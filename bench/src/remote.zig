//! Running commands on the other two VMs, with deadlines that actually fire.
//!
//! The old harness had no timeout of any kind: every `ssh` used only
//! `-o BatchMode=yes`, with no `ConnectTimeout`, no `ServerAliveInterval`, and
//! no wall-clock bound. The ramp invocation in particular was silent for 300s,
//! which sits right inside the 300-350s idle window cloud NAT gateways commonly
//! enforce — so a dropped session left the driver blocked forever. That is
//! survivable when a human is watching and fatal when nothing is.
//!
//! Every call here therefore carries a deadline, and a timed-out child is killed
//! by process GROUP so a wedged `ssh` cannot outlive it. Partial output is
//! RETURNED rather than discarded, because a killed command's stdout is usually
//! the only evidence of what went wrong.
//!
//! Nothing here logs an argv by default. Command lines carry the peers' private
//! addresses (compose needs `BACKEND_IP`), and this output is published.

const std = @import("std");
const Io = std.Io;

const redact = @import("redact.zig");

const Allocator = std.mem.Allocator;

pub const Outcome = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    /// The deadline fired and the child was killed. `term` is then whatever the
    /// kill produced and says nothing about the command's own outcome.
    timed_out: bool,

    pub fn ok(self: Outcome) bool {
        return !self.timed_out and self.term == .exited and self.term.exited == 0;
    }

    /// A short description for a failure message. Never includes the argv.
    pub fn describe(self: Outcome, buf: []u8) []const u8 {
        if (self.timed_out) return std.fmt.bufPrint(buf, "timed out", .{}) catch "timed out";
        return switch (self.term) {
            .exited => |c| std.fmt.bufPrint(buf, "exit {d}", .{c}) catch "exit ?",
            .signal => |s| std.fmt.bufPrint(buf, "killed by signal {d}", .{@intFromEnum(s)}) catch "signalled",
            .stopped => "stopped",
            .unknown => "unknown termination",
        };
    }
};

pub const ExecOptions = struct {
    deadline_ns: u64,
    /// Cap on captured output; beyond this the tail is dropped. Guards against
    /// a command that decides to stream forever.
    max_output: usize = 1 << 20,
    /// Log the argv on failure. Off by default because argv carries peer
    /// addresses; turn it on only for commands built from constants.
    log_argv: bool = false,
    /// Called once, immediately BEFORE the deadline's kill — the last moment the
    /// child's state can still be observed.
    ///
    /// It exists because the evidence a timeout needs is usually destroyed by the
    /// timeout itself: a wedged ramp holds thousands of ESTABLISHED connections,
    /// and killing it closes every one, so a census read after the fact reports an
    /// aftermath instead of the wedge. /proc/net is per-netns and the loadgen runs
    /// this child on the host, so the parent can read the child's sockets — but
    /// only while it is alive.
    ///
    /// Must not touch `io`: by definition this fires when something has already
    /// failed to finish, and a hook that can block is a hook that turns a bounded
    /// timeout back into a hang.
    on_deadline: ?*const fn () void = null,
};

/// How long a killed child gets to actually die before we stop waiting for it.
const kill_grace_ns: u64 = 5 * std.time.ns_per_s;

/// SIGKILL the child's whole process GROUP, and reap nothing.
///
/// Not `Child.kill`, for two reasons.
///
/// It signals the direct child only, so an `ssh` that has forked leaves the
/// grandchild holding the connection — the thing `.pgid = 0` was set up to
/// prevent. A negative pid targets the group, which with `.pgid = 0` is exactly
/// this child and its descendants.
///
/// And it reaps: it waits on the child it just signalled, which races the
/// `Waiter` already waiting on the same pid. The waiter wins, `Child.kill`'s
/// `waitpid` gets ECHILD, and std reads that as a double-free — a hard panic in
/// a Debug build (so `bench suite --local` died on any deadline), silently
/// swallowed in the ReleaseFast build the fleet runs, which instead lost the
/// exit status and left the term `unknown`. Leaving the reap to the one thread
/// already doing it removes the race rather than tolerating it.
///
/// Takes the pid rather than the `Child`, because `Child.id` is set to null by
/// whichever of `wait`/`kill` runs first — so by the time a deadline fires the
/// waiter may already have cleared the only record of what to signal.
fn killGroup(pid: std.posix.pid_t) void {
    // Raw syscall: nothing here may touch `io`, which by definition is already
    // failing to make progress when a deadline fires.
    _ = std.os.linux.kill(-pid, std.os.linux.SIG.KILL);
}

/// Spawn `argv`, capture both streams, and enforce a wall-clock deadline.
pub fn exec(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    opts: ExecOptions,
) !Outcome {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .pipe,
        // Its own process group, so killing on deadline reaches any grandchild
        // ssh has spawned rather than leaving one holding the connection.
        .pgid = 0,
    });
    // Captured now, while it is still there to capture: `Child.id` is cleared by
    // the reap, and the reap happens on another thread. With `.pgid = 0` the
    // child's group id IS its pid, so this is the group to signal.
    const pid = child.id.?;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var err: std.ArrayList(u8) = .empty;
    errdefer err.deinit(gpa);

    var timed_out = false;

    // Race the child against the deadline. Draining both pipes concurrently
    // matters: a command that fills the stderr pipe while we block reading
    // stdout would deadlock, which is exactly how a verbose `docker build`
    // would hang the suite.
    var group: Io.Group = .init;
    defer group.cancel(io);

    var drain_out = Drain{ .io = io, .gpa = gpa, .file = child.stdout.?, .into = &out, .max = opts.max_output };
    var drain_err = Drain{ .io = io, .gpa = gpa, .file = child.stderr.?, .into = &err, .max = opts.max_output };
    group.async(io, Drain.run, .{&drain_out});
    group.async(io, Drain.run, .{&drain_err});

    var waiter: Waiter = .{ .io = io, .child = &child };
    var wait_group: Io.Group = .init;
    wait_group.async(io, Waiter.run, .{&waiter});

    // Poll rather than select, so this stays provider-agnostic between the
    // Threaded Io used on the runner and zio's used during a ramp.
    const step_ns: u64 = 50 * std.time.ns_per_ms;
    var waited: u64 = 0;
    while (!waiter.done.load(.acquire)) {
        if (waited >= opts.deadline_ns) {
            // Re-checked before committing to the timeout, for the child that
            // finishes right on the wire: reporting it `timed_out` would be a
            // lie, and a pid that has already been reaped can be REUSED, so
            // signalling it would aim SIGKILL at whatever inherited the number.
            if (waiter.done.load(.acquire)) break;
            timed_out = true;
            if (opts.on_deadline) |hook| hook();
            killGroup(pid);
            // Let `Waiter` do the reaping, then move on.
            //
            // SIGKILL is prompt, so this normally returns on the first tick. It
            // is bounded anyway because "prompt" is not "guaranteed": a process
            // blocked in an uninterruptible kernel operation — the ramp child
            // sitting in io_uring is exactly that shape — does not die until the
            // operation completes, and waiting on it without a bound would put
            // the hang straight back.
            var grace: u64 = 0;
            while (!waiter.done.load(.acquire) and grace < kill_grace_ns) {
                io.sleep(.fromNanoseconds(step_ns), .awake) catch break;
                grace += step_ns;
            }
            break;
        }
        io.sleep(.fromNanoseconds(step_ns), .awake) catch break;
        waited += step_ns;
    }
    wait_group.cancel(io);
    group.cancel(io);

    const term = waiter.term orelse std.process.Child.Term{ .unknown = 0 };

    return .{
        .term = term,
        .stdout = try out.toOwnedSlice(gpa),
        .stderr = try err.toOwnedSlice(gpa),
        .timed_out = timed_out,
    };
}

const Waiter = struct {
    io: Io,
    child: *std.process.Child,
    term: ?std.process.Child.Term = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Waiter) void {
        self.term = self.child.wait(self.io) catch null;
        self.done.store(true, .release);
    }
};

const Drain = struct {
    io: Io,
    gpa: Allocator,
    file: Io.File,
    into: *std.ArrayList(u8),
    max: usize,

    fn run(self: *Drain) void {
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = self.file.readStreaming(self.io, &.{&buf}) catch break;
            if (n == 0) break;
            if (self.into.items.len >= self.max) continue;
            const take = @min(n, self.max - self.into.items.len);
            self.into.appendSlice(self.gpa, buf[0..take]) catch break;
        }
    }
};

/// Builds ssh command lines for the fleet's private network.
pub const Ssh = struct {
    key_path: []const u8,
    known_hosts: []const u8,
    user: []const u8 = "ubuntu",

    /// The options every connection gets.
    ///
    /// `StrictHostKeyChecking=yes` against a PINNED known_hosts is possible here
    /// only because terraform generates the host keys and injects them at boot,
    /// so they are known before the VM exists. Trust-on-first-use would be the
    /// usual compromise for ephemeral hosts; this avoids it.
    ///
    /// `ServerAliveInterval`/`ServerAliveCountMax` bound a silent session to
    /// ~120s of no traffic. The ramp is silent for far longer than that by
    /// design, so `bench suite` runs it locally rather than over ssh — these
    /// options exist for the short control commands.
    pub fn argv(
        self: Ssh,
        arena: Allocator,
        host: []const u8,
        remote_cmd: []const u8,
    ) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(arena, &.{
            "ssh",
            "-i",                            self.key_path,
            "-o",                            "IdentitiesOnly=yes",
            "-o",                            "BatchMode=yes",
            "-o",                            "StrictHostKeyChecking=yes",
            "-o",                            try std.fmt.allocPrint(arena, "UserKnownHostsFile={s}", .{self.known_hosts}),
            "-o",                            "ConnectTimeout=10",
            "-o",                            "ServerAliveInterval=15",
            "-o",                            "ServerAliveCountMax=8",
            "-o",                            "LogLevel=ERROR",
            try std.fmt.allocPrint(arena, "{s}@{s}", .{ self.user, host }),
            remote_cmd,
        });
        return list.toOwnedSlice(arena);
    }
};

/// Where a control command runs.
///
/// The two arms differ only in how the command string is delivered — over ssh to
/// a fleet VM, or to a local shell for `bench suite --local`. Both hand the
/// command to a shell, so `cd x && docker compose ...` means the same thing
/// either way and the suite needs no separate code path per mode.
pub const Host = union(enum) {
    remote: struct { ssh: Ssh, addr: []const u8 },
    local,
};

/// Run a command on `host`, returning an error if it did not succeed. The
/// child's stderr is passed through the redaction filter before being logged.
pub fn check(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    host: Host,
    what: []const u8,
    cmd: []const u8,
    deadline_ns: u64,
) !Outcome {
    const argv = switch (host) {
        .remote => |r| try r.ssh.argv(arena, r.addr, cmd),
        .local => try arena.dupe([]const u8, &.{ "sh", "-c", cmd }),
    };
    const res = try exec(gpa, io, argv, .{ .deadline_ns = deadline_ns });
    if (!res.ok()) {
        var buf: [64]u8 = undefined;
        redact.log("bench: {s} failed ({s})", .{ what, res.describe(&buf) });
        if (res.stderr.len > 0) {
            var scrubbed: [4096]u8 = undefined;
            const tail = res.stderr[res.stderr.len -| 1024 ..];
            std.debug.print("  {s}\n", .{redact.scrub(&scrubbed, tail)});
        }
        return error.RemoteCommandFailed;
    }
    return res;
}

/// Set by the test below; a hook is a plain fn, so there is nowhere else to
/// record that it ran.
var hook_fired: bool = false;

test "the deadline hook runs, and runs before the child is killed" {
    // The ordering is the entire point: the hook exists to observe state that
    // the kill destroys. The child below never finishes on its own, so a hook
    // that fires at all can only have fired on the deadline path.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    hook_fired = false;
    const res = try exec(
        std.testing.allocator,
        threaded.io(),
        // Absolute path and a shell BUILTIN loop, because a test has neither: PATH
        // comes from `std.process.Init`, which only `main` receives, so a bare
        // `sleep` here fails to resolve with FileNotFound.
        &.{ "/bin/sh", "-c", "while :; do :; done" },
        .{
            .deadline_ns = 200 * std.time.ns_per_ms,
            .on_deadline = struct {
                fn f() void {
                    hook_fired = true;
                }
            }.f,
        },
    );
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);

    try std.testing.expect(res.timed_out);
    try std.testing.expect(!res.ok());
    try std.testing.expect(hook_fired);

    // The termination survives the kill, which is the other half of `killGroup`:
    // reaping from two threads lost it to ECHILD and left this `unknown`.
    switch (res.term) {
        .signal => |s| try std.testing.expectEqual(@as(u32, 9), @intFromEnum(s)),
        else => return error.TestExpectedSignalledChild,
    }
}

test "no hook is not an error" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const res = try exec(
        std.testing.allocator,
        threaded.io(),
        // Absolute path and a shell BUILTIN loop, because a test has neither: PATH
        // comes from `std.process.Init`, which only `main` receives, so a bare
        // `sleep` here fails to resolve with FileNotFound.
        &.{ "/bin/sh", "-c", "while :; do :; done" },
        .{ .deadline_ns = 200 * std.time.ns_per_ms },
    );
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try std.testing.expect(res.timed_out);
}

test "Outcome.ok is true only for a clean exit" {
    const clean: Outcome = .{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "", .timed_out = false };
    try std.testing.expect(clean.ok());

    const nonzero: Outcome = .{ .term = .{ .exited = 1 }, .stdout = "", .stderr = "", .timed_out = false };
    try std.testing.expect(!nonzero.ok());

    // A command killed on deadline may still report Exited(0) from the kill
    // path; the timeout flag must veto it, or a timed-out ramp would be
    // recorded as a successful one.
    const late: Outcome = .{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "", .timed_out = true };
    try std.testing.expect(!late.ok());
}

test "Outcome.describe never leaks a command line" {
    var buf: [64]u8 = undefined;
    const timedout: Outcome = .{ .term = .{ .unknown = 0 }, .stdout = "", .stderr = "", .timed_out = true };
    try std.testing.expectEqualStrings("timed out", timedout.describe(&buf));

    const failed: Outcome = .{ .term = .{ .exited = 137 }, .stdout = "", .stderr = "", .timed_out = false };
    try std.testing.expectEqualStrings("exit 137", failed.describe(&buf));
}

test "Ssh.argv pins host keys and bounds connect time" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ssh: Ssh = .{ .key_path = "/run/bench/id", .known_hosts = "/run/bench/known_hosts" };
    const argv = try ssh.argv(arena, "10.10.0.27", "docker ps");

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (argv) |a| {
        try joined.appendSlice(std.testing.allocator, a);
        try joined.append(std.testing.allocator, ' ');
    }
    const s = joined.items;

    try std.testing.expect(std.mem.indexOf(u8, s, "StrictHostKeyChecking=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ConnectTimeout=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ServerAliveInterval=15") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "BatchMode=yes") != null);
    try std.testing.expectEqualStrings("docker ps", argv[argv.len - 1]);
    try std.testing.expectEqualStrings("ubuntu@10.10.0.27", argv[argv.len - 2]);
}

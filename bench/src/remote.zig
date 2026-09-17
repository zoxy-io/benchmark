//! Running commands on the other two VMs, with deadlines that actually fire.
//!
//! Every call has a deadline (a silent ssh can sit forever behind a NAT idle
//! timeout); a timed-out child is killed by process group and its partial
//! output returned. Never log an argv by default: it carries private peer
//! addresses and the output is published.

const std = @import("std");
const Io = std.Io;

const redact = @import("redact.zig");

const Allocator = std.mem.Allocator;

pub const Outcome = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    /// The deadline fired and the child was killed; `term` then reflects the kill.
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
    /// Cap on captured output; beyond this the tail is dropped.
    max_output: usize = 1 << 20,
    /// Log the argv on failure. Only for commands built from constants: argv
    /// carries peer addresses.
    log_argv: bool = false,
    /// Called once, just BEFORE the deadline's kill, to observe state the kill
    /// destroys (e.g. the wedged ramp's sockets). Must not touch `io` or block.
    on_deadline: ?*const fn () void = null,
    /// Print the child's output as it arrives, not only at exit. For the
    /// long-running ramp: buffered output dies with a killed parent (run #24).
    stream_output: bool = false,
};

/// How long a killed child gets to actually die before we stop waiting for it.
const kill_grace_ns: u64 = 5 * std.time.ns_per_s;

/// SIGKILL the child's whole process group, and reap nothing. Not
/// `Child.kill`: it signals only the direct child (leaving an ssh grandchild),
/// and its reap races `Waiter` (ECHILD: Debug panic, lost term in release).
/// Takes the pid because `Child.id` is nulled by whichever reaps first.
fn killGroup(pid: std.posix.pid_t) void {
    // Libc kill, not `io` (already stuck). Not `std.os.linux.kill`: a Linux
    // syscall on Darwin traps SIGSYS and kills the caller.
    std.posix.kill(-pid, .KILL) catch {};
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
        // Own process group, so a deadline kill reaches ssh's grandchildren.
        .pgid = 0,
    });
    // Capture now: the reap on another thread clears `Child.id`. With
    // `.pgid = 0` the pid is also the group id.
    const pid = child.id.?;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var err: std.ArrayList(u8) = .empty;
    errdefer err.deinit(gpa);

    var timed_out = false;

    // Drain both pipes concurrently, or a full stderr pipe deadlocks the child.
    var group: Io.Group = .init;
    defer group.cancel(io);

    var drain_out = Drain{ .io = io, .gpa = gpa, .file = child.stdout.?, .into = &out, .max = opts.max_output, .echo = opts.stream_output };
    var drain_err = Drain{ .io = io, .gpa = gpa, .file = child.stderr.?, .into = &err, .max = opts.max_output, .echo = opts.stream_output };
    group.async(io, Drain.run, .{&drain_out});
    group.async(io, Drain.run, .{&drain_err});

    var waiter: Waiter = .{ .io = io, .child = &child };
    var wait_group: Io.Group = .init;
    wait_group.async(io, Waiter.run, .{&waiter});

    // Poll rather than select, to stay agnostic between Threaded Io and zio.
    const step_ns: u64 = 50 * std.time.ns_per_ms;
    var waited: u64 = 0;
    while (!waiter.done.load(.acquire)) {
        if (waited >= opts.deadline_ns) {
            // Re-check: a child that just finished isn't timed out, and its pid may
            // already be reused.
            if (waiter.done.load(.acquire)) break;
            timed_out = true;
            if (opts.on_deadline) |hook| hook();
            killGroup(pid);
            // Let `Waiter` reap. Bounded: a child stuck in an uninterruptible op
            // (e.g. io_uring) may not die promptly.
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
    /// Print each line as it arrives, as well as accumulating it.
    echo: bool = false,
    /// How much of `into` has already been printed.
    echoed: usize = 0,

    fn run(self: *Drain) void {
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = self.file.readStreaming(self.io, &.{&buf}) catch break;
            if (n == 0) break;
            if (self.into.items.len >= self.max) continue;
            const take = @min(n, self.max - self.into.items.len);
            self.into.appendSlice(self.gpa, buf[0..take]) catch break;
            if (self.echo) self.flushLines();
        }
        // Whatever is left has no trailing newline; it is still worth printing.
        if (self.echo) self.flushRest();
    }

    /// Print every COMPLETE line accumulated since the last call.
    /// Print every complete line accumulated since the last call. Whole lines
    /// only, so a read boundary can't split an address past `redact.scrub`.
    fn flushLines(self: *Drain) void {
        const pending = self.into.items[self.echoed..];
        const end = std.mem.lastIndexOfScalar(u8, pending, '\n') orelse return;
        printScrubbed(pending[0 .. end + 1]);
        self.echoed += end + 1;
    }

    fn flushRest(self: *Drain) void {
        if (self.echoed >= self.into.items.len) return;
        printScrubbed(self.into.items[self.echoed..]);
        self.echoed = self.into.items.len;
    }
};

/// Print `text` a line at a time, each line scrubbed.
/// Per line because `scrub` truncates at the end of its output buffer.
fn printScrubbed(text: []const u8) void {
    var scrubbed: [4096]u8 = undefined;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Cap at half the buffer so the scrubbed line always fits.
        const safe = line[0..@min(line.len, scrubbed.len / 2)];
        std.debug.print("{s}\n", .{redact.scrub(&scrubbed, safe)});
    }
}

/// Builds ssh command lines for the fleet's private network.
pub const Ssh = struct {
    key_path: []const u8,
    known_hosts: []const u8,
    user: []const u8 = "ubuntu",

    /// The options every connection gets.
    /// The options every connection gets. Host keys are pinned (terraform
    /// generates and injects them). ServerAlive bounds a silent session to ~120s,
    /// so the long silent ramp must not run over ssh.
    pub fn argv(
        self: Ssh,
        arena: Allocator,
        host: []const u8,
        remote_cmd: []const u8,
    ) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(arena, &.{
            "ssh",
            "-i",
            self.key_path,
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            try std.fmt.allocPrint(arena, "UserKnownHostsFile={s}", .{self.known_hosts}),
            "-o",
            try std.fmt.allocPrint(arena, "ConnectTimeout={d}", .{connect_timeout_s}),
            "-o",
            "ServerAliveInterval=15",
            "-o",
            "ServerAliveCountMax=8",
            "-o",
            "LogLevel=ERROR",
            try std.fmt.allocPrint(arena, "{s}@{s}", .{ self.user, host }),
            remote_cmd,
        });
        return list.toOwnedSlice(arena);
    }
};

/// Where a control command runs.
/// Where a control command runs: ssh to a fleet VM, or a local shell for
/// `bench suite --local`. Both go through a shell, so commands are identical.
pub const Host = union(enum) {
    remote: struct { ssh: Ssh, addr: []const u8 },
    local,
};

/// The tail of one captured stream, redacted and printed under `label`.
/// The tail of one captured stream, redacted and printed under `label`.
/// 16 KiB because BuildKit's epilogue alone exceeds 1 KiB and would hide the
/// real error.
fn printTail(arena: Allocator, label: []const u8, stream: []const u8) !void {
    if (stream.len == 0) return;
    const keep = 16 * 1024;
    const tail = stream[stream.len -| keep..];
    // Heap-sized to the tail: `scrub` truncates at its buffer end, and a
    // scrubbed result never outgrows its input.
    const scrubbed = try arena.alloc(u8, tail.len);
    std.debug.print("  [{s}] {s}\n", .{ label, redact.scrub(scrubbed, tail) });
}

/// How long ssh waits for a connection, and for the banner that follows it.
/// How long ssh waits for a connection and banner. `connect_retry_budget_ns`
/// derives from it.
const connect_timeout_s: u64 = 10;

/// Transport retries: attempts, and the wait between them.
/// Transport retries: attempts, and the wait between them. sshd on the proxy
/// VM can vanish for seconds (e.g. apt restarting `ssh.socket`); see run
/// 32885230435.
pub const connect_attempts: u32 = 3;
pub const connect_retry_backoff_ns: u64 = 5 * std.time.ns_per_s;

/// The most wall clock retrying can add to ONE `check`, over its own deadline.
/// The most wall clock retrying can add to ONE `check`. Only failed connects
/// are retried, so each retry costs the connect timeout. `suite.deadline.turn`
/// must count it, or the watchdog can fire first (run #24).
pub const connect_retry_budget_ns: u64 =
    (connect_attempts - 1) * (connect_timeout_s * std.time.ns_per_s + connect_retry_backoff_ns);

/// Whether ssh failed BEFORE the remote command could have started.
/// Whether ssh failed BEFORE the remote command could have started, so a retry
/// cannot repeat a side effect. A bare `Connection closed by remote host` is a
/// mid-command drop and must NOT match. Exit 255 alone is not enough (a remote
/// command can exit 255); the stderr marker decides.
fn isConnectFailure(res: Outcome) bool {
    if (res.timed_out) return false;
    if (res.term != .exited or res.term.exited != 255) return false;
    for ([_][]const u8{
        "ssh: connect to host",
        "banner exchange",
        "kex_exchange_identification",
    }) |marker| {
        if (std.mem.indexOf(u8, res.stderr, marker) != null) return true;
    }
    return false;
}

/// Run a command on `host`, returning an error if it did not succeed. Output
/// is redacted before logging.
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
    var attempt: u32 = 1;
    const res = while (true) : (attempt += 1) {
        const r = try exec(gpa, io, argv, .{ .deadline_ns = deadline_ns });
        if (r.ok() or attempt >= connect_attempts or !isConnectFailure(r)) break r;
        gpa.free(r.stdout);
        gpa.free(r.stderr);
        redact.log("bench: {s}: ssh could not connect (attempt {d}/{d}), retrying", .{
            what, attempt, connect_attempts,
        });
        io.sleep(.fromNanoseconds(connect_retry_backoff_ns), .awake) catch {};
    };
    if (!res.ok()) {
        var buf: [64]u8 = undefined;
        redact.log("bench: {s} failed ({s})", .{ what, res.describe(&buf) });
        // Both streams, stdout first: BuildKit writes the step log (the real
        // error) to stdout, compose's epilogue to stderr.
        try printTail(arena, "stdout", res.stdout);
        try printTail(arena, "stderr", res.stderr);
        return error.RemoteCommandFailed;
    }
    return res;
}

test "the streaming echo consumes only complete lines" {
    // A split line (or address) is never printed before its newline arrives.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var d = Drain{
        .io = undefined,
        .gpa = std.testing.allocator,
        .file = undefined,
        .into = &buf,
        .max = 1 << 20,
        .echo = true,
    };

    try buf.appendSlice(std.testing.allocator, "a\nb");
    d.flushLines();
    try std.testing.expectEqual(@as(usize, 2), d.echoed); // "a\n" only

    try buf.appendSlice(std.testing.allocator, "c\n");
    d.flushLines();
    try std.testing.expectEqual(@as(usize, 5), d.echoed); // now "bc\n" too

    // A last line with no newline is still worth printing at EOF.
    try buf.appendSlice(std.testing.allocator, "d");
    d.flushLines();
    try std.testing.expectEqual(@as(usize, 5), d.echoed);
    d.flushRest();
    try std.testing.expectEqual(@as(usize, 6), d.echoed);
}

/// Set by the test below's hook, which is a plain fn.
var hook_fired: bool = false;

test "the deadline hook runs, and runs before the child is killed" {
    // The child never exits, so a fired hook can only be the deadline path.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    hook_fired = false;
    const res = try exec(
        std.testing.allocator,
        threaded.io(),
        // Absolute path: tests have no PATH (it comes from `std.process.Init`).
        &.{ "/bin/sleep", "60" },
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

    // The term survives the kill (single reaper; see `killGroup`).
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
        // Absolute path: tests have no PATH (it comes from `std.process.Init`).
        &.{ "/bin/sleep", "60" },
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

    // A timed-out command must not be ok, whatever its term.
    const late: Outcome = .{ .term = .{ .exited = 0 }, .stdout = "", .stderr = "", .timed_out = true };
    try std.testing.expect(!late.ok());
}

test "only a pre-authentication ssh failure is retryable" {
    // Builds an Outcome; `stderr` is mutable there, so literals need @constCast.
    const at = struct {
        fn f(stderr: []const u8, timed_out: bool) Outcome {
            return .{
                .term = .{ .exited = 255 },
                .stdout = "",
                .stderr = @constCast(stderr),
                .timed_out = timed_out,
            };
        }
    }.f;

    const refused = "ssh: connect to host 10.10.0.27 port 22: Connection refused\n";
    try std.testing.expect(isConnectFailure(at(refused, false)));
    try std.testing.expect(isConnectFailure(at("Connection timed out during banner exchange\n", false)));
    try std.testing.expect(isConnectFailure(at("kex_exchange_identification: Connection closed by remote host\n", false)));

    // Mid-command drop: may have taken effect, must NOT be retried.
    try std.testing.expect(!isConnectFailure(at("Connection closed by 10.10.0.27 port 22\n", false)));

    // The remote command's own 255, which says nothing about the transport.
    try std.testing.expect(!isConnectFailure(at("docker: no such container\n", false)));

    // A killed child had started its command; that's the deadline's business.
    try std.testing.expect(!isConnectFailure(at(refused, true)));

    // A clean exit is never a transport failure, whatever is on stderr.
    try std.testing.expect(!isConnectFailure(.{
        .term = .{ .exited = 0 },
        .stdout = "",
        .stderr = @constCast(refused),
        .timed_out = false,
    }));
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

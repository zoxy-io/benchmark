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
};

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
            timed_out = true;
            child.kill(io);
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

/// Run a command on `host`, returning an error if it did not succeed. The
/// child's stderr is passed through the redaction filter before being logged.
pub fn sshCheck(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    ssh: Ssh,
    host: []const u8,
    what: []const u8,
    remote_cmd: []const u8,
    deadline_ns: u64,
) !Outcome {
    const argv = try ssh.argv(arena, host, remote_cmd);
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

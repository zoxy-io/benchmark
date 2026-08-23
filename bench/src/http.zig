//! One bounded HTTP client, for every request this harness makes to something
//! it did not start.
//!
//! `std.http.Client.fetch` has no deadline of any kind. Nothing in it bounds a
//! stalled connect, a TLS handshake that never completes, or a server that
//! accepts the connection and then drips the response one byte at a time
//! forever. For an unattended job that is not a slow request, it is a hung one:
//! nightly run #9 burned 71 minutes inside a single `bench wait` poll.
//!
//! The bound comes from `Io`, not from a thread. `std.http.Client` performs
//! every operation through the `Io` it is given, so running the call as a task
//! and cancelling its `Io.Group` unwinds whatever it is blocked in — measured
//! at 1 ms under `Io.Threaded` and 0 ms under zio, against a server that
//! accepts and then never answers. Both backends matter: the ramp child runs
//! on zio, while `wait`, `notify` and `sweep` run on `process.Init`'s
//! `Io.Threaded`.
//!
//! This replaces a thread-per-request workaround that could not cancel
//! anything: it spawned an OS thread, polled an atomic flag, and on deadline
//! ABANDONED the thread, deliberately leaking the client, the task, the
//! headers and the sink, because a thread blocked in a syscall cannot be
//! unwound and anything it might still write to had to stay valid forever.
//! That leak is gone, and with it the rule that a `collect` writer must
//! outlive the process rather than merely the call.
//!
//! This file exists because that shape used to be written out twice, verbatim,
//! in `ycs.zig` and `discord.zig` — same `FetchTask` struct, same
//! `fetch_deadline_ns`, same abandon-and-leak comment. Two copies is two places
//! to fix, and every bug this code has ever had was fixed in exactly one of
//! them:
//!
//!   * d4ad5fa — a missing `response_writer` segfaults inside std's own discard
//!     path, and ONLY in the ReleaseFast static-musl build CI ships. It reached
//!     a real run and killed `bench wait` two seconds after tofu had brought up
//!     the whole fleet.
//!   * 8a6a507 / a60a95c — a reply with no discoverable body end (a HEAD's
//!     `content-length` with no body, Discord's 204) hangs the read forever
//!     unless the connection is asked to close.
//!
//! Both are now structural rather than remembered: `response_writer` is always
//! set because `Sink` has no variant that omits it, and `keep_alive` is not a
//! parameter at all.
//!
//! What this deliberately does NOT cover: `suite.probeOnce`, which speaks
//! HTTP/1.1 by hand over `std.Io.net` because it needs zrk's TLS transport
//! specifically — a handshake the probe accepts has to be one the measurement
//! will accept too, and that property is the whole reason the probe exists.
//!
//! `cadvisor.scrape` is covered, by `Sink.stream`. It used to parse the raw
//! socket itself, which is how it spent months reading a chunked body as plain
//! text and losing a slice of every exposition to the chunk framing. Framing
//! is std's job here, so that class of bug cannot recur.

const std = @import("std");
const Io = std.Io;

const Allocator = std.mem.Allocator;

/// How long one request gets before it is cancelled as failed.
///
/// Every caller here is either a one-shot (`notify`, `sweep`) or a poll on a
/// 30-second tick (`wait`), so this only has to be longer than a healthy
/// request and shorter than the loop it sits in.
pub const default_deadline_ns: u64 = 30 * std.time.ns_per_s;

/// How often the deadline is checked while the request runs. Polled rather
/// than selected on, for the reason `remote.check` polls: it keeps this
/// working unchanged on both the `Io.Threaded` the CLI commands run under and
/// the zio Runtime a ramp runs under.
const poll_step_ns: u64 = 20 * std.time.ns_per_ms;

pub const Response = struct {
    status: std.http.Status,

    pub fn ok(self: Response) bool {
        return self.status == .ok;
    }
};

/// A response body consumed a line at a time, without ever holding more than
/// one line of it.
///
/// This is what lets a ~2 MB cAdvisor exposition be parsed inside the load
/// generator's own process at 1 Hz without allocating or copying it: `drain`
/// hands complete lines straight out of the transport's buffer and keeps only
/// a partial trailing line in `carry`.
///
/// Lines longer than `carry` are dropped whole rather than truncated — a
/// truncated metric line still parses as a metric and reports a wrong value,
/// which is worse than a missing one — and counted in `overlong`, so a caller
/// can tell "no such series" from "that series did not fit".
pub const LineSink = struct {
    writer: Io.Writer,
    carry: []u8,
    carry_len: usize = 0,
    /// Lines that exceeded `carry` and were dropped whole.
    overlong: u64 = 0,
    /// Mid-drop: bytes are discarded until the next newline.
    dropping: bool = false,
    ctx: *anyopaque,
    onLine: *const fn (ctx: *anyopaque, line: []const u8) void,

    /// `carry` bounds the longest line this can deliver; `buffer` is ordinary
    /// `Io.Writer` scratch and may be small.
    pub fn init(
        buffer: []u8,
        carry: []u8,
        ctx: *anyopaque,
        onLine: *const fn (ctx: *anyopaque, line: []const u8) void,
    ) LineSink {
        return .{
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
            .carry = carry,
            .ctx = ctx,
            .onLine = onLine,
        };
    }

    /// Deliver a final line that had no trailing newline. `fetch` calls this
    /// once the body has ended; calling it twice is harmless.
    pub fn finish(self: *LineSink) void {
        if (self.carry_len == 0) return;
        const line = self.carry[0..self.carry_len];
        self.carry_len = 0;
        self.onLine(self.ctx, line);
    }

    fn feed(self: *LineSink, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            if (self.dropping) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return;
                self.dropping = false;
                rest = rest[nl + 1 ..];
                continue;
            }
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
            const chunk = rest[0..nl];
            if (self.carry_len == 0) {
                // The common case, and the reason this is cheap: the line is
                // whole inside the transport's buffer, so it is never copied.
                // The length limit is still applied here, so that whether a
                // line is delivered depends on the line and not on where the
                // transport happened to split the stream.
                if (chunk.len <= self.carry.len) {
                    self.onLine(self.ctx, chunk);
                } else {
                    self.overlong += 1;
                }
            } else if (self.carry_len + chunk.len <= self.carry.len) {
                @memcpy(self.carry[self.carry_len..][0..chunk.len], chunk);
                self.carry_len += chunk.len;
                self.onLine(self.ctx, self.carry[0..self.carry_len]);
                self.carry_len = 0;
            } else {
                self.overlong += 1;
                self.carry_len = 0;
            }
            rest = rest[nl + 1 ..];
        }
        if (self.dropping or rest.len == 0) return;
        if (self.carry_len + rest.len <= self.carry.len) {
            @memcpy(self.carry[self.carry_len..][0..rest.len], rest);
            self.carry_len += rest.len;
        } else {
            self.overlong += 1;
            self.carry_len = 0;
            self.dropping = true;
        }
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *LineSink = @alignCast(@fieldParentPtr("writer", w));
        if (w.end > 0) {
            self.feed(w.buffer[0..w.end]);
            w.end = 0;
        }
        const head = data[0 .. data.len - 1];
        const pattern = data[head.len];
        var written: usize = 0;
        for (head) |bytes| {
            self.feed(bytes);
            written += bytes.len;
        }
        for (0..splat) |_| self.feed(pattern);
        return written + pattern.len * splat;
    }
};

/// Where the response body goes.
///
/// There is no "no sink" variant, on purpose: omitting `response_writer` is
/// d4ad5fa, a segfault that reproduces in no build mode you would develop in.
pub const Sink = union(enum) {
    /// Nobody reads the body (HEAD, PUT, DELETE, a webhook's 204).
    discard,

    /// The caller keeps the whole body. Valid for the duration of the call —
    /// nothing outlives it any more.
    collect: *Io.Writer.Allocating,

    /// The caller parses the body a line at a time and keeps none of it.
    stream: *LineSink,
};

pub const Request = struct {
    url: []const u8,
    method: std.http.Method = .GET,
    /// Borrowed for the duration of the call, like every other field here.
    payload: ?[]const u8 = null,
    /// Sent verbatim as the `authorization` header. Every cloud call here is a
    /// bare `Bearer <IAM token>`; Yandex Object Storage accepts one directly, so
    /// there is no SigV4 to sign and no static key anywhere.
    authorization: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    sink: Sink = .discard,
    deadline_ns: u64 = default_deadline_ns,
    /// Named in the timeout message. A key or a short label, never a URL —
    /// a URL can carry a token in its query and these logs are public.
    what: []const u8 = "request",
};

const Call = struct {
    client: *std.http.Client,
    options: std.http.Client.FetchOptions,
    result: ?(std.http.Client.FetchError!std.http.Client.FetchResult) = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Call) void {
        self.result = self.client.fetch(self.options);
        self.done.store(true, .release);
    }
};

/// One bounded request. `null` means the deadline elapsed and the request was
/// cancelled.
///
/// Everything here is scoped to the call: `Io.Group.cancel` does not return
/// until the task has finished unwinding, so by the time this returns nothing
/// else holds a reference to the client, the sink, or any borrowed field of
/// `req`.
///
/// Each call also gets its OWN `std.http.Client` rather than a long-lived one.
/// Nothing forces that now that requests are cancelled rather than abandoned,
/// but one request per client keeps a connection pool from carrying state
/// between two unrelated cloud calls for no benefit — every caller here is a
/// one-shot or a 30-second poll.
pub fn fetch(gpa: Allocator, io: Io, req: Request) !?Response {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var discard_buf: [1024]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&discard_buf);
    const response_writer: *Io.Writer = switch (req.sink) {
        .discard => &discarding.writer,
        .collect => |w| &w.writer,
        .stream => |s| &s.writer,
    };

    var extra: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (req.content_type) |ct| blk: {
        extra[0] = .{ .name = "content-type", .value = ct };
        break :blk extra[0..1];
    } else &.{};

    var call: Call = .{
        .client = &client,
        .options = .{
            .location = .{ .url = req.url },
            .method = req.method,
            .payload = req.payload,
            .headers = .{
                .authorization = if (req.authorization) |a| .{ .override = a } else .default,
            },
            .extra_headers = extra_headers,
            .response_writer = response_writer,
            // Not a parameter. Ask the server to close after replying, always:
            // it is what gives a reply with no discoverable body end (a HEAD, a
            // 204) somewhere to stop, and one request per client means pooling
            // would buy nothing even if it were safe here.
            .keep_alive = false,
        },
    };

    var group: Io.Group = .init;
    group.async(io, Call.run, .{&call});

    const started = Io.Timestamp.now(io, .awake);
    while (!call.done.load(.acquire)) {
        if (started.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds >= req.deadline_ns) break;
        io.sleep(.fromNanoseconds(poll_step_ns), .awake) catch break;
    }
    // Joins whether or not it had to cancel anything, so everything below is
    // safe to touch and every `defer` above is safe to run.
    group.cancel(io);

    const result = call.result orelse {
        std.debug.print("bench: {s} timed out after {d}s\n", .{
            req.what, req.deadline_ns / std.time.ns_per_s,
        });
        return null;
    };
    const fetched = try result;
    if (req.sink == .stream) req.sink.stream.finish();
    return .{ .status = fetched.status };
}

test "a discard sink needs no caller allocation" {
    // The point of the test is the type, not a round trip: `Sink.discard`
    // carries no pointer, so no call site can forget to keep one alive.
    const r: Request = .{ .url = "https://example.invalid/", .what = "x" };
    try std.testing.expect(r.sink == .discard);
    try std.testing.expectEqual(default_deadline_ns, r.deadline_ns);
    try std.testing.expectEqual(std.http.Method.GET, r.method);
}

test "collect carries the caller's writer, not a copy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var body: Io.Writer.Allocating = .init(arena_state.allocator());
    const r: Request = .{ .url = "https://example.invalid/", .sink = .{ .collect = &body } };
    try std.testing.expectEqual(&body, r.sink.collect);
}

const LineCollector = struct {
    lines: std.ArrayList([]u8),
    gpa: Allocator,

    fn onLine(ctx: *anyopaque, line: []const u8) void {
        const self: *LineCollector = @ptrCast(@alignCast(ctx));
        const copy = self.gpa.dupe(u8, line) catch return;
        self.lines.append(self.gpa, copy) catch return;
    }

    fn deinit(self: *LineCollector) void {
        for (self.lines.items) |l| self.gpa.free(l);
        self.lines.deinit(self.gpa);
    }
};

test "LineSink splits lines across arbitrary write boundaries" {
    const gpa = std.testing.allocator;
    var collector: LineCollector = .{ .lines = .empty, .gpa = gpa };
    defer collector.deinit();

    var buf: [8]u8 = undefined;
    var carry: [64]u8 = undefined;
    var sink = LineSink.init(&buf, &carry, &collector, LineCollector.onLine);

    // Deliberately written in chunks that split lines mid-way, which is what a
    // transport does, and what the old hand-rolled reader got wrong when a
    // chunk marker landed inside a metric line.
    for ([_][]const u8{ "alpha\nbet", "a\ngamm", "a\n", "delta" }) |part| {
        try sink.writer.writeAll(part);
    }
    try sink.writer.flush();
    sink.finish();

    try std.testing.expectEqual(@as(usize, 4), collector.lines.items.len);
    try std.testing.expectEqualStrings("alpha", collector.lines.items[0]);
    try std.testing.expectEqualStrings("beta", collector.lines.items[1]);
    try std.testing.expectEqualStrings("gamma", collector.lines.items[2]);
    try std.testing.expectEqualStrings("delta", collector.lines.items[3]);
    try std.testing.expectEqual(@as(u64, 0), sink.overlong);
}

test "LineSink drops an overlong line whole rather than truncating it" {
    const gpa = std.testing.allocator;
    var collector: LineCollector = .{ .lines = .empty, .gpa = gpa };
    defer collector.deinit();

    var buf: [4]u8 = undefined;
    var carry: [8]u8 = undefined;
    var sink = LineSink.init(&buf, &carry, &collector, LineCollector.onLine);

    // A truncated metric line still parses as a metric, so half of one is
    // worse than none of it.
    try sink.writer.writeAll("short\n");
    try sink.writer.writeAll("this one is far longer than the carry buffer\n");
    try sink.writer.writeAll("after\n");
    try sink.writer.flush();
    sink.finish();

    try std.testing.expectEqual(@as(u64, 1), sink.overlong);
    try std.testing.expectEqual(@as(usize, 2), collector.lines.items.len);
    try std.testing.expectEqualStrings("short", collector.lines.items[0]);
    try std.testing.expectEqualStrings("after", collector.lines.items[1]);
}

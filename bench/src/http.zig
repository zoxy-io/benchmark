//! One bounded HTTP client, for every request this harness makes to something
//! it did not start.
//!
//! `std.http.Client.fetch` has no deadline of any kind. Nothing in it bounds a
//! stalled connect, a TLS handshake that never completes, or a server that
//! accepts the connection and then drips the response one byte at a time
//! forever. For an unattended job that is not a slow request, it is a hung one:
//! nightly run #9 burned 71 minutes inside a single `bench wait` poll.
//!
//! The workaround is unpleasant and there is no better one available: run the
//! call on its own OS thread, poll an atomic flag, and give up on the wall
//! clock if it never flips. Nothing here can force a thread blocked in a
//! syscall to unwind, so a request that misses its deadline is **abandoned**,
//! not cancelled — see `fetch`'s doc comment for what that costs and why it is
//! safe.
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
//! What this deliberately does NOT cover: `cadvisor.scrape` and
//! `suite.probeOnce`, which speak HTTP/1.1 by hand over `std.Io.net`. They are
//! not fetches. One streams ~200 KB of Prometheus exposition past a fixed
//! buffer without accumulating it, publishes its fd so a wedged read can be
//! interrupted, and orders that publication against its own close defer; the
//! other needs zrk's TLS transport specifically, so that a handshake the probe
//! accepts is one the measurement will accept too. Folding either into a
//! request/response API would mean giving up the property it exists for.

const std = @import("std");
const Io = std.Io;

const Allocator = std.mem.Allocator;

/// How long one request gets before it is abandoned as failed.
///
/// Every caller here is either a one-shot (`notify`, `sweep`) or a poll on a
/// 30-second tick (`wait`), so this only has to be longer than a healthy
/// request and shorter than the loop it sits in.
pub const default_deadline_ns: u64 = 30 * std.time.ns_per_s;

pub const Response = struct {
    status: std.http.Status,

    pub fn ok(self: Response) bool {
        return self.status == .ok;
    }
};

/// Where the response body goes.
///
/// There is no "no sink" variant, on purpose: omitting `response_writer` is
/// d4ad5fa, a segfault that reproduces in no build mode you would develop in.
pub const Sink = union(enum) {
    /// Nobody reads the body (HEAD, PUT, DELETE, a webhook's 204). `fetch`
    /// allocates the throwaway buffer itself, and on the abandon path
    /// deliberately never frees it.
    discard,

    /// The caller keeps the body. The writer and its allocator MUST outlive the
    /// process, not merely the call: if the deadline fires, the abandoned
    /// thread may still write through this pointer at any later moment. In
    /// practice that means an arena that is never reset — `wait`'s poll-loop
    /// arena is exactly this, which is why it can poll for 110 minutes without
    /// a stalled request being able to corrupt a later one.
    collect: *Io.Writer.Allocating,
};

pub const Request = struct {
    url: []const u8,
    method: std.http.Method = .GET,
    /// The request body. Unlike every other field here it is NOT copied —
    /// it can be arbitrarily large — so it must stay valid until the process
    /// exits, not merely until the call returns. Every caller today passes
    /// arena memory that is never reset, which satisfies that.
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

const Task = struct {
    client: *std.http.Client,
    options: std.http.Client.FetchOptions,
    result: ?(std.http.Client.FetchError!std.http.Client.FetchResult) = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Task) void {
        self.result = self.client.fetch(self.options);
        self.done.store(true, .release);
    }
};

/// One bounded request. `null` means the deadline elapsed and the request was
/// abandoned.
///
/// Every allocation an abandoned thread could still touch comes from `gpa` and
/// is freed ONLY on the path where the thread has been joined. On the timeout
/// path nothing is freed and nothing is reused, so the abandoned thread writes
/// into memory that belongs to it alone. That is a deliberate leak, bounded by
/// the process's remaining lifetime — the same trade `suite.ProxyWatchdog`
/// makes with the whole process. `bench` is a short-lived one-shot in every
/// mode it runs in.
///
/// Each call also gets its OWN `std.http.Client` rather than a long-lived one.
/// A shared client would mean every later request racing the connection pool of
/// whichever earlier request was abandoned into it; a throwaway one confines
/// the damage to itself.
pub fn fetch(gpa: Allocator, io: Io, req: Request) !?Response {
    const client = try gpa.create(std.http.Client);
    client.* = .{ .allocator = gpa, .io = io };

    // Held so the success path can free exactly what it allocated.
    var discard: ?*Io.Writer.Discarding = null;
    const response_writer: *Io.Writer = switch (req.sink) {
        .collect => |w| &w.writer,
        .discard => blk: {
            const d = try gpa.create(Io.Writer.Discarding);
            d.* = .init(try gpa.alloc(u8, 1024));
            discard = d;
            break :blk &d.writer;
        },
    };

    // Everything the request thread can still READ after this function returns
    // gets a gpa-owned copy, and those copies are freed only on the path where
    // the thread has been joined.
    //
    // This is not defensive tidiness; it is fixing a use-after-free the call
    // sites all had. `ycs.Client` builds each URL with `allocPrint` under a
    // `defer gpa.free(url)` and writes its `Bearer <token>` into a
    // `[4096]u8` on its own stack — so on the abandon path the old code left a
    // live thread reading a freed URL and a dead stack frame's auth token. It
    // never bit us because a timeout is rare and the thread is usually blocked
    // in connect() rather than serialising. Making the callers hold these alive
    // instead would push the same subtlety onto six call sites; owning them
    // here fixes all six and lets a caller keep passing a stack buffer.
    //
    // `payload` is the deliberate exception — it can be arbitrarily large and
    // copying it would double the peak footprint of an upload. Its contract is
    // in `Request`.
    const url = try gpa.dupe(u8, req.url);
    const what = try gpa.dupe(u8, req.what);
    const auth: ?[]const u8 = if (req.authorization) |a| try gpa.dupe(u8, a) else null;

    const extra = try gpa.alloc(std.http.Header, if (req.content_type == null) 0 else 1);
    if (req.content_type) |ct| {
        extra[0] = .{ .name = "content-type", .value = try gpa.dupe(u8, ct) };
    }

    const task = try gpa.create(Task);
    task.* = .{
        .client = client,
        .options = .{
            .location = .{ .url = url },
            .method = req.method,
            .payload = req.payload,
            .headers = .{
                .authorization = if (auth) |a| .{ .override = a } else .default,
            },
            .extra_headers = extra,
            .response_writer = response_writer,
            // Not a parameter. Ask the server to close after replying, always:
            // it is what gives a reply with no discoverable body end (a HEAD, a
            // 204) somewhere to stop, and one request per client means pooling
            // would buy nothing even if it were safe here.
            .keep_alive = false,
        },
    };

    const thread = try std.Thread.spawn(.{}, Task.run, .{task});

    const step_ns: u64 = 100 * std.time.ns_per_ms;
    var waited: u64 = 0;
    while (!task.done.load(.acquire) and waited < req.deadline_ns) {
        io.sleep(.fromNanoseconds(step_ns), .awake) catch break;
        waited += step_ns;
    }
    if (!task.done.load(.acquire)) {
        // Abandoned: return without freeing anything. Every allocation the
        // thread can still reach — client, task, headers, discard sink — stays
        // owned by nobody and is never reused, which is what makes it harmless
        // rather than a use-after-free.
        std.debug.print("bench: {s} timed out after {d}s\n", .{
            what, req.deadline_ns / std.time.ns_per_s,
        });
        return null;
    }

    thread.join(); // safe to free from here: nothing else touches any of it
    const result = task.result.?;
    client.deinit();
    gpa.destroy(client);
    gpa.destroy(task);
    for (extra) |h| gpa.free(h.value);
    gpa.free(extra);
    if (auth) |a| gpa.free(a);
    gpa.free(what);
    gpa.free(url);
    if (discard) |d| {
        gpa.free(d.writer.buffer);
        gpa.destroy(d);
    }

    return .{ .status = (try result).status };
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

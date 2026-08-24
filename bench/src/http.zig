//! One bounded HTTP client, for every request this harness makes to something
//! it did not start.
//!
//! This used to be ~400 lines wrapping `std.http.Client`: a task, a polled
//! done-flag, a deadline built by hand around a client that has none, and a
//! `LineSink` written here because nothing else had one. All of that now lives
//! in `zurl`, which was extracted from this file and then grown until it could
//! replace it. What is left is an adapter — the harness's spelling of a
//! request, translated into zurl's.
//!
//! The bound is still the point, and it is now zurl's `deadline_ns`: one
//! number covering DNS, connect, TLS and the response, enforced by Io
//! cancellation rather than by polling a flag every 20 ms. Nightly run #9's
//! 71 minutes inside a single `bench wait` poll is what it exists for.
//!
//! ## What changed, and what to watch
//!
//! **Redirects are no longer followed.** `std.http.Client` followed them
//! silently, so whatever these endpoints do, this harness has never seen it.
//! zurl defaults to not following, and a 3xx therefore arrives as a 3xx:
//! `res.ok()` is false and the caller logs the status. That is the loud
//! version of a question nobody had asked, and one run answers it. If an
//! endpoint turns out to redirect, set `follow_redirects` on THAT request
//! rather than globally.
//!
//! **A `content-encoding` other than identity is refused** rather than handed
//! to the sink. Nothing here asks for one, so a compliant origin never
//! triggers it — but an origin that gzips unasked used to feed compressed
//! bytes to `cadvisor`'s line parser, which is the same class of bug as the
//! chunked incident this whole effort came from.
//!
//! **Requests now carry `user-agent: zurl/0.0.0`.** They carried none before.

const std = @import("std");
const Io = std.Io;
const zurl = @import("zurl");

const Allocator = std.mem.Allocator;

/// How long one request gets before it is cancelled as failed.
///
/// Every caller here is either a one-shot (`notify`, `sweep`) or a poll on a
/// 30-second tick (`wait`), so this only has to be longer than a healthy
/// request and shorter than the loop it sits in.
pub const default_deadline_ns: u64 = 30 * std.time.ns_per_s;

/// The line-at-a-time sink, now zurl's.
///
/// It was written here first and moved there when zurl was extracted. Keeping
/// a second copy is exactly what this repository already learned not to do —
/// three HTTP implementations at three levels of completeness is the reason
/// zurl exists. Same shape: `carry` bounds the longest deliverable line,
/// overlong lines are dropped whole and counted rather than truncated, and
/// `finish` delivers a trailing line that had no newline.
pub const LineSink = zurl.LineSink;

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
/// zurl makes the same guarantee structurally, which is where it came from.
pub const Sink = union(enum) {
    /// Nobody reads the body (HEAD, PUT, DELETE, a webhook's 204).
    discard,

    /// The caller keeps the whole body. Valid for the duration of the call.
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
    /// Off by default, matching zurl and NOT matching the std client this
    /// replaced. Turn it on for one request if a run shows that endpoint
    /// redirecting; see the note at the top of this file.
    follow_redirects: bool = false,
};

/// One bounded request. `null` means the deadline elapsed and the request was
/// cancelled.
///
/// Everything is scoped to the call: zurl's `fetch` joins its worker before
/// returning, so by the time this returns nothing holds a reference to the
/// sink or to any borrowed field of `req`.
pub fn fetch(gpa: Allocator, io: Io, req: Request) !?Response {
    const secure = std.mem.startsWith(u8, req.url, "https://");

    // The trust store is the caller's, which is zurl's whole shape: loading it
    // allocates and zurl allocates nothing. Loaded per call, which is what the
    // std client did too — it built a fresh client per request and that client
    // loaded its bundle lazily on first use. Every caller here is a one-shot
    // or a 30-second poll, so the cost lands where it always did.
    var certificates: std.crypto.Certificate.Bundle = .empty;
    defer certificates.deinit(gpa);
    var lock: Io.RwLock = .init;
    if (secure) try certificates.rescan(gpa, io, .now(io, .real));

    var redirect_buf: [4 * 1024]u8 = undefined;

    const outcome = zurl.fetch(io, .{
        .url = req.url,
        .method = req.method,
        .authorization = req.authorization,
        .content_type = req.content_type,
        .body = if (req.payload) |payload| .{ .bytes = payload } else null,
        .sink = zurlSink(req.sink),
        .deadline_ns = req.deadline_ns,
        .what = req.what,
        .redirects = if (req.follow_redirects)
            .{ .max = 5, .buf = &redirect_buf }
        else
            .{},
        .tls = if (secure) .{ .ca = .{ .bundle = .{
            .gpa = gpa,
            .lock = &lock,
            .certificates = &certificates,
        } } } else null,
    }) catch |err| {
        // zurl's error set is wider than this wrapper's used to be, and the
        // extra members are the point: `UnsupportedContentEncoding` and
        // `InvalidRequestTarget` name failures the std client answered with a
        // corrupt body or a rewritten request line. Named in the log so a
        // nightly says which, instead of "it failed".
        std.debug.print("bench: {s} failed ({s})\n", .{ req.what, @errorName(err) });
        return err;
    };

    const response = outcome orelse {
        // zurl already printed which deadline fired and what it was named.
        return null;
    };

    // zurl range-checks the status before returning, so this is in 100..999.
    return .{ .status = @enumFromInt(response.status) };
}

/// This wrapper's `Sink` in zurl's spelling.
///
/// The one piece of genuinely new logic in the swap, and therefore the one
/// worth a test: everything else here forwards a field. Getting this wrong
/// would route a body to the wrong place, which is the failure `Sink` exists
/// to make unrepresentable (d4ad5fa) — so it should not be reintroduced by
/// the translation.
fn zurlSink(sink: Sink) zurl.Sink {
    return switch (sink) {
        .discard => .discard,
        .collect => |w| .{ .collect = w },
        .stream => |s| .{ .lines = s },
    };
}

const testing = std.testing;

test "every sink variant maps to the zurl variant that means the same thing" {
    var collected: Io.Writer.Allocating = .init(testing.allocator);
    defer collected.deinit();

    var buf: [64]u8 = undefined;
    var carry: [64]u8 = undefined;
    var lines = LineSink.init(&buf, &carry, null, struct {
        fn onLine(_: ?*anyopaque, _: []const u8) void {}
    }.onLine);

    // Discard stays discard: nobody reads the body, and it is still READ
    // rather than abandoned, which is what keeps the connection framed.
    try testing.expect(zurlSink(.discard) == .discard);

    // Collect carries the caller's writer by pointer, not a copy — a copy
    // would fill a temporary and hand the caller back an empty buffer.
    const mapped_collect = zurlSink(.{ .collect = &collected });
    try testing.expectEqual(&collected, mapped_collect.collect);

    // `stream` is this wrapper's older name for what zurl calls `lines`;
    // the rename is the only reason this arm is not an identity.
    const mapped_stream = zurlSink(.{ .stream = &lines });
    try testing.expectEqual(&lines, mapped_stream.lines);
}

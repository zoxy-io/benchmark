//! One bounded HTTP client, for every request this harness makes to something
//! it did not start.
//!
//! This used to be ~400 lines wrapping `std.http.Client`: a task, a polled
//! done-flag, a deadline built by hand around a client that has none, and a
//! `LineSink` written here because nothing else had one. All of that now lives
//! in `zurl`, which was extracted from this file and then grown until it could
//! replace it. What is left does two things zurl deliberately does not: it
//! supplies the trust anchors (zurl allocates nothing, so they are always the
//! caller's) and it hands back a `std.http.Status` rather than a `u16`.
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
//! endpoint turns out to redirect, set `redirects` on THAT request rather
//! than globally -- zurl drops `authorization` across an origin change either
//! way, which matters because these calls carry a live IAM token.
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

/// The status as an enum a caller can switch on.
///
/// This is one of the two reasons this file still exists. zurl returns a
/// `u16`, deliberately: it range-checks and otherwise has no opinion. The
/// callers here have plenty — `.created`, `.not_found`, `.no_content`,
/// `.too_many_requests` — and comparing those against magic numbers at ten
/// call sites is how a 204 gets confused with a 201.
pub const Response = struct {
    status: std.http.Status,

    pub fn ok(self: Response) bool {
        return self.status == .ok;
    }
};

/// One bounded request, with a trust store. `null` means the deadline elapsed
/// and the request was cancelled.
///
/// `req` is zurl's own `FetchRequest` rather than a copy of it under different
/// field names. The copy existed for one commit, to keep the swap small, and
/// was exactly the duplication the swap was supposed to remove: a `Sink` whose
/// only difference from zurl's was calling `lines` `stream`, and a `Request`
/// whose only difference was calling `body` `payload`.
///
/// Leave `.tls` unset. Filling it in is the other reason this file exists:
/// zurl requires caller-owned trust anchors, because loading them allocates
/// and zurl allocates nothing, and thirteen call sites each standing up a
/// `Certificate.Bundle` would be a worse duplication than the one just
/// deleted.
///
/// Everything is scoped to the call: zurl's `fetch` joins its worker before
/// returning, so by the time this returns nothing holds a reference to the
/// sink or to any borrowed field of `req`.
pub fn fetch(gpa: Allocator, io: Io, req: zurl.FetchRequest) !?Response {
    // This function owns `.tls`; a caller setting it would have it silently
    // replaced. Programmer misuse, so an assertion rather than an error.
    std.debug.assert(req.tls == null);

    const secure = std.mem.startsWith(u8, req.url, "https://");

    // The trust store is the caller's, which is zurl's whole shape. Loaded per
    // call, which is what the std client did too — it built a fresh client per
    // request and that client loaded its bundle lazily on first use. Every
    // caller here is a one-shot or a 30-second poll, so the cost lands where
    // it always did.
    var certificates: std.crypto.Certificate.Bundle = .empty;
    defer certificates.deinit(gpa);
    var lock: Io.RwLock = .init;
    if (secure) try certificates.rescan(gpa, io, .now(io, .real));

    var with_trust = req;
    if (secure) with_trust.tls = .{ .ca = .{ .bundle = .{
        .gpa = gpa,
        .lock = &lock,
        .certificates = &certificates,
    } } };

    const outcome = zurl.fetch(io, with_trust) catch |err| {
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

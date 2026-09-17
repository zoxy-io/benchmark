//! One bounded HTTP client, for every request this harness makes to something
//! it did not start. A thin wrapper over `zurl` that supplies trust anchors
//! and returns a `std.http.Status`.
//!
//! The bound is zurl's `deadline_ns`, covering DNS, connect, TLS and response
//! (nightly run #9 spent 71 minutes in one unbounded poll).
//!
//! Redirects are not followed; set `redirects` per request if ever needed
//! (zurl drops `authorization` across origins; these carry an IAM token).
//! Non-identity `content-encoding` is refused.

const std = @import("std");
const Io = std.Io;
const zurl = @import("zurl");

const Allocator = std.mem.Allocator;

/// How long one request gets before it is cancelled as failed.
pub const default_deadline_ns: u64 = 30 * std.time.ns_per_s;

/// The status as an enum, so callers compare `.created`/`.no_content` rather
/// than magic numbers.
pub const Response = struct {
    status: std.http.Status,

    pub fn ok(self: Response) bool {
        return self.status == .ok;
    }
};

/// One bounded request, with a trust store. `null` means the deadline elapsed
/// and the request was cancelled.
///
/// Leave `req.tls` unset: this fills it in with a per-call CA bundle.
/// Nothing outlives the call (zurl joins its worker before returning).
pub fn fetch(gpa: Allocator, io: Io, req: zurl.FetchRequest) !?Response {
    // This function owns `.tls`; setting it is programmer misuse.
    std.debug.assert(req.tls == null);

    const secure = std.mem.startsWith(u8, req.url, "https://");

    // Loaded per call; every caller is a one-shot or a 30s poll.
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
        // Log the error name so a nightly says which failure it was.
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

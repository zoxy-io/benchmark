//! The single choke point for keeping addresses out of anything that leaves the
//! fleet.
//!
//! Every artifact this harness produces is published: report.html is attached to
//! a public Discord channel and served from a public GitHub Pages site, and the
//! raw run data goes up alongside it. The old harness leaked in several places
//! at once — meta.json recorded the loadgen's public IP in its `prom` key,
//! zrk's per-run summary embedded the proxy's private address in a `target.url`,
//! and the driver printed both to stdout where they landed in any pasted
//! terminal log.
//!
//! Rather than rely on remembering to strip addresses at each site, `assertNoIps`
//! is called on every artifact before it is written and on the Discord body
//! before it is posted. That turns "we were careful" into a checkable invariant
//! with a test, and it fails the run rather than publishing.

const std = @import("std");

/// Addresses registered for scrubbing from log output. Small and fixed: the
/// three fleet members plus whatever an operator adds.
var table: [16][]const u8 = undefined;
var table_len: usize = 0;
var table_buf: [16][64]u8 = undefined;

/// Whether to emit GitHub Actions `::add-mask::` directives on `register`.
/// Set once at startup from the environment rather than read here, so this
/// module has no hidden dependency on process state.
var ci_masking = false;

pub fn setCiMasking(on: bool) void {
    ci_masking = on;
}

/// Register an address so `log` scrubs it. Under CI this also emits GitHub
/// Actions' `::add-mask::`, which makes the runner redact the value from every
/// subsequent log line — including ones this module never sees, such as a child
/// process's stderr.
pub fn register(addr: []const u8) void {
    if (addr.len == 0 or addr.len > 63) return;
    for (table[0..table_len]) |existing| {
        if (std.mem.eql(u8, existing, addr)) return;
    }
    if (table_len == table.len) return;

    @memcpy(table_buf[table_len][0..addr.len], addr);
    table[table_len] = table_buf[table_len][0..addr.len];
    table_len += 1;

    if (ci_masking) {
        // GitHub masks the value in the add-mask line itself, so emitting it
        // here does not leak it.
        std.debug.print("::add-mask::{s}\n", .{addr});
    }
}

pub fn reset() void {
    table_len = 0;
    ci_masking = false;
}

/// Write to stderr with every registered address replaced by a placeholder.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch {
        std.debug.print("bench: <log line too long>\n", .{});
        return;
    };
    var scrubbed: [4096]u8 = undefined;
    std.debug.print("{s}\n", .{scrub(&scrubbed, line)});
}

/// Replace each registered address with "<addr>". Returns a slice of `out`, or
/// the input unchanged when nothing matched and no copy was needed.
pub fn scrub(out: []u8, text: []const u8) []const u8 {
    if (table_len == 0) return text;

    var len: usize = 0;
    var i: usize = 0;
    outer: while (i < text.len) {
        for (table[0..table_len]) |addr| {
            if (std.mem.startsWith(u8, text[i..], addr)) {
                const rep = "<addr>";
                if (len + rep.len > out.len) break :outer;
                @memcpy(out[len..][0..rep.len], rep);
                len += rep.len;
                i += addr.len;
                continue :outer;
            }
        }
        if (len == out.len) break;
        out[len] = text[i];
        len += 1;
        i += 1;
    }
    return out[0..len];
}

pub const IpLeak = struct {
    offset: usize,
    text: []const u8,
};

var last_leak: ?IpLeak = null;

/// The offending match from the most recent `assertNoIps` failure, for building
/// an error message. Only valid immediately after the error.
pub fn lastLeak() ?IpLeak {
    return last_leak;
}

/// Fail if `text` contains anything shaped like an IPv4 address.
///
/// Deliberately blunt: it does not try to distinguish a private address from a
/// public one, or an address from a version string, because the cost of a false
/// positive (a developer adjusts one string) is far below the cost of a false
/// negative (a published report carries a host address forever). Callers that
/// legitimately contain dotted quads — there are none among the artifacts today
/// — would need an explicit exemption rather than a looser check.
pub fn assertNoIps(what: []const u8, text: []const u8) !void {
    last_leak = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isDigit(text[i])) continue;
        // Only consider a match at a token boundary, so the "1.2.3.4" inside
        // "v1.2.3.4" is still caught but "10" in "x10" does not start a scan.
        if (i > 0 and (std.ascii.isDigit(text[i - 1]) or text[i - 1] == '.')) continue;
        if (matchDottedQuad(text[i..])) |len| {
            last_leak = .{ .offset = i, .text = text[i .. i + len] };
            std.debug.print(
                "bench: refusing to write {s}: it contains what looks like an IP address at byte {d}\n",
                .{ what, i },
            );
            return error.IpLeak;
        }
    }
}

/// Length of a dotted quad at the start of `s`, or null. Each octet is 1-3
/// digits with a value <= 255, and the match must not be followed by a digit or
/// a dot (so a five-group version string is not mistaken for an address).
fn matchDottedQuad(s: []const u8) ?usize {
    var i: usize = 0;
    var octet: usize = 0;
    while (octet < 4) : (octet += 1) {
        if (octet > 0) {
            if (i >= s.len or s[i] != '.') return null;
            i += 1;
        }
        const start = i;
        var value: u32 = 0;
        while (i < s.len and std.ascii.isDigit(s[i]) and i - start < 3) : (i += 1) {
            value = value * 10 + (s[i] - '0');
        }
        if (i == start) return null;
        if (value > 255) return null;
    }
    if (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) return null;
    return i;
}

test "assertNoIps catches private and public addresses" {
    // The two real leaks from the old harness.
    try std.testing.expectError(error.IpLeak, assertNoIps(
        "summary",
        "{\"target\":{\"url\":\"http://10.10.0.27:8080/1k\"}}",
    ));
    try std.testing.expectError(error.IpLeak, assertNoIps(
        "meta",
        "{\"prom\":\"http://111.88.241.138:9090\"}",
    ));
}

test "assertNoIps passes a clean report" {
    try assertNoIps("report", "{\"runid\":\"20260728-000102\",\"sustained\":43120}");
    try assertNoIps("report", "p99 was 1.10ms at 8000 req/s over 300s");
    try assertNoIps("empty", "");
}

test "assertNoIps does not fire on version strings or ordinary numbers" {
    // zrk 1.3.1 and semver-ish strings appear all over the artifacts.
    try assertNoIps("versions", "zrk 1.3.1, zio 0.16.0, provider 0.127.0");
    try assertNoIps("numbers", "1.2.3.4.5 is five groups, not an address");
    try assertNoIps("bignum", "999.999.999.999 has out-of-range octets");
    try assertNoIps("decimal", "0.123456");
}

test "assertNoIps reports where the match was" {
    const doc = "ok ok 192.168.1.1 tail";
    try std.testing.expectError(error.IpLeak, assertNoIps("doc", doc));
    const leak = lastLeak().?;
    try std.testing.expectEqual(@as(usize, 6), leak.offset);
    try std.testing.expectEqualStrings("192.168.1.1", leak.text);
}

test "scrub replaces registered addresses" {
    reset();
    defer reset();
    register("10.10.0.27");

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "connect <addr>:8080 failed",
        scrub(&buf, "connect 10.10.0.27:8080 failed"),
    );
}

test "scrub is a no-op when nothing is registered" {
    reset();
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("10.10.0.27", scrub(&buf, "10.10.0.27"));
}

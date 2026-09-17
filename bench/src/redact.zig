//! Keeps addresses out of published artifacts and logs. `assertNoIps` runs on
//! every artifact before write and on the Discord body before post, failing
//! the run rather than publishing a leak.

const std = @import("std");

/// Addresses registered for scrubbing from log output.
var table: [16][]const u8 = undefined;
var table_len: usize = 0;
var table_buf: [16][64]u8 = undefined;

/// Whether `register` emits GitHub Actions `::add-mask::`. Set from main, not
/// read from the environment here.
var ci_masking = false;

pub fn setCiMasking(on: bool) void {
    ci_masking = on;
}

/// Register an address so `log` scrubs it. Under CI also emits `::add-mask::`,
/// which covers output this module never sees (e.g. child stderr).
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
        // GitHub masks the add-mask line itself, so this does not leak.
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

/// Replace each registered address with "<addr>". Returns `text` unchanged when
/// nothing is registered.
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

/// The match from the last `assertNoIps` failure. Valid only right after it.
pub fn lastLeak() ?IpLeak {
    return last_leak;
}

/// Fail if `text` contains anything shaped like an IPv4 address.
/// Blunt on purpose (no private/public or version-string distinction): a false
/// positive costs one string edit, a false negative a published address.
pub fn assertNoIps(what: []const u8, text: []const u8) !void {
    last_leak = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isDigit(text[i])) continue;
        // Match only at a token boundary: "v1.2.3.4" is caught, "x10" isn't a start.
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

/// Replace every IPv4-shaped substring with "<addr>", with nothing registered.
/// For `bench wait`, which relays loadgen logs on the runner and never learns
/// the fleet's private addresses (see CONTRACT.md).
pub fn scrubAnyIp(out: []u8, text: []const u8) []const u8 {
    var len: usize = 0;
    var i: usize = 0;
    outer: while (i < text.len) {
        const boundary = i == 0 or !(std.ascii.isDigit(text[i - 1]) or text[i - 1] == '.');
        if (boundary and std.ascii.isDigit(text[i])) {
            if (matchDottedQuad(text[i..])) |match_len| {
                const rep = "<addr>";
                if (len + rep.len > out.len) break :outer;
                @memcpy(out[len..][0..rep.len], rep);
                len += rep.len;
                i += match_len;
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

/// `scrubAnyIp` over a whole document, into `arena`. Grows instead of silently
/// truncating at a fixed buffer. "<addr>" (6) is never longer than a dotted
/// quad (7+), so `line.len` bounds each line; the +8 is slack.
pub fn scrubAnyIpAlloc(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const scratch = try arena.alloc(u8, line.len + 8);
        try out.appendSlice(arena, scrubAnyIp(scratch, line));
    }
    return out.toOwnedSlice(arena);
}

/// Print `text` a line at a time, each scrubbed by `scrubAnyIp`. Per line
/// because `scrubAnyIp` truncates at its buffer end. Preserves a trailing
/// newline.
pub fn logAnyIp(text: []const u8) void {
    var scrubbed: [4096]u8 = undefined;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) std.debug.print("\n", .{});
        first = false;
        // Cap at half the buffer so the scrubbed line always fits.
        const safe = line[0..@min(line.len, scrubbed.len / 2)];
        std.debug.print("{s}", .{scrubAnyIp(&scrubbed, safe)});
    }
}

/// Length of a dotted quad (octets 1-3 digits, <= 255) at the start of `s`, or
/// null. A following digit or dot rejects the match (version strings).
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

test "scrubAnyIpAlloc removes every address and keeps the shape" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Verbatim nginx error.log line: three addresses in three positions.
    const captured =
        "2026/09/01 17:37:59 [error] 29#29: *19 connect() failed (113: Host is unreachable) " ++
        "while connecting to upstream, client: 192.168.97.1, server: , " ++
        "request: \"GET /1k HTTP/1.1\", upstream: \"http://192.168.97.4:9000/1k\", " ++
        "host: \"127.0.0.1:8080\"\n";
    const clean = try scrubAnyIpAlloc(arena, captured);
    try assertNoIps("captured", clean);
    try std.testing.expectEqualStrings(
        "2026/09/01 17:37:59 [error] 29#29: *19 connect() failed (113: Host is unreachable) " ++
            "while connecting to upstream, client: <addr>, server: , " ++
            "request: \"GET /1k HTTP/1.1\", upstream: \"http://<addr>:9000/1k\", " ++
            "host: \"<addr>:8080\"\n",
        clean,
    );
}

test "scrubAnyIpAlloc does not truncate a document past one line buffer" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Longer than `logAnyIp`'s 4 KiB scratch.
    var long: std.ArrayList(u8) = .empty;
    for (0..400) |i| try long.print(arena, "line {d} from 10.0.0.13\n", .{i});
    const clean = try scrubAnyIpAlloc(arena, long.items);
    try assertNoIps("long", clean);
    try std.testing.expect(std.mem.endsWith(u8, clean, "line 399 from <addr>\n"));
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

test "scrubAnyIp catches an address with nothing registered" {
    // Unlike `scrub`, needs no prior `register` (what `bench wait` relies on).
    reset();
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "connect <addr>:8080 failed",
        scrubAnyIp(&buf, "connect 10.10.0.27:8080 failed"),
    );
    try std.testing.expectEqualStrings(
        "<addr> and <addr>",
        scrubAnyIp(&buf, "192.168.1.1 and 8.8.8.8"),
    );
}

test "scrubAnyIp leaves version strings and ordinary numbers alone" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "zrk 1.3.1, zio 0.16.0",
        scrubAnyIp(&buf, "zrk 1.3.1, zio 0.16.0"),
    );
}

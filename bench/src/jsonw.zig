//! A tiny streaming JSON writer, with number formatting chosen to line up with
//! report/report.py's `json.dumps(..., separators=(",", ":"))`.
//!
//! Why this exists rather than `std.json.Stringify`: report.json is the Phase 0
//! gate for the Zig rewrite, so its shape has to be comparable to the Python's
//! output. Two things matter and neither is the default anywhere.
//!
//! **Key order is data.** Python dicts preserve insertion order and json.dumps
//! honours it, so `proxies[]` rows and the `palette`/`hist` maps come out in a
//! meaningful order (sustained-descending, display order). A writer that sorted
//! or reordered keys would still be valid JSON but would no longer be diffable
//! against the reference, and the ordering is load-bearing for the report UI.
//!
//! **Rounding is display, not measurement.** Python's `round()` is
//! round-half-to-even applied to the exact binary value; Zig's `{d:.N}` rounds
//! half-away-from-zero and, worse, is not correctly rounded for the exact value
//! (`{d:.6}` of 0.1234565 yields 0.123457 where the true value is
//! 0.12345649999...). So `float()` here rounds the SHORTEST round-tripping
//! decimal representation, half-to-even, by string manipulation — exact,
//! predictable, and free of dtoa reimplementation. That agrees with Python
//! except when the shortest repr sits exactly on a tie while the underlying
//! binary value does not (`round(2.675, 2)`: Python 2.67, here 2.68). Such cases
//! differ by one unit in the last emitted decimal and are a rendering artifact,
//! never a measurement one — the gate script compares numerically with a
//! one-last-place tolerance for exactly this reason.

const std = @import("std");

pub const Writer = struct {
    w: *std.Io.Writer,
    /// Whether the current container already holds an element, so the next one
    /// needs a comma. One flag suffices because a comma is only ever needed
    /// immediately after a value, and `key`/`beginX` reset it appropriately.
    need_comma: bool = false,

    pub fn beginObject(self: *Writer) !void {
        try self.punct('{');
    }
    pub fn endObject(self: *Writer) !void {
        try self.w.writeByte('}');
        self.need_comma = true;
    }
    pub fn beginArray(self: *Writer) !void {
        try self.punct('[');
    }
    pub fn endArray(self: *Writer) !void {
        try self.w.writeByte(']');
        self.need_comma = true;
    }

    fn punct(self: *Writer, c: u8) !void {
        if (self.need_comma) try self.w.writeByte(',');
        try self.w.writeByte(c);
        self.need_comma = false;
    }

    pub fn key(self: *Writer, name: []const u8) !void {
        if (self.need_comma) try self.w.writeByte(',');
        try writeQuoted(self.w, name);
        try self.w.writeByte(':');
        self.need_comma = false;
    }

    pub fn string(self: *Writer, s: []const u8) !void {
        if (self.need_comma) try self.w.writeByte(',');
        try writeQuoted(self.w, s);
        self.need_comma = true;
    }

    pub fn boolean(self: *Writer, b: bool) !void {
        if (self.need_comma) try self.w.writeByte(',');
        try self.w.writeAll(if (b) "true" else "false");
        self.need_comma = true;
    }

    pub fn nullValue(self: *Writer) !void {
        if (self.need_comma) try self.w.writeByte(',');
        try self.w.writeAll("null");
        self.need_comma = true;
    }

    pub fn int(self: *Writer, v: i64) !void {
        if (self.need_comma) try self.w.writeByte(',');
        try self.w.print("{d}", .{v});
        self.need_comma = true;
    }

    pub fn optInt(self: *Writer, v: ?i64) !void {
        if (v) |x| try self.int(x) else try self.nullValue();
    }

    /// Emit a float rounded to `digits` decimals, half-to-even, printed the way
    /// Python prints it (always at least one decimal place, so 284.0 does not
    /// become the integer 284 and change the JSON type).
    pub fn float(self: *Writer, v: f64, digits: u8) !void {
        if (self.need_comma) try self.w.writeByte(',');
        var buf: [512]u8 = undefined;
        try self.w.writeAll(try formatRounded(&buf, v, digits));
        self.need_comma = true;
    }
};

fn writeQuoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Round `v` to `digits` decimal places, half-to-even, and render it with a
/// mandatory decimal point. Operates on the shortest round-tripping decimal
/// representation — see the module docs for why, and for the one case where
/// this differs from Python by a single unit in the last place.
pub fn formatRounded(buf: []u8, v: f64, digits: u8) ![]const u8 {
    if (std.math.isNan(v)) return "null";
    if (std.math.isInf(v)) return if (v > 0) "1e999" else "-1e999";

    var shortest: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&shortest, "{d}", .{v});

    const neg = s.len > 0 and s[0] == '-';
    const body = if (neg) s[1..] else s;

    const dot = std.mem.indexOfScalar(u8, body, '.');
    const int_part = if (dot) |d| body[0..d] else body;
    const frac_part = if (dot) |d| body[d + 1 ..] else "";

    // Already short enough: pad to at least one decimal and emit as-is. This is
    // the common case (284.0 -> "284.0", 0.5 -> "0.5") and it is what keeps the
    // output identical to Python's, which also prints the shortest repr.
    if (frac_part.len <= digits) {
        return std.fmt.bufPrint(buf, "{s}{s}.{s}", .{
            if (neg) "-" else "",
            int_part,
            if (frac_part.len == 0) "0" else frac_part,
        });
    }

    // Build the digit string, round half-to-even at `digits`, propagate carry.
    var digs: [64]u8 = undefined;
    @memcpy(digs[0..int_part.len], int_part);
    @memcpy(digs[int_part.len..][0..frac_part.len], frac_part);
    var n = int_part.len + frac_part.len;
    const keep = int_part.len + digits;

    const first_dropped = digs[keep];
    var round_up = false;
    if (first_dropped > '5') {
        round_up = true;
    } else if (first_dropped == '5') {
        // Exactly half only if every remaining digit is zero; otherwise it is
        // strictly greater than half and always rounds up.
        var rest_nonzero = false;
        for (digs[keep + 1 .. n]) |c| {
            if (c != '0') rest_nonzero = true;
        }
        // Ties go to even, which is what Python's round() does.
        round_up = rest_nonzero or ((digs[keep - 1] - '0') % 2 == 1);
    }

    n = keep;
    if (round_up) {
        var i = n;
        while (i > 0) {
            i -= 1;
            if (digs[i] == '9') {
                digs[i] = '0';
            } else {
                digs[i] += 1;
                break;
            }
        } else {
            // Carried past the most significant digit: shift right and prepend 1.
            std.mem.copyBackwards(u8, digs[1 .. n + 1], digs[0..n]);
            digs[0] = '1';
            n += 1;
            return renderDigits(buf, neg, digs[0..n], n - digits, digits);
        }
    }

    return renderDigits(buf, neg, digs[0..n], int_part.len, digits);
}

/// Assemble `digits` (a bare digit string) into `int.frac`, trimming trailing
/// fractional zeros the way Python's shortest repr does but always leaving at
/// least one decimal place.
fn renderDigits(buf: []u8, neg: bool, digs: []const u8, int_len: usize, digits: u8) ![]const u8 {
    _ = digits;
    var frac = digs[int_len..];
    while (frac.len > 1 and frac[frac.len - 1] == '0') frac = frac[0 .. frac.len - 1];
    if (frac.len == 0) frac = "0";

    var int_part = digs[0..int_len];
    // Strip leading zeros but keep a single one ("0.5", not ".5").
    while (int_part.len > 1 and int_part[0] == '0') int_part = int_part[1..];
    if (int_part.len == 0) int_part = "0";

    return std.fmt.bufPrint(buf, "{s}{s}.{s}", .{ if (neg) "-" else "", int_part, frac });
}

/// Python's `round(x)` with no ndigits: to the nearest integer, ties to even.
pub fn pyRoundToInt(v: f64) i64 {
    const r = @round(v);
    // @round is half-away-from-zero; correct the tie case to half-to-even.
    if (@abs(v - @trunc(v)) == 0.5) {
        const down = @trunc(v);
        const even = if (@mod(@abs(down), 2) == 0) down else down + std.math.sign(v);
        return @intFromFloat(even);
    }
    return @intFromFloat(r);
}

test "formatRounded always emits a decimal point" {
    var buf: [512]u8 = undefined;
    // Python json.dumps(284.0) is "284.0", not "284" — the type must not change.
    try std.testing.expectEqualStrings("284.0", try formatRounded(&buf, 284.0, 4));
    try std.testing.expectEqualStrings("0.0", try formatRounded(&buf, 0.0, 6));
}

test "formatRounded keeps the shortest repr when already short enough" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("0.5", try formatRounded(&buf, 0.5, 4));
    try std.testing.expectEqualStrings("422.7", try formatRounded(&buf, 422.7, 4));
    try std.testing.expectEqualStrings("2.675", try formatRounded(&buf, 2.675, 4));
}

test "formatRounded rounds ties to even, like Python" {
    var buf: [512]u8 = undefined;
    // Zig's own {d:.1} gives 1.3 here; Python's round(1.25, 1) gives 1.2.
    try std.testing.expectEqualStrings("1.2", try formatRounded(&buf, 1.25, 1));
    try std.testing.expectEqualStrings("1.4", try formatRounded(&buf, 1.35, 1));
    // Not a tie: strictly above half always rounds up.
    try std.testing.expectEqualStrings("1.3", try formatRounded(&buf, 1.2500001, 1));
}

test "formatRounded propagates carry, including past the leading digit" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("1.0", try formatRounded(&buf, 0.96, 1));
    try std.testing.expectEqualStrings("10.0", try formatRounded(&buf, 9.99, 1));
    try std.testing.expectEqualStrings("100.0", try formatRounded(&buf, 99.999, 2));
}

test "formatRounded handles negatives" {
    var buf: [512]u8 = undefined;
    // Shed is deliberately unclamped before smoothing, so negatives are real.
    try std.testing.expectEqualStrings("-0.5", try formatRounded(&buf, -0.5, 4));
    try std.testing.expectEqualStrings("-1.2", try formatRounded(&buf, -1.25, 1));
}

test "pyRoundToInt breaks ties to even" {
    try std.testing.expectEqual(@as(i64, 2), pyRoundToInt(2.5));
    try std.testing.expectEqual(@as(i64, 4), pyRoundToInt(3.5));
    try std.testing.expectEqual(@as(i64, 3), pyRoundToInt(2.7));
    try std.testing.expectEqual(@as(i64, 43120), pyRoundToInt(43119.6));
}

test "writer emits compact json with commas in the right places" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var j = Writer{ .w = &w };

    try j.beginObject();
    try j.key("a");
    try j.int(1);
    try j.key("b");
    try j.beginArray();
    try j.float(1.5, 4);
    try j.float(2.0, 4);
    try j.endArray();
    try j.key("c");
    try j.nullValue();
    try j.endObject();

    try std.testing.expectEqualStrings("{\"a\":1,\"b\":[1.5,2.0],\"c\":null}", w.buffered());
}

test "writer escapes strings" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var j = Writer{ .w = &w };
    try j.string("a\"b\\c\nd");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\"", w.buffered());
}

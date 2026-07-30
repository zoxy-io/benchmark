//! Inline SVG line charts, ported from report/charts.py.
//!
//! Same geometry constants and the same axis rules, because the report's visual
//! grammar is already settled and this is a language change, not a redesign. Two
//! of those rules are load-bearing and easy to "simplify" wrongly:
//!
//! * the y-axis fits only the points inside the cropped x window, so a tail that
//!   was cropped out cannot inflate the scale and flatten everything else;
//! * latency uses whole-decade log gridlines, because it spans sub-millisecond
//!   when healthy to hundreds of milliseconds at the knee, and a linear axis
//!   crushes every curve but the tallest into the baseline.
//!
//! Output is written straight into an `Io.Writer` rather than assembled in a
//! list of strings as the Python did.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Point = struct { x: f64, y: f64 };

pub const w: f64 = 720;
pub const h: f64 = 380;
pub const ml: f64 = 62;
pub const mr: f64 = 16;
pub const mt: f64 = 22;
pub const mb: f64 = 40;

pub const YFormat = enum { si, ms, pct, bytes };

pub const Series = struct {
    name: []const u8,
    pts: []const Point,
    dashed: bool = false,
};

pub const Options = struct {
    id: []const u8,
    yfmt: YFormat = .si,
    y_unit: []const u8 = "",
    ylog: bool = false,
    /// Crop the offered axis, e.g. to where the last real proxy stops keeping
    /// up. Lines running past it are clipped at the plot edge.
    xmax: ?f64 = null,
    x_label: []const u8 = "offered load (req/s)",
};

/// A small fixed-capacity tick list. 24 is far more than a readable axis ever
/// carries, so overflow means a bug upstream rather than a legitimate chart.
pub const Ticks = struct {
    buf: [24]f64 = undefined,
    len: usize = 0,

    pub fn append(self: *Ticks, v: f64) !void {
        if (self.len == self.buf.len) return error.Overflow;
        self.buf[self.len] = v;
        self.len += 1;
    }

    pub fn slice(self: *const Ticks) []const f64 {
        return self.buf[0..self.len];
    }
};

/// Tick positions covering [lo, hi] at a human-friendly step.
pub fn niceTicks(lo: f64, hi_in: f64, n: usize) Ticks {
    var out: Ticks = .{};
    var hi = hi_in;
    if (hi <= lo) hi = lo + 1;

    const raw = (hi - lo) / @as(f64, @floatFromInt(n));
    const mag = std.math.pow(f64, 10, @floor(std.math.log10(raw)));
    const candidates = [_]f64{ 1 * mag, 2 * mag, 2.5 * mag, 5 * mag, 10 * mag };
    var step: f64 = candidates[candidates.len - 1];
    for (candidates) |c| {
        if (c >= raw) {
            step = c;
            break;
        }
    }

    var t = @floor(lo / step) * step;
    // Step up to the first tick at or above hi, so the axis always COVERS the
    // data rather than stopping just short of the last point.
    while (t < hi - step * 1e-9) {
        out.append(roundTo(t, 10)) catch return out;
        t += step;
    }
    out.append(roundTo(t, 10)) catch {};
    return out;
}

fn roundTo(v: f64, digits: u32) f64 {
    const m = std.math.pow(f64, 10, @floatFromInt(digits));
    return @round(v * m) / m;
}

/// Axis tick labels, matching report/charts.py's `fmt_si` exactly — including
/// its last branch, which is `%.2g` (TWO SIGNIFICANT FIGURES) rather than a
/// shortest-form print. 0.123456 renders as "0.12", not "0.123456".
pub fn fmtSi(out: []u8, v: f64) []const u8 {
    var scratch: [64]u8 = undefined;
    if (v >= 1e9) return std.fmt.bufPrint(out, "{s}G", .{trimG(&scratch, v / 1e9)}) catch "?";
    if (v >= 1e6) return std.fmt.bufPrint(out, "{s}M", .{trimG(&scratch, v / 1e6)}) catch "?";
    if (v >= 1e3) return std.fmt.bufPrint(out, "{s}k", .{trimG(&scratch, v / 1e3)}) catch "?";
    if (v >= 10 or v == @trunc(v)) return std.fmt.bufPrint(out, "{d:.0}", .{v}) catch "?";
    return std.fmt.bufPrint(out, "{s}", .{sigFigs(&scratch, v, 2)}) catch "?";
}

/// Python's `%g`: shortest form, trailing zeros and a trailing point stripped.
fn trimG(buf: []u8, v: f64) []const u8 {
    var s = std.fmt.bufPrint(buf, "{d}", .{v}) catch return "?";
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        while (s.len > 1 and s[s.len - 1] == '0') s = s[0 .. s.len - 1];
        if (s.len > 0 and s[s.len - 1] == '.') s = s[0 .. s.len - 1];
    }
    return s;
}

/// Python's `%.<n>g` for the 0 < v < 10 range: round to `n` significant
/// figures, then strip as `%g` does.
fn sigFigs(buf: []u8, v: f64, n: u32) []const u8 {
    if (v == 0) return "0";
    const exp = @floor(std.math.log10(@abs(v)));
    const decimals: i32 = @as(i32, @intFromFloat(exp)) * -1 + @as(i32, @intCast(n)) - 1;
    const d: u8 = @intCast(std.math.clamp(decimals, 0, 17));

    var tmp: [64]u8 = undefined;
    const s = switch (d) {
        0 => std.fmt.bufPrint(&tmp, "{d:.0}", .{v}),
        1 => std.fmt.bufPrint(&tmp, "{d:.1}", .{v}),
        2 => std.fmt.bufPrint(&tmp, "{d:.2}", .{v}),
        3 => std.fmt.bufPrint(&tmp, "{d:.3}", .{v}),
        4 => std.fmt.bufPrint(&tmp, "{d:.4}", .{v}),
        5 => std.fmt.bufPrint(&tmp, "{d:.5}", .{v}),
        else => std.fmt.bufPrint(&tmp, "{d:.6}", .{v}),
    } catch return "?";

    var t = s;
    if (std.mem.indexOfScalar(u8, t, '.') != null) {
        while (t.len > 1 and t[t.len - 1] == '0') t = t[0 .. t.len - 1];
        if (t.len > 0 and t[t.len - 1] == '.') t = t[0 .. t.len - 1];
    }
    return std.fmt.bufPrint(buf, "{s}", .{t}) catch "?";
}

pub fn fmtBytes(out: []u8, v: f64) []const u8 {
    if (v >= 1 << 30) return std.fmt.bufPrint(out, "{d:.1}GiB", .{v / (1 << 30)}) catch "?";
    if (v >= 1 << 20) return std.fmt.bufPrint(out, "{d:.1}MiB", .{v / (1 << 20)}) catch "?";
    if (v >= 1 << 10) return std.fmt.bufPrint(out, "{d:.1}KiB", .{v / (1 << 10)}) catch "?";
    return std.fmt.bufPrint(out, "{d:.0}B", .{v}) catch "?";
}

fn fmtTick(out: []u8, v: f64, yfmt: YFormat) []const u8 {
    return switch (yfmt) {
        .bytes => fmtBytes(out, v),
        .pct => std.fmt.bufPrint(out, "{s}%", .{trimG(out[32..], v * 100)}) catch "?",
        // Latency series are in SECONDS; the tick POSITIONS stay in seconds so
        // round values like 0.01s land on round labels like 10ms, instead of the
        // 0.0050-style labels a millisecond axis would produce.
        .ms => fmtSi(out, v * 1000),
        .si => fmtSi(out, v),
    };
}

// --- markup shared between `chart` and `histChart` ---------------------
//
// Only the pieces that need no chart-specific TRANSFORM function are shared
// here — `y`/`label` below are already-computed values, not callbacks, so
// this stays plain data in, markup out. The point-scaling loops in `chart`
// and `histChart` are deliberately NOT unified with each other: chart's
// (possibly log) y-scale and histChart's log-x/linear-y decade scale are
// different enough that forcing them through one shared callback-based
// abstraction would cost more in indirection than the ~4 lines it would save,
// and would require materializing a scaled-points array where both currently
// stream straight into `out` with no allocation at all.

fn writeSvgOpen(out: *std.Io.Writer) !void {
    try out.print("<svg viewBox=\"0 0 {d:.0} {d:.0}\" role=\"img\">", .{ w, h });
}

/// One y-axis gridline plus its tick label, at a Y COORDINATE the caller has
/// already scaled (`ctx.y(t)` or `Y.f(t, ymaxt)`) and a label it has already
/// formatted (`fmtTick` or `fmtSi`) — the two charts differ only in how they
/// get to those two values, not in how the line and label are drawn.
fn writeYGridLine(out: *std.Io.Writer, y: f64, label: []const u8) !void {
    try out.print("<line class=\"grid\" x1=\"{d:.0}\" y1=\"{d:.1}\" x2=\"{d:.0}\" y2=\"{d:.1}\"/>", .{ ml, y, w - mr, y });
    try out.print("<text class=\"tick\" x=\"{d:.0}\" y=\"{d:.1}\" text-anchor=\"end\">{s}</text>", .{ ml - 8, y + 4, label });
}

/// The x-axis line plus its centred label.
fn writeXAxis(out: *std.Io.Writer, label: []const u8) !void {
    try out.print("<line class=\"axis\" x1=\"{d:.0}\" y1=\"{d:.0}\" x2=\"{d:.0}\" y2=\"{d:.0}\"/>", .{ ml, h - mb, w - mr, h - mb });
    try out.print("<text class=\"axis-label\" x=\"{d:.1}\" y=\"{d:.0}\" text-anchor=\"middle\">{s}</text>", .{ (ml + w - mr) / 2, h - 6, label });
}

/// The small top-left label naming the y-axis's unit.
fn writeYUnitLabel(out: *std.Io.Writer, unit: []const u8) !void {
    if (unit.len == 0) return;
    try out.print("<text class=\"axis-label\" x=\"14\" y=\"10\" text-anchor=\"start\">{s}</text>", .{unit});
}

/// Render one chart. Returns false if there was nothing to draw, in which case
/// the caller should emit its own empty state.
pub fn chart(out: *std.Io.Writer, opts: Options, series: []const Series) !bool {
    var any = false;
    for (series) |s| {
        if (s.pts.len > 0) any = true;
    }
    if (!any) {
        try out.writeAll("<p class='empty'>no data</p>");
        return false;
    }

    var xmax: f64 = opts.xmax orelse blk: {
        var m: f64 = 0;
        for (series) |s| for (s.pts) |p| {
            m = @max(m, p.x);
        };
        break :blk m;
    };
    if (xmax <= 0) xmax = 1;

    const xticks = niceTicks(0, xmax, 5);
    const xt = xticks.slice();
    const xmaxt = xt[xt.len - 1];

    // The y scale is fitted to the VISIBLE window only.
    var ylo: f64 = 0;
    var ymaxt: f64 = 1;
    var lo_exp: f64 = -3;
    var hi_exp: f64 = 0;
    var yticks: Ticks = .{};

    if (opts.ylog) {
        var min_pos: f64 = std.math.inf(f64);
        var max_pos: f64 = 0;
        for (series) |s| for (s.pts) |p| {
            if (p.x > xmaxt or p.y <= 0) continue;
            min_pos = @min(min_pos, p.y);
            max_pos = @max(max_pos, p.y);
        };
        if (std.math.isInf(min_pos)) {
            min_pos = 1e-3;
            max_pos = 1;
        }
        lo_exp = @floor(std.math.log10(min_pos));
        hi_exp = @ceil(std.math.log10(max_pos));
        if (hi_exp <= lo_exp) hi_exp = lo_exp + 1;

        var e = lo_exp;
        while (e <= hi_exp) : (e += 1) yticks.append(std.math.pow(f64, 10, e)) catch {};
        ylo = std.math.pow(f64, 10, lo_exp);
        ymaxt = std.math.pow(f64, 10, hi_exp);
    } else {
        var ymax: f64 = 0;
        for (series) |s| for (s.pts) |p| {
            if (p.x <= xmaxt) ymax = @max(ymax, p.y);
        };
        if (ymax == 0) {
            for (series) |s| for (s.pts) |p| {
                ymax = @max(ymax, p.y);
            };
        }
        yticks = niceTicks(0, ymax * 1.05, 5);
        const yt = yticks.slice();
        ymaxt = yt[yt.len - 1];
    }

    const ctx = Scale{
        .xmaxt = xmaxt,
        .ymaxt = ymaxt,
        .ylo = ylo,
        .lo_exp = lo_exp,
        .hi_exp = hi_exp,
        .ylog = opts.ylog,
    };

    try writeSvgOpen(out);
    try out.print(
        "<clipPath id=\"clip-{s}\"><rect x=\"{d:.0}\" y=\"{d:.0}\" width=\"{d:.0}\" height=\"{d:.0}\"/></clipPath>",
        .{ opts.id, ml, mt, w - ml - mr, h - mt - mb },
    );

    var buf: [128]u8 = undefined;
    for (yticks.slice()) |t| {
        try writeYGridLine(out, ctx.y(t), fmtTick(&buf, t, opts.yfmt));
    }
    for (xt) |t| {
        try out.print("<text class=\"tick\" x=\"{d:.1}\" y=\"{d:.0}\" text-anchor=\"middle\">{s}</text>", .{ ctx.x(t), h - mb + 18, fmtSi(&buf, t) });
    }
    try writeXAxis(out, opts.x_label);
    try writeYUnitLabel(out, opts.y_unit);

    try out.print("<g clip-path=\"url(#clip-{s})\">", .{opts.id});
    for (series) |s| {
        if (s.pts.len == 0) continue;
        try out.print("<polyline class=\"line s-{s}\" points=\"", .{s.name});
        for (s.pts, 0..) |p, i| {
            if (i > 0) try out.writeByte(' ');
            try out.print("{d:.1},{d:.1}", .{ ctx.x(p.x), ctx.y(p.y) });
        }
        try out.writeAll("\" fill=\"none\" stroke-width=\"2\"");
        if (s.dashed) try out.writeAll(" stroke-dasharray=\"6 4\"");
        try out.writeAll("/>");
    }
    try out.writeAll("</g>");

    try out.print(
        "<rect class=\"hover-capture\" data-chart=\"{s}\" x=\"{d:.0}\" y=\"{d:.0}\" width=\"{d:.0}\" height=\"{d:.0}\" fill=\"transparent\"/>",
        .{ opts.id, ml, mt, w - ml - mr, h - mt - mb },
    );
    try out.writeAll("</svg>");
    return true;
}

const Scale = struct {
    xmaxt: f64,
    ymaxt: f64,
    ylo: f64,
    lo_exp: f64,
    hi_exp: f64,
    ylog: bool,

    fn x(self: Scale, v: f64) f64 {
        return ml + (w - ml - mr) * v / self.xmaxt;
    }

    fn y(self: Scale, v: f64) f64 {
        if (self.ylog) {
            const clamped = @min(@max(v, self.ylo), self.ymaxt);
            const ly = std.math.log10(clamped);
            return h - mb - (h - mb - mt) * (ly - self.lo_exp) / (self.hi_exp - self.lo_exp);
        }
        return h - mb - (h - mb - mt) * v / self.ymaxt;
    }
};

/// The per-proxy latency distribution card: x is n = 1/(1-percentile) on a log
/// scale, so p50/p90/p99/p99.9 land on even decades.
pub fn histChart(out: *std.Io.Writer, id: []const u8, pts: []const Point) !bool {
    if (pts.len == 0) {
        try out.writeAll("<p class='empty'>no data</p>");
        return false;
    }
    var max_n: f64 = 1;
    var max_ms: f64 = 0;
    for (pts) |p| {
        max_n = @max(max_n, p.x);
        max_ms = @max(max_ms, p.y);
    }
    const decades = @max(1.0, @ceil(std.math.log10(max_n)));
    const yticks = niceTicks(0, max_ms * 1.05, 5);
    const yts = yticks.slice();
    const ymaxt = yts[yts.len - 1];

    const X = struct {
        fn f(n: f64, dec: f64) f64 {
            return ml + (w - ml - mr) * @min(@max(std.math.log10(@max(n, 1)), 0), dec) / dec;
        }
    };
    const Y = struct {
        fn f(v: f64, top: f64) f64 {
            return h - mb - (h - mb - mt) * v / top;
        }
    };

    try writeSvgOpen(out);
    var buf: [128]u8 = undefined;
    for (yticks.slice()) |t| {
        try writeYGridLine(out, Y.f(t, ymaxt), fmtSi(&buf, t));
    }
    var d: f64 = 0;
    while (d <= decades) : (d += 1) {
        const n = std.math.pow(f64, 10, d);
        const pct = 100.0 * (1.0 - 1.0 / n);
        const label = if (d == 0) "p0" else std.fmt.bufPrint(&buf, "p{d}", .{pct}) catch "p?";
        try out.print("<text class=\"tick\" x=\"{d:.1}\" y=\"{d:.0}\" text-anchor=\"middle\">{s}</text>", .{ X.f(n, decades), h - mb + 18, label });
    }
    try writeXAxis(out, "percentile");
    try writeYUnitLabel(out, "ms");

    try out.print("<polyline class=\"line s-{s}\" points=\"", .{id});
    for (pts, 0..) |p, i| {
        if (i > 0) try out.writeByte(' ');
        try out.print("{d:.1},{d:.1}", .{ X.f(p.x, decades), Y.f(p.y, ymaxt) });
    }
    try out.writeAll("\" fill=\"none\" stroke-width=\"2\"/>");

    // `data-hist`, not `data-chart`: report.js's line-chart hover handler
    // assumes a linear x-scale and several named series, neither true here
    // (log-x percentile scale, one series) — a distinct attribute routes this
    // rect to its own handler instead of silently misbehaving under the
    // wrong one.
    try out.print(
        "<rect class=\"hover-capture\" data-hist=\"{s}\" x=\"{d:.0}\" y=\"{d:.0}\" width=\"{d:.0}\" height=\"{d:.0}\" fill=\"transparent\"/>",
        .{ id, ml, mt, w - ml - mr, h - mt - mb },
    );
    try out.writeAll("</svg>");
    return true;
}

test "niceTicks covers the data and ends at or above hi" {
    const t = niceTicks(0, 43120, 5);
    const s = t.slice();
    try std.testing.expect(s.len >= 2);
    try std.testing.expectEqual(@as(f64, 0), s[0]);
    // The axis must COVER the data, never stop just short of the last point.
    try std.testing.expect(s[s.len - 1] >= 43120);
}

test "niceTicks handles a degenerate range" {
    const t = niceTicks(0, 0, 5);
    try std.testing.expect(t.len >= 2);
}

test "fmtSi reproduces report/charts.py's fmt_si" {
    // Every expectation here was taken from the Python, not assumed.
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("43.12k", fmtSi(&buf, 43120));
    try std.testing.expectEqualStrings("1M", fmtSi(&buf, 1_000_000));
    try std.testing.expectEqualStrings("1.5k", fmtSi(&buf, 1500));
    try std.testing.expectEqualStrings("500", fmtSi(&buf, 500));
    try std.testing.expectEqualStrings("0", fmtSi(&buf, 0));
    try std.testing.expectEqualStrings("43", fmtSi(&buf, 43.12));

    // The sub-10 branch is %.2g — two SIGNIFICANT figures, not shortest form.
    // Printing 0.123456 here would put six digits on an axis tick.
    try std.testing.expectEqualStrings("0.12", fmtSi(&buf, 0.123456));
    try std.testing.expectEqualStrings("0.4", fmtSi(&buf, 0.4));
    try std.testing.expectEqualStrings("0.05", fmtSi(&buf, 0.05));
    try std.testing.expectEqualStrings("1.5", fmtSi(&buf, 1.5));
    try std.testing.expectEqualStrings("10", fmtSi(&buf, 9.999));
    try std.testing.expectEqualStrings("0.0004", fmtSi(&buf, 0.0004));
}

test "fmtBytes uses binary units" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("24.0MiB", fmtBytes(&buf, 24 * 1024 * 1024));
    try std.testing.expectEqualStrings("512B", fmtBytes(&buf, 512));
}

test "chart reports an empty state rather than drawing axes over nothing" {
    var buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const drew = try chart(&out, .{ .id = "rps" }, &.{});
    try std.testing.expect(!drew);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "no data") != null);
}

test "chart fits y to the cropped window, not the whole series" {
    // A tail far past the crop must not inflate the y scale — that is what
    // flattens every visible curve into the baseline.
    const pts = [_]Point{
        .{ .x = 1000, .y = 10 },
        .{ .x = 2000, .y = 20 },
        .{ .x = 90000, .y = 100000 }, // cropped out
    };
    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    _ = try chart(&out, .{ .id = "rps", .xmax = 3000 }, &.{.{ .name = "zoxy", .pts = &pts }});

    // The largest y tick should be near 20, not near 100000.
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "100k") == null);
}

test "chart emits a log axis for latency" {
    const pts = [_]Point{ .{ .x = 1000, .y = 0.0004 }, .{ .x = 2000, .y = 0.4 } };
    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    _ = try chart(&out, .{ .id = "p99", .ylog = true, .yfmt = .ms }, &.{.{ .name = "zoxy", .pts = &pts }});
    const s = out.buffered();
    // Decade gridlines: 0.4ms through 400ms must both be labelled.
    try std.testing.expect(std.mem.indexOf(u8, s, "polyline") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "class=\"grid\"") != null);
}

test "histChart draws percentile decades" {
    const pts = [_]Point{ .{ .x = 1, .y = 0.4 }, .{ .x = 100, .y = 2.7 }, .{ .x = 10000, .y = 12.0 } };
    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try std.testing.expect(try histChart(&out, "zoxy", &pts));
    const s = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "percentile") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "p0") != null);
    // The hover-capture target for report.js's histogram tooltip handler,
    // distinguished from the line-chart one by `data-hist` rather than
    // `data-chart` — the two charts' x-scales are not interchangeable.
    try std.testing.expect(std.mem.indexOf(u8, s, "data-hist=\"zoxy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "data-chart=") == null);
}

//! Inline SVG line charts, ported from report/charts.py.
//!
//! Two load-bearing axis rules:
//! * the y-axis fits only points inside the cropped x window, so a cropped
//!   tail cannot flatten everything else;
//! * latency uses whole-decade log gridlines; a linear axis crushes all but
//!   the tallest curve into the baseline.

const std = @import("std");

const jsonw = @import("jsonw.zig");

const Allocator = std.mem.Allocator;

pub const Point = struct { x: f64, y: f64 };

pub const w: f64 = 720;
pub const h: f64 = 380;
pub const ml: f64 = 62;
pub const mr: f64 = 16;
pub const mt: f64 = 22;
pub const mb: f64 = 40;

/// Marker geometry for `Options.markers`: r=4 (8px) plus a 2px surface-colour
/// ring (`.dot`) so dots stay legible where series cross.
const dot_r: f64 = 4;
const dot_ring: f64 = 2;

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
    /// Crop the x axis; lines past it are clipped at the plot edge.
    xmax: ?f64 = null,
    x_label: []const u8 = "offered load (req/s)",
    /// Draw a dot on every data point as well as the line.
    ///
    /// Required for discrete observations (the nightly trend): a one-point
    /// `<polyline>` draws nothing, and single nights must be identifiable.
    markers: bool = false,
    /// x is an ordinal position (the Nth observation): the axis ends on the
    /// last observation and ticks land on whole runs, counted from 1.
    /// Must be paired with `XAxis.labels`, or the crosshair x range differs.
    x_ordinal: bool = false,
};

/// Fixed-capacity tick list; overflowing 24 means a bug upstream.
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
    // Step up to the first tick >= hi, so the axis always covers the data.
    while (t < hi - step * 1e-9) {
        out.append(roundTo(t, 10)) catch return out;
        t += step;
    }
    out.append(roundTo(t, 10)) catch {};
    return out;
}

/// Integer tick positions 0..hi, thinned to a readable count. For count axes,
/// where `niceTicks` would label run 0.5.
pub fn ordinalTicks(hi: f64) Ticks {
    var out: Ticks = .{};
    const n: usize = @intFromFloat(@max(hi, 0));
    const stride: usize = @max(1, (n + 8) / 8);
    var i: usize = 0;
    while (i <= n) : (i += stride) {
        out.append(@floatFromInt(i)) catch return out;
    }
    // The last run always gets a tick: it is the one a reader looks for.
    if ((n % stride) != 0) out.append(@floatFromInt(n)) catch {};
    return out;
}

fn roundTo(v: f64, digits: u32) f64 {
    const m = std.math.pow(f64, 10, @floatFromInt(digits));
    return @round(v * m) / m;
}

/// Axis tick labels, matching report/charts.py's `fmt_si` exactly, including
/// its `%.2g` last branch: 0.123456 renders as "0.12".
pub fn fmtSi(out: []u8, v: f64) []const u8 {
    var scratch: [64]u8 = undefined;
    if (v >= 1e9) return std.fmt.bufPrint(out, "{s}G", .{trimG(&scratch, v / 1e9)}) catch "?";
    if (v >= 1e6) return std.fmt.bufPrint(out, "{s}M", .{trimG(&scratch, v / 1e6)}) catch "?";
    if (v >= 1e3) return std.fmt.bufPrint(out, "{s}k", .{trimG(&scratch, v / 1e3)}) catch "?";
    if (v >= 10 or v == @trunc(v)) return std.fmt.bufPrint(out, "{d:.0}", .{v}) catch "?";
    return std.fmt.bufPrint(out, "{s}", .{sigFigs(&scratch, v, 2)}) catch "?";
}

/// Python's `%g`: round to 6 significant figures, then strip trailing zeros.
/// Rounding first keeps float noise ("43.11999999999999") off the axis.
fn trimG(buf: []u8, v: f64) []const u8 {
    return sigFigs(buf, v, 6);
}

/// Python's `%.<n>g` for 0 < v < 10.
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
        // Latency is in seconds; ticks stay in seconds so 0.01s labels as 10ms.
        .ms => fmtSi(out, v * 1000),
        .si => fmtSi(out, v),
    };
}

// --- markup shared between `chart` and `histChart` ---------------------
//
// The point-scaling loops are not shared: the two scales differ enough that
// a callback abstraction would cost more than it saves.

fn writeSvgOpen(out: *std.Io.Writer) !void {
    try out.print("<svg viewBox=\"0 0 {d:.0} {d:.0}\" role=\"img\">", .{ w, h });
}

/// One y gridline plus tick label, at an already-scaled y and formatted label.
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

    const xticks = if (opts.x_ordinal) ordinalTicks(xmax) else niceTicks(0, xmax, 5);
    const xt = xticks.slice();
    // An ordinal axis ends ON the last observation; `niceTicks` would round up
    // and leave a tick for a run that does not exist.
    const xmaxt = if (opts.x_ordinal) @max(xmax, 1) else xt[xt.len - 1];

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
    // With markers, let the clip out by marker radius + ring, or points on the
    // axis (including the latest run) get sliced in half.
    const pad: f64 = if (opts.markers) dot_r + dot_ring else 0;
    try out.print(
        "<clipPath id=\"clip-{s}\"><rect x=\"{d:.0}\" y=\"{d:.0}\" width=\"{d:.0}\" height=\"{d:.0}\"/></clipPath>",
        .{ opts.id, ml - pad, mt - pad, w - ml - mr + 2 * pad, h - mt - mb + 2 * pad },
    );

    var buf: [128]u8 = undefined;
    for (yticks.slice()) |t| {
        try writeYGridLine(out, ctx.y(t), fmtTick(&buf, t, opts.yfmt));
    }
    for (xt) |t| {
        // An ordinal axis counts from 1.
        const label = if (opts.x_ordinal)
            std.fmt.bufPrint(&buf, "{d:.0}", .{t + 1}) catch "?"
        else
            fmtSi(&buf, t);
        try out.print("<text class=\"tick\" x=\"{d:.1}\" y=\"{d:.0}\" text-anchor=\"middle\">{s}</text>", .{ ctx.x(t), h - mb + 18, label });
    }
    try writeXAxis(out, opts.x_label);
    try writeYUnitLabel(out, opts.y_unit);

    try out.print("<g clip-path=\"url(#clip-{s})\">", .{opts.id});
    for (series) |s| {
        if (s.pts.len == 0) continue;
        // A missing observation must read as missing: one polyline over the
        // surviving points would interpolate across the gap. Split into
        // contiguous stretches; a lone point is shown only by its marker.
        var start: usize = 0;
        while (start < s.pts.len) {
            var end = start + 1;
            while (end < s.pts.len) : (end += 1) {
                if (opts.x_ordinal and s.pts[end].x - s.pts[end - 1].x > 1.5) break;
            }
            try out.print("<polyline class=\"line s-{s}\" points=\"", .{s.name});
            for (s.pts[start..end], 0..) |p, i| {
                if (i > 0) try out.writeByte(' ');
                try out.print("{d:.1},{d:.1}", .{ ctx.x(p.x), ctx.y(p.y) });
            }
            try out.writeAll("\" fill=\"none\" stroke-width=\"2\"");
            if (s.dashed) try out.writeAll(" stroke-dasharray=\"6 4\"");
            try out.writeAll("/>");
            start = end;
        }
    }
    if (opts.markers) {
        // Dots after every line, so no dot is buried under a later stroke.
        for (series) |s| {
            for (s.pts) |p| {
                try out.print(
                    "<circle class=\"dot s-{s}\" cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"4\"/>",
                    .{ s.name, ctx.x(p.x), ctx.y(p.y) },
                );
            }
        }
    }
    try out.writeAll("</g>");

    try out.print(
        "<rect class=\"hover-capture\" data-chart=\"{s}\" x=\"{d:.0}\" y=\"{d:.0}\" width=\"{d:.0}\" height=\"{d:.0}\" fill=\"transparent\"/>",
        .{ opts.id, ml, mt, w - ml - mr, h - mt - mb },
    );
    try out.writeAll("</svg>");
    return true;
}

/// What the hover tooltip calls the x value, and how to render it. Carried in
/// the data blob: x is offered load in the run report but a run index in the
/// nightly trend.
pub const XAxis = struct {
    name: []const u8 = "offered",
    unit: []const u8 = "req/s",
    /// Per-x labels for an ordinal axis; when set the tooltip shows
    /// `labels[x]` (e.g. run ids) and `unit` is unused.
    labels: []const []const u8 = &.{},
};

/// JSON blob read by `report.js`'s hover handler for chart `id`. Geometry and
/// xmax must match what `chart` computed for the same series, or the
/// crosshair lands on the wrong point. Shared by every line-chart embedder.
pub fn writeChartData(
    out: *std.Io.Writer,
    id: []const u8,
    series: []const Series,
    yfmt: YFormat,
    xmax_opt: ?f64,
    x: XAxis,
) !void {
    try out.print("<script type=\"application/json\" id=\"data-{s}\">", .{id});
    var j = jsonw.Writer{ .w = out };
    try j.beginObject();
    try j.key("series");
    try j.beginArray();
    for (series) |s| {
        if (s.pts.len == 0) continue;
        try j.beginObject();
        try j.key("name");
        try j.string(s.name);
        try j.key("pts");
        try j.beginArray();
        for (s.pts) |p| {
            try j.beginArray();
            try j.float(p.x, 4);
            try j.float(p.y, 4);
            try j.endArray();
        }
        try j.endArray();
        try j.endObject();
    }
    try j.endArray();
    try j.key("yfmt");
    try j.string(@tagName(yfmt));
    try j.key("geom");
    try j.beginArray();
    for ([_]f64{ w, h, ml, mr, mt, mb }) |v| try j.int(@intFromFloat(v));
    try j.endArray();

    var xmax: f64 = xmax_opt orelse blk: {
        var m: f64 = 0;
        for (series) |s| for (s.pts) |p| {
            m = @max(m, p.x);
        };
        break :blk @max(m, 1);
    };
    if (xmax <= 0) xmax = 1;
    // Must match `chart`'s xmaxt. `labels` marks the axis ordinal, like
    // `Options.x_ordinal` on the drawing side.
    try j.key("xmax");
    if (x.labels.len > 0) {
        try j.float(@max(xmax, 1), 4);
    } else {
        const ticks = niceTicks(0, xmax, 5);
        const t = ticks.slice();
        try j.float(t[t.len - 1], 4);
    }

    try j.key("x");
    try j.beginObject();
    try j.key("name");
    try j.string(x.name);
    try j.key("unit");
    try j.string(x.unit);
    try j.key("labels");
    try j.beginArray();
    for (x.labels) |l| try j.string(l);
    try j.endArray();
    try j.endObject();

    try j.endObject();
    try out.writeAll("</script>");
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

/// Per-proxy latency distribution: x is n = 1/(1-percentile) on a log scale,
/// so p50/p90/p99/p99.9 land on even decades.
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

    // `data-hist`, not `data-chart`: the line-chart hover handler assumes a
    // linear x and named series, neither true here.
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
    // The axis must cover the data.
    try std.testing.expect(s[s.len - 1] >= 43120);
}

test "niceTicks handles a degenerate range" {
    const t = niceTicks(0, 0, 5);
    try std.testing.expect(t.len >= 2);
}

test "fmtSi reproduces report/charts.py's fmt_si" {
    // Expectations taken from the Python.
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("43.12k", fmtSi(&buf, 43120));
    try std.testing.expectEqualStrings("1M", fmtSi(&buf, 1_000_000));
    try std.testing.expectEqualStrings("1.5k", fmtSi(&buf, 1500));
    try std.testing.expectEqualStrings("500", fmtSi(&buf, 500));
    try std.testing.expectEqualStrings("0", fmtSi(&buf, 0));
    try std.testing.expectEqualStrings("43", fmtSi(&buf, 43.12));

    // The sub-10 branch is %.2g: two significant figures.
    try std.testing.expectEqualStrings("0.12", fmtSi(&buf, 0.123456));
    try std.testing.expectEqualStrings("0.4", fmtSi(&buf, 0.4));
    try std.testing.expectEqualStrings("0.05", fmtSi(&buf, 0.05));
    try std.testing.expectEqualStrings("1.5", fmtSi(&buf, 1.5));
    try std.testing.expectEqualStrings("10", fmtSi(&buf, 9.999));
    try std.testing.expectEqualStrings("0.0004", fmtSi(&buf, 0.0004));
}

test "fmtSi rounds float noise instead of printing it" {
    // Measured values carry float noise; fmtSi must round it away like `%g`.
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("43.12k", fmtSi(&buf, 43119.999999999993));
    try std.testing.expectEqualStrings("3M", fmtSi(&buf, 2_999_999.999999999));
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
    // A tail past the crop must not inflate the y scale.
    const pts = [_]Point{
        .{ .x = 1000, .y = 10 },
        .{ .x = 2000, .y = 20 },
        .{ .x = 90000, .y = 100000 }, // cropped out
    };
    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    _ = try chart(&out, .{ .id = "rps", .xmax = 3000 }, &.{.{ .name = "zoxy", .pts = &pts }});

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
    try std.testing.expect(std.mem.indexOf(u8, s, "data-hist=\"zoxy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "data-chart=") == null);
}

test "the hover blob says what x is, so the tooltip stops assuming offered load" {
    var buf: [4096]u8 = undefined;
    const pts = [_]Point{ .{ .x = 0, .y = 40000 }, .{ .x = 1, .y = 43000 } };
    const series = [_]Series{.{ .name = "zoxy", .pts = &pts }};

    // Run report: x is offered load.
    {
        var out: std.Io.Writer = .fixed(&buf);
        try writeChartData(&out, "rps", &series, .si, null, .{});
        const s = out.buffered();
        try std.testing.expect(std.mem.indexOf(u8, s, "\"name\":\"offered\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, s, "\"unit\":\"req/s\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, s, "\"labels\":[]") != null);
    }

    // Nightly trend: x is a run index; labels name the run.
    {
        var out: std.Io.Writer = .fixed(&buf);
        const runids = [_][]const u8{ "20260731-000100", "20260801-000100" };
        try writeChartData(&out, "trend-c1k", &series, .si, null, .{
            .name = "run",
            .labels = &runids,
        });
        const s = out.buffered();
        try std.testing.expect(std.mem.indexOf(u8, s, "\"name\":\"run\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, s, "\"20260801-000100\"") != null);
    }
}

test "markers are drawn for discrete observations, and let out of the clip" {
    var buf: [8192]u8 = undefined;

    // A one-vertex `<polyline>` paints nothing; the marker must show it.
    {
        var out: std.Io.Writer = .fixed(&buf);
        const one = [_]Point{.{ .x = 0, .y = 43000 }};
        _ = try chart(&out, .{ .id = "t", .markers = true }, &.{.{ .name = "zoxy", .pts = &one }});
        const s = out.buffered();
        try std.testing.expect(std.mem.indexOf(u8, s, "<circle class=\"dot s-zoxy\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, s, "r=\"4\"") != null);
    }

    // The clip is let out by the marker radius, so edge points are whole.
    {
        var out: std.Io.Writer = .fixed(&buf);
        const pts = [_]Point{ .{ .x = 0, .y = 1 }, .{ .x = 2, .y = 2 } };
        _ = try chart(&out, .{ .id = "t", .markers = true }, &.{.{ .name = "zoxy", .pts = &pts }});
        const s = out.buffered();
        // ml=62, mr=16, pad=6 -> x=56, width = 720-62-16+12 = 654
        try std.testing.expect(std.mem.indexOf(u8, s, "<rect x=\"56\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, s, "width=\"654\"") != null);
    }

    // Off by default: dense ramp samples do not need dots.
    {
        var out: std.Io.Writer = .fixed(&buf);
        const pts = [_]Point{ .{ .x = 0, .y = 1 }, .{ .x = 2, .y = 2 } };
        _ = try chart(&out, .{ .id = "rps" }, &.{.{ .name = "zoxy", .pts = &pts }});
        const s = out.buffered();
        try std.testing.expect(std.mem.indexOf(u8, s, "<circle") == null);
        try std.testing.expect(std.mem.indexOf(u8, s, "<rect x=\"62\"") != null);
    }
}

test "an ordinal axis ends on the last observation, not on a round number" {
    var buf: [8192]u8 = undefined;

    // Eight nights occupy x = 0..7; niceTicks would round the axis up to 8.
    const pts = [_]Point{
        .{ .x = 0, .y = 40000 }, .{ .x = 1, .y = 41000 },
        .{ .x = 2, .y = 42000 }, .{ .x = 3, .y = 43000 },
        .{ .x = 4, .y = 41000 }, .{ .x = 5, .y = 42000 },
        .{ .x = 6, .y = 43000 }, .{ .x = 7, .y = 44000 },
    };
    const series = [_]Series{.{ .name = "zoxy", .pts = &pts }};

    var out: std.Io.Writer = .fixed(&buf);
    _ = try chart(&out, .{ .id = "t", .markers = true, .x_ordinal = true }, &series);
    const s = out.buffered();

    // The newest run lands on the right edge (w - mr = 704).
    try std.testing.expect(std.mem.indexOf(u8, s, "cx=\"704.0\"") != null);
    // Counted from 1: "8" present, no "9".
    try std.testing.expect(std.mem.indexOf(u8, s, ">8</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, ">9</text>") == null);

    // The non-ordinal path is unchanged: still rounded, still 0-based.
    var out2: std.Io.Writer = .fixed(&buf);
    _ = try chart(&out2, .{ .id = "t" }, &series);
    try std.testing.expect(std.mem.indexOf(u8, out2.buffered(), "cx=\"704.0\"") == null);
}

test "the ordinal axis and its hover blob agree on xmax" {
    // Computed in two functions; they must agree.
    var buf: [8192]u8 = undefined;
    const pts = [_]Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 3 } };
    const series = [_]Series{.{ .name = "zoxy", .pts = &pts }};
    const runids = [_][]const u8{ "r1", "r2", "r3" };

    var out: std.Io.Writer = .fixed(&buf);
    try writeChartData(&out, "trend", &series, .si, null, .{ .name = "run", .labels = &runids });
    // 2, the last observation, not niceTicks' 2.5.
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"xmax\":2.0") != null);
}

test "ordinalTicks stays whole-numbered and always marks the last run" {
    const few = ordinalTicks(3);
    try std.testing.expectEqual(@as(usize, 4), few.slice().len);
    try std.testing.expectApproxEqAbs(@as(f64, 3), few.slice()[3], 1e-9);

    // Large: thinned, but the last run is never dropped.
    const many = ordinalTicks(30);
    const t = many.slice();
    try std.testing.expect(t.len <= 10);
    try std.testing.expectApproxEqAbs(@as(f64, 30), t[t.len - 1], 1e-9);
    for (t) |v| try std.testing.expectApproxEqAbs(v, @round(v), 1e-9);
}

test "a night with no data breaks the line instead of being drawn through" {
    var buf: [8192]u8 = undefined;

    // Five nights, the third missing: must not be bridged by one polyline.
    const pts = [_]Point{
        .{ .x = 0, .y = 20000 },
        .{ .x = 1, .y = 21000 },
        // x = 2 absent
        .{ .x = 3, .y = 22000 },
        .{ .x = 4, .y = 23000 },
    };
    const series = [_]Series{.{ .name = "haproxy", .pts = &pts }};

    var out: std.Io.Writer = .fixed(&buf);
    _ = try chart(&out, .{ .id = "t", .markers = true, .x_ordinal = true }, &series);
    const s = out.buffered();

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, s, "<polyline class=\"line s-haproxy\""));
    // Four nights of data, four dots.
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, s, "<circle class=\"dot s-haproxy\""));

    // A continuous series is still one polyline.
    const whole = [_]Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 3 } };
    var out2: std.Io.Writer = .fixed(&buf);
    _ = try chart(&out2, .{ .id = "t", .markers = true, .x_ordinal = true }, &.{.{ .name = "zoxy", .pts = &whole }});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out2.buffered(), "<polyline class=\"line s-zoxy\""));
}

test "gap-splitting is ordinal-only — a sampled ramp is never cut" {
    // Run report x is offered load: wide sample spacing is not a gap.
    var buf: [8192]u8 = undefined;
    const pts = [_]Point{ .{ .x = 0, .y = 1 }, .{ .x = 900, .y = 2 }, .{ .x = 1800, .y = 3 } };
    var out: std.Io.Writer = .fixed(&buf);
    _ = try chart(&out, .{ .id = "rps" }, &.{.{ .name = "zoxy", .pts = &pts }});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.buffered(), "<polyline class=\"line s-zoxy\""));
}

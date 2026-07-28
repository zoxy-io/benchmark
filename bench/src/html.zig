//! Assembles report.html from the same numbers report.json carries.
//!
//! Ported from report/report.py's `build`, with one substantive addition: a
//! proxy's STATUS is rendered. The Python derived the proxy list from
//! `meta["runs"]` membership, so a proxy that failed produced a row of zeros
//! indistinguishable from one that genuinely served nothing. Here a `failed` or
//! `skipped` proxy contributes no line to any chart and gets an explicit badge
//! naming the stage it died at; a `degraded` one renders its numbers with a
//! warning.
//!
//! Both style and behaviour are `@embedFile`d, so the page is self-contained —
//! it has to be, since it is posted to Discord as an attachment. The two font
//! `@import`s the Python's CSS carried were dropped when the assets were
//! extracted: on a public Pages site they send every viewer's address to
//! Fontshare and Google, and the CSS already declares full fallback stacks.

const std = @import("std");

const analysis = @import("analysis.zig");
const artifact = @import("artifact.zig");
const report = @import("report.zig");
const svg = @import("svg.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const css = @embedFile("assets/report.css");
const js = @embedFile("assets/report.js");

pub const Options = struct {
    runid: []const u8,
    profile_name: []const u8,
    ref_rate: f64,
    connections: u32,
    deadline_ms: u64,
    /// Absolute prefix for `.hgrm` download links, so the same file works both
    /// as a Discord attachment (where a relative link 404s) and on Pages.
    base_url: []const u8 = "",
};

pub fn render(
    arena: Allocator,
    out: *Writer,
    g: report.Gathered,
    statuses: []const artifact.ProxyRecord,
    opts: Options,
) !void {
    // Crop every chart's offered axis to where the LAST real proxy stops keeping
    // up. The p99 curves are keep-up-filtered, so their rightmost offered IS
    // that knee. Past it only the direct baseline has data, and the full ramp
    // would waste half the chart width on empty space.
    var crop: ?f64 = null;
    for (g.p99) |s| {
        if (std.mem.eql(u8, s.name, "direct")) continue;
        for (s.pts) |p| crop = @max(crop orelse 0, p.x);
    }

    try out.writeAll(
        \\<!doctype html><html lang=en><head><meta charset=utf-8>
        \\<meta name=viewport content="width=device-width,initial-scale=1">
        \\<meta name="color-scheme" content="dark">
        \\<meta name="theme-color" content="#0e1016">
    );
    try out.print("<title>zoxy bench · {s} · {s}</title><style>", .{ opts.runid, opts.profile_name });
    try out.writeAll(css);
    try out.writeAll("</style></head><body>");

    try out.print(
        "<div class=\"eyebrow\">HTTP (L7) proxy benchmark · open-loop ramp · {s}</div>",
        .{opts.profile_name},
    );
    try out.print("<h1>request throughput <span class=\"rid\">{s}</span></h1>", .{opts.runid});

    var buf: [64]u8 = undefined;
    try out.print(
        \\<p class="meta">Every proxy driven through the identical linear ramp (zrk, open-loop,
        \\coordinated-omission corrected) at <b>{d} connections</b>. Throughput and CPU span the full ramp.
        \\The table's <b>p50 / p99</b> are each proxy's latency at a common <b>{s} req/s</b> reference load — a
        \\shared, light, sub-knee rate where the number reflects per-request <em>cost</em> rather than queueing.
    , .{ opts.connections, svg.fmtSi(&buf, opts.ref_rate) });
    if (opts.deadline_ms > 0) {
        // Say so explicitly: it changes what p99 MEANS on this page.
        try out.print(
            \\ This profile applies a <b>{d}ms client-side deadline</b>, identical for every proxy: a request that
            \\would miss it is shed before being sent and never recorded, so p99 is the distribution of requests
            \\served <em>within the SLO</em> and overload shows up as a bounded error rate instead of an unbounded tail.
        , .{opts.deadline_ms});
    }
    try out.writeAll("</p>");

    // --- summary table
    try out.writeAll("<div class=\"tablewrap\"><table><tr><th>proxy</th><th>max sustained req/s</th>");
    try out.print("<th>p50 @ {s}</th><th>p99 @ {s}</th><th>peak mem</th><th>status</th></tr>", .{
        svg.fmtSi(&buf, opts.ref_rate),
        svg.fmtSi(&buf, opts.ref_rate),
    });

    const ranked = try rank(arena, g.present, statuses);
    for (ranked) |p| {
        const st = statusOf(statuses, p.name);
        const usable = st == null or st.?.status.usable();
        const has_hist = if (p.hist) |*hh| hh.count() > 0 else false;

        try out.writeAll(if (std.mem.eql(u8, p.name, "direct")) "<tr class=\"baseline\">" else "<tr>");

        // The colour swatch is the report's only legend.
        if (has_hist) {
            try out.print("<td><a class=\"proxycell\" href=\"#hist-{s}\"><span class=\"swatch s-{s}\"></span>{s}</a></td>", .{ p.name, p.name, p.name });
        } else {
            try out.print("<td><span class=\"proxycell\"><span class=\"swatch s-{s}\"></span>{s}</span></td>", .{ p.name, p.name });
        }

        if (!usable) {
            // No numbers at all — a failed proxy must never render as zeros.
            try out.writeAll("<td>—</td><td>—</td><td>—</td><td>—</td>");
        } else {
            try out.print("<td>{s}</td>", .{svg.fmtSi(&buf, p.sustained)});
            try writeLatencyCell(out, p, st);
            try writeLatencyCellP99(out, p, st);
            if (p.mem) |m| {
                var mb: [64]u8 = undefined;
                try out.print("<td>{s}</td>", .{svg.fmtBytes(&mb, m)});
            } else {
                try out.writeAll("<td>—</td>");
            }
        }

        try out.writeAll("<td>");
        try writeStatusBadge(out, st);
        try out.writeAll("</td></tr>");
    }
    try out.writeAll("</table></div>");

    // --- charts
    try out.writeAll("<div class=\"grid2\">");
    try card(arena, out, "Successful req/s vs offered", "open-loop ramp; dashed gray = perfect keep-up", .{
        .id = "rps",
        .yfmt = .si,
        .y_unit = "req/s",
        .xmax = crop,
    }, g.rps);
    try card(arena, out, "Proxy CPU vs offered", "container cores sampled from cAdvisor at 1Hz, on the ramp's own clock", .{
        .id = "cpu",
        .yfmt = .si,
        .y_unit = "cores",
        .xmax = crop,
    }, g.cpu);
    try card(arena, out, "p99 latency vs offered (while keeping up)", "per-window tail (log scale); each line stops where that proxy stops keeping up", .{
        .id = "p99",
        .yfmt = .ms,
        .y_unit = "ms",
        .ylog = true,
        .xmax = crop,
    }, g.p99);
    try card(arena, out, "Load shed vs offered", "offered load the proxy couldn't serve (1 − achieved/offered), minus the direct baseline's loadgen-side shortfall", .{
        .id = "shed",
        .yfmt = .pct,
        .xmax = crop,
    }, g.shed);
    try out.writeAll("</div>");

    // --- per-proxy latency distributions
    var any_hist = false;
    for (g.present) |*p| {
        if (p.hist) |*hh| {
            if (hh.count() > 0) any_hist = true;
        }
    }
    if (any_hist) {
        try out.print(
            "<h2 class=\"dist-h\">Latency distribution · HdrHistogram (at {s} req/s reference load)</h2><div class=\"grid2\">",
            .{svg.fmtSi(&buf, opts.ref_rate)},
        );
        for (g.present) |*p| {
            const hh = if (p.hist) |*x| x else continue;
            if (hh.count() == 0) continue;

            try out.print("<section class=\"card\" id=\"hist-{s}\"><h2>{s}</h2><p class=\"sub\">latency by percentile", .{ p.name, p.name });
            if (analysis.isSaturated(hh)) {
                // zrk's histogram clamps at 60s, so every tail percentile here
                // is the clamp value. Printing it as a measurement would be a
                // fabrication.
                try out.writeAll(" · <b class=\"warn\">saturated at 60s — tail percentiles are a floor, not a value</b>");
            }
            if (p.hgrm_file.len > 0) {
                try out.print(
                    " · raw <a href=\"{s}{s}\" download>{s}</a> = whole run",
                    .{ opts.base_url, p.hgrm_file, p.hgrm_file },
                );
            }
            try out.writeAll("</p><div class=\"chartwrap\">");
            _ = try svg.histChart(out, p.name, try toSvgPoints(arena, try analysis.hdrPoints(arena, hh)));
            try out.writeAll("</div></section>");
        }
        try out.writeAll("</div>");
    }

    try out.writeAll("<footer>generated by bench — <a href=\"https://zoxy.io\">zoxy.io</a></footer><script>");
    try out.writeAll(js);
    try out.writeAll("</script></body></html>");
}

fn writeLatencyCell(out: *Writer, p: *const report.ProxyData, st: ?artifact.ProxyRecord) !void {
    const h = if (p.hist) |*x| x else {
        try out.writeAll("<td>—</td>");
        return;
    };
    if (h.count() == 0) {
        try out.writeAll("<td>—</td>");
        return;
    }
    _ = st;
    const v = @as(f64, @floatFromInt(h.valueAtPercentile(50))) / 1000.0;
    try out.print("<td>{d:.2}ms</td>", .{v});
}

fn writeLatencyCellP99(out: *Writer, p: *const report.ProxyData, st: ?artifact.ProxyRecord) !void {
    _ = st;
    const h = if (p.hist) |*x| x else {
        try out.writeAll("<td>—</td>");
        return;
    };
    if (h.count() == 0) {
        try out.writeAll("<td>—</td>");
        return;
    }
    if (analysis.isSaturated(h)) {
        try out.writeAll("<td class=\"warn\">≥60s</td>");
        return;
    }
    const v = @as(f64, @floatFromInt(h.valueAtPercentile(99))) / 1000.0;
    try out.print("<td>{d:.2}ms</td>", .{v});
}

fn writeStatusBadge(out: *Writer, st: ?artifact.ProxyRecord) !void {
    const r = st orelse {
        try out.writeAll("<span class=\"badge\">ok</span>");
        return;
    };
    switch (r.status) {
        .ok => try out.writeAll("<span class=\"badge\">ok</span>"),
        .degraded => {
            try out.writeAll("<span class=\"badge warn\">⚠ degraded");
            if (r.notes.len > 0) try out.print(" · {s}", .{r.notes[0]});
            try out.writeAll("</span>");
        },
        .failed => {
            try out.writeAll("<span class=\"badge fail\">failed");
            if (r.stage) |s| try out.print(" · {s}", .{s.str()});
            try out.writeAll("</span>");
        },
        .skipped => try out.writeAll("<span class=\"badge\">skipped</span>"),
    }
}

/// analysis and svg each own their own Point type deliberately: one is a
/// measurement, the other a screen coordinate source. Convert at the boundary.
fn toSvgPoints(arena: Allocator, pts: []const analysis.Point) ![]svg.Point {
    const out = try arena.alloc(svg.Point, pts.len);
    for (pts, 0..) |p, i| out[i] = .{ .x = p.x, .y = p.y };
    return out;
}

fn statusOf(statuses: []const artifact.ProxyRecord, name: []const u8) ?artifact.ProxyRecord {
    for (statuses) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// Usable proxies by sustained throughput descending, then failed, then skipped.
/// A failure never outranks a real result just because it has no number.
fn rank(
    arena: Allocator,
    present: []report.ProxyData,
    statuses: []const artifact.ProxyRecord,
) ![]*report.ProxyData {
    const out = try arena.alloc(*report.ProxyData, present.len);
    for (present, 0..) |*p, i| out[i] = p;

    const Ctx = struct {
        statuses: []const artifact.ProxyRecord,
        fn key(self: @This(), p: *report.ProxyData) u8 {
            const st = statusOf(self.statuses, p.name) orelse return 0;
            return switch (st.status) {
                .ok, .degraded => 0,
                .failed => 1,
                .skipped => 2,
            };
        }
        fn less(self: @This(), a: *report.ProxyData, b: *report.ProxyData) bool {
            const ka = self.key(a);
            const kb = self.key(b);
            if (ka != kb) return ka < kb;
            return a.sustained > b.sustained;
        }
    };
    std.mem.sort(*report.ProxyData, out, Ctx{ .statuses = statuses }, Ctx.less);
    return out;
}

fn card(
    arena: Allocator,
    out: *Writer,
    title: []const u8,
    sub: []const u8,
    opts: svg.Options,
    series: []const report.Series,
) !void {
    const conv = try arena.alloc(svg.Series, series.len);
    for (series, 0..) |s, i| {
        const pts = try arena.alloc(svg.Point, s.pts.len);
        for (s.pts, 0..) |p, k| pts[k] = .{ .x = p.x, .y = p.y };
        conv[i] = .{ .name = s.name, .pts = pts, .dashed = s.ref or s.baseline };
    }

    try out.print("<section class=\"card\"><h2>{s}</h2><p class=\"sub\">{s}</p><div class=\"chartwrap\" id=\"wrap-{s}\">", .{ title, sub, opts.id });
    _ = try svg.chart(out, opts, conv);
    try out.print("<div class=\"tooltip\" id=\"tip-{s}\" hidden></div></div>", .{opts.id});

    // The hover layer reads its data from this blob. The synthetic y=x diagonal
    // is excluded: its value at any x is just x, already shown in the header.
    try out.print("<script type=\"application/json\" id=\"data-{s}\">", .{opts.id});
    try out.writeAll("{\"series\":[");
    var first = true;
    for (series) |s| {
        if (s.pts.len == 0 or s.ref) continue;
        if (!first) try out.writeByte(',');
        first = false;
        try out.print("{{\"name\":\"{s}\",\"pts\":[", .{s.name});
        for (s.pts, 0..) |p, i| {
            if (i > 0) try out.writeByte(',');
            try out.print("[{d:.1},{d}]", .{ p.x, p.y });
        }
        try out.writeAll("]}");
    }
    try out.print("],\"yfmt\":\"{s}\",\"geom\":[{d:.0},{d:.0},{d:.0},{d:.0},{d:.0},{d:.0}]", .{
        @tagName(opts.yfmt), svg.w, svg.h, svg.ml, svg.mr, svg.mt, svg.mb,
    });

    var xmax: f64 = opts.xmax orelse blk: {
        var m: f64 = 0;
        for (series) |s| for (s.pts) |p| {
            m = @max(m, p.x);
        };
        break :blk @max(m, 1);
    };
    if (xmax <= 0) xmax = 1;
    const ticks = svg.niceTicks(0, xmax, 5);
    const t = ticks.slice();
    try out.print(",\"xmax\":{d}}}", .{t[t.len - 1]});
    try out.writeAll("</script></section>");
}

test "a failed proxy renders no numbers and names its stage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var present = [_]report.ProxyData{.{
        .name = "haproxy",
        .rows = &.{},
        // Even with a nonzero sustained recorded, a failed proxy must not
        // publish it — that is precisely the zeros-look-like-data failure.
        .sustained = 12345,
        .hist = null,
        .hgrm_file = "",
        .mem = null,
        .cpu = &.{},
        .p99 = &.{},
        .shed_raw = &.{},
    }};
    const statuses = [_]artifact.ProxyRecord{.{
        .name = "haproxy",
        .status = .failed,
        .stage = .warm,
        .err = "no 200 after 30 attempts",
    }};

    var buf: [128 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try render(arena, &out, .{
        .present = &present,
        .rps = &.{},
        .cpu = &.{},
        .p99 = &.{},
        .shed = &.{},
    }, &statuses, .{
        .runid = "r",
        .profile_name = "c1k",
        .ref_rate = 2000,
        .connections = 1000,
        .deadline_ms = 0,
    });

    const s = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "failed · warm") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "12.3k") == null);
}

test "the c10k deadline is stated, because it changes what p99 means" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var buf: [128 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try render(arena_state.allocator(), &out, .{
        .present = &.{},
        .rps = &.{},
        .cpu = &.{},
        .p99 = &.{},
        .shed = &.{},
    }, &.{}, .{
        .runid = "r",
        .profile_name = "c10k",
        .ref_rate = 8000,
        .connections = 10000,
        .deadline_ms = 1000,
    });

    const s = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "1000ms client-side deadline") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "within the SLO") != null);
}

test "the page carries no external font imports" {
    // On a public Pages site an @import would send every viewer's address to a
    // third party, and a Discord attachment must render offline.
    try std.testing.expect(std.mem.indexOf(u8, css, "@import") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, "fonts.googleapis.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, "fontshare.com") == null);
}

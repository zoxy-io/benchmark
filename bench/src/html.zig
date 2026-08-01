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
const jsonw = @import("jsonw.zig");
const report = @import("report.zig");
const svg = @import("svg.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const css = @embedFile("assets/report.css");
const js = @embedFile("assets/report.js");

pub const Options = struct {
    runid: []const u8,
    profile_name: []const u8,
    /// A local run is banner-marked; see the note at the banner itself.
    origin: artifact.Origin = .cloud,
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
    if (opts.origin == .local) {
        // Someone will eventually screenshot one of these. The page has to say
        // what it is without being read carefully.
        try out.writeAll(
            "<p class=\"meta\"><b class=\"warn\">Local run — not a benchmark result.</b> " ++
                "The load generator shared CPU, cache and memory bandwidth with the proxy it was " ++
                "measuring, and the fleet's network was replaced by loopback, which removes a " ++
                "ceiling the real baseline sits near. Useful for working on the harness; not " ++
                "comparable to a nightly, and deliberately absent from the trend.</p>",
        );
    }

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
        try out.writeAll("<td>");
        if (has_hist) {
            try out.print("<a class=\"proxycell\" href=\"#hist-{s}\"><span class=\"swatch s-{s}\"></span>{s}</a>", .{ p.name, p.name, p.name });
        } else {
            try out.print("<span class=\"proxycell\"><span class=\"swatch s-{s}\"></span>{s}</span>", .{ p.name, p.name });
        }
        try writeVersion(out, p.name, st);
        try out.writeAll("</td>");

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
    //
    // Plots `dist_hist` (every window merged, warmup included) rather than
    // `hist` (the summary table's reference-band histogram) — a reader
    // hovering this chart should see what the whole run actually did, not a
    // fairness-filtered slice of it. The downloadable `.hgrm` file is the
    // SAME data (see analysis.wholeRunHist's doc comment), so the two no
    // longer describe different things under one heading.
    var any_hist = false;
    for (g.present) |*p| {
        if (p.dist_hist) |*hh| {
            if (hh.count() > 0) any_hist = true;
        }
    }
    if (any_hist) {
        try out.writeAll("<h2 class=\"dist-h\">Latency distribution · HdrHistogram (whole run)</h2><div class=\"grid2\">");
        for (g.present) |*p| {
            const hh = if (p.dist_hist) |*x| x else continue;
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
                    " · raw <a href=\"{s}{s}\" download>{s}</a>",
                    .{ opts.base_url, p.hgrm_file, p.hgrm_file },
                );
            }
            try out.writeAll("</p>");
            try histCard(arena, out, p.name, try analysis.hdrPoints(arena, hh));
            try out.writeAll("</section>");
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

/// The version that actually answered, under the proxy's name.
///
/// A benchmark number means nothing without the build it came from, and until
/// now the page named neither — a reader had to take "haproxy" on faith and go
/// read compose.yaml to find out which haproxy. zoxy additionally gets its
/// commit, short-form, since its version alone (`zoxy 0.0.5`) does not identify
/// a nightly build of a moving `main`.
fn writeVersion(out: *Writer, name: []const u8, st: ?artifact.ProxyRecord) !void {
    var vbuf: [128]u8 = undefined;
    var ebuf: [512]u8 = undefined;

    const version: ?[]const u8 = if (st) |r| r.version else null;
    const commit: ?[]const u8 = if (st) |r| r.zoxy_commit else null;

    // ALWAYS one line, on every row. Two reasons, both about the table reading
    // straight: a row that is two lines tall beside rows that are one looks
    // broken, and `direct` — the origin baseline, which has no container and so
    // no version — would otherwise be the short row in every report.
    //
    // The full string as recorded goes in `title`, so shortening costs a reader
    // nothing: it is a hover away here and verbatim in profile.json.
    try out.writeAll("<span class=\"prov\"");
    if (version) |v| try out.print(" title=\"{s}\"", .{escapeHtml(&ebuf, v)});
    try out.writeAll(">");

    if (version == null and commit == null) {
        // Said, not left blank. For `direct` this is the point of the row —
        // there is no proxy on the path — and for anything else it means the
        // probe could not read one, which is worth seeing.
        try out.writeAll(if (std.mem.eql(u8, name, "direct")) "no proxy" else "—");
        try out.writeAll("</span>");
        return;
    }

    var wrote = false;
    if (version) |v| {
        try out.print("{s}", .{escapeHtml(&ebuf, shortVersion(&vbuf, v))});
        wrote = true;
    }
    if (commit) |c| {
        // Short sha: the full 40 is in profile.json for anyone bisecting, and
        // the table has to stay readable.
        const short = if (c.len > 9) c[0..9] else c;
        if (wrote) try out.writeAll(" ");
        try out.print("@{s}", .{escapeHtml(&ebuf, short)});
    }
    try out.writeAll("</span>");
}

/// The version number out of whatever the proxy printed.
///
/// What these report is banner text, not a version — haproxy adds a build sha,
/// a date and a URL; envoy a commit, a build type and its TLS backend; the
/// image-reference fallback carries a whole repository path. Rendered verbatim
/// they run to 67 and 88 characters and stretch the summary table's first
/// column until the numbers beside it stop lining up.
///
/// The rule: split on the separators these formats use, and take the first
/// token that is a dotted version number. That is enough for every shape the
/// harness actually sees, and each one is pinned by a test:
///
///   HAProxy version 3.0.25-eb573a937 2026/07/03 - ...  -> 3.0.25
///   envoy  version: 14197ab.../1.33.14/Clean/RELEASE/.. -> 1.33.14
///   zoxy 0.0.5                                          -> 0.0.5
///   zoxy-bench/pingora-http:0.8                         -> 0.8
///
/// A string with no such token (an unrecognised format, or a proxy added later
/// that prints something else) falls back to the raw text, truncated. Losing
/// the shortening is a cosmetic problem; dropping the version is not.
fn shortVersion(buf: []u8, raw: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, raw, " \t/:");
    while (it.next()) |tok| {
        if (versionToken(tok)) |v| return v;
    }
    const max = @min(raw.len, @min(buf.len, 24));
    return raw[0..max];
}

/// `tok` as a dotted version number, or null.
///
/// Requires a leading digit and at least one dot, which is what separates a
/// version from the other digit-bearing tokens in these banners — envoy's
/// 40-character commit sha (no dots) and haproxy's `2026/07/03` date, split
/// into `2026`, `07`, `03` by the same separators.
///
/// A `-suffix` is a build tag (haproxy's `3.0.25-eb573a937`) and is dropped:
/// the release is the part a reader compares.
fn versionToken(tok: []const u8) ?[]const u8 {
    if (tok.len == 0 or !std.ascii.isDigit(tok[0])) return null;
    var dots: usize = 0;
    for (tok, 0..) |c, i| {
        if (c == '.') {
            dots += 1;
        } else if (c == '-' or c == '+') {
            return if (dots >= 1) tok[0..i] else null;
        } else if (!std.ascii.isDigit(c)) {
            return null;
        }
    }
    return if (dots >= 1) tok else null;
}

fn writeStatusBadge(out: *Writer, st: ?artifact.ProxyRecord) !void {
    const r = st orelse {
        try out.writeAll("<span class=\"badge\">ok</span>");
        return;
    };
    switch (r.status) {
        .ok => try out.writeAll("<span class=\"badge\">ok</span>"),
        .degraded => try out.writeAll("<span class=\"badge warn\">⚠ degraded</span>"),
        .failed => {
            try out.writeAll("<span class=\"badge fail\">failed");
            if (r.stage) |s| try out.print(" · {s}", .{s.str()});
            try out.writeAll("</span>");
        },
        .skipped => try out.writeAll("<span class=\"badge\">skipped</span>"),
    }

    // EVERY note, on every status — not just the first, and not only when
    // degraded. Both limits used to hide things that were recorded precisely
    // because a reader needs them: an `ok` zoxy's build-parity note (SIMD
    // against haproxy's generic x86-64 image) reached no reader at all, and a
    // degraded proxy showed one note while silently dropping the rest.
    for (r.notes) |n| {
        var nbuf: [1024]u8 = undefined;
        try out.print("<div class=\"note\">{s}</div>", .{escapeHtml(&nbuf, n)});
    }
}

/// Escape `text` for HTML text content.
///
/// This page has no other genuinely free-text sink: everything else `{s}`
/// interpolates is a name this harness generates itself (a proxy name from
/// `commands.parseProxies`'s allowlist, a `Stage`'s own `.str()`, a filename
/// it wrote) — but `notes` carries text built in `suite.zig` from a docker
/// image's `/etc/<proxy>/build-info` file, which is not proxy-name-shaped and
/// has no allowlist behind it.
fn escapeHtml(buf: []u8, text: []const u8) []const u8 {
    var len: usize = 0;
    for (text) |c| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            // Also escaped because this now feeds an ATTRIBUTE value (the
            // version `title=`), where a bare quote ends the attribute and
            // everything after it becomes markup. Harmless in text content,
            // which is the only place it went before.
            '"' => "&quot;",
            else => {
                if (len == buf.len) break;
                buf[len] = c;
                len += 1;
                continue;
            },
        };
        if (len + rep.len > buf.len) break;
        @memcpy(buf[len..][0..rep.len], rep);
        len += rep.len;
    }
    return buf[0..len];
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

    // The synthetic y=x diagonal is excluded from the hover data: its value at
    // any x is just x, already shown in the header. `conv` above still carries
    // it (drawn as the dashed reference line), so filter separately here.
    var hover_n: usize = 0;
    for (series) |s| {
        if (!s.ref) hover_n += 1;
    }
    const hover_series = try arena.alloc(svg.Series, hover_n);
    var hi: usize = 0;
    for (conv, series) |c, s| {
        if (s.ref) continue;
        hover_series[hi] = c;
        hi += 1;
    }
    try svg.writeChartData(out, opts.id, hover_series, opts.yfmt, opts.xmax);
    try out.writeAll("</section>");
}

/// The distribution chart: `svg.histChart` plus the same hover-tooltip
/// wiring `card` gives the line charts, adapted for a LOG x-axis (percentile,
/// as n = 1/(1-p)) and a single series instead of several named ones —
/// `report.js` has its own small handler for this shape, distinguished by the
/// `data-hist` attribute on the hover-capture rect rather than `data-chart`.
fn histCard(arena: Allocator, out: *Writer, name: []const u8, pts: []const analysis.Point) !void {
    const conv = try toSvgPoints(arena, pts);

    try out.print("<div class=\"chartwrap\" id=\"wrap-hist-{s}\">", .{name});
    _ = try svg.histChart(out, name, conv);
    try out.print("<div class=\"tooltip\" id=\"tip-hist-{s}\" hidden></div></div>", .{name});

    // `decades` here must match svg.histChart's OWN internal computation
    // exactly — it defines the log-x scale report.js needs to invert to find
    // the nearest point under the cursor. Duplicated rather than threaded
    // back out of histChart, matching how `card` above already recomputes
    // `xmax`/ticks itself instead of getting them back from `svg.chart`.
    var max_n: f64 = 1;
    for (conv) |p| max_n = @max(max_n, p.x);
    const decades = @max(1.0, @ceil(std.math.log10(max_n)));

    try out.print("<script type=\"application/json\" id=\"data-hist-{s}\">", .{name});
    var j = jsonw.Writer{ .w = out };
    try j.beginObject();
    try j.key("pts");
    try j.beginArray();
    for (conv) |p| {
        try j.beginArray();
        try j.float(p.x, 4);
        try j.float(p.y, 4);
        try j.endArray();
    }
    try j.endArray();
    try j.key("decades");
    try j.float(decades, 4);
    try j.key("geom");
    try j.beginArray();
    for ([_]f64{ svg.w, svg.h, svg.ml, svg.mr, svg.mt, svg.mb }) |v| try j.int(@intFromFloat(v));
    try j.endArray();
    try j.endObject();
    try out.writeAll("</script>");
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
        .dist_hist = null,
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

test "a local run is banner-marked, and a cloud run is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const empty: report.Gathered = .{ .present = &.{}, .rps = &.{}, .cpu = &.{}, .p99 = &.{}, .shed = &.{} };
    const base: Options = .{ .runid = "r", .profile_name = "c1k", .ref_rate = 2000, .connections = 1000, .deadline_ms = 0 };

    var lbuf: [128 * 1024]u8 = undefined;
    var lout: std.Io.Writer = .fixed(&lbuf);
    var local_opts = base;
    local_opts.origin = .local;
    try render(arena_state.allocator(), &lout, empty, &.{}, local_opts);
    try std.testing.expect(std.mem.indexOf(u8, lout.buffered(), "not a benchmark result") != null);

    var cbuf: [128 * 1024]u8 = undefined;
    var cout: std.Io.Writer = .fixed(&cbuf);
    try render(arena_state.allocator(), &cout, empty, &.{}, base);
    try std.testing.expect(std.mem.indexOf(u8, cout.buffered(), "not a benchmark result") == null);
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

test "escapeHtml neutralizes the three HTML metacharacters" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "a &lt;script&gt; &amp; more",
        escapeHtml(&buf, "a <script> & more"),
    );
}

test "a degraded proxy's note is escaped in the badge" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var present = [_]report.ProxyData{.{
        .name = "zoxy",
        .rows = &.{},
        .sustained = 100,
        .hist = null,
        .dist_hist = null,
        .hgrm_file = "",
        .mem = null,
        .cpu = &.{},
        .p99 = &.{},
        .shed_raw = &.{},
    }};
    const statuses = [_]artifact.ProxyRecord{.{
        .name = "zoxy",
        .status = .degraded,
        .notes = &.{"<script>alert(1)</script> & friends"},
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
    try std.testing.expect(std.mem.indexOf(u8, s, "<script>alert") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "&lt;script&gt;alert(1)&lt;/script&gt; &amp; friends") != null);
}

test "the chart data blob is well-formed JSON built through jsonw, not string concatenation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [16 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const series = [_]report.Series{.{
        .name = "zo\"xy", // a quote, to prove the writer escapes rather than corrupting the blob
        .pts = &.{ .{ .x = 1, .y = 2.5 }, .{ .x = 3, .y = 4 } },
    }};
    try card(arena, &out, "title", "sub", .{ .id = "rps", .yfmt = .si }, &series);

    const s = out.buffered();
    const start = std.mem.indexOf(u8, s, "<script type=\"application/json\" id=\"data-rps\">").? +
        "<script type=\"application/json\" id=\"data-rps\">".len;
    const end = std.mem.indexOf(u8, s[start..], "</script>").? + start;
    const blob = s[start..end];

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, blob, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("zo\"xy", root.get("series").?.array.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("si", root.get("yfmt").?.string);
    try std.testing.expect(root.get("geom").?.array.items.len == 6);
    try std.testing.expect(root.get("xmax") != null);
}

test "the page carries no external font imports" {
    // On a public Pages site an @import would send every viewer's address to a
    // third party, and a Discord attachment must render offline.
    try std.testing.expect(std.mem.indexOf(u8, css, "@import") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, "fonts.googleapis.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, "fontshare.com") == null);
}

test "the report names the build each number came from" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var present = [_]report.ProxyData{.{
        .name = "zoxy",
        .rows = &.{},
        .sustained = 43120,
        .hist = null,
        .dist_hist = null,
        .hgrm_file = "",
        .mem = null,
        .cpu = &.{},
        .p99 = &.{},
        .shed_raw = &.{},
    }};
    const statuses = [_]artifact.ProxyRecord{.{
        .name = "zoxy",
        .status = .degraded,
        .version = "zoxy 0.0.5",
        .zoxy_commit = "03308bfe33d2a0239cf2e40fe28e6a78686bb634",
        .notes = &.{
            "STALE BUILD — ran zoxy 03308bf, but main was 91d03b1 when this build ran",
            "compiled for this host's CPU with SIMD",
        },
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

    // The version that answered, and the commit that produced it — a number
    // without its build is not reproducible.
    try std.testing.expect(std.mem.indexOf(u8, s, "zoxy 0.0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "@03308bfe3") != null);
    // Short sha in the table; the full one stays in profile.json.
    try std.testing.expect(std.mem.indexOf(u8, s, "03308bfe33d2a0239cf2e40fe28e6a78686bb634") == null);

    // EVERY note reaches the page. Both of these used to be dropped: notes
    // rendered only on `degraded` and only the first one.
    try std.testing.expect(std.mem.indexOf(u8, s, "STALE BUILD") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "compiled for this host's CPU with SIMD") != null);
}

test "an ok proxy's notes are rendered too, not only a degraded one's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var present = [_]report.ProxyData{.{
        .name = "zoxy",
        .rows = &.{},
        .sustained = 43120,
        .hist = null,
        .dist_hist = null,
        .hgrm_file = "",
        .mem = null,
        .cpu = &.{},
        .p99 = &.{},
        .shed_raw = &.{},
    }};
    // The exact case that was invisible: suite.zig records the SIMD-parity note
    // because it "must travel WITH the numbers", and the proxy is perfectly ok.
    const statuses = [_]artifact.ProxyRecord{.{
        .name = "zoxy",
        .status = .ok,
        .notes = &.{"compiled for this host's CPU with SIMD; stock images are generic x86-64"},
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
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "generic x86-64") != null);
}

test "a version banner is shortened to the version" {
    var buf: [128]u8 = undefined;
    // Every one of these is real output, captured from the images compose.yaml
    // pins. Rendered verbatim they are 67 and 88 characters wide.
    try std.testing.expectEqualStrings(
        "3.0.25",
        shortVersion(&buf, "HAProxy version 3.0.25-eb573a937 2026/07/03 - https://haproxy.org/"),
    );
    try std.testing.expectEqualStrings(
        "1.33.14",
        shortVersion(&buf, "envoy  version: 14197ab296e1a276facff37b918d62794f0cf48c/1.33.14/Clean/RELEASE/BoringSSL"),
    );
    try std.testing.expectEqualStrings("0.0.5", shortVersion(&buf, "zoxy 0.0.5"));
    try std.testing.expectEqualStrings("1.27.5", shortVersion(&buf, "nginx version: nginx/1.27.5"));
    // The image-reference fallback, for a proxy with no version CLI.
    try std.testing.expectEqualStrings("0.8", shortVersion(&buf, "zoxy-bench/pingora-http:0.8"));
}

test "version shortening does not mistake a sha or a date for a version" {
    // The two digit-bearing decoys that sit next to the real version in these
    // banners. envoy's leading sha has no dots; haproxy's date is split into
    // 2026 / 07 / 03 by the same separators and none of those has dots either.
    try std.testing.expect(versionToken("14197ab296e1a276facff37b918d62794f0cf48c") == null);
    try std.testing.expect(versionToken("2026") == null);
    try std.testing.expect(versionToken("07") == null);
    try std.testing.expect(versionToken("haproxy.org") == null);
    try std.testing.expect(versionToken("") == null);

    try std.testing.expectEqualStrings("1.33.14", versionToken("1.33.14").?);
    // A build tag is dropped — the release is what a reader compares.
    try std.testing.expectEqualStrings("3.0.25", versionToken("3.0.25-eb573a937").?);
}

test "an unrecognised version format is truncated, never dropped" {
    var buf: [128]u8 = undefined;
    // A proxy added later that prints something with no dotted version in it.
    // Losing the shortening is cosmetic; losing the version is not.
    const raw = "some-proxy built from an unusual banner with no version number";
    const got = shortVersion(&buf, raw);
    try std.testing.expect(got.len > 0);
    try std.testing.expect(got.len <= 24);
    try std.testing.expect(std.mem.startsWith(u8, raw, got));
}

test "the full version survives as a hover title, and cannot break out of it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var present = [_]report.ProxyData{.{
        .name = "haproxy",
        .rows = &.{},
        .sustained = 21000,
        .hist = null,
        .dist_hist = null,
        .hgrm_file = "",
        .mem = null,
        .cpu = &.{},
        .p99 = &.{},
        .shed_raw = &.{},
    }};
    const statuses = [_]artifact.ProxyRecord{.{
        .name = "haproxy",
        .status = .ok,
        .version = "HAProxy version 3.0.25-eb573a937 \"quoted\" - https://haproxy.org/",
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

    // Short in the cell, full in the title — nothing is lost to the shortening.
    try std.testing.expect(std.mem.indexOf(u8, s, ">3.0.25<") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "title=\"HAProxy version") != null);
    // The quote inside the version must not be able to close the attribute.
    try std.testing.expect(std.mem.indexOf(u8, s, "&quot;quoted&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"quoted\"") == null);
}

test "every row carries a provenance line, so none is shorter than its neighbours" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The mix that made the table uneven: `direct` has no container and so no
    // version, while the proxy beside it has one. Without a line on both, one
    // row is a line shorter than the other.
    var present = [_]report.ProxyData{
        .{
            .name = "haproxy",
            .rows = &.{},
            .sustained = 21000,
            .hist = null,
            .dist_hist = null,
            .hgrm_file = "",
            .mem = null,
            .cpu = &.{},
            .p99 = &.{},
            .shed_raw = &.{},
        },
        .{
            .name = "direct",
            .rows = &.{},
            .sustained = 67000,
            .hist = null,
            .dist_hist = null,
            .hgrm_file = "",
            .mem = null,
            .cpu = &.{},
            .p99 = &.{},
            .shed_raw = &.{},
        },
    };
    const statuses = [_]artifact.ProxyRecord{
        .{ .name = "haproxy", .status = .ok, .version = "HAProxy version 3.0.25-eb573a937 2026/07/03" },
        .{ .name = "direct", .status = .ok },
    };

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

    // One `.prov` per data row — two rows, two lines.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, s, "class=\"prov\""));
    // And direct's says why it has no version rather than sitting blank.
    try std.testing.expect(std.mem.indexOf(u8, s, "no proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, ">3.0.25<") != null);
}

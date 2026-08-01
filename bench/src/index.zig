//! Builds the GitHub Pages site and the nightly-over-time trend chart.
//!
//! Only the most recent run is published — `actions/deploy-pages` replaces the
//! site wholesale — so the run-to-run history lives in a single `history.ndjson`
//! at the site root, fetched from the live site before deploying and republished
//! with tonight's rows appended. That circularity is deliberate: it keeps
//! history without a database, a branch, or a nightly commit.
//!
//! Losing history is explicitly survivable. A 404 on the first run, or a failed
//! fetch, costs one night of trend data and nothing else, because the durable
//! record is the workflow artifact rather than this page.

const std = @import("std");

const artifact = @import("artifact.zig");
const jsonw = @import("jsonw.zig");
const redact = @import("redact.zig");
const report = @import("report.zig");
const svg = @import("svg.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const css = @embedFile("assets/report.css");
const js = @embedFile("assets/report.js");

/// One row of history: a single proxy's result in a single profile on a single
/// night. NDJSON so appending is a concatenation and a truncated write costs one
/// line rather than the file.
pub const HistoryRow = struct {
    runid: []const u8,
    ts: []const u8,
    profile: []const u8,
    proxy: []const u8,
    status: []const u8,
    sustained: f64,
    p50_ms: ?f64 = null,
    p99_ms: ?f64 = null,
    mem: ?f64 = null,
};

pub fn writeHistory(w: *Writer, rows: []const HistoryRow) !void {
    for (rows) |r| {
        var j = jsonw.Writer{ .w = w };
        try j.beginObject();
        try j.key("runid");
        try j.string(r.runid);
        try j.key("ts");
        try j.string(r.ts);
        try j.key("profile");
        try j.string(r.profile);
        try j.key("proxy");
        try j.string(r.proxy);
        try j.key("status");
        try j.string(r.status);
        try j.key("sustained");
        try j.float(r.sustained, 1);
        try j.key("p50_ms");
        if (r.p50_ms) |v| try j.float(v, 4) else try j.nullValue();
        try j.key("p99_ms");
        if (r.p99_ms) |v| try j.float(v, 4) else try j.nullValue();
        try j.key("mem");
        if (r.mem) |v| try j.float(v, 1) else try j.nullValue();
        try j.endObject();
        try w.writeByte('\n');
    }
}

pub fn parseHistory(arena: Allocator, text: []const u8) ![]HistoryRow {
    var out: std.ArrayList(HistoryRow) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // A malformed line is skipped rather than fatal: history is a
        // convenience, and one bad row must not cost the whole trend.
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        const o = v.object;
        try out.append(arena, .{
            .runid = if (o.get("runid")) |x| x.string else "",
            .ts = if (o.get("ts")) |x| x.string else "",
            .profile = if (o.get("profile")) |x| x.string else "",
            .proxy = if (o.get("proxy")) |x| x.string else "",
            .status = if (o.get("status")) |x| x.string else "ok",
            .sustained = num(o.get("sustained")) orelse 0,
            .p50_ms = num(o.get("p50_ms")),
            .p99_ms = num(o.get("p99_ms")),
            .mem = num(o.get("mem")),
        });
    }
    return out.toOwnedSlice(arena);
}

fn num(v: ?std.json.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// Sustained throughput for `proxy` in `profile` on the most recent PRIOR run,
/// used for the vs-last-night delta. Only `ok` rows count: comparing against a
/// degraded night would report a regression that is really just a short ramp.
pub fn previousSustained(
    rows: []const HistoryRow,
    profile_name: []const u8,
    proxy: []const u8,
    exclude_runid: []const u8,
) ?f64 {
    var best: ?HistoryRow = null;
    for (rows) |r| {
        if (!std.mem.eql(u8, r.profile, profile_name)) continue;
        if (!std.mem.eql(u8, r.proxy, proxy)) continue;
        if (std.mem.eql(u8, r.runid, exclude_runid)) continue;
        if (!std.mem.eql(u8, r.status, "ok")) continue;
        // runids are UTC timestamps, so lexicographic order is chronological.
        if (best == null or std.mem.order(u8, r.runid, best.?.runid) == .gt) best = r;
    }
    return if (best) |b| b.sustained else null;
}

/// Whether a history row's status means it carries numbers worth drawing.
///
/// The same rule `artifact.Status.usable` states — ok or degraded — applied to
/// the status as history.ndjson spells it. An unrecognised status is treated as
/// not plottable: a row this build does not understand is not one to guess at.
///
/// Deliberately NOT used by `previousSustained`: excluding degraded nights from
/// the delta BASELINE is correct for the reason documented there, and that is a
/// different question from whether the night appears on the trend at all.
fn plottable(status: []const u8) bool {
    const s = std.meta.stringToEnum(artifact.Status, status) orelse return false;
    return s.usable();
}

pub fn delta(now: f64, before: ?f64) ?f64 {
    const prev = before orelse return null;
    if (prev == 0) return null;
    return (now - prev) / prev;
}

pub const ProfileSummary = struct {
    name: []const u8,
    ok: usize,
    failed: usize,
    connections: u32,
    deadline_ms: u64,
};

/// The landing page: what ran, how it went, and the trend.
pub fn renderIndex(
    arena: Allocator,
    out: *Writer,
    runid: []const u8,
    finished: []const u8,
    profiles: []const ProfileSummary,
    history: []const HistoryRow,
) !void {
    try out.writeAll(
        \\<!doctype html><html lang=en><head><meta charset=utf-8>
        \\<meta name=viewport content="width=device-width,initial-scale=1">
        \\<meta name="color-scheme" content="dark">
        \\<meta name="theme-color" content="#0e1016">
    );
    try out.print("<title>zoxy bench · {s}</title><style>", .{runid});
    try out.writeAll(css);
    try out.writeAll("</style></head><body>");

    try out.writeAll("<div class=\"eyebrow\">HTTP (L7) proxy benchmark · nightly</div>");
    try out.print("<h1>latest run <span class=\"rid\">{s}</span></h1>", .{runid});
    try out.print("<p class=\"meta\">Finished {s}. Only the most recent run is published here; " ++
        "every run's raw data is kept as a workflow artifact.</p>", .{finished});

    try out.writeAll("<div class=\"tablewrap\"><table><tr><th>profile</th><th>connections</th>" ++
        "<th>deadline</th><th>result</th><th></th></tr>");
    for (profiles) |p| {
        try out.print("<tr><td>{s}</td><td>{d}</td>", .{ p.name, p.connections });
        if (p.deadline_ms > 0) {
            try out.print("<td>{d}ms</td>", .{p.deadline_ms});
        } else {
            try out.writeAll("<td>—</td>");
        }
        if (p.failed > 0) {
            try out.print("<td><span class=\"badge fail\">{d}/{d} ok</span></td>", .{ p.ok, p.ok + p.failed });
        } else {
            try out.print("<td><span class=\"badge\">{d}/{d} ok</span></td>", .{ p.ok, p.ok + p.failed });
        }
        try out.print("<td><a href=\"{s}/\">open report →</a></td></tr>", .{p.name});
    }
    try out.writeAll("</table></div>");

    // --- trend, one line per proxy per profile
    //
    // Wrapped in the SAME `.grid2` html.zig's own chart section uses: `.card`
    // itself carries no margin (the page resets `margin:0` globally), so
    // spacing between these sections comes ENTIRELY from `.grid2`'s `gap` —
    // without this wrapper, one profile's trend card sits flush against the
    // next with no visible separation at all.
    var any_trend = false;
    for (profiles) |p| {
        if ((try trendSeries(arena, history, p.name)).series.len > 0) any_trend = true;
    }
    if (any_trend) {
        try out.writeAll("<div class=\"grid2\">");
        for (profiles) |p| {
            const trend = try trendSeries(arena, history, p.name);
            const series = trend.series;
            if (series.len == 0) continue;

            const id = try std.fmt.allocPrint(arena, "trend-{s}", .{p.name});

            try out.print(
                "<section class=\"card\"><h2>{s} · sustained req/s over time</h2>" ++
                    "<p class=\"sub\">one point per night; a fresh fleet each run, so read a proxy " ++
                    "against the direct baseline of the same night rather than in absolute terms</p>",
                .{p.name},
            );
            // A static legend, not just the hover tooltip: this is the site's
            // landing page, screenshotted and shared far more than a run
            // report is, so a reader has to be able to tell the lines apart
            // without moving the mouse.
            try out.writeAll("<p class=\"legend\">");
            for (series) |s| {
                try out.print("<span class=\"lgitem\"><span class=\"swatch s-{s}\"></span>{s}</span>", .{ s.name, s.name });
            }
            try out.writeAll("</p>");
            try out.print("<div class=\"chartwrap\" id=\"wrap-{s}\">", .{id});
            _ = try svg.chart(out, .{
                .id = id,
                .yfmt = .si,
                .y_unit = "req/s",
                .x_label = "run",
                // One point per night, so the nights have to be visible as
                // points. Without this a profile with a single night of
                // history drew an empty chart — a one-point `<polyline>` has
                // no segment to stroke — and the newest run was simply absent
                // from the overview.
                .markers = true,
            }, series);
            try out.print("<div class=\"tooltip\" id=\"tip-{s}\" hidden></div></div>", .{id});
            // x is a run INDEX here, not a rate — pass the run ids so hovering a
            // night names it, instead of the tooltip claiming an offered req/s
            // this chart has no axis for.
            try svg.writeChartData(out, id, series, .si, null, .{
                .name = "run",
                .labels = trend.runids,
            });
            try out.writeAll("</section>");
        }
        try out.writeAll("</div>");
    }

    try out.writeAll("<footer>generated by bench — <a href=\"https://zoxy.io\">zoxy.io</a></footer><script>");
    try out.writeAll(js);
    try out.writeAll("</script></body></html>");
}

/// One series per proxy, x = run index oldest-to-newest.
///
/// The x axis is an index rather than a date because runs are not evenly spaced
/// — a night can be skipped — and plotting an index keeps every point visible
/// instead of bunching them.
const Trend = struct {
    series: []svg.Series,
    /// The run id at each x position, so the hover tooltip can name the night
    /// instead of reporting a bare ordinal ("run 3" answers nothing).
    runids: [][]const u8,
};

fn trendSeries(arena: Allocator, history: []const HistoryRow, profile_name: []const u8) !Trend {
    var runids: std.ArrayList([]const u8) = .empty;
    for (history) |r| {
        if (!std.mem.eql(u8, r.profile, profile_name)) continue;
        var seen = false;
        for (runids.items) |x| {
            if (std.mem.eql(u8, x, r.runid)) seen = true;
        }
        if (!seen) try runids.append(arena, r.runid);
    }
    if (runids.items.len == 0) return .{ .series = &.{}, .runids = &.{} };
    std.mem.sort([]const u8, runids.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var out: std.ArrayList(svg.Series) = .empty;
    for (report.proxy_order) |proxy| {
        var pts: std.ArrayList(svg.Point) = .empty;
        for (runids.items, 0..) |rid, i| {
            for (history) |r| {
                if (!std.mem.eql(u8, r.profile, profile_name)) continue;
                if (!std.mem.eql(u8, r.proxy, proxy)) continue;
                if (!std.mem.eql(u8, r.runid, rid)) continue;
                // A failed night leaves a GAP rather than a zero, so the line
                // does not dive to the floor and read as a collapse.
                //
                // GAP means failed or skipped — a night with no numbers. It
                // does NOT mean degraded: that status is defined as "usable but
                // incomplete", the run report ranks and charts it, and
                // history.ndjson records it. Testing `status == "ok"` here (as
                // this did) silently dropped those nights from the trend while
                // still writing them to history, so the newest run could be
                // absent from the overview for the whole night — and every
                // reason a run gets marked degraded (a short ramp, absent
                // cAdvisor samples, a stale zoxy build) is a reason someone
                // would then go looking for it on exactly this chart.
                if (!plottable(r.status)) continue;
                try pts.append(arena, .{ .x = @floatFromInt(i), .y = r.sustained });
            }
        }
        if (pts.items.len == 0) continue;
        try out.append(arena, .{
            .name = proxy,
            .pts = try pts.toOwnedSlice(arena),
            .dashed = std.mem.eql(u8, proxy, "direct"),
        });
    }
    return .{ .series = try out.toOwnedSlice(arena), .runids = try runids.toOwnedSlice(arena) };
}

test "parseHistory round-trips and skips a malformed line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const rows = [_]HistoryRow{
        .{ .runid = "20260727-000104", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "ok", .sustained = 43120, .p99_ms = 1.10 },
        .{ .runid = "20260728-000102", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "ok", .sustained = 44155 },
    };
    try writeHistory(&w, &rows);

    const with_junk = try std.fmt.allocPrint(arena, "{s}not json\n", .{w.buffered()});
    const back = try parseHistory(arena, with_junk);

    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("zoxy", back[0].proxy);
    try std.testing.expectApproxEqAbs(@as(f64, 43120), back[0].sustained, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.10), back[0].p99_ms.?, 1e-6);
    try std.testing.expect(back[1].p99_ms == null);
}

test "previousSustained picks the latest prior ok run" {
    const rows = [_]HistoryRow{
        .{ .runid = "20260726-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "ok", .sustained = 40000 },
        .{ .runid = "20260727-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "ok", .sustained = 42000 },
        .{ .runid = "20260728-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "ok", .sustained = 43000 },
    };
    // Tonight is 0728, so the comparison must be 0727 rather than the oldest.
    try std.testing.expectApproxEqAbs(
        @as(f64, 42000),
        previousSustained(&rows, "c1k", "zoxy", "20260728-000100").?,
        0.5,
    );
}

test "previousSustained ignores degraded and failed nights" {
    const rows = [_]HistoryRow{
        .{ .runid = "20260726-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "ok", .sustained = 40000 },
        // A short ramp would report a huge fake regression if compared against.
        .{ .runid = "20260727-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "degraded", .sustained = 9000 },
    };
    try std.testing.expectApproxEqAbs(
        @as(f64, 40000),
        previousSustained(&rows, "c1k", "zoxy", "20260728-000100").?,
        0.5,
    );
}

test "previousSustained does not cross profiles or proxies" {
    const rows = [_]HistoryRow{
        .{ .runid = "20260727-000100", .ts = "t", .profile = "c10k", .proxy = "zoxy", .status = "ok", .sustained = 20000 },
        .{ .runid = "20260727-000100", .ts = "t", .profile = "c1k", .proxy = "haproxy", .status = "ok", .sustained = 30000 },
    };
    try std.testing.expect(previousSustained(&rows, "c1k", "zoxy", "x") == null);
}

test "delta is a ratio and guards a zero baseline" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.025), delta(41000, 40000).?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -0.025), delta(39000, 40000).?, 1e-9);
    try std.testing.expect(delta(100, null) == null);
    try std.testing.expect(delta(100, 0) == null);
}

test "the trend leaves a gap for a failed night rather than plotting zero" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]HistoryRow{
        .{ .runid = "20260726-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "ok", .sustained = 40000 },
        .{ .runid = "20260727-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "failed", .sustained = 0 },
        .{ .runid = "20260728-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "ok", .sustained = 41000 },
    };
    const series = (try trendSeries(arena, &rows, "c1k")).series;
    try std.testing.expectEqual(@as(usize, 1), series.len);
    // Three runs, two plotted points: the failed night is absent, not a zero
    // that would read as a collapse.
    try std.testing.expectEqual(@as(usize, 2), series[0].pts.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0), series[0].pts[0].x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), series[0].pts[1].x, 1e-9);
}

test "trend cards for multiple profiles sit inside one grid2, for spacing" {
    // `.card` carries no margin of its own — every other multi-card section
    // on this page relies on `.grid2`'s `gap` for spacing between cards, and
    // this loop used to emit its `<section class="card">`s with no such
    // wrapper at all, so consecutive profiles' trend charts sat flush against
    // each other with no visible gap.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]HistoryRow{
        .{ .runid = "r1", .ts = "t", .profile = "c100", .proxy = "zoxy", .status = "ok", .sustained = 1000 },
        .{ .runid = "r1", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "ok", .sustained = 40000 },
    };
    const profiles = [_]ProfileSummary{
        .{ .name = "c100", .ok = 1, .failed = 0, .connections = 100, .deadline_ms = 0 },
        .{ .name = "c1k", .ok = 1, .failed = 0, .connections = 1000, .deadline_ms = 0 },
    };

    var buf: [256 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try renderIndex(arena, &out, "r1", "t", &profiles, &rows);

    const s = out.buffered();
    const grid_start = std.mem.indexOf(u8, s, "<div class=\"grid2\">").?;
    const c100_card = std.mem.indexOf(u8, s, "data-chart=\"trend-c100\"").?;
    const c1k_card = std.mem.indexOf(u8, s, "data-chart=\"trend-c1k\"").?;
    // Both trend charts must be INSIDE the same grid2, not before it.
    try std.testing.expect(grid_start < c100_card);
    try std.testing.expect(grid_start < c1k_card);
}

test "the landing page is IP-clean and names each profile's result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var buf: [256 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const profiles = [_]ProfileSummary{
        .{ .name = "c1k", .ok = 4, .failed = 0, .connections = 1000, .deadline_ms = 0 },
        .{ .name = "c10k", .ok = 3, .failed = 1, .connections = 10000, .deadline_ms = 1000 },
    };
    try renderIndex(arena_state.allocator(), &out, "20260728-000102", "2026-07-28T00:52:11Z", &profiles, &.{});

    const s = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "4/4 ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "3/4 ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "1000ms") != null);
    try redact.assertNoIps("index.html", s);
}

test "the trend plots a degraded night — it is usable data, not a gap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The bug this covers: the newest run was written to history.ndjson and
    // then dropped from the trend, so the overview showed nothing for it. The
    // filter tested `status == "ok"`, which also excluded `degraded` — and
    // degraded is exactly the state a run lands in for a short ramp, absent
    // cAdvisor samples, or a stale zoxy build, each of which is a reason to go
    // looking for that night on this chart.
    const rows = [_]HistoryRow{
        .{ .runid = "20260730-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "ok", .sustained = 40000 },
        .{ .runid = "20260731-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "degraded", .sustained = 41000 },
        .{ .runid = "20260801-000100", .ts = "t", .profile = "c1k", .proxy = "zoxy", .status = "degraded", .sustained = 42000 },
    };
    const series = (try trendSeries(arena, &rows, "c1k")).series;
    try std.testing.expectEqual(@as(usize, 1), series.len);
    try std.testing.expectEqual(@as(usize, 3), series[0].pts.len);
    // Including the newest, at the right-hand end.
    try std.testing.expectApproxEqAbs(@as(f64, 2), series[0].pts[2].x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 42000), series[0].pts[2].y, 1e-9);
}

test "plottable matches artifact.Status.usable, and distrusts what it cannot parse" {
    try std.testing.expect(plottable("ok"));
    try std.testing.expect(plottable("degraded"));
    // No numbers to draw.
    try std.testing.expect(!plottable("failed"));
    try std.testing.expect(!plottable("skipped"));
    // A status written by some other build: not guessed at.
    try std.testing.expect(!plottable("weird"));
    try std.testing.expect(!plottable(""));
}

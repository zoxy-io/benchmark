//! Renders a run directory into report.json and report.html.
//!
//! report.json is the canonical measured-data artifact. Gate: `bench report`
//! must reproduce report/report.py's output field-for-field, hence the care
//! over key order, round-half-to-even and float printing.

const std = @import("std");
const zrk = @import("zrk");

const analysis = @import("analysis.zig");
const artifact = @import("artifact.zig");
const cadvisor = @import("cadvisor.zig");
const jsonw = @import("jsonw.zig");

const Allocator = std.mem.Allocator;
const Histogram = zrk.hdr.Histogram;
const Point = analysis.Point;

/// Display order for the summary table and series lists; unlisted proxies
/// follow in run order.
///
/// Keep `direct`: `bench index` walks this list for the trend chart, and
/// history.ndjson still has direct rows.
pub const proxy_order = [_][]const u8{
    "zoxy", "haproxy", "nginx", "pingora", "envoy", "direct",
};

/// Dark-ground hues (zoxy.io palette): zoxy is the amber signal, the rest are
/// distinct and legible on ink.
pub const palette = [_]struct { name: []const u8, hex: []const u8 }{
    .{ .name = "zoxy", .hex = "#fb9e0e" },
    .{ .name = "haproxy", .hex = "#38bdf8" },
    // Matches --c-nginx in report.css.
    .{ .name = "nginx", .hex = "#34d399" },
    .{ .name = "pingora", .hex = "#f472b6" },
    .{ .name = "envoy", .hex = "#a78bfa" },
    .{ .name = "direct", .hex = "#6d7385" },
};

pub fn colorOf(name: []const u8) ?[]const u8 {
    for (palette) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.hex;
    }
    return null;
}

/// Everything measured for one proxy, so HTML and JSON share the same numbers.
pub const ProxyData = struct {
    name: []const u8,
    rows: []analysis.Window,
    sustained: f64,
    /// Reference-band histogram (fixed rate, warmup excluded) for the summary
    /// table's p50/p99; see profile.zig's `ref_rate`.
    hist: ?Histogram,
    /// Whole-run histogram for the distribution chart; matches `hgrm_file`.
    /// Kept separate from `hist` on purpose.
    dist_hist: ?Histogram,
    hgrm_file: []const u8,
    /// Peak container working-set bytes; null without cAdvisor samples.
    mem: ?f64,
    /// Container cores vs offered; empty when no cAdvisor samples exist.
    cpu: []Point,
    p99: []Point,
    shed_raw: []Point,
};

pub const Series = struct {
    name: []const u8,
    pts: []const Point,
    /// The synthetic y=x perfect-keep-up diagonal.
    ref: bool = false,
};

pub const Gathered = struct {
    present: []ProxyData,
    rps: []Series,
    cpu: []Series,
    p99: []Series,
    shed: []Series,

    /// Frees the histograms, whose counts live in the general-purpose
    /// allocator rather than the arena.
    pub fn deinit(self: *Gathered) void {
        for (self.present) |*p| {
            if (p.hist) |*h| h.deinit();
            p.hist = null;
            if (p.dist_hist) |*h| h.deinit();
            p.dist_hist = null;
        }
    }
};

pub const Ramp = struct {
    start_rate: ?i64 = null,
    max_rate: ?i64 = null,
    ramp_seconds: ?i64 = null,
};

/// Compute every curve and summary for a run directory. `ref_rate`/`ref_band`
/// come from the profile; see profile.zig's `ref_rate`.
pub fn gather(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    dir: []const u8,
    proxies: []const ProxyInput,
    ref_rate: f64,
    ref_band: f64,
) !Gathered {
    var out: std.ArrayList(ProxyData) = .empty;

    for (proxies) |in| {
        // Drop each loadgen's end-of-run partial flush before merging.
        const per_tag = try arena.alloc([]analysis.TsRow, in.tags.len);
        for (in.tags, 0..) |tag, i| {
            const path = try artifactPath(arena, dir, in.name, tag, "ndjson");
            per_tag[i] = try analysis.fullWindows(arena, try analysis.readNdjson(arena, io, path));
        }
        const per_tag_const = try arena.alloc([]const analysis.TsRow, per_tag.len);
        for (per_tag, 0..) |r, i| per_tag_const[i] = r;

        const rows = try analysis.merge(arena, per_tag_const);

        // Reference histogram and p99 curve read only the first tag's rows
        // (as report.py): merging two machines' tails would misstate both.
        const first = if (per_tag.len > 0) per_tag[0] else &.{};

        var raw_shed: std.ArrayList(Point) = .empty;
        for (rows) |r| {
            if (r.t >= 3 and r.offered > 0) {
                try raw_shed.append(arena, .{ .x = r.offered, .y = r.shed });
            }
        }

        try out.append(arena, .{
            .name = in.name,
            .rows = rows,
            .sustained = analysis.sustained(rows),
            .hist = try analysis.refHist(gpa, first, ref_rate, ref_band),
            .dist_hist = try analysis.wholeRunHist(gpa, first),
            .hgrm_file = try hgrmFilename(arena, io, dir, in.name, in.tags),
            .mem = in.mem,
            .cpu = in.cpu,
            .p99 = try analysis.p99Curve(gpa, arena, first, analysis.p99_keepup, analysis.p99_window),
            .shed_raw = try analysis.smoothMedian(arena, raw_shed.items, 15),
        });
    }

    const present = try out.toOwnedSlice(arena);

    // --- rps: achieved per proxy, plus the synthetic perfect-keep-up diagonal.
    var rps: std.ArrayList(Series) = .empty;
    var xmax: f64 = 1;
    for (present) |*p| {
        if (p.rows.len == 0) continue;
        const pts = try arena.alloc(Point, p.rows.len);
        for (p.rows, 0..) |r, i| {
            pts[i] = .{ .x = r.offered, .y = r.achieved };
            xmax = @max(xmax, r.offered);
        }
        try rps.append(arena, .{ .name = p.name, .pts = pts });
    }
    {
        const diag = try arena.alloc(Point, 2);
        diag[0] = .{ .x = 0, .y = 0 };
        diag[1] = .{ .x = xmax, .y = xmax };
        try rps.append(arena, .{ .name = "offered", .pts = diag, .ref = true });
    }

    // --- cpu: 7-point median, cosmetic jitter damping only. The rate is on
    // cAdvisor's clock (cadvisor.Sample.cadvisor_ms); do not widen the median
    // to fix a number that looks wrong.
    var cpu: std.ArrayList(Series) = .empty;
    for (present) |*p| {
        if (p.cpu.len == 0) continue;
        try cpu.append(arena, .{
            .name = p.name,
            .pts = try analysis.smoothMedian(arena, p.cpu, 7),
        });
    }

    // --- p99
    var p99: std.ArrayList(Series) = .empty;
    for (present) |*p| {
        if (p.p99.len == 0) continue;
        try p99.append(arena, .{ .name = p.name, .pts = p.p99 });
    }

    // --- shed: every window, no offered floor. Raw shed is signed (see
    // analysis.merge), median-smoothed, then clamped at 0.
    //
    // No baseline subtraction since `direct` was removed: the loadgen's own
    // few-% ramp-up shortfall is inside these curves (the caption says so).
    // Not comparable with pre-removal runs.
    var shed: std.ArrayList(Series) = .empty;
    for (present) |*p| {
        if (p.shed_raw.len == 0) continue;
        const pts = try arena.alloc(Point, p.shed_raw.len);
        for (p.shed_raw, 0..) |q, i| {
            pts[i] = .{ .x = q.x, .y = @max(0.0, q.y) };
        }
        try shed.append(arena, .{ .name = p.name, .pts = pts });
    }

    return .{
        .present = present,
        .rps = try rps.toOwnedSlice(arena),
        .cpu = try cpu.toOwnedSlice(arena),
        .p99 = try p99.toOwnedSlice(arena),
        .shed = try shed.toOwnedSlice(arena),
    };
}

/// Load a proxy's cAdvisor samples: container cores against OFFERED load, plus
/// peak working-set bytes. Samples are on the ramp's clock, so offered(t) is
/// analytic with no clock skew.
pub fn loadCadvisor(
    arena: Allocator,
    io: std.Io,
    dir: []const u8,
    proxy: []const u8,
    tag: []const u8,
    ramp: Ramp,
) !struct { cpu: []Point, mem: ?f64 } {
    const path = try artifactPath(arena, dir, proxy, tag, "cadvisor.ndjson");
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch
        return .{ .cpu = &.{}, .mem = null };

    const Row = struct { t: f64 = 0, cpu_seconds_total: f64 = 0, mem_ws: u64 = 0, cadvisor_ms: i64 = 0 };
    var rows: std.ArrayList(Row) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const r = std.json.parseFromSliceLeaky(Row, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        try rows.append(arena, r);
    }
    if (rows.items.len == 0) return .{ .cpu = &.{}, .mem = null };

    var peak: u64 = 0;
    for (rows.items) |r| peak = @max(peak, r.mem_ws);

    // The first sample is only a baseline. Rate denominator is cAdvisor's
    // clock, not the poll clock (see cadvisor.Sample.cadvisor_ms); x comes from
    // the ramp clock `r.t`.
    var cpu: std.ArrayList(Point) = .empty;
    if (rows.items.len >= 2) {
        const start: f64 = @floatFromInt(ramp.start_rate orelse 0);
        const end: f64 = @floatFromInt(ramp.max_rate orelse 0);
        const total: f64 = @floatFromInt(ramp.ramp_seconds orelse 0);

        for (rows.items[1..], 0..) |r, i| {
            const prev = rows.items[i];
            const span = cadvisor.rateSpanSeconds(
                .{ .t = prev.t, .cpu_seconds_total = prev.cpu_seconds_total, .mem_ws = prev.mem_ws, .cadvisor_ms = prev.cadvisor_ms },
                .{ .t = r.t, .cpu_seconds_total = r.cpu_seconds_total, .mem_ws = r.mem_ws, .cadvisor_ms = r.cadvisor_ms },
            ) orelse continue;
            const cores = (r.cpu_seconds_total - prev.cpu_seconds_total) / span;
            const frac = if (total > 0) std.math.clamp(r.t / total, 0, 1) else 0;
            try cpu.append(arena, .{ .x = start + (end - start) * frac, .y = cores });
        }
    }

    return .{ .cpu = try cpu.toOwnedSlice(arena), .mem = if (peak > 0) @floatFromInt(peak) else null };
}

/// `<dir>/<proxy>.<tag>.<ext>`, or `<dir>/<proxy>.<ext>` when the tag is empty.
/// `bench suite` writes untagged names; archived bash-harness runs use `lg1`.
fn artifactPath(
    arena: Allocator,
    dir: []const u8,
    proxy: []const u8,
    tag: []const u8,
    ext: []const u8,
) ![]const u8 {
    return if (tag.len == 0)
        std.fmt.allocPrint(arena, "{s}/{s}.{s}", .{ dir, proxy, ext })
    else
        std.fmt.allocPrint(arena, "{s}/{s}.{s}.{s}", .{ dir, proxy, tag, ext });
}

pub const ProxyInput = struct {
    name: []const u8,
    tags: []const []const u8,
    mem: ?f64 = null,
    cpu: []Point = &.{},
};

/// Basename of the whole-run .hgrm (for a download link), or "".
fn hgrmFilename(
    arena: Allocator,
    io: std.Io,
    dir: []const u8,
    proxy: []const u8,
    tags: []const []const u8,
) ![]const u8 {
    for (tags) |tag| {
        const name = if (tag.len == 0)
            try std.fmt.allocPrint(arena, "{s}.hgrm", .{proxy})
        else
            try std.fmt.allocPrint(arena, "{s}.{s}.hgrm", .{ proxy, tag });
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
            return name;
        } else |_| {}
    }
    return "";
}

/// Order proxies: `proxy_order` first, then the rest in run order.
pub fn orderPresent(arena: Allocator, names: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (proxy_order) |want| {
        for (names) |n| {
            if (std.mem.eql(u8, n, want)) try out.append(arena, n);
        }
    }
    for (names) |n| {
        var known = false;
        for (proxy_order) |want| {
            if (std.mem.eql(u8, n, want)) known = true;
        }
        if (!known) try out.append(arena, n);
    }
    return out.toOwnedSlice(arena);
}

/// The build a row's numbers came from, so report.json consumers need not
/// parse profile.json.
fn versionOf(statuses: []const artifact.ProxyRecord, name: []const u8) ?[]const u8 {
    for (statuses) |s| {
        if (std.mem.eql(u8, s.name, name)) return s.version;
    }
    return null;
}

/// The suite's verdict (`ok`, `degraded`, `failed`, `skipped`), or null when
/// missing. Without it a crash at `start` reads as `"sustained":0`
/// (zoxy-io/zoxy#283).
fn statusOf(statuses: []const artifact.ProxyRecord, name: []const u8) ?[]const u8 {
    for (statuses) |s| {
        if (std.mem.eql(u8, s.name, name)) return @tagName(s.status);
    }
    return null;
}

/// Write report.json, matching report.py's `json.dumps(...,
/// separators=(",", ":"))` exactly; see jsonw.zig.
pub fn writeJson(
    arena: Allocator,
    w: *std.Io.Writer,
    g: Gathered,
    runid: []const u8,
    generated: []const u8,
    ramp: Ramp,
    ref_rate: f64,
    ref_band: f64,
    /// Per-proxy records from profile.json; empty for legacy run dirs, which
    /// report null versions.
    statuses: []const artifact.ProxyRecord,
) !void {
    var j = jsonw.Writer{ .w = w };

    try j.beginObject();

    try j.key("schema");
    try j.int(1);

    try j.key("runid");
    try j.string(runid);

    try j.key("generated");
    try j.string(generated);

    try j.key("units");
    try j.beginObject();
    try j.key("rps");
    try j.string("req/s");
    try j.key("cpu");
    try j.string("cores");
    try j.key("p99_ms");
    try j.string("ms");
    try j.key("shed");
    try j.string("ratio");
    try j.key("mem");
    try j.string("bytes");
    try j.key("latency_ms");
    try j.string("ms");
    try j.key("hist");
    try j.string("[1/(1-percentile), ms]");
    try j.endObject();

    try j.key("ramp");
    try j.beginObject();
    try j.key("start_rate");
    try j.optInt(ramp.start_rate);
    try j.key("max_rate");
    try j.optInt(ramp.max_rate);
    try j.key("ramp_seconds");
    try j.optInt(ramp.ramp_seconds);
    try j.endObject();

    try j.key("keepup");
    try j.beginObject();
    try j.key("throughput");
    try j.float(analysis.keepup, 6);
    try j.endObject();

    try j.key("latency_ref");
    try j.beginObject();
    try j.key("rate");
    try j.float(ref_rate, 6);
    try j.key("band");
    try j.float(ref_band, 6);
    try j.endObject();

    try j.key("palette");
    try j.beginObject();
    for (g.present) |*p| {
        if (colorOf(p.name)) |hex| {
            try j.key(p.name);
            try j.string(hex);
        }
    }
    try j.endObject();

    // By max sustained descending, like the HTML table. Stable, matching
    // Python's sorted(reverse=True).
    const ranked = try arena.dupe(*ProxyData, blk: {
        const ptrs = try arena.alloc(*ProxyData, g.present.len);
        for (g.present, 0..) |*p, i| ptrs[i] = p;
        break :blk ptrs;
    });
    std.mem.sort(*ProxyData, ranked, {}, struct {
        fn desc(_: void, a: *ProxyData, b: *ProxyData) bool {
            return a.sustained > b.sustained;
        }
    }.desc);

    try j.key("proxies");
    try j.beginArray();
    for (ranked) |p| {
        try j.beginObject();
        try j.key("name");
        try j.string(p.name);
        try j.key("self");
        try j.boolean(std.mem.eql(u8, p.name, "zoxy"));

        // Verbatim, as the container answered: this file is the record, not
        // the presentation.
        try j.key("version");
        if (versionOf(statuses, p.name)) |v| try j.string(v) else try j.nullValue();

        // Before `sustained`, so the verdict precedes the number.
        try j.key("status");
        if (statusOf(statuses, p.name)) |s| try j.string(s) else try j.nullValue();

        try j.key("sustained");
        try j.int(jsonw.pyRoundToInt(p.sustained));
        try j.key("mem");
        if (p.mem) |m| try j.float(m, 6) else try j.nullValue();

        // p50/p99 at the reference load. p99, not max: max is a single sample.
        try j.key("latency_ms");
        try j.beginObject();
        const lat: ?struct { p50: f64, p99: f64 } = if (p.hist) |*h| (if (h.count() > 0) .{
            .p50 = @as(f64, @floatFromInt(h.valueAtPercentile(50))) / 1000.0,
            .p99 = @as(f64, @floatFromInt(h.valueAtPercentile(99))) / 1000.0,
        } else null) else null;
        try j.key("p50");
        if (lat) |l| try j.float(l.p50, 4) else try j.nullValue();
        try j.key("p99");
        if (lat) |l| try j.float(l.p99, 4) else try j.nullValue();
        try j.key("source");
        // 'ref' = reference-rate window; null = never reached the ref band.
        if (lat != null) try j.string("ref") else try j.nullValue();
        try j.endObject();

        try j.key("hgrm_file");
        if (p.hgrm_file.len > 0) try j.string(p.hgrm_file) else try j.nullValue();
        try j.endObject();
    }
    try j.endArray();

    try j.key("series");
    try j.beginObject();
    try j.key("rps");
    try writeSeries(arena, &j, g.rps, 1, 1.0);
    try j.key("cpu");
    try writeSeries(arena, &j, g.cpu, 6, 1.0);
    try j.key("p99_ms");
    try writeSeries(arena, &j, g.p99, 4, 1000.0);
    try j.key("shed");
    try writeSeries(arena, &j, g.shed, 6, 1.0);
    try j.endObject();

    try j.key("hist");
    try j.beginObject();
    for (g.present) |*p| {
        const h = if (p.hist) |*hh| hh else continue;
        if (h.count() == 0) continue;
        try j.key(p.name);
        try j.beginObject();
        try j.key("pts");
        try j.beginArray();
        for (try analysis.hdrPoints(arena, h)) |pt| {
            try j.beginArray();
            try j.float(pt.x, 4);
            try j.float(pt.y, 4);
            try j.endArray();
        }
        try j.endArray();
        try j.endObject();
    }
    try j.endObject();

    try j.endObject();
}

fn writeSeries(
    arena: Allocator,
    j: *jsonw.Writer,
    list: []const Series,
    ydigits: u8,
    yscale: f64,
) !void {
    try j.beginArray();
    for (list) |s| {
        if (s.pts.len == 0) continue;
        try j.beginObject();
        try j.key("name");
        try j.string(s.name);
        try j.key("pts");
        try j.beginArray();

        const sorted = try arena.dupe(Point, s.pts);
        std.mem.sort(Point, sorted, {}, struct {
            fn lt(_: void, a: Point, b: Point) bool {
                if (a.x == b.x) return a.y < b.y;
                return a.x < b.x;
            }
        }.lt);

        for (sorted) |pt| {
            try j.beginArray();
            try j.float(pt.x, 1);
            try j.float(pt.y * yscale, ydigits);
            try j.endArray();
        }
        try j.endArray();
        if (s.ref) {
            try j.key("ref");
            try j.boolean(true);
        }
        try j.endObject();
    }
    try j.endArray();
}

test "orderPresent puts known proxies in display order and keeps the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try orderPresent(arena, &.{ "pingora", "direct", "mystery", "zoxy" });
    try std.testing.expectEqualStrings("zoxy", got[0]);
    try std.testing.expectEqualStrings("pingora", got[1]);
    try std.testing.expectEqualStrings("direct", got[2]);
    try std.testing.expectEqualStrings("mystery", got[3]);
}

test "colorOf knows the shipped proxies and nothing else" {
    try std.testing.expectEqualStrings("#fb9e0e", colorOf("zoxy").?);
    try std.testing.expect(colorOf("mystery") == null);
}

test "artifactPath resolves both the tagged and untagged spellings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What `bench suite` writes.
    try std.testing.expectEqualStrings(
        "run/c1k/zoxy.ndjson",
        try artifactPath(arena, "run/c1k", "zoxy", "", "ndjson"),
    );
    // What the archived run dirs from the bash harness carry.
    try std.testing.expectEqualStrings(
        "run/zoxy.lg1.ndjson",
        try artifactPath(arena, "run", "zoxy", "lg1", "ndjson"),
    );
}

test "the charted cpu curve never exceeds a capped container's cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Rate math and 7-point median together once charted a 1-CPU container at
    // ~1.5 cores, so test the pair: smoothMedian over rateSpanSeconds output
    // for a container pegged at 1.0 core (cadvisor.peggedSamples).
    const samples = try cadvisor.peggedSamples(arena, 1.0, 300);
    var pts: std.ArrayList(analysis.Point) = .empty;
    for (samples[1..], 0..) |s, i| {
        const p = samples[i];
        const span = cadvisor.rateSpanSeconds(p, s) orelse continue;
        try pts.append(arena, .{
            .x = s.t,
            .y = (s.cpu_seconds_total - p.cpu_seconds_total) / span,
        });
    }

    const smoothed = try analysis.smoothMedian(arena, pts.items, 7);
    try std.testing.expect(smoothed.len > 100);
    for (smoothed) |p| {
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), p.y, 1e-9);
    }
}

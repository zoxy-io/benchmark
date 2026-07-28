//! Renders a run directory into report.json (and, later, report.html).
//!
//! report.json is the canonical MEASURED-data artifact: the exact numbers the
//! HTML draws, so downstream consumers never parse HTML. It is also the Phase 0
//! gate for this rewrite — `bench report` must reproduce
//! `python3 report/report.py`'s output field-for-field on an existing run
//! directory, which is the only honest proof that analysis.zig's port of the
//! measurement math is correct.
//!
//! That gate is why this file cares about things that would otherwise be
//! irrelevant: key emission order, Python's round-half-to-even, and how
//! json.dumps prints a float.

const std = @import("std");
const zrk = @import("zrk");

const analysis = @import("analysis.zig");
const jsonw = @import("jsonw.zig");

const Allocator = std.mem.Allocator;
const Histogram = zrk.hdr.Histogram;
const Point = analysis.Point;

/// Display order for the summary table and every series list. Proxies present in
/// the run but not named here follow, in the order the run recorded them.
pub const proxy_order = [_][]const u8{
    "zoxy", "haproxy", "envoy", "traefik", "nginx", "pingora", "direct",
};

/// Dark-ground hues (zoxy.io palette): zoxy is the amber signal, the rest are
/// distinct and legible on ink.
pub const palette = [_]struct { name: []const u8, hex: []const u8 }{
    .{ .name = "zoxy", .hex = "#fb9e0e" },
    .{ .name = "haproxy", .hex = "#38bdf8" },
    .{ .name = "envoy", .hex = "#f2705b" },
    .{ .name = "traefik", .hex = "#a78bfa" },
    .{ .name = "nginx", .hex = "#34d399" },
    .{ .name = "pingora", .hex = "#f472b6" },
    .{ .name = "direct", .hex = "#6d7385" },
};

pub fn colorOf(name: []const u8) ?[]const u8 {
    for (palette) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.hex;
    }
    return null;
}

/// Everything measured for one proxy, computed once so the HTML and the JSON
/// render from the SAME numbers.
pub const ProxyData = struct {
    name: []const u8,
    rows: []analysis.Window,
    sustained: f64,
    hist: ?Histogram,
    hgrm_file: []const u8,
    /// Peak container working-set bytes; null for `direct` (no container) and
    /// for any run whose cAdvisor samples are absent.
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
    /// The no-proxy origin calibration, not a competitor.
    baseline: bool = false,
};

pub const Gathered = struct {
    present: []ProxyData,
    rps: []Series,
    cpu: []Series,
    p99: []Series,
    shed: []Series,

    /// Frees the reference histograms. Everything else lives in the caller's
    /// arena, but a Histogram owns a counts array from the general-purpose
    /// allocator (zrk allocates it in `Histogram.init`), so it needs releasing
    /// explicitly.
    pub fn deinit(self: *Gathered) void {
        for (self.present) |*p| {
            if (p.hist) |*h| h.deinit();
            p.hist = null;
        }
    }
};

pub const Ramp = struct {
    start_rate: ?i64 = null,
    max_rate: ?i64 = null,
    ramp_seconds: ?i64 = null,
};

/// Compute every curve and summary for a run directory.
///
/// `ref_rate`/`ref_band` come from the profile rather than being module
/// constants, because the offered level at which a single latency number is
/// fair moves with the connection count — see profile.zig's `ref_rate` docs.
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
        // Merge the per-loadgen series, dropping zrk's end-of-run partial flush
        // from each before they are aligned by interval index.
        const per_tag = try arena.alloc([]analysis.TsRow, in.tags.len);
        for (in.tags, 0..) |tag, i| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}.{s}.ndjson", .{ dir, in.name, tag });
            per_tag[i] = try analysis.fullWindows(arena, try analysis.readNdjson(arena, io, path));
        }
        const per_tag_const = try arena.alloc([]const analysis.TsRow, per_tag.len);
        for (per_tag, 0..) |r, i| per_tag_const[i] = r;

        const rows = try analysis.merge(arena, per_tag_const);

        // The reference histogram and the p99 curve both read the first tag's
        // raw rows (report.py does the same — a second loadgen contributes to
        // throughput, but merging two machines' tails would misstate both).
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
        try rps.append(arena, .{ .name = p.name, .pts = pts, .baseline = isDirect(p.name) });
    }
    {
        const diag = try arena.alloc(Point, 2);
        diag[0] = .{ .x = 0, .y = 0 };
        diag[1] = .{ .x = xmax, .y = xmax };
        try rps.append(arena, .{ .name = "offered", .pts = diag, .ref = true });
    }

    // --- cpu: median over 7 points; cAdvisor's housekeeping thread stalls under
    // host load, gapping counter updates 2-4s, and the rate dips spuriously at
    // the gaps — 1-2 sample spikes the median erases without the systematic lag
    // a wider rate window would add. `direct` has no container to measure.
    var cpu: std.ArrayList(Series) = .empty;
    for (present) |*p| {
        if (isDirect(p.name) or p.cpu.len == 0) continue;
        try cpu.append(arena, .{
            .name = p.name,
            .pts = try analysis.smoothMedian(arena, p.cpu, 7),
        });
    }

    // --- p99
    var p99: std.ArrayList(Series) = .empty;
    for (present) |*p| {
        if (p.p99.len == 0) continue;
        try p99.append(arena, .{ .name = p.name, .pts = p.p99, .baseline = isDirect(p.name) });
    }

    // --- shed: every window shown, no offered floor. Raw shed is signed (see
    // analysis.merge) and median-smoothed; THEN the direct baseline's smoothed
    // shortfall at the same offered is subtracted before clamping at 0. The
    // loadgen itself falls a few % short of the schedule in the first ~15s
    // (connect overhead, TCP slow-start) and `direct` measures exactly that with
    // no proxy on the path — subtracting it isolates the proxy's own shedding,
    // so curves sit at zero from the left edge until the proxy's real knee.
    var base: []const Point = &.{};
    for (present) |*p| {
        if (isDirect(p.name)) base = p.shed_raw;
    }
    var shed: std.ArrayList(Series) = .empty;
    for (present) |*p| {
        if (p.shed_raw.len == 0) continue;
        const pts = try arena.alloc(Point, p.shed_raw.len);
        for (p.shed_raw, 0..) |q, i| {
            pts[i] = .{ .x = q.x, .y = @max(0.0, q.y - analysis.interp(base, q.x)) };
        }
        try shed.append(arena, .{ .name = p.name, .pts = pts, .baseline = isDirect(p.name) });
    }

    return .{
        .present = present,
        .rps = try rps.toOwnedSlice(arena),
        .cpu = try cpu.toOwnedSlice(arena),
        .p99 = try p99.toOwnedSlice(arena),
        .shed = try shed.toOwnedSlice(arena),
    };
}

pub const ProxyInput = struct {
    name: []const u8,
    tags: []const []const u8,
    mem: ?f64 = null,
    cpu: []Point = &.{},
};

fn isDirect(name: []const u8) bool {
    return std.mem.eql(u8, name, "direct");
}

/// Basename of the whole-run .hgrm (for a download link), or "".
fn hgrmFilename(
    arena: Allocator,
    io: std.Io,
    dir: []const u8,
    proxy: []const u8,
    tags: []const []const u8,
) ![]const u8 {
    for (tags) |tag| {
        const name = try std.fmt.allocPrint(arena, "{s}.{s}.hgrm", .{ proxy, tag });
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
            return name;
        } else |_| {}
    }
    return "";
}

/// Order proxies for display: `proxy_order` first, then anything else in the
/// order the run recorded it.
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

/// Write report.json. Key order and number formatting are chosen to match
/// report.py's `json.dumps(..., separators=(",", ":"))` exactly — see jsonw.zig.
pub fn writeJson(
    arena: Allocator,
    w: *std.Io.Writer,
    g: Gathered,
    runid: []const u8,
    generated: []const u8,
    ramp: Ramp,
    ref_rate: f64,
    ref_band: f64,
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

    // Ordered by max sustained throughput, same as the HTML summary table.
    // Stable: ties keep `present` order, matching Python's sorted(reverse=True).
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
        try j.key("baseline");
        try j.boolean(isDirect(p.name));
        try j.key("sustained");
        try j.int(jsonw.pyRoundToInt(p.sustained));
        try j.key("mem");
        if (p.mem) |m| try j.float(m, 6) else try j.nullValue();

        // p50/p99 at the reference load, read from the merged reference-rate
        // histogram. p99, not raw max: HdrHistogram's max is a single worst
        // sample, so one scheduling blip ruins it even in a healthy window.
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
        if (s.baseline) {
            try j.key("baseline");
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

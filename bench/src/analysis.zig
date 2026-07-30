//! The measurement math, transliterated 1:1 from report/report.py.
//!
//! This module is deliberately NOT a redesign. Every function keeps the
//! Python's name and the substance of its comment, because those comments
//! encode corrections that each cost a bad run to find: the end-of-run partial
//! flush that faked a 62k "sustained", the window-midpoint offered reference
//! that removed phantom start-of-run shedding, the deliberately-unclamped shed,
//! and the keep-up BAND that rejects post-knee catch-up bursts.
//!
//! The Phase 0 gate for the Zig rewrite is that `bench report` reproduces
//! `python3 report/report.py`'s report.json field-for-field on an existing run
//! directory. If you change a constant or a comparison here, that gate is the
//! thing that tells you whether you were right.

const std = @import("std");
const zrk = @import("zrk");

const Allocator = std.mem.Allocator;
const Histogram = zrk.hdr.Histogram;

/// throughput: "keeping up" = achieved >= KEEPUP * offered  (report.py:187)
pub const keepup: f64 = 0.90;

/// p99-vs-offered CURVE only: looser than the histogram so the line isn't
/// starved — 0.99 drops ~78% of windows, leaving a sparse, low-res curve; <=5%
/// backlog is still a fair per-window p99 reading and ~triples points.
/// (report.py:188)
pub const p99_keepup: f64 = 0.95;

/// Neighborhood width for p99Curve's merge (report.py:367 `win=9`).
pub const p99_window: usize = 9;

/// A parsed zrk `--timeseries` row. Field names mirror the NDJSON emitted by
/// zrk.report.TimeSeries.record (zrk/src/report.zig:205) so the on-disk format
/// stays exactly what the CLI would have written.
pub const TsRow = struct {
    t: f64 = 0,
    target_rate: f64 = 0,
    achieved_rate: f64 = 0,
    requests: u64 = 0,
    errors: u64 = 0,
    /// Borrowed from the arena the rows were parsed into; empty if the run was
    /// recorded without `timeseries_histogram`.
    latency_histogram: []const u8 = "",
    p50_us: f64 = 0,
    p99_us: f64 = 0,
    p999_us: f64 = 0,
    max_us: f64 = 0,
};

/// One merged measurement window, the unit every chart and summary reads.
/// Latency is in SECONDS here (report.py hands charts seconds; `yfmt="ms"`
/// scales by 1000), matching report.py:123-126.
pub const Window = struct {
    t: f64,
    offered: f64,
    achieved: f64,
    err: f64,
    shed: f64,
    p50: f64,
    p99: f64,
    p999: f64,
    max: f64,
};

pub const Point = struct { x: f64, y: f64 };

/// Parse an NDJSON file into rows in emission order, skipping junk.
/// Mirrors report.py:37 `read_ndjson`: a missing file yields no rows (not an
/// error) and an unparseable line is skipped rather than fatal — zrk writes the
/// series incrementally, so a killed run leaves a half-written final line that
/// must not invalidate the 300 good ones before it.
pub fn readNdjson(arena: Allocator, io: std.Io, path: []const u8) ![]TsRow {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };

    var rows: std.ArrayList(TsRow) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const row = parseRow(arena, line) catch continue;
        try rows.append(arena, row);
    }
    return rows.toOwnedSlice(arena);
}

fn parseRow(arena: Allocator, line: []const u8) !TsRow {
    const Parsed = struct {
        t: f64 = 0,
        target_rate: f64 = 0,
        achieved_rate: f64 = 0,
        requests: u64 = 0,
        errors: u64 = 0,
        bytes: u64 = 0,
        bytes_per_sec: f64 = 0,
        latency_us: struct {
            p50: f64 = 0,
            p90: f64 = 0,
            p99: f64 = 0,
            p99_9: f64 = 0,
            max: f64 = 0,
        } = .{},
        latency_histogram: []const u8 = "",
    };
    const p = try std.json.parseFromSliceLeaky(Parsed, arena, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return .{
        .t = p.t,
        .target_rate = p.target_rate,
        .achieved_rate = p.achieved_rate,
        .requests = p.requests,
        .errors = p.errors,
        .latency_histogram = p.latency_histogram,
        .p50_us = p.latency_us.p50,
        .p99_us = p.latency_us.p99,
        .p999_us = p.latency_us.p99_9,
        .max_us = p.latency_us.max,
    };
}

/// The measurement windows worth trusting, dropping zrk's end-of-run PARTIAL
/// flush. zrk closes a run with a final sub-interval window (dt << the ~1s grid)
/// whose achieved_rate is a handful of requests over a sliver of wall-clock — a
/// backlog-drain burst, not steady state. Its rate lands anywhere (a collapsed
/// proxy's hit 0.94x offered, sneaking past the keep-up band to fake a 62k
/// "sustained"), so exclude any window narrower than half the run's median
/// window. Window width = gap to the prior row's timestamp (first row: from
/// t=0).  (report.py:54)
pub fn fullWindows(arena: Allocator, rows: []const TsRow) ![]TsRow {
    if (rows.len == 0) return &.{};

    const dts = try arena.alloc(f64, rows.len);
    for (rows, 0..) |r, k| dts[k] = r.t - (if (k == 0) 0.0 else rows[k - 1].t);

    const sorted = try arena.dupe(f64, dts);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const nominal = sorted[sorted.len / 2];

    var out: std.ArrayList(TsRow) = .empty;
    for (rows, dts) |r, dt| {
        if (nominal > 0 and dt < 0.5 * nominal) continue;
        try out.append(arena, r);
    }
    return out.toOwnedSlice(arena);
}

/// Merge per-loadgen NDJSON into one window series, ALIGNED BY INTERVAL INDEX.
/// Combined offered/achieved are SUMS ACROSS LOADGENS (each loadgen emits one
/// row per interval); latency is the max across loadgens (a conservative tail —
/// they hit the same proxy, so distributions track).
///
/// Bucketing is by each loadgen's interval SEQUENCE INDEX, not by rounded
/// wall-clock seconds. zrk's ~1s grid drifts, so a single loadgen can emit two
/// rows that round to the same integer second (notably the last on-grid window
/// plus the end-of-run flush row at t~=duration+eps). Rounding-then-summing
/// fused those two windows and DOUBLED that point's offered/achieved — a
/// phantom spike at the right edge of every chart.  (report.py:69)
pub fn merge(arena: Allocator, per_tag: []const []const TsRow) ![]Window {
    var n: usize = 0;
    for (per_tag) |rows| n = @max(n, rows.len);
    if (n == 0) return &.{};

    const Acc = struct {
        offered: f64 = 0,
        achieved: f64 = 0,
        requests: u64 = 0,
        errors: u64 = 0,
        p50: f64 = 0,
        p99: f64 = 0,
        p999: f64 = 0,
        max: f64 = 0,
        t: f64 = 0,
    };
    const acc = try arena.alloc(Acc, n);
    @memset(acc, .{});

    for (per_tag) |rows| {
        for (rows, 0..) |r, i| {
            const a = &acc[i];
            a.offered += r.target_rate;
            a.achieved += r.achieved_rate;
            a.requests += r.requests;
            a.errors += r.errors;
            a.p50 = @max(a.p50, r.p50_us);
            a.p99 = @max(a.p99, r.p99_us);
            a.p999 = @max(a.p999, r.p999_us);
            a.max = @max(a.max, r.max_us);
            a.t = @max(a.t, r.t);
        }
    }

    const out = try arena.alloc(Window, n);
    var prev_offered: f64 = 0;
    for (acc, 0..) |a, i| {
        const err: f64 = if (a.requests != 0)
            @as(f64, @floatFromInt(a.errors)) / @as(f64, @floatFromInt(a.requests))
        else
            0;

        // shed = fraction of OFFERED load the proxy never served. Under overload
        // these HTTP proxies mostly just can't keep up rather than reject (err
        // stays low) — so the shortfall (achieved < offered) is the real
        // "shedding"; explicit rejects (e.g. zoxy's static shed response past
        // its admission cap) surface separately as errors.
        //
        // Reference the WINDOW-AVERAGE offered (midpoint of this and the
        // previous window's end rate): zrk stamps target_rate at window END,
        // which on a rising ramp overstates what was actually asked during the
        // window by slope*dt/2 — ~11% of offered in the earliest windows, which
        // read as phantom "shedding" at the start of every run (the direct
        // baseline showed the identical bump, proving no proxy was involved).
        //
        // NOT clamped at 0: per-window noise is symmetric around true zero, and
        // clamping raw windows clips only the negative half — a phantom positive
        // bias exactly where shed should read 0. The chart clamps AFTER
        // median-smoothing instead, which is unbiased.
        const mid = if (prev_offered != 0) (a.offered + prev_offered) / 2 else a.offered;
        const shed = if (mid != 0) 1.0 - a.achieved / mid else 0.0;
        prev_offered = a.offered;

        out[i] = .{
            .t = a.t,
            .offered = a.offered,
            .achieved = a.achieved,
            .err = err,
            .shed = shed,
            .p50 = a.p50 / 1e6,
            .p99 = a.p99 / 1e6,
            .p999 = a.p999 / 1e6,
            .max = a.max / 1e6,
        };
    }
    return out;
}

/// Max SUSTAINABLE throughput: the highest achieved rate while the proxy is
/// still delivering >= `keepup` of what's offered. This is the real "how fast
/// can it go" number — it excludes both the pre-knee ramp (achieved==offered,
/// not a limit) and the post-knee thrash.
///
/// Keep-up is a BAND, not a floor. A window whose achieved massively OVERSHOOTS
/// offered isn't sustained throughput — it's zrk's open-loop catch-up draining
/// backlog after a stall (CO correction). Bounding above by offered/keepup
/// rejects that post-knee thrash, the very burst the one-sided
/// `achieved >= keepup*offered` test wrongly counted as a new peak.
///
/// NOTE this supersedes loadgen/zrk-runner/src/main.zig:158 `summarize()`, which
/// was one-sided and therefore disagreed with the report past the knee.
/// (report.py:202)
pub fn sustained(rows: []const Window) f64 {
    var best: f64 = 0;
    for (rows) |r| {
        if (r.t >= 3 and r.offered > 0 and
            keepup * r.offered <= r.achieved and r.achieved <= r.offered / keepup)
        {
            best = @max(best, r.achieved);
        }
    }
    return best;
}

/// Merge the per-window HdrHistogram blobs for the windows whose OFFERED rate
/// sits within +/-`band` of `rate` — every proxy's latency at the SAME light,
/// sub-knee load. Throughput keep-up is NOT enough to isolate healthy latency:
/// near its knee a proxy serves ~offered rate while sitting on a huge standing
/// queue, so the CO-corrected tail balloons even though achieved tracks offered.
/// A shared reference rate well below every proxy's knee measures per-request
/// COST instead of queueing delay.
///
/// Returns null if the proxy never reached the reference band. Caller owns the
/// histogram.  (report.py:130)
pub fn refHist(
    gpa: Allocator,
    rows: []const TsRow,
    rate: f64,
    band: f64,
) !?Histogram {
    const lo = rate * (1 - band);
    const hi = rate * (1 + band);

    var acc: ?Histogram = null;
    errdefer if (acc) |*h| h.deinit();

    for (rows) |r| {
        if (r.t < 3) continue;
        if (r.target_rate < lo or r.target_rate > hi) continue;
        if (r.latency_histogram.len == 0) continue;

        var h = try zrk.hdr.decodeBase64(gpa, r.latency_histogram);
        if (acc) |*a| {
            defer h.deinit();
            try addCompatible(a, &h);
        } else {
            acc = h;
        }
    }
    return acc;
}

/// The whole run's latency histogram: every window merged, no rate band and no
/// warmup exclusion. This is the same aggregate `ramp.zig` writes to the
/// `.hgrm` file (`result.snapshot.hist`, zrk's own cumulative histogram) —
/// reconstructed here from the per-window blobs already in the `.ndjson`
/// rather than re-parsed from the `.hgrm` text, because the `.hgrm` format is
/// a percentile TABLE (lossy, meant for a human or `hdrhistogram` tooling to
/// read) rather than something meant to round-trip back into a `Histogram`.
///
/// Deliberately separate from `refHist`: that one exists so the SUMMARY
/// TABLE'S p50/p99 read at one common, fair, sub-knee rate — this one is for
/// the DISTRIBUTION CHART, which should show what actually happened over the
/// whole ramp, warmup included, not a fairness-filtered slice of it.
/// Returns null only when the run produced no histogram data at all.
pub fn wholeRunHist(gpa: Allocator, rows: []const TsRow) !?Histogram {
    var acc: ?Histogram = null;
    errdefer if (acc) |*h| h.deinit();

    for (rows) |r| {
        if (r.latency_histogram.len == 0) continue;

        var h = try zrk.hdr.decodeBase64(gpa, r.latency_histogram);
        if (acc) |*a| {
            defer h.deinit();
            try addCompatible(a, &h);
        } else {
            acc = h;
        }
    }
    return acc;
}

/// An empty histogram with the same geometry as `src`, so `add` is legal.
fn emptyLike(gpa: Allocator, src: *const Histogram) !Histogram {
    return Histogram.init(gpa, src.lowest_discernible, src.highest_trackable, src.sig_figs);
}

/// `Histogram.add` asserts equal `counts_len`, which in a ReleaseFast build is
/// unchecked rather than merely fatal. Blobs within one run always agree, but a
/// run dir assembled from mismatched zrk versions would silently corrupt every
/// merged percentile — so make that a named error instead.
fn addCompatible(dst: *Histogram, src: *const Histogram) !void {
    if (dst.counts_len != src.counts_len) return error.HistogramGeometryMismatch;
    dst.add(src);
}

/// Dense, low-noise p99-vs-offered curve: one point per keep-up window (full
/// x-resolution), but each p99 is read from the MERGED per-window HdrHistograms
/// of a `win`-wide neighborhood — many windows' samples instead of one ~1s
/// window's few tail samples — so the estimate is stable rather than sawtooth.
/// Median-smoothing the raw per-window p99 couldn't fix that; merging the actual
/// sample counts does.
///
/// The Python (report.py:382-401) hand-rolls a sparse (bucket, count)
/// neighborhood merge and then reaches into hdr.Hdr's private `_median_equiv` /
/// `_value_from_index` helpers, because it had to reimplement HdrHistogram. Here
/// `Histogram.add` + `valueAtPercentile` are the real thing, and they agree by
/// construction: `valueAtPercentile` uses @round(p/100 * total) then
/// `medianEquivalentValue`, exactly what the Python reproduced by hand.
/// (report.py:367)
pub fn p99Curve(
    gpa: Allocator,
    arena: Allocator,
    rows: []const TsRow,
    keep_ratio: f64,
    win: usize,
) ![]Point {
    var keep: std.ArrayList(TsRow) = .empty;
    for (rows) |r| {
        if (r.t < 3) continue;
        if (r.target_rate <= 0) continue;
        if (r.achieved_rate < keep_ratio * r.target_rate) continue;
        if (r.latency_histogram.len == 0) continue;
        try keep.append(arena, r);
    }
    if (keep.items.len == 0) return &.{};

    const hists = try arena.alloc(Histogram, keep.items.len);
    var decoded: usize = 0;
    defer for (hists[0..decoded]) |*h| h.deinit();
    for (keep.items, 0..) |r, i| {
        hists[i] = try zrk.hdr.decodeBase64(gpa, r.latency_histogram);
        decoded = i + 1;
    }

    const half = win / 2;
    var out: std.ArrayList(Point) = .empty;
    for (0..hists.len) |i| {
        // Accumulate in the geometry the blobs were RECORDED with, not this
        // build's stats.newHistogram defaults. report.py does the same
        // (`geo = hdrs[0]`), and it matters for run dirs recorded by an older
        // zrk whose histogram bounds differed — `Histogram.add` asserts equal
        // counts_len, so a fresh accumulator would abort on those.
        var acc = try emptyLike(gpa, &hists[0]);
        defer acc.deinit();

        const lo = i -| half;
        const hi = @min(hists.len, i + half + 1);
        for (hists[lo..hi]) |*h| try addCompatible(&acc, h);

        if (acc.count() == 0) continue;
        const p99_us: f64 = @floatFromInt(acc.valueAtPercentile(99));
        try out.append(arena, .{ .x = keep.items[i].target_rate, .y = p99_us / 1e6 });
    }
    return out.toOwnedSlice(arena);
}

/// (n = 1/(1-percentile), latency_ms) points across the range, for the per-proxy
/// latency-distribution card. ~10 points per decade, with the true max pinned at
/// the far right.  (report.py:174)
pub fn hdrPoints(arena: Allocator, h: *const Histogram) ![]Point {
    const total = h.count();
    if (total == 0) return &.{};

    var out: std.ArrayList(Point) = .empty;
    var n: f64 = 1.0;
    const total_f: f64 = @floatFromInt(total);
    while (n < total_f) : (n *= std.math.pow(f64, 10, 0.1)) {
        const v: f64 = @floatFromInt(h.valueAtPercentile(100.0 * (1.0 - 1.0 / n)));
        try out.append(arena, .{ .x = n, .y = v / 1000.0 });
    }
    const mx: f64 = @floatFromInt(h.max());
    try out.append(arena, .{ .x = total_f, .y = mx / 1000.0 });
    return out.toOwnedSlice(arena);
}

/// Rolling-median (odd window) over x-sorted points — damps per-window jitter
/// and lone spikes (e.g. shed-ratio blowing up in a low-offered warmup window
/// where the tiny denominator makes a small dip read as a huge fraction) while
/// keeping the trend.  (report.py:329)
pub fn smoothMedian(arena: Allocator, pts: []const Point, w: usize) ![]Point {
    const s = try arena.dupe(Point, pts);
    std.mem.sort(Point, s, {}, ptLessThan);
    if (s.len < w) return s;

    const half = w / 2;
    const out = try arena.alloc(Point, s.len);
    const scratch = try arena.alloc(f64, w);
    for (s, 0..) |p, i| {
        const lo = i -| half;
        const hi = @min(s.len, i + half + 1);
        const ys = scratch[0 .. hi - lo];
        for (s[lo..hi], 0..) |q, k| ys[k] = q.y;
        std.mem.sort(f64, ys, {}, std.sort.asc(f64));
        out[i] = .{ .x = p.x, .y = ys[ys.len / 2] };
    }
    return out;
}

fn ptLessThan(_: void, a: Point, b: Point) bool {
    if (a.x == b.x) return a.y < b.y;
    return a.x < b.x;
}

/// Linear interpolation of y at x over x-sorted points; clamps to the end values
/// outside the range, 0 if empty. Used to read the direct baseline's shed at
/// another run's offered levels (their window grids differ by fractions of a
/// second).  (report.py:345)
pub fn interp(pts: []const Point, x: f64) f64 {
    if (pts.len == 0) return 0;
    if (x <= pts[0].x) return pts[0].y;
    if (x >= pts[pts.len - 1].x) return pts[pts.len - 1].y;

    var lo: usize = 0;
    var hi: usize = pts.len - 1;
    while (hi - lo > 1) {
        const m = (lo + hi) / 2;
        if (pts[m].x <= x) lo = m else hi = m;
    }
    const a = pts[lo];
    const b = pts[hi];
    return if (b.x > a.x) a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x) else a.y;
}

/// zrk's histogram tops out at `hist_highest` (60s, zrk/src/stats.zig:35) and
/// CLAMPS rather than drops, so a catastrophically overloaded run reports every
/// tail percentile as exactly that ceiling. Those are not measurements, and the
/// report must say so instead of printing a confident number.
///
/// This is what the c10k profile's loadgen-side `deadline_ns` exists to prevent;
/// the check stays as a backstop in case a run is configured without one.
pub fn isSaturated(h: *const Histogram) bool {
    return h.max() >= 59_000_000;
}

// ---------------------------------------------------------------------------
// Tests. These pin the behaviours whose comments above explain what they cost
// to discover — a refactor that "simplifies" one of them should fail here.
// ---------------------------------------------------------------------------

test "fullWindows drops the end-of-run partial flush" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Four 1s windows plus zrk's closing sliver at t=4.05 (dt=0.05 << 0.5*1.0).
    const rows = [_]TsRow{
        .{ .t = 1.0, .achieved_rate = 100 },
        .{ .t = 2.0, .achieved_rate = 100 },
        .{ .t = 3.0, .achieved_rate = 100 },
        .{ .t = 4.0, .achieved_rate = 100 },
        .{ .t = 4.05, .achieved_rate = 9000 }, // backlog-drain burst
    };
    const kept = try fullWindows(arena, &rows);
    try std.testing.expectEqual(@as(usize, 4), kept.len);
    try std.testing.expectEqual(@as(f64, 4.0), kept[kept.len - 1].t);
}

test "sustained rejects post-knee catch-up overshoot" {
    // A window achieving far MORE than offered is backlog drain, not throughput.
    const rows = [_]Window{
        .{ .t = 5, .offered = 1000, .achieved = 1000, .err = 0, .shed = 0, .p50 = 0, .p99 = 0, .p999 = 0, .max = 0 },
        .{ .t = 6, .offered = 2000, .achieved = 9000, .err = 0, .shed = 0, .p50 = 0, .p99 = 0, .p999 = 0, .max = 0 },
    };
    try std.testing.expectEqual(@as(f64, 1000), sustained(&rows));
}

test "sustained ignores the warmup before t=3" {
    const rows = [_]Window{
        .{ .t = 1, .offered = 5000, .achieved = 5000, .err = 0, .shed = 0, .p50 = 0, .p99 = 0, .p999 = 0, .max = 0 },
        .{ .t = 4, .offered = 1000, .achieved = 1000, .err = 0, .shed = 0, .p50 = 0, .p99 = 0, .p999 = 0, .max = 0 },
    };
    try std.testing.expectEqual(@as(f64, 1000), sustained(&rows));
}

test "merge references offered at the window midpoint, and leaves shed unclamped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A perfectly-keeping-up proxy on a rising ramp: achieved equals the window
    // AVERAGE offered, so shed must read ~0. Referencing the end-of-window
    // target_rate instead would report a phantom positive shed here.
    const rows = [_]TsRow{
        .{ .t = 1, .target_rate = 1000, .achieved_rate = 1000, .requests = 1000 },
        .{ .t = 2, .target_rate = 2000, .achieved_rate = 1500, .requests = 1500 },
    };
    const w = try merge(arena, &.{&rows});
    try std.testing.expectEqual(@as(usize, 2), w.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0), w[1].shed, 1e-12);

    // And an over-serving window yields a NEGATIVE shed rather than being
    // clipped at zero — clamping raw windows biases the mean upward.
    const over = [_]TsRow{
        .{ .t = 1, .target_rate = 1000, .achieved_rate = 1000, .requests = 1000 },
        .{ .t = 2, .target_rate = 2000, .achieved_rate = 3000, .requests = 3000 },
    };
    const w2 = try merge(arena, &.{&over});
    try std.testing.expect(w2[1].shed < 0);
}

test "merge aligns loadgens by interval index and sums them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two loadgens whose grids have drifted apart in wall-clock but agree in
    // sequence. Bucketing by rounded time would fuse rows and double a point.
    const lg1 = [_]TsRow{
        .{ .t = 1.00, .target_rate = 500, .achieved_rate = 500, .requests = 500, .p99_us = 1000 },
        .{ .t = 2.00, .target_rate = 600, .achieved_rate = 600, .requests = 600, .p99_us = 1000 },
    };
    const lg2 = [_]TsRow{
        .{ .t = 1.40, .target_rate = 500, .achieved_rate = 500, .requests = 500, .p99_us = 4000 },
        .{ .t = 2.40, .target_rate = 600, .achieved_rate = 600, .requests = 600, .p99_us = 4000 },
    };
    const w = try merge(arena, &.{ &lg1, &lg2 });
    try std.testing.expectEqual(@as(usize, 2), w.len);
    try std.testing.expectEqual(@as(f64, 1000), w[0].offered); // summed
    try std.testing.expectEqual(@as(f64, 1000), w[0].achieved);
    // latency is the max across loadgens, not the sum or the mean
    try std.testing.expectApproxEqAbs(@as(f64, 0.004), w[0].p99, 1e-12);
}

test "interp clamps outside the range and is linear within it" {
    const pts = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 100 } };
    try std.testing.expectEqual(@as(f64, 0), interp(&pts, -5));
    try std.testing.expectEqual(@as(f64, 100), interp(&pts, 50));
    try std.testing.expectApproxEqAbs(@as(f64, 50), interp(&pts, 5), 1e-12);
    try std.testing.expectEqual(@as(f64, 0), interp(&.{}, 1));
}

test "smoothMedian kills a lone spike but keeps the trend" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pts: [9]Point = undefined;
    for (&pts, 0..) |*p, i| p.* = .{ .x = @floatFromInt(i), .y = 1.0 };
    pts[4].y = 99.0; // the warmup-window shed spike

    const sm = try smoothMedian(arena, &pts, 7);
    for (sm) |p| try std.testing.expectApproxEqAbs(@as(f64, 1.0), p.y, 1e-12);
}

test "refHist merges only the windows inside the reference band" {
    const gpa = std.testing.allocator;

    // Build three windows: one below the band, one inside, one above. Only the
    // in-band one may contribute, so the merged count must be exactly its own.
    var inside = try zrk.stats.newHistogram(gpa);
    defer inside.deinit();
    inside.record(1234);
    inside.record(5678);
    const inside_b64 = try inside.encodeBase64(gpa);
    defer gpa.free(inside_b64);

    var other = try zrk.stats.newHistogram(gpa);
    defer other.deinit();
    other.record(999);
    const other_b64 = try other.encodeBase64(gpa);
    defer gpa.free(other_b64);

    const rows = [_]TsRow{
        .{ .t = 5, .target_rate = 500, .latency_histogram = other_b64 }, // below
        .{ .t = 6, .target_rate = 2000, .latency_histogram = inside_b64 }, // inside
        .{ .t = 7, .target_rate = 9000, .latency_histogram = other_b64 }, // above
    };

    var h = (try refHist(gpa, &rows, 2000, 0.20)).?;
    defer h.deinit();
    try std.testing.expectEqual(@as(u64, 2), h.count());
}

test "wholeRunHist merges every window, unlike refHist's band+warmup filter" {
    const gpa = std.testing.allocator;

    var below = try zrk.stats.newHistogram(gpa);
    defer below.deinit();
    below.record(999);
    const below_b64 = try below.encodeBase64(gpa);
    defer gpa.free(below_b64);

    var inside = try zrk.stats.newHistogram(gpa);
    defer inside.deinit();
    inside.record(1234);
    inside.record(5678);
    const inside_b64 = try inside.encodeBase64(gpa);
    defer gpa.free(inside_b64);

    // Same three rows `refHist`'s band test uses, PLUS a t<3 warmup row —
    // wholeRunHist must include all four, where refHist(2000, 0.20) would
    // keep only the "inside" one.
    const rows = [_]TsRow{
        .{ .t = 1, .target_rate = 100, .latency_histogram = below_b64 }, // warmup
        .{ .t = 5, .target_rate = 500, .latency_histogram = below_b64 }, // below band
        .{ .t = 6, .target_rate = 2000, .latency_histogram = inside_b64 }, // inside band
        .{ .t = 7, .target_rate = 9000, .latency_histogram = below_b64 }, // above band
    };

    var h = (try wholeRunHist(gpa, &rows)).?;
    defer h.deinit();
    try std.testing.expectEqual(@as(u64, 5), h.count()); // 1+1+2+1

    var band = (try refHist(gpa, &rows, 2000, 0.20)).?;
    defer band.deinit();
    try std.testing.expectEqual(@as(u64, 2), band.count());
}

test "wholeRunHist returns null for an empty run" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try wholeRunHist(gpa, &.{})) == null);
}

test "refHist skips the warmup and returns null when the band is never reached" {
    const gpa = std.testing.allocator;

    var h0 = try zrk.stats.newHistogram(gpa);
    defer h0.deinit();
    h0.record(1000);
    const b64 = try h0.encodeBase64(gpa);
    defer gpa.free(b64);

    // In-band by rate, but at t<3 — the warmup exclusion must drop it.
    const warmup = [_]TsRow{.{ .t = 1, .target_rate = 2000, .latency_histogram = b64 }};
    try std.testing.expect((try refHist(gpa, &warmup, 2000, 0.20)) == null);

    // Never in band at all.
    const never = [_]TsRow{.{ .t = 9, .target_rate = 50000, .latency_histogram = b64 }};
    try std.testing.expect((try refHist(gpa, &never, 2000, 0.20)) == null);
}

test "isSaturated flags a histogram pegged at zrk's 60s ceiling" {
    const gpa = std.testing.allocator;
    var h = try zrk.stats.newHistogram(gpa);
    defer h.deinit();

    h.record(1000);
    try std.testing.expect(!isSaturated(&h));

    // What a real c10k run recorded before the deadline SLO was introduced.
    h.record(60_000_000);
    try std.testing.expect(isSaturated(&h));
}

//! Replacement for loadgen/zrk/run.py: drives one zrk ramp in-process by
//! calling zrk's own embeddable `runner.run` directly (see zrk's README
//! "Library usage") instead of spawning the zrk CLI as a subprocess and
//! tailing its NDJSON output. That subprocess boundary was the source of
//! every reliability problem we hit benchmarking at high connection counts:
//! a canceled/failed run could report a truncated result with nothing
//! marking it short, and a swallowed non-zero exit code (zrk-bench.sh's
//! `|| true`) meant we never even saw it. Calling `runner.run` in-process
//! gives us the real Zig error union directly — no text parsing, no exit
//! code to lose in a pipe.
//!
//! Same env-var contract as run.py, so scripts/zrk-bench.sh needs no changes
//! beyond which binary it ships to the loadgen:
//!   TARGET        full URL, e.g. http://10.0.0.5:8080/1k             (required)
//!   MAX_RATE      req/s at the end of the ramp                       (default 200000)
//!   RAMP_SECONDS  ramp length / run duration                         (default 120)
//!   START_RATE    req/s at t=0                                        (default 200)
//!   CONNECTIONS   open connections = in-flight cap (open-loop guard)  (default 2000)
//!   THREADS       zio executor count, matches the loadgen's core count (default 4)
//!   TIMEOUT_S     per-request WIRE timeout, s                         (default 1)
//!   OUT           output BASE path, no extension                     (default /w/ramp)
//!   NAME          proxy label (logs + `proxy` metric label)          (default ramp)
//!   RUNID         `testid` metric label                              (default adhoc)
//!   METRICS_ADDR  Prometheus /metrics listen addr                    (default :8090)

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const zio = @import("zio");
const zrk = @import("zrk");

const cli = zrk.cli;
const runner = zrk.runner;
const stats = zrk.stats;
const report = zrk.report;

fn envStr(environ: std.process.Environ, key: []const u8, default: []const u8) []const u8 {
    const v = std.process.Environ.getPosix(environ, key) orelse return default;
    return if (v.len == 0) default else v;
}

fn envInt(comptime T: type, environ: std.process.Environ, key: []const u8, default: T) T {
    const v = std.process.Environ.getPosix(environ, key) orelse return default;
    if (v.len == 0) return default;
    return std.fmt.parseInt(T, v, 10) catch default;
}

/// Live gauges the Prometheus bridge serves, mirroring run.py's `_cur` dict.
/// Mutex-guarded: the progress callback (executor 0, per runner.run's own
/// docs) and metrics connections (any executor) touch this concurrently.
const LiveGauges = struct {
    mutex: Io.Mutex = .init,
    offered: f64 = 0,
    achieved: f64 = 0,
    failed: f64 = 0,
    err_ratio: f64 = 0,
    p50_s: f64 = 0,
    p90_s: f64 = 0,
    p99_s: f64 = 0,
    p999_s: f64 = 0,
};

/// Offered *total* target rate at elapsed `t_s` (mirrors report.TimeSeries's
/// private targetRate, which isn't exported for reuse here).
fn targetRate(cfg: *const cli.Config, t_s: f64, total_s: f64) f64 {
    const start: f64 = @floatFromInt(cfg.rate);
    const end_rate = cfg.rate_end orelse return start;
    const end: f64 = @floatFromInt(end_rate);
    if (total_s <= 0) return end;
    const frac = std.math.clamp(t_s / total_s, 0, 1);
    return start + (end - start) * frac;
}

/// One point kept for the peak-sustained/knee summary (mirrors run.py's
/// `summarize`), filtered the same way: t >= 3 and offered > 0.
const Row = struct { t: f64, offered: f64, achieved: f64 };

const ProgressCtx = struct {
    io: Io,
    ts: *report.TimeSeries,
    gauges: *LiveGauges,
    cfg: *const cli.Config,
    rows: *std.ArrayList(Row),
    arena: std.mem.Allocator,
    prev_completed: u64 = 0,
    prev_status_errors: u64 = 0,
    prev_other_errors: u64 = 0,
    prev_elapsed_s: f64 = 0,
};

fn onProgress(
    context: ?*anyopaque,
    snapshot: *const stats.Snapshot,
    now_ns: i128,
    elapsed_s: f64,
    total_s: f64,
    tick: runner.Tick,
) void {
    _ = now_ns;
    if (!tick.row) return;
    const ctx: *ProgressCtx = @ptrCast(@alignCast(context.?));

    // The NDJSON row: reuse zrk's own delta/percentile math verbatim rather
    // than reimplementing it, so the file format is byte-for-byte what the
    // CLI would have written.
    ctx.ts.record(snapshot, elapsed_s) catch {};

    // zrk's `completed` is wrk-lineage throughput: EVERY parsed response counts,
    // 2xx/3xx or not (`status_errors` is an overlapping quality subset of it, not
    // a disjoint category — see connection.zig's `recordStatus`). Socket errors
    // and deadline misses never got a parsed response at all, so those ARE
    // disjoint from `completed`. Splitting into a stacked ok/failed thus needs:
    // ok = completed MINUS its status_errors subset; failed = status_errors plus
    // the genuinely-disjoint socket/deadline failures. Getting this wrong double-
    // counts non-2xx/3xx responses in both "achieved" and "failed" at once.
    const interval_s = elapsed_s - ctx.prev_elapsed_s;
    const d_completed = snapshot.counters.completed -| ctx.prev_completed;
    const d_status_errors = snapshot.counters.status_errors -| ctx.prev_status_errors;
    const other_errors_now = snapshot.counters.socketErrors() + snapshot.counters.deadline_errors;
    const d_other_errors = other_errors_now -| ctx.prev_other_errors;
    const d_ok = d_completed -| d_status_errors;
    const d_failed = d_status_errors + d_other_errors;
    const achieved: f64 = if (interval_s > 0) @as(f64, @floatFromInt(d_ok)) / interval_s else 0;
    const failed: f64 = if (interval_s > 0) @as(f64, @floatFromInt(d_failed)) / interval_s else 0;
    const attempts = d_ok + d_failed;
    const err_ratio: f64 = if (attempts > 0) @as(f64, @floatFromInt(d_failed)) / @as(f64, @floatFromInt(attempts)) else 0;
    const offered = targetRate(ctx.cfg, elapsed_s, total_s);

    {
        ctx.gauges.mutex.lockUncancelable(ctx.io);
        defer ctx.gauges.mutex.unlock(ctx.io);
        ctx.gauges.offered = offered;
        ctx.gauges.achieved = achieved;
        ctx.gauges.failed = failed;
        ctx.gauges.err_ratio = err_ratio;
        // Cumulative-so-far percentiles, not this interval's delta (which
        // would need our own parallel delta-histogram tracker to match
        // TimeSeries's internal one) — fine for a live dashboard; the NDJSON
        // file above is the source of record for analysis.
        ctx.gauges.p50_s = @as(f64, @floatFromInt(snapshot.hist.valueAtPercentile(50))) / 1e6;
        ctx.gauges.p90_s = @as(f64, @floatFromInt(snapshot.hist.valueAtPercentile(90))) / 1e6;
        ctx.gauges.p99_s = @as(f64, @floatFromInt(snapshot.hist.valueAtPercentile(99))) / 1e6;
        ctx.gauges.p999_s = @as(f64, @floatFromInt(snapshot.hist.valueAtPercentile(99.9))) / 1e6;
    }

    if (elapsed_s >= 3 and offered > 0) {
        ctx.rows.append(ctx.arena, .{ .t = elapsed_s, .offered = offered, .achieved = achieved }) catch {};
    }

    ctx.prev_completed = snapshot.counters.completed;
    ctx.prev_status_errors = snapshot.counters.status_errors;
    ctx.prev_other_errors = other_errors_now;
    ctx.prev_elapsed_s = elapsed_s;
}

/// peak SUSTAINED (achieved >= 90% offered) + knee (two windows behind),
/// matching run.py's summarize() exactly.
fn summarize(rows: []const Row) struct { sustained: f64, knee: f64 } {
    const keep = 0.90;
    var sustained: f64 = 0;
    var knee: f64 = 0;
    var knee_found = false;
    for (rows, 0..) |r, i| {
        if (r.achieved >= keep * r.offered) {
            sustained = @max(sustained, r.achieved);
        } else if (!knee_found) {
            const nxt = if (i + 1 < rows.len) rows[i + 1] else r;
            if (nxt.achieved < keep * nxt.offered) {
                knee = r.offered;
                knee_found = true;
            }
        }
    }
    return .{ .sustained = sustained, .knee = knee };
}

/// Consume request header lines through the terminating blank line (mirrors
/// zrk's own test fixture in runner.zig).
fn discardRequestHead(r: *Io.Reader) !void {
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        if (line.len <= 2) return; // "\r\n" or "\n": end of headers
    }
}

fn writeMetrics(io: Io, w: *Io.Writer, gauges: *LiveGauges, name: []const u8, runid: []const u8) !void {
    var g: LiveGauges = undefined;
    {
        gauges.mutex.lockUncancelable(io);
        defer gauges.mutex.unlock(io);
        g = gauges.*;
    }
    var body_buf: [1536]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf,
        \\# TYPE zrk_offered_rps gauge
        \\zrk_offered_rps{{proxy="{s}",testid="{s}"}} {d:.3}
        \\# TYPE zrk_achieved_rps gauge
        \\zrk_achieved_rps{{proxy="{s}",testid="{s}"}} {d:.3}
        \\# TYPE zrk_failed_rps gauge
        \\zrk_failed_rps{{proxy="{s}",testid="{s}"}} {d:.3}
        \\# TYPE zrk_errors_ratio gauge
        \\zrk_errors_ratio{{proxy="{s}",testid="{s}"}} {d:.6}
        \\# TYPE zrk_latency_seconds gauge
        \\zrk_latency_seconds{{proxy="{s}",testid="{s}",quantile="0.5"}} {d:.6}
        \\zrk_latency_seconds{{proxy="{s}",testid="{s}",quantile="0.9"}} {d:.6}
        \\zrk_latency_seconds{{proxy="{s}",testid="{s}",quantile="0.99"}} {d:.6}
        \\zrk_latency_seconds{{proxy="{s}",testid="{s}",quantile="0.999"}} {d:.6}
        \\
    , .{
        name, runid, g.offered,
        name, runid, g.achieved,
        name, runid, g.failed,
        name, runid, g.err_ratio,
        name, runid, g.p50_s,
        name, runid, g.p90_s,
        name, runid, g.p99_s,
        name, runid, g.p999_s,
    });
    try w.print("HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
}

fn handleMetricsConn(io: Io, stream_in: net.Stream, gauges: *LiveGauges, name: []const u8, runid: []const u8) void {
    var stream = stream_in;
    defer stream.close(io);
    var rbuf: [1024]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var w = stream.writer(io, &wbuf);
    discardRequestHead(&r.interface) catch return;
    writeMetrics(io, &w.interface, gauges, name, runid) catch return;
    w.interface.flush() catch return;
}

fn metricsServe(io: Io, addr: net.IpAddress, gauges: *LiveGauges, name: []const u8, runid: []const u8) void {
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("zrk-runner: metrics listen failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer server.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = server.accept(io) catch break;
        group.async(io, handleMetricsConn, .{ io, stream, gauges, name, runid });
    }
}

fn parseListenAddr(spec: []const u8) !net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return error.InvalidMetricsAddr;
    const host = spec[0..colon];
    const port = try std.fmt.parseInt(u16, spec[colon + 1 ..], 10);
    if (host.len == 0) return net.IpAddress.parse("0.0.0.0", port);
    return net.IpAddress.parse(host, port);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const environ = init.minimal.environ;

    const target = envStr(environ, "TARGET", "");
    if (target.len == 0) {
        std.debug.print("zrk-runner: TARGET is required\n", .{});
        std.process.exit(2);
    }
    const max_rate = envInt(u64, environ, "MAX_RATE", 200000);
    const ramp_seconds = envInt(u64, environ, "RAMP_SECONDS", 120);
    const start_rate = envInt(u64, environ, "START_RATE", 200);
    const connections = envInt(u32, environ, "CONNECTIONS", 2000);
    const threads = envInt(u8, environ, "THREADS", 4);
    const timeout_s = envInt(u64, environ, "TIMEOUT_S", 1);
    const out = envStr(environ, "OUT", "/w/ramp");
    const name = envStr(environ, "NAME", "ramp");
    const runid = envStr(environ, "RUNID", "adhoc");
    const metrics_addr_spec = envStr(environ, "METRICS_ADDR", ":8090");

    const nd_path = try std.fmt.allocPrint(arena, "{s}.ndjson", .{out});
    const json_path = try std.fmt.allocPrint(arena, "{s}.json", .{out});
    const hgrm_path = try std.fmt.allocPrint(arena, "{s}.hgrm", .{out});

    var rt = try zio.Runtime.init(arena, .{ .executors = .exact(threads) });
    defer rt.deinit();
    const io = rt.io();

    var cfg: cli.Config = .{
        .connections = connections,
        .threads = threads,
        .rate = start_rate,
        .rate_end = max_rate,
        .duration_ns = ramp_seconds * std.time.ns_per_s,
        .interval_ns = 1 * std.time.ns_per_s,
        .timeout_ns = timeout_s * std.time.ns_per_s,
        .record_timeouts = false, // --no-record-timeouts
        .format = .json,
        .output_path = json_path,
        .hdr_path = hgrm_path,
        .timeseries_path = nd_path,
        .timeseries_histogram = true,
        .url = cli.parseUrl(target) catch {
            std.debug.print("zrk-runner[{s}]: invalid TARGET url: {s}\n", .{ name, target });
            std.process.exit(2);
        },
    };

    std.debug.print(
        "zrk[{s}]: {s}  {d}..{d} rps over {d}s, conns={d}, threads={d}, metrics {s}\n",
        .{ name, target, start_rate, max_rate, ramp_seconds, connections, threads, metrics_addr_spec },
    );

    var gauges: LiveGauges = .{};
    const metrics_addr = parseListenAddr(metrics_addr_spec) catch |err| {
        std.debug.print("zrk-runner: bad METRICS_ADDR {s}: {s}\n", .{ metrics_addr_spec, @errorName(err) });
        std.process.exit(2);
    };
    var metrics_group: Io.Group = .init;
    metrics_group.async(io, metricsServe, .{ io, metrics_addr, &gauges, name, runid });
    defer metrics_group.cancel(io);

    const nd_file = try Io.Dir.cwd().createFile(io, nd_path, .{});
    defer nd_file.close(io);
    var nd_buf: [4096]u8 = undefined;
    var nd_fw: Io.File.Writer = .init(nd_file, io, &nd_buf);
    var ts = try report.TimeSeries.init(arena, &nd_fw.interface, &cfg);
    defer ts.deinit();

    var rows: std.ArrayList(Row) = .empty;
    var ctx: ProgressCtx = .{ .io = io, .ts = &ts, .gauges = &gauges, .cfg = &cfg, .rows = &rows, .arena = arena };

    const result = runner.run(arena, io, &cfg, 0, &ctx, onProgress, null) catch |err| {
        const msg: []const u8 = switch (err) {
            error.Canceled => "run was interrupted before --duration elapsed; no report written",
            error.NoConnectionsLaunched => "could not launch any connections",
            error.UnknownHostName => "could not resolve the target host",
            else => @errorName(err),
        };
        std.debug.print("zrk[{s}]: interrupted: {s}\n", .{ name, msg });
        std.process.exit(1);
    };

    try nd_fw.interface.flush();

    const jf = try Io.Dir.cwd().createFile(io, json_path, .{});
    defer jf.close(io);
    var jbuf: [8192]u8 = undefined;
    var jfw: Io.File.Writer = .init(jf, io, &jbuf);
    try report.writeJson(arena, &jfw.interface, &cfg, &result.snapshot, result.elapsed_s, result.launched, result.interrupted);
    try jfw.interface.flush();

    const hf = try Io.Dir.cwd().createFile(io, hgrm_path, .{});
    defer hf.close(io);
    var hbuf: [8192]u8 = undefined;
    var hfw: Io.File.Writer = .init(hf, io, &hbuf);
    try result.snapshot.hist.writePercentileDistribution(&hfw.interface, 1000.0, 5);
    try hfw.interface.flush();

    const summary = summarize(rows.items);
    std.debug.print(
        "zrk[{s}]: peak sustained={d:.0} ok/s; knee (achieved<90% offered) at offered={d:.0}\n",
        .{ name, summary.sustained, summary.knee },
    );
    std.debug.print(
        "zrk[{s}]: wrote {s}, {s}, {s} ({d} windows)\n",
        .{ name, nd_path, json_path, hgrm_path, rows.items.len },
    );
}

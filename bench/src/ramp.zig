//! One proxy's ramp: drives zrk in-process and samples the proxy's cAdvisor
//! alongside it.
//!
//! Descends from loadgen/zrk-runner/src/main.zig, with three substantive changes.
//!
//! **Configuration comes from a Profile, not the environment.** The old runner
//! read eleven values with silent `catch default` fallbacks, which is how a real
//! run executed with `TIMEOUT_S=0` against a documented 1 and nothing noticed.
//!
//! **The Prometheus half is gone** — the live gauge struct, the /metrics
//! listener and its accept loop, and the mutex traffic in the progress callback.
//! cAdvisor is sampled directly into this run's artifacts instead.
//!
//! **A run that ends early still reports.** The old code did
//! `runner.run(...) catch { print; exit(1) }`, discarding a measurement zrk was
//! willing to hand back. zrk's own docs on the `interrupt` parameter say raising
//! it "stops the run early and returns what was measured so far", and is
//! "preferred over canceling the task ... cancellation discards the measurement,
//! this keeps it". So the interrupt is wired up and a truncated run becomes a
//! `degraded` result with real data, not a total loss.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const zio = @import("zio");
const zrk = @import("zrk");

const cadvisor = @import("cadvisor.zig");
const redact = @import("redact.zig");
const profile = @import("profile.zig");

const cli = zrk.cli;
const runner = zrk.runner;
const stats = zrk.stats;
const zreport = zrk.report;

const Allocator = std.mem.Allocator;

pub const Options = struct {
    prof: profile.Profile,
    proxy: []const u8,
    /// Full URL, always an IP literal — zoxy does no DNS and a hostname here
    /// would also drag zrk's untimed resolver into the measurement path.
    target: []const u8,
    /// Where to sample container CPU/memory, or null for `direct` (no container).
    cadvisor_addr: ?net.IpAddress,
    /// Output base path; `.ndjson`, `.hgrm` and `.summary.json` are appended.
    out_base: []const u8,
    runid: []const u8,
};

pub const Outcome = struct {
    elapsed_s: f64,
    configured_s: f64,
    launched: u32,
    interrupted: bool,
    completed: u64,
    status_errors: u64,
    socket_errors: u64,
    deadline_errors: u64,
    max_behind_ns: u64,
    /// Latency at the ceiling of zrk's histogram means every tail percentile is
    /// the clamp value rather than a measurement.
    saturated: bool,
    /// cAdvisor reported a different proxy's container mid-ramp: whatever
    /// answered :8080 may not be the proxy under test, so this result is void.
    identity_error: bool,
    cadvisor_samples: usize,
};

const Row = struct { t: f64, offered: f64, achieved: f64 };

const ProgressCtx = struct {
    ts: *zreport.TimeSeries,
    rows: *std.ArrayList(Row),
    arena: Allocator,
    /// Flushed after every window, so a ramp that never returns still leaves its
    /// timeseries on disk.
    ///
    /// This used to be flushed once, after `runner.run` — which meant a wedged
    /// ramp kept whatever the buffer happened to have spilled and nothing else.
    /// Run #21 survived with 269 of 300 windows for pingora and 259 for haproxy
    /// purely by luck of buffer size; a stall nearer the start would have left an
    /// empty file. The .ndjson is the only artifact a wedged proxy produces at
    /// all (its .hgrm and cadvisor samples are written after the run), so it is
    /// the whole evidence base for diagnosing one.
    nd: *Io.File.Writer,
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
    _ = total_s;
    if (!tick.row) return;
    const ctx: *ProgressCtx = @ptrCast(@alignCast(context.?));

    // Reuse zrk's own delta/percentile math rather than reimplementing it, so
    // the NDJSON is byte-for-byte what the zrk CLI would have written and the
    // report's parser stays a single implementation.
    ctx.ts.record(snapshot, elapsed_s) catch {};
    ctx.nd.interface.flush() catch {};

    ctx.rows.append(ctx.arena, .{
        .t = elapsed_s,
        .offered = 0,
        .achieved = 0,
    }) catch {};
}

/// Raise `flag` after `ns`. The ramp's own backstop: if zrk somehow does not
/// return on its own — the class of hang that motivated the v1.3.1 bump, where a
/// run stopped producing rows while the process stayed alive and kept serving —
/// this converts an unbounded hang into a truncated but real result.
fn raiseAfter(io: Io, flag: *std.atomic.Value(bool), ns: u64) void {
    io.sleep(.fromNanoseconds(ns), .awake) catch {};
    flag.store(true, .monotonic);
}

/// One proxy's ramp.
///
/// Everything here is allocated from a RAMP-SCOPED arena, not the caller's.
///
/// The caller's arena is `init.arena` — it lives for the whole process and is
/// never reset, and this function builds a zio Runtime whose stack pool is one
/// coroutine per connection. At c10k that is 2.7 GiB, and `rt.deinit()` merely
/// hands it back to an arena that releases nothing, so every proxy's ramp added
/// another 2.7 GiB for the rest of the run. Measured: direct 2.73 GiB, then
/// haproxy 5.34 GiB, and on the fleet the third allocation OOM-killed an 8 GB
/// loadgen mid-ramp — which looked for days like a hang in zoxy or zio, because
/// a SIGKILLed process writes no marker and no watchdog output.
///
/// `Outcome` is scalars only, so nothing here outlives the call.
pub fn run(gpa: Allocator, caller_arena: Allocator, opts: Options) !Outcome {
    _ = caller_arena;
    var ramp_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer ramp_arena_state.deinit();
    const arena = ramp_arena_state.allocator();

    const p = opts.prof;
    try p.validate();

    // A ramp at 10k connections needs 10k+ descriptors. The old harness set this
    // with an inline `ulimit -n` in a non-`set -e` remote shell, which silently
    // no-ops when systemd's hard limit is lower and then dies with EMFILE
    // mid-ramp. Fail here, legibly, before any measurement.
    try assertFdLimit(p.connections);

    const nd_path = try std.fmt.allocPrint(arena, "{s}.ndjson", .{opts.out_base});
    const hgrm_path = try std.fmt.allocPrint(arena, "{s}.hgrm", .{opts.out_base});
    const cad_path = try std.fmt.allocPrint(arena, "{s}.cadvisor.ndjson", .{opts.out_base});

    var rt = try zio.Runtime.init(arena, .{ .executors = .exact(p.threads) });
    defer rt.deinit();
    const io = rt.io();

    var cfg: cli.Config = .{
        .connections = p.connections,
        .threads = p.threads,
        .rate = p.start_rate,
        .rate_end = p.max_rate,
        .duration_ns = p.durationNs(),
        .interval_ns = 1 * std.time.ns_per_s,
        .timeout_ns = p.timeoutNs(),
        // Coordinated-omission deadline. Shed-before-send only: `deadline_abort`
        // stays false, because aborting an in-flight request resets its
        // connection, and under saturation that storms the target with
        // reconnects — we measured three proxies blowing from tens of MiB to
        // 380-440 MiB and collapsing. zrk made shed-before-send the default for
        // exactly this reason.
        .deadline_ns = p.deadlineNs(),
        .deadline_abort = false,
        .record_timeouts = false,
        // zrk's own whole-run JSON is deliberately NOT written: it embeds the
        // target URL, i.e. the proxy's private address, in a file that would
        // then be published. The summary below carries the same numbers without
        // it. (See zrk/src/report.zig's writeUrl.)
        .format = .json,
        .output_path = null,
        .hdr_path = hgrm_path,
        .timeseries_path = nd_path,
        .timeseries_histogram = true,
        .url = cli.parseUrl(opts.target) catch return error.InvalidTarget,
    };

    const nd_file = try Io.Dir.cwd().createFile(io, nd_path, .{});
    defer nd_file.close(io);
    var nd_buf: [4096]u8 = undefined;
    var nd_fw: Io.File.Writer = .init(nd_file, io, &nd_buf);
    var ts = try zreport.TimeSeries.init(arena, &nd_fw.interface, &cfg);
    defer ts.deinit();

    var rows: std.ArrayList(Row) = .empty;
    var ctx: ProgressCtx = .{ .ts = &ts, .rows = &rows, .arena = arena, .nd = &nd_fw };

    // --- cAdvisor sampling, concurrent with the ramp.
    var samples: std.ArrayList(cadvisor.Sample) = .empty;
    defer samples.deinit(gpa);
    var poll_stop = std.atomic.Value(bool).init(false);
    var poller: cadvisor.Poller = undefined;
    var poll_group: Io.Group = .init;
    const t0 = Io.Timestamp.now(io, .awake);

    if (opts.cadvisor_addr) |addr| {
        poller = .{
            .io = io,
            .addr = addr,
            .proxy = opts.proxy,
            .t0 = t0,
            .out = &samples,
            .gpa = gpa,
            .stop = &poll_stop,
        };
        poll_group.async(io, cadvisor.Poller.run, .{&poller});
    }
    defer {
        poll_stop.store(true, .monotonic);
        // Unblock a scrape already in flight before waiting on the task, or this
        // cancel waits for a read that will never return. `stop` first, so the
        // poller exits rather than reconnecting.
        if (opts.cadvisor_addr != null) poller.interrupt();
        poll_group.cancel(io);
    }

    // --- the run itself, bounded.
    var interrupt = std.atomic.Value(bool).init(false);
    var watchdog: Io.Group = .init;
    watchdog.async(io, raiseAfter, .{ io, &interrupt, (p.ramp_seconds + 30) * std.time.ns_per_s });
    defer watchdog.cancel(io);

    const result = try runner.run(arena, io, &cfg, 0, &ctx, onProgress, &interrupt);

    try nd_fw.interface.flush();

    poll_stop.store(true, .monotonic);

    // --- artifacts
    {
        const hf = try Io.Dir.cwd().createFile(io, hgrm_path, .{});
        defer hf.close(io);
        var hbuf: [8192]u8 = undefined;
        var hfw: Io.File.Writer = .init(hf, io, &hbuf);
        try result.snapshot.hist.writePercentileDistribution(&hfw.interface, 1000.0, 5);
        try hfw.interface.flush();
    }
    if (opts.cadvisor_addr != null) {
        const cf = try Io.Dir.cwd().createFile(io, cad_path, .{});
        defer cf.close(io);
        var cbuf: [8192]u8 = undefined;
        var cfw: Io.File.Writer = .init(cf, io, &cbuf);
        for (samples.items) |s| {
            try cfw.interface.print(
                "{{\"t\":{d:.3},\"cpu_seconds_total\":{d:.6},\"mem_ws\":{d}}}\n",
                .{ s.t, s.cpu_seconds_total, s.mem_ws },
            );
        }
        try cfw.interface.flush();
    }

    if (opts.cadvisor_addr != null) {
        // The poller's own view. "0 samples" alone cannot distinguish "never
        // reached cAdvisor" from "reached it and never saw our container", and
        // those have different causes — one is the address, the other is
        // cAdvisor's container discovery.
        redact.log("bench: [{s}] cadvisor: {d} samples, {d} scrape failures, ever_found={}", .{
            opts.proxy,
            samples.items.len,
            poller.scrape_failures,
            poller.ever_found,
        });
    }

    const c = result.snapshot.counters;
    return .{
        .elapsed_s = result.elapsed_s,
        .configured_s = @floatFromInt(p.ramp_seconds),
        .launched = result.launched,
        .interrupted = result.interrupted,
        .completed = c.completed,
        .status_errors = c.status_errors,
        .socket_errors = c.socketErrors(),
        .deadline_errors = c.deadline_errors,
        .max_behind_ns = c.max_behind_ns,
        .saturated = result.snapshot.hist.max() >= 59_000_000,
        .identity_error = opts.cadvisor_addr != null and poller.identity_error.load(.monotonic),
        .cadvisor_samples = samples.items.len,
    };
}

/// zrk keeps one in-flight request per connection, plus the loadgen's own
/// bookkeeping descriptors.
fn assertFdLimit(connections: u32) !void {
    const lim = std.posix.getrlimit(.NOFILE) catch return;
    const need: u64 = @as(u64, connections) + 1024;
    if (lim.cur < need) {
        std.debug.print(
            "bench: RLIMIT_NOFILE is {d} but this profile needs >= {d} " ++
                "({d} connections + headroom); see /etc/security/limits.d/99-bench.conf\n",
            .{ lim.cur, need, connections },
        );
        return error.FdLimitTooLow;
    }
}

/// How complete a ramp has to be before its numbers are worth reporting at all.
/// Below this the throughput curve covers too little of the offered range to
/// place a knee, so the result is `failed` rather than `degraded`.
pub const min_coverage: f64 = 0.5;

pub fn coverage(o: Outcome) f64 {
    if (o.configured_s <= 0) return 0;
    return o.elapsed_s / o.configured_s;
}

test "coverage classifies a truncated run" {
    const full: Outcome = .{
        .elapsed_s = 300, .configured_s = 300, .launched = 1000, .interrupted = false,
        .completed = 0, .status_errors = 0, .socket_errors = 0, .deadline_errors = 0,
        .max_behind_ns = 0, .saturated = false, .identity_error = false, .cadvisor_samples = 0,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), coverage(full), 1e-9);

    var half = full;
    half.elapsed_s = 150;
    half.interrupted = true;
    // Exactly at the threshold still counts as usable.
    try std.testing.expect(coverage(half) >= min_coverage);

    var stub = full;
    stub.elapsed_s = 20;
    try std.testing.expect(coverage(stub) < min_coverage);
}


// --- child/parent Outcome hand-off -----------------------------------------
//
// `ramp.run` is invoked as a CHILD (`bench ramp`) so a wedged generator can be
// killed on a deadline. Once `runner.run` blocks, zio owns the calling thread, so
// no in-process bound is possible — the only way to abandon it and keep measuring
// the remaining proxies is for it to be a separate process. Runs #21 and #22 each
// lost two proxies entirely because the only available bound was killing the
// whole suite.
//
// `Outcome` is scalars, so the hand-off is lossless. Rendering and parsing are
// split from the file I/O so the round-trip is testable without a filesystem.

pub fn renderOutcome(w: *std.Io.Writer, o: Outcome) !void {
    try w.print(
        "{{\"elapsed_s\":{d},\"configured_s\":{d},\"launched\":{d}," ++
            "\"interrupted\":{},\"completed\":{d},\"status_errors\":{d}," ++
            "\"socket_errors\":{d},\"deadline_errors\":{d},\"max_behind_ns\":{d}," ++
            "\"saturated\":{},\"identity_error\":{},\"cadvisor_samples\":{d}}}",
        .{
            o.elapsed_s,      o.configured_s,   o.launched,
            o.interrupted,    o.completed,      o.status_errors,
            o.socket_errors,  o.deadline_errors, o.max_behind_ns,
            o.saturated,      o.identity_error, o.cadvisor_samples,
        },
    );
}

pub fn parseOutcome(arena: Allocator, text: []const u8) !Outcome {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const o = v.object;
    return .{
        .elapsed_s = jnum(o, "elapsed_s"),
        .configured_s = jnum(o, "configured_s"),
        .launched = @intFromFloat(jnum(o, "launched")),
        .interrupted = jbool(o, "interrupted"),
        .completed = @intFromFloat(jnum(o, "completed")),
        .status_errors = @intFromFloat(jnum(o, "status_errors")),
        .socket_errors = @intFromFloat(jnum(o, "socket_errors")),
        .deadline_errors = @intFromFloat(jnum(o, "deadline_errors")),
        .max_behind_ns = @intFromFloat(jnum(o, "max_behind_ns")),
        .saturated = jbool(o, "saturated"),
        .identity_error = jbool(o, "identity_error"),
        .cadvisor_samples = @intFromFloat(jnum(o, "cadvisor_samples")),
    };
}

fn jnum(o: std.json.ObjectMap, key: []const u8) f64 {
    const v = o.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

fn jbool(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

pub fn writeOutcome(io: Io, path: []const u8, o: Outcome) !void {
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [1024]u8 = undefined;
    var fw: Io.File.Writer = .init(f, io, &buf);
    try renderOutcome(&fw.interface, o);
    try fw.interface.flush();
}

pub fn readOutcome(arena: Allocator, io: Io, path: []const u8) !Outcome {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 10));
    return parseOutcome(arena, text);
}

test "an Outcome survives the child/parent round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every field, with the shape a real c10k run produces. A silently zeroed
    // field here would read downstream as a proxy that served nothing.
    const want: Outcome = .{
        .elapsed_s = 300.408,
        .configured_s = 300.0,
        .launched = 10000,
        .interrupted = true,
        .completed = 5544684,
        .status_errors = 7,
        .socket_errors = 80339,
        .deadline_errors = 9299907,
        .max_behind_ns = 111892499000,
        .saturated = true,
        .identity_error = false,
        .cadvisor_samples = 287,
    };

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderOutcome(&w, want);
    const got = try parseOutcome(arena, w.buffered());

    try std.testing.expectApproxEqAbs(want.elapsed_s, got.elapsed_s, 1e-6);
    try std.testing.expectApproxEqAbs(want.configured_s, got.configured_s, 1e-6);
    try std.testing.expectEqual(want.launched, got.launched);
    try std.testing.expectEqual(want.interrupted, got.interrupted);
    try std.testing.expectEqual(want.completed, got.completed);
    try std.testing.expectEqual(want.status_errors, got.status_errors);
    try std.testing.expectEqual(want.socket_errors, got.socket_errors);
    try std.testing.expectEqual(want.deadline_errors, got.deadline_errors);
    try std.testing.expectEqual(want.max_behind_ns, got.max_behind_ns);
    try std.testing.expectEqual(want.saturated, got.saturated);
    try std.testing.expectEqual(want.identity_error, got.identity_error);
    try std.testing.expectEqual(want.cadvisor_samples, got.cadvisor_samples);
}

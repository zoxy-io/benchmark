//! Ramp profiles, compiled in.
//!
//! The old loadgen/zrk-runner read eleven parameters from the environment, each
//! with a silent `catch default` fallback (its main.zig:45). That is how a real
//! run ended up with `TIMEOUT_S=0` while .env.example documented 1, and nothing
//! anywhere noticed. Ramp parameters are the fairness contract of this
//! benchmark — "never compare runs with different MAX_RATE, RAMP_SECONDS or
//! CONNECTIONS" — so they are constants here, and `validate()` runs before any
//! measurement. An unknown profile name is a hard error, not a default.

const std = @import("std");

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const Profile = struct {
    name: []const u8,

    /// Open connections = in-flight concurrency cap (the open-loop guard; zrk
    /// keeps one request in flight per connection).
    connections: u32,
    /// OS threads driving zrk's zio coroutine engine. Match the loadgen VM's
    /// core count (cloud/variables.tf loadgen_cores), NOT `connections`.
    threads: u8,

    start_rate: u64,
    max_rate: u64,
    ramp_seconds: u64,

    /// Per-request WIRE timeout (bytes-out -> bytes-in). A hung-connection
    /// guard, NOT a bound on coordinated-omission latency: past saturation a
    /// request waits for a free connection but completes fast once it has one,
    /// so it never trips this while its scheduled->response latency balloons.
    timeout_s: u64,

    /// Coordinated-omission deadline (0 = off). A request already staler than
    /// this is SHED BEFORE SENDING — never touches the wire, counted as
    /// `deadline_errors`, never recorded in the histogram — so overload surfaces
    /// as a bounded, directly comparable error rate instead of an unbounded tail.
    ///
    /// This is what keeps c10k's histogram off zrk's 60s ceiling
    /// (zrk/src/stats.zig:35), where every tail percentile degenerates to
    /// ">=60s". It also makes the proxies comparable at all: without it each
    /// proxy's own timeout config decides the outcome (haproxy bounds an
    /// exchange at 60s and returns 504s, zoxy has no request_ms configured,
    /// pingora has no request timeout whatsoever).
    ///
    /// NEVER pair this with zrk's `deadline_abort`. That aborts requests already
    /// on the wire by resetting the connection, which under saturation storms
    /// the target with reconnects — we measured pingora/envoy/traefik blowing
    /// from tens of MiB to 380-440 MiB and collapsing (2026-07-20). zrk made
    /// shed-before-send the default precisely because of that report.
    deadline_ms: u64,

    req_path: []const u8,

    /// SUMMARY-latency reference offered rate: a shared, light, sub-knee load
    /// where a single per-proxy latency number is actually fair, because it
    /// reflects per-request COST rather than standing-queue wait.
    ///
    /// Per-profile because the connect storm moves. On a 200->50000/300s ramp,
    /// offered 2000 rps is t~=[8.4, 13.2]s — and at 10000 connections zrk is
    /// still ESTABLISHING connections then (zrk/src/runner.zig:153-156 launches
    /// them all at once), so a 2000 rps reading at c10k measures connection
    /// setup, not proxying.
    ref_rate: f64,
    /// Merge windows with offered within +/-ref_band of ref_rate.
    ref_band: f64,

    cooldown_s: u64,

    /// Per-profile proxy tuning, applied as environment to `docker compose`.
    proxy_env: []const Pair,

    pub fn validate(self: Profile) !void {
        if (self.start_rate >= self.max_rate) return error.InvalidRampBounds;
        if (self.ramp_seconds == 0) return error.InvalidRampSeconds;
        if (self.connections == 0) return error.InvalidConnections;
        if (self.threads == 0) return error.InvalidThreads;
        // A zero wire timeout is ALLOWED, but only as a compiled-in constant.
        //
        // The original rule rejected it outright, and the reason was sound: the
        // env-var plumbing this replaced silently produced `TIMEOUT_S=0` from a
        // `catch default`, and nothing noticed. That argument is about a value
        // arriving unnoticed from ambient state — it does not apply to a
        // constant in this file, which cannot change without a reviewed commit
        // explaining itself, as c10k's does.
        //
        // Rejecting it here would instead mean the harness cannot express the
        // only configuration known to complete a 10k ramp, which is a worse
        // failure than the one the rule was guarding against.

        // The reference rate must be reachable on this ramp and land after the
        // t>=3 warmup exclusion, or every proxy reports a null latency.
        const span: f64 = @floatFromInt(self.max_rate - self.start_rate);
        const t_at_ref = (self.ref_rate - @as(f64, @floatFromInt(self.start_rate))) /
            (span / @as(f64, @floatFromInt(self.ramp_seconds)));
        if (t_at_ref < 3) return error.RefRateInsideWarmup;
        if (self.ref_rate >= @as(f64, @floatFromInt(self.max_rate))) return error.RefRateAboveRamp;
        if (self.ref_band <= 0 or self.ref_band >= 1) return error.InvalidRefBand;
    }

    pub fn timeoutNs(self: Profile) u64 {
        return self.timeout_s * std.time.ns_per_s;
    }
    pub fn deadlineNs(self: Profile) u64 {
        return self.deadline_ms * std.time.ns_per_ms;
    }
    pub fn durationNs(self: Profile) u64 {
        return self.ramp_seconds * std.time.ns_per_s;
    }
};

/// Shared ramp shape. Identical across profiles by design — the offered axis
/// every chart shares depends on it, so only `connections` (and what that
/// forces) differs between c1k and c10k.
///
/// At 100k req/s of 1 KiB bodies the offered load is ~820 Mbps, which is at or
/// past what a 2-vCPU standard-v3 NIC sustains. That is deliberate: the ramp has
/// to extend past every proxy's knee for the knee to be visible at all. But it
/// does mean the `direct` baseline is expected to top out on the NETWORK rather
/// than on the origin, so `direct` marks where the measurement rig itself
/// saturates, not where nginx does — read a proxy against it, never as a
/// fraction of line rate.
/// The zoxy ref every profile builds. `main` ON PURPOSE: the nightly exists to
/// catch a regression the morning after it lands, so each night must build
/// whatever main is at the time. Points on the trend chart are deliberately
/// different commits, and `zoxy_commit` in profile.json records which one
/// produced each — that is what makes a regression bisectable.
///
/// Passed explicitly rather than left to compose's `${ZOXY_REF:-main}` default,
/// so a floating build is a stated intent rather than something that happens
/// because nobody set the variable.
///
/// A floating ref only means anything if the clone is actually fresh — see the
/// cache-bust in proxies/zoxy/Dockerfile, without which "main" silently means
/// "whatever main was when the layer was first built".
pub const zoxy_ref = "main";

const start_rate: u64 = 200;
const max_rate: u64 = 100_000;
const ramp_seconds: u64 = 300;

pub const c1k: Profile = .{
    .name = "c1k",
    .connections = 1000,
    .threads = 4,
    .start_rate = start_rate,
    .max_rate = max_rate,
    .ramp_seconds = ramp_seconds,
    .timeout_s = 1,
    .deadline_ms = 0,
    .req_path = "/1k",
    .ref_rate = 2000,
    .ref_band = 0.20,
    .cooldown_s = 8,
    .proxy_env = &.{
        // zoxy leases an upstream slot per admitted connection at saturation, so
        // the stock 1024 upstream slots against 1000 offered connections leaves
        // 2.4% headroom — close enough that zoxy could shed for a reason that
        // has nothing to do with its proxying. Pin upstream to the conn_slots
        // default so the two agree. (zoxy is fixing this default upstream.)
        .{ .key = "ZOXY_CONN_SLOTS", .value = "1386" },
        .{ .key = "ZOXY_UPSTREAM_SLOTS", .value = "1386" },
    },
};

pub const c10k: Profile = .{
    .name = "c10k",
    .connections = 10_000,
    .threads = 4,
    .start_rate = start_rate,
    .max_rate = max_rate,
    .ramp_seconds = ramp_seconds,
    // Restored: turning this off is what wedged haproxy's c10k ramp in run #14.
    //
    // With `timeout_s = 0` zrk never arms `watchTimer` (connection.zig gates it
    // on `timeout_ns != 0`), so nothing breaks a read that never completes. The
    // task blocks forever, zrk's end-of-run `group.cancel` waits on it, and the
    // ramp never returns — the proxy watchdog aborted it at 900s with
    // "stuck at stage ramp". direct and zoxy finished the same run cleanly
    // because their reads completed; haproxy at 10k connections left reads
    // outstanding past the end of the run.
    //
    // This is the hung-connection guard the field docs describe, and it is why
    // ten of the twelve old working 10k runs carried `timeout_ms: 1000`. It was
    // only ever zeroed to match the last known-good config while the c10k
    // failure was unexplained; that cause turned out to be a memory leak.
    .timeout_s = 1,

    // One SLO, enforced by the load generator, identical for every proxy.
    //
    // Restored after the c10k failure turned out to be a memory leak in
    // `ramp.run` (a zio runtime per proxy from a process-lifetime arena, which
    // OOM-killed the loadgen). The deadline was suspected and reverted; it was
    // never implicated.
    //
    // Without it every tail percentile at c10k degenerates to zrk's 60s clamp —
    // measured on the old fleet, p90/p99/p99.9/p99.99/max ALL 60.0s, five
    // identical constants carrying no information, so proxies cannot be ranked
    // by tail at all. It is also the only thing that makes them answer the same
    // question: with no loadgen bound each proxy's own config decides the
    // outcome (haproxy `timeout client/server 60s` returns 504s, pingora has no
    // request timeout whatsoever).
    //
    // It sheds hard past the knee — ~90% of scheduled requests at the top of a
    // ramp that deliberately runs to 100k. That does not corrupt the headline
    // latency, which is read at `ref_rate` (8000 rps, comfortably under the
    // ~16.7k zoxy sustained here), where shedding is negligible. Past the knee
    // it converts an unbounded tail into a bounded, comparable error rate.
    .deadline_ms = 1000,
    .req_path = "/1k",
    // Past the connect storm: ~8000 rps is t~=47s on this ramp, by which point
    // all 10k connections are long established.
    .ref_rate = 8000,
    .ref_band = 0.15,
    .cooldown_s = 8,
    .proxy_env = &.{
        // The comptime ceiling for both, pinned equal as of zoxy #108. Without
        // this zoxy sheds ~1/3 of responses by admission policy at 10k
        // connections and the number measures the cap, not the proxy.
        .{ .key = "ZOXY_CONN_SLOTS", .value = "11464" },
        .{ .key = "ZOXY_UPSTREAM_SLOTS", .value = "11464" },
    },
};

pub const all = [_]Profile{ c1k, c10k };

pub fn byName(name: []const u8) ?Profile {
    for (all) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

test "every shipped profile validates" {
    for (all) |p| try p.validate();
}

test "byName is exhaustive and rejects unknown names" {
    try std.testing.expect(byName("c1k") != null);
    try std.testing.expect(byName("c10k") != null);
    try std.testing.expect(byName("") == null);
    try std.testing.expect(byName("c100k") == null);
}

test "validate rejects the misconfigurations the env plumbing used to allow" {
    var p = c1k;

    // A zero wire timeout is no longer rejected: it is the only configuration
    // known to complete a 10k ramp, and as a compiled-in constant it cannot
    // arrive unnoticed the way the old TIMEOUT_S=0 did.
    p.timeout_s = 0;
    try p.validate();

    p = c1k;
    p.max_rate = p.start_rate;
    try std.testing.expectError(error.InvalidRampBounds, p.validate());

    // A reference rate down in the warmup would silently null out every
    // proxy's summary latency, since refHist excludes t<3.
    p = c1k;
    p.ref_rate = 250;
    try std.testing.expectError(error.RefRateInsideWarmup, p.validate());

    p = c1k;
    p.ref_rate = @floatFromInt(p.max_rate);
    try std.testing.expectError(error.RefRateAboveRamp, p.validate());
}

test "c10k carries the deadline SLO and c1k does not" {
    // Without it, c10k produced p90=p99=p99_9=p99_99=max=60s — five identical
    // clamp values, a saturated histogram rather than a measurement. It also
    // makes the proxies answer one question instead of each applying its own
    // timeout policy.
    try std.testing.expect(c10k.deadline_ms > 0);
    try std.testing.expectEqual(@as(u64, 0), c1k.deadline_ms);
}

test "profiles share one ramp shape so the offered axis is comparable" {
    for (all) |p| {
        try std.testing.expectEqual(start_rate, p.start_rate);
        try std.testing.expectEqual(max_rate, p.max_rate);
        try std.testing.expectEqual(ramp_seconds, p.ramp_seconds);
    }
}

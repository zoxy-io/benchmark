//! Ramp profiles, compiled in.
//!
//! Ramp parameters are the fairness contract, so they are constants, not env
//! (the old runner's silent `catch default` produced `TIMEOUT_S=0`).
//! `validate()` runs before any measurement; an unknown name is a hard error.

const std = @import("std");

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const Profile = struct {
    name: []const u8,

    /// In-flight concurrency cap (zrk keeps one request per connection).
    connections: u32,
    /// zio threads. Match loadgen cores (cloud/variables.tf), NOT connections.
    threads: u8,

    start_rate: u64,
    max_rate: u64,
    ramp_seconds: u64,

    /// Per-request wire timeout: a hung-connection guard, NOT a bound on
    /// coordinated-omission latency (queued requests never trip it).
    timeout_s: u64,

    /// Coordinated-omission deadline (0 = off). Staler requests are shed
    /// before sending and counted as `deadline_errors`, so overload is a
    /// bounded error rate instead of a tail pinned at zrk's 60s clamp.
    /// NEVER pair with zrk's `deadline_abort`: resetting in-flight connections
    /// storms the target with reconnects and collapses proxies.
    deadline_ms: u64,

    req_path: []const u8,

    /// Offer the load over TLS (1.3 only, ALPN http/1.1, no resumption).
    ///
    /// Inbound only: zoxy's upstream leg is plaintext, so every proxy's is.
    /// Proxies always carry both listeners (see compose.yaml PROXY_TLS_PORT);
    /// this picks the ramp's target, keeping healthchecks on plaintext.
    /// Handshakes all land at connect time, so `ref_rate` reads record-layer
    /// crypto, not handshake throughput.
    tls: bool = false,

    /// Speak HTTP/2 to the proxy: ALPN `h2` on the TLS listener, so `tls` must
    /// be set (validate). One stream per connection, so in-flight requests
    /// still equal `connections`. Inbound only, like TLS: every proxy's
    /// upstream leg stays HTTP/1.1. The suite passes PROXY_H2=on to the
    /// proxies, and the warm probe fails a listener that won't negotiate h2.
    h2: bool = false,

    /// Speak HTTP/3 to the proxy: QUIC on UDP, at the TLS listener's port
    /// number, so `tls` must be set and `h2` must not (validate). One request
    /// per connection, as on h2. Inbound only: every proxy's upstream leg
    /// stays HTTP/1.1. The suite passes PROXY_H3=on to the proxies, leaves out
    /// a proxy that has no HTTP/3 (`serves`), and the warm probe fails a
    /// listener that won't complete an HTTP/3 request. The TCP TLS listener
    /// stays up beside it, offering http/1.1, for the warm probe.
    h3: bool = false,

    /// Summary-latency reference rate: a light, sub-knee load where latency
    /// reflects per-request cost rather than queueing. Per-profile because it
    /// must land after the connect storm (zrk/src/runner.zig:153-156).
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
        // h2 is negotiated in the TLS handshake; nothing here speaks h2c.
        if (self.h2 and !self.tls) return error.H2WithoutTls;
        // QUIC has no cleartext mode, and one connection speaks one protocol.
        // zrk's CLI refuses both; the bench fills zrk's config directly, so
        // its CLI checks never run and these stand in for them.
        if (self.h3 and !self.tls) return error.H3WithoutTls;
        if (self.h3 and self.h2) return error.H3WithH2;
        // A zero wire timeout is allowed: as a compiled-in constant it cannot
        // arrive unnoticed the way the old env var's did.

        // The reference rate must be reachable on this ramp and land after the
        // t>=3 warmup exclusion, or every proxy reports a null latency.
        const span: f64 = @floatFromInt(self.max_rate - self.start_rate);
        const t_at_ref = (self.ref_rate - @as(f64, @floatFromInt(self.start_rate))) /
            (span / @as(f64, @floatFromInt(self.ramp_seconds)));
        if (t_at_ref < 3) return error.RefRateInsideWarmup;
        if (self.ref_rate >= @as(f64, @floatFromInt(self.max_rate))) return error.RefRateAboveRamp;
        if (self.ref_band <= 0 or self.ref_band >= 1) return error.InvalidRefBand;
    }

    /// Whether `proxy` can be measured on this profile. pingora (0.9) has no
    /// HTTP/3, so an h3 profile leaves it out rather than recording a turn
    /// that could only fail.
    pub fn serves(self: Profile, proxy: []const u8) bool {
        if (self.h3 and std.mem.eql(u8, proxy, "pingora")) return false;
        return true;
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

/// Which zoxy every profile measures. `release` = latest published release,
/// resolved to a tag by `suite.resolveZoxySource` and installed from the
/// upstream tarball (proxies/zoxy/Dockerfile): it measures what users run and
/// skips the flaky source build (run 30749146321). Cost: regressions bisect
/// only to a release. Set a branch/tag/sha to build from source.
pub const zoxy_ref = "release";

// Shared ramp shape: the offered axis every chart shares. 40k: the fastest
// 10 KiB knee on record is zoxy's 27.2k (median 21.6k, runs 20260918-20261007),
// and `sustained` reads the ceiling, not a knee, for a proxy that never falls
// behind, so 1.5x that best night is the margin. ~133 rps/s is 2.5x finer
// near each knee than the 100k ramp it replaced (2026-11-15). 40k of 10 KiB
// is ~3.3 Gbps, where the old 100 KiB band put every proxy; compare proxies to
// each other, not to line rate (`direct` in git history finds it).
const start_rate: u64 = 200;
const max_rate: u64 = 40_000;
const ramp_seconds: u64 = 300;

/// The nightly baseline, and the one body size every profile shares.
///
/// 10 KiB estimates the mean response behind an app-tier reverse proxy (API
/// plus HTML, static assets on a CDN); the median is nearer 1 KiB, but the mean
/// is what sets capacity under a real mix. It is also where per-request and
/// per-byte cost both show: the 64B-100k bands (runs 20260918-20261007) put
/// each proxy's break-even between 5 KiB (zoxy) and 43 KiB (envoy), and at
/// 100 KiB every proxy converged on the network path. It fits zoxy's 16 KiB
/// relay buffer and one default HTTP/2 DATA frame, so no knob or window
/// default decides the result.
///
/// Was 1 KiB until 2026-11-15: c1k's trend steps there, and the old c1k-10k
/// series is the one that continues.
pub const c1k: Profile = .{
    .name = "c1k",
    .connections = 1000,
    .threads = 4,
    .start_rate = start_rate,
    .max_rate = max_rate,
    .ramp_seconds = ramp_seconds,
    .timeout_s = 1,
    .deadline_ms = 0,
    .req_path = "/10k",
    .ref_rate = 2000,
    .ref_band = 0.20,
    .cooldown_s = 8,
    .proxy_env = &.{
        // Stock slots leave only 2.4% headroom over 1000 connections; pin to
        // the conn_slots default so zoxy never sheds on the cap.
        .{ .key = "ZOXY_CONN_SLOTS", .value = "1386" },
        // 4 x conn_slots: upstreams park per endpoint and round-robin rotates
        // through the four-node origin. Nonzero `zoxy_shed_upstream_slots` in
        // the artifacts means this is still too small (ceiling 11457).
        .{ .key = "ZOXY_UPSTREAM_SLOTS", .value = "5544" },
    },
};

/// c1k with TLS on the client leg and nothing else changed, so the pair
/// isolates the cost of TLS. Diverge only visibly, below. `ref_rate` stays
/// 2000 so "TLS costs X" is a subtraction (~21 MB/s AEAD, well sub-knee).
pub const c1k_tls: Profile = blk: {
    var p = c1k;
    p.name = "c1k-tls";
    p.tls = true;
    // ZOXY_TLS_ENGINES = 1024 is both zoxy's default and its ceiling
    // (`LimitTlsEnginesOutOfRange` above it, through 0.8.0); pinned so the run
    // record states it. One engine per TLS connection, 2.4% headroom over 1000:
    // holds because zrk never churns connections. Nonzero
    // `zoxy_shed_tls_engines` means the ramp measured the cap, not TLS.
    // Engines cost ~270 MiB vs ~104 MiB plaintext, hence no TLS listener on
    // plaintext profiles (compose.yaml).
    p.proxy_env = &.{
        .{ .key = "ZOXY_CONN_SLOTS", .value = "1386" },
        .{ .key = "ZOXY_UPSTREAM_SLOTS", .value = "5544" },
        .{ .key = "ZOXY_TLS_ENGINES", .value = "1024" },
    };
    break :blk p;
};

/// c1k-tls with HTTP/2 in place of HTTP/1.1 and nothing else changed, so the
/// pair isolates the protocol. One stream per connection keeps 1000 requests
/// in flight, as on c1k-tls: this measures HTTP/2 framing, HPACK and stream
/// bookkeeping, not multiplexing. Every proxy advertises `h2, http/1.1`; zrk
/// offers the same and counts a connection that lands on HTTP/1.1 as a
/// connect error, and the warm probe refuses such a listener outright.
pub const c1k_h2: Profile = blk: {
    var p = c1k_tls;
    p.name = "c1k-h2";
    p.h2 = true;
    // zoxy's HTTP/2 pools, legal only when a listener speaks h2 (zoxy
    // refuses them otherwise, so only an h2 profile may set them).
    // h2_connections: its 1024 default, pinned like tls_engines. With none
    // free zoxy answers an h2 offer with HTTP/1.1, so it must cover the 1000
    // connections; nonzero `zoxy_h2_shed_sessions` means it did not.
    // h2_streams: required with h2, no default. One stream per connection
    // needs 1000; conn_slots' 1386 keeps the same headroom. Nonzero
    // `zoxy_h2_shed_streams` means the ramp measured this cap.
    p.proxy_env = c1k_tls.proxy_env ++ [_]Pair{
        .{ .key = "ZOXY_H2_CONNECTIONS", .value = "1024" },
        .{ .key = "ZOXY_H2_STREAMS", .value = "1386" },
    };
    break :blk p;
};

/// c1k-tls with HTTP/3 in place of HTTP/1.1 and nothing else changed, so the
/// pair isolates the protocol, as c1k-h2 does for HTTP/2. One request per
/// connection keeps 1000 in flight: this measures QUIC packet protection,
/// loss recovery and QPACK, not multiplexing. Four proxies: pingora has no
/// HTTP/3 (`serves`).
pub const c1k_h3: Profile = blk: {
    var p = c1k_tls;
    p.name = "c1k-h3";
    p.h3 = true;
    // zoxy's QUIC pool. quic_connections defaults to 64, and a connection
    // past it gets no answer, so it must cover the 1000; at most tls_engines,
    // since each QUIC connection holds an engine for its life, so it is
    // tls_engines' 1024. Each costs ~835 KiB, which the published memory
    // shows. h2_streams: zoxy requires it with a QUIC binding (h3 requests
    // share HTTP/2's stream pool); 1386 as on c1k-h2. h2_connections stays
    // unset: the TCP listener offers http/1.1 alone, and zoxy refuses it
    // there. Nonzero `zoxy_h3_shed_*` means the ramp measured a cap.
    p.proxy_env = c1k_tls.proxy_env ++ [_]Pair{
        .{ .key = "ZOXY_QUIC_CONNECTIONS", .value = "1024" },
        .{ .key = "ZOXY_H2_STREAMS", .value = "1386" },
    };
    break :blk p;
};

pub const c100: Profile = .{
    .name = "c100",
    .connections = 100,
    .threads = 4,
    .start_rate = start_rate,
    .max_rate = max_rate,
    .ramp_seconds = ramp_seconds,
    .timeout_s = 1,
    .deadline_ms = 0,
    .req_path = "/10k",
    // c1k's ref_rate, for direct comparison; connections cap concurrency, not
    // throughput.
    .ref_rate = 2000,
    .ref_band = 0.20,
    .cooldown_s = 8,
    // No override: exercises zoxy's shipped defaults (100 conns ~10% of slots).
    .proxy_env = &.{},
};

pub const c10k: Profile = .{
    .name = "c10k",
    .connections = 10_000,
    .threads = 4,
    .start_rate = start_rate,
    .max_rate = max_rate,
    .ramp_seconds = ramp_seconds,
    // Hung-connection guard: with 0, zrk never arms `watchTimer`
    // (connection.zig), and an outstanding read wedged haproxy's ramp (run #14).
    .timeout_s = 1,

    // One SLO for every proxy. Without it every c10k tail percentile is zrk's
    // 60s clamp and each proxy's own timeouts decide the outcome. It sheds
    // heavily past each knee, but is negligible at `ref_rate`.
    .deadline_ms = 1000,
    .req_path = "/10k",
    // t=36s: past the 10k-connection connect storm (8000 sat at t=23 on the
    // 100k ramp), and under envoy's 10 KiB knee (lowest c1k night 5989), so
    // the reference latency is not overload.
    .ref_rate = 5000,
    .ref_band = 0.15,
    .cooldown_s = 8,
    .proxy_env = &.{
        // Comptime ceiling for both (zoxy #108); below it zoxy sheds ~1/3 by
        // admission policy. The ceiling moves between zoxy versions (#132): run
        // `zoxy --check <rendered config>` after a bump, or startup fails with
        // `LimitConnSlotsOutOfRange`.
        .{ .key = "ZOXY_CONN_SLOTS", .value = "11457" },
        // Not 4x conn_slots like c1k: already at the ceiling, so round-robin
        // redials instead of parking per endpoint. Nonzero
        // `zoxy_shed_upstream_slots` here is a zoxy limit, not a tuning bug.
        .{ .key = "ZOXY_UPSTREAM_SLOTS", .value = "11457" },
    },
};

/// The CI gate: the full production path in ~35s per proxy on a GitHub runner.
///
/// Not a measurement: its ramp shape differs from every other profile, so its
/// numbers are incomparable by construction, and it runs only under `--local`.
pub const smoke: Profile = .{
    .name = "smoke",
    .connections = 50,
    // The 4-core runner also hosts the proxy and origin pool.
    .threads = 2,
    .start_rate = 200,
    .max_rate = 5_000,
    .ramp_seconds = 30,
    .timeout_s = 1,
    .deadline_ms = 0,
    .req_path = "/10k",
    // t=11.25s: clear of the t>=3 warmup, with the +/-20% band whole.
    .ref_rate = 2000,
    .ref_band = 0.20,
    // Only needs to drain connections before the next turn.
    .cooldown_s = 2,
    .proxy_env = &.{},
};

/// APPEND-ONLY: `suite.proxyPort` keys per-turn host ports off the index, and
/// renumbering reuses ports an earlier turn served load on (runs #25/#26).
/// Dropping from the tail renumbers nothing (the c1k body bands left that way).
pub const all = [_]Profile{ c100, c1k, c10k, c1k_tls, smoke, c1k_h2, c1k_h3 };

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
    try std.testing.expect(byName("c100") != null);
    try std.testing.expect(byName("c1k") != null);
    try std.testing.expect(byName("c10k") != null);
    try std.testing.expect(byName("c1k-tls") != null);
    try std.testing.expect(byName("c1k-h2") != null);
    try std.testing.expect(byName("c1k-h3") != null);
    try std.testing.expect(byName("") == null);
    try std.testing.expect(byName("c100k") == null);
    // The body bands are gone: naming one fails at argument parsing.
    try std.testing.expect(byName("c1k-64") == null);
    try std.testing.expect(byName("c1k-10k") == null);
    try std.testing.expect(byName("c1k-100k") == null);
}

test "every profile requests the one 10 KiB body, and none sizes zoxy's relay buffer" {
    // backend/10-gen-bodies.sh serves /10k and nothing else.
    for (all) |p| {
        try std.testing.expectEqualStrings("/10k", p.req_path);
        // Over 16 KiB a body costs zoxy extra round trips; the knob that hid
        // that left with the 100 KiB band, and its plumbing with it.
        for (p.proxy_env) |kv| {
            try std.testing.expect(!std.mem.eql(u8, kv.key, "ZOXY_RELAY_BUFFER_BYTES"));
        }
    }
}

test "c1k-tls is c1k with TLS on, and nothing else" {
    try std.testing.expect(c1k_tls.tls);
    try std.testing.expect(!c1k.tls);

    try std.testing.expectEqual(c1k.connections, c1k_tls.connections);
    try std.testing.expectEqual(c1k.threads, c1k_tls.threads);
    try std.testing.expectEqual(c1k.start_rate, c1k_tls.start_rate);
    try std.testing.expectEqual(c1k.max_rate, c1k_tls.max_rate);
    try std.testing.expectEqual(c1k.ramp_seconds, c1k_tls.ramp_seconds);
    try std.testing.expectEqual(c1k.timeout_s, c1k_tls.timeout_s);
    try std.testing.expectEqual(c1k.deadline_ms, c1k_tls.deadline_ms);
    try std.testing.expectEqual(c1k.ref_rate, c1k_tls.ref_rate);
    try std.testing.expectEqual(c1k.ref_band, c1k_tls.ref_band);
    try std.testing.expectEqual(c1k.cooldown_s, c1k_tls.cooldown_s);
    try std.testing.expectEqualStrings(c1k.req_path, c1k_tls.req_path);

    // Same slot tuning, plus exactly one TLS-only knob.
    for (c1k.proxy_env) |want| {
        for (c1k_tls.proxy_env) |got| {
            if (std.mem.eql(u8, want.key, got.key)) {
                try std.testing.expectEqualStrings(want.value, got.value);
                break;
            }
        } else return error.MissingTuning;
    }
    try std.testing.expectEqual(c1k.proxy_env.len + 1, c1k_tls.proxy_env.len);

    // One engine per TLS connection; a smaller pool measures the cap.
    var tls_engines: u32 = 0;
    for (c1k_tls.proxy_env) |kv| {
        if (std.mem.eql(u8, kv.key, "ZOXY_TLS_ENGINES")) {
            tls_engines = try std.fmt.parseInt(u32, kv.value, 10);
        }
    }
    try std.testing.expect(tls_engines >= c1k_tls.connections);
    // zoxy's startup ceiling (`constants.tls_engines_max`).
    try std.testing.expect(tls_engines <= 1024);
}

test "c1k-h2 is c1k-tls with HTTP/2 on, and nothing else" {
    try std.testing.expect(c1k_h2.h2);
    try std.testing.expect(c1k_h2.tls);
    try std.testing.expect(!c1k_tls.h2);

    try std.testing.expectEqual(c1k_tls.connections, c1k_h2.connections);
    try std.testing.expectEqual(c1k_tls.threads, c1k_h2.threads);
    try std.testing.expectEqual(c1k_tls.start_rate, c1k_h2.start_rate);
    try std.testing.expectEqual(c1k_tls.max_rate, c1k_h2.max_rate);
    try std.testing.expectEqual(c1k_tls.ramp_seconds, c1k_h2.ramp_seconds);
    try std.testing.expectEqual(c1k_tls.timeout_s, c1k_h2.timeout_s);
    try std.testing.expectEqual(c1k_tls.deadline_ms, c1k_h2.deadline_ms);
    try std.testing.expectEqual(c1k_tls.ref_rate, c1k_h2.ref_rate);
    try std.testing.expectEqual(c1k_tls.ref_band, c1k_h2.ref_band);
    try std.testing.expectEqual(c1k_tls.cooldown_s, c1k_h2.cooldown_s);
    try std.testing.expectEqualStrings(c1k_tls.req_path, c1k_h2.req_path);

    // c1k-tls's tuning unchanged, plus exactly zoxy's two HTTP/2 pools.
    try std.testing.expectEqual(c1k_tls.proxy_env.len + 2, c1k_h2.proxy_env.len);
    for (c1k_tls.proxy_env, c1k_h2.proxy_env[0..c1k_tls.proxy_env.len]) |want, got| {
        try std.testing.expectEqualStrings(want.key, got.key);
        try std.testing.expectEqualStrings(want.value, got.value);
    }
    var h2_connections: u32 = 0;
    var h2_streams: u32 = 0;
    for (c1k_h2.proxy_env) |kv| {
        if (std.mem.eql(u8, kv.key, "ZOXY_H2_CONNECTIONS")) h2_connections = try std.fmt.parseInt(u32, kv.value, 10);
        if (std.mem.eql(u8, kv.key, "ZOXY_H2_STREAMS")) h2_streams = try std.fmt.parseInt(u32, kv.value, 10);
    }
    // Short of either, zoxy hands connections HTTP/1.1 or refuses streams,
    // and the ramp measures the cap rather than HTTP/2.
    try std.testing.expect(h2_connections >= c1k_h2.connections);
    try std.testing.expect(h2_streams >= c1k_h2.connections);
}

test "c1k-h3 is c1k-tls with HTTP/3 on, and nothing else" {
    try std.testing.expect(c1k_h3.h3);
    try std.testing.expect(c1k_h3.tls);
    try std.testing.expect(!c1k_h3.h2);
    try std.testing.expect(!c1k_tls.h3);
    try std.testing.expect(!c1k_h2.h3);

    try std.testing.expectEqual(c1k_tls.connections, c1k_h3.connections);
    try std.testing.expectEqual(c1k_tls.threads, c1k_h3.threads);
    try std.testing.expectEqual(c1k_tls.start_rate, c1k_h3.start_rate);
    try std.testing.expectEqual(c1k_tls.max_rate, c1k_h3.max_rate);
    try std.testing.expectEqual(c1k_tls.ramp_seconds, c1k_h3.ramp_seconds);
    try std.testing.expectEqual(c1k_tls.timeout_s, c1k_h3.timeout_s);
    try std.testing.expectEqual(c1k_tls.deadline_ms, c1k_h3.deadline_ms);
    try std.testing.expectEqual(c1k_tls.ref_rate, c1k_h3.ref_rate);
    try std.testing.expectEqual(c1k_tls.ref_band, c1k_h3.ref_band);
    try std.testing.expectEqual(c1k_tls.cooldown_s, c1k_h3.cooldown_s);
    try std.testing.expectEqualStrings(c1k_tls.req_path, c1k_h3.req_path);

    // c1k-tls's tuning unchanged, plus exactly zoxy's QUIC pool and the
    // stream pool a QUIC binding requires.
    try std.testing.expectEqual(c1k_tls.proxy_env.len + 2, c1k_h3.proxy_env.len);
    for (c1k_tls.proxy_env, c1k_h3.proxy_env[0..c1k_tls.proxy_env.len]) |want, got| {
        try std.testing.expectEqualStrings(want.key, got.key);
        try std.testing.expectEqualStrings(want.value, got.value);
    }
    var quic_connections: u32 = 0;
    var h2_streams: u32 = 0;
    var tls_engines: u32 = 0;
    for (c1k_h3.proxy_env) |kv| {
        if (std.mem.eql(u8, kv.key, "ZOXY_QUIC_CONNECTIONS")) quic_connections = try std.fmt.parseInt(u32, kv.value, 10);
        if (std.mem.eql(u8, kv.key, "ZOXY_H2_STREAMS")) h2_streams = try std.fmt.parseInt(u32, kv.value, 10);
        if (std.mem.eql(u8, kv.key, "ZOXY_TLS_ENGINES")) tls_engines = try std.fmt.parseInt(u32, kv.value, 10);
        // zoxy refuses HTTP/2's connection pool unless a listener offers h2.
        try std.testing.expect(!std.mem.eql(u8, kv.key, "ZOXY_H2_CONNECTIONS"));
    }
    // Short of the offered connections, zoxy leaves the rest unanswered and
    // the ramp measures the cap rather than HTTP/3. Over tls_engines, zoxy
    // refuses to start.
    try std.testing.expect(quic_connections >= c1k_h3.connections);
    try std.testing.expect(quic_connections <= tls_engines);
    try std.testing.expect(h2_streams >= c1k_h3.connections);
}

test "only an h3 profile leaves a proxy out, and only pingora" {
    for (all) |p| {
        try std.testing.expect(p.serves("zoxy"));
        try std.testing.expect(p.serves("haproxy"));
        try std.testing.expect(p.serves("nginx"));
        try std.testing.expect(p.serves("envoy"));
        try std.testing.expectEqual(!p.h3, p.serves("pingora"));
    }
}

test "only an h2 profile sizes zoxy's HTTP/2 connection pool" {
    // zoxy refuses h2_connections when no listener speaks h2, so on any
    // other profile it would not start.
    for (all) |p| {
        if (p.h2) continue;
        for (p.proxy_env) |kv| {
            try std.testing.expect(!std.mem.eql(u8, kv.key, "ZOXY_H2_CONNECTIONS"));
        }
    }
}

test "only an h2 or h3 profile sizes zoxy's stream pool" {
    // zoxy refuses h2_streams unless a listener speaks h2 or binds QUIC,
    // and requires it when one does.
    for (all) |p| {
        if (p.h2 or p.h3) continue;
        for (p.proxy_env) |kv| {
            try std.testing.expect(!std.mem.eql(u8, kv.key, "ZOXY_H2_STREAMS"));
        }
    }
}

test "only an h3 profile sizes zoxy's QUIC pool" {
    // zoxy refuses quic_connections when no listener binds QUIC.
    for (all) |p| {
        if (p.h3) continue;
        for (p.proxy_env) |kv| {
            try std.testing.expect(!std.mem.eql(u8, kv.key, "ZOXY_QUIC_CONNECTIONS"));
        }
    }
}

test "only a TLS profile sizes the TLS session pool" {
    // An engine pool on a plaintext profile would inflate published memory.
    for (all) |p| {
        if (p.tls) continue;
        for (p.proxy_env) |kv| {
            try std.testing.expect(!std.mem.eql(u8, kv.key, "ZOXY_TLS_ENGINES"));
        }
    }
}

test "the plaintext profiles stay plaintext" {
    // Acquiring TLS would silently change what historical trend points mean.
    try std.testing.expect(!c100.tls);
    try std.testing.expect(!c1k.tls);
    try std.testing.expect(!c10k.tls);
}

test "profile.all is append-only, because proxyPort keys off its index" {
    try std.testing.expectEqualStrings("c100", all[0].name);
    try std.testing.expectEqualStrings("c1k", all[1].name);
    try std.testing.expectEqualStrings("c10k", all[2].name);
    try std.testing.expectEqualStrings("c1k-tls", all[3].name);
    try std.testing.expectEqualStrings("smoke", all[4].name);
    try std.testing.expectEqualStrings("c1k-h2", all[5].name);
    try std.testing.expectEqualStrings("c1k-h3", all[6].name);
}

test "smoke shares no ramp shape with a published profile" {
    // Fails if someone "fixes" smoke to match, making it comparable.
    for (all) |p| {
        if (std.mem.eql(u8, p.name, "smoke")) continue;
        try std.testing.expect(p.max_rate != smoke.max_rate or
            p.ramp_seconds != smoke.ramp_seconds);
    }
}

test "validate rejects the misconfigurations the env plumbing used to allow" {
    var p = c1k;

    // A zero wire timeout is allowed as a compiled-in constant.
    p.timeout_s = 0;
    try p.validate();

    p = c1k;
    p.max_rate = p.start_rate;
    try std.testing.expectError(error.InvalidRampBounds, p.validate());

    // refHist excludes t<3, so this would null every summary latency.
    p = c1k;
    p.ref_rate = 250;
    try std.testing.expectError(error.RefRateInsideWarmup, p.validate());

    p = c1k;
    p.ref_rate = @floatFromInt(p.max_rate);
    try std.testing.expectError(error.RefRateAboveRamp, p.validate());

    // h2 rides ALPN; a plaintext h2 profile would have nothing to negotiate.
    p = c1k;
    p.h2 = true;
    try std.testing.expectError(error.H2WithoutTls, p.validate());

    // QUIC has no cleartext mode.
    p = c1k;
    p.h3 = true;
    try std.testing.expectError(error.H3WithoutTls, p.validate());

    // One connection speaks one protocol; zrk would refuse the pair.
    p = c1k_h2;
    p.h3 = true;
    try std.testing.expectError(error.H3WithH2, p.validate());
}

test "c10k carries the deadline SLO and c1k does not" {
    // Without it c10k's tail percentiles all read zrk's 60s clamp.
    try std.testing.expect(c10k.deadline_ms > 0);
    try std.testing.expectEqual(@as(u64, 0), c1k.deadline_ms);
}

test "profiles share one ramp shape so the offered axis is comparable" {
    for (all) |p| {
        // `smoke` is the one exception; see its own test above.
        if (std.mem.eql(u8, p.name, smoke.name)) continue;
        try std.testing.expectEqual(start_rate, p.start_rate);
        try std.testing.expectEqual(max_rate, p.max_rate);
        try std.testing.expectEqual(ramp_seconds, p.ramp_seconds);
    }
}

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

// Shared ramp shape: the offered axis every chart shares. 100k rps of 1 KiB is
// ~820 Mbps, near the rig's NIC limit, which nothing measures now; compare
// proxies to each other, not to line rate (`direct` in git history finds it).
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
/// 2000 so "TLS costs X" is a subtraction (~2.6 MB/s AEAD, well sub-knee).
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

/// c1k with a different response body and nothing else changed (bodies from
/// backend/10-gen-bodies.sh). Large bodies hit the rig's line rate (see the
/// ramp-shape note above `start_rate`): c1k-100k saturates near ~1k rps, below
/// `ref_rate`, so it mostly measures the network.
fn c1kBody(comptime name: []const u8, comptime path: []const u8) Profile {
    var p = c1k;
    p.name = name;
    p.req_path = path;
    return p;
}

pub const c1k_64 = c1kBody("c1k-64", "/64");
pub const c1k_10k = c1kBody("c1k-10k", "/10k");
pub const c1k_100k = c1kBody("c1k-100k", "/100k");

pub const c100: Profile = .{
    .name = "c100",
    .connections = 100,
    .threads = 4,
    .start_rate = start_rate,
    .max_rate = max_rate,
    .ramp_seconds = ramp_seconds,
    .timeout_s = 1,
    .deadline_ms = 0,
    .req_path = "/1k",
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
    // 60s clamp and each proxy's own timeouts decide the outcome. It sheds ~90%
    // at the top of the ramp, but is negligible at `ref_rate`.
    .deadline_ms = 1000,
    .req_path = "/1k",
    // ~t=47s: past the connect storm for all 10k connections.
    .ref_rate = 8000,
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
    .req_path = "/1k",
    // t=11.25s: clear of the t>=3 warmup, with the +/-20% band whole.
    .ref_rate = 2000,
    .ref_band = 0.20,
    // Only needs to drain connections before the next turn.
    .cooldown_s = 2,
    .proxy_env = &.{},
};

/// APPEND-ONLY: `suite.proxyPort` keys per-turn host ports off the index, and
/// renumbering reuses ports an earlier turn served load on (runs #25/#26).
pub const all = [_]Profile{ c100, c1k, c10k, c1k_tls, smoke, c1k_64, c1k_10k, c1k_100k };

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
    try std.testing.expect(byName("c1k-64") != null);
    try std.testing.expect(byName("c1k-10k") != null);
    try std.testing.expect(byName("c1k-100k") != null);
    try std.testing.expect(byName("") == null);
    try std.testing.expect(byName("c100k") == null);
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
    try std.testing.expectEqualStrings("c1k-64", all[5].name);
    try std.testing.expectEqualStrings("c1k-10k", all[6].name);
    try std.testing.expectEqualStrings("c1k-100k", all[7].name);
}

test "the body-size profiles are c1k with the body swapped, and nothing else" {
    for ([_]Profile{ c1k_64, c1k_10k, c1k_100k }) |p| {
        try std.testing.expect(!std.mem.eql(u8, c1k.req_path, p.req_path));
        try std.testing.expectEqual(c1k.tls, p.tls);
        try std.testing.expectEqual(c1k.connections, p.connections);
        try std.testing.expectEqual(c1k.threads, p.threads);
        try std.testing.expectEqual(c1k.start_rate, p.start_rate);
        try std.testing.expectEqual(c1k.max_rate, p.max_rate);
        try std.testing.expectEqual(c1k.ramp_seconds, p.ramp_seconds);
        try std.testing.expectEqual(c1k.timeout_s, p.timeout_s);
        try std.testing.expectEqual(c1k.deadline_ms, p.deadline_ms);
        try std.testing.expectEqual(c1k.ref_rate, p.ref_rate);
        try std.testing.expectEqual(c1k.ref_band, p.ref_band);
        try std.testing.expectEqual(c1k.cooldown_s, p.cooldown_s);
        try std.testing.expectEqual(c1k.proxy_env.ptr, p.proxy_env.ptr);
    }
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

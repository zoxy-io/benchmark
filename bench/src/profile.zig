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

    /// Offer the load over TLS, terminated by the proxy under test.
    ///
    /// INBOUND ONLY. Every proxy's upstream leg stays plaintext, because zoxy's
    /// 0.2.0 TLS is inbound-only by design ("the upstream leg stays plaintext"),
    /// and letting the other four also encrypt to the origin would measure a job
    /// zoxy cannot do rather than the one they share.
    ///
    /// Each proxy carries BOTH listeners at all times — plaintext on
    /// `PROXY_PORT`, TLS on `PROXY_TLS_PORT` (see compose.yaml) — and this flag
    /// only decides which one the ramp is pointed at. That is what keeps the
    /// container healthcheck on the plaintext port for every profile: three of
    /// the five images have neither curl nor openssl, and bash's /dev/tcp cannot
    /// speak TLS at all, so a healthcheck through the TLS listener is not
    /// available in the images this comparison is allowed to use.
    ///
    /// What the generator is, and is not, exercising — zrk drives Zig's std TLS
    /// client, so all three of these travel with any number this profile
    /// produces:
    ///
    ///   * TLS 1.3 ONLY. Nothing here measures 1.2, and every proxy's listener
    ///     is pinned to 1.3 so the negotiation cannot silently differ.
    ///   * NO ALPN is offered, so every proxy falls back to HTTP/1.1 — the same
    ///     protocol the plaintext profiles measure. Nothing here is HTTP/2.
    ///   * NO SESSION RESUMPTION. The client never presents a ticket, so every
    ///     connection is a full handshake and zoxy's 0.2.0 ticket support is
    ///     never exercised. Handshakes are paid at CONNECT time — all
    ///     `connections` of them in the first seconds of the ramp — and the
    ///     steady state that `ref_rate` reads is record-layer crypto on a
    ///     kept-alive connection, not handshake throughput.
    tls: bool = false,

    /// SUMMARY-latency reference offered rate: a shared, light, sub-knee load
    /// where a single per-proxy latency number is actually fair, because it
    /// reflects per-request COST rather than standing-queue wait.
    ///
    /// Per-profile because the connect storm moves. On a 200->100000/300s ramp
    /// (the compiled-in `start_rate`/`max_rate`/`ramp_seconds` below), offered
    /// 2000 rps at c1k's +/-20% band is t~=[4.2, 6.6]s — and at 10000
    /// connections zrk is still ESTABLISHING connections then
    /// (zrk/src/runner.zig:153-156 launches them all at once), so a 2000 rps
    /// reading at c10k measures connection setup, not proxying.
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
/// to extend past every proxy's knee for the knee to be visible at all.
///
/// It does mean the rig has a ceiling of its own, somewhere near line rate, and
/// NOTHING measures it any more: the `direct` baseline used to top out on the
/// network rather than on the origin and so marked exactly where the rig
/// saturated. Read proxies against each other, never as a fraction of line rate
/// — and if two proxies ever converge on the same suspiciously round plateau,
/// suspect this ceiling and restore `direct` from git history to find it.
/// Which zoxy every profile measures.
///
/// `release` is not a git ref. It means "the latest published release", which
/// `suite.resolveZoxySource` turns into a concrete tag before anything is
/// built, and which then arrives as an upstream tarball rather than a compile
/// (see proxies/zoxy/Dockerfile). Three things follow from that and they are
/// the reason for the setting:
///
///   * It measures the binary users actually download — the same standing the
///     stock haproxy, nginx and envoy images have here. A source build is our
///     build of their code; a release is theirs.
///   * It removes the longest, most failure-prone step of the night. The
///     source path compiles on the fleet and fetches four git dependencies
///     over NAT egress; run 30749146321 lost zoxy entirely to one transient
///     failure in there, on a commit that built fine before and after.
///   * The trend chart's points become versions rather than commits. That is
///     the real cost: a regression is now bisectable only to a release, and it
///     surfaces the night after it SHIPS, not the night after it lands.
///
/// Set this to `main` (or any branch, tag or sha) to get the old behaviour
/// back — the source path is unchanged and still the only way to bench an
/// unreleased commit or a PR. A floating ref only means anything if the clone
/// is actually fresh, so that path keeps its cache-bust; see the Dockerfile.
///
/// Passed explicitly rather than left to compose's `${ZOXY_REF:-main}` default,
/// so what gets measured is a stated intent rather than something that happens
/// because nobody set the variable.
pub const zoxy_ref = "release";

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
        // FOUR TIMES conn_slots, not equal to it, since the origin became a
        // four-node pool. zoxy's upstream pool is process-wide but parked PER
        // ENDPOINT on keep-alive, and the pick policy is round-robin per
        // request — so a single downstream connection rotates through all four
        // backends and wants a warm upstream parked at each. Held at 1386 the
        // pool would be ~1/4 of what steady state asks for, and zoxy would shed
        // on `zoxy_l7_shed_upstream_slots`: a number that measures the pool
        // rather than the proxy, and one that reads as a regression against
        // every pre-pool run.
        //
        // 5544 = 4 x 1386, comfortably under the ~11463 comptime ceiling.
        // Watch `zoxy_shed_upstream_slots` in the run artifacts — nonzero means
        // this arithmetic is still wrong.
        .{ .key = "ZOXY_UPSTREAM_SLOTS", .value = "5544" },
    },
};

/// c1k with TLS on the client leg, and NOTHING else changed.
///
/// Derived from `c1k` rather than spelled out, which is the whole design of it:
/// same ramp, same connection count, same reference rate, same zoxy slot
/// tuning, so the pair isolates the cost of terminating TLS instead of
/// measuring two different experiments. A field that has to be tuned differently
/// here (it has not been needed yet) should be set below, visibly, as a
/// deliberate divergence.
///
/// `ref_rate` is inherited at 2000 rps deliberately. Reading both profiles'
/// summary latency at the same offered rate is what makes "TLS costs X" a
/// subtraction rather than a comparison of two unrelated points, and 2000 rps of
/// 1 KiB bodies is ~2.6 MB/s of AEAD — nowhere near a bulk-crypto ceiling on any
/// of these proxies, so it stays the sub-knee reference it is at c1k.
///
/// The name carries a dash, like nothing else here: it is a directory under the
/// run, a path segment on the published site and a series in the trend chart, so
/// `c1k-tls` sorts and reads next to `c1k` in all three.
pub const c1k_tls: Profile = blk: {
    var p = c1k;
    p.name = "c1k-tls";
    p.tls = true;
    // c1k's tuning, plus the one knob that only exists when a listener
    // terminates TLS.
    //
    // ZOXY_TLS_ENGINES is 1024 because that is ALL v0.2.0 ALLOWS: it is both the
    // shipped default and the comptime ceiling — 2048 and 4096 are rejected at
    // startup with `LimitTlsEnginesOutOfRange`, measured against the v0.2.0
    // release binary. So unlike conn_slots and upstream_slots, this is not a
    // number this profile gets to choose, and it is pinned rather than left
    // implicit for the same reason c1k pins conn_slots to ITS default: the run
    // record should state the pool the numbers came from.
    //
    // zoxy holds one preallocated engine per admitted TLS connection and sheds
    // past the pool, where the other four allocate per connection with no such
    // ceiling. 1024 against this profile's 1000 offered connections is 2.4%
    // headroom — the same too-close-to-call margin that made c1k widen the
    // upstream pool, except here there is nothing to widen. It holds because zrk
    // opens exactly `connections` and keeps them; churn is what would break it.
    // `bench` reads `zoxy_shed_tls_engines` off the admin endpoint after every
    // TLS ramp, and a nonzero value means this ramp measured zoxy's admission
    // cap rather than its TLS — which is a finding about zoxy's ceiling, not a
    // number to publish as its TLS throughput.
    //
    // It is also most of zoxy's memory here: ~136 KiB plus a 64 KiB plaintext
    // buffer per engine, preallocated at boot, so ~283 MiB against 35 MiB for
    // the same proxy with no TLS listener (measured, v0.2.0). That is a real
    // property of terminating TLS this way, and it is why the TLS listener is
    // not left bound on the plaintext profiles — see compose.yaml.
    p.proxy_env = &.{
        .{ .key = "ZOXY_CONN_SLOTS", .value = "1386" },
        .{ .key = "ZOXY_UPSTREAM_SLOTS", .value = "5544" },
        .{ .key = "ZOXY_TLS_ENGINES", .value = "1024" },
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
    .req_path = "/1k",
    // Same as c1k's: 100 connections is nowhere near a throughput ceiling
    // (zrk reuses each connection for many sequential requests, so c1k's 1000
    // connections already sustained 50-90k rps in practice — connections cap
    // in-flight CONCURRENCY, not completions/sec), and a shared ref_rate keeps
    // this profile's summary latency directly comparable to c1k's.
    .ref_rate = 2000,
    .ref_band = 0.20,
    .cooldown_s = 8,
    // No override: 100 offered connections sit at ~10% of zoxy's stock 1024
    // conn_slots default, nowhere near the headroom pressure that made c1k
    // pin ZOXY_UPSTREAM_SLOTS to its conn_slots. This profile exists to be
    // the cheap, fast-turnaround control while c10k's start failures (run
    // #25) are being chased — it should exercise zoxy's SHIPPED defaults, not
    // a bespoke config.
    .proxy_env = &.{},
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
        // NOT 4x conn_slots, unlike c1k — there is no room. The pool is already
        // AT the comptime ceiling, so with a four-node origin this profile
        // cannot park a warm upstream per (connection, endpoint) the way c1k
        // can; round-robin will evict and redial instead. That is a real
        // handicap and it is the honest one available: the alternative is
        // lowering conn_slots, which trades admission capacity zoxy demonstrably
        // needs at 10k for pool depth. If `zoxy_shed_upstream_slots` shows up
        // here, this profile is measuring the ceiling and not the proxy, and the
        // fix is upstream in zoxy rather than in this file.
        .{ .key = "ZOXY_UPSTREAM_SLOTS", .value = "11464" },
    },
};

/// APPEND-ONLY, and the reason is `suite.proxyPort`: it keys each profile's
/// block of per-turn host ports off this array's index, so inserting a profile
/// anywhere but the end renumbers every profile after it. Ports are per
/// (profile, proxy) turn precisely so no turn ever rebinds a port a previous
/// turn used (runs #25/#26), and a renumbering would hand tonight's turns ports
/// that an earlier turn in the same dispatch had already served load on.
pub const all = [_]Profile{ c100, c1k, c10k, c1k_tls };

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
    try std.testing.expect(byName("") == null);
    try std.testing.expect(byName("c100k") == null);
}

test "c1k-tls is c1k with TLS on, and nothing else" {
    // The point of the profile is the subtraction: anything that differs beyond
    // the name and the transport makes "TLS costs X" a comparison of two
    // unrelated experiments instead.
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

    // Same zoxy admission/pool tuning — the TLS row must not be measuring a
    // different slot configuration as well as a different transport — plus
    // exactly one knob that has no meaning without a TLS listener.
    for (c1k.proxy_env) |want| {
        for (c1k_tls.proxy_env) |got| {
            if (std.mem.eql(u8, want.key, got.key)) {
                try std.testing.expectEqualStrings(want.value, got.value);
                break;
            }
        } else return error.MissingTuning;
    }
    try std.testing.expectEqual(c1k.proxy_env.len + 1, c1k_tls.proxy_env.len);

    // And the engine pool covers the load this profile offers: one engine is
    // held per admitted TLS connection, so a pool smaller than `connections`
    // sheds by policy and the ramp measures zoxy's admission cap instead of its
    // TLS. Derived from the profile rather than hardcoded, so raising
    // `connections` past the pool fails HERE rather than in a night's numbers.
    var tls_engines: u32 = 0;
    for (c1k_tls.proxy_env) |kv| {
        if (std.mem.eql(u8, kv.key, "ZOXY_TLS_ENGINES")) {
            tls_engines = try std.fmt.parseInt(u32, kv.value, 10);
        }
    }
    try std.testing.expect(tls_engines >= c1k_tls.connections);
    // v0.2.0 rejects anything above this at startup (LimitTlsEnginesOutOfRange),
    // so a profile that needs more headroom needs a zoxy that allows it.
    try std.testing.expect(tls_engines <= 1024);
}

test "only a TLS profile sizes the TLS session pool" {
    // `tls_engines` is "zero exactly when no listener terminates TLS" — setting
    // it on a plaintext profile would preallocate ~136 KiB per engine for a
    // listener that does not exist, and put a quarter of a gigabyte on a
    // published memory number.
    for (all) |p| {
        if (p.tls) continue;
        for (p.proxy_env) |kv| {
            try std.testing.expect(!std.mem.eql(u8, kv.key, "ZOXY_TLS_ENGINES"));
        }
    }
}

test "the plaintext profiles stay plaintext" {
    // A profile silently acquiring TLS would change what every historical
    // trend point means without changing its name.
    try std.testing.expect(!c100.tls);
    try std.testing.expect(!c1k.tls);
    try std.testing.expect(!c10k.tls);
}

test "profile.all is append-only, because proxyPort keys off its index" {
    // Renumbering a profile's port block would hand a turn the port an earlier
    // turn in the same dispatch had already served load on — the exact
    // condition runs #25/#26 died of.
    try std.testing.expectEqualStrings("c100", all[0].name);
    try std.testing.expectEqualStrings("c1k", all[1].name);
    try std.testing.expectEqualStrings("c10k", all[2].name);
    try std.testing.expectEqualStrings("c1k-tls", all[3].name);
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

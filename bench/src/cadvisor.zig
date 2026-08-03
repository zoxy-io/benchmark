//! Polls the proxy host's cAdvisor at 1Hz for the container under test.
//!
//! This replaces the entire Prometheus/Grafana stack. Prometheus existed only to
//! answer three queries the report asked — container CPU rate, a node_cpu cpuset
//! fallback, and peak working-set memory — all of them fed by this same cAdvisor.
//! Sampling it straight into the run's own artifacts removes a scrape config, a
//! tsdb volume, a 30-day retention policy, an exposed port, and the wall-clock →
//! elapsed → offered remapping the report needed to line Prometheus samples up
//! with the ramp. Here `t` shares the ramp's own t0, so offered(t) is analytic.
//!
//! Raw counters are recorded, never rates. Turning `cpu_seconds_total` into
//! cores is a report concern (analysis/report), so the sampling policy and the
//! presentation policy stay independently reviewable. What the poller MUST
//! record for that to be possible is cAdvisor's own timestamp alongside the
//! counter — the counter advances on cAdvisor's housekeeping tick, not on the
//! poll, so the poll clock cannot express the rate. See `Sample.cadvisor_ms`.
//!
//! The poller has a second job: it is an INDEPENDENT WITNESS of which container
//! is actually serving. The old harness could record a ramp under the wrong
//! proxy's name — no proxy service had a healthcheck, so `compose up --wait`
//! returned as soon as a container was *running*, and a leftover container from
//! the previous proxy would answer the next proxy's warm probe on the shared host
//! port 8080. A probe against :8080 cannot detect that, because the imposter
//! answers it correctly. cAdvisor can: it reports the container `name` label, so
//! seeing the wrong name — or seeing two proxies at once — is unambiguous.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const Allocator = std.mem.Allocator;

pub const Sample = struct {
    /// Seconds since the ramp's t0, so the report can map straight onto the
    /// offered axis without any clock arithmetic.
    t: f64,
    cpu_seconds_total: f64,
    mem_ws: u64,
    /// cAdvisor's OWN timestamp for this counter value (ms since the epoch, as
    /// the exposition carries it), or 0 if it did not send one.
    ///
    /// This is the denominator the CPU rate has to use, and it is why the
    /// exposition's optional trailing timestamp is recorded rather than
    /// discarded. `t` is when the POLLER asked; the counter only advances on
    /// cAdvisor's own housekeeping tick, so the two clocks disagree, and
    /// dividing a housekeeping-quantized numerator by a poll-clock denominator
    /// does not measure a rate at all. At the harness's cadence — 1s
    /// housekeeping, ~1.045s effective poll period — roughly a third of polls
    /// re-read an unchanged counter (rate 0) and the poll after each of those
    /// covers two housekeeping intervals in one poll interval, reporting ~2x
    /// the true rate. That is what put points above the 1-CPU cap on a
    /// container that cannot physically exceed it (cpuset "0"): a 0.66-core
    /// haproxy charted spikes to 1.40.
    ///
    /// With cAdvisor's timestamp the numerator and denominator describe the
    /// SAME span, so the rate is exact and a stale re-read is simply a
    /// duplicate (zero span) to skip rather than a zero to plot.
    cadvisor_ms: i64 = 0,
};

pub const Error = error{
    /// cAdvisor reported a container the ramp did not ask for, or none at all.
    /// Almost always a leftover container holding host port 8080.
    IdentityMismatch,
};

/// Names the suite may run. The poller asserts that no OTHER member of this set
/// has a live container while one proxy is being measured, which is what makes
/// a leftover from the previous iteration detectable.
pub const known_proxies = [_][]const u8{
    "zoxy", "haproxy", "nginx", "pingora", "envoy",
};

pub const Observation = struct {
    /// Whether the expected container was present exactly once.
    found: bool = false,
    /// Any OTHER known proxy container seen in the same scrape.
    intruder: ?[]const u8 = null,
    cpu_seconds_total: f64 = 0,
    mem_ws: u64 = 0,
    /// cAdvisor's timestamp on the CPU series — see `Sample.cadvisor_ms`.
    cadvisor_ms: i64 = 0,
};

/// One scrape: GET /metrics and pick out the two series we need.
///
/// Deliberately a hand-rolled plain-HTTP request over std.Io.net rather than
/// std.http.Client: cAdvisor is plain HTTP on a private address with no
/// redirects and no TLS, the exposition is ~200 KB of text we want to stream
/// past rather than buffer, and this avoids depending on std.http.Client
/// behaving on zio's Io (it is well-trodden only on std.Io.Threaded).
pub fn scrape(
    io: Io,
    addr: net.IpAddress,
    proxy: []const u8,
    fd_slot: ?*std.atomic.Value(i32),
    connect_timeout: Io.Timeout,
) !Observation {
    // `connect_timeout` is caller-supplied, not hardcoded here: `Io.Threaded`
    // panics outright on any non-`.none` timeout ("TODO implement
    // netConnectIpPosix with timeout" — see suite.zig's `deadline.warm_probe`),
    // so callers under test pass `.none` and production callers (zio's real
    // Runtime, which has supported this since zio#230) pass a real bound.
    //
    // Bounding it at all matters: `active_fd`/`interrupt()` below can only
    // unblock a scrape stuck in a READ (the fd is published after connect()
    // returns), not one stuck IN connect() itself — and a cAdvisor that never
    // resolves, rather than one that answers slowly, hangs there. That gap
    // cost entire nightly runs (envoy, intermittently): `interrupt()` is a
    // no-op while `fd_slot` still reads -1, so `poll_group.cancel` in
    // ramp.run waited on a connect() that would never return, until the
    // whole-process `ProxyWatchdog` killed the run ~30 minutes later.
    var stream = try addr.connect(io, .{ .mode = .stream, .timeout = connect_timeout });
    defer stream.close(io);
    // Publish the socket so `interrupt` can unblock a read that never returns.
    // Declared after the close defer so it runs BEFORE it: the fd is cleared
    // while it is still valid, never after it could have been reused.
    if (fd_slot) |slot| slot.store(@intCast(stream.socket.handle), .release);
    defer if (fd_slot) |slot| slot.store(-1, .release);

    {
        var wbuf: [512]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        try w.interface.print(
            "GET /metrics HTTP/1.1\r\nHost: cadvisor\r\nAccept: text/plain\r\nConnection: close\r\n\r\n",
            .{},
        );
        try w.interface.flush();
    }

    var rbuf: [16 * 1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const in = &r.interface;

    var obs: Observation = .{};
    var seen_expected: usize = 0;

    // Stream line by line into a fixed buffer; nothing is accumulated, so a
    // 200 KB exposition is parsed with zero allocation.
    while (true) {
        const line = in.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            // A metric line longer than the buffer is not one of ours; skip the
            // oversized chunk rather than aborting the whole scrape.
            error.StreamTooLong => {
                _ = in.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            else => return err,
        };

        if (parseMetric(line, "container_cpu_usage_seconds_total")) |m| {
            if (nameLabel(m.labels)) |n| {
                if (std.mem.eql(u8, n, proxy)) {
                    // cAdvisor emits one series per cgroup hierarchy level; the
                    // named one is the container itself.
                    obs.cpu_seconds_total += m.value;
                    if (m.timestamp_ms) |ms| obs.cadvisor_ms = @max(obs.cadvisor_ms, ms);
                    seen_expected += 1;
                } else if (matchKnownProxy(n)) |static_name| {
                    obs.intruder = static_name;
                }
            }
        } else if (parseMetric(line, "container_memory_working_set_bytes")) |m| {
            if (nameLabel(m.labels)) |n| {
                if (std.mem.eql(u8, n, proxy)) {
                    obs.mem_ws = @max(obs.mem_ws, @as(u64, @intFromFloat(m.value)));
                } else if (matchKnownProxy(n)) |static_name| {
                    obs.intruder = static_name;
                }
            }
        }
    }

    obs.found = seen_expected > 0;
    return obs;
}

fn isKnownProxy(name: []const u8) bool {
    return matchKnownProxy(name) != null;
}

/// The `known_proxies` entry equal to `name`, or null.
///
/// Returns the STATIC string from `known_proxies` rather than `name` itself.
/// `name` is a slice into `scrape()`'s per-call read buffer (`rbuf`, a stack
/// array) and does not outlive `scrape()` returning — `Observation.intruder`
/// used to be set directly to `name`, which meant every caller that read it
/// after the call returned was already looking at a dangling pointer. One
/// local repro printed the container name as "ompose_", a scrap of the
/// process's own prior stack contents, instead of the real intruder.
/// `known_proxies` has program lifetime, so returning its own entry sidesteps
/// the dangling-pointer problem entirely rather than copying into a buffer.
fn matchKnownProxy(name: []const u8) ?[]const u8 {
    for (known_proxies) |p| {
        if (std.mem.eql(u8, name, p)) return p;
    }
    return null;
}

const Metric = struct { labels: []const u8, value: f64, timestamp_ms: ?i64 = null };

/// Match `<name>{<labels>} <value> [<timestamp_ms>]` and return the label set,
/// the value, and the exposition's optional trailing timestamp.
///
/// That timestamp is not decoration: cAdvisor stamps every series with the
/// housekeeping instant the value belongs to, which is the only clock on which
/// the CPU counter's rate is well defined. See `Sample.cadvisor_ms`.
fn parseMetric(line: []const u8, name: []const u8) ?Metric {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, name)) return null;
    if (trimmed.len <= name.len or trimmed[name.len] != '{') return null;

    const close = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return null;
    const labels = trimmed[name.len + 1 .. close];

    var rest = std.mem.trim(u8, trimmed[close + 1 ..], " \t");
    // Prometheus text format allows an optional trailing timestamp.
    var ts: ?i64 = null;
    if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
        ts = std.fmt.parseInt(i64, std.mem.trim(u8, rest[sp + 1 ..], " \t"), 10) catch null;
        rest = rest[0..sp];
    }
    const value = std.fmt.parseFloat(f64, rest) catch return null;

    return .{ .labels = labels, .value = value, .timestamp_ms = ts };
}

/// Extract `name="..."` from a Prometheus label set.
fn nameLabel(labels: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < labels.len) {
        const eq = std.mem.indexOfScalarPos(u8, labels, i, '=') orelse return null;
        const key = std.mem.trim(u8, labels[i..eq], " ,");
        if (eq + 1 >= labels.len or labels[eq + 1] != '"') return null;
        const start = eq + 2;
        const end = std.mem.indexOfScalarPos(u8, labels, start, '"') orelse return null;
        if (std.mem.eql(u8, key, "name")) return labels[start..end];
        i = end + 1;
        if (i < labels.len and labels[i] == ',') i += 1;
    }
    return null;
}

/// Poll `scrape` until it reports `proxy`'s container, or `timeout_ns`
/// elapses. Best-effort: returns whether it was seen, never an error — a
/// cAdvisor that never catches up should cost the CPU/mem chart, not the
/// throughput measurement.
///
/// Exists because cAdvisor's own container discovery can lag well behind the
/// container actually starting. Nightly run #28: cAdvisor answered every
/// scrape correctly (zero failures) for the WHOLE 300s ramp without once
/// reporting c100's zoxy or haproxy, while the very next proxy (pingora) —
/// and every proxy in that same night's later c1k profile — worked fine. On
/// a healthy run this returns on its first scrape, so the cost here is one
/// HTTP round trip; the bound only matters on the run it exists for.
///
/// `connect_timeout` is forwarded to `scrape` as-is (`.none` under
/// `Io.Threaded` in tests, a real bound in production) — this loop's own
/// `timeout_ns` bounds attempts BETWEEN scrapes, not a scrape stuck inside
/// one, so without it a single wedged connect() could hold this past
/// `timeout_ns` indefinitely, same as `Poller.run`'s.
pub fn waitUntilFound(
    io: Io,
    addr: net.IpAddress,
    proxy: []const u8,
    timeout_ns: u64,
    connect_timeout: Io.Timeout,
) bool {
    const started = Io.Timestamp.now(io, .awake);
    while (true) {
        if (scrape(io, addr, proxy, null, connect_timeout)) |obs| {
            if (obs.found) return true;
        } else |_| {}
        if (started.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds >= timeout_ns) return false;
        io.sleep(.fromNanoseconds(std.time.ns_per_s), .awake) catch return false;
    }
}

/// Bounds a single scrape's connect() (see `scrape`'s doc comment) — generous
/// for what should be an instant local Docker-network HTTP GET, short enough
/// that a black-holed peer now costs seconds instead of the ~30 minutes an
/// unbounded connect() cost before this existed.
pub const scrape_connect_timeout: Io.Timeout = .{
    .duration = .{ .raw = .fromNanoseconds(5 * std.time.ns_per_s), .clock = .awake },
};

/// Samples one container for the length of a ramp, appending to `out`.
///
/// Runs as a concurrent task alongside the ramp. It never interrupts the run
/// itself: a scrape failure is recorded and retried, because losing the CPU
/// curve is much cheaper than losing the throughput measurement. Identity
/// violations are the exception — those mean the throughput number is being
/// attributed to the wrong proxy, so they set `identity_error` for the caller to
/// act on.
pub const Poller = struct {
    io: Io,
    addr: net.IpAddress,
    proxy: []const u8,
    t0: Io.Timestamp,
    out: *std.ArrayList(Sample),
    gpa: Allocator,

    stop: *std.atomic.Value(bool),
    /// Socket of the scrape currently in flight, or -1.
    ///
    /// `stop` alone cannot end a scrape that is already blocked: the poller only
    /// reads it between polls, and a scrape has neither a connect nor a read
    /// timeout — so a cAdvisor that stops answering blocks the poller forever,
    /// and `poll_group.cancel` in ramp.run then waits on it forever. That is a
    /// stalled scrape costing the RUN, which is exactly what `scrape` promises
    /// it cannot do.
    ///
    /// `interrupt` shuts this socket down from the outside, so the blocked read
    /// returns and the poller unwinds on its own.
    active_fd: std.atomic.Value(i32) = .init(-1),
    identity_error: std.atomic.Value(bool) = .init(false),
    scrape_failures: u32 = 0,
    /// cAdvisor was reachable and reported our container at least once. If this
    /// stays false the run produced no CPU/memory data at all, which the report
    /// must show as absent rather than as zero.
    ever_found: bool = false,

    /// Force a scrape that is blocked in connect or read to return.
    ///
    /// Called by the caller AFTER setting `stop`, so the poller sees the flag on
    /// its next pass and exits instead of retrying. `shutdown` rather than
    /// `close`: the poller still owns the socket and will close it itself, and
    /// closing an fd out from under a task in flight risks it being reused.
    pub fn interrupt(self: *Poller) void {
        const fd = self.active_fd.load(.acquire);
        if (fd < 0) return;
        _ = std.os.linux.shutdown(fd, std.os.linux.SHUT.RDWR);
    }

    pub fn run(self: *Poller) void {
        // A counter needs two points to become a rate, and the first scrape
        // lands mid-startup, so it is dropped.
        var first = true;

        while (!self.stop.load(.monotonic)) {
            const now = Io.Timestamp.now(self.io, .awake);
            const t = @as(f64, @floatFromInt(self.t0.durationTo(now).nanoseconds)) / std.time.ns_per_s;

            if (scrape(self.io, self.addr, self.proxy, &self.active_fd, scrape_connect_timeout)) |obs| {
                if (obs.intruder) |other| {
                    // A container for a DIFFERENT proxy is live while this one
                    // is being measured. Whatever is answering :8080 may not be
                    // the proxy we think it is, so the measurement is void.
                    self.identity_error.store(true, .monotonic);
                    std.debug.print(
                        "bench: identity: saw container \"{s}\" while ramping \"{s}\"\n",
                        .{ other, self.proxy },
                    );
                    return;
                }
                if (obs.found) {
                    self.ever_found = true;
                    if (first) {
                        first = false;
                    } else {
                        self.out.append(self.gpa, .{
                            .t = t,
                            .cpu_seconds_total = obs.cpu_seconds_total,
                            .mem_ws = obs.mem_ws,
                            .cadvisor_ms = obs.cadvisor_ms,
                        }) catch {};
                    }
                }
            } else |_| {
                self.scrape_failures += 1;
            }

            self.io.sleep(.fromNanoseconds(std.time.ns_per_s), .awake) catch break;
        }
    }
};

pub const CorePoint = struct { t: f64, cores: f64 };

/// Seconds between two samples ON THE CLOCK THE COUNTER ADVANCES ON, or null if
/// the pair spans no time at all and therefore yields no rate.
///
/// cAdvisor's own timestamp when it sent one (the normal case, and the only one
/// that gives an exact rate — see `Sample.cadvisor_ms`); the poller's ramp clock
/// otherwise, which is what artifacts recorded before `cadvisor_ms` existed
/// carry. A stale re-read is a duplicate on the cAdvisor clock, so it lands here
/// as a zero span and is skipped rather than plotted as a zero.
pub fn rateSpanSeconds(prev: Sample, s: Sample) ?f64 {
    if (prev.cadvisor_ms > 0 and s.cadvisor_ms > 0) {
        const ms = s.cadvisor_ms - prev.cadvisor_ms;
        return if (ms > 0) @as(f64, @floatFromInt(ms)) / 1000.0 else null;
    }
    const dt = s.t - prev.t;
    return if (dt > 0) dt else null;
}

/// The poller's effective period: a 1s sleep plus the scrape it just did.
/// Measured against the fleet, not chosen — it is what makes the poll clock
/// beat against cAdvisor's housekeeping.
pub const poll_period_s = 1.045;

/// Housekeeping intervals (ms) captured from a real cAdvisor v0.52.1 running
/// the harness's own flags (`--housekeeping_interval=1s
/// --allow_dynamic_housekeeping=false`).
///
/// The point of keeping the MEASURED values rather than a clean 1000ms is that
/// they are not clean: the interval jitters well past its nominal 1s. That is
/// what made the old poll-clock rate biased UPWARD rather than merely noisy —
/// each counter delta covers ~1.4s of housekeeping on average but was divided
/// by one ~1.045s poll, so the whole curve was scaled by about 1.4x.
pub const observed_housekeeping_ms = [_]i64{ 1220, 1379, 1994, 1044, 1289, 1761, 1605, 1329 };

/// Test support: what the poller records for a container pinned at exactly
/// `cores`, sampled the way the fleet samples it — cAdvisor advancing the
/// counter only on the (irregular) housekeeping ticks above, polled every
/// `poll_period_s`. Roughly a third of the polls re-read an unchanged counter.
///
/// A container capped at 1 CPU cannot exceed 1.0 cores, so any pipeline fed
/// `cores = 1.0` here must never report more.
pub fn peggedSamples(gpa: Allocator, cores: f64, polls: usize) ![]Sample {
    const epoch_ms: i64 = 1_785_556_727_497;

    var out: std.ArrayList(Sample) = .empty;
    errdefer out.deinit(gpa);

    var tick_ms = epoch_ms;
    var next_tick_ms = epoch_ms;
    var k: usize = 0;

    for (0..polls) |i| {
        const poll_t = poll_period_s * @as(f64, @floatFromInt(i));
        const poll_ms = epoch_ms + @as(i64, @intFromFloat(poll_t * 1000.0));
        // Advance cAdvisor's housekeeping up to (not past) this poll.
        while (next_tick_ms <= poll_ms) {
            tick_ms = next_tick_ms;
            next_tick_ms += observed_housekeeping_ms[k % observed_housekeeping_ms.len];
            k += 1;
        }
        const elapsed_s = @as(f64, @floatFromInt(tick_ms - epoch_ms)) / 1000.0;
        try out.append(gpa, .{
            .t = poll_t,
            .cpu_seconds_total = cores * elapsed_s,
            .mem_ws = 0,
            .cadvisor_ms = tick_ms,
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Convert raw counter samples into (elapsed, cores). The report maps elapsed
/// onto the offered axis analytically.
///
/// `t` stays the poller's ramp clock — that is the run's own time base and what
/// the offered axis is derived from — while the rate's denominator comes from
/// `rateSpanSeconds`. Mixing the two is deliberate: WHEN a sample happened and
/// WHAT SPAN its counter delta covers are different questions.
pub fn toCores(gpa: Allocator, samples: []const Sample) ![]CorePoint {
    const Pt = CorePoint;
    if (samples.len < 2) return &.{};
    var out: std.ArrayList(Pt) = .empty;
    errdefer out.deinit(gpa);
    for (samples[1..], 0..) |s, i| {
        const prev = samples[i];
        const span = rateSpanSeconds(prev, s) orelse continue;
        try out.append(gpa, .{
            .t = s.t,
            .cores = (s.cpu_seconds_total - prev.cpu_seconds_total) / span,
        });
    }
    return out.toOwnedSlice(gpa);
}

test "parseMetric pulls the value out of a cAdvisor line" {
    const line = "container_cpu_usage_seconds_total{id=\"/docker/3f2a\",name=\"zoxy\"} 9.73142\n";
    const m = parseMetric(line, "container_cpu_usage_seconds_total").?;
    try std.testing.expectApproxEqAbs(@as(f64, 9.73142), m.value, 1e-9);
    try std.testing.expectEqualStrings("zoxy", nameLabel(m.labels).?);
    // No trailing timestamp on this line, and none must be invented.
    try std.testing.expect(m.timestamp_ms == null);
}

test "parseMetric captures the trailing timestamp and rejects other metrics" {
    const line = "container_memory_working_set_bytes{name=\"haproxy\"} 41893888 1753699200000\n";
    const m = parseMetric(line, "container_memory_working_set_bytes").?;
    try std.testing.expectApproxEqAbs(@as(f64, 41893888), m.value, 1e-6);
    // The timestamp is the CPU rate's only correct denominator, so it has to
    // survive parsing rather than be stripped and dropped.
    try std.testing.expectEqual(@as(i64, 1753699200000), m.timestamp_ms.?);
    try std.testing.expect(parseMetric(line, "container_cpu_usage_seconds_total") == null);
    // A HELP/TYPE comment must not parse as a sample.
    try std.testing.expect(parseMetric("# TYPE container_cpu_usage_seconds_total counter", "container_cpu_usage_seconds_total") == null);
}

test "scrape reads the counter and cAdvisor's timestamp off a real exposition line" {
    // Verbatim from cAdvisor v0.52.1 with the harness's own flags (percpu
    // disabled, so exactly ONE cpu="total" series per container — the `+=` in
    // scrape is a single-series sum, not an accidental fan-in).
    const line = "container_cpu_usage_seconds_total{cpu=\"total\",id=\"/system.slice/docker-5e369d.scope\",image=\"gcr.io/cadvisor/cadvisor:v0.52.1\",name=\"zoxy\"} 0.153726 1785556717668\n";
    const m = parseMetric(line, "container_cpu_usage_seconds_total").?;
    try std.testing.expectEqualStrings("zoxy", nameLabel(m.labels).?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.153726), m.value, 1e-9);
    try std.testing.expectEqual(@as(i64, 1785556717668), m.timestamp_ms.?);
}

test "matchKnownProxy returns the static entry, not the caller's slice" {
    // The point of the fix: the returned slice must be `known_proxies[i]`
    // itself, never `name`, or `Observation.intruder` dangles the moment the
    // caller's buffer (scrape()'s stack-local rbuf, in production) is reused.
    var buf: [16]u8 = undefined;
    const scratch = std.fmt.bufPrint(&buf, "{s}", .{"haproxy"}) catch unreachable;
    const matched = matchKnownProxy(scratch).?;
    try std.testing.expect(matched.ptr != scratch.ptr);
    try std.testing.expectEqualStrings("haproxy", matched);

    try std.testing.expect(matchKnownProxy("mystery") == null);
}

test "nameLabel finds name regardless of label order" {
    try std.testing.expectEqualStrings("zoxy", nameLabel("id=\"/docker/x\",name=\"zoxy\",image=\"z\"").?);
    try std.testing.expectEqualStrings("zoxy", nameLabel("name=\"zoxy\"").?);
    // cAdvisor emits cgroup-level series with no name label; those are not the
    // container and must be ignored rather than misattributed.
    try std.testing.expect(nameLabel("id=\"/docker\"") == null);
}

test "nameLabel is not fooled by a label whose name is a suffix of 'name'" {
    // `image` and `container_name` must not be mistaken for `name`.
    try std.testing.expectEqualStrings("zoxy", nameLabel("container_name=\"other\",name=\"zoxy\"").?);
}

test "toCores differentiates the counter and drops the first sample" {
    const gpa = std.testing.allocator;
    // No cadvisor_ms: pre-fix artifacts, which must still render off the poll
    // clock rather than losing their CPU curve entirely.
    const samples = [_]Sample{
        .{ .t = 1, .cpu_seconds_total = 10, .mem_ws = 100 },
        .{ .t = 2, .cpu_seconds_total = 10.5, .mem_ws = 100 },
        .{ .t = 3, .cpu_seconds_total = 11.5, .mem_ws = 100 },
    };
    const pts = try toCores(gpa, &samples);
    defer gpa.free(pts);

    try std.testing.expectEqual(@as(usize, 2), pts.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), pts[0].cores, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pts[1].cores, 1e-9);
}

test "toCores rates a stale re-read on cAdvisor's clock, not the poll clock" {
    const gpa = std.testing.allocator;
    // The exact shape that put a 1-CPU-capped container above its cap. Real
    // numbers from results/repro-2 (haproxy, c1k): the poller runs at ~1.045s
    // while cAdvisor housekeeps at 1s, so poll 2 re-reads poll 1's counter and
    // poll 3 then carries TWO housekeeping intervals of CPU.
    //
    // Dividing that by one poll interval reported 0.0 cores then 0.851 —
    // the true rate across the pair is half of the latter.
    const samples = [_]Sample{
        .{ .t = 103.447, .cpu_seconds_total = 0.504315, .mem_ws = 100, .cadvisor_ms = 1785556730096 },
        .{ .t = 104.489, .cpu_seconds_total = 0.504315, .mem_ws = 100, .cadvisor_ms = 1785556730096 },
        .{ .t = 105.531, .cpu_seconds_total = 0.593284, .mem_ws = 100, .cadvisor_ms = 1785556732090 },
    };
    const pts = try toCores(gpa, &samples);
    defer gpa.free(pts);

    // The duplicate contributes no point at all — it is zero span, not 0 cores.
    try std.testing.expectEqual(@as(usize, 1), pts.len);
    // 0.088969 CPU-seconds over cAdvisor's own 1.994s span.
    try std.testing.expectApproxEqAbs(@as(f64, 0.04462), pts[0].cores, 1e-5);
    // The bug this replaces divided the same delta by ONE 1.042s poll interval,
    // inflating it by the ~1.9x that pushed capped containers over 1.0.
    const buggy = 0.088969 / 1.042;
    try std.testing.expect(buggy / pts[0].cores > 1.85);
    // `t` stays the ramp clock, so the offered-axis mapping is unaffected.
    try std.testing.expectApproxEqAbs(@as(f64, 105.531), pts[0].t, 1e-9);
}

test "toCores never charts a capped container above its cap" {
    const gpa = std.testing.allocator;
    // The cloud fleet's own situation: cpuset "0" makes anything above 1.0
    // physically impossible, so a reading above it is by definition the
    // instrument lying.
    const samples = try peggedSamples(gpa, 1.0, 200);
    defer gpa.free(samples);

    const pts = try toCores(gpa, samples);
    defer gpa.free(pts);

    try std.testing.expect(pts.len > 100);
    for (pts) |p| {
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), p.cores, 1e-9);
    }
}

test "the old poll-clock rate really did break on this same input" {
    // Guards the guard: if `peggedSamples` ever stopped reproducing the beat
    // between the poll period and cAdvisor's housekeeping, the tests above would
    // keep passing while testing nothing. So assert the OLD arithmetic — divide
    // the counter delta by the poll interval — still fails on it, both by
    // exceeding the cap and by the ~1.4x mean overstatement seen in production.
    const gpa = std.testing.allocator;
    const samples = try peggedSamples(gpa, 1.0, 200);
    defer gpa.free(samples);

    var n: usize = 0;
    var over: usize = 0;
    var sum: f64 = 0;
    var max: f64 = 0;
    for (samples[1..], 0..) |s, i| {
        const prev = samples[i];
        const dt = s.t - prev.t;
        if (dt <= 0) continue;
        const cores = (s.cpu_seconds_total - prev.cpu_seconds_total) / dt;
        n += 1;
        sum += cores;
        max = @max(max, cores);
        if (cores > 1.0) over += 1;
    }

    try std.testing.expect(n > 100);
    try std.testing.expect(over > 0); // charted a 1-CPU container above 1 CPU
    try std.testing.expect(max > 1.5);
    // Zeros from the stale re-reads drag the raw mean down; it is the median
    // filter downstream that drops those and leaves only the inflated side.
    try std.testing.expect(sum / @as(f64, @floatFromInt(n)) > 0.9);
}

test "waitUntilFound gives up after its bound against an address nothing answers on" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A closed local port: connect() fails immediately (ECONNREFUSED), so
    // this exercises the "never found, must eventually give up" path without
    // actually waiting out a long timeout. `.none`: `Io.Threaded` panics
    // outright on any other value (see `scrape`'s doc comment) and a fast
    // ECONNREFUSED never needs the bound anyway.
    const addr = try net.IpAddress.parse("127.0.0.1", 1);
    const found = waitUntilFound(io, addr, "zoxy", 300 * std.time.ns_per_ms, .none);
    try std.testing.expect(!found);
}

test "isKnownProxy covers the comparison set" {
    try std.testing.expect(isKnownProxy("zoxy"));
    try std.testing.expect(isKnownProxy("pingora"));
    // envoy came back as a default proxy (see commands.zig's parseProxies); it
    // was missing here for a while, which meant a leftover envoy container was
    // invisible to the preflight sweep AND the identity witness — exactly the
    // corruption class this whole mechanism exists to catch.
    try std.testing.expect(isKnownProxy("envoy"));
    // nginx came back the same way envoy did, and the same trap applies: miss
    // it here and a leftover nginx container is invisible to both the
    // preflight sweep and the identity witness.
    try std.testing.expect(isKnownProxy("nginx"));
    // `direct` is gone from the comparison and never had a container; it is
    // named here only so a leftover reference to it stays a plain unknown.
    try std.testing.expect(!isKnownProxy("direct"));
    try std.testing.expect(!isKnownProxy("cadvisor"));
}

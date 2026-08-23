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
const http = @import("http.zig");
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
/// One scrape: GET /metrics and pick out the two series we need.
///
/// Goes through `http.fetch` with a streaming sink, which is what makes the
/// framing somebody else's problem. This used to parse the socket by hand, and
/// spent months asking for HTTP/1.1 while reading the chunked body as plain
/// text: every 2 KiB, a hex chunk-size line was spliced into whatever metric
/// line straddled that offset, destroying it. Which series died depended on
/// byte offsets that hold still for one exposition layout and shift between
/// runs, so a container could be invisible for an entire ramp while docker and
/// curl both listed it.
///
/// `Sink.stream` keeps the property that motivated the hand-rolled version:
/// the exposition is parsed a line at a time out of the transport's buffer and
/// never accumulated, so a ~2 MB body costs one line of memory inside the load
/// generator's own process.
pub fn scrape(
    gpa: Allocator,
    io: Io,
    addr: net.IpAddress,
    proxy: []const u8,
    deadline_ns: u64,
) !Observation {
    // `{f}` on an IpAddress prints `host:port`, which is exactly a URL
    // authority — for IPv4. An IPv6 literal would need brackets here; every
    // address this is called with is the proxy host's v4.
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://{f}/metrics", .{addr});

    var ctx: ScrapeCtx = .{ .proxy = proxy };
    // 4 KiB is enough: raising this to 64 KiB was measured against a ~2 MB
    // exposition and changed the sample count not at all, so the drain
    // round-trips are not what a scrape spends its time on.
    var stack_buf: [4096]u8 = undefined;
    const buf = &stack_buf;
    // One metric line's worth. cAdvisor's are a few hundred bytes; this is the
    // same bound the hand-rolled reader used, and a line past it is dropped
    // whole rather than truncated.
    const carry = try gpa.alloc(u8, 16 * 1024);
    defer gpa.free(carry);

    var sink = http.LineSink.init(buf, carry, &ctx, ScrapeCtx.onLine);
    const res = try http.fetch(gpa, io, .{
        .url = url,
        .sink = .{ .stream = &sink },
        .deadline_ns = deadline_ns,
        .what = "cadvisor scrape",
    }) orelse return error.ScrapeTimedOut;
    if (!res.ok()) return error.ScrapeStatus;

    ctx.obs.found = ctx.seen_expected > 0;
    return ctx.obs;
}

/// Parse state for one scrape. Lives for the duration of `scrape` only; every
/// slice handed to `onLine` is valid for that call alone, which is why
/// `intruder` holds a `known_proxies` entry rather than the line's own bytes.
const ScrapeCtx = struct {
    proxy: []const u8,
    obs: Observation = .{},
    seen_expected: usize = 0,

    fn onLine(raw: *anyopaque, line: []const u8) void {
        const self: *ScrapeCtx = @ptrCast(@alignCast(raw));
        if (parseMetric(line, "container_cpu_usage_seconds_total")) |m| {
            if (nameLabel(m.labels)) |n| {
                if (std.mem.eql(u8, n, self.proxy)) {
                    // cAdvisor emits one series per cgroup hierarchy level; the
                    // named one is the container itself.
                    self.obs.cpu_seconds_total += m.value;
                    if (m.timestamp_ms) |ms| self.obs.cadvisor_ms = @max(self.obs.cadvisor_ms, ms);
                    self.seen_expected += 1;
                } else if (matchKnownProxy(n)) |static_name| {
                    self.obs.intruder = static_name;
                }
            }
        } else if (parseMetric(line, "container_memory_working_set_bytes")) |m| {
            if (nameLabel(m.labels)) |n| {
                if (std.mem.eql(u8, n, self.proxy)) {
                    self.obs.mem_ws = @max(self.obs.mem_ws, @as(u64, @intFromFloat(m.value)));
                } else if (matchKnownProxy(n)) |static_name| {
                    self.obs.intruder = static_name;
                }
            }
        }
    }
};

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
/// Nightly run #28 is what this was written for: cAdvisor answered every
/// scrape correctly (zero failures) for the WHOLE 300s ramp without once
/// reporting c100's zoxy or haproxy, while the very next proxy (pingora) —
/// and every proxy in that same night's later c1k profile — worked fine. That
/// was read at the time as cAdvisor's discovery lagging the container.
///
/// It was not. `scrape` was requesting HTTP/1.1 and reading the chunked body
/// as raw text, so a fixed fraction of series was destroyed by chunk framing,
/// and WHICH ones depended on byte offsets that hold still for the life of an
/// exposition layout — a container could therefore be invisible for an entire
/// ramp while `docker` and `curl` both showed it. See `scrape`'s request.
///
/// The wait is kept anyway: discovery genuinely is asynchronous, and one HTTP
/// round trip on a healthy run is the whole cost.
///
/// `connect_timeout` is forwarded to `scrape` as-is (`.none` under
/// `Io.Threaded` in tests, a real bound in production) — this loop's own
/// `timeout_ns` bounds attempts BETWEEN scrapes, not a scrape stuck inside
/// one, so without it a single wedged connect() could hold this past
/// `timeout_ns` indefinitely, same as `Poller.run`'s.
pub fn waitUntilFound(
    gpa: Allocator,
    io: Io,
    addr: net.IpAddress,
    proxy: []const u8,
    timeout_ns: u64,
    per_scrape_ns: u64,
) bool {
    const started = Io.Timestamp.now(io, .awake);
    while (true) {
        if (scrape(gpa, io, addr, proxy, per_scrape_ns)) |obs| {
            if (obs.found) return true;
        } else |_| {}
        if (started.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds >= timeout_ns) return false;
        io.sleep(.fromNanoseconds(std.time.ns_per_s), .awake) catch return false;
    }
}

/// Bounds a single scrape end to end — generous for what should be an instant
/// local Docker-network HTTP GET, short enough that a black-holed peer costs
/// seconds instead of the ~30 minutes an unbounded connect cost before any
/// bound existed.
///
/// One number now covers connect, headers and body, because `http.fetch`
/// cancels the whole request rather than bounding one syscall of it. That is
/// what retired `Poller.active_fd`: a scrape can no longer block past this, so
/// there is nothing left for an outside `shutdown()` to rescue.
pub const scrape_deadline_ns: u64 = 5 * std.time.ns_per_s;

/// One sampling period, measured start-of-scrape to start-of-scrape.
///
/// Deliberately NOT cAdvisor's own 1s housekeeping interval: polling exactly
/// in step with it would alias, re-reading the same counter every time. This
/// keeps the ~1.045s effective period the rate maths was characterised against
/// (see `Sample.cadvisor_ms`), while no longer letting it drift with whatever a
/// scrape happens to cost.
pub const poll_period_ns: u64 = 1_050 * std.time.ns_per_ms;

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
    identity_error: std.atomic.Value(bool) = .init(false),
    scrape_failures: u32 = 0,
    /// cAdvisor was reachable and reported our container at least once. If this
    /// stays false the run produced no CPU/memory data at all, which the report
    /// must show as absent rather than as zero.
    ever_found: bool = false,

    pub fn run(self: *Poller) void {
        // A counter needs two points to become a rate, and the first scrape
        // lands mid-startup, so it is dropped.
        var first = true;

        while (!self.stop.load(.monotonic)) {
            const now = Io.Timestamp.now(self.io, .awake);
            const t = @as(f64, @floatFromInt(self.t0.durationTo(now).nanoseconds)) / std.time.ns_per_s;

            if (scrape(self.gpa, self.io, self.addr, self.proxy, scrape_deadline_ns)) |obs| {
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

            // Sleep the REMAINDER of the period, not a flat second. The period
            // used to be "one second plus however long a scrape took", so the
            // sampling cadence moved with the cost of parsing an exposition:
            // switching to `http.fetch` slowed a scrape by ~80 ms and silently
            // cost every ramp two of its 28 samples. Sampling rate is a
            // property of the measurement, not of the HTTP client underneath
            // it.
            const spent = now.durationTo(Io.Timestamp.now(self.io, .awake)).nanoseconds;
            const remaining = poll_period_ns -| @as(u64, @intCast(@max(spent, 0)));
            self.io.sleep(.fromNanoseconds(remaining), .awake) catch break;
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
    // actually waiting out a long timeout.
    const addr = try net.IpAddress.parse("127.0.0.1", 1);
    const found = waitUntilFound(
        std.testing.allocator,
        io,
        addr,
        "zoxy",
        300 * std.time.ns_per_ms,
        scrape_deadline_ns,
    );
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

test "a series split across chunk boundaries is still read" {
    // The bug this pins: `scrape` used to read the body itself with no chunk
    // decoder, so a hex chunk-size line was spliced into whatever metric line
    // straddled each 2 KiB boundary. Against cAdvisor v0.52.1 that destroyed
    // 11 of 78 CPU series per scrape, and the series lost stayed lost as long
    // as the exposition's byte layout held — which read from outside as
    // "cAdvisor never reported this container".
    //
    // The series below is deliberately split ACROSS two chunks, at a point
    // inside its own label set. Decoded, it is one line; read raw, it is two
    // fragments with "1d" between them and parses as nothing.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const listen_addr = try net.IpAddress.parse("127.0.0.1", 0);
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    // Port 0 plus getsockname: `listen` resolves the bound address, so this
    // needs no fixed port to collide on.
    const bound = server.socket.address;

    const Serve = struct {
        fn run(srv: *net.Server, sio: Io) void {
            var stream = srv.accept(sio) catch return;
            defer stream.close(sio);
            var wbuf: [1024]u8 = undefined;
            var w = stream.writer(sio, &wbuf);
            const part1 = "container_cpu_usage_seconds_total{cpu=\"total\",na";
            const part2 = "me=\"zoxy\"} 0.5 1785556717668\n";
            // Chunk sizes are computed, not hand-written in hex, so editing
            // either half cannot silently desynchronise the framing.
            w.interface.print(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Type: text/plain\r\n" ++
                    "Transfer-Encoding: chunked\r\n\r\n" ++
                    "{x}\r\n{s}\r\n{x}\r\n{s}\r\n0\r\n\r\n",
                .{ part1.len, part1, part2.len, part2 },
            ) catch return;
            w.interface.flush() catch return;
        }
    };

    var group: Io.Group = .init;
    defer group.cancel(io);
    group.async(io, Serve.run, .{ &server, io });

    // Chunked framing is std.http.Client's job now, so a chunked response is
    // simply decoded. What this pins is that the streaming sink sees the
    // DECODED body: the series below is split across two chunks, and the old
    // hand-rolled reader would have found a hex marker in the middle of it.
    const obs = try scrape(std.testing.allocator, io, bound, "zoxy", 5 * std.time.ns_per_s);
    try std.testing.expect(obs.found);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), obs.cpu_seconds_total, 1e-9);
}

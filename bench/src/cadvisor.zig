//! Polls the proxy host's cAdvisor at 1Hz for the container under test.
//!
//! Records raw counters plus cAdvisor's own timestamp; rates are computed in
//! the report (see `Sample.cadvisor_ms`). Also an identity witness: cAdvisor's
//! `name` label catches a leftover container answering :8080 for the wrong
//! proxy, which a probe cannot.

const std = @import("std");
const http = @import("http.zig");
const zurl = @import("zurl");
const Io = std.Io;
const net = std.Io.net;

const Allocator = std.mem.Allocator;

pub const Sample = struct {
    /// Seconds since the ramp's t0.
    t: f64,
    cpu_seconds_total: f64,
    mem_ws: u64,
    /// cAdvisor's own timestamp for this counter (ms since epoch), or 0 if absent.
    /// The rate must divide by this span, not the poll clock: the counter advances
    /// on housekeeping ticks, so poll-clock rates read 0 then ~2x (e.g. a 1-CPU
    /// haproxy charted at 1.40). A stale re-read is a zero span, skipped.
    cadvisor_ms: i64 = 0,
};

pub const Error = error{
    /// cAdvisor reported a container the ramp did not ask for, or none at all.
    /// Usually a leftover container holding host port 8080.
    IdentityMismatch,
};

/// Names the suite may run. No OTHER member may have a live container while
/// one proxy is measured.
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
/// Streams line by line (never accumulates the ~2 MB body). Must go through
/// `http.fetch`: hand-parsing the chunked body corrupted series at chunk
/// boundaries.
pub fn scrape(
    gpa: Allocator,
    io: Io,
    addr: net.IpAddress,
    proxy: []const u8,
    deadline_ns: u64,
) !Observation {
    // `{f}` gives `host:port`, valid for IPv4 only (IPv6 needs brackets).
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://{f}/metrics", .{addr});

    var ctx: ScrapeCtx = .{ .proxy = proxy };
    // 64 KiB measured no faster against a ~2 MB exposition.
    var stack_buf: [4096]u8 = undefined;
    const buf = &stack_buf;
    // One metric line's worth; a longer line is dropped whole, not truncated.
    const carry = try gpa.alloc(u8, 16 * 1024);
    defer gpa.free(carry);

    var sink = zurl.LineSink.init(buf, carry, &ctx, ScrapeCtx.onLine);
    const res = try http.fetch(gpa, io, .{
        .url = url,
        .sink = .{ .lines = &sink },
        .deadline_ns = deadline_ns,
        .what = "cadvisor scrape",
    }) orelse return error.ScrapeTimedOut;
    if (!res.ok()) return error.ScrapeStatus;

    ctx.obs.found = ctx.seen_expected > 0;
    return ctx.obs;
}

/// Parse state for one scrape. `onLine` slices are valid only for that call,
/// so `intruder` holds a `known_proxies` entry.
const ScrapeCtx = struct {
    proxy: []const u8,
    obs: Observation = .{},
    seen_expected: usize = 0,

    // zurl's LineSink allows a null context; this one always passes itself.
    fn onLine(raw: ?*anyopaque, line: []const u8) void {
        const self: *ScrapeCtx = @ptrCast(@alignCast(raw.?));
        if (parseMetric(line, "container_cpu_usage_seconds_total")) |m| {
            if (nameLabel(m.labels)) |n| {
                if (std.mem.eql(u8, n, self.proxy)) {
                    // One series per cgroup level; the named one is the container.
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

/// The `known_proxies` entry equal to `name`, or null. Returns the static
/// entry: `name` points into a per-scrape buffer and would dangle.
fn matchKnownProxy(name: []const u8) ?[]const u8 {
    for (known_proxies) |p| {
        if (std.mem.eql(u8, name, p)) return p;
    }
    return null;
}

const Metric = struct { labels: []const u8, value: f64, timestamp_ms: ?i64 = null };

/// Match `<name>{<labels>} <value> [<timestamp_ms>]`. The timestamp is the
/// CPU rate's clock; see `Sample.cadvisor_ms`.
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
/// elapses. Best-effort: a missing cAdvisor should cost the CPU/mem chart, not
/// the throughput measurement. cAdvisor discovers containers asynchronously.
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

/// Bounds a single scrape end to end (connect, headers, body); `http.fetch`
/// cancels the whole request, so a black-holed peer costs seconds.
pub const scrape_deadline_ns: u64 = 5 * std.time.ns_per_s;

/// One sampling period, start-of-scrape to start-of-scrape. Not 1s: polling
/// in step with cAdvisor's housekeeping would alias. Matches the ~1.045s the
/// rate maths was characterised against.
pub const poll_period_ns: u64 = 1_050 * std.time.ns_per_ms;

/// Samples one container for the length of a ramp, appending to `out`.
/// Scrape failures are counted and retried, never abort the run. Identity
/// violations set `identity_error`: the throughput belongs to the wrong proxy.
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
    /// cAdvisor reported our container at least once. If false, the report must
    /// show CPU/memory as absent, not zero.
    ever_found: bool = false,

    pub fn run(self: *Poller) void {
        // The first scrape lands mid-startup, so it is dropped.
        var first = true;

        while (!self.stop.load(.monotonic)) {
            const now = Io.Timestamp.now(self.io, .awake);
            const t = @as(f64, @floatFromInt(self.t0.durationTo(now).nanoseconds)) / std.time.ns_per_s;

            if (scrape(self.gpa, self.io, self.addr, self.proxy, scrape_deadline_ns)) |obs| {
                if (obs.intruder) |other| {
                    // Another proxy's container is live: the measurement is void.
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

            // Sleep the remainder of the period, so scrape cost doesn't shift cadence.
            const spent = now.durationTo(Io.Timestamp.now(self.io, .awake)).nanoseconds;
            const remaining = poll_period_ns -| @as(u64, @intCast(@max(spent, 0)));
            self.io.sleep(.fromNanoseconds(remaining), .awake) catch break;
        }
    }
};

pub const CorePoint = struct { t: f64, cores: f64 };

/// Seconds between two samples on the clock the counter advances on, or null
/// for a zero span. Uses cAdvisor's timestamp when present, else the poll clock
/// (older artifacts).
pub fn rateSpanSeconds(prev: Sample, s: Sample) ?f64 {
    if (prev.cadvisor_ms > 0 and s.cadvisor_ms > 0) {
        const ms = s.cadvisor_ms - prev.cadvisor_ms;
        return if (ms > 0) @as(f64, @floatFromInt(ms)) / 1000.0 else null;
    }
    const dt = s.t - prev.t;
    return if (dt > 0) dt else null;
}

/// The poller's measured effective period, which beats against cAdvisor's
/// housekeeping.
pub const poll_period_s = 1.045;

/// Housekeeping intervals (ms) measured from cAdvisor v0.52.1 with the
/// harness's flags. Kept unclean on purpose: the jitter is what biased the old
/// poll-clock rate upward (~1.4x).
pub const observed_housekeeping_ms = [_]i64{ 1220, 1379, 1994, 1044, 1289, 1761, 1605, 1329 };

/// Test support: samples for a container pinned at `cores`, with the counter
/// advancing on the housekeeping ticks above and polled every `poll_period_s`.
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

/// Convert raw counter samples into (elapsed, cores). `t` stays the ramp clock
/// (the offered axis); the rate's span comes from `rateSpanSeconds`.
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
    // No trailing timestamp, and none must be invented.
    try std.testing.expect(m.timestamp_ms == null);
}

test "parseMetric captures the trailing timestamp and rejects other metrics" {
    const line = "container_memory_working_set_bytes{name=\"haproxy\"} 41893888 1753699200000\n";
    const m = parseMetric(line, "container_memory_working_set_bytes").?;
    try std.testing.expectApproxEqAbs(@as(f64, 41893888), m.value, 1e-6);
    // The timestamp must survive parsing: it is the rate's denominator.
    try std.testing.expectEqual(@as(i64, 1753699200000), m.timestamp_ms.?);
    try std.testing.expect(parseMetric(line, "container_cpu_usage_seconds_total") == null);
    // A HELP/TYPE comment must not parse as a sample.
    try std.testing.expect(parseMetric("# TYPE container_cpu_usage_seconds_total counter", "container_cpu_usage_seconds_total") == null);
}

test "scrape reads the counter and cAdvisor's timestamp off a real exposition line" {
    // Verbatim from cAdvisor v0.52.1 with the harness's flags (percpu disabled:
    // one cpu="total" series per container).
    const line = "container_cpu_usage_seconds_total{cpu=\"total\",id=\"/system.slice/docker-5e369d.scope\",image=\"gcr.io/cadvisor/cadvisor:v0.52.1\",name=\"zoxy\"} 0.153726 1785556717668\n";
    const m = parseMetric(line, "container_cpu_usage_seconds_total").?;
    try std.testing.expectEqualStrings("zoxy", nameLabel(m.labels).?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.153726), m.value, 1e-9);
    try std.testing.expectEqual(@as(i64, 1785556717668), m.timestamp_ms.?);
}

test "matchKnownProxy returns the static entry, not the caller's slice" {
    // Must return `known_proxies[i]`, never `name`, or `intruder` dangles.
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
    // Cgroup-level series have no name label and must be ignored.
    try std.testing.expect(nameLabel("id=\"/docker\"") == null);
}

test "nameLabel is not fooled by a label whose name is a suffix of 'name'" {
    // `image` and `container_name` must not be mistaken for `name`.
    try std.testing.expectEqualStrings("zoxy", nameLabel("container_name=\"other\",name=\"zoxy\"").?);
}

test "toCores differentiates the counter and drops the first sample" {
    const gpa = std.testing.allocator;
    // No cadvisor_ms (older artifacts): falls back to the poll clock.
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
    // Real numbers from results/repro-2 (haproxy, c1k): poll 2 re-reads poll 1's
    // counter, poll 3 carries two housekeeping intervals.
    const samples = [_]Sample{
        .{ .t = 103.447, .cpu_seconds_total = 0.504315, .mem_ws = 100, .cadvisor_ms = 1785556730096 },
        .{ .t = 104.489, .cpu_seconds_total = 0.504315, .mem_ws = 100, .cadvisor_ms = 1785556730096 },
        .{ .t = 105.531, .cpu_seconds_total = 0.593284, .mem_ws = 100, .cadvisor_ms = 1785556732090 },
    };
    const pts = try toCores(gpa, &samples);
    defer gpa.free(pts);

    // The duplicate is zero span, not 0 cores.
    try std.testing.expectEqual(@as(usize, 1), pts.len);
    // 0.088969 CPU-seconds over cAdvisor's own 1.994s span.
    try std.testing.expectApproxEqAbs(@as(f64, 0.04462), pts[0].cores, 1e-5);
    // Poll-clock division inflated this ~1.9x.
    const buggy = 0.088969 / 1.042;
    try std.testing.expect(buggy / pts[0].cores > 1.85);
    // `t` stays the ramp clock.
    try std.testing.expectApproxEqAbs(@as(f64, 105.531), pts[0].t, 1e-9);
}

test "toCores never charts a capped container above its cap" {
    const gpa = std.testing.allocator;
    // cpuset "0": anything above 1.0 is the instrument lying.
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
    // Guards the guard: the old poll-clock arithmetic must still fail on
    // `peggedSamples`, or the tests above test nothing.
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
    // Stale re-reads drag the raw mean down.
    try std.testing.expect(sum / @as(f64, @floatFromInt(n)) > 0.9);
}

test "waitUntilFound gives up after its bound against an address nothing answers on" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Closed local port: connect() is refused immediately.
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
    // A missing entry makes a leftover container invisible to the preflight
    // sweep and the identity witness.
    try std.testing.expect(isKnownProxy("envoy"));
    try std.testing.expect(isKnownProxy("nginx"));
    // `direct` is no longer compared and never had a container.
    try std.testing.expect(!isKnownProxy("direct"));
    try std.testing.expect(!isKnownProxy("cadvisor"));
}

test "a series split across chunk boundaries is still read" {
    // Split one series across two chunks inside its label set: only a decoded
    // body parses it.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const listen_addr = try net.IpAddress.parse("127.0.0.1", 0);
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    // Port 0: no fixed port to collide on.
    const bound = server.socket.address;

    const Serve = struct {
        fn run(srv: *net.Server, sio: Io) void {
            var stream = srv.accept(sio) catch return;
            defer stream.close(sio);
            var wbuf: [1024]u8 = undefined;
            var w = stream.writer(sio, &wbuf);
            const part1 = "container_cpu_usage_seconds_total{cpu=\"total\",na";
            const part2 = "me=\"zoxy\"} 0.5 1785556717668\n";
            // Computed chunk sizes, so editing a half cannot desync the framing.
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

    const obs = try scrape(std.testing.allocator, io, bound, "zoxy", 5 * std.time.ns_per_s);
    try std.testing.expect(obs.found);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), obs.cpu_seconds_total, 1e-9);
}

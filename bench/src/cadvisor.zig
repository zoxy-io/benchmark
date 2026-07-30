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
//! cores and smoothing it is a report concern (analysis/report), so the sampling
//! policy and the presentation policy stay independently reviewable.
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
    "zoxy", "haproxy", "pingora", "envoy",
};

pub const Observation = struct {
    /// Whether the expected container was present exactly once.
    found: bool = false,
    /// Any OTHER known proxy container seen in the same scrape.
    intruder: ?[]const u8 = null,
    cpu_seconds_total: f64 = 0,
    mem_ws: u64 = 0,
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
) !Observation {
    // No connect timeout: Io.Threaded panics on one, and a scrape that stalls
    // costs a sample rather than the run — the poller retries every second and
    // records the failure count.
    var stream = try addr.connect(io, .{ .mode = .stream });
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

const Metric = struct { labels: []const u8, value: f64 };

/// Match `<name>{<labels>} <value>` and return the label set and value.
fn parseMetric(line: []const u8, name: []const u8) ?Metric {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, name)) return null;
    if (trimmed.len <= name.len or trimmed[name.len] != '{') return null;

    const close = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return null;
    const labels = trimmed[name.len + 1 .. close];

    var rest = std.mem.trim(u8, trimmed[close + 1 ..], " \t");
    // Prometheus text format allows an optional trailing timestamp.
    if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| rest = rest[0..sp];
    const value = std.fmt.parseFloat(f64, rest) catch return null;

    return .{ .labels = labels, .value = value };
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
pub fn waitUntilFound(io: Io, addr: net.IpAddress, proxy: []const u8, timeout_ns: u64) bool {
    const started = Io.Timestamp.now(io, .awake);
    while (true) {
        if (scrape(io, addr, proxy, null)) |obs| {
            if (obs.found) return true;
        } else |_| {}
        if (started.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds >= timeout_ns) return false;
        io.sleep(.fromNanoseconds(std.time.ns_per_s), .awake) catch return false;
    }
}

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

            if (scrape(self.io, self.addr, self.proxy, &self.active_fd)) |obs| {
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

/// Convert raw counter samples into (elapsed, cores). The report maps elapsed
/// onto the offered axis analytically, and applies its own smoothing.
pub fn toCores(gpa: Allocator, samples: []const Sample) ![]CorePoint {
    const Pt = CorePoint;
    if (samples.len < 2) return &.{};
    const out = try gpa.alloc(Pt, samples.len - 1);
    for (samples[1..], 0..) |s, i| {
        const prev = samples[i];
        const dt = s.t - prev.t;
        out[i] = .{
            .t = s.t,
            .cores = if (dt > 0) (s.cpu_seconds_total - prev.cpu_seconds_total) / dt else 0,
        };
    }
    return out;
}

test "parseMetric pulls the value out of a cAdvisor line" {
    const line = "container_cpu_usage_seconds_total{id=\"/docker/3f2a\",name=\"zoxy\"} 9.73142\n";
    const m = parseMetric(line, "container_cpu_usage_seconds_total").?;
    try std.testing.expectApproxEqAbs(@as(f64, 9.73142), m.value, 1e-9);
    try std.testing.expectEqualStrings("zoxy", nameLabel(m.labels).?);
}

test "parseMetric tolerates a trailing timestamp and rejects other metrics" {
    const line = "container_memory_working_set_bytes{name=\"haproxy\"} 41893888 1753699200000\n";
    const m = parseMetric(line, "container_memory_working_set_bytes").?;
    try std.testing.expectApproxEqAbs(@as(f64, 41893888), m.value, 1e-6);
    try std.testing.expect(parseMetric(line, "container_cpu_usage_seconds_total") == null);
    // A HELP/TYPE comment must not parse as a sample.
    try std.testing.expect(parseMetric("# TYPE container_cpu_usage_seconds_total counter", "container_cpu_usage_seconds_total") == null);
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

    try std.testing.expect(matchKnownProxy("nginx") == null);
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

test "waitUntilFound gives up after its bound against an address nothing answers on" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A closed local port: connect() fails immediately (ECONNREFUSED), so
    // this exercises the "never found, must eventually give up" path without
    // actually waiting out a long timeout.
    const addr = try net.IpAddress.parse("127.0.0.1", 1);
    const found = waitUntilFound(io, addr, "zoxy", 300 * std.time.ns_per_ms);
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
    // `direct` has no container at all — it must never be treated as an
    // intruder, or every direct baseline would fail its identity check.
    try std.testing.expect(!isKnownProxy("direct"));
    try std.testing.expect(!isKnownProxy("cadvisor"));
}

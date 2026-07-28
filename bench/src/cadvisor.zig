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
    "zoxy", "haproxy", "envoy", "traefik", "nginx", "pingora",
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
    scratch: []u8,
) !Observation {
    var stream = try addr.connect(io, .{});
    defer stream.close(io);

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
        _ = scratch;

        if (parseMetric(line, "container_cpu_usage_seconds_total")) |m| {
            if (nameLabel(m.labels)) |n| {
                if (std.mem.eql(u8, n, proxy)) {
                    // cAdvisor emits one series per cgroup hierarchy level; the
                    // named one is the container itself.
                    obs.cpu_seconds_total += m.value;
                    seen_expected += 1;
                } else if (isKnownProxy(n)) {
                    obs.intruder = n;
                }
            }
        } else if (parseMetric(line, "container_memory_working_set_bytes")) |m| {
            if (nameLabel(m.labels)) |n| {
                if (std.mem.eql(u8, n, proxy)) {
                    obs.mem_ws = @max(obs.mem_ws, @as(u64, @intFromFloat(m.value)));
                } else if (isKnownProxy(n)) {
                    obs.intruder = n;
                }
            }
        }
    }

    obs.found = seen_expected > 0;
    return obs;
}

fn isKnownProxy(name: []const u8) bool {
    for (known_proxies) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    return false;
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
        var scratch: [4096]u8 = undefined;
        // A counter needs two points to become a rate, and the first scrape
        // lands mid-startup, so it is dropped.
        var first = true;

        while (!self.stop.load(.monotonic)) {
            const now = Io.Timestamp.now(self.io, .awake);
            const t = @as(f64, @floatFromInt(self.t0.durationTo(now).nanoseconds)) / std.time.ns_per_s;

            if (scrape(self.io, self.addr, self.proxy, &scratch)) |obs| {
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

            self.io.sleep(.fromNanos(std.time.ns_per_s), .awake) catch break;
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

test "isKnownProxy covers the comparison set" {
    try std.testing.expect(isKnownProxy("zoxy"));
    try std.testing.expect(isKnownProxy("pingora"));
    // `direct` has no container at all — it must never be treated as an
    // intruder, or every direct baseline would fail its identity check.
    try std.testing.expect(!isKnownProxy("direct"));
    try std.testing.expect(!isKnownProxy("cadvisor"));
}

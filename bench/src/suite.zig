//! Drives every proxy through one profile's ramp, on the loadgen VM.
//!
//! The whole point of this module is that ONE PROXY'S FAILURE CANNOT REACH
//! ANOTHER. The bash driver it replaces ran under `set -euo pipefail` with no
//! trap, so a proxy that failed to build (`docker compose up --build --wait`) or
//! never answered its warm probe (an explicit `exit 1`) took every remaining
//! proxy with it — and left its container running, holding the shared host port
//! 8080 and cpuset 0. Overnight that turns a single flaky build into a night
//! with no data at all.
//!
//! So: `runOne` is the only place an error is caught, it catches everything, and
//! the record is written to disk immediately after each proxy rather than at the
//! end. A suite that dies halfway still leaves every completed proxy's result
//! intact and correctly labelled.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const artifact = @import("artifact.zig");
const cadvisor = @import("cadvisor.zig");
const profile = @import("profile.zig");
const ramp = @import("ramp.zig");
const redact = @import("redact.zig");
const remote = @import("remote.zig");

const Allocator = std.mem.Allocator;

pub const Fleet = struct {
    proxy_ip: []const u8,
    backend_ip: []const u8,
    /// null selects LOCAL mode: compose runs against this machine's docker
    /// daemon and both peers are loopback. The numbers a local run produces are
    /// NOT comparable to a fleet run — the generator shares CPU, cache and
    /// memory bandwidth with the proxy it is measuring, and the network the
    /// fleet crosses is replaced by loopback, which removes a ceiling the cloud
    /// `direct` baseline demonstrably sits near. Local mode is for working on
    /// the harness, not for producing results; everything downstream is
    /// labelled so a local run cannot be mistaken for a nightly.
    ssh: ?remote.Ssh,
    /// Directory holding the payload — `~/bench` on a fleet VM, the repo root
    /// locally.
    remote_dir: []const u8 = "bench",

    pub fn isLocal(self: Fleet) bool {
        return self.ssh == null;
    }

    fn host(self: Fleet, addr: []const u8) remote.Host {
        const ssh = self.ssh orelse return .local;
        return .{ .remote = .{ .ssh = ssh, .addr = addr } };
    }

    pub fn proxyHost(self: Fleet) remote.Host {
        return self.host(self.proxy_ip);
    }

    pub fn backendHost(self: Fleet) remote.Host {
        return self.host(self.backend_ip);
    }

    /// Locally the base compose file IS the local configuration — bridge
    /// networking, published ports, docker DNS for `backend`. The cloud overlay
    /// is what swaps in host networking and peer IP literals, so it must not be
    /// applied here.
    pub fn composeCmd(self: Fleet) []const u8 {
        return if (self.isLocal())
            "docker compose -f compose.yaml"
        else
            "docker compose -f compose.yaml -f compose.cloud.yaml";
    }
};

pub const Options = struct {
    prof: profile.Profile,
    proxies: []const []const u8,
    fleet: Fleet,
    runid: []const u8,
    /// Where this profile's artifacts are written.
    out_dir: []const u8,
};

/// Deadlines. Every one of these was unbounded in the bash driver.
const deadline = struct {
    const backend_up: u64 = 180 * std.time.ns_per_s;
    const build: u64 = 900 * std.time.ns_per_s;
    const start: u64 = 120 * std.time.ns_per_s;
    const probe_each: u64 = 10 * std.time.ns_per_s;
    const teardown: u64 = 90 * std.time.ns_per_s;
    const inspect: u64 = 30 * std.time.ns_per_s;
};

const warm_probe_attempts = 30;
const warm_probe_interval_ns = 2 * std.time.ns_per_s;
/// Bounds the probe LOOP, because a single connect cannot be bounded:
/// `Io.Threaded` panics outright on `netConnectIp` with a timeout ("TODO
/// implement netConnectIpPosix with timeout"), so the per-attempt timeout has to
/// be `.none` and a black-holed peer costs the OS SYN timeout — minutes, not
/// seconds. Counting attempts alone would then let a wedged host hold the suite
/// for the better part of an hour.
const warm_probe_deadline_ns = 90 * std.time.ns_per_s;

pub const Result = struct {
    records: []artifact.ProxyRecord,
    /// Set when the fleet was left in a state where later numbers could not be
    /// trusted, so the caller stops rather than producing suspect data.
    aborted: bool = false,
};

pub fn run(gpa: Allocator, arena: Allocator, io: Io, opts: Options) !Result {
    const p = opts.prof;
    try p.validate();

    var records: std.ArrayList(artifact.ProxyRecord) = .empty;
    const started = try nowIso(io, arena);

    // Flush the record after every proxy, so a crash cannot lose the ones that
    // already finished.
    var flush = Flusher{
        .gpa = gpa,
        .io = io,
        .dir = opts.out_dir,
        .prof = p,
        .origin = if (opts.fleet.isLocal()) .local else .cloud,
        .runid = opts.runid,
        .started = started,
        .records = &records,
    };

    // --- preflight: the proxy host must be clean before anything is measured.
    //
    // A leftover container from a previous run holds host port 8080 and answers
    // probes correctly, so a later ramp would be attributed to the wrong proxy
    // and nothing downstream could tell. Sweep first, unconditionally.
    sweepProxyHost(gpa, arena, io, opts.fleet) catch |e| {
        redact.log("bench: preflight sweep failed: {s}", .{@errorName(e)});
        for (opts.proxies) |name| {
            try records.append(arena, .{
                .name = name,
                .status = .skipped,
                .stage = .identity,
                .err = "proxy host could not be cleaned before the run",
            });
        }
        try flush.write();
        return .{ .records = try records.toOwnedSlice(arena), .aborted = true };
    };

    // --- cAdvisor: the measurement's CPU/memory source and its identity witness.
    //
    // It must be started EXPLICITLY. `compose --profile <p> up -d --wait <p>`
    // names the service, so compose starts that service alone — cAdvisor sits in
    // every proxy's profile but is never brought up by it. The bash driver had a
    // separate step for this; dropping it cost a whole cloud run its CPU and
    // memory data, and every proxy came back `degraded` for want of samples.
    //
    // Not fatal: throughput and latency are still sound without it, and the
    // per-proxy `degraded` status already says the metrics are absent rather
    // than zero.
    _ = remote.check(
        gpa,
        arena,
        io,
        opts.fleet.proxyHost(),
        "cadvisor up",
        try std.fmt.allocPrint(arena, "cd {s} && {s} --profile monitoring up -d --wait cadvisor", .{
            opts.fleet.remote_dir, opts.fleet.composeCmd(),
        }),
        deadline.start,
    ) catch |e| {
        redact.log("bench: cAdvisor did not start ({s}); CPU and memory will be absent", .{@errorName(e)});
    };

    // --- backend: the origin every proxy forwards to.
    //
    // The bash driver tolerated a backend failure with `|| true` and then died
    // 25s later on the first proxy's warm probe, because `curl -sf` fails on the
    // 502 a proxy returns with a dead origin. That bought nothing except moving
    // the diagnosis away from the cause.
    _ = remote.check(
        gpa,
        arena,
        io,
        opts.fleet.backendHost(),
        "backend up",
        try std.fmt.allocPrint(arena, "cd {s} && {s} --profile backend up -d --wait", .{
            opts.fleet.remote_dir, opts.fleet.composeCmd(),
        }),
        deadline.backend_up,
    ) catch |e| {
        redact.log("bench: backend never came up: {s}", .{@errorName(e)});
        for (opts.proxies) |name| {
            try records.append(arena, .{
                .name = name,
                .status = .skipped,
                .stage = .start,
                .err = "backend origin never came up",
            });
        }
        try flush.write();
        return .{ .records = try records.toOwnedSlice(arena), .aborted = true };
    };

    // --- build every proxy BEFORE any measurement.
    //
    // The bash driver built each proxy inside the measurement loop, so zoxy's
    // source build (a git clone plus a zig ReleaseFast compile) burned the
    // SUT's own CPU minutes before its ramp, and could still be flushing page
    // cache during the previous proxy's cooldown. Building everything up front
    // costs the same wall clock and removes that coupling. A build failure marks
    // just that proxy and the others proceed.
    var build_failed: std.StringHashMapUnmanaged(void) = .empty;
    for (opts.proxies) |name| {
        if (isDirect(name)) continue;
        _ = remote.check(
            gpa,
            arena,
            io,
            opts.fleet.proxyHost(),
            try std.fmt.allocPrint(arena, "build {s}", .{name}),
            try std.fmt.allocPrint(arena, "cd {s} && {s} {s} --profile {s} build {s}", .{
                opts.fleet.remote_dir, envPrefix(arena, p, opts.fleet) catch "", opts.fleet.composeCmd(), name, name,
            }),
            deadline.build,
        ) catch {
            try build_failed.put(arena, name, {});
        };
    }

    // --- the measurement loop.
    for (opts.proxies) |name| {
        if (build_failed.contains(name)) {
            try records.append(arena, .{
                .name = name,
                .status = .failed,
                .stage = .build,
                .err = "image build failed",
            });
            try flush.write();
            continue;
        }

        var stage: artifact.Stage = .start;
        const rec = runOne(gpa, arena, io, opts, name, &stage) catch |e| blk: {
            redact.log("bench: [{s}] {s} at stage {s}", .{ name, @errorName(e), stage.str() });
            break :blk artifact.ProxyRecord{
                .name = name,
                .status = .failed,
                .stage = stage,
                .err = @errorName(e),
            };
        };
        try records.append(arena, rec);
        try flush.write();

        // Always tear down, whatever happened. Best-effort: a failure here is
        // reported by the NEXT proxy's identity check rather than silently
        // corrupting it.
        teardownProxy(gpa, arena, io, opts.fleet, name) catch |e| {
            redact.log("bench: [{s}] teardown failed: {s}", .{ name, @errorName(e) });
        };

        io.sleep(.fromNanoseconds(p.cooldown_s * std.time.ns_per_s), .awake) catch {};
    }

    flush.finished = try nowIso(io, arena);
    try flush.write();

    return .{ .records = try records.toOwnedSlice(arena) };
}

/// One proxy, start to finish. Every failure path returns an error, which the
/// caller turns into a `failed` record — this function never decides to skip
/// another proxy or to stop the suite.
fn runOne(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    name: []const u8,
    stage: *artifact.Stage,
) !artifact.ProxyRecord {
    const p = opts.prof;
    const direct = isDirect(name);

    var notes: std.ArrayList([]const u8) = .empty;
    var zoxy_commit: ?[]const u8 = null;
    var build_info: ?[]const u8 = null;

    const target = if (direct)
        try std.fmt.allocPrint(arena, "http://{s}:9000{s}", .{ opts.fleet.backend_ip, p.req_path })
    else
        try std.fmt.allocPrint(arena, "http://{s}:8080{s}", .{ opts.fleet.proxy_ip, p.req_path });

    if (!direct) {
        stage.* = .start;
        _ = try remote.check(
            gpa,
            arena,
            io,
            opts.fleet.proxyHost(),
            try std.fmt.allocPrint(arena, "start {s}", .{name}),
            try std.fmt.allocPrint(arena, "cd {s} && {s} {s} --profile {s} up -d --wait {s}", .{
                opts.fleet.remote_dir, try envPrefix(arena, p, opts.fleet), opts.fleet.composeCmd(), name, name,
            }),
            deadline.start,
        );

        stage.* = .identity;
        // Assert exactly this proxy is running before believing anything that
        // answers :8080. `compose up --wait` only gates on the container being
        // up, and with a healthcheck it gates on that container being healthy —
        // neither rules out a second, leftover container also bound to the port.
        try assertOnlyProxy(gpa, arena, io, opts.fleet, name);

        // How this image was compiled. Every proxy that records it gets read;
        // a mismatch in target CPU across proxies is a fairness violation that
        // is otherwise invisible in the numbers.
        if (remote.check(
            gpa,
            arena,
            io,
            opts.fleet.proxyHost(),
            "build info",
            try std.fmt.allocPrint(arena, "docker exec {s} cat /etc/{s}/build-info", .{ name, name }),
            deadline.inspect,
        )) |res| {
            const info = std.mem.trim(u8, res.stdout, " \n\r\t");
            if (info.len > 0) {
                build_info = info;
                // Every proxy targets a generic baseline, matching the stock
                // upstream images in the comparison. A NATIVE build is the
                // anomaly: it would hand that proxy the host's AVX2/AVX-512
                // against others running SSE2.
                if (std.mem.indexOf(u8, info, "NATIVE") != null) {
                    try notes.append(arena, try std.fmt.allocPrint(
                        arena,
                        "built for the host CPU ({s}) — an unfair advantage over the baseline-built proxies",
                        .{info},
                    ));
                }
            }
        } else |_| {
            // No descriptor means a stock upstream image rather than one built
            // here. Those are compiled for a generic x86-64 baseline so they run
            // anywhere, which is a real disadvantage against a proxy built with
            // the host's CPU features — haproxy:3.0-alpine carries zero AVX
            // instructions where zoxy and pingora both get AVX2/AVX-512. Say so
            // rather than leaving the field null and the asymmetry invisible.
            // Matches what the proxies built here target, so this is expected
            // rather than a problem — recorded so the parity is checkable.
            build_info = "stock upstream image (generic x86-64 baseline)";
        }

        if (std.mem.eql(u8, name, "zoxy")) {
            // Record which commit actually ran. The Dockerfile caches its git
            // clone, so a floating ref can silently be an older commit than the
            // one requested; the image records its own resolved HEAD.
            if (remote.check(
                gpa,
                arena,
                io,
                opts.fleet.proxyHost(),
                "zoxy commit",
                "docker exec zoxy cat /etc/zoxy/zoxy-commit",
                deadline.inspect,
            )) |res| {
                // The resolved HEAD of the image that actually ran, not the ref
                // that was requested. With a floating `main` these differ every
                // night by design, and this is the only record of which commit
                // produced tonight's numbers — so a regression on the trend
                // chart can be bisected to a range of zoxy commits.
                zoxy_commit = std.mem.trim(u8, res.stdout, " \n\r\t");
            } else |_| {
                try notes.append(arena, "could not read the running zoxy image's commit");
            }
        }
    }

    stage.* = .warm;
    try warmProbe(io, target, name);

    stage.* = .ramp;
    const start_iso = try nowIso(io, arena);

    const cadvisor_addr: ?net.IpAddress = if (direct) null else try net.IpAddress.parse(opts.fleet.proxy_ip, 8081);

    const out_base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ opts.out_dir, name });
    const outcome = try ramp.run(gpa, arena, .{
        .prof = p,
        .proxy = name,
        .target = target,
        .cadvisor_addr = cadvisor_addr,
        .out_base = out_base,
        .runid = opts.runid,
    });
    const end_iso = try nowIso(io, arena);

    // --- classify.
    //
    // An identity violation voids the measurement outright: cAdvisor saw a
    // different proxy's container live during the ramp, so whatever answered
    // :8080 may not be the proxy this data would be filed under. Reporting it as
    // degraded would still put a wrong number on the chart.
    if (outcome.identity_error) {
        return .{
            .name = name,
            .status = .failed,
            .stage = .identity,
            .err = "another proxy's container was live during the ramp",
            .start = start_iso,
            .end = end_iso,
        };
    }

    var status: artifact.Status = .ok;
    const cov = ramp.coverage(outcome);
    if (outcome.interrupted) {
        if (cov >= ramp.min_coverage) {
            status = .degraded;
            try notes.append(arena, try std.fmt.allocPrint(
                arena,
                "ramp stopped early, covering {d:.0}% of the offered range",
                .{cov * 100},
            ));
        } else {
            return .{
                .name = name,
                .status = .failed,
                .stage = .ramp,
                .err = "ramp stopped before covering enough of the offered range",
                .start = start_iso,
                .end = end_iso,
                .elapsed_s = outcome.elapsed_s,
                .configured_s = outcome.configured_s,
                .interrupted = true,
            };
        }
    }
    if (!direct and outcome.cadvisor_samples == 0) {
        status = .degraded;
        try notes.append(arena, "no cAdvisor samples: CPU and memory are absent, not zero");
    }
    if (outcome.saturated) {
        // Not degraded — the throughput number is still sound. But the tail is
        // the clamp value, and the report must not print it as a measurement.
        try notes.append(arena, "latency histogram saturated at 60s; tail percentiles are a floor, not a value");
    }

    return .{
        .name = name,
        .status = status,
        .start = start_iso,
        .end = end_iso,
        .elapsed_s = outcome.elapsed_s,
        .configured_s = outcome.configured_s,
        .interrupted = outcome.interrupted,
        .launched = outcome.launched,
        .completed = outcome.completed,
        .deadline_errors = outcome.deadline_errors,
        .status_errors = outcome.status_errors,
        .socket_errors = outcome.socket_errors,
        .saturated = outcome.saturated,
        .cadvisor_samples = outcome.cadvisor_samples,
        .zoxy_commit = zoxy_commit,
        .build_info = build_info,
        .notes = try notes.toOwnedSlice(arena),
    };
}

/// Poll the target until it serves. Runs from the loadgen so it exercises the
/// real path, and reports only the proxy name and attempt count — never the
/// target URL, which carries a private address.
fn warmProbe(io: Io, target: []const u8, name: []const u8) !void {
    const url = try std.Uri.parse(target);
    const host = switch (url.host orelse return error.InvalidTarget) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    const addr = try net.IpAddress.parse(host, url.port orelse 80);
    const path = if (url.path.isEmpty()) "/" else switch (url.path) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };

    const started = Io.Timestamp.now(io, .awake);
    var attempt: usize = 0;
    while (attempt < warm_probe_attempts) : (attempt += 1) {
        if (probeOnce(io, addr, path)) |_| return else |_| {}

        const elapsed = started.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        if (elapsed >= warm_probe_deadline_ns) {
            redact.log("bench: [{s}] never served 200 within {d}s", .{ name, warm_probe_deadline_ns / std.time.ns_per_s });
            return error.WarmProbeFailed;
        }
        io.sleep(.fromNanoseconds(warm_probe_interval_ns), .awake) catch {};
    }
    redact.log("bench: [{s}] never served 200 after {d} attempts", .{ name, warm_probe_attempts });
    return error.WarmProbeFailed;
}

fn probeOnce(io: Io, addr: net.IpAddress, path: []const u8) !void {
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print("GET {s} HTTP/1.1\r\nHost: bench\r\nConnection: close\r\n\r\n", .{path});
    try w.interface.flush();

    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const line = try r.interface.takeDelimiterInclusive('\n');
    // Only a 2xx counts. A proxy that is up but whose origin is dead answers
    // 502, and treating that as ready would ramp against an error page.
    if (std.mem.indexOf(u8, line, " 2") == null) return error.NotServing;
}

/// Fail unless `expected` is the only known proxy container running.
fn assertOnlyProxy(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    fleet: Fleet,
    expected: []const u8,
) !void {
    const res = try remote.check(
        gpa,
        arena,
        io,
        fleet.proxyHost(),
        "list containers",
        "docker ps --format '{{.Names}}'",
        deadline.inspect,
    );

    var seen_expected = false;
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |raw| {
        const n = std.mem.trim(u8, raw, " \r\t");
        if (n.len == 0) continue;
        if (std.mem.eql(u8, n, expected)) {
            seen_expected = true;
        } else if (isKnownProxy(n)) {
            redact.log(
                "bench: identity: container \"{s}\" is running while starting \"{s}\"",
                .{ n, expected },
            );
            return error.ForeignProxyRunning;
        }
    }
    if (!seen_expected) return error.ProxyNotRunning;
}

fn isKnownProxy(name: []const u8) bool {
    for (cadvisor.known_proxies) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    return false;
}

/// Remove every known proxy container from the proxy host.
fn sweepProxyHost(gpa: Allocator, arena: Allocator, io: Io, fleet: Fleet) !void {
    var cmd: std.ArrayList(u8) = .empty;
    try cmd.appendSlice(arena, "docker rm -f");
    for (cadvisor.known_proxies) |p| {
        try cmd.append(arena, ' ');
        try cmd.appendSlice(arena, p);
    }
    // `docker rm -f` on an absent container is an error, so tolerate a non-zero
    // exit here — the point is the post-condition, which assertOnlyProxy checks.
    try cmd.appendSlice(arena, " 2>/dev/null; true");

    _ = try remote.check(
        gpa,
        arena,
        io,
        fleet.proxyHost(),
        "sweep proxy host",
        cmd.items,
        deadline.teardown,
    );
}

fn teardownProxy(gpa: Allocator, arena: Allocator, io: Io, fleet: Fleet, name: []const u8) !void {
    if (isDirect(name)) return;
    // Verify the post-condition rather than trusting `stop`: a container that
    // ignores SIGTERM keeps host port 8080 and would answer the NEXT proxy's
    // probe. `docker rm -f` after the graceful attempt makes that impossible.
    const cmd = try std.fmt.allocPrint(
        arena,
        "docker stop -t 10 {s} >/dev/null 2>&1; docker rm -f {s} >/dev/null 2>&1; " ++
            "! docker ps --format '{{{{.Names}}}}' | grep -qx {s}",
        .{ name, name, name },
    );
    _ = try remote.check(
        gpa,
        arena,
        io,
        fleet.proxyHost(),
        try std.fmt.allocPrint(arena, "teardown {s}", .{name}),
        cmd,
        deadline.teardown,
    );
}

/// Environment prefix for a remote `docker compose` invocation.
///
/// Carries BACKEND_IP as well as the profile's proxy tuning. compose.cloud.yaml
/// interpolates it into every proxy's `extra_hosts` (zoxy does no DNS, so the
/// origin must be an address literal) and into pingora's BACKEND_ADDR. Omitting
/// it does not fail loudly — compose substitutes an empty string and each proxy
/// starts with `extra_hosts: "backend:"`, so the failure surfaces much later as
/// a warm probe that never gets a 200.
fn envPrefix(arena: Allocator, p: profile.Profile, fleet: Fleet) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    // Only the cloud overlay interpolates BACKEND_IP; locally the proxies reach
    // the origin by its compose service name over docker DNS.
    if (!fleet.isLocal()) try buf.print(arena, "BACKEND_IP={s} ", .{fleet.backend_ip});
    // Without this, compose falls back to `${ZOXY_REF:-main}` and builds a
    // floating main rather than the pinned commit — see profile.zig's note.
    try buf.print(arena, "ZOXY_REF={s} ", .{profile.zoxy_ref});
    for (p.proxy_env) |kv| {
        try buf.print(arena, "{s}={s} ", .{ kv.key, kv.value });
    }
    return buf.toOwnedSlice(arena);
}

fn isDirect(name: []const u8) bool {
    return std.mem.eql(u8, name, "direct");
}

const Flusher = struct {
    gpa: Allocator,
    io: Io,
    dir: []const u8,
    prof: profile.Profile,
    origin: artifact.Origin,
    runid: []const u8,
    started: []const u8,
    finished: []const u8 = "",
    records: *std.ArrayList(artifact.ProxyRecord),

    fn write(self: *Flusher) !void {
        try artifact.write(self.gpa, self.io, self.dir, .{
            .runid = self.runid,
            .prof = self.prof,
            .origin = self.origin,
            .started = self.started,
            .finished = self.finished,
            .proxies = self.records.items,
        });
    }
};

fn nowIso(io: Io, arena: Allocator) ![]const u8 {
    const ts = Io.Timestamp.now(io, .real);
    const secs = @divFloor(ts.nanoseconds, std.time.ns_per_s);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

test "isKnownProxy excludes direct, which has no container" {
    try std.testing.expect(isKnownProxy("zoxy"));
    try std.testing.expect(!isKnownProxy("direct"));
}

test "envPrefix carries BACKEND_IP as well as the profile's tuning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fleet: Fleet = .{
        .proxy_ip = "10.10.0.12",
        .backend_ip = "10.10.0.13",
        .ssh = .{ .key_path = "k", .known_hosts = "kh" },
    };
    const s = try envPrefix(arena, profile.c10k, fleet);

    // Without this every proxy starts with extra_hosts "backend:" and fails its
    // warm probe much later, with a symptom that does not name the cause.
    try std.testing.expect(std.mem.indexOf(u8, s, "BACKEND_IP=10.10.0.13") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_CONN_SLOTS=11464") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_UPSTREAM_SLOTS=11464") != null);
}

test "nowIso produces a sortable UTC stamp" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const s = try nowIso(threaded.io(), arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 20), s.len);
    try std.testing.expectEqual(@as(u8, 'T'), s[10]);
    try std.testing.expectEqual(@as(u8, 'Z'), s[19]);
}

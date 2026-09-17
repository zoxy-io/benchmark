//! Drives every proxy through one profile's ramp, on the loadgen VM.
//!
//! One proxy's failure must not reach another: `runOne` catches every error,
//! and each record is flushed to disk as soon as its proxy finishes.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const artifact = @import("artifact.zig");
const cadvisor = @import("cadvisor.zig");
const profile = @import("profile.zig");
const ramp = @import("ramp.zig");
const redact = @import("redact.zig");
const remote = @import("remote.zig");
const zio = @import("zio");
const zrk = @import("zrk");

const Allocator = std.mem.Allocator;

pub const Fleet = struct {
    proxy_ip: []const u8,
    /// The origin pool, in terraform's order: index 0 is backend0, so
    /// `BACKENDn_IP` names the same host as terraform's `backendN`.
    backend_ips: []const []const u8,
    /// null selects local mode (local docker, loopback peers). Local numbers
    /// are NOT comparable to a fleet run: the generator shares the proxy's CPU
    /// and loopback removes the network ceiling. For harness work only.
    ssh: ?remote.Ssh,
    /// Payload directory: `~/bench` on a fleet VM, the repo root locally.
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

    pub fn backendHost(self: Fleet, i: usize) remote.Host {
        return self.host(self.backend_ips[i]);
    }

    /// Compose profile for backend `i`. Locally one `backend` profile starts
    /// the whole pool; in cloud each VM must start only its own, or four
    /// containers race for :9000 on one host.
    pub fn backendProfile(self: Fleet, arena: Allocator, i: usize) ![]const u8 {
        return if (self.isLocal())
            "backend"
        else
            std.fmt.allocPrint(arena, "backend{d}", .{i});
    }

    /// Locally the base compose file is the whole config; the cloud overlay
    /// (host networking, peer IPs) must not apply. Result-deciding settings are
    /// passed explicitly (see `envPrefix`), never via a gitignored `.env`.
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

/// Stage deadlines; every remote and in-process step is bounded.
const deadline = struct {
    /// Per pool member, started in sequence. Not in `turn`: runs once before
    /// any turn, and a failure aborts the whole profile.
    const backend_up: u64 = 180 * std.time.ns_per_s;
    const build: u64 = 900 * std.time.ns_per_s;
    /// `build` bounds one attempt. Not counted in `turn`: the build phase
    /// runs before any turn.
    const build_attempts: u32 = 2;
    const build_retry_backoff: u64 = 15 * std.time.ns_per_s;
    const start: u64 = 120 * std.time.ns_per_s;
    /// Retries transient pull/port-bind failures (runs #26, #30). MUST stay
    /// counted in `turn`, or retries re-introduce the run #24 inversion.
    const start_attempts: u32 = 3;
    const start_retry_backoff: u64 = 15 * std.time.ns_per_s;
    const probe_each: u64 = 10 * std.time.ns_per_s;
    const teardown: u64 = 90 * std.time.ns_per_s;
    const inspect: u64 = 30 * std.time.ns_per_s;

    /// Wall-clock bound on the whole warm-probe loop; per-attempt connect
    /// timeouts alone don't bound `warm_probe_attempts` in total.
    const warm_probe: u64 = 90 * std.time.ns_per_s;

    /// Bounds `cadvisor.waitUntilFound`'s pre-ramp poll. Best-effort, but it
    /// runs inside the turn, so it must be counted in `turn`.
    const cadvisor_warm: u64 = 60 * std.time.ns_per_s;

    /// The ramp child, start to exit, including the cAdvisor poller teardown.
    /// In-process work has no other bound (runs #9, #10, #12 hung here).
    fn proxy(ramp_seconds: u64) u64 {
        return (ramp_seconds * 2 + 300) * std.time.ns_per_s;
    }

    /// `ProxyWatchdog`'s window: the sum of every stage bound in a turn plus
    /// grace. Must exceed the longest legitimate turn, or the watchdog (which
    /// ends the process) fires first and one slow proxy costs all the rest
    /// (run #24). Summed so raising any stage bound keeps that true.
    fn turn(ramp_seconds: u64, cooldown_s: u64) u64 {
        return proxy(ramp_seconds) // ramp — the one stage bounded by a kill
        + start_attempts * start + (start_attempts - 1) * start_retry_backoff // container start, with retries
        + warm_probe // first 200
        + cadvisor_warm // cAdvisor discovery head start, before the ramp
        + teardown // after runOne returns, still inside the window
            // Every `inspect`-bounded probe, worst case (zoxy): sockets,
            // identity, build info, commit, version, counters, error log.
            // Recount whenever a probe is added; undercounting is run #24.
        + 7 * inspect
            // Each ssh `check` (7 probes, start attempts, teardown) may also
            // pay `remote`'s transport-retry budget; worst case for all.
        + (7 + start_attempts + 1) * remote.connect_retry_budget_ns + (cooldown_s + 60) * std.time.ns_per_s; // cooldown, plus grace
    }
};

/// Last-resort bound on one proxy's turn, for in-process steps with no deadline
/// of their own (artifact writes, `io.sleep`, a wedged Io). It can only end the
/// process, so `deadline.turn` is sized to lose every race; completed proxies
/// are already flushed. Logs the current stage so a hang names its step (#12).
const ProxyWatchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    limit_ns: u64,
    name: []const u8,
    stage: *artifact.Stage,

    fn watch(self: *ProxyWatchdog) void {
        // Raw nanosleep, not `io.sleep`: must survive a wedged Io loop.
        const tick: std.os.linux.timespec = .{ .sec = 1, .nsec = 0 };
        const tick_ns = std.time.ns_per_s;
        var waited: u64 = 0;
        while (waited < self.limit_ns) : (waited += tick_ns) {
            _ = std.os.linux.nanosleep(&tick, null);
            if (self.done.load(.acquire)) return;
        }
        if (self.done.load(.acquire)) return;
        redact.log(
            "bench: [{s}] stuck at stage {s} for {d}s — aborting so the completed " ++
                "proxies are still uploaded.",
            .{ self.name, self.stage.str(), self.limit_ns / std.time.ns_per_s },
        );
        logSockets();
        std.process.exit(4);
    }

    /// Log the kernel socket census before giving up; `tw` (TIME_WAIT) shows
    /// ephemeral port exhaustion. Read from /proc, not `ss`: spawning a child
    /// could hang too.
    fn logSockets() void {
        var buf: [512]u8 = undefined;
        const fd = std.os.linux.open("/proc/net/sockstat", .{ .ACCMODE = .RDONLY }, 0);
        const signed: isize = @bitCast(fd);
        if (signed < 0) return;
        const handle: i32 = @intCast(fd);
        defer _ = std.os.linux.close(handle);

        const n = std.os.linux.read(handle, &buf, buf.len);
        const got: isize = @bitCast(n);
        if (got <= 0) return;
        const text = buf[0..@intCast(got)];

        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            // "TCP: inuse N orphan N tw N alloc N mem N" — tw is TIME_WAIT.
            if (std.mem.startsWith(u8, line, "TCP:") or std.mem.startsWith(u8, line, "sockets:")) {
                redact.log("bench: sockets: {s}", .{line});
            }
        }
        logEstablished();
    }

    /// Log CurrEstab. `inuse` counts every state: CurrEstab near the offered
    /// connections means a stuck exchange; low CurrEstab with high `inuse`
    /// means CLOSE_WAIT sockets the generator never reaped.
    fn logEstablished() void {
        var buf: [4096]u8 = undefined;
        const fd = std.os.linux.open("/proc/net/snmp", .{ .ACCMODE = .RDONLY }, 0);
        const signed: isize = @bitCast(fd);
        if (signed < 0) return;
        const handle: i32 = @intCast(fd);
        defer _ = std.os.linux.close(handle);

        const n = std.os.linux.read(handle, &buf, buf.len);
        const got: isize = @bitCast(n);
        if (got <= 0) return;

        // First "Tcp:" line names the columns, the second holds the values.
        var col: ?usize = null;
        var lines = std.mem.splitScalar(u8, buf[0..@intCast(got)], '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "Tcp:")) continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            var i: usize = 0;
            while (fields.next()) |f| : (i += 1) {
                if (col) |want| {
                    if (i == want) {
                        redact.log("bench: sockets: TCP CurrEstab {s}", .{f});
                        return;
                    }
                } else if (std.mem.eql(u8, f, "CurrEstab")) {
                    col = i;
                }
            }
        }
    }
};

/// This binary's path. Resolved here, not as `/proc/self/exe` in the command:
/// under `sh -c` that names the shell (exit 127). Keeps the ramp child the same
/// build as the suite.
fn selfExe(arena: Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
    const got: isize = @bitCast(n);
    if (got <= 0) return error.SelfExeUnavailable;
    return arena.dupe(u8, buf[0..@intCast(got)]);
}

/// Must match the `FROM` in proxies/zoxy/Dockerfile. A mismatch fails zoxy's
/// build loudly on a missing image, which is the right way for it to fail.
const zig_toolchain_tag = "zoxy-bench/zig:0.16.0";

/// The cache tag for a proxy whose image is a pure function of this repo, else
/// null. zoxy is excluded: it tracks a moving ref, and a wrongly-keyed cache
/// would silently benchmark a stale binary.
fn cacheableImage(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "pingora")) return "zoxy-bench/pingora-http:0.8";
    return null;
}

/// Shell command asking the RUNNING container its version (what answered, not
/// what compose requested). `head -1`: haproxy appends a blurb; `2>&1`: some
/// print to stderr. Proxies with no version CLI report their image reference.
fn versionProbe(arena: Allocator, name: []const u8) ![]const u8 {
    const asks_itself = [_]struct { proxy: []const u8, argv: []const u8 }{
        .{ .proxy = "haproxy", .argv = "haproxy -v" },
        .{ .proxy = "envoy", .argv = "envoy --version" },
        .{ .proxy = "zoxy", .argv = "zoxy --version" },
    };
    for (asks_itself) |e| {
        if (std.mem.eql(u8, name, e.proxy)) {
            return std.fmt.allocPrint(arena, "docker exec {s} {s} 2>&1 | head -1", .{ name, e.argv });
        }
    }
    return std.fmt.allocPrint(arena, "docker inspect -f '{{{{.Config.Image}}}}' {s} 2>/dev/null", .{name});
}

/// Counters for work zoxy skipped that the other proxies did. Read in ONE
/// scrape: a second probe would need a bump in `deadline.turn`.
const ZoxyCounters = struct {
    /// Access-log lines dropped. zoxy drops (and counts) lines rather than
    /// block its event loop; the others pay for every line, so unmeasured
    /// drops would show up as throughput.
    access_log_dropped: ?u64 = null,

    /// Connections shed for want of a TLS session slot. Nonzero means the ramp
    /// hit zoxy's admission cap (`ZOXY_TLS_ENGINES`, profile.zig), not its TLS.
    /// Always null on plaintext profiles: the metric is absent there.
    shed_tls_engines: ?u64 = null,
};

/// Scrape zoxy's admin endpoint from inside the container via bash's /dev/tcp:
/// the admin port isn't published and the image has no curl. Best-effort:
/// nulls mean unread, not zero.
fn zoxyCounters(gpa: Allocator, arena: Allocator, io: Io, fleet: Fleet) ZoxyCounters {
    const res = remote.check(
        gpa,
        arena,
        io,
        fleet.proxyHost(),
        "zoxy counters",
        // `|| true`: grep exits 1 when neither counter is present, which is a
        // question answered ("no such metric"), not a transport failure.
        "docker exec zoxy bash -c 'exec 3<>/dev/tcp/127.0.0.1/9101 && " ++
            "printf \"GET /metrics HTTP/1.1\\r\\nHost: admin\\r\\nConnection: close\\r\\n\\r\\n\" >&3 && " ++
            "cat <&3' 2>/dev/null | grep -E 'access_log_dropped|shed_tls_engines' || true",
        deadline.inspect,
    ) catch return .{};

    return .{
        .access_log_dropped = counterNamed(res.stdout, "access_log_dropped"),
        .shed_tls_engines = counterNamed(res.stdout, "shed_tls_engines"),
    };
}

/// The value of the first sample whose metric name contains `needle`; one
/// scrape carries both counters.
fn counterNamed(text: []const u8, needle: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // The name is everything up to a label brace or the value's space.
        const name_end = std.mem.indexOfAny(u8, line, " \t{") orelse line.len;
        if (std.mem.indexOf(u8, line[0..name_end], needle) == null) continue;
        return counterValue(line);
    }
    return null;
}

/// The value of the first sample line in Prometheus text. `# HELP`/`# TYPE`
/// lines match the grep too; skipped here to avoid more shell quoting.
fn counterValue(text: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // `<name>[{labels}] <value>` — the value is the last field.
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        var last: ?[]const u8 = null;
        while (fields.next()) |f| last = f;
        const v = last orelse continue;

        if (std.fmt.parseInt(u64, v, 10)) |n| return n else |_| {}
        // Samples are floats by spec, so `0.0` is a valid counter value.
        if (std.fmt.parseFloat(f64, v)) |f| {
            if (f >= 0) return @intFromFloat(@round(f));
        } else |_| {}
    }
    return null;
}

/// Ask GitHub, from the proxy host, what `ref` points at (bare sha via
/// `Accept: application/vnd.github.sha`; no jq on the fleet). Best-effort:
/// null means unknown, never stale.
fn resolveRef(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    fleet: Fleet,
    ref: []const u8,
    timeout_ns: u64,
) ?[]const u8 {
    const res = remote.check(
        gpa,
        arena,
        io,
        fleet.proxyHost(),
        "resolve zoxy ref",
        std.fmt.allocPrint(
            arena,
            "curl -sS --max-time 20 -H 'Accept: application/vnd.github.sha' " ++
                "https://api.github.com/repos/zoxy-io/zoxy/commits/{s}",
            .{ref},
        ) catch return null,
        timeout_ns,
    ) catch return null;

    const sha = std.mem.trim(u8, res.stdout, " \n\r\t");
    return if (isSha(sha)) sha else null;
}

/// Where tonight's zoxy binary comes from, resolved once before any build so
/// the build and start steps interpolate the same image tag.
pub const ZoxySource = struct {
    /// Selects the stage in proxies/zoxy/Dockerfile.
    flavour: []const u8,
    /// A git ref for `source`; a release tag (`v0.0.9`) for `release`.
    ref: []const u8,
    /// The binary's real cpu target: `native` for source; releases are built
    /// upstream with `-Dcpu=x86_64_v3`.
    cpu: []const u8,

    fn isSource(self: ZoxySource) bool {
        return std.mem.eql(u8, self.flavour, "source");
    }
};

/// Resolve `profile.zoxy_ref` into a `ZoxySource`; null if `release` could not
/// be resolved. Never falls back to a source build: that is a different binary.
/// The tag comes from the `releases/latest` redirect (no jq on the fleet).
fn resolveZoxySource(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    fleet: Fleet,
    timeout_ns: u64,
) ?ZoxySource {
    if (!std.mem.eql(u8, profile.zoxy_ref, "release")) {
        return .{ .flavour = "source", .ref = profile.zoxy_ref, .cpu = "native" };
    }

    const res = remote.check(
        gpa,
        arena,
        io,
        fleet.proxyHost(),
        "resolve latest zoxy release",
        "curl -sS -o /dev/null -w '%{url_effective}' -L --max-time 20 " ++
            "https://github.com/zoxy-io/zoxy/releases/latest",
        timeout_ns,
    ) catch return null;

    const tag = tagFromLatestUrl(std.mem.trim(u8, res.stdout, " \n\r\t")) orelse return null;
    return .{ .flavour = "release", .ref = arena.dupe(u8, tag) catch return null, .cpu = "x86_64_v3" };
}

/// Run-scoped pin of the resolved release tag, so a release published mid-run
/// cannot split one run across two zoxy versions. The first profile writes it
/// next to the run's results; later profiles read it back.
const zoxy_pin_name = "zoxy-release.pin";

fn zoxyPinPath(arena: Allocator, out_dir: []const u8) ?[]const u8 {
    // out_dir is `results/<runid>/<profile>`; the pin belongs to the run.
    const run_dir = std.fs.path.dirname(out_dir) orelse return null;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ run_dir, zoxy_pin_name }) catch null;
}

fn readZoxyPin(arena: Allocator, io: Io, out_dir: []const u8) ?[]const u8 {
    const path = zoxyPinPath(arena, out_dir) orelse return null;
    const raw = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64)) catch return null;
    const tag = std.mem.trim(u8, raw, " \n\r\t");
    // Re-validated: a corrupt pin must not become an image tag.
    return if (isReleaseTag(tag)) tag else null;
}

fn writeZoxyPin(io: Io, out_dir: []const u8, tag: []const u8) void {
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const path = zoxyPinPath(fba.allocator(), out_dir) orelse return;
    // Best-effort: losing the pin costs a second resolve, not the run.
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = tag }) catch {};
}

/// The tag from the URL `…/releases/latest` redirects to, else null. GitHub
/// serves errors and rate limits as 200 pages, so success proves nothing.
fn tagFromLatestUrl(url: []const u8) ?[]const u8 {
    const marker = "/releases/tag/";
    const at = std.mem.lastIndexOf(u8, url, marker) orelse return null;
    const tag = url[at + marker.len ..];
    return if (isReleaseTag(tag)) tag else null;
}

/// A `v`-prefixed tag safe to embed in a URL, a shell command and an image tag.
fn isReleaseTag(s: []const u8) bool {
    if (s.len < 2 or s.len > 32 or s[0] != 'v' or !std.ascii.isDigit(s[1])) return false;
    for (s[1..]) |c| {
        if (!std.ascii.isDigit(c) and c != '.' and c != '-' and !std.ascii.isAlphabetic(c)) return false;
    }
    return true;
}

/// A full 40-character hex sha; rejects GitHub's error bodies.
fn isSha(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Whether the zoxy that ran differs from what the ref pointed at at build
/// time. Unknown on either side is NOT stale.
fn isStaleBuild(ran: ?[]const u8, want: ?[]const u8) bool {
    const r = ran orelse return false;
    const w = want orelse return false;
    return !std.mem.eql(u8, r, w);
}

const warm_probe_attempts = 30;
const warm_probe_interval_ns = 2 * std.time.ns_per_s;

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

    // Flushed after every proxy, so a crash keeps finished records.
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

    // --- preflight: sweep the proxy host. A leftover container would answer
    // probes on the shared port and be measured under another proxy's name.
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

    // --- TLS material, shared by every proxy.
    //
    // One P-256 key for all: signature cost is part of the measurement, and
    // P-256 is all zoxy accepts. Generated on the proxy host, never committed.
    // Fatal only on TLS profiles.
    //
    // The directory is made on EVERY profile: proxies always bind-mount it, and
    // dockerd would otherwise create it root-owned, breaking a later TLS
    // profile's `openssl`.
    ensureTlsMaterial(gpa, arena, io, opts.fleet, p.tls) catch |e| {
        if (p.tls) {
            redact.log("bench: could not make the proxies' TLS certificate: {s}", .{@errorName(e)});
            for (opts.proxies) |name| {
                try records.append(arena, .{
                    .name = name,
                    .status = .skipped,
                    .stage = .start,
                    .err = "the proxies' TLS certificate could not be generated on the proxy host",
                });
            }
            try flush.write();
            return .{ .records = try records.toOwnedSlice(arena), .aborted = true };
        }
        // Nothing on a plaintext profile depends on the directory existing yet;
        // the TLS profile that does will report it.
        redact.log("bench: could not prepare {s}: {s}", .{ tls_dir, @errorName(e) });
    };

    // --- cAdvisor. Must be started explicitly: `up --wait <proxy>` starts only
    // that service. Not fatal; missing samples mark records `degraded`.
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

    // --- the origin pool. All-or-nothing: a missing member fails nothing, it
    // silently routes a share of requests into a refused connection. Locally
    // the first iteration starts the whole pool.
    for (opts.fleet.backend_ips, 0..) |_, i| {
        _ = remote.check(
            gpa,
            arena,
            io,
            opts.fleet.backendHost(i),
            try std.fmt.allocPrint(arena, "backend {d} up", .{i}),
            try std.fmt.allocPrint(arena, "cd {s} && {s} --profile {s} up -d --wait", .{
                opts.fleet.remote_dir,
                opts.fleet.composeCmd(),
                try opts.fleet.backendProfile(arena, i),
            }),
            deadline.backend_up,
        ) catch |e| {
            redact.log("bench: backend {d} never came up: {s}", .{ i, @errorName(e) });
            for (opts.proxies) |name| {
                try records.append(arena, .{
                    .name = name,
                    .status = .skipped,
                    .stage = .start,
                    .err = "an origin in the backend pool never came up",
                });
            }
            try flush.write();
            return .{ .records = try records.toOwnedSlice(arena), .aborted = true };
        };
        if (opts.fleet.isLocal()) break;
    }

    // --- build every proxy BEFORE any measurement, so compiles don't steal the
    // SUT's CPU. A build failure marks only that proxy.
    //
    // zoxy's source is resolved first, and only when zoxy is in tonight's set.
    const wants_zoxy = for (opts.proxies) |name| {
        if (std.mem.eql(u8, name, "zoxy")) break true;
    } else false;
    const zoxy_src = if (wants_zoxy) blk: {
        // A tag pinned by an earlier profile of this run wins; see `zoxy_pin_name`.
        if (readZoxyPin(arena, io, opts.out_dir)) |tag| {
            redact.log("bench: [zoxy] release pinned by this run: {s}", .{tag});
            break :blk ZoxySource{ .flavour = "release", .ref = tag, .cpu = "x86_64_v3" };
        }
        const src = resolveZoxySource(gpa, arena, io, opts.fleet, deadline.inspect);
        if (src) |s| {
            if (std.mem.eql(u8, s.flavour, "release")) writeZoxyPin(io, opts.out_dir, s.ref);
        }
        break :blk src;
    } else null;
    if (wants_zoxy) {
        if (zoxy_src) |z| {
            redact.log("bench: [zoxy] {s} build at {s} (cpu {s})", .{ z.flavour, z.ref, z.cpu });
        } else {
            redact.log("bench: [zoxy] could not resolve the latest release — zoxy cannot build", .{});
        }
    }

    // The Zig toolchain zoxy's Dockerfile builds `FROM`, cached in Object Storage
    // to keep ziglang.org off the critical path (run #21). Only needed for a
    // source build: BuildKit skips unreached stages.
    for (opts.proxies) |name| {
        if (!std.mem.eql(u8, name, "zoxy")) continue;
        if (zoxy_src == null or !zoxy_src.?.isSource()) break;
        redact.log("bench: [zig] toolchain", .{});
        const hit = remote.check(
            gpa,
            arena,
            io,
            opts.fleet.proxyHost(),
            "cache restore zig",
            try std.fmt.allocPrint(
                arena,
                "bench-image-cache restore zig {s} && echo HIT || true",
                .{zig_toolchain_tag},
            ),
            deadline.inspect,
        ) catch null;
        const have = if (hit) |h| std.mem.indexOf(u8, h.stdout, "HIT") != null else false;
        if (!have) {
            _ = remote.check(
                gpa,
                arena,
                io,
                opts.fleet.proxyHost(),
                "build zig toolchain",
                try std.fmt.allocPrint(arena, "cd {s} && docker build -t {s} proxies/zig", .{
                    opts.fleet.remote_dir, zig_toolchain_tag,
                }),
                deadline.build,
            ) catch {
                // zoxy's build will fail loudly on the missing FROM; every other
                // proxy is unaffected.
                redact.log("bench: [zig] toolchain build failed — zoxy cannot build", .{});
                break;
            };
            _ = remote.check(
                gpa,
                arena,
                io,
                opts.fleet.proxyHost(),
                "cache save zig",
                try std.fmt.allocPrint(arena, "bench-image-cache save zig {s}", .{zig_toolchain_tag}),
                deadline.build,
            ) catch {};
        }
        redact.log("bench: [zig] toolchain {s}", .{if (have) "restored from cache" else "built"});
        break;
    }

    // Resolved BEFORE the build, so a legitimate mid-run push isn't mistaken
    // for a stale build.
    const zoxy_ref_sha: ?[]const u8 = blk: {
        for (opts.proxies) |name| {
            if (std.mem.eql(u8, name, "zoxy")) break;
        } else break :blk null;

        const z = zoxy_src orelse break :blk null;
        const sha = resolveRef(gpa, arena, io, opts.fleet, z.ref, deadline.inspect);
        if (sha) |s| {
            redact.log("bench: [zoxy] ref {s} -> {s}", .{ z.ref, s });
        } else {
            redact.log("bench: [zoxy] could not resolve ref {s}; freshness unchecked", .{z.ref});
        }
        break :blk sha;
    };

    var build_failed: std.StringHashMapUnmanaged(void) = .empty;
    for (opts.proxies) |name| {
        // No resolved source: recorded as a build failure so it reads as one.
        if (std.mem.eql(u8, name, "zoxy") and zoxy_src == null) {
            try build_failed.put(arena, name, {});
            redact.log("bench: [zoxy] BUILD SKIPPED — no resolved source", .{});
            continue;
        }
        redact.log("bench: [{s}] building", .{name});
        const t0 = Io.Timestamp.now(io, .awake);

        // A cache hit skips the build (see `cacheableImage`). `|| true`: a miss
        // is normal, not a failure; the HIT marker decides.
        const restored = if (cacheableImage(name)) |tag|
            remote.check(
                gpa,
                arena,
                io,
                opts.fleet.proxyHost(),
                try std.fmt.allocPrint(arena, "cache restore {s}", .{name}),
                try std.fmt.allocPrint(
                    arena,
                    "bench-image-cache restore {s} {s} && echo HIT || true",
                    .{ name, tag },
                ),
                deadline.inspect,
            ) catch null
        else
            null;
        const cache_hit = if (restored) |r|
            std.mem.indexOf(u8, r.stdout, "HIT") != null
        else
            false;

        if (!cache_hit) {
            const cmd = try std.fmt.allocPrint(arena, "cd {s} && {s} {s} --profile {s} build {s}", .{
                opts.fleet.remote_dir,
                envPrefix(arena, p, opts.fleet, zoxy_src, null) catch "",
                opts.fleet.composeCmd(),
                name,
                name,
            });
            // Retried: builds hit the network, and one transient failure would
            // cost the night (run 30749146321). Not counted in `deadline.turn`:
            // no watchdog covers the build phase.
            var attempt: u32 = 1;
            while (true) : (attempt += 1) {
                if (remote.check(
                    gpa,
                    arena,
                    io,
                    opts.fleet.proxyHost(),
                    try std.fmt.allocPrint(arena, "build {s}", .{name}),
                    cmd,
                    deadline.build,
                )) |_| {
                    break;
                } else |_| {
                    if (attempt >= deadline.build_attempts) {
                        try build_failed.put(arena, name, {});
                        break;
                    }
                    redact.log("bench: [{s}] build attempt {d}/{d} failed, retrying", .{
                        name, attempt, deadline.build_attempts,
                    });
                    io.sleep(.fromNanoseconds(deadline.build_retry_backoff), .awake) catch {};
                }
            }

            // Populate the cache only from a build that succeeded.
            if (!build_failed.contains(name)) {
                if (cacheableImage(name)) |tag| {
                    _ = remote.check(
                        gpa,
                        arena,
                        io,
                        opts.fleet.proxyHost(),
                        try std.fmt.allocPrint(arena, "cache save {s}", .{name}),
                        try std.fmt.allocPrint(arena, "bench-image-cache save {s} {s}", .{ name, tag }),
                        deadline.build,
                    ) catch {};
                }
            }
        }

        const secs = @as(f64, @floatFromInt(
            t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds,
        )) / std.time.ns_per_s;
        // Say which, so a failed build never reads as "built" (run #21).
        if (build_failed.contains(name)) {
            redact.log("bench: [{s}] BUILD FAILED after {d:.0}s", .{ name, secs });
        } else {
            redact.log("bench: [{s}] {s} in {d:.0}s", .{
                name,
                if (cache_hit) "restored from cache" else "built",
                secs,
            });
        }
    }

    // --- the measurement loop.
    for (opts.proxies, 0..) |name, proxy_idx| {
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

        // Placeholder record, flushed before the risky work, so if the
        // watchdog ends the process this proxy still has a `failed` entry
        // (run #28). Overwritten below once the turn finishes.
        try records.append(arena, .{
            .name = name,
            .status = .failed,
            .stage = stage,
            .err = "turn did not complete (the suite's watchdog ended the process before it could)",
        });
        try flush.write();

        // Bound the whole turn, not just the ramp (run #12). The watchdog logs
        // `stage`, so a hang names its step. `turn`, not `proxy`; see
        // `deadline.turn`.
        var watchdog: ProxyWatchdog = .{
            .limit_ns = deadline.turn(p.ramp_seconds, p.cooldown_s),
            .name = name,
            .stage = &stage,
        };
        if (std.Thread.spawn(.{}, ProxyWatchdog.watch, .{&watchdog})) |t| {
            t.detach();
        } else |e| {
            // Losing the watchdog costs the bound, not the run.
            redact.log("bench: [{s}] no watchdog ({s})", .{ name, @errorName(e) });
        }
        defer watchdog.done.store(true, .release);

        const rec = runOne(gpa, arena, io, opts, name, proxy_idx, zoxy_src, zoxy_ref_sha, &stage) catch |e| blk: {
            redact.log("bench: [{s}] {s} at stage {s}", .{ name, @errorName(e), stage.str() });
            break :blk artifact.ProxyRecord{
                .name = name,
                .status = .failed,
                .stage = stage,
                .err = @errorName(e),
            };
        };
        // Replace the placeholder in place.
        records.items[records.items.len - 1] = rec;
        try flush.write();

        // Before teardown removes the container, and outside `runOne` so a
        // failed turn still leaves its reason.
        captureErrorLog(gpa, arena, io, opts.fleet, opts.out_dir, name);

        // Always tear down. A failure surfaces in the next proxy's identity
        // check.
        teardownProxy(gpa, arena, io, opts.fleet, name) catch |e| {
            redact.log("bench: [{s}] teardown failed: {s}", .{ name, @errorName(e) });
        };

        io.sleep(.fromNanoseconds(p.cooldown_s * std.time.ns_per_s), .awake) catch {};
    }

    flush.finished = try nowIso(io, arena);
    try flush.write();

    return .{ .records = try records.toOwnedSlice(arena) };
}

/// Move to `next` and log it; these lines are the only live view of an
/// unattended run.
fn enter(stage: *artifact.Stage, next: artifact.Stage, name: []const u8) void {
    stage.* = next;
    redact.log("bench: [{s}] {s}", .{ name, next.str() });
}

/// One proxy, start to finish. Every failure returns an error, which the caller
/// records as `failed`; this never skips another proxy or stops the suite.
fn runOne(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    name: []const u8,
    proxy_idx: usize,
    // Every proxy passes it: it is part of zoxy's image tag, and `up` must name
    // the tag `build` produced.
    zoxy_src: ?ZoxySource,
    // The ref's sha before the build, or null if unknown.
    zoxy_ref_sha: ?[]const u8,
    stage: *artifact.Stage,
) !artifact.ProxyRecord {
    const p = opts.prof;
    const ports = portsFor(p, opts.fleet, proxy_idx);
    const port = ports.target(p);

    var notes: std.ArrayList([]const u8) = .empty;
    var zoxy_commit: ?[]const u8 = null;
    var build_info: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    // Set when the running zoxy isn't the commit `zoxy_ref` pointed at.
    var stale_build = false;

    // `https` on TLS profiles makes zrk use TLS. The host is an IP literal (no
    // DNS in the measurement), so verification is off; see `ensureTlsMaterial`.
    const target = try std.fmt.allocPrint(arena, "{s}://{s}:{d}{s}", .{
        if (p.tls) "https" else "http",
        opts.fleet.proxy_ip,
        port,
        p.req_path,
    });

    {
        // Log the proxy host's TCP census before start: something accumulates
        // across proxies (runs #19/#20), and upstream connections burn
        // ephemeral ports against a 60s TIME_WAIT. Best-effort.
        if (remote.check(
            gpa,
            arena,
            io,
            opts.fleet.proxyHost(),
            "sockets before start",
            "cat /proc/net/sockstat",
            deadline.inspect,
        )) |res| {
            var lines = std.mem.splitScalar(u8, res.stdout, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "TCP:")) {
                    redact.log("bench: [{s}] proxy host {s}", .{ name, line });
                }
            }
        } else |_| {}

        enter(stage, .start, name);
        const start_label = try std.fmt.allocPrint(arena, "start {s}", .{name});
        const start_cmd = try std.fmt.allocPrint(arena, "cd {s} && {s} {s} --profile {s} up -d --wait {s}", .{
            opts.fleet.remote_dir,
            try envPrefix(arena, p, opts.fleet, zoxy_src, ports),
            opts.fleet.composeCmd(),
            name,
            name,
        });

        var start_attempt: u32 = 1;
        while (true) : (start_attempt += 1) {
            if (remote.check(
                gpa,
                arena,
                io,
                opts.fleet.proxyHost(),
                start_label,
                start_cmd,
                deadline.start,
            )) |_| {
                break;
            } else |e| {
                if (start_attempt >= deadline.start_attempts) {
                    // `up --wait` shows only lifecycle events; log the exit
                    // state (OOM vs exit 1) and the container's output (#25).
                    reportStartFailure(gpa, arena, io, opts.fleet, name);
                    return e;
                }
                // Stale port binds (#26) and registry hiccups (#30) are
                // transient; `deadline.turn` budgets every attempt.
                redact.log("bench: [{s}] start attempt {d}/{d} failed, retrying", .{
                    name, start_attempt, deadline.start_attempts,
                });
                io.sleep(.fromNanoseconds(deadline.start_retry_backoff), .awake) catch {};
            }
        }

        enter(stage, .identity, name);
        // Assert only this proxy is running: `up --wait` doesn't rule out a
        // leftover container on the same port.
        try assertOnlyProxy(gpa, arena, io, opts.fleet, name);

        // Build descriptor: a target-CPU mismatch across proxies is a fairness
        // issue invisible in the numbers. Absent for stock images, hence
        // `|| true`; only a transport failure is an error.
        if (remote.check(
            gpa,
            arena,
            io,
            opts.fleet.proxyHost(),
            "build info",
            try std.fmt.allocPrint(
                arena,
                "docker exec {s} cat /etc/{s}/build-info 2>/dev/null || true",
                .{ name, name },
            ),
            deadline.inspect,
        )) |res| {
            const info = std.mem.trim(u8, res.stdout, " \n\r\t");
            if (info.len > 0) {
                build_info = info;
                // Built here for the host CPU; stock images are generic x86-64.
                // The asymmetry must travel with the numbers.
                if (std.mem.indexOf(u8, info, "cpu=native") != null or
                    std.mem.indexOf(u8, info, "SIMD") != null)
                {
                    try notes.append(arena, try std.fmt.allocPrint(
                        arena,
                        "compiled for this host's CPU with SIMD ({s}); stock images in this comparison are generic x86-64 builds",
                        .{info},
                    ));
                }
                // The opposite asymmetry: zoxy ships ReleaseSafe (upstream
                // 1573c16), and that cost lands in its throughput.
                if (std.mem.indexOf(u8, info, "ReleaseSafe") != null) {
                    try notes.append(
                        arena,
                        "built ReleaseSafe: Zig's bounds/overflow/unreachable checks stay on in the hot path, " ++
                            "which measured -12.7% sustained against the same code at ReleaseFast (c1k, 2x2 over " ++
                            "v0.1.0/v0.2.1); the other proxies here are built without equivalent checks",
                    );
                }
            } else {
                // Stock upstream image, built for a generic x86-64 baseline.
                build_info = "stock upstream image (generic x86-64 baseline)";
            }
        } else |_| {
            // The probe itself failed, which differs from an absent file.
            try notes.append(arena, "could not read the image's build descriptor");
        }

        if (std.mem.eql(u8, name, "zoxy")) {
            // Record the commit that actually ran; the Dockerfile's cached
            // clone may lag the requested ref.
            if (remote.check(
                gpa,
                arena,
                io,
                opts.fleet.proxyHost(),
                "zoxy commit",
                "docker exec zoxy cat /etc/zoxy/zoxy-commit",
                deadline.inspect,
            )) |res| {
                // The only record of which commit produced tonight's numbers.
                zoxy_commit = std.mem.trim(u8, res.stdout, " \n\r\t");
            } else |_| {
                try notes.append(arena, "could not read the running zoxy image's commit");
            }

            // Should always match the ref; if the Dockerfile's cache-bust
            // breaks, a frozen commit would otherwise publish as "main".
            // Silent when either side is unknown.
            const asked_for = if (zoxy_src) |z| z.ref else profile.zoxy_ref;
            if (isStaleBuild(zoxy_commit, zoxy_ref_sha)) {
                stale_build = true;
                redact.log(
                    "bench: [zoxy] STALE BUILD: ran {s} but {s} is {s}",
                    .{ zoxy_commit.?, asked_for, zoxy_ref_sha.? },
                );
                // Prepended: must be the first note a reader sees.
                try notes.insert(arena, 0, try std.fmt.allocPrint(
                    arena,
                    "STALE BUILD — ran zoxy {s}, but {s} was {s} when this build ran; " ++
                        "these numbers are not a measurement of {s}",
                    .{ zoxy_commit.?, asked_for, zoxy_ref_sha.?, asked_for },
                ));
            }
        }

        // Version last, so its failure can't cost the probes above.
        if (remote.check(
            gpa,
            arena,
            io,
            opts.fleet.proxyHost(),
            "version",
            try versionProbe(arena, name),
            deadline.inspect,
        )) |res| {
            const v = std.mem.trim(u8, res.stdout, " \n\r\t");
            if (v.len > 0) version = v;
        } else |_| {
            try notes.append(arena, "could not read the running proxy's version");
        }
    }

    enter(stage, .warm, name);

    const cadvisor_addr: ?net.IpAddress = try net.IpAddress.parse(opts.fleet.proxy_ip, 8081);

    {
        // These probes need a real connect timeout, which the top-level
        // `Io.Threaded` panics on (see cadvisor.scrape); use a scoped zio
        // Runtime.
        var probe_rt = try zio.Runtime.init(arena, .{});
        defer probe_rt.deinit();
        const probe_io = probe_rt.io();

        try warmProbe(gpa, probe_io, target, name);

        // Best-effort cAdvisor head start before the ramp's sampling window.
        if (cadvisor_addr) |addr| {
            if (!cadvisor.waitUntilFound(gpa, probe_io, addr, name, deadline.cadvisor_warm, cadvisor.scrape_deadline_ns)) {
                redact.log(
                    "bench: [{s}] cadvisor had not reported this container after {d}s; CPU/mem may be absent for this ramp",
                    .{ name, deadline.cadvisor_warm / std.time.ns_per_s },
                );
            }
        }
    }

    enter(stage, .ramp, name);
    const start_iso = try nowIso(io, arena);

    const out_base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ opts.out_dir, name });

    // The ramp runs as a child process on a hard deadline, so a wedged proxy
    // is killed and recorded `failed` instead of taking the suite down (runs
    // #21, #22). It must be this exact binary; see `selfExe`.
    const outcome_path = try std.fmt.allocPrint(arena, "{s}.outcome.json", .{out_base});
    const cad_arg = if (cadvisor_addr != null)
        try std.fmt.allocPrint(arena, " --cadvisor {s}:8081", .{opts.fleet.proxy_ip})
    else
        "";
    const ramp_cmd = try std.fmt.allocPrint(
        arena,
        "{s} ramp --profile {s} --proxy {s} --target {s} " ++
            "--out-base {s} --runid {s} --outcome {s}{s}",
        .{ try selfExe(arena), p.name, name, target, out_base, opts.runid, outcome_path, cad_arg },
    );
    // `exec` for the deadline hook: the socket census must be read BEFORE the
    // kill closes the ramp's connections (see `logEstablished`).
    const ramp_res = try remote.exec(
        gpa,
        io,
        try arena.dupe([]const u8, &.{ "sh", "-c", ramp_cmd }),
        .{
            .deadline_ns = deadline.proxy(p.ramp_seconds),
            .on_deadline = ProxyWatchdog.logSockets,
            .stream_output = true,
        },
    );
    // `stream_output` already printed both streams; no echo here.
    if (!ramp_res.ok()) {
        var buf: [64]u8 = undefined;
        redact.log("bench: [{s}] ramp failed ({s})", .{ name, ramp_res.describe(&buf) });
        return error.RampFailed;
    }
    const outcome = try ramp.readOutcome(arena, io, outcome_path);
    const end_iso = try nowIso(io, arena);

    // Read after the ramp and before teardown: the counters are cumulative
    // per process.
    const counters: ZoxyCounters = if (std.mem.eql(u8, name, "zoxy"))
        zoxyCounters(gpa, arena, io, opts.fleet)
    else
        .{};
    const access_log_dropped = counters.access_log_dropped;

    // --- classify.
    //
    // An identity violation voids the measurement: another proxy's container
    // was live, so the data may belong to the wrong proxy.
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
    if (outcome.cadvisor_samples == 0) {
        status = .degraded;
        try notes.append(arena, "no cAdvisor samples: CPU and memory are absent, not zero");
    }
    if (outcome.saturated) {
        // Not degraded — the throughput number is still sound. But the tail is
        // the clamp value, and the report must not print it as a measurement.
        try notes.append(arena, "latency histogram saturated at 60s; tail percentiles are a floor, not a value");
    }
    if (std.mem.eql(u8, name, "zoxy")) {
        if (access_log_dropped) |dropped| {
            if (dropped > 0) {
                // Not degraded (like `saturated`): the measurement is valid
                // with a caveat. Degrading would also drop zoxy's regression
                // baseline (index.zig previousSustained).
                const share = if (outcome.completed > 0)
                    100.0 * @as(f64, @floatFromInt(dropped)) / @as(f64, @floatFromInt(outcome.completed))
                else
                    0;
                try notes.append(arena, try std.fmt.allocPrint(
                    arena,
                    "dropped {d} access-log lines ({d:.2}% of completed requests) instead of blocking on stdout; " ++
                        "the other proxies block or buffer, so this much logging work was skipped here and not by them",
                    .{ dropped, share },
                ));
            }
        } else {
            try notes.append(
                arena,
                "could not read zoxy's access-log drop counter; whether logging was lossy here is unknown, not zero",
            );
        }

        // TLS admission cap: nonzero means `tls_engines` was too small and the
        // ramp measured the cap (fix in profile.zig). Not degraded, as above.
        if (p.tls) {
            if (counters.shed_tls_engines) |shed| {
                if (shed > 0) {
                    try notes.insert(arena, 0, try std.fmt.allocPrint(
                        arena,
                        "shed {d} connection(s) for want of a TLS session slot: this profile's " ++
                            "tls_engines pool was too small for {d} offered connections, so part of " ++
                            "this number is zoxy's admission cap rather than its TLS",
                        .{ shed, p.connections },
                    ));
                }
            } else {
                try notes.append(
                    arena,
                    "could not read zoxy's TLS session shed counter; whether connections were refused for want of a session slot is unknown, not zero",
                );
            }
        }
    }
    if (stale_build) {
        // Not `failed` (some zoxy was measured), but never a plain `ok`: it is
        // not the commit the report names.
        status = .degraded;
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
        .version = version,
        .zoxy_commit = zoxy_commit,
        // The resolved ref: on the release flavour `zoxy_ref` is just "release".
        .zoxy_ref = if (std.mem.eql(u8, name, "zoxy"))
            (if (zoxy_src) |z| z.ref else profile.zoxy_ref)
        else
            null,
        .zoxy_ref_sha = if (std.mem.eql(u8, name, "zoxy")) zoxy_ref_sha else null,
        .build_info = build_info,
        .access_log_dropped = access_log_dropped,
        .shed_tls_engines = counters.shed_tls_engines,
        .notes = try notes.toOwnedSlice(arena),
    };
}

/// Poll the target from the loadgen until it serves a 2xx. Speaks TLS on TLS
/// profiles, to prove the ramp's listener handshakes. Never logs the target URL
/// (private address).
fn warmProbe(gpa: Allocator, io: Io, target: []const u8, name: []const u8) !void {
    const url = try std.Uri.parse(target);
    const use_tls = std.mem.eql(u8, url.scheme, "https");
    const host = switch (url.host orelse return error.InvalidTarget) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    const addr = try net.IpAddress.parse(host, url.port orelse @as(u16, if (use_tls) 443 else 80));
    const path = if (url.path.isEmpty()) "/" else switch (url.path) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };

    const started = Io.Timestamp.now(io, .awake);
    var attempt: usize = 0;
    while (attempt < warm_probe_attempts) : (attempt += 1) {
        if (probeOnce(gpa, io, addr, path, use_tls)) |_| return else |_| {}

        const elapsed = started.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        if (elapsed >= deadline.warm_probe) {
            redact.log("bench: [{s}] never served 200 within {d}s", .{ name, deadline.warm_probe / std.time.ns_per_s });
            return error.WarmProbeFailed;
        }
        io.sleep(.fromNanoseconds(warm_probe_interval_ns), .awake) catch {};
    }
    redact.log("bench: [{s}] never served 200 after {d} attempts", .{ name, warm_probe_attempts });
    return error.WarmProbeFailed;
}

/// Bounds `probeOnce`'s connect.
const probe_connect_timeout: Io.Timeout = .{
    .duration = .{ .raw = .fromNanoseconds(5 * std.time.ns_per_s), .clock = .awake },
};

fn probeOnce(gpa: Allocator, io: Io, addr: net.IpAddress, path: []const u8, use_tls: bool) !void {
    // `warmProbe` checks its deadline only between attempts, so each connect
    // needs its own bound.
    var stream = try addr.connect(io, .{ .mode = .stream, .timeout = probe_connect_timeout });
    defer stream.close(io);

    if (!use_tls) {
        var wbuf: [512]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        var rbuf: [1024]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        return probeExchange(&w.interface, &r.interface, path);
    }

    // zrk's TLS transport, same as the ramp. On the heap: the state is ~92 KiB
    // and self-referential once `handshake` runs, so it can't move.
    const st = try gpa.create(zrk.tls.State);
    defer gpa.destroy(st);
    // `init`/`deinit`, not a literal: `State` has no field defaults (zrk 2.4.0).
    st.init();
    defer st.deinit();
    // Insecure (self-signed cert, IP-literal target) and ALPN http/1.1, as the
    // ramp runs, so the probe can't accept what the measurement would reject.
    try st.handshake(io, gpa, stream, tls_probe_host, true, null, zrk.tls.alpn_http1);
    return probeExchange(st.writer(), st.reader(), path);
}

/// SNI sent by the probe, never verified. No proxy here selects a certificate
/// by name, and zoxy's L4 SNI routing is not in the path.
const tls_probe_host = "bench";

/// One request/response over the caller's transport. One flush suffices: zrk
/// 2.x writes to the socket itself.
fn probeExchange(w: *Io.Writer, r: *Io.Reader, path: []const u8) !void {
    try w.print("GET {s} HTTP/1.1\r\nHost: bench\r\nConnection: close\r\n\r\n", .{path});
    try w.flush();

    const line = try r.takeDelimiterInclusive('\n');
    // Only a 2xx counts. A proxy that is up but whose origin is dead answers
    // 502, and treating that as ready would ramp against an error page.
    if (std.mem.indexOf(u8, line, " 2") == null) return error.NotServing;
}

/// Best-effort: log why `name`'s container did not start. Never fails.
fn reportStartFailure(gpa: Allocator, arena: Allocator, io: Io, fleet: Fleet, name: []const u8) void {
    const inspect_cmd = std.fmt.allocPrint(
        arena,
        "docker inspect {s} --format '{{{{.State.ExitCode}}}} oom={{{{.State.OOMKilled}}}} {{{{.State.Error}}}}'",
        .{name},
    ) catch return;
    if (remote.check(gpa, arena, io, fleet.proxyHost(), "inspect", inspect_cmd, deadline.inspect)) |res| {
        redact.log("bench: [{s}] {s}", .{ name, std.mem.trim(u8, res.stdout, " \n\r\t") });
    } else |_| {}

    const logs_cmd = std.fmt.allocPrint(arena, "docker logs {s} --tail 50 2>&1", .{name}) catch return;
    if (remote.check(gpa, arena, io, fleet.proxyHost(), "logs", logs_cmd, deadline.inspect)) |res| {
        var scrubbed: [4096]u8 = undefined;
        const tail = res.stdout[res.stdout.len -| 2048..];
        redact.log("bench: [{s}] container log:\n{s}", .{ name, redact.scrub(&scrubbed, tail) });
    } else |_| {}
}

/// Log tail kept per proxy per profile, to keep `results.tar` bounded.
const error_log_tail_bytes: usize = 256 * 1024;

/// Save `name`'s container logs into the results dir (shipped in
/// `results.tar`). Runs for every outcome, before `teardownProxy`'s
/// `docker rm -f` removes the log (run 20260901-111818). Best-effort.
fn captureErrorLog(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    fleet: Fleet,
    out_dir: []const u8,
    name: []const u8,
) void {
    const cmd = errorLogCmd(arena, name) catch return;
    // `check` for its ssh retry budget. Its failure path prints output without
    // foreign-IP scrubbing, but the exit status is `tail`'s, so that path never
    // carries content.
    const res = remote.check(
        gpa,
        arena,
        io,
        fleet.proxyHost(),
        captureWhat(arena, name),
        cmd,
        deadline.inspect,
    ) catch |e| {
        redact.log("bench: [{s}] could not capture the error log: {s}", .{ name, @errorName(e) });
        return;
    };
    if (res.stdout.len == 0) return;

    // Another machine's output: only `scrubAnyIp` catches its addresses.
    const clean = redact.scrubAnyIpAlloc(arena, res.stdout) catch |e| {
        redact.log("bench: [{s}] could not scrub the error log: {s}", .{ name, @errorName(e) });
        return;
    };
    // Skipped, not fatal: this `.log` is not published (`commands.publishable`).
    redact.assertNoIps("error log", clean) catch {
        redact.log("bench: [{s}] error log withheld: it still contains an address", .{name});
        return;
    };
    writeErrorLog(io, arena, out_dir, name, clean);
}

fn captureWhat(arena: Allocator, name: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "capture {s} error log", .{name}) catch "capture error log";
}

/// A proxy's diagnostic log kept as a file inside the container, which
/// `docker logs` can't see. Only nginx: its error_log is a real file, not the
/// stderr symlink (see proxies/nginx/nginx.conf.template; moved in #16).
fn errorLogPath(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "nginx")) return "/tmp/error.log";
    return null;
}

/// `docker logs`, plus the in-container log file where one exists. Both `logs`
/// and `cp` work on an exited container; `exec` would not. Access logs are
/// excluded: huge, and not diagnostics.
fn errorLogCmd(arena: Allocator, name: []const u8) ![]const u8 {
    const logs = try std.fmt.allocPrint(
        arena,
        "echo '=== docker logs {s} ==='; docker logs {s} 2>&1 | tail -c {d}",
        .{ name, name, error_log_tail_bytes },
    );
    const path = errorLogPath(name) orelse return logs;
    return std.fmt.allocPrint(
        arena,
        "{s}; echo; echo '=== {s}:{s} ==='; " ++
            "docker cp {s}:{s} - 2>/dev/null | tar -xO 2>/dev/null | tail -c {d}",
        .{ logs, name, path, name, path, error_log_tail_bytes },
    );
}

test "errorLogCmd tails both streams of a possibly-dead container" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const cmd = try errorLogCmd(arena_state.allocator(), "zoxy");
    // `2>&1`: proxy diagnostics are on stderr.
    try std.testing.expect(std.mem.indexOf(u8, cmd, "docker logs zoxy 2>&1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "tail -c 262144") != null);
    // zoxy keeps nothing in a file, so its command stops there.
    try std.testing.expect(std.mem.indexOf(u8, cmd, "docker cp") == null);
}

test "errorLogCmd also copies nginx's error_log, which is a file and not stderr" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const cmd = try errorLogCmd(arena_state.allocator(), "nginx");
    // Pinned: a capture reading only `docker logs` looks like it works.
    try std.testing.expect(std.mem.indexOf(u8, cmd, "docker cp nginx:/tmp/error.log -") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "tar -xO") != null);
}

fn writeErrorLog(io: Io, arena: Allocator, out_dir: []const u8, name: []const u8, text: []const u8) void {
    const path = std.fmt.allocPrint(arena, "{s}/{s}.error.log", .{ out_dir, name }) catch return;
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch |e| {
        redact.log("bench: [{s}] could not write {s}: {s}", .{ name, path, @errorName(e) });
        return;
    };
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(f, io, &buf);
    fw.interface.writeAll(text) catch return;
    fw.interface.flush() catch return;
    redact.log("bench: [{s}] error log saved ({d} bytes)", .{ name, text.len });
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

/// Where the proxies' certificate and key live, relative to the payload root —
/// the directory compose bind-mounts into every proxy at /etc/bench/tls.
const tls_dir = "proxies/tls";

/// Create the certificate and key every proxy's TLS listener loads, if absent.
/// haproxy needs a combined pem; the rest take them separately.
///
/// `genpkey` writes PKCS#8, which every proxy reads (rustls rejects `ecparam`'s
/// SEC1). `ec_param_enc:named_curve` is required: LibreSSL otherwise emits
/// explicit curve parameters, which zoxy and envoy refuse.
fn ensureTlsMaterial(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    fleet: Fleet,
    want_cert: bool,
) !void {
    // Always: the directory, owned by whoever runs this rather than by dockerd.
    // Only when asked: the key pair inside it.
    const mkdir = try std.fmt.allocPrint(arena, "cd {s} && mkdir -p {s}", .{ fleet.remote_dir, tls_dir });
    const cmd = if (!want_cert) mkdir else try std.fmt.allocPrint(
        arena,
        "{s} && if [ ! -s {s}/bench.pem ]; then " ++
            "openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 " ++
            "-pkeyopt ec_param_enc:named_curve -out {s}/bench.key && " ++
            "openssl req -new -x509 -key {s}/bench.key -out {s}/bench.crt " ++
            "-days 3650 -subj /CN=bench-proxy -batch && " ++
            "cat {s}/bench.crt {s}/bench.key > {s}/bench.pem && " ++
            // World-readable: envoy and haproxy run as non-root.
            "chmod 0644 {s}/bench.key {s}/bench.crt {s}/bench.pem; fi && " ++
            // Check the post-condition, so a bad pem fails here, not at start.
            "test -s {s}/bench.pem && test -s {s}/bench.key && test -s {s}/bench.crt",
        .{
            mkdir,   tls_dir, tls_dir, tls_dir, tls_dir,
            tls_dir, tls_dir, tls_dir, tls_dir, tls_dir,
            tls_dir, tls_dir, tls_dir, tls_dir,
        },
    );

    _ = try remote.check(
        gpa,
        arena,
        io,
        fleet.proxyHost(),
        if (want_cert) "tls material" else "tls dir",
        cmd,
        deadline.inspect,
    );
}

/// Remove every known proxy container from the proxy host.
fn sweepProxyHost(gpa: Allocator, arena: Allocator, io: Io, fleet: Fleet) !void {
    var cmd: std.ArrayList(u8) = .empty;
    try cmd.appendSlice(arena, "docker rm -f");
    for (cadvisor.known_proxies) |p| {
        try cmd.append(arena, ' ');
        try cmd.appendSlice(arena, p);
    }
    // `rm -f` errors on absent containers; `assertOnlyProxy` checks the result.
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
    // Verify the post-condition: a container ignoring SIGTERM would keep the
    // port and answer the next proxy's probe.
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

/// Base of the per-turn port pool for the cloud plaintext listener.
const proxy_port_base: u16 = 18080;
/// Ports reserved per profile (2x the current proxy count).
const proxy_port_slots: u16 = 8;
/// Base for the TLS listener: a separate block, so it can't collide with the
/// plaintext range (pinned by a test below).
const proxy_tls_port_base: u16 = 19080;

/// The ports a proxy listens on for one turn. The plaintext one always exists
/// (it carries the healthcheck); `tls` is null on plaintext profiles, where no
/// proxy renders a TLS listener (see compose.yaml x-proxy-common).
const Ports = struct {
    plain: u16,
    tls: ?u16,

    /// Where this profile's load goes. The `orelse` can't be reached, but fails
    /// one turn with a message rather than the run as `unreachable` would.
    fn target(self: Ports, p: profile.Profile) u16 {
        return if (p.tls) (self.tls orelse self.plain) else self.plain;
    }
};

/// Local mode uses fixed ports: bridge networking rebinds cleanly and
/// compose.yaml publishes exactly these.
const local_plain_port: u16 = 8080;
const local_tls_port: u16 = 8443;

fn portsFor(p: profile.Profile, fleet: Fleet, proxy_idx: usize) Ports {
    if (fleet.isLocal()) {
        return .{ .plain = local_plain_port, .tls = if (p.tls) local_tls_port else null };
    }
    return .{
        .plain = proxyPort(p, proxy_idx),
        .tls = if (p.tls) proxyTlsPort(p, proxy_idx) else null,
    };
}

/// A host port unique to this (profile, proxy) turn within one dispatch:
/// rebinding a port that just served load hit EADDRINUSE (runs #25, #26).
/// Keyed on `profile.all`'s compiled order, not the night's selection.
fn proxyPort(p: profile.Profile, proxy_idx: usize) u16 {
    return proxy_port_base + slot(p, proxy_idx);
}

/// The TLS listener's port for the same turn; see `proxyPort`.
fn proxyTlsPort(p: profile.Profile, proxy_idx: usize) u16 {
    return proxy_tls_port_base + slot(p, proxy_idx);
}

fn slot(p: profile.Profile, proxy_idx: usize) u16 {
    var profile_idx: u16 = 0;
    for (profile.all, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate.name, p.name)) {
            profile_idx = @intCast(i);
            break;
        }
    }
    return profile_idx * proxy_port_slots + @as(u16, @intCast(proxy_idx));
}

/// Environment prefix for a remote `docker compose` invocation. A missing
/// `BACKENDn_IP` doesn't fail loudly: compose substitutes "" and the proxy
/// quietly loses a pool member.
fn envPrefix(arena: Allocator, p: profile.Profile, fleet: Fleet, zoxy: ?ZoxySource, ports: ?Ports) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    // Cloud only (local uses docker DNS). One variable per member: `extra_hosts`
    // is a static list in the compose files.
    if (!fleet.isLocal()) {
        for (fleet.backend_ips, 0..) |ip, i| {
            try buf.print(arena, "BACKEND{d}_IP={s} ", .{ i, ip });
        }
    }
    // All three form zoxy's image tag, so `build` and `up` must get the same
    // trio; without them compose builds a floating main.
    if (zoxy) |z| {
        try buf.print(arena, "ZOXY_FLAVOUR={s} ZOXY_REF={s} ZOXY_CPU={s} ", .{ z.flavour, z.ref, z.cpu });
    }
    // Ports only for `start`. PROXY_TLS_PORT only on TLS profiles: unset means
    // no TLS listener (see compose.yaml x-proxy-common).
    if (ports) |pt| {
        try buf.print(arena, "PROXY_PORT={d} ", .{pt.plain});
        if (pt.tls) |tls_port| try buf.print(arena, "PROXY_TLS_PORT={d} ", .{tls_port});
    }
    for (p.proxy_env) |kv| {
        try buf.print(arena, "{s}={s} ", .{ kv.key, kv.value });
    }
    return buf.toOwnedSlice(arena);
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

test "the watchdog is the outer bound, so an inner deadline always fires first" {
    // Stages the watchdog covers beyond the ramp child's deadline (run #24).
    const outside_ramp = deadline.start + deadline.warm_probe + deadline.cadvisor_warm +
        deadline.teardown + 4 * deadline.inspect;

    for (&profile.all) |p| {
        const turn = deadline.turn(p.ramp_seconds, p.cooldown_s);
        const ramp_child = deadline.proxy(p.ramp_seconds);
        try std.testing.expect(turn > ramp_child + outside_ramp);
    }
}

test "a proxy's placeholder record is replaced in place, not duplicated" {
    // Mirrors `run`'s placeholder-then-overwrite pattern (run #28).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var records: std.ArrayList(artifact.ProxyRecord) = .empty;
    try records.append(arena, .{ .name = "zoxy", .status = .ok });

    // Simulates one proxy's turn: placeholder in, then overwritten.
    try records.append(arena, .{
        .name = "haproxy",
        .status = .failed,
        .err = "turn did not complete (the suite's watchdog ended the process before it could)",
    });
    try std.testing.expectEqual(@as(usize, 2), records.items.len);

    records.items[records.items.len - 1] = .{ .name = "haproxy", .status = .ok, .err = null };

    // Overwritten in place: one haproxy entry, holding the real result.
    try std.testing.expectEqual(@as(usize, 2), records.items.len);
    try std.testing.expectEqualStrings("haproxy", records.items[1].name);
    try std.testing.expectEqual(artifact.Status.ok, records.items[1].status);
    try std.testing.expect(records.items[1].err == null);
}

test "isKnownProxy names only proxies that run in a container" {
    try std.testing.expect(isKnownProxy("zoxy"));
    try std.testing.expect(!isKnownProxy("direct"));
    try std.testing.expect(!isKnownProxy("mystery"));
}

const test_fleet: Fleet = .{
    .proxy_ip = "10.10.0.12",
    .backend_ips = &.{ "10.10.0.13", "10.10.0.14", "10.10.0.15", "10.10.0.16" },
    .ssh = .{ .key_path = "k", .known_hosts = "kh" },
};

const test_zoxy_src: ZoxySource = .{ .flavour = "release", .ref = "v0.0.9", .cpu = "x86_64_v3" };

test "envPrefix carries EVERY backend address as well as the profile's tuning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try envPrefix(arena, profile.c10k, test_fleet, test_zoxy_src, .{ .plain = 18096, .tls = null });

    // A missing member doesn't fail the warm probe; it just skews the numbers.
    try std.testing.expect(std.mem.indexOf(u8, s, "BACKEND0_IP=10.10.0.13") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "BACKEND1_IP=10.10.0.14") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "BACKEND2_IP=10.10.0.15") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "BACKEND3_IP=10.10.0.16") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "PROXY_PORT=18096") != null);
    // c10k is plaintext: no TLS port.
    try std.testing.expect(std.mem.indexOf(u8, s, "PROXY_TLS_PORT") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_CONN_SLOTS=11457") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_UPSTREAM_SLOTS=11457") != null);
}

test "c1k widens zoxy's upstream pool to cover every endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // zoxy parks an upstream per endpoint, so the pool must be a multiple of
    // conn_slots.
    const s = try envPrefix(arena, profile.c1k, test_fleet, test_zoxy_src, null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_CONN_SLOTS=1386") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_UPSTREAM_SLOTS=5544") != null);
}

test "envPrefix hands compose all three variables in zoxy's image tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The three are the image tag; `build` and `up` must agree.
    const s = try envPrefix(arena, profile.c1k, test_fleet, test_zoxy_src, null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_FLAVOUR=release") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_REF=v0.0.9") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_CPU=x86_64_v3") != null);
}

test "the latest release is read off the redirect, not out of JSON" {
    // The shape curl lands on: …/releases/latest -> …/releases/tag/v0.0.9.
    try std.testing.expectEqualStrings(
        "v0.0.9",
        tagFromLatestUrl("https://github.com/zoxy-io/zoxy/releases/tag/v0.0.9").?,
    );
    // The un-redirected URL and error pages are not tags.
    try std.testing.expect(tagFromLatestUrl("https://github.com/zoxy-io/zoxy/releases/latest") == null);
    try std.testing.expect(tagFromLatestUrl("https://github.com/zoxy-io/zoxy/releases/tag/") == null);
    try std.testing.expect(tagFromLatestUrl("") == null);
}

test "a release tag is accepted, GitHub's error pages are not" {
    // Must reject anything that smuggles structure into a URL or docker tag.
    try std.testing.expect(isReleaseTag("v0.0.9"));
    try std.testing.expect(isReleaseTag("v1.2.3-rc1"));
    try std.testing.expect(!isReleaseTag("release")); // the unresolved request
    try std.testing.expect(!isReleaseTag("v")); // no version at all
    try std.testing.expect(!isReleaseTag("main"));
    try std.testing.expect(!isReleaseTag("v0.0.9/../../etc"));
    try std.testing.expect(!isReleaseTag("v0.0.9 && rm -rf /"));
    try std.testing.expect(!isReleaseTag(""));
}

test "envPrefix omits PROXY_PORT for the build step, which has no listener" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try envPrefix(arena, profile.c1k, test_fleet, test_zoxy_src, null);
    try std.testing.expect(std.mem.indexOf(u8, s, "PROXY_PORT") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "PROXY_TLS_PORT") == null);
}

test "a TLS profile gets a TLS listener and a plaintext one gets none" {
    // Plaintext profiles get no TLS port, keeping their numbers comparable.
    const plain = portsFor(profile.c1k, test_fleet, 1);
    try std.testing.expectEqual(@as(u16, proxy_port_base + 1 * proxy_port_slots + 1), plain.plain);
    try std.testing.expect(plain.tls == null);
    try std.testing.expectEqual(plain.plain, plain.target(profile.c1k));

    const tls = portsFor(profile.c1k_tls, test_fleet, 1);
    try std.testing.expect(tls.tls != null);
    try std.testing.expectEqual(tls.tls.?, tls.target(profile.c1k_tls));
    try std.testing.expect(tls.tls.? != tls.plain);

    // Local mode: fixed ports, TLS only when the profile asks.
    const local: Fleet = .{ .proxy_ip = "127.0.0.1", .backend_ips = &.{"127.0.0.1"}, .ssh = null };
    try std.testing.expectEqual(@as(u16, 8080), portsFor(profile.c1k, local, 3).plain);
    try std.testing.expect(portsFor(profile.c1k, local, 3).tls == null);
    try std.testing.expectEqual(@as(u16, 8443), portsFor(profile.c1k_tls, local, 3).tls.?);
}

test "the TLS turn carries both ports, and the profile's TLS engine pool" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ports = portsFor(profile.c1k_tls, test_fleet, 0);
    const s = try envPrefix(arena, profile.c1k_tls, test_fleet, test_zoxy_src, ports);

    // The plaintext listener stays for the healthcheck.
    try std.testing.expect(std.mem.indexOf(u8, s, "PROXY_PORT=") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "PROXY_TLS_PORT=") != null);
    // Pinned explicitly; zoxy's default is unrecorded and may change.
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_TLS_ENGINES=1024") != null);
}

test "backendProfile starts one member per VM in cloud, the whole pool locally" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Cloud VMs are host-networked: each starts only its own backend.
    try std.testing.expectEqualStrings("backend0", try test_fleet.backendProfile(arena, 0));
    try std.testing.expectEqualStrings("backend3", try test_fleet.backendProfile(arena, 3));

    const local: Fleet = .{ .proxy_ip = "127.0.0.1", .backend_ips = &.{"127.0.0.1"}, .ssh = null };
    try std.testing.expectEqualStrings("backend", try local.backendProfile(arena, 0));
}

test "proxyPort never repeats within one suite dispatch, including a proxy's own repeat turn across profiles" {
    var seen = std.AutoHashMap(u16, void).init(std.testing.allocator);
    defer seen.deinit();

    for (profile.all) |p| {
        // Generous upper bound — comfortably above today's 5-proxy set.
        for (0..proxy_port_slots) |proxy_idx| {
            // Both listeners share one namespace: a cross-range collision is
            // the port reuse this scheme prevents.
            for ([_]u16{ proxyPort(p, proxy_idx), proxyTlsPort(p, proxy_idx) }) |port| {
                try std.testing.expect(!seen.contains(port));
                try seen.put(port, {});
            }
        }
    }
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

test "the drop counter is read past the HELP and TYPE lines that share its name" {
    // HELP/TYPE lines match the grep and come first.
    try std.testing.expectEqual(@as(?u64, 4211), counterValue(
        \\# HELP zoxy_access_log_dropped access log lines dropped
        \\# TYPE zoxy_access_log_dropped counter
        \\zoxy_access_log_dropped 4211
        \\
    ));

    try std.testing.expectEqual(@as(?u64, 0), counterValue("zoxy_access_log_dropped 0\n"));

    // With labels, the value is the last field.
    try std.testing.expectEqual(@as(?u64, 7), counterValue("zoxy_access_log_dropped{sink=\"stdout\"} 7\n"));

    // Floats by spec: `12.0` must parse, not read as unknown.
    try std.testing.expectEqual(@as(?u64, 12), counterValue("zoxy_access_log_dropped 12.0\n"));

    // Absent or failed scrape: unknown, distinct from zero.
    try std.testing.expectEqual(@as(?u64, null), counterValue(""));
    try std.testing.expectEqual(@as(?u64, null), counterValue("# HELP zoxy_access_log_dropped nope\n"));
}

test "a stale zoxy build is detected, and an unrunnable check is not one" {
    const main_sha = "91d03b10f698256857615c2e256ce29548dfd51a";
    const other = "03308bfe33d2a0239cf2e40fe28e6a78686bb634";

    // The image baked an older commit than the ref: cache-bust failed.
    try std.testing.expect(isStaleBuild(other, main_sha));
    // The intended nightly state.
    try std.testing.expect(!isStaleBuild(main_sha, main_sha));

    // Either side unknown: the check did not run, so not stale.
    try std.testing.expect(!isStaleBuild(null, main_sha));
    try std.testing.expect(!isStaleBuild(other, null));
    try std.testing.expect(!isStaleBuild(null, null));
}

test "only a real commit sha counts as a resolved ref" {
    try std.testing.expect(isSha("91d03b10f698256857615c2e256ce29548dfd51a"));
    // GitHub error bodies resolve to unknown, not a mismatching commit.
    try std.testing.expect(!isSha("Not Found"));
    try std.testing.expect(!isSha("{\"message\":\"API rate limit exceeded\"}"));
    try std.testing.expect(!isSha(""));
    // Right length, not hex.
    try std.testing.expect(!isSha("z1d03b10f698256857615c2e256ce29548dfd51a"));
    // A short sha is not enough to compare against a full one.
    try std.testing.expect(!isSha("91d03b1"));
}

test "the version probe asks the container, and falls back to the image tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Proxies with a version CLI are asked inside the container.
    const hap = try versionProbe(arena, "haproxy");
    try std.testing.expect(std.mem.indexOf(u8, hap, "docker exec haproxy haproxy -v") != null);
    // stderr folded in, one line kept (haproxy appends a blurb).
    try std.testing.expect(std.mem.indexOf(u8, hap, "2>&1") != null);
    try std.testing.expect(std.mem.indexOf(u8, hap, "head -1") != null);

    try std.testing.expect(std.mem.indexOf(u8, try versionProbe(arena, "envoy"), "envoy --version") != null);
    try std.testing.expect(std.mem.indexOf(u8, try versionProbe(arena, "zoxy"), "zoxy --version") != null);

    // pingora has no version flag; its image tag carries the version.
    const ping = try versionProbe(arena, "pingora");
    try std.testing.expect(std.mem.indexOf(u8, ping, "docker inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, ping, "{{.Config.Image}}") != null);
}

test "the release pin is scoped to a run and survives between profiles" {
    // A release published mid-run must not split a run across two versions.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = ".zig-cache/tmp/pin-test";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    const run_dir = try std.fmt.allocPrint(arena, "{s}/results/run-1", .{root});
    const c1k = try std.fmt.allocPrint(arena, "{s}/c1k", .{run_dir});
    const c1k_tls = try std.fmt.allocPrint(arena, "{s}/c1k-tls", .{run_dir});
    try Io.Dir.cwd().createDirPath(io, c1k);

    // Nothing pinned yet: the first profile has to resolve for itself.
    try std.testing.expect(readZoxyPin(arena, io, c1k) == null);

    writeZoxyPin(io, c1k, "v0.5.1");

    // Another profile of the same run sees it.
    try std.testing.expectEqualStrings("v0.5.1", readZoxyPin(arena, io, c1k_tls).?);

    // A different run does not.
    const other = try std.fmt.allocPrint(arena, "{s}/results/run-2/c1k", .{root});
    try std.testing.expect(readZoxyPin(arena, io, other) == null);

    // A corrupted pin is refused rather than becoming an image tag.
    const pin_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ run_dir, zoxy_pin_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pin_path, .data = "v1.0.0; rm -rf /" });
    try std.testing.expect(readZoxyPin(arena, io, c1k) == null);
}

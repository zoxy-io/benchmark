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
    ///
    /// Everything that decides a result is passed explicitly (see `envPrefix`)
    /// rather than left to a `.env` in the working directory, which compose
    /// auto-loads with no opt-in and which — being gitignored — never reaches a
    /// VM, so it can only make a local run differ from the nightly. Explicit is
    /// enough on its own: compose gives the shell environment precedence over
    /// `.env`, so a stale file loses to what is set here.
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

    /// Bounds the warm-probe LOOP, because a single connect cannot be bounded:
    /// `Io.Threaded` panics outright on `netConnectIp` with a timeout ("TODO
    /// implement netConnectIpPosix with timeout"), so the per-attempt timeout has
    /// to be `.none` and a black-holed peer costs the OS SYN timeout — minutes,
    /// not seconds. Counting attempts alone would then let a wedged host hold the
    /// suite for the better part of an hour.
    const warm_probe: u64 = 90 * std.time.ns_per_s;

    /// The ramp child — start to exit, including the cAdvisor poller's teardown.
    ///
    /// Every deadline above bounds a REMOTE command. Everything in-process had
    /// none, which is how a single proxy came to hold the entire suite: nightly
    /// runs #9, #10 and #12 all stopped dead on zoxy at c10k, and #9 burned the
    /// workflow's whole 115-minute budget that way.
    fn proxy(ramp_seconds: u64) u64 {
        return (ramp_seconds * 2 + 300) * std.time.ns_per_s;
    }

    /// `ProxyWatchdog`'s window: one proxy's WHOLE turn, as the sum of every
    /// bounded stage inside it plus a grace margin.
    ///
    /// This must be strictly LONGER than the longest legitimate turn, and the
    /// arithmetic is the whole point. The watchdog's only move is to end the
    /// process, so if it fires while an inner deadline still had time left it
    /// converts a bound that would have cost ONE proxy into one that costs every
    /// proxy after it.
    ///
    /// Run #24 shipped exactly that inversion. The ramp had just been moved into
    /// a killable child so a wedge would be survivable — but both bounds were
    /// `proxy(ramp_seconds)`, and the watchdog starts a whole `start` +
    /// `identity` + `warm` earlier, so it always won the race. The child's
    /// deadline was unreachable by construction and haproxy still took pingora
    /// and envoy with it, in both profiles.
    ///
    /// Summed rather than "`proxy()` plus a round number" so that raising any
    /// stage bound above cannot silently re-introduce the inversion.
    fn turn(ramp_seconds: u64, cooldown_s: u64) u64 {
        return proxy(ramp_seconds) // ramp — the one stage bounded by a kill
        + start // container start
        + warm_probe // first 200
        + teardown // after runOne returns, still inside the window
        + 4 * inspect // leftover check, identity, image id, build-info
        + (cooldown_s + 60) * std.time.ns_per_s; // cooldown, plus grace
    }
};

/// The LAST-RESORT bound on one proxy's turn: the one that fires when a stage
/// that should have bounded itself did not.
///
/// Every stage inside a turn now has its own deadline and its own recovery — a
/// remote command times out and its child is killed, the ramp is a child process
/// and gets killed too, and either way `runOne` records that proxy `failed` and
/// the suite moves to the next one. This thread exists for what is left: an
/// in-process step with no deadline of its own (an artifact write, `io.sleep`,
/// the Io provider itself wedging), where there is nothing to cancel.
///
/// Its only move is to end the process, which is why `deadline.turn` is sized to
/// lose every race it can. Crude but bounded, and strictly better than the hang
/// it replaces: the profile's completed proxies are already flushed to
/// profile.json, cloud-init uploads them, and the runner gets a terminal marker
/// in minutes rather than polling a corpse until the step times out.
///
/// The stage pointer is the point. Run #12 hung with the proxy VM's CPU flat,
/// meaning the ramp had finished, and nothing recorded whether it died in the
/// ramp's cleanup (which cancels the cAdvisor poller — whose scrape has neither
/// a connect nor a read timeout) or afterwards in teardown. Naming the stage
/// turns the next occurrence into a bug report instead of a guess.
const ProxyWatchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    limit_ns: u64,
    name: []const u8,
    stage: *artifact.Stage,

    fn watch(self: *ProxyWatchdog) void {
        // A raw nanosleep, deliberately NOT `io.sleep`: the whole point is to
        // stay alive when the Io loop is the thing that has wedged.
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

    /// The kernel's socket census, printed just before giving up.
    ///
    /// A ramp that stops returning is usually blocked on something, and at 10k
    /// connections per proxy across several ramps the first suspect is ephemeral
    /// port exhaustion: `ip_local_port_range` gives ~64.5k ports, a closed
    /// connection holds one in TIME_WAIT for 60s, and the cooldown between
    /// proxies is 8s. The `tw` field is that count directly.
    ///
    /// Read from /proc rather than shelling out to `ss`, because this runs on a
    /// thread whose entire purpose is to work when the process is wedged —
    /// spawning a child is exactly the sort of thing that would hang too.
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

    /// How many of those sockets are actually ESTABLISHED.
    ///
    /// `inuse` above counts TCP sockets in ANY state, which is not the same
    /// thing and is the distinction that decides what the c10k stall IS:
    ///
    ///   CurrEstab ~= the offered connections -> both ends alive, stuck
    ///                mid-exchange, and the generator is not unwinding.
    ///   CurrEstab low, `inuse` high        -> the peer already closed and
    ///                these are CLOSE_WAIT sockets the generator never reaped.
    ///
    /// The second is not a remote possibility: haproxy is configured with
    /// `timeout client 60s` and `timeout http-keep-alive 60s`, so a healthy
    /// haproxy closes an idle connection a minute after the ramp ends — many
    /// minutes before this watchdog fires.
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

        // Two "Tcp:" lines — the header names the columns, the next holds the
        // values. Find CurrEstab's index in the first, read it from the second.
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

/// This binary's own path, resolved HERE rather than written as
/// `/proc/self/exe` into the command.
///
/// `remote.check` runs a command through `sh -c`, so a literal /proc/self/exe in
/// the command string resolves to the SHELL, not to bench — the first attempt at
/// spawning the ramp died with exit 127 that way. Resolving it in the parent also
/// keeps the guarantee that matters: the ramp is the same build as the suite that
/// spawned it, not whatever `bench` happens to be on PATH.
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

/// The image tag for a proxy whose build is a pure function of this repo, or
/// null for one that is not cacheable.
///
/// pingora qualifies: pinned Cargo.toml + Cargo.lock and a local src/, so the
/// image is identical run after run and the cache hits every time. It is also
/// the expensive one — 469s measured, against zoxy's 179s and haproxy's 1s.
///
/// zoxy is deliberately absent. It tracks floating `main` because the nightly
/// exists to catch a regression the morning after it lands, so a correctly-keyed
/// cache would miss on precisely the nights that matter — and a WRONGLY-keyed one
/// would silently benchmark a stale binary, which is the bug we spent today
/// removing from the Dockerfile's git clone.
fn cacheableImage(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "pingora")) return "zoxy-bench/pingora-http:0.8";
    return null;
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
    // Timed and announced, because this is where the wall clock actually goes.
    // Measured on run #16: 18 of its 37 minutes elapsed before the first request
    // was sent, and NOTHING was logged in that window — the ramps themselves
    // were exactly the 5 minutes they are configured to be. The fleet is
    // ephemeral, so there is no docker layer cache and zoxy is rebuilt from
    // source (git clone + zig ReleaseFast) on a 2-core VM every single run.
    // The Zig toolchain zoxy's Dockerfile does `FROM`, made to exist before it
    // is needed. Cached in Object Storage because it is a pure function of the
    // version and the architecture, so the 55 MB fetch from ziglang.org happens
    // only when someone bumps it — not on every ephemeral fleet, in the critical
    // path of an unattended run, which is how run #21 lost a profile.
    for (opts.proxies) |name| {
        if (!std.mem.eql(u8, name, "zoxy")) continue;
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

    var build_failed: std.StringHashMapUnmanaged(void) = .empty;
    for (opts.proxies) |name| {
        if (isDirect(name)) continue;
        redact.log("bench: [{s}] building", .{name});
        const t0 = Io.Timestamp.now(io, .awake);

        // A cache hit skips the build entirely. Only for proxies whose image is
        // a pure function of the repo — see `cacheableImage`.
        // `|| true` so a MISS is not logged as a failure: `remote.check` reports
        // any non-zero exit, and an empty cache is the normal state on the first
        // run with a given key. The marker file is what says "hit".
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
        // Say which it was. "built in 167s" after a FAILED build is how run #21
        // read, which is worse than silence.
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

        // Bound the WHOLE proxy, not just its ramp.
        //
        // This watchdog used to wrap `ramp.run` alone, and run #12 showed why
        // that is not enough: the proxy VM's CPU went flat the moment zoxy's
        // c10k ramp finished, and `bench` then sat there for over an hour
        // without the watchdog making a sound. Covering only the ramp cannot
        // even tell us WHERE it stopped — inside the ramp's own cleanup, which
        // cancels the cAdvisor poller, or after it returned, in teardown.
        //
        // It reads `stage`, so whatever it catches, the log names the step. That
        // is the difference between another silent hour and a diagnosis.
        //
        // `turn`, NOT `proxy`: covering the whole turn with the RAMP's bound made
        // this the first deadline to fire rather than the last, which is how a
        // wedged haproxy kept costing pingora and envoy their measurements even
        // after the ramp became killable. See `deadline.turn`.
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
/// Move to `next` and say so.
///
/// The uploaded log is the only window into an unattended run, and this suite
/// used to print nothing at all on the happy path — a healthy c1k went 51
/// minutes between its start and its one summary line, which is indistinguishable
/// from a wedged one. These lines are what make a run readable while it is still
/// running, and what localised the c10k hang to `[zoxy] ramp`.
fn enter(stage: *artifact.Stage, next: artifact.Stage, name: []const u8) void {
    stage.* = next;
    redact.log("bench: [{s}] {s}", .{ name, next.str() });
}

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
        // What the PREVIOUS proxy left behind on the proxy host, before this one
        // takes over. Bounded and best-effort — a diagnostic must never be able
        // to fail a run.
        //
        // haproxy completed a c10k ramp STANDALONE in run #19 and then wedged as
        // the third proxy in run #20, at c1k, which it had passed comfortably
        // before. So something accumulates across proxies. The loadgen is ruled
        // out — its census at the abort was 1004 established, `tw 2`, no port
        // pressure at all — and the proxy host is where nothing is visible.
        // `tw` here is the count that matters: this host makes an UPSTREAM
        // connection per client connection, so it burns ephemeral ports too, and
        // the cooldown between proxies is 8s against a 60s TIME_WAIT.
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
        _ = remote.check(
            gpa,
            arena,
            io,
            opts.fleet.proxyHost(),
            try std.fmt.allocPrint(arena, "start {s}", .{name}),
            try std.fmt.allocPrint(arena, "cd {s} && {s} {s} --profile {s} up -d --wait {s}", .{
                opts.fleet.remote_dir, try envPrefix(arena, p, opts.fleet), opts.fleet.composeCmd(), name, name,
            }),
            deadline.start,
        ) catch |e| {
            // `compose up --wait` only ever printed ITS OWN lifecycle events —
            // "Container zoxy Waiting" / "exited (1)" — never the crashed
            // process's own stderr. Run #25 had zoxy and haproxy both exit(1) the
            // instant they started at c10k, immediately after both had run c1k
            // cleanly on the same image, and there was nothing to read beyond
            // that they had died. `docker inspect` distinguishes an OOM kill
            // (OOMKilled=true, exit 137) from the container's own decision to
            // exit(1), and `docker logs` is the container's actual reason —
            // whichever it turns out to be, this is the one place to catch it,
            // since a wedge later in the ramp can't produce it: the container
            // never got that far.
            reportStartFailure(gpa, arena, io, opts.fleet, name);
            return e;
        };

        enter(stage, .identity, name);
        // Assert exactly this proxy is running before believing anything that
        // answers :8080. `compose up --wait` only gates on the container being
        // up, and with a healthcheck it gates on that container being healthy —
        // neither rules out a second, leftover container also bound to the port.
        try assertOnlyProxy(gpa, arena, io, opts.fleet, name);

        // How this image was compiled. Every proxy that records it gets read;
        // a mismatch in target CPU across proxies is a fairness violation that
        // is otherwise invisible in the numbers.
        //
        // Only proxies built here write the descriptor, so its ABSENCE is the
        // normal case for a stock image, not an error. The `|| true` matters:
        // without it a missing file exits 1 and gets logged as
        // "bench: build info failed (exit 1)", which reads like haproxy broke
        // when nothing did. An empty read is the signal, and a real error is
        // then only a transport failure worth hearing about.
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
                // Proxies built here compile for the host CPU, because that is
                // how they ship. haproxy does not: it is the stock upstream
                // image, a generic x86-64 build with no AVX. That asymmetry is
                // deliberate but must travel WITH the numbers — a reader
                // comparing a SIMD build against a baseline one should be told,
                // not left to infer it from a Dockerfile.
                if (std.mem.indexOf(u8, info, "cpu=native") != null or
                    std.mem.indexOf(u8, info, "SIMD") != null)
                {
                    try notes.append(arena, try std.fmt.allocPrint(
                        arena,
                        "compiled for this host's CPU with SIMD ({s}); stock images in this comparison are generic x86-64 builds",
                        .{info},
                    ));
                }
            } else {
                // Stock upstream image rather than one built here. Those are
                // compiled for a generic x86-64 baseline so they run anywhere —
                // haproxy:3.0-alpine carries zero AVX where a native build of
                // zoxy or pingora would get AVX2/AVX-512. That matches what the
                // proxies built here now target, so it is expected rather than a
                // problem; recorded so the parity stays checkable.
                build_info = "stock upstream image (generic x86-64 baseline)";
            }
        } else |_| {
            // Could not run the probe at all (ssh/docker failure), which is
            // different from the file being absent and should stay visible.
            try notes.append(arena, "could not read the image's build descriptor");
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

    enter(stage, .warm, name);
    try warmProbe(io, target, name);

    enter(stage, .ramp, name);
    const start_iso = try nowIso(io, arena);

    const cadvisor_addr: ?net.IpAddress = if (direct) null else try net.IpAddress.parse(opts.fleet.proxy_ip, 8081);

    const out_base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ opts.out_dir, name });

    // The ramp runs as a CHILD, on a hard deadline.
    //
    // It used to be an in-process call, which could not be bounded: once
    // `runner.run` blocks, zio owns this thread and there is nothing left to
    // unwind. The only available bound was `ProxyWatchdog` killing the whole
    // process, so a single wedged proxy took every proxy after it — runs #21 and
    // #22 each lost two that way, which is why pingora and envoy still have no
    // c10k measurement.
    //
    // As a separate process it can simply be killed (`remote.exec` does that on
    // deadline), and this proxy is recorded `failed` while the rest of the profile
    // proceeds. `Outcome` is scalars, handed back through a small JSON file.
    //
    // /proc/self/exe rather than a looked-up name: the child MUST be this exact
    // binary. The suite and the ramp sharing one build is the property that makes
    // "the agent drifted from the controller" impossible, and re-resolving it by
    // path would quietly give that up.
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
    // `exec` rather than `check`, for the hook alone.
    //
    // The socket census belongs to whichever bound actually fires, and now that
    // is this one rather than `ProxyWatchdog` — so making the ramp killable would
    // otherwise have silently taken the census with it, and `CurrEstab` vs `inuse`
    // is the measurement that decides what the c10k stall IS (see
    // `logEstablished`). It has to run BEFORE the kill: killing the ramp closes
    // every connection it holds, so a census read afterwards describes the
    // cleanup, not the wedge.
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
    // `stream_output` above has already printed both streams, line by line, as
    // they arrived — so there is deliberately no echo here. This used to replay a
    // 4 KB tail after the fact, which lost the earlier lines on a long ramp and
    // everything at all when the process did not survive to do the replay.
    if (!ramp_res.ok()) {
        var buf: [64]u8 = undefined;
        redact.log("bench: [{s}] ramp failed ({s})", .{ name, ramp_res.describe(&buf) });
        return error.RampFailed;
    }
    const outcome = try ramp.readOutcome(arena, io, outcome_path);
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
        if (elapsed >= deadline.warm_probe) {
            redact.log("bench: [{s}] never served 200 within {d}s", .{ name, deadline.warm_probe / std.time.ns_per_s });
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

/// Best-effort: why `name`'s container did not start.
///
/// Never returns an error — a diagnostic that could fail the run it is trying
/// to explain would defeat the point. Bounded by `deadline.inspect` per probe,
/// same as every other in-band inspection.
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
        const tail = res.stdout[res.stdout.len -| 2048 ..];
        redact.log("bench: [{s}] container log:\n{s}", .{ name, redact.scrub(&scrubbed, tail) });
    } else |_| {}
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

test "the watchdog is the outer bound, so an inner deadline always fires first" {
    // The stages the watchdog covers but the ramp child's own deadline does not.
    // Unless `turn` exceeds `proxy` by more than these, the watchdog — whose only
    // move is to end the process — fires while the child still had time left, and
    // one wedged proxy costs every proxy after it. That was run #24's bug: both
    // were `proxy(ramp_seconds)`, so haproxy still took pingora and envoy.
    const outside_ramp = deadline.start + deadline.warm_probe +
        deadline.teardown + 4 * deadline.inspect;

    for (&profile.all) |p| {
        const turn = deadline.turn(p.ramp_seconds, p.cooldown_s);
        const ramp_child = deadline.proxy(p.ramp_seconds);
        try std.testing.expect(turn > ramp_child + outside_ramp);
    }
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

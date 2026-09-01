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
const zio = @import("zio");
const zrk = @import("zrk");

const Allocator = std.mem.Allocator;

pub const Fleet = struct {
    proxy_ip: []const u8,
    /// The origin POOL, in the order terraform pinned it: index 0 is backend0.
    /// A slice rather than a count, so growing or shrinking the pool is a
    /// terraform + compose + proxy-config change and touches nothing here.
    ///
    /// Nothing reads a particular index any more — the order is kept only so
    /// `BACKENDn_IP` names the same host as terraform's `backendN` and the
    /// compose profile of the same name. It was load-bearing while `direct`
    /// measured `backend_ips[0]`.
    backend_ips: []const []const u8,
    /// null selects LOCAL mode: compose runs against this machine's docker
    /// daemon and both peers are loopback. The numbers a local run produces are
    /// NOT comparable to a fleet run — the generator shares CPU, cache and
    /// memory bandwidth with the proxy it is measuring, and the network the
    /// fleet crosses is replaced by loopback, which removes a network ceiling
    /// the cloud path demonstrably sits near. Local mode is for working on
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

    pub fn backendHost(self: Fleet, i: usize) remote.Host {
        return self.host(self.backend_ips[i]);
    }

    /// The compose profile that starts the single backend belonging to member
    /// `i` — `backend0`..`backend3`. Locally the whole pool comes up under the
    /// `backend` profile instead; in cloud each VM must start exactly its own,
    /// or four containers race for :9000 on one host.
    pub fn backendProfile(self: Fleet, arena: Allocator, i: usize) ![]const u8 {
        return if (self.isLocal())
            "backend"
        else
            std.fmt.allocPrint(arena, "backend{d}", .{i});
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
    /// PER POOL MEMBER, and they are started in sequence, so the pre-measurement
    /// phase is bounded by this times the pool size. Not folded into `turn`
    /// below: this runs once, before any proxy's turn, and a failure here aborts
    /// the whole profile rather than costing one proxy its slot.
    const backend_up: u64 = 180 * std.time.ns_per_s;
    const build: u64 = 900 * std.time.ns_per_s;
    /// Bounds ONE attempt; `build_attempts` of them may run. See the retry at
    /// the build call site for why this one is NOT in `turn`'s sum.
    const build_attempts: u32 = 2;
    const build_retry_backoff: u64 = 15 * std.time.ns_per_s;
    const start: u64 = 120 * std.time.ns_per_s;
    /// A transient registry pull hiccup or a stale port bind (runs #26, #30)
    /// shouldn't cost a proxy its entire night's data over one bad attempt.
    /// Retried at the `start` call site; MUST stay reflected in `turn`'s sum
    /// below or a retry sequence can re-introduce the run #24 watchdog
    /// inversion (a stage running long converts its own bound into one that
    /// costs every proxy after it).
    const start_attempts: u32 = 3;
    const start_retry_backoff: u64 = 15 * std.time.ns_per_s;
    const probe_each: u64 = 10 * std.time.ns_per_s;
    const teardown: u64 = 90 * std.time.ns_per_s;
    const inspect: u64 = 30 * std.time.ns_per_s;

    /// Bounds the warm-probe LOOP. `probeOnce`'s own connect() now carries
    /// `cadvisor.scrape_connect_timeout` (5s), so a single attempt can no
    /// longer hang indefinitely the way an unbounded connect() did — but
    /// `warm_probe_attempts` alone still has no wall-clock ceiling (30
    /// attempts at ~5s apiece plus the read and the retry sleep add up), so
    /// this stays as the belt to that suspenders.
    const warm_probe: u64 = 90 * std.time.ns_per_s;

    /// Bounds `cadvisor.waitUntilFound`'s poll, giving cAdvisor a head start
    /// before the ramp's own sampling window opens (see that function's doc
    /// comment — nightly run #28's motivation). Best-effort and non-fatal on
    /// its own, but it still runs BEFORE the ramp starts, inside the same
    /// turn the watchdog bounds, so it has to be counted in `turn` below —
    /// the whole point of summing every stage there is that forgetting one
    /// silently re-narrows the watchdog's margin over the ramp child's own
    /// deadline.
    const cadvisor_warm: u64 = 60 * std.time.ns_per_s;

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
        + start_attempts * start + (start_attempts - 1) * start_retry_backoff // container start, with retries
        + warm_probe // first 200
        + cadvisor_warm // cAdvisor discovery head start, before the ramp
        + teardown // after runOne returns, still inside the window
            // Every `deadline.inspect`-bounded probe runOne can make in one turn,
            // counted for the WORST case, which is zoxy — two of the six are only
            // asked of it. In order: sockets before start, the leftover/identity
            // container check, the image's build descriptor, zoxy's baked commit,
            // the running proxy's version, and zoxy's access-log drop counter.
            //
            // This read `4 * inspect` while the code made six such calls: the
            // commit probe was added without bumping it, and the drop counter would
            // have been the second. Undercounting here is exactly the run #24
            // failure mode — the watchdog wins a race it should always lose and one
            // slow proxy takes every proxy after it — so it is worth re-counting
            // this list whenever a probe is added, not just believing the comment.
        + 6 * inspect
            // Every ssh `check` in the turn can now pay `remote`'s transport-retry
            // budget on top of its own bound: the 6 probes above, one per `start`
            // attempt, and the teardown. Counted at the worst case for all of them
            // at once, which is the only reading that keeps the watchdog losing.
        + (6 + start_attempts + 1) * remote.connect_retry_budget_ns + (cooldown_s + 60) * std.time.ns_per_s; // cooldown, plus grace
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

/// How to ask a RUNNING container what version it is.
///
/// Asked of the container that actually served the ramp, not of compose.yaml:
/// the tag in the compose file is what was requested, and the point of
/// recording a version at all is to know what answered. `head -1` because
/// haproxy follows its version line with a support-lifetime blurb, and `2>&1`
/// because several of these write to stderr (nginx always does).
///
/// Proxies with no version CLI fall back to the image reference, which is where
/// their version lives anyway — pingora is built from a pinned Cargo.toml and
/// tagged with the pingora-core version it links (`pingora-http:0.8`).
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

/// What zoxy silently did LESS of than the other four while serving the ramp.
///
/// Both counters are read in ONE scrape, deliberately. `deadline.turn` budgets
/// a fixed number of `deadline.inspect`-bounded probes per turn and its comment
/// is explicit that adding one without bumping that sum re-introduces the run
/// #24 watchdog inversion — so a second counter arrives as a second grep
/// pattern, not as a second probe.
const ZoxyCounters = struct {
    /// Access-log lines dropped.
    ///
    /// Every proxy in the comparison access-logs every request, and they do not
    /// agree about what happens when the sink cannot keep up. nginx, haproxy and
    /// pingora write once per request and wear the cost. envoy buffers and
    /// flushes on a timer. zoxy does neither: it DROPS the line and counts it,
    /// rather than let logging stall its event loop.
    ///
    /// That is a legitimate design choice and not a cheat — but it is also work
    /// zoxy did not do and the other four did, so left unmeasured it arrives as
    /// throughput.
    access_log_dropped: ?u64 = null,

    /// Connections refused for want of a TLS session slot.
    ///
    /// zoxy holds one preallocated TLS engine per admitted connection and sheds
    /// past the pool's size, where the other four allocate per connection and
    /// have no such ceiling. The TLS profiles size the pool to `conn_slots` for
    /// exactly that reason (profile.zig's `ZOXY_TLS_ENGINES`); a nonzero value
    /// here means the pool was reached anyway and the ramp measured zoxy's
    /// admission cap rather than its TLS.
    ///
    /// Always null on a plaintext profile — zoxy has no TLS listener then, and
    /// the metric is absent rather than zero.
    shed_tls_engines: ?u64 = null,
};

/// Scrape zoxy's admin endpoint for both counters.
///
/// Asked over zoxy's admin listener, which answers the same Prometheus text for
/// any path (`admin.bind` in config.template.json). Reached from INSIDE the
/// container over bash's /dev/tcp — the mechanism compose's healthcheck already
/// uses against this image — because the admin port is published in neither
/// mode and the runtime image carries no curl.
///
/// Best-effort: nulls on any failure, which the caller reports as unread
/// counters rather than as clean zeroes.
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

/// The value of the first real sample line whose metric name contains `needle`.
///
/// One scrape carries both counters now, so the name has to be matched here as
/// well as in the shell's grep — taking the first sample line would give
/// whichever counter zoxy happened to render first.
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

/// The value of the first real sample line in a scrap of Prometheus text.
///
/// `# HELP` and `# TYPE` lines carry the metric's own name, so a grep for it
/// matches them too and they arrive first. They are skipped HERE rather than in
/// the shell pipeline above, where excluding them would be one more layer of
/// quoting to get right across both ssh and `sh -c`.
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
        // Prometheus samples are floats by specification even when the counter
        // behind them is an integer, so an exporter is free to render `0.0`.
        if (std.fmt.parseFloat(f64, v)) |f| {
            if (f >= 0) return @intFromFloat(@round(f));
        } else |_| {}
    }
    return null;
}

/// Ask GitHub what `ref` points at right now, as plain text.
///
/// `Accept: application/vnd.github.sha` makes the commits endpoint answer with
/// the bare 40-character sha instead of a commit object, so nothing on the VM
/// has to parse JSON — there is no jq on the fleet image.
///
/// Run on the PROXY HOST rather than the runner because that is the box with
/// egress to GitHub in the nightly's network layout, and because it is the same
/// path the Dockerfile's cache-bust `ADD` takes: if this resolves, so did that.
///
/// Best-effort by design. Losing the freshness check must never cost the run —
/// it returns null and the record simply carries no `zoxy_ref_sha`, which the
/// comparison below treats as "unknown", not as "stale".
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

/// Where tonight's zoxy binary comes from, resolved once before any build.
///
/// `profile.zoxy_ref` is a REQUEST, and `release` is the one value of it that
/// is not a git ref — it means "whatever the latest published release is",
/// which only becomes a buildable tag once GitHub has been asked. Resolving it
/// here, rather than letting the word `release` reach compose, is also what
/// keeps the build step and the start step agreeing: both interpolate this same
/// string into the image tag, and a tag resolved twice could resolve twice
/// differently.
pub const ZoxySource = struct {
    /// Selects the stage in proxies/zoxy/Dockerfile.
    flavour: []const u8,
    /// A git ref for `source`; a release tag (`v0.0.9`) for `release`.
    ref: []const u8,
    /// The cpu model the binary is really built for — ours to choose only on
    /// the source path. A release is compiled by upstream's own workflow with
    /// `-Dcpu=x86_64_v3`, so that is what the image tag and profile.json must
    /// say about it, whatever this host happens to be.
    cpu: []const u8,

    fn isSource(self: ZoxySource) bool {
        return std.mem.eql(u8, self.flavour, "source");
    }
};

/// Turn `profile.zoxy_ref` into a concrete `ZoxySource`, or null if `release`
/// could not be resolved.
///
/// Null is NOT a fallback to the source build. The two flavours measure
/// different binaries — a release is upstream's x86_64_v3 artifact, a source
/// build is this host's `native` — so quietly substituting one for the other
/// would change what the night measured without changing what it reports.
///
/// The latest tag comes off the `releases/latest` redirect rather than the JSON
/// API: the fleet image has no jq, and `-w %{url_effective}` after `-L` lands
/// on `…/releases/tag/<tag>` with nothing to parse.
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

/// The resolved release tag for THIS RUN, shared by every profile in it.
///
/// `release` means "whatever is latest right now", and the fleet runs one
/// `bench suite` per profile (cloud-init's loop) — so a release published
/// between two profiles makes one night measure two different zoxy versions.
/// That is not hypothetical: the 2026-08-23 06:43 nightly measured c1k on
/// v0.5.1 and c1k-tls on v0.6.0, because v0.6.0 published at 07:04 in the gap.
/// The numbers then sit in one report, under one runid, with nothing saying
/// they are not the same binary.
///
/// So the first profile of a run writes the tag it resolved next to the run's
/// results, and every later profile reads it back instead of asking GitHub
/// again. Keyed on the run directory rather than on a flag, so it needs no
/// change to cloud-init's loop, works identically under `--local`, and cannot
/// leak between runs.
///
/// Only the `release` flavour needs this. A source ref is whatever the profile
/// asked for and does not move between profiles; the commit it points at can
/// still drift mid-run, which is what `zoxy_ref_sha`'s freshness check is for.
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
    // Re-validated on the way in: a truncated or hand-edited pin must not
    // become an image tag.
    return if (isReleaseTag(tag)) tag else null;
}

fn writeZoxyPin(io: Io, out_dir: []const u8, tag: []const u8) void {
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const path = zoxyPinPath(fba.allocator(), out_dir) orelse return;
    // Best-effort: losing the pin costs a second resolve, not the run.
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = tag }) catch {};
}

/// The tag out of the URL `…/releases/latest` redirects to.
///
/// Null on anything else, which covers the interesting failure: GitHub serves
/// an error or a rate limit as a normal page with a 200 and curl reports the
/// URL it landed on, so "the request worked" says nothing about whether the
/// answer is a release.
fn tagFromLatestUrl(url: []const u8) ?[]const u8 {
    const marker = "/releases/tag/";
    const at = std.mem.lastIndexOf(u8, url, marker) orelse return null;
    const tag = url[at + marker.len ..];
    return if (isReleaseTag(tag)) tag else null;
}

/// A `v`-prefixed tag with nothing in it that a shell, a URL or an image tag
/// would read as structure.
///
/// The same guard `isSha` is: GitHub answers an outage or a rate limit with a
/// perfectly well-formed page, and this string goes on to become part of a
/// download URL and a docker tag.
fn isReleaseTag(s: []const u8) bool {
    if (s.len < 2 or s.len > 32 or s[0] != 'v' or !std.ascii.isDigit(s[1])) return false;
    for (s[1..]) |c| {
        if (!std.ascii.isDigit(c) and c != '.' and c != '-' and !std.ascii.isAlphabetic(c)) return false;
    }
    return true;
}

/// A full 40-character hex commit sha.
///
/// Guards the freshness check against its own inputs: GitHub answers a bad ref
/// or a rate limit with a JSON error body and a 200-shaped curl exit, and
/// treating "Not Found" as a commit would report every build as stale.
fn isSha(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Whether the zoxy that ran is a different commit than the ref pointed at when
/// the build started.
///
/// Unknown on either side is NOT stale. An unreachable GitHub or an unreadable
/// commit file is a check that could not run, and reporting that as a stale
/// build would train readers to ignore the one signal that matters.
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

    // --- the certificate every proxy terminates TLS with, on a TLS profile.
    //
    // ONE certificate for all five, made before anything starts, because the key
    // is part of what is being measured: a signature is per handshake, and an
    // RSA-2048 key would charge one proxy several hundred microseconds of CPU
    // per connection that a P-256 key does not. Five self-signed certs, or five
    // proxies each shipping its own, would be five different experiments.
    //
    // P-256 specifically. zoxy accepts nothing else (its config docs: "ECDSA
    // P-256 or P-384", because an RSA signature would stall its single event
    // loop for milliseconds), so it is the only curve on which the comparison
    // can be like-for-like at all.
    //
    // Made on the PROXY HOST rather than committed to the repo: a private key in
    // a public repository is a permanent secret-scanner alarm for something that
    // exists for one night, and the fleet is ephemeral, so "generate if absent"
    // is once per run in cloud and once ever in a local checkout.
    //
    // The KEY PAIR is made only for a profile that terminates TLS, and its
    // failure is fatal for that profile: every proxy's TLS listener loads these
    // files, so without them nothing starts, and five identical start failures
    // are much harder to read than one message saying the certificate could not
    // be made. A plaintext profile never asks for the pair, and so cannot be
    // failed by a missing `openssl`.
    //
    // The DIRECTORY is made on every profile, and that is not tidiness. Every
    // proxy bind-mounts ./proxies/tls in every profile (compose cannot mount a
    // path conditionally), and dockerd CREATES A MISSING BIND SOURCE ITSELF, as
    // root. A plaintext profile running first would therefore leave a
    // root-owned directory that the TLS profile's `openssl`, running as the
    // unprivileged run user on the same host, cannot write into — a failure
    // that would only ever appear in a dispatch that ran both profiles, in that
    // order, which is exactly the nightly.
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

    // --- the origin pool every proxy forwards to.
    //
    // The bash driver tolerated a backend failure with `|| true` and then died
    // 25s later on the first proxy's warm probe, because `curl -sf` fails on the
    // 502 a proxy returns with a dead origin. That bought nothing except moving
    // the diagnosis away from the cause.
    //
    // ALL-OR-NOTHING across the pool, for a sharper version of the same reason:
    // a missing member does not fail anything, it just makes every proxy
    // round-robin a quarter of its requests into a refused connection. That
    // produces a complete set of plausible-looking numbers describing a fleet
    // that was never whole. Locally the first iteration starts the entire pool
    // (one `backend` profile) and the rest are no-ops against the same daemon.
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
    // Which zoxy, and from where — resolved FIRST, because it decides how much
    // of the rest of this phase has to happen at all. A release flavour is a
    // download; a source flavour is a toolchain, a clone and a compile.
    //
    // Only asked when zoxy is in tonight's set: resolving `release` costs a
    // round trip to GitHub and a run of the other four has no use for the
    // answer.
    const wants_zoxy = for (opts.proxies) |name| {
        if (std.mem.eql(u8, name, "zoxy")) break true;
    } else false;
    const zoxy_src = if (wants_zoxy) blk: {
        // A tag already pinned by an earlier profile of this run wins, and
        // skips the round trip entirely. See `zoxy_pin_name`.
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

    // The Zig toolchain zoxy's Dockerfile does `FROM`, made to exist before it
    // is needed. Cached in Object Storage because it is a pure function of the
    // version and the architecture, so the 55 MB fetch from ziglang.org happens
    // only when someone bumps it — not on every ephemeral fleet, in the critical
    // path of an unattended run, which is how run #21 lost a profile.
    //
    // Skipped entirely unless zoxy is being COMPILED. BuildKit does not resolve
    // a stage the target does not reach, so a release build never looks at
    // `FROM zoxy-bench/zig` and there is nothing for this to make exist.
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

    // What `profile.zoxy_ref` points at RIGHT NOW, resolved before the build so
    // the comparison afterwards is against the commit this build should have
    // picked up. Resolving it after the ramps instead would make a legitimate
    // mid-run push to zoxy look identical to a stale build.
    //
    // Only worth asking when zoxy is actually in tonight's set.
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
        // Nothing to build zoxy FROM. Recorded as a build failure so it reads
        // like one, rather than as a proxy that mysteriously never started.
        if (std.mem.eql(u8, name, "zoxy") and zoxy_src == null) {
            try build_failed.put(arena, name, {});
            redact.log("bench: [zoxy] BUILD SKIPPED — no resolved source", .{});
            continue;
        }
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
            const cmd = try std.fmt.allocPrint(arena, "cd {s} && {s} {s} --profile {s} build {s}", .{
                opts.fleet.remote_dir,
                envPrefix(arena, p, opts.fleet, zoxy_src, null) catch "",
                opts.fleet.composeCmd(),
                name,
                name,
            });
            // Retried, for the same reason `start` is: a build reaches the
            // network — a registry pull, a git clone, four zig dependency
            // fetches — and one transient failure out there costs this proxy
            // the entire night. Run 30749146321 lost zoxy that way, to a build
            // that had succeeded 20 minutes earlier and succeeded again 40
            // minutes later on the same commit.
            //
            // NOT counted in `deadline.turn`, unlike the start retries: the
            // build phase runs before any proxy's turn and no watchdog covers
            // it. The budget it does spend against is the workflow's — two
            // `wait` chunks of 3300s — where a worst case of
            // `build_attempts * deadline.build` per proxy still fits.
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

        // A PLACEHOLDER, overwritten below once this proxy's turn actually
        // finishes. Written and flushed to disk BEFORE the risky work starts,
        // so if the watchdog below has to end the whole process, there is
        // already a `.failed` record for this proxy on disk instead of none
        // at all.
        //
        // Run #28: envoy wedged as the LAST proxy in the list, the watchdog
        // fired `std.process.exit(4)`, and the process died before `runOne`
        // ever returned — so the normal `records.append` + `flush.write` a
        // few lines below never ran for envoy. It had no entry whatsoever in
        // profile.json, not even a failed one, so it silently vanished from
        // every report rather than showing up as failed. `std.process.exit`
        // also does not touch the ramp CHILD process (`.pgid = 0` gives it
        // its own group, and exiting the parent does not signal it), so the
        // watchdog's only real recovery is making sure THIS record survives.
        try records.append(arena, .{
            .name = name,
            .status = .failed,
            .stage = stage,
            .err = "turn did not complete (the suite's watchdog ended the process before it could)",
        });
        try flush.write();

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

        const rec = runOne(gpa, arena, io, opts, name, proxy_idx, zoxy_src, zoxy_ref_sha, &stage) catch |e| blk: {
            redact.log("bench: [{s}] {s} at stage {s}", .{ name, @errorName(e), stage.str() });
            break :blk artifact.ProxyRecord{
                .name = name,
                .status = .failed,
                .stage = stage,
                .err = @errorName(e),
            };
        };
        // Overwrites the placeholder appended above — this proxy's turn
        // reached here, so its real result replaces the "did not complete"
        // stand-in rather than adding a second entry for the same proxy.
        records.items[records.items.len - 1] = rec;
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
    proxy_idx: usize,
    // Where tonight's zoxy came from, resolved before the build. Only zoxy uses
    // it, but every proxy's compose invocation carries it: these variables are
    // in zoxy's image tag, and `up` has to name the tag `build` produced.
    zoxy_src: ?ZoxySource,
    // What that ref resolved to before the build, or null if GitHub could not
    // be reached. Only zoxy uses it; see the freshness check below.
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
    // Set when the running zoxy is NOT the commit `profile.zoxy_ref` pointed at
    // when the build ran, which makes tonight's zoxy numbers a measurement of
    // some other commit than the one the report will name.
    var stale_build = false;

    // `https` on a TLS profile — the scheme is what zrk's URL parser turns into
    // a TLS connection, and what `ramp.run` reads back to decide whether to skip
    // verification. The host is an IP literal either way (zoxy does no DNS, and
    // a hostname would drag zrk's untimed resolver into the measurement), so
    // there is no name to verify and no SNI to send: the certificate is
    // self-signed and the generator is run with verification off. See
    // `ensureTlsMaterial`.
    const target = try std.fmt.allocPrint(arena, "{s}://{s}:{d}{s}", .{
        if (p.tls) "https" else "http",
        opts.fleet.proxy_ip,
        port,
        p.req_path,
    });

    {
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
                }
                // A stale port bind (run #26, EADDRINUSE) and a registry hiccup
                // (run #30, Docker Hub auth "context deadline exceeded" while
                // pulling haproxy) are both transient — either previously cost a
                // proxy its entire night over one failed attempt. `deadline.turn`
                // already budgets for every attempt here, so retrying does not
                // risk the watchdog inversion from run #24.
                redact.log("bench: [{s}] start attempt {d}/{d} failed, retrying", .{
                    name, start_attempt, deadline.start_attempts,
                });
                io.sleep(.fromNanoseconds(deadline.start_retry_backoff), .awake) catch {};
            }
        }

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
                // The asymmetry that runs the OTHER way, and the reason both
                // belong here rather than only the flattering one. zoxy ships
                // ReleaseSafe on purpose (upstream 1573c16) so a field report
                // carries a real panic rather than undefined behaviour; the
                // other four proxies are release builds with no equivalent
                // checks. It is a priced trade, not a defect — but the price
                // lands in this profile's throughput, so a reader comparing the
                // rows has to be told it was paid.
                if (std.mem.indexOf(u8, info, "ReleaseSafe") != null) {
                    try notes.append(
                        arena,
                        "built ReleaseSafe: Zig's bounds/overflow/unreachable checks stay on in the hot path, " ++
                            "which measured -12.7% sustained against the same code at ReleaseFast (c1k, 2x2 over " ++
                            "v0.1.0/v0.2.1); the other proxies here are built without equivalent checks",
                    );
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

            // Is that actually what tonight's ref pointed at? On the source
            // path the Dockerfile busts its clone layer on what the ref POINTS
            // AT, so this should always agree — which is exactly why it is
            // worth asserting. If that mechanism ever breaks, every night
            // afterwards keeps publishing a frozen commit under the name "main"
            // and the trend reads as stability. On the release path both sides
            // are resolutions of the same TAG, so agreement is nearly given;
            // what remains is a tag that moved mid-run, and the binary's own
            // `zoxy --version` is the independent witness there.
            //
            // Silent when either side is unknown: an unreachable GitHub is a
            // missing check, not a failed one.
            const asked_for = if (zoxy_src) |z| z.ref else profile.zoxy_ref;
            if (isStaleBuild(zoxy_commit, zoxy_ref_sha)) {
                stale_build = true;
                redact.log(
                    "bench: [zoxy] STALE BUILD: ran {s} but {s} is {s}",
                    .{ zoxy_commit.?, asked_for, zoxy_ref_sha.? },
                );
                // Prepended, not appended: this has to be the first thing a
                // reader sees about the row, ahead of the build-parity note
                // already sitting there.
                try notes.insert(arena, 0, try std.fmt.allocPrint(
                    arena,
                    "STALE BUILD — ran zoxy {s}, but {s} was {s} when this build ran; " ++
                        "these numbers are not a measurement of {s}",
                    .{ zoxy_commit.?, asked_for, zoxy_ref_sha.?, asked_for },
                ));
            }
        }

        // What the running proxy says it is. Last of the provenance probes so a
        // version failure cannot cost the ones above.
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

    // Unconditional now: every proxy in the comparison runs in a container on
    // the proxy host. It used to be optional because `direct` had no container
    // to sample.
    const cadvisor_addr: ?net.IpAddress = try net.IpAddress.parse(opts.fleet.proxy_ip, 8081);

    {
        // warmProbe (via probeOnce) and cadvisor.waitUntilFound both hand a
        // real `cadvisor.scrape_connect_timeout` down to `addr.connect`. `io`
        // here is this suite's top-level `Io.Threaded` (from process.Init),
        // which panics outright on any connect timeout but `.none` — see
        // cadvisor.scrape's doc comment. Only zio's real Runtime supports
        // one, so give these two probes their own, scoped tightly so its
        // executor thread doesn't outlive them.
        var probe_rt = try zio.Runtime.init(arena, .{});
        defer probe_rt.deinit();
        const probe_io = probe_rt.io();

        try warmProbe(gpa, probe_io, target, name);

        // Best-effort: give cAdvisor a bounded head start before the ramp
        // opens its own 300s sampling window. See cadvisor.waitUntilFound's
        // doc comment for why — a miss here just gets logged, never fails
        // the turn.
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

    // Asked HERE, after the ramp and before `teardownProxy` removes the
    // container: the counter is cumulative over the process's life, so it has
    // to be read while that process is still alive, and reading it before the
    // ramp would only ever report zero.
    const counters: ZoxyCounters = if (std.mem.eql(u8, name, "zoxy"))
        zoxyCounters(gpa, arena, io, opts.fleet)
    else
        .{};
    const access_log_dropped = counters.access_log_dropped;

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
                // NOT degraded, on the `saturated` precedent above rather than
                // the `stale_build` one below: the ramp measured the proxy it
                // says it did, so the record is usable — it just carries a
                // caveat the reader has to be handed.
                //
                // And degrading here would cost more than it bought.
                // `index.zig`'s previousSustained skips degraded nights when it
                // picks a regression baseline, so a counter that is routinely
                // nonzero at saturation would leave zoxy with no baseline at
                // all and quietly switch its regression detection off — trading
                // a visible caveat for an invisible blind spot.
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

        // The TLS admission cap, on a TLS profile. Nonzero means the profile
        // sized `tls_engines` too small for the offered connections and the
        // ramp measured that ceiling rather than zoxy's TLS — the same failure
        // mode `zoxy_shed_upstream_slots` describes for the upstream pool, and
        // the fix is the same: raise it in profile.zig, or accept that the
        // number is about the cap.
        //
        // Not degraded, on the access-log precedent: the ramp measured the
        // proxy it says it did, and degrading zoxy routinely would cost it its
        // regression baseline in index.zig's previousSustained.
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
        // The ramp itself is fine — some zoxy really was measured — so this is
        // not `failed`. But it is not the commit the report names, and a
        // trend point that silently repeats last night's binary is worse than
        // an absent one, so it must never render as a plain `ok`.
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
        // The RESOLVED ref, not the request: on the release flavour `zoxy_ref`
        // is the word "release" until GitHub answers, and a report that named
        // it that could not say which zoxy it measured.
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

/// Poll the target until it serves. Runs from the loadgen so it exercises the
/// real path, and reports only the proxy name and attempt count — never the
/// target URL, which carries a private address.
///
/// "The real path" is why this speaks TLS on a TLS profile rather than probing
/// the plaintext listener that is also up. The container healthcheck already
/// proves the proxy forwards; what only this can prove is that the listener the
/// ramp is about to hammer completes a handshake. A proxy whose cert failed to
/// load usually does not start at all — but one that starts and then rejects
/// every handshake would otherwise reach the ramp and be recorded as a proxy
/// that served nothing.
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

/// Bounds `probeOnce`'s connect. This used to be `cadvisor.scrape_connect_timeout`,
/// borrowed because it bounded exactly this; `cadvisor.scrape` now carries a
/// whole-request deadline rather than a connect timeout, so the constant lives
/// with its only remaining user.
const probe_connect_timeout: Io.Timeout = .{
    .duration = .{ .raw = .fromNanoseconds(5 * std.time.ns_per_s), .clock = .awake },
};

fn probeOnce(gpa: Allocator, io: Io, addr: net.IpAddress, path: []const u8, use_tls: bool) !void {
    // Bounded the same way and for the same reason as cadvisor.scrape's
    // connect: `warmProbe`'s own elapsed-vs-`deadline.warm_probe` check above
    // only runs BETWEEN attempts, so an unbounded connect() here could wedge
    // this proxy's whole turn on a single hung attempt, same class of failure
    // that cost entire nightly runs before cadvisor.zig's fix. Reusing
    // cadvisor's constant rather than a second magic number for the same bound.
    var stream = try addr.connect(io, .{ .mode = .stream, .timeout = probe_connect_timeout });
    defer stream.close(io);

    if (!use_tls) {
        var wbuf: [512]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        var rbuf: [1024]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        return probeExchange(&w.interface, &r.interface, path);
    }

    // zrk's own TLS transport, not a second implementation of one: the ramp
    // that follows this probe handshakes through exactly this code, so a
    // handshake this accepts is one the measurement will accept too.
    //
    // HEAP, and not a stack local: the state is ~92 KiB of record buffers as of
    // zrk 2.4.0's zssl engine (`@sizeOf` 94432 — two 16645-byte out buffers, a
    // wire record, a reassembly buffer and the read/write pair), and the client
    // stores pointers into them and into the stream adapters beside them, so it
    // cannot be moved once `handshake` has run.
    const st = try gpa.create(zrk.tls.State);
    defer gpa.destroy(st);
    // `init` then `deinit`, not a `.{}` literal: as of zrk 2.4.0 the session is
    // zssl's and `State` is an undefined block with no field defaults — `init`
    // writes the one field (`live`) that makes every other method safe to call,
    // and `deinit` is what hands the session back. A literal stopped compiling
    // rather than stopped working, which is the good direction for this to fail.
    st.init();
    defer st.deinit();
    // `insecure`: the certificate is self-signed and generated per run (see
    // `ensureTlsMaterial`), and the target is an IP literal, so there is neither
    // a chain to trust nor a name to match. This is the same setting the ramp
    // runs under — `ramp.run` sets `cfg.insecure` from the profile — so the
    // probe cannot accept a handshake the measurement would reject.
    // `alpn_http1` — zrk 2.x offers ALPN, and this probe speaks HTTP/1.1.
    // Offering what the ramp offers keeps the probe unable to accept a
    // handshake the measurement would reject, which is the point of the
    // `insecure` note above.
    try st.handshake(io, gpa, stream, tls_probe_host, true, null, zrk.tls.alpn_http1);
    return probeExchange(st.writer(), st.reader(), path);
}

/// The name offered as SNI, and never verified.
///
/// It IS on the wire now: zrk's zssl client sends SNI even under `-k`, on the
/// argument that a server needing it to pick a certificate needs it either way.
/// Zig's std TLS client, which zrk 2.4.0 replaced, sent none when verification
/// was off — so this went from a value the API demanded to a value the peer
/// reads. Harmless here and checked rather than assumed: no proxy in this
/// comparison selects a certificate by name (each has exactly one), and every
/// TLS listener is an `http` one, so zoxy's L4 SNI routing is not in the path
/// either. It is not a hostname any of them is configured for.
const tls_probe_host = "bench";

/// One request/response over whichever transport the caller opened.
///
/// One flush, as of zrk 2.x. It used to be two, and the reason is worth keeping
/// because the failure was invisible: under `std.crypto.tls` the TLS writer
/// only ENCRYPTED into a socket writer's buffer, so ciphertext did not reach
/// the wire until that second writer was flushed too. Miss it and the handshake
/// still completes — everything looks healthy right up until nothing arrives.
/// Four of the five proxies closed the connection and haproxy answered `408
/// Request Time-out`, which is what this probe did to every proxy in the first
/// c1k-tls run.
///
/// zrk 2.0.0 moved to ztls, whose std.Io integration writes to the socket
/// itself, so there is no second buffer to forget; zrk's own connection.zig
/// dropped its matching double flush in the same change. `State` no longer
/// exposes a `swriter` at all, which is how this was found rather than
/// silently kept.
fn probeExchange(w: *Io.Writer, r: *Io.Reader, path: []const u8) !void {
    try w.print("GET {s} HTTP/1.1\r\nHost: bench\r\nConnection: close\r\n\r\n", .{path});
    try w.flush();

    const line = try r.takeDelimiterInclusive('\n');
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
        const tail = res.stdout[res.stdout.len -| 2048..];
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

/// Where the proxies' certificate and key live, relative to the payload root —
/// the directory compose bind-mounts into every proxy at /etc/bench/tls.
const tls_dir = "proxies/tls";

/// Make the certificate and key every proxy's TLS listener loads, if they are
/// not there already.
///
/// Three files, because the five proxies disagree about packaging and none of
/// them can be talked out of it: haproxy wants ONE pem holding the chain and the
/// key (`crt`), everyone else wants them separate. Generating both forms here is
/// cheaper than a per-image conversion step, and keeps every proxy loading
/// byte-identical key material.
///
/// `genpkey` and not `ecparam -genkey`, which is the older spelling of the same
/// thing: `ecparam` writes SEC1 (`BEGIN EC PRIVATE KEY`) and `genpkey` writes
/// PKCS#8 (`BEGIN PRIVATE KEY`). Every stack in this comparison reads PKCS#8;
/// SEC1 is the one a rustls-based proxy would reject outright, and a key format
/// that works on four proxies and not the fifth is not a fair certificate.
/// Both invocations are old enough to work under LibreSSL too, which is what
/// `openssl` is on a developer's Mac running `--local`.
///
/// `ec_param_enc:named_curve` is load-bearing and was found by running it. Left
/// off, LibreSSL writes the curve as EXPLICIT PARAMETERS rather than as the
/// prime256v1 OID, and two of the five proxies then refuse the certificate
/// outright — zoxy with `CertificateFieldHasWrongDataType`, envoy with "Failed
/// to load certificate chain" — while nginx, haproxy and pingora accept it. The
/// fleet's OpenSSL 3 defaults to named_curve and would never have shown this;
/// a laptop `--local` run is where it surfaces, which is exactly the kind of
/// difference that makes a local run worth having.
///
/// The certificate is never verified by anything — self-signed, an IP-literal
/// target, and the generator runs with verification off (see `probeOnce` and
/// `ramp.run`) — so its subject and 10-year lifetime are only there to keep
/// every proxy's own parser happy.
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
            // World-readable on purpose: envoy and haproxy run as non-root
            // inside their containers and have to read this mount.
            "chmod 0644 {s}/bench.key {s}/bench.crt {s}/bench.pem; fi && " ++
            // The post-condition, not the exit status of the `if`: an empty
            // or half-written pem must fail HERE, with this message, rather
            // than as five proxies that mysteriously refuse to start.
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
/// Carries the backend pool's addresses as well as the profile's proxy tuning.
/// compose.cloud.yaml interpolates them into every proxy's `extra_hosts` (zoxy
/// does no DNS, so the origin must be an address literal) and into haproxy's
/// BACKENDn_ADDR. Omitting one does not fail loudly — compose substitutes an
/// empty string and the proxy starts with `extra_hosts: "backend2:"`, so the
/// failure surfaces much later as a warm probe that never gets a 200, or worse,
/// as a proxy that serves three quarters of its requests and looks merely slow.
/// Base of the per-turn port pool used for the CLOUD proxy listener, so a
/// proxy's Nth start on this host never has to reuse the exact host port its
/// (N-1)th start used.
const proxy_port_base: u16 = 18080;
/// Headroom per profile's block. Current profiles run at most 4
/// container-backed proxies (zoxy, haproxy, pingora, envoy); double that so a
/// slightly longer proxy list still cannot spill into the next profile's
/// block.
const proxy_port_slots: u16 = 8;
/// The same scheme, one block further up, for the TLS listener every proxy also
/// carries. Separate from the plaintext base rather than interleaved with it, so
/// the two ranges cannot collide however many profiles or proxies are added: a
/// profile's plaintext block and its TLS block grow in parallel, and `19080` is
/// far enough above `18080 + profiles * slots` to stay clear for any plausible
/// number of either. The test below is what actually holds that.
const proxy_tls_port_base: u16 = 19080;

/// The ports a proxy listens on for one turn.
///
/// The plaintext one is always there: it carries the container healthcheck in
/// every profile, TLS included, because three of the five images have neither
/// curl nor openssl and bash's /dev/tcp cannot handshake. The TLS one is
/// `null` on a plaintext profile and no proxy renders a TLS listener at all
/// then — see compose.yaml's x-proxy-common for the measurement that decided
/// that (zoxy preallocates its TLS session pool: 68 MiB against 234 MiB).
const Ports = struct {
    plain: u16,
    tls: ?u16,

    /// Where this profile's load goes.
    ///
    /// The `orelse` cannot be reached — `portsFor` assigns a TLS port for
    /// exactly the profiles that ask for one, and the test below pins that —
    /// but it fails loudly rather than being `unreachable`: the warm probe
    /// would then handshake against a plaintext listener and `ramp.run` would
    /// refuse the mismatched transport, either of which costs one proxy its
    /// turn with a message. `unreachable` in a ReleaseFast build costs the run.
    fn target(self: Ports, p: profile.Profile) u16 {
        return if (p.tls) (self.tls orelse self.plain) else self.plain;
    }
};

/// Local mode never varies either port: bridge networking rebinds cleanly
/// (Docker's own NAT layer, not a raw app bind()), and compose.yaml publishes
/// exactly these two on the host, so varying them would mean varying a static
/// mapping for no reason.
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

/// A host port for this (profile, proxy) turn, distinct from every other
/// turn `bench suite` could run in one dispatch — including this SAME
/// proxy's own turn in a DIFFERENT profile.
///
/// Runs #25 and #26: zoxy and haproxy both refused to start — `docker logs`
/// (via `reportStartFailure`) showed a literal EADDRINUSE, "cannot bind
/// socket (Address in use) for [0.0.0.0:8080]" — on their SECOND start
/// within a run, immediately after running a full ramp under real load on
/// their FIRST. An isolated, traffic-free bind/teardown/rebind cycle on the
/// same host port, under the same `network_mode: host`, reproduces cleanly
/// every time — so whatever holds the port only outlives teardown when the
/// prior occupant actually served load, and the exact mechanism is still
/// open. Giving every turn its own port makes the question moot rather than
/// answered: nothing before a turn could ever be bound to the port it is
/// about to use, regardless of what the mechanism turns out to be.
///
/// Keyed off `profile.all`'s COMPILED order, not the night's BENCH_PROFILES
/// selection, so a subset (tonight: c100,c1k) still gets fixed,
/// non-overlapping blocks — c10k's block stays reserved even on a night
/// that never runs it, so re-enabling it later cannot collide with tonight's
/// ports by coincidence.
fn proxyPort(p: profile.Profile, proxy_idx: usize) u16 {
    return proxy_port_base + slot(p, proxy_idx);
}

/// The TLS listener's port for the same turn. Distinct from every plaintext
/// port and from every other turn's TLS port, for exactly the reasons
/// `proxyPort` is: this listener is bound on every turn too, so it burns and
/// releases a host port on the same schedule.
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

fn envPrefix(arena: Allocator, p: profile.Profile, fleet: Fleet, zoxy: ?ZoxySource, ports: ?Ports) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    // Only the cloud overlay interpolates BACKENDn_IP; locally the proxies reach
    // the pool by compose service name over docker DNS. One variable per member
    // because `extra_hosts` is a static YAML list — compose has no way to expand
    // a delimited string into entries, so the count is fixed in the compose
    // files and this just has to agree with it.
    if (!fleet.isLocal()) {
        for (fleet.backend_ips, 0..) |ip, i| {
            try buf.print(arena, "BACKEND{d}_IP={s} ", .{ i, ip });
        }
    }
    // Without this, compose falls back to `${ZOXY_REF:-main}` and builds a
    // floating main rather than the ref this run resolved — see profile.zig's
    // note. All three travel together and all three are in the image tag, so
    // the `build` call and the `up` call must be handed the SAME trio or the
    // second one looks for a tag the first never produced.
    if (zoxy) |z| {
        try buf.print(arena, "ZOXY_FLAVOUR={s} ZOXY_REF={s} ZOXY_CPU={s} ", .{ z.flavour, z.ref, z.cpu });
    }
    // Only for the `start` call — `build` has no listener to bind and no
    // meaningful per-turn port, so it passes null and every proxy's config
    // falls back to its own compose-level `${PROXY_PORT:-8080}` default.
    //
    // PROXY_TLS_PORT is emitted ONLY for a TLS profile, and its absence is what
    // makes every proxy render no TLS listener at all: compose turns an unset
    // variable into an empty one (`${PROXY_TLS_PORT:-}`), and each proxy's
    // config treats empty as off. See compose.yaml's x-proxy-common for why a
    // plaintext turn must not carry a TLS listener it never uses.
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
    // The stages the watchdog covers but the ramp child's own deadline does not.
    // Unless `turn` exceeds `proxy` by more than these, the watchdog — whose only
    // move is to end the process — fires while the child still had time left, and
    // one wedged proxy costs every proxy after it. That was run #24's bug: both
    // were `proxy(ramp_seconds)`, so haproxy still took pingora and envoy.
    const outside_ramp = deadline.start + deadline.warm_probe + deadline.cadvisor_warm +
        deadline.teardown + 4 * deadline.inspect;

    for (&profile.all) |p| {
        const turn = deadline.turn(p.ramp_seconds, p.cooldown_s);
        const ramp_child = deadline.proxy(p.ramp_seconds);
        try std.testing.expect(turn > ramp_child + outside_ramp);
    }
}

test "a proxy's placeholder record is replaced in place, not duplicated" {
    // Pins the exact pattern `run`'s measurement loop uses: append a
    // placeholder before the risky work, then overwrite the SAME index once
    // the real result is known — so a process that dies in between (the
    // watchdog's std.process.exit) leaves the placeholder as the final,
    // on-disk record instead of leaving no record at all. Run #28: envoy's
    // c100 turn had no entry whatsoever in profile.json for exactly this
    // reason, before this pattern existed.
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

    // Overwritten in place, not appended alongside — exactly one "haproxy"
    // entry, holding the REAL result.
    try std.testing.expectEqual(@as(usize, 2), records.items.len);
    try std.testing.expectEqualStrings("haproxy", records.items[1].name);
    try std.testing.expectEqual(artifact.Status.ok, records.items[1].status);
    try std.testing.expect(records.items[1].err == null);
}

test "isKnownProxy names only proxies that run in a container" {
    try std.testing.expect(isKnownProxy("zoxy"));
    // `direct` was the one entry in BENCH_PROXIES with no container. It is gone
    // from the comparison entirely now, so this is no longer a special case —
    // an unknown name is just unknown.
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

    // Miss one and that proxy starts with extra_hosts "backendN:" — which does
    // not fail its warm probe, because the other three still answer. It just
    // round-robins a quarter of its requests into a refused connection and
    // reports a number that looks like a slow proxy.
    try std.testing.expect(std.mem.indexOf(u8, s, "BACKEND0_IP=10.10.0.13") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "BACKEND1_IP=10.10.0.14") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "BACKEND2_IP=10.10.0.15") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "BACKEND3_IP=10.10.0.16") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "PROXY_PORT=18096") != null);
    // c10k is plaintext, so no TLS port travels and every proxy renders no TLS
    // listener at all.
    try std.testing.expect(std.mem.indexOf(u8, s, "PROXY_TLS_PORT") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_CONN_SLOTS=11457") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_UPSTREAM_SLOTS=11457") != null);
}

test "c1k widens zoxy's upstream pool to cover every endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // zoxy parks a keep-alive upstream PER ENDPOINT, and round-robin makes one
    // downstream connection rotate through all four — so the upstream pool has
    // to be a multiple of conn_slots, not equal to it. Equal is what shipped
    // before the origin became a pool, and it would shed here.
    const s = try envPrefix(arena, profile.c1k, test_fleet, test_zoxy_src, null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_CONN_SLOTS=1386") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_UPSTREAM_SLOTS=5544") != null);
}

test "envPrefix hands compose all three variables in zoxy's image tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Not three independent settings: they are the tag. Emit two of them at
    // `build` and three at `up` and compose looks for an image nothing built.
    const s = try envPrefix(arena, profile.c1k, test_fleet, test_zoxy_src, null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_FLAVOUR=release") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_REF=v0.0.9") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_CPU=x86_64_v3") != null);
}

test "the latest release is read off the redirect, not out of JSON" {
    // The shape curl actually lands on, checked against the live endpoint when
    // this was written: …/releases/latest -> …/releases/tag/v0.0.9.
    try std.testing.expectEqualStrings(
        "v0.0.9",
        tagFromLatestUrl("https://github.com/zoxy-io/zoxy/releases/tag/v0.0.9").?,
    );
    // Never followed anywhere — the un-redirected URL is not a tag, and neither
    // is a rate-limit or error page served with a 200.
    try std.testing.expect(tagFromLatestUrl("https://github.com/zoxy-io/zoxy/releases/latest") == null);
    try std.testing.expect(tagFromLatestUrl("https://github.com/zoxy-io/zoxy/releases/tag/") == null);
    try std.testing.expect(tagFromLatestUrl("") == null);
}

test "a release tag is accepted, GitHub's error pages are not" {
    // `isReleaseTag` guards a string that becomes part of a download URL and a
    // docker tag, so the shapes that must fail are the ones that would smuggle
    // structure into either.
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
    // The plaintext profiles must come out with NO TLS port at all: that is
    // what leaves the listener out of every proxy's rendered config, which is
    // what keeps their numbers — zoxy's memory above all — comparable to every
    // night before TLS existed here.
    const plain = portsFor(profile.c1k, test_fleet, 1);
    try std.testing.expectEqual(@as(u16, proxy_port_base + 1 * proxy_port_slots + 1), plain.plain);
    try std.testing.expect(plain.tls == null);
    try std.testing.expectEqual(plain.plain, plain.target(profile.c1k));

    const tls = portsFor(profile.c1k_tls, test_fleet, 1);
    try std.testing.expect(tls.tls != null);
    try std.testing.expectEqual(tls.tls.?, tls.target(profile.c1k_tls));
    try std.testing.expect(tls.tls.? != tls.plain);

    // Local mode publishes exactly the two ports compose.yaml maps on the host,
    // and still only asks for the TLS one when the profile terminates TLS.
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

    // The plaintext listener stays — it is what the container healthcheck
    // probes on every profile, TLS included.
    try std.testing.expect(std.mem.indexOf(u8, s, "PROXY_PORT=") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "PROXY_TLS_PORT=") != null);
    // The TLS session pool the profile pinned. Without it zoxy takes its own
    // default, which is unstated in the run record and free to move between
    // releases — and it is the pool this profile's connections have to fit in.
    try std.testing.expect(std.mem.indexOf(u8, s, "ZOXY_TLS_ENGINES=1024") != null);
}

test "backendProfile starts one member per VM in cloud, the whole pool locally" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // In cloud each backend VM must start ONLY its own container: the overlay
    // is host-networked, so bringing up the shared `backend` profile there
    // would have four containers race for :9000 on one host.
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
            // BOTH listeners, in one namespace: every turn binds a plaintext
            // and a TLS socket, so a collision between the two ranges would be
            // exactly the port reuse this scheme exists to make impossible —
            // and it would show up as a proxy that cannot start, one turn after
            // the range grew past 19080.
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
    // What the grep actually returns: a scrape matches the metric's own name in
    // its comment lines too, and those arrive FIRST. Taking the first line
    // would parse a sentence, not a count.
    try std.testing.expectEqual(@as(?u64, 4211), counterValue(
        \\# HELP zoxy_access_log_dropped access log lines dropped
        \\# TYPE zoxy_access_log_dropped counter
        \\zoxy_access_log_dropped 4211
        \\
    ));

    // The clean case, which is the one that means the comparison is fair.
    try std.testing.expectEqual(@as(?u64, 0), counterValue("zoxy_access_log_dropped 0\n"));

    // Labels sit between the name and the value, so the value is the LAST
    // field rather than the second.
    try std.testing.expectEqual(@as(?u64, 7), counterValue("zoxy_access_log_dropped{sink=\"stdout\"} 7\n"));

    // Prometheus samples are floats by specification even when the counter is
    // an integer; an exporter rendering `0.0` must not read as "unknown",
    // which the caller reports very differently from zero.
    try std.testing.expectEqual(@as(?u64, 12), counterValue("zoxy_access_log_dropped 12.0\n"));

    // Absent counter, or a scrape that failed and produced nothing: unknown.
    // The caller must be able to tell this from a genuine zero.
    try std.testing.expectEqual(@as(?u64, null), counterValue(""));
    try std.testing.expectEqual(@as(?u64, null), counterValue("# HELP zoxy_access_log_dropped nope\n"));
}

test "a stale zoxy build is detected, and an unrunnable check is not one" {
    const main_sha = "91d03b10f698256857615c2e256ce29548dfd51a";
    const other = "03308bfe33d2a0239cf2e40fe28e6a78686bb634";

    // The failure this exists for: the image baked some older commit while the
    // ref had moved on. That is the Dockerfile's cache-bust having failed.
    try std.testing.expect(isStaleBuild(other, main_sha));
    // The intended nightly state.
    try std.testing.expect(!isStaleBuild(main_sha, main_sha));

    // Neither side known == the check did not run. Reporting these as stale
    // would fire on every night GitHub is unreachable and teach a reader to
    // ignore the warning that matters.
    try std.testing.expect(!isStaleBuild(null, main_sha));
    try std.testing.expect(!isStaleBuild(other, null));
    try std.testing.expect(!isStaleBuild(null, null));
}

test "only a real commit sha counts as a resolved ref" {
    try std.testing.expect(isSha("91d03b10f698256857615c2e256ce29548dfd51a"));
    // What GitHub actually answers with when the check cannot be made: an
    // error body, which must resolve to "unknown" rather than to a commit that
    // then mismatches and reports a false stale build.
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

    // Proxies that can answer for themselves are asked directly, inside the
    // container that served the ramp rather than of compose.yaml.
    const hap = try versionProbe(arena, "haproxy");
    try std.testing.expect(std.mem.indexOf(u8, hap, "docker exec haproxy haproxy -v") != null);
    // stderr folded in and one line kept: haproxy follows its version with a
    // support-lifetime blurb, and several of these write to stderr.
    try std.testing.expect(std.mem.indexOf(u8, hap, "2>&1") != null);
    try std.testing.expect(std.mem.indexOf(u8, hap, "head -1") != null);

    try std.testing.expect(std.mem.indexOf(u8, try versionProbe(arena, "envoy"), "envoy --version") != null);
    try std.testing.expect(std.mem.indexOf(u8, try versionProbe(arena, "zoxy"), "zoxy --version") != null);

    // pingora has no version flag; its version is the pingora-core release it
    // links, which is what its image tag carries.
    const ping = try versionProbe(arena, "pingora");
    try std.testing.expect(std.mem.indexOf(u8, ping, "docker inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, ping, "{{.Config.Image}}") != null);
}

test "the release pin is scoped to a run and survives between profiles" {
    // The bug: cloud-init runs one `bench suite` per profile, each resolving
    // `release` independently, so a release published mid-run splits a night
    // across two zoxy versions (2026-08-23 06:43: c1k on v0.5.1, c1k-tls on
    // v0.6.0). The pin is what makes the second profile agree with the first.
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

    // A DIFFERENT profile of the SAME run sees it, which is the whole point.
    try std.testing.expectEqualStrings("v0.5.1", readZoxyPin(arena, io, c1k_tls).?);

    // A different run does not.
    const other = try std.fmt.allocPrint(arena, "{s}/results/run-2/c1k", .{root});
    try std.testing.expect(readZoxyPin(arena, io, other) == null);

    // A corrupted pin is refused rather than becoming an image tag.
    const pin_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ run_dir, zoxy_pin_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pin_path, .data = "v1.0.0; rm -rf /" });
    try std.testing.expect(readZoxyPin(arena, io, c1k) == null);
}

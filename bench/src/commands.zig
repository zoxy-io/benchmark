//! The subcommands that talk to the cloud: `sweep`, `wait`, `fetch`, `suite`.
//! Failure policies differ: `sweep` is best-effort and never blocks a run;
//! `wait` fails loudly, since no marker means no data.

const std = @import("std");
const Io = std.Io;
const zrk = @import("zrk");

const artifact = @import("artifact.zig");
const profile = @import("profile.zig");
const redact = @import("redact.zig");
const remote = @import("remote.zig");
const suite = @import("suite.zig");
const ycs = @import("ycs.zig");

const Allocator = std.mem.Allocator;

pub const Env = struct {
    token: []const u8 = "",
    folder: []const u8 = "",
    bucket: []const u8 = "",
    webhook: []const u8 = "",
    runid: []const u8 = "",

    pub fn read(environ: std.process.Environ) Env {
        return .{
            .token = get(environ, "YC_TOKEN"),
            .folder = get(environ, "YC_FOLDER_ID"),
            .bucket = get(environ, "BENCH_BUCKET"),
            .webhook = get(environ, "DISCORD_WEBHOOK"),
            .runid = get(environ, "BENCH_RUNID"),
        };
    }

    pub fn get(environ: std.process.Environ, key: []const u8) []const u8 {
        const v = std.process.Environ.getPosix(environ, key) orelse return "";
        return v;
    }
};

/// Delete every instance labelled `bench=nightly`.
/// Delete every instance labelled `bench=nightly`: recovers VMs whose
/// terraform state died with a cancelled runner (labels survive, state may
/// not). Never fatal; orphans cost less than a red nightly.
pub fn sweep(gpa: Allocator, arena: Allocator, io: Io, env: Env) !u8 {
    if (env.token.len == 0 or env.folder.len == 0) {
        std.debug.print("bench sweep: YC_TOKEN and YC_FOLDER_ID are required\n", .{});
        return 2;
    }

    var client = ycs.Client.init(gpa, io, env.token);
    defer client.deinit();

    const instances = client.listInstances(arena, env.folder) catch |e| {
        std.debug.print("bench sweep: could not list instances ({s}); continuing\n", .{@errorName(e)});
        return 0;
    };

    var deleted: usize = 0;
    for (instances) |inst| {
        const label = inst.bench_label orelse continue;
        if (!std.mem.eql(u8, label, "nightly")) continue;

        // Never print the instance's addresses.
        std.debug.print("bench sweep: deleting orphan {s} (runid {s})\n", .{
            inst.name,
            inst.runid_label orelse "unknown",
        });
        client.deleteInstance(inst.id) catch |e| {
            std.debug.print("bench sweep: could not delete {s}: {s}\n", .{ inst.name, @errorName(e) });
            continue;
        };
        deleted += 1;
    }

    if (deleted == 0) {
        std.debug.print("bench sweep: no orphaned instances\n", .{});
    } else {
        std.debug.print("bench sweep: deleted {d} orphaned instance(s)\n", .{deleted});
    }
    return 0;
}

pub const WaitOptions = struct {
    /// Overall bound, so a wedged VM cannot hold the workflow to its own timeout.
    deadline_s: u64 = 110 * 60,
    poll_s: u64 = 30,
    /// No boot marker by here means cloud-init failed. Catches a loadgen whose
    /// payload fetch failed and writes nothing at all.
    boot_deadline_s: u64 = 15 * 60,
};

pub const WaitResult = enum { done, failed, timed_out, never_booted };

/// Poll Object Storage for the run's terminal marker, echoing the uploaded log
/// as it grows.
pub fn wait(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: Env,
    opts: WaitOptions,
) !WaitResult {
    var client = ycs.Client.init(gpa, io, env.token);
    defer client.deinit();

    const keys: ycs.Keys = .{ .runid = env.runid };
    const done_key = try keys.done(arena);
    const failed_key = try keys.failed(arena);
    const log_key = try keys.log(arena);
    const boot_key = try keys.bootOk(arena, "loadgen");

    var shown: usize = 0;
    var booted = false;

    // Monotonic elapsed, not summed sleeps: the polls take time too, and drift
    // would outlast the caller's chunk timeout (see main.zig `--max-wait-s`).
    const started = Io.Timestamp.now(io, .awake);
    const deadline_ns = opts.deadline_s * std.time.ns_per_s;
    const boot_deadline_ns = opts.boot_deadline_s * std.time.ns_per_s;

    while (true) {
        const elapsed_ns = started.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        if (elapsed_ns >= deadline_ns) break;

        // Echo new log. `logAnyIp`, not `redact.log`: this runs on the CI runner,
        // which never registered the fleet's addresses.
        if (client.get(arena, env.bucket, log_key)) |maybe| {
            if (maybe) |text| {
                if (text.len > shown) {
                    redact.logAnyIp(text[shown..]);
                    shown = text.len;
                }
            }
        } else |_| {}

        if (client.exists(env.bucket, done_key) catch false) return .done;
        if (client.exists(env.bucket, failed_key) catch false) return .failed;

        if (!booted) {
            booted = client.exists(env.bucket, boot_key) catch false;
            if (!booted and elapsed_ns >= boot_deadline_ns) {
                std.debug.print(
                    "bench wait: the loadgen never wrote its boot marker after {d}s — " ++
                        "cloud-init did not finish, so no result will ever arrive\n",
                    .{@divTrunc(elapsed_ns, std.time.ns_per_s)},
                );
                return .never_booted;
            }
        }

        io.sleep(.fromNanoseconds(opts.poll_s * std.time.ns_per_s), .awake) catch break;
    }

    std.debug.print("bench wait: no terminal marker after {d}s\n", .{opts.deadline_s});
    return .timed_out;
}

/// Download and unpack the run's artifacts.
pub fn fetch(gpa: Allocator, arena: Allocator, io: Io, env: Env, out_dir: []const u8) !u8 {
    var client = ycs.Client.init(gpa, io, env.token);
    defer client.deinit();

    const keys: ycs.Keys = .{ .runid = env.runid };
    const tar = (try client.get(arena, env.bucket, try keys.results(arena))) orelse {
        std.debug.print("bench fetch: no results.tar for this run\n", .{});
        return 1;
    };

    try Io.Dir.cwd().createDirPath(io, out_dir);
    const path = try std.fmt.allocPrint(arena, "{s}/results.tar", .{out_dir});
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(f, io, &buf);
    try fw.interface.writeAll(tar);
    try fw.interface.flush();

    const res = try remote.exec(gpa, io, &.{ "tar", "-xf", path, "-C", out_dir }, .{
        .deadline_ns = 120 * std.time.ns_per_s,
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (!res.ok()) {
        std.debug.print("bench fetch: could not unpack results.tar\n", .{});
        return 1;
    }

    std.debug.print("bench fetch: unpacked into {s}\n", .{out_dir});
    return 0;
}

/// Run one profile's suite. Executes ON the loadgen VM.
pub fn runSuite(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: std.process.Environ,
    prof: profile.Profile,
    proxies: []const []const u8,
    runid: []const u8,
    local: bool,
) !u8 {
    const fleet: suite.Fleet = if (local) blk: {
        // Local: the base compose file publishes 8080, 9000 and cAdvisor 8081.
        std.debug.print(
            "bench suite: LOCAL run — the generator shares this machine with the proxy it is\n" ++
                "  measuring and the network is loopback, so these numbers are not comparable to a\n" ++
                "  fleet run. Recorded as fleet=local, banner-marked, and kept out of the trend.\n",
            .{},
        );
        break :blk .{
            .proxy_ip = "127.0.0.1",
            // One entry: locally one `backend up` starts the whole pool, reached
            // over docker DNS.
            .backend_ips = &.{"127.0.0.1"},
            .ssh = null,
            .remote_dir = ".",
        };
    } else blk: {
        const proxy_ip = Env.get(environ, "PROXY_IP");
        const ssh_key = Env.get(environ, "SSH_KEY");
        const backend_ips = try parseBackendIps(arena, Env.get(environ, "BACKEND_IPS"));
        if (proxy_ip.len == 0 or backend_ips.len == 0 or ssh_key.len == 0) {
            std.debug.print("bench suite: PROXY_IP, BACKEND_IPS and SSH_KEY are required (or pass --local)\n", .{});
            return 2;
        }

        // Scrub these from logs (and CI-mask them).
        redact.register(proxy_ip);
        for (backend_ips) |ip| redact.register(ip);

        const known_hosts = Env.get(environ, "SSH_KNOWN_HOSTS");
        break :blk .{
            .proxy_ip = proxy_ip,
            .backend_ips = backend_ips,
            .ssh = .{
                .key_path = ssh_key,
                .known_hosts = if (known_hosts.len > 0) known_hosts else "/home/ubuntu/.ssh/known_hosts",
            },
        };
    };

    const out_dir = try std.fmt.allocPrint(arena, "results/{s}/{s}", .{ runid, prof.name });
    try Io.Dir.cwd().createDirPath(io, out_dir);

    const res = try suite.run(gpa, arena, io, .{
        .prof = prof,
        .proxies = proxies,
        .runid = runid,
        .out_dir = out_dir,
        .fleet = fleet,
    });

    var ok: usize = 0;
    var bad: usize = 0;
    // Tracked apart: a night without zoxy has no headline or trend point.
    var zoxy_lost = false;
    for (res.records) |r| {
        if (r.status.usable()) ok += 1 else bad += 1;
        if (std.mem.eql(u8, r.name, "zoxy") and !r.status.usable()) zoxy_lost = true;
    }
    std.debug.print("bench suite [{s}]: {d} usable, {d} failed/skipped\n", .{ prof.name, ok, bad });
    if (zoxy_lost) std.debug.print("bench suite [{s}]: zoxy produced no usable data\n", .{prof.name});

    // Exit 3: ran but incomplete, so the workflow publishes and still goes red.
    // A lost zoxy reddens the run so nightly-retry.yml fires (run 30749146321);
    // a lost yardstick proxy does not.
    if (res.aborted or ok == 0 or zoxy_lost) return 3;
    return 0;
}

/// Split `BACKEND_IPS` into the origin pool, preserving order: entry N is
/// `backendN` / `BACKENDn_IP`. Blank entries are dropped (a trailing comma
/// must not become an empty backend); an empty spec yields an empty slice.
pub fn parseBackendIps(arena: Allocator, spec: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const ip = std.mem.trim(u8, raw, " \t");
        if (ip.len == 0) continue;
        try out.append(arena, ip);
    }
    return out.toOwnedSlice(arena);
}

test "parseBackendIps keeps pool order and drops blanks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ips = try parseBackendIps(arena, "10.10.0.13,10.10.0.14, 10.10.0.15 ,10.10.0.16,");
    try std.testing.expectEqual(@as(usize, 4), ips.len);
    // Order matters: entry N must stay backendN.
    try std.testing.expectEqualStrings("10.10.0.13", ips[0]);
    try std.testing.expectEqualStrings("10.10.0.15", ips[2]);
    try std.testing.expectEqualStrings("10.10.0.16", ips[3]);

    // The caller turns this into a usage error.
    try std.testing.expectEqual(@as(usize, 0), (try parseBackendIps(arena, "")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parseBackendIps(arena, " , ")).len);
}

/// Split a comma-separated list, rejecting names the suite does not know, so
/// a typo is loud rather than a silent gap in the comparison.
pub fn parseProxies(arena: Allocator, spec: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        if (!knownProxy(name)) {
            std.debug.print("bench: unknown proxy '{s}'\n", .{name});
            return error.UnknownProxy;
        }
        try out.append(arena, name);
    }
    if (out.items.len == 0) return error.NoProxies;
    return out.toOwnedSlice(arena);
}

/// Removed proxies (`direct`, traefik) are deleted, not parked, so a stale
/// `BENCH_PROXIES` fails loudly.
const all_proxies = [_][]const u8{
    "zoxy", "haproxy", "nginx", "pingora", "envoy",
};

fn knownProxy(name: []const u8) bool {
    for (all_proxies) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    return false;
}

test "parseProxies accepts the default set and trims spaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try parseProxies(arena, "zoxy ,haproxy,pingora, envoy");
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("zoxy", got[0]);
    try std.testing.expectEqualStrings("envoy", got[3]);
}

test "parseProxies rejects direct, which is no longer part of the comparison" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A stale dispatch input naming it must fail.
    try std.testing.expectError(error.UnknownProxy, parseProxies(arena, "direct,zoxy"));
}

test "parseProxies rejects a typo rather than silently dropping it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.UnknownProxy, parseProxies(arena_state.allocator(), "zoxyy"));
    try std.testing.expectError(error.NoProxies, parseProxies(arena_state.allocator(), ""));
}

test "parseProxies rejects proxies whose configs were removed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // Must fail at argument parsing, not later as a missing compose service.
    try std.testing.expectError(error.UnknownProxy, parseProxies(arena_state.allocator(), "traefik"));
}

// ---------------------------------------------------------------------------
// Publishing: `notify` and `index`. Both read a completed run directory
// (`<dir>/<profile>/{profile.json,report.json,report.html}`) from `bench report`.
// ---------------------------------------------------------------------------

const discord = @import("discord.zig");
const index = @import("index.zig");

/// One profile's published state, as read back off disk.
pub const ProfileView = struct {
    name: []const u8,
    prof: profile.Profile,
    origin: artifact.Origin,
    rows: []discord.Row,
    html: []const u8,
    ok: usize,
    failed: usize,
};

/// Read `<dir>/<name>/` back into the shape both publishers want.
/// Read `<dir>/<name>/` back into the shape both publishers want. Reads the
/// artifacts, not recomputing, so Discord and Pages quote the report's numbers.
pub fn readProfile(
    arena: Allocator,
    io: Io,
    dir: []const u8,
    name: []const u8,
) !?ProfileView {
    const prof = profile.byName(name) orelse return null;

    const pj_path = try std.fmt.allocPrint(arena, "{s}/{s}/profile.json", .{ dir, name });
    const pj = Io.Dir.cwd().readFileAlloc(io, pj_path, arena, .limited(4 << 20)) catch return null;
    const pv = try std.json.parseFromSliceLeaky(std.json.Value, arena, pj, .{});
    const proxies = (pv.object.get("proxies") orelse return null).object;
    const origin: artifact.Origin = if (strOf(pv.object.get("fleet"))) |f|
        (std.meta.stringToEnum(artifact.Origin, f) orelse .cloud)
    else
        .cloud;

    const rj_path = try std.fmt.allocPrint(arena, "{s}/{s}/report.json", .{ dir, name });
    const rj = Io.Dir.cwd().readFileAlloc(io, rj_path, arena, .limited(64 << 20)) catch return null;
    const rv = try std.json.parseFromSliceLeaky(std.json.Value, arena, rj, .{});

    const html_path = try std.fmt.allocPrint(arena, "{s}/{s}/report.html", .{ dir, name });
    const html_bytes = Io.Dir.cwd().readFileAlloc(io, html_path, arena, .limited(64 << 20)) catch "";

    var rows: std.ArrayList(discord.Row) = .empty;
    var ok: usize = 0;
    var failed: usize = 0;

    // Already ordered by sustained descending.
    if (rv.object.get("proxies")) |arr| {
        for (arr.array.items) |item| {
            const o = item.object;
            const pname = strOf(o.get("name")) orelse continue;

            var status: artifact.Status = .ok;
            var stage: ?artifact.Stage = null;
            var saturated = false;
            var note: ?[]const u8 = null;
            if (proxies.get(pname)) |st| {
                const so = st.object;
                if (strOf(so.get("status"))) |v| {
                    status = std.meta.stringToEnum(artifact.Status, v) orelse .ok;
                }
                if (strOf(so.get("stage"))) |v| {
                    stage = std.meta.stringToEnum(artifact.Stage, v);
                }
                // Leading note (suite.zig puts the most serious first), so e.g. a stale
                // zoxy build is readable in the post, not just a bare "⚠".
                if (so.get("notes")) |v| {
                    if (v == .array and v.array.items.len > 0 and v.array.items[0] == .string) {
                        note = v.array.items[0].string;
                    }
                }
                if (so.get("saturated")) |v| saturated = v == .bool and v.bool;
            }
            if (status.usable()) ok += 1 else failed += 1;

            const lat = o.get("latency_ms");
            try rows.append(arena, .{
                .name = pname,
                .status = status,
                .stage = stage,
                .sustained = numOf(o.get("sustained")) orelse 0,
                .p50_ms = if (lat) |l| numOf(l.object.get("p50")) else null,
                .p99_ms = if (lat) |l| numOf(l.object.get("p99")) else null,
                .saturated = saturated,
                .mem = numOf(o.get("mem")),
                .note = note,
            });
        }
    }

    return .{
        .name = name,
        .prof = prof,
        .origin = origin,
        .rows = try rows.toOwnedSlice(arena),
        .html = html_bytes,
        .ok = ok,
        .failed = failed,
    };
}

fn numOf(v: ?std.json.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// Like `numOf`, for a string field. Guards the type: an unchecked `.string`
/// on unexpected JSON is UB in ReleaseFast, on the whole publish path.
fn strOf(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

/// Post the nightly summary. History, when present, supplies the vs-last-night
/// delta; its absence costs a column and nothing else.
pub fn notify(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: Env,
    dir: []const u8,
    runid: []const u8,
    history_path: []const u8,
    base_url: []const u8,
    dry_run: bool,
) !u8 {
    if (!dry_run and env.webhook.len == 0) {
        std.debug.print("bench notify: DISCORD_WEBHOOK is required (or pass --dry-run)\n", .{});
        return 2;
    }

    const history = blk: {
        if (history_path.len == 0) break :blk &[_]index.HistoryRow{};
        const text = Io.Dir.cwd().readFileAlloc(io, history_path, arena, .limited(64 << 20)) catch
            break :blk &[_]index.HistoryRow{};
        break :blk try index.parseHistory(arena, text);
    };

    var embeds: std.ArrayList(discord.Embed) = .empty;
    var any_failed = false;

    // Link the report rather than attach it: Discord can't preview HTML
    // attachments. Links go to Pages, which holds only the latest run; the embed
    // names its run id and the trend carries history.
    for (profile.all) |p| {
        const view = (try readProfile(arena, io, dir, p.name)) orelse continue;
        if (view.failed > 0) any_failed = true;

        for (view.rows) |*r| {
            r.delta = index.delta(r.sustained, index.previousSustained(history, p.name, r.name, runid));
        }

        // No rendered report, no link; the table still goes out.
        var link: []const u8 = "";
        if (view.html.len > 0 and base_url.len > 0) {
            link = try std.fmt.allocPrint(arena, "{s}{s}/", .{ base_url, p.name });
        }

        try embeds.append(arena, .{
            .title = try std.fmt.allocPrint(arena, "{s} · {d} connections", .{ p.name, p.connections }),
            .ref_rate = p.ref_rate,
            .url = link,
            .footer = try std.fmt.allocPrint(
                arena,
                // From the linked package, never a literal, so provenance can't go stale.
                "{s} · p50/p99 read at {d:.0} req/s · zrk {s}",
                .{ runid, p.ref_rate, zrk.cli.version },
            ),
            .rows = view.rows,
        });
    }

    if (embeds.items.len == 0) {
        std.debug.print("bench notify: no rendered profiles found under {s}\n", .{dir});
        return 1;
    }

    const content = try std.fmt.allocPrint(
        arena,
        "{s} nightly benchmark · {s}",
        .{ if (any_failed) "⚠" else "✅", runid },
    );

    try discord.post(gpa, arena, io, env.webhook, content, embeds.items, &.{}, dry_run);
    std.debug.print("bench notify: posted {d} embed(s)\n", .{embeds.items.len});
    return 0;
}

/// Build the Pages site: the landing page, each profile's rendered report, and
/// history.ndjson with tonight's rows appended.
pub fn buildIndex(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    dir: []const u8,
    runid: []const u8,
    out_dir: []const u8,
    history_path: []const u8,
    /// Where this run's results.tar can be downloaded, linked from the landing
    /// page. Empty for a local run, or a fork with no bucket.
    results_url: []const u8,
) !u8 {
    _ = gpa;
    try Io.Dir.cwd().createDirPath(io, out_dir);

    const prior = blk: {
        if (history_path.len == 0) break :blk &[_]index.HistoryRow{};
        const text = Io.Dir.cwd().readFileAlloc(io, history_path, arena, .limited(64 << 20)) catch
            break :blk &[_]index.HistoryRow{};
        break :blk try index.parseHistory(arena, text);
    };

    var summaries: std.ArrayList(index.ProfileSummary) = .empty;
    var tonight: std.ArrayList(index.HistoryRow) = .empty;
    const ts = try nowIso(io, arena);

    for (profile.all) |p| {
        const view = (try readProfile(arena, io, dir, p.name)) orelse continue;

        try summaries.append(arena, .{
            .name = p.name,
            .ok = view.ok,
            .failed = view.failed,
            .connections = p.connections,
            .deadline_ms = p.deadline_ms,
            .tls = p.tls,
        });

        // A local run never enters history: incomparable points would read as a
        // regression or a win in the trend.
        if (view.origin == .local) {
            std.debug.print(
                "bench index: {s} was a local run; excluded from history and the trend\n",
                .{p.name},
            );
            continue;
        }
        for (view.rows) |r| {
            try tonight.append(arena, .{
                .runid = runid,
                .ts = ts,
                .profile = p.name,
                .proxy = r.name,
                .status = r.status.str(),
                .sustained = r.sustained,
                .p50_ms = r.p50_ms,
                .p99_ms = r.p99_ms,
                .mem = r.mem,
            });
        }

        // Copy artifacts so the page's links resolve and numbers are re-derivable.
        const sub = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, p.name });
        try Io.Dir.cwd().createDirPath(io, sub);
        try copyInto(arena, io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, p.name }), sub);

        // index.html is the report, so a profile directory opens directly.
        try copyFile(
            arena,
            io,
            try std.fmt.allocPrint(arena, "{s}/report.html", .{sub}),
            try std.fmt.allocPrint(arena, "{s}/index.html", .{sub}),
        );
    }

    if (summaries.items.len == 0) {
        std.debug.print("bench index: no rendered profiles found under {s}\n", .{dir});
        return 1;
    }

    // Built in memory so `assertNoIps` runs before disk: history is the
    // longest-lived artifact. Merged, not appended, so re-publishing a run
    // doesn't duplicate its rows (see index.mergeHistory). The trend renders from
    // `full` so it includes tonight.
    const full = try index.mergeHistory(arena, prior, tonight.items);

    {
        var buf: std.ArrayList(u8) = .empty;
        var hw: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
        try index.writeHistory(&hw.writer, full);
        try redact.assertNoIps("history.ndjson", hw.written());

        const path = try std.fmt.allocPrint(arena, "{s}/history.ndjson", .{out_dir});
        const f = try Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        var fbuf: [64 * 1024]u8 = undefined;
        var fw: Io.File.Writer = .init(f, io, &fbuf);
        try fw.interface.writeAll(hw.written());
        try fw.interface.flush();
    }

    {
        var page: std.ArrayList(u8) = .empty;
        var pw: std.Io.Writer.Allocating = .fromArrayList(arena, &page);
        try index.renderIndex(arena, &pw.writer, runid, ts, summaries.items, full, results_url);
        try redact.assertNoIps("index.html", pw.written());

        const path = try std.fmt.allocPrint(arena, "{s}/index.html", .{out_dir});
        const f = try Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var fw: Io.File.Writer = .init(f, io, &buf);
        try fw.interface.writeAll(pw.written());
        try fw.interface.flush();
    }

    std.debug.print("bench index: built {s} ({d} profile(s))\n", .{ out_dir, summaries.items.len });
    return 0;
}

/// Artifact kinds that may be published.
/// An ALLOWLIST, since this copies into a public website: new artifact kinds
/// must be added deliberately (a legacy meta.json once carried a public IP).
const publishable = [_][]const u8{
    ".ndjson", // raw per-window series, so every number is re-derivable
    ".hgrm", // whole-run percentile distribution
    ".html", // the rendered report
    ".json", // report.json and profile.json — both checked below
};

fn isPublishable(name: []const u8) bool {
    // meta.json is the legacy file that carried an IP; named so it never rides
    // along.
    if (std.mem.eql(u8, name, "meta.json")) return false;
    for (publishable) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

fn copyInto(arena: Allocator, io: Io, from: []const u8, to: []const u8) !void {
    var d = Io.Dir.cwd().openDir(io, from, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isPublishable(entry.name)) {
            std.debug.print("bench index: not publishing {s}\n", .{entry.name});
            continue;
        }
        try copyFile(
            arena,
            io,
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ from, entry.name }),
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ to, entry.name }),
        );
    }
}

fn copyFile(arena: Allocator, io: Io, from: []const u8, to: []const u8) !void {
    const bytes = Io.Dir.cwd().readFileAlloc(io, from, arena, .limited(256 << 20)) catch return;

    // Check everything reaching the site, including zrk's .ndjson and .hgrm.
    try redact.assertNoIps(from, bytes);

    const f = try Io.Dir.cwd().createFile(io, to, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(f, io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

test "the publish allowlist excludes the legacy meta.json" {
    // meta.json carried the loadgen's public IP in the old harness.
    try std.testing.expect(!isPublishable("meta.json"));
    try std.testing.expect(isPublishable("profile.json"));
    try std.testing.expect(isPublishable("report.json"));
    try std.testing.expect(isPublishable("zoxy.ndjson"));
    try std.testing.expect(isPublishable("zoxy.hgrm"));
    try std.testing.expect(isPublishable("report.html"));
    // Anything unrecognised stays put.
    try std.testing.expect(!isPublishable("id_ed25519"));
    try std.testing.expect(!isPublishable(".env"));
}

fn nowIso(io: Io, arena: Allocator) ![]const u8 {
    const t = Io.Timestamp.now(io, .real);
    const secs = @divFloor(t.nanoseconds, std.time.ns_per_s);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

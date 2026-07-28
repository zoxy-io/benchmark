//! The subcommands that talk to the cloud: `sweep`, `wait`, `fetch`, `suite`.
//!
//! Split out of main.zig so the argument plumbing stays readable and each
//! command's failure policy is stated next to it. The policies differ on
//! purpose: `sweep` tolerates almost everything (it is a best-effort cleanup and
//! must never block a run), while `wait` fails loudly (a run that produced no
//! marker produced no data, and pretending otherwise publishes nothing).

const std = @import("std");
const Io = std.Io;

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
///
/// This is the recovery path for a run cancelled between `apply` and `destroy`,
/// where terraform's per-run state died with the runner and nothing else knows
/// those VMs exist. Keying off a LABEL rather than state is the whole point:
/// state can be lost, a label cannot.
///
/// Never fatal. A sweep failure must not stop tonight's benchmark — worst case
/// a few orphans cost money until the next run, which is much better than a
/// permanently red nightly.
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

        // Never print the instance's addresses — only its name and run id.
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
    /// Overall bound. Past this the run is declared failed whatever the fleet is
    /// doing, so a wedged VM cannot hold the workflow to its own timeout.
    deadline_s: u64 = 110 * 60,
    poll_s: u64 = 30,
    /// If no VM has written its boot marker by here, cloud-init failed and no
    /// amount of further waiting will help. This closes the gap where a loadgen
    /// whose payload fetch failed writes NOTHING — no boot-ok, no FAILED — and
    /// the runner would otherwise poll for its full deadline with no signal.
    boot_deadline_s: u64 = 15 * 60,
};

pub const WaitResult = enum { done, failed, timed_out, never_booted };

/// Poll Object Storage for the run's terminal marker, echoing the uploaded log
/// as it grows so the Actions console shows progress rather than 45 minutes of
/// silence.
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
    var waited: u64 = 0;
    var booted = false;

    while (waited < opts.deadline_s) {
        // Echo whatever new log the loadgen has uploaded. This is the only
        // window into a run that is otherwise completely unreachable.
        if (client.get(arena, env.bucket, log_key)) |maybe| {
            if (maybe) |text| {
                if (text.len > shown) {
                    std.debug.print("{s}", .{text[shown..]});
                    shown = text.len;
                }
            }
        } else |_| {}

        if (client.exists(env.bucket, done_key) catch false) return .done;
        if (client.exists(env.bucket, failed_key) catch false) return .failed;

        if (!booted) {
            booted = client.exists(env.bucket, boot_key) catch false;
            if (!booted and waited >= opts.boot_deadline_s) {
                std.debug.print(
                    "bench wait: the loadgen never wrote its boot marker after {d}s — " ++
                        "cloud-init did not finish, so no result will ever arrive\n",
                    .{waited},
                );
                return .never_booted;
            }
        }

        io.sleep(.fromNanoseconds(opts.poll_s * std.time.ns_per_s), .awake) catch break;
        waited += opts.poll_s;
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
) !u8 {
    const proxy_ip = Env.get(environ, "PROXY_IP");
    const backend_ip = Env.get(environ, "BACKEND_IP");
    const ssh_key = Env.get(environ, "SSH_KEY");
    if (proxy_ip.len == 0 or backend_ip.len == 0 or ssh_key.len == 0) {
        std.debug.print("bench suite: PROXY_IP, BACKEND_IP and SSH_KEY are required\n", .{});
        return 2;
    }

    // Registered so any address that reaches a log line is scrubbed, and so CI
    // masks them if this ever runs somewhere with a console.
    redact.register(proxy_ip);
    redact.register(backend_ip);

    const known_hosts = Env.get(environ, "SSH_KNOWN_HOSTS");
    const out_dir = try std.fmt.allocPrint(arena, "results/{s}/{s}", .{ runid, prof.name });
    try Io.Dir.cwd().createDirPath(io, out_dir);

    const res = try suite.run(gpa, arena, io, .{
        .prof = prof,
        .proxies = proxies,
        .runid = runid,
        .out_dir = out_dir,
        .fleet = .{
            .proxy_ip = proxy_ip,
            .backend_ip = backend_ip,
            .ssh = .{
                .key_path = ssh_key,
                .known_hosts = if (known_hosts.len > 0) known_hosts else "/home/ubuntu/.ssh/known_hosts",
            },
        },
    });

    var ok: usize = 0;
    var bad: usize = 0;
    for (res.records) |r| {
        if (r.status.usable()) ok += 1 else bad += 1;
    }
    std.debug.print("bench suite [{s}]: {d} usable, {d} failed/skipped\n", .{ prof.name, ok, bad });

    // Exit 3 means "it ran, but the result is incomplete" — distinct from a
    // crash, so the workflow can still publish what there is while making the
    // run visibly red.
    if (res.aborted or ok == 0) return 3;
    return 0;
}

/// Split a comma-separated list, rejecting names the suite does not know.
/// A typo must be a loud error, not a silently-skipped proxy that leaves a gap
/// in the comparison nobody notices.
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

const all_proxies = [_][]const u8{
    "direct", "zoxy", "haproxy", "pingora",
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

    const got = try parseProxies(arena, "direct, zoxy ,haproxy,pingora");
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("direct", got[0]);
    try std.testing.expectEqualStrings("pingora", got[3]);
}

test "parseProxies rejects a typo rather than silently dropping it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // Silently skipping "zoxyy" would leave a hole in the comparison that
    // nobody would notice until the report came out short.
    try std.testing.expectError(error.UnknownProxy, parseProxies(arena_state.allocator(), "zoxyy"));
    try std.testing.expectError(error.NoProxies, parseProxies(arena_state.allocator(), ""));
}

test "parseProxies rejects proxies whose configs were removed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // envoy/traefik/nginx were deleted rather than parked. Naming one must fail
    // here — at argument parsing, with the name in the message — rather than
    // later as a compose service that does not exist.
    try std.testing.expectError(error.UnknownProxy, parseProxies(arena_state.allocator(), "envoy"));
    try std.testing.expectError(error.UnknownProxy, parseProxies(arena_state.allocator(), "nginx"));
}

// ---------------------------------------------------------------------------
// Publishing: `notify` and `index`. Both read a completed run directory —
// `<dir>/<profile>/{profile.json,report.json,report.html}` — so they depend on
// `bench report` having run, and on nothing else.
// ---------------------------------------------------------------------------

const discord = @import("discord.zig");
const index = @import("index.zig");

/// One profile's published state, as read back off disk.
pub const ProfileView = struct {
    name: []const u8,
    prof: profile.Profile,
    rows: []discord.Row,
    html: []const u8,
    ok: usize,
    failed: usize,
};

/// Read `<dir>/<name>/` back into the shape both publishers want.
///
/// Deliberately reads the ARTIFACTS rather than recomputing: report.json is the
/// canonical measured-data record, so the Discord table and the Pages page can
/// never quote a different number than the report does.
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

    const rj_path = try std.fmt.allocPrint(arena, "{s}/{s}/report.json", .{ dir, name });
    const rj = Io.Dir.cwd().readFileAlloc(io, rj_path, arena, .limited(64 << 20)) catch return null;
    const rv = try std.json.parseFromSliceLeaky(std.json.Value, arena, rj, .{});

    const html_path = try std.fmt.allocPrint(arena, "{s}/{s}/report.html", .{ dir, name });
    const html_bytes = Io.Dir.cwd().readFileAlloc(io, html_path, arena, .limited(64 << 20)) catch "";

    var rows: std.ArrayList(discord.Row) = .empty;
    var ok: usize = 0;
    var failed: usize = 0;

    // report.json's `proxies` is already ordered by sustained descending, which
    // is the order the summary table and the embed should both use.
    if (rv.object.get("proxies")) |arr| {
        for (arr.array.items) |item| {
            const o = item.object;
            const pname = if (o.get("name")) |v| v.string else continue;

            var status: artifact.Status = .ok;
            var stage: ?artifact.Stage = null;
            var saturated = false;
            if (proxies.get(pname)) |st| {
                const so = st.object;
                if (so.get("status")) |v| {
                    status = std.meta.stringToEnum(artifact.Status, v.string) orelse .ok;
                }
                if (so.get("stage")) |v| {
                    if (v == .string) stage = std.meta.stringToEnum(artifact.Stage, v.string);
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
            });
        }
    }

    return .{
        .name = name,
        .prof = prof,
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
    var files: std.ArrayList(discord.Attachment) = .empty;
    var any_failed = false;

    for (profile.all) |p| {
        const view = (try readProfile(arena, io, dir, p.name)) orelse continue;
        if (view.failed > 0) any_failed = true;

        for (view.rows) |*r| {
            r.delta = index.delta(r.sustained, index.previousSustained(history, p.name, r.name, runid));
        }

        try embeds.append(arena, .{
            .title = try std.fmt.allocPrint(arena, "{s} · {d} connections", .{ p.name, p.connections }),
            .ref_rate = p.ref_rate,
            .url = if (base_url.len > 0)
                try std.fmt.allocPrint(arena, "{s}{s}/", .{ base_url, p.name })
            else
                "",
            .footer = try std.fmt.allocPrint(
                arena,
                "{s} · p50/p99 read at {d:.0} req/s · zrk 1.3.1",
                .{ runid, p.ref_rate },
            ),
            .rows = view.rows,
        });

        if (view.html.len > 0) {
            try files.append(arena, .{
                .filename = try std.fmt.allocPrint(arena, "report-{s}.html", .{p.name}),
                .content_type = "text/html",
                .bytes = view.html,
            });
        }
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

    try discord.post(gpa, arena, io, env.webhook, content, embeds.items, files.items, dry_run);
    std.debug.print("bench notify: posted {d} embed(s), {d} attachment(s)\n", .{
        embeds.items.len,
        files.items.len,
    });
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
        });

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

        // Copy the profile's artifacts across so the page's links resolve and
        // every number stays independently re-derivable from the raw data.
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

    // history = everything we had + tonight, republished because deploy-pages
    // replaces the site wholesale.
    {
        const path = try std.fmt.allocPrint(arena, "{s}/history.ndjson", .{out_dir});
        const f = try Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var fw: Io.File.Writer = .init(f, io, &buf);
        try index.writeHistory(&fw.interface, prior);
        try index.writeHistory(&fw.interface, tonight.items);
        try fw.interface.flush();
    }

    {
        var page: std.ArrayList(u8) = .empty;
        var pw: std.Io.Writer.Allocating = .fromArrayList(arena, &page);
        try index.renderIndex(arena, &pw.writer, runid, ts, summaries.items, prior);
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
///
/// An ALLOWLIST, not a denylist, because this copies into a public website.
/// Copying whatever happens to be in the directory would have published a
/// legacy `meta.json` — the very file that recorded the loadgen's PUBLIC IP in
/// every run of the old harness. A new artifact kind should have to be added
/// here deliberately, having been looked at.
const publishable = [_][]const u8{
    ".ndjson", // raw per-window series, so every number is re-derivable
    ".hgrm", // whole-run percentile distribution
    ".html", // the rendered report
    ".json", // report.json and profile.json — both checked below
};

fn isPublishable(name: []const u8) bool {
    // profile.json and report.json are the only JSON the new harness writes,
    // and both are IP-free by construction. meta.json is the legacy file and is
    // named explicitly so it can never ride along.
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

    // Everything reaching the site is checked, not just the files this binary
    // wrote. The .ndjson and .hgrm come straight from zrk.
    try redact.assertNoIps(from, bytes);

    const f = try Io.Dir.cwd().createFile(io, to, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(f, io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

test "the publish allowlist excludes the legacy meta.json" {
    // meta.json recorded "prom": "http://<loadgen public ip>:9090" in every run
    // of the old harness, so it must never reach a public site.
    try std.testing.expect(!isPublishable("meta.json"));
    try std.testing.expect(isPublishable("profile.json"));
    try std.testing.expect(isPublishable("report.json"));
    try std.testing.expect(isPublishable("zoxy.ndjson"));
    try std.testing.expect(isPublishable("zoxy.hgrm"));
    try std.testing.expect(isPublishable("report.html"));
    // Anything unrecognised stays put rather than being published by default.
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
        yd.year,     md.month.numeric(),       md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

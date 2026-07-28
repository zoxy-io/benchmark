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
    "direct", "zoxy", "haproxy", "pingora", "envoy", "traefik", "nginx",
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

test "parseProxies still accepts the proxies dropped from the default set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // envoy/traefik/nginx left the nightly comparison but their configs stayed,
    // so a one-off run must still be able to name them.
    const got = try parseProxies(arena_state.allocator(), "envoy,traefik,nginx");
    try std.testing.expectEqual(@as(usize, 3), got.len);
}

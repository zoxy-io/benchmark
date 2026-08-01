//! bench — the benchmark harness: fleet orchestration, load ramp, and report
//! rendering in one static binary.
//!
//! Replaces scripts/zrk-bench.sh (bash orchestration), report/*.py (report
//! rendering) and loadgen/zrk-runner (the ramp). One binary is built per run and
//! used both on the CI runner and on the loadgen VM, so "the agent drifted from
//! the controller" is structurally impossible.
//!
//! Subcommands and where each runs:
//!   bench suite   --profile <name>   loadgen VM   drive every proxy, one ramp each
//!   bench report  <rundir>           CI runner    rundir -> report.json + report.html
//!   bench index   <rundir>           CI runner    -> _site/ (both profiles + trend)
//!   bench notify  <rundir>           CI runner    -> Discord embed + attachment
//!   bench sweep                      CI runner    delete orphaned VMs by label
//!   bench wait    <runid>            CI runner    poll for DONE, tail the log

const std = @import("std");

pub const analysis = @import("analysis.zig");
pub const profile = @import("profile.zig");
pub const jsonw = @import("jsonw.zig");
pub const report = @import("report.zig");
pub const redact = @import("redact.zig");
pub const cadvisor = @import("cadvisor.zig");
pub const ramp = @import("ramp.zig");
pub const remote = @import("remote.zig");
pub const artifact = @import("artifact.zig");
pub const suite = @import("suite.zig");
pub const ycs = @import("ycs.zig");
pub const svg = @import("svg.zig");
pub const html = @import("html.zig");
pub const discord = @import("discord.zig");
pub const commands = @import("commands.zig");
pub const index = @import("index.zig");

const usage =
    \\usage: bench <command> [options]
    \\
    \\  suite   --profile <c1k|c10k> [--proxies a,b,c] [--local]
    \\                                                   run the suite
    \\  report  <rundir>                                 render report.json + report.html
    \\  index   <rundir>                                 build the Pages site
    \\  notify  <rundir> [--dry-run]                     post to Discord
    \\  sweep                                            delete orphaned fleet VMs
    \\  wait    <runid> [--max-wait-s <n>]                await the self-driving run
    \\  ramp    --profile .. --proxy .. --target ..      one proxy's ramp (spawned by `suite`)
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }

    // GitHub masks any value passed to ::add-mask::, so registering the fleet's
    // addresses there covers output this process never sees — a child's stderr,
    // an action's own logging.
    redact.setCiMasking(std.process.Environ.getPosix(init.minimal.environ, "CI") != null);

    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "report")) return cmdReport(init, rest);
    if (std.mem.eql(u8, cmd, "sweep")) return exit(try commands.sweep(
        init.gpa,
        arena,
        init.io,
        commands.Env.read(init.minimal.environ),
    ));
    if (std.mem.eql(u8, cmd, "wait")) return cmdWait(init, rest);
    if (std.mem.eql(u8, cmd, "fetch")) return cmdFetch(init, rest);
    if (std.mem.eql(u8, cmd, "suite")) return cmdSuite(init, rest);
    if (std.mem.eql(u8, cmd, "notify")) return cmdNotify(init, rest);
    if (std.mem.eql(u8, cmd, "index")) return cmdIndex(init, rest);
    if (std.mem.eql(u8, cmd, "ramp")) return cmdRamp(init, rest);

    std.debug.print("bench: unknown command '{s}'\n\n{s}", .{ cmd, usage });
    std.process.exit(2);
}

fn exit(code: u8) noreturn {
    std.process.exit(code);
}

fn cmdWait(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var env = commands.Env.read(init.minimal.environ);
    env.runid = try flagValue(args, "--runid") orelse env.runid;
    if (env.runid.len == 0) return fail("bench wait: --runid or BENCH_RUNID is required", .{});

    var opts: commands.WaitOptions = .{};
    // Lets the workflow bound a single invocation to less than the federated
    // IAM token's ~1h TTL, so it can re-mint a fresh one and call `wait` again
    // rather than have the SAME invocation's token expire mid-poll — Object
    // Storage then starts 401ing every `exists`/`get` and the run looks dead
    // even though the fleet is healthy. Exit code 5 (below) is what tells the
    // workflow "that was a chunk boundary, not the end" so it knows to retry.
    if (try flagValue(args, "--max-wait-s")) |v| {
        opts.deadline_s = std.fmt.parseUnsigned(u64, v, 10) catch
            return fail("bench wait: --max-wait-s must be a non-negative integer", .{});
    }

    const res = try commands.wait(init.gpa, arena, init.io, env, opts);
    switch (res) {
        .done => {
            std.debug.print("bench wait: run complete\n", .{});
            exit(0);
        },
        // Distinguished in the exit code so the workflow can tell "the suite ran
        // and reported failure" (there may still be partial artifacts worth
        // publishing) from "nothing ever came back".
        //
        .failed => exit(3),
        .never_booted => exit(1),
        // Distinct from `never_booted`: the fleet may be perfectly healthy and
        // just still running when THIS invocation's deadline (`--max-wait-s`)
        // ran out — worth calling `wait` again with a fresh token, unlike
        // `never_booted`, which no amount of retrying will fix.
        .timed_out => exit(5),
    }
}

fn cmdFetch(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var env = commands.Env.read(init.minimal.environ);
    env.runid = try flagValue(args, "--runid") orelse env.runid;
    const out = try flagValue(args, "--out") orelse "results";
    if (env.runid.len == 0) return fail("bench fetch: --runid or BENCH_RUNID is required", .{});
    exit(try commands.fetch(init.gpa, arena, init.io, env, out));
}

fn cmdSuite(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    const environ = init.minimal.environ;

    const prof_name = try flagValue(args, "--profile") orelse
        return fail("bench suite: --profile is required", .{});
    const prof = profile.byName(prof_name) orelse
        return fail("bench suite: unknown profile '{s}'", .{prof_name});

    const spec = try flagValue(args, "--proxies") orelse
        commands.Env.get(environ, "BENCH_PROXIES");
    const proxies = try commands.parseProxies(arena, if (spec.len > 0) spec else "zoxy,haproxy,nginx,pingora,envoy");

    const runid = try flagValue(args, "--runid") orelse commands.Env.get(environ, "BENCH_RUNID");
    if (runid.len == 0) return fail("bench suite: --runid or BENCH_RUNID is required", .{});

    exit(try commands.runSuite(init.gpa, arena, init.io, environ, prof, proxies, runid, hasFlag(args, "--local")));
}

fn cmdNotify(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var env = commands.Env.read(init.minimal.environ);
    const dir = positional(args) orelse return fail("bench notify: <rundir> is required", .{});
    env.runid = try flagValue(args, "--runid") orelse env.runid;
    if (env.runid.len == 0) env.runid = std.fs.path.basename(dir);

    exit(try commands.notify(
        init.gpa,
        arena,
        init.io,
        env,
        dir,
        env.runid,
        try flagValue(args, "--history") orelse "",
        try flagValue(args, "--base-url") orelse "",
        hasFlag(args, "--dry-run"),
    ));
}

fn cmdIndex(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    const env = commands.Env.read(init.minimal.environ);
    const dir = positional(args) orelse return fail("bench index: <rundir> is required", .{});
    var runid = try flagValue(args, "--runid") orelse env.runid;
    if (runid.len == 0) runid = std.fs.path.basename(dir);

    exit(try commands.buildIndex(
        init.gpa,
        arena,
        init.io,
        dir,
        runid,
        try flagValue(args, "--out") orelse "_site",
        try flagValue(args, "--history") orelse "",
    ));
}

/// Every flag in this CLI that is checked with `hasFlag` rather than read with
/// `flagValue` — i.e. every flag `positional` must NOT treat as consuming the
/// argument after it. A flag added to a `hasFlag` call site anywhere in this
/// file but not to this list is silently misparsed: `positional` would treat
/// whatever follows it as ITS value and skip past a real positional argument.
const valueless_flags = [_][]const u8{ "--dry-run", "--local" };

fn isValueless(name: []const u8) bool {
    for (valueless_flags) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

/// The first argument that is not a flag or a flag's value.
fn positional(args: []const [:0]const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.startsWith(u8, args[i], "--")) {
            if (!isValueless(args[i])) i += 1;
            continue;
        }
        return args[i];
    }
    return null;
}

fn hasFlag(args: []const [:0]const u8, name: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

test "positional does not consume the argument after a valueless flag" {
    const args: []const [:0]const u8 = &.{ "--dry-run", "rundir" };
    try std.testing.expectEqualStrings("rundir", positional(args).?);
}

test "positional DOES consume the argument after a value-taking flag" {
    const args: []const [:0]const u8 = &.{ "--runid", "20260101-000000", "rundir" };
    try std.testing.expectEqualStrings("rundir", positional(args).?);
}

/// Value of `--name <value>`, or null when absent.
fn flagValue(args: []const [:0]const u8, name: []const u8) !?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], name)) continue;
        if (i + 1 >= args.len) {
            std.debug.print("bench: {s} needs a value\n", .{name});
            return error.MissingFlagValue;
        }
        return args[i + 1];
    }
    return null;
}

/// `bench report <rundir> [--profile <name>] [--generated <iso>]`
///
/// Reads the run's own artifacts and writes report.json beside them. During the
/// migration this also accepts the legacy meta.json written by
/// scripts/zrk-bench.sh, so the port can be diffed against report/report.py on
/// runs that already exist — the Phase 0 gate.
fn cmdReport(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    var dir: ?[]const u8 = null;
    var prof = profile.c1k;
    var generated: []const u8 = "";
    var base_url: []const u8 = "";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--profile")) {
            i += 1;
            if (i >= args.len) return fail("--profile needs a value", .{});
            prof = profile.byName(args[i]) orelse
                return fail("unknown profile '{s}'", .{args[i]});
        } else if (std.mem.eql(u8, a, "--base-url")) {
            i += 1;
            if (i >= args.len) return fail("--base-url needs a value", .{});
            base_url = args[i];
        } else if (std.mem.eql(u8, a, "--generated")) {
            i += 1;
            if (i >= args.len) return fail("--generated needs a value", .{});
            generated = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            return fail("unknown flag '{s}'", .{a});
        } else if (dir == null) {
            dir = a;
        } else {
            return fail("unexpected argument '{s}'", .{a});
        }
    }
    const run_dir = dir orelse return fail("usage: bench report <rundir>", .{});

    try prof.validate();

    // profile.json is what `bench suite` writes; meta.json is the bash
    // harness's, kept working so archived run dirs still render.
    //
    // Neither present is the ordinary shape of a truncated run — the profile
    // never got far enough to write one — so say that, with the path. A bare
    // `error: FileNotFound` sent me looking for a corrupt artifact when the
    // directory simply was not there, and it names neither the file nor the
    // fact that `<dir>` must be the PROFILE directory, not the run directory.
    const meta = readProfileMeta(arena, io, run_dir) catch
        readMeta(arena, io, run_dir) catch {
            std.debug.print(
                "bench report: no profile.json in {s} — this profile produced no artifacts " ++
                    "(a run that was cut short), or <dir> is the run directory rather than " ++
                    "<run>/<profile>\n",
                .{run_dir},
            );
            exit(2);
        };
    const ordered = try report.orderPresent(arena, meta.proxies);

    const inputs = try arena.alloc(report.ProxyInput, ordered.len);
    for (ordered, 0..) |name, k| {
        const tags = meta.tagsFor(name);
        // cAdvisor samples replace the Prometheus CPU/memory queries. An
        // archived run predates the poller and comes back empty, which the
        // report renders as absent rather than as zero.
        const cad = try report.loadCadvisor(
            arena,
            io,
            run_dir,
            name,
            if (tags.len > 0) tags[0] else "",
            meta.ramp,
        );
        inputs[k] = .{ .name = name, .tags = tags, .cpu = cad.cpu, .mem = cad.mem };
    }

    var g = try report.gather(gpa, arena, io, run_dir, inputs, prof.ref_rate, prof.ref_band);
    defer g.deinit();

    // profile.json carries per-proxy status and which fleet produced the run; a
    // legacy meta.json run dir has neither, in which case every present proxy is
    // treated as ok and the run as a cloud one.
    const statuses = readStatuses(arena, io, run_dir) catch &.{};
    const origin = readOrigin(arena, io, run_dir);

    // Built into memory first, like report.html below, so `assertNoIps` runs
    // BEFORE anything reaches disk. This used to stream straight to the file —
    // the only artifact in the whole harness that skipped the check at its own
    // point of creation; the gap was closed only incidentally, whenever
    // `copyFile` re-checked it during a Pages publish.
    var jbuf: std.ArrayList(u8) = .empty;
    defer jbuf.deinit(gpa);
    var jw: std.Io.Writer.Allocating = .fromArrayList(gpa, &jbuf);
    defer jbuf = jw.toArrayList();

    try report.writeJson(
        arena,
        &jw.writer,
        g,
        meta.runid,
        generated,
        meta.ramp,
        prof.ref_rate,
        prof.ref_band,
        statuses,
    );
    try redact.assertNoIps("report.json", jw.written());

    const path = try std.fmt.allocPrint(arena, "{s}/report.json", .{run_dir});
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(file, io, &buf);
    try fw.interface.writeAll(jw.written());
    try fw.interface.flush();

    // The HTML draws from the SAME Gathered value the JSON was written from, so
    // the two can never disagree about a number.
    const html_path = try std.fmt.allocPrint(arena, "{s}/report.html", .{run_dir});
    const hfile = try std.Io.Dir.cwd().createFile(io, html_path, .{});
    defer hfile.close(io);
    var hbuf: [64 * 1024]u8 = undefined;
    var hfw: std.Io.File.Writer = .init(hfile, io, &hbuf);

    var page: std.ArrayList(u8) = .empty;
    defer page.deinit(gpa);
    var pw: std.Io.Writer.Allocating = .fromArrayList(gpa, &page);
    defer page = pw.toArrayList();

    try html.render(arena, &pw.writer, g, statuses, .{
        .runid = meta.runid,
        .profile_name = prof.name,
        .ref_rate = prof.ref_rate,
        .connections = prof.connections,
        .deadline_ms = prof.deadline_ms,
        .base_url = base_url,
        .origin = origin,
    });

    // This file is attached to a public Discord channel and served from a public
    // Pages site. Refuse to write it rather than publish an address.
    try redact.assertNoIps("report.html", pw.written());

    try hfw.interface.writeAll(pw.written());
    try hfw.interface.flush();

    std.debug.print("bench: wrote {s} and {s}\n", .{ path, html_path });
}

const Meta = struct {
    runid: []const u8,
    proxies: []const []const u8,
    tags: []const []const []const u8,
    ramp: report.Ramp,

    fn tagsFor(self: Meta, name: []const u8) []const []const u8 {
        for (self.proxies, self.tags) |p, t| {
            if (std.mem.eql(u8, p, name)) return t;
        }
        return &.{"lg1"};
    }
};

/// Parse scripts/zrk-bench.sh's meta.json. Retained for the migration only;
/// `bench suite` writes profile.json, which carries an explicit per-proxy status
/// instead of making presence in a map mean "this proxy produced valid data".
fn readMeta(arena: std.mem.Allocator, io: std.Io, run_dir: []const u8) !Meta {
    const path = try std.fmt.allocPrint(arena, "{s}/meta.json", .{run_dir});
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024));

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const obj = parsed.object;

    const runid = if (obj.get("runid")) |v| v.string else "";
    const runs = (obj.get("runs") orelse return error.MetaMissingRuns).object;

    var names: std.ArrayList([]const u8) = .empty;
    var tags: std.ArrayList([]const []const u8) = .empty;
    var ramp_meta: report.Ramp = .{};

    var it = runs.iterator();
    while (it.next()) |e| {
        try names.append(arena, e.key_ptr.*);

        const run = e.value_ptr.*.object;
        var lg: std.ArrayList([]const u8) = .empty;
        if (run.get("loadgens")) |v| {
            for (v.array.items) |t| try lg.append(arena, t.string);
        }
        if (lg.items.len == 0) try lg.append(arena, "lg1");
        try tags.append(arena, try lg.toOwnedSlice(arena));

        // The ramp is identical across proxies by construction — read it off
        // whichever run we see first.
        if (ramp_meta.start_rate == null) {
            if (run.get("start_rate")) |v| ramp_meta.start_rate = v.integer;
            if (run.get("max_rate")) |v| ramp_meta.max_rate = v.integer;
            if (run.get("ramp_seconds")) |v| ramp_meta.ramp_seconds = v.integer;
        }
    }

    return .{
        .runid = runid,
        .proxies = try names.toOwnedSlice(arena),
        .tags = try tags.toOwnedSlice(arena),
        .ramp = ramp_meta,
    };
}

/// Read a run dir written by `bench suite`. Its files are untagged
/// (`<proxy>.ndjson`), and the proxy list is the profile.json `proxies` map —
/// which, unlike the bash harness's meta.json, distinguishes a proxy that failed
/// from one that served nothing.
fn readProfileMeta(arena: std.mem.Allocator, io: std.Io, run_dir: []const u8) !Meta {
    const path = try std.fmt.allocPrint(arena, "{s}/profile.json", .{run_dir});
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024));

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const obj = parsed.object;
    const proxies = (obj.get("proxies") orelse return error.NoProxies).object;

    var names: std.ArrayList([]const u8) = .empty;
    var tags: std.ArrayList([]const []const u8) = .empty;
    const untagged: []const []const u8 = &.{""};

    var it = proxies.iterator();
    while (it.next()) |e| {
        try names.append(arena, e.key_ptr.*);
        try tags.append(arena, untagged);
    }

    var ramp_meta: report.Ramp = .{};
    if (obj.get("ramp")) |r| {
        const ro = r.object;
        if (ro.get("start_rate")) |v| ramp_meta.start_rate = v.integer;
        if (ro.get("max_rate")) |v| ramp_meta.max_rate = v.integer;
        if (ro.get("ramp_seconds")) |v| ramp_meta.ramp_seconds = v.integer;
    }

    return .{
        .runid = if (obj.get("runid")) |v| v.string else "",
        .proxies = try names.toOwnedSlice(arena),
        .tags = try tags.toOwnedSlice(arena),
        .ramp = ramp_meta,
    };
}

/// Which fleet produced this run. A legacy run dir predates the field, and
/// every one of those came off the real fleet.
fn readOrigin(arena: std.mem.Allocator, io: std.Io, run_dir: []const u8) artifact.Origin {
    const path = std.fmt.allocPrint(arena, "{s}/profile.json", .{run_dir}) catch return .cloud;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch
        return .cloud;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return .cloud;
    const f = parsed.object.get("fleet") orelse return .cloud;
    if (f != .string) return .cloud;
    return std.meta.stringToEnum(artifact.Origin, f.string) orelse .cloud;
}

/// Per-proxy status from profile.json, or an empty slice for a legacy run dir.
fn readStatuses(arena: std.mem.Allocator, io: std.Io, run_dir: []const u8) ![]artifact.ProxyRecord {
    const path = try std.fmt.allocPrint(arena, "{s}/profile.json", .{run_dir});
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch
        return &.{};

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const proxies = (parsed.object.get("proxies") orelse return &.{}).object;

    var out: std.ArrayList(artifact.ProxyRecord) = .empty;
    var it = proxies.iterator();
    while (it.next()) |e| {
        const o = e.value_ptr.*.object;
        const status_str = if (o.get("status")) |v| v.string else "ok";

        // Provenance — the version that answered, how it was built, and (for
        // zoxy) which commit. All of this was already being RECORDED in
        // profile.json and then dropped right here, so the report never saw
        // it: the build-parity note that suite.zig writes because it "must
        // travel WITH the numbers" reached no reader at all.
        var notes: std.ArrayList([]const u8) = .empty;
        if (o.get("notes")) |v| {
            if (v == .array) {
                for (v.array.items) |n| {
                    if (n == .string) try notes.append(arena, n.string);
                }
            }
        }

        try out.append(arena, .{
            .name = e.key_ptr.*,
            .status = std.meta.stringToEnum(artifact.Status, status_str) orelse .ok,
            .stage = if (o.get("stage")) |v| (if (v == .string)
                std.meta.stringToEnum(artifact.Stage, v.string)
            else
                null) else null,
            .err = strField(o, "error"),
            .version = strField(o, "version"),
            .zoxy_commit = strField(o, "zoxy_commit"),
            .zoxy_ref = strField(o, "zoxy_ref"),
            .zoxy_ref_sha = strField(o, "zoxy_ref_sha"),
            .build_info = strField(o, "build_info"),
            .notes = try notes.toOwnedSlice(arena),
        });
    }
    return out.toOwnedSlice(arena);
}

/// A string field of a profile.json proxy record, or null when it is absent or
/// JSON `null` (every one of these is nullable by design — a stock image has no
/// build descriptor, only zoxy has a commit).
fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bench: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

test {
    std.testing.refAllDecls(@This());
}

/// One proxy's ramp, as its own process.
///
/// Spawned by `bench suite` rather than called in-process, so a generator that
/// stops making progress can be KILLED on a deadline. Once zrk's `runner.run`
/// blocks there is no way to bound it from inside — zio owns the thread — and the
/// only previous bound was killing the whole suite, which cost every proxy queued
/// behind the wedged one.
///
/// Not in CONTRACT.md's original command list on purpose: that said "there is no
/// separate ramp subcommand", and this is the reason that changed.
fn cmdRamp(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();

    const prof_name = try flagValue(args, "--profile") orelse
        return fail("bench ramp: --profile is required", .{});
    const prof = profile.byName(prof_name) orelse
        return fail("bench ramp: unknown profile '{s}'", .{prof_name});
    const proxy = try flagValue(args, "--proxy") orelse
        return fail("bench ramp: --proxy is required", .{});
    const target = try flagValue(args, "--target") orelse
        return fail("bench ramp: --target is required", .{});
    const out_base = try flagValue(args, "--out-base") orelse
        return fail("bench ramp: --out-base is required", .{});
    const outcome_path = try flagValue(args, "--outcome") orelse
        return fail("bench ramp: --outcome is required", .{});
    const runid = try flagValue(args, "--runid") orelse "";

    const cad: ?std.Io.net.IpAddress = if (try flagValue(args, "--cadvisor")) |spec| blk: {
        const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse
            return fail("bench ramp: --cadvisor wants host:port", .{});
        const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch
            return fail("bench ramp: bad --cadvisor port", .{});
        break :blk try std.Io.net.IpAddress.parse(spec[0..colon], port);
    } else null;

    // Echo what the child actually parsed. The suite hands these across a process
    // boundary now, so a flag that silently failed to arrive shows up as a
    // `degraded` result with no cAdvisor samples and no explanation.
    redact.log("bench: [{s}] ramp child: profile={s} cadvisor={s}", .{
        proxy,
        prof.name,
        if (cad != null) "yes" else "none",
    });

    const outcome = try ramp.run(init.gpa, arena, .{
        .prof = prof,
        .proxy = proxy,
        .target = target,
        .cadvisor_addr = cad,
        .out_base = out_base,
        .runid = runid,
    });
    try ramp.writeOutcome(init.io, outcome_path, outcome);
    exit(0);
}

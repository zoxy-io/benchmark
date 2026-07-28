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
//!   bench ramp    ...                loadgen VM   one proxy's ramp (re-exec'd by suite)
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

const usage =
    \\usage: bench <command> [options]
    \\
    \\  suite   --profile <c1k|c10k> [--proxies a,b,c]   run the suite (loadgen VM)
    \\  ramp    --profile <name> --proxy <name> ...      one ramp (loadgen VM)
    \\  report  <rundir>                                 render report.json + report.html
    \\  index   <rundir>                                 build the Pages site
    \\  notify  <rundir> [--dry-run]                     post to Discord
    \\  sweep                                            delete orphaned fleet VMs
    \\  wait    <runid>                                  await the self-driving run
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "report")) return cmdReport(init, args[2..]);

    std.debug.print("bench: unknown command '{s}'\n\n{s}", .{ cmd, usage });
    std.process.exit(2);
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

    const meta = try readMeta(arena, io, run_dir);
    const ordered = try report.orderPresent(arena, meta.proxies);

    const inputs = try arena.alloc(report.ProxyInput, ordered.len);
    for (ordered, 0..) |name, k| {
        inputs[k] = .{ .name = name, .tags = meta.tagsFor(name) };
    }

    var g = try report.gather(gpa, arena, io, run_dir, inputs, prof.ref_rate, prof.ref_band);
    defer g.deinit();

    // profile.json carries per-proxy status; a legacy meta.json run dir has
    // none, in which case every present proxy is treated as ok.
    const statuses = readStatuses(arena, io, run_dir) catch &.{};

    const path = try std.fmt.allocPrint(arena, "{s}/report.json", .{run_dir});
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(file, io, &buf);

    try report.writeJson(
        arena,
        &fw.interface,
        g,
        meta.runid,
        generated,
        meta.ramp,
        prof.ref_rate,
        prof.ref_band,
    );
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
        try out.append(arena, .{
            .name = e.key_ptr.*,
            .status = std.meta.stringToEnum(artifact.Status, status_str) orelse .ok,
            .stage = if (o.get("stage")) |v| (if (v == .string)
                std.meta.stringToEnum(artifact.Stage, v.string)
            else
                null) else null,
            .err = if (o.get("error")) |v| (if (v == .string) v.string else null) else null,
        });
    }
    return out.toOwnedSlice(arena);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bench: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

test {
    std.testing.refAllDecls(@This());
}

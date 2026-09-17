//! bench — the benchmark harness: fleet orchestration, load ramp, and report
//! rendering in one static binary.
//!
//! One binary is built per run and used on both the CI runner and the loadgen
//! VM, so they cannot drift.
//!
//! Subcommands and where each runs:
//!   bench suite   --profile <name>   loadgen VM   drive every proxy, one ramp each
//!   bench report  <rundir>           CI runner    rundir -> report.json + report.html
//!   bench index   <rundir>           CI runner    -> _site/ (both profiles + trend)
//!   bench notify  <rundir>           CI runner    -> Discord embed + attachment
//!   bench sweep                      CI runner    delete orphaned VMs by label
//!   bench wait    <runid>            CI runner    poll for DONE, tail the log
//!
//! report/index/notify also build standalone as `bench-publish`
//! (publish_main.zig) for publish.yml.

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
pub const http = @import("http.zig");
pub const ycs = @import("ycs.zig");
pub const svg = @import("svg.zig");
pub const html = @import("html.zig");
pub const discord = @import("discord.zig");
pub const commands = @import("commands.zig");
pub const index = @import("index.zig");
pub const render = @import("render.zig");

const usage =
    \\usage: bench <command> [options]
    \\
    \\  suite   --profile <c100|c1k|c1k-tls|c1k-64|c1k-10k|c1k-100k|c10k|smoke> [--proxies a,b,c] [--local]
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

    // ::add-mask:: also covers output this process never sees (child stderr).
    redact.setCiMasking(std.process.Environ.getPosix(init.minimal.environ, "CI") != null);

    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "report")) return render.cmdReport(init, rest);
    if (std.mem.eql(u8, cmd, "sweep")) return render.exit(try commands.sweep(
        init.gpa,
        arena,
        init.io,
        commands.Env.read(init.minimal.environ),
    ));
    if (std.mem.eql(u8, cmd, "wait")) return cmdWait(init, rest);
    if (std.mem.eql(u8, cmd, "fetch")) return cmdFetch(init, rest);
    if (std.mem.eql(u8, cmd, "suite")) return cmdSuite(init, rest);
    if (std.mem.eql(u8, cmd, "notify")) return render.cmdNotify(init, rest);
    if (std.mem.eql(u8, cmd, "index")) return render.cmdIndex(init, rest);
    if (std.mem.eql(u8, cmd, "ramp")) return cmdRamp(init, rest);

    std.debug.print("bench: unknown command '{s}'\n\n{s}", .{ cmd, usage });
    std.process.exit(2);
}

fn cmdWait(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var env = commands.Env.read(init.minimal.environ);
    env.runid = try render.flagValue(args, "--runid") orelse env.runid;
    if (env.runid.len == 0) return render.fail("bench wait: --runid or BENCH_RUNID is required", .{});

    var opts: commands.WaitOptions = .{};
    // Lets the workflow keep each invocation under the IAM token's ~1h TTL and
    // re-mint between calls; exit 5 marks the chunk boundary.
    if (try render.flagValue(args, "--max-wait-s")) |v| {
        opts.deadline_s = std.fmt.parseUnsigned(u64, v, 10) catch
            return render.fail("bench wait: --max-wait-s must be a non-negative integer", .{});
    }

    const res = try commands.wait(init.gpa, arena, init.io, env, opts);
    switch (res) {
        .done => {
            std.debug.print("bench wait: run complete\n", .{});
            render.exit(0);
        },
        // A failed suite may still have partial artifacts worth publishing.
        .failed => render.exit(3),
        .never_booted => render.exit(1),
        // `--max-wait-s` ran out; the fleet may still be healthy, so retry
        // with a fresh token (unlike `never_booted`).
        .timed_out => render.exit(5),
    }
}

fn cmdFetch(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var env = commands.Env.read(init.minimal.environ);
    env.runid = try render.flagValue(args, "--runid") orelse env.runid;
    const out = try render.flagValue(args, "--out") orelse "results";
    if (env.runid.len == 0) return render.fail("bench fetch: --runid or BENCH_RUNID is required", .{});
    render.exit(try commands.fetch(init.gpa, arena, init.io, env, out));
}

fn cmdSuite(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    const environ = init.minimal.environ;

    const prof_name = try render.flagValue(args, "--profile") orelse
        return render.fail("bench suite: --profile is required", .{});
    const prof = profile.byName(prof_name) orelse
        return render.fail("bench suite: unknown profile '{s}'", .{prof_name});

    const spec = try render.flagValue(args, "--proxies") orelse
        commands.Env.get(environ, "BENCH_PROXIES");
    const proxies = try commands.parseProxies(arena, if (spec.len > 0) spec else "zoxy,haproxy,nginx,pingora,envoy");

    const runid = try render.flagValue(args, "--runid") orelse commands.Env.get(environ, "BENCH_RUNID");
    if (runid.len == 0) return render.fail("bench suite: --runid or BENCH_RUNID is required", .{});

    render.exit(try commands.runSuite(init.gpa, arena, init.io, environ, prof, proxies, runid, render.hasFlag(args, "--local")));
}

/// One proxy's ramp, as its own process, so `bench suite` can kill a wedged
/// generator on a deadline (zio owns the thread once `runner.run` blocks).
fn cmdRamp(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();

    const prof_name = try render.flagValue(args, "--profile") orelse
        return render.fail("bench ramp: --profile is required", .{});
    const prof = profile.byName(prof_name) orelse
        return render.fail("bench ramp: unknown profile '{s}'", .{prof_name});
    const proxy = try render.flagValue(args, "--proxy") orelse
        return render.fail("bench ramp: --proxy is required", .{});
    const target = try render.flagValue(args, "--target") orelse
        return render.fail("bench ramp: --target is required", .{});
    const out_base = try render.flagValue(args, "--out-base") orelse
        return render.fail("bench ramp: --out-base is required", .{});
    const outcome_path = try render.flagValue(args, "--outcome") orelse
        return render.fail("bench ramp: --outcome is required", .{});
    const runid = try render.flagValue(args, "--runid") orelse "";

    const cad: ?std.Io.net.IpAddress = if (try render.flagValue(args, "--cadvisor")) |spec| blk: {
        const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse
            return render.fail("bench ramp: --cadvisor wants host:port", .{});
        const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch
            return render.fail("bench ramp: bad --cadvisor port", .{});
        break :blk try std.Io.net.IpAddress.parse(spec[0..colon], port);
    } else null;

    // Echo parsed flags: a flag lost across the process boundary is otherwise
    // silent.
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
    render.exit(0);
}

test {
    std.testing.refAllDecls(@This());
}

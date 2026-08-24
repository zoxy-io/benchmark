//! bench-publish — the `report`/`index`/`notify` subset of `bench`, built as
//! its own binary so publish.yml doesn't pay to compile the fleet path
//! (`suite`/`remote`/`ramp`/`ycs`) or the `zio` dependency those pull in,
//! neither of which this job ever touches. `render.zig` is the shared
//! implementation; `main.zig` is the full CLI built for nightly.zig.

const std = @import("std");
const redact = @import("redact.zig");
const render = @import("render.zig");

const usage =
    \\usage: bench-publish <command> [options]
    \\
    \\  report  <rundir> [--profile <name>] [--base-url <url>]
    \\                                                   render report.json + report.html
    \\  index   <rundir> [--out <dir>] [--history <file>]
    \\                                                   build the Pages site
    \\  notify  <rundir> [--dry-run]                     post to Discord
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }

    // Same reasoning as main.zig: registering masks covers output this
    // process never sees itself.
    redact.setCiMasking(std.process.Environ.getPosix(init.minimal.environ, "CI") != null);

    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "report")) return render.cmdReport(init, rest);
    if (std.mem.eql(u8, cmd, "notify")) return render.cmdNotify(init, rest);
    if (std.mem.eql(u8, cmd, "index")) return render.cmdIndex(init, rest);

    std.debug.print("bench-publish: unknown command '{s}'\n\n{s}", .{ cmd, usage });
    std.process.exit(2);
}

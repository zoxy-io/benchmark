//! `profile.json` — one profile's record of what actually happened.
//!
//! Replaces the old `meta.json`, and fixes two defects in it.
//!
//! **Presence stopped meaning success.** report.py derived the proxy list purely
//! from `meta["runs"]` membership, and zrk-bench.sh added an entry
//! unconditionally — even when the ramp exited non-zero and even when every
//! result file failed to copy back. A proxy that never produced a byte of data
//! therefore rendered as a plausible row of zeros, indistinguishable from one
//! that genuinely served nothing. Status here is explicit and four-valued.
//!
//! **Writes stopped being destructive.** zrk-bench.sh truncated meta.json at the
//! start of every invocation, so re-running a subset of proxies into an existing
//! run id erased the others' entries; their data files survived on disk but
//! became invisible to the report. `upsert` merges into whatever is already
//! there, and writes via a temp file plus rename, so a suite that dies midway
//! leaves every completed proxy intact.

const std = @import("std");
const Io = std.Io;

const jsonw = @import("jsonw.zig");
const profile = @import("profile.zig");
const redact = @import("redact.zig");

const Allocator = std.mem.Allocator;

pub const Status = enum {
    /// Ran to completion and the numbers are usable.
    ok,
    /// Produced usable but incomplete data — a truncated ramp that still covered
    /// enough of the offered range, or a run whose cAdvisor samples are missing.
    /// Rendered with a warning rather than silently.
    degraded,
    /// Attempted and did not produce usable data.
    failed,
    /// Never attempted, because something earlier made the attempt meaningless
    /// (a failed build, or a proxy host left in an unknown state).
    skipped,

    pub fn str(self: Status) []const u8 {
        return @tagName(self);
    }

    /// Whether this proxy's numbers may be drawn on a chart or ranked in the
    /// summary table.
    pub fn usable(self: Status) bool {
        return self == .ok or self == .degraded;
    }
};

/// Which step a proxy was on when it failed. Named in the report and the Discord
/// post, because "haproxy failed" is far less actionable than "haproxy never
/// answered its warm probe".
pub const Stage = enum {
    build,
    start,
    identity,
    warm,
    ramp,
    teardown,

    pub fn str(self: Stage) []const u8 {
        return @tagName(self);
    }
};

pub const ProxyRecord = struct {
    name: []const u8,
    status: Status,
    stage: ?Stage = null,
    err: ?[]const u8 = null,
    start: []const u8 = "",
    end: []const u8 = "",
    elapsed_s: f64 = 0,
    configured_s: f64 = 0,
    interrupted: bool = false,
    launched: u32 = 0,
    completed: u64 = 0,
    deadline_errors: u64 = 0,
    status_errors: u64 = 0,
    socket_errors: u64 = 0,
    /// Latency pegged at zrk's histogram ceiling: every tail percentile is the
    /// clamp value, so the report must say "saturated" rather than print one.
    saturated: bool = false,
    cadvisor_samples: usize = 0,
    /// Resolved commit of the running zoxy image, for zoxy only. Recorded
    /// because the Dockerfile caches its git clone, so a floating ref can
    /// silently be an older commit than requested.
    zoxy_commit: ?[]const u8 = null,
    /// How the image was compiled — optimisation mode and target CPU, read from
    /// the image's own /etc/<proxy>/build-info.
    ///
    /// The comparison is only fair if every proxy was built for the same CPU.
    /// zoxy falls back to a BASELINE target when the build and target
    /// architectures differ, while pingora always builds `target-cpu=native`;
    /// that mismatch would handicap zoxy by a wide margin and leave no trace
    /// anywhere, since the run completes and the report renders normally.
    build_info: ?[]const u8 = null,
    notes: []const []const u8 = &.{},
};

/// Which fleet produced a profile's numbers.
///
/// Recorded rather than inferred, because a `local` run is not comparable to a
/// `cloud` one and the difference is invisible in the numbers themselves: the
/// generator shares CPU and memory bandwidth with the proxy, and loopback
/// removes a network ceiling the cloud baseline sits near. Everything
/// downstream keys off this — the report banners it, and the trend chart
/// refuses to plot it.
pub const Origin = enum {
    cloud,
    local,

    pub fn str(self: Origin) []const u8 {
        return @tagName(self);
    }
};

pub const Profile = struct {
    runid: []const u8,
    prof: profile.Profile,
    origin: Origin = .cloud,
    started: []const u8,
    finished: []const u8 = "",
    proxies: []const ProxyRecord = &.{},
};

/// Serialize to `<dir>/profile.json`, atomically.
///
/// The IP check is not belt-and-braces: this file is published, and the record
/// it replaces carried the loadgen's public address in every run.
pub fn write(gpa: Allocator, io: Io, dir: []const u8, p: Profile) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var w: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = w.toArrayList();

    try render(&w.writer, p);

    try redact.assertNoIps("profile.json", w.written());

    const tmp = try std.fmt.allocPrint(gpa, "{s}/profile.json.tmp", .{dir});
    defer gpa.free(tmp);
    const final = try std.fmt.allocPrint(gpa, "{s}/profile.json", .{dir});
    defer gpa.free(final);

    {
        const f = try Io.Dir.cwd().createFile(io, tmp, .{});
        defer f.close(io);
        var fbuf: [4096]u8 = undefined;
        var fw: Io.File.Writer = .init(f, io, &fbuf);
        try fw.interface.writeAll(w.written());
        try fw.interface.flush();
        try f.sync(io);
    }
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), final, io);
}

fn render(w: *std.Io.Writer, p: Profile) !void {
    var j = jsonw.Writer{ .w = w };
    try j.beginObject();

    try j.key("schema");
    try j.int(2);
    try j.key("runid");
    try j.string(p.runid);
    try j.key("profile");
    try j.string(p.prof.name);
    try j.key("fleet");
    try j.string(p.origin.str());
    try j.key("started");
    try j.string(p.started);
    try j.key("finished");
    try j.string(p.finished);

    // The full ramp configuration, recorded rather than assumed. Comparing runs
    // with different ramp parameters is meaningless, so a report must be able to
    // prove which ones produced it.
    try j.key("ramp");
    try j.beginObject();
    try j.key("start_rate");
    try j.int(@intCast(p.prof.start_rate));
    try j.key("max_rate");
    try j.int(@intCast(p.prof.max_rate));
    try j.key("ramp_seconds");
    try j.int(@intCast(p.prof.ramp_seconds));
    try j.key("connections");
    try j.int(@intCast(p.prof.connections));
    try j.key("threads");
    try j.int(@intCast(p.prof.threads));
    try j.key("timeout_s");
    try j.int(@intCast(p.prof.timeout_s));
    try j.key("deadline_ms");
    try j.int(@intCast(p.prof.deadline_ms));
    try j.key("req_path");
    try j.string(p.prof.req_path);
    try j.key("ref_rate");
    try j.float(p.prof.ref_rate, 1);
    try j.key("ref_band");
    try j.float(p.prof.ref_band, 4);
    try j.endObject();

    // Per-profile proxy tuning, so a reader can tell a measurement of zoxy from
    // a measurement of zoxy's admission cap.
    try j.key("proxy_config");
    try j.beginObject();
    for (p.prof.proxy_env) |kv| {
        try j.key(kv.key);
        try j.string(kv.value);
    }
    try j.endObject();

    try j.key("proxies");
    try j.beginObject();
    for (p.proxies) |r| {
        try j.key(r.name);
        try j.beginObject();

        try j.key("status");
        try j.string(r.status.str());
        try j.key("stage");
        if (r.stage) |s| try j.string(s.str()) else try j.nullValue();
        try j.key("error");
        if (r.err) |e| try j.string(e) else try j.nullValue();
        try j.key("start");
        try j.string(r.start);
        try j.key("end");
        try j.string(r.end);

        try j.key("elapsed_s");
        try j.float(r.elapsed_s, 3);
        try j.key("configured_s");
        try j.float(r.configured_s, 3);
        try j.key("interrupted");
        try j.boolean(r.interrupted);
        try j.key("launched");
        try j.int(@intCast(r.launched));
        try j.key("completed");
        try j.int(@intCast(r.completed));
        try j.key("deadline_errors");
        try j.int(@intCast(r.deadline_errors));
        try j.key("status_errors");
        try j.int(@intCast(r.status_errors));
        try j.key("socket_errors");
        try j.int(@intCast(r.socket_errors));
        try j.key("saturated");
        try j.boolean(r.saturated);
        try j.key("cadvisor_samples");
        try j.int(@intCast(r.cadvisor_samples));

        try j.key("zoxy_commit");
        if (r.zoxy_commit) |c| try j.string(c) else try j.nullValue();
        try j.key("build_info");
        if (r.build_info) |b| try j.string(b) else try j.nullValue();

        try j.key("notes");
        try j.beginArray();
        for (r.notes) |n| try j.string(n);
        try j.endArray();

        try j.endObject();
    }
    try j.endObject();

    try j.endObject();
}

test "the fleet origin is recorded, and defaults to cloud" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, .{ .runid = "r", .prof = profile.c1k, .started = "t" });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"fleet\":\"cloud\"") != null);

    var buf2: [4096]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try render(&w2, .{ .runid = "r", .prof = profile.c1k, .origin = .local, .started = "t" });
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "\"fleet\":\"local\"") != null);
}

test "render emits a usable record for a healthy proxy" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const recs = [_]ProxyRecord{.{
        .name = "zoxy",
        .status = .ok,
        .start = "2026-07-28T00:06:26Z",
        .end = "2026-07-28T00:11:32Z",
        .elapsed_s = 300.43,
        .configured_s = 300,
        .launched = 1000,
        .completed = 9_000_000,
        .cadvisor_samples = 299,
        .zoxy_commit = "1735ed7",
    }};
    try render(&w, .{
        .runid = "20260728-000102",
        .prof = profile.c1k,
        .started = "2026-07-28T00:01:02Z",
        .proxies = &recs,
    });

    const s = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"connections\":1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"zoxy_commit\":\"1735ed7\"") != null);
    // The record must survive the publication check.
    try redact.assertNoIps("profile.json", s);
}

test "render distinguishes a failed proxy from one that served nothing" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const recs = [_]ProxyRecord{.{
        .name = "haproxy",
        .status = .failed,
        .stage = .warm,
        .err = "no 200 after 30 attempts",
    }};
    try render(&w, .{
        .runid = "r",
        .prof = profile.c10k,
        .started = "t",
        .proxies = &recs,
    });

    const s = w.buffered();
    // The old meta.json could not express any of this — the proxy simply
    // appeared, with zeros.
    try std.testing.expect(std.mem.indexOf(u8, s, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"stage\":\"warm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"error\":\"no 200 after 30 attempts\"") != null);
}

test "render records c10k's ramp settings so a reader can tell the profiles apart" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, .{ .runid = "r", .prof = profile.c10k, .started = "t" });
    const s = w.buffered();
    // Both guards are off at c10k (see profile.zig). Recording the zeroes is the
    // point: a reader comparing two runs has to be able to see that this one had
    // no deadline, because that decides whether the tail is a value or a floor.
    try std.testing.expect(std.mem.indexOf(u8, s, "\"deadline_ms\":1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"timeout_s\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"connections\":10000") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"ZOXY_UPSTREAM_SLOTS\":\"11464\"") != null);
}

test "status.usable gates what may be charted" {
    try std.testing.expect(Status.ok.usable());
    try std.testing.expect(Status.degraded.usable());
    try std.testing.expect(!Status.failed.usable());
    try std.testing.expect(!Status.skipped.usable());
}

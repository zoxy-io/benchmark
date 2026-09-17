//! `profile.json`: one profile's record of what actually happened.
//!
//! Status is explicit, so a proxy that produced no data never renders as
//! zeros. `upsert` merges and writes via temp file plus rename, so re-runs and
//! mid-suite deaths never erase other proxies' entries.

const std = @import("std");
const Io = std.Io;

const jsonw = @import("jsonw.zig");
const profile = @import("profile.zig");
const redact = @import("redact.zig");

const Allocator = std.mem.Allocator;

pub const Status = enum {
    /// Ran to completion and the numbers are usable.
    ok,
    /// Usable but incomplete (truncated ramp, missing cAdvisor samples);
    /// rendered with a warning.
    degraded,
    /// Attempted and did not produce usable data.
    failed,
    /// Never attempted (e.g. a failed build or a host in an unknown state).
    skipped,

    pub fn str(self: Status) []const u8 {
        return @tagName(self);
    }

    /// Whether the numbers may be charted or ranked.
    pub fn usable(self: Status) bool {
        return self == .ok or self == .degraded;
    }
};

/// Which step a proxy was on when it failed, named in the report and Discord.
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
    /// Latency pegged at zrk's histogram ceiling; report "saturated", not a
    /// value.
    saturated: bool = false,
    cadvisor_samples: usize = 0,
    /// What the running proxy says it is (`haproxy -v`, `envoy --version`,
    /// `zoxy --version`, or the image reference). Read from the container that
    /// served the ramp, not the tag compose.yaml asked for.
    version: ?[]const u8 = null,
    /// Resolved commit of the running zoxy image (zoxy only). The Dockerfile
    /// caches its clone, so a floating ref can be stale.
    zoxy_commit: ?[]const u8 = null,
    /// The ref the build resolved to (never the literal `release`) and its sha
    /// resolved from GitHub. `zoxy_commit != zoxy_ref_sha` means a stale cached
    /// build and degrades the record.
    zoxy_ref: ?[]const u8 = null,
    zoxy_ref_sha: ?[]const u8 = null,
    /// Optimisation mode and target CPU, from /etc/<proxy>/build-info. Fairness
    /// needs the same CPU target: zoxy can fall back to a baseline target while
    /// pingora builds `target-cpu=native`.
    build_info: ?[]const u8 = null,
    /// Access-log lines zoxy dropped during the ramp (zoxy only; null if
    /// unreadable). Dropping is cheaper than writing, so nonzero means an
    /// unfair advantage; zero means the comparison is clean.
    access_log_dropped: ?u64 = null,
    /// Connections zoxy refused for want of a TLS session slot. Null for other
    /// proxies, plaintext profiles, or an unreadable counter. Nonzero means the
    /// ramp measured the pool cap (`conn_slots`) rather than zoxy's TLS.
    shed_tls_engines: ?u64 = null,
    notes: []const []const u8 = &.{},
};

/// Which fleet produced a profile's numbers. A `local` run is not comparable
/// to `cloud` (shared CPU, no network ceiling); the report banners it and the
/// trend refuses to plot it.
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

/// Serialize to `<dir>/profile.json`, atomically. This file is published, so
/// it must pass the IP check.
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

    // Full ramp configuration: runs with different ramps are not comparable.
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
    // Transport, recorded like every other ramp parameter.
    try j.key("tls");
    try j.boolean(p.prof.tls);
    try j.key("ref_rate");
    try j.float(p.prof.ref_rate, 1);
    try j.key("ref_band");
    try j.float(p.prof.ref_band, 4);
    try j.endObject();

    // Per-profile proxy tuning, e.g. to tell zoxy from its admission cap.
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

        try j.key("version");
        if (r.version) |v| try j.string(v) else try j.nullValue();
        try j.key("zoxy_commit");
        if (r.zoxy_commit) |c| try j.string(c) else try j.nullValue();
        try j.key("zoxy_ref");
        if (r.zoxy_ref) |c| try j.string(c) else try j.nullValue();
        try j.key("zoxy_ref_sha");
        if (r.zoxy_ref_sha) |c| try j.string(c) else try j.nullValue();
        try j.key("build_info");
        if (r.build_info) |b| try j.string(b) else try j.nullValue();
        try j.key("access_log_dropped");
        if (r.access_log_dropped) |d| try j.int(@intCast(d)) else try j.nullValue();
        try j.key("shed_tls_engines");
        if (r.shed_tls_engines) |d| try j.int(@intCast(d)) else try j.nullValue();

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
    try std.testing.expect(std.mem.indexOf(u8, s, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"stage\":\"warm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"error\":\"no 200 after 30 attempts\"") != null);
}

test "render records c10k's ramp settings so a reader can tell the profiles apart" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, .{ .runid = "r", .prof = profile.c10k, .started = "t" });
    const s = w.buffered();
    // Both guards are off at c10k (see profile.zig); the zeroes must be
    // recorded, since they decide whether the tail is a value or a floor.
    try std.testing.expect(std.mem.indexOf(u8, s, "\"deadline_ms\":1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"timeout_s\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"connections\":10000") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"ZOXY_UPSTREAM_SLOTS\":\"11457\"") != null);
}

test "status.usable gates what may be charted" {
    try std.testing.expect(Status.ok.usable());
    try std.testing.expect(Status.degraded.usable());
    try std.testing.expect(!Status.failed.usable());
    try std.testing.expect(!Status.skipped.usable());
}

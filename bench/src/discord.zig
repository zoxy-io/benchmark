//! Posts the nightly summary to a Discord webhook.
//!
//! One embed per profile carrying the headline table, plus each profile's
//! report.html as a file attachment. The table goes in the embed description as
//! a fenced code block because Discord embeds have no table primitive and
//! monospace alignment is the standard idiom.
//!
//! Two things this must get right, because the channel is public and the message
//! is the only thing most people will ever read:
//!
//! * a failed proxy shows as FAILED with the stage it died at, never as a zero;
//! * a saturated latency histogram shows as ">=60s", never as a number, since at
//!   the clamp every tail percentile is the ceiling rather than a measurement.

const std = @import("std");

const analysis = @import("analysis.zig");
const artifact = @import("artifact.zig");
const jsonw = @import("jsonw.zig");
const redact = @import("redact.zig");
const svg = @import("svg.zig");

const Allocator = std.mem.Allocator;

/// Amber when every proxy is ok; the alarm hue when any failed. Both are the
/// report's own palette, so the post and the page read as one artifact.
pub const color_ok: u32 = 0xfb9e0e;
pub const color_fail: u32 = 0xf2705b;

pub const Row = struct {
    name: []const u8,
    status: artifact.Status,
    stage: ?artifact.Stage = null,
    sustained: f64 = 0,
    p50_ms: ?f64 = null,
    p99_ms: ?f64 = null,
    saturated: bool = false,
    mem: ?f64 = null,
    /// Change in sustained throughput against the previous night, as a ratio.
    delta: ?f64 = null,
};

pub const Embed = struct {
    title: []const u8,
    /// Reference rate the latency columns were read at; stated because it
    /// differs per profile.
    ref_rate: f64,
    url: []const u8 = "",
    footer: []const u8 = "",
    rows: []const Row,

    pub fn anyFailed(self: Embed) bool {
        for (self.rows) |r| {
            if (r.status == .failed or r.status == .skipped) return true;
        }
        return false;
    }
};

pub const Attachment = struct {
    filename: []const u8,
    content_type: []const u8,
    bytes: []const u8,
};

/// Discord's documented per-message caps. Exceeding any of them is a 400, so
/// they are asserted and the table truncated rather than discovered at runtime.
pub const limits = struct {
    pub const embeds = 10;
    pub const files = 10;
    pub const description = 4096;
    pub const total_embed = 6000;
};

/// Render one embed's headline table.
pub fn renderTable(arena: Allocator, e: Embed) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var w: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);

    try w.writer.writeAll("```\n");
    try w.writer.print("{s:<9} {s:>10} {s:>9} {s:>9} {s:>9} {s:>8}\n", .{
        "proxy", "sustained", "p50", "p99", "peak mem", "vs prev",
    });

    var num: [64]u8 = undefined;
    for (e.rows) |r| {
        if (!r.status.usable()) {
            // No columns at all for a proxy that produced nothing — a row of
            // dashes with a reason, never zeros that read as a measurement.
            const why = if (r.stage) |s| s.str() else "no data";
            try w.writer.print("{s:<9} {s:>10} · {s}\n", .{ r.name, "FAILED", why });
            continue;
        }

        try w.writer.print("{s:<9} {s:>10}", .{ r.name, svg.fmtSi(&num, r.sustained) });

        if (r.p50_ms) |v| {
            try w.writer.print(" {d:>7.2}ms", .{v});
        } else {
            try w.writer.print(" {s:>9}", .{"—"});
        }

        if (r.saturated) {
            // The histogram clamped; printing a number here would be a fiction.
            try w.writer.print(" {s:>9}", .{"≥60s"});
        } else if (r.p99_ms) |v| {
            try w.writer.print(" {d:>7.2}ms", .{v});
        } else {
            try w.writer.print(" {s:>9}", .{"—"});
        }

        if (r.mem) |m| {
            try w.writer.print(" {s:>9}", .{svg.fmtBytes(&num, m)});
        } else {
            try w.writer.print(" {s:>9}", .{"—"});
        }

        if (r.delta) |d| {
            // Explicit sign: "+2.4%" and "-3.1%" read as direction at a glance,
            // where bare numbers do not.
            const pct = d * 100;
            var db: [16]u8 = undefined;
            const txt = std.fmt.bufPrint(&db, "{s}{d:.1}%", .{ if (pct >= 0) "+" else "", pct }) catch "?";
            try w.writer.print(" {s:>8}", .{txt});
        } else {
            try w.writer.print(" {s:>8}", .{"—"});
        }

        if (r.status == .degraded) try w.writer.writeAll("  ⚠");
        try w.writer.writeByte('\n');
    }
    try w.writer.writeAll("```");

    var out = w.toArrayList();
    return out.toOwnedSlice(arena);
}

/// Build the `payload_json` part of the multipart body.
pub fn renderPayload(
    arena: Allocator,
    content: []const u8,
    embeds: []const Embed,
    files: []const Attachment,
) ![]const u8 {
    std.debug.assert(embeds.len <= limits.embeds);
    std.debug.assert(files.len <= limits.files);

    var buf: std.ArrayList(u8) = .empty;
    var w: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    var j = jsonw.Writer{ .w = &w.writer };

    try j.beginObject();
    try j.key("content");
    try j.string(content);

    try j.key("embeds");
    try j.beginArray();
    for (embeds) |e| {
        var table = try renderTable(arena, e);
        if (table.len > limits.description) table = table[0..limits.description];

        try j.beginObject();
        try j.key("title");
        try j.string(e.title);
        try j.key("description");
        try j.string(table);
        try j.key("color");
        try j.int(@intCast(if (e.anyFailed()) color_fail else color_ok));
        if (e.url.len > 0) {
            try j.key("url");
            try j.string(e.url);
        }
        if (e.footer.len > 0) {
            try j.key("footer");
            try j.beginObject();
            try j.key("text");
            try j.string(e.footer);
            try j.endObject();
        }
        try j.endObject();
    }
    try j.endArray();

    try j.key("attachments");
    try j.beginArray();
    for (files, 0..) |f, i| {
        try j.beginObject();
        try j.key("id");
        try j.int(@intCast(i));
        try j.key("filename");
        try j.string(f.filename);
        try j.endObject();
    }
    try j.endArray();

    try j.endObject();

    var out = w.toArrayList();
    return out.toOwnedSlice(arena);
}

/// Assemble the full multipart/form-data body.
pub fn buildMultipart(
    arena: Allocator,
    boundary: []const u8,
    payload_json: []const u8,
    files: []const Attachment,
) ![]const u8 {
    // A boundary occurring inside a part would split the body at the wrong
    // place. It is random, so this should never fire — but a silently corrupted
    // upload is worse than a loud failure.
    if (std.mem.indexOf(u8, payload_json, boundary) != null) return error.BoundaryCollision;
    for (files) |f| {
        if (std.mem.indexOf(u8, f.bytes, boundary) != null) return error.BoundaryCollision;
    }

    var buf: std.ArrayList(u8) = .empty;
    var w: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);

    try w.writer.print("--{s}\r\n", .{boundary});
    try w.writer.writeAll("Content-Disposition: form-data; name=\"payload_json\"\r\n");
    try w.writer.writeAll("Content-Type: application/json\r\n\r\n");
    try w.writer.writeAll(payload_json);
    try w.writer.writeAll("\r\n");

    for (files, 0..) |f, i| {
        try w.writer.print("--{s}\r\n", .{boundary});
        try w.writer.print(
            "Content-Disposition: form-data; name=\"files[{d}]\"; filename=\"{s}\"\r\n",
            .{ i, f.filename },
        );
        try w.writer.print("Content-Type: {s}\r\n\r\n", .{f.content_type});
        try w.writer.writeAll(f.bytes);
        try w.writer.writeAll("\r\n");
    }

    try w.writer.print("--{s}--\r\n", .{boundary});

    var out = w.toArrayList();
    return out.toOwnedSlice(arena);
}

pub fn randomBoundary(io: std.Io, buf: *[32]u8) []const u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    return std.fmt.bufPrint(buf, "{x}", .{&raw}) catch "benchboundary0000";
}

/// POST the message. `dry_run` prints what would be sent and returns.
pub fn post(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    webhook: []const u8,
    content: []const u8,
    embeds: []const Embed,
    files: []const Attachment,
    dry_run: bool,
) !void {
    const payload = try renderPayload(arena, content, embeds, files);

    var bbuf: [32]u8 = undefined;
    const boundary = randomBoundary(io, &bbuf);
    const body = try buildMultipart(arena, boundary, payload, files);

    // This is published. Refuse to send rather than leak an address.
    try redact.assertNoIps("the Discord message", body);

    if (dry_run) {
        std.debug.print("bench: --dry-run, would POST {d} bytes ({d} embeds, {d} files)\n{s}\n", .{
            body.len, embeds.len, files.len, payload,
        });
        return;
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const ctype = try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{boundary});

    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const res = try client.fetch(.{
            .location = .{ .url = webhook },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{.{ .name = "content-type", .value = ctype }},
        });
        switch (res.status) {
            .ok, .no_content => return,
            .too_many_requests => {
                // Back off before retrying; hammering straight away just gets
                // rate limited again.
                io.sleep(.fromNanoseconds(std.time.ns_per_s * @as(u64, attempt + 1) * 2), .awake) catch {};
                continue;
            },
            else => {
                // Status only: an error body can echo request content back.
                std.debug.print("bench: Discord returned {d}\n", .{@intFromEnum(res.status)});
                return error.DiscordPostFailed;
            },
        }
    }
    return error.DiscordPostFailed;
}

test "the table shows a failed proxy as FAILED, never as zeros" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]Row{
        .{ .name = "zoxy", .status = .ok, .sustained = 43120, .p50_ms = 0.42, .p99_ms = 1.10, .mem = 24 * 1024 * 1024, .delta = 0.024 },
        .{ .name = "haproxy", .status = .failed, .stage = .warm },
    };
    const table = try renderTable(arena, .{ .title = "c1k", .ref_rate = 2000, .rows = &rows });

    try std.testing.expect(std.mem.indexOf(u8, table, "FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "warm") != null);
    // The failed row must carry no throughput figure whatsoever.
    const hap = std.mem.indexOf(u8, table, "haproxy").?;
    const line_end = std.mem.indexOfScalarPos(u8, table, hap, '\n') orelse table.len;
    try std.testing.expect(std.mem.indexOf(u8, table[hap..line_end], "0") == null);
}

test "a saturated histogram prints as a floor, not a number" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]Row{.{
        .name = "zoxy",
        .status = .ok,
        .sustained = 20000,
        .p50_ms = 5,
        // What a real c10k run recorded before the deadline SLO existed.
        .p99_ms = 60014.592,
        .saturated = true,
    }};
    const table = try renderTable(arena, .{ .title = "c10k", .ref_rate = 8000, .rows = &rows });

    try std.testing.expect(std.mem.indexOf(u8, table, "≥60s") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "60014") == null);
}

test "the delta column is explicitly signed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]Row{
        .{ .name = "zoxy", .status = .ok, .sustained = 100, .delta = 0.024 },
        .{ .name = "haproxy", .status = .ok, .sustained = 100, .delta = -0.031 },
    };
    const table = try renderTable(arena, .{ .title = "t", .ref_rate = 2000, .rows = &rows });
    try std.testing.expect(std.mem.indexOf(u8, table, "+2.4%") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "-3.1%") != null);
}

test "embed colour reflects whether anything failed" {
    const ok_rows = [_]Row{.{ .name = "zoxy", .status = .ok }};
    const bad_rows = [_]Row{ .{ .name = "zoxy", .status = .ok }, .{ .name = "haproxy", .status = .failed } };

    try std.testing.expect(!(Embed{ .title = "t", .ref_rate = 2000, .rows = &ok_rows }).anyFailed());
    try std.testing.expect((Embed{ .title = "t", .ref_rate = 2000, .rows = &bad_rows }).anyFailed());

    // A skipped proxy is also a reason to flag the run.
    const skipped = [_]Row{.{ .name = "zoxy", .status = .skipped }};
    try std.testing.expect((Embed{ .title = "t", .ref_rate = 2000, .rows = &skipped }).anyFailed());
}

test "multipart body frames every part and refuses a boundary collision" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_]Attachment{.{
        .filename = "report-c1k.html",
        .content_type = "text/html",
        .bytes = "<!doctype html>hello",
    }};
    const body = try buildMultipart(arena, "BOUNDARY", "{\"content\":\"x\"}", &files);

    try std.testing.expect(std.mem.startsWith(u8, body, "--BOUNDARY\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, body, "--BOUNDARY--\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"payload_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "filename=\"report-c1k.html\"") != null);

    // A part containing the boundary would split the body at the wrong place.
    const evil = [_]Attachment{.{ .filename = "x", .content_type = "text/html", .bytes = "..BOUNDARY.." }};
    try std.testing.expectError(error.BoundaryCollision, buildMultipart(arena, "BOUNDARY", "{}", &evil));
}

test "payload declares one attachment id per file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]Row{.{ .name = "zoxy", .status = .ok, .sustained = 1 }};
    const embeds = [_]Embed{.{ .title = "c1k", .ref_rate = 2000, .rows = &rows }};
    const files = [_]Attachment{
        .{ .filename = "report-c1k.html", .content_type = "text/html", .bytes = "a" },
        .{ .filename = "report-c10k.html", .content_type = "text/html", .bytes = "b" },
    };
    const payload = try renderPayload(arena, "nightly", &embeds, &files);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"id\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "report-c10k.html") != null);
}

test "randomBoundary is not a constant" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    // A fixed boundary would be guessable from a part's content, and a
    // collision splits the multipart body at the wrong place.
    try std.testing.expect(!std.mem.eql(u8, randomBoundary(io, &a), randomBoundary(io, &b)));
}

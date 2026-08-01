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
    /// The row's leading caveat, printed under the table when the row is not
    /// plain `ok`. Without it a degraded row is a bare "⚠" that says something
    /// is wrong but not what — and the caveat this exists for, a stale zoxy
    /// build, is the one that decides whether the number above it means
    /// anything at all.
    note: ?[]const u8 = null,
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

    // Caveats under the table rather than in it — they are sentences, and the
    // columns above are aligned to stay readable in Discord's monospace block.
    for (e.rows) |r| {
        if (r.status == .ok) continue;
        const n = r.note orelse continue;
        try w.writer.print("\n⚠ {s}: {s}\n", .{ r.name, n });
    }
    try w.writer.writeAll("```");

    // The embed title is a link, but a bare URL under the table is what people
    // actually click, and it survives being quoted or copied elsewhere.
    if (e.url.len > 0) try w.writer.print("\n[full report]({s})", .{e.url});

    var out = w.toArrayList();
    return out.toOwnedSlice(arena);
}

/// Cut `table` to fit Discord's description limit, if it doesn't already.
///
/// A raw `table[0..limits.description]` — the previous behaviour — can land
/// mid-way through the closing ` ``` ` fence or the `[full report]` link,
/// leaving an unterminated code block, and can split a multi-byte UTF-8
/// sequence, which is invalid inside a JSON string. Unreachable at today's
/// proxy count (~5 rows fits in a few hundred bytes), but silent at the
/// moment the roster grows past it rather than caught here.
///
/// Always drops the tail and rebuilds a clean closing sequence, regardless of
/// where the cut lands relative to the original fence/link — simpler and
/// exactly as correct as trying to detect whether the original tail survived
/// the cut.
fn truncateTable(arena: Allocator, table: []const u8, url: []const u8) ![]const u8 {
    if (table.len <= limits.description) return table;

    const suffix = if (url.len > 0)
        try std.fmt.allocPrint(arena, "\n```\n[full report]({s})", .{url})
    else
        "\n```";

    var cut = limits.description -| suffix.len;
    // Never split a multi-byte UTF-8 sequence — a continuation byte has its
    // top two bits as 10.
    while (cut > 0 and (table[cut] & 0xC0) == 0x80) cut -= 1;

    return std.fmt.allocPrint(arena, "{s}{s}", .{ table[0..cut], suffix });
}

/// Build the `payload_json` part of the multipart body.
pub fn renderPayload(
    arena: Allocator,
    content: []const u8,
    embeds: []const Embed,
    files: []const Attachment,
) ![]const u8 {
    // Runtime checks, not `std.debug.assert`: the nightly binary ships
    // ReleaseFast (see .github/workflows/nightly.yml), where `assert`'s
    // `unreachable` is undefined behavior rather than a caught panic, for a
    // condition driven by runtime data (how many profiles/proxies ran) that
    // can plausibly change, not a fixed internal invariant.
    if (embeds.len > limits.embeds) return error.TooManyEmbeds;
    if (files.len > limits.files) return error.TooManyFiles;

    var buf: std.ArrayList(u8) = .empty;
    var w: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    var j = jsonw.Writer{ .w = &w.writer };

    try j.beginObject();
    try j.key("content");
    try j.string(content);

    try j.key("embeds");
    try j.beginArray();
    for (embeds) |e| {
        const table = try truncateTable(arena, try renderTable(arena, e), e.url);

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
/// Add `wait=true` to a webhook URL, so Discord replies 200 with the created
/// message instead of 204 No Content.
///
/// This is for the CONFIRMATION, not for the hang — a 200 means the message was
/// actually created, where 204 only means the request was accepted. The hang
/// that 204 used to cause is fixed by `keep_alive = false` at the call site, and
/// that fix does not depend on Discord honouring this parameter (httpbingo.org
/// ignores it and answers 204 regardless, which is exactly the case used to
/// verify the real fix).
pub fn withWait(arena: Allocator, webhook: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, webhook, "wait=") != null) return webhook;
    const sep: u8 = if (std.mem.indexOfScalar(u8, webhook, '?') != null) '&' else '?';
    return std.fmt.allocPrint(arena, "{s}{c}wait=true", .{ webhook, sep });
}

test "withWait appends the query the response depends on" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    try std.testing.expectEqualStrings(
        "https://discord.com/api/webhooks/1/t?wait=true",
        try withWait(arena, "https://discord.com/api/webhooks/1/t"),
    );
    // An existing query string keeps its parameters.
    try std.testing.expectEqualStrings(
        "https://x/y?thread_id=9&wait=true",
        try withWait(arena, "https://x/y?thread_id=9"),
    );
    // Already asked for: left exactly as-is, so no duplicate parameter.
    try std.testing.expectEqualStrings(
        "https://x/y?wait=true",
        try withWait(arena, "https://x/y?wait=true"),
    );
}

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

    const ctype = try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{boundary});
    const url = try withWait(arena, webhook);

    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const outcome = attemptOnce(gpa, arena, io, url, ctype, body) catch |e| {
            // A transport-level failure — DNS, connection refused/reset, a TLS
            // handshake failure. This used to be a bare `try` on the fetch,
            // which skipped this whole loop: the ONLY retried failure mode was
            // a response that actually arrived with a bad status. For a
            // one-shot call from an unattended job, a connection that never
            // completes is the more likely way for this to fail.
            std.debug.print("bench: Discord POST failed ({s}), attempt {d}/3\n", .{ @errorName(e), attempt + 1 });
            io.sleep(.fromNanoseconds(std.time.ns_per_s * @as(u64, attempt + 1) * 2), .awake) catch {};
            continue;
        };
        const res = outcome orelse {
            std.debug.print("bench: Discord POST timed out after {d}s (attempt {d}/3)\n", .{
                fetch_deadline_ns / std.time.ns_per_s, attempt + 1,
            });
            io.sleep(.fromNanoseconds(std.time.ns_per_s * @as(u64, attempt + 1) * 2), .awake) catch {};
            continue;
        };
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

/// How long a single attempt gets before it is abandoned as failed.
///
/// `std.http.Client.fetch` has no deadline of its own — nothing here bounds a
/// stalled connect, or a server that accepts the connection and then drips the
/// response forever. This borrows `remote.zig`'s `Waiter` shape: run the call
/// on its own thread, poll an atomic flag, give up on the wall clock if it
/// never flips. A webhook body here is a few KB of JSON with no attachment
/// (see `renderPayload`'s `files` — always empty on the real call path, see
/// `commands.zig`), so 30s is generous even on a slow connection.
const fetch_deadline_ns: u64 = 30 * std.time.ns_per_s;

const FetchTask = struct {
    client: *std.http.Client,
    options: std.http.Client.FetchOptions,
    result: ?(std.http.Client.FetchError!std.http.Client.FetchResult) = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *FetchTask) void {
        self.result = self.client.fetch(self.options);
        self.done.store(true, .release);
    }
};

/// One attempt: a fresh client, on its own thread, bounded by `fetch_deadline_ns`.
/// A `null` return means the attempt never came back in time.
///
/// The client and its thread are then ABANDONED rather than torn down —
/// nothing here can force an OS thread blocked in a syscall to unwind, and
/// calling `client.deinit()` out from under a thread still using it would race
/// its connection pool. Everything the abandoned thread can still touch is
/// allocated from `arena` for exactly that reason: never reused, so there is
/// nothing for it to corrupt. `bench notify` is a short-lived one-shot
/// process, so the leak is bounded by the process's own remaining lifetime —
/// the same trade `ProxyWatchdog` makes with the whole process elsewhere in
/// this codebase.
fn attemptOnce(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    url: []const u8,
    ctype: []const u8,
    body: []const u8,
) !?std.http.Client.FetchResult {
    const client = try arena.create(std.http.Client);
    client.* = .{ .allocator = gpa, .io = io };

    // The response body is of no interest, but a `response_writer` is still
    // mandatory: without one std.http.Client segfaults in its own discard
    // path, and only in a ReleaseFast musl build.
    const discard_buf = try arena.alloc(u8, 1024);
    const discard = try arena.create(std.Io.Writer.Discarding);
    discard.* = .init(discard_buf);

    const task = try arena.create(FetchTask);
    task.* = .{
        .client = client,
        .options = .{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{.{ .name = "content-type", .value = ctype }},
            .response_writer = &discard.writer,
            // Ask the server to close after replying. This is what actually
            // makes a 204 safe: that reply has no body and no `content-length`,
            // and `std.http.Client` then waits for a body that never comes —
            // forever, if the connection stays open. `Connection: close` gives
            // the read an end. Verified against httpbingo.org/status/204, which
            // hangs without it and returns immediately with it.
            //
            // One request per attempt, so pooling buys nothing anyway.
            .keep_alive = false,
        },
    };

    const thread = try std.Thread.spawn(.{}, FetchTask.run, .{task});

    const step_ns: u64 = 100 * std.time.ns_per_ms;
    var waited: u64 = 0;
    while (!task.done.load(.acquire) and waited < fetch_deadline_ns) {
        io.sleep(.fromNanoseconds(step_ns), .awake) catch break;
        waited += step_ns;
    }
    if (!task.done.load(.acquire)) return null; // abandoned; see doc comment above

    thread.join();
    defer client.deinit(); // safe now: joined, so nothing else touches it
    return try task.result.?;
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

test "truncateTable leaves a short table untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const table = "```\nshort table\n```\n[full report](https://x/y)";
    try std.testing.expectEqualStrings(table, try truncateTable(arena_state.allocator(), table, "https://x/y"));
}

test "truncateTable always re-closes the fence and the link, never mid-cut" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "```\n");
    // Comfortably past limits.description so this MUST be cut.
    var i: usize = 0;
    while (i < 1000) : (i += 1) try buf.appendSlice(arena, "proxy row of table text\n");
    try buf.appendSlice(arena, "```\n[full report](https://example/report)");

    const out = try truncateTable(arena, buf.items, "https://example/report");
    try std.testing.expect(out.len <= limits.description);
    try std.testing.expect(std.mem.endsWith(u8, out, "```\n[full report](https://example/report)"));
    // Still valid UTF-8 — the whole input here is ASCII, but the cut logic
    // itself must never land on a continuation byte.
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "renderPayload rejects too many embeds rather than asserting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var embeds: [limits.embeds + 1]Embed = undefined;
    for (&embeds) |*e| e.* = .{ .title = "t", .ref_rate = 2000, .rows = &.{} };
    try std.testing.expectError(error.TooManyEmbeds, renderPayload(arena, "x", &embeds, &.{}));
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

test "a degraded row says WHY, not just that it is degraded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]Row{
        .{
            .name = "zoxy",
            .status = .degraded,
            .sustained = 43120,
            .note = "STALE BUILD — ran zoxy 03308bf, but main was 91d03b1 when this build ran",
        },
        .{ .name = "haproxy", .status = .ok, .sustained = 21000 },
    };
    const body = try renderTable(arena, .{ .title = "c1k", .ref_rate = 2000, .rows = &rows });

    // The marker AND the reason. A nightly reader sees this post before they
    // see the report, and a stale build decides whether zoxy's number above
    // means anything.
    try std.testing.expect(std.mem.indexOf(u8, body, "⚠") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "STALE BUILD") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "⚠ zoxy:") != null);

    // An ok row contributes no caveat line, even if one were ever attached.
    try std.testing.expect(std.mem.indexOf(u8, body, "⚠ haproxy:") == null);
}

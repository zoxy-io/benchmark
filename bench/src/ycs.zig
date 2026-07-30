//! Yandex Cloud access: Object Storage for artifacts, Compute for the orphan
//! sweep. Everything authenticates with `Authorization: Bearer <IAM token>`.
//!
//! That header is the reason this design has no long-lived secret. Yandex Object
//! Storage accepts IAM tokens directly — "if authenticating with the API via an
//! IAM token, you do not have to additionally sign HTTP requests" — so there is
//! no AWS SigV4 to implement and no static access key to store. On the CI runner
//! the token comes from GitHub OIDC federated to a service account; on a VM it
//! comes from the metadata service, so the VM holds no credential at all.
//!
//! Object Storage is the only way results leave the fleet, because the VMs have
//! no public address and nothing can reach in. GitHub was considered and
//! rejected: it has no write-only drop-box credential — Actions artifacts can
//! only be uploaded from inside a runner, and releases and branch pushes both
//! sit under the `contents` permission — so any GitHub upload path would mean
//! handing repo write access to a machine being deliberately saturated with
//! load.

const std = @import("std");
const Io = std.Io;

const Allocator = std.mem.Allocator;

pub const storage_host = "storage.yandexcloud.net";
pub const compute_host = "compute.api.cloud.yandex.net";

/// How long a single request gets before it is abandoned as failed.
///
/// Nothing in `std.http.Client.fetch` bounds a stalled connect or a response
/// that arrives a byte at a time forever. `bench wait` polls `exists` for the
/// DONE/FAILED markers every 30s over up to 110 minutes with no deadline of
/// its own other than counting elapsed time BETWEEN calls — so one hung
/// request used to freeze the whole poll loop silently until the workflow's
/// own step timeout. Nightly run #9 burned 71 minutes that way. Same shape as
/// `discord.zig`'s `attemptOnce`: run the call on its own thread, poll an
/// atomic flag, give up on the wall clock if it never flips.
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

/// Run one bounded request on a throwaway client and thread of its own.
/// A `null` return means it never came back within `fetch_deadline_ns`.
///
/// Each call gets its OWN `std.http.Client` — deliberately not `Client`'s own
/// long-lived one — because `bench wait` calls this every 30s for up to 110
/// minutes, and a request that times out is ABANDONED rather than torn down:
/// nothing here can force a thread blocked in a syscall to unwind, and calling
/// `deinit` out from under it would race its connection pool. A shared,
/// reused client would mean every LATER poll racing that same zombie thread;
/// a throwaway one confines the damage to itself and is simply never freed.
///
/// For the same reason, `options.response_writer`'s backing buffer must stay
/// valid forever if this returns null — see `newSink`'s doc comment for the
/// discard-buffer case, and `get`/`listInstances` for why their arena-backed
/// writers need no special handling at all.
fn fetchBounded(gpa: Allocator, io: Io, options: std.http.Client.FetchOptions) !?std.http.Client.FetchResult {
    const client = try gpa.create(std.http.Client);
    client.* = .{ .allocator = gpa, .io = io };

    const task = try gpa.create(FetchTask);
    task.* = .{ .client = client, .options = options };

    const thread = try std.Thread.spawn(.{}, FetchTask.run, .{task});

    const step_ns: u64 = 100 * std.time.ns_per_ms;
    var waited: u64 = 0;
    while (!task.done.load(.acquire) and waited < fetch_deadline_ns) {
        io.sleep(.fromNanoseconds(step_ns), .awake) catch break;
        waited += step_ns;
    }
    if (!task.done.load(.acquire)) return null; // abandoned; see doc comment above

    thread.join();
    const result = task.result.?;
    client.deinit();
    gpa.destroy(client);
    gpa.destroy(task);
    return try result;
}

/// A throwaway sink for a response body nobody reads (HEAD/PUT/DELETE all
/// discard theirs). Heap-allocated rather than a caller's stack buffer,
/// because it must stay valid if `fetchBounded` abandons the request on
/// timeout: `exists` in particular is called every 30s in a loop, and a stack
/// buffer would be reused by the NEXT call while an earlier abandoned thread
/// might still be writing through the OLD one — corrupting whichever call's
/// struct happens to land there, not merely wasting a few bytes. Freed by the
/// caller only when the request did NOT time out; see `freeSink`.
///
/// The response_writer itself is still mandatory even though the body is
/// discarded: without one, std.http.Client takes an internal discard path
/// that segfaults in `Reader.discardRemaining`. It does not reproduce in a
/// Debug build against glibc — only in the ReleaseFast static-musl binary CI
/// actually ships, which is how it reached a real run: the first `bench wait`
/// died two seconds in, on a HEAD, immediately after tofu had brought up the
/// whole fleet. `keep_alive = false` matters too: it is what keeps a reply
/// whose body has no discoverable end (a HEAD's `content-length` with no
/// body, or Discord's 204) from hanging forever waiting for bytes that will
/// never come — see discord.zig's identical note.
fn newSink(gpa: Allocator) !*std.Io.Writer.Discarding {
    const buf = try gpa.alloc(u8, 1024);
    const d = try gpa.create(std.Io.Writer.Discarding);
    d.* = .init(buf);
    return d;
}

fn freeSink(gpa: Allocator, d: *std.Io.Writer.Discarding) void {
    gpa.free(d.writer.buffer);
    gpa.destroy(d);
}

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    token: []const u8,

    pub fn init(gpa: Allocator, io: Io, token: []const u8) Client {
        return .{ .gpa = gpa, .io = io, .token = token };
    }

    /// No-op: every request now builds and tears down its own throwaway
    /// client (see `fetchBounded`), so there is no longer any persistent
    /// connection state for `Client` itself to hold. Kept so call sites that
    /// pair `init`/`defer deinit()` need no change.
    pub fn deinit(self: *Client) void {
        _ = self;
    }

    fn authHeader(self: *Client, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "Bearer {s}", .{self.token});
    }

    pub const PutOptions = struct {
        content_type: ?[]const u8 = null,
        /// Make this one object world-readable, so it can be linked from a
        /// Discord post. Applied per object rather than to the bucket: the run
        /// data stays private and only the rendered report is exposed.
        public: bool = false,
    };

    /// PUT an object with a content type and optional public-read ACL.
    ///
    /// The content type matters for a linked report — without `text/html` a
    /// browser downloads the file instead of rendering it, which defeats the
    /// point of linking rather than attaching.
    pub fn putObject(
        self: *Client,
        bucket: []const u8,
        key: []const u8,
        body: []const u8,
        opts: PutOptions,
    ) !void {
        const url = try std.fmt.allocPrint(
            self.gpa,
            "https://{s}/{s}/{s}",
            .{ storage_host, bucket, key },
        );
        defer self.gpa.free(url);

        var auth_buf: [4096]u8 = undefined;
        const auth = try self.authHeader(&auth_buf);

        var extra: std.ArrayList(std.http.Header) = .empty;
        defer extra.deinit(self.gpa);
        if (opts.content_type) |ct| {
            try extra.append(self.gpa, .{ .name = "content-type", .value = ct });
        }
        if (opts.public) {
            try extra.append(self.gpa, .{ .name = "x-amz-acl", .value = "public-read" });
        }

        const discard = try newSink(self.gpa);
        const res = try fetchBounded(self.gpa, self.io, .{
            .location = .{ .url = url },
            .method = .PUT,
            .payload = body,
            .headers = .{ .authorization = .{ .override = auth } },
            .extra_headers = extra.items,
            .response_writer = &discard.writer,
            .keep_alive = false,
        }) orelse {
            std.debug.print("bench: PUT {s} timed out after {d}s\n", .{ key, fetch_deadline_ns / std.time.ns_per_s });
            return error.RequestTimedOut;
        };
        freeSink(self.gpa, discard);
        if (res.status != .ok and res.status != .created) {
            std.debug.print("bench: PUT {s} returned {d}\n", .{ key, @intFromEnum(res.status) });
            return error.ObjectPutFailed;
        }
    }

    /// Public URL of an object. Only resolves for one uploaded with
    /// `public = true`.
    pub fn publicUrl(arena: Allocator, bucket: []const u8, key: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "https://{s}/{s}/{s}", .{ storage_host, bucket, key });
    }

    /// GET an object, or null if it does not exist yet. A 404 is an expected,
    /// non-exceptional answer while polling for a marker.
    pub fn get(self: *Client, arena: Allocator, bucket: []const u8, key: []const u8) !?[]u8 {
        const url = try std.fmt.allocPrint(
            self.gpa,
            "https://{s}/{s}/{s}",
            .{ storage_host, bucket, key },
        );
        defer self.gpa.free(url);

        var auth_buf: [4096]u8 = undefined;
        const auth = try self.authHeader(&auth_buf);

        // Arena-backed, unlike the discard sinks above: `wait`'s arena lives
        // for the whole poll loop and is never reset mid-loop, so an
        // abandoned thread writing into it on timeout has nothing to corrupt
        // — the memory is simply never reused before the process exits.
        var body: std.Io.Writer.Allocating = .init(arena);
        const res = try fetchBounded(self.gpa, self.io, .{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .authorization = .{ .override = auth } },
            .response_writer = &body.writer,
            .keep_alive = false,
        }) orelse {
            std.debug.print("bench: GET {s} timed out after {d}s\n", .{ key, fetch_deadline_ns / std.time.ns_per_s });
            return error.RequestTimedOut;
        };
        if (res.status == .not_found) return null;
        if (res.status != .ok) {
            std.debug.print("bench: GET {s} returned {d}\n", .{ key, @intFromEnum(res.status) });
            return error.ObjectGetFailed;
        }
        return body.written();
    }

    pub fn exists(self: *Client, bucket: []const u8, key: []const u8) !bool {
        const url = try std.fmt.allocPrint(
            self.gpa,
            "https://{s}/{s}/{s}",
            .{ storage_host, bucket, key },
        );
        defer self.gpa.free(url);

        var auth_buf: [4096]u8 = undefined;
        const auth = try self.authHeader(&auth_buf);

        const discard = try newSink(self.gpa);
        const res = try fetchBounded(self.gpa, self.io, .{
            .location = .{ .url = url },
            .method = .HEAD,
            .headers = .{ .authorization = .{ .override = auth } },
            .response_writer = &discard.writer,
            .keep_alive = false,
        }) orelse {
            // Not fatal: `wait`'s loop treats a failed `exists` as `false` and
            // polls again next tick, which is exactly right for one stalled
            // HEAD in a 110-minute loop — see `wait`'s own catch sites.
            std.debug.print("bench: HEAD {s} timed out after {d}s\n", .{ key, fetch_deadline_ns / std.time.ns_per_s });
            return error.RequestTimedOut;
        };
        freeSink(self.gpa, discard);
        return res.status == .ok;
    }

    /// Instances in `folder`, for the orphan sweep.
    pub fn listInstances(self: *Client, arena: Allocator, folder: []const u8) ![]Instance {
        const url = try std.fmt.allocPrint(
            self.gpa,
            "https://{s}/compute/v1/instances?folderId={s}&pageSize=1000",
            .{ compute_host, folder },
        );
        defer self.gpa.free(url);

        var auth_buf: [4096]u8 = undefined;
        const auth = try self.authHeader(&auth_buf);

        // Arena-backed; see the comment in `get` above.
        var body: std.Io.Writer.Allocating = .init(arena);
        const res = try fetchBounded(self.gpa, self.io, .{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .authorization = .{ .override = auth } },
            .response_writer = &body.writer,
            .keep_alive = false,
        }) orelse return error.RequestTimedOut;
        if (res.status != .ok) return error.ListInstancesFailed;

        return parseInstances(arena, body.written());
    }

    pub fn deleteInstance(self: *Client, id: []const u8) !void {
        const url = try std.fmt.allocPrint(
            self.gpa,
            "https://{s}/compute/v1/instances/{s}",
            .{ compute_host, id },
        );
        defer self.gpa.free(url);

        var auth_buf: [4096]u8 = undefined;
        const auth = try self.authHeader(&auth_buf);

        const discard = try newSink(self.gpa);
        const res = try fetchBounded(self.gpa, self.io, .{
            .location = .{ .url = url },
            .method = .DELETE,
            .headers = .{ .authorization = .{ .override = auth } },
            .response_writer = &discard.writer,
            .keep_alive = false,
        }) orelse return error.RequestTimedOut;
        freeSink(self.gpa, discard);
        if (res.status != .ok) return error.DeleteInstanceFailed;
    }
};

pub const Instance = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    /// `bench` label, if present. The sweep keys off this rather than off
    /// terraform state, which is per-run and dies with the runner.
    bench_label: ?[]const u8,
    runid_label: ?[]const u8,
};

pub fn parseInstances(arena: Allocator, json: []const u8) ![]Instance {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const obj = parsed.object;

    var out: std.ArrayList(Instance) = .empty;
    const arr = obj.get("instances") orelse return out.toOwnedSlice(arena);

    for (arr.array.items) |item| {
        const o = item.object;
        var bench_label: ?[]const u8 = null;
        var runid_label: ?[]const u8 = null;
        if (o.get("labels")) |l| {
            if (l == .object) {
                if (l.object.get("bench")) |v| bench_label = v.string;
                if (l.object.get("runid")) |v| runid_label = v.string;
            }
        }
        try out.append(arena, .{
            .id = if (o.get("id")) |v| v.string else "",
            .name = if (o.get("name")) |v| v.string else "",
            .status = if (o.get("status")) |v| v.string else "",
            .bench_label = bench_label,
            .runid_label = runid_label,
        });
    }
    return out.toOwnedSlice(arena);
}

test "parseInstances picks out the sweep labels" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"instances":[
        \\ {"id":"fhm1","name":"loadgen","status":"RUNNING",
        \\  "labels":{"bench":"nightly","runid":"20260728-000102"}},
        \\ {"id":"fhm2","name":"unrelated","status":"RUNNING"}
        \\]}
    ;
    const list = try parseInstances(arena, json);
    try std.testing.expectEqual(@as(usize, 2), list.len);

    try std.testing.expectEqualStrings("fhm1", list[0].id);
    try std.testing.expectEqualStrings("nightly", list[0].bench_label.?);
    try std.testing.expectEqualStrings("20260728-000102", list[0].runid_label.?);

    // An instance with no labels must not be swept — the folder may hold
    // machines that have nothing to do with the benchmark.
    try std.testing.expect(list[1].bench_label == null);
}

test "parseInstances tolerates an empty folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const list = try parseInstances(arena_state.allocator(), "{}");
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

/// Object keys for one run. Centralised so the workflow, cloud-init and the
/// runner cannot disagree about where something lives.
pub const Keys = struct {
    runid: []const u8,

    pub fn payload(self: Keys, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "runs/{s}/payload.tar", .{self.runid});
    }
    pub fn log(self: Keys, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "runs/{s}/log", .{self.runid});
    }
    pub fn results(self: Keys, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "runs/{s}/results.tar", .{self.runid});
    }
    pub fn done(self: Keys, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "runs/{s}/DONE", .{self.runid});
    }
    pub fn failed(self: Keys, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "runs/{s}/FAILED", .{self.runid});
    }
    pub fn bootOk(self: Keys, arena: Allocator, role: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "runs/{s}/boot-ok.{s}", .{ self.runid, role });
    }

    /// The rendered report, uploaded public-read so Discord can link it. Under
    /// the run prefix, so it ages out with the rest of the run rather than
    /// accumulating forever.
    pub fn report(self: Keys, arena: Allocator, prof: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "runs/{s}/{s}/report.html", .{ self.runid, prof });
    }
};

test "Keys namespaces every object under the run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const k: Keys = .{ .runid = "20260728-000102" };
    try std.testing.expectEqualStrings("runs/20260728-000102/payload.tar", try k.payload(arena));
    try std.testing.expectEqualStrings("runs/20260728-000102/DONE", try k.done(arena));
    try std.testing.expectEqualStrings("runs/20260728-000102/boot-ok.loadgen", try k.bootOk(arena, "loadgen"));
}

test "Keys.report is namespaced under the run, so it ages out with it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const k: Keys = .{ .runid = "20260729-000112" };
    try std.testing.expectEqualStrings(
        "runs/20260729-000112/c1k/report.html",
        try k.report(arena, "c1k"),
    );
    try std.testing.expectEqualStrings(
        "https://storage.yandexcloud.net/b/runs/x/c1k/report.html",
        try Client.publicUrl(arena, "b", "runs/x/c1k/report.html"),
    );
}

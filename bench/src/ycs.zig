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

pub const Client = struct {
    gpa: Allocator,
    token: []const u8,
    http: std.http.Client,

    pub fn init(gpa: Allocator, io: Io, token: []const u8) Client {
        return .{
            .gpa = gpa,
            .token = token,
            .http = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    fn authHeader(self: *Client, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "Bearer {s}", .{self.token});
    }

    /// Every `fetch` MUST be given a `response_writer` AND `keep_alive = false`,
    /// even when the body is of no interest.
    ///
    /// `keep_alive = false` is what keeps a reply whose body has no discoverable
    /// end from hanging the client forever. `exists` uses HEAD, which answers
    /// with a `content-length` and no body at all, and the client will sit
    /// waiting for bytes that are never sent unless the connection closes. The
    /// same defect showed up against Discord's 204 (see discord.zig) and is
    /// reproducible against httpbingo.org/status/204.
    ///
    /// This is not theoretical here: `bench wait` polls `exists` for the
    /// DONE/FAILED markers every 30s, so one hung HEAD freezes the whole poll
    /// loop — no marker check, no deadline, nothing until the workflow's own step
    /// timeout. Nightly run #9 burned 71 minutes that way, silently.
    ///
    /// Requests here are one-per-poll, so pooling was never worth anything.
    ///
    /// Without one, std.http.Client takes an internal discard path that
    /// segfaults in `Reader.discardRemaining`. It does not reproduce in a Debug
    /// build against glibc — only in the ReleaseFast static-musl binary CI
    /// actually ships, which is how it reached a real run: the first `bench
    /// wait` died two seconds in, on a HEAD, immediately after tofu had brought
    /// up the whole fleet.
    fn sink(buf: []u8) std.Io.Writer.Discarding {
        return .init(buf);
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

        var discard_buf: [1024]u8 = undefined;
        var discard = sink(&discard_buf);
        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .PUT,
            .payload = body,
            .headers = .{ .authorization = .{ .override = auth } },
            .extra_headers = extra.items,
            .response_writer = &discard.writer,
            .keep_alive = false,
        });
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

    /// PUT an object. `key` is the full path within the bucket.
    pub fn put(self: *Client, bucket: []const u8, key: []const u8, body: []const u8) !void {
        const url = try std.fmt.allocPrint(
            self.gpa,
            "https://{s}/{s}/{s}",
            .{ storage_host, bucket, key },
        );
        defer self.gpa.free(url);

        var auth_buf: [4096]u8 = undefined;
        const auth = try self.authHeader(&auth_buf);

        var discard_buf: [1024]u8 = undefined;
        var discard = sink(&discard_buf);
        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .PUT,
            .payload = body,
            .headers = .{ .authorization = .{ .override = auth } },
            .response_writer = &discard.writer,
            .keep_alive = false,
        });
        if (res.status != .ok and res.status != .created) {
            // The status alone — a storage error body can echo request content.
            std.debug.print("bench: PUT {s} returned {d}\n", .{ key, @intFromEnum(res.status) });
            return error.ObjectPutFailed;
        }
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

        var body: std.Io.Writer.Allocating = .init(arena);
        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .authorization = .{ .override = auth } },
            .response_writer = &body.writer,
            .keep_alive = false,
        });
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

        var discard_buf: [1024]u8 = undefined;
        var discard = sink(&discard_buf);
        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .HEAD,
            .headers = .{ .authorization = .{ .override = auth } },
            .response_writer = &discard.writer,
            .keep_alive = false,
        });
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

        var body: std.Io.Writer.Allocating = .init(arena);
        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .authorization = .{ .override = auth } },
            .response_writer = &body.writer,
            .keep_alive = false,
        });
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

        var discard_buf: [1024]u8 = undefined;
        var discard = sink(&discard_buf);
        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .DELETE,
            .headers = .{ .authorization = .{ .override = auth } },
            .response_writer = &discard.writer,
            .keep_alive = false,
        });
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

/// Fetch an IAM token from the VM metadata service.
///
/// Requires the instance to have a service account attached and the
/// `gce-http-token` metadata key set. This is what keeps a benchmark VM — a
/// machine deliberately saturated with load traffic — free of any stored
/// credential: the token is minted on demand, scoped to that service account,
/// and expires on its own.
pub fn metadataToken(gpa: Allocator, io: Io, arena: Allocator) ![]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(arena);
    const res = try client.fetch(.{
        .location = .{
            .url = "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token",
        },
        .method = .GET,
        .extra_headers = &.{.{ .name = "Metadata-Flavor", .value = "Google" }},
        .response_writer = &body.writer,
        .keep_alive = false,
    });
    if (res.status != .ok) return error.MetadataTokenFailed;

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body.written(), .{});
    const tok = parsed.object.get("access_token") orelse return error.MetadataTokenFailed;
    return tok.string;
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

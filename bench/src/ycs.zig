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

        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .PUT,
            .payload = body,
            .headers = .{ .authorization = .{ .override = auth } },
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

        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .HEAD,
            .headers = .{ .authorization = .{ .override = auth } },
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

        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .DELETE,
            .headers = .{ .authorization = .{ .override = auth } },
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

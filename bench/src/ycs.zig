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

const http = @import("http.zig");

const Allocator = std.mem.Allocator;

pub const storage_host = "storage.yandexcloud.net";
pub const compute_host = "compute.api.cloud.yandex.net";

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    token: []const u8,

    pub fn init(gpa: Allocator, io: Io, token: []const u8) Client {
        return .{ .gpa = gpa, .io = io, .token = token };
    }

    /// No-op: every request now builds and tears down its own throwaway
    /// client (see `http.fetch`), so there is no longer any persistent
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
    };

    /// PUT an object. Every object this bucket holds is private run data; there
    /// is deliberately no public-read path (the Discord post links the GitHub
    /// Pages copy of the report instead of a world-readable object here).
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

        const res = try http.fetch(self.gpa, self.io, .{
            .url = url,
            .method = .PUT,
            .payload = body,
            .authorization = auth,
            .content_type = opts.content_type,
            .what = key,
        }) orelse return error.RequestTimedOut;
        if (res.status != .ok and res.status != .created) {
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

        // The `Allocating` itself is arena-ALLOCATED, not a stack local whose
        // buffer happens to come from the arena. `http.fetch` hands this
        // pointer to a thread it may abandon, and a stack local would leave
        // that thread writing into `get`'s dead frame. `wait`'s arena lives
        // for the whole poll loop and is never reset mid-loop, so the memory
        // is simply never reused before the process exits.
        const body = try arena.create(std.Io.Writer.Allocating);
        body.* = .init(arena);
        const res = try http.fetch(self.gpa, self.io, .{
            .url = url,
            .authorization = auth,
            .sink = .{ .collect = body },
            .what = key,
        }) orelse return error.RequestTimedOut;
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

        // A timeout here is not fatal: `wait`'s loop treats a failed `exists`
        // as `false` and polls again next tick, which is exactly right for one
        // stalled HEAD in a 110-minute loop — see `wait`'s own catch sites.
        const res = try http.fetch(self.gpa, self.io, .{
            .url = url,
            .method = .HEAD,
            .authorization = auth,
            .what = key,
        }) orelse return error.RequestTimedOut;
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

        // Arena-ALLOCATED, not a stack local; see the comment in `get` above.
        const body = try arena.create(std.Io.Writer.Allocating);
        body.* = .init(arena);
        const res = try http.fetch(self.gpa, self.io, .{
            .url = url,
            .authorization = auth,
            .sink = .{ .collect = body },
            .what = "list instances",
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

        const res = try http.fetch(self.gpa, self.io, .{
            .url = url,
            .method = .DELETE,
            .authorization = auth,
            .what = "delete instance",
        }) orelse return error.RequestTimedOut;
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

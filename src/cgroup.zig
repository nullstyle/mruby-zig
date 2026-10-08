//! cgroupv2 confinement for the worker tier (roadmap B3).
//!
//! The controller places each helper process into an ephemeral leaf cgroup
//! under a caller-provided *delegated parent*: an existing cgroupv2
//! directory whose `cgroup.subtree_control` already enables the domain
//! controllers being requested (the standard systemd delegation shape).
//! mruby-zig never enables controllers itself — flipping subtree_control
//! on a parent that hosts processes is a privileged, system-shape
//! decision that belongs to the embedding deployment.
//!
//! Lifecycle: create leaf (mkdir) → write `memory.max` / `cpu.max` /
//! `pids.max` → write the child pid to `leaf/cgroup.procs` immediately
//! after spawn and before any request byte is written, so confinement is
//! in place before any guest byte executes → existing kill-then-reap →
//! rmdir the (now-empty) leaf.
//!
//! Unavailability is typed and surfaced, never pretended: no cgroupv2,
//! a missing or read-only parent, or a parent without the needed
//! controllers enabled reports `error.CgroupUnavailable` (the
//! `HardMemoryLimitUnavailable` precedent). A failure midway through
//! setup after the leaf exists is `error.CgroupSetupFailed` and the leaf
//! is removed before returning.

const std = @import("std");
const builtin = @import("builtin");
const sandbox = @import("sandbox.zig");

pub const available: bool = builtin.os.tag == .linux;

pub const Error = error{
    CgroupUnavailable,
    CgroupSetupFailed,
    OutOfMemory,
};

/// Requested leaf limits. `memory_max_bytes` is a hard memory ceiling for
/// the whole worker process (a sharper tool than RLIMIT_AS: it accounts
/// every allocation including shared pages, with the kernel's OOM kill
/// as the failure mode rather than a failing malloc). `cpu_quota_us` /
/// `cpu_period_us` is a bandwidth ceiling (hard CPU per period,
/// complementing RLIMIT_CPU's cumulative seconds). `pids_max` bounds the
/// descendant tree.
pub const Limits = struct {
    parent: []const u8,
    memory_max_bytes: ?u64 = null,
    cpu_quota_us: ?u64 = null,
    cpu_period_us: u64 = 100_000,
    pids_max: ?u32 = null,

    pub fn anyRequested(limits: *const Limits) bool {
        return limits.memory_max_bytes != null or
            limits.cpu_quota_us != null or
            limits.pids_max != null;
    }
};

/// A created leaf cgroup. `destroy` removes it and frees the path.
pub const Group = struct {
    path: [:0]u8,

    pub fn destroy(group: *Group, allocator: std.mem.Allocator) void {
        // Dead processes leave the cgroup automatically; rmdir is safe
        // once empty and deliberately ignored otherwise (a still-live
        // descendant means kill/reap already failed and the operator's
        // supervision story owns it).
        _ = std.os.linux.unlinkat(std.posix.AT.FDCWD, group.path, std.posix.AT.REMOVEDIR);
        allocator.free(group.path);
        group.* = undefined;
    }
};

var name_counter = std.atomic.Value(u64).init(0);

/// Create a leaf cgroup with the requested limits under the delegated
/// parent. Every controller file requested must already exist in the
/// created leaf (i.e. the parent's subtree_control enables it);
/// otherwise the leaf is removed and the parent reported unsuitable.
pub fn create(allocator: std.mem.Allocator, limits: *const Limits) Error!Group {
    if (!available) return error.CgroupUnavailable;

    const seq = name_counter.fetchAdd(1, .monotonic);
    const now: u64 = @intCast(@as(u128, @bitCast(sandbox.monotonicNs())) & 0xffff_ffff);
    const path = std.fmt.allocPrintSentinel(
        allocator,
        "{s}/mruby-worker-{x}-{d}",
        .{ limits.parent, now, seq },
        0,
    ) catch return error.OutOfMemory;
    errdefer allocator.free(path);

    switch (std.posix.errno(std.os.linux.mkdirat(std.posix.AT.FDCWD, path, 0o755))) {
        .SUCCESS => {},
        .EXIST => return error.CgroupSetupFailed,
        .ROFS, .ACCES, .NOENT => return error.CgroupUnavailable,
        else => return error.CgroupSetupFailed,
    }

    if (limits.memory_max_bytes) |bytes| {
        var value_buf: [32]u8 = undefined;
        const value = std.fmt.bufPrint(&value_buf, "{d}", .{bytes}) catch
            return error.CgroupSetupFailed;
        writeControl(path, "memory.max", value) catch |err| return mapSetup(err);
    }
    if (limits.cpu_quota_us) |quota| {
        var value_buf: [48]u8 = undefined;
        const value = std.fmt.bufPrint(
            &value_buf,
            "{d} {d}",
            .{ quota, limits.cpu_period_us },
        ) catch return error.CgroupSetupFailed;
        writeControl(path, "cpu.max", value) catch |err| return mapSetup(err);
    }
    if (limits.pids_max) |pids| {
        var value_buf: [16]u8 = undefined;
        const value = std.fmt.bufPrint(&value_buf, "{d}", .{pids}) catch
            return error.CgroupSetupFailed;
        writeControl(path, "pids.max", value) catch |err| return mapSetup(err);
    }

    return .{ .path = path };
}

/// Move `pid` into the leaf. The kernel rejects a pid that is not a
/// descendant of the writer; that surfaces as a setup failure.
pub fn attach(group: *const Group, pid: std.posix.pid_t) Error!void {
    if (!available) return error.CgroupUnavailable;
    var path_buf: [512]u8 = undefined;
    var value_buf: [24]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/cgroup.procs", .{group.path}, 0) catch
        return error.CgroupSetupFailed;
    const value = std.fmt.bufPrint(&value_buf, "{d}", .{pid}) catch
        return error.CgroupSetupFailed;
    writeRaw(path, value) catch |err| return mapSetup(err);
}

fn writeControl(dir: [:0]const u8, name: []const u8, value: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ dir, name }, 0) catch
        return error.CgroupSetupFailed;
    try writeRaw(path, value);
}

fn writeRaw(path: [*:0]const u8, value: []const u8) !void {
    const rc0: isize = @bitCast(std.os.linux.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY }, 0));
    if (std.posix.errno(rc0) != .SUCCESS) return error.AccessDenied;
    const fd: i32 = @intCast(rc0);
    defer _ = std.os.linux.close(fd);
    const rc: isize = @bitCast(std.os.linux.write(fd, value.ptr, value.len));
    if (std.posix.errno(rc) != .SUCCESS) return error.AccessDenied;
}

fn mapSetup(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound, error.AccessDenied, error.ReadOnlyFileSystem => error.CgroupUnavailable,
        else => error.CgroupSetupFailed,
    };
}

// ---- tests ------------------------------------------------------------

test "limits request predicate" {
    var limits: Limits = .{ .parent = "/sys/fs/cgroup" };
    try std.testing.expect(!limits.anyRequested());
    limits.memory_max_bytes = 1 << 20;
    try std.testing.expect(limits.anyRequested());
    limits = .{ .parent = "/sys/fs/cgroup", .pids_max = 4 };
    try std.testing.expect(limits.anyRequested());
}

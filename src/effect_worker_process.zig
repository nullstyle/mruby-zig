//! Synchronous, bounded private-socket transport for the effect worker.
//! Child confinement happens before guest input or VM construction. The host
//! adapter remains trusted and synchronous: deadlines are checked when its
//! callback returns, not by preempting arbitrary host-native code.
const std = @import("std");
const builtin = @import("builtin");

pub const supported = (builtin.os.tag == .linux and (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64)) or builtin.os.tag == .macos;
pub const protocol_fd: c_int = 3;
pub const Error = error{
    UnsupportedPlatform,
    InvalidProcessLimits,
    ProcessWallExceeded,
    TransportLimitExceeded,
    TransportFailure,
    UnexpectedWorkerOutput,
    ChildReapingUnavailable,
    SpawnFailed,
    WorkerFailed,
    ConfinementUnavailable,
};

pub const Channel = extern struct {
    fd: c_int,
    started_ns: u64,
    deadline_ns: u64,
    remaining_bytes: u64,
    transferred_bytes: u64,

    pub fn child(wall_time_ns: u64, max_transfer_bytes: u64) Error!Channel {
        if (comptime !supported) return error.UnsupportedPlatform;
        var result: Channel = undefined;
        try check(mrz_effect_channel_init(protocol_fd, wall_time_ns, max_transfer_bytes, &result));
        return result;
    }
    /// Tighten startup bounds after reading the fixed header. Startup elapsed
    /// time and bytes already consumed continue to count against both limits.
    pub fn configure(self: *Channel, wall_time_ns: u64, max_transfer_bytes: u64) Error!void {
        try check(mrz_effect_channel_configure(self, wall_time_ns, max_transfer_bytes));
    }
    pub fn readExact(self: *Channel, out: []u8) Error!void {
        try check(mrz_effect_channel_read(self, out.ptr, out.len));
    }
    pub fn writeAll(self: *Channel, bytes: []const u8) Error!void {
        try check(mrz_effect_channel_write(self, bytes.ptr, bytes.len));
    }
    pub fn expectEof(self: *Channel) Error!void {
        try check(mrz_effect_channel_eof(self));
    }
    pub fn remainingWall(self: *const Channel) Error!u64 {
        const current = try nowNs();
        if (current >= self.deadline_ns) return error.ProcessWallExceeded;
        return self.deadline_ns - current;
    }
};

pub const Limits = struct {
    wall_time_ns: u64,
    max_transfer_bytes: u64,
    /// Optional earlier monotonic deadline shared by record and verification.
    deadline_ns: ?u64 = null,
};

/// Owns one child and its private socket. Exclude competing child reapers and
/// SIGCHLD-disposition changes until wait/deinit. Successful wait requires EOF
/// with no trailing bytes and a zero exit; deinit kills and reaps on failure.
pub const Process = extern struct {
    channel: Channel,
    /// Host diagnostics/tests only; it must not become a replay input.
    pid: c_int,
    wait_status: c_int,

    pub fn spawn(allocator: std.mem.Allocator, path: []const u8, limits: Limits) (Error || std.mem.Allocator.Error)!Process {
        if (comptime !supported) return error.UnsupportedPlatform;
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null or
            (!std.fs.path.isAbsolute(path) and std.mem.indexOfScalar(u8, path, '/') == null) or
            limits.wall_time_ns == 0 or limits.max_transfer_bytes == 0) return error.InvalidProcessLimits;
        const now = try currentTime();
        if (limits.deadline_ns) |deadline| if (deadline <= now) return error.ProcessWallExceeded;
        const terminated = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(terminated);
        var result: Process = undefined;
        const rc = mrz_effect_process_spawn(terminated, limits.wall_time_ns, limits.max_transfer_bytes, &result);
        if (rc != 0) {
            check(rc) catch |err| return if (err == error.TransportFailure) error.SpawnFailed else err;
        }
        if (limits.deadline_ns) |deadline| result.channel.deadline_ns = @min(result.channel.deadline_ns, deadline);
        return result;
    }
    pub fn wait(self: *Process) Error!void {
        const rc = mrz_effect_process_wait(self);
        if (rc == @backingInt(std.posix.E.IO)) return error.WorkerFailed;
        try check(rc);
    }
    pub fn terminate(self: *Process) Error!void {
        try check(mrz_effect_process_destroy(self));
    }
    pub fn deinit(self: *Process) void {
        _ = mrz_effect_process_destroy(self);
    }
    pub fn remainingWall(self: *const Process) Error!u64 {
        return self.channel.remainingWall();
    }
    pub const nowNs = currentTime;
};

pub const nowNs = currentTime;
fn currentTime() Error!u64 {
    if (comptime !supported) return error.UnsupportedPlatform;
    var result: u64 = undefined;
    try check(mrz_effect_now_ns(&result));
    return result;
}

/// Linux: fd3-only stream IO and an allowlist for anonymous memory, signals,
/// clocks, process-self/runtime operations; filesystem/network/process
/// syscalls are denied. Linux >=5.9 is required for pre-exec fd closure.
/// macOS: deny-default Seatbelt; file access, network connect/bind, process
/// creation/exec and Mach lookup denied. Unconnected socket creation itself
/// remains possible. Seatbelt is deprecated and admission fails closed.
pub fn confine(cpu_seconds: u32, address_space_bytes: u64) Error!void {
    if (comptime !supported) return error.UnsupportedPlatform;
    const rc = mrz_effect_worker_confine(cpu_seconds, address_space_bytes);
    if (rc == @backingInt(std.posix.E.INVAL)) return error.InvalidProcessLimits;
    if (rc != 0) return error.ConfinementUnavailable;
}

fn check(rc: c_int) Error!void {
    if (rc == 0) return;
    return switch (@as(std.posix.E, @fromBackingInt(@intCast(rc)))) {
        .INVAL => error.InvalidProcessLimits,
        .TIMEDOUT => error.ProcessWallExceeded,
        .MSGSIZE => error.TransportLimitExceeded,
        .PROTO => error.UnexpectedWorkerOutput,
        .CHILD => error.ChildReapingUnavailable,
        .OPNOTSUPP => error.UnsupportedPlatform,
        else => error.TransportFailure,
    };
}

extern fn mrz_effect_now_ns(out: *u64) c_int;
extern fn mrz_effect_channel_init(fd: c_int, wall_ns: u64, max_bytes: u64, out: *Channel) c_int;
extern fn mrz_effect_channel_configure(*Channel, u64, u64) c_int;
extern fn mrz_effect_channel_read(*Channel, [*]u8, usize) c_int;
extern fn mrz_effect_channel_write(*Channel, [*]const u8, usize) c_int;
extern fn mrz_effect_channel_eof(*Channel) c_int;
extern fn mrz_effect_process_spawn([*:0]const u8, u64, u64, *Process) c_int;
extern fn mrz_effect_process_wait(*Process) c_int;
extern fn mrz_effect_process_destroy(*Process) c_int;
extern fn mrz_effect_worker_confine(u32, u64) c_int;

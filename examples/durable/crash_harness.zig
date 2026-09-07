const std = @import("std");

const NativeProcess = extern struct { pid: c_int = 0, fd: c_int = -1 };
pub const Process = struct {
    native: NativeProcess,

    /// Returns only when the real host is blocked at the selected checkpoint.
    /// `worker` and `worker_second` are the per-application worker executables.
    pub fn start(allocator: std.mem.Allocator, executable: []const u8, database: []const u8, worker: []const u8, worker_second: []const u8, phase: []const u8, ordinal: u32, recipient: []const u8) !Process {
        var strings: [6][:0]u8 = undefined;
        var count: usize = 0;
        defer for (strings[0..count]) |string| allocator.free(string);
        for ([_][]const u8{ executable, database, worker, worker_second, phase, recipient }) |string| {
            strings[count] = try allocator.dupeSentinel(u8, string, 0);
            count += 1;
        }
        var self: Process = .{ .native = .{} };
        try check(mrz_durable_test_spawn(strings[0], strings[1], strings[2], strings[3], strings[4], ordinal, strings[5], &self.native));
        errdefer self.deinit();
        try check(mrz_durable_test_ready(&self.native));
        return self;
    }
    pub fn kill(self: *Process) !void {
        try check(mrz_durable_test_kill(&self.native));
    }
    pub fn proceed(self: *Process) !void {
        try check(mrz_durable_test_resume(&self.native));
    }
    pub fn deinit(self: *Process) void {
        _ = mrz_durable_test_kill(&self.native);
    }
};

pub fn checkpoint() void {
    if (mrz_durable_test_checkpoint() != 0) std.c._exit(124);
}

fn check(result: c_int) !void {
    if (result == 0) return;
    std.debug.print("durable crash supervisor failed: errno {d}\n", .{result});
    return error.CrashSupervisorFailed;
}

extern fn mrz_durable_test_spawn([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, c_uint, [*:0]const u8, *NativeProcess) c_int;
extern fn mrz_durable_test_ready(*NativeProcess) c_int;
extern fn mrz_durable_test_kill(*NativeProcess) c_int;
extern fn mrz_durable_test_resume(*NativeProcess) c_int;
extern fn mrz_durable_test_checkpoint() c_int;

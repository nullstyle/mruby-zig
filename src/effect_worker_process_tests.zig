const std = @import("std");
const native = @import("effect_worker_process.zig");
const c = std.c;

fn pair() ![2]c_int {
    var result: [2]c_int = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &result) != 0) return error.SocketPairFailed;
    return result;
}

fn channel(fd: c_int, bytes: u64) !native.Channel {
    const now = try native.nowNs();
    return .{ .fd = fd, .started_ns = now, .deadline_ns = now + std.time.ns_per_s, .remaining_bytes = bytes, .transferred_bytes = 0 };
}

test "channel reserves byte budget before consuming input and configure includes prior transfer" {
    if (comptime !native.supported) return error.SkipZigTest;
    const sockets = try pair();
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    var stream = try channel(sockets[0], 3);
    try std.testing.expectEqual(@as(isize, 4), c.write(sockets[1], "abcd", 4));
    var bytes: [4]u8 = undefined;
    try std.testing.expectError(error.TransportLimitExceeded, stream.readExact(&bytes));
    try stream.readExact(bytes[0..2]);
    try std.testing.expectEqualStrings("ab", bytes[0..2]);
    try std.testing.expectEqual(@as(u64, 2), stream.transferred_bytes);
    try std.testing.expectError(error.InvalidProcessLimits, stream.configure(std.time.ns_per_s, 4));
    try std.testing.expectError(error.InvalidProcessLimits, stream.configure(std.time.ns_per_s, 1));
    try stream.configure(std.time.ns_per_s, 2);
    try std.testing.expectError(error.TransportLimitExceeded, stream.readExact(bytes[0..1]));
}

test "ready socket bytes do not override an expired channel deadline" {
    if (comptime !native.supported) return error.SkipZigTest;
    const sockets = try pair();
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    var stream = try channel(sockets[0], 1);
    try std.testing.expectEqual(@as(isize, 1), c.write(sockets[1], "x", 1));
    stream.deadline_ns = stream.started_ns;
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.ProcessWallExceeded, stream.readExact(&byte));
    try std.testing.expectEqual(@as(u64, 0), stream.transferred_bytes);
}

test "EOF admission rejects trailing output" {
    if (comptime !native.supported) return error.SkipZigTest;
    const sockets = try pair();
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    var stream = try channel(sockets[0], 1);
    try std.testing.expectEqual(@as(isize, 1), c.write(sockets[1], "x", 1));
    try std.testing.expectError(error.UnexpectedWorkerOutput, stream.expectEof());
}

fn exitedChild() !native.Process {
    const sockets = try pair();
    errdefer _ = c.close(sockets[0]);
    errdefer _ = c.close(sockets[1]);
    const stream = try channel(sockets[0], 1);
    const child = c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        if (c.setpgid(0, 0) != 0) c._exit(126);
        _ = c.close(sockets[0]);
        _ = c.close(sockets[1]);
        c._exit(0);
    }
    _ = c.close(sockets[1]);
    return .{ .channel = stream, .pid = child, .wait_status = 0 };
}

test "clean child exit is reaped and ownership clears" {
    if (comptime !native.supported) return error.SkipZigTest;
    var child = try exitedChild();
    defer child.deinit();
    try child.wait();
    try std.testing.expectEqual(@as(c_int, 0), child.pid);
    try std.testing.expectEqual(@as(c_int, -1), child.channel.fd);
}

test "expired wait rejects a zero exit and retains ownership for cleanup" {
    if (comptime !native.supported) return error.SkipZigTest;
    var child = try exitedChild();
    defer child.deinit();
    child.channel.deadline_ns = child.channel.started_ns;
    try std.testing.expectError(error.ProcessWallExceeded, child.wait());
    try std.testing.expect(child.pid > 0);
    try child.terminate();
    try std.testing.expectEqual(@as(c_int, 0), child.pid);
    try std.testing.expectEqual(@as(c_int, -1), child.channel.fd);
}

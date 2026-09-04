//! Exact-lifetime checks for the real worker after its controller is killed.
const std = @import("std");
const mruby = @import("mruby");
const protocol = @import("worker_protocol");
const manifest = @import("codedb_orphan_manifest");
const config = @import("worker_orphan_config");

extern fn mrz_test_orphan_case(
    executable: [*:0]const u8,
    phase: c_int,
    request: [*]const u8,
    request_len: usize,
) c_int;

fn check(phase: c_int, image_name: []const u8) !void {
    const image = mruby.codedb.find(manifest, image_name).?.bytes;
    const header = try protocol.encodeRequest(.{
        .image_len = image.len,
        // This field is parent-side supervision metadata, not a worker wall
        // timer. Only the CPU ceiling remains after this controller dies.
        .process = .{ .wall_time_ns = 100 * std.time.ns_per_ms, .cpu_seconds = 2 },
    });
    const request = try std.testing.allocator.alloc(u8, header.len + if (phase == 1) @as(usize, 0) else image.len);
    defer std.testing.allocator.free(request);
    @memcpy(request[0..header.len], &header);
    if (phase != 1) @memcpy(request[header.len..], image);
    const executable = try std.testing.allocator.dupeSentinel(u8, config.fixture_executable, 0);
    defer std.testing.allocator.free(executable);
    const result = mrz_test_orphan_case(executable, phase, request.ptr, request.len);
    if (result != 0) std.debug.print("orphan worker phase {d}: fixture failure {d}\n", .{ phase, result });
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "worker orphan: incomplete body reaches EOF after controller death" {
    try check(1, "response");
}

test "worker orphan: CPU-bound artifact exits under its inherited CPU ceiling" {
    try check(2, "loop");
}

test "worker orphan: response delivery exits after its only reader dies" {
    try check(3, "response");
}

test "worker orphan: rejected setup cleans up before another worker succeeds" {
    // The real worker rejects this header before emitting any readiness
    // marker. The independent supervisor must still kill/reap its controller
    // and watchdog, and account for the exact worker's completed lifetime.
    const invalid: [protocol.request_header_len]u8 = @splat(0);
    const executable = try std.testing.allocator.dupeSentinel(u8, config.fixture_executable, 0);
    defer std.testing.allocator.free(executable);
    try std.testing.expectEqual(@as(c_int, 7), mrz_test_orphan_case(executable, 1, &invalid, invalid.len));
    try check(3, "response");
}

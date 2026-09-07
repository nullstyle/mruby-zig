//! Full-width integer bugs fixed in every strict profile, including Float builds.
const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("strict_manifest");
const min = std.math.minInt(i64);
const max = std.math.maxInt(i64);

test "strict integer sorting compares full-width boxed values" {
    if (comptime mruby.features.integer_bits != 64) return error.SkipZigTest;
    const program = try mruby.strict.Program.load(manifest, "integer_boundaries", .{}, .{ .effects = .{ .mode = .record } });
    defer program.deinit();
    const result = try (try program.call("IntegerBoundaries", "sort_extremes", .{ min, max }, @splat(0))).asArray();
    try std.testing.expectEqual(@as(usize, 6), result.len());
    for ([_]i64{ min, -1, 0, 1, max, max }, 0..) |value, index| try std.testing.expectEqual(value, try (try result.get(index)).asInt());
}

test "strict integer binary formatting has room for minimum sign magnitude and terminator" {
    if (comptime mruby.features.integer_bits != 64) return error.SkipZigTest;
    const program = try mruby.strict.Program.load(manifest, "integer_boundaries", .{}, .{ .effects = .{ .mode = .record } });
    defer program.deinit();
    const result = try program.call("IntegerBoundaries", "binary_minimum", .{min}, @splat(0));
    try std.testing.expectEqualStrings("-1000000000000000000000000000000000000000000000000000000000000000", try result.asString());
}

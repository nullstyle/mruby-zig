//! Deliberately schema-free: numeric admission must not depend on contracts.
pub const operations = .{
    .{ .name = "stage.write", .namespace = "Stage", .method = "write", .version = @as(u32, 1), .arity = @as(usize, 1), .authority_bits = @as(u16, 1 << 13), .max_result_bytes = @as(usize, 256) },
    .{ .name = "source.read", .namespace = "Source", .method = "read", .version = @as(u32, 1), .arity = @as(usize, 0), .authority_bits = @as(u16, 1 << 13), .max_result_bytes = @as(usize, 4096) },
};
pub const grants: []const []const u8 = &.{ "stage.write", "source.read" };

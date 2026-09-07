//! Shared descriptor metadata for the strict turn example and its CodeDB bundle.
pub const operations = .{
    .{ .name = "clock.now", .namespace = "Clock", .method = "now", .version = @as(u32, 1), .arity = @as(usize, 0), .authority_bits = @as(u16, 1 << 4), .max_result_bytes = @as(usize, 256) },
    .{ .name = "intent.prepare", .namespace = "Intent", .method = "prepare", .version = @as(u32, 1), .arity = @as(usize, 1), .authority_bits = @as(u16, 1 << 13), .max_result_bytes = @as(usize, 1024) },
    .{ .name = "output.write", .namespace = "Output", .method = "write", .version = @as(u32, 1), .arity = @as(usize, 1), .authority_bits = @as(u16, 1 << 13), .max_result_bytes = @as(usize, 256) },
};
pub const grants: []const []const u8 = &.{ "clock.now", "intent.prepare", "output.write" };
pub const bootstrap_contract = "strict-turn-counter/v1;logical-clock=1700000000;counter-limit=100;queued-output;in-memory-intents;explicit-host-commit";
pub const max_bytes: usize = 64 * 1024;

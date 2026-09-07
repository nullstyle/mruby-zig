//! Shared operation descriptors embedded in the worker and the host broker.
pub const turn_contract = .{
    .state = .{ .object = .{.{ .name = "count", .schema = .integer }} },
    .input = .{ .object = .{
        .{ .name = "delta", .schema = .integer },
        .{ .name = "mode", .schema = .{ .string = .{ .max_bytes = 64 } } },
    } },
    .result = .integer,
};

pub const operations = .{
    .{
        .name = "clock.now",
        .namespace = "Clock",
        .method = "now",
        .version = @as(u32, 1),
        .arity = @as(usize, 0),
        .authority_bits = @as(u16, 1 << 4),
        .max_result_bytes = @as(usize, 256),
        .contract = .{ .arguments = .{ .tuple = .{} }, .result = .integer },
    },
    .{
        .name = "outbox.prepare",
        .namespace = "Outbox",
        .method = "prepare",
        .version = @as(u32, 1),
        .arity = @as(usize, 1),
        .authority_bits = @as(u16, 1 << 13),
        .max_result_bytes = @as(usize, 256),
        .contract = .{ .arguments = .{ .tuple = .{.{ .tuple = .{ .integer, .integer } }} }, .result = .nil },
    },
};
pub const grants: []const []const u8 = &.{ "clock.now", "outbox.prepare" };
pub const max_bytes: usize = 64 * 1024;
pub const bootstrap_contract = "strict-worker-counter/v1;clock=1700000000;host-owned-memory-outbox;explicit-commit";

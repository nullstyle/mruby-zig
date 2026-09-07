//! Pure domain contracts shared by CodeDB, the confined worker and durable host.
pub const sku = .{ .string = .{ .min_bytes = 1, .max_bytes = 64 } };
pub const quantity = .{ .integer = .{ .min = 1, .max = 1000 } };
pub const identity = .{ .string = .{ .min_bytes = 64, .max_bytes = 64 } };
pub const max_attempts = 0x7fff_ffff_ffff_ffff;
pub const reservation = .{ .object = .{
    .{ .name = "id", .schema = identity },
    .{ .name = "sku", .schema = sku },
    .{ .name = "quantity", .schema = quantity },
    .{ .name = "remaining", .schema = .{ .integer = .{ .min = 0 } } },
} };
pub const operations = .{
    .{ .name = "stock.reserve", .namespace = "Stock", .method = "reserve", .version = @as(u32, 1), .arity = @as(usize, 2), .authority_bits = @as(u16, 1 << 12), .max_result_bytes = @as(usize, 2048), .contract = .{
        .arguments = .{ .tuple = .{ sku, quantity } },
        .result = reservation,
        .rejection = .{ .codes = .{"OutOfStock"}, .max_message_bytes = 512 },
    } },
    .{ .name = "notifications.reservation_created", .namespace = "Notifications", .method = "reservation_created", .version = @as(u32, 1), .arity = @as(usize, 1), .authority_bits = @as(u16, 1 << 13), .max_result_bytes = @as(usize, 256), .contract = .{
        .arguments = .{ .tuple = .{reservation} },
        .result = identity,
    } },
};
fn TurnContract(comptime maximum_attempts: i64) type {
    return struct {
        pub const value = .{
            .state = .{ .object = .{.{ .name = "attempts", .schema = .{ .integer = .{ .min = 0, .max = maximum_attempts } } }} },
            .input = .{ .object = .{
                .{ .name = "sku", .schema = sku },
                .{ .name = "quantity", .schema = quantity },
                .{ .name = "fail", .schema = .boolean },
                .{ .name = "mode", .schema = .{ .string = .{ .max_bytes = 64 } }, .optional = true },
            } },
            .result = .{ .object = .{
                .{ .name = "status", .schema = .{ .enum_string = .{ "reserved", "rejected" } } },
                .{ .name = "reservation", .schema = reservation, .optional = true },
                .{ .name = "intent", .schema = identity, .optional = true },
                .{ .name = "code", .schema = .{ .enum_string = .{"OutOfStock"} }, .optional = true },
            } },
        };
    };
}
pub const turn_contract = TurnContract(max_attempts).value;
// Test fixture changes only this shape, keeping code, operations and bootstrap.
pub const turn_contract_v2 = TurnContract(1_000_000).value;
pub const grants: []const []const u8 = &.{ "stock.reserve", "notifications.reservation_created" };
pub const max_bytes = 64 * 1024;
pub const max_receipt_bytes = 256 * 1024;
pub const max_snapshot_rows = 4096;
pub const bootstrap_contract = "durable-inventory/v2;sqlite-3.51.3-threadsafe;typed-reservation-v1;WAL-FULL;atomic-state-receipt-outbox;turn-id-and-revision;reservation-and-intent-sha256-v2";

/// Trusted host instrumentation; guest Ruby cannot invoke these checkpoints.
pub const Phase = enum {
    after_admission,
    after_begin,
    after_stock_update,
    after_reservation_insert,
    after_effect,
    after_prepare,
    before_commit,
    after_commit,
    before_upgrade_commit,
    after_upgrade_commit,
    before_delivery,
    after_recipient_commit,
    after_delivery_ack,
};
pub const Checkpoint = struct {
    context: ?*anyopaque = null,
    hit: ?*const fn (?*anyopaque, Phase) void = null,

    pub fn reach(self: Checkpoint, phase: Phase) void {
        if (self.hit) |callback| callback(self.context, phase);
    }
};

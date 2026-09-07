//! The same plain schemas are compiled into the application worker and broker.
fn Catalogue(comptime maximum_quantity: i64) type {
    return struct {
        const sku = .{ .string = .{ .min_bytes = 1, .max_bytes = 64 } };
        const quantity = .{ .integer = .{ .min = 1, .max = maximum_quantity } };
        const reservation = .{ .object = .{
            .{ .name = "id", .schema = .{ .integer = .{ .min = 1, .max = 1_000_000 } } },
            .{ .name = "sku", .schema = sku },
            .{ .name = "quantity", .schema = quantity },
        } };
        pub const operations = .{
            .{ .name = "stock.reserve", .namespace = "Stock", .method = "reserve", .version = @as(u32, 1), .arity = @as(usize, 2), .authority_bits = @as(u16, 1 << 13), .max_result_bytes = @as(usize, 4096), .contract = .{
                .arguments = .{ .tuple = .{ sku, quantity } },
                .result = reservation,
                .rejection = .{ .codes = .{"OutOfStock"}, .max_message_bytes = 512 },
            } },
            .{ .name = "notifications.reservation_created", .namespace = "Notifications", .method = "reservation_created", .version = @as(u32, 1), .arity = @as(usize, 1), .authority_bits = @as(u16, 1 << 13), .max_result_bytes = @as(usize, 256), .contract = .{
                .arguments = .{ .tuple = .{reservation} },
                .result = .nil,
            } },
        };
    };
}

pub const operations = Catalogue(100).operations;
// Same operation versions and bootstrap; only a schema bound changes.
pub const operations_v2 = Catalogue(101).operations;

fn TurnContract(comptime maximum_attempts: i64) type {
    return struct {
        pub const value = .{
            .state = .{ .object = .{
                .{ .name = "attempts", .schema = .{ .integer = .{ .min = 0, .max = maximum_attempts } } },
                .{ .name = "reservations", .schema = .{ .integer = .{ .min = 0 } } },
            } },
            .input = .{ .object = .{
                .{ .name = "sku", .schema = Catalogue(100).sku },
                .{ .name = "quantity", .schema = Catalogue(100).quantity },
                .{ .name = "mode", .schema = .{ .string = .{ .max_bytes = 64 } } },
            } },
            .result = .{ .object = .{
                .{ .name = "status", .schema = .{ .enum_string = .{ "reserved", "out_of_stock" } } },
                .{ .name = "reservation", .schema = Catalogue(100).reservation, .optional = true },
                .{ .name = "code", .schema = .{ .enum_string = .{"OutOfStock"} }, .optional = true },
            } },
        };
    };
}

// The generic worker wrapper compiles this plain declaration into the child;
// the parent admits an owned copy of the same contract before starting a turn.
pub const turn_contract = TurnContract(0x7fff_ffff_ffff_ffff).value;
pub const turn_contract_v2 = TurnContract(1_000_000).value;
pub const grants: []const []const u8 = &.{ "stock.reserve", "notifications.reservation_created" };
pub const max_bytes: usize = 16 * 1024;
pub const bootstrap_contract = "reservation-domain/v1;single-widget-stock;in-memory-intents;explicit-commit";

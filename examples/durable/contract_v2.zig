//! Application version `inventory/v2` contracts. State additionally records
//! the number of OutOfStock rejections, and the optional fault-instrumentation
//! `mode` input is gone. The operation catalogue and result shape are
//! unchanged from v1; the state schema, input schema, Ruby source, and
//! bootstrap contract differ, so v2 is a distinct ledger application.
const original = @import("durable_original_contract");
pub const operations = original.operations;
pub const grants = original.grants;
pub const turn_contract = .{
    .state = .{ .object = .{
        .{ .name = "attempts", .schema = .{ .integer = .{ .min = 0, .max = original.max_attempts } } },
        .{ .name = "rejections", .schema = .{ .integer = .{ .min = 0, .max = original.max_attempts } } },
    } },
    .input = .{ .object = .{
        .{ .name = "sku", .schema = original.sku },
        .{ .name = "quantity", .schema = original.quantity },
        .{ .name = "fail", .schema = .boolean },
    } },
    .result = original.turn_contract.result,
};
pub const max_bytes = original.max_bytes;
pub const max_receipt_bytes = original.max_receipt_bytes;
pub const max_snapshot_rows = original.max_snapshot_rows;
pub const bootstrap_contract = original.bootstrap_contract ++ ";state-rejections-v1";
pub const Phase = original.Phase;
pub const Checkpoint = original.Checkpoint;

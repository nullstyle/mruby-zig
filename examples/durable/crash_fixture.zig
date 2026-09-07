//! A real durable host paused by its independent test supervisor. This fixture
//! is never installed, and its checkpoints are inaccessible to guest Ruby.
const std = @import("std");
const mruby = @import("mruby");
const host_module = @import("durable_host");
const contract = @import("durable_contract");
const harness = @import("crash_harness.zig");

const Gate = struct {
    selected: contract.Phase,
    ordinal: u32,
    count: u32 = 0,
    reached: bool = false,

    fn hit(raw: ?*anyopaque, phase: contract.Phase) void {
        const self: *Gate = @ptrCast(@alignCast(raw.?));
        if (phase != self.selected) return;
        self.count += 1;
        if (self.count != self.ordinal) return;
        self.reached = true;
        harness.checkpoint();
    }
};

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const database = args.next() orelse return error.MissingDatabase;
    const worker = args.next() orelse return error.MissingWorker;
    const worker_second = args.next() orelse return error.MissingSecondWorker;
    const phase_name = args.next() orelse return error.MissingPhase;
    const phase = std.meta.stringToEnum(contract.Phase, phase_name) orelse return error.UnknownPhase;
    const ordinal = try std.fmt.parseInt(u32, args.next() orelse return error.MissingOrdinal, 10);
    const recipient = args.next() orelse return error.MissingRecipient;
    if (ordinal == 0 or args.next() != null) return error.InvalidArguments;
    var gate: Gate = .{ .selected = phase, .ordinal = ordinal };
    var host = try host_module.Host.open(init.gpa, database, &.{ worker, worker_second }, .{
        .checkpoint = .{ .context = &gate, .hit = Gate.hit },
    });
    defer host.close();
    var input = try mruby.effect.data.encode(init.gpa, .{ .hash = &.{
        .{ .key = .{ .string = "sku" }, .value = .{ .string = "widget" } },
        .{ .key = .{ .string = "quantity" }, .value = .{ .integer = 2 } },
        .{ .key = .{ .string = "fail" }, .value = .{ .boolean = false } },
    } }, contract.max_bytes);
    defer input.deinit(init.gpa);
    var result = try host.execute(.{ .turn_id = "crash-turn", .expected_revision = 0, .input = input.view() });
    defer result.deinit();
    switch (phase) {
        .before_delivery, .after_recipient_commit, .after_delivery_ack => {
            _ = try host.dispatch(recipient);
        },
        else => {},
    }
    if (!gate.reached) return error.CheckpointNotReached;
    return 0;
}

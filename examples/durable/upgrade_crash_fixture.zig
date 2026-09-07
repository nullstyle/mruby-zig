//! Durable host paused at an upgrade boundary by the test supervisor. The
//! ledger already holds one committed v1 turn; this fixture performs the
//! explicit upgrade to inventory/v2 and reports the requested checkpoint.
const std = @import("std");
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
    // The upgrade never delivers; the recipient path only keeps the shared
    // supervisor argv shape.
    _ = args.next() orelse return error.MissingRecipient;
    if (ordinal == 0 or args.next() != null) return error.InvalidArguments;
    var gate: Gate = .{ .selected = phase, .ordinal = ordinal };
    var host = try host_module.Host.open(init.gpa, database, &.{ worker, worker_second }, .{
        .checkpoint = .{ .context = &gate, .hit = Gate.hit },
    });
    defer host.close();
    const status = try host.status();
    if (status.revision < 1) return error.ExpectedCommittedTurn;
    _ = try host.upgrade(.{ .upgrade_id = "crash-upgrade", .expected_revision = status.revision, .target = "inventory/v2" });
    if (!gate.reached) return error.CheckpointNotReached;
    return 0;
}

//! Standalone alternate-schema host. Uses the existing supervisor protocol to
//! report the observed conflict before exiting cleanly; never launches a worker.
//! The changed whole-turn schema changes this build's application identity, so
//! opening the ledger now fails closed instead of merely conflicting on retry.
const std = @import("std");
const host_module = @import("durable_host");
const harness = @import("crash_harness.zig");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const database = args.next() orelse return error.MissingDatabase;
    const worker = args.next() orelse return error.MissingWorker;
    const worker_second = args.next() orelse return error.MissingSecondWorker;
    const turn_id = args.next() orelse return error.MissingTurnId;
    const ordinal = args.next() orelse return error.MissingOrdinal;
    _ = args.next() orelse return error.MissingRecipient;
    if (!std.mem.eql(u8, ordinal, "1") or args.next() != null) return error.InvalidArguments;
    _ = turn_id;
    var host = host_module.Host.open(init.gpa, database, &.{ worker, worker_second }, .{}) catch |err| {
        if (err != error.ApplicationIdentityMismatch) return err;
        harness.checkpoint();
        return;
    };
    defer host.close();
    return error.ExpectedApplicationIdentityMismatch;
}

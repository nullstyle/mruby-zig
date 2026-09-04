//! The real worker entrypoint with test-only boundary synchronization.
//! FD 5 is a dedicated lifetime writer, left open until kernel teardown.
const std = @import("std");
const worker = @import("worker_entry");

extern fn mrz_orphan_worker_gate(stage: c_int, selected: c_int) c_int;
var selected: c_int = 0;

const Observer = struct {
    pub fn reached(comptime stage: worker.Observation) !void {
        const value: c_int = switch (stage) {
            .request_body => 1,
            .execution => 2,
            .response => 3,
        };
        if (mrz_orphan_worker_gate(value, selected) != 0) return error.FixtureSynchronizationFailed;
    }
};

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    selected = try std.fmt.parseInt(c_int, args.next() orelse return error.MissingPhase, 10);
    if (selected < 1 or selected > 3) return error.InvalidPhase;
    return worker.mainObserved(init, Observer);
}

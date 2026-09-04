//! Sandboxing end to end: a restricted policy, host bootstrap + seal,
//! resource ceilings, error classification, and host access between runs.
//!
//!     zig build run-sandbox

const std = @import("std");
const mruby = @import("mruby");

pub fn main() !void {
    // 1. Bootstrap: define host surface on the raw vm, then seal.
    //    The restricted preset strips eval/send/introspection/ObjectSpace
    //    and freezes the object model; limits apply from the first run.
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(
        mruby.sandbox.Policy.restricted(.{
            .limits = .{
                .gas = .{ .per_execution = 200_000 },
                .call_depth = 64,
            },
        }),
    );
    defer boot.deinit();

    const budget = try boot.vm().defineClass("Budget", null);
    try budget.defineMethod("spend", struct {
        fn call(vm: *mruby.Vm, self: mruby.Value, units: i64) anyerror!mruby.Value {
            _ = self;
            if (units < 0) return vm.raise("ArgumentError", "units must be non-negative");
            return vm.intValue(units * 2);
        }
    }.call);
    const iso = try boot.seal();
    defer iso.deinit();

    // 2. Ordinary execution; results are observed through the locked host
    //    surface, not raw vm access.
    const spent = try iso.run("Budget.new.spend(21)");
    try iso.setGlobal("last_result", spent);
    std.debug.print("spend(21) = {d}\n", .{try (try iso.getGlobal("last_result")).asInt()});

    // 3. Capability stripping: eval is masked by the restricted preset.
    if (iso.run("eval('1 + 1')")) |_| {
        return error.ExpectedEvalStripped;
    } else |err| switch (err) {
        error.RubyException => try iso.clearError(),
        else => return error.UnexpectedError,
    }

    // 4. Gas exhaustion is renewable per execution: the failed run unwinds
    //    (ensure blocks run), state survives, and the next run gets a fresh
    //    allowance.
    if (iso.run(
        \\$ticks = 0
        \\begin
        \\  loop { $ticks += 1 }
        \\ensure
        \\  $ticks = -1
        \\end
    )) |_| {
        return error.ExpectedGasExhaustion;
    } else |err| switch (err) {
        error.GasExhausted => {},
        else => return error.UnexpectedTermination,
    }

    const ticks = try iso.run("$ticks");
    std.debug.print("after gas exhaustion, $ticks = {d}\n", .{try ticks.asInt()});

    const stats = iso.stats();
    std.debug.print("gas generation {d}, {d} instructions lifetime\n", .{
        stats.gas.?.generation,
        stats.instructions,
    });
}

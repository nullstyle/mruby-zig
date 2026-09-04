//! Runtime benchmarks for the embedding and sandboxing layers.
//!
//!     zig build run-bench                         # default (Debug) build
//!     zig build run-bench -Doptimize=ReleaseSafe  # reference numbers
//!
//! Each metric warms up, then repeats a fixed workload and reports
//! wall-clock per-op statistics. Numbers are machine-dependent; see
//! docs/benchmarks.md for methodology and reference observations.

const std = @import("std");
const mruby = @import("mruby");

const Script = struct {
    /// Fixed compute workload (deterministic opcode mix: loop, compare,
    /// add, array index).
    const compute =
        \\values = [1, 2, 3, 4, 5, 6, 7, 8]
        \\i = 0
        \\total = 0
        \\while i < 500
        \\  total += values[i % 8]
        \\  i += 1
        \\end
        \\total
    ;
    /// Method body for the call-loop metric.
    const method = "def spin(x); x + 1; end; 0";
    /// Ruby loop calling a host callback each iteration.
    const host_call = "i = 0\nwhile i < 1_000\n  i = Bench.add(i, 1)\nend\ni";
    /// Medium value graph for capsule roundtrips.
    const graph =
        \\pairs = {}
        \\i = 0
        \\while i < 200
        \\  pairs[i.to_s.freeze] = [i, i * 2, i * 3]
        \\  i += 1
        \\end
        \\pairs
    ;
};

fn spawnSealed(policy: mruby.sandbox.Policy) !mruby.sandbox.Isolate {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(policy);
    defer boot.deinit();
    return boot.seal();
}

const Sample = struct {
    ops: usize,
    ns_total: u128,

    fn perOpUs(self: Sample) f64 {
        return @as(f64, @floatFromInt(self.ns_total)) / @as(f64, @floatFromInt(self.ops)) / 1_000.0;
    }
    fn opsPerSec(self: Sample) f64 {
        return @as(f64, @floatFromInt(self.ops)) / (@as(f64, @floatFromInt(self.ns_total)) / 1e9);
    }
};

fn benchVmCycle(out: *std.Io.Writer) !void {
    var sample = Sample{ .ops = 0, .ns_total = 0 };
    const clock = mruby.sandbox.monotonicNs;

    // Warmup.
    for (0..20) |_| {
        const vm = try mruby.Vm.init();
        vm.deinit();
    }

    const reps = 300;
    const start_ns = clock();
    for (0..reps) |_| {
        const vm = try mruby.Vm.init();
        sample.ops += 1;
        vm.deinit();
    }
    sample.ns_total = @intCast(clock() - start_ns);
    try report(out, "vm-cycle (init+deinit)", sample);
}

fn benchIsolateCycle(out: *std.Io.Writer) !void {
    for (0..20) |_| {
        const iso = try spawnSealed(mruby.sandbox.Policy.trusted(.{}));
        iso.deinit();
    }

    const clock = mruby.sandbox.monotonicNs;
    const start_ns = clock();
    const reps = 200;
    var ops: usize = 0;
    for (0..reps) |_| {
        const iso = try spawnSealed(mruby.sandbox.Policy.trusted(.{}));
        ops += 1;
        iso.deinit();
    }
    try report(out, "isolate-cycle (spawn+seal+deinit)", .{ .ops = ops, .ns_total = @intCast(clock() - start_ns) });
}

fn benchEvalCold(out: *std.Io.Writer) !void {
    const iso = try spawnSealed(mruby.sandbox.Policy.trusted(.{}));
    defer iso.deinit();

    for (0..20) |_| _ = try iso.run(Script.compute);

    const clock = mruby.sandbox.monotonicNs;
    const start_ns = clock();
    const reps = 300;
    var ops: usize = 0;
    for (0..reps) |_| {
        _ = try iso.run(Script.compute);
        ops += 1;
    }
    try report(out, "eval-cold (parse+codegen+run)", .{ .ops = ops, .ns_total = @intCast(clock() - start_ns) });
}

fn benchRiteCached(out: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const iso = try spawnSealed(mruby.sandbox.Policy.trusted(.{}));
    defer iso.deinit();

    var image = try mruby.sandbox.compileRite(gpa, Script.compute, .{});
    defer image.deinit(gpa);
    const view = image.view();

    for (0..50) |_| _ = try iso.runRite(view);

    const clock = mruby.sandbox.monotonicNs;
    const start_ns = clock();
    const reps = 2_000;
    var ops: usize = 0;
    for (0..reps) |_| {
        _ = try iso.runRite(view);
        ops += 1;
    }
    try report(out, "rite-cached (validate+run)", .{ .ops = ops, .ns_total = @intCast(clock() - start_ns) });
}

fn benchCallLoop(out: *std.Io.Writer) !void {
    const iso = try spawnSealed(mruby.sandbox.Policy.trusted(.{}));
    defer iso.deinit();
    const receiver = try iso.run(Script.method);

    const clock = mruby.sandbox.monotonicNs;
    const start_ns = clock();
    const reps = 20_000;
    var ops: usize = 0;
    for (0..reps) |_| {
        _ = try iso.call(receiver, "spin", .{@as(i64, 1)});
        ops += 1;
    }
    try report(out, "call-loop (Zig->Ruby method)", .{ .ops = ops, .ns_total = @intCast(clock() - start_ns) });
}

fn benchHostCallback(out: *std.Io.Writer) !void {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.trusted(.{}));
    defer boot.deinit();
    const cls = try boot.vm().defineClass("Bench", null);
    try cls.defineClassMethod("add", struct {
        fn call(vm: *mruby.Vm, self: mruby.Value, a: i64, b: i64) anyerror!mruby.Value {
            _ = self;
            return vm.intValue(a + b);
        }
    }.call);
    const iso = try boot.seal();
    defer iso.deinit();

    for (0..5) |_| _ = try iso.run(Script.host_call);

    const clock = mruby.sandbox.monotonicNs;
    const start_ns = clock();
    const reps = 40;
    var ops: usize = 0;
    for (0..reps) |_| {
        const r = try iso.run(Script.host_call);
        if (try r.asInt() != 1_000) return error.BadHostLoopResult;
        ops += 1_000;
    }
    try report(out, "host-callback (Ruby->Zig, 1k/op)", .{ .ops = ops, .ns_total = @intCast(clock() - start_ns) });
}

fn benchGasHookCost(out: *std.Io.Writer) !void {
    const unlimited = try spawnSealed(mruby.sandbox.Policy.trusted(.{}));
    defer unlimited.deinit();
    const metered = try spawnSealed(mruby.sandbox.Policy.trusted(.{ .limits = .{
        .gas = .{ .per_isolate = std.math.maxInt(u64) },
    } }));
    defer metered.deinit();

    for (0..10) |_| {
        _ = try unlimited.run(Script.compute);
        _ = try metered.run(Script.compute);
    }

    const clock = mruby.sandbox.monotonicNs;
    const start_ns = clock();
    const reps = 300;
    var ops: usize = 0;
    for (0..reps) |_| {
        _ = try unlimited.run(Script.compute);
        ops += 1;
    }
    const plain_ns: u128 = @intCast(clock() - start_ns);

    const metered_start = clock();
    ops = 0;
    for (0..reps) |_| {
        _ = try metered.run(Script.compute);
        ops += 1;
    }
    const metered_ns: u128 = @intCast(clock() - metered_start);

    try report(out, "gas-hook off (unlimited)", .{ .ops = ops, .ns_total = plain_ns });
    try report(out, "gas-hook on (per-isolate)", .{ .ops = ops, .ns_total = metered_ns });
    const ratio = @as(f64, @floatFromInt(metered_ns)) / @as(f64, @floatFromInt(plain_ns));
    try out.print("    overhead ratio: {d:.2}x\n", .{ratio});
}

fn benchCapsuleRoundtrip(out: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const producer = try spawnSealed(mruby.sandbox.Policy.trusted(.{}));
    defer producer.deinit();
    const root = try producer.run(Script.graph);

    // Warmup + export timing.
    for (0..5) |_| {
        var capsule = try producer.exportValue(gpa, root, .{});
        capsule.deinit(gpa);
    }
    const clock = mruby.sandbox.monotonicNs;
    const start_ns = clock();
    const reps = 50;
    var bytes: usize = 0;
    for (0..reps) |_| {
        var capsule = try producer.exportValue(gpa, root, .{});
        bytes = capsule.view().bytes.len;
        capsule.deinit(gpa);
    }
    try report(out, "capsule-export (200-entry graph)", .{ .ops = reps, .ns_total = @intCast(clock() - start_ns) });
    try out.print("    encoded bytes: {d}\n", .{bytes});

    const consumer = try spawnSealed(mruby.sandbox.Policy.trusted(.{}));
    defer consumer.deinit();
    var capsule = try producer.exportValue(gpa, root, .{});
    defer capsule.deinit(gpa);
    const view = capsule.view();

    for (0..5) |_| _ = try consumer.importValue(view, .{});
    const import_start = clock();
    var ops: usize = 0;
    for (0..reps) |_| {
        _ = try consumer.importValue(view, .{});
        ops += 1;
    }
    try report(out, "capsule-import (200-entry graph)", .{ .ops = ops, .ns_total = @intCast(clock() - import_start) });
}

fn report(out: *std.Io.Writer, name: []const u8, sample: Sample) !void {
    try out.print("{s:<32} {d:>10.2} us/op {d:>12.0} ops/s\n", .{ name, sample.perOpUs(), sample.opsPerSec() });
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const w = &stdout_file.interface;
    defer w.flush() catch {};

    try w.print("mruby-zig benchmarks ({s}, {s})\n\n", .{
        @tagName(@import("builtin").mode),
        @tagName(@import("builtin").target.cpu.arch),
    });
    try w.writeAll("metric                               per-op        throughput\n");
    try w.writeAll("----------------------------------------------------------------\n");

    try benchVmCycle(w);
    try benchIsolateCycle(w);
    try benchEvalCold(w);
    try benchRiteCached(w, gpa);
    try benchCallLoop(w);
    try benchHostCallback(w);
    try benchGasHookCost(w);
    try benchCapsuleRoundtrip(w, gpa);
    try benchWorkerRite(init, gpa, w);

    return 0;
}

/// One-shot worker-process roundtrip (spawn + IPC + execute + reap),
/// resolved as the installed sibling of this binary. Skipped when the
/// platform or deployment does not provide the helper.
fn benchWorkerRite(init: std.process.Init, gpa: std.mem.Allocator, out: *std.Io.Writer) !void {
    if (comptime !mruby.features.worker_process_supported) {
        try out.print("{s:<32} {s:>10}    {s:>12}\n", .{ "worker-rite (process roundtrip)", "skipped", "unsupported" });
        return;
    }
    const self_path = std.process.executablePathAlloc(init.io, gpa) catch return;
    defer gpa.free(self_path);
    const dir = std.fs.path.dirname(self_path) orelse return;
    const worker_path = try std.fs.path.join(gpa, &.{ dir, "mruby-worker" });
    defer gpa.free(worker_path);

    std.Io.Dir.accessAbsolute(init.io, worker_path, .{}) catch {
        try out.print("{s:<32} {s:>10}    {s:>12}\n", .{ "worker-rite (process roundtrip)", "skipped", "no helper" });
        return;
    };

    var image = try mruby.sandbox.compileRite(gpa, "$input + 1", .{});
    defer image.deinit(gpa);

    const producer = try spawnSealed(mruby.sandbox.Policy.trusted(.{}));
    defer producer.deinit();
    const count = try producer.run("count = 41");
    var input_capsule = try producer.exportValue(gpa, count, .{});
    defer input_capsule.deinit(gpa);

    const request: mruby.worker.Request = .{
        .image = image.view(),
        .input = .{ .capsule = input_capsule.view() },
        .policy = mruby.sandbox.Policy.restricted(.{
            .limits = .{ .gas = .{ .per_execution = 1_000_000 } },
        }),
        .process = .{
            .wall_time_ns = 10 * std.time.ns_per_s,
            .cpu_seconds = 10,
        },
    };

    // Warmup + correctness check.
    {
        var rep = try mruby.worker.runRite(init.io, gpa, worker_path, request);
        defer rep.deinit(gpa);
        switch (rep.outcome) {
            .value => {},
            .ruby_exception => |exc| {
                std.debug.print("worker bench: {s}: {s}\n", .{ exc.class_name, exc.message });
                return error.UnexpectedWorkerOutcome;
            },
            else => |variant| {
                std.debug.print("worker bench outcome: {s}\n", .{@tagName(variant)});
                return error.UnexpectedWorkerOutcome;
            },
        }
    }

    const clock = mruby.sandbox.monotonicNs;
    const reps = 100;
    var ops: usize = 0;
    const start_ns = clock();
    for (0..reps) |_| {
        var rep = try mruby.worker.runRite(init.io, gpa, worker_path, request);
        defer rep.deinit(gpa);
        switch (rep.outcome) {
            .value => {},
            else => return error.UnexpectedWorkerOutcome,
        }
        ops += 1;
    }
    try report(out, "worker-rite (process roundtrip)", .{ .ops = ops, .ns_total = @intCast(clock() - start_ns) });
}

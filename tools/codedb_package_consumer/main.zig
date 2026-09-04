//! Runs after the package, consumer sources, and build caches are removed.
const std = @import("std");
const mruby = @import("mruby");
const manifest = @import("codedb_manifest");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    try std.testing.expect(!mruby.features.has_compiler);
    try std.testing.expect(!mruby.features.hasGem("mruby-eval"));
    try std.testing.expect(mruby.features.has_debug_hook);
    try std.testing.expect(mruby.worker.supported);

    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{
        .limits = .{ .gas = .{ .per_execution = 10_000 } },
    }));
    defer boot.deinit();
    const isolate = try boot.seal();
    defer isolate.deinit();
    try std.testing.expectError(error.CompilerUnavailable, isolate.run("42"));

    try std.testing.expect(try isolate.loadArtifact(manifest, "initialize"));
    try std.testing.expect(!try isolate.loadArtifact(manifest, "initialize"));
    try std.testing.expectEqualStrings("application/configuration.rb", try (try isolate.getGlobal("configuration_source")).asString());
    try std.testing.expectEqualStrings("application/initialize.rb", try (try isolate.getGlobal("initialization_source")).asString());
    try std.testing.expectEqual(@as(i64, 1), try (try isolate.getGlobal("initializations")).asInt());

    // Inputs are constructed through the native API; all application Ruby is
    // embedded by the generated manifest, with stable source names intact.
    try isolate.setGlobal("subtotal", try isolate.intValue(40));
    for (1..3) |expected_jobs| {
        const result = try (try isolate.runArtifact(manifest, "job")).asArray();
        try std.testing.expectEqual(@as(i64, 42), try (try result.get(0)).asInt());
        try std.testing.expectEqualStrings("jobs/calculation.rb", try (try result.get(1)).asString());
        try std.testing.expectEqual(@as(i64, @intCast(expected_jobs)), try (try result.get(2)).asInt());
    }
    try std.testing.expect(!try isolate.loadArtifact(manifest, "initialize"));
    try std.testing.expectEqual(@as(i64, 2), try (try isolate.getGlobal("jobs")).asInt());
    try std.testing.expect(isolate.stats().instructions > 0);

    // Resolve only the deployed sibling; running from an unrelated working
    // directory must not depend on the checkout, compiler, or build cache.
    const application_path = try std.process.executablePathAlloc(init.io, allocator);
    defer allocator.free(application_path);
    const application_dir = std.fs.path.dirname(application_path) orelse return error.InvalidApplicationPath;
    const worker_executable = try std.fs.path.join(allocator, &.{ application_dir, "mruby-worker" });
    defer allocator.free(worker_executable);
    var input = try isolate.exportValue(allocator, try isolate.intValue(41), .{});
    defer input.deinit(allocator);
    var report = try mruby.worker.runRite(init.io, allocator, worker_executable, .{
        .image = mruby.codedb.find(manifest, "worker").?,
        .input = .{ .capsule = input.view() },
        .policy = mruby.sandbox.Policy.restricted(.{
            .limits = .{ .gas = .{ .per_execution = 1_000 } },
        }),
        .process = .{ .wall_time_ns = 5 * std.time.ns_per_s, .cpu_seconds = 2 },
    });
    defer report.deinit(allocator);
    switch (report.outcome) {
        .value => |capsule| try std.testing.expectEqual(@as(i64, 42), try (try isolate.importValue(capsule.view(), .{})).asInt()),
        else => return error.UnexpectedWorkerOutcome,
    }
    try std.testing.expect(report.sandbox_stats.?.instructions > 0);
    std.debug.print("packaged CodeDB: initialization, jobs, and worker capsule -> 42\n", .{});
}

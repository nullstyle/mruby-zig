//! A deployable consumer: application Ruby is compiled only during the build.
const std = @import("std");
const mruby_zig = @import("mruby_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gem_set = b.option([]const u8, "gem-set", "mruby gem preset") orelse "standard";
    const dependency = b.dependency("mruby_zig", .{
        .target = target,
        .optimize = optimize,
        .@"gem-set" = gem_set,
        .@"no-compiler" = true,
    });
    const bundle = try mruby_zig.addCodeDB(b, dependency, .{
        .sources = &.{
            .{
                .name = "job",
                .source = b.path("job.rb"),
                .source_name = "jobs/calculation.rb",
                .dependencies = &.{"initialize"},
                .entrypoint = false,
            },
            .{
                .name = "initialize",
                .source = b.path("init.rb"),
                .source_name = "application/initialize.rb",
                .dependencies = &.{"configuration"},
            },
            .{
                .name = "configuration",
                .source = b.path("config.rb"),
                .source_name = "application/configuration.rb",
                .entrypoint = false,
            },
            .{
                .name = "worker",
                .source = b.path("worker.rb"),
                .source_name = "jobs/worker.rb",
            },
        },
    });
    const root = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("mruby", dependency.module("mruby"));
    root.addImport("codedb_manifest", bundle.manifest);
    const executable = b.addExecutable(.{ .name = "codedb-package-consumer", .root_module = root });
    b.installArtifact(executable);
    // Keep the deployed worker's compatibility and compiler profile identical
    // to the application. Its cache path never enters the application's code.
    b.installArtifact(dependency.artifact("mruby-worker"));
}

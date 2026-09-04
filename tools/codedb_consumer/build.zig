//! Downstream CodeDB integration fixture. Run `zig build test` here.
const std = @import("std");
const mruby_zig = @import("mruby_zig");

const Mismatch = enum { none, schema, compatibility, authority_profile, authority_effective, authority_tier };
const GraphError = enum { none, missing, duplicate, cycle };
const AuthorityCase = enum {
    none,
    forbidden_host,
    missing_host,
    unknown_requirement,
    unknown_host,
    unknown_allowlist,
    narrow_profile,
    trusted_host,
    custom_worker,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gem_set = b.option([]const u8, "gem-set", "mruby gem preset") orelse "standard";
    const without_gems = b.option([]const u8, "without-gems", "omit selected mruby gems") orelse "";
    const no_compiler = b.option(bool, "no-compiler", "omit the target Ruby compiler") orelse false;
    const mismatch = b.option(Mismatch, "consumer_mismatch", "deliberate compile-fail fixture") orelse .none;
    const graph_error = b.option(GraphError, "consumer_graph_error", "deliberate invalid CodeDB graph") orelse .none;
    const authority_case = b.option(AuthorityCase, "consumer_authority_case", "exercise CodeDB authority admission") orelse .none;
    const reverse = b.option(bool, "consumer_reverse", "reverse declarations to verify reproducibility") orelse false;
    const dependency = b.dependency("mruby_zig", .{
        .target = target,
        .optimize = optimize,
        .@"gem-set" = gem_set,
        .@"without-gems" = without_gems,
        .@"no-compiler" = no_compiler,
    });
    const entry_name = "billing/\"weekly\"";
    const library_name = "libraries/\"shared\"";
    const clock_binding = "host/\"clock\"";
    const arithmetic_binding = "host/arithmetic";
    const AuthoritySet = mruby_zig.CodeDB.AuthoritySet;
    // These declarations exercise trusted inventory metadata. The fixture
    // does not register Ruby callbacks or claim to discover host methods.
    var host_bindings = [_]mruby_zig.CodeDB.HostBinding{
        .{ .name = clock_binding, .authority = AuthoritySet.init(&.{.clock}) },
        .{ .name = arithmetic_binding, .authority = .empty },
        .{ .name = "host/filesystem", .authority = AuthoritySet.init(&.{.filesystem}) },
    };
    var host_count: usize = 2;
    var references = [_][]const u8{ arithmetic_binding, clock_binding };
    var tier: mruby_zig.CodeDB.Tier = .worker;
    var sources = [_]mruby_zig.CodeDB.Source{
        .{
            // Logical names must be escaped as Zig strings, never used as
            // paths. The stable compiler filename is independently supplied.
            .name = entry_name,
            .source = b.path("billing.rb"),
            .source_name = "jobs/billing job.rb",
            .dependencies = &.{library_name},
            .host_bindings = &references,
        },
        .{
            .name = library_name,
            .source = b.path("lib.rb"),
            .source_name = "support/shared library.rb",
            .entrypoint = false,
            .required_authority = AuthoritySet.init(&.{.entropy}),
        },
    };
    switch (graph_error) {
        .none => {},
        .missing => sources[0].dependencies = &.{"missing/\"module\""},
        .duplicate => sources[0].dependencies = &.{ library_name, library_name },
        .cycle => sources[1].dependencies = &.{entry_name},
    }
    var source_count: usize = sources.len;
    switch (authority_case) {
        .none => {},
        // This binding is deliberately unreferenced: its ambient authority
        // must still contribute to every artifact's classification.
        .forbidden_host => host_count = host_bindings.len,
        .missing_host => sources[0].host_bindings = &.{"host/undeclared"},
        .unknown_requirement => sources[1].required_authority = AuthoritySet.fromBits(0x8000),
        .unknown_host => host_bindings[0].authority = AuthoritySet.fromBits(0x8000),
        .unknown_allowlist => tier = .{ .custom = AuthoritySet.fromBits(0x8000) },
        .narrow_profile => {
            const constant = b.addWriteFiles().add("constant.rb", "42\n");
            sources[0] = .{ .name = "constant", .source = constant };
            source_count = 1;
            host_count = 0;
            tier = .{ .custom = .empty };
        },
        .trusted_host => {
            host_count = host_bindings.len;
            tier = .trusted;
        },
        .custom_worker => tier = .{ .custom = AuthoritySet.init(&.{
            .clock,            .entropy,        .dynamic_code,  .dynamic_dispatch, .introspection,
            .heap_enumeration, .model_mutation, .continuations, .host_output,
        }) },
    }
    if (reverse) {
        std.mem.reverse(mruby_zig.CodeDB.Source, sources[0..source_count]);
        std.mem.reverse(mruby_zig.CodeDB.HostBinding, host_bindings[0..host_count]);
        std.mem.reverse([]const u8, &references);
    }
    const bundle = try mruby_zig.addCodeDB(b, dependency, .{
        .sources = sources[0..source_count],
        .tier = tier,
        .host_bindings = host_bindings[0..host_count],
    });
    const options = b.addOptions();
    options.addOption(Mismatch, "mismatch", mismatch);
    options.addOption(AuthorityCase, "authority_case", authority_case);
    options.addOption(bool, "no_compiler", no_compiler);
    const root = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("mruby", dependency.module("mruby"));
    root.addImport("codedb_manifest", bundle.manifest);
    root.addOptions("consumer_options", options);
    const executable = b.addExecutable(.{ .name = "codedb-consumer", .root_module = root });
    const install_executable = b.addInstallArtifact(executable, .{});
    b.getInstallStep().dependOn(&install_executable.step);

    // Install the complete bundle so separate cache/build roots can compare
    // manifest and artifact bytes without knowing Zig's cache layout.
    const install_bundle = b.addInstallDirectory(.{
        .source_dir = bundle.directory,
        .install_dir = .prefix,
        .install_subdir = "codedb",
    });
    b.getInstallStep().dependOn(&install_bundle.step);
    const run = b.addRunArtifact(executable);
    const test_step = b.step("test", "verify downstream CodeDB build and execution");
    test_step.dependOn(&run.step);
    test_step.dependOn(&install_executable.step);
    test_step.dependOn(&install_bundle.step);
}

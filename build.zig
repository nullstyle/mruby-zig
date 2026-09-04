//! mruby-zig build.
//!
//! Replicates mruby's Rake build entirely inside `zig build` — no Ruby, no
//! rake, no submodules:
//!
//!   1. presym scan #1  : preprocess mruby core + compiler + mrbc tool with
//!                        `-DMRB_PRESYM_SCANNING`; generate id.h/table.h for
//!                        the host tool (mirrors the nested mrbc build).
//!   2. host mrbc       : compile the mrbc cross-compiler with `zig cc`.
//!   3. bytecode        : run mrbc on mrblib/*.rb and gem mrblib/*.rb,
//!                        producing cdump C sources; assemble mrblib.c and
//!                        per-gem gem_init.c (Rake's templates).
//!   4. presym scan #2  : scan everything the final library compiles,
//!                        including the generated files (this is how
//!                        Ruby-level symbols reach the presym table).
//!   5. libmruby        : static library built from all C sources; the Zig
//!                        side provides `mrb_basic_alloc_func` (src/alloc.zig)
//!                        so src/allocf.c is excluded.
//!   6. `mruby` module  : idiomatic Zig API linking libmruby; plus tests and
//!                        examples.

const std = @import("std");
const sources = @import("build/sources.zig");
const gems_mod = @import("build/gems.zig");
const gen = @import("build/gen.zig");

const mruby_version = "4.0.0";
const rite_binary_version = "04.00";
const rite_vm_version = "0400";
const portable_container_flags = &.{
    "-DMRB_STR_LENGTH_MAX=0",
    "-DMRB_ARY_LENGTH_MAX=0",
};
// Zig's built-in fuzzer uses a native inline coverage map. Instrumenting the
// linked mruby C objects with Clang's sanitizer-coverage ABI adds counters
// without matching PC records, so keep coverage focused on the Zig parser.
const no_c_fuzz_coverage = "-fno-sanitize-coverage=trace-pc-guard,trace-cmp,trace-div,indirect-calls,inline-8bit-counters,pc-table";
/// Bump when local C/Zig ABI or generated-code behavior changes RITE loading
/// compatibility without changing an input represented below.
const rite_compatibility_epoch: u32 = 3;
const hash_integer_patch_marker = "mruby-hash-rinteger-value-hash=v1";
const hash_symbol_patch_marker = "mruby-hash-symbol-name-hash=v1";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "enable ThreadSanitizer") orelse false;

    const allocator_name = b.option(
        []const u8,
        "allocator",
        "default mruby allocator: \"libc\" or process-lifetime \"arena\"",
    ) orelse "libc";
    const allocator_profile = parseAllocatorProfile(allocator_name) catch |err| {
        std.debug.print(
            "error: unknown -Dallocator={s} (expected \"libc\" or \"arena\")\n",
            .{allocator_name},
        );
        return err;
    };

    const explicit_gem_set = b.option([]const u8, "gem-set", "gem set: \"standard\" or \"minimal\"");
    const stdlib_gems = b.option(
        bool,
        "stdlib-gems",
        "deprecated gem-set alias: true selects \"standard\", false selects \"minimal\"",
    );
    const legacy_gem_set: ?[]const u8 = if (stdlib_gems) |enabled|
        if (enabled) "standard" else "minimal"
    else
        null;
    if (explicit_gem_set != null and legacy_gem_set != null and
        !std.mem.eql(u8, explicit_gem_set.?, legacy_gem_set.?))
    {
        std.debug.print(
            "error: conflicting -Dgem-set={s} and -Dstdlib-gems={}\n",
            .{ explicit_gem_set.?, stdlib_gems.? },
        );
        return error.ConflictingGemOptions;
    }
    const gem_set = explicit_gem_set orelse legacy_gem_set orelse "standard";
    const with_gems = b.option([]const u8, "with-gems", "comma-separated extra gems to enable on top of the gem set");
    const without_gems = b.option([]const u8, "without-gems", "comma-separated gems to remove from the gem set");

    const arena = b.graph.arena;
    const mruby_dep = b.dependency("mruby", .{});
    const root = mruby_dep.path("");

    const selected_gems = try selectGems(arena, gem_set, with_gems, without_gems);
    var gem_defines: std.ArrayList([]const u8) = .empty;
    for (selected_gems) |g| {
        for (g.defines) |d| {
            try gem_defines.append(arena, try std.fmt.allocPrint(arena, "-D{s}", .{d}));
        }
    }

    // Host tools shared by the pipeline.
    const artifact_identity_mod = b.createModule(.{
        .root_source_file = b.path("build/artifact_identity.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const presym_gen = hostTool(b, "tools/presym_gen.zig");
    presym_gen.root_module.addImport("artifact_identity", artifact_identity_mod);
    const artifact_config_gen = hostTool(b, "tools/artifact_config_gen.zig");
    artifact_config_gen.root_module.addImport("artifact_identity", artifact_identity_mod);
    const file_join = hostTool(b, "tools/file_join.zig");
    const hash_patcher = hostTool(b, "tools/patch_mruby_hash.zig");
    const patched_hash = patchMrubyHash(b, arena, hash_patcher, root);

    // ============================= stage 1 =================================
    // Presym headers for the host mrbc build: scan core (with allocf.c),
    // compiler, and the mrbc tool itself.
    const host_triple = try b.graph.host.result.zigTriple(arena);

    var mrbc_scan: std.ArrayList(ScanInput) = .empty;
    try addTreeFiles(arena, &mrbc_scan, root, &sources.core_srcs, "core");
    try mrbc_scan.append(arena, .{ .lp = try root.join(arena, sources.allocf_src), .pp_name = "core_allocf.c.pp" });
    try addTreeFiles(arena, &mrbc_scan, root, &sources.compiler_srcs, "compiler");
    try addTreeFiles(arena, &mrbc_scan, root, &sources.mrbc_srcs, "mrbc");

    const mrbc_presym_dir = try presymHeaders(b, presym_gen, arena, mrbc_scan.items, &.{}, root, host_triple);

    // ============================= stage 2 =================================
    const mrbc_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    var mrbc_files: std.ArrayList([]const u8) = .empty;
    try mrbc_files.appendSlice(arena, &sources.core_srcs);
    try mrbc_files.append(arena, sources.allocf_src);
    try mrbc_files.appendSlice(arena, &sources.compiler_srcs);
    try mrbc_files.appendSlice(arena, &sources.mrbc_srcs);
    mrbc_mod.addCSourceFiles(.{
        .root = root,
        .files = mrbc_files.items,
        .flags = &.{
            "-w",
            "-DMRB_STR_LENGTH_MAX=0",
            "-DMRB_ARY_LENGTH_MAX=0",
        },
    });
    mrbc_mod.addIncludePath(try root.join(arena, "include"));
    mrbc_mod.addIncludePath(mrbc_presym_dir);
    const mrbc = b.addExecutable(.{ .name = "mrbc", .root_module = mrbc_mod });

    // ============================= stage 3 =================================
    // Bytecode: core mrblib + per-gem mrblib, then assemble the generated
    // C files exactly like tasks/mrblib.rake and lib/mruby/gem.rb do.
    var generated_c: std.ArrayList(GeneratedC) = .empty;

    {
        var rb: std.ArrayList(std.Build.LazyPath) = .empty;
        for (sources.mrblib_rb_files) |f| try rb.append(arena, try root.join(arena, f));
        const body = try runMrbc(b, arena, mrbc, "mrblib_proc", rb.items, "mrblib_body.c");
        const file = joinFiles(b, file_join, "mrblib.c", arena, &.{
            .{ .str = mrblib_banner },
            .{ .file = body },
            .{ .str = try gen.mrblibFooter(arena) },
        });
        try generated_c.append(arena, .{ .lp = file, .pp_name = "mrblib.c.pp" });
    }

    for (selected_gems) |g| {
        const fn_ = g.funcname(try arena.alloc(u8, g.name.len));
        const header = try gen.gemInitHeader(arena, g);
        const footer = try gen.gemInitFooter(arena, g);
        const gem_init_name = try std.fmt.allocPrint(arena, "{s}_gem_init.c", .{fn_});
        const pp_name = try std.fmt.allocPrint(arena, "gem_{s}_gem_init.c.pp", .{fn_});
        if (g.rb_files.len != 0) {
            var rb: std.ArrayList(std.Build.LazyPath) = .empty;
            for (g.rb_files) |f| try rb.append(arena, try root.join(arena, f));
            const sym = try std.fmt.allocPrint(arena, "gem_mrblib_{s}_proc", .{fn_});
            const body = try runMrbc(b, arena, mrbc, sym, rb.items, try std.fmt.allocPrint(arena, "{s}_body.c", .{fn_}));
            const file = joinFiles(b, file_join, gem_init_name, arena, &.{
                .{ .str = header },
                .{ .file = body },
                .{ .str = footer },
            });
            try generated_c.append(arena, .{ .lp = file, .pp_name = pp_name });
        } else {
            const wf = b.addWriteFiles();
            const file = wf.add(gem_init_name, try std.fmt.allocPrint(arena, "{s}{s}", .{ header, footer }));
            try generated_c.append(arena, .{ .lp = file, .pp_name = pp_name });
        }
    }

    {
        const wf = b.addWriteFiles();
        const file = wf.add("gem_init.c", try gen.topGemInit(arena, selected_gems));
        try generated_c.append(arena, .{ .lp = file, .pp_name = "gem_init.c.pp" });
    }

    // ============================= stage 4 =================================
    // Presym headers for the final library: everything that gets compiled,
    // including the generated files above.
    const triple = try target.result.zigTriple(arena);
    // mrbconf.h enables an ELF `etext`/`edata` optimization by default, but
    // Zig's linker does not provide those symbols. Keep preprocessing and
    // compilation on the same documented fallback path.
    const ro_data_flags: []const []const u8 = if (target.result.os.tag == .linux)
        &.{"-DMRB_NO_DEFAULT_RO_DATA_P"}
    else
        &.{};
    var lib_scan: std.ArrayList(ScanInput) = .empty;
    for (sources.core_srcs) |path| {
        if (std.mem.eql(u8, path, "src/hash.c")) {
            try lib_scan.append(arena, .{ .lp = patched_hash, .pp_name = "core_src_hash.c.pp" });
        } else {
            try lib_scan.append(arena, .{
                .lp = try root.join(arena, path),
                .pp_name = try std.fmt.allocPrint(arena, "core_{s}", .{try mangle(arena, path, &.{ "c", "pp" })}),
            });
        }
    }
    try addTreeFiles(arena, &lib_scan, root, &sources.compiler_srcs, "compiler");
    var gem_include_dirs: std.ArrayList(std.Build.LazyPath) = .empty;
    for (selected_gems) |g| {
        for (g.c_srcs) |s| {
            try lib_scan.append(arena, .{
                .lp = try root.join(arena, s),
                .pp_name = try mangle(arena, s, &.{ "c", "pp" }),
                .includes = g.include_dirs,
            });
        }
        for (g.include_dirs) |dir| {
            try gem_include_dirs.append(arena, try root.join(arena, dir));
        }
    }
    try lib_scan.append(arena, .{ .lp = b.path("src/shim.c"), .pp_name = "mruby_zig_shim.c.pp" });
    for (generated_c.items) |g| try lib_scan.append(arena, .{ .lp = g.lp, .pp_name = g.pp_name });

    // Keep the presym scan consistent with the compile-time defines.
    const lib_scan_defines = defines: {
        var d: std.ArrayList([]const u8) = .empty;
        try d.appendSlice(arena, gem_defines.items);
        try d.append(arena, "-DMRB_USE_DEBUG_HOOK");
        try d.appendSlice(arena, portable_container_flags);
        try d.appendSlice(arena, ro_data_flags);
        break :defines d.items;
    };
    const lib_presym_dir = try presymHeaders(b, presym_gen, arena, lib_scan.items, lib_scan_defines, root, triple);

    // ============================= stage 5 =================================
    // The `mruby` module carries the entire C library (core + compiler +
    // gems + generated sources + shim) so consumers never link anything
    // themselves. The Zig-side allocator override (src/alloc.zig, which
    // exports mrb_basic_alloc_func) lives in the same module, which is why
    // src/allocf.c is not part of the build.
    const lib_flags = flags: {
        var f: std.ArrayList([]const u8) = .empty;
        try f.append(arena, "-w");
        // Enables mrb->code_fetch_hook (NULL-guarded per-instruction call
        // site) used by the sandboxing layer for limits and termination.
        try f.append(arena, "-DMRB_USE_DEBUG_HOOK");
        try f.appendSlice(arena, portable_container_flags);
        try f.append(arena, no_c_fuzz_coverage);
        try f.appendSlice(arena, ro_data_flags);
        try f.appendSlice(arena, gem_defines.items);
        break :flags f.items;
    };

    const shim_flags = flags: {
        var f: std.ArrayList([]const u8) = .empty;
        try f.appendSlice(arena, &.{ "-Wall", "-Wextra", "-DMRB_USE_DEBUG_HOOK" });
        try f.appendSlice(arena, portable_container_flags);
        try f.append(arena, no_c_fuzz_coverage);
        try f.appendSlice(arena, ro_data_flags);
        try f.appendSlice(arena, gem_defines.items);
        break :flags f.items;
    };

    const mruby_mod = b.addModule("mruby", .{
        .root_source_file = b.path("src/mruby.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libc = true,
    });
    const allocator_config = b.addOptions();
    allocator_config.addOption(bool, "use_arena", allocator_profile == .arena);
    mruby_mod.addOptions("allocator_config", allocator_config);
    const artifact_config = try artifactConfigModule(
        b,
        artifact_config_gen,
        arena,
        target.result,
        selected_gems,
        mruby_dep.builder.pkg_hash,
        lib_presym_dir,
    );
    mruby_mod.addImport("artifact_config", artifact_config);
    var lib_files: std.ArrayList([]const u8) = .empty;
    for (sources.core_srcs) |path| {
        if (!std.mem.eql(u8, path, "src/hash.c")) try lib_files.append(arena, path);
    }
    try lib_files.appendSlice(arena, &sources.compiler_srcs);
    for (selected_gems) |g| try lib_files.appendSlice(arena, g.c_srcs);
    mruby_mod.addCSourceFiles(.{ .root = root, .files = lib_files.items, .flags = lib_flags });
    mruby_mod.addCSourceFile(.{ .file = patched_hash, .flags = lib_flags });
    // Generated sources (cache paths, not under the dependency root).
    for (generated_c.items) |g| {
        mruby_mod.addCSourceFile(.{ .file = g.lp, .flags = lib_flags });
    }
    // ABI shim: exposes mruby's macro-only inline APIs as plain functions.
    mruby_mod.addCSourceFile(.{ .file = b.path("src/shim.c"), .flags = shim_flags });
    mruby_mod.addIncludePath(try root.join(arena, "include"));
    mruby_mod.addIncludePath(lib_presym_dir);
    for (gem_include_dirs.items) |dir| mruby_mod.addIncludePath(dir);

    const check_step = b.step(
        "check",
        "compile all tests, tools, and examples without running them",
    );

    // REPL tool.
    const repl_mod = b.createModule(.{
        .root_source_file = b.path("tools/repl.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    repl_mod.addImport("mruby", mruby_mod);
    const repl = b.addExecutable(.{ .name = "mruby-repl", .root_module = repl_mod });
    check_step.dependOn(&repl.step);
    b.installArtifact(repl);
    const run_repl = b.addRunArtifact(repl);
    run_repl.step.dependOn(b.getInstallStep());
    const repl_step = b.step("run-repl", "interactive mruby REPL");
    repl_step.dependOn(&run_repl.step);

    // Tests.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    test_mod.addImport("mruby", mruby_mod);
    const test_config = b.addOptions();
    test_config.addOption(bool, "has_core_language_suite", hasAllGemsExcept(selected_gems, &gems_mod.standard, &.{
        "mruby-enumerator",
        "mruby-enum-lazy",
        "mruby-set",
        "mruby-pack",
    }));
    test_config.addOption(bool, "has_numerics_suite", hasNamedGems(selected_gems, &.{
        "mruby-eval",
        "mruby-numeric-ext",
        "mruby-string-ext",
        "mruby-math",
    }));
    test_config.addOption(bool, "has_string_ext", hasGem(selected_gems, "mruby-string-ext"));
    test_config.addOption(bool, "has_math", hasGem(selected_gems, "mruby-math"));
    test_config.addOption(bool, "has_random", hasGem(selected_gems, "mruby-random"));
    test_config.addOption(bool, "has_time", hasGem(selected_gems, "mruby-time"));
    test_config.addOption(bool, "has_object_space", hasGem(selected_gems, "mruby-objectspace"));
    test_mod.addOptions("test_config", test_config);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    check_step.dependOn(&unit_tests.step);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "run unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);

    const artifact_identity_test_mod = b.createModule(.{
        .root_source_file = b.path("build/artifact_identity.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const artifact_identity_tests = b.addTest(.{ .root_module = artifact_identity_test_mod });
    check_step.dependOn(&artifact_identity_tests.step);
    const run_artifact_identity_tests = b.addRunArtifact(artifact_identity_tests);
    test_step.dependOn(&run_artifact_identity_tests.step);

    const gem_tests_mod = b.createModule(.{
        .root_source_file = b.path("build/gems.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const gem_tests = b.addTest(.{ .root_module = gem_tests_mod });
    check_step.dependOn(&gem_tests.step);
    const run_gem_tests = b.addRunArtifact(gem_tests);
    test_step.dependOn(&run_gem_tests.step);

    // Pure StateCapsule parser fuzz target. A normal `zig build test` runs the
    // stable corpus once; `zig build fuzz-state-capsule --fuzz=100K` enables
    // Zig's coverage-guided engine. The callback never creates an mruby VM.
    const state_capsule_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/state_capsule_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    state_capsule_fuzz_mod.addImport("mruby", mruby_mod);
    const state_capsule_fuzz_tests = b.addTest(.{ .root_module = state_capsule_fuzz_mod });
    check_step.dependOn(&state_capsule_fuzz_tests.step);
    const run_state_capsule_fuzz_tests = b.addRunArtifact(state_capsule_fuzz_tests);
    test_step.dependOn(&run_state_capsule_fuzz_tests.step);
    const fuzz_state_capsule_step = b.step(
        "fuzz-state-capsule",
        "fuzz the pure StateCapsule frame and graph parser",
    );
    fuzz_state_capsule_step.dependOn(&run_state_capsule_fuzz_tests.step);

    // The integration suite above roots at src/tests.zig and pulls in the
    // library as an imported module, so Zig never collects the `test` blocks
    // that live *inside* the mruby module (src/convert.zig, src/alloc.zig,
    // ...). Run those with the module itself as the test root; src/mruby.zig's
    // aggregator (`_ = @import(...)`) reaches every test-bearing file.
    const mod_tests = b.addTest(.{ .root_module = mruby_mod });
    check_step.dependOn(&mod_tests.step);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    // A real producer and consumer executable exchange the encoded capsule
    // through captured stdout/stdin. They are separately linked OS processes;
    // the consumer restores into a new Isolate and checks the complete graph.
    const capsule_producer_mod = b.createModule(.{
        .root_source_file = b.path("tools/state_capsule_process_producer.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    capsule_producer_mod.addImport("mruby", mruby_mod);
    const capsule_producer = b.addExecutable(.{
        .name = "state-capsule-process-producer",
        .root_module = capsule_producer_mod,
    });
    check_step.dependOn(&capsule_producer.step);
    const run_capsule_producer = b.addRunArtifact(capsule_producer);
    const transferred_capsule = run_capsule_producer.captureStdOut(.{
        .basename = "state-capsule.bin",
    });

    const capsule_consumer_mod = b.createModule(.{
        .root_source_file = b.path("tools/state_capsule_process_consumer.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    capsule_consumer_mod.addImport("mruby", mruby_mod);
    const capsule_consumer = b.addExecutable(.{
        .name = "state-capsule-process-consumer",
        .root_module = capsule_consumer_mod,
    });
    check_step.dependOn(&capsule_consumer.step);
    const run_capsule_consumer = b.addRunArtifact(capsule_consumer);
    run_capsule_consumer.setStdIn(.{ .lazy_path = transferred_capsule });
    test_step.dependOn(&run_capsule_consumer.step);
    const process_fixture_step = b.step(
        "test-state-capsule-process",
        "transfer a StateCapsule between producer and consumer processes",
    );
    process_fixture_step.dependOn(&run_capsule_consumer.step);

    // Examples.
    const ex_names = [_][]const u8{ "quickstart", "host_functions", "exceptions" };
    for (ex_names) |ex_name| {
        const ex_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{ex_name})),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        });
        ex_mod.addImport("mruby", mruby_mod);
        const ex = b.addExecutable(.{ .name = ex_name, .root_module = ex_mod });
        check_step.dependOn(&ex.step);
        b.installArtifact(ex);

        const run_cmd = b.addRunArtifact(ex);
        run_cmd.step.dependOn(b.getInstallStep());
        const run_step = b.step(b.fmt("run-{s}", .{ex_name}), b.fmt("run the {s} example", .{ex_name}));
        run_step.dependOn(&run_cmd.step);
    }
}

// --------------------------------------------------------------------------
// helpers

const ScanInput = struct {
    lp: std.Build.LazyPath,
    pp_name: []const u8,
    /// Extra include dirs (relative to the mruby root) this file needs.
    includes: []const []const u8 = &.{},
};
const GeneratedC = struct { lp: std.Build.LazyPath, pp_name: []const u8 };

const AllocatorProfile = enum {
    libc,
    arena,
};

fn parseAllocatorProfile(name: []const u8) !AllocatorProfile {
    return std.meta.stringToEnum(AllocatorProfile, name) orelse
        error.UnknownAllocator;
}

fn artifactConfigModule(
    b: *std.Build,
    artifact_config_gen: *std.Build.Step.Compile,
    arena: std.mem.Allocator,
    target: std.Target,
    selected_gems: []const gems_mod.Gem,
    mruby_package_hash: []const u8,
    final_presym_dir: std.Build.LazyPath,
) !*std.Build.Module {
    const pointer_bits = target.ptrBitWidth();
    if (pointer_bits != 32 and pointer_bits != 64) {
        std.debug.panic("mruby RITE identity does not support {d}-bit pointers", .{pointer_bits});
    }

    var semantic_defines: std.ArrayList([]const u8) = .empty;
    try semantic_defines.append(arena, "MRB_USE_DEBUG_HOOK");
    try semantic_defines.appendSlice(arena, &.{
        "MRB_STR_LENGTH_MAX=0",
        "MRB_ARY_LENGTH_MAX=0",
    });

    var ordered_gems: std.ArrayList([]const u8) = .empty;

    for (selected_gems) |gem| {
        try ordered_gems.append(arena, gem.name);
        for (gem.defines) |define| try semantic_defines.append(arena, define);
    }

    const generated_configuration = &.{
        "presym-scanner=v1",
        "presym-define=MRB_PRESYM_SCANNING",
        "presym-target-traits=pointer-width,endian",
        "mrbc-cdump=static,no-extension-tables",
        "mrblib-template=v1",
        "gem-init-template=v1",
        hash_integer_patch_marker,
        hash_symbol_patch_marker,
    };

    const run = b.addRunArtifact(artifact_config_gen);
    run.addFileArg(final_presym_dir.path(b, "presym.digest"));
    run.addArg(mruby_version);
    run.addArg(mruby_package_hash);
    run.addArg(rite_binary_version);
    run.addArg(rite_vm_version);
    run.addArg(try std.fmt.allocPrint(arena, "{d}", .{rite_compatibility_epoch}));
    run.addArg(try std.fmt.allocPrint(arena, "{d}", .{pointer_bits}));
    run.addArg(switch (target.cpu.arch.endian()) {
        .little => "little",
        .big => "big",
    });
    // The pinned mrbconf.h defaults to word boxing, binary64 Float, and
    // pointer-width Integer. Any future override belongs in these traits.
    run.addArg(try std.fmt.allocPrint(arena, "{d}", .{pointer_bits}));
    run.addArg("64");
    run.addArg("word");
    run.addArg("true");
    try addIdentitySequenceArgs(run, arena, semantic_defines.items);
    try addIdentitySequenceArgs(run, arena, ordered_gems.items);
    try addIdentitySequenceArgs(run, arena, generated_configuration);

    const generated_config = run.addOutputFileArg("artifact_config.zig");
    return b.createModule(.{ .root_source_file = generated_config });
}

fn addIdentitySequenceArgs(
    run: *std.Build.Step.Run,
    arena: std.mem.Allocator,
    values: []const []const u8,
) !void {
    run.addArg(try std.fmt.allocPrint(arena, "{d}", .{values.len}));
    for (values) |value| run.addArg(value);
}

const mrblib_banner =
    \\/*
    \\ * This file is loading the mrblib
    \\ *
    \\ * IMPORTANT:
    \\ *   This file was generated!
    \\ *   All manual changes will get lost.
    \\ */
    \\
;

fn selectGems(
    arena: std.mem.Allocator,
    gem_set: []const u8,
    with: ?[]const u8,
    without: ?[]const u8,
) ![]const gems_mod.Gem {
    var failure: gems_mod.SelectionFailure = .{};
    return gems_mod.select(arena, .{
        .gem_set = gem_set,
        .with = with,
        .without = without,
    }, &failure) catch |err| {
        switch (failure.kind) {
            .unknown_gem_set => std.debug.print(
                "error: unknown -Dgem-set={s} (expected \"standard\" or \"minimal\")\n",
                .{failure.name},
            ),
            .unknown_gem => std.debug.print(
                "error: unknown gem in build options: {s}\n",
                .{failure.name},
            ),
            .unknown_dependency => std.debug.print(
                "error: gem {s} depends on unknown gem {s}\n",
                .{ failure.dependent, failure.name },
            ),
            .dependency_cycle => std.debug.print(
                "error: gem dependency cycle includes {s}\n",
                .{failure.name},
            ),
            .none => {},
        }
        return err;
    };
}

fn hasGem(enabled_gems: []const gems_mod.Gem, name: []const u8) bool {
    for (enabled_gems) |gem| {
        if (std.mem.eql(u8, gem.name, name)) return true;
    }
    return false;
}

fn hasAllGemsExcept(enabled_gems: []const gems_mod.Gem, required: []const gems_mod.Gem, exceptions: []const []const u8) bool {
    for (required) |gem| {
        var excepted = false;
        for (exceptions) |exception| {
            if (std.mem.eql(u8, gem.name, exception)) {
                excepted = true;
                break;
            }
        }
        if (!excepted and !hasGem(enabled_gems, gem.name)) return false;
    }
    return true;
}

fn hasNamedGems(enabled_gems: []const gems_mod.Gem, required: []const []const u8) bool {
    for (required) |name| {
        if (!hasGem(enabled_gems, name)) return false;
    }
    return true;
}

fn hostTool(b: *std.Build, path: []const u8) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(path),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const name = std.fs.path.basename(path);
    return b.addExecutable(.{
        .name = name[0 .. name.len - ".zig".len],
        .root_module = mod,
    });
}

/// Register dependency-tree C files for a presym scan, giving each a unique
/// preprocessed-output name derived from its relative path.
fn addTreeFiles(
    arena: std.mem.Allocator,
    out: *std.ArrayList(ScanInput),
    root: std.Build.LazyPath,
    files: []const []const u8,
    prefix: []const u8,
) !void {
    for (files) |f| {
        try out.append(arena, .{
            .lp = try root.join(arena, f),
            .pp_name = try std.fmt.allocPrint(arena, "{s}_{s}", .{ prefix, try mangle(arena, f, &.{ "c", "pp" }) }),
        });
    }
}

/// "mrbgems/mruby-set/src/set.c" + exts {"c","pp"} -> "mrbgems_mruby-set_src_set.c.pp"
fn mangle(arena: std.mem.Allocator, rel: []const u8, exts: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (rel) |ch| try buf.append(arena, if (ch == '/') '_' else ch);
    for (exts) |e| {
        try buf.append(arena, '.');
        try buf.appendSlice(arena, e);
    }
    return buf.toOwnedSlice(arena);
}

/// Preprocess every input with `zig cc -E -P -DMRB_PRESYM_SCANNING`, then run
/// presym_gen over the results (out dir as its last argument). Returns the
/// generated include directory containing `mruby/presym/{id.h,table.h}` plus
/// `presym.digest`, the canonical final symbol-to-ID compatibility digest.
fn presymHeaders(
    b: *std.Build,
    presym_gen: *std.Build.Step.Compile,
    arena: std.mem.Allocator,
    inputs: []const ScanInput,
    defines: []const []const u8,
    root: std.Build.LazyPath,
    triple: []const u8,
) !std.Build.LazyPath {
    const include = try root.join(arena, "include");
    const run = b.addRunArtifact(presym_gen);
    for (inputs) |in| {
        const cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-E", "-P", "-DMRB_PRESYM_SCANNING" });
        cmd.addArg("-target");
        cmd.addArg(triple);
        cmd.addPrefixedDirectoryArg("-I", include);
        for (in.includes) |dir| {
            cmd.addPrefixedDirectoryArg("-I", try root.join(arena, dir));
        }
        for (defines) |d| cmd.addArg(d);
        cmd.addFileArg(in.lp);
        cmd.addArg("-o");
        run.addFileArg(cmd.addOutputFileArg(in.pp_name));
    }
    return run.addOutputDirectoryArg("presym");
}

/// Run host mrbc over `rb_files`, producing a cdump C file (like
/// `Command::Mrbc#run` with cdump: true, static: true).
fn runMrbc(
    b: *std.Build,
    arena: std.mem.Allocator,
    mrbc: *std.Build.Step.Compile,
    sym: []const u8,
    rb_files: []const std.Build.LazyPath,
    out_basename: []const u8,
) !std.Build.LazyPath {
    const run = b.addRunArtifact(mrbc);
    run.addArg(try std.fmt.allocPrint(arena, "-B{s}", .{sym}));
    run.addArg("-S");
    run.addArg("-s");
    run.addArg("-o");
    const out = run.addOutputFileArg(out_basename);
    for (rb_files) |f| run.addFileArg(f);
    return out;
}

const JoinPart = union(enum) {
    str: []const u8,
    file: std.Build.LazyPath,
};

fn patchMrubyHash(
    b: *std.Build,
    arena: std.mem.Allocator,
    patcher: *std.Build.Step.Compile,
    root: std.Build.LazyPath,
) std.Build.LazyPath {
    const run = b.addRunArtifact(patcher);
    run.addFileArg(root.join(arena, "src/hash.c") catch @panic("OOM"));
    return run.addOutputFileArg("hash.c");
}

fn joinFiles(
    b: *std.Build,
    file_join: *std.Build.Step.Compile,
    out_basename: []const u8,
    arena: std.mem.Allocator,
    parts: []const JoinPart,
) std.Build.LazyPath {
    _ = arena;
    const run = b.addRunArtifact(file_join);
    run.addArg("--output");
    const out = run.addOutputFileArg(out_basename);
    for (parts) |p| switch (p) {
        .str => |s| {
            run.addArg("--str");
            run.addArg(s);
        },
        .file => |f| {
            run.addArg("--file");
            run.addFileArg(f);
        },
    };
    return out;
}

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
const authority = @import("build/authority.zig");
const sources = @import("build/sources.zig");
const gems_mod = @import("build/gems.zig");
const gen = @import("build/gen.zig");

pub const CodeDB = @import("build/codedb.zig");

/// Compile application Ruby for the exact target/gem profile of `dependency`.
/// Import the returned manifest beside dependency.module("mruby").
pub fn addCodeDB(b: *std.Build, dependency: *std.Build.Dependency, options: CodeDB.Options) !CodeDB.Bundle {
    return CodeDB.add(b, .{
        .mrbc = dependency.namedLazyPath("codedb-mrbc"),
        .envelope = dependency.namedLazyPath("codedb-envelope"),
    }, options);
}

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
    const no_compiler = b.option(bool, "no-compiler", "omit the target Ruby parser/code generator; retain build-time mrbc") orelse false;
    const sanitize_thread = b.option(bool, "sanitize-thread", "enable ThreadSanitizer") orelse false;
    const sanitize_c = if (b.option(bool, "sanitize-c", "enable C undefined-behavior detection in unsafe builds") orelse false)
        std.zig.SanitizeC.full
    else
        null;
    const worker_target_supported = switch (target.result.os.tag) {
        .linux, .macos => target.result.ptrBitWidth() == 64,
        else => false,
    };

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
    const allow_worker_ambient_authority = b.option(
        bool,
        "allow-worker-ambient-authority",
        "build the generic worker even when linked gems expose host-access authority",
    ) orelse false;

    const arena = b.graph.arena;
    const mruby_dep = b.dependency("mruby", .{});
    const root = mruby_dep.path("");

    const selected_gems = try selectGems(arena, gem_set, with_gems, without_gems, no_compiler);
    const builtin_authority: []const authority.Source = if (no_compiler)
        gems_mod.builtin_authority[0..1]
    else
        &gems_mod.builtin_authority;
    var available_authority = authority.aggregate(builtin_authority);
    for (selected_gems) |gem| {
        available_authority = available_authority.unionWith(gem.authority);
    }
    const worker_decision = authority.workerDecision(
        available_authority,
        worker_target_supported,
        allow_worker_ambient_authority,
    );
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
    if (!no_compiler) try addTreeFiles(arena, &lib_scan, root, &sources.compiler_srcs, "compiler");
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
        if (no_compiler) try d.append(arena, "-DMRZ_NO_COMPILER");
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
        if (no_compiler) try f.append(arena, "-DMRZ_NO_COMPILER");
        try f.appendSlice(arena, portable_container_flags);
        try f.append(arena, no_c_fuzz_coverage);
        try f.appendSlice(arena, ro_data_flags);
        try f.appendSlice(arena, gem_defines.items);
        break :flags f.items;
    };

    const shim_flags = flags: {
        var f: std.ArrayList([]const u8) = .empty;
        try f.appendSlice(arena, &.{ "-Wall", "-Wextra", "-DMRB_USE_DEBUG_HOOK" });
        if (no_compiler) try f.append(arena, "-DMRZ_NO_COMPILER");
        try f.appendSlice(arena, portable_container_flags);
        try f.append(arena, no_c_fuzz_coverage);
        try f.appendSlice(arena, ro_data_flags);
        try f.appendSlice(arena, gem_defines.items);
        break :flags f.items;
    };

    // The worker wire format is VM-independent and shared by the public
    // controller module and the separately linked helper executable.
    const worker_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/worker_protocol.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });

    const authority_manifest_mod = b.createModule(.{
        .root_source_file = b.path("build/authority.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mruby_mod = b.addModule("mruby", .{
        .root_source_file = b.path("src/mruby.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
        .link_libc = true,
    });
    mruby_mod.addImport("authority_manifest", authority_manifest_mod);
    mruby_mod.addImport("worker_protocol", worker_protocol_mod);
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
        no_compiler,
    );
    mruby_mod.addImport("artifact_config", artifact_config);
    // Comptime feature manifest: everything here is known at configure time
    // (gem selection resolves above), so plain build options suffice and
    // consumers get correct build-graph dependencies through the module.
    var authority_source_names: std.ArrayList([]const u8) = .empty;
    var authority_source_bits: std.ArrayList(u16) = .empty;
    for (builtin_authority) |source| {
        try authority_source_names.append(arena, source.name);
        try authority_source_bits.append(arena, source.authority.toBits());
    }
    for (selected_gems) |gem| {
        try authority_source_names.append(arena, gem.name);
        try authority_source_bits.append(arena, gem.authority.toBits());
    }
    const build_features = b.addOptions();
    {
        var gem_names: std.ArrayList([]const u8) = .empty;
        for (selected_gems) |gem| try gem_names.append(arena, gem.name);
        build_features.addOption([]const []const u8, "gems", gem_names.items);
        build_features.addOption(
            []const []const u8,
            "authority_source_names",
            authority_source_names.items,
        );
        build_features.addOption(
            []const u16,
            "authority_source_bits",
            authority_source_bits.items,
        );
        build_features.addOption(u16, "authority_bits", available_authority.toBits());
        build_features.addOption(bool, "worker_target_supported", worker_target_supported);
        build_features.addOption(bool, "worker_profile_eligible", worker_decision.profile_eligible);
        build_features.addOption(
            bool,
            "worker_ambient_authority_opt_in",
            worker_decision.ambient_authority_opt_in,
        );
        build_features.addOption(bool, "worker_process_supported", worker_decision.enabled);
        build_features.addOption([]const u8, "gem_set", gem_set);
        build_features.addOption(bool, "has_compiler", !no_compiler);
        build_features.addOption(
            bool,
            "custom_selection",
            with_gems != null or without_gems != null,
        );
        build_features.addOption([]const u8, "mruby_version", mruby_version);
        build_features.addOption(u16, "pointer_bits", target.result.ptrBitWidth());
    }
    mruby_mod.addOptions("build_features", build_features);
    var lib_files: std.ArrayList([]const u8) = .empty;
    for (sources.core_srcs) |path| {
        if (!std.mem.eql(u8, path, "src/hash.c")) try lib_files.append(arena, path);
    }
    if (!no_compiler) try lib_files.appendSlice(arena, &sources.compiler_srcs);
    for (selected_gems) |g| try lib_files.appendSlice(arena, g.c_srcs);
    mruby_mod.addCSourceFiles(.{ .root = root, .files = lib_files.items, .flags = lib_flags });
    mruby_mod.addCSourceFile(.{ .file = patched_hash, .flags = lib_flags });
    // Generated sources (cache paths, not under the dependency root).
    for (generated_c.items) |g| {
        mruby_mod.addCSourceFile(.{ .file = g.lp, .flags = lib_flags });
    }
    // ABI shim: exposes mruby's macro-only inline APIs as plain functions.
    mruby_mod.addCSourceFile(.{ .file = b.path("src/shim.c"), .flags = shim_flags });
    if (worker_decision.enabled) {
        const worker_spawn_flags_macos = [_][]const u8{ "-Wall", "-Wextra", "-pthread", no_c_fuzz_coverage };
        const worker_spawn_flags = [_][]const u8{ "-Wall", "-Wextra", no_c_fuzz_coverage };
        mruby_mod.addCSourceFile(.{
            .file = b.path("src/worker_spawn.c"),
            .flags = if (target.result.os.tag == .macos)
                &worker_spawn_flags_macos
            else
                &worker_spawn_flags,
        });
        if (target.result.os.tag == .macos) {
            mruby_mod.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
        }
    }
    mruby_mod.addIncludePath(try root.join(arena, "include"));
    mruby_mod.addIncludePath(lib_presym_dir);
    for (gem_include_dirs.items) |dir| mruby_mod.addIncludePath(dir);

    const check_step = b.step(
        "check",
        "compile supported tests, tools, and examples for the selected profile",
    );

    // One-shot process-isolated RITE worker. The controller takes this exact
    // path explicitly; it never searches PATH or guesses an install layout.
    // Do not add the POSIX-only helper to unsupported target graphs.
    var worker_mod_for_tests: ?*std.Build.Module = null;
    var worker_descendant_fixture: ?*std.Build.Step.Compile = null;
    var worker_signal_fixture: ?*std.Build.Step.Compile = null;
    var worker_address_space_fixture: ?*std.Build.Step.Compile = null;
    var worker_sigchld_fixture: ?*std.Build.Step.Compile = null;
    const worker_executable: ?*std.Build.Step.Compile = if (worker_decision.enabled) worker: {
        const worker_mod = b.createModule(.{
            .root_source_file = b.path("tools/mruby_worker.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        worker_mod.addImport("mruby", mruby_mod);
        worker_mod.addImport("worker_protocol", worker_protocol_mod);
        worker_mod_for_tests = worker_mod;
        const executable = b.addExecutable(.{
            .name = "mruby-worker",
            .root_module = worker_mod,
        });
        check_step.dependOn(&executable.step);
        b.installArtifact(executable);

        const descendant_fixture_mod = b.createModule(.{
            .root_source_file = b.path("tools/worker_descendant_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        descendant_fixture_mod.addImport("worker_protocol", worker_protocol_mod);
        const descendant_fixture = b.addExecutable(.{
            .name = "worker-descendant-fixture",
            .root_module = descendant_fixture_mod,
        });
        check_step.dependOn(&descendant_fixture.step);
        worker_descendant_fixture = descendant_fixture;

        const signal_fixture_config = b.addOptions();
        signal_fixture_config.addOptionPath("worker_executable", executable.getEmittedBin());
        const signal_fixture_mod = b.createModule(.{
            .root_source_file = b.path("tools/worker_signal_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        signal_fixture_mod.addOptions("worker_signal_fixture_config", signal_fixture_config);
        const signal_fixture = b.addExecutable(.{
            .name = "worker-signal-fixture",
            .root_module = signal_fixture_mod,
        });
        check_step.dependOn(&signal_fixture.step);
        worker_signal_fixture = signal_fixture;

        if (target.result.os.tag == .linux) {
            const address_space_fixture_config = b.addOptions();
            address_space_fixture_config.addOptionPath(
                "worker_executable",
                executable.getEmittedBin(),
            );
            const address_space_fixture_mod = b.createModule(.{
                .root_source_file = b.path("tools/worker_address_space_fixture.zig"),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
                .sanitize_c = sanitize_c,
            });
            address_space_fixture_mod.addOptions(
                "worker_address_space_fixture_config",
                address_space_fixture_config,
            );
            const address_space_fixture = b.addExecutable(.{
                .name = "worker-address-space-fixture",
                .root_module = address_space_fixture_mod,
            });
            check_step.dependOn(&address_space_fixture.step);
            worker_address_space_fixture = address_space_fixture;
        }

        const sigchld_fixture_config = b.addOptions();
        sigchld_fixture_config.addOptionPath("worker_executable", executable.getEmittedBin());
        const sigchld_fixture_mod = b.createModule(.{
            .root_source_file = b.path("tools/worker_sigchld_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        sigchld_fixture_mod.addImport("mruby", mruby_mod);
        sigchld_fixture_mod.addOptions(
            "worker_sigchld_fixture_config",
            sigchld_fixture_config,
        );
        const sigchld_fixture = b.addExecutable(.{
            .name = "worker-sigchld-fixture",
            .root_module = sigchld_fixture_mod,
        });
        check_step.dependOn(&sigchld_fixture.step);
        worker_sigchld_fixture = sigchld_fixture;
        break :worker executable;
    } else null;

    if (!no_compiler) {
        // REPL tool.
        const repl_mod = b.createModule(.{
            .root_source_file = b.path("tools/repl.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        repl_mod.addImport("mruby", mruby_mod);
        const repl = b.addExecutable(.{ .name = "mruby-repl", .root_module = repl_mod });
        check_step.dependOn(&repl.step);
        b.installArtifact(repl);
        const run_repl = b.addRunArtifact(repl);
        run_repl.step.dependOn(b.getInstallStep());
        const repl_step = b.step("run-repl", "interactive mruby REPL");
        repl_step.dependOn(&run_repl.step);
    } else {
        unsupportedCompilerStep(b, "run-repl", "interactive mruby REPL");
    }

    const test_step = b.step("test", "run unit and integration tests for the selected profile");
    if (!no_compiler) {
        // Tests.
        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        test_mod.addImport("mruby", mruby_mod);
        test_mod.addImport("authority_manifest", authority_manifest_mod);
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
        test_config.addOption(bool, "sanitize_thread", sanitize_thread);
        if (worker_executable) |executable| {
            test_config.addOptionPath("worker_executable", executable.getEmittedBin());
        } else {
            test_config.addOption([]const u8, "worker_executable", "");
        }
        if (worker_descendant_fixture) |fixture| {
            test_config.addOptionPath("worker_descendant_fixture", fixture.getEmittedBin());
        } else {
            test_config.addOption([]const u8, "worker_descendant_fixture", "");
        }
        if (worker_signal_fixture) |fixture| {
            test_config.addOptionPath("worker_signal_fixture", fixture.getEmittedBin());
        } else {
            test_config.addOption([]const u8, "worker_signal_fixture", "");
        }
        if (worker_address_space_fixture) |fixture| {
            test_config.addOptionPath("worker_address_space_fixture", fixture.getEmittedBin());
        } else {
            test_config.addOption([]const u8, "worker_address_space_fixture", "");
        }
        test_mod.addOptions("test_config", test_config);
        const unit_tests = b.addTest(.{ .root_module = test_mod });
        check_step.dependOn(&unit_tests.step);
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // Lock the downstream contract for consumers that inspect only
    // `mruby.features`: libmruby's C objects must still receive the Zig-side
    // allocator export even when no runtime API declaration is referenced.
    const features_only_mod = b.createModule(.{
        .root_source_file = b.path("tools/features_only_consumer.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    features_only_mod.addImport("mruby", mruby_mod);
    const features_only_consumer = b.addExecutable(.{
        .name = "features-only-consumer",
        .root_module = features_only_mod,
    });
    check_step.dependOn(&features_only_consumer.step);
    const run_features_only_consumer = b.addRunArtifact(features_only_consumer);
    test_step.dependOn(&run_features_only_consumer.step);

    if (worker_mod_for_tests) |worker_mod| {
        const worker_tests = b.addTest(.{ .root_module = worker_mod });
        check_step.dependOn(&worker_tests.step);
        const run_worker_tests = b.addRunArtifact(worker_tests);
        test_step.dependOn(&run_worker_tests.step);
    }
    if (worker_sigchld_fixture) |fixture| {
        const run_sigchld_fixture = b.addRunArtifact(fixture);
        test_step.dependOn(&run_sigchld_fixture.step);
    }

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

    // The authority module is imported as a data dependency elsewhere, which
    // does not collect its own test declarations. Keep its fail-closed set and
    // duplicate-inventory checks as an explicit test root.
    const authority_tests_mod = b.createModule(.{
        .root_source_file = b.path("build/authority.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const authority_tests = b.addTest(.{ .root_module = authority_tests_mod });
    check_step.dependOn(&authority_tests.step);
    const run_authority_tests = b.addRunArtifact(authority_tests);
    test_step.dependOn(&run_authority_tests.step);

    // Pure StateCapsule parser fuzz target. A normal `zig build test` runs the
    // stable corpus once; `zig build fuzz-state-capsule --fuzz=100K` enables
    // Zig's coverage-guided engine. The callback never creates an mruby VM.
    const state_capsule_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/state_capsule_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
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

    // C materialization fuzz target: the same inputs driven through
    // Isolate.importValue inside a live, memory-capped isolate.
    const state_materialize_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/state_materialize_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    state_materialize_fuzz_mod.addImport("mruby", mruby_mod);
    const state_materialize_fuzz_tests = b.addTest(.{ .root_module = state_materialize_fuzz_mod });
    check_step.dependOn(&state_materialize_fuzz_tests.step);
    const run_state_materialize_fuzz_tests = b.addRunArtifact(state_materialize_fuzz_tests);
    test_step.dependOn(&run_state_materialize_fuzz_tests.step);
    const fuzz_state_materialize_step = b.step(
        "fuzz-state-materialize",
        "fuzz StateCapsule admission and C materialization through a live isolate",
    );
    fuzz_state_materialize_step.dependOn(&run_state_materialize_fuzz_tests.step);

    if (!no_compiler) {
        // The integration suite above roots at src/tests.zig and pulls in the
        // library as an imported module, so Zig never collects the `test` blocks
        // that live *inside* the mruby module (src/convert.zig, src/alloc.zig,
        // ...). Run those with the module itself as the test root; src/mruby.zig's
        // aggregator (`_ = @import(...)`) reaches every test-bearing file.
        const mod_tests = b.addTest(.{ .root_module = mruby_mod });
        check_step.dependOn(&mod_tests.step);
        const run_mod_tests = b.addRunArtifact(mod_tests);
        test_step.dependOn(&run_mod_tests.step);
    }

    // Preserve compiler-independent module coverage when the source-driven
    // mruby module test root is excluded from a runtime-only build.
    if (no_compiler) {
        for ([_][]const u8{ "src/artifact.zig", "src/alloc.zig" }) |path| {
            const pure_mod = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
                .sanitize_c = sanitize_c,
                .link_libc = true,
            });
            pure_mod.addOptions("allocator_config", allocator_config);
            const pure_tests = b.addTest(.{ .root_module = pure_mod });
            check_step.dependOn(&pure_tests.step);
            const run_pure_tests = b.addRunArtifact(pure_tests);
            test_step.dependOn(&run_pure_tests.step);
        }
    }

    const worker_protocol_tests = b.addTest(.{ .root_module = worker_protocol_mod });
    check_step.dependOn(&worker_protocol_tests.step);
    const run_worker_protocol_tests = b.addRunArtifact(worker_protocol_tests);
    test_step.dependOn(&run_worker_protocol_tests.step);

    if (!no_compiler) {
        // A real producer and consumer executable exchange the encoded capsule
        // through captured stdout/stdin. They are separately linked OS processes;
        // the consumer restores into a new Isolate and checks the complete graph.
        const capsule_producer_mod = b.createModule(.{
            .root_source_file = b.path("tools/state_capsule_process_producer.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
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
            .sanitize_c = sanitize_c,
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
    } else {
        unsupportedCompilerStep(b, "test-state-capsule-process", "transfer a source-produced StateCapsule between processes");
    }

    if (!no_compiler) {
        // Examples.
        const ex_names = [_][]const u8{ "quickstart", "host_functions", "exceptions", "sandbox" };
        for (ex_names) |ex_name| {
            const ex_mod = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{ex_name})),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
                .sanitize_c = sanitize_c,
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
    } else {
        for ([_][]const u8{ "quickstart", "host_functions", "exceptions", "sandbox" }) |name| {
            unsupportedCompilerStep(b, b.fmt("run-{s}", .{name}), b.fmt("run the {s} example", .{name}));
        }
    }

    // Share configured host tools with downstream build scripts. Named lazy
    // paths do not install host executables into the target deployment.
    const artifact_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/artifact.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const rite_envelope = hostTool(b, "tools/rite_envelope.zig");
    const codedb_graph_mod = b.createModule(.{
        .root_source_file = b.path("build/codedb_graph.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    rite_envelope.root_module.addImport("artifact", artifact_lib_mod);
    rite_envelope.root_module.addImport("artifact_config", artifact_config);
    rite_envelope.root_module.addImport("codedb_graph", codedb_graph_mod);
    const codedb_authority_mod = b.createModule(.{
        .root_source_file = b.path("build/authority.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    rite_envelope.root_module.addImport("authority_manifest", codedb_authority_mod);
    const codedb_features = b.addOptions();
    codedb_features.addOption([]const []const u8, "authority_source_names", authority_source_names.items);
    codedb_features.addOption([]const u16, "authority_source_bits", authority_source_bits.items);
    codedb_features.addOption([]const u8, "gem_set", gem_set);
    var codedb_gems: std.ArrayList([]const u8) = .empty;
    for (selected_gems) |gem| try codedb_gems.append(arena, gem.name);
    codedb_features.addOption([]const []const u8, "gems", codedb_gems.items);
    const codedb_features_mod = codedb_features.createModule();
    rite_envelope.root_module.addImport("codedb_features", codedb_features_mod);
    b.addNamedLazyPath("codedb-mrbc", mrbc.getEmittedBin());
    b.addNamedLazyPath("codedb-envelope", rite_envelope.getEmittedBin());
    const codedb_tools: CodeDB.Tools = .{
        .mrbc = mrbc.getEmittedBin(),
        .envelope = rite_envelope.getEmittedBin(),
    };
    // Package examples/tests must work with every selectable linked profile.
    // Applications default to the stricter worker tier in addCodeDB.
    const codedb_bundle = try CodeDB.add(b, codedb_tools, .{ .tier = .trusted, .sources = &.{
        .{ .name = "accumulate", .source = b.path("examples/codedb/accumulate.rb") },
        .{ .name = "dispatch", .source = b.path("examples/codedb/dispatch.rb") },
        .{ .name = "invoice", .source = b.path("examples/codedb/invoice.rb"), .source_name = "billing/invoice.rb", .dependencies = &.{"billing"}, .entrypoint = false },
        .{ .name = "billing", .source = b.path("examples/codedb/billing.rb"), .dependencies = &.{"discounts"} },
        .{ .name = "discounts", .source = b.path("examples/codedb/discounts.rb"), .entrypoint = false },
    } });
    const codedb_demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/codedb_demo.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    codedb_demo_mod.addImport("mruby", mruby_mod);
    codedb_demo_mod.addImport("codedb_manifest", codedb_bundle.manifest);
    const codedb_demo = b.addExecutable(.{ .name = "codedb-demo", .root_module = codedb_demo_mod });
    check_step.dependOn(&codedb_demo.step);
    b.installArtifact(codedb_demo);
    const run_codedb_demo = b.addRunArtifact(codedb_demo);
    const codedb_step = b.step("run-codedb-demo", "run the CodeDB build-time compilation demo");
    codedb_step.dependOn(&run_codedb_demo.step);
    const codedb_test_step = b.step("test-codedb", "test CodeDB generation, metadata, and policy admission");
    if (!no_compiler) {
        var test_sources: std.ArrayList(CodeDB.Source) = .empty;
        for ([_][]const u8{ "answer", "source", "trace", "loop" }) |name| {
            try test_sources.append(arena, .{
                .name = name,
                .source = b.path(b.fmt("src/tests_codedb/{s}.rb", .{name})),
                .source_name = b.fmt("tests/{s}.rb", .{name}),
            });
        }
        const test_bundle = try CodeDB.add(b, codedb_tools, .{ .tier = .trusted, .sources = test_sources.items });
        const app_bundle = try CodeDB.add(b, codedb_tools, .{ .tier = .trusted, .sources = &.{.{
            .name = "answer",
            .source = b.path("src/tests_codedb/answer.rb"),
            .source_name = "tests/answer.rb",
            .application = @splat(0x42),
        }} });
        const graph_definitions = [_]struct { name: []const u8, dependencies: []const []const u8 = &.{}, entrypoint: bool = false }{
            .{ .name = "main", .dependencies = &.{ "right", "left" }, .entrypoint = true },
            .{ .name = "left", .dependencies = &.{"base"} },
            .{ .name = "right", .dependencies = &.{"base"} },
            .{ .name = "base" },
            .{ .name = "secondary", .dependencies = &.{"base"}, .entrypoint = true },
            .{ .name = "unused" },
            .{ .name = "failure", .dependencies = &.{"base"} },
            .{ .name = "failed_root", .dependencies = &.{"failure"}, .entrypoint = true },
            .{ .name = "gas_base" },
            .{ .name = "gas_main", .dependencies = &.{"gas_base"}, .entrypoint = true },
            .{ .name = "gate", .entrypoint = true },
        };
        var graph_sources: std.ArrayList(CodeDB.Source) = .empty;
        for (graph_definitions) |definition| try graph_sources.append(arena, .{
            .name = definition.name,
            .source = b.path(b.fmt("src/tests_codedb/graph_{s}.rb", .{definition.name})),
            .source_name = b.fmt("graph/{s}.rb", .{definition.name}),
            .dependencies = definition.dependencies,
            .entrypoint = definition.entrypoint,
            .host_bindings = if (std.mem.eql(u8, definition.name, "gate")) &.{"CodeDBGate.call"} else &.{},
        });
        const graph_bundle = try CodeDB.add(b, codedb_tools, .{
            .tier = .trusted,
            .sources = graph_sources.items,
            // This test callback only coordinates admission/termination; it exposes
            // no host assets or arbitrary native operation to Ruby.
            .host_bindings = &.{.{ .name = "CodeDBGate.call", .authority = .empty }},
        });
        const other_graph_bundle = try CodeDB.add(b, codedb_tools, .{ .tier = .trusted, .sources = &.{.{
            .name = "main",
            .source = b.path("src/tests_codedb/answer.rb"),
        }} });
        const codedb_tests_mod = b.createModule(.{
            .root_source_file = b.path("src/codedb_tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        codedb_tests_mod.addImport("mruby", mruby_mod);
        codedb_tests_mod.addImport("codedb_manifest", test_bundle.manifest);
        codedb_tests_mod.addImport("codedb_app_manifest", app_bundle.manifest);
        codedb_tests_mod.addImport("codedb_graph_manifest", graph_bundle.manifest);
        codedb_tests_mod.addImport("codedb_graph_other_manifest", other_graph_bundle.manifest);
        const codedb_tests = b.addTest(.{ .root_module = codedb_tests_mod });
        check_step.dependOn(&codedb_tests.step);
        const run_codedb_tests = b.addRunArtifact(codedb_tests);
        codedb_test_step.dependOn(&run_codedb_tests.step);
    }

    var runtime_sources: std.ArrayList(CodeDB.Source) = .empty;
    for ([_][]const u8{ "answer", "loop", "random", "reseed", "eval", "init", "job", "depth", "memory", "ensure_loop", "input", "raise" }) |name| {
        try runtime_sources.append(arena, .{
            .name = name,
            .source = b.path(b.fmt("src/tests_runtime_only/{s}.rb", .{name})),
            .source_name = b.fmt("runtime/{s}.rb", .{name}),
            .entrypoint = !std.mem.eql(u8, name, "init"),
            .dependencies = if (std.mem.eql(u8, name, "job")) &.{"init"} else &.{},
        });
    }
    const runtime_bundle = try CodeDB.add(b, codedb_tools, .{ .tier = .trusted, .sources = runtime_sources.items });
    const runtime_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime_only_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    runtime_tests_mod.addImport("mruby", mruby_mod);
    runtime_tests_mod.addImport("codedb_runtime_manifest", runtime_bundle.manifest);
    const runtime_config = b.addOptions();
    runtime_config.addOption(bool, "expected_no_compiler", no_compiler);
    if (worker_executable) |executable| {
        runtime_config.addOptionPath("worker_executable", executable.getEmittedBin());
    } else {
        runtime_config.addOption([]const u8, "worker_executable", "");
    }
    runtime_tests_mod.addOptions("runtime_only_config", runtime_config);
    const runtime_tests = b.addTest(.{ .root_module = runtime_tests_mod });
    check_step.dependOn(&runtime_tests.step);
    const run_runtime_tests = b.addRunArtifact(runtime_tests);
    const runtime_test_step = b.step("test-runtime-only", "test artifact-only execution with the selected compiler profile");
    runtime_test_step.dependOn(&run_runtime_tests.step);
    codedb_test_step.dependOn(runtime_test_step);
    codedb_test_step.dependOn(&run_codedb_demo.step);
    test_step.dependOn(codedb_test_step);

    const envelope_tests_mod = b.createModule(.{
        .root_source_file = b.path("tools/rite_envelope.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    envelope_tests_mod.addImport("artifact", artifact_lib_mod);
    envelope_tests_mod.addImport("artifact_config", artifact_config);
    envelope_tests_mod.addImport("codedb_graph", codedb_graph_mod);
    envelope_tests_mod.addImport("authority_manifest", codedb_authority_mod);
    envelope_tests_mod.addImport("codedb_features", codedb_features_mod);
    const envelope_tests = b.addTest(.{ .root_module = envelope_tests_mod });
    check_step.dependOn(&envelope_tests.step);
    const run_envelope_tests = b.addRunArtifact(envelope_tests);
    codedb_test_step.dependOn(&run_envelope_tests.step);

    const codedb_build_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("build/codedb.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    check_step.dependOn(&codedb_build_tests.step);
    const run_codedb_build_tests = b.addRunArtifact(codedb_build_tests);
    codedb_test_step.dependOn(&run_codedb_build_tests.step);

    const graph_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("build/codedb_graph.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    check_step.dependOn(&graph_tests.step);
    const run_graph_tests = b.addRunArtifact(graph_tests);
    codedb_test_step.dependOn(&run_graph_tests.step);

    const codedb_authority_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("build/codedb_authority.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    check_step.dependOn(&codedb_authority_tests.step);
    const run_codedb_authority_tests = b.addRunArtifact(codedb_authority_tests);
    codedb_test_step.dependOn(&run_codedb_authority_tests.step);

    if (!no_compiler) {
        // Benchmarks.
        const bench_mod = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        bench_mod.addImport("mruby", mruby_mod);
        const bench = b.addExecutable(.{ .name = "mruby-bench", .root_module = bench_mod });
        check_step.dependOn(&bench.step);
        b.installArtifact(bench);
        const run_bench_cmd = b.addRunArtifact(bench);
        run_bench_cmd.step.dependOn(b.getInstallStep());
        const bench_step = b.step("run-bench", "run the runtime benchmarks");
        bench_step.dependOn(&run_bench_cmd.step);
    } else {
        unsupportedCompilerStep(b, "run-bench", "run source-driven runtime benchmarks");
    }
}

// --------------------------------------------------------------------------
// helpers

fn unsupportedCompilerStep(b: *std.Build, name: []const u8, description: []const u8) void {
    const step = b.step(name, description);
    const failure = b.addFail(b.fmt("{s} requires the target Ruby compiler; omit -Dno-compiler", .{name}));
    step.dependOn(&failure.step);
}

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
    no_compiler: bool,
) !*std.Build.Module {
    const pointer_bits = target.ptrBitWidth();
    if (pointer_bits != 32 and pointer_bits != 64) {
        std.debug.panic("mruby RITE identity does not support {d}-bit pointers", .{pointer_bits});
    }

    var semantic_defines: std.ArrayList([]const u8) = .empty;
    try semantic_defines.append(arena, "MRB_USE_DEBUG_HOOK");
    if (no_compiler) try semantic_defines.append(arena, "MRZ_NO_COMPILER");
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
    no_compiler: bool,
) ![]const gems_mod.Gem {
    var failure: gems_mod.SelectionFailure = .{};
    return gems_mod.select(arena, .{
        .gem_set = gem_set,
        .with = with,
        .without = without,
        .no_compiler = no_compiler,
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
            .compiler_required => std.debug.print(
                "error: -Dwith-gems={s} requires compiler-dependent gem {s}, incompatible with -Dno-compiler\n",
                .{ failure.dependent, failure.name },
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

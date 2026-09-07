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

/// Compile a dedicated strict worker with one embedded CodeDB bundle and
/// descriptor module (`pub const operations = ...`). The caller installs the
/// returned artifact and passes its explicit path to strict.Worker.
pub const EffectWorkerOptions = struct {
    name: []const u8,
    manifest: *std.Build.Module,
    contract: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
    root_source_file: ?std.Build.LazyPath = null,
    sanitize_thread: bool = false,
    sanitize_c: ?std.zig.SanitizeC = null,
};

pub fn addEffectWorker(b: *std.Build, dependency: *std.Build.Dependency, options: EffectWorkerOptions) *std.Build.Step.Compile {
    return effectWorker(b, dependency.module("mruby"), options.root_source_file orelse dependency.path("tools/effects_worker.zig"), options);
}

fn effectWorker(b: *std.Build, mruby_mod: *std.Build.Module, wrapper: std.Build.LazyPath, options: EffectWorkerOptions) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = wrapper,
        .target = options.target,
        .optimize = options.optimize,
        .sanitize_thread = options.sanitize_thread,
        .sanitize_c = options.sanitize_c,
    });
    module.addImport("mruby", mruby_mod);
    module.addImport("worker_manifest", options.manifest);
    module.addImport("worker_contract", options.contract);
    return b.addExecutable(.{ .name = options.name, .root_module = module });
}

/// The durable example's build-time-known application table: one applications
/// module per host variant, wired to the bundles and contracts that variant
/// knows. The identity-fixture host swaps only the first contract.
fn durableApplicationsModule(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    manifest_v1: *std.Build.Module,
    manifest_v2: *std.Build.Module,
    contract_v1: *std.Build.Module,
    contract_v2: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("examples/durable/applications.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    module.addImport("mruby", mruby_mod);
    module.addImport("durable_manifest_v1", manifest_v1);
    module.addImport("durable_manifest_v2", manifest_v2);
    module.addImport("durable_contract_v1", contract_v1);
    module.addImport("durable_contract_v2", contract_v2);
    return module;
}

fn durableHostModule(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    applications: *std.Build.Module,
    contract: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    sqlite: *std.Build.Dependency,
) *std.Build.Module {
    const host_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    host_module.addImport("mruby", mruby_mod);
    host_module.addImport("durable_applications", applications);
    host_module.addImport("durable_contract", contract);
    host_module.addIncludePath(sqlite.path(""));
    host_module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0", "-w" },
    });
    host_module.addCSourceFile(.{
        .file = b.path("examples/durable/sql_identity.c"),
        .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
    });
    return host_module;
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
const integer64_flags: []const []const u8 = &.{ "-DMRB_NO_FLOAT", "-DMRB_INT64", "-DMRZ_INTEGER_ONLY=1" };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const effects_strict = b.option(bool, "effects-strict", "use the strict effects runtime (minimal, without runtime compiler)") orelse false;
    const effects_integer64 = b.option(bool, "effects-integer64", "use signed 64-bit integer arithmetic without Float in the strict effects runtime") orelse false;
    if (effects_integer64 and (!effects_strict or target.result.ptrBitWidth() != 64)) {
        std.debug.print("error: -Deffects-integer64=true requires -Deffects-strict=true and a 64-bit target\n", .{});
        return error.InvalidIntegerEffectsProfile;
    }
    const numeric_flags: []const []const u8 = if (effects_integer64) integer64_flags else &.{};
    const explicit_no_compiler = b.option(bool, "no-compiler", "omit the target Ruby parser/code generator; retain build-time mrbc");
    const no_compiler = explicit_no_compiler orelse effects_strict;
    if (effects_strict and !no_compiler) {
        std.debug.print("error: -Deffects-strict=true requires -Dno-compiler=true\n", .{});
        return error.StrictEffectsRequiresNoCompiler;
    }
    const sqlite_effects = b.option(bool, "sqlite-effects", "build optional SQLite inventory and durable effects examples") orelse false;
    const sanitize_thread = b.option(bool, "sanitize-thread", "enable ThreadSanitizer") orelse false;
    const sanitize_c = if (b.option(bool, "sanitize-c", "enable C undefined-behavior detection in unsafe builds") orelse false)
        std.zig.SanitizeC.full
    else
        null;
    const worker_target_supported = switch (target.result.os.tag) {
        .linux, .macos => target.result.ptrBitWidth() == 64,
        else => false,
    };

    const effects_worker_supported = effects_strict and
        (target.result.os.tag == .linux or target.result.os.tag == .macos) and
        (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64);

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
    const gem_set = explicit_gem_set orelse legacy_gem_set orelse if (effects_strict) "minimal" else "standard";
    const with_gems = b.option([]const u8, "with-gems", "comma-separated extra gems to enable on top of the gem set");
    const without_gems = b.option([]const u8, "without-gems", "comma-separated gems to remove from the gem set");
    const allow_worker_ambient_authority = b.option(
        bool,
        "allow-worker-ambient-authority",
        "build the generic worker even when linked gems expose host-access authority",
    ) orelse false;
    if (effects_strict and (!std.mem.eql(u8, gem_set, "minimal") or
        (with_gems != null and std.mem.trim(u8, with_gems.?, " ,").len != 0) or allow_worker_ambient_authority))
    {
        std.debug.print("error: -Deffects-strict=true requires the minimal gem set, no additional gems, and no ambient worker authority\n", .{});
        return error.InvalidStrictEffectsProfile;
    }

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
        worker_target_supported and !effects_strict,
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
    const strict_sources = if (effects_strict) try patchMrubyStrict(b, root, patched_hash) else null;
    const integer_host_sources: []const PatchedHostSource = if (effects_integer64)
        try patchIntegerHostSources(b, root, strict_sources.?.tool)
    else
        &.{};

    // ============================= stage 1 =================================
    // Presym headers for the host mrbc build: scan core (with allocf.c),
    // compiler, and the mrbc tool itself.
    const host_triple = try b.graph.host.result.zigTriple(arena);

    var mrbc_scan: std.ArrayList(ScanInput) = .empty;
    for (sources.core_srcs) |path| {
        try mrbc_scan.append(arena, .{
            .lp = patchedHostSource(integer_host_sources, path) orelse try root.join(arena, path),
            .pp_name = try std.fmt.allocPrint(arena, "core_{s}", .{try mangle(arena, path, &.{ "c", "pp" })}),
        });
    }
    try mrbc_scan.append(arena, .{ .lp = try root.join(arena, sources.allocf_src), .pp_name = "core_allocf.c.pp" });
    for (sources.compiler_srcs) |path| {
        const patched_source = patchedHostSource(integer_host_sources, path);
        try mrbc_scan.append(arena, .{
            .lp = patched_source orelse try root.join(arena, path),
            .pp_name = try std.fmt.allocPrint(arena, "compiler_{s}", .{try mangle(arena, path, &.{ "c", "pp" })}),
            .includes = if (patched_source != null) &.{"mrbgems/mruby-compiler/core"} else &.{},
        });
    }
    try addTreeFiles(arena, &mrbc_scan, root, &sources.mrbc_srcs, "mrbc");

    const mrbc_presym_dir = try presymHeaders(b, presym_gen, arena, mrbc_scan.items, numeric_flags, root, host_triple, &.{});

    // ============================= stage 2 =================================
    const mrbc_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    var mrbc_files: std.ArrayList([]const u8) = .empty;
    for (sources.core_srcs) |path| {
        if (patchedHostSource(integer_host_sources, path) != null) continue;
        try mrbc_files.append(arena, path);
    }
    try mrbc_files.append(arena, sources.allocf_src);
    for (sources.compiler_srcs) |path| {
        if (patchedHostSource(integer_host_sources, path) != null) continue;
        try mrbc_files.append(arena, path);
    }
    try mrbc_files.appendSlice(arena, &sources.mrbc_srcs);
    var mrbc_flags: std.ArrayList([]const u8) = .empty;
    try mrbc_flags.append(arena, "-w");
    try mrbc_flags.appendSlice(arena, portable_container_flags);
    try mrbc_flags.appendSlice(arena, numeric_flags);
    mrbc_mod.addCSourceFiles(.{
        .root = root,
        .files = mrbc_files.items,
        .flags = mrbc_flags.items,
    });
    for (integer_host_sources) |source| mrbc_mod.addCSourceFile(.{ .file = source.file, .flags = mrbc_flags.items });
    if (integer_host_sources.len != 0) mrbc_mod.addIncludePath(root.path(b, "mrbgems/mruby-compiler/core"));
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
    for (sources.core_srcs, 0..) |path, index| {
        if (strict_sources) |strict| {
            try lib_scan.append(arena, .{
                .lp = strict.core[index],
                .pp_name = try std.fmt.allocPrint(arena, "strict_{s}", .{try mangle(arena, path, &.{ "c", "pp" })}),
            });
        } else if (std.mem.eql(u8, path, "src/hash.c")) {
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
    if (effects_strict) try lib_scan.append(arena, .{ .lp = b.path("src/strict_native.c"), .pp_name = "strict_native.c.pp" });
    for (generated_c.items) |g| try lib_scan.append(arena, .{ .lp = g.lp, .pp_name = g.pp_name });

    // Keep the presym scan consistent with the compile-time defines.
    const lib_scan_defines = defines: {
        var d: std.ArrayList([]const u8) = .empty;
        try d.appendSlice(arena, gem_defines.items);
        try d.append(arena, "-DMRB_USE_DEBUG_HOOK");
        if (no_compiler) try d.append(arena, "-DMRZ_NO_COMPILER");
        if (effects_strict) try d.appendSlice(arena, &.{ "-DMRZ_EFFECTS_STRICT=1", "-DMRB_NO_STDIO" });
        try d.appendSlice(arena, numeric_flags);
        try d.appendSlice(arena, portable_container_flags);
        try d.appendSlice(arena, ro_data_flags);
        break :defines d.items;
    };
    const strict_include_dirs: []const std.Build.LazyPath = if (strict_sources) |strict| &.{ strict.include, b.path("src"), root.path(b, "src") } else &.{};
    const lib_presym_dir = try presymHeaders(b, presym_gen, arena, lib_scan.items, lib_scan_defines, root, triple, strict_include_dirs);

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
        if (effects_strict) try f.appendSlice(arena, &.{ "-DMRZ_EFFECTS_STRICT=1", "-DMRB_NO_STDIO" });
        try f.appendSlice(arena, numeric_flags);
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
        if (effects_strict) try f.appendSlice(arena, &.{ "-DMRZ_EFFECTS_STRICT=1", "-DMRB_NO_STDIO" });
        try f.appendSlice(arena, numeric_flags);
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
        effects_strict,
        effects_integer64,
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
        build_features.addOption(bool, "effects_strict", effects_strict);
        build_features.addOption(bool, "effects_integer64", effects_integer64);
        build_features.addOption(bool, "effects_worker_supported", effects_worker_supported);
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
        if (!effects_strict and !std.mem.eql(u8, path, "src/hash.c")) try lib_files.append(arena, path);
    }
    if (!no_compiler) try lib_files.appendSlice(arena, &sources.compiler_srcs);
    for (selected_gems) |g| try lib_files.appendSlice(arena, g.c_srcs);
    mruby_mod.addCSourceFiles(.{ .root = root, .files = lib_files.items, .flags = lib_flags });
    if (strict_sources) |strict| {
        for (strict.core) |source| mruby_mod.addCSourceFile(.{ .file = source, .flags = lib_flags });
        mruby_mod.addCSourceFile(.{ .file = b.path("src/strict_native.c"), .flags = lib_flags });
    } else {
        mruby_mod.addCSourceFile(.{ .file = patched_hash, .flags = lib_flags });
    }
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
    if (effects_worker_supported) mruby_mod.addCSourceFile(.{
        .file = b.path("src/effect_worker_process.c"),
        .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
    });
    for (strict_include_dirs) |dir| mruby_mod.addIncludePath(dir);
    mruby_mod.addIncludePath(try root.join(arena, "include"));
    mruby_mod.addIncludePath(lib_presym_dir);
    for (gem_include_dirs.items) |dir| mruby_mod.addIncludePath(dir);

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

    if (!effects_strict) integer64Unavailable(b, "integer effects requires -Deffects-strict=true -Deffects-integer64=true");
    if (effects_strict) {
        try buildStrict(b, mruby_mod, codedb_tools, target, optimize, sanitize_thread, sanitize_c, sqlite_effects, effects_worker_supported, effects_integer64);
        return;
    }

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

    // Use the runtime operation catalogue for CodeDB's host authority metadata
    // as well, so the demo cannot silently describe different operations.
    const effect_contract = @import("examples/effects/contract.zig");
    var effect_hosts: [effect_contract.operations.len]CodeDB.HostBinding = undefined;
    var effect_names: [effect_contract.operations.len][]const u8 = undefined;
    inline for (effect_contract.operations, 0..) |operation, i| {
        effect_hosts[i] = .{
            .name = operation.name,
            .authority = CodeDB.AuthoritySet.fromBits(operation.authority_bits),
        };
        effect_names[i] = operation.name;
    }
    const effects_bundle = try CodeDB.add(b, codedb_tools, .{
        .tier = .trusted,
        .host_bindings = &effect_hosts,
        .sources = &.{.{
            .name = "announce",
            .source = b.path("examples/effects/announce.rb"),
            .source_name = "effects/announce.rb",
            .host_bindings = &effect_names,
        }},
    });
    const effects_demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/effects_demo.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    effects_demo_mod.addImport("mruby", mruby_mod);
    effects_demo_mod.addImport("effects_manifest", effects_bundle.manifest);
    const effects_demo = b.addExecutable(.{ .name = "effects-demo", .root_module = effects_demo_mod });
    check_step.dependOn(&effects_demo.step);
    b.installArtifact(effects_demo);
    const run_effects_demo = b.addRunArtifact(effects_demo);
    const effects_demo_step = b.step("run-effects-demo", "run explicit effects with live, fixed, recording, and replay adapters");
    effects_demo_step.dependOn(&run_effects_demo.step);
    const effects_test_step = b.step("test-effects", "test explicit effect enforcement and record/replay");
    addEffectDataTests(b, mruby_mod, target, optimize, sanitize_thread, sanitize_c, check_step, effects_test_step);
    addEffectInspector(b, mruby_mod, target, optimize, sanitize_thread, sanitize_c, check_step, effects_test_step);
    addEffectSchemaTests(b, mruby_mod, target, optimize, sanitize_thread, sanitize_c, check_step, effects_test_step);
    effects_test_step.dependOn(&run_effects_demo.step);
    const effect_trace_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/effect_trace.zig"),
        .target = target,
        .optimize = optimize,
    });
    const effect_trace_tests = b.addTest(.{ .root_module = effect_trace_tests_mod });
    check_step.dependOn(&effect_trace_tests.step);
    const run_effect_trace_tests = b.addRunArtifact(effect_trace_tests);
    effects_test_step.dependOn(&run_effect_trace_tests.step);
    const effect_invocation_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/effect_invocation.zig"),
        .target = target,
        .optimize = optimize,
    });
    const effect_invocation_tests = b.addTest(.{ .root_module = effect_invocation_tests_mod });
    check_step.dependOn(&effect_invocation_tests.step);
    const run_effect_invocation_tests = b.addRunArtifact(effect_invocation_tests);
    effects_test_step.dependOn(&run_effect_invocation_tests.step);
    if (!no_compiler) {
        const effects_tests_mod = b.createModule(.{
            .root_source_file = b.path("src/effect_tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        effects_tests_mod.addImport("mruby", mruby_mod);
        const effects_tests = b.addTest(.{ .root_module = effects_tests_mod });
        check_step.dependOn(&effects_tests.step);
        const run_effects_tests = b.addRunArtifact(effects_tests);
        effects_test_step.dependOn(&run_effects_tests.step);
    }
    test_step.dependOn(effects_test_step);

    _ = try addInventoryExample(b, mruby_mod, codedb_tools, target, optimize, sanitize_thread, sanitize_c, check_step, sqlite_effects);
    const strict_turn_required = b.addFail("strict turn example requires -Deffects-strict=true");
    b.step("run-effects-turn", "run the fresh strict turn example (requires -Deffects-strict=true)").dependOn(&strict_turn_required.step);
    b.step("test-effects-turn", "test fresh strict turns (requires -Deffects-strict=true)").dependOn(&strict_turn_required.step);
    b.step("run-effects-worker", "run brokered strict effects (requires -Deffects-strict=true)").dependOn(&strict_turn_required.step);
    b.step("test-effects-worker", "test brokered strict effects (requires -Deffects-strict=true)").dependOn(&strict_turn_required.step);
    b.step("run-effects-reservation", "run typed domain effects (requires -Deffects-strict=true)").dependOn(&strict_turn_required.step);
    b.step("test-effects-reservation", "test typed domain effects (requires -Deffects-strict=true)").dependOn(&strict_turn_required.step);
    const durable_required = b.addFail("durable example requires -Deffects-strict=true -Dsqlite-effects=true");
    b.step("run-effects-durable", "run durable strict effects (requires -Deffects-strict=true -Dsqlite-effects=true)").dependOn(&durable_required.step);
    b.step("test-effects-durable", "test durable strict effects (requires -Deffects-strict=true -Dsqlite-effects=true)").dependOn(&durable_required.step);

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

    // A test-only observer gates the same worker execution path while an
    // independent supervisor kills its controller and observes worker exit.
    // The installed helper keeps the no-op observer and no fixture C code.
    if (worker_mod_for_tests) |worker_mod| {
        const orphan_fixture_mod = b.createModule(.{
            .root_source_file = b.path("tools/worker_orphan_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        orphan_fixture_mod.addImport("worker_entry", worker_mod);
        orphan_fixture_mod.addCSourceFile(.{
            .file = b.path("tools/worker_orphan_fixture.c"),
            .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
        });
        const orphan_fixture = b.addExecutable(.{
            .name = "worker-orphan-fixture",
            .root_module = orphan_fixture_mod,
        });
        check_step.dependOn(&orphan_fixture.step);
        const orphan_config = b.addOptions();
        orphan_config.addOptionPath("fixture_executable", orphan_fixture.getEmittedBin());
        const orphan_bundle = try CodeDB.add(b, codedb_tools, .{
            .tier = .trusted,
            .sources = &.{
                .{ .name = "loop", .source = b.path("tools/worker_orphan_fixture_loop.rb") },
                .{ .name = "response", .source = b.path("tools/worker_orphan_fixture_response.rb") },
            },
        });
        const orphan_tests_mod = b.createModule(.{
            .root_source_file = b.path("src/worker_orphan_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        orphan_tests_mod.addImport("mruby", mruby_mod);
        orphan_tests_mod.addImport("worker_protocol", worker_protocol_mod);
        orphan_tests_mod.addImport("codedb_orphan_manifest", orphan_bundle.manifest);
        orphan_tests_mod.addOptions("worker_orphan_config", orphan_config);
        orphan_tests_mod.addCSourceFile(.{
            .file = b.path("tools/worker_orphan_fixture.c"),
            .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
        });
        const orphan_tests = b.addTest(.{ .root_module = orphan_tests_mod });
        check_step.dependOn(&orphan_tests.step);
        const run_orphan_tests = b.addRunArtifact(orphan_tests);
        const orphan_step = b.step("test-worker-orphan", "test worker exit after its controller is killed");
        orphan_step.dependOn(&run_orphan_tests.step);
        test_step.dependOn(orphan_step);
        runtime_test_step.dependOn(orphan_step);
    }

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

fn buildStrict(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    codedb_tools: CodeDB.Tools,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    sqlite_effects: bool,
    effects_worker_supported: bool,
    effects_integer64: bool,
) !void {
    const check_step = b.step("check", "compile strict effects tests and examples");
    const test_step = b.step("test", "run strict effects tests for the selected profile");
    const strict_step = b.step("test-effects-strict", "verify strict bootstrap, native admission, and identified effects");
    test_step.dependOn(strict_step);
    b.step("test-effects", "verify strict effects execution").dependOn(strict_step);
    addEffectDataTests(b, mruby_mod, target, optimize, sanitize_thread, sanitize_c, check_step, strict_step);
    addEffectInspector(b, mruby_mod, target, optimize, sanitize_thread, sanitize_c, check_step, strict_step);
    addEffectSchemaTests(b, mruby_mod, target, optimize, sanitize_thread, sanitize_c, check_step, strict_step);
    if (effects_integer64 and effects_worker_supported) {
        try addInteger64Example(b, mruby_mod, codedb_tools, target, optimize, sanitize_thread, sanitize_c, check_step, strict_step);
    } else {
        integer64Unavailable(b, "integer effects requires -Deffects-strict=true -Deffects-integer64=true on Linux/macOS x86_64 or aarch64");
    }

    const fixture_hosts = [_]CodeDB.HostBinding{
        .{ .name = "clock.now", .authority = CodeDB.AuthoritySet.fromBits(1 << 4) },
        .{ .name = "sink.write", .authority = CodeDB.AuthoritySet.fromBits(1 << 13) },
    };
    var fixture_sources: std.ArrayList(CodeDB.Source) = .empty;
    for ([_][]const u8{ "app", "bad_init", "loop_init", "identity_init", "native_alias", "integer_boundaries" }) |name| {
        try fixture_sources.append(b.allocator, .{
            .name = name,
            .source = b.path(b.fmt("src/tests_strict/{s}.rb", .{name})),
            .source_name = b.fmt("strict/{s}.rb", .{name}),
            .host_bindings = &.{ "clock.now", "sink.write" },
        });
    }
    const fixtures = try CodeDB.add(b, codedb_tools, .{
        .tier = .trusted,
        .host_bindings = &fixture_hosts,
        .sources = fixture_sources.items,
    });
    for ([_][]const u8{ "src/strict_tests.zig", "src/strict_integer_regression_tests.zig" }) |path| {
        const strict_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        strict_mod.addImport("mruby", mruby_mod);
        strict_mod.addImport("strict_manifest", fixtures.manifest);
        const strict_tests = b.addTest(.{ .root_module = strict_mod });
        check_step.dependOn(&strict_tests.step);
        strict_step.dependOn(&b.addRunArtifact(strict_tests).step);
    }

    // These parsers and identities are VM-independent and apply equally to
    // strict and compatibility builds. Ordinary VM regression suites have
    // deliberate compatibility assumptions and are not wired into this graph.
    for ([_][]const u8{ "build/artifact_identity.zig", "src/artifact.zig", "src/effect_trace.zig", "src/effect_invocation.zig", "src/turn_receipt.zig", "src/effect_worker_protocol.zig" }) |path| {
        const module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
        const tests = b.addTest(.{ .root_module = module });
        check_step.dependOn(&tests.step);
        strict_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const catalogue_module = b.createModule(.{
        .root_source_file = b.path("build/native_catalogue.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const patcher_module = b.createModule(.{
        .root_source_file = b.path("tools/patch_mruby_strict.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    patcher_module.addImport("native_catalogue", catalogue_module);
    for ([_]*std.Build.Module{ catalogue_module, patcher_module }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        check_step.dependOn(&tests.step);
        strict_step.dependOn(&b.addRunArtifact(tests).step);
    }
    try addTurnExample(b, mruby_mod, codedb_tools, target, optimize, sanitize_thread, sanitize_c, check_step, strict_step);
    if (effects_worker_supported) {
        try addWorkerExample(b, mruby_mod, codedb_tools, target, optimize, sanitize_thread, sanitize_c, check_step, strict_step);
        try addReservationExample(b, mruby_mod, codedb_tools, target, optimize, sanitize_thread, sanitize_c, check_step, strict_step);
    } else {
        const unavailable = b.addFail("strict effect workers require Linux/macOS x86_64 or aarch64");
        b.step("run-effects-worker", "run brokered strict effects").dependOn(&unavailable.step);
        b.step("test-effects-worker", "test brokered strict effects").dependOn(&unavailable.step);
        b.step("run-effects-reservation", "run typed domain effects").dependOn(&unavailable.step);
        b.step("test-effects-reservation", "test typed domain effects").dependOn(&unavailable.step);
    }
    const inventory_tests = try addInventoryExample(b, mruby_mod, codedb_tools, target, optimize, sanitize_thread, sanitize_c, check_step, sqlite_effects);
    if (sqlite_effects) strict_step.dependOn(inventory_tests);
    try addDurableExample(b, mruby_mod, codedb_tools, target, optimize, sanitize_thread, sanitize_c, check_step, strict_step, sqlite_effects, effects_worker_supported);
}

fn integer64Unavailable(b: *std.Build, message: []const u8) void {
    const disabled = b.addFail(message);
    b.step("run-effects-integer64", "emit the strict integer arithmetic corpus").dependOn(&disabled.step);
    b.step("test-effects-integer64", "test strict integer execution and worker boundaries").dependOn(&disabled.step);
    b.step("test-effects-integer64-compiler", "reject unsupported numeric literals with the configured CodeDB compiler").dependOn(&disabled.step);
}

fn addInteger64Example(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    codedb_tools: CodeDB.Tools,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    check_step: *std.Build.Step,
    strict_step: *std.Build.Step,
) !void {
    const contract = @import("examples/integer64/contract.zig");
    var hosts: [contract.operations.len]CodeDB.HostBinding = undefined;
    var names: [contract.operations.len][]const u8 = undefined;
    inline for (contract.operations, 0..) |operation, i| {
        hosts[i] = .{ .name = operation.name, .authority = CodeDB.AuthoritySet.fromBits(operation.authority_bits) };
        names[i] = operation.name;
    }
    const bundle = try CodeDB.add(b, codedb_tools, .{
        .tier = .trusted,
        .host_bindings = &hosts,
        .sources = &.{.{ .name = "app", .source = b.path("examples/integer64/app.rb"), .source_name = "integer64/app.rb", .host_bindings = &names }},
    });
    const contract_module = b.createModule(.{ .root_source_file = b.path("examples/integer64/contract.zig"), .target = target, .optimize = optimize });
    const child = effectWorker(b, mruby_mod, b.path("tools/effects_worker.zig"), .{
        .name = "effects-integer64-child",
        .manifest = bundle.manifest,
        .contract = contract_module,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    check_step.dependOn(&child.step);
    b.installArtifact(child);
    const module = b.createModule(.{
        .root_source_file = b.path("examples/effects_integer64.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    module.addImport("mruby", mruby_mod);
    module.addImport("integer64_manifest", bundle.manifest);
    module.addImport("integer64_contract", contract_module);
    const corpus = b.addExecutable(.{ .name = "effects-integer64", .root_module = module });
    check_step.dependOn(&corpus.step);
    b.installArtifact(corpus);
    b.step("run-effects-integer64", "emit the strict integer arithmetic corpus").dependOn(&b.addRunArtifact(corpus).step);
    const tests_module = b.createModule(.{
        .root_source_file = b.path("src/effects_integer64_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    tests_module.addImport("mruby", mruby_mod);
    tests_module.addImport("integer64_example", module);
    const config = b.addOptions();
    config.addOptionPath("worker_executable", child.getEmittedBin());
    tests_module.addOptions("integer64_test_config", config);
    const tests = b.addTest(.{ .root_module = tests_module });
    check_step.dependOn(&tests.step);
    const step = b.step("test-effects-integer64", "test strict integer execution and worker boundaries");
    step.dependOn(&b.addRunArtifact(tests).step);
    strict_step.dependOn(step);
    const compiler_step = b.step("test-effects-integer64-compiler", "reject unsupported numeric literals with the configured CodeDB compiler");
    const rejected_literals = [_]struct { name: []const u8, diagnostic: []const u8 }{
        .{ .name = "float_literal", .diagnostic = "floating-point numbers are not supported" },
        .{ .name = "float_folded", .diagnostic = "floating-point numbers are not supported" },
        .{ .name = "float_dead", .diagnostic = "floating-point numbers are not supported" },
        .{ .name = "integer_overflow", .diagnostic = "integer literal outside int64 range" },
        .{ .name = "integer_underflow", .diagnostic = "integer literal outside int64 range" },
    };
    for (rejected_literals) |literal| {
        const rejected = std.Build.Step.Run.create(b, b.fmt("reject integer profile {s}", .{literal.name}));
        rejected.addFileArg(codedb_tools.mrbc);
        rejected.addArg("-o");
        // Failed compilation must not publish an artifact. Use the platform's
        // null device so a successful but forbidden compile still fails the
        // expected-exit assertion without declaring a missing build output.
        rejected.addArg(if (b.graph.host.result.os.tag == .windows) "NUL" else "/dev/null");
        rejected.addFileArg(b.path(b.fmt("examples/integer64/{s}.rb", .{literal.name})));
        rejected.expectExitCode(1);
        rejected.expectStdErrMatch(literal.diagnostic);
        compiler_step.dependOn(&rejected.step);
    }
    step.dependOn(compiler_step);
}

fn addEffectInspector(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    check_step: *std.Build.Step,
    effects_step: *std.Build.Step,
) void {
    // The installed inspector imports only inert codecs. In particular it does
    // not link mruby, SQLite, a worker executable, or an operation catalogue.
    const inspect_module = b.createModule(.{
        .root_source_file = b.path("src/effect_inspect.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_module = b.createModule(.{
        .root_source_file = b.path("tools/effects_inspect.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("effect_inspect", inspect_module);
    const cli = b.addExecutable(.{ .name = "mruby-effects-inspect", .root_module = cli_module });
    check_step.dependOn(&cli.step);
    b.installArtifact(cli);
    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    b.step("run-effects-inspect", "inspect an inert turn receipt: -- <receipt-file>").dependOn(&run_cli.step);
    const tests_module = b.createModule(.{
        .root_source_file = b.path("src/effect_inspect_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    tests_module.addImport("mruby", mruby_mod);
    const tests = b.addTest(.{ .root_module = tests_module });
    check_step.dependOn(&tests.step);
    const test_step = b.step("test-effects-inspect", "test inert receipt inspection and the VM-free CLI");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const fixture_module = b.createModule(.{
        .root_source_file = b.path("tools/effects_inspect_fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_module.addImport("mruby", mruby_mod);
    const fixture = b.addExecutable(.{ .name = "effects-inspect-fixture", .root_module = fixture_module });
    check_step.dependOn(&fixture.step);
    const export_fixture = b.addRunArtifact(fixture);
    export_fixture.addPassthruArgs();
    b.step("make-effects-inspect-fixture", "write a synthetic receipt: -- <output-file>").dependOn(&export_fixture.step);
    const make_fixture = b.addRunArtifact(fixture);
    const receipt = make_fixture.addOutputFileArg("inspection.receipt");
    const demo = b.addRunArtifact(cli);
    demo.addFileArg(receipt);
    b.step("run-effects-inspect-demo", "inspect a constructed receipt fixture without executing Ruby").dependOn(&demo.step);
    const smoke = b.addRunArtifact(cli);
    smoke.addFileArg(receipt);
    smoke.expectStdOutMatch("\"operation_count\":1");
    smoke.expectStdOutMatch("\"preview_bytes\":\"OutOfStock\"");
    smoke.expectStdErrEqual("");
    test_step.dependOn(&smoke.step);
    const invalid = b.addWriteFiles().add("malformed.receipt", "not a receipt\x1b");
    const rejected = b.addRunArtifact(cli);
    rejected.addFileArg(invalid);
    rejected.expectExitCode(1);
    rejected.expectStdOutEqual("");
    rejected.expectStdErrMatch("mruby-effects-inspect:");
    test_step.dependOn(&rejected.step);
    effects_step.dependOn(test_step);
}

fn addEffectDataTests(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    check_step: *std.Build.Step,
    test_step: *std.Build.Step,
) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/effect_data_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    module.addImport("mruby", mruby_mod);
    const tests = b.addTest(.{ .root_module = module });
    check_step.dependOn(&tests.step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addTurnExample(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    codedb_tools: CodeDB.Tools,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    check_step: *std.Build.Step,
    strict_step: *std.Build.Step,
) !void {
    const contract = @import("examples/turn/contract.zig");
    var hosts: [contract.operations.len]CodeDB.HostBinding = undefined;
    var names: [contract.operations.len][]const u8 = undefined;
    inline for (contract.operations, 0..) |operation, i| {
        hosts[i] = .{ .name = operation.name, .authority = CodeDB.AuthoritySet.fromBits(operation.authority_bits) };
        names[i] = operation.name;
    }
    const bundle = try CodeDB.add(b, codedb_tools, .{
        .tier = .trusted,
        .host_bindings = &hosts,
        .sources = &.{
            .{ .name = "counter", .source = b.path("examples/turn/counter.rb"), .source_name = "turn/counter.rb", .host_bindings = &names },
            .{ .name = "fresh_probe", .source = b.path("examples/turn/fresh_probe.rb"), .source_name = "turn/fresh_probe.rb", .host_bindings = &names },
        },
    });
    const module = b.createModule(.{
        .root_source_file = b.path("examples/effects_turn.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    module.addImport("mruby", mruby_mod);
    module.addImport("turn_manifest", bundle.manifest);
    const example = b.addExecutable(.{ .name = "effects-turn", .root_module = module });
    check_step.dependOn(&example.step);
    b.installArtifact(example);
    b.step("run-effects-turn", "run a fresh strict turn with data-only effects and explicit commit").dependOn(&b.addRunArtifact(example).step);
    const turn_tests = b.step("test-effects-turn", "test fresh strict turns, data-only effects, commit/discard and terminal replay");
    for ([_][]const u8{ "src/strict_turn_tests.zig", "src/strict_turn_lifecycle_tests.zig", "src/strict_turn_contract_tests.zig" }) |path| {
        const tests_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        tests_module.addImport("turn_example", module);
        tests_module.addImport("mruby", mruby_mod);
        tests_module.addImport("turn_manifest", bundle.manifest);
        const tests = b.addTest(.{ .root_module = tests_module });
        check_step.dependOn(&tests.step);
        turn_tests.dependOn(&b.addRunArtifact(tests).step);
    }
    strict_step.dependOn(turn_tests);
}

fn addWorkerExample(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    codedb_tools: CodeDB.Tools,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    check_step: *std.Build.Step,
    strict_step: *std.Build.Step,
) !void {
    const contract = @import("examples/worker/contract.zig");
    var hosts: [contract.operations.len]CodeDB.HostBinding = undefined;
    var names: [contract.operations.len][]const u8 = undefined;
    inline for (contract.operations, 0..) |operation, i| {
        hosts[i] = .{ .name = operation.name, .authority = CodeDB.AuthoritySet.fromBits(operation.authority_bits) };
        names[i] = operation.name;
    }
    const bundle = try CodeDB.add(b, codedb_tools, .{
        .tier = .trusted,
        .host_bindings = &hosts,
        .sources = &.{.{ .name = "app", .source = b.path("examples/worker/app.rb"), .source_name = "worker/app.rb", .host_bindings = &names }},
    });
    const contract_module = b.createModule(.{
        .root_source_file = b.path("examples/worker/contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const child = effectWorker(b, mruby_mod, b.path("tools/effects_worker.zig"), .{
        .name = "effects-worker-child",
        .manifest = bundle.manifest,
        .contract = contract_module,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    check_step.dependOn(&child.step);
    b.installArtifact(child);
    const host_module = b.createModule(.{
        .root_source_file = b.path("examples/effects_worker.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    host_module.addImport("mruby", mruby_mod);
    host_module.addImport("worker_manifest", bundle.manifest);
    host_module.addImport("worker_contract", contract_module);
    const host = b.addExecutable(.{ .name = "effects-worker", .root_module = host_module });
    check_step.dependOn(&host.step);
    b.installArtifact(host);
    const run = b.addRunArtifact(host);
    run.addArtifactArg(child);
    b.step("run-effects-worker", "run strict application code in a confined child with a host effect broker").dependOn(&run.step);

    const config = b.addOptions();
    config.addOptionPath("worker_executable", child.getEmittedBin());
    for ([_][]const u8{ "unknown", "denied", "reordered", "duplicate", "exit_after_effect", "forged_result", "dropped_record", "wrong_arity", "trailing_output", "crash_after_finish", "forged_terminal", "malformed_diagnostic", "spoofed_diagnostic", "schema_arguments", "turn_result", "turn_state" }) |mode| {
        const fault_options = b.addOptions();
        fault_options.addOption([]const u8, "mode", mode);
        const module = b.createModule(.{
            .root_source_file = b.path("examples/worker/fault_worker.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        module.addImport("mruby", mruby_mod);
        module.addImport("worker_manifest", bundle.manifest);
        module.addImport("worker_contract", contract_module);
        module.addOptions("worker_fault_config", fault_options);
        const fixture = b.addExecutable(.{ .name = b.fmt("effect-worker-{s}-fixture", .{mode}), .root_module = module });
        check_step.dependOn(&fixture.step);
        config.addOptionPath(b.fmt("{s}_executable", .{mode}), fixture.getEmittedBin());
    }
    const probe_module = b.createModule(.{
        .root_source_file = b.path("examples/worker/confinement_probe.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    probe_module.addImport("mruby", mruby_mod);
    probe_module.addCSourceFile(.{ .file = b.path("examples/worker/confinement_probe.c"), .flags = &.{ "-Wall", "-Wextra" } });
    const probe = b.addExecutable(.{ .name = "effect-worker-confinement-probe", .root_module = probe_module });
    check_step.dependOn(&probe.step);
    config.addOptionPath("confinement_executable", probe.getEmittedBin());
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/strict_worker_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    test_module.addImport("mruby", mruby_mod);
    test_module.addImport("worker_example", host_module);
    test_module.addOptions("worker_test_config", config);
    const tests = b.addTest(.{ .root_module = test_module });
    check_step.dependOn(&tests.step);
    const test_step = b.step("test-effects-worker", "test host-only adapters, broker validation, child cleanup and OS confinement");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // Run codec tests in the mruby module itself so Zig discovers their test
    // declarations and all runtime feature/configuration imports remain shared.
    const diagnostic_tests = b.addTest(.{
        .root_module = mruby_mod,
        .filters = &.{"worker diagnostic"},
    });
    check_step.dependOn(&diagnostic_tests.step);
    test_step.dependOn(&b.addRunArtifact(diagnostic_tests).step);
    const process_module = b.createModule(.{
        .root_source_file = b.path("src/effect_worker_process_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    process_module.addCSourceFile(.{
        .file = b.path("src/effect_worker_process.c"),
        .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
    });
    const process_tests = b.addTest(.{ .root_module = process_module });
    check_step.dependOn(&process_tests.step);
    test_step.dependOn(&b.addRunArtifact(process_tests).step);
    if (target.result.os.tag == .linux) {
        const orphan_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = sanitize_c,
        });
        orphan_module.addCSourceFiles(.{
            .files = &.{ "src/effect_worker_process.c", "src/effect_worker_process_orphan_test.c" },
            .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
        });
        const orphan = b.addExecutable(.{ .name = "effect-worker-orphan-test", .root_module = orphan_module });
        check_step.dependOn(&orphan.step);
        const run_orphan = b.addRunArtifact(orphan);
        run_orphan.addArg("--test");
        test_step.dependOn(&run_orphan.step);
    }
    strict_step.dependOn(test_step);
}

fn addEffectSchemaTests(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    check_step: *std.Build.Step,
    effects_step: *std.Build.Step,
) void {
    const module = b.createModule(.{ .root_source_file = b.path("src/effect_schema.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = module });
    check_step.dependOn(&tests.step);
    const step = b.step("test-effects-schema", "test operation schema normalization, identity and inert validation");
    step.dependOn(&b.addRunArtifact(tests).step);
    const turn_schema_module = b.createModule(.{ .root_source_file = b.path("src/turn_contract.zig"), .target = target, .optimize = optimize });
    const turn_schema_tests = b.addTest(.{ .root_module = turn_schema_module });
    check_step.dependOn(&turn_schema_tests.step);
    step.dependOn(&b.addRunArtifact(turn_schema_tests).step);
    const validation_module = b.createModule(.{
        .root_source_file = b.path("src/effect_schema_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    validation_module.addImport("mruby", mruby_mod);
    const validation_tests = b.addTest(.{ .root_module = validation_module });
    check_step.dependOn(&validation_tests.step);
    step.dependOn(&b.addRunArtifact(validation_tests).step);
    effects_step.dependOn(step);
}

fn addReservationExample(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    codedb_tools: CodeDB.Tools,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    check_step: *std.Build.Step,
    strict_step: *std.Build.Step,
) !void {
    const contract = @import("examples/reservation/contract.zig");
    var hosts: [contract.operations.len]CodeDB.HostBinding = undefined;
    var names: [contract.operations.len][]const u8 = undefined;
    inline for (contract.operations, 0..) |operation, i| {
        hosts[i] = .{ .name = operation.name, .authority = CodeDB.AuthoritySet.fromBits(operation.authority_bits) };
        names[i] = operation.name;
    }
    const bundle = try CodeDB.add(b, codedb_tools, .{
        .tier = .trusted,
        .host_bindings = &hosts,
        .sources = &.{.{ .name = "app", .source = b.path("examples/reservation/app.rb"), .source_name = "reservation/app.rb", .host_bindings = &names }},
    });
    const contract_module = b.createModule(.{ .root_source_file = b.path("examples/reservation/contract.zig"), .target = target, .optimize = optimize });
    const child = effectWorker(b, mruby_mod, b.path("tools/effects_worker.zig"), .{
        .name = "effects-reservation-child",
        .manifest = bundle.manifest,
        .contract = contract_module,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    check_step.dependOn(&child.step);
    b.installArtifact(child);
    const changed_contract = b.createModule(.{ .root_source_file = b.path("examples/reservation/contract_v2.zig"), .target = target, .optimize = optimize });
    const changed_child = effectWorker(b, mruby_mod, b.path("tools/effects_worker.zig"), .{
        .name = "effects-reservation-schema-fixture",
        .manifest = bundle.manifest,
        .contract = changed_contract,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    check_step.dependOn(&changed_child.step);
    const changed_turn_contract = b.createModule(.{ .root_source_file = b.path("examples/reservation/turn_contract_v2.zig"), .target = target, .optimize = optimize });
    const changed_turn_child = effectWorker(b, mruby_mod, b.path("tools/effects_worker.zig"), .{
        .name = "effects-reservation-turn-schema-fixture",
        .manifest = bundle.manifest,
        .contract = changed_turn_contract,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    check_step.dependOn(&changed_turn_child.step);
    const module = b.createModule(.{
        .root_source_file = b.path("examples/effects_reservation.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    module.addImport("mruby", mruby_mod);
    module.addImport("reservation_manifest", bundle.manifest);
    module.addImport("reservation_contract", contract_module);
    const host = b.addExecutable(.{ .name = "effects-reservation", .root_module = module });
    check_step.dependOn(&host.step);
    b.installArtifact(host);
    const run = b.addRunArtifact(host);
    run.addArtifactArg(child);
    b.step("run-effects-reservation", "run typed reservation operations in a confined worker").dependOn(&run.step);
    const options = b.addOptions();
    options.addOptionPath("worker_executable", child.getEmittedBin());
    options.addOptionPath("changed_worker_executable", changed_child.getEmittedBin());
    options.addOptionPath("changed_turn_worker_executable", changed_turn_child.getEmittedBin());
    const tests_module = b.createModule(.{
        .root_source_file = b.path("examples/reservation/tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    tests_module.addImport("mruby", mruby_mod);
    tests_module.addImport("reservation_example", module);
    tests_module.addOptions("reservation_test_config", options);
    const tests = b.addTest(.{ .root_module = tests_module });
    check_step.dependOn(&tests.step);
    const step = b.step("test-effects-reservation", "test typed arguments, outcomes, rollback and schema-bound replay");
    step.dependOn(&b.addRunArtifact(tests).step);
    strict_step.dependOn(step);
}

fn addDurableExample(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    codedb_tools: CodeDB.Tools,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    check_step: *std.Build.Step,
    strict_step: *std.Build.Step,
    enabled: bool,
    worker_supported: bool,
) !void {
    const run_step = b.step("run-effects-durable", "run durable SQLite turns, retry recovery, replay and outbox delivery");
    const test_step = b.step("test-effects-durable", "test durable turns and process-crash recovery");
    if (!enabled or !worker_supported) {
        const unavailable = b.addFail(if (!enabled)
            "durable example requires -Deffects-strict=true -Dsqlite-effects=true"
        else
            "durable example requires strict effect worker support (Linux/macOS x86_64 or aarch64)");
        run_step.dependOn(&unavailable.step);
        test_step.dependOn(&unavailable.step);
        return;
    }
    const sqlite = b.lazyDependency("sqlite", .{}) orelse return;
    const contract = @import("examples/durable/contract.zig");
    var hosts: [contract.operations.len]CodeDB.HostBinding = undefined;
    var names: [contract.operations.len][]const u8 = undefined;
    inline for (contract.operations, 0..) |operation, i| {
        hosts[i] = .{ .name = operation.name, .authority = CodeDB.AuthoritySet.fromBits(operation.authority_bits) };
        names[i] = operation.name;
    }
    const bundle = try CodeDB.add(b, codedb_tools, .{
        .tier = .trusted,
        .host_bindings = &hosts,
        .sources = &.{.{ .name = "inventory", .source = b.path("examples/durable/inventory.rb"), .source_name = "durable/inventory.rb", .host_bindings = &names }},
    });
    const bundle_v2 = try CodeDB.add(b, codedb_tools, .{
        .tier = .trusted,
        .host_bindings = &hosts,
        .sources = &.{.{ .name = "inventory-v2", .source = b.path("examples/durable/inventory_v2.rb"), .source_name = "durable/inventory_v2.rb", .host_bindings = &names }},
    });
    const contract_module = b.createModule(.{ .root_source_file = b.path("examples/durable/contract.zig"), .target = target, .optimize = optimize });
    const contract_v2_module = b.createModule(.{ .root_source_file = b.path("examples/durable/contract_v2.zig"), .target = target, .optimize = optimize });
    contract_v2_module.addImport("durable_original_contract", contract_module);
    const child = effectWorker(b, mruby_mod, b.path("tools/effects_worker.zig"), .{
        .name = "effects-durable-child",
        .manifest = bundle.manifest,
        .contract = contract_module,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    check_step.dependOn(&child.step);
    b.installArtifact(child);
    const child_v2 = effectWorker(b, mruby_mod, b.path("tools/effects_worker.zig"), .{
        .name = "effects-durable-child-v2",
        .manifest = bundle_v2.manifest,
        .contract = contract_v2_module,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    check_step.dependOn(&child_v2.step);
    b.installArtifact(child_v2);
    const changed_contract_module = b.createModule(.{ .root_source_file = b.path("examples/durable/contract_schema_fixture.zig"), .target = target, .optimize = optimize });
    changed_contract_module.addImport("durable_original_contract", contract_module);
    const host_module = durableHostModule(b, mruby_mod, durableApplicationsModule(b, mruby_mod, target, optimize, sanitize_thread, sanitize_c, bundle.manifest, bundle_v2.manifest, contract_module, contract_v2_module), contract_module, target, optimize, sanitize_thread, sanitize_c, sqlite);
    const fixture_host_module = durableHostModule(b, mruby_mod, durableApplicationsModule(b, mruby_mod, target, optimize, sanitize_thread, sanitize_c, bundle.manifest, bundle_v2.manifest, changed_contract_module, contract_v2_module), changed_contract_module, target, optimize, sanitize_thread, sanitize_c, sqlite);
    const demo_module = b.createModule(.{
        .root_source_file = b.path("examples/effects_durable.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    demo_module.addImport("mruby", mruby_mod);
    demo_module.addImport("durable_host", host_module);
    demo_module.addImport("durable_contract", contract_module);
    const demo = b.addExecutable(.{ .name = "effects-durable", .root_module = demo_module });
    check_step.dependOn(&demo.step);
    b.installArtifact(demo);
    const run = b.addRunArtifact(demo);
    run.addArtifactArg(child);
    run.addArtifactArg(child_v2);
    run.addPassthruArgs();
    run_step.dependOn(&run.step);

    const fixture_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/crash_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    fixture_module.addImport("mruby", mruby_mod);
    fixture_module.addImport("durable_host", host_module);
    fixture_module.addImport("durable_contract", contract_module);
    fixture_module.addCSourceFile(.{
        .file = b.path("examples/durable/crash_supervisor.c"),
        .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
    });
    const fixture = b.addExecutable(.{ .name = "effects-durable-crash-fixture", .root_module = fixture_module });
    check_step.dependOn(&fixture.step);
    const identity_fixture_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/contract_identity_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    identity_fixture_module.addImport("mruby", mruby_mod);
    identity_fixture_module.addImport("durable_host", fixture_host_module);
    identity_fixture_module.addImport("durable_contract", changed_contract_module);
    identity_fixture_module.addCSourceFile(.{
        .file = b.path("examples/durable/crash_supervisor.c"),
        .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
    });
    const identity_fixture = b.addExecutable(.{ .name = "effects-durable-contract-fixture", .root_module = identity_fixture_module });
    check_step.dependOn(&identity_fixture.step);
    const upgrade_fixture_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/upgrade_crash_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    upgrade_fixture_module.addImport("mruby", mruby_mod);
    upgrade_fixture_module.addImport("durable_host", host_module);
    upgrade_fixture_module.addImport("durable_contract", contract_module);
    upgrade_fixture_module.addCSourceFile(.{
        .file = b.path("examples/durable/crash_supervisor.c"),
        .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
    });
    const upgrade_fixture = b.addExecutable(.{ .name = "effects-durable-upgrade-fixture", .root_module = upgrade_fixture_module });
    check_step.dependOn(&upgrade_fixture.step);
    const config = b.addOptions();
    config.addOptionPath("worker_executable", child.getEmittedBin());
    config.addOptionPath("worker_v2_executable", child_v2.getEmittedBin());
    config.addOptionPath("crash_fixture_executable", fixture.getEmittedBin());
    config.addOptionPath("changed_contract_fixture_executable", identity_fixture.getEmittedBin());
    config.addOptionPath("upgrade_crash_fixture_executable", upgrade_fixture.getEmittedBin());
    const tests_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    tests_module.addImport("mruby", mruby_mod);
    tests_module.addImport("durable_host", host_module);
    tests_module.addImport("durable_contract", contract_module);
    tests_module.addOptions("durable_test_config", config);
    tests_module.addCSourceFile(.{
        .file = b.path("examples/durable/crash_supervisor.c"),
        .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
    });
    const tests = b.addTest(.{ .root_module = tests_module });
    check_step.dependOn(&tests.step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const upgrade_tests_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/upgrade_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    upgrade_tests_module.addImport("mruby", mruby_mod);
    upgrade_tests_module.addImport("durable_host", host_module);
    upgrade_tests_module.addImport("durable_contract", contract_module);
    upgrade_tests_module.addOptions("durable_test_config", config);
    upgrade_tests_module.addCSourceFile(.{
        .file = b.path("examples/durable/crash_supervisor.c"),
        .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
    });
    const upgrade_tests = b.addTest(.{ .root_module = upgrade_tests_module });
    check_step.dependOn(&upgrade_tests.step);
    test_step.dependOn(&b.addRunArtifact(upgrade_tests).step);
    const retention_tests_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/retention_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    retention_tests_module.addImport("mruby", mruby_mod);
    retention_tests_module.addImport("durable_host", host_module);
    retention_tests_module.addImport("durable_contract", contract_module);
    retention_tests_module.addOptions("durable_test_config", config);
    retention_tests_module.addCSourceFile(.{
        .file = b.path("examples/durable/crash_supervisor.c"),
        .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
    });
    const retention_tests = b.addTest(.{ .root_module = retention_tests_module });
    check_step.dependOn(&retention_tests.step);
    test_step.dependOn(&b.addRunArtifact(retention_tests).step);
    const migrate_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/migrate.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    migrate_module.addImport("mruby", mruby_mod);
    // SQLite and the durable SQL shim arrive through the host module.
    migrate_module.addImport("durable_host", host_module);
    migrate_module.addImport("durable_contract", contract_module);
    const migrator = b.addExecutable(.{ .name = "effects-durable-migrate", .root_module = migrate_module });
    check_step.dependOn(&migrator.step);
    b.installArtifact(migrator);
    const migrate_tests_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/migrate_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    migrate_tests_module.addImport("mruby", mruby_mod);
    migrate_tests_module.addImport("durable_host", host_module);
    migrate_tests_module.addImport("durable_migrate", migrate_module);
    migrate_tests_module.addImport("durable_contract", contract_module);
    migrate_tests_module.addOptions("durable_test_config", config);
    const migrate_tests = b.addTest(.{ .root_module = migrate_tests_module });
    check_step.dependOn(&migrate_tests.step);
    test_step.dependOn(&b.addRunArtifact(migrate_tests).step);
    const chain_tests_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/chain_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    chain_tests_module.addImport("mruby", mruby_mod);
    chain_tests_module.addImport("durable_host", host_module);
    chain_tests_module.addImport("durable_migrate", migrate_module);
    chain_tests_module.addImport("durable_contract", contract_module);
    chain_tests_module.addOptions("durable_test_config", config);
    const chain_tests = b.addTest(.{ .root_module = chain_tests_module });
    check_step.dependOn(&chain_tests.step);
    test_step.dependOn(&b.addRunArtifact(chain_tests).step);
    // Production-delivery adapter example: a loopback HTTP recipient test
    // double and a dispatcher client that carries the stable intent ID as an
    // explicit idempotency key. The embedding library stays transport-free.
    const http_recipient_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/http_recipient.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    http_recipient_module.addImport("mruby", mruby_mod);
    http_recipient_module.addImport("durable_host", host_module);
    const http_recipient = b.addExecutable(.{ .name = "effects-durable-http-recipient", .root_module = http_recipient_module });
    check_step.dependOn(&http_recipient.step);
    b.installArtifact(http_recipient);
    config.addOptionPath("http_recipient_executable", http_recipient.getEmittedBin());
    const http_delivery_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/http_delivery.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    http_delivery_module.addImport("durable_host", host_module);
    http_delivery_module.addImport("durable_contract", contract_module);
    const http_delivery_tests_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/http_delivery_tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    http_delivery_tests_module.addImport("mruby", mruby_mod);
    http_delivery_tests_module.addImport("durable_host", host_module);
    http_delivery_tests_module.addImport("durable_contract", contract_module);
    http_delivery_tests_module.addImport("durable_http", http_delivery_module);
    http_delivery_tests_module.addOptions("durable_test_config", config);
    const http_delivery_tests = b.addTest(.{ .root_module = http_delivery_tests_module });
    check_step.dependOn(&http_delivery_tests.step);
    test_step.dependOn(&b.addRunArtifact(http_delivery_tests).step);
    // The delivery root also discovers sql.zig's focused storage tests. Keep
    // these explicit; tests in a named dependency module are not test roots.
    const storage_module = b.createModule(.{
        .root_source_file = b.path("examples/durable/delivery.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = sanitize_thread,
        .sanitize_c = sanitize_c,
    });
    storage_module.addImport("durable_contract", contract_module);
    storage_module.addIncludePath(sqlite.path(""));
    storage_module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0", "-w" },
    });
    storage_module.addCSourceFile(.{
        .file = b.path("examples/durable/sql_identity.c"),
        .flags = &.{ "-Wall", "-Wextra", no_c_fuzz_coverage },
    });
    const storage_tests = b.addTest(.{ .root_module = storage_module });
    check_step.dependOn(&storage_tests.step);
    test_step.dependOn(&b.addRunArtifact(storage_tests).step);
    strict_step.dependOn(test_step);
}

fn addInventoryExample(
    b: *std.Build,
    mruby_mod: *std.Build.Module,
    codedb_tools: CodeDB.Tools,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize_thread: bool,
    sanitize_c: ?std.zig.SanitizeC,
    check_step: *std.Build.Step,
    enabled: bool,
) !*std.Build.Step {
    // Deliberately opt-in: the embedding library has no SQLite dependency.
    const inventory_run_step = b.step("run-effects-inventory", "run SQLite inventory effects and measurements (requires -Dsqlite-effects=true)");
    const inventory_test_step = b.step("test-effects-inventory", "verify SQLite inventory effects (requires -Dsqlite-effects=true)");
    if (enabled) {
        if (b.lazyDependency("sqlite", .{})) |sqlite| {
            const inventory_contract = @import("examples/inventory/contract.zig");
            var inventory_hosts: [inventory_contract.operations.len]CodeDB.HostBinding = undefined;
            var inventory_names: [inventory_contract.operations.len][]const u8 = undefined;
            inline for (inventory_contract.operations, 0..) |operation, i| {
                inventory_hosts[i] = .{ .name = operation.name, .authority = CodeDB.AuthoritySet.fromBits(operation.authority_bits) };
                inventory_names[i] = operation.name;
            }
            const inventory_bundle = try CodeDB.add(b, codedb_tools, .{
                .tier = .trusted,
                .host_bindings = &inventory_hosts,
                .sources = &.{.{
                    .name = "inventory",
                    .source = b.path("examples/inventory/inventory.rb"),
                    .source_name = "inventory/inventory.rb",
                    .host_bindings = &inventory_names,
                }},
            });
            const inventory_mod = b.createModule(.{
                .root_source_file = b.path("examples/effects_inventory.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .sanitize_thread = sanitize_thread,
                .sanitize_c = sanitize_c,
            });
            inventory_mod.addImport("mruby", mruby_mod);
            inventory_mod.addImport("inventory_manifest", inventory_bundle.manifest);
            inventory_mod.addIncludePath(sqlite.path(""));
            inventory_mod.addCSourceFile(.{
                .file = sqlite.path("sqlite3.c"),
                .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0", "-w" },
            });
            const inventory = b.addExecutable(.{ .name = "effects-inventory", .root_module = inventory_mod });
            check_step.dependOn(&inventory.step);
            b.installArtifact(inventory);
            const run_inventory = b.addRunArtifact(inventory);
            inventory_run_step.dependOn(&run_inventory.step);
            const test_inventory = b.addRunArtifact(inventory);
            test_inventory.addArg("--test");
            inventory_test_step.dependOn(&test_inventory.step);
        }
    } else {
        const disabled = b.addFail("inventory example requires -Dsqlite-effects=true (SQLite is an optional, hash-pinned dependency)");
        inventory_run_step.dependOn(&disabled.step);
        inventory_test_step.dependOn(&disabled.step);
    }

    return inventory_test_step;
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
    effects_strict: bool,
    effects_integer64: bool,
) !*std.Build.Module {
    const pointer_bits = target.ptrBitWidth();
    if (pointer_bits != 32 and pointer_bits != 64) {
        std.debug.panic("mruby RITE identity does not support {d}-bit pointers", .{pointer_bits});
    }

    var semantic_defines: std.ArrayList([]const u8) = .empty;
    try semantic_defines.append(arena, "MRB_USE_DEBUG_HOOK");
    if (no_compiler) try semantic_defines.append(arena, "MRZ_NO_COMPILER");
    if (effects_strict) try semantic_defines.appendSlice(arena, &.{ "MRZ_EFFECTS_STRICT=1", "MRB_NO_STDIO" });
    if (effects_integer64) try semantic_defines.appendSlice(arena, &.{ "MRB_NO_FLOAT", "MRB_INT64", "MRZ_INTEGER_ONLY=1" });
    try semantic_defines.appendSlice(arena, &.{
        "MRB_STR_LENGTH_MAX=0",
        "MRB_ARY_LENGTH_MAX=0",
    });

    var ordered_gems: std.ArrayList([]const u8) = .empty;

    for (selected_gems) |gem| {
        try ordered_gems.append(arena, gem.name);
        for (gem.defines) |define| try semantic_defines.append(arena, define);
    }

    var generated_configuration: std.ArrayList([]const u8) = .empty;
    try generated_configuration.appendSlice(arena, &.{
        "presym-scanner=v1",
        "presym-define=MRB_PRESYM_SCANNING",
        "presym-target-traits=pointer-width,endian",
        "mrbc-cdump=static,no-extension-tables",
        "mrblib-template=v1",
        "gem-init-template=v1",
        hash_integer_patch_marker,
        hash_symbol_patch_marker,
    });
    if (effects_integer64) try generated_configuration.append(arena, "effects-integer64-policy=v1");
    if (effects_strict) {
        try generated_configuration.append(arena, "effects-strict-native-catalogue=v1");
        var digest: [32]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(@embedFile("build/native_catalogue.zig"));
        hash.update(@embedFile("tools/patch_mruby_strict.zig"));
        hash.update(@embedFile("src/strict_native.c"));
        hash.update(@embedFile("src/strict_native.h"));
        hash.final(&digest);
        try generated_configuration.append(arena, try std.fmt.allocPrint(arena, "strict-native-source-digest={x}", .{digest}));
    }

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
    // These traits describe the same numeric flags used by both the host
    // compiler and target runtime. Zero float bits means Float is absent.
    run.addArg(try std.fmt.allocPrint(arena, "{d}", .{if (effects_integer64) @as(u16, 64) else pointer_bits}));
    run.addArg(if (effects_integer64) "0" else "64");
    run.addArg("word");
    run.addArg(if (effects_integer64) "false" else "true");
    try addIdentitySequenceArgs(run, arena, semantic_defines.items);
    try addIdentitySequenceArgs(run, arena, ordered_gems.items);
    try addIdentitySequenceArgs(run, arena, generated_configuration.items);

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
    extra_include_dirs: []const std.Build.LazyPath,
) !std.Build.LazyPath {
    const include = try root.join(arena, "include");
    const run = b.addRunArtifact(presym_gen);
    for (inputs) |in| {
        const cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-E", "-P", "-DMRB_PRESYM_SCANNING" });
        cmd.addArg("-target");
        cmd.addArg(triple);
        for (extra_include_dirs) |dir| cmd.addPrefixedDirectoryArg("-I", dir);
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

const PatchedHostSource = struct { path: []const u8, file: std.Build.LazyPath };

fn patchIntegerHostSources(b: *std.Build, root: std.Build.LazyPath, patcher: *std.Build.Step.Compile) ![]const PatchedHostSource {
    const paths = [_][]const u8{
        "src/numeric.c",
        "src/string.c",
        "mrbgems/mruby-compiler/core/codegen.c",
        "mrbgems/mruby-compiler/core/y.tab.c",
    };
    const result = try b.allocator.alloc(PatchedHostSource, paths.len);
    for (paths, result) |path, *source| {
        const run = b.addRunArtifact(patcher);
        run.addArg(path);
        run.addFileArg(root.path(b, path));
        source.* = .{ .path = path, .file = run.addOutputFileArg(std.fs.path.basename(path)) };
        run.addArg("integer-host");
    }
    return result;
}

fn patchedHostSource(sources_to_check: []const PatchedHostSource, path: []const u8) ?std.Build.LazyPath {
    for (sources_to_check) |source| if (std.mem.eql(u8, source.path, path)) return source.file;
    return null;
}

const StrictSources = struct {
    tool: *std.Build.Step.Compile,
    core: [sources.core_srcs.len]std.Build.LazyPath,
    include: std.Build.LazyPath,
};

fn patchMrubyStrict(b: *std.Build, root: std.Build.LazyPath, patched_hash: std.Build.LazyPath) !StrictSources {
    const patcher = hostTool(b, "tools/patch_mruby_strict.zig");
    const catalogue = b.createModule(.{
        .root_source_file = b.path("build/native_catalogue.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    patcher.root_module.addImport("native_catalogue", catalogue);
    var result: StrictSources = undefined;
    result.tool = patcher;
    for (sources.core_srcs, 0..) |path, index| {
        const run = b.addRunArtifact(patcher);
        run.addArg(path);
        run.addFileArg(if (std.mem.eql(u8, path, "src/hash.c")) patched_hash else root.path(b, path));
        result.core[index] = run.addOutputFileArg(std.fs.path.basename(path));
    }
    const header = b.addRunArtifact(patcher);
    header.addArg("include/mruby.h");
    header.addFileArg(root.path(b, "include/mruby.h"));
    const headers = b.addWriteFiles();
    _ = headers.addCopyFile(header.addOutputFileArg("mruby.h"), "mruby.h");
    result.include = headers.getDirectory();
    return result;
}

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

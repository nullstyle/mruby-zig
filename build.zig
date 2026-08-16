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

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gem_set = b.option([]const u8, "gem-set", "gem set: \"standard\" or \"minimal\"") orelse "standard";
    const with_gems = b.option([]const u8, "with-gems", "comma-separated extra gems to enable on top of the gem set");
    const without_gems = b.option([]const u8, "without-gems", "comma-separated gems to remove from the gem set");

    const arena = b.graph.arena;
    const mruby_dep = b.dependency("mruby", .{});
    const root = mruby_dep.path("");

    const selected_gems = selectGems(arena, gem_set, with_gems, without_gems);
    var gem_defines: std.ArrayList([]const u8) = .empty;
    for (selected_gems) |g| {
        for (g.defines) |d| {
            try gem_defines.append(arena, try std.fmt.allocPrint(arena, "-D{s}", .{d}));
        }
    }

    // Host tools shared by the pipeline.
    const presym_gen = hostTool(b, "tools/presym_gen.zig");
    const file_join = hostTool(b, "tools/file_join.zig");

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
    mrbc_mod.addCSourceFiles(.{ .root = root, .files = mrbc_files.items, .flags = &.{"-w"} });
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
    var lib_scan: std.ArrayList(ScanInput) = .empty;
    try addTreeFiles(arena, &lib_scan, root, &sources.core_srcs, "core");
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
    for (generated_c.items) |g| try lib_scan.append(arena, .{ .lp = g.lp, .pp_name = g.pp_name });

    const lib_presym_dir = try presymHeaders(b, presym_gen, arena, lib_scan.items, gem_defines.items, root, triple);

    // ============================= stage 5 =================================
    // The `mruby` module carries the entire C library (core + compiler +
    // gems + generated sources + shim) so consumers never link anything
    // themselves. The Zig-side allocator override (src/alloc.zig, which
    // exports mrb_basic_alloc_func) lives in the same module, which is why
    // src/allocf.c is not part of the build.
    const lib_flags = flags: {
        var f: std.ArrayList([]const u8) = .empty;
        try f.append(arena, "-w");
        try f.appendSlice(arena, gem_defines.items);
        break :flags f.items;
    };

    const mruby_mod = b.addModule("mruby", .{
        .root_source_file = b.path("src/mruby.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    var lib_files: std.ArrayList([]const u8) = .empty;
    try lib_files.appendSlice(arena, &sources.core_srcs);
    try lib_files.appendSlice(arena, &sources.compiler_srcs);
    for (selected_gems) |g| try lib_files.appendSlice(arena, g.c_srcs);
    mruby_mod.addCSourceFiles(.{ .root = root, .files = lib_files.items, .flags = lib_flags });
    // Generated sources (cache paths, not under the dependency root).
    for (generated_c.items) |g| {
        mruby_mod.addCSourceFile(.{ .file = g.lp, .flags = lib_flags });
    }
    // ABI shim: exposes mruby's macro-only inline APIs as plain functions.
    mruby_mod.addCSourceFile(.{ .file = b.path("src/shim.c"), .flags = &.{"-w"} });
    mruby_mod.addIncludePath(try root.join(arena, "include"));
    mruby_mod.addIncludePath(lib_presym_dir);
    for (gem_include_dirs.items) |dir| mruby_mod.addIncludePath(dir);

    // REPL tool.
    const repl_mod = b.createModule(.{
        .root_source_file = b.path("tools/repl.zig"),
        .target = target,
        .optimize = optimize,
    });
    repl_mod.addImport("mruby", mruby_mod);
    const repl = b.addExecutable(.{ .name = "mruby-repl", .root_module = repl_mod });
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
    });
    test_mod.addImport("mruby", mruby_mod);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "run unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);

    // Examples.
    const ex_names = [_][]const u8{ "quickstart", "host_functions", "exceptions" };
    for (ex_names) |ex_name| {
        const ex_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{ex_name})),
            .target = target,
            .optimize = optimize,
        });
        ex_mod.addImport("mruby", mruby_mod);
        const ex = b.addExecutable(.{ .name = ex_name, .root_module = ex_mod });
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
) []const gems_mod.Gem {
    var list: std.ArrayList(gems_mod.Gem) = .empty;
    var base: []const gems_mod.Gem = undefined;
    if (std.mem.eql(u8, gem_set, "standard")) {
        base = &gems_mod.standard;
    } else if (std.mem.eql(u8, gem_set, "minimal")) {
        base = &gems_mod.minimal;
    } else {
        std.debug.panic("unknown -Dgem-set={s} (expected \"standard\" or \"minimal\")", .{gem_set});
    }
    for (base) |g| list.append(arena, g) catch @panic("OOM");

    if (with) |csv| {
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (name.len == 0) continue;
            const g = gems_mod.byName(name) orelse
                std.debug.panic("unknown gem in -Dwith-gems: {s}", .{name});
            var dup = false;
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) dup = true;
            }
            if (!dup) list.append(arena, g) catch @panic("OOM");
        }
    }
    if (without) |csv| {
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (name.len == 0) continue;
            removeGem(&list, name);
            // Cascade: a gem whose dependency was removed cannot initialize;
            // remove its dependents transitively (with a clear trace). The
            // scan restarts after every removal so no stale slice is walked.
            var changed = true;
            while (changed) {
                changed = false;
                var i: usize = 0;
                while (i < list.items.len) : (i += 1) {
                    var removed = false;
                    for (list.items[i].deps) |dep| {
                        if (!selected(list, dep)) {
                            std.debug.print("note: -Dwithout-gems={s} also removes {s} (depends on it)\n", .{ name, list.items[i].name });
                            removeGem(&list, list.items[i].name);
                            changed = true;
                            removed = true;
                            break;
                        }
                    }
                    if (removed) break;
                }
            }
        }
    }
    // Auto-add missing dependencies (rake's add_dependency semantics),
    // inserting each one just before its first dependent.
    resolveDeps(arena, &list);
    return list.items;
}

fn selected(list: std.ArrayList(gems_mod.Gem), name: []const u8) bool {
    for (list.items) |g| {
        if (std.mem.eql(u8, g.name, name)) return true;
    }
    return false;
}

fn removeGem(list: *std.ArrayList(gems_mod.Gem), name: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i].name, name)) {
            _ = list.orderedRemove(i);
        } else i += 1;
    }
}

fn resolveDeps(arena: std.mem.Allocator, list: *std.ArrayList(gems_mod.Gem)) void {
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            for (list.items[i].deps) |dep| {
                if (selected(list.*, dep)) continue;
                const g = gems_mod.byName(dep) orelse
                    std.debug.panic("gem {s} depends on unknown gem {s}", .{ list.items[i].name, dep });
                list.insert(arena, i, g) catch @panic("OOM");
                changed = true;
                break;
            }
        }
    }
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
/// generated include directory containing `mruby/presym/{id.h,table.h}`.
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

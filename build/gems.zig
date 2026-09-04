//! Gem catalog for mruby-zig.
//!
//! Mirrors the per-gem data that the upstream Rake build derives from each
//! gem's `mrbgem.rake` + directory contents: C sources under `src/`, Ruby
//! files under `mrblib/` (sorted by path), and any extra build defines.
//! `funcname` (used for generated init functions) is the gem name with
//! `-` replaced by `_`, exactly as `lib/mruby/gem.rb` computes it.

const authority_mod = @import("authority.zig");

pub const builtin_authority = [_]authority_mod.Source{
    // Core supplies context evaluation, __send__, reflection, and class/model
    // mutation. The compiler adds no Ruby-visible entry point by itself;
    // mruby-eval is the source that exposes compilation to guest code.
    .{ .name = "mruby-core", .authority = auth(&.{ .dynamic_code, .dynamic_dispatch, .introspection, .model_mutation, .host_output }) },
    .{ .name = "mruby-compiler", .authority = .empty },
};

pub const Gem = struct {
    name: []const u8,
    /// Conservative Ruby-visible authority exposed by this gem. Intentionally
    /// has no default: adding a catalog entry requires an explicit review.
    authority: authority_mod.Set,
    /// C sources, relative to the mruby dependency root.
    c_srcs: []const []const u8 = &.{},
    /// Ruby files, relative to the mruby dependency root; compiled to cdump
    /// bytecode and embedded in the gem's generated `gem_init.c`.
    rb_files: []const []const u8 = &.{},
    /// Extra -D defines this gem needs when enabled.
    defines: []const []const u8 = &.{},
    /// Extra include directories (relative to the mruby dependency root)
    /// this gem's sources need.
    include_dirs: []const []const u8 = &.{},
    /// Runtime dependencies on other gems in the catalog (mirrors each
    /// gem's `mrbgem.rake` `add_dependency` lines; test-only dependencies
    /// are omitted). Used by the build to validate/complete the selection.
    deps: []const []const u8 = &.{},

    pub fn funcname(gem: Gem, buf: []u8) []const u8 {
        for (gem.name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
        return buf[0..gem.name.len];
    }
};

fn auth(comptime kinds: []const authority_mod.Kind) authority_mod.Set {
    return authority_mod.Set.init(kinds);
}

fn gemDir(comptime name: []const u8) []const u8 {
    return "mrbgems/" ++ name ++ "/";
}

/// The "standard" set: metaprog + the stdlib/stdlib-ext gemboxes minus the
/// io/socket/dir/errno/print gems (excluded for cross-platform builds).
/// Order is dependency-respecting (dependencies init before dependents).
pub const standard = [_]Gem{
    .{ .name = "mruby-metaprog", .authority = auth(&.{ .dynamic_dispatch, .introspection, .model_mutation }), .c_srcs = &.{gemDir("mruby-metaprog") ++ "src/metaprog.c"} },
    .{ .name = "mruby-method", .authority = auth(&.{ .dynamic_dispatch, .introspection }), .c_srcs = &.{gemDir("mruby-method") ++ "src/method.c"}, .rb_files = &.{gemDir("mruby-method") ++ "mrblib/method.rb"}, .deps = &.{"mruby-proc-ext"} },
    .{ .name = "mruby-binding", .authority = auth(&.{.introspection}), .c_srcs = &.{gemDir("mruby-binding") ++ "src/binding.c"} },
    .{ .name = "mruby-eval", .authority = auth(&.{.dynamic_code}), .c_srcs = &.{gemDir("mruby-eval") ++ "src/eval.c"}, .deps = &.{"mruby-binding"} },
    .{ .name = "mruby-compar-ext", .authority = .empty, .rb_files = &.{gemDir("mruby-compar-ext") ++ "mrblib/compar.rb"} },
    .{ .name = "mruby-enum-ext", .authority = .empty, .rb_files = &.{gemDir("mruby-enum-ext") ++ "mrblib/enum.rb"} },
    .{ .name = "mruby-string-ext", .authority = .empty, .c_srcs = &.{gemDir("mruby-string-ext") ++ "src/string.c"}, .rb_files = &.{gemDir("mruby-string-ext") ++ "mrblib/string.rb"} },
    .{ .name = "mruby-numeric-ext", .authority = .empty, .c_srcs = &.{gemDir("mruby-numeric-ext") ++ "src/numeric_ext.c"}, .rb_files = &.{gemDir("mruby-numeric-ext") ++ "mrblib/numeric_ext.rb"} },
    .{ .name = "mruby-array-ext", .authority = .empty, .c_srcs = &.{gemDir("mruby-array-ext") ++ "src/array.c"}, .rb_files = &.{gemDir("mruby-array-ext") ++ "mrblib/array.rb"} },
    .{ .name = "mruby-hash-ext", .authority = .empty, .c_srcs = &.{gemDir("mruby-hash-ext") ++ "src/hash_ext.c"}, .rb_files = &.{gemDir("mruby-hash-ext") ++ "mrblib/hash.rb"}, .deps = &.{"mruby-array-ext"} },
    .{ .name = "mruby-range-ext", .authority = .empty, .c_srcs = &.{gemDir("mruby-range-ext") ++ "src/range.c"}, .rb_files = &.{gemDir("mruby-range-ext") ++ "mrblib/range.rb"} },
    .{ .name = "mruby-proc-ext", .authority = auth(&.{.introspection}), .c_srcs = &.{gemDir("mruby-proc-ext") ++ "src/proc.c"}, .rb_files = &.{gemDir("mruby-proc-ext") ++ "mrblib/proc.rb"} },
    .{ .name = "mruby-symbol-ext", .authority = auth(&.{.introspection}), .c_srcs = &.{gemDir("mruby-symbol-ext") ++ "src/symbol.c"}, .rb_files = &.{gemDir("mruby-symbol-ext") ++ "mrblib/symbol.rb"} },
    .{ .name = "mruby-object-ext", .authority = auth(&.{.dynamic_code}), .c_srcs = &.{gemDir("mruby-object-ext") ++ "src/object.c"}, .rb_files = &.{gemDir("mruby-object-ext") ++ "mrblib/object.rb"} },
    .{ .name = "mruby-objectspace", .authority = auth(&.{ .introspection, .heap_enumeration }), .c_srcs = &.{gemDir("mruby-objectspace") ++ "src/mruby_objectspace.c"} },
    .{ .name = "mruby-fiber", .authority = auth(&.{.continuations}), .c_srcs = &.{gemDir("mruby-fiber") ++ "src/fiber.c"} },
    .{ .name = "mruby-enumerator", .authority = auth(&.{ .continuations, .dynamic_dispatch }), .rb_files = &.{gemDir("mruby-enumerator") ++ "mrblib/enumerator.rb"}, .deps = &.{"mruby-fiber"} },
    .{ .name = "mruby-enum-lazy", .authority = auth(&.{.continuations}), .rb_files = &.{gemDir("mruby-enum-lazy") ++ "mrblib/lazy.rb"}, .deps = &.{ "mruby-enumerator", "mruby-enum-ext" } },
    .{ .name = "mruby-set", .authority = .empty, .c_srcs = &.{gemDir("mruby-set") ++ "src/set.c"}, .rb_files = &.{gemDir("mruby-set") ++ "mrblib/set.rb"}, .defines = &.{"MRB_USE_SET"}, .deps = &.{ "mruby-hash-ext", "mruby-enumerator" } },
    .{ .name = "mruby-toplevel-ext", .authority = auth(&.{.model_mutation}), .rb_files = &.{gemDir("mruby-toplevel-ext") ++ "mrblib/toplevel.rb"} },
    .{ .name = "mruby-kernel-ext", .authority = auth(&.{.introspection}), .c_srcs = &.{gemDir("mruby-kernel-ext") ++ "src/kernel.c"} },
    .{ .name = "mruby-class-ext", .authority = auth(&.{ .dynamic_code, .introspection, .heap_enumeration }), .c_srcs = &.{gemDir("mruby-class-ext") ++ "src/class.c"} },
    .{ .name = "mruby-pack", .authority = .empty, .c_srcs = &.{gemDir("mruby-pack") ++ "src/pack.c"} },
    .{ .name = "mruby-sprintf", .authority = .empty, .c_srcs = &.{gemDir("mruby-sprintf") ++ "src/sprintf.c"}, .rb_files = &.{gemDir("mruby-sprintf") ++ "mrblib/string.rb"} },
    .{ .name = "mruby-time", .authority = auth(&.{.clock}), .c_srcs = &.{gemDir("mruby-time") ++ "src/time.c"}, .include_dirs = &.{gemDir("mruby-time") ++ "include"} },
    .{ .name = "mruby-struct", .authority = auth(&.{.model_mutation}), .c_srcs = &.{gemDir("mruby-struct") ++ "src/struct.c"}, .rb_files = &.{gemDir("mruby-struct") ++ "mrblib/struct.rb"} },
    .{ .name = "mruby-data", .authority = auth(&.{.model_mutation}), .c_srcs = &.{gemDir("mruby-data") ++ "src/data.c"} },
    .{ .name = "mruby-random", .authority = auth(&.{.entropy}), .c_srcs = &.{gemDir("mruby-random") ++ "src/random.c"} },
    .{ .name = "mruby-math", .authority = .empty, .c_srcs = &.{gemDir("mruby-math") ++ "src/math.c"} },
};

/// The "minimal" set: just enough for `Vm.loadString` with no stdlib
/// extensions beyond core mruby (plus `mruby-eval`, which is tiny and
/// commonly wanted even in constrained builds).
pub const minimal = [_]Gem{
    .{ .name = "mruby-eval", .authority = auth(&.{.dynamic_code}), .c_srcs = &.{gemDir("mruby-eval") ++ "src/eval.c"}, .deps = &.{"mruby-binding"} },
};

/// All gems known to the catalog, used to resolve `-Dwith-gems=...`.
pub const all = standard;

pub fn byName(name: []const u8) ?Gem {
    for (all) |g| if (std.mem.eql(u8, g.name, name)) return g;
    return null;
}

const std = @import("std");

pub const SelectionOptions = struct {
    gem_set: []const u8,
    with: ?[]const u8 = null,
    without: ?[]const u8 = null,
};

pub const SelectionFailure = struct {
    kind: Kind = .none,
    name: []const u8 = "",
    dependent: []const u8 = "",

    pub const Kind = enum {
        none,
        unknown_gem_set,
        unknown_gem,
        unknown_dependency,
        dependency_cycle,
    };
};

pub const SelectionError = std.mem.Allocator.Error || error{
    UnknownGemSet,
    UnknownGem,
    UnknownDependency,
    DependencyCycle,
};

/// Resolve one gem configuration into deterministic dependency order.
/// Explicit exclusions win over inclusions and transitively remove dependents.
pub fn select(
    allocator: std.mem.Allocator,
    options: SelectionOptions,
    failure: *SelectionFailure,
) SelectionError![]Gem {
    failure.* = .{};

    const base: []const Gem = if (std.mem.eql(u8, options.gem_set, "standard"))
        &standard
    else if (std.mem.eql(u8, options.gem_set, "minimal"))
        &minimal
    else {
        failure.* = .{ .kind = .unknown_gem_set, .name = options.gem_set };
        return error.UnknownGemSet;
    };

    var selected_gems: std.ArrayList(Gem) = .empty;
    defer selected_gems.deinit(allocator);
    for (base) |gem| try appendUnique(allocator, &selected_gems, gem);

    if (options.with) |csv| {
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (name.len == 0) continue;
            const gem = byName(name) orelse {
                failure.* = .{ .kind = .unknown_gem, .name = name };
                return error.UnknownGem;
            };
            try appendUnique(allocator, &selected_gems, gem);
        }
    }

    var excluded: std.ArrayList([]const u8) = .empty;
    defer excluded.deinit(allocator);
    if (options.without) |csv| {
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (name.len == 0) continue;
            if (byName(name) == null) {
                failure.* = .{ .kind = .unknown_gem, .name = name };
                return error.UnknownGem;
            }
            if (!containsName(excluded.items, name)) try excluded.append(allocator, name);
        }
    }

    // Complete the dependency closure before applying exclusions so an
    // explicitly excluded dependency cannot be silently re-added later.
    var i: usize = 0;
    while (i < selected_gems.items.len) : (i += 1) {
        for (selected_gems.items[i].deps) |dependency| {
            if (containsName(excluded.items, dependency) or
                containsGem(selected_gems.items, dependency))
            {
                continue;
            }
            const gem = byName(dependency) orelse {
                failure.* = .{
                    .kind = .unknown_dependency,
                    .name = dependency,
                    .dependent = selected_gems.items[i].name,
                };
                return error.UnknownDependency;
            };
            try selected_gems.append(allocator, gem);
        }
    }

    for (excluded.items) |name| removeByName(&selected_gems, name);

    // Removing a dependency removes every dependent, including transitively.
    var changed = true;
    while (changed) {
        changed = false;
        i = 0;
        while (i < selected_gems.items.len) : (i += 1) {
            for (selected_gems.items[i].deps) |dependency| {
                if (containsGem(selected_gems.items, dependency)) continue;
                _ = selected_gems.orderedRemove(i);
                changed = true;
                break;
            }
            if (changed) break;
        }
    }

    var ordered: std.ArrayList(Gem) = .empty;
    errdefer ordered.deinit(allocator);
    const marks = try allocator.alloc(Visit, selected_gems.items.len);
    defer allocator.free(marks);
    @memset(marks, .unvisited);
    for (selected_gems.items, 0..) |_, index| {
        try visit(allocator, selected_gems.items, index, marks, &ordered, failure);
    }
    return ordered.toOwnedSlice(allocator);
}

const Visit = enum { unvisited, visiting, visited };

fn visit(
    allocator: std.mem.Allocator,
    selected_gems: []const Gem,
    index: usize,
    marks: []Visit,
    ordered: *std.ArrayList(Gem),
    failure: *SelectionFailure,
) SelectionError!void {
    switch (marks[index]) {
        .visited => return,
        .visiting => {
            failure.* = .{ .kind = .dependency_cycle, .name = selected_gems[index].name };
            return error.DependencyCycle;
        },
        .unvisited => marks[index] = .visiting,
    }

    for (selected_gems[index].deps) |dependency| {
        const dependency_index = findGem(selected_gems, dependency) orelse {
            failure.* = .{
                .kind = .unknown_dependency,
                .name = dependency,
                .dependent = selected_gems[index].name,
            };
            return error.UnknownDependency;
        };
        try visit(allocator, selected_gems, dependency_index, marks, ordered, failure);
    }

    marks[index] = .visited;
    try ordered.append(allocator, selected_gems[index]);
}

fn appendUnique(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Gem),
    gem: Gem,
) std.mem.Allocator.Error!void {
    if (!containsGem(list.items, gem.name)) try list.append(allocator, gem);
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn containsGem(gems: []const Gem, name: []const u8) bool {
    return findGem(gems, name) != null;
}

fn findGem(gems: []const Gem, name: []const u8) ?usize {
    for (gems, 0..) |gem, index| {
        if (std.mem.eql(u8, gem.name, name)) return index;
    }
    return null;
}

fn removeByName(list: *std.ArrayList(Gem), name: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i].name, name)) {
            _ = list.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

test "selection orders dependencies before dependents" {
    var failure: SelectionFailure = .{};
    const selected = try select(std.testing.allocator, .{
        .gem_set = "minimal",
        .with = "mruby-binding",
    }, &failure);
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqualStrings("mruby-binding", selected[0].name);
    try std.testing.expectEqualStrings("mruby-eval", selected[1].name);
}

test "selection rejects unknown exclusions" {
    var failure: SelectionFailure = .{};
    try std.testing.expectError(error.UnknownGem, select(std.testing.allocator, .{
        .gem_set = "minimal",
        .without = "mruby-not-real",
    }, &failure));
    try std.testing.expectEqualStrings("mruby-not-real", failure.name);
}

test "selection closes audited upstream runtime dependencies" {
    const cases = [_]struct { gem: []const u8, dependency: []const u8 }{
        .{ .gem = "mruby-method", .dependency = "mruby-proc-ext" },
        .{ .gem = "mruby-hash-ext", .dependency = "mruby-array-ext" },
        .{ .gem = "mruby-enumerator", .dependency = "mruby-fiber" },
    };

    for (cases) |case| {
        var failure: SelectionFailure = .{};
        const selected = try select(std.testing.allocator, .{
            .gem_set = "minimal",
            .with = case.gem,
        }, &failure);
        defer std.testing.allocator.free(selected);

        const dependency_index = findGem(selected, case.dependency) orelse
            return error.TestUnexpectedResult;
        const gem_index = findGem(selected, case.gem) orelse
            return error.TestUnexpectedResult;
        try std.testing.expect(dependency_index < gem_index);
    }
}

test "catalog authority is explicit and worker eligible" {
    var sources: [builtin_authority.len + all.len]authority_mod.Source = undefined;
    for (builtin_authority, 0..) |source, i| sources[i] = source;
    for (all, 0..) |gem, i| {
        sources[builtin_authority.len + i] = .{
            .name = gem.name,
            .authority = gem.authority,
        };
    }

    const available = authority_mod.aggregate(&sources);
    try std.testing.expect(available.has(.dynamic_code));
    try std.testing.expect(available.has(.clock));
    try std.testing.expect(available.has(.entropy));
    try std.testing.expect(available.has(.heap_enumeration));
    try std.testing.expect(available.has(.host_output));
    try std.testing.expect(available.workerEligible());
}

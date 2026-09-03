//! Gem catalog for mruby-zig.
//!
//! Mirrors the per-gem data that the upstream Rake build derives from each
//! gem's `mrbgem.rake` + directory contents: C sources under `src/`, Ruby
//! files under `mrblib/` (sorted by path), and any extra build defines.
//! `funcname` (used for generated init functions) is the gem name with
//! `-` replaced by `_`, exactly as `lib/mruby/gem.rb` computes it.

pub const Gem = struct {
    name: []const u8,
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

fn gemDir(comptime name: []const u8) []const u8 {
    return "mrbgems/" ++ name ++ "/";
}

/// The "standard" set: metaprog + the stdlib/stdlib-ext gemboxes minus the
/// io/socket/dir/errno/print gems (excluded for cross-platform builds).
/// Order is dependency-respecting (dependencies init before dependents).
pub const standard = [_]Gem{
    .{ .name = "mruby-metaprog", .c_srcs = &.{gemDir("mruby-metaprog") ++ "src/metaprog.c"} },
    .{ .name = "mruby-method", .c_srcs = &.{gemDir("mruby-method") ++ "src/method.c"}, .rb_files = &.{gemDir("mruby-method") ++ "mrblib/method.rb"} },
    .{ .name = "mruby-binding", .c_srcs = &.{gemDir("mruby-binding") ++ "src/binding.c"} },
    .{ .name = "mruby-eval", .c_srcs = &.{gemDir("mruby-eval") ++ "src/eval.c"}, .deps = &.{"mruby-binding"} },
    .{ .name = "mruby-compar-ext", .rb_files = &.{gemDir("mruby-compar-ext") ++ "mrblib/compar.rb"} },
    .{ .name = "mruby-enum-ext", .rb_files = &.{gemDir("mruby-enum-ext") ++ "mrblib/enum.rb"} },
    .{ .name = "mruby-string-ext", .c_srcs = &.{gemDir("mruby-string-ext") ++ "src/string.c"}, .rb_files = &.{gemDir("mruby-string-ext") ++ "mrblib/string.rb"} },
    .{ .name = "mruby-numeric-ext", .c_srcs = &.{gemDir("mruby-numeric-ext") ++ "src/numeric_ext.c"}, .rb_files = &.{gemDir("mruby-numeric-ext") ++ "mrblib/numeric_ext.rb"} },
    .{ .name = "mruby-array-ext", .c_srcs = &.{gemDir("mruby-array-ext") ++ "src/array.c"}, .rb_files = &.{gemDir("mruby-array-ext") ++ "mrblib/array.rb"} },
    .{ .name = "mruby-hash-ext", .c_srcs = &.{gemDir("mruby-hash-ext") ++ "src/hash_ext.c"}, .rb_files = &.{gemDir("mruby-hash-ext") ++ "mrblib/hash.rb"} },
    .{ .name = "mruby-range-ext", .c_srcs = &.{gemDir("mruby-range-ext") ++ "src/range.c"}, .rb_files = &.{gemDir("mruby-range-ext") ++ "mrblib/range.rb"} },
    .{ .name = "mruby-proc-ext", .c_srcs = &.{gemDir("mruby-proc-ext") ++ "src/proc.c"}, .rb_files = &.{gemDir("mruby-proc-ext") ++ "mrblib/proc.rb"} },
    .{ .name = "mruby-symbol-ext", .c_srcs = &.{gemDir("mruby-symbol-ext") ++ "src/symbol.c"}, .rb_files = &.{gemDir("mruby-symbol-ext") ++ "mrblib/symbol.rb"} },
    .{ .name = "mruby-object-ext", .c_srcs = &.{gemDir("mruby-object-ext") ++ "src/object.c"}, .rb_files = &.{gemDir("mruby-object-ext") ++ "mrblib/object.rb"} },
    .{ .name = "mruby-objectspace", .c_srcs = &.{gemDir("mruby-objectspace") ++ "src/mruby_objectspace.c"} },
    .{ .name = "mruby-fiber", .c_srcs = &.{gemDir("mruby-fiber") ++ "src/fiber.c"} },
    .{ .name = "mruby-enumerator", .rb_files = &.{gemDir("mruby-enumerator") ++ "mrblib/enumerator.rb"} },
    .{ .name = "mruby-enum-lazy", .rb_files = &.{gemDir("mruby-enum-lazy") ++ "mrblib/lazy.rb"}, .deps = &.{ "mruby-enumerator", "mruby-enum-ext" } },
    .{ .name = "mruby-set", .c_srcs = &.{gemDir("mruby-set") ++ "src/set.c"}, .rb_files = &.{gemDir("mruby-set") ++ "mrblib/set.rb"}, .defines = &.{"MRB_USE_SET"}, .deps = &.{ "mruby-hash-ext", "mruby-enumerator" } },
    .{ .name = "mruby-toplevel-ext", .rb_files = &.{gemDir("mruby-toplevel-ext") ++ "mrblib/toplevel.rb"} },
    .{ .name = "mruby-kernel-ext", .c_srcs = &.{gemDir("mruby-kernel-ext") ++ "src/kernel.c"} },
    .{ .name = "mruby-class-ext", .c_srcs = &.{gemDir("mruby-class-ext") ++ "src/class.c"} },
    .{ .name = "mruby-pack", .c_srcs = &.{gemDir("mruby-pack") ++ "src/pack.c"} },
    .{ .name = "mruby-sprintf", .c_srcs = &.{gemDir("mruby-sprintf") ++ "src/sprintf.c"}, .rb_files = &.{gemDir("mruby-sprintf") ++ "mrblib/string.rb"} },
    .{ .name = "mruby-time", .c_srcs = &.{gemDir("mruby-time") ++ "src/time.c"}, .include_dirs = &.{gemDir("mruby-time") ++ "include"} },
    .{ .name = "mruby-struct", .c_srcs = &.{gemDir("mruby-struct") ++ "src/struct.c"}, .rb_files = &.{gemDir("mruby-struct") ++ "mrblib/struct.rb"} },
    .{ .name = "mruby-data", .c_srcs = &.{gemDir("mruby-data") ++ "src/data.c"} },
    .{ .name = "mruby-random", .c_srcs = &.{gemDir("mruby-random") ++ "src/random.c"} },
    .{ .name = "mruby-math", .c_srcs = &.{gemDir("mruby-math") ++ "src/math.c"} },
};

/// The "minimal" set: just enough for `Vm.loadString` with no stdlib
/// extensions beyond core mruby (plus `mruby-eval`, which is tiny and
/// commonly wanted even in constrained builds).
pub const minimal = [_]Gem{
    .{ .name = "mruby-eval", .c_srcs = &.{gemDir("mruby-eval") ++ "src/eval.c"}, .deps = &.{"mruby-binding"} },
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

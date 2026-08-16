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
    .{ .name = "mruby-eval", .c_srcs = &.{gemDir("mruby-eval") ++ "src/eval.c"} },
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
    .{ .name = "mruby-enum-lazy", .rb_files = &.{gemDir("mruby-enum-lazy") ++ "mrblib/lazy.rb"} },
    .{ .name = "mruby-set", .c_srcs = &.{gemDir("mruby-set") ++ "src/set.c"}, .rb_files = &.{gemDir("mruby-set") ++ "mrblib/set.rb"}, .defines = &.{"MRB_USE_SET"} },
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
    .{ .name = "mruby-eval", .c_srcs = &.{gemDir("mruby-eval") ++ "src/eval.c"} },
};

/// All gems known to the catalog, used to resolve `-Dwith-gems=...`.
pub const all = standard ++ minimal;

pub fn byName(name: []const u8) ?Gem {
    for (all) |g| if (std.mem.eql(u8, g.name, name)) return g;
    return null;
}

const std = @import("std");

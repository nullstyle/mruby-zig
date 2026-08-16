//! mruby 4.0.0 source inventory.
//!
//! Paths are relative to the root of the mruby dependency tree. The lists
//! mirror what `tasks/core.rake`, `tasks/mrblib.rake`, and
//! `mrbgems/mruby-compiler/mrbgem.rake` compile in the upstream Rake build.

/// Core interpreter sources compiled into libmruby.
///
/// `src/allocf.c` is intentionally NOT part of this list: mruby-zig provides
/// its own `mrb_basic_alloc_func` so Ruby heap allocations flow through a Zig
/// allocator (see `src/alloc.zig`). The default C realloc wrapper is only
/// linked into the host `mrbc` tool, which never calls into Zig.
pub const core_srcs = [_][]const u8{
    "src/array.c",
    "src/backtrace.c",
    "src/cdump.c",
    "src/class.c",
    "src/codedump.c",
    "src/debug.c",
    "src/dump.c",
    "src/enum.c",
    "src/error.c",
    "src/etc.c",
    "src/fmt_fp.c",
    "src/gc.c",
    "src/hash.c",
    "src/init.c",
    "src/kernel.c",
    "src/load.c",
    "src/mempool.c",
    "src/numeric.c",
    "src/numops.c",
    "src/object.c",
    "src/print.c",
    "src/proc.c",
    "src/range.c",
    "src/readfloat.c",
    "src/readint.c",
    "src/readnum.c",
    "src/state.c",
    "src/string.c",
    "src/symbol.c",
    "src/variable.c",
    "src/version.c",
    "src/vm.c",
};

/// The default allocator, used only by the host `mrbc` tool.
pub const allocf_src = "src/allocf.c";

/// Parser + codegen (`mrbgems/mruby-compiler`); required by `mrb_load_string`.
/// `y.tab.c` and `lex.def` are committed upstream; no bison/gperf needed.
pub const compiler_srcs = [_][]const u8{
    "mrbgems/mruby-compiler/core/codegen.c",
    "mrbgems/mruby-compiler/core/y.tab.c",
};

/// The `mrbc` cross-compiler tool (`mrbgems/mruby-bin-mrbc`). Its checked-in
/// empty `mrb_init_mrblib`/`mrb_init_mrbgems` stubs break the bootstrap cycle.
pub const mrbc_srcs = [_][]const u8{
    "mrbgems/mruby-bin-mrbc/tools/mrbc/mrbc.c",
    "mrbgems/mruby-bin-mrbc/tools/mrbc/stub.c",
};

/// Core Ruby-level library, sorted by filename (load order matters).
pub const mrblib_rb_files = [_][]const u8{
    "mrblib/10error.rb",
    "mrblib/array.rb",
    "mrblib/compar.rb",
    "mrblib/enum.rb",
    "mrblib/hash.rb",
    "mrblib/kernel.rb",
    "mrblib/numeric.rb",
    "mrblib/range.rb",
    "mrblib/string.rb",
    "mrblib/symbol.rb",
};

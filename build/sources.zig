//! mruby 4.1.0-rc2 source inventory.
//!
//! Paths are relative to the root of the mruby dependency tree unless a
//! list says otherwise. The lists mirror what `tasks/core.rake`,
//! `tasks/mrblib.rake`, and `mrbgems/mruby-compiler/mrbgem.rake` compile
//! in the upstream Rake build. 4.1 moved the parser to Prism (a separate
//! pinned dependency for its hand-written sources; the template-generated
//! sources are vendored under `vendor/prism` because generating them
//! requires Ruby).

/// Core interpreter sources compiled into libmruby.
///
/// `src/allocf.c` is intentionally NOT part of this list: mruby-zig provides
/// its own `mrb_basic_alloc_func` so Ruby heap allocations flow through a Zig
/// allocator (see `src/alloc.zig`). The default C realloc wrapper is only
/// linked into the host `mrbc` tool, which never calls into Zig.
pub const core_srcs = [_][]const u8{
    "src/array.c",
    "src/backtrace.c",
    "src/class.c",
    "src/codedump.c",
    "src/debug.c",
    "src/dump.c",
    "src/enum.c",
    "src/error.c",
    "src/etc.c",
    "src/fp_uscale.c",
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
    "src/readint.c",
    "src/readnum.c",
    "src/state.c",
    "src/string.c",
    "src/symbol.c",
    "src/unicase.c",
    "src/variable.c",
    "src/version.c",
    "src/vm.c",
};

/// The default allocator, used only by the host `mrbc` tool.
pub const allocf_src = "src/allocf.c";

/// Parser + codegen glue (`mrbgems/mruby-compiler/src`). Prism replaced
/// bison: there is no y.tab.c. `mruby_compat.c` is excluded from the host
/// `mrbc` link exactly as upstream's rake does (the tool links without the
/// objects that reference gem initialization, replacing 4.0's stub.c).
pub const compiler_srcs = [_][]const u8{
    "mrbgems/mruby-compiler/src/ccontext.c",
    "mrbgems/mruby-compiler/src/cdump.c",
    "mrbgems/mruby-compiler/src/codedump.c",
    "mrbgems/mruby-compiler/src/codegen.c",
    "mrbgems/mruby-compiler/src/compile.c",
    "mrbgems/mruby-compiler/src/debug.c",
    "mrbgems/mruby-compiler/src/diagnostic.c",
    "mrbgems/mruby-compiler/src/dump.c",
    "mrbgems/mruby-compiler/src/irep.c",
    "mrbgems/mruby-compiler/src/mrc_presym.c",
    "mrbgems/mruby-compiler/src/parser_util.c",
    "mrbgems/mruby-compiler/src/pool.c",
};

/// `mruby_compat.c` (linked into the library, never the host mrbc).
pub const compiler_compat_src = "mrbgems/mruby-compiler/src/mruby_compat.c";

/// Prism's hand-written sources, relative to the root of the pinned prism
/// dependency (see build.zig.zon; the submodule is empty in release
/// tarballs).
pub const prism_srcs = [_][]const u8{
    "src/encoding.c",
    "src/options.c",
    "src/pack.c",
    "src/prism.c",
    "src/regexp.c",
    "src/static_literals.c",
    "src/util/pm_buffer.c",
    "src/util/pm_char.c",
    "src/util/pm_constant_pool.c",
    "src/util/pm_integer.c",
    "src/util/pm_list.c",
    "src/util/pm_memchr.c",
    "src/util/pm_newline_list.c",
    "src/util/pm_string.c",
    "src/util/pm_strncasecmp.c",
    "src/util/pm_strpbrk.c",
};

/// Prism's template-generated sources, relative to this repository's
/// `vendor/prism/<pin>` root. Upstream regenerates them with Ruby at build
/// time; see vendor/prism/c0e37816/MANIFEST.md.
pub const prism_gen_srcs = [_][]const u8{
    "src/diagnostic.c",
    "src/node.c",
    "src/prettyprint.c",
    "src/serialize.c",
    "src/token_type.c",
};

/// The `mrbc` cross-compiler tool (`mrbgems/mruby-bin-mrbc`). 4.1 removed
/// the 4.0 stub.c bootstrap; the link omits gem_init and mruby_compat
/// objects instead (mruby-bin-mrbc/mrbgem.rake).
pub const mrbc_srcs = [_][]const u8{
    "mrbgems/mruby-bin-mrbc/tools/mrbc/mrbc.c",
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

# Changelog

## 0.1.0 (unreleased)

Initial implementation.

- Full rake-free build of mruby 4.0.0 inside `zig build`: Zig-ported presym
  scanner/emitter, host `mrbc` built with `zig cc`, cdump bytecode
  generation for mrblib and gem Ruby code, generated `gem_init` registry.
- mruby source fetched as a hash-pinned `build.zig.zon` tarball dependency;
  no Ruby toolchain required at build time.
- Zig-side `mrb_basic_alloc_func` override (process-global allocator with
  live-bytes/allocs observability; 16-byte header per allocation).
- Safe layer: `Vm` (protected eval/call, classes, globals, ivars, symbols,
  raise, GC arena scopes), `Value` (typed accessors), `Class.defineMethod`
  with `mrb_get_args`-style typed marshalling (`i f b n o z S s & * |`),
  `data.DataType` for wrapping Zig pointers, exception details
  (`RubyError`), output redirection to `std.Io.Writer`.
- C ABI shim (`src/shim.c`) exposing mruby's macro-only inline APIs; Zig
  bindings (`src/c.zig`) keep `mrb_state` opaque.
- Standard gem set (28 gems) plus `minimal` preset; `-Dwith-gems` /
  `-Dwithout-gems` adjustment.
- 19 Zig tests including embedded Ruby integration suites and an eval tool
  (`zig build run-repl -- -e 'expr'`).

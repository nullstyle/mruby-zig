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
- 26 Zig tests including embedded Ruby integration suites, concurrent-VM
  and regression coverage, and an eval tool
  (`zig build run-repl -- -e 'expr'`).

Code-review hardening:

- Gem dependencies are validated at configure time: `-Dwith-gems` pulls in
  dependencies, `-Dwithout-gems` cascade-removes dependents (fixes the
  `minimal` set link failure and silent boot failures from invalid sets).
- `Vm.defineClass`/`defineModule` run under `mrb_protect_error` (no
  unprotected longjmp path remains in the safe layer); `Vm.init` failure
  paths no longer leak the interpreter state and expose the Ruby-level
  reason via `Vm.lastInitFailure()`.
- `convert.toValue` returns `error.Overflow` for unrepresentable integers
  (instead of panicking); `Vm.intValue` saturates; `Value.dupeString` added
  for owned string copies.
- `setGlobal`/`setIvar`/`setOutputWriter` propagate errors instead of
  silently no-op'ing; `puts` prints array elements one per line (CRuby
  semantics); `mrz_exc_set` ignores immediate values.
- Presym scanner octal-escape handling now matches `presym.rb` exactly
  (`\0` + up to three digits).

Sandboxing (v8-isolate parity and beyond):

- `mruby.sandbox.Isolate`: private heap per isolate with enforced limits —
  deterministic instruction gas, wall-clock deadlines, soft/hard
  per-isolate memory caps with escalation, and call-depth ceilings.
- Thread-safe `terminate()` delivered via the per-instruction fetch hook
  (`MRB_USE_DEBUG_HOOK`): ensure blocks run, rescue cannot suppress, and
  execution past a termination is bounded. Distinct Zig errors
  (`ScriptTerminated`, `DeadlineExceeded`, `GasExhausted`,
  `MemoryLimitExceeded`, `CallDepthExceeded`).
- Capability model: strip eval/send/introspection/ObjectSpace, freeze the
  core object model (`def` → FrozenError), pin RNG seed and clock for
  reproducible runs.
- `sandbox.compile`/`runImage`: precompiled irep snapshots for cheap
  mass-spawn; limits apply to image runs.
- `Isolate.stats()` (instructions, peak/live memory, peak depth, live
  objects, wall time) and an allocator `on_limit` callback; concurrent
  isolates with independent policies tested on separate threads.

Platform fixes:

- Linux builds link again. `mrbconf.h` enables `MRB_USE_ETEXT_RO_DATA_P` on
  every `__linux__` target, making `mrb_ro_data_p()` compare pointers against
  the `etext`/`edata` linker symbols that Zig's linker does not supply — every
  Linux link failed with `undefined symbol: etext`. The build now defines
  `MRB_NO_DEFAULT_RO_DATA_P` on Linux (mruby's documented fallback for
  platforms that cannot answer the question), applied consistently to the core
  sources, the generated gem inits, and `shim.c`.
- Fixed an integer-overflow panic in per-isolate memory accounting. The
  in-place-remap branch of `mrb_basic_alloc_func` computed
  `live_bytes - old + size` directly, which underflows when a buffer allocated
  before the cell was entered is reallocated inside it. It now uses
  `projectedLive`, the guard the copy branch already used. Linux-only in
  practice: `rawRemap` succeeds far more often there, so macOS almost always
  took the copy path.

CI and developer tooling:

- Gem-set tests now distinguish the complete standard fixtures from tests that
  are valid for trimmed configurations, so `minimal` and dependency-cascade
  builds exercise their compatible test coverage without requiring omitted
  gems. The REPL exits nonzero on evaluation or inspection errors, making CI
  smoke checks trustworthy.
- Added a checked-in `act` configuration and `mise run ci` task for running all
  Linux GitHub Actions jobs locally, including on Apple Silicon.

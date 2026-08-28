# Changelog

## 0.3.0 (2026-08-28)

Typed artifacts and portable value transfer:

- Added `artifact.RiteImage` plus `sandbox.compileRite` and
  `Isolate.runRite`. The stable outer envelope checks length, SHA-256
  integrity, generated mruby/RITE compatibility, and optional exact
  application identity before executing under the normal sandbox policy.
  `source_name` gives compiled code a stable `__FILE__`; embedded NUL is
  rejected.
- Added bounded `artifact.StateCapsule` export/import for nil, booleans,
  signed 64-bit integers, binary64 floats, symbols, exact-core Strings,
  Arrays, and Hashes. Cycles, aliases, insertion order, frozen container state,
  and non-proc Hash defaults are preserved without guest dispatch.
- StateCapsule v1 restricts Hash keys to Integer, Float, Symbol, and frozen
  exact-core String. Unsupported values, behavioral container state, default
  procs, foreign roots, malformed graphs, schema mismatch, and resource limits
  produce typed errors with best-effort artifact diagnostics.
- Added optional application schemas and policy-cached artifact limits.
  Per-operation capsule limits may tighten but cannot relax the Isolate's
  acceptance policy. Owned artifacts contain only encoded bytes and must be
  destroyed with the allocator used to create them.
- Added symmetric export/import Hash-work preflight with non-relaxable pair,
  probe, and String-comparison ceilings. Audited generated mruby patches give
  full-width Integer keys numeric hashes and Symbols stable name-byte hashes;
  their semantic markers participate in RITE compatibility identity.
- Added deterministic non-blocking same-Isolate operation admission across
  guest execution and artifact operations. Invalid typed RITE is rejected
  without changing Ruby error, lifetime timing, gas, capability, or
  termination state; `terminate()` remains lock-free.
- Added a coverage-guided StateCapsule parser target with stable valid and
  malformed corpus seeds, plus a golden producer/consumer subprocess fixture
  that verifies byte stability and restoration into a separate OS process.
- Deprecated raw `sandbox.compile` and `Isolate.runImage` for one compatibility
  cycle. They still work but lack the typed envelope's complete compatibility
  and application checks.

## 0.2.0 (2026-08-28)

Gas policy and reusable Isolates:

- Added `Limits.gas` with `.unlimited`, `.per_isolate`, and `.per_execution`
  policies. `.per_isolate` supplies one sticky lifetime allowance;
  `.per_execution` starts a fixed-size generation for each admitted outermost
  `run`, `runImage`, or `call`, while rejected preflights do not advance the
  generation and nested re-entry shares the active generation.
- Gas-only `GasExhausted` under `.per_execution` no longer poisons the
  Isolate. After the call fully unwinds, the next outer execution receives a
  fresh generation on the same Ruby heap. Guest state and completed `ensure`
  effects survive; interrupted computation is neither resumed nor rolled
  back. Every non-gas termination and `.per_isolate` exhaustion remain sticky.
- Added `GasStats` through `Isolate.stats().gas`: scope, generation, limit,
  charged use, remaining gas, observed exhaustion, and the wider
  `observed_instructions` count that includes bounded termination-delivery
  work. Existing `Stats.instructions` remains the saturating lifetime fetch
  count.
- Deprecated `Limits.instructions`; it remains source-compatible and maps
  exactly to `.gas = .{ .per_isolate = N }`. Setting both fields returns
  `error.ConflictingGasPolicy` before allocating an mruby heap.
- Sandbox `lastError()` diagnostics now use rooted, inert exception metadata.
  Reading `message()` or `className()` executes no guest methods, starts no gas
  generation, and changes no instruction statistics. Policy terminations
  expose no `lastError()`.
- Gas renewal is policy-scoped rather than exposed as a mutable `resetGas`
  operation. `.per_isolate` retains Shopify's fixed cumulative scope, while
  mruby-zig keeps its own bounded guest-unwind and termination semantics and
  adds reusable per-request Isolates without a reset/invoke race.

Migration:

- Existing `.instructions = N` callers require no immediate source change and
  retain cumulative, sticky behavior. Prefer
  `.gas = .{ .per_isolate = N }` in new code.
- Use `.gas = .{ .per_execution = N }` only when the same Isolate should
  accept another request after gas exhaustion. Replace the Isolate after any
  other policy termination. Gas renewal does not renew the lifetime wall-time,
  memory, or call-depth policy; any of those can still reject a later request.
- Do not set `instructions` and `gas` together.
- Read `stats().gas.?.exhausted`, not merely `remaining == 0`: a program may
  finish exactly at zero without a later fetch observing exhaustion.
- Sandbox error text now reflects the stored exception message and real cached
  class name, not guest-overridden diagnostic methods.

## 0.1.0 (2026-08-26)

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
  reproducible runs. The object-model freeze is also public and movable:
  `Isolate.sealModel()` applies the same class list at a host-chosen time,
  the two-phase form for hosts that load a script image on the unfrozen
  model (so its top-level class definitions land) and seal right after.
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

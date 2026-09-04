# Changelog

## Unreleased

Cross-version artifact fixtures:

- Checked-in byte fixtures produced by the v0.3.0 tag
  (`src/tests_artifacts/`, with a provenance manifest and regeneration
  recipe) pin cross-version behavior: a v0.3.0 RITE image is rejected
  with `IncompatibleRiteImage` — its compatibility fingerprint predates
  later presym and semantic-identity changes — while a v0.3.0 state
  capsule restores completely into the current build, demonstrating that
  capsule format v1 is forward-compatible by design.

Sanitizer and platform coverage:

- Added `-Dsanitize-c`, wiring C undefined-behavior detection into every
  module; CI runs the suite in a ReleaseFast + `-Dsanitize-c=true` build
  where detection is otherwise off.
- Added a best-effort, non-blocking Windows runtime CI job (Debug and
  ReleaseSafe suites plus the example binaries) — Windows stays
  compile-only-supported until that job is made blocking.
- Added weekly scheduled sustained fuzzing (2M StateCapsule executions,
  also dispatchable manually via `workflow_dispatch`).

Performance and size baselines:

- Added `zig build run-bench` (`tools/bench.zig`): VM and isolate lifecycle,
  cold evaluation vs cached RITE execution, Zig->Ruby call-loop and
  Ruby->Zig host-callback throughput, the gas-hook overhead ratio,
  StateCapsule export/import of a fixed 200-entry graph, and the one-shot
  worker-process roundtrip (skipped where the platform or deployment lacks
  the helper). Timing uses the sandbox's monotonic clock; results are
  informational, and CI records a Linux run per push without gating on it.
- Added [docs/benchmarks.md](docs/benchmarks.md) with methodology,
  reference observations (aarch64-macos, ReleaseSafe), and the
  binary-size baseline procedure: standard quickstart 1.79 MB vs minimal
  1.29 MB, worker 1.96 MB / 1.49 MB. Notable findings: the instruction
  hook costs ~1.03x, cached RITE is only ~9% cheaper than cold eval, and
  capsule export runs ~1.7x import (the export-side reparse the
  assessment flagged as the main optimization target).

Auditable authority and fail-closed workers:

- Core, compiler, and every catalog gem now declare conservative
  Ruby-visible authority. `mruby.features.authority` exposes the aggregate and
  per-source attribution, `authorityForGem` supports direct gem queries, and
  the manifest distinguishes linked/available authority from the entry points
  left effective by an Isolate policy.
- Sandbox method masks, constant removal, and model freezing now consume
  centralized exact-target audit tables with inventory-driven tests. A pinned
  `ObjectSpace` reference can no longer bypass the object-space gate. A pinned
  `random_seed` also masks reseeding and fresh `Random` construction after
  initial seeding, preventing guest code from restoring time/address-derived
  state. A pinned clock masks current-time `Time` construction after replacing
  `Time.now`.
- Generic worker builds now fail closed when linked authority includes
  filesystem, network, process, environment, or arbitrary native-host access.
  New feature flags expose target support, profile eligibility, explicit
  ambient-authority opt-in, and the combined result. The
  `-Dallow-worker-ambient-authority=true` override acknowledges an audited
  exception; it does not provide syscall, filesystem, network, or user
  confinement. Application bootstrap callbacks remain outside the package
  authority catalog and are absent from the generic helper.

One-shot worker processes:

- Added `mruby.worker.runRite`, a synchronous fresh-process boundary for one
  typed RITE image, an optional StateCapsule exposed as `$input`, and a typed
  StateCapsule result. Ruby exceptions, sandbox/process limits, and artifact
  rejection are structured outcomes with owned diagnostics; transport,
  protocol, spawn, and helper-setup failures remain errors.
- The installed `mruby-worker` helper uses a bounded, versioned private wire
  format, receives an empty environment, separates guest stdout from the
  protocol, applies CPU/core limits before body allocation, supports finite
  Linux `RLIMIT_AS`, and is hard-killed and reaped under one parent boot-clock
  deadline. The controller revalidates every returned StateCapsule before
  exposing it. Its `posix_spawn` seam also keeps failed launches from leaking
  pipes or zombies. A backing allocation failure under `RLIMIT_AS` remains a
  typed process-address-space limit even if Ruby rescues its immediate
  `NoMemoryError`.
- Added `mruby.features.worker_process_supported`, integration coverage for
  typed transfer, exceptions, artifact/gas failures, and hard timeout cleanup,
  plus a deployment and threat-model guide. The worker tier supports Linux and
  macOS, but does not yet provide syscall, filesystem, network, or user-identity
  confinement.

Post-seal host-operation accounting:

- Allocating host operations invoked through the sealed `Isolate` interface
  now run under the same non-blocking operation lock and allocator attribution
  as guest execution. Their mruby-heap allocations contribute to
  `live_memory_bytes` and `peak_memory_bytes`, respect the isolate's sticky
  soft/hard memory caps, and surface a crossed cap as
  `error.MemoryLimitExceeded`. Host-allocator scratch and root-registry
  bookkeeping remain host-owned and are not included in the mruby quota.
- This accounting applies to methods on `Isolate` itself (including value and
  collection construction, globals, symbols, and rooting). Direct operations
  on raw `Value`, `Array`, and `Hash` handles retain their existing VM-level
  threading and accounting contract.
- Threaded tests now return worker failures to the joining test instead of
  relying on `Thread.join()` (which discards a worker's error result). This
  exposed and fixed a stale policy fixture, and capability tests now pin the
  `Enumerable#reduce(:+)` dependency on the `send` grant.

Bootstrap/execution typestate for isolates:

- `sandbox.BootstrapIsolate.spawn(policy)` opens the bootstrap window: the
  raw `vm` for defining host classes and methods, loading definition-time
  code, and the two-phase `sealModel`. `seal()` consumes the handle and
  returns the execution `Isolate`; paired `defer boot.deinit()` /
  `defer iso.deinit()` are always safe because a consumed bootstrap handle
  deinits as a no-op.
- The execution `Isolate` no longer exposes the raw VM. Value construction
  (`intValue`, `floatValue`, `stringValue`, `boolValue`, `nilValue`,
  `array`, `hash`), symbols (`internSymbol`, `symbolName`), rooting
  (`root`, `arenaScope`), and `callWithOptions` are first-class
  delegations, serialized with guest execution — cross-thread construction
  now reports `IsolateThreadBusy` instead of racing the interpreter.
- The policy is applied strictly at `seal()` (no lazy first-run
  application), so capability setup gas and deadlines are always accounted
  at the seal boundary. A consumed or unsealed bootstrap handle used out of
  contract fails loudly (`error.BootstrapHandleConsumed`, panic on `vm`).
- `sandbox.internalVm(iso)` provides test-build-only raw access for
  diagnostics (GC forcing, allocator probing); it does not exist in
  library builds.

Documentation reorganization:

- The README is now a lean overview plus quickstart; the detailed guides
  live in `docs/`: getting-started (build options, gems, allocator,
  feature manifest), safe-api (embedding, lifetimes, threading),
  sandboxing (policy, limits, threat model), artifacts (RITE and state
  capsules, compatibility policy), platforms (support matrix and CI
  coverage), and maintenance (the Zig build of mruby, the audited hash
  patch, upgrade and release procedures). `docs/` ships with the package.
- Added a runnable sandbox example (`zig build run-sandbox`) covering a
  restricted policy, host bootstrap + seal, gas exhaustion with recovery,
  and host access between runs; CI builds and executes it like the other
  examples.
- Added `Class.fromValue`, the supported way for a `defineClassMethod`
  callback to reach its defining class (`self`) without process-global
  storage; the host_functions example no longer uses a static class slot.

Isolate host operations between executions:

- Added `Isolate.getGlobal`, `setGlobal`, and `clearError`: the locked,
  ownership-checked surface for seeding and observing interpreter state
  between runs. They serialize with guest execution and artifact operations
  (re-entrant use from a callback returns `IsolateThreadBusy`), `setGlobal`
  rejects foreign-VM values, and `clearError` drops both the pending Ruby
  exception and the retained `lastError` view. Ordinary host introspection
  no longer requires raw `iso.vm` access; the raw field remains the
  bootstrap-window escape hatch ending at `seal()`.

Comptime-derived method signatures:

- `Class.defineMethod`, `defineClassMethod`, and `defineModuleFunction` now
  derive the Ruby-facing argument protocol from the Zig callback's parameter
  types, so the marshalling and the mruby arity can never disagree. The
  callback shape `(vm: *Vm, self: Value, ...)` is validated at compile time,
  as is parameter ordering (required, then optional, then `Rest`, then
  `Block`).
- Optional arguments are declared as Zig optionals (`?i64`, `?[]const u8`,
  ...): they map to the `mrb_get_args` optional section and receive `null`
  when the caller omitted them — absence is now distinguishable from a
  passed default.
- Added the `Block` parameter marker (`.value` + `isPresent`) replacing the
  bare `&`-spec `Value` in derived signatures.
- The explicit-format variants are renamed `defineMethodRaw`,
  `defineClassMethodRaw`, and `defineModuleFunctionRaw` for protocols the
  derived form does not model (the `S` String-value spec) and for
  zero-value-default optionals.

Generated comptime feature manifest:

- Added `mruby.features`, generated per build from the resolved gem
  selection and target: `gems`/`hasGem` (dependency-ordered selection),
  `gem_set`/`custom_selection`, `mruby_version`, the RITE compatibility
  identity (`rite_compatibility_fingerprint` and hex/epoch/version
  re-exports), `pointer_bits`/`endian` target constraints, and
  `has_compiler`/`has_debug_hook`/`sandbox_supported` availability flags.
  Applications can use ordinary `comptime` branches instead of duplicating
  build knowledge or discovering features at runtime.
- Manifest tests cross-check `hasGem` against the profile-derived test
  flags across the standard, minimal, and customized gem selections.

Deny-by-default sandbox policy with explicit trust presets:

- `Policy.capabilities` is now deny-by-default: the zero value strips `eval`,
  `send`, introspection, and `ObjectSpace`, so a policy constructed without a
  preset is the fail-closed floor and capabilities added in future releases
  default to denied. Plain compute scripts run unchanged.
- Added `Policy.trusted(base)` (grants the ambient language capabilities on
  top of `base`'s limits/artifacts) and `Policy.restricted(base)` (the
  deny-by-default floor plus `freeze_object_model`; discards language grants
  from `base`).
- The policy is resolved completely at spawn — gas scope and limit, memory
  caps, wall budget, call-depth ceiling, capability snapshot, and artifact
  acceptance — and `Isolate` no longer retains a mutable `policy` field.
  Post-spawn edits to a host-held `Policy` value have no effect (previously
  `limits.wall_time_ns`, `limits.call_depth`, and `capabilities` were still
  read live after spawn while gas and memory were not).
- Added `Isolate.seal()`: applies the policy's capabilities through the same
  preflight bracket as an execution (admission, deadline start, pending
  termination; setup gas is charged to the current generation exactly as lazy
  first-run setup would be), making the bootstrap window explicit. Idempotent,
  and rejected with `error.IsolateThreadBusy` from inside a host callback.
  The first `run`/`call` still seals lazily for compatibility.
- Fixed a test-only undefined-behavior regression: the allocator default test
  compared `c_allocator`'s `undefined` context pointer, which failed
  nondeterministically under `ReleaseSafe`. CI now runs the test suite under
  `-Doptimize=ReleaseSafe` in addition to `Debug`.

Production-safe Zig API:

- Potentially allocating or raising safe-layer operations are now explicitly
  fallible, including value construction, method/constant definition, data
  wrapping, instance-variable reads, output hook installation, and
  `Isolate.sealModel`.
- All supported mruby operations that may raise now execute behind C protection
  trampolines. Ruby `longjmp` never crosses a live Zig frame, including method
  argument decoding, callback error construction, sandbox setup, compilation,
  and instruction-hook termination delivery. Void operations return an
  immediate result from those trampolines, avoiding ignored GC-arena roots.
- `Value` and `Class` handles carry interpreter ownership. Calls, assignments,
  superclass/constant definition, data wrappers, and callback returns reject
  cross-VM handles with `error.ForeignValue`.
- `Vm.loadString` and the RITE compilers reject embedded NUL bytes instead of
  silently compiling only a source prefix. Error diagnostics preserve the
  pending Ruby exception until the next safe-layer operation.
- Capability stripping now installs protected, non-dispatching method masks;
  policy setup neither requires nor executes guest `method_undefined` hooks.
- Gem selection is a tested, fallible dependency resolver with deterministic
  topological ordering and explicit diagnostics for unknown options.
- Added `-Dallocator=libc|arena` build profiles and a compile-only `check`
  step. The legacy `-Dstdlib-gems` spelling maps to the current standard or
  minimal gem set and rejects conflicts with `-Dgem-set`.
- Added `Vm.loadStringWithOptions` source names, so `__FILE__`, diagnostics,
  and backtraces carry host-provided source identity.
- Added `Vm.callWithOptions` for passing Ruby blocks and removed the fixed
  eight-positional-argument limit from `Vm.call`.
- Added direct nested class/module and constant operations on `Class`, with
  protected exception handling and VM ownership checks.
- Added typed `Array` and `Hash` handles, construction and controlled mutation,
  conversion integration, and a hash lookup result that distinguishes missing
  keys from present Ruby `nil`.
- Added `Vm.root` and `RootedValue` for values that must outlive a GC arena
  scope. Roots have explicit release, enforce VM ownership, and safely
  reference-count duplicate roots for the same mruby object.
- Numeric and Boolean conversion semantics are now explicit: `Vm.intValue`
  returns `error.Overflow`, `Vm.saturatingIntValue` opts into clamping, finite
  Float conversions report destination overflow, and
  `convert.fromValue(bool, ...)` accepts only Ruby `true` or `false`.
- `RubyError.message` and `className` now take a caller-selected allocator and
  report allocation or diagnostic failures instead of returning an ambiguous
  empty string. `RubyError.details` captures owned class, message, and bounded
  backtrace data; sandbox diagnostics use inert metadata without guest
  dispatch.

Migration:

- Isolate creation becomes two-phase:
  `var boot = try sandbox.BootstrapIsolate.spawn(policy); const iso = try boot.seal();`.
  Move every `iso.vm` use before the seal (class/method definition,
  definition-time loads, receiver construction); replace post-seal raw
  construction with the `Isolate` constructors (`iso.intValue`,
  `iso.stringValue`, `iso.array`, ...). `Isolate.seal` and the post-seal
  `Isolate.sealModel` are gone — freezing during bootstrap is
  `BootstrapIsolate.sealModel`, before `seal()`.
- Capability setup is no longer lazy: it is charged at `seal()`, so tests
  asserting zero instructions before the first execution of a sealed
  isolate should compare before/after a rejected execution instead.
- Rename `defineMethod`/`defineClassMethod`/`defineModuleFunction` calls
  that pass an explicit format string to the `...Raw` spellings. Where the
  format is derivable (`i`, `f`, `b`, `n`, `o`, `z`, `s`, `*`), drop the
  format argument instead and let the parameter types drive it; block
  callbacks change their parameter from `Value` to `Block` (use `.value`
  and `.isPresent`). Code that relied on zero-value defaults for omitted
  optional specs must stay on the `Raw` form or switch to `?T` parameters
  and handle `null` explicitly.
- Sandbox policies that relied on the old capability defaults must grant them
  explicitly: wrap the policy in `Policy.trusted(...)` (ambient language
  capabilities on) or set individual `capabilities` fields. Scripts that only
  compute need no change. `Isolate.spawn(.{})` now yields the stripped floor
  rather than full ambient authority.
- Remove any post-spawn writes to `iso.policy`; resolution happens entirely
  at spawn and the field no longer exists.
- Call `Isolate.seal()` after registering host methods when you want the
  capability masks (including `freeze_object_model`) applied at an explicit
  boundary instead of lazily at the first execution.
- Add `try`/`catch` around `Vm.intValue`, `floatValue`, and `stringValue`;
  `Class.defineMethod`, `defineClassMethod`, `defineModuleFunction`, and
  `defineConst`; `data.DataType.wrap`; and `Isolate.sealModel`.
- Pass an allocator to `RubyError.message` and `RubyError.className`, and free
  the result with that same allocator. Use `Vm.saturatingIntValue` if the old
  clamping behavior is required. Code that converted arbitrary Ruby truthy or
  falsey values to Zig `bool` must now check truthiness explicitly or pass an
  actual Ruby Boolean.
- Replace `DataType.wrap(mrb, class_ptr, ptr)` with `DataType.wrap(class, ptr)`
  and `DataType.unwrap(mrb, value)` with `DataType.unwrap(value)`.
- Handle the new error union from `Vm.getIvar`. Use `Class.asValue()` when a
  class/module object is needed as a `Value`.

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

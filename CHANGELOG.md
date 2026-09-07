# Changelog

## Unreleased

Experimental explicit effects (see docs/effects.md):

- The durable example now pins an explicit application identity in its ledger
  and demonstrates one controlled upgrade from `inventory/v1` to `inventory/v2`
  (state gains an explicit OutOfStock rejection counter). `Host.open` takes one
  confined worker per build-time-known application version; `Host.upgrade`
  publishes the new state, revision, active identity, and provenance in one
  transaction, resolves retries and lost replies from the committed upgrade
  record, and never rewrites receipts, admissions, outbox rows, or notification
  identities. Historical replay dispatches each turn to its original bundle,
  contracts, and worker. Opening a different application, label, or numeric
  profile fails closed at open; source ledger schema is now 3, and schema-1
  and schema-2 ledgers are rejected unchanged without migration. See
  docs/effects-durable.md.

- The durable example now exposes typed `Stock.reserve` and
  `Notifications.reservation_created` operations. Host-owned SQL, payloads, and
  business invariants bind every successful turn to its admitted request.
  Whole-turn/numeric input validation precedes durable admission, contract
  digests bind retry fingerprints, and terminal validation also covers cached
  replies. Crash recovery includes partial writes inside a domain operation.
  Source schema 2 rejects schema-1 ledgers without changing them; migration
  remains explicit. See docs/effects-durable.md.

- Opt-in `-Deffects-integer64=true` requires strict mode and a 64-bit target,
  compiling Ruby without Float and with fixed signed 64-bit integers. Float
  literals always fail parsing. Out-of-range integer literals fail compilation
  when they would emit a value; unused or unreachable literals may be eliminated.
  Overflowing arithmetic raises ordinary rescuable Ruby errors. Checked parsing,
  rounding, shifts, and full-width comparisons share the pinned numeric policy. Runtime admission
  rejects Float anywhere in state, input, effect data, or terminal graphs;
  invalid adapter outcomes discard staged work. VM-free structural codecs
  preserve Float artifacts for inspection. Profile identity prevents mixing
  incompatible CodeDB/RITE artifacts, workers, and receipts; integer-only
  StateCapsules remain transferable. `run-effects-integer64` emits actual canonical
  effect and terminal capsules plus error classes for platform comparison.
  See docs/effects-integer64.md for guarantees and remaining trust limits.
- All strict profiles fix full-width integer sort comparison and reserve enough
  space to format the minimum signed integer in base two, with regressions in
  both ordinary strict and integer64 builds.

- Whole-turn contracts constrain starting state, input, result, and next state.
  Admission snapshots and validates contracts before VM/transaction startup;
  terminal failures discard staged work. Runtime/broker validation, receipt
  identity, worker handshake, and owned diagnostics share the same shapes.
  The reservation example exercises both operation and whole-turn contracts.
- Effects examples explicitly re-raise caught exceptions with `raise error`.
  Regression tests preserve rejection identity, message, code, and ensure
  behavior during record/replay; general bare `raise` retains mruby's documented
  semantics.
- Optional shared operation contracts validate arguments before adapters and
  results/rejections before acceptance in live, record, and replay execution.
  The worker broker independently validates requests and full receipt records.
  Schema digests bind replay/application identity; mismatches remain fatal after
  Ruby rescue and include owned side/path/kind diagnostics. The first domain
  example, `run-effects-reservation -Deffects-strict=true`, stages stock, state,
  and notification intents under explicit commit without a SQL dependency.
- Strict workers transport bounded owned diagnostics through private protocol
  1.3: Ruby exception metadata, native debug locations, denied operations,
  adapter failures, and replay mismatches. The broker supplies trusted origin
  and phase labels. Inert capture and byte-escaped JSON formatting invoke no
  Ruby methods; the existing execution errors and commit rules are unchanged.
- `mruby-effects-inspect` and `effect.Inspection` validate stored receipt graphs
  and produce bounded JSON summaries without linking a Ruby VM or running
  adapters. `test-effects-inspect` exercises the library and CLI in ordinary
  and strict builds. Stored receipt formats are unchanged.
- `run-effects-durable` / `test-effects-durable` add a disk-backed reference
  host for strict workers. Durable ID admission prevents conflicting reuse;
  a single business transaction retains SQL changes, next Ruby state, the
  verified receipt, and outbox. Committed retries return the original result
  without workers or callbacks. A separate local recipient deduplicates stable
  intents; real SIGKILL tests cover preparation, commit, and delivery recovery.
  Requires `-Deffects-strict=true -Dsqlite-effects=true`; see
  docs/effects-durable.md for the persistence contract and process-crash scope.
- The optional SQLite dependency is pinned to 3.51.3, including the WAL reset
  corruption fix needed by the durable example. Ordinary library builds do not
  link it. Durable connections require WAL/FULL and validate source/recipient
  roles, namespaces, and file aliases.
- `mruby.strict.Worker` keeps Ruby in a dedicated OS-contained process and
  data-only effect adapters in the host. The broker checks every RPC and final
  receipt against its own reserved journal, then requires a second fresh replay
  before returning `Turn.Prepared`. Linux seccomp/macOS Seatbelt deny ambient
  access; private socket transport, wall/CPU limits and clean reap fail closed.
  `addEffectWorker` builds one application worker from its CodeDB manifest and
  shared contract. `run-effects-worker` / `test-effects-worker` exercise it.

- `mruby.strict.Turn` prepares one fresh VM invocation from explicit state/input
  capsules and accepts only data-only bindings. It records an owned receipt
  containing the effect trace and joint `[result,next_state]` graph; replay has
  no handler/transaction hooks and checks both, including cross-root aliases.
- `effect.DataHandler` / `DataOutcome` and data capsule helpers remove Vm/Value
  from the new handler interface. Tree encoding, owned document reads, and
  subgraph extraction preserve inert value semantics. Legacy handlers remain
  available, and empty catalogues now support pure turns.
- Prepared turns expose explicit commit/discard. Abandonment and preparation
  failure discard provisional work; uncertain commits require reconciliation
  and never trigger an automatic retry or rollback. `run-effects-turn` and
  `test-effects-turn` exercise the complete workflow without SQLite.
- Opt-in `-Deffects-strict=true` selects a core-only runtime without a target
  compiler. A source-pinned native catalogue checks all VM native dispatches by
  implementation identity; primitive checks deny output, warnings, address
  observations, debug operations, and unapproved lifecycle/finalizer callbacks.
  Native violations remain fatal through Ruby rescue and invalidate recordings.
- `mruby.strict.Program` installs Effects before bounded CodeDB initialization,
  forbids performed effects during initialization, and derives replay identity
  from actual artifacts and dependency metadata. Unknown ordinary host bindings
  are rejected. The SQLite example and strict CI exercise this profile in Debug
  and ReleaseSafe. The lower-level Program interface retains trusted VM-capable
  handlers and host starting-state attestations.
- `mruby.effect.install` registers inert Ruby request constructors and
  synchronous `Effect.perform` dispatch with separate immutable host grants.
  Request payloads are owned snapshots; handlers are replaceable without
  changing application Ruby. The optional ambient profile masks audited
  clock, random, and output entry points.
- Bounded owned transcripts record operation arguments/results and replay
  them without live handlers. Actual entry code, operation/runtime contracts,
  and host-supplied input identities gate replay; mismatches and rescued
  dispatch failures cannot produce valid traces. Isolate execution owns
  cleanup, termination checks, and `takeEffectTrace` transfer.
- `Isolate.callWithEffects` admits object-method execution with explicit code,
  bootstrap, starting-state, and logical receiver identities. The runtime
  binds the actual method and snapshotted arguments; invalid inputs or replay
  identity mismatches preserve the previous trace and gas generation.
- Outcome handlers can report `Effect::Rejected` with a code and message;
  Ruby can rescue it, and replay reproduces that branch. Raw handler failures
  remain fatal. Trace format 1.1 records outcome tags and reads format 1.0.
  Returned values and rejection payloads are detached snapshots in all modes.
  `effectDiagnostic` provides bounded, owned first-mismatch details.
- Protected native operations now also catch allocation failures in mruby's
  result-rooting postlude, keeping full-arena OOM unwinding inside C.
- `run-effects-demo` and `test-effects` cover a live clock, fixed test
  handlers, captured outgoing intents, and replay after VM destruction.
  The CodeDB demo and pure transcript tests also run with `-Dno-compiler`.
  This first slice does not provide durable delivery, arbitrary method-effect
  inference, or resumable continuations.
- Optional `run-effects-inventory` / `test-effects-inventory` targets use
  `-Dsqlite-effects=true` for a pinned SQLite fixture with private transactions,
  read-only inspection grants, recoverable stock rejection, inert outbox
  intents, fresh-VM replay, and live/record measurements. They also support
  `-Dno-compiler`; ordinary library builds do not link SQLite.

CodeDB phases 1–5 (see docs/artifacts.md and docs/plans/codedb.md):

- Application Ruby is now a build-time input: the host mrbc from the
  bootstrap pipeline compiles each source twice (identical bytes
  required — the determinism gate), tools/rite_envelope.zig wraps the
  RITE into typed envelopes carrying the build compatibility
  fingerprint, and a generated manifest module embeds the artifacts.
  The reusable `addCodeDB` build helper stages stable source names and
  generates SHA-256-addressed envelopes with a versioned sidecar recording
  source/content hashes, the feature profile, and optional application
  identity. `Isolate.runArtifact(manifest, name)` executes through the
  normal policy path; `mruby.codedb.run` remains available. Generated
  schema/build mismatches fail during compilation. `zig build
  run-codedb-demo` demonstrates a restricted invoice job; `test-codedb`
  covers generation, metadata, policy rejection, and older artifact bytes.
- Declared module dependencies and entrypoints are validated and emitted in
  deterministic dependency order. `Isolate.loadArtifact` initializes a closure
  once per isolate under one execution budget; initialization failure poisons
  that loader and requires a fresh isolate. Manifest schema 1.1 adds graph
  metadata without changing the artifact envelope or compatibility epoch.

- A conservative authority gate defaults application bundles to the worker
  allow-list. It includes the entire linked profile, all declared host bindings,
  and transitive artifact requirements; unknown bits and missing binding
  references fail. Trusted/custom tiers are explicit. Schema 1.2 records source
  attribution and effective masks, rechecked against the consuming build at
  compile time. Host catalogue completeness remains a trusted bootstrap
  contract; runtime policy and the artifact envelope are unchanged.

- `-Dno-compiler` removes target parser/codegen and compiler-dependent eval
  gems while retaining the host compiler for CodeDB. Source APIs explicitly
  return `CompilerUnavailable`; features and compatibility identity record the
  profile. RNG seeding uses a protected captured native operation in both
  profiles, with no setup bytecode. The debug hook, artifact-only demo, worker,
  and resource-policy checks remain available. CI audits real runtime symbols.
- A packaged-consumer smoke test fetches a release snapshot into a fresh
  external project, then runs its relocated application and matching worker
  after deleting build inputs and caches. Linux/macOS CI covers both presets.

Security review follow-up:

- Added `zig build fuzz-state-materialize`: a coverage-guided fuzz target
  that drives inputs through `Isolate.importValue` — envelope validation,
  graph admission, and C-side construction of live objects — inside a
  memory-capped isolate, closing security review finding 1. The weekly
  scheduled fuzzing job runs it alongside the pure parser target.
- Repaired the materialization fuzz harness and pinned its behavior with
  deterministic regressions: a single owner now follows the isolate through
  memory-exhaustion rollover and failed replacement (no stale-handle
  teardown, no global pointing at a destroyed isolate), the declared capsule
  limits are passed into `importValue`, schema-bearing and schema-free seeds
  are exercised deliberately, unexpected lifecycle and construction failures
  surface instead of being swallowed, successful and rejected imports assert
  zero executed guest instructions, and discarded import roots are released
  so repeated valid imports stabilize memory. Boundary fixtures show every
  configured ceiling is enforced. CI runs bounded campaigns in both compiler
  profiles and retains failing inputs; see docs/security-review-2026-09.md
  (follow-up status) and docs/artifacts.md.
- Added `zig build test-worker-orphan`, closing security review finding 2: a
  test-only supervisor spawns the real worker under a controller it owns,
  waits for a readiness marker at a real worker boundary, then SIGKILLs only
  that controller and observes the worker's exact lifetime through a
  worker-owned pipe. Incomplete-request EOF, CPU-bound SIGXCPU under an
  inherited `RLIMIT_CPU`, and broken-pipe response delivery all end in
  bounded worker exit on Linux and macOS in both compiler profiles. As
  documented in docs/workers.md, this claims pipe-closure and CPU-ceiling
  exits after controller death — not general orphan wall-time containment.

## 0.4.0 (2026-09-04)

Security review:

- Added the v0.4.0 security review (docs/security-review-2026-09.md):
  manual review of the worker boundary, artifact attack surface, sandbox
  enforcement, and capability manifest. No critical or high findings;
  one medium follow-up (a fuzz target through the C materialization
  boundary), one trusted-computing-base clarification for the worker
  helper, and accepted, documented risks (macOS address-space ceilings,
  in-process tier scope).

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

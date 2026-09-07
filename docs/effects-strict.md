# Strict effects profile

The experimental `-Deffects-strict=true` profile checks native implementation
identities from VM creation. It closes the specific ambient paths found in the
[effects bypass audit](effects-audit.md): captured native methods, ordinary host
callbacks, native output, and address-derived observations. The recommended
entry for contained workflows is [mruby.strict.Worker](effects-workers.md),
which keeps native adapters in the host broker. [mruby.strict.Turn](effects-turns.md)
provides fresh VMs, explicit state, and data-only handlers in process. Its underlying
`mruby.strict.Program` installs Effects before running any application
initializer. Ruby still annotates only performed operations:

```ruby
now = Effect.perform(Clock.now)
Effect.perform(Outbox.enqueue("orders", [order_id, now]))
```

`strict.Turn` adds terminal result/state verification and explicit host
commit/discard. The lower-level Program interface below retains legacy
`Vm`/`Value` handlers and effect-sequence replay. Native adapters remain trusted
in both interfaces. `strict.Worker` adds process separation, OS containment,
a host-owned journal, and mandatory fresh replay before returning prepared work.

## Build and run

```sh
mise x -- zig build test check -Deffects-strict=true
mise x -- zig build run-effects-turn -Deffects-strict=true
mise x -- zig build run-effects-inventory -Deffects-strict=true -Dsqlite-effects=true -Doptimize=ReleaseSafe
```

The profile selects minimal core-only mruby with zero target gems and no runtime
compiler. CodeDB still compiles Ruby with the trusted build-time host compiler.
Conflicting compiler, gem, and ambient-worker options fail configuration. Time,
Random, IO, and Struct are absent. Code needing time, random numbers, or output
must use a declared operation and a granted handler. The generic worker target
remains disabled; the dedicated strict effect worker is available on supported
Linux/macOS targets through `features.effects_worker_supported`.

Downstream builds select the profile on the dependency used by both their
application and CodeDB helper:

```zig
const dep = b.dependency("mruby", .{
    .target = target,
    .optimize = optimize,
    .@"effects-strict" = true,
});
```

`mruby.features.effects_strict` reports the choice. The compatibility fingerprint
includes the native catalogue and enforcement implementation, so strict and
ordinary artifacts cannot be substituted. Ordinary builds retain the existing
embedding interfaces and ambient-mask behavior.

An additional [`-Deffects-integer64=true` profile](effects-integer64.md) selects
fixed signed 64-bit Ruby integers without Float. It requires this strict profile
and a 64-bit target; ordinary strict builds keep their existing numeric behavior.

## Load definitions, then invoke

Use the operation descriptors and bindings described in [effects.md](effects.md):

```zig
const program = try mruby.strict.Program.load(manifest, "orders", operations, .{
    .effects = .{
        .allowed = &.{ "clock.now", "outbox.enqueue" },
        .bindings = &bindings,
        .mode = .record,
    },
    .bootstrap_identity = adapter_contract_digest,
});
defer program.deinit();

const result = try program.call("Orders", "submit", .{order_id}, starting_state_digest);
var trace = try program.takeEffectTrace();
defer trace.deinit();
```

`load` validates the CodeDB manifest, creates the strict runtime, installs the
Effect catalogue, strips restricted language capabilities, and initializes the
entry's dependency closure under an instruction budget. Initializers may define
classes, construct inert requests, and mutate local Ruby state. Any
`Effect.perform`, even one rescued by Ruby, fails initialization before a handler
runs. Native violations and resource termination also fail initialization.
Failed initialization poisons the loader; `Program.load` disposes that VM.

Initialization does not start or consume an effect transcript. After it succeeds,
the core object model is frozen and identified method calls become available.
The default budget is 100,000 instructions per admitted initialization/call,
with a call-depth limit of 64. A policy override with no instruction setting
receives the same finite gas default; explicit unlimited gas is rejected.
Native handler execution retains the embedding's existing interruptibility
limits, so instruction gas is not a bound on native work.

`Program` owns one VM across calls; returned Values borrow that VM. It derives
code identity from the actual complete manifest, artifact bytes, dependency
edges, entrypoint flags, and selected entry. Bootstrap identity includes the
strict runtime fingerprint, grants, and the additional host contract digest.
The effect catalogue separately binds operation contracts. Each call binds the
actual method and snapshotted arguments as in `callWithEffects`.

The host still supplies the complete starting-state digest, including relevant
Ruby state and adapter state. It must also describe additional trusted setup
through `bootstrap_identity`. The runtime cannot discover arbitrary native state
or verify those attestations. The [inventory example](../examples/inventory/README.md)
uses a fresh VM and fixed database fixture for each invocation.

## What native enforcement checks

The generated catalogue admits reviewed C implementations by function identity,
independently of their Ruby names. Every pinned VM native-dispatch form passes
through the same gate. Aliases, captured C Procs, and copied method tables cannot
change a function's permission. Unknown ordinary host methods are rejected;
Effects explicitly approves its own request and dispatch implementations during
trusted setup. Approval closes permanently when initialization first begins.

Sensitive helpers also receive checks at their C implementation entry, covering
internal paths that bypass Ruby method dispatch. Native warning/output helpers,
debug opcodes, address-based object and Proc hashes, and lifecycle registration
are denied. Default object identity/formatting methods are denied; internal
pointer formatting emits `identity-redacted`. The runtime is compiled with
`MRB_NO_STDIO`. Native data wrappers require an approved descriptor before
ownership transfer, and GC never invokes an unapproved data finalizer.

A violation remains sticky through Ruby rescue. The host receives
`NativeEffectViolation`; a recording remains incomplete and cannot be encoded
as a successful trace. `try program.nativeDiagnostic()` copies the first reason
and a bounded native label. The next admitted call resets that diagnosis.
Ordinary effect failures retain their existing `effectDiagnostic` reports.

Array/hash mutation, instance variables, Ruby exceptions, and attribute accessors
remain ordinary Ruby. Local mutation is intentional. Strict execution neither
rolls it back nor rolls back a handler's writes after a failed call. Hosts should
discard or explicitly restore failed application state and manage transactions
and outgoing intents, as the inventory example does.

## Maintaining the profile

[native_catalogue.zig](../build/native_catalogue.zig) pins every core C source
and the changed header, and explicitly classifies callable native functions.
[patch_mruby_strict.zig](../tools/patch_mruby_strict.zig) generates cache-owned
source copies with exact expected replacement counts. Changed source bytes,
unknown native table entries, or missing/duplicated patch sites fail the build.
No package-cache source is modified. New gems require their own review and are
currently rejected.

`test-effects-strict` covers local Ruby behavior, fresh-VM record/replay,
rescued identity violations, captured native aliases and dynamic dispatch,
unapproved finalizers, initialization denial/budget/poisoning, and graph identity.
Patcher tests guard dispatch coverage and reject unreviewed functions. CI runs
strict tests and the SQLite example in Debug and ReleaseSafe on Linux and macOS.

## Remaining work

Approved handlers, allocators, instruction-meter hooks, and raw embedding C/Zig
remain trusted. Low-level host access can deliberately bypass the supported
`Program` lifecycle. Native memory-safety bugs and process resources also remain
outside this guarantee. Ordinary strict builds do not promise bit-identical
Float/libc behavior across architectures. The optional [integer64 profile](effects-integer64.md)
removes Ruby Float and fixes integer boundary behavior; deadlines, allocation failures, and external host inputs can
affect execution. Program replay does not prove identical terminal state;
`strict.Turn.replay` compares the explicit terminal graph.

The [turn runner](effects-turns.md) now supplies data-only handlers, explicit
starting state, terminal verification, and host commit/discard decisions.
[Strict workers](effects-workers.md) move authority out of the Ruby process
and add OS containment. Broader gem support still requires a reviewed inventory.

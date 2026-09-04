# Sandboxing: policy, threat model, and limits

`mruby.sandbox.Isolate` wraps a private `Vm` (its own heap, symbols, and
globals — nothing is shared between isolates) with an enforced policy.

Capability grants are **deny-by-default**: a `Policy` built without a preset
strips `eval`, `send`, an audited set of high-powered reflection operations,
and `ObjectSpace`, so plain compute scripts run while ambient language
authority must be granted explicitly — including anything a future release
might add. The presets compose with your limits and artifact acceptance:

Some library conveniences dispatch through a stripped capability internally.
For example, mruby implements `Enumerable#reduce(:+)` with `__send__`, so it
raises under the zero/restricted policy; use the block form
`reduce { |sum, item| sum + item }` or explicitly grant `send` (the trusted
preset does so).

```zig
// Semi-trusted scripts: deny-by-default capabilities plus a frozen object
// model and resource ceilings. Host classes/methods go on the bootstrap
// handle's raw vm, then seal, then run.
var boot = try mruby.sandbox.BootstrapIsolate.spawn(
    mruby.sandbox.Policy.restricted(.{
        .limits = .{
            .gas = .{ .per_isolate = 10_000_000 }, // cumulative gas budget
            .wall_time_ns = 250 * std.time.ns_per_ms,
            .memory_bytes = 8 * 1024 * 1024,      // soft cap -> hard cap
            .call_depth = 64,
        },
        .capabilities = .{
            .random_seed = 42,             // reproducible rand sequences
            .clock_epoch_s = 1_700_000_000, // frozen Time.now
        },
    }),
);
defer boot.deinit();
const iso = try boot.seal();
defer iso.deinit();

// Trusted embedding (scripts the host authored or fully controls) grants
// the ambient language capabilities instead:
//   mruby.sandbox.Policy.trusted(.{ .limits = ... })

const result = iso.run(script) catch |err| switch (err) {
    error.ScriptTerminated,   // iso.terminate() from any thread
    error.DeadlineExceeded,
    error.GasExhausted,
    error.MemoryLimitExceeded,
    error.CallDepthExceeded => ...,
    error.RubyException => ..., // ordinary script error: iso.lastError()
};
```

The whole policy — gas scope and limit, memory caps, wall budget,
call-depth ceiling, capability snapshot, and artifact acceptance — is
resolved once at `spawn`; the Isolate retains no mutable policy, so later
edits to a host-held `Policy` value have no effect. Dynamic per-request
amounts are not currently supported. `Limits.instructions` is a deprecated
alias for `.gas = .{ .per_isolate = N }`; setting both fields returns
`error.ConflictingGasPolicy`.

## Available authority and effective policy

`mruby.features.authority` describes **available authority**: the conservative
union of what linked core, compiler, and selected gem code can expose, with a
source entry for each. It describes the binary and therefore does not change
when an Isolate is sealed. A policy determines the **effective Ruby surface**
for that Isolate; capability denial and model freezing can make it smaller.
There is intentionally no derived `effective_authority` bitset: restrictions
are entry-point-specific, and arbitrary behavior inside native code cannot be
inferred from a capability flag.

The deny-by-default floor is driven by canonical audited inventories in
[`build/authority.zig`](../build/authority.zig). Each restricted method is an
exact `(gate, owner, name, instance-or-class)` target, each restricted
constant is an exact `(gate, owner, name)` target, and object-model sealing
uses one explicit class/module list. Policy application iterates those tables;
tests iterate the same tables to verify every listed target is masked or
frozen. An authority label is review metadata, not enforcement by itself: a
new Ruby entry point that should follow a policy gate must also be added to the
corresponding audited inventory.

`object_space = false` removes the `ObjectSpace` constant and masks
`ObjectSpace.count_objects`, `ObjectSpace.each_object`, and
`Class#subclasses`. The method masks also revoke a module reference retained
during trusted bootstrap; constant removal alone would not.

The `introspection` gate is deliberately an exact API restriction, not an
information-hiding boundary. Ordinary observational queries including
`class`, `respond_to?`, `ancestors`, `method_defined?`, and `const_get` remain
available when it is false. The restricted inventory instead covers the
listed variable access/mutation, method handles and listings, binding and
symbol-table access, source locations, and selected class/module metadata.

Application-defined classes and Zig callbacks registered through the
bootstrap VM are outside the generated package manifest. The sandbox cannot
infer or mask their authority. Keep callbacks narrow and bounded, validate
their inputs, expose only deliberately chosen host operations, and treat any
native gem carrying host-access authority the same way. The generic worker
has no application bootstrap callbacks; see [workers.md](workers.md).

Core's `print` and `p` entry points are reported as `host_output`: an
in-process embedding can route them to a host writer. The generic worker
admits this authority only because it redirects process stdout before starting
the VM; the manifest still reports the linked surface.

When `random_seed` is set, sealing seeds the default RNG through a protected
native operation captured before the host bootstrap window. It compiles no
Ruby source, executes no Ruby instructions, and also works with `-Dno-compiler`.
Sealing then masks
the reseeding methods and fresh `Random` construction. Guest code therefore
cannot replace the pinned sequence, including by calling no-argument `srand`
or `Random.new` to restore time/address-derived state. mruby consumes the low
32 bits of the configured `u64` seed. Requesting a seed without `mruby-random`
fails capability application instead of silently leaving nondeterministic
state.

When `clock_epoch_s` is set, sealing replaces `Time.now` and masks `Time.new`,
`Time.allocate`, and `Time#initialize`, which are the other upstream paths
that read the current clock. Explicit-value constructors such as `Time.at`,
`Time.gm`, and `Time.local` remain available. Local-time operations still use
the host timezone and daylight-saving rules; the option pins current time,
not the timezone database.

## Gas scopes

`Limits.gas` controls how instruction gas is granted:

| Policy | Behavior |
| --- | --- |
| `.unlimited` | No gas meter; `stats().gas` is `null`. |
| `.{ .per_isolate = N }` | One cumulative allowance for the Isolate. Lazy capability setup and all executions share it, and exhaustion is sticky. |
| `.{ .per_execution = N }` | Each admitted outermost `run`, `runImage`, `runRite`, or `call` gets a fresh allowance. Rejected preflight calls do not advance the generation; nested callback re-entry shares the active allowance. |

Use `.per_execution` for a stateful worker that should accept another request
after gas exhaustion:

```zig
const std = @import("std");
const mruby = @import("mruby");

var boot = try mruby.sandbox.BootstrapIsolate.spawn(
    mruby.sandbox.Policy.trusted(.{
        .limits = .{ .gas = .{ .per_execution = 20_000 } },
    }),
);
defer boot.deinit();
const iso = try boot.seal();
defer iso.deinit();

if (iso.run(
    \\$value = 40
    \\$cleaned = false
    \\begin
    \\  $value += 1
    \\  while true; end
    \\ensure
    \\  $cleaned = true
    \\end
)) |_| {
    return error.ExpectedGasExhausted;
} else |err| switch (err) {
    error.GasExhausted => {},
    else => return err,
}

const exhausted = iso.stats().gas.?;
std.debug.assert(exhausted.exhausted);
std.debug.assert(exhausted.used == exhausted.limit);

// A new outer execution gets fresh gas on the same Ruby heap.
const preserved = try iso.run("$value == 41 && $cleaned");
std.debug.assert(preserved.isTruthy());

const renewed = iso.stats().gas.?;
std.debug.assert(renewed.generation == exhausted.generation +| 1);
std.debug.assert(!renewed.exhausted);
```

This preserves state; it is not a transaction or continuation. Mutations and
completed `ensure` effects survive, but the interrupted stack is unwound and
never resumed.

`Stats.instructions` is the saturating lifetime count of observed bytecode
fetches. `Stats.gas` describes the live or most recently completed finite
generation. `used + remaining == limit`, and `used <= limit`.
`exhausted` means a later fetch actually observed an empty allowance;
`observed_instructions` also includes bounded detection and unwind work, so it
can exceed `limit`. Before the first `.per_execution` request, gas statistics
report prospective generation 0; actual requests start at generation 1.

## Termination, memory, and recovery

- **Termination** (`iso.terminate()`) is thread-safe and is observed at the
  next bytecode fetch. Delivery may wait for a catchable VM position, after
  which `ensure` blocks run during unwind; a `rescue` can catch the termination
  only briefly (a bounded instruction grace), never suppress it. The distinct
  error always surfaces to the host, and completion after observation is
  bounded by the uncovered-wait and grace budgets.
- **Memory**: the soft cap fails the next allocation (mruby raises the
  rescuable `NoMemoryError`, then the hook escalates); the hard cap
  (default soft + max(1 MiB, soft/2)) fails allocations permanently and
  terminates immediately. Allocating post-seal host operations invoked through
  `Isolate` are serialized and run with the isolate's allocator attribution,
  so their mruby-heap allocations update live/peak memory statistics and
  enforce the same sticky caps; a cap crossed by one of these operations
  surfaces directly as `error.MemoryLimitExceeded`. `iso.stats()` reports
  instructions/peak-memory/peak-depth/live-objects/wall-time; the isolate
  cell exposes an `on_limit` callback for quota accounting. Temporary
  conversion buffers and root-registry bookkeeping use the host allocator,
  are not part of this mruby quota, and should be bounded by the host.
- **Recovery**: only gas exhaustion under `.per_execution` is renewable.
  `.per_isolate` exhaustion, deadline, memory, call depth, and external
  termination remain sticky. `Isolate.lastError()` is reserved for ordinary
  `RubyException` and is cleared at the next outer entry. Its `message()` and
  `className()` use rooted inert metadata, execute no guest code, and consume
  no gas; returned slices are caller-owned and must be freed with
  `mruby.alloc.gpa.free`.
- **CPU/loops**: the instruction hook fires only on bytecode. Long pure-C
  operations and host Zig callbacks are not instruction-interruptible; memory
  caps constrain only allocations attributed to the Isolate, not CPU time.
  Keep callbacks bounded. They may poll `iso.pendingTermination()` for an
  external or already-recorded cause; a lifetime deadline is also arbitrated
  when the native call returns. For typed RITE jobs that need a hard outer
  deadline even when the VM hook cannot run, use the fresh-process
  [`worker.runRite`](workers.md) tier.
- **Boundaries**: the final charged opcode may finish with `remaining == 0`
  and `exhausted == false`; exhaustion is observed on the next fetch. A zero
  limit admits no charged opcode, but bounded uncharged delivery work may run
  so `ensure` can unwind. Gas does not charge parsing/code generation or work
  inside one C-native opcode.

## Lifecycle and host access

- **Lifecycle**: the typestate is `BootstrapIsolate.spawn(policy)` → raw
  `vm` bootstrap work (host classes and methods, definition-time loads,
  optional `sealModel`) → `seal()` → the execution `Isolate`. Sealing
  applies the policy's capabilities through the same preflight bracket as
  an execution (so setup gas and deadlines are accounted identically) and
  consumes the bootstrap handle (`deinit` becomes a no-op, so paired defers
  are always safe). The execution handle has no raw `vm` access:
  run/`runImage`/`runRite`/`call`, termination, stats, error inspection,
  globals, and value construction are first-class locked operations.
  One non-blocking operation lock covers guest execution and value artifact
  operations; simultaneous same-Isolate access returns `IsolateThreadBusy`.
  Nested guest execution from a callback retains its existing behavior, but a
  callback cannot start export/import. Invalid typed RITE is rejected before
  `lastError`, timing, gas, capabilities, or termination state changes.
  `terminate()` and `pendingTermination()` remain the cross-thread-safe
  lock-free controls; serialize stats, diagnostics, direct VM access, and
  destruction. `wall_time_ns` starts when the first outer entry begins
  preflight (`seal()` counts if it comes first), continues across idle time,
  and is never renewed by a new gas generation.
- **Host access between executions**: `Isolate.getGlobal` / `setGlobal` /
  `clearError` are the locked, ownership-checked surface for seeding and
  observing interpreter state between runs — no raw `vm` access needed for
  ordinary host introspection. They serialize like every other operation
  (re-entrant use from a callback returns `IsolateThreadBusy`) and
  `setGlobal` rejects foreign-VM values with `error.ForeignValue`. Allocating
  methods on `Isolate` use that same host-operation bracket for both locking
  and allocator attribution. The non-allocating `clearError` method uses the
  lock without rejecting a previously recorded memory termination, so retained
  diagnostics can still be discarded. This guarantee is scoped to calls made
  through `Isolate`; calling methods directly on returned `Value`, `Array`, or
  `Hash` handles does not enter the post-seal host-operation bracket.
- **Compiled images**: prefer typed `compileRite`/`runRite`, which add framing,
  corruption checks, generated build compatibility, and optional application
  identity. Legacy `sandbox.compile`/`runImage` remain temporarily available
  for raw RITE but are deprecated because they provide none of those outer
  compatibility checks.

## Threat model

The in-process tier is designed for **trusted and semi-trusted scripts**:
configuration or plugin code the host authored, ships, or curates, with
resource ceilings and capability stripping to contain bugs, runaway loops,
and accidental abuse.

**Not covered in-process**: there is no address-space separation from the
host. A determined adversary with the full language surface — including bugs
in mruby, its gems, or host callbacks — can corrupt the process. Do not run
genuinely hostile input in-process.

When using the worker tier, the helper binary is part of the trusted
computing base: a swapped helper bypasses every policy, so ship and verify
it exactly like the application binary.

`mruby.worker.runRite` provides the first out-of-process tier for one-shot
jobs. It starts a fresh helper, transfers only typed RITE and StateCapsule
bytes, applies a hard parent deadline and CPU limit, optionally caps the Linux
address space, and always reaps the direct child before returning. It does not
front the stateful Isolate API: there is no source compilation, persistent
session, arbitrary method call, custom host bootstrap, or explicit terminate
operation across the process boundary.

The helper is still not a complete hostile-code sandbox. It runs as the same
OS user and currently has no syscall filter, filesystem jail, network
namespace, or privilege separation. The build omits the generic helper when
the selected authority manifest reports filesystem, network, process,
environment, or arbitrary native-host access, unless the build owner uses the
explicit ambient-authority override. That gate prevents an accidental worker
configuration; it does not confine an enabled helper. Authenticate executable
artifacts and add an external OS/container sandbox where fully hostile code is
in scope. See [workers.md](workers.md) for the exact platform and enforcement
contract.

Run `examples/sandbox.zig` (`zig build run-sandbox`) for a runnable
end-to-end tour of presets, limits, sealing, and host access.

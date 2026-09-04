# Sandboxing: policy, threat model, and limits

`mruby.sandbox.Isolate` wraps a private `Vm` (its own heap, symbols, and
globals — nothing is shared between isolates) with an enforced policy.

Capability grants are **deny-by-default**: a `Policy` built without a preset
strips `eval`, `send`, introspection, and `ObjectSpace`, so plain compute
scripts run while ambient language authority must be granted explicitly —
including anything a future release might add. The presets compose with your
limits and artifact acceptance:

```zig
// Semi-trusted scripts: deny-by-default capabilities plus a frozen object
// model and resource ceilings. Host classes/methods go on iso.vm first,
// then seal, then run.
const iso = try mruby.sandbox.Isolate.spawn(mruby.sandbox.Policy.restricted(.{
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
}));
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

const iso = try mruby.sandbox.Isolate.spawn(mruby.sandbox.Policy.trusted(.{
    .limits = .{ .gas = .{ .per_execution = 20_000 } },
}));
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
  terminates immediately. `iso.stats()` reports
  instructions/peak-memory/peak-depth/live-objects/wall-time; the isolate
  cell exposes an `on_limit` callback for quota accounting.
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
  when the native call returns.
- **Boundaries**: the final charged opcode may finish with `remaining == 0`
  and `exhausted == false`; exhaustion is observed on the next fetch. A zero
  limit admits no charged opcode, but bounded uncharged delivery work may run
  so `ensure` can unwind. Gas does not charge parsing/code generation or work
  inside one C-native opcode.

## Lifecycle and host access

- **Lifecycle**: lazy capability setup joins `.per_isolate` gas, but completes
  before generation 1 for `.per_execution`. `Isolate.seal()` ends the
  bootstrap window explicitly: it applies the policy's capabilities through
  the same preflight bracket as an execution (so setup gas and deadlines are
  accounted identically) and is idempotent; the first `run`/`call` seals
  lazily otherwise. Route untrusted work through `Isolate.run`, `runImage`,
  `runRite`, or `call`; executing directly through `iso.vm` bypasses the
  generation lifecycle and is for trusted bootstrap before `seal()` only.
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
  `setGlobal` rejects foreign-VM values with `error.ForeignValue`.
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

**Not covered** (by design, same as v8 isolates): no address-space
separation from the host. A determined adversary with the full language
surface — including bugs in mruby, its gems, or host callbacks — can corrupt
the process. Do not run genuinely hostile input in-process. The planned
out-of-process tier (worker processes with IPC: run/call/terminate/stats
plus structured value transfer, OS-level memory separation and optional
seccomp/pledge) fronts this same API; typed RITE images give those workers
cheap warm-starts, and StateCapsules provide deliberate structured value
transfer (see [artifacts.md](artifacts.md)).

Run `examples/sandbox.zig` (`zig build run-sandbox`) for a runnable
end-to-end tour of presets, limits, sealing, and host access.

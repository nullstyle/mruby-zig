# Part 4 — Recording and replay

**Prerequisites**: [Part 3](03-effects.md). Same example,
[examples/effects_demo.zig](../../examples/effects_demo.zig); same commands:

```sh
mise x -- zig build run-effects-demo
mise x -- zig build test-effects
```

Record/replay is the effect system's answer to nondeterminism. A live
execution consults real clocks and real adapters; a *recorded* execution
writes down every operation the guest performed and what came back; a
*replayed* execution answers the same requests from that transcript without
invoking any handler. If both executions agree — same result, same rejections,
same next state — you have evidence the guest's outcome was determined by its
inputs plus the recorded observations, and nothing else.

The demo's `execute(host, mode)` from [Part 3](03-effects.md) takes the mode
from `mruby.effect.install`:

```zig
try mruby.effect.install(boot.vm(), contract.operations, .{
    // ...
    .mode = mode, // .live, .record, or .{ .replay = encoded_trace }
});
```

The mode is fixed for the lifetime of the installed system.

## Recording

Run the announcement with `.mode = .record`, then take the trace out of the
isolate:

```zig
const recorded = try execute(&recorder, .record);
if (mode == .record) {
    var trace = try iso.takeEffectTrace();
    defer trace.deinit();
    outcome.encoded_trace = try trace.encode(host.allocator);
}
```

`takeEffectTrace` **transfers ownership out of the VM** — the trace is
designed to outlive the interpreter that produced it, which is why the demo
destroys the recording isolate and carries only the owned host values and the
encoded transcript onward. `Trace.encode` returns a separate allocation;
`Trace.len`, `get`, and `isComplete` let you inspect records (record slices
borrow from the trace).

A second take without another recording returns `EffectTraceUnavailable`.
Take the trace before the next admitted execution, which replaces any
retained trace even if the new run later fails. And an execution that fails —
an unrescued rejection, a raised exception, a handler error — leaves its
transcript **incomplete**, and incomplete transcripts cannot be encoded for
replay. Recording reserves transcript capacity ahead of each handler call,
but it is explicitly not a transaction protocol: a handler that already acted
is not rolled back when a later failure invalidates the recording. (Rolling
back or committing observed work is the host transaction problem of
[Part 5](05-turns.md).)

## Replaying

Replay is configured with the encoded bytes:

```zig
const replayed = try execute(&replayer, .{ .replay = encoded });
```

Each `Effect.perform` is matched against the next record. Matching requires
**exact operation order, versions, and encoded arguments** — remember from
[Part 3](03-effects.md) that requests are inert snapshots, so "encoded
arguments" is well-defined and tamper-evident by construction. On a match,
replay returns the recorded value or raises the recorded rejection *without
invoking any handler*. A different request, an extra request, or a record
left unconsumed at successful return fails with `EffectReplayMismatch`. There
is no fallback to live handlers — the transcript matches or the replay fails.

The demo proves the point with a hostile host: the replayer's clock is fixed
to `-1` and its counters start at zero, and yet:

```zig
try std.testing.expectEqual(recorded.timestamp, replayed.timestamp);
try std.testing.expectEqual(recorded.receipt, replayed.receipt);
try std.testing.expectEqual(@as(usize, 0), replayer.clock_calls);
try std.testing.expectEqual(@as(usize, 0), replayer.enqueue_calls);
try std.testing.expectEqual(@as(usize, 0), replayer.intents.items.len);
```

Zero handler calls, zero new intents, identical result. The Ruby code ran in
full — branches, string assembly, arithmetic — against recorded observations.

## What identifies an execution

Replay answers "did this code, given these observations, produce this
result?" — so the notion of *this code* and *these observations* has to be
pinned. The installation's `input_identity` (the demo hashes its input
message) participates in execution identity, alongside the operation
catalogue and the guest artifact. The full inventory — artifact bytes,
bootstrap contract, receiver and method, arguments — is specified in
[effects.md](../effects.md) under "What identifies an execution", and by
[Part 7](07-durable.md) it grows into full request fingerprints that include
application code and contract identities.

Trace format note: new recordings use trace format 1.1 with an explicit
outcome tag (returned vs rejected); 1.0 traces remain readable and
re-encode preserving their version.

## Where this leads

Two upgrades to this mechanism follow later in the series, and both reuse
everything you just learned:

- In [Part 5](05-turns.md), replay becomes **mandatory verification**: a
  strict turn's receipt — its recorded trace and result — must replay in a
  fresh VM before the host may commit anything. The demo's optional "replay
  and compare" becomes a gate.
- In [Part 7](07-durable.md), the receipt becomes a **durable artifact**:
  stored in SQLite, checksummed, replayable years later to re-derive the
  result, with fingerprints that fail closed if the application changes.

## Limits at this layer

- Replay attests to *recorded observations*, never to current external state.
  A replayed `Clock.now` proves what the clock said then; it says nothing
  about now. Replay runs no adapters — the demo's zero-call assertions are
  the contract.
- Determinism is bounded to what crosses the seam: operations performed
  through `Effect.perform` are captured; anything the guest can compute
  without an operation (ambient nondeterminism) is only as deterministic as
  the underlying platform, which is why numeric-profile equivalence evidence
  is described as bounded, not universal.
- Replaying code that performs a *different* number or order of operations
  fails rather than improvising — replay is a proof, not a best-effort cache.

Continue with [Part 5 — Strict turns and typed contracts](05-turns.md).

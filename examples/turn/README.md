# Fresh strict turns

```sh
mise x -- zig build run-effects-turn -Deffects-strict=true
mise x -- zig build test-effects-turn -Deffects-strict=true
mise x -- zig build test check install -Deffects-strict=true -Doptimize=ReleaseSafe
```

This example is available in every strict build and needs no SQLite or system
service. [Counter.apply](counter.rb) receives an explicit state and input and
returns `[result, next_state]`. Its clock observation, intent preparation and
output preparation use `Effect.perform` at the operation sites. Local state
mutation remains ordinary Ruby.

The [host](../effects_turn.zig) supplies data-only adapters. Each callback gets
an allocator and a bounded inert capsule, and returns an owned capsule. It gets
no VM or Ruby `Value`. The clock adapter supplies a fixed observation; the other
two adapters stage an intent and an output line in memory. Native adapters
remain trusted code and must follow the staging contract.

`strict.Turn.prepare` creates a fresh VM, validates and copies the state/input,
runs the application, and destroys the VM before returning owned terminal data
and a receipt. A receipt contains the effect trace and the complete terminal
pair. The pair preserves aliases between result and next state; extracting
`prepared.state(allocator)` gives an independent capsule for a later turn.
Unexported Ruby globals do not survive into the next turn.

Preparation does not commit. The example's transaction hooks make this visible:

- `begin` opens an empty staging area.
- `commit` adopts the next-state capsule, receipt, intents and output together,
  after completing all fallible allocations.
- `discard` removes staged work. An exception, an invalid result, explicit
  discard or an abandoned `Prepared` leaves committed state unchanged.

A rejected commit discards once. An indeterminate commit or a thrown commit
error requires host reconciliation; the runner neither retries nor discards it.
The example retains committed intents/output only in memory. It does not send
messages, print application output, write durable storage, or claim consensus
acceptance. A production adapter needs its own atomic persistence protocol.

`strict.Turn.replay` has no handler or transaction parameters. It reruns the
application with recorded observations, then compares the complete result and
next state. It returns owned data only after both match. Replay does not restore
a database, adopt state, deliver intents, or prove that a prior host committed.
Receipt checksums detect corruption; they do not authenticate a source.

The demo and tests cover counter transitions `7 → 10 → 13`, recoverable
`CounterLimit` rejection, rollback after preparing output and an intent, explicit
and automatic discard, fresh VM isolation, changed request identities, and
validly checksummed receipts with altered terminal result or next state.
Additional tests exercise malformed/oversized data results, native violations,
allocation failures, commit dispositions and cross-root aliases.

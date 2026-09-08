# Part 5 — Strict turns and typed contracts

**Prerequisites**: [Part 4](04-record-replay.md). This part requires the
strict profile:

```sh
mise x -- zig build run-effects-turn -Deffects-strict=true
mise x -- zig build test-effects-turn -Deffects-strict=true
```

No SQLite, no network, no system service — and, decisively, **no runtime
compiler**: the strict profile selects a minimal mruby whose parser is absent.
Everything Ruby-shaped was compiled by CodeDB at build time
([Part 2](02-codedb.md)).

A *turn* is the unit this part introduces: one application invocation that
receives capsule state and input, performs explicit effects, and returns a
terminal `[result, next_state]` pair. What makes it *strict* is the discipline
around it:

- **A fresh VM per call.** Every `Turn.prepare` boots a clean interpreter from
  the identified artifact. No globals leak between turns; the example's
  `FreshProbe` counts unexported global mutations across two calls and both
  come back as `1`.
- **Data-only adapters.** Handlers no longer receive a `*mruby.Vm` or a
  `Value`. They receive inert capsule bytes and an allocator, and return an
  outcome in the same encoding. The seam from [Part 3](03-effects.md) has
  narrowed to pure data.
- **A host transaction.** The host supplies `begin`/`commit`/`discard`
  callbacks. Effects stage into a pending set; nothing external happens until
  the caller explicitly commits the *prepared* turn.
- **Mandatory replay.** Before a turn's work is handed back, its receipt must
  replay in yet another fresh VM and reproduce the exact terminal bytes
  ([Part 4](04-record-replay.md) as a gate, not an option).

## The application

[examples/turn/counter.rb](../../examples/turn/counter.rb) — the Ruby side of
a turn is exactly the shape you already know:

```ruby
def self.apply(state, input)
  count = state["count"] + input["delta"]
  time = Effect.perform(Clock.now)
  begin
    receipt = Effect.perform(Intent.prepare({"topic" => "counter.updated", "count" => count, "at" => time}))
  rescue Effect::Rejected => rejection
    return [{"status" => "rejected", "code" => rejection.code}, state]
  end
  Effect.perform(Output.write("counter=#{count} at=#{time}"))
  raise "abort after preparation" if input["abort_after_prepare"]
  state["count"] = count
  state["last_at"] = time
  [{"status" => "updated", "count" => count, "receipt" => receipt}, state]
end
```

Note the vocabulary from [Part 3](03-effects.md) doing real work: a declared
rejection (`CounterLimit`, raised by the host adapter when a counter would
exceed 100) is rescued and becomes a valid *rejected result*, while
`raise "abort after preparation"` is a failure that will discard the turn.

The whole-turn contract in [examples/turn/contract.zig](../../examples/turn/contract.zig)
describes state, input, result, and expected rejections as typed schemas, so
the runtime can reject malformed values before a worker ever starts and
malformed terminals before the host ever commits. The typed-contract language
is specified in [effects-contracts.md](../effects-contracts.md); the turn
interface in [effects-turns.md](../effects-turns.md).

## The host side

[examples/effects_turn.zig](../../examples/effects_turn.zig) implements the
host. Its adapters are functions of `(context, allocator, View)` returning
`mruby.effect.DataOutcome` — for example, `prepareIntent` decodes its
arguments, rejects a counter above 100, appends to `pending_intents`, and
returns an integer receipt; `clockNow` returns a fixed timestamp. None of them
can touch a VM, because none of them receives one.

The transaction is three plain functions on the host struct:

```zig
fn transaction(host: *Host) Turn.Transaction {
    return .{ .context = host, .begin = begin, .commit = commit, .discard = discard };
}
```

`begin` opens the turn (double-begin fails); `commit` receives the terminal
view and the receipt bytes, and — critically — **completes every fallible
allocation before adopting any state**: it encodes the next state and dupes
the receipt first, then swaps them in and appends the pending intents and
output. `discard` drops everything pending.

## Prepare, commit, or discard

The caller-visible protocol:

```zig
var prepared = try Turn.prepare(allocator, manifest, "counter", contract.operations,
    request(state.view(), input.view()),
    .{ .bindings = &bindings, .transaction = host.transaction() },
    options());
defer prepared.deinit();

// ...inspect prepared.terminal(), prepared.receipt()...

try prepared.commit();   // host adopts state + staged work
// or prepared.discard();
```

Between `prepare` and `commit`, the host is in charge and can inspect
everything inertly. The demo verifies the full lifecycle:

- **Commit**: counter 7 → 10, the intent and output queues adopt their staged
  entries exactly once.
- **Declared rejection**: an input that trips `CounterLimit` produces a
  rejected *result* — clock and intent adapters still ran once each, and the
  receipt still replays to identical terminal bytes.
- **Discard**: explicit `discard()` is idempotent, and simply dropping a
  prepared turn (`deinit` without commit) discards too — state stays 7, no
  intents, no output, no commits.
- **Failure**: the `abort_after_prepare` input raises inside Ruby; the
  transaction discards, state stays 7.
- **Tampering**: a receipt is re-encoded with only the result, or only the
  next state, changed — both have valid framing and checksums, and both fail
  replay with `TerminalMismatch` and a diagnostic carrying expected/actual
  hashes and a byte offset ([effects-diagnostics.md](../effects-diagnostics.md)).
- **Identity**: replaying the receipt against a changed input or changed
  state fails with `EffectTraceIdentityMismatch`.

Receipts are themselves typed artifacts — `Turn.Receipt.decode`/`encode` with
framing and checksums — which is what lets [Part 7](07-durable.md) store them
in a database and [the inspect CLI](../effects-diagnostics.md) examine them
without any VM at all.

## The bigger reservation example

[examples/reservation/](../../examples/reservation/) applies the identical
shape to a domain — `Stock.reserve` conditionally decrements inventory,
`Notifications.reservation_created` stages an intent — with typed argument
schemas and outcome contracts. It is the direct precursor of the durable
application in [Part 7](07-durable.md), and its
[README](../../examples/reservation/README.md) is worth reading side by side
with that part. There is also the older
[examples/inventory/](../../examples/inventory/) example, which runs typed SQL
effects in-process under the strict profile: same seam, trusted native
adapters, no worker — useful for seeing the strict *program* tier without
process confinement.

## Limits at this layer

Everything still runs **in one process**. The strict runtime guarantees fresh
VMs, data-only seams, contracts, and verified receipts — but the Ruby code
shares your address space, and your adapters are trusted code in that same
process. A malicious or compromised guest binary is still a host problem, not
an interpreter problem. Closing that gap is [Part 6](06-workers.md).

Continue with [Part 6 — Confined effect workers](06-workers.md).

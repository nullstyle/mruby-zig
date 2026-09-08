# Part 7 — The durable host: turns that survive crashes

**Prerequisites**: [Part 6](06-workers.md). Strict profile plus the opt-in
SQLite dependency:

```sh
mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true
mise x -- zig build test-effects-durable -Deffects-strict=true -Dsqlite-effects=true
```

SQLite is compiled from the hash-pinned official 3.51.3 amalgamation — no
system installation, and ordinary builds never acquire the dependency. The
durable suites are the ones verified in the full matrix: Debug and
ReleaseSafe, ordinary and integer64 numeric profiles, on Linux and macOS.

Everything so far lived in memory: a prepared turn's state, receipt, and
staged intents vanished with the process. The durable example —
[examples/durable/](../../examples/durable/), with its
[reference guide](../effects-durable.md) — makes exactly one turn's effects
survive: inventory changes, the next Ruby state, the verified receipt, and
outgoing intents commit **in one SQLite transaction**, and a host that dies
at any point can be reopened and asked what happened.

## Run the demo

```sh
mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true -- /tmp/mruby-durable-demo
```

The run uses a private temporary directory by default (removed afterwards);
supply a directory to retain and inspect `inventory.sqlite` and
`recipient.sqlite`. Running the same command twice reuses every committed
decision — the second run re-derives the same answers with `reused` results
and zero effect calls. The installed form is:

```sh
./zig-out/bin/effects-durable "$PWD/zig-out/bin/effects-durable-child" \
    "$PWD/zig-out/bin/effects-durable-child-v2" ./durable-demo
```

One run verifies: revision 1 under `inventory/v1`, the published upgrade to
`inventory/v2`, one v2 rejection turn at revision 3, stock 3 from an initial
5, one reservation, one delivered recipient notification — and reissuing the
old v1 request under the upgraded application fails with `TurnIdConflict`
([Part 8](08-upgrades.md)).

## The application

The Ruby is the two-effect reservation flow you have known since
[Part 3](03-effects.md), now under a whole-turn contract:

```ruby
reservation = Effect.perform(Stock.reserve(input["sku"], input["quantity"]))
intent = Effect.perform(Notifications.reservation_created(reservation))
next_state = {"attempts" => state["attempts"] + 1}
[{"status" => "reserved", "reservation" => reservation, "intent" => intent}, next_state]
```

`Stock.reserve` conditionally decrements stock and inserts a reservation in
one host operation, returning a closed object with a stable reservation ID.
`OutOfStock` is a declared rejection — Ruby rescues it and returns a valid
rejected result, which commits and advances the attempt count. Ruby supplies
no SQL and no destination; the trusted host adapters own both. The shared
[contract.zig](../../examples/durable/contract.zig) describes operations,
state, input, and terminal results; the host additionally enforces relations
the shapes cannot express — a notification must refer to *this* turn's
reservation, each operation happens at most once, a rejected result must have
no staged changes.

## The host interface

[examples/durable/host.zig](../../examples/durable/host.zig) hides admission,
transactions, worker verification, persistence, retention, and recovery
behind eight operations:

| Operation | Behavior |
| --- | --- |
| `Host.open(allocator, db_path, worker_executables, options)` | Open or initialize the ledger; validate role, namespace, and pinned application identity. |
| `execute(.{ .turn_id, .expected_revision, .input })` | Return the original committed result, or prepare, verify, and atomically commit a new turn. |
| `upgrade(.{ .upgrade_id, .expected_revision, .target })` | Publish one explicit application upgrade atomically ([Part 8](08-upgrades.md)). |
| `prune(.{ .before_revision, .archive_path })` | Archive and remove acknowledged history ([Part 9](09-retention-chain.md)). |
| `verifyChain()` | Walk the tamper-evident history chain ([Part 9](09-retention-chain.md)). |
| `status()` | Consistent snapshot of active application, state, row counts. |
| `replay(turn_id)` | Verify a historical receipt with its original application and worker — no adapters. |
| `dispatch(recipient_path)` | Deliver up to 64 pending committed intents ([Part 10](10-delivery.md)). |

The ledger is schema 3: pinned application identity in `durable_metadata`,
per-turn version records, the upgrade journal, and the history chain.

## Admission and publication

`execute` is where [Part 4](04-record-replay.md)'s identity thinking becomes
load-bearing. The caller supplies a stable turn ID, the expected state
revision, and an inert input capsule. The host:

1. **Fingerprints the request** — application/contract identities, namespace,
   turn ID, expected revision, and the exact encoded input bytes. Differently
   encoded inputs are different requests.
2. **Admits the ID** in a short committed transaction, binding it to that
   fingerprint forever. Admissions are immutable; a bound ID can never
   execute different work.
3. Opens `BEGIN IMMEDIATE`, validates state and revision, and runs the turn
   **from [Part 6](06-workers.md) unchanged** — confined worker, data-only
   adapters, mandatory fresh replay verification — with the business
   transaction held open across recording and verification.
4. Commits inventory, reservations, next state, the receipt, and outbox rows
   **together**. Deferred foreign keys prevent orphans; the reply's owned
   allocations complete before `COMMIT` so no allocation failure can occur
   while constructing the result after publication.

A committed retry returns the original result with `reused = true` and zero
effect calls, independent of later revisions. An uncommitted admitted request
may retry while its expected revision is current; changed input under a bound
ID fails `TurnIdConflict`; an old revision fails `StaleState`.

## Recovery rules

The suite kills *real host processes* — at admission, transaction begin, both
domain effects, the individual stock and reservation writes, preparation,
before/after commit, and around delivery — using an independent supervisor,
then reopens the databases and checks retries, receipts, state, inventory,
and recipient counts. The rules it pins down:

| Outcome | Caller action |
| --- | --- |
| `reused = true` | Use the original result; no adapter ran. |
| `TurnIdConflict` | Preserve the original request; new ID for different work. |
| `StaleState` | Read current state; submit a deliberate new request. |
| `DatabaseBusy` | Retry when the competing writer finishes. |
| `CommitIndeterminate` | Close and reopen, then retry the exact original request. |
| `HostNeedsRecovery` / `DatabaseNeedsRecovery` | Close and reopen before further work. |

The subtle one is `CommitIndeterminate`: issuing `COMMIT` and receiving an
error proves nothing about whether publication happened, so the host poisons
itself rather than rolling back, and a fresh connection plus the immutable
ledger resolve the outcome — a committed record answers with its receipt,
otherwise the kept admission permits another attempt if the base revision
still matches. WAL with `synchronous=FULL` (and `fullfsync` on macOS) is part
of this contract; network filesystems are unsupported.

## What is trusted

The documented model, unchanged since [Part 3](03-effects.md): the database,
native adapters, allocator, and OS/storage are trusted. Receipts carry
corruption checksums, not signatures. The host namespace participates in
intent identity — independent sources sharing a recipient need distinct
persistent namespaces. This is still a small example by policy: two domain
operations, 64 KiB state/input bounds, 256 KiB receipts, a 4,096-row adapter
snapshot cap (`AdapterStateLimit`), a fixed `reservations` destination.

## What you can now build

A crash-safe request-driven application whose business logic is confined
Ruby, whose effects are explicit and typed, whose answers are idempotent
under retry, and whose history is verifiable by replay.

Continue with [Part 8 — Application upgrades](08-upgrades.md).

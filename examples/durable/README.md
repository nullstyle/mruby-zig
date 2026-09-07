# Typed durable turns and recovery

This example combines typed domain effects and whole-turn contracts with the
confined [effect worker](../worker/README.md) and a disk-backed SQLite transaction. A successful reservation commits its inventory
updates, Ruby state, turn receipt, and pending outbox intent together. The host
can reopen the database and identify the outcome of a retried turn.
See the [durable host guide](../../docs/effects-durable.md) for method contracts
and recovery decisions.

```sh
mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true -j2
mise x -- zig build test-effects-durable -Deffects-strict=true -Dsqlite-effects=true -j2
```

Both flags are required. Add `-Deffects-integer64=true` to use the checked
integer-only runtime. The example runs on the strict worker's supported
Linux and macOS targets, on x86_64 and aarch64. SQLite is built from the optional,
hash-pinned official amalgamation; no system SQLite library is required.
Ordinary builds and the other strict examples do not acquire this dependency.

The run target uses a private temporary directory and removes it after all
database connections close. To retain and inspect the databases, supply a
dedicated directory:

```sh
mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true -- /tmp/mruby-durable-demo
```

The directory contains `inventory.sqlite` and `recipient.sqlite`. Running the
same command again reuses the original turn, upgrade, and delivery decisions.
The installed demo accepts both application workers followed by an optional
directory:

```sh
mise x -- zig build install -Deffects-strict=true -Dsqlite-effects=true -j2
./zig-out/bin/effects-durable ./zig-out/bin/effects-durable-child ./zig-out/bin/effects-durable-child-v2 /tmp/mruby-durable-demo
```

## What happens

The [Ruby application](inventory.rb) receives state `{"attempts" => 0}` and an
input requesting two widgets. It performs two typed domain operations:

```ruby
reservation = Effect.perform(Stock.reserve(input["sku"], input["quantity"]))
intent = Effect.perform(Notifications.reservation_created(reservation))
```

The host owns the stock update, reservation insertion, and notification payload.
The shared operation and turn contracts validate all admitted and returned data.
A notification must match the reservation staged by the current request, and
neither operation can be duplicated. The starting stock
of five becomes three, and Ruby returns its result plus state with one attempt.
An insufficient-stock rejection is handled by Ruby. An uncaught exception
discards the transaction, including any already staged inventory or intent.

The [host](host.zig) uses `BEGIN IMMEDIATE` around the worker execution and its
mandatory fresh replay verification. It checks the caller's expected revision,
then atomically retains the accepted next state, receipt, and outbox alongside
the SQL changes. It does not deliver the intent while that transaction is open.

Each request supplies a stable turn ID and expected revision. Invalid input is
rejected before it can reserve an ID. Admission reserves
that ID for its immutable request fingerprint in a separate durable transaction.
This reservation survives failed preparation or process death. An uncommitted
request may retry with the same input and expected revision; changed input or
revision under its admitted ID fails with `TurnIdConflict`.

After a successful commit, closing and reopening the database and repeating the
same request returns the persisted result without starting another worker or
repeating an adapter. A new turn against an old revision fails with `StaleState`.
After an uncertain commit outcome, close and reopen the host, then retry the
exact same request to recover the durable decision. The admission registry is separate from the atomic commit
of inventory, Ruby state, receipt, and outbox.
The host namespace is part of intent identity. Give independent source ledgers
distinct, persistent namespaces when they share a recipient; the demo uses
`"demo"` with its own recipient database.

Replay loads the original request and receipt into a fresh worker with no
effect adapters. It verifies the result and next state without reserving stock,
advancing the revision, rebuilding external state, or delivering messages.

## Application versions and the upgrade

The ledger pins an application identity (code, contracts, label, and numeric
profile) in `durable_metadata` and records the committing version of every
turn. This example builds two versions side by side:

- `inventory/v1` — [inventory.rb](inventory.rb) and
  [contract.zig](contract.zig): state is `{"attempts" => n}`.
- `inventory/v2` — [inventory_v2.rb](inventory_v2.rb) and
  [contract_v2.zig](contract_v2.zig): state additionally counts declared
  `OutOfStock` rejections, and the fault-instrumentation `mode` input is gone.

Both live in one host through [applications.zig](applications.zig), which also
declares the single supported upgrade path and its trusted state transform.
The demo commits a v1 reservation, then calls:

```zig
host.upgrade(.{ .upgrade_id = "demo-upgrade", .expected_revision = 1, .target = "inventory/v2" })
```

One SQLite transaction validates the accepted v1 state, transforms it to
`{"attempts" => n, "rejections" => 0}` (v1 never recorded rejections, so the
counter starts at zero by explicit policy), publishes the new state at the next
revision, rewrites the active application identity, and records the upgrade's
provenance. Retries return the original decision; a lost reply after COMMIT is
resolved the same way after reopening. Death before publication rolls back to
the prior version and state.

After the upgrade, new turns run as v2, and reissuing an old v1 request fails
with `TurnIdConflict` instead of reinterpreting it. Historical receipts still
replay on the exact bundle, contracts, and worker that committed them — a v1
receipt replays on the v1 worker even though the ledger is now v2. Pending v1
intents keep their IDs and remain deliverable. Unknown pinned identities,
other numeric profiles, schema-1/2 ledgers, downgrades, and further upgrade
directions fail closed; there is no automatic migration.

## Retention

`Host.prune(.{ .before_revision, .archive_path })` archives and removes
acknowledged turn history below an explicit revision: every pruned turn's ID,
revision, pinned application, and receipt are written to a write-ahead JSON
archive first, then its turn/version/reservation/outbox rows are deleted in
one transaction. Pruning refuses turns with pending intents and keeps every
immutable admission, so a pruned request ID can only stale out or conflict —
it can never execute twice. Pruned receipts replay no longer but stay
recoverable from the archive file.

## Delivery and crash boundaries

Delivery uses a second local SQLite database as a recipient simulation. Each
intent has a stable ID. The recipient commits that ID, the complete payload,
and a simulated notification count in one transaction. Repeating the identical
intent leaves the count unchanged; conflicting use of its ID is rejected.

The source acknowledges delivery in a later transaction. A process can die after
the recipient commits but before that acknowledgement. Retrying delivery sends
the same intent, so the recipient's stored ID prevents a second notification.
This is a concrete example of recipient idempotency. It does not establish
exactly-once delivery for an arbitrary network service.

The process tests use explicit host checkpoints and an independent supervisor
to kill and reap the host before reopening its database. They cover deaths
around admission, both effects and the individual stock/reservation writes,
preparation, commit, recipient commit, and delivery
acknowledgement, plus retry identity and competing writers. These tests exercise
process-crash recovery; they do not simulate power loss or faulty storage.

## Storage and scope

Both databases require WAL mode and `synchronous=FULL`; macOS also enables
`fullfsync`. SQLite is compiled with `SQLITE_THREADSAFE=1`,
`SQLITE_OMIT_LOAD_EXTENSION`, and `SQLITE_DQS=0`. Each host instance and connection
uses `SQLITE_OPEN_NOMUTEX` and must have one caller at a time. SQLite protects
its process-wide internals; separate connections coordinate writes through its
locking. Guest effects and delivery batches are bounded, and a competing writer
can receive `DatabaseBusy` and retry. The starting inventory digest permits at
most 4,096 snapshot rows before worker execution. Host adapter and SQLite work
remain synchronous; the worker deadline cannot preempt a blocked host call.

The pinned [SQLite 3.51.3 release](https://www.sqlite.org/releaselog/3_51_3.html)
includes the [WAL reset corruption fix](https://www.sqlite.org/wal.html#walresetbug).
The [official archive](https://www.sqlite.org/2026/sqlite-amalgamation-3510300.zip)
is pinned in `build.zig.zon`. Its `sqlite3.c` SHA3-256 matches the release page:
`32d5424f97e0a7fc5ed2f6335afbb58be4e0298bd7117a34e39d345ff13d859e`.

Use a local filesystem with working SQLite locking and sync semantics. WAL
databases are not supported on network filesystems. Keep the database together
with its WAL and shared-memory files; do not copy or delete a live database's
sidecar files individually. See SQLite's [WAL documentation](https://www.sqlite.org/wal.html).

This remains a small application example. Ruby receives bounded domain
operations; trusted host adapters own the SQL and local-recipient payloads.
Source schema 3 intentionally rejects earlier schema-1 and schema-2 ledgers
with `UnsupportedDurableSchema` instead of migrating them in place. Schema-2
ledgers have an explicit offline path: the installed
[migrator](migrate.zig) validates everything under an operator-named
application and builds a fresh schema-3 ledger beside the untouched source:

```sh
./zig-out/bin/effects-durable-migrate ./old-schema2.sqlite ./migrated.sqlite inventory/v1
```

Schema-1 ledgers stay read-only-rejected. Downgrades, replicated acceptance,
production delivery, signed receipts, and operational reconciliation remain
application responsibilities. The earlier [inventory example](../inventory/README.md) keeps
its separate disposable in-memory workflow.

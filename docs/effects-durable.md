# Durable effect turns

The [durable reservation example](../examples/durable/README.md) is a reference
host for `strict.Worker` with typed domain operations and whole-turn contracts. It persists inventory changes, the next Ruby state,
the verified receipt, and outgoing intents in one SQLite transaction. Repeating
a committed request returns its original result without starting Ruby or
invoking an adapter. Delivery happens separately, with a second local database
demonstrating recipient idempotency.

```sh
mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true
mise x -- zig build test-effects-durable -Deffects-strict=true -Dsqlite-effects=true
```

Both commands also support `-Doptimize=ReleaseSafe` and
`-Deffects-integer64=true`. The demo uses temporary
disk databases by default. To retain them, build/install and run twice against
the same dedicated directory:

```sh
mise x -- zig build -Deffects-strict=true -Dsqlite-effects=true
./zig-out/bin/effects-durable "$PWD/zig-out/bin/effects-durable-child" "$PWD/zig-out/bin/effects-durable-child-v2" ./durable-demo
./zig-out/bin/effects-durable "$PWD/zig-out/bin/effects-durable-child" "$PWD/zig-out/bin/effects-durable-child-v2" ./durable-demo
```

Each run verifies revision 1 under `inventory/v1`, the published upgrade to
`inventory/v2`, one v2 rejection turn at revision 3, stock 3 from an initial 5,
one reservation, and one recipient notification. The second run reuses the
committed turn, upgrade, and delivery decisions; reissuing the old v1 request
under the upgraded application fails with `TurnIdConflict`. The earlier
[inventory example](../examples/inventory/README.md) remains a separate
in-memory demonstration of the lower-level interface.

## Ruby and shared contracts

The application has two explicit effect sites:

```ruby
reservation = Effect.perform(Stock.reserve(input["sku"], input["quantity"]))
intent = Effect.perform(Notifications.reservation_created(reservation))
next_state = {"attempts" => state["attempts"] + 1}
[{"status" => "reserved", "reservation" => reservation, "intent" => intent}, next_state]
```

`Stock.reserve` conditionally decrements stock and inserts a reservation inside
one host operation. It returns a closed object containing a stable reservation
`id`, `sku`, `quantity`, and `remaining` stock. `OutOfStock` is a declared
rejection; Ruby handles it by returning a rejected result and advancing its
attempt count. `Notifications.reservation_created` accepts the reservation and
returns the stable ID of a staged notification. The host constructs the payload;
Ruby supplies neither SQL nor an arbitrary destination or message body.

The shared declaration in [contract.zig](../examples/durable/contract.zig)
describes operation arguments, returned values, expected rejections, state,
input, and terminal results. State is a closed object containing nonnegative
`attempts`. Input contains a SKU of 1–64 bytes, an integer quantity from 1 to 1,000, and the example's
`fail` switch. Returned state reuses the same state contract. The optional
`mode` input and trusted host fault switches are failure-test instrumentation.

The host also enforces relationships that these shapes cannot express: the
reservation must match the admitted request, a notification must refer to the
exact reservation staged in this transaction, and each may happen only once.
Before commit, the terminal result must match the staged reservation and intent;
a rejected result must have no staged business changes. The next attempt count
must equal the prior count plus one. Type-correct fabricated or duplicate
notifications cannot authorize additional work.

## The host interface

[Host](../examples/durable/host.zig) hides request admission, transaction
ownership, worker verification, persistence, retention, and recovery behind
seven operations:

| Operation | Behavior |
| --- | --- |
| `Host.open(allocator, database_path, worker_executables, options)` | Open or initialize the source database and validate its role, namespace, and pinned application identity. `worker_executables` holds one confined worker per application version, ordered like the build's application table. |
| `execute(.{ .turn_id, .expected_revision, .input })` | Return the original committed result, or prepare, verify, and atomically commit a new turn under the active application. |
| `upgrade(.{ .upgrade_id, .expected_revision, .target })` | Publish one explicit application upgrade atomically; retries resolve the original decision. |
| `prune(.{ .before_revision, .archive_path })` | Archive acknowledged turns below a revision to a write-ahead file and remove them in one transaction. |
| `status()` | Read a consistent snapshot of the active application, state, and row counts. |
| `replay(turn_id)` | Verify a historical receipt using its original application, state/input, and worker, with no adapters. |
| `dispatch(recipient_path)` | Deliver up to 64 pending committed intents and acknowledge them. |

Call `close()` when finished. `Result` owns its receipt and terminal graph;
call `deinit()` on it. Its `result(allocator)` and `state(allocator)` methods
return separately owned capsules. `reused` indicates a cached committed answer,
and `effect_calls` is zero for that path. A cached answer carries its original
revision even if later turns have committed. `UpgradeResult` is plain data:
the published revision, whether a committed upgrade record answered the retry,
and the active application label.

The worker executable, manifest, catalogue, and adapters form one application
version. The build registers both versions — `inventory/v1` and `inventory/v2`
— with their own bundles, contracts, and worker executables, in
[applications.zig](../examples/durable/applications.zig); that table also
declares the single supported upgrade path and its state transform. `Host` is
an example module, not a new generic database interface in `mruby`.

## Admission and publication

The caller provides a stable turn ID, the expected state revision, and an inert
input capsule. The host owns snapshots of the request before invoking callbacks.
It fingerprints the actual application/contract identity, persistent namespace,
turn ID, expected revision, and exact encoded input bytes. Semantically similar
but differently encoded inputs are different requests.

The host validates its owned input against the numeric policy and input
contract before any admission write. It validates current state under the
admission lock and again under the business transaction lock. Malformed starting
values cannot reserve a new turn ID. A committed retry still returns its original
result independently of later state revisions.
The whole-turn contract digest participates in the fingerprint alongside code
and operation contracts, so changing only that schema also changes retry identity.

Admission reserves a new ID for that fingerprint in a short committed
transaction. An already stale, previously unknown request is rejected before
admission. Once admitted, the ID remains bound even if Ruby fails or the host
dies. A matching uncommitted request can retry while its expected revision is
still current; a changed request must use a new ID.

```mermaid
sequenceDiagram
    participant Caller
    participant Host
    participant DB as Source SQLite
    participant Record as Recording worker
    participant Replay as Verification worker
    Caller->>Host: ID, expected revision, input
    Host->>DB: Commit immutable ID admission
    Host->>DB: BEGIN IMMEDIATE; check revision
    Host->>Record: Explicit state and input
    Record->>Host: Performed effect requests
    Host->>DB: Stage inventory and outbox changes
    Host-->>Record: Recorded observations
    Record-->>Host: Complete receipt
    Host->>Replay: Replay receipt without adapters
    Replay-->>Host: Verified result and next state
    Host->>DB: Persist state, receipt, and turn record
    Host->>DB: COMMIT all business changes
    Host-->>Caller: Owned committed result
```

The business transaction stays open across recording and mandatory fresh replay.
It acquires the SQLite writer reservation before reading state or invoking
adapters. Another writer cannot change the starting snapshot during execution.
The host checks committed retries again after acquiring each transaction, so
concurrent attempts cannot execute an already committed turn twice.

On success, inventory changes, reservations, the next state revision, the
complete receipt, and outbox rows commit together. Deferred foreign keys prevent
orphan reservations and intents from committing without their turn record.
The reply's owned allocations finish before `COMMIT`; an allocation failure
cannot occur while constructing the result after publication.

An exception, worker failure, verification failure, or precommit persistence
failure rolls back business changes. Admission metadata remains. An expected
`OutOfStock` rejection is different: Ruby handles it and returns a valid result,
so the attempt count and state revision advance without reserving stock or
enqueuing an intent.

The adapter snapshot identity includes ordered inventory/reservation data,
namespace, revision, and turn ID. The turn ID matters because it changes the
intent ID returned to Ruby. Replay uses the originally stored identity and
observations; it does not rerun database writes or attest to current stock.

## Application identity and upgrades

Every application version has a pinned identity: a SHA-256 digest of its
label, artifact code identity, operation catalogue, whole-turn contract,
bootstrap contract, and the build's RITE compatibility fingerprint. The ledger
stores the active version's identity in `durable_metadata`, and each committed
turn records the version that produced it in `turn_versions`. Opening a ledger
fails with `ApplicationIdentityMismatch` unless its pinned identity is one of
the versions compiled into the host; a missing or malformed pin fails with
`UnknownApplication`. Changing code, contracts, labels, or the numeric profile
therefore fails closed at open instead of silently adopting existing state —
the schema-only fixture demonstrates this by failing to open a ledger after
changing only the whole-turn schema.

`inventory/v2` is the one newer version. Its Ruby source is
[inventory_v2.rb](../examples/durable/inventory_v2.rb): the same two effect
sites, while state additionally counts declared `OutOfStock` rejections and
the fault-instrumentation `mode` input is gone. Its whole-turn contract,
bundle, and worker executable differ from v1, so v1 requests can never be
reinterpreted under v2 code or contracts.

`upgrade` publishes one such transition in a single `BEGIN IMMEDIATE`
transaction, with no worker and no adapters:

1. A committed `upgrades` record for this ID answers first, recovering a lost
   reply with its original decision. A changed expectation under the same ID
   fails with `UpgradeIdConflict`.
2. The active application must be the declared source version; wrong
   direction, an unknown target, or an already-upgraded ledger fails with
   `UnsupportedApplicationUpgrade` / `UnknownApplication`.
3. The accepted state must validate under the source version's contract at the
   expected revision, or the attempt fails with `StaleState` and changes
   nothing.
4. The declared transform (`{attempts}` → `{attempts, rejections: 0}`) runs as
   trusted host policy and its output is validated against the target state
   contract. The attempt count is preserved; pre-upgrade rejection history was
   never recorded by v1 and is explicitly not reconstructed.
5. New state at `revision + 1`, the new active identity, and a provenance row
   (upgrade ID, request fingerprint, both application identities, and both
   revisions) commit atomically.

Because every upgrade publishes a new revision, an admitted v1 request that
has not committed fails with `StaleState` once the upgrade lands, and retrying
a committed or admitted v1 request under the now-active v2 fails with
`TurnIdConflict` rather than re-executing or reinterpreting it. Historical
replay is unaffected: `replay(turn_id)` resolves the recorded version and
dispatches to that version's bundle, contracts, and worker executable, so a
v1 receipt still replays on v1 after the ledger upgraded. Existing receipts,
admissions, outbox rows, and notification identities are never rewritten.

## Retention

`prune` removes committed turns with `revision` strictly below an explicit
bound, together with their version, reservation, and outbox rows. Before any
deletion it writes a write-ahead archive — one JSON line per pruned turn with
its ID, revision, pinned application identity, and base64 receipt — and
atomically replaces the target file, so a crash before the database commit
leaves an archive whose entries simply get rewritten by the retry. Pruning is
refused with `UndeliveredIntents` while any affected turn still has a pending
intent, with `PruneBatchLimit` beyond 256 receipts per call (callers loop over
longer histories), and with `IoUnavailable` when the host was opened without
threaded I/O. A zero-turn prune changes nothing, including an existing archive.

Immutable admissions are never pruned. A pruned turn ID can therefore never
execute again: same-version retries stale out on the kept admission, and
cross-version retries conflict on its fingerprint. Pruned receipts leave
replay (`UnknownTurn`) but remain recoverable from the archive, which is the
audit record for the removed business rows.

## Recovery rules

| Outcome | Caller action |
| --- | --- |
| Success with `reused = true` | Use the original result; no adapter ran. |
| `TurnIdConflict` | Preserve the original request. Use a new ID for different work. After an upgrade this also covers reissued requests from the previous application version. |
| `StaleState` | Read current state and submit a deliberate new request with a new ID. Published upgrades also advance the revision. |
| `UpgradeIdConflict` | Preserve the original upgrade request. Use a new ID for a different upgrade expectation. |
| `UnsupportedApplicationUpgrade` / `UnknownApplication` | The requested direction or pinned application is not one this build supports; no automatic migration or downgrade exists. |
| `UndeliveredIntents` | Deliver and acknowledge pending intents, then retry the prune. |
| `PruneBatchLimit` / `ArchiveLimit` | Prune a smaller revision window; loop over longer histories. |
| `IoUnavailable` | Open the host with threaded I/O before pruning. |
| `DatabaseBusy` | Retry the same request when the competing writer finishes. |
| `CommitIndeterminate` | Close and reopen the host, then retry the exact original request or upgrade. |
| `DatabaseNeedsRecovery` or `HostNeedsRecovery` | Close and reopen before attempting further work. |

Issuing `COMMIT` and receiving an error does not prove whether publication
occurred. For admission and business commits, the host marks itself unusable
and avoids automatic rollback or retry of that transaction. A fresh connection
and the immutable turn ledger resolve
the result: a committed record returns its receipt; otherwise a matching
admission permits another attempt if the base revision still matches. The same
recovery procedure applies when the caller loses the host before receiving its
reply. Opening or initializing the database can also fail; no usable Host is
returned in that case.

The database is trusted persistence. Receipts carry corruption checksums, not
signatures, and a cached lookup does not rerun verification. Deleting ledger
rows, copying a source as a new independent source without changing its
namespace, or externally rewriting business state violates this protocol.
Independent sources sharing a recipient need distinct persistent namespaces.
Application upgrades use the explicit identified operation above; altered code,
contracts, or labels are different pinned applications and cannot open the
ledger at all rather than silently reusing an old request fingerprint.

## Deferred delivery

`Notifications.reservation_created` stages an intent in the source transaction.
Reservation and intent IDs are SHA-256 digests with separate versioned domains,
the persistent namespace, turn ID, and effect ordinal.
Only committed intents are eligible for dispatch. No recipient call occurs
inside turn preparation or replay.

The local recipient commits the intent ID, destination, complete payload, and
simulated notification counter together. Repeating identical bytes under the
same ID succeeds without incrementing the counter. Changed bytes produce
`IntentConflict`. Source acknowledgement is a subsequent transaction that
matches the complete immutable intent.

A host killed after recipient commit but before source acknowledgement will
deliver that intent again. The recipient's durable ID check prevents a second
notification. Multiple dispatchers may also attempt the same intent. This is
retryable delivery with recipient deduplication; arbitrary network services
require their own durable idempotency contract. A generic HTTP call or email
send does not inherit this guarantee.

## Evidence and limits

The integration tests kill and reap real host processes at admission, transaction
begin, both domain effects, the stock update and reservation insertion inside
`Stock.reserve`, preparation, before/after business commit, and
before delivery, after recipient commit, and after source acknowledgement. They
reopen the databases and check retries, original receipts, state, inventory,
and recipient counts. Additional tests cover competing writers, changed input,
caller buffer mutation, contract violations and malformed adapter outcomes, fabricated or
duplicate notifications, schema-only application identity changes, allocation failure
after staging/preparation, reported
commit errors, failed rollback, conflicting recipient IDs, and database aliases.
The upgrade suite kills real hosts around upgrade publication, denies its
COMMIT through an authorizer, corrupts the pinned application identity, and
exercises unknown targets, reversed direction, stale revisions, committed
upgrade retries, request identity across the upgrade, per-version replay
routing with a missing v2 executable, pending v1 intent delivery, and an
upgrade serializing against a paused turn's open business transaction.

These are process-crash tests. They do not simulate power loss, storage firmware
failures, or a malicious host. Native adapters, SQLite, the filesystem, and the
[strict worker trust assumptions](effects-workers.md#what-this-does-not-establish)
remain part of the contract. No consensus acceptance or replication is added.

The opt-in dependency is SQLite 3.51.3, including the
[WAL reset fix](https://www.sqlite.org/wal.html#walresetbug). Each connection
requires WAL and `synchronous=FULL`; macOS also enables `fullfsync`. Use a local
filesystem with SQLite locking/sync semantics. SQLite's
[WAL documentation](https://www.sqlite.org/wal.html) explains why network
filesystems are unsupported and why the live WAL belongs with the database.

The example is deliberately small: two domain operations implemented using
host-owned SQL with bound parameters,
32 effect records, 64 KiB state/input bounds, 256 KiB receipts, and at most 4,096
combined inventory/reservation rows when computing the starting identity.
Exceeding that row bound returns `AdapterStateLimit` before starting a worker.
The adapter constructs notification payloads for the fixed `reservations`
destination; guests cannot choose another destination.
SQLite uses a [100 ms busy timeout](https://www.sqlite.org/c3ref/busy_timeout.html),
which bounds accumulated busy-handler sleep rather than total call time. Host
filesystem and adapter work remains synchronous and cannot be interrupted by
the worker deadline. SQLite is built with thread safety enabled, but each
connection uses `NOMUTEX`: serialize use of each host/connection, as described
in SQLite's [threading contract](https://www.sqlite.org/threadsafe.html).
The typed example uses source ledger schema **3**, which adds the pinned
application identity, per-turn version records, and the upgrade journal.
Opening a schema-1 or schema-2 ledger returns `UnsupportedDurableSchema` and
preserves it; migration is never automatic. Exactly one upgrade path
(`inventory/v1` → `inventory/v2`) is demonstrated; downgrades and multi-version
fan-out beyond two build-time-known versions remain unsupported. There is no
background dispatcher, replicated commit protocol, or production transport in
this example.

Schema-2 ledgers have one explicit, offline way forward: the installed
`effects-durable-migrate` tool builds a fresh schema-3 ledger beside the
source, which is only ever read:

```sh
./zig-out/bin/effects-durable-migrate ./old-schema2.sqlite ./migrated.sqlite inventory/v1
```

The operator names the application every historical turn is pinned to —
version provenance is an explicit input, never inferred, because schema-2
ledgers predate per-turn version records. The accepted state and every
receipt, terminal graph, and effect trace are validated under that
application's contracts before the target is created, so a rejected
migration leaves no target ledger at all. The source keeps its namespace and
role; admissions, turns (now with version records), reservations, outbox
delivery flags, stock, and the accepted state carry over byte for byte, and
retry identity survives: a migrated committed request reuses its original
receipt and replays bit for bit. Schema-1 ledgers remain permanently
read-only-rejected; their SQL-shaped domain model predates the typed turn
contracts and is archived rather than reinterpreted.

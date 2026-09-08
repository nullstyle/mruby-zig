# Part 8 — Application upgrades: changing code under live state

**Prerequisites**: [Part 7](07-durable.md). Same commands and flags:

```sh
mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true
mise x -- zig build test-effects-durable -Deffects-strict=true -Dsqlite-effects=true
```

Sooner or later the Ruby must change while the ledger keeps its history. The
durable example's answer is deliberately narrow and explicit: **application
versions are build-time-known, upgrades are identified operations, and old
requests can never become new requests.**

## Two versions, one build

[examples/durable/applications.zig](../../examples/durable/applications.zig)
registers both versions side by side:

- `inventory/v1` — [inventory.rb](../../examples/durable/inventory.rb);
  state is `{"attempts" => n}`.
- `inventory/v2` — [inventory_v2.rb](../../examples/durable/inventory_v2.rb);
  the same two effect sites, while state additionally counts declared
  `OutOfStock` rejections and the fault-instrumentation `mode` input is gone.

The table also declares the **single supported upgrade path** and its trusted
state transform (`{attempts}` → `{attempts, rejections: 0}` — v1 never
recorded rejections, so the counter starts at zero by explicit policy, not
reconstruction).

Each version has a pinned identity: a SHA-256 digest over its label, artifact
code identity, operation catalogue, whole-turn contract, bootstrap contract,
and the build's RITE compatibility fingerprint. `Host.open` fails with
`ApplicationIdentityMismatch` unless the ledger's pinned identity is one of
the versions compiled into the host — changing code, contracts, labels, or
the numeric profile fails closed at open instead of silently adopting
existing state. (The test suite demonstrates this with a schema-only fixture:
change only the whole-turn schema and the ledger refuses to open.)

## Publishing an upgrade

```zig
const upgrade = try host.upgrade(.{ .upgrade_id = "demo-upgrade", .expected_revision = 1, .target = "inventory/v2" });
```

One `BEGIN IMMEDIATE` transaction, no worker, no adapters:

1. A committed `upgrades` record for this ID answers first — a lost reply
   recovers the original decision (`reused`). A changed expectation under
   the same ID fails `UpgradeIdConflict`.
2. The active application must be the declared source version. Wrong
   direction, unknown target, or an already-upgraded ledger fails
   `UnsupportedApplicationUpgrade` / `UnknownApplication`.
3. The accepted state validates under the *source* version's contract at the
   expected revision, or the attempt fails `StaleState` and changes nothing.
4. The declared transform runs as trusted host policy; its output validates
   under the *target* state contract.
5. New state at `revision + 1`, the new active identity, and a provenance row
   (upgrade ID, request fingerprint, both identities, both revisions) commit
   atomically.

Because an upgrade publishes a revision just like a turn, an admitted v1
request that has not committed goes `StaleState` when the upgrade lands.

## Old requests never become new requests

This is the property the whole design protects, and it falls out of
[Part 7](07-durable.md)'s fingerprints: request fingerprints include the
active application's code/catalogue/turn-contract identities. After the
upgrade:

- Retrying a committed or admitted **v1 request** fails `TurnIdConflict` —
  its admission's fingerprint is not computable under v2's identity.
- Same-version stale IDs fail `StaleState`, exactly as before.
- There is no reinterpretation path. The demo's second run asserts the
  `TurnIdConflict` outcome directly.

History is untouched: existing receipts, admissions, outbox rows, and
notification identities are never rewritten. `replay(turn_id)` resolves the
recording version from `turn_versions` and dispatches to *that* version's
bundle, contracts, and worker executable — a v1 receipt still replays on v1
after the ledger upgraded. Pending v1 intents keep their IDs and remain
deliverable ([Part 10](10-delivery.md)).

## What the suite tortures

The upgrade tests kill real hosts around upgrade publication, deny the
upgrade's `COMMIT` through an authorizer (resolving via the committed record
after reopen), corrupt the pinned application identity, and exercise unknown
targets, reversed direction, stale revisions, committed upgrade retries,
request identity across the upgrade, per-version replay routing with a
missing v2 executable, pending v1 intent delivery, and an upgrade serializing
against a paused turn's open business transaction.

## Deliberate limits

Exactly one upgrade path is demonstrated; downgrades and multi-version
fan-out beyond two build-time-known versions are unsupported — the position
is to wait for a real third version before generalizing. Ledger schema is 3;
older schemas are handled by the migration path in [Part 9](09-retention-chain.md).

Continue with [Part 9 — Retention, migration, and the history chain](09-retention-chain.md).

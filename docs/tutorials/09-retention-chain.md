# Part 9 — Retention, migration, and the tamper-evident history chain

**Prerequisites**: [Part 8](08-upgrades.md). Same commands and flags:

```sh
mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true
mise x -- zig build test-effects-durable -Deffects-strict=true -Dsqlite-effects=true
```

Three operations complete the ledger's lifecycle story: bounded retention of
old history, an offline way forward for pre-schema-3 ledgers, and a
tamper-evident chain over everything that ever published a revision.

## Retention: prune with a write-ahead archive

Turns accumulate; `Host.prune` is the explicit, bounded way to remove them:

```zig
const pruned = try host.prune(.{ .before_revision = 4, .archive_path = paths.archive });
```

Turns strictly below the bound — with their version, reservation, and outbox
rows — are archived and deleted in one transaction. The **archive is
write-ahead**: one JSON line per pruned turn (ID, revision, pinned
application identity, base64 receipt) is written and atomically file-replaced
*before* any deletion, so a crash before the database commit leaves an
archive whose entries simply get rewritten by the retry.

The refusal rules are as informative as the happy path:

- `UndeliveredIntents` while any affected turn still has a pending intent —
  deliver and acknowledge first ([Part 10](10-delivery.md)).
- `PruneBatchLimit` beyond 256 receipts per call; callers loop over longer
  histories.
- `IoUnavailable` when the host was opened without threaded I/O.
- A zero-turn prune changes nothing, including an existing archive file.

The load-bearing decision: **admissions are never pruned.** A pruned turn ID
can therefore never execute again — same-version retries stale out on the
kept admission, cross-version retries conflict on its fingerprint. Pruned
receipts leave `replay` (`UnknownTurn`) but remain recoverable from the
archive, which is the audit record for the removed business rows.

## Migration: schema-2 ledgers have one explicit way forward

Schema-3 hosts refuse schema-1 and schema-2 ledgers with
`UnsupportedDurableSchema` and never migrate in place. For schema-2 sources
there is an offline, copy-based tool — installed by the same build:

```sh
./zig-out/bin/effects-durable-migrate ./old-schema2.sqlite ./migrated.sqlite inventory/v1
```

The operator names the application every historical turn is pinned to:
schema-2 ledgers predate per-turn version records, so **provenance is an
explicit input, never inferred**. The accepted state and every receipt,
terminal graph, and effect trace are validated under that application's
contracts *before the target is created* — a rejected migration leaves no
target ledger at all, and the source is only ever read. Namespace, role,
admissions, turns (now with version records), reservations, outbox delivery
flags, stock, and the accepted state carry over byte for byte; retry identity
survives — a migrated committed request reuses its original receipt and
replays bit for bit. Cutover is an explicit operator action. Schema-1 ledgers
stay permanently read-only-rejected; their SQL-shaped domain predates the
typed turn contracts and is archived rather than reinterpreted.

## The history chain

Every revision-publishing event — each committed turn and each published
upgrade — appends one row to an append-only `history_chain` table *inside the
same transaction*. Each row chains the previous row's digest to its own
inputs: event kind, record ID, request fingerprint, revision, and a subject
digest of the event's content (receipt bytes for turns, published state bytes
for upgrades). Links are contiguous from a zero genesis.

```zig
const summary = try host.verifyChain();
// summary.entries, summary.head_revision, summary.head_digest
```

`verifyChain` recomputes every digest, checks every link, requires contiguous
revisions, and cross-checks every entry whose live row still exists. Rewriting
a receipt or a request fingerprint fails with `ChainRewritten`; reordering,
inserting, or removing history fails with `ChainBroken`. Chain rows are never
pruned, so restating or backdating history after retention still breaks a
link, and migrated schema-2 ledgers are chained across their entire history.
(One documented corner: ledgers created by pre-chain schema-3 builds in
development sessions carry an empty chain until their next event — recorded,
not migrated.)

What the chain is *not* is as important: it is **keyless tamper-evidence
inside the trusted-storage model**, not a signature. An attacker who rewrites
the whole ledger can recompute its chain; what they cannot do is rewrite part
of it consistently. The protection becomes binding when
`ChainSummary.head_digest` is exported and anchored outside the ledger —
truncating the tail of a chain is otherwise undetectable. Receipt signatures
remain a separate, deliberately ungated decision.

## What you can now build

A ledger with a complete, documented lifecycle: bounded retention without
losing fail-closed identity, an operator-controlled path for old formats, and
internally consistent history whose head can be anchored externally.

Continue with [Part 10 — Delivery and idempotency](10-delivery.md).

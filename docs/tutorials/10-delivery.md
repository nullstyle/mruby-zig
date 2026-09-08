# Part 10 — Delivery and idempotency: the last mile out

**Prerequisites**: [Part 9](09-retention-chain.md). Same commands and flags:

```sh
mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true
mise x -- zig build test-effects-durable -Deffects-strict=true -Dsqlite-effects=true
```

Everything committed so far stays inside the ledger. Delivery is the
protocol for the last mile — telling the outside world what happened — and
it is deliberately built on **at-least-once delivery with recipient-side
deduplication**, because that is the only thing that can actually be built.

## The outbox and the local recipient

`Notifications.reservation_created` stages an intent in the source
transaction. Reservation and intent IDs are SHA-256 digests over separate
versioned domains, the persistent namespace, the turn ID, and the effect
ordinal — stable, derived, and never reused. Only committed intents are
eligible for dispatch, and no recipient call happens inside turn preparation
or replay.

The local recipient ([examples/durable/delivery.zig](../../examples/durable/delivery.zig))
is a second SQLite database whose acceptance transaction commits the intent
ID, destination, complete payload, and a simulated notification counter
together. Repeating identical bytes under the same ID succeeds without
incrementing the counter; changed bytes under the same ID fail with
`IntentConflict`. Source acknowledgement is a later transaction matching the
complete immutable row.

The crash window is the heart of it: a host killed after recipient commit but
before source acknowledgement will deliver that intent again, and the
recipient's stored ID prevents a second notification. Multiple dispatchers
may race; the recipient still sees one effect. `Host.dispatch(recipient_path)`
drives this with a bounded batch of 64.

That is the contract to internalize: **retryable delivery with recipient
deduplication.** Arbitrary network services need their own durable
idempotency contract — a generic HTTP call or email send does not inherit
this.

## The HTTP adapter example

The production-delivery adapter example
([examples/durable/http_delivery.zig](../../examples/durable/http_delivery.zig)
and [examples/durable/http_recipient.zig](../../examples/durable/http_recipient.zig))
moves the identical contract onto a real transport. The installed double:

```sh
./zig-out/bin/effects-durable-http-recipient ./recipient.sqlite
```

binds an ephemeral loopback port, prints one `LISTENING <port>` line on
stdout once its database is initialized, and serves until killed. Each
delivery is:

```
POST /<destination>
Idempotency-Key: <stable intent ID>
Content-Type: application/octet-stream

<the exact outbox payload bytes>
```

The double runs the *same* durable recipient transaction behind HTTP, so the
dedup contract is byte-identical to the local path — a test double standing
in for any recipient service that durably records idempotency keys. The
dispatcher client (`http_delivery.dispatch`) mirrors `Host.dispatch`'s shape:
batch bounded at 64, one intent at a time, and — only after a 200 response,
which is the recipient's committed proof — a source acknowledgement in its
own transaction. The three delivery checkpoints from the local path
(`before_delivery`, `after_recipient_commit`, `after_delivery_ack`) cover the
same crash window: a dispatcher that dies between send and acknowledgement
re-sends the identical bytes, and the recipient's stored key prevents a
second effect.

## What the tests prove

The HTTP suite spawns the double as a real child process and verifies, all
through public interfaces:

- **Byte-identical transport**: the recipient's stored payload equals the
  staged outbox payload under the same intent ID.
- **The crash window**: a competing writer makes the acknowledgement fail
  exactly where the window sits; the recipient has the effect, the source
  does not; retry re-sends; the notification count stays at one.
- **Key discipline**: identical repeats succeed; the same key with different
  bytes (or a different destination) returns 409; keyless requests are
  refused before any commit.
- **Fail-closed delivery**: with the recipient down, dispatch changes nothing
  and reports the transport failure; after restart, delivery resumes and
  completes.

## Limits, stated plainly

- This is **not exactly-once delivery**. A recipient that ignores the
  idempotency key observes duplicates; one that acknowledges before
  committing can lose an intent. Exactly-once to arbitrary services is not a
  thing this or any outbox can promise.
- The example has **no TLS, authentication, rate limiting, or request
  timeouts**, maps destinations to URL path segments (destinations must be
  path-safe; the durable adapter's fixed destination is), and **trusts the
  recipient's 200 as proof of its commit**.
- The embedding library remains transport-free; both pieces are example code
  in the durable example. There is no background dispatcher — delivery is an
  explicit, caller-driven operation.

## Where the series ends — and what remains deliberately open

You now hold the whole machine: build-time-compiled Ruby with explicit,
granted, recorded, replay-verified effects; confined execution; a durable,
recoverable, upgradable, prunable, tamper-evident ledger; and a delivery
protocol with honest idempotency semantics. The reference docs
([effects.md](../effects.md) through
[effects-durable.md](../effects-durable.md)) specify each layer, and
[plans/effects.md](../plans/effects.md) records how the design got here.

The deliberately open items are decision-gated, not forgotten: consensus
acceptance behind the turn-transaction seam (reserved for a separate
explicit instruction), Ed25519 receipt signatures (gated on a real
third-party verifier; the hash chain is the foundation), Ruby-level custom
and resumable handlers (needs a privilege/nesting design; mruby fiber limits
are documented), and generalization beyond two application versions. None of
them weaken anything you have built.

Back to the [index](README.md).

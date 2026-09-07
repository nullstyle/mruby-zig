# Inventory with explicit effects

The [Ruby application](inventory.rb) reserves stock through `DB.rows` and
`DB.execute`, rescues `Effect::Rejected` when the conditional update reports
`OutOfStock`, and captures an `Outbox.enqueue` intent after a successful
reservation. Only `Effect.perform` executes a request.

```sh
mise x -- zig build run-effects-inventory -Deffects-strict=true -Dsqlite-effects=true -Doptimize=ReleaseSafe
mise x -- zig build test-effects-strict -Deffects-strict=true -Dsqlite-effects=true
mise x -- zig build test-effects-inventory -Dsqlite-effects=true -Dno-compiler -Dgem-set=minimal -Doptimize=ReleaseSafe
```

SQLite is optional. Ordinary builds retain their existing dependencies; the
inventory targets require the explicit flag and compile a hash-pinned official
amalgamation without a system SQLite installation. The pinned version is
[SQLite 3.51.3](https://www.sqlite.org/releaselog/3_51_3.html), fetched from its
[official source archive](https://www.sqlite.org/2026/sqlite-amalgamation-3510300.zip).
The `sqlite3.c` SHA3-256 matches the release page:
`32d5424f97e0a7fc5ed2f6335afbb58be4e0298bd7117a34e39d345ff13d859e`.
This release includes the upstream [WAL reset corruption fix](https://www.sqlite.org/wal.html#walresetbug)
needed by the separate durable example's concurrent database connections.

The [host](../effects_inventory.zig) owns one disposable in-memory database and
one fresh VM per invocation. With `-Deffects-strict=true`, it compiles the
application through CodeDB and uses `mruby.strict.Program` for guarded bootstrap
and identified calls. This profile requires minimal gems and no runtime
compiler; its native catalogue is enforced during initialization and calls.
Native effect adapters remain trusted, and this profile does not enable the
generic worker or provide an OS sandbox.
The ordinary compatibility profile remains available through the third command
above and uses trusted host bootstrap. Identity includes the artifact bytes,
strict runtime profile when selected, bootstrap contract, entire fixed starting
fixture, receiver name, actual method, and arguments. A production host must identify
its actual complete source snapshot rather than reuse this example's fixture
identity.

The host begins and commits the private database transaction around the Ruby
turn. An uncaught failure rolls back the database and discards pending intents.
An intent receipt means the host owns an in-memory value: nothing is delivered
over the network, durably retained, or accepted by consensus here. Replay hosts
have no database handle. Replay returns recorded observations and does not
reconstruct mutated database state or create outgoing intents.

Verification covers successful reservation, recoverable rejection, replay of
both branches in fresh VMs, read-only inspection, denial of a write before its
SQLite callback, rollback after preparing an outgoing intent, and attempts to
escape the allowed SQL protocol. The small adapter accepts three exact SQL
statements with bounded parameters, checks `sqlite3_stmt_readonly`, and rejects
transaction control, `PRAGMA`, `ATTACH`, arbitrary functions and extra statements.
This intentionally limited adapter is an example, not a general SQLite wrapper.

The run target also measures live and recording modes after 10 warmups, using
100 fresh fixtures and VMs per mode. It reports median and p95 nanoseconds per
invocation and encoded trace bytes. Timings include the host transaction,
identified method execution, result copying, and trace extraction/encoding.
They exclude fixture creation, VM bootstrap/sealing, and disposal. These
measurements describe this tiny workflow on the machine running it; there is no
performance threshold or claim about production throughput.

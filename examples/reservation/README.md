# Typed reservation turns and effects

This example uses domain operations in an OS-confined Ruby worker. The parent
owns a small inventory, Ruby state, and queued notification intents. It stages
all three and adopts them together only when the caller commits the prepared
turn. The example has no SQLite or network dependency.

```sh
mise x -- zig build run-effects-reservation -Deffects-strict=true
mise x -- zig build test-effects-reservation -Deffects-strict=true

# Installed host and its application-specific worker:
mise x -- zig build install -Deffects-strict=true
./zig-out/bin/effects-reservation ./zig-out/bin/effects-reservation-child
```

The worker is available on the supported strict Linux/macOS targets. The
example requires the strict profile; its CodeDB application is compiled at
build time.

The application in [app.rb](app.rb) marks the two effect sites explicitly:

```ruby
reservation = Effect.perform(Stock.reserve(input["sku"], quantity))
Effect.perform(Notifications.reservation_created(reservation))
```

`ReservationFlow.apply(state, input)` returns `[result, next_state]`. A successful
reservation returns its ID, SKU and quantity and increments both state counters.
A declared `OutOfStock` rejection enters Ruby's `rescue Effect::Rejected`, returns
an `out_of_stock` result and increments only the attempt counter.

[contract.zig](contract.zig) is shared by the parent and child. It describes:

| Turn value | Shape |
| --- | --- |
| State and next state | Closed object with required nonnegative integer `attempts` and `reservations` |
| Input | Closed object with required `sku` (1–64 bytes), `quantity` (integer 1–100), and `mode` (String, at most 64 bytes) |
| Result | Closed object with required `status` (`reserved` or `out_of_stock`), optional reservation object, and optional `code` (`OutOfStock`) |

The parent uses `Turn.Contract.from(contract.turn_contract)` in its options.
The generic worker wrapper embeds that same plain declaration in the child.
Admission checks state and input before a worker starts or the host transaction
begins. The returned result and next state are checked before preparation can
succeed. Next state reuses the state schema.

The result schema checks each field independently. It does not express that
`reserved` requires a reservation while `out_of_stock` requires a code; the Ruby
flow supplies those relationships. No schema union or conditional fields are
introduced in this example.

The operation contracts describe the two explicit effect sites:

| Operation | Arguments | Returned value | Expected rejections |
| --- | --- | --- | --- |
| `Stock.reserve` | SKU string, 1–64 bytes; integer quantity, 1–100 | Reservation object | `OutOfStock`, message at most 512 bytes |
| `Notifications.reservation_created` | Reservation object | `nil` | None |

A reservation is a closed object with String keys `id`, `sku`, and `quantity`.
All are required: ID is an integer from 1 to 1,000,000; SKU and quantity have the
bounds above. The plain schema constants are part of the operation identity.
The `operations_v2` test fixture changes only the quantity maximum to 101 while
retaining the operation versions and bootstrap string. The broker rejects an
old receipt before spawning a worker because the contract identity changed.
The separate `turn_contract_v2` fixture tightens only the state's `attempts`
maximum to 1,000,000. Its operation catalogue, versions, and Ruby code stay the
same. Tests reject the prior receipt before spawning, then run a fresh turn
with a broker and worker that agree on the changed turn contract.

[host.zig](host.zig) models one SKU, `widget`, initially with five units. Reserving
two units prepares stock three and one notification intent. Before commit,
committed stock is still five and there are no committed notifications. Commit
adopts stock, the reservation counter, the returned Ruby state, receipt bytes
and notification intent after completing all fallible allocations. Discard
clears the staged work. This commit is entirely in memory; rerunning the program
starts with a fresh inventory.

The host also checks that a notification refers to the reservation staged in
the current transaction. A type-correct object alone does not authorize a
business action. Adapter-state identity records the starting stock and
reservation counter; replay uses that identity and executes no adapters. Replay
does not rebuild stock or send notifications.

The runnable demonstration checks success and rejection replay, an invalid Ruby
quantity before any stock callback, and invalid handler observations after stock
has been staged. It also checks invalid turn results and next state after both
domain effects have been staged. [tests.zig](tests.zig) additionally verifies
that invalid input and starting state cause no worker spawn, transaction begin,
or adapter call. It covers invalid notification results, Ruby exceptions,
abandoned preparations, allocation failure before commit adoption, and separate
operation- and turn-contract identity changes. The host's
`Fault` switches deliberately produce those malformed observations for the
checks; every failure must leave committed stock, state and notifications
unchanged.

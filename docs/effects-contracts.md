# Typed operation and turn contracts

An operation can declare the values it accepts, returns, and rejects with. The
same plain Zig declaration is compiled into the runtime and host broker. Ruby
marks the actual effect sites:

```ruby
reservation = Effect.perform(Stock.reserve(input["sku"], input["quantity"]))
Effect.perform(Notifications.reservation_created(reservation))
```

Constructing `Stock.reserve(...)` still makes an inert request. `Effect.perform`
checks the grant and argument contract before calling its adapter. A returned
value must satisfy the result contract before Ruby receives it or it enters the
trace. An expected rejection must use a declared code and bounded message.
Replay checks the same contracts without invoking adapters. The worker broker
also checks independently, including every record in a supplied receipt.

Run the complete [reservation example](../examples/reservation/README.md):

```sh
mise x -- zig build run-effects-reservation -Deffects-strict=true
mise x -- zig build test-effects-reservation -Deffects-strict=true
mise x -- zig build test-effects-schema
```

## Share a declaration

Keep these constants in a shared catalogue module imported by the host, worker,
and build. They need no mruby runtime import:

```zig
const sku = .{ .string = .{ .min_bytes = 1, .max_bytes = 64 } };
const quantity = .{ .integer = .{ .min = 1, .max = 100 } };
const reservation = .{ .object = .{
    .{ .name = "id", .schema = .{ .integer = .{ .min = 1, .max = 1_000_000 } } },
    .{ .name = "sku", .schema = sku },
    .{ .name = "quantity", .schema = quantity },
} };

pub const operations = .{.{
    .name = "stock.reserve",
    .namespace = "Stock",
    .method = "reserve",
    .version = @as(u32, 1),
    .arity = @as(usize, 2),
    .authority_bits = @as(u16, 1 << 13),
    .max_result_bytes = @as(usize, 4096),
    .contract = .{
        .arguments = .{ .tuple = .{ sku, quantity } },
        .result = reservation,
        .rejection = .{ .codes = .{"OutOfStock"}, .max_message_bytes = 512 },
    },
}};
```

The outer argument shape must be a tuple with exactly `arity` elements. Declare
zero arguments as `.{ .tuple = .{} }`. Omitting `.rejection` forbids expected
rejections for that typed operation. `effect.describeCatalogue` rejects malformed
contracts and arity drift with `InvalidEffectContract` before installing Ruby
definitions. Build-time worker identity generation rejects malformed catalogues
during compilation.

`effect.describeCatalogue` exposes each normalized `Operation.contract` as an
optional pointer to a compiled `effect.schema.Contract`. Its `arity()` and
`digest()` require no VM. Normalized pointer inputs are copied into owned static
storage at compile time, so later mutation cannot change an installed contract.
Ordinary descriptors without `.contract` retain their
existing behavior and catalogue/application identity calculation. Opt in one
operation at a time.

## Shapes and exactness

| Shape | Accepted values |
| --- | --- |
| `.nil`, `.boolean`, `.integer` | Exactly the corresponding inert type; integers are signed 64-bit. |
| `.float` | A finite Float; integers are not coerced. |
| `.{ .integer = .{ .min = 1, .max = 100 } }` | Inclusive bounds; omitted bounds use the signed 64-bit limits. |
| `.{ .string = .{ .min_bytes = 1, .max_bytes = 64 } }` | String bytes within bounds; `max_bytes` is required, minimum defaults to zero. |
| `.{ .tuple = .{ .integer, .boolean } }` | Array with exactly these two positional values. |
| `.{ .array = .{ .element = .integer, .max_items = 32 } }` | Array of matching elements; maximum required, optional `min_items` defaults to zero. |
| `.{ .object = .{.{ .name = "count", .schema = .integer }} }` | Hash containing exactly the declared String keys and matching values. |
| `.{ .nullable = .integer }` | `nil` or the given shape. |
| `.{ .enum_string = .{ "ready", "done" } }` | Exactly one listed String byte sequence. |

An object field can specify `.optional = true`; an absent field and a present
`nil` remain different. Use `.nullable` to accept `nil`. Symbol keys, unknown
keys, and non-nil Hash defaults are rejected. Field/enum order does not affect
contract identity. Array order does. String bounds count bytes and do not imply
UTF-8 validation. There are no Ruby conversion, accessor, serialization, or
validation callbacks.

Individual field names and enum/rejection strings contain 1–128 bytes. String
and array bounds fit unsigned 32-bit integers; capsule limits can impose a
smaller effective bound.

Aliases are accepted; cycles are rejected. The compiled schema is bounded to
128 nodes, 256 edges, 4 KiB of names/enum text, and depth 32. Validation performs
at most 65,536 charged steps and descends at most 64 levels. Repeated visits
through aliases consume that budget. Capsule byte, graph, request, and result
limits still apply independently. There are no recursive schema references or
general unions in this first version.

## Rejections and failures

An adapter uses the existing data-only API:

```zig
return mruby.effect.data.reject(allocator, "OutOfStock", "not enough stock", 4096);
```

The payload remains an exact `[code String, message String]` pair. Codes must
match the declared nonempty set; the message obeys its byte bound. Ruby can
handle an expected rejection normally:

```ruby
begin
  reservation = Effect.perform(Stock.reserve(sku, quantity))
rescue Effect::Rejected => error
  raise error unless error.code == "OutOfStock"
  reservation = nil
end
```

The pinned mruby 4.0.0 requires `raise error` to preserve a rescued exception's
identity, code, and message; bare `raise` creates an empty `RuntimeError`, as
documented in its [language limitations](https://github.com/mruby/mruby/blob/4.0.0/doc/limitations.md#kernelraise-in-rescue-clause).

A schema mismatch returns `EffectContractViolation` and poisons the execution,
even if Ruby rescues its exception. A malformed capsule remains a codec/request
failure. Strict preparation discards staged work on either failure. Validation
cannot undo an adapter that already performed an external write; adapters must
continue to stage writes and notification intents under the host transaction.

The owned [diagnostic](effects-diagnostics.md) includes
`effect_detail.contract_detail`: `side` (`arguments`, `result`, or `rejection`),
reason, path, expected kind, and actual kind when a value exists. For example,
a zero quantity reports `integer_range` at `$[1]`. Paths are bounded to 256 bytes
with an explicit truncation flag. JSON places these fields under
`effect.contract`. Source information is included when available; formatting
never calls Ruby.

## Identity and remaining responsibilities

Schema digests participate in both catalogue and worker application identity.
Changing a bound, field, optionality, result shape, or rejection set invalidates
an old receipt even when `.version` stays unchanged. Keep versioning semantic
changes too: schemas cannot describe the meaning of an adapter's actions.
Private worker protocol 1.3 carries the expanded diagnostics; deploy matching
host and child builds. Stored receipt formats remain unchanged.

Contracts check value shapes, not business authorization. The example host
checks that a notification refers to the reservation staged by the same
transaction. It commits stock, Ruby state, receipt, and intent together in
memory. The [durable host](effects-durable.md) brings the same operation-site
style to SQLite with its own durable reservation contract: stable digest IDs,
remaining stock, and a notification intent ID. It enforces request/reservation/
notification relationships, validates whole-turn data before publication, and
recovers committed turns and delivery after process crashes. The two examples
have distinct application identities and receipt contracts.

The VM-free receipt inspector has no application catalogue and performs
structural validation only. Typed effects do not add static effect inference,
prove native adapter behavior, or establish cross-platform floating-point
determinism.

## Contract for the whole turn

An optional turn contract checks starting state, input, result, and returned
state. Returned state uses the same shape as starting state so it can be supplied
to a subsequent turn. Put the plain declaration beside the operation catalogue:

```zig
pub const turn_contract = .{
    .state = .{ .object = .{
        .{ .name = "count", .schema = .{ .integer = .{ .min = 0 } } },
    } },
    .input = .{ .integer = .{ .min = 1, .max = 100 } },
    .result = .integer,
};
```

Compile it into the host's options:

```zig
const turn_shape = comptime try mruby.strict.Turn.Contract.from(application.turn_contract);
// With Turn.prepare / Turn.replay:
const turn_options: mruby.strict.Turn.Options = .{
    .contract = turn_shape,
    .allowed = application.grants,
};
// With Worker.prepare / Worker.replay:
const worker_options: mruby.strict.Worker.Options = .{ .turn = turn_options };
```

The generic worker built by `addEffectWorker` automatically compiles the shared
catalogue module's optional `turn_contract` declaration. The host must supply
the matching contract in its options. Custom worker entrypoints can use
`Runtime.serveWithContract`; `Runtime.serve` retains its contract-free behavior.
The shared declaration stays plain Zig, so build tools never import a runtime
just to read it.

Admission takes a validated owned copy of the contract and input capsules before
creating a VM or beginning a transaction. A later host callback cannot mutate
the captured contract. State and input are checked against that copy before
application initialization. Malformed normalized contracts return
`InvalidTurnContract`; values with valid capsule framing but the wrong shape
return `TurnContractViolation`.

After execution, the result and next state are checked before preparation
succeeds. A mismatch discards staged host work. Both the child and broker check
terminal values independently. Supplied receipt terminal values are checked
before replay execution. Turn digests contribute to invocation input identity;
the worker also includes the digest in its application handshake. Changing or
removing a contract invalidates receipts that used it. The broker checks those
receipt identities before spawning a replay worker. Omitting the contract keeps
the existing identity calculation and general inert-capsule behavior.

Turn diagnostics have `kind = contract` and a separate `contract_detail` with
`side` (`state`, `input`, `result`, or `next_state`) and `detail` containing the
schema reason, path, expected kind, and actual kind. Paths start at the individual
value's root. JSON places them under `turn_contract`. Input admission reports
the setup phase; invalid results report the phase that produced them.

Each of the three shapes has its own node, edge, text, depth, and validation-work
limits described above. The same bounded compiler and validator serve operations
and turns. Normalized graphs additionally cap expanded digest input at 64 KiB;
shared schema nodes cannot cause exponential hashing. Capsule policy limits
still apply, even when a schema permits a larger value. Cross-root aliases and
frozen flags remain part of the exact terminal graph used for replay.

The reservation example declares closed state/input/result objects and tests
invalid caller values, invalid returned values after staging stock and intent,
turn-schema-only identity changes, and replay without adapters. Optional fields
do not enforce relationships between fields: business rules such as a
`reserved` result requiring a matching reservation remain application/host
responsibilities.

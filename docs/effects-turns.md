# Explicit state and verified turns

`mruby.strict.Turn` runs each turn in a fresh strict VM, accepts only data-only
effect handlers, and verifies both the effect sequence and terminal value graph
during replay. Inputs, outputs, and receipts contain StateCapsule bytes; the
interface exposes no Ruby VM or Value.

```sh
mise x -- zig build run-effects-turn -Deffects-strict=true
mise x -- zig build test-effects-turn -Deffects-strict=true
```

The [counter example](../examples/effects_turn.zig) stages state changes,
outgoing intents, and output before explicit host commit. It checks fresh-VM
replay, continuation from returned state, expected rejections, discard, and
rejection of altered terminal results/state. No SQLite or service is required.

## The Ruby contract

An application method receives `(state, input)` and returns `[result, next_state]`:

```ruby
class Counter
  def self.apply(state, input)
    state["count"] += input["delta"]
    now = Effect.perform(Clock.now)
    Effect.perform(Intent.prepare({"count" => state["count"], "at" => now}))
    [{"count" => state["count"]}, state]
  end
end
```

Only performed operations are annotated. Each call loads CodeDB definitions
under the strict initialization rules, imports the two input capsules as
independent graphs, and invokes the method once. Globals and private VM state
disappear afterward. Anything a later turn needs must be returned explicitly.
Pure applications can use an empty operation catalogue.

Pass `Options.diagnostic` to retain a bounded failure explanation after VM
destruction. [Diagnostics and receipt inspection](effects-diagnostics.md) covers
native source locations, safe JSON formatting, and the offline inspector.

The terminal value must be an inert, exact two-element Array accepted by the
StateCapsule codec. No serialization/coercion hooks are invoked. The runner
exports the entire pair together, preserving aliases between result and next
state. Replacing `[x, x]` with two independent copies changes the commitment.

## Data-only handlers

A handler receives context, an allocator, and the capsule of positional
arguments. It returns a capsule owned by the supplied allocator:

```zig
fn clockNow(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    arguments: mruby.artifact.StateCapsuleView,
) !mruby.effect.DataOutcome {
    _ = context;
    _ = arguments;
    return .{ .returned = try mruby.effect.data.encode(
        allocator, .{ .integer = 1_700_000_000 }, 256,
    ) };
}
```

`effect.data.Document.decode` owns a copy of a capsule and exposes `root()`,
`at(index)`, `get(string_key)`, `getSymbol(symbol_key)`, `pair(index)`, and typed
readers such as `asInteger()` and `asString()`. Refs/strings borrow the Document;
call `deinit()` when finished. Validation uses the existing inert codec without
entering Ruby. Aliases/cycles remain in the graph; `nodeId()` is a document-local
index, never a VM address.

`data.encode` constructs a capsule from a Zig value tree and freezes string Hash
keys automatically. `data.clone` copies an existing capsule; `data.encodeRef`
extracts a reachable subgraph, preserving aliases, cycles, frozen flags, and
Hash defaults. `data.encodeRefs` combines existing roots into a new Array;
references from one Document share nodes, while separate Documents stay
independent. Returned capsules belong to the supplied allocator.

For expected application rejection, return
`data.reject(allocator, code, message, max_bytes)`. Ruby can rescue
`Effect::Rejected`. Zig errors, malformed/oversized capsules, and invalid
rejection payloads invalidate the turn even if Ruby rescues the exception.

The dispatcher always frees returned handler capsules with its allocator.
Never return borrowed arguments, static storage, or bytes from another
allocator. Arguments are borrowed only during the callback; retained data needs
a copy. Bindings carry only data handlers:

```zig
const bindings = [_]mruby.effect.DataBinding{
    .{ .name = "clock.now", .handler = clockNow },
};
```

General `effect.Binding` also accepts `.data_handler`, with exactly one handler
form per binding. `strict.Turn.Host` accepts only `DataBinding`, preventing
accidental installation of a handler taking Vm/Value.

## Prepare, commit, or discard

```zig
var prepared = try mruby.strict.Turn.prepare(
    allocator, manifest, "counter", operations,
    .{ .receiver = "Counter", .state = state.view(), .input = input.view() },
    .{ .bindings = &bindings, .transaction = transaction },
    .{ .allowed = grants, .bootstrap_identity = adapter_contract_digest },
);
defer prepared.deinit();

// Inspect prepared.terminal() and prepared.receipt() before deciding.
try prepared.commit();
```

The default method is `apply`. Preparation always records. It copies input
capsules and names, validates configuration, initializes a fresh VM, and imports
values before beginning a host transaction. Handler context must remain alive
until the Prepared owner is resolved and destroyed.

A transaction supplies `begin(context)`,
`commit(context, terminal_capsule, receipt_bytes)`, and `discard(context)`.
Handlers must stage provisional writes/intents in that transaction. The commit
hook can persist next state and staged work together. Without a transaction,
the runner controls no external host writes.

Every fallible output/receipt allocation finishes before preparation succeeds.
The VM is already destroyed when Prepared returns. Failure after a successful
begin invokes discard; a failed begin cleans up its own partial setup. Discard
must not fail. Explicit `discard()` or abandonment via `deinit()` discards pending
work exactly once.

| Commit outcome | Runner behavior |
| --- | --- |
| `committed` | Marks preparation committed; no later discard. |
| `rejected` | Means nothing was published; invokes discard and returns `CommitRejected`. |
| `indeterminate`, or a thrown error | Returns `CommitIndeterminate`; never automatically discards or retries. |

An uncertain commit requires host reconciliation. A second commit attempt on
the same Prepared returns `TurnAlreadyResolved`. Receipt and terminal bytes
remain inspectable until `deinit()`, including after uncertainty; retain copies
if reconciliation outlives the owner. Owned objects follow Zig's move-only
ownership convention and must not be copied and freed twice.

## Replay and continuation

```zig
var verified = try mruby.strict.Turn.replay(
    allocator, manifest, "counter", operations,
    .{ .receiver = "Counter", .state = state.view(), .input = input.view() },
    receipt_bytes,
    .{ .allowed = grants, .bootstrap_identity = adapter_contract_digest },
);
defer verified.deinit();

var next_state = try verified.state(allocator);
defer next_state.deinit(allocator);
```

Replay accepts no bindings or transaction and invokes no handlers or
begin/commit/discard hooks. It checks receipt framing, the complete effect trace,
terminal graph, invocation identities, and exact terminal bytes. Invalid typed
terminal values fail earlier with `TurnContractViolation`. When both terminal
graphs satisfy capsule and turn contracts, changed result, state, aliases, or
frozen flags fail with `TerminalMismatch`, even with valid checksums.
`Options.diagnostic` receives owned effect/native/contract details or terminal
hashes and the first differing encoded byte offset.

Prepared and Verified expose borrowed `terminal()` and `receipt()` bytes.
`result(allocator)` and `state(allocator)` return independent owned capsules;
aliases inside each extracted root survive. The joint terminal capsule remains
authoritative for comparing cross-root aliases.

Ruby starting-state/input identities derive from actual owned capsule bytes.
`bootstrap_identity` describes the native adapter contract;
`adapter_state_identity` attests relevant external starting state. Artifact and
dependency identities, method, receiver, grants, and operation catalogue retain
the strict Program checks.

## Limits and remaining trust

Graphs obey the intersection of sandbox capsule policy, `capsule_limits`, and
data codec bounds (depth 64, 16,384 nodes, 65,536 edges). Effect records and receipt
framing have separate limits. These are individual bounds, not a total process
memory cap. [Typed contracts](effects-contracts.md) can constrain both individual
operations and the whole turn through `Options.contract`. State/input validation
precedes VM creation and host begin; result/next-state validation precedes
successful preparation. Without a turn contract those values use general inert
capsules. Finite instruction gas
and native restrictions remain in force; native handler work is not preempted.

Data-only adapters reduce accidental VM access. Their native implementation,
context, and transaction semantics remain trusted. A handler can still write
immediately if implemented that way, and the runner cannot undo it. Checksums
detect corruption, not forgery: replay proves computation under supplied
observations, not that those observations occurred or a transaction committed.
Publication and durable delivery require the host's own protocol.
Cross-platform floating-point identity remains unproven.

[Strict workers](effects-workers.md) reuse this data and transaction interface
while keeping adapters in a separate host process. They add OS containment,
host-owned effect journals, and mandatory fresh replay before preparation
succeeds. Durable delivery remains a host responsibility.
The [durable reference host](effects-durable.md) now implements one such
protocol with atomic SQLite turns, stable retries, and a local recipient that
deduplicates deferred intents across process crashes.

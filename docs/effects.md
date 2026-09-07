# Explicit effects

The experimental `mruby.effect` interface makes selected host operations
explicit in Ruby. An operation constructor returns an inert `Effect` request;
`Effect.perform(request)` checks its grant and runs the configured handler.
The same Ruby code can use live handlers, deterministic test handlers, or an
owned transcript that supplies recorded results during replay.

For native enforcement from VM creation, use the experimental
[strict effects profile](effects-strict.md) and `mruby.strict.Program`.
The bootstrap example below describes the general embedding interface.
For explicit state, data-only handlers, terminal verification, and host
commit/discard, see [strict turns](effects-turns.md). For OS-contained execution
with native adapters retained in the host, use [strict workers](effects-workers.md).

```ruby
def self.announce(message)
  now = Effect.perform(Clock.now)
  receipt = Effect.perform(Outbox.enqueue("announcements", "#{now}: #{message}"))
  [now, receipt]
end

announce("hello from effects")
```

Only operations carry an annotation. Helpers need no effect declarations,
and `perform` returns an ordinary Ruby value synchronously. In this example,
the outbox handler takes ownership of an in-memory intent and returns its
integer receipt. It performs no network delivery or durable commit.

Run the complete [CodeDB example](../examples/effects_demo.zig):

```sh
mise x -- zig build run-effects-demo
mise x -- zig build run-effects-demo -Dno-compiler
mise x -- zig build test-effects
```

The demo checks a real clock, a fixed clock, and recording followed by replay
in a fresh isolate after the recording VM has been destroyed. Replay invokes
neither handler and creates no new outbox intents. Application Ruby is
compiled at build time, so both compiler profiles use the same source.

## Define the operation contract

An operation has a stable name and version, a Ruby constructor location, an
arity, authority metadata, and an encoded result-size limit:

```zig
const operations = .{.{
    .name = "clock.now",
    .namespace = "Clock",
    .method = "now",
    .version = @as(u32, 1),
    .arity = @as(usize, 0),
    .authority_bits = @as(u16, 1 << 4), // clock
    .max_result_bytes = @as(usize, 256),
}};
```

`install` accepts a comptime tuple or array of descriptors, including
`mruby.effect.Operation` values. The version defaults to 1 and the per-operation
result limit defaults to 4096 bytes. Names and descriptor strings must have
static lifetime. Change the version when the operation's meaning or value
contract changes.

Add an optional `.contract` for shared argument, result, and expected-rejection
shapes. [Typed operation contracts](effects-contracts.md) explains validation,
schema-bound replay identity, and the `Stock.reserve` domain example.

The demo's [shared catalogue](../examples/effects/contract.zig) is pure Zig and
is imported by both the executable and `build.zig`. Its CodeDB host bindings
derive their authority with
`CodeDB.AuthoritySet.fromBits(operation.authority_bits)`. Authority describes
what an operation can expose; the separate `allowed` list enforces permission
to perform it. Neither metadata nor a grant inspects a native handler's code.

## Install during bootstrap

Install once on the bootstrap VM, then seal and execute through `Isolate`:

```zig
var boot = try mruby.sandbox.BootstrapIsolate.spawn(
    mruby.sandbox.Policy.restricted(.{}),
);
defer boot.deinit();

try mruby.effect.install(boot.vm(), operations, .{
    .allowed = &.{"clock.now"},
    .bindings = &.{.{
        .name = "clock.now",
        .handler = fixedClock,
    }},
});
const iso = try boot.seal();
defer iso.deinit();

const result = try iso.run("Effect.perform(Clock.now)");
```

A handler receives its optional context, the owning VM, and an Array value
containing the materialized positional arguments:

```zig
fn fixedClock(
    context: ?*anyopaque,
    vm: *mruby.Vm,
    arguments: mruby.Value,
) anyerror!mruby.Value {
    _ = context;
    _ = arguments;
    return vm.intValue(@as(i64, 1_700_000_000));
}
```

`Binding.context` is a `?*anyopaque` pointer whose pointee must outlive the VM.
Installation copies the grants, bindings, and replay bytes; it does not take
ownership of the handler context. Values obey the ordinary
[VM ownership and borrowed-string rules](safe-api.md). A handler that retains
an argument must copy its bytes or otherwise establish ownership.

Grants default to empty. Constructing a request does not require a grant;
performing it does. An ungranted operation fails before its handler runs.
Live and recording modes also require a binding for each performed operation.
Replay still checks grants but needs no live bindings.

Installation closes an audited set of ambient clock, random, and output
entry points by default, including `Time.now`, `rand`, and `puts`. Sealing
reapplies these masks after policy clock/random setup. Set
`harden_ambient = false` only when deliberately retaining that ambient surface.
This option is independent of the sandbox's other capabilities. Strict builds
reject `harden_ambient = false` and add native implementation checks.

An installation failure after Ruby definitions begin leaves the VM unusable
for effects; discard it. Running `Effect.perform` directly through a raw VM
outside an admitted isolate execution fails with `EffectNotActive`.

## Requests are snapshots

The constructor captures its payload immediately using the inert
[StateCapsule value encoding](artifacts.md). Later mutation of the original
Ruby arguments does not change that request:

```ruby
message = "ready"
request = Outbox.enqueue("announcements", message)
message.replace("changed")
Effect.perform(request) # the handler receives "ready"
```

Requests expose `name`, `version`, and `arguments`. `arguments` materializes a
fresh value graph, so editing that graph also leaves the request unchanged.
Arguments and results must be supported by the StateCapsule codec and fit
their limits; arbitrary Ruby objects, closures, and native handles are not
general effect payloads. Requests belong to their creating VM.

Handler results are also delivered as detached snapshots, including in live
mode. Aliases within a result are preserved, but sharing with a handler's
retained Ruby objects is severed. This keeps result mutation consistent with
replay. Rejection code and message values follow the same rule.

Calling `perform` twice performs the request twice. There is no implicit
deduplication or exactly-once delivery. A handler cannot recursively perform
another effect: nested effect dispatch fails with `EffectReentry`. Handlers
remain trusted, bounded native code and can use ordinary host implementation
details internally.

## Record and replay

The mode is fixed for the lifetime of the installed system:

| Configuration | Behavior |
| --- | --- |
| `.mode = .live` | Check grants and execute handlers; retain no transcript. This is the default. |
| `.mode = .record` | Record each performed operation's name, version, arguments, and returned or rejected outcome. |
| `.mode = .{ .replay = encoded_trace }` | Match each request against the next record and return its recorded value or raise its recorded rejection without invoking a handler. |

After a successful recording execution, take the owned trace and encode it:

```zig
_ = try iso.runArtifact(manifest, "announce");
var trace = try iso.takeEffectTrace();
defer trace.deinit();
const encoded = try trace.encode(allocator);
defer allocator.free(encoded);
```

`takeEffectTrace` transfers ownership out of the isolate; the trace can outlive
its VM. `Trace.encode` returns a separate allocation owned by its supplied
allocator. `Trace.len`, `get`, and `isComplete` allow inspection; record slices
borrow from the trace. A second take without another recording returns
`EffectTraceUnavailable`.

Take a trace before the next admitted execution, which replaces any retained
trace even if the new guest run later fails. A code-identity rejection occurs
before that replacement. A failed outer execution or effect dispatch makes
its transcript incomplete; incomplete transcripts cannot be encoded for
replay. Completed handler actions are not rolled back when a later failure
invalidates the recording. Recording reserves transcript result capacity
before invoking the handler, but this is not a transaction protocol.

Replay requires exact operation order, versions, and encoded arguments. A
different request, an extra request, or an unconsumed record at successful
return produces `EffectReplayMismatch`. The entire transcript must match;
replay does not fall back to live handlers.

New recordings use trace format 1.1, with an explicit outcome tag. Version 1.0
traces remain readable; their records represent returned values. Decoding and
re-encoding an older trace preserves its version and framing.

## Expected rejections

An operation can report an expected application failure that Ruby handles
normally:

```ruby
def reserve(amount)
  remaining = Effect.perform(Store.reserve(amount))
  ["reserved", remaining]
rescue Effect::Rejected => failure
  ["unavailable", failure.code, failure.message]
end
```

Bind an `outcome_handler` to return either `.returned = value` or
`try mruby.effect.reject(vm, "OutOfStock", "Not enough stock")`. Its signature
is `fn (?*anyopaque, *Vm, Value) anyerror!effect.Outcome`. A binding supplies
exactly one of `handler` (the existing returned-value callback) and
`outcome_handler`. A rejection payload is an inert two-element array containing
a string code and string message; `reject` constructs it for you. It has the
same size and value-encoding limits as a returned result.

The runtime records a rejection before raising `Effect::Rejected`, whose
`code` and `message` preserve those strings. Rescuing it and completing the
outer invocation produces a complete trace. Replay raises the same rejection
at the same operation so the fallback runs again. An unrescued rejection
leaves the outer execution failed and its trace incomplete.

Return a Zig error for an indeterminate commit, a broken adapter, or another
failure that cannot safely become an application decision. Such errors still
invalidate the execution even if Ruby rescues the exception. Rejection does
not roll back prior handler actions; transaction boundaries belong to the host.

## What identifies an execution

Before recording or replay, the runtime combines three identities:

| Identity | Source |
| --- | --- |
| Code | A format-tagged digest of the actual outer source, raw bytecode image, or typed RITE bytes. |
| Catalogue | The operation descriptors and runtime compatibility fingerprint. Handler addresses are excluded. |
| Input | The host-supplied 32-byte `input_identity`. |

Source and RITE use different identity domains. Recording source and replaying
compiled RITE is rejected even if both express the same Ruby program. Changed
code, operation descriptors, runtime compatibility, or input identity produces
`EffectTraceIdentityMismatch` before guest execution.

The host must calculate `input_identity` from all external inputs and
bootstrap state that affect the computation, including preloaded Ruby helpers
and seeded globals. Its zero default does not establish that those inputs are
identical. The runtime identifies the outer entry bytes; it does not hash all
reachable Ruby heap state or discover every dependency. A fresh isolate with
the same explicit bootstrap/input contract is the simplest replay setup.

Recording and replay support outer `run`, `runImage`, `runRite`, and
`runArtifact` execution, and the identified method interface below. Ordinary
outer `call`, `callWithOptions`, and load-once CodeDB
initialization through `loadArtifact` have no complete code identity and
reject tracing with `EffectTraceRequiresCodeIdentity`; they support live
handlers. Ruby helpers called by a supported outer script work normally.

## Identified method calls

For a method in an already loaded application bundle, supply an explicit
invocation contract:

```zig
const result = try iso.callWithEffects(receiver, "reserve", .{amount}, .{
    .code = bundle_digest,
    .bootstrap = bootstrap_digest,
    .state = starting_state_digest,
    .receiver = "inventory/one",
});
```

`effect.Invocation` requires all four fields. `code` identifies the complete
application bundle, `bootstrap` identifies the host setup contract, and
`state` identifies the complete starting state observable by that turn.
`receiver` is a stable logical name, never a pointer or Ruby object address.
The host computes these identities; the runtime does not discover the code
behind a method or authenticate an arbitrary receiver's heap.

The runtime hashes the actual method name with code, bootstrap, and receiver
identity. It separately hashes the invocation's state identity, configured
`input_identity`, and a canonical capsule of the actual positional arguments.
All positional arguments are snapshotted together, preserving aliases between
them. Ruby receives the materialized snapshot, so mutations to it do not
change the caller's original argument graph. This copying behavior differs
from ordinary `call` and is part of the identified interface's contract.

Argument conversion is inert: no guest serialization hooks or coercions run.
Arguments must belong to this VM and fit the supported capsule shape and
limits. Raw `c.mrb_value`, arbitrary objects, and blocks are unsupported.
Method names must contain 1–255 bytes and no NUL; receiver names must be
nonempty, NUL-free, and bounded by `max_request_bytes` and `max_bytes`.
The same bounds apply to the combined encoded arguments.

Invalid inputs and replay identity mismatches reject before guest execution,
gas renewal, or replacement of a retained trace. Temporary conversion
allocations still count against the isolate's memory limit. This is an outer
execution interface; recursively entering it from a running guest is rejected.
Use ordinary internal Ruby calls within the admitted invocation.

## Replay diagnostics

After a failed attempt, `try iso.effectDiagnostic()` returns an optional owned
`effect.Diagnostic`. It includes a reason, a zero-based record index, bounded
expected/actual operation names, optional versions and SHA-256 hashes, and an
optional byte offset into the encoded argument capsule. That offset identifies
a serialized byte difference, not a Ruby argument position. Operation names
are available through `expectedOperation()` and `actualOperation()`.

Reasons distinguish code/catalogue/input identity differences, operation and
version differences, argument differences, invalid recorded results, an extra
performed operation, and an expected record left unconsumed. The first mismatch
sticks through Ruby rescue. The next execution validation clears the runtime's
diagnostic; a copied value remains valid after later runs or VM destruction.

## SQLite inventory example

The optional example runs build-compiled Ruby against a private in-memory
SQLite database:

```sh
mise x -- zig build run-effects-inventory -Dsqlite-effects=true
mise x -- zig build test-effects-inventory -Dsqlite-effects=true -Dno-compiler
```

It separates `DB.rows`, `DB.execute`, and `Outbox.enqueue`, keeps transaction
control in the host, and grants inspection only reads. Reservation updates are
conditional; an expected stock rejection drives a Ruby fallback. Outbox calls
append inert intents. Replay in a fresh VM reproduces Ruby results while
executing zero live database callbacks and creating no outgoing intents.

Replay does not rebuild the database writes or deliver the intents. A host
integrating consensus must attach prepared state and intents to acceptance,
then handle durable dispatch and retry policy separately. The example leaves
the consensus prototype untouched.

SQLite is an opt-in, pinned build dependency for this example. Ordinary mruby
builds do not link SQLite. The example also prints local live/record timing and
trace-size measurements; they are observations, not performance guarantees.

For disk-backed turns through contained workers, use the separate
[durable reference host](effects-durable.md). Typed reservation and notification
operations use whole-turn admission and atomic publication of inventory, Ruby
state, receipt, and outbox; stable retry identity; and process-crash tests through
recipient delivery:

```sh
mise x -- zig build run-effects-durable -Deffects-strict=true -Dsqlite-effects=true
```

## Limits and failure

`Config.limits` has these defaults:

| Limit | Default | Scope |
| --- | --- | --- |
| `max_records` | 1024 | Per-execution performed operations; also bounds outstanding request count. |
| `max_bytes` | 16 MiB | Transcript storage including reserved result capacity; separately bounds outstanding request storage. |
| `max_request_bytes` | 1 MiB | Each encoded argument graph. |
| `max_result_bytes` | 1 MiB | Each encoded result, further limited by the operation's own result limit. |

Request and transcript storage use the host allocator and are outside the
isolate's mruby heap quota. Their separate limits are not a total process
memory cap; temporary codec buffers, handler allocations, and the independently
allocated encoded transcript also need host budgeting. Live mode validates
argument and result shape and size, so swapping in a recorder preserves the
operation's value contract.

Dispatch failures such as `EffectDenied`, `EffectUnhandled`,
`EffectHandlerFailed`, and `EffectLimitExceeded` surface as distinct host
errors. Ruby receives an exception with operation context, but rescuing a
dispatch failure cannot turn that execution into a successful recording.
Sandbox termination remains authoritative and prevents new handler dispatch
during termination unwind. Native handlers retain the sandbox's existing
interruptibility limits.

The general embedding profile enforces registered operations and the audited
ambient masks. It does not infer effects, establish whole-program purity, track all
Ruby heap mutation, intercept arbitrary native gems, provide resumable
algebraic handlers, or make output durable. Replay reproduces recorded
operation results; external delivery requires its own host protocol.

The [2026-09-05 bypass audit](effects-audit.md) confirms remaining routes for
native warning output, previously captured native methods, ordinary host
callbacks, and unrecorded timezone/object-identity observations. Ambient
method masks are not a guarantee that every host interaction is mediated.
The [strict profile](effects-strict.md) addresses those native routes with a
smaller reviewed runtime. [Strict turns](effects-turns.md) additionally verify
terminal state/results. [Strict workers](effects-workers.md) add OS containment
and a separate host effect broker; native handler behavior remains trusted.

# Part 3 — The effect system: one seam between Ruby and the host

**Prerequisites**: [Part 1](01-embedding.md), [Part 2](02-codedb.md). No
example flags required.

This is the part the repository exists for. The effect system makes host
effects — clocks, storage, outbound messages, anything with authority —
**explicit at the operation site** in Ruby, and makes the host the sole
arbiter of what performing them means. There are no method-level effect
annotations; ordinary Ruby mutation stays ordinary Ruby. The guest experience
is exactly one spelling:

```ruby
now = Effect.perform(Clock.now)
receipt = Effect.perform(Outbox.enqueue("announcements", "#{now}: #{message}"))
```

Everything in this part is demonstrated by one example,
[examples/effects_demo.zig](../../examples/effects_demo.zig), whose
application lives in [examples/effects/announce.rb](../../examples/effects/announce.rb):

```sh
mise x -- zig build run-effects-demo
mise x -- zig build test-effects
```

## The shared operation catalogue

Effects start as data, not code. [examples/effects/contract.zig](../../examples/effects/contract.zig)
declares the two operations the announcement application may perform:

```zig
pub const operations = .{
    .{
        .name = "clock.now",
        .namespace = "Clock",
        .method = "now",
        .version = @as(u32, 1),
        .arity = @as(usize, 0),
        .authority_bits = @as(u16, 1 << 4), // clock
        .max_result_bytes = @as(usize, 256),
    },
    .{
        .name = "outbox.enqueue",
        .namespace = "Outbox",
        .method = "enqueue",
        // ...
    },
};
```

The catalogue is intentionally dependency-free Zig — the same file feeds the
CodeDB build (authority metadata), the runtime installer, and, in later parts,
whole-turn contracts. `namespace` + `method` are what Ruby sees: the installer
defines a frozen module `Clock` with a class method `now` that **builds an
inert request**. `authority_bits` names the kind of authority the operation
exercises, and `max_result_bytes` bounds what it may return.

Operations can also declare typed argument and result schemas, and expected
rejections; that vocabulary is specified in
[effects-contracts.md](../effects-contracts.md) and becomes central in
[Part 5](05-turns.md).

## Install during bootstrap

The host side of the demo (abbreviated from `effects_demo.zig`) installs the
system between sandbox bootstrap and seal:

```zig
var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{
    .limits = .{ .gas = .{ .per_execution = 100_000 }, .call_depth = 32 },
}));
defer boot.deinit();
const bindings = [_]mruby.effect.Binding{
    .{ .name = "clock.now", .handler = Host.now, .context = host },
    .{ .name = "outbox.enqueue", .handler = Host.enqueue, .context = host },
};
var input_identity: [32]u8 = undefined;
std.crypto.hash.sha2.Sha256.hash(contract.message, &input_identity, .{});
try mruby.effect.install(boot.vm(), contract.operations, .{
    .allowed = &.{ "clock.now", "outbox.enqueue" },
    .bindings = &bindings,
    .mode = mode,
    .input_identity = input_identity,
});
const iso = try boot.seal();
```

Four decisions are visible in that call:

- **Registration is not permission.** `bindings` says *how* to satisfy an
  operation; `.allowed` says *whether the guest may perform it*. In this demo
  both list the same two names, but splitting them is the design: a test host
  registers handlers and grants nothing; a production host grants a subset.
  Performing an ungranted operation fails closed.
- **`Effect` is exclusive.** If a class named `Effect` already exists,
  installation fails with `EffectNamespaceConflict` rather than merging. After
  installation the class is frozen, `new`/`allocate`/`dup`/`clone` are
  masked, and the namespace modules (`Clock`, `Outbox`) are frozen too —
  guests cannot forge requests or monkey-patch the seam.
- **`input_identity`** feeds the execution identity (see
  [Part 4](04-record-replay.md)).
- **`.mode`** selects live, record, or replay — the subject of the next part.

## Requests are inert snapshots

`Clock.now` in Ruby does not read a clock. It constructs a request object — a
detached snapshot of the operation name, version, and arguments in the
[inert StateCapsule encoding](../artifacts.md):

```ruby
message = "ready"
request = Outbox.enqueue("announcements", message)
message.replace("changed")
Effect.perform(request) # the handler receives "ready"
```

Mutation after construction cannot alter what the host will admit. The
request exposes `name`, `version`, and `arguments` readers, and `arguments`
materializes a *fresh* value graph, so even inspect-and-edit leaves the
request unchanged. This is the property that later lets durable hosts
fingerprint requests and sleep soundly.

Handler results come back the same way — detached snapshots, even in live
mode, with aliases within a result preserved but sharing with the handler's
retained Ruby objects severed. Result mutation therefore behaves identically
under live execution and replay.

Two hard rules from the reference doc ([effects.md](../effects.md)) worth
memorizing now:

- `perform` twice performs twice. There is no implicit deduplication or
  exactly-once anything at this layer.
- Handlers cannot recursively perform effects; nested dispatch fails with
  `EffectReentry`.

## What a handler looks like

The demo's host implements both operations as ordinary Zig functions:

```zig
fn now(context: ?*anyopaque, vm: *mruby.Vm, args: mruby.Value) !mruby.Value {
    const host: *Host = @ptrCast(@alignCast(context.?));
    host.clock_calls += 1;
    return vm.intValue(host.fixed_now orelse std.Io.Clock.real.now(host.io).toSeconds());
}
```

and an `enqueue` that validates bounds (destination ≤ 256 bytes, payload ≤
4096, at most 16 intents), **copies the borrowed Ruby bytes before making
another interpreter call**, appends an owned intent, and returns a receipt
integer. That copy rule is the safe-API ownership discipline from
[Part 1](01-embedding.md) applied at the seam.

Handlers are trusted, bounded native code. A Zig `error` from a handler is a
*failure* — it invalidates the execution — which is the right tool for a
broken adapter, but the wrong tool for expected business outcomes. Those are
**declared rejections**, and they are typed data: a binding supplies either
`handler` or an `outcome_handler`, and the outcome handler returns either
`.returned = value` or:

```zig
try mruby.effect.reject(vm, "OutOfStock", "Not enough stock")
```

Ruby rescues them as `Effect::Rejected` with `.code` and `.message` preserved:

```ruby
rescue Effect::Rejected => failure
  ["unavailable", failure.code, failure.message]
end
```

Rescuing and completing normally is a *successful* execution. This
failure-versus-rejection distinction runs through the entire stack — in
[Part 7](07-durable.md) an `OutOfStock` rejection advances state and commits,
while a worker-adapter failure poisons the turn with `EffectHandlerFailed`
and the cause in the diagnostic's `messageText()`.

## Run it and read what happened

`run-effects-demo` executes the announcement four times and asserts as it
goes: once live (real clock), once with a host-fixed clock, once recording,
and once replaying the recording — the last two are [Part 4](04-record-replay.md).
The live runs print:

```
effects: live -> [<timestamp>, 1], fixed -> [1700000000, 1]
```

with exactly one clock call, one enqueue, one owned intent whose payload is
`"<timestamp>: hello from effects"` — the string assembled *in Ruby* from
snapshot values, then validated and owned *by the host*.

## What this layer does not establish

The audit of what can still bypass the seam lives in
[effects-audit.md](../effects-audit.md); the honest list includes ambient
nondeterminism the guest can reach without an operation (time before
harnesses exist, hash ordering, and so on — `harden_ambient` closes known
gaps), and the fact that handlers themselves are trusted code. Time and
randomness mediated *through* operations are recorded and replayable; effects
are per-VM and single-threaded like everything else in the interpreter.

Also: this demo runs in-process. There is no OS isolation, no fresh-VM-per-
execution discipline, and no transaction binding effects to a commit decision.
Those are exactly [Part 5](05-turns.md) and [Part 6](06-workers.md).

Continue with [Part 4 — Recording and replay](04-record-replay.md).

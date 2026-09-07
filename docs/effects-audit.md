# Effects bypass audit — 2026-09-05

The current runtime mediates registered operations and masks selected Ruby
method names. It does not guarantee that all host interactions pass through
`Effect.perform`. The following are confirmed against the pinned mruby 4.0.0
standard build with `Policy.restricted`, default ambient hardening, recording
enabled, and no effect grants. This was an investigation; no runtime fixes
were applied in this audit. The later [strict profile](effects-strict.md)
implements native dispatch and primitive checks, excludes Time/Random/Struct,
and uses guarded application initialization. The findings below continue to
describe the ordinary compatibility profile. [Strict turns](effects-turns.md)
now compare explicit terminal results/state; arbitrary native-handler behavior
remains trusted. [Strict workers](effects-workers.md) now keep those handlers
outside the Ruby process and add OS containment plus host journal checks.

## Native warnings write to stderr

This needs no privileged bootstrap or additional host callback:

```ruby
k = Class.new(Struct)
k.new("Group", :a)
k.new("Group", :b)
123
```

It returns `123` and prints `warning: redefining constant Struct::Group` to
host stderr. The trace is complete with zero records. A mutable anonymous
subclass avoids mutating the frozen core Struct class. The native implementation
calls `mrb_warn`, which writes using libc rather than any masked Ruby print
method. Replaying the same code can print again without the effect dispatcher
ever observing that output.

Pinned upstream evidence: `mrbgems/mruby-struct/src/struct.c:199–201` and
`src/error.c:509–519`. Current masks are in [effect.zig](../src/effect.zig).

## Native methods captured before installation remain callable

Before installation:

```ruby
$clock = Time.method(:now)
$printer = Kernel.method(:print)
$random = Random.new.method(:rand).to_proc
class << Time
  alias unannotated_now now
end
```

After installation and restricted sealing, `$clock.call`, `$printer.call(...)`,
`$random.call(100)`, and `Time.unannotated_now` remain native calls. A copied
`Time` class made before installation also retains its methods. Captured
clock/print and alias/random calls succeeded with complete, empty traces.

Masking the original method name does not revoke a stored Method, Proc, alias,
or copied method table. Obtaining a new Method after sealing was blocked in
the negative controls. A plain lambda containing `Time.now` does not preserve
the original method: that name is resolved when the lambda runs.

In the audited compatibility profile, the inventory example loads application IREP before installing
effects ([host bootstrap](../examples/effects_inventory.zig)). Its shipped
Ruby contains no such captures, but application code placed in that prelude
could create them or perform native operations immediately. The announce
example installs and seals before executing its application artifact. The
strict inventory path now uses `strict.Program`, which installs Effects and
native enforcement before application initialization.

## Other native host bindings remain callable

A host-defined ordinary method such as `Legacy.bump` is unaffected by an
empty effect grant list. An audit callback incremented a native host counter;
Ruby invoked it successfully with a complete trace containing zero records.
Both restricted and trusted policy permit this when the host registers it.

The registration interfaces in [class.zig](../src/class.zig) do not require
ordinary native callbacks to declare or use Effects. The same responsibility
applies to native objects and custom gems exposed by an embedding host.

## Host timezone and allocation identity remain observable

These are unrecorded observations rather than external writes:

```ruby
Time.at(0).zone
Time.local(1970, 1, 1).to_i
Time.gm(1970, 1, 1).getlocal.zone
Object.new.object_id
Object.new.inspect
```

Time conversion calls libc `localtime_r`/`mktime`, so process timezone state
changes its answers. Running the same audit binary under `TZ=UTC` and
`TZ=America/Anchorage` produced different answers with zero effect records.
Object identity and default formatting expose VM allocation identity.

More directly, an audit recorded `Object.new.object_id`, then replayed the
same source and identities in a second live VM. Replay returned success, but
the integer differed. The effect transcript verifies operation observations;
it does not compare the overall Ruby return value or make unmediated guest
computation deterministic. Host-supplied bootstrap/state identities do not
stabilize future native object addresses.

## Intentional Ruby mutation and absent APIs

Array/hash mutation, instance-variable assignment, globals, and ordinary Ruby
exceptions remain unannotated by the agreed design. Consequently, “zero effect
records” has never meant a mathematically pure program or an unchanged VM.

The supported standard/minimal catalogue excludes general IO, filesystem,
socket, process, and environment gems; `File.write` and socket APIs are not
available default bypass examples. `Time.now`, `Random.rand`, and direct
print calls were blocked after sealing. `_print`, `__printstr__`, `warn`,
`STDOUT`, and `Random::DEFAULT` were absent in the tested standard profile.
`Time.at(0).dup`/`clone` copy existing state rather than read the current clock.

## Recommended next implementation slice

1. Install effect restrictions before executing any application bootstrap code.
2. Mediate sensitive native primitives at their implementation entry, so
   aliases and stored callables encounter the same checks. Route native
   warnings through an explicit host diagnostics policy as part of this work.
3. Add a strict embedding profile with an audited native registration surface;
   reject or deliberately authorize bindings outside that profile.
4. Define deterministic timezone and object-identity behavior for replay.
   Return-value comparison could detect some divergence, but would not prevent
   unrecorded writes and is not a substitute for mediation.
5. Turn these reproductions into enforcement regressions when fixes land.

Validation used temporary integration tests and an isolated native harness.
The scratch test imports were removed after the audit. These findings do not
constitute an exhaustive audit of every pinned native implementation.

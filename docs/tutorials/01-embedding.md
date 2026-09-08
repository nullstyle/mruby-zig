# Part 1 — Embedding mruby from Zig

**Prerequisites**: [Part 0](00-orientation.md); `mise x -- zig build test`
passing. No example flags required.

This part walks the four embedding examples: running Ruby and reading results
(`quickstart.zig`), calling Zig from Ruby (`host_functions.zig`), sandboxed
execution with policies and budgets (`sandbox.zig`), and exceptions in both
directions (`exceptions.zig`). None of this involves the effect system yet —
but the ownership rules you learn here are exactly the ones the effect system
is built on.

## 1. Evaluate Ruby, read a result

The whole first example ([examples/quickstart.zig](../../examples/quickstart.zig)):

```zig
const std = @import("std");
const mruby = @import("mruby");

pub fn main() !void {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    const result = try vm.loadString("[1, 2, 3, 4].map { |x| x * x }.reduce(:+)");
    std.debug.print("sum of squares: {d}\n", .{try result.asInt()});
}
```

Run it:

```sh
mise x -- zig build run-quickstart
```

Three things matter even at this size. First, `mruby.Vm.init()` creates an
interpreter with its own heap and symbol table; `deinit` destroys it, and the
safe layer is organized around the rule that values belong to their VM and
borrowed pointers expire at defined boundaries ([safe-api.md](../safe-api.md)).
Second, `loadString` returns a `mruby.Value` — a typed handle, not a raw
pointer. Third, conversion is explicit and fallible: `asInt()` returns an
error union and refuses to lie about the value's type.

There is also a REPL step if you want to poke interactively:

```sh
mise x -- zig build run-repl
```

## 2. Call Zig from Ruby

[examples/host_functions.zig](../../examples/host_functions.zig) defines a Zig
struct, wraps it as a Ruby object, and exposes methods on it:

```sh
mise x -- zig build run-host_functions
```

```zig
const Mixer = struct {
    volume: f64 = 1.0,
    slots: [8]i16 = @splat(0),
    // ...
};

const MixerData = mruby.data.DataType(Mixer, "Audio::Mixer", struct {
    fn destroy(p: *Mixer) void {
        mruby.alloc.gpa.destroy(p);
    }
}.destroy);
```

`mruby.data.DataType` wires a Zig type into mruby's wrap/unwrap machinery,
including its destructor. The methods themselves are plain Zig functions with
typed signatures the shim converts for you:

```zig
fn setVolume(m: *mruby.Vm, self: mruby.Value, v: f64) anyerror!mruby.Value {
    const p = MixerData.unwrap(self) orelse return m.raise("TypeError", "expected a Mixer");
    if (v < 0 or v > 1) return m.raise("ArgumentError", "volume must be in 0..1");
    p.volume = v;
    return m.floatValue(v);
}
```

Read the whole file for the remaining patterns it demonstrates:

- **Class methods and instance methods**: `defineClassMethod` vs
  `defineMethod`; `new` is implemented as a class method whose `self` is the
  class, so no process-global class storage is needed — the file is safe with
  any number of VMs.
- **Variadic arguments**: `mruby.Rest` (`mix` sums any number of samples).
- **Blocks**: `mruby.Block` — `each_slot` invokes the block with
  `m.call(blk.value, "call", .{...})` and raises `ArgumentError` when absent.
- **Argument validation lives in Zig**: bounds-check every typed argument
  before touching wrapped state; `unwrap` returning null is always handled.

A note on allocation: wrapped objects are allocated through the mruby
allocator (`mruby.alloc.gpa.create`), so the interpreter's GC and your
`destroy` callback own their lifetime together. Do not free wrapped pointers
yourself.

## 3. Sandbox: policy, seal, budgets

[examples/sandbox.zig](../../examples/sandbox.zig) is the sandbox tier in one
page:

```sh
mise x -- zig build run-sandbox
```

```zig
var boot = try mruby.sandbox.BootstrapIsolate.spawn(
    mruby.sandbox.Policy.restricted(.{
        .limits = .{
            .gas = .{ .per_execution = 200_000 },
            .call_depth = 64,
        },
    }),
);
defer boot.deinit();

const budget = try boot.vm().defineClass("Budget", null);
try budget.defineMethod("spend", /* ... */);
const iso = try boot.seal();
defer iso.deinit();
```

The two-phase shape is the point. During **bootstrap** you hold a raw VM and
define the host surface (classes, methods, constants). When you `seal()`, the
policy takes effect: the restricted preset masks `eval`, `send`, introspection
and `ObjectSpace`, and freezes the object model. After sealing you execute
through `iso.run(...)`, observing results only through the locked surface.

The example then demonstrates the properties you will rely on later:

- **Capability stripping**: `eval('1 + 1')` raises; the error is classified
  (`error.RubyException`) and cleared explicitly.
- **Gas is renewable per execution**: the infinite `loop` exhausts its 200k
  instruction budget and unwinds — `ensure` blocks still run, so `$ticks`
  ends at `-1` — and the *next* `iso.run` gets a fresh allowance while VM
  state survives.
- **Observation**: `iso.stats()` reports the gas generation and lifetime
  instruction count.

The full threat model — what the sandbox does and does not defend against —
is [sandboxing.md](../sandboxing.md). The short version: this is interpreter
containment, not an OS boundary; that arrives in [Part 6](06-workers.md).

## 4. Exceptions in both directions

[examples/exceptions.zig](../../examples/exceptions.zig) closes the embedding
basics:

```sh
mise x -- zig build run-exceptions
```

- **Zig raises, Ruby rescues**: `divide` returns `m.raise("ZeroDivisionError",
  "divided by 0 in zig")` when `b == 0`; Ruby's `rescue` sees an ordinary
  exception.
- **Ruby raises, Zig catches**: a failed `loadString` leaves the exception
  available as `vm.lastError().?`, with `className` and `message` accessors.
- **Zig errors inside a callback surface as `RuntimeError`** on the Ruby side —
  divide by a string and Ruby rescues a `TypeError`.
- **Output is redirectable**: the example captures `puts` output through
  `mruby.output.setOutputWriter` into a buffer instead of stdout.

One naming preview that will matter in [Part 3](03-effects.md): here, errors
crossing the boundary are *failures* — abnormal, untyped, control-flow.
The effect system later adds a second, very different category — *declared
rejections* — which are typed, expected business outcomes, not failures.

## What you can now build

A Zig application that evaluates Ruby, exposes a typed Zig host surface to it,
runs untrusted-ish code under a sealed policy with instruction budgets, and
classifies exceptions crossing either direction.

## Limits at this layer

- The sandbox constrains the interpreter: it is not an operating-system
  boundary, and native code you register is trusted by definition
  ([sandboxing.md](../sandboxing.md)).
- Values and wrapped pointers are per-VM; sharing across threads has explicit
  serialization boundaries instead of shared mutables
  ([safe-api.md](../safe-api.md)).
- Nothing yet stops Ruby from calling *host functions with effects* in ways the
  host cannot mediate — that is the problem the effect system solves.

Continue with [Part 2 — Compiling Ruby at build time](02-codedb.md).

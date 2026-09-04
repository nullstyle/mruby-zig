# Safe API: ownership, lifetimes, and threading

The supported Zig layer is explicit about failure and interpreter
ownership:

- Any operation that can allocate or raise returns an error union. A Ruby
  exception is always `error.RubyException`; inspect `vm.lastError()` before
  starting the next VM operation, which supersedes the pending diagnostic.
- `Value` and `Class` handles belong to the `Vm` that created them. APIs that
  combine handles reject cross-VM use with `error.ForeignValue` instead of
  passing a foreign heap pointer into mruby.
- The exported `mruby.c` module is an intentionally unsafe escape hatch.
  Supported safe-layer calls keep mruby's `setjmp`/`longjmp` entirely inside
  the C shim, so Ruby exceptions never unwind across live Zig frames.

## Evaluating Ruby

```zig
const v = try vm.loadString("'hello'.upcase");
try std.testing.expectEqualStrings("HELLO", try v.asString());

const named = try vm.loadStringWithOptions("__FILE__", .{
    .source_name = "jobs/worker.rb",
});
```

Ruby exceptions (compile-time or runtime) surface as `error.RubyException`
and never longjmp through Zig frames — the C shim runs each operation under
`mrb_protect_error`:

```zig
if (vm.loadString("raise 'boom'")) |_| {
    unreachable;
} else |err| {
    std.debug.assert(err == error.RubyException);
    var details = try vm.lastError().?.details(allocator, .{
        .max_backtrace_frames = 32,
    });
    defer details.deinit();
    // details.class_name == "RuntimeError"
    // details.message == "boom"
}
```

`RubyError.details` owns its class name, message, and bounded backtrace.
`RubyError.className` and `message` are also available when only one field is
needed; each takes the allocator that will own its returned bytes.

## Calling Zig from Ruby

`defineMethod` derives the Ruby-facing argument protocol from the Zig
callback's parameter types, so marshalling and arity can never disagree.
The callback starts with `(vm: *Vm, self: Value, ...)`; each further
parameter is one Ruby argument:

| Zig type         | Ruby argument      | Zig type          | Ruby argument |
|------------------|--------------------|-------------------|---------------|
| `i64`            | Integer            | `[]const u8`      | String (borrowed) |
| `f64`            | Float              | `[:0]const u8`    | String (borrowed) |
| `bool`           | Boolean            | `Rest`            | splat (`*`) |
| `u32`            | Symbol id          | `Block`           | block (`&`) |
| `Value`          | any object         | `?T` (any above)  | optional argument |

```zig
const math = try vm.defineClass("ZigMath", null);
try math.defineMethod("add", struct {
    fn call(vm: *mruby.Vm, self: mruby.Value, a: i64, b: i64) anyerror!mruby.Value {
        _ = self;
        return vm.intValue(a + b);
    }
}.call);

_ = try vm.loadString("ZigMath.new.add(20, 22)");  // => 42
```

Optional parameters are Zig optionals: `?i64` maps to the `mrb_get_args`
optional section and receives `null` when the caller omits it, so absence
is distinguishable from a passed default. Optional parameters must follow
the required ones; `Rest` and `Block` come last:

```zig
try math.defineMethod("scale", struct {
    fn call(vm: *mruby.Vm, self: mruby.Value, v: i64, factor: ?i64) anyerror!mruby.Value {
        _ = self;
        return vm.intValue(v * (factor orelse 1));
    }
}.call);
```

`defineMethodRaw` (plus `defineClassMethodRaw` / `defineModuleFunctionRaw`)
takes an explicit `mrb_get_args` format string for protocols the derived
form does not model — for example the `S` (String value) spec, or optional
arguments that should default to zero values instead of `null`:

| spec | Zig type      | spec | Zig type       |
|------|---------------|------|----------------|
| `i`  | `i64`         | `o`  | `Value`        |
| `f`  | `f64`         | `z`  | `[:0]const u8` |
| `b`  | `bool`        | `S`/`s` | `[]const u8` |
| `n`  | `u32` (sym)   | `&`  | `Value` (block) |
| `*`  | `Rest`        | `\|` | optional separator |

A Zig `error` returned from a callback becomes a Ruby `RuntimeError`
(`"zig error: Kaboom"`); `vm.raise("ArgumentError", "msg")` raises a specific
class from within a callback.

In a `defineClassMethod` callback, `self` is the class object itself;
`mruby.Class.fromValue(self)` is the supported way to reach the defining
class without process-global storage.

## Wrapping Zig state in Ruby objects

```zig
const Conn = mruby.data.DataType(ConnState, "Conn", ConnState.destroy);
const cls = try vm.defineClass("Conn", null);
const obj = try Conn.wrap(cls, state_ptr); // Ruby value
const p   = Conn.unwrap(some_value).?;     // *ConnState
```

If `destroy` is non-null it runs when the GC collects the wrapper. `wrap`
transfers ownership of the pointer only when it succeeds.

## Calling Ruby from Zig

```zig
const s = try vm.stringValue("hello");
const up = try vm.call(s, "upcase", .{});
const sqrt = try vm.call(try vm.loadString("Math"), "sqrt", .{@as(f64, 144.0)});

const items = try vm.loadString("[1, 2, 3]");
const double = try vm.loadString("->(x) { x * 2 }");
_ = try vm.callWithOptions(items, "each", .{}, .{ .block = double });
```

The positional argument tuple has no fixed eight-argument cap.
`callWithOptions` additionally accepts an optional Ruby block and enforces the
same VM ownership rule for that block.

## Typed collections and conversions

```zig
const one = try vm.intValue(1);
const array = try vm.array(&.{one});
try array.append(try vm.intValue(2));

const key = try vm.stringValue("answer");
const hash = try vm.hash(&.{
    .{ .key = key, .value = try vm.intValue(42) },
});
const answer: ?mruby.Value = try hash.get(key);
```

`Array` supports checked indexing, extension by assignment, and append.
`Hash.get` bypasses Hash defaults: it returns `null` for a missing key and a
non-null nil `Value` for a present Ruby `nil`. Hashes also support assignment
and typed `keys`. Both handles convert through `mruby.convert` and retain their
underlying `Value`'s arena lifetime and VM ownership.

Integer conversion is exact: values outside mruby's signed 64-bit range return
`error.Overflow`; use `Vm.saturatingIntValue` only when clamping is intended.
Finite Float conversions that exceed the destination format also return
`error.Overflow`.
Converting Ruby to Zig `bool` accepts only the actual Ruby `true` and `false`
values rather than applying Ruby truthiness.

## Output redirection

```zig
try mruby.output.setOutputWriter(vm, &some_writer.interface);
_ = try vm.loadString("puts 'hello from ruby'");     // -> some_writer
```

`print`, `puts`, and `p` are installed on `Kernel` and write (flushed) to
any `std.Io.Writer`.

## Value lifetimes

Two lifetime rules keep you safe:

- Values returned by `loadString`/`call` stay GC-rooted in the arena, so
  they are safe to hold across further Ruby execution. Each returned value
  occupies one arena slot, so bracket a tight loop of calls with
  `vm.arenaScope()` to keep the arena from growing. To keep selected values
  after restoring a scope, promote them to explicit long-lived roots:

  ```zig
  const scope = vm.arenaScope();
  const temporary = try vm.loadString("Object.new");
  var held = try vm.root(temporary);
  scope.restore();
  defer held.deinit(); // every RootedValue must be released before its Vm

  _ = try vm.call(held.get(), "inspect", .{});
  ```

  Multiple roots for the same Ruby object have independent lifetimes.
- String slices are **borrowed**: `Value.asString`, the `S`/`s`/`z` method
  parameters, and `Rest.get` point into the Ruby heap and are valid only
  until the next interpreter call — use `Value.dupeString(allocator)` to
  keep them. `vm.loadString` rejects source containing an interior NUL byte
  rather than silently evaluating only the prefix visible to the lexer.

## Threading

One `Vm` (or `Isolate`) is owned by one thread at a time; mruby states are
not thread-safe. Separate VMs may run on separate threads — the process
allocator is thread-safe. The sandbox layer additionally serializes its
public operations with a non-blocking lock: accidental same-Isolate
concurrency is reported as `error.IsolateThreadBusy` rather than corrupting
state (see [sandboxing.md](sandboxing.md)).

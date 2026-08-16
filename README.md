# mruby-zig

Embed [mruby](https://mruby.org) 4.0 in Zig applications — first-class,
production-grade, and built entirely with `zig`. One `zig build` fetches the
mruby 4.0.0 source (hash-pinned), generates its presym tables and core
bytecode, compiles everything with `zig cc`, and hands you a `mruby` module.
**No Ruby, no rake, no submodules, no system dependencies.**

```
 ┌──────────┐   presym scan (zig cc -E)     ┌─────────────────────┐
 │ mruby    │ ────────────────────────────► │ id.h / table.h      │
 │ 4.0.0    │                               └─────────────────────┘
 │ (zon dep)│   host mrbc (zig cc)          ┌─────────────────────┐
 │          │ ────────────────────────────► │ mrblib.c, gem_init  │
 └──────────┘                               └─────────┬───────────┘
                                                      ▼
                                      mruby module (C + Zig + shim)
```

## Status

Pre-release, tracking **Zig master** via [mise](https://mise.jdx.dev)
(`.mise.toml`; `mise install`, `mise x -- zig build test`). Developed and
tested on aarch64-macos; linux targets should work out of the box.

## Quickstart

```sh
mise install                 # or use your own zig master build
mise x -- zig build test     # unit + Ruby integration suites
mise x -- zig build run-quickstart
```

In your application:

```zig
const mruby = @import("mruby");

var vm = try mruby.Vm.init();
defer vm.deinit();

const result = try vm.loadString("[1, 2, 3].map { |x| x * x }.sum");
std.debug.print("{d}\n", .{try result.asInt()});
```

Depending on this package (once published):

```
zig fetch --save=mruby https://github.com/nullstyle/mruby-zig/archive/refs/tags/v0.1.0.tar.gz
```

```zig
// build.zig
const dep = b.dependency("mruby", .{});
exe.root_module.addImport("mruby", dep.module("mruby"));
```

The entire C library is compiled into the module — consumers link nothing
else and need no Ruby toolchain at build time.

## API tour

### Evaluating Ruby

```zig
const v = try vm.loadString("'hello'.upcase");
try std.testing.expectEqualStrings("HELLO", try v.asString());
```

Ruby exceptions (compile-time or runtime) surface as `error.RubyException`
and never longjmp through Zig frames — everything runs under
`mrb_protect_error`:

```zig
const v = vm.loadString("raise 'boom'") catch {
    const exc = vm.lastError().?;
    defer mruby.alloc.gpa.free(exc.className());
    defer mruby.alloc.gpa.free(exc.message());
    // "RuntimeError: boom"
};
```

### Calling Zig from Ruby

`defineMethod` bridges a Zig function into a Ruby method with typed
arguments. The format string follows mruby's `mrb_get_args`:

| spec | Zig type      | spec | Zig type       |
|------|---------------|------|----------------|
| `i`  | `i64`         | `o`  | `Value`        |
| `f`  | `f64`         | `z`  | `[:0]const u8` |
| `b`  | `bool`        | `S`/`s` | `[]const u8` |
| `n`  | `u32` (sym)   | `&`  | `Value` (block) |
| `*`  | `Rest`        | `\|` | optional separator |

```zig
const math = try vm.defineClass("ZigMath", null);
math.defineMethod("add", "ii", struct {
    fn call(vm: *mruby.Vm, self: mruby.Value, a: i64, b: i64) anyerror!mruby.Value {
        _ = self;
        return vm.intValue(a + b);
    }
}.call);

_ = try vm.loadString("ZigMath.new.add(20, 22)");  // => 42
```

A Zig `error` returned from a callback becomes a Ruby `RuntimeError`
(`"zig error: Kaboom"`); `vm.raise("ArgumentError", "msg")` raises a specific
class from within a callback.

### Wrapping Zig state in Ruby objects

```zig
const Conn = mruby.data.DataType(ConnState, "Conn", ConnState.destroy);
const cls = try vm.defineClass("Conn", null);
const obj = Conn.wrap(vm.mrb, cls.class, state_ptr);   // Ruby value
const p   = Conn.unwrap(vm.mrb, some_value).?;          // *ConnState
```

If `destroy` is non-null it runs when the GC collects the wrapper.

### Calling Ruby from Zig

```zig
const s = vm.stringValue("hello");
const up = try vm.call(s, "upcase", .{});            // up to 8 args
const sqrt = try vm.call(try vm.loadString("Math"), "sqrt", .{@as(f64, 144.0)});
```

### Output redirection

```zig
mruby.output.setOutputWriter(vm, &some_writer.interface);
_ = try vm.loadString("puts 'hello from ruby'");     // -> some_writer
```

`print`, `puts`, and `p` are installed on `Kernel` and write (flushed) to
any `std.Io.Writer`.

### Memory

All mruby allocations flow through `mruby.alloc`, a Zig-side
`mrb_basic_alloc_func` override: `mruby.alloc.setAllocator(gpa)` (before
the first `Vm`), `mruby.alloc.liveBytes()` / `liveAllocs()` for
observability. It is process-global — an upstream 4.0 constraint — and
defaults to the thread-safe `std.heap.c_allocator`.

Two lifetime rules keep you safe:

- Values returned by `loadString` are not GC-rooted once the call returns;
  root anything you keep across further Ruby execution (a global/ivar, or
  a `vm.arenaScope()` around a tight loop of calls).
- String slices are **borrowed**: `Value.asString`, the `S`/`s`/`z` method
  parameters, and `Rest.get` point into the Ruby heap and are valid only
  until the next interpreter call — use `Value.dupeString(allocator)` to
  keep them. `vm.loadString` evaluates a source slice only up to its first
  NUL byte (the lexer's sentinel).

## Gem configuration

The default **standard** gem set (28 gems) covers metaprogramming
(`mruby-metaprog`, `mruby-method`, `mruby-eval`, `mruby-binding`), the
stdlib extension gems (`string/array/hash/enum/range/numeric/class/object/
symbol/proc/kernel/toplevel/compar`), `struct`, `set`, `fiber`,
`enumerator` + `lazy`, `sprintf`, `pack`, `random`, `time`, `data`,
`objectspace`, and `math`.

```sh
mise x -- zig build -Dgem-set=minimal          # core + compiler + eval (+ deps)
mise x -- zig build -Dwith-gems=mruby-io       # add gems on top
mise x -- zig build -Dwithout-gems=mruby-pack  # remove gems
```

Gem dependencies are honored like Rake's `add_dependency`: `-Dwith-gems`
pulls in anything the added gem needs, and `-Dwithout-gems` cascade-removes
gems that depend on what you removed (printed as configure-time notes), so
misconfigurations can't silently produce an interpreter that fails to boot.

Excluded from defaults for portability: `io`, `socket`, `dir`, `errno`,
`print`, and the math-extras (`bigint`, `complex`, `rational`, `cmath`).
Note that without `mruby-bigint`, integer *literals* beyond the int32 pool
range raise `RangeError` at load time (upstream 4.0 behavior); computed
values up to ±2^63 work fine.

## Sandboxing and limits

The default gem set is deliberately **compute-only**: no `io`, `socket`,
`dir`, `errno`, or process gems, so scripts cannot touch the filesystem,
network, or spawn processes unless the host adds those gems or exposes
such capability through Zig methods. What the host must still manage:

- **CPU**: an infinite loop in a script cannot be interrupted; run
  untrusted scripts on a worker thread with your own timeout/kill policy.
- **Memory**: allocations are observable via `mruby.alloc.liveBytes()` /
  `liveAllocs()`; enforcing a quota (failing `mrb_basic_alloc_func` past a
  limit) is a natural extension.
- Deep recursion is safely caught (mruby raises `SystemStackError`, which
  surfaces as `error.RubyException` like any other exception).

## Layout

```
build.zig            # the entire mruby build, in zig
build/{sources,gems,gen}.zig
tools/presym_gen.zig # port of mruby's lib/mruby/presym.rb
tools/file_join.zig  # generated-C assembler helper
src/c.zig            # hand-written extern bindings (public for power users)
src/shim.c           # C-side accessors for macro-only inline APIs
src/vm.zig           # Vm: eval, call, classes, globals, raise, arena
src/{value,class,data,convert,error,output,arena,alloc}.zig
src/tests_ruby/*.rb  # Ruby-level integration suite (embedded, asserted in zig)
examples/            # quickstart, host_functions, exceptions
tools/repl.zig       # `zig build run-repl -- -e 'expr'` eval tool
```

## How it works

mruby's build normally requires Ruby (rake) to generate four things. This
package generates all of them in `build.zig`, mirroring the rake tasks:

1. **presym tables** — preprocess every C source with
   `-DMRB_PRESYM_SCANNING` (which turns `MRB_SYM(x)` into `<@! "x" !@>`
   markers), collect and sort symbols by (length, bytes), emit
   `mruby/presym/{id.h,table.h}` — a port of `lib/mruby/presym.rb`
   (`tools/presym_gen.zig`).
2. **host `mrbc`** — mruby's own bootstrap trick: the `mrbc` tool ships
   empty `mrb_init_mrblib`/`mrb_init_mrbgems` stubs, so it links without
   any generated files. We build it for the host with `zig cc` (with its
   own presym tables, like rake's nested build).
3. **bytecode** — run that `mrbc` over `mrblib/*.rb` and each gem's
   `mrblib/*.rb` (`-B<sym> -S -s`, cdump format), assembling `mrblib.c`
   and per-gem `gem_init.c` from the exact rake templates.
4. **gem registry** — a generated `gem_init.c` table driving
   `mrb_init_mrbgems`.

Ruby-level symbols reach the presym tables because the final scan covers
the *generated* files (the cdump output references symbols through
`MRB_SYM(...)` macros, exactly like the rake build).

The Zig side never hand-decodes mruby struct layouts: `src/shim.c` compiles
inside libmruby and re-exposes the macro-only inline API (GC arena,
`mrb->exc`, integer/string accessors, value constructors) as plain
functions, keeping every layout decision on the C side.

## Development

```sh
mise x -- zig build test              # 26 tests incl. Ruby suites
mise x -- zig build run-host-functions
mise x -- zig build run-repl -- -e 'RUBY_VERSION'
```

## License

MIT — see [LICENSE](LICENSE). mruby is MIT and fetched at build time as a
pinned, hash-verified dependency.

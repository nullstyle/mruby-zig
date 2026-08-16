# mruby-zig: production-grade mruby embedding for Zig

Design + implementation of a from-scratch Zig package (repo `mruby-zig/`, currently empty) that embeds **mruby 4.0.0** into Zig applications with **no Ruby toolchain required at build time** — the entire mruby build (normally Rake-driven) is replicated in `build.zig` and executed by `zig cc`.

## Locked-in decisions

- **Zig**: master (0.17.0-dev), tracked with **mise** (`.mise.toml`); pin an exact dev snapshot for reproducibility, `mise up` to move forward. CI uses the same pinned snapshot.
- **mruby**: **4.0.0** tarball fetched as a `build.zig.zon` dependency (`zig fetch --save`, GitHub release archive). No git submodule, no vendored copy, no rake.
- **Default gems**: "Standard" set — core + `mruby-compiler` + metaprog (`mruby-metaprog`, `mruby-method`, `mruby-eval`) + stdlib-ext gems (`string/array/hash/enum/range/numeric/class/object/symbol/proc/kernel/toplevel/compar-ext`, `mruby-sprintf`, `mruby-struct`, `mruby-data`, `mruby-random`, `mruby-time`, `mruby-pack`). Configurable via build options; io/socket/dir/errno/print excluded from defaults (portability).
- **Bindings**: hand-written `extern` declarations in `c.zig` (mruby headers use C bitfields Zig can't represent; avoids deprecated `@cImport`), with an idiomatic safe Zig layer on top.

## How mruby 4.0.0 builds without Ruby (the core problem)

Rake normally generates four things; we generate all of them in Zig:

1. **presym tables** — 4.0 removed `MRB_NO_PRESYM`, so `include/mruby/presym/id.h` + `table.h` must be generated. Rake's algorithm (port from `lib/mruby/presym.rb`): preprocess every C source with `-DMRB_PRESYM_SCANNING` (turns `MRB_SYM(x)` into `<@! "x" !@>` markers), scan `mrblib/*.rb` and gem `.rb` files for symbol names, union all names, sort by (byte-length, name), emit an enum (`MRB_PRESYM__...`) plus length-grouped string tables. Only *internal consistency* is required, not upstream's exact numbering. Exact id assignment is deterministic.
2. **mrblib bytecode** — build a **host `mrbc`** with `zig cc` (core `src/*.c` + `mrbgems/mruby-compiler/core/{codegen.c,y.tab.c}` + `mrbc.c`, whose checked-in empty `mrb_init_mrblib`/`mrb_init_mrbgems` stubs break the bootstrap cycle), then run it on `mrblib/*.rb` and gem `.rb` files with `-B<sym> -o out.c -S -s` (cdump format, used because presym is on) via `b.addSystemCommand` + `addOutputFileArg` (cached by Zig).
3. **per-gem `gem_init.c`** — fixed template: `GENERATED_TMP_mrb_<gem>_gem_init/_final` wrapping `mrb_<gem>_gem_init/_final` + `mrb_load_proc`.
4. **top-level `gem_init.c`** — fixed template: init/final function table driven `mrb_init_mrbgems`.

## Architecture

```
mruby-zig/
├── .mise.toml                 # zig master snapshot pin
├── build.zig                  # full pipeline (below), exposes `mruby` module + static libmruby
├── build.zig.zon              # fingerprint, deps: mruby 4.0.0 tarball (hash-pinned)
├── build/                     # build-script modules (@import-ed by build.zig)
│   ├── gems.zig               # gem catalog: name → {c sources, mrblib rb files, build option sets}
│   ├── presym.zig             # presym scanner + id.h/table.h emitter
│   ├── gen.zig                # gem_init/mrblib wrapper C templates
│   └── sources.zig            # 4.0.0 core/compiler source lists
├── src/
│   ├── mruby.zig              # public API root (re-exports)
│   ├── c.zig                  # hand-written extern bindings (mrb_state opaque-ish, mrb_value extern struct)
│   ├── vm.zig                 # Vm: init/deinit, Zig-allocator-backed allocf, loadString/loadFile
│   ├── value.zig              # Value: type queries, to/from int/float/bool/string/symbol/nil
│   ├── class.zig              # defineClass/defineModule/defineMethod (+ userdata), constants, ivars
│   ├── data.zig               # mrb_data_object_alloc wrapper: Ruby objects wrapping Zig types
│   ├── error.zig              # protected evaluation (mrb_protect), exception capture, raise from Zig
│   ├── arena.zig              # GC arena save/restore scopes (RAII via defer)
│   ├── convert.zig            # Zig↔Ruby marshaling (primitives, strings, slices, optionals)
│   └── output.zig             # print/puts redirection to a std.Io.Writer interface
├── examples/                  # quickstart, host_functions (Ruby→Zig calls), exceptions
├── tests/                     # unit tests colocated in src files + ruby/ integration scripts
├── tools/                     # mruby-bin: `zig build mruby-repl` eval/REPL helper
├── .github/workflows/ci.yml   # linux+macos required / windows best-effort; zig fmt + build + test
├── README.md, LICENSE (MIT), CHANGELOG.md, .gitignore
```

**Safe-layer API sketch** (layered: raw `c.zig` stays importable for power users):

```zig
var vm = try mruby.Vm.init(gpa);       defer vm.deinit();
const result = try vm.loadString("2 + 2");   // error.RubyException on raise, details via vm.lastException()
const four = try result.asInt();             // i32
try vm.class("Math").defineMethod("dist", hostFn, ctx);  // Zig fns callable from Ruby
var scope = vm.arenaScope(); defer scope.restore();      // GC safety for held Values
```

Key design points: `mrb_get_args` variadic bridging via comptime arity switch; method userdata via registered `Data` objects; `mrb_value` extern-struct layout pinned to our chosen boxing config (upstream default, no-boxing) with a **runtime ABI sanity test** (fixnum/float/string roundtrips) to catch any mismatch immediately.

## Build pipeline in build.zig

```
zon dep mruby 4.0.0 ─► [scan] zig cc -E (presym markers) + .rb token scan ─► generate id.h/table.h
                  └─► [stage 1] host mrbc (zig cc, MRB_NO_GEMS-ish nested config, own presym set as rake does)
                        └─► [stage 2] run mrbc on mrblib/*.rb + gem rb files ─► cdump .c files
                              └─► [stage 3] WriteFiles: gem_init.c wrappers + top-level gem_init.c
                                    └─► [stage 4] libmruby.a (all C sources + generated, -I include + generated dir)
                                          └─► [stage 5] `mruby` module (linkLibrary), tests, examples, repl tool
```

Implementation details to resolve at start by reading the 4.0.0 tarball (fidelity oracles): `lib/mruby/presym.rb` (exact scanning algorithm), `lib/mruby/build.rb` `create_mrbc_build` (how the nested mrbc build configures presym in 4.0), `include/mruby.h` (whether custom allocf is still installable at open time in 4.0 — `mrb_open_allocf` was removed; if gone, set the `allocf` field directly or fall back to default allocator, decided by what the header exposes), and `tasks/mrblib.rake` cdump wrapper text.

## Milestones

1. **Scaffold**: git init, `.mise.toml` (zig master snapshot; `mise install`), LICENSE, README stub, `build.zig.zon` with mruby 4.0.0 fetched and hash-pinned, `.gitignore` (`zig-pkg/`, caches).
2. **Pipeline bring-up**: stage-1 mrbc builds and runs under `zig cc`; presym scanner port + emitters; core+compiler libmruby with stub gems first — validated by a Zig test doing `mrb_open` + eval `"1+1"` == 2.
3. **Gem machinery**: per-gem mrblib compilation, gem_init generation, Standard set enabled; validate `String#start_with?`, `Struct`, `sprintf`, `Random` etc. work.
4. **Bindings + safe layer**: `c.zig`, then vm/value/class/data/error/arena/convert/output, with ABI sanity test.
5. **Tests + examples**: unit tests per file (per-file `refAllDecls`), Ruby integration suite (`tests/ruby/*.rb` run through the VM with Zig-side asserts), three examples.
6. **Polish**: REPL/eval tool, README (quickstart, gem configuration, API tour, consumer `zig fetch` instructions), CHANGELOG, CI workflow, final `zig fmt` + full `zig build test` green.

## Risks & mitigations

- **Presym port fidelity** → algorithm is small and deterministic; only internal consistency matters; validated by mrblib loading + integration suite. (If Ruby is available locally at dev time, diff against rake output as an oracle; never required for consumer builds.)
- **Zig master churn** → pin an exact snapshot via mise; keep library code off fragile std surfaces; CI on the pin.
- **Running mrbc during build** → proven `addSystemCommand` + `addOutputFileArg` pattern, cached.
- **Windows cross-compile** → Standard gem set avoids io/socket; core should build under `zig cc -target x86_64-windows-gnu`; CI marks Windows best-effort.

Consumers end up with: `zig fetch --save=mruby https://github.com/<you>/mruby-zig/archive/refs/tags/v0.1.0.tar.gz`, then `exe.root_module.addImport("mruby", b.dependency("mruby", .{}).module("mruby"))` — everything else (fetching mruby, presym, bytecode, compilation) is self-contained in one `zig build`.

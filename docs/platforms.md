# Platform support matrix

| Target | Build | Tests | Notes |
| --- | --- | --- | --- |
| aarch64-macos | supported | unit + integration + ReleaseSafe (CI) | primary development platform |
| x86_64-macos | supported | unit + integration + ReleaseSafe (CI) | |
| x86_64-linux (ubuntu) | supported | unit + integration + ReleaseSafe + TSan + gem profiles (CI) | |
| aarch64-linux-gnu | cross-compiles (CI) | compile-only (`-Doptimize=ReleaseSafe`) | runtime not exercised in CI |
| x86_64-linux-musl | cross-compiles (CI) | compile-only | static-friendly libc |
| x86_64-windows-gnu | best effort | compile-only, `continue-on-error` in CI | no runtime CI; not supported until it has one |

## Constraints

- **64-bit targets only.** The hand-written `mrb_value`/`mrb_int` ABI in
  `src/c.zig` targets the package's supported 64-bit word-boxing
  configuration and rejects other pointer widths at compile time.
  `mruby.features.pointer_bits` and `mruby.features.endian` expose the
  resolved target traits; `mruby.features.sandbox_supported` summarizes
  whether the sandbox tier is usable.
- **Zig is pinned** to `0.17.0-dev.1978+c961124d9` via mise (`.mise.toml`).
  A tagged mruby-zig release can stop building under a moving Zig snapshot,
  so upgrades are deliberate: bump the pin together with any required
  build/API compatibility fixes, in their own change.
- **libc is linked**; the default process allocator is the thread-safe
  `std.heap.c_allocator` (see [getting-started.md](getting-started.md)).

## CI coverage

- `zig fmt --check`
- `zig build test` in Debug **and** `-Doptimize=ReleaseSafe` on macOS and
  Linux
- example binaries execute on every CI run (quickstart, host_functions,
  exceptions, sandbox, and the REPL)
- cross-compiles for the targets above
- ThreadSanitizer build and test on Linux
- gem profiles: `-Dgem-set=minimal`, `-Dwithout-gems=…` subsets

Windows runtime behavior is explicitly **not** claimed: compilation is
best-effort only. Promoting a target means adding its runtime tests to CI
and updating this matrix in the same change.

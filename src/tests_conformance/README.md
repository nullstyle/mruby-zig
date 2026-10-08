# mruby upstream conformance harness

`zig build test` runs mruby 4.0.0's own ISO test suite (`test/t/*.rb`,
43 of 42 files — see the exclusion note in build/sources.zig) through
this repository's build and safe layer. The suite runs as build-time
CodeDB artifacts: one entry per upstream file, each a separate parse
unit exactly like upstream's rake harness (concatenation changes heredoc
contexts). A generated prelude provides the driver environment that
upstream's `mrbgems/mruby-test/driver.c` compiles in:

- `GEMNAME = 'mruby-test'` and a silent `t_print`,
- `Mrbtest::FLOAT_TOLERANCE = 1e-10` (binary64 Float; driver.c:225),
- `_str_match?` as a `*`-glob — the suite's only pattern shape —
  ported to mruby semantics (mruby `String#[]` yields 1-character
  strings, not integers).

The `summary` entry depends on every test file and returns the upstream
counters; the Zig test requires zero failures and zero kills beyond the
documented upstream delta (4.0.0's own suite asserts `assert_nil
(1..).last` while 4.0.0's own range-ext mrblib raises RangeError — an
upstream suite/implementation inconsistency, not a mruby-zig
divergence). Current result: 697 pass, 0 fail, 1 documented delta.

The suite runs under `Policy.trusted` — it measures the language core,
not the sandbox (upstream's assert driver uses `__send__` and
metaprogramming that restricted policies mask).

When mruby is upgraded, the file list in build/sources.zig is the only
maintenance surface; the suite itself says what changed.

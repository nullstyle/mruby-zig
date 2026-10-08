# mruby 4.1.0-rc2 integration — COMPLETE (against rc2)

Branch: `mruby-4.1-rc2-integration` (from main @ ea953ff). Main stays on
4.0.0 until 4.1.0 final ships (stable-only pin policy); when it does, the
zon pin moves to the final tag and these notes drive the reconciliation.

## What is done (builds through compile; link frontier below)

- **Pins**: mruby 4.1.0-rc2 + ruby/prism @ c0e37816 (the mruby tarball's
  submodule is empty; prism is a second zon dependency).
- **Vendored Prism generated sources** (`vendor/prism/c0e37816/`, see its
  MANIFEST.md): node.c, prettyprint.c, serialize.c, token_type.c,
  diagnostic.c, ast.h, diagnostic.h — deterministic template outputs that
  upstream regenerates with Ruby. Upstream does NOT compile
  `ext/prism/api_node.c` (CRuby extension; needs ruby.h) — it is not
  vendored. Generation is a maintenance-only procedure, preserving the
  no-Ruby build contract.
- **`build/sources.zig` rewritten**: core (cdump/fmt_fp/readfloat out;
  fp_uscale/unicase in), mrc compiler glue (13 files under
  `mrbgems/mruby-compiler/src`, `mruby_compat.c` split out for the
  library-only link), prism hand-written (6 + `src/util/*` 10 — the rake
  globs `**/*.c`, easy to miss), vendored generated (5), mrbc (mrbc.c
  only; 4.1 has no stub.c).
- **Host mrbc redesigned** (the 4.1 bootstrap): mrbc.c is self-contained
  with its own mrb_malloc/intern/sym_name shims and no `<mruby.h>` —
  the tool links ONLY mrc glue + prism + mrbc.c. No core objects, no
  allocf (linking them is a duplicate-symbol error, not a choice). The
  mrc glue still includes `<mruby.h>`, whose presym.h needs generated
  id.h, so stage 1 (presym scan) remains, scanning core+compiler+mrbc as
  in 4.0 (headers only; an mrc-only scan yields an empty table and a
  broken empty enum). The mrc layer's own symbol table is the static
  `mrc_presym.inc`.
- **Includes**: gem `include/`, prism `include/` (prism.h is at its root
  as `prism.h`, and `ext/` must be on the path for
  `prism/extension.h`), vendored `include/` (ast.h, diagnostic.h).
  Defines: MRC_TARGET_MRUBY, PRISM_XALLOCATOR, PRISM_DEPTH_MAXIMUM=256
  (matches MRC_CODEGEN_LEVEL_MAX), PRISM_BUILD_MINIMAL.
- **Presym scan preprocessing** gained extra include dirs + prism
  defines (otherwise mrc_common.h fails on prism.h).
- Constants: mruby_version = "4.1.0-rc2". RITE binary/VM versions are
  UNCHANGED in 4.1 ("04.00"/"0400") — no rite constant churn, but the
  compatibility fingerprint still changes via package hash + presym
  digest, so 4.0 artifacts are rejected by construction.

## Resolved since the first checkpoint

The link frontier dissolved without a shim rewrite: `mruby_compat.c`
exports the entire 4.0 parse API (`mrb_parse_nstring`,
`mrb_load_nstring_cxt`, `mrb_ccontext_*`, `mrb_generate_code`, ...) as
shims over mrc — but ONLY under `MRC_TARGET_MRUBY`, so the fix was
compiling every mrc translation unit with the prism defines and include
roots (the define also selects the `mrc_ccontext` layout; it must be
uniform across TUs, exactly as upstream's rake warns).

Drifts found and fixed during bring-up:
- RITE compiler ident is now `HSMK0000` (mrc_dump.h redefines
  RITE_COMPILER_NAME "HSMK"; 4.0 wrote MATZ0000). rite_envelope accepts
  and writes HSMK0000, and the ident is a fingerprint input
  (`rite-compiler-ident=HSMK`).
- Unnamed compiles now record the source name `-e` where 4.0 recorded
  `(null)`; the suite test renamed accordingly.
- mruby 4.1 parses full int64 literals natively; the numerics suite's
  int32-overflow RangeError expectation replaced with value assertions.
- Prism needs `ext/` on the include path (`prism/extension.h`) and its
  `src/util/*.c` (the rake's recursive glob).

Verified: `zig build check` and the full test matrix green (default,
ReleaseSafe, minimal gem set, no-compiler) on macOS, and 380/380 steps
on native aarch64 Linux (including the B1 seccomp suite against the 4.1
runtime). The audited hash patch's literal contexts still match 4.1's
hash.c (the patcher fails loudly on drift, so a green build is the
proof). A 4.0.0-produced RITE fixture
(`src/tests_artifacts/rite_image_4_0_0.bin`, produced by main@ea953ff)
is rejected by classification through the typed API; raw `runImage`
bytes from 4.0 fail loudly as loader errors rather than misexecuting.

## Original frontier (kept for the record)

1. **shim.c parse-path rewrite** — the remaining link errors are the 4.0
   C parse API consumed by our trampolines: mrb_parser_free,
   mrb_parser_foreach_top_variable, mrb_parse_nstring,
   mrb_load_nstring_cxt, mrb_generate_code, mrb_ccontext_new/free/
   filename (15 undefined symbols). 4.1 replaces these with the mrc API
   (mrc_ccontext_*, mrc_compile/mrc_load_*; see
   mrbgems/mruby-compiler/include/mrc_compile.h, mrc_ccontext.h).
   `mrz_load_string`/`mrz_load_irep` trampolines and any c.zig
   declarations must move onto it; the protection-frame pattern stays.
   Check `mruby_compat.c` — it may already provide mrb_load_string
   compatibility shims (it is excluded from the tool link but part of
   the library), which could make this a thin rename.
2. **Stage 3 bytecode**: mrbc CLI still takes -B/-S/-s (verified in
   4.1's mrbc.c usage text); run it and reconcile any cdump format
   drift against build/gen.zig templates and tools/rite_envelope.zig's
   validateRiteHeaders (RITE "0400" unchanged).
3. **tools/patch_mruby_hash.zig**: verify both literal blocks still
   match 4.1's hash.c (the RC assessment believed so; the patch tool
   fails loudly otherwise). Also confirm the shim's `mrb_jmpbuf` and
   value accessors against 4.1's value.h/vm.c.
4. **gen.zig gem templates**: GENERATED_TMP_mrb_*_gem_init/final shape
   survives in 4.1's gem.rb; verify mrb_init_mrblib footer against
   4.1's tasks/mrblib.rake (grep says same shape).
5. News.md language NOTEs may shift the Ruby integration suites.
6. Cross-version fixture: add a 4.0.0-produced RITE image fixture
   (accepted-by-construction = rejected via fingerprint change).
7. Full matrix + packaged-consumer rehearsal; epoch review (formats did
   not change => epoch stays 3).

## Notes for the final release swap

- 4.1.0 final vs rc2: re-run `zig fetch` for both pins (hashes will
  move), regenerate the vendored prism artifacts only if the submodule
  pin moved (check .gitmodules pin in the final tarball), rerun this
  checklist.
- The zon hash flip-flop during bring-up: `zig fetch <url>` and
  `zig build` can report different hashes for the same URL depending on
  cached state; trust `zig build`'s "fetched package has ..." value.

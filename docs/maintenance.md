# Maintenance: mruby upgrades, patches, and releases

## Where the mruby build lives

`build.zig` mirrors mruby's rake build entirely in Zig:

1. **presym tables** — preprocess every C source with
   `-DMRB_PRESYM_SCANNING` (which turns `MRB_SYM(x)` into `<@! "x" !@>`
   markers), collect and sort symbols by (length, bytes), emit
   `mruby/presym/{id.h,table.h}`, and hash the final canonical symbol-to-ID
   table (`tools/presym_gen.zig`). That generated digest feeds the typed
   RITE compatibility fingerprint; input path names are never used as a
   substitute for the emitted table.
2. **host `mrbc`** — mruby's own bootstrap trick: the `mrbc` tool ships
   empty `mrb_init_mrblib`/`mrb_init_mrbgems` stubs, so it links without
   any generated files. It is built for the host with `zig cc` (with its
   own presym tables, like rake's nested build).
3. **bytecode** — run that `mrbc` over `mrblib/*.rb` and each gem's
   `mrblib/*.rb` (`-B<sym> -S -s`, cdump format), assembling `mrblib.c`
   and per-gem `gem_init.c` from the exact rake templates
   (`build/gen.zig`, `tools/file_join.zig`).
4. **gem registry** — a generated `gem_init.c` table driving
   `mrb_init_mrbgems`, in dependency-respecting order
   (`build/gems.zig`).

The Zig side never hand-decodes mruby struct layouts: `src/shim.c` compiles
inside libmruby and re-exposes the macro-only inline API (GC arena,
`mrb->exc`, integer/string accessors, value constructors) as plain
functions, keeping every layout decision on the C side.

## Audited core patch

`tools/patch_mruby_hash.zig` produces the one audited mruby core patch: a
cache-owned copy of `hash.c` (never written into the package dependency).
mruby 4.0 word boxing stores full-width signed integers outside the fixnum
range in `RInteger`, but the non-BigInt Hash fallback hashes those objects
by identity even though key equality compares their numeric value; its
Symbol branch also treats word-boxed symbols as fixnums and collapses their
hashes. The patch gives full-width Integer keys numeric hashes and Symbols
stable name-byte hashes. Both patch markers
(`hash_integer_patch_marker`, `hash_symbol_patch_marker` in `build.zig`)
participate in the RITE compatibility fingerprint, so any change to the
patch semantics rejects previously produced artifacts.

## Upgrading mruby

1. Update the `.mruby` dependency URL/hash in `build.zig.zon` (`zig fetch`
   prints the new hash) and the `mruby_version` / `rite_binary_version` /
   `rite_vm_version` constants in `build.zig`.
2. Run the full matrix: Debug and `ReleaseSafe` tests across the standard,
   `minimal`, and customized gem sets, plus the state-capsule process
   fixture and a fuzz session.
3. Reconcile upstream changes with `src/shim.c` (macro-only APIs can
   change shape) and `tools/patch_mruby_hash.zig` (the patch context is
   literal C text — upstream edits to `hash.c` break the match loudly, by
   design).
4. If the presym table layout or generation procedure changed, verify the
   canonical digest is still derived from the emitted table, not inputs.
5. The fingerprint changes automatically through its inputs (version,
   package hash, presym digest). If the artifact *formats* changed — not
   just the identity inputs — bump `rite_compatibility_epoch` so old
   artifacts are rejected rather than misread.

## Release and versioning

- Semantic versioning; during `0.x` breaking changes are allowed and must
  ship with migration notes in `CHANGELOG.md`.
- A release updates `CHANGELOG.md` (dated section), the `.version` field
  in `build.zig.zon`, and the README dependency snippet, then tags
  `vX.Y.Z`.
- Artifact compatibility is governed by the fingerprint/epoch system (see
  [artifacts.md](artifacts.md)), not by package version: a new package
  release that preserves all identity inputs still accepts previously
  produced artifacts.
- Zig version upgrades are their own change: move the `.mise.toml` pin and
  any compatibility fixes together, never ride along with a feature.

# Upstream assessment: mruby 4.1.0-rc (2026-09-04)

Upstream status at the time of the v0.4.0 release: **4.0.0 remains the
latest stable**, and **4.1.0-rc** was tagged 2026-09-04. Per
[maintenance.md](maintenance.md) the package pins stable releases only, so
no pin change was made; this assessment records what the upgrade to 4.1.0
(final) will involve. Verify against the actual 4.1.0 tarball when it
ships — RCs change.

Findings from diffing `4.1.0-rc` against our pinned `4.0.0`:

- **The audited hash patch is still needed and should still apply.** The
  `MRB_TT_INTEGER` identity-hash fallback our `tools/patch_mruby_hash.zig`
  rewrites is present and unchanged in shape; the patch tool fails loudly
  if the literal context drifts, so application is verified at build time.
  Notably, 4.1 fixes *related* word-boxing wide-Integer compare/sort bugs
  upstream (#7480/#7481) but not the Hash identity fallback itself.
- **The bison parser is replaced by Prism.** A clean-build attempt
  (integration branch `mruby-4.1-integration`) shows `y.tab.c` is gone;
  the compiler gem gained `prism.h`, `mrc_presym.c`, `ccontext.c`,
  `diagnostic.c`, and `mruby_compat.c` under `src/` with a new
  `include/` tree. `mruby-bin-mrbc` is also restructured (`mrc_irep.h`,
  moved bootstrap stubs) and core files (`cdump.c`, `fmt_fp.c`) moved.
  The presym pipeline, host-`mrbc` bootstrap, source lists, and likely
  `src/shim.c` all need rework — see `MIGRATION.md` on the integration
  branch for the full findings and work order.
- `src/hash.c`, `src/vm.c`, and `include/mruby/value.h` differ (notably
  new NaN-boxing equality notes in `value.h`); `src/shim.c` should be
  reviewed against any macro-inline API changes.
- Language-level `NOTE`s in `NEWS.md` (protected-method self checks,
  `method_missing` dispatch, container self-equality) may shift Ruby
  integration-suite expectations; the suite will say which.

Procedure when 4.1.0 final ships: follow
[maintenance.md](maintenance.md) — bump the zon URL/hash and the
`mruby_version`/RITE version constants, re-derive compiler paths, run the
full matrix plus the cross-version fixtures (a 4.0.0-produced RITE image
fixture would be worth adding at that point), and let the compatibility
fingerprint change do its job.

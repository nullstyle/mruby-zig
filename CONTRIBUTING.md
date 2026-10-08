# Contributing to mruby-zig

Thanks for considering a contribution. This project is pre-1.0 with a
single maintainer; these notes exist so external contributions can land
without archaeology.

## Getting started

```sh
mise install                # installs the pinned Zig exactly
mise x -- zig build test    # the whole suite (Zig + embedded Ruby + workers)
mise x -- zig build check   # compile everything without running tests
```

No Ruby toolchain, no rake, no submodules: one `zig build` fetches the
hash-pinned mruby dependency and generates everything else. If `mise` is
unavailable, any Zig matching `.mise.toml`'s version works.

## What CI runs (and so should you)

Every push runs the matrix in `.github/workflows/ci.yml`; locally the
highest-value subset is:

```sh
mise x -- zig fmt --check .
mise x -- zig build test
mise x -- zig build test -Doptimize=ReleaseSafe
mise x -- zig build test -Dgem-set=minimal
```

The suite includes mruby 4.0.0's own ISO test suite
(`src/tests_conformance/`), the sandbox and worker integration tests,
and cross-version artifact fixtures — so a green run is a strong signal.

## Change categories and their expectations

- **Safe API (`src/vm.zig`, `value.zig`, `class.zig`, ...)**: operations
  declare the named `mruby.VmError`; allocating mruby work stays inside
  the C protection trampolines (`src/shim.c`); VM-ownership checks apply
  at every ingress. Changes that grow `VmError` are breaking.
- **Sandbox / workers (`src/sandbox.zig`, `worker.zig`)**: preserve the
  documented threat model boundaries in `docs/sandboxing.md` and
  `docs/workers.md`; new limits or outcomes need tests proving both
  enforcement and non-enforcement paths.
- **Build (`build.zig`, `build/`)**: changes touching artifact identity
  (presym, defines, gems, patches) must state whether the RITE
  compatibility fingerprint inputs changed; when formats change, bump
  `rite_compatibility_epoch` with justification.
- **mruby upgrade**: follow `docs/maintenance.md` — pin bump, full
  matrix, shim/patch reconciliation, cross-version fixtures. Never ride
  an upstream bump along with a feature.
- **Zig upgrade**: its own change, pin + fixes together.

## Commit and PR conventions

- Imperative, one-line subject; body explains *why* when non-obvious.
- Each change keeps the suite green — including the conformance suite
  and packaged-consumer rehearsal for anything touching CodeDB or the
  build (`mise x -- bash tools/test_codedb_package.sh standard
  ReleaseSafe`).
- Update `CHANGELOG.md` under `## Unreleased` for user-visible changes.

## Reporting bugs

Open an issue with: the Zig version (`zig version`), the build profile
(gem set, `-Dno-compiler`, optimize mode), a minimal reproducer, and —
for artifact or worker issues — the exact error classification, not just
the message. Security reports follow `SECURITY.md`.

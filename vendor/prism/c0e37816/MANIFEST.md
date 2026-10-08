# Vendored Prism generated sources

Prism ships `src/node.c`, `src/prettyprint.c`, `src/serialize.c`,
`src/token_type.c`, `src/diagnostic.c`, `include/prism/ast.h`, and
`ext/prism/api_node.c` only as Ruby `templates/*.erb` outputs: upstream's
rake regenerates them with `templates/template.rb` at build time. That
collides with this repository's no-Ruby build contract, so the artifacts
are generated **once per pinned submodule commit**, vendored here, and
verified against the recorded SHA-256 digests by the build.

- Prism submodule pin (mruby 4.1.0-rc2 `mrbgems/mruby-compiler/lib/prism`):
  `c0e37816e97e23e92524a4070e1b99a4025bc63f`
  (https://github.com/ruby/prism/archive/c0e37816e97e23e92524a4070e1b99a4025bc63f.tar.gz)
- Generation is deterministic (byte-identical across runs; verified).
- Regen procedure (maintenance only, never at consumer build time):

  ```sh
  curl -sL -o prism.tar.gz \
    https://github.com/ruby/prism/archive/c0e37816e97e23e92524a4070e1b99a4025bc63f.tar.gz
  tar xzf prism.tar.gz
  cd prism-c0e37816e97e23e92524a4070e1b99a4025bc63f
    ruby templates/template.rb include/prism/ast.h       <out>/include/prism/ast.h
  ruby templates/template.rb src/diagnostic.c          <out>/src/diagnostic.c
  ruby templates/template.rb src/node.c                <out>/src/node.c
  ruby templates/template.rb src/prettyprint.c         <out>/src/prettyprint.c
  ruby templates/template.rb src/serialize.c           <out>/src/serialize.c
  ruby templates/template.rb src/token_type.c          <out>/src/token_type.c
  shasum -a 256 ...   # must match the table below
  ```

| Artifact | SHA-256 |
| --- | --- |
| src/diagnostic.c | 5fa77141ef5f45d283ee7d11ed31f4dc0ada49dd1fc659d0e24346734648d3e7 |
| src/node.c | 7e59af22014660d5317cd92590550a04b398e8a69216d633464ecd1ad0d227b1 |
| src/prettyprint.c | e46f400adfe053b9d52c137289ae596a828b5aa61ced99bcabd8326e23a70f74 |
| src/serialize.c | 8adbf5818daaf5b7aa97b12f0f41b0de50282afd0996e1fd3c72441718b1902f |
| src/token_type.c | 7c465cd780a10ae011c7ac2124b937719bde9919e4f91f12d67034ca7e4d4a30 |
| include/prism/ast.h | d389d8726755de86f2895c0cf36d95d91ebe95f369493b40a3b84dc2193ee43c |

The `#line` directives in these files name paths relative to the prism
repository root (mruby's rake rewrites them to be tree-relative). The
Zig build adds the prism include root so they resolve for diagnostics
only; no compilation semantics depend on them.

When the submodule pin moves (an mruby upgrade), regenerate into a new
`vendor/prism/<commit>/` directory and update the pin above; the Zig
build's digest check fails loudly if the vendored bytes drift.

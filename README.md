# mruby-zig

Embed [mruby](https://mruby.org) 4.0 in Zig applications — first-class,
production-grade, and built entirely with `zig`: no Ruby, no rake, no
submodules. One `zig build` fetches mruby, generates its presym tables and
core bytecode, compiles everything with `zig cc`, and hands you a `mruby`
module.

**Status: under development.** (Full documentation lands with the first
release.)

## Toolchain

Zig master, tracked with [mise](https://mise.jdx.dev):

```
mise install   # resolves the `master` channel to a pinned snapshot
mise x -- zig build test
```

## License

MIT — see [LICENSE](LICENSE). mruby itself is MIT and fetched at build time
as a pinned, hash-verified dependency.

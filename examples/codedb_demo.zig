//! CodeDB demo: Ruby compiled at build time by the host mrbc, executed
//! from the generated manifest with no runtime parsing of source.
//!
//!     zig build run-codedb-demo

const std = @import("std");
const mruby = @import("mruby");
const codedb_manifest = @import("codedb_manifest");

pub fn main() !void {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(
        mruby.sandbox.Policy.trusted(.{}),
    );
    defer boot.deinit();
    const iso = try boot.seal();
    defer iso.deinit();

    _ = try mruby.codedb.run(iso, codedb_manifest, "accumulate");
    const total = try iso.getGlobal("codedb_total");
    try std.testing.expectEqual(@as(i64, 5740), try total.asInt());

    _ = try mruby.codedb.run(iso, codedb_manifest, "dispatch");
    const dispatched = try iso.getGlobal("codedb_dispatch");
    try std.testing.expectEqual(@as(i64, 42), try dispatched.asInt());

    std.debug.print("codedb: accumulate -> {d}, dispatch -> {d}\n", .{
        try total.asInt(),
        try dispatched.asInt(),
    });
}

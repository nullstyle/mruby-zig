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

    _ = try iso.runArtifact(codedb_manifest, "accumulate");
    const total = try iso.getGlobal("codedb_total");
    try std.testing.expectEqual(@as(i64, 5740), try total.asInt());

    _ = try iso.runArtifact(codedb_manifest, "dispatch");
    const dispatched = try iso.getGlobal("codedb_dispatch");
    try std.testing.expectEqual(@as(i64, 42), try dispatched.asInt());

    std.debug.print("codedb: accumulate -> {d}, dispatch -> {d}\n", .{
        try total.asInt(),
        try dispatched.asInt(),
    });

    try invoiceJob();
}

fn invoiceJob() !void {
    var boot = try mruby.sandbox.BootstrapIsolate.spawn(mruby.sandbox.Policy.restricted(.{
        .limits = .{ .gas = .{ .per_execution = 10_000 }, .call_depth = 32 },
    }));
    defer boot.deinit();
    const iso = try boot.seal();
    defer iso.deinit();

    // Load policy data and startup code once. Both initializers share one
    // execution budget; a repeat load does not reset the job counter.
    try std.testing.expect(try iso.loadArtifact(codedb_manifest, "billing"));
    try std.testing.expect(!try iso.loadArtifact(codedb_manifest, "billing"));

    // All application Ruby comes from CodeDB; inputs are ordinary host values.
    const first = try iso.array(&.{ try iso.intValue(2500), try iso.intValue(3) });
    const second = try iso.array(&.{ try iso.intValue(1800), try iso.intValue(2) });
    const items = try iso.array(&.{ first.asValue(), second.asValue() });
    try iso.setGlobal("invoice_items", items.asValue());
    const result = try iso.runArtifact(codedb_manifest, "invoice");
    const amounts = try result.asArray();
    try std.testing.expectEqual(@as(i64, 11100), try (try amounts.get(0)).asInt());
    try std.testing.expectEqual(@as(i64, 1110), try (try amounts.get(1)).asInt());
    try std.testing.expectEqual(@as(i64, 9990), try (try amounts.get(2)).asInt());
    try std.testing.expect(!try iso.loadArtifact(codedb_manifest, "billing"));
    _ = try iso.runArtifact(codedb_manifest, "invoice");
    try std.testing.expectEqual(@as(i64, 2), try (try iso.getGlobal("invoice_jobs")).asInt());

    const entry = mruby.codedb.lookup(codedb_manifest, "invoice").?;
    try std.testing.expectEqualStrings(entry.source_name, try (try amounts.get(3)).asString());
    // The result can cross the existing inert state-transfer interface.
    var capsule = try iso.exportValue(std.heap.page_allocator, result, .{});
    defer capsule.deinit(std.heap.page_allocator);
    std.debug.print("codedb: {s} -> subtotal {d}, discount {d}, due {d} cents ({d}-byte capsule)\n", .{
        entry.source_name,
        try (try amounts.get(0)).asInt(),
        try (try amounts.get(1)).asInt(),
        try (try amounts.get(2)).asInt(),
        capsule.encoded.len,
    });
}

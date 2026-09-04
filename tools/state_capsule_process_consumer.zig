//! Restore a StateCapsule read from stdin into a fresh mruby process and
//! verify cycles, aliases, defaults, insertion order, frozen state, and NULs.

const std = @import("std");
const mruby = @import("mruby");
const fixture = @import("state_capsule_process_common.zig");

const max_fixture_bytes = 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(init.gpa);

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    while (true) {
        const chunk = stdin_file.interface.peekGreedy(1) catch break;
        if (chunk.len == 0) break;
        if (chunk.len > max_fixture_bytes -| encoded.items.len) {
            return error.FixtureTooLarge;
        }
        try encoded.appendSlice(init.gpa, chunk);
        _ = try stdin_file.interface.discard(.limited(chunk.len));
    }
    if (encoded.items.len == 0) return error.EmptyFixture;
    if (encoded.items.len != fixture.encoded_len) return error.UnstableFixtureEncoding;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded.items, &digest, .{});
    if (!std.mem.eql(u8, &digest, &fixture.encoded_sha256)) {
        return error.UnstableFixtureEncoding;
    }

    var boot = try mruby.sandbox.BootstrapIsolate.spawn(.{});
    defer boot.deinit();
    const isolate = try boot.seal();
    defer isolate.deinit();
    const restored = try isolate.importValue(.{ .bytes = encoded.items }, .{
        .accepted_schema = fixture.schema,
    });
    try isolate.setGlobal("restored_graph", restored);
    if (!(try isolate.run(fixture.consumer_assertion)).isTruthy()) {
        return error.RestoredGraphMismatch;
    }
}

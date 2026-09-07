//! Host identities for one explicitly identified Ruby method invocation.
//! The host attests the code bundle, bootstrap contract, and complete starting
//! state. These hashes do not inspect or authenticate the receiver's Ruby heap.
const std = @import("std");

pub const Invocation = struct {
    /// Identity of the complete code bundle containing this method.
    code: [32]u8,
    /// Identity of the host bootstrap contract (classes, methods, and setup).
    bootstrap: [32]u8,
    /// Identity of all starting state observable by the receiver and handlers.
    state: [32]u8,
    /// Stable logical receiver name; never a VM pointer or object address.
    receiver: []const u8,

    pub fn validate(self: Invocation, method: []const u8, max_bytes: usize) !void {
        if (method.len == 0 or self.receiver.len == 0 or
            std.mem.indexOfScalar(u8, method, 0) != null or
            std.mem.indexOfScalar(u8, self.receiver, 0) != null)
            return error.InvalidEffectInvocation;
        if (method.len >= 256) return error.NameTooLong;
        if (method.len > max_bytes or self.receiver.len > max_bytes)
            return error.EffectLimitExceeded;
    }

    /// Binds the actual dispatch method, rather than a duplicate host label.
    pub fn codeIdentity(self: Invocation, method: []const u8) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("mruby-zig.effect.invocation.code.v1\x00");
        hash.update(&self.code);
        hash.update(&self.bootstrap);
        hashBytes(&hash, self.receiver);
        hashBytes(&hash, method);
        return hash.finalResult();
    }

    /// `arguments` is the canonical capsule of the exact positional values
    /// supplied to Ruby, after inert snapshotting and before method dispatch.
    pub fn inputIdentity(self: Invocation, configured: [32]u8, arguments: []const u8) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("mruby-zig.effect.invocation.input.v1\x00");
        hash.update(&self.state);
        hash.update(&configured);
        hashBytes(&hash, arguments);
        return hash.finalResult();
    }
};

fn hashBytes(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
    hash.update(&length);
    hash.update(bytes);
}

test "invocation identities bind host attestations and actual dispatch inputs" {
    const invocation: Invocation = .{
        .code = @splat(1),
        .bootstrap = @splat(2),
        .state = @splat(3),
        .receiver = "inventory/42",
    };
    const configured: [32]u8 = @splat(4);
    const code = invocation.codeIdentity("reserve");
    const input = invocation.inputIdentity(configured, "capsule");
    try std.testing.expectEqualSlices(u8, &code, &invocation.codeIdentity("reserve"));
    try std.testing.expectEqualSlices(u8, &input, &invocation.inputIdentity(configured, "capsule"));

    var changed = invocation;
    changed.code[0] ^= 1;
    try std.testing.expect(!std.mem.eql(u8, &code, &changed.codeIdentity("reserve")));
    changed = invocation;
    changed.bootstrap[0] ^= 1;
    try std.testing.expect(!std.mem.eql(u8, &code, &changed.codeIdentity("reserve")));
    changed = invocation;
    changed.receiver = "inventory/43";
    try std.testing.expect(!std.mem.eql(u8, &code, &changed.codeIdentity("reserve")));
    try std.testing.expect(!std.mem.eql(u8, &code, &invocation.codeIdentity("inspect")));
    changed = invocation;
    changed.state[0] ^= 1;
    try std.testing.expect(!std.mem.eql(u8, &input, &changed.inputIdentity(configured, "capsule")));
    try std.testing.expect(!std.mem.eql(u8, &input, &invocation.inputIdentity(@splat(5), "capsule")));
    try std.testing.expect(!std.mem.eql(u8, &input, &invocation.inputIdentity(configured, "changed capsule")));
}

test "invocation text identities are bounded and framed unambiguously" {
    var invocation: Invocation = .{
        .code = @splat(0),
        .bootstrap = @splat(0),
        .state = @splat(0),
        .receiver = "a",
    };
    try invocation.validate("bc", 256);
    const code = invocation.codeIdentity("bc");
    invocation.receiver = "ab";
    try std.testing.expect(!std.mem.eql(u8, &code, &invocation.codeIdentity("c")));
    try std.testing.expectError(error.InvalidEffectInvocation, invocation.validate("", 256));
    try std.testing.expectError(error.InvalidEffectInvocation, invocation.validate("a\x00b", 256));
    try std.testing.expectError(error.NameTooLong, invocation.validate(&(@as([256]u8, @splat('x'))), 256));
    try std.testing.expectError(error.EffectLimitExceeded, invocation.validate("a", 1));
    invocation.receiver = "";
    try std.testing.expectError(error.InvalidEffectInvocation, invocation.validate("a", 256));
    invocation.receiver = "a\x00b";
    try std.testing.expectError(error.InvalidEffectInvocation, invocation.validate("a", 256));
}

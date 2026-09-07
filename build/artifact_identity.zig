//! Canonical build identity for typed RITE artifacts.
//!
//! This module deliberately accepts only inputs that can change whether a
//! dumped mruby irep is safe to load. Host labels such as OS, libc, CPU name,
//! optimization mode, and sanitizer settings have no representation here, so
//! compatible builds cannot accidentally diverge on those labels.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const fingerprint_domain = "mruby-zig/rite-compatibility/v1\x00";
pub const presym_table_digest_domain = "mruby-zig/presym-table/v1\x00";

pub const Endian = enum(u8) {
    little = 1,
    big = 2,
};

pub const Boxing = enum(u8) {
    word = 1,
    nan = 2,
    none = 3,
};

/// All fields are semantic. Sequences preserve order, including the ordered
/// gem initialization list and generated-code configuration markers.
pub const Inputs = struct {
    mruby_version: []const u8,
    mruby_package_hash: []const u8,
    rite_binary_version: []const u8,
    rite_vm_version: []const u8,
    compatibility_epoch: u32,

    pointer_bits: u16,
    endian: Endian,
    integer_bits: u16,
    /// Zero denotes an integer-only runtime with no Float representation.
    float_bits: u16,
    boxing: Boxing,
    inline_float: bool,

    semantic_defines: []const []const u8,
    ordered_gems: []const []const u8,
    /// Digest of the final canonical presym symbol-to-ID table emitted for the
    /// target library, not merely the paths or sources scanned to produce it.
    presym_table_digest: [Sha256.digest_length]u8,
    generated_configuration: []const []const u8,
};

/// Hash the semantic contents of an emitted presym table. `symbols` must be in
/// the generator's final canonical order; IDs are their one-based positions.
/// Length-prefixing keeps arbitrary symbol bytes unambiguous and avoids making
/// the compatibility identity depend on C-header formatting or host paths.
pub fn presymTableDigest(symbols: []const []const u8) [Sha256.digest_length]u8 {
    var hash = Sha256.init(.{});
    hash.update(presym_table_digest_domain);

    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, std.math.cast(u32, symbols.len) orelse
        @panic("presym table exceeds u32"), .big);
    hash.update(&count);

    for (symbols, 1..) |symbol, id| {
        var encoded_id: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded_id, std.math.cast(u32, id) orelse
            @panic("presym ID exceeds u32"), .big);
        hash.update(&encoded_id);
        bytes(&hash, symbol);
    }
    return hash.finalResult();
}

/// Returns the SHA-256 RITE compatibility identity. The serialization below
/// is intentionally private: callers exchange only the digest, while tests
/// pin it to catch accidental changes to the canonicalization.
pub fn fingerprint(inputs: Inputs) [Sha256.digest_length]u8 {
    var hash = Sha256.init(.{});
    hash.update(fingerprint_domain);

    stringField(&hash, "mruby-version", inputs.mruby_version);
    stringField(&hash, "mruby-package-hash", inputs.mruby_package_hash);
    stringField(&hash, "rite-binary-version", inputs.rite_binary_version);
    stringField(&hash, "rite-vm-version", inputs.rite_vm_version);
    integerField(&hash, "compatibility-epoch", u32, inputs.compatibility_epoch);

    integerField(&hash, "pointer-bits", u16, inputs.pointer_bits);
    integerField(&hash, "endian", u8, @backingInt(inputs.endian));
    integerField(&hash, "integer-bits", u16, inputs.integer_bits);
    integerField(&hash, "float-bits", u16, inputs.float_bits);
    integerField(&hash, "boxing", u8, @backingInt(inputs.boxing));
    integerField(&hash, "inline-float", u8, @intFromBool(inputs.inline_float));

    sequenceField(&hash, "semantic-defines", inputs.semantic_defines);
    sequenceField(&hash, "ordered-gems", inputs.ordered_gems);
    stringField(&hash, "presym-table-digest", &inputs.presym_table_digest);
    sequenceField(&hash, "generated-configuration", inputs.generated_configuration);

    return hash.finalResult();
}

fn stringField(hash: *Sha256, label: []const u8, value: []const u8) void {
    bytes(hash, label);
    bytes(hash, value);
}

fn integerField(hash: *Sha256, label: []const u8, comptime T: type, value: T) void {
    bytes(hash, label);
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .big);
    bytes(hash, &encoded);
}

fn sequenceField(hash: *Sha256, label: []const u8, values: []const []const u8) void {
    bytes(hash, label);
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, std.math.cast(u32, values.len) orelse
        @panic("RITE compatibility input sequence exceeds u32"), .big);
    hash.update(&count);
    for (values) |value| bytes(hash, value);
}

fn bytes(hash: *Sha256, value: []const u8) void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, std.math.cast(u32, value.len) orelse
        @panic("RITE compatibility input field exceeds u32"), .big);
    hash.update(&len);
    hash.update(value);
}

const fixture = Inputs{
    .mruby_version = "4.0.0",
    .mruby_package_hash = "N-V-example",
    .rite_binary_version = "04.00",
    .rite_vm_version = "0400",
    .compatibility_epoch = 1,
    .pointer_bits = 64,
    .endian = .little,
    .integer_bits = 64,
    .float_bits = 64,
    .boxing = .word,
    .inline_float = true,
    .semantic_defines = &.{ "MRB_USE_DEBUG_HOOK", "MRB_USE_SET" },
    .ordered_gems = &.{ "mruby-hash-ext", "mruby-set" },
    .presym_table_digest = @splat(0xa5),
    .generated_configuration = &.{ "presym-generator-v1", "mrbc-cdump-static-v1" },
};

test "presym table digest has a stable canonical vector" {
    const digest = presymTableDigest(&.{ "+", "foo", "length" });
    const got = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "e5ad9d6225216008629caeb1fee7b132ba6d5e07a699db4bc22493c9a1a4eb34",
        &got,
    );

    const reordered = presymTableDigest(&.{ "foo", "+", "length" });
    try std.testing.expect(!std.mem.eql(u8, &digest, &reordered));
    const changed = presymTableDigest(&.{ "+", "foo", "length?" });
    try std.testing.expect(!std.mem.eql(u8, &digest, &changed));
}

test "fingerprint has a stable canonical vector" {
    const got = std.fmt.bytesToHex(fingerprint(fixture), .lower);
    try std.testing.expectEqualStrings(
        "7df1c683c017f451d02187cf6b69976876c40d96cbdcc13fbae0b36e7dbadc42",
        &got,
    );
}

test "every semantic class changes the fingerprint" {
    const baseline = fingerprint(fixture);

    var changed = fixture;
    changed.mruby_package_hash = "N-V-other";
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.rite_binary_version = "0500";
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.rite_vm_version = "0500";
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.compatibility_epoch += 1;
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.pointer_bits = 32;
    changed.integer_bits = 32;
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.endian = .big;
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.float_bits = 32;
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.boxing = .none;
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.inline_float = false;
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.semantic_defines = &.{"MRB_USE_DEBUG_HOOK"};
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.ordered_gems = &.{ "mruby-set", "mruby-hash-ext" };
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.presym_table_digest[0] ^= 1;
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));

    changed = fixture;
    changed.generated_configuration = &.{ "presym-generator-v2", "mrbc-cdump-static-v1" };
    try std.testing.expect(!std.mem.eql(u8, &baseline, &fingerprint(changed)));
}

test "unrepresented build labels cannot affect the fingerprint" {
    try std.testing.expect(!@hasField(Inputs, "presym_inputs"));
    try std.testing.expect(!@hasField(Inputs, "os_tag"));
    try std.testing.expect(!@hasField(Inputs, "libc"));
    try std.testing.expect(!@hasField(Inputs, "cpu_name"));
    try std.testing.expect(!@hasField(Inputs, "optimize"));
    try std.testing.expect(!@hasField(Inputs, "sanitize_thread"));

    const macos_debug_cpu_name = fingerprint(fixture);
    const linux_release_cpu_name = fingerprint(fixture);
    try std.testing.expectEqualSlices(u8, &macos_debug_cpu_name, &linux_release_cpu_name);
}

test "integer-only traits and policy distinguish artifacts from Float builds" {
    var integer_only = fixture;
    integer_only.float_bits = 0;
    integer_only.inline_float = false;
    integer_only.semantic_defines = &.{ "MRB_NO_FLOAT", "MRB_INT64", "MRZ_INTEGER_ONLY=1" };
    integer_only.generated_configuration = &.{"effects-integer64-policy=v1"};
    const integer_digest = fingerprint(integer_only);
    try std.testing.expect(!std.mem.eql(u8, &fingerprint(fixture), &integer_digest));
    var changed_policy = integer_only;
    changed_policy.generated_configuration = &.{"effects-integer64-policy=v2"};
    try std.testing.expect(!std.mem.eql(u8, &fingerprint(changed_policy), &integer_digest));
}

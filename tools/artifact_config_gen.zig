//! Generate the Zig module consumed by typed RITE compilation/execution.
//!
//! The final presym table is a build output, so its digest is unavailable while
//! build.zig is being configured. This host tool runs after presym generation,
//! combines that digest with the target's semantic identity inputs, and emits a
//! Zig module. Importing that module gives every consumer the correct build-
//! graph dependency rather than an eagerly computed approximation.

const std = @import("std");
const artifact_identity = @import("artifact_identity");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    _ = args.next() orelse return fatal("missing argv0", .{});

    const digest_path = args.next() orelse return fatal("missing presym digest path", .{});
    const mruby_version = args.next() orelse return fatal("missing mruby version", .{});
    const mruby_package_hash = args.next() orelse return fatal("missing mruby package hash", .{});
    const rite_binary_version = args.next() orelse return fatal("missing RITE binary version", .{});
    const rite_vm_version = args.next() orelse return fatal("missing RITE VM version", .{});
    const compatibility_epoch = try parseUnsigned(u32, args.next() orelse
        return fatal("missing compatibility epoch", .{}), "compatibility epoch");
    const pointer_bits = try parseUnsigned(u16, args.next() orelse
        return fatal("missing pointer width", .{}), "pointer width");
    const endian = try parseEndian(args.next() orelse return fatal("missing endianness", .{}));
    const integer_bits = try parseUnsigned(u16, args.next() orelse
        return fatal("missing Integer width", .{}), "Integer width");
    const float_bits = try parseUnsigned(u16, args.next() orelse
        return fatal("missing Float width", .{}), "Float width");
    const boxing = try parseBoxing(args.next() orelse return fatal("missing boxing mode", .{}));
    const inline_float = try parseBool(args.next() orelse return fatal("missing inline-float flag", .{}));

    var semantic_defines: std.ArrayList([]const u8) = .empty;
    defer semantic_defines.deinit(allocator);
    try readSequence(&args, allocator, "semantic defines", &semantic_defines);

    var ordered_gems: std.ArrayList([]const u8) = .empty;
    defer ordered_gems.deinit(allocator);
    try readSequence(&args, allocator, "ordered gems", &ordered_gems);

    var generated_configuration: std.ArrayList([]const u8) = .empty;
    defer generated_configuration.deinit(allocator);
    try readSequence(&args, allocator, "generated configuration", &generated_configuration);

    const output_path = args.next() orelse return fatal("missing output path", .{});
    if (args.next() != null) return fatal("unexpected trailing argument", .{});

    const digest_bytes = cwd.readFileAlloc(io, digest_path, allocator, .limited(33)) catch |err|
        return fatal("reading {s}: {s}", .{ digest_path, @errorName(err) });
    defer allocator.free(digest_bytes);
    if (digest_bytes.len != 32) {
        return fatal("{s} has {d} bytes; expected 32", .{ digest_path, digest_bytes.len });
    }
    var presym_table_digest: [32]u8 = undefined;
    @memcpy(&presym_table_digest, digest_bytes);

    const fingerprint = artifact_identity.fingerprint(.{
        .mruby_version = mruby_version,
        .mruby_package_hash = mruby_package_hash,
        .rite_binary_version = rite_binary_version,
        .rite_vm_version = rite_vm_version,
        .compatibility_epoch = compatibility_epoch,
        .pointer_bits = pointer_bits,
        .endian = endian,
        .integer_bits = integer_bits,
        .float_bits = float_bits,
        .boxing = boxing,
        .inline_float = inline_float,
        .semantic_defines = semantic_defines.items,
        .ordered_gems = ordered_gems.items,
        .presym_table_digest = presym_table_digest,
        .generated_configuration = generated_configuration.items,
    });

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeByteArray(&output.writer, "rite_compatibility_fingerprint", &fingerprint);
    const fingerprint_hex = std.fmt.bytesToHex(fingerprint, .lower);
    try output.writer.print(
        "pub const rite_compatibility_fingerprint_hex = \"{s}\";\n",
        .{&fingerprint_hex},
    );
    try writeByteArray(&output.writer, "presym_table_digest", &presym_table_digest);
    try output.writer.print(
        \\pub const rite_compatibility_epoch: u32 = {d};
        \\pub const rite_binary_version = "{s}";
        \\pub const rite_vm_version = "{s}";
        \\
    , .{ compatibility_epoch, rite_binary_version, rite_vm_version });

    if (std.fs.path.dirname(output_path)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{
        .sub_path = output_path,
        .data = output.writer.buffer[0..output.writer.end],
    });
}

fn readSequence(
    args: *std.process.Args.Iterator,
    allocator: std.mem.Allocator,
    label: []const u8,
    output: *std.ArrayList([]const u8),
) !void {
    const count_text = args.next() orelse return fatal("missing {s} count", .{label});
    const count = try parseUnsigned(usize, count_text, label);
    try output.ensureTotalCapacity(allocator, count);
    for (0..count) |_| {
        output.appendAssumeCapacity(args.next() orelse
            return fatal("missing entry in {s}", .{label}));
    }
}

fn parseUnsigned(comptime T: type, text: []const u8, label: []const u8) error{Fatal}!T {
    return std.fmt.parseInt(T, text, 10) catch
        return fatal("invalid {s}: {s}", .{ label, text });
}

fn parseEndian(text: []const u8) error{Fatal}!artifact_identity.Endian {
    if (std.mem.eql(u8, text, "little")) return .little;
    if (std.mem.eql(u8, text, "big")) return .big;
    return fatal("invalid endianness: {s}", .{text});
}

fn parseBoxing(text: []const u8) error{Fatal}!artifact_identity.Boxing {
    if (std.mem.eql(u8, text, "word")) return .word;
    if (std.mem.eql(u8, text, "nan")) return .nan;
    if (std.mem.eql(u8, text, "none")) return .none;
    return fatal("invalid boxing mode: {s}", .{text});
}

fn parseBool(text: []const u8) error{Fatal}!bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return fatal("invalid boolean: {s}", .{text});
}

fn writeByteArray(writer: *std.Io.Writer, name: []const u8, bytes: *const [32]u8) !void {
    try writer.print("pub const {s} = [32]u8{{\n", .{name});
    for (bytes, 0..) |byte, index| {
        if (index % 8 == 0) try writer.writeAll("    ");
        try writer.print("0x{x:0>2},", .{byte});
        if (index % 8 == 7) {
            try writer.writeByte('\n');
        } else {
            try writer.writeByte(' ');
        }
    }
    try writer.writeAll("};\n");
}

fn fatal(comptime fmt: []const u8, values: anytype) error{Fatal} {
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "artifact_config_gen: " ++ fmt ++ "\n", values) catch
        "artifact_config_gen: fatal error\n";
    std.debug.print("{s}", .{message});
    return error.Fatal;
}

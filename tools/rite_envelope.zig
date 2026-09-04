//! Wrap independently compiled host-mrbc outputs in typed envelopes and
//! publish a content-addressed CodeDB manifest. This tool never executes Ruby.
//!
//! Usage: rite_envelope output_dir tier allowed_bits host_count [host_name bits]...
//! [name source_name source_file pass_a pass_b application_hex_or_dash entrypoint
//! dependency_count dependency_names... required_bits host_ref_count host_names...]...

const std = @import("std");
const artifact = @import("artifact");
const artifact_config = @import("artifact_config");
const features = @import("codedb_features");
const graph = @import("codedb_graph");
const authority = @import("authority_manifest");
const gate = authority.CodeDB;
const Sha256 = std.crypto.hash.sha2.Sha256;

// This profile comes from the configured dependency, never from CLI declarations.
const linked_profile: [features.authority_source_names.len]authority.Source = blk: {
    var sources: [features.authority_source_names.len]authority.Source = undefined;
    for (features.authority_source_names, features.authority_source_bits, &sources) |name, bits, *source| {
        source.* = .{ .name = name, .authority = authority.Set.fromBits(bits) };
    }
    break :blk sources;
};

const Authority = struct {
    tier: gate.Tier = .worker,
    hosts: []const gate.HostBinding = &.{},
    profile: []const authority.Source = &linked_profile,
};

const Input = struct {
    name: []const u8,
    source_name: []const u8,
    source_file: []const u8,
    pass_a: []const u8,
    pass_b: []const u8,
    application_hex: []const u8,
    entrypoint: bool = true,
    dependencies: []const []const u8 = &.{},
    required_authority: authority.Set = .empty,
    host_bindings: []const []const u8 = &.{},
};

const Prepared = struct {
    name: []const u8,
    source_name: []const u8,
    source_hash: [32]u8,
    artifact_hash: [32]u8,
    application: ?artifact.ApplicationFingerprint,
    entrypoint: bool,
    dependencies: []const []const u8,
    required_authority: authority.Set,
    host_bindings: []const []const u8,
    effective_authority: authority.Set = .empty,
    image: artifact.RiteImage,

    fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
        allocator.free(self.dependencies);
        allocator.free(self.host_bindings);
    }
};

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return 1;
    const output_dir = args.next() orelse return fatal("missing output directory", .{});
    const tier_tag = args.next() orelse return fatal("missing authority tier", .{});
    const allowed_text = args.next() orelse return fatal("missing allowed authority", .{});
    const tier = parseTier(tier_tag, allowed_text) catch |err| return fatal("authority tier: {s}", .{@errorName(err)});
    const host_count_text = args.next() orelse return fatal("missing host binding count", .{});
    const host_count = std.fmt.parseInt(usize, host_count_text, 10) catch return fatal("invalid host binding count", .{});
    var hosts: std.ArrayList(gate.HostBinding) = .empty;
    defer hosts.deinit(init.gpa);
    for (0..host_count) |_| {
        const name = args.next() orelse return fatal("missing host binding name", .{});
        const bits_text = args.next() orelse return fatal("{s}: missing host authority", .{name});
        const bits = std.fmt.parseInt(u16, bits_text, 10) catch return fatal("{s}: invalid host authority", .{name});
        try hosts.append(init.gpa, .{ .name = name, .authority = authority.Set.fromBits(bits) });
    }
    var inputs: std.ArrayList(Input) = .empty;
    defer {
        for (inputs.items) |input| {
            init.gpa.free(input.dependencies);
            init.gpa.free(input.host_bindings);
        }
        inputs.deinit(init.gpa);
    }
    while (args.next()) |name| {
        var input: Input = .{
            .name = name,
            .source_name = args.next() orelse return fatal("{s}: missing source name", .{name}),
            .source_file = args.next() orelse return fatal("{s}: missing source file", .{name}),
            .pass_a = args.next() orelse return fatal("{s}: missing first compile pass", .{name}),
            .pass_b = args.next() orelse return fatal("{s}: missing second compile pass", .{name}),
            .application_hex = args.next() orelse return fatal("{s}: missing application fingerprint (or -)", .{name}),
        };
        const entrypoint = args.next() orelse return fatal("{s}: missing entrypoint flag", .{name});
        input.entrypoint = if (std.mem.eql(u8, entrypoint, "true")) true else if (std.mem.eql(u8, entrypoint, "false")) false else return fatal("{s}: invalid entrypoint flag (expected true or false)", .{name});
        const count_text = args.next() orelse return fatal("{s}: missing dependency count", .{name});
        const dependency_count = std.fmt.parseInt(usize, count_text, 10) catch return fatal("{s}: invalid dependency count", .{name});
        var dependencies: std.ArrayList([]const u8) = .empty;
        defer dependencies.deinit(init.gpa);
        for (0..dependency_count) |_| {
            const dependency = args.next() orelse return fatal("{s}: missing dependency name", .{name});
            try dependencies.append(init.gpa, dependency);
        }
        input.dependencies = try dependencies.toOwnedSlice(init.gpa);
        var owns_input = true;
        defer if (owns_input) {
            init.gpa.free(input.dependencies);
            init.gpa.free(input.host_bindings);
        };
        const required_text = args.next() orelse return fatal("{s}: missing required authority", .{name});
        input.required_authority = authority.Set.fromBits(std.fmt.parseInt(u16, required_text, 10) catch return fatal("{s}: invalid required authority", .{name}));
        const host_ref_count_text = args.next() orelse return fatal("{s}: missing host reference count", .{name});
        const host_ref_count = std.fmt.parseInt(usize, host_ref_count_text, 10) catch return fatal("{s}: invalid host reference count", .{name});
        var host_refs: std.ArrayList([]const u8) = .empty;
        defer host_refs.deinit(init.gpa);
        for (0..host_ref_count) |_| {
            const host = args.next() orelse return fatal("{s}: missing host reference", .{name});
            try host_refs.append(init.gpa, host);
        }
        input.host_bindings = try host_refs.toOwnedSlice(init.gpa);
        try inputs.append(init.gpa, input);
        owns_input = false;
    }
    var failed_entry: ?[]const u8 = null;
    generate(init.gpa, init.io, std.Io.Dir.cwd(), output_dir, .{ .tier = tier, .hosts = hosts.items }, inputs.items, &failed_entry) catch |err| {
        return fatal("{s}: {s}", .{ failed_entry orelse output_dir, @errorName(err) });
    };
    return 0;
}

fn parseTier(tag: []const u8, allowed_text: []const u8) !gate.Tier {
    const bits = std.fmt.parseInt(u16, allowed_text, 10) catch return error.InvalidAuthorityTier;
    if (bits & ~gate.known.toBits() != 0) return error.UnknownAuthority;
    const tier: gate.Tier = if (std.mem.eql(u8, tag, "worker")) .worker else if (std.mem.eql(u8, tag, "trusted")) .trusted else if (std.mem.eql(u8, tag, "custom")) .{ .custom = authority.Set.fromBits(bits) } else return error.InvalidAuthorityTier;
    if (bits != gate.allowed(tier).toBits()) return error.InvalidAuthorityTier;
    return tier;
}

/// Validate and prepare the entire batch before creating any output. The
/// manifest is renamed into place only after every content file was written.
fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_dir: std.Io.Dir,
    output_path: []const u8,
    declarations: Authority,
    inputs: []const Input,
    failed_entry: *?[]const u8,
) !void {
    failed_entry.* = null;
    const nodes = try allocator.alloc(graph.Node, inputs.len);
    defer allocator.free(nodes);
    for (inputs, nodes) |input, *node| node.* = .{ .name = input.name, .dependencies = input.dependencies };
    var diagnostic: graph.Diagnostic = .none;
    const ordered = graph.order(allocator, nodes, &diagnostic) catch |err| {
        diagnostic.report();
        return err;
    };
    defer allocator.free(ordered);
    const hosts = try allocator.dupe(gate.HostBinding, declarations.hosts);
    defer allocator.free(hosts);
    std.mem.sort(gate.HostBinding, hosts, {}, struct {
        fn lessThan(_: void, lhs: gate.HostBinding, rhs: gate.HostBinding) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);
    const authority_artifacts = try allocator.alloc(gate.Artifact, inputs.len);
    defer allocator.free(authority_artifacts);
    for (ordered, authority_artifacts) |i, *entry| {
        const input = inputs[i];
        entry.* = .{ .name = input.name, .dependencies = input.dependencies, .required_authority = input.required_authority, .host_bindings = input.host_bindings };
    }
    const effective = try allocator.alloc(authority.Set, inputs.len);
    defer allocator.free(effective);
    var authority_failure: gate.Failure = .{};
    gate.validate(declarations.tier, declarations.profile, hosts, authority_artifacts, effective, &authority_failure) catch |err| {
        failed_entry.* = authority_failure.artifact;
        authority_failure.report();
        return err;
    };
    var entries: std.ArrayList(Prepared) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    for (ordered, effective) |i, effective_authority| {
        const input = inputs[i];
        failed_entry.* = input.name;
        try validateIdentity(input.name, input.source_name);
        const source = try input_dir.readFileAlloc(io, input.source_file, allocator, .unlimited);
        defer allocator.free(source);
        const pass_a = try input_dir.readFileAlloc(io, input.pass_a, allocator, .unlimited);
        defer allocator.free(pass_a);
        const pass_b = try input_dir.readFileAlloc(io, input.pass_b, allocator, .unlimited);
        defer allocator.free(pass_b);
        var entry = try prepare(allocator, input, source, pass_a, pass_b);
        errdefer entry.deinit(allocator);
        entry.effective_authority = effective_authority;
        try entries.append(allocator, entry);
    }
    failed_entry.* = null;
    const manifest = try renderManifest(allocator, .{ .tier = declarations.tier, .hosts = hosts, .profile = declarations.profile }, entries.items);
    defer allocator.free(manifest);

    var output_dir = try input_dir.createDirPathOpen(io, output_path, .{});
    defer output_dir.close(io);
    for (entries.items) |entry| {
        failed_entry.* = entry.name;
        var name_buffer: [69]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s}.rite", .{std.fmt.bytesToHex(entry.artifact_hash, .lower)});
        var pending_buffer: [77]u8 = undefined;
        const pending_name = try std.fmt.bufPrint(&pending_buffer, "{s}.pending", .{name});
        errdefer output_dir.deleteFile(io, pending_name) catch {};
        try output_dir.writeFile(io, .{ .sub_path = pending_name, .data = entry.image.encoded });
        try output_dir.rename(pending_name, output_dir, name, io);
    }
    failed_entry.* = null;
    const pending_manifest = "manifest.zig.pending";
    errdefer output_dir.deleteFile(io, pending_manifest) catch {};
    try output_dir.writeFile(io, .{ .sub_path = pending_manifest, .data = manifest });
    try output_dir.rename(pending_manifest, output_dir, "manifest.zig", io);
}

fn validateIdentity(name: []const u8, source_name: []const u8) !void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
    if (source_name.len == 0 or source_name[0] == '-') return error.InvalidSourceName;
    for (source_name) |ch| {
        if (ch < 0x20 or ch == 0x7f or std.mem.indexOfScalar(u8, "\\:<>\"|?*", ch) != null) {
            return error.InvalidSourceName;
        }
    }
    var segments = std.mem.splitScalar(u8, source_name, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or
            std.mem.eql(u8, segment, "..") or segment[segment.len - 1] == '.' or
            segment[segment.len - 1] == ' ')
        {
            return error.InvalidSourceName;
        }
    }
}

fn parseApplication(hex: []const u8) !?artifact.ApplicationFingerprint {
    if (std.mem.eql(u8, hex, "-")) return null;
    if (hex.len != 64) return error.InvalidApplicationFingerprint;
    var value: artifact.ApplicationFingerprint = undefined;
    _ = std.fmt.hexToBytes(&value.bytes, hex) catch return error.InvalidApplicationFingerprint;
    return value;
}

fn prepare(
    allocator: std.mem.Allocator,
    input: Input,
    source: []const u8,
    pass_a: []const u8,
    pass_b: []const u8,
) !Prepared {
    try validateIdentity(input.name, input.source_name);
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidSource;
    const application = try parseApplication(input.application_hex);
    if (!std.mem.eql(u8, pass_a, pass_b)) return error.NonDeterministicCompilation;
    try validateRiteHeaders(pass_a);
    const dependencies = try allocator.dupe([]const u8, input.dependencies);
    errdefer allocator.free(dependencies);
    std.mem.sort([]const u8, dependencies, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    const host_bindings = try allocator.dupe([]const u8, input.host_bindings);
    errdefer allocator.free(host_bindings);
    std.mem.sort([]const u8, host_bindings, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    const image = try artifact.wrapRite(allocator, pass_a, .{
        .compatibility = artifact_config.rite_compatibility_fingerprint,
        .application = application,
        .max_encoded_bytes = std.math.maxInt(usize),
    });
    var result: Prepared = .{
        .name = input.name,
        .source_name = input.source_name,
        .source_hash = undefined,
        .artifact_hash = undefined,
        .application = application,
        .entrypoint = input.entrypoint,
        .dependencies = dependencies,
        .required_authority = input.required_authority,
        .host_bindings = host_bindings,
        .image = image,
    };
    Sha256.hash(source, &result.source_hash, .{});
    Sha256.hash(image.encoded, &result.artifact_hash, .{});
    return result;
}

/// Check upstream 4.0's file and section framing, without decoding bytecode.
/// The host mrbc is the trusted producer; the ordinary runtime admission path
/// remains responsible for loading every generated image.
fn validateRiteHeaders(bytes: []const u8) !void {
    try artifact.validateRawRite(bytes);
    if (bytes.len < 40 or !std.mem.eql(u8, bytes[12..20], "MATZ0000")) return error.InvalidArtifact;
    var offset: usize = 20;
    var found_irep = false;
    while (offset < bytes.len) {
        if (bytes.len - offset < 8) return error.InvalidArtifact;
        const tag = bytes[offset..][0..4];
        const size = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .big);
        if (size < 8 or size > bytes.len - offset) return error.InvalidArtifact;
        if (std.mem.eql(u8, tag, "END\x00")) {
            if (!found_irep or size != 8 or offset + size != bytes.len) return error.InvalidArtifact;
            return;
        }
        if (std.mem.eql(u8, tag, "IREP")) {
            if (found_irep or offset != 20 or size < 12) return error.InvalidArtifact;
            if (!std.mem.eql(u8, bytes[offset + 8 ..][0..4], artifact_config.rite_vm_version)) {
                return error.UnsupportedRiteVmVersion;
            }
            found_irep = true;
        } else if (!found_irep or (!std.mem.eql(u8, tag, "DBG\x00") and !std.mem.eql(u8, tag, "LVAR"))) {
            return error.InvalidArtifact;
        }
        offset += size;
    }
    return error.InvalidArtifact;
}

fn renderManifest(allocator: std.mem.Allocator, declarations: Authority, entries: []const Prepared) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll(
        \\//! Generated CodeDB manifest; do not edit.
        \\pub const format_major: u16 = 1;
        \\pub const format_minor: u16 = 2;
        \\pub const compatibility: [32]u8 =
    );
    try writeDigest(writer, artifact_config.rite_compatibility_fingerprint);
    try writer.print(";\npub const gem_set: []const u8 = \"{f}\";\npub const gems: []const []const u8 = &.{{\n", .{std.zig.fmtString(features.gem_set)});
    for (features.gems) |gem| try writer.print("    \"{f}\",\n", .{std.zig.fmtString(gem)});
    try writer.writeAll("};\n");
    try writer.print("pub const authority_tier: []const u8 = \"{s}\";\npub const authority_allowed: u16 = {d};\n", .{ @tagName(declarations.tier), gate.allowed(declarations.tier).toBits() });
    try writer.writeAll(
        \\pub const AuthoritySource = struct {
        \\    name: []const u8,
        \\    bits: u16,
        \\};
        \\
    );
    try writeAuthoritySources(writer, "authority_profile", declarations.profile);
    try writeAuthoritySources(writer, "host_bindings", declarations.hosts);
    try writer.writeAll(
        \\pub const Entry = struct {
        \\    name: []const u8,
        \\    bytes: []const u8,
        \\    source_name: []const u8,
        \\    source_hash: [32]u8,
        \\    artifact_hash: [32]u8,
        \\    application: ?[32]u8,
        \\    entrypoint: bool,
        \\    dependencies: []const []const u8,
        \\    required_authority: u16,
        \\    host_bindings: []const []const u8,
        \\    effective_authority: u16,
        \\};
        \\pub const entries = [_]Entry{
        \\
    );
    for (entries) |entry| {
        try writer.print("    .{{ .name = \"{f}\", .bytes = @embedFile(\"{s}.rite\"), .source_name = \"{f}\", .source_hash = ", .{
            std.zig.fmtString(entry.name),
            std.fmt.bytesToHex(entry.artifact_hash, .lower),
            std.zig.fmtString(entry.source_name),
        });
        try writeDigest(writer, entry.source_hash);
        try writer.writeAll(", .artifact_hash = ");
        try writeDigest(writer, entry.artifact_hash);
        try writer.writeAll(", .application = ");
        if (entry.application) |application| {
            try writeDigest(writer, application.bytes);
        } else {
            try writer.writeAll("null");
        }
        try writer.print(", .entrypoint = {}, .dependencies = &.{{", .{entry.entrypoint});
        for (entry.dependencies, 0..) |dependency, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("\"{f}\"", .{std.zig.fmtString(dependency)});
        }
        try writer.print("}}, .required_authority = {d}, .host_bindings = &.{{", .{entry.required_authority.toBits()});
        for (entry.host_bindings, 0..) |host, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("\"{f}\"", .{std.zig.fmtString(host)});
        }
        try writer.print("}}, .effective_authority = {d} }},\n", .{entry.effective_authority.toBits()});
    }
    try writer.writeAll("};\n");
    return output.toOwnedSlice();
}

fn writeAuthoritySources(writer: *std.Io.Writer, name: []const u8, sources: []const authority.Source) !void {
    try writer.print("pub const {s}: []const AuthoritySource = &.{{\n", .{name});
    for (sources) |source| {
        try writer.print("    .{{ .name = \"{f}\", .bits = {d} }},\n", .{ std.zig.fmtString(source.name), source.authority.toBits() });
    }
    try writer.writeAll("};\n");
}

fn writeDigest(writer: *std.Io.Writer, digest: [32]u8) !void {
    try writer.writeAll(".{");
    for (digest, 0..) |byte, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("0x{x:0>2}", .{byte});
    }
    try writer.writeByte('}');
}

fn fatal(comptime fmt: []const u8, values: anytype) u8 {
    std.debug.print("rite_envelope: " ++ fmt ++ "\n", values);
    return 1;
}

const test_input: Input = .{
    .name = "unit",
    .source_name = "app/unit.rb",
    .source_file = "source.rb",
    .pass_a = "a.mrb",
    .pass_b = "b.mrb",
    .application_hex = "-",
};

// Deliberately includes only section framing: this tool does not interpret
// IREP bodies. Real mrbc images are exercised by the build integration tests.
fn testRite() [40]u8 {
    var bytes: [40]u8 = @splat(0);
    @memcpy(bytes[0..8], "RITE0400");
    std.mem.writeInt(u32, bytes[8..12], bytes.len, .big);
    @memcpy(bytes[12..20], "MATZ0000");
    @memcpy(bytes[20..24], "IREP");
    std.mem.writeInt(u32, bytes[24..28], 12, .big);
    @memcpy(bytes[28..32], artifact_config.rite_vm_version);
    @memcpy(bytes[32..36], "END\x00");
    std.mem.writeInt(u32, bytes[36..40], 8, .big);
    return bytes;
}

test "logical names remain data and source paths are portable" {
    for ([_][]const u8{ "", "has\x00nul" }) |name| {
        try std.testing.expectError(error.InvalidName, validateIdentity(name, "valid.rb"));
    }
    for ([_][]const u8{ "", "/abs.rb", "-flag.rb", "a//b.rb", "./a.rb", "a/../b.rb", "a\\b.rb", "C:bad.rb", "a\n.rb", "bad\x7f.rb", "a/", "a./b.rb", "a /b.rb", "a\".rb", "a*.rb", "a?.rb", "a<.rb", "a>.rb", "a|.rb" }) |path| {
        try std.testing.expectError(error.InvalidSourceName, validateIdentity("unit", path));
    }
    try validateIdentity("arbitrary/\"logical\\name\n", "app/my unit.rb");
}

test "compile pairs, source bytes and application fingerprints fail closed" {
    const allocator = std.testing.allocator;
    const bytes = testRite();
    var changed = bytes;
    changed[30] ^= 1;
    try std.testing.expectError(error.NonDeterministicCompilation, prepare(allocator, test_input, "1", &bytes, &changed));
    try std.testing.expectError(error.InvalidSource, prepare(allocator, test_input, "1\x002", &bytes, &bytes));
    const invalid_hex: [64]u8 = @splat('g');
    const short_hex: [63]u8 = @splat('0');
    const long_hex: [65]u8 = @splat('0');
    for ([_][]const u8{ "", "00", &invalid_hex, &short_hex, &long_hex }) |application_hex| {
        var input = test_input;
        input.application_hex = application_hex;
        try std.testing.expectError(error.InvalidApplicationFingerprint, prepare(allocator, input, "1", &bytes, &bytes));
    }
}

test "raw RITE file and section headers are checked" {
    const valid = testRite();
    try validateRiteHeaders(&valid);
    const bad_offsets = [_]usize{ 0, 4, 8, 12, 20, 24, 32, 36 };
    for (bad_offsets) |offset| {
        var invalid = valid;
        invalid[offset] ^= 1;
        try std.testing.expectError(error.InvalidArtifact, validateRiteHeaders(&invalid));
    }
    var wrong_vm = valid;
    wrong_vm[28] ^= 1;
    try std.testing.expectError(error.UnsupportedRiteVmVersion, validateRiteHeaders(&wrong_vm));
    for (0..valid.len) |length| {
        try std.testing.expectError(error.InvalidArtifact, validateRiteHeaders(valid[0..length]));
    }
}

test "envelopes bind application identity and content hashes are deterministic" {
    const allocator = std.testing.allocator;
    const bytes = testRite();
    var first = try prepare(allocator, test_input, "answer = 42\n", &bytes, &bytes);
    defer first.deinit(allocator);
    var again = try prepare(allocator, test_input, "answer = 42\n", &bytes, &bytes);
    defer again.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.image.encoded, again.image.encoded);
    var graph_input = test_input;
    graph_input.entrypoint = false;
    graph_input.dependencies = &.{"library"};
    var graph_entry = try prepare(allocator, graph_input, "answer = 42\n", &bytes, &bytes);
    defer graph_entry.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.image.encoded, graph_entry.image.encoded);
    try std.testing.expectEqualSlices(u8, &first.artifact_hash, &graph_entry.artifact_hash);
    var expected_hash: [32]u8 = undefined;
    Sha256.hash("answer = 42\n", &expected_hash, .{});
    try std.testing.expectEqualSlices(u8, &expected_hash, &first.source_hash);
    Sha256.hash(first.image.encoded, &expected_hash, .{});
    try std.testing.expectEqualSlices(u8, &expected_hash, &first.artifact_hash);
    const payload = try artifact.validateRite(first.image.view(), .{ .compatibility = artifact_config.rite_compatibility_fingerprint });
    try std.testing.expectEqualSlices(u8, &bytes, payload.bytes);
    var bound_input = test_input;
    const application_bytes: [32]u8 = @splat(0xa1);
    const application_hex = std.fmt.bytesToHex(application_bytes, .upper);
    bound_input.application_hex = &application_hex;
    var bound = try prepare(allocator, bound_input, "answer = 42\n", &bytes, &bytes);
    defer bound.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, &first.artifact_hash, &bound.artifact_hash));
    try std.testing.expectEqualSlices(u8, &application_bytes, &bound.application.?.bytes);
    try std.testing.expectError(error.IncompatibleRiteImage, artifact.validateRite(bound.image.view(), .{ .compatibility = artifact_config.rite_compatibility_fingerprint }));
    _ = try artifact.validateRite(bound.image.view(), .{ .compatibility = artifact_config.rite_compatibility_fingerprint, .application = bound.application });
}

test "manifest escapes names, records identity, and uses content filenames" {
    const allocator = std.testing.allocator;
    const bytes = testRite();
    var input = test_input;
    input.name = "quoted\"\\\n";
    input.dependencies = &.{"dependency\"\\\n"};
    input.host_bindings = &.{"host\"\\\n"};
    var entry = try prepare(allocator, input, "1", &bytes, &bytes);
    defer entry.deinit(allocator);
    const manifest = try renderManifest(allocator, .{}, &.{entry});
    defer allocator.free(manifest);
    const marker = try std.fmt.allocPrint(allocator, "@embedFile(\"{s}.rite\")", .{std.fmt.bytesToHex(entry.artifact_hash, .lower)});
    defer allocator.free(marker);
    try std.testing.expect(std.mem.indexOf(u8, manifest, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".name = \"quoted\\\"\\\\\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "pub const format_major: u16 = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "pub const format_minor: u16 = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "pub const authority_tier: []const u8 = \"worker\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "pub const authority_profile: []const AuthoritySource") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".source_name = \"app/unit.rb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".application = null") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".entrypoint = true, .dependencies = &.{\"dependency\\\"\\\\\\n\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".host_bindings = &.{\"host\\\"\\\\\\n\"}") != null);
    const terminated = try allocator.allocSentinel(u8, manifest.len, 0);
    defer allocator.free(terminated);
    @memcpy(terminated, manifest);
    var ast = try std.zig.Ast.parse(allocator, terminated, .{});
    defer ast.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "batch validation publishes no partial manifest and preserves prior output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = testRite();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.rb", .data = "1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.mrb", .data = &bytes });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.mrb", .data = &bytes });
    var failure: ?[]const u8 = null;
    try std.testing.expectError(error.EmptyCodeDB, generate(allocator, io, tmp.dir, "empty", .{}, &.{}, &failure));
    try std.testing.expectError(error.DuplicateArtifactName, generate(allocator, io, tmp.dir, "duplicate", .{}, &.{ test_input, test_input }, &failure));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "duplicate", .{}));
    var bad = test_input;
    bad.name = "bad";
    bad.application_hex = "invalid";
    try std.testing.expectError(error.InvalidApplicationFingerprint, generate(allocator, io, tmp.dir, "bad", .{}, &.{ test_input, bad }, &failure));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "bad", .{}));
    try generate(allocator, io, tmp.dir, "good", .{}, &.{test_input}, &failure);
    const before = try tmp.dir.readFileAlloc(io, "good/manifest.zig", allocator, .unlimited);
    defer allocator.free(before);
    try std.testing.expectError(error.InvalidApplicationFingerprint, generate(allocator, io, tmp.dir, "good", .{}, &.{bad}, &failure));
    const after = try tmp.dir.readFileAlloc(io, "good/manifest.zig", allocator, .unlimited);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    var entry = try prepare(allocator, test_input, "1", &bytes, &bytes);
    defer entry.deinit(allocator);
    const content_path = try std.fmt.allocPrint(allocator, "good/{s}.rite", .{std.fmt.bytesToHex(entry.artifact_hash, .lower)});
    defer allocator.free(content_path);
    const published = try tmp.dir.readFileAlloc(io, content_path, allocator, .unlimited);
    defer allocator.free(published);
    try std.testing.expectEqualSlices(u8, entry.image.encoded, published);
}

test "graph errors fail before reading compile outputs or publishing files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var failure: ?[]const u8 = null;
    var dependent = test_input;
    dependent.dependencies = &.{"missing"};
    try std.testing.expectError(error.MissingArtifactDependency, generate(allocator, io, tmp.dir, "missing", .{}, &.{dependent}, &failure));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "missing", .{}));
    var library = test_input;
    library.name = "library";
    library.entrypoint = false;
    dependent.dependencies = &.{ "library", "library" };
    try std.testing.expectError(error.DuplicateArtifactDependency, generate(allocator, io, tmp.dir, "duplicate", .{}, &.{ dependent, library }, &failure));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "duplicate", .{}));
    dependent.dependencies = &.{"library"};
    library.dependencies = &.{dependent.name};
    try std.testing.expectError(error.ArtifactDependencyCycle, generate(allocator, io, tmp.dir, "cycle", .{}, &.{ dependent, library }, &failure));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "cycle", .{}));
}

test "manifest bytes canonicalize module and dependency declaration order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = testRite();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.rb", .data = "1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.mrb", .data = &bytes });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.mrb", .data = &bytes });
    var common = test_input;
    common.name = "common";
    common.entrypoint = false;
    common.required_authority = authority.Set.init(&.{.entropy});
    var alpha = common;
    alpha.name = "alpha";
    alpha.dependencies = &.{common.name};
    var beta = alpha;
    beta.name = "beta";
    var entry = test_input;
    entry.name = "invoke";
    entry.dependencies = &.{ beta.name, alpha.name };
    entry.required_authority = authority.Set.init(&.{.clock});
    entry.host_bindings = &.{ "second", "first" };
    const hosts = [_]gate.HostBinding{
        .{ .name = "second", .authority = authority.Set.init(&.{.dynamic_code}) },
        .{ .name = "first", .authority = authority.Set.init(&.{.introspection}) },
    };
    var failure: ?[]const u8 = null;
    try generate(allocator, io, tmp.dir, "first", .{ .profile = &.{}, .hosts = &hosts }, &.{ entry, beta, common, alpha }, &failure);
    entry.dependencies = &.{ alpha.name, beta.name };
    entry.host_bindings = &.{ "first", "second" };
    try generate(allocator, io, tmp.dir, "shuffled", .{ .profile = &.{}, .hosts = &.{ hosts[1], hosts[0] } }, &.{ alpha, common, beta, entry }, &failure);
    const first = try tmp.dir.readFileAlloc(io, "first/manifest.zig", allocator, .unlimited);
    defer allocator.free(first);
    const shuffled = try tmp.dir.readFileAlloc(io, "shuffled/manifest.zig", allocator, .unlimited);
    defer allocator.free(shuffled);
    try std.testing.expectEqualSlices(u8, first, shuffled);
    var offset: usize = 0;
    for ([_][]const u8{ common.name, alpha.name, beta.name, entry.name }) |name| {
        const marker = try std.fmt.allocPrint(allocator, ".name = \"{s}\"", .{name});
        defer allocator.free(marker);
        const position = std.mem.indexOfPos(u8, first, offset, marker) orelse return error.TestExpectedModule;
        offset = position + marker.len;
    }
    try std.testing.expect(std.mem.indexOf(u8, first, ".entrypoint = false, .dependencies = &.{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, ".entrypoint = true, .dependencies = &.{\"alpha\", \"beta\"}") != null);
    const transitive = authority.Set.init(&.{ .entropy, .clock, .dynamic_code, .introspection });
    const metadata = try std.fmt.allocPrint(allocator, ".required_authority = {d}, .host_bindings = &.{{\"first\", \"second\"}}, .effective_authority = {d}", .{ entry.required_authority.toBits(), transitive.toBits() });
    defer allocator.free(metadata);
    try std.testing.expect(std.mem.indexOf(u8, first, metadata) != null);
}

test "authority tier wire format rejects unknown bits and changed canonical masks" {
    var buffer: [16]u8 = undefined;
    const worker = try std.fmt.bufPrint(&buffer, "{d}", .{gate.allowed(.worker).toBits()});
    try std.testing.expectEqual(gate.Tier.worker, try parseTier("worker", worker));
    const trusted = try std.fmt.bufPrint(&buffer, "{d}", .{gate.allowed(.trusted).toBits()});
    try std.testing.expectEqual(gate.Tier.trusted, try parseTier("trusted", trusted));
    try std.testing.expectEqual(gate.Tier{ .custom = .empty }, try parseTier("custom", "0"));
    for ([_][]const u8{ "worker", "trusted" }) |tier| {
        try std.testing.expectError(error.InvalidAuthorityTier, parseTier(tier, "0"));
        try std.testing.expectError(error.UnknownAuthority, parseTier(tier, "32768"));
    }
    try std.testing.expectError(error.InvalidAuthorityTier, parseTier("unknown", "0"));
    try std.testing.expectError(error.InvalidAuthorityTier, parseTier("worker", "65536"));
    try std.testing.expectError(error.InvalidAuthorityTier, parseTier("custom", "invalid"));
    try std.testing.expectError(error.UnknownAuthority, parseTier("custom", "32768"));
}

test "authority checks reject unused hosts, linked profile, and undeclared references before output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Constant-only Ruby does not reduce the linked VM's ambient authority.
    try tmp.dir.writeFile(io, .{ .sub_path = "source.rb", .data = "1" });
    const dangerous = &[_]gate.HostBinding{.{ .name = "unused-files", .authority = authority.Set.init(&.{.filesystem}) }};
    var failure: ?[]const u8 = null;
    try std.testing.expectError(error.ForbiddenAuthority, generate(allocator, io, tmp.dir, "host", .{ .hosts = dangerous }, &.{test_input}, &failure));
    try std.testing.expectEqualStrings(test_input.name, failure.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "host", .{}));
    try std.testing.expectError(error.ForbiddenAuthority, generate(allocator, io, tmp.dir, "profile", .{ .profile = dangerous }, &.{test_input}, &failure));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "profile", .{}));
    try std.testing.expectError(error.ForbiddenAuthority, generate(allocator, io, tmp.dir, "linked", .{ .tier = .{ .custom = .empty } }, &.{test_input}, &failure));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "linked", .{}));
    var missing = test_input;
    missing.host_bindings = &.{"missing"};
    try std.testing.expectError(error.MissingHostBinding, generate(allocator, io, tmp.dir, "missing", .{}, &.{missing}, &failure));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "missing", .{}));
    var unknown = test_input;
    unknown.required_authority = authority.Set.fromBits(32768);
    try std.testing.expectError(error.UnknownAuthority, generate(allocator, io, tmp.dir, "unknown", .{ .tier = .trusted }, &.{unknown}, &failure));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "unknown", .{}));
}

test "trusted and custom gates publish explicit authority and failed changes preserve output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = testRite();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.rb", .data = "1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.mrb", .data = &bytes });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.mrb", .data = &bytes });
    const network = authority.Set.init(&.{.network});
    const hosts = &[_]gate.HostBinding{.{ .name = "network\"host", .authority = network }};
    var failure: ?[]const u8 = null;
    try generate(allocator, io, tmp.dir, "trusted", .{ .tier = .trusted, .hosts = hosts, .profile = &.{} }, &.{test_input}, &failure);
    try generate(allocator, io, tmp.dir, "custom", .{ .tier = .{ .custom = network }, .hosts = hosts, .profile = &.{} }, &.{test_input}, &failure);
    const before = try tmp.dir.readFileAlloc(io, "custom/manifest.zig", allocator, .unlimited);
    defer allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "pub const authority_tier: []const u8 = \"custom\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, "pub const authority_allowed: u16 = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, ".name = \"network\\\"host\", .bits = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, ".required_authority = 0, .host_bindings = &.{}, .effective_authority = 2") != null);
    try std.testing.expectError(error.ForbiddenAuthority, generate(allocator, io, tmp.dir, "custom", .{ .hosts = hosts, .profile = &.{} }, &.{test_input}, &failure));
    const after = try tmp.dir.readFileAlloc(io, "custom/manifest.zig", allocator, .unlimited);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

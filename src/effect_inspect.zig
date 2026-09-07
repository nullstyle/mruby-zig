//! Inert receipt inspection: validates framing, checksums and every value graph.
//! It never executes Ruby, loads application code, invokes an adapter, or proves
//! a receipt's provenance, business authorization, replay result, or commit.
const std = @import("std");
const artifact = @import("artifact.zig");
const data = @import("effect_data.zig");
const trace_format = @import("effect_trace.zig");
const receipt_format = @import("turn_receipt.zig");

pub const Limits = struct {
    max_receipt_bytes: usize = 8 * 1024 * 1024,
    max_trace_bytes: usize = 8 * 1024 * 1024,
    max_capsule_bytes: usize = 1024 * 1024,
    max_operations: usize = 256,
    max_name_bytes: usize = 256,
    max_total_nodes: usize = 65_536,
    max_total_edges: usize = 262_144,
    max_output_bytes: usize = 256 * 1024,
    max_preview_bytes: usize = 64,
    max_preview_items: usize = 4,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    output: []u8,
    operation_count: usize,
    identity: trace_format.Identity,
    terminal_sha256: [32]u8,

    /// Deterministic ASCII JSON, including a final newline. Arbitrary byte
    /// strings use one JSON character per byte (non-ASCII becomes \u00xx).
    pub fn json(self: *const Report) []const u8 {
        return self.output;
    }

    pub fn deinit(self: *Report) void {
        self.allocator.free(self.output);
        self.* = undefined;
    }
};

/// Produces an owned report only after all layers and every argument/outcome
/// capsule have passed admission. On failure there is no partial report.
/// The output contains shallow previews, not a recursive dump of guest data.
pub fn inspect(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !Report {
    const receipt = try receipt_format.decode(bytes, .{
        .max_encoded_bytes = limits.max_receipt_bytes,
        .max_trace_bytes = limits.max_trace_bytes,
        .max_terminal_bytes = limits.max_capsule_bytes,
    });
    var trace = try trace_format.Trace.decode(allocator, receipt.trace, .{
        .max_records = limits.max_operations,
        .max_bytes = limits.max_trace_bytes,
        .max_request_bytes = limits.max_capsule_bytes,
        .max_result_bytes = limits.max_capsule_bytes,
    });
    defer trace.deinit();
    var output: Output = .{ .allocator = allocator, .limits = limits };
    defer output.bytes.deinit(allocator);
    var budget: GraphBudget = .{ .nodes = limits.max_total_nodes, .edges = limits.max_total_edges };
    var terminal = try decode(allocator, receipt.terminal, limits, &budget);
    defer terminal.deinit();
    if (terminal.root().kind() != .array or try terminal.root().len() != 2) return error.InvalidTurnResult;

    try output.add("{\"format\":\"mruby-effects-inspection/v1\",\"verification\":\"structure-and-checksums-only\",\"byte_text_encoding\":\"u00xx-per-byte\",\"receipt_bytes\":");
    try output.number(bytes.len);
    try output.add(",\"receipt_sha256\":");
    try output.digest(hash(bytes));
    try output.add(",\"trace_bytes\":");
    try output.number(receipt.trace.len);
    try output.add(",\"trace_sha256\":");
    try output.digest(hash(receipt.trace));
    try output.add(",\"identity\":{\"code\":");
    try output.digest(trace.identity.code);
    try output.add(",\"catalogue\":");
    try output.digest(trace.identity.catalogue);
    try output.add(",\"input\":");
    try output.digest(trace.identity.input);
    try output.add("},\"operation_count\":");
    try output.number(trace.len());
    try output.add(",\"operations\":[");
    for (0..trace.len()) |sequence| {
        const record = trace.get(sequence).?;
        if (record.name.len > limits.max_name_bytes) return error.InspectionLimitExceeded;
        var arguments = try decode(allocator, .{ .bytes = record.arguments }, limits, &budget);
        defer arguments.deinit();
        if (arguments.root().kind() != .array) return error.InvalidEffectArguments;
        var result = try decode(allocator, .{ .bytes = record.result }, limits, &budget);
        defer result.deinit();
        if (record.outcome == .rejected) {
            if (result.root().kind() != .array or try result.root().len() != 2 or
                (try result.root().at(0)).kind() != .string or (try result.root().at(1)).kind() != .string)
                return error.InvalidEffectRejection;
        }
        if (sequence != 0) try output.add(",");
        try output.add("{\"sequence\":");
        try output.number(sequence);
        try output.add(",\"name_bytes\":");
        try output.string(record.name);
        try output.add(",\"version\":");
        try output.number(record.version);
        try output.add(",\"outcome\":");
        try output.string(@tagName(record.outcome));
        try output.add(",\"arguments\":");
        try output.capsule(&arguments);
        try output.add(",\"result\":");
        try output.capsule(&result);
        if (record.outcome == .rejected) {
            try output.add(",\"rejection_code\":");
            try output.describe(try result.root().at(0), false);
        }
        try output.add("}");
    }
    const terminal_digest = hash(receipt.terminal.bytes);
    try output.add("],\"terminal\":");
    try output.capsule(&terminal);
    try output.add(",\"result\":");
    try output.describe(try terminal.root().at(0), true);
    try output.add(",\"state\":");
    try output.describe(try terminal.root().at(1), true);
    try output.add("}\n");
    return .{
        .allocator = allocator,
        .output = try output.bytes.toOwnedSlice(allocator),
        .operation_count = trace.len(),
        .identity = trace.identity,
        .terminal_sha256 = terminal_digest,
    };
}

const GraphBudget = struct { nodes: usize, edges: usize };
fn decode(allocator: std.mem.Allocator, view: artifact.StateCapsuleView, limits: Limits, budget: *GraphBudget) !data.Document {
    // Admit advertised graph counts before allocation. Document then verifies
    // those counts and applies the shared depth and Hash work ceilings.
    const payload = try artifact.validateState(view, .{ .max_encoded_bytes = limits.max_capsule_bytes });
    var reader = artifact.Reader.init(payload.bytes);
    const prelude = try artifact.readStatePrelude(&reader);
    if (prelude.node_count > budget.nodes or prelude.edge_count > budget.edges) return error.InspectionLimitExceeded;
    var doc = try data.Document.decode(allocator, view, limits.max_capsule_bytes);
    errdefer doc.deinit();
    if (doc.graph.nodes.len > budget.nodes or doc.graph.edges.len > budget.edges) return error.InspectionLimitExceeded;
    budget.nodes -= doc.graph.nodes.len;
    budget.edges -= doc.graph.edges.len;
    return doc;
}

fn hash(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

const Output = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    bytes: std.ArrayList(u8) = .empty,

    fn add(self: *Output, bytes: []const u8) !void {
        if (bytes.len > self.limits.max_output_bytes -| self.bytes.items.len) return error.InspectionOutputLimitExceeded;
        try self.bytes.appendSlice(self.allocator, bytes);
    }
    fn number(self: *Output, n: anytype) !void {
        var buffer: [32]u8 = undefined;
        try self.add(try std.fmt.bufPrint(&buffer, "{d}", .{n}));
    }
    fn boolean(self: *Output, value: bool) !void {
        try self.add(if (value) "true" else "false");
    }
    fn digest(self: *Output, value: [32]u8) !void {
        try self.string(&std.fmt.bytesToHex(value, .lower));
    }
    fn string(self: *Output, bytes: []const u8) !void {
        const hex = "0123456789abcdef";
        try self.add("\"");
        for (bytes) |byte| switch (byte) {
            '"' => try self.add("\\\""),
            '\\' => try self.add("\\\\"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try self.add(&.{byte}),
            else => try self.add(&.{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 15] }),
        };
        try self.add("\"");
    }
    fn preview(self: *Output, bytes: []const u8) !void {
        const n = @min(bytes.len, self.limits.max_preview_bytes);
        try self.add(",\"byte_length\":");
        try self.number(bytes.len);
        try self.add(",\"preview_bytes\":");
        try self.string(bytes[0..n]);
        try self.add(",\"truncated\":");
        try self.boolean(n != bytes.len);
    }
    fn capsule(self: *Output, doc: *const data.Document) !void {
        try self.add("{\"encoded_bytes\":");
        try self.number(doc.view().bytes.len);
        try self.add(",\"sha256\":");
        try self.digest(hash(doc.view().bytes));
        try self.add(",\"nodes\":");
        try self.number(doc.graph.nodes.len);
        try self.add(",\"edges\":");
        try self.number(doc.graph.edges.len);
        try self.add(",\"root\":");
        try self.describe(doc.root(), false);
        try self.add("}");
    }
    fn describe(self: *Output, ref: data.Ref, expand: bool) anyerror!void {
        try self.add("{\"kind\":");
        try self.string(@tagName(ref.kind()));
        if (ref.nodeId()) |id| {
            try self.add(",\"node_id\":");
            try self.number(id);
            try self.add(",\"frozen\":");
            try self.boolean(ref.isFrozen());
        }
        switch (ref.kind()) {
            .nil => {},
            .boolean => {
                try self.add(",\"value\":");
                try self.boolean(try ref.asBoolean());
            },
            .integer => {
                try self.add(",\"value\":");
                try self.number(try ref.asInteger());
            },
            .float => {
                // Bits preserve signed zero and non-finite values in JSON.
                var buffer: [8]u8 = undefined;
                std.mem.writeInt(u64, &buffer, @bitCast(try ref.asFloat()), .big);
                try self.add(",\"ieee754_bits\":");
                try self.string(&std.fmt.bytesToHex(buffer, .lower));
            },
            .symbol => try self.preview(try ref.asSymbol()),
            .string => try self.preview(try ref.asString()),
            .array, .hash => {
                const count = try ref.len();
                try self.add(",\"length\":");
                try self.number(count);
                if (expand) {
                    const n = @min(count, self.limits.max_preview_items);
                    try self.add(if (ref.kind() == .array) ",\"items\":[" else ",\"entries\":[");
                    for (0..n) |index| {
                        if (index != 0) try self.add(",");
                        if (ref.kind() == .array) {
                            try self.describe(try ref.at(index), false);
                        } else {
                            const pair = try ref.pair(index);
                            try self.add("{\"key\":");
                            try self.describe(pair.key, false);
                            try self.add(",\"value\":");
                            try self.describe(pair.value, false);
                            try self.add("}");
                        }
                    }
                    try self.add("],\"truncated\":");
                    try self.boolean(n != count);
                    if (ref.kind() == .hash) {
                        if (try ref.default()) |value| {
                            try self.add(",\"default\":");
                            try self.describe(value, false);
                        }
                    }
                }
            },
        }
        try self.add("}");
    }
};

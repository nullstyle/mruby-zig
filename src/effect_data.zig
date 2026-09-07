//! Data-only effect adapters. These helpers never access a Ruby VM. Capsules
//! use the existing inert graph validator, including its canonical form and
//! allocation/work limits. A Document owns its bytes; its Refs borrow it.
const std = @import("std");
const artifact = @import("artifact.zig");
const codec = @import("artifact_value.zig");
const c = @import("c.zig");

pub const Outcome = union(enum) {
    returned: artifact.StateCapsule,
    rejected: artifact.StateCapsule,
};

/// A convenient borrowed tree for constructing results. Hash String keys are
/// frozen automatically. Use clone for an existing capsule with aliases or
/// cycles; this tree encoder creates a new node for each container occurrence.
pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    symbol: []const u8,
    array: []const Value,
    hash: []const Pair,
};
pub const Pair = struct { key: Value, value: Value };

pub fn limits(max_bytes: usize) artifact.CapsuleLimits {
    return .{
        .max_encoded_bytes = max_bytes,
        .max_nodes = @min(max_bytes, 16_384),
        .max_total_edges = @min(max_bytes, 65_536),
        .max_depth = 64,
        .max_string_bytes = max_bytes,
        .max_symbol_bytes = max_bytes,
    };
}

pub fn reject(allocator: std.mem.Allocator, code: []const u8, message: []const u8, max_bytes: usize) !Outcome {
    return .{ .rejected = try encode(allocator, .{ .array = &.{ .{ .string = code }, .{ .string = message } } }, max_bytes) };
}

/// Validate and copy a complete capsule, preserving aliases, cycles, frozen
/// flags, and Hash defaults. The caller owns the returned bytes.
pub fn clone(allocator: std.mem.Allocator, view: artifact.StateCapsuleView, max_bytes: usize) !artifact.StateCapsule {
    var graph = try codec.parse(allocator, view, .{ .limits = limits(max_bytes) }, null);
    defer graph.deinit(allocator);
    return .{ .encoded = try allocator.dupe(u8, view.bytes) };
}

pub const Document = struct {
    allocator: std.mem.Allocator,
    capsule: artifact.StateCapsule,
    graph: codec.ParsedGraph,

    pub fn decode(allocator: std.mem.Allocator, input: artifact.StateCapsuleView, max_bytes: usize) !Document {
        return decodeWithLimits(allocator, input, limits(max_bytes));
    }

    /// Apply the caller's tighter graph policy while retaining data codec caps.
    pub fn decodeWithLimits(allocator: std.mem.Allocator, input: artifact.StateCapsuleView, policy: artifact.CapsuleLimits) !Document {
        return decodeWithOptions(allocator, input, .{ .limits = policy });
    }

    pub const DecodeOptions = struct {
        limits: artifact.CapsuleLimits,
        allow_float: bool = true,
    };

    /// Structural data utilities preserve the capsule format. Execution callers
    /// additionally supply their runtime's non-relaxable numeric restriction.
    pub fn decodeWithOptions(allocator: std.mem.Allocator, input: artifact.StateCapsuleView, options: DecodeOptions) !Document {
        const bounds = options.limits.tightened(limits(options.limits.max_encoded_bytes));
        // Bound the copy before allocation; graph validation is still required.
        if (input.bytes.len > bounds.max_encoded_bytes) return error.ArtifactLimitExceeded;
        var capsule: artifact.StateCapsule = .{ .encoded = try allocator.dupe(u8, input.bytes) };
        errdefer capsule.deinit(allocator);
        return .{
            .allocator = allocator,
            .capsule = capsule,
            .graph = try codec.parse(allocator, capsule.view(), .{ .limits = bounds, .allow_float = options.allow_float }, null),
        };
    }

    pub fn deinit(self: *Document) void {
        self.graph.deinit(self.allocator);
        self.capsule.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn root(self: *const Document) Ref {
        return .{ .document = self, .reference = self.graph.root };
    }

    pub fn view(self: *const Document) artifact.StateCapsuleView {
        return self.capsule.view();
    }
};

pub const Kind = enum { nil, boolean, integer, float, symbol, string, array, hash };
pub const ReadError = error{ TypeMismatch, IndexOutOfBounds };

pub const Ref = struct {
    document: *const Document,
    reference: c.mrz_artifact_ref,

    pub fn kind(self: Ref) Kind {
        return switch (self.reference.tag) {
            c.MRZ_ARTIFACT_REF_NIL => .nil,
            c.MRZ_ARTIFACT_REF_FALSE, c.MRZ_ARTIFACT_REF_TRUE => .boolean,
            c.MRZ_ARTIFACT_REF_I64 => .integer,
            c.MRZ_ARTIFACT_REF_F64 => .float,
            c.MRZ_ARTIFACT_REF_SYMBOL => .symbol,
            c.MRZ_ARTIFACT_REF_NODE => switch (self.node().kind) {
                c.MRZ_ARTIFACT_NODE_STRING => .string,
                c.MRZ_ARTIFACT_NODE_ARRAY => .array,
                c.MRZ_ARTIFACT_NODE_HASH => .hash,
                else => unreachable,
            },
            else => unreachable,
        };
    }

    /// Document-local graph identity, useful for cycle/alias-aware traversal.
    /// It is an encoded node number, never a Ruby object or process address.
    pub fn nodeId(self: Ref) ?u32 {
        return if (self.reference.tag == c.MRZ_ARTIFACT_REF_NODE) @intCast(self.reference.payload) else null;
    }

    pub fn isFrozen(self: Ref) bool {
        return if (self.nodeId() != null) self.node().flags & artifact.flags.frozen != 0 else true;
    }

    pub fn asInteger(self: Ref) ReadError!i64 {
        if (self.kind() != .integer) return error.TypeMismatch;
        return @bitCast(self.reference.payload);
    }
    pub fn asBoolean(self: Ref) ReadError!bool {
        if (self.kind() != .boolean) return error.TypeMismatch;
        return self.reference.tag == c.MRZ_ARTIFACT_REF_TRUE;
    }
    pub fn asFloat(self: Ref) ReadError!f64 {
        if (self.kind() != .float) return error.TypeMismatch;
        return @bitCast(self.reference.payload);
    }
    pub fn asString(self: Ref) ReadError![]const u8 {
        if (self.kind() != .string) return error.TypeMismatch;
        const n = self.node();
        return if (n.bytes_len == 0) &.{} else n.bytes_ptr.?[0..n.bytes_len];
    }
    pub fn asSymbol(self: Ref) ReadError![]const u8 {
        if (self.kind() != .symbol) return error.TypeMismatch;
        return if (self.reference.length == 0) &.{} else @as([*]const u8, @ptrFromInt(self.reference.payload))[0..self.reference.length];
    }
    /// String byte length, Array element count, or Hash pair count.
    pub fn len(self: Ref) ReadError!usize {
        return switch (self.kind()) {
            .string => self.node().bytes_len,
            .array => self.node().edge_count,
            .hash => self.node().edge_count / 2,
            else => error.TypeMismatch,
        };
    }
    pub fn at(self: Ref, index: usize) ReadError!Ref {
        if (self.kind() != .array) return error.TypeMismatch;
        if (index >= self.node().edge_count) return error.IndexOutOfBounds;
        return self.edge(index);
    }
    pub fn pair(self: Ref, index: usize) ReadError!struct { key: Ref, value: Ref } {
        if (self.kind() != .hash) return error.TypeMismatch;
        if (index >= try self.len()) return error.IndexOutOfBounds;
        return .{ .key = self.edge(index * 2), .value = self.edge(index * 2 + 1) };
    }
    /// Look up an exact String key; Symbol keys remain a distinct Ruby type.
    pub fn get(self: Ref, name: []const u8) ReadError!?Ref {
        return self.getNamed(name, .string);
    }
    pub fn getSymbol(self: Ref, name: []const u8) ReadError!?Ref {
        return self.getNamed(name, .symbol);
    }
    pub fn default(self: Ref) ReadError!?Ref {
        if (self.kind() != .hash) return error.TypeMismatch;
        const n = self.node();
        return if (n.flags & artifact.flags.hash_has_default != 0) self.edge(n.edge_count - 1) else null;
    }
    fn getNamed(self: Ref, name: []const u8, key_kind: Kind) ReadError!?Ref {
        if (self.kind() != .hash) return error.TypeMismatch;
        for (0..try self.len()) |i| {
            const entry = try self.pair(i);
            if (entry.key.kind() != key_kind) continue;
            const bytes = if (key_kind == .string) try entry.key.asString() else try entry.key.asSymbol();
            if (std.mem.eql(u8, bytes, name)) return entry.value;
        }
        return null;
    }
    fn node(self: Ref) c.mrz_artifact_node {
        return self.document.graph.nodes[@intCast(self.reference.payload)];
    }
    fn edge(self: Ref, index: usize) Ref {
        return .{ .document = self.document, .reference = self.document.graph.edges[self.node().edge_offset + index] };
    }
};

const EncodeNode = struct {
    value: Value,
    depth: usize,
    frozen: bool,
    refs: []artifact.ValueRef = &.{},
    body_len: usize = 4,
};

const Encoder = struct {
    allocator: std.mem.Allocator,
    bounds: artifact.CapsuleLimits,
    nodes: std.ArrayList(EncodeNode) = .empty,
    edges: usize = 0,
    bytes: usize = artifact.state_prelude_fixed_len,

    fn deinit(self: *Encoder) void {
        for (self.nodes.items) |node| self.allocator.free(node.refs);
        self.nodes.deinit(self.allocator);
    }
    fn addBytes(self: *Encoder, amount: usize) !void {
        if (amount > self.bounds.max_encoded_bytes -| self.bytes) return error.ArtifactLimitExceeded;
        self.bytes += amount;
    }
    fn ref(self: *Encoder, value: Value, depth: usize, frozen: bool) !artifact.ValueRef {
        const result: artifact.ValueRef = switch (value) {
            .nil => .nil,
            .boolean => |b| if (b) .boolean_true else .boolean_false,
            .integer => |n| .{ .integer = n },
            .float => |n| .{ .float = @bitCast(n) },
            .symbol => |s| .{ .symbol = s },
            .string, .array, .hash => blk: {
                if (depth > self.bounds.max_depth or self.nodes.items.len >= self.bounds.max_nodes) return error.CapsuleLimitExceeded;
                const id: u32 = @intCast(self.nodes.items.len);
                try self.addBytes(artifact.node_record_header_len + 4);
                if (value == .string) try self.addBytes(value.string.len);
                try self.nodes.append(self.allocator, .{ .value = value, .depth = depth, .frozen = frozen });
                break :blk .{ .node_ref = id };
            },
        };
        try self.addBytes(try result.encodedLen());
        return result;
    }
};

pub fn encode(allocator: std.mem.Allocator, value: Value, max_bytes: usize) !artifact.StateCapsule {
    var encoder: Encoder = .{ .allocator = allocator, .bounds = limits(max_bytes) };
    defer encoder.deinit();
    const root = try encoder.ref(value, 0, false);
    var index: usize = 0;
    // Breadth-first discovery gives the same canonical node numbering as the
    // Ruby exporter. Refs are allocated once per container, never recursively.
    while (index < encoder.nodes.items.len) : (index += 1) {
        const node = encoder.nodes.items[index];
        const edge_count = switch (node.value) {
            .array => |items| items.len,
            .hash => |pairs| std.math.mul(usize, pairs.len, 2) catch return error.CapsuleLimitExceeded,
            .string => 0,
            else => unreachable,
        };
        if (edge_count > encoder.bounds.max_total_edges -| encoder.edges) return error.CapsuleLimitExceeded;
        encoder.edges += edge_count;
        const refs = try allocator.alloc(artifact.ValueRef, edge_count);
        encoder.nodes.items[index].refs = refs;
        switch (node.value) {
            .array => |items| for (items, refs) |item, *reference| {
                reference.* = try encoder.ref(item, node.depth + 1, false);
            },
            .hash => |pairs| for (pairs, 0..) |entry, i| {
                refs[i * 2] = try encoder.ref(entry.key, node.depth + 1, entry.key == .string);
                refs[i * 2 + 1] = try encoder.ref(entry.value, node.depth + 1, false);
            },
            .string => {},
            else => unreachable,
        }
        var body_len: usize = 4;
        if (node.value == .string) body_len += node.value.string.len;
        for (refs) |reference| body_len += try reference.encodedLen();
        encoder.nodes.items[index].body_len = body_len;
    }
    if (try artifact.encodedLength(encoder.bytes) > max_bytes) return error.ArtifactLimitExceeded;
    const payload = try allocator.alloc(u8, encoder.bytes);
    defer allocator.free(payload);
    var writer = artifact.Writer.init(payload);
    try artifact.writeStatePrelude(&writer, .{ .node_count = @intCast(encoder.nodes.items.len), .edge_count = @intCast(encoder.edges), .root = root });
    for (encoder.nodes.items, 0..) |node, id| {
        try artifact.writeNodeRecordHeader(&writer, .{
            .id = @intCast(id),
            .kind = switch (node.value) {
                .string => .string,
                .array => .array,
                .hash => .hash,
                else => unreachable,
            },
            .flags = if (node.frozen) artifact.flags.frozen else 0,
            .body_len = @intCast(node.body_len),
        });
        switch (node.value) {
            .string => |bytes| {
                try writer.writeU32(@intCast(bytes.len));
                try writer.writeBytes(bytes);
            },
            .array, .hash => {
                try writer.writeU32(@intCast(if (node.value == .hash) node.refs.len / 2 else node.refs.len));
                for (node.refs) |reference| try artifact.writeValueRef(&writer, reference);
            },
            else => unreachable,
        }
    }
    try writer.finish();
    var capsule = try artifact.wrapState(allocator, payload, .{ .max_encoded_bytes = max_bytes });
    errdefer capsule.deinit(allocator);
    var graph = try codec.parse(allocator, capsule.view(), .{ .limits = encoder.bounds }, null);
    graph.deinit(allocator);
    return capsule;
}

const CopyNode = struct {
    /// Null only for the new Array root constructed by encodeRefs.
    original: ?Ref,
    refs: []artifact.ValueRef = &.{},
    body_len: usize = 4,
};
const NodeKey = struct { document: *const Document, id: u32 };
const GraphCopy = struct {
    allocator: std.mem.Allocator,
    bounds: artifact.CapsuleLimits,
    ids: std.AutoHashMapUnmanaged(NodeKey, u32) = .empty,
    nodes: std.ArrayList(CopyNode) = .empty,
    bytes: usize = artifact.state_prelude_fixed_len,
    edges: usize = 0,

    fn deinit(self: *GraphCopy) void {
        for (self.nodes.items) |node| self.allocator.free(node.refs);
        self.nodes.deinit(self.allocator);
        self.ids.deinit(self.allocator);
    }
    fn addBytes(self: *GraphCopy, amount: usize) !void {
        if (amount > self.bounds.max_encoded_bytes -| self.bytes) return error.ArtifactLimitExceeded;
        self.bytes += amount;
    }
    fn ref(self: *GraphCopy, original: Ref) !artifact.ValueRef {
        const reference = original.reference;
        const result: artifact.ValueRef = switch (reference.tag) {
            c.MRZ_ARTIFACT_REF_NIL => .nil,
            c.MRZ_ARTIFACT_REF_FALSE => .boolean_false,
            c.MRZ_ARTIFACT_REF_TRUE => .boolean_true,
            c.MRZ_ARTIFACT_REF_I64 => .{ .integer = @bitCast(reference.payload) },
            c.MRZ_ARTIFACT_REF_F64 => .{ .float = reference.payload },
            c.MRZ_ARTIFACT_REF_SYMBOL => .{ .symbol = try original.asSymbol() },
            c.MRZ_ARTIFACT_REF_NODE => blk: {
                const key: NodeKey = .{ .document = original.document, .id = @intCast(reference.payload) };
                if (self.ids.get(key)) |id| break :blk .{ .node_ref = id };
                if (self.nodes.items.len >= self.bounds.max_nodes) return error.CapsuleLimitExceeded;
                const id: u32 = @intCast(self.nodes.items.len);
                const node = original.node();
                try self.addBytes(artifact.node_record_header_len + 4 + @as(usize, node.bytes_len));
                try self.ids.put(self.allocator, key, id);
                try self.nodes.append(self.allocator, .{ .original = original });
                break :blk .{ .node_ref = id };
            },
            else => unreachable,
        };
        try self.addBytes(try result.encodedLen());
        return result;
    }

    fn finish(self: *GraphCopy, root: artifact.ValueRef, max_bytes: usize) !artifact.StateCapsule {
        var cursor: usize = 0;
        while (cursor < self.nodes.items.len) : (cursor += 1) {
            const source = self.nodes.items[cursor].original orelse continue;
            const original = source.node();
            if (original.edge_count > self.bounds.max_total_edges -| self.edges) return error.CapsuleLimitExceeded;
            self.edges += original.edge_count;
            const refs = try self.allocator.alloc(artifact.ValueRef, original.edge_count);
            self.nodes.items[cursor].refs = refs;
            for (refs, 0..) |*reference, i| reference.* = try self.ref(source.edge(i));
            var body_len: usize = 4 + @as(usize, original.bytes_len);
            for (refs) |reference| body_len += try reference.encodedLen();
            self.nodes.items[cursor].body_len = body_len;
        }
        if (try artifact.encodedLength(self.bytes) > max_bytes) return error.ArtifactLimitExceeded;
        const payload = try self.allocator.alloc(u8, self.bytes);
        defer self.allocator.free(payload);
        var writer = artifact.Writer.init(payload);
        try artifact.writeStatePrelude(&writer, .{ .node_count = @intCast(self.nodes.items.len), .edge_count = @intCast(self.edges), .root = root });
        for (self.nodes.items, 0..) |node, id| {
            const original = if (node.original) |source| source.node() else null;
            const kind = if (original) |source| source.kind else c.MRZ_ARTIFACT_NODE_ARRAY;
            try artifact.writeNodeRecordHeader(&writer, .{
                .id = @intCast(id),
                .kind = @fromBackingInt(@intCast(kind)),
                .flags = if (original) |source| source.flags else 0,
                .body_len = @intCast(node.body_len),
            });
            if (kind == c.MRZ_ARTIFACT_NODE_STRING) {
                const source = original.?;
                try writer.writeU32(source.bytes_len);
                if (source.bytes_len != 0) try writer.writeBytes(source.bytes_ptr.?[0..source.bytes_len]);
            } else {
                try writer.writeU32(@intCast(if (kind == c.MRZ_ARTIFACT_NODE_HASH) node.refs.len / 2 else node.refs.len));
                for (node.refs) |reference| try artifact.writeValueRef(&writer, reference);
            }
        }
        try writer.finish();
        var capsule = try artifact.wrapState(self.allocator, payload, .{ .max_encoded_bytes = max_bytes });
        errdefer capsule.deinit(self.allocator);
        var graph = try codec.parse(self.allocator, capsule.view(), .{ .limits = self.bounds }, null);
        graph.deinit(self.allocator);
        return capsule;
    }
};

/// Export a reachable subgraph with a new root. Canonical node numbering is
/// rebuilt; aliases, cycles, frozen flags, and Hash defaults are retained.
/// This is useful for extracting next_state from a terminal [result, state].
pub fn encodeRef(allocator: std.mem.Allocator, root: Ref, max_bytes: usize) !artifact.StateCapsule {
    var copy: GraphCopy = .{ .allocator = allocator, .bounds = limits(max_bytes) };
    defer copy.deinit();
    const root_ref = try copy.ref(root);
    return copy.finish(root_ref, max_bytes);
}

/// Construct a mutable Array containing existing graph roots, with canonical
/// breadth-first numbering. Refs from the same Document retain shared nodes;
/// separate Documents remain independent even when their bytes are identical.
/// Frozen nodes, cycles, String keys, and Hash defaults retain their identity.
/// This matches exporting the positional argument Array after importing each
/// Document separately into a VM, without constructing or accessing any VM.
pub fn encodeRefs(allocator: std.mem.Allocator, roots: []const Ref, max_bytes: usize) !artifact.StateCapsule {
    var copy: GraphCopy = .{ .allocator = allocator, .bounds = limits(max_bytes) };
    defer copy.deinit();
    if (copy.bounds.max_nodes == 0 or roots.len > copy.bounds.max_total_edges) return error.CapsuleLimitExceeded;
    const root: artifact.ValueRef = .{ .node_ref = 0 };
    try copy.addBytes(artifact.node_record_header_len + 4 + try root.encodedLen());
    try copy.nodes.append(allocator, .{ .original = null });
    const refs = try allocator.alloc(artifact.ValueRef, roots.len);
    copy.nodes.items[0].refs = refs;
    copy.edges = refs.len;
    for (roots, refs) |original, *reference| reference.* = try copy.ref(original);
    var body_len: usize = 4;
    for (refs) |reference| body_len += try reference.encodedLen();
    copy.nodes.items[0].body_len = body_len;
    return copy.finish(root, max_bytes);
}

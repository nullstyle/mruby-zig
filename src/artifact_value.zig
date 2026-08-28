//! Inert StateCapsule graph encoding and validation.
//!
//! This module is the only seam between stable StateCapsule bytes and the
//! mruby graph inspection/materialization ABI.  Export never invokes guest
//! Ruby code.  Import validates and normalizes the complete graph before the
//! protected C materializer is allowed to allocate a Ruby object.

const std = @import("std");
const artifact = @import("artifact.zig");
const c = @import("c.zig");

/// mruby stores symbol lengths in a 16-bit field and rejects lengths greater
/// than or equal to UINT16_MAX.
pub const max_symbol_name_bytes: usize = std.math.maxInt(u16) - 1;

// These are format-admission safety ceilings, not policy defaults. They bound
// the exact work mruby's pinned Hash implementation will perform after the
// inert parser has already rejected semantic duplicate keys.
const max_hash_pairs: usize = 250_000;
const max_capsule_hash_probes: usize = 4_000_000;
const max_string_comparison_bytes: usize = 128 * 1024 * 1024;
const hash_array_max_entries: usize = 16;

pub const ExportError = std.mem.Allocator.Error || artifact.FramingError || error{
    CapsuleLimitExceeded,
    UnsupportedValue,
    UnsupportedHashKey,
    UnsupportedContainerState,
    ArtifactConstructionFailed,
};

pub const ParseError = std.mem.Allocator.Error || artifact.StateValidationError || error{
    CapsuleLimitExceeded,
};

pub const FailureKind = enum {
    none,
    invalid_artifact,
    artifact_limit_exceeded,
    capsule_limit_exceeded,
    unsupported_value,
    unsupported_hash_key,
    unsupported_container_state,
    duplicate_hash_key,
};

/// Best-effort diagnostics contain no allocation and remain valid when an
/// operation unwinds. `encoded_offset` addresses the complete capsule, not
/// merely its payload. Export failures have no encoded offset.
pub const Failure = struct {
    pub const path_capacity = 256;

    kind: FailureKind = .none,
    encoded_offset: ?usize = null,
    value_type: ?c.mrb_vtype = null,
    path_len: u16 = 0,
    path_truncated: bool = false,
    path_buffer: [path_capacity]u8 = @splat(0),

    pub fn clear(self: *Failure) void {
        self.* = .{};
    }

    pub fn path(self: *const Failure) []const u8 {
        return self.path_buffer[0..self.path_len];
    }
};

pub const ExportOptions = struct {
    limits: artifact.CapsuleLimits = .{},
    schema: ?artifact.Schema = null,
};

pub const ParseOptions = struct {
    limits: artifact.CapsuleLimits = .{},
    accepted_schema: ?artifact.Schema = null,
};

/// C-normalized graph whose strings and symbols borrow the capsule passed to
/// `parse`. Keep those bytes alive until this graph has been materialized.
pub const ParsedGraph = struct {
    nodes: []c.mrz_artifact_node,
    edges: []c.mrz_artifact_ref,
    root: c.mrz_artifact_ref,
    schema: ?artifact.Schema,

    pub fn deinit(self: *ParsedGraph, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.edges);
        self.* = undefined;
    }

    pub fn cGraph(self: *const ParsedGraph) c.mrz_artifact_graph {
        return .{
            .nodes = if (self.nodes.len == 0) null else self.nodes.ptr,
            .edges = if (self.edges.len == 0) null else self.edges.ptr,
            .node_count = @intCast(self.nodes.len),
            .edge_count = @intCast(self.edges.len),
            .root = self.root,
        };
    }
};

pub const Materialized = struct {
    value: c.mrb_value,
    arena_roots: u32,
};

/// OOM is intentionally not classified here. The Isolate owns the allocator
/// cell and decides whether C materialization exhausted process memory or a
/// configured sandbox cap.
pub const MaterializeOutcome = union(enum) {
    ok: Materialized,
    invalid,
    out_of_memory,
    unexpected,
};

const ExportNode = struct {
    value: c.mrb_value,
    kind: artifact.NodeKind,
    flags: u8,
    depth: usize,
    bytes: []const u8 = &.{},
    refs: []artifact.ValueRef = &.{},
};

const EdgeSiteKind = enum {
    root,
    node,
    array_element,
    hash_key,
    hash_value,
    hash_default,
};

const EdgeSite = struct {
    node_id: ?u32 = null,
    kind: EdgeSiteKind = .root,
    index: usize = 0,
};

const ExportContext = struct {
    allocator: std.mem.Allocator,
    mrb: *c.mrb_state,
    limits: artifact.CapsuleLimits,
    failure: ?*Failure,
    nodes: std.ArrayList(ExportNode) = .empty,
    identities: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    owned_symbols: std.ArrayList([]u8) = .empty,
    total_edges: usize = 0,
    total_string_bytes: usize = 0,
    total_symbol_bytes: usize = 0,

    fn deinit(self: *ExportContext) void {
        for (self.nodes.items) |node| {
            if (node.refs.len != 0) self.allocator.free(node.refs);
        }
        for (self.owned_symbols.items) |bytes| self.allocator.free(bytes);
        self.owned_symbols.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.identities.deinit(self.allocator);
    }
};

/// Export a Ruby value graph to canonical StateCapsule bytes. The caller must
/// already have admitted exclusive inert access to `mrb`.
pub fn exportValue(
    allocator: std.mem.Allocator,
    mrb: *c.mrb_state,
    root: c.mrb_value,
    options: ExportOptions,
    failure: ?*Failure,
) ExportError!artifact.StateCapsule {
    clearFailure(failure);
    var context: ExportContext = .{
        .allocator = allocator,
        .mrb = mrb,
        .limits = options.limits,
        .failure = failure,
    };
    defer context.deinit();

    const root_ref = try exportRef(&context, root, 0, .{});

    var cursor: usize = 0;
    while (cursor < context.nodes.items.len) : (cursor += 1) {
        try inspectExportNode(&context, cursor);
    }

    const payload_len = exportPayloadLen(&context, root_ref) catch |err| {
        setExportFailure(failure, .artifact_limit_exceeded, null, .{});
        return err;
    };
    const encoded_len = artifact.encodedLength(payload_len) catch |err| {
        setExportFailure(failure, .artifact_limit_exceeded, null, .{});
        return err;
    };
    if (encoded_len > context.limits.max_encoded_bytes) {
        setExportFailure(failure, .artifact_limit_exceeded, null, .{});
        return error.ArtifactLimitExceeded;
    }

    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    encodeExportPayload(payload, &context, root_ref) catch {
        return error.ArtifactConstructionFailed;
    };
    var capsule = try artifact.wrapState(allocator, payload, .{
        .schema = options.schema,
        .max_encoded_bytes = options.limits.max_encoded_bytes,
    });
    errdefer capsule.deinit(allocator);

    // Run the same pure admission used by import over the finished stable
    // bytes. This keeps non-relaxable Hash work ceilings symmetric: export
    // can never publish a capsule that an equally configured import rejects
    // solely because materializing its Hashes would be pathological.
    var preflight_failure: Failure = .{};
    var graph = parse(allocator, capsule.view(), .{
        .limits = options.limits,
        .accepted_schema = options.schema,
    }, &preflight_failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CapsuleLimitExceeded => {
            if (failure) |target| {
                target.* = preflight_failure;
                target.encoded_offset = null;
            }
            return error.CapsuleLimitExceeded;
        },
        else => return error.ArtifactConstructionFailed,
    };
    graph.deinit(allocator);
    return capsule;
}

fn exportRef(
    context: *ExportContext,
    value: c.mrb_value,
    depth: usize,
    site: EdgeSite,
) ExportError!artifact.ValueRef {
    if (c.mrz_nil_p(value)) return .{ .nil = {} };
    if (c.mrz_false_p(value)) return .{ .boolean_false = {} };
    if (c.mrz_true_p(value)) return .{ .boolean_true = {} };
    if (c.mrz_integer_p(value)) return .{ .integer = c.mrz_integer(value) };
    if (c.mrz_float_p(value)) {
        var bits: u64 = undefined;
        if (!c.mrz_artifact_float_bits(value, &bits)) {
            return exportUnsupported(context, error.UnsupportedValue, .unsupported_value, value, site);
        }
        return .{ .float = bits };
    }
    if (c.mrz_symbol_p(value)) {
        var len: c.mrb_int = 0;
        const ptr = c.mrb_sym_name_len(context.mrb, c.mrz_symbol(value), &len);
        if (len < 0) return exportUnsupported(context, error.UnsupportedValue, .unsupported_value, value, site);
        const byte_len: usize = @intCast(len);
        if (byte_len > max_symbol_name_bytes) {
            return exportUnsupported(context, error.UnsupportedValue, .unsupported_value, value, site);
        }
        context.total_symbol_bytes = checkedAdd(context.total_symbol_bytes, byte_len) catch {
            return exportLimit(context, value, site);
        };
        if (context.total_symbol_bytes > context.limits.max_symbol_bytes) {
            return exportLimit(context, value, site);
        }
        const borrowed: []const u8 = if (byte_len == 0)
            &.{}
        else if (ptr) |p|
            p[0..byte_len]
        else
            return exportUnsupported(context, error.UnsupportedValue, .unsupported_value, value, site);
        // Inline symbols borrow mrb->symbuf, which the next symbol lookup
        // overwrites. Copy every name immediately; this also makes the final
        // encoding independent of mruby's symbol storage strategy.
        const bytes = try context.allocator.dupe(u8, borrowed);
        errdefer context.allocator.free(bytes);
        try context.owned_symbols.append(context.allocator, bytes);
        return .{ .symbol = bytes };
    }

    const raw_kind = c.mrz_artifact_container_kind(context.mrb, value);
    const kind: artifact.NodeKind = switch (raw_kind) {
        c.MRZ_ARTIFACT_NODE_STRING => .string,
        c.MRZ_ARTIFACT_NODE_ARRAY => .array,
        c.MRZ_ARTIFACT_NODE_HASH => .hash,
        else => {
            if (c.mrz_string_p(value) or c.mrz_array_p(value) or c.mrz_hash_p(value)) {
                return exportUnsupported(
                    context,
                    error.UnsupportedContainerState,
                    .unsupported_container_state,
                    value,
                    site,
                );
            }
            return exportUnsupported(context, error.UnsupportedValue, .unsupported_value, value, site);
        },
    };

    const identity = c.mrz_artifact_identity(value) orelse
        return exportUnsupported(context, error.UnsupportedValue, .unsupported_value, value, site);
    const identity_key = @intFromPtr(identity);
    if (context.identities.get(identity_key)) |id| return .{ .node_ref = id };

    if (depth > context.limits.max_depth or
        context.nodes.items.len >= context.limits.max_nodes or
        context.nodes.items.len >= std.math.maxInt(u32))
    {
        return exportLimit(context, value, site);
    }

    const id: u32 = @intCast(context.nodes.items.len);
    try context.nodes.append(context.allocator, .{
        .value = value,
        .kind = kind,
        .flags = if (c.mrz_artifact_frozen_p(value)) artifact.flags.frozen else 0,
        .depth = depth,
    });
    try context.identities.put(context.allocator, identity_key, id);
    return .{ .node_ref = id };
}

fn inspectExportNode(context: *ExportContext, node_index: usize) ExportError!void {
    const value = context.nodes.items[node_index].value;
    const kind = context.nodes.items[node_index].kind;
    const depth = context.nodes.items[node_index].depth;
    const id: u32 = @intCast(node_index);
    const node_site: EdgeSite = .{ .node_id = id, .kind = .node };

    if (c.mrz_artifact_has_extra_ivars(context.mrb, value)) {
        return exportUnsupported(
            context,
            error.UnsupportedContainerState,
            .unsupported_container_state,
            value,
            node_site,
        );
    }

    switch (kind) {
        .string => {
            const signed_len = c.mrz_string_len(value);
            if (signed_len < 0) {
                return exportUnsupported(
                    context,
                    error.UnsupportedContainerState,
                    .unsupported_container_state,
                    value,
                    node_site,
                );
            }
            const len: usize = @intCast(signed_len);
            if (len > std.math.maxInt(u32)) return exportLimit(context, value, node_site);
            context.total_string_bytes = checkedAdd(context.total_string_bytes, len) catch
                return exportLimit(context, value, node_site);
            if (context.total_string_bytes > context.limits.max_string_bytes) {
                return exportLimit(context, value, node_site);
            }
            context.nodes.items[node_index].bytes = if (len == 0)
                &.{}
            else if (c.mrz_string_ptr(value)) |ptr|
                ptr[0..len]
            else
                return exportUnsupported(
                    context,
                    error.UnsupportedContainerState,
                    .unsupported_container_state,
                    value,
                    node_site,
                );
        },
        .array => {
            const len = c.mrz_artifact_array_len(value);
            try reserveEdges(context, len, value, node_site);
            const child_depth = checkedAdd(depth, 1) catch return exportLimit(context, value, node_site);
            const refs = try context.allocator.alloc(artifact.ValueRef, len);
            errdefer if (refs.len != 0) context.allocator.free(refs);
            const values = if (len == 0)
                null
            else
                c.mrz_artifact_array_ptr(value) orelse
                    return exportUnsupported(
                        context,
                        error.UnsupportedContainerState,
                        .unsupported_container_state,
                        value,
                        node_site,
                    );
            for (refs, 0..) |*ref, index| {
                ref.* = try exportRef(context, values.?[index], child_depth, .{
                    .node_id = id,
                    .kind = .array_element,
                    .index = index,
                });
            }
            context.nodes.items[node_index].refs = refs;
        },
        .hash => {
            var state: c.mrz_artifact_hash_state = undefined;
            if (!c.mrz_artifact_hash_state_get(context.mrb, value, &state) or
                state.reserved != 0 or state.has_default_proc != 0 or
                state.has_extra_ivars != 0)
            {
                return exportUnsupported(
                    context,
                    error.UnsupportedContainerState,
                    .unsupported_container_state,
                    value,
                    node_site,
                );
            }
            const pair_count = c.mrz_artifact_hash_len(value);
            const pair_edges = checkedMul(pair_count, 2) catch
                return exportLimit(context, value, node_site);
            const has_default: usize = if (state.has_default != 0) 1 else 0;
            const edge_count = checkedAdd(pair_edges, has_default) catch
                return exportLimit(context, value, node_site);
            try reserveEdges(context, edge_count, value, node_site);
            const child_depth = checkedAdd(depth, 1) catch return exportLimit(context, value, node_site);

            const pairs = try context.allocator.alloc(c.mrz_artifact_pair, pair_count);
            defer context.allocator.free(pairs);
            if (!c.mrz_artifact_hash_copy_pairs(
                context.mrb,
                value,
                if (pairs.len == 0) null else pairs.ptr,
                pairs.len,
            )) {
                return error.ArtifactConstructionFailed;
            }

            const refs = try context.allocator.alloc(artifact.ValueRef, edge_count);
            errdefer if (refs.len != 0) context.allocator.free(refs);
            for (pairs, 0..) |pair, pair_index| {
                try validateExportHashKey(context, pair.key, .{
                    .node_id = id,
                    .kind = .hash_key,
                    .index = pair_index,
                });
                refs[pair_index * 2] = try exportRef(context, pair.key, child_depth, .{
                    .node_id = id,
                    .kind = .hash_key,
                    .index = pair_index,
                });
                refs[pair_index * 2 + 1] = try exportRef(context, pair.value, child_depth, .{
                    .node_id = id,
                    .kind = .hash_value,
                    .index = pair_index,
                });
            }
            if (has_default != 0) {
                refs[refs.len - 1] = try exportRef(context, state.default_value, child_depth, .{
                    .node_id = id,
                    .kind = .hash_default,
                });
                context.nodes.items[node_index].flags |= artifact.flags.hash_has_default;
            }
            context.nodes.items[node_index].refs = refs;
        },
    }
}

fn validateExportHashKey(
    context: *ExportContext,
    value: c.mrb_value,
    site: EdgeSite,
) ExportError!void {
    if (c.mrz_integer_p(value) or c.mrz_float_p(value) or c.mrz_symbol_p(value)) return;
    if (c.mrz_artifact_container_kind(context.mrb, value) == c.MRZ_ARTIFACT_NODE_STRING and
        c.mrz_artifact_frozen_p(value) and
        !c.mrz_artifact_has_extra_ivars(context.mrb, value))
    {
        return;
    }
    return exportUnsupported(context, error.UnsupportedHashKey, .unsupported_hash_key, value, site);
}

fn reserveEdges(
    context: *ExportContext,
    additional: usize,
    value: c.mrb_value,
    site: EdgeSite,
) ExportError!void {
    const total = checkedAdd(context.total_edges, additional) catch
        return exportLimit(context, value, site);
    if (total > context.limits.max_total_edges or total > std.math.maxInt(u32)) {
        return exportLimit(context, value, site);
    }
    context.total_edges = total;
}

fn exportPayloadLen(context: *const ExportContext, root: artifact.ValueRef) ExportError!usize {
    var total: usize = artifact.state_prelude_fixed_len;
    total = try addFrameBytes(total, try root.encodedLen());
    for (context.nodes.items) |node| {
        total = try addFrameBytes(total, artifact.node_record_header_len);
        total = try addFrameBytes(total, try exportNodeBodyLen(node));
    }
    return total;
}

fn exportNodeBodyLen(node: ExportNode) artifact.FramingError!usize {
    var len: usize = 4;
    switch (node.kind) {
        .string => len = try addFrameBytes(len, node.bytes.len),
        .array, .hash => for (node.refs) |ref| {
            len = try addFrameBytes(len, try ref.encodedLen());
        },
    }
    if (len > std.math.maxInt(u32)) return error.ArtifactLimitExceeded;
    return len;
}

fn encodeExportPayload(
    payload: []u8,
    context: *const ExportContext,
    root: artifact.ValueRef,
) (artifact.Writer.Error || artifact.FramingError)!void {
    var writer = artifact.Writer.init(payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = @intCast(context.nodes.items.len),
        .edge_count = @intCast(context.total_edges),
        .root = root,
    });
    for (context.nodes.items, 0..) |node, id| {
        const body_len = try exportNodeBodyLen(node);
        try artifact.writeNodeRecordHeader(&writer, .{
            .id = @intCast(id),
            .kind = node.kind,
            .flags = node.flags,
            .body_len = @intCast(body_len),
        });
        switch (node.kind) {
            .string => {
                try writer.writeU32(@intCast(node.bytes.len));
                try writer.writeBytes(node.bytes);
            },
            .array => {
                try writer.writeU32(@intCast(node.refs.len));
                for (node.refs) |ref| try artifact.writeValueRef(&writer, ref);
            },
            .hash => {
                const default_edges: usize = if (node.flags & artifact.flags.hash_has_default != 0) 1 else 0;
                const pair_edges = node.refs.len - default_edges;
                try writer.writeU32(@intCast(pair_edges / 2));
                for (node.refs) |ref| try artifact.writeValueRef(&writer, ref);
            },
        }
    }
    try writer.finish();
}

/// Parse, quota-check, canonically validate, and normalize a StateCapsule.
/// No mruby function is called by this operation.
pub fn parse(
    allocator: std.mem.Allocator,
    capsule: artifact.StateCapsuleView,
    options: ParseOptions,
    failure: ?*Failure,
) ParseError!ParsedGraph {
    clearFailure(failure);
    const state = artifact.validateState(capsule, .{
        .accepted_schema = options.accepted_schema,
        .max_encoded_bytes = options.limits.max_encoded_bytes,
    }) catch |err| {
        setParseFailure(failure, switch (err) {
            error.ArtifactLimitExceeded => .artifact_limit_exceeded,
            else => .invalid_artifact,
        }, 0, .{});
        return err;
    };

    var reader = artifact.Reader.init(state.bytes);
    const prelude = artifact.readStatePrelude(&reader) catch |err| {
        setParseFailure(failure, .invalid_artifact, reader.offset, .{});
        return err;
    };
    const node_count: usize = prelude.node_count;
    const edge_count: usize = prelude.edge_count;
    if (node_count > options.limits.max_nodes or edge_count > options.limits.max_total_edges) {
        setParseFailure(failure, .capsule_limit_exceeded, reader.offset, .{});
        return error.CapsuleLimitExceeded;
    }

    const nodes = try allocator.alloc(c.mrz_artifact_node, node_count);
    errdefer allocator.free(nodes);
    const edges = try allocator.alloc(c.mrz_artifact_ref, edge_count);
    errdefer allocator.free(edges);
    const depths = try allocator.alloc(usize, node_count);
    defer allocator.free(depths);
    const seen = try allocator.alloc(bool, node_count);
    defer allocator.free(seen);
    @memset(seen, false);
    const edge_offsets = try allocator.alloc(usize, edge_count);
    defer allocator.free(edge_offsets);

    var parse_context: ParseContext = .{
        .allocator = allocator,
        .limits = options.limits,
        .failure = failure,
        .nodes = nodes,
        .edges = edges,
        .depths = depths,
        .seen = seen,
        .edge_offsets = edge_offsets,
    };

    const root = parseRef(&parse_context, prelude.root, null, artifact.state_prelude_fixed_len, .{}) catch |err| {
        if (failure) |f| if (f.kind == .none) setParseFailure(failure, .invalid_artifact, reader.offset, .{});
        return err;
    };

    for (nodes, 0..) |*node, id| {
        if (!seen[id]) return parseInvalid(&parse_context, reader.offset, .{ .node_id = @intCast(id), .kind = .node });
        const header_offset = reader.offset;
        const header = artifact.readNodeRecordHeader(&reader) catch |err| {
            setParseFailure(failure, .invalid_artifact, reader.offset, .{ .node_id = @intCast(id), .kind = .node });
            return err;
        };
        if (header.id != id) return parseInvalid(&parse_context, header_offset, .{ .node_id = @intCast(id), .kind = .node });
        const body_bytes = reader.readBytes(header.body_len) catch |err| {
            setParseFailure(failure, .invalid_artifact, reader.offset, .{ .node_id = @intCast(id), .kind = .node });
            return err;
        };
        var body = artifact.Reader.init(body_bytes);
        try parseNodeBody(&parse_context, node, @intCast(id), header, &body, header_offset + artifact.node_record_header_len);
        body.finish() catch return parseInvalid(
            &parse_context,
            header_offset + artifact.node_record_header_len + body.offset,
            .{ .node_id = @intCast(id), .kind = .node },
        );
    }

    reader.finish() catch return parseInvalid(&parse_context, reader.offset, .{});
    if (parse_context.edge_cursor != edge_count or
        parse_context.next_node_id != node_count)
    {
        return parseInvalid(&parse_context, reader.offset, .{});
    }
    try validateParsedHashKeys(&parse_context);

    return .{
        .nodes = nodes,
        .edges = edges,
        .root = root,
        .schema = state.schema,
    };
}

const ParseContext = struct {
    allocator: std.mem.Allocator,
    limits: artifact.CapsuleLimits,
    failure: ?*Failure,
    nodes: []c.mrz_artifact_node,
    edges: []c.mrz_artifact_ref,
    depths: []usize,
    seen: []bool,
    edge_offsets: []usize,
    edge_cursor: usize = 0,
    next_node_id: usize = 0,
    total_string_bytes: usize = 0,
    total_symbol_bytes: usize = 0,
};

fn parseNodeBody(
    context: *ParseContext,
    node: *c.mrz_artifact_node,
    id: u32,
    header: artifact.NodeRecordHeader,
    body: *artifact.Reader,
    body_payload_offset: usize,
) ParseError!void {
    const edge_offset = context.edge_cursor;
    switch (header.kind) {
        .string => {
            const len = body.readU32() catch return parseInvalid(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
            const bytes = body.readBytes(len) catch return parseInvalid(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
            context.total_string_bytes = checkedAdd(context.total_string_bytes, bytes.len) catch
                return parseLimit(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
            if (context.total_string_bytes > context.limits.max_string_bytes) {
                return parseLimit(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
            }
            node.* = .{
                .kind = c.MRZ_ARTIFACT_NODE_STRING,
                .flags = header.flags,
                .reserved = 0,
                // The materializer treats edge offsets on byte-only nodes as
                // reserved and requires the canonical zero value.
                .edge_offset = 0,
                .edge_count = 0,
                .bytes_ptr = if (bytes.len == 0) null else bytes.ptr,
                .bytes_len = @intCast(bytes.len),
            };
        },
        .array => {
            const count: usize = body.readU32() catch return parseInvalid(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
            try parseNodeEdges(context, body, id, count, body_payload_offset, .array_element);
            node.* = .{
                .kind = c.MRZ_ARTIFACT_NODE_ARRAY,
                .flags = header.flags,
                .reserved = 0,
                .edge_offset = @intCast(edge_offset),
                .edge_count = @intCast(count),
                .bytes_ptr = null,
                .bytes_len = 0,
            };
        },
        .hash => {
            const pair_count: usize = body.readU32() catch return parseInvalid(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
            const pair_edges = checkedMul(pair_count, 2) catch
                return parseInvalid(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
            const default_edges: usize = if (header.flags & artifact.flags.hash_has_default != 0) 1 else 0;
            const count = checkedAdd(pair_edges, default_edges) catch
                return parseInvalid(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
            try parseHashEdges(context, body, id, pair_count, default_edges != 0, body_payload_offset);
            node.* = .{
                .kind = c.MRZ_ARTIFACT_NODE_HASH,
                .flags = header.flags,
                .reserved = 0,
                .edge_offset = @intCast(edge_offset),
                .edge_count = @intCast(count),
                .bytes_ptr = null,
                .bytes_len = 0,
            };
        },
    }
}

fn parseNodeEdges(
    context: *ParseContext,
    body: *artifact.Reader,
    id: u32,
    count: usize,
    body_payload_offset: usize,
    site_kind: EdgeSiteKind,
) ParseError!void {
    if (count > context.edges.len -| context.edge_cursor) {
        return parseInvalid(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
    }
    const child_depth = checkedAdd(context.depths[id], 1) catch
        return parseLimit(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
    for (0..count) |index| {
        const site: EdgeSite = .{ .node_id = id, .kind = site_kind, .index = index };
        try parseAndStoreEdge(context, body, child_depth, body_payload_offset, site);
    }
}

fn parseHashEdges(
    context: *ParseContext,
    body: *artifact.Reader,
    id: u32,
    pair_count: usize,
    has_default: bool,
    body_payload_offset: usize,
) ParseError!void {
    const edge_count = checkedAdd(checkedMul(pair_count, 2) catch
        return parseInvalid(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node }), if (has_default) 1 else 0) catch
        return parseInvalid(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
    if (edge_count > context.edges.len -| context.edge_cursor) {
        return parseInvalid(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
    }
    const child_depth = checkedAdd(context.depths[id], 1) catch
        return parseLimit(context, body_payload_offset + body.offset, .{ .node_id = id, .kind = .node });
    for (0..pair_count) |index| {
        try parseAndStoreEdge(context, body, child_depth, body_payload_offset, .{
            .node_id = id,
            .kind = .hash_key,
            .index = index,
        });
        try parseAndStoreEdge(context, body, child_depth, body_payload_offset, .{
            .node_id = id,
            .kind = .hash_value,
            .index = index,
        });
    }
    if (has_default) {
        try parseAndStoreEdge(context, body, child_depth, body_payload_offset, .{
            .node_id = id,
            .kind = .hash_default,
        });
    }
}

fn parseAndStoreEdge(
    context: *ParseContext,
    body: *artifact.Reader,
    depth: usize,
    body_payload_offset: usize,
    site: EdgeSite,
) ParseError!void {
    const edge_index = context.edge_cursor;
    const wire_offset = body_payload_offset + body.offset;
    context.edge_offsets[edge_index] = wire_offset;
    const wire_ref = artifact.readValueRef(body) catch
        return parseInvalid(context, body_payload_offset + body.offset, site);
    context.edges[edge_index] = try parseRef(context, wire_ref, depth, wire_offset, site);
    context.edge_cursor += 1;
}

fn parseRef(
    context: *ParseContext,
    wire_ref: artifact.ValueRef,
    node_depth: ?usize,
    payload_offset: usize,
    site: EdgeSite,
) ParseError!c.mrz_artifact_ref {
    var result: c.mrz_artifact_ref = .{
        .tag = 0,
        .reserved = @splat(0),
        .length = 0,
        .payload = 0,
    };
    switch (wire_ref) {
        .nil => result.tag = c.MRZ_ARTIFACT_REF_NIL,
        .boolean_false => result.tag = c.MRZ_ARTIFACT_REF_FALSE,
        .boolean_true => result.tag = c.MRZ_ARTIFACT_REF_TRUE,
        .integer => |integer| {
            result.tag = c.MRZ_ARTIFACT_REF_I64;
            result.payload = @bitCast(integer);
        },
        .float => |bits| {
            result.tag = c.MRZ_ARTIFACT_REF_F64;
            result.payload = bits;
        },
        .symbol => |bytes| {
            if (bytes.len > max_symbol_name_bytes) {
                return parseInvalid(context, payload_offset, site);
            }
            context.total_symbol_bytes = checkedAdd(context.total_symbol_bytes, bytes.len) catch
                return parseLimit(context, payload_offset, site);
            if (context.total_symbol_bytes > context.limits.max_symbol_bytes) {
                return parseLimit(context, payload_offset, site);
            }
            result.tag = c.MRZ_ARTIFACT_REF_SYMBOL;
            result.length = @intCast(bytes.len);
            result.payload = if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr);
        },
        .node_ref => |id| {
            if (id >= context.nodes.len) return parseInvalid(context, payload_offset, site);
            const index: usize = id;
            if (!context.seen[index]) {
                if (index != context.next_node_id) return parseInvalid(context, payload_offset, site);
                const depth = node_depth orelse 0;
                if (depth > context.limits.max_depth) return parseLimit(context, payload_offset, site);
                context.seen[index] = true;
                context.depths[index] = depth;
                context.next_node_id += 1;
            }
            result.tag = c.MRZ_ARTIFACT_REF_NODE;
            result.payload = id;
        },
    }
    return result;
}

fn validateParsedHashKeys(context: *ParseContext) ParseError!void {
    var work: HashWork = .{};
    for (context.nodes, 0..) |node, node_index| {
        if (node.kind != c.MRZ_ARTIFACT_NODE_HASH) continue;
        var keys: std.HashMapUnmanaged(ParsedHashKey, void, ParsedHashKeyContext, 80) = .empty;
        defer keys.deinit(context.allocator);
        const default_edges: usize = if (node.flags & c.MRZ_ARTIFACT_HASH_HAS_DEFAULT != 0) 1 else 0;
        const pair_edges = node.edge_count - default_edges;
        const refs = context.edges[node.edge_offset .. node.edge_offset + pair_edges];
        const pair_count = refs.len / 2;

        var key_edge: usize = 0;
        while (key_edge < refs.len) : (key_edge += 2) {
            const key = refs[key_edge];
            const absolute_edge = node.edge_offset + key_edge;
            const site: EdgeSite = .{
                .node_id = @intCast(node_index),
                .kind = .hash_key,
                .index = key_edge / 2,
            };
            const normalized_key = parsedHashKey(context, key) orelse {
                setParseFailure(context.failure, .invalid_artifact, context.edge_offsets[absolute_edge], site);
                return error.InvalidArtifact;
            };
            const inserted = try keys.getOrPut(context.allocator, normalized_key);
            if (inserted.found_existing) {
                setParseFailure(context.failure, .duplicate_hash_key, context.edge_offsets[absolute_edge], site);
                return error.InvalidArtifact;
            }
        }
        if (hashPairOverflowIndex(work.total_pairs, pair_count)) |offending_index| {
            return hashWorkLimit(context, node, node_index, offending_index);
        }
        work.total_pairs += pair_count;
        try simulateHashInsertion(context, node, node_index, refs, &work);
    }
}

const HashWork = struct {
    total_pairs: usize = 0,
    total_probes: usize = 0,
    string_comparison_bytes: usize = 0,
};

fn hashPairOverflowIndex(total_pairs: usize, additional_pairs: usize) ?usize {
    const remaining = max_hash_pairs -| total_pairs;
    return if (additional_pairs > remaining) remaining else null;
}

fn simulateHashInsertion(
    context: *ParseContext,
    node: c.mrz_artifact_node,
    node_index: usize,
    refs: []const c.mrz_artifact_ref,
    work: *HashWork,
) ParseError!void {
    const pair_count = refs.len / 2;
    if (pair_count == 0) return;
    const per_hash_limit = @max(@as(usize, 136), checkedMul(12, pair_count) catch
        return hashWorkLimit(context, node, node_index, 0));
    var hash_probes: usize = 0;

    if (pair_count <= hash_array_max_entries) {
        // AR linearly compares against every earlier key, then performs one
        // terminal insertion operation: sum(1...16) is the 136 floor above.
        for (0..pair_count) |key_index| {
            for (0..key_index) |prior_index| {
                try addHashProbe(context, node, node_index, key_index, &hash_probes, per_hash_limit, work);
                try addStringComparison(
                    context,
                    node,
                    node_index,
                    key_index,
                    refs[key_index * 2],
                    refs[prior_index * 2],
                    work,
                );
            }
            try addHashProbe(context, node, node_index, key_index, &hash_probes, per_hash_limit, work);
        }
        return;
    }

    const capacity = hashTableCapacity(pair_count) catch
        return hashWorkLimit(context, node, node_index, 0);
    const empty = std.math.maxInt(u32);
    const buckets = try context.allocator.alloc(u32, capacity);
    defer context.allocator.free(buckets);
    @memset(buckets, empty);
    const mask = capacity - 1;

    for (0..pair_count) |key_index| {
        const key = refs[key_index * 2];
        const initial: u32 = @truncate(@as(usize, mixedHashCode(context, key)) & mask);
        var step: u32 = 0;
        while (true) {
            try addHashProbe(context, node, node_index, key_index, &hash_probes, per_hash_limit, work);
            // The pinned iterator performs this arithmetic in uint32_t.
            // Preserve its defined wrapping before masking to the IB capacity.
            const triangle = (step *% step +% step) / 2;
            const position = @as(usize, initial +% triangle) & mask;
            const prior_index = buckets[position];
            if (prior_index == empty) {
                buckets[position] = @intCast(key_index);
                break;
            }
            try addStringComparison(
                context,
                node,
                node_index,
                key_index,
                key,
                refs[@as(usize, prior_index) * 2],
                work,
            );
            step +%= 1;
        }
    }
}

fn addHashProbe(
    context: *ParseContext,
    node: c.mrz_artifact_node,
    node_index: usize,
    key_index: usize,
    hash_probes: *usize,
    per_hash_limit: usize,
    work: *HashWork,
) ParseError!void {
    hash_probes.* = checkedAdd(hash_probes.*, 1) catch
        return hashWorkLimit(context, node, node_index, key_index);
    work.total_probes = checkedAdd(work.total_probes, 1) catch
        return hashWorkLimit(context, node, node_index, key_index);
    if (hash_probes.* > per_hash_limit or work.total_probes > max_capsule_hash_probes) {
        return hashWorkLimit(context, node, node_index, key_index);
    }
}

fn addStringComparison(
    context: *ParseContext,
    node: c.mrz_artifact_node,
    node_index: usize,
    key_index: usize,
    key: c.mrz_artifact_ref,
    prior: c.mrz_artifact_ref,
    work: *HashWork,
) ParseError!void {
    const key_normalized = parsedHashKey(context, key) orelse return;
    const prior_normalized = parsedHashKey(context, prior) orelse return;
    if (key_normalized.kind != .string or prior_normalized.kind != .string or
        key_normalized.bytes.len != prior_normalized.bytes.len)
    {
        return;
    }
    work.string_comparison_bytes = checkedAdd(
        work.string_comparison_bytes,
        key_normalized.bytes.len,
    ) catch return hashWorkLimit(context, node, node_index, key_index);
    if (work.string_comparison_bytes > max_string_comparison_bytes) {
        return hashWorkLimit(context, node, node_index, key_index);
    }
}

fn hashWorkLimit(
    context: *ParseContext,
    node: c.mrz_artifact_node,
    node_index: usize,
    key_index: usize,
) ParseError {
    const key_edge = @as(usize, node.edge_offset) + key_index * 2;
    const offset = if (key_edge < context.edge_offsets.len)
        context.edge_offsets[key_edge]
    else
        artifact.state_prelude_fixed_len;
    return parseLimit(context, offset, .{
        .node_id = @intCast(node_index),
        .kind = .hash_key,
        .index = key_index,
    });
}

fn hashTableCapacity(pair_count: usize) error{Overflow}!usize {
    std.debug.assert(pair_count > hash_array_max_entries);
    var capacity: usize = 1;
    while (capacity <= pair_count) capacity = try checkedMul(capacity, 2);
    const upper_bound = (capacity >> 2) | (capacity >> 1);
    if (pair_count > upper_bound) capacity = try checkedMul(capacity, 2);
    return capacity;
}

fn mixedHashCode(context: *const ParseContext, key: c.mrz_artifact_ref) u32 {
    const base: u32 = switch (key.tag) {
        c.MRZ_ARTIFACT_REF_I64 => @truncate(key.payload),
        c.MRZ_ARTIFACT_REF_F64 => blk: {
            const value: f64 = @bitCast(key.payload);
            if (value == 0) break :blk 0;
            var bits = key.payload;
            break :blk fnv1(std.mem.asBytes(&bits));
        },
        c.MRZ_ARTIFACT_REF_SYMBOL => fnv1(refBytes(key)),
        c.MRZ_ARTIFACT_REF_NODE => fnv1(nodeBytes(context.nodes[@intCast(key.payload)])),
        else => unreachable,
    };
    return base ^ (base << 2) ^ (base >> 2);
}

fn fnv1(bytes: []const u8) u32 {
    var hash: u32 = 0x811c9dc5;
    for (bytes) |byte| {
        hash *%= 0x01000193;
        hash ^= byte;
    }
    return hash;
}

const ParsedHashKey = struct {
    kind: Kind,
    bits: u64 = 0,
    bytes: []const u8 = &.{},

    const Kind = enum(u8) {
        integer,
        float,
        symbol,
        string,
    };
};

const ParsedHashKeyContext = struct {
    pub fn hash(_: ParsedHashKeyContext, key: ParsedHashKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const kind_byte = [_]u8{@backingInt(key.kind)};
        hasher.update(&kind_byte);
        switch (key.kind) {
            .integer, .float => hasher.update(std.mem.asBytes(&key.bits)),
            .symbol, .string => hasher.update(key.bytes),
        }
        return hasher.final();
    }

    pub fn eql(_: ParsedHashKeyContext, a: ParsedHashKey, b: ParsedHashKey) bool {
        if (a.kind != b.kind) return false;
        return switch (a.kind) {
            .integer => a.bits == b.bits,
            // IEEE equality gives mruby's required +0 == -0 and NaN != NaN.
            .float => @as(f64, @bitCast(a.bits)) == @as(f64, @bitCast(b.bits)),
            .symbol, .string => std.mem.eql(u8, a.bytes, b.bytes),
        };
    }
};

fn parsedHashKey(context: *const ParseContext, key: c.mrz_artifact_ref) ?ParsedHashKey {
    return switch (key.tag) {
        c.MRZ_ARTIFACT_REF_I64 => .{ .kind = .integer, .bits = key.payload },
        c.MRZ_ARTIFACT_REF_F64 => blk: {
            const value: f64 = @bitCast(key.payload);
            // Equal keys must hash alike. Canonicalize both zero signs for
            // the host-side duplicate map without changing their wire bits.
            break :blk .{ .kind = .float, .bits = if (value == 0) 0 else key.payload };
        },
        c.MRZ_ARTIFACT_REF_SYMBOL => .{
            .kind = .symbol,
            .bytes = refBytes(key),
        },
        c.MRZ_ARTIFACT_REF_NODE => blk: {
            if (key.payload >= context.nodes.len) break :blk null;
            const node = context.nodes[@intCast(key.payload)];
            if (node.kind != c.MRZ_ARTIFACT_NODE_STRING or
                node.flags & c.MRZ_ARTIFACT_NODE_FROZEN == 0)
            {
                break :blk null;
            }
            break :blk .{ .kind = .string, .bytes = nodeBytes(node) };
        },
        else => null,
    };
}

fn refBytes(ref: c.mrz_artifact_ref) []const u8 {
    if (ref.length == 0) return &.{};
    const ptr: [*]const u8 = @ptrFromInt(ref.payload);
    return ptr[0..ref.length];
}

fn nodeBytes(node: c.mrz_artifact_node) []const u8 {
    if (node.bytes_len == 0) return &.{};
    return node.bytes_ptr.?[0..node.bytes_len];
}

pub fn materialize(mrb: *c.mrb_state, graph: *const ParsedGraph) MaterializeOutcome {
    const normalized = graph.cGraph();
    var result: c.mrz_artifact_materialize_result = undefined;
    c.mrz_artifact_materialize(mrb, &normalized, &result);
    return switch (result.status) {
        c.MRZ_ARTIFACT_MATERIALIZE_OK => .{ .ok = .{
            .value = result.value,
            .arena_roots = result.arena_roots,
        } },
        c.MRZ_ARTIFACT_MATERIALIZE_INVALID => .invalid,
        c.MRZ_ARTIFACT_MATERIALIZE_OOM => .out_of_memory,
        else => .unexpected,
    };
}

fn exportLimit(context: *ExportContext, value: c.mrb_value, site: EdgeSite) ExportError {
    setExportFailure(context.failure, .capsule_limit_exceeded, c.mrz_type(value), site);
    return error.CapsuleLimitExceeded;
}

fn exportUnsupported(
    context: *ExportContext,
    comptime err: ExportError,
    kind: FailureKind,
    value: c.mrb_value,
    site: EdgeSite,
) ExportError {
    setExportFailure(context.failure, kind, c.mrz_type(value), site);
    return err;
}

fn parseInvalid(context: *ParseContext, payload_offset: usize, site: EdgeSite) ParseError {
    setParseFailure(context.failure, .invalid_artifact, payload_offset, site);
    return error.InvalidArtifact;
}

fn parseLimit(context: *ParseContext, payload_offset: usize, site: EdgeSite) ParseError {
    setParseFailure(context.failure, .capsule_limit_exceeded, payload_offset, site);
    return error.CapsuleLimitExceeded;
}

fn clearFailure(failure: ?*Failure) void {
    if (failure) |value| value.clear();
}

fn setExportFailure(
    failure: ?*Failure,
    kind: FailureKind,
    value_type: ?c.mrb_vtype,
    site: EdgeSite,
) void {
    const target = failure orelse return;
    target.clear();
    target.kind = kind;
    target.value_type = value_type;
    writePath(target, site);
}

fn setParseFailure(
    failure: ?*Failure,
    kind: FailureKind,
    payload_offset: usize,
    site: EdgeSite,
) void {
    const target = failure orelse return;
    target.clear();
    target.kind = kind;
    target.encoded_offset = checkedAdd(artifact.envelope_header_len, payload_offset) catch null;
    writePath(target, site);
}

fn writePath(failure: *Failure, site: EdgeSite) void {
    const rendered = switch (site.kind) {
        .root => std.fmt.bufPrint(&failure.path_buffer, "$", .{}),
        .node => std.fmt.bufPrint(&failure.path_buffer, "$#{d}", .{site.node_id.?}),
        .array_element => std.fmt.bufPrint(&failure.path_buffer, "$#{d}[{d}]", .{ site.node_id.?, site.index }),
        .hash_key => std.fmt.bufPrint(&failure.path_buffer, "$#{d}.key[{d}]", .{ site.node_id.?, site.index }),
        .hash_value => std.fmt.bufPrint(&failure.path_buffer, "$#{d}.value[{d}]", .{ site.node_id.?, site.index }),
        .hash_default => std.fmt.bufPrint(&failure.path_buffer, "$#{d}.default", .{site.node_id.?}),
    } catch {
        failure.path_buffer[0] = '$';
        failure.path_len = 1;
        failure.path_truncated = true;
        return;
    };
    failure.path_len = @intCast(rendered.len);
}

fn checkedAdd(a: usize, b: usize) error{Overflow}!usize {
    return std.math.add(usize, a, b);
}

fn checkedMul(a: usize, b: usize) error{Overflow}!usize {
    return std.math.mul(usize, a, b);
}

fn addFrameBytes(a: usize, b: usize) artifact.FramingError!usize {
    return checkedAdd(a, b) catch error.ArtifactLimitExceeded;
}

test {
    std.testing.refAllDecls(@This());
}

test "StateCapsule parser normalizes a canonical scalar root" {
    const allocator = std.testing.allocator;
    var payload: [17]u8 = undefined;
    var writer = artifact.Writer.init(&payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 0,
        .edge_count = 0,
        .root = .{ .integer = -42 },
    });
    try writer.finish();
    var capsule = try artifact.wrapState(allocator, &payload, .{});
    defer capsule.deinit(allocator);

    var graph = try parse(allocator, capsule.view(), .{}, null);
    defer graph.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), graph.nodes.len);
    try std.testing.expectEqual(c.MRZ_ARTIFACT_REF_I64, graph.root.tag);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -42))), graph.root.payload);
}

test "StateCapsule parser rejects a dangling node reference" {
    const allocator = std.testing.allocator;
    var payload: [
        artifact.state_prelude_fixed_len + 5 +
            artifact.node_record_header_len + 4 + 5
    ]u8 = undefined;
    var writer = artifact.Writer.init(&payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 1,
        .edge_count = 1,
        .root = .{ .node_ref = 0 },
    });
    try artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .array,
        .flags = 0,
        .body_len = 4 + 5,
    });
    try writer.writeU32(1);
    try artifact.writeValueRef(&writer, .{ .node_ref = 1 });
    try writer.finish();
    var capsule = try artifact.wrapState(allocator, &payload, .{});
    defer capsule.deinit(allocator);

    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidArtifact, parse(allocator, capsule.view(), .{}, &failure));
    try std.testing.expectEqual(FailureKind.invalid_artifact, failure.kind);
    try std.testing.expectEqualStrings("$#0[0]", failure.path());
}

test "StateCapsule parser rejects an unreachable node record" {
    const allocator = std.testing.allocator;
    var payload: [
        artifact.state_prelude_fixed_len + 5 +
            2 * (artifact.node_record_header_len + 4)
    ]u8 = undefined;
    var writer = artifact.Writer.init(&payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 2,
        .edge_count = 0,
        .root = .{ .node_ref = 0 },
    });
    inline for (0..2) |id| {
        try artifact.writeNodeRecordHeader(&writer, .{
            .id = id,
            .kind = .string,
            .flags = 0,
            .body_len = 4,
        });
        try writer.writeU32(0);
    }
    try writer.finish();
    var capsule = try artifact.wrapState(allocator, &payload, .{});
    defer capsule.deinit(allocator);

    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidArtifact, parse(allocator, capsule.view(), .{}, &failure));
    try std.testing.expectEqual(FailureKind.invalid_artifact, failure.kind);
    try std.testing.expectEqualStrings("$#1", failure.path());
}

test "StateCapsule parser rejects node records outside ID order" {
    const allocator = std.testing.allocator;
    var payload: [
        artifact.state_prelude_fixed_len + 5 +
            (artifact.node_record_header_len + 4) +
            (artifact.node_record_header_len + 4 + 5)
    ]u8 = undefined;
    var writer = artifact.Writer.init(&payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 2,
        .edge_count = 1,
        .root = .{ .node_ref = 0 },
    });
    try artifact.writeNodeRecordHeader(&writer, .{
        .id = 1,
        .kind = .string,
        .flags = 0,
        .body_len = 4,
    });
    try writer.writeU32(0);
    try artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .array,
        .flags = 0,
        .body_len = 4 + 5,
    });
    try writer.writeU32(1);
    try artifact.writeValueRef(&writer, .{ .node_ref = 1 });
    try writer.finish();
    var capsule = try artifact.wrapState(allocator, &payload, .{});
    defer capsule.deinit(allocator);

    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidArtifact, parse(allocator, capsule.view(), .{}, &failure));
    try std.testing.expectEqual(FailureKind.invalid_artifact, failure.kind);
    try std.testing.expectEqualStrings("$#0", failure.path());
}

test "StateCapsule parser rejects a mutable String Hash key" {
    const allocator = std.testing.allocator;
    const key = "key";
    var payload: [
        artifact.state_prelude_fixed_len + 5 +
            artifact.node_record_header_len + 4 + 5 + 1 +
            artifact.node_record_header_len + 4 + key.len
    ]u8 = undefined;
    var writer = artifact.Writer.init(&payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 2,
        .edge_count = 2,
        .root = .{ .node_ref = 0 },
    });
    try artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .hash,
        .flags = 0,
        .body_len = 4 + 5 + 1,
    });
    try writer.writeU32(1);
    try artifact.writeValueRef(&writer, .{ .node_ref = 1 });
    try artifact.writeValueRef(&writer, .{ .nil = {} });
    try artifact.writeNodeRecordHeader(&writer, .{
        .id = 1,
        .kind = .string,
        .flags = 0,
        .body_len = 4 + key.len,
    });
    try writer.writeU32(key.len);
    try writer.writeBytes(key);
    try writer.finish();
    var capsule = try artifact.wrapState(allocator, &payload, .{});
    defer capsule.deinit(allocator);

    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidArtifact, parse(allocator, capsule.view(), .{}, &failure));
    try std.testing.expectEqual(FailureKind.invalid_artifact, failure.kind);
    try std.testing.expectEqualStrings("$#0.key[0]", failure.path());
}

test "StateCapsule parser rejects semantic duplicate float hash keys" {
    const allocator = std.testing.allocator;
    // prelude + root ref + node header + pair count + four scalar refs
    var payload: [8 + 5 + 12 + 4 + (9 * 4)]u8 = undefined;
    var writer = artifact.Writer.init(&payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 1,
        .edge_count = 4,
        .root = .{ .node_ref = 0 },
    });
    try artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .hash,
        .flags = 0,
        .body_len = 4 + (9 * 4),
    });
    try writer.writeU32(2);
    try artifact.writeValueRef(&writer, .{ .float = @bitCast(@as(f64, 0.0)) });
    try artifact.writeValueRef(&writer, .{ .integer = 1 });
    try artifact.writeValueRef(&writer, .{ .float = @bitCast(@as(f64, -0.0)) });
    try artifact.writeValueRef(&writer, .{ .integer = 2 });
    try writer.finish();
    var capsule = try artifact.wrapState(allocator, &payload, .{});
    defer capsule.deinit(allocator);

    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidArtifact, parse(allocator, capsule.view(), .{}, &failure));
    try std.testing.expectEqual(FailureKind.duplicate_hash_key, failure.kind);
    try std.testing.expectEqualStrings("$#0.key[1]", failure.path());
}

test "StateCapsule parser rejects duplicate full-width integer hash keys" {
    const allocator = std.testing.allocator;
    var payload: [8 + 5 + 12 + 4 + 9 + 1 + 9 + 1]u8 = undefined;
    var writer = artifact.Writer.init(&payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 1,
        .edge_count = 4,
        .root = .{ .node_ref = 0 },
    });
    try artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .hash,
        .flags = 0,
        .body_len = 4 + 9 + 1 + 9 + 1,
    });
    try writer.writeU32(2);
    try artifact.writeValueRef(&writer, .{ .integer = std.math.maxInt(i64) });
    try artifact.writeValueRef(&writer, .{ .nil = {} });
    try artifact.writeValueRef(&writer, .{ .integer = std.math.maxInt(i64) });
    try artifact.writeValueRef(&writer, .{ .nil = {} });
    try writer.finish();
    var capsule = try artifact.wrapState(allocator, &payload, .{});
    defer capsule.deinit(allocator);

    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidArtifact, parse(allocator, capsule.view(), .{}, &failure));
    try std.testing.expectEqual(FailureKind.duplicate_hash_key, failure.kind);
}

test "StateCapsule parser rejects symbols mruby cannot intern" {
    const allocator = std.testing.allocator;
    const symbol_len = std.math.maxInt(u16);
    const payload_len = artifact.state_prelude_fixed_len + 5 + symbol_len;
    const symbol = try allocator.alloc(u8, symbol_len);
    defer allocator.free(symbol);
    @memset(symbol, 's');
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    var writer = artifact.Writer.init(payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 0,
        .edge_count = 0,
        .root = .{ .symbol = symbol },
    });
    try writer.finish();
    var capsule = try artifact.wrapState(allocator, payload, .{});
    defer capsule.deinit(allocator);

    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidArtifact, parse(allocator, capsule.view(), .{}, &failure));
    try std.testing.expectEqual(FailureKind.invalid_artifact, failure.kind);
}

fn integerCollisionCapsule(
    allocator: std.mem.Allocator,
    pair_count: usize,
) !artifact.StateCapsule {
    const payload_len = artifact.state_prelude_fixed_len + 5 +
        artifact.node_record_header_len + 4 + pair_count * (9 + 1);
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    var writer = artifact.Writer.init(payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 1,
        .edge_count = @intCast(pair_count * 2),
        .root = .{ .node_ref = 0 },
    });
    try artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .hash,
        .flags = 0,
        .body_len = @intCast(4 + pair_count * (9 + 1)),
    });
    try writer.writeU32(@intCast(pair_count));
    for (0..pair_count) |index| {
        // Distinct signed-i64 values with identical low 32 bits exercise the
        // exact patched Integer hash and triangular-probe admission bound.
        const integer = @as(i64, @intCast(index)) * 0x1_0000_0000;
        try artifact.writeValueRef(&writer, .{ .integer = integer });
        try artifact.writeValueRef(&writer, .{ .nil = {} });
    }
    try writer.finish();
    return artifact.wrapState(allocator, payload, .{});
}

fn symbolCorpusCapsule(
    allocator: std.mem.Allocator,
    pair_count: usize,
) !artifact.StateCapsule {
    const symbol_len = 8;
    const symbol_ref_len = 5 + symbol_len;
    const payload_len = artifact.state_prelude_fixed_len + 5 +
        artifact.node_record_header_len + 4 + pair_count * (symbol_ref_len + 1);
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    var writer = artifact.Writer.init(payload);
    try artifact.writeStatePrelude(&writer, .{
        .node_count = 1,
        .edge_count = @intCast(pair_count * 2),
        .root = .{ .node_ref = 0 },
    });
    try artifact.writeNodeRecordHeader(&writer, .{
        .id = 0,
        .kind = .hash,
        .flags = 0,
        .body_len = @intCast(4 + pair_count * (symbol_ref_len + 1)),
    });
    try writer.writeU32(@intCast(pair_count));
    for (0..pair_count) |index| {
        std.debug.assert(index < 100);
        var name = "symbol00".*;
        name[6] = '0' + @as(u8, @intCast(index / 10));
        name[7] = '0' + @as(u8, @intCast(index % 10));
        try artifact.writeValueRef(&writer, .{ .symbol = &name });
        try artifact.writeValueRef(&writer, .{ .nil = {} });
    }
    try writer.finish();
    return artifact.wrapState(allocator, payload, .{});
}

test "StateCapsule Hash work admits the exact integer-collision boundary" {
    const allocator = std.testing.allocator;
    // 23 colliding keys need 1+...+23 = 276 probes, exactly 12*n.
    var capsule = try integerCollisionCapsule(allocator, 23);
    defer capsule.deinit(allocator);
    var graph = try parse(allocator, capsule.view(), .{}, null);
    defer graph.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.len);
}

test "StateCapsule Hash work rejects an excessive integer collision chain" {
    const allocator = std.testing.allocator;
    // The 24th key raises cumulative work from 276 to 300, past 12*n=288.
    var capsule = try integerCollisionCapsule(allocator, 24);
    defer capsule.deinit(allocator);
    var failure: Failure = .{};
    try std.testing.expectError(error.CapsuleLimitExceeded, parse(
        allocator,
        capsule.view(),
        .{},
        &failure,
    ));
    try std.testing.expectEqual(FailureKind.capsule_limit_exceeded, failure.kind);
    try std.testing.expectEqualStrings("$#0.key[23]", failure.path());
    try std.testing.expect(failure.encoded_offset != null);
}

test "StateCapsule Hash pair hard ceiling is exact and capsule-wide" {
    try std.testing.expect(hashPairOverflowIndex(0, max_hash_pairs) == null);
    try std.testing.expectEqual(
        @as(?usize, max_hash_pairs),
        hashPairOverflowIndex(0, max_hash_pairs + 1),
    );
    try std.testing.expectEqual(
        @as(?usize, 1),
        hashPairOverflowIndex(max_hash_pairs - 1, 2),
    );
}

test "StateCapsule Hash pair hard ceiling reports the first excess key" {
    const allocator = std.testing.allocator;
    var capsule = try integerCollisionCapsule(allocator, max_hash_pairs + 1);
    defer capsule.deinit(allocator);
    var failure: Failure = .{};
    try std.testing.expectError(error.CapsuleLimitExceeded, parse(
        allocator,
        capsule.view(),
        .{ .limits = .{ .max_total_edges = (max_hash_pairs + 1) * 2 } },
        &failure,
    ));
    try std.testing.expectEqual(FailureKind.capsule_limit_exceeded, failure.kind);
    try std.testing.expectEqualStrings("$#0.key[250000]", failure.path());
    try std.testing.expect(failure.encoded_offset != null);
}

test "StateCapsule Hash work accepts a Symbol-heavy name-hashed corpus" {
    const allocator = std.testing.allocator;
    var capsule = try symbolCorpusCapsule(allocator, 64);
    defer capsule.deinit(allocator);
    var graph = try parse(allocator, capsule.view(), .{}, null);
    defer graph.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 128), graph.edges.len);
}

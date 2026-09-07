//! Canonical arithmetic corpus. Output deliberately excludes runtime identities.
const std = @import("std");
const mruby = @import("mruby");
pub const manifest = @import("integer64_manifest");
pub const contract = @import("integer64_contract");
const Turn = mruby.strict.Turn;
const Worker = mruby.strict.Worker;
const data = mruby.effect.data;
const artifact = mruby.artifact;
const View = artifact.StateCapsuleView;
const hi = std.math.maxInt(i64);
const lo = std.math.minInt(i64);
const Case = struct { id: []const u8, mode: []const u8, x: i64, y: i64 = 0, value: ?data.Value = null, exception: ?[]const u8 = null };
const less = data.Value{ .array = &.{ .{ .boolean = true }, .{ .boolean = true }, .{ .boolean = false }, .{ .boolean = false }, .{ .boolean = false }, .{ .integer = -1 } } };
const greater = data.Value{ .array = &.{ .{ .boolean = false }, .{ .boolean = false }, .{ .boolean = true }, .{ .boolean = true }, .{ .boolean = false }, .{ .integer = 1 } } };
const equal = data.Value{ .array = &.{ .{ .boolean = false }, .{ .boolean = true }, .{ .boolean = false }, .{ .boolean = true }, .{ .boolean = true }, .{ .integer = 0 } } };
pub const cases = [_]Case{
    .{ .id = "array-custom-compare-min", .mode = "array_compare", .x = lo, .value = .{ .integer = -1 } },
    .{ .id = "sort-fullwidth-block", .mode = "sort_block", .x = hi, .y = lo, .value = .{ .array = &.{ .{ .integer = lo }, .{ .integer = -1 }, .{ .integer = 0 }, .{ .integer = 1 }, .{ .integer = hi }, .{ .integer = hi } } } },
    .{ .id = "sort-fullwidth", .mode = "sort", .x = hi, .y = lo, .value = .{ .array = &.{ .{ .integer = lo }, .{ .integer = -1 }, .{ .integer = 0 }, .{ .integer = 1 }, .{ .integer = hi }, .{ .integer = hi } } } },
    .{ .id = "compare-min-zero", .mode = "compare", .x = lo, .y = 0, .value = less },
    .{ .id = "compare-min-max", .mode = "compare", .x = lo, .y = hi, .value = less },
    .{ .id = "compare-max-max", .mode = "compare", .x = hi, .y = hi, .value = equal },
    .{ .id = "compare-zero-min", .mode = "compare", .x = 0, .y = lo, .value = greater },
    .{ .id = "compare-native-min-zero", .mode = "compare_native", .x = lo, .y = 0, .value = less },
    .{ .id = "compare-native-min-max", .mode = "compare_native", .x = lo, .y = hi, .value = less },
    .{ .id = "compare-native-max-max", .mode = "compare_native", .x = hi, .y = hi, .value = equal },
    .{ .id = "compare-native-zero-min", .mode = "compare_native", .x = 0, .y = lo, .value = greater },
    .{ .id = "min-less-zero", .mode = "less", .x = lo, .y = 0, .value = .{ .boolean = true } },
    .{ .id = "literal-max", .mode = "literal_max", .x = 0, .value = .{ .integer = hi } },
    .{ .id = "parse-min", .mode = "from_string_min", .x = 0, .value = .{ .integer = lo } },
    .{ .id = "to-i-min", .mode = "to_i_min", .x = 0, .value = .{ .integer = lo } },
    .{ .id = "parse-binary-min", .mode = "from_string_binary_min", .x = 0, .value = .{ .integer = lo } },
    .{ .id = "parse-over-max", .mode = "from_string_over_max", .x = 0, .exception = "RangeError" },
    .{ .id = "parse-under-min", .mode = "from_string_under_min", .x = 0, .exception = "RangeError" },
    .{ .id = "to-i-min-suffix", .mode = "to_i_min_suffix", .x = 0, .exception = "RangeError" },
    .{ .id = "round-min-minus19", .mode = "round", .x = lo, .y = -19, .exception = "RangeError" },
    .{ .id = "truncate-min-minus19", .mode = "truncate", .x = lo, .y = -19, .value = .{ .integer = 0 } },
    .{ .id = "ceil-min-minus19", .mode = "ceil", .x = lo, .y = -19, .value = .{ .integer = 0 } },
    .{ .id = "floor-min-minus19", .mode = "floor", .x = lo, .y = -19, .exception = "RangeError" },
    .{ .id = "round-min-minus20", .mode = "round", .x = lo, .y = -20, .value = .{ .integer = 0 } },
    .{ .id = "literal-min", .mode = "literal_min", .x = 0, .value = .{ .integer = lo } },
    .{ .id = "literal-left", .mode = "literal_left", .x = 0, .value = .{ .integer = lo } },
    .{ .id = "literal-right", .mode = "literal_right", .x = 0, .value = .{ .integer = -4 } },
    .{ .id = "literal-negative-shift", .mode = "literal_negative_shift", .x = 0, .value = .{ .integer = -4 } },
    .{ .id = "literal-overflow", .mode = "literal_overflow", .x = 0, .exception = "RangeError" },
    .{ .id = "max", .mode = "identity", .x = hi, .value = .{ .integer = hi } },
    .{ .id = "min", .mode = "identity", .x = lo, .value = .{ .integer = lo } },
    .{ .id = "add-boundary", .mode = "add", .x = hi - 1, .y = 1, .value = .{ .integer = hi } },
    .{ .id = "sub-boundary", .mode = "sub", .x = lo + 1, .y = 1, .value = .{ .integer = lo } },
    .{ .id = "mul-boundary", .mode = "mul", .x = lo / 2, .y = 2, .value = .{ .integer = lo } },
    .{ .id = "div-floor", .mode = "div", .x = -7, .y = 3, .value = .{ .integer = -3 } },
    .{ .id = "div-native", .mode = "div_native", .x = 7, .y = -3, .value = .{ .integer = -3 } },
    .{ .id = "idiv-floor", .mode = "idiv", .x = -7, .y = 3, .value = .{ .integer = -3 } },
    .{ .id = "mod-sign", .mode = "mod", .x = 7, .y = -3, .value = .{ .integer = -2 } },
    .{ .id = "mod-min", .mode = "mod", .x = lo, .y = -1, .value = .{ .integer = 0 } },
    .{ .id = "divmod-sign", .mode = "divmod", .x = -7, .y = 3, .value = .{ .array = &.{ .{ .integer = -3 }, .{ .integer = 2 } } } },
    .{ .id = "left-min", .mode = "left", .x = -1, .y = 63, .value = .{ .integer = lo } },
    .{ .id = "right-large-positive", .mode = "right", .x = hi, .y = hi, .value = .{ .integer = 0 } },
    .{ .id = "right-large-negative", .mode = "right", .x = lo, .y = hi, .value = .{ .integer = -1 } },
    .{ .id = "left-negative-count", .mode = "left", .x = -7, .y = -1, .value = .{ .integer = -4 } },
    .{ .id = "right-negative-count", .mode = "right", .x = -7, .y = -2, .value = .{ .integer = -28 } },
    .{ .id = "left-min-count", .mode = "left", .x = -7, .y = lo, .value = .{ .integer = -1 } },
    .{ .id = "zero-right-min-count", .mode = "right", .x = 0, .y = lo, .value = .{ .integer = 0 } },
    .{ .id = "power-min", .mode = "power", .x = -2, .y = 63, .value = .{ .integer = lo } },
    .{ .id = "power-zero", .mode = "power", .x = 0, .y = 0, .value = .{ .integer = 1 } },
    .{ .id = "floor-exact", .mode = "floor", .x = -100, .y = -2, .value = .{ .integer = -100 } },
    .{ .id = "ceil-exact", .mode = "ceil", .x = 100, .y = -2, .value = .{ .integer = 100 } },
    .{ .id = "floor-negative", .mode = "floor", .x = -101, .y = -2, .value = .{ .integer = -200 } },
    .{ .id = "ceil-negative", .mode = "ceil", .x = -101, .y = -2, .value = .{ .integer = -100 } },
    .{ .id = "round-tie", .mode = "round", .x = -150, .y = -2, .value = .{ .integer = -200 } },
    .{ .id = "truncate-negative", .mode = "truncate", .x = -199, .y = -2, .value = .{ .integer = -100 } },
    .{ .id = "round-precise", .mode = "round", .x = 9007199254740995, .y = -1, .value = .{ .integer = 9007199254741000 } },
    .{ .id = "decimal-min", .mode = "decimal", .x = lo, .value = .{ .string = "-9223372036854775808" } },
    .{ .id = "binary-min", .mode = "binary", .x = lo, .value = .{ .string = "-1000000000000000000000000000000000000000000000000000000000000000" } },
    .{ .id = "reverse-compare-min", .mode = "reverse_compare", .x = 1, .y = lo, .value = .{ .integer = 1 } },
    .{ .id = "bits", .mode = "bits", .x = -1, .y = hi, .value = .{ .array = &.{ .{ .integer = hi }, .{ .integer = -1 }, .{ .integer = lo }, .{ .integer = 0 } } } },
    .{ .id = "float-unavailable", .mode = "float_methods", .x = 1, .value = .{ .array = &.{ .{ .boolean = false }, .{ .boolean = false }, .{ .boolean = false } } } },
    .{ .id = "rescue-overflow", .mode = "rescue_overflow", .x = hi, .y = 1, .value = .{ .integer = 42 } },
    .{ .id = "rescue-zero", .mode = "rescue_zero", .x = 1, .y = 0, .value = .{ .integer = 43 } },
    .{ .id = "rescue-to-f", .mode = "rescue_to_f", .x = 1, .value = .{ .integer = 44 } },
    .{ .id = "rescue-Float", .mode = "rescue_float", .x = 1, .value = .{ .integer = 45 } },
    .{ .id = "add-overflow", .mode = "add", .x = hi, .y = 1, .exception = "RangeError" },
    .{ .id = "add-native-overflow", .mode = "add_native", .x = hi, .y = 1, .exception = "RangeError" },
    .{ .id = "sub-overflow", .mode = "sub", .x = lo, .y = 1, .exception = "RangeError" },
    .{ .id = "sub-native-overflow", .mode = "sub_native", .x = lo, .y = 1, .exception = "RangeError" },
    .{ .id = "mul-overflow", .mode = "mul", .x = hi, .y = 2, .exception = "RangeError" },
    .{ .id = "mul-native-overflow", .mode = "mul_native", .x = hi, .y = 2, .exception = "RangeError" },
    .{ .id = "neg-overflow", .mode = "neg", .x = lo, .exception = "RangeError" },
    .{ .id = "neg-native-overflow", .mode = "neg_native", .x = lo, .exception = "RangeError" },
    .{ .id = "abs-overflow", .mode = "abs", .x = lo, .exception = "RangeError" },
    .{ .id = "div-overflow", .mode = "div", .x = lo, .y = -1, .exception = "RangeError" },
    .{ .id = "div-native-overflow", .mode = "div_native", .x = lo, .y = -1, .exception = "RangeError" },
    .{ .id = "divmod-overflow", .mode = "divmod", .x = lo, .y = -1, .exception = "RangeError" },
    .{ .id = "zero-div", .mode = "div", .x = 0, .y = 0, .exception = "ZeroDivisionError" },
    .{ .id = "zero-mod", .mode = "mod", .x = 0, .y = 0, .exception = "ZeroDivisionError" },
    .{ .id = "left-overflow", .mode = "left", .x = 1, .y = 63, .exception = "RangeError" },
    .{ .id = "right-min-count", .mode = "right", .x = 1, .y = lo, .exception = "RangeError" },
    .{ .id = "power-overflow", .mode = "power", .x = 2, .y = 63, .exception = "RangeError" },
    .{ .id = "power-negative", .mode = "power", .x = 1, .y = -1, .exception = "RangeError" },
    .{ .id = "round-overflow", .mode = "round", .x = hi, .y = -1, .exception = "RangeError" },
    .{ .id = "ceil-overflow", .mode = "ceil", .x = hi, .y = -1, .exception = "RangeError" },
    .{ .id = "floor-overflow", .mode = "floor", .x = lo, .y = -1, .exception = "RangeError" },
    .{ .id = "hidden-overflow", .mode = "hidden_add", .x = hi, .y = 1, .exception = "RangeError" },
};

pub const Host = struct {
    begins: usize = 0,
    stages: usize = 0,
    reads: usize = 0,
    commits: usize = 0,
    discards: usize = 0,
    pending: usize = 0,
    durable: usize = 0,
    response: ?View = null,
    fn from(raw: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(raw.?));
    }
    fn stage(raw: ?*anyopaque, allocator: std.mem.Allocator, arguments: View) !mruby.effect.DataOutcome {
        const self = from(raw);
        self.stages += 1;
        self.pending += 1;
        var document = try data.Document.decode(allocator, arguments, 4096);
        defer document.deinit();
        return .{ .returned = try data.encodeRef(allocator, try document.root().at(0), 4096) };
    }
    fn read(raw: ?*anyopaque, allocator: std.mem.Allocator, _: View) !mruby.effect.DataOutcome {
        const self = from(raw);
        self.reads += 1;
        return .{ .returned = if (self.response) |response| .{ .encoded = try allocator.dupe(u8, response.bytes) } else try data.encode(allocator, .{ .integer = 7 }, 4096) };
    }
    fn begin(raw: ?*anyopaque) !void {
        from(raw).begins += 1;
    }
    fn commit(raw: ?*anyopaque, _: View, _: []const u8) !Turn.CommitOutcome {
        const self = from(raw);
        self.commits += 1;
        self.durable += self.pending;
        self.pending = 0;
        return .committed;
    }
    fn discard(raw: ?*anyopaque) void {
        const self = from(raw);
        self.discards += 1;
        self.pending = 0;
    }
    pub fn transaction(self: *Host) Turn.Transaction {
        return .{ .context = self, .begin = begin, .commit = commit, .discard = discard };
    }
    pub fn bindings(self: *Host) [2]mruby.effect.DataBinding {
        return .{
            .{ .name = "stage.write", .handler = stage, .context = self },
            .{ .name = "source.read", .handler = read, .context = self },
        };
    }
};
pub fn input(allocator: std.mem.Allocator, mode: []const u8, x: i64, y: i64) !artifact.StateCapsule {
    return data.encode(allocator, .{ .array = &.{ .{ .string = mode }, .{ .integer = x }, .{ .integer = y } } }, 4096);
}
pub fn request(state: View, argument: View) Turn.Request {
    return .{ .receiver = "IntegerCorpus", .state = state, .input = argument };
}
pub fn runCorpus(allocator: std.mem.Allocator, emit: bool) !void {
    var mismatches = false;
    var nil = try data.encode(allocator, .nil, 4096);
    defer nil.deinit(allocator);
    for (cases) |case| {
        var argument = try input(allocator, case.mode, case.x, case.y);
        defer argument.deinit(allocator);
        var host: Host = .{};
        const bindings = host.bindings();
        var diagnostic: Turn.Diagnostic = .{};
        var prepared = Turn.prepare(allocator, manifest, "app", contract.operations, request(nil.view(), argument.view()), .{ .bindings = &bindings, .transaction = host.transaction() }, .{ .allowed = contract.grants, .diagnostic = &diagnostic }) catch |err| {
            if (case.exception == null or err != error.RubyException or !std.mem.eql(u8, case.exception.?, diagnostic.className())) {
                std.debug.print("integer corpus {s}: unexpected {s} {s}: {s}\n", .{ case.id, @errorName(err), diagnostic.className(), diagnostic.messageText() });
                mismatches = true;
                continue;
            }
            if (host.begins != 1 or host.stages != 1 or host.discards != 1 or host.commits != 0 or host.pending != 0 or host.durable != 0) return error.CorpusTransactionMismatch;
            if (emit) std.debug.print("{s}\terror\t{s}\n", .{ case.id, diagnostic.className() });
            continue;
        };
        defer prepared.deinit();
        if (case.value == null) {
            std.debug.print("integer corpus {s}: unexpectedly succeeded\n", .{case.id});
            try emitCapsule(allocator, case.id, "unexpected-terminal", prepared.terminal().bytes);
            mismatches = true;
            continue;
        }
        var expected = try data.encode(allocator, .{ .array = &.{ case.value.?, .nil } }, 4096);
        defer expected.deinit(allocator);
        if (!std.mem.eql(u8, expected.encoded, prepared.terminal().bytes)) {
            std.debug.print("integer corpus {s}: wrong result\n", .{case.id});
            mismatches = true;
            continue;
        }
        try prepared.commit();
        if (host.begins != 1 or host.stages != 1 or host.discards != 0 or host.commits != 1 or host.pending != 0 or host.durable != 1) return error.CorpusTransactionMismatch;
        const receipt = try Turn.Receipt.decode(prepared.receipt(), .{});
        var trace = try mruby.effect.Trace.decode(allocator, receipt.trace, .{});
        defer trace.deinit();
        if (trace.len() != 1) return error.CorpusTraceMismatch;
        const record = trace.get(0).?;
        var expected_args = try data.encode(allocator, .{ .array = &.{.{ .integer = case.x }} }, 4096);
        defer expected_args.deinit(allocator);
        var expected_result = try data.encode(allocator, .{ .integer = case.x }, 4096);
        defer expected_result.deinit(allocator);
        if (!std.mem.eql(u8, record.name, "stage.write") or record.version != 1 or record.outcome != .returned or !std.mem.eql(u8, record.arguments, expected_args.encoded) or !std.mem.eql(u8, record.result, expected_result.encoded)) return error.CorpusTraceMismatch;
        if (emit) {
            try emitCapsule(allocator, case.id, "terminal", prepared.terminal().bytes);
            try emitCapsule(allocator, case.id, "stage.write.arguments", record.arguments);
            try emitCapsule(allocator, case.id, "stage.write.returned", record.result);
        }
    }
    if (mismatches) return error.CorpusMismatch;
}
fn emitCapsule(allocator: std.mem.Allocator, id: []const u8, part: []const u8, bytes: []const u8) !void {
    const hex = try allocator.alloc(u8, bytes.len * 2);
    defer allocator.free(hex);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        hex[2 * i] = digits[byte >> 4];
        hex[2 * i + 1] = digits[byte & 15];
    }
    std.debug.print("{s}\t{s}\t{s}\n", .{ id, part, hex });
}
pub fn main(init: std.process.Init) !void {
    try runCorpus(init.gpa, true);
}

//! presym_gen — port of mruby's `lib/mruby/presym.rb` scanner/emitter.
//!
//! Input: preprocessed C sources (`zig cc -E -P -DMRB_PRESYM_SCANNING`), in
//! which every presym-able macro invocation has expanded to a
//! `<@! "name" !@>` marker, followed by the output directory as the final
//! argument. Output: `<out-dir>/mruby/presym/{id.h,table.h}` plus
//! `<out-dir>/presym.txt` (the sorted symbol list, for debugging) and the raw
//! 32-byte `<out-dir>/presym.digest` compatibility input.
//!
//! Only internal consistency is required (see presym.rb): symbols are
//! deduplicated, sorted by (byte length, bytes), numbered from 1, and the
//! enum in id.h and the length/name tables in table.h are all generated from
//! that single ordering.

const std = @import("std");
const artifact_identity = @import("artifact_identity");

/// Operator symbol → enum suffix, mirroring `MRuby::Presym::OPERATORS`.
const operators = [_]struct { sym: []const u8, name: []const u8 }{
    .{ .sym = "!", .name = "not" },
    .{ .sym = "%", .name = "mod" },
    .{ .sym = "&", .name = "and" },
    .{ .sym = "*", .name = "mul" },
    .{ .sym = "+", .name = "add" },
    .{ .sym = "-", .name = "sub" },
    .{ .sym = "/", .name = "div" },
    .{ .sym = "<", .name = "lt" },
    .{ .sym = ">", .name = "gt" },
    .{ .sym = "^", .name = "xor" },
    .{ .sym = "`", .name = "tick" },
    .{ .sym = "|", .name = "or" },
    .{ .sym = "~", .name = "neg" },
    .{ .sym = "!=", .name = "neq" },
    .{ .sym = "!~", .name = "nmatch" },
    .{ .sym = "&&", .name = "andand" },
    .{ .sym = "**", .name = "pow" },
    .{ .sym = "+@", .name = "plus" },
    .{ .sym = "-@", .name = "minus" },
    .{ .sym = "<<", .name = "lshift" },
    .{ .sym = "<=", .name = "le" },
    .{ .sym = "==", .name = "eq" },
    .{ .sym = "=~", .name = "match" },
    .{ .sym = ">=", .name = "ge" },
    .{ .sym = ">>", .name = "rshift" },
    .{ .sym = "[]", .name = "aref" },
    .{ .sym = "||", .name = "oror" },
    .{ .sym = "<=>", .name = "cmp" },
    .{ .sym = "===", .name = "eqq" },
    .{ .sym = "[]=", .name = "aset" },
};

/// How a symbol maps to its `MRB_*SYM__*` enum entry, from `write_id_header`.
const Affixes = struct {
    prefix: []const u8 = "", // "", "GV", "CV", "IV"
    body: []const u8,
    suffix: []const u8 = "", // "", "_B", "_Q", "_E"
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = args.next() orelse return fatal("missing argv0", .{});

    var pp_paths: std.ArrayList([]const u8) = .empty;
    defer pp_paths.deinit(gpa);
    while (args.next()) |arg| try pp_paths.append(gpa, arg);
    if (pp_paths.items.len < 2)
        return fatal("usage: presym_gen <pp-file>... <out-dir>", .{});
    const out_dir = pp_paths.pop().?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var syms: std.array_hash_map.String(void) = .empty;
    for (pp_paths.items) |pp| {
        const data = cwd.readFileAlloc(io, pp, arena, .limited(1 << 30)) catch |err|
            return fatal("reading {s}: {s}", .{ pp, @errorName(err) });
        try scanMarkers(data, arena, &syms);
    }

    const list = syms.keys();
    std.mem.sort([]const u8, list, {}, symLessThan);
    const table_digest = artifact_identity.presymTableDigest(list);

    var id_h: Emitter = .init(arena);
    var table_h: Emitter = .init(arena);
    var txt: Emitter = .init(arena);

    try id_h.raw("enum mruby_presym {\n");
    for (list, 1..) |sym, num| {
        if (splitAffixes(sym)) |af| {
            try id_h.print("  MRB_{s}SYM{s}__{s} = {d},\n", .{ af.prefix, af.suffix, af.body, num });
        } else if (operatorName(sym)) |name| {
            try id_h.print("  MRB_OPSYM__{s} = {d},\n", .{ name, num });
        }
        try txt.print("{s}\n", .{sym});
    }
    try id_h.raw("};\n\n");
    try id_h.print("#define MRB_PRESYM_MAX {d}\n", .{list.len});

    try table_h.raw("static const uint16_t presym_length_table[] = {\n");
    for (list) |sym| {
        try table_h.print("  {d},\t/* {s} */\n", .{ sym.len, sym });
    }
    try table_h.raw("};\n\n");
    try table_h.raw("static const char * const presym_name_table[] = {\n");
    for (list) |sym| {
        try table_h.raw("  \"");
        try appendCEscaped(&table_h, sym);
        try table_h.raw("\",\n");
    }
    try table_h.raw("};\n");

    const presym_dir = try std.fmt.allocPrint(arena, "{s}/mruby/presym", .{out_dir});
    try cwd.createDirPath(io, presym_dir);
    try cwd.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/id.h", .{presym_dir}),
        .data = id_h.slice(),
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/table.h", .{presym_dir}),
        .data = table_h.slice(),
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/presym.txt", .{out_dir}),
        .data = txt.slice(),
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/presym.digest", .{out_dir}),
        .data = &table_digest,
    });
}

const Emitter = struct {
    buf: std.Io.Writer.Allocating,

    fn init(a: std.mem.Allocator) Emitter {
        return .{ .buf = .init(a) };
    }

    fn print(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
        try self.buf.writer.print(fmt, args);
    }

    fn raw(self: *Emitter, s: []const u8) !void {
        try self.buf.writer.writeAll(s);
    }

    fn byte(self: *Emitter, b: u8) !void {
        try self.buf.writer.writeByte(b);
    }

    fn slice(self: *Emitter) []const u8 {
        return self.buf.writer.buffer[0..self.buf.writer.end];
    }
};

fn fatal(comptime fmt: []const u8, args: anytype) error{Fatal} {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "presym_gen: " ++ fmt ++ "\n", args) catch "presym_gen: fatal error\n";
    std.debug.print("{s}", .{msg});
    return error.Fatal;
}

fn symLessThan(_: void, a: []const u8, b: []const u8) bool {
    return switch (std.math.order(a.len, b.len)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a, b) == .lt,
    };
}

/// Extract `<@! ... !@>` markers (single-line, matching Ruby's `.` semantics),
/// parse the C string literals inside each, unescape, and concatenate.
fn scanMarkers(data: []const u8, arena: std.mem.Allocator, syms: *std.array_hash_map.String(void)) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, "<@! ")) |start| {
        const body_start = start + "<@! ".len;
        const end = std.mem.indexOfPos(u8, data, body_start, " !@>") orelse break;
        const body = data[body_start..end];
        if (std.mem.indexOfScalar(u8, body, '\n') == null) {
            var sym: Emitter = .init(arena);
            if (try parseLiterals(body, &sym)) {
                if (sym.slice().len > 0) try syms.put(arena, sym.slice(), {});
            }
        }
        i = end + " !@>".len;
    }
}

/// Scan C string literals ("..."), unescaping each; returns false if no
/// literal was found, matching presym.rb (`unless literals.empty?`).
fn parseLiterals(body: []const u8, out: *Emitter) !bool {
    var found = false;
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] != '"') {
            i += 1;
            continue;
        }
        i += 1;
        found = true;
        while (i < body.len and body[i] != '"') {
            if (body[i] == '\\' and i + 1 < body.len) {
                i += 1;
                i += try unescapeEscape(body[i..], out);
            } else {
                try out.byte(body[i]);
                i += 1;
            }
        }
        if (i < body.len) i += 1; // closing quote
    }
    return found;
}

/// Handles one escape sequence after the backslash; returns bytes consumed.
fn unescapeEscape(s: []const u8, out: *Emitter) !usize {
    if (s.len == 0) return 0;
    if (s[0] == 'x') {
        if (s.len > 1) {
            var n: usize = 0;
            var val: u16 = 0;
            while (n < 2 and n + 1 < s.len) : (n += 1) {
                const d = std.fmt.charToDigit(s[n + 1], 16) catch break;
                val = val * 16 + d;
            }
            if (n > 0) {
                try out.byte(@truncate(val));
                return 1 + n;
            }
        }
        return 1;
    }
    if (s[0] == '0') {
        // Ruby: \(0[0-7]{,3}) — the leading zero plus up to 3 octal digits.
        var n: usize = 1;
        var val: u16 = 0;
        while (n < 4 and n < s.len) : (n += 1) {
            const d = std.fmt.charToDigit(s[n], 8) catch break;
            val = val * 8 + d;
        }
        try out.byte(@truncate(val));
        return n;
    }
    const simple = [_]struct { c: u8, b: u8 }{
        .{ .c = 'a', .b = 0x07 }, .{ .c = 'b', .b = 0x08 }, .{ .c = 'e', .b = 0x1b },
        .{ .c = 'f', .b = 0x0c }, .{ .c = 'n', .b = 0x0a }, .{ .c = 'r', .b = 0x0d },
        .{ .c = 't', .b = 0x09 }, .{ .c = 'v', .b = 0x0b },
    };
    for (simple) |e| {
        if (s[0] == e.c) {
            try out.byte(e.b);
            return 1;
        }
    }
    try out.byte(s[0]);
    return 1;
}

/// Optional sigil prefix (`$`, `@@`, `@`), body of `[A-Za-z_][A-Za-z0-9_]*`,
/// optional `!`/`?`/`=` suffix. `@@` is checked before `@` (regex
/// alternation order); the suffix is only taken when the remainder is a
/// valid body, so e.g. `foo-1=` matches neither way, like the Ruby regex.
fn splitAffixes(sym: []const u8) ?Affixes {
    var rest = sym;
    var prefix: []const u8 = "";
    if (std.mem.startsWith(u8, rest, "$")) {
        prefix = "GV";
        rest = rest[1..];
    } else if (std.mem.startsWith(u8, rest, "@@")) {
        prefix = "CV";
        rest = rest[2..];
    } else if (std.mem.startsWith(u8, rest, "@")) {
        prefix = "IV";
        rest = rest[1..];
    }

    var suffix: []const u8 = "";
    if (rest.len > 1) {
        const last = rest[rest.len - 1];
        if (last == '!' or last == '?' or last == '=') {
            const body = rest[0 .. rest.len - 1];
            if (validBody(body)) {
                suffix = switch (last) {
                    '!' => "_B",
                    '?' => "_Q",
                    else => "_E",
                };
                rest = body;
            }
        }
    }

    if (!validBody(rest)) return null;
    return .{ .prefix = prefix, .body = rest, .suffix = suffix };
}

fn operatorName(sym: []const u8) ?[]const u8 {
    for (operators) |op| {
        if (std.mem.eql(u8, sym, op.sym)) return op.name;
    }
    return null;
}

/// Body must be `[A-Za-z_][A-Za-z0-9_]*` (Ruby: `[\w&&\D]\w*`, ASCII \w).
fn validBody(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!isWordNonDigit(s[0])) return false;
    for (s[1..]) |c| {
        if (!isWord(c)) return false;
    }
    return true;
}

fn isWord(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isWordNonDigit(c: u8) bool {
    return isWord(c) and !(c >= '0' and c <= '9');
}

/// Escape rule from `write_table_header`: control/high bytes become C escapes
/// (`\a\b\e\f\n\r\t\v` or `\xNN""` with an empty-string break so following
/// characters can't be parsed as hex digits), `"` and `\` are
/// backslash-escaped; everything else is emitted verbatim.
fn appendCEscaped(out: *Emitter, sym: []const u8) !void {
    const escapes = [_]struct { b: u8, c: u8 }{
        .{ .b = 0x07, .c = 'a' }, .{ .b = 0x08, .c = 'b' }, .{ .b = 0x1b, .c = 'e' },
        .{ .b = 0x0c, .c = 'f' }, .{ .b = 0x0a, .c = 'n' }, .{ .b = 0x0d, .c = 'r' },
        .{ .b = 0x09, .c = 't' }, .{ .b = 0x0b, .c = 'v' },
    };
    for (sym) |b| {
        if ((b >= 0x01 and b <= 0x1f) or b >= 0x7f) {
            var matched = false;
            for (escapes) |e| {
                if (e.b == b) {
                    try out.print("\\{c}", .{e.c});
                    matched = true;
                    break;
                }
            }
            if (!matched) try out.print("\\x{x:0>2}\"\"", .{b});
        } else if (b == '"' or b == '\\') {
            try out.print("\\{c}", .{b});
        } else {
            try out.byte(b);
        }
    }
}

test "marker scanning and sorting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pp =
        \\x = <@! "length" !@> <@! "+" !@> y = <@! "+" !@>;
        \\z = <@! "$stdout" !@> w = <@! "empty?" !@> v = <@! "foo" "bar" !@>
        \\no marker here
        \\broken <@! "unterminated
    ;
    var syms: std.array_hash_map.String(void) = .empty;
    try scanMarkers(pp, arena, &syms);

    const list = syms.keys();
    std.mem.sort([]const u8, list, {}, symLessThan);
    const expected = [_][]const u8{ "+", "$stdout", "foobar", "empty?", "length" };
    try std.testing.expectEqual(expected.len, list.len);
    for (expected, list) |e, got| try std.testing.expectEqualStrings(e, got);
}

test "affix splitting" {
    const cases = [_]struct { sym: []const u8, prefix: []const u8, body: []const u8, suffix: []const u8 }{
        .{ .sym = "foo", .prefix = "", .body = "foo", .suffix = "" },
        .{ .sym = "empty?", .prefix = "", .body = "empty", .suffix = "_Q" },
        .{ .sym = "at=", .prefix = "", .body = "at", .suffix = "_E" },
        .{ .sym = "@iv", .prefix = "IV", .body = "iv", .suffix = "" },
        .{ .sym = "@@cv", .prefix = "CV", .body = "cv", .suffix = "" },
        .{ .sym = "$gv", .prefix = "GV", .body = "gv", .suffix = "" },
        .{ .sym = "_", .prefix = "", .body = "_", .suffix = "" },
    };
    for (cases) |c| {
        const af = splitAffixes(c.sym) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(c.prefix, af.prefix);
        try std.testing.expectEqualStrings(c.body, af.body);
        try std.testing.expectEqualStrings(c.suffix, af.suffix);
    }
    // Not presym-able as word symbols:
    for ([_][]const u8{ "+", "foo-1=", "0abc", "" }) |sym| {
        try std.testing.expect(splitAffixes(sym) == null);
    }
    // ...but "+" is an operator:
    try std.testing.expectEqualStrings("add", operatorName("+") orelse return error.TestUnexpectedResult);
}

//! Produce the one audited mruby core patch required by mruby-zig.
//!
//! mruby 4.0 word boxing stores full-width signed integers outside the fixnum
//! range in `RInteger`, but its non-BigInt Hash fallback hashes those objects
//! by identity even though key equality compares their numeric value. Its
//! Symbol branch also treats word-boxed symbols as fixnums and collapses their
//! hashes to a tiny set. This generator patches a cache-owned copy of hash.c;
//! it never writes into the package dependency.

const std = @import("std");

const old_integer_block =
    \\  case MRB_TT_INTEGER:
    \\    if (mrb_fixnum_p(key)) {
    \\      hash_code = U32(mrb_fixnum(key));
    \\    }
    \\    else {
    \\#ifdef MRB_USE_BIGINT
    \\      hash_code = U32(mrb_integer(mrb_bint_hash(mrb, key)));
    \\#else
    \\      /* This path should not be reached if bignum is not configured.
    \\       * Hashing object_id is a fallback to avoid uninitialized value. */
    \\      hash_code = U32(mrb_obj_id(key));
    \\#endif
    \\    }
    \\    break;
;

const new_integer_block =
    \\  case MRB_TT_INTEGER:
    \\    /* mruby-zig: Integer equality is numeric for both fixnums and heap
    \\     * RInteger values, so their hash must be numeric as well. Keeping
    \\     * U32 preserves upstream's fixnum hash and makes all signed mrb_int
    \\     * keys stable across separately boxed lookup values. */
    \\    hash_code = U32(mrb_integer(key));
    \\    break;
;

const old_symbol_block =
    \\  case MRB_TT_TRUE:
    \\  case MRB_TT_FALSE:
    \\  case MRB_TT_SYMBOL:
    \\    hash_code = U32(mrb_fixnum(key));
    \\    break;
;

const new_symbol_block =
    \\  case MRB_TT_TRUE:
    \\  case MRB_TT_FALSE:
    \\    hash_code = U32(mrb_fixnum(key));
    \\    break;
    \\  case MRB_TT_SYMBOL: {
    \\    /* mruby-zig: word-boxed Symbol bits are not a usable hash. Hash the
    \\     * inert interned name bytes with the same FNV-1 primitive Strings
    \\     * use, keeping StateCapsule insertion work predictable. */
    \\    mrb_int name_len;
    \\    const char *name = mrb_sym_name_len(mrb, mrb_symbol(key), &name_len);
    \\    hash_code = mrb_byte_hash((const uint8_t*)name, name_len);
    \\    break;
    \\  }
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    _ = args.next() orelse return fatal("missing argv0", .{});
    const input_path = args.next() orelse return fatal("missing input hash.c", .{});
    const output_path = args.next() orelse return fatal("missing output hash.c", .{});
    if (args.next() != null) return fatal("usage: patch_mruby_hash <input> <output>", .{});

    const source = cwd.readFileAlloc(io, input_path, allocator, .limited(16 * 1024 * 1024)) catch |err|
        return fatal("reading {s}: {s}", .{ input_path, @errorName(err) });
    defer allocator.free(source);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try replaceExactlyOnce(&output.writer, source, old_symbol_block, new_symbol_block, "Symbol");

    const symbol_patched = output.writer.buffer[0..output.writer.end];
    var final_output: std.Io.Writer.Allocating = .init(allocator);
    defer final_output.deinit();
    try replaceExactlyOnce(
        &final_output.writer,
        symbol_patched,
        old_integer_block,
        new_integer_block,
        "Integer",
    );

    if (std.fs.path.dirname(output_path)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{
        .sub_path = output_path,
        .data = final_output.writer.buffer[0..final_output.writer.end],
    });
}

fn replaceExactlyOnce(
    writer: *std.Io.Writer,
    source: []const u8,
    old: []const u8,
    new: []const u8,
    label: []const u8,
) !void {
    const offset = std.mem.indexOf(u8, source, old) orelse
        return fatal("pinned hash.c no longer contains the audited {s} block", .{label});
    if (std.mem.indexOfPos(u8, source, offset + old.len, old) != null)
        return fatal("pinned hash.c contains the audited {s} block more than once", .{label});
    try writer.writeAll(source[0..offset]);
    try writer.writeAll(new);
    try writer.writeAll(source[offset + old.len ..]);
}

fn fatal(comptime fmt: []const u8, args: anytype) error{Fatal} {
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "patch_mruby_hash: " ++ fmt ++ "\n", args) catch
        "patch_mruby_hash: fatal error\n";
    std.debug.print("{s}", .{message});
    return error.Fatal;
}

test "patch is narrow and gives Integer and Symbol value hashes" {
    try std.testing.expect(std.mem.indexOf(u8, old_integer_block, "mrb_obj_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, new_integer_block, "mrb_obj_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, new_integer_block, "U32(mrb_integer(key))") != null);
    try std.testing.expect(std.mem.indexOf(u8, old_symbol_block, "MRB_TT_SYMBOL") != null);
    try std.testing.expect(std.mem.indexOf(u8, new_symbol_block, "mrb_byte_hash") != null);
}

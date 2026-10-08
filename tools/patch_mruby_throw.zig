//! Produce the audited mruby throw.h patch for clang-on-MinGW targets.
//!
//! mruby 4.0's throw.h selects GCC's untyped `__builtin_setjmp` (a
//! `void **` buffer) on MinGW64 whenever `__GNUC__ >= 4`. zig cc is clang
//! in GCC-compatibility mode: it satisfies that precondition but, unlike
//! GCC, type-checks the builtin strictly against the platform `jmp_buf`
//! (an array of `struct _SETJMP_FLOAT128`), which is a hard compile error
//! across core, compiler, and shim sources. The patch excludes clang from
//! the builtin branch so it falls through to the typed `setjmp`/`longjmp`
//! path, whose signatures match `jmp_buf` exactly. GCC builds are
//! unchanged. This generator patches a cache-owned copy of throw.h; it
//! never writes into the package dependency.

const std = @import("std");

const old_block =
    \\#elif defined(__MINGW64__) && !defined(_M_ARM64) && defined(__GNUC__) && __GNUC__ >= 4
    \\#define MRB_SETJMP __builtin_setjmp
    \\#define MRB_LONGJMP __builtin_longjmp
;

const new_block =
    \\#elif defined(__MINGW64__) && !defined(_M_ARM64) && !defined(__clang__) && defined(__GNUC__) && __GNUC__ >= 4
    \\/* mruby-zig: clang (zig cc) defines __GNUC__ for compatibility but
    \\ * type-checks __builtin_setjmp's void** buffer against the platform
    \\ * jmp_buf; use the typed setjmp/longjmp path instead. */
    \\#define MRB_SETJMP setjmp
    \\#define MRB_LONGJMP longjmp
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    _ = args.next() orelse return fatal("missing argv0", .{});
    const input_path = args.next() orelse return fatal("missing input throw.h", .{});
    const output_dir = args.next() orelse return fatal("missing output dir", .{});
    if (args.next() != null) return fatal("usage: patch_mruby_throw <input> <output-dir>", .{});

    const source = cwd.readFileAlloc(io, input_path, allocator, .limited(1 * 1024 * 1024)) catch |err|
        return fatal("reading {s}: {s}", .{ input_path, @errorName(err) });
    defer allocator.free(source);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try replaceExactlyOnce(&output.writer, source, old_block, new_block, "MinGW setjmp");

    const out_path = try std.fs.path.join(allocator, &.{ output_dir, "mruby", "throw.h" });
    defer allocator.free(out_path);
    if (std.fs.path.dirname(out_path)) |dir| try cwd.createDirPath(io, dir);
    const file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(output.writer.buffer[0..output.writer.end]);
    try writer.interface.flush();
}

fn replaceExactlyOnce(
    writer: *std.Io.Writer,
    source: []const u8,
    old: []const u8,
    new: []const u8,
    name: []const u8,
) !void {
    const first = std.mem.indexOf(u8, source, old) orelse
        return fatal("pinned throw.h no longer contains the audited {s} block", .{name});
    if (std.mem.indexOfPos(u8, source, first + old.len, old) != null) {
        return fatal("audited {s} block matches more than once", .{name});
    }
    try writer.writeAll(source[0..first]);
    try writer.writeAll(new);
    try writer.writeAll(source[first + old.len ..]);
}

fn fatal(comptime fmt: []const u8, args: anytype) error{Fatal} {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "patch_mruby_throw: " ++ fmt ++ "\n", args) catch
        ("patch_mruby_throw: message truncated\n");
    std.debug.print("{s}", .{message});
    return error.Fatal;
}

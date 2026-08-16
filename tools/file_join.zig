//! file_join — concatenates literal strings and file contents into one
//! output file. Used to assemble generated C sources (mrblib.c, per-gem
//! gem_init.c) from a header, an `mrbc` cdump body, and a footer — the same
//! interleaving the Rake build produces with IO.popen.
//!
//! usage: file_join --output <path> [--str <text> | --file <path>]...

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = args.next() orelse return fatal("missing argv0", .{});

    var out_path: ?[]const u8 = null;
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--output")) {
            out_path = args.next() orelse return fatal("--output requires a path", .{});
        } else if (std.mem.eql(u8, arg, "--str")) {
            const text = args.next() orelse return fatal("--str requires a value", .{});
            try buf.writer.writeAll(text);
        } else if (std.mem.eql(u8, arg, "--file")) {
            const path = args.next() orelse return fatal("--file requires a path", .{});
            const data = cwd.readFileAlloc(io, path, gpa, .limited(1 << 30)) catch |err|
                return fatal("reading {s}: {s}", .{ path, @errorName(err) });
            defer gpa.free(data);
            try buf.writer.writeAll(data);
        } else {
            return fatal("unknown argument: {s}", .{arg});
        }
    }

    const path = out_path orelse return fatal("no --output given", .{});
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{
        .sub_path = path,
        .data = buf.writer.buffer[0..buf.writer.end],
    });
}

fn fatal(comptime fmt: []const u8, args: anytype) error{Fatal} {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "file_join: " ++ fmt ++ "\n", args) catch "file_join: fatal error\n";
    std.debug.print("{s}", .{msg});
    return error.Fatal;
}

//! mruby evaluation tool built on mruby-zig (development/inspection).
//!
//!     zig build run-repl -- -e '1 + 1'        # evaluate an expression
//!     echo 'puts [1,2,3].sum' | zig build run-repl
//!
//! Reads the whole input before evaluating (no line editing); it is meant
//! for quick checks against a freshly built libmruby, not as a shell.

const std = @import("std");
const mruby = @import("mruby");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var src = std.ArrayList(u8).empty;
    defer src.deinit(gpa);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = args.next();
    var in_expr = false;
    while (args.next()) |arg| {
        if (!in_expr and std.mem.eql(u8, arg, "-e")) {
            in_expr = true;
            continue;
        }
        if (in_expr) {
            if (src.items.len > 0) try src.append(gpa, '\n');
            try src.appendSlice(gpa, arg);
        }
    }
    if (src.items.len == 0) {
        var stdin_buf: [8192]u8 = undefined;
        var stdin_file = std.Io.File.stdin().reader(io, &stdin_buf);
        while (true) {
            const chunk = stdin_file.interface.peekGreedy(1) catch break;
            if (chunk.len == 0) break;
            try src.appendSlice(gpa, chunk);
            _ = stdin_file.interface.discard(.limited(chunk.len)) catch break;
        }
    }

    const vm = try mruby.Vm.init();
    defer vm.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_file.interface;
    mruby.output.setOutputWriter(vm, out);

    const result = vm.loadString(src.items) catch {
        const exc = vm.lastError().?;
        const cls = exc.className();
        defer mruby.alloc.gpa.free(cls);
        const msg = exc.message();
        defer mruby.alloc.gpa.free(msg);
        try out.print("{s}: {s}\n", .{ cls, msg });
        try out.flush();
        vm.printError();
        return;
    };
    if (!result.isNil()) {
        const inspected = vm.call(result, "inspect", .{}) catch {
            try out.writeAll("<uninspectable>\n");
            try out.flush();
            return;
        };
        const s = inspected.asString() catch {
            try out.writeAll("<non-string>\n");
            try out.flush();
            return;
        };
        try out.print("{s}\n", .{s});
    }
    try out.flush();
}

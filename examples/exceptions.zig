//! Exception handling in both directions: catching Ruby exceptions in Zig
//! and raising Ruby exceptions from Zig, with output redirection.
//!
//!     zig build run-exceptions

const std = @import("std");
const mruby = @import("mruby");

const Divider = struct {
    fn divide(m: *mruby.Vm, self: mruby.Value, a: i64, b: i64) anyerror!mruby.Value {
        _ = self;
        if (b == 0) return m.raise("ZeroDivisionError", "divided by 0 in zig");
        return m.intValue(@divTrunc(a, b));
    }
};

pub fn main(init: std.process.Init) !void {
    const vm = try mruby.Vm.init();
    defer vm.deinit();

    var buffer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer buffer.deinit();
    try mruby.output.setOutputWriter(vm, &buffer.writer);

    const divider = try vm.defineClass("Divider", null);
    try divider.defineMethod("divide", Divider.divide);

    // 1. A Zig-raised Ruby exception, caught in Ruby.
    _ = vm.loadString(
        \\begin
        \\  Divider.new.divide(1, 0)
        \\rescue ZeroDivisionError => e
        \\  puts "rescued: #{e.class}: #{e.message}"
        \\end
    ) catch return error.UnexpectedRubyException;

    // 2. A Ruby exception, caught in Zig.
    _ = vm.loadString("raise ArgumentError, 'from ruby'") catch {
        const exc = vm.lastError().?;
        const class_name = try exc.className(std.heap.page_allocator);
        defer std.heap.page_allocator.free(class_name);
        const msg = try exc.message(std.heap.page_allocator);
        defer std.heap.page_allocator.free(msg);
        try buffer.writer.print("caught: {s}: {s}\n", .{ class_name, msg });
    };

    // 3. A Zig error inside a method call, surfaced as RuntimeError.
    _ = vm.loadString(
        \\begin
        \\  Divider.new.divide("a", 1)
        \\rescue TypeError => e
        \\  puts "type error: #{e.message}"
        \\end
    ) catch return error.UnexpectedRubyException;

    try buffer.writer.flush();
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    try stdout_writer.interface.writeAll(buffer.writer.buffer[0..buffer.writer.end]);
    try stdout_writer.interface.flush();
}

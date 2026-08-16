//! Test root: `zig build test`.

const std = @import("std");
const mruby = @import("mruby");

test {
    _ = mruby;
}

test "evaluates arithmetic" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const result = try vm.loadString("1 + 1");
    try std.testing.expectEqual(@as(i64, 2), try result.asInt());
}

test "captures ruby exceptions" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try std.testing.expectError(error.RubyException, vm.loadString("raise 'boom'"));
    const exc = vm.lastError().?;
    const class_name = exc.className();
    defer mruby.alloc.gpa.free(class_name);
    try std.testing.expectEqualStrings("RuntimeError", class_name);
}

test "syntax errors are ruby exceptions" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    try std.testing.expectError(error.RubyException, vm.loadString("def oops("));
}

test "stdlib gems are loaded" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const v = try vm.loadString("'mruby-zig'.start_with?('mruby')");
    try std.testing.expect(v.isTruthy());
}

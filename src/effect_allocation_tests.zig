//! Regression coverage for the native protection boundary used by effects.
const std = @import("std");
const mruby = @import("mruby");
const testing = std.testing;
const test_c = struct {
    extern fn mrz_artifact_test_fill_arena(mrb: *mruby.c.mrb_state) c_int;
};

test "protected array read contains OOM while rooting an existing result" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const value = try vm.stringValue("already allocated");
    const array = try vm.array(&.{value});
    const previous = mruby.alloc.gpa;
    var failing = testing.FailingAllocator.init(previous, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    const result = blk: {
        const arena = test_c.mrz_artifact_test_fill_arena(vm.mrb);
        defer mruby.c.mrz_gc_arena_restore(vm.mrb, arena);
        mruby.alloc.gpa = failing.allocator();
        defer mruby.alloc.gpa = previous;
        // Reading the element allocates nothing. The failure occurs only in
        // mrb_protect_error's final gc_protect, after its own catch is gone.
        break :blk array.get(0);
    };
    try testing.expectError(error.RubyException, result);
    try testing.expect(failing.has_induced_failure);
    try testing.expect(vm.lastError() != null);
    vm.clearError();
    try testing.expectEqualStrings("already allocated", try (try array.get(0)).asString());
}

test "native effect rejection contains a second OOM while rooting its exception" {
    const vm = try mruby.Vm.init();
    defer vm.deinit();
    const operations = [_]mruby.effect.Operation{.{
        .name = "inventory.reserve",
        .namespace = "Inventory",
        .method = "reserve",
        .arity = 0,
        .authority_bits = 0,
    }};
    try mruby.effect.install(vm, operations, .{});
    const outcome = try mruby.effect.reject(vm, "unavailable", "not enough stock");
    const previous = mruby.alloc.gpa;
    var failing = testing.FailingAllocator.init(previous, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    const succeeded = blk: {
        const arena = test_c.mrz_artifact_test_fill_arena(vm.mrb);
        defer mruby.c.mrz_gc_arena_restore(vm.mrb, arena);
        mruby.alloc.gpa = failing.allocator();
        defer mruby.alloc.gpa = previous;
        // Construction fails inside the first catch. Rooting that exception
        // then encounters the same full arena and must stay inside C as well.
        break :blk mruby.c.mrz_protected_effect_rejection(
            vm.mrb,
            vm.effects.?.rejected_class.class,
            outcome.rejected.v,
        );
    };
    try testing.expect(!succeeded);
    try testing.expect(failing.has_induced_failure);
    try testing.expect(vm.lastError() != null);
    vm.clearError();
    try testing.expect(mruby.c.mrz_protected_effect_rejection(
        vm.mrb,
        vm.effects.?.rejected_class.class,
        outcome.rejected.v,
    ));
    const exception = vm.lastError() orelse return error.MissingRubyException;
    const class_name = try exception.className(testing.allocator);
    defer testing.allocator.free(class_name);
    try testing.expectEqualStrings("Effect::Rejected", class_name);
    vm.clearError();
}

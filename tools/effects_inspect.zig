//! Read-only, VM-free inspector for a complete binary strict-turn receipt.
const std = @import("std");
const inspection = @import("effect_inspect");

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        // Never echo an untrusted path or payload to the terminal on failure.
        std.debug.print("mruby-effects-inspect: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.ExpectedReceiptPath;
    if (args.next() != null) return error.ExpectedOneReceiptPath;
    const limits: inspection.Limits = .{};
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(limits.max_receipt_bytes));
    defer init.gpa.free(bytes);
    var report = try inspection.inspect(init.gpa, bytes, limits);
    defer report.deinit();
    try std.Io.File.stdout().writeStreamingAll(init.io, report.json());
}

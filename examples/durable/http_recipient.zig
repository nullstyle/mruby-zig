//! Local HTTP recipient test double for the durable delivery example.
//! Installed usage:
//!   effects-durable-http-recipient <recipient.sqlite> [port]
//!
//! Binds loopback — an ephemeral port when `port` is omitted or zero — and
//! prints one "LISTENING <port>" line on stdout once the socket is ready.
//! Then it serves requests sequentially, one connection at a time, until
//! killed. Each accepted intent runs the exact durable local-recipient
//! transaction from delivery.zig, so the deduplication contract is identical
//! to the local SQLite recipient:
//!   POST /<destination>  +  Idempotency-Key: <intent id>  +  exact payload bytes
//! Identical repeats under the same key succeed without another notification;
//! the same key with changed bytes is rejected with 409. The recipient
//! commits before responding, so a dispatcher that observes success can
//! safely acknowledge its source.
const std = @import("std");
const mruby = @import("mruby");
const host_module = @import("durable_host");
const delivery = host_module.delivery;
const sql = host_module.sql;

// The host re-exports everything this double uses; mruby itself is imported
// only to force the allocator export its linked C objects require.
comptime {
    _ = mruby.alloc;
}

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const database = arguments.next() orelse return error.MissingDatabasePath;
    const port_text = arguments.next();
    if (arguments.next() != null) return error.UnexpectedArgument;
    const port: u16 = if (port_text) |text| std.fmt.parseInt(u16, text, 10) catch return error.InvalidListenPort else 0;

    var recipient = try sql.Db.open(init.gpa, database);
    defer recipient.close();
    try delivery.initRecipient(&recipient);

    const listen_address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    var server = try listen_address.listen(init.io, .{});
    defer server.deinit(init.io);
    const bound = switch (server.socket.address) {
        .ip4 => |address| address.port,
        .ip6 => |address| address.port,
    };
    var stdout_buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.print("LISTENING {d}\n", .{bound});
    try stdout.interface.flush();

    while (true) {
        var stream = try server.accept(init.io);
        serveConnection(init.io, init.gpa, &recipient, stream) catch {};
        stream.close(init.io);
    }
}

fn serveConnection(io: std.Io, allocator: std.mem.Allocator, recipient: *sql.Db, stream: std.Io.net.Stream) !void {
    var in_buffer: [16 * 1024]u8 = undefined;
    var out_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buffer);
    var writer = stream.writer(io, &out_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing, error.HttpRequestTruncated => return,
            else => |e| return e,
        };
        try handleRequest(allocator, recipient, &request);
        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(allocator: std.mem.Allocator, recipient: *sql.Db, request: *std.http.Server.Request) !void {
    if (request.head.method != .POST) {
        return request.respond("POST required\n", .{ .status = .method_not_allowed, .keep_alive = false });
    }
    const target = request.head.target;
    if (target.len < 2 or target[0] != '/') {
        return request.respond("unknown destination\n", .{ .status = .not_found, .keep_alive = false });
    }
    const key = headerValue(request, "idempotency-key") orelse {
        return request.respond("missing idempotency key\n", .{ .status = .bad_request, .keep_alive = false });
    };
    const length = request.head.content_length orelse {
        return request.respond("content length required\n", .{ .status = .bad_request, .keep_alive = false });
    };
    if (length > delivery.max_payload_bytes) {
        return request.respond("payload too large\n", .{ .status = .bad_request, .keep_alive = false });
    }
    // Header and target strings are invalidated once the body starts reading.
    const id = try allocator.dupe(u8, key);
    defer allocator.free(id);
    const destination = try allocator.dupe(u8, target[1..]);
    defer allocator.free(destination);
    const payload = try allocator.alloc(u8, @intCast(length));
    defer allocator.free(payload);
    var transfer_scratch: [128]u8 = undefined;
    const body = request.readerExpectNone(&transfer_scratch);
    try body.readSliceAll(payload);
    delivery.accept(recipient, .{ .id = id, .destination = destination, .payload = payload }) catch |err| switch (err) {
        error.IntentConflict => return request.respond("intent conflict\n", .{ .status = .conflict, .keep_alive = false }),
        error.InvalidIntent, error.InvalidRecipientState => return request.respond("invalid intent\n", .{ .status = .bad_request, .keep_alive = false }),
        else => {
            try request.respond("recipient storage failed\n", .{ .status = .internal_server_error, .keep_alive = false });
            return err;
        },
    };
    try request.respond("committed\n", .{});
}

fn headerValue(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

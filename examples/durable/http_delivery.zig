//! Production-delivery adapter example for the durable host: retryable HTTP
//! delivery of committed outbox intents. The stable intent ID travels as an
//! explicit `Idempotency-Key` request header and the request body is the
//! exact outbox payload blob, byte for byte. A recipient that durably records
//! that key alongside the payload can therefore deduplicate the re-sends
//! this dispatcher performs whenever it dies between the recipient's commit
//! and the source acknowledgement.
//!
//! This is at-least-once delivery with transport-specific deduplication, not
//! exactly-once delivery: an HTTP service that ignores the idempotency key
//! will observe duplicate side effects. The embedding library stays
//! transport-free; everything here is example code.
const std = @import("std");
const host_module = @import("durable_host");
const contract = @import("durable_contract");
pub const delivery = host_module.delivery;
const sql = host_module.sql;

/// Same bound as the local `Host.dispatch` batch.
pub const max_batch: usize = 64;

/// Deliver up to `max_batch` pending committed intents over HTTP to a
/// loopback recipient and acknowledge each one in the source, mirroring the
/// local dispatcher's shape: only committed outbox rows are visible, the
/// recipient transaction commits before the source acknowledgement, and no
/// source statement or transaction stays open during recipient work or the
/// delivery checkpoints. An error mid-batch leaves earlier intents
/// acknowledged and the failing intent pending, so a retry re-sends it.
pub fn dispatch(allocator: std.mem.Allocator, io: std.Io, source: *sql.Db, port: u16, checkpoint: contract.Checkpoint) !usize {
    if (!source.autocommit()) return error.DatabaseTransactionActive;
    try delivery.requireRole(source, "inventory");
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var delivered: usize = 0;
    while (delivered < max_batch) : (delivered += 1) {
        var pending = (try delivery.loadOne(allocator, source)) orelse break;
        defer pending.deinit(allocator);
        checkpoint.reach(.before_delivery);
        try send(&client, port, pending.intent());
        checkpoint.reach(.after_recipient_commit);
        try delivery.acknowledge(source, pending);
        checkpoint.reach(.after_delivery_ack);
    }
    return delivered;
}

/// POST one intent to `http://127.0.0.1:<port>/<destination>` with the stable
/// intent ID as the explicit `Idempotency-Key` header and the payload as the
/// exact request body. The destination maps to the request path, so
/// destinations must be URL-path-safe; the durable adapter's fixed
/// destination is. A 409 response means the recipient already holds that key
/// with different bytes; any other non-200 response refuses the intent. Both
/// leave the source untouched.
pub fn send(client: *std.http.Client, port: u16, intent: delivery.Intent) !void {
    var url_buffer: ["http://127.0.0.1:65535/".len + delivery.max_destination_bytes + 1]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/{s}", .{ port, intent.destination });
    const headers = [_]std.http.Header{.{ .name = "idempotency-key", .value = intent.id }};
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = intent.payload,
        .headers = .{ .content_type = .{ .override = "application/octet-stream" } },
        .extra_headers = &headers,
        .redirect_behavior = .not_allowed,
    });
    switch (response.status) {
        .ok => {},
        .conflict => return error.IntentConflict,
        else => return error.RecipientRefused,
    }
}

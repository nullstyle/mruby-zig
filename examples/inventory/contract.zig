//! Operation catalogue and the intentionally small SQL protocol used by this example.
pub const operations = .{
    .{ .name = "db.rows", .namespace = "DB", .method = "rows", .version = @as(u32, 1), .arity = @as(usize, 2), .authority_bits = @as(u16, 1 << 12), .max_result_bytes = @as(usize, 2048) },
    .{ .name = "db.execute", .namespace = "DB", .method = "execute", .version = @as(u32, 1), .arity = @as(usize, 2), .authority_bits = @as(u16, 1 << 12), .max_result_bytes = @as(usize, 2048) },
    .{ .name = "outbox.enqueue", .namespace = "Outbox", .method = "enqueue", .version = @as(u32, 1), .arity = @as(usize, 2), .authority_bits = @as(u16, 1 << 13), .max_result_bytes = @as(usize, 256) },
};

pub const read_stock = "SELECT quantity FROM stock WHERE sku = ?";
pub const reserve_stock = "UPDATE stock SET quantity = quantity - ? WHERE sku = ? AND quantity >= ?";
pub const insert_reservation = "INSERT INTO reservations(sku, quantity) VALUES (?, ?)";
pub const fixture =
    "CREATE TABLE stock(sku TEXT PRIMARY KEY, quantity INTEGER NOT NULL CHECK(quantity >= 0));" ++
    "CREATE TABLE reservations(sku TEXT NOT NULL, quantity INTEGER NOT NULL);" ++
    "INSERT INTO stock VALUES ('widget', 5);";
// This identity commits to the complete, fixed fixture, schema and protocol.
// A real host must derive state identity from the entire actual source snapshot.
pub const bootstrap_contract = "inventory/v1;singleton=Inventory;private-memory-db;host-turn-transaction;sqlite-3.51.3;sql-allowlist-v1;outbox-intents-v1";

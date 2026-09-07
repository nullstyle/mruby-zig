//! A single in-memory inventory transaction. Adapter callbacks stage business
//! changes; only commit adopts them. Notification intents never leave memory.
const std = @import("std");
const mruby = @import("mruby");
const contract = @import("reservation_contract");
const data = mruby.effect.data;
const Turn = mruby.strict.Turn;
const Capsule = mruby.artifact.StateCapsule;
const View = mruby.artifact.StateCapsuleView;

pub const Reservation = struct { id: i64, quantity: i64 };
pub const Fault = enum { none, invalid_result, undeclared_rejection, invalid_notification };

pub const Host = struct {
    allocator: std.mem.Allocator,
    state: Capsule,
    receipt: ?[]u8 = null,
    stock: i64 = 5,
    reservation_count: i64 = 0,
    notification_count: usize = 0,
    last_notification: ?Reservation = null,
    pending_stock: ?i64 = null,
    pending_reservation: ?Reservation = null,
    pending_notification: ?Reservation = null,
    active: bool = false,
    reserve_calls: usize = 0,
    notification_calls: usize = 0,
    begins: usize = 0,
    commits: usize = 0,
    discards: usize = 0,
    fault: Fault = .none,

    pub fn init(allocator: std.mem.Allocator) !Host {
        return .{ .allocator = allocator, .state = try data.encode(allocator, .{ .hash = &.{
            .{ .key = .{ .string = "attempts" }, .value = .{ .integer = 0 } },
            .{ .key = .{ .string = "reservations" }, .value = .{ .integer = 0 } },
        } }, contract.max_bytes) };
    }

    pub fn deinit(self: *Host) void {
        if (self.active) discard(self);
        self.state.deinit(self.allocator);
        if (self.receipt) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }

    pub fn bindings(self: *Host) [2]mruby.effect.DataBinding {
        return .{
            .{ .name = "stock.reserve", .handler = reserve, .context = self },
            .{ .name = "notifications.reservation_created", .handler = notify, .context = self },
        };
    }

    pub fn transaction(self: *Host) Turn.Transaction {
        return .{ .context = self, .begin = begin, .commit = commit, .discard = discard };
    }

    /// Replay binds the adapter's starting snapshot without changing it.
    pub fn identity(self: *const Host) [32]u8 {
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        digest.update("reservation-host/widget/v1\x00");
        var buffer: [16]u8 = undefined;
        std.mem.writeInt(i64, buffer[0..8], self.stock, .big);
        std.mem.writeInt(i64, buffer[8..16], self.reservation_count, .big);
        digest.update(&buffer);
        return digest.finalResult();
    }

    fn from(context: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(context.?));
    }

    fn begin(context: ?*anyopaque) !void {
        const self = from(context);
        if (self.active) return error.TransactionAlreadyActive;
        std.debug.assert(self.pending_stock == null and self.pending_reservation == null and self.pending_notification == null);
        self.active = true;
        self.begins += 1;
    }

    fn reserve(context: ?*anyopaque, allocator: std.mem.Allocator, arguments: View) !mruby.effect.DataOutcome {
        const self = from(context);
        if (!self.active) return error.TransactionNotActive;
        self.reserve_calls += 1;
        var doc = try data.Document.decode(allocator, arguments, contract.max_bytes);
        defer doc.deinit();
        const sku = try (try doc.root().at(0)).asString();
        const quantity = try (try doc.root().at(1)).asInteger();
        if (!std.mem.eql(u8, sku, "widget") or quantity > self.stock)
            return data.reject(allocator, "OutOfStock", "requested stock is unavailable", 4096);
        if (self.pending_reservation != null) return error.ReservationAlreadyPending;
        self.pending_stock = self.stock - quantity;
        self.pending_reservation = .{ .id = self.reservation_count + 1, .quantity = quantity };
        // Deliberate test faults occur after staging: contract admission must
        // prevent these observations from reaching Ruby and discard the turn.
        if (self.fault == .undeclared_rejection)
            return data.reject(allocator, "DatabaseUnavailable", "not a declared business rejection", 4096);
        return .{ .returned = try encodeReservation(allocator, .{
            .id = self.pending_reservation.?.id,
            .quantity = if (self.fault == .invalid_result) 0 else quantity,
        }) };
    }

    fn notify(context: ?*anyopaque, allocator: std.mem.Allocator, arguments: View) !mruby.effect.DataOutcome {
        const self = from(context);
        if (!self.active) return error.TransactionNotActive;
        self.notification_calls += 1;
        var doc = try data.Document.decode(allocator, arguments, contract.max_bytes);
        defer doc.deinit();
        const value = try doc.root().at(0);
        const reservation: Reservation = .{
            .id = try (try field(value, "id")).asInteger(),
            .quantity = try (try field(value, "quantity")).asInteger(),
        };
        if (!std.mem.eql(u8, try (try field(value, "sku")).asString(), "widget")) return error.UnexpectedSku;
        const expected = self.pending_reservation orelse return error.ReservationNotPending;
        if (expected.id != reservation.id or expected.quantity != reservation.quantity) return error.ReservationDoesNotMatch;
        if (self.pending_notification != null) return error.NotificationAlreadyPending;
        self.pending_notification = reservation;
        return .{ .returned = try data.encode(allocator, if (self.fault == .invalid_notification) .{ .string = "sent" } else .nil, 256) };
    }

    const Adoption = struct { state: Capsule, receipt: []u8 };
    fn prepareAdoption(self: *Host, terminal: View, receipt: []const u8) !Adoption {
        var doc = try data.Document.decode(self.allocator, terminal, contract.max_bytes);
        defer doc.deinit();
        const next = try doc.root().at(1);
        var previous = try data.Document.decode(self.allocator, self.state.view(), contract.max_bytes);
        defer previous.deinit();
        const previous_attempts = try (try field(previous.root(), "attempts")).asInteger();
        if (try (try field(next, "attempts")).asInteger() != previous_attempts + 1) return error.InvalidNextState;
        const reservations = self.reservation_count + @as(i64, if (self.pending_reservation != null) 1 else 0);
        if (try (try field(next, "reservations")).asInteger() != reservations) return error.InvalidNextState;
        if ((self.pending_reservation != null) != (self.pending_notification != null)) return error.IncompleteReservation;
        var state = try data.encodeRef(self.allocator, next, contract.max_bytes);
        errdefer state.deinit(self.allocator);
        return .{ .state = state, .receipt = try self.allocator.dupe(u8, receipt) };
    }

    fn commit(context: ?*anyopaque, terminal: View, receipt: []const u8) !Turn.CommitOutcome {
        const self = from(context);
        if (!self.active) return error.TransactionNotActive;
        // All allocation and semantic checks precede adoption. A failure here
        // is known to have changed nothing and asks Prepared to discard.
        const adoption = self.prepareAdoption(terminal, receipt) catch return .rejected;
        self.state.deinit(self.allocator);
        self.state = adoption.state;
        if (self.receipt) |old| self.allocator.free(old);
        self.receipt = adoption.receipt;
        if (self.pending_stock) |stock| self.stock = stock;
        if (self.pending_reservation != null) self.reservation_count += 1;
        if (self.pending_notification) |notification| {
            self.last_notification = notification;
            self.notification_count += 1;
        }
        self.clearPending();
        self.commits += 1;
        return .committed;
    }

    fn discard(context: ?*anyopaque) void {
        const self = from(context);
        std.debug.assert(self.active);
        self.clearPending();
        self.discards += 1;
    }

    fn clearPending(self: *Host) void {
        self.pending_stock = null;
        self.pending_reservation = null;
        self.pending_notification = null;
        self.active = false;
    }
};

pub fn field(value: data.Ref, name: []const u8) !data.Ref {
    return (try value.get(name)) orelse error.MissingField;
}

pub fn encodeReservation(allocator: std.mem.Allocator, value: Reservation) !Capsule {
    return data.encode(allocator, .{ .hash = &.{
        .{ .key = .{ .string = "id" }, .value = .{ .integer = value.id } },
        .{ .key = .{ .string = "sku" }, .value = .{ .string = "widget" } },
        .{ .key = .{ .string = "quantity" }, .value = .{ .integer = value.quantity } },
    } }, 4096);
}

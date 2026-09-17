//! Bounded copied window-mode mailbox. Desktop owns geometry and focus policy.
const std = @import("std");
const a = @import("r4os").abi;
const owners = @import("tray_broker.zig");
pub const ok: i32 = 0;
pub const invalid: i32 = -1;
pub const busy: i32 = -2;
pub const unavailable: i32 = -3;
pub const stale: i32 = -4;
pub const not_owner: i32 = -5;
const Slot = struct {
    identity: a.WindowModeIdentity = .{},
    mode: u32 = 0,
    pending: ?a.WindowModeRequest = null,
    last: ?a.WindowModeRequest = null,
    last_result: i32 = 0,

    fn reply(self: *const Slot, result: i32) a.WindowModeReply {
        const request = self.pending orelse self.last;
        return .{ .identity = self.identity, .mode = self.mode,
            .request_id = if (request) |r| r.request_id else 0,
            .requested_mode = if (request) |r| r.mode else self.mode,
            .phase = if (self.pending != null) 1 else if (self.last != null) 2 else 0,
            .result = if (result != ok or self.pending != null) result else self.last_result };
    }
};
pub const Broker = struct {
    service: a.ProgramProcessHandle = .{},
    serial: u64 = 0,
    revision: u64 = 1,
    slots: [a.window_service_max_windows]Slot = @splat(.{}),

    pub fn clear(self: *Broker) void {
        for (&self.slots) |*slot| slot.* = .{};
        self.revision +|= 1;
    }
    pub fn removeOwner(self: *Broker, owner: a.ProgramProcessHandle) void {
        for (&self.slots) |*slot| if (slot.identity.serial != 0 and
            (owners.sameOwner(slot.identity.owner, owner) or owners.sameOwner(slot.identity.desktop, owner))) {
            slot.* = .{};
            self.revision +|= 1;
        };
    }
    fn find(self: *Broker, identity: a.WindowModeIdentity) ?*Slot {
        for (&self.slots) |*slot| if (slot.identity.serial != 0 and slot.identity.window_id == identity.window_id and
            owners.sameOwner(slot.identity.owner, identity.owner)) return slot;
        return null;
    }
    pub fn query(self: *Broker, request: *const a.WindowModeRequest) a.WindowModeReply {
        if (!validRequest(request) or request.action != 0 or request.request_id != 0 or request.mode != 0) return .{ .result = invalid };
        const slot = self.find(request.identity) orelse return .{ .result = unavailable };
        return slot.reply(ok);
    }
    pub fn submit(self: *Broker, request: *const a.WindowModeRequest) a.WindowModeReply {
        if (!validRequest(request) or request.action != 1 or request.request_id == 0) return .{ .result = invalid };
        const slot = self.find(request.identity) orelse return .{ .result = unavailable };
        if (!std.meta.eql(slot.identity, request.identity)) return slot.reply(stale);
        if (slot.pending) |pending| {
            if (pending.request_id == request.request_id) return slot.reply(if (std.meta.eql(pending, request.*)) ok else stale);
            return slot.reply(busy);
        }
        if (slot.last) |last| {
            if (last.request_id == request.request_id) return slot.reply(if (std.meta.eql(last, request.*)) ok else stale);
            if (request.request_id < last.request_id) return slot.reply(stale);
        }
        slot.pending = request.*;
        self.revision +|= 1;
        return slot.reply(ok);
    }
    pub fn exchange(self: *Broker, request: *const a.WindowModeExchange) a.WindowModeReply {
        if (request.version != 1 or request.size != @sizeOf(a.WindowModeExchange) or request.reserved != 0 or
            request.identity.reserved != 0 or !owners.ownerValid(request.identity.desktop) or
            !owners.ownerValid(request.identity.owner) or request.mode > 1 or
            request.flags > 1 or request.ack_result > 0 or request.ack_result < not_owner or
            (request.ack_request_id == 0 and request.ack_result != 0)) return .{ .result = invalid };
        var found = self.find(request.identity);
        if (request.flags == 1) {
            const slot = found orelse return .{ .result = unavailable };
            if (!std.meta.eql(slot.identity, request.identity)) return slot.reply(stale);
            const response = slot.reply(ok);
            slot.* = .{};
            self.revision +|= 1;
            return response;
        }
        if (found) |slot| if (!owners.sameOwner(slot.identity.desktop, request.identity.desktop)) {
            slot.* = .{};
            found = null;
        };
        if (found == null) {
            if (!owners.ownerValid(self.service) or self.serial == std.math.maxInt(u64)) return .{ .result = unavailable };
            for (&self.slots) |*slot| if (slot.identity.serial == 0) { found = slot; break; };
            const slot = found orelse return .{ .result = busy };
            self.serial += 1;
            slot.* = .{ .identity = .{ .service = self.service, .desktop = request.identity.desktop,
                .owner = request.identity.owner, .window_id = request.identity.window_id, .serial = self.serial } };
        }
        const slot = found.?;
        slot.mode = request.mode;
        if (slot.pending) |pending| {
            if (std.meta.eql(slot.identity, request.identity) and request.ack_request_id == pending.request_id) {
                // Success means the requested geometry is now the published geometry.
                if (request.ack_result == ok and request.mode != pending.mode) return slot.reply(invalid);
                slot.last = pending;
                slot.last_result = request.ack_result;
                slot.pending = null;
            }
        }
        return slot.reply(ok);
    }
};
pub fn validRequest(request: *const a.WindowModeRequest) bool {
    return request.version == 1 and request.size == @sizeOf(a.WindowModeRequest) and request.identity.reserved == 0 and
        owners.ownerValid(request.identity.owner) and request.action <= 1 and request.mode <= 1;
}

/// Included in the existing WINSVC generation/idempotency owner check.
pub fn check() !void {
    const t = std.testing;
    var broker: Broker = .{ .service = .{ .instance_id = 1, .generation = 90 } };
    var exchange: a.WindowModeExchange = .{ .identity = .{
        .desktop = .{ .instance_id = 2, .generation = 91 }, .owner = .{ .instance_id = 3, .generation = 92 }, .window_id = 4 } };
    exchange.identity = broker.exchange(&exchange).identity;
    var request: a.WindowModeRequest = .{ .identity = exchange.identity, .action = 1, .mode = 1, .request_id = 1 };
    try t.expectEqual(@as(u32, 1), broker.submit(&request).phase);
    const revision = broker.revision;
    try t.expectEqual(ok, broker.submit(&request).result);
    try t.expectEqual(revision, broker.revision);
    var changed = request; changed.mode = 0;
    try t.expectEqual(stale, broker.submit(&changed).result);
    changed = request; changed.request_id = 2;
    try t.expectEqual(busy, broker.submit(&changed).result);
    exchange.ack_request_id = 1;
    try t.expectEqual(invalid, broker.exchange(&exchange).result);
    exchange.mode = 1;
    exchange.identity.serial += 1;
    try t.expectEqual(@as(u32, 1), broker.exchange(&exchange).phase);
    exchange.identity = request.identity;
    try t.expectEqual(@as(u32, 2), broker.exchange(&exchange).phase);
    try t.expectEqual(@as(u32, 2), broker.submit(&request).phase);
    try t.expectEqual(@as(u32, 2), broker.exchange(&exchange).phase);
    changed = request; changed.identity.owner.generation += 1;
    try t.expectEqual(unavailable, broker.submit(&changed).result);
    changed = request; changed.request_id = 2; changed.mode = 0;
    try t.expectEqual(ok, broker.submit(&changed).result);
    try t.expectEqual(@as(u32, 1), broker.exchange(&exchange).phase);
    exchange.ack_request_id = 2; exchange.mode = 0;
    _ = broker.exchange(&exchange);
    try t.expectEqual(stale, broker.submit(&request).result);
    broker.removeOwner(request.identity.owner);
    try t.expectEqual(unavailable, broker.query(&.{ .identity = request.identity }).result);
    const replacement = broker.exchange(&exchange);
    try t.expect(replacement.identity.serial > request.identity.serial);
    try t.expectEqual(@as(u32, 0), replacement.phase);
    exchange.flags = 1;
    try t.expectEqual(stale, broker.exchange(&exchange).result);
    exchange.identity = replacement.identity;
    try t.expectEqual(ok, broker.exchange(&exchange).result);
    broker.clear(); broker.service.generation += 1;
    exchange.flags = 0;
    const restart = broker.exchange(&exchange);
    try t.expect(!std.meta.eql(replacement.identity, restart.identity));
    try t.expectEqual(@as(u32, 0), restart.phase);
    try t.expectEqual(stale, broker.submit(&request).result);
}

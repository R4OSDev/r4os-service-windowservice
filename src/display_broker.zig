//! Copied, bounded Desktop/settings mailbox. Graphics policy, file saves and
//! the confirmation timer belong to Desktop, never this service.
const std = @import("std");
const a = @import("r4os").abi;
const owners = @import("tray_broker.zig");
pub const ok: i32 = 0;
pub const invalid: i32 = -1;
pub const busy: i32 = -2;
pub const unavailable: i32 = -3;
pub const stale: i32 = -4;
pub const not_owner: i32 = -5;
pub const Broker = struct {
    desktop: a.ProgramProcessHandle = .{},
    published: a.DisplayControlStatus = .{},
    pending: ?a.DisplayControlRequest = null,
    last: ?a.DisplayControlRequest = null,

    pub fn clear(self: *Broker) void { self.* = .{}; }
    pub fn status(self: *const Broker, result: i32) a.DisplayControlStatus {
        var value = self.published;
        value.result = if (!owners.ownerValid(self.desktop)) unavailable else result;
        return value;
    }
    pub fn query(self: *const Broker) a.DisplayControlStatus {
        if (!owners.ownerValid(self.desktop)) return self.status(unavailable);
        return self.published;
    }
    pub fn submit(self: *Broker, request: *const a.DisplayControlRequest) a.DisplayControlStatus {
        if (!validRequest(request) or request.action == 0) return self.status(invalid);
        if (!owners.ownerValid(self.desktop) or self.published.flags & 1 == 0) return self.status(unavailable);
        if (request.desktop_epoch != self.desktop.generation) return self.status(stale);
        if (self.pending) |pending| {
            if (sameRequestId(&pending, request)) return self.status(if (std.meta.eql(pending, request.*)) ok else stale);
            return self.status(busy);
        }
        if (self.last) |last| if (sameRequestId(&last, request))
            return self.status(if (std.meta.eql(last, request.*)) ok else stale);
        if (request.base_revision != self.published.revision) return self.status(stale);
        if (request.action == 1) {
            if (request.transaction_id != 0 or active(self.published.phase)) return self.status(busy);
        } else {
            if (request.transaction_id == 0 or request.transaction_id != self.published.transaction_id) return self.status(stale);
            if (!owners.sameOwner(request.owner, self.published.owner)) return self.status(not_owner);
            if (request.action == 2 and self.published.phase != 2) return self.status(busy);
            if (request.action == 3 and !active(self.published.phase)) return self.status(stale);
        }
        self.pending = request.*;
        return self.status(ok);
    }
    pub fn exchange(self: *Broker, request: *const a.DisplayControlExchange) a.DisplayControlExchange {
        var response: a.DisplayControlExchange = .{ .desktop_owner = request.desktop_owner };
        if (!validExchange(request)) { response.status = self.status(invalid); return response; }
        if (!owners.sameOwner(self.desktop, request.desktop_owner)) {
            self.clear(); self.desktop = request.desktop_owner; response.flags = 1;
        }
        if (request.status.revision < self.published.revision) { response.status = self.status(stale); return response; }
        self.published = request.status;
        self.published.desktop_epoch = self.desktop.generation;
        if (self.pending) |pending| {
            if (self.published.request_id == pending.request_id and owners.sameOwner(self.published.owner, pending.owner)) {
                self.last = pending; self.pending = null;
            }
        }
        response.status = self.published;
        if (self.pending) |pending| response.request = pending;
        return response;
    }
};
fn active(phase: u32) bool { return phase == 1 or phase == 2 or phase == 3; }
fn sameRequestId(left: *const a.DisplayControlRequest, right: *const a.DisplayControlRequest) bool {
    return left.request_id == right.request_id and owners.sameOwner(left.owner, right.owner);
}
pub fn validRequest(value: *const a.DisplayControlRequest) bool {
    return value.magic == a.display_control_request_magic and value.version == 1 and value.size == @sizeOf(a.DisplayControlRequest) and
        owners.ownerValid(value.owner) and value.reserved == 0 and value.action <= 3 and
        (value.action == 0 or (value.request_id != 0 and value.base_revision != 0)) and validLayout(&value.layout);
}
fn validLayout(value: *const a.DisplayLayout) bool {
    return value.version == 1 and value.size == @sizeOf(a.DisplayLayout) and value.reserved == 0 and value.count <= value.outputs.len;
}
fn validExchange(value: *const a.DisplayControlExchange) bool {
    return value.magic == a.display_control_exchange_magic and value.version == 1 and value.size == @sizeOf(a.DisplayControlExchange) and
        owners.ownerValid(value.desktop_owner) and value.flags == 0 and value.reserved == 0 and
        value.status.magic == a.display_control_status_magic and value.status.version == 1 and value.status.size == @sizeOf(a.DisplayControlStatus) and
        value.status.reserved == 0 and value.status.flags & ~@as(u32, 3) == 0 and value.status.phase <= 6 and
        value.status.desktop_epoch == value.desktop_owner.generation and value.status.revision != 0 and validLayout(&value.status.layout);
}

/// Scenarios run inside the existing WINSVC generation/ownership test group.
pub fn check() !void {
    const t = std.testing;
    var broker: Broker = .{};
    const desktop: a.ProgramProcessHandle = .{ .instance_id = 1, .generation = 91 };
    const client: a.ProgramProcessHandle = .{ .instance_id = 2, .generation = 17 };
    var exchange: a.DisplayControlExchange = .{ .desktop_owner = desktop,
        .status = .{ .desktop_epoch = 91, .revision = 1, .flags = 1 } };
    try t.expectEqual(@as(u32, 1), broker.exchange(&exchange).flags);
    var request: a.DisplayControlRequest = .{ .owner = client, .desktop_epoch = 91, .request_id = 1, .base_revision = 1, .action = 1 };
    try t.expectEqual(ok, broker.submit(&request).result);
    try t.expectEqual(ok, broker.submit(&request).result);
    var changed = request; changed.layout.outputs[0].width = 800;
    try t.expectEqual(stale, broker.submit(&changed).result);
    changed = request; changed.request_id = 2;
    try t.expectEqual(busy, broker.submit(&changed).result);
    try t.expect(std.meta.eql(request, broker.exchange(&exchange).request));
    exchange.status.owner = client; exchange.status.request_id = 1;
    exchange.status.phase = 2; exchange.status.transaction_id = 10;
    _ = broker.exchange(&exchange);
    try t.expect(broker.pending == null);
    // A retry of an acknowledged request never applies the layout twice.
    try t.expectEqual(ok, broker.submit(&request).result);
    changed.action = 2; changed.transaction_id = 10; changed.owner.generation += 1;
    try t.expectEqual(not_owner, broker.submit(&changed).result);
    changed.owner = client;
    try t.expectEqual(ok, broker.submit(&changed).result);
    exchange.status.request_id = 2; exchange.status.phase = 4; exchange.status.revision = 2;
    _ = broker.exchange(&exchange);
    try t.expectEqual(stale, broker.submit(&request).result);
    broker.clear();
    try t.expectEqual(unavailable, broker.query().result);
    try t.expectEqual(@as(u32, 1), broker.exchange(&exchange).flags);
    exchange.desktop_owner.generation += 1; exchange.status.desktop_epoch += 1;
    try t.expectEqual(@as(u32, 1), broker.exchange(&exchange).flags);
    try t.expectEqual(stale, broker.submit(&changed).result);
}

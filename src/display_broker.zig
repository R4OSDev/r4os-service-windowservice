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
    pending_color: ?a.DisplayColorSelection = null,
    last_color: ?a.DisplayColorSelection = null,
    color_capable: bool = false,

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
        if (!validRequest(request)) return self.status(invalid);
        return self.submitImpl(request, null);
    }
    pub fn submitColor(self: *Broker, request: *const a.DisplayColorRequest) a.DisplayControlStatus {
        if (!validColorRequest(request)) return self.status(invalid);
        if (!self.color_capable) return self.status(unavailable);
        return self.submitImpl(&request.base, request.color);
    }
    fn submitImpl(self: *Broker, request: *const a.DisplayControlRequest, color: ?a.DisplayColorSelection) a.DisplayControlStatus {
        if (request.action == 0) return self.status(invalid);
        if (!owners.ownerValid(self.desktop) or self.published.flags & 1 == 0) return self.status(unavailable);
        if (request.desktop_epoch != self.desktop.generation) return self.status(stale);
        if (self.pending) |pending| {
            if (sameRequestId(&pending, request)) return self.status(if (std.meta.eql(pending, request.*) and std.meta.eql(self.pending_color, color)) ok else stale);
            return self.status(busy);
        }
        if (self.last) |last| if (sameRequestId(&last, request))
            return self.status(if (std.meta.eql(last, request.*) and std.meta.eql(self.last_color, color)) ok else stale);
        if (request.base_revision != self.published.revision) return self.status(stale);
        if (request.action == 1 or request.action == 4) {
            if (request.transaction_id != 0 or active(self.published.phase)) return self.status(busy);
        } else {
            if (request.transaction_id == 0 or request.transaction_id != self.published.transaction_id) return self.status(stale);
            if (!owners.sameOwner(request.owner, self.published.owner)) return self.status(not_owner);
            if (request.action == 2 and self.published.phase != 2) return self.status(busy);
            if (request.action == 3 and !active(self.published.phase)) return self.status(stale);
        }
        self.pending = request.*; self.pending_color = color;
        return self.status(ok);
    }
    pub fn exchange(self: *Broker, request: *const a.DisplayControlExchange) a.DisplayControlExchange {
        return self.exchangeImpl(request, false);
    }
    pub fn exchangeColor(self: *Broker, request: *const a.DisplayColorExchange) a.DisplayColorExchange {
        if (!std.meta.eql(request.color, a.DisplayColorSelection{})) return .{ .base = .{ .status = self.status(invalid) } };
        const base = self.exchangeImpl(&request.base, true);
        return .{ .base = base, .color = if (base.request.action == 4) self.pending_color orelse .{} else .{} };
    }
    fn exchangeImpl(self: *Broker, request: *const a.DisplayControlExchange, color_capable: bool) a.DisplayControlExchange {
        var response: a.DisplayControlExchange = .{ .desktop_owner = request.desktop_owner };
        if (!validExchange(request)) { response.status = self.status(invalid); return response; }
        if (!owners.sameOwner(self.desktop, request.desktop_owner)) {
            self.clear(); self.desktop = request.desktop_owner; response.flags = 1;
        }
        // A legacy Desktop cannot consume a color request. Do not truncate
        // or acknowledge a payload that only the new exchange can carry.
        if (!color_capable and self.pending_color != null) { response.status = self.status(unavailable); return response; }
        if (request.status.revision < self.published.revision) { response.status = self.status(stale); return response; }
        self.published = request.status;
        self.color_capable = color_capable;
        self.published.desktop_epoch = self.desktop.generation;
        if (self.pending) |pending| {
            if (self.published.request_id == pending.request_id and owners.sameOwner(self.published.owner, pending.owner)) {
                self.last = pending; self.last_color = self.pending_color;
                self.pending = null; self.pending_color = null;
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
    return validBase(value, 3);
}
pub fn validColorRequest(value: *const a.DisplayColorRequest) bool {
    const selected = value.color;
    return validBase(&value.base, 4) and value.base.action == 4 and selected.version == 1 and selected.size == @sizeOf(a.DisplayColorSelection) and
        selected.output.adapter_id != 0 and selected.output.connector_id != 0 and selected.output.device_generation != 0 and selected.output.connection_generation != 0 and
        selected.signal.version == 1 and selected.signal.size == @sizeOf(a.GfxColorSignal) and selected.signal.reserved0 == 0;
}
fn validBase(value: *const a.DisplayControlRequest, maximum_action: u32) bool {
    return value.magic == a.display_control_request_magic and value.version == 1 and value.size == @sizeOf(a.DisplayControlRequest) and
        owners.ownerValid(value.owner) and value.reserved == 0 and value.action <= maximum_action and
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
    // The color opcode cannot be delivered to an old Desktop. New transport
    // copies the entire selection and compares it during duplicate detection.
    var colored: a.DisplayColorRequest = .{ .base = .{ .owner = client, .desktop_epoch = exchange.desktop_owner.generation,
        .request_id = 9, .base_revision = exchange.status.revision, .action = 4 },
        .color = .{ .output = .{ .adapter_id = 1, .connector_id = 4, .device_generation = 2, .connection_generation = 3 },
            .signal = .{ .format = a.gfx_buffer_format_xrgb2101010, .bpc = 10, .pipeline = 7, .transfer = 3 } } };
    try t.expectEqual(unavailable, broker.submitColor(&colored).result);
    exchange.status.phase = 4;
    _ = broker.exchangeColor(&.{ .base = exchange });
    try t.expectEqual(invalid, broker.submit(&colored.base).result);
    try t.expectEqual(ok, broker.submitColor(&colored).result);
    try t.expectEqual(ok, broker.submitColor(&colored).result);
    var drift = colored; drift.color.signal.peak = 99;
    try t.expectEqual(stale, broker.submitColor(&drift).result);
    try t.expectEqual(unavailable, broker.exchange(&exchange).status.result);
    const copied = broker.exchangeColor(&.{ .base = exchange });
    try t.expectEqualDeep(colored.base, copied.base.request);
    try t.expectEqualDeep(colored.color, copied.color);
    colored.color.signal.peak = 42;
    try t.expectEqual(@as(u32, 0), broker.pending_color.?.signal.peak);
    exchange.status.request_id = 9; exchange.status.owner = client;
    _ = broker.exchangeColor(&.{ .base = exchange });
    try t.expect(broker.pending == null and broker.pending_color == null);
    try t.expectEqual(stale, broker.submitColor(&colored).result);
    drift = colored; drift.color.size -= 1;
    try t.expectEqual(invalid, broker.submitColor(&drift).result);
}

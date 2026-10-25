//! WINSVC-owned, copied launch queue. Caller lifetime is deliberately irrelevant
//! after acceptance. Wait RPCs park their request ID, never block the service.
const std = @import("std");
const w = @import("desktop_launch");
pub const capacity = 8;
pub const history_capacity = 16;
const Slot = struct { used: bool = false, claimed: bool = false, value: w.Message = .{}, sequence: u64 = 0, retired: u64 = 0 };
const Waiter = struct { used: bool = false, key: w.Message = .{}, rpc: u32 = 0, deadline: u64 = 0 };
pub const Reply = struct { rpc: u32, value: w.Message };
pub const Queue = struct {
    broker: w.Identity = .{},
    slots: [history_capacity]Slot = .{Slot{}} ** history_capacity,
    waiters: [capacity]Waiter = .{Waiter{}} ** capacity,
    sequence: u64 = 0,

    pub fn lookup(self: *Queue, key: w.Message) ?*Slot {
        for (&self.slots) |*s| if (s.used and s.value.sameKey(key)) return s;
        return null;
    }
    pub fn rejected(self: *const Queue, key: w.Message, code: w.Code) w.Message {
        var out = key;
        out.code = code;
        out.flags |= w.terminal;
        // Preserve the requested key, including a stale service generation.
        _ = self;
        return out;
    }
    pub fn submit(self: *Queue, request: w.Message, desktop: w.Identity, now: u64) w.Message {
        if (!request.broker.eql(self.broker)) return self.rejected(request, .stale_service);
        if (!request.request.valid() or request.phase != .request or request.code != .ok or request.flags & ~w.wait_frame != 0 or
            request.desktop.valid() or request.process.valid() or request.window != 0 or request.raw != 0 or request.content != 0 or w.text(&request.path).len == 0)
            return self.rejected(request, .invalid);
        if (self.lookup(request)) |old| {
            if (old.value.policy != request.policy or old.value.deadline != request.deadline or
                (old.value.flags & w.wait_frame) != request.flags or !std.mem.eql(u8, &old.value.path, &request.path) or
                !std.mem.eql(u8, &old.value.args, &request.args) or !std.mem.eql(u8, &old.value.title, &request.title)) return self.rejected(request, .invalid);
            return old.value;
        }
        if (!desktop.valid()) return self.rejected(request, .no_desktop);
        if (request.deadline <= now) return self.rejected(request, .timeout);
        var active: usize = 0;
        var free: ?*Slot = null;
        var oldest: ?*Slot = null;
        for (&self.slots) |*s| {
            if (!s.used) {
                free = s;
                continue;
            }
            if (!s.value.done()) active += 1 else if (oldest == null or s.sequence < oldest.?.sequence) {
                oldest = s;
            }
        }
        if (active >= capacity) return self.rejected(request, .queue_full);
        const s = free orelse oldest orelse return self.rejected(request, .queue_full);
        self.sequence +|= 1;
        s.* = .{ .used = true, .value = request, .sequence = self.sequence };
        s.value.desktop = desktop;
        s.value.phase = .accepted;
        return s.value;
    }
    pub fn take(self: *Queue, desktop: w.Identity, now: u64) w.Message {
        var selected: ?*Slot = null;
        for (&self.slots) |*s| {
            if (!s.used or s.value.done() or !s.value.desktop.eql(desktop)) continue;
            // Redeliver the SAME ticket until completion. Desktop retains its
            // execution receipt through lost transport replies and never respawns.
            if (s.claimed) return s.value;
            if (now >= s.value.deadline) continue;
            if (selected == null or s.sequence < selected.?.sequence) selected = s;
        }
        if (selected) |s| {
            s.claimed = true;
            s.value.phase = .starting;
            return s.value;
        }
        return .{ .broker = self.broker };
    }
    pub fn complete(self: *Queue, value: w.Message, now: u64) bool {
        const s = self.lookup(value) orelse return false;
        if (!s.claimed or !s.value.desktop.eql(value.desktop) or !value.broker.eql(self.broker) or
            @intFromEnum(value.phase) < @intFromEnum(s.value.phase) or value.phase == .request or value.phase == .accepted or
            (value.phase == .starting and value.code == .ok) or
            (@intFromEnum(value.phase) >= @intFromEnum(w.Phase.process) and !value.process.valid()) or
            (@intFromEnum(value.phase) >= @intFromEnum(w.Phase.window) and value.window == 0) or
            (value.phase == .content and value.content == 0) or
            (s.value.process.valid() and !s.value.process.eql(value.process))) return false;
        if (s.value.done() and s.value.code != .timeout) {
            return s.value.phase == value.phase and s.value.code == value.code and s.value.process.eql(value.process) and
                s.value.window == value.window and s.value.content == value.content and s.value.raw == value.raw;
        }
        s.value.phase = value.phase;
        s.value.code = value.code;
        s.value.process = value.process;
        s.value.window = value.window;
        s.value.content = value.content;
        s.value.raw = value.raw;
        s.value.flags &= ~w.terminal;
        if (value.code != .ok or value.phase == .content or (value.phase == .window and s.value.flags & w.wait_frame == 0)) {
            s.value.flags |= w.terminal;
            s.retired = now;
        } else if (now >= s.value.deadline) {
            s.value.code = .timeout;
            s.value.flags |= w.terminal;
            s.retired = now;
        }
        return true;
    }
    pub fn status(self: *Queue, key: w.Message) w.Message {
        if (!key.broker.eql(self.broker)) return self.rejected(key, .stale_service);
        return if (self.lookup(key)) |s| s.value else self.rejected(key, .unknown);
    }
    pub fn beginWait(self: *Queue, key: w.Message, rpc: u32, now: u64) ?w.Message {
        const value = self.status(key);
        if (value.done()) return value;
        if (key.deadline <= now) return self.rejected(value, .timeout);
        for (&self.waiters) |*waiter| if (!waiter.used) {
            waiter.* = .{ .used = true, .key = key, .rpc = rpc, .deadline = key.deadline };
            return null;
        };
        return self.rejected(value, .queue_full);
    }
    pub fn takeReply(self: *Queue, now: u64) ?Reply {
        for (&self.waiters) |*waiter| {
            if (!waiter.used) continue;
            var value = self.status(waiter.key);
            if (!value.done() and now < waiter.deadline) continue;
            if (!value.done()) value = self.rejected(value, .timeout);
            waiter.used = false;
            return .{ .rpc = waiter.rpc, .value = value };
        }
        return null;
    }
    pub fn maintain(self: *Queue, desktop: w.Identity, now: u64, retention: u64) void {
        for (&self.slots) |*s| {
            if (!s.used) continue;
            if (s.value.done()) {
                if (now >= s.retired +| retention) s.used = false;
                continue;
            }
            const failure: w.Code = if (!s.value.desktop.eql(desktop)) .desktop_lost else if (now >= s.value.deadline) .timeout else .ok;
            if (failure != .ok) {
                s.value.code = failure;
                s.value.flags |= w.terminal;
                s.retired = now;
            }
        }
    }
    pub fn deadline(self: *const Queue) ?u64 {
        var found: ?u64 = null;
        for (self.slots) |s| if (s.used and !s.value.done()) {
            found = @min(found orelse s.value.deadline, s.value.deadline);
        };
        for (self.waiters) |v| if (v.used) {
            found = @min(found orelse v.deadline, v.deadline);
        };
        return found;
    }
};

fn sample(n: u32) w.Message {
    var m = w.Message{ .broker = .{ .instance = 1, .generation = 10 }, .request = .{ .instance = n, .generation = 20 }, .deadline = 100 };
    w.copy(&m.path, "C:\\App.R4X") catch unreachable;
    return m;
}
const desk = w.Identity{ .instance = 2, .generation = 30 };
test "copied queue survives caller exit; retry and completion cannot duplicate launch" {
    var q = Queue{ .broker = sample(3).broker };
    var input = sample(3);
    const key = input;
    try std.testing.expectEqual(w.Phase.accepted, q.submit(input, desk, 1).phase);
    input.path[3] = 'X';
    const work = q.take(desk, 2);
    try std.testing.expectEqualStrings("C:\\App.R4X", w.text(&work.path));
    try std.testing.expectEqual(w.Phase.starting, q.submit(key, desk, 3).phase);
    try std.testing.expect(q.take(desk, 3).sameKey(work));
    var result = work;
    result.phase = .window;
    result.process = .{ .instance = 90, .generation = 99 };
    result.window = 2;
    try std.testing.expect(q.complete(result, 4));
    try std.testing.expect(q.complete(result, 5));
    try std.testing.expect(!q.take(desk, 5).request.valid());
    try std.testing.expect(q.status(key).done());
}
test "deadline, lost reply, late receipt and exact generations" {
    var q = Queue{ .broker = sample(3).broker };
    const key = sample(3);
    _ = q.submit(key, desk, 1);
    var result = q.take(desk, 2);
    try std.testing.expect(q.beginWait(key, 70, 3) == null);
    q.maintain(desk, 100, 6000);
    try std.testing.expectEqual(w.Code.timeout, q.takeReply(100).?.value.code);
    result.phase = .window;
    result.process = .{ .instance = 90, .generation = 99 };
    result.window = 2;
    var stale = result;
    stale.desktop.generation += 1;
    try std.testing.expect(!q.complete(stale, 101));
    try std.testing.expect(q.complete(result, 102));
    try std.testing.expectEqual(w.Code.ok, q.status(key).code);
    q.broker.generation += 1;
    try std.testing.expectEqual(w.Code.stale_service, q.status(key).code);
}
test "bounded queue; desktop replacement never transfers old requests" {
    var q = Queue{ .broker = sample(3).broker };
    for (0..capacity) |i| try std.testing.expectEqual(w.Code.ok, q.submit(sample(@intCast(i + 3)), desk, 1).code);
    try std.testing.expectEqual(w.Code.queue_full, q.submit(sample(99), desk, 1).code);
    try std.testing.expectEqual(w.Code.no_desktop, q.submit(sample(100), .{}, 1).code);
    const next = w.Identity{ .instance = desk.instance, .generation = desk.generation + 1 };
    q.maintain(next, 2, 6000);
    try std.testing.expectEqual(w.Code.desktop_lost, q.status(sample(3)).code);
    try std.testing.expect(!q.take(next, 3).request.valid());
    try std.testing.expectEqual(w.Code.ok, q.submit(sample(99), next, 3).code);
}
test "window receipt does not imply consumed content; wire bounds reject corruption" {
    var q = Queue{ .broker = sample(3).broker };
    var key = sample(3);
    key.flags = w.wait_frame;
    _ = q.submit(key, desk, 1);
    var result = q.take(desk, 2);
    result.phase = .window;
    result.process = .{ .instance = 90, .generation = 99 };
    result.window = 1;
    try std.testing.expect(q.complete(result, 3));
    try std.testing.expect(!q.status(key).done());
    result.phase = .content;
    try std.testing.expect(!q.complete(result, 4));
    result.content = 7;
    try std.testing.expect(q.complete(result, 5));
    try std.testing.expect(q.status(key).done());
    var bytes: [w.size]u8 = undefined;
    w.encode(&bytes, result);
    const decoded = try w.decode(&bytes);
    try std.testing.expect(decoded.sameKey(key));
    bytes[12] = 1;
    try std.testing.expectError(error.InvalidWire, w.decode(&bytes));
}

test "late attachment never satisfies WAITFRAME after expiration" {
    var q = Queue{ .broker = sample(3).broker };
    var key = sample(3);
    key.flags = w.wait_frame;
    _ = q.submit(key, desk, 1);
    var result = q.take(desk, 2);
    q.maintain(desk, 100, 6000);
    result.phase = .window;
    result.process = .{ .instance = 90, .generation = 99 };
    result.window = 1;
    try std.testing.expect(q.complete(result, 101));
    try std.testing.expectEqual(w.Code.timeout, q.status(key).code);
    result.phase = .content;
    result.content = 4;
    try std.testing.expect(q.complete(result, 102));
    try std.testing.expectEqual(w.Code.ok, q.status(key).code);
    try std.testing.expectEqual(w.Phase.content, q.status(key).phase);
}

//! WINSVC-owned, copied launch queue. Caller lifetime is deliberately irrelevant
//! after acceptance. Wait RPCs park their request ID, never block the service.
const std = @import("std");
const w = @import("desktop_launch");
pub const capacity = 8;
pub const history_capacity = 16;
const Slot = struct { used: bool = false, claimed: bool = false, settled: bool = false, value: w.Message = .{}, sequence: u64 = 0, retired: u64 = 0, evidence: u64 = 0 };
const Waiter = struct { used: bool = false, key: w.Message = .{}, rpc: u32 = 0, deadline: u64 = 0 };
pub const Reply = struct { rpc: u32, value: w.Message };
/// The broker owns one creator-bound kernel reference per retained ticket.
/// Tests can exercise eviction/ACK ordering without importing platform tables.
pub const Evidence = struct {
    context: ?*const anyopaque = null,
    retain: ?*const fn (?*const anyopaque, w.Identity) u64 = null,
    release: ?*const fn (?*const anyopaque, w.Identity, u64) bool = null,
};
pub const Queue = struct {
    evidence: Evidence = .{},
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
        if (!request.request.valid() or request.phase != .request or request.code != .ok or request.flags & ~w.request_flags != 0 or
            request.desktop.valid() or request.process.valid() or request.window != 0 or request.raw != 0 or request.content != 0 or w.text(&request.path).len == 0)
            return self.rejected(request, .invalid);
        if (self.lookup(request)) |old| {
            if (old.value.policy != request.policy or old.value.deadline != request.deadline or
                (old.value.flags & w.request_flags) != request.flags or !std.mem.eql(u8, &old.value.path, &request.path) or
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
            if (!s.value.done() or (s.claimed and !s.settled)) active += 1 else if (oldest == null or s.sequence < oldest.?.sequence) {
                oldest = s;
            }
        }
        if (active >= capacity) return self.rejected(request, .queue_full);
        const s = free orelse oldest orelse return self.rejected(request, .queue_full);
        if (s.used and !self.drop(s)) return self.rejected(request, .queue_full);
        self.sequence +|= 1;
        s.* = .{ .used = true, .value = request, .sequence = self.sequence };
        s.value.desktop = desktop;
        s.value.phase = .accepted;
        return s.value;
    }
    pub fn take(self: *Queue, desktop: w.Identity, now: u64) w.Message {
        var selected: ?*Slot = null;
        for (&self.slots) |*s| {
            if (!s.used or !s.value.desktop.eql(desktop)) continue;
            // Redeliver the SAME ticket until completion. Desktop retains its
            // execution receipt through lost transport replies and never respawns.
            // Caller timeout does not acknowledge an asynchronous loader. Keep
            // its mailbox and history until the Desktop returns the real result.
            if (s.claimed and !s.settled) return s.value;
            if (s.value.done()) continue;
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
            (value.flags & w.request_flags) != (s.value.flags & w.request_flags) or
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
        // Desktop holds its temporary exact reference until this completion
        // ACK. Acquire the broker's own binding before returning that ACK.
        if (s.evidence == 0 and s.value.flags & w.retain_evidence != 0 and value.process.valid()) {
            if (self.evidence.retain) |retain| s.evidence = retain(self.evidence.context, value.process);
            if (s.evidence == 0) s.value.flags |= w.evidence_unavailable else s.value.flags &= ~w.evidence_unavailable;
        }
        s.value.flags &= ~w.terminal;
        if (value.code != .ok or value.phase == .content or (value.phase == .window and s.value.flags & w.wait_frame == 0)) {
            s.value.flags |= w.terminal;
            s.retired = now;
        } else if (now >= s.value.deadline) {
            s.value.code = .timeout;
            s.value.flags |= w.terminal;
            s.retired = now;
        }
        s.settled = s.value.done();
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
    fn drop(self: *Queue, slot: *Slot) bool {
        if (slot.evidence != 0) {
            const release = self.evidence.release orelse return false;
            if (!release(self.evidence.context, slot.value.process, slot.evidence)) return false;
        }
        slot.* = .{};
        return true;
    }
    pub fn maintain(self: *Queue, desktop: w.Identity, now: u64, retention: u64) void {
        for (&self.slots) |*s| {
            if (!s.used) continue;
            if (s.claimed and !s.settled and !s.value.desktop.eql(desktop)) {
                s.value.code = .desktop_lost;
                s.value.flags |= w.terminal;
                s.retired = now;
                s.settled = true;
            }
            if (s.value.done()) {
                if ((!s.claimed or s.settled) and now >= s.retired +| retention) _ = self.drop(s);
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

test "caller timeout retains the claimed mailbox until the actual late result" {
    var q = Queue{ .broker = sample(3).broker };
    const first = sample(3);
    _ = q.submit(first, desk, 1);
    var result = q.take(desk, 2);
    var next = sample(4);
    next.deadline = 20000;
    _ = q.submit(next, desk, 3);
    q.maintain(desk, 101, 60);
    try std.testing.expectEqual(w.Code.timeout, q.status(first).code);
    try std.testing.expect(q.take(desk, 102).sameKey(first));
    q.maintain(desk, 10000, 60);
    try std.testing.expect(q.take(desk, 10001).sameKey(first));
    result.phase = .window;
    result.process = .{ .instance = 90, .generation = 99 };
    result.window = 2;
    try std.testing.expect(q.complete(result, 10002));
    try std.testing.expect(q.complete(result, 10003)); // lost ACK, same result.
    try std.testing.expect(q.status(first).process.eql(result.process));
    try std.testing.expect(q.take(desk, 10004).sameKey(next));
}

test "history pressure cannot evict an unacknowledged timed-out loader" {
    var q = Queue{ .broker = sample(3).broker };
    const first = sample(3);
    _ = q.submit(first, desk, 1);
    var result = q.take(desk, 2);
    q.maintain(desk, 101, 60000);
    for (0..history_capacity * 2) |i| {
        const now: u64 = 102 + i * 3;
        var other = sample(@intCast(4 + i));
        other.deadline = now + 1;
        try std.testing.expectEqual(w.Code.ok, q.submit(other, desk, now).code);
        q.maintain(desk, now + 2, 60000);
    }
    try std.testing.expect(q.take(desk, 300).sameKey(first));
    // The Desktop may acknowledge that its expired job never reached spawn.
    result.code = .timeout;
    result.flags |= w.terminal;
    try std.testing.expect(q.complete(result, 301));
    try std.testing.expect(q.complete(result, 302));
    var next = sample(99);
    next.deadline = 1000;
    _ = q.submit(next, desk, 303);
    try std.testing.expect(q.take(desk, 304).sameKey(next));
    try std.testing.expect(!q.status(first).process.valid());
}

test "desktop replacement settles an expired claim without transferring it" {
    var q = Queue{ .broker = sample(3).broker };
    const first = sample(3);
    _ = q.submit(first, desk, 1);
    _ = q.take(desk, 2);
    q.maintain(desk, 101, 60);
    const replacement = w.Identity{ .instance = desk.instance, .generation = desk.generation + 1 };
    q.maintain(replacement, 102, 60);
    try std.testing.expectEqual(w.Code.desktop_lost, q.status(first).code);
    try std.testing.expect(!q.take(replacement, 103).request.valid());
    q.maintain(replacement, 163, 60);
    try std.testing.expectEqual(w.Code.unknown, q.status(first).code);
}

test "evidence survives helper exit and duplicate ACK; retirement waits for release" {
    const Hooks = struct {
        retained: u32 = 0,
        released: u32 = 0,
        fail_release: bool = true,
        fn retain(raw: ?*const anyopaque, process: w.Identity) u64 {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw.?)));
            std.debug.assert(process.instance == 30 and process.generation == 31);
            self.retained += 1;
            return self.retained;
        }
        fn release(raw: ?*const anyopaque, process: w.Identity, id: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw.?)));
            std.debug.assert(process.instance == 30 and process.generation == 31 and id != 0);
            if (self.fail_release) {
                self.fail_release = false;
                return false;
            }
            self.released += 1;
            return true;
        }
    };
    var hooks = Hooks{};
    var queue = Queue{ .broker = .{ .instance = 1, .generation = 2 }, .evidence = .{ .context = &hooks, .retain = Hooks.retain, .release = Hooks.release } };
    const desktop = w.Identity{ .instance = 10, .generation = 11 };
    var request = w.Message{ .broker = queue.broker, .request = .{ .instance = 20, .generation = 21 }, .flags = w.retain_evidence, .deadline = 10000 };
    try w.copy(&request.path, "C:\\TEST.R4X");
    try std.testing.expect(queue.submit(request, desktop, 0).code == .ok);
    var result = queue.take(desktop, 1);
    result.phase = .window;
    result.window = 1;
    result.process = .{ .instance = 30, .generation = 31 };
    try std.testing.expect(queue.complete(result, 2));
    try std.testing.expect(queue.complete(result, 3));
    try std.testing.expectEqual(@as(u32, 1), hooks.retained);
    try std.testing.expect(queue.status(request).flags & w.evidence_unavailable == 0);
    queue.maintain(desktop, 102, 100);
    try std.testing.expect(queue.lookup(request) != null); // no false release ACK
    queue.maintain(desktop, 103, 100);
    try std.testing.expect(queue.lookup(request) == null);
    try std.testing.expectEqual(@as(u32, 1), hooks.released);
    try std.testing.expect(!queue.complete(result, 104));

    // Explicit retention failure reports unavailable without changing the
    // actual successful launch result or inventing a process exit code.
    queue.evidence = .{};
    request.request.generation += 1;
    try std.testing.expect(queue.submit(request, desktop, 105).code == .ok);
    result = queue.take(desktop, 106);
    result.phase = .window;
    result.window = 1;
    result.process = .{ .instance = 30, .generation = 31 };
    try std.testing.expect(queue.complete(result, 107));
    const failed = queue.status(request);
    try std.testing.expect(failed.code == .ok and failed.flags & w.evidence_unavailable != 0);
    queue.evidence = .{ .context = &hooks, .retain = Hooks.retain, .release = Hooks.release };
    // Admission beyond the bounded history evicts through the same real
    // release acknowledgement; every successful reference is eventually freed.
    for (0..history_capacity + 1) |i| {
        request.request.generation += 1;
        const now = 200 + i * 3;
        try std.testing.expect(queue.submit(request, desktop, now).code == .ok);
        result = queue.take(desktop, now + 1);
        result.phase = .window;
        result.window = 1;
        result.process = .{ .instance = 30, .generation = 31 };
        try std.testing.expect(queue.complete(result, now + 2));
    }
    try std.testing.expect(hooks.released > 1); // at least one bound record evicted
    queue.maintain(desktop, 20000, 100);
    try std.testing.expectEqual(hooks.retained, hooks.released);
}

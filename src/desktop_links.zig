//! One prepared own-link binding, one Desktop activation, retained original receipt.
//! Service-loop owner only. Status performs no Start/Retain/Release or reap.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const evidence = @import("desktop_evidence.zig");
const Token = a.DesktopLinkToken;
const Request = a.DesktopLinkRequest;
const Reply = a.DesktopLinkReply;
const Slot = struct { used: bool = false, received: bool = false, value: Reply = .{}, binding: u64 = 0 };
fn valid(p: a.ProgramProcessHandle) bool {
    return p.instance_id != 0 and p.generation != 0 and p.reserved == 0;
}
fn same(x: a.ProgramProcessHandle, y: a.ProgramProcessHandle) bool {
    return std.meta.eql(x, y);
}
fn nonzero(v: [3]u64) bool {
    return v[0] | v[1] | v[2] != 0;
}
fn text(v: []const u8) []const u8 {
    return v[0 .. std.mem.indexOfScalar(u8, v, 0) orelse v.len];
}
fn zvalid(v: []const u8) bool {
    const n = text(v).len;
    return n < v.len and std.unicode.utf8ValidateSlice(v[0..n]) and std.mem.allEqual(u8, v[n..], 0);
}
fn bindingValid(q: Request) bool {
    if (q.reserved != 0 or !zvalid(&q.link_path) or q.link_length == 0 or q.link_length > q.link_bytes.len or
        !std.mem.allEqual(u8, q.link_bytes[q.link_length..], 0) or !std.unicode.utf8ValidateSlice(q.link_bytes[0..q.link_length]) or
        std.mem.indexOfScalar(u8, q.link_bytes[0..q.link_length], 0) != null) return false;
    const path = text(&q.link_path);
    if (!std.ascii.endsWithIgnoreCase(path, ".LNK")) return false;
    const canonical = r4os.path.AbsoluteFilePath.parse(path) catch return false;
    return std.mem.eql(u8, canonical.bytes(), path);
}
fn keyValid(t: Token) bool {
    return t.version == 1 and t.size == @sizeOf(Token) and valid(t.service) and valid(t.owner) and nonzero(t.epoch) and nonzero(t.intent);
}
fn reject(q: Request, code: i32) Reply {
    return .{ .request = q, .result = code, .flags = a.desktop_link_capabilities };
}
pub const Broker = struct {
    service: a.ProgramProcessHandle = .{},
    epoch: [3]u64 = .{0} ** 3,
    serial: u64 = 0,
    backend: evidence.Backend = .{},
    gone: ?*const fn (?*const anyopaque, a.ProgramProcessHandle) bool = null,
    slots: [a.desktop_link_max_leases]Slot = .{Slot{}} ** a.desktop_link_max_leases,
    pub fn scope(self: *const Broker) Reply {
        return .{ .request = .{ .token = .{ .service = self.service, .epoch = self.epoch } }, .flags = if (valid(self.service) and nonzero(self.epoch)) a.desktop_link_capabilities else 0, .result = if (valid(self.service) and nonzero(self.epoch)) 0 else a.desktop_link_result_unavailable };
    }
    fn scoped(self: *const Broker, t: Token) bool {
        return keyValid(t) and same(t.service, self.service) and std.meta.eql(t.epoch, self.epoch);
    }
    fn find(self: *const Broker, t: Token) ?usize {
        if (!self.scoped(t)) return null;
        for (self.slots, 0..) |s, i| if (s.used and same(t.owner, s.value.request.token.owner) and std.meta.eql(t.intent, s.value.request.token.intent) and (t.serial == 0 or t.serial == s.value.request.token.serial)) return i;
        return null;
    }
    fn identical(q: Request, old: Request) bool {
        var copy = q;
        copy.token.serial = old.token.serial;
        return std.meta.eql(copy, old);
    }
    fn missing(self: *const Broker, q: Request) Reply {
        return reject(q, if (!keyValid(q.token)) a.desktop_link_result_invalid else if (!self.scoped(q.token)) a.desktop_link_result_stale else a.desktop_link_result_unknown);
    }
    pub fn prepare(self: *Broker, q: Request, caller: a.ProgramProcessHandle, now: u64, max_duration: u64) Reply {
        if (!self.scoped(q.token)) return self.missing(q);
        if (!same(caller, q.token.owner)) return reject(q, a.desktop_link_result_not_owner);
        if (q.token.serial != 0 or !bindingValid(q)) return reject(q, a.desktop_link_result_invalid);
        if (self.find(q.token)) |i| return if (identical(q, self.slots[i].value.request)) self.status(q, now) else reject(q, a.desktop_link_result_changed);
        if (q.deadline <= now or q.deadline - now > max_duration) return reject(q, a.desktop_link_result_expired);
        if (self.serial == std.math.maxInt(u64)) return reject(q, a.desktop_link_result_quota);
        var free: ?usize = null;
        for (&self.slots, 0..) |*s, i| {
            if (s.used and (s.value.phase == a.desktop_link_phase_prepared or s.value.phase == a.desktop_link_phase_accepted) and now >= s.value.request.deadline) s.value.phase = a.desktop_link_phase_expired;
            if (!s.used or (s.binding == 0 and (s.value.phase == a.desktop_link_phase_cleaned or s.value.phase == a.desktop_link_phase_expired or s.value.phase == a.desktop_link_phase_rejected))) {
                free = i;
                break;
            }
        }
        const i = free orelse return reject(q, a.desktop_link_result_quota);
        self.serial += 1;
        self.slots[i] = .{ .used = true, .value = .{ .request = q, .phase = a.desktop_link_phase_prepared, .flags = a.desktop_link_capabilities } };
        self.slots[i].value.request.token.serial = self.serial;
        return self.slots[i].value;
    }
    pub fn activate(self: *Broker, q: Request, caller: a.ProgramProcessHandle, desktop: a.ProgramProcessHandle, now: u64) Reply {
        const i = self.find(q.token) orelse return self.missing(q);
        const s = &self.slots[i];
        if (!same(caller, q.token.owner)) return reject(q, a.desktop_link_result_not_owner);
        if (q.token.serial == 0 or !std.meta.eql(q, s.value.request)) return reject(q, a.desktop_link_result_changed);
        // Every post-acceptance call returns the original. Never enqueue again.
        if (s.value.phase != a.desktop_link_phase_prepared) return self.status(q, now);
        if (now >= q.deadline) {
            s.value.phase = a.desktop_link_phase_expired;
            s.value.result = a.desktop_link_result_expired;
            return s.value;
        }
        if (!valid(desktop)) return reject(q, a.desktop_link_result_unavailable);
        s.value.desktop = desktop;
        s.value.accepted_tick = now;
        s.value.phase = a.desktop_link_phase_accepted;
        return s.value;
    }
    pub fn take(self: *Broker, desktop: a.ProgramProcessHandle, now: u64) Reply {
        for (&self.slots) |*s| {
            if (!s.used or !same(s.value.desktop, desktop) or s.received) continue;
            if (s.value.phase == a.desktop_link_phase_accepted) {
                if (now >= s.value.request.deadline) {
                    s.value.phase = a.desktop_link_phase_expired;
                    s.value.result = a.desktop_link_result_expired;
                    continue;
                }
                s.value.phase = a.desktop_link_phase_starting;
            }
            if (s.value.phase == a.desktop_link_phase_starting) return s.value;
        }
        return self.scope();
    }
    pub fn report(self: *Broker, r: Reply, desktop: a.ProgramProcessHandle) bool {
        const i = self.find(r.request.token) orelse return false;
        const s = &self.slots[i];
        if (!same(desktop, s.value.desktop) or !same(r.desktop, desktop) or !std.meta.eql(r.request, s.value.request) or s.value.phase < a.desktop_link_phase_starting or s.value.phase == a.desktop_link_phase_cleaned or s.value.phase == a.desktop_link_phase_expired) return false;
        if (s.value.phase == a.desktop_link_phase_rejected) return r.phase == s.value.phase and r.result == s.value.result and !valid(r.process);
        if (r.phase == a.desktop_link_phase_starting) {
            s.received = true;
            return true;
        }
        if (r.phase == a.desktop_link_phase_rejected and !valid(s.value.process) and !valid(r.process) and r.result < 0) {
            s.value.result = r.result;
            s.value.phase = r.phase;
            s.received = true;
            return true;
        }
        if ((r.phase != a.desktop_link_phase_process and r.phase != a.desktop_link_phase_ready) or !valid(r.process) or r.started_tick == 0 or
            r.flags & a.desktop_link_flag_validated == 0 or !zvalid(&r.resolved_path) or !zvalid(&r.resolved_args) or text(&r.resolved_path).len == 0 or
            r.policy > 2 or (r.phase == a.desktop_link_phase_ready and (r.ready_tick == 0 or r.content_generation == 0))) return false;
        if (valid(s.value.process) and (!same(s.value.process, r.process) or s.value.started_tick != r.started_tick or !std.mem.eql(u8, &s.value.resolved_path, &r.resolved_path) or !std.mem.eql(u8, &s.value.resolved_args, &r.resolved_args) or s.value.policy != r.policy)) return false;
        if (s.value.ready_tick != 0 and (s.value.ready_tick != r.ready_tick or s.value.content_generation != r.content_generation)) return false;
        if (s.binding == 0) {
            const retain = self.backend.retain orelse return false;
            s.binding = retain(self.backend.context, r.process);
            if (s.binding == 0) return false;
        }
        s.value.result = r.result;
        s.value.process = r.process;
        s.value.started_tick = r.started_tick;
        s.value.resolved_path = r.resolved_path;
        s.value.resolved_args = r.resolved_args;
        s.value.policy = r.policy;
        s.value.flags |= a.desktop_link_flag_validated;
        s.received = true;
        if (r.phase > s.value.phase) s.value.phase = r.phase;
        s.value.ready_tick = r.ready_tick;
        s.value.content_generation = r.content_generation;
        return true;
    }
    pub fn status(self: *const Broker, q: Request, now: u64) Reply {
        const i = self.find(q.token) orelse return self.missing(q);
        const s = &self.slots[i];
        if (!identical(q, s.value.request)) return reject(q, a.desktop_link_result_changed);
        var out = s.value;
        if ((out.phase == a.desktop_link_phase_prepared or out.phase == a.desktop_link_phase_accepted) and now >= out.request.deadline) {
            out.phase = a.desktop_link_phase_expired;
            out.result = a.desktop_link_result_expired;
        }
        if (s.binding != 0) if (self.backend.query) |query| {
            var completion: a.ProgramProcessCompletion = .{};
            if (query(self.backend.context, out.process, s.binding, &completion) == 0 and same(completion.handle, out.process) and completion.sequence != 0 and completion.flags & a.program_completion_flag_ready != 0) {
                out.completion = completion;
                out.flags |= a.desktop_link_flag_ended;
                out.phase = a.desktop_link_phase_ended;
                if (self.gone) |gone| if (gone(self.backend.context, out.process)) {
                    out.flags |= a.desktop_link_flag_reaped;
                };
            }
        };
        return out;
    }
    pub fn release(self: *Broker, q: Request, now: u64) Reply {
        var out = self.status(q, now);
        const i = self.find(q.token) orelse return out;
        if (q.token.serial == 0 or !std.meta.eql(q, self.slots[i].value.request)) return reject(q, a.desktop_link_result_changed);
        const s = &self.slots[i];
        if (out.phase == a.desktop_link_phase_cleaned) return out;
        if (out.phase == a.desktop_link_phase_starting or (valid(out.process) and out.flags & (a.desktop_link_flag_ended | a.desktop_link_flag_reaped) != (a.desktop_link_flag_ended | a.desktop_link_flag_reaped))) return reject(q, a.desktop_link_result_pending);
        if (s.binding != 0) {
            const free = self.backend.release orelse return reject(q, a.desktop_link_result_pending);
            if (!free(self.backend.context, out.process, s.binding)) return reject(q, a.desktop_link_result_pending);
            s.binding = 0;
        }
        out.phase = a.desktop_link_phase_cleaned;
        out.cleanup_tick = now;
        out.flags |= a.desktop_link_flag_released;
        s.value = out;
        return out;
    }
    pub fn clear(self: *Broker) void {
        for (&self.slots) |*s| if (s.used) {
            if (s.binding != 0) {
                const free = self.backend.release orelse continue;
                if (!free(self.backend.context, s.value.process, s.binding)) continue;
            }
            s.* = .{};
        };
    }
};

const Fake = struct {
    var retains: u32 = 0;
    var releases: u32 = 0;
    var ended: bool = false;
    var reaped: bool = false;
    fn retain(_: ?*const anyopaque, _: a.ProgramProcessHandle) u64 {
        retains += 1;
        return 9;
    }
    fn free(_: ?*const anyopaque, _: a.ProgramProcessHandle, _: u64) bool {
        releases += 1;
        return true;
    }
    fn query(_: ?*const anyopaque, process: a.ProgramProcessHandle, _: u64, out: *a.ProgramProcessCompletion) i32 {
        if (!ended) return a.program_handle_error_would_block;
        out.* = .{ .handle = process, .sequence = 18, .finish_tick = 20, .flags = a.program_completion_flag_ready, .exit_code = 37 };
        return 0;
    }
    fn gone(_: ?*const anyopaque, _: a.ProgramProcessHandle) bool {
        return reaped;
    }
};
fn testHandle(id: u32) a.ProgramProcessHandle {
    return .{ .instance_id = id, .generation = 700 + id };
}
fn testRequest(b: *const Broker) Request {
    var q: Request = .{ .token = .{ .service = b.service, .owner = testHandle(3), .epoch = b.epoch, .intent = .{ 1, 2, 3 } }, .deadline = 100, .link_length = 3 };
    const path = "C:\\TEMP\\OWN.LNK";
    @memcpy(q.link_path[0..path.len], path);
    @memcpy(q.link_bytes[0..3], "abc");
    return q;
}
test "own link original survives lost replies and never repeats a start or lifecycle cleanup" {
    Fake.retains = 0;
    Fake.releases = 0;
    Fake.ended = false;
    Fake.reaped = false;
    var b: Broker = .{ .service = testHandle(1), .epoch = .{ 4, 5, 6 }, .backend = .{ .retain = Fake.retain, .release = Fake.free, .query = Fake.query }, .gone = Fake.gone };
    const intent = testRequest(&b);
    const saved = b.prepare(intent, testHandle(3), 1, 200).request;
    try std.testing.expect(saved.token.serial != 0);
    try std.testing.expectEqual(saved.token.serial, b.status(intent, 2).request.token.serial);
    var changed = saved;
    changed.link_bytes[0] = 'x';
    try std.testing.expectEqual(a.desktop_link_result_changed, b.activate(changed, testHandle(3), testHandle(2), 3).result);
    try std.testing.expectEqual(a.desktop_link_result_not_owner, b.activate(saved, testHandle(4), testHandle(2), 3).result);
    const accepted = b.activate(saved, testHandle(3), testHandle(2), 4);
    try std.testing.expectEqual(a.desktop_link_phase_accepted, accepted.phase);
    try std.testing.expect(std.meta.eql(accepted, b.activate(saved, testHandle(3), testHandle(2), 5)));
    var original = b.take(testHandle(2), 6);
    try std.testing.expect(std.meta.eql(original, b.take(testHandle(2), 7)));
    try std.testing.expect(b.report(original, testHandle(2)));
    try std.testing.expectEqual(@as(u64, 0), b.take(testHandle(2), 8).request.token.serial);
    original.phase = a.desktop_link_phase_process;
    original.process = testHandle(8);
    original.started_tick = 9;
    original.flags |= a.desktop_link_flag_validated;
    @memcpy(original.resolved_path[0..13], "C:\\TEMP\\G.R4X");
    try std.testing.expect(b.report(original, testHandle(2)));
    try std.testing.expect(b.report(original, testHandle(2)));
    try std.testing.expectEqual(@as(u32, 1), Fake.retains);
    original.phase = a.desktop_link_phase_ready;
    original.ready_tick = 12;
    original.content_generation = 1;
    try std.testing.expect(b.report(original, testHandle(2)));
    try std.testing.expectEqual(a.desktop_link_phase_ready, b.status(saved, 13).phase);
    try std.testing.expectEqual(@as(u32, 0), Fake.releases);
    Fake.ended = true;
    try std.testing.expectEqual(a.desktop_link_result_pending, b.release(saved, 21).result);
    Fake.reaped = true;
    const observed = b.status(saved, 22);
    try std.testing.expectEqual(@as(i32, 37), observed.completion.exit_code);
    try std.testing.expectEqual(@as(u32, 0), Fake.releases);
    const cleaned = b.release(saved, 23);
    try std.testing.expectEqual(a.desktop_link_phase_cleaned, cleaned.phase);
    try std.testing.expect(std.meta.eql(cleaned, b.release(saved, 24)));
    try std.testing.expectEqual(@as(u32, 1), Fake.releases);
    _ = b.activate(saved, testHandle(3), testHandle(2), 25);
    try std.testing.expectEqual(@as(u64, 0), b.take(testHandle(2), 26).request.token.serial);
}
test "link binding original deadline and service epoch reject stale and replaced records" {
    var b: Broker = .{ .service = testHandle(1), .epoch = .{ 4, 5, 6 } };
    const intent = testRequest(&b);
    const saved = b.prepare(intent, testHandle(3), 1, 200).request;
    var changed = intent;
    changed.deadline += 1;
    try std.testing.expectEqual(a.desktop_link_result_changed, b.prepare(changed, testHandle(3), 2, 200).result);
    try std.testing.expectEqual(a.desktop_link_phase_expired, b.activate(saved, testHandle(3), testHandle(2), 101).phase);
    var next = intent;
    next.token.intent[0] = 9;
    next.deadline = 200;
    const replacement = b.prepare(next, testHandle(3), 102, 200);
    try std.testing.expect(replacement.request.token.serial != saved.token.serial);
    try std.testing.expectEqual(a.desktop_link_result_unknown, b.activate(saved, testHandle(3), testHandle(2), 103).result);
    b.epoch[0] += 1;
    try std.testing.expectEqual(a.desktop_link_result_stale, b.activate(replacement.request, testHandle(3), testHandle(2), 104).result);
}

test "accepted link with no Desktop offer expires without manufacturing a start" {
    var b: Broker = .{ .service = testHandle(1), .epoch = .{ 4, 5, 6 } };
    const intent = testRequest(&b);
    const saved = b.prepare(intent, testHandle(3), 1, 200).request;
    _ = b.activate(saved, testHandle(3), testHandle(2), 2);
    const expired = b.status(saved, 101);
    try std.testing.expectEqual(a.desktop_link_phase_expired, expired.phase);
    try std.testing.expectEqual(@as(u32, 0), expired.process.instance_id);
    try std.testing.expectEqual(@as(u64, 0), b.take(testHandle(2), 102).request.token.serial);
    try std.testing.expectEqual(a.desktop_link_phase_expired, b.activate(saved, testHandle(3), testHandle(2), 103).phase);
}

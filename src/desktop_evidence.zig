//! WINSVC owns these evidence references. Portable tokens name reservations,
//! never raw kernel bindings or process lifecycle rights. All methods run on
//! the existing service loop; no worker, background scan or new process owner.
const std = @import("std");
const a = @import("r4os").abi;

const reserved = a.desktop_evidence_phase_reserved;
const waiting = a.desktop_evidence_phase_waiting;
const offered = a.desktop_evidence_phase_offered;
const acknowledged = a.desktop_evidence_phase_acknowledged;
const released = a.desktop_evidence_phase_released;
const expired = a.desktop_evidence_phase_expired;
const unavailable = a.desktop_evidence_phase_unavailable;

pub const Backend = struct {
    context: ?*const anyopaque = null,
    retain: ?*const fn (?*const anyopaque, a.ProgramProcessHandle) u64 = null,
    release: ?*const fn (?*const anyopaque, a.ProgramProcessHandle, u64) bool = null,
    query: ?*const fn (?*const anyopaque, a.ProgramProcessHandle, u64, *a.ProgramProcessCompletion) i32 = null,
    read: ?*const fn (?*const anyopaque, a.ProgramProcessHandle, u64, u32, []u8, *u32) i32 = null,
};

/// Copied from the authoritative launch slot, after its own early reference
/// has been acquired and before Desktop receives the completion ACK.
pub const Source = struct {
    request: a.ProgramProcessHandle,
    process: a.ProgramProcessHandle = .{},
    desktop: a.ProgramProcessHandle = .{},
    protected: bool = false,
    terminal: bool = false,
};

const Slot = struct {
    used: bool = false,
    token: a.DesktopEvidenceToken = .{},
    phase: u32 = reserved,
    deadline: u64 = 0,
    retry_at: u64 = 0,
    binding: u64 = 0,
    revision: u64 = 1,
};

fn validProcess(p: a.ProgramProcessHandle) bool {
    return p.instance_id != 0 and p.generation != 0 and p.reserved == 0;
}
fn optionalProcess(p: a.ProgramProcessHandle) bool {
    return p.reserved == 0 and ((p.instance_id == 0 and p.generation == 0) or validProcess(p));
}
fn sameProcess(x: a.ProgramProcessHandle, y: a.ProgramProcessHandle) bool {
    return std.meta.eql(x, y);
}
fn nonzero(words: [3]u64) bool {
    return words[0] | words[1] | words[2] != 0;
}
fn validToken(t: a.DesktopEvidenceToken) bool {
    return t.version == 1 and t.size == @sizeOf(a.DesktopEvidenceToken) and
        validProcess(t.broker) and validProcess(t.request) and
        optionalProcess(t.process) and optionalProcess(t.desktop) and
        nonzero(t.epoch) and nonzero(t.intent);
}
fn terminal(phase: u32) bool {
    return phase == released or phase == expired or phase == unavailable;
}

pub const Broker = struct {
    backend: Backend = .{},
    service: a.ProgramProcessHandle = .{},
    epoch: [3]u64 = .{0} ** 3,
    serial: u64 = 0,
    slots: [a.desktop_evidence_max_leases]Slot = .{Slot{}} ** a.desktop_evidence_max_leases,

    pub fn ready(self: *const Broker) bool {
        return validProcess(self.service) and nonzero(self.epoch);
    }
    pub fn scope(self: *const Broker) a.DesktopEvidenceReply {
        return .{ .token = .{ .broker = self.service, .epoch = self.epoch }, .result = if (self.ready()) 0 else a.desktop_evidence_result_unavailable };
    }
    fn reject(token: a.DesktopEvidenceToken, result: i32) a.DesktopEvidenceReply {
        return .{ .token = token, .result = result };
    }
    fn scoped(self: *const Broker, token: a.DesktopEvidenceToken) bool {
        return self.ready() and sameProcess(token.broker, self.service) and std.meta.eql(token.epoch, self.epoch);
    }
    fn keyMatches(s: *const Slot, t: a.DesktopEvidenceToken) bool {
        return sameProcess(s.token.request, t.request) and std.meta.eql(s.token.intent, t.intent) and
            (t.serial == 0 or t.serial == s.token.serial) and
            (!validProcess(t.process) or sameProcess(s.token.process, t.process)) and
            (!validProcess(t.desktop) or sameProcess(s.token.desktop, t.desktop));
    }
    fn lookup(self: *Broker, token: a.DesktopEvidenceToken) ?*Slot {
        for (&self.slots) |*s| if (s.used and keyMatches(s, token)) return s;
        return null;
    }
    fn checked(self: *Broker, token: a.DesktopEvidenceToken) ?*Slot {
        if (!validToken(token) or !self.scoped(token)) return null;
        return self.lookup(token);
    }
    fn missing(self: *const Broker, token: a.DesktopEvidenceToken) a.DesktopEvidenceReply {
        return reject(token, if (!validToken(token)) a.desktop_evidence_result_invalid else if (!self.scoped(token)) a.desktop_evidence_result_stale else a.desktop_evidence_result_unknown);
    }
    fn reply(s: *const Slot, now: u64) a.DesktopEvidenceReply {
        const overdue = !terminal(s.phase) and s.phase != acknowledged and now >= s.deadline;
        const phase = if (overdue) expired else s.phase;
        const code: i32 = switch (phase) {
            released => a.desktop_evidence_result_released,
            expired => a.desktop_evidence_result_expired,
            unavailable => a.desktop_evidence_result_unavailable,
            reserved, waiting => a.desktop_evidence_result_pending,
            else => 0,
        };
        return .{ .token = s.token, .result = code, .phase = phase, .deadline = if (phase == acknowledged or terminal(phase)) 0 else s.deadline, .revision = s.revision };
    }
    /// No Retain. The returned nonzero serial must be saved before Offer.
    pub fn reserve(self: *Broker, token: a.DesktopEvidenceToken, now: u64, deadline: u64) a.DesktopEvidenceReply {
        if (!validToken(token) or token.serial != 0 or validProcess(token.process) or validProcess(token.desktop) or deadline <= now) return reject(token, a.desktop_evidence_result_invalid);
        if (!self.scoped(token)) return self.missing(token);
        if (self.lookup(token)) |s| return reply(s, now);
        if (self.serial == std.math.maxInt(u64)) return reject(token, a.desktop_evidence_result_quota);
        var selected: ?*Slot = null;
        for (&self.slots) |*s| {
            if (!s.used) {
                selected = s;
                break;
            }
            // Active reservations/leases and a failed physical release are
            // never evicted to make room for somebody else's request.
            if (terminal(s.phase) and s.binding == 0 and (selected == null or s.token.serial < selected.?.token.serial)) selected = s;
        }
        const s = selected orelse return reject(token, a.desktop_evidence_result_quota);
        self.serial += 1;
        s.* = .{ .used = true, .token = token, .deadline = deadline };
        s.token.serial = self.serial;
        return reply(s, now);
    }
    fn promote(self: *Broker, s: *Slot, source: Source, now: u64) void {
        if (s.phase != waiting or now >= s.deadline or !sameProcess(s.token.request, source.request)) return;
        if (!validProcess(source.process)) {
            if (source.terminal) {
                s.phase = unavailable;
                s.revision += 1;
            }
            return;
        }
        s.token.process = source.process;
        s.token.desktop = source.desktop;
        // An already lost bridge is not reconstructed by a post-hoc Retain.
        // The authoritative launch slot must still own the original evidence.
        if (source.protected) if (self.backend.retain) |retain| {
            s.binding = retain(self.backend.context, source.process);
        };
        s.phase = if (s.binding == 0) unavailable else offered;
        s.revision += 1;
    }
    pub fn offer(self: *Broker, token: a.DesktopEvidenceToken, source: ?Source, now: u64) a.DesktopEvidenceReply {
        if (token.serial == 0) return reject(token, a.desktop_evidence_result_invalid);
        const s = self.checked(token) orelse return self.missing(token);
        if (reply(s, now).result == a.desktop_evidence_result_expired or terminal(s.phase)) return reply(s, now);
        if (s.phase == reserved) {
            const actual = source orelse return reject(s.token, a.desktop_evidence_result_unknown);
            if (!sameProcess(actual.request, s.token.request)) return reject(s.token, a.desktop_evidence_result_invalid);
            s.phase = waiting;
            s.revision += 1;
            self.promote(s, actual, now);
        }
        return reply(s, now);
    }
    /// Called at actual launch completion, before the existing Desktop ACK.
    pub fn completed(self: *Broker, source: Source, now: u64) void {
        for (&self.slots) |*s| if (s.used) self.promote(s, source, now);
    }
    /// Persist the exact canonical process token BEFORE this acknowledgement.
    pub fn acknowledge(self: *Broker, token: a.DesktopEvidenceToken, now: u64) a.DesktopEvidenceReply {
        if (token.serial == 0) return reject(token, a.desktop_evidence_result_invalid);
        const s = self.checked(token) orelse return self.missing(token);
        if (reply(s, now).result == a.desktop_evidence_result_expired or terminal(s.phase)) return reply(s, now);
        if (!std.meta.eql(s.token, token)) return reject(token, a.desktop_evidence_result_invalid);
        if (s.phase == offered) {
            s.phase = acknowledged;
            s.deadline = 0;
            s.revision += 1;
        }
        return reply(s, now);
    }
    /// Read-only reconciliation. It never creates or renews a reference.
    pub fn status(self: *Broker, token: a.DesktopEvidenceToken, now: u64) a.DesktopEvidenceReply {
        const s = self.checked(token) orelse return self.missing(token);
        var out = reply(s, now);
        if (out.result != 0 or s.binding == 0) return out;
        const query = self.backend.query orelse {
            out.result = a.desktop_evidence_result_unavailable;
            return out;
        };
        const rc = query(self.backend.context, s.token.process, s.binding, &out.completion);
        out.raw_result = rc;
        if (rc == a.program_handle_error_would_block or rc == a.program_handle_error_timeout) {
            out.result = a.desktop_evidence_result_pending;
        } else if (rc != 0 or !sameProcess(out.completion.handle, s.token.process) or out.completion.sequence == 0) {
            out.completion = .{};
            out.result = a.desktop_evidence_result_unavailable;
        }
        return out;
    }
    pub fn read(self: *Broker, token: a.DesktopEvidenceToken, offset: u32, buffer: []u8, now: u64) a.DesktopEvidenceReply {
        const s = self.checked(token) orelse return self.missing(token);
        var out = self.status(token, now);
        if (out.result != 0) return out;
        if (s.phase != acknowledged) {
            out.result = a.desktop_evidence_result_not_acknowledged;
            return out;
        }
        const read_fn = self.backend.read orelse {
            out.result = a.desktop_evidence_result_unavailable;
            return out;
        };
        var bytes: u32 = 0;
        const rc = read_fn(self.backend.context, s.token.process, s.binding, offset, buffer, &bytes);
        out.raw_result = rc;
        if (rc != 0 or bytes > buffer.len) {
            out.result = a.desktop_evidence_result_unavailable;
            return out;
        }
        out.data_bytes = bytes;
        return out;
    }
    fn drop(self: *Broker, s: *Slot) bool {
        if (s.binding == 0) return true;
        const free = self.backend.release orelse return false;
        if (!free(self.backend.context, s.token.process, s.binding)) return false;
        s.binding = 0;
        return true;
    }
    pub fn release(self: *Broker, token: a.DesktopEvidenceToken, now: u64) a.DesktopEvidenceReply {
        if (token.serial == 0) return reject(token, a.desktop_evidence_result_invalid);
        const s = self.checked(token) orelse return self.missing(token);
        if (terminal(s.phase)) return reply(s, now);
        if (!self.drop(s)) return reject(s.token, a.desktop_evidence_result_unavailable);
        s.phase = released;
        s.deadline = 0;
        s.revision += 1;
        return reply(s, now);
    }
    /// Expiration belongs to the existing service deadline, not Status calls.
    pub fn maintain(self: *Broker, now: u64, retry_ticks: u64) void {
        for (&self.slots) |*s| {
            if (!s.used or terminal(s.phase) or s.phase == acknowledged or now < @max(s.deadline, s.retry_at)) continue;
            if (!self.drop(s)) {
                s.retry_at = now +| @max(retry_ticks, 1);
                continue;
            }
            s.phase = expired;
            s.deadline = 0;
            s.revision += 1;
        }
    }
    pub fn nextDeadline(self: *const Broker) ?u64 {
        var next: ?u64 = null;
        for (&self.slots) |*s| {
            if (!s.used or terminal(s.phase) or s.phase == acknowledged) continue;
            next = @min(next orelse std.math.maxInt(u64), @max(s.deadline, s.retry_at));
        }
        return next;
    }
    pub fn clear(self: *Broker) void {
        for (&self.slots) |*s| {
            if (!s.used) continue;
            if (self.drop(s)) s.* = .{};
        }
    }
};

const Fixture = struct {
    retains: u32 = 0,
    releases: u32 = 0,
    queries: u32 = 0,
    fn state(context: ?*const anyopaque) *Fixture {
        return @ptrCast(@alignCast(@constCast(context.?)));
    }
    fn retain(context: ?*const anyopaque, _: a.ProgramProcessHandle) u64 {
        const f = state(context);
        f.retains += 1;
        return 100 + f.retains;
    }
    fn release(context: ?*const anyopaque, _: a.ProgramProcessHandle, _: u64) bool {
        state(context).releases += 1;
        return true;
    }
    fn query(context: ?*const anyopaque, p: a.ProgramProcessHandle, _: u64, out: *a.ProgramProcessCompletion) i32 {
        state(context).queries += 1;
        out.* = .{ .handle = p, .sequence = 42, .exit_code = 37, .output_length = 4 };
        return 0;
    }
    fn read(_: ?*const anyopaque, _: a.ProgramProcessHandle, _: u64, offset: u32, out: []u8, count: *u32) i32 {
        const bytes = "MARK";
        const start = @min(offset, bytes.len);
        const n = @min(out.len, bytes.len - start);
        @memcpy(out[0..n], bytes[start..][0..n]);
        count.* = @intCast(n);
        return 0;
    }
    fn broker(self: *Fixture) Broker {
        return .{ .service = .{ .instance_id = 1, .generation = 101 }, .epoch = .{ 17, 18, 19 }, .backend = .{ .context = self, .retain = retain, .release = release, .query = query, .read = read } };
    }
    fn intent(b: *const Broker, receiver: u64) a.DesktopEvidenceToken {
        return .{ .broker = b.service, .epoch = b.epoch, .request = .{ .instance_id = 2, .generation = 202 }, .intent = .{ receiver, 7, 8 } };
    }
    fn source() Source {
        return .{ .request = .{ .instance_id = 2, .generation = 202 }, .process = .{ .instance_id = 3, .generation = 303 }, .desktop = .{ .instance_id = 4, .generation = 404 }, .protected = true, .terminal = true };
    }
};

test "evidence lost reserve and offer responses reconcile without another Retain" {
    var f: Fixture = .{};
    var b = f.broker();
    const intent = Fixture.intent(&b, 1);
    const reservation = b.reserve(intent, 10, 100);
    try std.testing.expect(reservation.token.serial != 0);
    try std.testing.expectEqual(reservation.token.serial, b.status(intent, 11).token.serial);
    const offer = b.offer(reservation.token, Fixture.source(), 12);
    try std.testing.expectEqual(offered, offer.phase);
    const recovered = b.status(reservation.token, 13);
    try std.testing.expectEqual(@as(i32, 37), recovered.completion.exit_code);
    try std.testing.expectEqual(offered, b.offer(reservation.token, Fixture.source(), 14).phase);
    try std.testing.expectEqual(@as(u32, 1), f.retains);
    try std.testing.expectEqual(acknowledged, b.acknowledge(recovered.token, 15).phase);
    try std.testing.expectEqual(@as(?u64, null), b.nextDeadline());
    const resumed = b.status(recovered.token, 1000); // Actual observer can end; lease remains.
    try std.testing.expectEqual(@as(u64, 42), resumed.completion.sequence);
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 4), b.read(recovered.token, 0, &out, 1001).data_bytes);
    try std.testing.expectEqualStrings("MARK", &out);
    try std.testing.expectEqual(released, b.release(recovered.token, 1002).phase);
    try std.testing.expectEqual(released, b.release(recovered.token, 1003).phase);
    try std.testing.expectEqual(@as(u32, 1), f.releases);
}

test "evidence expiry and evicted old serial never recreate an observation" {
    var f: Fixture = .{};
    var b = f.broker();
    const reservation = b.reserve(Fixture.intent(&b, 1), 10, 20);
    const offer = b.offer(reservation.token, Fixture.source(), 11);
    try std.testing.expectEqual(expired, b.status(offer.token, 20).phase);
    try std.testing.expectEqual(@as(u32, 0), f.releases); // Status is read-only.
    b.maintain(20, 2);
    try std.testing.expectEqual(@as(u32, 1), f.releases);
    for (0..a.desktop_evidence_max_leases) |i| {
        const next = b.reserve(Fixture.intent(&b, 10 + i), 21, 100);
        try std.testing.expectEqual(reserved, next.phase);
    }
    try std.testing.expectEqual(a.desktop_evidence_result_unknown, b.offer(offer.token, Fixture.source(), 22).result);
    try std.testing.expectEqual(a.desktop_evidence_result_quota, b.reserve(Fixture.intent(&b, 100), 22, 100).result);
    try std.testing.expectEqual(@as(u32, 1), f.retains);
    b.clear();
    try std.testing.expectEqual(@as(u32, 1), f.releases);
}

test "evidence independent observers and copied tokens have distinct release semantics" {
    var f: Fixture = .{};
    var b = f.broker();
    const first = b.offer(b.reserve(Fixture.intent(&b, 1), 10, 100).token, Fixture.source(), 11);
    const second = b.offer(b.reserve(Fixture.intent(&b, 2), 10, 100).token, Fixture.source(), 11);
    _ = b.acknowledge(first.token, 12);
    _ = b.acknowledge(second.token, 12);
    try std.testing.expectEqual(@as(u32, 2), f.retains);
    _ = b.release(first.token, 13);
    try std.testing.expectEqual(released, b.status(first.token, 14).phase);
    try std.testing.expectEqual(@as(u64, 42), b.status(second.token, 14).completion.sequence);
    var wrong = second.token;
    wrong.epoch[0] += 1;
    const queries = f.queries;
    try std.testing.expectEqual(a.desktop_evidence_result_stale, b.status(wrong, 14).result);
    wrong = second.token;
    wrong.process.generation += 1;
    try std.testing.expect(b.status(wrong, 14).result != 0);
    try std.testing.expectEqual(queries, f.queries);
    b.clear();
    try std.testing.expectEqual(@as(u32, 2), f.releases);
}

test "evidence waiting offer acquires before launch ACK and never repairs a lost bridge" {
    var f: Fixture = .{};
    var b = f.broker();
    const reservation = b.reserve(Fixture.intent(&b, 1), 10, 100);
    var source = Fixture.source();
    source.process = .{};
    source.terminal = false;
    try std.testing.expectEqual(waiting, b.offer(reservation.token, source, 11).phase);
    try std.testing.expectEqual(@as(u32, 0), f.retains);
    b.completed(Fixture.source(), 12); // The actual service adapter does this before ACK.
    b.completed(Fixture.source(), 13);
    const ready = b.status(reservation.token, 14);
    try std.testing.expectEqual(offered, ready.phase);
    try std.testing.expectEqual(@as(u32, 1), f.retains);
    source = Fixture.source();
    source.protected = false;
    const lost = b.reserve(Fixture.intent(&b, 2), 15, 100);
    try std.testing.expectEqual(unavailable, b.offer(lost.token, source, 16).phase);
    try std.testing.expectEqual(@as(u32, 1), f.retains);
    b.clear();
    try std.testing.expectEqual(@as(u32, 1), f.releases);
}

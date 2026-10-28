//! One bounded copy, authenticated by main.zig. No caller-owned storage.
const std = @import("std");
const wire = @import("desktop_check");
pub const Job = struct { ticket: u64, request_id: u32, request: wire.Request, desktop: wire.Identity, deadline: u64, submitted_at: u64, delivered_at: u64 = 0, claimed: bool = false };
pub const FaultPhase = enum { delivery, expiry, completed_late };
pub const Fault = struct { phase: FaultPhase, job: Job, raw: i32, now: u64, owner_result: ?i32 = null };
pub const Queue = struct {
    broker: wire.Identity = .{},
    pending: ?Job = null,
    next_ticket: u64 = 1,
    // Failure-only value receipts. Never call another service while replying
    // to or expiring this broker's caller. Explicit text status formats them.
    faults: [4]?Fault = .{null} ** 4,
    fault_count: u64 = 0,
    fault_next: usize = 0,
    pub fn recordFault(self: *Queue, fault: Fault) void {
        self.faults[self.fault_next] = fault;
        self.fault_next = (self.fault_next + 1) % self.faults.len;
        self.fault_count +|= 1;
    }
    pub fn submit(self: *Queue, request: wire.Request, request_id: u32, desktop: wire.Identity, now: u64, limit: u64) !void {
        if (self.pending != null) return error.Busy;
        if (request.deadline_tick <= now or !request.caller.valid() or !desktop.valid() or !self.broker.valid()) return error.Invalid;
        const ticket = self.next_ticket;
        self.next_ticket +%= 1;
        if (self.next_ticket == 0) self.next_ticket = 1;
        self.pending = .{ .ticket = ticket, .request_id = request_id, .request = request, .desktop = desktop,
            .deadline = @min(request.deadline_tick, now +| limit), .submitted_at = now };
    }
    pub fn offer(self: *const Queue, desktop: wire.Identity, now: u64) ?wire.Work {
        const job = self.pending orelse return null;
        // Publishing a reply does not acknowledge client consumption: the
        // client can resume past its own deadline and discard that reply.
        // Desktop keeps this exact ticket and its copied completion, so
        // redelivery cannot authorize executing the action a second time.
        if (now >= job.deadline or !job.desktop.same(desktop)) return null;
        return .{ .ticket = job.ticket, .deadline_tick = job.deadline, .broker = self.broker, .request = job.request };
    }
    /// Preserve the first actual publication, not a claim of consumption.
    /// The normalized handler result also accepts a cancelled caller.
    pub fn delivered(self: *Queue, offered: ?wire.Work, raw_reply: i32, now: u64) bool {
        if (raw_reply != 0) return false;
        const work = offered orelse return false;
        const job = if (self.pending) |*value| value else return false;
        if (now >= job.deadline or job.ticket != work.ticket or job.deadline != work.deadline_tick or
            !self.broker.same(work.broker) or !std.meta.eql(job.request, work.request)) return false;
        if (!job.claimed) {
            job.claimed = true;
            job.delivered_at = now;
        }
        return true;
    }
    pub fn complete(self: *Queue, ticket: u64, broker: wire.Identity, response: wire.Response) !Job {
        const job = self.pending orelse return error.Stale;
        if (!self.broker.same(broker) or !job.claimed or job.ticket != ticket or !job.desktop.same(response.desktop) or response.op != job.request.op or
            response.target.instance != job.request.target.instance or response.target.generation != job.request.target.generation) return error.Stale;
        self.pending = null;
        return job;
    }
};
test "bounded broker copy refuses busy expired changed-owner and late completion without consuming replacement" {
    var queue: Queue = .{ .broker = .{ .instance = 7, .generation = 18 } };
    const desktop: wire.Identity = .{ .instance = 5, .generation = 9 };
    const request: wire.Request = .{ .op = .begin, .caller = .{ .instance = 3, .generation = 7 }, .deadline_tick = 90 };
    try queue.submit(request, 4, desktop, 10, 20);
    try std.testing.expectError(error.Busy, queue.submit(request, 8, desktop, 10, 20));
    try std.testing.expectEqual(@as(?wire.Work, null), queue.offer(.{ .instance = 5, .generation = 10 }, 11));
    const work = queue.offer(desktop, 11).?;
    try std.testing.expectEqual(@as(u64, 30), work.deadline_tick);
    // A cancelled tray reply has not delivered the offer to the Desktop.
    try std.testing.expectEqualDeep(work, queue.offer(desktop, 12).?);
    try std.testing.expect(!queue.delivered(work, -2, 12)); // Actual cancelled IPC reply, not normalized0.
    try std.testing.expect(!queue.pending.?.claimed);
    try std.testing.expectEqual(@as(u64, 0), queue.pending.?.delivered_at);
    try std.testing.expectError(error.Stale, queue.complete(work.ticket, work.broker, .{ .op = .begin, .desktop = desktop }));
    try std.testing.expectEqualDeep(work, queue.offer(desktop, 13).?);
    var wrong = work;
    wrong.broker.generation += 1;
    try std.testing.expect(!queue.delivered(wrong, 0, 13));
    try std.testing.expect(queue.delivered(work, 0, 13));
    try std.testing.expectEqual(@as(u64, 10), queue.pending.?.submitted_at);
    try std.testing.expectEqual(@as(u64, 13), queue.pending.?.delivered_at);
    // Reply0 only published a response. A client may resume after its own
    // deadline and discard it. Keep the exact copied offer until completion.
    try std.testing.expectEqualDeep(work, queue.offer(desktop, 14).?);
    try std.testing.expect(queue.delivered(work, 0, 14));
    try std.testing.expectEqual(@as(u64, 13), queue.pending.?.delivered_at);
    try std.testing.expectError(error.Stale, queue.complete(work.ticket + 1, work.broker, .{ .op = .begin, .desktop = desktop }));
    try std.testing.expectError(error.Stale, queue.complete(work.ticket, .{ .instance = 7, .generation = 17 }, .{ .op = .begin, .desktop = desktop }));
    const done = try queue.complete(work.ticket, work.broker, .{ .op = .begin, .desktop = desktop });
    try std.testing.expectEqual(@as(u32, 4), done.request_id);
    try queue.submit(request, 8, desktop, 10, 20);
    try std.testing.expect(!queue.delivered(work, 0, 14)); // A late receipt cannot claim the replacement.
    try std.testing.expect(!queue.pending.?.claimed);
    try std.testing.expectError(error.Stale, queue.complete(work.ticket, work.broker, .{ .op = .begin, .desktop = desktop }));
    try std.testing.expect(queue.pending != null);
    const replacement = queue.offer(desktop, 29).?;
    try std.testing.expect(!queue.delivered(replacement, 0, 30));
    try std.testing.expect(!queue.pending.?.claimed);
    try std.testing.expectEqual(@as(?wire.Work, null), queue.offer(desktop, 30));
}

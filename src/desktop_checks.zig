//! One bounded copy, authenticated by main.zig. No caller-owned storage.
const std = @import("std");
const wire = @import("desktop_check");
pub const Job = struct { ticket: u64, request_id: u32, request: wire.Request, desktop: wire.Identity, deadline: u64, claimed: bool = false };
pub const Queue = struct {
    broker: wire.Identity = .{},
    pending: ?Job = null,
    next_ticket: u64 = 1,
    pub fn submit(self: *Queue, request: wire.Request, request_id: u32, desktop: wire.Identity, now: u64, limit: u64) !void {
        if (self.pending != null) return error.Busy;
        if (request.deadline_tick <= now or !request.caller.valid() or !desktop.valid() or !self.broker.valid()) return error.Invalid;
        const ticket = self.next_ticket;
        self.next_ticket +%= 1;
        if (self.next_ticket == 0) self.next_ticket = 1;
        self.pending = .{ .ticket = ticket, .request_id = request_id, .request = request, .desktop = desktop,
            .deadline = @min(request.deadline_tick, now +| limit) };
    }
    pub fn take(self: *Queue, desktop: wire.Identity, now: u64) ?wire.Work {
        const job = if (self.pending) |*value| value else return null;
        if (job.claimed or now >= job.deadline or !job.desktop.same(desktop)) return null;
        job.claimed = true;
        return .{ .ticket = job.ticket, .deadline_tick = job.deadline, .broker = self.broker, .request = job.request };
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
    try std.testing.expectEqual(@as(?wire.Work, null), queue.take(.{ .instance = 5, .generation = 10 }, 11));
    const work = queue.take(desktop, 11).?;
    try std.testing.expectEqual(@as(u64, 30), work.deadline_tick);
    try std.testing.expectEqual(@as(?wire.Work, null), queue.take(desktop, 12));
    try std.testing.expectError(error.Stale, queue.complete(work.ticket + 1, work.broker, .{ .op = .begin, .desktop = desktop }));
    try std.testing.expectError(error.Stale, queue.complete(work.ticket, .{ .instance = 7, .generation = 17 }, .{ .op = .begin, .desktop = desktop }));
    const done = try queue.complete(work.ticket, work.broker, .{ .op = .begin, .desktop = desktop });
    try std.testing.expectEqual(@as(u32, 4), done.request_id);
    try queue.submit(request, 8, desktop, 10, 20);
    try std.testing.expectError(error.Stale, queue.complete(work.ticket, work.broker, .{ .op = .begin, .desktop = desktop }));
    try std.testing.expect(queue.pending != null);
    try std.testing.expectEqual(@as(?wire.Work, null), queue.take(desktop, 30));
}

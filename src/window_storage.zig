//! Small tables stay inline. Growth is fallible and keeps the original table
//! intact until allocation for all its entries has succeeded.
const std = @import("std");

pub fn Table(comptime T: type, comptime initial: usize, comptime empty: T) type {
    return struct {
        const Self = @This();
        local: [initial]T = @splat(empty),
        heap: ?[]T = null,
        allocator: ?std.mem.Allocator = null,

        pub fn view(self: *const Self) []const T {
            return self.heap orelse &self.local;
        }
        pub fn items(self: *Self) []T {
            return self.heap orelse &self.local;
        }
        pub fn ensure(self: *Self, needed: usize) bool {
            const current = self.view();
            if (needed <= current.len) return true;
            const allocator = self.allocator orelse return false;
            const capacity = @max(needed, current.len +| current.len / 2 +| 1);
            const next = allocator.alloc(T, capacity) catch return false;
            @memcpy(next[0..current.len], current);
            @memset(next[current.len..], empty);
            if (self.heap) |old| allocator.free(old);
            self.heap = next;
            return true;
        }
        pub fn grow(self: *Self) ?*T {
            const index = self.view().len;
            if (!self.ensure(std.math.add(usize, index, 1) catch return null)) return null;
            return &self.items()[index];
        }
        pub fn reset(self: *Self) void {
            if (self.heap) |old| self.allocator.?.free(old);
            self.heap = null;
            self.local = @splat(empty);
        }
    };
}

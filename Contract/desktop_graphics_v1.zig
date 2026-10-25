//! WINSVC-owned, copied image-change snapshot. No image/BO lease is granted.
//! Service + Desktop generations bind the whole table; each row binds the
//! exact producer generation, window and non-reused surface serial.
const std = @import("std");
pub const operation: u16 = 4752;
pub const magic: u32 = 0x31474952; // RIG1
pub const capacity = 16;
pub const row_size = 40;
pub const size = 48 + capacity * row_size;
pub const native: u32 = 1;
pub const removed: u32 = 2;
pub const Identity = struct { instance: u32 = 0, generation: u64 = 0 };
pub const Row = struct {
    owner: Identity = .{},
    window: u32 = 0,
    serial: u64 = 0,
    revision: u64 = 0,
    flags: u32 = 0,
};
pub const Snapshot = struct {
    service: Identity = .{},
    desktop: Identity = .{},
    revision: u64 = 0,
    count: u32 = 0,
    rows: [capacity]Row = .{Row{}} ** capacity,
};
fn put(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}
pub fn encode(out: *[size]u8, value: *const Snapshot) void {
    std.debug.assert(value.count <= capacity);
    @memset(out, 0);
    put(u32, out, 0, magic); put(u16, out, 4, 1); put(u16, out, 6, size);
    put(u32, out, 8, value.service.instance); put(u32, out, 12, value.count);
    put(u64, out, 16, value.service.generation); put(u32, out, 24, value.desktop.instance);
    put(u64, out, 32, value.desktop.generation); put(u64, out, 40, value.revision);
    for (value.rows[0..value.count], 0..) |row, index| {
        const offset = 48 + index * row_size;
        put(u32, out, offset, row.owner.instance); put(u32, out, offset + 4, row.flags);
        put(u64, out, offset + 8, row.owner.generation); put(u64, out, offset + 16, row.serial);
        put(u32, out, offset + 24, row.window); put(u64, out, offset + 32, row.revision);
    }
}

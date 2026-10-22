//! WINSVC-owned byte protocol, independent of the Desktop implementation.
//! Integers have fixed little-endian offsets. No object or process pointers.
const std = @import("std");
pub const operation: u16 = 4500;
pub const magic: u32 = 0x314d4452; // RDM1
pub const version: u16 = 1;
pub const size: usize = 128;
pub const owner_valid: u32 = 1;
pub const display_valid: u32 = 2;
pub const clock_valid: u32 = 4;

pub const Snapshot = struct {
    flags: u32 = 0,
    service_instance: u32 = 0,
    endpoint: u32 = 0,
    service_generation: u64 = 0,
    desktop_instance: u32 = 0,
    window_count: u32 = 0,
    desktop_generation: u64 = 0,
    desktop_epoch: u64 = 0,
    window_revision: u32 = 0,
    focused_instance: u32 = 0,
    collected_ns: u64 = 0,
    display_epoch: u64 = 0,
    display_revision: u64 = 0,
    logical_outputs: u32 = 0,
    clock_generation: u64 = 0,
};
pub const Error = error{ InvalidSnapshot, InvalidProtocol, BufferTooSmall };

fn valid(s: Snapshot) bool {
    if (s.flags & ~@as(u32, 7) != 0 or s.service_instance == 0 or s.service_generation == 0 or
        s.endpoint == 0 or s.window_count > 64 or s.logical_outputs > 8) return false;
    if (s.flags & owner_valid != 0) {
        if (s.desktop_instance == 0 or s.desktop_generation == 0 or s.desktop_epoch != s.desktop_generation) return false;
    } else if (s.desktop_instance != 0 or s.desktop_generation != 0 or s.desktop_epoch != 0 or s.flags & display_valid != 0) return false;
    if (s.flags & display_valid != 0) {
        if (s.display_epoch != s.desktop_generation or s.display_revision == 0) return false;
    } else if (s.display_epoch != 0 or s.display_revision != 0 or s.logical_outputs != 0) return false;
    if (s.flags & clock_valid != 0) {
        if (s.clock_generation == 0) return false;
    } else if (s.collected_ns != 0 or s.clock_generation != 0) return false;
    return true;
}
fn put(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}
fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
pub fn encode(out: []u8, s: Snapshot) Error![]const u8 {
    if (out.len < size) return error.BufferTooSmall;
    if (!valid(s)) return error.InvalidSnapshot;
    @memset(out[0..size], 0);
    put(u32, out, 0, magic); put(u16, out, 4, version); put(u16, out, 6, size);
    put(u32, out, 8, s.flags);
    put(u32, out, 16, s.service_instance); put(u32, out, 20, s.endpoint); put(u64, out, 24, s.service_generation);
    put(u32, out, 32, s.desktop_instance); put(u32, out, 36, s.window_count);
    put(u64, out, 40, s.desktop_generation); put(u64, out, 48, s.desktop_epoch);
    put(u32, out, 56, s.window_revision); put(u32, out, 60, s.focused_instance);
    put(u64, out, 64, s.collected_ns); put(u64, out, 72, s.display_epoch); put(u64, out, 80, s.display_revision);
    put(u32, out, 88, s.logical_outputs); put(u64, out, 96, s.clock_generation);
    return out[0..size];
}
pub fn decode(bytes: []const u8) Error!Snapshot {
    if (bytes.len != size or get(u32, bytes, 0) != magic or get(u16, bytes, 4) != version or
        get(u16, bytes, 6) != size or get(u32, bytes, 12) != 0 or get(u32, bytes, 92) != 0 or
        !std.mem.allEqual(u8, bytes[104..], 0)) return error.InvalidProtocol;
    const s: Snapshot = .{
        .flags = get(u32, bytes, 8), .service_instance = get(u32, bytes, 16), .endpoint = get(u32, bytes, 20),
        .service_generation = get(u64, bytes, 24), .desktop_instance = get(u32, bytes, 32), .window_count = get(u32, bytes, 36),
        .desktop_generation = get(u64, bytes, 40), .desktop_epoch = get(u64, bytes, 48),
        .window_revision = get(u32, bytes, 56), .focused_instance = get(u32, bytes, 60),
        .collected_ns = get(u64, bytes, 64), .display_epoch = get(u64, bytes, 72), .display_revision = get(u64, bytes, 80),
        .logical_outputs = get(u32, bytes, 88), .clock_generation = get(u64, bytes, 96),
    };
    if (!valid(s)) return error.InvalidSnapshot;
    return s;
}

test "current wire is bounded little endian and retains exact generations" {
    const s: Snapshot = .{ .service_instance = 7, .endpoint = 3, .service_generation = std.math.maxInt(u64),
        .flags = owner_valid | display_valid | clock_valid, .desktop_instance = 9, .desktop_generation = 71,
        .desktop_epoch = 71, .display_epoch = 71, .display_revision = 12, .clock_generation = 8, .collected_ns = 0 };
    var bytes: [size]u8 = undefined;
    const encoded = try encode(&bytes, s);
    try std.testing.expectEqualSlices(u8, "RDM1", encoded[0..4]);
    try std.testing.expectEqualDeep(s, try decode(encoded));
    try std.testing.expectError(error.BufferTooSmall, encode(bytes[0..127], s));
    try std.testing.expectError(error.InvalidProtocol, decode(encoded[0..127]));
    bytes[4] = 0; try std.testing.expectError(error.InvalidProtocol, decode(&bytes));
    _ = try encode(&bytes, s); bytes[127] = 1;
    try std.testing.expectError(error.InvalidProtocol, decode(&bytes));
}
test "missing owner is explicit and stale or incomplete identities are refused" {
    var bytes: [size]u8 = undefined;
    var s: Snapshot = .{ .service_instance = 7, .endpoint = 3, .service_generation = 11 };
    _ = try encode(&bytes, s);
    try std.testing.expectEqual(@as(u32, 0), (try decode(&bytes)).flags);
    s.desktop_instance = 9;
    try std.testing.expectError(error.InvalidSnapshot, encode(&bytes, s));
    s.flags = owner_valid; s.desktop_generation = 71; s.desktop_epoch = 70;
    try std.testing.expectError(error.InvalidSnapshot, encode(&bytes, s));
    s.desktop_epoch = 71; s.flags |= display_valid;
    try std.testing.expectError(error.InvalidSnapshot, encode(&bytes, s));
}

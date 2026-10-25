//! Product launch mailbox. Fixed little-endian bytes, no retained caller pointers.
//! A helper submits once per exact process generation. (broker, request) is its
//! idempotency/status key, known BEFORE submission, including a lost RPC reply.
const std = @import("std");
pub const submit: u16 = 4736;
pub const status: u16 = 4737;
pub const wait: u16 = 4738;
pub const exchange: u16 = 4739;
pub const complete: u16 = 4740;
pub const size = 448;
pub const magic: u32 = 0x314c4452; // RDL1
pub const wait_frame: u32 = 1;
pub const terminal: u32 = 2;
pub const Phase = enum(u32) { request, accepted, starting, process, window, content };
pub const Code = enum(u32) {
    ok,
    transport,
    syntax,
    resolution,
    no_desktop,
    queue_full,
    window_full,
    loader,
    attachment,
    timeout,
    desktop_lost,
    process_ended,
    invalid,
    unknown,
    stale_service,
};
pub const Identity = struct {
    instance: u32 = 0,
    generation: u64 = 0,
    pub fn valid(self: Identity) bool {
        return self.instance != 0 and self.generation != 0;
    }
    pub fn eql(self: Identity, other: Identity) bool {
        return self.instance == other.instance and self.generation == other.generation;
    }
};
pub const Message = struct {
    broker: Identity = .{},
    request: Identity = .{},
    desktop: Identity = .{},
    process: Identity = .{},
    deadline: u64 = 0,
    phase: Phase = .request,
    code: Code = .ok,
    window: u32 = 0, // Desktop slot + 1; zero means no window receipt.
    policy: u32 = 0,
    flags: u32 = 0,
    raw: i32 = 0,
    content: u64 = 0, // consumed GUI generation / console revision, never scanout.
    path: [160]u8 = .{0} ** 160,
    args: [128]u8 = .{0} ** 128,
    title: [48]u8 = .{0} ** 48,
    pub fn sameKey(self: Message, other: Message) bool {
        return self.broker.eql(other.broker) and self.request.eql(other.request);
    }
    pub fn done(self: Message) bool {
        return self.flags & terminal != 0;
    }
};
pub fn text(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}
pub fn copy(out: []u8, value: []const u8) !void {
    if (value.len >= out.len or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
    @memset(out, 0);
    @memcpy(out[0..value.len], value);
}
fn put(out: []u8, offset: usize, comptime T: type, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}
fn get(bytes: []const u8, offset: usize, comptime T: type) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
fn putId(out: []u8, offset: usize, value: Identity) void {
    put(out, offset, u32, value.instance);
    put(out, offset + 8, u64, value.generation);
}
fn getId(bytes: []const u8, offset: usize) !Identity {
    if (get(bytes, offset + 4, u32) != 0) return error.InvalidWire;
    const id = Identity{ .instance = get(bytes, offset, u32), .generation = get(bytes, offset + 8, u64) };
    if ((id.instance == 0) != (id.generation == 0)) return error.InvalidWire;
    return id;
}
pub fn encode(out: *[size]u8, value: Message) void {
    @memset(out, 0);
    put(out, 0, u32, magic);
    put(out, 4, u16, 1);
    put(out, 6, u16, size);
    putId(out, 8, value.broker);
    putId(out, 24, value.request);
    putId(out, 40, value.desktop);
    putId(out, 56, value.process);
    put(out, 72, u64, value.deadline);
    put(out, 80, u32, @intFromEnum(value.phase));
    put(out, 84, u32, @intFromEnum(value.code));
    put(out, 88, u32, value.window);
    put(out, 92, u32, value.policy);
    put(out, 96, u32, value.flags);
    put(out, 100, i32, value.raw);
    put(out, 104, u64, value.content);
    @memcpy(out[112..272], &value.path);
    @memcpy(out[272..400], &value.args);
    @memcpy(out[400..448], &value.title);
}
pub fn decode(bytes: []const u8) !Message {
    if (bytes.len != size or get(bytes, 0, u32) != magic or get(bytes, 4, u16) != 1 or get(bytes, 6, u16) != size) return error.InvalidWire;
    if (get(bytes, 80, u32) > 5 or get(bytes, 84, u32) > 14) return error.InvalidWire;
    var m = Message{
        .broker = try getId(bytes, 8),
        .request = try getId(bytes, 24),
        .desktop = try getId(bytes, 40),
        .process = try getId(bytes, 56),
        .deadline = get(bytes, 72, u64),
        .phase = @enumFromInt(get(bytes, 80, u32)),
        .code = @enumFromInt(get(bytes, 84, u32)),
        .window = get(bytes, 88, u32),
        .policy = get(bytes, 92, u32),
        .flags = get(bytes, 96, u32),
        .raw = get(bytes, 100, i32),
        .content = get(bytes, 104, u64),
    };
    if (m.flags & ~@as(u32, 3) != 0 or m.policy > 2 or m.window > 4) return error.InvalidWire;
    @memcpy(&m.path, bytes[112..272]);
    @memcpy(&m.args, bytes[272..400]);
    @memcpy(&m.title, bytes[400..448]);
    for ([_][]const u8{ &m.path, &m.args, &m.title }) |field| {
        const n = text(field).len;
        if (n == field.len or !std.unicode.utf8ValidateSlice(field[0..n])) return error.InvalidWire;
        for (field[n..]) |b| if (b != 0) return error.InvalidWire;
    }
    return m;
}

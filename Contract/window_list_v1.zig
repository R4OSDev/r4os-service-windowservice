//! WINSVC paged enumeration. Cursor zero starts a read. Every later page
//! belongs to the same service generation and catalogue revision.
pub const operation: u16 = 1539;
pub const capacity = 8;
pub const ok: i32 = 0;
pub const restart: i32 = 1;
pub const invalid: i32 = -1;

pub const Query = extern struct {
    version: u32 = 1,
    size: u32 = @sizeOf(Query),
    revision: u64 = 0,
    generation: u64 = 0,
    service: u32 = 0,
    cursor: u32 = 0,
    limit: u32 = capacity,
    reserved: u32 = 0,
};
pub fn Page(comptime a: type) type {
    return extern struct {
        version: u32 = 1,
        size: u32 = @sizeOf(@This()),
        revision: u64 = 0,
        generation: u64 = 0,
        service: u32 = 0,
        result: i32 = ok,
        next: u32 = 0,
        count: u32 = 0,
        status: a.WindowServiceStatus = .{},
        records: [capacity]a.WindowServiceRecord = @splat(.{}),
    };
}

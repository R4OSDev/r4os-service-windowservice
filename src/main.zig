const std = @import("std");
const r4os = @import("r4os");
const tray_broker = @import("tray_broker.zig");

const service_name = "WINSVC";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";
const service_timeout_ticks: u64 = 120;
const tray_owner_sweep_ticks: u64 = 50;
const program_role_shell: u8 = 1;
const program_class_gui: u8 = 1;
const program_state_done: u8 = 2;

const Slot = struct {
    used: bool = false,
    record: r4os.abi.WindowServiceRecord = .{},
};

const ServiceState = struct {
    revision: u32 = 0,
    next_z: u32 = 1,
    requests: u64 = 0,
    status_requests: u64 = 0,
    snapshot_requests: u64 = 0,
    register_requests: u64 = 0,
    update_requests: u64 = 0,
    focus_requests: u64 = 0,
    minimize_requests: u64 = 0,
    restore_requests: u64 = 0,
    maximize_requests: u64 = 0,
    close_requests: u64 = 0,
    remove_requests: u64 = 0,
    stale_sweeps: u64 = 0,
    restart_cleanups: u64 = 0,
    bad_ops: u64 = 0,
    bad_requests: u64 = 0,
    last_error: [r4os.abi.window_service_error_bytes]u8 = .{0} ** r4os.abi.window_service_error_bytes,
    slots: [r4os.abi.window_service_max_windows]Slot = .{Slot{}} ** r4os.abi.window_service_max_windows,
    tray: tray_broker.Broker = .{},
    next_tray_owner_sweep_tick: u64 = 0,
};

var service_payload: [r4os.abi.service_api_max_payload]u8 = .{0xA5} ** r4os.abi.service_api_max_payload;
var service_response: [r4os.abi.service_api_max_payload]u8 = .{0xA5} ** r4os.abi.service_api_max_payload;
var status_reply: r4os.abi.WindowServiceStatus = .{};
var result_reply: r4os.abi.WindowServiceResult = .{};
var snapshot_reply: r4os.abi.WindowServiceSnapshot = .{};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var ctx = r4_app.system();
    if (hasArg(ctx.argsRaw(), selftest_arg)) return runSelfTest(&ctx);
    if (hasArg(ctx.argsRaw(), ping_arg)) return runPing(&ctx);
    return runService(&ctx);
}

fn runService(ctx: *const r4os.r4sys.Context) i32 {
    if (!ctx.hasFn("service_call")) return r4os.abi.service_api_result_invalid;

    var info: r4os.abi.ServiceInfo = .{};
    var handle: u32 = 0;
    var waited: u32 = 0;
    while (waited < 100 and handle == 0) : (waited += 1) {
        const rc = ctx.serviceEndpointRegister(service_name, 0, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            handle = info.handle;
            ctx.write("WINSVC endpoint handle=");
            ctx.printU64(@intCast(handle));
            ctx.println("");
            break;
        }
        ctx.sleepTicks(1);
    }
    if (handle == 0) {
        ctx.println("WINSVC endpoint registration failed");
        return r4os.abi.service_api_result_no_endpoint;
    }

    var state = ServiceState{};
    state.next_tray_owner_sweep_tick = ctx.ticks() +| tray_owner_sweep_ticks;
    setLastError(&state, "ready");
    var service_loop = r4os.ServiceLoop.init(ctx.*, handle, .{});
    while (true) {
        switch (service_loop.wait(nextServiceDeadline(&state))) {
            .requests => |pending| {
                const rc = service_loop.drain(pending, handleRequest, .{ ctx, handle, &state });
                if (rc < 0) {
                    clearAll(&state, "request");
                    _ = ctx.serviceEndpointUnregister(handle);
                    return rc;
                }
            },
            .idle, .deadline => {},
            .stop => break,
            .failure => |raw| {
                clearAll(&state, "endpoint");
                _ = ctx.serviceEndpointUnregister(handle);
                return raw;
            },
        }
        maintainTray(ctx, handle, &state);
    }

    service_loop.report(service_name);
    clearAll(&state, "service-stop");
    _ = ctx.serviceEndpointUnregister(handle);
    ctx.println("WINSVC stopped cleanly");
    return 0;
}

fn handleRequest(ctx: *const r4os.r4sys.Context, handle: u32, state: *ServiceState) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    const got = ctx.serviceEndpointRecv(handle, &header, service_payload[0..]);
    if (got < 0) return got;
    if (got == 0 and header.magic != r4os.abi.service_api_magic) return 0;

    state.requests +%= 1;
    const payload_len: usize = @intCast(got);
    const request = service_payload[0..payload_len];
    return switch (header.op) {
        r4os.abi.net_service_op_status,
        r4os.abi.window_service_op_text_status,
        => replyTextStatus(ctx, handle, header.request_id, state),
        r4os.abi.window_service_op_status => replyStatus(ctx, handle, header.request_id, state),
        r4os.abi.window_service_op_snapshot => replySnapshot(ctx, handle, header.request_id, state),
        r4os.abi.window_service_op_register,
        r4os.abi.window_service_op_update,
        r4os.abi.window_service_op_focus,
        r4os.abi.window_service_op_minimize,
        r4os.abi.window_service_op_restore,
        r4os.abi.window_service_op_maximize,
        r4os.abi.window_service_op_close,
        r4os.abi.window_service_op_remove,
        r4os.abi.window_service_op_stale_sweep,
        r4os.abi.window_service_op_restart_cleanup,
        => replyAction(ctx, handle, header.request_id, state, header.op, request),
        r4os.abi.tray_service_op_status,
        r4os.abi.tray_service_op_upsert,
        r4os.abi.tray_service_op_remove,
        r4os.abi.tray_service_op_wait_event,
        => replyTrayProvider(ctx, handle, header, state, request),
        r4os.abi.tray_service_op_desktop_sync,
        r4os.abi.tray_service_op_desktop_activate,
        r4os.abi.tray_service_op_desktop_visibility,
        => replyTrayDesktop(ctx, handle, header, state, request),
        else => {
            state.bad_ops +%= 1;
            setLastError(state, "bad-op");
            return ctx.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
        },
    };
}

fn nextServiceDeadline(state: *const ServiceState) ?u64 {
    const owner_sweep = state.next_tray_owner_sweep_tick;
    if (state.tray.nextDeadline()) |wait_deadline| return @min(owner_sweep, wait_deadline);
    return owner_sweep;
}

fn maintainTray(ctx: *const r4os.r4sys.Context, handle: u32, state: *ServiceState) void {
    const now = ctx.ticks();
    if (now >= state.next_tray_owner_sweep_tick) {
        state.next_tray_owner_sweep_tick = now +| tray_owner_sweep_ticks;
        if (tray_broker.ownerValid(state.tray.desktop_owner) and processHandleGone(ctx, state.tray.desktop_owner)) {
            _ = state.tray.clearDesktop();
        }

        var cursor: usize = 0;
        while (state.tray.ownerAt(cursor)) |found| {
            cursor = found.index + 1;
            if (processHandleGone(ctx, found.owner)) _ = state.tray.removeOwner(found.owner);
        }
    }

    var replies: usize = 0;
    while (replies < tray_broker.max_owners) : (replies += 1) {
        const reply = state.tray.takeWaitReply(now) orelse break;
        const bytes: [*]const u8 = @ptrCast(&reply.response);
        _ = ctx.serviceEndpointReply(handle, reply.request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.TrayServiceResponse)]);
    }
}

fn processHandleGone(ctx: *const r4os.r4sys.Context, owner: r4os.abi.ProgramProcessHandle) bool {
    var info: r4os.abi.ProgramInstanceInfo = .{};
    const rc = ctx.programHandleStatus(&owner, &info);
    if (rc == r4os.abi.program_handle_error_would_block) return false;
    return rc != r4os.abi.program_handle_ok or info.id != owner.instance_id or info.state == program_state_done;
}

fn liveCaller(ctx: *const r4os.r4sys.Context, client_id: u32, owner: r4os.abi.ProgramProcessHandle) ?r4os.abi.ProgramInstanceInfo {
    if (!tray_broker.ownerValid(owner) or client_id != owner.instance_id) return null;
    var info: r4os.abi.ProgramInstanceInfo = .{};
    if (ctx.programHandleStatus(&owner, &info) != r4os.abi.program_handle_ok or
        info.id != owner.instance_id or info.state == program_state_done)
    {
        return null;
    }
    return info;
}

fn replyTrayProvider(
    ctx: *const r4os.r4sys.Context,
    handle: u32,
    header: r4os.abi.ServiceMessageHeader,
    state: *ServiceState,
    payload: []const u8,
) i32 {
    const request = decodeFixed(r4os.abi.TrayServiceRequest, payload) orelse
        return ctx.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_invalid, "TRAYBAD");
    var response: r4os.abi.TrayServiceResponse = undefined;
    if (!tray_broker.validBaseRequest(&request)) {
        response = .{ .result = r4os.abi.tray_result_bad_request, .owner = request.owner, .item_id = request.item_id, .capacity = @intCast(tray_broker.max_items), .desktop_epoch = state.tray.desktop_epoch, .registry_revision = state.tray.revision };
    } else if (liveCaller(ctx, header.client_id, request.owner) == null) {
        response = .{ .result = r4os.abi.tray_result_not_owner, .owner = request.owner, .item_id = request.item_id, .capacity = @intCast(tray_broker.max_items), .desktop_epoch = state.tray.desktop_epoch, .registry_revision = state.tray.revision };
    } else switch (header.op) {
        r4os.abi.tray_service_op_status => response = state.tray.status(request.owner, request.item_id),
        r4os.abi.tray_service_op_upsert => response = state.tray.upsert(&request),
        r4os.abi.tray_service_op_remove => response = state.tray.remove(request.owner, request.item_id),
        r4os.abi.tray_service_op_wait_event => switch (state.tray.beginWait(
            request.owner,
            header.request_id,
            request.after_sequence,
            request.deadline_tick,
            ctx.ticks(),
        )) {
            .parked => return 0,
            .reply => |value| response = value,
        },
        else => unreachable,
    }
    return replyTrayResponse(ctx, handle, header.request_id, &response);
}

fn replyTrayDesktop(
    ctx: *const r4os.r4sys.Context,
    handle: u32,
    header: r4os.abi.ServiceMessageHeader,
    state: *ServiceState,
    payload: []const u8,
) i32 {
    const request = decodeFixed(r4os.abi.TrayDesktopExchange, payload) orelse
        return ctx.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_invalid, "TRAYDESKBAD");
    var response: r4os.abi.TrayDesktopExchange = undefined;
    const caller = liveCaller(ctx, header.client_id, request.desktop_owner);
    if (caller == null or caller.?.role != program_role_shell or caller.?.app_class != program_class_gui) {
        response = trayDesktopFailure(state, request.desktop_owner, r4os.abi.tray_result_not_owner);
    } else response = switch (header.op) {
        r4os.abi.tray_service_op_desktop_sync => state.tray.desktopSync(&request),
        r4os.abi.tray_service_op_desktop_activate => state.tray.desktopActivate(&request),
        r4os.abi.tray_service_op_desktop_visibility => state.tray.desktopVisibility(&request),
        else => unreachable,
    };
    const bytes: [*]const u8 = @ptrCast(&response);
    return ctx.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.TrayDesktopExchange)]);
}

fn replyTrayResponse(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, response: *const r4os.abi.TrayServiceResponse) i32 {
    const bytes: [*]const u8 = @ptrCast(response);
    return ctx.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.TrayServiceResponse)]);
}

fn trayDesktopFailure(state: *const ServiceState, owner: r4os.abi.ProgramProcessHandle, result: i32) r4os.abi.TrayDesktopExchange {
    return .{
        .desktop_owner = owner,
        .result = result,
        .registered_count = @intCast(state.tray.registered_count),
        .capacity = @intCast(tray_broker.max_items),
        .desktop_epoch = state.tray.desktop_epoch,
        .registry_revision = state.tray.revision,
    };
}

fn decodeFixed(comptime T: type, payload: []const u8) ?T {
    if (payload.len != @sizeOf(T)) return null;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), payload);
    return value;
}

fn replyTextStatus(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *ServiceState) i32 {
    state.status_requests +%= 1;
    status_reply = makeStatus(state);
    var writer = Writer{ .out = service_response[0..] };
    writer.write("WINSVC windows=");
    writer.writeU64(status_reply.window_count);
    writer.write(" focus=");
    writer.writeU64(status_reply.focused_window);
    writer.write(" instance=");
    writer.writeU64(status_reply.focused_instance);
    writer.write(" rev=");
    writer.writeU64(status_reply.revision);
    writer.write(" last=");
    writer.write(spanZ(status_reply.last_error[0..]));
    return ctx.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, writer.slice());
}

fn replyStatus(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *ServiceState) i32 {
    state.status_requests +%= 1;
    status_reply = makeStatus(state);
    const bytes: [*]const u8 = @ptrCast(&status_reply);
    return ctx.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.WindowServiceStatus)]);
}

fn replySnapshot(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *ServiceState) i32 {
    state.snapshot_requests +%= 1;
    snapshot_reply = makeSnapshot(state);
    const bytes: [*]const u8 = @ptrCast(&snapshot_reply);
    return ctx.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.WindowServiceSnapshot)]);
}

fn replyAction(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *ServiceState, op: u16, request: []const u8) i32 {
    result_reply = performAction(state, op, request);
    const bytes: [*]const u8 = @ptrCast(&result_reply);
    return ctx.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.WindowServiceResult)]);
}

fn performAction(state: *ServiceState, op: u16, request: []const u8) r4os.abi.WindowServiceResult {
    return switch (op) {
        r4os.abi.window_service_op_register => blk: {
            state.register_requests +%= 1;
            const record = requestRecord(request) orelse break :blk failResult(state, op, r4os.abi.window_service_result_bad_request, "bad-request");
            break :blk upsertRecord(state, op, record, true, false);
        },
        r4os.abi.window_service_op_update => blk: {
            state.update_requests +%= 1;
            const record = requestRecord(request) orelse break :blk failResult(state, op, r4os.abi.window_service_result_bad_request, "bad-request");
            break :blk upsertRecord(state, op, record, false, false);
        },
        r4os.abi.window_service_op_focus => blk: {
            state.focus_requests +%= 1;
            const record = requestRecord(request) orelse break :blk failResult(state, op, r4os.abi.window_service_result_bad_request, "bad-request");
            break :blk focusRecord(state, op, record.window_id);
        },
        r4os.abi.window_service_op_minimize => blk: {
            state.minimize_requests +%= 1;
            const record = requestRecord(request) orelse break :blk failResult(state, op, r4os.abi.window_service_result_bad_request, "bad-request");
            break :blk setRecordFlag(state, op, record.window_id, r4os.abi.window_service_flag_minimized, true, false);
        },
        r4os.abi.window_service_op_restore => blk: {
            state.restore_requests +%= 1;
            const record = requestRecord(request) orelse break :blk failResult(state, op, r4os.abi.window_service_result_bad_request, "bad-request");
            const restored = setRecordFlag(state, op, record.window_id, r4os.abi.window_service_flag_minimized, false, true);
            if (restored.result != r4os.abi.window_service_result_ok) break :blk restored;
            break :blk focusRecord(state, op, record.window_id);
        },
        r4os.abi.window_service_op_maximize => blk: {
            state.maximize_requests +%= 1;
            const record = requestRecord(request) orelse break :blk failResult(state, op, r4os.abi.window_service_result_bad_request, "bad-request");
            const maximized = setRecordFlag(state, op, record.window_id, r4os.abi.window_service_flag_maximized, true, true);
            if (maximized.result != r4os.abi.window_service_result_ok) break :blk maximized;
            break :blk focusRecord(state, op, record.window_id);
        },
        r4os.abi.window_service_op_close => blk: {
            state.close_requests +%= 1;
            const record = requestRecord(request) orelse break :blk failResult(state, op, r4os.abi.window_service_result_bad_request, "bad-request");
            break :blk setRecordFlag(state, op, record.window_id, r4os.abi.window_service_flag_closing, true, false);
        },
        r4os.abi.window_service_op_remove => blk: {
            state.remove_requests +%= 1;
            const record = requestRecord(request) orelse break :blk failResult(state, op, r4os.abi.window_service_result_bad_request, "bad-request");
            break :blk removeRecord(state, op, record.window_id);
        },
        r4os.abi.window_service_op_stale_sweep => blk: {
            state.stale_sweeps +%= 1;
            const removed = sweepStale(state);
            var out = makeResult(state, op, r4os.abi.window_service_result_ok, null, "ok");
            out.flags = removed;
            break :blk out;
        },
        r4os.abi.window_service_op_restart_cleanup => blk: {
            state.restart_cleanups +%= 1;
            clearAll(state, "restart-cleanup");
            break :blk makeResult(state, op, r4os.abi.window_service_result_ok, null, "ok");
        },
        else => failResult(state, op, r4os.abi.window_service_result_bad_request, "bad-op"),
    };
}

fn upsertRecord(state: *ServiceState, op: u16, raw: r4os.abi.WindowServiceRecord, create: bool, focus: bool) r4os.abi.WindowServiceResult {
    var record = sanitizeRecord(raw);
    if (findSlot(state, record.window_id)) |index| {
        const old_z = state.slots[index].record.z_order;
        if (record.z_order == 0) record.z_order = old_z;
        state.slots[index].record = record;
        if ((record.flags & r4os.abi.window_service_flag_focused) != 0 or focus) focusRecordAt(state, index);
        noteChange(state, "ok");
        return makeResult(state, op, r4os.abi.window_service_result_ok, &state.slots[index].record, "ok");
    }
    if (!create) return failResult(state, op, r4os.abi.window_service_result_not_found, "not-found");
    const free = findFreeSlot(state) orelse return failResult(state, op, r4os.abi.window_service_result_full, "full");
    if (record.z_order == 0) record.z_order = nextZ(state);
    state.slots[free] = .{ .used = true, .record = record };
    if ((record.flags & r4os.abi.window_service_flag_focused) != 0 or focus) focusRecordAt(state, free);
    noteChange(state, "ok");
    return makeResult(state, op, r4os.abi.window_service_result_ok, &state.slots[free].record, "ok");
}

fn focusRecord(state: *ServiceState, op: u16, window_id: u32) r4os.abi.WindowServiceResult {
    const index = findSlot(state, window_id) orelse return failResult(state, op, r4os.abi.window_service_result_not_found, "not-found");
    focusRecordAt(state, index);
    noteChange(state, "ok");
    return makeResult(state, op, r4os.abi.window_service_result_ok, &state.slots[index].record, "ok");
}

fn focusRecordAt(state: *ServiceState, index: usize) void {
    var i: usize = 0;
    while (i < state.slots.len) : (i += 1) {
        if (!state.slots[i].used) continue;
        state.slots[i].record.flags &= ~r4os.abi.window_service_flag_focused;
    }
    state.slots[index].record.flags |= r4os.abi.window_service_flag_visible | r4os.abi.window_service_flag_focused;
    state.slots[index].record.flags &= ~r4os.abi.window_service_flag_minimized;
    state.slots[index].record.z_order = nextZ(state);
}

fn setRecordFlag(state: *ServiceState, op: u16, window_id: u32, flag: u32, enabled: bool, visible: bool) r4os.abi.WindowServiceResult {
    const index = findSlot(state, window_id) orelse return failResult(state, op, r4os.abi.window_service_result_not_found, "not-found");
    if (enabled) {
        state.slots[index].record.flags |= flag;
    } else {
        state.slots[index].record.flags &= ~flag;
    }
    if (visible) state.slots[index].record.flags |= r4os.abi.window_service_flag_visible;
    if (flag == r4os.abi.window_service_flag_minimized and enabled) {
        state.slots[index].record.flags &= ~r4os.abi.window_service_flag_focused;
        selectFallbackFocus(state);
    }
    noteChange(state, "ok");
    return makeResult(state, op, r4os.abi.window_service_result_ok, &state.slots[index].record, "ok");
}

fn removeRecord(state: *ServiceState, op: u16, window_id: u32) r4os.abi.WindowServiceResult {
    const index = findSlot(state, window_id) orelse return failResult(state, op, r4os.abi.window_service_result_not_found, "not-found");
    const old = state.slots[index].record;
    state.slots[index] = .{};
    selectFallbackFocus(state);
    noteChange(state, "ok");
    return makeResult(state, op, r4os.abi.window_service_result_ok, &old, "ok");
}

fn sweepStale(state: *ServiceState) u32 {
    var removed: u32 = 0;
    var i: usize = 0;
    while (i < state.slots.len) : (i += 1) {
        if (!state.slots[i].used) continue;
        if (state.slots[i].record.instance_id != 0) continue;
        state.slots[i] = .{};
        removed += 1;
    }
    if (removed != 0) {
        selectFallbackFocus(state);
        noteChange(state, "ok");
    }
    return removed;
}

fn clearAll(state: *ServiceState, reason: []const u8) void {
    var i: usize = 0;
    while (i < state.slots.len) : (i += 1) state.slots[i] = .{};
    state.next_z = 1;
    noteChange(state, reason);
}

fn selectFallbackFocus(state: *ServiceState) void {
    var best: ?usize = null;
    var best_z: u32 = 0;
    var i: usize = 0;
    while (i < state.slots.len) : (i += 1) {
        if (!state.slots[i].used) continue;
        state.slots[i].record.flags &= ~r4os.abi.window_service_flag_focused;
        const flags = state.slots[i].record.flags;
        if ((flags & r4os.abi.window_service_flag_visible) == 0 or (flags & r4os.abi.window_service_flag_minimized) != 0) continue;
        if (best == null or state.slots[i].record.z_order >= best_z) {
            best = i;
            best_z = state.slots[i].record.z_order;
        }
    }
    if (best) |index| state.slots[index].record.flags |= r4os.abi.window_service_flag_focused;
}

fn requestRecord(request: []const u8) ?r4os.abi.WindowServiceRecord {
    var record = r4os.abi.WindowServiceRecord{};
    if (request.len >= @sizeOf(r4os.abi.WindowServiceRecord)) {
        const bytes: [*]u8 = @ptrCast(&record);
        @memcpy(bytes[0..@sizeOf(r4os.abi.WindowServiceRecord)], request[0..@sizeOf(r4os.abi.WindowServiceRecord)]);
        if (record.magic != r4os.abi.window_service_record_magic or record.version != r4os.abi.window_service_record_version) return null;
        return record;
    }
    if (request.len >= 4) {
        record.window_id = readLe32(request, 0);
        return record;
    }
    return null;
}

fn sanitizeRecord(raw: r4os.abi.WindowServiceRecord) r4os.abi.WindowServiceRecord {
    var record = raw;
    record.magic = r4os.abi.window_service_record_magic;
    record.version = r4os.abi.window_service_record_version;
    switch (record.kind) {
        r4os.abi.window_service_kind_terminal => record.flags |= r4os.abi.window_service_flag_terminal,
        r4os.abi.window_service_kind_gui, r4os.abi.window_service_kind_manager => record.flags |= r4os.abi.window_service_flag_gui,
        else => {},
    }
    if ((record.flags & r4os.abi.window_service_flag_closing) == 0) record.flags |= r4os.abi.window_service_flag_visible;
    return record;
}

fn makeStatus(state: *const ServiceState) r4os.abi.WindowServiceStatus {
    var out = r4os.abi.WindowServiceStatus{
        .revision = state.revision,
        .window_count = windowCount(state),
        .max_windows = r4os.abi.window_service_max_windows,
        .next_z = state.next_z,
        .requests = state.requests,
        .status_requests = state.status_requests,
        .snapshot_requests = state.snapshot_requests,
        .register_requests = state.register_requests,
        .update_requests = state.update_requests,
        .focus_requests = state.focus_requests,
        .minimize_requests = state.minimize_requests,
        .restore_requests = state.restore_requests,
        .maximize_requests = state.maximize_requests,
        .close_requests = state.close_requests,
        .remove_requests = state.remove_requests,
        .stale_sweeps = state.stale_sweeps,
        .restart_cleanups = state.restart_cleanups,
        .bad_ops = state.bad_ops,
        .bad_requests = state.bad_requests,
    };
    var i: usize = 0;
    while (i < state.slots.len) : (i += 1) {
        if (!state.slots[i].used) continue;
        if ((state.slots[i].record.flags & r4os.abi.window_service_flag_focused) == 0) continue;
        out.focused_window = state.slots[i].record.window_id;
        out.focused_instance = state.slots[i].record.instance_id;
        break;
    }
    copyFixed(out.last_error[0..], spanZ(state.last_error[0..]));
    return out;
}

fn makeSnapshot(state: *const ServiceState) r4os.abi.WindowServiceSnapshot {
    var out = r4os.abi.WindowServiceSnapshot{
        .status = makeStatus(state),
    };
    var src: usize = 0;
    var dst: usize = 0;
    while (src < state.slots.len and dst < out.records.len) : (src += 1) {
        if (!state.slots[src].used) continue;
        out.records[dst] = state.slots[src].record;
        dst += 1;
    }
    return out;
}

fn makeResult(state: *const ServiceState, action: u16, result: i32, record: ?*const r4os.abi.WindowServiceRecord, last: []const u8) r4os.abi.WindowServiceResult {
    const status = makeStatus(state);
    var out = r4os.abi.WindowServiceResult{
        .action = action,
        .result = result,
        .window_count = status.window_count,
        .max_windows = status.max_windows,
        .focused_window = status.focused_window,
        .focused_instance = status.focused_instance,
    };
    if (record) |value| out.record = value.*;
    copyFixed(out.last_error[0..], last);
    return out;
}

fn failResult(state: *ServiceState, action: u16, result: i32, last: []const u8) r4os.abi.WindowServiceResult {
    state.bad_requests +%= 1;
    setLastError(state, last);
    return makeResult(state, action, result, null, last);
}

fn noteChange(state: *ServiceState, last: []const u8) void {
    state.revision +%= 1;
    setLastError(state, last);
}

fn setLastError(state: *ServiceState, value: []const u8) void {
    copyFixed(state.last_error[0..], value);
}

fn findSlot(state: *const ServiceState, window_id: u32) ?usize {
    var i: usize = 0;
    while (i < state.slots.len) : (i += 1) {
        if (state.slots[i].used and state.slots[i].record.window_id == window_id) return i;
    }
    return null;
}

fn findFreeSlot(state: *const ServiceState) ?usize {
    var i: usize = 0;
    while (i < state.slots.len) : (i += 1) {
        if (!state.slots[i].used) return i;
    }
    return null;
}

fn windowCount(state: *const ServiceState) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < state.slots.len) : (i += 1) {
        if (state.slots[i].used) count += 1;
    }
    return count;
}

fn nextZ(state: *ServiceState) u32 {
    const out = state.next_z;
    state.next_z +%= 1;
    if (state.next_z == 0) state.next_z = 1;
    return out;
}

fn runPing(ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("WINSVC ping");
    var info: r4os.abi.ServiceInfo = .{};
    const handle = waitServiceOpen(ctx, &info, 100) orelse {
        ctx.println("WINSVC ping failed: service not open");
        return 1;
    };
    var status: r4os.abi.WindowServiceStatus = .{};
    const ok = callStatus(ctx, handle, &status);
    _ = ctx.serviceClose(handle);
    if (!ok or status.magic != r4os.abi.window_service_status_magic or status.version != r4os.abi.window_service_status_version) {
        ctx.println("WINSVC ping failed");
        return 1;
    }
    ctx.println("WINSVC ping: OK");
    return 0;
}

fn runSelfTest(ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("WINSVC selftest");
    if (!ctx.hasFn("service_start")) return fail(ctx, "manager-api");
    if (!ctx.hasFn("service_call")) return fail(ctx, "service-api");

    var info: r4os.abi.ServiceInfo = .{};
    var handle = waitServiceOpen(ctx, &info, 120) orelse return fail(ctx, "open");
    if (!callRestartCleanup(ctx, handle)) return fail(ctx, "initial-cleanup");

    var snapshot: r4os.abi.WindowServiceSnapshot = .{};
    if (!callSnapshot(ctx, handle, &snapshot) or snapshot.status.window_count != 0) return fail(ctx, "empty");

    var first = makeTestRecord(1, 1001, "First", "C:\\BIN\\FIRST.R4X", r4os.abi.window_service_kind_gui, 10, 20, 300, 180);
    var second = makeTestRecord(2, 1002, "Second", "C:\\BIN\\SECOND.R4X", r4os.abi.window_service_kind_terminal, 30, 40, 320, 200);
    if (!callRecord(ctx, handle, r4os.abi.window_service_op_register, &first, r4os.abi.window_service_result_ok)) return fail(ctx, "register-first");
    if (!callRecord(ctx, handle, r4os.abi.window_service_op_register, &second, r4os.abi.window_service_result_ok)) return fail(ctx, "register-second");
    if (!callSnapshot(ctx, handle, &snapshot) or snapshot.status.window_count != 2) return fail(ctx, "count-2");

    if (!callRecord(ctx, handle, r4os.abi.window_service_op_focus, &second, r4os.abi.window_service_result_ok)) return fail(ctx, "focus");
    if (!callSnapshot(ctx, handle, &snapshot) or snapshot.status.focused_window != 2 or snapshot.status.focused_instance != 1002) return fail(ctx, "focus-status");

    if (!callRecord(ctx, handle, r4os.abi.window_service_op_minimize, &second, r4os.abi.window_service_result_ok)) return fail(ctx, "minimize");
    if (!callRecord(ctx, handle, r4os.abi.window_service_op_restore, &second, r4os.abi.window_service_result_ok)) return fail(ctx, "restore");
    if (!callRecord(ctx, handle, r4os.abi.window_service_op_maximize, &first, r4os.abi.window_service_result_ok)) return fail(ctx, "maximize");

    first.x = 44;
    first.y = 55;
    copyFixed(first.title[0..], "First Updated");
    if (!callRecord(ctx, handle, r4os.abi.window_service_op_update, &first, r4os.abi.window_service_result_ok)) return fail(ctx, "update");
    if (!callRecord(ctx, handle, r4os.abi.window_service_op_close, &first, r4os.abi.window_service_result_ok)) return fail(ctx, "close");
    if (!callRecord(ctx, handle, r4os.abi.window_service_op_remove, &first, r4os.abi.window_service_result_ok)) return fail(ctx, "remove");
    if (!callSnapshot(ctx, handle, &snapshot) or snapshot.status.window_count != 1) return fail(ctx, "count-1");

    var bad_header: r4os.abi.ServiceMessageHeader = .{};
    var bad_response: [16]u8 = undefined;
    const bad = ctx.serviceCall(handle, 0x7FFE, "", &bad_header, bad_response[0..], service_timeout_ticks);
    if (bad < 0 or bad_header.status != r4os.abi.service_api_result_bad_op) return fail(ctx, "bad-op");

    if (!callRecord(ctx, handle, r4os.abi.window_service_op_register, &first, r4os.abi.window_service_result_ok)) return fail(ctx, "register-restart");
    _ = ctx.serviceClose(handle);

    var restart_info: r4os.abi.ServiceInfo = .{};
    const restart = ctx.serviceRestart(service_name, &restart_info);
    if (restart != r4os.abi.service_api_result_ok or restart_info.state != r4os.abi.service_state_running) return fail(ctx, "restart");
    handle = waitServiceOpen(ctx, &info, 120) orelse return fail(ctx, "open-after-restart");
    if (!callSnapshot(ctx, handle, &snapshot) or snapshot.status.window_count != 0) {
        _ = ctx.serviceClose(handle);
        return fail(ctx, "restart-cleanup");
    }
    _ = ctx.serviceClose(handle);

    ctx.println("WINSVC selftest: OK");
    return 0;
}

fn callStatus(ctx: *const r4os.r4sys.Context, handle: u32, out: *r4os.abi.WindowServiceStatus) bool {
    var header: r4os.abi.ServiceMessageHeader = .{};
    @memset(service_response[0..], 0);
    const got = ctx.serviceCall(handle, r4os.abi.window_service_op_status, "", &header, service_response[0..], service_timeout_ticks);
    if (got < @as(i32, @intCast(@sizeOf(r4os.abi.WindowServiceStatus))) or header.status != r4os.abi.service_api_result_ok) return false;
    const out_bytes: [*]u8 = @ptrCast(out);
    @memcpy(out_bytes[0..@sizeOf(r4os.abi.WindowServiceStatus)], service_response[0..@sizeOf(r4os.abi.WindowServiceStatus)]);
    return out.magic == r4os.abi.window_service_status_magic and out.version == r4os.abi.window_service_status_version;
}

fn callSnapshot(ctx: *const r4os.r4sys.Context, handle: u32, out: *r4os.abi.WindowServiceSnapshot) bool {
    var header: r4os.abi.ServiceMessageHeader = .{};
    @memset(service_response[0..], 0);
    const got = ctx.serviceCall(handle, r4os.abi.window_service_op_snapshot, "", &header, service_response[0..], service_timeout_ticks);
    if (got < @as(i32, @intCast(@sizeOf(r4os.abi.WindowServiceSnapshot))) or header.status != r4os.abi.service_api_result_ok) return false;
    const out_bytes: [*]u8 = @ptrCast(out);
    @memcpy(out_bytes[0..@sizeOf(r4os.abi.WindowServiceSnapshot)], service_response[0..@sizeOf(r4os.abi.WindowServiceSnapshot)]);
    return out.magic == r4os.abi.window_service_snapshot_magic and out.version == r4os.abi.window_service_snapshot_version;
}

fn callRecord(ctx: *const r4os.r4sys.Context, handle: u32, op: u16, record: *const r4os.abi.WindowServiceRecord, expected: i32) bool {
    var header: r4os.abi.ServiceMessageHeader = .{};
    const request: [*]const u8 = @ptrCast(record);
    @memset(service_response[0..], 0);
    const got = ctx.serviceCall(handle, op, request[0..@sizeOf(r4os.abi.WindowServiceRecord)], &header, service_response[0..], service_timeout_ticks);
    if (got < @as(i32, @intCast(@sizeOf(r4os.abi.WindowServiceResult))) or header.status != r4os.abi.service_api_result_ok) return false;
    var result: r4os.abi.WindowServiceResult = .{};
    const result_bytes: [*]u8 = @ptrCast(&result);
    @memcpy(result_bytes[0..@sizeOf(r4os.abi.WindowServiceResult)], service_response[0..@sizeOf(r4os.abi.WindowServiceResult)]);
    return result.magic == r4os.abi.window_service_result_magic and result.version == r4os.abi.window_service_result_version and result.result == expected;
}

fn callRestartCleanup(ctx: *const r4os.r4sys.Context, handle: u32) bool {
    var header: r4os.abi.ServiceMessageHeader = .{};
    @memset(service_response[0..], 0);
    const got = ctx.serviceCall(handle, r4os.abi.window_service_op_restart_cleanup, "", &header, service_response[0..], service_timeout_ticks);
    if (got < @as(i32, @intCast(@sizeOf(r4os.abi.WindowServiceResult))) or header.status != r4os.abi.service_api_result_ok) return false;
    var result: r4os.abi.WindowServiceResult = .{};
    const result_bytes: [*]u8 = @ptrCast(&result);
    @memcpy(result_bytes[0..@sizeOf(r4os.abi.WindowServiceResult)], service_response[0..@sizeOf(r4os.abi.WindowServiceResult)]);
    return result.magic == r4os.abi.window_service_result_magic and result.result == r4os.abi.window_service_result_ok;
}

fn waitServiceOpen(ctx: *const r4os.r4sys.Context, info: *r4os.abi.ServiceInfo, max_ticks: u32) ?u32 {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const rc = ctx.serviceOpen(service_name, info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) return info.handle;
        ctx.sleepTicks(1);
    }
    const rc = ctx.serviceOpen(service_name, info);
    if (rc == r4os.abi.service_api_result_ok and info.handle != 0) return info.handle;
    return null;
}

fn makeTestRecord(id: u32, instance_id: u32, title: []const u8, path: []const u8, kind: u16, x: i32, y: i32, w: i32, h: i32) r4os.abi.WindowServiceRecord {
    var out = r4os.abi.WindowServiceRecord{
        .kind = kind,
        .window_id = id,
        .instance_id = instance_id,
        .flags = r4os.abi.window_service_flag_visible,
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .normal_x = x,
        .normal_y = y,
        .normal_w = w,
        .normal_h = h,
    };
    copyFixed(out.title[0..], title);
    copyFixed(out.path[0..], path);
    return out;
}

fn fail(ctx: *const r4os.r4sys.Context, label: []const u8) i32 {
    ctx.write("WINSVC selftest FAILED: ");
    ctx.println(label);
    return 1;
}

const Writer = struct {
    out: []u8,
    pos: usize = 0,

    fn write(self: *Writer, value: []const u8) void {
        var i: usize = 0;
        while (i < value.len and self.pos < self.out.len) : (i += 1) {
            self.out[self.pos] = value[i];
            self.pos += 1;
        }
    }

    fn writeU64(self: *Writer, value: u64) void {
        var buf: [20]u8 = .{0} ** 20;
        var n = value;
        var i: usize = buf.len;
        if (n == 0) {
            self.write("0");
            return;
        }
        while (n != 0 and i > 0) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        self.write(buf[i..]);
    }

    fn slice(self: *const Writer) []const u8 {
        return self.out[0..self.pos];
    }
};

fn copyFixed(out: []u8, value: []const u8) void {
    @memset(out, 0);
    const count = @min(out.len, value.len);
    if (count != 0) @memcpy(out[0..count], value[0..count]);
}

fn spanZ(value: []const u8) []const u8 {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (asciiUpper(a[i]) != asciiUpper(b[i])) return false;
    }
    return true;
}

fn asciiUpper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}

fn readLe32(data: []const u8, offset: usize) u32 {
    if (offset + 4 > data.len) return 0;
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

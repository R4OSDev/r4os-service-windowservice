const std = @import("std");
const r4os = @import("r4os");

pub const max_items: usize = r4os.abi.tray_max_items;
pub const max_owners: usize = r4os.abi.tray_max_owners;
pub const event_capacity: usize = r4os.abi.tray_event_queue_capacity;

const valid_item_flags = r4os.abi.tray_item_flag_visible |
    r4os.abi.tray_item_flag_enabled |
    r4os.abi.tray_item_flag_attention;

const Entry = struct {
    used: bool = false,
    request: r4os.abi.TrayServiceRequest = .{},
    order: u64 = 0,
    layout_visible: bool = false,
};

pub const Waiter = struct {
    owner: r4os.abi.ProgramProcessHandle,
    request_id: u32,
    deadline_tick: u64,
    after_sequence: u64,
};

const OwnerState = struct {
    used: bool = false,
    owner: r4os.abi.ProgramProcessHandle = .{},
    next_sequence: u64 = 1,
    events: [event_capacity]r4os.abi.TrayEvent = .{r4os.abi.TrayEvent{}} ** event_capacity,
    head: usize = 0,
    count: usize = 0,
    dropped: u32 = 0,
    waiter: ?Waiter = null,
};

pub const WaitReply = struct {
    request_id: u32,
    response: r4os.abi.TrayServiceResponse,
};

pub const WaitStart = union(enum) {
    parked,
    reply: r4os.abi.TrayServiceResponse,
};

pub const Broker = struct {
    desktop_owner: r4os.abi.ProgramProcessHandle = .{},
    desktop_epoch: u64 = 0,
    revision: u64 = 1,
    next_order: u64 = 1,
    entries: [max_items]Entry = .{Entry{}} ** max_items,
    owners: [max_owners]OwnerState = .{OwnerState{}} ** max_owners,
    registered_count: usize = 0,
    visible_count: usize = 0,
    pending: [max_owners]WaitReply = .{WaitReply{
        .request_id = 0,
        .response = .{},
    }} ** max_owners,
    pending_head: usize = 0,
    pending_count: usize = 0,

    pub fn bindDesktop(self: *Broker, owner: r4os.abi.ProgramProcessHandle) bool {
        if (!ownerValid(owner)) return false;
        if (sameOwner(self.desktop_owner, owner)) return false;

        var cancelled: [max_owners]Waiter = undefined;
        var cancelled_count: usize = 0;
        for (self.owners) |state| {
            if (state.waiter) |waiter| {
                cancelled[cancelled_count] = waiter;
                cancelled_count += 1;
            }
        }

        self.entries = .{Entry{}} ** max_items;
        self.owners = .{OwnerState{}} ** max_owners;
        self.registered_count = 0;
        self.visible_count = 0;
        self.next_order = 1;
        self.desktop_owner = owner;
        self.desktop_epoch = owner.generation;
        self.bumpRevision();

        for (cancelled[0..cancelled_count]) |waiter| {
            self.queuePending(.{
                .request_id = waiter.request_id,
                .response = self.makeResponse(waiter.owner, 0, r4os.abi.tray_result_not_found, 0),
            });
        }
        return true;
    }

    pub fn clearDesktop(self: *Broker) bool {
        if (!self.desktopBound()) return false;
        var cancelled: [max_owners]Waiter = undefined;
        var cancelled_count: usize = 0;
        for (self.owners) |state| {
            if (state.waiter) |waiter| {
                cancelled[cancelled_count] = waiter;
                cancelled_count += 1;
            }
        }
        self.entries = .{Entry{}} ** max_items;
        self.owners = .{OwnerState{}} ** max_owners;
        self.registered_count = 0;
        self.visible_count = 0;
        self.next_order = 1;
        self.desktop_owner = .{};
        self.desktop_epoch = 0;
        self.bumpRevision();
        for (cancelled[0..cancelled_count]) |waiter| {
            self.queuePending(.{
                .request_id = waiter.request_id,
                .response = self.makeResponse(waiter.owner, 0, r4os.abi.tray_result_not_found, 0),
            });
        }
        return true;
    }

    pub fn status(self: *const Broker, owner: r4os.abi.ProgramProcessHandle, item_id: u64) r4os.abi.TrayServiceResponse {
        if (!ownerValid(owner)) return self.makeResponse(owner, item_id, r4os.abi.tray_result_bad_request, 0);
        if (!self.desktopBound()) return self.makeResponse(owner, item_id, r4os.abi.tray_result_not_found, 0);
        const result = if (item_id == 0 or self.findEntryIndex(owner, item_id) != null)
            r4os.abi.tray_result_ok
        else
            r4os.abi.tray_result_not_found;
        return self.makeResponse(owner, item_id, result, 0);
    }

    pub fn upsert(self: *Broker, request: *const r4os.abi.TrayServiceRequest) r4os.abi.TrayServiceResponse {
        if (!validItemRequest(request)) return self.makeResponse(request.owner, request.item_id, r4os.abi.tray_result_bad_request, 0);
        if (!self.desktopBound()) return self.makeResponse(request.owner, request.item_id, r4os.abi.tray_result_not_found, 0);

        if (self.findEntryIndex(request.owner, request.item_id)) |index| {
            const current = &self.entries[index];
            if (request.item_revision < current.request.item_revision) {
                return self.makeResponse(request.owner, request.item_id, r4os.abi.tray_result_stale, 0);
            }
            if (request.item_revision == current.request.item_revision) {
                const result = if (requestMatches(&current.request, request)) r4os.abi.tray_result_ok else r4os.abi.tray_result_stale;
                return self.makeResponse(request.owner, request.item_id, result, 0);
            }
            const visible = current.layout_visible;
            const order = current.order;
            self.entries[index] = .{ .used = true, .request = request.*, .order = order, .layout_visible = visible };
            self.bumpRevision();
            return self.makeResponse(request.owner, request.item_id, r4os.abi.tray_result_ok, r4os.abi.tray_response_flag_changed);
        }

        if (self.registered_count >= max_items) return self.makeResponse(request.owner, request.item_id, r4os.abi.tray_result_full, 0);
        const entry_index = self.freeEntryIndex() orelse return self.makeResponse(request.owner, request.item_id, r4os.abi.tray_result_full, 0);
        var owner_index = self.findOwnerIndex(request.owner);
        if (owner_index == null) owner_index = self.freeOwnerIndex();
        if (owner_index == null) return self.makeResponse(request.owner, request.item_id, r4os.abi.tray_result_full, 0);
        if (!self.owners[owner_index.?].used) self.owners[owner_index.?] = .{ .used = true, .owner = request.owner };

        const order = self.takeCounter(&self.next_order);
        self.entries[entry_index] = .{ .used = true, .request = request.*, .order = order };
        self.registered_count += 1;
        self.bumpRevision();
        return self.makeResponse(request.owner, request.item_id, r4os.abi.tray_result_ok, r4os.abi.tray_response_flag_changed);
    }

    pub fn remove(self: *Broker, owner: r4os.abi.ProgramProcessHandle, item_id: u64) r4os.abi.TrayServiceResponse {
        if (!ownerValid(owner) or item_id == 0) return self.makeResponse(owner, item_id, r4os.abi.tray_result_bad_request, 0);
        if (!self.desktopBound()) return self.makeResponse(owner, item_id, r4os.abi.tray_result_not_found, 0);
        const index = self.findEntryIndex(owner, item_id) orelse return self.makeResponse(owner, item_id, r4os.abi.tray_result_ok, 0);
        if (self.entries[index].layout_visible) self.visible_count -|= 1;
        self.entries[index] = .{};
        self.registered_count -|= 1;
        self.purgeItemEvents(owner, item_id);
        if (!self.ownerHasItems(owner)) self.removeOwnerState(owner);
        self.bumpRevision();
        return self.makeResponse(owner, item_id, r4os.abi.tray_result_ok, r4os.abi.tray_response_flag_changed);
    }

    pub fn removeOwner(self: *Broker, owner: r4os.abi.ProgramProcessHandle) bool {
        if (!ownerValid(owner)) return false;
        var changed = false;
        for (&self.entries) |*entry| {
            if (!entry.used or !sameOwner(entry.request.owner, owner)) continue;
            if (entry.layout_visible) self.visible_count -|= 1;
            entry.* = .{};
            self.registered_count -|= 1;
            changed = true;
        }
        if (self.findOwnerIndex(owner) != null) {
            self.removeOwnerState(owner);
            changed = true;
        }
        if (changed) self.bumpRevision();
        return changed;
    }

    pub fn beginWait(self: *Broker, owner: r4os.abi.ProgramProcessHandle, request_id: u32, after_sequence: u64, deadline_tick: u64, now: u64) WaitStart {
        if (!ownerValid(owner) or request_id == 0 or deadline_tick == std.math.maxInt(u64)) {
            return .{ .reply = self.makeResponse(owner, 0, r4os.abi.tray_result_bad_request, 0) };
        }
        if (!self.desktopBound()) return .{ .reply = self.makeResponse(owner, 0, r4os.abi.tray_result_not_found, 0) };
        const owner_index = self.findOwnerIndex(owner) orelse return .{ .reply = self.makeResponse(owner, 0, r4os.abi.tray_result_not_found, 0) };
        const state = &self.owners[owner_index];
        self.discardConsumedEvents(state, after_sequence);
        if (self.popEvent(state)) |event| {
            var response = self.makeResponse(owner, event.item_id, r4os.abi.tray_result_ok, r4os.abi.tray_response_flag_event);
            response.event = event;
            return .{ .reply = response };
        }
        if (deadline_tick <= now) return .{ .reply = self.makeResponse(owner, 0, r4os.abi.tray_result_timeout, 0) };
        if (state.waiter != null) return .{ .reply = self.makeResponse(owner, 0, r4os.abi.tray_result_busy, 0) };
        state.waiter = .{ .owner = owner, .request_id = request_id, .deadline_tick = deadline_tick, .after_sequence = after_sequence };
        return .parked;
    }

    pub fn takeWaitReply(self: *Broker, now: u64) ?WaitReply {
        if (self.pending_count != 0) {
            const reply = self.pending[self.pending_head];
            self.pending_head = (self.pending_head + 1) % self.pending.len;
            self.pending_count -= 1;
            return reply;
        }
        for (&self.owners) |*state| {
            const waiter = state.waiter orelse continue;
            self.discardConsumedEvents(state, waiter.after_sequence);
            if (self.popEvent(state)) |event| {
                state.waiter = null;
                var response = self.makeResponse(waiter.owner, event.item_id, r4os.abi.tray_result_ok, r4os.abi.tray_response_flag_event);
                response.event = event;
                return .{ .request_id = waiter.request_id, .response = response };
            }
            if (waiter.deadline_tick <= now) {
                state.waiter = null;
                return .{ .request_id = waiter.request_id, .response = self.makeResponse(waiter.owner, 0, r4os.abi.tray_result_timeout, 0) };
            }
        }
        return null;
    }

    pub fn nextDeadline(self: *const Broker) ?u64 {
        var next: ?u64 = null;
        for (self.owners) |state| {
            const waiter = state.waiter orelse continue;
            if (next == null or waiter.deadline_tick < next.?) next = waiter.deadline_tick;
        }
        return next;
    }

    pub fn ownerAt(self: *const Broker, start: usize) ?struct { index: usize, owner: r4os.abi.ProgramProcessHandle } {
        var index = start;
        while (index < self.owners.len) : (index += 1) {
            if (self.owners[index].used) return .{ .index = index, .owner = self.owners[index].owner };
        }
        return null;
    }

    pub fn desktopSync(self: *Broker, request: *const r4os.abi.TrayDesktopExchange) r4os.abi.TrayDesktopExchange {
        if (!validDesktopExchange(request)) return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_bad_request);
        const rebound = self.bindDesktop(request.desktop_owner);
        var out = self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_ok);
        var ordinal: usize = 0;
        var restart = rebound;

        if (request.cursor == r4os.abi.tray_desktop_cursor_poll) {
            if (!rebound and request.known_revision == self.revision) {
                out.flags = r4os.abi.tray_desktop_flag_complete;
                return out;
            }
            restart = true;
        } else if (request.known_revision != self.revision or request.cursor > max_items) {
            restart = true;
        } else {
            ordinal = request.cursor;
        }
        if (restart) out.flags |= r4os.abi.tray_desktop_flag_restart;

        const entry = self.entryAtOrdinal(ordinal) orelse {
            out.flags |= r4os.abi.tray_desktop_flag_complete;
            out.next_cursor = r4os.abi.tray_desktop_cursor_poll;
            return out;
        };
        out.item = entry.request;
        out.flags |= r4os.abi.tray_desktop_flag_item;
        if (self.entryAtOrdinal(ordinal + 1) == null) {
            out.flags |= r4os.abi.tray_desktop_flag_complete;
            out.next_cursor = r4os.abi.tray_desktop_cursor_poll;
        } else {
            out.next_cursor = @intCast(ordinal + 1);
        }
        return out;
    }

    pub fn desktopActivate(self: *Broker, request: *const r4os.abi.TrayDesktopExchange) r4os.abi.TrayDesktopExchange {
        if (!validDesktopExchange(request) or !sameOwner(request.desktop_owner, self.desktop_owner)) {
            return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_not_owner);
        }
        const event = request.event;
        if (!validActivation(&event)) return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_bad_request);
        const index = self.findEntryIndex(event.owner, event.item_id) orelse return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_not_found);
        const entry = &self.entries[index];
        if (entry.request.item_revision != event.item_revision) return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_stale);
        if (!entry.layout_visible or (entry.request.item_flags & r4os.abi.tray_item_flag_enabled) == 0) {
            return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_not_found);
        }
        const owner_index = self.findOwnerIndex(event.owner) orelse return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_not_found);
        const state = &self.owners[owner_index];
        var queued = event;
        queued.sequence = self.takeCounter(&state.next_sequence);
        if (state.count == event_capacity) {
            state.head = (state.head + 1) % event_capacity;
            state.count -= 1;
            state.dropped +|= 1;
        }
        const tail = (state.head + state.count) % event_capacity;
        state.events[tail] = queued;
        state.count += 1;
        return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_ok);
    }

    pub fn desktopVisibility(self: *Broker, request: *const r4os.abi.TrayDesktopExchange) r4os.abi.TrayDesktopExchange {
        if (!validDesktopExchange(request) or !sameOwner(request.desktop_owner, self.desktop_owner)) {
            return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_not_owner);
        }
        const identity = request.event;
        if (!ownerValid(identity.owner) or identity.item_id == 0) return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_bad_request);
        const index = self.findEntryIndex(identity.owner, identity.item_id) orelse return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_not_found);
        const entry = &self.entries[index];
        if (entry.request.item_revision != identity.item_revision) return self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_stale);
        const visible = (request.flags & r4os.abi.tray_desktop_flag_layout_visible) != 0;
        if (entry.layout_visible != visible) {
            entry.layout_visible = visible;
            if (visible) self.visible_count += 1 else self.visible_count -|= 1;
        }
        var out = self.exchangeResult(request.desktop_owner, r4os.abi.tray_result_ok);
        if (visible) out.flags |= r4os.abi.tray_desktop_flag_layout_visible;
        return out;
    }

    fn desktopBound(self: *const Broker) bool {
        return ownerValid(self.desktop_owner) and self.desktop_epoch != 0;
    }

    fn exchangeResult(self: *const Broker, owner: r4os.abi.ProgramProcessHandle, result: i32) r4os.abi.TrayDesktopExchange {
        return .{
            .desktop_owner = owner,
            .result = result,
            .registered_count = @intCast(self.registered_count),
            .capacity = @intCast(max_items),
            .desktop_epoch = self.desktop_epoch,
            .registry_revision = self.revision,
        };
    }

    fn makeResponse(self: *const Broker, owner: r4os.abi.ProgramProcessHandle, item_id: u64, result: i32, extra_flags: u32) r4os.abi.TrayServiceResponse {
        var out: r4os.abi.TrayServiceResponse = .{
            .result = result,
            .flags = extra_flags,
            .desktop_epoch = self.desktop_epoch,
            .registry_revision = self.revision,
            .owner = owner,
            .item_id = item_id,
            .registered_count = @intCast(self.registered_count),
            .visible_count = @intCast(self.visible_count),
            .capacity = @intCast(max_items),
        };
        if (self.findOwnerIndex(owner)) |owner_index| {
            out.queued_events = @intCast(self.owners[owner_index].count);
            out.dropped_events = self.owners[owner_index].dropped;
        }
        if (item_id != 0) {
            if (self.findEntryIndex(owner, item_id)) |entry_index| {
                const entry = &self.entries[entry_index];
                out.flags |= r4os.abi.tray_response_flag_exists;
                if (entry.layout_visible) out.flags |= r4os.abi.tray_response_flag_layout_visible;
                out.item_revision = entry.request.item_revision;
                out.item_flags = entry.request.item_flags;
                out.status_flags = entry.request.status_flags;
            }
        }
        return out;
    }

    fn queuePending(self: *Broker, reply: WaitReply) void {
        if (self.pending_count == self.pending.len) {
            self.pending_head = (self.pending_head + 1) % self.pending.len;
            self.pending_count -= 1;
        }
        const tail = (self.pending_head + self.pending_count) % self.pending.len;
        self.pending[tail] = reply;
        self.pending_count += 1;
    }

    fn removeOwnerState(self: *Broker, owner: r4os.abi.ProgramProcessHandle) void {
        const owner_index = self.findOwnerIndex(owner) orelse return;
        const waiter = self.owners[owner_index].waiter;
        self.owners[owner_index] = .{};
        if (waiter) |value| {
            self.queuePending(.{
                .request_id = value.request_id,
                .response = self.makeResponse(owner, 0, r4os.abi.tray_result_not_found, 0),
            });
        }
    }

    fn entryAtOrdinal(self: *const Broker, ordinal: usize) ?*const Entry {
        for (&self.entries) |*candidate| {
            if (!candidate.used) continue;
            var rank: usize = 0;
            for (self.entries) |other| {
                if (other.used and other.order < candidate.order) rank += 1;
            }
            if (rank == ordinal) return candidate;
        }
        return null;
    }

    fn findEntryIndex(self: *const Broker, owner: r4os.abi.ProgramProcessHandle, item_id: u64) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry.used and entry.request.item_id == item_id and sameOwner(entry.request.owner, owner)) return index;
        }
        return null;
    }

    fn freeEntryIndex(self: *const Broker) ?usize {
        for (self.entries, 0..) |entry, index| if (!entry.used) return index;
        return null;
    }

    fn findOwnerIndex(self: *const Broker, owner: r4os.abi.ProgramProcessHandle) ?usize {
        for (self.owners, 0..) |state, index| {
            if (state.used and sameOwner(state.owner, owner)) return index;
        }
        return null;
    }

    fn freeOwnerIndex(self: *const Broker) ?usize {
        for (self.owners, 0..) |state, index| if (!state.used) return index;
        return null;
    }

    fn ownerHasItems(self: *const Broker, owner: r4os.abi.ProgramProcessHandle) bool {
        for (self.entries) |entry| if (entry.used and sameOwner(entry.request.owner, owner)) return true;
        return false;
    }

    fn purgeItemEvents(self: *Broker, owner: r4os.abi.ProgramProcessHandle, item_id: u64) void {
        const owner_index = self.findOwnerIndex(owner) orelse return;
        const state = &self.owners[owner_index];
        var kept: [event_capacity]r4os.abi.TrayEvent = .{r4os.abi.TrayEvent{}} ** event_capacity;
        var kept_count: usize = 0;
        var offset: usize = 0;
        while (offset < state.count) : (offset += 1) {
            const event = state.events[(state.head + offset) % event_capacity];
            if (event.item_id == item_id) continue;
            kept[kept_count] = event;
            kept_count += 1;
        }
        state.events = kept;
        state.head = 0;
        state.count = kept_count;
    }

    fn discardConsumedEvents(self: *Broker, state: *OwnerState, after_sequence: u64) void {
        _ = self;
        while (state.count != 0 and state.events[state.head].sequence <= after_sequence) {
            state.head = (state.head + 1) % event_capacity;
            state.count -= 1;
        }
    }

    fn popEvent(self: *Broker, state: *OwnerState) ?r4os.abi.TrayEvent {
        _ = self;
        if (state.count == 0) return null;
        var event = state.events[state.head];
        state.head = (state.head + 1) % event_capacity;
        state.count -= 1;
        if (state.dropped != 0) {
            event.flags |= r4os.abi.tray_event_flag_overflow;
            event.dropped_before = state.dropped;
            state.dropped = 0;
        }
        return event;
    }

    fn takeCounter(self: *Broker, counter: *u64) u64 {
        _ = self;
        var value = counter.*;
        counter.* +%= 1;
        if (counter.* == 0) counter.* = 1;
        if (value == 0) value = 1;
        return value;
    }

    fn bumpRevision(self: *Broker) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }
};

pub fn validBaseRequest(request: *const r4os.abi.TrayServiceRequest) bool {
    return request.magic == r4os.abi.tray_service_request_magic and
        request.version == r4os.abi.tray_service_request_version and
        request.size == @sizeOf(r4os.abi.TrayServiceRequest) and
        ownerValid(request.owner) and
        allZero(request.reserved0[0..]);
}

fn validItemRequest(request: *const r4os.abi.TrayServiceRequest) bool {
    if (!validBaseRequest(request) or request.item_id == 0 or request.item_revision == 0 or
        request.tooltip_length > r4os.abi.tray_tooltip_bytes or
        request.icon_width != r4os.abi.tray_icon_width or
        request.icon_height != r4os.abi.tray_icon_height or
        request.icon_format != r4os.abi.tray_icon_format_argb32 or
        (request.item_flags & ~valid_item_flags) != 0)
    {
        return false;
    }
    return std.unicode.utf8ValidateSlice(request.tooltip[0..request.tooltip_length]) and
        allZero(request.tooltip[request.tooltip_length..]);
}

fn validDesktopExchange(request: *const r4os.abi.TrayDesktopExchange) bool {
    return request.magic == r4os.abi.tray_desktop_exchange_magic and
        request.version == r4os.abi.tray_desktop_exchange_version and
        request.size == @sizeOf(r4os.abi.TrayDesktopExchange) and
        ownerValid(request.desktop_owner) and
        allZero(request.reserved0[0..]);
}

fn validActivation(event: *const r4os.abi.TrayEvent) bool {
    return event.magic == r4os.abi.tray_event_magic and
        event.version == r4os.abi.tray_event_version and
        event.size == @sizeOf(r4os.abi.TrayEvent) and
        event.sequence == 0 and event.flags == 0 and event.dropped_before == 0 and event.reserved0 == 0 and
        ownerValid(event.owner) and event.item_id != 0 and event.item_revision != 0 and
        (event.kind == r4os.abi.tray_event_kind_primary or
            event.kind == r4os.abi.tray_event_kind_double or
            event.kind == r4os.abi.tray_event_kind_context or
            event.kind == r4os.abi.tray_event_kind_wheel);
}

fn requestMatches(left: *const r4os.abi.TrayServiceRequest, right: *const r4os.abi.TrayServiceRequest) bool {
    return std.mem.eql(u8, std.mem.asBytes(left), std.mem.asBytes(right));
}

pub fn ownerValid(owner: r4os.abi.ProgramProcessHandle) bool {
    return owner.instance_id != 0 and owner.reserved == 0 and owner.generation != 0;
}

pub fn sameOwner(left: r4os.abi.ProgramProcessHandle, right: r4os.abi.ProgramProcessHandle) bool {
    return left.instance_id == right.instance_id and left.reserved == right.reserved and left.generation == right.generation;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn makeRequest(owner: r4os.abi.ProgramProcessHandle, id: u64, revision: u64) r4os.abi.TrayServiceRequest {
    var request: r4os.abi.TrayServiceRequest = .{
        .owner = owner,
        .item_id = id,
        .item_revision = revision,
        .item_flags = r4os.abi.tray_item_flag_visible | r4os.abi.tray_item_flag_enabled,
        .tooltip_length = 4,
        .icon_width = 16,
        .icon_height = 16,
        .icon_format = r4os.abi.tray_icon_format_argb32,
    };
    @memcpy(request.tooltip[0..4], "test");
    request.icon[0] = 0xff11_2233;
    return request;
}

test "tray broker is generation-bound idempotent and bounded" {
    const desktop = r4os.abi.ProgramProcessHandle{ .instance_id = 1, .generation = 50 };
    const owner = r4os.abi.ProgramProcessHandle{ .instance_id = 2, .generation = 70 };
    var broker: Broker = .{};
    try std.testing.expect(broker.bindDesktop(desktop));
    var request = makeRequest(owner, 1, 1);
    try std.testing.expectEqual(r4os.abi.tray_result_ok, broker.upsert(&request).result);
    try std.testing.expectEqual(@as(u64, 3), broker.revision);
    try std.testing.expectEqual(r4os.abi.tray_result_ok, broker.upsert(&request).result);
    try std.testing.expectEqual(@as(u64, 3), broker.revision);
    request.icon[0] = 0xff44_5566;
    try std.testing.expectEqual(r4os.abi.tray_result_stale, broker.upsert(&request).result);

    var id: u64 = 2;
    while (id <= max_items) : (id += 1) {
        var item = makeRequest(owner, id, 1);
        try std.testing.expectEqual(r4os.abi.tray_result_ok, broker.upsert(&item).result);
    }
    var overflow = makeRequest(owner, 99, 1);
    try std.testing.expectEqual(r4os.abi.tray_result_full, broker.upsert(&overflow).result);
    try std.testing.expectEqual(@as(usize, max_items), broker.registered_count);

    try std.testing.expect(broker.bindDesktop(.{ .instance_id = 1, .generation = 51 }));
    try std.testing.expectEqual(@as(usize, 0), broker.registered_count);
    try std.testing.expectEqual(r4os.abi.tray_result_not_found, broker.status(owner, 1).result);
}

test "desktop snapshot pages in registration order and restarts on revision drift" {
    const desktop = r4os.abi.ProgramProcessHandle{ .instance_id = 4, .generation = 10 };
    const owner = r4os.abi.ProgramProcessHandle{ .instance_id = 5, .generation = 11 };
    var broker: Broker = .{};
    _ = broker.bindDesktop(desktop);
    var first = makeRequest(owner, 20, 1);
    var second = makeRequest(owner, 10, 1);
    _ = broker.upsert(&first);
    _ = broker.upsert(&second);

    var exchange: r4os.abi.TrayDesktopExchange = .{ .desktop_owner = desktop };
    var page = broker.desktopSync(&exchange);
    try std.testing.expect((page.flags & r4os.abi.tray_desktop_flag_restart) != 0);
    try std.testing.expectEqual(@as(u64, 20), page.item.item_id);
    exchange.known_revision = page.registry_revision;
    exchange.cursor = page.next_cursor;
    page = broker.desktopSync(&exchange);
    try std.testing.expectEqual(@as(u64, 10), page.item.item_id);
    try std.testing.expect((page.flags & r4os.abi.tray_desktop_flag_complete) != 0);

    var third = makeRequest(owner, 30, 1);
    _ = broker.upsert(&third);
    exchange.cursor = 1;
    page = broker.desktopSync(&exchange);
    try std.testing.expect((page.flags & r4os.abi.tray_desktop_flag_restart) != 0);
    try std.testing.expectEqual(@as(u64, 20), page.item.item_id);
}

test "activation queue is bounded and one waiter receives overflow" {
    const desktop = r4os.abi.ProgramProcessHandle{ .instance_id = 7, .generation = 90 };
    const owner = r4os.abi.ProgramProcessHandle{ .instance_id = 8, .generation = 91 };
    var broker: Broker = .{};
    _ = broker.bindDesktop(desktop);
    var item = makeRequest(owner, 1, 1);
    _ = broker.upsert(&item);
    var visibility: r4os.abi.TrayDesktopExchange = .{ .desktop_owner = desktop, .flags = r4os.abi.tray_desktop_flag_layout_visible };
    visibility.event.owner = owner;
    visibility.event.item_id = 1;
    visibility.event.item_revision = 1;
    try std.testing.expectEqual(r4os.abi.tray_result_ok, broker.desktopVisibility(&visibility).result);

    var activation: r4os.abi.TrayDesktopExchange = .{ .desktop_owner = desktop };
    activation.event.owner = owner;
    activation.event.item_id = 1;
    activation.event.item_revision = 1;
    activation.event.kind = r4os.abi.tray_event_kind_primary;
    var count: usize = 0;
    while (count < event_capacity + 2) : (count += 1) try std.testing.expectEqual(r4os.abi.tray_result_ok, broker.desktopActivate(&activation).result);

    const start = broker.beginWait(owner, 44, 0, 100, 1);
    const response = switch (start) {
        .reply => |value| value,
        .parked => return error.TestUnexpectedResult,
    };
    try std.testing.expect((response.flags & r4os.abi.tray_response_flag_event) != 0);
    try std.testing.expect((response.event.flags & r4os.abi.tray_event_flag_overflow) != 0);
    try std.testing.expectEqual(@as(u32, 2), response.event.dropped_before);
    try std.testing.expectEqual(.parked, broker.beginWait(owner, 45, 100, 200, 1));
    try std.testing.expectEqual(r4os.abi.tray_result_busy, switch (broker.beginWait(owner, 46, 100, 200, 1)) {
        .reply => |value| value.result,
        .parked => 99,
    });
    try std.testing.expect(broker.bindDesktop(.{ .instance_id = 7, .generation = 92 }));
    try std.testing.expectEqual(r4os.abi.tray_result_not_found, broker.takeWaitReply(2).?.response.result);
}

test "provider wait rejects an infinite deadline" {
    const desktop = r4os.abi.ProgramProcessHandle{ .instance_id = 7, .generation = 90 };
    const owner = r4os.abi.ProgramProcessHandle{ .instance_id = 8, .generation = 91 };
    var broker: Broker = .{};
    _ = broker.bindDesktop(desktop);
    var item = makeRequest(owner, 1, 1);
    _ = broker.upsert(&item);

    const start = broker.beginWait(owner, 44, 0, std.math.maxInt(u64), 1);
    try std.testing.expectEqual(r4os.abi.tray_result_bad_request, switch (start) {
        .reply => |value| value.result,
        .parked => 99,
    });
    try std.testing.expectEqual(@as(?u64, null), broker.nextDeadline());
}

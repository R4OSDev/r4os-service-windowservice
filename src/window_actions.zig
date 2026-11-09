//! Copied action delegation and receipts. Actual WM/view state belongs to
//! Desktop; live caller/source checks belong to main's existing canonical APIs.
const std = @import("std");
const a = @import("r4os").abi;
pub const Handle = a.ProgramProcessHandle;
pub const Token = a.DesktopActionToken;
pub const Request = a.DesktopActionRequest;
pub const Reply = a.DesktopActionReply;
pub const State = a.DesktopActionState;
/// Legacy launch receipts use slot + 1 (zero means none). Native GUI/mode
/// identities use the zero-based slot. Preserve that protocol boundary.
pub fn windowIdFromLaunchReceipt(receipt: u32) i32 {
    if (receipt == 0 or receipt > 4) return -1;
    return @intCast(receipt - 1);
}
pub const Launch = struct { request: Handle, owner: Handle = .{}, desktop: Handle = .{}, window_id: i32 = -1, deadline: u64 = 0 };
const Slot = struct {
    used: bool = false,
    token: Token = .{},
    launch: Launch = .{ .request = .{} },
    command: ?Request = null,
    last: ?Request = null,
    phase: u32 = a.desktop_action_phase_granted,
    result: i32 = 0,
    applied: State = .{},
    ended: bool = false,
    offered: bool = false,
    admitted_tick: u64 = 0,
    applied_tick: u64 = 0,
    pointer_basis: u64 = 0,
    pointer_until: u64 = 0,
    pointer_down: bool = false,
    pointer_steps: u32 = 0,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
};
pub fn valid(h: Handle) bool {
    return h.instance_id != 0 and h.reserved == 0 and h.generation != 0;
}
pub fn same(x: Handle, y: Handle) bool {
    return std.meta.eql(x, y);
}
pub fn sameWindow(x: a.WindowModeIdentity, y: a.WindowModeIdentity) bool {
    return std.meta.eql(x, y);
}
fn empty(h: Handle) bool {
    return std.meta.eql(h, Handle{});
}
fn nonzero(words: [3]u64) bool {
    return words[0] | words[1] | words[2] != 0;
}
fn rights(kind: u32) u32 {
    return switch (kind) {
        1 => 1,
        2 => 2,
        3 => 4,
        a.desktop_action_kind_pointer_down, a.desktop_action_kind_pointer_move, a.desktop_action_kind_pointer_up => a.desktop_action_right_pointer,
        else => 0,
    };
}
fn pointerKind(kind: u32) bool {
    return rights(kind) == a.desktop_action_right_pointer;
}
fn inClient(info: a.GuiWindowInfo, x: i32, y: i32) bool {
    return info.client_w > 0 and info.client_h > 0 and x >= info.client_x and y >= info.client_y and
        @as(i64, x) < @as(i64, info.client_x) + info.client_w and @as(i64, y) < @as(i64, info.client_y) + info.client_h;
}
fn closeTo(origin: i32, point: i32) bool {
    const delta = @as(i64, point) - origin;
    const limit: i64 = a.desktop_action_pointer_max_distance_px;
    return delta >= -limit and delta <= limit;
}
fn reject(token: Token, code: i32) Reply {
    return .{ .request = .{ .token = token }, .result = code };
}
pub const Broker = struct {
    service: Handle = .{},
    epoch: [3]u64 = .{ 0, 0, 0 },
    serial: u64 = 0,
    revision: u64 = 1,
    slots: [a.desktop_action_max_grants]Slot = @splat(.{}),
    states: [a.window_service_max_windows]State = @splat(.{}),
    candidates: [a.window_service_max_windows]u64 = @splat(0),
    focus: [a.window_service_max_windows]a.DesktopFocusSnapshot = @splat(.{}),
    // A derived acknowledgement from this same original window/focus owner,
    // not another window registry. Input revision is freshness, not focus ID.
    composition_focus: a.CompositionFocus = .{},
    composition_serial: u64 = 0,
    composition_desktop: Handle = .{},
    composition_input_revision: u64 = 0,

    pub fn scope(self: *const Broker) Reply {
        return .{ .request = .{ .token = .{ .window = .{ .service = self.service }, .epoch = self.epoch } }, .result = if (valid(self.service) and nonzero(self.epoch)) 0 else a.desktop_action_result_unavailable };
    }
    fn scoped(self: *const Broker, t: Token) bool {
        return t.version == 1 and t.size == @sizeOf(Token) and t.reserved == 0 and t.window.reserved == 0 and
            valid(self.service) and nonzero(self.epoch) and same(t.window.service, self.service) and std.meta.eql(t.epoch, self.epoch);
    }
    fn find(self: *Broker, t: Token) ?*Slot {
        if (!self.scoped(t)) return null;
        for (&self.slots) |*s| if (s.used and same(s.token.request, t.request) and same(s.token.controller, t.controller) and
            (t.grant == 0 or t.grant == s.token.grant) and t.rights == s.token.rights)
        {
            // Pre-binding grant lookup is read-only. Commands check the entire
            // canonical token separately before admission.
            if (t.window.serial != 0 and !sameWindow(t.window, s.token.window)) return null;
            return s;
        };
        return null;
    }
    fn current(self: *const Broker, identity: a.WindowModeIdentity) State {
        for (self.states, 0..) |s, i| if (identity.serial != 0 and sameWindow(identity, s.window)) {
            var value = s;
            value.candidate_generation = self.candidates[i];
            if (value.candidate_generation != 0) value.proof_flags |= a.desktop_action_proof_app_ack;
            return value;
        };
        return .{};
    }
    fn reply(self: *const Broker, s: *const Slot, operation: u64, now: u64) Reply {
        const request = s.command orelse s.last orelse Request{ .token = s.token };
        if (operation != 0 and request.operation != operation) return reject(s.token, a.desktop_action_result_unknown);
        const overdue = s.command != null and now >= request.deadline;
        const expired_phase: u32 = if (s.offered) a.desktop_action_phase_unknown else a.desktop_action_phase_expired;
        const expired_result: i32 = if (s.offered) a.desktop_action_result_unknown else a.desktop_action_result_expired;
        var out: Reply = .{ .request = request, .phase = if (overdue) expired_phase else s.phase, .result = if (overdue) expired_result else s.result, .applied_tick = s.applied_tick, .applied = s.applied, .current = self.current(s.token.window) };
        out.request.token = s.token;
        if (s.ended and s.phase != a.desktop_action_phase_released) {
            out.phase = a.desktop_action_phase_ended;
            out.result = a.desktop_action_result_target_ended;
        }
        return out;
    }
    pub fn grant(self: *Broker, token: Token, caller: Handle, source: ?Launch, controller_live: bool) Reply {
        return self.grantBounded(token, caller, source, controller_live, 0, 0);
    }
    pub fn grantBounded(self: *Broker, token: Token, caller: Handle, source: ?Launch, controller_live: bool, now: u64, duration: u64) Reply {
        if (!self.scoped(token)) return reject(token, a.desktop_action_result_stale);
        if (token.grant != 0 or token.window.serial != 0 or !valid(token.request) or !valid(token.controller) or token.rights == 0 or
            (token.rights != a.desktop_action_right_pointer and token.rights & ~@as(u32, 7) != 0))
            return reject(token, a.desktop_action_result_invalid);
        if (!same(caller, token.request) or !controller_live) return reject(token, a.desktop_action_result_not_owner);
        const launch = source orelse return reject(token, a.desktop_action_result_unknown);
        if (!same(launch.request, caller)) return reject(token, a.desktop_action_result_not_owner);
        var pointer_state: ?State = null;
        var pointer_input: u64 = 0;
        if (token.rights == a.desktop_action_right_pointer) {
            if (now == 0 or duration == 0 or !valid(launch.owner) or !valid(launch.desktop) or launch.window_id < 0) return reject(token, a.desktop_action_result_unavailable);
            for (self.states) |state| if (state.window.serial != 0 and same(state.window.owner, launch.owner) and
                same(state.window.desktop, launch.desktop) and state.window.window_id == @as(u32, @intCast(launch.window_id)))
            {
                pointer_state = state;
                break;
            };
            const state = pointer_state orelse return reject(token, a.desktop_action_result_pending);
            if (state.input_revision == 0 or state.info.flags & 1 == 0 or state.info.flags & 2 != 0) return reject(token, a.desktop_action_result_unavailable);
            const focus = self.focus[state.window.window_id];
            if (!sameWindow(focus.window, state.window) or focus.view_revision != state.view_revision or
                focus.focus_state != a.desktop_focus_state_focused or focus.input_revision == 0 or
                now < focus.observed_tick or now - focus.observed_tick > duration / 2)
                return reject(token, a.desktop_action_result_pending);
            pointer_input = focus.input_revision;
        }
        if (self.find(token)) |s| {
            if (token.rights != a.desktop_action_right_pointer or
                (s.phase != a.desktop_action_phase_released and s.phase != a.desktop_action_phase_expired and s.phase != a.desktop_action_phase_ended))
                return self.reply(s, 0, 0);
        }
        // One original request/controller pair cannot silently change rights.
        for (self.slots) |s| if (s.used and same(s.token.request, token.request) and same(s.token.controller, token.controller) and
            !(token.rights == a.desktop_action_right_pointer and
                (s.phase == a.desktop_action_phase_released or s.phase == a.desktop_action_phase_expired or s.phase == a.desktop_action_phase_ended)))
            return reject(token, a.desktop_action_result_stale);
        if (self.serial == std.math.maxInt(u64)) return reject(token, a.desktop_action_result_quota);
        for (&self.slots) |*s| if (!s.used or s.phase == a.desktop_action_phase_released or
            (token.rights == a.desktop_action_right_pointer and
                (s.phase == a.desktop_action_phase_expired or s.phase == a.desktop_action_phase_ended)))
        {
            self.serial += 1;
            s.* = .{ .used = true, .token = token, .launch = launch, .pointer_basis = pointer_input, .pointer_until = if (pointer_state != null) now +| duration else 0 };
            s.token.grant = self.serial;
            self.bindKnown(s);
            self.revision +|= 1;
            return self.reply(s, 0, 0);
        };
        return reject(token, a.desktop_action_result_quota);
    }
    fn bindKnown(self: *Broker, slot: *Slot) void {
        if (slot.token.window.serial != 0 or !valid(slot.launch.owner) or slot.phase == a.desktop_action_phase_ended or slot.phase == a.desktop_action_phase_released) return;
        for (self.states) |state| if (state.window.serial != 0 and same(state.window.owner, slot.launch.owner) and
            same(state.window.desktop, slot.launch.desktop) and @as(i64, state.window.window_id) == slot.launch.window_id)
        {
            slot.token.window = state.window;
            self.revision +|= 1;
            return;
        };
    }
    pub fn launched(self: *Broker, launch: Launch) void {
        for (&self.slots) |*s| if (s.used and same(s.token.request, launch.request) and s.token.window.serial == 0) {
            s.launch = launch;
            self.bindKnown(s);
        };
    }
    pub fn removeWindow(self: *Broker, identity: a.WindowModeIdentity) void {
        if (identity.serial == 0) return;
        self.invalidateCompositionFocus(identity);
        for (&self.states, 0..) |*s, i| if (sameWindow(s.window, identity)) {
            s.* = .{};
            self.candidates[i] = 0;
            self.focus[i] = .{};
        };
        for (&self.slots) |*s| if (s.used and sameWindow(s.token.window, identity)) {
            s.ended = true;
            s.last = s.command orelse s.last;
            s.command = null;
        };
        self.revision +|= 1;
    }
    /// Called only after main verified this is the real current Desktop and
    /// the original mode broker accepted the exact published incarnation.
    pub fn publish(self: *Broker, state: State) bool {
        if (state.version != 1 or state.size != @sizeOf(State) or state.reserved != 0 or state.window.serial == 0 or
            !same(state.window.service, self.service) or state.window.window_id >= self.states.len or state.view_revision == 0 or
            state.input_revision != state.view_revision or state.info.window_id != @as(i32, @intCast(state.window.window_id))) return false;
        const i = state.window.window_id;
        const old = self.states[i];
        const same_window = sameWindow(old.window, state.window);
        if (same_window and state.view_revision < old.view_revision) return false;
        const candidate = if (same_window and state.view_revision == old.view_revision) self.candidates[i] else 0;
        if (state.proof_flags & ~@as(u32, 63) != 0 or state.proof_flags & a.desktop_action_proof_view == 0) return false;
        if (state.proof_flags & a.desktop_action_proof_composed != 0 and state.composition_serial == 0) return false;
        if (state.proof_flags & a.desktop_action_proof_app_fresh != 0 and
            (candidate == 0 or candidate <= state.frame_before or state.frame_generation < candidate or state.proof_flags & a.desktop_action_proof_composed == 0)) return false;
        if (state.proof_flags & a.desktop_action_proof_invisible != 0 and (state.info.flags & 2 == 0 or state.frame_generation != 0)) return false;
        // Validate the entire copied publication before mutating the old view.
        if (!same_window and old.window.serial != 0) self.removeWindow(old.window);
        if (!same_window or state.view_revision != old.view_revision) self.candidates[i] = 0;
        self.states[i] = state;
        self.states[i].candidate_generation = 0;
        self.states[i].proof_flags &= ~@as(u32, a.desktop_action_proof_app_ack);
        for (&self.slots) |*s| if (s.used) self.bindKnown(s);
        return true;
    }
    /// Only the admitted Desktop publishes. The v1 view record remains fixed;
    /// this copied sidecar uses the same exact window and view revision.
    pub fn publishFocus(self: *Broker, snapshot: a.DesktopFocusSnapshot) bool {
        if (snapshot.version != 1 or snapshot.size != @sizeOf(a.DesktopFocusSnapshot) or snapshot.reserved != 0 or
            snapshot.window.window_id >= self.states.len or snapshot.window.serial == 0 or
            snapshot.input_revision == 0 or snapshot.observed_tick == 0 or
            snapshot.focus_state > a.desktop_focus_state_focused or snapshot.flags & ~@as(u32, 3) != 0)
            return false;
        const index = snapshot.window.window_id;
        const view = self.states[index];
        if (!sameWindow(view.window, snapshot.window) or view.view_revision != snapshot.view_revision or
            snapshot.flags != (view.info.flags & 3) or
            (snapshot.focus_state == a.desktop_focus_state_focused and (snapshot.flags & 1 == 0 or snapshot.flags & 2 != 0))) return false;
        const previous = self.focus[index];
        if (sameWindow(previous.window, snapshot.window) and
            (snapshot.input_revision < previous.input_revision or snapshot.observed_tick < previous.observed_tick or
                (snapshot.input_revision == previous.input_revision and snapshot.observed_tick == previous.observed_tick and !std.meta.eql(snapshot, previous)))) return false;
        self.updateCompositionFocus(snapshot);
        self.focus[index] = snapshot;
        return true;
    }
    pub fn invalidateCompositionFocus(self: *Broker, identity: a.WindowModeIdentity) void {
        if (sameWindow(self.composition_focus.window, identity)) self.composition_focus = .{};
    }
    fn updateCompositionFocus(self: *Broker, snapshot: a.DesktopFocusSnapshot) void {
        if (!same(snapshot.window.desktop, self.composition_desktop)) {
            self.composition_desktop = snapshot.window.desktop;
            self.composition_input_revision = 0;
            self.composition_focus = .{};
        }
        // A delayed publication for another window cannot restore a focus
        // which a newer acknowledged Desktop input revision already replaced.
        if (snapshot.input_revision < self.composition_input_revision) return;
        self.composition_input_revision = snapshot.input_revision;
        if (snapshot.input_revision == std.math.maxInt(u64)) {
            // The old publisher saturates this ordering context. Preserve
            // its old API while refusing unorderable new focus authority.
            self.composition_focus = .{};
            return;
        }
        if (snapshot.focus_state != a.desktop_focus_state_focused) {
            self.invalidateCompositionFocus(snapshot.window);
            return;
        }
        const old = self.composition_focus;
        const changed = old.focused != 1 or !sameWindow(old.window, snapshot.window) or old.view_generation != snapshot.view_revision;
        if (changed) {
            if (self.composition_serial == std.math.maxInt(u64)) {
                self.composition_focus = .{};
                return;
            }
            self.composition_serial += 1;
        }
        self.composition_focus = .{ .window = snapshot.window, .view_generation = snapshot.view_revision, .focus_generation = self.composition_serial, .input_revision = snapshot.input_revision, .observed_tick = snapshot.observed_tick, .focused = 1 };
    }
    pub fn compositionCapability(_: *const Broker) a.CompositionCapabilityReply {
        // No qualified inputmethod is installed or registered. Never turn a
        // keyboard, transport endpoint or test fixture into a languageIME.
        return .{ .result = a.composition_error_no_provider };
    }
    pub fn compositionFocus(self: *const Broker, caller: Handle, expected: a.WindowModeIdentity, now: u64, freshness: u64) a.CompositionFocusReply {
        if (!valid(caller) or !same(expected.owner, caller) or !same(expected.service, self.service) or
            !valid(expected.desktop) or expected.reserved != 0 or expected.serial == 0 or expected.window_id >= self.states.len)
            return .{ .result = a.composition_error_stale_view };
        const current_view = self.states[expected.window_id];
        if (!sameWindow(expected, current_view.window)) return .{ .result = a.composition_error_stale_view };
        const value = self.composition_focus;
        if (value.focused != 1 or !sameWindow(value.window, expected) or value.view_generation != current_view.view_revision or
            current_view.info.flags & 1 == 0 or current_view.info.flags & 2 != 0 or
            value.observed_tick == 0 or now < value.observed_tick or now - value.observed_tick > freshness)
            return .{ .result = a.composition_error_no_focus };
        return .{ .focus = value };
    }
    pub fn focusSnapshot(self: *const Broker, caller: Handle, expected: a.WindowModeIdentity, now: u64, freshness: u64) a.DesktopFocusReply {
        if (!valid(caller) or expected.window_id >= self.states.len or (valid(expected.owner) and !same(expected.owner, caller)))
            return .{ .result = a.desktop_focus_result_stale };
        const index = expected.window_id;
        const view = self.states[index];
        if (!same(view.window.owner, caller) or view.window.serial == 0) return .{ .result = a.desktop_focus_result_missing };
        if (expected.serial != 0 and !sameWindow(expected, view.window))
            return .{ .result = a.desktop_focus_result_stale, .snapshot = self.focus[index] };
        const snapshot = self.focus[index];
        if (!sameWindow(snapshot.window, view.window) or snapshot.view_revision != view.view_revision or
            snapshot.input_revision == 0 or now < snapshot.observed_tick or now - snapshot.observed_tick > freshness or
            snapshot.focus_state == a.desktop_focus_state_unknown)
            return .{ .result = a.desktop_focus_result_unknown, .snapshot = snapshot };
        return .{ .result = a.desktop_focus_result_ok, .snapshot = snapshot };
    }
    pub fn command(self: *Broker, request: Request, caller: Handle, now: u64, target_live: bool) Reply {
        const t = request.token;
        if (!self.scoped(t)) return reject(t, a.desktop_action_result_stale);
        const s = self.find(t) orelse return reject(t, a.desktop_action_result_unknown);
        if (!same(caller, s.token.controller)) return reject(t, a.desktop_action_result_not_owner);
        if (s.phase == a.desktop_action_phase_released) return self.reply(s, 0, now);
        if (s.phase == a.desktop_action_phase_ended) return self.reply(s, 0, now);
        if (s.token.window.serial == 0) {
            var waiting = self.reply(s, 0, now);
            waiting.result = a.desktop_action_result_pending;
            return waiting;
        }
        if (!target_live or s.ended) return reject(t, a.desktop_action_result_target_ended);
        if (!std.meta.eql(t, s.token) or t.window.serial == 0 or request.operation == 0 or request.flags != 0 or request.frame_generation != 0 or
            rights(request.kind) == 0 or t.rights & rights(request.kind) == 0 or
            (request.kind == 1 and (request.width <= 0 or request.height <= 0)) or
            (!pointerKind(request.kind) and request.kind != 1 and (request.x != 0 or request.y != 0 or request.width != 0 or request.height != 0)) or
            (pointerKind(request.kind) and (request.width != 0 or request.height != 0))) return reject(t, a.desktop_action_result_invalid);
        if (s.command orelse s.last) |old| {
            if (request.operation == old.operation) return if (std.meta.eql(old, request)) self.reply(s, request.operation, now) else reject(t, a.desktop_action_result_stale);
            if (request.operation < old.operation) return reject(t, a.desktop_action_result_unknown);
        }
        if (pointerKind(request.kind)) {
            const state = self.current(t.window);
            const focus = self.focus[t.window.window_id];
            if (s.pointer_until == 0 or now >= s.pointer_until or request.deadline > s.pointer_until or
                state.window.serial == 0 or
                !sameWindow(focus.window, state.window) or focus.view_revision != state.view_revision or
                focus.input_revision != s.pointer_basis or focus.focus_state != a.desktop_focus_state_focused or
                now < focus.observed_tick or now - focus.observed_tick > (s.pointer_until -| s.admitted_tick) / 2)
                return reject(t, a.desktop_action_result_stale);
            if (s.pointer_steps >= a.desktop_action_pointer_max_steps) return reject(t, a.desktop_action_result_quota);
            if (request.kind == a.desktop_action_kind_pointer_down) {
                if (s.pointer_down or s.pointer_steps != 0 or !inClient(state.info, request.x, request.y)) return reject(t, a.desktop_action_result_invalid);
            } else if (!s.pointer_down or !closeTo(s.pointer_x, request.x) or !closeTo(s.pointer_y, request.y)) {
                return reject(t, a.desktop_action_result_invalid);
            }
        }
        if (s.phase == a.desktop_action_phase_unknown) return reject(t, a.desktop_action_result_busy);
        if (request.deadline <= now) return reject(t, a.desktop_action_result_expired);
        for (self.slots) |other| if (other.used and sameWindow(other.token.window, t.window) and (other.phase == a.desktop_action_phase_unknown or (other.command != null and now < other.command.?.deadline)))
            return reject(t, a.desktop_action_result_busy);
        s.command = request;
        s.last = null;
        s.phase = a.desktop_action_phase_pending;
        s.result = a.desktop_action_result_pending;
        s.applied = .{};
        s.offered = false;
        s.admitted_tick = now;
        s.applied_tick = 0;
        self.revision +|= 1;
        return self.reply(s, request.operation, now);
    }
    pub fn status(self: *Broker, token: Token, operation: u64, now: u64) Reply {
        if (!self.scoped(token)) return reject(token, a.desktop_action_result_stale);
        const s = self.find(token) orelse return reject(token, a.desktop_action_result_unknown);
        return self.reply(s, operation, now);
    }
    pub fn release(self: *Broker, token: Token, caller: Handle, now: u64) Reply {
        if (!self.scoped(token)) return reject(token, a.desktop_action_result_stale);
        const s = self.find(token) orelse return reject(token, a.desktop_action_result_unknown);
        if (!same(caller, s.token.controller)) return reject(token, a.desktop_action_result_not_owner);
        s.command = null;
        s.phase = a.desktop_action_phase_released;
        s.result = a.desktop_action_result_released;
        self.revision +|= 1;
        return self.reply(s, 0, now);
    }
    pub fn expire(self: *Broker, now: u64) void {
        for (&self.slots) |*s| {
            if (!s.used) continue;
            if (s.pointer_until != 0 and now >= s.pointer_until and s.command == null and
                s.phase != a.desktop_action_phase_released and s.phase != a.desktop_action_phase_ended and
                s.phase != a.desktop_action_phase_expired)
            {
                s.phase = a.desktop_action_phase_expired;
                s.result = a.desktop_action_result_expired;
                self.revision +|= 1;
            }
            if (s.token.window.serial == 0 and s.phase == a.desktop_action_phase_granted and s.launch.deadline != 0 and now >= s.launch.deadline) {
                // Window admission is bounded by the original launch deadline.
                // A console/unsupported or missing window is not a dead app.
                s.phase = a.desktop_action_phase_ended;
                s.result = a.desktop_action_result_unavailable;
                self.revision +|= 1;
            }
            if (s.command) |cmd| if (now >= cmd.deadline) {
                s.last = cmd;
                s.command = null;
                s.phase = if (s.offered) a.desktop_action_phase_unknown else a.desktop_action_phase_expired;
                s.result = if (s.offered) a.desktop_action_result_unknown else a.desktop_action_result_expired;
                self.revision +|= 1;
            };
        }
    }
    pub fn deadline(self: *const Broker) ?u64 {
        var first: ?u64 = null;
        for (self.slots) |s| if (s.used and s.token.window.serial == 0 and s.phase == a.desktop_action_phase_granted and s.launch.deadline != 0) {
            first = @min(first orelse s.launch.deadline, s.launch.deadline);
        };
        for (self.slots) |s| if (s.used) if (s.command) |cmd| {
            first = @min(first orelse cmd.deadline, cmd.deadline);
        };
        for (self.slots) |s| if (s.used and s.pointer_until != 0 and
            s.phase != a.desktop_action_phase_released and s.phase != a.desktop_action_phase_ended and
            s.phase != a.desktop_action_phase_expired)
        {
            first = @min(first orelse s.pointer_until, s.pointer_until);
        };
        return first;
    }
    /// Dead controller pruning is an explicit canonical positive-death result
    /// from main, performed on allocation/real work, never a periodic scan.
    pub fn retireController(self: *Broker, controller: Handle) void {
        for (&self.slots) |*s| {
            if (s.used and same(s.token.controller, controller)) s.* = .{};
        }
    }
    pub fn exchange(self: *Broker, request: a.DesktopWindowExchange, now: u64) Reply {
        self.expire(now);
        if (request.flags & ~@as(u32, 1) != 0) return reject(.{}, a.desktop_action_result_invalid);
        var acknowledged: ?*Slot = null;
        if (request.flags == 1) {
            const slot = self.find(request.ack.token) orelse return reject(request.ack.token, a.desktop_action_result_stale);
            const original = slot.command orelse slot.last orelse return reject(slot.token, a.desktop_action_result_stale);
            if (!std.meta.eql(original, request.ack) or !sameWindow(slot.token.window, request.applied.window) or
                request.applied_tick < slot.admitted_tick or request.applied_tick == 0 or
                (request.ack_result == 0 and (request.applied_tick > original.deadline or !slot.offered)))
                return reject(slot.token, a.desktop_action_result_stale);
            if (slot.phase == a.desktop_action_phase_applied or slot.phase == a.desktop_action_phase_rejected) {
                if (slot.result != request.ack_result or slot.applied_tick != request.applied_tick or !std.meta.eql(slot.applied, request.applied))
                    return reject(slot.token, a.desktop_action_result_stale);
            } else if (slot.phase != a.desktop_action_phase_released) {
                // A late original ACK resolves an offered timeout; it never
                // reapplies WM work or overwrites the immutable original view.
                slot.last = original;
                slot.command = null;
                slot.result = request.ack_result;
                slot.phase = if (request.ack_result == 0) a.desktop_action_phase_applied else a.desktop_action_phase_rejected;
                slot.applied = request.applied;
                slot.applied_tick = request.applied_tick;
                if (request.ack_result == 0 and pointerKind(original.kind)) {
                    slot.pointer_steps += 1;
                    if (original.kind == a.desktop_action_kind_pointer_down) {
                        slot.pointer_down = true;
                        slot.pointer_x = original.x;
                        slot.pointer_y = original.y;
                    } else if (original.kind == a.desktop_action_kind_pointer_up) slot.pointer_down = false;
                }
                self.revision +|= 1;
            }
            acknowledged = slot;
        }
        if (!self.publish(request.state)) return reject(.{}, a.desktop_action_result_invalid);
        if (acknowledged) |slot| return self.reply(slot, request.ack.operation, now);
        for (&self.slots) |*slot| if (slot.used and sameWindow(slot.token.window, request.state.window)) {
            if (slot.command != null) {
                // Preparing an offer is conservatively possibly delivered,
                // even if the transport reply is lost. Timeout stays Unknown.
                slot.offered = true;
                return self.reply(slot, 0, now);
            }
            if (slot.phase == a.desktop_action_phase_unknown) return self.reply(slot, 0, now);
            if (slot.token.rights == a.desktop_action_right_pointer and
                (slot.phase == a.desktop_action_phase_released or slot.phase == a.desktop_action_phase_ended or slot.phase == a.desktop_action_phase_expired))
                return self.reply(slot, 0, now);
        };
        return .{ .current = self.current(request.state.window) };
    }
    pub fn appView(self: *const Broker, caller: Handle, window_id: u32) Reply {
        if (!valid(caller) or !valid(self.service) or !nonzero(self.epoch)) return reject(.{}, a.desktop_action_result_unavailable);
        for (self.states) |state| if (same(state.window.owner, caller) and state.window.window_id == window_id and state.window.serial != 0) {
            return .{ .request = .{ .token = .{ .window = state.window, .epoch = self.epoch } }, .current = self.current(state.window) };
        };
        return reject(.{}, a.desktop_action_result_unavailable);
    }
    pub fn appFrame(self: *Broker, request: Request, caller: Handle) Reply {
        const t = request.token;
        if (!self.scoped(t)) return reject(t, a.desktop_action_result_stale);
        if (!same(t.window.owner, caller) or t.grant != 0 or !empty(t.request) or !empty(t.controller) or t.rights != 0) return reject(t, a.desktop_action_result_not_owner);
        const state = self.current(t.window);
        if (state.view_revision == 0 or state.info.flags & 2 != 0 or request.operation != state.view_revision or request.width != state.info.client_w or request.height != state.info.client_h or
            request.frame_generation <= state.frame_before or request.kind != 0 or request.flags != 0 or request.deadline != 0 or request.x != 0 or request.y != 0) return reject(t, a.desktop_action_result_stale);
        const index = t.window.window_id;
        if (request.frame_generation > self.candidates[index]) {
            self.candidates[index] = request.frame_generation;
            self.revision +|= 1;
        }
        return .{ .request = request, .current = self.current(t.window) };
    }
};

// These focused owner cases join the existing launch-test, not a new suite.
test {
    _ = @import("window_actions_test.zig");
}

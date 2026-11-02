const std = @import("std");
const w = @import("window_actions.zig");
const a = @import("r4os").abi;
const t = std.testing;
fn handle(id: u32) w.Handle {
    return .{ .instance_id = id, .generation = 1000 + id };
}
fn broker() w.Broker {
    return .{ .service = handle(1), .epoch = .{ 123, 456, 789 } };
}
fn state(b: *const w.Broker, revision: u64) w.State {
    return .{ .window = .{ .service = b.service, .desktop = handle(2), .owner = handle(3), .serial = 77, .window_id = 2 }, .view_revision = revision, .frame_before = 10, .input_revision = revision, .info = .{ .window_id = 2, .frame_x = 30, .frame_y = 40, .frame_w = 640, .frame_h = 480, .client_x = 38, .client_y = 70, .client_w = 624, .client_h = 442, .flags = 1 }, .proof_flags = a.desktop_action_proof_view };
}
fn grant(b: *w.Broker, origin: u32, controller: u32) w.Token {
    var token = b.scope().request.token;
    token.request = handle(origin);
    token.controller = handle(controller);
    token.rights = 7;
    return b.grant(token, handle(origin), .{ .request = handle(origin), .owner = handle(3), .desktop = handle(2), .window_id = 2 }, true).request.token;
}
fn command(token: w.Token) w.Request {
    return .{ .token = token, .operation = 1, .deadline = 100, .kind = 1, .x = 50, .y = 60, .width = 320, .height = 200 };
}
test "delegated grant requires the real live launch requester and exact named controller" {
    var b = broker();
    try t.expect(b.publish(state(&b, 1)));
    var token = b.scope().request.token;
    token.request = handle(4);
    token.controller = handle(5);
    token.rights = 7;
    const source: w.Launch = .{ .request = handle(4), .owner = handle(3), .desktop = handle(2), .window_id = 2 };
    try t.expectEqual(a.desktop_action_result_not_owner, b.grant(token, handle(6), source, true).result);
    try t.expectEqual(a.desktop_action_result_not_owner, b.grant(token, handle(4), source, false).result);
    const actual = b.grant(token, handle(4), source, true).request.token;
    try t.expectEqual(@as(u64, 77), actual.window.serial);
    try t.expectEqual(@as(u64, 1), actual.grant);
    try t.expectEqual(a.desktop_action_result_not_owner, b.command(command(actual), handle(6), 10, true).result);
    try t.expectEqual(a.desktop_action_phase_pending, b.command(command(actual), handle(5), 10, true).phase);
    try t.expectEqual(a.desktop_action_result_busy, b.command(.{ .token = grant(&b, 7, 8), .operation = 1, .deadline = 100, .kind = 2 }, handle(8), 11, true).result);
    var foreign = actual;
    foreign.epoch[1] += 1;
    try t.expectEqual(a.desktop_action_result_stale, b.status(foreign, 0, 10).result);
    foreign = actual;
    foreign.window.owner.generation += 1;
    try t.expectEqual(a.desktop_action_result_unknown, b.status(foreign, 0, 10).result);
    var waiting = broker();
    var unbound = waiting.scope().request.token;
    unbound.request = handle(4);
    unbound.controller = handle(5);
    unbound.rights = 7;
    const pending = waiting.grant(unbound, handle(4), .{ .request = handle(4), .owner = handle(3), .desktop = handle(2), .window_id = 2, .deadline = 50 }, true);
    try t.expectEqual(@as(u64, 0), pending.request.token.window.serial);
    try t.expectEqual(@as(?u64, 50), waiting.deadline());
    waiting.expire(51);
    try t.expectEqual(a.desktop_action_result_unavailable, waiting.status(pending.request.token, 0, 51).result);
    try t.expect(waiting.publish(state(&waiting, 1)));
    try t.expectEqual(@as(u64, 0), waiting.status(pending.request.token, 0, 52).request.token.window.serial);
    // Real native failure: launch reported receipt 2 for GUI slot 1. A
    // numerically copied receipt never bound to the published native view.
    var mapped = broker();
    var mapped_state = state(&mapped, 1);
    mapped_state.window.window_id = 1;
    mapped_state.info.window_id = 1;
    try t.expect(mapped.publish(mapped_state));
    var mapped_token = mapped.scope().request.token;
    mapped_token.request = handle(4);
    mapped_token.controller = handle(5);
    mapped_token.rights = 7;
    const mapped_grant = mapped.grant(mapped_token, handle(4), .{ .request = handle(4), .owner = handle(3), .desktop = handle(2), .window_id = w.windowIdFromLaunchReceipt(2) }, true);
    try t.expectEqual(@as(u64, 77), mapped_grant.request.token.window.serial);
    try t.expectEqual(@as(u32, 1), mapped_grant.request.token.window.window_id);
    try t.expectEqual(@as(i32, -1), w.windowIdFromLaunchReceipt(0));
    try t.expectEqual(@as(i32, 3), w.windowIdFromLaunchReceipt(4));
    try t.expectEqual(@as(i32, -1), w.windowIdFromLaunchReceipt(5));
}
test "offered timeout stays unknown and a late immutable original receipt resolves it without reapply" {
    var b = broker();
    const before = state(&b, 1);
    try t.expect(b.publish(before));
    const token = grant(&b, 4, 5);
    const cmd = command(token);
    try t.expectEqual(a.desktop_action_phase_pending, b.command(cmd, handle(5), 10, true).phase);
    var exchange: a.DesktopWindowExchange = .{ .state = before };
    try t.expectEqual(a.desktop_action_phase_pending, b.exchange(exchange, 20).phase);
    b.expire(101);
    try t.expectEqual(a.desktop_action_phase_unknown, b.status(token, 1, 101).phase);
    var newer = cmd;
    newer.operation = 2;
    newer.deadline = 300;
    try t.expectEqual(a.desktop_action_result_busy, b.command(newer, handle(5), 102, true).result);
    var applied = state(&b, 2);
    applied.info.client_w = 320;
    applied.info.client_h = 200;
    exchange = .{ .state = state(&b, 3), .ack = cmd, .applied = applied, .applied_tick = 30, .flags = 1 };
    const late = b.exchange(exchange, 200);
    try t.expectEqual(a.desktop_action_phase_applied, late.phase);
    try t.expectEqual(@as(u64, 30), late.applied_tick);
    try t.expectEqual(@as(u64, 2), late.applied.view_revision);
    try t.expectEqual(@as(u64, 3), late.current.view_revision);
    try t.expectEqual(a.desktop_action_phase_applied, b.exchange(exchange, 201).phase);
    exchange.applied.info.client_w += 1;
    try t.expectEqual(a.desktop_action_result_stale, b.exchange(exchange, 202).result);
    try t.expectEqual(@as(i32, 320), b.status(token, 1, 202).applied.info.client_w);
    newer = cmd;
    newer.width += 1;
    try t.expectEqual(a.desktop_action_result_stale, b.command(newer, handle(5), 203, true).result);
    var unoffered = broker();
    try t.expect(unoffered.publish(state(&unoffered, 1)));
    const other = grant(&unoffered, 4, 5);
    _ = unoffered.command(command(other), handle(5), 10, true);
    unoffered.expire(101);
    try t.expectEqual(a.desktop_action_phase_expired, unoffered.status(other, 1, 101).phase);
}
test "own app view ACK is not composed pixels and an old coordinate view cannot acknowledge a new one" {
    var b = broker();
    var view = state(&b, 1);
    try t.expect(b.publish(view));
    const own = b.appView(handle(3), 2).request.token;
    var ack: w.Request = .{ .token = own, .operation = 1, .width = view.info.client_w, .height = view.info.client_h, .frame_generation = 11 };
    try t.expectEqual(a.desktop_action_result_not_owner, b.appFrame(ack, handle(4)).result);
    const received = b.appFrame(ack, handle(3));
    try t.expectEqual(@as(i32, 0), received.result);
    try t.expectEqual(@as(u64, 11), received.current.candidate_generation);
    try t.expectEqual(@as(u64, 0), received.current.composition_serial);
    view.frame_generation = 11;
    view.composition_serial = 1;
    view.proof_flags |= a.desktop_action_proof_composed | a.desktop_action_proof_app_fresh;
    try t.expect(b.publish(view));
    try t.expectEqual(@as(u64, 11), b.appView(handle(3), 2).current.frame_generation);
    view = state(&b, 2);
    view.frame_before = 11;
    try t.expect(b.publish(view));
    try t.expectEqual(a.desktop_action_result_stale, b.appFrame(ack, handle(3)).result);
    try t.expectEqual(@as(u64, 0), b.appView(handle(3), 2).current.candidate_generation);
    view = state(&b, 3);
    view.info.flags = 3;
    view.composition_serial = 2;
    view.proof_flags |= a.desktop_action_proof_composed | a.desktop_action_proof_invisible;
    try t.expect(b.publish(view));
    try t.expectEqual(@as(u64, 0), b.appView(handle(3), 2).current.frame_generation);
    ack.operation = 3;
    try t.expectEqual(a.desktop_action_result_stale, b.appFrame(ack, handle(3)).result);
}
test "grant quota is bounded and positively dead controller reuse never resurrects old grants" {
    var b = broker();
    try t.expect(b.publish(state(&b, 1)));
    const first = grant(&b, 10, 100);
    for (1..16) |i| _ = grant(&b, @intCast(10 + i), @intCast(100 + i));
    var token = b.scope().request.token;
    token.request = handle(40);
    token.controller = handle(140);
    token.rights = 7;
    const source: w.Launch = .{ .request = token.request, .owner = handle(3), .desktop = handle(2), .window_id = 2 };
    try t.expectEqual(a.desktop_action_result_quota, b.grant(token, token.request, source, true).result);
    b.retireController(first.controller);
    const replacement = b.grant(token, token.request, source, true);
    try t.expectEqual(@as(u64, 17), replacement.request.token.grant);
    try t.expectEqual(a.desktop_action_result_unknown, b.status(first, 0, 0).result);
    b.serial = std.math.maxInt(u64);
    b.retireController(token.controller);
    try t.expectEqual(a.desktop_action_result_quota, b.grant(token, token.request, source, true).result);
}

test "focus snapshot is own-only, exact-incarnation and read-only" {
    var b = broker();
    const view = state(&b, 1);
    try t.expect(b.publish(view));
    const focus: a.DesktopFocusSnapshot = .{ .window = view.window, .view_revision = 1,
        .input_revision = 8, .observed_tick = 20, .focus_state = a.desktop_focus_state_focused, .flags = 1 };
    try t.expect(b.publishFocus(focus));
    const result = b.focusSnapshot(handle(3), view.window, 21, 10);
    try t.expectEqual(a.desktop_focus_result_ok, result.result);
    try t.expectEqual(@as(u64, 8), result.snapshot.input_revision);
    var stale = view.window;
    stale.serial += 1;
    try t.expectEqual(a.desktop_focus_result_stale, b.focusSnapshot(handle(3), stale, 21, 10).result);
    try t.expectEqual(a.desktop_focus_result_missing, b.focusSnapshot(handle(4), .{ .window_id = 2 }, 21, 10).result);
    try t.expectEqual(a.desktop_focus_result_unknown, b.focusSnapshot(handle(3), view.window, 32, 10).result);
    try t.expect(b.publish(state(&b, 2)));
    try t.expectEqual(a.desktop_focus_result_unknown, b.focusSnapshot(handle(3), view.window, 22, 10).result);
}

test "pointer grant bounds one outside drag and retains each original receipt" {
    var b = broker();
    var view = state(&b, 1);
    var token = b.scope().request.token;
    token.request = handle(4);
    token.controller = handle(5);
    token.rights = a.desktop_action_right_pointer;
    const launch: w.Launch = .{ .request = token.request, .owner = handle(3), .desktop = handle(2), .window_id = 2 };
    try t.expectEqual(a.desktop_action_result_pending, b.grantBounded(token, token.request, launch, true, 10, 100).result);
    try t.expect(b.publish(view));
    try t.expect(b.publishFocus(.{ .window = view.window, .view_revision = view.view_revision,
        .input_revision = 9, .observed_tick = 10, .focus_state = a.desktop_focus_state_focused, .flags = 1 }));
    token = b.grantBounded(token, token.request, launch, true, 10, 100).request.token;
    try t.expectEqual(view.window.serial, token.window.serial);
    var down: w.Request = .{ .token = token, .operation = 1, .deadline = 100,
        .kind = a.desktop_action_kind_pointer_down, .x = 100, .y = 100 };
    try t.expectEqual(a.desktop_action_phase_pending, b.command(down, handle(5), 11, true).phase);
    try t.expectEqual(a.desktop_action_phase_pending, b.exchange(.{ .state = view }, 12).phase);
    const ack: a.DesktopWindowExchange = .{ .state = view, .ack = down, .applied = view, .applied_tick = 13, .flags = 1 };
    try t.expectEqual(a.desktop_action_phase_applied, b.exchange(ack, 14).phase);
    try t.expectEqual(a.desktop_action_phase_applied, b.exchange(ack, 15).phase);
    var move = down;
    move.operation = 2;
    move.kind = a.desktop_action_kind_pointer_move;
    move.x = 10;
    move.y = 90;
    // A real Down can republish a view without changing authoritative input.
    // Keep the gesture bound to input/window identity, not cosmetic revisions.
    view = state(&b, 2);
    try t.expect(b.publish(view));
    try t.expect(b.publishFocus(.{ .window = view.window, .view_revision = 2,
        .input_revision = 9, .observed_tick = 15, .focus_state = a.desktop_focus_state_focused, .flags = 1 }));
    var invalidated = b;
    try t.expect(invalidated.publishFocus(.{ .window = view.window, .view_revision = 2,
        .input_revision = 10, .observed_tick = 16, .focus_state = a.desktop_focus_state_focused, .flags = 1 }));
    try t.expectEqual(a.desktop_action_result_stale, invalidated.command(move, handle(5), 16, true).result);
    try t.expectEqual(a.desktop_action_phase_pending, b.command(move, handle(5), 16, true).phase);
    try t.expectEqual(a.desktop_action_phase_pending, b.exchange(.{ .state = view }, 17).phase);
    try t.expectEqual(a.desktop_action_phase_applied, b.exchange(.{ .state = view, .ack = move, .applied = view, .applied_tick = 18, .flags = 1 }, 19).phase);
    var up = move;
    up.operation = 3;
    up.kind = a.desktop_action_kind_pointer_up;
    try t.expectEqual(a.desktop_action_phase_pending, b.command(up, handle(5), 20, true).phase);
    try t.expectEqual(a.desktop_action_phase_pending, b.exchange(.{ .state = view }, 21).phase);
    try t.expectEqual(a.desktop_action_phase_applied, b.exchange(.{ .state = view, .ack = up, .applied = view, .applied_tick = 22, .flags = 1 }, 23).phase);
    down.operation = 4;
    try t.expectEqual(a.desktop_action_result_invalid, b.command(down, handle(5), 24, true).result);
    b.expire(111);
    try t.expectEqual(a.desktop_action_phase_expired, b.status(token, 0, 111).phase);
}

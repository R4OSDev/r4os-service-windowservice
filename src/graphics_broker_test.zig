//! State-owner tests with explicitly modeled BO/fence calls. These do not
//! establish physical GPU completion, pixel correctness or Desktop support.
const std = @import("std");
const a = @import("r4os").abi;
const transport = @import("graphics_broker.zig");
const t = std.testing;
const Platform = struct {
    references: usize = 0,
    imports: usize = 0,
    next_reference: u32 = 100,
    alias: bool = false,
    reject: bool = false,
    immutable: bool = false,
    descriptor: a.GfxBufferDescriptor = .{ .byte_length = 65536, .width = 64, .height = 64, .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{ 256, 0, 0, 0 }, .usage = a.gfx_buffer_usage_render | a.gfx_buffer_usage_transfer_source, .location = a.gfx_buffer_location_device_local, .adapter_id = 1, .device_generation = 9 },
    terminal: [8]bool = .{false} ** 8,
    held: [8]bool = .{false} ** 8,
    failed: [8]bool = .{false} ** 8,
    released: [8]bool = .{false} ** 8,
    pub fn importBuffer(self: *Platform, source: a.GfxBufferHandle, output: *a.GfxBufferReference) bool {
        if (self.reject) return false;
        self.imports += 1;
        self.references += 1;
        self.next_reference += 1;
        output.* = .{ .buffer = .{ .id = if (self.alias) 1 else source.id, .generation = 1 }, .reference = .{ .id = self.next_reference, .generation = 2 }, .flags = if (self.immutable) a.gfx_buffer_reference_immutable else 0 };
        return true;
    }
    pub fn describeBuffer(self: *Platform, _: a.GfxBufferHandle, output: *a.GfxBufferDescriptor) bool {
        output.* = self.descriptor;
        return true;
    }
    pub fn releaseBuffer(self: *Platform, reference: a.GfxBufferHandle) void {
        std.debug.assert(reference.id > 100 and self.references != 0);
        self.references -= 1;
    }
    pub fn queryFence(self: *Platform, value: a.GfxFence, output: *a.GfxFenceStatus) bool {
        if (value.slot == 0 or value.slot > self.terminal.len) return false;
        const index = value.slot - 1;
        if (self.released[index]) return false;
        output.* = .{ .fence = value, .phase = if (self.terminal[index]) a.gfx_queue_phase_terminal else a.gfx_queue_phase_running, .milestone = if (value.adapter_id == 2) a.gfx_queue_milestone_scanout else a.gfx_queue_milestone_device_execution, .flags = if (self.held[index]) a.gfx_queue_flag_resources_held else 0, .result = if (self.failed[index]) a.gfx_queue_result_failed else if (self.terminal[index]) a.gfx_queue_result_complete else a.gfx_queue_result_pending };
        return true;
    }
};
fn fence(slot: u32) a.GfxFence {
    return .{ .slot = slot, .adapter_id = 1, .timeline = 1, .point = slot, .device_generation = 7, .reset_generation = 8 };
}
const Fixture = struct {
    broker: transport.Broker = .{ .service = .{ .instance_id = 1, .generation = 10 } },
    platform: Platform = .{},
    publication: a.WindowGraphicsPublication = .{ .desktop = .{ .instance_id = 2, .generation = 20 }, .owner = .{ .instance_id = 3, .generation = 30 }, .window_id = 4, .config = .{ .revision = 1, .width = 64, .height = 64, .flags = a.window_graphics_visible, .present_modes = a.window_graphics_fifo | a.window_graphics_mailbox, .min_images = 2, .max_images = 3, .format_count = 1, .backend = .{ .binding = .{ .adapter_id = 1, .device_generation = 7, .reset_generation = 8, .milestone = a.gfx_queue_milestone_device_execution }, .memory_generation = 9 }, .output = .{ .adapter_id = 1, .connector_id = 1, .device_generation = 7, .connection_generation = 10 }, .display_generation = 11, .formats = .{a.WindowGraphicsFormat{ .format = a.gfx_buffer_format_xrgb8888 }} ++ .{a.WindowGraphicsFormat{}} ** 7 } },
    chain: u64 = 0,
    serial: u64 = 0,
    consumer_serial: u64 = 0,
    fn init(self: *Fixture, mode: u32) !void {
        const reply = self.broker.publish(&self.platform, &self.publication);
        try t.expectEqual(a.window_graphics_ok, reply.result);
        self.publication.surface = reply.surface;
        var request = self.makeRequest(a.window_graphics_create_chain);
        request.image_count = 2;
        request.present_mode = mode;
        const chain = self.broker.client(&self.platform, &request);
        try t.expectEqual(a.window_graphics_ok, chain.result);
        self.chain = chain.chain;
        for (0..2) |index| {
            request = self.makeRequest(a.window_graphics_attach);
            request.image_slot = @intCast(index);
            request.source = .{ .id = @intCast(index + 1), .generation = 1 };
            try t.expectEqual(a.window_graphics_ok, self.broker.client(&self.platform, &request).result);
        }
    }
    fn makeRequest(self: *Fixture, action: u32) a.WindowGraphicsRequest {
        self.serial += 1;
        return .{ .owner = self.publication.owner, .surface = self.publication.surface, .action = action, .request_serial = self.serial, .config_revision = self.publication.config.revision, .chain = self.chain };
    }
    fn acquire(self: *Fixture) !a.WindowGraphicsReply {
        const request = self.makeRequest(a.window_graphics_acquire);
        const result = self.broker.client(&self.platform, &request);
        try t.expectEqual(a.window_graphics_ok, result.result);
        return result;
    }
    fn present(self: *Fixture, acquired: a.WindowGraphicsReply, ready: a.GfxFence) !void {
        var request = self.makeRequest(a.window_graphics_present);
        request.image_slot = acquired.image_slot;
        request.acquire_token = acquired.acquire_token;
        request.fence = ready;
        try t.expectEqual(a.window_graphics_ok, self.broker.client(&self.platform, &request).result);
        const serial = self.broker.serial;
        try t.expectEqual(a.window_graphics_ok, self.broker.client(&self.platform, &request).result);
        try t.expectEqual(serial, self.broker.serial);
    }
    fn consumer(self: *Fixture, action: u32) a.WindowGraphicsConsumer {
        self.consumer_serial += 1;
        return .{ .desktop = self.publication.desktop, .surface = self.publication.surface, .chain = self.chain, .action = action, .request_serial = self.consumer_serial, .result = a.window_graphics_ok };
    }
};

pub fn check() !void {
    try leaseAndFenceRetirement();
    try consumerCompletionBeforeProducer();
    try mailboxAndLifecycle();
    try rejectionAndWait();
}

fn consumerCompletionBeforeProducer() !void {
    var f: Fixture = .{};
    try f.init(a.window_graphics_fifo);
    defer f.broker.clear(&f.platform);
    const first = try f.acquire();
    try f.present(first, fence(1));
    const take = f.consumer(a.window_graphics_take);
    _ = f.broker.consumer(&f.platform, &take);
    _ = try f.acquire();
    var request = f.consumer(a.window_graphics_return);
    request.image_slot = first.image_slot;
    request.acquire_token = first.acquire_token;
    request.fence = fence(3);
    try t.expectEqual(@as(u32, 0), f.broker.consumer(&f.platform, &request).flags);
    request.action = a.window_graphics_release_fence;
    request.request_serial = f.consumer(a.window_graphics_release_fence).request_serial;
    try t.expectEqual(a.window_graphics_not_ready, f.broker.consumer(&f.platform, &request).result);
    f.platform.terminal[2] = true;
    const receipt = f.broker.consumer(&f.platform, &request);
    try t.expectEqual(a.window_graphics_ok, receipt.result);
    try t.expectEqual(a.window_graphics_fence_released, receipt.flags);
    f.platform.released[2] = true;
    const acquire = f.makeRequest(a.window_graphics_acquire);
    try t.expectEqual(a.window_graphics_not_ready, f.broker.client(&f.platform, &acquire).result);
    f.platform.terminal[0] = true;
    try t.expectEqual(a.window_graphics_ok, f.broker.client(&f.platform, &acquire).result);

    f.broker.clear(&f.platform);
    f = .{};
    try f.init(a.window_graphics_fifo);
    const failing = try f.acquire();
    try f.present(failing, fence(1));
    const failing_take = f.consumer(a.window_graphics_take);
    _ = f.broker.consumer(&f.platform, &failing_take);
    request = f.consumer(a.window_graphics_return);
    request.image_slot = failing.image_slot;
    request.acquire_token = failing.acquire_token;
    request.fence = fence(3);
    try t.expectEqual(a.window_graphics_ok, f.broker.consumer(&f.platform, &request).result);
    const revision = f.broker.revision;
    const wait: a.WindowGraphicsWait = .{ .owner = f.publication.owner, .known_revision = revision, .deadline_tick = 100 };
    try t.expect(f.broker.beginWait(1, &wait, 1) == null);
    f.platform.terminal[2] = true;
    f.platform.failed[2] = true;
    request.action = a.window_graphics_release_fence;
    request.request_serial = f.consumer(a.window_graphics_release_fence).request_serial;
    try t.expectEqual(a.window_graphics_device_lost, f.broker.consumer(&f.platform, &request).result);
    try t.expect(f.broker.revision > revision);
    try t.expectEqual(a.window_graphics_ok, f.broker.takeWaitReply(2).?.response.result);
    try t.expectEqual(@as(usize, 0), f.platform.references);
}

fn leaseAndFenceRetirement() !void {
    var f: Fixture = .{};
    try f.init(a.window_graphics_fifo);
    defer f.broker.clear(&f.platform);
    const first = try f.acquire();
    try f.present(first, fence(1));
    var take = f.consumer(a.window_graphics_take);
    const leased = f.broker.consumer(&f.platform, &take);
    try t.expectEqual(a.window_graphics_ok, leased.result);
    try t.expect(std.meta.eql(fence(1), leased.frame.ready)); // Pending GPU producer is transported, not CPU-waited.
    try t.expect(std.meta.eql(leased, f.broker.consumer(&f.platform, &take))); // Lost response retry.
    const second = try f.acquire();
    try f.present(second, fence(2));
    var returning = f.consumer(a.window_graphics_return);
    returning.image_slot = first.image_slot;
    returning.acquire_token = first.acquire_token;
    returning.fence = fence(3);
    returning.fence.adapter_id = 2;
    returning.fence.reset_generation = 99;
    const returned = f.broker.consumer(&f.platform, &returning);
    try t.expectEqual(a.window_graphics_ok, returned.result);
    try t.expectEqual(@as(u32, 0), returned.flags);
    var receipt = returning;
    receipt.action = a.window_graphics_release_fence;
    receipt.request_serial = f.consumer(a.window_graphics_release_fence).request_serial;
    try t.expectEqual(a.window_graphics_not_ready, f.broker.consumer(&f.platform, &receipt).result);
    var acquire = f.makeRequest(a.window_graphics_acquire);
    var result = f.broker.client(&f.platform, &acquire);
    try t.expectEqual(a.window_graphics_not_ready, result.result);
    try t.expect(std.meta.eql(fence(1), result.wait_fence));
    f.platform.terminal[0] = true;
    result = f.broker.client(&f.platform, &acquire);
    try t.expectEqual(a.window_graphics_not_ready, result.result);
    try t.expect(std.meta.eql(returning.fence, result.wait_fence));
    f.platform.terminal[2] = true;
    f.platform.held[2] = true;
    try t.expectEqual(a.window_graphics_not_ready, f.broker.client(&f.platform, &acquire).result);
    try t.expectEqual(a.window_graphics_not_ready, f.broker.consumer(&f.platform, &receipt).result);
    f.platform.held[2] = false;
    result = f.broker.client(&f.platform, &acquire);
    try t.expectEqual(a.window_graphics_ok, result.result);
    try t.expectEqual(first.image_slot, result.image_slot);
    try t.expect(result.acquire_token > first.acquire_token);
    try t.expect(std.meta.eql(result, f.broker.client(&f.platform, &acquire)));
    // Producer-side retirement can acknowledge a delayed consumer after slot
    // reuse. Once acknowledged, deleting the job's metadata is safe.
    const acknowledged = f.broker.consumer(&f.platform, &receipt);
    try t.expectEqual(a.window_graphics_ok, acknowledged.result);
    try t.expectEqual(a.window_graphics_fence_released, acknowledged.flags);
    f.platform.released[2] = true;
    try t.expect(std.meta.eql(acknowledged, f.broker.consumer(&f.platform, &receipt)));
    var old = f.makeRequest(a.window_graphics_present);
    old.image_slot = first.image_slot;
    old.acquire_token = first.acquire_token;
    old.fence = fence(1);
    try t.expectEqual(a.window_graphics_stale, f.broker.client(&f.platform, &old).result);
    take = f.consumer(a.window_graphics_take);
    try t.expectEqual(second.image_slot, f.broker.consumer(&f.platform, &take).image_slot);
    f.broker.clear(&f.platform);
    try t.expectEqual(@as(usize, 0), f.platform.references);

    // A completed Return snapshots its receipt even if the producer is still
    // pending. The next Acquire must never query freed consumer metadata.
    f = .{};
    try f.init(a.window_graphics_fifo);
    const pending = try f.acquire();
    try f.present(pending, fence(1));
    take = f.consumer(a.window_graphics_take);
    _ = f.broker.consumer(&f.platform, &take);
    _ = try f.acquire(); // No other available slot can conceal the result.
    returning = f.consumer(a.window_graphics_return);
    returning.image_slot = pending.image_slot;
    returning.acquire_token = pending.acquire_token;
    returning.fence = fence(3);
    f.platform.terminal[2] = true;
    result = f.broker.consumer(&f.platform, &returning);
    try t.expectEqual(a.window_graphics_fence_released, result.flags);
    f.platform.released[2] = true;
    acquire = f.makeRequest(a.window_graphics_acquire);
    try t.expectEqual(a.window_graphics_not_ready, f.broker.client(&f.platform, &acquire).result);
    f.platform.terminal[0] = true;
    try t.expectEqual(a.window_graphics_ok, f.broker.client(&f.platform, &acquire).result);
}

fn mailboxAndLifecycle() !void {
    var f: Fixture = .{};
    try f.init(a.window_graphics_mailbox);
    const first = try f.acquire();
    try f.present(first, fence(1));
    const second = try f.acquire();
    try f.present(second, fence(2));
    var acquire = f.makeRequest(a.window_graphics_acquire);
    try t.expectEqual(a.window_graphics_not_ready, f.broker.client(&f.platform, &acquire).result);
    f.publication.config.flags = 0;
    try t.expectEqual(a.window_graphics_ok, f.broker.publish(&f.platform, &f.publication).result);
    var take = f.consumer(a.window_graphics_take);
    try t.expectEqual(a.window_graphics_not_ready, f.broker.consumer(&f.platform, &take).result);
    f.publication.config.flags = a.window_graphics_visible;
    _ = f.broker.publish(&f.platform, &f.publication);
    const frame = f.broker.consumer(&f.platform, &take);
    try t.expectEqual(a.window_graphics_ok, frame.result);
    try t.expectEqual(second.image_slot, frame.image_slot); // Mailbox superseded first, never leased second.
    f.publication.config.revision += 1;
    f.publication.config.width = 128;
    _ = f.broker.publish(&f.platform, &f.publication);
    acquire = f.makeRequest(a.window_graphics_acquire);
    try t.expectEqual(a.window_graphics_out_of_date, f.broker.client(&f.platform, &acquire).result);
    try t.expectEqual(@as(usize, 1), f.platform.references); // Resize retained exact Desktop lease.
    var resize_return = f.consumer(a.window_graphics_return);
    resize_return.image_slot = frame.image_slot;
    resize_return.acquire_token = frame.acquire_token;
    const resized = f.broker.consumer(&f.platform, &resize_return);
    try t.expectEqual(a.window_graphics_ok, resized.result);
    try t.expectEqual(a.window_graphics_fence_released, resized.flags);
    try t.expectEqual(@as(usize, 0), f.platform.references); // Return after resize drops its last import.
    // A fresh lease is retained independently through app death below.
    f.broker.clear(&f.platform);
    f = .{};
    try f.init(a.window_graphics_fifo);
    const dying = try f.acquire();
    try f.present(dying, fence(1));
    take = f.consumer(a.window_graphics_take);
    const dead_frame = f.broker.consumer(&f.platform, &take);
    f.broker.removeOwner(&f.platform, f.publication.owner);
    try t.expectEqual(@as(usize, 1), f.platform.references);
    const revision = f.broker.revision;
    f.broker.removeOwner(&f.platform, f.publication.owner);
    try t.expectEqual(revision, f.broker.revision); // No recurring fake change on dead-owner sweep.
    var returning = f.consumer(a.window_graphics_return);
    returning.image_slot = dead_frame.image_slot;
    returning.acquire_token = dead_frame.acquire_token;
    try t.expectEqual(a.window_graphics_ok, f.broker.consumer(&f.platform, &returning).result);
    try t.expectEqual(@as(usize, 0), f.platform.references);
    const old_surface = f.publication.surface;
    f.publication.surface = .{};
    const recreated = f.broker.publish(&f.platform, &f.publication);
    try t.expectEqual(a.window_graphics_ok, recreated.result);
    try t.expect(recreated.surface.serial > old_surface.serial);
    try t.expectEqual(a.window_graphics_stale, f.broker.consumer(&f.platform, &returning).result);
    f.broker.clear(&f.platform);
    // An actual Desktop death releases outstanding service references, while
    // GPU resource pins are independently retained by the existing kernel.
    f = .{};
    try f.init(a.window_graphics_fifo);
    const image = try f.acquire();
    try f.present(image, fence(1));
    take = f.consumer(a.window_graphics_take);
    _ = f.broker.consumer(&f.platform, &take);
    f.broker.removeOwner(&f.platform, f.publication.desktop);
    try t.expectEqual(@as(usize, 0), f.platform.references);
}

fn rejectionAndWait() !void {
    var f: Fixture = .{};
    try f.init(a.window_graphics_fifo);
    defer f.broker.clear(&f.platform);
    var request = f.makeRequest(a.window_graphics_create_chain);
    request.chain = 0;
    request.image_count = 2;
    request.present_mode = a.window_graphics_fifo;
    const second_chain = f.broker.client(&f.platform, &request);
    try t.expectEqual(a.window_graphics_ok, second_chain.result);
    request = f.makeRequest(a.window_graphics_attach);
    request.chain = second_chain.chain;
    request.source = .{ .id = 3, .generation = 1 };
    f.platform.alias = true;
    try t.expectEqual(a.window_graphics_busy, f.broker.client(&f.platform, &request).result);
    try t.expectEqual(@as(usize, 2), f.platform.references);
    f.platform.alias = false;
    f.platform.immutable = true;
    try t.expectEqual(a.window_graphics_invalid, f.broker.client(&f.platform, &request).result);
    f.platform.immutable = false;
    f.platform.descriptor.device_generation += 1;
    try t.expectEqual(a.window_graphics_invalid, f.broker.client(&f.platform, &request).result);
    f.platform.descriptor.device_generation -= 1;
    f.platform.reject = true;
    try t.expectEqual(a.window_graphics_unavailable, f.broker.client(&f.platform, &request).result);
    try t.expectEqual(@as(usize, 2), f.platform.references);
    f.platform.reject = false;
    try t.expectEqual(a.window_graphics_ok, f.broker.client(&f.platform, &request).result);
    const imports = f.platform.imports;
    try t.expectEqual(a.window_graphics_ok, f.broker.client(&f.platform, &request).result);
    try t.expectEqual(imports, f.platform.imports);
    var wait: a.WindowGraphicsWait = .{ .owner = f.publication.owner, .known_revision = f.broker.revision, .deadline_tick = 100 };
    try t.expect(f.broker.beginWait(1, &wait, 1) == null);
    try t.expectEqual(a.window_graphics_busy, f.broker.beginWait(2, &wait, 1).?.result);
    try t.expect(f.broker.takeWaitReply(99) == null);
    try t.expectEqual(a.window_graphics_timeout, f.broker.takeWaitReply(100).?.response.result);
    wait.deadline_tick = 200;
    try t.expect(f.broker.beginWait(3, &wait, 101) == null);
    f.broker.clear(&f.platform);
    try t.expectEqual(a.window_graphics_closed, f.broker.takeWaitReply(102).?.response.result);
    try t.expectEqual(@as(usize, 0), f.platform.references);
    f = .{};
    try f.init(a.window_graphics_fifo);
    const acquired = try f.acquire();
    try f.present(acquired, fence(1));
    f.platform.terminal[0] = true;
    f.platform.failed[0] = true;
    const take = f.consumer(a.window_graphics_take);
    try t.expectEqual(a.window_graphics_device_lost, f.broker.consumer(&f.platform, &take).result);
    try t.expectEqual(@as(usize, 0), f.platform.references);
    request = f.makeRequest(a.window_graphics_acquire);
    try t.expectEqual(a.window_graphics_device_lost, f.broker.client(&f.platform, &request).result);
}

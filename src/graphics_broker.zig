//! Bounded common window-image transport. WINSVC owns imported references;
//! Desktop owns composition/color/output, and the existing queue owns GPU
//! completion. This owner never waits for GPU work or maps image pixels.
const std = @import("std");
const a = @import("r4os").abi;
const owners = @import("tray_broker.zig");
pub const max_surfaces = a.window_service_max_windows;
pub const max_chains = max_surfaces * 2;
pub const max_images = 3;
pub const max_waiters = max_surfaces + 1;
const Phase = enum(u32) { vacant, available, acquired, queued, leased, returning };
const Image = struct {
    phase: Phase = .vacant,
    source: a.GfxBufferReference = .{},
    descriptor: a.GfxBufferDescriptor = .{},
    token: u64 = 0,
    order: u64 = 0,
    ready: a.GfxFence = .{},
    consumed: a.GfxFence = .{},
    // Monotone acquisition tokens allow a delayed acknowledgement after the
    // producer has already reused this slot. This receipt owns no GPU work.
    consumer_released_token: u64 = 0,
};
const Chain = struct {
    id: u64 = 0,
    surface: a.WindowGraphicsSurface = .{},
    config: a.WindowGraphicsConfig = .{},
    format: a.WindowGraphicsFormat = .{},
    mode: u32 = 0,
    count: u32 = 0,
    error_result: i32 = a.window_graphics_ok,
    closing: bool = false,
    images: [max_images]Image = .{Image{}} ** max_images,
};
const Surface = struct {
    identity: a.WindowGraphicsSurface = .{},
    config: a.WindowGraphicsConfig = .{},
    removed: bool = false,
    last: a.WindowGraphicsRequest = .{},
    reply: a.WindowGraphicsReply = .{},
    last_consumer: a.WindowGraphicsConsumer = .{},
    consumer_reply: a.WindowGraphicsReply = .{},
};
const Waiter = struct {
    request_id: u32 = 0,
    request: a.WindowGraphicsWait = .{},
};
pub const WaitReply = struct { request_id: u32, response: a.WindowGraphicsReply };

pub const Broker = struct {
    service: a.ProgramProcessHandle = .{},
    revision: u64 = 1,
    serial: u64 = 0,
    surfaces: [max_surfaces]Surface = .{Surface{}} ** max_surfaces,
    chains: [max_chains]Chain = .{Chain{}} ** max_chains,
    waiters: [max_waiters]Waiter = .{Waiter{}} ** max_waiters,

    pub fn response(self: *const Broker, result: i32) a.WindowGraphicsReply {
        return .{ .result = result, .revision = self.revision };
    }

    // IDs and change revisions must never wrap into a valid old incarnation.
    fn next(self: *Broker) ?u64 {
        if (self.serial == std.math.maxInt(u64)) return null;
        self.serial += 1;
        return self.serial;
    }
    fn changed(self: *Broker) void {
        self.revision +|= 1;
    }
    fn findSurface(self: *Broker, identity: a.WindowGraphicsSurface) ?*Surface {
        if (!validHeader(identity) or identity.serial == 0) return null;
        for (&self.surfaces) |*surface| {
            if (sameSurface(surface.identity, identity)) return surface;
        }
        return null;
    }
    fn findChain(self: *Broker, surface: a.WindowGraphicsSurface, id: u64) ?*Chain {
        if (id == 0) return null;
        for (&self.chains) |*chain| {
            if (chain.id == id and sameSurface(chain.surface, surface)) return chain;
        }
        return null;
    }
    fn snapshot(self: *const Broker, surface: *const Surface, result: i32) a.WindowGraphicsReply {
        return .{ .result = result, .revision = self.revision, .surface = surface.identity, .config = surface.config };
    }

    /// Caller/target liveness and Desktop role are checked by the IPC adapter.
    pub fn publish(self: *Broker, platform: anytype, request: *const a.WindowGraphicsPublication) a.WindowGraphicsReply {
        if (!validHeader(request.*) or !owners.ownerValid(self.service) or !owners.ownerValid(request.desktop) or
            !owners.ownerValid(request.owner) or request.window_id == 0 or request.action > a.window_graphics_remove)
            return self.response(a.window_graphics_invalid);
        if (self.revision == std.math.maxInt(u64)) return self.response(a.window_graphics_capacity);
        var found: ?*Surface = null;
        if (request.surface.serial != 0) {
            found = self.findSurface(request.surface) orelse return self.response(a.window_graphics_stale);
            if (!owners.sameOwner(found.?.identity.desktop, request.desktop) or !owners.sameOwner(found.?.identity.owner, request.owner) or
                found.?.identity.window_id != request.window_id) return self.response(a.window_graphics_not_owner);
        } else {
            if (request.action != a.window_graphics_publish or !std.meta.eql(request.surface, a.WindowGraphicsSurface{}))
                return self.response(a.window_graphics_invalid);
            // A lost create reply may be repeated. Reusing the same window ID
            // after removal still creates a distinct serial.
            for (&self.surfaces) |*surface| {
                if (surface.identity.serial != 0 and !surface.removed and surface.identity.window_id == request.window_id and
                    owners.sameOwner(surface.identity.owner, request.owner) and owners.sameOwner(surface.identity.desktop, request.desktop))
                {
                    found = surface;
                    break;
                }
            }
        }
        if (request.action == a.window_graphics_remove) {
            const surface = found.?;
            self.removeSurface(platform, surface, false);
            return self.snapshot(surface, a.window_graphics_ok);
        }
        if (!validConfig(request.config)) return self.response(a.window_graphics_invalid);
        if (found) |surface| {
            if (surface.removed) return self.snapshot(surface, a.window_graphics_closed);
            var old = surface.config;
            var new = request.config;
            old.flags = 0;
            new.flags = 0;
            if (new.revision < old.revision or (new.revision == old.revision and !std.meta.eql(old, new)))
                return self.snapshot(surface, a.window_graphics_stale);
            if (!std.meta.eql(old, new)) {
                const binding_changed = !std.meta.eql(old.backend.binding, new.backend.binding) or
                    old.backend.memory_generation != new.backend.memory_generation;
                for (&self.chains) |*chain| {
                    if (chain.id != 0 and sameSurface(chain.surface, surface.identity))
                        self.invalidate(platform, chain, if (binding_changed) a.window_graphics_device_lost else a.window_graphics_out_of_date);
                }
            }
            if (!std.meta.eql(surface.config, request.config)) self.changed();
            surface.config = request.config;
            return self.snapshot(surface, a.window_graphics_ok);
        }
        // Removed records with outstanding consumer leases cannot be reused.
        for (&self.surfaces) |*surface| {
            if (surface.identity.serial == 0 or (surface.removed and !self.hasChains(surface.identity))) {
                const id = self.next() orelse return self.response(a.window_graphics_capacity);
                surface.* = .{ .identity = .{ .service = self.service, .desktop = request.desktop, .owner = request.owner, .window_id = request.window_id, .serial = id }, .config = request.config };
                self.changed();
                return self.snapshot(surface, a.window_graphics_ok);
            }
        }
        return self.response(a.window_graphics_capacity);
    }

    pub fn client(self: *Broker, platform: anytype, request: *const a.WindowGraphicsRequest) a.WindowGraphicsReply {
        if (!validHeader(request.*) or !owners.ownerValid(request.owner) or request.action > a.window_graphics_chain_status)
            return self.response(a.window_graphics_invalid);
        if (request.action == a.window_graphics_query) {
            if (request.surface.serial != 0) {
                const surface = self.findSurface(request.surface) orelse return self.response(a.window_graphics_stale);
                if (!owners.sameOwner(surface.identity.owner, request.owner)) return self.response(a.window_graphics_not_owner);
                return self.snapshot(surface, if (surface.removed) a.window_graphics_closed else a.window_graphics_ok);
            }
            for (&self.surfaces) |*surface| {
                if (!surface.removed and surface.identity.serial != 0 and surface.identity.window_id == request.window_id and
                    owners.sameOwner(surface.identity.owner, request.owner)) return self.snapshot(surface, a.window_graphics_ok);
            }
            return self.response(a.window_graphics_unavailable);
        }
        const surface = self.findSurface(request.surface) orelse return self.response(a.window_graphics_stale);
        if (!owners.sameOwner(surface.identity.owner, request.owner)) return self.response(a.window_graphics_not_owner);
        if (request.action == a.window_graphics_chain_status) {
            const chain = self.findChain(surface.identity, request.chain) orelse return self.snapshot(surface, a.window_graphics_closed);
            if (request.image_slot >= chain.count) return self.snapshot(surface, a.window_graphics_invalid);
            var result = self.snapshot(surface, chain.error_result);
            result.chain = chain.id;
            result.image_slot = request.image_slot;
            result.flags = @intFromEnum(chain.images[request.image_slot].phase);
            result.frame = frame(chain, request.image_slot);
            return result;
        }
        if (request.request_serial == 0) return self.snapshot(surface, a.window_graphics_invalid);
        if (request.request_serial <= surface.last.request_serial) {
            if (std.meta.eql(surface.last, request.*)) return surface.reply;
            return self.snapshot(surface, a.window_graphics_stale);
        }
        if (self.revision == std.math.maxInt(u64)) return self.snapshot(surface, a.window_graphics_capacity);
        var result = self.mutate(platform, surface, request);
        if (result.result == a.window_graphics_ok) {
            self.changed();
            result.revision = self.revision;
            surface.last = request.*;
            surface.reply = result;
        }
        return result;
    }

    fn mutate(self: *Broker, platform: anytype, surface: *Surface, request: *const a.WindowGraphicsRequest) a.WindowGraphicsReply {
        var result = self.snapshot(surface, a.window_graphics_ok);
        result.chain = request.chain;
        result.image_slot = request.image_slot;
        if (request.action == a.window_graphics_close_chain) {
            if (self.findChain(surface.identity, request.chain)) |chain| {
                self.closeChain(platform, chain, false);
            } else return self.snapshot(surface, a.window_graphics_closed);
            return result;
        }
        if (surface.removed) return self.snapshot(surface, a.window_graphics_closed);
        if (request.action == a.window_graphics_create_chain) {
            const config = surface.config;
            if (request.config_revision != config.revision) return self.snapshot(surface, a.window_graphics_out_of_date);
            if (request.chain != 0 or request.image_count < config.min_images or request.image_count > config.max_images or
                request.format_index >= config.format_count or (request.present_mode != a.window_graphics_fifo and request.present_mode != a.window_graphics_mailbox) or
                request.present_mode & config.present_modes == 0) return self.snapshot(surface, a.window_graphics_invalid);
            for (&self.chains) |*chain| if (chain.id == 0) {
                const id = self.next() orelse return self.snapshot(surface, a.window_graphics_capacity);
                chain.* = .{ .id = id, .surface = surface.identity, .config = config, .count = request.image_count, .format = config.formats[request.format_index], .mode = request.present_mode };
                result.chain = id;
                return result;
            };
            return self.snapshot(surface, a.window_graphics_capacity);
        }
        const chain = self.findChain(surface.identity, request.chain) orelse return self.snapshot(surface, a.window_graphics_closed);
        if (chain.closing) return self.snapshot(surface, a.window_graphics_closed);
        if (chain.error_result != a.window_graphics_ok) return self.snapshot(surface, chain.error_result);
        if (chain.config.revision != surface.config.revision or request.config_revision != chain.config.revision)
            return self.snapshot(surface, a.window_graphics_out_of_date);
        if (request.action == a.window_graphics_acquire) {
            for (chain.images[0..chain.count]) |item| if (item.phase == .vacant) return self.snapshot(surface, a.window_graphics_not_ready);
            for (chain.images[0..chain.count], 0..) |*item, index| {
                if (item.phase == .returning) {
                    const ready = self.retireCheck(platform, chain, item, &result.wait_fence);
                    if (ready < 0) return self.snapshot(surface, ready);
                }
                if (item.phase != .available) continue;
                const token = self.next() orelse return self.snapshot(surface, a.window_graphics_capacity);
                item.phase = .acquired;
                item.token = token;
                item.ready = .{};
                item.consumed = .{};
                result.image_slot = @intCast(index);
                result.acquire_token = token;
                result.wait_fence = .{};
                return result;
            }
            result.result = a.window_graphics_not_ready;
            return result;
        }
        if (request.image_slot >= chain.count) return self.snapshot(surface, a.window_graphics_invalid);
        const item = &chain.images[request.image_slot];
        switch (request.action) {
            a.window_graphics_attach => {
                if (item.phase != .vacant or !validHandle(request.source)) return self.snapshot(surface, a.window_graphics_invalid);
                var imported: a.GfxBufferReference = .{};
                if (!platform.importBuffer(request.source, &imported)) return self.snapshot(surface, a.window_graphics_unavailable);
                var keep = false;
                defer if (!keep) platform.releaseBuffer(imported.reference);
                var descriptor: a.GfxBufferDescriptor = .{};
                if (imported.flags != 0 or !platform.describeBuffer(imported.reference, &descriptor) or !validImage(chain, descriptor))
                    return self.snapshot(surface, a.window_graphics_invalid);
                // Different import references can still alias the same BO.
                // Such aliasing would let an app acquire an image under use.
                for (&self.chains) |*other| {
                    if (other.id == 0) continue;
                    for (other.images[0..other.count]) |image| {
                        if (image.phase != .vacant and std.meta.eql(image.source.buffer, imported.buffer))
                            return self.snapshot(surface, a.window_graphics_busy);
                    }
                }
                item.* = .{ .phase = .available, .source = imported, .descriptor = descriptor };
                keep = true;
            },
            a.window_graphics_present, a.window_graphics_cancel_acquire => {
                if (item.phase != .acquired or request.acquire_token == 0 or request.acquire_token != item.token)
                    return self.snapshot(surface, a.window_graphics_stale);
                if (request.action == a.window_graphics_present and !validFence(request.fence)) return self.snapshot(surface, a.window_graphics_invalid);
                if (!zeroFence(request.fence) and !admitFence(platform, chain, request.fence)) return self.snapshot(surface, a.window_graphics_device_lost);
                const order = self.next() orelse return self.snapshot(surface, a.window_graphics_capacity);
                item.ready = request.fence;
                item.order = order;
                item.phase = if (request.action == a.window_graphics_present) .queued else .returning;
                if (item.phase == .queued and chain.mode == a.window_graphics_mailbox) {
                    for (chain.images[0..chain.count]) |*older| {
                        if (older != item and older.phase == .queued) older.phase = .returning;
                    }
                }
                result.acquire_token = item.token;
            },
            else => return self.snapshot(surface, a.window_graphics_invalid),
        }
        return result;
    }

    pub fn consumer(self: *Broker, platform: anytype, request: *const a.WindowGraphicsConsumer) a.WindowGraphicsReply {
        if (!validHeader(request.*) or request.reserved != 0 or request.action > a.window_graphics_inspect)
            return self.response(a.window_graphics_invalid);
        const surface = self.findSurface(request.surface) orelse return self.response(a.window_graphics_stale);
        if (!owners.sameOwner(surface.identity.desktop, request.desktop)) return self.response(a.window_graphics_not_owner);
        if (request.action == a.window_graphics_inspect) {
            if (request.request_serial != 0 or request.chain == 0 or request.acquire_token == 0 or
                request.result != 0 or !zeroFence(request.fence)) return self.snapshot(surface, a.window_graphics_invalid);
            var result = self.snapshot(surface, a.window_graphics_closed);
            result.chain = request.chain;
            result.image_slot = request.image_slot;
            result.acquire_token = request.acquire_token;
            const chain = self.findChain(surface.identity, request.chain) orelse return result;
            if (request.image_slot >= chain.count) return self.snapshot(surface, a.window_graphics_invalid);
            const item = &chain.images[request.image_slot];
            if (item.phase != .leased or item.token != request.acquire_token) return self.snapshot(surface, a.window_graphics_stale);
            result.result = chain.error_result;
            result.flags = a.window_graphics_image_leased;
            // Read-only: neither end a metadata loan nor displace the receipt
            // needed to retry the last mutation after a lost response.
            return result;
        }
        if (request.request_serial == 0) return self.snapshot(surface, a.window_graphics_invalid);
        if (request.request_serial <= surface.last_consumer.request_serial) {
            if (std.meta.eql(surface.last_consumer, request.*)) return surface.consumer_reply;
            return self.snapshot(surface, a.window_graphics_stale);
        }
        if (self.revision == std.math.maxInt(u64)) return self.snapshot(surface, a.window_graphics_capacity);
        var result = self.snapshot(surface, a.window_graphics_ok);
        if (request.action == a.window_graphics_release_fence) {
            const chain = self.findChain(surface.identity, request.chain) orelse return self.snapshot(surface, a.window_graphics_closed);
            if (request.image_slot >= chain.count or request.acquire_token == 0) return self.snapshot(surface, a.window_graphics_invalid);
            const item = &chain.images[request.image_slot];
            if (request.acquire_token > item.consumer_released_token) {
                if (item.phase != .returning or item.token != request.acquire_token or !std.meta.eql(item.consumed, request.fence))
                    return self.snapshot(surface, a.window_graphics_stale);
                const retired = self.retireConsumer(platform, chain, item);
                if (retired != a.window_graphics_ok) return self.snapshot(surface, retired);
            }
            result.flags = a.window_graphics_fence_released;
            result.chain = request.chain;
            result.image_slot = request.image_slot;
            result.acquire_token = request.acquire_token;
        } else if (request.action == a.window_graphics_take) {
            if (surface.removed) return self.snapshot(surface, a.window_graphics_closed);
            if (surface.config.flags & a.window_graphics_visible == 0) return self.snapshot(surface, a.window_graphics_not_ready);
            var selected: ?*Chain = null;
            var slot: u32 = 0;
            var order: u64 = std.math.maxInt(u64);
            for (&self.chains) |*chain| {
                if (chain.id == 0 or chain.closing or chain.error_result != a.window_graphics_ok or
                    !sameSurface(chain.surface, surface.identity) or (request.chain != 0 and request.chain != chain.id)) continue;
                for (chain.images[0..chain.count], 0..) |item, index| {
                    if (item.phase == .queued and (selected == null or item.order < order)) {
                        selected = chain;
                        slot = @intCast(index);
                        order = item.order;
                    }
                }
            }
            const chain = selected orelse return self.snapshot(surface, a.window_graphics_not_ready);
            const item = &chain.images[slot];
            if (!admitFence(platform, chain, item.ready)) {
                self.invalidate(platform, chain, a.window_graphics_device_lost);
                self.changed();
                return self.snapshot(surface, a.window_graphics_device_lost);
            }
            item.phase = .leased;
            result.frame = frame(chain, slot);
            result.chain = chain.id;
            result.image_slot = slot;
            result.acquire_token = item.token;
        } else {
            const chain = self.findChain(surface.identity, request.chain) orelse return self.snapshot(surface, a.window_graphics_closed);
            if (request.image_slot >= chain.count) return self.snapshot(surface, a.window_graphics_invalid);
            const item = &chain.images[request.image_slot];
            if (item.phase != .leased or item.token != request.acquire_token) return self.snapshot(surface, a.window_graphics_stale);
            if (request.result != a.window_graphics_ok and request.result != a.window_graphics_device_lost and request.result != a.window_graphics_failed)
                return self.snapshot(surface, a.window_graphics_invalid);
            // A failure receipt can release a lease, but must retire the chain;
            // it can never recycle the image as a completed successful frame.
            if (request.result == a.window_graphics_ok and !zeroFence(request.fence) and !admitConsumerFence(platform, request.fence))
                return self.snapshot(surface, a.window_graphics_device_lost);
            item.consumed = request.fence;
            item.phase = .returning;
            if (request.result != a.window_graphics_ok or chain.error_result != a.window_graphics_ok) {
                // Invalidated chains cannot recycle. Drop this returned lease
                // as well; the old invalidate call intentionally retained it.
                self.invalidate(platform, chain, if (request.result != a.window_graphics_ok) request.result else chain.error_result);
                result.flags = a.window_graphics_fence_released;
            } else if (self.retireConsumer(platform, chain, item) != a.window_graphics_not_ready) {
                // Complete (or invalidated) metadata is no longer borrowed.
                // This does not assert physical success for a failed chain.
                result.flags = a.window_graphics_fence_released;
            }
            if (chain.closing) {
                self.closeChain(platform, chain, false);
                result.flags = a.window_graphics_fence_released;
            }
            result.chain = request.chain;
            result.image_slot = request.image_slot;
            result.acquire_token = request.acquire_token;
        }
        self.changed();
        result.revision = self.revision;
        surface.last_consumer = request.*;
        surface.consumer_reply = result;
        return result;
    }

    fn retireCheck(self: *Broker, platform: anytype, chain: *Chain, item: *Image, wait: *a.GfxFence) i32 {
        // Retire the consumer independently of the producer. A compositor
        // must be able to release its job even while producer work is pending.
        const consumer_result = self.retireConsumer(platform, chain, item);
        if (consumer_result < 0) return consumer_result;
        var pending = consumer_result == a.window_graphics_not_ready;
        if (pending) wait.* = item.consumed;
        for ([_]a.GfxFence{item.ready}) |fence| {
            if (zeroFence(fence)) continue;
            var status: a.GfxFenceStatus = .{};
            if (!platform.queryFence(fence, &status) or !validHeader(status) or !std.meta.eql(status.fence, fence) or
                (status.phase == a.gfx_queue_phase_terminal and status.result != a.gfx_queue_result_complete))
            {
                self.invalidate(platform, chain, a.window_graphics_device_lost);
                return a.window_graphics_device_lost;
            }
            if (status.phase != a.gfx_queue_phase_terminal or status.flags & (a.gfx_queue_flag_device_active | a.gfx_queue_flag_resources_held) != 0) {
                wait.* = fence;
                pending = true;
            }
        }
        if (pending) return a.window_graphics_not_ready;
        item.phase = .available;
        return a.window_graphics_ok;
    }
    fn retireConsumer(self: *Broker, platform: anytype, chain: *Chain, item: *Image) i32 {
        if (!zeroFence(item.consumed)) {
            var status: a.GfxFenceStatus = .{};
            if (!platform.queryFence(item.consumed, &status) or !validHeader(status) or !std.meta.eql(status.fence, item.consumed) or
                (status.phase == a.gfx_queue_phase_terminal and status.result != a.gfx_queue_result_complete))
            {
                self.invalidate(platform, chain, a.window_graphics_device_lost);
                return a.window_graphics_device_lost;
            }
            if (status.phase != a.gfx_queue_phase_terminal or status.flags & (a.gfx_queue_flag_device_active | a.gfx_queue_flag_resources_held) != 0)
                return a.window_graphics_not_ready;
        }
        item.consumed = .{};
        item.consumer_released_token = item.token;
        return a.window_graphics_ok;
    }
    fn invalidate(self: *Broker, platform: anytype, chain: *Chain, result: i32) void {
        // Failures can be discovered by Acquire or release_fence, whose error
        // replies do not pass through the successful-mutation revision bump.
        self.changed();
        chain.error_result = result;
        // Already-leased images survive resize/hotplug until explicit return.
        // Other imports can close: resident GPU jobs hold their own pins.
        for (chain.images[0..chain.count]) |*item| {
            if (item.phase != .leased) releaseImage(platform, item);
        }
    }
    fn closeChain(self: *Broker, platform: anytype, chain: *Chain, consumer_gone: bool) void {
        _ = self;
        chain.closing = true;
        chain.error_result = a.window_graphics_closed;
        var outstanding = false;
        for (chain.images[0..chain.count]) |*item| {
            if (item.phase == .leased and !consumer_gone) {
                outstanding = true;
                continue;
            }
            releaseImage(platform, item);
        }
        if (!outstanding) chain.* = .{};
    }
    fn hasChains(self: *Broker, identity: a.WindowGraphicsSurface) bool {
        for (&self.chains) |*chain| if (chain.id != 0 and sameSurface(chain.surface, identity)) return true;
        return false;
    }
    fn removeSurface(self: *Broker, platform: anytype, surface: *Surface, consumer_gone: bool) void {
        surface.removed = true;
        for (&self.chains) |*chain| {
            if (chain.id != 0 and sameSurface(chain.surface, surface.identity)) self.closeChain(platform, chain, consumer_gone);
        }
        self.changed();
    }
    /// Dead app: preserve any Desktop lease. Dead Desktop: its own submitted
    /// work is protected by the kernel's existing BO/queue pin lifecycle.
    pub fn removeOwner(self: *Broker, platform: anytype, owner: a.ProgramProcessHandle) void {
        for (&self.surfaces) |*surface| {
            if (surface.identity.serial == 0) continue;
            const desktop_gone = owners.sameOwner(surface.identity.desktop, owner);
            if ((desktop_gone and (!surface.removed or self.hasChains(surface.identity))) or
                (!surface.removed and owners.sameOwner(surface.identity.owner, owner))) self.removeSurface(platform, surface, desktop_gone);
        }
        for (&self.waiters) |*waiter| if (owners.sameOwner(waiter.request.owner, owner)) {
            waiter.* = .{};
        };
    }
    pub fn clear(self: *Broker, platform: anytype) void {
        for (&self.surfaces) |*surface| {
            if (surface.identity.serial != 0) self.removeSurface(platform, surface, true);
        }
        // Keep identity counters and waiter records: IDs cannot repeat and
        // live waiters must receive the changed/closed result on next drain.
    }
    pub fn participant(self: *const Broker, owner: a.ProgramProcessHandle) bool {
        for (&self.surfaces) |*surface| {
            if (surface.identity.serial != 0 and !surface.removed and
                (owners.sameOwner(surface.identity.owner, owner) or owners.sameOwner(surface.identity.desktop, owner))) return true;
        }
        return false;
    }
    pub fn beginWait(self: *Broker, request_id: u32, request: *const a.WindowGraphicsWait, now: u64) ?a.WindowGraphicsReply {
        if (!validHeader(request.*) or request_id == 0 or request.deadline_tick <= now or request.deadline_tick == std.math.maxInt(u64))
            return self.response(a.window_graphics_invalid);
        if (!self.participant(request.owner)) return self.response(a.window_graphics_closed);
        if (request.known_revision != self.revision) return self.response(a.window_graphics_ok);
        for (&self.waiters) |*waiter| {
            if (waiter.request_id != 0 and owners.sameOwner(waiter.request.owner, request.owner)) return self.response(a.window_graphics_busy);
        }
        for (&self.waiters) |*waiter| if (waiter.request_id == 0) {
            waiter.* = .{ .request_id = request_id, .request = request.* };
            return null;
        };
        return self.response(a.window_graphics_capacity);
    }
    pub fn nextDeadline(self: *const Broker) ?u64 {
        var deadline: ?u64 = null;
        for (&self.waiters) |*waiter| if (waiter.request_id != 0) {
            deadline = if (deadline) |value| @min(value, waiter.request.deadline_tick) else waiter.request.deadline_tick;
        };
        return deadline;
    }
    pub fn takeWaitReply(self: *Broker, now: u64) ?WaitReply {
        for (&self.waiters) |*waiter| {
            if (waiter.request_id == 0) continue;
            const result: i32 = if (!self.participant(waiter.request.owner)) a.window_graphics_closed else if (waiter.request.known_revision != self.revision) a.window_graphics_ok else if (now >= waiter.request.deadline_tick) a.window_graphics_timeout else continue;
            const reply: WaitReply = .{ .request_id = waiter.request_id, .response = self.response(result) };
            waiter.* = .{};
            return reply;
        }
        return null;
    }
};

fn validHeader(value: anytype) bool {
    return value.version == 1 and value.size == @sizeOf(@TypeOf(value));
}
fn sameSurface(left: a.WindowGraphicsSurface, right: a.WindowGraphicsSurface) bool {
    return std.meta.eql(left, right);
}
fn validHandle(value: a.GfxBufferHandle) bool {
    return value.id != 0 and value.generation != 0 and value.reserved0 == 0;
}
fn validFence(value: a.GfxFence) bool {
    return value.slot != 0 and value.timeline != 0 and value.point != 0;
}
fn zeroFence(value: a.GfxFence) bool {
    return std.meta.eql(value, a.GfxFence{});
}
fn validConfig(value: a.WindowGraphicsConfig) bool {
    const binding = value.backend.binding;
    if (!validHeader(value) or value.revision == 0 or value.width == 0 or value.height == 0 or value.reserved != 0 or
        value.flags & ~@as(u32, a.window_graphics_visible) != 0 or value.min_images < 2 or value.min_images > value.max_images or value.max_images > max_images or
        value.present_modes == 0 or value.present_modes & ~@as(u32, a.window_graphics_fifo | a.window_graphics_mailbox) != 0 or
        value.format_count == 0 or value.format_count > value.formats.len or !validHeader(value.backend) or !validHeader(binding) or
        value.display_generation == 0 or value.output.connector_id == 0 or value.output.connection_generation == 0 or
        value.output.device_generation == 0) return false;
    if (binding.device_generation == 0 or binding.reset_generation == 0) return false;
    if (binding.adapter_id == 0 and binding.milestone != a.gfx_queue_milestone_cpu_stores) return false;
    if (binding.adapter_id != 0 and (value.backend.memory_generation == 0 or binding.milestone != a.gfx_queue_milestone_device_execution)) return false;
    // CPU rendering is independent of the physical output adapter. Only a
    // device-local producer must share the output's exact device incarnation.
    if (binding.adapter_id != 0 and (value.output.adapter_id != binding.adapter_id or
        value.output.device_generation != binding.device_generation)) return false;
    for (value.formats[0..value.format_count], 0..) |format, index| {
        if (format.format == 0 or format.reserved != 0) return false;
        for (value.formats[0..index]) |prior| if (std.meta.eql(prior, format)) return false;
    }
    return true;
}
fn validImage(chain: *const Chain, value: a.GfxBufferDescriptor) bool {
    if (!validHeader(value) or value.reserved0 != 0 or value.byte_length == 0 or value.plane_count != 1 or
        value.width != chain.config.width or value.height != chain.config.height or value.format != chain.format.format or
        value.usage & (a.gfx_buffer_usage_render | a.gfx_buffer_usage_transfer_source) != (a.gfx_buffer_usage_render | a.gfx_buffer_usage_transfer_source)) return false;
    if (chain.config.backend.binding.adapter_id == 0) return value.location == a.gfx_buffer_location_system;
    return value.location == a.gfx_buffer_location_device_local and value.adapter_id == chain.config.backend.binding.adapter_id and
        value.device_generation == chain.config.backend.memory_generation;
}
fn admitFence(platform: anytype, chain: *const Chain, fence: a.GfxFence) bool {
    const binding = chain.config.backend.binding;
    if (!validFence(fence) or fence.adapter_id != binding.adapter_id or fence.device_generation != binding.device_generation or
        fence.reset_generation != binding.reset_generation) return false;
    var status: a.GfxFenceStatus = .{};
    return platform.queryFence(fence, &status) and validHeader(status) and std.meta.eql(status.fence, fence) and
        status.milestone == binding.milestone and (status.result == a.gfx_queue_result_pending or status.result == a.gfx_queue_result_complete);
}
fn admitConsumerFence(platform: anytype, fence: a.GfxFence) bool {
    // The final compositor/capture/scanout consumer can use another queue or
    // backend incarnation. In particular a scanout-release fence is not the
    // producer's execution fence. Retain its exact identity and wait for its
    // physical retirement; never rewrite it to the current output binding.
    if (!validFence(fence)) return false;
    var status: a.GfxFenceStatus = .{};
    return platform.queryFence(fence, &status) and validHeader(status) and std.meta.eql(status.fence, fence) and
        status.milestone <= a.gfx_queue_milestone_scanout and
        (status.result == a.gfx_queue_result_pending or status.result == a.gfx_queue_result_complete);
}
fn releaseImage(platform: anytype, item: *Image) void {
    if (item.phase != .vacant) platform.releaseBuffer(item.source.reference);
    item.* = .{};
}
fn frame(chain: *const Chain, slot: u32) a.WindowGraphicsFrame {
    const item = chain.images[slot];
    return .{ .surface = chain.surface, .chain = chain.id, .config_revision = chain.config.revision, .image_slot = slot, .acquire_token = item.token, .present_serial = item.order, .source = item.source, .descriptor = item.descriptor, .format = chain.format, .ready = item.ready };
}

comptime {
    if (@sizeOf(a.WindowGraphicsReply) > a.service_api_max_payload) @compileError("GPU window response exceeds service payload");
    if (@intFromEnum(Phase.returning) != a.window_graphics_image_returning) @compileError("GPU window phase ABI drift");
}

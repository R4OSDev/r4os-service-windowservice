//! Existing R4DRAW BO/queue facade. No image mapping, GPU wait, submission,
//! fence release or display policy belongs in WINSVC.
const r4os = @import("r4os");
const a = r4os.abi;
pub const Platform = struct {
    draw: ?r4os.r4draw.Context = null,
    pub fn importBuffer(self: *const Platform, source: a.GfxBufferHandle, output: *a.GfxBufferReference) bool {
        const draw = self.draw orelse return false;
        return draw.gfxBufferImport(&source, output) == a.gfx_buffer_result_ok;
    }
    pub fn describeBuffer(self: *const Platform, reference: a.GfxBufferHandle, output: *a.GfxBufferDescriptor) bool {
        const draw = self.draw orelse return false;
        return draw.gfxBufferDescribe(&reference, output) == a.gfx_buffer_result_ok;
    }
    pub fn releaseBuffer(self: *const Platform, reference: a.GfxBufferHandle) void {
        const draw = self.draw orelse return;
        _ = draw.gfxBufferRelease(&reference);
    }
    pub fn queryFence(self: *const Platform, fence: a.GfxFence, output: *a.GfxFenceStatus) bool {
        const draw = self.draw orelse return false;
        return draw.gfxFenceQuery(&fence, output) == a.gfx_queue_ok;
    }
};

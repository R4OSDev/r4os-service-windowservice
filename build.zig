const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// `zig build` erzeugt das Modul allein aus diesem Verzeichnis, ohne den Rest
/// von R4OS. Die Datei zeigt nur auf module.R4MF - Name, Klasse, Quellen,
/// Ziel, Imports und Metadaten stehen dort und nirgends sonst.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));

    const tray_broker_module = b.createModule(.{
        .root_source_file = b.path("src/tray_broker.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    tray_broker_module.addImport("r4os", sdk.createR4osModule(b.graph.host, .Debug));
    const tray_broker_tests = b.addTest(.{ .root_module = tray_broker_module });
    const run_tray_broker_tests = b.addRunArtifact(tray_broker_tests);
    const test_step = b.step("test", "Run WINSVC Zig tests");
    test_step.dependOn(&run_tray_broker_tests.step);
}

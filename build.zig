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
    const active_path: std.Build.LazyPath = .{ .cwd_relative = b.pathResolve(&.{ "../../Apps/Desktop/Contract/desktop_check_v2.zig" }) };
    const active_wire = b.createModule(.{ .root_source_file = active_path, .target = b.graph.host });
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{
        .zig_module_roots = &.{ b.path("Contract/desktop_diagnostics_v1.zig"), active_path },
    });

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
    const wire = b.createModule(.{ .root_source_file = b.path("Contract/desktop_diagnostics_v1.zig"), .target = b.graph.host });
    const wire_tests = b.addRunArtifact(b.addTest(.{ .root_module = wire }));
    test_step.dependOn(&wire_tests.step);
    const desktop_step = b.step("desktop-test", "Bounded current Desktop diagnostic contracts and broker queue");
    desktop_step.dependOn(&wire_tests.step);
    const broker_module = b.createModule(.{ .root_source_file = b.path("src/desktop_checks.zig"), .target = b.graph.host });
    broker_module.addImport("desktop_check", active_wire);
    const broker_tests = b.addRunArtifact(b.addTest(.{ .root_module = broker_module }));
    desktop_step.dependOn(&broker_tests.step);
    test_step.dependOn(&broker_tests.step);
}

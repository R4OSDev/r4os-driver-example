const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// Die build.zig zeigt seit 0.61.8 nur noch auf module.R4MF, statt Name,
/// Typ beziehungsweise Rolle und Metadaten ein zweites Mal hinzuschreiben.
/// Damit gibt es hier nichts mehr, was vom Manifest abweichen koennte.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    const libraries_build = b.lazyImport(@This(), "r4os_libraries") orelse return;
    const libraries = b.dependencyFromBuildZig(libraries_build, .{});
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{
        .zig_module_roots = &.{ libraries.namedLazyPath("r4gfx_edid"), libraries.namedLazyPath("r4gfx_outputs") },
    });
}

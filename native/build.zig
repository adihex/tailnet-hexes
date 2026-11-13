const std = @import("std");
const nui_build = @import("nanoui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const portable = b.option(bool, "portable", "Test with NanoUI's portable renderer") orelse false;
    const dependency = b.dependency("nanoui", .{ .target = target, .optimize = optimize, .portable = portable });
    const nanoui = dependency.module("nanoui");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    mod.addAnonymousImport("app_icon", .{
        .root_source_file = b.path(if (target.result.os.tag == .macos) "resources/Hexes.icns" else "resources/icon.png"),
    });
    if (target.result.os.tag == .macos) mod.linkFramework("Security", .{});

    if (target.result.abi.isAndroid()) {
        const lib = nui_build.android.library(b, .{ .name = "hexes", .root_module = mod, .nanoui = nanoui });
        const apk = nui_build.android.apk(b, lib, .{
            .name = "Hexes",
            .id = "net.adihex.hexes",
            .version = "0.1.0",
            .version_code = 4,
            .icon = b.path("resources/icon.png"),
        });
        b.getInstallStep().dependOn(&b.addInstallFile(apk, "android/Hexes.apk").step);
    } else {
        const exe = b.addExecutable(.{ .name = "hexes", .root_module = mod, .use_llvm = true });
        if (target.result.os.tag == .windows) exe.subsystem = .windows;
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step("run", "Run Hexes (opens a window)").dependOn(&run.step);
    }

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    if (target.result.os.tag == .macos) test_mod.linkFramework("Security", .{});
    const tests = b.addTest(.{ .root_module = test_mod, .use_llvm = true });
    if (target.result.abi.isAndroid()) if (nui_build.android.Sdk.find(b)) |sdk| {
        _ = nui_build.android.linkNdk(b, tests, sdk);
    };
    b.step("test", "Run protocol and offscreen interaction tests").dependOn(&b.addRunArtifact(tests).step);
    b.step("test-bin", "Build tests for another machine").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = "hexes-tests" }).step);
}

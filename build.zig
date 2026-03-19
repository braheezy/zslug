const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const freetype_include_candidates = [_][]const u8{
        "/opt/homebrew/opt/freetype/include/freetype2",
        "/usr/local/opt/freetype/include/freetype2",
    };

    const zgpu = b.dependency("zgpu", .{}).module("root");
    const zglfw_dep = b.dependency("zglfw", .{});
    const zmath = b.dependency("zmath", .{}).module("root");
    const zslug_mod = b.addModule("zslug", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (freetype_include_candidates) |path| {
        zslug_mod.addIncludePath(.{ .cwd_relative = path });
    }
    const exe = b.addExecutable(.{
        .name = "zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zgpu", .module = zgpu },
                .{ .name = "zglfw", .module = zglfw_dep.module("root") },
                .{ .name = "zslug", .module = zslug_mod },
                .{ .name = "zmath", .module = zmath },
            },
        }),
    });

    exe.linkLibC();
    exe.linkLibrary(zglfw_dep.artifact("glfw"));
    exe.linkSystemLibrary("freetype");

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const demo_text = b.option([]const u8, "text", "Demo phrase rendered into the Slug scene") orelse "Meow?!";
    const demo_slug_path = b.option([]const u8, "slug-path", "Path to the .slug font file used by the reference backend") orelse "SlugDemo/Fonts/georgia_nc.slug";
    const demo_font_path = b.option([]const u8, "font-path", "Path to the source font file used by the native generator backend") orelse "";
    const runtime_backend = b.option([]const u8, "runtime-backend", "Font runtime backend: slug_reference or native_generator") orelse "native_generator";
    const enable_harfbuzz = b.option(bool, "harfbuzz", "Enable HarfBuzz shaping scaffolding") orelse false;
    const freetype_include_candidates = [_][]const u8{
        "/opt/homebrew/opt/freetype/include/freetype2",
        "/usr/local/opt/freetype/include/freetype2",
    };
    const harfbuzz_include_candidates = [_][]const u8{
        "/opt/homebrew/include/harfbuzz",
        "/usr/local/include/harfbuzz",
    };

    const zgpu = b.dependency("zgpu", .{}).module("root");
    const zglfw_dep = b.dependency("zglfw", .{});
    const zmath = b.dependency("zmath", .{}).module("root");
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "demo_text", demo_text);
    build_options.addOption([]const u8, "demo_slug_path", demo_slug_path);
    build_options.addOption([]const u8, "demo_font_path", demo_font_path);
    build_options.addOption([]const u8, "runtime_backend", runtime_backend);
    build_options.addOption(bool, "enable_harfbuzz", enable_harfbuzz);
    const build_options_mod = build_options.createModule();
    const zslug_mod = b.addModule("zslug", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zslug_mod.addImport("build_options", build_options_mod);
    for (freetype_include_candidates) |path| {
        zslug_mod.addIncludePath(.{ .cwd_relative = path });
    }
    if (enable_harfbuzz) {
        for (harfbuzz_include_candidates) |path| {
            zslug_mod.addIncludePath(.{ .cwd_relative = path });
        }
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
    const parity_report_exe = b.addExecutable(.{
        .name = "parity-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parity_report.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "zslug", .module = zslug_mod },
            },
        }),
    });
    const font_compile_exe = b.addExecutable(.{
        .name = "font-compile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/font_compile.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zslug", .module = zslug_mod },
            },
        }),
    });

    exe.root_module.link_libc = true;
    exe.root_module.linkLibrary(zglfw_dep.artifact("glfw"));
    exe.root_module.linkSystemLibrary("freetype", .{});
    parity_report_exe.root_module.link_libc = true;
    parity_report_exe.root_module.linkSystemLibrary("freetype", .{});
    font_compile_exe.root_module.link_libc = true;
    font_compile_exe.root_module.linkSystemLibrary("freetype", .{});
    if (enable_harfbuzz) {
        exe.root_module.linkSystemLibrary("harfbuzz", .{});
        parity_report_exe.root_module.linkSystemLibrary("harfbuzz", .{});
        font_compile_exe.root_module.linkSystemLibrary("harfbuzz", .{});
    }

    b.installArtifact(exe);
    b.installArtifact(parity_report_exe);
    b.installArtifact(font_compile_exe);

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    for (freetype_include_candidates) |path| {
        lib_tests.root_module.addIncludePath(.{ .cwd_relative = path });
    }
    if (enable_harfbuzz) {
        for (harfbuzz_include_candidates) |path| {
            lib_tests.root_module.addIncludePath(.{ .cwd_relative = path });
        }
    }
    lib_tests.root_module.link_libc = true;
    lib_tests.root_module.linkSystemLibrary("freetype", .{});
    if (enable_harfbuzz) {
        lib_tests.root_module.linkSystemLibrary("harfbuzz", .{});
    }

    const test_step = b.step("test", "Run library tests");
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    const run_step = b.step("run", "Run the app");
    const parity_report_step = b.step("parity-report", "Run the glyph parity report");
    const font_compile_step = b.step("font-compile", "Compile a native font asset");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    const parity_report_cmd = b.addRunArtifact(parity_report_exe);
    parity_report_step.dependOn(&parity_report_cmd.step);
    const font_compile_cmd = b.addRunArtifact(font_compile_exe);
    font_compile_step.dependOn(&font_compile_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    parity_report_cmd.step.dependOn(b.getInstallStep());
    font_compile_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
        parity_report_cmd.addArgs(args);
        font_compile_cmd.addArgs(args);
    }
}

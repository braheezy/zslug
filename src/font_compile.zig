const std = @import("std");
const zslug = @import("zslug");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 3) return usage();
    const font_path = args[1];
    const out_path = args[2];
    const coverage_arg = if (args.len > 3) args[3] else "ascii";

    const coverage: zslug.native_generator.Coverage = if (std.mem.eql(u8, coverage_arg, "ascii"))
        .ascii_basic
    else if (std.mem.eql(u8, coverage_arg, "all"))
        .full_cmap
    else
        return usage();

    var font = try zslug.font_backend.compileNativeFontAsset(allocator, .{
        .font_path = font_path,
        .coverage = coverage,
    });
    defer font.deinit();
    try font.saveToFile(io, out_path);

    var stdout_buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &stdout_buffer);
    try out.interface.print(
        "wrote {s} glyphs={} cmap={} curves={}x{} bands={}x{}\n",
        .{
            out_path,
            font.glyphs.len,
            font.cmap.len,
            font.curves_width,
            font.curves_height,
            font.bands_width,
            font.bands_height,
        },
    );
    try out.interface.flush();
}

fn usage() !void {
    std.debug.print("usage: font-compile <font-path> <out-path> [ascii|all]\n", .{});
    return error.InvalidArguments;
}

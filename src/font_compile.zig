const std = @import("std");
const zslug = @import("zslug");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const font_path = args.next() orelse return usage();
    const out_path = args.next() orelse return usage();
    const coverage_arg = args.next() orelse "ascii";

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
    try font.saveToFile(out_path);

    var stdout_buffer: [1024]u8 = undefined;
    var out = std.fs.File.stdout().writer(&stdout_buffer);
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
    var stderr_buffer: [256]u8 = undefined;
    var err = std.fs.File.stderr().writer(&stderr_buffer);
    try err.interface.writeAll("usage: font-compile <font-path> <out-path> [ascii|all]\n");
    try err.interface.flush();
    return error.InvalidArguments;
}

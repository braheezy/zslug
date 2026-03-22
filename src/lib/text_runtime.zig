const std = @import("std");
const runtime = @import("runtime_font.zig");

pub const GlyphPlacement = struct {
    glyph_index: u32,
    position: [2]f32,
    scale: f32 = 1.0,
    color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

pub const GlyphRun = struct {
    allocator: std.mem.Allocator,
    placements: []GlyphPlacement,

    pub fn deinit(self: *GlyphRun) void {
        self.allocator.free(self.placements);
        self.* = undefined;
    }
};

pub const DrawTextOptions = struct {
    origin: [2]f32 = .{ 0.0, 0.0 },
    scale: f32 = 1.0,
    color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    line_height: f32 = 0.0,
};

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    glyph_count: usize,
};

pub fn buildGlyphRunUtf8(
    allocator: std.mem.Allocator,
    font: runtime.CompiledFont,
    text: []const u8,
    options: DrawTextOptions,
) !GlyphRun {
    var placements = std.ArrayList(GlyphPlacement).empty;
    errdefer placements.deinit(allocator);

    var pen_x: f32 = 0.0;
    var pen_y: f32 = 0.0;
    const line_height = effectiveLineHeight(font, options) * options.scale;

    var view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') {
            pen_x = 0.0;
            pen_y += line_height;
            continue;
        }

        const glyph_index = font.lookupGlyphIndex(codepoint) orelse font.fallbackGlyphIndex() orelse continue;
        const glyph = font.findGlyph(glyph_index) orelse continue;
        try placements.append(allocator, .{
            .glyph_index = glyph_index,
            .position = .{ options.origin[0] + pen_x, options.origin[1] + pen_y },
            .scale = options.scale,
            .color = options.color,
        });
        pen_x += glyph.advance * options.scale;
    }

    return .{
        .allocator = allocator,
        .placements = try placements.toOwnedSlice(allocator),
    };
}

pub fn measureUtf8(font: runtime.CompiledFont, text: []const u8, options: DrawTextOptions) !TextMetrics {
    var pen_x: f32 = 0.0;
    var pen_y: f32 = 0.0;
    var line_width: f32 = 0.0;
    var max_width: f32 = 0.0;
    var glyph_count: usize = 0;
    const line_height = effectiveLineHeight(font, options) * options.scale;

    var view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') {
            max_width = @max(max_width, line_width);
            pen_x = 0.0;
            line_width = 0.0;
            pen_y += line_height;
            continue;
        }

        const glyph_index = font.lookupGlyphIndex(codepoint) orelse font.fallbackGlyphIndex() orelse continue;
        const glyph = font.findGlyph(glyph_index) orelse continue;
        pen_x += glyph.advance * options.scale;
        line_width = pen_x;
        glyph_count += 1;
    }
    max_width = @max(max_width, line_width);

    return .{
        .width = max_width,
        .height = if (glyph_count == 0) 0.0 else pen_y + line_height,
        .glyph_count = glyph_count,
    };
}

fn effectiveLineHeight(font: runtime.CompiledFont, options: DrawTextOptions) f32 {
    if (options.line_height > 0.0) return options.line_height;
    return if (font.line_height > 0.0) font.line_height else 1.0;
}

test "buildGlyphRunUtf8 emits placements with newline handling" {
    const allocator = std.testing.allocator;
    const curves_texels = try allocator.alloc(runtime.CurveTexel, 0);
    defer allocator.free(curves_texels);
    const bands_texels = try allocator.alloc(runtime.BandTexel, 0);
    defer allocator.free(bands_texels);
    const glyphs = try allocator.dupe(runtime.CompiledGlyph, &[_]runtime.CompiledGlyph{
        .{
            .glyph_index = 1,
            .glyph = .{
                .glyph_index = 1,
                .bbox = .{ 0.0, 0.0, 1.0, 1.0 },
                .glyph_offset = .{ 0.0, 0.0 },
                .advance = 2.0,
                .visible = true,
                .band_location = .{ 0, 0 },
                .band_count = .{ 1, 1 },
                .band_scale = .{ 1.0, 1.0 },
                .polygon_count = 4,
                .polygon_points = .{
                    .{ 0.0, 0.0 }, .{ 0.0, 1.0 }, .{ 1.0, 1.0 }, .{ 1.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
                },
            },
        },
    });
    defer allocator.free(glyphs);
    const cmap = try allocator.dupe(runtime.CodepointMapEntry, &[_]runtime.CodepointMapEntry{
        .{ .codepoint = 'A', .glyph_index = 1 },
    });
    defer allocator.free(cmap);

    const font = runtime.CompiledFont{
        .allocator = allocator,
        .units_per_em = 1000,
        .ascender = 0.8,
        .descender = -0.2,
        .line_height = 3.0,
        .curves_width = 0,
        .curves_height = 0,
        .curves_texels = curves_texels,
        .bands_width = 0,
        .bands_height = 0,
        .bands_texels = bands_texels,
        .glyphs = glyphs,
        .cmap = cmap,
    };

    var run = try buildGlyphRunUtf8(allocator, font, "AA\nA", .{});
    defer run.deinit();

    try std.testing.expectEqual(@as(usize, 3), run.placements.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), run.placements[0].position[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), run.placements[1].position[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), run.placements[2].position[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), run.placements[2].position[1], 0.0001);
}

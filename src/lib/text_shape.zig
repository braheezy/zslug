const std = @import("std");
const build_options = @import("build_options");

pub const ShapeBackend = enum {
    simple_utf8,
    harfbuzz,
};

pub const ShapedGlyph = struct {
    codepoint: u32,
    glyph_index: u32 = 0,
    cluster: u32,
    advance: [2]f32 = .{ 0.0, 0.0 },
    offset: [2]f32 = .{ 0.0, 0.0 },
};

pub const ShapeResult = struct {
    allocator: std.mem.Allocator,
    glyphs: []ShapedGlyph,

    pub fn deinit(self: *ShapeResult) void {
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }
};

pub fn defaultBackend() ShapeBackend {
    return if (build_options.enable_harfbuzz) .harfbuzz else .simple_utf8;
}

pub fn shapeUtf8(allocator: std.mem.Allocator, text: []const u8) !ShapeResult {
    return shapeUtf8Simple(allocator, text);
}

pub fn shapeUtf8Simple(allocator: std.mem.Allocator, text: []const u8) !ShapeResult {
    var view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    var glyphs = std.ArrayList(ShapedGlyph).empty;
    errdefer glyphs.deinit(allocator);

    while (iter.nextCodepoint()) |codepoint| {
        try glyphs.append(allocator, .{
            .codepoint = codepoint,
            .cluster = @intCast(glyphs.items.len),
        });
    }

    return .{
        .allocator = allocator,
        .glyphs = try glyphs.toOwnedSlice(allocator),
    };
}

pub fn shapeUtf8HarfBuzzFtFace(
    allocator: std.mem.Allocator,
    ft_face: ?*anyopaque,
    text: []const u8,
) !ShapeResult {
    return harfbuzz_impl.shapeUtf8HarfBuzzFtFace(allocator, ft_face, text);
}

const harfbuzz_impl = if (build_options.enable_harfbuzz) struct {
    const c = @cImport({
        @cInclude("ft2build.h");
        @cInclude("freetype/freetype.h");
        @cInclude("hb.h");
        @cInclude("hb-ft.h");
    });

    pub fn shapeUtf8HarfBuzzFtFace(
        allocator: std.mem.Allocator,
        ft_face_ptr: ?*anyopaque,
        text: []const u8,
    ) !ShapeResult {
        const ft_face: c.FT_Face = @ptrCast(ft_face_ptr orelse return error.MissingFace);
        const hb_font = c.hb_ft_font_create_referenced(ft_face) orelse return error.HarfBuzzCreateFailed;
        defer c.hb_font_destroy(hb_font);
        c.hb_ft_font_set_funcs(hb_font);

        const buffer = c.hb_buffer_create() orelse return error.HarfBuzzCreateFailed;
        defer c.hb_buffer_destroy(buffer);
        c.hb_buffer_add_utf8(buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_guess_segment_properties(buffer);
        c.hb_shape(hb_font, buffer, null, 0);

        var glyph_count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(buffer, &glyph_count) orelse return error.HarfBuzzShapeFailed;
        const positions = c.hb_buffer_get_glyph_positions(buffer, &glyph_count) orelse return error.HarfBuzzShapeFailed;

        const shaped = try allocator.alloc(ShapedGlyph, glyph_count);
        errdefer allocator.free(shaped);
        for (shaped, 0..) |*glyph, i| {
            glyph.* = .{
                .codepoint = 0,
                .glyph_index = infos[i].codepoint,
                .cluster = infos[i].cluster,
                .advance = .{
                    @as(f32, @floatFromInt(positions[i].x_advance)) / 64.0,
                    @as(f32, @floatFromInt(positions[i].y_advance)) / 64.0,
                },
                .offset = .{
                    @as(f32, @floatFromInt(positions[i].x_offset)) / 64.0,
                    @as(f32, @floatFromInt(positions[i].y_offset)) / 64.0,
                },
            };
        }

        return .{
            .allocator = allocator,
            .glyphs = shaped,
        };
    }
} else struct {
    pub fn shapeUtf8HarfBuzzFtFace(
        allocator: std.mem.Allocator,
        ft_face: ?*anyopaque,
        text: []const u8,
    ) !ShapeResult {
        _ = allocator;
        _ = ft_face;
        _ = text;
        return error.HarfBuzzDisabled;
    }
};

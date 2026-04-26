const std = @import("std");
const build_options = @import("build_options");
const font_backend = @import("font_backend.zig");
const runtime = @import("runtime_font.zig");

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
});

pub const texture_width: u32 = 4096;

pub const CurveTexel = runtime.CurveTexel;
pub const BandTexel = runtime.BandTexel;

pub const GlyphInstance = extern struct {
    scale_bias: [4]f32,
    glyph_band_scale: [4]f32,
    band_data: [4]u32,
};

pub const SlugVertex = runtime.SlugVertex;
pub const Scene = runtime.Scene;
const LayoutGlyph = runtime.LayoutGlyph;
const ResolvedPath = struct {
    value: []const u8,
    owned: bool,
};

const Curve = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    x3: f32,
    y3: f32,
    texel_index: u32 = 0,
    first: bool = false,
};

const Point = runtime.Point;

const Glyph = struct {
    codepoint: u32,
    glyph_index: u32,
    width: u32,
    height: u32,
    band_count: u32,
    band_dim_x: u32,
    band_dim_y: u32,
    bands_tex_coord_x: u32,
    bands_tex_coord_y: u32,
    bbox_min: [2]f32,
    advance: f32,
    polygon: []Point,
};

const SlugGlyph = runtime.RuntimeGlyph;

const OutlineBuilder = struct {
    allocator: std.mem.Allocator,
    curves: std.ArrayList(Curve) = .empty,
    contour_starts: std.ArrayList(usize) = .empty,
    bbox_min: [2]f32,
    current: Curve = .{
        .x1 = 0.0,
        .y1 = 0.0,
        .x2 = 0.0,
        .y2 = 0.0,
        .x3 = 0.0,
        .y3 = 0.0,
    },
    failed: bool = false,
    unsupported_cubic: bool = false,
    saw_move: bool = false,

    fn deinit(self: *OutlineBuilder) void {
        self.curves.deinit(self.allocator);
        self.contour_starts.deinit(self.allocator);
    }

    fn moveTo(self: *OutlineBuilder, x: f32, y: f32) void {
        self.contour_starts.append(self.allocator, self.curves.items.len) catch {
            self.failed = true;
            return;
        };
        self.current.first = true;
        self.current.x3 = x - self.bbox_min[0];
        self.current.y3 = y - self.bbox_min[1];
        self.saw_move = true;
    }

    fn lineTo(self: *OutlineBuilder, x: f32, y: f32) void {
        if (!self.saw_move) return;

        var curve = self.current;
        curve.x1 = self.current.x3;
        curve.y1 = self.current.y3;
        curve.x3 = x - self.bbox_min[0];
        curve.y3 = y - self.bbox_min[1];
        curve.x2 = (curve.x1 + curve.x3) * 0.5;
        curve.y2 = (curve.y1 + curve.y3) * 0.5;
        self.curves.append(self.allocator, curve) catch {
            self.failed = true;
            return;
        };
        self.current = curve;
        self.current.first = false;
    }

    fn conicTo(self: *OutlineBuilder, cx: f32, cy: f32, x: f32, y: f32) void {
        if (!self.saw_move) return;

        var curve = self.current;
        curve.x1 = self.current.x3;
        curve.y1 = self.current.y3;
        curve.x2 = cx - self.bbox_min[0];
        curve.y2 = cy - self.bbox_min[1];
        curve.x3 = x - self.bbox_min[0];
        curve.y3 = y - self.bbox_min[1];
        self.curves.append(self.allocator, curve) catch {
            self.failed = true;
            return;
        };
        self.current = curve;
        self.current.first = false;
    }
};

const BuildState = struct {
    allocator: std.mem.Allocator,
    face: c.FT_Face,
    glyphs: std.AutoHashMap(u32, Glyph),
    curves_texture: std.ArrayList(f32) = .empty,
    bands_texture: std.ArrayList(u32) = .empty,
    band_count_limit: u32 = 16,

    fn deinit(self: *BuildState) void {
        var it = self.glyphs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.polygon);
        }
        self.curves_texture.deinit(self.allocator);
        self.bands_texture.deinit(self.allocator);
        self.glyphs.deinit();
    }
};

pub fn buildDemoScene(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    viewport: [2]f32,
) !Scene {
    return buildDemoSceneFromSlug(allocator, io, environ_map, viewport);
}

fn buildDemoSceneFromSlug(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    viewport: [2]f32,
) !Scene {
    const backend = font_backend.defaultBackend();
    const slug_path = if (backend == .slug_reference) try findSlugPath(allocator, io, environ_map) else null;
    defer if (slug_path) |path| allocator.free(path);
    const font_path = if (backend == .native_generator) try findFontPath(allocator, io, environ_map) else null;
    defer if (font_path) |path| if (path.owned) allocator.free(path.value);

    var runtime_font = try font_backend.loadRuntimeFont(allocator, io, .{
        .text = build_options.demo_text,
        .slug_path = slug_path,
        .font_path = if (font_path) |path| path.value else null,
        .backend = backend,
    });
    errdefer runtime_font.deinit();

    const geometry = try buildSlugGeometry(allocator, &runtime_font.glyphs, runtime_font.layout_glyphs, viewport);
    errdefer allocator.free(geometry.vertices);
    errdefer allocator.free(geometry.indices);

    allocator.free(runtime_font.layout_glyphs);
    runtime_font.glyphs.deinit();

    return .{
        .allocator = allocator,
        .curves_width = runtime_font.curves_width,
        .curves_height = runtime_font.curves_height,
        .curves_texels = runtime_font.curves_texels,
        .bands_width = runtime_font.bands_width,
        .bands_height = runtime_font.bands_height,
        .bands_texels = runtime_font.bands_texels,
        .vertices = geometry.vertices,
        .indices = geometry.indices,
    };
}

fn buildFreeTypeDemoScene(allocator: std.mem.Allocator, viewport: [2]f32) !Scene {
    var ft_library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;
    defer _ = c.FT_Done_FreeType(ft_library);

    const font_path = try findFontPath(allocator);
    defer if (font_path.owned) allocator.free(font_path.value);

    const font_path_z = try allocator.dupeZ(u8, font_path.value);
    defer allocator.free(font_path_z);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(ft_library, font_path_z.ptr, 0, &face) != 0) return error.FontOpenFailed;
    defer _ = c.FT_Done_Face(face);

    var state = BuildState{
        .allocator = allocator,
        .face = face,
        .glyphs = std.AutoHashMap(u32, Glyph).init(allocator),
    };
    defer state.deinit();

    var phrase_view = try std.unicode.Utf8View.init(build_options.demo_text);
    var phrase_iter = phrase_view.iterator();
    while (phrase_iter.nextCodepoint()) |codepoint| {
        if (state.glyphs.contains(codepoint)) continue;
        const glyph = try processCodepoint(&state, codepoint);
        try state.glyphs.put(codepoint, glyph);
    }

    const curves_texels, const curves_height = try padCurvesTexture(allocator, state.curves_texture.items);
    const bands_texels, const bands_height = try padBandsTexture(allocator, state.bands_texture.items);
    errdefer allocator.free(curves_texels);
    errdefer allocator.free(bands_texels);

    const geometry = try buildGeometry(allocator, face, &state.glyphs, viewport, build_options.demo_text);
    errdefer allocator.free(geometry.vertices);
    errdefer allocator.free(geometry.indices);

    return .{
        .allocator = allocator,
        .curves_width = texture_width,
        .curves_height = curves_height,
        .curves_texels = curves_texels,
        .bands_width = texture_width,
        .bands_height = bands_height,
        .bands_texels = bands_texels,
        .vertices = geometry.vertices,
        .indices = geometry.indices,
    };
}

fn processCodepoint(state: *BuildState, codepoint: u32) !Glyph {
    const glyph_index = c.FT_Get_Char_Index(state.face, codepoint);
    if (glyph_index == 0) return error.MissingGlyph;

    const load_flags = c.FT_LOAD_NO_SCALE | c.FT_LOAD_NO_BITMAP | c.FT_LOAD_NO_HINTING;
    if (c.FT_Load_Glyph(state.face, glyph_index, load_flags) != 0) return error.GlyphLoadFailed;

    const slot = state.face.*.glyph;
    if (slot == null) return error.GlyphLoadFailed;
    if (slot.*.format != c.FT_GLYPH_FORMAT_OUTLINE) return error.UnsupportedGlyphFormat;
    if (slot.*.outline.n_points == 0) return error.EmptyGlyph;

    const metrics = slot.*.metrics;
    const bbox_min = [2]f32{
        @floatFromInt(metrics.horiBearingX),
        @floatFromInt(metrics.horiBearingY - metrics.height),
    };
    const width_i = metrics.width;
    const height_i = metrics.height;
    if (width_i <= 0 or height_i <= 0) return error.EmptyGlyph;

    var outline_builder = OutlineBuilder{
        .allocator = state.allocator,
        .bbox_min = bbox_min,
    };
    defer outline_builder.deinit();

    var funcs = c.FT_Outline_Funcs{
        .move_to = moveToCallback,
        .line_to = lineToCallback,
        .conic_to = conicToCallback,
        .cubic_to = cubicToCallback,
        .shift = 0,
        .delta = 0,
    };

    if (c.FT_Outline_Decompose(&slot.*.outline, &funcs, &outline_builder) != 0) {
        if (outline_builder.unsupported_cubic) return error.UnsupportedCubicCurve;
        if (outline_builder.failed) return error.OutOfMemory;
        return error.OutlineDecomposeFailed;
    }
    if (outline_builder.unsupported_cubic) return error.UnsupportedCubicCurve;
    if (outline_builder.failed) return error.OutOfMemory;
    if (outline_builder.curves.items.len == 0) return error.EmptyGlyph;

    fixupCurves(outline_builder.curves.items);

    const bands_texel_index = @as(u32, @intCast(state.bands_texture.items.len / 2));
    try appendCurvesTexture(&state.curves_texture, outline_builder.curves.items, state.allocator);

    const width: u32 = @intCast(width_i);
    const height: u32 = @intCast(height_i);
    const size_x = width + 1;
    const size_y = height + 1;

    // For correctness in the demo, use a single full-glyph band in each direction.
    // This disables the band subdivision optimization and avoids missing-curve artifacts
    // caused by our current band builder.
    const band_count: u32 = 1;

    const band_dim_y = divCeil(size_y, band_count);
    const band_dim_x = divCeil(size_x, band_count);
    try appendGlyphBandData(&state.bands_texture, outline_builder.curves.items, band_count, band_dim_x, band_dim_y, state.allocator);

    const polygon = try buildGlyphPolygon(
        state.allocator,
        outline_builder.curves.items,
        outline_builder.contour_starts.items,
        width,
        height,
    );

    return .{
        .codepoint = codepoint,
        .glyph_index = glyph_index,
        .width = width,
        .height = height,
        .band_count = band_count,
        .band_dim_x = band_dim_x,
        .band_dim_y = band_dim_y,
        .bands_tex_coord_x = bands_texel_index % texture_width,
        .bands_tex_coord_y = bands_texel_index / texture_width,
        .bbox_min = bbox_min,
        .advance = @floatFromInt(metrics.horiAdvance),
        .polygon = polygon,
    };
}

fn moveToCallback(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const state: *OutlineBuilder = @ptrCast(@alignCast(user.?));
    state.moveTo(@floatFromInt(to.*.x), @floatFromInt(to.*.y));
    return 0;
}

fn lineToCallback(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const state: *OutlineBuilder = @ptrCast(@alignCast(user.?));
    state.lineTo(@floatFromInt(to.*.x), @floatFromInt(to.*.y));
    return if (state.failed) 1 else 0;
}

fn conicToCallback(control: [*c]const c.FT_Vector, to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const state: *OutlineBuilder = @ptrCast(@alignCast(user.?));
    state.conicTo(
        @floatFromInt(control.*.x),
        @floatFromInt(control.*.y),
        @floatFromInt(to.*.x),
        @floatFromInt(to.*.y),
    );
    return if (state.failed) 1 else 0;
}

fn cubicToCallback(_: [*c]const c.FT_Vector, _: [*c]const c.FT_Vector, _: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const state: *OutlineBuilder = @ptrCast(@alignCast(user.?));
    state.unsupported_cubic = true;
    return 1;
}

fn fixupCurves(curves: []Curve) void {
    for (curves) |*curve| {
        if ((curve.x2 == curve.x1 and curve.y2 == curve.y1) or
            (curve.x2 == curve.x3 and curve.y2 == curve.y3))
        {
            curve.x2 = (curve.x1 + curve.x3) * 0.5;
            curve.y2 = (curve.y1 + curve.y3) * 0.5;
        }
    }
}

fn appendCurvesTexture(buffer: *std.ArrayList(f32), curves: []Curve, allocator: std.mem.Allocator) !void {
    for (curves) |*curve| {
        if (curve.first and buffer.items.len % 4 != 0) {
            const to_add = 4 - (buffer.items.len % 4);
            for (0..to_add) |_| try buffer.append(allocator, -1.0);
        }

        const current_texel = buffer.items.len / 4;
        const new_row = current_texel % texture_width == texture_width - 1;
        if (new_row) {
            const to_add = 8 - (buffer.items.len % 4);
            for (0..to_add) |_| try buffer.append(allocator, -1.0);
        }

        if (curve.first or new_row) {
            curve.texel_index = @intCast(buffer.items.len / 4);
            try buffer.append(allocator, curve.x1);
            try buffer.append(allocator, curve.y1);
        } else {
            curve.texel_index = @intCast((((buffer.items.len / 2) - 1) / 2));
        }

        try buffer.append(allocator, curve.x2);
        try buffer.append(allocator, curve.y2);
        try buffer.append(allocator, curve.x3);
        try buffer.append(allocator, curve.y3);
    }
}

fn appendHorizontalBandHeaders(
    headers: *std.ArrayList(u32),
    curve_pairs: *std.ArrayList(u32),
    curves: []Curve,
    band_count: u32,
    band_dim_y: u32,
    allocator: std.mem.Allocator,
) !void {
    std.mem.sort(Curve, curves, {}, struct {
        fn lessThan(_: void, a: Curve, b: Curve) bool {
            return max3(a.x1, a.x2, a.x3) > max3(b.x1, b.x2, b.x3);
        }
    }.lessThan);

    const f_band_dim_y: f32 = @floatFromInt(band_dim_y);
    var band_min_y: f32 = 0.0;
    var band_max_y: f32 = f_band_dim_y;
    for (0..band_count) |_| {
        const band_texel_offset = @as(u32, @intCast(curve_pairs.items.len / 2));
        var curve_count: u32 = 0;

        for (curves) |curve| {
            if (curve.y1 == curve.y2 and curve.y2 == curve.y3) continue;

            const curve_min_y = min3(curve.y1, curve.y2, curve.y3);
            const curve_max_y = max3(curve.y1, curve.y2, curve.y3);
            if (curve_min_y > band_max_y or curve_max_y < band_min_y) continue;

            try curve_pairs.append(allocator, curve.texel_index % texture_width);
            try curve_pairs.append(allocator, curve.texel_index / texture_width);
            curve_count += 1;
        }

        try headers.append(allocator, curve_count);
        try headers.append(allocator, band_texel_offset);
        band_min_y += f_band_dim_y;
        band_max_y += f_band_dim_y;
    }
}

fn appendVerticalBandHeaders(
    headers: *std.ArrayList(u32),
    curve_pairs: *std.ArrayList(u32),
    curves: []Curve,
    band_count: u32,
    band_dim_x: u32,
    allocator: std.mem.Allocator,
) !void {
    std.mem.sort(Curve, curves, {}, struct {
        fn lessThan(_: void, a: Curve, b: Curve) bool {
            return max3(a.y1, a.y2, a.y3) > max3(b.y1, b.y2, b.y3);
        }
    }.lessThan);

    const f_band_dim_x: f32 = @floatFromInt(band_dim_x);
    var band_min_x: f32 = 0.0;
    var band_max_x: f32 = f_band_dim_x;
    for (0..band_count) |_| {
        const band_texel_offset = @as(u32, @intCast(curve_pairs.items.len / 2));
        var curve_count: u32 = 0;

        for (curves) |curve| {
            if (curve.x1 == curve.x2 and curve.x2 == curve.x3) continue;

            const curve_min_x = min3(curve.x1, curve.x2, curve.x3);
            const curve_max_x = max3(curve.x1, curve.x2, curve.x3);
            if (curve_min_x > band_max_x or curve_max_x < band_min_x) continue;

            try curve_pairs.append(allocator, curve.texel_index % texture_width);
            try curve_pairs.append(allocator, curve.texel_index / texture_width);
            curve_count += 1;
        }

        try headers.append(allocator, curve_count);
        try headers.append(allocator, band_texel_offset);
        band_min_x += f_band_dim_x;
        band_max_x += f_band_dim_x;
    }
}

fn appendGlyphBandData(
    bands_texture: *std.ArrayList(u32),
    curves: []Curve,
    band_count: u32,
    band_dim_x: u32,
    band_dim_y: u32,
    allocator: std.mem.Allocator,
) !void {
    var headers = std.ArrayList(u32).empty;
    defer headers.deinit(allocator);

    var curve_pairs = std.ArrayList(u32).empty;
    defer curve_pairs.deinit(allocator);

    try appendHorizontalBandHeaders(&headers, &curve_pairs, curves, band_count, band_dim_y, allocator);
    try appendVerticalBandHeaders(&headers, &curve_pairs, curves, band_count, band_dim_x, allocator);

    const header_texel_count = @as(u32, @intCast(headers.items.len / 2));
    var i: usize = 1;
    while (i < headers.items.len) : (i += 2) {
        headers.items[i] += header_texel_count;
    }

    try bands_texture.appendSlice(allocator, headers.items);
    try bands_texture.appendSlice(allocator, curve_pairs.items);
}

fn padCurvesTexture(allocator: std.mem.Allocator, floats: []const f32) !struct { []CurveTexel, u32 } {
    if (floats.len == 0) return error.InvalidCurveTexture;

    const remainder = floats.len % 4;
    const used_texels = (floats.len + 3) / 4;
    const height = @max(@as(u32, 1), divCeil(@as(u32, @intCast(used_texels)), texture_width));
    const padded = try allocator.alloc(CurveTexel, height * texture_width);
    @memset(padded, .{ .value = .{ -1.0, -1.0, -1.0, -1.0 } });

    var texel_index: usize = 0;
    while (texel_index < used_texels) : (texel_index += 1) {
        const base = texel_index * 4;
        padded[texel_index] = .{ .value = .{
            if (base + 0 < floats.len) floats[base + 0] else -1.0,
            if (base + 1 < floats.len) floats[base + 1] else -1.0,
            if (base + 2 < floats.len) floats[base + 2] else -1.0,
            if (base + 3 < floats.len) floats[base + 3] else -1.0,
        } };
    }
    _ = remainder;
    return .{ padded, height };
}

fn padBandsTexture(allocator: std.mem.Allocator, entries: []const u32) !struct { []BandTexel, u32 } {
    if (entries.len % 2 != 0) return error.InvalidBandTexture;

    const used_texels = entries.len / 2;
    const height = @max(@as(u32, 1), divCeil(@as(u32, @intCast(used_texels)), texture_width));
    const padded = try allocator.alloc(BandTexel, height * texture_width);
    @memset(padded, .{ .value = .{ 0, 0 } });

    var texel_index: usize = 0;
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        padded[texel_index] = .{ .value = .{ entries[i], entries[i + 1] } };
        texel_index += 1;
    }
    return .{ padded, height };
}

fn buildGeometry(
    allocator: std.mem.Allocator,
    face: c.FT_Face,
    glyphs: *const std.AutoHashMap(u32, Glyph),
    viewport: [2]f32,
    phrase: []const u8,
) !struct { vertices: []SlugVertex, indices: []u32 } {
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);

    var pen_x: f32 = 0.0;
    var prev_glyph_index: u32 = 0;
    var have_prev = false;
    var phrase_view = try std.unicode.Utf8View.init(phrase);
    var phrase_iter = phrase_view.iterator();
    while (phrase_iter.nextCodepoint()) |codepoint| {
        const glyph = glyphs.get(codepoint) orelse continue;
        if (have_prev) pen_x += getKerning(face, prev_glyph_index, glyph.glyph_index);

        const x0 = pen_x + glyph.bbox_min[0];
        const x1 = x0 + @as(f32, @floatFromInt(glyph.width));
        const y0 = glyph.bbox_min[1];
        const y1 = y0 + @as(f32, @floatFromInt(glyph.height));

        min_x = @min(min_x, x0);
        min_y = @min(min_y, y0);
        max_x = @max(max_x, x1);
        max_y = @max(max_y, y1);

        pen_x += glyph.advance;
        prev_glyph_index = glyph.glyph_index;
        have_prev = true;
    }

    const text_width = max_x - min_x;
    const text_height = max_y - min_y;
    if (text_width <= 0.0 or text_height <= 0.0) return error.EmptyLayout;

    const scale = @min(viewport[0] * 0.8 / text_width, viewport[1] * 0.5 / text_height);
    const origin_x = (viewport[0] - text_width * scale) * 0.5 - min_x * scale;
    const origin_y = (viewport[1] - text_height * scale) * 0.5 - min_y * scale;

    var glyph_count: usize = 0;
    phrase_view = try std.unicode.Utf8View.init(phrase);
    phrase_iter = phrase_view.iterator();
    while (phrase_iter.nextCodepoint()) |codepoint| {
        if (glyphs.get(codepoint) != null) glyph_count += 1;
    }

    const vertices = try allocator.alloc(SlugVertex, glyph_count * 4);
    errdefer allocator.free(vertices);
    const indices = try allocator.alloc(u32, glyph_count * 6);
    errdefer allocator.free(indices);
    var vertex_count: usize = 0;
    var index_count: usize = 0;
    pen_x = 0.0;
    prev_glyph_index = 0;
    have_prev = false;
    phrase_view = try std.unicode.Utf8View.init(phrase);
    phrase_iter = phrase_view.iterator();
    while (phrase_iter.nextCodepoint()) |codepoint| {
        const glyph = glyphs.get(codepoint) orelse continue;
        if (have_prev) pen_x += getKerning(face, prev_glyph_index, glyph.glyph_index);

        const x = origin_x + (pen_x + glyph.bbox_min[0]) * scale;
        const y = origin_y + glyph.bbox_min[1] * scale;
        appendGlyphQuad(
            vertices[vertex_count .. vertex_count + 4],
            indices[index_count .. index_count + 6],
            @intCast(vertex_count),
            x,
            y,
            scale,
            glyph,
        );
        vertex_count += 4;
        index_count += 6;
        pen_x += glyph.advance;
        prev_glyph_index = glyph.glyph_index;
        have_prev = true;
    }

    return .{
        .vertices = try allocator.realloc(vertices, vertex_count),
        .indices = try allocator.realloc(indices, index_count),
    };
}

fn appendGlyphQuad(
    vertices: []SlugVertex,
    indices: []u32,
    base_vertex: u32,
    x: f32,
    y: f32,
    scale: f32,
    glyph: Glyph,
) void {
    const packed_glyph_loc = packU16x2(glyph.bands_tex_coord_x, glyph.bands_tex_coord_y);
    const packed_band_max = packU16x2(glyph.band_count - 1, glyph.band_count - 1);
    const inv_scale = 1.0 / scale;
    const jac = [4]f32{ inv_scale, 0.0, 0.0, inv_scale };
    const bnd = [4]f32{
        1.0 / @as(f32, @floatFromInt(glyph.band_dim_x)),
        1.0 / @as(f32, @floatFromInt(glyph.band_dim_y)),
        0.0,
        0.0,
    };
    const col = [4]f32{ 0.97, 0.93, 0.85, 1.0 };
    const glyph_w: f32 = @floatFromInt(glyph.width);
    const glyph_h: f32 = @floatFromInt(glyph.height);

    vertices[0] = .{
        .pos = .{ x, y, -1.0, -1.0 },
        .tex = .{ 0.0, 0.0, packed_glyph_loc, packed_band_max },
        .jac = jac,
        .bnd = bnd,
        .col = col,
    };
    vertices[1] = .{
        .pos = .{ x, y + glyph_h * scale, -1.0, 1.0 },
        .tex = .{ 0.0, glyph_h, packed_glyph_loc, packed_band_max },
        .jac = jac,
        .bnd = bnd,
        .col = col,
    };
    vertices[2] = .{
        .pos = .{ x + glyph_w * scale, y + glyph_h * scale, 1.0, 1.0 },
        .tex = .{ glyph_w, glyph_h, packed_glyph_loc, packed_band_max },
        .jac = jac,
        .bnd = bnd,
        .col = col,
    };
    vertices[3] = .{
        .pos = .{ x + glyph_w * scale, y, 1.0, -1.0 },
        .tex = .{ glyph_w, 0.0, packed_glyph_loc, packed_band_max },
        .jac = jac,
        .bnd = bnd,
        .col = col,
    };

    indices[0] = base_vertex + 0;
    indices[1] = base_vertex + 1;
    indices[2] = base_vertex + 2;
    indices[3] = base_vertex + 0;
    indices[4] = base_vertex + 2;
    indices[5] = base_vertex + 3;
}

fn buildSlugGeometry(
    allocator: std.mem.Allocator,
    glyphs: *const std.AutoHashMap(u32, SlugGlyph),
    layout_glyphs: []const LayoutGlyph,
    viewport: [2]f32,
) !struct { vertices: []SlugVertex, indices: []u32 } {
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);

    var pen_x: f32 = 0.0;
    var glyph_count: usize = 0;
    for (layout_glyphs) |layout_glyph| {
        const glyph = glyphs.get(layout_glyph.glyph_index) orelse continue;
        if (glyph.visible) {
            const x0 = pen_x + layout_glyph.offset[0] + glyph.glyph_offset[0] + glyph.bbox[0];
            const x1 = pen_x + layout_glyph.offset[0] + glyph.glyph_offset[0] + glyph.bbox[2];
            const y0 = layout_glyph.offset[1] + glyph.glyph_offset[1] + glyph.bbox[1];
            const y1 = layout_glyph.offset[1] + glyph.glyph_offset[1] + glyph.bbox[3];

            min_x = @min(min_x, x0);
            min_y = @min(min_y, y0);
            max_x = @max(max_x, x1);
            max_y = @max(max_y, y1);
            glyph_count += 1;
        }
        pen_x += layout_glyph.advance[0];
    }

    const text_width = max_x - min_x;
    const text_height = max_y - min_y;
    if (glyph_count == 0 or text_width <= 0.0 or text_height <= 0.0) return error.EmptyLayout;

    const scale = @min(viewport[0] * 0.8 / text_width, viewport[1] * 0.5 / text_height);
    const origin_x = (viewport[0] - text_width * scale) * 0.5 - min_x * scale;
    const origin_y = (viewport[1] - text_height * scale) * 0.5 - min_y * scale;

    var total_vertex_count: usize = 0;
    var total_index_count: usize = 0;
    for (layout_glyphs) |layout_glyph| {
        const glyph = glyphs.get(layout_glyph.glyph_index) orelse continue;
        if (!glyph.visible) continue;
        const polygon_count = glyphPolygonCount(glyph);
        total_vertex_count += polygon_count;
        total_index_count += (polygon_count - 2) * 3;
    }

    const vertices = try allocator.alloc(SlugVertex, total_vertex_count);
    errdefer allocator.free(vertices);
    const indices = try allocator.alloc(u32, total_index_count);
    errdefer allocator.free(indices);

    var vertex_count: usize = 0;
    var index_count: usize = 0;
    pen_x = 0.0;
    for (layout_glyphs) |layout_glyph| {
        const glyph = glyphs.get(layout_glyph.glyph_index) orelse continue;
        if (glyph.visible) {
            const polygon_count = glyphPolygonCount(glyph);
            appendSlugGlyphPolygon(
                vertices[vertex_count .. vertex_count + polygon_count],
                indices[index_count .. index_count + (polygon_count - 2) * 3],
                @intCast(vertex_count),
                origin_x,
                origin_y,
                pen_x,
                layout_glyph,
                scale,
                glyph,
            );
            vertex_count += polygon_count;
            index_count += (polygon_count - 2) * 3;
        }
        pen_x += layout_glyph.advance[0];
    }

    return .{
        .vertices = try allocator.realloc(vertices, vertex_count),
        .indices = try allocator.realloc(indices, index_count),
    };
}

fn appendSlugGlyphPolygon(
    vertices: []SlugVertex,
    indices: []u32,
    base_vertex: u32,
    origin_x: f32,
    origin_y: f32,
    pen_x: f32,
    layout_glyph: LayoutGlyph,
    scale: f32,
    glyph: SlugGlyph,
) void {
    const packed_glyph_loc = packU16x2(glyph.band_location[0], glyph.band_location[1]);
    const packed_band_max = packU16x2(glyph.band_count[0] - 1, glyph.band_count[1] - 1);
    const inv_scale = 1.0 / scale;
    const jac = [4]f32{ inv_scale, 0.0, 0.0, inv_scale };
    const bnd = [4]f32{
        glyph.band_scale[0],
        glyph.band_scale[1],
        -glyph.bbox[0] * glyph.band_scale[0],
        -glyph.bbox[1] * glyph.band_scale[1],
    };
    const col = [4]f32{ 0.97, 0.93, 0.85, 1.0 };

    const fallback = fallbackSlugQuad(glyph.bbox);
    const polygon = if (glyph.polygon_count >= 3)
        glyph.polygon_points[0..glyph.polygon_count]
    else
        fallback[0..];
    const winding: f32 = if (signedPolygonArea(polygon) >= 0.0) 1.0 else -1.0;
    for (polygon, 0..) |point, i| {
        const prev = polygon[(i + polygon.len - 1) % polygon.len];
        const next = polygon[(i + 1) % polygon.len];
        const normal = polygonVertexNormal(prev, point, next, winding);
        vertices[i] = .{
            .pos = .{
                origin_x + (pen_x + layout_glyph.offset[0] + glyph.glyph_offset[0] + point[0]) * scale,
                origin_y + (layout_glyph.offset[1] + glyph.glyph_offset[1] + point[1]) * scale,
                normal[0],
                normal[1],
            },
            .tex = .{ point[0], point[1], packed_glyph_loc, packed_band_max },
            .jac = jac,
            .bnd = bnd,
            .col = col,
        };
    }

    var index_pos: usize = 0;
    triangulatePolygon(indices, &index_pos, base_vertex, polygon);
}

fn glyphPolygonCount(glyph: SlugGlyph) usize {
    if (glyph.polygon_count >= 3) return glyph.polygon_count;
    return 4;
}

fn fallbackSlugQuad(bbox: [4]f32) [4]Point {
    return .{
        .{ bbox[0], bbox[1] },
        .{ bbox[0], bbox[3] },
        .{ bbox[2], bbox[3] },
        .{ bbox[2], bbox[1] },
    };
}

fn packU16x2(x: u32, y: u32) f32 {
    const packed_bits: u32 = (x & 0xFFFF) | ((y & 0xFFFF) << 16);
    return @bitCast(packed_bits);
}

fn buildGlyphPolygon(
    allocator: std.mem.Allocator,
    curves: []const Curve,
    _: []const usize,
    width: u32,
    height: u32,
) ![]Point {
    if (curves.len == 0) {
        return allocator.dupe(Point, &fallbackQuadPolygon(width, height));
    }

    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);

    const clip_bl = chooseCornerClip(curves, w, h, .bottom_left);
    const clip_tl = chooseCornerClip(curves, w, h, .top_left);
    const clip_tr = chooseCornerClip(curves, w, h, .top_right);
    const clip_br = chooseCornerClip(curves, w, h, .bottom_right);

    var points = std.ArrayList(Point).empty;
    defer points.deinit(allocator);

    try appendSequentialPoint(&points, allocator, if (clip_bl) |clip| clip.edge0 else .{ 0.0, 0.0 });
    if (clip_tl) |clip| {
        try appendSequentialPoint(&points, allocator, clip.edge0);
        try appendSequentialPoint(&points, allocator, clip.edge1);
    } else {
        try appendSequentialPoint(&points, allocator, .{ 0.0, h });
    }
    if (clip_tr) |clip| {
        try appendSequentialPoint(&points, allocator, clip.edge0);
        try appendSequentialPoint(&points, allocator, clip.edge1);
    } else {
        try appendSequentialPoint(&points, allocator, .{ w, h });
    }
    if (clip_br) |clip| {
        try appendSequentialPoint(&points, allocator, clip.edge0);
        try appendSequentialPoint(&points, allocator, clip.edge1);
    } else {
        try appendSequentialPoint(&points, allocator, .{ w, 0.0 });
    }
    if (clip_bl) |clip| {
        try appendSequentialPoint(&points, allocator, clip.edge1);
    }

    if (points.items.len > 1 and pointNear(points.items[0], points.items[points.items.len - 1])) {
        _ = points.pop();
    }
    if (points.items.len < 3 or polygonArea(points.items) < 1.0) {
        return allocator.dupe(Point, &fallbackQuadPolygon(width, height));
    }
    return allocator.dupe(Point, points.items);
}

const Corner = enum {
    bottom_left,
    top_left,
    top_right,
    bottom_right,
};

const CornerClip = struct {
    edge0: Point,
    edge1: Point,
    area: f32,
};

fn chooseCornerClip(curves: []const Curve, width: f32, height: f32, corner: Corner) ?CornerClip {
    const candidates = [_][2]f32{
        .{ 1.0, 4.0 },
        .{ 1.0, 2.0 },
        .{ 1.0, 1.0 },
        .{ 2.0, 1.0 },
        .{ 4.0, 1.0 },
    };

    var best: ?CornerClip = null;
    for (candidates) |pair| {
        const sx: f32 = switch (corner) {
            .bottom_left, .top_left => -1.0,
            .top_right, .bottom_right => 1.0,
        };
        const sy: f32 = switch (corner) {
            .bottom_left, .bottom_right => -1.0,
            .top_left, .top_right => 1.0,
        };
        const normal = Point{ sx * pair[0], sy * pair[1] };
        if (makeCornerClip(curves, width, height, corner, normal)) |clip| {
            if (best == null or clip.area > best.?.area) {
                best = clip;
            }
        }
    }
    return best;
}

fn makeCornerClip(
    curves: []const Curve,
    width: f32,
    height: f32,
    corner: Corner,
    normal: Point,
) ?CornerClip {
    const h = maxControlDot(curves, normal);
    const eps = 1.0e-3;
    switch (corner) {
        .bottom_left => {
            if (h >= -eps) return null;
            const x = h / normal[0];
            const y = h / normal[1];
            if (x <= eps or x >= width - eps or y <= eps or y >= height - eps) return null;
            return .{
                .edge0 = .{ 0.0, y },
                .edge1 = .{ x, 0.0 },
                .area = 0.5 * x * y,
            };
        },
        .top_left => {
            const y = h / normal[1];
            const x = (normal[1] * height - h) / -normal[0];
            if (x <= eps or x >= width - eps or y <= eps or y >= height - eps) return null;
            return .{
                .edge0 = .{ 0.0, y },
                .edge1 = .{ x, height },
                .area = 0.5 * x * (height - y),
            };
        },
        .top_right => {
            const x = (h - normal[1] * height) / normal[0];
            const y = (h - normal[0] * width) / normal[1];
            if (x <= eps or x >= width - eps or y <= eps or y >= height - eps) return null;
            return .{
                .edge0 = .{ x, height },
                .edge1 = .{ width, y },
                .area = 0.5 * (width - x) * (height - y),
            };
        },
        .bottom_right => {
            const x = h / normal[0];
            const y = (h - normal[0] * width) / normal[1];
            if (x <= eps or x >= width - eps or y <= eps or y >= height - eps) return null;
            return .{
                .edge0 = .{ width, y },
                .edge1 = .{ x, 0.0 },
                .area = 0.5 * (width - x) * y,
            };
        },
    }
}

fn maxControlDot(curves: []const Curve, normal: Point) f32 {
    var max_dot = -std.math.inf(f32);
    for (curves) |curve| {
        const p1 = Point{ curve.x1, curve.y1 };
        const p2 = Point{ curve.x2, curve.y2 };
        const p3 = Point{ curve.x3, curve.y3 };
        max_dot = @max(max_dot, dot2(p1, normal));
        max_dot = @max(max_dot, dot2(p2, normal));
        max_dot = @max(max_dot, dot2(p3, normal));
    }
    return max_dot;
}

fn dot2(a: Point, b: Point) f32 {
    return a[0] * b[0] + a[1] * b[1];
}

fn appendSequentialPoint(list: *std.ArrayList(Point), allocator: std.mem.Allocator, point: Point) !void {
    if (list.items.len > 0 and pointNear(list.items[list.items.len - 1], point)) return;
    try list.append(allocator, point);
}

fn pointNear(a: Point, b: Point) bool {
    return @abs(a[0] - b[0]) < 0.01 and @abs(a[1] - b[1]) < 0.01;
}

fn cross(a: Point, b: Point, c_: Point) f32 {
    return (b[0] - a[0]) * (c_[1] - a[1]) - (b[1] - a[1]) * (c_[0] - a[0]);
}

fn quadraticExtremumT(a: f32, b: f32, c_: f32) ?f32 {
    const denom = a - 2.0 * b + c_;
    if (@abs(denom) < 1.0e-4) return null;
    const t = (a - b) / denom;
    if (t <= 0.0 or t >= 1.0) return null;
    return t;
}

fn evalQuadratic(curve: Curve, t: f32) Point {
    const omt = 1.0 - t;
    return .{
        omt * omt * curve.x1 + 2.0 * omt * t * curve.x2 + t * t * curve.x3,
        omt * omt * curve.y1 + 2.0 * omt * t * curve.y2 + t * t * curve.y3,
    };
}

fn fallbackQuadPolygon(width: u32, height: u32) [4]Point {
    return .{
        .{ 0.0, 0.0 },
        .{ 0.0, @floatFromInt(height) },
        .{ @floatFromInt(width), @floatFromInt(height) },
        .{ @floatFromInt(width), 0.0 },
    };
}

fn polygonArea(points: []const Point) f32 {
    return @abs(signedPolygonArea(points)) * 0.5;
}

fn signedPolygonArea(points: []const Point) f32 {
    var area: f32 = 0.0;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        area += p[0] * q[1] - q[0] * p[1];
    }
    return area;
}

fn polygonVertexNormal(prev: Point, current: Point, next: Point, winding: f32) Point {
    const e0 = normalize2(.{ current[0] - prev[0], current[1] - prev[1] });
    const e1 = normalize2(.{ next[0] - current[0], next[1] - current[1] });
    const n0 = Point{ winding * e0[1], -winding * e0[0] };
    const n1 = Point{ winding * e1[1], -winding * e1[0] };
    const sum = Point{ n0[0] + n1[0], n0[1] + n1[1] };
    const len2 = sum[0] * sum[0] + sum[1] * sum[1];
    if (len2 < 1.0e-6) return n1;

    const bisector = normalize2(sum);
    const miter_scale = @max(0.05, bisector[0] * n1[0] + bisector[1] * n1[1]);
    return .{
        bisector[0] / miter_scale,
        bisector[1] / miter_scale,
    };
}

fn triangulatePolygon(indices: []u32, index_pos: *usize, base_vertex: u32, polygon: []const Point) void {
    if (polygon.len < 3) return;
    var i: usize = 1;
    while (i + 1 < polygon.len) : (i += 1) {
        indices[index_pos.* + 0] = base_vertex;
        indices[index_pos.* + 1] = base_vertex + @as(u32, @intCast(i));
        indices[index_pos.* + 2] = base_vertex + @as(u32, @intCast(i + 1));
        index_pos.* += 3;
    }
}

fn normalize2(v: Point) Point {
    const len2 = v[0] * v[0] + v[1] * v[1];
    if (len2 < 1.0e-8) return .{ 0.0, 1.0 };
    const inv_len = 1.0 / @sqrt(len2);
    return .{ v[0] * inv_len, v[1] * inv_len };
}

fn getKerning(face: c.FT_Face, left_glyph: u32, right_glyph: u32) f32 {
    if ((face.*.face_flags & c.FT_FACE_FLAG_KERNING) == 0) return 0.0;

    var vector: c.FT_Vector = .{ .x = 0, .y = 0 };
    if (c.FT_Get_Kerning(face, left_glyph, right_glyph, c.FT_KERNING_UNSCALED, &vector) != 0) {
        return 0.0;
    }
    return @floatFromInt(vector.x);
}

fn findFontPath(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !ResolvedPath {
    if (environ_map.get("ZSLUG_FONT_PATH")) |value| {
        const env_path = try allocator.dupe(u8, value);
        if (canOpenPath(io, env_path)) return .{ .value = env_path, .owned = true };
        allocator.free(env_path);
    }

    if (build_options.demo_font_path.len != 0) {
        const configured_path = build_options.demo_font_path;
        if (canOpenPath(io, configured_path)) return .{ .value = configured_path, .owned = false };
    }

    const candidates = [_][]const u8{
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/NewYork.ttf",
    };
    for (candidates) |candidate| {
        if (canOpenAbsolute(io, candidate)) return .{ .value = candidate, .owned = false };
    }
    return error.NoUsableFontFound;
}

fn findSlugPath(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("ZSLUG_SLUG_PATH")) |value| {
        const env_path = try allocator.dupe(u8, value);
        errdefer allocator.free(env_path);
        const file = std.Io.Dir.cwd().openFile(io, env_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(env_path);
                return error.FileNotFound;
            },
            else => return err,
        };
        file.close(io);
        return env_path;
    }

    const file = std.Io.Dir.cwd().openFile(io, build_options.demo_slug_path, .{}) catch return error.FileNotFound;
    file.close(io);
    return allocator.dupe(u8, build_options.demo_slug_path);
}

fn canOpenAbsolute(io: std.Io, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn canOpenPath(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return canOpenAbsolute(io, path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn divCeil(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

fn min3(a: f32, b: f32, c_: f32) f32 {
    return @min(a, @min(b, c_));
}

fn max3(a: f32, b: f32, c_: f32) f32 {
    return @max(a, @max(b, c_));
}

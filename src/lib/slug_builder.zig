const std = @import("std");

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
});

pub const texture_width: u32 = 4096;
const default_phrase = "Meow?!";

pub const CurveTexel = extern struct {
    value: [4]f32,
};

pub const BandTexel = extern struct {
    value: [2]u32,
};

pub const GlyphInstance = extern struct {
    scale_bias: [4]f32,
    glyph_band_scale: [4]f32,
    band_data: [4]u32,
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    curves_width: u32,
    curves_height: u32,
    curves_texels: []CurveTexel,
    bands_width: u32,
    bands_height: u32,
    bands_texels: []BandTexel,
    instances: []GlyphInstance,

    pub fn deinit(self: *Scene) void {
        self.allocator.free(self.curves_texels);
        self.allocator.free(self.bands_texels);
        self.allocator.free(self.instances);
        self.* = undefined;
    }
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
};

const OutlineBuilder = struct {
    allocator: std.mem.Allocator,
    curves: std.ArrayList(Curve) = .empty,
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
    }

    fn moveTo(self: *OutlineBuilder, x: f32, y: f32) void {
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
        curve.x2 = @floor((curve.x1 + curve.x3) * 0.5);
        curve.y2 = @floor((curve.y1 + curve.y3) * 0.5);
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
    band_headers: std.ArrayList(u32) = .empty,
    curve_offsets: std.ArrayList(u32) = .empty,
    band_count_limit: u32 = 16,

    fn deinit(self: *BuildState) void {
        self.curves_texture.deinit(self.allocator);
        self.band_headers.deinit(self.allocator);
        self.curve_offsets.deinit(self.allocator);
        self.glyphs.deinit();
    }
};

pub fn buildDemoScene(allocator: std.mem.Allocator, viewport: [2]f32) !Scene {
    var ft_library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;
    defer _ = c.FT_Done_FreeType(ft_library);

    const font_path = try findFontPath(allocator);
    defer if (!isStaticPath(font_path)) allocator.free(font_path);

    const font_path_z = try allocator.dupeZ(u8, font_path);
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

    for (default_phrase) |ch| {
        const codepoint: u32 = ch;
        if (state.glyphs.contains(codepoint)) continue;
        const glyph = try processCodepoint(&state, codepoint);
        try state.glyphs.put(codepoint, glyph);
    }

    finalizeBandOffsets(&state);

    const curves_texels, const curves_height = try padCurvesTexture(allocator, state.curves_texture.items);
    const bands_texels, const bands_height = try padBandsTexture(allocator, state.band_headers.items, state.curve_offsets.items);
    errdefer allocator.free(curves_texels);
    errdefer allocator.free(bands_texels);

    const instances = try buildInstances(allocator, face, &state.glyphs, viewport, default_phrase);
    errdefer allocator.free(instances);

    return .{
        .allocator = allocator,
        .curves_width = texture_width,
        .curves_height = curves_height,
        .curves_texels = curves_texels,
        .bands_width = texture_width,
        .bands_height = bands_height,
        .bands_texels = bands_texels,
        .instances = instances,
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

    const bands_texel_index = @as(u32, @intCast(state.band_headers.items.len / 2));
    try appendCurvesTexture(&state.curves_texture, outline_builder.curves.items, state.allocator);

    const width: u32 = @intCast(width_i);
    const height: u32 = @intCast(height_i);
    const size_x = width + 1;
    const size_y = height + 1;

    var band_count = state.band_count_limit;
    if (size_x < band_count or size_y < band_count) {
        band_count = @max(@as(u32, 1), @min(size_x, size_y) / 2);
    }

    const band_dim_y = divCeil(size_y, band_count);
    try appendHorizontalBands(
        &state.band_headers,
        &state.curve_offsets,
        outline_builder.curves.items,
        band_count,
        band_dim_y,
        state.allocator,
    );

    const band_dim_x = divCeil(size_x, band_count);
    try appendVerticalBands(
        &state.band_headers,
        &state.curve_offsets,
        outline_builder.curves.items,
        band_count,
        band_dim_x,
        state.allocator,
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

fn appendHorizontalBands(
    headers: *std.ArrayList(u32),
    offsets: *std.ArrayList(u32),
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
        const band_texel_offset = @as(u32, @intCast(offsets.items.len / 2));
        var curve_count: u32 = 0;

        for (curves) |curve| {
            if (curve.y1 == curve.y2 and curve.y2 == curve.y3) continue;

            const curve_min_y = min3(curve.y1, curve.y2, curve.y3);
            const curve_max_y = max3(curve.y1, curve.y2, curve.y3);
            if (curve_min_y > band_max_y or curve_max_y < band_min_y) continue;

            try offsets.append(allocator, curve.texel_index % texture_width);
            try offsets.append(allocator, curve.texel_index / texture_width);
            curve_count += 1;
        }

        try headers.append(allocator, curve_count);
        try headers.append(allocator, band_texel_offset);
        band_min_y += f_band_dim_y;
        band_max_y += f_band_dim_y;
    }
}

fn appendVerticalBands(
    headers: *std.ArrayList(u32),
    offsets: *std.ArrayList(u32),
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
        const band_texel_offset = @as(u32, @intCast(offsets.items.len / 2));
        var curve_count: u32 = 0;

        for (curves) |curve| {
            if (curve.x1 == curve.x2 and curve.x2 == curve.x3) continue;

            const curve_min_x = min3(curve.x1, curve.x2, curve.x3);
            const curve_max_x = max3(curve.x1, curve.x2, curve.x3);
            if (curve_min_x > band_max_x or curve_max_x < band_min_x) continue;

            try offsets.append(allocator, curve.texel_index % texture_width);
            try offsets.append(allocator, curve.texel_index / texture_width);
            curve_count += 1;
        }

        try headers.append(allocator, curve_count);
        try headers.append(allocator, band_texel_offset);
        band_min_x += f_band_dim_x;
        band_max_x += f_band_dim_x;
    }
}

fn finalizeBandOffsets(state: *BuildState) void {
    const header_texels = @as(u32, @intCast(state.band_headers.items.len / 2));
    var i: usize = 1;
    while (i < state.band_headers.items.len) : (i += 2) {
        state.band_headers.items[i] += header_texels;
    }
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

fn padBandsTexture(allocator: std.mem.Allocator, headers: []const u32, offsets: []const u32) !struct { []BandTexel, u32 } {
    if (headers.len % 2 != 0 or offsets.len % 2 != 0) return error.InvalidBandTexture;

    const used_texels = (headers.len + offsets.len) / 2;
    const height = @max(@as(u32, 1), divCeil(@as(u32, @intCast(used_texels)), texture_width));
    const padded = try allocator.alloc(BandTexel, height * texture_width);
    @memset(padded, .{ .value = .{ 0, 0 } });

    var texel_index: usize = 0;
    var i: usize = 0;
    while (i < headers.len) : (i += 2) {
        padded[texel_index] = .{ .value = .{ headers[i], headers[i + 1] } };
        texel_index += 1;
    }
    i = 0;
    while (i < offsets.len) : (i += 2) {
        padded[texel_index] = .{ .value = .{ offsets[i], offsets[i + 1] } };
        texel_index += 1;
    }
    return .{ padded, height };
}

fn buildInstances(
    allocator: std.mem.Allocator,
    face: c.FT_Face,
    glyphs: *const std.AutoHashMap(u32, Glyph),
    viewport: [2]f32,
    phrase: []const u8,
) ![]GlyphInstance {
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);

    var pen_x: f32 = 0.0;
    var prev_glyph_index: u32 = 0;
    var have_prev = false;
    for (phrase) |ch| {
        const glyph = glyphs.get(ch) orelse continue;
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

    const instances = try allocator.alloc(GlyphInstance, phrase.len);
    var count: usize = 0;
    pen_x = 0.0;
    prev_glyph_index = 0;
    have_prev = false;
    for (phrase) |ch| {
        const glyph = glyphs.get(ch) orelse continue;
        if (have_prev) pen_x += getKerning(face, prev_glyph_index, glyph.glyph_index);

        const x = origin_x + (pen_x + glyph.bbox_min[0]) * scale;
        const y = origin_y + glyph.bbox_min[1] * scale;
        const w = @as(f32, @floatFromInt(glyph.width)) * scale;
        const h = @as(f32, @floatFromInt(glyph.height)) * scale;

        instances[count] = makeInstance(viewport, x, y, w, h, glyph);
        count += 1;
        pen_x += glyph.advance;
        prev_glyph_index = glyph.glyph_index;
        have_prev = true;
    }

    return allocator.realloc(instances, count);
}

fn makeInstance(viewport: [2]f32, x: f32, y: f32, w: f32, h: f32, glyph: Glyph) GlyphInstance {
    const sx = w / viewport[0];
    const sy = h / viewport[1];
    return .{
        .scale_bias = .{
            sx,
            sy,
            2.0 * (x / viewport[0]) - 1.0 + sx,
            2.0 * (y / viewport[1]) - 1.0 + sy,
        },
        .glyph_band_scale = .{
            @floatFromInt(glyph.width),
            @floatFromInt(glyph.height),
            @as(f32, @floatFromInt(glyph.width)) / @as(f32, @floatFromInt(glyph.band_dim_x)),
            @as(f32, @floatFromInt(glyph.height)) / @as(f32, @floatFromInt(glyph.band_dim_y)),
        },
        .band_data = .{
            glyph.band_count - 1,
            glyph.band_count - 1,
            glyph.bands_tex_coord_x,
            glyph.bands_tex_coord_y,
        },
    };
}

fn getKerning(face: c.FT_Face, left_glyph: u32, right_glyph: u32) f32 {
    if ((face.*.face_flags & c.FT_FACE_FLAG_KERNING) == 0) return 0.0;

    var vector: c.FT_Vector = .{ .x = 0, .y = 0 };
    if (c.FT_Get_Kerning(face, left_glyph, right_glyph, c.FT_KERNING_UNSCALED, &vector) != 0) {
        return 0.0;
    }
    return @floatFromInt(vector.x);
}

fn findFontPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "ZSLUG_FONT_PATH")) |env_path| {
        errdefer allocator.free(env_path);
        if (canOpenAbsolute(env_path)) return env_path;
        allocator.free(env_path);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const candidates = [_][]const u8{
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/NewYork.ttf",
    };
    for (candidates) |candidate| {
        if (canOpenAbsolute(candidate)) return candidate;
    }
    return error.NoUsableFontFound;
}

fn canOpenAbsolute(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn isStaticPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/System/Library/Fonts/");
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

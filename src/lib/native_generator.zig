const std = @import("std");
const runtime = @import("runtime_font.zig");
const text_shape = @import("text_shape.zig");

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
});

pub const texture_width: u32 = 4096;

pub const GeneratorConfig = struct {
    text: []const u8,
    font_path: []const u8,
    shape_backend: text_shape.ShapeBackend,
};

pub const Coverage = union(enum) {
    ascii_basic,
    full_cmap,
    codepoints: []const u32,
};

pub const CompileFontConfig = struct {
    font_path: []const u8,
    coverage: Coverage = .ascii_basic,
};

pub const PlannedGlyph = struct {
    glyph: runtime.LayoutGlyph,
};

pub const PlannedRuntimeGlyph = struct {
    codepoint: u32,
    glyph_index: u32,
    runtime_glyph: runtime.RuntimeGlyph,
};

pub const BuildPlan = struct {
    allocator: std.mem.Allocator,
    font_path: []const u8,
    shape_backend: text_shape.ShapeBackend,
    units_per_em: u32,
    ascender: f32,
    descender: f32,
    line_height: f32,
    layout_glyphs: []PlannedGlyph,
    runtime_glyphs: []PlannedRuntimeGlyph,

    pub fn deinit(self: *BuildPlan) void {
        self.allocator.free(self.font_path);
        self.allocator.free(self.layout_glyphs);
        self.allocator.free(self.runtime_glyphs);
        self.* = undefined;
    }
};

pub const RuntimeSkeleton = struct {
    allocator: std.mem.Allocator,
    layout_glyphs: []runtime.LayoutGlyph,
    glyphs: std.AutoHashMap(u32, runtime.RuntimeGlyph),

    pub fn deinit(self: *RuntimeSkeleton) void {
        self.allocator.free(self.layout_glyphs);
        self.glyphs.deinit();
        self.* = undefined;
    }
};

pub const BandAxisHeuristicDebug = struct {
    significant_count: u32,
    feature_bins: u32,
    activity_transition_count: u32,
    max_active_curve_count: u32,
    span_min: f32,
    span_max: f32,
    estimate: f32,
    estimate_count: u32,
    feature_cap: u32,
    aspect_ratio: f32,
    capped: bool,
    band_count: u32,
};

pub const BandHeuristicDebug = struct {
    glyph_index: u32,
    visible: bool,
    width: f32,
    height: f32,
    source_curve_count: usize,
    split_curve_count: usize,
    vertical: BandAxisHeuristicDebug,
    horizontal: BandAxisHeuristicDebug,
};

pub fn makeBuildPlan(allocator: std.mem.Allocator, config: GeneratorConfig) !BuildPlan {
    var ft_library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;
    defer _ = c.FT_Done_FreeType(ft_library);

    const font_path_z = try allocator.dupeZ(u8, config.font_path);
    defer allocator.free(font_path_z);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(ft_library, font_path_z.ptr, 0, &face) != 0) return error.FontOpenFailed;
    defer _ = c.FT_Done_Face(face);

    var shaped = switch (config.shape_backend) {
        .simple_utf8 => try text_shape.shapeUtf8Simple(allocator, config.text),
        .harfbuzz => try text_shape.shapeUtf8HarfBuzzFtFace(allocator, @ptrCast(face), config.text),
    };
    defer shaped.deinit();

    const units_per_em: u32 = if (face.*.units_per_EM > 0) @intCast(face.*.units_per_EM) else 1;
    const layout_glyphs = try allocator.alloc(PlannedGlyph, shaped.glyphs.len);
    errdefer allocator.free(layout_glyphs);
    var runtime_glyphs = std.ArrayList(PlannedRuntimeGlyph).empty;
    defer runtime_glyphs.deinit(allocator);
    var seen_glyphs = std.AutoHashMap(u32, void).init(allocator);
    defer seen_glyphs.deinit();

    for (shaped.glyphs, layout_glyphs) |shape_glyph, *planned| {
        const glyph_index = if (shape_glyph.glyph_index != 0)
            shape_glyph.glyph_index
        else
            c.FT_Get_Char_Index(face, shape_glyph.codepoint);
        if (glyph_index == 0) return error.MissingGlyph;

        if (c.FT_Load_Glyph(face, glyph_index, c.FT_LOAD_NO_SCALE | c.FT_LOAD_NO_HINTING | c.FT_LOAD_NO_BITMAP) != 0) {
            return error.GlyphLoadFailed;
        }

        const slot = face.*.glyph orelse return error.GlyphLoadFailed;
        const metrics = slot.*.metrics;
        const default_advance = [2]f32{
            @as(f32, @floatFromInt(metrics.horiAdvance)) / @as(f32, @floatFromInt(units_per_em)),
            0.0,
        };

        planned.* = .{
            .glyph = .{
                .glyph_index = glyph_index,
                .codepoint = shape_glyph.codepoint,
                .cluster = shape_glyph.cluster,
                .advance = if (shape_glyph.advance[0] != 0.0 or shape_glyph.advance[1] != 0.0) shape_glyph.advance else default_advance,
                .offset = shape_glyph.offset,
            },
        };

        if (!seen_glyphs.contains(glyph_index)) {
            try seen_glyphs.put(glyph_index, {});
            try runtime_glyphs.append(allocator, .{
                .codepoint = shape_glyph.codepoint,
                .glyph_index = glyph_index,
                .runtime_glyph = makeRuntimeGlyph(slot, units_per_em, glyph_index),
            });
        }
    }

    return .{
        .allocator = allocator,
        .font_path = try allocator.dupe(u8, config.font_path),
        .shape_backend = config.shape_backend,
        .units_per_em = units_per_em,
        .ascender = @as(f32, @floatFromInt(face.*.ascender)) / @as(f32, @floatFromInt(units_per_em)),
        .descender = @as(f32, @floatFromInt(face.*.descender)) / @as(f32, @floatFromInt(units_per_em)),
        .line_height = @as(f32, @floatFromInt(face.*.height)) / @as(f32, @floatFromInt(units_per_em)),
        .layout_glyphs = layout_glyphs,
        .runtime_glyphs = try runtime_glyphs.toOwnedSlice(allocator),
    };
}

pub fn buildRuntimeSkeleton(allocator: std.mem.Allocator, build_plan: BuildPlan) !RuntimeSkeleton {
    const layout_glyphs = try allocator.alloc(runtime.LayoutGlyph, build_plan.layout_glyphs.len);
    errdefer allocator.free(layout_glyphs);
    for (build_plan.layout_glyphs, layout_glyphs) |planned, *layout_glyph| {
        layout_glyph.* = planned.glyph;
    }

    var glyphs = std.AutoHashMap(u32, runtime.RuntimeGlyph).init(allocator);
    errdefer glyphs.deinit();
    for (build_plan.runtime_glyphs) |planned| {
        try glyphs.put(planned.glyph_index, planned.runtime_glyph);
    }

    return .{
        .allocator = allocator,
        .layout_glyphs = layout_glyphs,
        .glyphs = glyphs,
    };
}

pub fn buildRuntimeFont(allocator: std.mem.Allocator, config: GeneratorConfig) !runtime.RuntimeFont {
    var ft_library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;
    defer _ = c.FT_Done_FreeType(ft_library);

    const font_path_z = try allocator.dupeZ(u8, config.font_path);
    defer allocator.free(font_path_z);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(ft_library, font_path_z.ptr, 0, &face) != 0) return error.FontOpenFailed;
    defer _ = c.FT_Done_Face(face);

    var shaped = switch (config.shape_backend) {
        .simple_utf8 => try text_shape.shapeUtf8Simple(allocator, config.text),
        .harfbuzz => try text_shape.shapeUtf8HarfBuzzFtFace(allocator, @ptrCast(face), config.text),
    };
    defer shaped.deinit();

    const units_per_em: u32 = if (face.*.units_per_EM > 0) @intCast(face.*.units_per_EM) else 1;

    var glyphs = std.AutoHashMap(u32, runtime.RuntimeGlyph).init(allocator);
    errdefer glyphs.deinit();

    const layout_glyphs = try allocator.alloc(runtime.LayoutGlyph, shaped.glyphs.len);
    errdefer allocator.free(layout_glyphs);

    var curves_texture = std.ArrayList(f32).empty;
    defer curves_texture.deinit(allocator);
    var bands_texture = std.ArrayList(u32).empty;
    defer bands_texture.deinit(allocator);

    for (shaped.glyphs, layout_glyphs) |shape_glyph, *layout_glyph| {
        const glyph_index = if (shape_glyph.glyph_index != 0)
            shape_glyph.glyph_index
        else
            c.FT_Get_Char_Index(face, shape_glyph.codepoint);
        if (glyph_index == 0) return error.MissingGlyph;

        const runtime_glyph = if (glyphs.get(glyph_index)) |existing|
            existing
        else blk: {
            const generated = try generateRuntimeGlyph(allocator, face, units_per_em, glyph_index, &curves_texture, &bands_texture);
            try glyphs.put(glyph_index, generated);
            break :blk generated;
        };

        layout_glyph.* = .{
            .glyph_index = glyph_index,
            .codepoint = shape_glyph.codepoint,
            .cluster = shape_glyph.cluster,
            .advance = if (shape_glyph.advance[0] != 0.0 or shape_glyph.advance[1] != 0.0)
                shape_glyph.advance
            else
                .{ runtime_glyph.advance, 0.0 },
            .offset = shape_glyph.offset,
        };
    }

    const curves_texels, const curves_height = try padCurvesTexture(allocator, curves_texture.items);
    errdefer allocator.free(curves_texels);
    const bands_texels, const bands_height = try padBandsTexture(allocator, bands_texture.items);
    errdefer allocator.free(bands_texels);

    return .{
        .allocator = allocator,
        .curves_width = texture_width,
        .curves_height = curves_height,
        .curves_texels = curves_texels,
        .bands_width = texture_width,
        .bands_height = bands_height,
        .bands_texels = bands_texels,
        .layout_glyphs = layout_glyphs,
        .glyphs = glyphs,
    };
}

pub fn compileFont(allocator: std.mem.Allocator, config: CompileFontConfig) !runtime.CompiledFont {
    var ft_library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;
    defer _ = c.FT_Done_FreeType(ft_library);

    const font_path_z = try allocator.dupeZ(u8, config.font_path);
    defer allocator.free(font_path_z);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(ft_library, font_path_z.ptr, 0, &face) != 0) return error.FontOpenFailed;
    defer _ = c.FT_Done_Face(face);

    const units_per_em: u32 = if (face.*.units_per_EM > 0) @intCast(face.*.units_per_EM) else 1;

    var glyphs = std.ArrayList(runtime.CompiledGlyph).empty;
    defer glyphs.deinit(allocator);
    var cmap = std.ArrayList(runtime.CodepointMapEntry).empty;
    defer cmap.deinit(allocator);
    var seen_glyphs = std.AutoHashMap(u32, void).init(allocator);
    defer seen_glyphs.deinit();

    var curves_texture = std.ArrayList(f32).empty;
    defer curves_texture.deinit(allocator);
    var bands_texture = std.ArrayList(u32).empty;
    defer bands_texture.deinit(allocator);

    switch (config.coverage) {
        .ascii_basic => {
            var codepoint: u32 = 32;
            while (codepoint <= 126) : (codepoint += 1) {
                try appendCompiledCodepoint(
                    allocator,
                    face,
                    units_per_em,
                    codepoint,
                    &glyphs,
                    &cmap,
                    &seen_glyphs,
                    &curves_texture,
                    &bands_texture,
                );
            }
        },
        .codepoints => |codepoints| {
            for (codepoints) |codepoint| {
                try appendCompiledCodepoint(
                    allocator,
                    face,
                    units_per_em,
                    codepoint,
                    &glyphs,
                    &cmap,
                    &seen_glyphs,
                    &curves_texture,
                    &bands_texture,
                );
            }
        },
        .full_cmap => {
            var glyph_index: c.FT_UInt = 0;
            var codepoint = c.FT_Get_First_Char(face, &glyph_index);
            while (glyph_index != 0) {
                try appendCompiledCodepoint(
                    allocator,
                    face,
                    units_per_em,
                    @intCast(codepoint),
                    &glyphs,
                    &cmap,
                    &seen_glyphs,
                    &curves_texture,
                    &bands_texture,
                );
                codepoint = c.FT_Get_Next_Char(face, codepoint, &glyph_index);
            }
        },
    }

    std.mem.sort(runtime.CompiledGlyph, glyphs.items, {}, struct {
        fn lessThan(_: void, lhs: runtime.CompiledGlyph, rhs: runtime.CompiledGlyph) bool {
            return lhs.glyph_index < rhs.glyph_index;
        }
    }.lessThan);
    std.mem.sort(runtime.CodepointMapEntry, cmap.items, {}, struct {
        fn lessThan(_: void, lhs: runtime.CodepointMapEntry, rhs: runtime.CodepointMapEntry) bool {
            return lhs.codepoint < rhs.codepoint;
        }
    }.lessThan);

    const curves_texels, const curves_height = try padCurvesTexture(allocator, curves_texture.items);
    errdefer allocator.free(curves_texels);
    const bands_texels, const bands_height = try padBandsTexture(allocator, bands_texture.items);
    errdefer allocator.free(bands_texels);

    return .{
        .allocator = allocator,
        .units_per_em = units_per_em,
        .ascender = @as(f32, @floatFromInt(face.*.ascender)) / @as(f32, @floatFromInt(units_per_em)),
        .descender = @as(f32, @floatFromInt(face.*.descender)) / @as(f32, @floatFromInt(units_per_em)),
        .line_height = @as(f32, @floatFromInt(face.*.height)) / @as(f32, @floatFromInt(units_per_em)),
        .curves_width = texture_width,
        .curves_height = curves_height,
        .curves_texels = curves_texels,
        .bands_width = texture_width,
        .bands_height = bands_height,
        .bands_texels = bands_texels,
        .glyphs = try glyphs.toOwnedSlice(allocator),
        .cmap = try cmap.toOwnedSlice(allocator),
    };
}

pub fn debugBandHeuristicForGlyph(allocator: std.mem.Allocator, font_path: []const u8, glyph_index: u32) !BandHeuristicDebug {
    var ft_library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;
    defer _ = c.FT_Done_FreeType(ft_library);

    const font_path_z = try allocator.dupeZ(u8, font_path);
    defer allocator.free(font_path_z);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(ft_library, font_path_z.ptr, 0, &face) != 0) return error.FontOpenFailed;
    defer _ = c.FT_Done_Face(face);

    const units_per_em: u32 = if (face.*.units_per_EM > 0) @intCast(face.*.units_per_EM) else 1;
    const em_scale = @as(f32, @floatFromInt(units_per_em));
    const load_flags = c.FT_LOAD_NO_SCALE | c.FT_LOAD_NO_BITMAP | c.FT_LOAD_NO_HINTING;
    if (c.FT_Load_Glyph(face, glyph_index, load_flags) != 0) return error.GlyphLoadFailed;

    const slot = face.*.glyph orelse return error.GlyphLoadFailed;
    const metrics = slot.*.metrics;
    const bbox = [4]f32{
        @as(f32, @floatFromInt(metrics.horiBearingX)) / em_scale,
        @as(f32, @floatFromInt(metrics.horiBearingY - metrics.height)) / em_scale,
        @as(f32, @floatFromInt(metrics.horiBearingX + metrics.width)) / em_scale,
        @as(f32, @floatFromInt(metrics.horiBearingY)) / em_scale,
    };
    const width = @as(f32, @floatFromInt(metrics.width)) / em_scale;
    const height = @as(f32, @floatFromInt(metrics.height)) / em_scale;
    const visible =
        slot.*.format == c.FT_GLYPH_FORMAT_OUTLINE and
        slot.*.outline.n_points > 0 and
        metrics.width > 0 and
        metrics.height > 0;
    if (!visible) {
        return .{
            .glyph_index = glyph_index,
            .visible = false,
            .width = width,
            .height = height,
            .source_curve_count = 0,
            .split_curve_count = 0,
            .vertical = zeroBandAxisHeuristicDebug(),
            .horizontal = zeroBandAxisHeuristicDebug(),
        };
    }

    var outline_builder = OutlineBuilder{
        .allocator = allocator,
        .em_scale = em_scale,
    };
    defer outline_builder.deinit();

    try decomposeOutlineToBuilder(slot, &outline_builder);
    if (outline_builder.curves.items.len == 0) return error.EmptyGlyph;

    const source_curve_count = outline_builder.curves.items.len;
    fixupCurves(outline_builder.curves.items);
    const split_curves = try splitCurvesAtExtrema(allocator, outline_builder.curves.items);
    defer allocator.free(split_curves);

    return .{
        .glyph_index = glyph_index,
        .visible = true,
        .width = width,
        .height = height,
        .source_curve_count = source_curve_count,
        .split_curve_count = split_curves.len,
        .vertical = analyzeBandCountForAxis(split_curves, .x, bbox[0], bbox[1], width, height),
        .horizontal = analyzeBandCountForAxis(split_curves, .y, bbox[0], bbox[1], width, height),
    };
}

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

const OutlineBuilder = struct {
    allocator: std.mem.Allocator,
    curves: std.ArrayList(Curve) = .empty,
    em_scale: f32 = 1.0,
    contour_start: runtime.Point = .{ 0.0, 0.0 },
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
        self.closeContour();
        self.current.first = true;
        self.current.x3 = x;
        self.current.y3 = y;
        self.contour_start = .{ self.current.x3, self.current.y3 };
        self.saw_move = true;
    }

    fn lineTo(self: *OutlineBuilder, x: f32, y: f32) void {
        if (!self.saw_move) return;

        var curve = self.current;
        curve.x1 = self.current.x3;
        curve.y1 = self.current.y3;
        curve.x3 = x;
        curve.y3 = y;
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
        curve.x2 = cx;
        curve.y2 = cy;
        curve.x3 = x;
        curve.y3 = y;
        self.curves.append(self.allocator, curve) catch {
            self.failed = true;
            return;
        };
        self.current = curve;
        self.current.first = false;
    }

    fn closeContour(self: *OutlineBuilder) void {
        if (!self.saw_move) return;
        if (!pointNearEps(
            .{ self.current.x3, self.current.y3 },
            self.contour_start,
            1.0e-4,
        )) {
            self.lineTo(self.contour_start[0], self.contour_start[1]);
        }
        self.saw_move = false;
    }
};

fn makeRuntimeGlyph(slot: c.FT_GlyphSlot, units_per_em: u32, glyph_index: u32) runtime.RuntimeGlyph {
    const em_scale = @as(f32, @floatFromInt(units_per_em));
    const metrics = slot.*.metrics;
    const visible =
        slot.*.format == c.FT_GLYPH_FORMAT_OUTLINE and
        slot.*.outline.n_points > 0 and
        metrics.width > 0 and
        metrics.height > 0;
    const bbox = if (visible)
        [4]f32{
            @as(f32, @floatFromInt(metrics.horiBearingX)) / em_scale,
            @as(f32, @floatFromInt(metrics.horiBearingY - metrics.height)) / em_scale,
            @as(f32, @floatFromInt(metrics.horiBearingX + metrics.width)) / em_scale,
            @as(f32, @floatFromInt(metrics.horiBearingY)) / em_scale,
        }
    else
        [4]f32{ 0.0, 0.0, 0.0, 0.0 };

    var polygon_points: [6]runtime.Point = std.mem.zeroes([6]runtime.Point);
    var polygon_count: u8 = 0;
    if (visible) {
        polygon_points[0] = .{ bbox[0], bbox[1] };
        polygon_points[1] = .{ bbox[0], bbox[3] };
        polygon_points[2] = .{ bbox[2], bbox[3] };
        polygon_points[3] = .{ bbox[2], bbox[1] };
        polygon_count = 4;
    }

    return .{
        .glyph_index = glyph_index,
        .bbox = bbox,
        .glyph_offset = .{ 0.0, 0.0 },
        .advance = @as(f32, @floatFromInt(metrics.horiAdvance)) / em_scale,
        .visible = visible,
        .band_location = .{ 0, 0 },
        .band_count = .{ 0, 0 },
        .band_scale = .{ 0.0, 0.0 },
        .polygon_count = polygon_count,
        .polygon_points = polygon_points,
    };
}

fn generateRuntimeGlyph(
    allocator: std.mem.Allocator,
    face: c.FT_Face,
    units_per_em: u32,
    glyph_index: u32,
    curves_texture: *std.ArrayList(f32),
    bands_texture: *std.ArrayList(u32),
) !runtime.RuntimeGlyph {
    const em_scale = @as(f32, @floatFromInt(units_per_em));
    const load_flags = c.FT_LOAD_NO_SCALE | c.FT_LOAD_NO_BITMAP | c.FT_LOAD_NO_HINTING;
    if (c.FT_Load_Glyph(face, glyph_index, load_flags) != 0) return error.GlyphLoadFailed;

    const slot = face.*.glyph orelse return error.GlyphLoadFailed;
    const metrics = slot.*.metrics;
    const bbox = [4]f32{
        @as(f32, @floatFromInt(metrics.horiBearingX)) / em_scale,
        @as(f32, @floatFromInt(metrics.horiBearingY - metrics.height)) / em_scale,
        @as(f32, @floatFromInt(metrics.horiBearingX + metrics.width)) / em_scale,
        @as(f32, @floatFromInt(metrics.horiBearingY)) / em_scale,
    };
    const width_i = metrics.width;
    const height_i = metrics.height;
    const visible =
        slot.*.format == c.FT_GLYPH_FORMAT_OUTLINE and
        slot.*.outline.n_points > 0 and
        width_i > 0 and
        height_i > 0;
    if (!visible) {
        return .{
            .glyph_index = glyph_index,
            .bbox = .{ 0.0, 0.0, 0.0, 0.0 },
            .glyph_offset = .{ 0.0, 0.0 },
            .advance = @as(f32, @floatFromInt(metrics.horiAdvance)) / em_scale,
            .visible = false,
            .band_location = .{ 0, 0 },
            .band_count = .{ 0, 0 },
            .band_scale = .{ 0.0, 0.0 },
            .polygon_count = 0,
            .polygon_points = std.mem.zeroes([6]runtime.Point),
        };
    }

    var outline_builder = OutlineBuilder{
        .allocator = allocator,
        .em_scale = em_scale,
    };
    defer outline_builder.deinit();

    try decomposeOutlineToBuilder(slot, &outline_builder);
    if (outline_builder.curves.items.len == 0) return error.EmptyGlyph;

    fixupCurves(outline_builder.curves.items);
    const split_curves = try splitCurvesAtExtrema(allocator, outline_builder.curves.items);
    defer allocator.free(split_curves);

    const bands_texel_index = @as(u32, @intCast(bands_texture.items.len / 2));
    try appendCurvesTexture(curves_texture, split_curves, allocator);

    const width = @as(f32, @floatFromInt(width_i)) / em_scale;
    const height = @as(f32, @floatFromInt(height_i)) / em_scale;
    const horizontal_band_count = chooseBandCountForAxis(split_curves, .y, bbox[0], bbox[1], width, height);
    const vertical_band_count = chooseBandCountForAxis(split_curves, .x, bbox[0], bbox[1], width, height);
    const horizontal_band_dim = if (horizontal_band_count > 0) height / @as(f32, @floatFromInt(horizontal_band_count)) else height;
    const vertical_band_dim = if (vertical_band_count > 0) width / @as(f32, @floatFromInt(vertical_band_count)) else width;
    try appendGlyphBandData(
        bands_texture,
        split_curves,
        horizontal_band_count,
        vertical_band_count,
        bbox[0],
        bbox[1],
        vertical_band_dim,
        horizontal_band_dim,
        allocator,
    );

    const polygon = try buildGlyphPolygon(allocator, split_curves, width, height);
    defer allocator.free(polygon);

    var polygon_points = std.mem.zeroes([6]runtime.Point);
    const polygon_count: u8 = @intCast(@min(polygon.len, polygon_points.len));
    for (polygon[0..polygon_count], 0..) |point, i| {
        polygon_points[i] = .{
            point[0] + bbox[0],
            point[1] + bbox[1],
        };
    }

    return .{
        .glyph_index = glyph_index,
        .bbox = bbox,
        .glyph_offset = .{ 0.0, 0.0 },
        .advance = @as(f32, @floatFromInt(metrics.horiAdvance)) / em_scale,
        .visible = true,
        .band_location = .{
            @intCast(bands_texel_index % texture_width),
            @intCast(bands_texel_index / texture_width),
        },
        .band_count = .{ @intCast(vertical_band_count), @intCast(horizontal_band_count) },
        .band_scale = .{
            if (width > 0.0) @as(f32, @floatFromInt(vertical_band_count)) / width else 0.0,
            if (height > 0.0) @as(f32, @floatFromInt(horizontal_band_count)) / height else 0.0,
        },
        .polygon_count = polygon_count,
        .polygon_points = polygon_points,
    };
}

fn moveToCallback(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const state: *OutlineBuilder = @ptrCast(@alignCast(user.?));
    state.moveTo(
        @as(f32, @floatFromInt(to.*.x)) / state.em_scale,
        @as(f32, @floatFromInt(to.*.y)) / state.em_scale,
    );
    return 0;
}

fn lineToCallback(to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const state: *OutlineBuilder = @ptrCast(@alignCast(user.?));
    state.lineTo(
        @as(f32, @floatFromInt(to.*.x)) / state.em_scale,
        @as(f32, @floatFromInt(to.*.y)) / state.em_scale,
    );
    return if (state.failed) 1 else 0;
}

fn conicToCallback(control: [*c]const c.FT_Vector, to: [*c]const c.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const state: *OutlineBuilder = @ptrCast(@alignCast(user.?));
    state.conicTo(
        @as(f32, @floatFromInt(control.*.x)) / state.em_scale,
        @as(f32, @floatFromInt(control.*.y)) / state.em_scale,
        @as(f32, @floatFromInt(to.*.x)) / state.em_scale,
        @as(f32, @floatFromInt(to.*.y)) / state.em_scale,
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

fn splitCurvesAtExtrema(allocator: std.mem.Allocator, curves: []const Curve) ![]Curve {
    var result = std.ArrayList(Curve).empty;
    errdefer result.deinit(allocator);

    for (curves) |curve| {
        var split_ts_buf: [2]f32 = undefined;
        const split_ts = collectCurveExtremaTs(curve, &split_ts_buf);

        var current = curve;
        var prev_t: f32 = 0.0;
        if (split_ts.len == 0) {
            try result.append(allocator, current);
            continue;
        }

        for (split_ts, 0..) |t, split_index| {
            const local_t = (t - prev_t) / (1.0 - prev_t);
            const pair = subdivideCurve(current, local_t);
            var left = pair[0];
            var right = pair[1];
            left.first = current.first and split_index == 0;
            right.first = false;
            try result.append(allocator, left);
            current = right;
            prev_t = t;
        }
        current.first = false;
        try result.append(allocator, current);
    }

    return result.toOwnedSlice(allocator);
}

fn collectCurveExtremaTs(curve: Curve, out: *[2]f32) []const f32 {
    var len: usize = 0;
    maybeAppendSplitT(out, &len, quadraticExtremumT(curve.x1, curve.x2, curve.x3));
    maybeAppendSplitT(out, &len, quadraticExtremumT(curve.y1, curve.y2, curve.y3));
    if (len == 2 and out[0] > out[1]) std.mem.swap(f32, &out[0], &out[1]);
    return out[0..len];
}

fn maybeAppendSplitT(out: *[2]f32, len: *usize, t_opt: ?f32) void {
    const t = t_opt orelse return;
    for (out[0..len.*]) |existing| {
        if (@abs(existing - t) < 1.0e-5) return;
    }
    out[len.*] = t;
    len.* += 1;
}

fn quadraticExtremumT(p0: f32, p1: f32, p2: f32) ?f32 {
    const denom = p0 - 2.0 * p1 + p2;
    if (@abs(denom) < 1.0e-6) return null;
    const t = (p0 - p1) / denom;
    if (t <= 1.0e-4 or t >= 1.0 - 1.0e-4) return null;
    return t;
}

fn subdivideCurve(curve: Curve, t: f32) [2]Curve {
    const p0 = runtime.Point{ curve.x1, curve.y1 };
    const p1 = runtime.Point{ curve.x2, curve.y2 };
    const p2 = runtime.Point{ curve.x3, curve.y3 };
    const q0 = lerpPoint(p0, p1, t);
    const q1 = lerpPoint(p1, p2, t);
    const r = lerpPoint(q0, q1, t);
    return .{
        .{
            .x1 = p0[0],
            .y1 = p0[1],
            .x2 = q0[0],
            .y2 = q0[1],
            .x3 = r[0],
            .y3 = r[1],
            .first = curve.first,
        },
        .{
            .x1 = r[0],
            .y1 = r[1],
            .x2 = q1[0],
            .y2 = q1[1],
            .x3 = p2[0],
            .y3 = p2[1],
            .first = false,
        },
    };
}

fn lerpPoint(a: runtime.Point, b: runtime.Point, t: f32) runtime.Point {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
    };
}

fn appendHorizontalBandHeaders(
    headers: *std.ArrayList(u32),
    curve_pairs: *std.ArrayList(u32),
    curves: []Curve,
    band_count: u32,
    band_min_origin_y: f32,
    band_dim_y: f32,
    allocator: std.mem.Allocator,
) !void {
    std.mem.sort(Curve, curves, {}, struct {
        fn lessThan(_: void, a: Curve, b: Curve) bool {
            return max3(a.x1, a.x2, a.x3) > max3(b.x1, b.x2, b.x3);
        }
    }.lessThan);

    var band_min_y: f32 = band_min_origin_y;
    var band_max_y: f32 = band_min_origin_y + band_dim_y;
    for (0..band_count) |_| {
        const band_texel_offset = @as(u32, @intCast(curve_pairs.items.len / 2));
        var curve_count: u32 = 0;

        for (curves) |curve| {
            if (curve.y1 == curve.y2 and curve.y2 == curve.y3) continue;

            const curve_min_y = min3(curve.y1, curve.y2, curve.y3);
            const curve_max_y = max3(curve.y1, curve.y2, curve.y3);
            if (curve_min_y > band_max_y + band_overlap_epsilon_em or curve_max_y < band_min_y - band_overlap_epsilon_em) continue;

            try curve_pairs.append(allocator, curve.texel_index % texture_width);
            try curve_pairs.append(allocator, curve.texel_index / texture_width);
            curve_count += 1;
        }

        try headers.append(allocator, curve_count);
        try headers.append(allocator, band_texel_offset);
        band_min_y += band_dim_y;
        band_max_y += band_dim_y;
    }
}

fn appendVerticalBandHeaders(
    headers: *std.ArrayList(u32),
    curve_pairs: *std.ArrayList(u32),
    curves: []Curve,
    band_count: u32,
    band_min_origin_x: f32,
    band_dim_x: f32,
    allocator: std.mem.Allocator,
) !void {
    std.mem.sort(Curve, curves, {}, struct {
        fn lessThan(_: void, a: Curve, b: Curve) bool {
            return max3(a.y1, a.y2, a.y3) > max3(b.y1, b.y2, b.y3);
        }
    }.lessThan);

    var band_min_x: f32 = band_min_origin_x;
    var band_max_x: f32 = band_min_origin_x + band_dim_x;
    for (0..band_count) |_| {
        const band_texel_offset = @as(u32, @intCast(curve_pairs.items.len / 2));
        var curve_count: u32 = 0;

        for (curves) |curve| {
            if (curve.x1 == curve.x2 and curve.x2 == curve.x3) continue;

            const curve_min_x = min3(curve.x1, curve.x2, curve.x3);
            const curve_max_x = max3(curve.x1, curve.x2, curve.x3);
            if (curve_min_x > band_max_x + band_overlap_epsilon_em or curve_max_x < band_min_x - band_overlap_epsilon_em) continue;

            try curve_pairs.append(allocator, curve.texel_index % texture_width);
            try curve_pairs.append(allocator, curve.texel_index / texture_width);
            curve_count += 1;
        }

        try headers.append(allocator, curve_count);
        try headers.append(allocator, band_texel_offset);
        band_min_x += band_dim_x;
        band_max_x += band_dim_x;
    }
}

fn appendGlyphBandData(
    bands_texture: *std.ArrayList(u32),
    curves: []Curve,
    horizontal_band_count: u32,
    vertical_band_count: u32,
    band_origin_x: f32,
    band_origin_y: f32,
    band_dim_x: f32,
    band_dim_y: f32,
    allocator: std.mem.Allocator,
) !void {
    var headers = std.ArrayList(u32).empty;
    defer headers.deinit(allocator);

    var curve_pairs = std.ArrayList(u32).empty;
    defer curve_pairs.deinit(allocator);

    try appendHorizontalBandHeaders(&headers, &curve_pairs, curves, horizontal_band_count, band_origin_y, band_dim_y, allocator);
    try appendVerticalBandHeaders(&headers, &curve_pairs, curves, vertical_band_count, band_origin_x, band_dim_x, allocator);

    const header_texel_count = @as(u32, @intCast(headers.items.len / 2));
    var i: usize = 1;
    while (i < headers.items.len) : (i += 2) {
        headers.items[i] += header_texel_count;
    }

    try bands_texture.appendSlice(allocator, headers.items);
    try bands_texture.appendSlice(allocator, curve_pairs.items);
}

fn buildGlyphPolygon(
    allocator: std.mem.Allocator,
    curves: []const Curve,
    width: f32,
    height: f32,
) ![]runtime.Point {
    if (curves.len == 0) {
        return allocator.dupe(runtime.Point, &fallbackQuadPolygon(width, height));
    }

    const w = width;
    const h = height;

    const clip_bl = chooseCornerClip(curves, w, h, .bottom_left);
    const clip_tl = chooseCornerClip(curves, w, h, .top_left);
    const clip_tr = chooseCornerClip(curves, w, h, .top_right);
    const clip_br = chooseCornerClip(curves, w, h, .bottom_right);

    var points = std.ArrayList(runtime.Point).empty;
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
        return allocator.dupe(runtime.Point, &fallbackQuadPolygon(width, height));
    }
    return allocator.dupe(runtime.Point, points.items);
}

const Corner = enum {
    bottom_left,
    top_left,
    top_right,
    bottom_right,
};

const CornerClip = struct {
    edge0: runtime.Point,
    edge1: runtime.Point,
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
        const normal = runtime.Point{ sx * pair[0], sy * pair[1] };
        if (makeCornerClip(curves, width, height, corner, normal)) |clip| {
            if (best == null or clip.area > best.?.area) best = clip;
        }
    }
    return best;
}

fn makeCornerClip(
    curves: []const Curve,
    width: f32,
    height: f32,
    corner: Corner,
    normal: runtime.Point,
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

fn maxControlDot(curves: []const Curve, normal: runtime.Point) f32 {
    var max_dot = -std.math.inf(f32);
    for (curves) |curve| {
        max_dot = @max(max_dot, dot2(.{ curve.x1, curve.y1 }, normal));
        max_dot = @max(max_dot, dot2(.{ curve.x2, curve.y2 }, normal));
        max_dot = @max(max_dot, dot2(.{ curve.x3, curve.y3 }, normal));
    }
    return max_dot;
}

fn dot2(a: runtime.Point, b: runtime.Point) f32 {
    return a[0] * b[0] + a[1] * b[1];
}

fn appendSequentialPoint(list: *std.ArrayList(runtime.Point), allocator: std.mem.Allocator, point: runtime.Point) !void {
    if (list.items.len > 0 and pointNear(list.items[list.items.len - 1], point)) return;
    try list.append(allocator, point);
}

fn pointNear(a: runtime.Point, b: runtime.Point) bool {
    return pointNearEps(a, b, 0.01);
}

fn pointNearEps(a: runtime.Point, b: runtime.Point, eps: f32) bool {
    return @abs(a[0] - b[0]) < eps and @abs(a[1] - b[1]) < eps;
}

fn fallbackQuadPolygon(width: f32, height: f32) [4]runtime.Point {
    return .{
        .{ 0.0, 0.0 },
        .{ 0.0, height },
        .{ width, height },
        .{ width, 0.0 },
    };
}

const Axis = enum { x, y };
const band_overlap_epsilon_em: f32 = 1.0 / 1024.0;

fn chooseBandCountForAxis(
    curves: []const Curve,
    axis: Axis,
    band_origin_x: f32,
    band_origin_y: f32,
    width: f32,
    height: f32,
) u32 {
    return analyzeBandCountForAxis(curves, axis, band_origin_x, band_origin_y, width, height).band_count;
}

fn analyzeBandCountForAxis(
    curves: []const Curve,
    axis: Axis,
    band_origin_x: f32,
    band_origin_y: f32,
    width: f32,
    height: f32,
) BandAxisHeuristicDebug {
    const primary_dim = switch (axis) {
        .x => width,
        .y => height,
    };
    const cross_dim = switch (axis) {
        .x => height,
        .y => width,
    };
    const band_origin = switch (axis) {
        .x => band_origin_x,
        .y => band_origin_y,
    };
    const sig_x = countSignificantCurvesForAxis(curves, .x, width);
    const sig_y = countSignificantCurvesForAxis(curves, .y, height);
    const significant_count = switch (axis) {
        .x => sig_x,
        .y => sig_y,
    };
    const other_significant_count = switch (axis) {
        .x => sig_y,
        .y => sig_x,
    };
    const estimate = switch (axis) {
        .x => @as(f32, @floatFromInt(sig_x)) * 2.5 + @as(f32, @floatFromInt(sig_y)) * 0.6,
        .y => @as(f32, @floatFromInt(sig_y)) * 1.5 + @as(f32, @floatFromInt(sig_x)) * 0.8,
    };
    const feature_bins = countDistinctCurveExtentBinsForAxis(curves, axis, primary_dim);
    const activity = analyzeCurveActivityForAxis(curves, axis, primary_dim);
    const significant_span = findSignificantCurveSpanForAxis(curves, axis, primary_dim);
    const span_min = if (significant_span) |span| span.min else 0.0;
    const span_max = if (significant_span) |span| span.max else 0.0;
    const tight_feature_cap: u32 = @min(@as(u32, 32), feature_bins * 4 + 2);
    const loose_feature_cap: u32 = @min(@as(u32, 32), feature_bins * 5 - 1);
    var feature_cap: u32 = if (significant_count <= other_significant_count)
        tight_feature_cap
    else
        loose_feature_cap;
    const estimate_count: u32 = @intFromFloat(@max(1.0, @min(@ceil(estimate), 32.0)));
    const aspect_ratio = if (primary_dim > 0.0 and cross_dim > 0.0)
        @max(primary_dim / cross_dim, cross_dim / primary_dim)
    else
        std.math.inf(f32);
    const stacked_high_curve_axis =
        significant_count >= 12 and
        aspect_ratio <= 1.5;
    if (stacked_high_curve_axis) {
        const should_apply_activity_cap =
            significant_count <= other_significant_count or
            activity.activity_transition_count <= 4;
        if (should_apply_activity_cap) {
            const dominant_axis_bonus: u32 = if (
                activity.activity_transition_count <= 4 and
                significant_count > other_significant_count
            )
                3
            else
                0;
            const activity_cap = @min(
                @as(u32, 32),
                activity.activity_transition_count + activity.max_active_curve_count * 2 + 2 + dominant_axis_bonus,
            );
            feature_cap = @min(feature_cap, activity_cap);
        }
        const bowl_stem_secondary_axis =
            axis == .y and
            aspect_ratio >= 1.2 and
            aspect_ratio <= 1.5 and
            other_significant_count >= 16 and
            significant_count >= 12 and
            other_significant_count >= significant_count + 2 and
            activity.activity_transition_count >= 4 and
            activity.activity_transition_count <= 8 and
            activity.max_active_curve_count <= 4;
        if (bowl_stem_secondary_axis) {
            const bowl_stem_secondary_cap = @min(
                @as(u32, 32),
                activity.activity_transition_count + activity.max_active_curve_count * 3 + 8,
            );
            feature_cap = @max(feature_cap, bowl_stem_secondary_cap);
        }
        const descender_bowl_secondary_axis =
            axis == .y and
            aspect_ratio >= 1.25 and
            aspect_ratio <= 1.45 and
            significant_count >= 10 and
            significant_count <= 14 and
            other_significant_count >= significant_count + 2 and
            activity.activity_transition_count >= 4 and
            activity.activity_transition_count <= 6 and
            activity.max_active_curve_count <= 4 and
            span_min < -primary_dim * 0.08 and
            span_max <= primary_dim * 0.78;
        if (descender_bowl_secondary_axis) {
            feature_cap = if (feature_cap < estimate_count) estimate_count else feature_cap;
        }
        const secondary_loop_axis =
            aspect_ratio <= 1.15 and
            other_significant_count >= significant_count + 3 and
            activity.activity_transition_count <= 6 and
            activity.max_active_curve_count <= 4;
        if (secondary_loop_axis) {
            const secondary_loop_cap = @min(
                @as(u32, 32),
                activity.activity_transition_count + activity.max_active_curve_count + 2,
            );
            feature_cap = @min(feature_cap, secondary_loop_cap);
        }
        const distributed_secondary_axis =
            aspect_ratio <= 1.25 and
            significant_count <= other_significant_count and
            other_significant_count <= significant_count + 2 and
            activity.activity_transition_count >= 7 and
            activity.max_active_curve_count <= 4;
        if (distributed_secondary_axis) {
            const distributed_secondary_cap = @min(
                @as(u32, 32),
                activity.activity_transition_count + activity.max_active_curve_count + 2,
            );
            feature_cap = @min(feature_cap, distributed_secondary_cap);
        }
    }
    const compact_descender_bowl_secondary_axis =
        axis == .y and
        aspect_ratio >= 1.25 and
        aspect_ratio <= 1.45 and
        significant_count >= 10 and
        significant_count <= 12 and
        feature_bins <= 5 and
        other_significant_count >= significant_count + 6 and
        activity.activity_transition_count >= 4 and
        activity.activity_transition_count <= 6 and
        activity.max_active_curve_count <= 4 and
        span_min < -primary_dim * 0.08;
    if (compact_descender_bowl_secondary_axis) {
        feature_cap = if (feature_cap < estimate_count) estimate_count else feature_cap;
    }
    const bowl_stem_dominant_axis =
        axis == .x and
        aspect_ratio >= 1.2 and
        aspect_ratio <= 1.5 and
        significant_count >= 16 and
        other_significant_count >= 11 and
        significant_count >= other_significant_count + 2 and
        activity.activity_transition_count >= 5 and
        activity.activity_transition_count <= 8 and
        activity.max_active_curve_count <= 6;
    if (bowl_stem_dominant_axis) {
        const bowl_stem_dominant_cap = @min(
            @as(u32, 32),
            @max(@as(u32, 20), activity.activity_transition_count + activity.max_active_curve_count + 9),
        );
        feature_cap = @min(feature_cap, bowl_stem_dominant_cap);
    }
    const tail_bowl_secondary_axis =
        axis == .y and
        aspect_ratio >= 1.25 and
        aspect_ratio <= 1.45 and
        significant_count >= 18 and
        other_significant_count >= significant_count + 2 and
        activity.activity_transition_count >= 4 and
        activity.activity_transition_count <= 6 and
        activity.max_active_curve_count <= 4;
    if (tail_bowl_secondary_axis) {
        const tail_bowl_secondary_cap = @min(
            @as(u32, 32),
            activity.activity_transition_count + activity.max_active_curve_count * 2 + 7,
        );
        feature_cap = @min(feature_cap, tail_bowl_secondary_cap);
    }
    const tall_complex_axis =
        significant_count >= 12 and
        aspect_ratio > 1.5 and
        activity.activity_transition_count >= 5;
    if (tall_complex_axis) {
        const tall_activity_cap = @min(@as(u32, 32), activity.activity_transition_count + activity.max_active_curve_count * 2 + 4);
        feature_cap = @min(feature_cap, tall_activity_cap);
    }
    const capped = aspect_ratio <= 1.5 or feature_bins <= 3 or tall_complex_axis;
    const heuristic_band_count = if (capped)
        @max(@as(u32, 1), @min(estimate_count, feature_cap))
    else
        estimate_count;
    const band_count = chooseOptimalBandCount(curves, axis, band_origin, primary_dim, heuristic_band_count);
    return .{
        .significant_count = significant_count,
        .feature_bins = feature_bins,
        .activity_transition_count = activity.activity_transition_count,
        .max_active_curve_count = activity.max_active_curve_count,
        .span_min = span_min,
        .span_max = span_max,
        .estimate = estimate,
        .estimate_count = estimate_count,
        .feature_cap = feature_cap,
        .aspect_ratio = aspect_ratio,
        .capped = capped,
        .band_count = band_count,
    };
}

const BandCountScore = struct {
    band_count: u32,
    max_curve_count: u32,
    total_curve_refs: u32,
};

fn chooseOptimalBandCount(
    curves: []const Curve,
    axis: Axis,
    band_origin: f32,
    primary_dim: f32,
    heuristic_band_count: u32,
) u32 {
    if (curves.len == 0 or primary_dim <= 0.0) return @max(@as(u32, 1), heuristic_band_count);

    const target = std.math.clamp(heuristic_band_count, @as(u32, 1), @as(u32, 32));
    const search_radius: u32 = 6;
    const candidate_min = if (target > search_radius) target - search_radius else 1;
    const candidate_max = @min(@as(u32, 32), target + search_radius);

    var best = scoreBandCountCandidate(curves, axis, band_origin, primary_dim, target);
    var candidate = candidate_min;
    while (candidate <= candidate_max) : (candidate += 1) {
        if (candidate == target) continue;
        const score = scoreBandCountCandidate(curves, axis, band_origin, primary_dim, candidate);
        if (bandCountScoreLessThan(score, best, target)) best = score;
    }
    return best.band_count;
}

fn scoreBandCountCandidate(
    curves: []const Curve,
    axis: Axis,
    band_origin: f32,
    primary_dim: f32,
    band_count: u32,
) BandCountScore {
    const band_dim = primary_dim / @as(f32, @floatFromInt(band_count));
    var max_curve_count: u32 = 0;
    var total_curve_refs: u32 = 0;
    var band_min = band_origin;
    var band_max = band_origin + band_dim;

    var i: u32 = 0;
    while (i < band_count) : (i += 1) {
        const curve_count = countCurvesOverlappingBand(curves, axis, band_min, band_max);
        max_curve_count = @max(max_curve_count, curve_count);
        total_curve_refs += curve_count;
        band_min += band_dim;
        band_max += band_dim;
    }

    return .{
        .band_count = band_count,
        .max_curve_count = max_curve_count,
        .total_curve_refs = total_curve_refs,
    };
}

fn bandCountScoreLessThan(a: BandCountScore, b: BandCountScore, target: u32) bool {
    if (a.max_curve_count != b.max_curve_count) return a.max_curve_count < b.max_curve_count;
    const a_distance = absDiffU32(a.band_count, target);
    const b_distance = absDiffU32(b.band_count, target);
    if (a_distance != b_distance) return a_distance < b_distance;
    if (a.total_curve_refs != b.total_curve_refs) return a.total_curve_refs < b.total_curve_refs;
    return a.band_count < b.band_count;
}

fn absDiffU32(a: u32, b: u32) u32 {
    return if (a >= b) a - b else b - a;
}

fn countCurvesOverlappingBand(
    curves: []const Curve,
    axis: Axis,
    band_min: f32,
    band_max: f32,
) u32 {
    var count: u32 = 0;
    for (curves) |curve| {
        if (curveIsExcludedFromBands(curve, axis)) continue;

        const curve_min = curveAxisMin(curve, axis);
        const curve_max = curveAxisMax(curve, axis);
        if (curve_min > band_max + band_overlap_epsilon_em or curve_max < band_min - band_overlap_epsilon_em) continue;
        count += 1;
    }
    return count;
}

fn curveIsExcludedFromBands(curve: Curve, axis: Axis) bool {
    return switch (axis) {
        .x => curve.x1 == curve.x2 and curve.x2 == curve.x3,
        .y => curve.y1 == curve.y2 and curve.y2 == curve.y3,
    };
}

fn zeroBandAxisHeuristicDebug() BandAxisHeuristicDebug {
    return .{
        .significant_count = 0,
        .feature_bins = 0,
        .activity_transition_count = 0,
        .max_active_curve_count = 0,
        .span_min = 0.0,
        .span_max = 0.0,
        .estimate = 0.0,
        .estimate_count = 0,
        .feature_cap = 0,
        .aspect_ratio = 0.0,
        .capped = false,
        .band_count = 0,
    };
}

fn decomposeOutlineToBuilder(slot: c.FT_GlyphSlot, outline_builder: *OutlineBuilder) !void {
    var funcs = c.FT_Outline_Funcs{
        .move_to = moveToCallback,
        .line_to = lineToCallback,
        .conic_to = conicToCallback,
        .cubic_to = cubicToCallback,
        .shift = 0,
        .delta = 0,
    };
    if (c.FT_Outline_Decompose(&slot.*.outline, &funcs, outline_builder) != 0) {
        if (outline_builder.unsupported_cubic) return error.UnsupportedCubicCurve;
        if (outline_builder.failed) return error.OutOfMemory;
        return error.OutlineDecomposeFailed;
    }
    if (outline_builder.unsupported_cubic) return error.UnsupportedCubicCurve;
    if (outline_builder.failed) return error.OutOfMemory;
    outline_builder.closeContour();
    if (outline_builder.failed) return error.OutOfMemory;
}

fn appendCompiledCodepoint(
    allocator: std.mem.Allocator,
    face: c.FT_Face,
    units_per_em: u32,
    codepoint: u32,
    glyphs: *std.ArrayList(runtime.CompiledGlyph),
    cmap: *std.ArrayList(runtime.CodepointMapEntry),
    seen_glyphs: *std.AutoHashMap(u32, void),
    curves_texture: *std.ArrayList(f32),
    bands_texture: *std.ArrayList(u32),
) !void {
    const glyph_index = c.FT_Get_Char_Index(face, codepoint);
    if (glyph_index == 0) return;

    if (!seen_glyphs.contains(glyph_index)) {
        try seen_glyphs.put(glyph_index, {});
        try glyphs.append(allocator, .{
            .glyph_index = glyph_index,
            .glyph = try generateRuntimeGlyph(allocator, face, units_per_em, glyph_index, curves_texture, bands_texture),
        });
    }

    try cmap.append(allocator, .{
        .codepoint = codepoint,
        .glyph_index = glyph_index,
    });
}

fn countSignificantCurvesForAxis(curves: []const Curve, axis: Axis, dim: f32) u32 {
    var significant_count: u32 = 0;
    const threshold = @max(0.005, dim * 0.08);
    for (curves) |curve| {
        const delta = curveAxisDelta(curve, axis);
        if (delta > threshold) significant_count += 1;
    }
    return significant_count;
}

fn countDistinctCurveExtentBinsForAxis(curves: []const Curve, axis: Axis, dim: f32) u32 {
    if (curves.len == 0) return 1;

    const threshold = @max(0.005, dim * 0.08);
    var axis_min = std.math.inf(f32);
    var axis_max = -std.math.inf(f32);
    var saw_significant = false;
    for (curves) |curve| {
        if (curveAxisDelta(curve, axis) <= threshold) continue;
        axis_min = @min(axis_min, curveAxisMin(curve, axis));
        axis_max = @max(axis_max, curveAxisMax(curve, axis));
        saw_significant = true;
    }

    if (!saw_significant) return 1;

    const span = @max(0.0001, @max(dim, axis_max - axis_min));
    var occupied = [_]bool{false} ** 6;
    for (curves) |curve| {
        if (curveAxisDelta(curve, axis) <= threshold) continue;
        occupied[quantizeAxisValueToExtentBin(curveAxisMin(curve, axis), axis_min, span)] = true;
        occupied[quantizeAxisValueToExtentBin(curveAxisMax(curve, axis), axis_min, span)] = true;
    }

    var count: u32 = 0;
    for (occupied) |is_set| {
        if (is_set) count += 1;
    }
    return @max(@as(u32, 1), count);
}

const CurveActivitySummary = struct {
    activity_transition_count: u32,
    max_active_curve_count: u32,
};

const CurveAxisSpan = struct {
    min: f32,
    max: f32,
};

fn findSignificantCurveSpanForAxis(curves: []const Curve, axis: Axis, dim: f32) ?CurveAxisSpan {
    if (curves.len == 0) return null;

    const threshold = @max(0.005, dim * 0.08);
    var axis_min = std.math.inf(f32);
    var axis_max = -std.math.inf(f32);
    var saw_significant = false;
    for (curves) |curve| {
        if (curveAxisDelta(curve, axis) <= threshold) continue;
        axis_min = @min(axis_min, curveAxisMin(curve, axis));
        axis_max = @max(axis_max, curveAxisMax(curve, axis));
        saw_significant = true;
    }
    if (!saw_significant) return null;
    return .{ .min = axis_min, .max = axis_max };
}

fn analyzeCurveActivityForAxis(curves: []const Curve, axis: Axis, dim: f32) CurveActivitySummary {
    if (curves.len == 0) return .{ .activity_transition_count = 0, .max_active_curve_count = 0 };

    const threshold = @max(0.005, dim * 0.08);
    const significant_span = findSignificantCurveSpanForAxis(curves, axis, dim) orelse
        return .{ .activity_transition_count = 0, .max_active_curve_count = 0 };
    const axis_min = significant_span.min;
    const axis_max = significant_span.max;

    const sample_count: usize = 16;
    const span = @max(0.0001, @max(dim, axis_max - axis_min));
    var previous_active: ?u32 = null;
    var activity_transition_count: u32 = 0;
    var max_active_curve_count: u32 = 0;

    for (0..sample_count) |i| {
        const pos = axis_min + ((@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(sample_count))) * span;
        var active_count: u32 = 0;
        for (curves) |curve| {
            if (curveAxisDelta(curve, axis) <= threshold) continue;
            if (curveAxisMin(curve, axis) <= pos and pos <= curveAxisMax(curve, axis)) {
                active_count += 1;
            }
        }
        max_active_curve_count = @max(max_active_curve_count, active_count);
        if (previous_active) |prev| {
            if (active_count != prev) activity_transition_count += 1;
        }
        previous_active = active_count;
    }

    return .{
        .activity_transition_count = activity_transition_count,
        .max_active_curve_count = max_active_curve_count,
    };
}

fn quantizeAxisValueToExtentBin(value: f32, axis_min: f32, span: f32) usize {
    const clamped = std.math.clamp((value - axis_min) / span, 0.0, 0.9999);
    return @min(5, @as(usize, @intFromFloat(clamped * 6.0)));
}

fn curveAxisMin(curve: Curve, axis: Axis) f32 {
    return switch (axis) {
        .x => min3(curve.x1, curve.x2, curve.x3),
        .y => min3(curve.y1, curve.y2, curve.y3),
    };
}

fn curveAxisMax(curve: Curve, axis: Axis) f32 {
    return switch (axis) {
        .x => max3(curve.x1, curve.x2, curve.x3),
        .y => max3(curve.y1, curve.y2, curve.y3),
    };
}

fn curveAxisDelta(curve: Curve, axis: Axis) f32 {
    return curveAxisMax(curve, axis) - curveAxisMin(curve, axis);
}

fn polygonArea(points: []const runtime.Point) f32 {
    return @abs(signedPolygonArea(points)) * 0.5;
}

fn signedPolygonArea(points: []const runtime.Point) f32 {
    var area: f32 = 0.0;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        area += p[0] * q[1] - q[0] * p[1];
    }
    return area;
}

fn padCurvesTexture(allocator: std.mem.Allocator, floats: []const f32) !struct { []runtime.CurveTexel, u32 } {
    if (floats.len == 0) return error.InvalidCurveTexture;

    const used_texels = (floats.len + 3) / 4;
    const height = @max(@as(u32, 1), divCeil(@as(u32, @intCast(used_texels)), texture_width));
    const padded = try allocator.alloc(runtime.CurveTexel, height * texture_width);
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
    return .{ padded, height };
}

fn padBandsTexture(allocator: std.mem.Allocator, entries: []const u32) !struct { []runtime.BandTexel, u32 } {
    if (entries.len % 2 != 0) return error.InvalidBandTexture;

    const used_texels = entries.len / 2;
    const height = @max(@as(u32, 1), divCeil(@as(u32, @intCast(used_texels)), texture_width));
    const padded = try allocator.alloc(runtime.BandTexel, height * texture_width);
    @memset(padded, .{ .value = .{ 0, 0 } });

    var texel_index: usize = 0;
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        padded[texel_index] = .{ .value = .{ entries[i], entries[i + 1] } };
        texel_index += 1;
    }
    return .{ padded, height };
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

test "buildRuntimeSkeleton preserves layout order and glyph lookup" {
    const allocator = std.testing.allocator;
    const layout = try allocator.alloc(PlannedGlyph, 2);
    defer allocator.free(layout);
    layout[0] = .{ .glyph = .{
        .glyph_index = 10,
        .codepoint = 'A',
        .cluster = 0,
        .advance = .{ 12.0, 0.0 },
        .offset = .{ 0.0, 0.0 },
    } };
    layout[1] = .{ .glyph = .{
        .glyph_index = 20,
        .codepoint = 'B',
        .cluster = 1,
        .advance = .{ 9.0, 0.0 },
        .offset = .{ 1.0, -2.0 },
    } };

    const runtime_glyphs = try allocator.alloc(PlannedRuntimeGlyph, 2);
    defer allocator.free(runtime_glyphs);
    runtime_glyphs[0] = .{
        .codepoint = 'A',
        .glyph_index = 10,
        .runtime_glyph = .{
            .glyph_index = 10,
            .bbox = .{ 0.0, 0.0, 8.0, 10.0 },
            .glyph_offset = .{ 0.0, 0.0 },
            .advance = 12.0,
            .visible = true,
            .band_location = .{ 1, 2 },
            .band_count = .{ 1, 1 },
            .band_scale = .{ 0.5, 0.25 },
            .polygon_count = 4,
            .polygon_points = .{
                .{ 0.0, 0.0 },
                .{ 0.0, 10.0 },
                .{ 8.0, 10.0 },
                .{ 8.0, 0.0 },
                .{ 0.0, 0.0 },
                .{ 0.0, 0.0 },
            },
        },
    };
    runtime_glyphs[1] = .{
        .codepoint = 'B',
        .glyph_index = 20,
        .runtime_glyph = .{
            .glyph_index = 20,
            .bbox = .{ 0.0, 0.0, 6.0, 11.0 },
            .glyph_offset = .{ 1.0, 0.0 },
            .advance = 9.0,
            .visible = true,
            .band_location = .{ 3, 4 },
            .band_count = .{ 1, 1 },
            .band_scale = .{ 0.6, 0.3 },
            .polygon_count = 4,
            .polygon_points = .{
                .{ 0.0, 0.0 },
                .{ 0.0, 11.0 },
                .{ 6.0, 11.0 },
                .{ 6.0, 0.0 },
                .{ 0.0, 0.0 },
                .{ 0.0, 0.0 },
            },
        },
    };

    const plan = BuildPlan{
        .allocator = allocator,
        .font_path = try allocator.dupe(u8, "/tmp/test-font.ttf"),
        .shape_backend = .simple_utf8,
        .units_per_em = 1000,
        .ascender = 0.8,
        .descender = -0.2,
        .line_height = 1.0,
        .layout_glyphs = layout,
        .runtime_glyphs = runtime_glyphs,
    };
    defer allocator.free(plan.font_path);

    var skeleton = try buildRuntimeSkeleton(allocator, plan);
    defer skeleton.deinit();

    try std.testing.expectEqual(@as(usize, 2), skeleton.layout_glyphs.len);
    try std.testing.expectEqual(@as(u32, 10), skeleton.layout_glyphs[0].glyph_index);
    try std.testing.expectEqual(@as(u32, 20), skeleton.layout_glyphs[1].glyph_index);
    try std.testing.expectEqual(@as(usize, 2), skeleton.glyphs.count());
    try std.testing.expectEqual(@as(f32, 12.0), skeleton.glyphs.get(10).?.advance);
    try std.testing.expectEqual(@as(f32, 6.0), skeleton.glyphs.get(20).?.bbox[2]);
}

test "buildGlyphPolygon clips a supported corner" {
    const allocator = std.testing.allocator;
    const curves = [_]Curve{
        .{
            .x1 = 4.0,
            .y1 = 0.0,
            .x2 = 0.0,
            .y2 = 0.0,
            .x3 = 0.0,
            .y3 = 4.0,
            .first = true,
        },
    };

    const polygon = try buildGlyphPolygon(allocator, &curves, 10, 10);
    defer allocator.free(polygon);

    try std.testing.expect(polygon.len > 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), polygon[0][0], 0.01);
    try std.testing.expect(polygon[0][1] > 0.0);
}

test "splitCurvesAtExtrema splits quadratic with interior extremum" {
    const allocator = std.testing.allocator;
    const curves = [_]Curve{
        .{
            .x1 = 0.0,
            .y1 = 0.0,
            .x2 = 1.0,
            .y2 = 1.0,
            .x3 = 2.0,
            .y3 = 0.0,
            .first = true,
        },
    };

    const split = try splitCurvesAtExtrema(allocator, &curves);
    defer allocator.free(split);

    try std.testing.expectEqual(@as(usize, 2), split.len);
    try std.testing.expect(split[0].first);
    try std.testing.expect(!split[1].first);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), split[0].x3, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), split[0].y3, 0.0001);
    try std.testing.expectApproxEqAbs(split[0].x3, split[1].x1, 0.0001);
    try std.testing.expectApproxEqAbs(split[0].y3, split[1].y1, 0.0001);
}

test "chooseBandCountForAxis scales from significant monotonic segments" {
    const curves = [_]Curve{
        .{ .x1 = 0.0, .y1 = 0.0, .x2 = 0.2, .y2 = 0.5, .x3 = 0.4, .y3 = 1.0 },
        .{ .x1 = 0.4, .y1 = 1.0, .x2 = 0.7, .y2 = 0.2, .x3 = 1.0, .y3 = 0.0 },
        .{ .x1 = 0.0, .y1 = 0.1, .x2 = 0.0, .y2 = 0.4, .x3 = 0.0, .y3 = 0.6 },
        .{ .x1 = 0.0, .y1 = 0.6, .x2 = 0.0, .y2 = 0.8, .x3 = 0.0, .y3 = 1.0 },
    };

    try std.testing.expectEqual(@as(u32, 2), countSignificantCurvesForAxis(&curves, .x, 1.0));
    try std.testing.expectEqual(@as(u32, 4), countSignificantCurvesForAxis(&curves, .y, 1.0));
    try std.testing.expectEqual(@as(u32, 3), countDistinctCurveExtentBinsForAxis(&curves, .x, 1.0));
    try std.testing.expectEqual(@as(u32, 6), countDistinctCurveExtentBinsForAxis(&curves, .y, 1.0));
    try std.testing.expectEqual(@as(u32, 8), chooseBandCountForAxis(&curves, .x, 1.0, 1.0));
    try std.testing.expectEqual(@as(u32, 12), chooseBandCountForAxis(&curves, .y, 1.0, 1.0));
}

test "chooseBandCountForAxis caps round-ish curve clouds below saturation" {
    const curves = [_]Curve{
        .{ .x1 = 0.00, .y1 = 0.50, .x2 = 0.10, .y2 = 0.90, .x3 = 0.35, .y3 = 1.00 },
        .{ .x1 = 0.35, .y1 = 1.00, .x2 = 0.70, .y2 = 1.00, .x3 = 0.85, .y3 = 0.80 },
        .{ .x1 = 0.85, .y1 = 0.80, .x2 = 1.00, .y2 = 0.60, .x3 = 1.00, .y3 = 0.50 },
        .{ .x1 = 1.00, .y1 = 0.50, .x2 = 1.00, .y2 = 0.20, .x3 = 0.80, .y3 = 0.05 },
        .{ .x1 = 0.80, .y1 = 0.05, .x2 = 0.55, .y2 = 0.00, .x3 = 0.50, .y3 = 0.00 },
        .{ .x1 = 0.50, .y1 = 0.00, .x2 = 0.15, .y2 = 0.00, .x3 = 0.00, .y3 = 0.50 },
        .{ .x1 = 0.25, .y1 = 0.50, .x2 = 0.35, .y2 = 0.75, .x3 = 0.50, .y3 = 0.75 },
        .{ .x1 = 0.50, .y1 = 0.75, .x2 = 0.65, .y2 = 0.75, .x3 = 0.75, .y3 = 0.50 },
        .{ .x1 = 0.75, .y1 = 0.50, .x2 = 0.75, .y2 = 0.25, .x3 = 0.50, .y3 = 0.25 },
        .{ .x1 = 0.50, .y1 = 0.25, .x2 = 0.35, .y2 = 0.25, .x3 = 0.25, .y3 = 0.50 },
    };

    try std.testing.expect(countSignificantCurvesForAxis(&curves, .x, 1.0) >= 8);
    try std.testing.expect(countSignificantCurvesForAxis(&curves, .y, 1.0) >= 8);
    try std.testing.expectEqual(@as(u32, 4), countDistinctCurveExtentBinsForAxis(&curves, .x, 1.0));
    try std.testing.expectEqual(@as(u32, 4), countDistinctCurveExtentBinsForAxis(&curves, .y, 1.0));
    try std.testing.expectEqual(@as(u32, 18), chooseBandCountForAxis(&curves, .x, 1.0, 1.0));
    try std.testing.expectEqual(@as(u32, 18), chooseBandCountForAxis(&curves, .y, 1.0, 1.0));
}

test "buildRuntimeFont generates textures for a system font" {
    const font_path = findTestFontPath() orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var runtime_font = try buildRuntimeFont(allocator, .{
        .text = "Meow?!",
        .font_path = font_path,
        .shape_backend = .simple_utf8,
    });
    defer runtime_font.deinit();

    try std.testing.expect(runtime_font.curves_texels.len > 0);
    try std.testing.expect(runtime_font.bands_texels.len > 0);
    try std.testing.expectEqual(@as(usize, 6), runtime_font.layout_glyphs.len);
    try std.testing.expect(runtime_font.glyphs.count() >= 5);
    const first_glyph = runtime_font.glyphs.get(runtime_font.layout_glyphs[0].glyph_index).?;
    try std.testing.expect(first_glyph.polygon_count >= 3);
    try std.testing.expect(first_glyph.polygon_count <= 6);
    try std.testing.expect(first_glyph.band_count[0] > 0);
    try std.testing.expect(first_glyph.band_count[0] > 1 or first_glyph.band_count[1] > 1);
    try std.testing.expect(first_glyph.advance > 0.0);
    try std.testing.expect(first_glyph.advance < 4.0);
    try std.testing.expect(first_glyph.bbox[2] > 0.0);
    try std.testing.expect(first_glyph.bbox[2] < 4.0);
    try std.testing.expect(first_glyph.band_scale[0] > 1.0 or first_glyph.band_scale[1] > 1.0);
}

fn findTestFontPath() ?[]const u8 {
    const candidates = [_][]const u8{
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
    };
    for (candidates) |candidate| {
        const file = std.Io.Dir.openFileAbsolute(std.testing.io, candidate, .{}) catch continue;
        file.close(std.testing.io);
        return candidate;
    }
    return null;
}

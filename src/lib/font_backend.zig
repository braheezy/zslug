const std = @import("std");
const build_options = @import("build_options");
const font_model = @import("font_model.zig");
const native_generator = @import("native_generator.zig");
const runtime = @import("runtime_font.zig");
const slug_parse = @import("slug_parse.zig");
const text_shape = @import("text_shape.zig");

pub const Backend = enum {
    slug_reference,
    native_generator,
};

pub const LoadConfig = struct {
    text: []const u8 = build_options.demo_text,
    slug_path: ?[]const u8 = null,
    font_path: ?[]const u8 = null,
    backend: Backend = defaultBackend(),
    shape_backend: text_shape.ShapeBackend = text_shape.defaultBackend(),
};

pub const NativeGeneratorConfig = struct {
    text: []const u8,
    font_path: []const u8,
    shape_backend: text_shape.ShapeBackend,
    atlas_width: u32 = 4096,
};

pub const CompileFontConfig = struct {
    font_path: []const u8,
    coverage: native_generator.Coverage = .ascii_basic,
};

pub fn defaultBackend() Backend {
    if (std.mem.eql(u8, build_options.runtime_backend, "native_generator")) return .native_generator;
    return .slug_reference;
}

pub fn loadRuntimeFont(allocator: std.mem.Allocator, config: LoadConfig) !runtime.RuntimeFont {
    return switch (config.backend) {
        .slug_reference => loadReferenceSlugFont(allocator, config),
        .native_generator => buildNativeRuntimeFont(allocator, .{
            .text = config.text,
            .font_path = config.font_path orelse return error.MissingFontPath,
            .shape_backend = config.shape_backend,
        }),
    };
}

pub fn makeNativeBuildPlan(allocator: std.mem.Allocator, config: NativeGeneratorConfig) !native_generator.BuildPlan {
    return native_generator.makeBuildPlan(allocator, .{
        .text = config.text,
        .font_path = config.font_path,
        .shape_backend = config.shape_backend,
    });
}

pub fn buildNativeRuntimeFont(allocator: std.mem.Allocator, config: NativeGeneratorConfig) !runtime.RuntimeFont {
    var build_plan = try makeNativeBuildPlan(allocator, config);
    defer build_plan.deinit();
    var runtime_skeleton = try native_generator.buildRuntimeSkeleton(allocator, build_plan);
    defer runtime_skeleton.deinit();
    return native_generator.buildRuntimeFont(allocator, .{
        .text = config.text,
        .font_path = config.font_path,
        .shape_backend = config.shape_backend,
    });
}

pub fn compileNativeFontAsset(allocator: std.mem.Allocator, config: CompileFontConfig) !runtime.CompiledFont {
    return native_generator.compileFont(allocator, .{
        .font_path = config.font_path,
        .coverage = config.coverage,
    });
}

fn loadReferenceSlugFont(allocator: std.mem.Allocator, config: LoadConfig) !runtime.RuntimeFont {
    const slug_path = config.slug_path orelse return error.MissingSlugPath;
    var file = try slug_parse.loadFile(allocator, slug_path);
    defer file.deinit();

    const font = try slug_parse.parsePrimaryFontHeader(file);
    const curves = try slug_parse.extractCurveTexture(allocator, file);
    defer allocator.free(curves.texels);
    const bands = try slug_parse.extractBandTexture(allocator, file);
    defer allocator.free(bands.texels);

    var glyphs = std.AutoHashMap(u32, runtime.RuntimeGlyph).init(allocator);
    errdefer glyphs.deinit();

    var shaped = try text_shape.shapeUtf8(allocator, config.text);
    defer shaped.deinit();
    const layout_glyphs = try allocator.alloc(runtime.LayoutGlyph, shaped.glyphs.len);
    errdefer allocator.free(layout_glyphs);

    for (shaped.glyphs, layout_glyphs) |shaped_glyph, *layout_glyph| {
        const codepoint = shaped_glyph.codepoint;
        const glyph_index = if (shaped_glyph.glyph_index != 0)
            shaped_glyph.glyph_index
        else
            try slug_parse.lookupGlyphIndex(file, font, codepoint);
        if (glyph_index == 0) return error.MissingGlyph;

        if (glyphs.get(glyph_index)) |existing| {
            layout_glyph.* = .{
                .glyph_index = glyph_index,
                .codepoint = codepoint,
                .cluster = shaped_glyph.cluster,
                .advance = if (shaped_glyph.advance[0] != 0.0 or shaped_glyph.advance[1] != 0.0)
                    shaped_glyph.advance
                else
                    .{ existing.advance, 0.0 },
                .offset = shaped_glyph.offset,
            };
            continue;
        }

        const glyph = try slug_parse.parseGlyphData(file, font, glyph_index, 0);
        const visible =
            glyph.graphic.band_count[0] > 0 and
            glyph.graphic.band_count[1] > 0 and
            glyph.graphic.bounding_box[2] > glyph.graphic.bounding_box[0] and
            glyph.graphic.bounding_box[3] > glyph.graphic.bounding_box[1];
        const polygon = slug_parse.decodePolygon(glyph.graphic);

        try glyphs.put(glyph_index, .{
            .glyph_index = glyph_index,
            .bbox = glyph.graphic.bounding_box,
            .glyph_offset = glyph.glyph_offset,
            .advance = glyph.advance_width,
            .visible = visible,
            .band_location = glyph.graphic.band_location,
            .band_count = .{
                if (glyph.graphic.band_count[0] > 0) @intCast(glyph.graphic.band_count[0]) else 0,
                if (glyph.graphic.band_count[1] > 0) @intCast(glyph.graphic.band_count[1]) else 0,
            },
            .band_scale = glyph.graphic.band_scale,
            .polygon_count = polygon.count,
            .polygon_points = polygon.points,
        });

        layout_glyph.* = .{
            .glyph_index = glyph_index,
            .codepoint = codepoint,
            .cluster = shaped_glyph.cluster,
            .advance = if (shaped_glyph.advance[0] != 0.0 or shaped_glyph.advance[1] != 0.0)
                shaped_glyph.advance
            else
                .{ glyph.advance_width, 0.0 },
            .offset = shaped_glyph.offset,
        };
    }

    const curves_texels = try allocator.alloc(runtime.CurveTexel, curves.texels.len);
    errdefer allocator.free(curves_texels);
    for (curves_texels, curves.texels) |*dst, src| dst.* = .{ .value = src.value };

    const bands_texels = try allocator.alloc(runtime.BandTexel, bands.texels.len);
    errdefer allocator.free(bands_texels);
    for (bands_texels, bands.texels) |*dst, src| dst.* = .{ .value = src.value };

    return .{
        .allocator = allocator,
        .curves_width = curves.width,
        .curves_height = curves.height,
        .curves_texels = curves_texels,
        .bands_width = bands.width,
        .bands_height = bands.height,
        .bands_texels = bands_texels,
        .layout_glyphs = layout_glyphs,
        .glyphs = glyphs,
    };
}

test "reference and native backends align on basic glyph metrics" {
    const allocator = std.testing.allocator;
    const slug_path = if (canOpenRelative("SlugDemo/Fonts/arial.slug"))
        "SlugDemo/Fonts/arial.slug"
    else
        return error.SkipZigTest;
    const font_path = findArialFontPath() orelse return error.SkipZigTest;

    var reference_font = try loadRuntimeFont(allocator, .{
        .text = "Meow?!",
        .slug_path = slug_path,
        .backend = .slug_reference,
    });
    defer reference_font.deinit();

    var native_font = try loadRuntimeFont(allocator, .{
        .text = "Meow?!",
        .font_path = font_path,
        .backend = .native_generator,
        .shape_backend = .simple_utf8,
    });
    defer native_font.deinit();

    var reference_model = try font_model.fromRuntimeFont(allocator, reference_font);
    defer reference_model.deinit();
    var file = try slug_parse.loadFile(allocator, slug_path);
    defer file.deinit();
    const font = try slug_parse.parsePrimaryFontHeader(file);
    var contour_refs = try slug_parse.extractContourCurveRefs(allocator, file, font);
    defer contour_refs.deinit();
    try font_model.attachOfficialCurveRefs(allocator, &reference_model, contour_refs);

    var native_model = try font_model.fromRuntimeFont(allocator, native_font);
    defer native_model.deinit();
    var glyph_index_report = try font_model.compareFontModels(allocator, reference_model, native_model);
    defer glyph_index_report.deinit();
    var layout_report = try font_model.compareFontModelsByLayout(allocator, reference_model, native_model);
    defer layout_report.deinit();

    try std.testing.expectEqual(reference_model.layout_glyphs.len, native_model.layout_glyphs.len);
    try std.testing.expectEqual(@as(usize, 0), layout_report.layout_codepoint_mismatches);
    try std.testing.expectEqual(@as(usize, 0), layout_report.missing_expected_glyphs);
    try std.testing.expectEqual(@as(usize, 0), layout_report.missing_actual_glyphs);
    try std.testing.expectEqual(@as(usize, 0), layout_report.invisible_mismatches);
    try std.testing.expect(layout_report.max_advance_abs_diff <= 2048.0);
    try std.testing.expect(layout_report.max_bounds_abs_diff <= 2048.0);
    try std.testing.expect(layout_report.glyph_diffs.len > 0);
    try std.testing.expect(glyph_index_report.missing_expected_glyphs > 0 or glyph_index_report.missing_actual_glyphs > 0);
}

fn canOpenRelative(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn findArialFontPath() ?[]const u8 {
    const candidates = [_][]const u8{
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
    };
    for (candidates) |candidate| {
        const file = std.fs.openFileAbsolute(candidate, .{}) catch continue;
        file.close();
        return candidate;
    }
    return null;
}

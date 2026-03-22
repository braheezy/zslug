const std = @import("std");
const runtime = @import("runtime_font.zig");
const slug_parse = @import("slug_parse.zig");

pub const PackedCurve = struct {
    texel_index: u32,
    texel0: [4]f32,
    texel1: [4]f32,
};

pub const BandModel = struct {
    curve_count: u16,
    curves: []PackedCurve,
};

pub const BandPayloadSummary = struct {
    allocator: std.mem.Allocator,
    curve_counts: []u16,
    non_empty_count: usize,
    total_curve_refs: usize,
    max_curve_count: u16,

    pub fn deinit(self: *BandPayloadSummary) void {
        self.allocator.free(self.curve_counts);
        self.* = undefined;
    }
};

pub const GlyphModel = struct {
    glyph_index: u32,
    visible: bool,
    advance: f32,
    bbox: [4]f32,
    glyph_offset: [2]f32,
    band_scale: [2]f32,
    polygon_count: u8,
    polygon_points: [6]runtime.Point,
    official_curve_refs: []u32,
    horizontal_bands: []BandModel,
    vertical_bands: []BandModel,

    pub fn bounds(self: GlyphModel) [4]f32 {
        return .{
            self.glyph_offset[0] + self.bbox[0],
            self.glyph_offset[1] + self.bbox[1],
            self.glyph_offset[0] + self.bbox[2],
            self.glyph_offset[1] + self.bbox[3],
        };
    }

    pub fn totalCurveRefs(self: GlyphModel) usize {
        var total: usize = 0;
        for (self.horizontal_bands) |band| total += band.curves.len;
        for (self.vertical_bands) |band| total += band.curves.len;
        return total;
    }
};

pub const FontModel = struct {
    allocator: std.mem.Allocator,
    layout_glyphs: []runtime.LayoutGlyph,
    glyphs: []GlyphModel,

    pub fn deinit(self: *FontModel) void {
        self.allocator.free(self.layout_glyphs);
        for (self.glyphs) |glyph| {
            self.allocator.free(glyph.official_curve_refs);
            freeBands(self.allocator, glyph.horizontal_bands);
            freeBands(self.allocator, glyph.vertical_bands);
        }
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }

    pub fn findGlyph(self: FontModel, glyph_index: u32) ?GlyphModel {
        for (self.glyphs) |glyph| {
            if (glyph.glyph_index == glyph_index) return glyph;
        }
        return null;
    }
};

pub const GlyphDiff = struct {
    glyph_index: u32,
    advance_abs_diff: f32,
    max_bounds_abs_diff: f32,
    horizontal_band_count_diff: i32,
    vertical_band_count_diff: i32,
    polygon_count_diff: i32,
    total_curve_ref_diff: i32,
    official_curve_ref_missing_count: usize,
    official_curve_ref_extra_count: usize,
};

pub const LayoutGlyphDiff = struct {
    layout_index: usize,
    codepoint: u32,
    expected_glyph_index: u32,
    actual_glyph_index: u32,
    advance_abs_diff: f32,
    max_bounds_abs_diff: f32,
    horizontal_band_count_diff: i32,
    vertical_band_count_diff: i32,
    polygon_count_diff: i32,
    total_curve_ref_diff: i32,
    official_curve_ref_missing_count: usize,
    official_curve_ref_extra_count: usize,
};

pub const FontComparisonReport = struct {
    allocator: std.mem.Allocator,
    glyph_diffs: []GlyphDiff,
    layout_count_expected: usize,
    layout_count_actual: usize,
    layout_codepoint_mismatches: usize,
    missing_expected_glyphs: usize,
    missing_actual_glyphs: usize,
    invisible_mismatches: usize,
    max_advance_abs_diff: f32,
    max_bounds_abs_diff: f32,
    horizontal_band_count_mismatches: usize,
    vertical_band_count_mismatches: usize,
    horizontal_band_payload_mismatches: usize,
    vertical_band_payload_mismatches: usize,
    polygon_count_mismatches: usize,
    total_curve_ref_mismatches: usize,
    official_curve_ref_mismatches: usize,
    official_curve_ref_missing_total: usize,
    official_curve_ref_extra_total: usize,

    pub fn deinit(self: *FontComparisonReport) void {
        self.allocator.free(self.glyph_diffs);
        self.* = undefined;
    }
};

pub const LayoutFontComparisonReport = struct {
    allocator: std.mem.Allocator,
    glyph_diffs: []LayoutGlyphDiff,
    layout_count_expected: usize,
    layout_count_actual: usize,
    layout_codepoint_mismatches: usize,
    layout_glyph_id_mismatches: usize,
    missing_expected_glyphs: usize,
    missing_actual_glyphs: usize,
    invisible_mismatches: usize,
    max_advance_abs_diff: f32,
    max_bounds_abs_diff: f32,
    horizontal_band_count_mismatches: usize,
    vertical_band_count_mismatches: usize,
    horizontal_band_payload_mismatches: usize,
    vertical_band_payload_mismatches: usize,
    polygon_count_mismatches: usize,
    total_curve_ref_mismatches: usize,
    official_curve_ref_mismatches: usize,
    official_curve_ref_missing_total: usize,
    official_curve_ref_extra_total: usize,

    pub fn deinit(self: *LayoutFontComparisonReport) void {
        self.allocator.free(self.glyph_diffs);
        self.* = undefined;
    }
};

pub fn fromRuntimeFont(allocator: std.mem.Allocator, font: runtime.RuntimeFont) !FontModel {
    const layout_glyphs = try allocator.dupe(runtime.LayoutGlyph, font.layout_glyphs);
    errdefer allocator.free(layout_glyphs);

    var glyphs = std.ArrayList(GlyphModel).empty;
    errdefer {
        for (glyphs.items) |glyph| {
            freeBands(allocator, glyph.horizontal_bands);
            freeBands(allocator, glyph.vertical_bands);
        }
        glyphs.deinit(allocator);
    }

    var it = font.glyphs.iterator();
    while (it.next()) |entry| {
        const glyph = entry.value_ptr.*;
        const horizontal_bands = try decodeBands(allocator, font, glyph, 0);
        errdefer freeBands(allocator, horizontal_bands);
        const vertical_bands = try decodeBands(allocator, font, glyph, 1);
        errdefer freeBands(allocator, vertical_bands);

        try glyphs.append(allocator, .{
            .glyph_index = glyph.glyph_index,
            .visible = glyph.visible,
            .advance = glyph.advance,
            .bbox = glyph.bbox,
            .glyph_offset = glyph.glyph_offset,
            .band_scale = glyph.band_scale,
            .polygon_count = glyph.polygon_count,
            .polygon_points = glyph.polygon_points,
            .official_curve_refs = try allocator.alloc(u32, 0),
            .horizontal_bands = horizontal_bands,
            .vertical_bands = vertical_bands,
        });
    }

    std.mem.sort(GlyphModel, glyphs.items, {}, struct {
        fn lessThan(_: void, a: GlyphModel, b: GlyphModel) bool {
            return a.glyph_index < b.glyph_index;
        }
    }.lessThan);

    return .{
        .allocator = allocator,
        .layout_glyphs = layout_glyphs,
        .glyphs = try glyphs.toOwnedSlice(allocator),
    };
}

pub fn compareFontModels(
    allocator: std.mem.Allocator,
    expected: FontModel,
    actual: FontModel,
) !FontComparisonReport {
    var glyph_diffs = std.ArrayList(GlyphDiff).empty;
    errdefer glyph_diffs.deinit(allocator);

    const shared_layout_count = @min(expected.layout_glyphs.len, actual.layout_glyphs.len);
    var layout_codepoint_mismatches: usize = 0;
    for (expected.layout_glyphs[0..shared_layout_count], actual.layout_glyphs[0..shared_layout_count]) |lhs, rhs| {
        if (lhs.codepoint != rhs.codepoint) layout_codepoint_mismatches += 1;
    }

    var missing_actual_glyphs: usize = 0;
    var invisible_mismatches: usize = 0;
    var max_advance_abs_diff: f32 = 0.0;
    var max_bounds_abs_diff: f32 = 0.0;
    var horizontal_band_count_mismatches: usize = 0;
    var vertical_band_count_mismatches: usize = 0;
    var horizontal_band_payload_mismatches: usize = 0;
    var vertical_band_payload_mismatches: usize = 0;
    var polygon_count_mismatches: usize = 0;
    var total_curve_ref_mismatches: usize = 0;
    var official_curve_ref_mismatches: usize = 0;
    var official_curve_ref_missing_total: usize = 0;
    var official_curve_ref_extra_total: usize = 0;

    for (expected.glyphs) |expected_glyph| {
        const actual_glyph = actual.findGlyph(expected_glyph.glyph_index) orelse {
            missing_actual_glyphs += 1;
            continue;
        };

        const glyph_cmp = try compareGlyphPair(allocator, expected_glyph, actual_glyph);
        if (glyph_cmp.invisible_mismatch) invisible_mismatches += 1;
        max_advance_abs_diff = @max(max_advance_abs_diff, glyph_cmp.advance_abs_diff);
        max_bounds_abs_diff = @max(max_bounds_abs_diff, glyph_cmp.max_bounds_abs_diff);
        if (glyph_cmp.horizontal_band_count_diff != 0) horizontal_band_count_mismatches += 1;
        if (glyph_cmp.vertical_band_count_diff != 0) vertical_band_count_mismatches += 1;
        if (glyph_cmp.horizontal_band_payload_mismatch) horizontal_band_payload_mismatches += 1;
        if (glyph_cmp.vertical_band_payload_mismatch) vertical_band_payload_mismatches += 1;
        if (glyph_cmp.polygon_count_diff != 0) polygon_count_mismatches += 1;
        if (glyph_cmp.total_curve_ref_diff != 0) total_curve_ref_mismatches += 1;
        if (glyph_cmp.official_curve_ref_missing_count > 0 or glyph_cmp.official_curve_ref_extra_count > 0) {
            official_curve_ref_mismatches += 1;
        }
        official_curve_ref_missing_total += glyph_cmp.official_curve_ref_missing_count;
        official_curve_ref_extra_total += glyph_cmp.official_curve_ref_extra_count;

        try glyph_diffs.append(allocator, .{
            .glyph_index = expected_glyph.glyph_index,
            .advance_abs_diff = glyph_cmp.advance_abs_diff,
            .max_bounds_abs_diff = glyph_cmp.max_bounds_abs_diff,
            .horizontal_band_count_diff = glyph_cmp.horizontal_band_count_diff,
            .vertical_band_count_diff = glyph_cmp.vertical_band_count_diff,
            .polygon_count_diff = glyph_cmp.polygon_count_diff,
            .total_curve_ref_diff = glyph_cmp.total_curve_ref_diff,
            .official_curve_ref_missing_count = glyph_cmp.official_curve_ref_missing_count,
            .official_curve_ref_extra_count = glyph_cmp.official_curve_ref_extra_count,
        });
    }

    var missing_expected_glyphs: usize = 0;
    for (actual.glyphs) |actual_glyph| {
        if (expected.findGlyph(actual_glyph.glyph_index) == null) missing_expected_glyphs += 1;
    }

    std.mem.sort(GlyphDiff, glyph_diffs.items, {}, struct {
        fn lessThan(_: void, a: GlyphDiff, b: GlyphDiff) bool {
            return a.glyph_index < b.glyph_index;
        }
    }.lessThan);

    return .{
        .allocator = allocator,
        .glyph_diffs = try glyph_diffs.toOwnedSlice(allocator),
        .layout_count_expected = expected.layout_glyphs.len,
        .layout_count_actual = actual.layout_glyphs.len,
        .layout_codepoint_mismatches = layout_codepoint_mismatches,
        .missing_expected_glyphs = missing_expected_glyphs,
        .missing_actual_glyphs = missing_actual_glyphs,
        .invisible_mismatches = invisible_mismatches,
        .max_advance_abs_diff = max_advance_abs_diff,
        .max_bounds_abs_diff = max_bounds_abs_diff,
        .horizontal_band_count_mismatches = horizontal_band_count_mismatches,
        .vertical_band_count_mismatches = vertical_band_count_mismatches,
        .horizontal_band_payload_mismatches = horizontal_band_payload_mismatches,
        .vertical_band_payload_mismatches = vertical_band_payload_mismatches,
        .polygon_count_mismatches = polygon_count_mismatches,
        .total_curve_ref_mismatches = total_curve_ref_mismatches,
        .official_curve_ref_mismatches = official_curve_ref_mismatches,
        .official_curve_ref_missing_total = official_curve_ref_missing_total,
        .official_curve_ref_extra_total = official_curve_ref_extra_total,
    };
}

pub fn compareFontModelsByLayout(
    allocator: std.mem.Allocator,
    expected: FontModel,
    actual: FontModel,
) !LayoutFontComparisonReport {
    var glyph_diffs = std.ArrayList(LayoutGlyphDiff).empty;
    errdefer glyph_diffs.deinit(allocator);

    const shared_layout_count = @min(expected.layout_glyphs.len, actual.layout_glyphs.len);
    var layout_codepoint_mismatches: usize = 0;
    var layout_glyph_id_mismatches: usize = 0;
    var missing_expected_glyphs: usize = 0;
    var missing_actual_glyphs: usize = 0;
    var invisible_mismatches: usize = 0;
    var max_advance_abs_diff: f32 = 0.0;
    var max_bounds_abs_diff: f32 = 0.0;
    var horizontal_band_count_mismatches: usize = 0;
    var vertical_band_count_mismatches: usize = 0;
    var horizontal_band_payload_mismatches: usize = 0;
    var vertical_band_payload_mismatches: usize = 0;
    var polygon_count_mismatches: usize = 0;
    var total_curve_ref_mismatches: usize = 0;
    var official_curve_ref_mismatches: usize = 0;
    var official_curve_ref_missing_total: usize = 0;
    var official_curve_ref_extra_total: usize = 0;

    for (0..shared_layout_count) |i| {
        const expected_layout = expected.layout_glyphs[i];
        const actual_layout = actual.layout_glyphs[i];
        if (expected_layout.codepoint != actual_layout.codepoint) {
            layout_codepoint_mismatches += 1;
            continue;
        }
        if (expected_layout.glyph_index != actual_layout.glyph_index) layout_glyph_id_mismatches += 1;

        const expected_glyph = expected.findGlyph(expected_layout.glyph_index) orelse {
            missing_expected_glyphs += 1;
            continue;
        };
        const actual_glyph = actual.findGlyph(actual_layout.glyph_index) orelse {
            missing_actual_glyphs += 1;
            continue;
        };

        const glyph_cmp = try compareGlyphPair(allocator, expected_glyph, actual_glyph);
        if (glyph_cmp.invisible_mismatch) invisible_mismatches += 1;
        max_advance_abs_diff = @max(max_advance_abs_diff, @max(glyph_cmp.advance_abs_diff, @abs(expected_layout.advance[0] - actual_layout.advance[0])));
        max_bounds_abs_diff = @max(max_bounds_abs_diff, glyph_cmp.max_bounds_abs_diff);
        if (glyph_cmp.horizontal_band_count_diff != 0) horizontal_band_count_mismatches += 1;
        if (glyph_cmp.vertical_band_count_diff != 0) vertical_band_count_mismatches += 1;
        if (glyph_cmp.horizontal_band_payload_mismatch) horizontal_band_payload_mismatches += 1;
        if (glyph_cmp.vertical_band_payload_mismatch) vertical_band_payload_mismatches += 1;
        if (glyph_cmp.polygon_count_diff != 0) polygon_count_mismatches += 1;
        if (glyph_cmp.total_curve_ref_diff != 0) total_curve_ref_mismatches += 1;
        if (glyph_cmp.official_curve_ref_missing_count > 0 or glyph_cmp.official_curve_ref_extra_count > 0) {
            official_curve_ref_mismatches += 1;
        }
        official_curve_ref_missing_total += glyph_cmp.official_curve_ref_missing_count;
        official_curve_ref_extra_total += glyph_cmp.official_curve_ref_extra_count;

        try glyph_diffs.append(allocator, .{
            .layout_index = i,
            .codepoint = expected_layout.codepoint,
            .expected_glyph_index = expected_layout.glyph_index,
            .actual_glyph_index = actual_layout.glyph_index,
            .advance_abs_diff = @max(glyph_cmp.advance_abs_diff, @abs(expected_layout.advance[0] - actual_layout.advance[0])),
            .max_bounds_abs_diff = glyph_cmp.max_bounds_abs_diff,
            .horizontal_band_count_diff = glyph_cmp.horizontal_band_count_diff,
            .vertical_band_count_diff = glyph_cmp.vertical_band_count_diff,
            .polygon_count_diff = glyph_cmp.polygon_count_diff,
            .total_curve_ref_diff = glyph_cmp.total_curve_ref_diff,
            .official_curve_ref_missing_count = glyph_cmp.official_curve_ref_missing_count,
            .official_curve_ref_extra_count = glyph_cmp.official_curve_ref_extra_count,
        });
    }

    return .{
        .allocator = allocator,
        .glyph_diffs = try glyph_diffs.toOwnedSlice(allocator),
        .layout_count_expected = expected.layout_glyphs.len,
        .layout_count_actual = actual.layout_glyphs.len,
        .layout_codepoint_mismatches = layout_codepoint_mismatches,
        .layout_glyph_id_mismatches = layout_glyph_id_mismatches,
        .missing_expected_glyphs = missing_expected_glyphs,
        .missing_actual_glyphs = missing_actual_glyphs,
        .invisible_mismatches = invisible_mismatches,
        .max_advance_abs_diff = max_advance_abs_diff,
        .max_bounds_abs_diff = max_bounds_abs_diff,
        .horizontal_band_count_mismatches = horizontal_band_count_mismatches,
        .vertical_band_count_mismatches = vertical_band_count_mismatches,
        .horizontal_band_payload_mismatches = horizontal_band_payload_mismatches,
        .vertical_band_payload_mismatches = vertical_band_payload_mismatches,
        .polygon_count_mismatches = polygon_count_mismatches,
        .total_curve_ref_mismatches = total_curve_ref_mismatches,
        .official_curve_ref_mismatches = official_curve_ref_mismatches,
        .official_curve_ref_missing_total = official_curve_ref_missing_total,
        .official_curve_ref_extra_total = official_curve_ref_extra_total,
    };
}

pub fn attachOfficialCurveRefs(
    allocator: std.mem.Allocator,
    model: *FontModel,
    contour_refs: slug_parse.ContourCurveRefTable,
) !void {
    for (model.glyphs) |*glyph| {
        allocator.free(glyph.official_curve_refs);
        const refs = contour_refs.glyphCurveRefs(glyph.glyph_index) orelse {
            glyph.official_curve_refs = try allocator.alloc(u32, 0);
            continue;
        };
        glyph.official_curve_refs = try allocator.dupe(u32, refs);
        std.mem.sort(u32, glyph.official_curve_refs, {}, std.sort.asc(u32));
    }
}

pub fn summarizeBands(allocator: std.mem.Allocator, bands: []const BandModel) !BandPayloadSummary {
    const curve_counts = try allocator.alloc(u16, bands.len);
    errdefer allocator.free(curve_counts);

    var non_empty_count: usize = 0;
    var total_curve_refs: usize = 0;
    var max_curve_count: u16 = 0;
    for (bands, curve_counts) |band, *curve_count| {
        curve_count.* = band.curve_count;
        total_curve_refs += band.curves.len;
        if (band.curve_count > 0) non_empty_count += 1;
        max_curve_count = @max(max_curve_count, band.curve_count);
    }

    return .{
        .allocator = allocator,
        .curve_counts = curve_counts,
        .non_empty_count = non_empty_count,
        .total_curve_refs = total_curve_refs,
        .max_curve_count = max_curve_count,
    };
}

fn decodeBands(
    allocator: std.mem.Allocator,
    font: runtime.RuntimeFont,
    glyph: runtime.RuntimeGlyph,
    axis: usize,
) ![]BandModel {
    const count = if (axis == 0) glyph.band_count[1] else glyph.band_count[0];
    if (!glyph.visible or count == 0) return allocator.alloc(BandModel, 0);

    const base_index = @as(usize, glyph.band_location[1]) * font.bands_width + glyph.band_location[0];
    const axis_base_index = base_index + if (axis == 0) 0 else glyph.band_count[1];
    if (axis_base_index + count > font.bands_texels.len) return error.InvalidBandData;

    const bands = try allocator.alloc(BandModel, count);
    errdefer freeBands(allocator, bands);

    for (bands, 0..) |*band, i| {
        const header = font.bands_texels[axis_base_index + i].value;
        const curve_count = header[0];
        const curve_offset = header[1];
        const curve_pairs_base = base_index + curve_offset;
        if (curve_pairs_base + curve_count > font.bands_texels.len) return error.InvalidBandData;

        const curves = try allocator.alloc(PackedCurve, curve_count);
        errdefer allocator.free(curves);
        for (curves, 0..) |*curve, curve_i| {
            const pair = font.bands_texels[curve_pairs_base + curve_i].value;
            const texel_index = @as(usize, pair[1]) * font.curves_width + pair[0];
            if (texel_index >= font.curves_texels.len) return error.InvalidCurveData;
            curve.* = .{
                .texel_index = @intCast(texel_index),
                .texel0 = font.curves_texels[texel_index].value,
                .texel1 = if (texel_index + 1 < font.curves_texels.len)
                    font.curves_texels[texel_index + 1].value
                else
                    .{ -1.0, -1.0, -1.0, -1.0 },
            };
        }

        band.* = .{
            .curve_count = @intCast(curve_count),
            .curves = curves,
        };
    }

    return bands;
}

fn freeBands(allocator: std.mem.Allocator, bands: []BandModel) void {
    for (bands) |band| allocator.free(band.curves);
    allocator.free(bands);
}

const CurveRefDiff = struct {
    missing_count: usize,
    extra_count: usize,
};

pub const CurveGeometryDiff = struct {
    missing_count: usize,
    extra_count: usize,
};

const GlyphPairComparison = struct {
    invisible_mismatch: bool,
    advance_abs_diff: f32,
    max_bounds_abs_diff: f32,
    horizontal_band_count_diff: i32,
    vertical_band_count_diff: i32,
    horizontal_band_payload_mismatch: bool,
    vertical_band_payload_mismatch: bool,
    polygon_count_diff: i32,
    total_curve_ref_diff: i32,
    official_curve_ref_missing_count: usize,
    official_curve_ref_extra_count: usize,
};

fn compareGlyphPair(
    allocator: std.mem.Allocator,
    expected_glyph: GlyphModel,
    actual_glyph: GlyphModel,
) !GlyphPairComparison {
    const advance_abs_diff = @abs(expected_glyph.advance - actual_glyph.advance);

    const expected_bounds = expected_glyph.bounds();
    const actual_bounds = actual_glyph.bounds();
    var glyph_max_bounds_abs_diff: f32 = 0.0;
    for (expected_bounds, actual_bounds) |lhs, rhs| {
        glyph_max_bounds_abs_diff = @max(glyph_max_bounds_abs_diff, @abs(lhs - rhs));
    }

    const horizontal_band_count_diff: i32 = @intCast(@as(i32, @intCast(expected_glyph.horizontal_bands.len)) - @as(i32, @intCast(actual_glyph.horizontal_bands.len)));
    const vertical_band_count_diff: i32 = @intCast(@as(i32, @intCast(expected_glyph.vertical_bands.len)) - @as(i32, @intCast(actual_glyph.vertical_bands.len)));
    const polygon_count_diff: i32 = @intCast(@as(i32, expected_glyph.polygon_count) - @as(i32, actual_glyph.polygon_count));
    const total_curve_ref_diff: i32 = @intCast(@as(i32, @intCast(expected_glyph.totalCurveRefs())) - @as(i32, @intCast(actual_glyph.totalCurveRefs())));

    var official_curve_ref_missing_count: usize = 0;
    var official_curve_ref_extra_count: usize = 0;
    if (expected_glyph.official_curve_refs.len > 0) {
        const actual_curve_refs = try collectUniqueCurveRefs(allocator, actual_glyph);
        defer allocator.free(actual_curve_refs);
        const official_curve_ref_diff = diffSortedCurveRefs(expected_glyph.official_curve_refs, actual_curve_refs);
        official_curve_ref_missing_count = official_curve_ref_diff.missing_count;
        official_curve_ref_extra_count = official_curve_ref_diff.extra_count;
    }

    return .{
        .invisible_mismatch = expected_glyph.visible != actual_glyph.visible,
        .advance_abs_diff = advance_abs_diff,
        .max_bounds_abs_diff = glyph_max_bounds_abs_diff,
        .horizontal_band_count_diff = horizontal_band_count_diff,
        .vertical_band_count_diff = vertical_band_count_diff,
        .horizontal_band_payload_mismatch = !bandsEquivalent(expected_glyph.horizontal_bands, actual_glyph.horizontal_bands),
        .vertical_band_payload_mismatch = !bandsEquivalent(expected_glyph.vertical_bands, actual_glyph.vertical_bands),
        .polygon_count_diff = polygon_count_diff,
        .total_curve_ref_diff = total_curve_ref_diff,
        .official_curve_ref_missing_count = official_curve_ref_missing_count,
        .official_curve_ref_extra_count = official_curve_ref_extra_count,
    };
}

pub fn compareCurveGeometry(
    allocator: std.mem.Allocator,
    expected_glyph: GlyphModel,
    actual_glyph: GlyphModel,
) !CurveGeometryDiff {
    const expected_curves = try collectUniqueCurveGeometryKeys(allocator, expected_glyph);
    defer allocator.free(expected_curves);
    const actual_curves = try collectUniqueCurveGeometryKeys(allocator, actual_glyph);
    defer allocator.free(actual_curves);

    const diff = diffSortedCurveGeometry(expected_curves, actual_curves);
    return .{
        .missing_count = diff.missing_count,
        .extra_count = diff.extra_count,
    };
}

fn collectUniqueCurveRefs(allocator: std.mem.Allocator, glyph: GlyphModel) ![]u32 {
    var refs = std.ArrayList(u32).empty;
    errdefer refs.deinit(allocator);

    for (glyph.horizontal_bands) |band| {
        for (band.curves) |curve| {
            try refs.append(allocator, curve.texel_index);
        }
    }
    for (glyph.vertical_bands) |band| {
        for (band.curves) |curve| {
            try refs.append(allocator, curve.texel_index);
        }
    }

    std.mem.sort(u32, refs.items, {}, std.sort.asc(u32));

    var unique_len: usize = 0;
    for (refs.items) |ref| {
        if (unique_len == 0 or refs.items[unique_len - 1] != ref) {
            refs.items[unique_len] = ref;
            unique_len += 1;
        }
    }
    refs.shrinkRetainingCapacity(unique_len);
    return refs.toOwnedSlice(allocator);
}

const CurveGeometryKey = struct {
    values: [6]i32,
};

fn collectUniqueCurveGeometryKeys(allocator: std.mem.Allocator, glyph: GlyphModel) ![]CurveGeometryKey {
    var keys = std.ArrayList(CurveGeometryKey).empty;
    errdefer keys.deinit(allocator);

    try appendUniqueCurveGeometryKeys(&keys, allocator, glyph.horizontal_bands);
    try appendUniqueCurveGeometryKeys(&keys, allocator, glyph.vertical_bands);

    std.mem.sort(CurveGeometryKey, keys.items, {}, curveGeometryKeyLessThan);

    var unique_len: usize = 0;
    for (keys.items) |key| {
        if (unique_len == 0 or !std.meta.eql(keys.items[unique_len - 1], key)) {
            keys.items[unique_len] = key;
            unique_len += 1;
        }
    }
    keys.shrinkRetainingCapacity(unique_len);
    return keys.toOwnedSlice(allocator);
}

fn appendUniqueCurveGeometryKeys(
    keys: *std.ArrayList(CurveGeometryKey),
    allocator: std.mem.Allocator,
    bands: []const BandModel,
) !void {
    for (bands) |band| {
        for (band.curves) |curve| {
            try keys.append(allocator, .{
                .values = .{
                    quantizeCurveValue(curve.texel0[0]),
                    quantizeCurveValue(curve.texel0[1]),
                    quantizeCurveValue(curve.texel0[2]),
                    quantizeCurveValue(curve.texel0[3]),
                    quantizeCurveValue(curve.texel1[0]),
                    quantizeCurveValue(curve.texel1[1]),
                },
            });
        }
    }
}

fn quantizeCurveValue(value: f32) i32 {
    return @intFromFloat(@round(value * 10000.0));
}

fn curveGeometryKeyLessThan(_: void, lhs: CurveGeometryKey, rhs: CurveGeometryKey) bool {
    for (lhs.values, rhs.values) |lhs_value, rhs_value| {
        if (lhs_value != rhs_value) return lhs_value < rhs_value;
    }
    return false;
}

fn diffSortedCurveRefs(expected: []const u32, actual: []const u32) CurveRefDiff {
    var expected_index: usize = 0;
    var actual_index: usize = 0;
    var missing_count: usize = 0;
    var extra_count: usize = 0;

    while (expected_index < expected.len and actual_index < actual.len) {
        const lhs = expected[expected_index];
        const rhs = actual[actual_index];
        if (lhs == rhs) {
            expected_index += 1;
            actual_index += 1;
        } else if (lhs < rhs) {
            missing_count += 1;
            expected_index += 1;
        } else {
            extra_count += 1;
            actual_index += 1;
        }
    }

    missing_count += expected.len - expected_index;
    extra_count += actual.len - actual_index;
    return .{
        .missing_count = missing_count,
        .extra_count = extra_count,
    };
}

fn diffSortedCurveGeometry(expected: []const CurveGeometryKey, actual: []const CurveGeometryKey) CurveRefDiff {
    var expected_index: usize = 0;
    var actual_index: usize = 0;
    var missing_count: usize = 0;
    var extra_count: usize = 0;

    while (expected_index < expected.len and actual_index < actual.len) {
        const lhs = expected[expected_index];
        const rhs = actual[actual_index];
        if (std.meta.eql(lhs, rhs)) {
            expected_index += 1;
            actual_index += 1;
        } else if (curveGeometryKeyLessThan({}, lhs, rhs)) {
            missing_count += 1;
            expected_index += 1;
        } else {
            extra_count += 1;
            actual_index += 1;
        }
    }

    missing_count += expected.len - expected_index;
    extra_count += actual.len - actual_index;
    return .{
        .missing_count = missing_count,
        .extra_count = extra_count,
    };
}

fn bandsEquivalent(lhs: []const BandModel, rhs: []const BandModel) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_band, rhs_band| {
        if (lhs_band.curve_count != rhs_band.curve_count) return false;
        if (lhs_band.curves.len != rhs_band.curves.len) return false;
        for (lhs_band.curves, rhs_band.curves) |lhs_curve, rhs_curve| {
            if (lhs_curve.texel_index != rhs_curve.texel_index) return false;
            if (!texelApproxEq(lhs_curve.texel0, rhs_curve.texel0, 0.001)) return false;
            if (!texelApproxEq(lhs_curve.texel1, rhs_curve.texel1, 0.001)) return false;
        }
    }
    return true;
}

fn texelApproxEq(lhs: [4]f32, rhs: [4]f32, tolerance: f32) bool {
    for (lhs, rhs) |lhs_value, rhs_value| {
        if (@abs(lhs_value - rhs_value) > tolerance) return false;
    }
    return true;
}

test "fromRuntimeFont decodes glyph band references into canonical model" {
    const allocator = std.testing.allocator;

    var glyphs = std.AutoHashMap(u32, runtime.RuntimeGlyph).init(allocator);
    defer glyphs.deinit();
    try glyphs.put(7, .{
        .glyph_index = 7,
        .bbox = .{ 0.0, 0.0, 10.0, 12.0 },
        .glyph_offset = .{ 1.0, -2.0 },
        .advance = 14.0,
        .visible = true,
        .band_location = .{ 0, 0 },
        .band_count = .{ 1, 1 },
        .band_scale = .{ 0.1, 0.2 },
        .polygon_count = 4,
        .polygon_points = .{
            .{ 0.0, 0.0 },
            .{ 0.0, 12.0 },
            .{ 10.0, 12.0 },
            .{ 10.0, 0.0 },
            .{ 0.0, 0.0 },
            .{ 0.0, 0.0 },
        },
    });

    const curves_texels = try allocator.alloc(runtime.CurveTexel, 4);
    defer allocator.free(curves_texels);
    curves_texels[0] = .{ .value = .{ 1.0, 2.0, 3.0, 4.0 } };
    curves_texels[1] = .{ .value = .{ 5.0, 6.0, 7.0, 8.0 } };
    curves_texels[2] = .{ .value = .{ 9.0, 10.0, 11.0, 12.0 } };
    curves_texels[3] = .{ .value = .{ 13.0, 14.0, 15.0, 16.0 } };

    const bands_texels = try allocator.alloc(runtime.BandTexel, 4);
    defer allocator.free(bands_texels);
    bands_texels[0] = .{ .value = .{ 1, 2 } };
    bands_texels[1] = .{ .value = .{ 1, 3 } };
    bands_texels[2] = .{ .value = .{ 0, 0 } };
    bands_texels[3] = .{ .value = .{ 2, 0 } };

    const layout = [_]runtime.LayoutGlyph{
        .{
            .glyph_index = 7,
            .codepoint = 'A',
            .cluster = 0,
            .advance = .{ 14.0, 0.0 },
            .offset = .{ 0.0, 0.0 },
        },
    };
    const layout_glyphs = try allocator.dupe(runtime.LayoutGlyph, &layout);
    defer allocator.free(layout_glyphs);

    const runtime_font = runtime.RuntimeFont{
        .allocator = allocator,
        .curves_width = 2,
        .curves_height = 2,
        .curves_texels = curves_texels,
        .bands_width = 4,
        .bands_height = 1,
        .bands_texels = bands_texels,
        .layout_glyphs = layout_glyphs,
        .glyphs = glyphs,
    };

    var model = try fromRuntimeFont(allocator, runtime_font);
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 1), model.glyphs.len);
    const glyph = model.findGlyph(7).?;
    try std.testing.expectEqual(@as(usize, 0), glyph.official_curve_refs.len);
    try std.testing.expectEqual(@as(usize, 1), glyph.horizontal_bands.len);
    try std.testing.expectEqual(@as(usize, 1), glyph.vertical_bands.len);
    try std.testing.expectEqual(@as(u16, 1), glyph.horizontal_bands[0].curve_count);
    try std.testing.expectEqual(@as(u16, 1), glyph.vertical_bands[0].curve_count);
    try std.testing.expectEqual(@as(u32, 0), glyph.horizontal_bands[0].curves[0].texel_index);
    try std.testing.expectEqual(@as(u32, 2), glyph.vertical_bands[0].curves[0].texel_index);
}

test "compareFontModels reports structured diffs" {
    const allocator = std.testing.allocator;

    const expected_layout = try allocator.dupe(runtime.LayoutGlyph, &[_]runtime.LayoutGlyph{
        .{
            .glyph_index = 7,
            .codepoint = 'A',
            .cluster = 0,
            .advance = .{ 14.0, 0.0 },
            .offset = .{ 0.0, 0.0 },
        },
    });
    defer allocator.free(expected_layout);
    const actual_layout = try allocator.dupe(runtime.LayoutGlyph, &[_]runtime.LayoutGlyph{
        .{
            .glyph_index = 7,
            .codepoint = 'A',
            .cluster = 0,
            .advance = .{ 10.0, 0.0 },
            .offset = .{ 0.0, 0.0 },
        },
    });
    defer allocator.free(actual_layout);

    const expected_horizontal_curves = try allocator.dupe(PackedCurve, &[_]PackedCurve{
        .{ .texel_index = 0, .texel0 = .{ 1.0, 2.0, 3.0, 4.0 }, .texel1 = .{ 5.0, 6.0, 7.0, 8.0 } },
    });
    defer allocator.free(expected_horizontal_curves);
    const expected_horizontal_bands = try allocator.dupe(BandModel, &[_]BandModel{
        .{ .curve_count = 1, .curves = expected_horizontal_curves },
    });
    defer allocator.free(expected_horizontal_bands);
    const expected_vertical_bands = try allocator.alloc(BandModel, 0);
    defer allocator.free(expected_vertical_bands);

    const actual_horizontal_bands = try allocator.alloc(BandModel, 0);
    defer allocator.free(actual_horizontal_bands);
    const actual_vertical_bands = try allocator.alloc(BandModel, 0);
    defer allocator.free(actual_vertical_bands);

    const expected_glyphs = try allocator.dupe(GlyphModel, &[_]GlyphModel{
        .{
            .glyph_index = 7,
            .visible = true,
            .advance = 14.0,
            .bbox = .{ 0.0, 0.0, 10.0, 12.0 },
            .glyph_offset = .{ 1.0, -2.0 },
            .band_scale = .{ 0.1, 0.2 },
            .polygon_count = 4,
            .polygon_points = .{
                .{ 0.0, 0.0 }, .{ 0.0, 12.0 }, .{ 10.0, 12.0 }, .{ 10.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
            },
            .official_curve_refs = try allocator.dupe(u32, &[_]u32{ 0, 9 }),
            .horizontal_bands = expected_horizontal_bands,
            .vertical_bands = expected_vertical_bands,
        },
    });
    defer {
        for (expected_glyphs) |glyph| allocator.free(glyph.official_curve_refs);
        allocator.free(expected_glyphs);
    }

    const actual_glyphs = try allocator.dupe(GlyphModel, &[_]GlyphModel{
        .{
            .glyph_index = 7,
            .visible = true,
            .advance = 10.0,
            .bbox = .{ 0.0, 0.0, 8.0, 12.0 },
            .glyph_offset = .{ 1.0, -2.0 },
            .band_scale = .{ 0.1, 0.2 },
            .polygon_count = 4,
            .polygon_points = .{
                .{ 0.0, 0.0 }, .{ 0.0, 12.0 }, .{ 8.0, 12.0 }, .{ 8.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
            },
            .official_curve_refs = try allocator.alloc(u32, 0),
            .horizontal_bands = actual_horizontal_bands,
            .vertical_bands = actual_vertical_bands,
        },
    });
    defer {
        for (actual_glyphs) |glyph| allocator.free(glyph.official_curve_refs);
        allocator.free(actual_glyphs);
    }

    const expected = FontModel{
        .allocator = allocator,
        .layout_glyphs = expected_layout,
        .glyphs = expected_glyphs,
    };
    const actual = FontModel{
        .allocator = allocator,
        .layout_glyphs = actual_layout,
        .glyphs = actual_glyphs,
    };

    var report = try compareFontModels(allocator, expected, actual);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 1), report.glyph_diffs.len);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), report.max_advance_abs_diff, 0.001);
    try std.testing.expect(report.max_bounds_abs_diff >= 2.0);
    try std.testing.expectEqual(@as(usize, 1), report.horizontal_band_count_mismatches);
    try std.testing.expectEqual(@as(usize, 1), report.horizontal_band_payload_mismatches);
    try std.testing.expectEqual(@as(usize, 1), report.total_curve_ref_mismatches);
    try std.testing.expectEqual(@as(usize, 1), report.official_curve_ref_mismatches);
    try std.testing.expectEqual(@as(usize, 2), report.official_curve_ref_missing_total);
    try std.testing.expectEqual(@as(usize, 0), report.official_curve_ref_extra_total);
    try std.testing.expectEqual(@as(usize, 2), report.glyph_diffs[0].official_curve_ref_missing_count);
    try std.testing.expectEqual(@as(usize, 0), report.glyph_diffs[0].official_curve_ref_extra_count);
}

test "summarizeBands reports curve-count structure" {
    const allocator = std.testing.allocator;

    const curves_a = try allocator.dupe(PackedCurve, &[_]PackedCurve{
        .{ .texel_index = 1, .texel0 = .{ 0.0, 0.0, 0.0, 0.0 }, .texel1 = .{ 0.0, 0.0, 0.0, 0.0 } },
        .{ .texel_index = 2, .texel0 = .{ 0.0, 0.0, 0.0, 0.0 }, .texel1 = .{ 0.0, 0.0, 0.0, 0.0 } },
    });
    defer allocator.free(curves_a);
    const curves_b = try allocator.alloc(PackedCurve, 0);
    defer allocator.free(curves_b);
    const curves_c = try allocator.dupe(PackedCurve, &[_]PackedCurve{
        .{ .texel_index = 3, .texel0 = .{ 0.0, 0.0, 0.0, 0.0 }, .texel1 = .{ 0.0, 0.0, 0.0, 0.0 } },
    });
    defer allocator.free(curves_c);

    const bands = [_]BandModel{
        .{ .curve_count = 2, .curves = curves_a },
        .{ .curve_count = 0, .curves = curves_b },
        .{ .curve_count = 1, .curves = curves_c },
    };

    var summary = try summarizeBands(allocator, &bands);
    defer summary.deinit();

    try std.testing.expectEqualSlices(u16, &[_]u16{ 2, 0, 1 }, summary.curve_counts);
    try std.testing.expectEqual(@as(usize, 2), summary.non_empty_count);
    try std.testing.expectEqual(@as(usize, 3), summary.total_curve_refs);
    try std.testing.expectEqual(@as(u16, 2), summary.max_curve_count);
}

test "compareFontModels is zero for identical canonical data" {
    const allocator = std.testing.allocator;

    const curves = try allocator.dupe(PackedCurve, &[_]PackedCurve{
        .{ .texel_index = 4, .texel0 = .{ 1.0, 2.0, 3.0, 4.0 }, .texel1 = .{ 5.0, 6.0, 7.0, 8.0 } },
    });
    defer allocator.free(curves);
    const bands = try allocator.dupe(BandModel, &[_]BandModel{
        .{ .curve_count = 1, .curves = curves },
    });
    defer allocator.free(bands);
    const empty_bands = try allocator.alloc(BandModel, 0);
    defer allocator.free(empty_bands);
    const layout = try allocator.dupe(runtime.LayoutGlyph, &[_]runtime.LayoutGlyph{
        .{
            .glyph_index = 9,
            .codepoint = 'Z',
            .cluster = 0,
            .advance = .{ 7.0, 0.0 },
            .offset = .{ 0.0, 0.0 },
        },
    });
    defer allocator.free(layout);
    const glyphs = try allocator.dupe(GlyphModel, &[_]GlyphModel{
        .{
            .glyph_index = 9,
            .visible = true,
            .advance = 7.0,
            .bbox = .{ 0.0, 0.0, 5.0, 9.0 },
            .glyph_offset = .{ 0.0, 0.0 },
            .band_scale = .{ 0.2, 0.3 },
            .polygon_count = 4,
            .polygon_points = .{
                .{ 0.0, 0.0 }, .{ 0.0, 9.0 }, .{ 5.0, 9.0 }, .{ 5.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
            },
            .official_curve_refs = try allocator.dupe(u32, &[_]u32{4}),
            .horizontal_bands = bands,
            .vertical_bands = empty_bands,
        },
    });
    defer {
        for (glyphs) |glyph| allocator.free(glyph.official_curve_refs);
        allocator.free(glyphs);
    }

    const model = FontModel{
        .allocator = allocator,
        .layout_glyphs = layout,
        .glyphs = glyphs,
    };

    var report = try compareFontModels(allocator, model, model);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 0), report.layout_codepoint_mismatches);
    try std.testing.expectEqual(@as(usize, 0), report.missing_expected_glyphs);
    try std.testing.expectEqual(@as(usize, 0), report.missing_actual_glyphs);
    try std.testing.expectEqual(@as(usize, 0), report.invisible_mismatches);
    try std.testing.expectEqual(@as(f32, 0.0), report.max_advance_abs_diff);
    try std.testing.expectEqual(@as(f32, 0.0), report.max_bounds_abs_diff);
    try std.testing.expectEqual(@as(usize, 0), report.horizontal_band_count_mismatches);
    try std.testing.expectEqual(@as(usize, 0), report.vertical_band_count_mismatches);
    try std.testing.expectEqual(@as(usize, 0), report.horizontal_band_payload_mismatches);
    try std.testing.expectEqual(@as(usize, 0), report.vertical_band_payload_mismatches);
    try std.testing.expectEqual(@as(usize, 0), report.polygon_count_mismatches);
    try std.testing.expectEqual(@as(usize, 0), report.total_curve_ref_mismatches);
    try std.testing.expectEqual(@as(usize, 0), report.official_curve_ref_mismatches);
    try std.testing.expectEqual(@as(usize, 0), report.official_curve_ref_missing_total);
    try std.testing.expectEqual(@as(usize, 0), report.official_curve_ref_extra_total);
}

test "compareCurveGeometry ignores duplicated band references" {
    const allocator = std.testing.allocator;

    const curves = try allocator.dupe(PackedCurve, &[_]PackedCurve{
        .{ .texel_index = 1, .texel0 = .{ 0.1, 0.2, 0.3, 0.4 }, .texel1 = .{ 0.5, 0.6, 0.7, 0.8 } },
    });
    defer allocator.free(curves);
    const duplicated_bands = try allocator.dupe(BandModel, &[_]BandModel{
        .{ .curve_count = 1, .curves = curves },
        .{ .curve_count = 1, .curves = curves },
    });
    defer allocator.free(duplicated_bands);
    const empty_bands = try allocator.alloc(BandModel, 0);
    defer allocator.free(empty_bands);

    const expected = GlyphModel{
        .glyph_index = 1,
        .visible = true,
        .advance = 1.0,
        .bbox = .{ 0.0, 0.0, 1.0, 1.0 },
        .glyph_offset = .{ 0.0, 0.0 },
        .band_scale = .{ 1.0, 1.0 },
        .polygon_count = 4,
        .polygon_points = std.mem.zeroes([6]runtime.Point),
        .official_curve_refs = &.{},
        .horizontal_bands = duplicated_bands[0..1],
        .vertical_bands = empty_bands,
    };
    const actual = GlyphModel{
        .glyph_index = 2,
        .visible = true,
        .advance = 1.0,
        .bbox = .{ 0.0, 0.0, 1.0, 1.0 },
        .glyph_offset = .{ 0.0, 0.0 },
        .band_scale = .{ 1.0, 1.0 },
        .polygon_count = 4,
        .polygon_points = std.mem.zeroes([6]runtime.Point),
        .official_curve_refs = &.{},
        .horizontal_bands = duplicated_bands,
        .vertical_bands = empty_bands,
    };

    const diff = try compareCurveGeometry(allocator, expected, actual);
    try std.testing.expectEqual(@as(usize, 0), diff.missing_count);
    try std.testing.expectEqual(@as(usize, 0), diff.extra_count);
}

test "compareFontModelsByLayout aligns codepoints despite different glyph ids" {
    const allocator = std.testing.allocator;

    const expected_layout = try allocator.dupe(runtime.LayoutGlyph, &[_]runtime.LayoutGlyph{
        .{
            .glyph_index = 7,
            .codepoint = 'A',
            .cluster = 0,
            .advance = .{ 14.0, 0.0 },
            .offset = .{ 0.0, 0.0 },
        },
    });
    defer allocator.free(expected_layout);
    const actual_layout = try allocator.dupe(runtime.LayoutGlyph, &[_]runtime.LayoutGlyph{
        .{
            .glyph_index = 9,
            .codepoint = 'A',
            .cluster = 0,
            .advance = .{ 14.0, 0.0 },
            .offset = .{ 0.0, 0.0 },
        },
    });
    defer allocator.free(actual_layout);

    const expected_glyphs = try allocator.dupe(GlyphModel, &[_]GlyphModel{
        .{
            .glyph_index = 7,
            .visible = true,
            .advance = 14.0,
            .bbox = .{ 0.0, 0.0, 10.0, 12.0 },
            .glyph_offset = .{ 0.0, 0.0 },
            .band_scale = .{ 0.1, 0.1 },
            .polygon_count = 4,
            .polygon_points = .{
                .{ 0.0, 0.0 }, .{ 0.0, 12.0 }, .{ 10.0, 12.0 }, .{ 10.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
            },
            .official_curve_refs = try allocator.alloc(u32, 0),
            .horizontal_bands = try allocator.alloc(BandModel, 0),
            .vertical_bands = try allocator.alloc(BandModel, 0),
        },
    });
    defer {
        for (expected_glyphs) |glyph| allocator.free(glyph.official_curve_refs);
        allocator.free(expected_glyphs[0].horizontal_bands);
        allocator.free(expected_glyphs[0].vertical_bands);
        allocator.free(expected_glyphs);
    }

    const actual_glyphs = try allocator.dupe(GlyphModel, &[_]GlyphModel{
        .{
            .glyph_index = 9,
            .visible = true,
            .advance = 14.0,
            .bbox = .{ 0.0, 0.0, 10.0, 12.0 },
            .glyph_offset = .{ 0.0, 0.0 },
            .band_scale = .{ 0.1, 0.1 },
            .polygon_count = 4,
            .polygon_points = .{
                .{ 0.0, 0.0 }, .{ 0.0, 12.0 }, .{ 10.0, 12.0 }, .{ 10.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
            },
            .official_curve_refs = try allocator.alloc(u32, 0),
            .horizontal_bands = try allocator.alloc(BandModel, 0),
            .vertical_bands = try allocator.alloc(BandModel, 0),
        },
    });
    defer {
        for (actual_glyphs) |glyph| allocator.free(glyph.official_curve_refs);
        allocator.free(actual_glyphs[0].horizontal_bands);
        allocator.free(actual_glyphs[0].vertical_bands);
        allocator.free(actual_glyphs);
    }

    const expected = FontModel{
        .allocator = allocator,
        .layout_glyphs = expected_layout,
        .glyphs = expected_glyphs,
    };
    const actual = FontModel{
        .allocator = allocator,
        .layout_glyphs = actual_layout,
        .glyphs = actual_glyphs,
    };

    var report = try compareFontModelsByLayout(allocator, expected, actual);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 1), report.layout_glyph_id_mismatches);
    try std.testing.expectEqual(@as(usize, 0), report.missing_expected_glyphs);
    try std.testing.expectEqual(@as(usize, 0), report.missing_actual_glyphs);
    try std.testing.expectEqual(@as(usize, 1), report.glyph_diffs.len);
    try std.testing.expectEqual(@as(f32, 0.0), report.max_advance_abs_diff);
    try std.testing.expectEqual(@as(f32, 0.0), report.max_bounds_abs_diff);
}

test "attachOfficialCurveRefs decorates matching glyphs" {
    const allocator = std.testing.allocator;

    const layout = try allocator.dupe(runtime.LayoutGlyph, &[_]runtime.LayoutGlyph{});
    defer allocator.free(layout);
    const glyphs = try allocator.dupe(GlyphModel, &[_]GlyphModel{
        .{
            .glyph_index = 0,
            .visible = false,
            .advance = 0.0,
            .bbox = .{ 0.0, 0.0, 0.0, 0.0 },
            .glyph_offset = .{ 0.0, 0.0 },
            .band_scale = .{ 0.0, 0.0 },
            .polygon_count = 0,
            .polygon_points = .{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 } },
            .official_curve_refs = try allocator.alloc(u32, 0),
            .horizontal_bands = try allocator.alloc(BandModel, 0),
            .vertical_bands = try allocator.alloc(BandModel, 0),
        },
        .{
            .glyph_index = 2,
            .visible = true,
            .advance = 1.0,
            .bbox = .{ 0.0, 0.0, 1.0, 1.0 },
            .glyph_offset = .{ 0.0, 0.0 },
            .band_scale = .{ 1.0, 1.0 },
            .polygon_count = 3,
            .polygon_points = .{ .{ 0.0, 0.0 }, .{ 1.0, 0.0 }, .{ 0.0, 1.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 } },
            .official_curve_refs = try allocator.alloc(u32, 0),
            .horizontal_bands = try allocator.alloc(BandModel, 0),
            .vertical_bands = try allocator.alloc(BandModel, 0),
        },
    });
    var model = FontModel{
        .allocator = allocator,
        .layout_glyphs = layout,
        .glyphs = glyphs,
    };
    defer model.deinit();

    var contour_refs = slug_parse.ContourCurveRefTable{
        .allocator = allocator,
        .glyphs = try allocator.dupe(slug_parse.GlyphCurveRefRange, &[_]slug_parse.GlyphCurveRefRange{
            .{ .start = 0, .len = 0 },
            .{ .start = 0, .len = 0 },
            .{ .start = 0, .len = 3 },
        }),
        .curve_refs = try allocator.dupe(u32, &[_]u32{ 7, 3, 5 }),
    };
    defer contour_refs.deinit();

    try attachOfficialCurveRefs(allocator, &model, contour_refs);

    try std.testing.expectEqualSlices(u32, &[_]u32{}, model.glyphs[0].official_curve_refs);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 3, 5, 7 }, model.glyphs[1].official_curve_refs);
}

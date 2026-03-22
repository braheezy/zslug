const std = @import("std");
const font_backend = @import("font_backend.zig");
const font_model = @import("font_model.zig");

pub const RenderConfig = struct {
    pixels_per_em: f32 = 10.0,
};

pub const GlyphMask = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    alpha: []f32,

    pub fn deinit(self: *GlyphMask) void {
        self.allocator.free(self.alpha);
        self.* = undefined;
    }
};

pub const MaskDiffReport = struct {
    width: usize,
    height: usize,
    mean_abs_diff: f32,
    max_abs_diff: f32,
    pixels_over_1pct: usize,
    pixels_over_10pct: usize,
};

pub const GlyphShapeDiff = struct {
    glyph_index: u32,
    codepoint: u32,
    mask: MaskDiffReport,
};

pub fn renderGlyphMask(
    allocator: std.mem.Allocator,
    glyph: font_model.GlyphModel,
    config: RenderConfig,
) !GlyphMask {
    return renderGlyphMaskInBounds(allocator, glyph, glyph.bbox, config);
}

pub fn compareGlyphMasks(
    allocator: std.mem.Allocator,
    lhs: font_model.GlyphModel,
    rhs: font_model.GlyphModel,
    config: RenderConfig,
) !MaskDiffReport {
    const bounds = unionBounds(lhs.bbox, rhs.bbox);
    var lhs_mask = try renderGlyphMaskInBounds(allocator, lhs, bounds, config);
    defer lhs_mask.deinit();
    var rhs_mask = try renderGlyphMaskInBounds(allocator, rhs, bounds, config);
    defer rhs_mask.deinit();

    var sum_abs_diff: f32 = 0.0;
    var max_abs_diff: f32 = 0.0;
    var pixels_over_1pct: usize = 0;
    var pixels_over_10pct: usize = 0;
    for (lhs_mask.alpha, rhs_mask.alpha) |lhs_alpha, rhs_alpha| {
        const abs_diff = @abs(lhs_alpha - rhs_alpha);
        sum_abs_diff += abs_diff;
        max_abs_diff = @max(max_abs_diff, abs_diff);
        if (abs_diff > 0.01) pixels_over_1pct += 1;
        if (abs_diff > 0.10) pixels_over_10pct += 1;
    }

    const pixel_count = @as(f32, @floatFromInt(lhs_mask.alpha.len));
    return .{
        .width = lhs_mask.width,
        .height = lhs_mask.height,
        .mean_abs_diff = if (pixel_count > 0.0) sum_abs_diff / pixel_count else 0.0,
        .max_abs_diff = max_abs_diff,
        .pixels_over_1pct = pixels_over_1pct,
        .pixels_over_10pct = pixels_over_10pct,
    };
}

pub fn compareSharedLayoutGlyphs(
    allocator: std.mem.Allocator,
    expected: font_model.FontModel,
    actual: font_model.FontModel,
    config: RenderConfig,
) ![]GlyphShapeDiff {
    const shared_layout_count = @min(expected.layout_glyphs.len, actual.layout_glyphs.len);
    var diffs = std.ArrayList(GlyphShapeDiff).empty;
    errdefer diffs.deinit(allocator);

    for (0..shared_layout_count) |i| {
        const expected_layout = expected.layout_glyphs[i];
        const actual_layout = actual.layout_glyphs[i];
        if (expected_layout.codepoint != actual_layout.codepoint) continue;

        const expected_glyph = expected.findGlyph(expected_layout.glyph_index) orelse continue;
        const actual_glyph = actual.findGlyph(actual_layout.glyph_index) orelse continue;
        if (!expected_glyph.visible or !actual_glyph.visible) continue;

        try diffs.append(allocator, .{
            .glyph_index = expected_layout.glyph_index,
            .codepoint = expected_layout.codepoint,
            .mask = try compareGlyphMasks(allocator, expected_glyph, actual_glyph, config),
        });
    }

    return diffs.toOwnedSlice(allocator);
}

fn renderGlyphMaskInBounds(
    allocator: std.mem.Allocator,
    glyph: font_model.GlyphModel,
    bounds: [4]f32,
    config: RenderConfig,
) !GlyphMask {
    const width_units = @max(bounds[2] - bounds[0], 1.0 / 1024.0);
    const height_units = @max(bounds[3] - bounds[1], 1.0 / 1024.0);
    const width: usize = @max(1, @as(usize, @intFromFloat(@ceil(width_units * config.pixels_per_em))));
    const height: usize = @max(1, @as(usize, @intFromFloat(@ceil(height_units * config.pixels_per_em))));
    const alpha = try allocator.alloc(f32, width * height);
    errdefer allocator.free(alpha);

    const pixels_per_em = [2]f32{
        @as(f32, @floatFromInt(width)) / width_units,
        @as(f32, @floatFromInt(height)) / height_units,
    };

    for (0..height) |y| {
        for (0..width) |x| {
            const render_coord = [2]f32{
                bounds[0] + (@as(f32, @floatFromInt(x)) + 0.5) / pixels_per_em[0],
                bounds[1] + (@as(f32, @floatFromInt(height - 1 - y)) + 0.5) / pixels_per_em[1],
            };
            alpha[y * width + x] = if (glyph.visible)
                slugRender(glyph, render_coord, pixels_per_em)
            else
                0.0;
        }
    }

    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .alpha = alpha,
    };
}

fn slugRender(glyph: font_model.GlyphModel, render_coord: [2]f32, pixels_per_em: [2]f32) f32 {
    if (!glyph.visible or glyph.horizontal_bands.len == 0 or glyph.vertical_bands.len == 0) return 0.0;

    const band_max = [2]i32{
        @as(i32, @intCast(glyph.vertical_bands.len - 1)),
        @as(i32, @intCast(glyph.horizontal_bands.len - 1)),
    };
    const band_index = [2]i32{
        clampI32(
            @as(i32, @intFromFloat(render_coord[0] * glyph.band_scale[0] - glyph.bbox[0] * glyph.band_scale[0])),
            0,
            band_max[0],
        ),
        clampI32(
            @as(i32, @intFromFloat(render_coord[1] * glyph.band_scale[1] - glyph.bbox[1] * glyph.band_scale[1])),
            0,
            band_max[1],
        ),
    };

    var xcov: f32 = 0.0;
    var xwgt: f32 = 0.0;
    const hband = glyph.horizontal_bands[@intCast(band_index[1])];
    for (hband.curves) |curve| {
        const p12 = [4]f32{
            curve.texel0[0] - render_coord[0],
            curve.texel0[1] - render_coord[1],
            curve.texel0[2] - render_coord[0],
            curve.texel0[3] - render_coord[1],
        };
        const p3 = [2]f32{
            curve.texel1[0] - render_coord[0],
            curve.texel1[1] - render_coord[1],
        };
        if (@max(@max(p12[0], p12[2]), p3[0]) * pixels_per_em[0] < -0.5) break;
        const code = calcRootCode(p12[1], p12[3], p3[1]);
        if (code != 0) {
            const r = solveHorizPoly(p12, p3);
            const rx = [2]f32{ r[0] * pixels_per_em[0], r[1] * pixels_per_em[0] };
            if ((code & 1) != 0) {
                xcov += clampf(rx[0] + 0.5, 0.0, 1.0);
                xwgt = @max(xwgt, clampf(1.0 - @abs(rx[0]) * 2.0, 0.0, 1.0));
            }
            if (code > 1) {
                xcov -= clampf(rx[1] + 0.5, 0.0, 1.0);
                xwgt = @max(xwgt, clampf(1.0 - @abs(rx[1]) * 2.0, 0.0, 1.0));
            }
        }
    }

    var ycov: f32 = 0.0;
    var ywgt: f32 = 0.0;
    const vband = glyph.vertical_bands[@intCast(band_index[0])];
    for (vband.curves) |curve| {
        const p12 = [4]f32{
            curve.texel0[0] - render_coord[0],
            curve.texel0[1] - render_coord[1],
            curve.texel0[2] - render_coord[0],
            curve.texel0[3] - render_coord[1],
        };
        const p3 = [2]f32{
            curve.texel1[0] - render_coord[0],
            curve.texel1[1] - render_coord[1],
        };
        if (@max(@max(p12[1], p12[3]), p3[1]) * pixels_per_em[1] < -0.5) break;
        const code = calcRootCode(p12[0], p12[2], p3[0]);
        if (code != 0) {
            const r = solveVertPoly(p12, p3);
            const ry = [2]f32{ r[0] * pixels_per_em[1], r[1] * pixels_per_em[1] };
            if ((code & 1) != 0) {
                ycov -= clampf(ry[0] + 0.5, 0.0, 1.0);
                ywgt = @max(ywgt, clampf(1.0 - @abs(ry[0]) * 2.0, 0.0, 1.0));
            }
            if (code > 1) {
                ycov += clampf(ry[1] + 0.5, 0.0, 1.0);
                ywgt = @max(ywgt, clampf(1.0 - @abs(ry[1]) * 2.0, 0.0, 1.0));
            }
        }
    }

    return calcCoverage(xcov, ycov, xwgt, ywgt);
}

fn calcRootCode(y1: f32, y2: f32, y3: f32) u32 {
    const sign1 = (@as(u32, @bitCast(y1)) >> 31);
    const sign2 = (@as(u32, @bitCast(y2)) >> 30);
    const sign3 = (@as(u32, @bitCast(y3)) >> 29);
    var shift = (sign2 & 2) | (sign1 & ~@as(u32, 2));
    shift = (sign3 & 4) | (shift & ~@as(u32, 4));
    return (@as(u32, 0x2E74) >> @as(u3, @intCast(shift))) & 0x0101;
}

fn solveHorizPoly(p12: [4]f32, p3: [2]f32) [2]f32 {
    const a = [2]f32{
        p12[0] - p12[2] * 2.0 + p3[0],
        p12[1] - p12[3] * 2.0 + p3[1],
    };
    const b = [2]f32{
        p12[0] - p12[2],
        p12[1] - p12[3],
    };
    const ra = 1.0 / a[1];
    const rb = 0.5 / b[1];

    const d = @sqrt(@max(b[1] * b[1] - a[1] * p12[1], 0.0));
    var t1 = (b[1] - d) * ra;
    var t2 = (b[1] + d) * ra;
    if (@abs(a[1]) < 1.0 / 65536.0) {
        t1 = p12[1] * rb;
        t2 = t1;
    }

    return .{
        (a[0] * t1 - b[0] * 2.0) * t1 + p12[0],
        (a[0] * t2 - b[0] * 2.0) * t2 + p12[0],
    };
}

fn solveVertPoly(p12: [4]f32, p3: [2]f32) [2]f32 {
    const a = [2]f32{
        p12[0] - p12[2] * 2.0 + p3[0],
        p12[1] - p12[3] * 2.0 + p3[1],
    };
    const b = [2]f32{
        p12[0] - p12[2],
        p12[1] - p12[3],
    };
    const ra = 1.0 / a[0];
    const rb = 0.5 / b[0];

    const d = @sqrt(@max(b[0] * b[0] - a[0] * p12[0], 0.0));
    var t1 = (b[0] - d) * ra;
    var t2 = (b[0] + d) * ra;
    if (@abs(a[0]) < 1.0 / 65536.0) {
        t1 = p12[0] * rb;
        t2 = t1;
    }

    return .{
        (a[1] * t1 - b[1] * 2.0) * t1 + p12[1],
        (a[1] * t2 - b[1] * 2.0) * t2 + p12[1],
    };
}

fn calcCoverage(xcov: f32, ycov: f32, xwgt: f32, ywgt: f32) f32 {
    return clampf(
        @max(
            @abs(xcov * xwgt + ycov * ywgt) / @max(xwgt + ywgt, 1.0 / 65536.0),
            @min(@abs(xcov), @abs(ycov)),
        ),
        0.0,
        1.0,
    );
}

fn unionBounds(a: [4]f32, b: [4]f32) [4]f32 {
    return .{
        @min(a[0], b[0]),
        @min(a[1], b[1]),
        @max(a[2], b[2]),
        @max(a[3], b[3]),
    };
}

fn clampI32(value: i32, min_value: i32, max_value: i32) i32 {
    return @max(min_value, @min(max_value, value));
}

fn clampf(value: f32, min_value: f32, max_value: f32) f32 {
    return @max(min_value, @min(max_value, value));
}

test "glyph mask diff is zero for identical glyphs" {
    const allocator = std.testing.allocator;
    if (!canOpenRelative("SlugDemo/Fonts/georgia_nc.slug")) return error.SkipZigTest;

    var font = try font_backend.loadRuntimeFont(allocator, .{
        .text = "MW",
        .slug_path = "SlugDemo/Fonts/georgia_nc.slug",
        .backend = .slug_reference,
    });
    defer font.deinit();

    var model = try font_model.fromRuntimeFont(allocator, font);
    defer model.deinit();

    const glyph_m = model.findGlyph(model.layout_glyphs[0].glyph_index).?;
    const diff = try compareGlyphMasks(allocator, glyph_m, glyph_m, .{});

    try std.testing.expectEqual(@as(f32, 0.0), diff.mean_abs_diff);
    try std.testing.expectEqual(@as(f32, 0.0), diff.max_abs_diff);
    try std.testing.expectEqual(@as(usize, 0), diff.pixels_over_1pct);
    try std.testing.expectEqual(@as(usize, 0), diff.pixels_over_10pct);
}

test "glyph mask diff distinguishes different glyph shapes" {
    const allocator = std.testing.allocator;
    if (!canOpenRelative("SlugDemo/Fonts/georgia_nc.slug")) return error.SkipZigTest;

    var font = try font_backend.loadRuntimeFont(allocator, .{
        .text = "MW",
        .slug_path = "SlugDemo/Fonts/georgia_nc.slug",
        .backend = .slug_reference,
    });
    defer font.deinit();

    var model = try font_model.fromRuntimeFont(allocator, font);
    defer model.deinit();

    const glyph_m = model.findGlyph(model.layout_glyphs[0].glyph_index).?;
    const glyph_w = model.findGlyph(model.layout_glyphs[1].glyph_index).?;
    const diff = try compareGlyphMasks(allocator, glyph_m, glyph_w, .{});

    try std.testing.expect(diff.mean_abs_diff > 0.01);
    try std.testing.expect(diff.max_abs_diff > 0.1);
    try std.testing.expect(diff.pixels_over_10pct > 0);
}

test "reference and native glyph mask comparison runs" {
    const allocator = std.testing.allocator;
    const font_path = findArialFontPath() orelse return error.SkipZigTest;
    if (!canOpenRelative("SlugDemo/Fonts/arial.slug")) return error.SkipZigTest;

    var reference_font = try font_backend.loadRuntimeFont(allocator, .{
        .text = "Meow?!",
        .slug_path = "SlugDemo/Fonts/arial.slug",
        .backend = .slug_reference,
    });
    defer reference_font.deinit();

    var native_font = try font_backend.loadRuntimeFont(allocator, .{
        .text = "Meow?!",
        .font_path = font_path,
        .backend = .native_generator,
        .shape_backend = .simple_utf8,
    });
    defer native_font.deinit();

    var reference_model = try font_model.fromRuntimeFont(allocator, reference_font);
    defer reference_model.deinit();
    var native_model = try font_model.fromRuntimeFont(allocator, native_font);
    defer native_model.deinit();

    const diffs = try compareSharedLayoutGlyphs(allocator, reference_model, native_model, .{});
    defer allocator.free(diffs);

    try std.testing.expect(diffs.len > 0);
    for (diffs) |diff| {
        try std.testing.expect(diff.mask.mean_abs_diff >= 0.0);
        try std.testing.expect(diff.mask.max_abs_diff >= 0.0);
        try std.testing.expect(diff.mask.max_abs_diff <= 1.0);
    }
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

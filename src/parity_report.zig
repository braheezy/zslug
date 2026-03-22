const std = @import("std");
const build_options = @import("build_options");
const zslug = @import("zslug");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const slug_path = try resolveSlugPath();
    const font_path = try resolveFontPath(slug_path);
    const text = build_options.demo_text;

    var stdout_buffer: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&stdout_buffer);

    var reference_font = try zslug.font_backend.loadRuntimeFont(allocator, .{
        .text = text,
        .slug_path = slug_path,
        .backend = .slug_reference,
    });
    defer reference_font.deinit();

    var native_font = try zslug.font_backend.loadRuntimeFont(allocator, .{
        .text = text,
        .font_path = font_path,
        .backend = .native_generator,
        .shape_backend = .simple_utf8,
    });
    defer native_font.deinit();

    var reference_model = try zslug.font_model.fromRuntimeFont(allocator, reference_font);
    defer reference_model.deinit();
    var native_model = try zslug.font_model.fromRuntimeFont(allocator, native_font);
    defer native_model.deinit();
    var native_band_debug = std.AutoHashMap(u32, zslug.native_generator.BandHeuristicDebug).init(allocator);
    defer native_band_debug.deinit();

    var file = try zslug.slug_parse.loadFile(allocator, slug_path);
    defer file.deinit();
    const font = try zslug.slug_parse.parsePrimaryFontHeader(file);
    var contour_refs = try zslug.slug_parse.extractContourCurveRefs(allocator, file, font);
    defer contour_refs.deinit();
    try zslug.font_model.attachOfficialCurveRefs(allocator, &reference_model, contour_refs);

    var glyph_index_report = try zslug.font_model.compareFontModels(allocator, reference_model, native_model);
    defer glyph_index_report.deinit();
    var layout_report = try zslug.font_model.compareFontModelsByLayout(allocator, reference_model, native_model);
    defer layout_report.deinit();
    const shape_diffs = try zslug.glyph_parity.compareSharedLayoutGlyphs(allocator, reference_model, native_model, .{
        .pixels_per_em = 48.0,
    });
    defer allocator.free(shape_diffs);

    try out.interface.print("text: {s}\n", .{text});
    try out.interface.print("reference slug: {s}\n", .{slug_path});
    try out.interface.print("native font: {s}\n\n", .{font_path});

    try out.interface.writeAll("layout-aligned comparison:\n");
    try out.interface.print("layout_count_expected: {}\n", .{layout_report.layout_count_expected});
    try out.interface.print("layout_count_actual: {}\n", .{layout_report.layout_count_actual});
    try out.interface.print("layout_codepoint_mismatches: {}\n", .{layout_report.layout_codepoint_mismatches});
    try out.interface.print("layout_glyph_id_mismatches: {}\n", .{layout_report.layout_glyph_id_mismatches});
    try out.interface.print("missing_expected_glyphs: {}\n", .{layout_report.missing_expected_glyphs});
    try out.interface.print("missing_actual_glyphs: {}\n", .{layout_report.missing_actual_glyphs});
    try out.interface.print("invisible_mismatches: {}\n", .{layout_report.invisible_mismatches});
    try out.interface.print("max_advance_abs_diff: {d:.3}\n", .{layout_report.max_advance_abs_diff});
    try out.interface.print("max_bounds_abs_diff: {d:.3}\n", .{layout_report.max_bounds_abs_diff});
    try out.interface.print("horizontal_band_count_mismatches: {}\n", .{layout_report.horizontal_band_count_mismatches});
    try out.interface.print("vertical_band_count_mismatches: {}\n", .{layout_report.vertical_band_count_mismatches});
    try out.interface.print("horizontal_band_payload_mismatches: {}\n", .{layout_report.horizontal_band_payload_mismatches});
    try out.interface.print("vertical_band_payload_mismatches: {}\n", .{layout_report.vertical_band_payload_mismatches});
    try out.interface.print("polygon_count_mismatches: {}\n", .{layout_report.polygon_count_mismatches});
    try out.interface.print("total_curve_ref_mismatches: {}\n", .{layout_report.total_curve_ref_mismatches});
    try out.interface.print("official_curve_ref_mismatches: {}\n", .{layout_report.official_curve_ref_mismatches});
    try out.interface.print("official_curve_ref_missing_total: {}\n", .{layout_report.official_curve_ref_missing_total});
    try out.interface.print("official_curve_ref_extra_total: {}\n", .{layout_report.official_curve_ref_extra_total});

    try out.interface.writeAll("\nlegacy glyph-index comparison:\n");
    try out.interface.print("missing_expected_glyphs: {}\n", .{glyph_index_report.missing_expected_glyphs});
    try out.interface.print("missing_actual_glyphs: {}\n", .{glyph_index_report.missing_actual_glyphs});

    try out.interface.writeAll("\nper-glyph canonical diffs:\n");
    for (glyph_index_report.glyph_diffs) |diff| {
        const codepoint = codepointForGlyph(reference_model, diff.glyph_index) orelse 0;
        try out.interface.print(
            "  glyph={} cp={} char={c} adv={d:.3} bounds={d:.3} hbands={} vbands={} poly={} total_refs={} official_missing={} official_extra={}\n",
            .{
                diff.glyph_index,
                codepoint,
                displayCodepoint(codepoint),
                diff.advance_abs_diff,
                diff.max_bounds_abs_diff,
                diff.horizontal_band_count_diff,
                diff.vertical_band_count_diff,
                diff.polygon_count_diff,
                diff.total_curve_ref_diff,
                diff.official_curve_ref_missing_count,
                diff.official_curve_ref_extra_count,
            },
        );
    }

    try out.interface.writeAll("\nper-layout structural diffs:\n");
    for (layout_report.glyph_diffs) |diff| {
        const ref_glyph = reference_model.findGlyph(diff.expected_glyph_index).?;
        const native_glyph = native_model.findGlyph(diff.actual_glyph_index).?;
        const band_debug = blk: {
            const entry = try native_band_debug.getOrPut(diff.actual_glyph_index);
            if (!entry.found_existing) {
                entry.value_ptr.* = try zslug.native_generator.debugBandHeuristicForGlyph(
                    allocator,
                    font_path,
                    diff.actual_glyph_index,
                );
            }
            break :blk entry.value_ptr.*;
        };
        const ref_size = .{ ref_glyph.bbox[2] - ref_glyph.bbox[0], ref_glyph.bbox[3] - ref_glyph.bbox[1] };
        const native_size = .{ native_glyph.bbox[2] - native_glyph.bbox[0], native_glyph.bbox[3] - native_glyph.bbox[1] };
        var ref_h_summary = try zslug.font_model.summarizeBands(allocator, ref_glyph.horizontal_bands);
        defer ref_h_summary.deinit();
        var native_h_summary = try zslug.font_model.summarizeBands(allocator, native_glyph.horizontal_bands);
        defer native_h_summary.deinit();
        var ref_v_summary = try zslug.font_model.summarizeBands(allocator, ref_glyph.vertical_bands);
        defer ref_v_summary.deinit();
        var native_v_summary = try zslug.font_model.summarizeBands(allocator, native_glyph.vertical_bands);
        defer native_v_summary.deinit();
        const curve_geometry_diff = try zslug.font_model.compareCurveGeometry(allocator, ref_glyph, native_glyph);
        try out.interface.print(
            "  idx={} cp={} char={c} ref_glyph={} native_glyph={} adv={d:.3} bounds={d:.3} ref_bbox=({d:.3},{d:.3},{d:.3},{d:.3}) native_bbox=({d:.3},{d:.3},{d:.3},{d:.3}) ref_off=({d:.3},{d:.3}) native_off=({d:.3},{d:.3}) size=({d:.3},{d:.3}) native_size=({d:.3},{d:.3}) poly={} total_refs={} curve_geom_missing={} curve_geom_extra={}\n",
            .{
                diff.layout_index,
                diff.codepoint,
                displayCodepoint(diff.codepoint),
                diff.expected_glyph_index,
                diff.actual_glyph_index,
                diff.advance_abs_diff,
                diff.max_bounds_abs_diff,
                ref_glyph.bbox[0],
                ref_glyph.bbox[1],
                ref_glyph.bbox[2],
                ref_glyph.bbox[3],
                native_glyph.bbox[0],
                native_glyph.bbox[1],
                native_glyph.bbox[2],
                native_glyph.bbox[3],
                ref_glyph.glyph_offset[0],
                ref_glyph.glyph_offset[1],
                native_glyph.glyph_offset[0],
                native_glyph.glyph_offset[1],
                ref_size[0],
                ref_size[1],
                native_size[0],
                native_size[1],
                diff.polygon_count_diff,
                diff.total_curve_ref_diff,
                curve_geometry_diff.missing_count,
                curve_geometry_diff.extra_count,
            },
        );
        try out.interface.print(
            "    hbands={} ref={} native={} scale_ref={d:.3} scale_native={d:.3} nz_ref={} nz_native={} max_ref={} max_native={} total_ref={} total_native={}\n",
            .{
                diff.horizontal_band_count_diff,
                ref_glyph.horizontal_bands.len,
                native_glyph.horizontal_bands.len,
                ref_glyph.band_scale[1],
                native_glyph.band_scale[1],
                ref_h_summary.non_empty_count,
                native_h_summary.non_empty_count,
                ref_h_summary.max_curve_count,
                native_h_summary.max_curve_count,
                ref_h_summary.total_curve_refs,
                native_h_summary.total_curve_refs,
            },
        );
        try out.interface.print(
            "    vbands={} ref={} native={} scale_ref={d:.3} scale_native={d:.3} nz_ref={} nz_native={} max_ref={} max_native={} total_ref={} total_native={}\n",
            .{
                diff.vertical_band_count_diff,
                ref_glyph.vertical_bands.len,
                native_glyph.vertical_bands.len,
                ref_glyph.band_scale[0],
                native_glyph.band_scale[0],
                ref_v_summary.non_empty_count,
                native_v_summary.non_empty_count,
                ref_v_summary.max_curve_count,
                native_v_summary.max_curve_count,
                ref_v_summary.total_curve_refs,
                native_v_summary.total_curve_refs,
            },
        );
        try out.interface.writeAll("    h_curve_counts_ref=");
        try writeCurveCounts(&out, ref_h_summary.curve_counts);
        try out.interface.writeAll(" native=");
        try writeCurveCounts(&out, native_h_summary.curve_counts);
        try out.interface.writeAll("\n    v_curve_counts_ref=");
        try writeCurveCounts(&out, ref_v_summary.curve_counts);
        try out.interface.writeAll(" native=");
        try writeCurveCounts(&out, native_v_summary.curve_counts);
        try out.interface.print(
            "\n    native_heuristic curves_src={} curves_split={} vertical(sig={} bins={} trans={} max_active={} span=({d:.3},{d:.3}) est={d:.2} est_n={} cap={} aspect={d:.2} capped={} final={}) horizontal(sig={} bins={} trans={} max_active={} span=({d:.3},{d:.3}) est={d:.2} est_n={} cap={} aspect={d:.2} capped={} final={})\n",
            .{
                band_debug.source_curve_count,
                band_debug.split_curve_count,
                band_debug.vertical.significant_count,
                band_debug.vertical.feature_bins,
                band_debug.vertical.activity_transition_count,
                band_debug.vertical.max_active_curve_count,
                band_debug.vertical.span_min,
                band_debug.vertical.span_max,
                band_debug.vertical.estimate,
                band_debug.vertical.estimate_count,
                band_debug.vertical.feature_cap,
                band_debug.vertical.aspect_ratio,
                band_debug.vertical.capped,
                band_debug.vertical.band_count,
                band_debug.horizontal.significant_count,
                band_debug.horizontal.feature_bins,
                band_debug.horizontal.activity_transition_count,
                band_debug.horizontal.max_active_curve_count,
                band_debug.horizontal.span_min,
                band_debug.horizontal.span_max,
                band_debug.horizontal.estimate,
                band_debug.horizontal.estimate_count,
                band_debug.horizontal.feature_cap,
                band_debug.horizontal.aspect_ratio,
                band_debug.horizontal.capped,
                band_debug.horizontal.band_count,
            },
        );
    }

    const sorted_shape_diffs = try allocator.dupe(zslug.glyph_parity.GlyphShapeDiff, shape_diffs);
    defer allocator.free(sorted_shape_diffs);
    std.mem.sort(zslug.glyph_parity.GlyphShapeDiff, sorted_shape_diffs, {}, struct {
        fn lessThan(_: void, a: zslug.glyph_parity.GlyphShapeDiff, b: zslug.glyph_parity.GlyphShapeDiff) bool {
            if (a.mask.mean_abs_diff != b.mask.mean_abs_diff) return a.mask.mean_abs_diff > b.mask.mean_abs_diff;
            return a.codepoint < b.codepoint;
        }
    }.lessThan);

    try out.interface.writeAll("\nper-glyph mask diffs:\n");
    for (sorted_shape_diffs) |diff| {
        try out.interface.print(
            "  cp={} char={c} glyph={} size={}x{} mean={d:.4} max={d:.4} over1%={} over10%={}\n",
            .{
                diff.codepoint,
                displayCodepoint(diff.codepoint),
                diff.glyph_index,
                diff.mask.width,
                diff.mask.height,
                diff.mask.mean_abs_diff,
                diff.mask.max_abs_diff,
                diff.mask.pixels_over_1pct,
                diff.mask.pixels_over_10pct,
            },
        );
    }

    try out.interface.flush();
}

fn resolveSlugPath() ![]const u8 {
    if (canOpenRelative(build_options.demo_slug_path)) return build_options.demo_slug_path;
    if (canOpenRelative("SlugDemo/Fonts/georgia_nc.slug")) return "SlugDemo/Fonts/georgia_nc.slug";
    if (canOpenRelative("SlugDemo/Fonts/arial.slug")) return "SlugDemo/Fonts/arial.slug";
    return error.MissingSlugPath;
}

fn resolveFontPath(slug_path: []const u8) ![]const u8 {
    if (build_options.demo_font_path.len != 0 and canOpenAbsolute(build_options.demo_font_path)) {
        return build_options.demo_font_path;
    }

    const georgia_candidates = [_][]const u8{
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/Library/Fonts/Georgia.ttf",
    };
    const arial_candidates = [_][]const u8{
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
    };

    const candidates = if (std.mem.indexOf(u8, slug_path, "georgia") != null)
        georgia_candidates[0..]
    else
        arial_candidates[0..];
    for (candidates) |candidate| {
        if (canOpenAbsolute(candidate)) return candidate;
    }
    return error.MissingFontPath;
}

fn codepointForGlyph(model: zslug.font_model.FontModel, glyph_index: u32) ?u32 {
    for (model.layout_glyphs) |layout_glyph| {
        if (layout_glyph.glyph_index == glyph_index) return layout_glyph.codepoint;
    }
    return null;
}

fn displayCodepoint(codepoint: u32) u8 {
    return switch (codepoint) {
        33...126 => @intCast(codepoint),
        else => '?',
    };
}

fn canOpenRelative(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn canOpenAbsolute(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn writeCurveCounts(out: anytype, counts: []const u16) !void {
    try out.interface.writeByte('[');
    for (counts, 0..) |count, i| {
        if (i != 0) try out.interface.writeAll(",");
        try out.interface.print("{}", .{count});
    }
    try out.interface.writeByte(']');
}

const std = @import("std");
const runtime = @import("runtime_font.zig");
const text_runtime = @import("text_runtime.zig");

pub const Geometry = struct {
    allocator: std.mem.Allocator,
    vertices: []runtime.SlugVertex,
    indices: []u32,

    pub fn deinit(self: *Geometry) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
        self.* = undefined;
    }
};

pub fn buildGlyphGeometry(
    allocator: std.mem.Allocator,
    font: runtime.CompiledFont,
    placements: []const text_runtime.GlyphPlacement,
) !Geometry {
    var total_vertex_count: usize = 0;
    var total_index_count: usize = 0;
    for (placements) |placement| {
        const glyph = font.findGlyph(placement.glyph_index) orelse continue;
        if (!glyph.visible) continue;
        const polygon_count = glyphPolygonCount(glyph);
        total_vertex_count += polygon_count;
        total_index_count += (polygon_count - 2) * 3;
    }
    if (total_vertex_count == 0) return error.EmptyLayout;

    const vertices = try allocator.alloc(runtime.SlugVertex, total_vertex_count);
    errdefer allocator.free(vertices);
    const indices = try allocator.alloc(u32, total_index_count);
    errdefer allocator.free(indices);

    var vertex_count: usize = 0;
    var index_count: usize = 0;
    for (placements) |placement| {
        const glyph = font.findGlyph(placement.glyph_index) orelse continue;
        if (!glyph.visible) continue;
        const polygon_count = glyphPolygonCount(glyph);
        appendGlyphPolygon(
            vertices[vertex_count .. vertex_count + polygon_count],
            indices[index_count .. index_count + (polygon_count - 2) * 3],
            @intCast(vertex_count),
            placement,
            glyph,
        );
        vertex_count += polygon_count;
        index_count += (polygon_count - 2) * 3;
    }

    return .{
        .allocator = allocator,
        .vertices = try allocator.realloc(vertices, vertex_count),
        .indices = try allocator.realloc(indices, index_count),
    };
}

fn appendGlyphPolygon(
    vertices: []runtime.SlugVertex,
    indices: []u32,
    base_vertex: u32,
    placement: text_runtime.GlyphPlacement,
    glyph: runtime.RuntimeGlyph,
) void {
    const packed_glyph_loc = packU16x2(glyph.band_location[0], glyph.band_location[1]);
    const packed_band_max = packU16x2(glyph.band_count[0] - 1, glyph.band_count[1] - 1);
    const inv_scale = 1.0 / placement.scale;
    const jac = [4]f32{ inv_scale, 0.0, 0.0, inv_scale };
    const bnd = [4]f32{
        glyph.band_scale[0],
        glyph.band_scale[1],
        -glyph.bbox[0] * glyph.band_scale[0],
        -glyph.bbox[1] * glyph.band_scale[1],
    };

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
                placement.position[0] + (glyph.glyph_offset[0] + point[0]) * placement.scale,
                placement.position[1] + (glyph.glyph_offset[1] + point[1]) * placement.scale,
                normal[0],
                normal[1],
            },
            .tex = .{ point[0], point[1], packed_glyph_loc, packed_band_max },
            .jac = jac,
            .bnd = bnd,
            .col = placement.color,
        };
    }

    var index_pos: usize = 0;
    triangulatePolygon(indices, &index_pos, base_vertex, polygon);
}

fn glyphPolygonCount(glyph: runtime.RuntimeGlyph) usize {
    if (glyph.polygon_count >= 3) return glyph.polygon_count;
    return 4;
}

fn fallbackSlugQuad(bbox: [4]f32) [4]runtime.Point {
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

fn signedPolygonArea(points: []const runtime.Point) f32 {
    var area: f32 = 0.0;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        area += p[0] * q[1] - q[0] * p[1];
    }
    return area;
}

fn polygonVertexNormal(prev: runtime.Point, current: runtime.Point, next: runtime.Point, winding: f32) runtime.Point {
    const e0 = normalize2(.{ current[0] - prev[0], current[1] - prev[1] });
    const e1 = normalize2(.{ next[0] - current[0], next[1] - current[1] });
    const n0 = runtime.Point{ winding * e0[1], -winding * e0[0] };
    const n1 = runtime.Point{ winding * e1[1], -winding * e1[0] };
    const sum = runtime.Point{ n0[0] + n1[0], n0[1] + n1[1] };
    const len2 = sum[0] * sum[0] + sum[1] * sum[1];
    if (len2 < 1.0e-6) return n1;

    const bisector = normalize2(sum);
    const miter_scale = @max(0.05, bisector[0] * n1[0] + bisector[1] * n1[1]);
    return .{
        bisector[0] / miter_scale,
        bisector[1] / miter_scale,
    };
}

fn triangulatePolygon(indices: []u32, index_pos: *usize, base_vertex: u32, polygon: []const runtime.Point) void {
    if (polygon.len < 3) return;
    var i: usize = 1;
    while (i + 1 < polygon.len) : (i += 1) {
        indices[index_pos.* + 0] = base_vertex;
        indices[index_pos.* + 1] = base_vertex + @as(u32, @intCast(i));
        indices[index_pos.* + 2] = base_vertex + @as(u32, @intCast(i + 1));
        index_pos.* += 3;
    }
}

fn normalize2(v: runtime.Point) runtime.Point {
    const len2 = v[0] * v[0] + v[1] * v[1];
    if (len2 < 1.0e-8) return .{ 0.0, 1.0 };
    const inv_len = 1.0 / @sqrt(len2);
    return .{ v[0] * inv_len, v[1] * inv_len };
}

test "buildGlyphGeometry builds slug vertices from placements" {
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
                .bbox = .{ 0.0, 0.0, 2.0, 1.0 },
                .glyph_offset = .{ 0.0, 0.0 },
                .advance = 2.0,
                .visible = true,
                .band_location = .{ 3, 4 },
                .band_count = .{ 2, 2 },
                .band_scale = .{ 0.5, 0.5 },
                .polygon_count = 4,
                .polygon_points = .{
                    .{ 0.0, 0.0 }, .{ 0.0, 1.0 }, .{ 2.0, 1.0 }, .{ 2.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
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
        .line_height = 1.1,
        .curves_width = 0,
        .curves_height = 0,
        .curves_texels = curves_texels,
        .bands_width = 0,
        .bands_height = 0,
        .bands_texels = bands_texels,
        .glyphs = glyphs,
        .cmap = cmap,
    };
    const placements = [_]text_runtime.GlyphPlacement{
        .{ .glyph_index = 1, .position = .{ 10.0, 20.0 }, .scale = 2.0 },
    };

    var geometry = try buildGlyphGeometry(allocator, font, &placements);
    defer geometry.deinit();

    try std.testing.expectEqual(@as(usize, 4), geometry.vertices.len);
    try std.testing.expectEqual(@as(usize, 6), geometry.indices.len);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), geometry.vertices[0].pos[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 22.0), geometry.vertices[1].pos[1], 0.0001);
}

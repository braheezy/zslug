const std = @import("std");

pub const Point = [2]f32;

pub const CurveTexel = extern struct {
    value: [4]f32,
};

pub const BandTexel = extern struct {
    value: [2]u32,
};

pub const SlugVertex = extern struct {
    pos: [4]f32,
    tex: [4]f32,
    jac: [4]f32,
    bnd: [4]f32,
    col: [4]f32,
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    curves_width: u32,
    curves_height: u32,
    curves_texels: []CurveTexel,
    bands_width: u32,
    bands_height: u32,
    bands_texels: []BandTexel,
    vertices: []SlugVertex,
    indices: []u32,

    pub fn deinit(self: *Scene) void {
        self.allocator.free(self.curves_texels);
        self.allocator.free(self.bands_texels);
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
        self.* = undefined;
    }
};

pub const RuntimeGlyph = struct {
    glyph_index: u32,
    bbox: [4]f32,
    glyph_offset: [2]f32,
    advance: f32,
    visible: bool,
    band_location: [2]u16,
    band_count: [2]u16,
    band_scale: [2]f32,
    polygon_count: u8,
    polygon_points: [6]Point,
};

pub const LayoutGlyph = struct {
    glyph_index: u32,
    codepoint: u32,
    cluster: u32,
    advance: [2]f32,
    offset: [2]f32,
};

pub const CompiledGlyph = struct {
    glyph_index: u32,
    glyph: RuntimeGlyph,
};

pub const CodepointMapEntry = struct {
    codepoint: u32,
    glyph_index: u32,
};

pub const CompiledFont = struct {
    allocator: std.mem.Allocator,
    units_per_em: u32,
    ascender: f32,
    descender: f32,
    line_height: f32,
    curves_width: u32,
    curves_height: u32,
    curves_texels: []CurveTexel,
    bands_width: u32,
    bands_height: u32,
    bands_texels: []BandTexel,
    glyphs: []CompiledGlyph,
    cmap: []CodepointMapEntry,

    const magic: u32 = 0x4753465A; // ZSFG
    const version: u32 = 1;

    pub fn deinit(self: *CompiledFont) void {
        self.allocator.free(self.curves_texels);
        self.allocator.free(self.bands_texels);
        self.allocator.free(self.glyphs);
        self.allocator.free(self.cmap);
        self.* = undefined;
    }

    pub fn lookupGlyphIndex(self: CompiledFont, codepoint: u32) ?u32 {
        var lo: usize = 0;
        var hi: usize = self.cmap.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = self.cmap[mid];
            if (entry.codepoint < codepoint) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo < self.cmap.len and self.cmap[lo].codepoint == codepoint) {
            return self.cmap[lo].glyph_index;
        }
        return null;
    }

    pub fn findGlyph(self: CompiledFont, glyph_index: u32) ?RuntimeGlyph {
        var lo: usize = 0;
        var hi: usize = self.glyphs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = self.glyphs[mid];
            if (entry.glyph_index < glyph_index) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo < self.glyphs.len and self.glyphs[lo].glyph_index == glyph_index) {
            return self.glyphs[lo].glyph;
        }
        return null;
    }

    pub fn fallbackGlyphIndex(self: CompiledFont) ?u32 {
        return self.lookupGlyphIndex('?') orelse self.lookupGlyphIndex(' ');
    }

    pub fn saveToFile(self: CompiledFont, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var writer_buffer: [4096]u8 = undefined;
        var writer = file.writer(&writer_buffer);

        try writeU32(&writer, magic);
        try writeU32(&writer, version);
        try writeU32(&writer, self.units_per_em);
        try writeF32(&writer, self.ascender);
        try writeF32(&writer, self.descender);
        try writeF32(&writer, self.line_height);
        try writeU32(&writer, self.curves_width);
        try writeU32(&writer, self.curves_height);
        try writeU32(&writer, self.bands_width);
        try writeU32(&writer, self.bands_height);
        try writeU32(&writer, @intCast(self.glyphs.len));
        try writeU32(&writer, @intCast(self.cmap.len));

        for (self.curves_texels) |texel| {
            for (texel.value) |value| try writeF32(&writer, value);
        }
        for (self.bands_texels) |texel| {
            try writeU32(&writer, texel.value[0]);
            try writeU32(&writer, texel.value[1]);
        }
        for (self.glyphs) |entry| {
            try writeCompiledGlyph(&writer, entry);
        }
        for (self.cmap) |entry| {
            try writeU32(&writer, entry.codepoint);
            try writeU32(&writer, entry.glyph_index);
        }
        try writer.interface.flush();
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !CompiledFont {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var reader_buffer: [4096]u8 = undefined;
        var reader = file.reader(&reader_buffer);

        if (try readU32(&reader) != magic) return error.InvalidFontAsset;
        if (try readU32(&reader) != version) return error.UnsupportedFontAssetVersion;

        const units_per_em = try readU32(&reader);
        const ascender = try readF32(&reader);
        const descender = try readF32(&reader);
        const line_height = try readF32(&reader);
        const curves_width = try readU32(&reader);
        const curves_height = try readU32(&reader);
        const bands_width = try readU32(&reader);
        const bands_height = try readU32(&reader);
        const glyph_count = try readU32(&reader);
        const cmap_count = try readU32(&reader);

        const curves_texels = try allocator.alloc(CurveTexel, curves_width * curves_height);
        errdefer allocator.free(curves_texels);
        for (curves_texels) |*texel| {
            for (&texel.value) |*value| value.* = try readF32(&reader);
        }

        const bands_texels = try allocator.alloc(BandTexel, bands_width * bands_height);
        errdefer allocator.free(bands_texels);
        for (bands_texels) |*texel| {
            texel.* = .{ .value = .{ try readU32(&reader), try readU32(&reader) } };
        }

        const glyphs = try allocator.alloc(CompiledGlyph, glyph_count);
        errdefer allocator.free(glyphs);
        for (glyphs) |*entry| entry.* = try readCompiledGlyph(&reader);

        const cmap = try allocator.alloc(CodepointMapEntry, cmap_count);
        errdefer allocator.free(cmap);
        for (cmap) |*entry| {
            entry.* = .{
                .codepoint = try readU32(&reader),
                .glyph_index = try readU32(&reader),
            };
        }

        return .{
            .allocator = allocator,
            .units_per_em = units_per_em,
            .ascender = ascender,
            .descender = descender,
            .line_height = line_height,
            .curves_width = curves_width,
            .curves_height = curves_height,
            .curves_texels = curves_texels,
            .bands_width = bands_width,
            .bands_height = bands_height,
            .bands_texels = bands_texels,
            .glyphs = glyphs,
            .cmap = cmap,
        };
    }
};

pub const RuntimeFont = struct {
    allocator: std.mem.Allocator,
    curves_width: u32,
    curves_height: u32,
    curves_texels: []CurveTexel,
    bands_width: u32,
    bands_height: u32,
    bands_texels: []BandTexel,
    layout_glyphs: []LayoutGlyph,
    glyphs: std.AutoHashMap(u32, RuntimeGlyph),

    pub fn deinit(self: *RuntimeFont) void {
        self.allocator.free(self.curves_texels);
        self.allocator.free(self.bands_texels);
        self.allocator.free(self.layout_glyphs);
        self.glyphs.deinit();
        self.* = undefined;
    }
};

fn writeU32(writer: anytype, value: u32) !void {
    try writer.interface.writeInt(u32, value, .little);
}

fn writeU8(writer: anytype, value: u8) !void {
    try writer.interface.writeByte(value);
}

fn writeF32(writer: anytype, value: f32) !void {
    try writeU32(writer, @bitCast(value));
}

fn readU32(reader: anytype) !u32 {
    return try reader.interface.readInt(u32, .little);
}

fn readU8(reader: anytype) !u8 {
    return try reader.interface.takeByte();
}

fn readF32(reader: anytype) !f32 {
    return @bitCast(try readU32(reader));
}

fn writeCompiledGlyph(writer: anytype, entry: CompiledGlyph) !void {
    try writeU32(writer, entry.glyph_index);
    for (entry.glyph.bbox) |value| try writeF32(writer, value);
    for (entry.glyph.glyph_offset) |value| try writeF32(writer, value);
    try writeF32(writer, entry.glyph.advance);
    try writeU8(writer, if (entry.glyph.visible) 1 else 0);
    try writeU32(writer, entry.glyph.band_location[0]);
    try writeU32(writer, entry.glyph.band_location[1]);
    try writeU32(writer, entry.glyph.band_count[0]);
    try writeU32(writer, entry.glyph.band_count[1]);
    for (entry.glyph.band_scale) |value| try writeF32(writer, value);
    try writeU8(writer, entry.glyph.polygon_count);
    for (entry.glyph.polygon_points) |point| {
        try writeF32(writer, point[0]);
        try writeF32(writer, point[1]);
    }
}

fn readCompiledGlyph(reader: anytype) !CompiledGlyph {
    var glyph: RuntimeGlyph = undefined;
    glyph.glyph_index = try readU32(reader);
    for (&glyph.bbox) |*value| value.* = try readF32(reader);
    for (&glyph.glyph_offset) |*value| value.* = try readF32(reader);
    glyph.advance = try readF32(reader);
    glyph.visible = (try readU8(reader)) != 0;
    glyph.band_location = .{
        @intCast(try readU32(reader)),
        @intCast(try readU32(reader)),
    };
    glyph.band_count = .{
        @intCast(try readU32(reader)),
        @intCast(try readU32(reader)),
    };
    for (&glyph.band_scale) |*value| value.* = try readF32(reader);
    glyph.polygon_count = try readU8(reader);
    for (&glyph.polygon_points) |*point| {
        point.* = .{ try readF32(reader), try readF32(reader) };
    }
    return .{
        .glyph_index = glyph.glyph_index,
        .glyph = glyph,
    };
}

test "compiled font serializes and loads" {
    const allocator = std.testing.allocator;
    const curves_texels = try allocator.alloc(CurveTexel, 1);
    defer allocator.free(curves_texels);
    curves_texels[0] = .{ .value = .{ 1.0, 2.0, 3.0, 4.0 } };
    const bands_texels = try allocator.alloc(BandTexel, 1);
    defer allocator.free(bands_texels);
    bands_texels[0] = .{ .value = .{ 5, 6 } };
    const glyphs = try allocator.dupe(CompiledGlyph, &[_]CompiledGlyph{
        .{
            .glyph_index = 7,
            .glyph = .{
                .glyph_index = 7,
                .bbox = .{ 1.0, 2.0, 3.0, 4.0 },
                .glyph_offset = .{ 0.0, 0.5 },
                .advance = 9.0,
                .visible = true,
                .band_location = .{ 10, 11 },
                .band_count = .{ 12, 13 },
                .band_scale = .{ 0.25, 0.5 },
                .polygon_count = 4,
                .polygon_points = .{
                    .{ 0.0, 0.0 }, .{ 0.0, 1.0 }, .{ 1.0, 1.0 }, .{ 1.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
                },
            },
        },
    });
    defer allocator.free(glyphs);
    const cmap = try allocator.dupe(CodepointMapEntry, &[_]CodepointMapEntry{
        .{ .codepoint = 'A', .glyph_index = 7 },
    });
    defer allocator.free(cmap);

    var font = CompiledFont{
        .allocator = allocator,
        .units_per_em = 1000,
        .ascender = 0.8,
        .descender = -0.2,
        .line_height = 1.1,
        .curves_width = 1,
        .curves_height = 1,
        .curves_texels = curves_texels,
        .bands_width = 1,
        .bands_height = 1,
        .bands_texels = bands_texels,
        .glyphs = glyphs,
        .cmap = cmap,
    };

    const path = "zig-cache/test-font.zsf";
    try font.saveToFile(path);

    var loaded = try CompiledFont.loadFromFile(allocator, path);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u32, 1000), loaded.units_per_em);
    try std.testing.expectEqual(@as(usize, 1), loaded.glyphs.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.cmap.len);
    try std.testing.expectEqual(@as(u32, 7), loaded.lookupGlyphIndex('A').?);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), loaded.findGlyph(7).?.advance, 0.0001);
}

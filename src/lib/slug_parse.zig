const std = @import("std");

pub const SlugFile = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    header_size: u32,
    kind: u32,
    version: u32,
    blocks: [2]DataBlock,
    root_offset_count: u32,

    pub fn deinit(self: *SlugFile) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn kindTag(self: SlugFile) [4]u8 {
        return unpackTag(self.kind);
    }

    pub fn magicOk(self: SlugFile) bool {
        return self.bytes.len >= 4 and std.mem.eql(u8, self.bytes[0..4], "guls");
    }
};

pub const CurveTexel32 = extern struct {
    value: [4]f32,
};

pub const BandTexel32 = extern struct {
    value: [2]u32,
};

pub const FontHeader = struct {
    base_offset: usize,
    font_key_data_count: i32,
    font_key_data_offset: i32,
    page_count: i32,
    page_index_offset: i32,
    glyph_index_offset: i32,
    glyph_count: i32,
    glyph_data_offset: [2]i32,
    contour_data_offset: i32,
    decompose_data_offset: i32,
    color_layer_data_offset: i32,
    base_anchor_data_offset: i32,
    mark_attach_data_offset: i32,
    kern_data_offset: [2]i32,
    sequence_data_offset: i32,
    alternate_data_offset: i32,
    caret_position_data_offset: i32,
    extra_offset: i32,
};

pub const DataBlock = struct {
    storage_tag: u32,
    width: u32,
    height: u32,
    compression_tag: u32,
    compressed_size: u32,
    data_offset: u32,

    pub fn storageName(self: DataBlock) [4]u8 {
        return reverseTag(self.storage_tag);
    }

    pub fn compressionName(self: DataBlock) [4]u8 {
        return reverseTag(self.compression_tag);
    }

    pub fn isCompressed(self: DataBlock) bool {
        return self.compression_tag != 0;
    }
};

pub const HeaderDirectory = struct {
    entries: []DirectoryEntry,

    pub fn deinit(self: *HeaderDirectory, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const DirectoryEntry = struct {
    raw_tag: u32,
    offset: u32,

    pub fn name(self: DirectoryEntry) [4]u8 {
        return reverseTag(self.raw_tag);
    }
};

pub const GraphicData = struct {
    bounding_box: [4]f32,
    band_location: [2]u16,
    band_count: [2]i16,
    band_scale: [2]f32,
    contour_curve_count: u16,
    polygon_code: u16,
    contour_data: u32,
    polygon_bytes: [24]u8,
};

pub const DecodedPolygon = struct {
    code: u16,
    flags: u16,
    count: u8,
    points: [6][2]f32,
};

pub const GlyphData = struct {
    graphic: GraphicData,
    glyph_offset: [2]f32,
    advance_width: f32,
    advance_height: f32,
    vertical_origin: f32,
    decompose_data: u32,
    color_layer_data: u32,
    base_anchor_data: u32,
    mark_attach_data: u32,
    kern_data: [2]u32,
    sequence_data: u32,
    alternate_data: u32,
    caret_position_data: u32,
};

pub const GlyphCurveRefRange = struct {
    start: usize,
    len: usize,
};

pub const ContourCurveRefTable = struct {
    allocator: std.mem.Allocator,
    glyphs: []GlyphCurveRefRange,
    curve_refs: []u32,

    pub fn deinit(self: *ContourCurveRefTable) void {
        self.allocator.free(self.glyphs);
        self.allocator.free(self.curve_refs);
        self.* = undefined;
    }

    pub fn glyphCurveRefs(self: ContourCurveRefTable, glyph_index: u32) ?[]const u32 {
        if (glyph_index >= self.glyphs.len) return null;
        const range = self.glyphs[glyph_index];
        return self.curve_refs[range.start .. range.start + range.len];
    }
};

pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !SlugFile {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    errdefer allocator.free(bytes);
    return try parseBytesOwned(allocator, bytes);
}

pub fn parseBytesOwned(allocator: std.mem.Allocator, bytes: []u8) !SlugFile {
    if (bytes.len < 0x54) return error.InvalidSlugFile;
    if (!std.mem.eql(u8, bytes[0..4], "guls")) return error.InvalidSlugMagic;

    return .{
        .allocator = allocator,
        .bytes = bytes,
        .header_size = readU32(bytes, 0x04),
        .kind = readU32(bytes, 0x08),
        .version = readU32(bytes, 0x0C),
        .blocks = .{
            parseBlock(bytes, 0x20),
            parseBlock(bytes, 0x38),
        },
        .root_offset_count = readU32(bytes, 0x50),
    };
}

pub fn parseHeaderDirectory(allocator: std.mem.Allocator, file: SlugFile) !HeaderDirectory {
    const header_end = @min(file.bytes.len, file.header_size);
    if (header_end < 8) return error.InvalidSlugFile;

    var best_start: usize = 0;
    var best_count: usize = 0;
    var start: usize = 0;
    while (start + 8 <= header_end) : (start += 4) {
        var count: usize = 0;
        var cursor = start;
        while (cursor + 8 <= header_end) : (cursor += 8) {
            if (!looksLikeDirectoryTag(file.bytes[cursor .. cursor + 4])) break;
            const offset = readU32(file.bytes, cursor + 4);
            if (offset >= file.header_size) break;
            count += 1;
        }
        if (count > best_count) {
            best_count = count;
            best_start = start;
        }
    }

    if (best_count == 0) return error.DirectoryNotFound;

    const entries = try allocator.alloc(DirectoryEntry, best_count);
    errdefer allocator.free(entries);
    for (entries, 0..) |*entry, i| {
        const offset = best_start + i * 8;
        entry.* = .{
            .raw_tag = readU32(file.bytes, offset),
            .offset = readU32(file.bytes, offset + 4),
        };
    }
    return .{ .entries = entries };
}

pub fn parsePrimaryFontHeader(file: SlugFile) !FontHeader {
    const base = commonHeaderSize(file);
    if (base + 0x48 > file.bytes.len) return error.InvalidSlugFile;

    return .{
        .base_offset = base,
        .font_key_data_count = readI32(file.bytes, base + 0x00),
        .font_key_data_offset = readI32(file.bytes, base + 0x04),
        .page_count = readI32(file.bytes, base + 0x08),
        .page_index_offset = readI32(file.bytes, base + 0x0C),
        .glyph_index_offset = readI32(file.bytes, base + 0x10),
        .glyph_count = readI32(file.bytes, base + 0x14),
        .glyph_data_offset = .{
            readI32(file.bytes, base + 0x18),
            readI32(file.bytes, base + 0x1C),
        },
        .contour_data_offset = readI32(file.bytes, base + 0x20),
        .decompose_data_offset = readI32(file.bytes, base + 0x24),
        .color_layer_data_offset = readI32(file.bytes, base + 0x28),
        .base_anchor_data_offset = readI32(file.bytes, base + 0x2C),
        .mark_attach_data_offset = readI32(file.bytes, base + 0x30),
        .kern_data_offset = .{
            readI32(file.bytes, base + 0x34),
            readI32(file.bytes, base + 0x38),
        },
        .sequence_data_offset = readI32(file.bytes, base + 0x3C),
        .alternate_data_offset = readI32(file.bytes, base + 0x40),
        .caret_position_data_offset = readI32(file.bytes, base + 0x44),
        .extra_offset = if (base + 0x4C <= file.bytes.len) readI32(file.bytes, base + 0x48) else 0,
    };
}

pub fn parseFontKeyDirectory(allocator: std.mem.Allocator, file: SlugFile, font: FontHeader) !HeaderDirectory {
    if (font.font_key_data_count < 0 or font.font_key_data_offset < 0) return error.InvalidSlugFile;
    const count: usize = @intCast(font.font_key_data_count);
    const base = font.base_offset + @as(usize, @intCast(font.font_key_data_offset));
    const end = base + count * 8;
    if (end > file.bytes.len) return error.InvalidSlugFile;

    const entries = try allocator.alloc(DirectoryEntry, count);
    errdefer allocator.free(entries);
    for (entries, 0..) |*entry, i| {
        const offset = base + i * 8;
        entry.* = .{
            .raw_tag = readU32(file.bytes, offset),
            .offset = readU32(file.bytes, offset + 4),
        };
    }
    return .{ .entries = entries };
}

pub fn lookupGlyphIndex(file: SlugFile, font: FontHeader, unicode: u32) !u32 {
    if (unicode >> 8 >= @as(u32, @intCast(font.page_count))) return 0;
    if (font.page_index_offset < 0 or font.glyph_index_offset < 0) return error.InvalidSlugFile;

    const page_table = font.base_offset + @as(usize, @intCast(font.page_index_offset));
    const page = @as(usize, @intCast(unicode >> 8));
    const page_index = readI16(file.bytes, page_table + page * 2);
    if (page_index < 0) return 0;

    const glyph_table = font.base_offset + @as(usize, @intCast(font.glyph_index_offset));
    const glyph_offset = (@as(usize, @intCast(page_index)) * 256 + @as(usize, @intCast(unicode & 0xFF))) * 4;
    return readU32(file.bytes, glyph_table + glyph_offset);
}

pub fn parseGlyphData(file: SlugFile, font: FontHeader, glyph_index: u32, variant: usize) !GlyphData {
    if (variant > 1) return error.InvalidVariant;
    if (glyph_index >= @as(u32, @intCast(font.glyph_count))) return error.InvalidGlyphIndex;
    const table_offset = font.glyph_data_offset[variant];
    if (table_offset <= 0) return error.MissingGlyphTable;

    const base = font.base_offset + @as(usize, @intCast(table_offset)) + @as(usize, glyph_index) * 128;
    if (base + 128 > file.bytes.len) return error.InvalidSlugFile;
    const polygon_slice: *const [24]u8 = @ptrCast(file.bytes[base + 0x28 .. base + 0x40].ptr);

    return .{
        .graphic = .{
            .bounding_box = .{
                readF32(file.bytes, base + 0x00),
                readF32(file.bytes, base + 0x04),
                readF32(file.bytes, base + 0x08),
                readF32(file.bytes, base + 0x0C),
            },
            .band_location = .{
                readU16(file.bytes, base + 0x10),
                readU16(file.bytes, base + 0x12),
            },
            .band_count = .{
                readI16(file.bytes, base + 0x14),
                readI16(file.bytes, base + 0x16),
            },
            .band_scale = .{
                readF32(file.bytes, base + 0x18),
                readF32(file.bytes, base + 0x1C),
            },
            .contour_curve_count = readU16(file.bytes, base + 0x20),
            .polygon_code = readU16(file.bytes, base + 0x22),
            .contour_data = readU32(file.bytes, base + 0x24),
            .polygon_bytes = polygon_slice.*,
        },
        .glyph_offset = .{
            readF32(file.bytes, base + 0x40),
            readF32(file.bytes, base + 0x44),
        },
        .advance_width = readF32(file.bytes, base + 0x48),
        .advance_height = readF32(file.bytes, base + 0x4C),
        .vertical_origin = readF32(file.bytes, base + 0x50),
        .decompose_data = readU32(file.bytes, base + 0x54),
        .color_layer_data = readU32(file.bytes, base + 0x58),
        .base_anchor_data = readU32(file.bytes, base + 0x5C),
        .mark_attach_data = readU32(file.bytes, base + 0x60),
        .kern_data = .{
            readU32(file.bytes, base + 0x64),
            readU32(file.bytes, base + 0x68),
        },
        .sequence_data = readU32(file.bytes, base + 0x6C),
        .alternate_data = readU32(file.bytes, base + 0x70),
        .caret_position_data = readU32(file.bytes, base + 0x74),
    };
}

pub fn extractCurveTexture(allocator: std.mem.Allocator, file: SlugFile) !struct { width: u32, height: u32, texels: []CurveTexel32 } {
    const block = file.blocks[0];
    if (block.isCompressed()) return error.CompressedTextureUnsupported;
    if (!std.mem.eql(u8, &block.storageName(), "HLF4")) return error.UnsupportedCurveTextureFormat;

    const texel_count = @as(usize, block.width) * @as(usize, block.height);
    const byte_count = texel_count * 8;
    const start = @as(usize, block.data_offset);
    const end = start + byte_count;
    if (end > file.bytes.len) return error.InvalidSlugFile;

    const texels = try allocator.alloc(CurveTexel32, texel_count);
    errdefer allocator.free(texels);

    var src = start;
    for (texels) |*texel| {
        texel.value = .{
            halfToFloat(readU16(file.bytes, src + 0)),
            halfToFloat(readU16(file.bytes, src + 2)),
            halfToFloat(readU16(file.bytes, src + 4)),
            halfToFloat(readU16(file.bytes, src + 6)),
        };
        src += 8;
    }

    return .{ .width = block.width, .height = block.height, .texels = texels };
}

pub fn extractBandTexture(allocator: std.mem.Allocator, file: SlugFile) !struct { width: u32, height: u32, texels: []BandTexel32 } {
    const block = file.blocks[1];
    if (block.isCompressed()) return error.CompressedTextureUnsupported;
    if (!std.mem.eql(u8, &block.storageName(), "16U2")) return error.UnsupportedBandTextureFormat;

    const texel_count = @as(usize, block.width) * @as(usize, block.height);
    const byte_count = texel_count * 4;
    const start = @as(usize, block.data_offset);
    const end = start + byte_count;
    if (end > file.bytes.len) return error.InvalidSlugFile;

    const texels = try allocator.alloc(BandTexel32, texel_count);
    errdefer allocator.free(texels);

    var src = start;
    for (texels) |*texel| {
        texel.value = .{
            readU16(file.bytes, src + 0),
            readU16(file.bytes, src + 2),
        };
        src += 4;
    }

    return .{ .width = block.width, .height = block.height, .texels = texels };
}

pub fn decodePolygon(graphic: GraphicData) DecodedPolygon {
    const count_u16 = graphic.polygon_code & 0x00FF;
    const count: u8 = @intCast(@min(count_u16, 6));
    var points: [6][2]f32 = undefined;
    @memset(&points, .{ 0.0, 0.0 });

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const pair_offset = i * 4;
        points[i] = .{
            halfToFloat(readU16(&graphic.polygon_bytes, pair_offset + 0)),
            halfToFloat(readU16(&graphic.polygon_bytes, pair_offset + 2)),
        };
    }

    return .{
        .code = graphic.polygon_code,
        .flags = graphic.polygon_code >> 8,
        .count = count,
        .points = points,
    };
}

pub fn extractContourCurveRefs(
    allocator: std.mem.Allocator,
    file: SlugFile,
    font: FontHeader,
) !ContourCurveRefTable {
    if (font.contour_data_offset <= 0 or font.glyph_count <= 0) {
        return .{
            .allocator = allocator,
            .glyphs = try allocator.alloc(GlyphCurveRefRange, 0),
            .curve_refs = try allocator.alloc(u32, 0),
        };
    }

    const start = font.base_offset + @as(usize, @intCast(font.contour_data_offset));
    if (start >= file.bytes.len) return error.InvalidSlugFile;

    const curve_texel_capacity = @as(u64, file.blocks[0].width) * @as(u64, file.blocks[0].height);
    var glyphs = std.ArrayList(GlyphCurveRefRange).empty;
    errdefer glyphs.deinit(allocator);
    var curve_refs = std.ArrayList(u32).empty;
    errdefer curve_refs.deinit(allocator);

    var cursor = start;
    while (glyphs.items.len < @as(usize, @intCast(font.glyph_count)) and cursor + 4 <= file.bytes.len) {
        const count = readU32(file.bytes, cursor);
        if (count > curve_texel_capacity) break;

        const end_u64 = @as(u64, cursor) + 4 + @as(u64, count) * 4;
        if (end_u64 > file.bytes.len) break;
        const end: usize = @intCast(end_u64);

        const refs_start = curve_refs.items.len;
        var ref_cursor = cursor + 4;
        var valid = true;
        while (ref_cursor < end) : (ref_cursor += 4) {
            const ref = readU32(file.bytes, ref_cursor);
            if (ref >= curve_texel_capacity) {
                valid = false;
                break;
            }
            try curve_refs.append(allocator, ref);
        }
        if (!valid) {
            curve_refs.shrinkRetainingCapacity(refs_start);
            break;
        }

        try glyphs.append(allocator, .{
            .start = refs_start,
            .len = @intCast(count),
        });
        cursor = end;
    }

    return .{
        .allocator = allocator,
        .glyphs = try glyphs.toOwnedSlice(allocator),
        .curve_refs = try curve_refs.toOwnedSlice(allocator),
    };
}

fn parseBlock(bytes: []const u8, start: usize) DataBlock {
    return .{
        .storage_tag = readU32(bytes, start + 0x00),
        .width = readU32(bytes, start + 0x04),
        .height = readU32(bytes, start + 0x08),
        .compression_tag = readU32(bytes, start + 0x0C),
        .compressed_size = readU32(bytes, start + 0x10),
        .data_offset = readU32(bytes, start + 0x14),
    };
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    const slice: *const [4]u8 = @ptrCast(bytes[offset .. offset + 4].ptr);
    return std.mem.readInt(u32, slice, .little);
}

fn readI32(bytes: []const u8, offset: usize) i32 {
    const slice: *const [4]u8 = @ptrCast(bytes[offset .. offset + 4].ptr);
    return std.mem.readInt(i32, slice, .little);
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    const slice: *const [2]u8 = @ptrCast(bytes[offset .. offset + 2].ptr);
    return std.mem.readInt(u16, slice, .little);
}

fn readI16(bytes: []const u8, offset: usize) i16 {
    const slice: *const [2]u8 = @ptrCast(bytes[offset .. offset + 2].ptr);
    return std.mem.readInt(i16, slice, .little);
}

fn readF32(bytes: []const u8, offset: usize) f32 {
    return @bitCast(readU32(bytes, offset));
}

fn halfToFloat(bits: u16) f32 {
    const half: f16 = @bitCast(bits);
    return @floatCast(half);
}

fn commonHeaderSize(_: SlugFile) usize {
    return 0x50;
}

fn looksLikeDirectoryTag(bytes: []const u8) bool {
    if (bytes.len != 4) return false;
    for (bytes) |ch| {
        if (std.ascii.isUpper(ch) or std.ascii.isDigit(ch)) continue;
        return false;
    }
    return true;
}

fn unpackTag(value: u32) [4]u8 {
    return .{
        @truncate(value & 0xFF),
        @truncate((value >> 8) & 0xFF),
        @truncate((value >> 16) & 0xFF),
        @truncate((value >> 24) & 0xFF),
    };
}

fn reverseTag(value: u32) [4]u8 {
    const tag = unpackTag(value);
    return .{ tag[3], tag[2], tag[1], tag[0] };
}

test "parse arial slug header" {
    var file = try loadFile(std.testing.allocator, "SlugDemo/Fonts/arial.slug");
    defer file.deinit();

    try std.testing.expect(file.magicOk());
    try std.testing.expectEqual(@as(u32, 0x740), file.header_size);
    try std.testing.expectEqual(@as(u32, 1), file.version);
    try std.testing.expectEqualStrings("fnt\x00", &file.kindTag());
    try std.testing.expectEqualStrings("HLF4", &file.blocks[0].storageName());
    try std.testing.expectEqualStrings("COMP", &file.blocks[0].compressionName());
    try std.testing.expectEqualStrings("16U2", &file.blocks[1].storageName());
    try std.testing.expectEqualStrings("COMP", &file.blocks[1].compressionName());
    try std.testing.expectEqual(@as(u32, 14), file.root_offset_count);

    const font = try parsePrimaryFontHeader(file);
    try std.testing.expectEqual(@as(i32, 14), font.font_key_data_count);
    try std.testing.expectEqual(@as(i32, 0x70), font.font_key_data_offset);
    try std.testing.expectEqual(@as(i32, 256), font.page_count);
    try std.testing.expectEqual(@as(i32, 0x1B0), font.page_index_offset);
    try std.testing.expectEqual(@as(i32, 0x3B0), font.glyph_index_offset);
    try std.testing.expectEqual(@as(i32, 0xEF6), font.glyph_count);
    try std.testing.expectEqual(@as(i32, 0x6FB0), font.glyph_data_offset[0]);

    var dir = try parseFontKeyDirectory(std.testing.allocator, file, font);
    defer dir.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 14), dir.entries.len);

    const expected = [_][]const u8{
        "MTRC",
        "TYPO",
        "HITE",
        "AXIS",
        "BBOX",
        "SUBS",
        "SUPS",
        "CLAS",
        "SLNT",
        "NAME",
        "SNAM",
        "UNDR",
        "STRK",
        "POLY",
    };
    for (expected, 0..) |name, i| {
        try std.testing.expectEqualStrings(name, &dir.entries[i].name());
    }

    const glyph_a = try lookupGlyphIndex(file, font, 'A');
    try std.testing.expect(glyph_a != 0);
    const glyph = try parseGlyphData(file, font, glyph_a, 0);
    try std.testing.expect(glyph.advance_width > 0.0);
    try std.testing.expect(glyph.graphic.band_count[0] > 0);
    try std.testing.expect(glyph.graphic.band_count[1] > 0);
}

test "extract uncompressed georgia textures" {
    var file = try loadFile(std.testing.allocator, "SlugDemo/Fonts/georgia_nc.slug");
    defer file.deinit();

    try std.testing.expectEqualStrings("HLF4", &file.blocks[0].storageName());
    try std.testing.expect(!file.blocks[0].isCompressed());
    try std.testing.expectEqual(@as(u32, 0x1000), file.blocks[0].width);
    try std.testing.expectEqual(@as(u32, 6), file.blocks[0].height);

    const curves = try extractCurveTexture(std.testing.allocator, file);
    defer std.testing.allocator.free(curves.texels);
    try std.testing.expectEqual(@as(usize, @intCast(curves.width * curves.height)), curves.texels.len);

    const bands = try extractBandTexture(std.testing.allocator, file);
    defer std.testing.allocator.free(bands.texels);
    try std.testing.expectEqual(@as(usize, @intCast(bands.width * bands.height)), bands.texels.len);
}

test "decode georgia polygon data" {
    var file = try loadFile(std.testing.allocator, "SlugDemo/Fonts/georgia_nc.slug");
    defer file.deinit();

    const font = try parsePrimaryFontHeader(file);
    const glyph_m = try parseGlyphData(file, font, try lookupGlyphIndex(file, font, 'M'), 0);
    const poly_m = decodePolygon(glyph_m.graphic);
    try std.testing.expectEqual(@as(u8, 4), poly_m.count);
    try std.testing.expectApproxEqAbs(glyph_m.graphic.bounding_box[2], poly_m.points[0][0], 0.0001);
    try std.testing.expectApproxEqAbs(glyph_m.graphic.bounding_box[3], poly_m.points[0][1], 0.0001);
    try std.testing.expectApproxEqAbs(glyph_m.graphic.bounding_box[0], poly_m.points[1][0], 0.0001);

    const glyph_q = try parseGlyphData(file, font, try lookupGlyphIndex(file, font, '?'), 0);
    const poly_q = decodePolygon(glyph_q.graphic);
    try std.testing.expectEqual(@as(u8, 3), poly_q.count);
}

test "decode compressed contour curve reference prefix table" {
    var file = try loadFile(std.testing.allocator, "SlugDemo/Fonts/arial.slug");
    defer file.deinit();

    const font = try parsePrimaryFontHeader(file);
    var contour_refs = try extractContourCurveRefs(std.testing.allocator, file, font);
    defer contour_refs.deinit();

    try std.testing.expect(contour_refs.curve_refs.len > 0);
    const glyph_exclaim = try lookupGlyphIndex(file, font, '!');
    const glyph_m = try lookupGlyphIndex(file, font, 'M');
    try std.testing.expect(contour_refs.glyphs.len > glyph_exclaim);
    try std.testing.expect(contour_refs.glyphs.len > glyph_m);

    const refs_exclaim = contour_refs.glyphCurveRefs(glyph_exclaim).?;
    try std.testing.expectEqual(@as(usize, 64), refs_exclaim.len);
    try std.testing.expectEqual(@as(u32, 707), refs_exclaim[0]);
    try std.testing.expectEqual(@as(u32, 1973), refs_exclaim[refs_exclaim.len - 1]);

    const refs_m = contour_refs.glyphCurveRefs(glyph_m).?;
    try std.testing.expectEqual(@as(usize, 13), refs_m.len);
    try std.testing.expectEqual(@as(u32, 3793), refs_m[0]);
    try std.testing.expectEqual(@as(u32, 3805), refs_m[refs_m.len - 1]);

    for (refs_m) |ref| {
        try std.testing.expect(ref < file.blocks[0].width * file.blocks[0].height);
    }
}

test "uncompressed font has no contour reference prefix table" {
    var file = try loadFile(std.testing.allocator, "SlugDemo/Fonts/georgia_nc.slug");
    defer file.deinit();

    const font = try parsePrimaryFontHeader(file);
    var contour_refs = try extractContourCurveRefs(std.testing.allocator, file, font);
    defer contour_refs.deinit();

    try std.testing.expectEqual(@as(usize, 0), contour_refs.glyphs.len);
    try std.testing.expectEqual(@as(usize, 0), contour_refs.curve_refs.len);
}

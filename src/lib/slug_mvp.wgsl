struct VertexIn {
    @location(0) position: vec2<f32>,
    @location(1) texcoord: vec2<f32>,
    @location(2) scale_bias: vec4<f32>,
    @location(3) glyph_band_scale: vec4<f32>,
    @location(4) band_data: vec4<u32>,
};

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) texcoord: vec2<f32>,
    @interpolate(flat) @location(1) glyph_band_scale: vec4<f32>,
    @interpolate(flat) @location(2) band_data: vec4<u32>,
};

@group(0) @binding(0) var curves_tex: texture_2d<f32>;
@group(0) @binding(1) var bands_tex: texture_2d<u32>;

fn max3(v: vec3<f32>) -> f32 {
    return max(v.x, max(v.y, v.z));
}

fn trace_ray_curve_h(p1: vec2<f32>, p2: vec2<f32>, p3: vec2<f32>, pixels_per_em: f32) -> f32 {
    if (max3(vec3<f32>(p1.x, p2.x, p3.x)) * pixels_per_em < -0.5) {
        return 0.0;
    }

    let code =
        ((0x2E74u >> ((select(0u, 2u, p1.y > 0.0)) + (select(0u, 4u, p2.y > 0.0)) + (select(0u, 8u, p3.y > 0.0)))) & 3u);
    if (code == 0u) {
        return 0.0;
    }

    let a = p1 - p2 * 2.0 + p3;
    let b = p1 - p2;
    let c = p1.y;

    var t1 = 0.0;
    var t2 = 0.0;
    if (abs(a.y) < 0.0001) {
        let t = c / (2.0 * b.y);
        t1 = t;
        t2 = t;
    } else {
        let d = sqrt(max(b.y * b.y - a.y * c, 0.0));
        let inv = 1.0 / a.y;
        t1 = (b.y - d) * inv;
        t2 = (b.y + d) * inv;
    }

    var coverage = 0.0;
    if ((code & 1u) != 0u) {
        let x1 = (a.x * t1 - b.x * 2.0) * t1 + p1.x;
        coverage += clamp(x1 * pixels_per_em + 0.5, 0.0, 1.0);
    }

    if (code > 1u) {
        let x2 = (a.x * t2 - b.x * 2.0) * t2 + p1.x;
        coverage -= clamp(x2 * pixels_per_em + 0.5, 0.0, 1.0);
    }
    return coverage;
}

fn load_band_texel(index: u32) -> vec2<u32> {
    return textureLoad(bands_tex, vec2<i32>(i32(index & 0xFFFu), i32(index >> 12u)), 0).xy;
}

fn load_curve_points(curve_loc: vec2<i32>, glyph_scale: vec2<f32>, texcoord: vec2<f32>) -> array<vec2<f32>, 3> {
    let cp12 = textureLoad(curves_tex, curve_loc, 0) / vec4<f32>(glyph_scale, glyph_scale) - vec4<f32>(texcoord, texcoord);
    let cp3 = textureLoad(curves_tex, vec2<i32>(curve_loc.x + 1, curve_loc.y), 0).xy / glyph_scale - texcoord;
    return array<vec2<f32>, 3>(cp12.xy, cp12.zw, cp3);
}

fn trace_ray_band_h(band_data: vec2<u32>, glyph_scale: vec2<f32>, texcoord: vec2<f32>, pixels_per_em: f32) -> f32 {
    var coverage = 0.0;
    for (var curve = 0u; curve < band_data.x; curve += 1u) {
        let curve_offset = band_data.y + curve;
        let curve_xy = load_band_texel(curve_offset);
        let curve_loc = vec2<i32>(i32(curve_xy.x), i32(curve_xy.y));
        let points = load_curve_points(curve_loc, glyph_scale, texcoord);
        coverage += trace_ray_curve_h(points[0], points[1], points[2], pixels_per_em);
    }
    return coverage;
}

fn trace_ray_band_v(band_data: vec2<u32>, glyph_scale: vec2<f32>, texcoord: vec2<f32>, pixels_per_em: f32) -> f32 {
    var coverage = 0.0;
    for (var curve = 0u; curve < band_data.x; curve += 1u) {
        let curve_offset = band_data.y + curve;
        let curve_xy = load_band_texel(curve_offset);
        let curve_loc = vec2<i32>(i32(curve_xy.x), i32(curve_xy.y));
        let points = load_curve_points(curve_loc, glyph_scale, texcoord);
        coverage += trace_ray_curve_h(points[0].yx, points[1].yx, points[2].yx, pixels_per_em);
    }
    return coverage;
}

@vertex
fn vs_main(input: VertexIn) -> VertexOut {
    var output: VertexOut;
    output.position = vec4<f32>(
        input.position * input.scale_bias.xy + input.scale_bias.zw,
        0.0,
        1.0,
    );
    output.texcoord = input.texcoord;
    output.glyph_band_scale = input.glyph_band_scale;
    output.band_data = input.band_data;
    return output;
}

@fragment
fn fs_main(input: VertexOut) -> @location(0) vec4<f32> {
    let glyph_scale = input.glyph_band_scale.xy;
    let band_scale = input.glyph_band_scale.zw;
    let band_max = input.band_data.xy;
    let bands_texcoords = input.band_data.zw;

    let pixels_per_em = vec2<f32>(1.0 / fwidth(input.texcoord.x), 1.0 / fwidth(input.texcoord.y));
    let band_index = vec2<u32>(clamp(
        input.texcoord * band_scale,
        vec2<f32>(0.0, 0.0),
        vec2<f32>(band_max),
    ));

    let h_band_offset = bands_texcoords.y * 4096u + bands_texcoords.x + band_index.y;
    let h_band_data = load_band_texel(h_band_offset);

    let v_band_offset = bands_texcoords.y * 4096u + bands_texcoords.x + band_max.y + 1u + band_index.x;
    let v_band_data = load_band_texel(v_band_offset);

    var coverage_x = trace_ray_band_h(h_band_data, glyph_scale, input.texcoord, pixels_per_em.x);
    var coverage_y = trace_ray_band_v(v_band_data, glyph_scale, input.texcoord, pixels_per_em.y);
    coverage_x = min(abs(coverage_x), 1.0);
    coverage_y = min(abs(coverage_y), 1.0);
    let alpha = (coverage_x + coverage_y) * 0.5;
    return vec4<f32>(0.97, 0.93, 0.85, alpha);
}

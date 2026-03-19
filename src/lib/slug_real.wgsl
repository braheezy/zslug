struct Params {
    slug_matrix: array<vec4<f32>, 4>,
    slug_viewport: vec4<f32>,
};

struct VertexIn {
    @location(0) pos: vec4<f32>,
    @location(1) tex: vec4<f32>,
    @location(2) jac: vec4<f32>,
    @location(3) bnd: vec4<f32>,
    @location(4) col: vec4<f32>,
};

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) texcoord: vec2<f32>,
    @interpolate(flat) @location(2) banding: vec4<f32>,
    @interpolate(flat) @location(3) glyph: vec4<i32>,
};

struct UnpackedData {
    banding: vec4<f32>,
    glyph: vec4<i32>,
};

struct DilatedData {
    texcoord: vec2<f32>,
    position: vec2<f32>,
};

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var curve_texture: texture_2d<f32>;
@group(0) @binding(2) var band_texture: texture_2d<u32>;

fn slug_unpack(tex: vec4<f32>, bnd: vec4<f32>) -> UnpackedData {
    let g = vec2<u32>(bitcast<u32>(tex.z), bitcast<u32>(tex.w));
    return UnpackedData(
        bnd,
        vec4<i32>(
            i32(g.x & 0xFFFFu),
            i32(g.x >> 16u),
            i32(g.y & 0xFFFFu),
            i32(g.y >> 16u),
        ),
    );
}

fn slug_dilate(
    pos: vec4<f32>,
    tex: vec4<f32>,
    jac: vec4<f32>,
    m0: vec4<f32>,
    m1: vec4<f32>,
    m3: vec4<f32>,
    dim: vec2<f32>,
) -> DilatedData {
    let n = normalize(pos.zw);
    let s = dot(m3.xy, pos.xy) + m3.w;
    let t = dot(m3.xy, n);

    let u = (s * dot(m0.xy, n) - t * (dot(m0.xy, pos.xy) + m0.w)) * dim.x;
    let v = (s * dot(m1.xy, n) - t * (dot(m1.xy, pos.xy) + m1.w)) * dim.y;

    let s2 = s * s;
    let st = s * t;
    let uv = u * u + v * v;
    let d = pos.zw * (s2 * (st + sqrt(uv)) / (uv - st * st));

    return DilatedData(vec2<f32>(tex.x + dot(d, jac.xy), tex.y + dot(d, jac.zw)), pos.xy + d);
}

@vertex
fn vs_main(input: VertexIn) -> VertexOut {
    let dilated = slug_dilate(
        input.pos,
        input.tex,
        input.jac,
        params.slug_matrix[0],
        params.slug_matrix[1],
        params.slug_matrix[3],
        params.slug_viewport.xy,
    );

    let unpacked = slug_unpack(input.tex, input.bnd);

    var output: VertexOut;
    output.texcoord = dilated.texcoord;
    output.position.x = dilated.position.x * params.slug_matrix[0].x + dilated.position.y * params.slug_matrix[0].y + params.slug_matrix[0].w;
    output.position.y = dilated.position.x * params.slug_matrix[1].x + dilated.position.y * params.slug_matrix[1].y + params.slug_matrix[1].w;
    output.position.z = dilated.position.x * params.slug_matrix[2].x + dilated.position.y * params.slug_matrix[2].y + params.slug_matrix[2].w;
    output.position.w = dilated.position.x * params.slug_matrix[3].x + dilated.position.y * params.slug_matrix[3].y + params.slug_matrix[3].w;
    output.banding = unpacked.banding;
    output.glyph = unpacked.glyph;
    output.color = input.col;
    return output;
}

fn calc_root_code(y1: f32, y2: f32, y3: f32) -> u32 {
    let i1 = bitcast<u32>(y1) >> 31u;
    let i2 = bitcast<u32>(y2) >> 30u;
    let i3 = bitcast<u32>(y3) >> 29u;

    var shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);
    return (0x2E74u >> shift) & 0x0101u;
}

fn solve_horiz_poly(p12: vec4<f32>, p3: vec2<f32>) -> vec2<f32> {
    let a = p12.xy - p12.zw * 2.0 + p3;
    let b = p12.xy - p12.zw;
    let ra = 1.0 / a.y;
    let rb = 0.5 / b.y;

    let d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
    var t1 = (b.y - d) * ra;
    var t2 = (b.y + d) * ra;

    if (abs(a.y) < 1.0 / 65536.0) {
        t1 = p12.y * rb;
        t2 = t1;
    }

    return vec2<f32>(
        (a.x * t1 - b.x * 2.0) * t1 + p12.x,
        (a.x * t2 - b.x * 2.0) * t2 + p12.x,
    );
}

fn solve_vert_poly(p12: vec4<f32>, p3: vec2<f32>) -> vec2<f32> {
    let a = p12.xy - p12.zw * 2.0 + p3;
    let b = p12.xy - p12.zw;
    let ra = 1.0 / a.x;
    let rb = 0.5 / b.x;

    let d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
    var t1 = (b.x - d) * ra;
    var t2 = (b.x + d) * ra;

    if (abs(a.x) < 1.0 / 65536.0) {
        t1 = p12.x * rb;
        t2 = t1;
    }

    return vec2<f32>(
        (a.y * t1 - b.y * 2.0) * t1 + p12.y,
        (a.y * t2 - b.y * 2.0) * t2 + p12.y,
    );
}

fn calc_band_loc(glyph_loc: vec2<i32>, offset: u32) -> vec2<i32> {
    var band_loc = vec2<i32>(glyph_loc.x + i32(offset), glyph_loc.y);
    band_loc.y += band_loc.x >> 12;
    band_loc.x &= (1 << 12) - 1;
    return band_loc;
}

fn calc_coverage(xcov: f32, ycov: f32, xwgt: f32, ywgt: f32, flags: i32) -> f32 {
    _ = flags;
    return clamp(
        max(
            abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0),
            min(abs(xcov), abs(ycov)),
        ),
        0.0,
        1.0,
    );
}

fn slug_render(render_coord: vec2<f32>, band_transform: vec4<f32>, glyph_data: vec4<i32>) -> f32 {
    let ems_per_pixel = fwidth(render_coord);
    let pixels_per_em = 1.0 / ems_per_pixel;

    var band_max = glyph_data.zw;
    band_max.y &= 0x00FF;

    let band_index = clamp(vec2<i32>(render_coord * band_transform.xy + band_transform.zw), vec2<i32>(0), band_max);
    let glyph_loc = glyph_data.xy;

    var xcov = 0.0;
    var xwgt = 0.0;

    let hband_data = textureLoad(band_texture, vec2<i32>(glyph_loc.x + band_index.y, glyph_loc.y), 0).xy;
    let hband_loc = calc_band_loc(glyph_loc, hband_data.y);

    for (var curve_index = 0; curve_index < i32(hband_data.x); curve_index += 1) {
        let curve_loc = vec2<i32>(textureLoad(band_texture, vec2<i32>(hband_loc.x + curve_index, hband_loc.y), 0).xy);
        let p12 = textureLoad(curve_texture, curve_loc, 0) - vec4<f32>(render_coord, render_coord);
        let p3 = textureLoad(curve_texture, vec2<i32>(curve_loc.x + 1, curve_loc.y), 0).xy - render_coord;

        if (max(max(p12.x, p12.z), p3.x) * pixels_per_em.x < -0.5) {
            break;
        }

        let code = calc_root_code(p12.y, p12.w, p3.y);
        if (code != 0u) {
            let r = solve_horiz_poly(p12, p3) * pixels_per_em.x;

            if ((code & 1u) != 0u) {
                xcov += clamp(r.x + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }

            if (code > 1u) {
                xcov -= clamp(r.y + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    var ycov = 0.0;
    var ywgt = 0.0;

    let vband_data = textureLoad(band_texture, vec2<i32>(glyph_loc.x + band_max.y + 1 + band_index.x, glyph_loc.y), 0).xy;
    let vband_loc = calc_band_loc(glyph_loc, vband_data.y);

    for (var curve_index = 0; curve_index < i32(vband_data.x); curve_index += 1) {
        let curve_loc = vec2<i32>(textureLoad(band_texture, vec2<i32>(vband_loc.x + curve_index, vband_loc.y), 0).xy);
        let p12 = textureLoad(curve_texture, curve_loc, 0) - vec4<f32>(render_coord, render_coord);
        let p3 = textureLoad(curve_texture, vec2<i32>(curve_loc.x + 1, curve_loc.y), 0).xy - render_coord;

        if (max(max(p12.y, p12.w), p3.y) * pixels_per_em.y < -0.5) {
            break;
        }

        let code = calc_root_code(p12.x, p12.z, p3.x);
        if (code != 0u) {
            let r = solve_vert_poly(p12, p3) * pixels_per_em.y;

            if ((code & 1u) != 0u) {
                ycov -= clamp(r.x + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }

            if (code > 1u) {
                ycov += clamp(r.y + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    return calc_coverage(xcov, ycov, xwgt, ywgt, glyph_data.w);
}

@fragment
fn fs_main(input: VertexOut) -> @location(0) vec4<f32> {
    let coverage = slug_render(input.texcoord, input.banding, input.glyph);
    return input.color * coverage;
}

struct Params {
    slug_matrix: array<vec4<f32>, 4>,
    slug_viewport: vec4<f32>,
};

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@group(0) @binding(0) var<uniform> params: Params;

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VsOut {
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>(3.0, -1.0),
        vec2<f32>(-1.0, 3.0),
    );

    var out: VsOut;
    let pos = positions[vertex_index];
    out.position = vec4<f32>(pos, 0.0, 1.0);
    out.uv = pos * 0.5 + vec2<f32>(0.5, 0.5);
    return out;
}

fn hash21(p: vec2<f32>) -> f32 {
    let q = fract(p * vec2<f32>(123.34, 456.21));
    return fract(q.x * q.y + q.x + q.y);
}

@fragment
fn fs_main(input: VsOut) -> @location(0) vec4<f32> {
    let uv = input.uv;
    let centered = uv * 2.0 - vec2<f32>(1.0, 1.0);
    let aspect = params.slug_viewport.x / params.slug_viewport.y;
    let time = params.slug_viewport.z;
    let p = vec2<f32>(centered.x * aspect, centered.y);

    let top = vec3<f32>(0.055, 0.072, 0.11);
    let bottom = vec3<f32>(0.015, 0.02, 0.032);
    var color = mix(bottom, top, clamp(uv.y * 1.2, 0.0, 1.0));

    let glow_center = vec2<f32>(
        (-0.28 + 0.11 * sin(time * 0.24)) * aspect,
        -0.16 + 0.075 * cos(time * 0.17),
    );
    let glow = exp(-3.4 * distance(p, glow_center));
    color += vec3<f32>(0.26, 0.16, 0.08) * glow * 0.42;

    let horizon = smoothstep(-0.18, 0.28, uv.y);
    color += vec3<f32>(0.08, 0.09, 0.12) * horizon * 0.12;

    let grid_uv = vec2<f32>(
        p.x * 7.5 + uv.y * 0.8 + time * 0.04,
        p.y * 10.5 + 0.18 * sin(time * 0.14),
    );
    let grid = abs(fract(grid_uv) - 0.5);
    let line_x = 1.0 - smoothstep(0.46, 0.5, grid.x);
    let line_y = 1.0 - smoothstep(0.475, 0.5, grid.y);
    let grid_mask = max(line_x * 0.45, line_y * 0.2) * smoothstep(0.12, 0.86, uv.y);
    color += vec3<f32>(0.14, 0.13, 0.1) * grid_mask * 0.16;

    let noise = hash21(floor(uv * params.slug_viewport.xy * 0.35) + vec2<f32>(time * 11.0, time * 5.0)) - 0.5;
    color += noise * 0.012;

    let vignette = smoothstep(1.45, 0.3, length(vec2<f32>(centered.x * 0.9, centered.y * 1.15)));
    color *= vignette;

    return vec4<f32>(color, 1.0);
}

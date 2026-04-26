const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zslug = @import("zslug");

const wgpu = zgpu.wgpu;
const math = std.math;
const shader_source = @embedFile("lib/slug_real.wgsl");
const backdrop_shader_source = @embedFile("lib/backdrop.wgsl");

const SlugVertex = zslug.slug.SlugVertex;
const CurveTexel = zslug.slug.CurveTexel;
const BandTexel = zslug.slug.BandTexel;

var current_app: ?*App = null;

const Uniforms = extern struct {
    slug_matrix: [4][4]f32,
    slug_viewport: [4]f32,
};

const App = @This();
allocator: std.mem.Allocator,
window: *zglfw.Window,
gfx: *zgpu.GraphicsContext,
scene: zslug.slug.Scene,
backdrop_pipeline: zgpu.RenderPipelineHandle = .{},
pipeline: zgpu.RenderPipelineHandle = .{},
backdrop_bind_group: zgpu.BindGroupHandle = .{},
bind_group: zgpu.BindGroupHandle = .{},
vertex_buffer: zgpu.BufferHandle = .{},
index_buffer: zgpu.BufferHandle = .{},
curve_texture: zgpu.TextureHandle = .{},
curve_view: zgpu.TextureViewHandle = .{},
band_texture: zgpu.TextureHandle = .{},
band_view: zgpu.TextureViewHandle = .{},
index_count: u32 = 0,
uniform_offset: u32 = 0,
orbit_yaw: f32 = 0.16,
orbit_pitch: f32 = 0.12,
camera_distance: f32 = 4.2,
camera_target: [2]f32 = .{ 0.0, 0.0 },
last_cursor_pos: [2]f64 = .{ 0.0, 0.0 },
pending_scroll: f32 = 0.0,
auto_motion: bool = true,
reset_was_down: bool = false,
drift_toggle_was_down: bool = false,

pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !*App {
    try zglfw.init();
    errdefer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    zglfw.windowHint(.resizable, false);
    const window = try zglfw.createWindow(800, 600, "zslug", null, null);
    errdefer zglfw.destroyWindow(window);

    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    app.* = .{
        .allocator = allocator,
        .window = window,
        .gfx = undefined,
        .scene = undefined,
    };
    current_app = app;

    app.gfx = try zgpu.GraphicsContext.create(allocator, .{
        .window = window,
        .fn_getTime = @ptrCast(&zglfw.getTime),
        .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
        .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
        .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
        .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
        .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
        .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
        .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
    }, .{});
    errdefer app.gfx.destroy(allocator);

    app.scene = try zslug.slug.buildDemoScene(allocator, io, environ_map, .{
        @floatFromInt(app.gfx.width),
        @floatFromInt(app.gfx.height),
    });
    errdefer app.scene.deinit();

    try stylizeScene(allocator, &app.scene);
    app.last_cursor_pos = window.getCursorPos();
    _ = zglfw.setScrollCallback(window, onScroll);

    try app.createResources();
    return app;
}

pub fn deinit(self: *App) void {
    if (current_app == self) current_app = null;
    self.gfx.releaseResource(self.backdrop_pipeline);
    self.gfx.releaseResource(self.pipeline);
    self.gfx.releaseResource(self.backdrop_bind_group);
    self.gfx.releaseResource(self.bind_group);
    self.gfx.releaseResource(self.band_view);
    self.gfx.destroyResource(self.band_texture);
    self.gfx.releaseResource(self.curve_view);
    self.gfx.destroyResource(self.curve_texture);
    self.gfx.destroyResource(self.index_buffer);
    self.gfx.destroyResource(self.vertex_buffer);
    self.scene.deinit();
    self.gfx.destroy(self.allocator);
    zglfw.destroyWindow(self.window);
    zglfw.terminate();
    self.allocator.destroy(self);
}

pub fn isRunning(self: *App) bool {
    return !self.window.shouldClose() and self.window.getKey(.escape) != .press;
}

pub fn update(self: *App) void {
    zglfw.pollEvents();

    self.updateCameraControls();

    const width = @as(f32, @floatFromInt(self.gfx.width));
    const height = @as(f32, @floatFromInt(self.gfx.height));
    const time = @as(f32, @floatCast(self.gfx.stats.time));
    const mem = self.gfx.uniformsAllocate(Uniforms, 1);
    mem.slice[0] = .{
        .slug_matrix = makeSceneMatrix(width, height, time, self),
        .slug_viewport = .{ width, height, time, 0.0 },
    };
    self.uniform_offset = mem.offset;
}

pub fn draw(self: *App) void {
    const back_buffer_view = self.gfx.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = self.gfx.device.createCommandEncoder(null);
        defer encoder.release();

        const pipeline = self.gfx.lookupResource(self.pipeline) orelse break :commands encoder.finish(null);
        const bind_group = self.gfx.lookupResource(self.bind_group) orelse break :commands encoder.finish(null);
        const vertex_info = self.gfx.lookupResourceInfo(self.vertex_buffer) orelse break :commands encoder.finish(null);
        const index_info = self.gfx.lookupResourceInfo(self.index_buffer) orelse break :commands encoder.finish(null);

        {
            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = back_buffer_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.01, .g = 0.015, .b = 0.022, .a = 1.0 },
            }};
            const pass = encoder.beginRenderPass(.{
                .color_attachment_count = color_attachments.len,
                .color_attachments = &color_attachments,
            });
            defer {
                pass.end();
                pass.release();
            }

            if (self.gfx.lookupResource(self.backdrop_pipeline)) |backdrop_pipeline| {
                if (self.gfx.lookupResource(self.backdrop_bind_group)) |backdrop_bind_group| {
                    pass.setPipeline(backdrop_pipeline);
                    pass.setBindGroup(0, backdrop_bind_group, &.{self.uniform_offset});
                    pass.draw(3, 1, 0, 0);
                }
            }

            pass.setPipeline(pipeline);
            pass.setBindGroup(0, bind_group, &.{self.uniform_offset});
            pass.setVertexBuffer(0, vertex_info.gpuobj.?, 0, vertex_info.size);
            pass.setIndexBuffer(index_info.gpuobj.?, .uint32, 0, index_info.size);
            pass.drawIndexed(self.index_count, 1, 0, 0, 0);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    self.gfx.submit(&.{commands});
    _ = self.gfx.present();
}

fn createResources(self: *App) !void {
    const backdrop_bind_group_layout = self.gfx.createBindGroupLayout(&.{
        zgpu.bufferEntry(0, wgpu.ShaderStages.vertex | wgpu.ShaderStages.fragment, .uniform, true, 0),
    });
    defer self.gfx.releaseResource(backdrop_bind_group_layout);

    const bind_group_layout = self.gfx.createBindGroupLayout(&.{
        zgpu.bufferEntry(0, wgpu.ShaderStages.vertex, .uniform, true, 0),
        .{
            .binding = 1,
            .visibility = wgpu.ShaderStages.fragment,
            .texture = .{
                .sample_type = .unfilterable_float,
                .view_dimension = .tvdim_2d,
                .multisampled = .false,
            },
        },
        .{
            .binding = 2,
            .visibility = wgpu.ShaderStages.fragment,
            .texture = .{
                .sample_type = .uint,
                .view_dimension = .tvdim_2d,
                .multisampled = .false,
            },
        },
    });
    defer self.gfx.releaseResource(bind_group_layout);

    const backdrop_pipeline_layout = self.gfx.createPipelineLayout(&.{backdrop_bind_group_layout});
    defer self.gfx.releaseResource(backdrop_pipeline_layout);

    const pipeline_layout = self.gfx.createPipelineLayout(&.{bind_group_layout});
    defer self.gfx.releaseResource(pipeline_layout);

    const backdrop_shader = zgpu.createWgslShaderModule(self.gfx.device, backdrop_shader_source, "backdrop");
    defer backdrop_shader.release();
    const shader = zgpu.createWgslShaderModule(self.gfx.device, shader_source, "slug-real");
    defer shader.release();

    const color_targets = [_]wgpu.ColorTargetState{.{
        .format = zgpu.GraphicsContext.swapchain_format,
        .blend = &wgpu.BlendState{
            .color = .{
                .src_factor = .src_alpha,
                .dst_factor = .one_minus_src_alpha,
                .operation = .add,
            },
            .alpha = .{
                .src_factor = .zero,
                .dst_factor = .one,
                .operation = .add,
            },
        },
        .write_mask = wgpu.ColorWriteMasks.all,
    }};

    const vertex_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x4, .offset = @offsetOf(SlugVertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x4, .offset = @offsetOf(SlugVertex, "tex"), .shader_location = 1 },
        .{ .format = .float32x4, .offset = @offsetOf(SlugVertex, "jac"), .shader_location = 2 },
        .{ .format = .float32x4, .offset = @offsetOf(SlugVertex, "bnd"), .shader_location = 3 },
        .{ .format = .float32x4, .offset = @offsetOf(SlugVertex, "col"), .shader_location = 4 },
    };
    const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
        .array_stride = @sizeOf(SlugVertex),
        .step_mode = .vertex,
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    }};

    self.backdrop_pipeline = self.gfx.createRenderPipeline(backdrop_pipeline_layout, .{
        .vertex = .{
            .module = backdrop_shader,
            .entry_point = wgpu.StringView.fromSlice("vs_main"),
        },
        .primitive = .{
            .topology = .triangle_list,
            .front_face = .ccw,
            .cull_mode = .none,
        },
        .fragment = &.{
            .module = backdrop_shader,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
    });

    self.pipeline = self.gfx.createRenderPipeline(pipeline_layout, .{
        .vertex = .{
            .module = shader,
            .entry_point = wgpu.StringView.fromSlice("vs_main"),
            .buffer_count = vertex_buffers.len,
            .buffers = &vertex_buffers,
        },
        .primitive = .{
            .topology = .triangle_list,
            .front_face = .ccw,
            .cull_mode = .none,
        },
        .fragment = &.{
            .module = shader,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
    });

    self.vertex_buffer = self.gfx.createBuffer(.{
        .usage = wgpu.BufferUsages.copy_dst | wgpu.BufferUsages.vertex,
        .size = self.scene.vertices.len * @sizeOf(SlugVertex),
    });
    self.gfx.queue.writeBuffer(self.gfx.lookupResource(self.vertex_buffer).?, 0, SlugVertex, self.scene.vertices);

    self.index_count = @intCast(self.scene.indices.len);
    self.index_buffer = self.gfx.createBuffer(.{
        .usage = wgpu.BufferUsages.copy_dst | wgpu.BufferUsages.index,
        .size = self.scene.indices.len * @sizeOf(u32),
    });
    self.gfx.queue.writeBuffer(self.gfx.lookupResource(self.index_buffer).?, 0, u32, self.scene.indices);

    self.curve_texture = self.gfx.createTexture(.{
        .usage = wgpu.TextureUsages.copy_dst | wgpu.TextureUsages.texture_binding,
        .dimension = .tdim_2d,
        .size = .{
            .width = self.scene.curves_width,
            .height = self.scene.curves_height,
            .depth_or_array_layers = 1,
        },
        .format = .rgba32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    self.curve_view = self.gfx.createTextureView(self.curve_texture, .{});
    self.gfx.queue.writeTexture(
        .{ .texture = self.gfx.lookupResource(self.curve_texture).? },
        .{
            .bytes_per_row = self.scene.curves_width * @sizeOf(CurveTexel),
            .rows_per_image = self.scene.curves_height,
        },
        .{
            .width = self.scene.curves_width,
            .height = self.scene.curves_height,
            .depth_or_array_layers = 1,
        },
        CurveTexel,
        self.scene.curves_texels,
    );

    self.band_texture = self.gfx.createTexture(.{
        .usage = wgpu.TextureUsages.copy_dst | wgpu.TextureUsages.texture_binding,
        .dimension = .tdim_2d,
        .size = .{
            .width = self.scene.bands_width,
            .height = self.scene.bands_height,
            .depth_or_array_layers = 1,
        },
        .format = .rg32_uint,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    self.band_view = self.gfx.createTextureView(self.band_texture, .{});
    self.gfx.queue.writeTexture(
        .{ .texture = self.gfx.lookupResource(self.band_texture).? },
        .{
            .bytes_per_row = self.scene.bands_width * @sizeOf(BandTexel),
            .rows_per_image = self.scene.bands_height,
        },
        .{
            .width = self.scene.bands_width,
            .height = self.scene.bands_height,
            .depth_or_array_layers = 1,
        },
        BandTexel,
        self.scene.bands_texels,
    );

    self.bind_group = self.gfx.createBindGroup(bind_group_layout, &.{
        .{
            .binding = 0,
            .buffer_handle = self.gfx.uniforms.buffer,
            .offset = 0,
            .size = @sizeOf(Uniforms),
        },
        .{ .binding = 1, .texture_view_handle = self.curve_view },
        .{ .binding = 2, .texture_view_handle = self.band_view },
    });

    self.backdrop_bind_group = self.gfx.createBindGroup(backdrop_bind_group_layout, &.{
        .{
            .binding = 0,
            .buffer_handle = self.gfx.uniforms.buffer,
            .offset = 0,
            .size = @sizeOf(Uniforms),
        },
    });
}

fn updateCameraControls(self: *App) void {
    const cursor = self.window.getCursorPos();
    const dx = @as(f32, @floatCast(cursor[0] - self.last_cursor_pos[0]));
    const dy = @as(f32, @floatCast(cursor[1] - self.last_cursor_pos[1]));
    self.last_cursor_pos = cursor;

    const shift_down = self.window.getKey(.left_shift) == .press or self.window.getKey(.right_shift) == .press;
    const left_down = self.window.getMouseButton(.left) == .press;
    const right_down = self.window.getMouseButton(.right) == .press or self.window.getMouseButton(.middle) == .press;

    if (left_down and !shift_down) {
        self.orbit_yaw = std.math.clamp(self.orbit_yaw + dx * 0.005, -0.52, 0.52);
        self.orbit_pitch = std.math.clamp(self.orbit_pitch + dy * 0.004, -0.32, 0.34);
        if (dx != 0.0 or dy != 0.0) self.auto_motion = false;
    } else if (right_down or (left_down and shift_down)) {
        const pan_scale = self.camera_distance * 0.0012;
        self.camera_target[0] += dx * pan_scale;
        self.camera_target[1] += dy * pan_scale;
        self.camera_target[0] = std.math.clamp(self.camera_target[0], -1.6, 1.6);
        self.camera_target[1] = std.math.clamp(self.camera_target[1], -1.2, 1.2);
        if (dx != 0.0 or dy != 0.0) self.auto_motion = false;
    }

    if (self.pending_scroll != 0.0) {
        self.camera_distance = std.math.clamp(self.camera_distance - self.pending_scroll * 0.22, 3.0, 6.2);
        self.pending_scroll = 0.0;
        self.auto_motion = false;
    }

    const reset_down = self.window.getKey(.r) == .press;
    if (reset_down and !self.reset_was_down) self.resetCamera();
    self.reset_was_down = reset_down;

    const drift_toggle_down = self.window.getKey(.space) == .press;
    if (drift_toggle_down and !self.drift_toggle_was_down) self.auto_motion = !self.auto_motion;
    self.drift_toggle_was_down = drift_toggle_down;
}

fn resetCamera(self: *App) void {
    self.orbit_yaw = 0.16;
    self.orbit_pitch = 0.12;
    self.camera_distance = 4.2;
    self.camera_target = .{ 0.0, 0.0 };
    self.auto_motion = true;
}

fn makeSceneMatrix(width: f32, height: f32, time: f32, app: *const App) [4][4]f32 {
    const aspect = width / height;
    const fov_y = 0.24 * math.pi;
    const sy = 1.0 / @tan(fov_y * 0.5);
    const sx = sy / aspect;
    const near = 0.1;
    const far = 10.0;
    const proj_a = far / (far - near);
    const proj_b = -(near * far) / (far - near);

    const ax = 1.0 / height;
    const ay = 1.0 / height;
    const bx = -0.5 * width / height;
    const by = -0.5;

    const auto_yaw = if (app.auto_motion) 0.03 * @sin(time * 0.31) else 0.0;
    const auto_pitch = if (app.auto_motion) 0.022 * @cos(time * 0.23) else 0.0;
    const auto_distance = if (app.auto_motion) 0.12 * @sin(time * 0.17) else 0.0;
    const auto_target_x = if (app.auto_motion) 0.06 * @sin(time * 0.11) else 0.0;
    const auto_target_y = if (app.auto_motion) 0.03 * @cos(time * 0.13) else 0.0;

    const yaw = app.orbit_yaw + auto_yaw;
    const pitch = app.orbit_pitch + auto_pitch;
    const distance = app.camera_distance + auto_distance;
    const target_x = app.camera_target[0] + auto_target_x;
    const target_y = app.camera_target[1] + auto_target_y;

    const origin = [3]f32{
        -0.01 + target_x * 0.85,
        -0.005 + target_y * 0.8,
        distance,
    };
    const basis_x = [3]f32{
        1.78,
        0.0,
        0.08 + 0.9 * @sin(yaw),
    };
    const basis_y = [3]f32{
        0.06 + 0.34 * @sin(yaw),
        -1.88,
        -0.24 + 0.95 * @sin(pitch),
    };

    const ox = origin[0] + bx * basis_x[0] + by * basis_y[0];
    const oy = origin[1] + bx * basis_x[1] + by * basis_y[1];
    const oz = origin[2] + bx * basis_x[2] + by * basis_y[2];

    return .{
        .{ sx * ax * basis_x[0], sx * ay * basis_y[0], 0.0, sx * ox },
        .{ -sy * ax * basis_x[1], -sy * ay * basis_y[1], 0.0, -sy * oy },
        .{ proj_a * ax * basis_x[2], proj_a * ay * basis_y[2], 0.0, proj_a * oz + proj_b },
        .{ ax * basis_x[2], ay * basis_y[2], 0.0, oz },
    };
}

fn onScroll(window: *zglfw.Window, _: f64, yoffset: f64) callconv(.c) void {
    if (current_app) |app| {
        if (app.window == window) {
            app.pending_scroll += @floatCast(yoffset);
        }
    }
}

fn stylizeScene(allocator: std.mem.Allocator, scene: *zslug.slug.Scene) !void {
    const base_vertices = scene.vertices;
    const base_indices = scene.indices;

    const layer_count: usize = 3;
    const styled_vertices = try allocator.alloc(SlugVertex, base_vertices.len * layer_count);
    errdefer allocator.free(styled_vertices);
    const styled_indices = try allocator.alloc(u32, base_indices.len * layer_count);
    errdefer allocator.free(styled_indices);

    const layers = [_]struct {
        offset: [2]f32,
        color: [4]f32,
    }{
        .{
            .offset = .{ 28.0, 22.0 },
            .color = .{ 0.16, 0.09, 0.04, 0.26 },
        },
        .{
            .offset = .{ -10.0, -8.0 },
            .color = .{ 0.88, 0.66, 0.3, 0.07 },
        },
        .{
            .offset = .{ 0.0, 0.0 },
            .color = .{ -1.0, -1.0, -1.0, -1.0 },
        },
    };

    for (layers, 0..) |layer, layer_index| {
        const vertex_base = layer_index * base_vertices.len;
        const index_base = layer_index * base_indices.len;
        const vertex_offset: u32 = @intCast(vertex_base);

        for (base_vertices, 0..) |vertex, i| {
            var out = vertex;
            out.pos[0] += layer.offset[0];
            out.pos[1] += layer.offset[1];
            if (layer.color[3] >= 0.0) {
                out.col = layer.color;
            }
            styled_vertices[vertex_base + i] = out;
        }
        for (base_indices, 0..) |index, i| {
            styled_indices[index_base + i] = index + vertex_offset;
        }
    }

    allocator.free(scene.vertices);
    allocator.free(scene.indices);
    scene.vertices = styled_vertices;
    scene.indices = styled_indices;
}

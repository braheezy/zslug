const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zslug = @import("zslug");

const wgpu = zgpu.wgpu;
const shader_source = @embedFile("lib/slug_mvp.wgsl");

const QuadVertex = extern struct {
    position: [2]f32,
    texcoord: [2]f32,
};

const GlyphInstance = zslug.slug.GlyphInstance;
const CurveTexel = zslug.slug.CurveTexel;
const BandTexel = zslug.slug.BandTexel;

const App = @This();
allocator: std.mem.Allocator,
window: *zglfw.Window,
gfx: *zgpu.GraphicsContext,
scene: zslug.slug.Scene,
pipeline: zgpu.RenderPipelineHandle = .{},
bind_group: zgpu.BindGroupHandle = .{},
quad_buffer: zgpu.BufferHandle = .{},
instance_buffer: zgpu.BufferHandle = .{},
curve_texture: zgpu.TextureHandle = .{},
curve_view: zgpu.TextureViewHandle = .{},
band_texture: zgpu.TextureHandle = .{},
band_view: zgpu.TextureViewHandle = .{},
instance_count: u32 = 0,

pub fn init(allocator: std.mem.Allocator) !*App {
    try zglfw.init();
    errdefer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    zglfw.windowHint(.resizable, false);
    const window = try zglfw.createWindow(800, 600, "zslug", null);
    errdefer zglfw.destroyWindow(window);

    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    app.* = .{
        .allocator = allocator,
        .window = window,
        .gfx = undefined,
        .scene = undefined,
    };

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

    app.scene = try zslug.slug.buildDemoScene(allocator, .{
        @floatFromInt(app.gfx.width),
        @floatFromInt(app.gfx.height),
    });
    errdefer app.scene.deinit();

    try app.createResources();
    return app;
}

pub fn deinit(self: *App) void {
    self.gfx.releaseResource(self.band_view);
    self.gfx.destroyResource(self.band_texture);
    self.gfx.releaseResource(self.curve_view);
    self.gfx.destroyResource(self.curve_texture);
    self.gfx.destroyResource(self.instance_buffer);
    self.gfx.destroyResource(self.quad_buffer);
    self.scene.deinit();
    self.gfx.destroy(self.allocator);
    zglfw.destroyWindow(self.window);
    zglfw.terminate();
    self.allocator.destroy(self);
}

pub fn isRunning(self: *App) bool {
    return !self.window.shouldClose() and self.window.getKey(.escape) != .press;
}

pub fn update(_: *App) void {
    zglfw.pollEvents();
}

pub fn draw(self: *App) void {
    const back_buffer_view = self.gfx.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = self.gfx.device.createCommandEncoder(null);
        defer encoder.release();

        const pipeline = self.gfx.lookupResource(self.pipeline) orelse break :commands encoder.finish(null);
        const bind_group = self.gfx.lookupResource(self.bind_group) orelse break :commands encoder.finish(null);
        const quad_buffer = self.gfx.lookupResource(self.quad_buffer) orelse break :commands encoder.finish(null);
        const instance_info = self.gfx.lookupResourceInfo(self.instance_buffer) orelse break :commands encoder.finish(null);

        {
            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = back_buffer_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.05, .g = 0.06, .b = 0.09, .a = 1.0 },
            }};
            const pass = encoder.beginRenderPass(.{
                .color_attachment_count = color_attachments.len,
                .color_attachments = &color_attachments,
            });
            defer {
                pass.end();
                pass.release();
            }

            pass.setPipeline(pipeline);
            pass.setBindGroup(0, bind_group, &.{});
            pass.setVertexBuffer(0, quad_buffer, 0, 6 * @sizeOf(QuadVertex));
            pass.setVertexBuffer(1, instance_info.gpuobj.?, 0, instance_info.size);
            pass.draw(6, self.instance_count, 0, 0);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();
    self.gfx.submit(&.{commands});
    _ = self.gfx.present();
}

fn createResources(self: *App) !void {
    const bind_group_layout = self.gfx.createBindGroupLayout(&.{
        .{
            .binding = 0,
            .visibility = wgpu.ShaderStages.fragment,
            .texture = .{
                .sample_type = .unfilterable_float,
                .view_dimension = .tvdim_2d,
                .multisampled = .false,
            },
        },
        .{
            .binding = 1,
            .visibility = wgpu.ShaderStages.fragment,
            .texture = .{
                .sample_type = .uint,
                .view_dimension = .tvdim_2d,
                .multisampled = .false,
            },
        },
    });
    defer self.gfx.releaseResource(bind_group_layout);

    const pipeline_layout = self.gfx.createPipelineLayout(&.{bind_group_layout});
    defer self.gfx.releaseResource(pipeline_layout);

    const shader = zgpu.createWgslShaderModule(self.gfx.device, shader_source, "slug");
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

    const quad_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(QuadVertex, "texcoord"), .shader_location = 1 },
    };
    const instance_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x4, .offset = @offsetOf(GlyphInstance, "scale_bias"), .shader_location = 2 },
        .{ .format = .float32x4, .offset = @offsetOf(GlyphInstance, "glyph_band_scale"), .shader_location = 3 },
        .{ .format = .uint32x4, .offset = @offsetOf(GlyphInstance, "band_data"), .shader_location = 4 },
    };
    const vertex_buffers = [_]wgpu.VertexBufferLayout{
        .{
            .array_stride = @sizeOf(QuadVertex),
            .step_mode = .vertex,
            .attribute_count = quad_attributes.len,
            .attributes = &quad_attributes,
        },
        .{
            .array_stride = @sizeOf(GlyphInstance),
            .step_mode = .instance,
            .attribute_count = instance_attributes.len,
            .attributes = &instance_attributes,
        },
    };

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

    const quad_vertices = [_]QuadVertex{
        .{ .position = .{ -1.0, -1.0 }, .texcoord = .{ 0.0, 0.0 } },
        .{ .position = .{ -1.0, 1.0 }, .texcoord = .{ 0.0, 1.0 } },
        .{ .position = .{ 1.0, 1.0 }, .texcoord = .{ 1.0, 1.0 } },
        .{ .position = .{ -1.0, -1.0 }, .texcoord = .{ 0.0, 0.0 } },
        .{ .position = .{ 1.0, 1.0 }, .texcoord = .{ 1.0, 1.0 } },
        .{ .position = .{ 1.0, -1.0 }, .texcoord = .{ 1.0, 0.0 } },
    };
    self.quad_buffer = self.gfx.createBuffer(.{
        .usage = wgpu.BufferUsages.copy_dst | wgpu.BufferUsages.vertex,
        .size = quad_vertices.len * @sizeOf(QuadVertex),
    });
    self.gfx.queue.writeBuffer(self.gfx.lookupResource(self.quad_buffer).?, 0, QuadVertex, &quad_vertices);

    self.instance_count = @intCast(self.scene.instances.len);
    self.instance_buffer = self.gfx.createBuffer(.{
        .usage = wgpu.BufferUsages.copy_dst | wgpu.BufferUsages.vertex,
        .size = self.scene.instances.len * @sizeOf(GlyphInstance),
    });
    self.gfx.queue.writeBuffer(self.gfx.lookupResource(self.instance_buffer).?, 0, GlyphInstance, self.scene.instances);

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
        .{ .binding = 0, .texture_view_handle = self.curve_view },
        .{ .binding = 1, .texture_view_handle = self.band_view },
    });
}

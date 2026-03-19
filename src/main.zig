const std = @import("std");
const builtin = @import("builtin");
const zslug = @import("zslug");

const App = @import("App.zig");

pub fn main() !void {
    // Memory allocation setup
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    // Memory allocation setup
    const allocator, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        if (debug_allocator.deinit() == .leak) {
            std.process.exit(1);
        }
    };

    const app = try App.init(allocator);
    defer app.deinit();

    while (app.isRunning()) {
        app.update();
        app.draw();
    }
}

const std = @import("std");
const zx = @import("zx");

const config = zx.App.Config{ .server = .{} };

pub fn main() !void {
    if (zx.platform == .browser) return try zx.Client.run();
    if (zx.platform == .edge) return try zx.Edge.run();

    const allocator = std.heap.smp_allocator;
    const app = try zx.Server(void).init(allocator, config, {});
    defer app.deinit();

    app.info();
    try app.start();
}

pub const std_options = zx.std_options;

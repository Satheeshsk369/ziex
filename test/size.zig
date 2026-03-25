const std = @import("std");
const zx = @import("zx");

test "Style size" {
    const size = @sizeOf(zx.Style);
    const alignment = @alignOf(zx.Style);
    
    std.debug.print("\n--- Style Metrics (Optimized + Dynamic Selectors) ---\n", .{});
    std.debug.print("Size:      {d} bytes\n", .{size});
    std.debug.print("Size (KB): {d:.2} KB\n", .{@as(f64, @floatFromInt(size)) / 1024.0});
    std.debug.print("Alignment: {d} bytes\n", .{alignment});
    std.debug.print("-----------------------------------------------------\n", .{});
}

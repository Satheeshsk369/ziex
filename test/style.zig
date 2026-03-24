const std = @import("std");
const zx = @import("zx");

test "StyleSheet formatting" {
    const allocator = std.testing.allocator;
    const style: zx.StyleSheet = .{
        .display = .flex,
        .flexDirection = .column,
        .backgroundColor = .hex(0xff0000),
        .paddingTop = .px(10),
        .width = .px(100),
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{style});
    defer allocator.free(result);
    
    std.debug.print("\nGenerated CSS: {s}\n", .{result});
    
    try std.testing.expect(std.mem.indexOf(u8, result, "display: flex;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "flex-direction: column;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "background-color: #ff0000;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "padding-top: 10px;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "width: 100px;") != null);
}

test "StyleSheet in Component" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var ctx = zx.allocInit(arena_allocator);

    const style: zx.StyleSheet = .{
        .color = .hex(0x0000ff),
        .marginTop = .px(20),
    };

    const comp = ctx.ele(.div, .{
        .attributes = &[_]zx.Element.Attribute{
            ctx.attr("style", style).?,
            ctx.attr("class", "my-div").?,
        },
        .children = &[_]zx.Component{
            ctx.txt("Hello with style"),
        },
    });
    // deinit is not strictly needed with arena but good practice if we want to test it
    defer comp.deinit(arena_allocator);

    try std.testing.expectEqual(zx.ElementTag.div, comp.element.tag);
    
    var found_style = false;
    for (comp.element.attributes.?) |attr| {
        if (std.mem.eql(u8, attr.name, "style")) {
            const expected_style = "color: #0000ff; margin-top: 20px; ";
            try std.testing.expectEqualStrings(expected_style, attr.value.?);
            found_style = true;
        }
    }
    try std.testing.expect(found_style);
}


const std = @import("std");

pub const Unit = enum {
    px, em, rem, vh, vw, vmin, vmax, @"%", pt, pc, in, cm, mm,
    deg, rad, grad, turn,
    s, ms,
    Hz, kHz,
    dpi, dpcm, dppx,

    pub fn toString(self: Unit) []const u8 {
        return switch (self) {
            .@"%" => "%",
            else => @tagName(self),
        };
    }
};

pub const Dimension = struct {
    value: f32,
    unit: Unit,
};

pub const Color = union(enum) {
    hex_: u32,
    rgb_: struct { r: u8, g: u8, b: u8 },
    rgba_: struct { r: u8, g: u8, b: u8, a: f32 },
    keyword_: []const u8,

    pub fn hex(val: u32) Color { return .{ .hex_ = val }; }
    pub fn rgb(r: u8, g: u8, b: u8) Color { return .{ .rgb_ = .{ .r = r, .g = g, .b = b } }; }
    pub fn rgba(r: u8, g: u8, b: u8, a: f32) Color { return .{ .rgba_ = .{ .r = r, .g = g, .b = b, .a = a } }; }
    pub fn kw(k: []const u8) Color { return .{ .keyword_ = k }; }

    pub fn format(self: Color, w: *std.io.Writer) std.io.Writer.Error!void {
        switch (self) {
            .hex_ => |h| try w.print("#{x:0>6}", .{h}),
            .keyword_ => |k| try w.writeAll(k),
            .rgb_ => |c| try w.print("rgb({d},{d},{d})", .{ c.r, c.g, c.b }),
            .rgba_ => |c| try w.print("rgba({d},{d},{d},{d})", .{ c.r, c.g, c.b, c.a }),
        }
    }
};

/// Formats a Zig camelCase name into a CSS kebab-case string
pub fn formatKebab(name: []const u8, w: anytype) !void {
    const prefixes = [_][]const u8{ "webkit", "moz", "ms", "apple", "epub", "hp", "atsc", "rim", "ro", "tc", "xhtml" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, name, p) and name.len > p.len and std.ascii.isUpper(name[p.len])) {
            try w.writeByte('-');
            break;
        }
    }

    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            try w.writeByte('-');
            try w.writeByte(std.ascii.toLower(c));
        } else if (c == '_' and i == name.len - 1) {
            continue;
        } else {
            try w.writeByte(c);
        }
    }
}

pub fn formatValue(value: anytype, w: *std.io.Writer) std.io.Writer.Error!void {
    @setEvalBranchQuota(10000);
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"union";
    const tag = @as(info.tag_type.?, value);

    if (tag == .none) return;

    inline for (info.fields) |f| {
        if (tag == @field(info.tag_type.?, f.name)) {
            if (comptime std.mem.eql(u8, f.name, "hex_")) {
                try w.print("#{x:0>6}", .{@field(value, f.name)});
                return;
            }
            if (comptime f.type == Color) {
                try @field(value, f.name).format(w);
                return;
            }
            if (comptime std.mem.eql(u8, f.name, "raw_")) {
                try w.writeAll(@field(value, f.name));
                return;
            }
            if (comptime std.mem.eql(u8, f.name, "percent_")) {
                try w.print("{d}%", .{@field(value, f.name)});
                return;
            }
            
            // Check for other units manually to avoid concatenation evaluation issues
            if (comptime std.mem.eql(u8, f.name, "px_")) { try w.print("{d}px", .{@field(value, f.name)}); return; }
            if (comptime std.mem.eql(u8, f.name, "em_")) { try w.print("{d}em", .{@field(value, f.name)}); return; }
            if (comptime std.mem.eql(u8, f.name, "rem_")) { try w.print("{d}rem", .{@field(value, f.name)}); return; }
            if (comptime std.mem.eql(u8, f.name, "vh_")) { try w.print("{d}vh", .{@field(value, f.name)}); return; }
            if (comptime std.mem.eql(u8, f.name, "vw_")) { try w.print("{d}vw", .{@field(value, f.name)}); return; }
            if (comptime std.mem.eql(u8, f.name, "vmin_")) { try w.print("{d}vmin", .{@field(value, f.name)}); return; }
            if (comptime std.mem.eql(u8, f.name, "vmax_")) { try w.print("{d}vmax", .{@field(value, f.name)}); return; }
            
            // Keywords
            try formatKebab(f.name, w);
            return;
        }
    }
}

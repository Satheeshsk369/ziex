//! HTML escaping and unescaping utilities.

const std = @import("std");

/// Escape a string for use inside an HTML attribute value.
/// Escapes: `& < > " '`
pub fn escapeAttr(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#x27;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Escape a string for use inside an HTML text node.
/// Escapes: `& < >`
pub fn escapeText(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Unescape HTML entities (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#x27;`) back
/// to their literal characters, writing the result to `writer`.
pub fn unescape(writer: *std.Io.Writer, value: []const u8) !void {
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '&') {
            if (i + 4 <= value.len and std.mem.eql(u8, value[i .. i + 4], "&lt;")) {
                try writer.writeByte('<');
                i += 4;
            } else if (i + 4 <= value.len and std.mem.eql(u8, value[i .. i + 4], "&gt;")) {
                try writer.writeByte('>');
                i += 4;
            } else if (i + 5 <= value.len and std.mem.eql(u8, value[i .. i + 5], "&amp;")) {
                try writer.writeByte('&');
                i += 5;
            } else if (i + 6 <= value.len and std.mem.eql(u8, value[i .. i + 6], "&quot;")) {
                try writer.writeByte('"');
                i += 6;
            } else if (i + 6 <= value.len and std.mem.eql(u8, value[i .. i + 6], "&#x27;")) {
                try writer.writeByte('\'');
                i += 6;
            } else {
                try writer.writeByte(value[i]);
                i += 1;
            }
        } else {
            try writer.writeByte(value[i]);
            i += 1;
        }
    }
}

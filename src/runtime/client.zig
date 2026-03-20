const window = @import("client/window.zig");

pub const Event = @import("client/Event.zig");

// Legacy --- may get removed/renamed
pub const Document = window.Document;
pub const js = window.js;
pub const clearInterval = window.clearInterval;
pub const setInterval = window.setInterval;
pub const setTimeout = window.setTimeout;
pub const Console = window.Console;

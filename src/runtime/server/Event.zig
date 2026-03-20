//! Server-side Event — context for server event handlers.
//!
//! Provides the event payload value via `value()`.
//! For state access, use `Event.Stateful` via `ctx.bind()`.

const std = @import("std");
const zx = @import("../../root.zig");
const core = @import("../core/Event.zig");
const reactivity = @import("../client/reactivity.zig");

const Allocator = std.mem.Allocator;
const StateContext = core.StateContext;
const EventHandler = reactivity.EventHandler;
const client_allocator = zx.client_allocator;

const Event = @This();

allocator: Allocator = undefined,
arena: Allocator = undefined,
action_ref: u64 = 0,
payload: EventHandler.ServerEventPayload = .{},
/// Set by the comptime-generated wrapper when the handler uses StateContext.
_state_ctx: ?*StateContext = null,

pub fn init(action_ref: u64) Event {
    return .{ .action_ref = action_ref };
}

pub fn value(self: Event) ?[]const u8 {
    return self.payload.value;
}

/// Stateful server event — provides `state()` access to bound component state.
/// Use `fn(*zx.server.Event.Stateful) void` with `ctx.bind()` to get this type.
pub const Stateful = struct {
    _inner: *Event,
    _state_ctx: *StateContext,

    /// Access the component's state (server-side).
    /// Must be called in the same order as `ctx.state()` in the render function.
    pub fn state(self: *Stateful, comptime T: type) core.StateHandle(T) {
        return self._state_ctx.state(T);
    }

    pub fn value(self: Stateful) ?[]const u8 {
        return self._inner.value();
    }

    // ── Handler creation ─────────────────────────────────────────

    /// Create an EventHandler for `fn(*Event.Stateful) void` via ctx.bind().
    /// Auto-collects all component states for round-tripping.
    pub fn createHandler(
        comptime handler: anytype,
        alloc: Allocator,
        component_id: []const u8,
        state_index: u32,
        handler_index: *u32,
    ) zx.EventHandler {
        const wrap_fn = comptime makeWrap(handler, struct {
            fn call(ctx: *Event, sc: *StateContext, h: anytype) void {
                var sf = Stateful{ ._inner = ctx, ._state_ctx = sc };
                h(&sf);
            }
        }.call);
        return finalize(alloc, handler_index, &wrap_fn, reactivity.collectStateBoundEntries(alloc, component_id, state_index));
    }

    /// Create an EventHandler for `fn(*Event.Stateful) void` via ctx.sbind() with explicit states.
    pub fn createHandlerWithStates(
        comptime handler: anytype,
        alloc: Allocator,
        handler_index: *u32,
        bound_states: []const EventHandler.BoundStateEntry,
    ) zx.EventHandler {
        const wrap_fn = comptime makeWrap(handler, struct {
            fn call(ctx: *Event, sc: *StateContext, h: anytype) void {
                var sf = Stateful{ ._inner = ctx, ._state_ctx = sc };
                h(&sf);
            }
        }.call);
        return finalize(alloc, handler_index, &wrap_fn, bound_states);
    }
};

/// Build BoundStateEntry vtable for each explicitly listed state (used by sbind).
pub fn buildBoundStates(alloc: Allocator, states: anytype) []const EventHandler.BoundStateEntry {
    const state_fields = @typeInfo(@TypeOf(states)).@"struct".fields;
    const arr = alloc.alloc(EventHandler.BoundStateEntry, state_fields.len) catch @panic("OOM");
    inline for (state_fields, 0..) |field, i| {
        const s = @field(states, field.name);
        const T = @typeInfo(@TypeOf(s)).pointer.child.ValueType;
        arr[i] = .{
            .state_ptr = @ptrCast(s),
            .getJson = &struct {
                fn f(a: Allocator, ptr: *anyopaque) []const u8 {
                    const st: *reactivity.State(T) = @ptrCast(@alignCast(ptr));
                    var aw = std.Io.Writer.Allocating.init(a);
                    zx.util.zxon.serialize(st.get(), &aw.writer, .{}) catch return "null";
                    return aw.written();
                }
            }.f,
            .applyJson = &struct {
                fn f(ptr: *anyopaque, json: []const u8) void {
                    const st: *reactivity.State(T) = @ptrCast(@alignCast(ptr));
                    st.set(zx.util.zxon.parse(T, client_allocator, json, .{}) catch return);
                }
            }.f,
        };
    }
    return arr;
}

/// Create the server-side wrapper fn that builds a StateContext from the payload
/// and calls the handler through `call`.
fn makeWrap(
    comptime handler: anytype,
    comptime call: fn (*Event, *StateContext, anytype) void,
) fn (*Event) void {
    return struct {
        fn wrap(ctx: *Event) void {
            const sc = StateContext.init(ctx.allocator, ctx.arena, ctx.payload.states) orelse return;
            ctx._state_ctx = sc;
            call(ctx, sc, handler);
        }
    }.wrap;
}

/// Allocate handler ID, create callback context, return EventHandler.
fn finalize(
    alloc: Allocator,
    handler_index: *u32,
    comptime wrap_fn: *const fn (*Event) void,
    bound_states: []const EventHandler.BoundStateEntry,
) zx.EventHandler {
    handler_index.* += 1;
    const h_id = handler_index.*;
    const ctx = alloc.create(EventHandler.ServerEventCallbackCtx) catch @panic("OOM");
    ctx.* = .{ .handler_id = h_id, .bound_states = bound_states };
    return EventHandler.createServerEvent(h_id, wrap_fn, @ptrCast(ctx), bound_states);
}

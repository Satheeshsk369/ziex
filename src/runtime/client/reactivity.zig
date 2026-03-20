//! Reactive primitives for client-side state management.

const std = @import("std");
const builtin = @import("builtin");

const Client = @import("Client.zig");
const zx = @import("../../root.zig");
const js = zx.client.js;

const is_wasm = builtin.os.tag == .freestanding;

fn getGlobalAllocator() std.mem.Allocator {
    return zx.client_allocator;
}

const ComponentSubKey = struct {
    component_id: []const u8,

    const Context = struct {
        pub fn hash(_: Context, k: ComponentSubKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k.component_id);
            return h.final();
        }
        pub fn eql(_: Context, a: ComponentSubKey, b: ComponentSubKey) bool {
            return std.mem.eql(u8, a.component_id, b.component_id);
        }
    };
};

var component_subscriptions = std.HashMapUnmanaged(
    ComponentSubKey,
    void,
    ComponentSubKey.Context,
    std.hash_map.default_max_load_percentage,
){};

pub var active_component_id: ?[]const u8 = null;

/// Key for the per-component per-slot state store.
const StateKey = struct {
    component_id: []const u8,
    slot: u32,

    const Context = struct {
        pub fn hash(_: Context, k: StateKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k.component_id);
            h.update(std.mem.asBytes(&k.slot));
            return h.final();
        }
        pub fn eql(_: Context, a: StateKey, b: StateKey) bool {
            return a.slot == b.slot and std.mem.eql(u8, a.component_id, b.component_id);
        }
    };
};

/// Opaque blob of state with a serialization vtable for server event round-trips.
const StateEntry = struct {
    ptr: *anyopaque,
    /// Serialize current value to positional JSON. Only populated on WASM.
    getJson: *const fn (alloc: std.mem.Allocator, ptr: *anyopaque) []const u8 = &noopGetJson,
    /// Apply a positional JSON value back to the state (triggers re-render).
    applyJson: *const fn (ptr: *anyopaque, json: []const u8) void = &noopApplyJson,

    fn noopGetJson(_: std.mem.Allocator, _: *anyopaque) []const u8 {
        return "null";
    }
    fn noopApplyJson(_: *anyopaque, _: []const u8) void {}
};

var state_store = std.HashMapUnmanaged(
    StateKey,
    StateEntry,
    StateKey.Context,
    std.hash_map.default_max_load_percentage,
){};

pub fn State(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const ValueType = T;

        value: T,
        /// The owning component ID — used to call scheduleRender on mutation.
        component_id: []const u8,

        pub fn init(value: T, component_id: []const u8) Self {
            return .{ .value = value, .component_id = component_id };
        }

        /// Get the current value.
        pub inline fn get(self: *const Self) T {
            return self.value;
        }

        /// Set a new value and trigger a component re-render.
        pub fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            scheduleRender(self.component_id);
        }

        /// Update the value using a transform function `fn(T) T` and trigger a re-render.
        /// Example: `count.update(struct { fn f(x: i32) i32 { return x + 1; } }.f)`
        pub fn update(self: *Self, transform: *const fn (T) T) void {
            self.value = transform(self.value);
            scheduleRender(self.component_id);
        }

        /// Create an event handler that updates the state using a transform function.
        pub fn bind(self: *Self, comptime transform: *const fn (T) T) zx.EventHandler {
            return .{
                .callback = &struct {
                    fn handler(ctx: *anyopaque, _: zx.client.Event) void {
                        const s: *Self = @ptrCast(@alignCast(ctx));
                        s.set(transform(s.get()));
                    }
                }.handler,
                .context = self,
            };
        }

        pub fn getOrCreate(alloc: std.mem.Allocator, component_id: []const u8, slot: u32, initial: T) !*Self {
            if (is_wasm) {
                const key = StateKey{ .component_id = component_id, .slot = slot };

                if (state_store.get(key)) |entry| {
                    return @ptrCast(@alignCast(entry.ptr));
                }

                const state_ptr = try getGlobalAllocator().create(Self);
                state_ptr.* = Self.init(initial, component_id);
                const id_copy = try getGlobalAllocator().dupe(u8, component_id);
                const stored_key = StateKey{ .component_id = id_copy, .slot = slot };
                try state_store.put(getGlobalAllocator(), stored_key, .{
                    .ptr = @ptrCast(state_ptr),
                    .getJson = &struct {
                        fn f(a: std.mem.Allocator, ptr: *anyopaque) []const u8 {
                            const s: *Self = @ptrCast(@alignCast(ptr));
                            var aw = std.Io.Writer.Allocating.init(a);
                            zx.util.zxon.serialize(s.get(), &aw.writer, .{}) catch return "null";
                            return aw.written();
                        }
                    }.f,
                    .applyJson = &struct {
                        fn f(ptr: *anyopaque, json: []const u8) void {
                            const s: *Self = @ptrCast(@alignCast(ptr));
                            s.set(zx.util.zxon.parse(T, getGlobalAllocator(), json, .{}) catch return);
                        }
                    }.f,
                });
                return state_ptr;
            } else {
                // Server SSR: return default state
                const state_ptr = try alloc.create(Self);
                state_ptr.* = Self.init(initial, component_id);
                return state_ptr;
            }
        }

        /// Look up an existing state by (component_id, slot). Used by StateContext in event handlers
        /// where the state was already created during render.
        pub fn getExisting(component_id: []const u8, slot: u32) *Self {
            const key = StateKey{ .component_id = component_id, .slot = slot };
            if (state_store.get(key)) |entry| {
                return @ptrCast(@alignCast(entry.ptr));
            }
            @panic("State not found — ensure sc.state() is called in the same order as ctx.state()");
        }
    };
}

/// Top-level alias for State(T) pointer to improve IDE/ZLS type resolution.
pub fn StateInstance(comptime T: type) type {
    return *State(T);
}

/// Collect a BoundStateEntry for every state belonging to `component_id`, in slot order.
/// Used by ctx.bind(serverFn) to auto-bind all component states for server event round-trips.
/// Returns an empty slice on SSR (state_store is not populated server-side).
pub fn collectStateBoundEntries(
    alloc: std.mem.Allocator,
    component_id: []const u8,
    state_count: u32,
) []EventHandler.BoundStateEntry {
    if (!is_wasm) return &.{};

    var list = std.ArrayList(EventHandler.BoundStateEntry).empty;
    for (0..state_count) |i| {
        const slot = (1 << 20) + @as(u32, @intCast(i));
        const key = StateKey{ .component_id = component_id, .slot = slot };
        if (state_store.get(key)) |entry| {
            list.append(alloc, .{
                .state_ptr = entry.ptr,
                .getJson = entry.getJson,
                .applyJson = entry.applyJson,
            }) catch {};
        }
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

/// Re-render the whole page using VDOM diffing algorithm like react
pub fn rerender() void {
    if (!is_wasm) return;
    if (Client.global_client) |client| {
        client.renderAll();
    }
}

/// Request a re-render of a specific component by ID.
/// If the component_id is not found in the registry (e.g. a nested ComponentCtx
/// component without @rendering={.client}), falls back to re-rendering all components.
pub fn scheduleRender(component_id: []const u8) void {
    if (!is_wasm) return;
    if (Client.global_client) |client| {
        for (client.components) |cmp| {
            if (std.mem.eql(u8, cmp.id, component_id)) {
                client.render(cmp) catch {};
                return;
            }
        }
        // component_id not registered — nested component inside a CSR parent.
        // Re-render all so the parent picks up the state change.
        client.renderAll();
    }
}

pub const EventHandler = struct {
    /// Vtable entry for a single piece of state bound to a server event handler.
    pub const BoundStateEntry = struct {
        state_ptr: *anyopaque,
        /// Serialize the current state value to its positional JSON representation.
        getJson: *const fn (alloc: std.mem.Allocator, ptr: *anyopaque) []const u8,
        /// Apply a positional JSON value back to the local state (triggers re-render).
        applyJson: *const fn (ptr: *anyopaque, json: []const u8) void,
    };

    callback: *const fn (ctx: *anyopaque, event: zx.client.Event) void,
    context: *anyopaque,
    /// Non-null when created from a form `action={}` handler.
    /// Takes a pointer so the server wrapper can write `_state_ctx` back after the call.
    action_fn: ?*const fn (*zx.ActionContext) void = null,
    /// Server-side handler; takes *ServerEventContext so the wrapper can set _state_ctx.
    server_event_fn: ?*const fn (*zx.server.Event) void = null,
    /// Unique ID for this handler instance on the current page.
    handler_id: u32 = 0,
    /// States to serialize/deserialize for server event round-trips.
    bound_states: []const BoundStateEntry = &.{},

    /// Helper to create an EventHandler from a plain function pointer (no context).
    /// Accepts `fn () void`, `fn (zx.client.Event) void`, and `fn (zx.ActionContext) void`.
    /// When the parameter is `zx.ActionContext`, the handler behaves as a server action:
    /// it calls preventDefault() then POSTs to the current page URL (WASM only).
    pub fn fromFn(comptime func: anytype) EventHandler {
        const FnType = @TypeOf(func);
        const fn_info = @typeInfo(FnType);
        const params = fn_info.@"fn".params;

        // Server action: fn (zx.ActionContext) void
        if (comptime params.len == 1) {
            const arg_type = params[0].type.?;
            switch (arg_type) {
                zx.ActionContext => {
                    // Wrap fn(ActionContext)void → fn(*ActionContext)void so the server
                    // can write _state_ctx back after dispatch.
                    const Wrap = struct {
                        fn w(ctx: *zx.ActionContext) void {
                            func(ctx.*);
                        }
                    };
                    return .{
                        .callback = &serverActionHandler,
                        .context = @as(*anyopaque, @ptrFromInt(1)),
                        .action_fn = &Wrap.w,
                    };
                },
                zx.server.Event => {
                    // Wrap to the canonical *ServerEventContext signature used by the registry.
                    const Wrapper = struct {
                        fn w(ctx: *zx.server.Event) void {
                            func(ctx.*);
                        }
                    };
                    return .{
                        .callback = &serverEventHandler,
                        .context = @as(*anyopaque, @ptrFromInt(1)),
                        .server_event_fn = &Wrapper.w,
                    };
                },
                *zx.server.Event.Stateful => {
                    // Stateful server event — not supported without ctx.bind().
                    @compileError(
                        "fn(*zx.server.Event.Stateful) void handlers require ctx.bind(). " ++
                            "Use fn(zx.server.Event) void for non-bind server event handlers.",
                    );
                },
                else => {
                    // Guard: user-defined struct arg (not a framework context) is only valid
                    // on `action={}`. Point them at fromActionFn / the action attribute.
                    if (comptime @typeInfo(arg_type) == .@"struct" and
                        arg_type != zx.client.Event)
                    {
                        @compileError(
                            "A struct-typed handler `" ++ @typeName(@TypeOf(func)) ++ "` can only be used " ++
                                "as a form `action={}` attribute, not as an event handler. " ++
                                "Use `fn (zx.client.Event) void` for event handlers.",
                        );
                    }
                },
            }
        }

        const Wrapper = struct {
            fn wrapper(ctx: *anyopaque, event: zx.client.Event) void {
                _ = ctx;
                if (comptime params.len == 0) {
                    func();
                } else {
                    func(event);
                }
            }
        };
        return .{
            .callback = &Wrapper.wrapper,
            .context = @as(*anyopaque, @ptrFromInt(1)),
        };
    }

    /// Helper to create an EventHandler from a form `action={}` attribute.
    /// Accepts both `fn (zx.ActionContext) void` and `fn (SomeStruct) void`.
    /// For the struct form, form fields are automatically parsed via ctx.data(T).
    pub fn fromActionFn(comptime func: anytype) EventHandler {
        const FnType = @TypeOf(func);
        const fn_info = @typeInfo(FnType);
        const params = fn_info.@"fn".params;

        if (comptime params.len == 1) {
            const arg_type = params[0].type.?;
            // Direct typed form: first param is a user struct (not a framework context type).
            if (comptime @typeInfo(arg_type) == .@"struct" and
                arg_type != zx.ActionContext and
                arg_type != zx.client.Event and
                arg_type != zx.server.Event)
            {
                const DirectTyped = struct {
                    fn w(ctx: *zx.ActionContext) void {
                        func(ctx.data(arg_type));
                    }
                };
                return .{
                    .callback = &serverActionHandler,
                    .context = @as(*anyopaque, @ptrFromInt(1)),
                    .action_fn = &DirectTyped.w,
                };
            }
        }

        // Fall back to the standard path (handles ActionContext, ServerEventContext, etc.)
        return fromFn(func);
    }

    /// Helper to create an EventHandler from a runtime function pointer (no context)
    pub fn fromFnRuntime(func: *const fn (zx.client.Event) void) EventHandler {
        return .{
            .callback = &runtimeWrapper,
            .context = @ptrCast(@constCast(func)),
        };
    }

    fn runtimeWrapper(ctx: *anyopaque, event: zx.client.Event) void {
        const func: *const fn (zx.client.Event) void = @ptrCast(@alignCast(ctx));
        func(event);
    }

    /// Create an EventHandler that POSTs to the current page URL with minimal
    /// event data as JSON. In WASM this fires a fetch call to the server; on
    /// the server-side (SSR/native) this is a no-op.
    pub fn serverAction() EventHandler {
        return .{
            .callback = &serverActionHandler,
            .context = @as(*anyopaque, @ptrFromInt(1)),
        };
    }

    pub fn serverActionHandler(ctx: *anyopaque, event: zx.client.Event) void {
        _ = ctx;
        if (!is_wasm) return;

        // Prevent default browser behavior (e.g. form navigation).
        event.preventDefault();

        // const ext = @import("window/extern.zig");
        const client_fetch = @import("fetch.zig");
        const CoreFetch = @import("../core/Fetch.zig");

        // Get current page URL from the browser.
        // var url_buf: [2048]u8 = undefined;
        // const url_len = ext._getLocationHref(&url_buf, url_buf.len);
        // const url = url_buf[0..url_len];

        // Minimal JSON payload — enough for the server to identify the action.
        const headers = [_]CoreFetch.RequestInit.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-ZX-Action", .value = "1" },
        };

        client_fetch.fetchAsync(
            getGlobalAllocator(),
            "",
            .{
                .method = .GET,
                .headers = &headers,
                .body = "{}",
            },
            onServerActionResponse,
        );
    }

    /// Opaque context stored per-request when bound states need round-tripping.
    pub const ServerEventCallbackCtx = struct {
        handler_id: u32 = 0,
        bound_states: []const BoundStateEntry,
        /// When false (state-only handlers), event value is omitted from the payload.
        send_event_value: bool = true,
    };

    /// Factory used by ComponentCtx.sbind to build a server-event handler
    /// with bound states without exposing the private serverEventHandler symbol.
    pub fn createServerEvent(
        handler_id: u32,
        comptime server_fn: *const fn (*zx.server.Event) void,
        context: *anyopaque,
        bound_states: []const BoundStateEntry,
    ) EventHandler {
        return .{
            .handler_id = handler_id,
            .callback = &serverEventHandler,
            .context = context,
            .server_event_fn = server_fn,
            .bound_states = bound_states,
        };
    }

    fn serverEventHandler(ctx: *anyopaque, event: zx.client.Event) void {
        if (!is_wasm) return;

        // Prevent default browser behavior (e.g. form navigation).
        event.preventDefault();

        const client_fetch = @import("fetch.zig");
        const CoreFetch = @import("../core/Fetch.zig");

        // Resolve bound states and handler ID from context (sentinel 1 means no states/ID).
        var handler_id: u32 = 0;
        const bound_states: []const BoundStateEntry = if (@intFromPtr(ctx) == 1)
            &.{}
        else blk: {
            const ec: *ServerEventCallbackCtx = @ptrCast(@alignCast(ctx));
            handler_id = ec.handler_id;
            break :blk ec.bound_states;
        };

        const send_event_value: bool = if (@intFromPtr(ctx) == 1) true else blk: {
            const ec: *ServerEventCallbackCtx = @ptrCast(@alignCast(ctx));
            break :blk ec.send_event_value;
        };

        // Serialize current values of bound states.
        var state_jsons = std.ArrayList([]const u8).empty;
        for (bound_states) |bs| {
            const json = bs.getJson(getGlobalAllocator(), bs.state_ptr);
            state_jsons.append(getGlobalAllocator(), json) catch {};
        }

        const headers = [_]CoreFetch.RequestInit.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-ZX-Server-Event", .value = "1" },
        };

        const payload = ServerEventPayload{
            .handler_id = handler_id,
            .value = if (send_event_value) event.value() else null,
            .states = state_jsons.items,
        };

        var aw = std.Io.Writer.Allocating.init(getGlobalAllocator());
        zx.util.zxon.serialize(payload, &aw.writer, .{}) catch {};
        const payload_buf = aw.written();

        if (bound_states.len > 0) {
            // Allocate a callback context to carry bound_states into the response handler.
            const cb_ctx = getGlobalAllocator().create(ServerEventCallbackCtx) catch return;
            cb_ctx.* = .{ .bound_states = bound_states };
            client_fetch.fetchAsyncCtx(
                getGlobalAllocator(),
                "",
                .{ .method = .POST, .headers = &headers, .body = payload_buf },
                @ptrCast(cb_ctx),
                onServerEventResponse,
            );
        } else {
            client_fetch.fetchAsync(
                getGlobalAllocator(),
                "",
                .{ .method = .POST, .headers = &headers, .body = payload_buf },
                onServerActionResponse,
            );
        }
    }

    pub const ServerEventPayload = struct {
        handler_id: u32 = 0,
        value: ?[]const u8 = null,
        states: []const []const u8 = &.{},
    };

    fn onServerActionResponse(_: ?*@import("../core/Fetch.zig").Response, _: ?@import("../core/Fetch.zig").FetchError) void {}

    /// Called when a server event with bound states completes.
    /// Parses the returned state JSON array and applies each value to the local state.
    fn onServerEventResponse(ctx_ptr: *anyopaque, response: ?*@import("../core/Fetch.zig").Response, _: ?@import("../core/Fetch.zig").FetchError) void {
        const cb_ctx: *ServerEventCallbackCtx = @ptrCast(@alignCast(ctx_ptr));
        defer getGlobalAllocator().destroy(cb_ctx);

        const resp = response orelse return;
        const body = resp._body;
        if (body.len == 0) return;

        // Body is a JSON array of JSON-string-encoded state values: ["42", "true", ...]
        // Parse as []const []const u8; each element is the raw positional JSON for that state.
        const states = zx.util.zxon.parse([]const []const u8, getGlobalAllocator(), body, .{}) catch return;
        for (states, 0..) |state_json, i| {
            if (i >= cb_ctx.bound_states.len) break;
            cb_ctx.bound_states[i].applyJson(cb_ctx.bound_states[i].state_ptr, state_json);
        }
    }
};

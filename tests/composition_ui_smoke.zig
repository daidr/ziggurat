const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn zlc_test_pixel(*anyopaque, u32, u32) u32;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn gtk_widget_size_allocate(*anyopaque, *const Allocation) void;
const Allocation = extern struct { x: c_int = 0, y: c_int = 0, width: c_int, height: c_int };
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
fn paint(window: z.Window) !void {
    if (builtin.os.tag == .windows) {
        _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    } else {
        const record = window.app.windows.get(window.key) orelse return error.Closed;
        const bounds = try window.clientBounds();
        zlg_test_paint(record.native.native.?, bounds.width, bounds.height);
    }
}
fn click(window: z.Window, x: f64, y: f64) !void {
    if (builtin.os.tag == .windows) {
        const scale = @as(f64, @floatFromInt(c.GetDpiForWindow(window.nativeHandle()))) / 96;
        const xx: u32 = @intFromFloat(x * scale);
        const yy: u32 = @intFromFloat(y * scale);
        _ = c.SendMessageW(window.nativeHandle(), c.WM_LBUTTONDOWN, 0, @intCast(xx | (yy << 16)));
        _ = c.SendMessageW(window.nativeHandle(), c.WM_LBUTTONUP, 0, @intCast(xx | (yy << 16)));
    } else {
        const widget = gtk_bin_get_child(window.nativeHandle().?).?;
        for ([_]bool{ true, false }) |down| {
            const event = gdk_event_new(if (down) 4 else 7) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const native: *ButtonEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = if (down) 4 else 7, .window = if (gtk_widget_get_window(widget)) |handle| g_object_ref(handle) else null, .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 0, .button = 1, .device = null, .x_root = x, .y_root = y };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, if (down) @as([*:0]const u8, "button-press-event") else @as([*:0]const u8, "button-release-event"), native, &handled);
        }
    }
}
const State = struct {
    context: ui.Context = undefined,
    region: ?z.composition.Region = null,
    failure: ?anyerror = null,
    expected_diagnostic: ?anyerror = null,
    remove_draw: bool = false,
    remove_input: bool = false,
    remove_key: bool = false,
    fail_frame: bool = false,
    close_draw: bool = false,
    draws: usize = 0,
    inputs: usize = 0,
    actions: usize = 0,
    resizes: usize = 0,
    positions: usize = 0,
    lease: ui.drawing.Lease = undefined,
    levels: [1]ui.drawing.ImageLevel = undefined,
    image: ui.drawing.ImageView = undefined,
    pixels: [4]u8 = .{ 0, 0, 255, 255 },
    fn init(self: *State) !void {
        self.lease = .init(std.Thread.getCurrentId());
        self.context = ui.Context.init(self, draw, action);
        self.context.on_input = input;
        self.context.render_mode = .gdi;
        self.levels = .{.{ .pixels = &self.pixels, .byte_len = 4, .width = 1, .height = 1, .stride = 4 }};
        self.image = .{ .lease = &self.lease, .identity = try ui.drawing.reserveRasterIdentity(), .levels = &self.levels };
    }
    fn diagnostic(ptr: *anyopaque, diagnostic_value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (diagnostic_value.err) |actual| {
            if (self.expected_diagnostic) |wanted| {
                if (actual != wanted) self.failure = actual;
            } else self.failure = actual;
        } else if (self.expected_diagnostic != null) self.failure = error.UnexpectedDiagnostic;
    }
    fn action(ptr: *anyopaque, _: u64) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.actions += 1;
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.inputs += 1;
        if (event == .resize) self.resizes += 1;
        if (event == .window_position) self.positions += 1;
        if ((self.remove_input and event == .pointer_down) or (self.remove_key and event == .key_input)) {
            self.remove() catch |err| {
                self.failure = err;
            };
            // Return false to prove the old default handler does not act after removal.
            return false;
        }
        return false;
    }
    fn remove(self: *State) !void {
        try expect(try self.region.?.remove());
        try expect(self.context.window != null);
        try expectError(error.Closed, self.context.layerStats());
        try expectError(error.Closed, self.region.?.snapshot());
        try expect(self.region.?.beginCallback() == null);
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            self.failure = err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        self.draws += 1;
        frame.clear(0xffffff);
        frame.rect(.{ .x = 0, .y = 0, .width = 20, .height = 20 }, 0x123456);
        try frame.image(.{ .x = 24, .y = 0, .width = 8, .height = 8 }, self.image, .{ .sampling = .nearest });
        try frame.button(1, .{ .x = 0, .y = 24, .width = 80, .height = 24 }, "UI");
        try expect(self.lease.pins > self.lease.residency_pins);
        if (self.remove_draw) try self.remove();
        if (self.close_draw) {
            _ = try self.context.window.?.destroy();
            try expect(self.context.window != null);
        }
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn check(self: *State) !void {
        if (self.failure) |err| return err;
    }
};
const Native = struct {
    attaches: usize = 0,
    detaches: usize = 0,
    inputs: usize = 0,
    updates: usize = 0,
    fn attach(ptr: *anyopaque, region: z.composition.Region) !void {
        const self: *Native = @ptrCast(@alignCast(ptr));
        try equal(z.composition.Kind.native, (try region.snapshot()).kind);
        self.attaches += 1;
    }
    fn update(ptr: *anyopaque, _: z.composition.Region, _: z.composition.Viewport) !void {
        const self: *Native = @ptrCast(@alignCast(ptr));
        self.updates += 1;
    }
    fn detach(ptr: *anyopaque, region: z.composition.Region) void {
        const self: *Native = @ptrCast(@alignCast(ptr));
        std.debug.assert(if (region.snapshot()) |_| false else |err| err == error.Closed);
        self.detaches += 1;
    }
    fn event(ptr: *anyopaque, _: z.composition.Region, input: z.Event) void {
        const self: *Native = @ptrCast(@alignCast(ptr));
        if (input == .pointer_down or input == .pointer_up) self.inputs += 1;
    }
    fn participant(self: *Native) z.composition.Participant {
        return .{ .context = self, .attach = attach, .update = update, .detach = detach, .event = event };
    }
};
fn checkRemoved(state: *State) !void {
    try state.check();
    try expect(state.context.window == null and state.context.backdrop_region == null);
    try expect(!state.context.hasSurface());
    try equal(@as(usize, 0), state.lease.pins);
    try equal(@as(usize, 0), state.lease.residency_pins);
}
fn normal(allocator: std.mem.Allocator) !void {
    var state: State = .{};
    try state.init();
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 160, .height = 96 });
    defer _ = window.destroy() catch unreachable;
    const owner = try z.composition.Owner.create(allocator, window, .{});
    defer owner.close() catch unreachable;
    state.context.render_mode = .automatic;
    try expectError(error.UnsupportedBackdropRenderMode, state.context.attachBackdrop(owner));
    state.context.render_mode = .gdi;
    if (ui.capabilities.accessibility) {
        state.context.semantic_name = &@as([257]u8, @splat('x'));
        try expectError(error.SemanticNameTooLong, state.context.attachBackdrop(owner));
        try expect(state.context.window == null and state.context.backdrop_region == null);
        state.context.semantic_name = "Backdrop";
    }
    state.region = try state.context.attachBackdrop(owner);
    try equal(z.composition.Kind.backdrop, (try state.region.?.snapshot()).kind);
    try expectError(error.AlreadyAttached, state.context.attach(window));
    var second: State = .{};
    try second.init();
    try expectError(error.ContentAlreadyAttached, second.context.attach(window));
    try expectError(error.BackdropAlreadyReserved, second.context.attachBackdrop(owner));
    try expect(second.context.window == null);
    try state.context.uploadImage(state.image);
    try paint(window);
    try state.check();
    try expect(state.draws != 0 and state.context.frames != 0);
    if (builtin.os.tag == .windows) {
        try expect(c.GdiFlush() != 0);
        try equal(@as(c.COLORREF, 0x563412), c.GetPixel(state.context.renderer.dc, 2, 2));
    } else try equal(@as(u32, 0x123456), zlc_test_pixel(state.context.renderer.native.?, 2, 2));
    var native: Native = .{};
    const child = try owner.reserve(.{ .bounds = .{ .x = 90, .y = 0, .width = 50, .height = 96 } });
    try child.attach(native.participant());
    try click(window, 100, 20);
    try equal(@as(usize, 2), native.inputs);
    try equal(@as(usize, 0), state.actions);
    try click(window, 10, 30);
    try state.check();
    try equal(@as(usize, 1), state.actions);
    const resizes = state.resizes;
    try window.resize(200, 120);
    if (builtin.os.tag == .linux) {
        // An actual GTK allocation is the native resize source for a hidden area.
        const area = gtk_bin_get_child(window.nativeHandle().?).?;
        const allocation: Allocation = .{ .width = 200, .height = 120 };
        gtk_widget_size_allocate(area, &allocation);
    }
    try app.dispatch();
    try expect(state.resizes > resizes);
    const bounds = (try state.region.?.snapshot()).viewport.bounds;
    const size = try window.contentSize();
    try equal(@as(f32, @floatFromInt(size.width)) / size.scale, bounds.width);
    try equal(@as(f32, @floatFromInt(size.height)) / size.scale, bounds.height);
    const positions = state.positions;
    if (builtin.os.tag == .windows) {
        var next = try window.clientBounds();
        next.position = .{ .x = 17, .y = 19 };
        try window.setClientBounds(next);
    } else {
        // Exercise the native configure relay for a hidden widget. A separate
        // mixed-native fixture verifies actual WM movement and child placement.
        const Configure = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, x: c_int, y: c_int, width: c_int, height: c_int };
        const event = gdk_event_new(13) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        const native_event: *Configure = @ptrCast(@alignCast(event));
        native_event.* = .{ .kind = 13, .window = if (gtk_widget_get_window(window.nativeHandle().?)) |handle| g_object_ref(handle) else null, .send_event = 1, .x = 17, .y = 19, .width = 200, .height = 120 };
        var handled: c_int = 0;
        g_signal_emit_by_name(window.nativeHandle().?, "configure-event", native_event, &handled);
    }
    try expect(state.positions > positions);
    const frames = state.context.frames;
    state.fail_frame = true;
    state.expected_diagnostic = error.InvalidGeometry;
    try paint(window);
    try state.check();
    try equal(frames, state.context.frames);
    state.fail_frame = false;
    state.expected_diagnostic = null;
    var provider: ?*anyopaque = null;
    if (ui.capabilities.accessibility) provider = try state.context.accessibility_bridge.retainProvider(1);
    state.remove_draw = true;
    try paint(window);
    try checkRemoved(&state);
    try equal(frames, state.context.frames);
    if (ui.capabilities.accessibility) {
        const node: *c.IUnknown = @ptrCast(@alignCast(provider.?));
        defer _ = node.lpVtbl.*.Release.?(node);
        const raw: *c.IRawElementProviderSimple = @ptrCast(@alignCast(provider.?));
        var value: c.VARIANT = std.mem.zeroes(c.VARIANT);
        try equal(@as(c.HRESULT, @bitCast(@as(u32, 0x80040201))), raw.lpVtbl.*.GetPropertyValue.?(raw, c.UIA_NamePropertyId, &value));
    }
    const old = state.region.?;
    state.remove_draw = false;
    state.region = try state.context.attachBackdrop(owner);
    try equal(old.index, state.region.?.index);
    try expect(old.generation != state.region.?.generation);
    try expectError(error.Closed, old.snapshot());
    try state.context.uploadImage(state.image);
    try paint(window);
    state.remove_input = true;
    try click(window, 10, 30);
    try checkRemoved(&state);
    try equal(@as(usize, 1), state.actions);
    state.remove_input = false;
    state.region = try state.context.attachBackdrop(owner);
    try state.context.uploadImage(state.image);
    try paint(window);
    state.context.input_state.focused = 1;
    state.remove_key = true;
    try expect(state.context.handleKeyInput(window, .{ .key = .enter }));
    try checkRemoved(&state);
    try equal(@as(usize, 1), state.actions);
    try owner.detach();
    try equal(@as(usize, 1), native.detaches);
    _ = try window.destroy();
    try app.dispatch();
    try equal(@as(usize, 0), app.resourceStats().allocated_records);
}
const ReentrantAllocator = struct {
    source: std.mem.Allocator,
    state: *State,
    fired: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn allocate(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (!self.fired) {
            self.fired = true;
            self.state.remove() catch |err| {
                self.state.failure = err;
            };
        }
        return self.source.rawAlloc(size, alignment, ret);
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.source.rawResize(bytes, alignment, size, ret);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.source.rawRemap(bytes, alignment, size, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.source.rawFree(bytes, alignment, ret);
    }
};
fn reentrantResource(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return;
    var state: State = .{};
    try state.init();
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 160, .height = 96 });
    defer _ = window.destroy() catch unreachable;
    const owner = try z.composition.Owner.create(allocator, window, .{});
    defer owner.close() catch unreachable;
    state.region = try state.context.attachBackdrop(owner);
    var allocating: ReentrantAllocator = .{ .source = allocator, .state = &state };
    try expectError(error.Closed, state.context.prepareLayers(allocating.allocator(), .{ .size = try window.contentSize(), .max_depth = 1 }));
    try expect(allocating.fired);
    try checkRemoved(&state);
    try owner.detach();
}
fn closedContext(allocator: std.mem.Allocator) !void {
    const External = struct {
        allocator: std.mem.Allocator,
        state: ?*State = null,
        owner: ?*z.composition.Owner = null,
        closed: bool = false,
        fn notify(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const state = self.state.?;
            checkRemoved(state) catch unreachable;
            self.owner.?.close() catch unreachable;
            self.owner = null;
            self.allocator.destroy(state);
            self.state = null;
            self.closed = true;
        }
    };
    var external: External = .{ .allocator = allocator };
    external.state = try allocator.create(State);
    external.state.?.* = .{};
    try external.state.?.init();
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 160, .height = 96, .on_closed = .{ .context = &external, .notify = External.notify } });
    external.owner = try z.composition.Owner.create(allocator, window, .{});
    const state = external.state.?;
    state.region = try state.context.attachBackdrop(external.owner.?);
    try state.context.uploadImage(state.image);
    state.close_draw = true;
    try paint(window);
    try app.dispatch();
    try expect(external.closed and external.state == null and external.owner == null);
    try equal(@as(usize, 0), app.resourceStats().allocated_records);
}

const AttachClose = struct {
    source: std.mem.Allocator,
    state: ?*State = null,
    owner: ?*z.composition.Owner = null,
    armed: bool = false,
    fired: bool = false,
    closed: bool = false,
    fail_allocation: bool = true,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn allocate(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.armed and !self.fired) {
            self.fired = true;
            const state = self.state.?;
            std.debug.assert(state.context.backdrop_region != null and state.context.window != null);
            _ = state.context.window.?.destroy() catch unreachable;
            std.debug.assert(!self.closed);
            if (self.fail_allocation) return null;
        }
        return self.source.rawAlloc(size, alignment, ret);
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.source.rawResize(bytes, alignment, size, ret);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.source.rawRemap(bytes, alignment, size, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.source.rawFree(bytes, alignment, ret);
    }
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        checkRemoved(self.state.?) catch unreachable;
        self.owner.?.close() catch unreachable;
        self.owner = null;
        self.source.destroy(self.state.?);
        self.state = null;
        self.closed = true;
    }
};
fn failedAttachCloses(allocator: std.mem.Allocator) !void {
    if (!ui.capabilities.accessibility) return;
    for ([_]bool{ true, false }) |fail_allocation| {
        var external: AttachClose = .{ .source = allocator, .fail_allocation = fail_allocation };
        external.state = try allocator.create(State);
        external.state.?.* = .{};
        try external.state.?.init();
        const app = try z.App.init(external.allocator());
        defer app.deinit();
        const window = try app.createWindow(.{ .on_closed = .{ .context = &external, .notify = AttachClose.notify } });
        external.owner = try z.composition.Owner.create(external.allocator(), window, .{});
        external.armed = true;
        try expectError(if (fail_allocation) error.OutOfMemory else error.Closed, external.state.?.context.attachBackdrop(external.owner.?));
        try app.dispatch();
        try expect(external.fired and external.closed and external.owner == null and external.state == null);
        try equal(@as(usize, 0), app.resourceStats().allocated_records);
    }
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const before = if (ui.capabilities.accessibility) ui.accessibility.resourceCounts() else std.mem.zeroes(ui.accessibility.ResourceCounts);
    const gpu = if (ui.capabilities.gpu) ui.d3d11.globalResourceCount() else 0;
    try normal(debug.allocator());
    try reentrantResource(debug.allocator());
    try closedContext(debug.allocator());
    try failedAttachCloses(debug.allocator());
    if (ui.capabilities.accessibility) try equal(before, ui.accessibility.resourceCounts());
    if (ui.capabilities.gpu) try equal(gpu, ui.d3d11.globalResourceCount());
    if (builtin.os.tag == .linux) try equal(@as(u32, 0), zlg_resource_count());
    std.debug.print("composition UI native passed: sole owner/backdrop, software pixels, region input/resize, attach rollback, stale handles, draw/input/key/resource remove, failed Frame and close/free resources=0\n", .{});
}

const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const input = @import("input.zig");
const gdi = if (builtin.os.tag == .linux) @import("linux.zig") else @import("windows.zig");
pub const SoftwareRenderer = gdi.Renderer;
const build_options = @import("ziggurat_ui_options");
pub const d3d11 = if (builtin.os.tag == .windows) @import("d3d11.zig") else struct {};
pub const Rect = input.Rect;
pub const layout = @import("layout.zig");
pub const grid = @import("grid.zig");
pub const scroll = @import("scroll.zig");
pub const text_buffer = @import("text_buffer.zig");
pub const editor = @import("editor.zig");
pub const commands = @import("commands.zig");
pub const Font = commands.Font;
pub const drawing = @import("ziggurat_drawing_resources");
pub const ImageOptions = drawing.ImageOptions;
pub const ImageCacheStats = struct { software: drawing.ImageStats, gpu: ?drawing.ImageStats };
pub const CoverageCacheStats = struct { software: drawing.CoverageStats, gpu: ?drawing.CoverageStats };
pub const RasterCacheStats = struct { software: drawing.RasterStats, gpu: ?drawing.RasterStats };
pub const geometry = @import("geometry.zig");
pub const layers = @import("layers.zig");
pub const gaussian = @import("gaussian_filter.zig");
const gaussian_scope = @import("gaussian_scope.zig");
pub const GaussianWorkspaceOptions = gaussian_scope.Options;
pub const GaussianFilterOptions = gaussian_scope.FilterOptions;
const GaussianWorkspace = struct { allocator: std.mem.Allocator, options: GaussianWorkspaceOptions, storage: commands.FilterStorage = .{} };
pub const backdrop_effects = commands.backdrop;
pub const BackdropEffect = backdrop_effects.Effect;
pub const loading = commands.loading;
pub const BackdropEffectStats = struct {
    workspace: backdrop_effects.Stats = .{},
    /// Effects drawn as their opaque fill because no workspace was prepared.
    unprepared: u64 = 0,
    /// Frames replayed in software because they held a backdrop effect or
    /// a loading indicator.
    software_frames: u64 = 0,
};
/// The shading language that programmable effects run.
pub const shader = @import("ziggurat_shader");
pub const shader_effects = commands.shader_effects;
pub const ShaderEffect = shader_effects.Effect;
/// Built-in pose (2D/3D transform) and refracting glass programs.
pub const effects = @import("effect_library.zig");
pub const ShaderEffectStats = struct {
    workspace: shader_effects.Stats = .{},
    /// Effects drawn without their program because no shader workspace, or
    /// no Gaussian workspace with room for an element's capture, was
    /// prepared.
    unprepared: u64 = 0,
};
/// How an element effect composites into its parent.
pub const EffectOptions = struct { opacity: u8 = 255 };
pub const offscreen = @import("offscreen.zig");
pub const canvas = @import("canvas.zig");
pub const PixelImage = @import("pixel_image.zig").PixelImage;
pub const frame_stats = @import("frame_stats.zig");
pub const FrameStats = frame_stats.Stats;
pub const Canvas = canvas.Canvas;
pub const gpu_resources = @import("gpu_resources.zig");
pub const gpu_offscreen = @import("gpu_offscreen.zig");
pub const GradientInterpolationStats = @import("gradient_interpolation_gpu.zig").Stats;
pub const Color = geometry.Color;
pub const accessibility = @import("accessibility.zig");
pub const widgets = @import("widgets.zig");
pub const theme = @import("theme.zig");
pub const affine = @import("affine.zig");
const affine_state = @import("affine_state.zig");
const accessibility_source = @import("accessibility_source.zig");
pub const AccessibilitySource = accessibility_source.Source;
pub const AccessibilityPhase = accessibility_source.Phase;
pub const AccessibilitySourceToken = struct { context: *Context, generation: u64 };
pub const Theme = theme.Theme;
pub const Range = input.Range;
pub const RangeValues = input.Values;
pub const ValueChange = input.ValueChange;
pub const PointerClickRegistration = input.pointer_clicks.Registration;
pub const ClickOutcome = input.pointer_clicks.Outcome;
pub const ControlClick = input.pointer_clicks.Click;
pub const ClickTarget = input.pointer_clicks.Target;
pub const ShortcutScopeOptions = input.shortcut_scopes.ScopeOptions;
pub const ShortcutScopesOptions = input.shortcut_scopes.Options;
pub const ShortcutScopeToken = struct { context: *Context, window: z.Window, epoch: u64, serial: u64, id: u64 };
pub const ShortcutRequestToken = struct { context: *Context, window: z.Window, epoch: u64, id: u64 };
pub const ShortcutScopesStats = struct {
    metadata_bytes: usize = 0,
    references: usize = 0,
    serial: u64 = 0,
    candidate: u64 = 0,
    accepted_scopes: usize = 0,
    closed: bool = false,
    pending: bool = false,
    post_accepted: bool = false,
    last_error: ?anyerror = null,
};
comptime {
    // The native UIA object is linked whenever accessibility is enabled and
    // always references the collection row-bounds export, even in programs
    // that never attach a Bridge or prepare a collection.
    if (build_options.accessibility) _ = &accessibility.virtual_lists.enableMath;
}
pub const capabilities = .{
    .gpu = build_options.gpu,
    .accessibility = build_options.accessibility,
    .software_backend = if (builtin.os.tag == .linux) "cairo-pango" else "gdi",
};
pub const LayerCacheStats = struct { software: layers.Stats, gpu: ?layers.Stats, current_bytes: usize, ordinary_front_bytes: usize, candidate_peak_bytes: usize };
pub const TransformCacheStats = struct { layers: LayerCacheStats, metadata_bytes: usize, generation: u64, accepted_scopes: usize, accepted_captures: usize };
/// Fixed coordinate banks and, when attached semantics are enabled, their
/// native geometry owner. Excludes renderer surfaces and opaque SDK allocations.
/// Raster transforms still need explicit prepareTransforms.
pub const CoordinateOptions = struct { bytes: usize = 256 * 1024 };
pub const TextFieldsOptions = input.text_fields.Options;
pub const RecipientsStats = struct { registry_bytes: usize = 0, native_bytes: usize = 0, total_bytes: usize = 0, capacity: usize = 0 };
pub const TextFieldRegistration = input.text_fields.Registration;
pub const TextFieldScope = input.text_fields.EventScope;
pub const TextFieldResult = input.text_fields.Result;
pub const TextFieldAction = input.text_fields.Action;
pub const RecipientsOptions = struct { recipients: usize = 8, bytes: usize = 32 * 1024 };
pub const ControlRegistration = input.text_fields.ControlRegistration;
pub const ControlResult = input.text_fields.ControlResult;
pub const ControlAction = input.text_fields.ControlAction;
pub const ControlScope = input.text_fields.EventScope;
pub const VirtualListsOptions = accessibility.virtual_lists.Options;
pub const VirtualListsStats = accessibility.virtual_lists.Stats;
pub const VirtualListCaret = struct { id: u64, incarnation: u64 };
pub const ControlFrame = input.text_fields.ControlFrame;
pub const ControlToken = struct {
    context: *Context,
    key: input.text_fields.Key,
    pub fn validate(self: ControlToken) !void {
        try self.context.recipientCurrent(self.key, .control);
    }
    /// Cold membership only. This grants no accepted input, focus or native
    /// action authority, and can prepare a control before its first image.
    pub fn validateRegistration(self: ControlToken) !void {
        try self.context.controlRegistrationCurrent(self.key);
    }
    pub fn focus(self: ControlToken) !void {
        try self.context.focusRegisteredControl(self);
    }
    pub fn blur(self: ControlToken) !void {
        try self.context.blurRegisteredControlToken(self);
    }
    pub fn close(self: ControlToken) !bool {
        return self.context.unregisterControlRecipient(self);
    }
    pub fn perform(self: ControlToken, action: ControlAction) !ControlResult {
        return self.context.performControl(self, action);
    }
};
/// Borrow Context through every use. A registration owns no business object;
/// close withdraws its slot before that object's storage may be reclaimed.
pub const TextFieldToken = struct {
    context: *Context,
    key: input.text_fields.Key,
    pub fn validate(self: TextFieldToken) !void {
        try self.context.textFieldCurrent(self.key);
    }
    pub fn focus(self: TextFieldToken) !void {
        try self.context.focusTextField(self);
    }
    pub fn blur(self: TextFieldToken) !void {
        try self.context.blurTextFieldToken(self);
    }
    pub fn close(self: TextFieldToken) !bool {
        return self.context.unregisterTextField(self);
    }
    pub fn perform(self: TextFieldToken, action: TextFieldAction) !TextFieldResult {
        return self.context.performTextField(self, action);
    }
};
pub const RenderMode = enum { automatic, gdi, hardware, warp };
/// Pure tests can exercise the real accepted-frame and event boundaries.
/// Production builds expose no entry points through this namespace.
pub const testing = if (builtin.is_test) struct {
    pub const begin = TransformWorkspace.begin;
    pub const commit = Context.commitFrame;
    pub const event = Context.event;
} else struct {};
test {
    _ = @import("recipient_control_tests.zig").Tests(struct {
        pub const ContextType = Context;
        pub const FrameType = Frame;
        pub const TokenType = ControlToken;
        pub const TextTokenType = TextFieldToken;
        pub const RegistrationType = ControlRegistration;
        pub const TextRegistrationType = TextFieldRegistration;
        pub const ScopeType = ControlScope;
        pub const ResultType = ControlResult;
        pub const ActionType = ControlAction;
        pub const TextResultType = TextFieldResult;
        pub const TextActionType = TextFieldAction;
        pub const begin = TransformWorkspace.begin;
        pub const commit = Context.commitFrame;
        pub const event = Context.event;
    });
}

test "nested focused shortcut ranges accept a child override" {
    const Host = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Host.draw, Host.action);
    if (@hasDecl(Context, "prepareShortcutScopes")) try context.prepareShortcutScopes(std.testing.allocator, .{});
    defer if (@hasDecl(Context, "clearShortcutScopes")) context.clearShortcutScopes() catch unreachable;
    context.input_state.beginFrame();
    defer if (context.input_state.building) context.input_state.cancelFrame();
    var frame: Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
    if (@hasDecl(Frame, "beginShortcutScope")) try frame.beginShortcutScope(11, .{});
    try frame.addControl(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
    if (@hasDecl(Frame, "beginShortcutScope")) try frame.beginShortcutScope(12, .{});
    try frame.addControl(2, .{ .x = 30, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
    if (@hasDecl(Frame, "endShortcutScope")) {
        try frame.endShortcutScope();
        try frame.endShortcutScope();
    }
    context.input_state.commitFrame();
    context.input_state.focused = 2;
    try std.testing.expectEqual(@as(?u64, 2), context.input_state.matchShortcut(.{ .key = .f3 }));
    context.input_state.focused = 1;
    try std.testing.expectEqual(@as(?u64, 1), context.input_state.matchShortcut(.{ .key = .f3 }));
}

test "prepared Escape invokes its exact new front once through the App queue" {
    const Host = struct {
        request: ?ShortcutRequestToken = null,
        window: z.Window,
        actions: usize = 0,
        fallbacks: usize = 0,
        inputs: usize = 0,
        err: ?anyerror = null,
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(ptr: *anyopaque, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.actions += 1;
        }
        fn fallback(ptr: *anyopaque, _: z.Window, _: z.KeyInput) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.fallbacks += 1;
        }
        fn event(ptr: *anyopaque, context: *Context, ev: z.Event) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (ev == .key_input) {
                self.inputs += 1;
                self.request = context.deferUnhandledEscape() catch |err| {
                    self.err = err;
                    return true;
                };
            }
            return false;
        }
        fn finish(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.window.app.quit();
        }
    };
    inline for (.{ .normal, .preedit_cycle, .focus_cycle, .control_focus_cycle, .input_focus_cycle, .cancel, .preflight_failure }) |lifecycle| {
        errdefer std.debug.print("Escape queued case: {s}\n", .{@tagName(lifecycle)});
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        defer _ = window.destroy() catch unreachable;
        var host: Host = .{ .window = window };
        var context = Context.init(&host, Host.draw, Host.action);
        context.render_mode = .gdi;
        context.semantics_enabled = false; // The pure backend has no UIA HWND.
        context.on_input = Host.event;
        try context.attach(window);
        var options: ShortcutScopesOptions = .{};
        if (@hasField(ShortcutScopesOptions, "unhandled")) options.unhandled = .{ .context = &host, .call = Host.fallback };
        try context.prepareShortcutScopes(std.testing.allocator, options);
        try window.perform(.focus);
        context.input_state.beginFrame();
        var previous: Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
        try previous.addControl(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .escape } });
        context.commitFrame(window);
        try std.testing.expect(context.handleKeyInput(window, .{ .key = .escape }));
        if (host.err) |err| return err;
        if (lifecycle == .preflight_failure) {
            // Both software backends reject scale before touching native_context.
            Context.event(&context, window, .{ .paint = .{ .native_context = @ptrFromInt(8), .size = .{ .width = 100, .height = 100, .scale = 0 } } });
        } else {
            context.input_state.beginFrame();
            var frame: Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
            if (@hasDecl(Frame, "acceptShortcutRequest")) try frame.acceptShortcutRequest(host.request.?);
            try frame.beginShortcutScope(20, .{ .kind = .overlay, .overlay_order = 1 });
            try frame.addControl(2, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .escape } });
            try frame.endShortcutScope();
            // Pure backend publication exercises the actual Input/Context transaction;
            // the separate native fixture must also establish renderer success.
            context.commitFrame(window);
            if (@hasDecl(Context, "postShortcutContinuation")) context.postShortcutContinuation(window);
        }
        try std.testing.expectEqual(@as(usize, 0), host.actions);
        switch (lifecycle) {
            .preedit_cycle => {
                Context.event(&context, window, .{ .text_preedit = .{ .text = "x", .selection_start = 0, .selection_end = 1 } });
                Context.event(&context, window, .text_preedit_cancel);
            },
            .focus_cycle => {
                Context.event(&context, window, .{ .focus = false });
                Context.event(&context, window, .{ .focus = true });
            },
            .control_focus_cycle => {
                try context.focusControl(2);
                try context.blurControls();
            },
            .input_focus_cycle => {
                context.input_state.tab();
                context.input_state.down(.{ .x = 99, .y = 99 });
            },
            .cancel => Context.event(&context, window, .cancel_input),
            else => {},
        }
        try app.post(.{ .context = &host, .call = Host.finish });
        try app.run();
        try std.testing.expectEqual(@as(usize, if (lifecycle == .normal or lifecycle == .preflight_failure) 1 else 0), host.actions);
        try std.testing.expectEqual(@as(usize, 0), host.fallbacks);
        try std.testing.expectEqual(@as(usize, 1), host.inputs);
    }
}

test "Escape continuations respect queue ownership and can outlive an immediately freed Context" {
    const Host = struct {
        context: ?*Context = null,
        window: z.Window = undefined,
        request: ?ShortcutRequestToken = null,
        err: ?anyerror = null,
        actions: usize = 0,
        fallbacks: usize = 0,
        closed: usize = 0,
        posts: usize = 0,
        close_action: bool = false,
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(ptr: *anyopaque, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.actions += 1;
            if (self.close_action) _ = self.window.destroy() catch unreachable;
        }
        fn fallback(ptr: *anyopaque, _: z.Window, _: z.KeyInput) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.fallbacks += 1;
        }
        fn onInput(ptr: *anyopaque, context: *Context, ev: z.Event) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (ev == .key_input) self.request = context.deferUnhandledEscape() catch |err| {
                self.err = err;
                return true;
            };
            return false;
        }
        fn onClosed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const context = self.context.?;
            self.context = null;
            self.closed += 1;
            // The independent workspace allocator/context outlive this free.
            std.testing.allocator.destroy(context);
        }
        fn count(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.posts += 1;
        }
        fn finish(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.window.app.quit();
        }
        fn countAndFinish(ptr: *anyopaque) void {
            count(ptr);
            finish(ptr);
        }
    };
    const Case = enum { normal, fallback, full, closed, clear, replaced, close_before_take, close_action };
    inline for (std.meta.tags(Case)) |case| {
        errdefer std.debug.print("Escape owner case: {s}\n", .{@tagName(case)});
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var host: Host = .{ .close_action = case == .close_action };
        const window = try app.createWindow(.{ .on_closed = .{ .context = &host, .notify = Host.onClosed } });
        host.window = window;
        defer _ = window.destroy() catch unreachable;
        const context = try std.testing.allocator.create(Context);
        host.context = context;
        context.* = Context.init(&host, Host.draw, Host.action);
        context.render_mode = .gdi;
        context.semantics_enabled = false; // Keep native Bridge coverage in smoke.
        context.on_input = Host.onInput;
        try context.attach(window);
        try context.prepareShortcutScopes(std.testing.allocator, .{ .unhandled = .{ .context = &host, .call = Host.fallback } });
        try window.perform(.focus);
        context.input_state.beginFrame();
        var frame: Frame = .{ .context = context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
        try frame.addControl(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .escape } });
        context.commitFrame(window);
        try std.testing.expect(context.handleKeyInput(window, .{ .key = .escape }));
        try std.testing.expect(context.handleKeyInput(window, .{ .key = .escape, .repeat = true }));
        if (host.err) |err| return err;
        context.input_state.beginFrame();
        try frame.acceptShortcutRequest(host.request.?);
        if (case != .fallback) try frame.addControl(2, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .escape } });
        context.commitFrame(window);
        const workspace = context.input_state.scopes.?;
        if (case == .full) {
            for (0..255) |_| try app.post(.{ .context = &host, .call = Host.count });
            try app.post(.{ .context = &host, .call = Host.countAndFinish });
        } else if (case == .closed) {
            // Exercise the real Mailbox/App.post Closed boundary while physical
            // authority is still valid; public stop normally revokes it first.
            app.queue.close();
        }
        context.postShortcutContinuation(window);
        try std.testing.expectEqual(@as(usize, 0), host.actions + host.fallbacks);
        if (case == .full or case == .closed) {
            try std.testing.expectEqual(@as(?anyerror, if (case == .full) error.Full else error.Closed), workspace.last_error);
            try std.testing.expect(workspace.request == null and !workspace.post_accepted);
            try std.testing.expectEqual(@as(usize, 1), workspace.refs);
        } else {
            try std.testing.expect(workspace.post_accepted);
            try std.testing.expectError(error.Busy, context.prepareShortcutScopes(std.testing.allocator, .{}));
        }
        if (case == .clear) try context.clearShortcutScopes();
        if (case == .replaced) {
            context.input_state.beginFrame();
            try frame.addControl(3, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .escape } });
            context.commitFrame(window);
        }
        if (case == .close_before_take or case == .closed) {
            _ = try window.destroy();
            try std.testing.expect(host.context == null);
        }
        if (case != .full and case != .closed) try app.post(.{ .context = &host, .call = Host.finish });
        try app.run();
        try std.testing.expectEqual(@as(usize, if (case == .normal or case == .close_action) 1 else 0), host.actions);
        try std.testing.expectEqual(@as(usize, if (case == .fallback) 1 else 0), host.fallbacks);
        try std.testing.expectEqual(@as(usize, if (case == .full) 256 else 0), host.posts);
        try std.testing.expect(host.context == null);
        try std.testing.expectEqual(@as(usize, 1), host.closed);
    }
}

pub const Context = struct {
    state: *anyopaque,
    draw: *const fn (*anyopaque, *Frame) void,
    on_action: *const fn (*anyopaque, u64) void,
    on_value: ?*const fn (*anyopaque, u64, ValueChange) void = null,
    /// Input and resize form the explicit update/layout stage. Resize includes
    /// physical size and DPI for preparing resources before a later paint.
    on_input: ?*const fn (*anyopaque, *Context, z.Event) bool = null,
    /// A key released while the window has the keyboard, outside paint; see
    /// `z.Content.key_release`. Text fields and shortcuts see no releases.
    on_key_release: ?*const fn (*anyopaque, *Context, z.KeyInput) void = null,
    on_accessibility_action: ?*const fn (*anyopaque, *Context, accessibility.Action) void = null,
    semantic_name: []const u8 = "Ziggurat",
    semantics_enabled: bool = true,
    attached_semantics_enabled: bool = false,
    semantic_name_storage: [256]u8 = undefined,
    semantic_name_len: usize = 0,
    semantic_tree: if (build_options.accessibility) accessibility.Tree else void = if (build_options.accessibility) .{} else {},
    accessibility_bridge: if (build_options.accessibility) accessibility.Bridge else void = undefined,
    window: ?z.Window = null,
    backdrop_region: ?z.composition.Region = null,
    attachment_phase: enum { detached, attaching, attached, detaching } = .detached,
    input_state: input.Input = .{},
    control_focus_busy: bool = false,
    control_focus_cancelled: bool = false,
    renderer: gdi.Renderer = .{},
    gpu_renderer: if (build_options.gpu) d3d11.Renderer else void = if (build_options.gpu) .{} else {},
    /// Configuration for the next attach; an attached surface keeps its mode.
    render_mode: RenderMode = .automatic,
    /// Optional explicit shared GPU device. Frozen into the renderer at attach.
    /// The owner must outlive detach. No default Context creates a domain.
    gpu_domain: ?*gpu_resources.DeviceDomain = null,
    attached_render_mode: RenderMode = .automatic,
    gpu_unavailable: bool = false,
    gpu_wait: ?z.NativeWaitToken = null,
    last_paint_size: ?z.Size = null,
    deferred_frames: usize = 0,
    gpu_frames: usize = 0,
    gdi_frames: usize = 0,
    fallbacks: usize = 0,
    command_buffer: commands.Buffer = .{},
    painting: bool = false,
    repaint_pending: bool = false,
    composing: bool = false,
    last_enabled: ?bool = null,
    frames: usize = 0,
    layer_candidate_peak: usize = 0,
    theme_value: Theme = .{},
    theme_generation: u64 = 0,
    transforms: ?*TransformWorkspace = null,
    gaussian_workspace: ?*GaussianWorkspace = null,
    backdrop_workspace: ?*backdrop_effects.Workspace = null,
    backdrop_preferences: backdrop_effects.Preferences = .{},
    backdrop_unprepared: u64 = 0,
    shader_workspace: ?*shader_effects.Workspace = null,
    shader_unprepared: u64 = 0,
    frame_stats_options: frame_stats.Options = .{},
    frame_stats_set: bool = false,
    frame_stats_totals: frame_stats.Stats = .{},
    backdrop_software_frames: u64 = 0,
    space_generation: u64 = 0,
    space_binding_epoch: u64 = 0,
    layer_mutating: bool = false,
    accessibility_source_state: accessibility_source.State = .{},
    frame_accessibility_source: ?u64 = null,

    pub fn init(state: *anyopaque, draw: *const fn (*anyopaque, *Frame) void, on_action: *const fn (*anyopaque, u64) void) Context {
        return .{ .state = state, .draw = draw, .on_action = on_action };
    }
    /// One explicit optional allocation. Its allocator and context must outlive
    /// every event reference, including final release after Context on_closed.
    pub fn preparePointerClicks(self: *Context, allocator: std.mem.Allocator, registration: PointerClickRegistration) !void {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        const record = window.app.windows.get(window.key) orelse return error.Closed;
        if (!record.pointerEnabled()) return error.UnsupportedCapability;
        if (self.painting or self.input_state.building or self.input_state.click_preparing) return error.Busy;
        const epoch = self.input_state.click_epoch;
        if (epoch == std.math.maxInt(u64)) return error.IdExhausted;
        self.input_state.click_preparing = true;
        defer self.input_state.click_preparing = false;
        if (self.input_state.clicks) |workspace| {
            if (workspace.allocator.ptr != allocator.ptr or workspace.allocator.vtable != allocator.vtable) return error.AllocatorMismatch;
            defer self.input_state.click_epoch = @max(self.input_state.click_epoch, workspace.state.installation);
            try workspace.state.install(clickWindow(window), self.clickAttachment());
            workspace.registration = registration;
            workspace.last_up = .{};
            return;
        }
        const attachment = self.clickAttachment();
        const candidate = try input.pointer_clicks.Workspace.create(allocator, epoch, clickWindow(window), attachment, registration, self.input_state.len);
        errdefer {
            candidate.close();
            candidate.release();
        }
        if (!self.live(window)) return error.Closed;
        if (self.input_state.click_epoch != epoch or self.input_state.clicks != null or !std.meta.eql(attachment, self.clickAttachment())) return error.PointerClickStateChanged;
        self.input_state.click_epoch = candidate.state.installation;
        self.input_state.clicks = candidate;
    }
    pub fn replacePointerClickRegistration(self: *Context, registration: PointerClickRegistration) !void {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.input_state.building or self.input_state.click_preparing) return error.Busy;
        const workspace = self.input_state.clicks orelse return error.PointerClicksNotPrepared;
        try workspace.state.replaceRegistration();
        workspace.last_up = .{};
        workspace.registration = registration;
    }
    /// Clear keeps displayed nonzero marks denied until another front commits.
    pub fn clearPointerClicks(self: *Context) !void {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.input_state.building) return error.Busy;
        if (self.input_state.clicks) |workspace| workspace.close() else if (self.input_state.click_preparing) {
            self.input_state.click_epoch +|= 1;
        }
        self.input_state.cancelPress();
    }
    /// Mint in update, then reuse the same target in successful frames.
    pub fn newClickTarget(self: *Context, id: u64) !ClickTarget {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.input_state.building or self.input_state.click_preparing) return error.Busy;
        const workspace = self.input_state.clicks orelse return error.PointerClicksNotPrepared;
        const target = try workspace.state.mint(id);
        return .{ .context = self, .installation = target.installation, .registration = target.registration, .serial = target.serial, .id = target.id };
    }
    fn clickWindow(window: z.Window) input.pointer_clicks.kernel.Window {
        return .{ .app = @intFromPtr(window.app), .index = window.key.index, .generation = window.key.generation };
    }
    fn clickAttachment(self: *const Context) input.pointer_clicks.kernel.Attachment {
        return if (self.backdrop_region) |region| .{ .owner = @intFromPtr(region.owner), .index = region.index, .generation = region.generation } else .{};
    }
    /// Explicit update-stage storage. Ordinary Contexts allocate no scopes.
    /// The allocator and its context must outlive every accepted continuation,
    /// including tasks that retire after on_closed has freed this Context.
    pub fn prepareShortcutScopes(self: *Context, allocator: std.mem.Allocator, options: ShortcutScopesOptions) !void {
        const window = self.window;
        if (window) |value| if (value.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.painting or self.composing or self.attachment_phase == .attaching or self.attachment_phase == .detaching) return error.Busy;
        const pin = if (window) |value| self.callbackScope(value) orelse return error.Closed else null;
        defer if (pin) |value| value.end();
        const epoch = self.input_state.scope_epoch;
        if (epoch == std.math.maxInt(u64)) return error.IdExhausted;
        const previous = self.input_state.scopes;
        if (previous) |value| if (value.refs != 1 or value.key_busy) return error.Busy;
        if (previous) |value| value.retain();
        defer if (previous) |value| value.release();
        const candidate = try input.shortcut_scopes.Workspace.create(allocator, options);
        errdefer candidate.release();
        if (!std.meta.eql(window, self.window) or (if (window) |value| !self.live(value) else self.attachment_phase != .detached)) return error.Closed;
        if (self.input_state.scope_epoch != epoch or self.input_state.scopes != previous) return error.ShortcutStateChanged;
        candidate.entry = self;
        candidate.window = window;
        self.input_state.scope_epoch += 1;
        self.input_state.scopes = candidate;
        if (previous) |value| {
            value.close();
            value.release();
        }
    }
    /// Attached hits remain scoped and denied until prepare or actual detach.
    pub fn clearShortcutScopes(self: *Context) !void {
        const window = self.window;
        if (window) |value| if (value.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const pin = if (window) |value| self.callbackScope(value) orelse return error.Closed else null;
        defer if (pin) |value| value.end();
        if (self.painting) return error.Busy;
        const workspace = self.input_state.scopes orelse return;
        workspace.close();
        self.input_state.scope_epoch +|= 1;
        if (window == null) {
            const epoch = self.input_state.scope_epoch;
            self.input_state = .{ .scope_epoch = epoch, .click_epoch = self.input_state.click_epoch };
            workspace.release();
        }
    }
    /// Counts physical storage, including a closed workspace retained by this
    /// Context. Its allocator and allocator context must outlive queued tasks.
    pub fn shortcutScopesStats(self: *const Context) !ShortcutScopesStats {
        if (self.window) |window| if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const workspace = self.input_state.scopes orelse return .{};
        return .{ .metadata_bytes = @sizeOf(input.shortcut_scopes.Workspace), .references = workspace.refs, .serial = workspace.serial, .candidate = workspace.candidate, .accepted_scopes = if (workspace.serial == 0) 0 else workspace.accepted().len, .closed = workspace.closed, .pending = workspace.request != null, .post_accepted = workspace.post_accepted, .last_error = workspace.last_error };
    }
    pub fn shortcutScope(self: *Context, id: u64) !ShortcutScopeToken {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        try self.controlWindowAllowed(window);
        const workspace = self.input_state.scopes orelse return error.ShortcutScopesNotPrepared;
        if (workspace.closed or workspace.serial == 0 or workspace.hit_len != self.input_state.len) return error.ShortcutScopeUnavailable;
        const index = workspace.scope(id) orelse return error.ShortcutScopeUnavailable;
        if (!workspace.enabled(index)) return error.ShortcutScopeUnavailable;
        return .{ .context = self, .window = window, .epoch = self.input_state.scope_epoch, .serial = workspace.serial, .id = id };
    }
    /// Associate existing physical client ownership; never focus or bind it.
    pub fn associateTextShortcutScope(self: *Context, scope: ShortcutScopeToken, token: z.TextClientToken) !void {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        const current = try self.shortcutScope(scope.id);
        if (!std.meta.eql(current, scope) or !std.meta.eql(token.window, window) or !std.meta.eql(window.textClientToken(), @as(?z.TextClientToken, token))) return error.StaleShortcutScope;
        const workspace = self.input_state.scopes.?;
        if (!workspace.advanceRouting()) return error.IdExhausted;
        workspace.text_scope = scope.id;
        workspace.text_token = token;
    }
    /// Bare, non-repeat Escape only. The original key stays consumed even when
    /// close, supersession or a later App.post Full/Closed cancels this request.
    pub fn deferUnhandledEscape(self: *Context) !ShortcutRequestToken {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const workspace = self.input_state.scopes orelse return error.ShortcutScopesNotPrepared;
        const entered = workspace.entered_key orelse return error.NoKeyInput;
        if (workspace.closed or !workspace.key_busy) return error.ShortcutScopesClosed;
        if (entered.key.key != .escape or entered.key.repeat or !std.meta.eql(entered.key.modifiers, z.KeyModifiers{})) return error.InvalidDeferredShortcut;
        if (workspace.request != null or workspace.post_accepted) return error.Busy;
        if (!self.shortcutAuthorityCurrent(workspace, entered.authority)) return error.StaleShortcutScope;
        if (workspace.next_request == std.math.maxInt(u64)) return error.IdExhausted;
        workspace.next_request += 1;
        workspace.request = .{ .id = workspace.next_request, .authority = entered.authority, .origin = workspace.serial };
        return .{ .context = self, .window = window, .epoch = self.input_state.scope_epoch, .id = workspace.next_request };
    }
    fn shortcutAuthorityCurrent(self: *const Context, workspace: *const input.shortcut_scopes.Workspace, authority: input.shortcut_scopes.Authority) bool {
        if (workspace.closed or workspace.entry != @as(?*anyopaque, @ptrCast(@constCast(self))) or self.input_state.scopes != workspace or self.input_state.scope_epoch != authority.installation or workspace.routing_epoch != authority.routing or self.composing or !self.live(authority.window)) return false;
        const state = authority.window.state() catch return false;
        if (!state.focused or !state.enabled or state.modal_blocked or authority.window.app.phase == .stopping or authority.window.app.phase == .stopped) return false;
        return self.input_state.focused == authority.focused and std.meta.eql(authority.text, authority.window.textClientToken()) and std.meta.eql(authority.mode, authority.window.textInputStamp() catch return false);
    }
    /// Cancel logical responsibility. An already accepted App task still owns
    /// and retires its independent workspace pin before App shutdown completes.
    pub fn cancelDeferredShortcut(self: *Context, token: ShortcutRequestToken) !bool {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const workspace = self.input_state.scopes orelse return false;
        if (token.context != self or !std.meta.eql(token.window, window) or token.epoch != self.input_state.scope_epoch) return false;
        const request = workspace.request orelse return false;
        if (request.id != token.id) return false;
        workspace.request = null;
        return true;
    }
    fn beginShortcutAttempt(self: *Context) void {
        const workspace = self.input_state.scopes orelse return;
        workspace.attempt_request = if (workspace.request) |request| (if (request.state == .waiting) request.id else null) else null;
    }
    fn finishShortcutAttempt(self: *Context) void {
        const workspace = self.input_state.scopes orelse return;
        const attempted = workspace.attempt_request;
        workspace.attempt_request = null;
        const request = if (workspace.request) |*value| value else return;
        if (workspace.closed or attempted != request.id or request.state != .waiting or self.gpu_wait != null) return;
        // A completed failed candidate cannot lend any of its registrations.
        if (workspace.serial == request.origin) {
            request.state = .ready;
            request.target = request.origin;
        }
    }
    noinline fn postShortcutContinuation(self: *Context, window: z.Window) void {
        const workspace = self.input_state.scopes orelse return;
        workspace.retain();
        defer workspace.release();
        const scope = self.callbackScope(window) orelse {
            workspace.request = null;
            return;
        };
        defer scope.end();
        const request = workspace.request orelse return;
        if (request.state != .ready or workspace.post_accepted) return;
        if (!self.shortcutAuthorityCurrent(workspace, request.authority) or workspace.serial != request.target) {
            workspace.request = null;
            return;
        }
        workspace.request.?.state = .queued;
        workspace.post_accepted = true;
        workspace.retain();
        window.app.post(.{ .context = workspace, .call = shortcutContinuation }) catch |err| {
            workspace.post_accepted = false;
            workspace.request = null;
            workspace.last_error = err;
            workspace.release();
            // Every field and logical slot is settled before foreign reporting.
            window.report(.{ .domain = .core, .operation = .post, .err = err });
        };
    }
    fn shortcutContinuation(ptr: *anyopaque) void {
        const workspace: *input.shortcut_scopes.Workspace = @ptrCast(@alignCast(ptr));
        defer workspace.release();
        const request = workspace.request;
        workspace.request = null;
        workspace.post_accepted = false;
        const entry = workspace.entry orelse return;
        const window = workspace.window orelse return;
        // The owner thread clears entry before actual detach can free Context.
        // No foreign call occurs between this gate and acquiring its scope.
        const self: *Context = @ptrCast(@alignCast(entry));
        const scope = self.callbackScope(window) orelse return;
        defer scope.end();
        const pending = request orelse return;
        if (pending.state != .queued or workspace.key_busy or workspace.serial != pending.target or !self.shortcutAuthorityCurrent(workspace, pending.authority)) return;
        workspace.key_busy = true;
        defer workspace.key_busy = false;
        const key: z.KeyInput = .{ .key = .escape };
        const id = self.input_state.matchShortcut(key);
        if (!self.shortcutAuthorityCurrent(workspace, pending.authority) or workspace.serial != pending.target) return;
        if (id) |target| {
            const hit = self.input_state.get(target) orelse return;
            if (hit.options.range != null) {
                self.focusControl(target) catch return;
            } else {
                const state = self.state;
                const action = self.on_action;
                action(state, target);
            }
            window.invalidate();
        } else if (workspace.options.unhandled) |fallback| {
            fallback.call(fallback.context, window, key);
            window.invalidate();
        }
        // The scope may detach/free Context. Only workspace is used afterward.
    }
    pub fn currentTheme(self: *const Context) Theme {
        return self.theme_value;
    }
    pub fn themeVersion(self: *const Context) u64 {
        return self.theme_generation;
    }
    /// Copy a complete theme at an update boundary. Fonts and prepared text
    /// remain explicitly owned by their layout clients.
    pub fn setTheme(self: *Context, value: Theme) !bool {
        if (self.window) |window| if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.painting or self.composing or self.attachment_phase == .attaching or self.attachment_phase == .detaching) return error.Busy;
        const scope = if (self.window) |window| window.beginCallback() orelse return error.Closed else null;
        defer if (scope) |pin| pin.end();
        try value.validate();
        if (std.meta.eql(self.theme_value, value)) return false;
        if (self.theme_generation == std.math.maxInt(u64)) return error.IdExhausted;
        self.theme_value = value;
        self.theme_generation += 1;
        if (self.window) |window| window.invalidate();
        return true;
    }

    /// Allocate the scratch planes backdrop effects filter in. Until then,
    /// and when a region exceeds `max_pixels`, effects draw their opaque
    /// fill. The workspace lasts until release or detach.
    pub fn prepareBackdropEffects(self: *Context, allocator: std.mem.Allocator, options: backdrop_effects.Options) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting) return error.Busy;
        const workspace = try backdrop_effects.Workspace.create(allocator, options);
        const previous = self.backdrop_workspace;
        self.backdrop_workspace = workspace;
        if (previous) |value| value.destroy();
        window.invalidate();
    }
    pub fn releaseBackdropEffects(self: *Context) !void {
        if (self.painting) return error.Busy;
        const workspace = self.backdrop_workspace orelse return error.BackdropNotPrepared;
        self.backdrop_workspace = null;
        workspace.destroy();
        if (self.window) |window| if (self.live(window)) window.invalidate();
    }
    /// Allocate the machine that runs shader effects. Element effects also
    /// need `prepareGaussianWorkspace` with room for each element's capture
    /// (box plus margin); backdrop shaders read through the backdrop
    /// workspace. Until then effects draw their content unchanged.
    pub fn prepareShaderEffects(self: *Context, allocator: std.mem.Allocator, options: shader_effects.Options) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting) return error.Busy;
        const workspace = try shader_effects.Workspace.create(allocator, options);
        const previous = self.shader_workspace;
        self.shader_workspace = workspace;
        if (previous) |value| value.destroy();
        window.invalidate();
    }
    pub fn releaseShaderEffects(self: *Context) !void {
        if (self.painting) return error.Busy;
        const workspace = self.shader_workspace orelse return error.ShaderEffectsNotPrepared;
        self.shader_workspace = null;
        workspace.destroy();
        if (self.window) |window| if (self.live(window)) window.invalidate();
    }
    /// Time each frame and log slow ones; see `frame_stats`. Overrides the
    /// `ZIGGURAT_FRAME_STATS` environment variable.
    pub fn setFrameStats(self: *Context, options: frame_stats.Options) void {
        self.frame_stats_options = options;
        self.frame_stats_set = true;
    }
    pub fn frameStats(self: *const Context) frame_stats.Stats {
        return self.frame_stats_totals;
    }
    pub fn shaderEffectStats(self: *const Context) ShaderEffectStats {
        return .{ .workspace = if (self.shader_workspace) |workspace| workspace.stats else .{}, .unprepared = self.shader_unprepared };
    }
    /// The host's reading of the system's reduced transparency and high
    /// contrast settings; either one draws every effect as an opaque fill.
    pub fn setBackdropPreferences(self: *Context, value: backdrop_effects.Preferences) !void {
        if (self.window) |window| if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.painting) return error.Busy;
        if (std.meta.eql(self.backdrop_preferences, value)) return;
        self.backdrop_preferences = value;
        if (self.window) |window| if (self.live(window)) window.invalidate();
    }
    pub fn backdropPreferences(self: *const Context) backdrop_effects.Preferences {
        return self.backdrop_preferences;
    }
    pub fn backdropEffectStats(self: *const Context) BackdropEffectStats {
        return .{ .workspace = if (self.backdrop_workspace) |workspace| workspace.stats else .{}, .unprepared = self.backdrop_unprepared, .software_frames = self.backdrop_software_frames };
    }

    /// Keep this Context at a stable address through its actual detach callback.
    pub fn attach(self: *Context, window: z.Window) !void {
        if (self.window != null or self.attachment_phase != .detached) return error.AlreadyAttached;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        try window.setContent(.{ .context = self, .event = event, .detach = detach, .accessibility = getAccessibility, .key_input = nativeKeyInput, .key_release = nativeKeyRelease });
        errdefer window.cancelContent(self);
        try self.initialize(window);
    }
    /// The Owner remains the only Window.Content. This first slice supports
    /// one full-window software backdrop; native UIA trees are not composed.
    pub fn attachBackdrop(self: *Context, owner: *z.composition.Owner) !z.composition.Region {
        if (self.window != null or self.attachment_phase != .detached) return error.AlreadyAttached;
        if (self.render_mode != .gdi) return error.UnsupportedBackdropRenderMode;
        const window = try owner.window();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const region = try owner.reserveBackdrop();
        errdefer _ = region.remove() catch false;
        try region.attach(.{ .context = self, .attach = attachRegion, .update = updateRegion, .detach = detachRegion, .event = regionEvent, .key_input = regionKeyInput, .accessibility = regionAccessibility });
        _ = try region.snapshot();
        return region;
    }
    const AttachmentScope = union(enum) {
        window: z.CallbackScope,
        region: z.composition.Scope,
        fn end(self: AttachmentScope) void {
            switch (self) {
                .window => |scope| scope.end(),
                .region => |scope| scope.end(),
            }
        }
    };
    fn sameWindow(a: z.Window, b: z.Window) bool {
        return a.app == b.app and std.meta.eql(a.key, b.key);
    }
    fn callbackScope(self: *Context, window: z.Window) ?AttachmentScope {
        if (self.attachment_phase != .attached or !sameWindow(self.window orelse return null, window)) return null;
        if (self.backdrop_region) |region| return .{ .region = region.beginCallback() orelse return null };
        return .{ .window = window.beginCallback() orelse return null };
    }
    fn live(self: *const Context, window: z.Window) bool {
        if (self.attachment_phase != .attached or !sameWindow(self.window orelse return false, window) or window.isClosed()) return false;
        if (self.backdrop_region) |region| _ = region.snapshot() catch return false;
        return true;
    }
    fn controlWindowAllowed(self: *const Context, window: z.Window) !void {
        if (!self.live(window) or window.app.phase == .stopping or window.app.phase == .stopped) return error.Closed;
        const state = try window.state();
        if (!state.enabled or state.modal_blocked) return error.Disabled;
    }
    fn controlsAllowed(self: *Context, window: z.Window) !void {
        try self.controlWindowAllowed(window);
        if (try window.hasTextClient()) {
            if (self.input_state.fields) |fields| if (self.input_state.focused) |id| {
                const key = fields.byId(self.input_state.hits[0..self.input_state.len], id) catch return error.TextClientActive;
                if (self.input_state.available(id) and fields.matchesToken(key, window.textClientToken())) return;
            };
            self.input_state.setFocused(null);
            self.input_state.cancelPress();
            return error.TextClientActive;
        }
    }
    /// Accepted hit identity, including disabled controls that occlude the body.
    pub fn hitControl(self: *Context, point: z.Point) !?input.Hit {
        const window = self.window orelse return error.NotAttached;
        if (std.Thread.getCurrentId() != window.app.owner) return error.WrongThread;
        if (!self.live(window)) return error.Closed;
        return self.input_state.hitControl(point);
    }
    /// The host must revoke its retained text client before handing focus to
    /// controls. Native focus can synchronously remove/replace the accepted ID.
    pub fn focusControl(self: *Context, id: u64) !void {
        const window = self.window orelse return error.NotAttached;
        if (std.Thread.getCurrentId() != window.app.owner) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.input_state.fields) |fields| {
            const key = fields.byId(self.input_state.hits[0..self.input_state.len], id) catch null;
            if (key) |current| switch (try fields.kind(current)) {
                .text => return self.focusTextField(.{ .context = self, .key = current }),
                .control => return self.focusRegisteredControl(.{ .context = self, .key = current }),
            };
        }
        if (self.input_state.clicks) |workspace| workspace.revoke();
        if (self.control_focus_busy) return error.Busy;
        self.control_focus_busy = true;
        self.control_focus_cancelled = false;
        defer self.control_focus_busy = false;
        errdefer {
            self.input_state.setFocused(null);
            self.input_state.cancelPress();
        }
        try self.blurRegisteredControl(window);
        try self.blurTextField(window);
        try self.controlsAllowed(window);
        if (!self.input_state.available(id)) return error.ControlUnavailable;
        self.input_state.setFocused(null);
        self.input_state.cancelPress();
        if (!(try window.state()).focused) try window.perform(.focus);
        try self.controlsAllowed(window);
        if (self.control_focus_cancelled) return error.FocusChanged;
        if (!self.input_state.available(id)) return error.ControlUnavailable;
        self.input_state.setFocused(id);
        window.invalidate();
    }
    /// Clears the existing control authority; it never installs a text client.
    pub fn blurControls(self: *Context) !void {
        const window = self.window orelse return error.NotAttached;
        if (std.Thread.getCurrentId() != window.app.owner) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        const entered_busy = self.control_focus_busy;
        if (entered_busy) self.control_focus_cancelled = true else self.control_focus_busy = true;
        defer {
            if (!entered_busy) self.control_focus_busy = false;
        }
        try self.blurRegisteredControl(window);
        try self.blurTextField(window);
        if (self.input_state.clicks) |workspace| workspace.revoke();
        if (!self.live(window)) return error.Closed;
        if (self.control_focus_busy) self.control_focus_cancelled = true;
        self.input_state.setFocused(null);
        self.input_state.cancelPress();
        window.invalidate();
    }

    /// Explicit coordinate metadata and a bounded recipient registry. This
    /// prepares no raster transform surfaces; those remain opt-in separately.
    /// One bounded optional registry and one existing focus authority. This
    /// common preparation reopens both recipient kinds without reusing serials.
    pub fn prepareRecipients(self: *Context, allocator: std.mem.Allocator, options: RecipientsOptions) !void {
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        try self.prepareTextFields(allocator, .{ .fields = options.recipients, .bytes = options.bytes });
        if (!self.live(window)) return error.Closed;
        try (self.input_state.fields orelse return error.Closed).reopenKind(.control);
    }
    pub fn registerControlRecipient(self: *Context, id: u64, registration: ControlRegistration) !ControlToken {
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        if (self.painting or self.layer_mutating or self.input_state.building) return error.Busy;
        const fields = self.input_state.fields orelse return error.TextFieldsNotPrepared;
        return .{ .context = self, .key = try fields.registerControl(id, registration) };
    }
    /// Optional full native list metadata. The recipient/coordinate owners
    /// must already be explicitly prepared. Native buffers own copied POD;
    /// late providers never retain a Zig model or allocator address.
    pub fn prepareVirtualLists(self: *Context, options: VirtualListsOptions) !void {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (!build_options.accessibility or !self.attached_semantics_enabled) return error.AccessibilityNotEnabled;
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        if (self.painting or self.layer_mutating or self.input_state.building) return error.Busy;
        const fields = self.input_state.fields orelse return error.TextFieldsNotPrepared;
        if (fields.closed or fields.closed_kinds[@intFromEnum(input.text_fields.Kind.control)]) return error.TextFieldsClosed;
        if (options.lists > fields.slots.len) return error.InvalidNativeCollectionLimits;
        try self.accessibility_bridge.prepareVirtualLists(options);
    }
    pub fn virtualListStats(self: *Context) !VirtualListsStats {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (!build_options.accessibility or !self.attached_semantics_enabled) return error.AccessibilityNotEnabled;
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        return self.accessibility_bridge.virtualListStats();
    }
    pub fn installVirtualListCatalog(self: *Context, token: ControlToken, product: *accessibility.virtual_lists.Prepared, revision: u64, bits: []const u64) !void {
        if (token.context != self) return error.ForeignContext;
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (!build_options.accessibility or !self.attached_semantics_enabled) return error.AccessibilityNotEnabled;
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        if (self.painting or self.layer_mutating or self.input_state.building) return error.Busy;
        try token.validateRegistration();
        const fields = self.input_state.fields.?;
        var held = try fields.borrow(token.key);
        defer held.end();
        try self.accessibility_bridge.installVirtualList(token.key, product, revision, bits);
    }
    pub fn applyVirtualListSelection(self: *Context, token: ControlToken, model: u64, patch: anytype) !void {
        if (token.context != self) return error.ForeignContext;
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (!build_options.accessibility or !self.attached_semantics_enabled) return error.AccessibilityNotEnabled;
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        if (self.painting) return error.Busy;
        try token.validateRegistration();
        try self.accessibility_bridge.applyVirtualListSelection(token.key, model, patch);
    }
    pub fn withdrawVirtualList(self: *Context, token: ControlToken) !void {
        if (token.context != self) return error.ForeignContext;
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        if (build_options.accessibility and self.attached_semantics_enabled) self.accessibility_bridge.withdrawVirtualList(token.key);
    }
    fn publishedRecipientMatches(self: *const Context, fields: *const input.text_fields.Workspace, key: input.text_fields.Key) bool {
        for (self.input_state.hits[0..self.input_state.len], 0..) |hit, index| if (hit.id == key.id) {
            const published = fields.publishedKey(index, key.id) catch return false;
            return std.meta.eql(published, key);
        };
        return false;
    }
    pub fn unregisterControlRecipient(self: *Context, token: ControlToken) !bool {
        if (token.context != self) return error.ForeignContext;
        const fields = self.input_state.fields orelse return true;
        if (self.window) |window| window.app.assertOwner();
        if (fields.current(token.key)) try fields.requireKind(token.key, .control);
        const owns_front = self.publishedRecipientMatches(fields, token.key);
        if (build_options.accessibility and self.attached_semantics_enabled) self.accessibility_bridge.withdrawVirtualList(token.key);
        const result = try fields.unregister(token.key);
        if (owns_front and self.input_state.focused == token.key.id) self.input_state.setFocused(null);
        if (owns_front and self.input_state.active == token.key.id) self.input_state.cancelPress();
        return result;
    }
    pub fn focusRegisteredControl(self: *Context, token: ControlToken) !void {
        if (token.context != self) return error.ForeignContext;
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        const fields = self.input_state.fields orelse return error.StaleTextField;
        var entry: FieldEntry = undefined;
        try entry.initKind(self, window, fields, token.key, .control);
        defer entry.borrow.end();
        try self.focusEnteredControl(&entry);
    }
    pub fn performControl(self: *Context, token: ControlToken, action: ControlAction) !ControlResult {
        if (token.context != self) return error.ForeignContext;
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        const fields = self.input_state.fields orelse return error.StaleTextField;
        var entry: FieldEntry = undefined;
        try entry.initKind(self, window, fields, token.key, .control);
        defer entry.borrow.end();
        try self.focusEnteredControl(&entry);
        try FieldEntry.check(&entry);
        const callback = try entry.borrow.control();
        const result = try callback.action(callback.context, entry.scope.scope(), action);
        if (result.changed and self.live(window)) window.invalidate();
        return result;
    }
    fn blurRegisteredControlToken(self: *Context, token: ControlToken) !void {
        try token.validate();
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        const fields = self.input_state.fields orelse return error.StaleTextField;
        var entered = try fields.borrow(token.key);
        defer entered.end();
        if (self.input_state.focused != token.key.id) return;
        const callback = try entered.control();
        self.input_state.setFocused(null);
        self.input_state.cancelPress();
        try callback.blur(callback.context, window);
        if (self.live(window)) window.invalidate();
    }
    fn blurRegisteredControl(self: *Context, window: z.Window) !void {
        const id = self.input_state.focused orelse return;
        const fields = self.input_state.fields orelse return;
        const key = fields.byId(self.input_state.hits[0..self.input_state.len], id) catch return;
        if (try fields.kind(key) != .control) return;
        try self.blurRegisteredControlToken(.{ .context = self, .key = key });
        if (!self.live(window)) return error.Closed;
    }
    fn focusEnteredControl(self: *Context, entry: *FieldEntry) !void {
        try FieldEntry.check(entry);
        try entry.borrow.workspace.?.requireKind(entry.borrow.key, .control);
        const key = entry.borrow.key;
        if (self.input_state.focused == key.id and !(try entry.window.hasTextClient())) return;
        if (self.control_focus_busy) return error.Busy;
        self.control_focus_busy = true;
        self.control_focus_cancelled = false;
        defer self.control_focus_busy = false;
        try self.blurRegisteredControl(entry.window);
        try self.blurTextField(entry.window);
        try FieldEntry.check(entry);
        if (try entry.window.hasTextClient()) return error.TextClientActive;
        if (!(try entry.window.state()).focused) try entry.window.perform(.focus);
        try FieldEntry.check(entry);
        if (self.control_focus_cancelled) return error.FocusChanged;
        const callback = try entry.borrow.control();
        try callback.focus(callback.context, entry.scope.scope());
        try FieldEntry.check(entry);
        if (self.control_focus_cancelled) return error.FocusChanged;
        if (try entry.window.hasTextClient()) return error.TextClientActive;
        self.input_state.setFocused(key.id);
        self.input_state.cancelPress();
        entry.window.invalidate();
    }
    pub fn clearRecipients(self: *Context) !void {
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        if (self.painting or self.layer_mutating or self.input_state.building) return error.Busy;
        const fields = self.input_state.fields orelse return;
        var held: ?input.text_fields.Borrow = null;
        if (self.input_state.focused) |id| {
            const key = fields.byId(self.input_state.hits[0..self.input_state.len], id) catch null;
            if (key) |current| if ((try fields.kind(current)) == .control) {
                held = try fields.borrow(current);
            };
        }
        if (held == null) if (window.textClientToken()) |native| for (fields.slots, 0..) |slot, index| {
            if (slot.registration != null and std.meta.activeTag(slot.registration.?) == .text and slot.token != null and std.meta.eql(slot.token.?, native)) {
                held = try fields.borrow(.{ .epoch = fields.epoch, .serial = slot.serial, .id = slot.id, .slot = @intCast(index) });
                break;
            }
        };
        defer if (held) |*borrow| borrow.end();
        const Callback = union(enum) { text: TextFieldRegistration, control: ControlRegistration };
        const callback: ?Callback = if (held) |*borrow| switch (try borrow.kind()) {
            .text => .{ .text = try borrow.registration() },
            .control => .{ .control = try borrow.control() },
        } else null;
        const clear_focus = if (self.input_state.focused) |id| blk: {
            for (self.input_state.hits[0..self.input_state.len], 0..) |hit, index| if (hit.id == id) break :blk fields.marked(index);
            break :blk false;
        } else false;
        const clear_press = if (self.input_state.active) |id| blk: {
            for (self.input_state.hits[0..self.input_state.len], 0..) |hit, index| if (hit.id == id) break :blk fields.marked(index);
            break :blk false;
        } else false;
        // Withdraw every old callback before any foreign blur can reopen or
        // replace a workspace. An entered borrow alone pins its old context.
        fields.close();
        if (build_options.accessibility and self.attached_semantics_enabled) self.accessibility_bridge.clearVirtualLists();
        if (clear_focus) self.input_state.setFocused(null);
        if (clear_focus or clear_press) self.input_state.cancelPress();
        if (callback) |value| switch (value) {
            .text => |registration| try registration.blur(registration.context, window),
            .control => |registration| try registration.blur(registration.context, window),
        };
        if (self.live(window)) window.invalidate();
    }
    pub fn prepareTextFields(self: *Context, allocator: std.mem.Allocator, options: TextFieldsOptions) !void {
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        if (self.painting or self.layer_mutating or self.input_state.building) return error.Busy;
        const required = try self.recipientMetadata(options.fields);
        if (required.total_bytes > options.bytes) return error.TextFieldBudgetExceeded;
        try self.prepareCoordinates(allocator, .{});
        if (!self.live(window)) return error.Closed;
        if (self.input_state.fields) |fields| {
            if (fields.allocator.ptr != allocator.ptr or fields.allocator.vtable != allocator.vtable) return error.AllocatorMismatch;
            if (fields.slots.len != options.fields) return error.InvalidTextFieldLimits;
            if (fields.publication == std.math.maxInt(u64)) return error.IdExhausted;
            try fields.reopenKind(.text);
            return;
        }
        self.layer_mutating = true;
        defer self.layer_mutating = false;
        const epoch = self.space_binding_epoch;
        const fields = try input.text_fields.Workspace.create(allocator, epoch, options, self.input_state.len);
        errdefer fields.release();
        const native_candidate: ?accessibility.Bridge.RecipientsCandidate = if (build_options.accessibility and self.attached_semantics_enabled) try self.accessibility_bridge.createRecipientsCandidate() else null;
        errdefer if (native_candidate) |candidate| accessibility.Bridge.destroyRecipientsCandidate(candidate);
        if (!self.live(window) or self.space_binding_epoch != epoch) return error.Closed;
        if (native_candidate) |candidate| try self.accessibility_bridge.commitRecipientsCandidate(candidate);
        self.input_state.fields = fields;
    }
    /// Registry plus framework-owned native authority metadata. Coordinates
    /// retain their separate explicit CoordinateOptions budget.
    pub fn recipientMetadata(self: *const Context, capacity: usize) !RecipientsStats {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const registry_bytes = try input.text_fields.Workspace.requiredBytes(.{ .fields = capacity }, self.input_state.len);
        const native_bytes = if (build_options.accessibility and self.attached_semantics_enabled) accessibility.recipientsMetadataBytes() else 0;
        const total_bytes = std.math.add(usize, registry_bytes, native_bytes) catch return error.TextFieldBudgetExceeded;
        return .{ .registry_bytes = registry_bytes, .native_bytes = native_bytes, .total_bytes = total_bytes, .capacity = capacity };
    }
    pub fn recipientsStats(self: *const Context) !RecipientsStats {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const fields = self.input_state.fields orelse return .{};
        const result = try self.recipientMetadata(fields.slots.len);
        std.debug.assert(result.registry_bytes == fields.bytes());
        return result;
    }
    pub fn registerTextField(self: *Context, id: u64, registration: TextFieldRegistration) !TextFieldToken {
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        if (self.painting or self.layer_mutating or self.input_state.building) return error.Busy;
        const fields = self.input_state.fields orelse return error.TextFieldsNotPrepared;
        return .{ .context = self, .key = try fields.register(id, registration) };
    }
    pub fn clearTextFields(self: *Context) !void {
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        if (self.painting or self.layer_mutating or self.input_state.building) return error.Busy;
        const fields = self.input_state.fields orelse return;
        const clear_focus = if (self.input_state.focused) |id| blk: {
            for (self.input_state.hits[0..self.input_state.len], 0..) |hit, index| if (hit.id == id) {
                break :blk (fields.publishedKind(index) catch break :blk false) == .text;
            };
            break :blk false;
        } else false;
        const clear_press = if (self.input_state.active) |id| blk: {
            for (self.input_state.hits[0..self.input_state.len], 0..) |hit, index| if (hit.id == id) {
                break :blk (fields.publishedKind(index) catch break :blk false) == .text;
            };
            break :blk false;
        } else false;
        // Keep the closed marker banks until a successful ordinary frame, or
        // detach. A retired marked hit can never become a legacy action.
        var client: ?input.text_fields.Borrow = null;
        if (window.textClientToken()) |token| for (fields.slots, 0..) |slot, index| {
            if (slot.registration != null and std.meta.activeTag(slot.registration.?) == .text and slot.token != null and std.meta.eql(slot.token.?, token)) {
                client = try fields.borrow(.{ .epoch = fields.epoch, .serial = slot.serial, .id = slot.id, .slot = @intCast(index) });
                break;
            }
        };
        defer if (client) |*borrow| borrow.end();
        const callback = if (client) |borrow| try borrow.registration() else null;
        try fields.closeKind(.text);
        if (clear_focus) self.input_state.setFocused(null);
        if (clear_focus or clear_press) self.input_state.cancelPress();
        if (callback) |registration| try registration.blur(registration.context, window);
        if (self.live(window)) window.invalidate();
    }
    pub fn unregisterTextField(self: *Context, token: TextFieldToken) !bool {
        if (token.context != self) return error.ForeignContext;
        const fields = self.input_state.fields orelse return true;
        if (self.window) |window| window.app.assertOwner();
        // A retired token can still finish its pinned close; a current control
        // must never pass through the text-only public token API.
        if (fields.current(token.key)) try fields.requireKind(token.key, .text);
        const owns_front = self.publishedRecipientMatches(fields, token.key);
        const result = try fields.unregister(token.key);
        if (owns_front and self.input_state.focused == token.key.id) {
            self.input_state.setFocused(null);
            self.input_state.cancelPress();
        }
        if (owns_front and self.input_state.active == token.key.id) self.input_state.cancelPress();
        return result;
    }
    fn textFieldCurrent(self: *Context, key: input.text_fields.Key) !void {
        try self.recipientCurrent(key, .text);
    }
    fn recipientCurrent(self: *Context, key: input.text_fields.Key, kind: input.text_fields.Kind) !void {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        try self.controlWindowAllowed(window);
        const fields = self.input_state.fields orelse return error.StaleTextField;
        try fields.requireKind(key, kind);
        const accepted = try fields.byId(self.input_state.hits[0..self.input_state.len], key.id);
        if (!std.meta.eql(accepted, key) or !self.input_state.available(key.id)) return error.StaleTextField;
    }
    fn controlRegistrationCurrent(self: *Context, key: input.text_fields.Key) !void {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live(window)) return error.Closed;
        try (self.input_state.fields orelse return error.StaleTextField).requireKind(key, .control);
    }
    fn blurTextField(self: *Context, window: z.Window) !void {
        const fields = self.input_state.fields orelse return;
        const current = window.textClientToken() orelse return;
        for (fields.slots, 0..) |slot, index| {
            if (slot.registration == null or std.meta.activeTag(slot.registration.?) != .text or slot.token == null or !std.meta.eql(slot.token.?, current)) continue;
            const key: input.text_fields.Key = .{ .epoch = fields.epoch, .serial = slot.serial, .id = slot.id, .slot = @intCast(index) };
            var borrow = try fields.borrow(key);
            defer borrow.end();
            const callback = try borrow.registration();
            try fields.setToken(key, null);
            self.input_state.setFocused(null);
            self.input_state.cancelPress();
            try callback.blur(callback.context, window);
            if (!self.live(window)) return error.Closed;
            return;
        }
    }
    fn blurTextFieldToken(self: *Context, token: TextFieldToken) !void {
        if (token.context != self) return error.ForeignContext;
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        const fields = self.input_state.fields orelse return error.StaleTextField;
        try fields.requireKind(token.key, .text);
        var borrow = try fields.borrow(token.key);
        defer borrow.end();
        if (self.input_state.focused != token.key.id or !fields.matchesToken(token.key, window.textClientToken())) return;
        const callback = try borrow.registration();
        try fields.setToken(token.key, null);
        self.input_state.setFocused(null);
        self.input_state.cancelPress();
        try callback.blur(callback.context, window);
        if (self.live(window)) window.invalidate();
    }
    const FieldEntry = struct {
        context: *Context,
        window: z.Window,
        borrow: input.text_fields.Borrow,
        publication: u64,
        kind: input.text_fields.Kind = .text,
        press: ?z.PointerPress = null,
        phase: z.PointerPhase = .down,
        scope: input.text_fields.ScopeState,
        fn check(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const owner = self.borrow.workspace orelse return error.StaleTextField;
            if (self.context.input_state.fields != owner or owner.publication != self.publication) return error.StaleTextField;
            try self.context.recipientCurrent(self.borrow.key, self.kind);
            if (self.press) |press| _ = try self.window.pointerPressSnapshot(press, self.phase);
        }
        fn init(self: *@This(), context: *Context, window: z.Window, fields: *input.text_fields.Workspace, key: input.text_fields.Key) !void {
            try self.initKind(context, window, fields, key, .text);
        }
        fn initKind(self: *@This(), context: *Context, window: z.Window, fields: *input.text_fields.Workspace, key: input.text_fields.Key, kind: input.text_fields.Kind) !void {
            try fields.requireKind(key, kind);
            const receipt: ?ControlFrame = if (kind == .control) fields.controlFrame(key) catch |err| switch (err) {
                error.UnpublishedControlFrame => null,
                else => return err,
            } else null;
            self.* = .{ .context = context, .window = window, .borrow = try fields.borrow(key), .kind = kind, .publication = fields.publication, .scope = .{ .window = window, .context = self, .check = check, .control_frame = receipt, .publication = fields.publication } };
        }
    };
    fn focusEnteredTextField(self: *Context, entry: *FieldEntry) !void {
        try FieldEntry.check(entry);
        const key = entry.borrow.key;
        const fields = entry.borrow.workspace.?;
        if (self.input_state.focused == key.id and fields.matchesToken(key, entry.window.textClientToken())) return;
        if (self.control_focus_busy) return error.Busy;
        self.control_focus_busy = true;
        self.control_focus_cancelled = false;
        defer self.control_focus_busy = false;
        try self.blurRegisteredControl(entry.window);
        try self.blurTextField(entry.window);
        try FieldEntry.check(entry);
        if (try entry.window.hasTextClient()) return error.TextClientActive;
        if (!(try entry.window.state()).focused) try entry.window.perform(.focus);
        try FieldEntry.check(entry);
        if (self.control_focus_cancelled) return error.FocusChanged;
        const callback = try entry.borrow.registration();
        const token = try callback.focus(callback.context, entry.scope.scope());
        errdefer if (std.meta.eql(@as(?z.TextClientToken, token), entry.window.textClientToken())) {
            _ = entry.window.clearTextClient(token) catch {};
        };
        try FieldEntry.check(entry);
        if (self.control_focus_cancelled) return error.FocusChanged;
        if (!std.meta.eql(@as(?z.TextClientToken, token), entry.window.textClientToken())) return error.StaleTextClient;
        try fields.setToken(key, token);
        self.input_state.setFocused(key.id);
        self.input_state.cancelPress();
        entry.window.invalidate();
    }
    pub fn focusTextField(self: *Context, token: TextFieldToken) !void {
        if (token.context != self) return error.ForeignContext;
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        const fields = self.input_state.fields orelse return error.StaleTextField;
        var entry: FieldEntry = undefined;
        try entry.init(self, window, fields, token.key);
        defer entry.borrow.end();
        try self.focusEnteredTextField(&entry);
    }
    pub fn performTextField(self: *Context, token: TextFieldToken, action: TextFieldAction) !TextFieldResult {
        if (token.context != self) return error.ForeignContext;
        const window = self.window orelse return error.NotAttached;
        const pin = self.callbackScope(window) orelse return error.Closed;
        defer pin.end();
        const fields = self.input_state.fields orelse return error.StaleTextField;
        var entry: FieldEntry = undefined;
        try entry.init(self, window, fields, token.key);
        defer entry.borrow.end();
        try self.focusEnteredTextField(&entry);
        try FieldEntry.check(&entry);
        const callback = try entry.borrow.registration();
        return callback.action(callback.context, entry.scope.scope(), action);
    }
    fn reportFieldResult(window: z.Window, result: TextFieldResult) void {
        if (result.input_error) |err| window.report(.{ .domain = .core, .operation = .text_input, .err = err });
        if (result.presentation_error) |err| window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
    }
    noinline fn textFieldEvent(self: *Context, window: z.Window, ev: z.Event) bool {
        const pin = self.callbackScope(window) orelse return true;
        defer pin.end();
        const fields = self.input_state.fields orelse return true;
        fields.retain() catch return true;
        defer fields.release();
        const publication = fields.publication;
        const entered_text = window.textClientToken();
        const entered_focus = self.input_state.focused;
        const entered_mode = window.textInputStamp() catch return true;
        const index: ?usize = switch (ev) {
            .pointer_down => |value| self.input_state.hitControlIndex(value.position),
            .wheel => |value| blk: {
                if (self.input_state.hitControlIndex(value.position)) |hover| {
                    if ((fields.publishedKind(hover) catch .text) == .control) break :blk hover;
                }
                for (self.input_state.hits[0..self.input_state.len], 0..) |item, i| if (self.input_state.focused == item.id) break :blk i;
                break :blk null;
            },
            else => blk: {
                const id = if (ev == .pointer_up or ev == .pointer_move) self.input_state.active orelse self.input_state.focused else self.input_state.focused;
                for (self.input_state.hits[0..self.input_state.len], 0..) |item, i| if (id == item.id) break :blk i;
                break :blk null;
            },
        };
        const marked = if (index) |i| fields.marked(i) else false;
        var entry: ?FieldEntry = null;
        if (marked) if (fields.accepted(index.?, self.input_state.hits[index.?].id)) |key| {
            entry = undefined;
            if (entry.?.initKind(self, window, fields, key, fields.kind(key) catch return true)) |_| {
                switch (ev) {
                    .pointer_down => |value| {
                        entry.?.press = if (value.press.sequence != 0) value.press else null;
                        entry.?.scope.pointer_down = value.button == .primary;
                    },
                    .pointer_up => |value| {
                        entry.?.press = if (value.press.sequence != 0) value.press else null;
                        entry.?.phase = .up;
                    },
                    else => {},
                }
            } else |_| entry = null;
        } else |_| {};
        defer if (entry) |*current| current.borrow.end();
        // ScopeState.context must refer to the final stack location, not the
        // optional's temporary value used while constructing it.
        if (entry) |*current| current.scope.context = current;
        if (self.on_input) |callback| if (callback(self.state, self, ev)) {
            window.invalidate();
            return true;
        };
        if (!self.live(window) or self.input_state.fields != fields or fields.publication != publication) return true;
        if (!std.meta.eql(entered_text, window.textClientToken()) or entered_focus != self.input_state.focused or !std.meta.eql(entered_mode, window.textInputStamp() catch return true)) return true;
        if (marked) {
            const current = if (entry) |*value| value else return true;
            FieldEntry.check(current) catch return true;
            if (current.kind == .control) return self.registeredControlEvent(window, current, ev);
            if (ev == .pointer_down) {
                if (ev.pointer_down.button != .primary) return true;
                self.focusEnteredTextField(current) catch |err| {
                    reportFieldResult(window, .{ .input_error = err });
                    return true;
                };
                self.input_state.active = current.borrow.key.id;
            }
            if (self.input_state.focused != current.borrow.key.id) return true;
            const callback = current.borrow.registration() catch return true;
            const input_token = fields.token(current.borrow.key) catch return true;
            const result = callback.input(callback.context, current.scope.scope(), ev) catch |err| TextFieldResult{ .handled = true, .input_error = err };
            reportFieldResult(window, result);
            FieldEntry.check(current) catch return true;
            if (self.input_state.focused != current.borrow.key.id or !std.meta.eql(input_token, window.textClientToken())) return true;
            if (ev == .pointer_up and ev.pointer_up.button == .primary) self.input_state.cancelPress();
            if (result.handled) {
                window.invalidate();
                return true;
            }
            if (ev == .key_input and ev.key_input.key == .tab and !ev.key_input.modifiers.control and !ev.key_input.modifiers.alt and !ev.key_input.modifiers.super) {
                self.tabTextField(window, ev.key_input.modifiers.shift) catch |err| reportFieldResult(window, .{ .input_error = err });
                return true;
            }
            if (ev == .key_input and self.input_state.matchShortcut(ev.key_input) == null) return false;
            // An accepted field owns editing even when it makes no change.
            // Tab alone can explicitly transfer the existing focus authority.
            switch (ev) {
                .pointer_down, .pointer_up, .pointer_move, .text_input, .text_preedit, .text_preedit_cancel, .edit_key, .key => return true,
                else => {},
            }
        } else if (ev == .pointer_down) self.blurTextField(window) catch return true;
        if (ev == .key_input) return self.handleControlKey(window, ev.key_input, legacyKey(ev.key_input));
        self.eventDefault(window, ev, true);
        return false;
    }
    noinline fn registeredControlEvent(self: *Context, window: z.Window, entry: *FieldEntry, ev: z.Event) bool {
        FieldEntry.check(entry) catch return true;
        if (ev == .pointer_down) {
            if (ev.pointer_down.button != .primary and ev.pointer_down.button != .secondary) return true;
            self.focusEnteredControl(entry) catch |err| {
                reportFieldResult(window, .{ .input_error = err });
                return true;
            };
            if (ev.pointer_down.button == .primary) self.input_state.active = entry.borrow.key.id;
        }
        if (ev != .wheel and self.input_state.focused != entry.borrow.key.id) return true;
        const callback = entry.borrow.control() catch return true;
        const result = callback.input(callback.context, entry.scope.scope(), ev) catch |err| ControlResult{ .handled = true, .input_error = err };
        reportFieldResult(window, .{ .handled = result.handled, .input_error = result.input_error, .presentation_error = result.presentation_error });
        if (result.changed and self.live(window)) window.invalidate();
        FieldEntry.check(entry) catch return true;
        if (ev != .wheel and (self.input_state.focused != entry.borrow.key.id or (window.hasTextClient() catch true))) return true;
        if (ev == .pointer_up and ev.pointer_up.button == .primary) self.input_state.cancelPress();
        if (result.handled) {
            if (!result.changed) window.invalidate();
            return true;
        }
        if (ev == .key_input and ev.key_input.key == .tab and !ev.key_input.modifiers.control and !ev.key_input.modifiers.alt and !ev.key_input.modifiers.super) {
            self.tabTextField(window, ev.key_input.modifiers.shift) catch |err| reportFieldResult(window, .{ .input_error = err });
            return true;
        }
        switch (ev) {
            .pointer_down, .pointer_up, .pointer_move, .text_input, .text_preedit, .text_preedit_cancel, .edit_key, .key => return true,
            .key_input => return self.handleControlKey(window, ev.key_input, legacyKey(ev.key_input)),
            else => {
                self.eventDefault(window, ev, true);
                return false;
            },
        }
    }
    fn tabTextField(self: *Context, window: z.Window, backwards: bool) !void {
        const before = self.input_state.focused;
        self.input_state.tabDirection(backwards);
        const next = self.input_state.focused;
        self.input_state.setFocused(before);
        if (next) |id| try self.focusControl(id) else try self.blurControls();
        if (self.live(window)) window.invalidate();
    }
    noinline fn textFieldAction(self: *Context, window: z.Window, action: accessibility.Action) bool {
        const id: u64 = switch (action) {
            .set_value => |value| value.id,
            .select_text => |value| value.id,
            .set_focus => |value| value,
            .invoke => |value| value,
            else => return false,
        };
        const fields = self.input_state.fields orelse return false;
        var index: ?usize = null;
        for (self.input_state.hits[0..self.input_state.len], 0..) |item, i| if (item.id == id) {
            index = i;
            break;
        };
        if (index == null or !fields.marked(index.?)) return false;
        const key = fields.accepted(index.?, id) catch return true;
        var entry: FieldEntry = undefined;
        entry.init(self, window, fields, key) catch return true;
        defer entry.borrow.end();
        self.focusEnteredTextField(&entry) catch return true;
        if (action == .set_focus or action == .invoke) return true;
        FieldEntry.check(&entry) catch return true;
        const operation: TextFieldAction = switch (action) {
            .set_value => |value| .{ .set_value = value.text },
            .select_text => |value| .{ .select_text = .{ .start_utf16 = value.start_utf16, .end_utf16 = value.end_utf16 } },
            else => unreachable,
        };
        const callback = entry.borrow.registration() catch return true;
        const result = callback.action(callback.context, entry.scope.scope(), operation) catch |err| TextFieldResult{ .handled = true, .input_error = err };
        reportFieldResult(window, result);
        if (self.live(window)) window.invalidate();
        return true;
    }
    fn attachRegion(ptr: *anyopaque, region: z.composition.Region) !void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const snapshot = try region.snapshot();
        if (snapshot.kind != .backdrop) return error.UnsupportedViewport;
        self.backdrop_region = region;
        errdefer self.backdrop_region = null;
        try self.initialize(snapshot.window);
    }
    fn updateRegion(_: *anyopaque, _: z.composition.Region, _: z.composition.Viewport) !void {
        return error.AutomaticViewport;
    }
    fn detachRegion(ptr: *anyopaque, _: z.composition.Region) void {
        detach(ptr);
    }
    fn regionEvent(ptr: *anyopaque, region: z.composition.Region, ev: z.Event) void {
        const snapshot = region.snapshot() catch return;
        event(ptr, snapshot.window, ev);
    }
    fn regionKeyInput(ptr: *anyopaque, region: z.composition.Region, key: z.KeyInput) bool {
        const snapshot = region.snapshot() catch return true;
        return nativeKeyInput(ptr, snapshot.window, key);
    }
    fn regionAccessibility(ptr: *anyopaque, region: z.composition.Region, wp: usize, lp: isize) ?isize {
        const snapshot = region.snapshot() catch return null;
        return getAccessibility(ptr, snapshot.window, wp, lp);
    }
    fn initialize(self: *Context, window: z.Window) !void {
        if (!self.frame_stats_set) self.frame_stats_options = frame_stats.fromEnvironment();
        self.attachment_phase = .attaching;
        errdefer self.attachment_phase = .detached;
        if (self.gpu_domain) |domain| {
            if (!build_options.gpu) return error.GpuNotEnabled;
            if (self.render_mode == .gdi or self.backdrop_region != null) return error.UnsupportedDomainRenderMode;
            try domain.checkApplication(window.app);
            const driver = try domain.driver();
            if ((self.render_mode == .hardware and driver != .hardware) or (self.render_mode == .warp and driver != .warp)) return error.DomainDriverMismatch;
        }
        self.window = window;
        if (self.input_state.scopes) |workspace| workspace.window = window;
        errdefer {
            self.window = null;
            self.last_enabled = null;
        }
        self.painting = false;
        self.repaint_pending = false;
        self.composing = false;
        self.last_enabled = (try window.state()).enabled;
        self.attached_render_mode = self.render_mode;
        self.attached_semantics_enabled = build_options.accessibility and self.semantics_enabled;
        errdefer self.attached_semantics_enabled = false;
        if (build_options.accessibility and self.attached_semantics_enabled) {
            if (self.semantic_name.len > self.semantic_name_storage.len) return error.SemanticNameTooLong;
            @memcpy(self.semantic_name_storage[0..self.semantic_name.len], self.semantic_name);
            self.semantic_name_len = self.semantic_name.len;
            self.accessibility_bridge = accessibility.Bridge.init(self, accessibilityAction);
            self.accessibility_bridge.on_recipient_action = accessibilityRecipientAction;
            try self.accessibility_bridge.attach(window);
            errdefer self.accessibility_bridge.detach();
            try self.semantic_tree.reset(self.semantic_name_storage[0..self.semantic_name_len], .{ .x = 0, .y = 0, .width = 0, .height = 0 });
            try self.accessibility_bridge.publish(&self.semantic_tree);
        }
        self.gpu_unavailable = false;
        if (build_options.gpu and self.render_mode != .gdi) {
            self.gpu_renderer.init(.{ .driver = if (self.render_mode == .warp) .warp else .hardware, .domain = self.gpu_domain, .native_wait_slot = &self.gpu_wait }) catch |err| {
                if (self.gpu_domain != null) return err;
                self.gpu_unavailable = true;
                window.report(.{ .severity = .warning, .domain = .renderer, .operation = .content_attach, .err = err, .code = @bitCast(self.gpu_renderer.last_hresult) });
            };
        }
        self.attachment_phase = .attached;
        window.invalidate();
    }
    fn getAccessibility(ptr: *anyopaque, window: z.Window, wp: usize, lp: isize) ?isize {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const scope = self.callbackScope(window) orelse return null;
        defer scope.end();
        if (self.accessibility_source_state.pin()) |pin| {
            const result = pin.source.query(pin.source.context, window, wp, lp);
            const current = self.accessibility_source_state.isCurrent(pin);
            self.accessibility_source_state.end(pin);
            if (result != null or !current or !self.live(window)) return result;
        }
        if (build_options.accessibility and self.attached_semantics_enabled) return self.accessibility_bridge.getObject(window, wp, lp);
        return null;
    }
    /// Borrow a single explicit native accessibility source. The returned token
    /// may already have retired if disposal of the old source closed the owner.
    /// Failed validation/Busy does not take responsibility for the new source.
    pub fn installAccessibilitySource(self: *Context, source: AccessibilitySource) !AccessibilitySourceToken {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        const generation = try self.accessibility_source_state.install(source);
        if (self.live(window)) window.invalidate();
        return .{ .context = self, .generation = generation };
    }
    pub fn clearAccessibilitySource(self: *Context, token: AccessibilitySourceToken) !bool {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (token.context != self) return false;
        return self.accessibility_source_state.clear(token.generation);
    }
    fn accessibilityPhase(self: *Context, window: z.Window, phase: AccessibilityPhase) bool {
        const pin = self.accessibility_source_state.pin() orelse return self.live(window);
        if (pin.source.phase) |callback| callback(pin.source.context, window, phase);
        const current = self.accessibility_source_state.isCurrent(pin);
        self.accessibility_source_state.end(pin);
        return current and self.live(window);
    }
    fn accessibilityPositionChanged(self: *Context, window: z.Window) void {
        if (self.accessibility_source_state.pin()) |pin| {
            if (pin.source.position_changed) |callback| callback(pin.source.context, window);
            const current = self.accessibility_source_state.isCurrent(pin);
            self.accessibility_source_state.end(pin);
            if (!current or !self.live(window)) return;
        }
        if (build_options.accessibility and self.attached_semantics_enabled) self.accessibility_bridge.positionChanged() catch |err| {
            if (err != error.Closed) window.report(.{ .domain = .hresult, .operation = .paint, .err = err, .code = if (self.accessibility_bridge.last_hresult < 0) @bitCast(self.accessibility_bridge.last_hresult) else null });
        };
    }
    fn gradientPreparationAllowed(self: *const Context, window: z.Window) bool {
        return self.live(window) and (window.app.phase == .ready or window.app.phase == .running);
    }
    /// Prepare the separate interpolation shader outside paint. Failure keeps
    /// the old front; device loss requires an explicit preparation again.
    pub fn prepareGradientInterpolation(self: *Context) !void {
        if (comptime builtin.os.tag != .windows or !build_options.gpu) return error.GpuNotEnabled;
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (!self.gradientPreparationAllowed(window)) return error.Closed;
        if (self.painting or self.layer_mutating) return error.Busy;
        if (self.gpu_unavailable or self.attached_render_mode == .gdi) return error.GraphicsUnavailable;
        self.layer_mutating = true;
        defer {
            self.layer_mutating = false;
            if (self.repaint_pending and self.live(window)) {
                self.repaint_pending = false;
                window.invalidate();
            }
        }
        if (try self.gpu_renderer.checkGradientInterpolationPrepared()) return;
        const candidate = try self.gpu_renderer.createGradientInterpolationCandidate();
        errdefer d3d11.Renderer.destroyGradientInterpolationCandidate(candidate);
        if (!self.gradientPreparationAllowed(window)) return error.Closed;
        try self.gpu_renderer.retireGradientInterpolation(candidate);
        if (!self.gradientPreparationAllowed(window)) return error.Closed;
        try self.gpu_renderer.commitGradientInterpolationCandidate(candidate);
    }
    pub fn releaseGradientInterpolation(self: *Context) !void {
        if (comptime builtin.os.tag != .windows or !build_options.gpu) return error.GpuNotEnabled;
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.layer_mutating) return error.Busy;
        self.layer_mutating = true;
        defer {
            self.layer_mutating = false;
            if (self.repaint_pending and self.live(window)) {
                self.repaint_pending = false;
                window.invalidate();
            }
        }
        if (self.gpu_renderer.native != null) try self.gpu_renderer.releaseGradientInterpolation();
    }
    pub fn gradientInterpolationStats(self: *Context) !GradientInterpolationStats {
        if (comptime builtin.os.tag != .windows or !build_options.gpu) return error.GpuNotEnabled;
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.layer_mutating) return error.Busy;
        return self.gpu_renderer.gradientInterpolationStats();
    }
    /// Reserve front/work/group planes outside paint. Both candidates succeed
    /// before either backend replaces its previous workspace.
    pub fn prepareLayers(self: *Context, allocator: std.mem.Allocator, options: layers.Options) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.layer_mutating) return error.Busy;
        if (self.transforms) |workspace| if (workspace.state.committed().inUse()) return error.ResourceInUse;
        self.layer_mutating = true;
        defer self.layer_mutating = false;
        const gpu = build_options.gpu and !self.gpu_unavailable and self.attached_render_mode != .gdi;
        const total = try layers.Plan.checkContext(options, if (builtin.os.tag == .linux) .cairo else .gdi, gpu);
        self.cancelGpuWait();
        const old = self.renderer.layerSurfaceBytes() + (if (build_options.gpu) self.gpu_renderer.layerStats().pixel_bytes else 0);
        self.layer_candidate_peak = @max(self.layer_candidate_peak, old + total);
        const software_candidate = try self.renderer.createLayerCandidate(allocator, options);
        errdefer gdi.Renderer.destroyLayerCandidate(software_candidate);
        if (!self.live(window)) return error.Closed;
        if (build_options.gpu and gpu) {
            const gpu_candidate = try self.gpu_renderer.createLayerCandidate(allocator, options);
            errdefer d3d11.Renderer.destroyLayerCandidate(gpu_candidate);
            if (!self.live(window)) return error.Closed;
            try self.gpu_renderer.commitLayerCandidate(gpu_candidate);
            self.renderer.commitLayerCandidate(software_candidate);
        } else self.renderer.commitLayerCandidate(software_candidate);
        self.dropTransformMetadata();
        self.dropGaussianMetadata();
        if (!self.live(window)) return error.Closed;
    }
    /// Explicit whole-subtree filtering capacity. All old owners and both new
    /// backends remain charged until the complete candidate can replace them.
    pub fn prepareGaussianWorkspace(self: *Context, allocator: std.mem.Allocator, options: GaussianWorkspaceOptions) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.layer_mutating) return error.Busy;
        self.layer_mutating = true;
        defer self.layer_mutating = false;
        const gpu = build_options.gpu and !self.gpu_unavailable and self.attached_render_mode != .gdi;
        const software_plan = try gaussian_scope.Plan.init(options, if (builtin.os.tag == .linux) .cairo else .gdi, self.renderer.transformOptions());
        const gpu_plan: ?gaussian_scope.Plan = if (build_options.gpu and gpu) try gaussian_scope.Plan.init(options, .gpu, self.gpu_renderer.transformOptions()) else null;
        const old = self.renderer.layerSurfaceBytes() + self.renderer.layerStats().metadata_bytes + (if (build_options.gpu) self.gpu_renderer.layerStats().pixel_bytes + self.gpu_renderer.layerStats().metadata_bytes else 0) + (if (self.gaussian_workspace != null) @as(usize, @sizeOf(GaussianWorkspace)) else 0) + (try self.transformStats()).metadata_bytes;
        const metadata = @sizeOf(GaussianWorkspace) + gdi.Renderer.layerMetadataBytes() + gdi.Renderer.gaussianMetadataBytes() + (if (build_options.gpu and gpu) d3d11.Renderer.layerMetadataBytes() + d3d11.Renderer.gaussianMetadataBytes() else 0);
        const peak = try gaussian_scope.Plan.checkPeak(software_plan, gpu_plan, old, metadata);
        self.layer_candidate_peak = @max(self.layer_candidate_peak, peak);
        const workspace = try allocator.create(GaussianWorkspace);
        var workspace_transferred = false;
        errdefer if (!workspace_transferred) allocator.destroy(workspace);
        workspace.* = .{ .allocator = allocator, .options = options };
        if (!self.live(window)) return error.Closed;
        self.cancelGpuWait();
        const software_candidate = try self.renderer.createGaussianCandidate(allocator, software_plan);
        var software_transferred = false;
        errdefer if (!software_transferred) gdi.Renderer.destroyLayerCandidate(software_candidate);
        if (!self.live(window)) return error.Closed;
        if (build_options.gpu and gpu) {
            const gpu_candidate = try self.gpu_renderer.createGaussianCandidate(allocator, gpu_plan.?);
            errdefer d3d11.Renderer.destroyLayerCandidate(gpu_candidate);
            if (!self.live(window)) return error.Closed;
            try self.gpu_renderer.commitLayerCandidate(gpu_candidate);
            self.renderer.commitLayerCandidate(software_candidate);
        } else self.renderer.commitLayerCandidate(software_candidate);
        software_transferred = true;
        if (!self.live(window)) return error.Closed;
        const previous = self.gaussian_workspace;
        self.gaussian_workspace = workspace;
        workspace_transferred = true;
        // The valid new owner is published before an old allocator can reenter.
        // A close is completed by the already pinned Context's detach path,
        // including this new metadata owner; never free a published candidate.
        if (previous) |value| value.allocator.destroy(value);
        if (!self.live(window)) return error.Closed;
    }
    /// Drop filter scratch/program/metadata, retaining ordinary layer planes
    /// and accepted coordinate geometry. releaseLayers also drops those planes.
    pub fn releaseGaussianWorkspace(self: *Context) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.layer_mutating) return error.Busy;
        if (self.gaussian_workspace == null) return error.GaussianNotPrepared;
        self.layer_mutating = true;
        defer self.layer_mutating = false;
        try self.renderer.releaseGaussian();
        if (!self.live(window)) return error.Closed;
        if (build_options.gpu) try self.gpu_renderer.releaseGaussian();
        self.dropGaussianMetadata();
        if (!self.live(window)) return error.Closed;
    }
    fn dropGaussianMetadata(self: *Context) void {
        const workspace = self.gaussian_workspace orelse return;
        self.gaussian_workspace = null;
        std.debug.assert(!workspace.storage.bound and workspace.storage.len == 0);
        workspace.allocator.destroy(workspace);
    }
    noinline fn preflightGaussianFrame(self: *Context, size: z.Size, using_gpu: bool) !void {
        const workspace = self.gaussian_workspace orelse return error.GaussianNotPrepared;
        const plan = (if (build_options.gpu and using_gpu) self.gpu_renderer.layerPlan() else self.renderer.layerPlan()) orelse return error.GaussianNotPrepared;
        const filter_capacity = self.renderer.gaussianCapacity() orelse return error.GaussianNotPrepared;
        const work = if (plan.transform_source != null) @min(workspace.options.render_work, plan.transform_work) else workspace.options.render_work;
        _ = try @import("render_batch.zig").preflight(&self.command_buffer, .{ .size = size, .max_depth = plan.options.max_depth, .legacy_text = plan.options.legacy_text, .render_work = work, .transform_plan = plan, .gaussian_capacity = filter_capacity, .texture_domain = if (build_options.gpu and using_gpu) (if (self.gpu_renderer.domain_borrow) |borrow| borrow.epoch else null) else null });
    }
    /// Prepare coordinate/capture authority and attached semantic geometry,
    /// without renderer planes or transform programs. The same workspace can
    /// later be upgraded by prepareTransforms without replacing its epoch or
    /// accepted capture banks.
    pub fn prepareCoordinates(self: *Context, allocator: std.mem.Allocator, options: CoordinateOptions) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.layer_mutating) return error.Busy;
        if (options.bytes == 0) return error.InvalidCoordinateLimits;
        const native_geometry_bytes: usize = if (build_options.accessibility and self.attached_semantics_enabled) @sizeOf(accessibility.NativeGeometry) else 0;
        const total = std.math.add(usize, @sizeOf(TransformWorkspace), native_geometry_bytes) catch return error.CoordinateBudgetExceeded;
        if (total > options.bytes) return error.CoordinateBudgetExceeded;
        const needs_geometry = build_options.accessibility and self.attached_semantics_enabled and self.accessibility_bridge.geometry_scratch == null;
        if (self.transforms != null and !needs_geometry) return;
        if (self.transforms == null and (self.space_generation == std.math.maxInt(u64) or self.space_binding_epoch == std.math.maxInt(u64))) return error.GenerationExhausted;
        self.layer_mutating = true;
        defer self.layer_mutating = false;
        var candidate_workspace: ?*TransformWorkspace = null;
        errdefer if (candidate_workspace) |value| allocator.destroy(value);
        const workspace = self.transforms orelse candidate: {
            const value = try allocator.create(TransformWorkspace);
            candidate_workspace = value;
            if (!self.live(window)) return error.Closed;
            value.* = .{ .allocator = allocator };
            break :candidate value;
        };
        var geometry_candidate: ?accessibility.Bridge.GeometryCandidate = null;
        errdefer if (build_options.accessibility) if (geometry_candidate) |value| accessibility.Bridge.destroyGeometryCandidate(value);
        var geometry_committed = false;
        errdefer if (build_options.accessibility and geometry_committed) self.accessibility_bridge.releaseGeometry();
        if (build_options.accessibility and needs_geometry) {
            geometry_candidate = try self.accessibility_bridge.createGeometryCandidate(&workspace.native_geometry);
            if (!self.live(window)) return error.Closed;
            try self.accessibility_bridge.commitGeometryCandidate(geometry_candidate.?);
            geometry_candidate = null;
            geometry_committed = true;
            if (!self.live(window)) return error.Closed;
        }
        if (candidate_workspace) |value| {
            self.transforms = value;
            self.space_binding_epoch += 1;
            candidate_workspace = null;
        }
    }
    /// Opt-in raster sources and coordinate snapshots. Native candidates and
    /// metadata are ready before replacing either backend. Reprepare retains
    /// the accepted coordinate snapshot until another frame succeeds.
    pub fn prepareTransforms(self: *Context, allocator: std.mem.Allocator, options: layers.TransformOptions) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.layer_mutating) return error.Busy;
        if (self.input_state.clicks) |workspace| workspace.revoke();
        if (self.space_generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        if (self.transforms == null and self.space_binding_epoch == std.math.maxInt(u64)) return error.GenerationExhausted;
        self.layer_mutating = true;
        defer self.layer_mutating = false;
        const gpu = build_options.gpu and !self.gpu_unavailable and self.attached_render_mode != .gdi;
        const total = try layers.Plan.checkTransformContext(options, if (builtin.os.tag == .linux) .cairo else .gdi, gpu);
        const old = self.renderer.layerSurfaceBytes() + (if (build_options.gpu) self.gpu_renderer.layerStats().pixel_bytes else 0);
        const peak = std.math.add(usize, old, total) catch return error.LayerAggregateBudgetExceeded;
        const native_geometry_bytes: usize = if (build_options.accessibility and self.attached_semantics_enabled) @sizeOf(accessibility.NativeGeometry) else 0;
        const with_metadata = std.math.add(usize, peak, @sizeOf(TransformWorkspace) + native_geometry_bytes) catch return error.LayerAggregateBudgetExceeded;
        if (with_metadata > options.layers.total_bytes) return error.LayerAggregateBudgetExceeded;
        self.layer_candidate_peak = @max(self.layer_candidate_peak, with_metadata);
        var candidate_workspace: ?*TransformWorkspace = null;
        errdefer if (candidate_workspace) |value| allocator.destroy(value);
        if (self.transforms == null) {
            const value = try allocator.create(TransformWorkspace);
            candidate_workspace = value;
            if (!self.live(window)) return error.Closed;
            value.* = .{ .allocator = allocator, .options = options };
        }
        var geometry_candidate: ?accessibility.Bridge.GeometryCandidate = null;
        errdefer if (build_options.accessibility) if (geometry_candidate) |value| accessibility.Bridge.destroyGeometryCandidate(value);
        if (build_options.accessibility and self.attached_semantics_enabled and self.accessibility_bridge.geometry_scratch == null) {
            const workspace = candidate_workspace orelse self.transforms.?;
            geometry_candidate = try self.accessibility_bridge.createGeometryCandidate(&workspace.native_geometry);
        }
        self.cancelGpuWait();
        const software_candidate = try self.renderer.createTransformCandidate(allocator, options);
        var software_transferred = false;
        errdefer if (!software_transferred) gdi.Renderer.destroyLayerCandidate(software_candidate);
        if (!self.live(window)) return error.Closed;
        if (build_options.gpu and gpu) {
            const gpu_candidate = try self.gpu_renderer.createTransformCandidate(allocator, options);
            errdefer d3d11.Renderer.destroyLayerCandidate(gpu_candidate);
            if (!self.live(window)) return error.Closed;
            try self.gpu_renderer.commitLayerCandidate(gpu_candidate);
            self.renderer.commitLayerCandidate(software_candidate);
        } else self.renderer.commitLayerCandidate(software_candidate);
        software_transferred = true;
        // Native commit may release previous owners. Window scope keeps this
        // Context alive, but a close must not publish a new metadata owner.
        if (!self.live(window)) return error.Closed;
        if (build_options.accessibility) if (geometry_candidate) |value| {
            try self.accessibility_bridge.commitGeometryCandidate(value);
            geometry_candidate = null;
        };
        if (candidate_workspace) |value| {
            self.transforms = value;
            self.space_binding_epoch += 1;
            candidate_workspace = null;
        }
        self.transforms.?.options = options;
        self.dropGaussianMetadata();
        if (!self.live(window)) return error.Closed;
    }
    /// Submit a successful frame without transforms/captured Spaces first.
    /// Detach always performs final cleanup, including an in-use workspace.
    pub fn releaseTransforms(self: *Context) !void {
        if (self.transforms == null) return error.TransformsNotPrepared;
        try self.releaseLayers();
    }
    pub fn releaseLayers(self: *Context) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting or self.layer_mutating) return error.Busy;
        if (self.input_state.clicks) |workspace| workspace.revoke();
        if (self.transforms) |workspace| if (workspace.state.committed().inUse()) return error.ResourceInUse;
        self.layer_mutating = true;
        defer self.layer_mutating = false;
        self.cancelGpuWait();
        try self.renderer.releaseLayers();
        if (!self.live(window)) return error.Closed;
        if (build_options.gpu) try self.gpu_renderer.releaseLayers();
        self.dropTransformMetadata();
        self.dropGaussianMetadata();
        if (!self.live(window)) return error.Closed;
    }
    fn dropTransformMetadata(self: *Context) void {
        const workspace = self.transforms orelse return;
        const allocator = workspace.allocator;
        self.transforms = null;
        if (self.space_binding_epoch != std.math.maxInt(u64)) self.space_binding_epoch += 1;
        self.input_state.mapped = null;
        self.input_state.pending_mapped = null;
        if (build_options.accessibility) {
            self.semantic_tree.mapped = null;
            if (self.attached_semantics_enabled) self.accessibility_bridge.releaseGeometry();
        }
        if (self.space_generation != std.math.maxInt(u64)) self.space_generation += 1;
        allocator.destroy(workspace);
    }
    pub fn transformStats(self: *const Context) !TransformCacheStats {
        const layer_stats = try self.layerStats();
        const workspace = self.transforms;
        const native_geometry_bytes: usize = if (build_options.accessibility and self.attached_semantics_enabled and self.accessibility_bridge.geometry_scratch != null) @sizeOf(accessibility.NativeGeometry) else 0;
        return .{ .layers = layer_stats, .metadata_bytes = (if (workspace != null) @as(usize, @sizeOf(TransformWorkspace)) else 0) + native_geometry_bytes, .generation = self.space_generation, .accepted_scopes = if (workspace) |value| value.state.committed().scope_count else 0, .accepted_captures = if (workspace) |value| value.state.committed().capture_len else 0 };
    }
    pub fn committedSpace(self: *Context, id: u64) !SpaceToken {
        const window = self.window orelse return error.NotAttached;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        const workspace = self.transforms orelse return error.TransformsNotPrepared;
        _ = try workspace.state.lookup(self.space_generation, id);
        return .{ .context = self, .generation = self.space_generation, .id = id };
    }
    pub fn layerStats(self: *const Context) !LayerCacheStats {
        const window = self.window orelse return error.NotAttached;
        window.app.assertOwner();
        if (!self.live(window)) return error.Closed;
        const software_stats = self.renderer.layerStats();
        const gpu_stats: ?layers.Stats = if (build_options.gpu) self.gpu_renderer.layerStats() else null;
        return .{ .software = software_stats, .gpu = gpu_stats, .current_bytes = software_stats.pixel_bytes + (if (gpu_stats) |value| value.pixel_bytes else 0), .ordinary_front_bytes = if (software_stats.prepared) 0 else self.renderer.layerSurfaceBytes(), .candidate_peak_bytes = self.layer_candidate_peak };
    }
    /// Explicit resource work outside paint. Each backend upload is a separate
    /// transaction: a GPU failure can leave a usable software residency.
    pub fn uploadImage(self: *Context, view: drawing.ImageView) !void {
        try self.uploadImageMode(view, false);
    }
    pub fn uploadCoverage(self: *Context, view: drawing.CoverageView) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting) return error.Busy;
        try view.validate();
        self.cancelGpuWait();
        try self.renderer.uploadCoverage(view);
        if (!self.live(window)) return error.Closed;
        if (build_options.gpu and !self.gpu_unavailable and self.attached_render_mode != .gdi) try self.gpu_renderer.uploadCoverage(view);
    }
    pub fn releaseCoverage(self: *Context, identity: u64) !bool {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting) return error.Busy;
        self.cancelGpuWait();
        const software_released = try self.renderer.releaseCoverage(identity);
        if (!self.live(window)) return error.Closed;
        const gpu_released = if (build_options.gpu) try self.gpu_renderer.releaseCoverage(identity) else false;
        return software_released or gpu_released;
    }
    pub fn setRasterBudget(self: *Context, bytes: usize) !void {
        try self.setImageBudget(bytes);
    }
    pub fn coverageStats(self: *const Context) !CoverageCacheStats {
        const window = self.window orelse return error.NotAttached;
        window.app.assertOwner();
        if (!self.live(window)) return error.Closed;
        return .{ .software = self.renderer.coverageStats(), .gpu = if (build_options.gpu) self.gpu_renderer.coverageStats() else null };
    }
    pub fn rasterStats(self: *const Context) !RasterCacheStats {
        const window = self.window orelse return error.NotAttached;
        window.app.assertOwner();
        if (!self.live(window)) return error.Closed;
        return .{ .software = self.renderer.rasterStats(), .gpu = if (build_options.gpu) self.gpu_renderer.rasterStats() else null };
    }
    /// Explicitly reserve the backend's reusable dynamic storage. Ordinary
    /// static uploads do not pay for the second native image bank.
    pub fn uploadDynamicImage(self: *Context, view: drawing.ImageView) !void {
        try self.uploadImageMode(view, true);
    }
    fn uploadImageMode(self: *Context, view: drawing.ImageView, dynamic: bool) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting) return error.Busy;
        try view.validate();
        self.cancelGpuWait();
        if (dynamic) try self.renderer.uploadDynamicImage(view) else try self.renderer.uploadImage(view);
        if (!self.live(window)) return error.Closed;
        if (build_options.gpu and !self.gpu_unavailable and self.attached_render_mode != .gdi) {
            if (dynamic) try self.gpu_renderer.uploadDynamicImage(view) else try self.gpu_renderer.uploadImage(view);
        }
    }
    /// Commit one immutable version to previously reserved same-shape storage.
    /// Each backend commits independently; callers retain both views on error.
    pub fn updateImage(self: *Context, old_identity: u64, view: drawing.ImageView) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting) return error.Busy;
        try view.validate();
        self.cancelGpuWait();
        try self.renderer.updateImage(old_identity, view);
        if (!self.live(window)) return error.Closed;
        if (build_options.gpu and !self.gpu_unavailable and self.attached_render_mode != .gdi) try self.gpu_renderer.updateImage(old_identity, view);
    }
    /// Releases backend residency pins. A current Frame keeps its own pin.
    pub fn releaseImage(self: *Context, identity: u64) !bool {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting) return error.Busy;
        self.cancelGpuWait();
        const software_released = try self.renderer.releaseImage(identity);
        if (!self.live(window)) return error.Closed;
        const gpu_released = if (build_options.gpu) try self.gpu_renderer.releaseImage(identity) else false;
        return software_released or gpu_released;
    }
    pub fn setImageBudget(self: *Context, bytes: usize) !void {
        const window = self.window orelse return error.NotAttached;
        const scope = self.callbackScope(window) orelse return error.Closed;
        defer scope.end();
        if (self.painting) return error.Busy;
        if (bytes == 0 or bytes > 256 * 1024 * 1024) return error.InvalidImageBudget;
        self.cancelGpuWait();
        try self.renderer.setImageBudget(bytes);
        if (!self.live(window)) return error.Closed;
        if (build_options.gpu) try self.gpu_renderer.setImageBudget(bytes);
    }
    pub fn imageStats(self: *const Context) !ImageCacheStats {
        const window = self.window orelse return error.NotAttached;
        window.app.assertOwner();
        if (!self.live(window)) return error.Closed;
        return .{ .software = self.renderer.imageStats(), .gpu = if (build_options.gpu) self.gpu_renderer.imageStats() else null };
    }
    fn accessibilityRecipientAction(ptr: *anyopaque, window: z.Window, request: accessibility.CapturedRecipientAction) void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const pin = self.callbackScope(window) orelse return;
        defer pin.end();
        const fields = self.input_state.fields orelse return;
        if (fields.publication != request.publication) return;
        fields.requireKind(request.key, request.kind) catch return;
        if (request.action == .collection) {
            if (request.kind != .control) return;
            const accepted = fields.byId(self.input_state.hits[0..self.input_state.len], request.key.id) catch return;
            if (!std.meta.eql(accepted, request.key)) return;
            self.performCapturedCollection(window, request.key, request.action.collection) catch {};
            return;
        }
        const action = request.action.ordinary;
        const id: u64 = switch (action) {
            .set_value => |value| value.id,
            .select_text => |value| value.id,
            .set_focus => |value| value,
            .invoke => |value| value,
            .set_range => |value| value.id,
        };
        if (id != request.key.id) return;
        const accepted = fields.byId(self.input_state.hits[0..self.input_state.len], id) catch return;
        if (!std.meta.eql(accepted, request.key)) return;
        // No foreign callback occurs between this exact-key gate and the
        // entered helper capturing its pinned key. Its later checks remain
        // responsible for focus callback removal, replacement and closure.
        switch (request.kind) {
            .text => _ = self.textFieldAction(window, action),
            .control => switch (action) {
                .set_focus => self.focusRegisteredControl(.{ .context = self, .key = request.key }) catch {},
                else => {},
            },
        }
    }
    noinline fn performCapturedCollection(self: *Context, window: z.Window, key: input.text_fields.Key, request: *const accessibility.virtual_lists.authority.RowRequest) !void {
        const fields = self.input_state.fields orelse return error.StaleTextField;
        var entry: FieldEntry = undefined;
        try entry.initKind(self, window, fields, key, .control);
        defer entry.borrow.end();
        if (try request.action() == .focus) try self.focusEnteredControl(&entry);
        try FieldEntry.check(&entry);
        const callback = try entry.borrow.control();
        const result = try callback.action(callback.context, entry.scope.scope(), .{ .native_row = request });
        if (result.changed and self.live(window)) window.invalidate();
        reportFieldResult(window, .{ .handled = result.handled, .input_error = result.input_error, .presentation_error = result.presentation_error });
    }
    noinline fn publishRecipientSemantics(self: *Context) !void {
        const fields = self.input_state.fields orelse return error.TextFieldsNotPrepared;
        var keys: [accessibility.max_nodes]accessibility.RecipientAuthority = @splat(.{});
        for (self.semantic_tree.entries[0..self.semantic_tree.len], 0..) |node, index| {
            const key = fields.byId(self.input_state.hits[0..self.input_state.len], node.id) catch continue;
            keys[index] = try accessibility.RecipientAuthority.capture(key, fields.publication, try fields.kind(key));
        }
        try self.accessibility_bridge.publishRegistered(&self.semantic_tree, keys[0..self.semantic_tree.len]);
    }
    fn accessibilityAction(ptr: *anyopaque, window: z.Window, action: accessibility.Action) void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const scope = self.callbackScope(window) orelse return;
        defer scope.end();
        if (self.input_state.fields != null) if (self.textFieldAction(window, action)) return;
        if (self.on_accessibility_action) |callback| callback(self.state, self, action) else switch (action) {
            .invoke => |id| self.on_action(self.state, id),
            .set_range => |value| if (self.on_value) |callback| callback(self.state, value.id, .{ .set = value.value }),
            .set_focus => |id| self.focusControl(id) catch return,
            else => {},
        }
        window.invalidate();
    }
    fn nativeKeyInput(ptr: *anyopaque, window: z.Window, key: z.KeyInput) bool {
        const self: *Context = @ptrCast(@alignCast(ptr));
        return self.handleKeyInput(window, key);
    }
    fn nativeKeyRelease(ptr: *anyopaque, window: z.Window, key: z.KeyInput) void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const callback = self.on_key_release orelse return;
        const scope = self.callbackScope(window) orelse return;
        defer scope.end();
        if (self.painting) return;
        callback(self.state, self, key);
    }
    fn legacyKey(key: z.KeyInput) ?z.Event {
        if (key.modifiers.alt or key.modifiers.super) return null;
        const code: z.EditKeyCode = switch (key.key) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
            .home => .home,
            .end => .end,
            .backspace => .backspace,
            .delete => .delete,
            .a => if (key.modifiers.control) .a else return null,
            .c => if (key.modifiers.control) .c else return null,
            .x => if (key.modifiers.control) .x else return null,
            .v => if (key.modifiers.control) .v else return null,
            .z => if (key.modifiers.control) .z else return null,
            .y => if (key.modifiers.control) .y else return null,
            .tab => return if (key.modifiers.control) null else .{ .key = .tab },
            .enter, .space => return if (key.modifiers.control) null else .{ .key = .activate },
            else => return null,
        };
        return .{ .edit_key = .{ .key = code, .control = key.modifiers.control, .shift = key.modifiers.shift } };
    }
    /// The native callback pins this Context. A mapped legacy event is offered
    /// to on_input exactly once, then consumed even when it made no change.
    pub fn handleKeyInput(self: *Context, window: z.Window, key: z.KeyInput) bool {
        if (self.input_state.fields != null) return self.textFieldEvent(window, .{ .key_input = key });
        if (self.input_state.scopes) |workspace| if (!workspace.closed) return self.handleScopedKeyInput(window, key, workspace);
        return self.handleLegacyKeyInput(window, key);
    }
    fn handleLegacyKeyInput(self: *Context, window: z.Window, key: z.KeyInput) bool {
        const scope = self.callbackScope(window) orelse return true;
        defer scope.end();
        if (self.composing) return false;
        const input_stamp = window.textInputStamp() catch return true;
        if (self.on_input) |callback| if (callback(self.state, self, .{ .key_input = key })) {
            window.invalidate();
            return true;
        };
        if (!self.live(window) or !std.meta.eql(input_stamp, window.textInputStamp() catch return true)) return true;
        const legacy = legacyKey(key);
        if (legacy) |event_value| if (self.on_input) |callback| if (callback(self.state, self, event_value)) {
            window.invalidate();
            return true;
        };
        if (!self.live(window) or !std.meta.eql(input_stamp, window.textInputStamp() catch return true)) return true;
        return self.handleControlKey(window, key, legacy);
    }
    noinline fn handleScopedKeyInput(self: *Context, window: z.Window, key: z.KeyInput, workspace: *input.shortcut_scopes.Workspace) bool {
        workspace.retain();
        defer workspace.release();
        const scope = self.callbackScope(window) orelse return true;
        defer scope.end();
        if (workspace.key_busy) return true;
        if (self.composing) return false;
        self.controlWindowAllowed(window) catch return true;
        if (!(window.state() catch return true).focused) return true;
        if (workspace.request != null and key.key == .escape and key.repeat and std.meta.eql(key.modifiers, z.KeyModifiers{})) return true;
        workspace.request = null;
        if (!workspace.advanceRouting()) return true;
        const original_front = workspace.serial;
        const authority: input.shortcut_scopes.Authority = .{ .window = window, .installation = self.input_state.scope_epoch, .routing = workspace.routing_epoch, .text = window.textClientToken(), .mode = window.textInputStamp() catch return true, .focused = self.input_state.focused };
        workspace.key_busy = true;
        workspace.entered_key = .{ .key = key, .authority = authority };
        defer {
            workspace.key_busy = false;
            workspace.entered_key = null;
        }
        if (self.on_input) |callback| if (callback(self.state, self, .{ .key_input = key })) {
            workspace.request = null;
            window.invalidate();
            return true;
        };
        if (!self.shortcutAuthorityCurrent(workspace, authority) or (workspace.serial != original_front and workspace.request == null)) {
            workspace.request = null;
            return true;
        }
        const legacy = legacyKey(key);
        if (legacy) |event_value| if (self.on_input) |callback| if (callback(self.state, self, event_value)) {
            workspace.request = null;
            window.invalidate();
            return true;
        };
        if (!self.shortcutAuthorityCurrent(workspace, authority) or (workspace.serial != original_front and workspace.request == null)) {
            workspace.request = null;
            return true;
        }
        if (workspace.request != null) {
            window.invalidate();
            return true;
        }
        return self.handleControlKey(window, key, legacy);
    }
    fn applyKeyboardRecipientFocus(self: *Context, window: z.Window, before: ?u64) bool {
        const next = self.input_state.focused;
        self.input_state.setFocused(before);
        (if (next) |id| self.focusControl(id) else self.blurControls()) catch |err| {
            reportFieldResult(window, .{ .input_error = err });
            return false;
        };
        return self.live(window);
    }
    fn handleControlKey(self: *Context, window: z.Window, key: z.KeyInput, legacy: ?z.Event) bool {
        self.controlWindowAllowed(window) catch return true;
        const before_focus = self.input_state.focused;
        if (self.input_state.matchShortcut(key)) |id| {
            if (self.input_state.get(id).?.options.range != null) {
                self.controlsAllowed(window) catch return false;
                if (self.input_state.fields != null) {
                    self.focusControl(id) catch |err| {
                        reportFieldResult(window, .{ .input_error = err });
                        return true;
                    };
                } else self.input_state.setFocused(id);
            } else self.on_action(self.state, id);
            window.invalidate();
            return true;
        }
        self.controlsAllowed(window) catch {
            self.input_state.setFocused(null);
            self.input_state.cancelPress();
            return false;
        };
        if (key.key == .tab and !key.modifiers.control and !key.modifiers.alt and !key.modifiers.super) {
            self.input_state.tabDirection(key.modifiers.shift);
            if (self.input_state.fields != null and !self.applyKeyboardRecipientFocus(window, before_focus)) return true;
            window.invalidate();
            return true;
        }
        if (self.input_state.rangeKey(key)) |action| {
            if (self.on_value) |callback| callback(self.state, action.id, action.change);
            window.invalidate();
            return true;
        }
        if (legacy) |event_value| if (event_value == .edit_key) {
            if (self.input_state.navigate(event_value.edit_key)) |id| {
                if (self.input_state.fields != null and !self.applyKeyboardRecipientFocus(window, before_focus)) return true;
                self.on_action(self.state, id);
                window.invalidate();
                return true;
            }
        };
        if (!key.modifiers.control and !key.modifiers.alt and !key.modifiers.super and !key.modifiers.shift) {
            if (self.input_state.spatial(key.key)) {
                if (self.input_state.fields != null and !self.applyKeyboardRecipientFocus(window, before_focus)) return true;
                window.invalidate();
                return true;
            }
            if (key.key == .home or key.key == .end) {
                self.input_state.setFocused(null);
                self.input_state.tabDirection(key.key == .end);
                if (self.input_state.fields != null and !self.applyKeyboardRecipientFocus(window, before_focus)) return true;
                window.invalidate();
                return true;
            }
            if (key.key == .enter or key.key == .space) {
                if (!key.repeat) if (self.input_state.activation()) |id| self.on_action(self.state, id);
                window.invalidate();
                return true;
            }
        }
        return legacy != null;
    }
    pub fn hasSurface(self: *const Context) bool {
        if (build_options.gpu) if (self.gpu_renderer.native != null) return true;
        return self.renderer.hasSurface();
    }
    fn commitFrame(self: *Context, window: z.Window) void {
        if (self.transforms) |workspace| self.space_generation = workspace.state.commitFrame() catch unreachable;
        if (self.input_state.fields != null) self.commitRegisteredRecipientFrame(window) else self.input_state.commitFrame();
        if (!self.live(window)) return;
        if (self.input_state.fields) |fields| if (window.textClientToken()) |token| {
            var retained = false;
            if (self.input_state.focused) |id| if (fields.byId(self.input_state.hits[0..self.input_state.len], id)) |key| {
                retained = fields.matchesToken(key, token);
            } else |_| {};
            if (!retained) self.blurTextField(window) catch {};
        };
        if (!self.live(window)) return;
        if (self.input_state.scopes) |workspace| if (workspace.request) |*request| {
            if (request.state == .waiting) {
                if (workspace.frame_request == request.id) {
                    request.state = .ready;
                    request.target = workspace.serial;
                } else workspace.request = null;
            }
        };
        self.accessibility_source_state.commitFrame(self.frame_accessibility_source);
        if (build_options.accessibility and self.attached_semantics_enabled) (if (self.input_state.fields != null) self.publishRecipientSemantics() else self.accessibility_bridge.publish(&self.semantic_tree)) catch |err| {
            window.report(.{ .domain = .core, .operation = .paint, .err = err });
        };
        if (self.live(window) and self.frame_accessibility_source != null and self.frame_accessibility_source == self.accessibility_source_state.currentGeneration()) _ = self.accessibilityPhase(window, .committed);
    }
    noinline fn commitRegisteredRecipientFrame(self: *Context, window: z.Window) void {
        const fields = self.input_state.fields orelse unreachable;
        var old_control: ?input.text_fields.Borrow = null;
        if (self.input_state.focused) |id| {
            const key = fields.byId(self.input_state.hits[0..self.input_state.len], id) catch null;
            if (key) |current| if ((fields.kind(current) catch .text) == .control) {
                old_control = fields.borrow(current) catch null;
            };
        }
        defer if (old_control) |*borrow| borrow.end();
        self.input_state.commitFrame();
        if (old_control) |*borrow| {
            const key = fields.byId(self.input_state.hits[0..self.input_state.len], borrow.key.id) catch null;
            const retained = self.input_state.focused == borrow.key.id and key != null and std.meta.eql(key.?, borrow.key);
            if (!retained) if (borrow.control() catch null) |callback| callback.blur(callback.context, window) catch |err| reportFieldResult(window, .{ .input_error = err });
        }
    }
    fn software(self: *Context, paint: z.Paint) !void {
        try self.renderer.begin(paint);
        errdefer self.renderer.abort();
        try self.renderer.replayBuffer(&self.command_buffer);
        const restore_gpu = if (build_options.gpu) self.gpu_renderer.suspendSurface() else false;
        errdefer if (build_options.gpu and restore_gpu) self.gpu_renderer.restoreSurface();
        try self.renderer.endChecked(paint);
        self.gdi_frames += 1;
    }
    fn cancelGpuWait(self: *Context) void {
        if (self.gpu_wait) |token| {
            if (self.window) |window| _ = window.app.unwatchNative(token);
            self.gpu_wait = null;
        }
    }
    fn gpuReady(ptr: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        self.gpu_wait = null;
        const window = self.window orelse return;
        const scope = self.callbackScope(window) orelse return;
        defer scope.end();
        window.invalidate();
    }
    fn deferPresent(self: *Context, window: z.Window) bool {
        if (build_options.gpu) {
            const handle = self.gpu_renderer.frameReadyHandle() orelse return false;
            self.gpu_wait = window.app.watchNative(handle, .{ .context = self, .call = gpuReady }) catch |err| {
                window.report(.{ .domain = .core, .operation = .paint, .err = err });
                return false;
            };
            self.deferred_frames += 1;
            return true;
        }
        return false;
    }
    fn gpuFailure(self: *Context, window: z.Window, err: anyerror) void {
        if (build_options.gpu) {
            self.fallbacks += 1;
            // Keep the accepted GPU front until a software end succeeds.
            // Device/domain validation failure cannot be repaired by readback.
            self.gpu_renderer.discard();
            const native_error = err == error.DeviceLost or err == error.GraphicsFailed or err == error.PresentationBusy;
            window.report(.{ .severity = .warning, .domain = if (native_error) .hresult else .renderer, .operation = .paint, .err = err, .code = if (native_error) @bitCast(self.gpu_renderer.last_hresult) else null });
        }
    }

    fn clickEntryCurrent(self: *const Context, workspace: *const input.pointer_clicks.Workspace, window: z.Window, installation: u64, registration: u64, routing: u64, closed: bool, guard: ?input.pointer_clicks.kernel.Guard) bool {
        if (workspace.state.installation != installation or workspace.state.registration != registration or workspace.state.routing != routing or workspace.state.closed != closed) return false;
        if (guard) |value| if (!workspace.current(value)) return false;
        return self.live(window) and self.input_state.clicks == workspace;
    }
    /// Closed entry: only this captured Context event can construct a guard.
    /// Never reload/transfer to a newly installed workspace after preprocessing.
    noinline fn pointerClickEvent(self: *Context, workspace: *input.pointer_clicks.Workspace, window: z.Window, ev: z.Event, preprocessed: bool) void {
        if (!workspace.retain()) return;
        defer workspace.release();
        const scope = self.callbackScope(window) orelse return;
        defer scope.end();
        var guard: ?input.pointer_clicks.kernel.Guard = null;
        const position: z.Point = switch (ev) {
            .pointer_down, .pointer_up => |value| value.position,
            .pointer_move => |value| value,
            else => unreachable,
        };
        const raw: ?z.PointerPressSnapshot = switch (ev) {
            .pointer_down => |value| window.pointerPressSnapshot(value.press, .down) catch null,
            .pointer_up => |value| window.pointerPressSnapshot(value.press, .up) catch null,
            else => null,
        };
        const route_point: input.pointer_clicks.kernel.Point = .{ .x = position.x, .y = position.y };
        switch (ev) {
            .pointer_down => |value| {
                workspace.last_up = .{};
                const valid = raw != null and raw.?.button == value.button;
                guard = workspace.state.beginDown(.{ .sequence = if (valid) value.press.sequence else 0, .previous_completed_sequence = if (valid) raw.?.previous_completed_sequence else 0, .timing = if (valid) raw.?.timing else null, .point = route_point, .button = @intFromEnum(value.button) }) catch null;
            },
            .pointer_up => |value| {
                const valid = raw != null and raw.?.button == value.button;
                guard = workspace.state.beginUp(.{ .sequence = if (valid) value.press.sequence else 0, .point = route_point, .button = @intFromEnum(value.button) }) catch null;
            },
            else => {},
        }
        defer if (guard) |value| workspace.state.finish(value);
        const installation = workspace.state.installation;
        const registration_generation = workspace.state.registration;
        const routing = workspace.state.routing;
        const closed = workspace.state.closed;
        const registration = if (!closed) workspace.registration else null;
        const consumed = if (preprocessed) false else if (registration) |value| (if (value.on_input) |callback| callback(value.context, self, ev) else false) else (if (self.on_input) |callback| callback(self.state, self, ev) else false);
        if (consumed) {
            window.invalidate();
            return;
        }
        if (!self.clickEntryCurrent(workspace, window, installation, registration_generation, routing, closed, guard)) return;
        self.controlsAllowed(window) catch {
            self.input_state.cancelPress();
            if (ev == .pointer_down) self.input_state.setFocused(null);
            return;
        };
        if (!self.clickEntryCurrent(workspace, window, installation, registration_generation, routing, closed, guard)) return;
        switch (ev) {
            .pointer_down => |value| {
                const index = self.input_state.hitControlIndex(position);
                const mark = if (index) |i| workspace.state.mark(i) catch return else 0;
                if (mark != 0) {
                    const i = index.?;
                    const item = self.input_state.hits[i];
                    if (guard == null or raw == null or value.button != .primary or raw.?.button != value.button) {
                        self.input_state.cancelPress();
                        return;
                    }
                    // Preprocessing can supersede native ingress without a
                    // second Content callback. Validate before changing focus
                    // or claiming this registered target.
                    const current = window.pointerPressSnapshot(value.press, .down) catch {
                        self.input_state.cancelPress();
                        return;
                    };
                    if (current.button != value.button or !self.clickEntryCurrent(workspace, window, installation, registration_generation, routing, closed, guard)) {
                        self.input_state.cancelPress();
                        return;
                    }
                    // Use Input's own eligibility/occlusion decision, then
                    // reserve the old entry before any focus/active mutation.
                    if (self.input_state.hit(position) != item.id) {
                        self.input_state.cancelPress();
                        return;
                    }
                    const target = workspace.state.bound(i, item.id) orelse {
                        self.input_state.cancelPress();
                        return;
                    };
                    _ = workspace.state.claim(guard.?, target) catch {
                        self.input_state.cancelPress();
                        return;
                    };
                }
                // Input.down/setFocused only mutate owned bounded tables;
                // neither performs foreign callbacks or native operations.
                self.input_state.down(position);
                if (self.input_state.pointerValue(position, .down)) |action| if (self.on_value) |callback| callback(self.state, action.id, action.change);
            },
            .pointer_move => {
                if (self.input_state.pointerValue(position, .move)) |action| if (self.on_value) |callback| callback(self.state, action.id, action.change);
            },
            .pointer_up => |value| {
                if (self.input_state.pointerValue(position, .up)) |action| {
                    if (self.on_value) |callback| callback(self.state, action.id, action.change);
                } else if (self.input_state.up(position)) |id| {
                    const index = self.input_state.hitControlIndex(position) orelse return;
                    const mark = workspace.state.mark(index) catch return;
                    if (mark == 0) {
                        self.on_action(self.state, id);
                    } else {
                        const current_guard = guard orelse return;
                        if (raw == null or raw.?.button != value.button or value.button != .primary) return;
                        const target = workspace.state.bound(index, id) orelse return;
                        const completion = workspace.state.takeUp(current_guard, target) catch return;
                        const callback = registration orelse return;
                        const before = window.pointerPressSnapshot(value.press, .up) catch return;
                        if (before.button != value.button or !self.clickEntryCurrent(workspace, window, installation, registration_generation, routing, closed, guard)) return;
                        const outcome = callback.on_click(callback.context, window, .{ .id = id, .count = completion.click.count, .button = value.button, .press = value.press, .position = position });
                        if (!self.clickEntryCurrent(workspace, window, installation, registration_generation, routing, closed, guard)) return;
                        self.controlsAllowed(window) catch return;
                        const after = window.pointerPressSnapshot(value.press, .up) catch return;
                        if (after.button != value.button or !self.clickEntryCurrent(workspace, window, installation, registration_generation, routing, closed, guard)) return;
                        if (workspace.state.complete(completion, .{ .accepted = outcome == .accepted, .authorized = true, .eligible = after.continuation_eligible })) workspace.last_up = value.press;
                    }
                }
            },
            else => unreachable,
        }
        window.invalidate();
    }

    noinline fn pointerClickLifecycle(workspace: *input.pointer_clicks.Workspace, window: z.Window, ev: z.Event) void {
        switch (ev) {
            .focus => |focused| if (!focused) workspace.revoke(),
            .cancel_input => {
                const previous = workspace.last_up;
                const snapshot = if (previous.sequence != 0) window.pointerPressSnapshot(previous, .up) catch null else null;
                if (snapshot != null and snapshot.?.button == .primary) workspace.state.cancel(previous.sequence) else workspace.revoke();
            },
            .window_position, .resize, .window_state, .text_input, .text_preedit, .text_preedit_cancel, .text_preedit_revoked => workspace.revoke(),
            else => {},
        }
    }
    fn event(ptr: *anyopaque, window: z.Window, ev: z.Event) void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        if (self.input_state.clicks) |workspace| pointerClickLifecycle(workspace, window, ev);
        if (self.input_state.scopes) |workspace| switch (ev) {
            .focus, .cancel_input, .text_preedit, .text_preedit_cancel, .text_preedit_revoked, .text_input, .pointer_down, .window_state, .resize => {
                workspace.request = null;
                _ = workspace.advanceRouting();
            },
            else => {},
        };
        switch (ev) {
            .text_preedit => self.composing = true,
            .text_preedit_cancel, .text_preedit_revoked, .text_input => self.composing = false,
            .focus => |focused| if (!focused) {
                self.composing = false;
                self.input_state.cancelPress();
            },
            .cancel_input => self.input_state.cancelPress(),
            .window_position => self.accessibilityPositionChanged(window),
            else => {},
        }
        // The old TextClient has already lost ingress. Its unbound callback
        // owns document cleanup; forwarding this notification would reenter a
        // busy or stale business owner during an otherwise valid handoff.
        if (ev == .text_preedit_revoked) return;
        if (ev == .window_position and !self.live(window)) return;
        if (self.input_state.fields != null and ev != .paint) {
            _ = self.textFieldEvent(window, ev);
            return;
        }
        self.eventDefault(window, ev, false);
    }
    fn eventDefault(self: *Context, window: z.Window, ev: z.Event, preprocessed: bool) void {
        if (ev != .paint) {
            if (self.input_state.clicks) |workspace| switch (ev) {
                .pointer_down, .pointer_up, .pointer_move => return self.pointerClickEvent(workspace, window, ev, preprocessed),
                else => {},
            };
            if (!preprocessed) if (self.on_input) |callback| {
                const stamp: ?z.TextInputStamp = window.textInputStamp() catch null;
                if (callback(self.state, self, ev)) {
                    window.invalidate();
                    return;
                }
                if (stamp) |before| switch (ev) {
                    .text_input, .text_preedit, .key_input, .edit_key, .key => if (!std.meta.eql(before, window.textInputStamp() catch return)) return,
                    else => {},
                };
            };
        }
        if (!self.live(window)) return;
        switch (ev) {
            .paint => |paint| {
                if (self.painting or (build_options.gpu and self.gpu_renderer.interpolation_mutating)) {
                    self.repaint_pending = true;
                    return;
                }
                self.painting = true;
                self.frame_accessibility_source = null;
                defer {
                    if (self.input_state.scopes != null) self.finishShortcutAttempt();
                    self.renderer.abort();
                    self.painting = false;
                    self.frame_accessibility_source = null;
                    const repaint = self.repaint_pending;
                    self.repaint_pending = false;
                    if (repaint and self.window != null and self.live(window)) window.invalidate();
                    if (self.input_state.scopes != null) self.postShortcutContinuation(window);
                }
                if (paint.size.width == 0 or paint.size.height == 0) return;
                if (self.gpu_wait != null) if (self.last_paint_size) |previous| {
                    if (previous.width == paint.size.width and previous.height == paint.size.height and previous.scale == paint.size.scale) {
                        self.deferred_frames += 1;
                        return;
                    }
                };
                self.cancelGpuWait();
                self.last_paint_size = paint.size;
                if (self.input_state.scopes != null) self.beginShortcutAttempt();
                var using_gpu = false;
                if (build_options.gpu and !self.gpu_unavailable and self.attached_render_mode != .gdi) {
                    if (self.gpu_renderer.begin(paint)) {
                        using_gpu = true;
                    } else |err| self.gpuFailure(window, err);
                }
                defer if (build_options.gpu and self.gpu_renderer.active) self.gpu_renderer.discard();
                if (!self.live(window)) return;
                if (!using_gpu) self.renderer.begin(paint) catch |err| {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                    return;
                };
                self.command_buffer.reset();
                defer self.command_buffer.reset();
                var clock = frame_stats.Clock.begin(self.frame_stats_options.enabled);
                defer frame_stats.finish(&self.frame_stats_totals, self.frame_stats_options, &clock, self.command_buffer.len);
                self.command_buffer.backdrop_storage.workspace = self.backdrop_workspace;
                self.command_buffer.shader_storage.workspace = self.shader_workspace;
                if (self.gaussian_workspace) |workspace| self.command_buffer.bindFilterStorage(&workspace.storage) catch |err| {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                    return;
                };
                const transform_workspace = self.transforms;
                if (transform_workspace) |workspace| {
                    const generation = std.math.add(u64, self.space_generation, 1) catch {
                        window.report(.{ .domain = .renderer, .operation = .paint, .err = error.GenerationExhausted });
                        return;
                    };
                    workspace.begin(paint.size, generation) catch |err| {
                        window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                        return;
                    };
                    self.command_buffer.bindTransformStorage(&workspace.command_storage) catch |err| {
                        workspace.state.cancelFrame();
                        window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                        return;
                    };
                    self.input_state.beginMappedFrame(workspace.state.pending() catch unreachable);
                } else self.input_state.beginFrame();
                defer if (transform_workspace) |workspace| workspace.state.cancelFrame();
                defer if (self.input_state.building) self.input_state.cancelFrame();
                if (build_options.accessibility and self.attached_semantics_enabled and self.input_state.fields != null) self.accessibility_bridge.beginVirtualListsFrame() catch |err| {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                    return;
                };
                if (build_options.accessibility and self.attached_semantics_enabled) self.semantic_tree.reset(self.semantic_name_storage[0..self.semantic_name_len], .{ .x = 0, .y = 0, .width = @as(f32, @floatFromInt(paint.size.width)) / paint.size.scale, .height = @as(f32, @floatFromInt(paint.size.height)) / paint.size.scale }) catch |err| {
                    window.report(.{ .domain = .core, .operation = .paint, .err = err });
                    return;
                };
                if (build_options.accessibility and self.attached_semantics_enabled) if (transform_workspace) |workspace| {
                    const snapshot = workspace.state.pending() catch unreachable;
                    snapshot.addSemantic(.{}, .{ .width = @as(f64, @floatFromInt(paint.size.width)) / paint.size.scale, .height = @as(f64, @floatFromInt(paint.size.height)) / paint.size.scale }) catch |err| {
                        window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                        return;
                    };
                    self.semantic_tree.mapped = snapshot;
                };
                var frame: Frame = .{ .context = self, .size = paint.size, .transforms = transform_workspace };
                self.frame_accessibility_source = self.accessibility_source_state.currentGeneration();
                self.accessibility_source_state.beginFrame() catch |err| {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                    return;
                };
                if (!self.accessibilityPhase(window, .frame_begin)) return;
                self.draw(self.state, &frame);
                if (!self.live(window)) return;
                if (frame.failure) |err| {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                    return;
                }
                self.command_buffer.finish() catch |err| {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                    return;
                };
                clock.markBuild();
                const layer_options = if (build_options.gpu and using_gpu) self.gpu_renderer.layerOptions() else self.renderer.layerOptions();
                const transform_options = if (build_options.gpu and using_gpu) self.gpu_renderer.transformOptions() else self.renderer.transformOptions();
                const transform_plan: ?layers.Plan = if (transform_options) |value| layers.Plan.initTransforms(value, if (build_options.gpu and using_gpu) .gpu else if (builtin.os.tag == .linux) .cairo else .gdi) catch |err| {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                    return;
                } else null;
                const filters = self.command_buffer.filterResources();
                const preflight = if (filters.len != 0) self.preflightGaussianFrame(paint.size, using_gpu) else commands.preflightScopes(self.command_buffer.commands(), if (layer_options) |value| value.max_depth else 0, paint.size.scale, self.command_buffer.coverageResources(), if (layer_options) |value| value.legacy_text == .grayscale else true, transform_plan, self.command_buffer.transformResources());
                preflight catch |err| {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                    return;
                };
                if (frame.offset_depth != 0) {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = error.UnbalancedOffsets });
                    return;
                }
                self.input_state.validateFrame() catch |err| {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                    return;
                };
                if (build_options.accessibility and self.attached_semantics_enabled and self.input_state.fields != null) self.accessibility_bridge.validateVirtualListsFrame() catch |err| {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                    return;
                };
                if (if (transform_workspace) |workspace| workspace.depth != 0 else false) {
                    window.report(.{ .domain = .renderer, .operation = .paint, .err = error.InvalidTransformFrame });
                    return;
                }
                if (build_options.accessibility and self.attached_semantics_enabled) if (self.semantic_tree.mapped) |snapshot| {
                    if (snapshot.semantic_len != self.semantic_tree.len) {
                        window.report(.{ .domain = .renderer, .operation = .paint, .err = error.InvalidSemanticGeometry });
                        return;
                    }
                    // Identity clips/offsets already have exact AABB semantics.
                    // Keep normal UIA publish free of geometry serialization.
                    if (snapshot.scope_count == 0 and !self.accessibility_bridge.virtualListsPrepared()) self.semantic_tree.mapped = null;
                };
                if (filters.len == 0) if (transform_workspace) |workspace| if (workspace.options) |options| {
                    const plan = transform_plan orelse {
                        window.report(.{ .domain = .renderer, .operation = .paint, .err = error.TransformsRequired });
                        return;
                    };
                    _ = @import("render_batch.zig").preflight(&self.command_buffer, .{ .size = paint.size, .max_depth = plan.options.max_depth, .legacy_text = plan.options.legacy_text, .render_work = options.render_work, .transform_plan = plan, .texture_domain = if (build_options.gpu and using_gpu) (if (self.gpu_renderer.domain_borrow) |borrow| borrow.epoch else null) else null }) catch |err| {
                        window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                        return;
                    };
                };
                if (!self.live(window)) return;
                clock.markPreflight();
                clock.software = !using_gpu;
                // Backdrop effects and loading indicators draw on the software
                // planes: replay this frame there without reporting a device
                // failure.
                if (build_options.gpu and using_gpu and commands.softwareOnly(self.command_buffer.commands())) {
                    self.gpu_renderer.discard();
                    using_gpu = false;
                    clock.software = true;
                    self.backdrop_software_frames += 1;
                }
                if (build_options.gpu and using_gpu) {
                    const rendered = if (self.gpu_renderer.replayBuffer(&self.command_buffer)) rendered: {
                        if (self.gpu_renderer.end()) break :rendered true else |err| {
                            if (err == error.PresentationBusy and self.deferPresent(window)) {
                                self.frames += 1;
                                return;
                            }
                            self.gpuFailure(window, err);
                        }
                        break :rendered false;
                    } else |err| rendered: {
                        self.gpuFailure(window, err);
                        break :rendered false;
                    };
                    if (rendered) {
                        self.commitFrame(window);
                        self.gpu_frames += 1;
                        self.frames += 1;
                        return;
                    }
                }
                if (self.live(window)) {
                    if (self.software(paint)) self.commitFrame(window) else |err| window.report(.{ .domain = .renderer, .operation = .paint, .err = err });
                }
                self.frames += 1;
            },
            .pointer_down => |pointer| {
                const point = pointer.position;
                self.controlsAllowed(window) catch {
                    self.input_state.cancelPress();
                    self.input_state.setFocused(null);
                    return;
                };
                self.input_state.down(point);
                if (self.input_state.pointerValue(point, .down)) |action| if (self.on_value) |callback| callback(self.state, action.id, action.change);
                window.invalidate();
            },
            .pointer_move => |point| {
                self.controlsAllowed(window) catch {
                    self.input_state.cancelPress();
                    return;
                };
                if (self.input_state.pointerValue(point, .move)) |action| {
                    if (self.on_value) |callback| callback(self.state, action.id, action.change);
                    window.invalidate();
                }
            },
            .pointer_up => |pointer| {
                const point = pointer.position;
                self.controlsAllowed(window) catch {
                    self.input_state.cancelPress();
                    return;
                };
                if (self.input_state.pointerValue(point, .up)) |action| {
                    if (self.on_value) |callback| callback(self.state, action.id, action.change);
                } else if (self.input_state.up(point)) |id| self.on_action(self.state, id);
                window.invalidate();
            },
            .cancel_input => {
                window.invalidate();
            },
            .key => |key| {
                self.controlsAllowed(window) catch return;
                switch (key) {
                    .tab => self.input_state.tab(),
                    .activate => if (self.input_state.activation()) |id| self.on_action(self.state, id),
                }
                window.invalidate();
            },
            .edit_key => |key| {
                self.controlsAllowed(window) catch return;
                if (self.input_state.navigate(key)) |id| {
                    self.on_action(self.state, id);
                    window.invalidate();
                }
            },
            .resize => window.invalidate(),
            .window_state => |state| {
                const changed = self.last_enabled != null and self.last_enabled.? != state.enabled;
                self.last_enabled = state.enabled;
                if (changed) window.invalidate();
            },
            else => {},
        }
    }

    fn detach(ptr: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        self.attachment_phase = .detaching;
        const text_fields = self.input_state.fields;
        self.input_state.fields = null;
        if (text_fields) |fields| fields.close();
        const click_workspace = self.input_state.clicks;
        self.input_state.clicks = null;
        if (click_workspace) |workspace| workspace.close();
        const click_epoch = if (click_workspace) |workspace| @max(self.input_state.click_epoch, workspace.state.installation) else self.input_state.click_epoch;
        const shortcut_workspace = self.input_state.scopes;
        if (shortcut_workspace) |workspace| workspace.close();
        const shortcut_epoch = self.input_state.scope_epoch +| 1;
        self.accessibility_source_state.close();
        self.backdrop_region = null;
        self.cancelGpuWait();
        self.command_buffer.reset();
        if (build_options.accessibility and self.attached_semantics_enabled) self.accessibility_bridge.detach();
        self.attached_semantics_enabled = false;
        self.renderer.deinit();
        if (build_options.gpu) self.gpu_renderer.deinit();
        self.window = null;
        self.last_paint_size = null;
        self.input_state = .{ .scope_epoch = shortcut_epoch, .click_epoch = click_epoch };
        self.dropTransformMetadata();
        if (self.backdrop_workspace) |workspace| {
            self.backdrop_workspace = null;
            workspace.destroy();
        }
        if (self.shader_workspace) |workspace| {
            self.shader_workspace = null;
            workspace.destroy();
        }
        self.painting = false;
        self.dropGaussianMetadata();
        self.frame_accessibility_source = null;
        self.repaint_pending = false;
        self.composing = false;
        self.last_enabled = null;
        self.attachment_phase = .detached;
        if (shortcut_workspace) |workspace| workspace.release();
        if (click_workspace) |workspace| workspace.release();
        if (text_fields) |fields| fields.release();
    }
};

/// One local rectangle's exact candidate geometry. This value owns no Context
/// lifetime and authorizes no input. Its stamp is checked only while publishing
/// the matching successful front under the existing Context callback pin.
pub const CoordinateMapping = struct {
    space: affine.Space,
    visible: affine.Polygon,
    context: *Context,
    window: z.Window,
    region: ?z.composition.Region,
    source: u64,
    candidate: u64,
    epoch: u64,
    space_generation: ?u64,

    pub fn checkCommitted(self: *const CoordinateMapping, context: *Context) !void {
        if (context != self.context) return error.ForeignFrame;
        if (self.window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.window.app.phase == .stopping or self.window.app.phase == .stopped) return error.Closed;
        if (context.window == null or !std.meta.eql(context.window.?, self.window) or !context.live(self.window)) return error.Closed;
        if (!context.painting or !std.meta.eql(context.backdrop_region, self.region) or context.space_binding_epoch != self.epoch or !context.accessibility_source_state.isCommittedFrame(self.source, self.candidate)) return error.StaleGeometry;
        if (self.space_generation) |generation| if (context.transforms == null or context.space_generation != generation) return error.StaleGeometry;
    }
};

pub const Frame = struct {
    context: *Context,
    size: z.Size,
    failure: ?anyerror = null,
    offset: layout.Point = .{},
    offsets: [32]layout.Point = undefined,
    offset_depth: usize = 0,
    clips: layout.ClipStack(32) = .{},
    group_depth: usize = 0,
    group_clip_base: [layers.max_depth]usize = undefined,
    group_bounds: [layers.max_depth]Rect = undefined,
    group_geometry_passthrough: u8 = 0,
    transforms: ?*TransformWorkspace = null,
    /// Open element effects; false marks one drawn without its program.
    effect_scopes: [16]bool = undefined,
    effect_depth: usize = 0,

    pub fn beginShortcutScope(self: *Frame, id: u64, options: ShortcutScopeOptions) !void {
        errdefer |err| self.failure = self.failure orelse err;
        if (!self.context.input_state.building) return error.NoFrame;
        const workspace = self.context.input_state.scopes orelse return error.ShortcutScopesNotPrepared;
        try workspace.beginScope(id, options);
    }
    pub fn endShortcutScope(self: *Frame) !void {
        errdefer |err| self.failure = self.failure orelse err;
        if (!self.context.input_state.building) return error.NoFrame;
        const workspace = self.context.input_state.scopes orelse return error.ShortcutScopesNotPrepared;
        try workspace.endScope();
    }
    /// Attribute this candidate to the explicit preparation of one consumed
    /// Escape. This publishes no authority and never invokes business code.
    pub fn acceptShortcutRequest(self: *Frame, token: ShortcutRequestToken) !void {
        errdefer |err| self.failure = self.failure orelse err;
        const context = self.context;
        if (!context.input_state.building) return error.NoFrame;
        const workspace = context.input_state.scopes orelse return error.ShortcutScopesNotPrepared;
        const request = workspace.request orelse return error.StaleShortcutRequest;
        if (token.context != context or token.epoch != context.input_state.scope_epoch or !std.meta.eql(@as(?z.Window, token.window), context.window) or token.id != request.id or request.state != .waiting or !context.shortcutAuthorityCurrent(workspace, request.authority)) return error.StaleShortcutRequest;
        workspace.frame_request = token.id;
    }

    pub fn currentTheme(self: *const Frame) Theme {
        return self.context.currentTheme();
    }
    pub fn windowSize(self: *const Frame) z.Size {
        return if (self.transforms) |workspace| workspace.window_size else self.size;
    }
    /// The current raster source clips child drawing in local DIP. Its extent
    /// is explicit and need not equal the window or its transformed AABB.
    pub fn sourceBounds(self: *const Frame) Rect {
        return if (self.transforms) |workspace| workspace.source_bounds orelse .{ .x = 0, .y = 0, .width = @as(f32, @floatFromInt(self.size.width)) / self.size.scale, .height = @as(f32, @floatFromInt(self.size.height)) / self.size.scale } else .{ .x = 0, .y = 0, .width = @as(f32, @floatFromInt(self.size.width)) / self.size.scale, .height = @as(f32, @floatFromInt(self.size.height)) / self.size.scale };
    }
    const CoordinateAuthority = struct { window: z.Window, source: u64, candidate: u64, snapshot: ?*affine_state.Snapshot };
    fn coordinateAuthority(self: *const Frame) !CoordinateAuthority {
        if (self.failure) |err| return err;
        const context = self.context;
        const window = context.window orelse return error.Closed;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (window.app.phase == .stopping or window.app.phase == .stopped) return error.Closed;
        if (!context.live(window)) return error.Closed;
        if (!context.painting) return error.NoFrame;
        const source = context.frame_accessibility_source orelse return error.NotAttached;
        if (context.accessibility_source_state.currentGeneration() != source) return error.StaleGeometry;
        const candidate = context.accessibility_source_state.frame_candidate;
        if (candidate == 0) return error.NoFrame;
        if (self.transforms != context.transforms) return error.StaleGeometry;
        const snapshot = if (self.transforms) |workspace| try workspace.state.pending() else null;
        if (snapshot) |value| {
            const generation = std.math.add(u64, context.space_generation, 1) catch return error.StaleGeometry;
            if (value.generation != generation) return error.StaleGeometry;
        }
        return .{ .window = window, .source = source, .candidate = candidate, .snapshot = snapshot };
    }
    /// No allocation, native query, table append, or partially written output.
    /// The visible polygon includes the raster source, all parent clips and the
    /// window. Copy it at the same scope where this local rectangle is drawn.
    pub fn coordinateMapping(self: *const Frame, bounds: Rect, output: *CoordinateMapping) !void {
        const authority = try self.coordinateAuthority();
        const context = self.context;
        const local = affine.Rect.from(bounds);
        try local.validate();
        const translation = try affine.Affine.translation(affine.Point.from(self.offset));
        var space: affine.Space = undefined;
        var visible: affine.Polygon = .{};
        var generation: ?u64 = null;
        if (self.transforms) |workspace| {
            const snapshot = authority.snapshot.?;
            space = try (try snapshot.geometry.getSpace(workspace.reference.space)).child(translation);
            try snapshot.geometry.visiblePolygon(workspace.reference, affine.Rect.from(self.absolute(bounds)), &visible);
            generation = snapshot.generation;
        } else {
            space = try affine.Space.init(translation);
            var table: affine.GeometryTable(1, 1) = .{};
            const clip = layout.intersect(self.clipBounds() orelse self.sourceBounds(), self.sourceBounds());
            const clip_id = try table.addClip(.identity, null, affine.Rect.from(clip));
            try table.visiblePolygon(.{ .clip = clip_id }, affine.Rect.from(self.absolute(bounds)), &visible);
        }
        const window_size = self.windowSize();
        try visible.clipBounds(.{ .width = @as(f64, @floatFromInt(window_size.width)) / window_size.scale, .height = @as(f64, @floatFromInt(window_size.height)) / window_size.scale }, &visible);
        if (visible.bounds() == null) visible.len = 0;
        output.* = .{ .space = space, .visible = visible, .context = context, .window = authority.window, .region = context.backdrop_region, .source = authority.source, .candidate = authority.candidate, .epoch = context.space_binding_epoch, .space_generation = generation };
    }
    /// Read actual mapped semantic descriptors in this Frame's local domain.
    /// Equal Ref values permit exact offset rebasing, not a recording-offset
    /// identity assumption. No clipped AABB is inverted and no table is appended.
    /// A batch accepts at most 128 ids. Any error leaves all output unchanged;
    /// success writes only output[0..ids.len]. Empty batches still validate the
    /// same frame/Tree authority; repeated ids repeat the corresponding bounds.
    pub fn semanticLocalBounds(self: *const Frame, ids: []const u64, output: []Rect) !void {
        const authority = try self.coordinateAuthority();
        if (build_options.accessibility) {
            if (self.context.attached_semantics_enabled) return self.semanticLocalBoundsChecked(authority, &self.context.semantic_tree, ids, output);
        }
        return error.SemanticGeometryRequired;
    }
    fn semanticLocalBoundsFrom(self: *const Frame, tree: *const accessibility.Tree, ids: []const u64, output: []Rect) !void {
        const authority = try self.coordinateAuthority();
        return self.semanticLocalBoundsChecked(authority, tree, ids, output);
    }
    fn semanticLocalBoundsChecked(self: *const Frame, authority: CoordinateAuthority, tree: *const accessibility.Tree, ids: []const u64, output: []Rect) !void {
        if (ids.len > accessibility.max_nodes or output.len < ids.len) return error.SemanticExportCapacityExceeded;
        const snapshot = authority.snapshot orelse return error.SemanticGeometryRequired;
        if (tree.mapped != snapshot) return error.InvalidSemanticGeometry;
        try tree.validate();
        if (snapshot.semantic_len != tree.len) return error.InvalidSemanticGeometry;
        for (snapshot.semantics[0..tree.len]) |item| {
            try item.local_bounds.validate();
            try validateSemanticReference(snapshot, item.reference);
        }
        // One bounded Tree validation for the whole batch. No persistent cache
        // or escaping proof is needed; at most 2 KiB of candidate Rect storage.
        var candidates: [accessibility.max_nodes]Rect = undefined;
        for (ids, 0..) |id, at| {
            var found = false;
            for (tree.entries[0..tree.len], snapshot.semantics[0..tree.len]) |entry, item| {
                if (entry.id != id) continue;
                if (!std.meta.eql(item.reference, self.transforms.?.reference)) return error.SemanticScopeMismatch;
                candidates[at] = try self.rebaseSemanticBounds(item.local_bounds);
                found = true;
                break;
            }
            if (!found) return error.MissingSemanticNode;
        }
        @memcpy(output[0..ids.len], candidates[0..ids.len]);
    }
    fn rebaseSemanticBounds(self: *const Frame, bounds: affine.Rect) !Rect {
        const local: Rect = .{ .x = @floatCast(bounds.x - self.offset.x), .y = @floatCast(bounds.y - self.offset.y), .width = @floatCast(bounds.width), .height = @floatCast(bounds.height) };
        try affine.Rect.from(local).validate();
        // coordinateMapping uses a double-precision offset translation, while
        // Frame.absolute records f32 coordinates. Both must recover the exact
        // descriptor: a rounded f32 sum alone would hide lost local position.
        if (@as(f64, local.x) + self.offset.x != bounds.x or @as(f64, local.y) + self.offset.y != bounds.y or @as(f64, local.width) != bounds.width or @as(f64, local.height) != bounds.height or !std.meta.eql(affine.Rect.from(self.absolute(local)), bounds)) return error.InvalidGeometry;
        if ((@as(f64, local.x) + local.width) + self.offset.x != bounds.x + bounds.width or (@as(f64, local.y) + local.height) + self.offset.y != bounds.y + bounds.height) return error.InvalidGeometry;
        return local;
    }
    fn validateSemanticReference(snapshot: *const affine_state.Snapshot, reference: affine.Ref) !void {
        _ = try snapshot.geometry.getSpace(reference.space);
        var clip = reference.clip;
        var depth: usize = 0;
        while (clip) |id| {
            if (depth == affine.max_clip_depth) return error.ClipDepthExceeded;
            const index = @intFromEnum(id);
            if (index >= snapshot.geometry.clip_len) return error.InvalidClip;
            const item = snapshot.geometry.clips[index];
            _ = try snapshot.geometry.getSpace(item.space);
            try item.bounds.validate();
            if (item.parent) |parent| if (@intFromEnum(parent) >= index) return error.InvalidClip;
            clip = item.parent;
            depth += 1;
        }
    }
    pub fn beginTransform(self: *Frame, source_size: layout.Size, to_parent: affine.Affine) !void {
        errdefer |err| self.failure = self.failure orelse err;
        const workspace = self.transforms orelse return error.TransformsNotPrepared;
        const options = workspace.options orelse return error.TransformsNotPrepared;
        if (workspace.depth == workspace.frames.len) return error.LayerDepthExceeded;
        const snapshot = try workspace.state.pending();
        const mark = snapshot.checkpoint();
        errdefer snapshot.rollback(mark) catch unreachable;
        // A native float matrix and input must use the same rounded forward
        // coefficients, including the parent's current pushOffset.
        const positioned = try to_parent.then(try affine.Affine.translation(affine.Point.from(self.offset)));
        const descriptor = try layers.NativeTransform.init(positioned, source_size, self.size.scale);
        const plan = try layers.Plan.initTransforms(options, if (builtin.os.tag == .linux) .cairo else .gdi);
        try plan.validateTransform(descriptor);
        const child_space = try snapshot.geometry.addChild(workspace.reference.space, descriptor.matrix());
        const source: Rect = .{ .x = 0, .y = 0, .width = source_size.width, .height = source_size.height };
        const child_clip = try snapshot.geometry.addClip(child_space, workspace.reference.clip, affine.Rect.from(source));
        try snapshot.noteScope();
        try self.context.command_buffer.beginTransform(descriptor);
        workspace.frames[workspace.depth] = .{ .frame = self.*, .reference = workspace.reference, .clip_parents = workspace.clip_parents, .group_parents = workspace.group_parents, .source_bounds = workspace.source_bounds };
        workspace.depth += 1;
        workspace.reference = .{ .space = child_space, .clip = child_clip };
        workspace.source_bounds = source;
        self.size = .{ .width = descriptor.pixel_width, .height = descriptor.pixel_height, .scale = self.size.scale };
        self.offset = .{};
        self.offset_depth = 0;
        self.clips.len = 0;
        self.group_depth = 0;
        self.group_geometry_passthrough = 0;
    }
    pub fn endTransform(self: *Frame) !void {
        errdefer |err| self.failure = self.failure orelse err;
        const workspace = self.transforms orelse return error.TransformsNotPrepared;
        if (workspace.depth == 0) return error.TransformStackEmpty;
        if (self.offset_depth != 0 or self.clips.len != 0 or self.group_depth != 0) return error.UnbalancedTransform;
        try self.context.command_buffer.endTransform();
        workspace.depth -= 1;
        const previous = &workspace.frames[workspace.depth];
        const failure = self.failure;
        self.* = previous.frame;
        self.failure = failure;
        workspace.reference = previous.reference;
        workspace.clip_parents = previous.clip_parents;
        workspace.group_parents = previous.group_parents;
        workspace.source_bounds = previous.source_bounds;
    }
    /// Capture this local coordinate system for the next successfully displayed
    /// frame. Query Context.committedSpace afterwards; this does not authorize
    /// using pending coordinates for editor input or native caret placement.
    pub fn captureSpace(self: *Frame, id: u64, bounds: Rect) !void {
        const workspace = self.transforms orelse return error.TransformsNotPrepared;
        const snapshot = try workspace.state.pending();
        const mark = snapshot.checkpoint();
        errdefer snapshot.rollback(mark) catch unreachable;
        const positioned = try snapshot.geometry.addChild(workspace.reference.space, try affine.Affine.translation(affine.Point.from(self.offset)));
        const clip = try snapshot.geometry.addClip(positioned, workspace.reference.clip, affine.Rect.from(bounds));
        try snapshot.addCapture(id, .{ .space = positioned, .clip = clip }, affine.Rect.from(bounds));
    }
    /// Bind an explicitly registered text recipient to this exact pending hit
    /// and captured Space. Only the successful visual transaction publishes it.
    /// Bind one explicitly registered control recipient to the accepted hit
    /// transaction. Complete virtual rows do not consume per-row hit slots.
    pub fn controlRecipient(self: *Frame, token: ControlToken, bounds: Rect, enabled: bool) !void {
        return self.controlRecipientStamped(token, bounds, enabled, .{});
    }
    /// Record the model structure and scroll used for this candidate image.
    /// Failed/cancelled frames preserve the old receipt with the old hits.
    pub fn controlRecipientStamped(self: *Frame, token: ControlToken, bounds: Rect, enabled: bool, receipt: ControlFrame) !void {
        errdefer |err| self.failure = self.failure orelse err;
        if (token.context != self.context) return error.ForeignFrame;
        if (!self.context.input_state.building) return error.NoFrame;
        const fields = self.context.input_state.fields orelse return error.TextFieldsNotPrepared;
        try fields.requireKind(token.key, .control);
        const snapshot = try (self.transforms orelse return error.CoordinatesNotPrepared).state.pending();
        const geometry_mark = snapshot.checkpoint();
        const index = self.context.input_state.checkpoint();
        errdefer {
            snapshot.rollback(geometry_mark) catch unreachable;
            self.context.input_state.rollback(index);
        }
        try self.captureSpace(token.key.id, bounds);
        try self.addControl(token.key.id, bounds, .{ .enabled = enabled });
        try self.context.input_state.bindControlRecipientFrame(index, token.key.id, token.key, receipt);
    }
    /// Full immutable native rows attach to the same viewport hit and Window
    /// root. Recording this stage allocates no labels, rows or providers.
    pub noinline fn virtualListRecipient(self: *Frame, token: ControlToken, bounds: Rect, enabled: bool, name: []const u8, receipt: ControlFrame, selection: u64, caret: ?VirtualListCaret) !void {
        errdefer |err| self.failure = self.failure orelse err;
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (!build_options.accessibility or !self.context.attached_semantics_enabled) return error.AccessibilityNotEnabled;
        try self.controlRecipientStamped(token, bounds, enabled, receipt);
        const snapshot = try self.transforms.?.state.pending();
        const capture = try snapshot.capture(token.key.id);
        const visible = try snapshot.geometry.visibleBounds(capture.reference, capture.local_bounds);
        try self.context.semantic_tree.addMapped(.{ .id = token.key.id, .role = .list, .name = name, .bounds = if (visible) |value| nativeRect(value) else .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .enabled = enabled, .focused = visible != null and self.context.input_state.focused == token.key.id }, capture.reference, capture.local_bounds);
        const mapping = try accessibility.virtual_lists.math.prepare(&snapshot.geometry, capture.reference, capture.local_bounds);
        try self.context.accessibility_bridge.stageVirtualList(token.key, receipt.model, selection, .{ .x = capture.local_bounds.x, .y = capture.local_bounds.y, .width = capture.local_bounds.width, .height = capture.local_bounds.height, .scroll = receipt.scroll, .space = @intFromEnum(capture.reference.space), .clip = if (capture.reference.clip) |clip| @intFromEnum(clip) else std.math.maxInt(u32), .caret = if (caret) |value| value.id else 0, .caret_incarnation = if (caret) |value| value.incarnation else 0 }, &mapping);
    }
    pub fn textField(self: *Frame, token: TextFieldToken, bounds: Rect, enabled: bool) !void {
        errdefer |err| self.failure = self.failure orelse err;
        if (token.context != self.context) return error.ForeignFrame;
        if (!self.context.input_state.building) return error.NoFrame;
        const fields = self.context.input_state.fields orelse return error.TextFieldsNotPrepared;
        try fields.requireKind(token.key, .text);
        const snapshot = try (self.transforms orelse return error.CoordinatesNotPrepared).state.pending();
        const geometry_mark = snapshot.checkpoint();
        const index = self.context.input_state.checkpoint();
        errdefer {
            snapshot.rollback(geometry_mark) catch unreachable;
            self.context.input_state.rollback(index);
        }
        try self.captureSpace(token.key.id, bounds);
        try self.addControl(token.key.id, bounds, .{ .enabled = enabled });
        try self.context.input_state.bindTextField(index, token.key.id, token.key);
    }
    /// Custom controls use local bounds/track/button coordinates just like
    /// drawing. Ordinary frames retain the original axis-aligned path.
    pub fn addControl(self: *Frame, id: u64, bounds: Rect, options: input.Options) !void {
        const absolute_bounds = self.absolute(bounds);
        const visible = if (self.clipBounds()) |clip| layout.intersect(absolute_bounds, clip) else absolute_bounds;
        var actual = options;
        if (options.focus_rect) |focus| {
            const value = self.absolute(focus);
            actual.focus_rect = if (self.clipBounds()) |clip| layout.intersect(value, clip) else value;
        }
        if (options.range) |range| {
            var value = range;
            value.track = self.absolute(range.track);
            if (range.step_buttons) |buttons| value.step_buttons = .{ .decrement = self.absolute(buttons.decrement), .increment = self.absolute(buttons.increment) };
            actual.range = value;
        }
        if (self.transforms) |workspace| try self.context.input_state.addMapped(id, visible, actual, workspace.reference) else try self.context.input_state.addWithOptions(id, visible, actual);
    }
    fn absolute(self: *const Frame, bounds: Rect) Rect {
        return .{ .x = bounds.x + self.offset.x, .y = bounds.y + self.offset.y, .width = bounds.width, .height = bounds.height };
    }
    pub fn pushOffset(self: *Frame, delta: layout.Point) !void {
        if (self.offset_depth == self.offsets.len) return error.OffsetStackFull;
        if (!std.math.isFinite(delta.x) or !std.math.isFinite(delta.y)) return error.InvalidGeometry;
        const next: layout.Point = .{ .x = self.offset.x + delta.x, .y = self.offset.y + delta.y };
        if (!std.math.isFinite(next.x) or !std.math.isFinite(next.y)) return error.InvalidGeometry;
        self.offsets[self.offset_depth] = self.offset;
        self.offset_depth += 1;
        self.offset = next;
    }
    pub fn popOffset(self: *Frame) !void {
        if (self.offset_depth == 0) return error.OffsetStackEmpty;
        self.offset_depth -= 1;
        self.offset = self.offsets[self.offset_depth];
    }
    pub fn beginGroup(self: *Frame, bounds: Rect, options: layers.Group) !void {
        errdefer |err| self.failure = self.failure orelse err;
        const absolute_bounds = self.absolute(bounds);
        const snapshot = if (self.transforms) |workspace| try workspace.state.pending() else null;
        const mark = if (snapshot) |value| value.checkpoint() else null;
        errdefer if (snapshot) |value| value.rollback(mark.?) catch unreachable;
        const geometry_clip = if (self.transforms) |workspace| try snapshot.?.geometry.addClip(workspace.reference.space, workspace.reference.clip, affine.Rect.from(absolute_bounds)) else null;
        var absolute_options = options;
        absolute_options.mask_origin.x += self.offset.x;
        absolute_options.mask_origin.y += self.offset.y;
        try self.context.command_buffer.beginGroup(absolute_bounds, absolute_options);
        if (self.transforms) |workspace| {
            workspace.group_parents[self.group_depth] = workspace.reference.clip;
            workspace.reference.clip = geometry_clip;
        }
        self.group_clip_base[self.group_depth] = self.clips.len;
        self.group_bounds[self.group_depth] = self.absolute(bounds);
        self.group_geometry_passthrough &= ~(@as(u8, 1) << @intCast(self.group_depth));
        self.group_depth += 1;
    }
    pub fn endGroup(self: *Frame) !void {
        errdefer |err| self.failure = self.failure orelse err;
        if (self.group_depth == 0) return error.GroupStackEmpty;
        if (self.group_geometry_passthrough & (@as(u8, 1) << @intCast(self.group_depth - 1)) != 0) return error.GroupStackEmpty;
        try self.context.command_buffer.endGroup();
        self.group_depth -= 1;
        if (self.transforms) |workspace| workspace.reference.clip = workspace.group_parents[self.group_depth];
    }
    pub fn pushClip(self: *Frame, bounds: Rect) !void {
        const absolute_bounds = self.absolute(bounds);
        if (!layout.validRect(absolute_bounds)) return error.InvalidGeometry;
        if (self.clips.len == 32) return error.ClipStackFull;
        const base = if (self.group_depth != 0) self.group_clip_base[self.group_depth - 1] else 0;
        const clip = if (self.clips.len > base) layout.intersect(self.clips.items[self.clips.len - 1], absolute_bounds) else absolute_bounds;
        const snapshot = if (self.transforms) |workspace| try workspace.state.pending() else null;
        const mark = if (snapshot) |value| value.checkpoint() else null;
        errdefer if (snapshot) |value| value.rollback(mark.?) catch unreachable;
        const geometry_clip = if (self.transforms) |workspace| try snapshot.?.geometry.addClip(workspace.reference.space, workspace.reference.clip, affine.Rect.from(clip)) else null;
        try self.context.command_buffer.pushClip(clip);
        if (self.transforms) |workspace| {
            workspace.clip_parents[self.clips.len] = workspace.reference.clip;
            workspace.reference.clip = geometry_clip;
        }
        self.clips.items[self.clips.len] = clip;
        self.clips.len += 1;
    }
    pub fn popClip(self: *Frame) !void {
        if (self.clips.len == 0) return error.ClipStackEmpty;
        try self.context.command_buffer.popClip();
        try self.clips.pop();
        if (self.transforms) |workspace| workspace.reference.clip = workspace.clip_parents[self.clips.len];
    }
    /// Geometric hit/semantic clip across parent and group boundaries.
    pub fn clipBounds(self: *const Frame) ?Rect {
        var result: ?Rect = if (self.transforms) |workspace| workspace.source_bounds else null;
        for (self.clips.items[0..self.clips.len]) |clip| result = if (result) |before| layout.intersect(before, clip) else clip;
        for (0..self.group_depth) |index| {
            if (self.group_geometry_passthrough & (@as(u8, 1) << @intCast(index)) != 0) continue;
            const clip = self.group_bounds[index];
            result = if (result) |before| layout.intersect(before, clip) else clip;
        }
        return result;
    }
    /// Visual isolation only: source bounds never become hit/semantic clipping.
    /// Parent visual clips are suspended while the body is recorded once.
    pub noinline fn gaussianScope(self: *Frame, bounds: Rect, kernel: gaussian.View, options: layers.Group, state: *anyopaque, body: *const fn (*anyopaque, *Frame) anyerror!void) anyerror!void {
        errdefer |err| self.failure = self.failure orelse err;
        try kernel.validate();
        if (kernel.descriptor.scale != self.size.scale) return error.GaussianDpiMismatch;
        if (self.group_depth == layers.max_depth) return error.GroupStackFull;
        const before = self.*;
        const mark = self.context.command_buffer.checkpoint();
        var committed = false;
        defer {
            const failure = self.failure;
            if (!committed) self.context.command_buffer.rollback(mark);
            self.* = before;
            self.failure = failure;
        }
        var absolute_options = options;
        absolute_options.mask_origin.x += self.offset.x;
        absolute_options.mask_origin.y += self.offset.y;
        try self.context.command_buffer.beginGaussian(self.absolute(bounds), kernel, absolute_options);
        self.group_clip_base[self.group_depth] = self.clips.len;
        self.group_geometry_passthrough |= @as(u8, 1) << @intCast(self.group_depth);
        self.group_depth += 1;
        try body(state, self);
        if (self.failure) |err| return @as(anyerror!void, err);
        if (self.group_depth != before.group_depth + 1 or self.clips.len != before.clips.len or self.offset_depth != before.offset_depth or !std.meta.eql(self.offset, before.offset) or self.transforms != before.transforms) return error.UnbalancedGaussian;
        try self.context.command_buffer.endGaussian();
        committed = true;
    }
    pub fn beginScroll(self: *Frame, bounds: Rect, model: *const scroll.ScrollModel) !void {
        try self.pushClip(bounds);
        errdefer self.popClip() catch {};
        try self.pushOffset(.{ .x = bounds.x - model.offset.x, .y = bounds.y - model.offset.y });
    }
    pub fn endScroll(self: *Frame) !void {
        try self.popOffset();
        try self.popClip();
    }
    pub fn semantic(self: *Frame, node: accessibility.Node) !void {
        if (build_options.accessibility and self.context.attached_semantics_enabled) {
            if (node.role == .text_box and !node.read_only and self.context.on_accessibility_action == null) {
                const state = &self.context.input_state;
                const field_owns_action = state.building and if (state.fields) |fields| fields.pendingRegistered(state.pending[0..state.pending_len], node.id) else false;
                if (!field_owns_action) return error.MissingAccessibilityHandler;
            }
            var absolute_node = node;
            absolute_node.bounds = self.absolute(node.bounds);
            if (self.transforms) |workspace| {
                const snapshot = try workspace.state.pending();
                const local = affine.Rect.from(absolute_node.bounds);
                const visible = try snapshot.geometry.visibleBounds(workspace.reference, local);
                absolute_node.bounds = if (visible) |value| nativeRect(value) else .{ .x = 0, .y = 0, .width = 0, .height = 0 };
                if (visible == null) absolute_node.focused = false;
                try self.context.semantic_tree.addMapped(absolute_node, workspace.reference, local);
            } else {
                if (self.clipBounds()) |clip| absolute_node.bounds = layout.intersect(absolute_node.bounds, clip);
                try self.context.semantic_tree.add(absolute_node);
            }
        }
    }

    pub fn clear(self: *Frame, rgb: u32) void {
        self.rect(.{ .x = 0, .y = 0, .width = @as(f32, @floatFromInt(self.size.width)) / self.size.scale, .height = @as(f32, @floatFromInt(self.size.height)) / self.size.scale }, rgb);
    }
    pub fn rect(self: *Frame, bounds: Rect, rgb: u32) void {
        self.context.command_buffer.fill(self.absolute(bounds), rgb) catch |err| {
            self.failure = self.failure orelse err;
        };
    }
    pub fn label(self: *Frame, bounds: Rect, text: []const u8, rgb: u32) void {
        self.labelFont(bounds, text, rgb, .{});
    }
    /// A single-line label in `font`, vertically centered and ellipsized
    /// like `label`.
    pub fn labelFont(self: *Frame, bounds: Rect, text: []const u8, rgb: u32, font: Font) void {
        self.context.command_buffer.textFont(self.absolute(bounds), text, rgb, font) catch |err| {
            self.failure = self.failure orelse err;
        };
    }
    pub fn image(self: *Frame, destination: Rect, view: drawing.ImageView, options: ImageOptions) !void {
        self.context.command_buffer.image(self.absolute(destination), view, options) catch |err| {
            self.failure = self.failure orelse err;
            return err;
        };
    }
    pub fn texture(self: *Frame, destination: Rect, view: drawing.TextureView, options: ImageOptions) !void {
        self.context.command_buffer.texture(self.absolute(destination), view, options) catch |err| {
            self.failure = self.failure orelse err;
            return err;
        };
    }
    pub fn coverage(self: *Frame, origin: layout.Point, view: drawing.CoverageView, color: Color) !void {
        if (view.coverage.scale != self.size.scale) {
            self.failure = self.failure orelse error.CoverageDpiMismatch;
            return error.CoverageDpiMismatch;
        }
        self.context.command_buffer.coverage(.{ .x = origin.x + self.offset.x, .y = origin.y + self.offset.y }, view, color) catch |err| {
            self.failure = self.failure orelse err;
            return err;
        };
    }
    pub fn gradientCoverage(self: *Frame, origin: layout.Point, view: drawing.CoverageView, gradient: commands.Gradient) !void {
        if (view.coverage.scale != self.size.scale) {
            self.failure = self.failure orelse error.CoverageDpiMismatch;
            return error.CoverageDpiMismatch;
        }
        const offset: layout.Point = self.offset;
        self.context.command_buffer.gradientCoverage(.{ .x = origin.x + offset.x, .y = origin.y + offset.y }, view, gradient.translated(offset)) catch |err| {
            self.failure = self.failure orelse err;
            return err;
        };
    }
    /// Borrow an explicitly prepared immutable layout until this paint ends.
    pub fn preparedText(self: *Frame, origin: layout.Point, view: drawing.PreparedTextView, color: Color) !void {
        if (view.coverage.scale != self.size.scale) {
            self.failure = self.failure orelse error.PreparedTextScaleMismatch;
            return error.PreparedTextScaleMismatch;
        }
        self.context.command_buffer.preparedText(.{ .x = origin.x + self.offset.x, .y = origin.y + self.offset.y }, view, color) catch |err| {
            self.failure = self.failure orelse err;
            return err;
        };
    }
    pub fn roundedRect(self: *Frame, bounds: Rect, radius: f32, color: Color) void {
        self.context.command_buffer.roundedRect(self.absolute(bounds), radius, color) catch |err| {
            self.failure = self.failure orelse err;
        };
    }
    pub fn strokeRect(self: *Frame, bounds: Rect, radius: f32, width: f32, color: Color) void {
        self.context.command_buffer.strokeRect(self.absolute(bounds), radius, width, color) catch |err| {
            self.failure = self.failure orelse err;
        };
    }
    /// Filter what has been drawn beneath `bounds` in the current target and
    /// write the result inside its rounded rectangle: a blur, a glass pane or
    /// a scroll edge. Inside a group, transform or Gaussian scope the effect
    /// sees only what that scope has drawn so far. Under reduced
    /// transparency or high contrast, and before `prepareBackdropEffects`,
    /// it draws an opaque fill instead. Hit testing and semantics are the
    /// caller's, as for any drawing.
    pub fn backdropEffect(self: *Frame, bounds: Rect, radius: f32, effect: BackdropEffect) void {
        self.recordBackdrop(bounds, radius, effect) catch |err| {
            self.failure = self.failure orelse err;
        };
    }
    /// Draw loading indicator `kind` fitted and centered in `bounds`, at the
    /// pose `phase` cycles into its animation; `loading.phase` derives it
    /// from elapsed time. Scheduling the next frame is the caller's.
    pub fn loadingIndicator(self: *Frame, bounds: Rect, kind: loading.Kind, phase: f64, color: Color, options: loading.Options) void {
        self.context.command_buffer.loadingIndicator(.{ .bounds = self.absolute(bounds), .kind = kind, .phase = phase, .color = color, .options = options }) catch |err| {
            self.failure = self.failure orelse err;
        };
    }
    /// Draw what follows, until `endEffect`, through `effect`: the content is
    /// captured in isolation over `box` plus the effect's margin, rewritten
    /// by its program and composited at `options.opacity`. Hit testing,
    /// focus and semantics keep their geometry. A prepared Gaussian
    /// workspace with room isolates the content exactly in a layer;
    /// otherwise it is isolated on the target (see
    /// `shader_effects.twoPassRegion`). Without `prepareShaderEffects`, or
    /// nested deeper than the layer depth, the content is drawn as it is
    /// and counted as unprepared.
    pub fn beginEffect(self: *Frame, box: Rect, effect: ShaderEffect, options: EffectOptions) !void {
        errdefer |err| self.failure = self.failure orelse err;
        if (self.effect_depth == self.effect_scopes.len) return error.EffectStackFull;
        var entry: shader_effects.Entry = .{ .program = effect.program, .values = effect.values.*, .target = .element, .box = self.absolute(box), .margin = effect.margin, .opacity = options.opacity };
        try shader_effects.validate(entry);
        entry.scale = self.size.scale;
        _ = try shader_effects.carrier(entry.scale);
        if (self.context.shader_workspace == null or self.group_depth == layers.max_depth) {
            self.context.shader_unprepared += 1;
            self.effect_scopes[self.effect_depth] = false;
            self.effect_depth += 1;
            return;
        }
        try self.context.command_buffer.beginEffect(entry);
        self.group_clip_base[self.group_depth] = self.clips.len;
        self.group_bounds[self.group_depth] = entry.captureBounds();
        self.group_geometry_passthrough |= @as(u8, 1) << @intCast(self.group_depth);
        self.group_depth += 1;
        self.effect_scopes[self.effect_depth] = true;
        self.effect_depth += 1;
    }
    pub fn endEffect(self: *Frame) !void {
        errdefer |err| self.failure = self.failure orelse err;
        if (self.effect_depth == 0) return error.EffectStackEmpty;
        if (self.effect_scopes[self.effect_depth - 1]) {
            if (self.group_depth == 0 or self.group_geometry_passthrough & (@as(u8, 1) << @intCast(self.group_depth - 1)) == 0) return error.UnbalancedEffect;
            try self.context.command_buffer.endEffect();
            self.group_depth -= 1;
            self.group_geometry_passthrough &= ~(@as(u8, 1) << @intCast(self.group_depth));
        }
        self.effect_depth -= 1;
    }
    /// Rewrite what has been drawn beneath `bounds` with `effect`'s program,
    /// inside its rounded rectangle; reads reach `effect.margin` beyond it.
    /// Like `backdropEffect` it sees only the current scope's content.
    /// Without the shader and backdrop workspaces it draws nothing.
    pub fn backdropShader(self: *Frame, bounds: Rect, radius: f32, effect: ShaderEffect) void {
        self.recordBackdropShader(bounds, radius, effect) catch |err| {
            self.failure = self.failure orelse err;
        };
    }
    fn recordBackdropShader(self: *Frame, bounds: Rect, radius: f32, effect: ShaderEffect) !void {
        const entry: shader_effects.Entry = .{ .program = effect.program, .values = effect.values.*, .target = .backdrop, .box = self.absolute(bounds), .margin = effect.margin, .radius = radius };
        try shader_effects.validate(entry);
        if (self.context.shader_workspace == null or self.context.backdrop_workspace == null) {
            self.context.shader_unprepared += 1;
            return;
        }
        try self.context.command_buffer.backdropShader(entry);
    }
    fn recordBackdrop(self: *Frame, bounds: Rect, radius: f32, effect: BackdropEffect) !void {
        const palette = self.currentTheme().palette;
        const preferences = self.context.backdrop_preferences;
        const dark = backdrop_effects.isDark(palette.background);
        const fallback = backdrop_effects.fallbackColor(effect, palette.background, palette.control);
        const buffer = &self.context.command_buffer;
        const absolute_bounds = self.absolute(bounds);
        const opaque_fill = preferences.opaqueFill() or self.context.backdrop_workspace == null;
        if (!preferences.opaqueFill() and self.context.backdrop_workspace == null) self.context.backdrop_unprepared += 1;
        switch (effect) {
            .scroll_edge => |edge| {
                const background = edge.background orelse palette.background;
                if (opaque_fill) {
                    try buffer.roundedRect(absolute_bounds, radius, .rgb(background));
                } else if (!edge.hard) {
                    const stops = [_]commands.brushes.Stop{ .{ .offset = 0, .color = alphaColor(background, backdrop_effects.soft_edge_alpha) }, .{ .offset = 1, .color = alphaColor(background, 0) } };
                    const top: layout.Point = .{ .x = absolute_bounds.x, .y = absolute_bounds.y };
                    const bottom: layout.Point = .{ .x = absolute_bounds.x, .y = absolute_bounds.y + absolute_bounds.height };
                    try buffer.gradientRect(absolute_bounds, radius, .{ .linear = .{ .start = if (edge.bottom) bottom else top, .end = if (edge.bottom) top else bottom, .stops = &stops } });
                    return;
                } else try buffer.backdropEffect(.{ .bounds = absolute_bounds, .radius = radius, .kind = .edge, .dark = dark, .background = background, .fallback = fallback });
                if (!edge.hard) return;
                // A hairline separates the hard edge from the content.
                const height = @max(0.5, 1 / self.size.scale);
                const alpha: f64 = (if (dark) @as(f64, 0.07) else 0.1) * 0.5 / height;
                const y = if (edge.bottom) absolute_bounds.y - height else absolute_bounds.y + absolute_bounds.height;
                try buffer.roundedRect(.{ .x = absolute_bounds.x, .y = y, .width = absolute_bounds.width, .height = height }, 0, alphaColor(if (dark) 0xffffff else 0, alpha));
            },
            .glass => |glass| {
                if (!std.math.isFinite(glass.noise)) return error.InvalidGeometry;
                if (opaque_fill) {
                    try buffer.roundedRect(absolute_bounds, radius, fallback);
                    if (preferences.high_contrast) try buffer.strokeRect(absolute_bounds, radius, 1, .rgb(palette.border));
                    return;
                }
                try buffer.backdropEffect(.{ .bounds = absolute_bounds, .radius = radius, .kind = .glass, .style = glass.style, .dark = dark, .tint = glass.tint orelse .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .noise = glass.noise, .fallback = fallback });
            },
            .blur => |blur| {
                if (!std.math.isFinite(blur.radius) or blur.radius < 0) return error.InvalidGeometry;
                if (opaque_fill) {
                    if (blur.mask) |mask| {
                        const points = backdrop_effects.maskPoints(mask, absolute_bounds);
                        const stops = [_]commands.brushes.Stop{ .{ .offset = 0, .color = alphaColor(palette.background, @as(f64, @floatFromInt(mask.from)) / 255) }, .{ .offset = 1, .color = alphaColor(palette.background, @as(f64, @floatFromInt(mask.to)) / 255) } };
                        try buffer.gradientRect(absolute_bounds, radius, .{ .linear = .{ .start = points[0], .end = points[1], .stops = &stops } });
                    } else try buffer.roundedRect(absolute_bounds, radius, fallback);
                    return;
                }
                if (blur.radius == 0 and blur.mask == null) return;
                try buffer.backdropEffect(.{ .bounds = absolute_bounds, .radius = radius, .kind = .blur, .sigma = blur.radius, .mask = blur.mask, .dark = dark, .fallback = fallback });
            },
        }
    }
    pub fn gradientRect(self: *Frame, bounds: Rect, radius: f32, gradient: commands.Gradient) void {
        self.context.command_buffer.gradientRect(self.absolute(bounds), radius, gradient.translated(.{ .x = self.offset.x, .y = self.offset.y })) catch |err| {
            self.failure = self.failure orelse err;
        };
    }
    pub fn gradientStrokeRect(self: *Frame, bounds: Rect, radius: f32, width: f32, gradient: commands.Gradient) void {
        self.context.command_buffer.gradientStrokeRect(self.absolute(bounds), radius, width, gradient.translated(.{ .x = self.offset.x, .y = self.offset.y })) catch |err| {
            self.failure = self.failure orelse err;
        };
    }
    pub fn button(self: *Frame, id: u64, bounds: Rect, text: []const u8) !void {
        try self.buttonWithOptions(id, bounds, text, .{});
    }
    pub fn buttonWithOptions(self: *Frame, id: u64, bounds: Rect, text: []const u8, options: widgets.Options) !void {
        try widgets.emit(self, .button, id, bounds, text, false, 0, options);
    }
    pub fn clickButton(self: *Frame, target: ClickTarget, bounds: Rect, text: []const u8, options: widgets.Options) !void {
        if (target.context != self.context) return error.ForeignFrame;
        const workspace = self.context.input_state.clicks orelse return error.PointerClicksNotPrepared;
        const binding: input.pointer_clicks.kernel.Target = .{ .owner = &workspace.state, .installation = target.installation, .registration = target.registration, .serial = target.serial, .id = target.id };
        try widgets.emitClickButton(self, binding, bounds, text, options);
    }
    /// Plain text that acts as a button, such as a label that becomes a
    /// text field when activated; announced as a button named `text`.
    pub fn labelButton(self: *Frame, id: u64, bounds: Rect, text: []const u8, options: widgets.Options) !void {
        try widgets.emit(self, .label_button, id, bounds, text, false, 0, options);
    }
    pub fn checkbox(self: *Frame, id: u64, bounds: Rect, text: []const u8, checked: bool, options: widgets.Options) !void {
        try widgets.emit(self, .checkbox, id, bounds, text, checked, 0, options);
    }
    pub fn radio(self: *Frame, id: u64, bounds: Rect, text: []const u8, selected: bool, options: widgets.Options) !void {
        try widgets.emit(self, .radio, id, bounds, text, selected, 0, options);
    }
    pub fn radioGroup(self: *Frame, id: u64, bounds: Rect, name: []const u8) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .role = .radio_group, .name = name, .bounds = bounds });
    }
    /// A row of tabs; each `tab` names this id as its `radio_group`.
    pub fn tabList(self: *Frame, id: u64, bounds: Rect, name: []const u8) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .role = .tab_list, .name = name, .bounds = bounds });
    }
    /// One tab. Like a radio, it shares a Tab stop and arrow navigation with
    /// its `radio_group` peers, and activation selects it.
    pub fn tab(self: *Frame, id: u64, bounds: Rect, text: []const u8, selected: bool, options: widgets.Options) !void {
        if (options.radio_group == null) return error.MissingGroup;
        try widgets.emit(self, .tab, id, bounds, text, selected, 0, options);
    }
    /// One segment of a segmented control, a row of joined buttons that
    /// selects like a radio; `radio_group` names its `radioGroup`.
    pub fn segment(self: *Frame, id: u64, bounds: Rect, text: []const u8, selected: bool, options: widgets.Options) !void {
        if (options.radio_group == null) return error.MissingGroup;
        try widgets.emit(self, .segment, id, bounds, text, selected, 0, options);
    }
    /// Underlined accent text that activates like a button. The application
    /// decides what activation opens.
    pub fn link(self: *Frame, id: u64, bounds: Rect, text: []const u8, options: widgets.Options) !void {
        try widgets.emit(self, .link, id, bounds, text, false, 0, options);
    }
    /// A labelled expander; activation should flip the application's
    /// `expanded` value, which also decides whether the content is drawn.
    pub fn disclosure(self: *Frame, id: u64, bounds: Rect, text: []const u8, expanded: bool, options: widgets.Options) !void {
        try widgets.emit(self, .disclosure, id, bounds, text, expanded, 0, options);
    }
    /// A named group of tool controls; controls name it as `semantic_parent`.
    pub fn toolbar(self: *Frame, id: u64, bounds: Rect, name: []const u8) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .role = .toolbar, .name = name, .bounds = bounds });
    }
    /// A single-selection list of options; each `listItem` names this id as
    /// its `radio_group`.
    pub fn listBox(self: *Frame, id: u64, bounds: Rect, name: []const u8) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .role = .list_box, .name = name, .bounds = bounds });
    }
    /// One option of a list box. It shares a Tab stop and arrow navigation
    /// with its peers, and activation selects it.
    pub fn listItem(self: *Frame, id: u64, bounds: Rect, text: []const u8, selected: bool, options: widgets.Options) !void {
        if (options.radio_group == null) return error.MissingGroup;
        try widgets.emit(self, .list_item, id, bounds, text, selected, 0, options);
    }
    /// A named navigation region, such as a breadcrumb trail; links inside
    /// name it as `semantic_parent`.
    pub fn navigation(self: *Frame, id: u64, bounds: Rect, name: []const u8, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .parent = parent, .role = .navigation, .name = name, .bounds = bounds });
    }
    /// A named group of related controls, such as accordion sections.
    pub fn group(self: *Frame, id: u64, bounds: Rect, name: []const u8, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .parent = parent, .role = .group, .name = name, .bounds = bounds });
    }
    /// A field showing the current choice `text` that opens a list of
    /// options; `expanded` is whether that list is open. Activation should
    /// open or close it. Named by `options.name`.
    pub fn comboBox(self: *Frame, id: u64, bounds: Rect, text: []const u8, expanded: bool, options: widgets.Options) !void {
        try widgets.emit(self, .combo_box, id, bounds, text, expanded, 0, options);
    }
    /// The list a combo box or text input opens, drawn over other content;
    /// its options name this id as their `radio_group`.
    pub fn popupList(self: *Frame, id: u64, bounds: Rect, name: []const u8, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .parent = parent, .role = .list_box, .name = name, .bounds = bounds });
    }
    /// A panel drawn over other content and anchored to a control, such as
    /// a date input's calendar. It occludes the controls behind it, so a
    /// press on its background reaches none of them; its own controls
    /// follow it.
    pub fn popover(self: *Frame, id: u64, bounds: Rect, name: []const u8, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.addControl(id, bounds, .{ .enabled = false, .focusable = false });
        try self.semantic(.{ .id = id, .parent = parent, .role = .popup, .name = name, .bounds = bounds });
    }
    /// A dialog drawn inside the window over the rest of its content.
    /// Like a popover it occludes the controls behind it; its own controls
    /// follow it. `alert` reports an alert dialog, which asks for a
    /// response before work continues. `description` is announced with
    /// the name, such as the dialog's message.
    pub fn dialog(self: *Frame, id: u64, bounds: Rect, name: []const u8, description: []const u8, alert: bool, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.addControl(id, bounds, .{ .enabled = false, .focusable = false });
        try self.semantic(.{ .id = id, .parent = parent, .role = if (alert) .alert_dialog else .dialog, .name = name, .description = description, .bounds = bounds });
    }
    /// How many controls and semantic nodes this frame has added so far,
    /// for `makeInert`.
    pub const InertMark = struct { controls: usize, semantics: usize };
    pub fn inertMark(self: *const Frame) InertMark {
        return .{
            .controls = self.context.input_state.checkpoint(),
            .semantics = if (comptime @TypeOf(self.context.semantic_tree) != void) self.context.semantic_tree.len else 0,
        };
    }
    /// Disables the controls and semantic nodes added between two marks,
    /// such as the content behind a modal dialog. They keep occluding
    /// pointer input but take no input or focus and are reported disabled.
    pub fn makeInert(self: *Frame, from: InertMark, to: InertMark) void {
        const state = &self.context.input_state;
        const hits = if (state.building) state.pending[0..state.pending_len] else state.hits[0..state.len];
        for (hits[@min(from.controls, hits.len)..@min(to.controls, hits.len)]) |*hit| hit.options.enabled = false;
        if (comptime @TypeOf(self.context.semantic_tree) != void) {
            const tree = &self.context.semantic_tree;
            // The window root stays enabled.
            const start = @max(@min(from.semantics, tree.len), 1);
            const end = @min(to.semantics, tree.len);
            if (start < end) for (tree.entries[start..end]) |*entry| {
                entry.enabled = false;
                entry.focused = false;
            };
        }
    }
    /// A button with a chevron along `direction`, such as Back or Forward.
    pub fn navButton(self: *Frame, id: u64, bounds: Rect, direction: widgets.NavDirection, name: []const u8, options: widgets.Options) !void {
        try widgets.emitNavButton(self, id, bounds, direction, name, options);
    }
    pub fn avatar(self: *Frame, id: u64, bounds: Rect, name: []const u8, options: widgets.AvatarOptions) !void {
        try widgets.emitAvatar(self, id, bounds, name, options);
    }
    pub fn tooltip(self: *Frame, id: u64, bounds: Rect, text: []const u8) !void {
        try widgets.emitTooltip(self, id, bounds, text);
    }
    /// A transient status message, such as a toast; its contents follow.
    /// Announced politely to accessibility clients when it first appears.
    pub fn status(self: *Frame, id: u64, bounds: Rect, name: []const u8, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .parent = parent, .role = .status, .name = name, .bounds = bounds });
    }
    /// A named search region holding a query input and its controls.
    pub fn search(self: *Frame, id: u64, bounds: Rect, name: []const u8, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .parent = parent, .role = .search, .name = name, .bounds = bounds });
    }
    /// A tree of rows; `multiple` lets several be selected at once. Its rows
    /// name this id as their `radio_group`.
    pub fn treeView(self: *Frame, id: u64, bounds: Rect, name: []const u8, multiple: bool, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .parent = parent, .role = .tree, .name = name, .bounds = bounds, .multiple = multiple });
    }
    /// One tree row. Its semantic parent is the tree or the row it is
    /// nested under; `options.expanded` is null for a leaf.
    pub fn treeItem(self: *Frame, id: u64, bounds: Rect, text: []const u8, options: widgets.RowOptions) !void {
        if (options.control.radio_group == null) return error.MissingGroup;
        try widgets.emitTreeItem(self, id, bounds, text, options);
    }
    /// A table of rows under a header row; `multiple` lets several rows be
    /// selected at once. Its rows name this id as their `radio_group`.
    pub fn dataTable(self: *Frame, id: u64, bounds: Rect, name: []const u8, multiple: bool, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .parent = parent, .role = .table, .name = name, .bounds = bounds, .multiple = multiple });
    }
    /// The row of column headers at the top of a table.
    pub fn tableHeader(self: *Frame, id: u64, bounds: Rect, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .parent = parent, .role = .table_header, .name = "", .bounds = bounds });
    }
    /// A column title that sorts on activation when `sortable`; `sort` is
    /// the column's current direction, or null when another column sorts.
    pub fn columnHeader(self: *Frame, id: u64, bounds: Rect, title: []const u8, sort: ?widgets.SortDirection, sortable: bool, options: widgets.Options) !void {
        try widgets.emitColumnHeader(self, id, bounds, title, sort, sortable, options);
    }
    /// The background and semantics of one table row; record its cells after it.
    pub fn tableRow(self: *Frame, id: u64, bounds: Rect, name: []const u8, options: widgets.RowOptions) !void {
        if (options.control.radio_group == null) return error.MissingGroup;
        try widgets.emitTableRow(self, id, bounds, name, options);
    }
    /// A text input that collects tokens; its tokens and input follow.
    pub fn tokenField(self: *Frame, id: u64, bounds: Rect, name: []const u8, parent: u64) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .parent = parent, .role = .token_field, .name = name, .bounds = bounds });
    }
    pub fn tokenItem(self: *Frame, id: u64, remove_id: u64, bounds: Rect, text: []const u8, options: widgets.TokenOptions) !void {
        try widgets.emitToken(self, id, remove_id, bounds, text, options);
    }
    /// An editable combo box around a text input that follows: `value` is
    /// the input's text and `expanded` whether its list is open.
    pub fn comboField(self: *Frame, id: u64, bounds: Rect, value: []const u8, expanded: bool, options: widgets.Options) !void {
        if (id == accessibility.root_id) return error.ReservedControlId;
        try self.semantic(.{ .id = id, .parent = options.semantic_parent, .role = .combo_box, .name = options.name, .value = value, .description = options.description, .invalid = options.invalid, .required = options.required, .bounds = bounds, .enabled = options.enabled, .checked = expanded, .read_only = true });
    }
    pub fn comboToggle(self: *Frame, id: u64, bounds: Rect, expanded: bool, options: widgets.Options) !void {
        try widgets.emitComboToggle(self, id, bounds, expanded, options);
    }
    pub fn meter(self: *Frame, id: u64, bounds: Rect, value: f64, spec: Range, options: widgets.MeterOptions) !void {
        try widgets.emitMeter(self, id, bounds, value, spec, options);
    }
    pub fn rating(self: *Frame, id: u64, bounds: Rect, value: f64, count: u8, options: widgets.Options) !void {
        try widgets.emitRating(self, id, bounds, value, count, options);
    }
    pub fn splitter(self: *Frame, id: u64, bounds: Rect, divider: Rect, value: f64, spec: Range, options: widgets.SplitterOptions) !void {
        try widgets.emitSplitter(self, id, bounds, divider, value, spec, options);
    }
    pub fn toggleSwitch(self: *Frame, id: u64, bounds: Rect, text: []const u8, checked: bool, options: widgets.Options) !void {
        try widgets.emit(self, .toggle_switch, id, bounds, text, checked, 0, options);
    }
    pub fn progress(self: *Frame, id: u64, bounds: Rect, fraction: f32, options: widgets.Options) !void {
        try widgets.emit(self, .progress, id, bounds, "", false, fraction, options);
    }
    pub fn slider(self: *Frame, id: u64, bounds: Rect, value: f64, spec: Range, options: widgets.RangeOptions) !void {
        try widgets.emitSlider(self, id, bounds, value, spec, options);
    }
    pub fn rangeSlider(self: *Frame, ids: widgets.RangeSliderIds, bounds: Rect, values: input.Values, spec: Range, options: widgets.RangeSliderOptions) !void {
        try widgets.emitRangeSlider(self, ids, bounds, values, spec, options);
    }
    pub fn stepper(self: *Frame, id: u64, bounds: Rect, value: f64, spec: Range, options: widgets.Options) !void {
        try widgets.emitStepper(self, id, bounds, value, spec, options);
    }
};

fn alphaColor(rgb: u32, alpha: f64) Color {
    var color = Color.rgb(rgb);
    color.a = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255));
    return color;
}

const SavedTransform = struct {
    frame: Frame,
    reference: affine.Ref,
    clip_parents: [32]?affine.ClipId,
    group_parents: [layers.max_depth]?affine.ClipId,
    source_bounds: ?Rect,
};
const TransformWorkspace = struct {
    allocator: std.mem.Allocator,
    options: ?layers.TransformOptions = null,
    state: affine_state.State = .{},
    command_storage: commands.TransformStorage = .{},
    native_geometry: if (build_options.accessibility) accessibility.NativeGeometry else void = undefined,
    frames: [layers.max_depth]SavedTransform = undefined,
    depth: usize = 0,
    reference: affine.Ref = .{},
    clip_parents: [32]?affine.ClipId = undefined,
    group_parents: [layers.max_depth]?affine.ClipId = undefined,
    source_bounds: ?Rect = null,
    window_size: z.Size = .{ .width = 0, .height = 0, .scale = 1 },

    fn begin(self: *TransformWorkspace, size: z.Size, generation: u64) !void {
        try self.state.beginFrame(generation);
        self.depth = 0;
        self.reference = .{};
        self.source_bounds = null;
        self.window_size = size;
        self.command_storage.scale = size.scale;
    }
};

pub const MapOptions = struct {
    /// Physical wheel axes/amount remain unchanged by default. A host choosing
    /// local_vector explicitly applies the inverse linear map to the delta.
    wheel: enum { preserve_axes, local_vector } = .preserve_axes,
};

/// Borrowed Context handle. Context storage must outlive every token use.
/// Only the last successfully displayed snapshot authorizes coordinate use;
/// a token becomes stale after its replacement, release, or detach.
pub const SpaceToken = struct {
    context: *Context,
    generation: u64,
    id: u64,

    const Access = struct {
        scope: Context.AttachmentScope,
        snapshot: *const affine_state.Snapshot,
        item: affine_state.Capture,
        window: z.Window,
    };
    fn access(self: SpaceToken) !Access {
        const context = self.context;
        const window = context.window orelse return error.Closed;
        if (window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const scope = context.callbackScope(window) orelse return error.Closed;
        errdefer scope.end();
        if (self.generation != context.space_generation) return error.StaleSpace;
        const workspace = context.transforms orelse return error.StaleSpace;
        const item = try workspace.state.lookup(self.generation, self.id);
        return .{ .scope = scope, .snapshot = workspace.state.committed(), .item = item, .window = window };
    }
    /// Follow this stable ID across successful frames in the same attachment
    /// and explicitly prepared workspace. Release/detach never revives it.
    pub fn binding(self: SpaceToken) !SpaceBinding {
        const value = try self.access();
        defer value.scope.end();
        return .{ .context = self.context, .epoch = self.context.space_binding_epoch, .id = self.id, .window = value.window, .region = self.context.backdrop_region };
    }
    pub fn checkWindow(self: SpaceToken, window: z.Window) !void {
        const value = try self.access();
        defer value.scope.end();
        if (!Context.sameWindow(value.window, window)) return error.ForeignWindow;
    }
    /// Semantic continuity across equal successful fronts. This does not make
    /// the token usable after its exact frame generation has been replaced.
    pub fn geometryVersion(self: SpaceToken) !u64 {
        const value = try self.access();
        defer value.scope.end();
        return value.item.geometry_version;
    }
    /// The original local capture bounds, before forward projection or AABB
    /// clipping. No reconstructed rectangle, table append or allocation.
    pub fn localBounds(self: SpaceToken) !affine.Rect {
        const value = try self.access();
        defer value.scope.end();
        return value.item.local_bounds;
    }
    /// Independent of mapping, so a drag can continue outside the visible clip.
    pub fn contains(self: SpaceToken, window_point: z.Point) !bool {
        const value = try self.access();
        defer value.scope.end();
        return value.snapshot.geometry.contains(value.item.reference, value.item.local_bounds, affine.Point.from(window_point));
    }
    pub fn localPoint(self: SpaceToken, window_point: z.Point) !z.Point {
        const value = try self.access();
        defer value.scope.end();
        return nativePoint(try (try value.snapshot.geometry.getSpace(value.item.reference.space)).localPoint(affine.Point.from(window_point)));
    }
    pub fn windowBounds(self: SpaceToken, local_bounds: Rect) !Rect {
        const value = try self.access();
        defer value.scope.end();
        return nativeRect(try (try value.snapshot.geometry.getSpace(value.item.reference.space)).windowBounds(affine.Rect.from(local_bounds)));
    }
    /// Pointer positions map even outside the clip for captured dragging.
    /// Hosts separately check contains before a pointer-down hit. Key/text/IME
    /// events remain unchanged; no composition/document state is duplicated.
    pub fn mapEvent(self: SpaceToken, event_value: z.Event, options: MapOptions) !z.Event {
        const value = try self.access();
        defer value.scope.end();
        const space = try value.snapshot.geometry.getSpace(value.item.reference.space);
        return switch (event_value) {
            .pointer_down => |pointer| blk: {
                var mapped = pointer;
                mapped.position = nativePoint(try space.localPoint(affine.Point.from(pointer.position)));
                break :blk .{ .pointer_down = mapped };
            },
            .pointer_up => |pointer| blk: {
                var mapped = pointer;
                mapped.position = nativePoint(try space.localPoint(affine.Point.from(pointer.position)));
                break :blk .{ .pointer_up = mapped };
            },
            .pointer_move => |point| .{ .pointer_move = nativePoint(try space.localPoint(affine.Point.from(point))) },
            .wheel => |wheel| .{ .wheel = .{ .position = nativePoint(try space.localPoint(affine.Point.from(wheel.position))), .delta = if (options.wheel == .local_vector) nativePoint(try space.localVector(affine.Point.from(wheel.delta))) else wheel.delta } },
            else => event_value,
        };
    }
    /// Set the native candidate anchor from the very same accepted mapping.
    /// A fully clipped caret is explicitly rejected; native candidates retain
    /// their normal axis-aligned OS presentation.
    pub fn setTextCaret(self: SpaceToken, local_caret: Rect) !void {
        const value = try self.access();
        defer value.scope.end();
        const visible = try value.snapshot.geometry.visibleCaretBounds(value.item.reference, affine.Rect.from(local_caret)) orelse return error.NotVisible;
        try value.window.setTextCaret(nativeRect(visible));
    }
};

/// Borrowed coordinate binding for retained native clients. This follows only
/// successful fronts of its original workspace/Window/Region. Context storage
/// must outlive all uses and the client's unbind callback.
pub const SpaceBinding = struct {
    context: *Context,
    epoch: u64,
    id: u64,
    window: z.Window,
    region: ?z.composition.Region,

    pub fn resolve(self: SpaceBinding) !SpaceToken {
        if (self.window.app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        const context = self.context;
        const scope = context.callbackScope(self.window) orelse return error.Closed;
        defer scope.end();
        if (context.space_binding_epoch != self.epoch or !std.meta.eql(context.backdrop_region, self.region)) return error.StaleSpace;
        const workspace = context.transforms orelse return error.StaleSpace;
        _ = try workspace.state.lookup(context.space_generation, self.id);
        return .{ .context = context, .generation = context.space_generation, .id = self.id };
    }
    pub fn checkWindow(self: SpaceBinding, window: z.Window) !void {
        if (!Context.sameWindow(window, self.window)) return error.ForeignWindow;
        _ = try self.resolve();
    }
    pub fn setTextCaret(self: SpaceBinding, local_caret: Rect) !void {
        try (try self.resolve()).setTextCaret(local_caret);
    }
};

fn nativePoint(point: affine.Point) z.Point {
    return .{ .x = @floatCast(point.x), .y = @floatCast(point.y) };
}
fn nativeRect(bounds: affine.Rect) Rect {
    return .{ .x = @floatCast(bounds.x), .y = @floatCast(bounds.y), .width = @floatCast(bounds.width), .height = @floatCast(bounds.height) };
}

test {
    _ = gdi;
    _ = effects;
    _ = canvas;
    _ = @import("pixel_image.zig");
    _ = frame_stats;
    _ = input;
    _ = layout;
    _ = grid;
    _ = scroll;
    _ = text_buffer;
    _ = editor;
    _ = commands;
    _ = accessibility;
    _ = widgets;
    _ = theme;
    _ = @import("render_batch.zig");
    _ = @import("gpu_reservations.zig");
    _ = @import("gpu_transform_precision.zig");
    _ = @import("gradient_interpolation_gpu.zig");
}

test "theme updates copy values at update boundaries and preserve failed transactions" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn worker(context: *Context) void {
            std.testing.expectError(error.WrongThread, context.setTheme(.dark())) catch unreachable;
        }
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    try std.testing.expect(!try context.setTheme(.light()));
    var custom = Theme.dark();
    try std.testing.expect(try context.setTheme(custom));
    custom.palette.accent = 0xff5500;
    try std.testing.expect(context.currentTheme().palette.accent != custom.palette.accent);
    const version = context.themeVersion();
    var invalid = custom;
    invalid.metrics.thumb_size = std.math.nan(f32);
    try std.testing.expectError(error.InvalidThemeMetric, context.setTheme(invalid));
    context.painting = true;
    try std.testing.expectError(error.Busy, context.setTheme(custom));
    context.painting = false;
    try std.testing.expectEqual(version, context.themeVersion());
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    context.window = window;
    context.attachment_phase = .attached;
    const worker = try std.Thread.spawn(.{}, Dummy.worker, .{&context});
    worker.join();
    try std.testing.expect(try context.setTheme(.highContrast()));
    const scope = window.beginCallback().?;
    _ = try window.destroy();
    try std.testing.expectError(error.Closed, context.setTheme(.dark()));
    scope.end();
    context.window = null;
    context.attachment_phase = .detached;
    context.theme_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, context.setTheme(.light()));
}

test "backdrop effects record opaque fills for system preferences and an unprepared workspace" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    defer context.command_buffer.reset();
    var frame: Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 2 } };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 80, .height = 40 };
    const buffer = &context.command_buffer;
    // Unprepared: an opaque fill, counted.
    frame.backdropEffect(bounds, 12, .{ .glass = .{} });
    try std.testing.expect(buffer.commands()[0] == .shape);
    try std.testing.expectEqual(@as(u64, 1), context.backdropEffectStats().unprepared);
    const workspace = try backdrop_effects.Workspace.create(std.testing.allocator, .{ .max_pixels = 64 });
    context.backdrop_workspace = workspace;
    defer {
        context.backdrop_workspace = null;
        workspace.destroy();
    }
    buffer.reset();
    try frame.pushOffset(.{ .x = 5, .y = 6 });
    frame.backdropEffect(bounds, 12, .{ .glass = .{ .tint = .{ .r = 255, .g = 0, .b = 0, .a = 128 } } });
    frame.backdropEffect(bounds, 0, .{ .blur = .{ .radius = 4, .mask = .{} } });
    frame.backdropEffect(bounds, 0, .{ .scroll_edge = .{ .hard = true } });
    frame.backdropEffect(bounds, 0, .{ .scroll_edge = .{} });
    try frame.popOffset();
    try std.testing.expectEqual(@as(?anyerror, null), frame.failure);
    const list = buffer.commands();
    try std.testing.expectEqual(@as(usize, 5), list.len);
    try std.testing.expect(list[0] == .backdrop and list[1] == .backdrop and list[2] == .backdrop and list[3] == .shape and list[4] == .gradient);
    const glass = buffer.backdropEntries()[0];
    try std.testing.expectEqual(backdrop_effects.Kind.glass, glass.kind);
    try std.testing.expectEqual(@as(f32, 5), glass.bounds.x);
    try std.testing.expectEqual(@as(u8, 128), glass.tint.a);
    // The hard edge's hairline is half a DIP below it at scale 2.
    try std.testing.expectEqual(@as(f32, 46), list[3].shape.bounds.y);
    try std.testing.expectEqual(@as(f32, 0.5), list[3].shape.bounds.height);
    try std.testing.expect(commands.softwareOnly(list));
    // Reduced transparency and high contrast fill opaquely, outlined in high contrast.
    buffer.reset();
    try context.setBackdropPreferences(.{ .high_contrast = true });
    frame.backdropEffect(bounds, 12, .{ .glass = .{} });
    frame.backdropEffect(bounds, 0, .{ .blur = .{ .radius = 4 } });
    try std.testing.expectEqual(@as(usize, 3), buffer.commands().len);
    try std.testing.expect(buffer.commands()[0] == .shape and buffer.commands()[1] == .shape and buffer.commands()[2] == .shape);
    try std.testing.expect(!commands.softwareOnly(buffer.commands()));
    try std.testing.expectEqual(@as(u64, 1), context.backdropEffectStats().unprepared);
    // Invalid input records nothing and keeps the error.
    buffer.reset();
    try context.setBackdropPreferences(.{});
    frame.backdropEffect(bounds, 0, .{ .blur = .{ .radius = std.math.nan(f32) } });
    try std.testing.expectEqual(@as(usize, 0), buffer.commands().len);
    try std.testing.expectEqual(@as(?anyerror, error.InvalidGeometry), frame.failure);
    // The table is bounded and rolls back with a checkpoint.
    frame.failure = null;
    const mark = buffer.checkpoint();
    for (0..backdrop_effects.max_entries) |_| frame.backdropEffect(bounds, 0, .{ .glass = .{} });
    try std.testing.expectEqual(@as(?anyerror, null), frame.failure);
    frame.backdropEffect(bounds, 0, .{ .glass = .{} });
    try std.testing.expectEqual(@as(?anyerror, error.BackdropsFull), frame.failure);
    buffer.rollback(mark);
    try std.testing.expectEqual(@as(usize, 0), buffer.backdropEntries().len);
}

test "widget errors roll back hit semantics and commands" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    if (build_options.accessibility) {
        context.attached_semantics_enabled = true;
        try context.semantic_tree.reset("Test", .{ .x = 0, .y = 0, .width = 100, .height = 100 });
    }
    var frame: Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 30 };
    try frame.button(1, bounds, "OK");
    const commands_before = context.command_buffer.len;
    const text_before = context.command_buffer.text_len;
    const semantics_before = if (build_options.accessibility) context.semantic_tree.len else 0;
    const used_before = if (build_options.accessibility) context.semantic_tree.used else 0;
    try std.testing.expectError(error.InvalidUtf8, frame.checkbox(2, bounds, "\xff", false, .{}));
    try std.testing.expectEqual(1, context.input_state.len);
    try std.testing.expectEqual(commands_before, context.command_buffer.len);
    try std.testing.expectEqual(text_before, context.command_buffer.text_len);
    if (build_options.accessibility) {
        try std.testing.expectEqual(semantics_before, context.semantic_tree.len);
        try std.testing.expectEqual(used_before, context.semantic_tree.used);
    }
    context.command_buffer.len = context.command_buffer.storage.len - 1;
    try std.testing.expectError(error.CommandsFull, frame.toggleSwitch(2, bounds, "More", false, .{}));
    try std.testing.expectEqual(1, context.input_state.len);
    try std.testing.expectEqual(context.command_buffer.storage.len - 1, context.command_buffer.len);
    context.command_buffer.reset();
    try frame.checkbox(2, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, "", false, .{});
    try std.testing.expectError(error.ReservedControlId, frame.button(0, bounds, "Reserved"));
    try std.testing.expectError(error.InvalidProgress, frame.progress(3, bounds, std.math.nan(f32), .{}));
    try frame.radioGroup(10, bounds, "Group");
    try frame.radio(3, bounds, "First", true, .{ .radio_group = 10 });
    try std.testing.expectError(error.MultipleRadioSelection, frame.radio(4, bounds, "Second", true, .{ .radio_group = 10 }));
    try std.testing.expectEqual(3, context.input_state.len);
}

test "writable field semantics use only the exact registered pending action route" {
    if (!build_options.accessibility) return error.SkipZigTest;
    const Callbacks = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn focus(_: *anyopaque, _: *TextFieldScope) !z.TextClientToken {
            return error.NotBound;
        }
        fn blur(_: *anyopaque, _: z.Window) !void {}
        fn fieldInput(_: *anyopaque, _: *TextFieldScope, _: z.Event) !TextFieldResult {
            return .{};
        }
        fn fieldAction(_: *anyopaque, _: *TextFieldScope, _: TextFieldAction) !TextFieldResult {
            return .{};
        }
    };
    var state: u8 = 0;
    var context = Context.init(&state, Callbacks.draw, Callbacks.action);
    context.attached_semantics_enabled = true;
    const fields = try input.text_fields.Workspace.create(std.testing.allocator, 1, .{ .fields = 1 }, 0);
    defer fields.release();
    context.input_state.fields = fields;
    const key = try fields.register(7, .{ .context = &state, .focus = Callbacks.focus, .blur = Callbacks.blur, .input = Callbacks.fieldInput, .action = Callbacks.fieldAction });
    context.input_state.beginFrame();
    defer context.input_state.cancelFrame();
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 80, .height = 20 };
    try context.semantic_tree.reset("Fields", .{ .x = 0, .y = 0, .width = 100, .height = 100 });
    var frame: Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
    try frame.addControl(7, bounds, .{});
    // Merely registering a recipient or retaining an older front is insufficient.
    try std.testing.expectError(error.MissingAccessibilityHandler, frame.semantic(.{ .id = 7, .role = .text_box, .name = "", .bounds = bounds }));
    try fields.bind(0, key);
    try frame.semantic(.{ .id = 7, .role = .text_box, .name = "", .bounds = bounds });
    try frame.addControl(8, bounds, .{});
    try std.testing.expectError(error.MissingAccessibilityHandler, frame.semantic(.{ .id = 8, .role = .text_box, .name = "", .bounds = bounds }));
    try std.testing.expect(try fields.unregister(key));
    _ = try fields.register(7, .{ .context = &state, .focus = Callbacks.focus, .blur = Callbacks.blur, .input = Callbacks.fieldInput, .action = Callbacks.fieldAction });
    try std.testing.expectError(error.MissingAccessibilityHandler, frame.semantic(.{ .id = 7, .role = .text_box, .name = "", .bounds = bounds }));
}

test "range widgets share transactional metadata and never update values while drawing" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn value(_: *anyopaque, _: u64, _: ValueChange) void {
            @panic("draw must not change a value");
        }
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    context.on_value = Dummy.value;
    if (build_options.accessibility) {
        context.attached_semantics_enabled = true;
        try context.semantic_tree.reset("Ranges", .{ .x = 0, .y = 0, .width = 200, .height = 200 });
    }
    var frame: Frame = .{ .context = &context, .size = .{ .width = 200, .height = 200, .scale = 1 } };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 180, .height = 30 };
    const spec: Range = .{ .minimum = -10, .maximum = 10, .step = 0.5 };
    try frame.slider(1, bounds, 0, spec, .{ .control = .{ .name = "Slider" } });
    try frame.stepper(2, bounds, 0, spec, .{ .name = "Stepper" });
    try frame.rangeSlider(.{ .group = 3, .low = 4, .high = 5 }, bounds, .{ .low = -2, .high = 2 }, spec, .{});
    try std.testing.expectEqual(@as(usize, 4), context.input_state.len);
    const length = context.command_buffer.len;
    try std.testing.expectError(error.DuplicateId, frame.rangeSlider(.{ .group = 6, .low = 7, .high = 1 }, bounds, .{ .low = 0, .high = 1 }, spec, .{}));
    try std.testing.expectEqual(@as(usize, 4), context.input_state.len);
    try std.testing.expectEqual(length, context.command_buffer.len);
    context.on_value = null;
    try std.testing.expectError(error.MissingValueHandler, frame.slider(8, bounds, 0, spec, .{}));
}

test "tabs select like radios inside a tab list and splitters report ranges" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn value(_: *anyopaque, _: u64, _: ValueChange) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    context.on_value = Dummy.value;
    if (build_options.accessibility) {
        context.attached_semantics_enabled = true;
        try context.semantic_tree.reset("Tabs", .{ .x = 0, .y = 0, .width = 200, .height = 200 });
    }
    var frame: Frame = .{ .context = &context, .size = .{ .width = 200, .height = 200, .scale = 1 } };
    const strip: Rect = .{ .x = 0, .y = 0, .width = 200, .height = 30 };
    try frame.tabList(10, strip, "Sections");
    try frame.tab(11, .{ .x = 0, .y = 0, .width = 60, .height = 30 }, "General", true, .{ .radio_group = 10 });
    try frame.tab(12, .{ .x = 60, .y = 0, .width = 60, .height = 30 }, "Advanced", false, .{ .radio_group = 10 });
    try std.testing.expectError(error.MissingGroup, frame.tab(13, strip, "Loose", false, .{}));
    try std.testing.expectError(error.MultipleRadioSelection, frame.tab(14, strip, "Second", true, .{ .radio_group = 10 }));
    try frame.toolbar(20, .{ .x = 0, .y = 30, .width = 200, .height = 30 }, "Tools");
    try frame.buttonWithOptions(21, .{ .x = 0, .y = 30, .width = 40, .height = 30 }, "Bold", .{ .semantic_parent = 20 });
    const area: Rect = .{ .x = 0, .y = 60, .width = 200, .height = 100 };
    try frame.splitter(30, area, .{ .x = 97, .y = 60, .width = 6, .height = 100 }, 0.5, .{ .minimum = 0.2, .maximum = 0.8 }, .{ .control = .{ .name = "Panes" } });
    try std.testing.expectEqual(@as(usize, 4), context.input_state.len);
    // Tab moves to the selected tab; arrows move to and select a peer.
    context.input_state.tab();
    try std.testing.expectEqual(@as(?u64, 11), context.input_state.focused);
    try std.testing.expectEqual(@as(?u64, 12), context.input_state.navigate(.{ .key = .right }));
    if (build_options.accessibility) {
        const nodes = context.semantic_tree.entries[0..context.semantic_tree.len];
        var roles: [8]accessibility.Role = undefined;
        for (nodes[1..], 0..) |node, i| roles[i] = node.role;
        try std.testing.expectEqualSlices(accessibility.Role, &.{ .tab_list, .tab, .tab, .toolbar, .button, .splitter }, roles[0 .. nodes.len - 1]);
        try std.testing.expectEqual(@as(?u64, 10), nodes[2].parent);
        try std.testing.expectEqual(@as(?u64, 20), nodes[5].parent);
        try std.testing.expectEqual(@as(f64, 0.8), nodes[6].range_maximum);
    }
}

test "segments select within a group while links and disclosures activate" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    if (build_options.accessibility) {
        context.attached_semantics_enabled = true;
        try context.semantic_tree.reset("Controls", .{ .x = 0, .y = 0, .width = 200, .height = 200 });
    }
    var frame: Frame = .{ .context = &context, .size = .{ .width = 200, .height = 200, .scale = 1 } };
    const row: Rect = .{ .x = 0, .y = 0, .width = 200, .height = 30 };
    try frame.radioGroup(10, row, "View");
    try frame.segment(11, .{ .x = 0, .y = 0, .width = 50, .height = 30 }, "Day", false, .{ .radio_group = 10 });
    try frame.segment(12, .{ .x = 50, .y = 0, .width = 50, .height = 30 }, "Week", true, .{ .radio_group = 10 });
    try std.testing.expectError(error.MissingGroup, frame.segment(13, row, "Loose", false, .{}));
    try frame.link(20, .{ .x = 0, .y = 40, .width = 80, .height = 24 }, "Docs", .{});
    try frame.disclosure(30, .{ .x = 0, .y = 70, .width = 120, .height = 24 }, "Details", true, .{});
    try std.testing.expectEqual(@as(usize, 4), context.input_state.len);
    context.input_state.tab();
    try std.testing.expectEqual(@as(?u64, 12), context.input_state.focused);
    try std.testing.expectEqual(@as(?u64, 11), context.input_state.navigate(.{ .key = .left }));
    context.input_state.tab();
    try std.testing.expectEqual(@as(?u64, 20), context.input_state.activation());
    if (build_options.accessibility) {
        const nodes = context.semantic_tree.entries[0..context.semantic_tree.len];
        try std.testing.expectEqual(accessibility.Role.radio, nodes[2].role);
        try std.testing.expectEqual(@as(?u64, 10), nodes[3].parent);
        try std.testing.expectEqual(accessibility.Role.link, nodes[4].role);
        try std.testing.expectEqual(accessibility.Role.disclosure, nodes[5].role);
        try std.testing.expect(nodes[5].checked);
    }
}

test "list boxes keep one selected option under arrow navigation" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    if (build_options.accessibility) {
        context.attached_semantics_enabled = true;
        try context.semantic_tree.reset("Controls", .{ .x = 0, .y = 0, .width = 200, .height = 200 });
    }
    var frame: Frame = .{ .context = &context, .size = .{ .width = 200, .height = 200, .scale = 1 } };
    try frame.listBox(10, .{ .x = 0, .y = 0, .width = 200, .height = 90 }, "Fonts");
    try frame.listItem(11, .{ .x = 0, .y = 0, .width = 200, .height = 30 }, "Serif", true, .{ .radio_group = 10 });
    try frame.listItem(12, .{ .x = 0, .y = 30, .width = 200, .height = 30 }, "Sans", false, .{ .radio_group = 10 });
    try frame.listItem(13, .{ .x = 0, .y = 60, .width = 200, .height = 30 }, "Mono", false, .{ .radio_group = 10 });
    try std.testing.expectError(error.MissingGroup, frame.listItem(14, .{ .x = 0, .y = 90, .width = 200, .height = 30 }, "Loose", false, .{}));
    context.input_state.tab();
    try std.testing.expectEqual(@as(?u64, 11), context.input_state.focused);
    try std.testing.expectEqual(@as(?u64, 12), context.input_state.navigate(.{ .key = .down }));
    try std.testing.expectEqual(@as(?u64, 13), context.input_state.navigate(.{ .key = .end }));
    if (build_options.accessibility) {
        const nodes = context.semantic_tree.entries[0..context.semantic_tree.len];
        try std.testing.expectEqual(accessibility.Role.list_box, nodes[1].role);
        try std.testing.expectEqual(accessibility.Role.list_item, nodes[2].role);
        try std.testing.expectEqual(@as(?u64, 10), nodes[3].parent);
        try std.testing.expect(nodes[2].checked);
    }
}

test "meters report values, ratings snap to marks and regions nest" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn value(_: *anyopaque, _: u64, _: input.ValueChange) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    context.on_value = Dummy.value;
    if (build_options.accessibility) {
        context.attached_semantics_enabled = true;
        try context.semantic_tree.reset("Controls", .{ .x = 0, .y = 0, .width = 300, .height = 200 });
    }
    var frame: Frame = .{ .context = &context, .size = .{ .width = 300, .height = 200, .scale = 1 } };
    const disk_range: Range = .{ .minimum = 0, .maximum = 512 };
    try frame.meter(10, .{ .x = 0, .y = 0, .width = 200, .height = 12 }, 480, disk_range, .{ .control = .{ .name = "Disk" }, .bands = .{ .high = 400 } });
    try std.testing.expectError(error.InvalidRange, frame.meter(11, .{ .x = 0, .y = 0, .width = 200, .height = 12 }, 1, disk_range, .{ .bands = .{ .low = 300, .high = 200 } }));
    try std.testing.expectError(error.InvalidValue, frame.meter(11, .{ .x = 0, .y = 0, .width = 200, .height = 12 }, 600, disk_range, .{}));
    try frame.navigation(20, .{ .x = 0, .y = 20, .width = 300, .height = 30 }, "Breadcrumbs", accessibility.root_id);
    try frame.link(21, .{ .x = 0, .y = 20, .width = 60, .height = 30 }, "Home", .{ .semantic_parent = 20 });
    try frame.group(30, .{ .x = 0, .y = 60, .width = 300, .height = 30 }, "Sections", accessibility.root_id);
    const stars: Rect = .{ .x = 0, .y = 100, .width = 150, .height = 30 };
    try frame.rating(40, stars, 3, 5, .{ .name = "Score", .semantic_parent = 30 });
    try std.testing.expectError(error.InvalidRange, frame.rating(41, stars, 0, 0, .{}));
    try std.testing.expectError(error.InvalidValue, frame.rating(41, stars, 2.5, 5, .{}));
    // Pressing the second mark's left edge or right edge still selects it.
    const mark = widgets.ratingMark(stars, 5, 1);
    inline for (.{ mark.x + 1, mark.x + mark.width - 1 }) |x| {
        context.input_state.down(.{ .x = x, .y = 115 });
        try std.testing.expectEqual(@as(f64, 2), context.input_state.pointerValue(.{ .x = x, .y = 115 }, .down).?.change.set);
        context.input_state.cancelPress();
    }
    if (build_options.accessibility) {
        const nodes = context.semantic_tree.entries[0..context.semantic_tree.len];
        try std.testing.expectEqual(accessibility.Role.meter, nodes[1].role);
        try std.testing.expect(nodes[1].read_only);
        try std.testing.expectEqual(@as(f64, 512), nodes[1].range_maximum);
        try std.testing.expectEqual(accessibility.Role.navigation, nodes[2].role);
        try std.testing.expectEqual(@as(?u64, 20), nodes[3].parent);
        try std.testing.expectEqual(accessibility.Role.slider, nodes[5].role);
        try std.testing.expectEqual(@as(?u64, 30), nodes[5].parent);
        try std.testing.expectEqual(@as(f64, 5), nodes[5].range_maximum);
    }
}

test "combo boxes, tooltips, status, search and avatars publish their roles" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    if (build_options.accessibility) {
        context.attached_semantics_enabled = true;
        try context.semantic_tree.reset("Controls", .{ .x = 0, .y = 0, .width = 300, .height = 300 });
    }
    var frame: Frame = .{ .context = &context, .size = .{ .width = 300, .height = 300, .scale = 1 } };
    try frame.search(10, .{ .x = 0, .y = 0, .width = 300, .height = 40 }, "Find", accessibility.root_id);
    try frame.comboBox(11, .{ .x = 0, .y = 0, .width = 160, .height = 32 }, "Sans", true, .{ .name = "Font", .semantic_parent = 10 });
    try frame.popupList(12, .{ .x = 0, .y = 36, .width = 160, .height = 64 }, "Font", 11);
    try frame.listItem(13, .{ .x = 0, .y = 36, .width = 160, .height = 32 }, "Serif", false, .{ .semantic_parent = 12, .radio_group = 12 });
    try frame.navButton(20, .{ .x = 0, .y = 120, .width = 32, .height = 32 }, .back, "Back", .{});
    try frame.avatar(21, .{ .x = 40, .y = 120, .width = 32, .height = 32 }, "Ada Lovelace", .{});
    try frame.status(22, .{ .x = 0, .y = 200, .width = 200, .height = 40 }, "Saved", accessibility.root_id);
    try frame.tooltip(23, .{ .x = 0, .y = 160, .width = 100, .height = 24 }, "Go back");
    // The combo box and navigation button take presses like buttons.
    context.input_state.down(.{ .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(?u64, 11), context.input_state.active);
    context.input_state.cancelPress();
    context.input_state.down(.{ .x = 10, .y = 130 });
    try std.testing.expectEqual(@as(?u64, 20), context.input_state.active);
    context.input_state.cancelPress();
    if (build_options.accessibility) {
        const nodes = context.semantic_tree.entries[0..context.semantic_tree.len];
        const expected = [_]accessibility.Role{ .search, .combo_box, .list_box, .list_item, .button, .image, .status, .tooltip };
        for (expected, nodes[1..][0..expected.len]) |role, node| try std.testing.expectEqual(role, node.role);
        const text = context.semantic_tree.storage[0..];
        try std.testing.expectEqualStrings("Font", text[nodes[2].name_start..][0..nodes[2].name_len]);
        try std.testing.expectEqualStrings("Sans", text[nodes[2].value_start..][0..nodes[2].value_len]);
        try std.testing.expect(nodes[2].checked and nodes[2].read_only);
        try std.testing.expectEqual(@as(?u64, 10), nodes[2].parent);
        try std.testing.expectEqual(@as(?u64, 11), nodes[3].parent);
        try std.testing.expectEqualStrings("Ada Lovelace", text[nodes[6].name_start..][0..nodes[6].name_len]);
        try std.testing.expectEqualStrings("Go back", text[nodes[8].name_start..][0..nodes[8].name_len]);
    }
}

test "trees, tables and token fields publish their roles and states" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    if (build_options.accessibility) {
        context.attached_semantics_enabled = true;
        try context.semantic_tree.reset("Collections", .{ .x = 0, .y = 0, .width = 300, .height = 300 });
    }
    var frame: Frame = .{ .context = &context, .size = .{ .width = 300, .height = 300, .scale = 1 } };
    const row: Rect = .{ .x = 0, .y = 0, .width = 200, .height = 24 };
    try frame.treeView(1, .{ .x = 0, .y = 0, .width = 200, .height = 48 }, "Files", true, accessibility.root_id);
    try frame.treeItem(2, row, "src", .{ .control = .{ .semantic_parent = 1, .radio_group = 1 }, .selected = true, .cursor = true, .multiple = true, .expanded = true });
    try frame.treeItem(3, .{ .x = 0, .y = 24, .width = 200, .height = 24 }, "main.zig", .{ .control = .{ .semantic_parent = 2, .radio_group = 1 }, .multiple = true, .level = 1 });
    try frame.dataTable(4, .{ .x = 0, .y = 60, .width = 200, .height = 60 }, "Parts", false, accessibility.root_id);
    try frame.tableHeader(5, .{ .x = 0, .y = 60, .width = 200, .height = 30 }, 4);
    try frame.columnHeader(6, .{ .x = 0, .y = 60, .width = 100, .height = 30 }, "Name", .descending, true, .{ .semantic_parent = 5 });
    try frame.columnHeader(7, .{ .x = 100, .y = 60, .width = 100, .height = 30 }, "Note", null, false, .{ .semantic_parent = 5 });
    try frame.tableRow(8, .{ .x = 0, .y = 90, .width = 200, .height = 30 }, "Bolts", .{ .control = .{ .semantic_parent = 4, .radio_group = 4 }, .cursor = true });
    try frame.tokenField(9, .{ .x = 0, .y = 130, .width = 200, .height = 30 }, "Tags", accessibility.root_id);
    try frame.tokenItem(10, 11, .{ .x = 0, .y = 130, .width = 80, .height = 30 }, "zig", .{ .control = .{ .semantic_parent = 9, .radio_group = 9 } });
    // The sortable header takes presses; the other one does not.
    context.input_state.down(.{ .x = 10, .y = 70 });
    try std.testing.expectEqual(@as(?u64, 6), context.input_state.active);
    context.input_state.cancelPress();
    context.input_state.down(.{ .x = 150, .y = 70 });
    try std.testing.expectEqual(@as(?u64, null), context.input_state.active);
    context.input_state.cancelPress();
    // The end of a token is its remove button.
    context.input_state.down(.{ .x = 78, .y = 140 });
    try std.testing.expectEqual(@as(?u64, 11), context.input_state.active);
    context.input_state.cancelPress();
    if (build_options.accessibility) {
        const nodes = context.semantic_tree.entries[0..context.semantic_tree.len];
        const expected = [_]accessibility.Role{ .tree, .tree_item, .tree_item, .table, .table_header, .column_header, .column_header, .table_row, .token_field, .token, .button };
        for (expected, nodes[1..][0..expected.len]) |role, node| try std.testing.expectEqual(role, node.role);
        try std.testing.expect(nodes[1].multiple and !nodes[4].multiple);
        try std.testing.expect(nodes[2].checked and nodes[2].expanded.?);
        try std.testing.expectEqual(@as(?bool, null), nodes[3].expanded);
        try std.testing.expectEqual(@as(?u64, 2), nodes[3].parent);
        const text = context.semantic_tree.storage[0..];
        try std.testing.expectEqualStrings("descending", text[nodes[6].value_start..][0..nodes[6].value_len]);
        try std.testing.expectEqual(@as(usize, 0), nodes[7].value_len);
        try std.testing.expectEqual(@as(?u64, 10), nodes[11].parent);
    }
}

test "dialogs make earlier content inert and mixed checkboxes report their state" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    if (build_options.accessibility) {
        context.attached_semantics_enabled = true;
        try context.semantic_tree.reset("Dialogs", .{ .x = 0, .y = 0, .width = 300, .height = 300 });
    }
    var frame: Frame = .{ .context = &context, .size = .{ .width = 300, .height = 300, .scale = 1 } };
    const start = frame.inertMark();
    try frame.button(1, .{ .x = 0, .y = 0, .width = 100, .height = 30 }, "Behind");
    try frame.checkbox(2, .{ .x = 0, .y = 40, .width = 100, .height = 30 }, "All", false, .{ .mixed = true });
    const behind = frame.inertMark();
    try frame.dialog(3, .{ .x = 50, .y = 100, .width = 200, .height = 100 }, "Delete", "This cannot be undone.", true, accessibility.root_id);
    try frame.buttonWithOptions(4, .{ .x = 60, .y = 150, .width = 80, .height = 30 }, "Cancel", .{ .semantic_parent = 3 });
    frame.makeInert(start, behind);
    // Content behind the dialog takes no press or focus.
    context.input_state.down(.{ .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(?u64, null), context.input_state.active);
    context.input_state.cancelPress();
    // The dialog's background occludes, and its own controls still work.
    context.input_state.down(.{ .x = 200, .y = 110 });
    try std.testing.expectEqual(@as(?u64, null), context.input_state.active);
    context.input_state.cancelPress();
    context.input_state.down(.{ .x = 70, .y = 160 });
    try std.testing.expectEqual(@as(?u64, 4), context.input_state.active);
    context.input_state.cancelPress();
    if (build_options.accessibility) {
        const nodes = context.semantic_tree.entries[0..context.semantic_tree.len];
        try std.testing.expect(nodes[0].enabled);
        try std.testing.expect(!nodes[1].enabled and !nodes[2].enabled);
        try std.testing.expect(nodes[2].mixed and !nodes[2].checked);
        try std.testing.expectEqual(accessibility.Role.alert_dialog, nodes[3].role);
        const text = context.semantic_tree.storage[0..];
        try std.testing.expectEqualStrings("This cannot be undone.", text[nodes[3].description_start..][0..nodes[3].description_len]);
        try std.testing.expect(nodes[4].enabled);
        try std.testing.expectEqual(@as(?u64, 3), nodes[4].parent);
    }
}

fn testWorkspace(context: *Context, size: z.Size) !*TransformWorkspace {
    const workspace = try std.testing.allocator.create(TransformWorkspace);
    workspace.* = .{ .allocator = std.testing.allocator, .options = .{ .layers = .{ .size = size, .max_depth = 4 }, .source_size = .{ .width = 512, .height = 512 } } };
    context.transforms = workspace;
    context.space_binding_epoch += 1;
    return workspace;
}

test "retained Space binding follows fronts but never a recreated workspace" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    const other = try app.createWindow(.{});
    defer _ = other.destroy() catch unreachable;
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    context.window = window;
    context.attachment_phase = .attached;
    defer if (context.transforms != null) context.dropTransformMetadata();
    defer context.command_buffer.reset();
    const workspace = try testWorkspace(&context, .{ .width = 100, .height = 100, .scale = 1 });
    var frame = try testFrame(&context, workspace, 1);
    try frame.captureSpace(9, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    context.commitFrame(window);
    const token = try context.committedSpace(9);
    const binding = try token.binding();
    try std.testing.expectError(error.ForeignWindow, binding.checkWindow(other));
    frame = try testFrame(&context, workspace, 2);
    try frame.pushOffset(.{ .x = 30 });
    try frame.captureSpace(9, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    try frame.popOffset();
    context.commitFrame(window);
    try std.testing.expectError(error.StaleSpace, token.binding());
    try std.testing.expectEqual(@as(u64, 2), (try binding.resolve()).generation);
    try std.testing.expectEqual(@as(f32, 0), (try (try binding.resolve()).localPoint(.{ .x = 30, .y = 0 })).x);
    _ = try testFrame(&context, workspace, 3);
    workspace.state.cancelFrame();
    context.input_state.cancelFrame();
    try std.testing.expectEqual(@as(u64, 2), (try binding.resolve()).generation);
    _ = try testFrame(&context, workspace, 3);
    context.commitFrame(window);
    try std.testing.expectError(error.SpaceNotFound, binding.resolve());
    context.command_buffer.reset();
    context.dropTransformMetadata();
    const next_workspace = try testWorkspace(&context, .{ .width = 100, .height = 100, .scale = 1 });
    frame = try testFrame(&context, next_workspace, context.space_generation + 1);
    try frame.captureSpace(9, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    context.commitFrame(window);
    try std.testing.expectError(error.StaleSpace, binding.resolve());
    _ = try context.committedSpace(9);
}

test "Context source hooks pin the old entry and require a matching begin" {
    const Host = struct {
        context: *Context,
        token: ?AccessibilitySourceToken = null,
        unbound: usize = 0,
        phases: [2]usize = .{ 0, 0 },
        moves: usize = 0,
        clear_query: bool = false,
        clear_begin: bool = false,
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn query(ptr: *anyopaque, _: z.Window, _: usize, _: isize) ?isize {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.clear_query) {
                std.debug.assert(self.context.clearAccessibilitySource(self.token.?) catch unreachable);
                std.debug.assert(self.unbound == 0);
            }
            return 17;
        }
        fn phase(ptr: *anyopaque, _: z.Window, value: AccessibilityPhase) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.phases[@intFromEnum(value)] += 1;
            if (value == .frame_begin and self.clear_begin) std.debug.assert(self.context.clearAccessibilitySource(self.token.?) catch unreachable);
        }
        fn position(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.moves += 1;
        }
        fn released(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.unbound += 1;
        }
        fn source(self: *@This()) AccessibilitySource {
            return .{ .context = self, .query = query, .phase = phase, .position_changed = position, .unbound = released };
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Host.draw, Host.action);
    context.window = window;
    context.attachment_phase = .attached;
    defer context.accessibility_source_state.close();
    var host: Host = .{ .context = &context, .clear_query = true };
    host.token = try context.installAccessibilitySource(host.source());
    try std.testing.expectEqual(@as(?isize, 17), Context.getAccessibility(&context, window, 0, -25));
    try std.testing.expectEqual(@as(usize, 1), host.unbound);
    host.clear_query = false;
    host.token = try context.installAccessibilitySource(host.source());
    context.accessibilityPositionChanged(window);
    try std.testing.expectEqual(@as(usize, 1), host.moves);
    try std.testing.expect(context.accessibilityPhase(window, .frame_begin));
    context.frame_accessibility_source = host.token.?.generation;
    context.commitFrame(window);
    try std.testing.expectEqualDeep([2]usize{ 1, 1 }, host.phases);
    host.token = try context.installAccessibilitySource(host.source());
    context.commitFrame(window);
    try std.testing.expectEqual(@as(usize, 1), host.phases[1]);
    host.clear_begin = true;
    try std.testing.expect(!context.accessibilityPhase(window, .frame_begin));
    try std.testing.expectEqual(@as(usize, 3), host.unbound);
}
fn testFrame(context: *Context, workspace: *TransformWorkspace, generation: u64) !Frame {
    context.command_buffer.reset();
    const size = workspace.options.?.layers.size;
    try workspace.begin(size, generation);
    try context.command_buffer.bindTransformStorage(&workspace.command_storage);
    context.input_state.beginMappedFrame(try workspace.state.pending());
    return .{ .context = context, .size = size, .transforms = workspace };
}

test "affine Frame preserves source extent, parent clips and parent offsets" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    const workspace = try testWorkspace(&context, .{ .width = 100, .height = 100, .scale = 1 });
    defer context.dropTransformMetadata();
    defer context.command_buffer.reset();
    var frame = try testFrame(&context, workspace, 1);
    try frame.pushClip(.{ .x = 0, .y = 0, .width = 100, .height = 100 });
    try frame.pushOffset(.{ .x = 5, .y = 10 });
    try frame.beginTransform(.{ .width = 200, .height = 40 }, .{ .x0 = -100, .y0 = 20 });
    try std.testing.expectEqual(@as(u32, 200), frame.size.width);
    try std.testing.expectEqual(@as(u32, 100), frame.windowSize().width);
    try std.testing.expectEqual(@as(f32, 200), frame.sourceBounds().width);
    try frame.button(1, .{ .x = 100, .y = 0, .width = 20, .height = 20 }, "Moved in");
    try frame.captureSpace(50, .{ .x = 100, .y = 0, .width = 20, .height = 20 });
    try frame.endTransform();
    try std.testing.expectEqualDeep(layout.Point{ .x = 5, .y = 10 }, frame.offset);
    try frame.popOffset();
    try frame.popClip();
    try context.command_buffer.finish();
    _ = try workspace.state.commitFrame();
    context.input_state.commitFrame();
    try std.testing.expectEqual(@as(?u64, 1), context.input_state.hit(.{ .x = 15, .y = 40 }));
    try std.testing.expect(context.input_state.hit(.{ .x = 110, .y = 10 }) == null);
    const descriptor = workspace.command_storage.storage[0];
    try std.testing.expectEqual(@as(f64, -95), descriptor.x0);
    try std.testing.expectEqual(@as(f64, 30), descriptor.y0);
}

test "semantic local bounds has an explicit Frame query" {
    try std.testing.expect(@hasDecl(Frame, "semanticLocalBounds"));
}

const SemanticQueryFixture = struct {
    app: *z.App = undefined,
    window: z.Window = undefined,
    context: Context = undefined,
    tree: accessibility.Tree = .{},
    frame: Frame = undefined,
    workspace: *TransformWorkspace = undefined,
    marker: u8 = 0,
    fn draw(_: *anyopaque, _: *Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
    fn query(_: *anyopaque, _: z.Window, _: usize, _: isize) ?isize {
        return null;
    }
    fn init(self: *@This(), allocator: std.mem.Allocator) !void {
        self.app = try z.App.init(std.testing.allocator);
        self.window = try self.app.createWindow(.{});
        self.context = Context.init(&self.marker, draw, action);
        self.context.window = self.window;
        self.context.attachment_phase = .attached;
        const source = try self.context.installAccessibilitySource(.{ .context = &self.marker, .query = query });
        self.context.frame_accessibility_source = source.generation;
        self.context.painting = true;
        self.workspace = try allocator.create(TransformWorkspace);
        self.workspace.* = .{ .allocator = allocator, .options = .{ .layers = .{ .size = .{ .width = 100, .height = 100, .scale = 1 }, .max_depth = 4 }, .source_size = .{ .width = 512, .height = 512 } } };
        self.context.transforms = self.workspace;
        self.context.space_binding_epoch += 1;
        try self.context.accessibility_source_state.beginFrame();
        self.frame = try testFrame(&self.context, self.workspace, 1);
        const root: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
        try self.tree.reset("Frame", root);
        const snapshot = try self.workspace.state.pending();
        try snapshot.addSemantic(.{}, affine.Rect.from(root));
        self.tree.mapped = snapshot;
    }
    fn deinit(self: *@This()) void {
        self.context.painting = false;
        self.context.accessibility_source_state.close();
        self.context.command_buffer.reset();
        // This fixture installs no native widget Bridge, including in Windows
        // tests that exercise the public wrapper with its actual Context Tree.
        self.context.attached_semantics_enabled = false;
        self.context.dropTransformMetadata();
        _ = self.window.destroy() catch unreachable;
        self.app.deinit();
    }
    fn record(self: *@This(), id: u64, local: Rect) !void {
        // Independent spelling of Frame.semantic's record-time f32 offset
        // contract; Tree.bounds contains only the actual clipped window AABB.
        const raw: affine.Rect = .{ .x = @as(f32, local.x + self.frame.offset.x), .y = @as(f32, local.y + self.frame.offset.y), .width = local.width, .height = local.height };
        const snapshot = try self.workspace.state.pending();
        const visible = try snapshot.geometry.visibleBounds(self.workspace.reference, raw);
        try self.tree.addMapped(.{ .id = id, .role = .button, .name = "Control", .bounds = if (visible) |bounds| nativeRect(bounds) else .{ .x = 0, .y = 0, .width = 0, .height = 0 } }, self.workspace.reference, raw);
    }
};

test "semantic batch exports actual descriptors under rotation shear reflection clip and changed offset" {
    const matrices = [_]affine.Affine{
        .{ .xx = 0, .yx = 1, .xy = -1, .yy = 0, .x0 = 85, .y0 = 5 },
        .{ .xy = 0.5, .x0 = 5, .y0 = 5 },
        .{ .xx = -1, .x0 = 90, .y0 = 5 },
    };
    for (matrices) |matrix| {
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var fixture: SemanticQueryFixture = .{};
        try fixture.init(allocator.allocator());
        defer fixture.deinit();
        try fixture.frame.pushClip(.{ .x = 15, .y = 5, .width = 60, .height = 70 });
        try fixture.frame.beginTransform(.{ .width = 80, .height = 60 }, matrix);
        try fixture.frame.pushOffset(.{ .x = 6, .y = 8 });
        try fixture.record(7, .{ .x = 2, .y = 4, .width = 20, .height = 12 });
        try fixture.frame.popOffset();
        try fixture.frame.pushOffset(.{ .x = 2, .y = 3 });
        try fixture.record(8, .{ .x = 10, .y = 12, .width = 18, .height = 9 });
        const before = (try fixture.workspace.state.pending()).checkpoint();
        const used = fixture.tree.used;
        const commands_before = fixture.context.command_buffer.len;
        const allocated = allocator.alloc_index;
        allocator.fail_index = allocated;
        allocator.resize_fail_index = allocator.resize_index;
        const untouched: Rect = .{ .x = -999, .y = 0, .width = 0, .height = 0 };
        var output: [3]Rect = @splat(untouched);
        try fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{ 7, 8 }, &output);
        try std.testing.expectEqualDeep(Rect{ .x = 6, .y = 9, .width = 20, .height = 12 }, output[0]);
        try std.testing.expectEqualDeep(Rect{ .x = 10, .y = 12, .width = 18, .height = 9 }, output[1]);
        try std.testing.expectEqualDeep(untouched, output[2]);
        var mapping: CoordinateMapping = undefined;
        try fixture.frame.coordinateMapping(output[0], &mapping);
        const space = try (try fixture.workspace.state.pending()).geometry.getSpace(fixture.workspace.reference.space);
        const expected = try space.windowPoint(.{ .x = 8, .y = 12 });
        try std.testing.expectEqualDeep(expected, try mapping.space.windowPoint(.{ .x = output[0].x, .y = output[0].y }));
        var visible: affine.Polygon = .{};
        try (try fixture.workspace.state.pending()).geometry.visiblePolygon(fixture.workspace.reference, .{ .x = 8, .y = 12, .width = 20, .height = 12 }, &visible);
        try visible.clipBounds(.{ .width = 100, .height = 100 }, &visible);
        try std.testing.expectEqualSlices(affine.Point, visible.points(), mapping.visible.points());
        try fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{}, &.{});
        var repeated: [65]Rect = undefined;
        const ids: [65]u64 = @splat(7);
        try fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &ids, &repeated);
        for (repeated) |bounds| try std.testing.expectEqualDeep(output[0], bounds);
        if (build_options.accessibility) {
            fixture.context.semantic_tree = fixture.tree;
            fixture.context.attached_semantics_enabled = true;
            var actual: [2]Rect = undefined;
            try fixture.frame.semanticLocalBounds(&.{ 7, 8 }, &actual);
            try std.testing.expectEqualDeep(output[0], actual[0]);
            try std.testing.expectEqualDeep(output[1], actual[1]);
            fixture.context.attached_semantics_enabled = false;
        } else try std.testing.expectError(error.SemanticGeometryRequired, fixture.frame.semanticLocalBounds(&.{7}, &output));
        try std.testing.expectEqual(allocated, allocator.alloc_index);
        try std.testing.expect(!allocator.has_induced_failure);
        try std.testing.expectEqual(used, fixture.tree.used);
        try std.testing.expectEqual(commands_before, fixture.context.command_buffer.len);
        try std.testing.expectEqualDeep(before, (try fixture.workspace.state.pending()).checkpoint());
    }
}

test "semantic batch is atomic for capacity missing ids malformed peers and foreign scope" {
    var fixture: SemanticQueryFixture = .{};
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    try fixture.record(7, .{ .x = 8, .y = 12, .width = 20, .height = 12 });
    try fixture.record(8, .{ .x = 30, .y = 12, .width = 10, .height = 12 });
    const snapshot = try fixture.workspace.state.pending();
    const before = snapshot.checkpoint();
    const poison: Rect = .{ .x = -111, .y = 222, .width = 3, .height = 4 };
    var output: [2]Rect = @splat(poison);
    try std.testing.expectError(error.MissingSemanticNode, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{ 7, 999 }, &output));
    try std.testing.expectError(error.SemanticExportCapacityExceeded, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{ 7, 8 }, output[0..1]));
    const excessive: [*]const u64 = @ptrFromInt(4096);
    try std.testing.expectError(error.SemanticExportCapacityExceeded, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, excessive[0..129], &output));
    fixture.tree.entries[2].parent = 999;
    try std.testing.expectError(error.MissingSemanticParent, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    fixture.tree.entries[2].parent = 0;
    fixture.tree.entries[2].id = 7;
    try std.testing.expectError(error.DuplicateSemanticId, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    fixture.tree.entries[2].id = 8;
    const name_start = fixture.tree.entries[2].name_start;
    fixture.tree.storage[name_start] = 0xff;
    try std.testing.expectError(error.InvalidUtf8, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    fixture.tree.storage[name_start] = 'C';
    snapshot.semantic_len -= 1;
    try std.testing.expectError(error.InvalidSemanticGeometry, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    snapshot.semantic_len += 1;
    fixture.tree.mapped = &fixture.workspace.state.snapshots[fixture.workspace.state.front];
    try std.testing.expectError(error.InvalidSemanticGeometry, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    fixture.tree.mapped = snapshot;
    snapshot.semantics[2].reference.space = @enumFromInt(999);
    try std.testing.expectError(error.InvalidSpace, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    snapshot.semantics[2].reference.space = .identity;
    snapshot.semantics[2].reference.clip = @enumFromInt(999);
    try std.testing.expectError(error.InvalidClip, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    snapshot.semantics[2].reference.clip = null;
    snapshot.semantics[2].local_bounds.width = -1;
    try std.testing.expectError(error.InvalidGeometry, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    snapshot.semantics[2].local_bounds.width = 10;
    try std.testing.expectEqualDeep(before, snapshot.checkpoint());
    const peer_space = try snapshot.geometry.addChild(.identity, .{ .x0 = 1 });
    snapshot.semantics[2].reference.space = peer_space;
    const peer_before = snapshot.checkpoint();
    try std.testing.expectError(error.SemanticScopeMismatch, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{ 7, 8 }, &output));
    try std.testing.expectEqualDeep(peer_before, snapshot.checkpoint());
    snapshot.semantics[2].reference.space = .identity;
    try fixture.frame.pushClip(.{ .x = 0, .y = 0, .width = 50, .height = 50 });
    const clipped = snapshot.checkpoint();
    try std.testing.expectError(error.SemanticScopeMismatch, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    try std.testing.expectEqualDeep(clipped, snapshot.checkpoint());
    try fixture.frame.popClip();
    try fixture.frame.beginTransform(.{ .width = 40, .height = 40 }, .{ .xy = 0.25 });
    try std.testing.expectError(error.SemanticScopeMismatch, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    try fixture.frame.endTransform();
    for (output) |value| try std.testing.expectEqualDeep(poison, value);
    try std.testing.expect(fixture.frame.failure == null);
}

test "semantic rebasing rejects f32 precision loss instead of silently moving a descriptor" {
    var fixture: SemanticQueryFixture = .{};
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    try fixture.record(7, .{ .x = 8, .y = 12, .width = 20, .height = 12 });
    const snapshot = try fixture.workspace.state.pending();
    const poison: Rect = .{ .x = 55, .y = 66, .width = 77, .height = 88 };
    var output: [2]Rect = @splat(poison);
    try fixture.frame.pushOffset(.{ .x = 1073741824 });
    try std.testing.expectError(error.InvalidGeometry, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    // The large offset itself is valid when both origins and edges are exact.
    snapshot.semantics[1].local_bounds.x = 0;
    snapshot.semantics[1].local_bounds.width = 16;
    var exact: [1]Rect = undefined;
    try fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &exact);
    try std.testing.expectEqualDeep(Rect{ .x = -1073741824, .y = 12, .width = 16, .height = 12 }, exact[0]);
    try fixture.frame.popOffset();
    // Even when f32 absolute() would round back to the stored raw x, the
    // double translation used by coordinateMapping must recover it exactly.
    try fixture.frame.pushOffset(.{ .x = 0.1 });
    snapshot.semantics[1].local_bounds.x = 100000000;
    try std.testing.expectError(error.InvalidGeometry, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    try fixture.frame.popOffset();
    // Origin and width can each round-trip while (local.x + width) loses
    // precision before the mapping's offset cancellation. Reject that edge.
    snapshot.semantics[1].local_bounds.x = 0;
    snapshot.semantics[1].local_bounds.width = @as(f32, 0.1);
    try fixture.frame.pushOffset(.{ .x = 1073741824 });
    try std.testing.expectError(error.InvalidGeometry, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    try fixture.frame.popOffset();
    snapshot.semantics[1].local_bounds.x = 8;
    snapshot.semantics[1].local_bounds.width = 1.0 / 3.0;
    try std.testing.expectError(error.InvalidGeometry, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    snapshot.semantics[1].local_bounds.width = 20;
    for (output) |value| try std.testing.expectEqualDeep(poison, value);
}

test "semantic export and mapping share live source candidate thread and pending authority" {
    var fixture: SemanticQueryFixture = .{};
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    try fixture.record(7, .{ .x = 8, .y = 12, .width = 20, .height = 12 });
    const snapshot = try fixture.workspace.state.pending();
    const poison: Rect = .{ .x = -111, .y = 0, .width = 0, .height = 0 };
    var output: [1]Rect = .{poison};
    const Worker = struct {
        fixture: *SemanticQueryFixture,
        output: *[1]Rect,
        failure: ?anyerror = null,
        public_failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.fixture.frame.semanticLocalBoundsFrom(&self.fixture.tree, &.{7}, self.output) catch |err| {
                self.failure = err;
            };
            self.fixture.frame.semanticLocalBounds(&.{7}, self.output) catch |err| {
                self.public_failure = err;
            };
        }
    };
    var worker: Worker = .{ .fixture = &fixture, .output = &output };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    try std.testing.expectEqual(error.WrongThread, worker.failure.?);
    try std.testing.expectEqual(error.WrongThread, worker.public_failure.?);
    fixture.context.painting = false;
    try std.testing.expectError(error.NoFrame, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    try std.testing.expectError(error.NoFrame, fixture.frame.semanticLocalBounds(&.{7}, &output));
    fixture.context.painting = true;
    const candidate = fixture.context.accessibility_source_state.frame_candidate;
    fixture.context.accessibility_source_state.frame_candidate = 0;
    try std.testing.expectError(error.NoFrame, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    fixture.context.accessibility_source_state.frame_candidate = candidate;
    snapshot.generation += 1;
    try std.testing.expectError(error.StaleGeometry, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    var mapping: CoordinateMapping = undefined;
    try std.testing.expectError(error.StaleGeometry, fixture.frame.coordinateMapping(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, &mapping));
    snapshot.generation -= 1;
    fixture.frame.transforms = null;
    try std.testing.expectError(error.StaleGeometry, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    fixture.frame.transforms = fixture.workspace;
    fixture.frame.failure = error.GeometryOverflow;
    try std.testing.expectError(error.GeometryOverflow, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    fixture.frame.failure = null;
    _ = try fixture.context.installAccessibilitySource(.{ .context = &fixture.marker, .query = SemanticQueryFixture.query });
    try std.testing.expectError(error.StaleGeometry, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    fixture.context.frame_accessibility_source = fixture.context.accessibility_source_state.currentGeneration();
    const phase = fixture.app.phase;
    fixture.app.phase = .stopping;
    try std.testing.expectError(error.Closed, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    try std.testing.expectError(error.Closed, fixture.frame.semanticLocalBounds(&.{7}, &output));
    fixture.app.phase = phase;
    fixture.workspace.state.cancelFrame();
    try std.testing.expectError(error.NoFrame, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    const scope = fixture.window.beginCallback().?;
    _ = try fixture.window.destroy();
    try std.testing.expectError(error.Closed, fixture.frame.semanticLocalBoundsFrom(&fixture.tree, &.{7}, &output));
    try std.testing.expectError(error.Closed, fixture.frame.semanticLocalBounds(&.{7}, &output));
    scope.end();
    try std.testing.expectEqualDeep(poison, output[0]);
}

test "one-bound coordinate mappings share successful front and exact convex clip identity" {
    const Host = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn query(_: *anyopaque, _: z.Window, _: usize, _: isize) ?isize {
            return null;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Host.draw, Host.action);
    context.window = window;
    context.attachment_phase = .attached;
    const source = try context.installAccessibilitySource(.{ .context = &dummy, .query = Host.query });
    defer context.accessibility_source_state.close();
    context.frame_accessibility_source = source.generation;
    context.painting = true;
    defer context.painting = false;
    const workspace = try testWorkspace(&context, .{ .width = 100, .height = 100, .scale = 1 });
    defer context.dropTransformMetadata();
    defer context.command_buffer.reset();
    try context.accessibility_source_state.beginFrame();
    var frame = try testFrame(&context, workspace, 1);
    try frame.pushClip(.{ .x = 0, .y = 0, .width = 50, .height = 80 });
    try frame.beginTransform(.{ .width = 100, .height = 40 }, .{ .xy = 0.5, .x0 = 10, .y0 = 5 });
    try frame.pushOffset(.{ .x = 2, .y = 3 });
    const checkpoint = (try workspace.state.pending()).checkpoint();
    var mapping: CoordinateMapping = undefined;
    try frame.coordinateMapping(.{ .x = 0, .y = 0, .width = 60, .height = 30 }, &mapping);
    try std.testing.expectEqualDeep(checkpoint, (try workspace.state.pending()).checkpoint());
    try std.testing.expectApproxEqAbs(@as(f64, 13.5), mapping.space.to_window.x0, 1e-9);
    const clipped = mapping.visible.bounds().?;
    try std.testing.expectApproxEqAbs(@as(f64, 50), clipped.x + clipped.width, 1e-9);
    try std.testing.expectError(error.StaleGeometry, mapping.checkCommitted(&context));
    const before = mapping;
    try std.testing.expectError(error.InvalidGeometry, frame.coordinateMapping(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, &mapping));
    try std.testing.expectEqual(before.context, mapping.context);
    try std.testing.expectEqual(before.candidate, mapping.candidate);
    try std.testing.expectEqualDeep(before.space, mapping.space);
    try std.testing.expectEqualSlices(affine.Point, before.visible.points(), mapping.visible.points());
    try frame.popOffset();
    try frame.endTransform();
    try frame.popClip();
    context.commitFrame(window);
    try mapping.checkCommitted(&context);
    try context.accessibility_source_state.beginFrame();
    try std.testing.expectError(error.StaleGeometry, mapping.checkCommitted(&context));
    _ = try context.clearAccessibilitySource(source);
    try std.testing.expectError(error.StaleGeometry, mapping.checkCommitted(&context));
}

test "affine Frame errors roll back candidates and cannot steal parent clips" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    const workspace = try testWorkspace(&context, .{ .width = 100, .height = 100, .scale = 1 });
    defer context.dropTransformMetadata();
    defer context.command_buffer.reset();
    var frame = try testFrame(&context, workspace, 1);
    const mark = (try workspace.state.pending()).checkpoint();
    try std.testing.expectError(error.TransformSourceExceeded, frame.beginTransform(.{ .width = 600, .height = 10 }, .{}));
    try std.testing.expectEqualDeep(mark, (try workspace.state.pending()).checkpoint());
    try std.testing.expectEqual(@as(usize, 0), context.command_buffer.len);
    workspace.state.cancelFrame();
    frame = try testFrame(&context, workspace, 1);
    try frame.pushClip(.{ .x = 0, .y = 0, .width = 100, .height = 100 });
    try frame.beginTransform(.{ .width = 20, .height = 20 }, .{});
    try std.testing.expectError(error.ClipStackEmpty, frame.popClip());
    try std.testing.expectEqual(@as(usize, 1), context.command_buffer.depth);
    try frame.pushOffset(.{ .x = 2, .y = 3 });
    try std.testing.expectError(error.UnbalancedTransform, frame.endTransform());
    try std.testing.expectEqual(@as(usize, 1), workspace.depth);
    try frame.popOffset();
    try frame.endTransform();
    try frame.popClip();
    try std.testing.expectEqual(error.UnbalancedTransform, frame.failure.?);
    try context.command_buffer.finish();
}

test "captured Space includes pushOffset and capture errors are transactional" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    const workspace = try testWorkspace(&context, .{ .width = 100, .height = 100, .scale = 1 });
    defer context.dropTransformMetadata();
    defer context.command_buffer.reset();
    var frame = try testFrame(&context, workspace, 1);
    try frame.pushOffset(.{ .x = 5, .y = 7 });
    try frame.captureSpace(50, .{ .x = 0, .y = 0, .width = 20, .height = 10 });
    const snapshot = try workspace.state.pending();
    const mark = snapshot.checkpoint();
    try std.testing.expectError(error.DuplicateSpaceId, frame.captureSpace(50, .{ .x = 0, .y = 0, .width = 20, .height = 10 }));
    try std.testing.expectEqualDeep(mark, snapshot.checkpoint());
    const local = try (try snapshot.captureSpace(50)).localPoint(.{ .x = 8, .y = 9 });
    try std.testing.expectEqualDeep(affine.Point{ .x = 3, .y = 2 }, local);
    try frame.popOffset();
}

test "ordinary control focus cannot coexist with a retained native text client" {
    const Host = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn read(_: *anyopaque, _: z.Window, _: []u8) !z.text.Snapshot {
            return error.Unavailable;
        }
        fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
            return .applied;
        }
        fn unbound(_: *anyopaque, _: z.Window, _: z.text.UnbindReason) void {}
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Host.draw, Host.action);
    context.window = window;
    context.attachment_phase = .attached;
    try context.input_state.add(10, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    const client = try window.setTextClient(.{ .context = &dummy, .owner = app.owner, .read = Host.read, .change = Host.change, .unbound = Host.unbound });
    Context.accessibilityAction(&context, window, .{ .set_focus = 10 });
    try std.testing.expect(context.input_state.focused == null);
    Context.event(&context, window, .{ .pointer_down = .{ .position = .{ .x = 1, .y = 1 } } });
    try std.testing.expect(context.input_state.focused == null and context.input_state.active == null);
    _ = context.handleKeyInput(window, .{ .key = .tab });
    try std.testing.expect(context.input_state.focused == null);
    try std.testing.expect(try window.hasTextClient());
    _ = try window.clearTextClient(client);
}

test "focus handoff revalidates client ownership and accepted identity after native callbacks" {
    const Host = struct {
        context: *Context,
        mode: enum { client, removed, close, blur, nested },
        once: bool = false,
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn read(_: *anyopaque, _: z.Window, _: []u8) !z.text.Snapshot {
            return error.Unavailable;
        }
        fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
            return .applied;
        }
        fn unbound(_: *anyopaque, _: z.Window, _: z.text.UnbindReason) void {}
        fn detach(_: *anyopaque) void {}
        fn event(ptr: *anyopaque, window: z.Window, event_value: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (event_value != .window_state or self.once) return;
            self.once = true;
            std.testing.expect(self.context.input_state.focused == null) catch unreachable;
            switch (self.mode) {
                .client => {
                    _ = window.setTextClient(.{ .context = self, .owner = window.app.owner, .read = read, .change = change, .unbound = unbound }) catch unreachable;
                },
                .removed => {
                    self.context.input_state.beginFrame();
                    self.context.input_state.commitFrame();
                },
                .close => {
                    _ = window.destroy() catch unreachable;
                },
                .blur => self.context.blurControls() catch unreachable,
                .nested => std.testing.expectError(error.Busy, self.context.focusControl(10)) catch unreachable,
            }
        }
    };
    inline for (.{ .client, .removed, .close, .blur, .nested }) |mode| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        defer _ = window.destroy() catch unreachable;
        var dummy: u8 = 0;
        var context = Context.init(&dummy, Host.draw, Host.action);
        context.window = window;
        context.attachment_phase = .attached;
        try context.input_state.add(10, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
        context.input_state.focused = 10;
        var host: Host = .{ .context = &context, .mode = mode };
        try window.setContent(.{ .context = &host, .event = Host.event, .detach = Host.detach });
        if (host.mode == .nested) {
            try context.focusControl(10);
            try std.testing.expectEqual(@as(?u64, 10), context.input_state.focused);
            try context.blurControls();
        } else try std.testing.expectError(switch (host.mode) {
            .client => error.TextClientActive,
            .removed => error.ControlUnavailable,
            .close => error.Closed,
            .blur => error.FocusChanged,
            .nested => unreachable,
        }, context.focusControl(10));
        try std.testing.expect(host.once and context.input_state.focused == null);
    }
}

test "unhandled command shortcuts retain the document while range shortcuts cannot steal focus" {
    const Host = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(ptr: *anyopaque, _: u64) void {
            const count: *usize = @ptrCast(@alignCast(ptr));
            count.* += 1;
        }
        fn read(_: *anyopaque, _: z.Window, _: []u8) !z.text.Snapshot {
            return error.Unavailable;
        }
        fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
            return .applied;
        }
        fn unbound(_: *anyopaque, _: z.Window, _: z.text.UnbindReason) void {}
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var count: usize = 0;
    var context = Context.init(&count, Host.draw, Host.action);
    context.window = window;
    context.attachment_phase = .attached;
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    try context.input_state.addWithOptions(10, bounds, .{ .shortcut = .{ .key = .s, .modifiers = .{ .control = true } } });
    try context.input_state.addWithOptions(11, bounds, .{ .shortcut = .{ .key = .f9 }, .range = .{ .spec = .{ .minimum = 0, .maximum = 10 }, .track = bounds } });
    _ = try window.setTextClient(.{ .context = &count, .owner = app.owner, .read = Host.read, .change = Host.change, .unbound = Host.unbound });
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .s, .modifiers = .{ .control = true } }));
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(!context.handleKeyInput(window, .{ .key = .f9 }));
    try std.testing.expect(context.input_state.focused == null and try window.hasTextClient());
}

test "SpaceToken uses only accepted generations for events and native caret" {
    const Dummy = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn worker(token: SpaceToken) void {
            std.testing.expectError(error.WrongThread, token.localPoint(.{ .x = 0, .y = 0 })) catch unreachable;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Dummy.draw, Dummy.action);
    context.window = window;
    context.attachment_phase = .attached;
    const workspace = try testWorkspace(&context, .{ .width = 100, .height = 100, .scale = 1 });
    defer if (context.transforms != null) context.dropTransformMetadata();
    defer context.command_buffer.reset();
    var frame = try testFrame(&context, workspace, 1);
    try frame.beginTransform(.{ .width = 20, .height = 20 }, .{ .xx = 0, .xy = -2, .yx = 3, .yy = 0, .x0 = 50, .y0 = 10 });
    try frame.captureSpace(50, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    try frame.endTransform();
    try std.testing.expectError(error.StaleSpace, context.committedSpace(50));
    context.commitFrame(window);
    const token = try context.committedSpace(50);
    try std.testing.expect(try token.contains(.{ .x = 30, .y = 25 }));
    const press: z.PointerButtonInput = .{
        .position = .{ .x = 30, .y = 25 },
        .button = .secondary,
        .modifiers = .{ .shift = true, .control = true },
        .press = .{ .sequence = 71, .window_count = 3, .eligible = true, .qualified = true },
    };
    inline for (.{ .pointer_down, .pointer_up }) |tag| {
        const remapped = try token.mapEvent(@unionInit(z.Event, @tagName(tag), press), .{});
        var expected = press;
        expected.position = .{ .x = 5, .y = 10 };
        try std.testing.expectEqualDeep(expected, @field(remapped, @tagName(tag)));
    }
    const mapped = try token.mapEvent(.{ .wheel = .{ .position = .{ .x = 30, .y = 25 }, .delta = .{ .x = 0, .y = 6 } } }, .{});
    try std.testing.expectEqualDeep(z.Point{ .x = 5, .y = 10 }, mapped.wheel.position);
    try std.testing.expectEqualDeep(z.Point{ .x = 0, .y = 6 }, mapped.wheel.delta);
    const vector = try token.mapEvent(.{ .wheel = .{ .position = .{ .x = 30, .y = 25 }, .delta = .{ .x = 0, .y = 6 } } }, .{ .wheel = .local_vector });
    try std.testing.expectEqualDeep(z.Point{ .x = 2, .y = 0 }, vector.wheel.delta);
    try std.testing.expect(!(try token.contains(.{ .x = 100, .y = 100 })));
    _ = try token.mapEvent(.{ .pointer_move = .{ .x = 100, .y = 100 } }, .{});
    try token.setTextCaret(.{ .x = 1, .y = 2, .width = 1, .height = 3 });
    try token.setTextCaret(.{ .x = 1, .y = 2, .width = 0, .height = 3 });
    try std.testing.expectError(error.NotVisible, token.setTextCaret(.{ .x = 100, .y = 100, .width = 1, .height = 3 }));
    const worker = try std.Thread.spawn(.{}, Dummy.worker, .{token});
    worker.join();
    try std.testing.expectError(error.ResourceInUse, context.releaseTransforms());
    context.command_buffer.reset();
    frame = try testFrame(&context, workspace, 2);
    context.commitFrame(window);
    try std.testing.expectError(error.StaleSpace, token.localPoint(.{ .x = 30, .y = 25 }));
    context.command_buffer.reset();
    try context.releaseTransforms();
    try std.testing.expect(context.transforms == null);
    try std.testing.expectError(error.StaleSpace, token.contains(.{ .x = 30, .y = 25 }));
    _ = try window.destroy();
    context.window = null;
    context.attachment_phase = .detached;
}

test "Frame gradient coverage translates mask and brush once without changing frame scopes" {
    const Callbacks = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var state: u8 = 0;
    var context = Context.init(&state, Callbacks.draw, Callbacks.action);
    defer context.command_buffer.reset();
    var frame: Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 }, .offset = .{ .x = 3, .y = 5 } };
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = [_]u8{255};
    var view: drawing.CoverageView = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &bytes, .width = 1, .height = 1, .stride = 1, .origin_x = -2, .origin_y = 4, .scale = 1 } };
    const stops = [_]commands.brushes.Stop{ .{ .offset = 0, .color = Color.rgb(0) }, .{ .offset = 1, .color = Color.rgb(0xffffff) } };
    const gradient: commands.Gradient = .{ .linear = .{ .start = .{ .x = 13, .y = 17 }, .end = .{ .x = 19, .y = 23 }, .stops = &stops } };
    const clip = frame.clipBounds();
    try frame.gradientCoverage(.{ .x = 7, .y = 11 }, view, gradient);
    try std.testing.expectEqual(@as(usize, 3), context.command_buffer.len);
    try std.testing.expectEqualDeep(drawing.Point{ .x = 10, .y = 16 }, context.command_buffer.commands()[0].begin_group.mask_origin);
    const brush = context.command_buffer.brushResources()[0];
    try std.testing.expectEqualDeep(layout.Point{ .x = 16, .y = 22 }, brush.a);
    try std.testing.expectEqualDeep(layout.Point{ .x = 22, .y = 28 }, brush.b);
    try std.testing.expect(frame.group_depth == 0 and frame.offset_depth == 0 and frame.transforms == null and std.meta.eql(clip, frame.clipBounds()));
    view.coverage.scale = 2;
    try std.testing.expectError(error.CoverageDpiMismatch, frame.gradientCoverage(.{}, view, gradient));
    try std.testing.expect(frame.failure.? == error.CoverageDpiMismatch);
    try std.testing.expectEqual(@as(usize, 3), context.command_buffer.len);
    context.command_buffer.reset();
    try lease.ensureUnused();
}

test "metadata coordinates prepare one bounded owner and no renderer planes" {
    const Callbacks = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var state: u8 = 0;
    var context = Context.init(&state, Callbacks.draw, Callbacks.action);
    context.window = window;
    context.attachment_phase = .attached;
    defer if (context.transforms != null) context.dropTransformMetadata();
    defer context.command_buffer.reset();
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try std.testing.expectError(error.InvalidCoordinateLimits, context.prepareCoordinates(allocator.allocator(), .{ .bytes = 0 }));
    try std.testing.expectError(error.CoordinateBudgetExceeded, context.prepareCoordinates(allocator.allocator(), .{ .bytes = @sizeOf(TransformWorkspace) - 1 }));
    try std.testing.expectEqual(@as(usize, 0), allocator.alloc_index);
    try context.prepareCoordinates(allocator.allocator(), .{ .bytes = @sizeOf(TransformWorkspace) });
    try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
    const workspace = context.transforms.?;
    const epoch = context.space_binding_epoch;
    try context.prepareCoordinates(allocator.allocator(), .{});
    try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
    try std.testing.expect(context.transforms.? == workspace and workspace.options == null);
    const stats = try context.transformStats();
    try std.testing.expectEqual(@as(usize, @sizeOf(TransformWorkspace)), stats.metadata_bytes);
    try std.testing.expect(!stats.layers.software.prepared and stats.layers.current_bytes == 0);
    try std.testing.expectEqual(@as(u32, 0), stats.layers.software.native_objects);
    if (stats.layers.gpu) |gpu| try std.testing.expect(!gpu.prepared and gpu.pixel_bytes == 0 and gpu.native_objects == 0);

    const size: z.Size = .{ .width = 80, .height = 60, .scale = 1 };
    try workspace.begin(size, 1);
    try context.command_buffer.bindTransformStorage(&workspace.command_storage);
    context.input_state.beginMappedFrame(try workspace.state.pending());
    var frame: Frame = .{ .context = &context, .size = size, .transforms = workspace };
    const before = (try workspace.state.pending()).checkpoint();
    try std.testing.expectError(error.TransformsNotPrepared, frame.beginTransform(.{ .width = 20, .height = 20 }, .{}));
    try std.testing.expectEqualDeep(before, (try workspace.state.pending()).checkpoint());
    try std.testing.expectEqual(@as(usize, 0), context.command_buffer.len);
    context.input_state.cancelFrame();
    workspace.state.cancelFrame();

    try workspace.begin(size, 1);
    context.input_state.beginMappedFrame(try workspace.state.pending());
    frame = .{ .context = &context, .size = size, .transforms = workspace };
    try frame.pushClip(.{ .x = 3, .y = 4, .width = 20, .height = 25 });
    try frame.pushOffset(.{ .x = 3, .y = 5 });
    const local: Rect = .{ .x = 1, .y = 1, .width = 10, .height = 10 };
    try frame.captureSpace(90, local);
    try frame.popOffset();
    try frame.popClip();
    context.commitFrame(window);
    const token = try context.committedSpace(90);
    try std.testing.expectEqualDeep(Rect{ .x = 4, .y = 6, .width = 10, .height = 10 }, try token.windowBounds(local));
    try std.testing.expect(try token.contains(.{ .x = 5, .y = 7 }));
    try std.testing.expect(!try token.contains(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(epoch, context.space_binding_epoch);
    try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
    try std.testing.expectError(error.ResourceInUse, context.releaseTransforms());
    context.command_buffer.reset();
    try workspace.begin(size, 2);
    context.input_state.beginMappedFrame(try workspace.state.pending());
    context.commitFrame(window);
    try context.releaseTransforms();
    try std.testing.expectError(error.StaleSpace, token.contains(.{ .x = 0, .y = 0 }));
    std.debug.print("Coordinate metadata bytes={d} one allocation; renderer planes=0; Context={d} Input={d} Frame={d}\n", .{ @sizeOf(TransformWorkspace), @sizeOf(Context), @sizeOf(input.Input), @sizeOf(Frame) });
}

test "metadata coordinate allocation close cannot publish a workspace" {
    const Callbacks = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    const Allocator = struct {
        window: z.Window,
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert((self.window.destroy() catch unreachable) == .deferred);
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var state: u8 = 0;
    var context = Context.init(&state, Callbacks.draw, Callbacks.action);
    context.window = window;
    context.attachment_phase = .attached;
    var hook: Allocator = .{ .window = window };
    const allocator: std.mem.Allocator = .{ .ptr = &hook, .vtable = &.{ .alloc = Allocator.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = Allocator.free } };
    try std.testing.expectError(error.Closed, context.prepareCoordinates(allocator, .{}));
    try std.testing.expect(context.transforms == null and context.space_binding_epoch == 0);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

test "attached semantic coordinate budget includes native geometry before allocation" {
    if (!build_options.accessibility) return error.SkipZigTest;
    const Callbacks = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var state: u8 = 0;
    var context = Context.init(&state, Callbacks.draw, Callbacks.action);
    context.window = window;
    context.attachment_phase = .attached;
    context.attached_semantics_enabled = true;
    context.accessibility_bridge = accessibility.Bridge.init(&context, Context.accessibilityAction);
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const required = @sizeOf(TransformWorkspace) + @sizeOf(accessibility.NativeGeometry);
    try std.testing.expectError(error.CoordinateBudgetExceeded, context.prepareCoordinates(allocator.allocator(), .{ .bytes = required - 1 }));
    try std.testing.expectEqual(@as(usize, 0), allocator.alloc_index);
    try std.testing.expect(context.transforms == null and context.accessibility_bridge.geometry_scratch == null);
    try std.testing.expectEqual(@as(u64, 0), context.space_binding_epoch);
}

test "Gaussian visual clip domain preserves parent hit geometry and scoped rollback" {
    const Host = struct {
        kernel: *gaussian.Kernel,
        calls: usize = 0,
        fail: bool = false,
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn body(ptr: *anyopaque, frame: *Frame) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            try std.testing.expectEqualDeep(@as(?Rect, .{ .x = 2, .y = 2, .width = 2, .height = 2 }), frame.clipBounds());
            try std.testing.expectError(error.ResourceInUse, self.kernel.close());
            try frame.pushClip(.{ .x = -4, .y = -4, .width = 20, .height = 20 });
            // The render clip must be the child's large rectangle. Hit and
            // semantic geometry still intersects the actual outer parent.
            try std.testing.expectEqualDeep(Rect{ .x = -4, .y = -4, .width = 20, .height = 20 }, frame.clips.items[frame.clips.len - 1]);
            try std.testing.expectEqualDeep(@as(?Rect, .{ .x = 2, .y = 2, .width = 2, .height = 2 }), frame.clipBounds());
            frame.rect(.{ .x = 0, .y = 2, .width = 2, .height = 2 }, 0xff0000);
            if (self.fail) return error.ExpectedBodyFailure;
            try frame.popClip();
        }
    };
    const bank = try gaussian.Bank.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer bank.close() catch unreachable;
    const kernel = try bank.prepare(.{ .spec = .{ .sigma = 1 } });
    defer kernel.close() catch unreachable;
    var host: Host = .{ .kernel = kernel };
    var context = Context.init(&host, Host.draw, Host.action);
    defer context.command_buffer.reset();
    var storage: commands.FilterStorage = .{};
    try context.command_buffer.bindFilterStorage(&storage);
    var frame: Frame = .{ .context = &context, .size = .{ .width = 10, .height = 10, .scale = 1 } };
    try frame.pushClip(.{ .x = 2, .y = 2, .width = 2, .height = 2 });
    try frame.gaussianScope(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, try kernel.view(), .{ .opacity = 128 }, &host, Host.body);
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expectEqual(@as(u8, 0), frame.group_geometry_passthrough);
    try std.testing.expectEqual(@as(usize, 0), frame.group_depth);
    try std.testing.expectEqual(@as(usize, 1), frame.clips.len);
    const before = context.command_buffer.checkpoint();
    host.fail = true;
    try std.testing.expectError(error.ExpectedBodyFailure, frame.gaussianScope(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, try kernel.view(), .{}, &host, Host.body));
    try std.testing.expectEqualDeep(before, context.command_buffer.checkpoint());
    try std.testing.expectEqual(@as(usize, 1), (try kernel.view()).lease.pins);
    try std.testing.expectEqual(@as(?anyerror, error.ExpectedBodyFailure), frame.failure);
    try std.testing.expectEqual(@as(usize, 1), frame.clips.len);
    try frame.popClip();
    try context.command_buffer.finish();
    std.debug.print("Gaussian UI sizes Context={d} Frame={d} workspace={d}\n", .{ @sizeOf(Context), @sizeOf(Frame), @sizeOf(GaussianWorkspace) });
}
test "Gaussian identity uses ordinary isolation without filter preparation or pins" {
    const Host = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn body(_: *anyopaque, frame: *Frame) !void {
            frame.rect(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, 0xff0000);
        }
    };
    const bank = try gaussian.Bank.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer bank.close() catch unreachable;
    const kernel = try bank.prepare(.{ .spec = .{ .sigma = 0 } });
    defer kernel.close() catch unreachable;
    var dummy: u8 = 0;
    var context = Context.init(&dummy, Host.draw, Host.action);
    defer context.command_buffer.reset();
    var frame: Frame = .{ .context = &context, .size = .{ .width = 4, .height = 4, .scale = 1 } };
    try frame.gaussianScope(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, try kernel.view(), .{}, &dummy, Host.body);
    try std.testing.expectEqual(@as(usize, 3), context.command_buffer.len);
    try std.testing.expectEqual(commands.no_filter, context.command_buffer.commands()[0].begin_group.filter_slot);
    try std.testing.expectEqual(@as(usize, 0), (try kernel.view()).lease.pins);
    try context.command_buffer.finish();
}

test "Gaussian Context preparation preserves coordinate authority and failed candidates" {
    const Host = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var marker: u8 = 0;
    var context = Context.init(&marker, Host.draw, Host.action);
    context.render_mode = .gdi;
    context.semantics_enabled = false;
    try context.attach(window);
    try context.prepareCoordinates(std.testing.allocator, .{});
    const coordinates = context.transforms.?;
    const epoch = context.space_binding_epoch;
    const options: GaussianWorkspaceOptions = .{ .layers = .{ .size = .{ .width = 8, .height = 8, .scale = 1 }, .max_depth = 2, .legacy_text = .disabled }, .source_size = .{ .width = 10, .height = 10 }, .max_radius = 3 };
    try context.prepareGaussianWorkspace(std.testing.allocator, options);
    const before = context.gaussian_workspace.?;
    const capacity = context.renderer.gaussianCapacity();
    const pixels = context.renderer.layerSurfaceBytes();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var short = options;
    short.layers.total_bytes = 1;
    try std.testing.expectError(error.LayerAggregateBudgetExceeded, context.prepareGaussianWorkspace(failing.allocator(), short));
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    const plan = try gaussian_scope.Plan.init(options, if (builtin.os.tag == .linux) .cairo else .gdi, null);
    const old_layers = context.renderer.layerSurfaceBytes() + context.renderer.layerStats().metadata_bytes + @sizeOf(GaussianWorkspace);
    const next_metadata = @sizeOf(GaussianWorkspace) + gdi.Renderer.layerMetadataBytes() + gdi.Renderer.gaussianMetadataBytes();
    short.layers.total_bytes = plan.pixel_bytes + old_layers + next_metadata + (try context.transformStats()).metadata_bytes - 1;
    try std.testing.expectError(error.LayerAggregateBudgetExceeded, context.prepareGaussianWorkspace(failing.allocator(), short));
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try std.testing.expectError(error.OutOfMemory, context.prepareGaussianWorkspace(failing.allocator(), options));
    try std.testing.expect(context.gaussian_workspace.? == before);
    try std.testing.expectEqualDeep(capacity, context.renderer.gaussianCapacity());
    try std.testing.expectEqual(pixels, context.renderer.layerSurfaceBytes());
    try std.testing.expect(context.transforms.? == coordinates and context.space_binding_epoch == epoch);
    try context.releaseGaussianWorkspace();
    try std.testing.expect(context.gaussian_workspace == null and context.renderer.gaussianCapacity() == null);
    try std.testing.expect(context.renderer.layerSurfaceBytes() < pixels);
    try std.testing.expect(context.transforms.? == coordinates and context.space_binding_epoch == epoch);
}

test "Gaussian Context rechecks closure after the previous workspace final free" {
    const Host = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    const Hook = struct {
        window: z.Window,
        armed: bool = false,
        calls: usize = 0,
        fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.armed and bytes.len == @sizeOf(GaussianWorkspace)) {
                self.armed = false;
                self.calls += 1;
                std.debug.assert((self.window.destroy() catch unreachable) == .deferred);
            }
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var marker: u8 = 0;
    var context = Context.init(&marker, Host.draw, Host.action);
    context.render_mode = .gdi;
    context.semantics_enabled = false;
    try context.attach(window);
    var hook: Hook = .{ .window = window };
    const options: GaussianWorkspaceOptions = .{ .layers = .{ .size = .{ .width = 8, .height = 8, .scale = 1 }, .max_depth = 2, .legacy_text = .disabled }, .source_size = .{ .width = 10, .height = 10 }, .max_radius = 3 };
    try context.prepareGaussianWorkspace(hook.allocator(), options);
    hook.armed = true;
    try std.testing.expectError(error.Closed, context.prepareGaussianWorkspace(hook.allocator(), options));
    try std.testing.expectEqual(@as(usize, 1), hook.calls);
    try app.dispatch();
    try std.testing.expect(context.window == null and context.gaussian_workspace == null);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

test "Gaussian and nested raster scopes restore visual flags without expanding Space clips" {
    const Host = struct {
        fn draw(_: *anyopaque, _: *Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
        fn body(_: *anyopaque, frame: *Frame) !void {
            const workspace = frame.transforms.?;
            const parent = workspace.reference;
            try frame.beginTransform(.{ .width = 8, .height = 8 }, .{ .x0 = 1 });
            try std.testing.expectEqual(@as(u8, 0), frame.group_geometry_passthrough);
            const visible = try (try workspace.state.pending()).geometry.visibleBounds(workspace.reference, .{ .width = 8, .height = 8 });
            try std.testing.expectEqualDeep(@as(?affine.Rect, .{ .x = 2, .y = 2, .width = 2, .height = 2 }), visible);
            try frame.endTransform();
            try std.testing.expectEqualDeep(parent, workspace.reference);
            try std.testing.expectEqual(@as(u8, 1), frame.group_geometry_passthrough);
        }
    };
    const bank = try gaussian.Bank.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer bank.close() catch unreachable;
    const kernel = try bank.prepare(.{ .spec = .{ .sigma = 1 } });
    defer kernel.close() catch unreachable;
    const workspace = try std.testing.allocator.create(TransformWorkspace);
    defer std.testing.allocator.destroy(workspace);
    workspace.* = .{ .allocator = std.testing.allocator, .options = .{ .layers = .{ .size = .{ .width = 16, .height = 16, .scale = 1 }, .max_depth = 4 }, .source_size = .{ .width = 16, .height = 16 } } };
    var marker: u8 = 0;
    var context = Context.init(&marker, Host.draw, Host.action);
    context.transforms = workspace;
    defer context.command_buffer.reset();
    var storage: commands.FilterStorage = .{};
    try context.command_buffer.bindFilterStorage(&storage);
    try workspace.begin(.{ .width = 16, .height = 16, .scale = 1 }, 1);
    try context.command_buffer.bindTransformStorage(&workspace.command_storage);
    var frame: Frame = .{ .context = &context, .size = .{ .width = 16, .height = 16, .scale = 1 }, .transforms = workspace };
    try frame.pushClip(.{ .x = 2, .y = 2, .width = 2, .height = 2 });
    const parent = workspace.reference;
    try frame.gaussianScope(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, try kernel.view(), .{}, &marker, Host.body);
    try std.testing.expectEqualDeep(parent, workspace.reference);
    try std.testing.expectEqual(@as(u8, 0), frame.group_geometry_passthrough);
    try frame.popClip();
    try context.command_buffer.finish();
}

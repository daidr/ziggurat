const std = @import("std");
const builtin = @import("builtin");
const backend = if (builtin.is_test) @import("platform/testing.zig") else if (builtin.os.tag == .windows) @import("platform/windows.zig") else if (builtin.os.tag == .linux) @import("platform/linux.zig") else @import("platform/unsupported.zig");
const mailbox = @import("mailbox.zig");
const registry = @import("registry.zig");
const app_stop = @import("app_stop.zig");
const pointer_press = @import("platform/pointer_press.zig");
const pointer_clicks = @import("pointer_classifier");
pub const diagnostics = @import("diagnostics.zig");
pub const text = @import("text_client.zig");
pub const composition = @import("composition.zig");
pub const TextClient = text.Client;
pub const TextClientToken = text.Token;
/// Per-window native text service selection. Keyboard/compose keeps ordinary
/// layout text and local compose; it does not select a system language profile.
pub const TextInputMode = enum { system, keyboard_compose };
pub const TextInputModeResult = enum { applied, superseded };
pub const TextInputStamp = struct { mode: TextInputMode, epoch: u64 };

pub const windows_text = if (builtin.os.tag == .windows) @import("platform/windows_text.zig") else struct {};

pub const AppOptions = struct {
    /// Borrowed until deinit. Framework reports run on the owner thread.
    diagnostics_sink: ?diagnostics.Sink = null,
    icon_policy: enum { automatic, disabled, required } = .automatic,
    /// Limits caller-owned nodes; no participant table is allocated.
    stop_capacity: usize = 256,
    /// Borrowed until deinit.
    activation: ?ActivationHandler = null,
    /// Borrowed until deinit. Set, the App keeps running without windows,
    /// as an app living in the notification area does, until requestQuit or
    /// quit: the last window closing calls it instead of quitting, and run
    /// does not return when it starts without windows.
    on_all_windows_closed: ?AllWindowsClosedHandler = null,
};
/// Runs on the owner thread at the dispatch safe point after the last
/// window closed. It may create windows or quit. Context outlives the App.
pub const AllWindowsClosedHandler = struct {
    context: *anyopaque,
    closed: *const fn (*anyopaque, *App) void,
};

pub const Task = mailbox.Task;
pub const StopParticipant = app_stop.Node;
/// Borrowed from a stable participant and App. Neither may be freed while used.
pub const StopToken = app_stop.Token;
/// Resource-owned stable node. Queue on the owner thread; App must outlive it.
/// Storage stays valid until the task starts, which may then free the node.
/// Cleanup is mandatory, nonblocking work, independent of the user task queue.
pub const Cleanup = struct { task: Task, next: ?*Cleanup = null, queued: bool = false };
pub const NativeWaitToken = struct { index: u8, generation: u64 };
pub const platform_capabilities = .{
    .native_windows = builtin.os.tag == .windows or builtin.os.tag == .linux,
    .native_waits = builtin.os.tag == .windows,
    .application_icon = builtin.os.tag == .windows,
    .text_input = builtin.os.tag == .windows or builtin.os.tag == .linux,
};
pub const Point = struct { x: f32, y: f32 };
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    pub fn contains(self: Rect, point: Point) bool {
        return point.x >= self.x and point.y >= self.y and point.x < self.x + self.width and point.y < self.y + self.height;
    }
};
pub const Size = struct { width: u32, height: u32, scale: f32 };
/// `transparent` frames start clear and keep their alpha (see
/// `WindowCapabilities.transparent`).
/// `background` is the window's (`Window.setBackground`) where the backend
/// shows it beyond the frame until a frame of the new size presents.
pub const Paint = struct { native_context: *anyopaque, native_window: ?*anyopaque = null, size: Size, transparent: bool = false, background: ?u32 = null };
pub const TextPreedit = struct { text: []const u8, selection_start: usize, selection_end: usize };
/// Native delivery path, not an assertion about a physical keyboard or a
/// language engine. A GTK text-service commit can include keyboard translation.
pub const TextProducer = enum { win32_character, imm_result, gtk_text_service_commit, gtk_keyval_fallback, application };
pub const TextInput = struct { text: []const u8, producer: TextProducer };
pub const EditKeyCode = enum { left, right, up, down, home, end, backspace, delete, a, c, x, v, z, y };
pub const EditKey = struct { key: EditKeyCode, shift: bool = false, control: bool = false };
pub const KeyModifiers = struct { shift: bool = false, control: bool = false, alt: bool = false, super: bool = false };
pub const PointerButton = pointer_press.Button;
pub const PointerPhase = pointer_press.Phase;
/// Sequence0 has no native receipt. Native timestamp0 remains a valid sample.
pub const PointerPress = pointer_press.Receipt;
pub const PointerClickTiming = pointer_press.Timing;
pub const ClickSample = pointer_press.Position;
pub const ClickPolicy = pointer_clicks.Policy;
pub const PointerPressSnapshot = pointer_press.Snapshot;
pub const PointerDisposition = pointer_press.Disposition;
pub const PointerButtonInput = struct {
    position: Point,
    button: PointerButton = .primary,
    modifiers: KeyModifiers = .{},
    press: PointerPress = .{},
};
/// Logical key before Shift/Lock, using the current native keyboard layout.
/// Text and IME output still arrive separately through text_input/preedit.
pub const KeyCode = enum {
    unknown,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    digit0,
    digit1,
    digit2,
    digit3,
    digit4,
    digit5,
    digit6,
    digit7,
    digit8,
    digit9,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    tab,
    enter,
    space,
    escape,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    backspace,
    caps_lock,
    num_lock,
    scroll_lock,
    print_screen,
    pause,
    shift,
    control,
    alt,
    super,
    context_menu,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    grave,
    comma,
    period,
    slash,
    numpad0,
    numpad1,
    numpad2,
    numpad3,
    numpad4,
    numpad5,
    numpad6,
    numpad7,
    numpad8,
    numpad9,
    decimal,
    add,
    subtract,
    multiply,
    divide,
    media_play_pause,
    media_stop,
    media_next,
    media_previous,
    volume_mute,
    volume_down,
    volume_up,
    browser_back,
    browser_forward,
    browser_refresh,
    browser_stop,
    browser_search,
    browser_favorites,
    browser_home,
};
pub const KeyInput = struct {
    key: KeyCode,
    modifiers: KeyModifiers = .{},
    repeat: bool = false,
    /// The key by its position, whatever the layout (`physical_keys`):
    /// `.w` is the key in W's place on any layout, as games want for WASD.
    /// `.unknown` when the native event carried no position.
    physical: KeyCode = .unknown,
};
pub const physical_keys = @import("physical_keys.zig");
pub const Event = union(enum) {
    paint: Paint,
    resize: Size,
    /// Native observation and requested WM policy changed. Notifications dedupe.
    window_state: WindowState,
    /// Native parent geometry may have moved. No screen coordinates implied.
    window_position,
    key_input: KeyInput,
    pointer_down: PointerButtonInput,
    pointer_up: PointerButtonInput,
    pointer_move: Point,
    wheel: struct { position: Point, delta: Point },
    focus: bool,
    /// Text slices are borrowed for the duration of the content callback.
    text_input: TextInput,
    text_preedit: TextPreedit,
    text_preedit_cancel,
    /// Native preedit was cancelled after its TextClient ingress was revoked.
    /// Lifecycle bookkeeping only; the former client's unbound callback owns
    /// document cleanup. Do not route this back into the former business owner.
    text_preedit_revoked,
    edit_key: EditKey,
    cancel_input,
    key: enum { tab, activate },
};

/// Context stays at a stable address through detach. Callbacks run on the UI thread.
pub const Content = struct {
    context: *anyopaque,
    event: *const fn (*anyopaque, Window, Event) void,
    detach: *const fn (*anyopaque) void,
    accessibility: ?*const fn (*anyopaque, Window, usize, isize) ?isize = null,
    /// Runs before native text translation. True consumes the key, including
    /// its legacy/edit/text consequences. Null preserves the legacy path.
    key_input: ?*const fn (*anyopaque, Window, KeyInput) bool = null,
    /// A key released while the window has the keyboard, after native
    /// handling; `repeat` is unset. Only content that asks receives
    /// releases, which games read to tell held keys from released ones.
    key_release: ?*const fn (*anyopaque, Window, KeyInput) void = null,
    /// Early native teardown only: no allocation, COM or business callbacks.
    /// Use cached native handles; the Window/Region is already closing.
    /// Windows invokes this at WM_DESTROY while native children still exist.
    native_parent_destroying: ?*const fn (*anyopaque) void = null,
};
/// Optional native facilities independent of the window's content owner.
/// Context remains stable through on_closed; native cleanup never frees it.
pub const WindowService = struct {
    context: *anyopaque,
    message: ?*const fn (*anyopaque, Window, u32, usize, isize) ?isize = null,
    native_destroying: *const fn (*anyopaque) void,
};
pub const CloseReason = enum { user, application, owner, quit };
pub const CloseDecision = enum { allow, cancel };
pub const CloseResult = enum { closed, cancelled, deferred, in_progress };
pub const CloseHandler = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque, Window, CloseReason) CloseDecision,
};
pub const ClosedHandler = struct {
    context: *anyopaque,
    notify: *const fn (*anyopaque, Window) void,
};
pub const WindowAction = enum { show, hide, minimize, maximize, restore, focus, enable, disable };
pub const WindowState = struct {
    visible: bool,
    minimized: bool,
    maximized: bool,
    focused: bool,
    enabled: bool,
    fullscreen: bool = false,
    fullscreen_requested: bool = false,
    always_on_top: bool = false,
    always_on_top_requested: bool = false,
    enabled_requested: bool = true,
    modal_blocked: bool = false,
};
/// Client origin in native desktop coordinates: physical pixels on Windows,
/// desktop logical coordinates on GTK/X11. Position is unavailable on Wayland.
pub const ScreenPoint = struct { x: i32, y: i32 };
/// Client size is in DIP. A null position preserves the current position when set.
pub const ClientBounds = struct { position: ?ScreenPoint = null, width: u32, height: u32 };
pub const WindowCapabilities = struct {
    client_position: bool,
    fullscreen: bool,
    always_on_top: bool,
    owned_windows: bool = false,
    modal_windows: bool = false,
    custom_decoration: bool = false,
    native_move_resize: bool = false,
    system_menu: bool = false,
    /// Paint frames start transparent and keep their alpha: a window created
    /// with `transparent` on GTK with an RGBA visual, or one that can show a
    /// material on Windows.
    transparent: bool = false,
    /// What paint frames leave transparent shows the window's `Vibrancy`:
    /// Windows 11 22H2 and later, in a window created with a material.
    vibrancy: bool = false,
    backdrop_material: bool = false,
    /// `setOpacity` changes whole-window translucency. GTK needs a compositor.
    opacity: bool = false,
    /// `setIgnorePointer` lets pointer input reach the windows below.
    ignore_pointer: bool = false,
    /// `setContentProtection` excludes the window from screen capture.
    content_protection: bool = false,
    /// `flashFrame` asks for attention: a flashing taskbar button or an
    /// urgency hint.
    attention: bool = false,
    /// `setSkipTaskbar` hides the taskbar entry.
    skip_taskbar: bool = false,
    /// `minimizable`/`maximizable` change the system buttons and commands.
    /// Linux X11 publishes them as window manager hints.
    window_buttons: bool = false,
};
/// Runtime window policy. `resizable` also gates custom resize edges and
/// `startResize`; `movable` gates `startMove` and native move commands;
/// `closable` cancels user close requests before `on_close` runs.
pub const WindowTraits = struct {
    resizable: bool = true,
    movable: bool = true,
    minimizable: bool = true,
    maximizable: bool = true,
    closable: bool = true,
};
/// Called on the owner thread when the App gains or loses its first focused
/// window. Focus moving between this App's windows reports nothing: the change
/// is evaluated at the next dispatch safe point. Context outlives the App.
pub const ActivationHandler = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, *App, bool) void,
};
pub const WindowDecoration = enum { system, borderless, custom };
/// System backdrop material drawn by the compositor behind the native frame.
/// `.system` restores the platform default; client content stays opaque.
pub const WindowBackdrop = enum { system, none, mica, acrylic, mica_alt };
/// A translucent material that blurs what is behind a window, shown where its
/// paint frames are transparent (see `WindowOptions.vibrancy`). Windows 11
/// has the Mica, Acrylic and Tabbed system backdrops; the other materials use
/// the closest one: Acrylic for transient UI (menu, popover, hud, sheet,
/// tooltip, selection, fullscreen_ui), Mica otherwise. Linux has none.
pub const Vibrancy = enum {
    none,
    window,
    content,
    sidebar,
    header,
    titlebar,
    under_window,
    under_page,
    menu,
    popover,
    hud,
    sheet,
    tooltip,
    selection,
    fullscreen_ui,
    mica,
    acrylic,
    tabbed,
};
/// Construction-time native accessibility hosting policy.
pub const AccessibilityHost = enum { platform, children };
pub const ResizeEdge = enum(u8) { north_west, north, north_east, west, east, south_west, south, south_east };
pub const WindowHit = enum(c_int) {
    client,
    caption,
    system_menu,
    north_west,
    north,
    north_east,
    west,
    east,
    south_west,
    south,
    south_east,
    pub fn resizeEdge(self: WindowHit) ?ResizeEdge {
        const value = @backingInt(self);
        return if (value >= @backingInt(WindowHit.north_west)) @fromBackingInt(@intCast(value - @backingInt(WindowHit.north_west))) else null;
    }
};
/// The shape of the pointer over the client area. Shapes a platform lacks
/// fall back to the nearest one it has (on Windows, one-sided and column/row
/// resizes use the two-sided ones, and copy, alias and context menu the
/// arrow); `none` hides the pointer.
pub const Cursor = enum(u8) {
    default,
    pointer,
    text,
    move,
    resize_ew,
    resize_ns,
    resize_nwse,
    resize_nesw,
    not_allowed,
    crosshair,
    grab,
    grabbing,
    resize_n,
    resize_e,
    resize_s,
    resize_w,
    resize_column,
    resize_row,
    vertical_text,
    copy,
    alias,
    context_menu,
    none,
};
pub const HitTestHandler = struct { context: *anyopaque, query: *const fn (*anyopaque, Window, Point) WindowHit };
pub const WindowRelationship = struct { owner: ?Window, modal: bool, modal_active: bool, modal_children: usize };
/// Construction-time role of a borderless window placed beside an anchor,
/// such as a flyout, a menu or a hover card: it has no taskbar or pager entry
/// and the user does not move or resize it. Requires `.borderless`.
pub const PopupRole = struct {
    /// Takes the keyboard when shown, and reports `PopupHandler.dismiss` when
    /// another window outside its own popups takes the keyboard or, on Linux,
    /// when the user presses outside it. Others never take the keyboard: show,
    /// focus and pointer presses leave the active window as it was.
    focusable: bool = false,
    /// Floats above other applications' windows, as a popup without an owner
    /// beside a notification-area icon does.
    topmost: bool = false,
    /// The system's popup shadow. Windows 11 also rounds and outlines the
    /// window as it does its menus; Linux draws no shadow of its own.
    shadow: bool = false,
    /// Borrowed context remains valid through on_closed, like close handlers.
    handler: ?PopupHandler = null,
};
pub const PopupHandler = struct {
    context: *anyopaque,
    /// A focusable popup lost the keyboard or saw a press outside it. Runs on
    /// the main thread at a safe point; the popup is still open.
    dismiss: *const fn (*anyopaque, Window) void,
    /// The owner reported a new size or position; place the popup again.
    owner_moved: ?*const fn (*anyopaque, Window) void = null,
};
pub const WindowOptions = struct {
    title: []const u8 = "Ziggurat",
    width: u32 = 720,
    height: u32 = 480,
    min_width: u32 = 0,
    min_height: u32 = 0,
    decoration: WindowDecoration = .system,
    resizable: bool = true,
    movable: bool = true,
    minimizable: bool = true,
    maximizable: bool = true,
    /// False removes the close command; user close requests are cancelled.
    closable: bool = true,
    /// Applied right after native creation; requires the matching capability
    /// unless left at its default.
    opacity: f32 = 1,
    skip_taskbar: bool = false,
    /// Reserved client edge in DIP for .custom; .borderless has no auto edges.
    resize_border: f32 = 6,
    /// Borrowed context remains valid through on_closed, like close handlers.
    hit_test: ?HitTestHandler = null,
    /// Immutable ownership between independent top-level windows in this App.
    owner: ?Window = null,
    /// Active while visible; disables other branches in this ownership tree.
    modal: bool = false,
    text_input_mode: TextInputMode = .system,
    /// Fixed construction-time raw native press state. No state is allocated
    /// when disabled; semantic control actions remain independently owned by UI.
    native_pointer_clicks: bool = false,
    /// .children selects the optional GTK accessible child host on Linux.
    /// Other native backends reject it with UnsupportedCapability.
    accessibility_host: AccessibilityHost = .platform,
    popup: ?PopupRole = null,
    /// Makes the window background transparent, so what paint frames leave
    /// transparent shows the desktop through. GTK needs a compositing
    /// desktop; `capabilities().transparent` tells whether frames keep alpha.
    /// On Windows the window has no redirection bitmap, as with a material:
    /// frames are composed with their alpha and it has no menu bar.
    transparent: bool = false,
    /// Puts a material behind what paint frames leave transparent. On
    /// Windows only a window created with a material can show one (Windows
    /// 11 22H2 and later, `capabilities().vibrancy`); its frames are then
    /// composed with their alpha and it has no menu bar: Alt and F10 open the
    /// menus in a popup. Linux shows none.
    vibrancy: Vibrancy = .none,
    on_close: ?CloseHandler = null,
    on_closed: ?ClosedHandler = null,
};
pub const ResourceStats = struct {
    live_windows: usize,
    allocated_records: usize,
    registry_slots: usize,
    pending_destroys: usize,
    stop_participants: usize,
};

pub const App = struct {
    pub const Phase = enum { ready, running, stopping, stopped };
    pub const QuitResult = enum { accepted, cancelled, in_progress, already_stopped };
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    native: backend.AppData = .{},
    active_pointer: ?*PointerIngress = null,
    phase: Phase = .ready,
    windows: registry.Registry(WindowRecord) = .{},
    first: ?*WindowRecord = null,
    pending_head: ?*WindowRecord = null,
    pending_tail: ?*WindowRecord = null,
    pending_count: usize = 0,
    cleanup_head: ?*Cleanup = null,
    cleanup_tail: ?*Cleanup = null,
    allocated_records: usize = 0,
    activity_depth: usize = 0,
    stop_resources: app_stop.Manager,
    querying_quit: bool = false,
    /// Inside the native event loop of `run`.
    looping: bool = false,
    querying_close_tree: bool = false,
    relations_busy: bool = false,
    relations_dirty: bool = false,
    relation_cursor: ?*WindowRecord = null,
    focus_restore: ?Window = null,
    modal_total: usize = 0,
    next_modal_order: u64 = 1,
    quit_cursor: ?*WindowRecord = null,
    destroying: bool = false,
    dispatching: bool = false,
    queue: mailbox.Mailbox(256) = .{},
    last_native_error: u32 = 0,
    native_failure: ?struct { domain: diagnostics.Domain, code: u32 } = null,
    diagnostics_sink: ?diagnostics.Sink = null,
    icon_policy: @FieldType(AppOptions, "icon_policy") = .automatic,
    reporting_diagnostic: bool = false,
    activation: ?ActivationHandler = null,
    all_windows_closed: ?AllWindowsClosedHandler = null,
    /// A window was created since the handler last ran.
    windows_seen: bool = false,
    active: bool = false,
    activation_dirty: bool = false,
    activation_notifying: bool = false,

    /// Call on the process main thread. App must outlive all its value handles.
    pub fn init(allocator: std.mem.Allocator) !*App {
        return initWithOptions(allocator, .{});
    }
    pub fn initWithOptions(allocator: std.mem.Allocator, options: AppOptions) !*App {
        const stops = app_stop.Manager.init(options.stop_capacity) catch |err| {
            if (options.diagnostics_sink) |sink| sink.report(.{ .domain = .core, .operation = .app_init, .err = err });
            return err;
        };
        const self = allocator.create(App) catch |err| {
            if (options.diagnostics_sink) |sink| sink.report(.{ .domain = .core, .operation = .app_init, .err = err });
            return err;
        };
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .diagnostics_sink = options.diagnostics_sink, .icon_policy = options.icon_policy, .stop_resources = stops, .activation = options.activation, .all_windows_closed = options.on_all_windows_closed };
        backend.init(self) catch |err| {
            self.report(self.failureDiagnostic(.app_init, err, null));
            return err;
        };
        return self;
    }
    /// Backend captures the code at the failure site, before rollback changes it.
    pub fn captureNativeFailure(self: *App, domain: diagnostics.Domain, code: u32) void {
        self.last_native_error = code;
        self.native_failure = .{ .domain = domain, .code = code };
    }
    fn failureDiagnostic(self: *App, operation: diagnostics.Operation, err: anyerror, window: ?Window) diagnostics.Diagnostic {
        const native = self.native_failure;
        self.native_failure = null;
        return .{ .domain = if (native) |n| n.domain else .core, .operation = operation, .err = err, .code = if (native) |n| n.code else null, .window = if (window) |w| w.diagnosticId() else null };
    }
    /// Synchronous owner-thread callback. Recursive reporting is suppressed.
    /// Destruction requested by the sink waits until the next safe point.
    pub fn report(self: *App, diagnostic: diagnostics.Diagnostic) void {
        self.assertOwner();
        const sink = self.diagnostics_sink orelse return;
        if (self.reporting_diagnostic) return;
        self.reporting_diagnostic = true;
        self.activity_depth += 1;
        defer {
            self.reporting_diagnostic = false;
            self.leaveActivity();
        }
        const pointer = self.suspendPointer();
        defer self.restorePointer(pointer);
        sink.report(diagnostic);
    }
    pub fn assertOwner(self: *const App) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
    }
    inline fn suspendPointer(self: *App) ?*PointerIngress {
        const previous = self.active_pointer;
        if (previous != null) self.active_pointer = null;
        return previous;
    }
    inline fn restorePointer(self: *App, previous: ?*PointerIngress) void {
        if (previous != null) self.active_pointer = previous;
    }
    /// Pins application activity without retaining any WindowRecord. The App
    /// stays alive through end; this linear scope must not be copied.
    pub fn beginCallback(self: *App) ?AppCallbackScope {
        self.assertOwner();
        if (self.phase == .stopping or self.phase == .stopped) return null;
        self.activity_depth += 1;
        return .{ .app = self };
    }
    /// A lifetime pin for resource close/detach, including stopping or stopped
    /// Apps and stop callbacks during deinit. This grants no business ingress:
    /// post/watch/create and resource operations retain their phase checks.
    pub fn beginTeardownCallback(self: *App) AppCallbackScope {
        self.assertOwner();
        self.activity_depth += 1;
        return .{ .app = self };
    }
    /// A real SDK callback boundary, including teardown callbacks. This masks
    /// any suspended raw pointer ingress and grants no business permission.
    pub fn beginNativeCallback(self: *App) NativeAppCallbackScope {
        const callback = self.beginTeardownCallback();
        return .{ .callback = callback, .previous = self.suspendPointer() };
    }
    /// Stable participant storage remains alive until cancellation succeeds or
    /// its stop callback succeeds. Registration/cancellation never allocate.
    pub fn registerStop(self: *App, node: *StopParticipant) !StopToken {
        self.assertOwner();
        if (self.phase == .stopping or self.phase == .stopped) return error.Closed;
        return self.stop_resources.register(node);
    }
    pub fn cancelStop(self: *App, token: StopToken) !bool {
        self.assertOwner();
        return self.stop_resources.cancel(token);
    }
    pub fn resourceStats(self: *const App) ResourceStats {
        self.assertOwner();
        return .{ .live_windows = self.windows.count, .allocated_records = self.allocated_records, .registry_slots = self.windows.slots.items.len, .pending_destroys = self.pending_count, .stop_participants = self.stop_resources.count };
    }
    /// Snapshot open windows in unspecified order, without allocation or native
    /// calls. OutputTooSmall leaves output untouched. Handles retain the normal
    /// generation checks; the App must outlive every returned handle use.
    pub fn listWindows(self: *App, output: []Window) ![]Window {
        self.assertOwner();
        var count: usize = 0;
        var cursor = self.first;
        while (cursor) |record| : (cursor = record.next) {
            if (record.phase == .open) count += 1;
        }
        if (count > output.len) return error.OutputTooSmall;
        count = 0;
        cursor = self.first;
        while (cursor) |record| : (cursor = record.next) {
            if (record.phase != .open) continue;
            output[count] = record.window;
            count += 1;
        }
        return output[0..count];
    }
    /// Resolve an App-local runtime identity in O(1). Identities cannot cross
    /// App lifetimes and are not suitable for persistent document identities.
    pub fn findWindow(self: *App, id: diagnostics.WindowId) ?Window {
        self.assertOwner();
        const record = self.windows.get(.{ .index = id.index, .generation = id.generation }) orelse return null;
        return if (record.phase == .open) record.window else null;
    }
    pub fn createWindow(self: *App, options: WindowOptions) !Window {
        self.assertOwner();
        self.activity_depth += 1;
        defer self.leaveActivity();
        self.native_failure = null;
        return self.createWindowInner(options) catch |err| {
            self.report(self.failureDiagnostic(.window_create, err, null));
            return err;
        };
    }
    fn createWindowInner(self: *App, options: WindowOptions) !Window {
        const pointer = self.suspendPointer();
        defer self.restorePointer(pointer);
        if (self.phase == .stopping or self.phase == .stopped) return error.Closed;
        if (self.querying_quit) return error.QuitInProgress;
        if (self.querying_close_tree) return error.CloseInProgress;
        if (self.relations_busy) return error.Busy;
        if (options.accessibility_host == .children) {
            if (comptime !builtin.is_test and builtin.os.tag != .linux) return error.UnsupportedCapability;
        }
        if (options.modal and options.owner == null) return error.OwnerRequired;
        const owner = if (options.owner) |value| owner: {
            if (value.app != self) return error.ForeignApp;
            const record = value.resolve() orelse return error.Closed;
            if (record.phase != .open) return error.Closed;
            if (!backend.capabilities(record).owned_windows or (options.modal and !backend.capabilities(record).modal_windows)) return error.UnsupportedCapability;
            break :owner record;
        } else null;
        if (std.mem.indexOfScalar(u8, options.title, 0) != null) return error.EmbeddedNul;
        if (!std.unicode.utf8ValidateSlice(options.title)) return error.InvalidUtf8;
        if (options.width == 0 or options.height == 0 or options.width > 32768 or options.height > 32768 or options.min_width > options.width or options.min_height > options.height) return error.InvalidSize;
        if (!std.math.isFinite(options.resize_border) or options.resize_border < 0 or options.resize_border > 64) return error.InvalidGeometry;
        if (options.decoration == .system and options.hit_test != null) return error.InvalidWindowDecoration;
        if (options.popup != null and (options.decoration != .borderless or options.modal)) return error.InvalidPopup;
        if (!std.math.isFinite(options.opacity) or options.opacity < 0 or options.opacity > 1) return error.InvalidOpacity;
        const title = try self.allocator.dupe(u8, options.title);
        const record = self.allocator.create(WindowRecord) catch |err| {
            self.allocator.free(title);
            return err;
        };
        const key = self.windows.insert(self.allocator, record) catch |err| {
            self.allocator.destroy(record);
            self.allocator.free(title);
            return err;
        };
        record.* = .{ .window = .{ .app = self, .key = key }, .options = options, .vibrancy = options.vibrancy, .next = self.first, .pins = 1, .title = title };
        if (owner) |parent| record.linkOwner(parent);
        if (self.first) |first| first.previous = record;
        self.first = record;
        self.allocated_records += 1;
        defer record.unpin();
        record.createNative(options) catch |err| {
            if (record.phase != .closed) record.nativeDestroyed();
            return err;
        };
        if (record.phase != .creating or (owner != null and owner.?.phase != .open)) {
            if (record.phase != .closed) record.queueCloseTree();
            return error.CreateWindowFailed;
        }
        record.phase = .open;
        self.refreshRelationships();
        if (record.phase != .open) return error.CreateWindowFailed;
        record.applyInitialPolicy() catch |err| {
            if (record.phase != .closed) record.queueCloseTree();
            return err;
        };
        if (record.phase != .open) return error.CreateWindowFailed;
        record.created = true;
        self.windows_seen = true;
        // The native API has copied the title. Do not retain its borrowed slice.
        record.options.title = "";
        return record.window;
    }
    /// Only cross-thread entry. Join producers before deinit. Context lives until execution.
    pub fn post(self: *App, task: Task) !void {
        if (try self.queue.post(task)) backend.wake(self);
    }
    /// Enqueue final native release without allocation or mailbox capacity.
    /// Callbacks cannot rely on detached Window/Content storage or block/retry.
    pub fn deferCleanup(self: *App, node: *Cleanup) void {
        self.assertOwner();
        std.debug.assert(!node.queued);
        node.queued = true;
        node.next = null;
        if (self.cleanup_tail) |tail| tail.next = node else self.cleanup_head = node;
        self.cleanup_tail = node;
        backend.wake(self);
    }
    fn cleanupSafe() bool {
        if (comptime !builtin.is_test and builtin.os.tag == .windows) return backend.cleanupSafe();
        return true;
    }
    fn flushCleanups(self: *App) void {
        if (self.activity_depth != 0 or !cleanupSafe()) return;
        for (0..64) |_| {
            const node = self.cleanup_head orelse return;
            self.cleanup_head = node.next;
            if (self.cleanup_head == null) self.cleanup_tail = null;
            node.next = null;
            node.queued = false;
            const task = node.task;
            self.activity_depth += 1;
            const pointer = self.suspendPointer();
            task.call(task.context);
            self.restorePointer(pointer);
            self.leaveActivity();
        }
    }
    /// Borrow an OS event handle until cancellation or one owner-thread callback.
    /// App shutdown cancels remaining registrations without executing them.
    pub fn watchNative(self: *App, handle: *anyopaque, task: Task) !NativeWaitToken {
        self.assertOwner();
        if (self.phase == .stopping or self.phase == .stopped) return error.Closed;
        if (comptime builtin.is_test or builtin.os.tag != .windows) return error.UnsupportedCapability;
        return backend.watchNative(self, handle, task);
    }
    pub fn unwatchNative(self: *App, token: NativeWaitToken) bool {
        self.assertOwner();
        if (comptime builtin.is_test or builtin.os.tag != .windows) return false;
        return backend.unwatchNative(self, token);
    }
    pub fn dispatchNativeTask(self: *App, task: Task) void {
        self.assertOwner();
        self.activity_depth += 1;
        defer self.leaveActivity();
        const pointer = self.suspendPointer();
        defer self.restorePointer(pointer);
        task.call(task.context);
    }
    /// Backend safe point. A bounded batch yields to native input.
    pub fn dispatch(self: *App) !void {
        self.assertOwner();
        if (self.activity_depth != 0 or self.dispatching) return;
        self.dispatching = true;
        defer {
            self.dispatching = false;
            if (self.queue.pending() or self.pending_head != null or self.cleanup_head != null) backend.wake(self);
        }
        self.drain();
        // Shutdown owns Stop-before-window ordering once a task seals ingress.
        // Do not flush that task's deferred destroys before stopAll can run.
        if (self.phase == .stopping) return;
        self.refreshRelationships();
        try self.flushDestroys();
        self.refreshRelationships();
        self.restoreFocus();
        self.updateActivation();
        self.flushCleanups();
        self.maybeQuit();
    }
    /// Whether one of this App's windows has keyboard focus, as last reported
    /// to the activation handler.
    pub fn isActive(self: *const App) bool {
        self.assertOwner();
        return self.active;
    }
    fn markActivation(self: *App) void {
        if (self.activation_dirty) return;
        self.activation_dirty = true;
        // Inside an activity, leaving it wakes. Shutdown reports nothing more.
        if (self.activity_depth == 0 and self.activationLive()) backend.wake(self);
    }
    fn activationLive(self: *const App) bool {
        return self.phase == .ready or self.phase == .running;
    }
    fn updateActivation(self: *App) void {
        if (!self.activation_dirty or self.activation_notifying) return;
        self.activation_dirty = false;
        var focused = false;
        var cursor = self.first;
        while (cursor) |record| : (cursor = record.next) {
            if (record.phase == .open and record.focused) {
                focused = true;
                break;
            }
        }
        if (focused == self.active) return;
        self.active = focused;
        const handler = self.activation orelse return;
        self.activation_notifying = true;
        self.activity_depth += 1;
        defer {
            self.activation_notifying = false;
            self.leaveActivity();
        }
        const pointer = self.suspendPointer();
        defer self.restorePointer(pointer);
        handler.changed(handler.context, self, focused);
    }
    fn drain(self: *App) void {
        for (0..256) |_| {
            const task = self.queue.pop() orelse break;
            self.activity_depth += 1;
            const pointer = self.suspendPointer();
            task.call(task.context);
            self.restorePointer(pointer);
            self.leaveActivity();
        }
    }
    pub fn run(self: *App) !void {
        self.assertOwner();
        if (self.activity_depth != 0 or self.phase == .running) return error.AlreadyRunning;
        if (self.phase != .ready) return error.Closed;
        self.phase = .running;
        var loop_error: ?anyerror = null;
        self.maybeQuit();
        self.native_failure = null;
        self.looping = true;
        backend.run(self) catch |err| {
            self.report(self.failureDiagnostic(.run, err, null));
            loop_error = err;
        };
        self.looping = false;
        try self.shutdown();
        if (loop_error) |err| return err;
    }
    /// Preflight handlers before accepting shutdown. No partial automatic close.
    pub fn requestQuit(self: *App) QuitResult {
        self.assertOwner();
        if (self.phase == .stopping and self.looping) backend.quit(self);
        if (self.phase == .stopping or self.phase == .stopped) return .already_stopped;
        if (self.querying_quit or self.querying_close_tree) return .in_progress;
        self.querying_quit = true;
        self.activity_depth += 1;
        defer {
            self.querying_quit = false;
            self.quit_cursor = null;
            self.leaveActivity();
        }
        self.quit_cursor = self.first;
        while (self.quit_cursor) |record| {
            self.quit_cursor = record.next;
            record.pin();
            const allow = record.allowClose(.quit);
            record.unpin();
            if (self.phase == .stopping) return .accepted;
            if (!allow) return .cancelled;
        }
        self.quit();
        return .accepted;
    }
    /// Unconditional shutdown for explicit termination/error paths. Bypasses vetoes.
    pub fn quit(self: *App) void {
        self.assertOwner();
        if (self.phase == .stopping and self.looping) {
            // The quit sequence ran but the native loop goes on, as after a
            // modal loop that swallowed the request: ask it to stop again.
            backend.quit(self);
            return;
        }
        if (self.phase == .stopping or self.phase == .stopped) return;
        const running = self.phase == .running;
        self.phase = .stopping;
        self.stop_resources.seal() catch unreachable;
        self.cancelNativeWaits();
        self.queue.close();
        if (running) backend.quit(self);
    }
    fn shutdown(self: *App) !void {
        self.phase = .stopping;
        self.stop_resources.seal() catch unreachable;
        self.cancelNativeWaits();
        self.queue.close();
        self.drain();
        if (!cleanupSafe() and self.stop_resources.count != 0) return error.UnsafeCleanupContext;
        self.activity_depth += 1;
        const pointer = self.suspendPointer();
        defer self.restorePointer(pointer);
        self.stop_resources.stopAll() catch |err| {
            self.leaveActivity();
            self.report(.{ .domain = .core, .operation = .app_stop, .err = err });
            return err;
        };
        self.leaveActivity();
        while (self.first != null or self.pending_head != null) {
            try self.flushDestroys();
            if (self.first) |record| {
                if (record.phase != .closing) _ = try record.window.destroy();
            }
        }
        if (!cleanupSafe() and self.cleanup_head != null) return error.UnsafeCleanupContext;
        while (self.cleanup_head != null) self.flushCleanups();
        self.phase = .stopped;
    }
    /// Retry a failed shutdown pass after run returns, without replaying posts
    /// or reopening ingress. Each failed participant is attempted once per call.
    pub fn finishShutdown(self: *App) !void {
        self.assertOwner();
        if (self.activity_depth != 0 or self.dispatching or self.destroying) return error.Busy;
        if (self.phase == .stopped) return;
        if (self.phase != .stopping) return error.NotStopping;
        if (!cleanupSafe()) return error.UnsafeCleanupContext;
        try self.shutdown();
    }
    fn cancelNativeWaits(self: *App) void {
        if (comptime !builtin.is_test and builtin.os.tag == .windows) backend.cancelAllNativeWaits(self);
    }
    pub fn deinit(self: *App) void {
        self.assertOwner();
        std.debug.assert(self.activity_depth == 0 and self.phase != .running and !self.destroying);
        self.destroying = true;
        self.shutdown() catch |err| std.debug.panic("cannot release App with native resources: {s} ({d})", .{ @errorName(err), self.last_native_error });
        std.debug.assert(self.allocated_records == 0);
        self.stop_resources.deinit() catch unreachable;
        self.windows.deinit(self.allocator);
        backend.deinit(self);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    fn enqueueDestroy(self: *App, record: *WindowRecord) void {
        if (record.queued) return;
        record.queued = true;
        record.pin();
        record.pending_previous = self.pending_tail;
        if (self.pending_tail) |tail| tail.pending_next = record else self.pending_head = record;
        self.pending_tail = record;
        self.pending_count += 1;
        backend.wake(self);
    }
    fn scheduleDestroy(self: *App, record: *WindowRecord) void {
        if (!record.queued) return self.enqueueDestroy(record);
        if (self.pending_tail == record) return;
        if (record.pending_previous) |previous| previous.pending_next = record.pending_next else self.pending_head = record.pending_next;
        if (record.pending_next) |next| next.pending_previous = record.pending_previous;
        record.pending_previous = self.pending_tail;
        record.pending_next = null;
        if (self.pending_tail) |tail| tail.pending_next = record;
        self.pending_tail = record;
    }
    fn refreshRelationships(self: *App) void {
        if (!self.relations_dirty or self.relations_busy) return;
        self.relations_dirty = false;
        self.relations_busy = true;
        defer {
            self.relations_busy = false;
            self.relation_cursor = null;
        }
        self.relation_cursor = self.first;
        while (self.relation_cursor) |root| {
            self.relation_cursor = root.next;
            if (root.owner_record != null) continue;
            const root_scope = root.enter();
            defer root_scope.end();
            const modal = root.modal_last;
            const after_modal = if (modal) |leaf| leaf.nextAfterTree(root) else null;
            var allowed = modal == null;
            var cursor: ?*WindowRecord = root;
            while (cursor) |record| {
                cursor = record.nextInTree(root);
                if (record == modal) allowed = true;
                if (record == after_modal) allowed = false;
                record.blocked_by = if (allowed) null else modal;
                if (record.phase != .open) continue;
                const scope = record.enter();
                defer scope.end();
                const enabled = record.enabled_requested and record.blocked_by == null;
                if (backend.state(record).enabled != enabled) {
                    if (!enabled) _ = record.invalidatePointer(false);
                    self.native_failure = null;
                    backend.perform(record, if (enabled) .enable else .disable) catch |err| {
                        self.report(self.failureDiagnostic(.window_update, err, record.window));
                    };
                }
                record.emitState();
            }
        }
    }
    fn restoreFocus(self: *App) void {
        const requested = self.focus_restore orelse return;
        self.focus_restore = null;
        if (self.phase == .stopping or self.phase == .stopped) return;
        const target = requested.focusTarget() catch return;
        target.perform(.focus) catch {};
    }
    fn destroyNative(self: *App, record: *WindowRecord) !void {
        const modal_active = record.modal_active;
        const modal_order = record.modal_order;
        record.setModalActive(false) catch unreachable;
        if (record.owner_record) |owner| if (owner.phase == .open) self.refreshRelationships();
        if (record.phase == .closed) {
            record.finishClosed();
            return;
        }
        record.destroying_native = true;
        defer record.destroying_native = false;
        self.native_failure = null;
        backend.destroy(record) catch |err| {
            const diagnostic = self.failureDiagnostic(.window_destroy, err, record.window);
            if (record.phase == .closed) {
                record.finishClosed();
                self.report(diagnostic);
                return err;
            }
            record.phase = .open;
            var parent = record.owner_record;
            while (parent) |ancestor| : (parent = ancestor.owner_record) if (ancestor.phase == .closing) {
                ancestor.phase = .open;
            };
            if (modal_active and backend.state(record).visible) record.activateModal(modal_order) catch unreachable;
            self.relations_dirty = true;
            self.refreshRelationships();
            self.report(diagnostic);
            return err;
        };
        if (record.phase == .closed) record.finishClosed();
    }
    fn flushDestroys(self: *App) !void {
        std.debug.assert(self.activity_depth == 0);
        const tail = self.pending_tail;
        while (self.pending_head) |record| {
            const last = record == tail;
            self.pending_head = record.pending_next;
            if (self.pending_head == null) self.pending_tail = null;
            if (self.pending_head) |head| head.pending_previous = null;
            record.pending_next = null;
            record.pending_previous = null;
            record.queued = false;
            self.pending_count -= 1;
            defer record.unpin();
            if (record.phase == .closing or record.phase == .closed) {
                if (record.first_child != null) {
                    self.enqueueDestroy(record);
                } else if (record.phase == .closing) {
                    try self.destroyNative(record);
                } else record.finishClosed();
            }
            if (last) break;
        }
    }
    fn leaveActivity(self: *App) void {
        std.debug.assert(self.activity_depth != 0);
        self.activity_depth -= 1;
        if (self.activity_depth == 0 and (self.relations_dirty or (self.activation_dirty and self.activationLive()) or self.focus_restore != null or self.pending_head != null or self.cleanup_head != null or self.queue.pending() or (self.windows.count == 0 and self.phase == .running and (self.all_windows_closed == null or self.windows_seen)))) backend.wake(self);
    }
    fn maybeQuit(self: *App) void {
        if (self.phase != .running or self.windows.count != 0 or self.pending_head != null or self.activity_depth > 1) return;
        const handler = self.all_windows_closed orelse return self.quit();
        if (!self.windows_seen) return;
        self.windows_seen = false;
        self.activity_depth += 1;
        defer self.leaveActivity();
        handler.closed(handler.context, self);
    }
};

/// Copyable handle; closed generations cannot resolve to newly created windows.
/// Handles expire with their App. No public pointer to the native record escapes.
pub const Window = struct {
    app: *App,
    key: registry.Key,
    pub fn diagnosticId(self: Window) diagnostics.WindowId {
        return .{ .index = self.key.index, .generation = self.key.generation };
    }
    pub fn report(self: Window, diagnostic: diagnostics.Diagnostic) void {
        var value = diagnostic;
        value.window = self.diagnosticId();
        self.app.report(value);
    }
    fn resolve(self: Window) ?*WindowRecord {
        self.app.assertOwner();
        return self.app.windows.get(self.key);
    }
    pub fn isClosed(self: Window) bool {
        const record = self.resolve() orelse return true;
        return record.phase == .closing or record.phase == .closed;
    }
    /// Owned original timing and current continuation qualification, only for
    /// this App's real active native down/up callback. No SDK call or allocation.
    pub fn pointerPressSnapshot(self: Window, press: PointerPress, expected_phase: PointerPhase) !PointerPressSnapshot {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        const record = self.resolve() orelse return error.StalePointerInput;
        const pointer_state = record.pointer_state orelse return error.UnsupportedCapability;
        const active = self.app.active_pointer orelse return error.StalePointerInput;
        if (active.record != record or !record.pointerCurrent(active.transition.operation)) return error.StalePointerInput;
        return pointer_state.owner.snapshot(active.transition, press, expected_phase);
    }
    /// Read a completed native down's held state, including from an explicit
    /// host deadline. The receipt is scoped to this Window. Success exposes
    /// no native event/timing authority and does not extend the active-callback
    /// contract of pointerPressSnapshot. No SDK call or allocation occurs.
    pub fn pointerPressHeld(self: Window, press: PointerPress, button: PointerButton) !void {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        const record = self.resolve() orelse return error.StalePointerInput;
        const pointer_state = record.pointer_state orelse return error.UnsupportedCapability;
        if (!record.pointerCurrent(pointer_state.owner.operation)) return error.StalePointerInput;
        try pointer_state.owner.held(press, button);
    }
    pub fn setContent(self: Window, content: Content) !void {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        if (record.content != null) return error.ContentAlreadyAttached;
        record.content = content;
    }
    pub fn setService(self: Window, service: WindowService) !void {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        if (record.service != null) return error.ServiceAlreadyAttached;
        record.service = service;
    }
    pub fn clearService(self: Window, context: *anyopaque) void {
        const record = self.resolve() orelse return;
        if (record.service) |service| if (service.context == context) record.detachService();
    }
    /// Native command identifiers never repeat during this window's lifetime.
    pub fn reserveNativeIds(self: Window, count: u16) !u16 {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        if (count == 0 or count > 65536 - record.next_native_id) return error.IdExhausted;
        const start: u16 = @intCast(record.next_native_id);
        record.next_native_id += count;
        return start;
    }
    /// Roll back a failed attachment without invoking its detach callback.
    pub fn cancelContent(self: Window, context: *anyopaque) void {
        const record = self.resolve() orelse return;
        if (record.content) |content| if (content.context == context) {
            record.content = null;
        };
    }
    pub fn show(self: Window) void {
        self.perform(.show) catch {};
    }
    pub fn perform(self: Window, action: WindowAction) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        if (self.app.relations_busy) return error.Busy;
        const record = scope.record;
        if (action == .focus) {
            if (record.modalBlocker() != null) return error.ModalBlocked;
            if (!record.enabled_requested) return error.Disabled;
        }
        if (action == .enable or action == .disable) {
            if (action == .disable) _ = record.invalidatePointer(false);
            record.enabled_requested = action == .enable;
            self.app.relations_dirty = true;
            self.app.refreshRelationships();
            return;
        }
        const current = backend.state(scope.record);
        // While a requested exit from full screen is still observed, restore
        // asks for the normal mode instead of the one from before full screen.
        const leaving = current.fullscreen and !current.fullscreen_requested and action == .restore;
        if ((current.fullscreen or current.fullscreen_requested) and !leaving and (action == .minimize or action == .maximize or action == .restore)) return error.InvalidWindowState;
        const activated = action == .show and record.options.modal and !record.modal_active;
        if (activated) {
            try record.setModalActive(true);
            self.app.refreshRelationships();
            if (record.phase != .open) return error.Closed;
        }
        const restore_focus = action == .hide and record.owner_record != null and backend.isActive(record);
        if (action == .hide or action == .minimize or action == .maximize or action == .restore) _ = record.invalidatePointer(true);
        self.app.native_failure = null;
        backend.perform(scope.record, action) catch |err| {
            const failure = self.app.native_failure;
            if (activated) {
                record.setModalActive(false) catch unreachable;
                self.app.refreshRelationships();
            }
            self.app.native_failure = failure;
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
        if (action == .hide) {
            record.setModalActive(false) catch unreachable;
            self.app.refreshRelationships();
            if (restore_focus) {
                if (record.owner_record) |owner| self.app.focus_restore = owner.window;
                self.app.restoreFocus();
            }
        }
        scope.record.emitState();
    }
    pub fn state(self: Window) !WindowState {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        return record.observedState();
    }
    pub fn relationship(self: Window) !WindowRelationship {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        return .{ .owner = if (record.owner_record) |owner| owner.window else null, .modal = record.options.modal, .modal_active = record.modal_active, .modal_children = record.modal_count };
    }
    /// The latest visible modal branch wins within one ownership tree.
    pub fn focusTarget(self: Window) !Window {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        return if (record.modalBlocker()) |modal| modal.window else self;
    }
    pub fn hitTest(self: Window, position: Point) !WindowHit {
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y)) return error.InvalidGeometry;
        const bounds = try backend.clientBounds(scope.record);
        return scope.record.hitTest(position, @floatFromInt(bounds.width), @floatFromInt(bounds.height));
    }
    fn beginInteraction(self: Window, is_resize: bool) !CallbackScope {
        const scope = self.beginCallback() orelse return error.Closed;
        errdefer scope.end();
        const record = scope.record;
        if (record.modalBlocker() != null) return error.ModalBlocked;
        if (!record.enabled_requested) return error.Disabled;
        const current = backend.state(record);
        if (!current.enabled) return error.Disabled;
        if (!current.visible or current.minimized or current.fullscreen or current.fullscreen_requested or (is_resize and (!record.options.resizable or current.maximized))) return error.InvalidWindowState;
        return scope;
    }
    /// Submit a native move using this window's current, unused pointer press.
    pub fn startMove(self: Window) !void {
        const scope = try self.beginInteraction(false);
        defer scope.end();
        if (!scope.record.options.movable) return error.InvalidWindowState;
        if (!backend.capabilities(scope.record).native_move_resize) return error.UnsupportedCapability;
        self.app.native_failure = null;
        backend.startMove(scope.record) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
    }
    pub fn startResize(self: Window, edge: ResizeEdge) !void {
        const scope = try self.beginInteraction(true);
        defer scope.end();
        if (!backend.capabilities(scope.record).native_move_resize) return error.UnsupportedCapability;
        self.app.native_failure = null;
        backend.startResize(scope.record, edge) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
    }
    pub fn showSystemMenu(self: Window) !void {
        const scope = try self.beginInteraction(false);
        defer scope.end();
        if (!backend.capabilities(scope.record).system_menu) return error.UnsupportedCapability;
        self.app.native_failure = null;
        backend.showSystemMenu(scope.record) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
    }
    pub fn capabilities(self: Window) !WindowCapabilities {
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        return backend.capabilities(scope.record);
    }
    pub fn clientBounds(self: Window) !ClientBounds {
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.app.native_failure = null;
        return backend.clientBounds(scope.record) catch |err| {
            self.app.report(self.app.failureDiagnostic(.window_update, err, self));
            return err;
        };
    }
    /// Current physical client dimensions and its DIP scale, without a paint.
    pub fn contentSize(self: Window) !Size {
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        return backend.contentSize(scope.record);
    }
    /// Changes normal client geometry. Restore and leave fullscreen first.
    pub fn setClientBounds(self: Window, bounds: ClientBounds) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        try validateClientSize(scope.record, bounds.width, bounds.height);
        const current = backend.state(scope.record);
        if (current.fullscreen or current.fullscreen_requested or current.minimized or current.maximized) return error.InvalidWindowState;
        self.app.native_failure = null;
        _ = scope.record.invalidatePointer(true);
        backend.setClientBounds(scope.record, bounds) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
    }
    /// GTK reports acceptance of a WM request; query state for observation.
    pub fn setFullscreen(self: Window, enabled: bool) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        self.app.native_failure = null;
        _ = scope.record.invalidatePointer(true);
        backend.setFullscreen(scope.record, enabled) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
        scope.record.emitState();
    }
    pub fn setAlwaysOnTop(self: Window, enabled: bool) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        self.app.native_failure = null;
        backend.setAlwaysOnTop(scope.record, enabled) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
        scope.record.emitState();
    }
    /// Show `cursor` while the pointer is over the client area, from now
    /// until it changes. Resize edges of a custom frame keep their own
    /// shapes; the window forgets the shape when it closes.
    pub fn setCursor(self: Window, shape: Cursor) !void {
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (scope.record.cursor == shape) return;
        scope.record.cursor = shape;
        backend.setCursor(scope.record, shape);
    }
    /// The shape last given to `setCursor`.
    pub fn currentCursor(self: Window) Cursor {
        const scope = self.beginCallback() orelse return .default;
        defer scope.end();
        return scope.record.cursor;
    }
    /// Requires `capabilities().backdrop_material`; the value is not saved by
    /// the framework and stays on the native window until changed or closed.
    pub fn setBackdrop(self: Window, material: WindowBackdrop) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        if (!backend.capabilities(scope.record).backdrop_material) return error.UnsupportedCapability;
        self.app.native_failure = null;
        backend.setBackdrop(scope.record, material) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
    }
    /// Sets the material behind what paint frames leave transparent; `.none`
    /// removes it. A window created without a material, or where materials
    /// are unavailable, keeps the value and shows none.
    pub fn setVibrancy(self: Window, material: Vibrancy) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        scope.record.vibrancy = material;
        backend.setVibrancy(scope.record, material);
    }
    pub fn vibrancy(self: Window) !Vibrancy {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        return record.vibrancy;
    }
    /// Whether the window shows its material wherever paint frames are
    /// transparent. Elsewhere, transparent frames show no material: paint a
    /// background there instead.
    pub fn showsVibrancy(self: Window) bool {
        const scope = self.beginCallback() orelse return false;
        defer scope.end();
        return scope.record.vibrancy != .none and backend.capabilities(scope.record).vibrancy;
    }
    pub fn traits(self: Window) !WindowTraits {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        return record.traits();
    }
    pub fn setResizable(self: Window, enabled: bool) !void {
        var value = try self.traits();
        value.resizable = enabled;
        try self.setTraits(value);
    }
    pub fn setMovable(self: Window, enabled: bool) !void {
        var value = try self.traits();
        value.movable = enabled;
        try self.setTraits(value);
    }
    pub fn setMinimizable(self: Window, enabled: bool) !void {
        var value = try self.traits();
        value.minimizable = enabled;
        try self.setTraits(value);
    }
    pub fn setMaximizable(self: Window, enabled: bool) !void {
        var value = try self.traits();
        value.maximizable = enabled;
        try self.setTraits(value);
    }
    pub fn setClosable(self: Window, enabled: bool) !void {
        var value = try self.traits();
        value.closable = enabled;
        try self.setTraits(value);
    }
    /// Applies all traits in one native style update. Disabling minimize or
    /// maximize requires `capabilities().window_buttons`.
    pub fn setTraits(self: Window, value: WindowTraits) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        const record = scope.record;
        if ((!value.minimizable or !value.maximizable) and !backend.capabilities(record).window_buttons) return error.UnsupportedCapability;
        if (std.meta.eql(record.traits(), value)) return;
        self.app.native_failure = null;
        _ = record.invalidatePointer(false);
        backend.setTraits(record, value) catch |err| {
            self.reportUpdateFailure(record, err);
            return err;
        };
        record.storeTraits(value);
        record.emitState();
    }
    /// The opaque color the content fills the window with (0xRRGGBB), or
    /// null for content that is not opaque. Windows shows it where the
    /// window grows before the content's frame of the new size presents,
    /// instead of black or the last frame stretched; other backends keep
    /// nothing. Content calls it when its background changes, from paint
    /// too; an unchanged value costs a comparison.
    pub fn setBackground(self: Window, rgb: ?u32) !void {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        if (record.background == rgb) return;
        record.background = rgb;
        if (comptime @hasDecl(backend, "setBackground")) backend.setBackground(record, rgb);
    }
    /// Whole-window translucency from 0 (invisible) to 1 (opaque).
    pub fn setOpacity(self: Window, value: f32) !void {
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidOpacity;
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        if (!backend.capabilities(scope.record).opacity) return error.UnsupportedCapability;
        if (scope.record.opacity == value) return;
        self.app.native_failure = null;
        backend.setOpacity(scope.record, value) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
        scope.record.opacity = value;
    }
    pub fn opacity(self: Window) !f32 {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        return record.opacity;
    }
    /// True lets pointer input pass through to whatever is below the window.
    /// Keyboard focus is unaffected.
    pub fn setIgnorePointer(self: Window, enabled: bool) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        if (!backend.capabilities(scope.record).ignore_pointer) return error.UnsupportedCapability;
        if (scope.record.ignore_pointer == enabled) return;
        self.app.native_failure = null;
        if (enabled) _ = scope.record.invalidatePointer(false);
        backend.setIgnorePointer(scope.record, enabled) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
        scope.record.ignore_pointer = enabled;
    }
    /// Keeps the window's pixels out of screenshots and screen recordings
    /// where the system honors the request.
    pub fn setContentProtection(self: Window, enabled: bool) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        if (!backend.capabilities(scope.record).content_protection) return error.UnsupportedCapability;
        self.app.native_failure = null;
        backend.setContentProtection(scope.record, enabled) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
    }
    /// Starts or stops drawing attention: Windows flashes the taskbar button
    /// until the window comes to the foreground; GTK sets the urgency hint.
    pub fn flashFrame(self: Window, enabled: bool) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        if (!backend.capabilities(scope.record).attention) return error.UnsupportedCapability;
        self.app.native_failure = null;
        backend.flashFrame(scope.record, enabled) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
    }
    pub fn setSkipTaskbar(self: Window, enabled: bool) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        if (!backend.capabilities(scope.record).skip_taskbar) return error.UnsupportedCapability;
        if (scope.record.skip_taskbar == enabled) return;
        self.app.native_failure = null;
        backend.setSkipTaskbar(scope.record, enabled) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
        scope.record.skip_taskbar = enabled;
    }
    /// Marks unsaved changes. Windows and Linux show a "*" before the title,
    /// as their editors do; `setTitle` keeps the mark.
    pub fn setDocumentEdited(self: Window, edited: bool) !void {
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const record = scope.record;
        if (record.document_edited == edited) return;
        record.document_edited = edited;
        self.applyTitle(record) catch |err| {
            record.document_edited = !edited;
            return err;
        };
    }
    pub fn isDocumentEdited(self: Window) !bool {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        return record.document_edited;
    }
    /// Copies the current title, without the edited mark, into `destination`.
    pub fn title(self: Window, destination: []u8) ![]const u8 {
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        if (destination.len < record.title.len) return error.ResultCapacityExceeded;
        @memcpy(destination[0..record.title.len], record.title);
        return destination[0..record.title.len];
    }
    fn applyTitle(self: Window, record: *WindowRecord) !void {
        const allocator = self.app.allocator;
        const shown = if (record.document_edited) try std.mem.concat(allocator, u8, &.{ "*", record.title }) else record.title;
        defer if (record.document_edited) allocator.free(shown);
        self.app.native_failure = null;
        backend.setTitle(record, shown) catch |err| {
            self.app.report(self.app.failureDiagnostic(.window_update, err, self));
            return err;
        };
    }
    fn beginUpdate(self: Window) !CallbackScope {
        const scope = self.beginCallback() orelse return error.Closed;
        if (scope.record.window_update_busy) {
            scope.end();
            return error.Busy;
        }
        scope.record.window_update_busy = true;
        return scope;
    }
    fn reportUpdateFailure(self: Window, record: *WindowRecord, err: anyerror) void {
        const diagnostic = self.app.failureDiagnostic(.window_update, err, self);
        record.emitState();
        self.app.report(diagnostic);
    }
    fn endUpdate(scope: CallbackScope) void {
        scope.record.window_update_busy = false;
        scope.end();
    }
    fn validateClientSize(record: *WindowRecord, width: u32, height: u32) !void {
        const options = record.options;
        if (width == 0 or height == 0 or width > 32768 or height > 32768 or width < options.min_width or height < options.min_height) return error.InvalidSize;
    }
    pub fn setTitle(self: Window, value: []const u8) !void {
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNul;
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        const record = scope.record;
        const copy = try self.app.allocator.dupe(u8, value);
        const previous = record.title;
        record.title = copy;
        self.applyTitle(record) catch |err| {
            record.title = previous;
            self.app.allocator.free(copy);
            return err;
        };
        self.app.allocator.free(previous);
    }
    pub fn resize(self: Window, width: u32, height: u32) !void {
        const scope = try self.beginUpdate();
        defer endUpdate(scope);
        try validateClientSize(scope.record, width, height);
        const current = backend.state(scope.record);
        if (current.fullscreen or current.fullscreen_requested) return error.InvalidWindowState;
        self.app.native_failure = null;
        _ = scope.record.invalidatePointer(true);
        backend.resize(scope.record, width, height) catch |err| {
            self.reportUpdateFailure(scope.record, err);
            return err;
        };
    }
    /// Install one borrowed native document client. Binding is explicit and may
    /// also be done by the host's focus callback. Replacement revokes the old
    /// generation before native cancellation or user notification.
    pub fn setTextClient(self: Window, client: TextClient) !TextClientToken {
        if (std.Thread.getCurrentId() != self.app.owner or client.owner != self.app.owner) return error.WrongThread;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const record = scope.record;
        if (record.text_busy) return error.Busy;
        if (record.text_generation == std.math.maxInt(u64)) return error.IdExhausted;
        record.text_busy = true;
        defer record.endTextCall();
        try record.revokeTextClient(.replaced, true);
        if (record.phase != .open) return error.Closed;
        if (record.text_blur_pending) return error.FocusLost;
        record.text_generation += 1;
        record.text_client = client;
        return .{ .window = self, .generation = record.text_generation };
    }
    pub fn clearTextClient(self: Window, token: TextClientToken) !bool {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        const scope = self.beginCallback() orelse return false;
        defer scope.end();
        const record = scope.record;
        if (!record.matchesTextClient(token)) return false;
        if (record.text_busy) return error.Busy;
        record.text_busy = true;
        defer record.endTextCall();
        try record.revokeTextClient(.cleared, true);
        return true;
    }
    /// Physical client ownership, independent of enabled/modal input policy.
    /// This owner-thread query performs no native operation or callback.
    pub fn hasTextClient(self: Window) !bool {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        const record = self.resolve() orelse return error.Closed;
        return record.text_client != null;
    }
    pub fn textClientToken(self: Window) ?TextClientToken {
        const record = self.resolve() orelse return null;
        return if (record.text_client != null and record.inputAllowed()) .{ .window = self, .generation = record.text_generation } else null;
    }
    pub fn readTextClient(self: Window, token: TextClientToken, storage: []u8) !text.Snapshot {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const record = scope.record;
        if (!record.matchesTextClient(token) or !record.inputAllowed()) return error.StaleTextClient;
        if (record.text_busy) return error.Busy;
        const client = record.text_client.?;
        record.text_busy = true;
        defer record.endTextCall();
        const pointer = self.app.suspendPointer();
        defer self.app.restorePointer(pointer);
        const value = try client.read(client.context, self, storage);
        if (!record.matchesTextClient(token) or !record.inputAllowed() or record.text_blur_pending) return error.StaleTextClient;
        try text.validate(value, storage);
        return value;
    }
    pub fn changeTextClient(self: Window, token: TextClientToken, change: text.Change) !text.ChangeResult {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const record = scope.record;
        if (!record.matchesTextClient(token) or !record.inputAllowed()) return error.StaleTextClient;
        if (record.text_busy) return error.Busy;
        const client = record.text_client.?;
        record.text_busy = true;
        defer record.endTextCall();
        const pointer = self.app.suspendPointer();
        defer self.app.restorePointer(pointer);
        const result = try client.change(client.context, self, change);
        if (result != .applied) return if (!record.matchesTextClient(token) or !record.inputAllowed() or record.text_blur_pending) .superseded else result;
        if (!record.matchesTextClient(token) or !record.inputAllowed() or record.text_blur_pending) return error.StaleTextClient;
        self.invalidate();
        return .applied;
    }
    pub fn setTextCaret(self: Window, bounds: Rect) !void {
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height) or bounds.width < 0 or bounds.height < 0 or @abs(bounds.x) > 1_000_000 or @abs(bounds.y) > 1_000_000 or bounds.width > 1_000_000 or bounds.height > 1_000_000) return error.InvalidGeometry;
        try backend.setTextCaret(scope.record, bounds);
    }
    pub fn cancelTextComposition(self: Window) !void {
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        try backend.cancelTextComposition(scope.record);
    }
    /// The successfully selected Window policy, independent of the user's IME
    /// open status. Windows .system restores this HWND's default IMM context.
    pub fn textInputMode(self: Window) !TextInputMode {
        return (try self.textInputStamp()).mode;
    }
    /// Allocation-free authority stamp for an in-flight native input operation.
    pub fn textInputStamp(self: Window) !TextInputStamp {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        return .{ .mode = record.text_input_mode, .epoch = record.text_input_epoch };
    }
    /// Cancellation is observable and cannot be rolled back. A callback that
    /// closes, rebinds or starts a new composition supersedes the old request.
    /// Nested transitions are Busy; setting the current mode has no effects.
    pub fn setTextInputMode(self: Window, mode: TextInputMode) !TextInputModeResult {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const record = scope.record;
        if (record.text_mode_busy) return error.Busy;
        if (record.text_input_mode == mode) return .applied;
        if (record.text_input_epoch == std.math.maxInt(u64)) return error.IdExhausted;
        record.text_mode_busy = true;
        defer record.text_mode_busy = false;
        const generation = record.text_generation;
        const allowed = record.inputAllowed();
        if (!try backend.cancelTextForMode(record)) return .superseded;
        if (record.phase != .open or self.app.phase == .stopping or self.app.phase == .stopped or record.text_generation != generation or record.inputAllowed() != allowed) return .superseded;
        return backend.setTextInputMode(record, mode);
    }
    pub fn invalidate(self: Window) void {
        const record = self.resolve() orelse return;
        if (record.phase == .open) backend.invalidate(record);
    }
    /// Queue client-area damage in DIP. The native update region coalesces
    /// requests; this does not promise partial command generation or GPU replay.
    pub fn invalidateRect(self: Window, bounds: Rect) !void {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height) or bounds.width < 0 or bounds.height < 0 or @abs(bounds.x) > 1_000_000 or @abs(bounds.y) > 1_000_000 or bounds.width > 1_000_000 or bounds.height > 1_000_000) return error.InvalidGeometry;
        if (bounds.width == 0 or bounds.height == 0) return;
        self.app.native_failure = null;
        backend.invalidateRect(scope.record, bounds) catch |err| {
            self.app.report(self.app.failureDiagnostic(.window_update, err, self));
            return err;
        };
    }
    /// Deliver `event` to the window's content as the platform adapter
    /// does, with the same pointer bookkeeping and input gating. Main
    /// thread only, outside the content's own callbacks; for measurement
    /// tools and checks that drive a real window.
    pub fn emitEvent(self: Window, event: Event) !void {
        if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        const record = self.resolve() orelse return error.Closed;
        if (record.phase != .open) return error.Closed;
        record.emit(event);
    }
    pub fn nativeHandle(self: Window) ?*anyopaque {
        const record = self.resolve() orelse return null;
        return if (record.phase == .open) backend.handle(record) else null;
    }
    pub fn requestClose(self: Window) !CloseResult {
        return self.requestCloseFrom(.application);
    }
    pub fn requestCloseFrom(self: Window, reason: CloseReason) !CloseResult {
        const record = self.resolve() orelse return .closed;
        record.pin();
        defer record.unpin();
        if (record.querying_close) return .in_progress;
        if (record.phase == .closing) return .deferred;
        if (reason == .user and !record.options.closable) return .cancelled;
        if (self.app.querying_close_tree or self.app.querying_quit) return .in_progress;
        self.app.querying_close_tree = true;
        self.app.activity_depth += 1;
        const allowed = allowed: {
            defer {
                self.app.querying_close_tree = false;
                self.app.leaveActivity();
            }
            var cursor: ?*WindowRecord = record;
            while (cursor) |item| {
                cursor = item.nextInTree(record);
                if (!item.allowClose(if (item == record) reason else .owner)) break :allowed false;
            }
            break :allowed true;
        };
        if (!allowed) return .cancelled;
        return self.destroy();
    }
    /// Force destruction; inside callbacks this waits for a backend safe point.
    pub fn destroy(self: Window) !CloseResult {
        const record = self.resolve() orelse return .closed;
        record.pin();
        defer record.unpin();
        if (record.phase == .closing) return .deferred;
        record.queueCloseTree();
        if (self.app.activity_depth != 0) return .deferred;
        self.app.refreshRelationships();
        try self.app.flushDestroys();
        self.app.refreshRelationships();
        self.app.restoreFocus();
        return if (record.closed_notified) .closed else .deferred;
    }
    /// Lifetime pin for ordinary composition/Region forwarding. This preserves
    /// the caller's ingress; independent SDK callbacks use beginNativeCallback.
    pub fn beginCallback(self: Window) ?CallbackScope {
        const record = self.resolve() orelse return null;
        if (record.phase != .open) return null;
        return record.enter();
    }
    /// Enter a real independent native callback while the Window is open.
    /// The App-only form also covers callbacks after Window closure.
    pub fn beginNativeCallback(self: Window) ?NativeCallbackScope {
        const record = self.resolve() orelse return null;
        if (record.phase != .open) return null;
        return record.enterNative();
    }
};

pub const AppCallbackScope = struct {
    app: *App,
    pub fn end(self: AppCallbackScope) void {
        self.app.assertOwner();
        self.app.leaveActivity();
    }
};

pub const NativeAppCallbackScope = struct {
    callback: AppCallbackScope,
    previous: ?*PointerIngress,
    pub fn end(self: NativeAppCallbackScope) void {
        const app = self.callback.app;
        self.callback.end();
        app.restorePointer(self.previous);
    }
};

pub const CallbackScope = struct {
    record: *WindowRecord,
    pub fn end(self: CallbackScope) void {
        const app = self.record.window.app;
        self.record.unpin();
        app.leaveActivity();
    }
};

const PointerState = struct { owner: pointer_press.Owner = .{}, domain: u64 = 1 };
const PointerIngress = struct { record: *WindowRecord, transition: pointer_press.Transition };
/// Native callback boundaries mask a suspended pointer callback. Ordinary
/// CallbackScope remains a lifetime pin and preserves composition/Region routing.
pub const NativeCallbackScope = struct {
    callback: CallbackScope,
    previous: ?*PointerIngress,
    pub fn end(self: NativeCallbackScope) void {
        const app = self.callback.record.window.app;
        self.callback.end();
        app.restorePointer(self.previous);
    }
};

/// Internal backend record, pinned for every native callback.
pub const WindowRecord = struct {
    pub const Phase = enum { creating, open, closing, closed };
    window: Window,
    options: WindowOptions,
    native: backend.WindowData = .{},
    vibrancy: Vibrancy = .none,
    background: ?u32 = null,
    pointer_state: ?*PointerState = null,
    content: ?Content = null,
    parent_destroy_notified: bool = false,
    service: ?WindowService = null,
    next_native_id: u32 = 1,
    text_client: ?TextClient = null,
    text_generation: u64 = 0,
    text_busy: bool = false,
    text_blur_pending: bool = false,
    text_revoking_native: bool = false,
    text_input_mode: TextInputMode = .system,
    text_input_epoch: u64 = 0,
    text_mode_busy: bool = false,
    phase: Phase = .creating,
    created: bool = false,
    closed_notified: bool = false,
    pins: usize = 0,
    querying_close: bool = false,
    window_update_busy: bool = false,
    hit_testing: bool = false,
    /// The pointer shape over the client area; see `Window.setCursor`.
    cursor: Cursor = .default,
    last_state: ?WindowState = null,
    owner_record: ?*WindowRecord = null,
    first_child: ?*WindowRecord = null,
    sibling_previous: ?*WindowRecord = null,
    sibling_next: ?*WindowRecord = null,
    modal_active: bool = false,
    modal_order: u64 = 0,
    modal_count: usize = 0,
    modal_last: ?*WindowRecord = null,
    modal_previous: ?*WindowRecord = null,
    modal_next: ?*WindowRecord = null,
    enabled_requested: bool = true,
    tree_root: ?*WindowRecord = null,
    blocked_by: ?*WindowRecord = null,
    destroying_native: bool = false,
    queued: bool = false,
    previous: ?*WindowRecord = null,
    next: ?*WindowRecord = null,
    pending_next: ?*WindowRecord = null,
    pending_previous: ?*WindowRecord = null,
    /// Owned by the record; the native title may add the edited mark.
    title: []u8 = &.{},
    document_edited: bool = false,
    focused: bool = false,
    opacity: f32 = 1,
    ignore_pointer: bool = false,
    skip_taskbar: bool = false,
    fn traits(self: *const WindowRecord) WindowTraits {
        return .{ .resizable = self.options.resizable, .movable = self.options.movable, .minimizable = self.options.minimizable, .maximizable = self.options.maximizable, .closable = self.options.closable };
    }
    fn storeTraits(self: *WindowRecord, value: WindowTraits) void {
        self.options.resizable = value.resizable;
        self.options.movable = value.movable;
        self.options.minimizable = value.minimizable;
        self.options.maximizable = value.maximizable;
        self.options.closable = value.closable;
    }
    /// Construction options that the native window starts without.
    fn applyInitialPolicy(self: *WindowRecord) !void {
        const options = self.options;
        const caps = backend.capabilities(self);
        const buttons = !options.minimizable or !options.maximizable;
        if (buttons and !caps.window_buttons) return error.UnsupportedCapability;
        // Native creation already applied `resizable`.
        if (buttons or !options.movable or !options.closable) try backend.setTraits(self, self.traits());
        if (options.opacity != 1) {
            if (!caps.opacity) return error.UnsupportedCapability;
            try backend.setOpacity(self, options.opacity);
            self.opacity = options.opacity;
        }
        if (options.skip_taskbar) {
            if (!caps.skip_taskbar) return error.UnsupportedCapability;
            try backend.setSkipTaskbar(self, true);
            self.skip_taskbar = true;
        }
    }
    fn createNative(self: *WindowRecord, options: WindowOptions) !void {
        if (options.native_pointer_clicks) {
            if (comptime !builtin.is_test and builtin.os.tag != .windows and builtin.os.tag != .linux) return error.UnsupportedCapability;
            const app = self.window.app;
            const previous = app.suspendPointer();
            const state = app.allocator.create(PointerState) catch |err| {
                app.restorePointer(previous);
                return err;
            };
            app.restorePointer(previous);
            state.* = .{};
            if (self.phase != .creating or app.phase == .stopping or app.phase == .stopped or (self.owner_record != null and self.owner_record.?.phase != .open)) {
                const hidden = app.suspendPointer();
                app.allocator.destroy(state);
                app.restorePointer(hidden);
                return error.CreateWindowFailed;
            }
            self.pointer_state = state;
        }
        try backend.create(self, options);
    }
    fn linkOwner(self: *WindowRecord, owner: *WindowRecord) void {
        owner.pin();
        self.owner_record = owner;
        self.tree_root = owner.tree_root orelse owner;
        self.blocked_by = owner.blocked_by;
        self.sibling_next = owner.first_child;
        if (owner.first_child) |first| first.sibling_previous = self;
        owner.first_child = self;
        if (self.tree_root.?.modal_last != null) self.window.app.relations_dirty = true;
    }
    fn unlinkOwner(self: *WindowRecord) void {
        const owner = self.owner_record orelse return;
        std.debug.assert(!self.modal_active);
        if (self.sibling_previous) |previous| previous.sibling_next = self.sibling_next else owner.first_child = self.sibling_next;
        if (self.sibling_next) |next| next.sibling_previous = self.sibling_previous;
        self.owner_record = null;
        self.tree_root = null;
        self.sibling_previous = null;
        self.sibling_next = null;
        owner.unpin();
    }
    fn nextInTree(self: *WindowRecord, root: *WindowRecord) ?*WindowRecord {
        if (self.first_child) |child| return child;
        return self.nextAfterTree(root);
    }
    fn nextAfterTree(self: *WindowRecord, root: *WindowRecord) ?*WindowRecord {
        var cursor = self;
        while (cursor != root) {
            if (cursor.sibling_next) |next| return next;
            cursor = cursor.owner_record orelse return null;
        }
        return null;
    }
    fn modalBlocker(self: *WindowRecord) ?*WindowRecord {
        const app = self.window.app;
        if (app.modal_total == 0) return null;
        if (!app.relations_dirty and !app.relations_busy) return self.blocked_by;
        const root = self.tree_root orelse self;
        const modal = root.modal_last orelse return null;
        var cursor: ?*WindowRecord = self;
        while (cursor) |item| : (cursor = item.owner_record) if (item == modal) return null;
        return modal;
    }
    fn setModalActive(self: *WindowRecord, active: bool) !void {
        if (!self.options.modal or self.modal_active == active) return;
        if (active) return self.activateModal(null);
        const owner = self.owner_record orelse return error.OwnerRequired;
        const root = self.tree_root.?;
        if (self.modal_previous) |previous| previous.modal_next = self.modal_next;
        if (self.modal_next) |next| next.modal_previous = self.modal_previous else root.modal_last = self.modal_previous;
        self.modal_previous = null;
        self.modal_next = null;
        owner.modal_count -= 1;
        self.window.app.modal_total -= 1;
        self.modal_active = false;
        self.window.app.relations_dirty = true;
    }
    fn activateModal(self: *WindowRecord, restoring_order: ?u64) !void {
        const owner = self.owner_record orelse return error.OwnerRequired;
        const app = self.window.app;
        if (owner.phase != .open) return error.Closed;
        if (owner.modal_count == std.math.maxInt(usize) or app.modal_total == std.math.maxInt(usize)) return error.TooManyModalWindows;
        const order = restoring_order orelse order: {
            if (app.next_modal_order == std.math.maxInt(u64)) return error.IdExhausted;
            const value = app.next_modal_order;
            app.next_modal_order += 1;
            break :order value;
        };
        const root = self.tree_root.?;
        var previous = root.modal_last;
        var next: ?*WindowRecord = null;
        while (previous) |item| {
            if (item.modal_order < order) break;
            next = item;
            previous = item.modal_previous;
        }
        self.modal_previous = previous;
        self.modal_next = next;
        if (previous) |item| item.modal_next = self;
        if (next) |item| item.modal_previous = self else root.modal_last = self;
        owner.modal_count += 1;
        app.modal_total += 1;
        self.modal_order = order;
        self.modal_active = true;
        app.relations_dirty = true;
    }
    fn queueCloseTree(self: *WindowRecord) void {
        var cursor = self;
        while (cursor.first_child) |child| cursor = child;
        while (true) {
            const next = if (cursor == self) null else if (cursor.sibling_next) |sibling| next: {
                var leaf = sibling;
                while (leaf.first_child) |child| leaf = child;
                break :next leaf;
            } else cursor.owner_record;
            if (!cursor.closed_notified) {
                if (cursor.phase == .open and cursor.owner_record != null and backend.isActive(cursor)) cursor.window.app.focus_restore = cursor.owner_record.?.window;
                if (cursor.phase == .open or cursor.phase == .creating) _ = cursor.invalidatePointer(false);
                if (cursor.phase != .closed) cursor.phase = .closing;
                cursor.window.app.scheduleDestroy(cursor);
            }
            cursor = next orelse break;
        }
    }
    fn observedState(self: *WindowRecord) WindowState {
        var current = backend.state(self);
        current.enabled_requested = self.enabled_requested;
        current.modal_blocked = self.modalBlocker() != null;
        return current;
    }
    fn pin(self: *WindowRecord) void {
        self.pins += 1;
    }
    fn unpin(self: *WindowRecord) void {
        std.debug.assert(self.pins != 0);
        self.pins -= 1;
        if (self.pins == 0 and self.phase == .closed) {
            std.debug.assert(self.content == null and self.closed_notified and self.first_child == null and self.owner_record == null);
            const app = self.window.app;
            const state = self.pointer_state;
            self.pointer_state = null;
            const previous = app.suspendPointer();
            if (state) |value| app.allocator.destroy(value);
            app.allocator.free(self.title);
            app.allocated_records -= 1;
            app.allocator.destroy(self);
            app.restorePointer(previous);
        }
    }
    pub fn enter(self: *WindowRecord) CallbackScope {
        self.pin();
        self.window.app.activity_depth += 1;
        return .{ .record = self };
    }
    pub fn enterNative(self: *WindowRecord) NativeCallbackScope {
        const callback = self.enter();
        return .{ .callback = callback, .previous = self.window.app.suspendPointer() };
    }
    pub fn pointerEnabled(self: *const WindowRecord) bool {
        return self.pointer_state != null;
    }
    /// Raw issuance watermark for pinned, main-thread content adapters. This
    /// observes identity only; it does not authorize a pointer operation.
    pub fn pointerSequenceHighWater(self: *const WindowRecord) ?u64 {
        const state = self.pointer_state orelse return null;
        return state.owner.last_sequence;
    }
    pub fn pointerOperation(self: *const WindowRecord) u64 {
        if (comptime @hasDecl(backend, "pointerOperation")) return backend.pointerOperation(self);
        return std.math.maxInt(u64);
    }
    fn pointerOperationCurrent(self: *const WindowRecord, operation: u64) bool {
        return operation != 0 and operation != std.math.maxInt(u64) and self.pointerOperation() == operation;
    }
    pub fn pointerCurrent(self: *WindowRecord, operation: u64) bool {
        const app = self.window.app;
        return app.phase != .stopping and app.phase != .stopped and self.inputAllowed() and self.pointerOperationCurrent(operation);
    }
    pub fn pointerDomain(self: *const WindowRecord) u64 {
        const state = self.pointer_state orelse return 0;
        return if (state.domain == std.math.maxInt(u64)) 0 else state.domain;
    }
    pub fn invalidatePointer(self: *WindowRecord, domain_changed: bool) u64 {
        const operation = if (comptime @hasDecl(backend, "advancePointerOperation")) backend.advancePointerOperation(self) else std.math.maxInt(u64);
        if (self.pointer_state != null) self.pointerRevoke(operation, domain_changed);
        return operation;
    }
    pub fn pointerRevoke(self: *WindowRecord, operation: u64, domain_changed: bool) void {
        const state = self.pointer_state orelse return;
        if (self.pointerOperation() != operation) return;
        if (operation == std.math.maxInt(u64)) {
            state.owner.retire();
            return;
        }
        if (!self.pointerOperationCurrent(operation)) return;
        if (!state.owner.revoke(operation)) return;
        if (domain_changed) state.domain = if (state.domain >= std.math.maxInt(u64) - 1) std.math.maxInt(u64) else state.domain + 1;
    }
    pub fn pointerBeginDown(self: *WindowRecord, operation: u64, button: ?PointerButton, timing: ?PointerClickTiming) ?pointer_press.Transition {
        const state = self.pointer_state orelse return null;
        if (!self.pointerCurrent(operation)) {
            if (self.pointerOperationCurrent(operation)) self.pointerRevoke(operation, false);
            return null;
        }
        var original = timing;
        if (original) |*value| {
            if (self.pointerDomain() == 0) original = null else value.position.domain = state.domain;
        }
        return state.owner.beginDown(operation, button, original);
    }
    pub fn pointerBeginUp(self: *WindowRecord, operation: u64, button: ?PointerButton) ?pointer_press.Transition {
        const state = self.pointer_state orelse return null;
        if (!self.pointerCurrent(operation)) {
            if (self.pointerOperationCurrent(operation)) self.pointerRevoke(operation, false);
            return null;
        }
        return state.owner.beginUp(operation, button);
    }
    pub fn pointerFinish(self: *WindowRecord, operation: u64, sequence: u64, button: ?PointerButton, phase: PointerPhase, disposition: PointerDisposition) bool {
        if (!self.pointerCurrent(operation)) return false;
        const state = self.pointer_state orelse return false;
        const input = button orelse return false;
        const transition = state.owner.lookup(operation, sequence, input, phase) orelse return false;
        return if (phase == .down) state.owner.finishDown(transition, disposition) else state.owner.finishUp(transition, disposition);
    }
    pub fn pointerMotion(self: *WindowRecord, operation: u64, position: ?ClickSample) void {
        const state = self.pointer_state orelse return;
        if (!self.pointerCurrent(operation)) return;
        var original = position;
        if (original) |*value| {
            if (self.pointerDomain() == 0) original = null else value.domain = state.domain;
        }
        _ = state.owner.motion(operation, original);
    }
    pub noinline fn emitPointer(self: *WindowRecord, operation: u64, sequence: u64, phase: PointerPhase, input: PointerButtonInput) void {
        if (!self.pointerCurrent(operation)) return;
        const state = self.pointer_state orelse return;
        const transition = state.owner.lookup(operation, sequence, input.button, phase);
        var delivered = input;
        delivered.press = if (transition) |value| value.press else .{};
        if (transition) |value| {
            const scope = self.enter();
            defer scope.end();
            var active: PointerIngress = .{ .record = self, .transition = value };
            const previous = self.window.app.active_pointer;
            self.window.app.active_pointer = &active;
            defer self.window.app.active_pointer = previous;
            self.emitInternal(if (phase == .down) .{ .pointer_down = delivered } else .{ .pointer_up = delivered }, true);
        } else self.emit(if (phase == .down) .{ .pointer_down = delivered } else .{ .pointer_up = delivered });
    }
    /// Only adapters with an exact current own-release/capture-owner fact call
    /// this. Other capture/focus losses use the ordinary revoking cancel path.
    pub fn emitPointerCancel(self: *WindowRecord, operation: u64, sequence: u64, button: PointerButton) void {
        if (!self.pointerCurrent(operation)) return;
        const state = self.pointer_state orelse {
            self.emitInternal(.cancel_input, false);
            return;
        };
        const transition = state.owner.lookup(operation, sequence, button, .up) orelse {
            if (sequence == 0) self.emitInternal(.cancel_input, false);
            return;
        };
        const scope = self.enter();
        defer scope.end();
        var active: PointerIngress = .{ .record = self, .transition = transition };
        const previous = self.window.app.active_pointer;
        self.window.app.active_pointer = &active;
        defer self.window.app.active_pointer = previous;
        self.emitInternal(.cancel_input, true);
    }
    /// Native lifecycle delivery after an earlier operation/domain revoke.
    /// Its captured operation prevents an old callback tail cancelling new input.
    pub fn emitPointerLifecycle(self: *WindowRecord, operation: u64, event: Event) void {
        if (self.pointerOperation() != operation) return;
        self.emitInternal(event, false);
    }
    pub fn inputAllowed(self: *WindowRecord) bool {
        return self.phase == .open and self.enabled_requested and self.modalBlocker() == null;
    }
    pub fn hitTest(self: *WindowRecord, position: Point, width: f32, height: f32) WindowHit {
        if (!self.inputAllowed() or self.options.decoration == .system or !std.math.isFinite(position.x) or !std.math.isFinite(position.y) or width <= 0 or height <= 0) return .client;
        const current = backend.state(self);
        if (current.fullscreen or current.fullscreen_requested) return .client;
        if (self.options.decoration == .custom and self.options.resizable and !current.maximized) {
            const border = @min(self.options.resize_border, @min(width, height) / 2);
            const left = position.x < border;
            const right = position.x >= width - border;
            const top = position.y < border;
            const bottom = position.y >= height - border;
            if (top) return if (left) .north_west else if (right) .north_east else .north;
            if (bottom) return if (left) .south_west else if (right) .south_east else .south;
            if (left) return .west;
            if (right) return .east;
        }
        const handler = self.options.hit_test orelse return .client;
        if (self.hit_testing) return .client;
        self.hit_testing = true;
        const scope = self.enter();
        defer {
            self.hit_testing = false;
            scope.end();
        }
        const pointer = self.window.app.suspendPointer();
        defer self.window.app.restorePointer(pointer);
        const result = handler.query(handler.context, self.window, position);
        if (!self.inputAllowed()) return .client;
        const after = backend.state(self);
        if (after.fullscreen or after.fullscreen_requested) return .client;
        if (result.resizeEdge() != null and (!self.options.resizable or after.maximized)) return .client;
        return result;
    }
    pub fn keyInput(self: *WindowRecord, input: KeyInput) bool {
        if (!self.inputAllowed()) return true;
        const scope = self.enter();
        defer scope.end();
        if (self.content) |content| if (content.key_input) |callback| {
            const epoch = self.text_input_epoch;
            const pointer = self.window.app.suspendPointer();
            defer self.window.app.restorePointer(pointer);
            const consumed = callback(content.context, self.window, input);
            if (consumed or !self.inputAllowed() or epoch != self.text_input_epoch) return true;
        };
        // A popup closes, as the user closing it, on an Escape its content
        // leaves unconsumed, as menus and popovers do.
        if (self.options.popup != null and input.key == .escape and std.meta.eql(input.modifiers, KeyModifiers{}) and self.phase == .open) {
            _ = self.window.requestCloseFrom(.user) catch |err| self.window.report(.{ .domain = .core, .operation = .window_destroy, .err = err });
            return true;
        }
        return false;
    }
    pub fn keyRelease(self: *WindowRecord, input: KeyInput) void {
        if (!self.inputAllowed()) return;
        const content = self.content orelse return;
        const callback = content.key_release orelse return;
        const scope = self.enter();
        defer scope.end();
        const pointer = self.window.app.suspendPointer();
        defer self.window.app.restorePointer(pointer);
        callback(content.context, self.window, input);
    }
    /// Adapter commit point. No rollback or retryable failure may follow it.
    pub fn publishTextInputMode(self: *WindowRecord, mode: TextInputMode) void {
        std.debug.assert(self.text_input_epoch != std.math.maxInt(u64));
        self.text_input_mode = mode;
        self.text_input_epoch += 1;
    }
    fn matchesTextClient(self: *WindowRecord, token: TextClientToken) bool {
        return self.text_client != null and self.text_generation == token.generation and token.window.app == self.window.app and std.meta.eql(token.window.key, self.window.key);
    }
    fn revokeTextClient(self: *WindowRecord, reason: text.UnbindReason, cancel_native: bool) anyerror!void {
        const client = self.text_client orelse return;
        const scope = self.enter();
        defer scope.end();
        self.text_client = null;
        self.text_blur_pending = false;
        var failure: ?anyerror = null;
        if (cancel_native and self.phase == .open) {
            const previous = self.text_revoking_native;
            self.text_revoking_native = true;
            defer self.text_revoking_native = previous;
            backend.cancelTextComposition(self) catch |err| {
                failure = err;
            };
        }
        if (client.unbound) |callback| {
            const pointer = self.window.app.suspendPointer();
            defer self.window.app.restorePointer(pointer);
            callback(client.context, self.window, reason);
        }
        if (failure) |err| return err;
    }
    fn endTextCall(self: *WindowRecord) void {
        const blurred = self.text_blur_pending;
        self.text_blur_pending = false;
        self.text_busy = false;
        if (blurred) self.revokeTextClient(.focus_lost, true) catch |err| self.window.report(.{ .domain = .core, .operation = .text_input, .err = err });
    }
    pub fn emit(self: *WindowRecord, event: Event) void {
        if (self.phase != .open) return;
        switch (event) {
            .focus => |focused| if (!focused) {
                _ = self.invalidatePointer(false);
            },
            .cancel_input => {
                _ = self.invalidatePointer(false);
            },
            .resize, .window_position => {
                _ = self.invalidatePointer(true);
            },
            else => {},
        }
        self.emitInternal(event, false);
    }
    fn emitInternal(self: *WindowRecord, event: Event, comptime native_pointer: bool) void {
        if (self.phase != .open) return;
        const scope = self.enter();
        defer scope.end();
        const pointer = if (native_pointer) null else self.window.app.suspendPointer();
        defer if (!native_pointer) self.window.app.restorePointer(pointer);
        // Backends deliver focus loss here directly, without `emit`.
        if (event == .focus and self.focused != event.focus) {
            self.focused = event.focus;
            self.window.app.markActivation();
        }
        if (event == .focus and !event.focus) {
            if (self.text_busy) self.text_blur_pending = true else self.revokeTextClient(.focus_lost, true) catch |err| self.window.report(.{ .domain = .core, .operation = .text_input, .err = err });
            if (self.phase != .open) return;
        }
        switch (event) {
            .pointer_down, .pointer_up, .pointer_move, .wheel, .text_input, .text_preedit, .edit_key, .key, .key_input => if (!self.inputAllowed()) return,
            else => {},
        }
        if (self.content) |content| {
            const delivered: Event = if (event == .text_preedit_cancel and self.text_revoking_native and self.text_client == null) .text_preedit_revoked else event;
            content.event(content.context, self.window, delivered);
        }
        if (event == .resize or event == .window_position) self.notifyOwnedPopups();
    }
    /// Popups follow their owner: each open one with an `owner_moved`
    /// handler hears that the owner's geometry changed.
    fn notifyOwnedPopups(self: *WindowRecord) void {
        var cursor = self.first_child;
        while (cursor) |child| {
            if (self.phase != .open) return;
            child.pin();
            defer {
                cursor = child.sibling_next;
                child.unpin();
            }
            if (child.phase != .open) continue;
            const role = child.options.popup orelse continue;
            const handler = role.handler orelse continue;
            const moved = handler.owner_moved orelse continue;
            const scope = child.enter();
            defer scope.end();
            moved(handler.context, child.window);
        }
    }
    /// Native backends report that a focusable popup was dismissed. Call it
    /// outside native activation handlers; destruction it requests is deferred.
    pub fn popupDismissed(self: *WindowRecord) void {
        if (self.phase != .open) return;
        const role = self.options.popup orelse return;
        if (!role.focusable) return;
        const handler = role.handler orelse return;
        const scope = self.enter();
        defer scope.end();
        const pointer = self.window.app.suspendPointer();
        defer self.window.app.restorePointer(pointer);
        handler.dismiss(handler.context, self.window);
    }
    pub fn emitState(self: *WindowRecord) void {
        if (self.phase != .open) return;
        const current = self.observedState();
        if (self.last_state) |previous| if (std.meta.eql(previous, current)) return;
        self.last_state = current;
        self.emit(.{ .window_state = current });
    }
    pub fn emitPointerState(self: *WindowRecord, operation: u64) void {
        if (self.phase != .open or self.pointerOperation() != operation) return;
        const current = self.observedState();
        if (self.phase != .open or self.pointerOperation() != operation) return;
        if (self.last_state) |previous| if (std.meta.eql(previous, current)) return;
        self.last_state = current;
        self.emitPointerLifecycle(operation, .{ .window_state = current });
    }
    fn allowClose(self: *WindowRecord, reason: CloseReason) bool {
        if (self.phase != .open) return true;
        if (self.querying_close) return false;
        const handler = self.options.on_close orelse return true;
        self.querying_close = true;
        const scope = self.enter();
        defer {
            self.querying_close = false;
            scope.end();
        }
        const pointer = self.window.app.suspendPointer();
        defer self.window.app.restorePointer(pointer);
        const decision = handler.request(handler.context, self.window, reason);
        return self.phase != .open or decision == .allow;
    }
    pub fn nativeDestroying(self: *WindowRecord) void {
        if (self.pointer_state) |state| state.owner.retire();
        self.phase = .closing;
        if (!self.parent_destroy_notified) {
            self.parent_destroy_notified = true;
            if (self.content) |content| if (content.native_parent_destroying) |notify| {
                const scope = self.enter();
                defer scope.end();
                const pointer = self.window.app.suspendPointer();
                defer self.window.app.restorePointer(pointer);
                notify(content.context);
            };
        }
        self.setModalActive(false) catch unreachable;
        var child = self.first_child;
        while (child) |item| : (child = item.sibling_next) {
            if (item.phase == .open or item.phase == .creating) item.queueCloseTree();
        }
        self.detachService();
        if (self.first_child != null or (self.window.app.activity_depth > 1 and (self.content != null or self.text_client != null or (self.created and self.options.on_closed != null and !self.closed_notified)))) {
            // A caller may bypass Window.destroy through nativeHandle. Keep
            // content alive if a pre-existing callback is still using it.
            if (!self.destroying_native) self.window.app.enqueueDestroy(self);
            return;
        }
        self.detachContent();
    }
    fn detachService(self: *WindowRecord) void {
        const service = self.service orelse return;
        self.service = null;
        const scope = self.enter();
        defer scope.end();
        const pointer = self.window.app.suspendPointer();
        defer self.window.app.restorePointer(pointer);
        service.native_destroying(service.context);
    }
    fn detachContent(self: *WindowRecord) void {
        self.revokeTextClient(.closed, false) catch unreachable;
        if (self.content) |content| {
            self.content = null;
            const scope = self.enter();
            defer scope.end();
            const pointer = self.window.app.suspendPointer();
            defer self.window.app.restorePointer(pointer);
            content.detach(content.context);
        }
    }
    fn notifyClosed(self: *WindowRecord) void {
        if (self.closed_notified) return;
        std.debug.assert(self.phase == .closed and self.content == null);
        self.closed_notified = true;
        if (self.created) {
            if (self.options.on_closed) |handler| {
                const scope = self.enter();
                defer scope.end();
                const pointer = self.window.app.suspendPointer();
                defer self.window.app.restorePointer(pointer);
                handler.notify(handler.context, self.window);
            }
        }
    }
    fn finishClosed(self: *WindowRecord) void {
        if (self.first_child != null) {
            self.window.app.enqueueDestroy(self);
            return;
        }
        self.detachContent();
        self.notifyClosed();
        self.unlinkOwner();
        if (self.created) self.window.app.maybeQuit();
    }
    pub fn nativeDestroyed(self: *WindowRecord) void {
        if (self.phase == .closed) return;
        self.nativeDestroying();
        const app = self.window.app;
        if (self.focused) {
            self.focused = false;
            app.markActivation();
        }
        if (app.quit_cursor == self) app.quit_cursor = self.next;
        if (app.relation_cursor == self) app.relation_cursor = self.next;
        _ = app.windows.remove(self.window.key);
        if (self.previous) |previous| previous.next = self.next else app.first = self.next;
        if (self.next) |next| next.previous = self.previous;
        self.previous = null;
        self.next = null;
        self.phase = .closed;
        if (self.destroying_native) return;
        if (self.queued or self.owner_record != null or self.first_child != null) {
            app.enqueueDestroy(self);
            return;
        }
        self.finishClosed();
    }
};

test {
    _ = app_stop;
    _ = @import("physical_keys.zig");
    _ = @import("app_shutdown_test.zig");
    _ = mailbox;
    _ = registry;
    _ = diagnostics;
    _ = windows_text;
    _ = text;
    _ = composition;
    _ = @import("text_client_test.zig");
    _ = @import("text_input_mode_test.zig");
    _ = @import("lifecycle_test.zig");
    _ = @import("window_registry_test.zig");
    _ = @import("damage_test.zig");
    _ = @import("diagnostics_test.zig");
    _ = @import("platform/decoration_test.zig");
    _ = @import("platform/work_area.zig");
    _ = @import("pointer_press_test.zig");
    _ = @import("window_policy_test.zig");
}

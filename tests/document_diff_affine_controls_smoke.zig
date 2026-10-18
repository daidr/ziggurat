const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const e = @import("ziggurat_document_editor");
const t = @import("ziggurat_text_layout");
const ui = @import("ziggurat_ui");
const diff = @import("ziggurat_document_diff");
const v = @import("ziggurat_document_diff_view");
const a = @import("ziggurat_document_accessibility");
const paired = @import("ziggurat_document_diff_accessibility");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("objbase.h");
}) else struct {};
extern fn zdd_probe_auxiliary(*anyopaque, u32, *f64) i32;
extern fn zdd_probe_auxiliary_hit_mta(*anyopaque, *anyopaque, f64, f64) i32;
extern fn zda_probe_release(*anyopaque) void;
extern fn zda_probe_bounds(*anyopaque, [*]f64, f64, f64) i32;
extern fn zdac_probe_storage([*]u64) void;
const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 320, .height = 170 };
const extent: ui.layout.Size = .{ .width = 440, .height = 280 };
const button: ui.Rect = .{ .x = 8, .y = 194, .width = 140, .height = 24 };
const texts = [2][]const u8{
    "head\nold\nsame 0\nsame 1\nsame 2\nsame 3\nsame 4\nsame 5\nsame 6\nsame 7\nsame 8\nlast",
    "head\nnew\nsame 0\nsame 1\nsame 2\nsame 3\nsame 4\nsame 5\nsame 6\nsame 7\nsame 8\nlast",
};
const AllocationProbe = struct {
    source: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    lease: ?*e.PresentationLease = null,
    arm: enum { none, allocate, free } = .none,
    fired: bool = false,
    renew: bool = false,
    fn allocator(self: *AllocationProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn revoke(self: *AllocationProbe, stage: @FieldType(AllocationProbe, "arm")) void {
        if (self.arm != stage) return;
        self.arm = .none;
        self.fired = true;
        const lease = self.lease.?;
        if (self.renew) {
            const previous = lease.snapshot() catch unreachable;
            const generation = lease.begin(lease.publisher) catch unreachable;
            lease.commit(lease.publisher, generation, previous.stamp) catch unreachable;
        } else _ = lease.withdraw() catch unreachable;
    }
    fn allocate(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *AllocationProbe = @ptrCast(@alignCast(ptr));
        const result = self.source.rawAlloc(len, alignment, ret) orelse return null;
        self.allocations += 1;
        self.revoke(.allocate);
        return result;
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *AllocationProbe = @ptrCast(@alignCast(ptr));
        return self.source.rawResize(bytes, alignment, len, ret);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *AllocationProbe = @ptrCast(@alignCast(ptr));
        return self.source.rawRemap(bytes, alignment, len, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *AllocationProbe = @ptrCast(@alignCast(ptr));
        self.frees += 1;
        self.revoke(.free);
        self.source.rawFree(bytes, alignment, ret);
    }
};
const Host = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    documents: [2]*d.Document = undefined,
    inbox: *v.Inbox = undefined,
    view: *v.EditableSplit = undefined,
    bridge: ?*paired.Bridge = null,
    controls: paired.controls.Controls = undefined,
    parameters: v.Parameters = .{ .font = .{ .size = 15, .wrap = .word_character } },
    matrix: ui.affine.Affine = .{ .xy = 0.25, .x0 = 28, .y0 = 18 },
    offset: ui.layout.Point = .{ .x = 3, .y = 5 },
    clip: ?ui.Rect = null,
    fail_frame: bool = false,
    omit: bool = false,
    disabled: bool = false,
    mismatch: enum { none, offset, clip, transform } = .none,
    failure: ?anyerror = null,
    expected: ?anyerror = null,
    calls: usize = 0,
    outcome: ?paired.controls.Outcome = null,
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (value.err) |err| if (self.expected == null or self.expected.? != err) {
            self.failure = err;
        };
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            frame.failure = err;
            if (self.expected == null or self.expected.? != err) self.failure = err;
        };
    }
    fn drawChecked(self: *Host, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        if (self.omit) return;
        if (self.clip) |clip| try frame.pushClip(clip);
        defer if (self.clip != null) frame.popClip() catch unreachable;
        try frame.beginTransform(extent, self.matrix);
        defer frame.endTransform() catch unreachable;
        try frame.pushOffset(self.offset);
        defer frame.popOffset() catch unreachable;
        if (self.mismatch == .none) {
            try self.bridge.?.draw(frame, .{});
        } else {
            try self.view.draw(frame, bounds, .{});
            try self.bridge.?.record(frame);
            switch (self.mismatch) {
                .none => unreachable,
                .offset => try frame.pushOffset(.{ .x = 1 }),
                .clip => try frame.pushClip(.{ .x = 0, .y = 0, .width = 330, .height = 225 }),
                .transform => try frame.beginTransform(extent, .{}),
            }
            try self.controls.draw(frame);
            switch (self.mismatch) {
                .none => unreachable,
                .offset => try frame.popOffset(),
                .clip => try frame.popClip(),
                .transform => try frame.endTransform(),
            }
            const bank = &self.controls.banks[self.controls.active];
            try self.bridge.?.native.?.recordAuxiliaryLocal(frame, bank.bounds[0..bank.len]);
        }
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn action(ptr: *anyopaque, id: u64) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.outcome = self.bridge.?.controlAction(id) catch |err| {
            self.failure = err;
            return;
        };
        self.calls += 1;
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        return self.bridge.?.handleEvent(event, self.parameters) catch |err| {
            if (self.expected == null or self.expected.? != err) self.failure = err;
            return true;
        };
    }
    fn publish(self: *Host, allocator: std.mem.Allocator) !void {
        const job = try self.inbox.begin();
        defer _ = self.inbox.finish(job.ticket) catch unreachable;
        var released = false;
        defer if (!released) job.release() catch unreachable;
        var result = try diff.compare(allocator, job.a, job.b, .{});
        defer result.deinit();
        try job.release();
        released = true;
        try self.inbox.publish(job.ticket, &result);
    }
    fn prepare(self: *Host) !void {
        try self.view.prepare(bounds, self.parameters);
        const sa = try self.documents[0].snapshot();
        defer sa.close() catch unreachable;
        const sb = try self.documents[1].snapshot();
        defer sb.close() catch unreachable;
        const ra = try sa.borrowReader();
        defer ra.release() catch unreachable;
        const rb = try sb.borrowReader();
        defer rb.release() catch unreachable;
        try self.bridge.?.prepare(.{ ra, rb });
        try self.plan("Action");
    }
    fn plan(self: *Host, name: []const u8) !void {
        const hunk: paired.controls.Hunk = .{ .index = 0, .original_to_modified = .{ .bounds = button, .name = name, .enabled = !self.disabled } };
        try self.bridge.?.prepareControls(.{ .bounds = .{ .x = 4, .y = 4, .width = 330, .height = 220 }, .hunks = &.{hunk} });
    }
    fn paint(self: *Host) !void {
        _ = c.InvalidateRect(self.window.nativeHandle(), null, 0);
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        if (self.failure) |err| return err;
    }
    fn install(self: *Host) !void {
        try self.bridge.?.setCommittedSpace(try self.context.committedSpace(91));
    }
    fn node(self: *Host, kind: a.auxiliary.Kind) !a.auxiliary.Node {
        const bank = &self.controls.banks[self.controls.active];
        for (bank.nodes[0..bank.len]) |value| if (value.key.kind == kind) return value;
        return error.MissingControl;
    }
    fn point(self: *Host, x: f64, y: f64) ui.affine.Point {
        // The public native transform contract rounds each forward coefficient
        // through f32. Reproduce that numeric contract independently, without
        // consulting the actual Frame Mapping or transforming its returned AABB.
        const matrix: ui.affine.Affine = .{
            .xx = @as(f32, @floatCast(self.matrix.xx)),
            .yx = @as(f32, @floatCast(self.matrix.yx)),
            .xy = @as(f32, @floatCast(self.matrix.xy)),
            .yy = @as(f32, @floatCast(self.matrix.yy)),
            .x0 = @as(f32, @floatCast(self.matrix.x0)),
            .y0 = @as(f32, @floatCast(self.matrix.y0)),
        };
        // The local Frame offset is applied once, after coefficient rounding.
        const px = x + self.offset.x;
        const py = y + self.offset.y;
        return .{ .x = matrix.xx * px + matrix.xy * py + matrix.x0, .y = matrix.yx * px + matrix.yy * py + matrix.y0 };
    }
    fn click(self: *Host, location: ui.affine.Point) !void {
        const x: u16 = @intFromFloat(location.x * self.parameters.scale);
        const y: u16 = @intFromFloat(location.y * self.parameters.scale);
        const position: isize = @intCast(@as(u32, x) | (@as(u32, y) << 16));
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_LBUTTONDOWN, c.MK_LBUTTON, position);
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_LBUTTONUP, 0, position);
        if (self.failure) |err| return err;
    }
    fn key(self: *Host, keycode: usize) !void {
        var saved: [256]u8 = undefined;
        try std.testing.expect(c.GetKeyboardState(&saved) != 0);
        defer std.debug.assert(c.SetKeyboardState(&saved) != 0);
        var plain: [256]u8 = @splat(0);
        try std.testing.expect(c.SetKeyboardState(&plain) != 0);
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_KEYDOWN, keycode, 0);
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_KEYUP, keycode, 0);
        if (self.failure) |err| return err;
    }
};
fn invoke(provider: *anyopaque, kind: u32) !i32 {
    const Worker = struct {
        provider: *anyopaque,
        kind: u32,
        hr: i32 = 0,
        fn run(self: *@This()) void {
            var ignored: f64 = 0;
            self.hr = zdd_probe_auxiliary(self.provider, self.kind, &ignored);
        }
    };
    var worker: Worker = .{ .provider = provider, .kind = kind };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    return worker.hr;
}
fn geometry(root: *anyopaque, provider: *anyopaque, x: f64, y: f64, rectangle: *[4]f64) !i32 {
    const Worker = struct {
        root: *anyopaque,
        provider: *anyopaque,
        x: f64,
        y: f64,
        rectangle: *[4]f64,
        hr: i32 = 0,
        fn run(self: *@This()) void {
            self.hr = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
            if (self.hr < 0) return;
            defer c.CoUninitialize();
            self.hr = zda_probe_bounds(self.provider, self.rectangle, self.x, self.y);
            if (self.hr >= 0) self.hr = zdd_probe_auxiliary_hit_mta(self.root, self.provider, self.x, self.y);
        }
    };
    var worker: Worker = .{ .root = root, .provider = provider, .x = x, .y = y, .rectangle = rectangle };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    return worker.hr;
}
fn scenario(allocator: std.mem.Allocator, unified: bool) !void {
    var host: Host = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer app.deinit();
    const engine = try t.Engine.create(allocator, app.owner, .{});
    defer engine.close() catch unreachable;
    host.documents = .{ try d.Document.create(allocator, app.owner, texts[0], .{}), try d.Document.create(allocator, app.owner, texts[1], .{}) };
    defer for (host.documents) |document| document.close() catch unreachable;
    const adapters = [2]*e.Adapter{ try e.Adapter.create(allocator, host.documents[0], engine, .{}), try e.Adapter.create(allocator, host.documents[1], engine, .{}) };
    defer for (adapters) |adapter| adapter.close() catch unreachable;
    host.inbox = try v.Inbox.create(allocator, .{ .a = host.documents[0], .b = host.documents[1] }, .{});
    defer host.inbox.close() catch unreachable;
    host.window = try app.createWindow(.{ .width = 520, .height = 340 });
    defer {
        _ = host.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    // Hidden-window input tests establish thread-local focus explicitly. OS
    // foreground activation remains a separate operation that may be denied.
    _ = c.SetFocus(host.window.nativeHandle());
    try std.testing.expect(c.GetFocus() == host.window.nativeHandle());
    host.parameters.scale = (try host.window.contentSize()).scale;
    var view_probe: AllocationProbe = .{ .source = allocator };
    const target: paired.Target = if (unified) .{ .unified = try v.EditableUnified.create(view_probe.allocator(), host.inbox, adapters[0], adapters[1], host.window, .{}) } else .{ .split = try v.EditableSplit.create(view_probe.allocator(), host.inbox, adapters[0], adapters[1], host.window, .{}) };
    host.view = switch (target) {
        .split => |value| value,
        .unified => |value| value.coordinator(),
    };
    defer host.view.close() catch unreachable;
    try host.view.setContext(.{ .context_lines = 1, .minimum_hidden = 3 });
    try host.publish(allocator);
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    host.context.render_mode = .gdi;
    host.context.on_input = Host.input;
    try host.context.attach(host.window);
    try host.context.prepareTransforms(allocator, .{ .layers = .{ .size = try host.window.contentSize(), .max_depth = 3 }, .source_size = extent });
    host.controls = try paired.controls.Controls.init(0x414646494e45, 10000, .{});
    var bridge_probe: AllocationProbe = .{ .source = allocator };
    var failing = std.testing.FailingAllocator.init(bridge_probe.allocator(), .{});
    // Original production RED: this exact real configuration returns
    // UnsupportedAuxiliaryConfiguration before it can lend a coordinate lease.
    host.bridge = try paired.Bridge.create(failing.allocator(), host.window, target, .{ .accessibility = .{ .affine_geometry = true, .cells = 512, .carets = 512, .lines = 64 }, .controls = &host.controls, .affine_space_id = 91 });
    defer if (host.bridge) |bridge| bridge.close() catch unreachable;
    try host.bridge.?.attachContext(&host.context);
    try host.prepare();
    try host.paint();
    try host.install();
    view_probe.lease = try host.bridge.?.coordinates.?.publication();
    const control = try host.node(.invoke);
    const provider = try host.bridge.?.retainAuxiliaryProvider(control.key);
    defer zda_probe_release(provider);
    const root = try host.bridge.?.retainProvider(null);
    defer zda_probe_release(root);
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    try std.testing.expect(c.ClientToScreen(host.window.nativeHandle(), &origin) != 0);
    const allocation_counts = [2]usize{ view_probe.allocations, bridge_probe.allocations };
    const native_bytes = (try host.bridge.?.stats()).requested_bytes;
    const matrices = [_]ui.affine.Affine{ host.matrix, .{ .xx = -0.8, .xy = 0.15, .yy = 1.05, .x0 = 380, .y0 = 12 }, try (try ui.affine.Affine.rotation(0.15)).then(.{ .x0 = 70, .y0 = 12 }) };
    for (matrices) |matrix| {
        host.matrix = matrix;
        try host.paint();
        try host.install();
        const point = host.point(button.x + 20, button.y + 10);
        // The toolbar is outside the body's capture bounds. It shares the
        // matrices, not the body's visible polygon.
        var rectangle: [4]f64 = undefined;
        try std.testing.expectEqual(@as(i32, 0), try geometry(root, provider, @as(f64, @floatFromInt(origin.x)) + point.x * host.parameters.scale, @as(f64, @floatFromInt(origin.y)) + point.y * host.parameters.scale, &rectangle));
        const corners = [_]ui.affine.Point{ host.point(button.x, button.y), host.point(button.x + button.width, button.y), host.point(button.x + button.width, button.y + button.height), host.point(button.x, button.y + button.height) };
        var left = corners[0].x;
        var right = left;
        var top = corners[0].y;
        var bottom = top;
        for (corners[1..]) |corner| {
            left = @min(left, corner.x);
            right = @max(right, corner.x);
            top = @min(top, corner.y);
            bottom = @max(bottom, corner.y);
        }
        const expected = [4]f64{ @as(f64, @floatFromInt(origin.x)) + left * host.parameters.scale, @as(f64, @floatFromInt(origin.y)) + top * host.parameters.scale, (right - left) * host.parameters.scale, (bottom - top) * host.parameters.scale };
        for (rectangle, expected) |actual, wanted| try std.testing.expectApproxEqAbs(wanted, actual, 1e-6);
        try std.testing.expectEqual(control.frame_id, (try host.context.hitControl(.{ .x = @floatCast(point.x), .y = @floatCast(point.y) })).?.id);
    }
    try std.testing.expectEqualDeep(allocation_counts, [2]usize{ view_probe.allocations, bridge_probe.allocations });
    try std.testing.expectEqual(native_bytes, (try host.bridge.?.stats()).requested_bytes);
    for ([_]@FieldType(Host, "mismatch"){ .offset, .clip, .transform }) |mismatch| {
        const accepted = try view_probe.lease.?.snapshot();
        host.mismatch = mismatch;
        host.expected = if (mismatch == .offset) error.AuxiliaryPlanMismatch else error.SemanticScopeMismatch;
        try host.paint();
        host.mismatch = .none;
        host.expected = null;
        try std.testing.expectEqualDeep(accepted, try view_probe.lease.?.snapshot());
    }
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, host.plan("OOM candidate"));
    failing.fail_index = std.math.maxInt(usize);
    // Failure during candidate allocation keeps the accepted bank actionable.
    try std.testing.expectEqual(@as(i32, 0), try invoke(provider, 4));
    try app.dispatch();
    if (host.failure) |err| return err;
    try std.testing.expect(host.context.input_state.focused != null);
    try std.testing.expectEqual(@as(?u64, control.frame_id), host.context.input_state.focused);
    // Same Diff epoch, different successful Space: the older queued Invoke
    // must not acquire the newer publication when owner dispatch eventually runs.
    const version = try host.documents[1].version();
    try std.testing.expectEqual(@as(i32, 0), try invoke(provider, 1));
    host.matrix.x0 += 7;
    try host.paint();
    try host.install();
    try app.dispatch();
    try std.testing.expectEqual(version, try host.documents[1].version());
    // Failed frame keeps the accepted input/native front. A merely prepared
    // bank cannot steal its key -> Frame ID focus association.
    try host.bridge.?.prepareControls(.{ .bounds = .{ .x = 4, .y = 4, .width = 330, .height = 220 }, .hunks = &.{} });
    host.fail_frame = true;
    host.expected = error.InvalidGeometry;
    try host.paint();
    host.fail_frame = false;
    host.expected = null;
    try std.testing.expectEqual(@as(i32, 0), try invoke(provider, 4));
    try app.dispatch();
    if (host.failure) |err| return err;
    try std.testing.expect(host.context.input_state.focused != null);
    try std.testing.expectEqual(@as(?u64, control.frame_id), host.context.input_state.focused);
    try std.testing.expect(!(try host.window.hasTextClient()));
    try host.plan("Action");
    // Explicit parent clip cuts the sheared toolbar. Test points against an
    // independent scalar forward map and the axis-aligned parent clip, including
    // points inside the transformed AABB but outside the real quadrilateral.
    host.matrix = matrices[0];
    host.clip = .{ .x = 60, .y = 0, .width = 110, .height = 320 };
    try host.paint();
    try host.install();
    const clip_control = try host.node(.invoke);
    const clip_provider = try host.bridge.?.retainAuxiliaryProvider(clip_control.key);
    defer zda_probe_release(clip_provider);
    for ([_]f64{ -5, 2, 40, 100, 138, 145 }) |dx| {
        const point = host.point(button.x + dx, button.y + 10);
        const allowed = dx >= 0 and dx < button.width and point.x >= host.clip.?.x and point.x < host.clip.?.x + host.clip.?.width;
        const hit = try host.context.hitControl(.{ .x = @floatCast(point.x), .y = @floatCast(point.y) });
        try std.testing.expectEqual(allowed, hit != null and hit.?.id == clip_control.frame_id);
        var rectangle: [4]f64 = undefined;
        const hr = try geometry(root, clip_provider, @as(f64, @floatFromInt(origin.x)) + point.x * host.parameters.scale, @as(f64, @floatFromInt(origin.y)) + point.y * host.parameters.scale, &rectangle);
        try std.testing.expectEqual(allowed, hr >= 0);
    }
    host.clip = null;
    try host.paint();
    try host.install();
    // A context action must carry its entering generation through allocation
    // and a pre-pair free. Renew the same valid stamp with a NEW generation:
    // a mere existence check would accept it. Context projection frees its raw Index
    // before entering projectPairWithFolds, so neither root may publish here.
    for ([_]@FieldType(AllocationProbe, "arm"){ .allocate, .free }) |stage| {
        const disclosure = try host.node(.disclosure);
        const intent = try host.controls.intent(disclosure.key, true);
        const folds = [2]u64{ (try adapters[0].status()).fold_version, (try adapters[1].status()).fold_version };
        const revisions = [2]u64{ try host.documents[0].version(), try host.documents[1].version() };
        view_probe.arm = stage;
        view_probe.fired = false;
        view_probe.renew = true;
        try std.testing.expectError(error.StalePresentation, host.view.setContextPresented(host.bridge.?.prepared_epoch, intent.context.key, false));
        try std.testing.expect(view_probe.fired);
        try std.testing.expectEqualDeep(folds, [2]u64{ (try adapters[0].status()).fold_version, (try adapters[1].status()).fold_version });
        try std.testing.expectEqualDeep(revisions, [2]u64{ try host.documents[0].version(), try host.documents[1].version() });
        try host.prepare();
        try host.paint();
        try host.install();
        var regions: [96]v.editable.ContextRegion = undefined;
        try std.testing.expect((try host.view.contextRegions(&regions))[0].collapsed);
    }
    const disclosure = try host.node(.disclosure);
    const disclosure_provider = try host.bridge.?.retainAuxiliaryProvider(disclosure.key);
    defer zda_probe_release(disclosure_provider);
    const revisions = [2]u64{ try host.documents[0].version(), try host.documents[1].version() };
    try std.testing.expectEqual(@as(i32, 0), try invoke(disclosure_provider, 2));
    try app.dispatch();
    try std.testing.expectEqualDeep(revisions, [2]u64{ try host.documents[0].version(), try host.documents[1].version() });
    try host.prepare();
    try host.paint();
    try host.install();
    var regions: [96]v.editable.ContextRegion = undefined;
    try std.testing.expect(!(try host.view.contextRegions(&regions))[0].collapsed);
    try std.testing.expectEqual(@as(i32, 0), try invoke(disclosure_provider, 3));
    try app.dispatch();
    try host.prepare();
    try host.paint();
    try host.install();
    try std.testing.expect((try host.view.contextRegions(&regions))[0].collapsed);
    host.disabled = true;
    try host.plan("Action");
    try host.paint();
    try host.install();
    try std.testing.expect((try invoke(provider, 1)) < 0);
    try host.click(host.point(button.x + 20, button.y + 10));
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    try std.testing.expectEqual(version, try host.documents[1].version());
    host.disabled = false;
    try host.plan("Action");
    // A successful missing front withdraws both auxiliary and body authority.
    host.omit = true;
    try host.paint();
    try std.testing.expect((try invoke(provider, 1)) < 0);
    host.omit = false;
    try host.paint();
    try host.install();
    // Real owner pointer activation uses the accepted inverse/clip once.
    try host.click(host.point(button.x + 20, button.y + 10));
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expect(host.outcome.?.changed);
    var output: [256]u8 = undefined;
    const length = try host.documents[1].byteLength();
    _ = try host.documents[1].read(.{ .start = 0, .end = length }, &output);
    try std.testing.expectEqualStrings(texts[0], output[0..length]);
    try std.testing.expect(try host.documents[1].undo());
    try std.testing.expectEqual(version + 2, try host.documents[1].version());
    // Exercise the accepted Context focus model again after the explicit host
    // comparison/preparation boundary, then activate through plain Tab/Space.
    try host.publish(allocator);
    try host.prepare();
    try host.paint();
    try host.install();
    try host.context.blurControls();
    try host.view.focus(.b);
    try std.testing.expect(try host.window.hasTextClient());
    try host.key(c.VK_TAB);
    const current_control = try host.node(.invoke);
    try std.testing.expectEqual(@as(?u64, current_control.frame_id), host.context.input_state.focused);
    try std.testing.expect(!(try host.window.hasTextClient()));
    try host.key(c.VK_SPACE);
    try std.testing.expectEqual(@as(usize, 2), host.calls);
    try std.testing.expect(host.outcome.?.changed);
    try std.testing.expect(try host.documents[1].undo());
    try std.testing.expectEqual(version + 4, try host.documents[1].version());
    const costs = try host.bridge.?.stats();
    std.debug.print("affine controls {s} charged bytes: current={d} peak={d} host={d}\n", .{ if (unified) "unified" else "split", costs.requested_bytes, costs.peak_reserved_bytes, costs.host_staging_bytes });
    try host.publish(allocator);
    try host.prepare();
    try host.paint();
    try host.install();
    const terminal_control = try host.node(.invoke);
    const late = try host.bridge.?.retainAuxiliaryProvider(terminal_control.key);
    defer zda_probe_release(late);
    // Keep an actually accepted MTA action queued across callback-delayed close.
    try std.testing.expectEqual(@as(i32, 0), try invoke(late, 4));
    try host.context.blurControls();
    try host.view.focus(.b);
    try std.testing.expect(try host.view.handleEvent(.{ .text_preedit = .{ .text = "候\n选", .selection_start = 0, .selection_end = 3 } }, bounds, host.parameters));
    try host.bridge.?.native.?.updateMetadata();
    const composing_version = try host.documents[1].version();
    try std.testing.expect((try invoke(late, 1)) < 0);
    try std.testing.expectEqual(composing_version, try host.documents[1].version());
    try std.testing.expect(try host.documents[1].composition() != null);
    const lease = try host.bridge.?.coordinates.?.publication();
    var pin = try host.bridge.?.coordinates.?.pin();
    try std.testing.expectError(error.Busy, host.bridge.?.close());
    pin.end();
    host.expected = error.Closed;
    const scope = host.window.beginCallback().?;
    try std.testing.expectEqual(z.CloseResult.deferred, try host.window.destroy());
    try std.testing.expectError(error.UnbindPending, host.bridge.?.close());
    try std.testing.expect(try host.documents[1].composition() != null);
    scope.end();
    try app.dispatch();
    try std.testing.expect(try host.documents[1].composition() == null);
    // The old counter-exhaustion cleanup contract applies to typed auxiliary
    // storage as well: permanent denial cannot strand unbind or its last owner.
    lease.generation = std.math.maxInt(u64) - 1;
    _ = try lease.withdraw();
    try std.testing.expectError(error.IdExhausted, lease.snapshot());
    try host.bridge.?.close();
    host.bridge = null;
    try std.testing.expect((try invoke(late, 1)) < 0);
    host.expected = null;
    if (host.failure) |err| return err;
}
pub fn main() !void {
    if (builtin.os.tag != .windows) return error.UnsupportedCapability;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var sizes: [7]u64 = undefined;
    zdac_probe_storage(&sizes);
    std.debug.print("affine controls native storage: State={d} Action={d} Auxiliary={d} AuxMapping={d}; transient Publication={d} AuxAction={d} AuxAccepted={d}\n", .{ sizes[0], sizes[1], sizes[2], sizes[3], sizes[4], sizes[5], sizes[6] });
    try scenario(gpa.allocator(), false);
    try scenario(gpa.allocator(), true);
    try std.testing.expectEqualDeep(a.ResourceCounts{ .accounts = 0, .blocks = 0, .bytes = 0 }, a.resourceCounts());
    std.debug.print("affine typed Diff controls: split/unified accepted fronts, toolbar hit/focus, same-epoch queued action withdrawal, one undo, native resources=0\n", .{});
}

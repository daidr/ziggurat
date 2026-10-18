//! Real Prepared/native point cases. The original one-point RED is separate.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const e = @import("ziggurat_document_editor");
const a = @import("ziggurat_document_accessibility");
const oracle = @import("document_accessibility_point_oracle.zig");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});
extern fn zda_probe_release(*anyopaque) void;
const source_text = "aaaaaaaaaaaaaaaa\nאבג e\u{301}😀\r\nthird\nlast";
const viewport: ui.Rect = .{ .x = 8.25, .y = 8.375, .width = 160.5, .height = 88.25 };
const filter = [_]usize{1};
const Stage = enum { ordinary, projected, filtered, empty_filter, hidden, folded, shear, reflection, rotation };
const Host = struct {
    app: *z.App,
    window: z.Window = undefined,
    context: ui.Context = undefined,
    document: *d.Document,
    adapter: *e.Adapter,
    bridge: ?*a.Bridge = null,
    provider: ?*anyopaque = null,
    plan: *e.ProjectionPlan,
    parameters: e.Parameters,
    renderer: ui.RenderMode,
    stage: Stage = .ordinary,
    matrix: ?ui.affine.Affine = null,
    clip: ?ui.Rect = null,
    offset: ui.layout.Point = .{},
    paragraphs: ?[]const usize = null,
    hide: bool = false,
    baseline: usize = 0,
    observing: bool = false,
    done: bool = false,
    failure: ?anyerror = null,
    comparisons: usize = 0,
    ties: usize = 0,
    gpu_frames: usize = 0,
    presents: u32 = 0,

    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(pointer: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(pointer));
        self.fail(value.err orelse error.UnexpectedDiagnostic);
    }
    fn fail(self: *Host, err: anyerror) void {
        std.debug.print("Prepared native point stage={s} renderer={s}: {any}\n", .{ @tagName(self.stage), @tagName(self.renderer), err });
        self.failure = self.failure orelse err;
        self.app.quit();
    }
    fn draw(pointer: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(pointer));
        self.project(frame) catch |err| {
            frame.failure = frame.failure orelse err;
            self.fail(err);
        };
    }
    fn project(self: *Host, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        frame.rect(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, 0x102030);
        if (self.clip) |clip| try frame.pushClip(clip);
        defer if (self.clip != null) frame.popClip() catch unreachable;
        if (self.matrix) |matrix| try frame.beginTransform(.{ .width = 240, .height = 140 }, matrix);
        defer if (self.matrix != null) frame.endTransform() catch unreachable;
        try frame.pushOffset(self.offset);
        defer frame.popOffset() catch unreachable;
        if (!self.hide) {
            if (self.paragraphs) |paragraphs| try self.adapter.drawParagraphs(frame, viewport, paragraphs, ui.Color.rgb(0)) else try self.adapter.draw(frame, viewport, .{});
        }
        try self.bridge.?.recordGeometry(frame);
        // Draw only posts a test observation. Business preparation and all
        // native queries execute after the actual paint callback has returned.
        if (!self.observing) {
            self.observing = true;
            try self.app.post(.{ .context = self, .call = observe });
        }
    }
    fn start(pointer: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(pointer));
        self.prepareStage() catch |err| self.fail(err);
    }
    fn prepareStage(self: *Host) !void {
        self.hide = self.stage == .hidden;
        self.paragraphs = switch (self.stage) {
            .filtered => &filter,
            .empty_filter => &.{},
            else => null,
        };
        self.matrix = switch (self.stage) {
            .shear => .{ .xy = 0.35, .x0 = 30.25, .y0 = 20.5 },
            .reflection => .{ .xx = -0.8, .yy = 1.1, .x0 = 230.25, .y0 = 10.5 },
            .rotation => try (try ui.affine.Affine.rotation(0.35)).then(.{ .x0 = 60.25, .y0 = 15.5 }),
            else => null,
        };
        self.clip = if (self.matrix != null) .{ .x = 58.25, .y = 27.5, .width = 115.5, .height = 70.25 } else null;
        self.offset = if (self.matrix != null) .{ .x = 3.25, .y = 2.5 } else .{};
        if (self.stage == .projected) try self.adapter.setProjection(self.plan);
        if (self.stage == .folded) {
            try self.adapter.setProjection(null);
            try self.adapter.setFolds(try self.document.version(), &.{.{ .id = 1, .header = 0, .end = (try self.document.line(3)).start, .collapsed = true }});
        }
        if (self.stage == .shear) try self.adapter.setFolds(try self.document.version(), &.{});
        _ = try self.adapter.prepare(viewport, self.parameters);
        const snapshot = try self.document.snapshot();
        defer snapshot.close() catch unreachable;
        const reader = try snapshot.borrowReader();
        defer reader.release() catch unreachable;
        try self.bridge.?.prepareText(&.{reader});
        if (self.hide) try self.bridge.?.prepareGeometrySelected(&.{.hidden}, 0) else try self.bridge.?.prepareGeometry(&.{self.paragraphs});
        self.baseline = self.context.gdi_frames + self.context.gpu_frames;
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
    }
    fn observe(pointer: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(pointer));
        self.observing = false;
        if (self.failure != null or self.done or self.window.isClosed()) return;
        // PresentationBusy can leave this stage pending. The existing GPU wait
        // event retries paint; its draw posts the next observation. No UI wait,
        // nested event loop, timer or polling task is introduced here.
        if (self.context.gdi_frames + self.context.gpu_frames <= self.baseline) return;
        self.checkStage() catch |err| {
            self.fail(err);
            return;
        };
        if (self.stage == .rotation) {
            self.done = true;
            if (self.renderer == .gdi) {
                std.debug.assert(self.context.gdi_frames > 0 and self.context.gpu_frames == 0);
            } else if (comptime ui.capabilities.gpu) {
                const stats = self.context.gpu_renderer.stats();
                if (self.context.gpu_frames == 0 or self.context.gdi_frames != 0 or self.context.fallbacks != 0 or stats.presents == 0) {
                    self.fail(error.GpuPointFrontRequired);
                    return;
                }
                self.gpu_frames = self.context.gpu_frames;
                self.presents = stats.presents;
            } else {
                self.fail(error.UnsupportedTestRenderer);
                return;
            }
            self.app.quit();
        } else {
            self.stage = @enumFromInt(@intFromEnum(self.stage) + 1);
            self.prepareStage() catch |err| self.fail(err);
        }
    }
    fn allowed(self: *const Host, coordinates: oracle.Coordinates, point: ui.affine.Point) bool {
        const window_point = coordinates.window(point);
        if (self.clip) |clip| return window_point.x >= clip.x and window_point.y >= clip.y and window_point.x < @as(f64, clip.x) + clip.width and window_point.y < @as(f64, clip.y) + clip.height;
        return true;
    }
    fn checkStage(self: *Host) !void {
        const coordinates = try oracle.Coordinates.init(self.window.nativeHandle(), self.parameters.scale, self.matrix orelse .{}, self.offset);
        var batch: oracle.Batch = .{ .provider = self.provider.? };
        var carets: [512]e.GeometryCaret = undefined;
        var lines: [64]e.GeometryLine = undefined;
        const exported = try self.adapter.preparedCarets(try self.document.version(), &carets, &lines, .{ .paragraphs = self.paragraphs });
        if (self.hide or self.stage == .empty_filter) {
            try batch.deny(coordinates, .{ .x = 9, .y = 10 }, if (self.hide) oracle.not_supported else oracle.invalid_argument);
        } else if (self.stage == .filtered) {
            try std.testing.expect(exported.lines.len != 0);
            const line = exported.lines[0].rect;
            for (0..14) |at| try batch.append(self.adapter, self.document, viewport, coordinates, .{ .x = viewport.x + 1 + @as(f64, @floatFromInt(at)) * 10, .y = line.y + line.height / 2 });
            // Before the first actual projected line and in its gap, the full
            // candidate must not reauthorize an undrawn filtered paragraph.
            try batch.deny(coordinates, .{ .x = 9, .y = viewport.y + 1 }, oracle.invalid_argument);
            try batch.deny(coordinates, .{ .x = 9, .y = line.y - 5 }, oracle.invalid_argument);
        } else {
            for (0..17) |yi| for (0..14) |xi| {
                const point: ui.affine.Point = .{ .x = viewport.x + 0.25 + @as(f64, @floatFromInt(xi)) * 12, .y = viewport.y + 0.25 + @as(f64, @floatFromInt(yi)) * 5.4 };
                if (self.allowed(coordinates, point)) try batch.append(self.adapter, self.document, viewport, coordinates, point) else try batch.deny(coordinates, point, oracle.invalid_argument);
            };
            for (exported.lines) |line| {
                const stops = exported.carets[line.first..][0..line.count];
                for (stops, 0..) |stop, index| {
                    if (index != 0 and stop.rect.x == stops[index - 1].rect.x) self.ties += 1;
                    const middle: f32 = if (index == 0) stop.rect.x else @floatCast((@as(f64, stops[index - 1].rect.x) + stop.rect.x) / 2);
                    for ([_]f32{ std.math.nextAfter(f32, middle, -std.math.inf(f32)), middle, std.math.nextAfter(f32, middle, std.math.inf(f32)) }) |x| {
                        if (x < viewport.x or x > viewport.x + viewport.width) continue;
                        const point: ui.affine.Point = .{ .x = x, .y = line.rect.y + line.rect.height / 2 };
                        if (self.allowed(coordinates, point)) try batch.append(self.adapter, self.document, viewport, coordinates, point);
                    }
                }
            }
            if (self.matrix == null) {
                // Existing Windows unfiltered viewport endpoints are inclusive.
                for ([_]ui.affine.Point{
                    .{ .x = viewport.x, .y = viewport.y },
                    .{ .x = viewport.x + viewport.width, .y = viewport.y },
                    .{ .x = viewport.x + viewport.width, .y = viewport.y + viewport.height },
                    .{ .x = viewport.x, .y = viewport.y + viewport.height },
                }) |point| {
                    const actual = coordinates.localDouble(coordinates.screen(point));
                    if (actual.x >= viewport.x and actual.y >= viewport.y and actual.x <= @as(f64, viewport.x) + viewport.width and actual.y <= @as(f64, viewport.y) + viewport.height) try batch.append(self.adapter, self.document, viewport, coordinates, point) else try batch.deny(coordinates, point, oracle.invalid_argument);
                }
            }
        }
        try std.testing.expect(batch.len != 0);
        try batch.verify();
        self.comparisons += batch.len;
        std.debug.print("Prepared native point stage={s} owner+MTA={d} frames={d}\n", .{ @tagName(self.stage), batch.len, self.context.frames });
    }
};

pub fn run(allocator: std.mem.Allocator, renderer: ui.RenderMode) !void {
    if (builtin.os.tag != .windows or (renderer != .gdi and !ui.capabilities.gpu)) return error.UnsupportedTestRenderer;
    const native_before = a.resourceCounts();
    const text_before = t.resourceCounts();
    var host: Host = undefined;
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source_text, .{});
    defer document.close() catch unreachable;
    const plan = try e.ProjectionPlan.create(allocator, document, &.{ .{ .line = 1, .gap_before = 17.25, .minimum_height = 45 }, .{ .line = 2, .gap_before = 4.5 } }, .{});
    defer plan.close() catch unreachable;
    const adapter = try e.Adapter.create(allocator, document, engine, .{ .batch_rows = 1 });
    defer adapter.close() catch unreachable;
    host = .{ .app = app, .document = document, .adapter = adapter, .plan = plan, .parameters = .{ .font = .{ .size = 24, .wrap = .none, .width = viewport.width } }, .renderer = renderer };
    host.window = try app.createWindow(.{ .width = 420, .height = 240 });
    defer _ = host.window.destroy() catch unreachable;
    const size = try host.window.contentSize();
    host.parameters.scale = size.scale;
    _ = try adapter.prepare(viewport, host.parameters);
    var carets: [512]e.GeometryCaret = undefined;
    var lines: [64]e.GeometryLine = undefined;
    const initial = try adapter.preparedCarets(try document.version(), &carets, &lines, .{});
    var advance: f32 = 0;
    for (initial.carets) |caret| if (caret.position == 1) {
        advance = caret.rect.x - viewport.x;
        break;
    };
    try std.testing.expect(advance > 2 and try adapter.scrollBy(.{ .x = 1.375, .y = 0 }));
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    host.context.render_mode = renderer;
    try host.context.attach(host.window);
    try host.context.prepareTransforms(allocator, .{ .layers = .{ .size = size, .max_depth = 2 }, .source_size = .{ .width = 240, .height = 140 } });
    const bridge = try a.Bridge.create(allocator, host.window, &.{.{ .adapter = adapter, .name = "Prepared native input", .read_only = true, .selectable = false, .focusable = false }}, .{ .affine_geometry = true });
    defer bridge.close() catch unreachable;
    host.bridge = bridge;
    try bridge.attachContext(&host.context);
    const provider = try bridge.retainProvider(0);
    defer zda_probe_release(provider);
    host.provider = provider;
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.post(.{ .context = &host, .call = Host.start });
    try app.run();
    try std.testing.expect(!watchdog.expired);
    if (host.failure) |err| return err;
    try std.testing.expect(host.done);
    std.debug.print("Prepared point routes: renderer={s} scale={d} advance={d}, {d} owner+MTA pairs, observed same-X pairs={d}, gpu_frames={d} presents={d}; prior ledger={any} text={any}\n", .{ @tagName(renderer), size.scale, advance, host.comparisons, host.ties, host.gpu_frames, host.presents, native_before, text_before });
}

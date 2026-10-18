const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const e = @import("ziggurat_document_editor");
const diff = @import("ziggurat_document_diff");
const v = @import("ziggurat_document_diff_view");
const a = @import("ziggurat_document_accessibility");
const paired = @import("ziggurat_document_diff_accessibility");
const fold_checks = @import("document_fold_pair_smoke.zig");
const point_oracle = @import("document_accessibility_point_oracle.zig");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("objbase.h");
    @cInclude("imm.h");
}) else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn zda_probe_all_rectangles(*anyopaque, [*]f64, u32, *u32) i32;
extern fn zda_probe_point(*anyopaque, f64, f64, *u32) i32;
extern fn zda_probe_release(*anyopaque) void;
const bounds: ui.Rect = .{ .x = 4, .y = 4, .width = 300, .height = 120 };
const extent: ui.layout.Size = .{ .width = 320, .height = 140 };
const texts = [2][]const u8{ "header\nremoved 😀 אבג\ncommon\nlast", "header\nreplacement e\u{301} 文\ncommon\nlast" };
const AllocationProbe = struct {
    source: std.mem.Allocator,
    lease: ?*e.PresentationLease = null,
    armed: bool = false,
    fired: bool = false,
    exhaust: bool = false,
    rebind: ?struct { address: usize, host: *Host } = null,
    rebound: bool = false,
    failure: ?anyerror = null,
    fn allocator(self: *AllocationProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *AllocationProbe = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            self.armed = false;
            self.fired = true;
            if (self.exhaust) self.lease.?.generation = std.math.maxInt(u64) - 1;
            _ = self.lease.?.withdraw() catch unreachable;
        }
        return self.source.rawAlloc(len, alignment, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *AllocationProbe = @ptrCast(@alignCast(ptr));
        if (self.rebind) |action| if (@intFromPtr(bytes.ptr) == action.address) {
            self.rebind = null;
            self.rebound = true;
            self.onFinalFree(action.host) catch |err| {
                self.failure = err;
            };
        };
        self.source.rawFree(bytes, alignment, ret);
    }
    fn onFinalFree(_: *AllocationProbe, host: *Host) !void {
        try host.adapters[1].bind(host.window);
        try host.rejectNative(host.window.textClientToken().?, error.GeometryRequired);
    }
};
fn nativeAddress(bridge: *paired.Bridge) usize {
    return @intFromPtr(if (comptime @typeInfo(@TypeOf(bridge.native)) == .optional) bridge.native.? else bridge.native);
}
const Host = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    view: *v.EditableSplit = undefined,
    adapters: [2]*e.Adapter = undefined,
    documents: [2]*d.Document = undefined,
    inbox: *v.Inbox = undefined,
    bridge: ?*paired.Bridge = null,
    coordinates: *v.editable.CoordinateBinding = undefined,
    lease: *e.PresentationLease = undefined,
    publisher: u64 = 0,
    phase_token: ?ui.AccessibilitySourceToken = null,
    parameters: v.Parameters = .{ .font = .{ .size = 16, .wrap = .word_character } },
    matrix: ui.affine.Affine = .{ .xy = 0.25, .x0 = 30, .y0 = 20 },
    clip: ?ui.Rect = null,
    offset: ui.layout.Point = .{},
    record_body: bool = true,
    unrelated_capture: bool = false,
    fail_frame: bool = false,
    nested_paint: bool = false,
    plain: bool = false,
    wrong_association: bool = false,
    paints: usize = 0,
    mapping: ?ui.CoordinateMapping = null,
    failure: ?anyerror = null,
    paint_error: ?anyerror = null,
    expected_diagnostic: ?anyerror = null,
    diagnostic_count: usize = 0,
    rows: [96]v.editable.Row = undefined,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (self.expected_diagnostic) |expected| if (value.err) |err| if (err == expected) {
            self.diagnostic_count += 1;
            return;
        };
        if (value.operation == .paint) self.paint_error = value.err else if (value.err) |err| self.failure = err;
    }
    fn query(_: *anyopaque, _: z.Window, _: usize, _: isize) ?isize {
        return null;
    }
    // Linux exercises the real shared coordinate/GTK TextClient seam. This
    // test-only C-free publisher does not pretend to provide native UIA/AT-SPI.
    fn phase(ptr: *anyopaque, _: z.Window, value: ui.AccessibilityPhase) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (value == .frame_begin) {
            self.mapping = null;
            self.lease.discardCandidate();
            return;
        }
        const offered = self.lease.pending;
        const generation = self.lease.begin(self.publisher) catch |err| {
            self.failure = err;
            return;
        };
        if (self.mapping) |mapping| {
            mapping.checkCommitted(&self.context) catch |err| {
                self.failure = err;
                return;
            };
            var rows: [96]v.editable.Row = undefined;
            const presentation = self.view.copyPresentation(&rows) catch |err| {
                self.failure = err;
                return;
            };
            const stamp: e.PresentationLease.Stamp = .{ .publication = presentation.epoch, .source = mapping.source, .candidate = mapping.candidate, .space_epoch = mapping.epoch, .space_generation = mapping.space_generation.? };
            if (offered == null or !std.meta.eql(offered.?, stamp)) return;
            self.lease.commit(self.publisher, generation, stamp) catch |err| {
                self.failure = err;
            };
        }
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            self.failure = err;
            frame.failure = frame.failure orelse err;
        };
    }
    fn drawChecked(self: *Host, frame: *ui.Frame) !void {
        self.paints += 1;
        frame.clear(0xffffff);
        if (self.plain) return;
        if (self.clip) |clip| try frame.pushClip(clip);
        defer if (self.clip != null) frame.popClip() catch unreachable;
        try frame.beginTransform(extent, self.matrix);
        defer frame.endTransform() catch unreachable;
        try frame.pushOffset(self.offset);
        defer frame.popOffset() catch unreachable;
        if (self.record_body) {
            if (builtin.os.tag == .windows) {
                try self.bridge.?.draw(frame, .{});
            } else {
                try self.view.draw(frame, bounds, .{});
                var rows: [96]v.editable.Row = undefined;
                const presentation = try self.view.copyPresentation(&rows);
                try self.coordinates.record(frame, presentation.epoch);
                var mapping: ui.CoordinateMapping = undefined;
                try frame.coordinateMapping(bounds, &mapping);
                self.mapping = mapping;
            }
        } else {
            try self.view.draw(frame, bounds, .{});
            // Same configured ID in an unrelated successful body is still not
            // authorized without the matching native geometry publication.
            if (self.unrelated_capture) try frame.captureSpace(91, bounds);
        }
        try frame.captureSpace(92, bounds);
        if (self.wrong_association) {
            var altered = self.lease.pending.?;
            altered.candidate += 1;
            self.lease.offer(altered);
        }
        if (self.nested_paint) {
            self.nested_paint = false;
            const before = self.paints;
            const candidate = self.context.accessibility_source_state.frame_candidate;
            try self.nativePaint();
            try std.testing.expectEqual(before, self.paints);
            try std.testing.expectEqual(candidate, self.context.accessibility_source_state.frame_candidate);
        }
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn nativePaint(self: *Host) !void {
        if (builtin.os.tag == .windows) {
            _ = c.InvalidateRect(self.window.nativeHandle(), null, 0);
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        } else {
            const native = self.window.app.windows.get(self.window.key).?.native.native.?;
            const size = try self.window.contentSize();
            const scale: u32 = @intFromFloat(size.scale);
            zlg_test_paint(native, size.width / scale, size.height / scale);
        }
    }
    fn paint(self: *Host) !void {
        self.paint_error = null;
        const before = self.paints;
        try self.nativePaint();
        if (self.failure) |err| return err;
        try std.testing.expect(self.paints > before);
        if (self.fail_frame) try std.testing.expectEqual(error.InvalidGeometry, self.paint_error.?) else if (self.paint_error) |err| return err;
    }
    fn setSpace(self: *Host, token: ui.SpaceToken) !void {
        if (builtin.os.tag == .windows) try self.bridge.?.setCommittedSpace(token) else try self.coordinates.setCommittedSpace(token);
    }
    fn prepare(self: *Host) !void {
        try self.view.prepare(bounds, self.parameters);
        if (builtin.os.tag == .windows) {
            const snapshots = [2]*d.Snapshot{ try self.documents[0].snapshot(), try self.documents[1].snapshot() };
            defer for (snapshots) |snapshot| snapshot.close() catch unreachable;
            const readers = [2]d.Reader{ try snapshots[0].borrowReader(), try snapshots[1].borrowReader() };
            defer for (readers) |reader| reader.release() catch unreachable;
            try self.bridge.?.prepare(.{ readers[0], readers[1] });
        }
    }
    fn rejectNative(self: *Host, token: z.TextClientToken, expected: anyerror) !void {
        const revision = try self.documents[1].version();
        const selected = try self.documents[1].selection();
        var output: [128]u8 = @splat(0x5a);
        try std.testing.expectError(expected, self.window.readTextClient(token, &output));
        try std.testing.expect(std.mem.allEqual(u8, &output, 0x5a));
        try std.testing.expectError(expected, self.window.changeTextClient(token, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "X" } }));
        try std.testing.expectEqual(revision, try self.documents[1].version());
        try std.testing.expectEqualDeep(selected, try self.documents[1].selection());
    }
    fn contextRead(self: *Host) !void {
        var output: [256]u8 = undefined;
        const result = try self.window.readTextClient(self.window.textClientToken().?, &output);
        var expected: [256]u8 = undefined;
        const length = try self.documents[1].byteLength();
        _ = try self.documents[1].read(.{ .start = 0, .end = length }, &expected);
        try std.testing.expectEqualStrings(expected[0..length], output[0..result.bytes]);
    }
    fn caret(self: *Host) !void {
        if (builtin.os.tag == .windows) try self.bridge.?.syncNativeCaret() else try self.coordinates.syncCaret();
        const info = try self.view.copyPresentation(&self.rows);
        const caret_rect = try self.adapters[1].caretRect(info.columns[1], self.parameters.scale);
        const token = try self.context.committedSpace(91);
        const mapped = try token.windowBounds(caret_rect);
        if (builtin.os.tag == .windows) {
            const im = c.ImmCreateContext() orelse return error.InputContextUnavailable;
            const previous = c.ImmAssociateContext(self.window.nativeHandle(), im);
            defer {
                _ = c.ImmAssociateContext(self.window.nativeHandle(), previous);
                std.debug.assert(c.ImmDestroyContext(im) != 0);
            }
            try self.bridge.?.syncNativeCaret();
            var actual = std.mem.zeroes(c.COMPOSITIONFORM);
            try std.testing.expect(c.ImmGetCompositionWindow(im, &actual) != 0);
            try std.testing.expectEqual(@as(c.LONG, @intFromFloat(mapped.x * self.parameters.scale)), actual.ptCurrentPos.x);
            try std.testing.expectEqual(@as(c.LONG, @intFromFloat(mapped.y * self.parameters.scale)) + @as(c.LONG, @intFromFloat(mapped.height * self.parameters.scale)), actual.ptCurrentPos.y);
        }
    }
};

fn publish(inbox: *v.Inbox, allocator: std.mem.Allocator) !void {
    const job = try inbox.begin();
    defer _ = inbox.finish(job.ticket) catch unreachable;
    var released = false;
    defer if (!released) job.release() catch unreachable;
    var result = try diff.compare(allocator, job.a, job.b, .{});
    defer result.deinit();
    try job.release();
    released = true;
    try inbox.publish(job.ticket, &result);
}

const Oracle = struct {
    provider: *anyopaque,
    values: [2048]f64 = undefined,
    count: usize = 0,
    points: [64]struct { point: ui.affine.Point, offset: u32 } = undefined,
    point_count: usize = 0,
    failure: ?anyerror = null,
    fn run(self: *Oracle) void {
        self.check() catch |err| {
            self.failure = err;
        };
    }
    fn check(self: *Oracle) !void {
        if (builtin.os.tag != .windows) return;
        try std.testing.expect(c.CoInitializeEx(null, c.COINIT_MULTITHREADED) >= 0);
        defer c.CoUninitialize();
        var output: [2048]f64 = undefined;
        var count: u32 = 0;
        try std.testing.expectEqual(@as(i32, 0), zda_probe_all_rectangles(self.provider, &output, output.len, &count));
        try std.testing.expectEqual(self.count, count);
        for (self.values[0..self.count], output[0..count]) |expected, actual| try std.testing.expectApproxEqAbs(expected, actual, 0.003);
        for (self.points[0..self.point_count]) |expected| {
            var actual: u32 = undefined;
            try std.testing.expectEqual(@as(i32, 0), zda_probe_point(self.provider, expected.point.x, expected.point.y, &actual));
            try std.testing.expectEqual(expected.offset, actual);
        }
    }
    fn verify(self: *Oracle) !void {
        const worker = try std.Thread.spawn(.{}, Oracle.run, .{self});
        worker.join();
        if (self.failure) |err| return err;
    }
};

fn oracle(host: *Host, provider: *anyopaque, side: usize) !Oracle {
    var result: Oracle = .{ .provider = provider };
    var rows: [96]v.editable.Row = undefined;
    const presented = try host.view.copyPresentation(&rows);
    var filter: [96]usize = undefined;
    var used: usize = 0;
    if (presented.mode == .unified and side == 0) for (presented.rows) |row| if (row.b == null) if (row.a) |line| {
        filter[used] = line;
        used += 1;
    };
    const paragraphs: ?[]const usize = if (presented.mode == .unified and side == 0) filter[0..used] else null;
    var cells: [512]e.GeometryCell = undefined;
    const geometry = try host.adapters[side].preparedGeometry(try host.documents[side].version(), &cells, .{ .paragraphs = paragraphs });
    var table: ui.affine.GeometryTable(2, 4) = .{};
    const size = try host.window.contentSize();
    const window_clip = try table.addClip(.identity, null, .{ .width = @as(f64, @floatFromInt(size.width)) / size.scale, .height = @as(f64, @floatFromInt(size.height)) / size.scale });
    const parent_clip = if (host.clip) |clip| try table.addClip(.identity, window_clip, ui.affine.Rect.from(clip)) else window_clip;
    var matrix = host.matrix;
    matrix.x0 += host.matrix.xx * host.offset.x + host.matrix.xy * host.offset.y;
    matrix.y0 += host.matrix.yx * host.offset.x + host.matrix.yy * host.offset.y;
    const space = try table.addSpace(matrix);
    const clip = try table.addClip(space, parent_clip, ui.affine.Rect.from(presented.columns[side]));
    var origin = std.mem.zeroes(c.POINT);
    try std.testing.expect(c.ClientToScreen(host.window.nativeHandle(), &origin) != 0);
    for (geometry.cells) |cell| if (try table.visibleBounds(.{ .space = space, .clip = clip }, ui.affine.Rect.from(cell.rect))) |visible| {
        const values = [_]f64{ @as(f64, @floatFromInt(origin.x)) + visible.x * size.scale, @as(f64, @floatFromInt(origin.y)) + visible.y * size.scale, visible.width * size.scale, visible.height * size.scale };
        @memcpy(result.values[result.count..][0..4], &values);
        result.count += 4;
    };
    if (side == 1 or presented.mode == .split) {
        var carets: [512]e.GeometryCaret = undefined;
        var lines: [64]e.GeometryLine = undefined;
        const prepared = try host.adapters[side].preparedCarets(try host.documents[side].version(), &carets, &lines, .{});
        for (prepared.lines) |line| for (0..8) |at| {
            if (result.point_count == result.points.len) break;
            const local: ui.affine.Point = .{ .x = presented.columns[side].x + 2 + (presented.columns[side].width - 4) * @as(f64, @floatFromInt(at)) / 7, .y = line.rect.y + line.rect.height / 2 };
            const mapped = try matrix.mapPoint(local);
            if (!try table.contains(.{ .space = space, .clip = clip }, ui.affine.Rect.from(presented.columns[side]), mapped)) continue;
            const target = try host.adapters[side].hitTest(presented.columns[side], .{ .x = @floatCast(local.x), .y = @floatCast(local.y) });
            result.points[result.point_count] = .{ .point = .{ .x = @as(f64, @floatFromInt(origin.x)) + mapped.x * size.scale, .y = @as(f64, @floatFromInt(origin.y)) + mapped.y * size.scale }, .offset = @intCast(try host.documents[side].utf16Offset(target.byte_offset)) };
            result.point_count += 1;
        };
    }
    return result;
}

fn completePoints(host: *Host, provider: *anyopaque, side: usize) !void {
    var rows: [96]v.editable.Row = undefined;
    const presentation = try host.view.copyPresentation(&rows);
    var filter: [96]usize = undefined;
    var filter_len: usize = 0;
    if (presentation.mode == .unified and side == 0) for (presentation.rows) |row| if (row.b == null) if (row.a) |line| {
        filter[filter_len] = line;
        filter_len += 1;
    };
    const paragraphs: ?[]const usize = if (presentation.mode == .unified and side == 0) filter[0..filter_len] else null;
    const viewport = presentation.columns[side];
    const size = try host.window.contentSize();
    const coordinates = try point_oracle.Coordinates.init(host.window.nativeHandle(), size.scale, host.matrix, host.offset);
    var table: ui.affine.GeometryTable(2, 4) = .{};
    const window_clip = try table.addClip(.identity, null, .{ .width = @as(f64, @floatFromInt(size.width)) / size.scale, .height = @as(f64, @floatFromInt(size.height)) / size.scale });
    const parent = if (host.clip) |clip| try table.addClip(.identity, window_clip, ui.affine.Rect.from(clip)) else window_clip;
    const space = try table.addSpace(coordinates.forward);
    const clip = try table.addClip(space, parent, ui.affine.Rect.from(viewport));
    var carets: [512]e.GeometryCaret = undefined;
    var lines: [64]e.GeometryLine = undefined;
    const prepared = try host.adapters[side].preparedCarets(try host.documents[side].version(), &carets, &lines, .{ .paragraphs = paragraphs });
    var checks: point_oracle.Batch = .{ .provider = provider };
    if (prepared.lines.len == 0) {
        // Paired mode withdraws Geometry when the source has no drawn rows.
        try checks.deny(coordinates, .{ .x = viewport.x + 1, .y = viewport.y + 1 }, point_oracle.not_supported);
        try checks.verify();
        return;
    }
    for (prepared.lines) |line| {
        for (0..17) |at| {
            const local: ui.affine.Point = .{ .x = viewport.x + 0.25 + (@as(f64, viewport.width) - 0.5) * @as(f64, @floatFromInt(at)) / 16, .y = line.rect.y + line.rect.height / 2 };
            const window_point = coordinates.window(local);
            if (!try table.contains(.{ .space = space, .clip = clip }, ui.affine.Rect.from(viewport), window_point)) continue;
            try checks.append(host.adapters[side], host.documents[side], viewport, coordinates, local);
        }
        const stops = prepared.carets[line.first..][0..line.count];
        for (stops, 0..) |stop, index| {
            const midpoint: f32 = if (index == 0) stop.rect.x else @floatCast((@as(f64, stops[index - 1].rect.x) + stop.rect.x) / 2);
            for ([_]f32{ std.math.nextAfter(f32, midpoint, -std.math.inf(f32)), midpoint, std.math.nextAfter(f32, midpoint, std.math.inf(f32)) }) |x| {
                const local: ui.affine.Point = .{ .x = x, .y = line.rect.y + line.rect.height / 2 };
                if (!try table.contains(.{ .space = space, .clip = clip }, ui.affine.Rect.from(viewport), coordinates.window(local))) continue;
                try checks.append(host.adapters[side], host.documents[side], viewport, coordinates, local);
            }
        }
    }
    // AABB samples expose corners outside the exact rotated/sheared polygon.
    // For unified ghosts, points in undrawn row gaps remain unavailable even
    // when the full Prepared candidate could select a stop there.
    if (try table.visibleBounds(.{ .space = space, .clip = clip }, ui.affine.Rect.from(viewport))) |aabb| {
        for (0..9) |yi| for (0..9) |xi| {
            const window_point: ui.affine.Point = .{ .x = aabb.x + (aabb.width - 0.25) * @as(f64, @floatFromInt(xi)) / 8 + 0.125, .y = aabb.y + (aabb.height - 0.25) * @as(f64, @floatFromInt(yi)) / 8 + 0.125 };
            const screen_point: ui.affine.Point = .{ .x = coordinates.origin.x + window_point.x * size.scale, .y = coordinates.origin.y + window_point.y * size.scale };
            const local = coordinates.localDouble(screen_point);
            var allowed = try table.contains(.{ .space = space, .clip = clip }, ui.affine.Rect.from(viewport), window_point);
            if (allowed and paragraphs != null) {
                allowed = false;
                for (prepared.lines) |line| {
                    const rect = line.rect;
                    if (local.x >= rect.x and local.y >= rect.y and @as(f64, local.x) < @as(f64, rect.x) + rect.width and @as(f64, local.y) < @as(f64, rect.y) + rect.height) {
                        allowed = true;
                        break;
                    }
                }
            }
            if (allowed) try checks.appendScreen(host.adapters[side], host.documents[side], viewport, coordinates, screen_point) else try checks.denyScreen(screen_point, point_oracle.invalid_argument);
        };
    }
    try std.testing.expect(checks.len != 0);
    try checks.verify();
    std.debug.print("paired complete Prepared point mode={s} side={d} owner+MTA={d}\n", .{ @tagName(presentation.mode), side, checks.len });
}

fn run(allocator: std.mem.Allocator, unified: bool, exhaust_observer: bool) !void {
    const host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = host, .emit = Host.diagnostic } });
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var document_probe: AllocationProbe = .{ .source = allocator };
    host.documents = .{ try d.Document.create(allocator, std.Thread.getCurrentId(), texts[0], .{}), try d.Document.create(document_probe.allocator(), std.Thread.getCurrentId(), texts[1], .{}) };
    defer for (host.documents) |document| document.close() catch unreachable;
    host.adapters = .{ try e.Adapter.create(allocator, host.documents[0], engine, .{}), try e.Adapter.create(allocator, host.documents[1], engine, .{}) };
    defer for (host.adapters) |adapter| adapter.close() catch unreachable;
    host.inbox = try v.Inbox.create(allocator, .{ .a = host.documents[0], .b = host.documents[1] }, .{});
    defer host.inbox.close() catch unreachable;
    host.window = try app.createWindow(.{ .width = 480, .height = 300 });
    defer {
        _ = host.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    host.parameters.scale = (try host.window.contentSize()).scale;
    var view_probe: AllocationProbe = .{ .source = allocator };
    var bridge_probe: AllocationProbe = .{ .source = allocator };
    var view_fault = std.testing.FailingAllocator.init(view_probe.allocator(), .{});
    const target: paired.Target = if (unified) .{ .unified = try v.EditableUnified.create(view_fault.allocator(), host.inbox, host.adapters[0], host.adapters[1], host.window, .{}) } else .{ .split = try v.EditableSplit.create(view_fault.allocator(), host.inbox, host.adapters[0], host.adapters[1], host.window, .{}) };
    host.view = switch (target) {
        .split => |view| view,
        .unified => |view| view.coordinator(),
    };
    defer host.view.close() catch unreachable;
    try publish(host.inbox, allocator);
    host.context = ui.Context.init(host, Host.draw, Host.action);
    host.context.render_mode = .gdi;
    try host.context.attach(host.window);
    const options: ui.layers.TransformOptions = .{ .layers = .{ .size = try host.window.contentSize(), .max_depth = 3 }, .source_size = extent };
    try host.context.prepareTransforms(allocator, options);
    view_fault.fail_index = view_fault.alloc_index;
    try std.testing.expectError(error.OutOfMemory, host.view.acquireCoordinates(91));
    view_fault.fail_index = std.math.maxInt(usize);
    if (builtin.os.tag == .windows) {
        host.bridge = try paired.Bridge.create(bridge_probe.allocator(), host.window, target, .{ .accessibility = .{ .affine_geometry = true, .cells = 512, .carets = 512, .lines = 64 }, .affine_space_id = 91 });
        host.coordinates = host.bridge.?.coordinates.?;
        try host.bridge.?.attachContext(&host.context);
    } else {
        host.coordinates = try host.view.acquireCoordinates(91);
        try host.coordinates.attachContext(&host.context);
        host.phase_token = try host.context.installAccessibilitySource(.{ .context = host, .query = Host.query, .phase = Host.phase });
    }
    host.lease = try host.coordinates.publication();
    document_probe.lease = host.lease;
    view_probe.lease = host.lease;
    if (builtin.os.tag != .windows) host.publisher = try host.lease.acquire();
    defer {
        if (builtin.os.tag == .windows) {
            if (host.bridge) |bridge| bridge.close() catch unreachable;
        } else if (host.publisher != 0) {
            host.coordinates.withdraw() catch unreachable;
            host.lease.release(host.publisher) catch |err| switch (err) {
                error.IdExhausted => std.debug.assert(!host.lease.hasPublisher()),
                else => unreachable,
            };
            host.coordinates.close() catch unreachable;
            if (host.context.window != null) _ = host.context.clearAccessibilitySource(host.phase_token.?) catch unreachable;
        }
        host.bridge = null;
    }
    try host.prepare();
    const providers: ?[2]*anyopaque = if (builtin.os.tag == .windows) .{ try host.bridge.?.retainProvider(0), try host.bridge.?.retainProvider(1) } else null;
    defer if (providers) |values| for (values) |provider| zda_probe_release(provider);
    try std.testing.expectError(error.GeometryRequired, host.view.focus(.b));
    try host.paint();
    try host.setSpace(try host.context.committedSpace(91));
    try std.testing.expectError(error.ForeignSpace, host.setSpace(try host.context.committedSpace(92)));
    try host.view.focus(.b);
    try host.contextRead();
    try host.caret();
    // Ctrl+Enter owns the coordinate authority across the foreign revert-byte
    // allocation, before the sole Document is allowed to commit.
    const shortcut_revision = try host.documents[1].version();
    const shortcut_selection = try host.documents[1].selection();
    view_probe.armed = true;
    const shortcut = host.view.handleEvent(.{ .key_input = .{ .key = .enter, .modifiers = .{ .control = true } } }, bounds, host.parameters);
    try std.testing.expect(view_probe.fired and !view_probe.armed);
    try std.testing.expectEqual(shortcut_revision, try host.documents[1].version());
    try std.testing.expectEqualDeep(shortcut_selection, try host.documents[1].selection());
    try std.testing.expectError(error.GeometryRequired, shortcut);
    try host.prepare();
    try host.paint();
    const native_token = host.window.textClientToken().?;
    const saved_space = try host.context.committedSpace(91);
    var previous_oracle: ?Oracle = null;
    const matrices = [_]ui.affine.Affine{ host.matrix, .{ .xx = -0.85, .yy = 1.1, .x0 = 380, .y0 = 15 }, try (try ui.affine.Affine.rotation(0.15)).then(.{ .x0 = 50, .y0 = 30 }) };
    for (matrices, 0..) |matrix, at| {
        host.matrix = matrix;
        host.clip = if (at == 2) .{ .x = 70.25, .y = 35.5, .width = 200.5, .height = 100.25 } else null;
        host.offset = if (at == 1) .{ .x = 3.25, .y = 2.5 } else .{};
        try host.paint();
        try host.contextRead();
        try std.testing.expectError(error.StaleSpace, host.setSpace(saved_space));
        if (builtin.os.tag == .windows) {
            for (0..2) |side| {
                const provider = providers.?[side];
                var check = try oracle(host, provider, side);
                try check.verify();
                try completePoints(host, provider, side);
                if (side == 1) previous_oracle = check;
            }
        }
    }
    // Reentrant native paint cannot begin C while B is painting/recorded.
    const before_nested = (try host.lease.snapshot()).generation;
    host.nested_paint = true;
    try host.paint();
    try std.testing.expect((try host.lease.snapshot()).generation > before_nested);
    const accepted = try host.lease.snapshot();
    host.fail_frame = true;
    host.matrix.x0 += 15;
    try host.paint();
    try std.testing.expectEqualDeep(accepted, try host.lease.snapshot());
    try host.contextRead();
    host.fail_frame = false;
    host.wrong_association = true;
    try host.paint();
    try host.rejectNative(native_token, error.GeometryRequired);
    try std.testing.expectError(error.GeometryRequired, host.setSpace(try host.context.committedSpace(91)));
    if (builtin.os.tag == .windows) {
        var position: u32 = undefined;
        try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040204))), zda_probe_point(previous_oracle.?.provider, previous_oracle.?.points[0].point.x, previous_oracle.?.points[0].point.y, &position));
    }
    host.wrong_association = false;
    host.record_body = false;
    host.unrelated_capture = true;
    try host.paint();
    try std.testing.expectError(error.GeometryRequired, host.setSpace(try host.context.committedSpace(91)));
    try host.rejectNative(native_token, error.GeometryRequired);
    if (builtin.os.tag == .windows) {
        var position: u32 = undefined;
        try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040204))), zda_probe_point(previous_oracle.?.provider, previous_oracle.?.points[0].point.x, previous_oracle.?.points[0].point.y, &position));
    }
    host.record_body = true;
    host.unrelated_capture = false;
    try host.paint();
    try host.contextRead();
    // Map a window-space click through the accepted common Space. The Adapter
    // remains the only owner of the actual directed source selection.
    host.clip = null;
    host.matrix = .{ .xy = 0.2, .x0 = 30, .y0 = 20 };
    host.offset = .{};
    try host.paint();
    var rows: [96]v.editable.Row = undefined;
    const presentation = try host.view.copyPresentation(&rows);
    var stops: [512]e.GeometryCaret = undefined;
    var lines: [64]e.GeometryLine = undefined;
    const prepared = try host.adapters[1].preparedCarets(try host.documents[1].version(), &stops, &lines, .{});
    const point: ui.layout.Point = .{ .x = presentation.columns[1].x + 35, .y = prepared.lines[0].rect.y + prepared.lines[0].rect.height / 2 };
    const target_caret = try host.adapters[1].hitTest(presentation.columns[1], point);
    const transformed = try host.matrix.mapPoint(.{ .x = point.x, .y = point.y });
    const click: z.Event = .{ .pointer_down = .{ .position = .{ .x = @floatCast(transformed.x), .y = @floatCast(transformed.y) } } };
    try std.testing.expect(if (builtin.os.tag == .windows) try host.bridge.?.handleEvent(click, host.parameters) else try host.view.handleEvent(click, bounds, host.parameters));
    try std.testing.expectEqual(target_caret.byte_offset, (try host.documents[1].selection()).caret);
    try host.contextRead();
    try host.prepare();
    try host.paint();
    // Ordinary selection revision changes preserve the same coordinate lease
    // through native update/observer preparation, before another front exists.
    try std.testing.expectEqual(z.text.ChangeResult.applied, try host.window.changeTextClient(native_token, .{ .select = .{ .anchor = 2, .caret = 0 } }));
    try std.testing.expectEqualDeep(d.Selection{ .anchor = 2, .caret = 0 }, try host.documents[1].selection());
    try host.contextRead();
    try host.prepare();
    try host.paint();
    var shifted = bounds;
    shifted.x += 8;
    try host.view.prepare(shifted, host.parameters);
    try host.rejectNative(native_token, error.GeometryRequired);
    try host.view.prepare(bounds, host.parameters);
    try host.contextRead();
    try host.prepare();
    try host.paint();
    const before_loss = try host.documents[1].version();
    const selection_before_loss = try host.documents[1].selection();
    document_probe.armed = true;
    try std.testing.expectError(error.GeometryRequired, host.window.changeTextClient(native_token, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "explicit candidate allocation loses the accepted authority" } }));
    try std.testing.expect(document_probe.fired and !document_probe.armed);
    try std.testing.expectEqual(before_loss, try host.documents[1].version());
    try std.testing.expectEqualDeep(selection_before_loss, try host.documents[1].selection());
    try host.prepare();
    try host.paint();
    try host.contextRead();
    // An observer may lose the accepted front while preparing an already
    // committed native change. Its result must forbid replay of that change.
    const observer_revision = try host.documents[1].version();
    view_probe.exhaust = exhaust_observer;
    view_probe.armed = true;
    const observed = try host.window.changeTextClient(native_token, .{ .select = .{ .anchor = 0, .caret = 1 } });
    try std.testing.expect(view_probe.fired and !view_probe.armed);
    try std.testing.expectEqual(observer_revision + 1, try host.documents[1].version());
    try std.testing.expectEqualDeep(d.Selection{ .anchor = 0, .caret = 1 }, try host.documents[1].selection());
    try std.testing.expectEqual(z.text.ChangeResult.superseded, observed);
    if (exhaust_observer) {
        try std.testing.expectError(error.IdExhausted, host.lease.snapshot());
        if (host.failure) |err| return err;
        return;
    }
    try host.prepare();
    try host.paint();
    const oom_revision = try host.documents[1].version();
    if (host.failure) |err| return err;
    const diagnostics = host.diagnostic_count;
    host.expected_diagnostic = error.OutOfMemory;
    view_fault.fail_index = view_fault.alloc_index;
    const oom_observer = host.window.changeTextClient(native_token, .{ .select = .{ .anchor = 1, .caret = 0 } });
    view_fault.fail_index = std.math.maxInt(usize);
    host.expected_diagnostic = null;
    try std.testing.expectEqual(z.text.ChangeResult.applied, try oom_observer);
    try std.testing.expectEqual(oom_revision + 1, try host.documents[1].version());
    try std.testing.expectEqualDeep(d.Selection{ .anchor = 1, .caret = 0 }, try host.documents[1].selection());
    if (host.failure) |err| return err;
    try std.testing.expectEqual(diagnostics + 1, host.diagnostic_count);
    try host.prepare();
    try host.paint();
    const old = try host.context.committedSpace(91);
    // Release requires a successful plain frame before rebuilding the workspace.
    // Missing record invalidates the native lease and body input independently.
    host.record_body = false;
    host.unrelated_capture = false;
    host.plain = true;
    try host.paint();
    try host.rejectNative(native_token, error.GeometryRequired);
    try host.context.releaseTransforms();
    try host.context.prepareTransforms(allocator, options);
    host.plain = false;
    host.record_body = true;
    try host.paint();
    try host.rejectNative(native_token, error.StaleSpace);
    try std.testing.expectError(error.StaleSpace, host.setSpace(old));
    try host.setSpace(try host.context.committedSpace(91));
    try host.contextRead();
    // Explicit withdrawal cancels the real client and prevents default DIP fallthrough.
    if (builtin.os.tag == .windows) try host.bridge.?.clearCommittedSpace() else try host.coordinates.withdraw();
    try std.testing.expect(!try host.window.hasTextClient());
    try std.testing.expectError(error.GeometryRequired, host.view.focus(.b));
    try host.prepare();
    try host.paint();
    try std.testing.expectError(error.GeometryRequired, host.view.focus(.b));
    try host.setSpace(try host.context.committedSpace(91));
    try host.view.focus(.b);
    // The native publisher's last allocator callback may legally acquire a new
    // physical Adapter token. Remaining coordinate ownership must survive a
    // retryable close; already retired native storage is never called again.
    if (builtin.os.tag == .windows) {
        const bridge = host.bridge.?;
        bridge_probe.rebind = .{ .address = nativeAddress(bridge), .host = host };
        const closing = bridge.close();
        if (bridge.coordinates == null) {
            // Formal old-source oracle: avoid retrying its dangling native
            // pointer while preserving the explicit wrong ownership result.
            host.bridge = null;
            try host.coordinates.withdraw();
            try host.coordinates.close();
            allocator.destroy(bridge);
            try host.view.releaseClient();
            return error.ClosingCoordinateLost;
        }
        try std.testing.expectError(error.UnbindPending, closing);
        try std.testing.expect(bridge_probe.rebound);
        if (bridge_probe.failure) |err| return err;
        try std.testing.expectError(error.Closed, bridge.stats());
        try std.testing.expectError(error.Closed, bridge.prepare(.{ null, null }));
        try std.testing.expectError(error.Closed, bridge.retainProvider(null));
        try std.testing.expectError(error.Closed, bridge.handleEvent(.{ .key_input = .{ .key = .enter } }, host.parameters));
        view_probe.rebind = .{ .address = @intFromPtr(host.coordinates), .host = host };
        try bridge.close();
        host.bridge = null;
    } else {
        try host.coordinates.withdraw();
        try host.lease.release(host.publisher);
        host.publisher = 0;
        // Linux has no native document provider: this explicit owned shell
        // reproduces only its final-free/rebind responsibility at the shared
        // CoordinateBinding seam; Windows above closes the real native owner.
        const shell = try bridge_probe.allocator().create(u8);
        bridge_probe.rebind = .{ .address = @intFromPtr(shell), .host = host };
        bridge_probe.allocator().destroy(shell);
        try std.testing.expect(bridge_probe.rebound);
        if (bridge_probe.failure) |err| return err;
        try std.testing.expectError(error.UnbindPending, host.coordinates.close());
        try host.coordinates.withdraw();
        view_probe.rebind = .{ .address = @intFromPtr(host.coordinates), .host = host };
        try host.coordinates.close();
        _ = try host.context.clearAccessibilitySource(host.phase_token.?);
    }
    try std.testing.expect(view_probe.rebound);
    if (view_probe.failure) |err| return err;
    const retired = host.window.textClientToken().?;
    try host.rejectNative(retired, error.GeometryRequired);
    try std.testing.expectError(error.GeometryRequired, host.view.focus(.b));
    try std.testing.expectError(error.GeometryRequired, host.view.handleEvent(.{ .key_input = .{ .key = .enter } }, bounds, host.parameters));
    try std.testing.expectError(error.GeometryRequired, host.adapters[1].syncNativeCaret());
    // Programmatic prepare remains legal. New input requires a new explicit
    // binding and a matching successful front, with no default DIP fallback.
    try host.view.prepare(bounds, host.parameters);
    try host.adapters[1].unbind();
    if (builtin.os.tag == .windows) {
        host.bridge = try paired.Bridge.create(bridge_probe.allocator(), host.window, target, .{ .accessibility = .{ .affine_geometry = true, .cells = 512, .carets = 512, .lines = 64 }, .affine_space_id = 91 });
        host.coordinates = host.bridge.?.coordinates.?;
        try host.bridge.?.attachContext(&host.context);
    } else {
        host.coordinates = try host.view.acquireCoordinates(91);
        try host.coordinates.attachContext(&host.context);
        host.phase_token = try host.context.installAccessibilitySource(.{ .context = host, .query = Host.query, .phase = Host.phase });
    }
    host.lease = try host.coordinates.publication();
    document_probe.lease = host.lease;
    view_probe.lease = host.lease;
    if (builtin.os.tag != .windows) host.publisher = try host.lease.acquire();
    try host.prepare();
    try std.testing.expectError(error.GeometryRequired, host.view.focus(.b));
    try host.paint();
    try host.setSpace(try host.context.committedSpace(91));
    try host.view.focus(.b);
    try host.contextRead();
    // IME uses the same sole Document and projection suspension. This direct
    // producer test does not claim a particular installed language engine.
    try std.testing.expect(try host.view.handleEvent(.{ .text_preedit = .{ .text = "候\n选", .selection_start = 0, .selection_end = 3 } }, bounds, host.parameters));
    try std.testing.expect((try host.view.info()).composition_identity);
    try host.contextRead();
    const scope = host.window.beginCallback().?;
    try std.testing.expectEqual(z.CloseResult.deferred, try host.window.destroy());
    if (builtin.os.tag == .windows) try std.testing.expectError(error.UnbindPending, host.bridge.?.close()) else try std.testing.expectError(error.UnbindPending, host.coordinates.withdraw());
    try std.testing.expect(try host.documents[1].composition() != null);
    scope.end();
    try app.dispatch();
    try std.testing.expect(try host.documents[1].composition() == null);
    // Exhaustion permanently denies new authority but cannot prevent owner
    // retirement. Restore the injected counter only on the old failing path
    // so the fixture can release its existing owners before returning RED.
    const teardown_generation = host.lease.generation;
    host.lease.generation = std.math.maxInt(u64) - 1;
    _ = try host.lease.withdraw();
    const exhausted_cleanup = host.coordinates.withdraw();
    if (exhausted_cleanup) |_| {} else |err| {
        host.lease.generation = teardown_generation;
        std.debug.print("affine exhausted-authority cleanup failed before retirement: {s}\n", .{@errorName(err)});
        return err;
    }
    try std.testing.expectError(error.IdExhausted, host.lease.snapshot());
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const before = a.resourceCounts();
    try fold_checks.run(gpa.allocator());
    try run(gpa.allocator(), false, false);
    try run(gpa.allocator(), true, false);
    try run(gpa.allocator(), false, true);
    try run(gpa.allocator(), true, true);
    try std.testing.expectEqual(before, a.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("affine editable Diff: {s}, shared Space/lease and native TextClient, split/unified, exact front association, failed/missing/nested fronts, wrong/stale tokens resources=0\n", .{if (builtin.os.tag == .windows) "real UIA rectangles/point/caret" else "real GTK shared-coordinate seam; no native document provider"});
}

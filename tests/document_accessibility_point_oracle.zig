//! Native point expectations come from the live Adapter, never a hit packet.
const std = @import("std");
const ui = @import("ziggurat_ui");
const e = @import("ziggurat_document_editor");
const d = @import("ziggurat_document");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("objbase.h");
});
extern fn zda_probe_point(*anyopaque, f64, f64, *u32) i32;

pub const invalid_argument: i32 = @bitCast(@as(u32, 0x80070057));
pub const not_supported: i32 = @bitCast(@as(u32, 0x80040204));
pub const Coordinates = struct {
    origin: ui.affine.Point,
    scale: f64,
    forward: ui.affine.Affine,
    inverse: ui.affine.Affine,

    pub fn init(hwnd: ?*anyopaque, scale: f64, matrix: ui.affine.Affine, offset: ui.layout.Point) !Coordinates {
        var origin = std.mem.zeroes(c.POINT);
        if (c.ClientToScreen(hwnd, &origin) == 0) return error.ClientOriginFailed;
        // Independently apply the public native-float contract to all six
        // configured coefficients. No recorded Mapping/Space is inspected.
        var forward: ui.affine.Affine = undefined;
        inline for (std.meta.fields(ui.affine.Affine)) |field| {
            @field(forward, field.name) = @as(f32, @floatCast(@field(matrix, field.name)));
        }
        forward.x0 += forward.xx * offset.x + forward.xy * offset.y;
        forward.y0 += forward.yx * offset.x + forward.yy * offset.y;
        return .{ .origin = .{ .x = @floatFromInt(origin.x), .y = @floatFromInt(origin.y) }, .scale = scale, .forward = forward, .inverse = try forward.inverse() };
    }
    pub fn screen(self: Coordinates, local_point: ui.affine.Point) ui.affine.Point {
        return .{
            .x = self.origin.x + (self.forward.xx * local_point.x + self.forward.xy * local_point.y + self.forward.x0) * self.scale,
            .y = self.origin.y + (self.forward.yx * local_point.x + self.forward.yy * local_point.y + self.forward.y0) * self.scale,
        };
    }
    pub fn local(self: Coordinates, screen_point: ui.affine.Point) ui.layout.Point {
        const point = self.localDouble(screen_point);
        return .{ .x = @floatCast(point.x), .y = @floatCast(point.y) };
    }
    pub fn localDouble(self: Coordinates, screen_point: ui.affine.Point) ui.affine.Point {
        // Preserve native screen subtraction/division, double inverse, then
        // one final f32 cast before the original Adapter's own hit arithmetic.
        const x = (screen_point.x - self.origin.x) / self.scale;
        const y = (screen_point.y - self.origin.y) / self.scale;
        return .{
            .x = self.inverse.xx * x + self.inverse.xy * y + self.inverse.x0,
            .y = self.inverse.yx * x + self.inverse.yy * y + self.inverse.y0,
        };
    }
    pub fn window(self: Coordinates, point: ui.affine.Point) ui.affine.Point {
        const screen_point = self.screen(point);
        return .{ .x = (screen_point.x - self.origin.x) / self.scale, .y = (screen_point.y - self.origin.y) / self.scale };
    }
};

pub const Batch = struct {
    const Query = struct { screen: ui.affine.Point, hr: i32, position: u32 };
    provider: *anyopaque,
    queries: [2048]Query = undefined,
    len: usize = 0,
    failure: ?anyerror = null,

    pub fn append(self: *Batch, adapter: *e.Adapter, document: *d.Document, bounds: ui.Rect, coordinates: Coordinates, point: ui.affine.Point) !void {
        try self.appendScreen(adapter, document, bounds, coordinates, coordinates.screen(point));
    }
    pub fn appendScreen(self: *Batch, adapter: *e.Adapter, document: *d.Document, bounds: ui.Rect, coordinates: Coordinates, screen_point: ui.affine.Point) !void {
        const hit = try adapter.hitTest(bounds, coordinates.local(screen_point));
        try self.add(.{ .screen = screen_point, .hr = 0, .position = @intCast(try document.utf16Offset(hit.byte_offset)) });
    }
    pub fn deny(self: *Batch, coordinates: Coordinates, point: ui.affine.Point, hr: i32) !void {
        try self.add(.{ .screen = coordinates.screen(point), .hr = hr, .position = std.math.maxInt(u32) });
    }
    pub fn denyScreen(self: *Batch, screen_point: ui.affine.Point, hr: i32) !void {
        try self.add(.{ .screen = screen_point, .hr = hr, .position = std.math.maxInt(u32) });
    }
    fn add(self: *Batch, query: Query) !void {
        if (self.len == self.queries.len) return error.PointOracleCapacity;
        self.queries[self.len] = query;
        self.len += 1;
    }
    pub fn ownerCheck(self: *const Batch) !void {
        for (self.queries[0..self.len], 0..) |query, at| {
            var offset: u32 = std.math.maxInt(u32);
            const hr = zda_probe_point(self.provider, query.screen.x, query.screen.y, &offset);
            if (hr != query.hr or (hr == 0 and offset != query.position)) {
                std.debug.print("Prepared UIA point[{d}] screen=({d},{d}) expected={d}/0x{x} actual={d}/0x{x}\n", .{ at, query.screen.x, query.screen.y, query.position, @as(u32, @bitCast(query.hr)), offset, @as(u32, @bitCast(hr)) });
            }
            try std.testing.expectEqual(query.hr, hr);
            if (hr == 0) try std.testing.expectEqual(query.position, offset);
        }
    }
    fn worker(self: *Batch) void {
        self.mtaCheck() catch |err| {
            self.failure = err;
        };
    }
    fn mtaCheck(self: *Batch) !void {
        if (c.CoInitializeEx(null, c.COINIT_MULTITHREADED) < 0) return error.MtaInitializationFailed;
        defer c.CoUninitialize();
        try self.ownerCheck();
    }
    pub fn verify(self: *Batch) !void {
        try self.ownerCheck();
        const thread = try std.Thread.spawn(.{}, worker, .{self});
        thread.join();
        if (self.failure) |err| return err;
    }
};

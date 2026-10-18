const std = @import("std");
const v = @import("ziggurat_vector");
const doc = @import("document.zig");
const n = @import("numbers.zig");
pub const Viewport = struct { width: f64, height: f64 };
pub fn coordinate(node: doc.Node, key: []const u8, fallback: f64, reference: f64) !f64 {
    return if (node.attribute(key)) |input| (try n.length(input)).resolve(reference) else fallback;
}
pub fn path(allocator: std.mem.Allocator, node: doc.Node, name: []const u8, viewport: Viewport, limits: v.Limits, cancellation: ?*const v.Cancellation) !?*v.Path {
    if (cancellation) |cancel| try cancel.check();
    if (std.mem.eql(u8, name, "path")) {
        const data = node.attribute("d") orelse "";
        return try v.Path.parseData(allocator, data, .{ .limits = limits, .cancellation = cancellation });
    }
    if (std.mem.eql(u8, name, "line")) return try v.Path.create(allocator, &.{
        .{ .move = .{ .x = try coordinate(node, "x1", 0, viewport.width), .y = try coordinate(node, "y1", 0, viewport.height) } },
        .{ .line = .{ .x = try coordinate(node, "x2", 0, viewport.width), .y = try coordinate(node, "y2", 0, viewport.height) } },
    }, limits);
    if (std.mem.eql(u8, name, "rect")) {
        const x = try coordinate(node, "x", 0, viewport.width);
        const y = try coordinate(node, "y", 0, viewport.height);
        const width = try coordinate(node, "width", 0, viewport.width);
        const height = try coordinate(node, "height", 0, viewport.height);
        var rx = try coordinate(node, "rx", -1, viewport.width);
        var ry = try coordinate(node, "ry", -1, viewport.height);
        if (width < 0 or height < 0 or (node.attribute("rx") != null and rx < 0) or (node.attribute("ry") != null and ry < 0)) return error.InvalidShape;
        if (width == 0 or height == 0) return null;
        if (rx < 0 and ry < 0) {
            rx = 0;
            ry = 0;
        } else if (rx < 0) rx = ry else if (ry < 0) ry = rx;
        rx = @min(rx, width / 2);
        ry = @min(ry, height / 2);
        if (rx == 0 or ry == 0) return try v.Path.create(allocator, &.{ .{ .move = .{ .x = x, .y = y } }, .{ .line = .{ .x = x + width, .y = y } }, .{ .line = .{ .x = x + width, .y = y + height } }, .{ .line = .{ .x = x, .y = y + height } }, .close }, limits);
        const radius: v.Point = .{ .x = rx, .y = ry };
        return try v.Path.create(allocator, &.{
            .{ .move = .{ .x = x + rx, .y = y } },                                                              .{ .line = .{ .x = x + width - rx, .y = y } },
            .{ .arc = .{ .radius = radius, .sweep = true, .end = .{ .x = x + width, .y = y + ry } } },          .{ .line = .{ .x = x + width, .y = y + height - ry } },
            .{ .arc = .{ .radius = radius, .sweep = true, .end = .{ .x = x + width - rx, .y = y + height } } }, .{ .line = .{ .x = x + rx, .y = y + height } },
            .{ .arc = .{ .radius = radius, .sweep = true, .end = .{ .x = x, .y = y + height - ry } } },         .{ .line = .{ .x = x, .y = y + ry } },
            .{ .arc = .{ .radius = radius, .sweep = true, .end = .{ .x = x + rx, .y = y } } },                  .close,
        }, limits);
    }
    if (std.mem.eql(u8, name, "circle") or std.mem.eql(u8, name, "ellipse")) {
        const x = try coordinate(node, "cx", 0, viewport.width);
        const y = try coordinate(node, "cy", 0, viewport.height);
        const circle = std.mem.eql(u8, name, "circle");
        const rx = if (circle) try coordinate(node, "r", 0, std.math.hypot(viewport.width, viewport.height) / @sqrt(@as(f64, 2))) else try coordinate(node, "rx", 0, viewport.width);
        const ry = if (circle) rx else try coordinate(node, "ry", 0, viewport.height);
        if (rx < 0 or ry < 0) return error.InvalidShape;
        if (rx == 0 or ry == 0) return null;
        const radius: v.Point = .{ .x = rx, .y = ry };
        return try v.Path.create(allocator, &.{
            .{ .move = .{ .x = x + rx, .y = y } },
            .{ .arc = .{ .radius = radius, .sweep = true, .end = .{ .x = x, .y = y + ry } } },
            .{ .arc = .{ .radius = radius, .sweep = true, .end = .{ .x = x - rx, .y = y } } },
            .{ .arc = .{ .radius = radius, .sweep = true, .end = .{ .x = x, .y = y - ry } } },
            .{ .arc = .{ .radius = radius, .sweep = true, .end = .{ .x = x + rx, .y = y } } },
            .close,
        }, limits);
    }
    if (std.mem.eql(u8, name, "polygon") or std.mem.eql(u8, name, "polyline")) {
        const data = node.attribute("points") orelse return null;
        var iterator: n.List = .{ .scan = .{ .input = data } };
        var values: usize = 0;
        while (try iterator.next()) |_| {
            if (values == limits.commands * 2) return error.CapacityExceeded;
            values += 1;
        }
        if (values % 2 != 0) return error.InvalidPoints;
        if (values == 0) return null;
        const closed = std.mem.eql(u8, name, "polygon");
        const count = values / 2 + @as(usize, @intFromBool(closed));
        if (count > limits.commands or count > limits.bytes / @sizeOf(v.Command)) return error.CapacityExceeded;
        const commands = try allocator.alloc(v.Command, count);
        defer allocator.free(commands);
        iterator = .{ .scan = .{ .input = data } };
        for (0..values / 2) |i| {
            if (cancellation) |cancel| try cancel.check();
            const point: v.Point = .{ .x = (try iterator.next()).?, .y = (try iterator.next()).? };
            commands[i] = if (i == 0) .{ .move = point } else .{ .line = point };
        }
        if (closed) commands[count - 1] = .close;
        var remainder = limits;
        remainder.bytes -= count * @sizeOf(v.Command);
        return try v.Path.create(allocator, commands, remainder);
    }
    return error.UnsupportedElement;
}

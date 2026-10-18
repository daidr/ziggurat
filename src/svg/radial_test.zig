const std = @import("std");
const api = @import("root.zig");
const allocator = std.testing.allocator;

test "SVG near tangent outside cone remains transparent in both compositing modes" {
    const cases = [_][]const u8{
        "cx='2' cy='1e-30' r='1' fx='1' fy='0'",
        "cx='1e-30' cy='2' r='1' fx='0' fy='1'",
    };
    for (cases) |attributes| {
        const source = try std.fmt.allocPrint(allocator, "<svg><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' {s}><stop stop-color='red'/><stop offset='1' stop-color='blue'/></radialGradient></defs><rect width='2' height='2' fill='url(#g)'/></svg>", .{attributes});
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        for ([_]@FieldType(api.PrepareOptions, "compositing"){ .pixel, .sample_color }) |mode| {
            const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 2, .height = 2, .compositing = mode });
            defer image.close() catch unreachable;
            // Every positive-radius circle has leftmost x=1 (or bottom y=1).
            // (.5,.5) cannot belong to any of them; a tangent pad limit would
            // incorrectly paint it blue. This oracle does not solve a quadratic.
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, image.pixels[0..4]);
        }
    }
}

test "SVG uncertain subtraction cannot silently create a tangent classification" {
    const source = "<svg><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='-1e-30' cy='0' r='1' fx='1' fy='0'><stop/></radialGradient></defs><rect width='2' height='2' fill='url(#g)'/></svg>";
    const document = try api.Document.parse(allocator, source, .{});
    defer document.close() catch unreachable;
    for ([_]@FieldType(api.PrepareOptions, "compositing"){ .pixel, .sample_color }) |mode| {
        try std.testing.expectError(error.UnsupportedRadialPrecision, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 2, .height = 2, .compositing = mode }));
    }
}

test "SVG constant RGB tangent periodic alpha has an unambiguous weighted mean" {
    const cases = [_]struct { stops: []const u8, pixel: [4]u8 }{
        .{ .stops = "<stop stop-color='red' stop-opacity='0'/><stop offset='1' stop-color='red'/>", .pixel = .{ 0, 0, 128, 128 } },
        .{ .stops = "<stop stop-color='#808080' stop-opacity='0'/><stop offset='1' stop-color='#808080'/>", .pixel = .{ 64, 64, 64, 128 } },
        // Zero until .25, linear to .75, then one: integral alpha = .5.
        .{ .stops = "<stop offset='.25' stop-color='red' stop-opacity='0'/><stop offset='.75' stop-color='red'/>", .pixel = .{ 0, 0, 128, 128 } },
        // A discontinuity contributes no area; alpha is one only after .25.
        .{ .stops = "<stop stop-color='red' stop-opacity='0'/><stop offset='.25' stop-color='red' stop-opacity='0'/><stop offset='.25' stop-color='red'/><stop offset='1' stop-color='red'/>", .pixel = .{ 0, 0, 191, 191 } },
        .{ .stops = "<stop offset='.6' stop-color='red' stop-opacity='.25'/>", .pixel = .{ 0, 0, 64, 64 } },
        .{ .stops = "<stop stop-color='red' stop-opacity='0'/><stop offset='1' stop-color='red' stop-opacity='0'/>", .pixel = .{ 0, 0, 0, 0 } },
    };
    for (cases) |case| for ([_][]const u8{ "repeat", "reflect" }) |spread| for ([_][]const u8{ "sRGB", "linearRGB" }) |interpolation| {
        const source = try std.fmt.allocPrint(allocator, "<svg><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='2.5' cy='2.5' r='2' fx='4.5' fy='2.5' spreadMethod='{s}' color-interpolation='{s}'>{s}</radialGradient></defs><rect width='8' height='8' fill='url(#g)'/></svg>", .{ spread, interpolation, case.stops });
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        for ([_]@FieldType(api.PrepareOptions, "compositing"){ .pixel, .sample_color }) |mode| {
            const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 8, .compositing = mode });
            defer image.close() catch unreachable;
            try std.testing.expectEqualSlices(u8, &case.pixel, image.pixels[(2 * 8 + 6) * 4 ..][0..4]);
        }
    };
}

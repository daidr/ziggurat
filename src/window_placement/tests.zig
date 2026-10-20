const std = @import("std");
const m = @import("model.zig");
const codec = @import("codec.zig");
const Files = @import("files.zig").Files;
fn key(value: []const u8) m.Key {
    return m.Key.init(value) catch unreachable;
}
fn monitor(name: []const u8, x: i32, y: i32, width: u32, height: u32, primary: bool) m.Monitor {
    return .{ .key = key(name), .bounds = .{ .x = x, .y = y, .width = width, .height = height }, .work = .{ .x = x, .y = y + 20, .width = width, .height = height - 20 }, .primary = primary };
}
fn sample() m.State {
    return .{ .space = .win32_physical, .normal = .{ .position = .{ .x = 120, .y = 100 }, .width = 800, .height = 600 }, .work = .{ .x = 0, .y = 20, .width = 1920, .height = 1060 }, .display = key("panel-a") };
}

test "workarea constraints preserve DIP size and map native negative positions across DPI" {
    const topology = try m.Topology.init(.win32_physical, &.{ monitor("panel-a", -2560, -200, 2560, 1600, true), monitor("panel-b", 0, 0, 1920, 1080, false) });
    var saved = sample();
    saved.maximized = true;
    saved.fullscreen = true;
    const fit = try m.resolve(saved, &topology, .{ .units_per_dip = 2, .insets = .{ .left = 8, .right = 8, .top = 46, .bottom = 8 } }, .{});
    try std.testing.expectEqual(@as(u32, 800), fit.bounds.width);
    try std.testing.expectEqual(@as(u32, 600), fit.bounds.height);
    try std.testing.expectEqual(@as(i32, -2320), fit.bounds.position.x);
    try std.testing.expectEqual(@as(i32, -20), fit.bounds.position.y);
    try std.testing.expect(fit.maximized and fit.fullscreen and fit.recovered);
    try std.testing.expectEqual(@as(u8, 0), fit.display_index);
    saved.normal.width = 32768;
    saved.normal.height = 32768;
    const clipped = try m.resolve(saved, &topology, .{ .units_per_dip = 2, .insets = .{ .left = 8, .right = 8, .top = 46, .bottom = 8 } }, .{});
    try std.testing.expectEqual(@as(u32, 1272), clipped.bounds.width);
    try std.testing.expectEqual(@as(u32, 763), clipped.bounds.height);
    try std.testing.expectError(error.ConstraintsUnsatisfiable, m.resolve(saved, &topology, .{ .units_per_dip = 2 }, .{ .min_width = 1400 }));
}
test "removed connector chooses overlap then distance; cross-space placement starts on primary" {
    const topology = try m.Topology.init(.win32_physical, &.{ monitor("left", -1000, 0, 1000, 800, false), monitor("right", 0, 0, 1000, 800, true) });
    var saved = sample();
    saved.display = key("removed");
    saved.normal.position = .{ .x = -900, .y = 100 };
    try std.testing.expectEqual(@as(u8, 0), try m.choose(saved, &topology));
    saved.normal.position = .{ .x = 10000, .y = 10000 };
    const recovered = try m.resolve(saved, &topology, .{}, .{});
    try std.testing.expectEqual(@as(u8, 1), recovered.display_index);
    try std.testing.expectEqual(@as(i32, 100), recovered.bounds.position.x);
    try std.testing.expectEqual(@as(i32, 110), recovered.bounds.position.y);
    saved.space = .x11_logical;
    saved.normal.position = .{ .x = -900, .y = 0 };
    try std.testing.expectEqual(@as(u8, 1), try m.choose(saved, &topology));
}
test "constraints and geometry reject invalid scale, impossible workarea and integer endpoints" {
    var bad = monitor("bad", std.math.maxInt(i32) - 10, 0, 100, 200, true);
    try std.testing.expectError(error.InvalidRectangle, m.Topology.init(.win32_physical, &.{bad}));
    bad = monitor("bad", 0, 0, 100, 100, true);
    bad.work.width = 101;
    try std.testing.expectError(error.InvalidWorkarea, m.Topology.init(.win32_physical, &.{bad}));
    bad.work.width = 100;
    try std.testing.expectError(error.DuplicateDisplay, m.Topology.init(.win32_physical, &.{ bad, bad }));
}
test "random fit agrees with independently checked workarea containment and DIP constraints" {
    var rng = std.Random.DefaultPrng.init(0x917aef05);
    const random = rng.random();
    for (0..10000) |_| {
        const width = random.intRangeAtMost(u32, 64, 5000);
        const height = random.intRangeAtMost(u32, 64, 3000);
        const panel = monitor("panel-a", random.intRangeAtMost(i32, -100000, 100000), random.intRangeAtMost(i32, -100000, 100000), width, height, true);
        const topology = try m.Topology.init(.win32_physical, &.{panel});
        var saved = sample();
        saved.normal.position = .{ .x = random.int(i32), .y = random.int(i32) };
        saved.normal.width = random.intRangeAtMost(u32, 1, 32768);
        saved.normal.height = random.intRangeAtMost(u32, 1, 32768);
        const scale = @as(f64, @floatFromInt(random.intRangeAtMost(u32, 1, 16))) / 4;
        const fit = try m.resolve(saved, &topology, .{ .units_per_dip = scale, .insets = .{ .left = 2, .top = 4, .right = 3, .bottom = 1 } }, .{});
        const p = fit.bounds.position;
        try std.testing.expect(p.x >= @as(i64, panel.work.x) + 2 and p.y >= @as(i64, panel.work.y) + 4);
        try std.testing.expect(@as(f64, @floatFromInt(p.x)) + @ceil(@as(f64, @floatFromInt(fit.bounds.width)) * scale) + 3 <= @as(f64, @floatFromInt(panel.work.right())));
        try std.testing.expect(@as(f64, @floatFromInt(p.y)) + @ceil(@as(f64, @floatFromInt(fit.bounds.height)) * scale) + 1 <= @as(f64, @floatFromInt(panel.work.bottom())));
        try std.testing.expect(fit.bounds.width >= 1 and fit.bounds.width <= saved.normal.width);
        try std.testing.expect(fit.bounds.height >= 1 and fit.bounds.height <= saved.normal.height);
    }
    const topology = try m.Topology.init(.win32_physical, &.{monitor("panel-a", 0, 0, 1920, 1080, true)});
    for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64), 17 }) |scale| try std.testing.expectError(error.InvalidScale, m.resolve(sample(), &topology, .{ .units_per_dip = scale }, .{}));
}
test "store and versioned codec preserve old state on capacity, corruption and unsupported versions" {
    var rows: [2]m.Entry = undefined;
    var store = try m.Store.init(&rows);
    var saved = sample();
    saved.maximized = true;
    saved.fullscreen = true;
    saved.always_on_top = true;
    try store.put(key("main"), saved);
    try store.put(key("编辑器"), sample());
    try std.testing.expectError(error.CapacityExceeded, store.put(key("third"), sample()));
    var data: [codec.max_bytes]u8 = @splat(0xaa);
    try std.testing.expectError(error.OutputTooSmall, codec.encode(&store, data[0..10]));
    try std.testing.expect(std.mem.allEqual(u8, &data, 0xaa));
    const bytes = try codec.encode(&store, &data);
    var restored_rows: [2]m.Entry = undefined;
    var restored = try m.Store.init(&restored_rows);
    try codec.decode(&restored, bytes);
    try std.testing.expectEqualDeep(saved, restored.get(key("main")).?);
    try std.testing.expectEqual(@as(usize, 2), restored.count);
    for (0..bytes.len) |at| {
        var corrupted: [codec.max_bytes]u8 = undefined;
        @memcpy(corrupted[0..bytes.len], bytes);
        corrupted[at] ^= 0x80;
        if (codec.decode(&restored, corrupted[0..bytes.len])) |_| return error.CorruptionAccepted else |_| {}
        try std.testing.expectEqualDeep(saved, restored.get(key("main")).?);
    }
    var one_row: [1]m.Entry = undefined;
    var small = try m.Store.init(&one_row);
    try small.put(key("keep"), sample());
    try std.testing.expectError(error.CapacityExceeded, codec.decode(&small, bytes));
    try std.testing.expect(small.get(key("keep")) != null);
    data[4] = 2;
    try std.testing.expectError(error.UnsupportedVersion, codec.decode(&restored, bytes));
    try std.testing.expect(restored.remove(key("编辑器")));
    try std.testing.expect(!restored.remove(key("编辑器")));
}
test "codec rejects duplicate keys and malformed fields even with a valid checksum" {
    var rows: [2]m.Entry = undefined;
    var store = try m.Store.init(&rows);
    try store.put(key("a"), sample());
    try store.put(key("b"), sample());
    var data: [1024]u8 = undefined;
    const bytes = try codec.encode(&store, &data);
    const duplicate = codec.header_bytes + codec.record_bytes;
    @memcpy(data[duplicate..][0..97], data[codec.header_bytes..][0..97]);
    std.mem.writeInt(u32, data[12..16], std.hash.Crc32.hash(data[16..bytes.len]), .little);
    try std.testing.expectError(error.DuplicateKey, codec.decode(&store, bytes));
    try std.testing.expectEqual(@as(usize, 2), store.count);
    data[codec.header_bytes + 194] = 255;
    std.mem.writeInt(u32, data[12..16], std.hash.Crc32.hash(data[16..bytes.len]), .little);
    try std.testing.expectError(error.InvalidEncoding, codec.decode(&store, bytes));
}
test "hard capacity roundtrips without heap storage and rejects one extra record" {
    var rows: [m.max_entries]m.Entry = undefined;
    var store = try m.Store.init(&rows);
    for (0..rows.len) |at| {
        var name: [16]u8 = undefined;
        try store.put(key(try std.fmt.bufPrint(&name, "window-{d}", .{at})), sample());
    }
    try std.testing.expectError(error.CapacityExceeded, store.put(key("extra"), sample()));
    var data: [codec.max_bytes]u8 = undefined;
    const encoded = try codec.encode(&store, &data);
    try std.testing.expectEqual(codec.max_bytes, encoded.len);
    var other: [m.max_entries]m.Entry = undefined;
    var restored = try m.Store.init(&other);
    try codec.decode(&restored, encoded);
    try std.testing.expectEqualDeep(store.items(), restored.items());
    try std.testing.expectError(error.NoDisplays, m.Topology.init(.x11_logical, &.{}));
    var monitors: [m.max_monitors + 1]m.Monitor = undefined;
    for (&monitors, 0..) |*panel, at| {
        var name: [16]u8 = undefined;
        panel.* = monitor(try std.fmt.bufPrint(&name, "panel-{d}", .{at}), @as(i32, @intCast(at)) * 100, 0, 100, 100, at == 0);
    }
    const topology = try m.Topology.init(.x11_logical, monitors[0..m.max_monitors]);
    try std.testing.expectEqual(m.max_monitors, topology.items().len);
    try std.testing.expectError(error.CapacityExceeded, m.Topology.init(.x11_logical, &monitors));
}
test "explicit worker atomic store replaces, reloads and retries a failed destination" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const Work = struct {
        files: Files,
        directory: std.fs.Dir,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            self.inner() catch |err| {
                self.err = err;
            };
        }
        fn inner(self: *@This()) !void {
            var rows: [1]m.Entry = undefined;
            var store = try m.Store.init(&rows);
            try store.put(key("main"), sample());
            var encoded: [1024]u8 = undefined;
            const bytes = try codec.encode(&store, &encoded);
            var write_buffer: [64]u8 = undefined;
            var output: [1024]u8 = undefined;
            try self.files.save(self.directory, "placement.bin", bytes, &write_buffer);
            try std.testing.expectEqualSlices(u8, bytes, try self.files.read(self.directory, "placement.bin", &output));
            try self.directory.makeDir("blocked");
            if (self.files.save(self.directory, "blocked", bytes, &write_buffer)) |_| return error.RenameShouldFail else |_| {}
            try self.directory.deleteDir("blocked");
            try self.files.save(self.directory, "blocked", bytes, &write_buffer);
            try std.testing.expectEqualSlices(u8, bytes, try self.files.read(self.directory, "blocked", &output));
            try std.testing.expectError(error.CapacityExceeded, self.files.read(self.directory, "placement.bin", output[0..10]));
            try std.testing.expectError(error.InvalidPath, self.files.save(self.directory, "../escape", bytes, &write_buffer));
            var changed = sample();
            changed.normal.width = 500;
            try store.put(key("main"), changed);
            try self.files.save(self.directory, "placement.bin", try codec.encode(&store, &encoded), &write_buffer);
            try codec.decode(&store, try self.files.read(self.directory, "placement.bin", &output));
            try std.testing.expectEqual(@as(u32, 500), store.get(key("main")).?.normal.width);
        }
    };
    var work: Work = .{ .files = .{ .ui_thread = std.Thread.getCurrentId() }, .directory = temporary.dir };
    var buffer: [64]u8 = undefined;
    try std.testing.expectError(error.UiThreadIo, work.files.read(temporary.dir, "placement.bin", &buffer));
    try std.testing.expectError(error.UiThreadIo, work.files.save(temporary.dir, "placement.bin", "", &buffer));
    const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
    thread.join();
    if (work.err) |err| return err;
}
test "reach separates contained, partially visible and unreachable frames across workareas" {
    const topology = try m.Topology.init(.win32_physical, &.{ monitor("left", -1000, 0, 1000, 800, false), monitor("right", 0, 0, 1000, 800, true) });
    try std.testing.expectEqual(m.Reach.contained, try m.reach(.{ .x = -900, .y = 40, .width = 400, .height = 300 }, &topology));
    try std.testing.expectEqual(m.Reach.partial, try m.reach(.{ .x = -200, .y = 40, .width = 400, .height = 300 }, &topology));
    try std.testing.expectEqual(m.Reach.partial, try m.reach(.{ .x = 1000 - m.min_reachable, .y = 800 - m.min_reachable, .width = 400, .height = 300 }, &topology));
    try std.testing.expectEqual(m.Reach.offscreen, try m.reach(.{ .x = 1000 - m.min_reachable + 1, .y = 40, .width = 400, .height = 300 }, &topology));
    // The workarea starts below a 20-unit band, so this frame overlaps only it.
    try std.testing.expectEqual(m.Reach.offscreen, try m.reach(.{ .x = 100, .y = -280, .width = 400, .height = 300 }, &topology));
    try std.testing.expectEqual(m.Reach.offscreen, try m.reach(.{ .x = 5000, .y = 5000, .width = 400, .height = 300 }, &topology));
    // Frames smaller than the threshold must overlap entirely on that axis.
    try std.testing.expectEqual(m.Reach.contained, try m.reach(.{ .x = 990, .y = 40, .width = 10, .height = 10 }, &topology));
    try std.testing.expectEqual(m.Reach.offscreen, try m.reach(.{ .x = 995, .y = 40, .width = 10, .height = 10 }, &topology));
    try std.testing.expectError(error.InvalidRectangle, m.reach(.{ .x = 0, .y = 0, .width = 0, .height = 10 }, &topology));
}

const std = @import("std");
const d = @import("ziggurat_document");
const ix = @import("index.zig");
const memory = @import("memory.zig");
const testing = std.testing;

fn verify(storage: *ix.Storage, root: *ix.Node, text: []const u8) !void {
    try testing.expectEqual(text.len, root.sum.bytes);
    var start: usize = 0;
    var line: usize = 0;
    for (text, 0..) |byte, position| {
        try testing.expectEqual(line, ix.lineAt(storage, root, position));
        if (byte == '\n') {
            const row = ix.get(storage, root, line);
            try testing.expectEqual(position + 1 - start, row.bytes);
            try testing.expect(row.terminated);
            try testing.expectEqual(start, ix.prefix(storage, root, line).bytes);
            line += 1;
            start = position + 1;
        }
    }
    try testing.expectEqual(line, ix.lineAt(storage, root, text.len));
    try testing.expectEqual(line + 1, root.sum.rows);
    const row = ix.get(storage, root, line);
    try testing.expectEqual(text.len - start, row.bytes);
    try testing.expect(!row.terminated);
}
fn checked(node: *ix.Node) !void {
    try testing.expect(node.refs > 0 and node.height <= 64);
    if (node.value == .rows) {
        try testing.expect(node.value.rows.len > 0 and node.value.rows.len <= ix.chunk_rows);
        try testing.expectEqual(node.value.rows.len, node.sum.rows);
        var bytes: usize = 0;
        var ticks: u128 = 0;
        for (node.value.rows) |row| {
            bytes += row.bytes;
            ticks += row.ticks;
        }
        try testing.expectEqual(bytes, node.sum.bytes);
        try testing.expectEqual(ticks, node.sum.ticks);
        return;
    }
    const a = node.value.branch.left;
    const b = node.value.branch.right;
    try testing.expect(@abs(@as(i32, a.height) - @as(i32, b.height)) <= 1);
    try testing.expectEqual(a.sum.rows + b.sum.rows, node.sum.rows);
    try testing.expectEqual(a.sum.bytes + b.sum.bytes, node.sum.bytes);
    try testing.expectEqual(a.sum.ticks + b.sum.ticks, node.sum.ticks);
    try checked(a);
    try checked(b);
}
test "streaming paragraph index and random edit candidates agree with LF oracle" {
    var storage: ix.Storage = .{ .allocator = testing.allocator, .node_limit = 100000 };
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "a\r\nb\n", .{});
    defer document.close() catch unreachable;
    var builder: ix.Builder = .{ .storage = &storage, .row_limit = 10000, .next_id = 1, .epoch = 1, .estimate = try ix.quantize(20) };
    defer builder.deinit();
    var root = try builder.finish(document);
    defer ix.release(&storage, root);
    var next_id = builder.next_id;
    var linear: std.ArrayList(u8) = .empty;
    defer linear.deinit(testing.allocator);
    try linear.appendSlice(testing.allocator, "a\r\nb\n");
    var random_source = std.Random.DefaultPrng.init(0xb001a);
    const random = random_source.random();
    const values = [_][]const u8{ "", "a", "\n", "x\r\n", "\n\n", "longer" };
    for (2..2200) |epoch| {
        const start = random.uintLessThan(usize, linear.items.len + 1);
        const end = start + random.uintLessThan(usize, linear.items.len - start + 1);
        const text = values[random.uintLessThan(usize, values.len)];
        const first = ix.get(&storage, root, ix.lineAt(&storage, root, start));
        const plan = try ix.plan(&storage, root, .{ .start = start, .end = end }, text, next_id, epoch, try ix.quantize(20), 10000);
        try linear.replaceRange(testing.allocator, start, end - start, text);
        ix.release(&storage, root);
        root = plan.root;
        next_id = plan.next_id;
        try testing.expectEqual(first.id, ix.get(&storage, root, plan.first).id);
        try verify(&storage, root, linear.items);
        try checked(root);
    }
}
test "height aggregation is exact and local differences survive enormous prefixes" {
    var storage: ix.Storage = .{ .allocator = testing.allocator, .node_limit = 10000 };
    var rows: [1024]ix.Row = undefined;
    for (&rows, 0..) |*row, at| row.* = .{ .id = at + 1, .epoch = 1, .bytes = 2, .ticks = try ix.quantize(1000000), .terminated = true };
    const root = (try ix.build(&storage, &rows)).?;
    defer ix.release(&storage, root);
    const changed = try ix.height(&storage, root, 1000, try ix.quantize(12.345703125), 7);
    defer ix.release(&storage, changed);
    const before = ix.prefix(&storage, changed, 1000).ticks;
    const after = ix.prefix(&storage, changed, 1001).ticks;
    try testing.expectEqual(@as(f64, 12.345703125), @as(f64, @floatFromInt(after - before)) / ix.units);
    try testing.expectEqual(@as(usize, 1000), ix.atTick(&storage, changed, before));
    try testing.expectEqual(@as(usize, 1000), ix.atTick(&storage, changed, after - 1));
    try testing.expectEqual(@as(usize, 1001), ix.atTick(&storage, changed, after));
    try testing.expectEqual(@as(u64, 7), ix.get(&storage, changed, 1000).metric_generation);
    try testing.expectError(error.UnsupportedMetricPrecision, ix.quantize(0.000000000001));
}
fn allocationScenario(allocator: std.mem.Allocator) !void {
    var storage: ix.Storage = .{ .allocator = allocator, .node_limit = 10000 };
    const text = &@as([30 * "a\nb\nc\nd\ne\nf\n".len]u8, @bitCast(@as([30]["a\nb\nc\nd\ne\nf\n".len]u8, @splat("a\nb\nc\nd\ne\nf\n".*))));
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), text, .{});
    defer document.close() catch unreachable;
    var builder: ix.Builder = .{ .storage = &storage, .row_limit = 10000, .next_id = 1, .epoch = 1, .estimate = try ix.quantize(20) };
    defer builder.deinit();
    const root = try builder.finish(document);
    defer ix.release(&storage, root);
    const before = storage.nodes;
    const candidate = ix.plan(&storage, root, .{ .start = 3, .end = 9 }, "x\ny\nz", builder.next_id, 2, try ix.quantize(20), 10000) catch |err| {
        try testing.expectEqual(before, storage.nodes);
        try verify(&storage, root, text);
        return err;
    };
    defer ix.release(&storage, candidate.root);
    const changed = try ix.height(&storage, candidate.root, 1, try ix.quantize(17.125), 1);
    defer ix.release(&storage, changed);
}
test "chunk boundaries survive random persistent splices and shared height paths" {
    var storage: ix.Storage = .{ .allocator = testing.allocator, .node_limit = 100000 };
    var rows: [4097]ix.Row = undefined;
    for (&rows, 0..) |*row, at| row.* = .{ .id = at + 1, .epoch = 1, .bytes = if (at + 1 == rows.len) 1 else 2, .ticks = try ix.quantize(20), .terminated = at + 1 != rows.len };
    var root = (try ix.build(&storage, &rows)).?;
    defer ix.release(&storage, root);
    try testing.expect(storage.nodes < rows.len / 4);
    const original = ix.retain(root).?;
    defer ix.release(&storage, original);
    var linear: std.ArrayList(u8) = .empty;
    defer linear.deinit(testing.allocator);
    try linear.appendSlice(testing.allocator, &@as([4096 * "x\n".len]u8, @bitCast(@as([4096]["x\n".len]u8, @splat("x\n".*)))) ++ "x");
    var source = std.Random.DefaultPrng.init(0x53af192);
    const random = source.random();
    var next_id: u64 = 4098;
    for (2..502) |epoch| {
        const start = random.uintLessThan(usize, linear.items.len + 1);
        const end = @min(linear.items.len, start + random.uintLessThan(usize, 160));
        const insert = if (epoch % 3 == 0) "long\n\nline\r\n" else "z\n";
        const edit = try ix.plan(&storage, root, .{ .start = start, .end = end }, insert, next_id, epoch, try ix.quantize(20), 10000);
        try linear.replaceRange(testing.allocator, start, end - start, insert);
        ix.release(&storage, root);
        root = edit.root;
        next_id = edit.next_id;
        const row = random.uintLessThan(usize, root.sum.rows);
        const changed = try ix.height(&storage, root, row, try ix.quantize(17.125), 3);
        ix.release(&storage, root);
        root = changed;
        try verify(&storage, root, linear.items);
        try checked(root);
    }
    try testing.expectEqual(rows.len, original.sum.rows);
    try testing.expectEqual(@as(u64, 1), ix.get(&storage, original, 0).epoch);
    try testing.expectEqual(try ix.quantize(20), ix.get(&storage, original, 0).ticks);
}
test "all index construction and path update allocation failures preserve old roots" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}
test "budget allocator accounts resize remap external reservations and cleanup" {
    var budget: memory.Budget = .{ .source = testing.allocator, .limit = 64 };
    const allocator = budget.allocator();
    var bytes = try allocator.alloc(u8, 20);
    try budget.reserve(20);
    try testing.expectEqual(@as(usize, 40), budget.total());
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 25));
    try testing.expectEqual(error.CapacityExceeded, budget.normalize(error.OutOfMemory));
    budget.release(20);
    bytes = try allocator.realloc(bytes, 32);
    try testing.expectEqual(@as(usize, 32), budget.total());
    allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0), budget.total());
}

fn visibilityOracle(storage: *ix.Storage, root: *ix.Node, rows: []const ix.Row) !void {
    var ticks: u128 = 0;
    var raw: u128 = 0;
    var visible: usize = 0;
    var bytes: usize = 0;
    for (rows, 0..) |row, at| {
        const prefix = ix.prefix(storage, root, at);
        try testing.expectEqual(ticks, prefix.ticks);
        try testing.expectEqual(raw, prefix.raw_ticks);
        try testing.expectEqual(visible, prefix.visible_rows);
        try testing.expectEqual(bytes, prefix.bytes);
        const actual = ix.get(storage, root, at);
        try testing.expectEqualDeep(row, actual);
        if (!row.hidden) {
            try testing.expectEqual(at, ix.atTick(storage, root, ticks));
            try testing.expectEqual(at, ix.atTick(storage, root, ticks + row.ticks - 1));
            ticks += row.ticks;
            visible += 1;
        }
        raw += row.ticks;
        bytes += row.bytes;
        var next: ?usize = null;
        for (rows[at..], at..) |candidate, index| if (!candidate.hidden) {
            next = index;
            break;
        };
        try testing.expectEqual(next, ix.nextVisible(storage, root, at));
        var previous: ?usize = null;
        for (rows[0..at], 0..) |candidate, index| if (!candidate.hidden) {
            previous = index;
        };
        try testing.expectEqual(previous, ix.previousVisible(storage, root, at));
    }
    try testing.expectEqual(ticks, root.sum.ticks);
    try testing.expectEqual(raw, root.sum.raw_ticks);
    try testing.expectEqual(visible, root.sum.visible_rows);
    try testing.expectEqual(bytes, root.sum.bytes);
}
test "lazy visibility height updates and persistent splices agree with a plain row array" {
    var storage: ix.Storage = .{ .allocator = testing.allocator, .node_limit = 100000 };
    var linear: std.ArrayList(ix.Row) = .empty;
    defer linear.deinit(testing.allocator);
    for (0..257) |at| try linear.append(testing.allocator, .{ .id = at + 1, .epoch = 1, .bytes = 2, .ticks = at % 17 + 1, .terminated = true });
    var root = (try ix.build(&storage, linear.items)).?;
    defer ix.release(&storage, root);
    const initial = ix.retain(root).?;
    defer ix.release(&storage, initial);
    const original = try testing.allocator.dupe(ix.Row, linear.items);
    defer testing.allocator.free(original);
    var source = std.Random.DefaultPrng.init(0x0a71b32);
    const random = source.random();
    for (0..350) |iteration| {
        const first = random.uintLessThan(usize, linear.items.len);
        const end = first + random.uintLessThan(usize, linear.items.len - first + 1);
        const candidate = switch (iteration % 4) {
            0, 1 => block: {
                const hidden = iteration % 4 == 0;
                for (linear.items[first..end]) |*row| row.hidden = hidden;
                break :block try ix.setHidden(&storage, root, first, end, hidden);
            },
            2 => block: {
                const ticks = random.uintLessThan(u128, 100) + 1;
                linear.items[first].ticks = ticks;
                linear.items[first].metric_generation = iteration;
                linear.items[first].measured = true;
                break :block try ix.height(&storage, root, first, ticks, iteration);
            },
            else => block: {
                const rows = [_]ix.Row{.{ .id = 10000 + iteration, .epoch = 1, .bytes = 3, .ticks = 9, .terminated = true, .hidden = iteration % 3 == 0 }};
                const removed = @min(end - first, 3);
                const value = try ix.splice(&storage, root, first, removed, &rows);
                try linear.replaceRange(testing.allocator, first, removed, &rows);
                break :block value;
            },
        };
        ix.release(&storage, root);
        root = candidate;
        try visibilityOracle(&storage, root, linear.items);
    }
    try visibilityOracle(&storage, initial, original);
}
fn visibilityAllocations(allocator: std.mem.Allocator) !void {
    var storage: ix.Storage = .{ .allocator = allocator, .node_limit = 10000 };
    var rows: [1024]ix.Row = undefined;
    for (&rows, 0..) |*row, at| row.* = .{ .id = at + 1, .epoch = 1, .bytes = 2, .ticks = 10, .terminated = true };
    const root = (try ix.build(&storage, &rows)).?;
    defer ix.release(&storage, root);
    const hidden = try ix.setHidden(&storage, root, 0, rows.len, true);
    defer ix.release(&storage, hidden);
    const shown = try ix.setHidden(&storage, hidden, 127, 903, false);
    defer ix.release(&storage, shown);
    const changed = try ix.height(&storage, shown, 250, 25, 2);
    defer ix.release(&storage, changed);
    const replaced = try ix.splice(&storage, changed, 10, 50, rows[0..2]);
    defer ix.release(&storage, replaced);
    try testing.expectEqual(@as(usize, rows.len), root.sum.visible_rows);
}
test "lazy visibility candidates clean up every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, visibilityAllocations, .{});
}
test "a huge hidden body uses bounded tree paths and retains raw measured heights" {
    var storage: ix.Storage = .{ .allocator = testing.allocator, .node_limit = 100000 };
    const rows = try testing.allocator.alloc(ix.Row, 100000);
    defer testing.allocator.free(rows);
    for (rows, 0..) |*row, at| row.* = .{ .id = at + 1, .epoch = 1, .bytes = 2, .ticks = 10, .terminated = true };
    const root = (try ix.build(&storage, rows)).?;
    defer ix.release(&storage, root);
    storage.visited = 0;
    storage.scanned = 0;
    const hidden = try ix.setHidden(&storage, root, 1, rows.len - 1, true);
    defer ix.release(&storage, hidden);
    try testing.expect(storage.visited < 100 and storage.scanned < 2048);
    try testing.expectEqual(@as(u128, 20), hidden.sum.ticks);
    try testing.expectEqual(@as(u128, 1000000), hidden.sum.raw_ticks);
    storage.visited = 0;
    storage.scanned = 0;
    try testing.expectEqual(@as(?usize, 99999), ix.nextVisible(&storage, hidden, 1));
    try testing.expectEqual(@as(usize, 99999), ix.atTick(&storage, hidden, 10));
    try testing.expect(storage.visited < 100 and storage.scanned < 128);
}

const f = @import("folds.zig");
fn foldOracle(storage: *ix.Storage, root: *ix.Node, definitions: []const f.Fold) !void {
    for (0..root.sum.rows) |row| {
        const byte = ix.prefix(storage, root, row).bytes;
        var hidden = false;
        for (definitions) |fold| {
            const header_row = ix.lineAt(storage, root, fold.header);
            if (fold.collapsed and row > header_row and byte < fold.end) hidden = true;
        }
        try testing.expectEqual(hidden, ix.get(storage, root, row).hidden);
    }
}
test "nested fold toggles preserve child states and effective interval differences" {
    var storage: ix.Storage = .{ .allocator = testing.allocator, .node_limit = 10000 };
    var rows: [128]ix.Row = undefined;
    for (&rows, 0..) |*row, at| row.* = .{ .id = at + 1, .epoch = 1, .bytes = 2, .ticks = 10, .terminated = true };
    var root = (try ix.build(&storage, &rows)).?;
    defer ix.release(&storage, root);
    var definitions = [_]f.Fold{ .{ .id = 1, .header = 0, .end = 200 }, .{ .id = 2, .header = 10, .end = 100 }, .{ .id = 3, .header = 20, .end = 80 }, .{ .id = 4, .header = 120, .end = 180 }, .{ .id = 5, .header = 220, .end = 250 } };
    var set = try f.create(testing.allocator, &storage, root, &definitions, 100);
    defer f.release(set);
    var source = std.Random.DefaultPrng.init(0x831b72);
    const random = source.random();
    for (0..700) |_| {
        const at = random.uintLessThan(usize, definitions.len);
        definitions[at].collapsed = !definitions[at].collapsed;
        const next = try f.changed(testing.allocator, &storage, root, set, definitions[at].id, definitions[at].collapsed, &.{.{ .anchor = 0, .caret = 0 }}, 100);
        const candidate = try f.apply(&storage, root, set, next);
        ix.release(&storage, root);
        root = candidate;
        f.release(set);
        set = next;
        try foldOracle(&storage, root, &definitions);
    }
    const old = root;
    root = ix.retain(old).?;
    ix.release(&storage, old);
    try testing.expectError(error.CaretInsideFold, f.changed(testing.allocator, &storage, root, set, 1, true, &.{.{ .anchor = 30, .caret = 30 }}, 100));
    const expanded = try f.expanded(testing.allocator, &storage, root, set, 30, 100);
    defer f.release(expanded);
    var at = expanded.?.containing(30);
    while (at) |index| {
        try testing.expect(!expanded.?.entries[index].fold.collapsed);
        at = expanded.?.entries[index].parent;
    }
}
fn foldAllocations(allocator: std.mem.Allocator) !void {
    var storage: ix.Storage = .{ .allocator = allocator, .node_limit = 10000 };
    var rows: [256]ix.Row = undefined;
    for (&rows, 0..) |*row, at| row.* = .{ .id = at + 1, .epoch = 1, .bytes = 2, .ticks = 10, .terminated = true };
    const root = (try ix.build(&storage, &rows)).?;
    defer ix.release(&storage, root);
    const set = try f.create(allocator, &storage, root, &.{ .{ .id = 1, .header = 0, .end = 400, .collapsed = true }, .{ .id = 2, .header = 10, .end = 100, .collapsed = true } }, 10);
    defer f.release(set);
    const hidden = try f.apply(&storage, root, null, set);
    defer ix.release(&storage, hidden);
    const expanded = try f.expanded(allocator, &storage, hidden, set, 30, 10);
    defer f.release(expanded);
    const shown = try f.apply(&storage, hidden, set, expanded);
    defer ix.release(&storage, shown);
    const plan = try ix.plan(&storage, shown, .{ .start = 22, .end = 24 }, "a\nb\n", 1000, 2, 10, 1000);
    defer ix.release(&storage, plan.root);
    const mapped = try f.mapped(allocator, &storage, root, plan.root, set, &.{.{ .range = .{ .start = 22, .end = 24 }, .text = "a\nb\n" }}, 10);
    defer f.release(mapped);
    const merged = try f.merge(allocator, &storage, root, set, expanded, 10);
    defer f.release(merged);
}
test "fold validation and all candidate allocation failures are transactional" {
    try testing.checkAllAllocationFailures(testing.allocator, foldAllocations, .{});
    var storage: ix.Storage = .{ .allocator = testing.allocator, .node_limit = 1000 };
    var rows: [10]ix.Row = undefined;
    for (&rows, 0..) |*row, at| row.* = .{ .id = at + 1, .epoch = 1, .bytes = 2, .ticks = 10, .terminated = true };
    const root = (try ix.build(&storage, &rows)).?;
    defer ix.release(&storage, root);
    try testing.expectError(error.InvalidFoldBoundary, f.create(testing.allocator, &storage, root, &.{.{ .id = 1, .header = 1, .end = 10 }}, 10));
    try testing.expectError(error.EmptyFold, f.create(testing.allocator, &storage, root, &.{.{ .id = 1, .header = 0, .end = 2 }}, 10));
    try testing.expectError(error.CrossingFolds, f.create(testing.allocator, &storage, root, &.{ .{ .id = 1, .header = 0, .end = 10 }, .{ .id = 2, .header = 6, .end = 16 } }, 10));
    try testing.expectError(error.DuplicateFoldId, f.create(testing.allocator, &storage, root, &.{ .{ .id = 1, .header = 0, .end = 10 }, .{ .id = 1, .header = 12, .end = 18 } }, 10));
}

const PlainFold = struct { id: u64, header: usize, end: usize, collapsed: bool };
fn verifyPlainFolds(storage: *ix.Storage, root: *ix.Node, plain: []const PlainFold, set: ?*const f.Set) !void {
    try testing.expectEqual(plain.len, f.count(set));
    for (plain) |item| {
        const index = set.?.find(item.id).?;
        const actual = set.?.entries[index];
        try testing.expectEqual(item.header * 2, actual.fold.header);
        try testing.expectEqual(item.end * 2, actual.fold.end);
        try testing.expectEqual(item.collapsed, actual.fold.collapsed);
    }
    for (0..root.sum.rows) |line| {
        var hidden = false;
        for (plain) |item| if (item.collapsed and line > item.header and line < item.end) {
            hidden = true;
        };
        try testing.expectEqual(hidden, ix.get(storage, root, line).hidden);
    }
}
test "fold edit and undo coordinates agree with an independent paragraph array oracle" {
    var storage: ix.Storage = .{ .allocator = testing.allocator, .node_limit = 100000 };
    var rows: [128]ix.Row = undefined;
    for (&rows, 0..) |*row, at| row.* = .{ .id = at + 1, .epoch = 1, .bytes = 2, .ticks = 10, .terminated = true };
    var root = (try ix.build(&storage, &rows)).?;
    defer ix.release(&storage, root);
    const initial = [_]PlainFold{ .{ .id = 1, .header = 0, .end = 110, .collapsed = false }, .{ .id = 2, .header = 10, .end = 90, .collapsed = true }, .{ .id = 3, .header = 20, .end = 70, .collapsed = true }, .{ .id = 4, .header = 112, .end = 125, .collapsed = false } };
    var plain: std.ArrayList(PlainFold) = .empty;
    defer plain.deinit(testing.allocator);
    try plain.appendSlice(testing.allocator, &initial);
    var definitions: [initial.len]f.Fold = undefined;
    for (&definitions, initial) |*item, before| item.* = .{ .id = before.id, .header = before.header * 2, .end = before.end * 2, .collapsed = before.collapsed };
    var set = try f.create(testing.allocator, &storage, root, &definitions, 20);
    defer f.release(set);
    const hidden = try f.apply(&storage, root, null, set);
    ix.release(&storage, root);
    root = hidden;
    const Version = struct { root: *ix.Node, set: ?*f.Set, plain: []PlainFold };
    var history: std.ArrayList(Version) = .empty;
    defer {
        for (history.items) |version| {
            ix.release(&storage, version.root);
            f.release(version.set);
            testing.allocator.free(version.plain);
        }
        history.deinit(testing.allocator);
    }
    var source = std.Random.DefaultPrng.init(0xf02d167);
    const random = source.random();
    var next_id: u64 = 1000;
    for (0..450) |iteration| {
        if (iteration % 3 == 0 and plain.items.len != 0) {
            const at = random.uintLessThan(usize, plain.items.len);
            plain.items[at].collapsed = !plain.items[at].collapsed;
            const changed_set = try f.changed(testing.allocator, &storage, root, set, plain.items[at].id, plain.items[at].collapsed, &.{}, 20);
            const changed_root = try f.apply(&storage, root, set, changed_set);
            f.release(set);
            set = changed_set;
            ix.release(&storage, root);
            root = changed_root;
        } else if (iteration % 7 == 0 and history.items.len != 0) {
            const version = history.pop().?;
            defer testing.allocator.free(version.plain);
            const merged = try f.merge(testing.allocator, &storage, version.root, version.set, set, 20);
            errdefer f.release(merged);
            const candidate = try f.apply(&storage, version.root, version.set, merged);
            for (version.plain) |*old| for (plain.items) |current| if (old.id == current.id) {
                old.collapsed = current.collapsed;
            };
            try plain.resize(testing.allocator, version.plain.len);
            @memcpy(plain.items, version.plain);
            ix.release(&storage, root);
            root = candidate;
            f.release(set);
            set = merged;
            ix.release(&storage, version.root);
            f.release(version.set);
        } else {
            const before = try testing.allocator.dupe(PlainFold, plain.items);
            errdefer testing.allocator.free(before);
            try history.append(testing.allocator, .{ .root = ix.retain(root).?, .set = f.retain(set), .plain = before });
            const first = 1 + random.uintLessThan(usize, root.sum.rows - 2);
            const end = @min(root.sum.rows - 1, first + random.uintLessThan(usize, 3));
            const inserted = random.uintLessThan(usize, 4);
            const text = (&@as([3 * "x\n".len]u8, @bitCast(@as([3]["x\n".len]u8, @splat("x\n".*)))))[0 .. inserted * 2];
            const edit: d.Replacement = .{ .range = .{ .start = first * 2, .end = end * 2 }, .text = text };
            const plan = try ix.plan(&storage, root, edit.range, text, next_id, iteration + 2, 10, 1000);
            next_id = plan.next_id;
            defer ix.release(&storage, plan.root);
            const next_set = try f.mapped(testing.allocator, &storage, root, plan.root, set, &.{edit}, 20);
            const visible = try ix.setHidden(&storage, plan.root, 0, plan.root.sum.rows, false);
            defer ix.release(&storage, visible);
            const candidate = try f.apply(&storage, visible, null, next_set);
            var out: usize = 0;
            for (plain.items) |item| {
                if ((item.header >= first and item.header < end) or item.header == first) continue;
                var changed = item;
                if (changed.header >= end) changed.header = changed.header - (end - first) + inserted;
                if (changed.end >= first and changed.end <= end) changed.end = first else if (changed.end > end) changed.end = changed.end - (end - first) + inserted;
                if (changed.end <= changed.header + 1) continue;
                plain.items[out] = changed;
                out += 1;
            }
            plain.shrinkRetainingCapacity(out);
            ix.release(&storage, root);
            root = candidate;
            f.release(set);
            set = next_set;
        }
        try verifyPlainFolds(&storage, root, plain.items, set);
    }
}

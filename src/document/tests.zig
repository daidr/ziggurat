const std = @import("std");
const d = @import("root.zig");
const tree = @import("tree.zig");
const z = @import("ziggurat");
const testing = std.testing;

fn expectText(document: anytype, expected: []const u8) !void {
    var bytes: [65536]u8 = undefined;
    const length = try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes);
    try testing.expectEqualStrings(expected, bytes[0..length]);
}
fn validateNode(node: *tree.Node) !tree.Counts {
    try testing.expect(node.refs > 0 and node.height <= tree.max_depth);
    switch (node.value) {
        .leaf => |bytes| {
            try testing.expect(bytes.len > 0 and bytes.len <= tree.leaf_bytes);
            var counts: tree.Counts = .{ .bytes = bytes.len };
            var iterator = (try std.unicode.Utf8View.init(bytes)).iterator();
            while (iterator.nextCodepoint()) |cp| {
                counts.scalars += 1;
                counts.utf16 += if (cp > 0xffff) @as(usize, 2) else 1;
                counts.lf += @intFromBool(cp == '\n');
            }
            try testing.expectEqual(@as(u8, 1), node.height);
            try testing.expectEqualDeep(counts, node.counts);
            return counts;
        },
        .branch => |branch| {
            const left = try validateNode(branch.left);
            const right = try validateNode(branch.right);
            try testing.expect(@abs(@as(i32, branch.left.height) - @as(i32, branch.right.height)) <= 1);
            try testing.expectEqual(@max(branch.left.height, branch.right.height) + 1, node.height);
            const counts: tree.Counts = .{ .bytes = left.bytes + right.bytes, .scalars = left.scalars + right.scalars, .utf16 = left.utf16 + right.utf16, .lf = left.lf + right.lf };
            try testing.expectEqualDeep(counts, node.counts);
            return counts;
        },
    }
}
fn oracle(document: anytype, bytes: []const u8) !void {
    try expectText(document, bytes);
    var lines: usize = 0;
    var scalars: usize = 0;
    var units: usize = 0;
    var line_start: usize = 0;
    var iterator = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (iterator.nextCodepointSlice()) |scalar| {
        const at = iterator.i - scalar.len;
        try testing.expectEqual(units, try document.utf16Offset(at));
        try testing.expectEqual(at, try document.byteOffsetFromUtf16(units));
        try testing.expectEqual(lines, try document.lineAt(at));
        const cp = try std.unicode.utf8Decode(scalar);
        if (cp > 0xffff) try testing.expectError(error.InvalidBoundary, document.byteOffsetFromUtf16(units + 1));
        for (1..scalar.len) |extra| try testing.expectError(error.InvalidBoundary, document.utf16Offset(at + extra));
        units += if (cp > 0xffff) @as(usize, 2) else 1;
        scalars += 1;
        if (cp == '\n') {
            try testing.expectEqual(d.Range{ .start = line_start, .end = at }, try document.line(lines));
            line_start = iterator.i;
            lines += 1;
        }
    }
    try testing.expectEqual(d.Range{ .start = line_start, .end = bytes.len }, try document.line(lines));
    try testing.expectEqual(units, try document.utf16Length());
    try testing.expectEqual(scalars, try document.scalarLength());
    try testing.expectEqual(lines + 1, try document.lineCount());
    try testing.expectEqual(units, try document.utf16Offset(bytes.len));
    try testing.expectEqual(bytes.len, try document.byteOffsetFromUtf16(units));
    try testing.expectError(error.InvalidRange, document.line(lines + 1));
    try testing.expectError(error.InvalidRange, document.byteOffsetFromUtf16(units + 1));
}

test "strict byte UTF16 scalar and LF coordinates preserve CRLF and terminal empty lines" {
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "a😀\r\n中e\u{301}\n", .{});
    defer document.close() catch unreachable;
    try oracle(document, "a😀\r\n中e\u{301}\n");
    try testing.expectError(error.InvalidBoundary, document.replace(.{ .start = 2, .end = 4 }, "x"));
    try testing.expectError(error.InvalidUtf8, document.replace(.{ .start = 0, .end = 1 }, "\xff"));
    try testing.expectError(error.InvalidRange, document.replace(.{ .start = 5, .end = 1 }, ""));
    var storage: [1]u8 = .{0xaa};
    try testing.expectError(error.CapacityExceeded, document.read(.{ .start = 1, .end = 5 }, &storage));
    try testing.expectEqual(@as(u8, 0xaa), storage[0]);
    const empty = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "", .{});
    defer empty.close() catch unreachable;
    try oracle(empty, "");
}

test "persistent AVL random edits match linear UTF and line oracle and retained versions" {
    var random_source = std.Random.DefaultPrng.init(0xb1616);
    const random = random_source.random();
    var linear: std.ArrayList(u8) = .empty;
    defer linear.deinit(testing.allocator);
    // Begin across several chunks; random deletions and both-end insertions
    // exercise joins, rotations and scalar boundaries rather than tiny leaves.
    try linear.appendNTimes(testing.allocator, 'x', 12000);
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), linear.items, .{ .history_entries = 5 });
    defer document.close() catch unreachable;
    const originals = try document.snapshot();
    defer originals.close() catch unreachable;
    const inserts = [_][]const u8{ "", "x", "😀", "中\r\n", "e\u{301}", "\n", "abc", "👩‍👩‍👧‍👦" };
    for (0..1600) |step| {
        var start = if (step % 7 == 0) 0 else if (step % 7 == 1) linear.items.len else random.uintLessThan(usize, linear.items.len + 1);
        while (start < linear.items.len and linear.items[start] & 0xc0 == 0x80) start += 1;
        var end = @min(linear.items.len, start + random.uintLessThan(usize, 36));
        while (end < linear.items.len and linear.items[end] & 0xc0 == 0x80) end += 1;
        const inserted = inserts[random.uintLessThan(usize, inserts.len)];
        try document.replace(.{ .start = start, .end = end }, inserted);
        try linear.replaceRange(testing.allocator, start, end - start, inserted);
        if (step % 37 == 0) try oracle(document, linear.items);
    }
    try oracle(document, linear.items);
    try testing.expectEqual(@as(usize, 12000), try originals.byteLength());
    var initial: [12000]u8 = undefined;
    _ = try originals.read(.{ .start = 0, .end = initial.len }, &initial);
    for (initial) |byte| try testing.expectEqual(@as(u8, 'x'), byte);
    try testing.expect((try document.stats()).height < 32);
}

test "tree structure and aggregate checks survive random boundary sharing" {
    var memory: tree.Memory = .{ .allocator = testing.allocator, .limits = .{ .live_bytes = 4 * 1024 * 1024, .candidate_bytes = 1024 * 1024, .nodes = 10000 } };
    var initial: [24000]u8 = undefined;
    @memset(&initial, 'x');
    @memcpy(initial[4093..4097], "😀");
    var root = try tree.build(&memory, &initial);
    defer tree.release(&memory, root);
    var random_source = std.Random.DefaultPrng.init(81);
    const random = random_source.random();
    for (0..2500) |_| {
        var at = random.uintLessThan(usize, tree.counts(root).bytes + 1);
        while (at < tree.counts(root).bytes and tree.byteAt(&memory, root.?, at) & 0xc0 == 0x80) at += 1;
        const halves = try tree.split(&memory, root, at);
        defer tree.release(&memory, halves.left);
        defer tree.release(&memory, halves.right);
        const joined = try tree.concat(&memory, halves.left, halves.right);
        tree.release(&memory, root);
        root = joined;
        _ = try validateNode(root.?);
    }
    tree.release(&memory, root);
    root = null;
    try testing.expectEqual(@as(usize, 0), memory.stats.live_bytes);
    try testing.expectEqual(@as(usize, 0), memory.stats.live_nodes);
}

test "snapshot coordinate queries and streaming writers do not flatten or allocate" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const text = "a😀\r\n中\n";
    const document = try d.Document.create(failing.allocator(), std.Thread.getCurrentId(), text, .{});
    const saved = try document.snapshot();
    defer saved.close() catch unreachable;
    failing.fail_index = failing.alloc_index;
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try document.writeTo(&writer);
    try testing.expectEqualStrings(text, writer.buffered());
    try document.close();
    try oracle(saved, text);
    writer = std.Io.Writer.fixed(&storage);
    try saved.writeTo(&writer);
    try testing.expectEqualStrings(text, writer.buffered());
    var small: [2]u8 = undefined;
    var short = std.Io.Writer.fixed(&small);
    try testing.expectError(error.WriteFailed, saved.writeTo(&short));
    // Failed output ends its Busy scope; the immutable owner remains usable.
    try testing.expectEqual(@as(usize, text.len), try saved.byteLength());
}

test "chunk construction preserves a scalar crossing the midpoint and explicit native NUL errors" {
    var input = @as([8192]u8, @splat('x'));
    @memcpy(input[4095..4099], "😀");
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), &input, .{});
    defer document.close() catch unreachable;
    try testing.expectEqual(@as(usize, 4095), try document.byteOffsetFromUtf16(4095));
    try testing.expectError(error.InvalidBoundary, document.byteOffsetFromUtf16(4096));
    try testing.expectEqual(@as(usize, 4099), try document.byteOffsetFromUtf16(4097));
    try document.replace(.{ .start = 4095, .end = 4099 }, "中");
    try testing.expect(try document.undo());
    try expectText(document, &input);
    const nul = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "a\x00b", .{});
    defer nul.close() catch unreachable;
    var context: [16]u8 = undefined;
    try testing.expectError(error.EmbeddedNul, nul.nativeContext(&context));
    try expectText(nul, "a\x00b");
}

test "100k line tail query and edit walk logarithmic paths and copy bounded leaves" {
    const input = try testing.allocator.alloc(u8, 100000 * 10);
    defer testing.allocator.free(input);
    for (0..100000) |i| @memcpy(input[i * 10 ..][0..10], "abc😀xy\n");
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), input, .{ .history_entries = 4 });
    defer document.close() catch unreachable;
    try testing.expectEqual(@as(usize, 100001), try document.lineCount());
    const before = try document.stats();
    const last = try document.line(99999);
    try testing.expectEqual(@as(usize, 999990), last.start);
    try testing.expectEqual(@as(usize, 999999), last.end);
    try testing.expectEqual(@as(usize, 799992), try document.utf16Offset(last.start));
    try testing.expectEqual(last.start, try document.byteOffsetFromUtf16(799992));
    var context: [128]u8 = undefined;
    _ = try document.setSelection(.{ .anchor = last.start + 3, .caret = last.start + 7 });
    const value = try document.nativeContext(&context);
    try z.text.validate(value, &context);
    try document.replace(.{ .start = last.start + 3, .end = last.start + 7 }, "文");
    const after = try document.stats();
    try testing.expect(after.visited_nodes - before.visited_nodes < 512);
    try testing.expect(after.copied_bytes - before.copied_bytes < 32768);
    try testing.expect(after.candidate_peak_bytes < 65536);
    try testing.expect(after.height < 32);
}

test "history ring branches transactionally and snapshots outlive document" {
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "A", .{ .history_entries = 2, .snapshots = 2 });
    const saved = try document.snapshot();
    errdefer saved.close() catch unreachable;
    const cloned = try saved.clone();
    defer cloned.close() catch unreachable;
    try testing.expectError(error.CapacityExceeded, saved.clone());
    try document.replace(.{ .start = 0, .end = 1 }, "B");
    try document.replace(.{ .start = 0, .end = 1 }, "C");
    try document.replace(.{ .start = 0, .end = 1 }, "D");
    try testing.expect(try document.undo());
    try expectText(document, "C");
    try testing.expect(try document.undo());
    try expectText(document, "B");
    try testing.expect(!try document.undo());
    try document.replace(.{ .start = 0, .end = 1 }, "E");
    try testing.expect(!try document.canRedo());
    try document.restore(saved);
    try expectText(document, "A");
    try testing.expect(try document.undo());
    try expectText(document, "E");
    try document.close();
    try expectText(saved, "A");
    try saved.close();
    try expectText(cloned, "A");
    try testing.expectEqual(@as(usize, 1), try cloned.scalarLength());
    try testing.expectEqual(@as(usize, 0), try cloned.lineAt(1));
}

test "composition is virtual, bounded and commits one undo version" {
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "a😀bc", .{ .document_bytes = 16, .composition_bytes = 8 });
    defer document.close() catch unreachable;
    _ = try document.setSelection(.{ .anchor = 5, .caret = 1 });
    try document.setComposition("中文", .{ .anchor = 0, .caret = 6 });
    try expectText(document, "a😀bc");
    try testing.expectError(error.CompositionActive, document.replaceSelection("x"));
    try testing.expectError(error.InvalidBoundary, document.setComposition("中", .{ .anchor = 1, .caret = 3 }));
    try testing.expectError(error.CapacityExceeded, document.setComposition("abcdefghi", .{}));
    try testing.expectEqualStrings("中文", (try document.composition()).?.text);
    try document.commitComposition(null);
    try expectText(document, "a中文bc");
    try testing.expect(try document.undo());
    try expectText(document, "a😀bc");
    try testing.expectEqual(d.Selection{ .anchor = 5, .caret = 1 }, try document.selection());
    try document.setComposition("文", .{ .anchor = 3, .caret = 3 });
    try testing.expect(try document.cancelComposition());
    try expectText(document, "a😀bc");
    try testing.expect(!try document.cancelComposition());
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    const input = @as([12000]u8, @splat('a'));
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), &input, .{ .history_entries = 3 });
    defer document.close() catch unreachable;
    const saved = try document.snapshot();
    defer saved.close() catch unreachable;
    try document.replace(.{ .start = 4090, .end = 4100 }, "😀\n中");
    try document.replace(.{ .start = 0, .end = 1 }, "x");
    try testing.expect(try document.undo());
    const before = try document.stats();
    const version = try document.version();
    const selected = try document.selection();
    const length = try document.byteLength();
    var old: [12032]u8 = undefined;
    _ = try document.read(.{ .start = 0, .end = length }, &old);
    document.replace(.{ .start = 8190, .end = 8200 }, "longer😀replacement") catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try expectText(document, old[0..length]);
        try testing.expectEqual(version, try document.version());
        try testing.expectEqual(selected, try document.selection());
        try testing.expect(try document.canRedo());
        try testing.expectEqual(before.owned_bytes, (try document.stats()).owned_bytes);
        try testing.expectEqual(before.nodes, (try document.stats()).nodes);
        return err;
    };
    try testing.expect(!try document.canRedo());
    try document.restore(saved);
    try expectText(document, &input);
    const second = try saved.clone();
    defer second.close() catch unreachable;
}
test "all allocation failures preserve document selection history and snapshot ownership" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}

test "document, live, node and candidate limits reject before publishing" {
    try testing.expectError(error.InvalidLimits, d.Document.create(testing.allocator, std.Thread.getCurrentId(), "", .{ .nodes = 0 }));
    try testing.expectError(error.CapacityExceeded, d.Document.create(testing.allocator, std.Thread.getCurrentId(), "a", .{ .live_bytes = 1, .candidate_bytes = 0 }));
    const documents = [_]*d.Document{
        try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "abc", .{ .document_bytes = 3 }),
        try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "abc", .{ .candidate_bytes = 0 }),
        try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "abc", .{ .nodes = 1 }),
    };
    for (documents) |document| {
        defer document.close() catch unreachable;
        const before = try document.stats();
        try testing.expectError(error.CapacityExceeded, document.replace(.{ .start = 1, .end = 1 }, "def"));
        try expectText(document, "abc");
        try testing.expectEqual(@as(u64, 0), try document.version());
        try testing.expectEqual(before.owned_bytes, (try document.stats()).owned_bytes);
    }
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "A", .{});
    defer document.close() catch unreachable;
    const other = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "B", .{});
    defer other.close() catch unreachable;
    const foreign = try other.snapshot();
    defer foreign.close() catch unreachable;
    try testing.expectError(error.ForeignSnapshot, document.restore(foreign));
    try expectText(document, "A");
}

test "document and immutable snapshots enforce their actual owner thread" {
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "x", .{});
    defer document.close() catch unreachable;
    const saved = try document.snapshot();
    defer saved.close() catch unreachable;
    const Host = struct {
        fn run(doc: *d.Document, snapshot: *d.Snapshot) void {
            testing.expectError(error.WrongThread, doc.byteLength()) catch unreachable;
            testing.expectError(error.WrongThread, doc.replace(.{ .start = 0, .end = 1 }, "a")) catch unreachable;
            testing.expectError(error.WrongThread, doc.close()) catch unreachable;
            testing.expectError(error.WrongThread, snapshot.clone()) catch unreachable;
            testing.expectError(error.WrongThread, snapshot.close()) catch unreachable;
            testing.expectError(error.WrongThread, d.Document.create(testing.allocator, std.Thread.getCurrentId() + 1, "", .{})) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Host.run, .{ document, saved });
    thread.join();
    try expectText(document, "x");
}

test "native binding owns document until revoke and commits against indexed coordinates" {
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "pre😀post", .{});
    defer document.close() catch unreachable;
    const app = try z.App.init(testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var binding = d.ClientBinding.init(document, std.Thread.getCurrentId());
    try binding.bind(window);
    defer binding.unbind() catch unreachable;
    try testing.expectError(error.ClientAttached, document.close());
    _ = try document.setSelection(.{ .anchor = 7, .caret = 3 });
    var context: [4]u8 = undefined;
    const value = try window.readTextClient(binding.token.?, &context);
    try testing.expectEqualStrings("😀", context[0..value.bytes]);
    try testing.expectEqual(z.text.Selection{ .anchor = 5, .caret = 3 }, value.selection);
    const revision = try document.version();
    try testing.expectError(error.InvalidBoundary, window.changeTextClient(binding.token.?, .{ .select = .{ .anchor = 4, .caret = 5 } }));
    try testing.expectEqual(revision, try document.version());
    _ = try window.changeTextClient(binding.token.?, .{ .replace = .{ .range = .{ .start = 3, .end = 5 }, .text = "文" } });
    try expectText(document, "pre文post");
    try testing.expect(try document.undo());
    try expectText(document, "pre😀post");
    try testing.expect(try binding.handleEvent(window, .{ .text_preedit = .{ .text = "中文", .selection_start = 0, .selection_end = 6 } }));
    try testing.expectError(error.CompositionActive, window.changeTextClient(binding.token.?, .{ .select = .{ .anchor = 3, .caret = 3 } }));
    try testing.expect(try binding.handleEvent(window, .{ .text_input = .{ .text = "中", .producer = .application } }));
    try expectText(document, "pre中post");
    try binding.unbind();
    try testing.expect(binding.token == null);
}

test "binding explicit layout failure preserves edit and callback close revokes once" {
    const document = try d.Document.create(testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const app = try z.App.init(testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var binding = d.ClientBinding.init(document, std.Thread.getCurrentId());
    const Host = struct {
        fn changed(_: *anyopaque, win: z.Window) !void {
            _ = try win.destroy();
            return error.LayoutRequired;
        }
    };
    binding.changed = .{ .context = document, .call = Host.changed };
    try binding.bind(window);
    try testing.expectError(error.LayoutRequired, window.changeTextClient(binding.token.?, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "x" } }));
    try testing.expect(window.isClosed());
    // isClosed includes deferred closure; the native safe point owns revoke.
    try testing.expectError(error.ClientAttached, document.close());
    try testing.expectError(error.UnbindPending, binding.unbind());
    try app.dispatch();
    try testing.expect(binding.token == null);
    try expectText(document, "xbc");
    try testing.expect(try document.undo());
    try expectText(document, "abc");
}

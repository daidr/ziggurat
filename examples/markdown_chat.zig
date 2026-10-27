//! A chat with a pretend language model whose replies stream in token by
//! token as Markdown. While a reply comes, it shows up to the last whole
//! word, sentence, line or paragraph, as the bar at the top chooses, or
//! nothing until it is done; the list follows the end until the user
//! scrolls up.
//!
//! The tokens arrive on the main thread at the uneven pace of a model,
//! from `View.wakeAt` deadlines that `ziggurat_view_timer` serves.
//!
//! Run it with `zig build run-markdown-chat`.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const text = @import("ziggurat_view_text");
const md = @import("ziggurat_markdown");
const mv = @import("ziggurat_markdown_view");

const Reveal = enum { word, sentence, line, paragraph, at_once };
const reveal_names = [_][]const u8{ "Word", "Sentence", "Line", "Paragraph", "At once" };

const Message = struct {
    mine: bool,
    /// The user's words, owned; or the reply's whole canned text.
    text: []const u8,
    /// Bytes of a reply streamed so far.
    shown: usize = 0,
    done: bool = false,
};

const muted: u32 = 0x5f6b7a;
const bubble: u32 = 0xeef1f5;
const border: u32 = 0xd5dbe3;

fn rule(v: *view.View) !void {
    try v.row(.{ .height = 1, .self_align = .stretch, .background = border });
    try v.end();
}

const Chat = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message) = .empty,
    reveal: Reveal = .word,
    replies: usize = 0,
    /// Replies stream only with a window; without one they come whole.
    streaming: bool = false,
    next_token: u64 = 0,
    random: std.Random.DefaultPrng,
    list: view.ScrollModel = .{},
    /// The list stays at the end until the user scrolls up.
    follow: bool = true,
    last_offset: f32 = 0,
    input: ?*text.TextField = null,
    /// The message being written, when there is no text field.
    draft: [512]u8 = undefined,
    draft_len: usize = 0,
    send_queued: bool = false,
    markdown: md.Storage(2048, 16 * 1024) = .{},

    fn init(allocator: std.mem.Allocator) Chat {
        return .{ .allocator = allocator, .random = .init(zio.random.int(u64)) };
    }
    fn deinit(self: *Chat) void {
        for (self.messages.items) |item| if (item.mine) self.allocator.free(item.text);
        self.messages.deinit(self.allocator);
    }

    fn replying(self: *const Chat) ?*Message {
        if (self.messages.items.len == 0) return null;
        const last = &self.messages.items[self.messages.items.len - 1];
        return if (last.mine or last.done) null else last;
    }

    fn build(self: *Chat, v: *view.View) anyerror!void {
        self.stream(v);
        try v.column(.{ .grow = 1, .self_align = .stretch });
        try v.row(.{ .gap = 8, .alignment = .center, .self_align = .stretch, .padding = .{ .top = 8, .bottom = 8, .left = 20, .right = 20 } });
        try v.text("Stream by", .{ .color = muted });
        try v.segmented(.{ .name = "Stream by" });
        inline for (reveal_names, 0..) |name, i| _ = try v.segment(Reveal, &self.reveal, @fromBackingInt(@intCast(i)), name, .{});
        try v.end();
        try v.end();
        try rule(v);

        try v.scroll(&self.list, .{ .grow = 1, .self_align = .stretch, .padding = .{ .top = 16, .bottom = 16, .left = 20, .right = 20 }, .gap = 16, .key = 1 });
        self.followEnd(v);
        if (self.messages.items.len == 0) {
            try v.spacer(.{});
            try v.text("Ask anything: the replies are canned, streamed as a model streams them.", .{ .color = muted, .self_align = .center });
            try v.spacer(.{});
        }
        for (self.messages.items, 0..) |*item, i| try self.message(v, item, i);
        try v.end();
        try rule(v);

        try v.row(.{ .gap = 8, .alignment = .center, .self_align = .stretch, .padding = .{ .top = 12, .bottom = 12, .left = 20, .right = 20 } });
        if (self.input) |input| try v.embed(input.embed(), .{ .grow = 1, .key = 2 }) else try v.spacer(.{});
        if (self.replying()) |reply| {
            if (try v.button("Stop", .{ .key = 3 })) reply.done = true;
        } else if (try v.button("Send", .{ .key = 4, .enabled = std.mem.trim(u8, self.draftText(), " \t\r\n").len > 0 })) self.requestSend();
        try v.end();
        try v.end();
    }

    /// Advances the reply by a token whose time has come.
    fn stream(self: *Chat, v: *view.View) void {
        const reply = self.replying() orelse return;
        const now = v.time();
        if (now >= self.next_token) {
            // Tokens of a few bytes, whole characters.
            var n = @min(reply.text.len - reply.shown, 2 + self.random.random().uintLessThan(usize, 7));
            while (n < reply.text.len - reply.shown and reply.text[reply.shown + n] & 0xc0 == 0x80) n += 1;
            reply.shown += n;
            if (reply.shown == reply.text.len) reply.done = true;
            self.next_token = now + (8 + self.random.random().uintLessThan(u64, 30)) * std.time.ns_per_ms;
        }
        if (!reply.done) v.wakeAt(self.next_token);
    }

    /// Keeps the list at its end while it grows, unless the user scrolled
    /// up; scrolling back down to the end follows it again.
    fn followEnd(self: *Chat, v: *view.View) void {
        const end = self.list.maxOffset().y;
        if (self.list.offset.y + 0.5 < self.last_offset) self.follow = false;
        if (self.list.offset.y >= end - 2) self.follow = true;
        if (self.follow and self.list.offset.y < end) _ = self.list.setOffset(.{ .x = 0, .y = end }) catch {};
        self.last_offset = self.list.offset.y;
        // The content grows after this pass arranges; one more pass catches
        // up with the end.
        if (self.follow and self.replying() != null) v.wakeAt(v.time());
    }

    /// The user's words in a bubble on the right, the model's as Markdown.
    fn message(self: *Chat, v: *view.View, m: *const Message, i: usize) !void {
        if (m.mine) {
            try v.row(.{ .self_align = .stretch, .key = 100 + i });
            try v.spacer(.{});
            try v.row(.{ .padding = .{ .top = 8, .bottom = 8, .left = 12, .right = 12 }, .radius = 14, .background = bubble, .max_width = 520, .shrink = 0 });
            // The view measures text by estimate; room to spare keeps short
            // words from being cut.
            const estimate = (view.Measurer{}).textSize(m.text, null).width;
            try v.text(m.text, .{ .min_width = @min(496, estimate * 1.25) });
            try v.end();
            try v.end();
            return;
        }
        const source = revealed(m.text[0..m.shown], if (m.done) null else self.reveal);
        if (source.len == 0) {
            try v.text("…", .{ .color = muted, .key = 100 + i });
            return;
        }
        const tree = md.parse(source, self.markdown.buffers()) catch |err| {
            try v.text(@errorName(err), .{ .color = muted, .key = 100 + i });
            return;
        };
        if (try mv.build(v, tree, .{ .width = 720 }, .{ .key = 100 + i, .max_width = 760 })) |activation| switch (activation) {
            .link => |url| std.log.info("link: {s}", .{url}),
            .task => {},
        };
    }

    fn draftText(self: *Chat) []const u8 {
        return self.draft[0..self.draft_len];
    }

    /// Send and Enter run inside input handling, so sending is posted.
    fn requestSend(self: *Chat) void {
        const input = self.input orelse return self.send();
        if (self.send_queued) return;
        const window = input.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = sendFromInput }) catch return;
        self.send_queued = true;
    }

    fn sendFromInput(ptr: *anyopaque) void {
        const self: *Chat = @ptrCast(@alignCast(ptr));
        self.send_queued = false;
        if (self.replying() != null) return;
        self.send();
        if (self.input) |input| {
            _ = input.field.setValue("") catch {};
            if (input.host.context.window) |window| window.invalidate();
        }
    }

    /// Sends the draft, and streams the next reply in.
    fn send(self: *Chat) void {
        const words = std.mem.trim(u8, self.draftText(), " \t\r\n");
        if (words.len == 0) return;
        const owned = self.allocator.dupe(u8, words) catch return;
        self.messages.ensureUnusedCapacity(self.allocator, 2) catch {
            self.allocator.free(owned);
            return;
        };
        self.messages.appendAssumeCapacity(.{ .mine = true, .text = owned, .done = true });
        const source = replies[self.replies % replies.len];
        self.replies += 1;
        self.messages.appendAssumeCapacity(if (self.streaming) .{ .mine = false, .text = source } else .{ .mine = false, .text = source, .shown = source.len, .done = true });
        self.draft_len = 0;
        self.next_token = 0;
        self.follow = true;
    }

    /// The draft follows the field as the user types.
    fn changed(ptr: ?*anyopaque, _: z.Window, _: u64) void {
        const self: *Chat = @ptrCast(@alignCast(ptr.?));
        const input = self.input orelse return;
        const document = input.field.document;
        const length = document.byteLength() catch return;
        var end = document.read(.{ .start = 0, .end = @min(length, self.draft.len) }, &self.draft) catch return;
        while (end > 0 and end < length and self.draft[end] & 0xc0 == 0x80) end -= 1;
        self.draft_len = end;
    }

    fn submitted(ptr: ?*anyopaque, _: z.Window) void {
        const self: *Chat = @ptrCast(@alignCast(ptr.?));
        if (self.replying() == null) self.requestSend();
    }
};

/// The part of a streaming reply to show: up to the end of the last whole
/// unit, or all of a finished reply (`unit` null).
fn revealed(source: []const u8, unit: ?Reveal) []const u8 {
    const by = unit orelse return source;
    var end: usize = 0;
    switch (by) {
        .at_once => {},
        .word => {
            if (std.mem.lastIndexOfAny(u8, source, " \t\n")) |at| end = at + 1;
        },
        .sentence => {
            var i: usize = source.len;
            while (i > 0) : (i -= 1) {
                const c = source[i - 1];
                if (c == '\n' or ((c == '.' or c == '!' or c == '?' or c == ':') and i < source.len and (source[i] == ' ' or source[i] == '\n'))) {
                    end = i;
                    break;
                }
            }
        },
        .line => {
            if (std.mem.lastIndexOfScalar(u8, source, '\n')) |at| end = at + 1;
        },
        .paragraph => {
            if (std.mem.lastIndexOf(u8, source, "\n\n")) |at| end = at + 2;
        },
    }
    return source[0..end];
}

const replies = [_][]const u8{
    "Here is a minimal **LRU cache** in Zig, for one thread:\n\n" ++
        "```zig\nfn Lru(comptime V: type) type {\n    return struct {\n        map: std.StringHashMapUnmanaged(*Node) = .empty,\n        order: std.DoublyLinkedList = .{},\n        capacity: usize,\n\n" ++
        "        pub fn get(self: *@This(), key: []const u8) ?V {\n            const node = self.map.get(key) orelse return null;\n            self.order.remove(&node.link);\n            self.order.prepend(&node.link);\n            return node.value;\n        }\n    };\n}\n```\n\n" ++
        "A few things to note:\n\n1. The intrusive `DoublyLinkedList` keeps the order of use in O(1).\n2. `get` moves the entry, so it is a writer too: guard it with a `zio.Mutex` to share the cache.\n3. For heavy read traffic, consider **sharding** by key hash.\n",
    "## Comparing the options\n\n| Strategy | Read latency | Staleness | Complexity |\n|---|--:|:-:|---|\n| No cache | ~41 ms | none | trivial |\n| Cache-aside | ~0.2 ms | medium | low |\n| Write-through | ~0.2 ms | low | medium |\n\n" ++
        "> **Tip:** start with *cache-aside*; move to write-through once staleness bites.\n\nSee the [Zig language reference](https://ziglang.org/documentation/master/) before you profile what to cache first.",
    "Sure. The area of a circle is $$A = \\pi r^2$$ and its circumference $$C = 2\\pi r$$.\n\n" ++
        "- [x] Measure the radius\n- [x] Square it\n- [ ] Multiply by π\n\nThat's all there is to it~ unless you need ~~approximations~~ the exact value, which `std.math.pi` gives to 15 digits.",
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var chat: Chat = .init(allocator);
    defer chat.deinit();
    chat.streaming = true;
    var storage: view.Storage(4096, 64 * 1024) = .{};
    var host = view.Host.init(&chat, Chat.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0) } });
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch {};
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "", .{});
    defer document.close() catch {};

    const window = try app.createWindow(.{ .title = "Markdown chat", .width = 820, .height = 720, .min_width = 480, .min_height = 360 });
    try host.attach(window);
    try host.context.prepareTextFields(allocator, .{});
    try timer.attach(app, allocator);

    const field = try editing.Field.create(allocator, document, engine, .{ .value_bytes = chat.draft.len, .context = &chat, .changed = Chat.changed, .submit = Chat.submitted });
    var input = text.TextField.init(field, &host, .{ .font = .{ .size = 15 }, .scale = (try window.contentSize()).scale }, .{ .name = "Message" });
    chat.input = &input;

    window.show();
    try app.run();
    chat.input = null;
    input.detach();
    try field.close();
    try timer.close();
}

test "a message and its reply" {
    var chat: Chat = .init(std.testing.allocator);
    defer chat.deinit();
    var storage: view.Storage(4096, 64 * 1024) = .{};
    var h = view.Harness.init(&chat, Chat.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 820, .height = 720 } });
    try h.render();
    _ = try h.find(.{ .text = "Ask anything: the replies are canned, streamed as a model streams them." });
    const words = "How do I cache?";
    @memcpy(chat.draft[0..words.len], words);
    chat.draft_len = words.len;
    try h.render();
    try h.click(.{ .text = "Send" });
    try h.render();
    _ = try h.find(.{ .text = words });
    // Without a window, the reply comes whole.
    _ = try h.find(.{ .text = "A few things to note:" });
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Stop" }));
}

test "a streaming reply shows whole units" {
    const source = "One two. Three\nfour five\n\nSix";
    try std.testing.expectEqualStrings("One two. Three\nfour five\n\n", revealed(source, .word));
    try std.testing.expectEqualStrings("One two. Three\nfour five\n\n", revealed(source, .line));
    try std.testing.expectEqualStrings("One two. Three\nfour five\n\n", revealed(source, .paragraph));
    try std.testing.expectEqualStrings("One ", revealed(source[0..6], .word));
    try std.testing.expectEqualStrings("One two.", revealed(source[0..12], .sentence));
    try std.testing.expectEqualStrings("", revealed(source[0..12], .line));
    try std.testing.expectEqualStrings("", revealed(source, .at_once));
    try std.testing.expectEqualStrings(source, revealed(source, null));
}

test "replies stream token by token and stop" {
    var chat: Chat = .init(std.testing.allocator);
    defer chat.deinit();
    chat.streaming = true;
    var storage: view.Storage(4096, 64 * 1024) = .{};
    var h = view.Harness.init(&chat, Chat.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 820, .height = 720 } });
    @memcpy(chat.draft[0..2], "Hi");
    chat.draft_len = 2;
    try h.render();
    try h.click(.{ .text = "Send" });
    const reply = &chat.messages.items[1];
    var passes: usize = 0;
    while (!reply.done and passes < 10) : (passes += 1) try h.advance(50 * std.time.ns_per_ms);
    try std.testing.expect(reply.shown > 0 and !reply.done);
    try h.click(.{ .text = "Stop" });
    try std.testing.expect(reply.done);
    const shown = reply.shown;
    try h.advance(std.time.ns_per_s);
    try std.testing.expectEqual(shown, reply.shown);
}

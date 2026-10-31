//! Hybrid window: a native sidebar drawn with `ziggurat_ui` beside a system
//! WebView page in its own rectangular region. Both sides share one count
//! that lives in Zig. The sidebar's buttons change it and post the new
//! value to the page; the page's buttons post requests that Zig applies and
//! answers. Notes typed into the page appear in the native sidebar, and the
//! sidebar can send greetings that appear in the page.
//!
//! The window's single Content is a `composition.Owner`: the UI Context is
//! its full-window backdrop and the page is a native region on top of it.
//!
//! Run with `zig build run-hybrid -Dwebview=true`.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const web = @import("ziggurat_webview");
const html = @embedFile("hybrid.html");

const sidebar_width: f32 = 280;
const max_notes = 5;
const max_note = 80;

const Action = enum(u64) { increment = 1, reset, greet };

const Hybrid = struct {
    window: z.Window = undefined,
    owner: ?*z.composition.Owner = null,
    page: web.View = undefined,
    region: ?z.composition.Region = null,
    width: f32 = 960,
    height: f32 = 600,
    count: i64 = 0,
    greetings: u32 = 0,
    ready: bool = false,
    status: []const u8 = "starting",
    /// Notes from the page, newest first, copied into fixed storage.
    notes: [max_notes][max_note]u8 = undefined,
    note_lens: [max_notes]usize = @splat(0),
    note_count: usize = 0,
    error_name: []const u8 = "",

    fn report(self: *Hybrid, err: anyerror) void {
        self.error_name = @errorName(err);
        self.window.invalidate();
    }

    fn pageViewport(self: *const Hybrid) z.composition.Viewport {
        return .{ .bounds = .{ .x = sidebar_width, .y = 0, .width = @max(0, self.width - sidebar_width), .height = self.height }, .visible = true };
    }

    /// Send the count to the page. Before the page is ready there is no one
    /// to tell; it asks with "hello" once its listener is installed.
    fn publish(self: *Hybrid) void {
        var buffer: [32]u8 = undefined;
        self.post(std.fmt.bufPrint(&buffer, "count:{d}", .{self.count}) catch unreachable);
    }
    fn post(self: *Hybrid, message: []const u8) void {
        if (!self.ready) return;
        self.page.post(message) catch |err| self.report(err);
    }

    fn remember(self: *Hybrid, note: []const u8) void {
        var i: usize = max_notes - 1;
        while (i > 0) : (i -= 1) {
            self.notes[i] = self.notes[i - 1];
            self.note_lens[i] = self.note_lens[i - 1];
        }
        // Truncate on a UTF-8 boundary.
        var len = @min(note.len, max_note);
        while (len > 0 and len < note.len and note[len] & 0xc0 == 0x80) len -= 1;
        @memcpy(self.notes[0][0..len], note[0..len]);
        self.note_lens[0] = len;
        self.note_count = @min(self.note_count + 1, max_notes);
    }

    /// Page events arrive on the main thread; message text is borrowed
    /// until this returns.
    fn pageEvent(context: *anyopaque, view: *web.View, event: web.Event) void {
        const self: *Hybrid = @ptrCast(@alignCast(context));
        switch (event) {
            .ready => {
                self.ready = true;
                self.status = "ready";
            },
            .message => |message| {
                if (std.mem.eql(u8, message, "hello")) {
                    self.publish();
                } else if (std.mem.eql(u8, message, "increment")) {
                    self.count +|= 1;
                    self.publish();
                } else if (std.mem.eql(u8, message, "decrement")) {
                    self.count -|= 1;
                    self.publish();
                } else if (std.mem.startsWith(u8, message, "note:")) {
                    self.remember(message["note:".len..]);
                }
            },
            .failed => |code| {
                self.ready = false;
                self.status = "failed to start";
                std.log.err("page failed: native code 0x{x}", .{@as(u32, @bitCast(code))});
            },
            .process_failed => {
                self.ready = false;
                self.status = "restarting";
                view.recover() catch |err| self.report(err);
            },
            .policy_request, .resources_released => {},
        }
        self.window.invalidate();
    }

    fn draw(context: *anyopaque, frame: *ui.Frame) void {
        const self: *Hybrid = @ptrCast(@alignCast(context));
        frame.clear(0xffffff);
        frame.rect(.{ .x = 0, .y = 0, .width = sidebar_width, .height = self.height }, 0xf4f2ed);
        frame.rect(.{ .x = sidebar_width - 1, .y = 0, .width = 1, .height = self.height }, 0xd6d2c8);
        const x: f32 = 20;
        const w = sidebar_width - 2 * x;
        frame.labelFont(.{ .x = x, .y = 20, .width = w, .height = 30 }, "Native sidebar", 0x202b35, ui.Font.heading4);
        var buffer: [96]u8 = undefined;
        frame.labelFont(.{ .x = x, .y = 60, .width = w, .height = 44 }, std.fmt.bufPrint(&buffer, "Count: {d}", .{self.count}) catch unreachable, 0x202b35, ui.Font.heading2);
        frame.button(@backingInt(Action.increment), .{ .x = x, .y = 116, .width = w, .height = 34 }, "+ 1 from Zig") catch return;
        frame.buttonWithOptions(@backingInt(Action.reset), .{ .x = x, .y = 158, .width = w, .height = 34 }, "Reset", .{ .enabled = self.count != 0 }) catch return;
        frame.buttonWithOptions(@backingInt(Action.greet), .{ .x = x, .y = 200, .width = w, .height = 34 }, "Greet the page", .{ .enabled = self.ready }) catch return;
        frame.label(.{ .x = x, .y = 248, .width = w, .height = 24 }, std.fmt.bufPrint(&buffer, "Page: {s}", .{self.status}) catch unreachable, 0x3f5260);
        frame.label(.{ .x = x, .y = 288, .width = w, .height = 24 }, "Notes from the page", 0x202b35);
        if (self.note_count == 0) frame.label(.{ .x = x, .y = 316, .width = w, .height = 24 }, "(none yet)", 0x7e8790);
        for (0..self.note_count) |i| {
            const y = 316 + 28 * @as(f32, @floatFromInt(i));
            frame.label(.{ .x = x, .y = y, .width = w, .height = 24 }, self.notes[i][0..self.note_lens[i]], 0x3f5260);
        }
        if (self.error_name.len > 0) frame.label(.{ .x = x, .y = self.height - 36, .width = w, .height = 24 }, self.error_name, 0xa8530f);
    }

    fn action(context: *anyopaque, id: u64) void {
        const self: *Hybrid = @ptrCast(@alignCast(context));
        switch (std.enums.fromInt(Action, id) orelse return) {
            .increment => {
                self.count +|= 1;
                self.publish();
            },
            .reset => {
                self.count = 0;
                self.publish();
            },
            .greet => {
                self.greetings += 1;
                var buffer: [64]u8 = undefined;
                self.post(std.fmt.bufPrint(&buffer, "note:Hello #{d} from the native sidebar", .{self.greetings}) catch unreachable);
            },
        }
        self.window.invalidate();
    }

    /// Keep the page region beside the sidebar as the window resizes.
    fn input(context: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Hybrid = @ptrCast(@alignCast(context));
        if (event == .resize) {
            self.width = @as(f32, @floatFromInt(event.resize.width)) / event.resize.scale;
            self.height = @as(f32, @floatFromInt(event.resize.height)) / event.resize.scale;
            if (self.region) |region| region.update(self.pageViewport()) catch |err| self.report(err);
        }
        return false;
    }

    /// The regions and the backdrop have detached; free the Owner's slots.
    fn closed(context: *anyopaque, _: z.Window) void {
        const self: *Hybrid = @ptrCast(@alignCast(context));
        if (self.owner) |owner| owner.close() catch |err| std.log.err("owner close: {s}", .{@errorName(err)});
        self.owner = null;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // WebView2 on Windows keeps its profile in an absolute folder; WebKitGTK
    // on Linux can run this trusted page in an ephemeral session instead.
    const profile: []u8 = if (builtin.os.tag == .windows) blk: {
        const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        break :blk try std.fs.path.join(allocator, &.{ local, "Ziggurat", "Hybrid" });
    } else &.{};
    defer allocator.free(profile);
    const options: web.Options = if (builtin.os.tag == .windows) .{ .html = html, .user_data_folder = profile } else .{ .html = html, .storage = .ephemeral };

    var hybrid: Hybrid = .{};
    var context = ui.Context.init(&hybrid, Hybrid.draw, Hybrid.action);
    // A composition backdrop draws through the GDI/Cairo path.
    context.render_mode = .gdi;
    context.on_input = Hybrid.input;

    const app = try z.App.init(allocator);
    defer app.deinit();
    hybrid.window = try app.createWindow(.{
        .title = "Ziggurat - Hybrid",
        .width = 960,
        .height = 600,
        .min_width = 640,
        .min_height = 420,
        .on_closed = .{ .context = &hybrid, .notify = Hybrid.closed },
    });
    hybrid.owner = try z.composition.Owner.create(allocator, hybrid.window, .{ .capacity = 2 });
    _ = try context.attachBackdrop(hybrid.owner.?);

    hybrid.page = web.View.init(allocator, &hybrid, Hybrid.pageEvent);
    const region = try hybrid.owner.?.reserve(hybrid.pageViewport());
    hybrid.page.attachRegion(region, options) catch |err| {
        std.log.err("page: {s}; on Windows run the installed executable beside WebView2Loader.dll", .{@errorName(err)});
        _ = region.remove() catch false;
        return err;
    };
    hybrid.region = region;

    hybrid.window.show();
    try app.run();
}

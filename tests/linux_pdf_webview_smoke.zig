const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const source =
    \\<!doctype html><style>@media print{p:not(:last-child){break-after:page}}body{background:#204060}</style><p>one</p><p>two</p><p>three</p>
;
const Step = struct { options: web.tools.PdfOptions, pages: usize, media_box: []const u8 };
const State = struct {
    app: *z.App,
    path: []const u8,
    directory: std.Io.Dir,
    allocator: std.mem.Allocator,
    view: web.View = undefined,
    step: usize = 0,
    steps: []const Step = &.{},
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("Linux printToPdf step {d}: {s}\n", .{ self.step, @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, input: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (input != .completed) return;
        if (!input.completed.success) return self.fail(error.LoadFailed);
        var options = self.steps[0].options;
        options.first_page = 0;
        std.testing.expectError(error.InvalidPageRange, view.printToPdf(view.pageId().?, options, .{}, self.completion())) catch |err| return self.fail(err);
        options = self.steps[0].options;
        options.margins.left = 5;
        options.margins.right = 5;
        std.testing.expectError(error.InvalidMargins, view.printToPdf(view.pageId().?, options, .{}, self.completion())) catch |err| return self.fail(err);
        self.submit();
    }
    fn completion(self: *State) web.tools.Completion {
        return .{ .context = self, .complete = complete };
    }
    fn submit(self: *State) void {
        _ = self.view.printToPdf(self.view.pageId().?, self.steps[self.step].options, .{ .timeout_ms = 20_000 }, self.completion()) catch |err| self.fail(err);
    }
    fn complete(ptr: *anyopaque, result: web.tools.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .pdf_path) {
            std.debug.print("result: {s}\n", .{@tagName(result)});
            return self.fail(error.PdfFailed);
        }
        if (!std.mem.eql(u8, result.pdf_path, self.path)) return self.fail(error.WrongPath);
        self.check() catch |err| return self.fail(err);
        self.step += 1;
        if (self.step == self.steps.len) return self.app.quit();
        self.submit();
    }
    fn check(self: *State) !void {
        const bytes = try self.directory.readFileAlloc(zio.io(), "out.pdf", self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(bytes);
        const want = self.steps[self.step];
        if (!std.mem.startsWith(u8, bytes, "%PDF-")) return error.NotPdf;
        const pages = std.mem.count(u8, bytes, "/Type /Page\n");
        const box = std.mem.indexOf(u8, bytes, want.media_box) != null;
        if (pages != want.pages or !box) {
            std.debug.print("pages={d} want={d} media box {s} found={}\n", .{ pages, want.pages, want.media_box, box });
            return error.WrongPdf;
        }
        try self.directory.deleteFile(zio.io(), "out.pdf");
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var private = zio.tmpDir(.{});
    defer private.cleanup();
    const directory = try zio.realPathAlloc(private.dir, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "out.pdf" });
    defer allocator.free(path);
    const steps = [_]Step{
        .{ .options = .{ .path = path, .accept_overwrite = true }, .pages = 3, .media_box = "/MediaBox [0 0 612 792]" },
        .{ .options = .{ .path = path, .accept_overwrite = true, .page_size = .a4, .landscape = true, .first_page = 2, .last_page = 3, .print_backgrounds = true, .margins = .none }, .pages = 2, .media_box = "/MediaBox [0 0 842 595]" },
        .{ .options = .{ .path = path, .accept_overwrite = true, .first_page = 2 }, .pages = 2, .media_box = "/MediaBox [0 0 612 792]" },
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .path = path, .directory = private.dir, .allocator = allocator, .steps = &steps };
    state.view = web.View.init(allocator, &state, State.event);
    const window = try app.createWindow(.{ .width = 320, .height = 240 });
    defer _ = window.destroy() catch unreachable;
    try state.view.attach(window, .{ .html = source, .storage = .ephemeral, .tools = .{ .pdf = true }, .page_listener = .{ .context = &state, .event = State.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.step == steps.len);
    std.debug.print("Linux printToPdf: page size, orientation, margins and page ranges written through the file printer\n", .{});
}

const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
extern fn zwk_capture_counts(*u32, *u32, *usize, *usize) void;

const source =
    \\<!doctype html><style>@media print{p:not(:last-child){break-after:page}}body{background:#204060;color:white}</style><p>one</p><p>two</p><p>three</p>
;
const Step = struct { options: web.tools.PdfOptions, pages: usize, media_box: []const u8 };

/// The visible page as a PNG, PDFs as the Linux smoke prints them (page
/// size, orientation, margins and page ranges), and a clear of the page's
/// data store. Every operation's record is gone at the end.
const State = struct {
    app: *z.App,
    window: z.Window,
    path: []const u8,
    directory: std.Io.Dir,
    allocator: std.mem.Allocator,
    view: web.View = undefined,
    stage: enum { capture, pdf, clear, done } = .capture,
    step: usize = 0,
    steps: []const Step = &.{},
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("macOS capture stage={s} step={d}: {s}\n", .{ @tagName(self.stage), self.step, @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn completion(self: *State) web.tools.Completion {
        return .{ .context = self, .complete = complete };
    }
    fn page(ptr: *anyopaque, view: *web.View, input: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (input != .completed) return;
        if (!input.completed.success) return self.fail(error.LoadFailed);
        var options = self.steps[0].options;
        options.first_page = 0;
        std.testing.expectError(error.InvalidPageRange, view.printToPdf(view.pageId().?, options, .{}, self.completion())) catch |err| return self.fail(err);
        _ = view.capturePreview(view.pageId().?, .{ .timeout_ms = 20_000 }, self.completion()) catch |err| self.fail(err);
    }
    fn submit(self: *State) void {
        _ = self.view.printToPdf(self.view.pageId().?, self.steps[self.step].options, .{ .timeout_ms = 20_000 }, self.completion()) catch |err| self.fail(err);
    }
    fn complete(ptr: *anyopaque, result: web.tools.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (self.stage) {
            .capture => {
                if (result != .png) {
                    std.debug.print("capture result: {s}\n", .{@tagName(result)});
                    return self.fail(error.CaptureFailed);
                }
                const png = result.png;
                if (!std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n")) return self.fail(error.NotPng);
                std.debug.print("macOS capture: PNG of {d} bytes\n", .{png.len});
                self.stage = .pdf;
                self.submit();
            },
            .pdf => {
                if (result != .pdf_path) {
                    std.debug.print("pdf result: {s}\n", .{@tagName(result)});
                    return self.fail(error.PdfFailed);
                }
                if (!std.mem.eql(u8, result.pdf_path, self.path)) return self.fail(error.WrongPath);
                self.check() catch |err| return self.fail(err);
                self.step += 1;
                if (self.step < self.steps.len) return self.submit();
                self.stage = .clear;
                _ = self.view.clearBrowsingData(.entire_profile, .{ .timeout_ms = 20_000 }, self.completion()) catch |err| self.fail(err);
            },
            .clear => {
                if (result != .cleared) {
                    std.debug.print("clear result: {s}\n", .{@tagName(result)});
                    return self.fail(error.ClearFailed);
                }
                self.stage = .done;
                _ = self.window.destroy() catch |err| return self.fail(err);
                self.app.quit();
            },
            .done => self.fail(error.UnexpectedCompletion),
        }
    }
    fn check(self: *State) !void {
        const bytes = try self.directory.readFileAlloc(zio.io(), "out.pdf", self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(bytes);
        const want = self.steps[self.step];
        if (!std.mem.startsWith(u8, bytes, "%PDF-")) return error.NotPdf;
        const pages = std.mem.count(u8, bytes, "/Type /Page") - std.mem.count(u8, bytes, "/Type /Pages");
        const box = std.mem.indexOf(u8, bytes, want.media_box) != null;
        std.debug.print("macOS PDF step {d}: {d} bytes, pages={d} (want {d}), media box {s} found={}\n", .{ self.step, bytes.len, pages, want.pages, want.media_box, box });
        if (pages != want.pages or !box) return error.WrongPdf;
        try self.directory.deleteFile(zio.io(), "out.pdf");
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    if (!web.backendCapabilities().capture_preview) return error.SkipZigTest;
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
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var state: State = .{ .app = app, .window = try app.createWindow(.{ .width = 320, .height = 240 }), .path = path, .directory = private.dir, .allocator = allocator, .steps = &steps };
        state.view = web.View.init(allocator, &state, State.event);
        try state.view.attach(state.window, .{ .html = source, .storage = .ephemeral, .tools = .{ .capture = true, .pdf = true, .clear_entire_profile = true }, .page_listener = .{ .context = &state, .event = State.page } });
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        watchdog.stop();
        if (watchdog.expired) state.fail(error.Timeout);
        if (state.failure) |err| return err;
        try std.testing.expect(state.stage == .done);
    }
    var budgets: u32 = 0;
    var operations: u32 = 0;
    var bytes: usize = 0;
    var peak: usize = 0;
    zwk_capture_counts(&budgets, &operations, &bytes, &peak);
    if (budgets != 0 or operations != 0 or bytes != 0) {
        std.debug.print("macOS capture records left: budgets={d} operations={d} bytes={d}\n", .{ budgets, operations, bytes });
        return error.CaptureRecordsLeft;
    }
    std.debug.print("macOS capture: visible PNG, PDFs with page size, orientation, margins and ranges, clear; capture records=0 (peak {d} bytes)\n", .{peak});
}

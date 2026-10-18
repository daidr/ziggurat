const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const web = @import("ziggurat_webview");
const html = @embedFile("web_counter.html");

const Panel = struct {
    host: *Workspace,
    view: web.View = undefined,
    region: ?z.composition.Region = null,
    profile: []const u8,
    count: usize = 0,
    visible: bool = true,
    ready: bool = false,
    fn event(context: *anyopaque, view: *web.View, event_value: web.Event) void {
        const self: *Panel = @ptrCast(@alignCast(context));
        switch (event_value) {
            .ready => self.ready = true,
            .resources_released => self.ready = false,
            .process_failed => {
                self.ready = false;
                self.host.report(error.BrowserProcessFailed);
            },
            .failed => |hr| {
                self.ready = false;
                std.log.err("page controller failed: 0x{x}", .{@as(u32, @bitCast(hr))});
                self.host.report(error.PageFailed);
            },
            .message => |message| {
                if (std.mem.eql(u8, message, "increment")) {
                    self.count +|= 1;
                    var buffer: [32]u8 = undefined;
                    const text = std.fmt.bufPrint(&buffer, "{d}", .{self.count}) catch unreachable;
                    view.post(text) catch |err| self.host.report(err);
                }
            },
            .policy_request => {},
        }
        self.host.window.invalidate();
    }
    fn open(self: *Panel, viewport: z.composition.Viewport) !void {
        var initial = viewport;
        initial.visible = true;
        const region = try self.host.owner.?.reserve(initial);
        errdefer _ = region.remove() catch false;
        try self.view.attachRegion(region, .{ .html = html, .user_data_folder = self.profile });
        self.region = region;
        self.visible = true;
        self.ready = false;
        self.count = 0;
    }
};

const Workspace = struct {
    window: z.Window = undefined,
    owner: ?*z.composition.Owner = null,
    panels: [2]Panel = undefined,
    width: f32 = 960,
    height: f32 = 640,
    error_name: []const u8 = "",
    fn report(self: *Workspace, err: anyerror) void {
        self.error_name = @errorName(err);
        self.window.invalidate();
    }
    fn viewport(self: *const Workspace, index: usize) z.composition.Viewport {
        const width = @max(0, (self.width - 48) / 2);
        return .{ .bounds = .{ .x = 16 + @as(f32, @floatFromInt(index)) * (width + 16), .y = 112, .width = width, .height = @max(0, self.height - 128) }, .visible = self.panels[index].visible };
    }
    fn input(context: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Workspace = @ptrCast(@alignCast(context));
        if (event == .resize) {
            self.width = @as(f32, @floatFromInt(event.resize.width)) / event.resize.scale;
            self.height = @as(f32, @floatFromInt(event.resize.height)) / event.resize.scale;
            for (&self.panels, 0..) |*panel, index| if (panel.region) |region| region.update(self.viewport(index)) catch |err| self.report(err);
        }
        return false;
    }
    fn draw(context: *anyopaque, frame: *ui.Frame) void {
        const self: *Workspace = @ptrCast(@alignCast(context));
        frame.clear(0xf4f2ed);
        frame.label(.{ .x = 16, .y = 8, .width = 700, .height = 24 }, "Ziggurat / Independent rectangular pages", 0x202b35);
        frame.buttonWithOptions(1, .{ .x = 16, .y = 40, .width = 150, .height = 32 }, if (self.panels[0].visible) "Hide left page" else "Show left page", .{ .enabled = self.panels[0].region != null }) catch return;
        frame.button(2, .{ .x = 176, .y = 40, .width = 180, .height = 32 }, if (self.panels[0].region != null) "Close left page" else "Reopen left page") catch return;
        var buffer: [192]u8 = undefined;
        const status = std.fmt.bufPrint(&buffer, "Left: {s}, count {d} | Right: {s}, count {d}  {s}", .{ if (self.panels[0].ready) "ready" else "inactive", self.panels[0].count, if (self.panels[1].ready) "ready" else "inactive", self.panels[1].count, self.error_name }) catch unreachable;
        frame.label(.{ .x = 16, .y = 80, .width = @max(0, self.width - 32), .height = 24 }, status, 0x3f5260);
    }
    fn action(context: *anyopaque, id: u64) void {
        const self: *Workspace = @ptrCast(@alignCast(context));
        const panel = &self.panels[0];
        if (id == 1) {
            if (panel.region) |region| {
                var next = self.viewport(0);
                next.visible = !panel.visible;
                region.update(next) catch |err| return self.report(err);
                panel.visible = next.visible;
            }
        } else if (id == 2) {
            if (panel.region) |region| {
                _ = region.remove() catch |err| return self.report(err);
                panel.region = null;
                panel.ready = false;
            } else panel.open(self.viewport(0)) catch |err| self.report(err);
        }
        self.window.invalidate();
    }
    fn closed(context: *anyopaque, _: z.Window) void {
        const self: *Workspace = @ptrCast(@alignCast(context));
        if (self.owner) |owner| owner.close() catch unreachable;
        self.owner = null;
    }
};

pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    const allocator = allocations.allocator();
    const local = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    var profiles: [2][]u8 = undefined;
    profiles[0] = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "RectangularPages", "Left" });
    defer allocator.free(profiles[0]);
    profiles[1] = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "RectangularPages", "Right" });
    defer allocator.free(profiles[1]);
    var workspace: Workspace = .{};
    var context = ui.Context.init(&workspace, Workspace.draw, Workspace.action);
    context.render_mode = .gdi;
    context.on_input = Workspace.input;
    const app = try z.App.init(allocator);
    defer app.deinit();
    workspace.window = try app.createWindow(.{ .title = "Ziggurat — Rectangular pages", .width = 960, .height = 640, .min_width = 720, .min_height = 420, .on_closed = .{ .context = &workspace, .notify = Workspace.closed } });
    workspace.owner = try z.composition.Owner.create(allocator, workspace.window, .{});
    for (&workspace.panels, profiles) |*panel, profile| {
        panel.* = .{ .host = &workspace, .profile = profile };
        panel.view = web.View.init(allocator, panel, Panel.event);
    }
    _ = try context.attachBackdrop(workspace.owner.?);
    for (&workspace.panels, 0..) |*panel, index| try panel.open(workspace.viewport(index));
    workspace.window.show();
    try app.run();
}

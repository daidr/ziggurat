const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);

const linux = builtin.os.tag == .linux;
/// WebKitGTK and WKWebView: explicit ephemeral storage, no WebView2 folder.
const webkit = linux or builtin.os.tag == .macos;

/// Run by tests/http_auth_host.py with its two loopback origins. The app
/// signs in to one realm, goes without credentials in another and sees the
/// server's refusal, then refuses a certificate nothing trusts, sees the
/// load fail, and allows it the second time by its DER.
const Probe = struct {
    app: *z.App,
    view: web.View = undefined,
    plain: []const u8,
    secure: []const u8,
    der: []const u8,
    store: []const u8,
    extension: []const u8,
    grants: [2]web.OriginGrant = undefined,
    url: [512]u8 = undefined,
    step: enum { welcome, denied, refused, trusted, done } = .welcome,
    challenges: u32 = 0,
    certificates: u32 = 0,
    failure: ?anyerror = null,

    fn fail(self: *Probe, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("http auth step {s}: {s}\n", .{ @tagName(self.step), @errorName(err) });
        self.app.quit();
    }
    fn options(self: *Probe) web.Options {
        self.grants = .{ .{ .origin = self.plain }, .{ .origin = self.secure } };
        return .{
            .html = "",
            .storage = if (webkit) .ephemeral else .profile,
            .user_data_folder = if (webkit) "" else self.store,
            .remote = .{ .url = self.at(self.plain, "/private"), .origins = &self.grants, .credentials = if (webkit) .ephemeral else .profile, .allow_insecure_loopback = true },
            .request_policy_extension = if (linux) .{ .directory = self.extension } else null,
            .http_auth = .{ .context = self, .answer = answer },
            .certificate_errors = .{ .context = self, .allow = allow },
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn at(self: *Probe, origin: []const u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.url, "{s}{s}", .{ origin, path }) catch unreachable;
    }
    fn port(origin: []const u8) u16 {
        return std.fmt.parseInt(u16, origin[std.mem.lastIndexOfScalar(u8, origin, ':').? + 1 ..], 10) catch unreachable;
    }
    fn answer(ptr: *anyopaque, _: *web.View, challenge: web.AuthChallenge) ?web.Credentials {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.challenges += 1;
        if (!std.mem.eql(u8, challenge.host, "127.0.0.1") or challenge.port != port(self.plain) or challenge.scheme != .basic or challenge.proxy) {
            std.debug.print("challenge {s}:{d} {s} {s}\n", .{ challenge.host, challenge.port, challenge.realm, @tagName(challenge.scheme) });
            self.fail(error.WrongChallenge);
            return null;
        }
        const realm = if (self.step == .welcome) "ziggurat test" else "elsewhere";
        if (!std.mem.eql(u8, challenge.realm, realm)) {
            std.debug.print("realm {s}\n", .{challenge.realm});
            self.fail(error.WrongRealm);
            return null;
        }
        return if (self.step == .welcome) .{ .username = "ziggurat", .password = "s3cret" } else null;
    }
    fn allow(ptr: *anyopaque, _: *web.View, problem: web.CertificateError) bool {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.certificates += 1;
        if (!std.mem.eql(u8, problem.host, "127.0.0.1") or !std.mem.startsWith(u8, problem.uri, self.secure) or problem.reason.len == 0) {
            std.debug.print("certificate error {s} {s} {s}\n", .{ problem.uri, problem.host, problem.reason });
            self.fail(error.WrongCertificateError);
            return false;
        }
        if (!std.mem.eql(u8, problem.certificate, self.der)) {
            self.fail(error.WrongCertificate);
            return false;
        }
        return self.step == .trusted;
    }
    fn page(ptr: *anyopaque, view: *web.View, input: web.PageEvent) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .title_changed => |change| {
                const title = change.title orelse return;
                if (std.mem.eql(u8, title, "welcome") and self.step == .welcome) {
                    if (self.challenges != 1) return self.fail(error.ChallengeCount);
                    self.step = .denied;
                    view.navigateRemote(self.at(self.plain, "/deny")) catch |err| self.fail(err);
                } else if (std.mem.eql(u8, title, "denied") and self.step == .denied) {
                    if (self.challenges != 2) return self.fail(error.ChallengeCount);
                    self.step = .refused;
                    view.navigateRemote(self.at(self.secure, "/tls")) catch |err| self.fail(err);
                } else if (std.mem.eql(u8, title, "trusted")) {
                    if (self.step != .trusted) return self.fail(error.RefusedCertificateLoaded);
                    self.step = .done;
                    self.app.quit();
                }
            },
            .completed => |info| {
                if (self.step != .refused or info.success) return;
                if (self.certificates != 1) {
                    std.debug.print("refused load: status {d}, asked {d} times\n", .{ info.native_status, self.certificates });
                    return self.fail(error.CertificateNotAsked);
                }
                self.step = .trusted;
                view.navigateRemote(self.at(self.secure, "/tls")) catch |err| self.fail(err);
            },
            else => {},
        }
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len != @as(usize, if (linux) 5 else 4)) return error.InvalidArgument;
    const file = try std.Io.Dir.cwd().openFile(zio.io(), args[3], .{});
    const pem = try zio.readToEndAlloc(file, allocator, 65536);
    file.close(zio.io());
    defer allocator.free(pem);
    var der_storage: [8192]u8 = undefined;
    const der = web.http_auth.pemCertificate(pem, &der_storage) orelse return error.InvalidCertificate;
    const store = if (webkit) try allocator.dupe(u8, "") else blk: {
        const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        break :blk try std.fs.path.join(allocator, &.{ local, "Ziggurat", "HttpAuthSmoke" });
    };
    defer allocator.free(store);
    const extension = if (linux) args[4] else "";
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 320, .height = 200 });
    defer _ = window.destroy() catch {};
    var probe: Probe = .{ .app = app, .plain = args[1], .secure = args[2], .der = der, .store = store, .extension = extension };
    probe.view = web.View.init(allocator, &probe, Probe.event);
    try probe.view.attach(window, probe.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (probe.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.step == .done and probe.challenges == 2 and probe.certificates == 2);
    std.debug.print("http auth: signed in, refusal without credentials, certificate refused then allowed by its DER\n", .{});
}

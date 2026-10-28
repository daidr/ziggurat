const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn webkit_get_major_version() c_uint;
extern fn webkit_get_minor_version() c_uint;
extern fn webkit_get_micro_version() c_uint;

const origin = "asset://app.ziggurat.invalid";
const body =
    \\<!doctype html><meta charset="utf-8"><script>addEventListener('DOMContentLoaded',async()=>{
    \\chrome.webview.postMessage('origin:'+location.origin);let step='start';try{
    \\let s=await fetch('/static');if(await s.text()!=='static body')throw Error('static GET');
    \\let h=await fetch('/static',{method:'HEAD'});if(h.headers.get('Content-Length')!=='11'||await h.text()!=='')throw Error('static HEAD');
    \\const headers={'Content-Type':'application/zig-test','Authorization':'fixture-only','X-Exact':'declared','X-Any':'variable','X-Empty':''};
    \\for(const [method,path] of [['GET','/echo'],['POST','/document'],['POST','/static'],['PUT','/write'],['PATCH','/write'],['DELETE','/write'],['OPTIONS','/write']]){
    \\step=method+' '+path;chrome.webview.postMessage('attempt:'+step);
    \\let r=await fetch(path,{method,headers,...(method==='GET'?{}:{body:'fixture body must not be read'})});
    \\if(r.status!==200||await r.text()!==method+':'+path)throw Error('handler route');}
    \\chrome.webview.postMessage('done');}catch(e){chrome.webview.postMessage('error:'+step+':'+e.name+':'+e.message)}})</script>
;
const xhr_body =
    \\<!doctype html><meta charset="utf-8"><script>addEventListener('DOMContentLoaded',()=>{
    \\chrome.webview.postMessage('origin:'+location.origin);chrome.webview.postMessage('attempt:XHR POST /echo');
    \\const x=new XMLHttpRequest();x.open('POST','/echo');
    \\for(const [k,v] of Object.entries({'Content-Type':'application/zig-test','Authorization':'fixture-only','X-Exact':'declared','X-Any':'variable','X-Empty':''}))x.setRequestHeader(k,v);
    \\x.onload=()=>chrome.webview.postMessage(x.status===200&&x.responseText==='POST:/echo'?'done':'error:XHR status='+x.status);
    \\x.onerror=()=>chrome.webview.postMessage('error:XHR POST /echo:NetworkError:status='+x.status);x.send('fixture body must not be read');})</script>
;
const read_body =
    \\<!doctype html><meta charset="utf-8"><script>addEventListener('DOMContentLoaded',async()=>{
    \\chrome.webview.postMessage('origin:'+location.origin);let step='read';try{
    \\const headers={'Content-Type':'application/zig-test','Authorization':'fixture-only','X-Exact':'declared','X-Any':'variable','X-Empty':''};
    \\let s=await fetch('/static',{headers});if(await s.text()!=='static body')throw Error('static GET');
    \\let h=await fetch('/static',{method:'HEAD',headers});if(h.headers.get('Content-Length')!=='11'||await h.text()!=='')throw Error('static HEAD');
    \\chrome.webview.postMessage('attempt:GET /echo');let r=await fetch('/echo',{headers});if(r.status!==200||await r.text()!=='GET:/echo')throw Error('GET handler');
    \\const cases=[['X-Exact','wrong'],['X-Empty','nonempty'],['Content-Type','unlisted/type'],['Authorization','wrong'],['Range','bytes=0-1'],['X-Unlisted','denied']];
    \\for(const [name,value] of cases){step='header '+name;chrome.webview.postMessage('attempt:'+step);let rejected=false;try{await fetch('/echo?case='+name,{headers:{...headers,[name]:value}})}catch(e){if(e.name!=='TypeError')throw e;rejected=true}if(!rejected)throw Error('unexpected header permission');chrome.webview.postMessage('denied:'+step);}
    \\for(const method of ['POST','PUT','PATCH','DELETE','OPTIONS']){step=method+' /static';chrome.webview.postMessage('attempt:'+step);let rejected=false;try{await fetch('/static',{method,headers,body:'fixture body must not be read'})}catch(e){if(e.name!=='TypeError')throw e;rejected=true}if(!rejected)throw Error('write unexpectedly admitted without observed Origin');chrome.webview.postMessage('denied:'+step);}
    \\chrome.webview.postMessage('done');}catch(e){chrome.webview.postMessage('error:'+step+':'+e.name+':'+e.message)}})</script>
;

const Probe = struct {
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    failure: ?anyerror = null,
    requests: usize = 0,
    attempts: usize = 0,
    messages: usize = 0,
    origins: usize = 0,
    denied: usize = 0,
    methods: [7]usize = @splat(0),
    fn fail(self: *Probe, failure: anyerror) void {
        if (self.failure == null) self.failure = failure;
        std.debug.print("custom_request_failure={s} requests={d} attempts={d}\n", .{ @errorName(failure), self.requests, self.attempts });
        self.app.quit();
    }
    fn event(context: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        switch (value) {
            .message => |message| {
                std.debug.print("custom_request_page={s}\n", .{message});
                if (std.mem.startsWith(u8, message, "origin:")) {
                    if (!std.mem.eql(u8, message, "origin:" ++ origin)) return self.fail(error.UnexpectedPageOrigin);
                    self.origins += 1;
                } else if (std.mem.startsWith(u8, message, "attempt:")) self.attempts += 1 else if (std.mem.startsWith(u8, message, "denied:")) self.denied += 1 else if (std.mem.eql(u8, message, "done")) {
                    self.messages += 1;
                    self.app.quit();
                } else self.fail(error.PageRequestFailed);
            },
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn handle(context: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.check(request, responder) catch |failure| self.fail(failure);
    }
    fn check(self: *Probe, request: web.ResourceRequest, responder: *web.Responder) !void {
        self.requests += 1;
        self.methods[@backingInt(request.method)] += 1;
        var origins: usize = 0;
        for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "Origin")) {
            origins += 1;
            std.debug.print("custom_request_observed_origin={s} method={s} path={s}\n", .{ header.value, @tagName(request.method), request.path });
            try std.testing.expectEqualStrings(origin, header.value);
        };
        if (request.method != .get and request.method != .head) try std.testing.expectEqual(@as(usize, 1), origins);
        try std.testing.expect(origins <= 1);
        const expected = [_]web.resources.Header{
            .{ .name = "Content-Type", .value = "application/zig-test" },
            .{ .name = "Authorization", .value = "fixture-only" },
            .{ .name = "X-Exact", .value = "declared" },
            .{ .name = "X-Any", .value = "variable" },
            .{ .name = "X-Empty", .value = "" },
        };
        for (expected) |field| {
            var found = false;
            for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, field.name)) {
                try std.testing.expectEqualStrings(field.value, header.value);
                found = true;
            };
            try std.testing.expect(found);
        }
        std.debug.print("custom_request_handler method={s} path={s} origin_count={d} headers={d} body_reads=none\n", .{ @tagName(request.method), request.path, origins, request.headers.len });
        var text: [128]u8 = undefined;
        const method = switch (request.method) {
            .get => "GET",
            .head => "HEAD",
            .post => "POST",
            .put => "PUT",
            .patch => "PATCH",
            .delete => "DELETE",
            .options => "OPTIONS",
        };
        const response = try std.fmt.bufPrint(&text, "{s}:{s}", .{ method, request.path });
        try responder.respond(.{ .mime = "text/plain", .bytes = response });
    }
};

pub fn run(allocator: std.mem.Allocator) !void {
    std.debug.print("custom_request_engine=WebKitGTK {d}.{d}.{d}\n", .{ webkit_get_major_version(), webkit_get_minor_version(), webkit_get_micro_version() });
    const variant = zio.getenv("ZIGGURAT_CUSTOM_REQUEST_VARIANT") orelse "read-policy";
    const xhr = std.mem.eql(u8, variant, "xhr");
    const reads = std.mem.eql(u8, variant, "read-policy");
    if (!xhr and !reads and !std.mem.eql(u8, variant, "fetch")) return error.InvalidRequestVariant;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app };
    probe.window = try app.createWindow(.{});
    probe.view = web.View.init(allocator, &probe, Probe.event);
    try probe.view.attach(probe.window, .{
        .html = if (xhr) xhr_body else if (reads) read_body else body,
        .storage = .ephemeral,
        .local = .{
            .scheme = "asset",
            .start_path = "/document",
            .scheme_ipc = true,
            .resources = &.{.{ .path = "/static", .mime = "text/plain", .bytes = "static body" }},
            .on_resource = .{ .context = &probe, .handle = Probe.handle },
            .methods = .{ .post = true, .put = true, .patch = true, .delete = true, .options = true },
            .request_headers = &.{
                .{ .name = "Content-Type", .exact_value = "application/zig-test" },
                .{ .name = "Authorization", .exact_value = "fixture-only" },
                .{ .name = "X-Exact", .exact_value = "declared" },
                .{ .name = "X-Any" },
                .{ .name = "X-Empty", .exact_value = "" },
            },
        },
        .custom_schemes = &.{.{ .name = "asset", .treat_as_secure = true, .request_origins = &.{origin} }},
    });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (probe.failure) |failure| return failure;
    if (watchdog.expired) return error.RequestDeadline;
    const expected_requests: usize = if (xhr or reads) 1 else 7;
    const expected_attempts: usize = if (reads) 12 else if (xhr) 1 else 7;
    try std.testing.expect(probe.messages == 1 and probe.requests == expected_requests and probe.attempts == expected_attempts and probe.origins == 1);
    try std.testing.expectEqualSlices(usize, if (xhr) &.{ 0, 0, 1, 0, 0, 0, 0 } else if (reads) &.{ 1, 0, 0, 0, 0, 0, 0 } else &.{ 1, 0, 2, 1, 1, 1, 1 }, &probe.methods);
    try std.testing.expectEqual(@as(usize, if (reads) 11 else 0), probe.denied);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("custom_request_same_origin variant={s}: static GET/HEAD, non-X/any/exact-empty, handler_requests={d} denied={d}; writes require actually observed Origin\n", .{ variant, probe.requests, probe.denied });
}

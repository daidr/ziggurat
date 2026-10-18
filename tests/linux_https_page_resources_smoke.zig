const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const https = @import("ziggurat_https_resources");
const native_stream = @import("ziggurat_native_stream");
const Watchdog = @import("watchdog.zig").Watchdog;
const certificate = @embedFile("fixtures/profile-https/server-cert.pem");
const private_key = @embedFile("fixtures/profile-https/server-key.pem");
const file_length = 524325;
const secret: [32]u8 = .{0x53} ** 32;
const Mode = enum { complete, file_window, range_file, range_empty, origin_guard, cancel_file, stop_file, post_closed, missing_credentials, static_routes, callback_close, final_free_close, final_free_quit, producer_fetch, producer_head, producer_cancel, producer_stop, producer_post_closed, producer_navigate, producer_recover, producer_endpoint_close };
const generated_length = 131109;
const generated_maximum = 32 * 1024 * 1024;
fn isProducer(mode: Mode) bool {
    return @intFromEnum(mode) >= @intFromEnum(Mode.producer_fetch);
}
extern fn zhr_page_connect_refused(c_uint) c_int;
extern fn zhr_page_observer_new(*anyopaque) ?*anyopaque;
extern fn zhr_page_observer_read(*anyopaque, *c_uint, *c_uint) void;
extern fn zhr_page_observer_release(*anyopaque) void;
extern fn zhr_page_observer_count() c_uint;
extern fn zhr_page_file() c_int;
extern fn zhr_page_empty_file() c_int;
extern fn g_main_context_iteration(?*anyopaque, c_int) c_int;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
extern fn zwk_profile_counts(*u32, *u32, *usize) void;
extern fn zwk_file_pread_count() u64;

const Preparation = struct {
    allocator: std.mem.Allocator,
    main: std.Thread.Id,
    path: []const u8,
    value: ?web.profile_storage.Prepared = null,
    failure: ?anyerror = null,
    fn worker(self: *Preparation) void {
        self.value = web.profile_storage.Prepared.prepare(self.allocator, self.main, self.path, .{}) catch |err| {
            self.failure = err;
            return;
        };
        self.value.?.handoff() catch |err| {
            self.failure = err;
            self.value.?.close() catch |close_err| {
                self.failure = close_err;
            };
            self.value = null;
        };
    }
    fn open(self: *Preparation) !void {
        const thread = try std.Thread.spawn(.{}, worker, .{self});
        thread.join();
        if (self.failure) |err| return err;
        try self.value.?.adopt();
    }
};
const Job = struct {
    state: *State,
    kind: enum { memory, file, head, window, window_head, empty_window, range, cancel, stop, closed },
    ticket: https.Endpoint.Ticket,
    method: https.http.Method = .get,
    file_request: ?https.FileRequest = null,
    file_response: ?https.PreparedFileResponse = null,
    source: ?https.files.PreparedSource = null,
    thread: ?std.Thread = null,
    gate: std.Thread.Semaphore = .{},
    failure: std.atomic.Value(u16) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),
    closed_post: std.atomic.Value(bool) = .init(false),
    fn start(self: *Job) !void {
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }
    fn worker(self: *Job) void {
        self.produce() catch |err| {
            self.failure.store(@intFromError(err), .release);
            self.state.app.post(.{ .context = self, .call = failed }) catch {};
        };
    }
    fn failed(ptr: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        self.state.fail(error.WorkerFailed);
    }
    fn produce(self: *Job) !void {
        if (self.kind == .closed) {
            var owned = try https.http.OwnedResponse.init(self.state.allocator, .{ .bytes = "retained after Closed" }, 100);
            defer owned.deinit();
            self.gate.wait();
            self.state.app.post(.{ .context = self, .call = deliver }) catch |err| {
                if (err != error.Closed or owned.storage == null or self.ticket.native_ticket == null) return error.PostClosedOwnership;
                self.closed_post.store(true, .release);
                self.ticket.deinit();
                return;
            };
            return error.ClosedPostAccepted;
        }
        if (self.kind == .memory) {
            self.state.app.post(.{ .context = self, .call = deliver }) catch |err| {
                self.ticket.deinit();
                return err;
            };
            return;
        }
        const descriptor = if (self.kind == .range and self.state.mode == .range_empty) zhr_page_empty_file() else zhr_page_file();
        if (descriptor < 0) return error.PrivateFileFailed;
        const file: std.fs.File = .{ .handle = descriptor };
        defer file.close();
        if (self.kind == .range) return self.produceRange(file);
        const is_window = self.kind == .window or self.kind == .window_head or self.kind == .empty_window;
        const saved_position = if (is_window) try file.getPos() else 0;
        const reads_before = zwk_file_pread_count();
        const selected_window: https.files.FileWindow = .{ .offset = if (self.kind == .empty_window) file_length else 17, .length = if (self.kind == .empty_window) 0 else 65541 };
        var prepared = if (is_window)
            try https.files.PreparedSource.prepareWindow(self.state.app.owner, file, selected_window, 1024 * 1024)
        else
            try https.files.PreparedSource.prepare(self.state.app.owner, file, 1024 * 1024);
        defer prepared.pump.deinit();
        self.source = prepared.source;
        prepared.source.native = null;
        prepared.source.length = 0;
        if (is_window) {
            const expected: u64 = selected_window.length;
            if (try self.source.?.authoritativeLength() != expected or try file.getPos() != saved_position) return error.WindowPreparationChanged;
            self.source.?.length = 1; // Deliberately untrusted convenience cache.
        }
        self.state.app.post(.{ .context = self, .call = deliver }) catch |err| {
            self.source.?.deinit();
            self.source = null;
            self.ticket.deinit();
            return err;
        };
        if (self.kind == .head or self.kind == .window_head or self.kind == .stop or self.kind == .cancel) self.gate.wait();
        if (self.kind == .head or self.kind == .window_head) {
            if (self.kind == .window_head and zwk_file_pread_count() != reads_before) return error.WindowHeadReadBody;
            return;
        }
        prepared.pump.pump() catch |err| {
            if (err == error.Cancelled and (self.kind == .stop or self.kind == .cancel)) {
                self.cancelled.store(true, .release);
                return;
            }
            return err;
        };
        if (self.kind == .stop or self.kind == .cancel) return error.CancelledPumpCompleted;
        if (is_window and try file.getPos() != saved_position) return error.WindowPumpChangedPosition;
        if (self.kind == .empty_window and zwk_file_pread_count() != reads_before) return error.EmptyWindowReadBody;
    }
    fn produceRange(self: *Job, file: std.fs.File) !void {
        const position = try file.getPos();
        const reads = zwk_file_pread_count();
        const prepared = try https.PreparedFileResponse.prepare(self.state.app.owner, file, 1024 * 1024, self.file_request.?);
        var pump = prepared.pump;
        defer if (pump) |*value| value.deinit();
        const metadata_only = prepared.response.selection == .unsatisfiable;
        const empty = prepared.response.total == 0;
        if (metadata_only and (prepared.response.source != null or pump != null)) return error.UnsatisfiableCreatedSource;
        if (!metadata_only and (prepared.response.source == null or pump == null)) return error.PreparedSourceMissing;
        self.file_response = prepared.response;
        self.state.app.post(.{ .context = self, .call = deliver }) catch |err| {
            self.file_response.?.deinit();
            self.ticket.deinit();
            return err;
        };
        // A successful post transfers response to the owner; only this worker
        // pump and pre-post scalar facts may be read hereafter.
        if (pump) |*value| try value.pump();
        if (try file.getPos() != position) return error.WindowPumpChangedPosition;
        if ((self.method == .head or empty) and zwk_file_pread_count() != reads) return error.PreparedHeadReadBody;
    }
    fn deliver(ptr: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        const state = self.state;
        if (self.kind == .closed) return state.fail(error.ClosedPostAccepted);
        if (self.kind == .memory) {
            const response: https.http.Response = .{ .mime = "text/plain", .bytes = "worker memory", .headers = &https.site_routes.policy_headers };
            var receipt = self.ticket.respondBorrowed(response) catch |err| return state.fail(err);
            defer receipt.deinit();
            if (self.ticket.native_ticket != null or !std.mem.eql(u8, response.bytes, "worker memory")) return state.fail(error.BorrowedResponseOwnership);
        } else if (self.kind == .range) {
            const metadata_only = self.file_response.?.selection == .unsatisfiable;
            var receipt = self.ticket.respondPreparedFile(&self.file_response.?, .{ .file_control = true }) catch |err| {
                self.file_response.?.deinit(); // Cancel an unaccepted worker pump.
                return state.fail(err);
            };
            defer receipt.deinit();
            if (self.file_response.?.ready or self.file_response.?.source != null or self.ticket.native_ticket != null) return state.fail(error.PreparedResponseNotMoved);
            if ((receipt.control == null) != metadata_only) return state.fail(error.PreparedControlMismatch);
            if (metadata_only) std.debug.print("HTTPS helper 416: metadata-only/no-source/no-pump\n", .{});
        } else {
            var receipt = self.ticket.respondSource(.{ .length = 1, .headers = &https.site_routes.policy_headers }, &self.source.?, .{ .file_control = true }) catch |err| return state.fail(err);
            defer receipt.deinit();
            if (self.source.?.native != null or self.ticket.native_ticket != null or receipt.control == null) return state.fail(error.ResponseNotMoved);
            if (self.kind == .cancel) {
                receipt.control.?.cancel();
                const physical = https.files.counts();
                if (physical.physical == 0) return state.fail(error.CancelPrematurelyReleasedFile);
                state.logical_cancel_retained = true;
                self.gate.post();
            } else if (self.kind == .head or self.kind == .window_head) self.gate.post() else if (self.kind == .stop) {
                if (https.files.counts().physical == 0) return state.fail(error.AcceptedFileMissing);
                state.app.quit();
            }
        }
        state.deliveries += 1;
    }
};

const ProducerJob = struct {
    state: *State,
    ticket: https.Endpoint.Ticket,
    kind: enum { body, zero, head, cancel, stop, closed, navigate, recover, endpoint_close },
    length: u64,
    source: ?native_stream.Source = null,
    control: ?https.files.Control = null, // owner thread only
    thread: ?std.Thread = null,
    gate: std.Thread.Semaphore = .{},
    retire_gate: std.Thread.Semaphore = .{},
    failure: std.atomic.Value(u16) = .init(0),
    generated: std.atomic.Value(u64) = .init(0),
    completed: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    head_skipped: std.atomic.Value(bool) = .init(false),
    closed_post: std.atomic.Value(bool) = .init(false),
    fn start(self: *ProducerJob) !void {
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }
    fn worker(self: *ProducerJob) void {
        self.produce() catch |err| {
            self.failure.store(@intFromError(err), .release);
            self.state.app.post(.{ .context = self, .call = failed }) catch {};
        };
    }
    fn failed(ptr: *anyopaque) void {
        const self: *ProducerJob = @ptrCast(@alignCast(ptr));
        std.debug.print("Native producer worker: {s}\n", .{@errorName(@errorFromInt(self.failure.load(.acquire)))});
        self.state.fail(error.ProducerWorkerFailed);
    }
    fn produce(self: *ProducerJob) !void {
        var pair = try native_stream.prepare(self.state.app.owner, self.length, generated_maximum);
        defer pair.writer.deinit();
        self.source = pair.source;
        pair.source.native = null;
        pair.source.length = 0;
        if (self.kind == .closed) self.gate.wait();
        self.state.app.post(.{ .context = self, .call = deliver }) catch |err| {
            const retained = self.source.?.native != null and self.ticket.native_ticket != null;
            self.source.?.deinit();
            self.source = null;
            self.ticket.deinit();
            if (self.kind != .closed or err != error.Closed or !retained) return error.ProducerPostOwnership;
            self.closed_post.store(true, .release);
            return;
        };
        if (self.kind == .closed) return error.ProducerClosedPostAccepted;
        if (self.kind == .head or self.kind == .stop or self.kind == .navigate or self.kind == .recover or self.kind == .endpoint_close) self.gate.wait();
        if (self.kind == .head) {
            // The authorized request was HEAD and the owner has committed its
            // real source. Retire without invoking generation; the SDK may
            // already have released its completed HEAD stream at this point.
            self.head_skipped.store(true, .release);
            return;
        }
        const disposition = pair.writer.waitAccepted() catch |err| return self.expectedCancel(err);
        if (disposition != .body) return error.UnexpectedProducerHead;
        var bytes: [native_stream.chunk_bytes]u8 = undefined;
        var offset: u64 = 0;
        while (offset < self.length) {
            const count: usize = @intCast(@min(bytes.len, self.length - offset));
            for (bytes[0..count], 0..) |*byte, i| byte.* = @intCast((offset + i) % 251);
            pair.writer.writeAll(bytes[0..count]) catch |err| return self.expectedCancel(err);
            offset += count;
            self.generated.store(offset, .release);
            // Test-only staging, not a production ACK protocol: expose one
            // real fetch chunk before the host explicitly revokes this duty.
            if (self.kind == .cancel and offset == count) self.gate.wait();
        }
        try pair.writer.finish();
        self.completed.store(true, .release);
        if (self.kind == .cancel or self.kind == .stop or self.kind == .navigate or self.kind == .recover or self.kind == .endpoint_close) return error.ExpectedProducerCancellation;
    }
    fn expectedCancel(self: *ProducerJob, err: anyerror) !void {
        if (err != error.Cancelled or (self.kind != .cancel and self.kind != .stop and self.kind != .navigate and self.kind != .recover and self.kind != .endpoint_close)) return err;
        self.cancelled.store(true, .release);
        // Keep this actual physical Writer ref until App.run has returned.
        // Logical cancellation must not return its shared capacity early.
        self.retire_gate.wait();
    }
    fn deliver(ptr: *anyopaque) void {
        const self: *ProducerJob = @ptrCast(@alignCast(ptr));
        const state = self.state;
        if (self.kind == .closed) return state.fail(error.ProducerClosedPostAccepted);
        var receipt = self.ticket.respondSource(.{ .length = 1, .mime = "application/octet-stream", .headers = &https.site_routes.policy_headers }, &self.source.?, .{ .file_control = true }) catch |err| {
            self.source.?.deinit(); // A failed admission wakes the writer.
            self.source = null;
            return state.fail(err);
        };
        defer receipt.deinit();
        if (self.source.?.native != null or self.ticket.native_ticket != null or receipt.control == null) return state.fail(error.ProducerNotMoved);
        self.control = receipt.control;
        receipt.control = null;
        state.deliveries += 1;
        switch (self.kind) {
            .head => self.gate.post(),
            .stop => {
                if (https.files.counts().physical == 0) return state.fail(error.ProducerPhysicalMissing);
                state.logical_cancel_retained = true;
                state.app.quit();
            },
            .navigate => state.view.navigateRemote(state.restart_url.?) catch |err| state.fail(err),
            .recover => @import("linux_webview_process.zig").stop(state.window) catch |err| state.fail(err),
            .endpoint_close => {
                state.site_stats = state.site.?.stats() catch |err| return state.fail(err);
                _ = state.site.?.close() catch |err| return state.fail(err);
                if (https.files.counts().physical == 0) return state.fail(error.ProducerPhysicalMissing);
                state.logical_cancel_retained = true;
                self.gate.post();
            },
            else => {},
        }
    }
};

const FreeProbe = struct {
    backing: std.mem.Allocator,
    site: ?*https.Site = null,
    app: ?*z.App = null,
    target: ?[*]u8 = null,
    quit: bool = false,
    calls: usize = 0,
    failure: ?anyerror = null,
    fn allocator(self: *FreeProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FreeProbe = @ptrCast(@alignCast(ptr));
        return self.backing.rawAlloc(bytes, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *FreeProbe = @ptrCast(@alignCast(ptr));
        if (self.target == bytes.ptr) {
            self.target = null;
            self.calls += 1;
            const site = self.site.?;
            if (site.table.storage != null or site.endpoint != null or site.handler != null) self.failure = error.SiteNotWithdrawnBeforeFree;
            const result = site.close() catch |err| result: {
                self.failure = err;
                break :result https.CloseResult.deferred;
            };
            if (result != .closed) self.failure = error.SiteFreeCloseNotIdempotent;
            if (self.quit) self.app.?.quit();
        }
        self.backing.rawFree(bytes, alignment, ra);
    }
};

fn program(mode: Mode) []const u8 {
    return switch (mode) {
        .complete => "(async()=>{try{if(await(await fetch('/private/memory')).text()!=='memory')throw 1;if(await(await fetch('/private/deferred')).text()!=='worker memory')throw 2;let r=await fetch('/private/file'),b=new Uint8Array(await r.arrayBuffer());if(b.length!==524325)throw 3;for(let i=0;i<b.length;i++)if(b[i]!==i%251)throw 4;let h=await fetch('/private/head',{method:'HEAD'});if(h.headers.get('Content-Length')!=='524325'||(await h.arrayBuffer()).byteLength!==0)throw 5;chrome.webview.postMessage('complete')}catch(e){chrome.webview.postMessage('error:'+e)}})();",
        .file_window => "(async()=>{try{function p(r,n){if(r.status!==200||r.headers.get('Content-Length')!==String(n)||r.headers.get('Cache-Control')!=='no-store'||r.headers.get('X-Content-Type-Options')!=='nosniff'||!r.headers.get('Content-Security-Policy').includes(\"default-src 'none'\"))throw 'metadata'}let r=await fetch('/private/window');p(r,65541);let b=new Uint8Array(await r.arrayBuffer());if(b.length!==65541)throw 'length';for(let i=0;i<b.length;i++)if(b[i]!==((i+17)%251))throw 'byte:'+i;let h=await fetch('/private/window',{method:'HEAD'});p(h,65541);if((await h.arrayBuffer()).byteLength!==0)throw 'head';let e=await fetch('/private/empty-window');p(e,0);if((await e.arrayBuffer()).byteLength!==0)throw 'empty';chrome.webview.postMessage('complete')}catch(e){chrome.webview.postMessage('error:'+e)}})();",
        .range_file => "(async()=>{try{async function q(v,s,n,o,c,ir,m){let h={Range:v};if(ir)h['If-Range']=ir;let r=await fetch('/private/range',{method:m||'GET',headers:h});if(r.status!==s||r.headers.get('Content-Length')!==String(n)||r.headers.get('Content-Range')!==c||r.headers.get('ETag')!=='\"fixture-v1\"'||r.headers.get('Cache-Control')!=='no-store'||r.headers.get('X-Content-Type-Options')!=='nosniff'||!r.headers.get('Content-Security-Policy').includes(\"default-src 'none'\"))throw 'metadata:'+v+':'+r.status;let b=new Uint8Array(await r.arrayBuffer());if(b.length!==(m==='HEAD'?0:n))throw 'length:'+v;for(let i=0;i<b.length;i++)if(b[i]!==((i+o)%251))throw 'byte:'+v+':'+i}await q('bytes=17-65557',206,65541,17,'bytes 17-65557/524325','\"fixture-v1\"');await q('bytes=-7',206,7,524318,'bytes 524318-524324/524325');await q('bytes=0-4',200,524325,0,null,'\"different\"');await q('bytes=0-1,4-5',200,524325,0,null);await q('items=0-1',200,524325,0,null);await q('bytes=524325-',416,0,0,'bytes */524325');await q('malformed',200,524325,0,null,null,'HEAD');chrome.webview.postMessage('complete')}catch(e){chrome.webview.postMessage('error:'+e)}})();",
        .range_empty => "(async()=>{try{for(let m of ['GET','HEAD']){let r=await fetch('/private/range',{method:m,headers:{Range:m==='GET'?'bytes=0-0':'malformed'}});if(r.status!==200||r.headers.get('Content-Length')!=='0'||r.headers.get('Content-Range')!==null||(await r.arrayBuffer()).byteLength!==0)throw 'empty'}chrome.webview.postMessage('complete')}catch(e){chrome.webview.postMessage('error:'+e)}})();",
        .cancel_file => "fetch('/private/cancel').then(r=>r.arrayBuffer()).then(()=>chrome.webview.postMessage('error:unexpected body'),()=>chrome.webview.postMessage('cancelled'));",
        .stop_file => "fetch('/private/stop').then(r=>r.arrayBuffer());",
        .post_closed, .callback_close => "fetch('/private/closed');",
        .missing_credentials => "chrome.webview.postMessage('error:unauthorized page')",
        .producer_fetch => "(async()=>{try{let r=await fetch('/private/producer');if(r.status!==200||r.headers.get('Content-Length')!=='131109'||r.headers.get('Content-Type')!=='application/octet-stream')throw 'metadata';let reader=r.body.getReader(),n=0;for(;;){let x=await reader.read();if(x.done)break;for(let b of x.value){if(b!==n%251)throw 'byte:'+n;n++}}if(n!==131109)throw 'length';let e=await fetch('/private/producer-zero');if(e.headers.get('Content-Length')!=='0'||(await e.arrayBuffer()).byteLength!==0)throw 'zero';chrome.webview.postMessage('complete')}catch(e){chrome.webview.postMessage('error:'+e)}})();",
        .producer_head => "(async()=>{try{let r=await fetch('/private/producer',{method:'HEAD'});if(r.status!==200||r.headers.get('Content-Length')!=='131109'||(await r.arrayBuffer()).byteLength!==0)throw 'head';chrome.webview.postMessage('complete')}catch(e){chrome.webview.postMessage('error:'+e)}})();",
        .producer_cancel => "(async()=>{try{let r=await fetch('/private/producer'),reader=r.body.getReader(),x=await reader.read();if(x.done||!x.value.length)throw 'missing first bytes';for(let i=0;i<x.value.length;i++)if(x.value[i]!==i%251)throw 'first byte';await reader.cancel();chrome.webview.postMessage('cancelled')}catch(e){chrome.webview.postMessage('error:'+e)}})();",
        .producer_stop => "fetch('/private/producer').then(r=>r.arrayBuffer());",
        .producer_post_closed => "fetch('/private/producer');",
        .producer_navigate, .producer_recover => "(async()=>{try{let r=await fetch('/private/producer'),b=new Uint8Array(await r.arrayBuffer());if(b.length!==131109)throw 'length';for(let i=0;i<b.length;i++)if(b[i]!==i%251)throw 'byte:'+i;chrome.webview.postMessage('complete')}catch(e){chrome.webview.postMessage('error:'+e)}})();",
        .producer_endpoint_close => "fetch('/private/producer').then(r=>r.arrayBuffer()).then(()=>chrome.webview.postMessage('error:unexpected body'),()=>chrome.webview.postMessage('cancelled'));",
        .static_routes, .origin_guard, .final_free_close, .final_free_quit => "(async()=>{try{function p(r){if(r.headers.get('Cache-Control')!=='no-store'||r.headers.get('X-Content-Type-Options')!=='nosniff'||!r.headers.get('Content-Security-Policy').includes(\"default-src 'none'\"))throw 'headers'}let r=await fetch('/private/memory?opaque=%2f');p(r);if(await r.text()!=='memory')throw 1;let h=await fetch('/private/memory',{method:'HEAD'});p(h);if(h.headers.get('Content-Length')!=='6'||(await h.arrayBuffer()).byteLength!==0)throw 2;let n=await fetch('/private/missing');p(n);if(n.status!==404||await n.text()!=='Not Found')throw 3;let nh=await fetch('/private/missing',{method:'HEAD'});p(nh);if(nh.status!==404||nh.headers.get('Content-Length')!=='9'||(await nh.arrayBuffer()).byteLength!==0)throw 4;chrome.webview.postMessage('complete')}catch(e){chrome.webview.postMessage('error:'+e)}})();",
    };
}

const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    window: z.Window,
    mode: Mode,
    view: web.View = undefined,
    site: ?*https.Site = null,
    site_stats: ?https.Site.Stats = null,
    late_ticket: ?https.Endpoint.Ticket = null,
    free_probe: ?*FreeProbe = null,
    jobs: [8]Job = undefined,
    producers: [4]ProducerJob = undefined,
    producer_count: usize = 0,
    job_count: usize = 0,
    offers: usize = 0,
    deliveries: usize = 0,
    messages: usize = 0,
    ready: usize = 0,
    closed: bool = false,
    logical_cancel_retained: bool = false,
    peer_uri: ?[]const u8 = null,
    peer_denied: usize = 0,
    restart_url: ?[]const u8 = null,
    process_failures: usize = 0,
    failure: ?anyerror = null,
    stop_node: z.StopParticipant = undefined,
    fn fail(self: *State, err: anyerror) void {
        self.failure = self.failure orelse err;
        std.debug.print("HTTPS pages {s}: {s}\n", .{ @tagName(self.mode), @errorName(err) });
        self.app.quit();
    }
    fn stop(context: *anyopaque) !void {
        const self: *State = @ptrCast(@alignCast(context));
        // Registered before Endpoint: its cancellation runs first. Wake only
        // explicit test workers; never wait for them on the owner thread.
        if ((self.mode == .stop_file and self.job_count != 0) or (self.mode == .producer_stop and self.producer_count != 0)) {
            if (https.files.counts().physical == 0) return error.StopPrematurelyReleasedFile;
            if ((try self.site.?.stats()).transport.accepting) return error.EndpointNotSealedBeforeWorker;
            self.logical_cancel_retained = true;
        }
        for (self.jobs[0..self.job_count]) |*job| if (job.kind == .stop or job.kind == .closed or job.kind == .head or job.kind == .window_head or job.kind == .cancel) {
            job.gate.post();
        };
        for (self.producers[0..self.producer_count]) |*job| job.gate.post();
    }
    fn endpointClosed(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        std.debug.assert(!self.closed);
        self.closed = true;
        self.site = null;
    }
    fn finish(self: *State) !void {
        if (self.app.phase != .stopped) {
            self.app.quit();
            try self.app.finishShutdown();
        }
        // The loop has returned (or failed construction has finished shutdown).
        // No active owner callback waits for a worker to call back into App.
        for (self.jobs[0..self.job_count]) |*job| {
            job.gate.post();
            if (job.thread) |thread| thread.join();
            job.thread = null;
            if (job.source) |*source| source.deinit();
            if (job.file_response) |*response| response.deinit();
            job.ticket.deinit();
        }
        for (self.producers[0..self.producer_count]) |*job| {
            job.gate.post();
            job.retire_gate.post();
            if (job.thread) |thread| thread.join();
            job.thread = null;
            if (job.source) |*source| source.deinit();
            if (job.control) |*control| control.deinit();
            job.ticket.deinit();
        }
        if (self.site) |site| {
            self.site_stats = try site.stats();
            _ = try site.close();
        }
    }
    fn request(context: *anyopaque, req: https.Site.Request, offer: https.Endpoint.Offer) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.offers += 1;
        self.route(req, offer) catch |err| self.fail(err);
    }
    fn route(self: *State, req: https.Site.Request, offer: https.Endpoint.Offer) !void {
        if (!std.mem.startsWith(u8, req.full_path, "/private/") or req.policy_headers.len != 3) return error.DynamicRequestScope;
        if (isProducer(self.mode)) {
            if ((req.method != .get and req.method != .head) or self.producer_count == self.producers.len) return error.ProducerRequestInvalid;
            const empty = std.mem.eql(u8, req.path, "/producer-zero");
            if (!empty and !std.mem.eql(u8, req.path, "/producer")) return error.ProducerRouteInvalid;
            const first = self.producer_count == 0;
            const kind: @FieldType(ProducerJob, "kind") = if (req.method == .head) .head else if (empty) .zero else switch (self.mode) {
                .producer_cancel => .cancel,
                .producer_stop => .stop,
                .producer_post_closed => .closed,
                .producer_navigate => if (first) .navigate else .body,
                .producer_recover => if (first) .recover else .body,
                .producer_endpoint_close => .endpoint_close,
                else => .body,
            };
            const job = &self.producers[self.producer_count];
            job.* = .{ .state = self, .ticket = try offer.deferRequest(), .kind = kind, .length = if (empty) 0 else if (kind == .cancel) generated_maximum else generated_length };
            self.producer_count += 1;
            try job.start();
            if (kind == .closed) self.app.quit();
            return;
        }
        if (self.mode == .callback_close and std.mem.eql(u8, req.path, "/closed")) {
            self.late_ticket = try offer.deferRequest();
            self.site_stats = try self.site.?.stats();
            if (try self.site.?.close() != .deferred or self.closed) return error.SiteCallbackPinMissing;
            if (!std.mem.eql(u8, req.path, "/closed")) return error.RequestBorrowInvalidated;
            self.app.quit();
            return;
        }
        if (self.job_count == self.jobs.len) return error.TooManyJobs;
        if ((self.mode == .range_file or self.mode == .range_empty) and std.mem.eql(u8, req.path, "/range")) {
            const captured = try https.FileRequest.capture(req.method, req.headers, .{ .etag = "\"fixture-v1\"" });
            const job = &self.jobs[self.job_count];
            // Only numeric selection inputs survive the borrowed callback.
            job.* = .{ .state = self, .kind = .range, .ticket = try offer.deferRequest(), .method = req.method, .file_request = captured };
            self.job_count += 1;
            try job.start();
            return;
        }
        const kind: @FieldType(Job, "kind") = if (std.mem.eql(u8, req.path, "/deferred")) .memory else if (std.mem.eql(u8, req.path, "/file")) .file else if (std.mem.eql(u8, req.path, "/head") and req.method == .head) .head else if (self.mode == .file_window and std.mem.eql(u8, req.path, "/window")) (if (req.method == .head) .window_head else .window) else if (self.mode == .file_window and std.mem.eql(u8, req.path, "/empty-window") and req.method == .get) .empty_window else if (std.mem.eql(u8, req.path, "/cancel")) .cancel else if (std.mem.eql(u8, req.path, "/stop")) .stop else if (std.mem.eql(u8, req.path, "/closed")) .closed else return error.UnexpectedRoute;
        const job = &self.jobs[self.job_count];
        job.* = .{ .state = self, .kind = kind, .ticket = try offer.deferRequest() };
        self.job_count += 1;
        try job.start();
        if (kind == .closed) self.app.quit();
    }
    fn staticError(context: *anyopaque, _: https.Site.Request, failure: anyerror) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.fail(failure);
    }
    fn event(context: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (value) {
            .ready => {
                self.ready += 1;
                if (self.ready == 1 and self.offers != 0) self.fail(error.RequestBeforeReady);
                if (self.peer_uri) |uri| {
                    view.navigateRemote(uri) catch |failure| {
                        if (failure == error.OriginDenied) {
                            self.peer_denied += 1;
                            return;
                        }
                        return self.fail(failure);
                    };
                    self.fail(error.PeerNavigationAccepted);
                }
            },
            .failed => self.fail(error.PageFailed),
            .process_failed => {
                if (self.mode != .producer_recover or self.process_failures != 0 or self.producer_count != 1) return self.fail(error.PageFailed);
                self.process_failures += 1;
                self.producers[0].control.?.cancel();
                self.producers[0].gate.post();
                view.recover() catch |err| self.fail(err);
            },
            .message => |message| {
                const expected = if (self.mode == .cancel_file or self.mode == .producer_cancel or self.mode == .producer_endpoint_close) "cancelled" else "complete";
                if (!std.mem.eql(u8, expected, message)) {
                    std.debug.print("HTTPS pages {s} actual message: {s}\n", .{ @tagName(self.mode), message });
                    return self.fail(error.PageResultMismatch);
                }
                self.messages += 1;
                if (self.mode == .producer_cancel) {
                    // The host explicitly revokes this independent network
                    // duty after the page reports reader.cancel. This is not
                    // a claim that browser consumption supplies an ACK.
                    self.producers[0].control.?.cancel();
                    if (https.files.counts().physical == 0) return self.fail(error.ProducerPhysicalMissing);
                    self.logical_cancel_retained = true;
                    self.producers[0].gate.post();
                }
                if (self.mode == .final_free_close or self.mode == .final_free_quit) {
                    const site = self.site.?;
                    self.site_stats = site.stats() catch |err| return self.fail(err);
                    const probe = self.free_probe.?;
                    probe.site = site;
                    probe.app = self.app;
                    probe.target = site.table.storage.?.ptr;
                    probe.quit = self.mode == .final_free_quit;
                    _ = site.close() catch |err| return self.fail(err);
                }
                self.app.quit();
            },
            else => {},
        }
    }
    fn page(context: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (value == .started and self.mode == .producer_navigate and self.producer_count == 1) {
            self.producers[0].control.?.cancel();
            self.producers[0].gate.post();
        }
        if (value == .completed and self.mode == .missing_credentials) self.app.quit();
    }
};

fn run(allocator: std.mem.Allocator, prepared: *web.profile_storage.Prepared, extension: []const u8, mode: Mode, late_ticket: *?https.Endpoint.Ticket) !void {
    const preads = zwk_file_pread_count();
    const app = try z.App.init(allocator);
    defer app.deinit();
    var transport_closed = false;
    const transport = try https.Transport.create(allocator, app, .{ .material = .{ .certificate_pem = certificate, .private_key_pem = private_key }, .on_closed = .{ .context = &transport_closed, .notify = struct {
        fn closed(context: *anyopaque) void {
            const value: *bool = @ptrCast(@alignCast(context));
            std.debug.assert(!value.*);
            value.* = true;
        }
    }.closed } });
    defer if (!transport_closed) {
        _ = transport.close() catch unreachable;
        std.debug.assert(transport_closed);
    };
    const profile = try web.Profile.createWithOptions(allocator, app, prepared, .{ .loopback_https = .{ .certificate_pem = certificate } });
    defer profile.close() catch unreachable;
    var origin_buffer: [30]u8 = undefined;
    const origin = try transport.origin(&origin_buffer);
    const port = (try transport.stats()).port;
    const url = try std.fmt.allocPrint(allocator, "{s}/private/start", .{origin});
    defer allocator.free(url);
    const restart_url: ?[]u8 = if (mode == .producer_navigate) try std.fmt.allocPrint(allocator, "{s}?generation=2", .{url}) else null;
    defer if (restart_url) |value| allocator.free(value);
    var probe: FreeProbe = .{ .backing = allocator };
    var state: State = .{ .allocator = allocator, .app = app, .window = try app.createWindow(.{ .width = 320, .height = 200 }), .mode = mode, .free_probe = &probe, .restart_url = restart_url };
    defer if (state.late_ticket) |*ticket| ticket.deinit();
    defer state.finish() catch |err| std.debug.panic("HTTPS page cleanup failed: {s}", .{@errorName(err)});
    var peer: ?Peer = null;
    defer if (peer) |*owner| owner.close();
    var peer_url: [64]u8 = undefined;
    if (mode == .origin_guard) {
        peer = try Peer.create(allocator, app);
        var peer_origin_buffer: [30]u8 = undefined;
        const peer_origin = try peer.?.transport.?.origin(&peer_origin_buffer);
        try std.testing.expect(!std.mem.eql(u8, peer_origin, origin));
        state.peer_uri = try std.fmt.bufPrint(&peer_url, "{s}/private/peer", .{peer_origin});
    }
    state.stop_node = .{ .context = &state, .stop = State.stop };
    _ = try app.registerStop(&state.stop_node);
    var resources = [_]https.site_routes.Route{
        .{ .path = "/start", .mime = "text/html; charset=utf-8", .bytes = "<!doctype html><meta charset='utf-8'><script src='/private/app.js'></script>" },
        .{ .path = "/app.js", .mime = "text/javascript", .bytes = program(mode) },
        .{ .path = "/memory", .mime = "text/plain", .bytes = "memory" },
    };
    const static_only = mode == .static_routes or mode == .origin_guard or mode == .final_free_close or mode == .final_free_quit;
    // Completed HTTP work may still have retained native stream references.
    // Provision all three new source duties without assuming prompt SDK unref.
    const range_mode = mode == .range_file or mode == .range_empty;
    const file_slots: u8 = if (mode == .range_file) 8 else if (mode == .file_window or isProducer(mode)) 3 else 2;
    const budget: usize = if (range_mode) 512 * 1024 else 256 * 1024;
    state.site = try https.Site.createOnTransport(probe.allocator(), app, transport, .{ .mount_prefix = "/private/", .bearer = secret, .range_requests = range_mode, .resources = &resources, .on_resource = if (static_only) null else .{ .context = &state, .call = State.request }, .on_error = .{ .context = &state, .call = State.staticError }, .on_closed = .{ .context = &state, .notify = State.endpointClosed }, .limits = .{ .bytes = budget, .max_pending = if (range_mode) 8 else 4, .max_response_bytes = 64 * 1024, .max_file_bytes = if (isProducer(mode)) generated_maximum else 1024 * 1024, .max_file_streams = file_slots } });
    var site_origin: [30]u8 = undefined;
    try std.testing.expectEqualStrings(origin, try state.site.?.origin(&site_origin));
    for (&resources) |*resource| resource.* = .{ .path = "/changed", .bytes = "caller descriptor replaced" };
    state.view = web.View.init(allocator, &state, State.event);
    const credentials = [_]web.RequestCredential{.{ .origin = origin, .bearer = secret }};
    try state.view.attach(state.window, .{ .html = "", .storage = .profile, .profile = profile, .remote = .{ .url = url, .origins = &.{.{ .origin = origin, .ipc = true, .request_headers = if (range_mode) &.{.{ .name = "Range" }} else &.{} }}, .credentials = .profile, .allow_insecure_loopback = true, .request_credentials = if (mode == .missing_credentials) &.{} else &credentials }, .request_policy_extension = .{ .directory = extension }, .page_listener = .{ .context = &state, .event = State.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    try state.finish();
    try std.testing.expect(!(try transport.stats()).accepting);
    try std.testing.expectError(error.Closed, https.Site.createOnTransport(allocator, app, transport, .{ .bearer = secret }));
    try ListenerCheck.execute(port);
    for (state.jobs[0..state.job_count]) |*job| {
        try std.testing.expectEqual(@as(u16, 0), job.failure.load(.acquire));
    }
    for (state.producers[0..state.producer_count]) |*job| {
        std.debug.print("Native producer {s}: kind={s} generated={d} completed={} cancelled={} head_skipped={} closed_post={}\n", .{ @tagName(mode), @tagName(job.kind), job.generated.load(.acquire), job.completed.load(.acquire), job.cancelled.load(.acquire), job.head_skipped.load(.acquire), job.closed_post.load(.acquire) });
        try std.testing.expectEqual(@as(u16, 0), job.failure.load(.acquire));
    }
    if (state.failure) |err| return err;
    if (isProducer(mode)) try std.testing.expectEqual(preads, zwk_file_pread_count());
    try std.testing.expect(!watchdog.expired and state.closed and state.ready == (if (mode == .producer_recover) @as(usize, 2) else 1));
    switch (mode) {
        .complete, .file_window => try std.testing.expect(state.offers == 3 and state.messages == 1 and state.job_count == 3 and state.deliveries == 3),
        .range_file => try std.testing.expect(state.offers == 7 and state.messages == 1 and state.job_count == 7 and state.deliveries == 7),
        .range_empty => try std.testing.expect(state.offers == 2 and state.messages == 1 and state.job_count == 2 and state.deliveries == 2),
        .cancel_file => try std.testing.expect(state.logical_cancel_retained and state.messages == 1 and state.jobs[0].cancelled.load(.acquire)),
        .stop_file => try std.testing.expect(state.logical_cancel_retained and state.messages == 0 and state.jobs[0].cancelled.load(.acquire)),
        .post_closed => try std.testing.expect(state.jobs[0].closed_post.load(.acquire) and state.messages == 0),
        .missing_credentials => try std.testing.expect(state.offers == 0 and state.messages == 0),
        .static_routes, .origin_guard, .final_free_close, .final_free_quit => {
            try std.testing.expect(state.offers == 0 and state.messages == 1 and state.site_stats.?.static_requests == 4 and state.site_stats.?.not_found == 2);
            if (mode == .origin_guard) {
                try std.testing.expectEqual(@as(usize, 1), state.peer_denied);
                var requests: c_uint = 0;
                var authorization: c_uint = 0;
                zhr_page_observer_read(peer.?.observer.?, &requests, &authorization);
                try std.testing.expect(requests == 0 and authorization == 0 and (try peer.?.site.?.stats()).static_requests == 0);
                std.debug.print("HTTPS owned page exact-origin peer: actual native navigation OriginDenied, wire0 Authorization0\n", .{});
            } else if (mode != .static_routes) {
                try std.testing.expectEqual(@as(usize, 1), probe.calls);
                if (probe.failure) |err| return err;
            }
        },
        .callback_close => {
            try std.testing.expect(state.offers == 1 and state.messages == 0 and state.late_ticket != null);
            late_ticket.* = state.late_ticket;
            state.late_ticket = null;
        },
        .producer_fetch => {
            try std.testing.expect(state.offers == 2 and state.producer_count == 2 and state.deliveries == 2 and state.messages == 1);
            try std.testing.expect(state.producers[0].completed.load(.acquire) and state.producers[0].generated.load(.acquire) == generated_length);
            try std.testing.expect(state.producers[1].completed.load(.acquire) and state.producers[1].generated.load(.acquire) == 0);
        },
        .producer_head => try std.testing.expect(state.offers == 1 and state.producer_count == 1 and state.messages == 1 and state.producers[0].head_skipped.load(.acquire) and state.producers[0].generated.load(.acquire) == 0),
        .producer_cancel, .producer_stop, .producer_endpoint_close => {
            try std.testing.expect(state.offers == 1 and state.producer_count == 1 and state.deliveries == 1 and state.logical_cancel_retained);
            try std.testing.expect(state.messages == (if (mode == .producer_stop) @as(usize, 0) else 1));
            try std.testing.expect(state.producers[0].cancelled.load(.acquire) and !state.producers[0].completed.load(.acquire));
        },
        .producer_post_closed => try std.testing.expect(state.offers == 1 and state.producer_count == 1 and state.messages == 0 and state.deliveries == 0 and state.producers[0].closed_post.load(.acquire)),
        .producer_navigate, .producer_recover => {
            try std.testing.expect(state.offers == 2 and state.producer_count == 2 and state.deliveries == 2 and state.messages == 1);
            try std.testing.expect(state.producers[0].cancelled.load(.acquire) and state.producers[0].generated.load(.acquire) == 0);
            try std.testing.expect(state.producers[1].completed.load(.acquire) and state.producers[1].generated.load(.acquire) == generated_length);
            try std.testing.expect(state.process_failures == (if (mode == .producer_recover) @as(usize, 1) else 0));
        },
    }
    try std.testing.expect(state.site_stats.?.peak_reserved_bytes <= budget);
    std.debug.print("HTTPS pages {s}: offers={d} jobs={d} deliveries={d} messages={d} endpoint_closed={} owned_transport_stop/refused\n", .{ @tagName(mode), state.offers, state.job_count, state.deliveries, state.messages, state.closed });
}
const Peer = struct {
    transport: ?*https.Transport = null,
    site: ?*https.Site = null,
    observer: ?*anyopaque = null,
    fn create(allocator: std.mem.Allocator, app: *z.App) !Peer {
        var out: Peer = .{};
        errdefer out.close();
        out.transport = try https.Transport.create(allocator, app, .{ .material = .{ .certificate_pem = certificate, .private_key_pem = private_key } });
        out.site = try https.Site.createOnTransport(allocator, app, out.transport.?, .{ .mount_prefix = "/private/", .bearer = .{0x54} ** 32, .resources = &.{.{ .path = "/peer", .mime = "text/plain", .bytes = "must never reach this peer" }} });
        out.observer = zhr_page_observer_new(out.transport.?.handle.?) orelse return error.PeerObserverFailed;
        return out;
    }
    fn close(self: *Peer) void {
        if (self.site) |site| {
            self.site = null;
            _ = site.close() catch unreachable;
        }
        if (self.transport) |transport| {
            self.transport = null;
            _ = transport.close() catch unreachable;
        }
        if (self.observer) |observer| {
            self.observer = null;
            zhr_page_observer_release(observer);
        }
    }
};
const ListenerCheck = struct {
    port: u16,
    result: c_int = -1,
    fn worker(self: *ListenerCheck) void {
        self.result = zhr_page_connect_refused(self.port);
    }
    fn execute(port: u16) !void {
        var self: ListenerCheck = .{ .port = port };
        const thread = try std.Thread.spawn(.{}, worker, .{&self});
        thread.join(); // Explicit driver check, only after App.run/finish.
        try std.testing.expectEqual(@as(c_int, 0), self.result);
    }
};
const TransportConstruction = struct {
    backing: std.mem.Allocator,
    app: *z.App,
    options: *https.Transport.Options,
    action: enum { mutate_options, stop_alloc, close_free, quit_free },
    transport: ?*https.Transport = null,
    allocations: usize = 0,
    free_calls: usize = 0,
    closed: usize = 0,
    wrong_closed: usize = 0,
    failure: ?anyerror = null,
    fn good(context: *anyopaque) void {
        const self: *TransportConstruction = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
    fn wrong(context: *anyopaque) void {
        const self: *TransportConstruction = @ptrCast(@alignCast(context));
        self.wrong_closed += 1;
    }
    fn allocator(self: *TransportConstruction) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *TransportConstruction = @ptrCast(@alignCast(context));
        self.allocations += 1;
        if (self.allocations == 1) switch (self.action) {
            .mutate_options => {
                const invalid: [*]const u8 = @ptrFromInt(1);
                self.options.* = .{ .material = .{ .certificate_pem = invalid[0..1], .private_key_pem = invalid[0..1] }, .limits = .{ .bytes = 1 }, .on_closed = .{ .context = self, .notify = wrong } };
            },
            .stop_alloc => self.app.quit(),
            else => {},
        };
        return self.backing.rawAlloc(bytes, alignment, ra);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *TransportConstruction = @ptrCast(@alignCast(context));
        if (self.transport) |transport| {
            if (bytes.ptr == @as([*]u8, @ptrCast(transport))) {
                self.transport = null;
                self.free_calls += 1;
                if (transport.handle != null or transport.on_closed != null or transport.stop_token != null) self.failure = error.TransportNotWithdrawn;
                const result = transport.close() catch |err| result: {
                    self.failure = err;
                    break :result https.CloseResult.deferred;
                };
                if (result != .closed) self.failure = error.TransportFinalCloseNotIdempotent;
                if (self.action == .quit_free) self.app.quit();
            }
        }
        self.backing.rawFree(bytes, alignment, ra);
    }
};
const BindingRevoker = struct {
    backing: std.mem.Allocator,
    transport: ?*https.Transport,
    failure: ?anyerror = null,
    fn allocator(self: *BindingRevoker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *BindingRevoker = @ptrCast(@alignCast(context));
        if (self.transport) |transport| {
            self.transport = null;
            _ = transport.close() catch |failure| {
                self.failure = failure;
                return null;
            };
        }
        return self.backing.rawAlloc(bytes, alignment, ra);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *BindingRevoker = @ptrCast(@alignCast(context));
        self.backing.rawFree(bytes, alignment, ra);
    }
};
fn transportConstructors(allocator: std.mem.Allocator) !void {
    const material: https.Transport.Material = .{ .certificate_pem = certificate, .private_key_pem = private_key };
    for (std.meta.tags(@FieldType(TransportConstruction, "action"))) |action| {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var options: https.Transport.Options = .{ .material = material };
        var probe: TransportConstruction = .{ .backing = allocator, .app = app, .options = &options, .action = action };
        options.on_closed = .{ .context = &probe, .notify = TransportConstruction.good };
        const result = https.Transport.create(probe.allocator(), app, options);
        if (action == .stop_alloc) {
            try std.testing.expectError(error.Closed, result);
            try std.testing.expect(probe.closed == 0 and probe.wrong_closed == 0);
        } else {
            const owner = try result;
            probe.transport = owner;
            const stats = try owner.stats();
            try std.testing.expect(stats.accepting and stats.port != 0 and stats.peak_reserved_bytes <= 64 * 1024);
            _ = try owner.close();
            try std.testing.expect(probe.closed == 1 and probe.wrong_closed == 0 and probe.free_calls == 1);
        }
        if (probe.failure) |failure| return failure;
        try std.testing.expectEqualDeep(https.TransportNativeCounts{}, https.transportNativeCounts());
    }
    for (0..2) |fail_at| {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_at });
        const result = https.Transport.create(failing.allocator(), app, .{ .material = material });
        if (fail_at == 0) try std.testing.expectError(error.OutOfMemory, result) else {
            _ = try (try result).close();
        }
        try std.testing.expectEqualDeep(https.TransportNativeCounts{}, https.transportNativeCounts());
    }
    for ([_]bool{ false, true }) |stop_at_free| {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var options: https.Transport.Options = .{ .material = material };
        var probe: TransportConstruction = .{ .backing = allocator, .app = app, .options = &options, .action = if (stop_at_free) .quit_free else .close_free };
        options.on_closed = .{ .context = &probe, .notify = TransportConstruction.good };
        const owner = try https.Transport.create(probe.allocator(), app, options);
        probe.transport = owner;
        var revoker: BindingRevoker = .{ .backing = allocator, .transport = owner };
        var site_closed: usize = 0;
        try std.testing.expectError(if (stop_at_free) error.Closed else error.InvalidEndpoint, https.Site.createOnTransport(revoker.allocator(), app, owner, .{ .bearer = secret, .resources = &.{.{ .path = "/owned", .bytes = "candidate" }}, .on_closed = .{ .context = &site_closed, .notify = struct {
            fn closed(context: *anyopaque) void {
                const value: *usize = @ptrCast(@alignCast(context));
                value.* += 1;
            }
        }.closed } }));
        if (revoker.failure) |failure| return failure;
        if (probe.failure) |failure| return failure;
        try std.testing.expect(probe.closed == 1 and probe.free_calls == 1 and site_closed == 0 and revoker.transport == null);
        try std.testing.expectEqualDeep(https.TransportNativeCounts{}, https.transportNativeCounts());
        try std.testing.expectEqualDeep(https.NativeCounts{}, https.nativeCounts());
    }
    const app = try z.App.init(allocator);
    defer app.deinit();
    var failure: ?https.Transport.Failure = null;
    try std.testing.expectError(error.TransportBudgetExceeded, https.Transport.createWithFailure(allocator, app, .{ .material = material, .limits = .{ .bytes = 1 } }, &failure));
    try std.testing.expect(failure == null);
    try std.testing.expectError(error.NativeFailure, https.Transport.createWithFailure(allocator, app, .{ .material = .{ .certificate_pem = "-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n", .private_key_pem = private_key } }, &failure));
    try std.testing.expect(failure != null and failure.?.domain != 0);
    try std.testing.expectEqualDeep(https.TransportNativeCounts{}, https.transportNativeCounts());
    std.debug.print("HTTPS Transport: captured Options/first-alloc Stop/last-free close+quit/caller OOM/scoped Site lease revoke+Stop/tiny capacity/real GLib failure; resources0\n", .{});
}
const DirectoryCleanup = struct {
    parent: []const u8,
    path: []const u8,
    failure: ?anyerror = null,
    fn worker(self: *DirectoryCleanup) void {
        self.remove() catch |err| {
            self.failure = err;
        };
    }
    fn remove(self: *DirectoryCleanup) !void {
        if (!std.mem.eql(u8, std.fs.path.dirname(self.path) orelse return error.InvalidCleanupPath, self.parent) or
            !std.mem.startsWith(u8, std.fs.path.basename(self.path), "https-page-")) return error.InvalidCleanupPath;
        // Only this run's exact prepared directory, after all native counts=0.
        // Never enumerate or remove the shared evidence/cache parent.
        try std.fs.cwd().deleteTree(self.path);
    }
    fn execute(parent: []const u8, path: []const u8) !void {
        var self: DirectoryCleanup = .{ .parent = parent, .path = path };
        const thread = try std.Thread.spawn(.{}, worker, .{&self});
        thread.join();
        if (self.failure) |err| return err;
    }
};
fn drain() !void {
    var expired = false;
    const source = g_timeout_add(3000, struct {
        fn timeout(ptr: *anyopaque) callconv(.c) c_int {
            const value: *bool = @ptrCast(@alignCast(ptr));
            value.* = true;
            return 0;
        }
    }.timeout, &expired);
    defer if (!expired) {
        _ = g_source_remove(source);
    };
    while (!expired) {
        var profiles: u32 = 0;
        var contexts: u32 = 0;
        var bytes: usize = 0;
        zwk_profile_counts(&profiles, &contexts, &bytes);
        const native = https.nativeCounts();
        const files = https.files.counts();
        const views = web.resourceCounts();
        const transports = https.transportNativeCounts();
        if (profiles == 0 and contexts == 0 and bytes == 0 and native.owners == 0 and native.gates == 0 and native.operations == 0 and native.tickets == 0 and native.requested_bytes == 0 and native.queued_payload_reservation == 0 and files.physical == 0 and files.controls == 0 and files.budgets == 0 and files.candidates == 0 and views.states == 0 and views.handlers == 0 and views.controllers == 0 and transports.owners == 0 and transports.servers == 0 and transports.bytes == 0 and zhr_page_observer_count() == 0) return;
        _ = g_main_context_iteration(null, 1);
    }
    return error.FinalNativeReferencesRemain;
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    if (std.posix.getenv("ZIGGURAT_HTTPS_TRANSPORT_CONSTRUCTORS_ONLY") != null) return transportConstructors(allocator);
    const root = std.posix.getenv("ZIGGURAT_PROFILE_TEST_ROOT") orelse return error.MissingProfileRoot;
    const extension = std.posix.getenv("ZIGGURAT_REQUEST_POLICY_EXTENSION") orelse return error.MissingExtension;
    const selected_mode = std.posix.getenv("ZIGGURAT_HTTPS_PAGE_MODE");
    if (selected_mode) |selected| {
        _ = std.meta.stringToEnum(Mode, selected) orelse return error.UnknownMode;
    }
    for (std.meta.tags(Mode)) |mode| {
        if (selected_mode) |selected| if (!std.mem.eql(u8, selected, @tagName(mode))) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/https-page-{s}-{d}", .{ root, @tagName(mode), std.time.nanoTimestamp() });
        defer allocator.free(path);
        _ = try web.profile_storage.Prepared.requiredBytes(path, .{});
        var preparation: Preparation = .{ .allocator = allocator, .main = std.Thread.getCurrentId(), .path = path };
        // Prepare and adopt before App exists, so construction performs no
        // owner-loop filesystem wait. Cleanup also runs after App deinit/drain.
        preparation.open() catch |err| {
            try DirectoryCleanup.execute(root, path);
            return err;
        };
        var late_ticket: ?https.Endpoint.Ticket = null;
        const result = run(allocator, &preparation.value.?, extension, mode, &late_ticket);
        if (late_ticket) |*ticket| {
            // App and Site are already gone. Only C ownership may be accessed.
            try std.testing.expectError(error.Closed, ticket.respondBorrowed(.{ .bytes = "cannot retry" }));
            try std.testing.expect(ticket.native_ticket != null);
            ticket.deinit();
        }
        try preparation.value.?.close();
        try drain();
        try DirectoryCleanup.execute(root, path);
        try result;
    }
    std.debug.print("HTTPS pages: memory/Ticket/private-file/HEAD, independent cancel and Stop, post Closed, missing Bearer, all final HTTP/file/Profile/View refs=0\n", .{});
}

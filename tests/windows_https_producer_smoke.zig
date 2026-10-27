//! Real Windows WebView HTTPS workflow. Test-only certificate observation is
//! linked by this target; production TLS and browser trust are unchanged.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const https = @import("ziggurat_https_resources");
const stream = @import("ziggurat_native_stream");
const Watchdog = @import("watchdog.zig").Watchdog;
const w = @import("ziggurat_c_win32");
extern fn zwv_test_credential_probe_install(*anyopaque, [*]const [*:0]const u16, u32, c_int, *?*anyopaque) i32;
extern fn zwv_test_credential_probe_counts(*anyopaque, *u32, *u32, *u32, *u32, *u32) void;
extern fn zwv_test_credential_probe_release(*anyopaque) void;
extern fn zwv_test_credential_live_probes() u32;
extern fn zwv_browser_process_id(*anyopaque, *c_uint) i32;
extern fn zhtp_provider_count() u32;
extern fn zhtp_domain_count() u32;
const Mode = enum { constructors, complete, cancel, stop, post_closed, endpoint_close, navigate, recover, wrong_certificate, close_listener };
const body_length = 131109;
const large_length = 4 * 1024 * 1024;
const secret: [32]u8 = @splat(0xa7);

const Preparation = struct {
    main: std.Thread.Id,
    directory: []const u8,
    wrong_certificate: bool,
    prepared: ?https.Transport.Prepared = null,
    ready: zio.Semaphore = .{},
    go: zio.Semaphore = .{},
    abandoned: std.atomic.Value(bool) = .init(false),
    failure: std.atomic.Value(u16) = .init(0),
    thread: ?std.Thread = null,
    fn worker(self: *Preparation) void {
        self.prepare() catch |err| {
            self.failure.store(@intFromError(err), .release);
            self.ready.post();
            return;
        };
        self.ready.post();
        self.go.wait();
        if (!self.abandoned.load(.acquire)) self.prepared.?.driver.run(null) catch |err| self.failure.store(@intFromError(err), .release);
        self.prepared.?.driver.deinit() catch |err| self.failure.store(@intFromError(err), .release);
    }
    fn prepare(self: *Preparation) !void {
        var directory = try std.Io.Dir.cwd().openDir(zio.io(), self.directory, .{});
        defer directory.close();
        var certificate: [16384]u8 = undefined;
        var private_key: [16384]u8 = undefined;
        defer std.crypto.secureZero(u8, &private_key);
        const cert = try read(directory, if (self.wrong_certificate) "other-cert.pem" else "server-cert.pem", &certificate);
        const key = try read(directory, if (self.wrong_certificate) "other-key.pem" else "server-key.pem", &private_key);
        self.prepared = try https.Transport.prepareOnWorker(self.main, .{ .certificate_pem = cert, .private_key_pem = key }, .{ .bytes = 8 * 1024 * 1024 }, null);
    }
    fn read(directory: std.Io.Dir, path: []const u8, buffer: []u8) ![]const u8 {
        const file = try directory.openFile(zio.io(), path, .{});
        defer file.close();
        const n = try zio.readAll(file, buffer);
        if (n == 0 or n == buffer.len) return error.InvalidFixtureMaterial;
        return buffer[0..n];
    }
    fn start(self: *Preparation) !void {
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        self.ready.wait(); // Before App initialization: no UI/App loop exists.
        if (self.failure.load(.acquire) != 0) return @errorFromInt(self.failure.load(.acquire));
    }
    fn finish(self: *Preparation) !void {
        if (self.prepared) |*pair| pair.listener.deinit();
        self.abandoned.store(true, .release);
        self.go.post();
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.failure.load(.acquire) != 0) return @errorFromInt(self.failure.load(.acquire));
    }
};

const Job = struct {
    state: *State,
    ticket: https.Endpoint.Ticket,
    kind: enum { body, zero, head, cancel, stop, closed, endpoint_close, navigate, recover, file, file_head, file_unsat, close_listener },
    length: u64,
    file_request: ?https.FileRequest = null,
    file_response: ?https.PreparedFileResponse = null,
    source: ?stream.Source = null,
    control: ?https.files.Control = null,
    gate: zio.Semaphore = .{},
    retired: zio.Semaphore = .{},
    thread: ?std.Thread = null,
    failure: std.atomic.Value(u16) = .init(0),
    generated: std.atomic.Value(u64) = .init(0),
    completed: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    head_skipped: std.atomic.Value(bool) = .init(false),
    post_closed: std.atomic.Value(bool) = .init(false),
    fn worker(self: *Job) void {
        self.produce() catch |err| {
            self.failure.store(@intFromError(err), .release);
            self.state.app.post(.{ .context = self, .call = workerFailed }) catch {};
        };
    }
    fn workerFailed(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.state.fail(@errorFromInt(self.failure.load(.acquire)));
    }
    fn produce(self: *Job) !void {
        if (self.kind == .file or self.kind == .file_head or self.kind == .file_unsat) return self.produceFile();
        var pair = try stream.prepare(self.state.app.owner, self.length, large_length);
        defer pair.writer.deinit();
        self.source = pair.source;
        pair.source.native = null;
        pair.source.length = 0;
        if (self.kind == .closed) self.gate.wait();
        self.state.app.post(.{ .context = self, .call = deliver }) catch |err| {
            const retained = self.ticket.native_ticket != null and self.source.?.native != null;
            self.source.?.deinit();
            self.source = null;
            self.ticket.deinit();
            if (err != error.Closed or self.kind != .closed or !retained) return error.PostOwnershipChanged;
            self.post_closed.store(true, .release);
            return;
        };
        if (self.kind == .closed) return error.ClosedPostAccepted;
        if (self.kind == .head or self.kind == .stop or self.kind == .endpoint_close or self.kind == .navigate or self.kind == .recover) self.gate.wait();
        if (self.kind == .head) {
            // HEAD commits the real source but never invokes generation. A
            // completed response can release its reader before this worker runs.
            self.head_skipped.store(true, .release);
            return;
        }
        const disposition = pair.writer.waitAccepted() catch |err| return self.expectedCancel(err);
        if (disposition != .body) return error.UnexpectedProducerHead;
        var bytes: [stream.chunk_bytes]u8 = undefined;
        var at: u64 = 0;
        while (at < self.length) {
            const n: usize = @intCast(@min(bytes.len, self.length - at));
            for (bytes[0..n], 0..) |*byte, i| byte.* = @intCast((at + i) % 251);
            pair.writer.writeAll(bytes[0..n]) catch |err| return self.expectedCancel(err);
            at += n;
            self.generated.store(at, .release);
            if (self.kind == .cancel and at == n) self.gate.wait();
        }
        try pair.writer.finish();
        self.completed.store(true, .release);
        if (self.kind != .body and self.kind != .zero and self.kind != .close_listener) return error.ExpectedProducerCancellation;
    }
    fn produceFile(self: *Job) !void {
        const file = try std.Io.Dir.cwd().openFile(zio.io(), self.state.file_path, .{});
        defer file.close();
        try zio.posix.seekTo(file.handle, 3);
        const prepared = try https.PreparedFileResponse.prepare(self.state.app.owner, file, large_length, self.file_request.?);
        var pump = prepared.pump;
        defer if (pump) |*value| value.deinit();
        if (try zio.posix.position(file.handle) != 3 or prepared.response.total != large_length) return error.FileMetadataChanged;
        if (self.kind == .file_unsat) {
            if (prepared.response.source != null or pump != null or prepared.response.selection != .unsatisfiable) return error.UnsatisfiableCreatedSource;
        } else if (prepared.response.source == null or pump == null) return error.MissingPreparedFile;
        self.file_response = prepared.response;
        self.state.app.post(.{ .context = self, .call = deliverFile }) catch |err| {
            self.file_response.?.deinit();
            self.ticket.deinit();
            return err;
        };
        if (self.kind == .file_head) {
            // Keep physical producer/storage alive through actual HEAD, then
            // retire without invoking file pumping or any ReadFile operation.
            self.gate.wait();
            self.head_skipped.store(true, .release);
        } else if (pump) |*value| {
            try value.pump();
            self.completed.store(true, .release);
        } else self.completed.store(true, .release);
        if (try zio.posix.position(file.handle) != 3) return error.FileCursorChanged;
    }
    fn deliverFile(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        var receipt = self.ticket.respondPreparedFile(&self.file_response.?, .{}) catch |err| {
            self.file_response.?.deinit();
            self.ticket.deinit();
            return self.state.fail(err);
        };
        receipt.deinit();
        if (self.file_response.?.ready or self.file_response.?.source != null or self.ticket.native_ticket != null) return self.state.fail(error.PreparedFileNotConsumed);
        self.state.deliveries += 1;
    }
    fn expectedCancel(self: *Job, err: anyerror) !void {
        if (err != error.Cancelled or (self.kind != .cancel and self.kind != .stop and self.kind != .endpoint_close and self.kind != .navigate and self.kind != .recover)) return err;
        self.cancelled.store(true, .release);
        self.retired.wait(); // Keep actual physical Writer ref after logical cancel.
    }
    fn deliver(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        const state = self.state;
        if (self.kind == .close_listener) {
            const transport = state.transport orelse return state.fail(error.TransportAlreadyClosed);
            state.transport = null;
            _ = transport.close() catch |err| return state.fail(err);
            // The existing Ticket's claimed Endpoint duty survives this close.
        }
        var receipt = self.ticket.respondSource(.{ .length = 1, .mime = "application/octet-stream", .headers = &https.site_routes.policy_headers }, &self.source.?, .{ .file_control = true }) catch |err| {
            self.source.?.deinit();
            self.source = null;
            self.ticket.deinit();
            return state.fail(err);
        };
        self.control = receipt.control;
        receipt.control = null;
        receipt.deinit();
        state.deliveries += 1;
        switch (self.kind) {
            .head => {}, // Retain the producer until the real HEAD has completed.
            .stop => {
                if (https.files.counts().physical == 0) return state.fail(error.PhysicalSourceMissing);
                state.logical_cancel_retained = true;
                state.done = true;
                state.app.quit();
            },
            .endpoint_close => {
                _ = state.site.?.close() catch |err| return state.fail(err);
                if (https.files.counts().physical == 0) return state.fail(error.PhysicalSourceReturnedEarly);
                state.logical_cancel_retained = true;
                self.gate.post();
            },
            .navigate => {
                self.control.?.cancel();
                self.gate.post();
                state.view.navigateRemote(state.restart_url) catch |err| return state.fail(err);
            },
            .recover => {
                self.control.?.cancel();
                self.gate.post();
                if (w.TerminateProcess(state.browsers[state.native_count - 1].?, 1) == 0) state.fail(error.BrowserTerminationFailed);
            },
            else => {},
        }
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    view: web.View = undefined,
    site: ?*https.Site = null,
    transport: ?*https.Transport = null,
    mode: Mode,
    origin: []const u8,
    wide_origin: [*:0]const u16,
    restart_url: []const u8,
    file_path: []const u8,
    probes: [2]?*anyopaque = @splat(null),
    browsers: [2]?*anyopaque = @splat(null),
    native_count: usize = 0,
    ready: usize = 0,
    process_failures: usize = 0,
    offers: usize = 0,
    messages: usize = 0,
    deliveries: usize = 0,
    job_count: usize = 0,
    jobs: [8]Job = undefined,
    closed: bool = false,
    done: bool = false,
    logical_cancel_retained: bool = false,
    failure: ?anyerror = null,
    cleanup_failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("Windows HTTPS producer {s}: {s}\n", .{ @tagName(self.mode), @errorName(err) });
        self.app.quit();
    }
    fn request(context: *anyopaque, request_value: https.Site.Request, offer: https.Endpoint.Offer) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.requestInner(request_value, offer) catch |err| self.fail(err);
    }
    fn requestInner(self: *State, request_value: https.Site.Request, offer: https.Endpoint.Offer) !void {
        self.offers += 1;
        if (self.job_count == self.jobs.len) return error.TooManyProducerRequests;
        if (std.mem.eql(u8, request_value.path, "/file")) {
            const file_request = try https.FileRequest.capture(request_value.method, request_value.headers, .{ .etag = "\"windows-private-v1\"" });
            const kind: @FieldType(Job, "kind") = if (request_value.method == .head) .file_head else if ((try file_request.select(large_length)) == .unsatisfiable) .file_unsat else .file;
            const job = &self.jobs[self.job_count];
            job.* = .{ .state = self, .ticket = try offer.deferRequest(), .kind = kind, .length = 0, .file_request = file_request };
            self.job_count += 1;
            job.thread = std.Thread.spawn(.{}, Job.worker, .{job}) catch |err| {
                job.ticket.deinit();
                return err;
            };
            return;
        }
        const zero = std.mem.eql(u8, request_value.path, "/zero");
        if (!zero and !std.mem.eql(u8, request_value.path, "/producer")) return error.UnexpectedRoute;
        const first = self.job_count == 0;
        const kind: @FieldType(Job, "kind") = if (request_value.method == .head) .head else if (zero) .zero else switch (self.mode) {
            .constructors => unreachable,
            .complete, .wrong_certificate => .body,
            .cancel => .cancel,
            .stop => .stop,
            .post_closed => .closed,
            .endpoint_close => .endpoint_close,
            .navigate => if (first) .navigate else .body,
            .recover => if (first) .recover else .body,
            .close_listener => .close_listener,
        };
        const job = &self.jobs[self.job_count];
        job.* = .{ .state = self, .ticket = try offer.deferRequest(), .kind = kind, .length = if (zero) 0 else if (kind == .cancel) large_length else body_length };
        self.job_count += 1;
        job.thread = std.Thread.spawn(.{}, Job.worker, .{job}) catch |err| {
            job.ticket.deinit();
            return err;
        };
        if (kind == .closed) {
            self.done = true;
            self.app.quit();
        }
    }
    fn siteClosed(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        std.debug.assert(!self.closed);
        self.site = null;
        self.closed = true;
    }
    fn siteError(context: *anyopaque, _: https.Site.Request, err: anyerror) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.fail(err);
    }
    fn event(context: *anyopaque, view: *web.View, event_value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (event_value) {
            .ready => {
                self.ready += 1;
                if (self.native_count == self.probes.len) return self.fail(error.TooManyNativeEpochs);
                const index = self.native_count;
                if (zwv_test_credential_probe_install(view.native.?, &.{self.wide_origin}, 1, 1, &self.probes[index]) < 0) return self.fail(error.ProbeInstallFailed);
                self.native_count += 1;
                var pid: c_uint = 0;
                if (zwv_browser_process_id(view.native.?, &pid) < 0 or pid == 0) return self.fail(error.BrowserPidMissing);
                self.browsers[index] = w.OpenProcess(w.SYNCHRONIZE | w.PROCESS_TERMINATE, w.FALSE, pid) orelse return self.fail(error.BrowserHandleMissing);
            },
            .process_failed => {
                if (self.mode != .recover or self.process_failures != 0) return self.fail(error.UnexpectedProcessFailure);
                self.process_failures += 1;
                view.recover() catch |err| self.fail(err);
            },
            .failed => self.fail(error.NativeViewFailed),
            .message => |message| {
                self.messages += 1;
                if (std.mem.startsWith(u8, message, "error:")) {
                    std.debug.print("actual page failure: {s}\n", .{message});
                    return self.fail(error.PageOracleFailed);
                }
                const expected = if (self.mode == .cancel or self.mode == .endpoint_close) "cancelled" else "complete";
                if (!std.mem.eql(u8, message, expected)) return self.fail(error.UnexpectedMessage);
                if (self.mode == .cancel) {
                    self.jobs[0].control.?.cancel();
                    if (https.files.counts().physical == 0) return self.fail(error.PhysicalSourceReturnedEarly);
                    self.logical_cancel_retained = true;
                    self.jobs[0].gate.post();
                }
                self.done = true;
                self.app.quit();
            },
            else => {},
        }
    }
    fn page(context: *anyopaque, _: *web.View, event_value: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (event_value == .completed and !event_value.completed.success and self.mode == .wrong_certificate) {
            self.done = true;
            self.app.quit();
        }
    }
    fn finishJobs(self: *State) !void {
        // App.run has returned. All accepted posts ran; late post failures keep
        // their input owners. Join only now, before App.deinit invalidates App.
        var failure: ?anyerror = null;
        for (self.jobs[0..self.job_count]) |*job| {
            if (job.control) |control| control.cancel();
            job.gate.post();
            job.retired.post();
        }
        for (self.jobs[0..self.job_count]) |*job| {
            if (job.thread) |thread| thread.join();
            job.thread = null;
            if (job.source) |*source| source.deinit();
            job.source = null;
            if (job.file_response) |*response| response.deinit();
            job.file_response = null;
            job.ticket.deinit();
            if (job.control) |*control| control.deinit();
            job.control = null;
            if (job.failure.load(.acquire) != 0 and failure == null) failure = @errorFromInt(job.failure.load(.acquire));
        }
        if (failure) |err| return err;
    }
    fn waitBrowsers(self: *State) void {
        for (&self.browsers) |*browser| if (browser.*) |handle| {
            if (w.WaitForSingleObject(handle, 10_000) != w.WAIT_OBJECT_0) self.cleanup_failure = error.BrowserShutdownUnconfirmed;
            _ = w.CloseHandle(handle);
            browser.* = null;
        };
    }
    fn releaseCallerReferences(self: *State) void {
        for (&self.browsers) |*browser| if (browser.*) |handle| {
            _ = w.CloseHandle(handle);
            browser.* = null;
        };
        for (&self.probes) |*probe| if (probe.*) |handle| {
            zwv_test_credential_probe_release(handle);
            probe.* = null;
        };
    }
    fn releaseObservers(self: *State) !void {
        var allowed: u32 = 0;
        var denied: u32 = 0;
        var bad = false;
        for (&self.probes) |*probe| if (probe.*) |handle| {
            var records: u32 = 0;
            var yes: u32 = 0;
            var no: u32 = 0;
            var refs: u32 = 0;
            var overflow: u32 = 0;
            zwv_test_credential_probe_counts(handle, &records, &yes, &no, &refs, &overflow);
            allowed += yes;
            denied += no;
            bad = bad or refs != 1 or overflow != 0;
            zwv_test_credential_probe_release(handle);
            probe.* = null;
        };
        if (bad or zwv_test_credential_live_probes() != 0) return error.ProbeRefsRemain;
        if (self.mode == .wrong_certificate) {
            if (allowed != 0 or denied == 0) return error.CertificatePinNotEnforced;
        } else if (allowed == 0) return error.RealTlsNotObserved;
    }
};

fn program(mode: Mode) []const u8 {
    return switch (mode) {
        .constructors => unreachable,
        .complete =>
        \\(async()=>{try{let r=await fetch('/private/producer');if(r.status!==200||r.headers.get('Content-Length')!=='131109')throw 'metadata';let b=new Uint8Array(await r.arrayBuffer());if(b.length!==131109)throw 'length';for(let i=0;i<b.length;i++)if(b[i]!==i%251)throw 'byte:'+i;let e=await fetch('/private/zero');if(e.headers.get('Content-Length')!=='0'||(await e.arrayBuffer()).byteLength!==0)throw 'zero';let h=await fetch('/private/producer',{method:'HEAD'});if(h.headers.get('Content-Length')!=='131109'||(await h.arrayBuffer()).byteLength!==0)throw 'head';let f=await fetch('/private/file',{headers:{Range:'bytes=17-65557'}}),v=new Uint8Array(await f.arrayBuffer());if(f.status!==206||f.headers.get('Content-Range')!=='bytes 17-65557/4194304'||v.length!==65541)throw 'range';for(let i=0;i<v.length;i++)if(v[i]!==((17+i)%251))throw 'file:'+i;let fh=await fetch('/private/file',{method:'HEAD',headers:{Range:'bytes=17-65557'}});if(fh.status!==200||fh.headers.get('Content-Length')!=='4194304'||(await fh.arrayBuffer()).byteLength!==0)throw 'file HEAD';let u=await fetch('/private/file',{headers:{Range:'bytes=9000000-'}});if(u.status!==416||u.headers.get('Content-Range')!=='bytes */4194304'||(await u.arrayBuffer()).byteLength!==0)throw '416';chrome.webview.postMessage('complete')}catch(e){chrome.webview.postMessage('error:'+e)}})();
        ,
        .cancel =>
        \\(async()=>{try{let r=await fetch('/private/producer'),s=r.body.getReader(),x=await s.read();if(x.done||!x.value.length)throw 'empty';for(let i=0;i<x.value.length;i++)if(x.value[i]!==i%251)throw 'byte';await s.cancel();chrome.webview.postMessage('cancelled')}catch(e){chrome.webview.postMessage('error:'+e)}})();
        ,
        .stop, .post_closed => "fetch('/private/producer').then(r=>r.arrayBuffer());",
        .endpoint_close => "fetch('/private/producer').then(r=>r.arrayBuffer()).then(()=>chrome.webview.postMessage('error:unexpected body'),()=>chrome.webview.postMessage('cancelled'));",
        .navigate, .recover, .close_listener =>
        \\(async()=>{try{let r=await fetch('/private/producer'),b=new Uint8Array(await r.arrayBuffer());if(b.length!==131109)throw 'length';for(let i=0;i<b.length;i++)if(b[i]!==i%251)throw 'byte:'+i;chrome.webview.postMessage('complete')}catch(e){if(location.search)chrome.webview.postMessage('error:'+e)}})();
        ,
        .wrong_certificate => "chrome.webview.postMessage('error:wrong certificate loaded');",
    };
}

fn runtime(allocator: std.mem.Allocator, mode: Mode, profile: []const u8, file_path: []const u8, prep: *Preparation) !void {
    const app = try z.App.init(allocator);
    var owns_app = true;
    defer if (owns_app) app.deinit();
    // Cleanup ordering is deliberate: all own workers finish before App deinit.
    defer prep.finish() catch |err| std.debug.panic("driver cleanup: {s}", .{@errorName(err)});
    var transport_closed = false;
    const transport = try https.Transport.adopt(allocator, app, &prep.prepared.?.listener, .{ .on_closed = .{ .context = &transport_closed, .notify = struct {
        fn closed(context: *anyopaque) void {
            const value: *bool = @ptrCast(@alignCast(context));
            std.debug.assert(!value.*);
            value.* = true;
        }
    }.closed } });
    defer if (!transport_closed) {
        _ = transport.close() catch unreachable;
    };
    var origin_buffer: [30]u8 = undefined;
    const origin = try transport.origin(&origin_buffer);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, origin);
    defer allocator.free(wide);
    const url = try std.fmt.allocPrint(allocator, "{s}/private/start", .{origin});
    defer allocator.free(url);
    const restart = try std.fmt.allocPrint(allocator, "{s}?generation=2", .{url});
    defer allocator.free(restart);
    var state: State = .{ .allocator = allocator, .app = app, .mode = mode, .origin = origin, .wide_origin = wide.ptr, .restart_url = restart, .file_path = file_path, .transport = transport };
    defer state.releaseCallerReferences();
    defer {
        // Once a View can exist, close/drain Core's mailbox before joining a
        // worker that may be waiting for one of those accepted deliveries.
        // Every callback's borrowed URI storage still exists here.
        if (owns_app) app.quit();
        if (state.site) |site| _ = site.close() catch .deferred;
        state.finishJobs() catch {};
        if (!transport_closed) _ = transport.close() catch .deferred;
        prep.finish() catch {};
        if (owns_app) app.deinit();
        owns_app = false;
    }
    const resources = [_]https.site_routes.Route{
        .{ .path = "/start", .mime = "text/html", .bytes = "<!doctype html><meta charset='utf-8'><script src='/private/app.js'></script>" },
        .{ .path = "/app.js", .mime = "text/javascript", .bytes = program(mode) },
    };
    state.site = try https.Site.createOnTransport(allocator, app, transport, .{ .mount_prefix = "/private/", .bearer = secret, .range_requests = true, .resources = &resources, .on_resource = .{ .context = &state, .call = State.request }, .on_error = .{ .context = &state, .call = State.siteError }, .on_closed = .{ .context = &state, .notify = State.siteClosed }, .limits = .{ .bytes = 512 * 1024, .max_pending = 8, .max_file_streams = 8, .max_response_bytes = 64 * 1024, .max_file_bytes = large_length } });
    defer if (state.site) |site| {
        _ = site.close() catch unreachable;
    };
    state.view = web.View.init(allocator, &state, State.event);
    const window = try app.createWindow(.{ .width = 320, .height = 200 });
    try state.view.attach(window, .{ .html = "", .user_data_folder = profile, .remote = .{ .url = url, .origins = &.{.{ .origin = origin, .ipc = true, .request_headers = &.{.{ .name = "Range" }} }}, .credentials = .profile, .allow_insecure_loopback = true, .request_credentials = &.{.{ .origin = origin, .bearer = secret }} }, .page_listener = .{ .context = &state, .event = State.page } });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    prep.go.post();
    try app.run();
    watchdog.stop();
    if (mode == .cancel or mode == .stop or mode == .endpoint_close or mode == .navigate or mode == .recover) {
        if (https.files.counts().physical == 0) return error.CancelledWriterReturnedPhysicalCredit;
    }
    if (state.site) |site| _ = try site.close();
    try state.finishJobs();
    // These late generated post failures still used a valid stopped App.
    try prep.finish();
    if (!transport_closed) _ = try transport.close();
    if (watchdog.expired) return error.WatchdogExpired;
    if (state.failure) |err| return err;
    if (!state.done) return error.NoTerminalResult;
    for (state.jobs[0..state.job_count]) |*job| {
        std.debug.print("Windows source {s}: kind={s} generated={d} finished={} cancelled={} HEAD0={} post_closed={}\n", .{ @tagName(mode), @tagName(job.kind), job.generated.load(.acquire), job.completed.load(.acquire), job.cancelled.load(.acquire), job.head_skipped.load(.acquire), job.post_closed.load(.acquire) });
    }
    switch (mode) {
        .constructors => unreachable,
        .complete => if (state.offers != 6 or state.deliveries != 6 or state.messages != 1 or !state.jobs[0].completed.load(.acquire) or !state.jobs[1].completed.load(.acquire) or !state.jobs[2].head_skipped.load(.acquire) or state.jobs[2].generated.load(.acquire) != 0 or !state.jobs[3].completed.load(.acquire) or !state.jobs[4].head_skipped.load(.acquire) or !state.jobs[5].completed.load(.acquire)) return error.CompleteStagesMissing,
        .cancel, .stop, .endpoint_close => if (state.offers != 1 or !state.logical_cancel_retained or !state.jobs[0].cancelled.load(.acquire)) return error.CancellationStagesMissing,
        .post_closed => if (state.offers != 1 or !state.jobs[0].post_closed.load(.acquire)) return error.PostClosedStageMissing,
        .navigate, .recover => if (state.offers != 2 or !state.jobs[0].cancelled.load(.acquire) or !state.jobs[1].completed.load(.acquire) or state.messages != 1 or (mode == .recover and state.process_failures != 1)) return error.GenerationStageMissing,
        .wrong_certificate => if (state.offers != 0 or state.messages != 0) return error.WrongCertificateReachedHandler,
        .close_listener => if (state.offers != 1 or state.deliveries != 1 or !state.jobs[0].completed.load(.acquire) or state.messages != 1 or !transport_closed) return error.ClaimedTicketFailedAfterListenerClose,
    }
    if (!state.closed or https.files.counts().physical != 0) return error.FinalPhysicalRefsRemain;
    if (app.resourceStats().allocated_records != 0) return error.CoreNativeRecordsRemain;
    // No own worker or accepted App post remains. Browser/observer late refs
    // are independent C-only state and retire after the Core lifetime ends.
    app.deinit();
    owns_app = false;
    const wait = std.Thread.spawn(.{}, State.waitBrowsers, .{&state}) catch |err| {
        state.releaseCallerReferences();
        return err;
    };
    wait.join();
    try state.releaseObservers();
    if (state.cleanup_failure) |err| return err;
    const views = web.resourceCounts();
    if (views.states != 0 or views.handlers != 0 or views.controllers != 0) return error.NativeWebViewRefsRemain;
    const native = https.Transport.driverNativeCounts();
    const endpoint = https.nativeCounts();
    if (native.servers != 0 or native.payloads != 0 or native.envelopes != 0 or native.connections != 0 or native.bytes != 0 or endpoint.owners != 0 or endpoint.operations != 0 or endpoint.tickets != 0 or endpoint.requested_bytes != 0 or zhtp_provider_count() != 0 or zhtp_domain_count() != 0) return error.NativeDriverRefsRemain;
    std.debug.print("windows_https_producer_shutdown=confirmed mode={s}\n", .{@tagName(mode)});
}

const ConstructorProbe = struct {
    backing: std.mem.Allocator,
    app: *z.App,
    listener: *https.Transport.Listener,
    options: *https.Transport.AdoptOptions,
    action: enum { mutate_options, revoke_listener, stop_allocate, close_free, stop_free },
    entered: bool = false,
    closed: usize = 0,
    wrong_closed: usize = 0,
    owner: ?*https.Transport = null,
    failure: ?anyerror = null,
    fn good(context: *anyopaque) void {
        const self: *ConstructorProbe = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
    fn wrong(context: *anyopaque) void {
        const self: *ConstructorProbe = @ptrCast(@alignCast(context));
        self.wrong_closed += 1;
    }
    fn value(self: *ConstructorProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn allocate(context: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ConstructorProbe = @ptrCast(@alignCast(context));
        if (!self.entered) {
            self.entered = true;
            switch (self.action) {
                .mutate_options => self.options.* = .{ .limits = .{ .bytes = 1 }, .on_closed = .{ .context = self, .notify = wrong } },
                .revoke_listener => self.listener.deinit(),
                .stop_allocate => self.app.quit(),
                .close_free, .stop_free => {},
            }
        }
        return self.backing.rawAlloc(bytes, alignment, ra);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *ConstructorProbe = @ptrCast(@alignCast(context));
        if (self.owner) |owner| {
            self.owner = null;
            if (owner.handle != null or owner.on_closed != null or owner.stop_token != null) self.failure = error.TransportNotWithdrawn;
            if (self.action == .close_free) {
                const result = owner.close() catch |err| {
                    self.failure = err;
                    self.backing.rawFree(bytes, alignment, ra);
                    return;
                };
                if (result != .closed) self.failure = error.TransportCloseReentered;
            } else if (self.action == .stop_free) self.app.quit();
        }
        self.backing.rawFree(bytes, alignment, ra);
    }
};

fn adoptionConstructors(allocator: std.mem.Allocator, directory: []const u8) !void {
    // These are preparation/never-run exits: Driver has made no App post and
    // never enters run. Its original worker is explicitly retired before App
    // deinit; there is no callback waiting for UI dispatch and no nested loop.
    for ([_]@FieldType(ConstructorProbe, "action"){ .mutate_options, .revoke_listener, .stop_allocate, .close_free, .stop_free }) |action| {
        var prep: Preparation = .{ .main = std.Thread.getCurrentId(), .directory = directory, .wrong_certificate = false };
        try constructionStart(&prep);
        var saved_app: ?*z.App = null;
        defer {
            if (saved_app) |value| value.quit();
            if (prep.thread != null) prep.finish() catch unreachable;
            if (saved_app) |value| value.deinit();
        }
        const app = try z.App.init(allocator);
        saved_app = app;
        var options: https.Transport.AdoptOptions = .{};
        var probe: ConstructorProbe = .{ .backing = allocator, .app = app, .listener = &prep.prepared.?.listener, .options = &options, .action = action };
        options.on_closed = .{ .context = &probe, .notify = ConstructorProbe.good };
        const result = https.Transport.adopt(probe.value(), app, probe.listener, options);
        if (action == .revoke_listener or action == .stop_allocate) {
            if (result) |owner| {
                _ = owner.close() catch .deferred;
                return error.ConstructorRevocationAccepted;
            } else |err| {
                if (err != (if (action == .revoke_listener) error.TransportListenerMoved else error.Closed)) return err;
            }
            if (probe.closed != 0 or probe.wrong_closed != 0) return error.FailedConstructionNotified;
            if ((action == .revoke_listener) != (probe.listener.native == null)) return error.FailedAdoptionConsumedListener;
        } else {
            const owner = try result;
            if (probe.listener.native != null) return error.SuccessfulAdoptionKeptListener;
            if (action == .close_free or action == .stop_free) probe.owner = owner;
            _ = try owner.close();
            if (probe.closed != 1 or probe.wrong_closed != 0) return error.OptionsNotFrozen;
            if (probe.failure) |err| return err;
        }
        app.quit();
        try prep.finish();
        app.deinit();
        saved_app = null;
        try adoptionZero();
        std.debug.print("Windows HTTPS adoption {s} PASS final_refs=0\n", .{@tagName(action)});
    }
    // Only the stable Transport allocation uses this allocator. Stop storage
    // was prepared by App; failure0 must preserve Listener, success1 consumes.
    for (0..2) |fail_at| {
        var prep: Preparation = .{ .main = std.Thread.getCurrentId(), .directory = directory, .wrong_certificate = false };
        try constructionStart(&prep);
        var saved_app: ?*z.App = null;
        defer {
            if (saved_app) |value| value.quit();
            if (prep.thread != null) prep.finish() catch unreachable;
            if (saved_app) |value| value.deinit();
        }
        const app = try z.App.init(allocator);
        saved_app = app;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_at });
        const saved = prep.prepared.?.listener.native.?;
        const result = https.Transport.adopt(failing.allocator(), app, &prep.prepared.?.listener, .{});
        if (fail_at == 0) {
            if (result) |owner| {
                _ = owner.close() catch .deferred;
                return error.ExpectedCallerOom;
            } else |err| if (err != error.OutOfMemory) return err;
            if (prep.prepared.?.listener.native != saved) return error.FailedAdoptionConsumedListener;
        } else {
            const owner = try result;
            if (prep.prepared.?.listener.native != null) return error.SuccessfulAdoptionKeptListener;
            _ = try owner.close();
        }
        app.quit();
        try prep.finish();
        app.deinit();
        saved_app = null;
        try adoptionZero();
        std.debug.print("Windows HTTPS adoption caller_allocation {d} PASS final_refs=0\n", .{fail_at});
    }
    {
        var prep: Preparation = .{ .main = std.Thread.getCurrentId(), .directory = directory, .wrong_certificate = false };
        try constructionStart(&prep);
        var saved_app: ?*z.App = null;
        defer {
            if (saved_app) |value| value.quit();
            if (prep.thread != null) prep.finish() catch unreachable;
            if (saved_app) |value| value.deinit();
        }
        const app = try z.App.init(allocator);
        saved_app = app;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        const saved = prep.prepared.?.listener.native.?;
        if (https.Transport.adopt(failing.allocator(), app, &prep.prepared.?.listener, .{ .limits = .{ .bytes = 1 } })) |owner| {
            _ = owner.close() catch .deferred;
            return error.TinyBudgetAccepted;
        } else |err| if (err != error.TransportBudgetExceeded) return err;
        if (failing.alloc_index != 0 or prep.prepared.?.listener.native != saved) return error.TinyBudgetHadSideEffects;
        app.quit();
        try prep.finish();
        app.deinit();
        saved_app = null;
        try adoptionZero();
        std.debug.print("Windows HTTPS adoption tiny_budget PASS allocations=0 final_refs=0\n", .{});
    }
    std.debug.print("windows_https_producer_shutdown=confirmed mode=constructors\n", .{});
}
fn constructionStart(preparation: *Preparation) !void {
    preparation.start() catch |err| {
        if (preparation.thread) |thread| thread.join();
        preparation.thread = null;
        return err;
    };
}
fn adoptionZero() !void {
    const value = https.Transport.driverNativeCounts();
    const endpoint = https.nativeCounts();
    if (value.servers != 0 or value.payloads != 0 or value.envelopes != 0 or value.connections != 0 or value.bytes != 0 or endpoint.owners != 0 or endpoint.operations != 0 or endpoint.tickets != 0 or endpoint.requested_bytes != 0 or zhtp_provider_count() != 0 or zhtp_domain_count() != 0) return error.AdoptionNativeRefsRemain;
}

pub fn main(init: std.process.Init.Minimal) !void {
    std.debug.print("Windows HTTPS public layout: Transport={d} Source={d} Writer={d} Pump={d}\n", .{ @sizeOf(https.Transport), @sizeOf(stream.Source), @sizeOf(stream.Writer), @sizeOf(https.files.Pump) });
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len != 5) return error.ExpectedModeFixtureProfileAndPrivateFile;
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.InvalidMode;
    if (mode == .constructors) return adoptionConstructors(allocator, args[2]);
    var preparation: Preparation = .{ .main = std.Thread.getCurrentId(), .directory = args[2], .wrong_certificate = mode == .wrong_certificate };
    preparation.start() catch |err| {
        if (preparation.thread) |thread| thread.join();
        return err;
    };
    defer if (preparation.thread != null) preparation.finish() catch unreachable;
    try runtime(allocator, mode, args[3], args[4], &preparation);
}

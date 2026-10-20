//! A plain-text notes app built on the document app model
//! (`ziggurat_document_app`): one window per note, New / Open / Save /
//! Save As from a native menu bar and a toolbar, a dirty marker in the
//! window title, a prompt before closing or quitting with unsaved changes,
//! timer-driven autosave for notes that have a file, and a persisted list of
//! recent notes under File > Open Recent.
//!
//! The registry owns document state on the main thread; all file I/O runs
//! on one explicit worker thread that this file starts and joins, and every
//! result returns to the main thread through `App.post`. Autosave arms a
//! single `ziggurat_wake.OneShot` for the registry's next deadline, so an
//! idle window does no work. The note body is a multiline
//! `ziggurat_view_text.TextField`, which holds up to 16 KiB.
//!
//! Run it with `zig build run-notes` (or `zig build run-notes -- file.txt`).
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const view = @import("ziggurat_view");
const text = @import("ziggurat_view_text");
const system = @import("ziggurat_system");
const wake = @import("ziggurat_wake");
const docs = @import("ziggurat_document_app");

/// The editing field's own limit on its value.
const max_note = 16 * 1024;
const max_windows = 8;
const max_recent = 6;
const extensions = [_][]const u8{ ".txt", ".md" };
const muted: u32 = 0x6b7785;

const Command = enum { new, open, save, save_as, close, quit };
const menu = struct {
    const file = 1;
    const new = 2;
    const open = 3;
    const recent = 4;
    const save = 5;
    const save_as = 6;
    const close = 7;
    const quit = 8;
    const no_recent = 9;
    const first_recent = 100;
};
const prompt = struct {
    const close = 1;
    const quit = 2;
    const conflict = 3;
};

/// One unit of blocking file work, created on the main thread, run on the
/// worker and completed back on the main thread.
const Job = struct {
    kind: enum { open, resolve_target, save, load_recent, store_recent },
    notes: *Notes,
    /// The window that asked, kept alive by its `in_flight` count.
    note: ?*Note = null,
    path: docs.Path = .{},
    bytes: [max_recent * (docs.max_path + 1) + 64]u8 = undefined,
    len: usize = 0,
    ticket: docs.SaveTicket = undefined,
    identity: docs.Identity = undefined,
    stamp: ?docs.Stamp = null,
    saved: ?docs.SaveResult = null,
    failure: ?anyerror = null,
    next: ?*Job = null,
};

/// One worker thread with an intrusive job queue. It never touches
/// registry or UI state; results go back through `App.post`.
const Worker = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    files: docs.Files,
    mutex: std.Thread.Mutex = .{},
    ready: std.Thread.Condition = .{},
    head: ?*Job = null,
    tail: ?*Job = null,
    stopping: bool = false,
    thread: ?std.Thread = null,

    fn submit(self: *Worker, job: *Job) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        job.next = null;
        if (self.tail) |tail| tail.next = job else self.head = job;
        self.tail = job;
        self.ready.signal();
    }

    fn loop(self: *Worker) void {
        while (true) {
            self.mutex.lock();
            while (self.head == null and !self.stopping) self.ready.wait(&self.mutex);
            const job = self.head orelse {
                self.mutex.unlock();
                return;
            };
            self.head = job.next;
            if (self.head == null) self.tail = null;
            self.mutex.unlock();
            self.run(job) catch |err| {
                job.failure = err;
            };
            // After shutdown starts, App.post refuses and the result is dropped.
            self.app.post(.{ .context = job, .call = Notes.complete }) catch self.allocator.destroy(job);
        }
    }

    fn run(self: *Worker, job: *Job) !void {
        switch (job.kind) {
            .open => {
                var absolute: [std.fs.max_path_bytes]u8 = undefined;
                const given = job.path.slice();
                const path = if (std.fs.path.isAbsolute(given)) given else try std.fs.cwd().realpath(given, &absolute);
                job.identity = try self.files.resolve(path);
                const loaded = try self.files.read(job.identity.path.slice(), job.bytes[0..max_note]);
                job.len = loaded.bytes.len;
                job.stamp = loaded.stamp;
            },
            .resolve_target => job.identity = try self.files.resolveTarget(job.path.slice()),
            .save => {
                job.saved = try self.save(job.ticket.path.slice(), &job.bytes, job.len, job.ticket.expected);
            },
            .load_recent, .store_recent => {
                const directory = try std.fs.getAppDataDir(self.allocator, "ziggurat-notes");
                defer self.allocator.free(directory);
                const path = try std.fs.path.join(self.allocator, &.{ directory, "recent.txt" });
                defer self.allocator.free(path);
                if (job.kind == .load_recent) {
                    const loaded = self.files.read(path, &job.bytes) catch |err| switch (err) {
                        error.FileNotFound => return,
                        else => return err,
                    };
                    job.len = loaded.bytes.len;
                } else {
                    try std.fs.cwd().makePath(directory);
                    _ = try self.save(path, &job.bytes, job.len, null);
                }
            },
        }
    }

    /// Atomic replace with conflict detection through `Files.save`.
    fn save(self: *Worker, path: []const u8, bytes: []u8, len: usize, expected: ?docs.Stamp) !docs.SaveResult {
        var buffer: [4096]u8 = undefined;
        return self.files.save(path, bytes[0..len], &buffer, .{ .expected = expected });
    }

    /// Main thread, after `App.run` returns: finish the queue and join.
    fn stop(self: *Worker) void {
        self.mutex.lock();
        self.stopping = true;
        self.ready.signal();
        self.mutex.unlock();
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
};

/// One window and the note it shows. Heap-allocated so the Host, the text
/// field and the system Owner keep stable addresses; freed by `reap` once
/// the window has closed and no file work refers to it.
const Note = struct {
    notes: *Notes,
    document_id: docs.DocumentId,
    registered: bool = false,
    window: ?z.Window = null,
    document: ?*d.Document = null,
    editor: ?*editing.Field = null,
    field: text.TextField = undefined,
    host: view.Host = undefined,
    storage: view.Storage(32, 2048) = .{},
    owner: system.Owner = undefined,
    owner_attached: bool = false,
    /// Destination of the open and save pickers.
    picked: [docs.max_path]u8 = undefined,
    close_reason: z.CloseReason = .user,
    pending: ?Command = null,
    message: [128]u8 = undefined,
    message_len: usize = 0,
    in_flight: usize = 0,
    closed: bool = false,

    fn create(notes: *Notes, document_id: docs.DocumentId, initial: []const u8, stamp: ?docs.Stamp) !void {
        const self = try notes.allocator.create(Note);
        self.* = .{ .notes = notes, .document_id = document_id };
        notes.track(self) catch |err| {
            notes.allocator.destroy(self);
            return err;
        };
        // From here a failure closes the window, and on_closed releases what
        // was made; without a window, mark the note for reaping directly.
        errdefer if (self.window) |window| {
            _ = window.destroy() catch {};
        } else {
            self.closed = true;
        };
        const window = try notes.app.createWindow(.{ .title = "Notes", .width = 640, .height = 480, .min_width = 360, .min_height = 240, .on_close = notes.registry.closeHandler(), .on_closed = .{ .context = self, .notify = onClosed } });
        self.window = window;
        const thread = std.Thread.getCurrentId();
        self.document = try d.Document.create(notes.allocator, thread, initial, .{});
        self.host = view.Host.init(self, build, self.storage.buffers(), .{ .root = .{ .padding = view.Insets.all(12), .gap = 8, .alignment = .stretch } });
        try self.host.attach(window);
        try self.host.context.prepareTextFields(notes.allocator, .{});
        self.editor = try editing.Field.create(notes.allocator, self.document.?, notes.engine, .{ .multiline = true, .value_bytes = max_note, .context = self, .changed = edited });
        const scale = (try window.contentSize()).scale;
        self.field = text.TextField.init(self.editor.?, &self.host, .{ .font = .{ .size = 16, .wrap = .word_character, .width = 1 }, .scale = scale }, .{ .name = "Note", .lines = 12 });
        self.owner = system.Owner.init(self, action);
        try self.owner.attach(window);
        self.owner_attached = true;
        try self.refreshMenu();
        try notes.registry.attach(document_id, window, stamp);
        self.registered = true;
        self.refreshTitle();
        window.show();
    }

    fn build(self: *Note, v: *view.View) anyerror!void {
        try v.toolbar(.{ .gap = 8, .alignment = .center, .name = "File" });
        if (try v.button("New", .{})) self.queue(.new);
        if (try v.button("Open…", .{})) self.queue(.open);
        if (try v.button("Save", .{})) self.queue(.save);
        if (try v.button("Save As…", .{})) self.queue(.save_as);
        try v.end();
        if (self.editor != null) try v.embed(self.field.embed(), .{ .grow = 1, .key = 1 });
        try v.row(.{ .gap = 8, .key = 2 });
        try v.text(self.status(), .{ .color = muted, .grow = 1 });
        if (self.message_len > 0) try v.text(self.message[0..self.message_len], .{ .color = 0xa33a2c });
        try v.end();
    }

    fn status(self: *Note) []const u8 {
        if (!self.registered) return "";
        const info = self.notes.registry.info(self.document_id) catch return "";
        if (info.conflict) return "Changed on disk; Save to choose what to keep";
        if (info.saving) return "Saving…";
        const file = info.kind.* == .file;
        if (info.dirty) return if (file) "Edited; autosaves when you pause typing" else "Not saved yet";
        return if (file) "Saved" else "New note";
    }

    fn report(self: *Note, comptime format: []const u8, args: anytype) void {
        self.message_len = (std.fmt.bufPrint(&self.message, format, args) catch &self.message).len;
        if (self.window) |window| window.invalidate();
    }

    fn refreshTitle(self: *Note) void {
        const window = self.window orelse return;
        if (!self.registered) return;
        var name: [256]u8 = undefined;
        const shown = self.notes.registry.displayName(self.document_id, &name) catch "Note";
        const dirty = if (self.notes.registry.info(self.document_id)) |info| info.dirty else |_| false;
        var title: [300]u8 = undefined;
        window.setTitle(std.fmt.bufPrint(&title, "{s}{s} — Notes", .{ if (dirty) "• " else "", shown }) catch "Notes") catch {};
        window.invalidate();
    }

    fn refreshMenu(self: *Note) !void {
        if (!self.owner_attached) return;
        var items: [12 + max_recent]system.Item = undefined;
        var n: usize = 0;
        const control: system.Modifiers = .{ .control = true };
        for ([_]system.Item{
            .{ .id = menu.file, .kind = .submenu, .label = "&File" },
            .{ .id = menu.new, .parent = menu.file, .label = "&New", .accelerator = .{ .key = .n, .modifiers = control } },
            .{ .id = menu.open, .parent = menu.file, .label = "&Open…", .accelerator = .{ .key = .o, .modifiers = control } },
            .{ .id = menu.recent, .parent = menu.file, .kind = .submenu, .label = "Open &Recent" },
        }) |item| {
            items[n] = item;
            n += 1;
        }
        const recent = self.notes.recent.items();
        for (recent, 0..) |*entry, index| {
            items[n] = .{ .id = menu.first_recent + index, .parent = menu.recent, .label = entry.basename() };
            n += 1;
        }
        if (recent.len == 0) {
            items[n] = .{ .id = menu.no_recent, .parent = menu.recent, .label = "No recent notes", .enabled = false };
            n += 1;
        }
        for ([_]system.Item{
            .{ .parent = menu.file, .kind = .separator },
            .{ .id = menu.save, .parent = menu.file, .label = "&Save", .accelerator = .{ .key = .s, .modifiers = control } },
            .{ .id = menu.save_as, .parent = menu.file, .label = "Save &As…", .accelerator = .{ .key = .s, .modifiers = .{ .control = true, .shift = true } } },
            .{ .parent = menu.file, .kind = .separator },
            .{ .id = menu.close, .parent = menu.file, .label = "&Close", .accelerator = .{ .key = .w, .modifiers = control } },
            .{ .id = menu.quit, .parent = menu.file, .label = "&Quit", .accelerator = .{ .key = .q, .modifiers = control } },
        }) |item| {
            items[n] = item;
            n += 1;
        }
        try self.owner.setMenu(items[0..n]);
    }

    /// Buttons fire inside a build pass; run their command as a posted task.
    fn queue(self: *Note, command: Command) void {
        const window = self.window orelse return;
        self.pending = command;
        window.app.post(.{ .context = self, .call = runPending }) catch {};
    }

    fn runPending(ptr: *anyopaque) void {
        const self: *Note = @ptrCast(@alignCast(ptr));
        const command = self.pending orelse return;
        self.pending = null;
        if (!self.closed) self.run(command);
    }

    fn run(self: *Note, command: Command) void {
        const notes = self.notes;
        self.message_len = 0;
        switch (command) {
            .new => notes.newNote(),
            .open => self.owner.openFile(.{ .extensions = &extensions }, &self.picked, self, openPicked) catch |err| self.report("Cannot open a picker: {s}", .{@errorName(err)}),
            .save => self.save(.normal),
            .save_as => self.saveAs(),
            .close => _ = (self.window orelse return).requestClose() catch {},
            .quit => _ = notes.registry.requestQuit(),
        }
    }

    fn openPicked(ptr: *anyopaque, _: z.Window, result: system.picker.Result) void {
        const self: *Note = @ptrCast(@alignCast(ptr));
        switch (result) {
            .selected => |path| self.notes.open(path, self),
            .failed => |failure| self.report("Picker failed: {s}", .{@errorName(failure.err)}),
            else => {},
        }
    }

    fn saveAs(self: *Note) void {
        var name: [256]u8 = undefined;
        const suggested = self.notes.registry.displayName(self.document_id, &name) catch "Note";
        self.owner.saveFile(.{ .extensions = &extensions, .suggested_name = suggested }, &self.picked, self, savePicked) catch |err| self.report("Cannot open a picker: {s}", .{@errorName(err)});
    }

    fn savePicked(ptr: *anyopaque, _: z.Window, result: system.picker.Result) void {
        const self: *Note = @ptrCast(@alignCast(ptr));
        const path = switch (result) {
            .selected => |path| path,
            .failed => |failure| return self.report("Picker failed: {s}", .{@errorName(failure.err)}),
            else => return self.abandonPendingClose(),
        };
        const job = self.notes.job(.resolve_target, self) orelse return;
        job.path = docs.Path.init(path) catch return self.notes.finish(job);
        self.notes.worker.submit(job);
    }

    /// Start saving the current revision; untitled notes ask for a file.
    fn save(self: *Note, mode: docs.Registry.SaveMode) void {
        const ticket = self.notes.registry.beginSave(self.document_id, mode) catch |err| switch (err) {
            error.Untitled => return self.saveAs(),
            error.Conflict => return self.askOverwrite(),
            error.SaveInProgress => return,
            else => return self.report("Cannot save: {s}", .{@errorName(err)}),
        };
        self.submitSave(ticket, null);
    }

    fn submitSave(self: *Note, ticket: docs.SaveTicket, reuse: ?*Job) void {
        const job = reuse orelse self.notes.job(.save, self) orelse {
            self.notes.registry.failSave(&ticket) catch {};
            return;
        };
        job.kind = .save;
        job.ticket = ticket;
        job.len = self.read(job.bytes[0..max_note]) catch |err| {
            self.notes.registry.failSave(&ticket) catch {};
            self.report("Cannot save: {s}", .{@errorName(err)});
            return self.notes.finish(job);
        };
        self.notes.worker.submit(job);
        if (self.window) |window| window.invalidate();
    }

    fn read(self: *Note, output: []u8) !usize {
        const document = self.document orelse return error.Closed;
        const length = try document.byteLength();
        if (length > output.len) return error.NoteTooLarge;
        return document.read(.{ .start = 0, .end = length }, output);
    }

    fn isBlankUntitled(self: *Note) bool {
        if (!self.registered or self.closed) return false;
        const info = self.notes.registry.info(self.document_id) catch return false;
        const length = if (self.document) |document| document.byteLength() catch 1 else 1;
        return info.kind.* == .untitled and !info.dirty and length == 0;
    }

    fn askOverwrite(self: *Note) void {
        self.owner.showMessage(prompt.conflict, .{
            .title = "Notes",
            .message = "The file changed on disk since it was opened. Replace it with this note?",
            .buttons = &.{ .{ .id = 1, .label = "Replace" }, .{ .id = 2, .label = "Cancel" } },
            .cancel_button = 1,
        }) catch {};
    }

    fn abandonPendingClose(self: *Note) void {
        self.notes.registry.abandonClose(self.document_id) catch {};
    }

    fn action(ptr: *anyopaque, _: z.Window, event: system.Action) void {
        const self: *Note = @ptrCast(@alignCast(ptr));
        const registry = &self.notes.registry;
        switch (event) {
            .menu => |id| switch (id) {
                menu.new => self.run(.new),
                menu.open => self.run(.open),
                menu.save => self.run(.save),
                menu.save_as => self.run(.save_as),
                menu.close => self.run(.close),
                menu.quit => self.run(.quit),
                else => if (id >= menu.first_recent and id < menu.first_recent + self.notes.recent.len) {
                    const entry = &self.notes.recent.items()[id - menu.first_recent];
                    self.notes.open(entry.slice(), self);
                },
            },
            .message => |result| {
                const button: u64 = switch (result.response) {
                    .button => |value| value,
                    else => 0,
                };
                switch (result.request) {
                    prompt.close => switch (button) {
                        1 => self.save(.normal),
                        2 => {
                            registry.discard(self.document_id) catch {};
                            if (self.window) |window| _ = window.requestCloseFrom(self.close_reason) catch {};
                        },
                        else => self.abandonPendingClose(),
                    },
                    prompt.quit => if (button == 1) {
                        registry.discardAll();
                        _ = registry.requestQuit();
                    } else registry.abandonQuit(),
                    prompt.conflict => if (button == 1) self.save(.overwrite),
                    else => {},
                }
            },
            else => {},
        }
    }

    fn edited(ptr: ?*anyopaque, _: z.Window, _: u64) void {
        const self: *Note = @ptrCast(@alignCast(ptr.?));
        if (!self.registered) return;
        self.notes.registry.edited(self.document_id, self.notes.now()) catch return;
        self.message_len = 0;
        self.notes.schedule();
    }

    /// on_closed: the window and its content are gone. Release the editor
    /// before its Document, then leave the struct itself to `reap`.
    fn onClosed(ptr: *anyopaque, window: z.Window) void {
        const self: *Note = @ptrCast(@alignCast(ptr));
        if (self.registered) self.notes.registry.closed(window);
        self.registered = false;
        if (self.editor) |editor| {
            self.field.detach();
            editor.close() catch {};
            self.editor = null;
        }
        if (self.document) |document| document.close() catch {};
        self.document = null;
        self.window = null;
        self.closed = true;
        self.notes.schedule();
        self.notes.app.post(.{ .context = self.notes, .call = Notes.reapTask }) catch {};
    }
};

const Notes = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    engine: *t.Engine,
    registry: docs.Registry = undefined,
    slots: [max_windows]docs.Slot = undefined,
    list: [max_windows]?*Note = .{null} ** max_windows,
    recent_storage: [max_recent]docs.Path = undefined,
    recent: docs.Recent = undefined,
    worker: Worker,
    clock: std.time.Timer,
    autosave: ?*wake.OneShot = null,
    armed: ?wake.Token = null,

    fn now(self: *Notes) i128 {
        return self.clock.read();
    }

    fn track(self: *Notes, note: *Note) !void {
        for (&self.list) |*entry| if (entry.* == null) {
            entry.* = note;
            return;
        };
        return error.TooManyWindows;
    }

    fn find(self: *Notes, document_id: docs.DocumentId) ?*Note {
        for (self.list) |entry| if (entry) |note| if (note.registered and note.document_id.eql(document_id)) return note;
        return null;
    }

    fn reapTask(ptr: *anyopaque) void {
        const self: *Notes = @ptrCast(@alignCast(ptr));
        self.reap(false);
    }

    /// Free closed notes that no queued work refers to; `all` after the
    /// loop and the worker have stopped.
    fn reap(self: *Notes, all: bool) void {
        for (&self.list) |*entry| if (entry.*) |note| if (all or (note.closed and note.in_flight == 0)) {
            self.allocator.destroy(note);
            entry.* = null;
        };
    }

    fn job(self: *Notes, kind: @FieldType(Job, "kind"), note: ?*Note) ?*Job {
        const created = self.allocator.create(Job) catch {
            if (note) |owner| owner.report("Out of memory", .{});
            return null;
        };
        created.* = .{ .kind = kind, .notes = self, .note = note };
        if (note) |owner| owner.in_flight += 1;
        return created;
    }

    fn finish(self: *Notes, done: *Job) void {
        if (done.note) |note| note.in_flight -= 1;
        self.allocator.destroy(done);
        self.reap(false);
    }

    fn newNote(self: *Notes) void {
        const document_id = self.registry.claimUntitled() catch return;
        Note.create(self, document_id, "", null) catch |err| {
            self.registry.cancel(document_id) catch {};
            std.log.err("cannot create a note window: {s}", .{@errorName(err)});
        };
    }

    fn open(self: *Notes, path: []const u8, origin: ?*Note) void {
        const created = self.job(.open, origin) orelse return;
        created.path = docs.Path.init(path) catch return self.finish(created);
        self.worker.submit(created);
    }

    fn storeRecent(self: *Notes) void {
        for (self.list) |entry| if (entry) |note| note.refreshMenu() catch {};
        const created = self.job(.store_recent, null) orelse return;
        const encoded = self.recent.encode(&created.bytes) catch return self.finish(created);
        created.len = encoded.len;
        self.worker.submit(created);
    }

    /// Main thread: apply one finished job.
    fn complete(ptr: *anyopaque) void {
        const done: *Job = @ptrCast(@alignCast(ptr));
        const self = done.notes;
        // A Save As continues with the same job; everything else ends here.
        if (done.kind == .resolve_target and done.failure == null) if (done.note) |note| if (!note.closed) {
            const ticket = self.registry.beginSaveAs(note.document_id, &done.identity) catch |err| {
                note.report("Cannot save here: {s}", .{@errorName(err)});
                note.abandonPendingClose();
                return self.finish(done);
            };
            return note.submitSave(ticket, done);
        };
        defer self.finish(done);
        const note = done.note;
        const live = if (note) |value| !value.closed else false;
        if (done.failure) |err| {
            if (done.kind == .save) self.registry.failSave(&done.ticket) catch {};
            if (live) note.?.report("{s} failed: {s}", .{ @tagName(done.kind), @errorName(err) }) else if (done.kind != .load_recent and done.kind != .store_recent) std.log.err("{s} failed: {s}", .{ @tagName(done.kind), @errorName(err) });
            if ((done.kind == .save or done.kind == .resolve_target) and live) note.?.abandonPendingClose();
            return;
        }
        switch (done.kind) {
            .open => {
                const claim = self.registry.claim(&done.identity) catch |err| return if (live) note.?.report("Cannot open: {s}", .{@errorName(err)});
                switch (claim) {
                    .existing => |existing| _ = self.registry.reveal(existing) catch {},
                    .reserved => |document_id| {
                        Note.create(self, document_id, done.bytes[0..done.len], done.stamp) catch |err| {
                            self.registry.cancel(document_id) catch {};
                            if (live) note.?.report("Cannot open: {s}", .{@errorName(err)});
                            return;
                        };
                        // An untouched blank note gives way to the opened one.
                        if (live and note.?.isBlankUntitled()) _ = note.?.window.?.requestClose() catch {};
                    },
                }
                self.recent.add(done.identity.path.slice()) catch {};
                self.storeRecent();
            },
            .resolve_target => {},
            .save => {
                switch (done.saved.?) {
                    .conflict => {
                        self.registry.conflictSave(&done.ticket) catch {};
                        if (live) note.?.askOverwrite();
                    },
                    .saved => |stamp| {
                        const outcome = self.registry.finishSave(&done.ticket, stamp) catch |err| return if (live) note.?.report("Cannot save: {s}", .{@errorName(err)});
                        if (done.ticket.target != null) {
                            self.recent.add(done.ticket.path.slice()) catch {};
                            self.storeRecent();
                        }
                        if (outcome.retry_close) |reason| {
                            if (reason == .quit) {
                                _ = self.registry.requestQuit();
                            } else if (live) _ = note.?.window.?.requestCloseFrom(reason) catch {};
                        }
                    },
                }
            },
            .load_recent => {
                self.recent.decode(done.bytes[0..done.len]) catch {};
                for (self.list) |entry| if (entry) |value| value.refreshMenu() catch {};
            },
            .store_recent => {},
        }
    }

    /// Autosave: arm one timer for the registry's earliest deadline.
    fn schedule(self: *Notes) void {
        const timer = self.autosave orelse return;
        if (self.armed) |token| _ = timer.cancel(token) catch {};
        self.armed = null;
        const deadline = self.registry.nextDeadline() orelse return;
        const delay: u64 = @intCast(std.math.clamp(deadline - self.now(), 1, std.time.ns_per_hour));
        self.armed = timer.armAfter(delay) catch null;
    }

    fn fire(ptr: *anyopaque, _: *wake.OneShot, _: wake.Token) void {
        const self: *Notes = @ptrCast(@alignCast(ptr));
        self.armed = null;
        var due: [max_windows]docs.DocumentId = undefined;
        for (self.registry.dueAutosaves(self.now(), &due)) |document_id| {
            if (self.find(document_id)) |note| note.save(.normal);
        }
        self.schedule();
    }

    fn changed(ptr: *anyopaque, _: *docs.Registry, document_id: docs.DocumentId) void {
        const self: *Notes = @ptrCast(@alignCast(ptr));
        if (self.find(document_id)) |note| note.refreshTitle();
    }

    fn closeBlocked(ptr: *anyopaque, _: *docs.Registry, document_id: docs.DocumentId, reason: z.CloseReason) void {
        const self: *Notes = @ptrCast(@alignCast(ptr));
        const note = self.find(document_id) orelse return;
        note.close_reason = reason;
        var name: [256]u8 = undefined;
        var message: [320]u8 = undefined;
        const shown = self.registry.displayName(document_id, &name) catch "this note";
        note.owner.showMessage(prompt.close, .{
            .title = "Notes",
            .message = std.fmt.bufPrint(&message, "Save changes to {s} before closing?", .{shown}) catch "Save changes before closing?",
            .buttons = &.{ .{ .id = 1, .label = "Save" }, .{ .id = 2, .label = "Don't Save" }, .{ .id = 3, .label = "Cancel" } },
            .default_button = 0,
            .cancel_button = 2,
        }) catch note.abandonPendingClose();
    }

    fn quitBlocked(ptr: *anyopaque, registry: *docs.Registry) void {
        const self: *Notes = @ptrCast(@alignCast(ptr));
        var blocking: [max_windows]docs.DocumentId = undefined;
        const list = registry.blocking(&blocking);
        const note = if (list.len > 0) self.find(list[0]) else null;
        var message: [160]u8 = undefined;
        (note orelse return registry.abandonQuit()).owner.showMessage(prompt.quit, .{
            .title = "Notes",
            .message = std.fmt.bufPrint(&message, "{d} note(s) have unsaved changes. Quit anyway?", .{list.len}) catch "Quit anyway?",
            .buttons = &.{ .{ .id = 1, .label = "Discard and Quit" }, .{ .id = 2, .label = "Cancel" } },
            .default_button = 1,
            .cancel_button = 1,
        }) catch registry.abandonQuit();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app = try z.App.init(allocator);
    defer app.deinit();
    const thread = std.Thread.getCurrentId();
    const engine = try t.Engine.create(allocator, thread, .{});
    defer engine.close() catch {};

    const notes = try allocator.create(Notes);
    defer allocator.destroy(notes);
    notes.* = .{
        .app = app,
        .allocator = allocator,
        .engine = engine,
        .worker = .{ .app = app, .allocator = allocator, .files = .{ .ui_thread = thread } },
        .clock = try std.time.Timer.start(),
    };
    notes.registry = docs.Registry.init(app, &notes.slots, .{ .recovery = false }, .{
        .context = notes,
        .close_blocked = Notes.closeBlocked,
        .quit_blocked = Notes.quitBlocked,
        .changed = Notes.changed,
    });
    notes.recent = docs.Recent.init(&notes.recent_storage);
    notes.autosave = try wake.OneShot.create(app, allocator, .{ .context = notes, .fire = Notes.fire }, .{});
    // The timer shell outlives App stop; close it last.
    defer _ = notes.autosave.?.close() catch {};

    notes.worker.thread = try std.Thread.spawn(.{}, Worker.loop, .{&notes.worker});
    // After the loop: join the worker, then free every note it might name.
    defer {
        notes.worker.stop();
        notes.reap(true);
    }

    notes.newNote();
    if (notes.job(.load_recent, null)) |job| notes.worker.submit(job);
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    // The worker resolves a relative path; the blank note gives way to it.
    if (args.next()) |path| notes.open(path, notes.list[0]);
    try app.run();
}

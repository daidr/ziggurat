const std = @import("std");
const z = @import("ziggurat");
const d = @import("root.zig");

/// Borrows one Document; keep this address stable until unbound and all active
/// calls return. Native context queries only walk the index and copy into the
/// caller buffer. changed runs after a committed edit, in the input/layout
/// phase; its failure preserves the edit and is returned for explicit retry.
pub const Binding = struct {
    pub const Changed = struct { context: *anyopaque, call: *const fn (*anyopaque, z.Window) anyerror!void };
    document: *d.Document,
    owner: std.Thread.Id,
    token: ?z.TextClientToken = null,
    changed: ?Changed = null,
    busy: bool = false,

    pub fn init(document: *d.Document, owner: std.Thread.Id) Binding {
        return .{ .document = document, .owner = owner };
    }
    fn check(self: *const Binding) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.busy) return error.Busy;
    }
    pub fn bind(self: *Binding, window: z.Window) !void {
        try self.check();
        if (self.token != null) return error.AlreadyBound;
        self.busy = true;
        defer self.busy = false;
        try self.document.retainClient();
        errdefer self.document.releaseClient() catch unreachable;
        self.token = try window.setTextClient(.{ .context = self, .owner = self.owner, .read = read, .change = change, .unbound = unbound });
    }
    pub fn unbind(self: *Binding) !void {
        try self.check();
        if (self.token) |token| _ = try token.window.clearTextClient(token);
        // clearTextClient revokes before native cancellation and always calls
        // unbound, including when cancellation reports an error.
        // Closing windows reject new callback scopes. Their accepted close
        // still owns the eventual unbound notification at the safe point.
        if (self.token != null) return error.UnbindPending;
    }
    fn unbound(ptr: *anyopaque, window: z.Window, _: z.text.UnbindReason) void {
        const self: *Binding = @ptrCast(@alignCast(ptr));
        self.token = null;
        const failure: ?anyerror = blk: {
            _ = self.document.cancelComposition() catch |err| break :blk err;
            break :blk null;
        };
        self.document.releaseClient() catch unreachable;
        // No access to the borrowed binding/document after user diagnostics.
        if (failure) |err| window.report(.{ .domain = .core, .operation = .text_input, .err = err });
    }
    fn read(ptr: *anyopaque, _: z.Window, destination: []u8) !z.text.Snapshot {
        const self: *Binding = @ptrCast(@alignCast(ptr));
        try self.check();
        if (self.token == null) return error.StaleTextClient;
        return self.document.nativeContext(destination);
    }
    fn change(ptr: *anyopaque, window: z.Window, value: z.text.Change) !z.text.ChangeResult {
        const self: *Binding = @ptrCast(@alignCast(ptr));
        try self.check();
        if (self.token == null) return error.StaleTextClient;
        self.busy = true;
        defer self.busy = false;
        try self.document.retainClient();
        defer self.document.releaseClient() catch unreachable;
        if (try self.document.composition() != null) return error.CompositionActive;
        if (try self.document.selectionCount() != 1) return error.MultipleSelections;
        switch (value) {
            .select => |selected| {
                if (!try self.document.setSelection(.{ .anchor = try self.document.byteOffsetFromUtf16(selected.anchor), .caret = try self.document.byteOffsetFromUtf16(selected.caret) })) return .applied;
            },
            .replace => |replacement| {
                if (std.mem.indexOfScalar(u8, replacement.text, 0) != null) return error.EmbeddedNul;
                try self.document.replace(.{ .start = try self.document.byteOffsetFromUtf16(replacement.range.start), .end = try self.document.byteOffsetFromUtf16(replacement.range.end) }, replacement.text);
            },
        }
        if (self.changed) |callback| try callback.call(callback.context, window);
        return .applied;
    }
    /// Explicitly route committed/preedit content events here. This is a text
    /// transport, not a keyboard navigation, shaping or drawing implementation.
    /// No native query calls this method implicitly.
    pub fn handleEvent(self: *Binding, window: z.Window, event: z.Event) !bool {
        try self.check();
        const token = self.token orelse return false;
        const current = window.textClientToken() orelse return false;
        if (token.window.app != window.app or !std.meta.eql(token.window.key, window.key) or token.generation != current.generation) return false;
        switch (event) {
            .text_input, .text_preedit, .text_preedit_cancel => {},
            else => return false,
        }
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        try self.document.retainClient();
        defer self.document.releaseClient() catch unreachable;
        switch (event) {
            .text_input => |input| {
                if (std.mem.indexOfScalar(u8, input.text, 0) != null) return error.EmbeddedNul;
                if (try self.document.composition() != null) try self.document.commitComposition(input.text) else try self.document.replaceSelections(input.text);
            },
            .text_preedit => |preedit| try self.document.setComposition(preedit.text, .{ .anchor = preedit.selection_start, .caret = preedit.selection_end }),
            .text_preedit_cancel => if (!try self.document.cancelComposition()) return true,
            else => unreachable,
        }
        if (self.changed) |callback| try callback.call(callback.context, window);
        return true;
    }
};

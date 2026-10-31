//! Serialized content for native drag and drop. A Data holds ordered items;
//! each item offers alternative formats of the same content, and separate
//! items are separate values. Formats are MIME names with explicit encodings.
//! Data borrows caller slices; a Snapshot copies them with an explicit
//! allocator and caches lazy representations once per drag.
const std = @import("std");
const builtin = @import("builtin");

pub const Format = []const u8;
pub const text: Format = "text/plain";
pub const html: Format = "text/html";
pub const uri_list: Format = "text/uri-list";
/// A URI list known to contain local files. Native integrations offer it as
/// the system's file list as well as text/uri-list.
pub const file_list: Format = "application/x-ziggurat-file-list";
pub const png: Format = "image/png";
/// Markdown text (RFC 7763).
pub const markdown: Format = "text/markdown";

/// Foreign representations larger than this are rejected.
pub const max_representation_bytes = 64 * 1024 * 1024;
pub const max_format_bytes = 255;
pub const max_items = 4096;
pub const max_formats = 64;

/// 1..255 bytes without NUL, CR or LF.
pub fn validFormat(format: Format) bool {
    if (format.len == 0 or format.len > max_format_bytes) return false;
    return std.mem.indexOfAny(u8, format, "\x00\r\n") == null;
}
fn coalesced(format: Format) enum { lines, uris, first } {
    if (std.mem.eql(u8, format, text)) return .lines;
    if (std.mem.eql(u8, format, uri_list) or std.mem.eql(u8, format, file_list)) return .uris;
    return .first;
}

/// Renders a lazy representation into a Sink. It runs on the owner thread
/// at most once per Snapshot, when a destination requests the format, and
/// its error is cached too. It must return promptly and never wait for
/// another owner-thread action; prepare costly content beforehand.
pub const Provider = struct {
    context: *anyopaque,
    render: *const fn (*anyopaque, Format, *Sink) anyerror!void,
};
/// Receives a rendered representation. `set` copies; a provider that never
/// calls it renders empty bytes.
pub const Sink = struct {
    allocator: std.mem.Allocator,
    bytes: ?[]u8 = null,

    pub fn set(self: *Sink, data: []const u8) !void {
        if (self.bytes != null) return error.AlreadyWritten;
        if (data.len > max_representation_bytes) return error.CapacityExceeded;
        self.bytes = try self.allocator.dupe(u8, data);
    }
};

pub const Representation = struct {
    format: Format,
    value: union(enum) { bytes: []const u8, lazy: Provider },

    pub fn fromBytes(format: Format, data: []const u8) Representation {
        return .{ .format = format, .value = .{ .bytes = data } };
    }
    pub fn lazy(format: Format, provider: Provider) Representation {
        return .{ .format = format, .value = .{ .lazy = provider } };
    }
};

/// Alternative representations of one value, in the source's preference order.
pub const Item = struct {
    representations: []const Representation,

    pub fn offers(self: Item, format: Format) bool {
        return self.find(format) != null;
    }
    fn find(self: Item, format: Format) ?Representation {
        for (self.representations) |representation| if (std.mem.eql(u8, representation.format, format)) return representation;
        return null;
    }
};

pub const Data = struct {
    items: []const Item = &.{},

    /// Every item has 1..max_formats valid, distinct formats.
    pub fn validate(self: Data) !void {
        if (self.items.len > max_items) return error.TooManyItems;
        for (self.items) |item| {
            if (item.representations.len == 0 or item.representations.len > max_formats) return error.InvalidItem;
            for (item.representations, 0..) |representation, index| {
                if (!validFormat(representation.format)) return error.InvalidFormat;
                for (item.representations[0..index]) |earlier| if (std.mem.eql(u8, earlier.format, representation.format)) return error.DuplicateFormat;
                if (representation.value == .bytes and representation.value.bytes.len > max_representation_bytes) return error.CapacityExceeded;
            }
        }
    }
    pub fn offers(self: Data, format: Format) bool {
        for (self.items) |item| if (item.offers(format)) return true;
        return false;
    }
    /// Distinct formats in item order, without rendering anything. Returns
    /// the count; formats beyond `destination` are left out.
    pub fn formats(self: Data, destination: []Format) usize {
        var count: usize = 0;
        for (self.items) |item| for (item.representations) |representation| {
            if (count == destination.len) return count;
            if (contains(destination[0..count], representation.format)) continue;
            destination[count] = representation.format;
            count += 1;
        };
        return count;
    }
    /// The receiver's first preferred format that this data offers.
    pub fn preferred(self: Data, preference: []const Format) ?Format {
        for (preference) |format| if (self.offers(format)) return format;
        return null;
    }
    /// Reads a format as single-object systems do: text items join with
    /// newlines, URI and file lists with CRLF, and other formats use the
    /// first item offering them. Lazy providers run each call; a Snapshot
    /// caches them. The bytes belong to the caller.
    pub fn read(self: Data, allocator: std.mem.Allocator, format: Format) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var found = false;
        for (self.items) |item| {
            const representation = item.find(format) orelse continue;
            if (found) try out.appendSlice(allocator, if (coalesced(format) == .uris) "\r\n" else "\n");
            switch (representation.value) {
                .bytes => |bytes| try out.appendSlice(allocator, bytes),
                .lazy => |provider| {
                    var sink: Sink = .{ .allocator = allocator };
                    defer if (sink.bytes) |bytes| allocator.free(bytes);
                    try provider.render(provider.context, format, &sink);
                    try out.appendSlice(allocator, sink.bytes orelse "");
                },
            }
            found = true;
            if (coalesced(format) == .first) break;
            if (out.items.len > max_representation_bytes) return error.CapacityExceeded;
        }
        if (!found) return error.FormatUnavailable;
        return out.toOwnedSlice(allocator);
    }
};

fn contains(list: []const Format, format: Format) bool {
    for (list) |existing| if (std.mem.eql(u8, existing, format)) return true;
    return false;
}
/// Negotiates an offer's formats without requesting data: the receiver's
/// preference order wins over the source's item order.
pub fn preferredFormat(offered: []const Format, preference: []const Format) ?Format {
    for (preference) |format| if (contains(offered, format)) return format;
    return null;
}

/// A drag effect.
pub const Operation = enum(u8) { none = 0, copy = 1, move = 2 };
/// A set of drag effects. The empty set means copy.
pub const Operations = packed struct(u8) {
    copy: bool = false,
    move: bool = false,
    _: u6 = 0,

    pub const copy_only: Operations = .{ .copy = true };
    pub const copy_move: Operations = .{ .copy = true, .move = true };

    /// The default (copy) for the empty set.
    pub fn allowed(self: Operations) Operations {
        return if (!self.copy and !self.move) copy_only else .{ .copy = self.copy, .move = self.move };
    }
    pub fn has(self: Operations, operation: Operation) bool {
        return switch (operation) {
            .none => false,
            .copy => self.copy,
            .move => self.move,
        };
    }
    pub fn empty(self: Operations) bool {
        return !self.copy and !self.move;
    }
};
/// Chooses one effect both ends allow. The source's modifier-key suggestion
/// wins when allowed; otherwise copy comes before move.
pub fn negotiate(source: Operations, destination: Operations, suggested: Operation) Operation {
    const target = destination.allowed();
    const both: Operations = .{ .copy = source.copy and target.copy, .move = source.move and target.move };
    if (both.has(suggested)) return suggested;
    if (both.copy) return .copy;
    if (both.move) return .move;
    return .none;
}

/// A drag during hover, without its bytes.
pub const Offer = struct {
    formats: []const Format,
    operations: Operations,
    suggested: Operation = .none,

    pub fn preferred(self: Offer, preference: []const Format) ?Format {
        return preferredFormat(self.formats, preference);
    }
};

/// A copy of Data with its own provider cache, as each drag takes. Lazy
/// providers stay borrowed: keep their contexts valid until the drag's done
/// callback.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    states: []State = &.{},
    reads: std.ArrayList(Cached) = .empty,

    const State = union(enum) { pending, ready: []const u8, failed: anyerror };
    const Cached = struct { format: Format, result: anyerror![]const u8 };

    pub fn init(allocator: std.mem.Allocator, source: Data) !Snapshot {
        try source.validate();
        var self: Snapshot = .{ .arena = .init(allocator) };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        var count: usize = 0;
        for (source.items) |item| count += item.representations.len;
        self.items = try a.alloc(Item, source.items.len);
        self.states = try a.alloc(State, count);
        const representations = try a.alloc(Representation, count);
        var next: usize = 0;
        for (source.items, self.items) |item, *copy| {
            const start = next;
            for (item.representations) |representation| {
                const format = try a.dupe(u8, representation.format);
                representations[next] = switch (representation.value) {
                    .bytes => |bytes| .fromBytes(format, try a.dupe(u8, bytes)),
                    .lazy => |provider| .lazy(format, provider),
                };
                self.states[next] = switch (representation.value) {
                    .bytes => .{ .ready = representations[next].value.bytes },
                    .lazy => .pending,
                };
                next += 1;
            }
            copy.* = .{ .representations = representations[start..next] };
        }
        return self;
    }
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
    /// The copied data. Its lazy representations still call the providers
    /// directly; read through the Snapshot to use its cache.
    pub fn data(self: *const Snapshot) Data {
        return .{ .items = self.items };
    }

    /// One item's representation, rendering a lazy one at most once.
    /// The bytes live as long as the Snapshot.
    pub fn readItem(self: *Snapshot, item: usize, format: Format) ![]const u8 {
        if (item >= self.items.len) return error.FormatUnavailable;
        var index: usize = 0;
        for (self.items[0..item]) |earlier| index += earlier.representations.len;
        for (self.items[item].representations) |representation| {
            if (std.mem.eql(u8, representation.format, format)) return self.render(index, representation);
            index += 1;
        }
        return error.FormatUnavailable;
    }
    fn render(self: *Snapshot, index: usize, representation: Representation) ![]const u8 {
        switch (self.states[index]) {
            .ready => |bytes| return bytes,
            .failed => |err| return err,
            .pending => {},
        }
        const provider = representation.value.lazy;
        var sink: Sink = .{ .allocator = self.arena.allocator() };
        provider.render(provider.context, representation.format, &sink) catch |err| {
            self.states[index] = .{ .failed = err };
            return err;
        };
        self.states[index] = .{ .ready = sink.bytes orelse "" };
        return self.states[index].ready;
    }
    /// Data.read's coalescing over the cache. The result, or the error,
    /// is kept for the Snapshot's lifetime.
    pub fn read(self: *Snapshot, format: Format) ![]const u8 {
        for (self.reads.items) |cached| if (std.mem.eql(u8, cached.format, format)) return cached.result;
        const result = self.coalesce(format);
        if (result) |_| {} else |err| if (err == error.OutOfMemory) return err;
        const a = self.arena.allocator();
        try self.reads.append(a, .{ .format = try a.dupe(u8, format), .result = result });
        return result;
    }
    fn coalesce(self: *Snapshot, format: Format) ![]const u8 {
        const a = self.arena.allocator();
        var out: std.ArrayList(u8) = .empty;
        var found: usize = 0;
        var single: []const u8 = "";
        for (self.items, 0..) |item, index| {
            if (!item.offers(format)) continue;
            const bytes = try self.readItem(index, format);
            if (found == 0) single = bytes else {
                if (found == 1) try out.appendSlice(a, single);
                try out.appendSlice(a, if (coalesced(format) == .uris) "\r\n" else "\n");
                try out.appendSlice(a, bytes);
                if (out.items.len > max_representation_bytes) return error.CapacityExceeded;
            }
            found += 1;
            if (coalesced(format) == .first) break;
        }
        if (found == 0) return error.FormatUnavailable;
        return if (found == 1) single else out.items;
    }
    /// Distinct formats in item order.
    pub fn formats(self: *const Snapshot, destination: []Format) usize {
        return self.data().formats(destination);
    }
};

/// Data whose bytes it owns, with no providers.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    data: Data = .{},

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Builds owned data an item at a time, copying every slice.
pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Item) = .empty,
    current: std.ArrayList(Representation) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .arena = .init(allocator) };
    }
    pub fn deinit(self: *Builder) void {
        self.arena.deinit();
        self.* = undefined;
    }
    /// Adds a representation to the current item. A format the item
    /// already has is replaced.
    pub fn add(self: *Builder, format: Format, bytes: []const u8) !void {
        if (!validFormat(format)) return error.InvalidFormat;
        const a = self.arena.allocator();
        const copy: Representation = .fromBytes(try a.dupe(u8, format), try a.dupe(u8, bytes));
        for (self.current.items) |*existing| if (std.mem.eql(u8, existing.format, format)) {
            existing.* = copy;
            return;
        };
        try self.current.append(a, copy);
    }
    /// Ends the current item; an empty item is dropped.
    pub fn endItem(self: *Builder) !void {
        if (self.current.items.len == 0) return;
        const a = self.arena.allocator();
        if (self.items.items.len == max_items) return error.TooManyItems;
        try self.items.append(a, .{ .representations = try self.current.toOwnedSlice(a) });
    }
    /// The finished data; the Builder is consumed.
    pub fn finish(self: *Builder) !Owned {
        try self.endItem();
        const items = try self.items.toOwnedSlice(self.arena.allocator());
        return .{ .arena = self.arena, .data = .{ .items = items } };
    }
};

/// Copies the representations in `wanted` into owned data, rendering lazy
/// ones. A failed representation fails the copy; no match is
/// FormatUnavailable.
pub fn materialize(allocator: std.mem.Allocator, snapshot: *Snapshot, wanted: []const Format) !Owned {
    var builder: Builder = .init(allocator);
    errdefer builder.deinit();
    for (snapshot.items, 0..) |item, index| {
        for (item.representations) |representation| {
            if (!contains(wanted, representation.format)) continue;
            try builder.add(representation.format, try snapshot.readItem(index, representation.format));
        }
        try builder.endItem();
    }
    if (builder.items.items.len == 0) return error.FormatUnavailable;
    return builder.finish();
}

/// Plain text as one item.
pub const TextData = struct {
    representation: [1]Representation,
    item: [1]Item = undefined,

    pub fn init(value: []const u8) TextData {
        return .{ .representation = .{.fromBytes(text, value)} };
    }
    /// Borrows self and the text; keep both in place while the data is used.
    pub fn data(self: *TextData) Data {
        self.item = .{.{ .representations = &self.representation }};
        return .{ .items = &self.item };
    }
};
/// A URL as a URI list and as plain text, one item.
pub const UrlData = struct {
    representation: [2]Representation,
    item: [1]Item = undefined,

    /// The URL needs a scheme and no CR, LF or NUL.
    pub fn init(url: []const u8) !UrlData {
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return error.InvalidUrl;
        if (colon == 0 or !std.ascii.isAlphabetic(url[0]) or std.mem.indexOfAny(u8, url, "\x00\r\n") != null) return error.InvalidUrl;
        for (url[0..colon]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return error.InvalidUrl;
        return .{ .representation = .{ .fromBytes(uri_list, url), .fromBytes(text, url) } };
    }
    pub fn data(self: *UrlData) Data {
        self.item = .{.{ .representations = &self.representation }};
        return .{ .items = &self.item };
    }
};

/// Existing absolute paths as escaped file URLs, one item per path with a
/// file list and a URI list. Files are neither read nor deleted.
pub fn fileData(allocator: std.mem.Allocator, paths: []const []const u8) !Owned {
    var builder: Builder = .init(allocator);
    errdefer builder.deinit();
    var url: std.ArrayList(u8) = .empty;
    defer url.deinit(allocator);
    for (paths) |path| {
        url.clearRetainingCapacity();
        try fileUrl(allocator, &url, path);
        try builder.add(file_list, url.items);
        try builder.add(uri_list, url.items);
        try builder.endItem();
    }
    return builder.finish();
}

/// `file:///...` for an absolute path, percent-escaping all but unreserved
/// bytes and path punctuation. Windows paths become `file:///C:/...`.
pub fn fileUrl(allocator: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) !void {
    const windows_path = path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
    if (std.mem.indexOfScalar(u8, path, 0) != null or !(windows_path or (path.len > 0 and path[0] == '/') or (builtin.os.tag == .windows and std.fs.path.isAbsoluteWindows(path)))) return error.PathNotAbsolute;
    try out.appendSlice(allocator, "file://");
    if (path[0] != '/' and path[0] != '\\') try out.append(allocator, '/');
    for (path) |byte| {
        const c = if (byte == '\\') '/' else byte;
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.~/$&+,:;=@", c) != null) {
            try out.append(allocator, c);
        } else try out.print(allocator, "%{X:0>2}", .{c});
    }
}

/// Lines of a URI list, without blanks and comments.
pub const UriIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn init(list: []const u8) UriIterator {
        return .{ .lines = std.mem.splitScalar(u8, list, '\n') };
    }
    pub fn next(self: *UriIterator) ?[]const u8 {
        while (self.lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0 and trimmed[0] != '#') return trimmed;
        }
        return null;
    }
};

/// The local path of a `file:` URL, decoded into `destination`, or null for
/// other schemes, remote hosts and paths that are not absolute, so a network
/// URL never becomes a filesystem path.
pub fn filePath(url: []const u8, destination: []u8) !?[]const u8 {
    if (url.len < 5 or !std.ascii.eqlIgnoreCase(url[0..5], "file:")) return null;
    var rest = url[5..];
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const host = rest[0..slash];
        if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
        rest = rest[slash..];
    }
    if (std.mem.indexOfAny(u8, rest, "?#") != null) rest = rest[0..std.mem.indexOfAny(u8, rest, "?#").?];
    var length: usize = 0;
    var index: usize = 0;
    while (index < rest.len) : (index += 1) {
        var byte = rest[index];
        if (byte == '%') {
            if (index + 2 >= rest.len) return null;
            byte = std.fmt.parseInt(u8, rest[index + 1 .. index + 3], 16) catch return null;
            index += 2;
        }
        if (byte == 0) return null;
        if (length == destination.len) return error.CapacityExceeded;
        destination[length] = byte;
        length += 1;
    }
    var path = destination[0..length];
    // "/C:/x" is a Windows drive path.
    if (path.len >= 3 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == ':') {
        path = path[1..];
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, path, '/', '\\');
        if (path.len < 3 or (path[2] != '/' and path[2] != '\\')) return null;
        return path;
    }
    if (builtin.os.tag == .windows) return null;
    if (path.len == 0 or path[0] != '/') return null;
    return path;
}

/// Local paths of the data's file list, or of its URI list without one,
/// NUL-separated as drop.Payload's files are. The bytes belong to the caller.
pub fn files(allocator: std.mem.Allocator, source: Data) ![]u8 {
    const list = source.read(allocator, file_list) catch |err| switch (err) {
        error.FormatUnavailable => try source.read(allocator, uri_list),
        else => return err,
    };
    defer allocator.free(list);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var uris: UriIterator = .init(list);
    while (uris.next()) |uri| {
        const path = (filePath(uri, &buffer) catch continue) orelse continue;
        if (out.items.len != 0) try out.append(allocator, 0);
        try out.appendSlice(allocator, path);
    }
    return out.toOwnedSlice(allocator);
}

test "operations negotiate the suggestion, then copy, then move" {
    try std.testing.expectEqual(Operation.copy, negotiate(.copy_move, .{}, .none));
    try std.testing.expectEqual(Operation.move, negotiate(.copy_move, .copy_move, .move));
    try std.testing.expectEqual(Operation.copy, negotiate(.copy_move, .copy_only, .move));
    try std.testing.expectEqual(Operation.move, negotiate(.{ .move = true }, .copy_move, .none));
    try std.testing.expectEqual(Operation.none, negotiate(.{ .move = true }, .{}, .none));
    try std.testing.expect((Operations{}).allowed().copy);
}

const Counter = struct {
    calls: usize = 0,
    fail: bool = false,
    fn render(ptr: *anyopaque, format: Format, sink: *Sink) anyerror!void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.fail) return error.ProviderFailed;
        try sink.set(format);
    }
};

test "snapshots render lazy representations once and coalesce items" {
    var counter: Counter = .{};
    var failing: Counter = .{ .fail = true };
    const lazy: Provider = .{ .context = &counter, .render = Counter.render };
    const items = [_]Item{
        .{ .representations = &.{ .fromBytes(text, "one"), .lazy("application/x-note", lazy) } },
        .{ .representations = &.{ .fromBytes(text, "two"), .fromBytes(uri_list, "file:///a") } },
        .{ .representations = &.{ .fromBytes(uri_list, "file:///b"), .lazy(html, .{ .context = &failing, .render = Counter.render }) } },
    };
    const source: Data = .{ .items = &items };
    var names: [8]Format = undefined;
    try std.testing.expectEqual(4, source.formats(&names));
    try std.testing.expectEqualStrings("application/x-note", names[1]);
    try std.testing.expectEqualStrings(html, source.preferred(&.{ "image/png", html, text }).?);
    try std.testing.expectEqual(0, counter.calls);

    var snapshot: Snapshot = try .init(std.testing.allocator, source);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("one\ntwo", try snapshot.read(text));
    try std.testing.expectEqualStrings("file:///a\r\nfile:///b", try snapshot.read(uri_list));
    try std.testing.expectEqualStrings("application/x-note", try snapshot.read("application/x-note"));
    try std.testing.expectEqualStrings("application/x-note", try snapshot.readItem(0, "application/x-note"));
    try std.testing.expectEqual(1, counter.calls);
    try std.testing.expectError(error.ProviderFailed, snapshot.read(html));
    try std.testing.expectError(error.ProviderFailed, snapshot.readItem(2, html));
    try std.testing.expectEqual(1, failing.calls);
    try std.testing.expectError(error.FormatUnavailable, snapshot.read(png));

    var owned = try materialize(std.testing.allocator, &snapshot, &.{ text, "application/x-note" });
    defer owned.deinit();
    try std.testing.expectEqual(2, owned.data.items.len);
    try std.testing.expectEqual(1, counter.calls);
    const joined = try owned.data.read(std.testing.allocator, text);
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("one\ntwo", joined);
    try std.testing.expectError(error.FormatUnavailable, materialize(std.testing.allocator, &snapshot, &.{png}));
}

test "data validation rejects empty items and duplicate or invalid formats" {
    try std.testing.expectError(error.InvalidItem, (Data{ .items = &.{.{ .representations = &.{} }} }).validate());
    try std.testing.expectError(error.DuplicateFormat, (Data{ .items = &.{.{ .representations = &.{ .fromBytes(text, "a"), .fromBytes(text, "b") } }} }).validate());
    try std.testing.expectError(error.InvalidFormat, (Data{ .items = &.{.{ .representations = &.{.fromBytes("a\nb", "")} }} }).validate());
    var url = try UrlData.init("https://example.com/a b");
    try (url.data()).validate();
    try std.testing.expectError(error.InvalidUrl, UrlData.init("no scheme"));
    try std.testing.expectError(error.InvalidUrl, UrlData.init("https://a\r\nb"));
}

test "file data round-trips through escaped file URLs" {
    const paths: []const []const u8 = if (builtin.os.tag == .windows) &.{ "C:\\notes & more\\a b.txt", "D:\\100%.txt" } else &.{ "/tmp/notes & more/a b.txt", "/tmp/100%#.txt" };
    var owned = try fileData(std.testing.allocator, paths);
    defer owned.deinit();
    try std.testing.expectEqual(2, owned.data.items.len);
    const list = try owned.data.read(std.testing.allocator, file_list);
    defer std.testing.allocator.free(list);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("file:///tmp/notes%20&%20more/a%20b.txt\r\nfile:///tmp/100%25%23.txt", list);
    const decoded = try files(std.testing.allocator, owned.data);
    defer std.testing.allocator.free(decoded);
    const expected = try std.mem.join(std.testing.allocator, "\x00", paths);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, decoded);
    try std.testing.expectError(error.PathNotAbsolute, fileData(std.testing.allocator, &.{"relative"}));

    var buffer: [64]u8 = undefined;
    try std.testing.expect(try filePath("https://example.com/a", &buffer) == null);
    try std.testing.expect(try filePath("file://server/share/a", &buffer) == null);
    try std.testing.expect(try filePath("file:///a%00b", &buffer) == null);
    try std.testing.expect(try filePath("file:///a%2", &buffer) == null);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("/a b", (try filePath("file://localhost/a%20b", &buffer)).?);
    var uris: UriIterator = .init("# comment\r\n\r\n file:///a \r\nhttps://b\n");
    try std.testing.expectEqualStrings("file:///a", uris.next().?);
    try std.testing.expectEqualStrings("https://b", uris.next().?);
    try std.testing.expect(uris.next() == null);
}

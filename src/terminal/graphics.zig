//! The Kitty graphics protocol, as Ghostty implements it: programs send
//! images in APC strings (`ESC _ G keys ; payload ESC \`), as raw RGB or
//! RGBA pixels or PNG, maybe compressed, maybe in chunks, directly or
//! through a file, and place them at the cursor, over the text or under
//! it. Each screen keeps its own images, up to a byte limit past which
//! the oldest go. Placements keep their rows as text scrolls, into the
//! scrollback with it.
const std = @import("std");
const builtin = @import("builtin");
const png = @import("png.zig");
const screen_module = @import("screen.zig");

const Screen = screen_module.Screen;

/// Ghostty's image-storage-limit.
pub const default_limit: usize = 320 * 1024 * 1024;
pub const max_dimension = 10000;
/// The most bytes one image's data takes, before and after decoding.
pub const max_size = 400 * 1024 * 1024;
const max_control = 1024;
const max_path = 4096;

pub const Format = enum {
    rgb,
    rgba,

    pub fn bytesPerPixel(self: Format) u32 {
        return switch (self) {
            .rgb => 3,
            .rgba => 4,
        };
    }
};

pub const Image = struct {
    id: u32,
    /// The number a program gave it (`I`), 0 for none.
    number: u32 = 0,
    width: u32,
    height: u32,
    format: Format,
    /// The pixels, row by row, with straight alpha.
    pixels: []u8,
    /// Unique to these pixels: a new transmission under the id changes it.
    generation: u64 = 0,
    /// The id was the terminal's choice, so commands about it get no answer.
    implicit_id: bool = false,
};

pub const Placement = struct {
    image_id: u32,
    /// The program's placement id, or one of the terminal's above 2^32
    /// when it gave none.
    id: u64,
    /// Shown through Unicode placeholder cells rather than where it is.
    virtual: bool = false,
    /// Its top left cell: a row counted as `Storage.top` counts them, and a
    /// column.
    row: u64,
    col: u16,
    /// Within the first cell, in pixels.
    x_offset: u32 = 0,
    y_offset: u32 = 0,
    /// The part of the image it shows, as the program asked: 0 for the
    /// rest of the image.
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    /// The cells it takes, as the program asked: 0 for what its pixels
    /// take.
    cols: u32 = 0,
    rows: u32 = 0,
    z: i32 = 0,
};

/// How a placement shows: the part of the image, the pixels it takes on
/// the screen, and its cells.
pub const Layout = struct {
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    width: u32,
    height: u32,
    cols: u32,
    rows: u32,
};

pub fn layout(p: Placement, image: Image, cell_width: u32, cell_height: u32) Layout {
    const cw = @max(cell_width, 1);
    const ch = @max(cell_height, 1);
    const sx = @min(image.width, p.src_x);
    const sy = @min(image.height, p.src_y);
    const sw = if (p.src_w > 0) @min(image.width - sx, p.src_w) else image.width - sx;
    const sh = if (p.src_h > 0) @min(image.height - sy, p.src_h) else image.height - sy;
    var width: u64 = if (p.cols > 0) @as(u64, p.cols) * cw else sw;
    var height: u64 = if (p.rows > 0) @as(u64, p.rows) * ch else sh;
    // Given only columns or rows, the image keeps its aspect.
    if (p.cols > 0 and p.rows == 0 and sw > 0) height = width * sh / sw;
    if (p.rows > 0 and p.cols == 0 and sh > 0) width = height * sw / sh;
    const cols = if (p.cols > 0 and p.rows > 0) p.cols else std.math.divCeil(u64, width + p.x_offset, cw) catch 0;
    const rows = if (p.cols > 0 and p.rows > 0) p.rows else std.math.divCeil(u64, height + p.y_offset, ch) catch 0;
    return .{
        .src_x = sx,
        .src_y = sy,
        .src_w = sw,
        .src_h = sh,
        .width = @intCast(@min(width, std.math.maxInt(u32))),
        .height = @intCast(@min(height, std.math.maxInt(u32))),
        .cols = @intCast(@min(cols, std.math.maxInt(u32))),
        .rows = @intCast(@min(rows, std.math.maxInt(u32))),
    };
}

/// A command's keys.
pub const Command = struct {
    action: u8 = 't',
    /// 1 keeps OK answers back, 2 errors too.
    quiet: u32 = 0,
    format: u32 = 32,
    medium: u8 = 'd',
    compression: u8 = 0,
    width: u32 = 0,
    height: u32 = 0,
    size: u32 = 0,
    offset: u32 = 0,
    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    more: bool = false,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    x_offset: u32 = 0,
    y_offset: u32 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
    z: i32 = 0,
    /// 1 leaves the cursor where it is.
    cursor: u32 = 0,
    virtual: bool = false,
    delete: u8 = 'a',

    pub fn parse(control: []const u8) error{InvalidCommand}!Command {
        var c: Command = .{};
        var it = std.mem.splitScalar(u8, control, ',');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            if (pair.len < 3 or pair[1] != '=') return error.InvalidCommand;
            const value = pair[2..];
            switch (pair[0]) {
                'a' => c.action = try char(value),
                'q' => c.quiet = try number(u32, value),
                'f' => c.format = try number(u32, value),
                't' => c.medium = try char(value),
                'o' => c.compression = try char(value),
                's' => c.width = try number(u32, value),
                'v' => c.height = try number(u32, value),
                'S' => c.size = try number(u32, value),
                'O' => c.offset = try number(u32, value),
                'i' => c.image_id = try number(u32, value),
                'I' => c.image_number = try number(u32, value),
                'p' => c.placement_id = try number(u32, value),
                'm' => c.more = try number(u32, value) == 1,
                'x' => c.x = try number(u32, value),
                'y' => c.y = try number(u32, value),
                'w' => c.w = try number(u32, value),
                'h' => c.h = try number(u32, value),
                'X' => c.x_offset = try number(u32, value),
                'Y' => c.y_offset = try number(u32, value),
                'c' => c.cols = try number(u32, value),
                'r' => c.rows = try number(u32, value),
                'z' => c.z = try number(i32, value),
                'C' => c.cursor = try number(u32, value),
                'U' => c.virtual = try number(u32, value) == 1,
                'd' => c.delete = try char(value),
                else => {},
            }
        }
        return c;
    }

    fn char(value: []const u8) error{InvalidCommand}!u8 {
        if (value.len != 1) return error.InvalidCommand;
        return value[0];
    }
    fn number(comptime T: type, value: []const u8) error{InvalidCommand}!T {
        return std.fmt.parseInt(T, value, 10) catch error.InvalidCommand;
    }
};

/// The answer to a command: `ESC _ G i=…[,I=…][,p=…];message ESC \`.
pub const Response = struct {
    id: u32 = 0,
    number: u32 = 0,
    placement: u32 = 0,
    message: []const u8 = "OK",

    pub fn ok(self: Response) bool {
        return std.mem.eql(u8, self.message, "OK");
    }
    /// With no id or number, there is nothing to answer about.
    pub fn empty(self: Response) bool {
        return self.id == 0 and self.number == 0;
    }
    pub fn write(self: Response, out: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(out);
        try w.writeAll("\x1b_G");
        var comma = false;
        if (self.id > 0) {
            try w.print("i={d}", .{self.id});
            comma = true;
        }
        if (self.number > 0) {
            try w.print("{s}I={d}", .{ if (comma) "," else "", self.number });
            comma = true;
        }
        if (self.placement > 0) try w.print("{s}p={d}", .{ if (comma) "," else "", self.placement });
        try w.print(";{s}\x1b\\", .{self.message});
        return w.buffered();
    }
};

const LoadError = error{
    OutOfMemory,
    InvalidData,
    DecompressionFailed,
    UnsupportedFormat,
    UnsupportedMedium,
    DimensionsRequired,
    DimensionsTooLarge,
    TemporaryFileNotInTempDir,
    TemporaryFileNotNamedCorrectly,
    FilePathTooLong,
};

fn message(err: LoadError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "ENOMEM: out of memory",
        error.InvalidData => "EINVAL: invalid data",
        error.DecompressionFailed => "EINVAL: decompression failed",
        error.UnsupportedFormat => "EINVAL: unsupported format",
        error.UnsupportedMedium => "EINVAL: unsupported medium",
        error.DimensionsRequired => "EINVAL: dimensions required",
        error.DimensionsTooLarge => "EINVAL: dimensions too large",
        error.TemporaryFileNotInTempDir => "EINVAL: temporary file not in temp dir",
        error.TemporaryFileNotNamedCorrectly => "EINVAL: temporary file not named correctly",
        error.FilePathTooLong => "EINVAL: file path too long",
    };
}

/// An image arriving, maybe in chunks.
const Loading = struct {
    command: Command,
    data: std.ArrayList(u8) = .empty,

    fn deinit(self: *Loading, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }

    fn init(allocator: std.mem.Allocator, command: Command, payload: []const u8) LoadError!Loading {
        var self: Loading = .{ .command = command };
        errdefer self.deinit(allocator);
        switch (command.format) {
            24, 32, 100 => {},
            else => return error.UnsupportedFormat,
        }
        if (command.compression != 0 and command.compression != 'z') return error.UnsupportedFormat;
        switch (command.medium) {
            'd' => try self.add(allocator, payload),
            'f', 't', 's' => try self.read(allocator, payload),
            else => return error.UnsupportedMedium,
        }
        return self;
    }

    fn add(self: *Loading, allocator: std.mem.Allocator, bytes: []const u8) LoadError!void {
        if (self.data.items.len + bytes.len > max_size) return error.InvalidData;
        try self.data.appendSlice(allocator, bytes);
    }

    /// The data of a file, a temporary file, which goes once read, or a
    /// shared memory object, which goes too.
    fn read(self: *Loading, allocator: std.mem.Allocator, path: []const u8) LoadError!void {
        if (path.len > max_path) return error.FilePathTooLong;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidData;
        const medium = self.command.medium;
        var shm_buffer: [max_path + 16]u8 = undefined;
        const file_path = if (medium == 's') shm: {
            if (builtin.os.tag != .linux) return error.UnsupportedMedium;
            const name = std.mem.trimLeft(u8, path, "/");
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidData;
            break :shm std.fmt.bufPrint(&shm_buffer, "/dev/shm/{s}", .{name}) catch return error.FilePathTooLong;
        } else path;
        if (!std.fs.path.isAbsolute(file_path)) return error.InvalidData;
        if (medium == 'f' or medium == 't') {
            if (std.mem.startsWith(u8, file_path, "/proc/") or std.mem.startsWith(u8, file_path, "/sys/") or
                (std.mem.startsWith(u8, file_path, "/dev/") and !std.mem.startsWith(u8, file_path, "/dev/shm/"))) return error.InvalidData;
        }
        if (medium == 't') {
            if (!inTempDir(allocator, file_path)) return error.TemporaryFileNotInTempDir;
            if (std.mem.indexOf(u8, file_path, "tty-graphics-protocol") == null) return error.TemporaryFileNotNamedCorrectly;
        }
        defer if (medium == 't' or medium == 's') std.fs.deleteFileAbsolute(file_path) catch {};
        var file = std.fs.openFileAbsolute(file_path, .{}) catch return error.InvalidData;
        defer file.close();
        const stat = file.stat() catch return error.InvalidData;
        if (stat.kind != .file) return error.InvalidData;
        const offset = @min(stat.size, self.command.offset);
        const available: u64 = stat.size - offset;
        const len: usize = @intCast(@min(if (self.command.size > 0) @min(available, self.command.size) else available, max_size));
        try self.data.resize(allocator, len);
        const n = file.preadAll(self.data.items, offset) catch return error.InvalidData;
        self.data.shrinkRetainingCapacity(n);
    }

    /// The image the data makes, validated; the data goes to it.
    fn complete(self: *Loading, allocator: std.mem.Allocator) LoadError!Image {
        const c = self.command;
        var data = self.data.toOwnedSlice(allocator) catch return error.OutOfMemory;
        errdefer allocator.free(data);
        if (c.compression == 'z') {
            const inflated = png.inflate(allocator, data, max_size) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.DecompressionFailed,
            };
            allocator.free(data);
            data = inflated;
        }
        var width = c.width;
        var height = c.height;
        var format: Format = if (c.format == 24) .rgb else .rgba;
        if (c.format == 100) {
            const decoded = png.decode(allocator, data, @as(u64, max_dimension) * max_dimension) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.TooLarge => error.DimensionsTooLarge,
                else => error.InvalidData,
            };
            allocator.free(data);
            data = decoded.pixels;
            width = decoded.width;
            height = decoded.height;
            format = .rgba;
        }
        if (width == 0 or height == 0) return error.DimensionsRequired;
        if (width > max_dimension or height > max_dimension) return error.DimensionsTooLarge;
        if (data.len != @as(u64, width) * height * format.bytesPerPixel()) return error.InvalidData;
        return .{ .id = c.image_id, .number = c.image_number, .width = width, .height = height, .format = format, .pixels = data };
    }
};

fn inTempDir(allocator: std.mem.Allocator, path: []const u8) bool {
    if (builtin.os.tag != .windows) {
        if (std.mem.startsWith(u8, path, "/tmp") or std.mem.startsWith(u8, path, "/dev/shm")) return true;
    }
    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |name| {
        const dir = std.process.getEnvVarOwned(allocator, name) catch continue;
        defer allocator.free(dir);
        if (dir.len > 0 and std.mem.startsWith(u8, path, dir)) return true;
    }
    return false;
}

/// What a command needs of the terminal: its screen, which one shows, and
/// the cell's size in pixels.
pub const Grid = struct {
    screen: *Screen,
    cell_width: u32,
    cell_height: u32,
};

/// The images and placements of one screen.
pub const Storage = struct {
    allocator: std.mem.Allocator,
    images: std.ArrayList(Image) = .empty,
    /// Ordered by z, those placed later after those placed before at one z.
    placements: std.ArrayList(Placement) = .empty,
    bytes: usize = 0,
    /// The most bytes images take; 0 refuses them all.
    limit: usize,
    /// Images in the order they arrived, for which go first.
    order: std.ArrayList(u32) = .empty,
    next_id: u32 = 2147483647,
    next_internal: u64 = 1 << 32,
    /// The last image's generation; storages start theirs apart.
    generation: u64,
    loading: ?Loading = null,
    /// Whether the image arriving has an id of the terminal's choice.
    implicit: bool = false,
    /// The quiet key of an image arriving in chunks, from its first.
    last_quiet: ?u32 = null,
    /// Changes whenever an image or placement does.
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, limit: usize, first_generation: u64) Storage {
        return .{ .allocator = allocator, .limit = limit, .generation = first_generation };
    }

    pub fn deinit(self: *Storage) void {
        self.clear();
        self.images.deinit(self.allocator);
        self.placements.deinit(self.allocator);
        self.order.deinit(self.allocator);
    }

    /// Forget every image and placement, and an image arriving.
    pub fn clear(self: *Storage) void {
        for (self.images.items) |img| self.allocator.free(img.pixels);
        self.images.clearRetainingCapacity();
        self.placements.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        if (self.loading) |*loading| loading.deinit(self.allocator);
        self.loading = null;
        self.bytes = 0;
        self.next_id = 2147483647;
        self.next_internal = 1 << 32;
        self.revision +%= 1;
    }

    pub fn image(self: *const Storage, id: u32) ?*const Image {
        for (self.images.items) |*i| if (i.id == id) return i;
        return null;
    }

    fn imageIndex(self: *const Storage, id: u32) ?usize {
        for (self.images.items, 0..) |i, at| if (i.id == id) return at;
        return null;
    }

    /// The newest image with a number.
    fn imageByNumber(self: *const Storage, n: u32) ?*const Image {
        var i = self.order.items.len;
        while (i > 0) {
            i -= 1;
            const found = self.image(self.order.items[i]) orelse continue;
            if (found.number == n) return found;
        }
        return null;
    }

    /// The row `Placement.row` counts for the top of the screen.
    pub fn top(screen: *const Screen) u64 {
        return if (screen.onAlternate()) screen.alternate_scrolled else screen.pushed;
    }

    /// Run a command, given its keys and its payload decoded; the answer,
    /// if the program gets one.
    pub fn execute(self: *Storage, control: []const u8, payload: []const u8, grid: Grid) ?Response {
        if (self.limit == 0) return null;
        const command = Command.parse(control) catch return null;
        self.prune(grid.screen);
        // Anything but more of an image arriving drops it.
        if (self.loading != null and command.action != 't' and command.action != 'T') {
            self.loading.?.deinit(self.allocator);
            self.loading = null;
        }
        const response: Response = switch (command.action) {
            'q' => query(self.allocator, command, payload),
            'p' => self.display(command, grid),
            'd' => self.delete(command, grid) orelse return null,
            't', 'T' => self.transmit(command, payload, grid),
            'f', 'a', 'c' => .{ .message = "ERROR: unimplemented action" },
            else => return null,
        };
        const quiet = if (self.last_quiet) |q| @max(q, command.quiet) else command.quiet;
        self.last_quiet = null;
        if (response.empty()) return null;
        return switch (quiet) {
            0 => response,
            1 => if (response.ok()) null else response,
            else => null,
        };
    }

    fn query(allocator: std.mem.Allocator, command: Command, payload: []const u8) Response {
        if (command.image_id == 0) return .{ .message = "EINVAL: image ID required" };
        var result: Response = .{ .id = command.image_id, .number = command.image_number, .placement = command.placement_id };
        var loading = Loading.init(allocator, command, payload) catch |err| {
            result.message = message(err);
            return result;
        };
        loading.deinit(allocator);
        return result;
    }

    fn transmit(self: *Storage, command: Command, payload: []const u8, grid: Grid) Response {
        if (self.loading) |*loading| {
            // More of an image: its first chunk's keys hold.
            const first = loading.command;
            self.last_quiet = first.quiet;
            var result: Response = .{ .id = if (first.image_id > 0 and !self.implicit) first.image_id else 0, .number = first.image_number, .placement = first.placement_id };
            loading.add(self.allocator, payload) catch |err| {
                loading.deinit(self.allocator);
                self.loading = null;
                result.message = message(err);
                return result;
            };
            if (command.more) return .{ .message = "" };
            var done = loading.*;
            self.loading = null;
            defer done.deinit(self.allocator);
            return self.finish(&done, self.implicit, grid);
        }
        if (command.image_id > 0 and command.image_number > 0) return .{ .message = "EINVAL: image ID and number are mutually exclusive" };
        var result: Response = .{ .id = command.image_id, .number = command.image_number, .placement = command.placement_id };
        var loading = Loading.init(self.allocator, command, payload) catch |err| {
            result.message = message(err);
            return result;
        };
        var implicit = false;
        if (loading.command.image_id == 0) {
            loading.command.image_id = self.next_id;
            self.next_id +%= 1;
            implicit = command.image_number == 0;
        }
        if (command.more) {
            self.loading = loading;
            self.implicit = implicit;
            return .{ .message = "" };
        }
        defer loading.deinit(self.allocator);
        return self.finish(&loading, implicit, grid);
    }

    fn finish(self: *Storage, loading: *Loading, implicit: bool, grid: Grid) Response {
        const c = loading.command;
        var result: Response = .{ .id = if (implicit) 0 else c.image_id, .number = c.image_number, .placement = c.placement_id };
        var img = loading.complete(self.allocator) catch |err| {
            result.message = message(err);
            return result;
        };
        img.implicit_id = implicit;
        self.add(img) catch |err| {
            self.allocator.free(img.pixels);
            result.message = message(err);
            return result;
        };
        if (c.action == 'T') {
            var shown = c;
            shown.image_number = 0;
            const answer = self.display(shown, grid);
            if (implicit) return .{ .message = answer.message, .number = c.image_number };
            var with = answer;
            with.number = c.image_number;
            return with;
        }
        return result;
    }

    /// Keep an image, in place of one of its id; the oldest go to make
    /// room, those no placement shows first.
    fn add(self: *Storage, img: Image) LoadError!void {
        if (img.pixels.len > self.limit) return error.OutOfMemory;
        const existing = self.imageIndex(img.id);
        const replaced = if (existing) |at| self.images.items[at].pixels.len else 0;
        if (self.bytes - replaced + img.pixels.len > self.limit) {
            if (!self.evict(self.bytes - replaced + img.pixels.len - self.limit, img.id)) return error.OutOfMemory;
        }
        try self.images.ensureUnusedCapacity(self.allocator, 1);
        try self.order.ensureUnusedCapacity(self.allocator, 1);
        var kept = img;
        self.generation +%= 1;
        kept.generation = self.generation;
        if (self.imageIndex(img.id)) |at| {
            self.bytes -= self.images.items[at].pixels.len;
            self.allocator.free(self.images.items[at].pixels);
            self.images.items[at] = kept;
            self.forgetOrder(img.id);
        } else self.images.appendAssumeCapacity(kept);
        self.order.appendAssumeCapacity(img.id);
        self.bytes += img.pixels.len;
        self.revision +%= 1;
    }

    fn forgetOrder(self: *Storage, id: u32) void {
        if (std.mem.indexOfScalar(u32, self.order.items, id)) |at| _ = self.order.orderedRemove(at);
    }

    /// Free at least `needed` bytes but those of `keep`: images no
    /// placement shows, oldest first, then those shown.
    fn evict(self: *Storage, needed: usize, keep: u32) bool {
        var freed: usize = 0;
        for ([_]bool{ false, true }) |used| {
            var i: usize = 0;
            while (i < self.order.items.len and freed < needed) {
                const id = self.order.items[i];
                if (id == keep or self.placed(id) != used) {
                    i += 1;
                    continue;
                }
                freed += self.image(id).?.pixels.len;
                self.removeImage(id);
            }
        }
        return freed >= needed;
    }

    fn placed(self: *const Storage, id: u32) bool {
        for (self.placements.items) |p| if (p.image_id == id) return true;
        return false;
    }

    /// Drop an image and its placements.
    fn removeImage(self: *Storage, id: u32) void {
        self.removePlacements(.{ .image = id });
        const at = self.imageIndex(id) orelse return;
        const gone = self.images.orderedRemove(at);
        self.bytes -= gone.pixels.len;
        self.allocator.free(gone.pixels);
        self.forgetOrder(id);
        self.revision +%= 1;
    }

    fn display(self: *Storage, command: Command, grid: Grid) Response {
        if (command.image_id == 0 and command.image_number == 0) return .{ .message = "EINVAL: image ID or number required" };
        var result: Response = .{ .id = command.image_id, .number = command.image_number, .placement = command.placement_id };
        const img = (if (command.image_id != 0) self.image(command.image_id) else self.imageByNumber(command.image_number)) orelse {
            result.message = "ENOENT: image not found";
            return result;
        };
        result.id = img.id;
        const s = grid.screen;
        const placement: Placement = .{
            .image_id = img.id,
            .id = if (command.placement_id > 0) command.placement_id else id: {
                self.next_internal += 1;
                break :id self.next_internal;
            },
            .virtual = command.virtual,
            .row = top(s) + s.cursor.y,
            .col = s.cursor.x,
            .x_offset = command.x_offset,
            .y_offset = command.y_offset,
            .src_x = command.x,
            .src_y = command.y,
            .src_w = command.w,
            .src_h = command.h,
            .cols = command.cols,
            .rows = command.rows,
            .z = command.z,
        };
        self.place(placement) catch |err| {
            result.message = message(err);
            return result;
        };
        // The cursor goes past it: to its last row, after its last column.
        if (!command.virtual and command.cursor != 1) {
            const size = layout(placement, img.*, grid.cell_width, grid.cell_height);
            for (1..@max(size.rows, 1)) |_| s.index();
            s.cursor.x = @intCast(@min(@as(u64, placement.col) + size.cols, s.cols - 1));
            s.cursor.pending_wrap = false;
        }
        return result;
    }

    /// Add a placement in place of one of its image and id.
    fn place(self: *Storage, placement: Placement) LoadError!void {
        try self.placements.ensureUnusedCapacity(self.allocator, 1);
        self.removePlacements(.{ .image = placement.image_id, .placement = placement.id });
        var at = self.placements.items.len;
        while (at > 0 and self.placements.items[at - 1].z > placement.z) at -= 1;
        self.placements.insertAssumeCapacity(at, placement);
        self.revision +%= 1;
    }

    const Filter = struct {
        image: ?u32 = null,
        placement: ?u64 = null,
    };

    fn removePlacements(self: *Storage, filter: Filter) void {
        var kept: usize = 0;
        for (self.placements.items) |p| {
            const gone = (filter.image == null or filter.image.? == p.image_id) and (filter.placement == null or filter.placement.? == p.id);
            if (gone) continue;
            self.placements.items[kept] = p;
            kept += 1;
        }
        if (kept != self.placements.items.len) self.revision +%= 1;
        self.placements.shrinkRetainingCapacity(kept);
    }

    /// Drop placements that left the scrollback.
    pub fn prune(self: *Storage, screen: *const Screen) void {
        const first = if (screen.onAlternate()) screen.alternate_scrolled else screen.firstRow();
        var kept: usize = 0;
        for (self.placements.items) |p| {
            if (!p.virtual and p.row < first) continue;
            self.placements.items[kept] = p;
            kept += 1;
        }
        if (kept != self.placements.items.len) self.revision +%= 1;
        self.placements.shrinkRetainingCapacity(kept);
    }

    /// Delete placements, and with an uppercase `d` the images they leave
    /// unshown. Nothing to answer unless the command is wrong.
    fn delete(self: *Storage, command: Command, grid: Grid) ?Response {
        const d = command.delete;
        const images = std.ascii.isUpper(d);
        const s = grid.screen;
        const base = top(s);
        switch (std.ascii.toLower(d)) {
            'a' => if (images) self.clear() else {
                self.placements.clearRetainingCapacity();
                self.revision +%= 1;
            },
            'i', 'n' => {
                const img = (if (d == 'i' or d == 'I') self.image(command.image_id) else self.imageByNumber(command.image_number)) orelse return null;
                const id = img.id;
                if (command.placement_id > 0) self.removePlacements(.{ .image = id, .placement = command.placement_id }) else self.removePlacements(.{ .image = id });
                if (images) self.dropIfUnused(id);
            },
            'c' => self.deleteWhere(.{ .row = base + s.cursor.y, .col = s.cursor.x }, null, images, grid),
            'p' => self.deleteWhere(.{ .row = base + command.y -| 1, .col = command.x -| 1 }, null, images, grid),
            'q' => self.deleteWhere(.{ .row = base + command.y -| 1, .col = command.x -| 1 }, command.z, images, grid),
            'x' => self.deleteWhere(.{ .col = command.x -| 1 }, null, images, grid),
            'y' => self.deleteWhere(.{ .row = base + command.y -| 1 }, null, images, grid),
            'z' => self.deleteWhere(.{}, command.z, images, grid),
            'r' => {
                if (command.x == 0 or command.y == 0 or command.x > command.y) return .{ .message = "EINVAL: invalid range" };
                var i: usize = 0;
                while (i < self.images.items.len) {
                    const id = self.images.items[i].id;
                    if (id >= command.x and id <= command.y) {
                        self.removePlacements(.{ .image = id });
                        if (images) {
                            self.removeImage(id);
                            continue;
                        }
                    }
                    i += 1;
                }
            },
            'f' => {},
            else => return null,
        }
        return .{ .message = "" };
    }

    const Cell = struct { row: ?u64 = null, col: ?u32 = null };

    /// Delete the placements over a cell, a row or a column, of a z.
    fn deleteWhere(self: *Storage, cell: Cell, z: ?i32, images: bool, grid: Grid) void {
        var i: usize = 0;
        while (i < self.placements.items.len) {
            const p = self.placements.items[i];
            const img = self.image(p.image_id) orelse {
                i += 1;
                continue;
            };
            const size = layout(p, img.*, grid.cell_width, grid.cell_height);
            const over = !p.virtual and
                (cell.row == null or (cell.row.? >= p.row and cell.row.? < p.row + size.rows)) and
                (cell.col == null or (cell.col.? >= p.col and cell.col.? < @as(u64, p.col) + size.cols)) and
                (z == null or z.? == p.z);
            if (!over) {
                i += 1;
                continue;
            }
            _ = self.placements.orderedRemove(i);
            self.revision +%= 1;
            if (images) self.dropIfUnused(p.image_id);
        }
    }

    fn dropIfUnused(self: *Storage, id: u32) void {
        if (!self.placed(id)) self.removeImage(id);
    }
};

/// Collects an APC string: a Kitty graphics command's keys and its
/// payload, decoded from base64 as it arrives.
pub const Receiver = struct {
    state: enum { kind, control, payload, ignore } = .ignore,
    control_bytes: [max_control]u8 = undefined,
    control_len: usize = 0,
    payload: std.ArrayList(u8) = .empty,
    bits: u32 = 0,
    bit_count: u5 = 0,
    /// The most payload bytes kept; a longer payload drops the command.
    limit: usize = max_size,

    pub fn deinit(self: *Receiver, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
    }

    pub fn start(self: *Receiver, allocator: std.mem.Allocator) void {
        self.state = .kind;
        self.control_len = 0;
        self.bits = 0;
        self.bit_count = 0;
        // A big image's room goes once it is done with.
        if (self.payload.capacity > 1024 * 1024) {
            self.payload.clearAndFree(allocator);
        } else self.payload.clearRetainingCapacity();
    }

    pub fn data(self: *Receiver, allocator: std.mem.Allocator, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) switch (self.state) {
            .ignore => return,
            .kind => {
                self.state = if (rest[0] == 'G') .control else .ignore;
                rest = rest[1..];
            },
            .control => {
                const stop = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                if (self.control_len + stop > max_control) {
                    self.state = .ignore;
                    return;
                }
                @memcpy(self.control_bytes[self.control_len..][0..stop], rest[0..stop]);
                self.control_len += stop;
                if (stop < rest.len) {
                    self.state = .payload;
                    rest = rest[stop + 1 ..];
                } else return;
            },
            .payload => {
                // At most three bytes for each four characters.
                if (self.payload.items.len + rest.len / 4 * 3 + 3 > self.limit) {
                    self.state = .ignore;
                    return;
                }
                self.payload.ensureUnusedCapacity(allocator, rest.len / 4 * 3 + 3) catch {
                    self.state = .ignore;
                    return;
                };
                for (rest) |c| {
                    const value: u32 = switch (c) {
                        'A'...'Z' => c - 'A',
                        'a'...'z' => c - 'a' + 26,
                        '0'...'9' => c - '0' + 52,
                        '+', '-' => 62,
                        '/', '_' => 63,
                        '=' => {
                            // Padding ends a group: what bits are left
                            // are not a byte.
                            self.bits = 0;
                            self.bit_count = 0;
                            continue;
                        },
                        ' ', '\t', '\r', '\n' => continue,
                        else => {
                            self.state = .ignore;
                            return;
                        },
                    };
                    self.bits = (self.bits << 6) | value;
                    self.bit_count += 6;
                    if (self.bit_count >= 8) {
                        self.bit_count -= 8;
                        self.payload.appendAssumeCapacity(@truncate(self.bits >> self.bit_count));
                        self.bits &= (@as(u32, 1) << self.bit_count) - 1;
                    }
                }
                return;
            },
        };
    }

    /// The command, when the string was one, until the next `start`.
    pub fn end(self: *Receiver) ?struct { control: []const u8, payload: []const u8 } {
        defer self.state = .ignore;
        return switch (self.state) {
            .control, .payload => .{ .control = self.control_bytes[0..self.control_len], .payload = self.payload.items },
            else => null,
        };
    }
};

// ---- Tests -----------------------------------------------------------------

const Harness = struct {
    screen: Screen,
    storage: Storage,
    receiver: Receiver = .{},
    answer: [256]u8 = undefined,
    answer_len: usize = 0,

    fn init(self: *Harness, rows: u16) !void {
        return self.initWith(rows, 100);
    }
    fn initWith(self: *Harness, rows: u16, scrollback: u32) !void {
        self.* = .{ .screen = try Screen.init(std.testing.allocator, .{ .cols = 20, .rows = rows, .scrollback = scrollback, .scrollback_cells = 2000 }), .storage = undefined };
        self.storage = .init(std.testing.allocator, default_limit, 0);
    }
    fn deinit(self: *Harness) void {
        self.storage.deinit();
        self.receiver.deinit(std.testing.allocator);
        self.screen.deinit();
    }
    /// Run an APC string's body, `G…`, sent in pieces of `piece` bytes.
    fn run(self: *Harness, body: []const u8) []const u8 {
        self.receiver.start(std.testing.allocator);
        var rest = body;
        while (rest.len > 0) {
            const n = @min(rest.len, 7);
            self.receiver.data(std.testing.allocator, rest[0..n]);
            rest = rest[n..];
        }
        const command = self.receiver.end() orelse return "";
        const response = self.storage.execute(command.control, command.payload, .{ .screen = &self.screen, .cell_width = 10, .cell_height = 20 }) orelse return "";
        return response.write(&self.answer) catch "";
    }
};

fn encoded(comptime raw: []const u8) []const u8 {
    const encoder = std.base64.standard.Encoder;
    var out: [encoder.calcSize(raw.len)]u8 = undefined;
    _ = encoder.encode(&out, raw);
    const final = out;
    return &final;
}

test "transmits, places and moves the cursor past the image" {
    var h: Harness = undefined;
    try h.init(5);
    defer h.deinit();
    // 2x1 RGB, at 10x20 cells: one row, one column... 2 pixels wide.
    const px = comptime encoded("\xff\x00\x00\x00\xff\x00");
    try std.testing.expectEqualStrings("\x1b_Gi=7;OK\x1b\\", h.run("Ga=t,f=24,s=2,v=1,i=7;" ++ px));
    try std.testing.expectEqual(@as(usize, 6), h.storage.bytes);
    try std.testing.expectEqualSlices(u8, "\xff\x00\x00\x00\xff\x00", h.storage.image(7).?.pixels);
    h.screen.moveTo(3, 1);
    // Four cells by two: the cursor goes down a row, past the columns.
    try std.testing.expectEqualStrings("\x1b_Gi=7,p=2;OK\x1b\\", h.run("Ga=p,i=7,p=2,c=4,r=2"));
    try std.testing.expectEqual(@as(u16, 2), h.screen.cursor.y);
    try std.testing.expectEqual(@as(u16, 7), h.screen.cursor.x);
    const p = h.storage.placements.items[0];
    try std.testing.expectEqual(@as(u64, 1), p.row);
    try std.testing.expectEqual(@as(u16, 3), p.col);
    // The same id again moves it; C=1 keeps the cursor.
    h.screen.moveTo(0, 4);
    _ = h.run("Ga=p,i=7,p=2,C=1,q=1");
    try std.testing.expectEqual(@as(usize, 1), h.storage.placements.items.len);
    try std.testing.expectEqual(@as(u64, 4), h.storage.placements.items[0].row);
    try std.testing.expectEqual(@as(u16, 0), h.screen.cursor.x);
    // Unknown images and missing ids are errors.
    try std.testing.expectEqualStrings("\x1b_Gi=9;ENOENT: image not found\x1b\\", h.run("Ga=p,i=9"));
    try std.testing.expectEqualStrings("", h.run("Ga=p,i=9,q=2"));
    try std.testing.expectEqualStrings("\x1b_Gi=8;EINVAL: invalid data\x1b\\", h.run("Ga=t,f=24,s=2,v=2,i=8;" ++ px));
    try std.testing.expectEqualStrings("\x1b_Gi=8;EINVAL: dimensions required\x1b\\", h.run("Ga=t,f=32,i=8;" ++ px));
}

test "chunks, implicit ids, numbers and compression" {
    var h: Harness = undefined;
    try h.init(5);
    defer h.deinit();
    const px = comptime encoded("\x01\x02\x03\x04\x05\x06\x07\x08");
    // In chunks with no id: placed, and nothing said.
    try std.testing.expectEqualStrings("", h.run("Ga=T,f=32,s=2,v=1,m=1;" ++ px[0..4]));
    try std.testing.expectEqual(@as(usize, 0), h.storage.images.items.len);
    try std.testing.expectEqualStrings("", h.run("Gm=0;" ++ px[4..]));
    try std.testing.expectEqual(@as(usize, 1), h.storage.images.items.len);
    try std.testing.expectEqual(@as(u32, 2147483647), h.storage.images.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), h.storage.placements.items.len);
    // A number gets an id and an answer with both.
    try std.testing.expectEqualStrings("\x1b_Gi=2147483648,I=13;OK\x1b\\", h.run("Ga=t,f=32,s=2,v=1,I=13;" ++ px));
    try std.testing.expectEqualStrings("\x1b_Gi=2147483648,I=13;OK\x1b\\", h.run("Ga=p,I=13"));
    // Both an id and a number: wrong, with nothing to answer about.
    try std.testing.expectEqualStrings("", h.run("Ga=t,i=1,I=13;" ++ px));
    // zlib, a stored block.
    const z = comptime encoded("\x78\x01\x01\x04\x00\xfb\xff\x09\x08\x07\x06" ++ "\x00\x54\x00\x1f");
    try std.testing.expectEqualStrings("\x1b_Gi=3;OK\x1b\\", h.run("Ga=t,f=32,s=1,v=1,o=z,i=3;" ++ z));
    try std.testing.expectEqualSlices(u8, "\x09\x08\x07\x06", h.storage.image(3).?.pixels);
    // A query checks without keeping.
    try std.testing.expectEqualStrings("\x1b_Gi=31;OK\x1b\\", h.run("Ga=q,i=31,s=1,v=1,f=24;AAAA"));
    try std.testing.expect(h.storage.image(31) == null);
    try std.testing.expectEqualStrings("\x1b_Gi=31;EINVAL: unsupported format\x1b\\", h.run("Ga=q,i=31,f=7;AAAA"));
}

test "PNG decodes to RGBA" {
    var h: Harness = undefined;
    try h.init(5);
    defer h.deinit();
    const pixels = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 128 };
    const file = try png.encodeForTest(std.testing.allocator, 2, 1, &pixels, 1);
    defer std.testing.allocator.free(file);
    const text = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(file.len) + 32);
    defer std.testing.allocator.free(text);
    const head = "Gf=100,i=4;";
    @memcpy(text[0..head.len], head);
    const body = std.base64.standard.Encoder.encode(text[head.len..], file);
    try std.testing.expectEqualStrings("\x1b_Gi=4;OK\x1b\\", h.run(text[0 .. head.len + body.len]));
    const img = h.storage.image(4).?;
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqualSlices(u8, &pixels, img.pixels);
}

test "deletes by id, cell and z, and frees images with uppercase" {
    var h: Harness = undefined;
    try h.init(5);
    defer h.deinit();
    const px = comptime encoded("\x01\x02\x03\x04");
    _ = h.run("Ga=t,f=32,s=1,v=1,i=1,q=2;" ++ px);
    _ = h.run("Ga=t,f=32,s=1,v=1,i=2,q=2;" ++ px);
    _ = h.run("Ga=p,i=1,p=1,c=2,r=1,z=5,q=2");
    _ = h.run("Ga=p,i=1,p=2,c=2,r=1,z=-1,q=2");
    h.screen.moveTo(10, 3);
    _ = h.run("Ga=p,i=2,c=2,r=2,q=2");
    // Ordered by z.
    try std.testing.expectEqual(@as(i32, -1), h.storage.placements.items[0].z);
    // By cell: column 11, row 5 is the third placement's.
    _ = h.run("Ga=d,d=p,x=11,y=5");
    try std.testing.expectEqual(@as(usize, 2), h.storage.placements.items.len);
    try std.testing.expect(h.storage.image(2) != null);
    _ = h.run("Ga=d,d=z,z=5");
    try std.testing.expectEqual(@as(usize, 1), h.storage.placements.items.len);
    // Uppercase frees what is left unplaced.
    _ = h.run("Ga=d,d=I,i=1");
    try std.testing.expect(h.storage.image(1) == null);
    try std.testing.expect(h.storage.image(2) != null);
    _ = h.run("Ga=d,d=A");
    try std.testing.expectEqual(@as(usize, 0), h.storage.images.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.storage.bytes);
}

test "the oldest images go past the limit, unplaced ones first" {
    var h: Harness = undefined;
    try h.init(5);
    defer h.deinit();
    h.storage.limit = 12;
    const px = comptime encoded("\x01\x02\x03\x04");
    _ = h.run("Ga=T,f=32,s=1,v=1,i=1,q=2;" ++ px);
    _ = h.run("Ga=t,f=32,s=1,v=1,i=2,q=2;" ++ px);
    _ = h.run("Ga=t,f=32,s=1,v=1,i=3,q=2;" ++ px);
    _ = h.run("Ga=t,f=32,s=1,v=1,i=4,q=2;" ++ px);
    try std.testing.expect(h.storage.image(1) != null);
    try std.testing.expect(h.storage.image(2) == null);
    try std.testing.expectEqual(@as(usize, 12), h.storage.bytes);
    try std.testing.expectEqualStrings("\x1b_Gi=5;ENOMEM: out of memory\x1b\\", h.run("Ga=t,f=32,s=2,v=2,i=5;" ++ comptime encoded("0123456789abcdef")));
}

test "placements scroll with the text and go with the scrollback" {
    var h: Harness = undefined;
    try h.initWith(3, 2);
    defer h.deinit();
    const px = comptime encoded("\x01\x02\x03\x04");
    _ = h.run("Ga=T,f=32,s=1,v=1,i=1,C=1,q=2;" ++ px);
    for (0..3) |_| h.screen.lineFeed();
    // A line up, into the scrollback: its row stays, the screen's moves.
    _ = h.run("Ga=d,d=z,z=9");
    try std.testing.expectEqual(@as(u64, 0), h.storage.placements.items[0].row);
    try std.testing.expectEqual(@as(u64, 1), Storage.top(&h.screen));
    // Three lines up, past a scrollback of two, it goes.
    for (0..2) |_| h.screen.lineFeed();
    _ = h.run("Ga=d,d=z,z=9");
    try std.testing.expectEqual(@as(usize, 0), h.storage.placements.items.len);
}

test "receiver decodes padded chunks and drops other strings" {
    var r: Receiver = .{};
    defer r.deinit(std.testing.allocator);
    r.start(std.testing.allocator);
    r.data(std.testing.allocator, "Gi=1;YQ==Yg");
    r.data(std.testing.allocator, "==");
    const command = r.end().?;
    try std.testing.expectEqualStrings("i=1", command.control);
    try std.testing.expectEqualStrings("ab", command.payload);
    r.start(std.testing.allocator);
    r.data(std.testing.allocator, "Xyz");
    try std.testing.expect(r.end() == null);
    r.start(std.testing.allocator);
    r.data(std.testing.allocator, "Gi=1;a!b");
    try std.testing.expect(r.end() == null);
}

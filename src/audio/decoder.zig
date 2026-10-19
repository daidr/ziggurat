const std = @import("std");

/// Failures of inputs, decoders and the formats that open them.
pub const Error = error{
    /// The bytes are not the format they claim to be, or are cut short.
    InvalidData,
    /// A valid file of an encoding this decoder does not play.
    UnsupportedEncoding,
    /// No format in the list matches the data.
    UnknownFormat,
    /// A position beyond the end.
    OutOfRange,
    ReadFailed,
    SeekFailed,
    OutOfMemory,
};

/// Seekable bytes a format decodes from. The context stays at a stable
/// address while a decoder reads it; the decoder never closes it.
pub const Input = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Reads up to `buffer.len` bytes; 0 only at the end.
        read: *const fn (context: *anyopaque, buffer: []u8) Error!usize,
        seekTo: *const fn (context: *anyopaque, offset: u64) Error!void,
        /// Total bytes.
        size: *const fn (context: *anyopaque) Error!u64,
    };

    pub fn read(self: Input, buffer: []u8) Error!usize {
        return self.vtable.read(self.context, buffer);
    }

    /// Reads until `buffer` is full or the input ends; returns the count.
    pub fn readAll(self: Input, buffer: []u8) Error!usize {
        var filled: usize = 0;
        while (filled < buffer.len) {
            const count = try self.read(buffer[filled..]);
            if (count == 0) break;
            filled += count;
        }
        return filled;
    }

    pub fn seekTo(self: Input, offset: u64) Error!void {
        return self.vtable.seekTo(self.context, offset);
    }

    pub fn size(self: Input) Error!u64 {
        return self.vtable.size(self.context);
    }
};

/// Borrowed bytes as an Input. The bytes outlive every reader.
pub const BytesInput = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn input(self: *BytesInput) Input {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: Input.VTable = .{ .read = readFn, .seekTo = seekFn, .size = sizeFn };

    fn readFn(context: *anyopaque, buffer: []u8) Error!usize {
        const self: *BytesInput = @ptrCast(@alignCast(context));
        const count = @min(buffer.len, self.bytes.len - self.position);
        @memcpy(buffer[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }

    fn seekFn(context: *anyopaque, offset: u64) Error!void {
        const self: *BytesInput = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len) return error.SeekFailed;
        self.position = @intCast(offset);
    }

    fn sizeFn(context: *anyopaque) Error!u64 {
        const self: *BytesInput = @ptrCast(@alignCast(context));
        return self.bytes.len;
    }
};

/// A file as an Input, read through a buffer of its own. The input does not
/// close the file.
pub const FileInput = struct {
    file: std.fs.File,
    buffer: [16 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    /// File offset of `buffer[end]`.
    offset: u64 = 0,

    pub fn init(file: std.fs.File) FileInput {
        return .{ .file = file };
    }

    pub fn input(self: *FileInput) Input {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: Input.VTable = .{ .read = readFn, .seekTo = seekFn, .size = sizeFn };

    fn readFn(context: *anyopaque, out: []u8) Error!usize {
        const self: *FileInput = @ptrCast(@alignCast(context));
        if (self.start == self.end) {
            if (out.len >= self.buffer.len) {
                const count = self.file.pread(out, self.offset) catch return error.ReadFailed;
                self.offset += count;
                return count;
            }
            const count = self.file.pread(&self.buffer, self.offset) catch return error.ReadFailed;
            self.offset += count;
            self.start = 0;
            self.end = count;
            if (count == 0) return 0;
        }
        const count = @min(out.len, self.end - self.start);
        @memcpy(out[0..count], self.buffer[self.start..][0..count]);
        self.start += count;
        return count;
    }

    fn seekFn(context: *anyopaque, offset: u64) Error!void {
        const self: *FileInput = @ptrCast(@alignCast(context));
        const first = self.offset - self.end;
        if (offset >= first and offset <= self.offset) {
            self.start = @intCast(offset - first);
            return;
        }
        self.start = 0;
        self.end = 0;
        self.offset = offset;
    }

    fn sizeFn(context: *anyopaque) Error!u64 {
        const self: *FileInput = @ptrCast(@alignCast(context));
        const stat = self.file.stat() catch return error.ReadFailed;
        return stat.size;
    }
};

/// Decodes audio as interleaved `f32` samples in [-1, 1], one per channel
/// for each frame. Formats return one; implement one to play sound an app
/// generates itself. A decoder is used by one thread at a time: a stream's
/// runs on the engine's decoding thread.
pub const Decoder = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// Frames per second.
    sample_rate: u32,
    /// Samples per frame: 1 mono, 2 stereo (left, right); channels past the
    /// second are not played.
    channels: u16,
    /// Frames from the start to the end, or null when unknown.
    frames: ?u64,

    pub const VTable = struct {
        /// Decodes the next samples into `buffer`, a whole number of
        /// frames, and returns how many it wrote: 0 only at the end.
        read: *const fn (context: *anyopaque, buffer: []f32) Error!usize,
        /// Moves to `frame`, counted from the start.
        setPosition: *const fn (context: *anyopaque, frame: u64) Error!void,
        /// Frees what the decoder owns, closing any input it owns.
        deinit: *const fn (context: *anyopaque) void,
    };

    pub fn read(self: Decoder, buffer: []f32) Error!usize {
        return self.vtable.read(self.context, buffer);
    }

    pub fn setPosition(self: Decoder, frame: u64) Error!void {
        return self.vtable.setPosition(self.context, frame);
    }

    pub fn deinit(self: Decoder) void {
        self.vtable.deinit(self.context);
    }
};

/// A format the engine detects by its first bytes: `magic` is the start of
/// its files, where '?' matches any byte. `open` returns a decoder reading
/// `input` from offset 0; the input outlives the decoder.
pub const Format = struct {
    name: []const u8,
    magic: []const u8,
    open: *const fn (allocator: std.mem.Allocator, input: Input) Error!Decoder,
};

pub fn matches(magic: []const u8, head: []const u8) bool {
    if (magic.len > head.len) return false;
    for (magic, head[0..magic.len]) |want, got| {
        if (want != '?' and want != got) return false;
    }
    return true;
}

pub const Opened = struct { decoder: Decoder, format: []const u8 };

/// Opens a decoder of the first format matching the input's first bytes.
pub fn open(allocator: std.mem.Allocator, input: Input, formats: []const Format) Error!Opened {
    try input.seekTo(0);
    var head: [16]u8 = undefined;
    const count = try input.readAll(&head);
    try input.seekTo(0);
    for (formats) |format| {
        if (matches(format.magic, head[0..count])) return .{ .decoder = try format.open(allocator, input), .format = format.name };
    }
    return error.UnknownFormat;
}

test "magic matches with wildcards" {
    try std.testing.expect(matches("RIFF????WAVE", "RIFF\x01\x02\x03\x04WAVEfmt "));
    try std.testing.expect(!matches("RIFF????WAVE", "RIFF\x01\x02\x03\x04WAVX"));
    try std.testing.expect(!matches("fLaC", "fLa"));
}

test "bytes input reads and seeks" {
    var bytes = BytesInput{ .bytes = "abcdef" };
    const input = bytes.input();
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try input.readAll(&buffer));
    try std.testing.expectEqualStrings("abcd", &buffer);
    try input.seekTo(5);
    try std.testing.expectEqual(@as(usize, 1), try input.read(&buffer));
    try std.testing.expectEqual(@as(usize, 0), try input.read(&buffer));
    try std.testing.expectError(error.SeekFailed, input.seekTo(7));
}

test "file input reads through its buffer and seeks" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var data: [40000]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index * 7);
    try dir.dir.writeFile(.{ .sub_path = "data", .data = &data });
    const file = try dir.dir.openFile("data", .{});
    defer file.close();
    var file_input = FileInput.init(file);
    const input = file_input.input();
    try std.testing.expectEqual(@as(u64, data.len), try input.size());
    var buffer: [100]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 100), try input.readAll(&buffer));
    try std.testing.expectEqualSlices(u8, data[0..100], &buffer);
    try input.seekTo(50);
    try std.testing.expectEqual(@as(usize, 100), try input.readAll(&buffer));
    try std.testing.expectEqualSlices(u8, data[50..150], &buffer);
    try input.seekTo(30000);
    try std.testing.expectEqual(@as(usize, 100), try input.readAll(&buffer));
    try std.testing.expectEqualSlices(u8, data[30000..30100], &buffer);
    var large: [20000]u8 = undefined;
    try input.seekTo(10);
    try std.testing.expectEqual(@as(usize, 20000), try input.readAll(&large));
    try std.testing.expectEqualSlices(u8, data[10..20010], &large);
    try input.seekTo(39990);
    try std.testing.expectEqual(@as(usize, 10), try input.readAll(&buffer));
}

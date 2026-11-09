//! `ziggurat-pe-resources IMAGE.exe RESOURCES.obj`: adds the `.rsrc` section
//! of a resource object (as `zig rc /:output-format coff` writes it) to a
//! linked Windows image, in place. Zig's own COFF linker drops resource
//! sections, so Debug builds that use it get their icons, manifest and
//! version information this way. Patching in place keeps one copy of each
//! image in the cache; an image that already has resources is left as is.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        std.debug.print("usage: ziggurat-pe-resources IMAGE.exe RESOURCES.obj\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const image = try cwd.readFileAlloc(init.io, args[1], allocator, .limited(1024 * 1024 * 1024));
    const object = try cwd.readFileAlloc(init.io, args[2], allocator, .limited(256 * 1024 * 1024));
    const output = addResources(allocator, image, object) catch |err| switch (err) {
        error.AlreadyHasResources => return,
        else => {
            std.debug.print("{s}: {s}\n", .{ args[1], @errorName(err) });
            std.process.exit(1);
        },
    };
    try cwd.writeFile(init.io, .{ .sub_path = args[1], .data = output });
}

fn read(comptime T: type, bytes: []const u8, offset: usize) !T {
    if (offset + @sizeOf(T) > bytes.len) return error.Truncated;
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn write(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

const section_header_size = 40;
const resource_directory = 2;
const certificate_directory = 4;

/// Lays out every `.rsrc*` section of the object (in name order, as a linker
/// groups `$`-suffixed sections) at `rva` and applies its image-relative
/// relocations. Returns the section's raw contents.
fn resourceSection(allocator: std.mem.Allocator, object: []const u8, rva: u32) ![]u8 {
    const machine = try read(u16, object, 0);
    const section_count = try read(u16, object, 2);
    const symbol_table = try read(u32, object, 8);
    const symbol_count = try read(u32, object, 12);
    const optional_size = try read(u16, object, 16);
    const relative_type: u16 = switch (machine) {
        0x8664 => 3, // IMAGE_REL_AMD64_ADDR32NB
        0xaa64 => 2, // IMAGE_REL_ARM64_ADDR32NB
        0x14c => 7, // IMAGE_REL_I386_DIR32NB
        else => return error.UnsupportedMachine,
    };
    const headers = 20 + @as(usize, optional_size);

    const offsets = try allocator.alloc(?u32, section_count);
    @memset(offsets, null);
    var order: std.ArrayList(u16) = .empty;
    for (0..section_count) |index| {
        const header = headers + index * section_header_size;
        if (header + section_header_size > object.len) return error.Truncated;
        if (std.mem.startsWith(u8, object[header..][0..8], ".rsrc")) try order.append(allocator, @intCast(index));
    }
    if (order.items.len == 0) return error.NoResources;
    const Context = struct {
        object: []const u8,
        headers: usize,
        fn lessThan(context: @This(), a: u16, b: u16) bool {
            const left = context.object[context.headers + @as(usize, a) * section_header_size ..][0..8];
            const right = context.object[context.headers + @as(usize, b) * section_header_size ..][0..8];
            return std.mem.order(u8, left, right) == .lt;
        }
    };
    std.mem.sort(u16, order.items, Context{ .object = object, .headers = headers }, Context.lessThan);

    var size: u32 = 0;
    for (order.items) |index| {
        const header = headers + @as(usize, index) * section_header_size;
        const characteristics = try read(u32, object, header + 36);
        const alignment_bits = (characteristics >> 20) & 0xf;
        const alignment: u32 = if (alignment_bits == 0) 1 else @as(u32, 1) << @intCast(alignment_bits - 1);
        size = std.mem.alignForward(u32, size, alignment);
        offsets[index] = size;
        size += try read(u32, object, header + 16);
    }

    const contents = try allocator.alloc(u8, size);
    @memset(contents, 0);
    for (order.items) |index| {
        const header = headers + @as(usize, index) * section_header_size;
        const raw_size = try read(u32, object, header + 16);
        const raw = try read(u32, object, header + 20);
        const relocations = try read(u32, object, header + 24);
        const relocation_count = try read(u16, object, header + 32);
        const base = offsets[index].?;
        if (raw_size != 0) {
            if (@as(usize, raw) + raw_size > object.len) return error.Truncated;
            @memcpy(contents[base..][0..raw_size], object[raw..][0..raw_size]);
        }
        for (0..relocation_count) |relocation_index| {
            const entry = @as(usize, relocations) + relocation_index * 10;
            const address = try read(u32, object, entry);
            const symbol = try read(u32, object, entry + 4);
            const kind = try read(u16, object, entry + 8);
            if (kind != relative_type) return error.UnsupportedRelocation;
            if (symbol >= symbol_count) return error.InvalidSymbol;
            const record = @as(usize, symbol_table) + @as(usize, symbol) * 18;
            const value = try read(u32, object, record + 8);
            const section_number = try read(i16, object, record + 12);
            if (section_number <= 0 or section_number > section_count) return error.InvalidSymbol;
            const target = offsets[@intCast(section_number - 1)] orelse return error.InvalidSymbol;
            if (@as(usize, address) + 4 > raw_size) return error.Truncated;
            const location = base + address;
            const addend = try read(u32, contents, location);
            write(u32, contents, location, rva + target + value + addend);
        }
    }
    return contents;
}

fn addResources(allocator: std.mem.Allocator, image: []const u8, object: []const u8) ![]u8 {
    const pe = try read(u32, image, 0x3c);
    if (try read(u32, image, pe) != 0x4550) return error.NotPortableExecutable;
    const coff = pe + 4;
    const section_count = try read(u16, image, coff + 2);
    const optional = coff + 20;
    const optional_size = try read(u16, image, coff + 16);
    const plus = switch (try read(u16, image, optional)) {
        0x10b => false,
        0x20b => true,
        else => return error.NotPortableExecutable,
    };
    const section_alignment = try read(u32, image, optional + 32);
    const file_alignment = try read(u32, image, optional + 36);
    const headers_size = try read(u32, image, optional + 60);
    const directories = optional + @as(usize, if (plus) 112 else 96);
    const directory_count = try read(u32, image, directories - 4);
    if (directory_count <= certificate_directory) return error.NoResourceDirectory;
    if (try read(u32, image, directories + resource_directory * 8) != 0) return error.AlreadyHasResources;
    const sections = optional + optional_size;

    var image_end: u32 = 0;
    var file_end: usize = 0;
    var first_raw: usize = headers_size;
    for (0..section_count) |index| {
        const header = sections + index * section_header_size;
        const virtual_size = try read(u32, image, header + 8);
        const virtual_address = try read(u32, image, header + 12);
        const raw_size = try read(u32, image, header + 16);
        const raw = try read(u32, image, header + 20);
        image_end = @max(image_end, virtual_address + @max(virtual_size, raw_size));
        if (raw != 0 and raw_size != 0) {
            file_end = @max(file_end, @as(usize, raw) + raw_size);
            first_raw = @min(first_raw, raw);
        }
    }
    const header = sections + @as(usize, section_count) * section_header_size;
    if (header + section_header_size > first_raw) return error.NoRoomForSectionHeader;
    // A certificate table sits after the sections and signs the old image.
    if (try read(u32, image, directories + certificate_directory * 8) != 0) return error.SignedImage;
    if (file_end > image.len) return error.Truncated;

    const rva = std.mem.alignForward(u32, image_end, section_alignment);
    const contents = try resourceSection(allocator, object, rva);
    const raw = std.mem.alignForward(usize, image.len, file_alignment);
    const raw_size = std.mem.alignForward(u32, @intCast(contents.len), file_alignment);
    const output = try allocator.alloc(u8, raw + raw_size);
    @memset(output, 0);
    @memcpy(output[0..image.len], image);
    @memcpy(output[raw..][0..contents.len], contents);

    @memcpy(output[header..][0..8], ".rsrc\x00\x00\x00");
    write(u32, output, header + 8, @intCast(contents.len));
    write(u32, output, header + 12, rva);
    write(u32, output, header + 16, raw_size);
    write(u32, output, header + 20, @intCast(raw));
    // IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ
    write(u32, output, header + 36, 0x40000040);
    write(u16, output, coff + 2, section_count + 1);
    write(u32, output, optional + 8, try read(u32, output, optional + 8) + raw_size);
    write(u32, output, optional + 56, std.mem.alignForward(u32, rva + @as(u32, @intCast(contents.len)), section_alignment));
    write(u32, output, optional + 64, 0);
    write(u32, output, directories + resource_directory * 8, rva);
    write(u32, output, directories + resource_directory * 8 + 4, @intCast(contents.len));
    return output;
}

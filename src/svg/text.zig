const std = @import("std");
const v = @import("ziggurat_vector");
pub const Lease = v.drawing.Lease;
pub const mapping = @import("text_mapping.zig");
pub const Mapping = mapping.Mapping;

pub const Direction = enum { ltr, rtl };
pub const Anchor = enum { start, middle, end };
pub const GenericFamily = enum { named, sans_serif, serif, monospace };
pub const Font = struct {
    family: []const u8 = "",
    generic: GenericFamily = .sans_serif,
    size: f64 = 16,
    weight: u32 = 400,
    italic: bool = false,
    direction: Direction = .ltr,
    locale: []const u8 = "",
};
pub const Limits = struct {
    instances: usize = 64,
    source_bytes: usize = 65536,
    glyphs: usize = 8192,
    commands: usize = 65536,
    characters: usize = 8192,
    position_values: usize = 16384,
    chunks: usize = 256,
    /// Cumulative mixed-fill partitions per preparation geometry use,
    /// including bbox probes; not unique owning Paths or final draw calls.
    paint_runs: usize = 256,
    work: u64 = 4 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.instances == 0 or self.instances > 256 or self.source_bytes == 0 or self.source_bytes > 1024 * 1024 or self.glyphs == 0 or self.glyphs > 65536 or self.commands == 0 or self.commands > 1024 * 1024 or self.work == 0 or self.work > 128 * 1024 * 1024) return error.InvalidTextLimits;
        if (self.characters == 0 or self.characters > 65536 or self.position_values == 0 or self.position_values > 262144 or self.chunks == 0 or self.chunks > 8192) return error.InvalidTextLimits;
        if (self.paint_runs == 0 or self.paint_runs > 8192) return error.InvalidTextLimits;
    }
};
pub const Request = struct {
    utf8: []const u8,
    font: Font,
    max_glyphs: usize,
    max_commands: usize,
    max_bytes: usize,
    cancellation: ?*const v.Cancellation,
    include_mapping: bool = false,
    max_work: u64 = 4 * 1024 * 1024,
};
pub const Result = struct {
    /// Ownership transfers only on success. Must use the supplied allocator,
    /// current owner, finite geometry, and the request's remaining limits.
    path: *v.Path,
    first_baseline: f64,
    advance: f64,
    glyphs: usize,
    /// Optional full cells, one per glyph, allocated with path.allocator.
    /// Transfers with path. The caller frees this slice before closing path.
    cells: ?[]v.Bounds = null,
    /// Independent owning geometry/metadata, only for an explicit request.
    mapping: ?*Mapping = null,
    /// Explicit preparation work consumed in addition to cache transforms.
    work: u64 = 0,
};
/// Called only during explicit preparation, never during command playback.
/// Requests are borrowed for this call. Only transferred Path/cells/Mapping
/// storage may retain the supplied allocator, until preparation releases it.
/// Without a lease, the caller keeps context alive through the complete prepare.
pub const Provider = struct {
    context: *anyopaque,
    shape: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!Result,
    /// Optional stable owner pin held throughout prepare, including candidate
    /// allocation and final cache disposal outside individual shape calls.
    lease: ?*Lease = null,
    supports_mapping: bool = false,
};
pub fn sameFont(a: Font, b: Font) bool {
    return a.generic == b.generic and a.size == b.size and a.weight == b.weight and a.italic == b.italic and a.direction == b.direction and std.mem.eql(u8, a.family, b.family) and std.mem.eql(u8, a.locale, b.locale);
}
pub fn parseFamily(font: *Font, input: []const u8) !void {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0 or value.len > 257 or std.mem.indexOfAny(u8, value, ",\\") != null) return error.UnsupportedFontFamily;
    if (value[0] == '\'' or value[0] == '"') {
        if (value.len < 3 or value[value.len - 1] != value[0]) return error.UnsupportedFontFamily;
        font.family = value[1 .. value.len - 1];
        font.generic = .named;
    } else if (std.ascii.eqlIgnoreCase(value, "sans-serif")) {
        font.family = "";
        font.generic = .sans_serif;
    } else if (std.ascii.eqlIgnoreCase(value, "serif")) {
        font.family = "";
        font.generic = .serif;
    } else if (std.ascii.eqlIgnoreCase(value, "monospace")) {
        font.family = "";
        font.generic = .monospace;
    } else {
        if (std.mem.indexOfAny(u8, value, "\"'") != null) return error.UnsupportedFontFamily;
        font.family = value;
        font.generic = .named;
    }
    if (font.family.len > 255) return error.UnsupportedFontFamily;
}

const std = @import("std");
const zio = @import("ziggurat_io");
const http = @import("ziggurat_http_response");
const files = @import("ziggurat_file_stream");
const policy = @import("policy.zig");
const routes = @import("site_routes.zig");
const types = @import("types.zig");
const enabled = (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .windows) and @import("ziggurat_https_resources_options").enabled;

pub const etag_capacity = http.byte_range.value_capacity;
pub const mime_capacity = 127;
pub const Representation = struct {
    /// Host assertion about immutable representation bytes, not an inferred
    /// filename/size/time validator. Only strong, HTTP-safe tags are accepted.
    etag: []const u8,
    mime: []const u8 = "application/octet-stream",
};

/// Owning bounded numeric/metadata capture, without allocator or native work.
/// Call only after authorization and the host's other HTTP preconditions
/// (304/412 etc). This value grants no request, path, file or transport access.
pub const FileRequest = struct {
    method: http.Method,
    parsed: ?http.byte_range.Parsed = null,
    condition_matches: bool = true,
    etag_storage: [etag_capacity]u8 = undefined,
    etag_length: u16 = 0,
    mime_storage: [mime_capacity]u8 = undefined,
    mime_length: u8 = 0,

    pub fn capture(method: http.Method, observed: []const http.Header, representation: Representation) !FileRequest {
        if (method != .get and method != .head) return error.MethodDenied;
        if (observed.len > policy.header_capacity) return error.RequestHeadersExceeded;
        if (representation.etag.len == 0 or representation.etag.len > etag_capacity) return error.InvalidFileEntityTag;
        if (representation.mime.len == 0 or representation.mime.len > mime_capacity) return error.InvalidMime;
        var out: FileRequest = .{ .method = method, .etag_length = @intCast(representation.etag.len), .mime_length = @intCast(representation.mime.len) };
        // Own metadata before validating or deriving anything from its bytes.
        @memcpy(out.etag_storage[0..representation.etag.len], representation.etag);
        @memcpy(out.mime_storage[0..representation.mime.len], representation.mime);
        try out.validate();
        var bytes: usize = 0;
        var range: ?[]const u8 = null;
        var condition: ?[]const u8 = null;
        var conditions: usize = 0;
        for (observed) |header| {
            if (!http.validName(header.name) or !http.validValue(header.value)) return error.InvalidRequestHeader;
            bytes += header.name.len + header.value.len;
            if (bytes > policy.header_bytes) return error.RequestHeadersExceeded;
            if (method == .head) continue; // Generic budgets, no range semantics.
            if (std.ascii.eqlIgnoreCase(header.name, "Range")) {
                if (range != null) return error.DuplicateRangeHeader;
                range = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "If-Range")) {
                condition = header.value;
                conditions += 1;
            }
        }
        if (range) |value| {
            if (conditions > 1) return error.DuplicateIfRangeHeader;
            out.parsed = try http.byte_range.parse(value);
            if (condition) |value_condition| out.condition_matches = http.byte_range.ifRangeMatches(value_condition, out.etag_storage[0..out.etag_length]);
        }
        return out;
    }
    pub fn validate(self: *const FileRequest) !void {
        if (self.method != .get and self.method != .head) return error.MethodDenied;
        if (self.etag_length == 0 or self.etag_length > etag_capacity) return error.InvalidFileEntityTag;
        if (self.mime_length == 0 or self.mime_length > mime_capacity) return error.InvalidMime;
        const tag = self.etag_storage[0..self.etag_length];
        if (!http.validValue(tag) or !http.byte_range.ifRangeMatches(tag, tag)) return error.InvalidFileEntityTag;
        if (!http.validValue(self.mime_storage[0..self.mime_length])) return error.InvalidMime;
        // Public values can be hand-constructed. HEAD or a mismatching validator
        // must not hide an invalid numeric Spec before worker/native access.
        _ = try http.byte_range.evaluate(.get, self.parsed, 1, null, null);
    }
    pub fn etag(self: *const FileRequest) ![]const u8 {
        try self.validate();
        return self.etag_storage[0..self.etag_length];
    }
    pub fn mime(self: *const FileRequest) ![]const u8 {
        try self.validate();
        return self.mime_storage[0..self.mime_length];
    }
    pub fn select(self: *const FileRequest, total: u64) !http.byte_range.Selection {
        try self.validate();
        if (!self.condition_matches) return .full;
        return http.byte_range.evaluate(if (self.method == .head) .head else .get, self.parsed, total, null, null);
    }
};

/// Two independent linear owners. Move response to the owner thread only
/// through a successful App.post; the host retains and runs/deinits pump on its
/// explicit worker. A 416 has no source or pump. No thread or App is retained.
pub const Prepared = struct { response: PreparedFileResponse, pump: ?files.Pump };

/// Created only by prepare. Do not modify or copy any field afterwards; only
/// submit/deinit this response. Do not manufacture native owning fields.
/// Metadata is inline. Its source and the separate Pump use the existing file
/// physical/control ledger. Deinit never joins or waits for the worker.
pub const PreparedFileResponse = struct {
    request: FileRequest,
    selection: http.byte_range.Selection,
    total: u64,
    source: ?files.PreparedSource = null,
    ready: bool = true,

    /// Worker-only. File must already be authorized, private and immutable
    /// before entry and remain so until pump finishes. Does not open a path,
    /// infer an ETag, process other preconditions, or read representation bytes.
    pub fn prepare(main_thread: std.Thread.Id, file: std.Io.File, maximum: u64, request: FileRequest) !Prepared {
        if (!enabled) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() == main_thread) return error.UiThreadForbidden;
        if (maximum == 0 or maximum > files.hard_max_bytes) return error.InvalidFileStreamLimit;
        try request.validate();
        const stat = try file.stat(zio.io());
        if (stat.kind != .file) return error.RegularFileRequired;
        if (stat.size > maximum) return error.FileTooLarge;
        const selection = try request.select(stat.size);
        const response: PreparedFileResponse = .{ .request = request, .selection = selection, .total = stat.size };
        if (selection == .unsatisfiable) return .{ .response = response, .pump = null };
        var physical = if (selection == .partial)
            try files.PreparedSource.prepareWindow(main_thread, file, .{ .offset = selection.partial.offset, .length = selection.partial.length }, maximum)
        else
            try files.PreparedSource.prepare(main_thread, file, maximum);
        errdefer {
            physical.source.deinit();
            physical.pump.deinit();
        }
        const expected = if (selection == .partial) selection.partial.length else stat.size;
        if (try physical.source.authoritativeLength() != expected) return error.FileSourceChanged;
        var out = response;
        out.source = physical.source;
        return .{ .response = out, .pump = physical.pump };
    }
    pub fn deinit(self: *PreparedFileResponse) void {
        var source = self.source;
        self.source = null;
        self.ready = false;
        if (source) |*value| value.deinit();
    }
    /// Pure shape validation before native candidate work. Source identity and
    /// authoritative length are checked again by Endpoint's existing commit.
    pub fn validate(self: *const PreparedFileResponse) !void {
        if (!self.ready) return error.ResponseMoved;
        const selected = try self.request.select(self.total);
        if (self.total > files.hard_max_bytes) return error.FileTooLarge;
        if (!std.meta.eql(self.selection, selected)) return error.InvalidSelection;
        if (self.source) |source| if (source.native == null) return error.ResponseMoved;
        switch (self.selection) {
            .full => if (self.source == null) return error.ResponseMoved,
            .partial => |span| {
                if (self.source == null) return error.ResponseMoved;
                if (span.total != self.total) return error.InvalidSelection;
                var buffer: [http.byte_range.maximum_content_range_length]u8 = undefined;
                _ = try http.byte_range.formatContentRange(self.selection, &buffer);
            },
            .unsatisfiable => |total| {
                if (self.source != null or total == 0 or total != self.total) return error.InvalidSelection;
            },
        }
    }
};

/// Explicit opt-in stack capture at a stable address. Header rows and formatted
/// range stay here; MIME/ETag bytes borrow the response until commit returns.
pub const Metadata = struct {
    head: types.Head = undefined,
    headers: [16]http.Header = undefined,
    content_range: [http.byte_range.maximum_content_range_length]u8 = undefined,
    pub fn init(self: *Metadata, response: *const PreparedFileResponse) !void {
        try response.validate();
        var extra: [2]http.Header = undefined;
        // validate above checked these owned lengths/bytes. No foreign entry
        // intervenes, so do not repeat the full request/Spec validation twice.
        extra[0] = .{ .name = "ETag", .value = response.request.etag_storage[0..response.request.etag_length] };
        const count: usize = if (response.selection == .full) 1 else 2;
        if (count == 2) extra[1] = .{ .name = "Content-Range", .value = try http.byte_range.formatContentRange(response.selection, &self.content_range) };
        self.head = .{
            .status = switch (response.selection) {
                .full => 200,
                .partial => 206,
                .unsatisfiable => 416,
            },
            .mime = response.request.mime_storage[0..response.request.mime_length],
            .length = switch (response.selection) {
                .full => response.total,
                .partial => |span| span.length,
                .unsatisfiable => 0,
            },
            .headers = try routes.mergePolicyHeaders(extra[0..count], &self.headers),
        };
    }
};

test {
    _ = @import("file_response_test.zig");
}

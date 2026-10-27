const std = @import("std");
pub const capacity = 8;
pub const Policy = struct {
    cookies: bool = false,
    clear_entire_profile: bool = false,
    find: bool = false,
    capture: bool = false,
    pdf: bool = false,
};
pub const Limits = struct {
    max_pending: u8 = capacity,
    max_cookies: u16 = 128,
    max_cookie_bytes: u32 = 64 * 1024,
    max_capture_bytes: u32 = 4 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.max_pending == 0 or self.max_pending > capacity or self.max_cookies == 0 or self.max_cookies > 128 or self.max_cookie_bytes == 0 or self.max_cookie_bytes > 256 * 1024 or self.max_capture_bytes == 0 or self.max_capture_bytes > 16 * 1024 * 1024) return error.InvalidToolLimits;
    }
};
pub const SameSite = enum(u32) { none = 0, lax = 1, strict = 2 };
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    expires: f64,
    secure: bool,
    http_only: bool,
    session: bool,
    same_site: SameSite,
};
pub const CookieWrite = struct {
    name: []const u8,
    value: []const u8,
    path: []const u8 = "/",
    expires: ?f64 = null,
    secure: bool = true,
    http_only: bool = false,
    same_site: SameSite = .lax,
    /// Cookies have no port isolation. Native domain/path matching can affect
    /// other pages; this API does not promise host-only cookie semantics.
    accept_cookie_scope: bool,
};
pub const CookieDelete = struct {
    name: []const u8,
    path: []const u8 = "/",
    /// Deletes the exact native domain/path pair derived from the authorized
    /// URI host and this path. Cookies still have no port isolation.
    accept_cookie_scope: bool,
};
pub const ClearScope = enum { entire_profile };
/// A sheet of paper in inches, in portrait orientation.
pub const PageSize = struct {
    width: f64,
    height: f64,
    pub const letter: PageSize = .{ .width = 8.5, .height = 11 };
    pub const legal: PageSize = .{ .width = 8.5, .height = 14 };
    pub const tabloid: PageSize = .{ .width = 11, .height = 17 };
    pub const a3: PageSize = .{ .width = 11.69, .height = 16.54 };
    pub const a4: PageSize = .{ .width = 8.27, .height = 11.69 };
    pub const a5: PageSize = .{ .width = 5.83, .height = 8.27 };
};
/// Page margins in inches.
pub const Margins = struct {
    top: f64 = 0.4,
    right: f64 = 0.4,
    bottom: f64 = 0.4,
    left: f64 = 0.4,
    pub const none: Margins = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 };
};
/// The defaults print Letter pages in portrait with margins of 0.4 inch and
/// without backgrounds, like a browser's print dialog; the page's print style
/// sheets apply.
pub const PdfOptions = struct {
    /// Host prepares a private absolute path on its explicit worker. Native PDF
    /// generation may write after logical cancellation and is not byte-budgeted.
    path: []const u8,
    accept_overwrite: bool,
    page_size: PageSize = .letter,
    margins: Margins = .{},
    first_page: u16 = 1,
    /// Null prints through the last page; a range spans at most 256 pages.
    last_page: ?u16 = null,
    landscape: bool = false,
    /// Background colors and images, which printing leaves out by default.
    print_backgrounds: bool = false,
    pub fn validate(self: PdfOptions) !void {
        const size = self.page_size;
        if (!(size.width >= 1 and size.width <= 100 and size.height >= 1 and size.height <= 100)) return error.InvalidPageSize;
        const m = self.margins;
        for ([_]f64{ m.top, m.right, m.bottom, m.left }) |value| if (!(value >= 0 and value <= 10)) return error.InvalidMargins;
        if (m.left + m.right >= size.width or m.top + m.bottom >= size.height) return error.InvalidMargins;
        if (self.first_page == 0) return error.InvalidPageRange;
        if (self.last_page) |last| if (last < self.first_page or @as(u32, last) - self.first_page + 1 > 256) return error.InvalidPageRange;
    }
};
pub const FindState = struct {
    /// null when the native result does not contain a full-document total.
    matches: ?i32 = null,
    /// null is unknown; -1 is a known absence, >=1 a known native index.
    active_index: ?i32 = null,
};
pub const FindCapabilities = struct {
    whole_word: bool = false,
    highlight_control: bool = false,
    total_count_on_step: bool = false,
    active_index: bool = false,
};
pub const FindListener = struct {
    /// Borrowed until stop, replacement, navigation, reload or detach.
    context: *anyopaque,
    changed: *const fn (*anyopaque, FindState) void,
};
pub const FindOptions = struct {
    term: []const u8,
    case_sensitive: bool = false,
    whole_word: bool = false,
    highlight_all: bool = true,
    listener: ?FindListener = null,
};
pub const RequestOptions = struct { timeout_ms: ?u32 = null };
pub const Result = union(enum) {
    /// All strings, rows and byte slices borrow storage until callback return.
    cookies: []const Cookie,
    find: FindState,
    png: []const u8,
    pdf_path: []const u8,
    cleared,
    native_failure: i32,
    cancelled,
    timed_out,
    page_changed,
    detached,
    unavailable,
    timer_failed,
    limit_exceeded,
    invalid_result,
    out_of_memory,
};
pub const Completion = struct { context: *anyopaque, complete: *const fn (*anyopaque, Result) void };
pub const Scope = enum { page, profile };
pub const Kind = enum(u32) { cookies = 0, clear = 1, find = 2, capture = 3, pdf = 4 };
pub const Slot = struct {
    token: u64,
    kind: Kind,
    scope: Scope,
    page: u64,
    deadline: ?u64,
    completion: Completion,
    /// Optional owning request metadata; the View frees it after terminal callback.
    owned: ?[]u8 = null,
};
pub const Book = struct {
    slots: [capacity]?Slot = @splat(null),
    next_token: u64 = 1,
    pub fn reserve(self: *Book, value: Slot, limit: u8) !u64 {
        if (limit == 0 or limit > capacity) return error.InvalidToolLimits;
        if (self.next_token == std.math.maxInt(u64)) return error.ToolTokenExhausted;
        for (self.slots[0..limit]) |*slot| if (slot.* == null) {
            var next = value;
            next.token = self.next_token;
            self.next_token += 1;
            slot.* = next;
            return next.token;
        };
        return error.Full;
    }
    pub fn take(self: *Book, token: u64) ?Slot {
        for (&self.slots) |*slot| if (slot.*) |value| {
            if (value.token == token) {
                slot.* = null;
                return value;
            }
        };
        return null;
    }
    pub fn earliest(self: *const Book) ?u64 {
        var at: ?u64 = null;
        for (self.slots) |slot| if (slot) |value| if (value.deadline) |deadline| {
            if (at == null or deadline < at.?) at = deadline;
        };
        return at;
    }
    pub fn tokens(self: *const Book, output: *[capacity]u64, scope: ?Scope, expired_at: ?u64) []const u64 {
        var count: usize = 0;
        for (self.slots) |slot| if (slot) |value| {
            if (scope) |selected| if (value.scope != selected) {
                continue;
            };
            if (expired_at) |now| if (value.deadline == null or value.deadline.? > now) {
                continue;
            };
            output[count] = value.token;
            count += 1;
        };
        return output[0..count];
    }
};
test "tool slots separate profile effects from page cancellation and keep monotonic identity" {
    var marker: u8 = 0;
    const completion: Completion = .{ .context = &marker, .complete = struct {
        fn complete(_: *anyopaque, _: Result) void {}
    }.complete };
    var book: Book = .{};
    const page = try book.reserve(.{ .token = 0, .kind = .capture, .scope = .page, .page = 1, .deadline = 10, .completion = completion }, 2);
    const profile = try book.reserve(.{ .token = 0, .kind = .clear, .scope = .profile, .page = 1, .deadline = 20, .completion = completion }, 2);
    var storage: [capacity]u64 = undefined;
    try std.testing.expectEqualSlices(u64, &.{page}, book.tokens(&storage, .page, null));
    try std.testing.expectEqualSlices(u64, &.{profile}, book.tokens(&storage, .profile, null));
    try std.testing.expectEqualSlices(u64, &.{page}, book.tokens(&storage, null, 10));
    try std.testing.expect(book.take(page) != null and book.take(page) == null);
    const replacement = try book.reserve(.{ .token = 0, .kind = .pdf, .scope = .page, .page = 2, .deadline = null, .completion = completion }, 2);
    try std.testing.expect(replacement != page);
    try std.testing.expectError(error.Full, book.reserve(.{ .token = 0, .kind = .cookies, .scope = .profile, .page = 2, .deadline = null, .completion = completion }, 2));
    try std.testing.expectEqual(20, book.earliest().?);
}

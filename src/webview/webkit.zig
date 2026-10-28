const std = @import("std");
pub const Failure = @import("backend.zig").GlibFailure;
pub const PageEvent = extern struct { kind: c_int, navigation_id: u64, flags: u32, status: i32, value: ?[*:0]const u16 };
pub const ResourceHeader = extern struct { name: [*:0]const u8, value: [*:0]const u8 };
pub const ResponseHeader = extern struct { name: [*]const u8, name_len: u32, value: [*]const u8, value_len: u32 };
pub const ResourceNotify = *const fn (*anyopaque, [*:0]const u8, [*:0]const u8, [*]const ResourceHeader, u32, *anyopaque) callconv(.c) void;
pub const Options = extern struct {
    html: [*:0]const u8,
    user_agent: ?[*:0]const u8,
    zoom: f64,
    max_pending: u32,
    max_result_bytes: u32,
    policy_flags: u32,
    local: ?*const Local = null,
    remote: ?*const @import("webkit_remote.zig").Input = null,
    region: u32 = 0,
    profile_context: ?*anyopaque = null,
    initializers: ?*const @import("initializer_owner.zig").NativeInput = null,
    developer_tools: u32 = 0,
    facts: ?[*:0]const u8 = null,
    autoplay: u32 = 0,
    auth: ?*const fn (*anyopaque, [*:0]const u8, u32, [*:0]const u8, u32, c_int, *anyopaque) callconv(.c) void = null,
    certificate: ?*const fn (*anyopaque, [*:0]const u8, u32, [*]const u8, usize) callconv(.c) c_int = null,
    context_menu: u32 = 0,
    context_offer: ?*const fn (*anyopaque, *const ContextTarget, [*]const ContextItem, u32, [*]u8, *anyopaque) callconv(.c) c_int = null,
};
pub const ContextItem = extern struct { name: [*:0]const u8, label: [*:0]const u8, kind: u32, flags: u32, action: u32 };
pub const ContextTarget = extern struct { link: ?[*:0]const u8, link_text: ?[*:0]const u8, image: ?[*:0]const u8, media: ?[*:0]const u8, selection: ?[*:0]const u8, frame: ?[*:0]const u8, editable: u32 };
pub const LocalResource = extern struct {
    path: [*]const u8,
    mime: [*]const u8,
    path_length: usize,
    mime_length: usize,
    bytes: [*]const u8,
    length: usize,
};
pub const LocalHeaderGrant = extern struct { name: [*:0]const u8, value: ?[*:0]const u8 };
pub const LocalPolicy = extern struct {
    methods: u32,
    header_count: u32,
    origin_count: u32,
    reserved: u32 = 0,
    headers: ?[*]const LocalHeaderGrant,
    origins: ?[*]const [*:0]const u8,
};
pub const local_policy_bytes_limit = 32 * 1024;
/// Length-only preflight, before inspecting caller bytes or allocating. These
/// bytes include the native owning rows, NULs and resource-table alignment.
pub fn localPolicyBytes(site: anytype, registration: anytype) !usize {
    if (site.request_headers.len > 16) return error.TooManyHeaderGrants;
    if (registration.request_origins.len > 8) return error.TooManySchemeOrigins;
    if (@as(u8, @bitCast(site.methods)) == 3 and site.request_headers.len == 0 and registration.request_origins.len == 0) return 0;
    var size = @sizeOf(LocalPolicy) + site.request_headers.len * @sizeOf(LocalHeaderGrant) + registration.request_origins.len * @sizeOf([*:0]const u8);
    var grant_bytes: usize = 0;
    for (site.request_headers) |header| {
        if (header.name.len == 0 or header.name.len > 64) return error.InvalidHeaderGrant;
        if (header.exact_value) |value| if (value.len > 2048) return error.InvalidHeaderGrant;
        const length = header.name.len + if (header.exact_value) |value| value.len else @as(usize, 0);
        grant_bytes = try std.math.add(usize, grant_bytes, length);
        if (grant_bytes > 8192) return error.HeaderBudgetExceeded;
        size = try std.math.add(usize, size, length + 1 + @as(usize, @intFromBool(header.exact_value != null)));
    }
    for (registration.request_origins) |origin| {
        if (origin.len == 0 or origin.len > 1024) return error.InvalidSchemeOrigin;
        size = try std.math.add(usize, size, origin.len + 1);
    }
    size = std.mem.alignBackward(usize, try std.math.add(usize, size, @alignOf(LocalResource) - 1), @alignOf(LocalResource));
    if (size > local_policy_bytes_limit) return error.LocalPolicyTooLarge;
    return size;
}
pub const Local = extern struct {
    scheme: [*:0]const u8,
    host: [*:0]const u8,
    start_path: [*:0]const u8,
    resources: [*]const LocalResource,
    count: u32,
    max_response_bytes: u32,
    budget: *anyopaque,
    secure: c_int,
    ipc: c_int,
    policy: ?*const LocalPolicy = null,
};
pub const LocalScratch = struct {
    storage: []align(@alignOf(LocalResource)) u8,
    local: Local,
    pub fn init(allocator: std.mem.Allocator, site: anytype, max_bytes: u32, budget: *anyopaque, registration: anytype) !LocalScratch {
        const policy_bytes = try localPolicyBytes(site, registration);
        const prefix = if (policy_bytes != 0) @sizeOf(LocalPolicy) + site.request_headers.len * @sizeOf(LocalHeaderGrant) + registration.request_origins.len * @sizeOf([*:0]const u8) else 0;
        var size = try std.math.add(usize, prefix, try std.math.mul(usize, site.resources.len, @sizeOf(LocalResource)));
        size = try std.math.add(usize, size, site.scheme.len + site.host.len + site.start_path.len + 3);
        if (policy_bytes != 0) size = try std.math.add(usize, size, policy_bytes - prefix);
        const storage = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(LocalResource)), size);
        errdefer allocator.free(storage);
        const rows = @as([*]LocalResource, @ptrCast(@alignCast(storage.ptr + prefix)))[0..site.resources.len];
        var offset = prefix + rows.len * @sizeOf(LocalResource);
        var texts: [3][*:0]const u8 = undefined;
        inline for (.{ site.scheme, site.host, site.start_path }, 0..) |text, i| {
            const out = storage[offset..][0..text.len];
            @memcpy(out, text);
            storage[offset + text.len] = 0;
            texts[i] = @ptrCast(out.ptr);
            offset += text.len + 1;
        }
        for (rows, site.resources) |*out, source| out.* = .{ .path = source.path.ptr, .path_length = source.path.len, .mime = source.mime.ptr, .mime_length = source.mime.len, .bytes = source.bytes.ptr, .length = source.bytes.len };
        const policy: ?*LocalPolicy = if (policy_bytes != 0) blk: {
            const owned: *LocalPolicy = @ptrCast(storage.ptr);
            const headers = @as([*]LocalHeaderGrant, @ptrCast(@alignCast(storage.ptr + @sizeOf(LocalPolicy))))[0..site.request_headers.len];
            const origins = @as([*][*:0]const u8, @ptrCast(@alignCast(storage.ptr + @sizeOf(LocalPolicy) + headers.len * @sizeOf(LocalHeaderGrant))))[0..registration.request_origins.len];
            for (headers, site.request_headers) |*out, input| out.* = .{ .name = terminated(storage, &offset, input.name), .value = if (input.exact_value) |value| terminated(storage, &offset, value) else null };
            for (origins, registration.request_origins) |*out, input| out.* = terminated(storage, &offset, input);
            owned.* = .{ .methods = @as(u8, @bitCast(site.methods)), .header_count = @intCast(headers.len), .origin_count = @intCast(origins.len), .headers = if (headers.len != 0) headers.ptr else null, .origins = if (origins.len != 0) origins.ptr else null };
            break :blk owned;
        } else null;
        return .{ .storage = storage, .local = .{ .scheme = texts[0], .host = texts[1], .start_path = texts[2], .resources = rows.ptr, .count = @intCast(rows.len), .max_response_bytes = max_bytes, .budget = budget, .secure = @intFromBool(registration.treat_as_secure), .ipc = @intFromBool(site.scheme_ipc), .policy = policy } };
    }
    fn terminated(storage: []u8, offset: *usize, text: []const u8) [*:0]const u8 {
        const output = storage[offset.*..][0..text.len];
        @memcpy(output, text);
        storage[offset.* + text.len] = 0;
        offset.* += text.len + 1;
        return @ptrCast(output.ptr);
    }
    pub fn deinit(self: *LocalScratch, allocator: std.mem.Allocator) void {
        const storage = self.storage;
        self.* = undefined;
        allocator.free(storage);
    }
};
pub const Notify = *const fn (*anyopaque, c_int, ?[*:0]const u16, i32, ?*const Failure) callconv(.c) void;
pub const PageNotify = *const fn (*anyopaque, *const PageEvent) callconv(.c) c_int;
pub const ScriptNotify = *const fn (*anyopaque, u64, c_int, i32, ?[*:0]const u16, ?*const Failure) callconv(.c) void;
pub const InitializerNotify = *const fn (*anyopaque, u64, u32, i32) callconv(.c) void;
pub extern fn zwk_initializer_counts(*u32, *u32, *u32, *u64) void;
pub extern fn zwk_initializers_prepare(*anyopaque, *const @import("initializer_owner.zig").NativeInput, u64, ?InitializerNotify) c_int;
pub extern fn zwk_initializers_activate(*anyopaque) void;
pub extern fn zwk_initializers_abandon(*anyopaque) void;
pub extern fn zwk_initializers_cancel(*anyopaque, u64) void;
pub extern fn zwk_initializers_try_cancel(*anyopaque, u64) bool;
pub extern fn zwk_initializers_blocked(*anyopaque) bool;
pub const CaptureNotify = *const fn (*anyopaque, u64, c_int, [*]const u8, usize, ?*const Failure) callconv(.c) void;
pub const FindSnapshot = extern struct { known: u32, matches: i32, active_index: i32 };
pub const FindNotify = *const fn (*anyopaque, u64, c_int, c_int, *const FindSnapshot) callconv(.c) void;
pub extern fn zwk_find_budget_new(u32) ?*anyopaque;
pub extern fn zwk_find_budget_limit(*anyopaque, u32) c_int;
pub extern fn zwk_find_budget_close(*anyopaque) void;
pub extern fn zwk_find_budget_release(*anyopaque) void;
pub extern fn zwk_find_prepare(*anyopaque, *anyopaque, FindNotify, [*]const u8, usize, u32, *?*anyopaque) c_int;
/// Always consumes the candidate, including a rejected commit.
pub extern fn zwk_find_commit(*anyopaque, u64) c_int;
pub extern fn zwk_find_abort(*anyopaque) void;
pub extern fn zwk_find_action(*anyopaque, c_int, *FindSnapshot) c_int;
pub extern fn zwk_find_cancel(*anyopaque, u64) void;
pub extern fn zwk_find_counts(*u32, *u32, *u32, *usize, *usize) void;
pub extern fn zwk_capture_budget_new(u32, u32, CaptureNotify) ?*anyopaque;
pub extern fn zwk_capture_budget_limit(*anyopaque, u32, u32) c_int;
pub extern fn zwk_capture_budget_close(*anyopaque) void;
pub extern fn zwk_capture_budget_release(*anyopaque) void;
pub extern fn zwk_capture_enable(*anyopaque, *anyopaque) c_int;
pub extern fn zwk_capture_start(*anyopaque, u64) c_int;
/// Page geometry in inches: width, height, then top, right, bottom and left
/// margins. A zero last page prints through the end.
pub const PdfRequest = extern struct { first_page: u32, last_page: u32, flags: u32, page: [6]f64 };
pub extern fn zwk_pdf_start(*anyopaque, u64, [*:0]const u8, *const PdfRequest) c_int;
pub extern fn zwk_clear_start(*anyopaque, u64) c_int;
pub extern fn zwk_capture_cancel(*anyopaque, u64) void;
pub extern fn zwk_capture_counts(*u32, *u32, *usize, *usize) void;
pub extern fn zwk_create(*anyopaque, *const Options, Notify, PageNotify, ScriptNotify, *const fn (*anyopaque) callconv(.c) void, *anyopaque, *?*anyopaque) c_int;
pub extern fn zwk_session_create(*const Options, u32, u32, Notify, PageNotify, ScriptNotify, *const fn (*anyopaque) callconv(.c) void, *anyopaque, *?*anyopaque) c_int;
pub extern fn zwk_session_mount(*anyopaque, *anyopaque, i32, i32, i32, i32, c_int, u64) c_int;
pub extern fn zwk_session_park(*anyopaque, u64) c_int;
pub extern fn zwk_session_size(*anyopaque, *u32, *u32) c_int;
pub extern fn zwk_session_parent_destroying(*anyopaque, u64) void;
pub extern fn zwk_close(*anyopaque) void;
pub extern fn zwk_resources_enable(*anyopaque, ResourceNotify, c_int, u32) c_int;
pub extern fn zwk_resource_respond(*anyopaque, u32, [*]const u8, usize, [*]const u8, usize, [*]const ResponseHeader, u32) c_int;
pub extern fn zwk_resource_defer(*anyopaque, u64) c_int;
pub extern fn zwk_resource_respond_deferred(*anyopaque, u64, u32, [*]const u8, usize, [*]const u8, usize, [*]const ResponseHeader, u32) c_int;
pub extern fn zwk_resource_cancel(*anyopaque, u64) void;
pub extern fn zwk_resource_cancel_all(*anyopaque) void;
pub extern fn zwk_resources_pending() u32;
pub extern fn zwk_resource_respond_file(*anyopaque, *anyopaque, u64, *anyopaque, u32, [*]const u8, usize, [*]const ResponseHeader, u32, c_int, *?*anyopaque) c_int;
pub extern fn zwk_resource_respond_file_deferred(*anyopaque, u64, *anyopaque, u64, *anyopaque, u32, [*]const u8, usize, [*]const ResponseHeader, u32, c_int, *?*anyopaque) c_int;
pub extern fn zwk_file_budget_create(u32) ?*anyopaque;
pub extern fn zwk_file_budget_limit(*anyopaque, u32) void;
pub extern fn zwk_file_budget_release(*anyopaque) void;
pub extern fn zwk_file_counts(*u32, *u32, *u32, *u32) void;
pub extern fn zwk_evaluate(*anyopaque, [*:0]const u8, u64) c_int;
pub extern fn zwk_evaluate_cancel(*anyopaque, u64) void;
pub extern fn zwk_post(*anyopaque, [*:0]const u8) c_int;
pub extern fn zwk_zoom(*anyopaque, *f64, c_int) c_int;
pub extern fn zwk_user_agent(*anyopaque, ?[*:0]const u8, ?*?[*:0]u8) c_int;
pub extern fn zwk_devtools(*anyopaque, c_int, ?*c_int, ?*c_int) c_int;
pub extern fn zwk_devtools_counts(*u32) void;
pub extern fn zwk_string_free([*:0]u8) void;
pub extern fn zwk_deadline_arm(*anyopaque, u64) c_int;
pub extern fn zwk_deadline_cancel(*anyopaque) void;
pub extern fn zwk_refresh(*anyopaque) c_int;
pub extern fn zwk_navigate_remote(*anyopaque, [*:0]const u8) c_int;
pub extern fn zwk_navigate_local(*anyopaque, [*:0]const u8) c_int;
pub extern fn zwk_history(*anyopaque, c_int) c_int;
pub extern fn zwk_stop(*anyopaque) c_int;
pub extern fn zwk_focus(*anyopaque) c_int;
pub extern fn zwk_viewport(*anyopaque, i32, i32, i32, i32, c_int) c_int;
pub extern fn zwk_last_failure(*anyopaque, *Failure) void;
pub extern fn zwk_counts(*u32, *u32, *u32) void;
pub extern fn zwk_local_budget_new(u32, u32) ?*anyopaque;
pub extern fn zwk_local_budget_limit(*anyopaque, u32, u32) void;
pub extern fn zwk_local_budget_release(*anyopaque) void;
pub extern fn zwk_local_counts(*u32, *u32, *u32) void;
pub extern fn zwk_recovery_begin(*anyopaque) c_int;
pub extern fn zwk_recovery_cancel(*anyopaque) void;
pub extern fn zwk_recovery_dispatch(*anyopaque) void;
pub extern fn zwk_recovery_anchor(Notify, *anyopaque) ?*anyopaque;

pub fn check(result: c_int) !void {
    return switch (result) {
        0 => {},
        1 => error.Closed,
        2 => error.Full,
        3 => error.OutOfMemory,
        4 => error.InvalidNativeArgument,
        6 => error.NotReady,
        7 => error.NavigationPending,
        8 => error.IpcOriginDenied,
        9 => error.NoHistory,
        10 => error.NavigationCancelled,
        11 => error.NativeGeometryNotApplied,
        12 => error.InitializerBudgetExceeded,
        13 => error.DevToolsDisabled,
        else => error.WebViewNativeFailed,
    };
}

test "native status remains separate from real failure domains" {
    try check(0);
    try std.testing.expectError(error.Closed, check(1));
    try std.testing.expectError(error.OutOfMemory, check(3));
    try std.testing.expectError(error.WebViewNativeFailed, check(5));
    try std.testing.expectError(error.NavigationPending, check(7));
    try std.testing.expectError(error.NoHistory, check(9));
    try std.testing.expectError(error.NavigationCancelled, check(10));
    try std.testing.expectError(error.NativeGeometryNotApplied, check(11));
}

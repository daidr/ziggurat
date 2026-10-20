const std = @import("std");
const z = @import("ziggurat");
const backend = @import("backend.zig");
const webkit = @import("webkit.zig");
const webkit_remote = @import("webkit_remote.zig");
pub const RequestPolicyExtension = webkit_remote.Extension;
const is_linux = @import("builtin").os.tag == .linux;
const native_profiles = @import("profile.zig");
pub const profile_storage = native_profiles.storage;
pub const Profile = @import("profile_app.zig").Type(z);
pub const ProfileLimits = native_profiles.Limits;
pub const cookies = @import("cookies.zig");
pub const CookieStore = @import("cookie_store.zig").Type(z, Profile);
pub const cookieStoreNativeCounts = @import("cookie_store.zig").nativeCounts;
test "independent cookie store rejects unsupported platforms before any owner access" {
    if (!is_linux) {
        const app: *z.App = @ptrFromInt(4096);
        const profile: *Profile = @ptrFromInt(4096);
        try std.testing.expectError(error.UnsupportedCapability, CookieStore.create(std.testing.failing_allocator, app, profile, .{}));
        const store: *CookieStore = @ptrFromInt(4096);
        const Never = struct {
            fn complete(_: *anyopaque, _: cookies.Result) void {
                unreachable;
            }
        };
        try std.testing.expectError(error.UnsupportedCapability, store.listAll(.{ .context = @ptrFromInt(4096), .complete = Never.complete }));
        const unreadable_cookies: [*]const cookies.Cookie = @ptrFromInt(4096);
        try std.testing.expectError(error.UnsupportedCapability, store.replaceAll(unreadable_cookies[0..1], .{ .context = @ptrFromInt(4096), .complete = Never.complete }));
        const unreadable_key: [*]const u8 = @ptrFromInt(4096);
        try std.testing.expectError(error.UnsupportedCapability, store.deleteKey(.{ .name = unreadable_key[0..1], .domain = unreadable_key[0..1], .path = unreadable_key[0..1] }, .{ .context = @ptrFromInt(4096), .complete = Never.complete }));
        try std.testing.expectEqual(@as(u32, 0), cookieStoreNativeCounts().stores);
    }
}
test "profile TLS options reject unsupported platforms before owner input or allocation" {
    if (!native_profiles.supported) {
        const app: *z.App = @ptrFromInt(4096);
        const prepared: *profile_storage.Prepared = @ptrFromInt(4096);
        const unreadable: [*]const u8 = @ptrFromInt(4096);
        const options: Profile.CreateOptions = .{ .limits = .{ .bytes = 0 }, .loopback_https = .{ .certificate_pem = unreadable[0..1] } };
        var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var failure: ?Profile.Failure = .{ .system_errno = 1 };
        try std.testing.expectError(error.UnsupportedCapability, Profile.createWithOptionsAndFailure(fault.allocator(), app, prepared, options, &failure));
        try std.testing.expect(failure == null and fault.alloc_index == 0);
        try std.testing.expectError(error.UnsupportedCapability, Profile.createWithOptions(fault.allocator(), app, prepared, options));
        try std.testing.expectEqual(@as(usize, 0), fault.alloc_index);
    }
}
pub const BackendCapabilities = backend.Capabilities;
pub const Storage = backend.Storage;
pub const NativeFailure = backend.NativeFailure;
pub const backendCapabilities = backend.capabilities;
pub const findCapabilities = backend.findCapabilities;
pub const custom_local = @import("custom_local.zig");
pub const CustomLocalLimits = custom_local.Limits;
pub const snapshots = @import("snapshot.zig");
pub const tools = @import("tools.zig");
pub const resources = @import("resources.zig");
pub const file_responses = @import("file_responses.zig");
pub const schemes = @import("schemes.zig");
pub const SchemeRegistration = schemes.Registration;
pub const permissions = @import("permissions.zig");
pub const downloads = @import("downloads.zig");
pub const policy_store = @import("policy_store.zig");
const page_sessions = @import("page_session.zig");
pub const PageSession = page_sessions.Type(View, SessionHooks);
test {
    _ = policy_store;
    _ = custom_local;
}
pub const DownloadDestination = downloads.Destination;
pub const PermissionId = struct {
    view: *View,
    token: u64,
    page: u64,
    pub fn cancel(self: PermissionId) !bool {
        return self.view.cancelPermission(self);
    }
};
pub const OwnedFileResponse = file_responses.OwnedFileResponse;
pub const StreamTicket = file_responses.StreamTicket;
const evaluations = @import("evaluations.zig");
const initializer_owner = @import("initializer_owner.zig");
pub const document_initializers = initializer_owner.source;
pub const DocumentInitializer = document_initializers.Initializer;
pub const InitializerLimits = document_initializers.Limits;
pub const InitializerResult = initializer_owner.transaction.Result;
pub const InitializerCompletion = initializer_owner.transaction.Completion;
pub const InitializerReplacement = struct {
    view: *View,
    token: u64,
    /// Completes logically once while Add is pending. Returns false after Add
    /// result processing begins, or once clear commits before its first Remove.
    /// Successful cancellation still holds the slot until physical retirement.
    pub fn cancel(self: InitializerReplacement) !bool {
        return self.view.cancelDocumentInitializers(self.token);
    }
};
pub const ScriptLimits = evaluations.Limits;
pub const ScriptResult = evaluations.Result;
pub const ScriptCompletion = evaluations.Completion;
pub const EvaluationOptions = struct { timeout_ms: ?u32 = null };
pub const Evaluation = struct {
    view: *View,
    token: u64,
    /// Logical cancellation; successful cancellation completes once immediately.
    /// This does not interrupt JavaScript already running in the system Runtime.
    pub fn cancel(self: Evaluation) !bool {
        return self.view.cancelEvaluation(self.token);
    }
};
pub const ToolOperation = struct {
    view: *View,
    token: u64,
    pub fn cancel(self: ToolOperation) !bool {
        return self.view.cancelTool(self.token);
    }
};
/// Identity only, with no native pointer. The View must outlive every use.
/// Carry to a worker as data; respond/cancel only on the App owner thread.
pub const ResourceRequestId = struct {
    view: *View,
    token: u64,
    page: u64,
    pub fn cancel(self: ResourceRequestId) !bool {
        return self.view.cancelRequest(self);
    }
};

pub const Event = union(enum) {
    /// Controller and message channel are ready; the document may still be loading.
    ready,
    /// Borrowed UTF-8, valid only for the duration of the callback.
    message: []const u8,
    /// Native OS code. Read nativeFailure() during this callback for its domain.
    failed: i32,
    /// The native action has already been denied. URI is borrowed until return.
    policy_request: PolicyRequest,
    /// Recovery is an explicit, queued operation; no automatic restart occurs.
    process_failed: ProcessFailure,
    /// A queued reload closed the previous controller and released its resource
    /// pointers. Previous resource bodies may now be freed. New bodies stay
    /// borrowed until the next such event or detach. This precedes the new ready.
    resources_released,
};
/// Both actions deny the native request. Notify adds an application event only
/// when Runtime raises one; cached DENY decisions can remain silent.
pub const PolicyAction = enum { deny, notify };
pub const PolicyKind = enum { navigation, new_window, download, permission, frame_navigation };
pub const Policy = struct {
    navigation: PolicyAction = .deny,
    new_window: PolicyAction = .deny,
    download: PolicyAction = .deny,
    permission: PolicyAction = .deny,
    frame_navigation: PolicyAction = .deny,
};
pub const PolicyRequest = struct { kind: PolicyKind, uri: []const u8, native_detail: i32 };
pub const ProcessFailure = struct { native_kind: i32 };
/// A document generation belongs to one stable View. The View must outlive use.
pub const PageId = struct { view: *const View, generation: u64 };
pub const PageEvent = union(enum) {
    started: struct { id: PageId, navigation_id: u64, uri: ?[]const u8, redirected: bool },
    completed: struct { id: PageId, navigation_id: u64, success: bool, native_status: i32 },
    dom_ready: PageId,
    source_changed: struct { id: PageId, uri: ?[]const u8 },
    title_changed: struct { id: PageId, title: ?[]const u8 },
    history_changed: struct { id: PageId, can_go_back: bool, can_go_forward: bool },
};
pub const PageListener = struct {
    /// Stable until detach. Strings are borrowed until return. Null metadata
    /// means conversion/size failure, also reported to diagnostics; lifecycle
    /// events are still delivered so the host can invalidate its old IPC session.
    context: *anyopaque,
    event: *const fn (*anyopaque, *View, PageEvent) void,
};
pub const Resource = snapshots.Resource;
pub const Response = resources.Response;
pub const ResourceRequest = struct { uri: []const u8, path: []const u8, method: resources.Method, headers: []const resources.Header = &.{} };
pub const ResourceHandler = struct {
    /// Stable caller storage, borrowed until detach.
    context: *anyopaque,
    /// Synchronous and nonblocking. Request and Responder cannot escape this call.
    handle: *const fn (*anyopaque, ResourceRequest, *Responder) void,
};
pub const LocalSite = struct {
    /// HTTPS keeps the ordinary local site. Other names require a matching
    /// custom_schemes environment registration and use scheme://host/path.
    scheme: []const u8 = "https",
    /// Registered-scheme IPC is opt-in; this does not change HTTPS local IPC.
    scheme_ipc: bool = false,
    host: []const u8 = "app.ziggurat.invalid",
    start_path: []const u8 = "/",
    resources: []const Resource = &.{},
    on_resource: ?ResourceHandler = null,
    methods: resources.MethodSet = .{},
    request_headers: []const resources.HeaderGrant = &.{},
    /// Route the start document through on_resource, including its loading phase.
    dynamic_document: bool = false,
};
pub const OriginGrant = struct {
    /// Absolute HTTP(S) origin only, with optional port and trailing slash.
    origin: []const u8,
    navigate: bool = true,
    requests: bool = true,
    methods: resources.MethodSet = .{},
    /// Only constrains observed request headers; never modifies the request.
    request_headers: []const resources.HeaderGrant = &.{},
    /// Explicitly trust this remote origin for both incoming and outgoing IPC.
    ipc: bool = false,
};
pub const RequestCredential = @import("request_credentials.zig").Entry;
pub const RemotePage = struct {
    url: []const u8,
    origins: []const OriginGrant,
    /// Explicit browser storage policy: Windows profile, or Linux storage
    /// matching the ephemeral Context or supplied Profile owner. Ephemeral
    /// still permits in-memory cookies; this does not grant system credentials.
    credentials: enum { profile, ephemeral },
    /// Immutable exact HTTPS origin Bearer sending capabilities.
    /// Independent of OriginGrant/HeaderGrant and captured before allocation.
    request_credentials: []const RequestCredential = &.{},
    allow_script_navigation: bool = false,
    allow_redirects: bool = false,
    /// HTTP is restricted to loopback and needs this opt-in; HTTPS loopback too.
    allow_insecure_loopback: bool = false,
};
pub const PermissionOffer = struct { origin: []const u8, kind: permissions.Kind, user_initiated: bool, page: PageId };
pub const PermissionHandler = struct {
    context: *anyopaque,
    /// Borrowed data/responder cannot escape; defer to cross the worker boundary.
    handle: *const fn (*anyopaque, PermissionOffer, *PermissionResponder) void,
};
pub const PermissionPolicy = struct {
    grants: []const permissions.Grant,
    handler: PermissionHandler,
    require_user_gesture: bool = true,
    limits: permissions.Limits = .{},
};
pub const PermissionResponder = struct {
    view: *View,
    native: *anyopaque,
    page: u64,
    responded: bool = false,
    pub fn deny(self: *PermissionResponder) !void {
        if (self.responded) return error.AlreadyDecided;
        self.responded = true;
    }
    pub fn deferDecision(self: *PermissionResponder, options: permissions.DeferOptions) !PermissionId {
        if (self.responded) return error.AlreadyDecided;
        const id = try self.view.deferPermission(self.native, self.page, options);
        self.responded = true;
        return id;
    }
};
pub const DownloadId = struct {
    view: *View,
    token: u64,
    pub fn cancel(self: DownloadId) !bool {
        return self.view.cancelDownload(self);
    }
    pub fn pause(self: DownloadId) !void {
        return self.view.pauseDownload(self, true);
    }
    pub fn resumeTransfer(self: DownloadId) !void {
        return self.view.pauseDownload(self, false);
    }
    pub fn snapshot(self: DownloadId) !downloads.Snapshot {
        return self.view.downloadSnapshot(self);
    }
};
pub const DownloadOffer = struct {
    uri: []const u8,
    mime: []const u8,
    suggested_name: []const u8,
    total_bytes: ?u64,
    /// Audit only. A download belongs to this View, not to a document lifetime.
    observed_page: ?PageId,
};
pub const DownloadHandler = struct {
    context: *anyopaque,
    handle: *const fn (*anyopaque, DownloadOffer, *DownloadResponder) void,
};
pub const DownloadPolicy = struct {
    origins: []const []const u8,
    handler: DownloadHandler,
    /// Required acknowledgement that ordinary navigation does not cancel it.
    lifetime: enum { view },
    limits: downloads.Limits = .{},
};
pub const DownloadResponder = struct {
    view: *View,
    native: *anyopaque,
    responded: bool = false,
    pub fn deny(self: *DownloadResponder) !void {
        if (self.responded) return error.AlreadyDecided;
        self.responded = true;
    }
    pub fn deferDecision(self: *DownloadResponder, options: downloads.DeferOptions) !DownloadId {
        if (self.responded) return error.AlreadyDecided;
        const id = try self.view.deferDownload(self.native, options);
        self.responded = true;
        return id;
    }
};
pub const Options = struct {
    html: []const u8,
    /// An absolute, application-specific writable directory. Before navigation,
    /// cached ALLOW permissions are asynchronously reset to DEFAULT so current
    /// denial policy applies. Missing APIs or too many cached settings fail.
    user_data_folder: []const u8 = "",
    /// Linux persistent storage requires an explicit owner from this App and
    /// an empty folder. Copied configurations retain only its C-native state.
    profile: ?*Profile = null,
    /// Ephemeral storage is currently Linux-only and requires an empty folder.
    /// The default preserves the explicit persistent profile contract.
    storage: Storage = .profile,
    local: ?LocalSite = null,
    /// Linux static registered-scheme responses. No native budget is allocated
    /// for ordinary HTML. Late streams retain physical bytes/slots until free.
    custom_local_limits: CustomLocalLimits = .{},
    /// Mutually exclusive with local and nonempty html. Default has no network grant.
    remote: ?RemotePage = null,
    /// Linux remote pages require an explicitly deployed native request adapter.
    request_policy_extension: ?RequestPolicyExtension = null,
    /// Environment-wide immutable registrations. Reload must keep this set.
    /// Custom request_origins filters Origin independently of method/header
    /// grants. Registration grants no navigation, IPC or Cookie access.
    custom_schemes: []const SchemeRegistration = &.{},
    /// Default remains native DENY without UI. Decisions never persist in the
    /// profile; Runtime session caching is not a one-host-query-per-call promise.
    permissions: ?PermissionPolicy = null,
    /// Explicit View-scoped transfers. Default cancels without native UI.
    downloads: ?DownloadPolicy = null,
    scripts: ScriptLimits = .{},
    /// Trusted, valid ordinary function bodies at document start/top/page world.
    /// No JavaScript parser or untrusted-code sandbox is provided.
    /// Exact HTTPS execution scopes grant no navigation, TLS or IPC capability.
    document_initializers: []const DocumentInitializer = &.{},
    initializer_limits: InitializerLimits = .{},
    zoom: f64 = 1.0,
    user_agent: ?[]const u8 = null,
    devtools_enabled: bool = false,
    tools: tools.Policy = .{},
    tool_limits: tools.Limits = .{},
    policy: Policy = .{},
    max_resource_bytes: usize = 16 * 1024 * 1024,
    resource_limits: resources.Limits = .{},
    /// Optional complete private-file responses. Disabled creates no stream
    /// budget, COM object, control/event, or file handle.
    file_streams: ?file_responses.Limits = null,
    /// Maximum nondefault profile records inspected before any document loads.
    /// Zero permits only a profile with no cached permission records.
    max_cached_permissions: u16 = 256,
    /// Permit links/scripts to navigate within the configured local HTTPS site.
    /// Remote/file/frame navigation remains denied. Host navigateLocal is explicit.
    allow_local_navigation: bool = false,
    page_listener: ?PageListener = null,
};

const NativePageEvent = webkit.PageEvent;
const NativeHeaderGrant = extern struct { name: [*]const u8, name_len: u32, value: ?[*]const u8, value_len: u32, exact: bool };
const NativeHeader = extern struct { name: [*:0]const u16, value: [*:0]const u16 };
const NativeResponseHeader = webkit.ResponseHeader;
const NativeOrigin = extern struct { origin: [*:0]const u16, flags: u32, methods: u32, headers: ?[*]const NativeHeaderGrant, header_count: u32 };
const NativeCredential = extern struct { origin: [*]const u8, origin_len: u32, bearer: *const [32]u8 };
const NativeRemote = extern struct { url: [*:0]const u16, origins: [*]const NativeOrigin, count: u32, allow_loopback: bool, allow_script_navigation: bool, allow_redirects: bool, credentials: ?[*]const NativeCredential, credential_count: u32 };
comptime {
    if (@sizeOf(usize) == 8 and (@sizeOf(NativeCredential) != 24 or @sizeOf(NativeRemote) != 40)) @compileError("Windows remote credential descriptor ABI mismatch");
}
const NativeScheme = extern struct { name: [*:0]const u16, secure: c_int, origins: ?[*]const [*:0]const u16, origin_count: u32 };
const NativePermissionGrant = extern struct { origin: [*:0]const u16, kinds: u32 };
const NativeActions = extern struct {
    budget: *anyopaque,
    permissions: ?[*]const NativePermissionGrant = null,
    permission_count: u32 = 0,
    permission_gesture: bool = true,
    permission_offer: ?*const fn (*anyopaque, [*:0]const u16, u32, bool, *anyopaque) callconv(.c) void = null,
    download_origins: ?[*]const [*:0]const u16 = null,
    download_origin_count: u32 = 0,
    download_known_limit: u64 = 0,
    download_received_limit: u64 = 0,
    download_unknown: bool = false,
    download_offer: ?*const fn (*anyopaque, [*:0]const u16, [*:0]const u16, [*:0]const u16, i64, *anyopaque) callconv(.c) void = null,
    download_notify: ?*const fn (*anyopaque, u64, u32, u64, i64, i32) callconv(.c) void = null,
};
const NativeSettings = extern struct { zoom: f64, user_agent: ?[*:0]const u16, devtools: bool, tool_flags: u32, tool_limit: u32, max_cookies: u32, max_cookie_bytes: u32, max_capture_bytes: u32, schemes: ?[*]const NativeScheme, scheme_count: u32, local_ipc: bool, actions: ?*const NativeActions, initializers: ?*const initializer_owner.NativeInput, owned_context: ?*anyopaque };
const PermissionScratch = struct {
    rows: [permissions.origin_capacity]NativePermissionGrant = undefined,
    text: [permissions.origin_capacity][schemes.origin_limit + 1:0]u16 = undefined,
    fn prepare(self: *@This(), policy: PermissionPolicy, budget: *anyopaque) NativeActions {
        for (policy.grants, 0..) |grant, i| {
            for (grant.origin, 0..) |byte, j| self.text[i][j] = byte;
            self.text[i][grant.origin.len] = 0;
            self.rows[i] = .{ .origin = @ptrCast(&self.text[i]), .kinds = @as(u16, @bitCast(grant.kinds)) };
        }
        return .{ .budget = budget, .permissions = &self.rows, .permission_count = @intCast(policy.grants.len), .permission_gesture = policy.require_user_gesture, .permission_offer = View.permissionOffer };
    }
};
const DownloadScratch = struct {
    pointers: [downloads.origin_capacity][*:0]const u16 = undefined,
    text: [downloads.origin_capacity][schemes.origin_limit + 1:0]u16 = undefined,
    fn prepare(self: *@This(), policy: DownloadPolicy, actions: *NativeActions) void {
        for (policy.origins, 0..) |origin, i| {
            for (origin, 0..) |byte, j| self.text[i][j] = byte;
            self.text[i][origin.len] = 0;
            self.pointers[i] = @ptrCast(&self.text[i]);
        }
        actions.download_origins = &self.pointers;
        actions.download_origin_count = @intCast(policy.origins.len);
        actions.download_known_limit = policy.limits.max_known_bytes;
        actions.download_received_limit = policy.limits.max_received_bytes;
        actions.download_unknown = policy.limits.allow_unknown_length;
        actions.download_offer = View.downloadOffer;
        actions.download_notify = View.downloadNotify;
    }
};
const SchemeScratch = struct {
    items: [schemes.capacity]NativeScheme = undefined,
    names: [schemes.capacity][schemes.name_limit + 1:0]u16 = undefined,
    origins: [schemes.capacity][schemes.origin_capacity][schemes.origin_limit + 1:0]u16 = undefined,
    pointers: [schemes.capacity][schemes.origin_capacity][*:0]const u16 = undefined,
    fn prepare(self: *@This(), input: []const SchemeRegistration) void {
        for (input, 0..) |item, i| {
            for (item.name, 0..) |byte, j| self.names[i][j] = byte;
            self.names[i][item.name.len] = 0;
            for (item.request_origins, 0..) |origin, j| {
                for (origin, 0..) |byte, k| self.origins[i][j][k] = byte;
                self.origins[i][j][origin.len] = 0;
                self.pointers[i][j] = @ptrCast(&self.origins[i][j]);
            }
            self.items[i] = .{ .name = @ptrCast(&self.names[i]), .secure = @intFromBool(item.treat_as_secure), .origins = if (item.request_origins.len == 0) null else &self.pointers[i], .origin_count = @intCast(item.request_origins.len) };
        }
    }
};
const NativeToolRequest = extern struct { kind: u32, flags: u32 = 0, token: u64 = 0, text: ?[*:0]const u16 = null, first_page: u32 = 0, last_page: u32 = 0 };
const NativeFind = extern struct { matches: i32, active_index: i32 };
const NativeCookie = extern struct { name: ?[*:0]const u16, value: ?[*:0]const u16, domain: ?[*:0]const u16, path: ?[*:0]const u16, expires: f64, flags: u32, same_site: u32 };
const NativeCookieWrite = extern struct { name: [*:0]const u16, value: [*:0]const u16, path: [*:0]const u16, expires: f64, flags: u32, same_site: u32 };
const RemoteScratch = struct {
    origins: [32]NativeOrigin = undefined,
    text: [32][1025:0]u16 = undefined,
    headers: [32][16]NativeHeaderGrant = undefined,
    url: [16385:0]u16 = undefined,
    credentials: [8]NativeCredential = undefined,
    fn prepare(self: *@This(), remote: RemotePage) !NativeRemote {
        if (remote.origins.len == 0 or remote.origins.len > 32) return error.InvalidOriginCount;
        if (remote.request_credentials.len > self.credentials.len) return error.TooManyRequestCredentials;
        const url_len = try uriWide(&self.url, remote.url);
        self.url[url_len] = 0;
        for (remote.origins, 0..) |grant, i| {
            if (grant.methods.reserved != 0 or (grant.requests and @as(u8, @bitCast(grant.methods)) == 0)) return error.InvalidMethods;
            try resources.validateGrants(grant.request_headers);
            const len = try uriWide(&self.text[i], grant.origin);
            self.text[i][len] = 0;
            for (grant.request_headers, 0..) |header, j| self.headers[i][j] = .{ .name = header.name.ptr, .name_len = @intCast(header.name.len), .value = if (header.exact_value) |value| value.ptr else null, .value_len = if (header.exact_value) |value| @intCast(value.len) else 0, .exact = header.exact_value != null };
            self.origins[i] = .{ .origin = @ptrCast(&self.text[i]), .flags = @as(u32, @intFromBool(grant.navigate)) | @as(u32, @intFromBool(grant.requests)) << 1 | @as(u32, @intFromBool(grant.ipc)) << 2, .methods = @as(u8, @bitCast(grant.methods)), .headers = if (grant.request_headers.len != 0) &self.headers[i] else null, .header_count = @intCast(grant.request_headers.len) };
        }
        for (remote.request_credentials, 0..) |*credential, index| {
            if (credential.origin.len == 0 or credential.origin.len > 1024) return error.InvalidCredentialOrigin;
            self.credentials[index] = .{ .origin = credential.origin.ptr, .origin_len = @intCast(credential.origin.len), .bearer = &credential.bearer };
        }
        return .{ .url = @ptrCast(&self.url), .origins = &self.origins, .count = @intCast(remote.origins.len), .allow_loopback = remote.allow_insecure_loopback, .allow_script_navigation = remote.allow_script_navigation, .allow_redirects = remote.allow_redirects, .credentials = if (remote.request_credentials.len != 0) &self.credentials else null, .credential_count = @intCast(remote.request_credentials.len) };
    }
};
fn uriWide(destination: []u16, value: []const u8) !usize {
    if (value.len == 0 or value.len >= destination.len) return error.UriTooLarge;
    for (value) |byte| if (byte <= 32 or byte >= 127 or byte == '\\') return error.InvalidRemoteUri;
    for (value, 0..) |byte, index| destination[index] = byte;
    return value.len;
}
extern fn zwv_remote_validate(*const NativeRemote) i32;
extern fn zwv_initializers_prepare(*anyopaque, *const initializer_owner.NativeInput, u64, ?*const fn (*anyopaque, u64, u32, i32) callconv(.c) void) i32;
extern fn zwv_initializers_activate(*anyopaque) void;
extern fn zwv_initializers_abandon(*anyopaque) void;
extern fn zwv_initializers_cancel(*anyopaque, u64) void;
extern fn zwv_initializers_try_cancel(*anyopaque, u64) bool;
extern fn zwv_initializers_blocked(*anyopaque) bool;
extern fn zwv_initializer_counts(*u32, *u32, *u32, *u64) void;
pub const InitializerNativeCounts = struct { budgets: u32 = 0, owners: u32 = 0, handlers: u32 = 0, bytes: u64 = 0 };
pub fn initializerNativeCounts() InitializerNativeCounts {
    var counts: InitializerNativeCounts = .{};
    if (is_linux) webkit.zwk_initializer_counts(&counts.budgets, &counts.owners, &counts.handlers, &counts.bytes) else zwv_initializer_counts(&counts.budgets, &counts.owners, &counts.handlers, &counts.bytes);
    return counts;
}
extern fn zwv_action_budget_create(u32, u32) ?*anyopaque;
extern fn zwv_action_budget_limit(*anyopaque, u32, u32) void;
extern fn zwv_action_budget_release(*anyopaque) void;
extern fn zwv_action_counts(*u32, *u32, *u32) void;
extern fn zwv_permission_defer(*anyopaque, u64) i32;
extern fn zwv_permission_decide(*anyopaque, u64, bool) i32;
extern fn zwv_permission_cancel(*anyopaque, u64) i32;
extern fn zwv_download_defer(*anyopaque, u64) i32;
extern fn zwv_download_accept(*anyopaque, u64, [*:0]const u16) i32;
extern fn zwv_download_activate(*anyopaque, u64) void;
extern fn zwv_download_cancel(*anyopaque, u64) i32;
extern fn zwv_download_pause(*anyopaque, u64, bool) i32;
extern fn zwv_download_snapshot(*anyopaque, u64, *u64, *i64, *bool) i32;
extern fn zwv_create(?*anyopaque, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, ?*const NativeRemote, *const NativeSettings, u32, c_uint, c_uint, bool, bool, *const fn (*anyopaque, c_int, ?[*:0]const u16, i32) callconv(.c) void, *const fn (*anyopaque, *const NativePageEvent) callconv(.c) c_int, *const fn (*anyopaque, u64, i32, ?[*:0]const u16) callconv(.c) void, *const fn (*anyopaque, u64, u32, i32, ?*const anyopaque, u32) callconv(.c) void, *const fn (*anyopaque, [*:0]const u16, [*:0]const u16, [*]const NativeHeader, u32, *anyopaque) callconv(.c) void, *anyopaque, *i32) ?*anyopaque;
extern fn zwv_close(*anyopaque) void;
extern fn zwv_resize(*anyopaque) i32;
extern fn zwv_viewport(*anyopaque, i32, i32, i32, i32, bool) i32;
extern fn zwv_parent_position(*anyopaque) i32;
extern fn zwv_session_viewport(*anyopaque, i32, i32, bool) i32;
extern fn zwv_post(*anyopaque, [*:0]const u16) i32;
extern fn zwv_resource_counts(*u32, *u32, *u32) void;
extern fn zwv_respond(*anyopaque, c_uint, [*]const u8, usize, [*]const u8, usize, ?[*]const NativeResponseHeader, u32) i32;
extern fn zwv_defer_resource(*anyopaque, u64) i32;
extern fn zwv_respond_deferred(*anyopaque, u64, c_uint, [*]const u8, usize, [*]const u8, usize, ?[*]const NativeResponseHeader, u32) i32;
extern fn zwv_cancel_resource(*anyopaque, u64) void;
extern fn zwv_resource_pending() u32;
extern fn zwv_file_budget_create(u32) ?*anyopaque;
extern fn zwv_file_budget_limit(*anyopaque, u32) void;
extern fn zwv_file_budget_release(*anyopaque) void;
extern fn zwv_file_cancel_all(*anyopaque) void;
extern fn zwv_respond_file(*anyopaque, *anyopaque, u64, *anyopaque, c_uint, [*]const u8, usize, [*]const NativeResponseHeader, u32, c_int, *?*anyopaque) i32;
extern fn zwv_respond_file_deferred(*anyopaque, u64, *anyopaque, u64, *anyopaque, c_uint, [*]const u8, usize, [*]const NativeResponseHeader, u32, c_int, *?*anyopaque) i32;
extern fn zwv_file_counts(*u32, *u32, *u32) void;
extern fn zwv_recovery_begin(*anyopaque) i32;
extern fn zwv_recovery_anchor(*const fn (*anyopaque, c_int, ?[*:0]const u16, i32) callconv(.c) void, *anyopaque) ?*anyopaque;
extern fn zwv_recovery_cancel(*anyopaque) void;
extern fn zwv_recovery_dispatch(*anyopaque) void;
extern fn zwv_navigate_local(*anyopaque, [*:0]const u16) i32;
extern fn zwv_navigate_remote(*anyopaque, [*:0]const u16) i32;
extern fn zwv_page_action(*anyopaque, c_int) i32;
extern fn zwv_evaluate(*anyopaque, [*:0]const u16, u64) i32;
extern fn zwv_evaluate_cancel(*anyopaque, u64) void;
extern fn zwv_eval_timer_create(*?*anyopaque) i32;
extern fn zwv_eval_timer_arm(*anyopaque, u64) i32;
extern fn zwv_eval_timer_close(*anyopaque) void;
extern fn zwv_zoom(*anyopaque, *f64, bool) i32;
extern fn zwv_user_agent(*anyopaque, ?[*:0]const u16, ?*?[*:0]u16) i32;
extern fn zwv_string_free([*:0]u16) void;
extern fn zwv_devtools(*anyopaque, *bool, bool, bool) i32;
extern fn zwv_tool_start(*anyopaque, *const NativeToolRequest) i32;
extern fn zwv_tool_cancel(*anyopaque, u64) void;
extern fn zwv_cookie_write(*anyopaque, [*:0]const u16, *const NativeCookieWrite, bool) i32;
extern fn zwv_find_action(*anyopaque, c_int, *NativeFind) i32;
extern fn zwv_tool_counts(*u32, *u32) void;

pub const Responder = struct {
    native: *anyopaque,
    /// Present only while the page has a live viewport. Never retains a window.
    window: ?z.Window,
    view: *View,
    max_bytes: usize,
    responded: bool = false,
    /// Defers this request with a bounded deadline. Context ownership transfers
    /// only on success; the returned identity does not extend the View lifetime.
    pub fn deferResponse(self: *Responder, options: resources.DeferOptions) !ResourceRequestId {
        const owner = self.view.access() orelse return error.Closed;
        if (self.view.attachmentClosed() or appStopping(owner)) return error.Closed;
        if (self.responded) return error.AlreadyResponded;
        const id = try self.view.deferResource(self.native, options);
        self.responded = true;
        return id;
    }
    /// The adapter copies body and MIME before this returns; stack data is valid.
    /// Exactly one successful response is permitted. Never retain this Responder.
    pub fn respond(self: *Responder, response: Response) !void {
        const owner = self.view.access() orelse return error.Closed;
        if (self.view.attachmentClosed() or appStopping(owner)) return error.Closed;
        if (self.responded) return error.AlreadyResponded;
        try resources.validateResponse(response, self.max_bytes);
        var headers: [16]NativeResponseHeader = undefined;
        for (response.headers, 0..) |header, i| headers[i] = .{ .name = header.name.ptr, .name_len = @intCast(header.name.len), .value = header.value.ptr, .value_len = @intCast(header.value.len) };
        if (is_linux) {
            try self.view.resourceResult(webkit.zwk_resource_respond(self.native, response.status, response.mime.ptr, response.mime.len, response.bytes.ptr, response.bytes.len, &headers, @intCast(response.headers.len)));
            self.responded = true;
            return;
        }
        const hr = zwv_respond(self.native, response.status, response.mime.ptr, response.mime.len, response.bytes.ptr, response.bytes.len, &headers, @intCast(response.headers.len));
        if (hr < 0) {
            owner.report(.{ .domain = .hresult, .operation = .webview_create, .code = @bitCast(hr), .err = error.ResourceResponseFailed });
            return error.ResourceResponseFailed;
        }
        self.responded = true;
    }
    /// The complete file was prepared on an explicit worker. Main-thread commit
    /// reads no file data. Success consumes owned; every error retains it.
    pub fn respondFile(self: *Responder, owned: *OwnedFileResponse, options: file_responses.CommitOptions) !?StreamTicket {
        const owner = self.view.access() orelse return error.Closed;
        if (self.view.attachmentClosed() or appStopping(owner)) return error.Closed;
        if (self.responded) return error.AlreadyResponded;
        const budget = try self.view.fileBudget(owned);
        const response = owned.metadata.response;
        var headers: [16]NativeResponseHeader = undefined;
        for (response.headers, 0..) |header, i| headers[i] = .{ .name = header.name.ptr, .name_len = @intCast(header.name.len), .value = header.value.ptr, .value_len = @intCast(header.value.len) };
        var ticket: ?*anyopaque = null;
        const hr = if (is_linux) webkit.zwk_resource_respond_file(self.native, owned.native.?, owned.length, budget, response.status, response.mime.ptr, response.mime.len, &headers, @intCast(response.headers.len), @intFromBool(options.ticket), &ticket) else zwv_respond_file(self.native, owned.native.?, owned.length, budget, response.status, response.mime.ptr, response.mime.len, &headers, @intCast(response.headers.len), @intFromBool(options.ticket), &ticket);
        if (is_linux) try self.view.resourceResult(hr) else {
            self.view.last_hresult = hr;
            if (hr < 0) return fileResponseError(hr);
        }
        self.responded = true;
        owned.deinit();
        return if (ticket) |control| .{ .native = control } else null;
    }
};
fn fileResponseError(hr: i32) anyerror {
    return switch (@as(u32, @bitCast(hr))) {
        0x8000000a => error.Full,
        0x8007000e => error.OutOfMemory,
        else => error.ResourceResponseFailed,
    };
}
fn appStopping(window: anytype) bool {
    return window.app.phase == .stopping or window.app.phase == .stopped;
}
fn nativeClose(native: *anyopaque) void {
    if (is_linux) webkit.zwk_close(native) else zwv_close(native);
}
fn nativeCancelScript(native: *anyopaque, token: u64) void {
    if (is_linux) webkit.zwk_evaluate_cancel(native, token) else zwv_evaluate_cancel(native, token);
}
fn validateBackendOptions(options: Options) !void {
    if (is_linux) {
        switch (options.storage) {
            .ephemeral => {
                if (options.profile != null) return error.ConflictingProfileStorage;
                if (options.user_data_folder.len != 0) return error.EphemeralProfilePathForbidden;
            },
            .profile => {
                if (options.profile == null) return error.ProfileRequired;
                if (options.user_data_folder.len != 0) return error.ProfilePathForbidden;
            },
        }
        if (options.permissions != null or options.downloads != null or options.allow_local_navigation)
            return error.UnsupportedCapability;
        if (options.remote) |remote| {
            if ((options.storage == .ephemeral and remote.credentials != .ephemeral) or
                (options.storage == .profile and remote.credentials != .profile)) return error.UnsupportedCapability;
            const extension = options.request_policy_extension orelse return error.RequestPolicyExtensionRequired;
            try webkit_remote.validateExtension(extension);
            try webkit_remote.validate(remote);
        } else if (options.request_policy_extension != null) return error.RemotePageRequired;
        try options.custom_local_limits.validate();
        if (options.local) |site| {
            if (std.mem.eql(u8, site.scheme, "https") or options.custom_schemes.len != 1)
                return error.UnsupportedCapability;
            const registration = options.custom_schemes[0];
            if (!std.mem.eql(u8, registration.name, site.scheme)) return error.UnsupportedCapability;
            _ = try webkit.localPolicyBytes(site, registration);
            if (site.methods.reserved != 0 or @as(u8, @bitCast(site.methods)) == 0) return error.InvalidMethods;
            try resources.validateGrants(site.request_headers);
            if (options.file_streams != null and site.on_resource == null) return error.ResourceHandlerRequired;
        } else if (options.custom_schemes.len != 0 or !std.meta.eql(options.custom_local_limits, CustomLocalLimits{})) return error.UnsupportedCapability;
        if (options.file_streams != null and options.local == null) return error.LocalSiteRequired;
        if (options.policy.new_window != .deny or options.policy.download != .deny or options.policy.permission != .deny or options.policy.frame_navigation != .deny or
            options.max_cached_permissions != 256 or options.tool_limits.max_cookies != (tools.Limits{}).max_cookies or options.tool_limits.max_cookie_bytes != (tools.Limits{}).max_cookie_bytes) return error.UnsupportedCapability;
        if (options.max_resource_bytes > 16 * 1024 * 1024) return error.InvalidResourceLimit;
        inline for (std.meta.fields(tools.Policy)) |field| if (!std.mem.eql(u8, field.name, "capture") and !std.mem.eql(u8, field.name, "find") and !std.mem.eql(u8, field.name, "clear_entire_profile") and @field(options.tools, field.name)) return error.UnsupportedCapability;
    } else {
        if (options.storage != .profile or !std.meta.eql(options.custom_local_limits, CustomLocalLimits{}) or options.request_policy_extension != null) return error.UnsupportedCapability;
        if (options.profile != null) {
            if (options.user_data_folder.len != 0) return error.ProfilePathForbidden;
            if (options.custom_schemes.len != 0) return error.UnsupportedCapability;
        }
        if (options.remote) |remote| if (remote.credentials != .profile) return error.UnsupportedCapability;
    }
}

fn validMime(value: []const u8) bool {
    if (value.len == 0 or value.len > 127) return false;
    for (value) |byte| if (byte < 32 or byte > 126) return false;
    return true;
}
fn validUserAgent(value: []const u8) bool {
    if (value.len > 4096 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}
fn validPath(value: []const u8) bool {
    if (value.len == 0 or value.len > 4096 or value[0] != '/') return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-_.", byte) != null)) return false;
    var segments = std.mem.splitScalar(u8, value, '/');
    while (segments.next()) |segment| if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    return true;
}
fn validHost(value: []const u8) bool {
    if (value.len == 0 or value.len > 253) return false;
    var labels = std.mem.splitScalar(u8, value, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |byte| if (!(byte >= 'a' and byte <= 'z') and !std.ascii.isDigit(byte) and byte != '-') return false;
    }
    return true;
}

const config_alignment = std.mem.Alignment.fromByteUnits(@max(@alignOf(Resource), @alignOf(ProfileState)));
const ProfileState = struct {
    lease: native_profiles.ConfigLease,
    context: native_profiles.Context,
    pending_context: ?native_profiles.Context = null,
    admitted: bool = false,
};
const OwnedConfig = struct {
    storage: []align(@alignOf(Resource)) u8,
    options: Options,
    url: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    scheme_config: schemes.Owned,
    permission_config: ?permissions.Owned = null,
    download_config: ?downloads.OwnedOrigins = null,
    initializer_config: ?*initializer_owner.Config = null,
    profile_state: ?*ProfileState = null,
    fn copy(storage: []u8, offset: *usize, text: []const u8) []const u8 {
        const result = storage[offset.* .. offset.* + text.len];
        @memcpy(result, text);
        offset.* += text.len;
        return result;
    }
    fn init(allocator: std.mem.Allocator, options: Options) !OwnedConfig {
        try validateBackendOptions(options);
        if (options.profile != null) return error.ProfileAppRequired;
        return initPortable(allocator, options);
    }
    fn initForApp(allocator: std.mem.Allocator, options: Options, app: *z.App) !OwnedConfig {
        return initForAppDomain(allocator, options, app, null);
    }
    fn initForAppDomain(allocator: std.mem.Allocator, options: Options, app: *z.App, domain: ?*anyopaque) !OwnedConfig {
        try validateBackendOptions(options);
        if (options.profile == null) return initOwnedDomain(allocator, options, false, domain);
        var lease = try options.profile.?.retainForApp(app);
        errdefer lease.release() catch unreachable;
        var cleaned = options;
        cleaned.profile = null;
        var result = try initOwnedDomain(allocator, cleaned, true, domain);
        errdefer result.deinit(allocator);
        var context = try lease.context();
        errdefer context.close() catch unreachable;
        // All candidate allocator callbacks and Context construction have
        // returned. No public Profile pointer remains past the first allocation.
        try lease.check();
        if (app.phase == .stopping or app.phase == .stopped) return error.Closed;
        const offset = std.mem.alignBackward(usize, result.storage.len - @sizeOf(ProfileState), @alignOf(ProfileState));
        const state: *ProfileState = @ptrCast(@alignCast(result.storage.ptr + offset));
        state.* = .{ .lease = lease, .context = context };
        lease.native = null;
        context.native = null;
        result.profile_state = state;
        return result;
    }
    // Ownership/encoding can be tested independently of backend grants. Public
    // submission always passes through init and its capability preflight.
    fn initPortable(allocator: std.mem.Allocator, options: Options) !OwnedConfig {
        return initOwned(allocator, options, false);
    }
    fn initOwned(allocator: std.mem.Allocator, options: Options, persistent: bool) !OwnedConfig {
        return initOwnedDomain(allocator, options, persistent, null);
    }
    fn initOwnedDomain(allocator: std.mem.Allocator, options: Options, persistent: bool, domain: ?*anyopaque) !OwnedConfig {
        if (options.remote) |remote| if (remote.request_credentials.len != 0) return initCredentialOwned(allocator, options, persistent, domain);
        return initCommon(allocator, options, persistent, domain);
    }
    noinline fn initCredentialOwned(allocator: std.mem.Allocator, source_options: Options, persistent: bool, domain: ?*anyopaque) !OwnedConfig {
        var capture: @import("request_credentials.zig").Capture = .{};
        defer capture.deinit();
        var options = source_options;
        if (options.remote) |remote| {
            try capture.init(remote.request_credentials);
            options.remote.?.request_credentials = capture.entries[0..capture.count];
        }
        return initCommon(allocator, options, persistent, domain);
    }
    fn initCommon(allocator: std.mem.Allocator, options: Options, persistent: bool, domain: ?*anyopaque) !OwnedConfig {
        if (domain) |value| try initializer_owner.validateSharedLimits(options.initializer_limits, value);
        if (options.document_initializers.len != 0) {
            const owned = (try initializer_owner.Config.create(allocator, options.document_initializers, options.initializer_limits, domain)).?;
            errdefer owned.destroy();
            var cleaned = options;
            cleaned.document_initializers = &.{};
            var result = try initCommonBase(allocator, cleaned, persistent);
            result.initializer_config = owned;
            result.options.document_initializers = owned.owned.entries;
            return result;
        }
        return initCommonBase(allocator, options, persistent);
    }
    fn initCommonBase(allocator: std.mem.Allocator, options: Options, persistent: bool) !OwnedConfig {
        try options.initializer_limits.validate();
        var scheme_config = try schemes.Owned.init(allocator, options.custom_schemes);
        errdefer scheme_config.deinit();
        var permission_config: ?permissions.Owned = null;
        errdefer if (permission_config) |*owned| owned.deinit();
        if (options.permissions) |policy| {
            try policy.limits.validate();
            permission_config = try permissions.Owned.init(allocator, policy.grants, scheme_config.registrations);
        }
        var download_config: ?downloads.OwnedOrigins = null;
        errdefer if (download_config) |owned| owned.deinit();
        if (options.downloads) |policy| {
            try policy.limits.validate();
            download_config = try downloads.OwnedOrigins.init(allocator, policy.origins);
        }
        try options.scripts.validate();
        try options.tool_limits.validate();
        try options.resource_limits.validate();
        if (options.file_streams) |limits| try limits.validate();
        if (!std.math.isFinite(options.zoom) or options.zoom < 0.25 or options.zoom > 5) return error.InvalidZoom;
        if (options.user_agent) |agent| if (!validUserAgent(agent)) return error.InvalidUserAgent;
        if (options.remote != null and (options.local != null or options.html.len != 0)) return error.ConflictingPageSources;
        if (options.allow_local_navigation and options.local == null) return error.LocalSiteRequired;
        if (options.storage == .profile and !persistent and !std.fs.path.isAbsolute(options.user_data_folder)) return error.AbsoluteProfilePathRequired;
        if (std.mem.indexOfScalar(u8, options.html, 0) != null or std.mem.indexOfScalar(u8, options.user_data_folder, 0) != null) return error.EmbeddedNul;
        if (!std.unicode.utf8ValidateSlice(options.html) or !std.unicode.utf8ValidateSlice(options.user_data_folder)) return error.InvalidUtf8;
        if (options.max_resource_bytes == 0 or options.max_resource_bytes > std.math.maxInt(u32)) return error.InvalidResourceLimit;
        if (options.html.len > options.max_resource_bytes) return error.ResourceTooLarge;
        var size = try std.math.add(usize, options.html.len, options.user_data_folder.len);
        if (options.request_policy_extension) |extension| {
            try webkit_remote.validateExtension(extension);
            size = try std.math.add(usize, size, extension.directory.len);
        }
        if (options.user_agent) |agent| size = try std.math.add(usize, size, agent.len);
        var count: usize = 0;
        var header_count: usize = 0;
        const origin_count = if (options.remote) |remote| remote.origins.len else 0;
        const credential_count = if (options.remote) |remote| remote.request_credentials.len else 0;
        if (options.remote) |remote| {
            if (is_linux) {
                try webkit_remote.validate(remote);
            } else {
                var scratch: RemoteScratch = undefined;
                const native = try scratch.prepare(remote);
                const hr = zwv_remote_validate(&native);
                if (hr < 0) return if (@as(u32, @bitCast(hr)) == 0x8007000e) error.OutOfMemory else error.InvalidRemotePolicy;
            }
            size = try std.math.add(usize, size, try std.math.mul(usize, origin_count, @sizeOf(OriginGrant)));
            size = try std.math.add(usize, size, credential_count * @sizeOf(RequestCredential));
            for (remote.request_credentials) |credential| size = try std.math.add(usize, size, credential.origin.len);
            size = try std.math.add(usize, size, remote.url.len);
            for (remote.origins) |grant| {
                size = try std.math.add(usize, size, grant.origin.len);
                header_count += grant.request_headers.len;
                for (grant.request_headers) |header| size = try std.math.add(usize, size, header.name.len + if (header.exact_value) |value| value.len else @as(usize, 0));
            }
        }
        if (options.local) |site| {
            if (!std.mem.eql(u8, site.scheme, "https")) {
                var registered = false;
                for (scheme_config.registrations) |registration| if (std.mem.eql(u8, site.scheme, registration.name)) {
                    registered = true;
                    break;
                };
                if (!registered) return error.UnregisteredScheme;
                var origin_buffer: [320]u8 = undefined;
                const origin = try std.fmt.bufPrint(&origin_buffer, "{s}://{s}", .{ site.scheme, site.host });
                var canonical: [320]u8 = undefined;
                if (!std.mem.eql(u8, origin, try schemes.canonicalOrigin(&canonical, origin, scheme_config.registrations))) return error.InvalidSchemeOrigin;
            }
            if (site.dynamic_document and site.on_resource == null) return error.ResourceHandlerRequired;
            if (site.methods.reserved != 0 or @as(u8, @bitCast(site.methods)) == 0) return error.InvalidMethods;
            try resources.validateGrants(site.request_headers);
            header_count += site.request_headers.len;
            for (site.request_headers) |header| size = try std.math.add(usize, size, header.name.len + if (header.exact_value) |value| value.len else @as(usize, 0));
            if (!validHost(site.host)) return error.InvalidLocalHost;
            if (!validPath(site.start_path)) return error.InvalidResourcePath;
            if (site.resources.len > 4096) return error.TooManyResources;
            if (options.html.len > options.max_resource_bytes) return error.ResourceTooLarge;
            const response_limit = @min(options.max_resource_bytes, options.resource_limits.max_response_bytes);
            if (!site.dynamic_document and options.html.len > response_limit) return error.ResourceTooLarge;
            count = site.resources.len;
            size = try std.math.add(usize, size, try std.math.mul(usize, count, @sizeOf(Resource)));
            inline for (.{ site.scheme, site.host, site.start_path }) |text| size = try std.math.add(usize, size, text.len);
            size = try std.math.add(usize, size, site.scheme.len + 3 + site.host.len + 1 + site.scheme.len + 3 + site.host.len + site.start_path.len);
            for (site.resources) |resource| {
                if (!validPath(resource.path)) return error.InvalidResourcePath;
                if (std.mem.eql(u8, resource.path, site.start_path)) return error.ResourceConflictsWithDocument;
                if (!validMime(resource.mime)) return error.InvalidMime;
                if (resource.bytes.len > response_limit) return error.ResourceTooLarge;
                size = try std.math.add(usize, size, resource.path.len);
                size = try std.math.add(usize, size, resource.mime.len);
            }
        }
        size = try std.math.add(usize, size, header_count * @sizeOf(resources.HeaderGrant));
        const content_size = size;
        if (persistent) {
            size = try std.math.add(usize, size, @alignOf(ProfileState) - 1);
            size = std.mem.alignBackward(usize, size, @alignOf(ProfileState));
            size = try std.math.add(usize, size, @sizeOf(ProfileState));
        }
        const storage = try allocator.alignedAlloc(u8, config_alignment, size);
        errdefer {
            if (credential_count != 0) std.crypto.secureZero(u8, storage);
            allocator.free(storage);
        }
        var result: OwnedConfig = .{ .storage = storage, .options = options, .scheme_config = scheme_config, .permission_config = permission_config, .download_config = download_config };
        result.options.custom_schemes = scheme_config.registrations;
        if (result.options.permissions) |*policy| policy.grants = permission_config.?.grants;
        if (result.options.downloads) |*policy| policy.origins = download_config.?.origins;
        const credential_offset = count * @sizeOf(Resource) + origin_count * @sizeOf(OriginGrant);
        const header_offset = credential_offset + credential_count * @sizeOf(RequestCredential);
        const header_storage = @as([*]resources.HeaderGrant, @ptrCast(@alignCast(storage.ptr + header_offset)))[0..header_count];
        var header_index: usize = 0;
        var offset = header_offset + header_count * @sizeOf(resources.HeaderGrant);
        result.options.html = copy(storage, &offset, options.html);
        result.options.user_data_folder = copy(storage, &offset, options.user_data_folder);
        if (options.request_policy_extension) |extension| result.options.request_policy_extension.?.directory = copy(storage, &offset, extension.directory);
        if (options.user_agent) |agent| result.options.user_agent = copy(storage, &offset, agent);
        if (options.remote) |remote| {
            var owned = remote;
            owned.url = copy(storage, &offset, remote.url);
            const origins: []OriginGrant = @as([*]OriginGrant, @ptrCast(storage.ptr))[0..origin_count];
            for (origins, remote.origins) |*destination, source| {
                destination.* = source;
                destination.origin = copy(storage, &offset, source.origin);
                const headers = header_storage[header_index..][0..source.request_headers.len];
                for (headers, source.request_headers) |*target, header| target.* = .{ .name = copy(storage, &offset, header.name), .exact_value = if (header.exact_value) |value| copy(storage, &offset, value) else null };
                destination.request_headers = headers;
                header_index += headers.len;
            }
            owned.origins = origins;
            const credentials = @as([*]RequestCredential, @ptrCast(@alignCast(storage.ptr + credential_offset)))[0..credential_count];
            for (credentials, remote.request_credentials) |*destination, source| destination.* = .{ .origin = copy(storage, &offset, source.origin), .bearer = source.bearer };
            owned.request_credentials = credentials;
            result.options.remote = owned;
            result.url = owned.url;
        }
        if (options.local) |site| {
            var owned = site;
            owned.scheme = copy(storage, &offset, site.scheme);
            owned.host = copy(storage, &offset, site.host);
            owned.start_path = copy(storage, &offset, site.start_path);
            const headers = header_storage[header_index..][0..site.request_headers.len];
            for (headers, site.request_headers) |*target, header| target.* = .{ .name = copy(storage, &offset, header.name), .exact_value = if (header.exact_value) |value| copy(storage, &offset, value) else null };
            owned.request_headers = headers;
            const static_resources: []Resource = @as([*]Resource, @ptrCast(storage.ptr))[0..count];
            for (static_resources, site.resources) |*destination, source| {
                destination.* = .{ .path = copy(storage, &offset, source.path), .mime = copy(storage, &offset, source.mime), .bytes = source.bytes };
            }
            std.mem.sort(Resource, static_resources, {}, struct {
                fn less(_: void, a: Resource, b: Resource) bool {
                    return std.mem.lessThan(u8, a.path, b.path);
                }
            }.less);
            for (static_resources, 0..) |resource, index| if (index != 0 and std.mem.eql(u8, resource.path, static_resources[index - 1].path)) return error.DuplicateResourcePath;
            owned.resources = static_resources;
            result.options.local = owned;
            const prefix = try std.fmt.bufPrint(storage[offset..], "{s}://{s}/", .{ site.scheme, site.host });
            offset += prefix.len;
            result.prefix = prefix;
            const url = try std.fmt.bufPrint(storage[offset..], "{s}://{s}{s}", .{ site.scheme, site.host, site.start_path });
            offset += url.len;
            result.url = url;
        }
        std.debug.assert(offset == content_size);
        return result;
    }
    fn checkProfile(self: *const OwnedConfig) !void {
        if (self.profile_state) |state| try state.lease.check();
    }
    fn admitProfile(self: *OwnedConfig) !void {
        const state = self.profile_state orelse return;
        if (state.admitted) return;
        try state.context.admit();
        state.admitted = true;
    }
    fn prepareRecoveryContext(self: *OwnedConfig) !void {
        const state = self.profile_state orelse return;
        if (state.pending_context != null) return error.RecoveryInProgress;
        var candidate = try state.lease.context();
        errdefer candidate.close() catch unreachable;
        try state.lease.check();
        try candidate.admit();
        state.pending_context = candidate;
        candidate.native = null;
    }
    fn cancelRecoveryContext(self: *OwnedConfig) void {
        const state = self.profile_state orelse return;
        var pending = state.pending_context orelse return;
        state.pending_context = null;
        pending.close() catch unreachable;
    }
    fn publishRecoveryContext(self: *OwnedConfig) void {
        const state = self.profile_state orelse return;
        var pending = state.pending_context orelse return;
        var previous = state.context;
        state.context = pending;
        pending.native = null;
        state.pending_context = null;
        state.admitted = true;
        previous.close() catch unreachable;
    }
    fn deinit(self: OwnedConfig, allocator: std.mem.Allocator) void {
        // Withdraw every linear native entry before any foreign destructor.
        var profile_context: ?native_profiles.Context = null;
        var pending_context: ?native_profiles.Context = null;
        var profile_lease: ?native_profiles.ConfigLease = null;
        if (self.profile_state) |state| {
            profile_context = state.context;
            state.context.native = null;
            pending_context = state.pending_context;
            state.pending_context = null;
            profile_lease = state.lease;
            state.lease.native = null;
        }
        if (pending_context) |*context| context.close() catch unreachable;
        if (profile_context) |*context| context.close() catch unreachable;
        if (profile_lease) |*lease| lease.release() catch unreachable;
        var metadata = self.scheme_config;
        metadata.deinit();
        if (self.permission_config) |owned| {
            var config = owned;
            config.deinit();
        }
        if (self.download_config) |owned| owned.deinit();
        if (self.initializer_config) |owned| owned.destroy();
        if (self.options.remote) |remote| if (remote.request_credentials.len != 0) {
            std.crypto.secureZero(u8, self.storage);
            allocator.rawFree(self.storage, config_alignment, @returnAddress());
            return;
        };
        allocator.free(self.storage);
    }
};

/// Adapter-owned states, async callbacks and controllers/native view objects.
/// These counts do not include the system browser's internal allocations or processes.
pub const ResourceCounts = struct { states: u32, handlers: u32, controllers: u32 };
pub const ActionResourceCounts = struct { budgets: u32, permissions: u32, downloads: u32 };
pub fn actionResourceCounts() ActionResourceCounts {
    if (is_linux) return .{ .budgets = 0, .permissions = 0, .downloads = 0 };
    var counts: ActionResourceCounts = undefined;
    zwv_action_counts(&counts.budgets, &counts.permissions, &counts.downloads);
    return counts;
}
pub fn resourceCounts() ResourceCounts {
    var counts: ResourceCounts = undefined;
    if (is_linux) webkit.zwk_counts(&counts.states, &counts.handlers, &counts.controllers) else zwv_resource_counts(&counts.states, &counts.handlers, &counts.controllers);
    return counts;
}
/// Adapter-owned physical memory streams, independent of late View callbacks.
pub fn customLocalResourceCounts() custom_local.ResourceCounts {
    if (!is_linux) return .{ .budgets = 0, .streams = 0, .body_bytes = 0 };
    var result: custom_local.ResourceCounts = undefined;
    webkit.zwk_local_counts(&result.budgets, &result.streams, &result.body_bytes);
    return result;
}
/// Linux inspectors explicitly shown and not yet closed by disable, detach,
/// recover or close. Windows tool windows belong to the Runtime and report 0.
pub fn devToolsResourceCount() u32 {
    if (!is_linux) return 0;
    var shown: u32 = undefined;
    webkit.zwk_devtools_counts(&shown);
    return shown;
}
pub const ToolResourceCounts = struct { streams: u32, pending: u32 };
pub fn toolResourceCounts() ToolResourceCounts {
    if (is_linux) return .{ .streams = 0, .pending = 0 };
    var value: ToolResourceCounts = undefined;
    zwv_tool_counts(&value.streams, &value.pending);
    return value;
}
pub fn deferredResourceCount() u32 {
    if (is_linux) return webkit.zwk_resources_pending();
    return zwv_resource_pending();
}
pub const FileResourceCounts = struct { streams: u32, controls: u32, budgets: u32 };
pub fn fileResourceCounts() FileResourceCounts {
    var counts: FileResourceCounts = undefined;
    if (is_linux) {
        var candidates: u32 = undefined;
        webkit.zwk_file_counts(&counts.streams, &counts.controls, &counts.budgets, &candidates);
        return counts;
    }
    zwv_file_counts(&counts.streams, &counts.controls, &counts.budgets);
    return counts;
}

pub const View = struct {
    allocator: std.mem.Allocator,
    context: *anyopaque,
    on_event: *const fn (*anyopaque, *View, Event) void,
    window: ?z.Window = null,
    region: ?z.composition.Region = null,
    session: ?*PageSession = null,
    attachment_phase: enum { detached, attaching, attached, detaching } = .detached,
    native: ?*anyopaque = null,
    ready: bool = false,
    last_hresult: i32 = 0,
    last_native_failure: ?NativeFailure = null,
    failed: bool = false,
    recovering: bool = false,
    config: ?OwnedConfig = null,
    pending_config: ?OwnedConfig = null,
    initializer_controller: ?*initializer_owner.Controller = null,
    initializer_domain: ?*anyopaque = null,
    initializer_preparing: bool = false,
    eval_book: evaluations.Book = .{},
    eval_clock: ?std.time.Timer = null,
    eval_timer: ?*anyopaque = null,
    eval_watch: ?z.NativeWaitToken = null,
    eval_accepting: bool = true,
    zoom_override: ?f64 = null,
    agent_override: ?[]u8 = null,
    devtools_override: ?bool = null,
    tool_book: tools.Book = .{},
    tool_accepting: bool = true,
    resource_book: resources.Book = .{},
    permission_book: permissions.Book = .{},
    permission_accepting: bool = true,
    download_book: downloads.Book = .{},
    download_accepting: bool = true,
    action_budget: ?*anyopaque = null,
    resource_accepting: bool = true,
    file_budget: ?*anyopaque = null,
    custom_local_budget: ?*anyopaque = null,
    capture_budget: ?*anyopaque = null,
    find_budget: ?*anyopaque = null,
    find_token: u64 = 0,
    find_listener: ?tools.FindListener = null,
    page_generation: u64 = 0,
    page_active: bool = false,
    loading: bool = false,
    can_go_back: bool = false,
    can_go_forward: bool = false,

    pub fn init(allocator: std.mem.Allocator, context: *anyopaque, on_event: *const fn (*anyopaque, *View, Event) void) View {
        return .{ .allocator = allocator, .context = context, .on_event = on_event };
    }
    /// Last real native failure. Local validation/capacity errors create none.
    /// Strings/results remain borrowed under their ordinary callback contract.
    pub fn nativeFailure(self: *const View) ?NativeFailure {
        if (is_linux) return self.last_native_failure;
        return if (self.last_hresult < 0) .{ .hresult = self.last_hresult } else null;
    }

    const Access = struct {
        app: *z.App,
        window: ?z.Window,
        session: ?*PageSession = null,
        fn nativeHandle(self: Access) ?*anyopaque {
            return if (self.session) |session| session.native_bridge else self.window.?.nativeHandle();
        }
        fn report(self: Access, diagnostic: z.diagnostics.Diagnostic) void {
            var value = diagnostic;
            if (self.window) |window| value.window = window.diagnosticId();
            self.app.report(value);
        }
    };
    fn access(self: *const View) ?Access {
        if (self.session) |session| return .{ .app = session.app orelse return null, .window = self.window, .session = session };
        const window = self.window orelse return null;
        return .{ .app = window.app, .window = window };
    }
    fn unavailableBackend(self: *const View) anyerror {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        return if (self.attachmentClosed() or appStopping(window)) error.Closed else error.UnsupportedCapability;
    }

    const AttachmentScope = union(enum) {
        window: z.CallbackScope,
        region: z.composition.Scope,
        session: PageSession.Scope,
        fn end(self: AttachmentScope) void {
            switch (self) {
                .window => |scope| scope.end(),
                .region => |scope| scope.end(),
                .session => |scope| scope.end(),
            }
        }
    };
    fn beginCallback(self: *View) ?AttachmentScope {
        if (self.session) |session| return .{ .session = session.beginCallback() orelse return null };
        if (self.region) |region| return .{ .region = region.beginCallback() orelse return null };
        const window = self.window orelse return null;
        return .{ .window = window.beginCallback() orelse return null };
    }
    const NativeAttachmentScope = struct {
        attachment: AttachmentScope,
        native: z.NativeAppCallbackScope,
        fn end(self: NativeAttachmentScope) void {
            // Ending the attachment can detach/free View or Session. Only the
            // independently saved App scope is touched after that foreign tail.
            self.attachment.end();
            self.native.end();
        }
    };
    fn beginNativeAttachment(self: *View) ?NativeAttachmentScope {
        const app = (self.access() orelse return null).app;
        // Native ingress must be masked before attachment lookup, including its
        // failure unwind. Ordinary public/Region/Session forwarding stays linear.
        const native = app.beginNativeCallback();
        const attachment = self.beginCallback() orelse {
            native.end();
            return null;
        };
        return .{ .attachment = attachment, .native = native };
    }
    /// A linear lifetime pin, not permission to submit to a changed document.
    /// End exactly once; it may release the View/Session and its callback context.
    pub const PageCallbackScope = struct {
        attachment: AttachmentScope,
        owner: *z.App,
        pub fn app(self: PageCallbackScope) *z.App {
            return self.owner;
        }
        pub fn end(self: PageCallbackScope) void {
            self.attachment.end();
        }
    };
    /// Keeps the current attachment or parked Session stable across caller
    /// allocation/transport callbacks. Revalidate PageId after each such call.
    /// Loading is allowed for lifetime protection; postFor still rejects it.
    pub fn beginPageCallback(self: *View, id: PageId) !PageCallbackScope {
        const access_value = self.access() orelse return error.Closed;
        access_value.app.assertOwner();
        if (self.attachmentClosed() or appStopping(access_value)) return error.Closed;
        if (id.view != self or id.generation != self.page_generation or !self.page_active or self.recovering) return error.StalePage;
        return .{ .attachment = self.beginCallback() orelse return error.Closed, .owner = access_value.app };
    }
    fn attachmentClosed(self: *const View) bool {
        if (self.session) |session| return !session.accepts();
        if (self.attachment_phase == .detaching) return true;
        const window = self.window orelse return true;
        if (window.isClosed()) return true;
        if (self.region) |region| _ = region.snapshot() catch return true;
        return false;
    }

    /// Attach one native rectangular viewport without taking Window.Content.
    /// Removing the Region closes this page; it does not retain a detached DOM.
    /// The View and composition Owner stay stable through participant detach.
    pub fn attachRegion(self: *View, region: z.composition.Region, options: Options) !void {
        if (self.session != null) return error.ManagedSession;
        if (self.window != null or self.attachment_phase != .detached) return error.AlreadyAttached;
        const snapshot = try region.snapshot();
        snapshot.window.app.assertOwner();
        if (appStopping(snapshot.window)) return error.Closed;
        if (snapshot.kind != .native) return error.NativeRegionRequired;
        const scope = region.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.attachment_phase = .attaching;
        errdefer self.attachment_phase = .detached;
        self.config = try OwnedConfig.initForApp(self.allocator, options, snapshot.window.app);
        errdefer {
            self.config.?.deinit(self.allocator);
            self.config = null;
        }
        try region.attach(.{ .context = self, .attach = regionAttach, .update = regionUpdate, .detach = regionDetach, .event = regionEvent });
        self.attachment_phase = .attached;
    }
    fn regionAttach(ptr: *anyopaque, region: z.composition.Region) !void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const snapshot = try region.snapshot();
        self.region = region;
        self.window = snapshot.window;
        errdefer {
            self.discardNativeAttachment();
            self.region = null;
            self.window = null;
        }
        try self.startNative(self.access().?);
        // Native preparation releases foreign scratch before returning. Its
        // final allocator callback may have revoked this provisional region.
        if (self.attachmentClosed() or appStopping(snapshot.window)) return error.Closed;
        try self.config.?.checkProfile();
    }
    fn regionUpdate(ptr: *anyopaque, region: z.composition.Region, viewport: z.composition.Viewport) !void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const snapshot = try region.snapshot();
        try self.applyViewport(viewport, snapshot.size.scale);
    }
    fn regionDetach(ptr: *anyopaque, _: z.composition.Region) void {
        detach(ptr);
    }
    fn regionEvent(ptr: *anyopaque, region: z.composition.Region, ev: z.Event) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        if (ev == .window_position) return self.parentPosition();
        if (ev != .resize) return;
        const snapshot = region.snapshot() catch return;
        self.applyViewport(snapshot.viewport, snapshot.size.scale) catch |err| {
            snapshot.window.report(.{ .domain = if (err == error.ViewportFailed) .hresult else .webview, .operation = .webview_geometry, .err = err, .code = if (err == error.ViewportFailed) @bitCast(self.last_hresult) else null });
        };
    }
    fn parentPosition(self: *View) void {
        if (is_linux) return;
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window)) return;
        const scope = self.beginCallback() orelse return;
        defer scope.end();
        const native = self.native orelse return;
        self.last_hresult = zwv_parent_position(native);
        if (self.last_hresult < 0 and !self.attachmentClosed()) window.report(.{ .domain = .hresult, .operation = .webview_geometry, .err = error.ParentPositionFailed, .code = @bitCast(self.last_hresult) });
    }
    fn applyViewport(self: *View, viewport: z.composition.Viewport, scale: f32) !void {
        if (self.attachmentClosed()) return error.Closed;
        const native = self.native orelse return error.Closed;
        const b = viewport.bounds;
        const edges = try viewportPixels(b, scale);
        if (is_linux) {
            try webkit.check(webkit.zwk_viewport(native, edges[0], edges[1], edges[2], edges[3], @intFromBool(viewport.visible and b.width > 0 and b.height > 0)));
            if (self.attachmentClosed()) return error.Closed;
            return;
        }
        self.last_hresult = zwv_viewport(native, edges[0], edges[1], edges[2], edges[3], viewport.visible and b.width > 0 and b.height > 0);
        if (self.last_hresult < 0) return error.ViewportFailed;
        if (self.attachmentClosed()) return error.Closed;
    }
    fn viewportPixels(b: z.Rect, scale: f32) ![4]i32 {
        if (!std.math.isFinite(scale) or scale <= 0 or b.width < 0 or b.height < 0) return error.InvalidViewport;
        var edges: [4]i32 = undefined;
        for ([_]f32{ b.x, b.y, b.x + b.width, b.y + b.height }, 0..) |edge, index| {
            const scaled = @round(@as(f64, edge) * @as(f64, scale));
            if (!std.math.isFinite(scaled) or scaled < std.math.minInt(i32) or scaled > std.math.maxInt(i32)) return error.InvalidViewport;
            edges[index] = @intFromFloat(scaled);
        }
        if (@as(i64, edges[2]) - edges[0] > std.math.maxInt(i32) or @as(i64, edges[3]) - edges[1] > std.math.maxInt(i32)) return error.InvalidViewport;
        return edges;
    }

    /// Address must remain stable through detach. No nested message pumping.
    pub fn attach(self: *View, window: z.Window, options: Options) !void {
        if (self.session != null) return error.ManagedSession;
        if (self.window != null or self.attachment_phase != .detached) return error.AlreadyAttached;
        window.app.assertOwner();
        if (appStopping(window)) return error.Closed;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.attachment_phase = .attaching;
        errdefer self.attachment_phase = .detached;
        self.attachInner(window, options) catch |err| {
            window.report(.{ .domain = if (err == error.WebViewCreationFailed) .hresult else .webview, .operation = .webview_create, .err = err, .code = if (err == error.WebViewCreationFailed) @bitCast(self.last_hresult) else null });
            return err;
        };
        self.attachment_phase = .attached;
    }
    fn attachInner(self: *View, window: z.Window, options: Options) !void {
        if (self.window != null) return error.AlreadyAttached;
        self.config = try OwnedConfig.initForApp(self.allocator, options, window.app);
        errdefer {
            self.config.?.deinit(self.allocator);
            self.config = null;
        }
        try window.setContent(.{ .context = self, .event = event, .detach = detach });
        errdefer window.cancelContent(self);
        self.window = window;
        errdefer self.window = null;
        errdefer self.discardNativeAttachment();
        try self.startNative(self.access().?);
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        try self.config.?.checkProfile();
    }

    fn discardNativeAttachment(self: *View) void {
        const find_budget = self.find_budget;
        self.find_budget = null;
        if (is_linux) if (find_budget) |value| webkit.zwk_find_budget_close(value);
        const capture_budget = self.capture_budget;
        self.capture_budget = null;
        if (is_linux) if (capture_budget) |value| webkit.zwk_capture_budget_close(value);
        const initializer_controller = self.initializer_controller;
        self.initializer_controller = null;
        const initializer_domain = self.initializer_domain;
        self.initializer_domain = null;
        const native = self.native;
        self.native = null;
        if (native) |value| nativeClose(value);
        if (is_linux) if (find_budget) |value| webkit.zwk_find_budget_release(value);
        if (is_linux) if (capture_budget) |value| webkit.zwk_capture_budget_release(value);
        const file_budget = self.file_budget;
        self.file_budget = null;
        if (file_budget) |value| {
            if (is_linux) webkit.zwk_file_budget_release(value) else zwv_file_budget_release(value);
        }
        const local_budget = self.custom_local_budget;
        self.custom_local_budget = null;
        if (is_linux) if (local_budget) |value| webkit.zwk_local_budget_release(value);
        const action_budget = self.action_budget;
        self.action_budget = null;
        if (!is_linux) if (action_budget) |value| zwv_action_budget_release(value);
        if (initializer_controller) |controller| controller.release();
        if (initializer_domain) |domain| initializer_owner.releaseDomain(domain);
    }

    fn startNative(self: *View, window: Access) !void {
        if (self.config.?.initializer_config) |source| self.pinInitializerDomain(source.domain);
        try self.config.?.admitProfile();
        if (is_linux) return self.startWebKit(window);
        const config = self.config.?;
        const html = if (config.url == null) try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, config.options.html) else null;
        defer if (html) |value| self.allocator.free(value);
        const profile = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, config.options.user_data_folder);
        defer self.allocator.free(profile);
        const url = if (config.url) |value| try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, value) else null;
        defer if (url) |value| self.allocator.free(value);
        const prefix = if (config.prefix) |value| try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, value) else null;
        defer if (prefix) |value| self.allocator.free(value);
        var policy: u32 = 0;
        inline for (std.meta.fields(Policy), 0..) |field, index| {
            if (@field(config.options.policy, field.name) == .notify) policy |= @as(u32, 1) << @intCast(index);
        }
        var scratch: RemoteScratch = undefined;
        const remote = if (config.options.remote) |value| try scratch.prepare(value) else null;
        const agent = if (self.agent_override orelse config.options.user_agent) |value| try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, value) else null;
        defer if (agent) |value| self.allocator.free(value);
        if (self.session) |session| try SessionHooks.ensureHost(session);
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (self.native != null) return error.RecoveryInProgress;
        var tool_flags: u32 = 0;
        inline for (std.meta.fields(tools.Policy), 0..) |field, i| if (@field(config.options.tools, field.name)) {
            tool_flags |= @as(u32, 1) << @intCast(i);
        };
        const limits = config.options.tool_limits;
        var scheme_scratch: SchemeScratch = undefined;
        scheme_scratch.prepare(config.options.custom_schemes);
        const previous_budget = self.action_budget;
        errdefer if (previous_budget == null) {
            if (self.action_budget) |budget| zwv_action_budget_release(budget);
            self.action_budget = null;
        };
        const permission_limit: u32 = if (config.options.permissions) |permission_policy| permission_policy.limits.max_pending else 0;
        const download_limit: u32 = if (config.options.downloads) |download_policy| download_policy.limits.max_active else 0;
        if ((permission_limit != 0 or download_limit != 0) and self.action_budget == null) self.action_budget = zwv_action_budget_create(permission_limit, download_limit) orelse return error.OutOfMemory;
        if (self.action_budget) |budget| zwv_action_budget_limit(budget, permission_limit, download_limit);
        var permission_scratch: PermissionScratch = undefined;
        var download_scratch: DownloadScratch = undefined;
        var actions: ?NativeActions = if (permission_limit != 0 or download_limit != 0) .{ .budget = self.action_budget.? } else null;
        if (config.options.permissions) |permission_policy| actions = permission_scratch.prepare(permission_policy, self.action_budget.?);
        if (config.options.downloads) |download_policy| download_scratch.prepare(download_policy, &actions.?);
        const initializer_input = if (config.initializer_config) |source| source.input() else null;
        const settings: NativeSettings = .{ .zoom = self.zoom_override orelse config.options.zoom, .user_agent = if (agent) |value| value.ptr else null, .devtools = self.devtools_override orelse config.options.devtools_enabled, .tool_flags = tool_flags, .tool_limit = limits.max_pending, .max_cookies = limits.max_cookies, .max_cookie_bytes = limits.max_cookie_bytes, .max_capture_bytes = limits.max_capture_bytes, .schemes = if (config.options.custom_schemes.len == 0) null else &scheme_scratch.items, .scheme_count = @intCast(config.options.custom_schemes.len), .local_ipc = if (config.options.local) |site| std.mem.eql(u8, site.scheme, "https") or site.scheme_ipc else true, .actions = if (actions) |*value| value else null, .initializers = if (initializer_input) |*value| value else null, .owned_context = if (config.profile_state) |state| try state.context.windowsContext() else null };
        self.native = zwv_create(window.nativeHandle(), if (html) |value| value.ptr else std.unicode.utf8ToUtf16LeStringLiteral(""), profile.ptr, if (url) |value| value.ptr else null, if (prefix) |value| value.ptr else null, if (remote) |*value| value else null, &settings, policy, config.options.max_cached_permissions, config.options.scripts.max_pending, config.options.allow_local_navigation, config.options.page_listener != null, notify, pageNotify, scriptNotify, toolNotify, resource, self, &self.last_hresult) orelse return error.WebViewCreationFailed;
        errdefer {
            nativeClose(self.native.?);
            self.native = null;
        }
        if (self.session) |session| {
            try SessionHooks.pageViewport(session, session.last_size, SessionHooks.visible(session));
        } else if (self.region) |region| {
            const snapshot = try region.snapshot();
            try self.applyViewport(snapshot.viewport, snapshot.size.scale);
        }
        self.eval_accepting = true;
        self.tool_accepting = true;
        self.resource_accepting = true;
        self.permission_accepting = true;
        self.download_accepting = true;
    }
    fn startWebKit(self: *View, window: Access) !void {
        if (@import("builtin").is_test) return error.UnsupportedCapability;
        const options = self.config.?.options;
        const html = try self.allocator.dupeZ(u8, options.html);
        defer self.allocator.free(html);
        const agent = if (self.agent_override orelse options.user_agent) |value| try self.allocator.dupeZ(u8, value) else null;
        defer if (agent) |value| self.allocator.free(value);
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        var new_capture_budget = false;
        errdefer if (new_capture_budget) {
            const budget = self.capture_budget;
            self.capture_budget = null;
            if (budget) |value| {
                webkit.zwk_capture_budget_close(value);
                webkit.zwk_capture_budget_release(value);
            }
        };
        // Capture and whole-data clear share one physical owner and quota.
        if (options.tools.capture or options.tools.clear_entire_profile) {
            const limits = options.tool_limits;
            const budget = self.capture_budget orelse blk: {
                const value = webkit.zwk_capture_budget_new(limits.max_pending, limits.max_capture_bytes, webkitCaptureNotify) orelse return error.OutOfMemory;
                self.capture_budget = value;
                new_capture_budget = true;
                break :blk value;
            };
            try webkit.check(webkit.zwk_capture_budget_limit(budget, limits.max_pending, limits.max_capture_bytes));
        }
        var local: ?webkit.LocalScratch = null;
        defer if (local) |*scratch| scratch.deinit(self.allocator);
        var remote: ?webkit_remote.Scratch = null;
        defer if (remote) |*scratch| scratch.deinit();
        if (options.remote) |page| remote = try webkit_remote.Scratch.init(self.allocator, page, options.request_policy_extension.?);
        var new_local_budget = false;
        errdefer if (new_local_budget) {
            const budget = self.custom_local_budget;
            self.custom_local_budget = null;
            if (budget) |value| webkit.zwk_local_budget_release(value);
        };
        if (options.local) |site| {
            const limits = options.custom_local_limits;
            const budget = self.custom_local_budget orelse blk: {
                const candidate = webkit.zwk_local_budget_new(limits.max_live_responses, @intCast(limits.max_live_bytes)) orelse return error.OutOfMemory;
                self.custom_local_budget = candidate;
                new_local_budget = true;
                break :blk candidate;
            };
            webkit.zwk_local_budget_limit(budget, limits.max_live_responses, @intCast(limits.max_live_bytes));
            local = try webkit.LocalScratch.init(self.allocator, site, @intCast(@min(options.max_resource_bytes, options.resource_limits.max_response_bytes)), budget, options.custom_schemes[0]);
        }
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        const callback_scope = if (self.session == null) (window.window.?.beginCallback() orelse return error.Closed) else null;
        defer if (callback_scope) |scope| scope.end();
        var flags: u32 = 0;
        inline for (std.meta.fields(Policy), 0..) |field, i| if (@field(options.policy, field.name) == .notify) {
            flags |= @as(u32, 1) << @intCast(i);
        };
        const initializer_input = if (self.config.?.initializer_config) |source| source.input() else null;
        const native_options: webkit.Options = .{ .html = html, .user_agent = if (agent) |value| value else null, .zoom = self.zoom_override orelse options.zoom, .max_pending = options.scripts.max_pending, .max_result_bytes = options.scripts.max_result_bytes, .policy_flags = flags, .local = if (local) |*scratch| &scratch.local else null, .remote = if (remote) |*scratch| &scratch.input else null, .region = @intFromBool(self.session == null and self.region != null), .profile_context = if (self.config.?.profile_state) |state| state.context.native else null, .initializers = if (initializer_input) |*value| value else null, .developer_tools = @intFromBool(self.devtools_override orelse options.devtools_enabled) };
        var candidate: ?*anyopaque = null;
        if (self.session) |session| {
            try webkit.check(webkit.zwk_session_create(&native_options, session.last_size.width, session.last_size.height, webkitNotify, pageNotify, webkitScriptNotify, webkitTimeout, self, &candidate));
        } else {
            const native_window = callback_scope.?.record.native.native orelse return error.Closed;
            try webkit.check(webkit.zwk_create(native_window, &native_options, webkitNotify, pageNotify, webkitScriptNotify, webkitTimeout, self, &candidate));
        }
        if (options.tools.capture or options.tools.clear_entire_profile) {
            webkit.check(webkit.zwk_capture_enable(candidate.?, self.capture_budget.?)) catch |err| {
                webkit.zwk_close(candidate.?);
                return err;
            };
        }
        if (options.local) |site| if (site.on_resource != null) {
            webkit.check(webkit.zwk_resources_enable(candidate.?, webkitResource, @intFromBool(site.dynamic_document), options.resource_limits.max_pending)) catch |err| {
                webkit.zwk_close(candidate.?);
                return err;
            };
        };
        if (self.attachmentClosed() or appStopping(window)) {
            webkit.zwk_close(candidate.?);
            return error.Closed;
        }
        self.native = candidate;
        errdefer {
            if (self.native) |native| webkit.zwk_close(native);
            self.native = null;
        }
        if (self.session) |session| {
            if (session.region) |region| {
                const value = try region.snapshot();
                try SessionHooks.update(session, region, value.viewport, value);
            }
        } else if (self.region) |region| {
            const snapshot = try region.snapshot();
            try self.applyViewport(snapshot.viewport, snapshot.size.scale);
        }
        self.eval_accepting = true;
        self.tool_accepting = true;
        self.resource_accepting = if (options.local) |site| site.on_resource != null else false;
        self.permission_accepting = false;
        self.download_accepting = false;
    }
    fn webkitNotify(ptr: *anyopaque, kind: c_int, value: ?[*:0]const u16, code: i32, failure: ?*const webkit.Failure) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        if (failure) |native| self.last_native_failure = .{ .glib = native.* };
        notify(ptr, kind, value, code);
    }
    fn webkitTimeout(ptr: *anyopaque) callconv(.c) void {
        evalTimeout(ptr);
    }

    /// Schedule one explicit recovery after native callbacks unwind. Full/Closed
    /// leaves ownership with the caller and can be retried. No worker is started.
    pub fn recover(self: *View) !void {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed()) return error.Closed;
        if (self.attachment_phase != .attached) return error.NotReady;
        if (window.app.phase == .stopping or window.app.phase == .stopped) return error.Closed;
        if (self.recovering) return error.RecoveryInProgress;
        if (self.initializer_preparing) return error.Busy;
        if (self.initializer_controller) |controller| if (controller.book.busy()) return error.Busy;
        if (!self.failed) return error.NotFailed;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        try self.config.?.prepareRecoveryContext();
        errdefer self.config.?.cancelRecoveryContext();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        try self.queueRestart(window);
        if (self.initializer_controller) |controller| try controller.book.recover();
    }

    /// Replace a document after current callbacks unwind. Validation/allocation
    /// and Full/Closed failures preserve the current document. Success borrows
    /// new resource bodies until a later resources_released event or detach.
    /// On close before dispatch, detach releases both old and pending configs.
    pub fn reload(self: *View, options: Options) !void {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or window.app.phase == .stopping or window.app.phase == .stopped) return error.Closed;
        if (self.attachment_phase != .attached) return error.NotReady;
        if (self.recovering or self.pending_config != null) return error.RecoveryInProgress;
        if (self.initializer_preparing) return error.Busy;
        if (self.initializer_controller) |controller| if (controller.book.busy()) return error.Busy;
        if (self.initializersUnavailable()) return error.InitializerUnavailable;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const domain = self.initializerDomain();
        var candidate = try OwnedConfig.initForAppDomain(self.allocator, options, window.app, domain);
        errdefer candidate.deinit(self.allocator);
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (self.recovering or self.pending_config != null) return error.RecoveryInProgress;
        if (self.initializer_controller) |controller| if (controller.book.busy()) return error.Busy;
        if (self.initializersUnavailable()) return error.InitializerUnavailable;
        if (self.initializerDomain() != domain) return error.InitializerStateChanged;
        if (!schemes.equal(self.config.?.options.custom_schemes, candidate.options.custom_schemes)) return error.SchemeEnvironmentChange;
        try candidate.checkProfile();
        try candidate.admitProfile();
        try self.queueRestart(window);
        self.pending_config = candidate;
    }

    fn initializerDomain(self: *const View) ?*anyopaque {
        if (self.initializer_domain) |domain| return domain;
        if (self.initializer_controller) |controller| return controller.domain;
        if (self.config) |config| if (config.initializer_config) |source| return source.domain;
        return null;
    }
    fn pinInitializerDomain(self: *View, domain: *anyopaque) void {
        if (self.initializer_domain) |current| {
            std.debug.assert(current == domain);
            return;
        }
        initializer_owner.retainDomain(domain);
        self.initializer_domain = domain;
    }
    fn initializersUnavailable(self: *const View) bool {
        if (self.initializer_controller) |controller| if (controller.book.unavailable) return true;
        return self.initializer_domain != null and (if (self.native) |native| (if (is_linux) webkit.zwk_initializers_blocked(native) else zwv_initializers_blocked(native)) else false);
    }
    fn initializerNavigationAllowed(self: *const View) bool {
        return !self.initializer_preparing and (if (self.initializer_controller) |controller| controller.book.allowsNavigation() else true);
    }

    /// Accept one replacement of future document-start initializers. It never
    /// evaluates the current document, grants an origin, or creates a PageId.
    /// Synchronous failure does not take the completion context. Acceptance may
    /// complete synchronously; the callback can close/reload this View.
    pub fn replaceDocumentInitializers(self: *View, entries: []const DocumentInitializer, completion: InitializerCompletion) !InitializerReplacement {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (self.initializer_preparing) return error.Busy;
        if (!self.ready or self.recovering or self.pending_config != null) return error.NotReady;
        if (self.loading) return error.Busy;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (self.initializer_controller == null) {
            self.initializer_preparing = true;
            errdefer self.initializer_preparing = false;
            const controller = try initializer_owner.Controller.create(self.allocator, self.config.?.options.initializer_limits, self.initializerDomain(), 0);
            if (self.attachmentClosed() or appStopping(window)) {
                controller.release();
                return error.Closed;
            }
            self.pinInitializerDomain(controller.domain);
            self.initializer_controller = controller;
            self.initializer_preparing = false;
        }
        const controller = self.initializer_controller.?;
        controller.retain();
        defer controller.release();
        const token = try controller.book.reserve(self.loading);
        errdefer std.debug.assert(controller.book.abort(token));
        const candidate = try initializer_owner.Config.create(self.allocator, entries, self.config.?.options.initializer_limits, controller.domain);
        errdefer if (candidate) |value| value.destroy();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (self.recovering or self.pending_config != null) return error.RecoveryInProgress;
        const native = self.native orelse return error.NotReady;
        controller.candidate = candidate;
        errdefer controller.candidate = null;
        const input = controller.input();
        if (is_linux) {
            const result = webkit.zwk_initializers_prepare(native, &input, token, initializerNotify);
            if (result == 7) return error.Busy;
            try webkit.check(result);
        } else {
            self.last_hresult = zwv_initializers_prepare(native, &input, token, initializerNotify);
            if (self.last_hresult == @as(i32, @bitCast(@as(u32, 0x8000000a)))) return error.Busy;
            if (self.last_hresult < 0) return error.InitializerPreparationFailed;
        }
        errdefer if (is_linux) webkit.zwk_initializers_abandon(native) else zwv_initializers_abandon(native);
        try controller.book.accept(token, completion);
        const replacement: InitializerReplacement = .{ .view = self, .token = token };
        // No View access after activation: native calls may complete synchronously and
        // the accepted completion may close/reload the attachment.
        if (is_linux) webkit.zwk_initializers_activate(native) else zwv_initializers_activate(native);
        return replacement;
    }
    fn cancelDocumentInitializers(self: *View, token: u64) !bool {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const controller = self.initializer_controller orelse return false;
        const pending = controller.book.pending orelse return false;
        if (pending.token != token or !pending.accepted or pending.cancelled) return false;
        const native = self.native orelse return false;
        if (!(if (is_linux) webkit.zwk_initializers_try_cancel(native, token) else zwv_initializers_try_cancel(native, token))) return false;
        const delivery = controller.book.cancel(token).?;
        delivery.invoke();
        return true;
    }
    fn initializerNotify(ptr: *anyopaque, token: u64, kind: u32, hr: i32) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        const controller = self.initializer_controller orelse return;
        controller.retain();
        const outcome: initializer_owner.transaction.Retirement = switch (kind) {
            0 => .installed,
            1 => .discarded,
            2 => .{ .failed = hr },
            else => .{ .removal_uncertain = hr },
        };
        const retired = controller.book.retire(token, outcome) catch {
            controller.release();
            return;
        };
        const candidate = controller.candidate;
        controller.candidate = null;
        var previous: ?*initializer_owner.Config = null;
        if (retired.publish) {
            previous = self.config.?.initializer_config;
            self.config.?.initializer_config = candidate;
            self.config.?.options.document_initializers = if (candidate) |value| value.owned.entries else &.{};
        }
        var delivery = retired.delivery;
        if (appStopping(window) or self.attachmentClosed()) {
            _ = controller.book.detach();
            if (delivery) |*value| value.result = .detached;
        } else if (retired.unavailable) {
            self.last_hresult = hr;
            self.ready = false;
            self.failed = true;
        }
        // All View state is published/withdrawn before foreign free. Each
        // owner pins the C accounting domain independently through its free.
        if (previous) |value| value.destroy();
        if (!retired.publish) if (candidate) |value| value.destroy();
        controller.release();
        if (delivery) |value| value.invoke();
    }

    fn queueRestart(self: *View, window: Access) !void {
        const native = self.native orelse blk: {
            // A new anchor can itself fail to allocate; retain the owned config
            // and return OutOfMemory so the caller can retry or close the window.
            const anchor = (if (is_linux) webkit.zwk_recovery_anchor(webkitNotify, self) else zwv_recovery_anchor(notify, self)) orelse return error.OutOfMemory;
            self.native = anchor;
            break :blk anchor;
        };
        if (is_linux) {
            try webkit.check(webkit.zwk_recovery_begin(native));
        } else {
            self.last_hresult = zwv_recovery_begin(native);
            if (self.last_hresult < 0) return error.RecoveryFailed;
        }
        window.app.post(.{ .context = native, .call = recoveryDispatch }) catch |err| {
            if (is_linux) webkit.zwk_recovery_cancel(native) else zwv_recovery_cancel(native);
            return err;
        };
        if (is_linux) webkit.zwk_resource_cancel_all(native) else zwv_file_cancel_all(native);
        self.ready = false;
        self.page_active = false;
        self.loading = false;
        self.can_go_back = false;
        self.can_go_forward = false;
        self.recovering = true;
        self.finishRequests(.page_changed, .page_changed, .page_changed, null, null, false);
    }
    fn recoveryDispatch(native: *anyopaque) void {
        if (is_linux) webkit.zwk_recovery_dispatch(native) else zwv_recovery_dispatch(native);
    }

    /// Success transfers completion responsibility exactly once. Failure does
    /// not take context ownership. JSON is borrowed until the callback returns.
    pub fn evaluateJS(self: *View, script: []const u8, options: EvaluationOptions, completion: ScriptCompletion) !Evaluation {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (!self.ready or self.recovering or !self.page_active) return error.NotReady;
        if (self.loading) return error.PageLoading;
        if (!self.eval_accepting) return error.EvaluationUnavailable;
        const limits = self.config.?.options.scripts;
        const page = self.page_generation;
        if (script.len > limits.max_script_bytes) return error.ScriptTooLarge;
        if (std.mem.indexOfScalar(u8, script, 0) != null) return error.EmbeddedNul;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const wide = if (is_linux) try self.allocator.dupeZ(u8, script) else try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, script);
        defer self.allocator.free(wide);
        _ = try self.propertyWindow();
        if (!self.page_active or self.page_generation != page) return error.StalePage;
        if (self.loading) return error.PageLoading;
        if (!self.eval_accepting) return error.EvaluationUnavailable;
        var deadline: ?u64 = null;
        if (options.timeout_ms) |milliseconds| {
            if (milliseconds == 0 or milliseconds > 600_000) return error.InvalidTimeout;
            if (self.eval_clock == null) self.eval_clock = try std.time.Timer.start();
            deadline = try std.math.add(u64, self.eval_clock.?.read(), @as(u64, milliseconds) * std.time.ns_per_ms);
        }
        const token = try self.eval_book.reserve(page, deadline, completion, limits.max_pending);
        self.syncEvalTimer() catch |err| {
            _ = self.eval_book.take(token);
            self.syncEvalTimer() catch self.failEvalTimer();
            return err;
        };
        const submitted = if (is_linux) webkit.zwk_evaluate(self.native.?, wide.ptr, token) else zwv_evaluate(self.native.?, wide.ptr, token);
        if (!is_linux) self.last_hresult = submitted;
        if ((is_linux and submitted != 0) or (!is_linux and submitted < 0)) {
            const hr = self.last_hresult;
            _ = self.eval_book.take(token);
            self.syncEvalTimer() catch self.failEvalTimer();
            if (is_linux) {
                webkit.check(submitted) catch |err| return err;
                unreachable;
            }
            return switch (@as(u32, @bitCast(hr))) {
                0x8000000a => error.Full,
                0x8007000e => error.OutOfMemory,
                else => error.ScriptSubmitFailed,
            };
        }
        return .{ .view = self, .token = token };
    }
    fn cancelEvaluation(self: *View, token: u64) !bool {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const slot = self.eval_book.take(token) orelse return false;
        if (self.native) |native| nativeCancelScript(native, token);
        self.syncEvalTimer() catch self.failEvalTimer();
        slot.completion.complete(slot.completion.context, if (self.attachmentClosed() or appStopping(window)) .detached else .cancelled);
        return true;
    }
    fn syncEvalTimer(self: *View) !void {
        const window = self.access() orelse return;
        if (is_linux) {
            if (self.native) |native| webkit.zwk_deadline_cancel(native);
        }
        if (self.eval_watch) |watch| _ = window.app.unwatchNative(watch);
        self.eval_watch = null;
        if (self.attachmentClosed() or appStopping(window)) return;
        var earliest_at: ?u64 = null;
        for ([_]?u64{ self.eval_book.earliest(), self.tool_book.earliest(), self.resource_book.earliest(), self.permission_book.earliest(), self.download_book.earliest() }) |candidate| if (candidate) |at| {
            earliest_at = if (earliest_at) |other| @min(at, other) else at;
        };
        const deadline = earliest_at orelse return;
        if (is_linux) {
            const now = self.eval_clock.?.read();
            try webkit.check(webkit.zwk_deadline_arm(self.native orelse return error.Closed, if (deadline > now) deadline - now else 1));
            return;
        }
        if (self.eval_timer == null) {
            self.last_hresult = zwv_eval_timer_create(&self.eval_timer);
            if (self.last_hresult < 0) return error.EvaluationTimerFailed;
        }
        const now = self.eval_clock.?.read();
        self.last_hresult = zwv_eval_timer_arm(self.eval_timer.?, if (deadline > now) deadline - now else 1);
        if (self.last_hresult < 0) return error.EvaluationTimerFailed;
        self.eval_watch = try window.app.watchNative(self.eval_timer.?, .{ .context = self, .call = evalTimeout });
    }
    fn failEvalTimer(self: *View) void {
        if (self.attachmentClosed()) return;
        if (self.access()) |window| if (appStopping(window)) return;
        self.eval_accepting = false;
        self.tool_accepting = false;
        self.resource_accepting = false;
        self.permission_accepting = false;
        self.download_accepting = false;
        self.finishRequests(.timer_failed, .timer_failed, .timer_failed, null, null, false);
    }
    fn finishRequests(self: *View, script_result: ScriptResult, tool_result: tools.Result, resource_result: resources.Result, tool_scope: ?tools.Scope, expired_at: ?u64, rearm: bool) void {
        var script_tokens: [evaluations.capacity]u64 = undefined;
        var script_slots: [evaluations.capacity]evaluations.Slot = undefined;
        const script_ids = self.eval_book.tokens(&script_tokens, expired_at);
        for (script_ids, 0..) |token, i| {
            script_slots[i] = self.eval_book.take(token).?;
        }
        var tool_tokens: [tools.capacity]u64 = undefined;
        var tool_slots: [tools.capacity]tools.Slot = undefined;
        const tool_ids = self.tool_book.tokens(&tool_tokens, tool_scope, expired_at);
        for (tool_ids, 0..) |token, i| {
            tool_slots[i] = self.tool_book.take(token).?;
        }
        var resource_tokens: [resources.capacity]u64 = undefined;
        var resource_slots: [resources.capacity]resources.Slot = undefined;
        const resource_ids = self.resource_book.tokens(&resource_tokens, expired_at);
        for (resource_ids, 0..) |token, i| resource_slots[i] = self.resource_book.take(token).?;
        var permission_tokens: [permissions.capacity]u64 = undefined;
        var permission_slots: [permissions.capacity]permissions.Slot = undefined;
        const permission_ids = self.permission_book.tokens(&permission_tokens, null, expired_at);
        for (permission_ids, 0..) |token, i| permission_slots[i] = self.permission_book.take(token).?;
        var download_tokens: [downloads.capacity]u64 = undefined;
        var download_slots: [downloads.capacity]downloads.Slot = undefined;
        const download_ids = if (tool_scope == .page) download_tokens[0..0] else self.download_book.tokens(&download_tokens, expired_at);
        for (download_ids, 0..) |token, i| download_slots[i] = self.download_book.take(token).?;
        for (script_ids) |token| if (self.native) |native| nativeCancelScript(native, token);
        if (is_linux) {
            for (resource_ids) |token| if (self.native) |native| webkit.zwk_resource_cancel(native, token);
            for (tool_slots[0..tool_ids.len]) |slot| {
                if (slot.kind == .find and slot.token == self.find_token) {
                    self.clearFind();
                } else if (self.native) |native| {
                    if (slot.kind == .find) webkit.zwk_find_cancel(native, slot.token) else webkit.zwk_capture_cancel(native, slot.token);
                }
            }
        }
        if (!is_linux) {
            for (tool_ids) |token| {
                if (self.native) |native| zwv_tool_cancel(native, token);
                if (token == self.find_token) self.clearFind();
            }
            for (resource_ids) |token| if (self.native) |native| zwv_cancel_resource(native, token);
            for (permission_ids) |token| if (self.native) |native| self.permissionNativeResult(zwv_permission_cancel(native, token));
            for (download_ids) |token| if (self.native) |native| self.downloadNativeResult(zwv_download_cancel(native, token));
        }
        if (expired_at == null and (tool_scope == null or tool_scope.? == .page)) self.clearFind();
        if (self.eval_watch) |watch| if (self.access()) |window| {
            _ = window.app.unwatchNative(watch);
        };
        self.eval_watch = null;
        if (is_linux) if (self.native) |native| webkit.zwk_deadline_cancel(native);
        if (rearm) self.syncEvalTimer() catch self.failEvalTimer();
        for (script_slots[0..script_ids.len]) |slot| slot.completion.complete(slot.completion.context, script_result);
        for (tool_slots[0..tool_ids.len]) |slot| self.completeToolSlot(slot, tool_result);
        for (resource_slots[0..resource_ids.len]) |slot| if (slot.completion) |completion| completion.complete(completion.context, resource_result);
        const permission_result: permissions.Result = switch (script_result) {
            .cancelled => .cancelled,
            .timed_out => .timed_out,
            .page_changed => .page_changed,
            .detached => .detached,
            .unavailable => .unavailable,
            .timer_failed => .timer_failed,
            else => unreachable,
        };
        for (permission_slots[0..permission_ids.len]) |slot| if (slot.completion) |completion| completion.complete(completion.context, permission_result);
        const download_result: downloads.Result = switch (script_result) {
            .cancelled => .cancelled,
            .timed_out => .timed_out,
            .page_changed, .unavailable => .unavailable,
            .detached => .detached,
            .timer_failed => .timer_failed,
            else => unreachable,
        };
        for (download_slots[0..download_ids.len]) |slot| completeDownloadSlot(slot, download_result);
    }
    fn evalTimeout(ptr: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        self.eval_watch = null;
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window)) return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        self.finishRequests(.timed_out, .timed_out, .timed_out, null, self.eval_clock.?.read(), true);
    }

    fn completeToolSlot(self: *View, slot: tools.Slot, result: tools.Result) void {
        defer if (slot.owned) |owned| self.allocator.free(owned);
        slot.completion.complete(slot.completion.context, result);
    }
    fn permissionNativeResult(self: *View, hr: i32) void {
        if (hr >= 0) return;
        self.last_hresult = hr;
        if (self.access()) |window| window.report(.{ .domain = .hresult, .operation = .webview_permission, .code = @bitCast(hr) });
    }
    fn permissionOffer(ptr: *anyopaque, origin: [*:0]const u16, native_kind: u32, user: bool, native_call: *anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window) or !self.ready or self.recovering or !self.page_active) return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        const policy = self.config.?.options.permissions orelse return;
        const kind = permissions.Kind.fromNative(native_kind) orelse return;
        var text: [schemes.origin_limit]u8 = undefined;
        var length: usize = 0;
        while (length < text.len and origin[length] != 0) : (length += 1) {
            if (origin[length] > 126 or origin[length] <= 32) return;
            text[length] = @intCast(origin[length]);
        }
        if (origin[length] != 0) return;
        const page = self.pageId() orelse return;
        var responder: PermissionResponder = .{ .view = self, .native = native_call, .page = page.generation };
        policy.handler.handle(policy.handler.context, .{ .origin = text[0..length], .kind = kind, .user_initiated = user, .page = page }, &responder);
    }
    fn deferPermission(self: *View, native_call: *anyopaque, page: u64, options: permissions.DeferOptions) !PermissionId {
        if (is_linux) return self.unavailableBackend();
        const window = try self.propertyWindow();
        if (!self.permission_accepting) return error.PermissionUnavailable;
        if (!self.page_active or page != self.page_generation) return error.StalePage;
        const policy = self.config.?.options.permissions orelse return error.PermissionDenied;
        if (options.timeout_ms == 0 or options.timeout_ms > 600_000) return error.InvalidTimeout;
        if (self.eval_clock == null) self.eval_clock = try std.time.Timer.start();
        const deadline = try std.math.add(u64, self.eval_clock.?.read(), @as(u64, options.timeout_ms) * std.time.ns_per_ms);
        const token = try self.permission_book.reserve(.{ .page = page, .deadline = deadline }, policy.limits.max_pending);
        self.syncEvalTimer() catch |err| {
            _ = self.permission_book.take(token);
            self.syncEvalTimer() catch self.failEvalTimer();
            return err;
        };
        const hr = zwv_permission_defer(native_call, token);
        self.last_hresult = hr;
        if (hr < 0) {
            _ = self.permission_book.take(token);
            self.syncEvalTimer() catch self.failEvalTimer();
            return switch (@as(u32, @bitCast(hr))) {
                0x8000000a => error.Full,
                0x8007000e => error.OutOfMemory,
                else => error.PermissionDeferFailed,
            };
        }
        if (!self.attachmentClosed() and !appStopping(window) and !self.recovering and self.page_active and self.page_generation == page) {
            for (&self.permission_book.slots) |*entry| if (entry.*) |slot| if (slot.token == token) {
                entry.*.?.completion = options.completion;
                return .{ .view = self, .token = token, .page = page };
            };
        }
        _ = self.permission_book.take(token);
        if (self.native) |native| self.permissionNativeResult(zwv_permission_cancel(native, token));
        self.syncEvalTimer() catch self.failEvalTimer();
        return if (self.attachmentClosed() or appStopping(window)) error.Closed else error.StalePermission;
    }
    pub fn decidePermission(self: *View, id: PermissionId, decision: permissions.Decision) !void {
        if (is_linux) return self.unavailableBackend();
        const window = try self.propertyWindow();
        if (id.view != self or id.page != self.page_generation or !self.page_active) return error.StalePermission;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const slot = self.permission_book.take(id.token) orelse return error.StalePermission;
        const hr = zwv_permission_decide(self.native.?, id.token, decision == .allow_ephemeral);
        self.permissionNativeResult(hr);
        self.syncEvalTimer() catch self.failEvalTimer();
        const result: permissions.Result = if (self.attachmentClosed() or appStopping(window)) .detached else if (self.recovering or !self.page_active or slot.page != self.page_generation) .page_changed else if (hr < 0) .{ .native_failure = hr } else .{ .decided = decision };
        if (slot.completion) |completion| completion.complete(completion.context, result);
    }
    fn cancelPermission(self: *View, id: PermissionId) !bool {
        if (is_linux) return self.unavailableBackend();
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (id.view != self) return error.StalePermission;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const slot = self.permission_book.take(id.token) orelse return false;
        if (self.native) |native| self.permissionNativeResult(zwv_permission_cancel(native, id.token));
        self.syncEvalTimer() catch self.failEvalTimer();
        if (slot.completion) |completion| completion.complete(completion.context, if (self.attachmentClosed() or appStopping(window)) .detached else .cancelled);
        return true;
    }
    fn downloadNativeResult(self: *View, hr: i32) void {
        if (hr >= 0) return;
        self.last_hresult = hr;
        if (self.access()) |window| window.report(.{ .domain = .hresult, .operation = .webview_download, .code = @bitCast(hr) });
    }
    fn completeDownloadSlot(slot: downloads.Slot, result: downloads.Result) void {
        var destination = slot.destination;
        defer if (destination) |*owned| owned.deinit();
        if (slot.completion) |completion| completion.complete(completion.context, result);
    }
    fn downloadOffer(ptr: *anyopaque, uri_wide: [*:0]const u16, mime_wide: [*:0]const u16, name_wide: [*:0]const u16, total: i64, native_call: *anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window) or self.recovering or !self.ready) return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        const policy = self.config.?.options.downloads orelse return;
        var uri_storage: [65536]u8 = undefined;
        var mime_storage: [508]u8 = undefined;
        var name_storage: [1020]u8 = undefined;
        const uri_length = std.unicode.utf16LeToUtf8(&uri_storage, std.mem.span(uri_wide)) catch return;
        const mime_length = std.unicode.utf16LeToUtf8(&mime_storage, std.mem.span(mime_wide)) catch return;
        const name_length = std.unicode.utf16LeToUtf8(&name_storage, std.mem.span(name_wide)) catch return;
        var responder: DownloadResponder = .{ .view = self, .native = native_call };
        policy.handler.handle(policy.handler.context, .{ .uri = uri_storage[0..uri_length], .mime = mime_storage[0..mime_length], .suggested_name = name_storage[0..name_length], .total_bytes = if (total >= 0) @intCast(total) else null, .observed_page = if (self.page_active) .{ .view = self, .generation = self.page_generation } else null }, &responder);
    }
    fn deferDownload(self: *View, native_call: *anyopaque, options: downloads.DeferOptions) !DownloadId {
        if (is_linux) return self.unavailableBackend();
        const window = try self.propertyWindow();
        if (!self.download_accepting) return error.DownloadUnavailable;
        const policy = self.config.?.options.downloads orelse return error.DownloadDenied;
        if (options.timeout_ms == 0 or options.timeout_ms > 600_000) return error.InvalidTimeout;
        if (self.eval_clock == null) self.eval_clock = try std.time.Timer.start();
        const deadline = try std.math.add(u64, self.eval_clock.?.read(), @as(u64, options.timeout_ms) * std.time.ns_per_ms);
        const token = try self.download_book.reserve(.{ .observed_page = if (self.page_active) self.page_generation else null, .deadline = deadline }, policy.limits.max_active);
        self.syncEvalTimer() catch |err| {
            _ = self.download_book.take(token);
            self.syncEvalTimer() catch self.failEvalTimer();
            return err;
        };
        const hr = zwv_download_defer(native_call, token);
        if (hr < 0) {
            self.downloadNativeResult(hr);
            _ = self.download_book.take(token);
            self.syncEvalTimer() catch self.failEvalTimer();
            return switch (@as(u32, @bitCast(hr))) {
                0x8000000a => error.Full,
                0x8007000e => error.OutOfMemory,
                else => error.DownloadDeferFailed,
            };
        }
        if (!self.attachmentClosed() and !appStopping(window) and !self.recovering) if (self.download_book.find(token)) |slot| {
            slot.completion = options.completion;
            return .{ .view = self, .token = token };
        };
        _ = self.download_book.take(token);
        if (self.native) |native| self.downloadNativeResult(zwv_download_cancel(native, token));
        self.syncEvalTimer() catch self.failEvalTimer();
        return error.Closed;
    }
    /// Success consumes destination; any failure retains it. Native acceptance
    /// failure terminates the already accepted offer with native_failure.
    pub fn resolveDownload(self: *View, id: DownloadId, destination: *DownloadDestination, listener: ?downloads.Listener) !void {
        if (is_linux) return self.unavailableBackend();
        const window = try self.propertyWindow();
        if (id.view != self) return error.StaleDownload;
        const slot = self.download_book.find(id.token) orelse return error.StaleDownload;
        if (slot.active) return error.DownloadAlreadyActive;
        try destination.validate();
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const hr = zwv_download_accept(self.native.?, id.token, destination.wide.?.ptr);
        if (hr < 0) {
            self.downloadNativeResult(hr);
            if (self.download_book.take(id.token)) |old| {
                if (self.native) |native| self.downloadNativeResult(zwv_download_cancel(native, id.token));
                self.syncEvalTimer() catch self.failEvalTimer();
                completeDownloadSlot(old, if (self.attachmentClosed() or appStopping(window)) .detached else .{ .native_failure = hr });
            }
            return error.DownloadAcceptFailed;
        }
        const current = self.download_book.find(id.token) orelse return error.Closed;
        current.destination = destination.*;
        destination.path = null;
        destination.wide = null;
        current.active = true;
        current.deadline = null;
        current.listener = listener;
        self.syncEvalTimer() catch self.failEvalTimer();
        if (!self.attachmentClosed() and !appStopping(window) and !self.recovering) if (self.native) |native| zwv_download_activate(native, id.token);
    }
    fn cancelDownload(self: *View, id: DownloadId) !bool {
        if (is_linux) return self.unavailableBackend();
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (id.view != self) return error.StaleDownload;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const slot = self.download_book.take(id.token) orelse return false;
        if (self.native) |native| self.downloadNativeResult(zwv_download_cancel(native, id.token));
        self.syncEvalTimer() catch self.failEvalTimer();
        completeDownloadSlot(slot, if (self.attachmentClosed() or appStopping(window)) .detached else .cancelled);
        return true;
    }
    fn pauseDownload(self: *View, id: DownloadId, pause: bool) !void {
        if (is_linux) return self.unavailableBackend();
        _ = try self.propertyWindow();
        if (id.view != self) return error.StaleDownload;
        const slot = self.download_book.find(id.token) orelse return error.StaleDownload;
        if (!slot.active) return error.DownloadNotActive;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const hr = zwv_download_pause(self.native.?, id.token, pause);
        self.downloadNativeResult(hr);
        if (hr < 0) return error.DownloadControlFailed;
    }
    fn downloadSnapshot(self: *View, id: DownloadId) !downloads.Snapshot {
        if (is_linux) return self.unavailableBackend();
        const window = try self.propertyWindow();
        if (id.view != self) return error.StaleDownload;
        const slot = self.download_book.find(id.token) orelse return error.StaleDownload;
        if (!slot.active) return error.DownloadNotActive;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        var received: u64 = 0;
        var total: i64 = -1;
        var paused = false;
        const hr = zwv_download_snapshot(self.native.?, id.token, &received, &total, &paused);
        self.downloadNativeResult(hr);
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (hr < 0) return error.DownloadSnapshotFailed;
        return .{ .received_bytes = received, .total_bytes = if (total >= 0) @intCast(total) else null, .paused = paused };
    }
    fn downloadNotify(ptr: *anyopaque, token: u64, kind: u32, received: u64, total: i64, code: i32) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window) or self.recovering) return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        const snapshot: downloads.Snapshot = .{ .received_bytes = received, .total_bytes = if (total >= 0) @intCast(total) else null, .paused = kind == 0 and code != 0 };
        if (kind == 0) {
            const slot = self.download_book.find(token) orelse return;
            if (slot.listener) |listener| listener.changed(listener.context, snapshot);
            return;
        }
        const slot = self.download_book.take(token) orelse return;
        if (kind == 4) self.downloadNativeResult(code);
        self.syncEvalTimer() catch self.failEvalTimer();
        const result: downloads.Result = if (self.attachmentClosed() or appStopping(window)) .detached else switch (kind) {
            1 => if (slot.destination) |owned| .{ .completed = .{ .snapshot = snapshot, .path = owned.path.? } } else .{ .native_failure = @bitCast(@as(u32, 0x8000ffff)) },
            2 => .{ .interrupted = code },
            3 => .limit_exceeded,
            else => .{ .native_failure = code },
        };
        completeDownloadSlot(slot, result);
    }
    fn deferResource(self: *View, native_call: *anyopaque, options: resources.DeferOptions) !ResourceRequestId {
        const window = try self.propertyWindow();
        if (!self.resource_accepting) return error.ResourceUnavailable;
        if (!self.page_active) return error.StalePage;
        if (window.app.phase == .stopping or window.app.phase == .stopped) return error.Closed;
        if (options.timeout_ms == 0 or options.timeout_ms > 600_000) return error.InvalidTimeout;
        if (self.eval_clock == null) self.eval_clock = try std.time.Timer.start();
        const deadline = try std.math.add(u64, self.eval_clock.?.read(), @as(u64, options.timeout_ms) * std.time.ns_per_ms);
        const page = self.page_generation;
        // Provisional slots cannot call the new context if native preparation
        // reenters lifecycle handling before ownership has transferred.
        const token = try self.resource_book.reserve(.{ .page = page, .deadline = deadline, .completion = null }, self.config.?.options.resource_limits.max_pending);
        self.syncEvalTimer() catch |err| {
            _ = self.resource_book.take(token);
            self.syncEvalTimer() catch self.failEvalTimer();
            return err;
        };
        const hr = if (is_linux) webkit.zwk_resource_defer(native_call, token) else zwv_defer_resource(native_call, token);
        if (!is_linux) self.last_hresult = hr;
        if (if (is_linux) hr != 0 else hr < 0) {
            _ = self.resource_book.take(token);
            self.syncEvalTimer() catch self.failEvalTimer();
            if (is_linux) {
                try webkit.check(hr);
                unreachable;
            }
            return switch (@as(u32, @bitCast(hr))) {
                0x8000000a => error.Full,
                0x8007000e => error.OutOfMemory,
                else => error.ResourceDeferFailed,
            };
        }
        if (!self.attachmentClosed() and self.page_generation == page and self.page_active and !self.recovering) {
            for (&self.resource_book.slots) |*entry| if (entry.*) |slot| if (slot.token == token) {
                entry.*.?.completion = options.completion;
                return .{ .view = self, .token = token, .page = page };
            };
        }
        _ = self.resource_book.take(token);
        if (self.native) |native| if (is_linux) webkit.zwk_resource_cancel(native, token) else zwv_cancel_resource(native, token);
        self.syncEvalTimer() catch self.failEvalTimer();
        return error.StaleRequest;
    }
    /// Main-thread commit. Success consumes owned; every error retains its data.
    /// A validated native commit attempt terminates the request even on HRESULT
    /// failure, so a retained response can be reused for a different request.
    pub fn respondOwned(self: *View, id: ResourceRequestId, owned: *resources.OwnedResponse) !void {
        const window = try self.propertyWindow();
        if (id.view != self or id.page != self.page_generation or !self.page_active) return error.StaleRequest;
        if (owned.storage == null) return error.ResponseMoved;
        try resources.validateResponse(owned.response, @min(self.config.?.options.max_resource_bytes, self.config.?.options.resource_limits.max_response_bytes));
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        var headers: [16]NativeResponseHeader = undefined;
        for (owned.response.headers, 0..) |header, i| headers[i] = .{ .name = header.name.ptr, .name_len = @intCast(header.name.len), .value = header.value.ptr, .value_len = @intCast(header.value.len) };
        const slot = self.resource_book.take(id.token) orelse return error.StaleRequest;
        const response = owned.response;
        const hr = if (is_linux) webkit.zwk_resource_respond_deferred(self.native.?, id.token, response.status, response.mime.ptr, response.mime.len, response.bytes.ptr, response.bytes.len, &headers, @intCast(response.headers.len)) else zwv_respond_deferred(self.native.?, id.token, response.status, response.mime.ptr, response.mime.len, response.bytes.ptr, response.bytes.len, &headers, @intCast(response.headers.len));
        self.recordResourceFailure(hr);
        if (!is_linux) self.last_hresult = hr;
        const succeeded = if (is_linux) hr == 0 else hr >= 0;
        if (succeeded) owned.deinit();
        self.syncEvalTimer() catch self.failEvalTimer();
        if (slot.completion) |completion| completion.complete(completion.context, if (self.attachmentClosed() or appStopping(window)) .detached else if (self.recovering or self.page_generation != slot.page or !self.page_active) .page_changed else if (!succeeded) (if (is_linux) .unavailable else .{ .native_failure = hr }) else .responded);
        if (is_linux) return webkit.check(hr);
        if (!succeeded) return error.ResourceResponseFailed;
    }
    fn fileBudget(self: *View, owned: *const OwnedFileResponse) !*anyopaque {
        _ = try self.propertyWindow();
        const limits = self.config.?.options.file_streams orelse return error.FileStreamsDenied;
        try owned.validate(limits.max_file_bytes);
        if (self.file_budget) |budget| {
            if (is_linux) webkit.zwk_file_budget_limit(budget, limits.max_live) else zwv_file_budget_limit(budget, limits.max_live);
            return budget;
        }
        const budget = (if (is_linux) webkit.zwk_file_budget_create(limits.max_live) else zwv_file_budget_create(limits.max_live)) orelse return error.OutOfMemory;
        self.file_budget = budget;
        return budget;
    }
    fn resourceResult(self: *View, result: c_int) !void {
        self.recordResourceFailure(result);
        return webkit.check(result);
    }
    fn recordResourceFailure(self: *View, result: c_int) void {
        if (is_linux and result == 5) if (self.native) |native| {
            var failure: webkit.Failure = undefined;
            webkit.zwk_last_failure(native, &failure);
            if (failure.domain != 0) self.last_native_failure = .{ .glib = failure };
        };
    }
    /// Commits a complete prepared file. Success consumes owned and optionally
    /// returns an owning ticket. Errors retain it. Once native commit starts,
    /// this request terminates even on failure; retry with a fresh request id.
    pub fn respondFile(self: *View, id: ResourceRequestId, owned: *OwnedFileResponse, options: file_responses.CommitOptions) !?StreamTicket {
        const window = try self.propertyWindow();
        if (id.view != self or id.page != self.page_generation or !self.page_active) return error.StaleRequest;
        const budget = try self.fileBudget(owned);
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const response = owned.metadata.response;
        var headers: [16]NativeResponseHeader = undefined;
        for (response.headers, 0..) |header, i| headers[i] = .{ .name = header.name.ptr, .name_len = @intCast(header.name.len), .value = header.value.ptr, .value_len = @intCast(header.value.len) };
        const slot = self.resource_book.take(id.token) orelse return error.StaleRequest;
        var ticket: ?*anyopaque = null;
        const hr = if (is_linux) webkit.zwk_resource_respond_file_deferred(self.native.?, id.token, owned.native.?, owned.length, budget, response.status, response.mime.ptr, response.mime.len, &headers, @intCast(response.headers.len), @intFromBool(options.ticket), &ticket) else zwv_respond_file_deferred(self.native.?, id.token, owned.native.?, owned.length, budget, response.status, response.mime.ptr, response.mime.len, &headers, @intCast(response.headers.len), @intFromBool(options.ticket), &ticket);
        self.recordResourceFailure(hr);
        if (!is_linux) self.last_hresult = hr;
        const succeeded = if (is_linux) hr == 0 else hr >= 0;
        if (succeeded) owned.deinit();
        self.syncEvalTimer() catch self.failEvalTimer();
        if (slot.completion) |completion| completion.complete(completion.context, if (self.attachmentClosed() or appStopping(window)) .detached else if (self.recovering or self.page_generation != slot.page or !self.page_active) .page_changed else if (!succeeded) (if (is_linux) .unavailable else .{ .native_failure = hr }) else .responded);
        if (is_linux) try webkit.check(hr) else if (!succeeded) return fileResponseError(hr);
        return if (ticket) |control| .{ .native = control } else null;
    }
    fn cancelRequest(self: *View, id: ResourceRequestId) !bool {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (id.view != self or id.page != self.page_generation) return error.StaleRequest;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const slot = self.resource_book.take(id.token) orelse return false;
        if (self.native) |native| if (is_linux) webkit.zwk_resource_cancel(native, id.token) else zwv_cancel_resource(native, id.token);
        self.syncEvalTimer() catch self.failEvalTimer();
        if (slot.completion) |completion| completion.complete(completion.context, if (self.attachmentClosed() or appStopping(window)) .detached else .cancelled);
        return true;
    }
    fn cancelTool(self: *View, token: u64) !bool {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const slot = self.tool_book.take(token) orelse return false;
        if (self.native) |native| {
            if (is_linux) {
                if (slot.kind == .find) webkit.zwk_find_cancel(native, token) else webkit.zwk_capture_cancel(native, token);
            } else zwv_tool_cancel(native, token);
        }
        if (token == self.find_token) self.clearFind();
        self.syncEvalTimer() catch self.failEvalTimer();
        self.completeToolSlot(slot, if (self.attachmentClosed() or appStopping(window)) .detached else .cancelled);
        return true;
    }
    fn toolWindow(self: *View, kind: tools.Kind, page: ?PageId) !Access {
        if (is_linux and kind != .capture and kind != .find and kind != .clear) return self.unavailableBackend();
        const window = try self.propertyWindow();
        if (!self.tool_accepting) return error.ToolUnavailable;
        const policy = self.config.?.options.tools;
        const allowed = switch (kind) {
            .cookies => policy.cookies,
            .clear => policy.clear_entire_profile,
            .find => policy.find,
            .capture => policy.capture,
            .pdf => policy.pdf,
        };
        if (!allowed) return error.ToolDenied;
        if (page) |id| {
            if (id.view != self or id.generation != self.page_generation or !self.page_active) return error.StalePage;
            if (self.loading) return error.PageLoading;
        }
        return window;
    }
    fn reserveTool(self: *View, kind: tools.Kind, request_scope: tools.Scope, options: tools.RequestOptions, completion: tools.Completion, owned: ?[]u8, page: ?PageId) !u64 {
        _ = try self.toolWindow(kind, page);
        var deadline: ?u64 = null;
        if (options.timeout_ms) |milliseconds| {
            if (milliseconds == 0 or milliseconds > 600_000) return error.InvalidTimeout;
            if (self.eval_clock == null) self.eval_clock = try std.time.Timer.start();
            deadline = try std.math.add(u64, self.eval_clock.?.read(), @as(u64, milliseconds) * std.time.ns_per_ms);
        }
        const token = try self.tool_book.reserve(.{ .token = 0, .kind = kind, .scope = request_scope, .page = self.page_generation, .deadline = deadline, .completion = completion, .owned = owned }, self.config.?.options.tool_limits.max_pending);
        self.syncEvalTimer() catch |err| {
            _ = self.tool_book.take(token);
            self.syncEvalTimer() catch self.failEvalTimer();
            return err;
        };
        return token;
    }
    fn submitTool(self: *View, kind: tools.Kind, request_scope: tools.Scope, native_request: NativeToolRequest, options: tools.RequestOptions, completion: tools.Completion, owned: ?[]u8, listener: ?tools.FindListener, page: ?PageId) !ToolOperation {
        const token = try self.reserveTool(kind, request_scope, options, completion, owned, page);
        var request = native_request;
        request.token = token;
        if (kind == .find) {
            self.find_token = token;
            self.find_listener = listener;
        }
        const hr = if (!is_linux) zwv_tool_start(self.native.?, &request) else if (kind == .clear) webkit.zwk_clear_start(self.native.?, token) else webkit.zwk_capture_start(self.native.?, token);
        if (is_linux) {
            if (hr != 0) {
                _ = self.tool_book.take(token);
                self.syncEvalTimer() catch self.failEvalTimer();
                try webkit.check(hr);
                unreachable;
            }
            return .{ .view = self, .token = token };
        }
        self.last_hresult = hr;
        if (hr < 0) {
            _ = self.tool_book.take(token);
            if (kind == .find) {
                self.find_token = 0;
                self.find_listener = null;
            }
            self.syncEvalTimer() catch self.failEvalTimer();
            return switch (@as(u32, @bitCast(hr))) {
                0x8000000a => error.Full,
                0x80070005 => error.OriginDenied,
                0x80004002 => error.UnsupportedCapability,
                0x8007000e => error.OutOfMemory,
                else => error.ToolSubmitFailed,
            };
        }
        return .{ .view = self, .token = token };
    }
    pub fn getCookies(self: *View, uri: []const u8, options: tools.RequestOptions, completion: tools.Completion) !ToolOperation {
        if (is_linux) return self.unavailableBackend();
        _ = try self.toolWindow(.cookies, null);
        var wide: [16385:0]u16 = undefined;
        wide[try uriWide(&wide, uri)] = 0;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        return self.submitTool(.cookies, .profile, .{ .kind = 0, .text = &wide }, options, completion, null, null, null);
    }
    pub fn clearBrowsingData(self: *View, _: tools.ClearScope, options: tools.RequestOptions, completion: tools.Completion) !ToolOperation {
        _ = try self.toolWindow(.clear, null);
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        return self.submitTool(.clear, .profile, .{ .kind = 1 }, options, completion, null, null, null);
    }
    pub fn capturePreview(self: *View, page: PageId, options: tools.RequestOptions, completion: tools.Completion) !ToolOperation {
        _ = try self.toolWindow(.capture, page);
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        return self.submitTool(.capture, .page, .{ .kind = 3 }, options, completion, null, null, page);
    }
    pub fn printToPdf(self: *View, page: PageId, pdf: tools.PdfOptions, options: tools.RequestOptions, completion: tools.Completion) !ToolOperation {
        if (is_linux) return self.unavailableBackend();
        _ = try self.toolWindow(.pdf, page);
        if (!pdf.accept_overwrite) return error.OverwriteNotAccepted;
        if (!std.fs.path.isAbsolute(pdf.path) or pdf.path.len == 0 or std.mem.indexOfScalar(u8, pdf.path, 0) != null) return error.AbsoluteOutputPathRequired;
        if (pdf.first_page == 0 or pdf.last_page < pdf.first_page or @as(u32, pdf.last_page) - pdf.first_page + 1 > 256) return error.InvalidPageRange;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, pdf.path);
        defer self.allocator.free(wide);
        if (wide.len > 32766) return error.OutputPathTooLarge;
        const owned = try self.allocator.dupe(u8, pdf.path);
        errdefer self.allocator.free(owned);
        return self.submitTool(.pdf, .page, .{ .kind = 4, .text = wide.ptr, .first_page = pdf.first_page, .last_page = pdf.last_page, .flags = @as(u32, @intFromBool(pdf.landscape)) | @as(u32, @intFromBool(pdf.print_backgrounds)) << 1 }, options, completion, owned, null, page);
    }
    pub fn startFind(self: *View, page: PageId, find: tools.FindOptions, options: tools.RequestOptions, completion: tools.Completion) !ToolOperation {
        if (is_linux) {
            _ = try self.toolWindow(.find, page);
            if (find.whole_word or !find.highlight_all) return error.UnsupportedCapability;
            if (find.term.len == 0 or find.term.len > 4096) return error.InvalidFindTerm;
            const scope = self.beginCallback() orelse return error.Closed;
            defer scope.end();
            return self.startLinuxFindCaptured(page, find, options, completion);
        }
        _ = try self.toolWindow(.find, page);
        if (find.term.len == 0 or find.term.len > 4096 or std.mem.indexOfScalar(u8, find.term, 0) != null) return error.InvalidFindTerm;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, find.term);
        defer self.allocator.free(wide);
        _ = try self.toolWindow(.find, page);
        if (self.find_token != 0) {
            const old = self.find_token;
            self.clearFind();
            if (self.tool_book.take(old)) |slot| self.completeToolSlot(slot, .cancelled);
            _ = try self.toolWindow(.find, page);
            if (self.find_token != 0) return error.FindReentered;
        }
        return self.submitTool(.find, .page, .{ .kind = 2, .text = wide.ptr, .flags = @as(u32, @intFromBool(find.case_sensitive)) | @as(u32, @intFromBool(find.whole_word)) << 1 | @as(u32, @intFromBool(find.highlight_all)) << 2 }, options, completion, null, find.listener, page);
    }
    noinline fn startLinuxFindCaptured(self: *View, page: PageId, find: tools.FindOptions, options: tools.RequestOptions, completion: tools.Completion) !ToolOperation {
        var captured: [4097]u8 = undefined;
        @memcpy(captured[0..find.term.len], find.term);
        captured[find.term.len] = 0;
        const term = captured[0..find.term.len];
        if (std.mem.indexOfScalar(u8, term, 0) != null or !std.unicode.utf8ValidateSlice(term)) return error.InvalidFindTerm;
        const budget = self.find_budget orelse blk: {
            const value = webkit.zwk_find_budget_new(self.config.?.options.tool_limits.max_pending) orelse return error.OutOfMemory;
            _ = self.toolWindow(.find, page) catch |err| {
                webkit.zwk_find_budget_close(value);
                webkit.zwk_find_budget_release(value);
                return err;
            };
            if (self.find_budget != null) {
                webkit.zwk_find_budget_close(value);
                webkit.zwk_find_budget_release(value);
                return error.FindReentered;
            }
            self.find_budget = value;
            break :blk value;
        };
        try webkit.check(webkit.zwk_find_budget_limit(budget, self.config.?.options.tool_limits.max_pending));
        _ = try self.toolWindow(.find, page);
        const native = self.native.?;
        var candidate: ?*anyopaque = null;
        try webkit.check(webkit.zwk_find_prepare(native, budget, webkitFindNotify, term.ptr, term.len, 4 | @as(u32, @intFromBool(find.case_sensitive)), &candidate));
        defer if (candidate) |value| webkit.zwk_find_abort(value);
        _ = try self.toolWindow(.find, page);
        if (self.native != native) return error.StalePage;
        const token = try self.reserveTool(.find, .page, options, completion, null, page);
        errdefer {
            _ = self.tool_book.take(token);
            if (self.find_token == token) self.clearFind();
            self.syncEvalTimer() catch self.failEvalTimer();
        }
        _ = try self.toolWindow(.find, page);
        if (self.native != native) return error.StalePage;
        if (self.find_token != 0) {
            const old = self.find_token;
            self.clearFind();
            if (self.tool_book.take(old)) |slot| self.completeToolSlot(slot, .cancelled);
            _ = try self.toolWindow(.find, page);
            if (self.native != native) return error.StalePage;
            if (self.find_token != 0) return error.FindReentered;
        }
        self.find_token = token;
        self.find_listener = find.listener;
        const value = candidate.?;
        candidate = null; // commit always consumes, including a rejected commit.
        try webkit.check(webkit.zwk_find_commit(value, token));
        return .{ .view = self, .token = token };
    }
    fn clearFind(self: *View) void {
        const token = self.find_token;
        self.find_token = 0;
        self.find_listener = null;
        if (token != 0) if (self.native) |native| {
            if (is_linux) webkit.zwk_find_cancel(native, token) else zwv_tool_cancel(native, token);
        };
    }
    fn findAction(self: *View, page: PageId, action: c_int) !tools.FindState {
        _ = try self.toolWindow(.find, page);
        if (self.find_token == 0) return error.FindInactive;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (is_linux) {
            var snapshot: webkit.FindSnapshot = .{ .known = 0, .matches = 0, .active_index = 0 };
            try webkit.check(webkit.zwk_find_action(self.native.?, action, &snapshot));
            return findSnapshot(snapshot);
        }
        var snapshot: NativeFind = .{ .matches = 0, .active_index = -1 };
        try self.propertyResult(zwv_find_action(self.native.?, action, &snapshot));
        return .{ .matches = snapshot.matches, .active_index = snapshot.active_index };
    }
    pub fn findState(self: *View, page: PageId) !tools.FindState {
        return self.findAction(page, 0);
    }
    pub fn findNext(self: *View, page: PageId) !void {
        _ = try self.findAction(page, 1);
    }
    pub fn findPrevious(self: *View, page: PageId) !void {
        _ = try self.findAction(page, 2);
    }
    pub fn stopFind(self: *View) !void {
        _ = try self.propertyWindow();
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const token = self.find_token;
        self.clearFind();
        if (self.tool_book.take(token)) |slot| self.completeToolSlot(slot, .cancelled);
        self.syncEvalTimer() catch self.failEvalTimer();
    }
    fn findSnapshot(snapshot: webkit.FindSnapshot) tools.FindState {
        return .{
            .matches = if (snapshot.known & 1 != 0) snapshot.matches else null,
            .active_index = if (snapshot.known & 2 != 0) snapshot.active_index else null,
        };
    }
    fn webkitFindNotify(ptr: *anyopaque, token: u64, kind: c_int, status: c_int, snapshot: *const webkit.FindSnapshot) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window)) return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        if (kind == 1) {
            if (self.find_token != token or self.loading or !self.page_active or self.recovering or status != 0) return;
            if (self.find_listener) |listener| listener.changed(listener.context, findSnapshot(snapshot.*));
            return;
        }
        const slot = self.tool_book.take(token) orelse return;
        self.syncEvalTimer() catch self.failEvalTimer();
        if (self.attachmentClosed() or appStopping(window)) return self.completeToolSlot(slot, .detached);
        if (self.recovering or slot.page != self.page_generation or !self.page_active) return self.completeToolSlot(slot, .page_changed);
        if (kind != 0 or slot.kind != .find) return self.completeToolSlot(slot, .invalid_result);
        if (status != 0) {
            if (self.find_token == token) self.clearFind();
            return self.completeToolSlot(slot, if (status == 1) .limit_exceeded else .invalid_result);
        }
        self.completeToolSlot(slot, .{ .find = findSnapshot(snapshot.*) });
    }
    fn toolNotify(ptr: *anyopaque, token: u64, kind: u32, hr: i32, data: ?*const anyopaque, count: u32) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window)) return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        if (kind == 5) {
            if (self.find_token != token or self.loading or !self.page_active or self.recovering or data == null) return;
            const snapshot: *const NativeFind = @ptrCast(@alignCast(data.?));
            if (self.find_listener) |listener| listener.changed(listener.context, .{ .matches = snapshot.matches, .active_index = snapshot.active_index });
            return;
        }
        const slot = self.tool_book.take(token) orelse return;
        self.syncEvalTimer() catch self.failEvalTimer();
        if (self.attachmentClosed() or appStopping(window)) return self.completeToolSlot(slot, .detached);
        if (self.recovering or (slot.scope == .page and (slot.page != self.page_generation or !self.page_active))) return self.completeToolSlot(slot, .page_changed);
        if (kind != @intFromEnum(slot.kind)) return self.completeToolSlot(slot, .invalid_result);
        if (hr < 0) {
            if (slot.kind == .find and self.find_token == token) self.clearFind();
            return self.completeToolSlot(slot, if (@as(u32, @bitCast(hr)) == 0x8007007a or @as(u32, @bitCast(hr)) == 0x80030070) .limit_exceeded else .{ .native_failure = hr });
        }
        switch (slot.kind) {
            .clear => self.completeToolSlot(slot, .cleared),
            .pdf => self.completeToolSlot(slot, .{ .pdf_path = slot.owned orelse "" }),
            .capture => {
                if (data == null or count > self.config.?.options.tool_limits.max_capture_bytes) return self.completeToolSlot(slot, .invalid_result);
                self.completeToolSlot(slot, .{ .png = @as([*]const u8, @ptrCast(data.?))[0..count] });
            },
            .find => {
                if (data == null or count != 1) return self.completeToolSlot(slot, .invalid_result);
                const snapshot: *const NativeFind = @ptrCast(@alignCast(data.?));
                self.completeToolSlot(slot, .{ .find = .{ .matches = snapshot.matches, .active_index = snapshot.active_index } });
            },
            .cookies => self.cookiesResult(slot, data, count),
        }
    }
    fn webkitCaptureNotify(ptr: *anyopaque, token: u64, status: c_int, data: [*]const u8, count: usize, failure: ?*const webkit.Failure) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window)) return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        const slot = self.tool_book.take(token) orelse return;
        self.syncEvalTimer() catch self.failEvalTimer();
        if (self.attachmentClosed() or appStopping(window)) return self.completeToolSlot(slot, .detached);
        if (self.recovering or (slot.scope == .page and (slot.page != self.page_generation or !self.page_active))) return self.completeToolSlot(slot, .page_changed);
        if (failure) |native| self.last_native_failure = .{ .glib = native.* };
        if (slot.kind == .clear) return self.completeToolSlot(slot, switch (status) {
            0 => if (count == 0) .cleared else .invalid_result,
            1 => if (failure) |native| .{ .native_failure = native.code } else .invalid_result,
            else => .invalid_result,
        });
        if (slot.kind != .capture) return self.completeToolSlot(slot, .invalid_result);
        const result: tools.Result = switch (status) {
            0 => if (count == 0 or count > self.config.?.options.tool_limits.max_capture_bytes) .invalid_result else .{ .png = data[0..count] },
            1 => if (failure) |native| .{ .native_failure = native.code } else .invalid_result,
            2 => .limit_exceeded,
            4 => .out_of_memory,
            else => .invalid_result,
        };
        self.completeToolSlot(slot, result);
    }
    fn cookieText(allocator: std.mem.Allocator, wide: ?[*:0]const u16, remaining: *usize) ![]const u8 {
        const value = wide orelse return error.InvalidCookieResult;
        var units: usize = 0;
        while (units <= 4096 and value[units] != 0) : (units += 1) {}
        if (units > 4096) return error.ToolResultTooLarge;
        var it = std.unicode.Utf16LeIterator.init(value[0..units]);
        var bytes: usize = 0;
        while (try it.nextCodepoint()) |cp| bytes += std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        if (bytes > remaining.*) return error.ToolResultTooLarge;
        const output = try allocator.alloc(u8, bytes);
        _ = try std.unicode.utf16LeToUtf8(output, value[0..units]);
        remaining.* -= bytes;
        return output;
    }
    fn cookiesResult(self: *View, slot: tools.Slot, data: ?*const anyopaque, count: u32) void {
        const limits = self.config.?.options.tool_limits;
        if (count > limits.max_cookies or (count != 0 and data == null)) return self.completeToolSlot(slot, .limit_exceeded);
        const descriptors = @as(usize, count) * @sizeOf(tools.Cookie);
        if (descriptors > limits.max_cookie_bytes) return self.completeToolSlot(slot, .limit_exceeded);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const items = self.convertCookies(arena.allocator(), data, count, limits.max_cookie_bytes - descriptors) catch |err| {
            if (self.obsoleteToolResult(slot)) |result| return self.completeToolSlot(slot, result);
            return self.completeToolSlot(slot, if (err == error.OutOfMemory) .out_of_memory else if (err == error.ToolResultTooLarge) .limit_exceeded else .invalid_result);
        };
        if (self.obsoleteToolResult(slot)) |result| return self.completeToolSlot(slot, result);
        self.completeToolSlot(slot, .{ .cookies = items });
    }
    fn obsoleteToolResult(self: *View, slot: tools.Slot) ?tools.Result {
        const window = self.access() orelse return .detached;
        if (self.attachmentClosed() or appStopping(window)) return .detached;
        if (self.recovering or (slot.scope == .page and (slot.page != self.page_generation or !self.page_active))) return .page_changed;
        return null;
    }
    fn convertCookies(_: *View, allocator: std.mem.Allocator, data: ?*const anyopaque, count: u32, available: usize) ![]const tools.Cookie {
        const output = try allocator.alloc(tools.Cookie, count);
        if (count == 0) return output;
        const input = @as([*]const NativeCookie, @ptrCast(@alignCast(data.?)))[0..count];
        var remaining = available;
        for (output, input) |*cookie, native| {
            if (native.same_site > 2 or native.flags & ~@as(u32, 7) != 0 or !std.math.isFinite(native.expires)) return error.InvalidCookieResult;
            cookie.* = .{ .name = try cookieText(allocator, native.name, &remaining), .value = try cookieText(allocator, native.value, &remaining), .domain = try cookieText(allocator, native.domain, &remaining), .path = try cookieText(allocator, native.path, &remaining), .expires = native.expires, .secure = native.flags & 1 != 0, .http_only = native.flags & 2 != 0, .session = native.flags & 4 != 0, .same_site = @enumFromInt(native.same_site) };
        }
        return output;
    }
    fn validCookieName(name: []const u8) bool {
        if (name.len == 0 or name.len > 256) return false;
        for (name) |byte| if (byte < 33 or byte > 126 or std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={}", byte) != null) return false;
        return true;
    }
    pub fn setCookie(self: *View, uri: []const u8, cookie: tools.CookieWrite) !void {
        if (is_linux) return self.unavailableBackend();
        _ = try self.toolWindow(.cookies, null);
        if (!cookie.accept_cookie_scope) return error.CookieScopeNotAccepted;
        if (!validCookieName(cookie.name) or cookie.value.len > 4096 or cookie.path.len == 0 or cookie.path.len > 4096 or cookie.path[0] != '/') return error.InvalidCookie;
        for (cookie.value) |byte| if (byte < 32 or byte > 126 or byte == ';') return error.InvalidCookie;
        for (cookie.path) |byte| if (byte < 33 or byte > 126 or byte == ';') return error.InvalidCookie;
        if (cookie.same_site == .none and !cookie.secure) return error.InvalidCookie;
        if (cookie.expires) |expires| if (!std.math.isFinite(expires) or expires <= 0) return error.InvalidCookie;
        var wide_uri: [16385:0]u16 = undefined;
        wide_uri[try uriWide(&wide_uri, uri)] = 0;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const name = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, cookie.name);
        defer self.allocator.free(name);
        const value = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, cookie.value);
        defer self.allocator.free(value);
        const path = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, cookie.path);
        defer self.allocator.free(path);
        _ = try self.toolWindow(.cookies, null);
        const native: NativeCookieWrite = .{ .name = name.ptr, .value = value.ptr, .path = path.ptr, .expires = cookie.expires orelse 0, .flags = @as(u32, @intFromBool(cookie.secure)) | @as(u32, @intFromBool(cookie.http_only)) << 1 | @as(u32, @intFromBool(cookie.expires == null)) << 2, .same_site = @intFromEnum(cookie.same_site) };
        const hr = zwv_cookie_write(self.native.?, &wide_uri, &native, false);
        if (@as(u32, @bitCast(hr)) == 0x80070005) return error.OriginDenied;
        try self.propertyResult(hr);
    }
    pub fn deleteCookie(self: *View, uri: []const u8, cookie: tools.CookieDelete) !void {
        if (is_linux) return self.unavailableBackend();
        _ = try self.toolWindow(.cookies, null);
        if (!cookie.accept_cookie_scope) return error.CookieScopeNotAccepted;
        if (!validCookieName(cookie.name) or cookie.path.len == 0 or cookie.path.len > 4096 or cookie.path[0] != '/') return error.InvalidCookie;
        for (cookie.path) |byte| if (byte < 33 or byte > 126 or byte == ';') return error.InvalidCookie;
        var wide_uri: [16385:0]u16 = undefined;
        wide_uri[try uriWide(&wide_uri, uri)] = 0;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const wide_name = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, cookie.name);
        defer self.allocator.free(wide_name);
        const path = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, cookie.path);
        defer self.allocator.free(path);
        _ = try self.toolWindow(.cookies, null);
        const native: NativeCookieWrite = .{ .name = wide_name.ptr, .value = std.unicode.utf8ToUtf16LeStringLiteral(""), .path = path.ptr, .expires = 0, .flags = 0, .same_site = 1 };
        const hr = zwv_cookie_write(self.native.?, &wide_uri, &native, true);
        if (@as(u32, @bitCast(hr)) == 0x80070005) return error.OriginDenied;
        try self.propertyResult(hr);
    }
    fn scriptNotify(ptr: *anyopaque, token: u64, hr: i32, value: ?[*:0]const u16) callconv(.c) void {
        completeScript(ptr, token, if (hr < 0) .{ .native_failure = hr } else null, value);
    }
    fn webkitScriptNotify(ptr: *anyopaque, token: u64, status: c_int, code: i32, value: ?[*:0]const u16, failure: ?*const webkit.Failure) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        if (failure) |native| self.last_native_failure = .{ .glib = native.* };
        const problem: ?ScriptResult = switch (status) {
            0 => null,
            1 => .{ .native_failure = code },
            2 => .result_too_large,
            else => .invalid_result,
        };
        completeScript(ptr, token, problem, value);
    }
    fn completeScript(ptr: *anyopaque, token: u64, problem: ?ScriptResult, value: ?[*:0]const u16) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window)) return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        const slot = self.eval_book.take(token) orelse return;
        self.syncEvalTimer() catch self.failEvalTimer();
        if (self.attachmentClosed() or appStopping(window)) {
            slot.completion.complete(slot.completion.context, .detached);
            return;
        }
        if (slot.page != self.page_generation or !self.page_active or self.recovering) {
            slot.completion.complete(slot.completion.context, .page_changed);
            return;
        }
        if (problem) |result| {
            slot.completion.complete(slot.completion.context, result);
            return;
        }
        const json = value orelse {
            slot.completion.complete(slot.completion.context, .invalid_result);
            return;
        };
        const max = self.config.?.options.scripts.max_result_bytes;
        var units: usize = 0;
        while (units <= max and json[units] != 0) : (units += 1) {}
        if (units > max) {
            slot.completion.complete(slot.completion.context, .result_too_large);
            return;
        }
        var iterator = std.unicode.Utf16LeIterator.init(json[0..units]);
        var bytes: usize = 0;
        while (iterator.nextCodepoint() catch {
            slot.completion.complete(slot.completion.context, .invalid_result);
            return;
        }) |codepoint| {
            bytes += std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
            if (bytes > max) {
                slot.completion.complete(slot.completion.context, .result_too_large);
                return;
            }
        }
        const text = self.allocator.alloc(u8, bytes) catch {
            if (self.attachmentClosed() or appStopping(window)) return slot.completion.complete(slot.completion.context, .detached);
            if (self.recovering or !self.page_active or slot.page != self.page_generation) return slot.completion.complete(slot.completion.context, .page_changed);
            slot.completion.complete(slot.completion.context, .out_of_memory);
            return;
        };
        defer self.allocator.free(text);
        if (self.attachmentClosed() or appStopping(window)) return slot.completion.complete(slot.completion.context, .detached);
        if (self.recovering or !self.page_active or slot.page != self.page_generation) return slot.completion.complete(slot.completion.context, .page_changed);
        _ = std.unicode.utf16LeToUtf8(text, json[0..units]) catch unreachable;
        slot.completion.complete(slot.completion.context, .{ .json = text });
    }

    fn propertyWindow(self: *View) !Access {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (self.attachment_phase != .attached or !self.ready or self.recovering) return error.NotReady;
        return window;
    }
    fn propertyResult(self: *View, hr: i32) !void {
        self.last_hresult = hr;
        _ = try self.propertyWindow();
        if (hr < 0) return error.WebViewPropertyFailed;
    }
    pub fn setZoom(self: *View, factor: f64) !void {
        _ = try self.propertyWindow();
        if (!std.math.isFinite(factor) or factor < 0.25 or factor > 5.0) return error.InvalidZoom;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        var value = factor;
        if (is_linux) try webkit.check(webkit.zwk_zoom(self.native.?, &value, 1)) else try self.propertyResult(zwv_zoom(self.native.?, &value, true));
        _ = try self.propertyWindow();
        self.zoom_override = factor;
    }
    pub fn zoom(self: *View) !f64 {
        _ = try self.propertyWindow();
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        var value: f64 = 0;
        if (is_linux) try webkit.check(webkit.zwk_zoom(self.native.?, &value, 0)) else try self.propertyResult(zwv_zoom(self.native.?, &value, false));
        _ = try self.propertyWindow();
        return value;
    }
    /// Empty resets the Runtime default. Success persists through recover;
    /// reload applies the new Options instead. Invalid input changes no state.
    pub fn setUserAgent(self: *View, agent: []const u8) !void {
        _ = try self.propertyWindow();
        if (!validUserAgent(agent)) return error.InvalidUserAgent;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const owned = try self.allocator.dupe(u8, agent);
        var transferred = false;
        errdefer if (!transferred) self.allocator.free(owned);
        const wide = if (is_linux) try self.allocator.dupeZ(u8, agent) else try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, agent);
        defer self.allocator.free(wide);
        _ = try self.propertyWindow();
        if (is_linux) try webkit.check(webkit.zwk_user_agent(self.native.?, wide.ptr, null)) else try self.propertyResult(zwv_user_agent(self.native.?, wide.ptr, null));
        _ = try self.propertyWindow();
        const previous = self.agent_override;
        self.agent_override = owned;
        transferred = true;
        if (previous) |old| self.allocator.free(old);
    }
    /// Caller owns the returned UTF-8. Native temporary storage is always freed.
    pub fn userAgent(self: *View, allocator: std.mem.Allocator) ![]u8 {
        _ = try self.propertyWindow();
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (is_linux) {
            var text: ?[*:0]u8 = null;
            try webkit.check(webkit.zwk_user_agent(self.native.?, null, &text));
            defer if (text) |value| webkit.zwk_string_free(value);
            _ = try self.propertyWindow();
            const result = try allocator.dupe(u8, std.mem.span(text orelse return error.InvalidUserAgent));
            errdefer allocator.free(result);
            _ = try self.propertyWindow();
            return result;
        }
        var wide: ?[*:0]u16 = null;
        const hr = zwv_user_agent(self.native.?, null, &wide);
        defer if (wide) |value| zwv_string_free(value);
        try self.propertyResult(hr);
        const value = wide orelse return error.InvalidUserAgent;
        var length: usize = 0;
        while (length <= 4096 and value[length] != 0) : (length += 1) {}
        if (length > 4096) return error.InvalidUserAgent;
        const result = try std.unicode.utf16LeToUtf8Alloc(allocator, value[0..length]);
        errdefer allocator.free(result);
        _ = try self.propertyWindow();
        return result;
    }
    pub fn setDevToolsEnabled(self: *View, enabled: bool) !void {
        _ = try self.propertyWindow();
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (is_linux) {
            try webkit.check(webkit.zwk_devtools(self.native.?, if (enabled) 1 else 2, null, null));
            _ = try self.propertyWindow();
            self.devtools_override = enabled;
            return;
        }
        var value = enabled;
        try self.propertyResult(zwv_devtools(self.native.?, &value, true, false));
        self.devtools_override = enabled;
    }
    pub fn devToolsEnabled(self: *View) !bool {
        _ = try self.propertyWindow();
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (is_linux) {
            var enabled: c_int = 0;
            try webkit.check(webkit.zwk_devtools(self.native.?, 0, &enabled, null));
            _ = try self.propertyWindow();
            return enabled != 0;
        }
        var value = false;
        try self.propertyResult(zwv_devtools(self.native.?, &value, false, false));
        return value;
    }
    /// Explicitly opens a native tool window; never called automatically.
    pub fn openDevTools(self: *View) !void {
        _ = try self.propertyWindow();
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (is_linux) {
            try webkit.check(webkit.zwk_devtools(self.native.?, 3, null, null));
            _ = try self.propertyWindow();
            return;
        }
        var value = false;
        const hr = zwv_devtools(self.native.?, &value, false, true);
        if (@as(u32, @bitCast(hr)) == 0x80070005) return error.DevToolsDisabled;
        try self.propertyResult(hr);
    }
    fn clearPropertyOverrides(self: *View) void {
        if (self.agent_override) |agent| self.allocator.free(agent);
        self.agent_override = null;
        self.zoom_override = null;
        self.devtools_override = null;
    }

    pub fn post(self: *View, message: []const u8) !void {
        return self.postWithPage(message, null);
    }
    fn postWithPage(self: *View, message: []const u8, page: ?u64) !void {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (!self.ready) return error.NotReady;
        if (message.len > 65536) return error.MessageTooLarge;
        if (std.mem.indexOfScalar(u8, message, 0) != null) return error.EmbeddedNul;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const utf16 = (if (is_linux) self.allocator.dupeZ(u8, message) else std.unicode.utf8ToUtf16LeAllocZ(self.allocator, message)) catch |err| {
            window.report(.{ .domain = .webview, .operation = .webview_post, .err = err });
            return err;
        };
        defer self.allocator.free(utf16);
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (page) |generation| {
            if (generation != self.page_generation or !self.page_active or self.recovering) return error.StalePage;
            if (self.loading) return error.PageLoading;
        }
        _ = try self.propertyWindow();
        if (is_linux) return webkit.check(webkit.zwk_post(self.native.?, utf16.ptr));
        self.last_hresult = zwv_post(self.native.?, utf16.ptr);
        if (@as(u32, @bitCast(self.last_hresult)) == 0x80070005) return error.IpcOriginDenied;
        if (self.last_hresult < 0) {
            window.report(.{ .domain = .hresult, .operation = .webview_post, .err = error.PostFailed, .code = @bitCast(self.last_hresult) });
            return error.PostFailed;
        }
    }

    /// Snapshot the currently accepted document, including an in-flight load.
    pub fn pageId(self: *const View) ?PageId {
        const window = self.access() orelse return null;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window) or !self.ready or !self.page_active) return null;
        return .{ .view = self, .generation = self.page_generation };
    }

    /// Host jobs/replies retain a PageId and reject a document replacement.
    /// The application must also reset its IPC session at every started event.
    pub fn postFor(self: *View, id: PageId, message: []const u8) !void {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (id.view != self or id.generation != self.page_generation or !self.page_active or self.recovering) return error.StalePage;
        if (self.loading) return error.PageLoading;
        try self.postWithPage(message, id.generation);
    }

    /// Navigate to an ASCII absolute resource path in the configured local site.
    /// This does not grant scripts permission for further navigation.
    pub fn navigateLocal(self: *View, path: []const u8) !void {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (!self.ready or self.recovering) return error.NotReady;
        if (!self.initializerNavigationAllowed()) return error.Busy;
        if (!validPath(path)) return error.InvalidResourcePath;
        if (self.config.?.options.local == null) return error.LocalSiteRequired;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        const generation = self.page_generation;
        if (is_linux) {
            const value = try self.allocator.dupeZ(u8, path);
            defer self.allocator.free(value);
            _ = try self.propertyWindow();
            if (self.page_generation != generation) return error.PageChanged;
            return webkit.check(webkit.zwk_navigate_local(self.native.?, value));
        }
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, path);
        defer self.allocator.free(wide);
        _ = try self.propertyWindow();
        if (!self.initializerNavigationAllowed()) return error.Busy;
        if (self.page_generation != generation) return error.PageChanged;
        self.last_hresult = zwv_navigate_local(self.native.?, wide.ptr);
        try self.navigationResult(window);
    }

    pub fn goBack(self: *View) !void {
        try self.pageAction(0);
    }
    pub fn navigateRemote(self: *View, uri: []const u8) !void {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (!self.ready or self.recovering) return error.NotReady;
        if (!self.initializerNavigationAllowed()) return error.Busy;
        if (self.config.?.options.remote == null) return error.RemotePageRequired;
        if (is_linux) {
            var origin: [1024]u8 = undefined;
            _ = try webkit_remote.canonicalUriOrigin(&origin, uri, false, self.config.?.options.remote.?.allow_insecure_loopback);
            const scope = self.beginCallback() orelse return error.Closed;
            defer scope.end();
            const text = try self.allocator.dupeZ(u8, uri);
            defer self.allocator.free(text);
            if (self.attachmentClosed() or appStopping(window)) return error.Closed;
            const result = webkit.zwk_navigate_remote(self.native.?, text);
            if (result == 8) return error.OriginDenied;
            return webkit.check(result);
        }
        var wide: [16385:0]u16 = undefined;
        const length = try uriWide(&wide, uri);
        wide[length] = 0;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.last_hresult = zwv_navigate_remote(self.native.?, &wide);
        if (@as(u32, @bitCast(self.last_hresult)) == 0x80070005) return error.OriginDenied;
        try self.navigationResult(window);
    }
    pub fn goForward(self: *View) !void {
        try self.pageAction(1);
    }
    pub fn refresh(self: *View) !void {
        try self.pageAction(2);
    }
    pub fn stop(self: *View) !void {
        try self.pageAction(3);
    }
    fn pageAction(self: *View, action: c_int) !void {
        const window = self.access() orelse return error.Closed;
        window.app.assertOwner();
        if (self.attachmentClosed() or appStopping(window)) return error.Closed;
        if (!self.ready or self.recovering) return error.NotReady;
        if (action != 3 and !self.initializerNavigationAllowed()) return error.Busy;
        const scope = self.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (action <= 1 and self.config.?.options.local == null and self.config.?.options.remote == null) return error.LocalSiteRequired;
        if (is_linux) return webkit.check(switch (action) {
            0 => webkit.zwk_history(self.native.?, 0),
            1 => webkit.zwk_history(self.native.?, 1),
            2 => webkit.zwk_refresh(self.native.?),
            else => webkit.zwk_stop(self.native.?),
        });
        if (action == 0 and !self.can_go_back or action == 1 and !self.can_go_forward) return error.NoHistory;
        self.last_hresult = zwv_page_action(self.native.?, action);
        try self.navigationResult(window);
    }
    fn navigationResult(self: *View, window: Access) !void {
        const hr = self.last_hresult;
        if (hr >= 0) return;
        if (@as(u32, @bitCast(hr)) == 0x8000000a) return error.NavigationPending;
        window.report(.{ .domain = .hresult, .operation = .webview_navigate, .err = error.NavigationFailed, .code = @bitCast(hr) });
        return error.NavigationFailed;
    }

    fn pageNotify(ptr: *anyopaque, native: *const NativePageEvent) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return 0;
        const scope = self.beginNativeAttachment() orelse return 0;
        defer scope.end();
        if (self.recovering or self.attachmentClosed() or appStopping(window)) return 0;
        if (is_linux and native.kind == 6) {
            // A native full-document transaction revokes the old logical page
            // before LOAD_STARTED. Stopping here must still finish its books.
            self.page_active = false;
            self.finishRequests(.page_changed, .page_changed, .page_changed, .page, null, true);
            return if (self.attachmentClosed() or appStopping(window) or self.recovering) 0 else 1;
        }
        if (is_linux and native.kind == 1 and native.flags & 1 == 0) if (self.native) |handle| {
            var failure: webkit.Failure = undefined;
            webkit.zwk_last_failure(handle, &failure);
            if (failure.domain != 0) self.last_native_failure = .{ .glib = failure };
        };
        if (native.kind == 0 and native.flags & 1 == 0) {
            if (self.page_generation == std.math.maxInt(u64)) {
                self.page_active = false;
                self.loading = false;
                self.finishRequests(.page_changed, .page_changed, .page_changed, .page, null, true);
                window.report(.{ .domain = .webview, .operation = .webview_navigate, .err = error.PageGenerationExhausted });
                return 0;
            }
            self.page_generation += 1;
            self.page_active = true;
        }
        const id: PageId = .{ .view = self, .generation = self.page_generation };
        switch (native.kind) {
            0 => self.loading = true,
            1 => {
                self.loading = false;
                if (native.flags & 1 == 0) self.page_active = false;
            },
            3 => if (native.flags & 1 == 0) {
                self.page_active = false;
                window.report(.{ .domain = .webview, .operation = .webview_navigate, .err = error.PageSourceRejected });
            },
            5 => {
                self.can_go_back = native.flags & 1 != 0;
                self.can_go_forward = native.flags & 2 != 0;
            },
            else => {},
        }
        if ((native.kind == 0 and native.flags & 1 == 0) or ((native.kind == 1 or native.kind == 3) and native.flags & 1 == 0)) self.finishRequests(.page_changed, .page_changed, .page_changed, .page, null, true);
        if (self.attachmentClosed() or appStopping(window) or self.recovering or self.page_generation != id.generation) return 0;
        const listener = self.config.?.options.page_listener orelse return 1;
        var utf8: ?[]u8 = null;
        defer if (utf8) |text| self.allocator.free(text);
        if (native.value) |value| {
            var length: usize = 0;
            while (length <= 16384 and value[length] != 0) : (length += 1) {}
            if (length > 16384) {
                window.report(.{ .domain = .webview, .operation = .utf8, .err = error.PageMetadataTooLarge });
            } else {
                utf8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, value[0..length]) catch |err| blk: {
                    window.report(.{ .domain = .webview, .operation = .utf8, .err = err });
                    break :blk null;
                };
            }
        }
        if (self.attachmentClosed() or appStopping(window) or self.recovering or self.page_generation != id.generation) return 0;
        const ev: PageEvent = switch (native.kind) {
            0 => .{ .started = .{ .id = id, .navigation_id = native.navigation_id, .uri = utf8, .redirected = native.flags & 1 != 0 } },
            1 => .{ .completed = .{ .id = id, .navigation_id = native.navigation_id, .success = native.flags & 1 != 0, .native_status = native.status } },
            2 => .{ .dom_ready = id },
            3 => .{ .source_changed = .{ .id = id, .uri = utf8 } },
            4 => .{ .title_changed = .{ .id = id, .title = utf8 } },
            5 => .{ .history_changed = .{ .id = id, .can_go_back = self.can_go_back, .can_go_forward = self.can_go_forward } },
            else => return 1,
        };
        listener.event(listener.context, self, ev);
        return if (self.attachmentClosed() or appStopping(window) or self.recovering or self.page_generation != id.generation) 0 else 1;
    }

    fn notify(ptr: *anyopaque, kind: c_int, value: ?[*:0]const u16, hr: i32) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        if (kind != 9 and (self.attachmentClosed() or appStopping(window))) return;
        const page = self.page_generation;
        switch (kind) {
            0 => {
                self.ready = true;
                self.failed = false;
                self.recovering = false;
                self.on_event(self.context, self, .ready);
            },
            1 => {
                if (!self.ready) return;
                const text = std.unicode.utf16LeToUtf8Alloc(self.allocator, std.mem.span(value.?)) catch |err| {
                    if (self.attachmentClosed() or appStopping(window) or self.recovering or self.page_generation != page) return;
                    window.report(.{ .domain = .webview, .operation = .utf8, .err = err });
                    if (self.attachmentClosed() or appStopping(window) or self.recovering or self.page_generation != page) return;
                    if (!is_linux) {
                        self.last_hresult = @bitCast(@as(u32, if (err == error.OutOfMemory) 0x8007000e else 0x8007000d));
                        self.on_event(self.context, self, .{ .failed = self.last_hresult });
                    }
                    return;
                };
                defer self.allocator.free(text);
                if (self.attachmentClosed() or appStopping(window) or self.recovering or !self.ready or self.page_generation != page) return;
                self.on_event(self.context, self, .{ .message = text });
            },
            3...7 => {
                var length: usize = 0;
                while (length <= 16384 and value.?[length] != 0) : (length += 1) {}
                if (length > 16384) {
                    window.report(.{ .domain = .webview, .operation = .utf8, .err = error.PolicyUriTooLarge });
                    return;
                }
                const text = std.unicode.utf16LeToUtf8Alloc(self.allocator, value.?[0..length]) catch |err| {
                    window.report(.{ .domain = .webview, .operation = .utf8, .err = err });
                    return;
                };
                defer self.allocator.free(text);
                if (self.attachmentClosed() or appStopping(window) or self.recovering or self.page_generation != page) return;
                self.on_event(self.context, self, .{ .policy_request = .{ .kind = @enumFromInt(kind - 3), .uri = text, .native_detail = hr } });
            },
            8 => {
                self.ready = false;
                self.page_active = false;
                self.loading = false;
                self.can_go_back = false;
                self.can_go_forward = false;
                self.failed = true;
                self.finishRequests(.unavailable, .unavailable, .unavailable, null, null, false);
                if (self.attachmentClosed() or appStopping(window) or self.recovering) return;
                window.report(.{ .domain = .webview, .operation = .webview_teardown, .code = @bitCast(hr) });
                if (self.attachmentClosed() or appStopping(window) or self.recovering) return;
                self.on_event(self.context, self, .{ .process_failed = .{ .native_kind = hr } });
            },
            9 => {
                if (self.attachmentClosed() or appStopping(window)) {
                    self.recovering = false;
                    return;
                }
                if (self.native) |native| nativeClose(native);
                self.native = null;
                if (self.pending_config == null) self.config.?.publishRecoveryContext();
                if (self.attachmentClosed() or appStopping(window)) return;
                if (self.pending_config) |candidate| {
                    const previous = self.config.?;
                    self.config = candidate;
                    self.pending_config = null;
                    self.clearPropertyOverrides();
                    previous.deinit(self.allocator);
                    if (self.attachmentClosed() or appStopping(window)) return;
                    self.on_event(self.context, self, .resources_released);
                    if (self.attachmentClosed() or window.app.phase == .stopping or window.app.phase == .stopped) return;
                }
                self.startNative(window) catch |err| {
                    self.recovering = false;
                    self.failed = true;
                    if (is_linux) {
                        window.report(.{ .domain = .webview, .operation = .webview_create, .err = err });
                        return;
                    }
                    self.last_hresult = if (err == error.WebViewCreationFailed) self.last_hresult else @bitCast(@as(u32, if (err == error.OutOfMemory) 0x8007000e else 0x8007000d));
                    window.report(.{ .domain = .webview, .operation = .webview_create, .err = err, .code = @bitCast(self.last_hresult) });
                    self.on_event(self.context, self, .{ .failed = self.last_hresult });
                };
            },
            else => {
                if (!is_linux) self.last_hresult = hr;
                self.ready = false;
                self.page_active = false;
                self.loading = false;
                self.can_go_back = false;
                self.can_go_forward = false;
                self.failed = true;
                self.recovering = false;
                self.finishRequests(.unavailable, .unavailable, .unavailable, null, null, false);
                if (self.attachmentClosed() or appStopping(window) or self.recovering) return;
                window.report(.{ .domain = if (is_linux) .webview else .hresult, .operation = .webview_create, .code = @bitCast(hr) });
                if (self.attachmentClosed() or appStopping(window) or self.recovering) return;
                self.on_event(self.context, self, .{ .failed = hr });
            },
        }
    }
    fn resource(ptr: *anyopaque, uri_wide: [*:0]const u16, method: [*:0]const u16, native_headers: [*]const NativeHeader, header_count: u32, native: *anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window)) return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        const config = self.config orelse return;
        const page = self.page_generation;
        const site = config.options.local orelse return;
        var parsed: ?resources.Method = null;
        inline for (.{ "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS" }, 0..) |name, i| if (std.mem.eql(u16, std.mem.span(method), std.unicode.utf8ToUtf16LeStringLiteral(name))) {
            parsed = @enumFromInt(i);
        };
        const verb = parsed orelse return;
        if (!site.methods.allows(verb) or header_count > 64) return;
        var header_rows: [64]resources.Header = undefined;
        var header_bytes: [16384]u8 = undefined;
        const headers = header_rows[0..header_count];
        var budget: usize = 0;
        for (headers, native_headers[0..header_count]) |*header, input| {
            var parts: [2][]const u8 = undefined;
            for ([_][*:0]const u16{ input.name, input.value }, 0..) |wide, part| {
                const start = budget;
                var index: usize = 0;
                while (index <= (if (part == 0) @as(usize, 64) else 2048) and wide[index] != 0) : (index += 1) {
                    if (budget == header_bytes.len or wide[index] > 126 or wide[index] < 32) return;
                    header_bytes[budget] = @intCast(wide[index]);
                    budget += 1;
                }
                if (index > (if (part == 0) @as(usize, 64) else 2048)) return;
                parts[part] = header_bytes[start..budget];
            }
            header.* = .{ .name = parts[0], .value = parts[1] };
            if (!resources.allowsHeader(site.request_headers, header.*)) return;
        }
        const uri = std.unicode.utf16LeToUtf8Alloc(self.allocator, std.mem.span(uri_wide)) catch |err| {
            window.report(.{ .domain = .webview, .operation = .utf8, .err = err });
            return;
        };
        defer self.allocator.free(uri);
        if (self.attachmentClosed() or appStopping(window) or self.page_generation != page) return;
        self.dispatchResource(native, uri, verb, headers);
    }
    fn webkitResource(ptr: *anyopaque, uri: [*:0]const u8, method: [*:0]const u8, native_headers: [*]const webkit.ResourceHeader, header_count: u32, native: *anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        const window = self.access() orelse return;
        if (self.attachmentClosed() or appStopping(window) or header_count > 64) return;
        const scope = self.beginNativeAttachment() orelse return;
        defer scope.end();
        const config = self.config orelse return;
        const site = config.options.local orelse return;
        var parsed: ?resources.Method = null;
        inline for (.{ "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS" }, 0..) |name, i| if (std.mem.eql(u8, std.mem.span(method), name)) {
            parsed = @enumFromInt(i);
        };
        const verb = parsed orelse return;
        if (!site.methods.allows(verb)) return;
        var rows: [64]resources.Header = undefined;
        var bytes: usize = 0;
        for (native_headers[0..header_count], rows[0..header_count]) |input, *output| {
            output.* = .{ .name = std.mem.span(input.name), .value = std.mem.span(input.value) };
            if (!resources.allowsHeader(site.request_headers, output.*)) return;
            bytes += output.name.len + output.value.len;
            if (bytes > 16384) return;
        }
        self.dispatchResource(native, std.mem.span(uri), verb, rows[0..header_count]);
    }
    // Both native adapters borrow request bytes only during this callback. The
    // common dispatcher keeps response and deferral semantics independent of URI ABI.
    fn dispatchResource(self: *View, native: *anyopaque, uri: []const u8, verb: resources.Method, headers: []const resources.Header) void {
        const config = self.config orelse return;
        const site = config.options.local orelse return;
        const prefix = config.prefix.?;
        if (!std.mem.startsWith(u8, uri, prefix)) return;
        var path = uri[prefix.len - 1 ..];
        if (std.mem.indexOfAny(u8, path, "?#")) |index| path = path[0..index];
        var responder: Responder = .{ .native = native, .window = self.window, .view = self, .max_bytes = @min(config.options.max_resource_bytes, config.options.resource_limits.max_response_bytes) };
        if (!site.dynamic_document and (verb == .get or verb == .head) and std.mem.eql(u8, path, site.start_path)) {
            responder.respond(.{ .mime = "text/html; charset=utf-8", .bytes = config.options.html }) catch {};
            return;
        }
        var low: usize = 0;
        var high = site.resources.len;
        while ((verb == .get or verb == .head) and low < high) {
            const index = low + (high - low) / 2;
            const item = site.resources[index];
            switch (std.mem.order(u8, path, item.path)) {
                .lt => high = index,
                .gt => low = index + 1,
                .eq => {
                    responder.respond(.{ .mime = item.mime, .bytes = item.bytes }) catch {};
                    return;
                },
            }
        }
        if (site.on_resource) |handler| {
            handler.handle(handler.context, .{ .uri = uri, .path = path, .method = verb, .headers = headers }, &responder);
        }
        if (!responder.responded) responder.respond(.{ .status = 404, .mime = "text/plain; charset=utf-8", .bytes = "Not found" }) catch {};
    }
    fn event(ptr: *anyopaque, _: z.Window, ev: z.Event) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        if (is_linux) return;
        switch (ev) {
            .resize => if (self.native) |native| {
                self.last_hresult = zwv_resize(native);
                if (self.last_hresult < 0 and !self.attachmentClosed()) if (self.access()) |window| window.report(.{ .domain = .hresult, .operation = .webview_geometry, .err = error.ViewportFailed, .code = @bitCast(self.last_hresult) });
            },
            .window_position => self.parentPosition(),
            else => {},
        }
    }
    fn detach(ptr: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        self.attachment_phase = .detaching;
        const initializer_controller = self.initializer_controller;
        self.initializer_controller = null;
        const initializer_domain = self.initializer_domain;
        self.initializer_domain = null;
        const initializer_delivery = if (initializer_controller) |controller| controller.book.detach() else null;
        if (initializer_controller) |controller| if (controller.book.pending) |pending| if (self.native) |native| {
            if (is_linux) webkit.zwk_initializers_cancel(native, pending.token) else zwv_initializers_cancel(native, pending.token);
        };
        self.eval_accepting = false;
        self.tool_accepting = false;
        self.resource_accepting = false;
        self.permission_accepting = false;
        self.download_accepting = false;
        if (is_linux) if (self.find_budget) |budget| webkit.zwk_find_budget_close(budget);
        if (is_linux) if (self.capture_budget) |budget| webkit.zwk_capture_budget_close(budget);
        self.finishRequests(.detached, .detached, .detached, null, null, false);
        if (!is_linux) if (self.eval_timer) |timer| zwv_eval_timer_close(timer);
        self.eval_timer = null;
        self.eval_watch = null;
        self.clearPropertyOverrides();
        if (self.native) |native| nativeClose(native);
        self.native = null;
        if (is_linux) if (self.find_budget) |budget| webkit.zwk_find_budget_release(budget);
        self.find_budget = null;
        if (is_linux) if (self.capture_budget) |budget| webkit.zwk_capture_budget_release(budget);
        self.capture_budget = null;
        if (self.file_budget) |budget| {
            if (is_linux) webkit.zwk_file_budget_release(budget) else zwv_file_budget_release(budget);
        }
        self.file_budget = null;
        if (is_linux) if (self.custom_local_budget) |budget| webkit.zwk_local_budget_release(budget);
        self.custom_local_budget = null;
        if (!is_linux) if (self.action_budget) |budget| zwv_action_budget_release(budget);
        self.action_budget = null;
        self.region = null;
        self.window = null;
        self.ready = false;
        self.page_active = false;
        self.loading = false;
        self.can_go_back = false;
        self.can_go_forward = false;
        self.failed = false;
        self.recovering = false;
        const previous_config = self.config;
        self.config = null;
        const pending_config = self.pending_config;
        self.pending_config = null;
        if (previous_config) |config| config.deinit(self.allocator);
        if (pending_config) |config| config.deinit(self.allocator);
        if (initializer_controller) |controller| controller.release();
        if (initializer_domain) |domain| initializer_owner.releaseDomain(domain);
        self.attachment_phase = .detached;
        if (initializer_delivery) |delivery| delivery.invoke();
    }
};

const HostRect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

fn testInitializerOwnedConfig(allocator: std.mem.Allocator) !void {
    defer std.debug.assert(std.meta.eql(initializerNativeCounts(), InitializerNativeCounts{}));
    var body = "window.owned='甲😀';return;".*;
    var origins = [_][]const u8{"HTTPS://EXAMPLE.test:443/"};
    var entries = [_]DocumentInitializer{.{ .body = &body, .origins = &origins }};
    const config = try OwnedConfig.initPortable(allocator, .{ .html = "", .user_data_folder = testProfilePath(), .document_initializers = &entries });
    defer config.deinit(allocator);
    @memset(&body, '?');
    entries[0].body = "throw Error('changed')";
    origins[0] = "http://changed.test";
    try std.testing.expectEqualStrings("window.owned='甲😀';return;", config.options.document_initializers[0].body);
    try std.testing.expectEqualStrings("https://example.test", config.options.document_initializers[0].origins[0]);
    const counts = initializerNativeCounts();
    try std.testing.expect(counts.budgets == 1 and counts.bytes != 0 and counts.owners == 0 and counts.handlers == 0);
}
test "optional initializer source owns and encodes input and every allocation failure releases its C domain" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testInitializerOwnedConfig, .{});
}
test "initializer configuration is cold by default and unsupported platforms reject before allocation" {
    try std.testing.expect((try initializer_owner.Config.create(std.testing.failing_allocator, &.{}, .{}, null)) == null);
    try std.testing.expectEqual(@import("builtin").os.tag == .windows or is_linux, backendCapabilities().document_initializers);
    if (@import("builtin").os.tag != .windows and !is_linux) {
        try std.testing.expectError(error.UnsupportedCapability, initializer_owner.Config.create(std.testing.failing_allocator, &.{.{ .body = "return;", .origins = &.{"https://example.test"} }}, .{}, null));
        try std.testing.expectError(error.UnsupportedCapability, initializer_owner.Controller.create(std.testing.failing_allocator, .{}, null, 0));
        try std.testing.expectError(error.UnsupportedCapability, OwnedConfig.init(std.testing.failing_allocator, .{ .html = "", .document_initializers = &.{.{ .body = "return;", .origins = &.{"https://example.test"} }} }));
    } else {
        try std.testing.expectError(error.InitializerBudgetExceeded, initializer_owner.Config.create(std.testing.allocator, &.{.{ .body = "return;", .origins = &.{"https://example.test"} }}, .{ .bytes = 1 }, null));
        try std.testing.expectError(error.InitializerBudgetExceeded, initializer_owner.Config.create(std.testing.allocator, &.{.{ .body = "return;", .origins = &.{"https://example.test"} }}, .{ .bytes = 128 }, null));
    }
    try std.testing.expectEqualDeep(InitializerNativeCounts{}, initializerNativeCounts());
}
test "initializer preparation pins an existing transaction controller across allocator close" {
    for ([_]bool{ false, true }) |close| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var probe: TestAllocationReentry = .{ .action = if (close) .close else .remove, .free_on_closed = true };
        try probe.setup(app);
        defer probe.cleanup(app);
        const view = probe.view.?;
        view.initializer_controller = try initializer_owner.Controller.create(view.allocator, .{}, null, 0);
        probe.armed = true;
        try std.testing.expectError(error.Closed, view.replaceDocumentInitializers(&.{.{ .body = "return;", .origins = &.{"https://example.test"} }}, .{ .context = &probe, .complete = TestAllocationReentry.initializer }));
        try std.testing.expect(probe.fired and probe.callbacks == 0);
        _ = try probe.window.destroy();
        try app.dispatch();
        try std.testing.expect(probe.closed == 1 and probe.view == null and probe.owner == null);
        try std.testing.expectEqualDeep(InitializerNativeCounts{}, initializerNativeCounts());
    }
}
test "initializer reservation gates host navigation and restart before touching native pointers" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: TestAllocationReentry = .{};
    try probe.setup(app);
    defer probe.cleanup(app);
    const view = probe.view.?;
    const controller = try initializer_owner.Controller.create(view.allocator, .{}, null, 0);
    view.initializer_controller = controller;
    const token = try controller.book.reserve(false);
    try std.testing.expectError(error.Busy, view.navigateLocal("/next"));
    try std.testing.expectError(error.Busy, view.navigateRemote("https://example.test/next"));
    try std.testing.expectError(error.Busy, view.goBack());
    try std.testing.expectError(error.Busy, view.goForward());
    try std.testing.expectError(error.Busy, view.refresh());
    try std.testing.expectError(error.Busy, view.reload(probe.options()));
    try std.testing.expectError(error.Busy, view.recover());
    try std.testing.expect(controller.book.abort(token));
}
test "empty logical initializer configuration retains the View domain and charges late physical owners" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    {
        var probe: TestAllocationReentry = .{};
        try probe.setup(app);
        defer probe.cleanup(app);
        const view = probe.view.?;
        const limits: InitializerLimits = .{ .bytes = 4096 };
        const original = (try initializer_owner.Config.create(view.allocator, &.{.{ .body = "return;", .origins = &.{"https://example.test"} }}, limits, null)).?;
        view.config.?.initializer_config = original;
        view.config.?.options.document_initializers = original.owned.entries;
        view.config.?.options.initializer_limits = limits;
        view.pinInitializerDomain(original.domain);
        const domain = original.domain;
        const account = original.owned.accounting;
        // Model an independently owned C allocation while the old logical
        // source still exists. Actual COM-extra-ref behavior has its C oracle.
        const held = limits.bytes - @as(usize, @intCast(initializerNativeCounts().bytes));
        account.retain();
        defer account.unref();
        try account.reserve(held);
        defer account.release(held);
        view.config.?.initializer_config = null;
        view.config.?.options.document_initializers = &.{};
        original.destroy();
        try std.testing.expect(view.initializer_controller == null and view.initializerDomain() == domain);
        const body = [_]u8{'a'} ** 2048;
        try std.testing.expectError(error.InitializerBudgetExceeded, initializer_owner.Config.create(view.allocator, &.{.{ .body = &body, .origins = &.{"https://example.test"} }}, limits, view.initializerDomain()));
        try std.testing.expectEqual(@as(u32, 1), initializerNativeCounts().budgets);
    }
    try std.testing.expectEqualDeep(InitializerNativeCounts{}, initializerNativeCounts());
}
test "uncertain initializer removal rejects reload and only explicit recovery clears its gate" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: TestAllocationReentry = .{};
    try probe.setup(app);
    defer probe.cleanup(app);
    const view = probe.view.?;
    const controller = try initializer_owner.Controller.create(view.allocator, .{}, null, 0);
    view.initializer_controller = controller;
    view.pinInitializerDomain(controller.domain);
    controller.book.unavailable = true;
    view.failed = true;
    view.ready = false;
    const original = view.config.?.storage.ptr;
    probe.armed = true;
    try std.testing.expectError(error.InitializerUnavailable, view.reload(probe.options()));
    try std.testing.expect(!probe.fired and view.pending_config == null and view.config.?.storage.ptr == original);
    probe.armed = false;
    try view.recover();
    try std.testing.expect(view.recovering and !controller.book.unavailable and view.config.?.storage.ptr == original);
}
const HostSnapshot = extern struct {
    parking: ?*anyopaque,
    bridge: ?*anyopaque,
    parent: ?*anyopaque,
    bounds: HostRect,
    epoch: u64,
    phase: c_int,
    visible: c_int,
    failure: i32,
    rollback_failure: i32,
};
extern fn zwv_page_host_create(u32, *?*anyopaque) i32;
extern fn zwv_page_host_snapshot(*anyopaque, *HostSnapshot) i32;
extern fn zwv_page_host_mount(*anyopaque, ?*anyopaque, HostRect, c_int, u64) i32;
extern fn zwv_page_host_park(*anyopaque, u64) i32;
extern fn zwv_page_host_resize_parked(*anyopaque, i32, i32, u64) i32;
extern fn zwv_page_host_restore(*anyopaque, *const HostSnapshot, u64) i32;
extern fn zwv_page_host_parent_destroying(*anyopaque, ?*anyopaque, u64) i32;
extern fn zwv_page_host_close(*?*anyopaque) i32;
extern fn zwv_page_host_counts(*u32, *u32, *u32) void;

pub const PageHostResourceCounts = struct { hosts: u32 = 0, parking_windows: u32 = 0, bridge_windows: u32 = 0 };
pub fn pageHostResourceCounts() PageHostResourceCounts {
    if (@import("builtin").os.tag != .windows) return .{};
    var result: PageHostResourceCounts = .{};
    zwv_page_host_counts(&result.hosts, &result.parking_windows, &result.bridge_windows);
    return result;
}

const SessionOptions = Options;
const SessionEvent = Event;
const SessionHooks = struct {
    pub const Options = SessionOptions;
    pub const Event = SessionEvent;
    pub fn open(session: *PageSession, options: SessionOptions, size: PageSession.PixelSize) anyerror!void {
        if (@import("builtin").os.tag != .windows and !is_linux) return error.UnsupportedCapability;
        session.page.session = session;
        session.page.attachment_phase = .attaching;
        if (size.width == 0 or size.height == 0 or size.width > std.math.maxInt(i32) or size.height > std.math.maxInt(i32)) return error.InvalidViewport;
        session.page.config = try OwnedConfig.initForApp(session.page.allocator, options, session.app.?);
        if (!session.accepts()) return error.Closed;
        try session.page.startNative(session.page.access().?);
        try session.page.config.?.checkProfile();
        session.page.attachment_phase = .attached;
    }
    pub fn closePage(session: *PageSession) void {
        View.detach(&session.page);
    }
    pub fn closeHost(session: *PageSession) anyerror!void {
        if (is_linux) {
            if (session.native_host != null) return error.UnsupportedCapability;
            return;
        }
        if (session.native_host != null) {
            try result(session, zwv_page_host_close(&session.native_host));
        }
        session.native_bridge = null;
    }
    fn result(session: *PageSession, hr: i32) anyerror!void {
        if (hr != 0) {
            session.last_hresult = hr;
            session.page.last_hresult = hr;
        }
        if (hr == @as(i32, @bitCast(@as(u32, 0x8004a101)))) return error.NativeGeometryNotApplied;
        if (hr < 0) return error.PageHostFailed;
        if (hr == 1) return error.StaleAttachment;
    }
    fn snapshot(session: *PageSession) anyerror!HostSnapshot {
        var value: HostSnapshot = undefined;
        try result(session, zwv_page_host_snapshot(session.native_host orelse return error.Closed, &value));
        return value;
    }
    fn ensureHost(session: *PageSession) anyerror!void {
        if (session.native_host != null) {
            const previous = try snapshot(session);
            if (previous.phase == 2) try closeHost(session);
        }
        if (session.native_host == null) {
            try result(session, zwv_page_host_create(@intCast(session.app.?.owner), &session.native_host));
            const initial = try snapshot(session);
            session.native_bridge = initial.bridge;
            try result(session, zwv_page_host_resize_parked(session.native_host.?, @intCast(session.last_size.width), @intCast(session.last_size.height), initial.epoch));
            session.parent_loss = null;
        }
    }
    fn visible(session: *PageSession) bool {
        if (session.attachment_phase == .detaching or session.attachment_phase == .detached) return false;
        const region = session.region orelse return false;
        const value = region.snapshot() catch return false;
        return value.viewport.visible and value.viewport.bounds.width > 0 and value.viewport.bounds.height > 0;
    }
    fn pageViewport(session: *PageSession, size: PageSession.PixelSize, is_visible: bool) anyerror!void {
        const native = session.page.native orelse return;
        const hr = zwv_session_viewport(native, @intCast(size.width), @intCast(size.height), is_visible);
        session.page.last_hresult = hr;
        session.last_hresult = hr;
        if (hr < 0) return error.ViewportFailed;
    }
    fn unavailable(session: *PageSession, hr: i32) void {
        const page = &session.page;
        page.ready = false;
        page.page_active = false;
        page.loading = false;
        page.failed = true;
        page.recovering = false;
        page.last_hresult = hr;
        if (session.phase == .closing) return;
        const previous = page.native;
        page.native = null;
        if (previous) |native| nativeClose(native);
        page.finishRequests(.unavailable, .unavailable, .unavailable, null, null, false);
        if (!session.accepts() or page.recovering) return;
        session.app.?.report(.{ .domain = if (is_linux) .webview else .hresult, .operation = .webview_geometry, .err = error.PageHostFailed, .code = if (is_linux) null else @as(u32, @bitCast(hr)) });
        if (session.accepts() and !page.recovering) page.on_event(page.context, page, .{ .failed = hr });
    }
    fn rollback(session: *PageSession, old: HostSnapshot, size: PageSession.PixelSize) void {
        if (session.native_host == null) return;
        var saved = old;
        const live = if (session.region) |region| blk: {
            _ = region.snapshot() catch break :blk false;
            break :blk session.attachment_phase != .detaching;
        } else false;
        if (saved.phase == 1 and !live) {
            saved.phase = 0;
            saved.parent = saved.parking;
            saved.visible = 0;
            saved.bounds = .{ .left = 0, .top = 0, .right = @intCast(size.width), .bottom = @intCast(size.height) };
        }
        const current = snapshot(session) catch {
            unavailable(session, session.last_hresult);
            return;
        };
        result(session, zwv_page_host_restore(session.native_host.?, &saved, current.epoch)) catch {
            unavailable(session, session.last_hresult);
            return;
        };
        pageViewport(session, size, saved.visible != 0) catch {
            unavailable(session, session.last_hresult);
            return;
        };
        session.last_size = size;
    }
    pub fn attach(session: *PageSession, region: z.composition.Region, value: z.composition.Snapshot) anyerror!void {
        session.page.window = value.window;
        session.page.region = region;
        errdefer {
            session.page.window = null;
            session.page.region = null;
        }
        try update(session, region, value.viewport, value);
    }
    pub fn update(session: *PageSession, region: z.composition.Region, viewport: z.composition.Viewport, value: z.composition.Snapshot) anyerror!void {
        if (is_linux) {
            const window_scope = value.window.beginCallback() orelse return error.Closed;
            defer window_scope.end();
            const native_window = window_scope.record.native.native orelse return error.Closed;
            const native = session.page.native orelse return error.NotReady;
            const edges = try View.viewportPixels(viewport.bounds, value.size.scale);
            _ = try region.snapshot();
            try webkit.check(webkit.zwk_session_mount(native, native_window, edges[0], edges[1], edges[2], edges[3], @intFromBool(viewport.visible), session.attachment_epoch));
            var actual: PageSession.PixelSize = undefined;
            try webkit.check(webkit.zwk_session_size(native, &actual.width, &actual.height));
            if (!session.accepts()) return error.Closed;
            _ = try region.snapshot();
            session.last_size = actual;
            return;
        }
        const old = try snapshot(session);
        const previous_size = session.last_size;
        const edges = try View.viewportPixels(viewport.bounds, value.size.scale);
        const size: PageSession.PixelSize = .{ .width = @intCast(edges[2] - edges[0]), .height = @intCast(edges[3] - edges[1]) };
        session.host_parent = value.window.nativeHandle();
        errdefer {
            const failure = session.last_hresult;
            rollback(session, old, previous_size);
            session.last_hresult = failure;
            session.page.last_hresult = failure;
        }
        if (!session.accepts()) return error.Closed;
        _ = try region.snapshot();
        try result(session, zwv_page_host_mount(session.native_host.?, session.host_parent, .{ .left = edges[0], .top = edges[1], .right = edges[2], .bottom = edges[3] }, @intFromBool(viewport.visible and size.width > 0 and size.height > 0), session.attachment_epoch));
        try pageViewport(session, size, viewport.visible and size.width > 0 and size.height > 0);
        if (!session.accepts()) return error.Closed;
        _ = try region.snapshot();
        session.last_size = size;
    }
    pub fn park(session: *PageSession) anyerror!void {
        if (is_linux) {
            if (session.page.native) |native| try webkit.check(webkit.zwk_session_park(native, session.attachment_epoch));
            return;
        }
        const old = try snapshot(session);
        if (old.phase == 0) {
            try pageViewport(session, session.last_size, false);
            return;
        }
        const size = session.last_size;
        errdefer {
            const failure = session.last_hresult;
            rollback(session, old, size);
            session.last_hresult = failure;
            session.page.last_hresult = failure;
        }
        try result(session, zwv_page_host_park(session.native_host.?, session.attachment_epoch));
        try pageViewport(session, size, false);
    }
    pub fn detach(session: *PageSession) void {
        if (!session.native_closed and !session.page_closed and (session.native_host != null or (is_linux and session.page.native != null))) {
            if (session.parent_loss) |hr| {
                unavailable(session, hr);
            } else park(session) catch {
                unavailable(session, session.last_hresult);
            };
        }
        session.page.window = null;
        session.page.region = null;
    }
    pub fn parentDestroying(session: *PageSession, _: z.composition.Region) void {
        session.page.window = null;
        session.page.region = null;
        if (is_linux) {
            if (session.page.native) |native| webkit.zwk_session_parent_destroying(native, session.attachment_epoch);
            return;
        }
        const host = session.native_host orelse return;
        const hr = zwv_page_host_parent_destroying(host, session.host_parent, session.attachment_epoch);
        if (hr < 0) {
            session.parent_loss = hr;
            session.last_hresult = hr;
        }
    }
    pub fn parentPosition(session: *PageSession) void {
        session.page.parentPosition();
    }
};

fn testProfilePath() []const u8 {
    return if (is_linux) "/ZigguratTest" else "C:\\ZigguratTest";
}

const TestSessionAllocation = struct {
    app: *z.App,
    window: z.Window,
    session: *PageSession = undefined,
    action: enum { close, quit, nested },
    return_null: bool,
    armed: bool = true,
    fired: bool = false,
    notifications: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn options() Options {
        if (is_linux) return .{ .html = "candidate", .storage = .ephemeral };
        return .{ .html = "candidate", .user_data_folder = testProfilePath() };
    }
    fn event(_: *anyopaque, _: *View, _: Event) void {}
    fn closed(context: *anyopaque, _: *PageSession) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.notifications += 1;
    }
    fn allocate(context: *anyopaque, size: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.armed) {
            self.armed = false;
            self.fired = true;
            switch (self.action) {
                .close => std.testing.expectEqual(PageSession.CloseResult.deferred, self.session.close() catch unreachable) catch unreachable,
                .quit => self.app.quit(),
                .nested => {
                    std.testing.expectError(error.AlreadyOpened, self.session.open(self.app, .{ .page = options() })) catch unreachable;
                    std.testing.expectError(error.ManagedSession, self.session.page.attach(self.window, options())) catch unreachable;
                },
            }
            if (self.return_null) return null;
        }
        return std.testing.allocator.rawAlloc(size, alignment, address);
    }
    fn resize(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) bool {
        return std.testing.allocator.rawResize(bytes, alignment, size, address);
    }
    fn remap(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) ?[*]u8 {
        return std.testing.allocator.rawRemap(bytes, alignment, size, address);
    }
    fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        std.testing.allocator.rawFree(bytes, alignment, address);
    }
};

test "Session config allocation close quit and nested open roll back before native submission" {
    for (0..5) |index| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        const before = pageHostResourceCounts();
        var context: TestSessionAllocation = .{ .app = app, .window = try app.createWindow(.{}), .action = if (index == 4) .nested else if (index >= 2) .quit else .close, .return_null = index % 2 == 0 };
        var session = PageSession.init(context.allocator(), &context, TestSessionAllocation.event);
        context.session = &session;
        const expected = if (context.return_null) error.OutOfMemory else error.Closed;
        try std.testing.expectError(expected, session.open(app, .{ .page = TestSessionAllocation.options(), .on_closed = .{ .context = &context, .notify = TestSessionAllocation.closed } }));
        try std.testing.expect(context.fired and context.notifications == 0 and session.phase == .closed);
        try std.testing.expect(session.page.config == null and session.native_host == null and session.page.native == null);
        try std.testing.expectEqualDeep(before, pageHostResourceCounts());
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
    }
}

fn testSessionPrepareFailure(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const before = pageHostResourceCounts();
    var context: u8 = 0;
    var session = PageSession.init(allocator, &context, TestSessionAllocation.event);
    // A real native geometry failure follows every configuration/UTF conversion
    // allocation but precedes Runtime creation, so all OOM paths are repeatable.
    session.open(app, .{ .page = TestSessionAllocation.options(), .initial_size = .{ .width = 100_000, .height = 100_000 } }) catch |err| {
        try std.testing.expect(session.phase == .closed and session.page.config == null and session.native_host == null and session.page.native == null);
        try std.testing.expectEqualDeep(before, pageHostResourceCounts());
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
        if (err == error.OutOfMemory) return err;
        try std.testing.expect(err == error.NativeGeometryNotApplied);
        try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x8004a101))), session.last_hresult);
        return;
    };
    return error.ExpectedGeometryFailure;
}

test "Session native preparation failure and every allocation failure release host and stop ownership" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testSessionPrepareFailure, .{});
}

test "public page lifetime scope delays owner free but never authorizes a closed or replaced page" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var context: TestAllocationReentry = .{ .action = .close, .free_on_closed = true };
    try context.setup(app);
    defer context.cleanup(app);
    const view = context.view.?;
    const id = view.pageId().?;
    try std.testing.expectError(error.StalePage, view.beginPageCallback(.{ .view = view, .generation = 2 }));
    const scope = try view.beginPageCallback(id);
    context.armed = true;
    const memory = try view.allocator.alloc(u8, 8);
    view.allocator.free(memory);
    try std.testing.expect(context.fired and context.view != null and context.owner != null and view.config != null);
    try std.testing.expectError(error.Closed, view.beginPageCallback(id));
    try std.testing.expectError(error.Closed, view.postFor(id, "{}"));
    scope.end();
    try app.dispatch();
    try std.testing.expect(context.view == null and context.owner == null and context.closed == 1);
}

fn prepareTestView(view: *View, app: *z.App, listener: ?PageListener) !z.Window {
    const window = try app.createWindow(.{});
    view.config = try OwnedConfig.initPortable(view.allocator, .{ .html = "", .user_data_folder = testProfilePath(), .page_listener = listener });
    errdefer {
        view.config.?.deinit(view.allocator);
        view.config = null;
    }
    try window.setContent(.{ .context = view, .event = View.event, .detach = View.detach });
    view.window = window;
    view.attachment_phase = .attached;
    view.ready = true;
    view.page_generation = 1;
    view.page_active = true;
    view.loading = true;
    return window;
}

const TestAllocationReentry = struct {
    action: enum { remove, close, page, nested } = .remove,
    window: z.Window = undefined,
    owner: ?*z.composition.Owner = null,
    region: z.composition.Region = undefined,
    other: z.composition.Region = undefined,
    view: ?*View = null,
    armed: bool = false,
    free_armed: bool = false,
    return_null: bool = false,
    fired: bool = false,
    free_on_closed: bool = false,
    require_config: bool = true,
    closed: usize = 0,
    denied: usize = 0,
    callbacks: usize = 0,
    expected_script: ScriptResult = .detached,
    expected_tool: tools.Result = .detached,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn options(self: *@This()) Options {
        return .{ .html = "old", .user_data_folder = testProfilePath(), .local = .{ .on_resource = .{ .context = self, .handle = handleResource } }, .tools = .{ .cookies = true, .pdf = true, .find = true } };
    }
    fn denyNested(self: *@This()) void {
        std.testing.expectError(error.AlreadyAttached, self.view.?.attachRegion(self.other, self.options())) catch unreachable;
        std.testing.expectError(error.AlreadyAttached, self.view.?.attach(self.window, self.options())) catch unreachable;
        self.denied += 2;
    }
    fn trigger(self: *@This()) void {
        self.fired = true;
        switch (self.action) {
            .remove => std.debug.assert(self.region.remove() catch unreachable),
            .close => std.debug.assert((self.window.destroy() catch unreachable) == .deferred),
            .page => {
                const starting: NativePageEvent = .{ .kind = 0, .navigation_id = 2, .flags = 0, .status = 0, .value = null };
                _ = View.pageNotify(self.view.?, &starting);
                const completed: NativePageEvent = .{ .kind = 1, .navigation_id = 2, .flags = 1, .status = 0, .value = null };
                _ = View.pageNotify(self.view.?, &completed);
            },
            .nested => self.denyNested(),
        }
        if (self.action == .remove or self.action == .close) std.debug.assert(self.view != null and (!self.require_config or self.view.?.config != null) and self.owner != null);
    }
    fn allocate(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            self.armed = false;
            self.trigger();
            if (self.return_null) return null;
        }
        return std.testing.allocator.rawAlloc(size, alignment, address);
    }
    fn resize(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) bool {
        return std.testing.allocator.rawResize(bytes, alignment, size, address);
    }
    fn remap(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) ?[*]u8 {
        return std.testing.allocator.rawRemap(bytes, alignment, size, address);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.free_armed) {
            self.free_armed = false;
            self.denyNested();
        }
        std.testing.allocator.rawFree(bytes, alignment, address);
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        if (!self.free_on_closed) return;
        self.owner.?.close() catch unreachable;
        self.owner = null;
        std.testing.allocator.destroy(self.view.?);
        self.view = null;
    }
    fn setup(self: *@This(), app: *z.App) !void {
        self.window = try app.createWindow(.{ .on_closed = .{ .context = self, .notify = onClosed } });
        self.owner = try z.composition.Owner.create(std.testing.allocator, self.window, .{ .capacity = 2 });
        self.region = try self.owner.?.reserve(.{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } });
        self.other = try self.owner.?.reserve(.{ .bounds = .{ .x = 10, .y = 0, .width = 10, .height = 10 } });
        self.view = try std.testing.allocator.create(View);
        self.view.?.* = View.init(self.allocator(), self, event);
        self.view.?.config = try OwnedConfig.initPortable(self.allocator(), self.options());
        try self.region.attach(.{ .context = self.view.?, .attach = attach, .update = update, .detach = View.regionDetach });
        self.view.?.attachment_phase = .attached;
        self.view.?.ready = true;
        self.view.?.page_active = true;
        self.view.?.page_generation = 1;
    }
    fn cleanup(self: *@This(), app: *z.App) void {
        self.armed = false;
        self.free_armed = false;
        _ = self.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
        if (self.owner) |owner| owner.close() catch unreachable;
        if (self.view) |view| std.testing.allocator.destroy(view);
    }
    fn attach(ptr: *anyopaque, region: z.composition.Region) !void {
        const view: *View = @ptrCast(@alignCast(ptr));
        view.region = region;
        view.window = (try region.snapshot()).window;
    }
    fn update(_: *anyopaque, _: z.composition.Region, _: z.composition.Viewport) !void {}
    fn event(ptr: *anyopaque, _: *View, _: Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.callbacks += 1;
    }
    fn handleResource(ptr: *anyopaque, _: ResourceRequest, _: *Responder) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.callbacks += 1;
    }
    fn script(ptr: *anyopaque, result: ScriptResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(std.meta.activeTag(result) == std.meta.activeTag(self.expected_script));
        self.callbacks += 1;
    }
    fn initializer(ptr: *anyopaque, result: InitializerResult) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(result == .detached);
        self.callbacks += 1;
    }
    fn tool(ptr: *anyopaque, result: tools.Result) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(std.meta.activeTag(result) == std.meta.activeTag(self.expected_tool));
        self.callbacks += 1;
    }
};

test "Find optional snapshots distinguish unknown from known zero and native absence" {
    try std.testing.expectEqualDeep(tools.FindState{}, View.findSnapshot(.{ .known = 0, .matches = 99, .active_index = -1 }));
    try std.testing.expectEqualDeep(tools.FindState{ .matches = 0 }, View.findSnapshot(.{ .known = 1, .matches = 0, .active_index = -1 }));
    try std.testing.expectEqualDeep(tools.FindState{ .matches = 2, .active_index = -1 }, View.findSnapshot(.{ .known = 3, .matches = 2, .active_index = -1 }));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(webkit.FindSnapshot));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(NativeFind));
}
test "Linux Find unsupported options reject before term reads allocation or existing session mutation" {
    if (!is_linux) return error.SkipZigTest;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: TestAllocationReentry = .{};
    try probe.setup(app);
    defer probe.cleanup(app);
    const view = probe.view.?;
    const unreadable: [*]const u8 = @ptrFromInt(4096);
    const token = try view.tool_book.reserve(.{ .token = 0, .kind = .find, .scope = .page, .page = 1, .deadline = null, .completion = .{ .context = &probe, .complete = TestAllocationReentry.tool } }, 1);
    view.find_token = token;
    probe.armed = true;
    for ([_]tools.FindOptions{ .{ .term = unreadable[0..1], .whole_word = true }, .{ .term = unreadable[0..1], .highlight_all = false } }) |options| {
        try std.testing.expectError(error.UnsupportedCapability, view.startFind(view.pageId().?, options, .{}, .{ .context = &probe, .complete = TestAllocationReentry.tool }));
        try std.testing.expect(!probe.fired and probe.callbacks == 0 and view.find_token == token and view.find_budget == null);
    }
    probe.armed = false;
    view.find_token = 0;
    try std.testing.expect(view.tool_book.take(token) != null);
}
test "Linux expired Find withdraws its logical session independently of physical native retirement" {
    if (!is_linux) return error.SkipZigTest;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: TestAllocationReentry = .{ .expected_tool = .timed_out };
    try probe.setup(app);
    defer probe.cleanup(app);
    const view = probe.view.?;
    const token = try view.tool_book.reserve(.{ .token = 0, .kind = .find, .scope = .page, .page = 1, .deadline = 5, .completion = .{ .context = &probe, .complete = TestAllocationReentry.tool } }, 1);
    view.find_token = token;
    view.find_listener = .{ .context = &probe, .changed = struct {
        fn changed(_: *anyopaque, _: tools.FindState) void {
            unreachable;
        }
    }.changed };
    view.finishRequests(.timed_out, .timed_out, .timed_out, null, 5, false);
    try std.testing.expect(probe.callbacks == 1 and view.find_token == 0 and view.find_listener == null and view.tool_book.take(token) == null);
    try std.testing.expectError(error.FindInactive, view.findState(view.pageId().?));
}
test "allocator remove or close rejects submissions before native calls and permits immediate owner release" {
    @setEvalBranchQuota(20000);
    const Operation = enum { reload, script, initializers, post, reply, navigate, agent, pdf, find, set_cookie, delete_cookie };
    const operations = comptime std.meta.tags(Operation);
    for ([_]bool{ false, true }) |close| inline for (operations) |operation| {
        if (comptime is_linux and (operation == .navigate or operation == .pdf or operation == .find or operation == .set_cookie or operation == .delete_cookie)) continue;
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var probe: TestAllocationReentry = .{ .action = if (close) .close else .remove, .free_on_closed = true };
        try probe.setup(app);
        defer probe.cleanup(app);
        const view = probe.view.?;
        const page = view.pageId().?;
        probe.armed = true;
        switch (operation) {
            .reload => try std.testing.expectError(error.Closed, view.reload(if (is_linux) .{ .html = "candidate", .storage = .ephemeral } else probe.options())),
            .script => try std.testing.expectError(error.Closed, view.evaluateJS("42", .{}, .{ .context = &probe, .complete = TestAllocationReentry.script })),
            .initializers => try std.testing.expectError(error.Closed, view.replaceDocumentInitializers(&.{.{ .body = "return;", .origins = &.{"https://example.test"} }}, .{ .context = &probe, .complete = TestAllocationReentry.initializer })),
            .post => try std.testing.expectError(error.Closed, view.post("late")),
            .reply => try std.testing.expectError(error.Closed, view.postFor(page, "late")),
            .navigate => try std.testing.expectError(error.Closed, view.navigateLocal("/next")),
            .agent => try std.testing.expectError(error.Closed, view.setUserAgent("agent")),
            .pdf => try std.testing.expectError(error.Closed, view.printToPdf(page, .{ .path = "C:\\Private\\out.pdf", .accept_overwrite = true }, .{}, .{ .context = &probe, .complete = TestAllocationReentry.tool })),
            .find => try std.testing.expectError(error.Closed, view.startFind(page, .{ .term = "text" }, .{}, .{ .context = &probe, .complete = TestAllocationReentry.tool })),
            .set_cookie => try std.testing.expectError(error.Closed, view.setCookie("https://example.test", .{ .name = "n", .value = "v", .accept_cookie_scope = true })),
            .delete_cookie => try std.testing.expectError(error.Closed, view.deleteCookie("https://example.test", .{ .name = "n", .path = "/", .accept_cookie_scope = true })),
        }
        try std.testing.expect(probe.fired and probe.callbacks == 0);
        _ = try probe.window.destroy();
        try app.dispatch();
        try std.testing.expect(probe.closed == 1 and probe.view == null and probe.owner == null);
    };
}

test "allocator cannot attach a second owner during installation or teardown" {
    if (is_linux) return error.SkipZigTest;
    @setEvalBranchQuota(20000);
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: TestAllocationReentry = .{};
    try probe.setup(app);
    defer probe.cleanup(app);
    probe.free_armed = true;
    try std.testing.expect(try probe.region.remove());
    try std.testing.expectEqual(@as(usize, 2), probe.denied);
    const view = probe.view.?;
    try std.testing.expect(view.attachment_phase == .detached);
    probe.action = .nested;
    probe.return_null = true;
    probe.armed = true;
    try std.testing.expectError(error.OutOfMemory, view.attachRegion(probe.other, probe.options()));
    try std.testing.expect(view.attachment_phase == .detached and view.config == null and view.window == null);
    const legacy = try app.createWindow(.{});
    probe.armed = true;
    try std.testing.expectError(error.OutOfMemory, view.attach(legacy, probe.options()));
    try std.testing.expectEqual(@as(usize, 6), probe.denied);
    try std.testing.expect(view.attachment_phase == .detached and view.config == null and view.window == null);
}

test "outer attachment scopes finish construction rollback before on_closed releases their owners" {
    if (is_linux) return error.SkipZigTest;
    for ([_]bool{ false, true }) |region_mode| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var probe: TestAllocationReentry = .{ .action = .close, .free_on_closed = true, .require_config = false };
        try probe.setup(app);
        defer probe.cleanup(app);
        try std.testing.expect(try probe.region.remove());
        const view = probe.view.?;
        probe.armed = true;
        if (region_mode) {
            try std.testing.expectError(error.Closed, view.attachRegion(probe.other, probe.options()));
        } else {
            try std.testing.expectError(error.Closed, view.attach(probe.window, probe.options()));
        }
        try app.dispatch();
        try std.testing.expect(probe.fired and probe.closed == 1 and probe.view == null and probe.owner == null);
    }
}

test "conversion allocation invalidation terminates taken slots and suppresses fresh handlers" {
    @setEvalBranchQuota(20000);
    const Kind = enum { script, cookies, message, policy, resource };
    for ([_]bool{ false, true }) |new_page| for ([_]bool{ false, true }) |allocation_fails| inline for (std.meta.tags(Kind)) |kind| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var probe: TestAllocationReentry = .{ .action = if (new_page) .page else .remove, .return_null = allocation_fails, .expected_script = if (new_page) .page_changed else .detached, .expected_tool = if (!new_page) .detached else if (allocation_fails) .out_of_memory else .{ .cookies = &.{} } };
        try probe.setup(app);
        defer probe.cleanup(app);
        const view = probe.view.?;
        probe.armed = true;
        switch (kind) {
            .script => {
                const token = try view.eval_book.reserve(1, null, .{ .context = &probe, .complete = TestAllocationReentry.script }, 1);
                View.scriptNotify(view, token, 0, std.unicode.utf8ToUtf16LeStringLiteral("42"));
            },
            .cookies => {
                const text = std.unicode.utf8ToUtf16LeStringLiteral("text");
                const cookie: NativeCookie = .{ .name = text, .value = text, .domain = text, .path = text, .expires = 0, .flags = 0, .same_site = 1 };
                const token = try view.tool_book.reserve(.{ .token = 0, .kind = .cookies, .scope = .profile, .page = 1, .deadline = null, .completion = .{ .context = &probe, .complete = TestAllocationReentry.tool } }, 1);
                View.toolNotify(view, token, 0, 0, &cookie, 1);
            },
            .message => View.notify(view, 1, std.unicode.utf8ToUtf16LeStringLiteral("message"), 0),
            .policy => View.notify(view, 3, std.unicode.utf8ToUtf16LeStringLiteral("https://example.test/"), 0),
            .resource => View.resource(view, std.unicode.utf8ToUtf16LeStringLiteral("https://app.ziggurat.invalid/unknown"), std.unicode.utf8ToUtf16LeStringLiteral("GET"), undefined, 0, @ptrFromInt(1)),
        }
        try std.testing.expect(probe.fired);
        try std.testing.expectEqual(@as(usize, if (kind == .script or kind == .cookies) 1 else 0), probe.callbacks);
    };
}

test "page-bound submissions reject allocator navigation before accepting a new context" {
    @setEvalBranchQuota(20000);
    const Kind = enum { script, reply, pdf, find };
    const kinds = comptime std.meta.tags(Kind);
    inline for (kinds) |kind| {
        if (comptime is_linux and (kind == .pdf or kind == .find)) continue;
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var probe: TestAllocationReentry = .{ .action = .page };
        try probe.setup(app);
        defer probe.cleanup(app);
        const view = probe.view.?;
        const page = view.pageId().?;
        probe.armed = true;
        switch (kind) {
            .script => try std.testing.expectError(error.StalePage, view.evaluateJS("42", .{}, .{ .context = &probe, .complete = TestAllocationReentry.script })),
            .reply => try std.testing.expectError(error.StalePage, view.postFor(page, "late")),
            .pdf => try std.testing.expectError(error.StalePage, view.printToPdf(page, .{ .path = "C:\\Private\\out.pdf", .accept_overwrite = true }, .{}, .{ .context = &probe, .complete = TestAllocationReentry.tool })),
            .find => try std.testing.expectError(error.StalePage, view.startFind(page, .{ .term = "text" }, .{}, .{ .context = &probe, .complete = TestAllocationReentry.tool })),
        }
        try std.testing.expect(probe.fired and probe.callbacks == 0);
    }
}

test "viewport conversion rounds edges at DPI and rejects native integer overflow" {
    const rect: z.Rect = .{ .x = -1.5, .y = 3.5, .width = 100.25, .height = 20.5 };
    try std.testing.expectEqual([_]i32{ -2, 4, 123, 30 }, try View.viewportPixels(rect, 1.25));
    try std.testing.expectError(error.InvalidViewport, View.viewportPixels(rect, 0));
    try std.testing.expectError(error.InvalidViewport, View.viewportPixels(rect, std.math.nan(f32)));
    try std.testing.expectError(error.InvalidViewport, View.viewportPixels(.{ .x = -500000, .y = 0, .width = 1000000, .height = 1 }, 3000));
    try std.testing.expectError(error.InvalidViewport, View.viewportPixels(.{ .x = 1000000, .y = 0, .width = 1, .height = 1 }, 3000));
}

test "removed region rejects every entry while its callback keeps all five books alive" {
    if (is_linux) return error.SkipZigTest;
    const Probe = struct {
        view: *View,
        calls: [5]u8 = @splat(0),
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn attach(ptr: *anyopaque, region: z.composition.Region) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.view.region = region;
            self.view.window = (try region.snapshot()).window;
        }
        fn update(_: *anyopaque, _: z.composition.Region, _: z.composition.Viewport) !void {}
        fn detach(ptr: *anyopaque, _: z.composition.Region) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            View.detach(self.view);
        }
        fn check(self: *@This(), index: usize) void {
            for (self.view.eval_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.tool_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.resource_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.permission_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.download_book.slots) |slot| std.debug.assert(slot == null);
            std.debug.assert(self.view.config != null and self.view.attachmentClosed());
            self.calls[index] += 1;
        }
        fn script(ptr: *anyopaque, result: ScriptResult) void {
            std.debug.assert(result == .detached);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.check(0);
        }
        fn tool(ptr: *anyopaque, result: tools.Result) void {
            std.debug.assert(result == .detached);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.check(1);
        }
        fn resource(ptr: *anyopaque, result: resources.Result) void {
            std.debug.assert(result == .detached);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.check(2);
        }
        fn permission(ptr: *anyopaque, result: permissions.Result) void {
            std.debug.assert(result == .detached);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.check(3);
        }
        fn download(ptr: *anyopaque, result: downloads.Result) void {
            std.debug.assert(result == .detached);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.check(4);
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const owner = try z.composition.Owner.create(std.testing.allocator, window, .{ .capacity = 1 });
    defer owner.close() catch unreachable;
    defer _ = window.destroy() catch unreachable;
    const region = try owner.reserve(.{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } });
    var view: View = undefined;
    var probe: Probe = .{ .view = &view };
    view = View.init(std.testing.allocator, &probe, Probe.event);
    view.config = try OwnedConfig.initPortable(view.allocator, .{ .html = "", .user_data_folder = testProfilePath() });
    try region.attach(.{ .context = &probe, .attach = Probe.attach, .update = Probe.update, .detach = Probe.detach });
    view.ready = true;
    view.page_active = true;
    view.page_generation = 1;
    view.eval_clock = try std.time.Timer.start();
    const script = try view.eval_book.reserve(1, 100, .{ .context = &probe, .complete = Probe.script }, 1);
    const tool = try view.tool_book.reserve(.{ .token = 0, .kind = .cookies, .scope = .profile, .page = 1, .deadline = 100, .completion = .{ .context = &probe, .complete = Probe.tool } }, 1);
    const resource_id = try view.resource_book.reserve(.{ .page = 1, .deadline = 100, .completion = .{ .context = &probe, .complete = Probe.resource } }, 1);
    const permission = try view.permission_book.reserve(.{ .page = 1, .deadline = 100, .completion = .{ .context = &probe, .complete = Probe.permission } }, 1);
    const download = try view.download_book.reserve(.{ .observed_page = 1, .deadline = 100, .completion = .{ .context = &probe, .complete = Probe.download } }, 1);
    const scope = view.beginCallback().?;
    try std.testing.expect(try region.remove());
    try std.testing.expect(!window.isClosed() and view.config != null and view.region != null and view.pageId() == null);
    try std.testing.expectError(error.Closed, view.postFor(.{ .view = &view, .generation = 1 }, "late"));
    try std.testing.expectError(error.Closed, view.cancelEvaluation(script));
    try std.testing.expectError(error.Closed, view.cancelTool(tool));
    try std.testing.expectError(error.Closed, view.cancelRequest(.{ .view = &view, .token = resource_id, .page = 1 }));
    try std.testing.expectError(error.Closed, view.cancelPermission(.{ .view = &view, .token = permission, .page = 1 }));
    try std.testing.expectError(error.Closed, view.cancelDownload(.{ .view = &view, .token = download }));
    try std.testing.expectError(error.Closed, view.setZoom(1));
    View.scriptNotify(&view, script, 0, null);
    View.toolNotify(&view, tool, 0, 0, null, 0);
    View.downloadNotify(&view, download, 1, 10, 10, 0);
    View.evalTimeout(&view);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, &probe.calls);
    scope.end();
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1 }, &probe.calls);
    try std.testing.expect(view.config == null and view.region == null and view.window == null and !window.isClosed());
}

test "region attach allocation failures roll back without taking the Content slot" {
    if (is_linux) return error.SkipZigTest;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const owner = try z.composition.Owner.create(std.testing.allocator, window, .{ .capacity = 1 });
    defer owner.close() catch unreachable;
    defer _ = window.destroy() catch unreachable;
    const region = try owner.reserve(.{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } });
    var marker: u8 = 0;
    for (0..2) |index| {
        var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        var view = View.init(fault.allocator(), &marker, struct {
            fn event(_: *anyopaque, _: *View, _: Event) void {}
        }.event);
        try std.testing.expectError(error.OutOfMemory, view.attachRegion(region, .{ .html = "text", .user_data_folder = testProfilePath() }));
        try std.testing.expect(view.window == null and view.region == null and view.config == null and view.native == null);
        _ = try region.snapshot();
        try std.testing.expectEqual(fault.allocated_bytes, fault.freed_bytes);
    }
}

test "failed completion invalidates replies even when an old document remains" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var marker: u8 = 0;
    var view = View.init(std.testing.allocator, &marker, struct {
        fn event(_: *anyopaque, _: *View, _: Event) void {}
    }.event);
    _ = try prepareTestView(&view, app, null);
    const id = view.pageId().?;
    const completion: NativePageEvent = .{ .kind = 1, .navigation_id = 42, .flags = 0, .status = 14, .value = null };
    try std.testing.expectEqual(1, View.pageNotify(&view, &completion));
    try std.testing.expect(!view.loading and !view.page_active);
    try std.testing.expect(view.pageId() == null);
    // No controller exists here: rejecting before zwv_post is essential.
    try std.testing.expectError(error.StalePage, view.postFor(id, "sensitive reply"));
}

test "untrusted source and generation exhaustion fail closed" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var marker: u8 = 0;
    var view = View.init(std.testing.allocator, &marker, struct {
        fn event(_: *anyopaque, _: *View, _: Event) void {}
    }.event);
    _ = try prepareTestView(&view, app, null);
    const id = view.pageId().?;
    const source: NativePageEvent = .{ .kind = 3, .navigation_id = 42, .flags = 0, .status = 0, .value = null };
    try std.testing.expectEqual(1, View.pageNotify(&view, &source));
    try std.testing.expectError(error.StalePage, view.postFor(id, "reply"));
    view.page_generation = std.math.maxInt(u64);
    const start: NativePageEvent = .{ .kind = 0, .navigation_id = 43, .flags = 0, .status = 0, .value = null };
    try std.testing.expectEqual(0, View.pageNotify(&view, &start));
    try std.testing.expectEqual(std.math.maxInt(u64), view.page_generation);
    try std.testing.expect(!view.page_active and !view.loading);
}

test "page callback close retains config until callback pin unwinds" {
    const Probe = struct {
        called: bool = false,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn page(ptr: *anyopaque, view: *View, value: PageEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(value == .started);
            self.called = true;
            const result = view.window.?.destroy() catch unreachable;
            std.debug.assert(result == .deferred and view.config != null);
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{};
    var view = View.init(std.testing.allocator, &probe, Probe.event);
    _ = try prepareTestView(&view, app, .{ .context = &probe, .event = Probe.page });
    const start: NativePageEvent = .{ .kind = 0, .navigation_id = 43, .flags = 0, .status = 0, .value = null };
    try std.testing.expectEqual(0, View.pageNotify(&view, &start));
    try std.testing.expect(probe.called and view.window.?.isClosed() and view.config != null);
    try app.dispatch();
    try std.testing.expect(probe.called and view.window == null and view.config == null);
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
}

test "script timer preparation failure preserves submitted context ownership" {
    const Probe = struct {
        calls: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn complete(ptr: *anyopaque, _: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{};
    var view = View.init(std.testing.allocator, &probe, Probe.event);
    const window = try prepareTestView(&view, app, null);
    view.loading = false;
    // The test backend intentionally has no native waits. Timer preparation
    // fails before any controller or script submission can be touched.
    try std.testing.expectError(if (is_linux) error.Closed else error.UnsupportedCapability, view.evaluateJS("42", .{ .timeout_ms = 5 }, .{ .context = &probe, .complete = Probe.complete }));
    try std.testing.expectEqual(0, probe.calls);
    try std.testing.expect(view.eval_accepting);
    var tokens: [evaluations.capacity]u64 = undefined;
    try std.testing.expectEqual(0, view.eval_book.tokens(&tokens, null).len);
    _ = try window.destroy();
    try std.testing.expect(view.eval_timer == null);
}

test "production page notify cancels old script slots before application callbacks" {
    const Probe = struct {
        calls: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn complete(ptr: *anyopaque, result: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .page_changed);
            self.calls += 1;
        }
        fn page(ptr: *anyopaque, view: *View, _: PageEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.calls == 1 and view.loading);
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{};
    var view = View.init(std.testing.allocator, &probe, Probe.event);
    _ = try prepareTestView(&view, app, .{ .context = &probe, .event = Probe.page });
    _ = try view.eval_book.reserve(view.page_generation, null, .{ .context = &probe, .complete = Probe.complete }, 1);
    const start: NativePageEvent = .{ .kind = 0, .navigation_id = 43, .flags = 0, .status = 0, .value = null };
    try std.testing.expectEqual(1, View.pageNotify(&view, &start));
    try std.testing.expectEqual(1, probe.calls);
}

test "private document preparation takes logical books without a public page generation" {
    if (!is_linux) return error.SkipZigTest;
    const Probe = struct {
        view: *View,
        generation: u64 = 0,
        calls: [3]u32 = @splat(0),
        pages: u32 = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn page(ptr: *anyopaque, _: *View, _: PageEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.pages += 1;
        }
        fn taken(self: *@This()) void {
            std.debug.assert(self.view.pageId() == null);
            std.debug.assert(self.view.page_generation == self.generation);
            for (self.view.eval_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.tool_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.resource_book.slots) |slot| std.debug.assert(slot == null);
        }
        fn script(ptr: *anyopaque, result: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .page_changed);
            self.taken();
            self.calls[0] += 1;
        }
        fn tool(ptr: *anyopaque, result: tools.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .page_changed);
            self.taken();
            self.calls[1] += 1;
        }
        fn resource(ptr: *anyopaque, result: resources.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .page_changed);
            self.taken();
            self.calls[2] += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var view: View = undefined;
    var probe: Probe = .{ .view = &view };
    view = View.init(std.testing.allocator, &probe, Probe.event);
    _ = try prepareTestView(&view, app, .{ .context = &probe, .event = Probe.page });
    view.loading = false;
    probe.generation = view.page_generation;
    const id = view.pageId().?;
    _ = try view.eval_book.reserve(probe.generation, null, .{ .context = &probe, .complete = Probe.script }, 1);
    _ = try view.tool_book.reserve(.{ .token = 0, .kind = .pdf, .scope = .page, .page = probe.generation, .deadline = null, .completion = .{ .context = &probe, .complete = Probe.tool } }, 1);
    _ = try view.resource_book.reserve(.{ .page = probe.generation, .deadline = 1000, .completion = .{ .context = &probe, .complete = Probe.resource } }, 1);
    const invalidated: NativePageEvent = .{ .kind = 6, .navigation_id = 43, .flags = 0, .status = 0, .value = null };
    try std.testing.expectEqual(1, View.pageNotify(&view, &invalidated));
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1 }, &probe.calls);
    try std.testing.expectEqual(0, probe.pages);
    try std.testing.expect(!view.loading and !view.page_active);
    try std.testing.expectError(error.StalePage, view.postFor(id, "old document"));
    try std.testing.expectEqual(1, View.pageNotify(&view, &invalidated));
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1 }, &probe.calls);
    const started: NativePageEvent = .{ .kind = 0, .navigation_id = 44, .flags = 0, .status = 0, .value = null };
    try std.testing.expectEqual(1, View.pageNotify(&view, &started));
    try std.testing.expectEqual(probe.generation + 1, view.pageId().?.generation);
    try std.testing.expectEqual(1, probe.pages);
}

test "page cancellation completion close reload or quit suppresses the old listener" {
    const Action = enum { destroy, reload, quit };
    const Probe = struct {
        view: *View,
        action: Action,
        completed: usize = 0,
        listeners: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn page(ptr: *anyopaque, _: *View, _: PageEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.listeners += 1;
        }
        fn complete(ptr: *anyopaque, result: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .page_changed);
            self.completed += 1;
            switch (self.action) {
                .reload => self.view.reload(if (is_linux) .{ .html = "", .storage = .ephemeral } else .{ .html = "", .user_data_folder = testProfilePath() }) catch unreachable,
                .destroy => _ = self.view.window.?.destroy() catch unreachable,
                .quit => self.view.window.?.app.quit(),
            }
        }
    };
    for (std.enums.values(Action)) |action| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var view: View = undefined;
        var probe: Probe = .{ .view = &view, .action = action };
        view = View.init(std.testing.allocator, &probe, Probe.event);
        _ = try prepareTestView(&view, app, .{ .context = &probe, .event = Probe.page });
        _ = try view.eval_book.reserve(view.page_generation, null, .{ .context = &probe, .complete = Probe.complete }, 1);
        const start: NativePageEvent = .{ .kind = 0, .navigation_id = 43, .flags = 0, .status = 0, .value = null };
        try std.testing.expectEqual(0, View.pageNotify(&view, &start));
        try std.testing.expectEqual(1, probe.completed);
        try std.testing.expectEqual(0, probe.listeners);
        // Prevent the queued recreation from constructing a real controller.
        app.quit();
        try app.dispatch();
        // A stopping dispatcher drains accepted work but leaves deferred
        // windows for the Stop-before-destroy shutdown pass.
        try app.finishShutdown();
        try std.testing.expect(view.window == null);
        try std.testing.expectEqual(1, probe.completed);
        try std.testing.expectEqual(0, probe.listeners);
    }
}

test "script rearm failure completion close prevents another stale success" {
    const Probe = struct {
        view: *View,
        quit: bool,
        current: usize = 0,
        other: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn currentComplete(ptr: *anyopaque, result: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .detached);
            self.current += 1;
        }
        fn otherComplete(ptr: *anyopaque, result: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .timer_failed);
            self.other += 1;
            if (self.quit) self.view.window.?.app.quit() else _ = self.view.window.?.destroy() catch unreachable;
        }
    };
    for ([_]bool{ false, true }) |quit| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var view: View = undefined;
        var probe: Probe = .{ .view = &view, .quit = quit };
        view = View.init(std.testing.allocator, &probe, Probe.event);
        _ = try prepareTestView(&view, app, null);
        view.loading = false;
        view.eval_clock = try std.time.Timer.start();
        const token = try view.eval_book.reserve(view.page_generation, null, .{ .context = &probe, .complete = Probe.currentComplete }, 2);
        _ = try view.eval_book.reserve(view.page_generation, 0, .{ .context = &probe, .complete = Probe.otherComplete }, 2);
        // Unsupported test-backend native waits force the production rearm path.
        View.scriptNotify(&view, token, 0, std.unicode.utf8ToUtf16LeStringLiteral("\"must-not-deliver\""));
        try std.testing.expectEqual(1, probe.current);
        try std.testing.expectEqual(1, probe.other);
        try app.dispatch();
        if (view.window) |window| _ = try window.destroy();
        try std.testing.expect(view.window == null);
    }
}

test "quit detaches all deadline books without trying to rearm a stopping App" {
    const Probe = struct {
        view: *View,
        script: usize = 0,
        tool: usize = 0,
        resource: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn scriptComplete(ptr: *anyopaque, result: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .detached);
            for (self.view.eval_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.tool_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.resource_book.slots) |slot| std.debug.assert(slot == null);
            self.script += 1;
        }
        fn toolComplete(ptr: *anyopaque, result: tools.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .detached);
            self.tool += 1;
        }
        fn resourceComplete(ptr: *anyopaque, result: resources.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .detached);
            self.resource += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var view: View = undefined;
    var probe: Probe = .{ .view = &view };
    view = View.init(std.testing.allocator, &probe, Probe.event);
    _ = try prepareTestView(&view, app, null);
    view.eval_clock = try std.time.Timer.start();
    _ = try view.eval_book.reserve(view.page_generation, 1000, .{ .context = &probe, .complete = Probe.scriptComplete }, 1);
    _ = try view.tool_book.reserve(.{ .token = 0, .kind = .cookies, .scope = .profile, .page = view.page_generation, .deadline = 1000, .completion = .{ .context = &probe, .complete = Probe.toolComplete } }, 1);
    _ = try view.resource_book.reserve(.{ .page = view.page_generation, .deadline = 1000, .completion = .{ .context = &probe, .complete = Probe.resourceComplete } }, 1);
    app.quit();
    try app.dispatch();
    _ = try view.window.?.destroy();
    try std.testing.expectEqual(1, probe.script);
    try std.testing.expectEqual(1, probe.tool);
    try std.testing.expectEqual(1, probe.resource);
    try std.testing.expect(view.window == null and view.eval_timer == null);
    try std.testing.expect(view.eval_watch == null);
}

test "native completion after quit before window destruction preserves detached reasons" {
    const Probe = struct {
        script: ?std.meta.Tag(ScriptResult) = null,
        tool: ?std.meta.Tag(tools.Result) = null,
        resource: ?std.meta.Tag(resources.Result) = null,
        calls: [3]u32 = @splat(0),
        events: u32 = 0,
        pages: u32 = 0,
        fn event(ptr: *anyopaque, _: *View, _: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.events += 1;
        }
        fn page(ptr: *anyopaque, _: *View, _: PageEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.pages += 1;
        }
        fn scriptComplete(ptr: *anyopaque, result: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.script = std.meta.activeTag(result);
            self.calls[0] += 1;
        }
        fn toolComplete(ptr: *anyopaque, result: tools.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.tool = std.meta.activeTag(result);
            self.calls[1] += 1;
        }
        fn resourceComplete(ptr: *anyopaque, result: resources.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.resource = std.meta.activeTag(result);
            self.calls[2] += 1;
        }
    };
    const Arrival = enum { script, tool, page, timeout, failure, recovery };
    const Delivery = struct {
        view: *View,
        arrival: Arrival,
        script: u64,
        tool: u64,
        fn run(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (self.arrival) {
                .script => View.scriptNotify(self.view, self.script, 0, std.unicode.utf8ToUtf16LeStringLiteral("true")),
                .tool => View.toolNotify(self.view, self.tool, 0, 0, null, 0),
                .page => _ = View.pageNotify(self.view, &.{ .kind = 0, .navigation_id = 100, .flags = 0, .status = 0, .value = null }),
                .timeout => View.evalTimeout(self.view),
                .failure => View.notify(self.view, 8, null, 0),
                .recovery => View.notify(self.view, 9, null, 0),
            }
        }
    };
    for (std.enums.values(Arrival)) |arrival| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        var probe: Probe = .{};
        var view = View.init(std.testing.allocator, &probe, Probe.event);
        const window = try prepareTestView(&view, app, .{ .context = &probe, .event = Probe.page });
        view.eval_clock = try std.time.Timer.start();
        const script = try view.eval_book.reserve(view.page_generation, 1000, .{ .context = &probe, .complete = Probe.scriptComplete }, 1);
        const tool = try view.tool_book.reserve(.{ .token = 0, .kind = .cookies, .scope = .profile, .page = view.page_generation, .deadline = 1000, .completion = .{ .context = &probe, .complete = Probe.toolComplete } }, 1);
        const resource = try view.resource_book.reserve(.{ .page = view.page_generation, .deadline = 1000, .completion = .{ .context = &probe, .complete = Probe.resourceComplete } }, 1);
        if (arrival == .recovery) {
            view.recovering = true;
            view.pending_config = try OwnedConfig.initPortable(std.testing.allocator, .{ .html = "pending body", .user_data_folder = if (is_linux) "/ZigguratPendingTest" else "C:\\ZigguratPendingTest" });
        }
        var delivery: Delivery = .{ .view = &view, .arrival = arrival, .script = script, .tool = tool };
        try app.post(.{ .context = &delivery, .call = Delivery.run });
        app.quit();
        try std.testing.expect(!window.isClosed());
        var owned = try resources.OwnedResponse.init(std.testing.allocator, .{ .bytes = "retained" }, 1024);
        defer owned.deinit();
        var file: OwnedFileResponse = undefined;
        try std.testing.expectError(error.Closed, view.evaluateJS("true", .{}, .{ .context = &probe, .complete = Probe.scriptComplete }));
        try std.testing.expectError(error.Closed, view.getCookies("https://app.ziggurat.invalid/", .{}, .{ .context = &probe, .complete = Probe.toolComplete }));
        try std.testing.expectError(error.Closed, view.cancelEvaluation(script));
        try std.testing.expectError(error.Closed, view.cancelTool(tool));
        const id: ResourceRequestId = .{ .view = &view, .token = resource, .page = view.page_generation };
        try std.testing.expectError(error.Closed, id.cancel());
        try std.testing.expectError(error.Closed, view.respondOwned(id, &owned));
        try std.testing.expectError(error.Closed, view.respondFile(id, &file, .{}));
        try std.testing.expect(owned.storage != null and view.pageId() == null);
        var responder: Responder = .{ .native = @ptrFromInt(1), .window = window, .view = &view, .max_bytes = 1024 };
        try std.testing.expectError(error.Closed, responder.respond(.{}));
        try std.testing.expectError(error.Closed, responder.respondFile(&file, .{}));
        try std.testing.expectError(error.Closed, responder.deferResponse(.{}));
        try app.dispatch();
        try std.testing.expect(probe.script == null and probe.tool == null and probe.resource == null);
        try std.testing.expect(probe.events == 0 and probe.pages == 0 and view.page_generation == 1);
        if (arrival == .recovery) try std.testing.expect(view.pending_config != null and view.config != null);
        _ = try window.destroy();
        try std.testing.expectEqual(std.meta.Tag(ScriptResult).detached, probe.script.?);
        try std.testing.expectEqual(std.meta.Tag(tools.Result).detached, probe.tool.?);
        try std.testing.expectEqual(std.meta.Tag(resources.Result).detached, probe.resource.?);
        View.scriptNotify(&view, script, 0, null);
        View.toolNotify(&view, tool, 0, 0, null, 0);
        try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1 }, &probe.calls);
        try std.testing.expect(view.window == null and view.config == null and view.pending_config == null);
    }
}

test "tool rearm failure completion close suppresses the current native result" {
    const Probe = struct {
        view: *View,
        script: usize = 0,
        tool: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn scriptComplete(ptr: *anyopaque, result: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .timer_failed);
            self.script += 1;
            _ = self.view.window.?.destroy() catch unreachable;
        }
        fn toolComplete(ptr: *anyopaque, result: tools.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .detached);
            self.tool += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var view: View = undefined;
    var probe: Probe = .{ .view = &view };
    view = View.init(std.testing.allocator, &probe, Probe.event);
    _ = try prepareTestView(&view, app, null);
    view.eval_clock = try std.time.Timer.start();
    _ = try view.eval_book.reserve(view.page_generation, 0, .{ .context = &probe, .complete = Probe.scriptComplete }, 1);
    const token = try view.tool_book.reserve(.{ .token = 0, .kind = .clear, .scope = .profile, .page = view.page_generation, .deadline = null, .completion = .{ .context = &probe, .complete = Probe.toolComplete } }, 1);
    View.toolNotify(&view, token, 1, 0, null, 0);
    try std.testing.expectEqual(1, probe.script);
    try std.testing.expectEqual(1, probe.tool);
    try app.dispatch();
    try std.testing.expect(view.window == null);
}

test "page cancellation takes both old books before reentrant work is added" {
    const Probe = struct {
        view: *View,
        script: usize = 0,
        old_tool: usize = 0,
        replacement: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn scriptComplete(ptr: *anyopaque, result: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .page_changed);
            _ = self.view.tool_book.reserve(.{ .token = 0, .kind = .capture, .scope = .page, .page = self.view.page_generation, .deadline = null, .completion = .{ .context = self, .complete = replacementComplete } }, 2) catch unreachable;
            self.script += 1;
        }
        fn oldComplete(ptr: *anyopaque, result: tools.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .page_changed);
            self.old_tool += 1;
        }
        fn replacementComplete(ptr: *anyopaque, result: tools.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .detached);
            self.replacement += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var view: View = undefined;
    var probe: Probe = .{ .view = &view };
    view = View.init(std.testing.allocator, &probe, Probe.event);
    _ = try prepareTestView(&view, app, null);
    _ = try view.eval_book.reserve(view.page_generation, null, .{ .context = &probe, .complete = Probe.scriptComplete }, 1);
    _ = try view.tool_book.reserve(.{ .token = 0, .kind = .capture, .scope = .page, .page = view.page_generation, .deadline = null, .completion = .{ .context = &probe, .complete = Probe.oldComplete } }, 2);
    const start: NativePageEvent = .{ .kind = 0, .navigation_id = 44, .flags = 0, .status = 0, .value = null };
    try std.testing.expectEqual(1, View.pageNotify(&view, &start));
    try std.testing.expect(probe.script == 1 and probe.old_tool == 1 and probe.replacement == 0);
    app.quit();
    try app.dispatch();
    _ = try view.window.?.destroy();
    try std.testing.expectEqual(1, probe.replacement);
}

test "expired tool is timed out even when another deadline cannot rearm" {
    const Probe = struct {
        timed_out: usize = 0,
        failed: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn expired(ptr: *anyopaque, result: tools.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .timed_out);
            self.timed_out += 1;
        }
        fn future(ptr: *anyopaque, result: tools.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .timer_failed);
            self.failed += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{};
    var view = View.init(std.testing.allocator, &probe, Probe.event);
    const window = try prepareTestView(&view, app, null);
    view.eval_clock = try std.time.Timer.start();
    _ = try view.tool_book.reserve(.{ .token = 0, .kind = .cookies, .scope = .profile, .page = view.page_generation, .deadline = 0, .completion = .{ .context = &probe, .complete = Probe.expired } }, 2);
    _ = try view.tool_book.reserve(.{ .token = 0, .kind = .cookies, .scope = .profile, .page = view.page_generation, .deadline = std.math.maxInt(u64), .completion = .{ .context = &probe, .complete = Probe.future } }, 2);
    View.evalTimeout(&view);
    try std.testing.expect(probe.timed_out == 1 and probe.failed == 1 and !view.tool_accepting and !view.eval_accepting);
    _ = try window.destroy();
}

fn cookieConversionFixture(allocator: std.mem.Allocator) !void {
    var marker: u8 = 0;
    var view = View.init(allocator, &marker, struct {
        fn event(_: *anyopaque, _: *View, _: Event) void {}
    }.event);
    const native: NativeCookie = .{
        .name = std.unicode.utf8ToUtf16LeStringLiteral("cookie"),
        .value = std.unicode.utf8ToUtf16LeStringLiteral("Unicode 值"),
        .domain = std.unicode.utf8ToUtf16LeStringLiteral("example.test"),
        .path = std.unicode.utf8ToUtf16LeStringLiteral("/"),
        .expires = -1,
        .flags = 7,
        .same_site = 1,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try view.convertCookies(arena.allocator(), &native, 1, 1024);
    try std.testing.expectEqualStrings("Unicode 值", result[0].value);
    try std.testing.expect(result[0].secure and result[0].http_only and result[0].session);
}
test "cookie conversion releases each partial allocation and enforces UTF8 budget" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cookieConversionFixture, .{});
    var remaining: usize = 2;
    try std.testing.expectError(error.ToolResultTooLarge, View.cookieText(std.testing.allocator, std.unicode.utf8ToUtf16LeStringLiteral("值"), &remaining));
    try std.testing.expectEqual(2, remaining);
}

test "resource preparation during initial loading fails without taking context on timer error" {
    const Probe = struct {
        calls: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn complete(ptr: *anyopaque, _: resources.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{};
    var view = View.init(std.testing.allocator, &probe, Probe.event);
    const window = try prepareTestView(&view, app, null);
    view.loading = true;
    try std.testing.expectError(if (is_linux) error.Closed else error.UnsupportedCapability, view.deferResource(@ptrFromInt(1), .{ .timeout_ms = 5, .completion = .{ .context = &probe, .complete = Probe.complete } }));
    try std.testing.expectEqual(0, probe.calls);
    for (view.resource_book.slots) |slot| try std.testing.expect(slot == null);
    try std.testing.expect(view.resource_accepting and view.eval_watch == null);
    _ = try window.destroy();
}

test "three request books isolate expiry from rearm failure callbacks that close" {
    const Probe = struct {
        view: *View,
        script: usize = 0,
        tool: usize = 0,
        resource: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn scriptComplete(ptr: *anyopaque, result: ScriptResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .timed_out);
            self.script += 1;
        }
        fn toolComplete(ptr: *anyopaque, result: tools.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .timer_failed);
            for (self.view.resource_book.slots) |slot| std.debug.assert(slot == null);
            self.tool += 1;
            _ = self.view.window.?.destroy() catch unreachable;
        }
        fn resourceComplete(ptr: *anyopaque, result: resources.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .timed_out);
            self.resource += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var view: View = undefined;
    var probe: Probe = .{ .view = &view };
    view = View.init(std.testing.allocator, &probe, Probe.event);
    _ = try prepareTestView(&view, app, null);
    view.eval_clock = try std.time.Timer.start();
    _ = try view.eval_book.reserve(view.page_generation, 0, .{ .context = &probe, .complete = Probe.scriptComplete }, 1);
    _ = try view.tool_book.reserve(.{ .token = 0, .kind = .cookies, .scope = .profile, .page = view.page_generation, .deadline = std.math.maxInt(u64), .completion = .{ .context = &probe, .complete = Probe.toolComplete } }, 1);
    _ = try view.resource_book.reserve(.{ .page = view.page_generation, .deadline = 0, .completion = .{ .context = &probe, .complete = Probe.resourceComplete } }, 1);
    View.evalTimeout(&view);
    try std.testing.expect(probe.script == 1 and probe.tool == 1 and probe.resource == 1);
    try app.dispatch();
    try std.testing.expect(view.window == null);
}

fn headerConfigFixture(allocator: std.mem.Allocator) !void {
    var name = "X-Fixture".*;
    var value = "exact".*;
    const grants = [_]resources.HeaderGrant{.{ .name = &name, .exact_value = &value }};
    var config = try OwnedConfig.initPortable(allocator, .{ .html = "", .user_data_folder = testProfilePath(), .local = .{ .request_headers = &grants } });
    defer config.deinit(allocator);
    name[0] = 'Y';
    value[0] = 'E';
    try std.testing.expectEqualStrings("X-Fixture", config.options.local.?.request_headers[0].name);
    try std.testing.expectEqualStrings("exact", config.options.local.?.request_headers[0].exact_value.?);
}
test "header policy configuration copies borrowed rules transactionally" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, headerConfigFixture, .{});
}

fn schemeConfigFixture(allocator: std.mem.Allocator) !void {
    var name = "asset".*;
    var origin = "HTTPS://EXAMPLE.TEST:443/".*;
    const registrations = [_]SchemeRegistration{.{ .name = &name, .request_origins = &.{&origin} }};
    var config = try OwnedConfig.initPortable(allocator, .{ .html = "document", .user_data_folder = testProfilePath(), .custom_schemes = &registrations, .local = .{ .scheme = "asset", .host = "fixture" } });
    defer config.deinit(allocator);
    name[0] = 'X';
    origin[0] = 'x';
    try std.testing.expectEqualStrings("asset", config.options.custom_schemes[0].name);
    try std.testing.expectEqualStrings("https://example.test", config.options.custom_schemes[0].request_origins[0]);
    try std.testing.expectEqualStrings("asset://fixture/", config.url.?);
    try std.testing.expectEqualStrings("asset://fixture/", config.prefix.?);
}
test "scheme configuration copies metadata and rolls every allocation back" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, schemeConfigFixture, .{});
    try std.testing.expectError(error.UnregisteredScheme, OwnedConfig.initPortable(std.testing.allocator, .{ .html = "", .user_data_folder = testProfilePath(), .local = .{ .scheme = "unknown" } }));
    try std.testing.expectError(error.InvalidSchemeOrigin, OwnedConfig.initPortable(std.testing.allocator, .{ .html = "", .user_data_folder = testProfilePath(), .custom_schemes = &.{.{ .name = "asset" }}, .local = .{ .scheme = "asset", .host = "2130706433" } }));
}
test "reload cannot alter an attached environment registration set even with a different profile path" {
    if (is_linux) return error.SkipZigTest;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var marker: u8 = 0;
    var view = View.init(std.testing.allocator, &marker, struct {
        fn event(_: *anyopaque, _: *View, _: Event) void {}
    }.event);
    _ = try prepareTestView(&view, app, null);
    const original = view.config.?.storage.ptr;
    try std.testing.expectError(error.SchemeEnvironmentChange, view.reload(.{ .html = "", .user_data_folder = "C:\\AnotherProfile", .custom_schemes = &.{.{ .name = "asset" }} }));
    try std.testing.expect(view.config.?.storage.ptr == original and view.pending_config == null and !view.recovering and view.ready);
    try std.testing.expect(view.native == null);
}

test "permission timer preparation fails before accepting completion ownership" {
    const Probe = struct {
        completed: usize = 0,
        offers: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn handle(ptr: *anyopaque, _: PermissionOffer, _: *PermissionResponder) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.offers += 1;
        }
        fn complete(ptr: *anyopaque, _: permissions.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.completed += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{};
    var view = View.init(std.testing.allocator, &probe, Probe.event);
    const window = try prepareTestView(&view, app, null);
    view.config.?.deinit(view.allocator);
    view.config = try OwnedConfig.initPortable(view.allocator, .{ .html = "", .user_data_folder = testProfilePath(), .permissions = .{ .grants = &.{.{ .origin = "https://example.test", .kinds = .{ .notifications = true } }}, .handler = .{ .context = &probe, .handle = Probe.handle } } });
    try std.testing.expectError(error.UnsupportedCapability, view.deferPermission(@ptrFromInt(1), view.page_generation, .{ .timeout_ms = 1, .completion = .{ .context = &probe, .complete = Probe.complete } }));
    try std.testing.expect(probe.completed == 0 and probe.offers == 0 and view.permission_book.earliest() == null and view.action_budget == null);
    _ = try window.destroy();
}
test "permission completion after stopping remains owned until detached" {
    const Probe = struct {
        count: usize = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn complete(ptr: *anyopaque, result: permissions.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .detached);
            self.count += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{};
    var view = View.init(std.testing.allocator, &probe, Probe.event);
    const window = try prepareTestView(&view, app, null);
    const token = try view.permission_book.reserve(.{ .page = view.page_generation, .deadline = 0, .completion = .{ .context = &probe, .complete = Probe.complete } }, 1);
    const id: PermissionId = .{ .view = &view, .token = token, .page = view.page_generation };
    app.quit();
    try std.testing.expectError(error.Closed, view.decidePermission(id, .allow_ephemeral));
    try std.testing.expectError(error.Closed, id.cancel());
    View.evalTimeout(&view);
    try std.testing.expect(probe.count == 0 and view.permission_book.earliest() != null);
    _ = try window.destroy();
    try std.testing.expect(probe.count == 1 and view.permission_book.earliest() == null);
}

test "shutdown takes all five request books before any application completion" {
    const Probe = struct {
        view: *View,
        calls: [5]u8 = @splat(0),
        fn check(self: *@This(), index: usize) void {
            for (self.view.eval_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.tool_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.resource_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.permission_book.slots) |slot| std.debug.assert(slot == null);
            for (self.view.download_book.slots) |slot| std.debug.assert(slot == null);
            self.calls[index] += 1;
        }
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn script(ptr: *anyopaque, result: ScriptResult) void {
            std.debug.assert(result == .detached);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.check(0);
        }
        fn tool(ptr: *anyopaque, result: tools.Result) void {
            std.debug.assert(result == .detached);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.check(1);
        }
        fn resource(ptr: *anyopaque, result: resources.Result) void {
            std.debug.assert(result == .detached);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.check(2);
        }
        fn permission(ptr: *anyopaque, result: permissions.Result) void {
            std.debug.assert(result == .detached);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.check(3);
        }
        fn download(ptr: *anyopaque, result: downloads.Result) void {
            std.debug.assert(result == .detached);
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.check(4);
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var view: View = undefined;
    var probe: Probe = .{ .view = &view };
    view = View.init(std.testing.allocator, &probe, Probe.event);
    _ = try prepareTestView(&view, app, null);
    view.eval_clock = try std.time.Timer.start();
    _ = try view.eval_book.reserve(1, 100, .{ .context = &probe, .complete = Probe.script }, 1);
    _ = try view.tool_book.reserve(.{ .token = 0, .kind = .cookies, .scope = .profile, .page = 1, .deadline = 100, .completion = .{ .context = &probe, .complete = Probe.tool } }, 1);
    _ = try view.resource_book.reserve(.{ .page = 1, .deadline = 100, .completion = .{ .context = &probe, .complete = Probe.resource } }, 1);
    _ = try view.permission_book.reserve(.{ .page = 1, .deadline = 100, .completion = .{ .context = &probe, .complete = Probe.permission } }, 1);
    const download = try view.download_book.reserve(.{ .observed_page = 1, .deadline = 100, .completion = .{ .context = &probe, .complete = Probe.download } }, 1);
    app.quit();
    View.downloadNotify(&view, download, 1, 100, 100, 0);
    try std.testing.expectEqual(@as(u8, 0), probe.calls[4]);
    try std.testing.expect(view.download_book.find(download) != null);
    try std.testing.expectError(error.Closed, view.cancelDownload(.{ .view = &view, .token = download }));
    try app.dispatch();
    _ = try view.window.?.destroy();
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1 }, &probe.calls);
    try std.testing.expect(view.eval_watch == null and view.eval_timer == null);
}

test "ordinary page change leaves View-scoped downloads alive and cancels permission offers" {
    const Probe = struct {
        permission_calls: u8 = 0,
        download_calls: u8 = 0,
        fn event(_: *anyopaque, _: *View, _: Event) void {}
        fn permission(ptr: *anyopaque, result: permissions.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .page_changed);
            self.permission_calls += 1;
        }
        fn download(ptr: *anyopaque, result: downloads.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(result == .detached);
            self.download_calls += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{};
    var view = View.init(std.testing.allocator, &probe, Probe.event);
    const window = try prepareTestView(&view, app, null);
    const download = try view.download_book.reserve(.{ .observed_page = 1, .deadline = null, .active = true, .completion = .{ .context = &probe, .complete = Probe.download } }, 1);
    _ = try view.permission_book.reserve(.{ .page = 1, .deadline = 100, .completion = .{ .context = &probe, .complete = Probe.permission } }, 1);
    view.finishRequests(.page_changed, .page_changed, .page_changed, .page, null, true);
    try std.testing.expect(probe.permission_calls == 1 and probe.download_calls == 0 and view.download_book.find(download) != null);
    _ = try window.destroy();
    try std.testing.expectEqual(@as(u8, 1), probe.download_calls);
}

test "Linux custom local policy reaches public attach capture before any SDK operation" {
    if (!is_linux) return error.SkipZigTest;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch {};
    var context: u8 = 0;
    var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var view = View.init(fault.allocator(), &context, struct {
        fn event(_: *anyopaque, _: *View, _: Event) void {}
    }.event);
    try std.testing.expectError(error.OutOfMemory, view.attach(window, .{
        .html = "private",
        .storage = .ephemeral,
        .custom_schemes = &.{.{ .name = "asset", .request_origins = &.{"asset://app.ziggurat.invalid"} }},
        .local = .{ .scheme = "asset", .methods = .{ .post = true }, .request_headers = &.{.{ .name = "X-Explicit", .exact_value = "allowed" }} },
    }));
    try std.testing.expect(view.config == null and view.native == null and view.window == null and view.attachment_phase == .detached);
    try std.testing.expect(fault.allocated_bytes == 0);
}

test "Linux custom local raw header aggregate rejects before scanning or allocating" {
    if (!is_linux) return error.SkipZigTest;
    const unreadable: []const u8 = @as([*]const u8, @ptrFromInt(4096))[0..2048];
    const rows = [_]resources.HeaderGrant{.{ .name = "X-Budget", .exact_value = unreadable }} ** 16;
    var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.HeaderBudgetExceeded, OwnedConfig.init(fault.allocator(), .{
        .html = "",
        .storage = .ephemeral,
        .custom_schemes = &.{.{ .name = "asset" }},
        .local = .{ .scheme = "asset", .request_headers = &rows },
    }));
    try std.testing.expect(fault.alloc_index == 0 and fault.allocated_bytes == 0);
}

test "Linux local scratch owns policy bytes and leaves default metadata layout unchanged" {
    if (!is_linux) return error.SkipZigTest;
    var name = "X-Explicit".*;
    var value = "allowed".*;
    var origin = "asset://app.ziggurat.invalid".*;
    const headers = [_]resources.HeaderGrant{ .{ .name = &name, .exact_value = &value }, .{ .name = "X-Any" }, .{ .name = "X-Empty", .exact_value = "" } };
    const origins = [_][]const u8{&origin};
    const site: LocalSite = .{ .scheme = "asset", .methods = .{ .post = true }, .request_headers = &headers };
    const registration: SchemeRegistration = .{ .name = "asset", .request_origins = &origins };
    const measured = try webkit.localPolicyBytes(site, registration);
    var scratch = try webkit.LocalScratch.init(std.testing.allocator, site, 1024, @ptrFromInt(4096), registration);
    defer scratch.deinit(std.testing.allocator);
    name[0] = '?';
    value[0] = '?';
    origin[0] = '?';
    const policy = scratch.local.policy.?;
    try std.testing.expectEqual(@as(u32, 7), policy.methods);
    try std.testing.expectEqual(@as(u32, 3), policy.header_count);
    try std.testing.expectEqualStrings("X-Explicit", std.mem.span(policy.headers.?[0].name));
    try std.testing.expectEqualStrings("allowed", std.mem.span(policy.headers.?[0].value.?));
    try std.testing.expect(policy.headers.?[1].value == null);
    try std.testing.expectEqualStrings("", std.mem.span(policy.headers.?[2].value.?));
    try std.testing.expectEqualStrings("asset://app.ziggurat.invalid", std.mem.span(policy.origins.?[0]));
    var plain = try webkit.LocalScratch.init(std.testing.allocator, LocalSite{ .scheme = "asset" }, 1024, @ptrFromInt(4096), SchemeRegistration{ .name = "asset" });
    defer plain.deinit(std.testing.allocator);
    try std.testing.expect(plain.local.policy == null);
    try std.testing.expectEqual(@as(usize, "asset".len + "app.ziggurat.invalid".len + 1 + 3), plain.storage.len);
    std.debug.print("Linux local ABI: Local={d} Scratch={d} Policy={d} Grant={d}; policy requested={d} default allocation={d}; View={d} Options={d}\n", .{ @sizeOf(webkit.Local), @sizeOf(webkit.LocalScratch), @sizeOf(webkit.LocalPolicy), @sizeOf(webkit.LocalHeaderGrant), measured, plain.storage.len, @sizeOf(View), @sizeOf(Options) });
}

test "Linux capability preflight rejects unsupported configuration before allocation" {
    if (!is_linux) return error.SkipZigTest;
    const cases = [_]Options{
        .{ .html = "", .storage = .ephemeral, .local = .{} },
        .{ .html = "", .storage = .ephemeral, .remote = .{ .url = "https://example.test", .origins = &.{}, .credentials = .profile } },
        .{ .html = "", .storage = .ephemeral, .custom_schemes = &.{.{ .name = "private" }} },
        .{ .html = "", .storage = .ephemeral, .tools = .{ .cookies = true } },
        .{ .html = "", .storage = .ephemeral, .tools = .{ .pdf = true } },
        .{ .html = "", .storage = .ephemeral, .tools = .{ .capture = true }, .tool_limits = .{ .max_cookies = 1 } },
        .{ .html = "", .storage = .ephemeral, .policy = .{ .permission = .notify } },
    };
    for (cases) |options| {
        var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.UnsupportedCapability, OwnedConfig.init(fault.allocator(), options));
        try std.testing.expect(fault.alloc_index == 0 and fault.allocated_bytes == 0);
    }
    var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, OwnedConfig.init(fault.allocator(), .{ .html = "find", .storage = .ephemeral, .tools = .{ .find = true } }));
    try std.testing.expectError(error.OutOfMemory, OwnedConfig.init(fault.allocator(), .{ .html = "capture", .storage = .ephemeral, .tools = .{ .capture = true }, .tool_limits = .{ .max_pending = 1, .max_capture_bytes = 8 } }));
    try std.testing.expectError(error.ProfileRequired, OwnedConfig.init(fault.allocator(), .{ .html = "" }));
    try std.testing.expectError(error.LocalSiteRequired, OwnedConfig.init(fault.allocator(), .{ .html = "", .storage = .ephemeral, .file_streams = .{} }));
    try std.testing.expect(fault.alloc_index == 0);
    try std.testing.expectError(error.EphemeralProfilePathForbidden, OwnedConfig.init(fault.allocator(), .{ .html = "", .storage = .ephemeral, .user_data_folder = "/must-not-be-ignored" }));
    try std.testing.expect(fault.alloc_index == 0);
}
fn testEphemeralConfig(allocator: std.mem.Allocator) !void {
    var html = "<title>owned page</title>".*;
    var agent = "explicit agent".*;
    var candidate = try OwnedConfig.init(allocator, .{ .html = &html, .storage = .ephemeral, .user_agent = &agent });
    defer candidate.deinit(allocator);
    html[0] = '?';
    agent[0] = '?';
    try std.testing.expectEqualStrings("<title>owned page</title>", candidate.options.html);
    try std.testing.expectEqualStrings("explicit agent", candidate.options.user_agent.?);
    try std.testing.expect(candidate.options.storage == .ephemeral and candidate.options.user_data_folder.len == 0);
}
test "Linux ephemeral configuration owns metadata and rolls every allocation back" {
    if (!is_linux) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testEphemeralConfig, .{});
}

fn testRemoteEphemeralConfig(allocator: std.mem.Allocator) !void {
    var url = "https://example.test/start".*;
    var origin = "https://example.test".*;
    var directory = "/application/request-policy".*;
    var name = "X-Application".*;
    var exact = "known".*;
    const headers = [_]resources.HeaderGrant{.{ .name = &name, .exact_value = &exact }};
    const origins = [_]OriginGrant{.{ .origin = &origin, .request_headers = &headers, .ipc = true }};
    var credentials = [_]RequestCredential{.{ .origin = "https://example.test", .bearer = .{0x5a} ** 32 }};
    var owned = try OwnedConfig.init(allocator, .{ .html = "", .storage = .ephemeral, .remote = .{ .url = &url, .origins = &origins, .credentials = .ephemeral, .request_credentials = &credentials }, .request_policy_extension = .{ .directory = &directory } });
    defer owned.deinit(allocator);
    @memset(&url, '?');
    @memset(&origin, '?');
    @memset(&directory, '?');
    @memset(&name, '?');
    @memset(&exact, '?');
    credentials[0].bearer = .{0} ** 32;
    try std.testing.expectEqualStrings("https://example.test/start", owned.options.remote.?.url);
    try std.testing.expectEqualStrings("https://example.test", owned.options.remote.?.origins[0].origin);
    try std.testing.expectEqualStrings("/application/request-policy", owned.options.request_policy_extension.?.directory);
    try std.testing.expectEqualStrings("X-Application", owned.options.remote.?.origins[0].request_headers[0].name);
    try std.testing.expectEqualStrings("known", owned.options.remote.?.origins[0].request_headers[0].exact_value.?);
    try std.testing.expectEqualSlices(u8, &(.{0x5a} ** 32), &owned.options.remote.?.request_credentials[0].bearer);
}

test "Linux remote configuration owns policy deployment and all grants with complete OOM rollback" {
    if (!is_linux) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testRemoteEphemeralConfig, .{});
}

test "Linux remote policy preflight rejects missing native deployment before allocating" {
    if (!is_linux) return error.SkipZigTest;
    const options: Options = .{ .html = "", .storage = .ephemeral, .remote = .{ .url = "https://example.test", .origins = &.{.{ .origin = "https://example.test" }}, .credentials = .ephemeral } };
    var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.RequestPolicyExtensionRequired, OwnedConfig.init(fault.allocator(), options));
    try std.testing.expect(fault.alloc_index == 0);
}

test "request credentials are captured before caller allocation and wiped before final free" {
    const Gate = struct {
        input: *RequestCredential,
        origin: []u8,
        allocated: usize = 0,
        freed: usize = 0,
        all_zero: bool = false,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.allocated += 1;
            @memset(self.origin, '?');
            self.input.bearer = .{0} ** 32;
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.freed += 1;
            self.all_zero = std.mem.allEqual(u8, bytes, 0);
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var origin = "https://example.test".*;
    var entries = [_]RequestCredential{.{ .origin = &origin, .bearer = .{0x5a} ** 32 }};
    var gate: Gate = .{ .input = &entries[0], .origin = &origin };
    const candidate = try OwnedConfig.init(gate.allocator(), .{ .html = "", .storage = if (is_linux) .ephemeral else .profile, .user_data_folder = if (is_linux) "" else testProfilePath(), .remote = .{ .url = "https://example.test/start", .origins = &.{.{ .origin = "https://example.test" }}, .credentials = if (is_linux) .ephemeral else .profile, .request_credentials = &entries }, .request_policy_extension = if (is_linux) .{ .directory = "/app/policy" } else null });
    try std.testing.expectEqualStrings("https://example.test", candidate.options.remote.?.request_credentials[0].origin);
    try std.testing.expectEqualSlices(u8, &(.{0x5a} ** 32), &candidate.options.remote.?.request_credentials[0].bearer);
    candidate.deinit(gate.allocator());
    try std.testing.expect(gate.allocated == 1 and gate.freed == 1 and gate.all_zero);
}

test "Windows request credential validation reaches caller allocation after native policy preflight" {
    if (is_linux) return error.SkipZigTest;
    var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, OwnedConfig.init(fault.allocator(), .{ .html = "", .user_data_folder = testProfilePath(), .remote = .{ .url = "https://example.test", .origins = &.{.{ .origin = "https://example.test" }}, .credentials = .profile, .request_credentials = &.{.{ .origin = "https://example.test", .bearer = .{1} ** 32 }} } }));
    try std.testing.expect(fault.has_induced_failure and fault.alloc_index == 0);
}

fn testWindowsRequestCredentials(allocator: std.mem.Allocator) !void {
    var origin = "https://example.test".*;
    var entries = [_]RequestCredential{.{ .origin = &origin, .bearer = @splat(0x5a) }};
    const owned = try OwnedConfig.init(allocator, .{ .html = "", .user_data_folder = testProfilePath(), .remote = .{ .url = "https://example.test/start", .origins = &.{.{ .origin = "https://example.test" }}, .credentials = .profile, .request_credentials = &entries } });
    defer owned.deinit(allocator);
    @memset(&origin, '?');
    entries[0].bearer = @splat(0);
    try std.testing.expectEqualStrings("https://example.test", owned.options.remote.?.request_credentials[0].origin);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x5a} ** 32), &owned.options.remote.?.request_credentials[0].bearer);
}

test "Windows exact request credentials own input and roll every caller allocation back" {
    if (is_linux) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testWindowsRequestCredentials, .{});
}

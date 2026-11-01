const builtin = @import("builtin");

/// Implemented adapter contracts, independent of installed engine version,
/// granted permissions, initialization success or the current document.
pub const Capabilities = struct {
    trusted_html: bool = false,
    persistent_profile: bool = false,
    ephemeral_profile: bool = false,
    page_lifecycle: bool = false,
    top_level_ipc: bool = false,
    evaluate_javascript: bool = false,
    /// Ordered owned top-frame/page-world document-start function bodies.
    document_initializers: bool = false,
    zoom: bool = false,
    user_agent: bool = false,
    developer_tools: bool = false,
    local_site: bool = false,
    /// Explicitly registered custom origin; independent of HTTPS local.
    custom_local_site: bool = false,
    remote_pages: bool = false,
    request_credentials: bool = false,
    file_responses: bool = false,
    custom_schemes: bool = false,
    browser_tools: bool = false,
    /// Native text find, independent of Cookie/PDF/other browser tools.
    find_text: bool = false,
    /// Visible-viewport PNG capture; independent of other browser tools.
    capture_preview: bool = false,
    /// Whole-data clear of the page's own data manager or Profile.
    clear_browsing_data: bool = false,
    permission_decisions: bool = false,
    downloads: bool = false,
    regions: bool = false,
    page_sessions: bool = false,
};

pub const Storage = enum { profile, ephemeral };
pub const GlibFailure = extern struct { domain: u32, code: i32 };
pub const NativeFailure = union(enum) {
    hresult: i32,
    glib: GlibFailure,
};

pub fn capabilities() Capabilities {
    return switch (builtin.os.tag) {
        .windows => .{
            .trusted_html = true,
            .persistent_profile = true,
            .page_lifecycle = true,
            .top_level_ipc = true,
            .evaluate_javascript = true,
            .document_initializers = true,
            .zoom = true,
            .user_agent = true,
            .developer_tools = true,
            .local_site = true,
            .custom_local_site = true,
            .remote_pages = true,
            .request_credentials = true,
            .file_responses = true,
            .custom_schemes = true,
            .browser_tools = true,
            .find_text = true,
            .capture_preview = true,
            .clear_browsing_data = true,
            .permission_decisions = true,
            .downloads = true,
            .regions = true,
            .page_sessions = true,
        },
        .linux => .{
            .trusted_html = true,
            .persistent_profile = true,
            .ephemeral_profile = true,
            .page_lifecycle = true,
            .top_level_ipc = true,
            .evaluate_javascript = true,
            .document_initializers = true,
            .zoom = true,
            .user_agent = true,
            .developer_tools = true,
            .custom_local_site = true,
            .remote_pages = true,
            .request_credentials = true,
            .file_responses = true,
            .find_text = true,
            .capture_preview = true,
            .clear_browsing_data = true,
            .regions = true,
            .page_sessions = true,
        },
        // WKWebView: trusted HTML, custom-scheme local sites and remote
        // pages (grants by origin, no Bearer credential) in ephemeral or
        // explicit persistent storage, with document initializers.
        .macos => .{
            .trusted_html = true,
            .persistent_profile = true,
            .ephemeral_profile = true,
            .page_lifecycle = true,
            .top_level_ipc = true,
            .evaluate_javascript = true,
            .document_initializers = true,
            .zoom = true,
            .user_agent = true,
            .custom_local_site = true,
            .remote_pages = true,
            .find_text = true,
            .capture_preview = true,
            .clear_browsing_data = true,
        },
        else => .{},
    };
}

/// Per-option/state guarantees, independent of policy and installed engine.
/// Linux substring search has native highlights, but no whole-word,
/// highlight-off, known step total or known active-index contract.
pub fn findCapabilities() @import("tools.zig").FindCapabilities {
    return if (builtin.os.tag == .windows) .{
        .whole_word = true,
        .highlight_control = true,
        .total_count_on_step = true,
        .active_index = true,
    } else .{};
}

test "Find capability and option guarantees remain independent" {
    const expect = @import("std").testing.expect;
    const base = capabilities();
    const find = findCapabilities();
    if (builtin.os.tag == .linux) {
        try expect(base.find_text and !base.browser_tools);
        try expect(!find.whole_word and !find.highlight_control and !find.total_count_on_step and !find.active_index);
    } else if (builtin.os.tag == .windows) {
        try expect(base.find_text and base.browser_tools);
        try expect(find.whole_word and find.highlight_control and find.total_count_on_step and find.active_index);
    } else try expect(!base.find_text);
}

test "Linux explicit page contracts keep file and HTTPS local independent" {
    const expect = @import("std").testing.expect;
    const value = capabilities();
    if (builtin.os.tag == .linux) {
        try expect(value.capture_preview and !value.browser_tools);
        try expect(value.custom_local_site and value.remote_pages and value.request_credentials and value.file_responses and value.regions and value.page_sessions and !value.local_site and !value.custom_schemes);
    } else if (builtin.os.tag == .windows) {
        try expect(value.capture_preview and value.browser_tools);
        try expect(value.custom_local_site and value.local_site and value.custom_schemes and value.request_credentials);
    } else try expect(!value.custom_local_site and !value.capture_preview);
}

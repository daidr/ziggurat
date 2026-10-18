const std = @import("std");
const z = @import("ziggurat");
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_container_get_children(*anyopaque) ?*List;
extern fn g_list_free(?*List) void;
extern fn g_type_name_from_instance(*anyopaque) [*:0]const u8;
extern fn webkit_web_view_terminate_web_process(*anyopaque) void;
const List = extern struct { data: ?*anyopaque, next: ?*List, previous: ?*List };

/// Test only: terminate the WebView owned by this fixture's window through
/// the engine's own API. Never search for or signal unrelated processes.
pub fn stop(window: z.Window) !void {
    webkit_web_view_terminate_web_process(try ownedWidget(window));
}

/// Borrow only the WebView in this fixture's content subtree. A test moving
/// it out of the subtree must hold its own GObject reference across the move.
pub fn ownedWidget(window: z.Window) !*anyopaque {
    const overlay = gtk_bin_get_child(window.nativeHandle().?) orelse return error.MissingContentHost;
    const children = gtk_container_get_children(overlay);
    defer g_list_free(children);
    var cursor = children;
    while (cursor) |node| : (cursor = node.next) {
        const child = node.data orelse continue;
        if (std.mem.eql(u8, std.mem.span(g_type_name_from_instance(child)), "WebKitWebView")) {
            return child;
        }
    }
    return error.MissingNativeView;
}

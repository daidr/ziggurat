const z = @import("ziggurat");
const web = @import("ziggurat_webview");
pub const bytes = @import("ziggurat_resource_stream");
pub const Options = @import("bridge.zig").Options;
pub const Service = @import("bridge.zig").Service;

const Backend = struct {
    pub const Id = web.PageId;
    pub const Scope = web.View.PageCallbackScope;
    pub fn pin(id: Id) !Scope {
        return @constCast(id.view).beginPageCallback(id);
    }
    pub fn live(id: Id) bool {
        const current = id.view.pageId() orelse return false;
        return current.view == id.view and current.generation == id.generation;
    }
    pub fn send(id: Id, packet: []const u8) !void {
        return @constCast(id.view).postFor(id, packet);
    }
    pub fn owner(scope: Scope) *z.App {
        return scope.app();
    }
};

/// Optional main-thread adapter. The pure byte protocol remains independent of
/// the App and native WebView module. Params is a declared IPC wire type.
pub fn Bridge(comptime Params: type) type {
    return @import("bridge.zig").Type(Params, Backend);
}

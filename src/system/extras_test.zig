//! Unit tests of the system helpers that need no native session.
test {
    _ = @import("paths.zig");
    _ = @import("menu_roles.zig");
    _ = @import("menu_role_actions.zig");
    _ = @import("signals.zig");
    _ = @import("jump_list.zig");
    _ = @import("recent.zig");
    _ = @import("relaunch.zig");
}

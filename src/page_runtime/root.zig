//! Page runtime: connects a page document to the built-in runtime service
//! (window controls, locale, preferences, file drops, document state) and to
//! application plugins over the page's message transport.
const std = @import("std");
pub const service = @import("service.zig");
pub const host = @import("host.zig");
pub const find = @import("find.zig");
pub const manifest = @import("manifest.zig");
pub const controls = @import("controls.zig");
pub const outbox = @import("outbox.zig");
/// Fixtures for plugin tests.
pub const testing = @import("testing.zig");

pub const Host = host.Host;
pub const Options = host.Options;
pub const Transport = host.Transport;
pub const Endpoint = host.Endpoint;
pub const Plugin = host.Plugin;
pub const Preferences = host.Preferences;
pub const Received = host.Received;
pub const Controls = controls.Controls;
pub const WindowControls = controls.WindowControls;
pub const Post = outbox.Post;
pub const Outbox = outbox.Outbox;
pub const Service = service.Service;
pub const DocumentState = service.DocumentState;
pub const hello = host.hello;
pub const platform = host.platform;
pub const version = host.version;

test {
    _ = @import("tests.zig");
    _ = find;
    _ = manifest;
    _ = controls;
    _ = outbox;
}

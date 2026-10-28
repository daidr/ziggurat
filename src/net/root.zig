//! Optional HTTP fetch and WebSocket client. Every transfer blocks on an
//! application-managed worker; the module creates no threads and never
//! touches the UI thread. Results reach the UI with `App.post`.
//! HTTPS and WSS use the caller's `std.http.Client`: its TLS client and
//! system CA bundle. Requests go through the proxy the user set in the
//! system's settings (`proxy`), unless the client sets its own.
const std = @import("std");

pub const Cancel = @import("cancel.zig").Cancel;
pub const fetch_api = @import("fetch.zig");
pub const websocket = @import("websocket.zig");
pub const proxy = @import("proxy.zig");
pub const tunnel = @import("tunnel.zig");

pub const Header = fetch_api.Header;
pub const Request = fetch_api.Request;
pub const Limits = fetch_api.Limits;
pub const Head = fetch_api.Head;
pub const Response = fetch_api.Response;
pub const FetchError = fetch_api.Error;
pub const fetch = fetch_api.fetch;
pub const fetchJson = fetch_api.fetchJson;
pub const Json = fetch_api.Json;
pub const stream = fetch_api.stream;
pub const receive = fetch_api.receive;
pub const Receiver = fetch_api.Receiver;
pub const Redirect = fetch_api.Redirect;

pub const WebSocket = websocket.Socket;

test {
    std.testing.refAllDecls(@This());
    _ = @import("cancel.zig");
    _ = @import("fetch.zig");
    _ = @import("websocket.zig");
    _ = @import("waker.zig");
    _ = @import("proxy.zig");
    _ = @import("tunnel.zig");
    _ = @import("proxy_test.zig");
}

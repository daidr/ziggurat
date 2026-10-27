# WebSocket 插件

WebSocket 插件让页面经宿主建立 WebSocket 连接，页面侧 `WebSocket` 与浏览器的 API 相同。与浏览器不同，打开握手可以带任意头部（如 `Authorization`、`Cookie`、`Origin`），也不受页面 Content Security Policy 限制。Zig 半部是 `ziggurat_plugin_websocket` 模块（`src/page_runtime/plugins/websocket.zig`），页面半部是 `@ziggurat/plugin-websocket` 包（`packages/plugin-websocket`），清单是包内的 `ziggurat-plugin.json`，不需要原生库。约定见[插件](plugins.md)。

## 宿主

```zig
const websocket_plugin = @import("ziggurat_plugin_websocket");

var plugin: websocket_plugin.Plugin = undefined;
try plugin.init(allocator, .{ .post = .app(app), .connections = 8, .allow = allow });
defer plugin.deinit(); // App.run 返回、Host.detach 之后，App.deinit 之前
try host.use(plugin.plugin());
```

- `init` 启动 `connections` 个 worker（默认 8，最多 `max_connections` = 16），`deinit` 取消全部连接并 join。每个打开的连接占用一个 worker 直到结束：握手、读消息和写消息都由它在 `ziggurat_net` 的 `WebSocket` 上完成。连接数已满时新连接以 `busy` 失败。`allocator` 必须线程安全。
- `allow` 在主线程上看到 URL、子协议和握手头部，返回 `false` 时连接以 `denied` 失败。未设置时允许全部连接。
- 握手头部中 `Host`、`Upgrade`、`Connection`、`Sec-WebSocket-*` 由 socket 自己写，页面给出的值被丢弃；其他头部原样发送。`wss` 使用系统 CA；不经过 HTTP 代理，不协商扩展（如 permessage-deflate）。
- `max_message_bytes`（默认 64 MiB）限制收到的单条消息，超限以 1009 关闭连接。`send_buffer_bytes`（默认 4 MiB）是每个连接的发送队列，更大的消息发送失败；队列满时宿主暂缓回复页面，写出后继续。
- 页面读得慢时，每个连接最多保留 `receive_buffer_bytes`（默认 1 MiB）已收到的字节，之后停止从服务器读取，直到页面读完。
- 页面主动关闭后等待服务器完成关闭握手最多 `close_timeout_ms`（默认 5 秒），超时以 1006 结束。页面离开、换代或 Host detach 时，连接以 1001（going away）关闭，同样受该时限约束。

## 页面

```ts
import { WebSocket } from "@ziggurat/plugin-websocket";

const ws = new WebSocket("wss://example.com/live", ["v1"], {
  headers: { authorization: `Bearer ${token}` },
});
ws.onopen = () => ws.send("hello");
ws.onmessage = (e) => console.log(e.data);
ws.onclose = (e) => console.log(e.code, e.reason, e.wasClean);
```

- 构造参数与浏览器相同，第三个参数给出握手头部。`http:`/`https:` URL 转成 `ws:`/`wss:`；其他协议、带片段的 URL、重复或非法子协议抛 `SyntaxError`。
- `readyState`、`protocol`、`extensions`（总是空）、`binaryType`（`blob` 或 `arraybuffer`）、`bufferedAmount`、`onopen`/`onmessage`/`onerror`/`onclose` 与 `addEventListener` 行为同浏览器。连接中 `send` 抛 `InvalidStateError`；关闭后 `send` 的数据计入 `bufferedAmount` 并被丢弃。
- 消息按 `send` 的顺序发送；`bufferedAmount` 计算宿主尚未收下的字节。`close(code, reason)` 只接受 1000 与 3000–4999、reason 不超过 123 字节，在已发送的消息之后关闭；不给 code 时发送 1000。连接中关闭会中止握手，以 1006 结束。
- 连接失败（拒绝、握手被拒、协议错误、超时）先触发 `error`，再以 `code` 1006、`wasClean` 为 `false` 触发 `close`，原因写到控制台。
- 宿主未注册插件时连接以 1006 失败，控制台提示 `Host.use`。

## 消息与上限

服务 limits 为 `max_pending = 32`、`max_in_flight = 16`、`max_message_bytes = 64 KiB`，页面包导出相同的 `limits`。每个连接在整个生命期里占用一个 `connect` 流式调用，事件按 `open`、消息、`close` 的顺序作为块到达；页面确认已读的块后宿主继续发送。消息两个方向都按 32 KiB（Base64 后放进一条消息）切成片段，`last` 标记一条消息的最后一片；页面每个连接同一时间只发送一片，所以 16 个连接最多占用 32 个调用。

## 验证

`zig build test-plugin-websocket` 在测试后端上用本地服务器覆盖：子协议协商与握手头部、文本和跨片段的 100 KB 二进制回显、页面与服务器发起的关闭及其 code/reason、拒绝连接、无效 URL/子协议、`allow` 拒绝、未知连接、页面换代时以 1001 关闭、服务器不回应关闭握手时超时。`bun test packages` 覆盖页面包。`smoke-plugin-websocket -Dwebview=true` 在真实 WebView 中经页面包连接本地服务器：浏览器无法设置的 `Authorization`/`Origin` 握手头、子协议、文本回显、300 KB 二进制分片回显与 `bufferedAmount`、干净关闭和拒绝连接。Linux WebKitGTK 上已在隐藏窗口中运行通过；Windows 列在 CI 手动触发的 WebView2 任务中。这些检查不建立性能结论。

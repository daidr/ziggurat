# fetch 插件

fetch 插件让页面从宿主发起 HTTP 请求：不受 CORS 限制，也不受 WebView 对 `Origin`、`User-Agent` 等头部的限制。Zig 半部是 `ziggurat_plugin_fetch` 模块（`src/page_runtime/plugins/fetch.zig`），页面半部是 `@ziggurat/plugin-fetch` 包（`packages/plugin-fetch`），清单是包内的 `ziggurat-plugin.json`，不需要原生库。约定见[插件](plugins.md)。

## 宿主

```zig
const fetch_plugin = @import("ziggurat_plugin_fetch");

var plugin: fetch_plugin.Plugin = undefined;
try plugin.init(allocator, .{ .post = .app(app), .workers = 4, .allow = allow });
defer plugin.deinit(); // App.run 返回、Host.detach 之后，App.deinit 之前
try host.use(plugin.plugin());
```

- `init` 启动 `workers` 个 worker（默认 4），`deinit` 停止并 join；插件在两者之间保持地址不变。`allocator` 必须线程安全，worker 用它分配。每个 worker 自带一个 `std.http.Client`，请求走系统代理（见 [net.md](net.md) “系统代理”），一次处理一个请求；超出 worker 数的请求按顺序排队。
- worker 产出的响应头和 body 经 `Options.post`（通常是 `.app(app)`）唤醒主线程。插件同一时间最多占用一个邮箱槽；`Full` 在 worker 上重试，`Closed` 后不再投递。
- `allow` 在主线程上看到方法、URL 和头部，返回 `false` 时调用以 `denied` 失败。它只检查第一跳；重定向按 `Options.limits.redirects`（默认 20）跟随。未设置时允许全部请求。
- `limits` 是 `ziggurat_net` 的 `Limits`；默认不限制 body 大小。`max_upload_bytes`（默认 64 MiB）限制页面已上传但尚未发出的请求 body 总量。
- 页面离开、换代或 Host detach 时，进行中的请求被取消，排队的请求被丢弃，未使用的上传被释放。

## 页面

```ts
import { fetch } from "@ziggurat/plugin-fetch";

const res = await fetch("https://api.example.com/items", {
  headers: { authorization: `Bearer ${token}` },
});
const items = await res.json();
```

`fetch` 接受标准参数，返回标准 `Response`：

- `status`、`statusText`、`headers`、`url`、`redirected` 来自宿主看到的最终响应。响应头名为小写，按收到顺序，不含 `Set-Cookie`；插件不保存 Cookie。状态码不在 200–599 时 `Response` 以 200 构造，`status` 再改回真实值。
- body 是随宿主读取而到达的流；页面不读时宿主最多保留 32 个 32 KiB 的块，之后暂停读取。HEAD 以及 101、103、204、205、304 响应没有 body。
- `redirect` 支持 `follow`、`manual`（返回重定向响应本身）和 `error`（以 `TypeError` 失败）。
- `signal` 取消请求：响应头到达前 `fetch` 以 `signal.reason` 拒绝，之后 body 流以它出错。
- 网络失败、被拒绝和无效请求以 `TypeError("fetch failed: …")` 拒绝，`cause` 是 `RemoteError`。
- 非 http/https 的 URL（应用自身页面、`data:`、`blob:`）交给 WebView 的 `fetch`。
- `mode`、`credentials`、`cache` 等在宿主上没有意义，被忽略。

`Host`、`Content-Type`、`User-Agent`、`Authorization` 由页面给出时替换默认值；`Content-Length`、`Transfer-Encoding`、`Connection` 等传输头部由宿主决定，页面的值被丢弃。页面给出 `Accept-Encoding` 时 body 按服务器编码原样返回，否则宿主解码 gzip/deflate。

宿主未注册插件时，`fetch` 以提示 `Host.use` 的错误拒绝。

## 消息与上限

页面消息最多 64 KiB，服务 limits 为 `max_pending = 32`、`max_in_flight = 32`、`max_message_bytes = 64 KiB`，页面包导出相同的 `limits`。

- 请求 body 不超过 32 KiB 时以 Base64 放在 `fetch` 调用里；更大的 body 先用 `upload` 方法按 36 KiB 分片发送，`fetch` 调用再以上传编号取用。分片累计超过 `max_upload_bytes` 时以 `invalid` 失败，同时未完成的上传超过 32 个时以 `busy` 失败。
- 响应先发一个只含 `head` 的块，之后每块最多 32 KiB body（Base64）。页面确认已读的块后宿主继续发送。
- 同时进行的请求最多 32 个；GET、HEAD 不能带 body。

## 验证

`zig build test-plugin-fetch` 在测试后端上用本地服务器覆盖：1.2 MB 流式 body 按序到达、状态/原因/头部、隐藏 `Set-Cookie`、内联和分片上传的 POST/PUT（含 300 KB 回显）、三种重定向模式、无效与被拒请求、未知上传编号、取消与页面换代、不可达服务器。`bun test packages` 覆盖页面包。`smoke-plugin-fetch -Dwebview=true` 在真实 WebView 中经页面包请求本地服务器：JSON 与页面不可设置的头部、POST、300 KB PUT 上传回显、重定向、逐块流式读取、3 MB body、网络失败和中止。Linux WebKitGTK 上已在隐藏窗口中运行通过；Windows 列在 CI 手动触发的 WebView2 任务中。这些检查不建立性能结论。

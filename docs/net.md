# Fetch 与 WebSocket

`ziggurat_net` 是可选的纯 Zig 网络客户端模块，提供 HTTP(S) 请求和 WebSocket(ws/wss) 客户端。它不导入核心，不创建线程、计时器或连接池之外的后台状态：所有网络调用都在应用自己管理的 worker 上阻塞执行，结果由宿主通过 `App.post` 交给 UI 线程。HTTPS 与 WSS 复用调用者的 `std.http.Client`，即与[更新下载](updates.md)相同的 TLS 客户端与系统 CA；请求默认走用户在系统设置里配置的代理（见下文“系统代理”）。

## Fetch

```zig
const net = @import("ziggurat_net");

// 应用自己的 worker：
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();
var cancel: net.Cancel = .{};
var response = try net.fetch(allocator, &client, .{
    .method = .POST,
    .url = "https://example.com/api",
    .headers = &.{.{ .name = "accept", .value = "application/json" }},
    .credentials = &.{.{ .name = "authorization", .value = token }},
    .body = payload,
    .content_type = "application/json",
}, .{ .response_bytes = 1024 * 1024 }, &cancel);
defer response.deinit(allocator);
```

- 任何 HTTP 状态都作为响应返回，只有传输失败才是错误。`Head` 拥有复制的头部、状态行的 reason（可能为空）和最终响应的 `url`，`header(name)` 不区分大小写。
- `stream` 把响应体边到达边写入调用者的 `std.Io.Writer`，每次读取后 flush 一次，流式响应（如 server-sent events）不会等缓冲填满；写入阻塞时传输随之停住，慢消费者通过 TCP 施加背压，而不是在内存里堆积。`receive` 在读取 body 之前把 `Head` 交给 `Receiver.head`（接管所有权），适合先处理状态和头部、再流式消费 body。`fetch` 是写入内存的便捷形式。
- `headers` 中的 `Host`、`User-Agent`、`Authorization`、`Content-Type` 替换客户端默认值而不是重复发送。调用者自己给出 `Accept-Encoding` 时模块不再声明 gzip/deflate，响应体按服务器编码原样返回、不解码；标准库不认识的编码（如 br）仍无法接收，返回 `ProtocolError`。
- `fetchJson(T, ...)` 在同一上限下把 2xx JSON 解码为 `T`，非 2xx 返回 `HttpStatus`，无法解码返回 `InvalidJson`，未知字段被忽略。
- 重定向由模块逐跳处理，最多 `Limits.redirects` 次；`Request.redirect = .manual` 直接返回重定向响应，`.reject` 遇到重定向返回 `Redirected`；`headers` 每跳都发送，`credentials` 只在 scheme、host、port 不变时发送。带 body 的请求不跟随重定向，直接返回重定向响应；303 以及 POST 的 301/302 改为 GET。
- 默认接受 gzip/deflate 并解码，解码窗口只为编码响应分配；`decompress = false` 只请求 identity。

上限都是显式的：`response_bytes`（解码后的 body，默认 8 MiB）、`header_bytes` 与 `headers`（复制的头部）、`redirects`、`url_bytes`。响应头整体还必须放进客户端的 `read_buffer_size`。已知长度的 identity body 先按 Content-Length 预检，短于声明长度的 body 不会被当作完成。PUT 和 TRACE 响应同样读取 body；HEAD 响应以及 1xx、204、304 响应在头部处结束。

## 取消

`Cancel` 可在任意线程调用 `cancel`。传输的 socket 建立后由 worker 绑定到 token，取消会 shutdown 该 socket，阻塞在读写中的 worker 随即返回 `Cancelled`；被取消的传输不会报告成功。worker 在关闭 socket 之前解绑，迟到的取消不会触及已释放的描述符。域名解析、TCP 连接和 TLS 握手发生在绑定之前，期间的取消在它们返回后生效。模块没有内置超时，截止时间由宿主自己的计时器调用 `cancel` 实现。

## WebSocket

```zig
// worker：
const socket = try net.WebSocket.connect(allocator, &client, "wss://example.com/live", .{
    .protocols = &.{"chat.v2"},
    .headers = &.{.{ .name = "origin", .value = "https://app.example" }},
    .limits = .{ .message_bytes = 256 * 1024, .send_buffer_bytes = 512 * 1024 },
}, &cancel);
defer socket.deinit();
const closed = try socket.run(.{ .context = &state, .on_message = onMessage });

// 任意线程，包括 UI 线程：
try socket.send(.text, "hello"); // error.Full 表示发送队列已满
try socket.close(net.websocket.close_code.normal, "bye");
```

- `connect` 和 `run` 在同一个 worker 上执行，该 worker 独占连接的两个方向，同一 TLS 会话不会被并发读写。`send`、`ping`、`close`、`cancel`、`resumeReading` 可在任意线程调用且不等待网络。
- 发送队列在连接时按 `send_buffer_bytes` 一次性分配，`send` 只复制进队列；空间不足返回 `Full`，`close`/`cancel`/连接结束后返回 `Closed`。`sendCapacity` 报告剩余空间；`Handler.on_flushed` 在 worker 写出排队消息后调用，收到 `Full` 的生产者可据此重试。消息按入队顺序整帧发送，`close` 在已排队的消息之后发送。
- 入站消息在 worker 上交给 handler，`bytes` 只在调用期间有效。handler 返回 `pause` 后 worker 停止读 socket，直到 `resumeReading`；在 handler 仍在执行时调用的 `resumeReading` 同样生效。典型用法是 `App.post` 返回 `Full` 时保留该消息并返回 `pause`，UI 处理完后恢复读取。
- 分片在 `message_bytes` 内重组；超限以 1009 关闭并返回 `MessageTooLarge`，非 UTF-8 文本以 1007 关闭并返回 `InvalidUtf8`，被掩码的服务器帧、保留位、非法控制帧或关闭码以 1002 关闭并返回 `ProtocolViolation`。收到 ping 自动回复 pong；模块不主动发送心跳，由宿主按需调用 `ping`。
- `run` 在关闭握手完成时返回 `Closed{code, reason, remote}`；连接未经关闭握手就断开返回 `ConnectionLost`，`cancel` 返回 `Cancelled`。`close` 接受 1000、1001（离开）和 3000–4999。`Limits.close_timeout_ms` 非零时，本端发出关闭帧后对端在该时间内不回应，`run` 返回 `CloseTimedOut`；默认 0 不限时。阻塞写没有内置超时，由宿主在截止时间后 `cancel`。`wss` 首次连接前与 `std.http.Client.request` 一样按需扫描系统 CA。握手校验 `101`、`Upgrade`、`Connection` 与 `Sec-WebSocket-Accept`，服务器选择未提供的子协议或任何扩展都会被拒绝。不支持压缩扩展。经过代理时 WebSocket 总是走隧道（HTTP 代理的 CONNECT 或 SOCKS5），`ConnectOptions.proxy` 与 fetch 的 `Request.proxy` 含义相同。
- `deinit` 在 `run` 返回后（或从不调用 `run` 时）由 worker 调用，其他线程此前必须停止使用该 socket；`std.http.Client` 必须比 socket 活得更久。

## 系统代理

`net.proxy.forUrl(uri)` 为每个请求决定代理，fetch 每一跳（含重定向）和 WebSocket 连接都用它：

1. 回环主机（`localhost`、`*.localhost`、`127.0.0.0/8`、`::1`）直连。
2. 只要设置了 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 中任一个（或其小写名），就由环境变量决定：`http`/`ws` 用 `HTTP_PROXY`，`https`/`wss` 用 `HTTPS_PROXY`，各自未设置时用 `ALL_PROXY`；`NO_PROXY` 是逗号分隔的主机、域名（`example.com` 含子域，`.example.com` 与 `*.example.com` 只含子域）、IP 或网段，都可带端口，`*` 表示全部直连。显式设置优先于系统设置。
3. 否则按系统设置：Windows 用 WinHTTP 读取当前用户的代理设置（设置 > 网络和 Internet > 代理，即旧的 Internet 选项），先自动检测（WPAD）和配置脚本（PAC），再用手动代理及其绕过列表（`<local>`、`*` 通配、前导点域名、网段）；macOS 用 CFNetwork 读取网络设置里的代理（系统设置 > 网络 > 详细信息 > 代理），包括 HTTP、HTTPS、SOCKS 手动代理及其绕过列表、自动代理发现（WPAD）和自动配置脚本（PAC），PAC 在调用线程的 run loop 私有模式里执行，最多等 5 秒；Linux 用 GIO 默认代理解析器，读取 GNOME 设置，或经 libproxy 读取 KDE 设置与 PAC，沙盒内走桌面 portal。没有答案时直连。

同一 scheme 与主机的系统答案缓存 5 秒，修改系统设置后无需重启应用即对后续请求生效。查询可能执行 PAC 脚本而阻塞，与传输一样只在 worker 上调用。WinHTTP 只从系统目录加载；GIO 在第一次查询时 `dlopen`，没有 GIO 时直连。

支持 HTTP 代理与 SOCKS5（未标版本的 `socks://` 按 SOCKS5，主机名交给代理解析）；SOCKS4 与 HTTPS 代理被跳过，取系统列出的下一个。普通 `http` 请求由 HTTP 代理以绝对 URL 转发（`Proxy-Authorization` 随请求发送，代理要求认证时其 407 响应原样返回）；`https`、`ws`、`wss` 经 CONNECT 或 SOCKS5 隧道到达目标主机，TLS 在隧道内与目标主机握手。代理设置里带用户名与密码时（GNOME 设置与代理 URL 可以带）才发送凭据：HTTP 代理用 Basic，SOCKS5 用用户名/密码认证。隧道握手期间 `Cancel` 已绑定代理连接，取消随即生效。

`Request.proxy`（WebSocket 为 `ConnectOptions.proxy`）是 `net.proxy.Choice`：默认 `.system` 按上述规则；`.direct` 直连；`.{ .proxy = net.proxy.Proxy.parse("socks5://host:1080").? }` 指定代理。调用者自己设置了 `std.http.Client.http_proxy`/`https_proxy` 时 `.system` 保留客户端的设置。经代理的连接属于客户端连接池，请求结束即关闭，不被复用。更新器的下载与 fetch、WebSocket 插件同样走系统代理。

## 线程与停机次序

模块对象不属于 App。正常退出时宿主先取消或关闭自己的请求与 socket，join worker，再结束 App；worker 投递的每个 `App.post` 成功后都会在停机前执行一次，失败返回 `Full` 或 `Closed` 时所有权仍在 worker。

## 验证范围

单元测试用回环 HTTP/WebSocket 服务覆盖状态与头部、reason、最终 URL、重定向模式、默认头替换与不解码的调用者编码、head 先于 body 交付与逐次 flush、POST body、gzip 解码及解码后上限、body/头部/重定向/URL 上限、阻塞读取时的取消、JSON 解码、文本/二进制回显、ping/pong、分片重组、暂停与恢复、远端与本地关闭、超限消息、队列满和握手拒绝。`scripts/net-tls-probe.sh` 用临时生成的 localhost 证书启动回环 TLS 对端，实际验证 HTTPS、跨多个 TLS record 的 WSS 消息，以及不受信证书被拒绝。标准库 TLS 客户端只按 DNS 名称校验证书，IP 地址 URL 不匹配证书中的 IP SAN。代理测试用回环假代理验证 HTTP 代理的绝对 URL 转发与 Basic 凭据、407 响应、SOCKS5 按名称和按地址建隧道、SOCKS5 用户名/密码认证与拒绝、WebSocket 经 CONNECT 隧道，以及环境变量、`NO_PROXY`、Windows 代理列表与绕过列表、回环判断和 5 秒缓存的规则；隧道内 TLS 连接与客户端自身连接的内存布局一致由单元测试检查。真实系统代理设置（WinHTTP/PAC、GIO）只在各平台运行时读取，CI 没有配置代理。公网服务器、证书吊销和长时间断线重连没有在本模块中验证；重连策略由宿主决定。

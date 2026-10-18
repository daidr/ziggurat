# 显式请求凭据

Windows 和 Linux 的 `RemotePage.request_credentials` 是独立的创建期发送能力。每项 `RequestCredential` 包含精确 HTTPS `origin` 与宿主提供的 32 字节私密随机 `bearer`；最多八项，默认空。线上形式是 `Authorization: Bearer ` 后接 64 个小写十六进制字符，与独立 HTTPS Endpoint 的认证形式相同。模块不生成、持久化或通过 URI、Cookie、IPC 消息向页面公开这个值。这里的 IPC 指应用的公开消息通道；引擎私有进程间配置必须携带该凭据。Windows 仍须显式使用 `.profile`，不因这项发送能力获得 Linux 的临时 Context 或 Profile owner API。

```zig
.remote = .{
    .url = "https://127.0.0.1:8443/private/start",
    .origins = &.{.{ .origin = "https://127.0.0.1:8443", .ipc = true }},
    .credentials = .profile,
    .allow_insecure_loopback = true,
    .request_credentials = &.{.{
        .origin = "https://127.0.0.1:8443",
        .bearer = host_private_random_bytes,
    }},
},
```

该配置不授予导航、请求方法、TLS 例外、IPC 或额外资源来源。每个凭据来源必须同时存在独立的 `OriginGrant.requests` 授权；HTTP 即使回环也拒绝。来源沿用 scheme/规范 host/有效 port 的精确比较，不接受路径、userinfo 或通配符。相同 canonical origin 重复拒绝。`HeaderGrant` 继续只检查观察到的头部，不承担装饰。

非空凭据配置明确取得这个页面请求装饰时可见的 Authorization 字段责任，所以不能再与任一 `HeaderGrant` 的 Authorization 规则组合。每次发送及每一跳重定向，Linux WebProcess 或 Windows `WebResourceRequested` 门禁先撤去当前 Authorization，再验证该目标的普通来源、方法与其余头部规则，最后只为这个精确目标添加其冻结 Bearer。JS 提供的同名值不会覆盖它；另一被允许但没有凭据的来源不会注入本模块的 Bearer。被拒绝的请求不发送。额外字段自身也计入 64 个/16KiB 请求头预算。没有配置时完全保留原来的观察与放行语义，不修改既有 Authorization。

这是一项对指定来源的完整发送授权，不根据发起者的 DOM 身份或路径区分 Bearer。允许的页面可以触发该来源的请求，服务端仍须实施路由与方法权限；页面自己的 fetch/CORS、重定向和引擎限制也继续成立。请求装饰不是匿名浏览或网络沙箱，不能阻止可信服务端把收到的凭据写进响应或转发到别处。这里保证的是本模块拥有的 Bearer；[WebView2 网络栈可以在请求回调之后补充自己的 Cookie 或认证字段](https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/webresourcerequested#sequence-for-modifying-requests)，不能将本模块的字段处理解释为禁止 Profile 或操作系统认证。

配置在首次调用 caller allocator 前以有界栈存储捕获，再复制到本次页面配置与独立原生请求策略。调用者修改原数组不改变已接受配置；reload 接受新配置，recover 沿用自己已拥有的配置。Profile 不保存这份请求装饰表，另一个 View/Context 或清空配置的 reload 不继承它。停放 Session 沿用自己的页面与配置。

Zig 配置、暂存描述符、原生策略中的 wire 值及框架显式分配的 GVariant secret/序列化 backing 在实际最后使用或引用释放时清零。Windows 原生策略独立拥有 UTF-16 wire 值，在 State 实际最后引用释放时擦除；逻辑关闭不强行清空仍被 native 引用的策略。迟到的策略释放只操作 C/GLib 存储，不访问 Zig View/App。引擎、GVariant 内部、进程间传输和 HTTP/TLS 栈可能有各自的私有副本，框架不能保证这些 SDK 内部内存全部擦除。宿主仍拥有原始输入并负责其回收。

有凭据时才进入独立 noinline 捕获/校验栈帧：捕获最多八个 1024 字节来源和八份 32 字节输入；Linux 规范化校验另有八个 1024 字节来源，原生 wire 值独立分配 8×72 字节，序列化 backing 沿用整个请求策略的 1MiB 上限。Windows 可选原生表固定 1188 字节，包含最多八个来源索引和八份 72×UTF-16 wire 值；其来源校验在独立 noinline helper 中，普通 Windows 描述符 scratch 增加 8×24 字节而不复制 secret。普通 HTML 与没有装饰的远程配置不进入凭据捕获/校验栈帧，不分配 wire/secret backing，也不增加清零遍历；Linux 原生来源记录仅增加一个可空指针，Windows 策略增加一个可空表指针。系统 GVariant/引擎分配仍不计作项目堆预算。

Linux 请求扩展协议为 ABI 2；扩展与宿主须一起部署。旧 ABI、策略身份不符或未完成握手都在首请求前失败。Windows 使用既有的所有 resource context/source kinds 过滤器与逐跳导航门禁；缺少所需 Runtime 接口会在首次发送前失败，不以只装饰初始 URL 作为回退。`backendCapabilities().request_credentials` 在 Windows/Linux 为 true；此能力不打开 Linux `local_site`，也不将独立 Endpoint 改成 WebView 的 `respondFile`。

纯 Zig 测试覆盖精确来源、HTTPS、重复/未知来源、Authorization 冲突、独立复制、全部 caller OOM 及最终 free 前清零。strict-C policy 测试保留额外原生策略与序列化引用，验证最后一项释放前不提前擦除。真实 Runtime 夹具沿用 `P01_PROBE=https-zig bash scripts/webkit-probe.sh`，可用 `ZIGGURAT_HTTPS_MODE=request_credentials` 单独选择凭据场景；完整 TLS 矩阵仍使用默认入口。

Windows 使用 `zig build build-smoke-request-credentials -Dwebview=true` 编译独立测试对象，再由 Python 3.12+（本机使用 bundled 3.12.14）的 `tests/windows_https_credentials_host.py --exe <installed-exe> --cache <explicit-private-cache> --log <evidence.json>` 显式启动四个私有 TLS 来源。测试对象只接受指定来源和固定夹具证书 SHA-256；不同证书仍拒绝，不改变生产 TLS。ReleaseSafe/Debug 在本机 Runtime 156.0.4314.23 各通过四个场景：主场景五文档、68 次实际请求与 73 次回调逐项比较，另测禁止重定向、ready 立即关闭与错误证书。覆盖首次顶层和子资源、HEAD、同源与跨源往返、JS 同名头覆盖、A→reload B→崩溃 recover B→清空→另一 Profile，以及最后 C 引用和浏览器进程退出。无凭据 peer 不携带本模块 Bearer，禁止来源零实际 HTTP。测试记录方法、来源、路径与字段分类，不记录 Bearer。该环境中重定向请求未带 Origin，受控响应有 Origin 时精确反射、无 Origin 时给 CORS `*`；这只是该夹具的实际观测，不能推断所有 Runtime 或 Profile 的行为。

# 页面来源、请求策略与代数

页面行为属于 `ziggurat_webview.View`，不依赖 UI 模块。Windows 提供内存本地站点、显式远程 HTTP(S) 来源、后台文件快照、有界异步 JS、缩放、UA、DevTools 开关，以及显式授权的 Cookie、Profile 清理、查找、PNG 与 PDF 工具；支持原生矩形区域与离窗 PageSession。原生 `file://` 尚未开放。Linux 首片支持范围如下，其余章节描述 Windows 能力。

## Linux 可信内存页面

Linux 的可选后端使用 GTK3、Soup3 的 WebKitGTK API 4.1，最低版本 2.40；构建时经 pkg-config 检查对应头文件和库，未启用 `-Dwebview=true` 不链接它们。`backendCapabilities()` 返回当前适配器已实现的契约，不代表引擎已安装、当前 ready 或获得来源/设备授权。

```zig
try view.attach(window, .{
    .html = "<title>Memory page</title>",
    .storage = .ephemeral,
    .page_listener = listener,
});
```

`storage` 默认 `.profile`，Windows 保留绝对 `user_data_folder` 契约。Linux 临时页面显式选择 `.ephemeral` 且 folder 为空，不读取已有持久数据；持久页面必须传入同一 App 显式创建的 `Profile` owner，folder 仍为空，见[Linux 页面存储](webview-profile.md)。没有 owner 返回 `ProfileRequired`，不自动根据路径创建 manager。Windows 暂不接受 `.ephemeral` 或这个 Linux Profile owner。Linux 支持下述显式 custom 本地站点、异步资源/私有文件流、远程页面、独立矩形区域、PageSession，以及单独授权的 PNG 截图和整体数据清理；HTTPS local、其余浏览器工具、权限决定和下载仍返回 `UnsupportedCapability`；DevTools 见下文 Linux 说明。不支持的配置在分配或接管前拒绝，非空临时 folder 返回 `EphemeralProfilePathForbidden`；关闭入口优先 `Closed`。没有将 HTTPS 来源、目录权限或其他平台的 grant 转换成本地 scheme。

这一内存 HTML 模式的实际页面 URI 是 `about:blank`，采用构造时不可被文档放宽的 default CSP：网络子资源、connect、frame、worker、object、base 和 form 均拒绝，仅允许内联脚本/样式及 data/blob 图片；显式宿主 JS 仍可执行。普通文档导航只接受适配器为首次加载/刷新准备的 about:blank，其余脚本/链接导航拒绝。可设置 `policy.navigation = .notify` 观察 Runtime 实际发出的已拒绝导航；其余非默认 policy 通知尚不接受。HTTP 方法/header 前置策略仅由下述显式远程模式安装，普通 HTML 不加载请求扩展。CSP 和这些导航规则不是操作系统网络沙箱，不提供对不可信 HTML 的通用隔离保证。

双向字符串 IPC 兼容页面的 `chrome.webview.postMessage` 与 `addEventListener('message', handler)`。接收入口由仅注入顶层的独立 script world 转发，检查真实 MessageEvent、`source === window`、文档标记和已提交的 about:blank；不会仅根据当前 URI 猜测消息来自顶层。旧文档标记、子 frame 的 `parent.postMessage`、默认 world 直接调用私有 handler 及合成 MessageEvent 均不能通过该入口。宿主仍只应附加可信页面；同源代码共享 DOM 的一般能力没有变成安全隔离边界。

已有的 PageId、页面事件、`postFor`、异步 JS、缩放、UA、显式 reload/recover 和关闭所有权规则继续使用同一个 View。HTML 最多 16 MiB；脚本/JSON 使用 `scripts` 显式上限。Linux 的宿主消息投递另有 1024 条待完成上限，与 Windows 一样不占用脚本容量；Full 不接受责任，逻辑取消不会在迟到 finish 前返还物理槽。JS 结果与元数据转换的上限不限制引擎内部执行/JSON 序列化的内存或耗时。截止时间使用已有主循环上的 one-shot GSource，无框架 worker、UI 等待或嵌套 pump。

`nativeFailure()` 保留真实 `.glib = .{ .domain, .code }`，Windows 仍可返回 `.hresult`。`Event.failed`/`ScriptResult.native_failure` 的数字是所属系统的原生 code；需要域时在回调内读取完整快照。本地参数、容量和 allocator 错误不制造 HRESULT，Linux 不改写 `last_hresult`。引擎进程终止仍通过独立的 process_failed 原生 reason 通知。

首片只支持独占全窗 Content。首次附加按需创建 GtkOverlay，保留原 GtkWindow、DrawingArea、IM 对象与 signals；普通窗口不预建容器。area 的 GdkWindow 会在冷附加/拆卸时重建，适配器先取消捕获、组合与原焦点，撤销旧 TextClient，再绑定实际新 GdkWindow；不自动恢复旧编辑 token。WebKit 自己的编辑/输入法由引擎处理，这不代表完整混合焦点已实现。原生脚本对话框、文件/颜色选择器、打印、通知、弹窗和上下文菜单被拒绝；普通网页 `<select>` 的选项菜单保留，不能概括为禁止所有网页 UI。

关闭先清空 C State 的 Zig context，再断开 signals、取消 source/异步操作及拆卸子 widget。已接受逻辑请求在普通 detach 按 detached 结算；迟到异步回调仍调用各自 finish 并只释放独立 C State。View/业务 context 可按 Window.on_closed 契约释放。App.run 返回不承诺引擎内部进程或所有迟到原生引用立即消失，框架不为等待它们运行嵌套循环。`resourceCounts()` 在 Linux 统计 adapter State、异步回调和原生 WebView 对象，另有私有 content host 计数，不包含引擎内部缓存/进程。

`zig build smoke-webview-linux -Dwebview=true` 在隐藏窗口验证配置/编码的全部 allocator 故障、ready 前立即释放 owner、顶层 IPC、单槽链式 JS、真实 GLib 错误域/码、UA 返回 OOM、deadline/quit、raw GtkWindow 关闭、reload、终止自有 WebProcess 后显式 recover，以及旧 PageId 拒绝。测试额外用独立 App 的正常 GLib 循环收尾迟到 native refs，带总 deadline，最终计数归零；库没有加入轮询。`smoke-content-host` 独立验证原对象/IM 重绑、回滚、重入和 raw parent close。两者不建立视觉质量、完整 IME/AT-SPI、GPU 或 Wayland 运行结论。

可用 `P01_PROBE=contract|backend|local-test|local|zig|zig-test bash scripts/webkit-probe.sh` 分别运行来源/CSP、C adapter、本地资源寿命、本地引擎、公开 View 和纯测试；需要 GTK3/WebKitGTK 4.1 开发包。脚本也支持 home 中的独立解包依赖：`P01_DEPS/root`、`GTK_DEPS` 与 `ZIG_BIN`。发行版 WebKit 使用固定 helper 安装路径时，脚本仅在私有 user/mount/network namespace 只读映射库目录，启用独立 loopback 与 Xvfb，不改系统安装、不关闭引擎 sandbox；namespace 不可用则明确失败。实际验证环境为 WSL Ubuntu 24.04、GTK3 3.24.41、WebKitGTK 2.52.6、Soup3 3.4.4 和 Zig 0.15.2。

WebKit 的 [default CSP](https://webkitgtk.org/reference/webkit2gtk/stable/property.WebView.default-content-security-policy.html)、[异步 JS](https://webkitgtk.org/reference/webkit2gtk/stable/method.WebView.evaluate_javascript.html) 和 [script world 注册](https://webkitgtk.org/reference/webkit2gtk/stable/method.UserContentManager.register_script_message_handler_in_world.html) 分别约束内容加载、完成回调和消息入口，不把这些接口等同于完整网络权限系统。

### Linux 显式静态本地站点

```zig
try view.attach(window, .{
    .storage = .ephemeral,
    .html = "<script src='/app.js'></script>",
    .custom_schemes = &.{.{ .name = "asset", .treat_as_secure = true }},
    .local = .{
        .scheme = "asset",
        .scheme_ipc = true,
        .resources = &.{.{ .path = "/app.js", .mime = "text/javascript", .bytes = application_js }},
    },
});
```

`custom_local_site` 表示这一能力；Linux 的 `local_site`（HTTPS）和宽 `custom_schemes` 仍为 false，`file_responses` 单独表示下述显式文件泵。仅接受一个与 local.scheme 完全匹配的显式注册和精确 host。静态 start_path 与资源表只服务 GET/HEAD；静态资源之外可显式配置 on_resource，dynamic_document=true 还将 start_path 交给同一处理器。显式宿主导航和原生历史遵守下述单次授权规则，不能用 HTTPS 配置替换成此 origin。

Linux custom 站点可显式配置 `LocalSite.methods`、`request_headers` 和注册的 `request_origins`。只识别 GET/HEAD/POST/PUT/PATCH/DELETE/OPTIONS；非读取方法即使与静态路由同名也不会返回静态内容。每个非浏览器管理的请求头必须匹配显式 grant，名称按 ASCII 忽略大小写，可选择任意合法值或精确值，精确空字符串与未限制值不同。这些规则只验证实际观察的请求，不注入头或读取 request body。

Origin 独立于 HeaderGrant：实际携带时必须唯一并精确匹配拥有的规范来源名单；写方法必须携带 Origin。缺失、重复、null 或非匹配 Origin 均在业务回调前拒绝，不能用当前页面 URL、Referer 或目标 host 补造。无 Origin 的 GET/HEAD 保留读取合同，不证明发起者。实测 WebKitGTK 2.52.6 的同源 fetch 与 XHR 写请求都进入了原生 scheme callback，但 SDK 可见头中没有 Origin，因此被安全拒绝；当前验证不能据此宣称 Linux 写方法可用或跨来源 CORS 已完成。secure 与 CORS 注册也不保证引擎生成这个头。

配置最多16个 header grant、8个 request origin，grant 名称/值累计最多8192字节，新增拥有型策略区最多32KiB；沿用既有资源/响应的各自预算，没有新增统一1MiB配置上限。实际请求的全部可见头（包括管理头）计入64项、16KiB总量及每项64字节名称/2048字节值的限制。策略在创建前完整捕获，reload/recover 从同一拥有配置重建；默认 GET/HEAD、空 grants/origins 不建立该策略区。异步资源、旧请求代数与关闭责任仍使用下述同一 Responder/Book，不保留借用的请求头。

资源路径是有界的 ASCII 路由，不开放目录。userinfo、可见端口、编码分隔符、点段和非 canonical authority 不会成为另一条文件路径。query/fragment 是 URL 元数据，不改变资源查找。资源请求先完整验证，再二分查找；缺失资源为 404，HEAD 返回原 Content-Length 和空 body。响应带固定 CSP、no-store、Content-Type 和 nosniff。CSP 只允许精确 custom origin 的脚本/样式/图片/connect，以及内联脚本/样式和 data/blob 图片；HTTP(S)、WebSocket、frame、worker、object、base 和 form 保持拒绝。该配置只用于宿主可信内容，不构成通用网络隔离。

IPC 默认关闭；仅 scheme_ipc=true 授权已提交的精确顶层来源，仍核对文档 generation/PageId。内存 HTML 的默认 IPC 行为不变。`FileSnapshot` 仍由应用 worker 从明确给出的文件句柄准备，经成功 App.post 后 adopt，再把 html/resources 传给 View；它不是 file:// 或目录访问授权。View 依原有 resources_released/detach 规则借用资源 body；请求交付前复制为独立原生内存流，迟到读取不借用 Zig config、View 或 App。

`custom_local_limits` 默认且最多8个物理 response、32MiB body；单响应仍最多16MiB。这个 budget 跨同一 View 的 reload/recover 保留，配置降额不能提前归还旧对象。全进程最多32个物理流，每流固定一份有界 metadata；EOF、close、取消不归还槽，直到 engine 最后 unref 才释放 body/数量。HEAD/空 body 同样占槽，满额用预先准备的错误完成，不再分配 body。`customLocalResourceCounts()` 记录实际 budget/stream/body bytes，不代表引擎内部缓存、原生对象 header 或进程 RSS；普通 HTML 与 Windows 不分配此 Linux budget。

`local-test` 锁定初始 budget/复制失败回滚、全局32槽、空流、降额和末引用；`local` 使用真实引擎验证静态资源、HEAD、MIME、默认/显式 IPC 和关闭。公开 smoke-webview-linux 另覆盖 worker FileSnapshot、reload/recover 的同预算、旧 PageId 拒绝、逐分配失败及 allocator 关闭后 on_closed 立即释放 View。它遵循正常 App dispatch 安全点，不要求 attach 返回就已执行最终关闭通知。

### Linux 异步资源与显式私有文件泵

on_resource 使用相同 ResourceHandler/Responder。立即 respond 在返回前复制有界响应；deferResponse 只在成功时接管 completion，返回有文档代数的 ResourceRequestId。宿主 worker 准备 OwnedResponse，经 App.post 后由 owner respondOwned；成功消费数据，失败仍归宿主。真正的 native 提交尝试终结该请求，重试要使用新 id。取消、超时、导航、reload、recover 与 detach 共用已有请求账本，原生最多8个延后请求，不保留 Zig 配置或回调 context 到迟到读取中。

文件模式还需显式 file_streams 和本地 on_resource。Linux worker 调用 OwnedFileResponse.preparePumped，得到两个线性拥有值 response/pump；prepare 只验证并复制明确的 regular 文件句柄和元数据，不读取正文。宿主将 response 经成功 App.post 交 owner，再由自己的 worker 调用 pump.pump。原有 prepare 继续是 Windows 文件流接口，Linux 不暗中代启 worker；FileSnapshot 仍可用于较小的静态完整内存资源。

pump 在 native 真正接受响应前等待，GET 才用固定16KiB块 pread 并通过有界非阻塞本地 socket 供数；HEAD 不读取正文。UI 和引擎只读 socket，主循环 Source 驱动异步完成；框架不创建文件读取线程、GTask线程池、UI磁盘等待或嵌套loop。取消直接唤醒 reader 与等待中的 worker；已在进行的 regular-file pread 只能合作结束。worker 的真实 I/O/截短状态传入流读取错误，不能当成成功 EOF 或静默交付短文件。

响应候选先完整准备 stream、header 和每 View 额度，失败释放候选并保留 response/pump。真正 finish_with_response 后才无失败地转移额度并打开 GET/HEAD gate；关闭或导航重入只能取消已接受传输，不能复活旧 View。若 post/响应被拒绝，宿主必须明确重试或 deinit 保留的 response 来唤醒 pump，不能先在 owner 等待一个仍等接收的 worker。pump 返回后才释放其自身线性值，禁止并发 deinit。

最多每 View8份、进程32份 physical 文件责任，单文件最多256MiB；额度跨 reload/recover 保留，直到 response、显式 pump 和真实 engine stream 的最后引用消失才归还。取消 ticket 只保留独立 native control，不保 physical、文件句柄或额度。固定 chunk、socket 缓冲与这些数量有界；文件长度不是内存副本，预算不冒称覆盖浏览器缓存、GObject header、内核 socket 或进程 RSS。普通 HTML 不创建资源处理器、文件 budget、文件句柄或 pump。

Linux 复制 fd 不禁止其他现存 writer；源必须由宿主保持私有且不可修改，直至 pump 完成。准备不会改变源文件的逻辑 seek 位置，不开放目录或 file://；metadata 的 allocator 必须支持实际创建和释放线程。框架自己的 native metadata 分配可失败回滚；GLib 的 GObject/类型基础设施保留其 fatal-OOM 行为，不承诺从这些内部内存耗尽中恢复。

test-webkit-file 不需启动浏览器，覆盖冷进程线程数、真实异步字节、HEAD零pread、候选失败/重试、容量/最后引用、取消、截短/I/O错误和元数据分配失败。smoke-webview-dynamic-linux 使用真实页面核对立即/worker响应、GET/HEAD、超时/取消/404、截短拒绝、已接受但未启动pump时取消，以及资源回调内退出后 on_closed 立即释放整个宿主。该证据不推定更广 methods/headers、HTTPS本地或目录访问能力。

### Linux 宿主导航与原生历史

`navigateLocal("/settings")` 只向当前 custom scheme+host 提交一个 ASCII 绝对路由，沿用最多4096字节和禁止点段的资源路径语法，不接收 query/fragment。它不改变默认脚本、链接或表单整页导航的拒绝策略，也不开放 `allow_local_navigation`。`goBack`/`goForward` 读取当前原生 BackForwardList 的精确目标；没有对应项返回 `NoHistory`。本地与已授权远程页都支持它们。普通 `about:blank` HTML 没有历史能力，不持有列表引用或历史/URI/loading观察 handler。

每个 native View 同时至多一个拥有型导航事务：先封闭重入，再保存有界目标 URI，并在历史操作中 retain 精确原生 item；stop/close 先撤入口，仍在调用栈上的旧事务最后释放。活动和已撤销但尚未退栈的事务合计最多8个，满额返回 `Full`；序号耗尽不回绕。每个目标和当前 URI 快照最多16384字节，当前快照独立于不可变的配置起始 URL。原生引擎自己的历史列表/文档内存不属于此额度。普通 HTML 为首次加载/刷新使用同一事务，但不建立历史表；没有框架维护的、随导航次数增长的记录。

`refresh` 刷新实际当前地址，包括原生 History API 更新后的 path/query/fragment，不重新加载配置的 start_path/remote.url；`reload(options)` 仍然替换完整配置与 controller。事务或原生转换尚未结束时，新导航返回 `NavigationPending`，不会覆盖旧目标。参数、宿主 allocator 或原生候选分配失败不接管新操作，旧有效文档保持不变。方法成功表示引擎已接受，不等于已完成加载。

同文档 `pushState`/`replaceState`/fragment 与同文档原生回退可能不发整页 policy/LOAD 信号；它们只更新真实来源/历史快照，保留 PageId、私有 IPC 标记与文档状态。框架不通过 URI 相等、fragment 文本或历史 item 的旧代数推断 DOM 身份。宿主历史授权仅绑定精确 item；实际收到跨文档 BACK_FORWARD policy 才准备新私有脚本，真实 LOAD_STARTED 才发布新 PageId。page cache 显式禁用。未经准备与授权的整页 STARTED、被移除的目标或无法核验的目标顺序一律撤入口并失败，不把新文档套入旧代数。

整页准备在任何实际加载前先私下撤销旧逻辑页面，并一次终结旧 script、页面工具、defer 和权限责任；它不伪造公开 started 或 PageId。完成回调可以 stop、reload、quit 或关闭并在 on_closed 释放整个宿主，外层操作重新核验事务/关闭身份后返回 `NavigationCancelled` 或 `Closed`。准备已撤销而 stop 阻止了真实 STARTED 时，旧 DOM 可能仍存在，但不能重新使用已撤销的 IPC/脚本授权；历史操作明确 `NotReady`，等待原生 loading 实际结束后由新的显式完整 `navigateLocal`/`navigateRemote` 恢复。不会反复重试、把旧 item 当作恢复证明或让取消制造假成功。已进入真实 STARTED 的停止/加载失败同样使页面入口失效。

真实 STARTED 回调拒绝或调用 stop 后，`stop_loading` 仍可能留下已排队的 COMMITTED。适配层先撤导航入口，保留该 load 的序号和文档代数撤销标记；仅匹配这次已撤销加载且仍符合 URI 授权的迟到 COMMITTED 不再发布页面。脚本、IPC、DOM/source/title 和新资源入口保持失效，新的导航在该 load 的 FINISHED 前返回 `NavigationPending`。FINISHED 先清标记，再恰好一次报告失败完成，允许完成回调提交新导航；原生进程失败或关闭也清标记，不等待永远不会到达的完成通知。没有对应撤销标记的 COMMITTED 仍报告导航错误，包括 `about:blank`，不把它当作通用例外。raw backend 夹具实际覆盖拒绝/显式 stop 的 STARTED→迟到 COMMITTED→失败完成，并在标记终结后注入无授权 COMMITTED 核对原错误域。

失败完成的 status 仅来自该序号/文档代数 load 的首个错误；取消未产生原生错误时为 0，不借用此前脚本或其他操作的错误。`nativeFailure()` 仍保存最近原生诊断，不因新加载而清零。上述隔离在当前 64 位 Linux State 中增加固定 24 字节元数据，无新增分配、历史表或轮询；State 本体按 `sizeof` 分配，不属于响应 body 的字节额度。夹具分别验证真实 JavaScript 错误后取消刷新、以及注入重复 load-failed 的首错保留，后者不宣称引擎实际产生了两次错误。

`P01_PROBE=history-events bash scripts/webkit-probe.sh` 独立记录真实 policy/list/uri/is-loading/LOAD 次序及 DOM token；`P01_PROBE=navigation-zig` 运行公开 `smoke-webview-navigation-linux`，覆盖本地整页导航、原生前进/回退、同文档 IPC/代数、当前地址刷新、拒绝脚本导航、分配失败、准备中 stop、实际 loading 结束后的拒绝/恢复，以及完成回调/raw parent/allocator 关闭和立即释放宿主。夹具还注入未经授权的 native STARTED，验证 GLib 错误域、旧入口撤销与显式 recover，末尾 native resources=0。这类 `Event.failed` 仍按原合同要求重建 controller，不承诺在失败 controller 上重新开放业务入口。证据限前述已安装的 X11/WebKitGTK 版本，不把其事件顺序推广到未经测试的引擎或 Wayland。框架不主动泵消息或新增线程。

### Linux 显式远程页面

远程模式另需部署与应用匹配的原生 WebProcess 请求扩展：`zig build webview-request-extension -Dwebview=true` 将 `libziggurat-request-policy.so` 安装到 prefix 的 lib 目录。应用明确传入该原生代码目录的绝对路径；不搜索当前目录、不下载扩展，也不从页面参数选择目录。普通 HTML/custom 本地模式不加载此扩展。

```zig
try view.attach(window, .{
    .html = "",
    .storage = .ephemeral,
    .remote = .{
        .url = "https://example.test/app",
        .origins = &.{.{ .origin = "https://example.test", .ipc = true }},
        .credentials = .ephemeral,
    },
    .request_policy_extension = .{
        .directory = "/opt/application/lib/ziggurat-policy",
        .handshake_timeout_ms = 5000,
    },
});
```

`remote_pages=true` 表示此显式能力。Linux 的 storage/credentials 必须一致：临时 Context 都选 ephemeral，持久页面都选 profile 并提供同一 App 的显式 Profile owner。临时 Context 仍允许本次生命周期内的 Cookie/cache，不代表禁止 Cookie；持久选择不扩大 origin、请求或系统凭据授权，HTTP credential 持久存储仍禁用。配置与目录字符串、全部来源和请求头规则在 attach/reload 时复制；`html` 必须为空，不能同时选择 local。Windows 保留 credentials=profile，不接受 Linux 扩展路径。

Windows/Linux 可另行显式配置创建期冻结的 `request_credentials`，只为独立授权的精确 HTTPS 来源发送宿主 Bearer。它与 HeaderGrant 校验分开；首请求/子资源/每跳重定向使用同一发送门禁，无凭据目标不注入本模块 Bearer，Profile 不保存这份配置。非空表不能组合任一 Authorization HeaderGrant；空表不修改已有字段。它只约束本模块 Bearer，不代表匿名 Profile 或禁止 SDK/操作系统另加自己的认证。ABI、最后回收、实际 Runtime 验收及 SDK 内部副本边界见[请求凭据](request-credentials.md)。

Windows 独立 TLS 验证夹具由宿主显式运行 Python 3.12+；它的固定测试证书例外不进入生产适配器，命令及证据范围见上述请求凭据文档。

每个 View 创建独立 Context，先安装不可变请求配置，只加载空白 bootstrap。WebProcess 先接入发送前的请求过滤，再返回 ABI、策略 ID、WebPage ID 和有效标记。宿主同时等待该身份握手与 bootstrap 完成，才发布 ready 并发出首个远程请求。启动期缺失、不兼容或错误身份以及 1–60000ms 的一次性截止失败，均不加载应用 URL；ready 后重复或不匹配 ACK 也会撤销后续入口。GLib 错误域为 ziggurat-webkit-request-policy，code 1 为身份不匹配、2 为超时、3 为文档准备失败。无等待线程、主线程阻塞或嵌套循环；关闭会撤销该 source。recover/reload 建立新的策略身份，旧 ACK 不能启用新实例。

最多32个精确 HTTP(S) origin，来源最长1024字节、URI最长16384字节，拒绝 userinfo、歧义数值主机、尾点、非 ASCII authority 和内部合成站点。HTTP 仅限显式允许的回环地址；HTTPS 回环同样需 `allow_insecure_loopback=true`。IPv4 127/8、IPv6 `::1` 与映射/兼容 IPv4 回环采用相同规则，`127.example.test` 是普通 DNS 名。这里不查询 DNS、不承诺阻止 DNS 重绑定；TLS 证书检查由引擎执行。

导航、资源请求和 IPC 分别授权。顶层目标必须同时拥有 navigate、requests 和 GET；requests-only 来源可以服务子资源。请求扩展在初次发送及每次重定向前检查实际 origin、method 和可见 headers。每来源最多16个自定义 header、合计8192字节，exact_value 区分空值与任意值；浏览器管理的 Cookie/Origin 等头沿用明确的 managed-header 合同，不修改或注入请求。配置序列化和临时拥有描述均有1MiB上限，不把它当作网页正文或引擎内存限额。

宿主 `navigateRemote` 明确提交目标；路径/query 的转义内容不折叠成另一条授权 URL。脚本导航默认拒绝，`allow_script_navigation` 只允许已有来源的顶层导航；`allow_redirects` 控制顶层 HTTP 重定向，子资源重定向仍逐跳检查请求规则。页内 fragment 改变保留同一 PageId、私有脚本标记和 IPC，报告 source_changed；整页加载才更换文档代数。原生前进/回退、当前地址刷新、stop/reload/recover 沿用上一节的事务和失效规则。

固定的构造式 CSP 另拒绝 frame、worker、object、base、form 与 ws/wss，只为已授予请求的 HTTP(S) 来源生成资源/connect 项。服务器自己的 CSP 继续叠加，不能放宽此策略。实际测试包括服务器返回允许 WebSocket/blob worker 的宽 CSP，相关请求仍为零。导航策略、CSP 和 WebProcess 请求过滤共同实施此合同，不构成操作系统网络沙箱，也不限制引擎内部执行或网页内存。

IPC 只在 committed 文档且该 origin 的 ipc=true 时通过。独立 script world 在每次文档开始时构造一次浏览器规范 origin 集，保留顶层真实 MessageEvent/source/代数检查；宿主 post 同样检查当前来源。ipc=false 不妨碍宿主明确 evaluateJS，但会拒绝页面收发消息。关闭先撤 Zig owner，再取消 sources/异步操作、断开信号并拆卸 widget；迟到回调仅持独立 C State。普通 HTML 不分配 RemoteData、来源数组或握手 timer，其脚本准备仍使用原有栈存储。

`P01_REQUEST_PROBE=policy|remote-test|runtime|strict bash scripts/webkit-request-probe.sh` 分别验证纯规则、原生拥有配置及独立引擎过滤。`P01_PROBE=remote|remote-zig bash scripts/webkit-probe.sh` 验证实际 C adapter 与公开 View：缺失/错误 ABI 的零请求失败、GET/HEAD/header、POST/跨源/worker/WebSocket 拒绝、导航及重定向开关的目标请求计数、IPC 独立授权、fragment、刷新/reload/进程 recover/旧 PageId、所有 allocator 故障和 ready 中立即关闭，最终 adapter/native refs=0。证据限上述 X11/WebKitGTK 环境，不推定其他引擎版本、Wayland、完整混合焦点或按需文件流完成。

## Linux 有界 PNG 截图

`backendCapabilities().capture_preview` 独立表示 `capturePreview`，Linux 的 `browser_tools` 仍为 false。Windows 同样报告这个独立能力。先在原有 Options 中设置 `.tools = .{ .capture = true }`，等页面完成后以该 View 当前 `PageId` 提交；默认关闭时返回 `ToolDenied`，不创建 capture budget、Op 或 PNG buffer。开启不授予 IPC、来源、文件或其他工具权限。请求沿用现有 ToolOperation、Completion 和 deadline：失败不接管 context，接受后恰好一次主线程终结，PNG bytes 只在回调内借用。

Linux 直接调用 WebKitGTK 的可见 viewport snapshot，使用每次调用独有的 GTask/userdata 并在其回调中调用对应 finish，取得拥有的 Cairo surface。在主线程同步调用 Cairo PNG stream encoder，写入提交前一次分配的固定容量 buffer；超限返回整体 `limit_exceeded`，不交付截断 PNG。没有 worker、文件写入、JS 截图、隐藏页面或第二份页面模型。此同步编码会占用 UI 线程；PNG 上限不限制引擎生成 surface、Cairo encoder 的内部临时内存或耗时，也不构成引擎总内存配额。

每个显式 capture budget 的并行上限沿用 `tool_limits.max_pending`（1–8），PNG 预留容量沿用 `max_capture_bytes`（默认 4 MiB，最高 16 MiB）。一个进程另有 8 个物理 capture 请求的硬上限，覆盖所有 View、已关闭 attachment 和 recover 前的迟到请求：默认容量下最多预留 32 MiB，全部设为最大容量时最多 128 MiB PNG buffer。Linux x86_64 实测每个开启的 View 多一个 64-byte budget、每个请求多 56-byte Op，GCancellable/GTask 的内部对象另计；默认关闭仅增加两个 nullable 指针的固定记录成本，该 capture 切片当时的公开 View 从 5016 到 5024 bytes，C State 从 2464 到 2472 bytes。独立 JS 请求仍使用其原有预算。每个 View 在 reload/recover 中复用同一 budget；降低上限不会撤销旧预留或提前归还物理槽。detach 先关闭 budget 入口，再结算逻辑请求；重附加创建新入口，旧入口不能复活，旧任务仍计入进程硬上限。

取消、deadline、导航、reload/recover、Stop 和 detach 先从现有 Book 摘下逻辑请求，再取消原生操作。迟到结果始终 finish/销毁 surface；若逻辑上已取消或关闭，跳过 PNG 编码且不再调用 Zig owner。C-only Op、buffer、budget 和 State 一直保留到该 GTask 最终释放。因此即使成功 completion 已开始，同栈再次提交也可能 `Full`；这与下文 Windows completion 时点的容量规则不同。关闭或 completion 内移除页面并在 `on_closed` 立即释放 View/context，不会让迟到 native callback 使用已释放 Zig 地址。正常库路径没有为等待这些物理引用添加循环或 timer。

Linux 原生 Find 是独立的 `capabilities().find_text` 能力，仍不开放整个 `browser_tools`。显式启用 `Options.tools.find` 后可做 substring、大小写和原生全部高亮；`whole_word=true`、`highlight_all=false` 明确返回 `UnsupportedCapability`，不会读取 term、分配候选或修改旧场次。没有将词首匹配替代整词。`findCapabilities()` 分别报告整词、可控高亮、step 总数和活动索引；Windows 保留原生已知结果与原有选项。

WebKitGTK 的初次 search 成功或失败可返回已知总数或零，但活动索引为未知；next/previous 提交后缓存的 count/index 都置未知，step 终态也不把原生局部计数当全页总数。不会额外调用 count_matches 拼接成原子快照。页面 DOM 可在命令之间变化，已返回的 count 不是持续准确的页面订阅。

Linux 同一原生 controller 只有一个未退休的物理 Find 命令。取消或超时先终结业务一次并停止逻辑场次，不能撤销已发送的 SDK reply；在真实 found/failed 或旧 controller 最后释放前，新 start/next/previous 返回 `Full`。普通同 WebView 导航也保留这个占用；`reload(options)`/`recover()` 真正重建原生页面，旧 controller 的独立引用和额度仍留在同一 View 预算域直到最后退休。若 SDK 不给终态，框架不以 timer、轮询、隐藏队列或自动重建提前放行。`stopFind()`、关闭通知和逻辑完成都不是 SDK 引用归零屏障。

默认为 View 和 native State 各增加一个可空指针；工具关闭或仅开启而尚未发命令，不创建 FindDomain/Gate/Command，也不进入 4097 字节的 noinline 查询捕获 helper。第一次允许的查询才复制输入并创建原生拥有者，旧 gate、候选、迟到 command 同时计费到实际 free 返回。本轮 x64 的旧891/新 View 为 5024/5032 字节、native State 为 2496/2504 字节；Domain/Gate/Command header 为 56/112/56 字节，N=`tool_limits.max_pending` 的新增请求字节上界为 `56 + N*112 + N*(56+4097)`，N 在 1..8。Command 可延长其旧 native State、完整配置和 SDK 对象的寿命；这些既有存储不计入 Find 新增字节，该公式不是全部引擎内存上限。

固定 Zig 0.15.2 / WebKitGTK 2.52.6 的 Debug 与 ReleaseSafe 已用真实公开 View/Book 路径验证顺序查找、大小写/UTF-8、step unknown、取消/timeout 后物理 Full、普通刷新、原生 reload/recover、关闭/raw close/Stop 和最终引用零。进程故障可先完成旧 SDK 查找为零，再发实际 process_failed；成功的零结果不表示恢复成功。恢复另需显式 recover、新文档 PageId 与新查询结果。此结果不扩展为其他引擎版本或完整浏览器工具支持。

## Linux 整体数据清理

`backendCapabilities().clear_browsing_data` 独立表示 `clearBrowsingData`，两平台均报告；Linux 的 `browser_tools` 仍为 false。设置 `.tools = .{ .clear_entire_profile = true }` 后，`clearBrowsingData(.entire_profile, options, completion)` 对该 View 自己的 WebKit 网站数据管理器调用一次全部数据类型、全部时间范围的原生 clear；成功为 `.cleared`，GLib 错误为 `native_failure` 并保留完整域/码快照。持久 `.profile` 页面清除的是整个显式 Profile，会同时影响共用它的其他 View 与 CookieStore；`.ephemeral` 页面只清除自己的临时 Context。这是宿主能力，框架不弹确认框，也不按 origin 清理。默认关闭时返回 `ToolDenied`。

清理是 Profile 作用域请求：不要求当前文档已提交，普通导航不终结它；reload/recover、detach、App 停止和进程失败仍按工具通用规则终结回调。它与截图共用同一个显式 budget、每 View `max_pending` 和进程级 8 个物理请求上限，仅开启清理时不预留 PNG 容量，每请求只多一个 56-byte Op。取消或超时只终结宿主回调，GCancellable 不保证撤回已经执行的删除；物理槽保留到原生 GTask 结果释放。已打开文档的内存状态由引擎决定，验证以随后加载的文档为准。

`smoke-webview-cookies-linux` 在随机私有 Profile 中先由 CookieStore 写入 HttpOnly Cookie、页面写入 Cookie 与 localStorage，再经 View 清理；随后 Store 查询为空、reload 后的新文档看不到旧 Cookie 和 localStorage，并验证取消恰好一次与 deadline/关闭路径。`test-webkit-capture` 用受控 GTask 验证清理与截图共享配额、不要求文档、OOM、取消后迟到完成、真实错误和回调内关闭；最终原生计数归零。

Linux PDF 也保留 `UnsupportedCapability`。已核对的[WebKitGTK 2.52.6 实现](https://github.com/WebKit/WebKit/blob/webkitgtk-2.52.6/Source/WebKit/UIProcess/API/gtk/WebKitPrintOperation.cpp)在无对话框 print 入口仍自行同步枚举 printer；[GTK 3.24.41 枚举实现](https://github.com/GNOME/gtk/blob/3.24.41/gtk/gtkprinter.c#L1182)可能进入递归主循环，不能满足本项目主线程合同。提前枚举不跳过这次内部枚举。其[文件打印后端](https://github.com/GNOME/gtk/blob/3.24.41/modules/printbackends/file/gtkprintbackendfile.c#L398)还在主循环同步写文件，关闭输出的错误未传回原完成，并登记最近文件；这条路径尚未建立既有私有异步PDF合同。没有启动打印操作或更改系统打印配置；未来适配需要可验证的非阻塞输出边界与独立拥有的结果。

`P01_PROBE=capture-zig bash scripts/webkit-probe.sh` 使用显式隐藏的合成页面，通过 PNG signature/IHDR、完整像素颜色和真实 GTK scale 核验结果；同时覆盖默认零分配、全部 Zig allocator 故障、cancel/deadline/导航/reload/recover/close/Stop、回调内释放 owner 及最终物理引用归零。`P01_PROBE=capture-owner` 独立调度生产 C owner 的 GTask，验证真实 malloc/calloc 失败、同步完成内关闭/重入、跨 restart/已关闭 budget 的物理限额和 C-only 迟到 finish。这些是机器结构与生命周期 oracle，不打开图片或浏览器，不建立视觉质量、GPU 加速或其他平台的运行结论。

## 原生页面区域

Windows 和 Linux/X11 已实现独立矩形区域；`backendCapabilities().regions` 表示放置与寿命合同，跨区域 Tab/输入法和页面会话仍独立查询。下述 controller/HRESULT 失败恢复适用于 Windows。Linux 使用 GTK3 整数逻辑坐标：先沿公开规则舍入物理边缘，再以原生整数 scale 向外覆盖到逻辑边界；分数 DIP 在此边界量化，不声称像素级子逻辑位置。

`View.attach(window, options)` 保留独占整个 Window.Content 的原有行为。需要同窗多个页面时，先显式 `composition.Owner.create(allocator, window, .{ .capacity = 4 })`，由这个 owner 独占 Content，再 `owner.reserve(.{ .bounds = dip_rect, .visible = true })` 和 `view.attachRegion(region, options)`。每个 View 同时只附加一个区域；backdrop 区域不能附加 WebView，返回 `NativeRegionRequired`。View 地址保持到 participant detach，Owner 和 App 覆盖所有借用 Region 句柄的使用期；Window 关闭并完成 detach 后显式 `owner.close()`。

Region 是 owner、槽位、代数的值句柄，移除后立即失效，旧副本不会因槽位复用恢复。`region.update(viewport)` 使用窗口客户区 DIP，按当前 scale 在原生边界舍入矩形边缘；空尺寸或 visible=false 隐藏 controller。布局、显隐和窗口 resize 不重建文档，不改变 PageId 或清空页面变量。controller 异步创建及 `reload`/`recover` 使用当时最新区域，而非恢复成全窗。几何更新无每帧分配，原生失败尝试恢复上次 bounds/visibility；恢复也失败则关闭 controller 并报告失败，不能把半次更新当作成功。核心 window_position 事件同时通知原生父窗口位置变化；区域和旧全窗路径都保留实际 HRESULT，并将失败报告为 webview_geometry。

`region.remove()` 关闭这个 View 的原生页面，不关闭同窗其他区域。移除先撤销入口；已有 Region/Window callback pin 退栈后恰好一次 detach。此时同步 Responder、PageId、属性及请求入口立即返回 Closed；五类已接受请求一并取出，再取消原生入口和 timer，最后以 detached 终结。回调持有配置到退栈，晚到 COM 只访问自己的已关闭原生 State。同一 View 可在 detach 后重附加，得到新文档代数；这会重建页面，**不保留原 DOM、JS 或历史**。同一 View 的已有 scheme/environment 不变性规则不因区域模式放宽。

安装与拆卸各有明确事务阶段；配置分配、失败回滚及最终释放期间，对同一 View 的再次 attach 返回 AlreadyAttached。宿主 allocator 也可能重入窗口操作，因此 callback pin 覆盖整个分配和回滚；原生提交前再检查 attachment 与所需 PageId。若转换结果的分配使区域失效，已经接受的请求按 detached/page_changed 终结，不把迟到转换当作成功；Profile 范围请求仍可跨普通页面导航。没有接管 completion 的失败不会发回调。

Linux 在首个区域显式创建共享 GTK overlay，保留原 drawing area/IM 对象与 backdrop；每个区域有独立 owning child 引用，最后区域撤离后恢复原 area。普通全窗 attach 不创建区域层，区域与旧独占宿主互斥。层和子项的物理 pin 覆盖全部 GTK 释放/重入，关闭先撤入口，更新/焦点内部操作期间再次修改宿主返回 Busy。初始挂载的最后一次 foreign scratch free 之后再检查关闭/停止，失败回收候选页面及本地/文件/action budget。生产路径不新增线程、磁盘读取或等待。

`P01_CONTENT=regions bash scripts/linux-content-probe.sh` 验证双子项、实际 GTK 几何、隐藏/空区域、分配失败、重入撤离与 raw parent close；`P01_ASAN=1` 使用显式 GCC/ASan。`P01_PROBE=regions-zig bash scripts/webkit-probe.sh` 运行真实双 DOM：无分配 move/hide/empty、PageId/变量保留、pinned remove、槽位复用/新文档、候选 OOM、normal/raw close 待完成回调及最终资源归零；HTML/custom 的普通/区域挂载均覆盖最后 scratch free 关窗。该区域夹具本身不验证离窗 Session，后者见下节；任意 clip/overlay、混合焦点或 AT-SPI 继续待实现。

首片使用原生子窗口矩形、可见性和原生 z-order，不提供任意裁剪、圆角、透明覆盖、跨页面 Tab/capture 或 UIA 树混合；它们需要各自的输入与绘制整合。WebView 不直接绘入 UI 命令缓冲。旧 attach 不隐式创建 composition owner、预留槽位或停放窗口；区域模式额外持有一个借用句柄和 callback guard，页面与请求资源仍由每个 View 显式拥有。

`smoke-composition-webview` 使用独占临时 Profile 和隐藏窗口，在一个真正的 GDI backdrop 上附加两个页面，查询原生子窗口的位置、尺寸、WS_VISIBLE，并用脚本核对各自的 viewport 与变量。覆盖背景绘制/resize/移除重附加、真实父窗口移动、显隐、单页 reload、pending 与回调内移除、异步资源 detached、失败入口保留拥有结果、旧槽位与同一 View 重附加，也核对旧全窗 attach 的 resize/move。未建立视觉质量、任意覆盖、独立离窗 Page 或 Linux WebView 支持的结论。

## 离窗页面会话

Windows/Linux 的 `PageSession` 在稳定地址内拥有唯一 `page: View`。配置、PageId、历史和五类异步请求簿都由这个内嵌 View 持有，不复制第二套页面状态。先 `PageSession.init(allocator, context, on_event)`，再 `session.open(app, .{ .page = options, .initial_size = .{ .width = 800, .height = 600 }, .on_closed = handler })`。`initial_size` 是正数物理客户区像素，在 controller 和 DOM 创建前应用；默认 800×600，可显式配置。JS 的 CSS 像素尺寸还受 Runtime 的 DPI/缩放影响。open 只提交异步初始化，仍须观察 ready 和页面事件。

`session.attachRegion(region)` 只接收同一 App 的 native 区域；`session.park()` 移除当前区域并隐藏页面，保留最后提交的物理尺寸。正常 `region.remove()`、宿主 Window 关闭及 park 都撤销旧区域入口，等待其 provider detach 完成后才能重挂新区域。旧 Owner 在 Window.on_closed 后可关闭并释放；Session 不借用它继续运行。跨宿主挂载和停放不重新加载文档、不改变 PageId，已接受请求与 DOM/JS/历史继续由原 controller 拥有。`session.page.reload`、recover、导航和来源策略仍遵守原来的代数、权限及失败契约；不能对内嵌 page 再调用旧 attach/attachRegion，这会返回 ManagedSession。停放时 Responder.window 为 null，该可选字段仅提供宿主信息，入口有效性由页面会话判定。

Windows 的每个显式 Session 多拥有一个原生 host、一个隐藏 parking HWND、一个固定 child bridge HWND，以及一个 App StopParticipant；controller 始终以 bridge 为父，只移动 bridge 的 Win32 父子关系。旧独占 View 和普通 View.attachRegion 不创建这些对象。所有操作及回调仍在主线程，无隐藏线程、磁盘访问、持续 timer 或嵌套消息循环。Session 不隐式保持 `App.run` 存活；零窗口应用仍按 App 既有策略退出，预加载的宿主需要显式管理窗口寿命。

Linux 使用同一 Session/View/Stop 节点和已有 WebKit State，在停放时直接持有无父、未 realize 的 WebKit widget，不创建 parking GtkWindow、额外 WindowRecord 或第二份页面所有者。普通 View 不创建 Session 专有对象。仍须显式使用 ephemeral；custom 站点、私有文件流与 remote 的原有来源和请求扩展策略不变。初始物理尺寸必须能按当前整数 scale 精确表示，无法实现时返回 `NativeGeometryNotApplied`；区域按两条物理边缘再量化到 GTK 逻辑边界，空/隐藏区域保留最后非空 DOM 尺寸。raw 父窗口销毁在早期撤离既有内容层；正在 GTK set_parent 的 child-parent 链保持到 foreign 调用退栈，之后在普通安全点拆卸。两个 Session 可共享一层，各自停放、关闭或重挂不改变另一页的 DOM/PageId。不同缩放宿主、Wayland、混合焦点/IME/AT-SPI 和任意覆盖未由这片验收建立运行结论。

父 HWND 的 WM_DESTROY 早期通知只做有界 Win32 撤离和入口失效，不调用 COM、分配或业务回调；普通安全点再处理 provider detach。普通挂载、停放及回滚在 bridge 移动后显式调用 NotifyParentWindowPositionChanged；早期撤离的通知延到安全点。撤离失败保存真实 HRESULT，关闭旧 controller 并通知页面不可用，宿主可按原 recover 契约重建；不声称任何父销毁失败都能保留 DOM。原生几何在提交前核对实际结果，系统截断尺寸视为 NativeGeometryNotApplied，并尝试恢复旧几何。恢复也失败时保留失败状态，而非发布未实现的 viewport。

`session.close()` 关闭页面、取消已接受请求并释放 host，返回 closed 或 deferred。已有 callback pin 或旧 provider detach 尚未结束时返回 deferred；`isClosed()` 包含关闭中，不能据此释放存储。成功 open 后的最终 `on_closed` 恰好一次，且在所有 provider 撤销后通知，允许回调立即释放整个 Session。App 覆盖 Session 的完整使用期，Session 和共享业务 context 必须稳定到该通知。原生关闭失败保留存储和 StopParticipant，显式 close 或 App.finishShutdown 可重试；失败 open 不触发 on_closed，调用者检查 close 的结果后自行释放。应用停机先排空已接受任务，再停止页面资源，最后由窗口安全点完成 provider detach；所有旧请求先一并取出、取消入口与 timer，再按 detached 结算，不能因 stopping 误报 timer_failed。

`smoke-page-session` 在真实 Runtime 和私有 Profile 下核对初始停放尺寸、GDI backdrop、两个宿主间的 DOM 变量及 PageId 保留、脚本 completion 内 raw DestroyWindow 后重挂、旧 Owner 与最终 Session 立即释放、停放和挂载状态的三类 deadline 关闭、已接受退出任务销毁挂载窗口，以及 allocator 重入关闭后的提交拒绝。`smoke-page-host` 独立验证原生构造/分配/关闭失败、回滚、尺寸截断、早期撤离与重试；`pageHostResourceCounts()` 统计实际存活 host/parking/bridge，最后 COM Release 不拥有这些 HWND。该组 Windows 检查不建立任意裁剪、UI overlay、跨页面焦点/IME/UIA 混合或视觉质量。

Linux 的 `P01_PROBE=session-host bash scripts/webkit-probe.sh` 独立验证无父 DOM/IPC、实际 allocation、首次建层关闭及12种暂定挂载中的 raw parent destroy。`P01_PROBE=session-zig` 运行公开 Session：初始/区域几何、全部 host 分配失败、双宿主与同层双 Session、挂载/停放 reload 和自有 WebProcess recover、JS/异步资源/文件流跨宿主保留、远程握手首请求屏障/fragment/history/refresh、App Stop 和零窗口关闭、文件 pump 取消及 worker 的 post Closed 归还、最后 native scratch free 的 close/quit，以及 queued reload 后 Session 立即自释放。Debug/ReleaseSafe 的1×/2×均实际通过。夹具以显式独立 App 收尾迟到 native refs，最终窗口、Region、Stop、请求、文件与native预算归零；库没有加入等待线程或轮询。

## 导航与来源

`Options.allow_local_navigation` 默认 false。首次文档加载以外的脚本/链接文档导航默认拒绝；显式设为 true 只允许配置的 `LocalSite.host`，不会放行远程 URL、文件、frame、弹窗、下载或权限。未由本地资源响应器处理的请求仍被拒绝，导航能力不授予网络访问。同一文档的 History API/fragment 状态变化不等同于新文档，不因此更换 PageId。

宿主可调用 `view.navigateLocal("/settings")`，该方法仅允许现有资源路径语法：以 `/` 开头、最多 4096 字节、ASCII 字母数字和 `/-_.`，不允许 `.`/`..` 路径段。方法为下一次匹配的本地导航授权，不改变脚本/链接的默认策略。此宿主方法尚不支持查询串、fragment 和更广泛的 URL 语法。

`goBack`/`goForward` 使用当前 controller 的本地历史，没有相应项时返回 `NoHistory`；不访问旧 controller 的历史。`refresh` 保留当前 controller 并刷新文档，`stop` 请求 Runtime 停止加载。它们返回时不保证页面已加载或已经停止；使用事件观察结果。`reload(options)` 仍表示事务替换完整配置并重建 controller，与 `refresh` 不同。

宿主授权同时校验原生 NavigationKind：前进/后退只接收 BACK_OR_FORWARD，刷新只接收 RELOAD，显式 URL 只接收 NEW_DOCUMENT；未开始的历史请求不能替别的脚本导航放行。依赖此信息的请求在 Runtime 不提供相应接口时拒绝，不根据 IsUserInitiated 猜测来源。默认脚本限制下，重定向不继承一次性授权。

未 ready 或重建中返回 `NotReady`；原生关闭后返回 `Closed`。一次原生导航尚未进入 Starting 时，下一次导航请求返回 `NavigationPending`，没有隐藏队列或自动重试。`stop` 可撤销尚未开始的一次授权；它不能撤回已经发生的业务副作用。

## 远程页面

`Options.remote` 与 `local`、非空 `html` 互斥。显式配置初始 `url`、最多 32 项 `OriginGrant`，并填写 `credentials = .profile`；初始化复制 URL 与 grant 字符串，重载的资源释放次序不变。每项 `origin` 只有 scheme、host、可选 port 和可选结尾 `/`，不接受 wildcard、路径、查询串或 fragment。

```zig
.remote = .{
    .url = "https://example.com/start",
    .origins = &.{
        .{ .origin = "https://example.com", .ipc = false },
        .{ .origin = "https://cdn.example.com", .navigate = false },
    },
    .credentials = .profile,
},
```

三个许可分开检查：`navigate` 允许顶层文档，`requests` 允许该 origin 的可拦截 GET/HEAD 请求，`ipc` 才赋予宿主消息权限。导航或 IPC grant 同时要求请求与导航权限；可以单独授予 CDN 请求权限。相同规范 origin 的重复 grant 拒绝，不能通过另一项覆盖权限。默认没有远程配置；配置远程页时 IPC 仍默认 false。保留的 `ziggurat.invalid` 及其子域不能成为远程 grant，远程模式也不挂载本地资源响应器。

`navigateRemote(url)` 只授权下一次匹配的 NEW_DOCUMENT 导航；`allow_script_navigation` 默认 false，链接/脚本需单独开启。`allow_redirects` 默认 false；开启后只接收已经接受、正在进行的同一原生导航 ID 的重定向，每一跳仍必须拥有目标 origin 的导航许可。显式导航不会永久打开脚本权限。历史、刷新、停止和 PageId 延续前述规则；Runtime 不提供 NavigationKind 时不猜测宿主的一次性授权。

Windows 通过 [CreateUri/IUri](https://learn.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/platform-apis/ms775098(v=vs.85)) 解析并比较精确 scheme、host、有效端口，大小写与默认 HTTPS 443 规范化；不使用字符串前缀或正则判断 origin。URL 最多 16384 个 ASCII 字节、单项 origin 最多 1024 字节；国际域名用 ASCII A-label，路径用百分号编码。userinfo（含空 `@`）、反斜线、空白/控制字符、host 百分号和结尾点拒绝。IPv4 authority 必须是规范四段十进制，拒绝整数、十六进制、缩写和带前导零形式。

常规远程只允许 HTTPS。开发用 HTTP 仅支持标准 127/8、`::1`、`localhost` 及 `.localhost` 名称，并需显式 `allow_insecure_loopback = true`；HTTPS loopback 也需该开关。它们仍须逐个列入精确 origin 表，端口没有隐式放行，也不自动获得 IPC 信任。不做 DNS 查询，因此不声称阻止域名解析变化或 DNS 重绑定；TLS 校验沿用 Runtime，不忽略证书错误。

`credentials = .profile` 明确使用所选 profile 的浏览器 cookies、缓存和可能已有的认证状态，不提供匿名/无凭据保证。框架默认不注入密码或 token；显式 `request_credentials` 只按[独立请求凭据合同](request-credentials.md)注入本模块的 Bearer。URL 凭据仍拒绝，并取消 Runtime 发出的 Basic/代理认证和客户端证书选择请求，避免弹出认证选择窗口。使用应用独占 profile；不同信任域是否共用 profile 由应用决定。

frame 文档导航、弹窗、下载、权限仍默认拒绝。资源入口额外限制 DOCUMENT 请求只能匹配正在加载的顶层地址，非文档资源必须有对应请求 grant。每个 `OriginGrant.methods` 默认仅 GET/HEAD；POST、PUT、PATCH、DELETE、OPTIONS 分别显式开启，不存在 allow-all。写请求的 body 由 Runtime 原样发送，框架不在 UI 读取它，也没有请求体大小/上传耗时预算。OPTIONS 和后续实际请求各自检查权限，不自动放行 CORS preflight。`WebResourceRequested` 的覆盖范围由 [Runtime 请求拦截 API](https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/webresourcerequested) 决定：这不是整个浏览器的网络沙箱，不保证覆盖 WebSocket/WebRTC、DNS、Runtime 自身流量或全部缓存行为；严格网络隔离需由宿主另行部署。

远程双向 IPC 都要求显式 `ipc` grant。接收还要求当前已提交的顶层 Source、controller 当前地址与保存来源一致；新文档 Starting 到 ContentLoading 之间不接收。`post`/`postFor` 向未信任或未提交的远程来源返回 `IpcOriginDenied`。授予某 origin IPC 就信任它的全部页面，路径不是权限边界；应用继续使用 session 和 PageId，不能把 origin 许可等同于业务授权。

## 请求头与有界异步响应

`OriginGrant.request_headers` 只校验观察到的请求头，不修改或注入它们。名称用不区分大小写的 ASCII token，最多 64 字节；值为最多 2048 字节的可打印 ASCII。每个 grant 最多 16 项、8 KiB，不允许同名重复规则。`.{ .name = "Authorization", .exact_value = "Bearer private-token" }` 精确按值字节匹配；省略 exact_value 明确允许该名称的任意合规值。所有未列入下述固定集合的头都必须匹配规则，包括 Content-Type、Range、Authorization 和非 X 前缀自定义头；不会只检查 X-*。禁止将 framing/hop、Proxy-* 或固定集合伪装成可控 grant。

固定透传集合为 Accept、Accept-Encoding、Accept-Language、User-Agent、Origin、Referer、Cookie、Host、Connection、Content-Length、Cache-Control、Pragma、DNT、Priority、Upgrade-Insecure-Requests、If-Match、If-None-Match、If-Modified-Since、If-Unmodified-Since、If-Range、Access-Control-Request-Method、Access-Control-Request-Headers 和 Sec-*。其中部分值也能由页面 JS 设置，无法从该 API 判断生成者。单次观察最多 64 个头、16 KiB 名称和值，非法或超限整体拒绝。网络栈可能在观察后追加 Cookie 等头，因此该规则不能实现无凭据网络沙箱。精确 origin 仍包含 scheme/host/有效 port，重定向到另一 origin 要重新通过目标规则。

`LocalSite.methods` 和 `request_headers` 使用同样规则，默认 GET/HEAD、没有额外可控头授权。`ResourceRequest` 给回调借用 uri、path、method 和 headers；不得逃逸到 worker。body 未读取/快照，也不把原生 IStream 指针交给后台线程。需要保留元数据时显式复制。内存静态文档和资源只处理 GET/HEAD，额外方法交给 `on_resource`。`dynamic_document = true` 显式让起始文档也由该 handler 响应，默认 false 保留静态 html；未配置 handler 时拒绝该配置。动态初始文档在 loading 阶段也允许 defer，不套用 postFor 的 PageLoading 检查。

`Response` 增加显式 headers；status 为 200–599，mime 单独给出。headers 最多 16 项、8 KiB，名称/值使用前述长度与 ASCII 规则，拒绝 CR/LF/NUL、同名重复、Content-Type、Content-Length 和 framing/hop 头。默认 nosniff/no-store，可用同名自定义头显式替换默认值。HEAD 使用同份 representation bytes 的长度产生 Content-Length，但不发送 body；204/205/304 不接受非空 bytes，204 和 304 不发 Content-Length。当前不提供重复 Set-Cookie 头、Range 自动解析或内容协商。

同步 `Responder.respond(response)` 仍在回调内复制，不保留栈数据。`Responder.deferResponse(.{ .timeout_ms = 30000, .completion = optional })` 返回 `ResourceRequestId{view,token,page}`；默认 deadline 为 30 秒，可配置 1 ms–10 分钟。`Options.resource_limits` 默认最多 8 个请求、每响应 16 MiB，均可降低，不得调高；bytes 还受 max_resource_bytes 限制。失败不接管新 completion context，成功后终结一次。未响应时默认拒绝；原生 deferral 在交给应用前就挂好预备的 403 响应，后续失败/取消不会依赖再次分配拒绝 body。

应用在自己的 worker 用 `resources.OwnedResponse.init(allocator, response, max_bytes)` 复制完整响应，再通过 `App.post` 在主线程调用 `view.respondOwned(id, &owned)`。OwnedResponse 拥有一个分配，不可复制；成功消费并清空，错误保留数据，由调用者 deinit。非法输入不改变 pending 请求；通过输入校验后的一次 native commit 尝试会终结该请求，原生错误不保证可以用同一 ID 重试。已消费或旧 token 返回 StaleRequest，关闭/重建遵守 Closed/NotReady；失败 post 不转移结果责任。所有 View/句柄操作只在主线程，worker 只携带 ID 数据。宿主保持 View/回调上下文到相关投递执行完，并在 run 返回后 join 所有后台生产者、再释放 View/App；ID 不延长它们的生命。

这是拥有的整块响应，主线程提交仍有最多 16 MiB 的 native 内存复制及有限 header 转换成本，worker 准备不等于 UI 零复制。原生先收集有限 headers，Zig 用 64 个描述符和 16 KiB ASCII scratch（合计约 18 KiB 栈数据）二次校验；URI 转换和原生 header 字符串仍会分配，不声称请求路径零分配。没有隐式 worker、嵌套循环或轮询。deferral 和现有 JS/tool 共用一个 deadline timer，先同时取出三类旧请求再执行任何终结回调。页面失效/更换、重载、失败和 detach 都拒绝并 Complete 旧请求一次，迟到 ID 不能替新页面响应；独立原生 State 持有 EventArgs/Deferral 到完成，不回调已 detach 的 Zig。`id.cancel()` 同步终结取消，超时为 timed_out；关闭为 detached，进程失败为 unavailable，重新 arm 失败为 timer_failed 并关闭入口。

Windows 的[SDK 响应流契约](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2webresourceresponse) 要求 Complete 时全部 content 已经可用。整块响应仍使用上述内存复制；完整私有文件可使用后文的按需读取接口。这条 Windows 原生响应路径不支持边生成边传；[应用资源字节流](resource-stream.md)另提供显式 IPC ACK 背压，不替换 fetch。[注册页面 scheme](#注册页面-scheme)沿用来源和 IPC 的独立授权。

Linux 可用独立[原生字节生产者](native-stream.md)把已知长度 Source 交给显式 HTTPS
Endpoint，再由 worker 的 Writer 以最多16KiB输入逐块生成，实际页面继续使用原生 fetch。
Source 与私有文件共享 consumer/physical账本，HEAD不生成body，reader.cancel后的业务撤销
由宿主明确处理，Stop不join且最后原生引用才归还容量。该流程仍需Transport/Site、Profile
信任、精确origin请求许可及独立Bearer，不放宽custom写请求缺实际Origin、opaque scheme
或Linux `local_site`，也不把HTTP写出credit当作页面消费ACK。

## 注册页面 scheme

Windows 的 `Options.custom_schemes` 使用真正的 WebView2 环境注册，不改写成 HTTP 地址，不注册操作系统协议或开放文件目录。默认空表没有额外原生 options/registration 对象。最多 4 项 `SchemeRegistration{name,treat_as_secure,request_origins}`；名称为 1–32 个 ASCII 字符，首字符为字母，随后只允许字母、数字、`+.-`，复制时转为小写。HTTP/HTTPS、file/data/blob/javascript/about/ws/wss、浏览器内部等保留名称被拒绝；Runtime 仍可拒绝自己保留的其他名称。`treat_as_secure` 默认 false，只有宿主明确设为 true 才把该 scheme 作为 secure context。

首片只注册 `HasAuthorityComponent=true` 的 `scheme://host/path`，不支持 opaque scheme。选择站点时设置 `LocalSite.scheme` 为已注册的小写名称，沿用原有 host、start_path、静态资源、方法/头规则和动态 handler；默认 `scheme="https"` 完全保留 HTTPS 本地站点行为。同一 View 当前只服务这一个精确 scheme+host，其他注册项、其他 host 或未经授权的 HTTP(S) 仍被拒绝。`navigateLocal`、历史/刷新、PageId、defer/拥有响应、可选私有文件流及失败/关闭规则复用原合同，没有新的隐式线程、网络服务或 UI 文件读取。

`request_origins` 每项最多 8 个、每 origin 最多 1024 个 ASCII 字节，明确同时作为 custom 请求 Origin 前置过滤和 Runtime 的 AllowedOrigins CORS 输入。它默认空：带 Origin 的请求必须恰好一个该头并精确匹配；POST/PUT/PATCH/DELETE/OPTIONS 缺 Origin 也拒绝，null/重复/不匹配不会进入 Zig handler。缺 Origin 的 GET/HEAD 可以继续处理，不能据此证明请求发起者身份。源名单不授予 method/header、导航、HTTP 网络、Cookie 或 IPC 权限；原有 HTTPS local/remote 规则不变。

origin 经解析、规范化并排序，拒绝通配符、opaque/null、userinfo、路径/query/fragment、未注册 custom scheme 以及歧义数字主机；允许末尾 `/`，HTTP(S) 默认端口省略。HTTP(S) IPv6 可以使用方括号；custom host 使用本地站点的 ASCII DNS-label 规则，不接收端口。同源 POST 也需把自己的 custom origin 显式列入，并独立开启方法/请求头权限。跨源访问仍需宿主响应合适的 CORS 头；单独依赖 Runtime CORS 不能保证请求未进入 handler 或没有副作用，前置过滤是这里显式增加的策略。[原生注册契约](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2customschemeregistration)

custom scheme 的原生 origin 只包含 scheme+host，**没有端口或用户信息隔离**。宿主配置拒绝这些字段，事件仍携带的非规范 authority 也被拒绝；Runtime 若已把 `asset://host:123/path` 或 `asset://user@host/path` 规范化为 `asset://host/path`，原始拼写已不可见，只能按相同 scheme+host 授权。本机 Runtime 测试明确观察到这两种规范化，不能用不同端口或 userinfo 隔离不同权限。远程 `OriginGrant` 继续只接受 HTTP(S)，不能冒充 custom 来源，Cookie 工具也始终拒绝 custom URI。custom 页面双向 IPC 默认拒绝，只有 `LocalSite.scheme_ipc=true` 才开启，而且仍检查当前 committed 文档/页面代数；它不受 `treat_as_secure` 或 CORS 列表自动授权。

attach/reload 复制全部注册名称、origin、描述和站点 scheme；静态 body 与回调 context 的借用期不变。最多约 32 KiB origin 字符串及有界描述复制，空表不分配注册 metadata；非空表多一次明确的拥有分配。UTF-16 原生 COM options/registration 另持独立副本，Get* 返回的字符串/数组按 CoTaskMemAlloc 规则归还，异步环境创建或迟到 Release 不访问已 detach 的 Zig 对象。custom 请求的来源解析有有限原生 URI 对象成本。

注册是浏览器进程级配置，不能在运行中修改。recover 重用已拥有的注册集；同一 View 的 reload 只要规范注册集改变就同步返回 `SchemeEnvironmentChange`，即使换 profile 路径也如此，错误不会排队或替换当前配置。需要不同注册集时创建新 View 并提供适当的私有 profile。不同 View/进程共享一个 profile 时必须提供相同注册配置；Runtime 若仍占有不兼容配置，会返回真实原生创建错误，不去掉注册、自动重试或等待。仅关闭窗口不保证浏览器进程已经退出；宿主负责 profile 和浏览器进程的外部生命周期。[环境 options API](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2environmentoptions4)

## 完整私有文件按需响应

`Options.file_streams` 默认 null；显式启用后 `file_responses.Limits` 默认最多 8 个存活物理流、每文件 256 MiB，可降低。进程另有固定 32 个物理流上限。未使用该能力不创建 Budget、Control、FTM、event 或文件句柄；首次提交才创建附着预算。预算跨 reload/recover 保留，降额以实际存活数限制新提交，不替换预算来绕过旧流。直到最后 COM Release 才归还物理容量，EOF、cancel、完成逻辑请求和关闭都不提前归还。物理容量与原有 8 槽 deferred request/计时器分别计算。

宿主先在自己的 worker 打开并准备完整、可信的私有 regular file，再调用 `OwnedFileResponse.prepare(allocator, process_main_thread_id, borrowed_file, head, max_bytes)`。传入已捕获的进程主线程 ID，函数会在任何文件访问前拒绝该线程。`head` 为 `file_responses.Head{status,mime,headers}`，沿用普通响应的 MIME/头预算和拒绝规则。worker 用 ReOpenFile 建独立只读、禁止共享写的 OVERLAPPED 句柄，并验证非目录、disk file 和完整长度；max_bytes 为 1–256 MiB，允许零长度文件。借用原句柄仍属宿主，位置不变；没有目录扫描或路径权限推断。已有 writable mapping 仍需宿主协调，不能把句柄共享模式当作全系统不可修改保证。

拥有结果包含文件句柄和有限 metadata 分配，不复制整个文件，不可复制。`prepareWithFailure(..., max_bytes, native_failure)` 可额外传 `?*?i32` 接收真实 native HRESULT；每次先清空，UI/输入校验及 Zig 分配失败没有伪造的原生码。失败不接管借用句柄。结果的 `deinit()` 只关闭自己拥有的句柄和释放 metadata，不触 COM，可用于 worker 的 post 失败回收。

`Responder.respondFile(&owned, .{ .ticket = false })` 在当前回调内提交；已 defer 时由 `App.post` 调用 `view.respondFile(id, &owned, options)`。UI 只做有限头处理、DuplicateHandle 与 FTM/stream 构造，不重新打开、stat 或读取文件。成功 put/Complete 才消费并清空 owned，任何错误均保留其数据与重试位置；通过校验后开始的 native deferred commit 会终结该请求，即使返回 Full/OOM/HRESULT，重试须使用新请求 ID。失败 post 留给 worker 释放。准备结果、ID 和投递上下文仍遵守原有 View/App 稳定地址与 join 生命周期；拥有结果和 ticket 的独立 native 数据不借用它们。

HEAD 使用文件 representation 长度生成 Content-Length，不建物理文件流、没有 body；204/205/304 拒绝非空文件，204/304 不发 Content-Length。方法、请求头、来源和 IPC 授权不改变；接口不向 Runtime 开放 native file URL 或目录。

可选返回的 `StreamTicket` 只拥有独立取消 Control，未建物理流时为 null。不可复制，用 `clone()` 显式取得第二份 owning 引用；每份引用自行 `deinit()`。`cancel()` 和这些引用操作可跨线程，不访问 COM、View 或 App，也不保留物理流槽。成功后的页面更换、失败、reload/recover 和 detach 会先摘掉旧代控制入口再自动取消流；ticket 可在窗口和 App 析构后继续取消/释放。宿主长期持有的 ticket 仍占自己的 Control 存储，必须显式释放。

原生 IStream 只持有文件、自己的逻辑 cursor/锁、FTM、Budget 和 Control，没有 State/View/App/STA 指针。Runtime 的后台 Read 可以阻塞，每次最多 64 KiB 文件 I/O 后检查取消；多个流使用显式 OVERLAPPED offset，不共享逻辑位置。IO_PENDING 后即使取消也在后台 drain 实际完成，操作结构与输出 buffer 不提前退栈。UI Read 明确失败，UI Seek 锁忙立即返回 E_PENDING，Stat 只读内存；没有 UI join、磁盘读取、隐藏 worker 或嵌套泵。取消不保证中断已经进入内核的单次磁盘操作，也不承诺总体耗时。它是 Runtime pull 的完整文件流，不控制系统预取或页面自身缓存。

## 文件快照

不向 Runtime 开放文件目录，也不在 UI 回调读磁盘。应用自行打开文档和资源文件，在显式 worker 调用 `snapshots.FileSnapshot.init(allocator, main_thread_id, document_file, resources, limits)`；资源逐项提供已打开的 `File`、独立路由 path 和 MIME。没有目录枚举、递归扫描、路径前缀推导权限或隐式 worker，文件句柄仍由调用者关闭。

返回的 `FileSnapshot` 拥有 UTF-8 `html`、资源描述、路由/MIME 和二进制 body，初始化后不可复制。将 `snapshot.html` 与 `snapshot.resources` 传入普通 `Options.local`；`LocalSite` 默认起始路由 `/`。快照保持到相应 `resources_released` 或 detach 后再 deinit；若与窗口回调上下文共享存储，遵守更长的 `on_closed` 生命周期。后续磁盘修改不改变已复制数据，Runtime 只读取内存站点。

只接收 regular file，使用 offset read，不改变调用者文件游标。默认最多 128 个文件（含文档）、每文件 16 MiB、总内存预算 32 MiB；总预算包括文档、body、复制字符串和资源描述，配置总预算最多 256 MiB。路由沿用本地站点规则，拒绝 `.`/`..`、重复项和 `/` 文档冲突。失败回收已复制部分；取消在 stat/read 前后与每个最多 64 KiB 读取块之间检查。单次系统调用可能阻塞，因此必须由应用管理线程、取消和 join，不能在 UI 等待。快照不是文件系统原子事务；应用需协调并发写入，同长度并发改写可能形成混合版本，大小改变会尽可能报 `FileChanged`。

## 页面事件与异步回复

设置 `Options.page_listener` 接收独立 `PageEvent`。监听上下文从 attach/reload 成功后保持稳定，直到相应配置释放或 detach；旧资源释放顺序沿用 `resources_released`。所有回调在主线程，持有核心 callback pin；回调内关闭只在安全点 detach。

事件包括 started、completed、dom_ready、source_changed、title_changed、history_changed、audible_changed。controller 的 ready 不表示 DOM 已就绪。completed 带原生导航 ID、成功标志和 WebErrorStatus；它不把 HTTP 错误状态等同于传输失败。source/title/history 在变化时通知，并在加载完成时发布快照，因此可能有相同值的重复事件，刷新也能得到当前元数据。

每次新文档的 accepted Starting 增加 `PageId.generation`；同一原生导航的重定向沿用代数。`PageId` 还包含所属 View 地址，不能跨 View 使用。View 从 attach 开始必须保持地址稳定，并覆盖 PageId 的使用期。页面代数在 detach/re-attach 或恢复后继续增加，不复活旧页面。

应用在每个 started 事件重置自己的 IPC session、取消上一代业务任务。异步任务保留 `PageId`，返回后使用 `postFor(id, message)`：不同 View、已替换或已失效页面返回 `StalePage`，本代尚在加载返回 `PageLoading`。失败/取消完成会使本代失效，避免把失败加载的回复发给 Runtime 留下的旧文档。代数是宿主生命周期校验，不替代 IPC 的随机 session、来源验证、请求取消或消息确认。普通 `post` 保留原有向当前页面发送消息的行为。

需要在外部 allocator/transport 回调期间固定页面存储时，主线程调用 `view.beginPageCallback(id)`，成功得到零分配的 `PageCallbackScope`。它固定原 attachment 或 Session/App，允许 loading 中的本代；不是发送许可，不延长业务授权。每个外部调用返回后仍需重查当前 PageId/关闭状态。`scope.app()` 只能在 end 前使用；`end()` 可能触发最终 detach/on_closed 并释放 View/整个 Session，此后不得再访问旧对象或借用 context。跨线程仍只携带 ID，不把 scope 移到 worker。

事件的 URI/title 在回调结束前借用。UTF-16 元数据最多检查 16384 单元；超限或 UTF-8 转换失败会报告诊断，并将该字段置为 null，仍发布生命周期事件。宿主不能因缺少标题/URI 而忽略 started 的失效处理。没有监听器时，不做这些 UTF-8 转换，也不注册标题/DOM 观察 handler。

框架拥有的原生来源 URI 同样限制为 16384 单元；本地文档超长导航在 Starting 拒绝，来源变化超长/不可信则撤销消息入口与本代有效性。NavigateToString 的大 data URI 不被重复保存为来源，只保存其实际消息来源 about:blank。Runtime 自身分配和页面内存不属于此适配器预算。超长策略 URI 在拒绝请求后报告诊断，不分配完整 UTF-8 副本。

Starting 到本次 ContentLoading 期间抑制页面消息；之后消息必须来自当前顶层文档的可信来源。同地址刷新无法只凭消息的 Source 区分全部旧代数消息，所以应用必须重置 IPC session，并按 session/任务代数处理迟到结果。页面载入失败或停止也不能证明旧 JS 业务已经撤销。

## 主题色、按内容定尺寸与页面进程

`Options.theme_color = true` 让 View 跟踪页面的主题色：页面 `<head>` 中第一个 `media` 为空或匹配、内容是颜色的 `<meta name="theme-color">`，与浏览器的选法相同。颜色由页面引擎解析，任何 CSS 颜色（`dodgerblue`、`rgb(30 144 255 / 50%)`、`oklch(…)`）都可以，得到 8 位 sRGB 和直通 alpha 的 `web.Rgba`。`View.themeColor()` 返回当前值，`PageEvent.theme_color_changed` 只在颜色变化时通知：页面增删或修改 meta、外观变化让另一个 `media` 匹配、或新页面的颜色不同。刚开始加载的页面在 DOM 就绪前沿用上一页的颜色，所以同色页面之间切换不产生事件；从未报告颜色的文档（例如图片）在加载完成时变为 null。应用可以据此给标题栏、工具栏或窗口背景着色：

```zig
.theme_color_changed => |change| toolbar.setBackground(change.color orelse default_color),
```

`Options.fit_content = .{ .max_width = 400, .max_height = 600 }` 让窗口跟随页面内容的尺寸，像浏览器扩展的弹出页面：页面根元素按内容宽度（`width: max-content`）在限制内布局，文字在最大宽度处换行，高度超过最大高度时页面滚动，此时滚动条的宽度计入窗口宽度。限制以 DIP 给出，0 表示不限，按文档开始时的缩放换算成页面的 CSS 像素；缩放改变后的新限制在下一次 reload 生效。规则没有特异性，页面自己给 `html` 的尺寸（如 `height: 100%`）优先，所以要让 `html` 和 `body` 取内容的尺寸。`PageEvent.content_size_changed` 以 CSS 像素报告根元素尺寸和可见滚动条的空间，`View.contentSize()` 返回最近一次的值。附着在窗口上且 `resize_window = true`（默认）时，View 用 `page_facts.fit` 把尺寸换算成 DIP 并调用 `Window.resize`：只改变真正变化的那一维，用户调整过的另一维保持不变，最大化和全屏时不改变。区域、PageSession 和 `resize_window = false` 只报告尺寸，由应用调用 `web.page_facts.fit` 再交给 `Flyout.setSize` 或自己的布局。

两项都由 View 在每个顶层文档开始时运行的同一段脚本完成（`src/webview/page_facts.js`），与页面来源和信任无关：Linux 运行在私有 script world 中，经私有消息通道只到达 View；Windows 用 `AddScriptToExecuteOnDocumentCreated` 在页面脚本之前取得 `chrome.webview.postMessage`，消息带 `\x01ziggurat-facts:` 前缀，在来源与 IPC 授权检查之前交给 View，不会成为 `Event.message`。页面也能发出同样前缀的消息，但只能谎报自己的主题色和内容尺寸，窗口尺寸仍受应用给的限制。两项都关闭时不注入脚本。

`View.processId()` 返回运行页面的操作系统进程 ID，供应用自己的任务管理器或内存报告使用：Windows 是同一 App 的页面共用的 WebView2 浏览器进程（`msedgewebview2.exe`），WebKitGTK 没有对应 API，Linux 总是 null。

## 不受信任页面、开窗手势与自动播放

`Options.untrusted = true` 把页面当作别人的页面，例如从自定义 scheme 显示插件界面：无论来源的授权（`OriginGrant.ipc`、`LocalSite.scheme_ipc`、普通 html）如何，页面的消息都不会成为 `Event.message`；`post` 仍能把消息送达页面。页面通往应用的通道是它向自己 scheme 发出的请求：`on_resource` 收到的 `ResourceRequest.page` 是发出请求的文档的 `PageId`，处理器据此判断是哪一个页面、哪一代文档在请求，再用 `postFor` 回复。权限、下载、新窗口和跨来源导航仍按各自的显式策略处理，默认全部拒绝。

`PolicyRequest.user_gesture` 说明导航或新窗口请求是否由用户手势发起：点击链接，或在点击、按键的处理函数里设置 `location.href`、调用 `window.open()`；页面脚本自己（定时器、加载时）发起的为 false。Windows 来自事件参数的 `IsUserInitiated`；Linux 来自 `webkit_navigation_action_is_user_gesture`，`window.open()` 经 `create` 信号报告。WebKitGTK 自己会先拒绝没有手势的 `window.open()`，所以 Linux 只会报告有手势的那些；WebKit 和 WebView2 都把宿主 `evaluateJS` 运行的脚本视为用户手势。frame 导航不提供该信息，为 null。Linux 现在也接受 `policy.new_window = .notify`。

`Options.autoplay = .allow` 让页面在用户点击或输入之前就能播放有声媒体，隐藏窗口里的页面也一样：默认情况下没有手势时，有声的 `<audio>`/`<video>` 的 `play()` 以 `NotAllowedError` 拒绝。Linux 在每次主 frame 导航的 website policies 中设置 `WEBKIT_AUTOPLAY_ALLOW`。Windows 以 `--autoplay-policy=no-user-gesture-required` 启动浏览器：这是 WebView2 环境的参数，同一 user data folder 的所有 View 共享环境并且必须一致，否则后创建的 View 失败；Windows Profile owner 暂不接受这个选项（`UnsupportedCapability`）。

`smoke-webview-page-facts` 在隐藏窗口的真实页面中检查：初始主题色和脚本修改后的颜色、内容尺寸与窗口按内容调整为 266×136、自动播放不被策略拒绝、全部 frame 与任意来源的初始化器在顶层和子 frame 各运行一次、宿主脚本 `window.open` 的手势报告、进程 ID，以及 reload 为不受信任页面后消息被丢弃而主题色仍然报告。Linux 在 WebKitGTK 2.52.6（xvfb）本地通过；Windows 在 CI 的 WebView2 任务中运行。

## 文档初始化器

Windows 的 `Options.document_initializers` 在首个文档前安装已拥有的初始化器，`View.replaceDocumentInitializers` 用一次有界事务替换未来文档配置。每项是宿主信任、语法有效的普通函数体，在页面 world 的 document start、精确 HTTPS 来源守卫通过后按序调用；`frames = .all` 让它在子 frame 中也运行（每个 frame 检查自己的来源），`origins` 只写 `"*"` 时任何来源的文档都运行；return 结束自身，throw 中断后续。默认空表不创建预算、注册或事务。它不授予导航、TLS、请求或 IPC 权限，也不是不可信代码 sandbox。

替换期间包括逻辑取消后尚未退休的原生 Add 都阻断新导航；Remove 结果不确定时封锁页面，只有显式 recover 可以恢复。关闭先撤去 Zig 回调，迟到操作只持独立 C 状态；最后原生引用释放后才归还预算。Windows Debug/ReleaseSafe 四模式真实验证覆盖顺序、拥有/reload、frame/opaque/CSP、取消、恢复、关闭、Stop、错误证书和服务端精确请求计数。Linux 目前明确 `UnsupportedCapability`，普通空表页面的两优化窄回归已通过。完整限制、预算和复验命令见[文档初始化器](document-initializers.md)。

## 异步 JavaScript

`evaluateJS(script, .{ .timeout_ms = 1000 }, completion)` 在当前有效、已经完成加载的顶层页面执行脚本，返回 `Evaluation`（稳定 View 地址及单调 token）。`completion` 显式提供 context 和完成函数；成功提交接管一次完成责任，失败返回 `Full`、输入/分配/原生错误且不调用新 context。View 与 context 保持稳定到终结回调，handle 的使用期不能超过 View。

这是宿主主动执行能力，可用于已经允许导航但未授予 IPC 的远程页；不会反向授予页面宿主调用权限。宿主负责选择脚本和目标页面，不应把机密数据注入未信任来源。

`Options.scripts` 默认最多 16 个 pending 请求、脚本和返回 JSON 各 64 KiB；可分别降低容量，字节上限最多 1 MiB，容量最多 16。转换前检查 UTF-16/UTF-8 大小，JSON 文本只在完成回调内借用，保留结果需应用复制。`ScriptResult` 区分 JSON、原生 HRESULT、取消、超时、页面更换、detach、不可用、timer 失败、超限、非法编码和分配失败。它保留 Runtime 的 JSON 语义：`undefined`、不可序列化值或脚本异常可能得到 JSON `null`；并不把所有 JS 异常变成 HRESULT，也不自动 await Promise。需要业务错误或异步 Promise 的页面应显式包装结果或使用 IPC。

完成回调在主线程窗口 pin 内运行，先移除逻辑槽、在真实原生 completion 点释放 pending 容量，允许 `max_pending = 1` 的回调内继续提交；独立 COM handler 保留 State 到最终 Release，重复 Invoke 不重复交付。`Evaluation.cancel()` 返回是否成功取消，并同步终结一次；已完成返回 false，detach 后返回 `Closed`。取消/超时是逻辑终结，不抢占正在运行的系统 JavaScript；尚未到原生 completion 的已取消请求仍占原生容量，不能借助反复取消无限堆积 handler。

timeout 可省略，设定时范围 1 ms 到 10 分钟。每 View 惰性创建一个 waitable timer，通过有界 `App.watchNative` 等待最近截止时间；没有轮询、刷新 timer、隐藏线程或嵌套消息泵。提交前先准备 timer/watch，失败不接管新 context，并恢复已有请求的等待；已接受请求无法重新 arm 时终结 pending 为 `timer_failed` 并关闭求值入口，直到显式重建 controller。无 deadline 时撤销 watch，detach 关闭 timer 句柄。

新文档 Starting、失败/来源失效、成功入队 reload 会终结旧页请求为 `page_changed`；process failure 为 `unavailable`；detach 为 `detached`。批量终结先快照旧 token，回调新建的请求不被旧批次误取消。业务完成回调可能 close/reload，因此之后再次检查窗口/代数，失效时不继续发送旧页面事件或旧成功结果。旧 controller 的迟到 handler 只访问独立关闭状态，不访问 detach 后的 View。

## 缩放、User-Agent 与工具窗口

`Options.zoom` 默认 1，`setZoom`/`zoom` 操作 Runtime 的页面缩放，接受有限数值 0.25 到 5。`Options.user_agent` 可选；`setUserAgent` 接收最多 4096 UTF-8 字节、无 NUL/ASCII 控制字符的值，空值重置系统默认。`userAgent(allocator)` 返回调用者拥有的 UTF-8，必须用同一 allocator 释放。UA 用于后续请求/文档，已发出的网络请求不会被改写。

`Options.devtools_enabled` 默认 false；`setDevToolsEnabled`/`devToolsEnabled` 显式修改/读取开关，`openDevTools` 仅在启用时打开原生工具窗口，否则返回 `DevToolsDisabled`。不会自动打开工具窗口。三个 setter 成功后保留 override，`recover` 复用它们；事务 `reload(options)` 应用新 Options 并清除旧 override，detach 释放复制的 UA。属性操作在主线程、受窗口 pin 保护，未 ready/正在重建时返回 `NotReady`，失败不修改已保存配置。

Linux 同样接受 `devtools_enabled` 和三个 DevTools 方法，对应 WebKit 的 developer extras 设置。`openDevTools` 只在启用时显示引擎拥有的独立 inspector 顶层窗口；它拒绝停靠进 Content host，不改变 GtkOverlay/区域/PageSession 的 widget 层级。重复打开不新增窗口。`setDevToolsEnabled(false)`、detach、reload/recover 替换原生页面和关闭均同步关闭已显示的 inspector；`devToolsResourceCount()` 统计尚未关闭的已显示 inspector，Windows 工具窗属于 Runtime，固定返回 0。网页上下文菜单仍被拒绝，因此启用开关不会额外打开“检查元素”入口。inspector 运行在同一主线程和引擎进程中，没有新增框架 worker、轮询或嵌套循环；`smoke-webview-linux` 与 `P01_PROBE=backend` 覆盖默认关闭、关闭时拒绝打开、显示/重复显示、禁用关闭、recover 保留 override、reload 清除 override 和最终计数归零，不建立人眼工具窗展示结论。

## 页面声音

`isAudible()` 报告页面是否正在发声：任一 frame（含其他站点的 frame）里播放的音视频元素或 Web Audio。它像浏览器标签页的喇叭图标，静音时也可能仍为 true；暂停或无声的来源何时不再算发声由引擎决定。设置了 `page_listener` 时，`PageEvent.audible_changed`（带当前 `PageId` 与新值）通知变化；它属于 View 而不是某个文档，也可能在两次导航之间出现。引擎未就绪时 `isAudible()` 返回 false。

`setAudioMuted(true)` 像浏览器静音标签页一样静音整个页面（媒体元素、Web Audio 和其他站点的 frame），页面看不到自己的元素被静音；`setAudioMuted(false)` 恢复。静音跨导航保持，`recover` 保留，`reload(options)` 应用新 Options 并清除它；`Options.audio_muted` 让页面从第一次加载起就静音。attach 之后、引擎就绪之前也可以设置，就绪时生效。`audioMuted()` 返回当前状态，就绪前返回所设的值。

- Linux：`webkit_web_view_is_playing_audio`、`notify::is-playing-audio` 与 `webkit_web_view_set_is_muted`。
- Windows：`ICoreWebView2_8` 的 `IsDocumentPlayingAudio`、`IsDocumentPlayingAudioChanged` 与 `IsMuted`。没有 `ICoreWebView2_8` 的旧 Runtime 不能静音，也不报告发声（始终 false）。WebView2 在一次 `IsMuted` 写入的 `IsMutedChanged` 到来前收到另一次写入时，可能丢失或乱序应用，所以适配器同一时间只让一次写入在途：其余只记录目标状态，`IsMutedChanged` 到来后若与目标不同再写；没有变化的写入不会有事件，最多压住下一次写入 1 秒。

## 内容拦截规则

内容拦截规则阻止页面加载某些资源并隐藏页面的某些部分，就像广告或跟踪器拦截器。规则使用 WebKit 内容拦截器的 JSON 格式：一个规则数组，每条规则有 trigger 和 action，按顺序应用。

```json
[{"trigger": {"url-filter": "^https?://ads\\.example\\.com/"}, "action": {"type": "block"}},
 {"trigger": {"url-filter": ".*", "if-domain": ["*example.com"]},
  "action": {"type": "css-display-none", "selector": ".banner"}}]
```

trigger 用 `url-filter`（URL 的正则表达式，除非 `url-filter-is-case-sensitive` 否则不区分大小写）匹配一次加载，并可用以下之一缩小范围：`if-domain`/`unless-domain`（页面的域名，小写 punycode，前面的 `*` 包含子域名）或 `if-top-url`/`unless-top-url`（页面 URL 的正则表达式）；另外可用 `resource-type`（`document`、`image`、`style-sheet`、`script`、`font`、`raw`（fetch、XMLHttpRequest、WebSocket）、`svg-document`、`media`、`popup`、`ping`、`fetch`、`websocket`、`other`）与 `load-type`（`first-party` 或 `third-party`，加载是否来自页面自己的站点，按公共后缀表的可注册域名判断）。action 是 `block`（不加载）、`block-cookies`（不带 Cookie 加载）、`make-https`（http 改用 https）、`css-display-none`（在 trigger 匹配的页面里隐藏 selector 选中的元素）或 `ignore-previous-rules`（撤销本列表之前规则对这次加载的作用）。正则表达式是 WebKit 的子集：ASCII，没有 `|`、`{n}` 计数重复和 `\d` 之类的字符类，`^` 只能在开头。引擎无法解析 selector 的规则被跳过；其他错误（以及空列表）使整个列表失败。

`ContentRules.compile(allocator, app, id, rules, .{ .store_directory = dir }, completion)` 在主线程编译规则，completion 稍后在主线程收到 `Result`：`.compiled`（调用者持有一个引用，不再需要时 `release()`）、`.invalid`（`content_rules.Failure`，带原因与规则序号）、`.failed`、`.out_of_memory` 或 App 先停止时的 `.closed`。`Compilation.cancel()` 撤回 completion。id 由 1 到 64 个字母、数字、`-`、`_`、`.` 组成。

- Linux（WebKitGTK）用引擎的内容过滤器在主线程之外编译。`store_directory` 必须是绝对路径（不存在时创建），引擎把编译结果按 id 加规则哈希保存在里面：之后以同样的规则启动直接加载已编译的列表，同一 id 编译了别的规则则删除旧列表。WebKit 限制每个列表的规则数（15 万条，旧版本 5 万条），更长的列表请拆分后一起应用。规则错误时引擎只报告整个列表，`Failure.reason` 为 `rejected_by_engine`、没有规则序号。
- Windows（WebView2）没有内容拦截器：`compile` 在调用线程解析规则（EasyList 那样长的列表约需零点几秒），经 `App.post` 交付结果。应用规则的页面所见的每个请求都在宿主里匹配；被拦截的子资源得到指向 `data:,` 的 307 重定向，fetch 和 XMLHttpRequest 因此像网络错误一样失败，页面本身得到空的 403。`css-display-none` 通过每个文档（含 frame）都采用的一张样式表隐藏元素，页面重设 `adoptedStyleSheets` 后仍保留；它是页面自己的样式表，所以元素带 `!important` 的内联样式会胜过它。WebView2 不暴露 WebSocket 请求，WebSocket 不会被拦截。规则不存储，`store_directory` 被忽略。

`Options.content_rules` 让页面从第一次加载起应用规则，配置持有自己的引用。`View.setContentRules(rules)` 替换页面应用的规则（空切片移除全部）；此后的加载经过新规则，已加载的页面保留已加载与已隐藏的内容，直到重新加载。setContentRules 的规则跨 `recover` 保留，`reload(options)` 应用新 Options 时清除，detach 释放引用。一个 `ContentRules` 可同时供多个页面使用。

规则的解析、正则子集、公共后缀与隐藏脚本在 `content_rules.zig` 中实现，可在任意线程纯计算，`zig build test-content-rules` 不依赖引擎验证；公共后缀表由 `scripts/update-public-suffix.py` 从公共后缀表重新生成。`smoke-webview-content-rules`（Linux 与 Windows）编译、重复加载已编译列表、拒绝 `a|b` 与空列表，验证页面从首次加载起阻止脚本、隐藏元素，移除规则重新加载后恢复，并验证页面从一开始就静音、取消静音后保持。是否真正听到声音需要音频设备，自动检查只验证状态与无声页面不发声。

## Cookie、Profile 与页面工具

`Options.tools` 的 `cookies`、`clear_entire_profile`、`find`、`capture`、`pdf` 全部默认 false，逐项显式开启。相应原生能力或所需 Runtime 接口不可用时返回 `UnsupportedCapability`。这些是宿主能力，不赋予页面 IPC 或额外导航/网络权限。

异步方法统一接收 `tools.RequestOptions` 和 `tools.Completion`，返回 `ToolOperation`。成功后恰好一次主线程终结回调，失败不接管新 context；所有返回字符串、Cookie 数组、PNG bytes 和 `pdf_path` 只在回调内借用。句柄使用期不能超过稳定地址的 View。`Options.tool_limits` 默认最多 8 个请求，不能超过 8；Cookie 默认最多 128 项、64 KiB 结果预算，最高 128 项、256 KiB；PNG 默认 4 MiB，最高 16 MiB。Cookie 预算分别约束原生字符串复制和 Zig 描述/UTF-8 数据，Runtime 自身的 Cookie 存储、枚举和页面内存不属于该预算。

`getCookies(uri, options, completion)` 只接受配置本地站点 origin 或具备导航许可的精确远程 origin，不枚举未知 host 或整个 Cookie 库。`setCookie(uri, tools.CookieWrite)` 从已授权 URI 派生 native domain，显式提供 name/value/path、Secure、HttpOnly、SameSite 和可选 Unix 秒过期时间；未提供过期时间为 session。`deleteCookie(uri, tools.CookieDelete)` 按 name、该 host 的精确 native domain 和显式 path（默认 `/`）删除，不匹配父域或其他 path。名称最多 256 字节，值/path 最多 4096 字节，当前接收受限 ASCII；SameSite=None 必须 Secure。

写入和删除必须填写 `accept_cookie_scope = true`。精确 origin 是调用授权边界，Cookie 实际遵循 [Runtime 的 domain/path 匹配语义](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2cookiemanager)，没有端口隔离，也不承诺 `CreateCookie` 创建 host-only Cookie。父域、同 host 的其他端口和共用 Profile 的页面可能受影响；返回的 domain 不可当成 host-only 标志。两种 mutation 返回成功只表示原生接受，未提供完成回调，不承诺紧接着的读取已反映更改。应用需自行协调观察结果，框架不插入等待、重试或轮询。

`clearBrowsingData(.entire_profile, options, completion)` 还要求 `tools.clear_entire_profile = true`，调用 [ClearBrowsingDataAll](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2profile4)。这是所选 Profile 的整体清理，可能影响其他共用该 Profile 的 View；不是按 origin 清理。框架不额外弹确认框。Cookie 枚举和清理属于 Profile 作用域，普通页面导航不会取消它们；reload/recover、进程失败和 detach 仍会终结回调。

`startFind(page_id, tools.FindOptions, options, completion)` 开始原生查找；term 最多 4096 UTF-8 字节。Windows 支持大小写、整词和全部高亮选项，强制抑制默认查找对话框；Linux 的逐选项范围见上文及 `findCapabilities()`。完成返回 `FindState{matches:?i32, active_index:?i32}`：`null` 明确表示未知；已知 active_index 使用 Runtime 的 1 起始索引，`-1` 仍表示已知尚无活动项，不能代替未知。Windows 原生数值仍作为 known 值交付。`findState` 读取当前缓存状态，`findNext`/`findPrevious` 跳转，`stopFind` 终结逻辑场次。

可选 listener 观察匹配数/索引变化，上下文保持到 stop、替换、页面更换或 detach。每 View 仅一场逻辑查找；替换只有在新候选完整拥有、Book/deadline 预留和当前页面检查成功后才撤销旧场次。旧完成回调若重入建立新查找，外层替换返回 `FindReentered`，不覆盖新场次。逻辑取消后迟到原生完成不通知旧 listener；Linux 物理槽的保留规则见上文。

旧调用者须从直接整数比较或格式化迁移到显式处理 optional；不要用 `orelse 0` 将未知总数变成“没有匹配”。例如 `if (state.matches) |count| { /* 已知总数 */ } else { /* 未知 */ }`；活动索引也须先检查 optional，再区分已知 `-1` 与 1 起始的索引。

`capturePreview(page_id, options, completion)` 用原生 PNG 编码写入固定预算的内存 `IStream`，不读写文件、不在 UI 解码图片。超预算整体返回 `limit_exceeded`，不交付部分 PNG。结果为 `Result.png` 的借用 bytes；需要保存时由宿主复制并交给显式 worker。它不会限制 Runtime 编码过程自身的临时内存或耗时。

`printToPdf(page_id, tools.PdfOptions, options, completion)` 使用 Runtime 的异步 PDF 文件输出，不调用系统打印机或打印对话框。宿主必须在自己的显式 worker 准备可信的私有绝对路径，调用时填写 `accept_overwrite = true`；UI 入口不 stat/read 文件，也不判定路径是否安全、是否已有内容。输出可覆盖该路径。路径最多 32766 UTF-16 单元，复制到本次请求。

排版选项与浏览器打印对话框一致，页面的 print 样式表生效：

- `page_size` 以英寸计，默认 `PageSize.letter`（8.5×11），另有 `legal`、`tabloid`、`a3`、`a4`、`a5` 预设或任意 1–100 英寸的自定义尺寸；`landscape` 横向。
- `margins` 四边默认 0.4 英寸，`Margins.none` 为零；每边 0–10 英寸，且左右、上下之和须小于纸张尺寸，否则返回 `InvalidMargins`。
- `first_page` 从 1 起，`last_page = null`（默认）打印到最后一页；给定 `last_page` 时连续范围最多 256 页，否则返回 `InvalidPageRange`。
- `print_backgrounds` 默认 false，与打印对话框一样不打印背景色和背景图。
- 不打印页眉页脚。

Windows 使用 Runtime 的 PrintToPdf。Linux 通过 WebKitGTK 打印操作交给 GTK 的“打印到文件”后端写 PDF，同样不显示对话框；它与截图、清理共用物理 pending 配额，同一 View 同时只运行一个 PDF（运行期间临时替换该 View 的打印背景设置），文件写完后先释放物理槽再回调，回调内可以立即提交下一次。Linux 的取消同样只终结回调，已开始的打印继续写完目标。成功返回 `Result.pdf_path`（借用输出路径），不是 PDF bytes。输出大小、磁盘空间、复杂页面排版与 Runtime 耗时没有硬预算；应用负责路径权限、并发写入及在 worker 检查产物。

工具、JS、deferred resource、权限与待决下载共用一个惰性创建的 waitable timer，timeout 同为 1 ms 到 10 分钟。取消/超时只终结宿主回调，不撤回已写 Cookie、已执行的 Profile 清理、已提交截图编码或 PDF 写入；PDF 可能在逻辑终结后继续写目标。未完成的原生操作继续占有界 native pending 槽，直到真实 completion；Windows 真实完成先释放容量，允许回调内再次提交，Linux Find/capture/clear/PDF 的物理引用时点见上文。PNG sink 和独立 COM 状态保留到原生 Release。页面作用域的查找/截图/PDF 在新页面、失效或重建时收到 `page_changed`，detach 为 `detached`，进程失败为 `unavailable`。批量清理先同时取出五类旧请求，再取消原生操作并运行任何业务回调，正常关闭不重新挂载计时器；重新 arm 失败则终结剩余请求并关闭提交入口，避免悬挂。已接受传输的下载没有持续 timer，进度由原生事件驱动。

真实 native C→Zig 回调以独立 App native callback scope 遮蔽被暂停的原始输入 receipt，结束后恢复外层输入上下文；普通 Region/Session 回调转发保持原权限。scope 先结束 attachment pin，再结束保存的 App pin，之后不读取可能已释放的 View/Session。CookieStore 的晚到完成/停止 teardown 也进入该边界。这不宣称 SDK 在 C ABI 返回后的任意 C-only 尾部都被包住；后续新 C→Zig 入口会独立建立边界。

App 已进入 stopping/stopped、原生窗口尚未销毁时，同样停止接受 View 提交/属性操作及逻辑取消并返回 `Closed`，保留未消费拥有结果。该阶段迟到的 native completion、页面事件、timeout 和进程通知不重挂 timer 或改写终结原因，逻辑槽由 detach 统一完成为 `detached`；恢复通知仍保留当前与 pending 配置到 detach。独立 StreamTicket 的取消/释放不依赖 View，可继续使用。

## 异步权限与下载

`Options.permissions` 默认 null：原生拒绝，不显示默认许可 UI。权限和下载均禁用时不创建新增 action budget。显式策略包含最多 8 个精确 canonical origin、每项明确的 `permissions.Kinds`、handler 与最多 8 个 pending 槽；默认还要求原生 `IsUserInitiated`。许可 URI 与当前已 committed 顶层文档必须同时匹配该 origin，未知种类和不支持的 Args3/deferral 接口不会扩大权限。iframe 不能以另一 origin 借用顶层许可。

`PermissionOffer` 的 origin 和 responder 只在 handler 内借用。`deny()` 保留默认拒绝；`deferDecision(.{ .completion = ... })` 成功后返回 `PermissionId`，宿主可在显式 worker 处理业务，再 `App.post` 调用 `view.decidePermission(id, .allow_ephemeral/.deny_ephemeral)`。失败不接管 completion context；成功后该 context 保持到恰好一次终结回调。`decided` 表示原生接受决定且 Complete 成功，不保证操作系统、设备或站点 API 最终成功。导航/来源失效终结为 `page_changed`，timeout/cancel 拒绝该原生请求；重建为 `page_changed` 或 `unavailable`，关闭为 `detached`。旧 PageId/token 不可再次决定。

原生显式设置 [SavesInProfile=false](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2permissionrequestedeventargs3)，不写入持久许可。公开名称使用 ephemeral，不承诺每次站点调用都再问宿主，也不把此选项解释为清空 Runtime 的会话状态。当前未提供持久许可管理或 OS 许可对话框包装。

`Options.downloads` 也默认 null：Cancel=true、Handled=true，不显示下载 UI、不自动选择路径。开启时明确 `lifetime = .view`、最多 8 个 HTTP(S) 精确目标 origin、handler 和 `downloads.Limits`。这只控制 Runtime 已提供的 DownloadStarting，不额外授权导航、HTTP method/header 或请求。现有 DOCUMENT 门禁继续适用：跳过 NavigationStarting 的 `download` 属性请求可能得到默认 403；宿主可显式 `navigateRemote` 到受信附件 URL，普通链接仍遵循导航配置。blob/data/custom 下载不属于本片授权范围。

`DownloadOffer` 借用受限 URI、MIME、建议 basename、可选总长度，以及仅供审计的 `observed_page`。建议名称是未信任元数据，不能直接决定目标路径。`deny()` 不接管上下文；`deferDecision(options)` 成功返回 `DownloadId`，之后保持 completion context 到其终结回调。Options 中的 handler context 和稳定地址的 View 保持到 detach，ID 的使用也不能超过 View 生存期。普通导航和附件导致的导航失败不取消 View 作用域下载；reload/recover/进程失败终结为 `unavailable`，detach 为 `detached`。默认最多 4 个待决或活动下载，默认拒绝未知长度，已知长度上限 64 MiB；接收事件超过默认 64 MiB 阈值则取消为 `limit_exceeded`，这是观察后的软限制，不能限制 Runtime 预取或构成硬磁盘/网络配额。

宿主在自己的 worker 调用 `DownloadDestination.prepare(allocator, process_main_thread_id, absolute_path, .{})`，在主线程执行会直接返回 `UiThreadForbidden`。它检查已存在的父目录、目标及受限 Windows 名称，默认拒绝已有输出，并拥有 UTF-8/UTF-16 路径；这是准备时预检，不锁住路径。显式 `accept_overwrite=true` 可接受已有普通文件。[Runtime 按路径打开、可覆盖现有文件并创建目录](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2downloadstartingeventargs)，因此宿主必须提供可信私有目录并协调 TOCTOU/reparse 竞争，默认 false 不等于原子 no-replace。

`view.resolveDownload(id, &destination, listener)` 不执行文件系统检查；成功消耗 destination，失败仍由调用者拥有。若原生提交已失败，该已接受 offer 会以 `native_failure`（或关闭时 `detached`）终结。完成前原生通知保持静默，成功移动路径后才激活，防止 Complete 的同步重入读到半提交上下文。`DownloadId.snapshot()`、`pause()`、`resumeTransfer()`、`cancel()` 都在主线程使用；pause/resume 返回原生接受，不是状态变化的同步屏障，listener/snapshot 观察实际状态。暂停由原生 USER_PAUSED 状态表示，其他原生中断明确取消后终结，避免隐式自动恢复。进度 listener 仅借用数值快照；`completed.path` 仅在终结回调内借用。回调可关闭/重建，窗口 pin 和先摘槽保证旧请求不触碰新业务。

Destination 是不可复制的拥有结果，失败 post 后可在 worker `deinit`，不含 COM、不删除输出。取消不保证立即停止 Runtime I/O，也不删除部分文件；完成只表示原生传输完成，不证明文件内容安全。准备与最终内容验证由宿主管理，框架不扫描、解码、执行或打开下载文件。

像浏览器那样把下载存进“下载”目录时，可组合两个辅助函数：`downloads.safeName(buffer, offer.suggested_name)` 取建议名的最后一个路径分量（`/` 和 `\` 都算分隔符），为空时用 `download`；Windows 上把文件名不能含的字符换成 `_`、去掉结尾的点和空格、给设备名加前缀 `_`，截断不拆开 UTF-8 序列。worker 上的 `downloads.uniquePath(allocator, main_thread_id, directory, name)` 在目录中已有同名文件时依次编号为 `name (2).ext`、`name (3).ext`……，返回调用者拥有的绝对路径。目录可用 `ziggurat_system` 的 `identity.directory(.downloads, &buffer)` 取得。之后照常 `Destination.prepare`，不要开 `accept_overwrite`，这样期间被其他进程占用的名字会被拒绝而不是覆盖。

权限与下载的物理预算独立于逻辑槽：每附着 View 的 budget 跨 recover 保留，降低配置上限不能绕过旧对象；全进程分别最多 32 个权限 deferral 与 16 个物理下载对象。下载直到最后一次原生 event-handler Release 才返还物理槽，取消和移除事件本身不提前返还。迟到 handler 只持有原生 State/budget，不读取已 detach 的 Zig context。`actionResourceCounts()` 供诊断，不计系统 Runtime 内部资源。禁用功能不分配其 deferral 或下载 progress/state 事件对象；原有默认拒绝入口继续保留。

## 宿主持久策略

`policy_store.Store` 是应用拥有的可选纯策略对象，不会自动处理 permission/download offer，也不读写 Runtime 的持久许可。`Store.init(allocator, main_thread, scope, limits)` 在指定主线程创建稳定地址对象；mutation、lookup、snapshot 同样限主线程。worker `load`/`decode` 返回独占候选，成功 `App.post` 后在主线程 `adopt()` 才能使用，post 失败则 worker `close()`。不得让 worker 并发修改 live Store。

`Scope` 包含宿主明确选择的 128-bit namespace 和 policy_epoch，不从 Profile 路径猜身份。key 是精确 canonical HTTP(S) origin 加 permission kind 或 download；本片不持久化 custom origin。规则保存 ask/deny/allow、issued_at/expires_at，下载还可保存更窄的 known/received/unknown 限制与不透明 folder_key。folder_key 由宿主在 worker 解析为自己的目录，每次下载仍须 `DownloadDestination.prepare`；它不是绝对路径或目录授权。`DownloadConstraints.intersect(capability)` 只生成收紧后的数据，不会修改现有 View 的原生额度。宿主必须在接受前应用 known/unknown 门禁，并用更窄的 received 值在 progress listener 中取消、在 completed 中核对结果，或预先将相交额度用于本次 View 配置。Runtime 若只交付末次进度/完成，限制仍只能事后观察，不能承诺精确截断。磁盘规则不能扩大 `Options` 的 origin/kind/gesture/method/header 能力。

lookup 显式传入宿主 UTC 秒，早于 issued_at 或到达 expires_at 均不匹配；默认最大 TTL 30 天，可显式配置到 10 年。时间来自宿主，不是防时钟篡改机制。`DecisionLease` 拥有 key bytes，绑定进程内 Store identity、namespace/epoch、精确 subject/key、该规则 revision 和有效期；更新、revoke、clear 或安装另一 Store 后不能复用旧授权，其他 key 的变更不会误撤销本条租约。lease 仅在内存中交接，不是可持久化或跨进程的凭据。宿主必须在 UI 调用 native decide/resolve 前检查自己的 cancellation、重新获取当前时间并调用 `validateLease`；没有调用该方法就不能声称异步决策具备自动撤销保障。规则 revision 耗尽明确拒绝，不回绕。

默认 256 条、当前 Store 128 KiB、编码文件 128 KiB，上限分别 1024 条和 1 MiB；没有全局业务表。key 保持排序，lookup 使用 O(log N) 次有界字符串比较；put/revoke 先构建完整候选，再一次发布，成本为 O(N + origin bytes)，不得放进 paint。`owned_bytes` 限单一 Store generation，事务可同时拥有旧、新两份；`stats().mutation_peak_bytes` 记录该 Store 的实际代际峰值。snapshot 是调用者明确付费的编码副本，独立于 Store 生存期，worker 加载还同时持有有界输入与候选，路径预检有独立的有界 UTF-8/UTF-16 元数据。

`Store.snapshot(allocator)` 返回不可复制的拥有型 `Snapshot`；`snapshot.save(main_thread, absolute_path, options)` 和 `policy_store.load(allocator, main_thread, scope, path, limits, cancellation)` 可执行地拒绝主线程，不创建隐藏 worker。文件使用严格版本、scope、数量、长度、已知 kind/flag、canonical/sorted/unique key 和 CRC 检查；CRC 只检测损坏，不提供认证，宿主须保护私有目录和文件。输入失败或 OOM 不发布半个候选，不修改 live Store。

保存使用同目录 exclusive 随机临时文件、完整有界分块写入、flush 和一次 rename；在分块、flush 前后和 rename 前检查取消，观察到提交前失败/取消时保留旧文件并清理临时文件。`SaveOptions.failure` 可保留原始错误及清理失败的临时名称，不能默默丢失清理诊断。rename 是提交点，之后取消不撤回；语义依赖所选文件系统，不承诺断电后的目录持久性。宿主序列化 writer 并提供可信私有路径；没有自动保存、热加载、多进程 CAS 或通用文件系统沙箱。

revoke 立即使新的宿主 lookup 与旧 lease 失效，但不会撤回已经允许的 OS/设备操作，也不保证清除 Runtime 的内存许可缓存。Store 不自动追踪已启动传输，宿主若要停止它们须显式取消持有的 DownloadId。持久规则仍通过既有 ephemeral 决策提交，不持久化 browser ALLOW；需要共享 Profile 原生许可管理时须另行明确影响范围，不能把删掉磁盘规则当成系统权限已撤销。

## 成本与验证

不启动 worker、定时轮询或嵌套消息循环。导航使用有界路径转换和一个待开始 URL；原生 handler 独立持有关闭状态，移除事件注册、关闭 controller 后迟到 COM 引用不访问已 detach 的 View。

`zig build smoke-page -Dwebview=true` 在真实 Runtime 验证本地导航、历史/刷新、加载事件、旧代数拒绝、元数据 OOM 和回调关闭。`smoke-page-remote` 使用自建 loopback 服务、不同随机端口、私有 Unicode 文件与独立 profile，验证请求/POST/frame 拒绝、脚本/重定向权限、默认 IPC 拒绝、显式 IPC 往返、配置重载代数及文件快照；关闭后适配器 COM 计数归零。`smoke-page-authorization` 无 Runtime，直接经生产 callback ABI 验 URI 边界、规范 origin、一次性授权种类与拒绝路径；快照另有有界/取消/分配失败单测。测试不触及公网或用户文档，不下载 Runtime，不证明视觉质量、公网 TLS/真实代理认证/客户端证书交互，亦不证明完整网络隔离。

`smoke-script` 在真实 Runtime 验证单槽连续 completion、Unicode JSON、结果/OOM 上限、原生 timer 逻辑超时、取消、重载/重入/关闭与 pending 容量；读写 zoom/UA/DevTools 属性，并终止本测试 controller 的 browser process 验显式 recover 后属性保留。自动测试只验证 DevTools 开关与禁用拒绝，未打开工具窗口验证其展示。测试后 allocator、窗口记录与 adapter COM 计数归零。

`smoke-browser-tools` 只使用自建 loopback 服务、每次运行随机私有 Profile 和 worker 准备的私有 Unicode PDF 路径，实际验证默认拒绝、Cookie 跨端口作用域/HttpOnly/删除、Profile Cookie/localStorage 清理、隐藏原生查找和前后跳转、PNG 上限/签名/尺寸、PDF 签名/页结构、取消/原生容量及同时带 JS/tool deadline 的 App.quit。Cookie 设置与删除由测试自己的 one-shot timer 在明确 deadline 内继续异步观察，仍要求目标 value/domain/path/flags 正确并最终消失；一次 JS 往返不能充当原生 mutation 完成屏障，框架没有增加轮询。App 析构后 worker 有界等待本次已取得 handle 的 browser process 退出再清理私有目录，不能确认时保留并报错。PDF 仅由测试 worker 读取，未打开图片、PDF、工具窗或系统打印机。纯单测覆盖多请求簿退出原因、timer 失败回调关闭及页面清理重入；原生 ABI fixture 覆盖有界 stream 和 COM 请求的失败/取消/重复/迟到完成，资源计数不包含系统 Runtime。

`smoke-request-policy` 用两个私有随机端口服务实际接收 POST body、OPTIONS、Authorization，验证精确方法/名称/值授权以及未知非 X 头、Range、PUT 和另一端口写请求未到达服务。`smoke-resource-async` 实际验证初始 loading 文档 defer、显式 worker 拥有响应、HEAD 长度/空 body、204、取消、timeout、Full、不接管失败 context、导航后旧 ID 保留结果所有权，以及 detach 后 worker post Closed 的释放。原生 ABI fixture 验证准备失败、响应 OOM、8 槽容量、预挂拒绝响应、Complete/Release 恰好一次和 HEAD/204/304/framing；纯单测覆盖三请求簿 quit/超时/rearm 失败重入、响应硬预算及规则复制/OOM。

`smoke-resource-file` 使用每轮随机私有 Profile/文件，真实验证默认拒绝且无动态流对象、主线程禁止/文件上限/OOM/原生错误码、宿主 cursor 保留、HEAD 长度、同步与 worker post 延迟提交的完整 4 MiB 内容，以及 completion 内关闭后在 App 析构后的 worker clone/cancel/释放 ticket。原生 ABI 另验 32/8 物理容量、降额、EOF/cancel 不返还槽、失败保留预挂 403、Complete 失败、关闭/导航重入、有界控制入口 sweep，以及真实 OVERLAPPED pending 取消后的 completion drain。隔离实验观测到 Runtime 在非 UI 线程调用 Read，并验证 Read 挂起期间 UI 可关闭、迟到 MTA 最后释放；观察到的 32 KiB 请求大小是本机 Runtime 行为，不是公开保证。测试检查协议、内容和生命周期，不证明视觉质量或应用级背压。

`smoke-scheme` 用每次运行的随机私有 profile，实际验证 URL 保留 custom scheme、secure context、静态资源/worker 延迟响应、POST/头授权、其他 host/其他 scheme 拒绝、端口/userinfo 被 Runtime 规范化的事实、默认/显式双向 IPC、Cookie 拒绝、不兼容 reload/同 profile 环境错误，以及显式崩溃恢复后配置保留。测试 worker 等本次拥有 handle 的 browser 退出后清理目录；关闭后窗口记录及 adapter COM 计数归零。`smoke-page-authorization` 另测可见非法 authority、COM identity、独立返回字符串/数组、迟到 registration Release 和不可变 setter；纯单测覆盖 metadata 规范化/复制/上限/OOM 及 reload 事务。上述验证针对 Windows Runtime；Linux 静态 custom 站点的范围和独立验收见前文，动态响应与完整网络沙箱仍需各自实现和验证。

`smoke-permission` 仅调用自有页面的 Notification.requestPermission，不创建通知或读取设备/剪贴板，真实验证默认无 budget、显式 ephemeral allow/deny、重复请求的实际行为、gesture gate、timeout、旧页拒绝及 JS/tool/resource/permission 四簿退出的精确 detached 原因。`smoke-download` 仅向私有 loopback 服务请求附件，在 worker 准备的随机私有目录验证 256 KiB 完整字节、默认拒绝、跨导航待决请求、timeout/cancel/软限额、pause/resume 与退出；不打开下载文件或用户文档。ABI fixture 覆盖权限准备/Complete 失败、导航重入及下载准备/提交失败、同步通知静默、迟到 handler、跨 State 共享物理容量、重入取消、快照失败与最终资源回零；纯单测覆盖五簿统一关闭及 metadata 分配失败。上述证据仅对应 Windows，本片不宣称持久许可或其他平台下载已实现。

`smoke-browser-policy` 在真实 Windows Runtime 执行六次 worker 保存/加载/post/adopt：持久 allow 记录驱动 Notification 与私有 loopback 下载，取得 lease 后撤销的 permission/download 均在原生决定前拒绝，最后再加载确认两条撤销已落盘。另保持 View 原生 64 KiB 上限而将 Store received 设为 1，由真实 progress 触发宿主取消，不把数据 helper 冒称原生配置已修改。worker 核对 64 KiB 完整产物及撤销目标不存在，COM/窗口记录归零。独立 Store 测试在 Windows/Linux 实际执行 worker 文件读写、版本/损坏/非 canonical/重复拒绝、TTL/租约身份与 revision、1024 条有序查找、主线程 I/O 拒绝和全部分配失败回滚；Windows 另以真实禁止 delete-share 的文件句柄迫使 rename 失败，确认旧文件保留和临时文件清理。Linux 的证据仅为独立 Store 文件能力，不代表 Linux WebView 下载或原生权限支持。

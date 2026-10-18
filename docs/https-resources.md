# 显式 HTTPS 资源消费

`ziggurat_https_resources` 是可选的 HTTP/1.1 资源模块，不依赖 WebView，也不创建 App、Window 或线程。Linux 宿主可提供自己的单一 `https://127.0.0.1:port` TLS SoupServer，再显式创建 Endpoint；Linux/Windows 也可用独立的 [Transport owner](https-owned-transport.md) 明确拥有回环监听器，再调用 `Site.createOnTransport`。Windows 使用 worker prepare/main adopt/原 worker run。构建开关为 `-Dhttps-resources=true`，默认关闭；未开启或平台不支持的入口在读取 App、server、输入或调用 allocator 前返回 `UnsupportedCapability`。Windows 真实 App/browser 组合使用隔离固定证书测试例外通过，产品仍须正常系统证书验证；Profile 级生产显式 pin 未完成。

Linux 原生最低 libsoup 3.2，编译期检查 pause/unpause API 所需版本；本机实际运行依赖为 libsoup 3.4.4。Windows 的固定可选 TLS source、预算、协议范围及线程交接见 Transport 合同。依赖由宿主显式准备，Endpoint 不安装依赖或启动 worker。

模块提供独立资源运输，不开放 Linux `local_site`。WebView 的 header grant 仍只检查已观察到的头；Linux 的独立 `RemotePage.request_credentials` 将创建期 Bearer 限定到精确 HTTPS origin，连接首个页面请求及后续 fetch，见[凭据合同](request-credentials.md)。宿主显式组合 Transport 或自有服务器、Site/Endpoint、Profile、证书例外、请求许可和凭据，各自保持自己的所有者及生命周期。

## 服务器与权限

Linux 宿主在进程主线程的默认 GMainContext 上创建和监听 server，创建时须设置 construct-only `raw-paths=true`，并保证原生 server、TLS 配置、唯一监听器和 Endpoint 的独占 prefix 在 Endpoint 关闭前不被更改。Endpoint 使用核心已有的默认 context，不驱动另一 context 或嵌套循环；在其他 thread-default context 上构造会拒绝。构造在 caller allocator 前检查这项属性、listener 的 socket 地址及 URI，不以“server 配有证书”代替“这个 listener 正在使用 HTTPS”。Windows 的 Site 从 Transport 一次 lease 取得同一个受检 listener 身份。证书、私钥、服务可达性和退出由宿主负责；不同平台的 native/TLS/kernel 成本按各自 Transport 合同单列，没有总 RSS 的硬上界承诺。

`Options` 包含 `port`、`mount_prefix`、宿主给出的 32 字节私密随机 Bearer、`context/on_request`、可选 `on_closed` 和 `limits`。模块不生成或持久化凭据。构造先用固定值捕获 prefix/Bearer，并持有 server 的原生引用，再进入调用者 allocator。Bearer 的 wire 编码为 `Bearer ` 后接 64 个小写十六进制字符，不放入 URI、Cookie 或诊断。

构造捕获的临时 Bearer 在返回前显式清零；Endpoint 的拥有型 Bearer 在构造回滚或最后 callback pin 释放后、调用者 allocator 的最终 free 之前清零，认证比较的临时编码也在返回前清零。原生 Gate/Ticket 不复制 Bearer，封入口后不会再回访该策略。这只覆盖本模块明确拥有的字段与指定临时缓冲；宿主 Options/请求头、编译器生成的值副本、TLS/SDK 内部存储和进程内存取证不属于此保证。

每个请求必须同时满足以下条件：

- 实际本地地址是该 Endpoint 的 `127.0.0.1:port`，对端也是 `127.0.0.1`。
- HTTPS URI 的 host 和 port 精确匹配，没有 userinfo/fragment；Host 头采用相同的 canonical authority，443 省略端口。
- GET 或 HEAD，没有非零 Content-Length、Transfer-Encoding 或 Expect。
- 恰好一个正确 Bearer。没有 Origin 不能替代认证；有 Origin 时必须精确等于 Endpoint origin。
- SDK canonical URI 总量最多 4KiB，计算包含 `https://`、authority、path 和可选 `?query`。最多 64 个解析后头、16KiB 头内容，每个名称/值还遵循共享 HTTP metadata 的边界。原始 wire request-target、解析器、TLS 和连接的上限仍由宿主/SDK 管理。

早期 headers handler 完成门禁后，正常 handler 才转交业务。此处不承诺 SDK 完全没有接收或缓存网络字节；未授权请求不会进入 `on_request` 或启动本层 source 读取。

prefix 作用于解析后的同一 canonical GUri，要求首尾 slash。`raw-paths` 保留 reserved 字符的编码，但不提供原始 wire 字节：GLib 即使开启 encoded flags，仍会归一化 unreserved escapes，例如 `/%70rivate/body` 与 `/private/body` 是同一路径；query 的百分号十六进制也可能变成大写。模块不猜测已被 SDK 消除的原始表示。early Gate 强持 GUri，normal 阶段要求同一 identity 并再次验证 policy。

在解析后的表示中，path 保守拒绝仍可见的 dot/dotdot 段、重复 slash、encoded reserved slash/backslash 以及控制字符；query 是有界 canonical 数据，不作为 HTML 表单解码。请求 path/query 只借用到 `on_request` 返回。**这不是文件路径授权**：宿主仍须显式选择并授权自己的 source，模块没有目录映射、相对路径打开或磁盘扫描。[SDK handler 路由合同](https://libsoup.gnome.org/libsoup-3.0/callback.ServerCallback.html)与[固定 GLib URI 归一化实现](https://raw.githubusercontent.com/GNOME/glib/2.80.0/glib/guri.c)说明了这一区别。

## 响应、接受与宿主 worker

显式 `range_requests` 请求准入与 callback 内借用的 `Request.headers` 见
[HTTP 字节范围](http-byte-ranges.md)。默认仍拒绝 Range；开启不自动选择部分响应，也不授予文件或浏览器请求权限。

`on_request(context, endpoint, request, offer)` 只在进程主线程运行。`Offer` 只借用当前 callback 栈，不能保留其副本。宿主可调用 `respondOwned`、`respondBorrowed`、`respondHead`、`respondSource`、`respondPreparedFile`，或用 `deferRequest` 接管一个独立线性 Ticket。没有被处理的 Offer 以拒绝响应结束。

`respondBorrowed` 在固定栈存储中先捕获最多 16 个 header 描述符，再进入原生查询或准备；MIME、header 字节和 body 保持稳定到返回。独立 C candidate 在接受前完成自己的复制，调用者的 Response 不被消费，返回后即可释放输入。输入借用和候选保留量仍进入 Endpoint 同一预算；不为了静态响应额外构造 OwnedResponse。Ticket 仍仅在接受后消费一次，失败保留，接受后即使 Stop 取消发送也不能重试。HEAD 使用 `respondHead` 可以只提交表示长度，不借用 body。

共享 `http.OwnedResponse` 拥有 MIME、headers、完整内存 body 的单份调用者分配。Endpoint 使用同一份共享 validator，再复制为独立的 C candidate；不复制第二套 HTTP validator。HEAD 可只提供 `Head.length`，无需先分配这份表示字节。文件通过中立 `files.PreparedSource` 进入，Content-Length 使用其原生保存的 authoritative length，忽略可改写的公开长度字段。

失败发生在接受前时，OwnedResponse、PreparedSource 和 Ticket 都仍由调用者拥有。候选构造、foreign 临时清理、App/owner/slot 检查全部通过后，先纯发布一次响应责任，再撤销调用者 owning 字段。文件 source 在撤字段后先激活已接受 stream，之后才释放原 prepared 引用，避免把其未提交释放误当取消。最后开始原生发送；任何这个阶段的关闭都返回 `accepted_cancelled`，不能作为可重试失败。Receipt 表示责任接管，不是对端已收到、Producer ACK、文件内容持久化或原生任务归零证明。

Ticket 只保留独立的 C 身份、槽位代数和取消权，不保留 Zig Endpoint、App、业务 context 或调用者 allocator。它可以跨 Endpoint/App 释放。worker 上的 `cancel/deinit` 只修改原子状态和 GCancellable，主线程 source 再退役 HTTP 消息及连接。Ticket 响应方法只在进程主线程运行；owner 关闭后读取原生状态返回 `Closed`，不会回访已释放的 Zig owner。

后台文件读取、pump、任务存储和线程都由宿主显式安排。worker 使用 `App.post` 交付稳定 Ticket 和 owning response。post 返回 `Full/Closed` 时不接管它们，宿主必须自行取消、释放或保留重试；成功 post 必须执行一次。pump 可在 worker 上等待显式接受和有界 socket 背压，主线程从不等待它，也不使用普通文件 GInputStream 的隐式异步 worker。

已知长度的生成字节可使用独立 [ziggurat_native_stream](native-stream.md)，把其 Source
直接交给同一个 `respondSource`，由显式 worker 的 Writer 分块生成。HTTPS 不新增该
模块依赖，HEAD不生成body，文件和生成流共用consumer/physical容量；导航、reader.cancel
与宿主撤销的边界、最后引用和写出credit不等于页面ACK均按该合同执行。

实际文件 consumer 使用现有中立 file-stream 的一个 physical/control 账本。HTTP 具有独立的最多 32 个 physical Op；文件自身仍是原来的 process 32、consumer 最多 8，没有复制文件计数。每个 body 只有一次最多 16KiB 的 source read 和一个排队发送 chunk。`wrote-chunk` 才允许下一次 read，`accumulate=false`；这只是 HTTP 写出 credit，不是应用协议的消费确认。短文件、source EIO、取消和断开退役连接，不调用“成功完成短 body”。

## 关闭与最后引用

Endpoint 是显式的 App Stop 参与者，不建立 keepalive。Stop 封入口、撤销 C 的 Zig context，再取消全部已接受操作。宿主仍须显式 `close` Zig Endpoint，且 App 覆盖它的全部使用期。`close` 可以在 `on_request` 或最终 OwnedResponse free 回调中重入，活动 pin 令最后释放延迟到 callback 退栈。已经由 Stop 接管的节点遵循核心 `StopInProgress`，不会另设关闭状态机。

下表为 Linux 原生引用链。Windows 由有界 Envelope、C-only Owner/Ticket、worker
连接和 Source Reader 分别持有；worker 先退 TLS/socket payload，迟到 post/Ticket 只
释放独立 metadata，详见 Transport 合同。

| 存储 | 实际引用与归还点 |
| --- | --- |
| Gate | 请求 message 的私有 qdata 持 C Owner，不存 Zig context；正常 handler 接管后释放 |
| Op | 固定槽、取消/credit source、candidate、read callback、message 最终 qdata 各自 pin；最后一次引用才归还 HTTP physical 槽 |
| Ticket | 线性 caller ref 与 Op 的 C control ref；worker 最后释放仅触原子/GCancellable/纯 C 元数据 |
| GSource | 每 Op 固定两个，由 Op 保存 owning 引用；close 主线程主动 destroy/unref，未派发 source 也能收回，不形成常驻 cycle |
| 文件 stream | 中立 physical 引用覆盖 response、pump 和实际 GInputStream；最后一项结束才归还文件 slot |

活动连接错误使用已持有的 message/socket 撤离连接。已经 finished/disconnected 的消息只取消，不再 steal connection。晚到的 GIO callback、message/qdata 释放和 Ticket 只触 C 原生状态；`on_closed` 表示 Zig owner 最后使用结束，可以先于这些物理引用归零。如果宿主不再迭代 owner main context，已取消的原生任务可能保留到后续 context 迭代或进程结束。`nativeCounts()` 在 App/Endpoint 关闭后仍可观察这些 C-only 责任。

## 预算与边界

默认最多 8 个 Endpoint pending Op，硬上限也是 8；所有 Endpoint 共用 HTTP process physical 32。Linux 的元数据、C body copy、固定 file read buffer、candidate 与旧 physical Op 同时计入本项目实际 requested bytes。候选期间调用者 owning response/headers 的借用字节，以及每个活动 body 最多一个 16KiB SDK queued payload 的已知 reservation，也纳入 `Limits.bytes` 和 peak。HEAD 不复制表示 body，但调用者若已持有 OwnedResponse，其接受前借用存储仍计 reservation。

Windows Endpoint 的 Owner、Ticket、response candidate/body copy、borrowed input
计入同一 Endpoint budget；Server/Worker/Envelope、TLS record 与 provider allocator
在独立 WorkerLimits 中，Source ring/物理通道继续单独计费。Windows 不把项目自有的
TLS buffer 伪装为 libsoup queued payload，后者字段为0；详见 Transport 分项 stats。

`Stats` 分别报告 requested、borrowed input、queued payload reservation、peak 和 physical pending。Body 最大 16MiB，文件最大 256MiB，可由实例收紧。文件中立模块的固定元数据账本独立报告，不把它冒称 HTTP malloc。GObject/GSource/header/TLS、libsoup parser/socket 和其余 SDK 内部分配未纳入项目 malloc counter；固定操作数/头长度限制其输入和实例数量，不能把它们说成总内存硬限额。GLib 的进程 fatal OOM 也没有伪装为可恢复 allocator 错误。

requested/peak 是上述堆分配和 reservation 口径，不是线程栈峰值。构造有固定 Policy 栈捕获；headers 路径的 C 和 Zig 各最多 64 个借用描述符，响应至多 16 个描述符，均不随 payload 增长。编译器栈帧和 SDK 栈使用不计入这组 counter，也不宣称精确的栈字节测量。

模块实现 HTTP/1.1 GET/HEAD 资源运输，并提供独立显式 Range 请求准入与纯数字选择。HTTP/2、动态 server 配置、请求 body、重定向服务和完整本地站点能力仍未实现。Linux 已验证公开 Endpoint 与独立 WebView 凭据的组合；这不增加 Endpoint 对页面导航、IPC 或普通网络的权限。

## 验证

`zig build test-https-resources` 运行不依赖网络的 policy、metadata 和关闭能力测试；默认关闭 native 时不查询 libsoup。启用原生链接可用 `zig build test-https-resources -Dhttps-resources=true`，Windows 另需显式准备固定 TLS source。未启用和入口不支持的平台测试以不可解引用的 App/server token 与 fail-first allocator 验证先返回 `UnsupportedCapability`。

Linux 实际 TLS/App 夹具通过 `scripts/https-resources-probe.sh -Doptimize=Debug` 运行，`ReleaseSafe` 使用相同入口。宿主须提供 GnuTLS GIO module；私有依赖部署可显式设置 `ZIGGURAT_HTTPS_TLS_ROOT` 与 `ZIGGURAT_HTTPS_LIBRARY_ROOT`，runner 在私有 namespace 只读挂载它们，测试证书和私钥仅用于该夹具。`GDK_SCALE=1/2` 两个值下的 Debug、ReleaseSafe 均实际完成 28 项检查，包括 TLS GET/HEAD、认证和 URI gate、文件长度与零读取 HEAD、背压、worker 取消、post Full/Closed、Stop、构造 OOM，以及最后 allocator free 重入 close/quit。每项最后项目原生引用均归零；这些是隐藏窗口集成检查，不建立视觉质量或性能结论。

`scripts/https-resources-probe.sh --native -Doptimize=ReleaseSafe` 使用同一 TLS 环境运行正式 `test-https-resources-native` 目标。它在独立测试进程链接启用故障注入的 HTTP/file 实现，不与生产 consumer 的物理状态同时链接；开启原生 HTTPS 的 `check` 会编译该夹具，但不会隐式运行网络检查。CI 的可选 Linux WebKit 阶段已接入普通/2× App 夹具和独立故障目标；配置解析通过仍不代表远端已运行。

独立 strict-C 夹具 `tests/https_resources_native.c` 另覆盖 16 个场景：2MiB 运输、慢客户端、短文件和真实 EIO 连接失败、未启动 pump 取消、HTTP/file 候选分配故障、early Gate 分配失败，以及五个 consumer 共用 32 个 HTTP physical slot。保留消息的原生引用时，logical close 不提前归还 slot；最后引用释放后归零。该组以 `-O2`、AddressSanitizer 和 UndefinedBehaviorSanitizer 实际通过，未禁用检查。SDK 内部分配与连接超时仍遵循前述宿主合同。

`P01_PROBE=https-pages-zig bash scripts/webkit-probe.sh` 运行公开组合目标
`smoke-https-pages`，同时启用 `-Dwebview=true -Dhttps-resources=true`。私有 GIO
TLS 模块可用 `P01_TLS_ROOT` 指定；`P01_OPTIMIZE` 与 `GDK_SCALE` 分别选择编译模式和
缩放。夹具只接受自己的测试证书，不改系统信任。

真实页面读取内存、显式 worker Ticket 与 524325-byte 私有文件，并检查 HEAD 的
authoritative Content-Length/空 body；其他模式分别核验文件独立取消、Stop 在
worker 唤醒前封 Endpoint、post Closed 保留调用者拥有权，以及缺失 Bearer 零业务
offer。最后 HTTP/file/Profile/View 的原生引用全部归零。目录准备在 App.init 前，
App 释放及 native drain 后才由显式 worker 清理本次确切目录；失败构造同样撤销已
接受责任。ReleaseSafe 2×与独立 Debug 1×各为 20/20 构建步骤，均完成五模式。
隐藏窗口网络集成不建立人工交互、视觉质量或性能结论。

后续独立 Site 路由与 FileWindow 增量将当前夹具扩为十模式。新增固定授权的
`/private/window` 使用显式 worker 的 `files.PreparedSource.prepareWindow`，将
offset17/length65541 作为完整 HTTP200 表示；真实页面逐字节核验 body、选定的
authoritative Content-Length 和固定 policy headers，再检查同一路径 HEAD 与
empty window GET。HEAD/empty 均为零 pread，公开 length 缓存被刻意改写也不能
覆盖原生权威值。该模式创建时为三个文件责任显式配置三个 consumer 槽，不假设
SDK 会立即释放已完成 HTTP 的额外 stream 引用；既有九模式仍保持原两槽配置。
Debug/ReleaseSafe 的 1×运行各为 20/20 构建步骤，十模式最终原生引用全部归零。
该原语仍要求整个源文件满足 worker 指定 maximum，不解析 Range、生成 206 或
授予目录权限；完整合同见[独立文件流](file-stream.md)。

后续显式 Range 准入的纯目标在 Debug/ReleaseSafe 各20/20测试通过；TLS/App
目标在两种模式各13/13构建步骤，实际运行36种请求/寿命模式，另有创建期 flag
冻结、双配置构造 OOM 和 transport 撤销检查。新增 Range 默认拒绝、显式完整200、
HEAD忽略范围语法、重复字段/坏尾/认证/Origin拒绝，以及同步响应和 callback close
后的头借用；均检查最后原生引用归零。

同源 WebKit 组合另在 Debug/ReleaseSafe 的独立新进程中运行两个 Range 模式。
固定授权文件的部分/后缀206、metadata-only416、错强标签/多范围/未知单位的
完整200、HEAD零pread，以及0B FileWindow 的GET/HEAD全部实际通过，页面逐字节
检查内容和 Content-Range/长度/CSP。只对新模式显式配置更高物理槽与预算，旧十模式
保持原配置；本次未重复旧十模式，也不把之前的完整运行追溯成新源码验收。

公开 `FileRequest`/`PreparedFileResponse` 随后把这组 worker 决策与206/416/200 metadata
收为拥有型接口；用 `Offer/Ticket.respondPreparedFile` 在原事务接受点一起撤销 response
及 Ticket。它仍要求宿主先授权、处理其他 HTTP 条件、提供强标签与稳定文件，再显式
安排 worker 和 App.post。HEAD 保留真实源验证但零 pread，416 不创建文件源或 Pump。
完整[拥有权与范围合同](http-byte-ranges.md#拥有型文件响应)列出了 post 失败、接受取消、
字段不可修改、默认成本和实际验证范围；这项不增加 `Options.local`/`local_site` 能力。

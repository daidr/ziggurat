# 显式 HTTPS Transport 与本地页面流程

`https_resources.Transport` 明确拥有一个 TLS-only、`127.0.0.1:0` 监听器，端口由
系统分配。Linux 使用进程主线程的默认 GMainContext；Windows 由宿主的显式 worker
准备并运行，主线程采用独立 Listener。模块不创建 App、Window、线程或第二个事件
循环，不读磁盘、生成证书或修改系统信任。
默认关闭；未开启 `-Dhttps-resources=true` 时入口先返回 `UnsupportedCapability`。
`create/createWithFailure` 只支持 Linux，`prepareOnWorker/adopt` 只支持 Windows，
不支持的入口在读取 App、PEM 或调用 allocator 前拒绝。

## 证书、构造和预算

宿主先在自己的 worker 上准备 `Material{certificate_pem,private_key_pem}` 的内存字节。
第一片接受一个最多16KiB的 leaf certificate 和一个最多16KiB的未加密 PKCS#8 private
key。共享纯 PEM framing 与 Profile 证书验证使用同一实现；真正的证书/密钥解析由
GIO TLS backend 完成。私钥格式、证书来源、随机 Bearer 和文件字节身份由宿主负责。

`Transport.create(allocator,app,.{.material=material})` 返回稳定拥有型指针。
`createWithFailure` 可另接 `?Failure{domain,code}` 输出；容量、输入、caller OOM
不伪造 GLib 诊断。实际 SDK 解析或 listen 失败保留真实 GError domain/code。
成功只说明构造了监听器，不证明 key/certificate 匹配或 TLS 握手已成功：固定
GIO/GnuTLS 对不同的合法 key 与 certificate 实际返回了构造成功，部署仍须由宿主及
实际握手验证。Profile 的证书例外也不能修复错配的服务端密钥。

构造在第一次 foreign/allocator 前拥有全部 PEM 字节，并冻结 Limits/on_closed；
原 Options 描述符在 allocator callback 中被替换不会改变已捕获配置。
只有这个显式 noinline 构造入口支付固定捕获帧。每条退出路径清零该帧的完整 key
存储，原始宿主 PEM、编译器副本和 GTls/GLib 的内部密钥存储不在擦除保证内。
原生 server 在 caller allocator 前已有独立 C owner，创建期 Stop/OOM 回滚不通知
用户 on_closed，也不会把临时 Zig 栈指针放进 SDK。

Linux `Limits.bytes` 默认64KiB，包含本项目 C metadata、Zig owner 和整个构造捕获帧的峰值
reservation；有效但太小的预算返回 `TransportBudgetExceeded`。SDK 对象、TLS、socket
和 allocator 内部存储另属系统成本，GLib fatal OOM 不伪装成可恢复错误。
Linux Transport 共用16个物理 C owner 上限；关闭后的 server 仍被 SDK 引用时继续占槽，
新构造返回 `Full`。`stats()` 报当前 requested、构造 peak、accepting 和实际 port。
port/origin 是元数据，不是网络权限或 server 借用权。

## Windows 的显式 worker

宿主把实际进程主线程 ID 与内存 Material 交给自己的 worker：

```zig
var prepared = try https.Transport.prepareOnWorker(main_thread, material,
    .{ .bytes = 8 * 1024 * 1024, .connections = 8 }, &failure);
```

结果为线性的 `Prepared{listener,driver}`。只把 Listener 移至主线程，并调用
`Transport.adopt(allocator,app,&listener,.{})`；失败保留 Listener，成功才消费。
adopt 在第一次 caller allocation 前独立 pin C server，冻结选项，并在 allocation
返回及发布前复核同一 Listener。准备失败和构造失败均不通知用户 `on_closed`。
主线程采用成功后，宿主显式通知原 worker 调用 `driver.run`。

prepare、run 和 Driver.deinit 必须在同一原 worker，包含准备后未运行、采用失败和
正常退出。WrongThread 不消费 Driver。Listener.deinit 与 Driver.cancel 只撤销并
唤醒，不等待；全部 TLS、密钥、socket 和 connection payload 在原 worker 退休。
其他线程调用 Driver.cancel 时也须持有稳定借用，由宿主同步其 token 的移动/最后
deinit，不能与同一个 token 的退休并发。App 必须覆盖 Driver.run、正在执行的 post
以及全部已接受 envelope。正常次序是
**App.run 返回并排空已接受 post → join 自己的 producer/driver → App.deinit**。
gate 清指针、logical close 或 on_closed 均不能代替这个边界。

Windows `AdoptOptions.limits.bytes` 只计 Zig Transport metadata。独立
`WorkerLimits.bytes` 默认8MiB，包含 Server/Worker/envelope 与 TLS allocator 的实际
requested bytes；最多8条并发连接的 metadata 先保留，再把剩余预算交给 TLS。
Endpoint response/borrow/candidate 与 Source ring 仍有自己的预算。stats 合计 Zig、
C metadata、TLS live；reserved peak 是 metadata peak 与 TLS peak 的保守和，不
声称两个峰值同时发生。系统 socket/kernel、allocator 内部、浏览器/SDK 和宿主
worker stack 另计。显式 worker 的 PEM capture 还有固定32792字节栈存储，返回前
擦除；不能把它称作 worker heap 或 RSS。

监听器仅绑定 IPv4 回环，采用严格 HTTP/1.1、origin-form request head 与关闭连接
响应，不支持未知长度、chunked、pipeline 或请求 body consumer。项目只从 TLS API
取到头部 delimiter；TLS record/kernel 可能已经缓冲同一 record 的后续 wire 字节。
实际 Host、Bearer、Origin、GET/HEAD、header/Range 许可继续独立校验，不制造 Origin。

TLS provider 固定为 TLS1.2、ECDHE-RSA/P-256/AES-128-GCM/SHA-256 与 HTTP/1.1 ALPN，
不请求 client certificate。BCrypt 系统熵初始化每个 worker 自有 DRBG，失败拒绝；
无全局 App allocator、密钥持久化、证书 store、HTTP.sys 配置、seed 文件或隐藏线程。
私有 TLS library 类型不进入公共 API。

仅显式 Windows HTTPS 构建链接可选固定依赖。用 Python3.12+ 运行
`python scripts/fetch-mbedtls.py`，或用 `--verify-only` 检查已有字节；构建不下载依赖。
脚本校验官方3.6.7 archive 的固定 SHA256，选取7,894,271字节，连同5,473,689字节
archive 共13,367,960字节，分别受18MiB/24MiB上限约束，保留并安装原 LICENSE。
该维护分支的支持期仅至至少2027-03，provider 保持私有可替换边界。普通
Core/UI/WebView/file 使用不引入 TLS library。

## Site 的一次绑定与关闭

`Site.createOnTransport(allocator,app,transport,options)` 与自有 server 的 `Site.create`
保持相同路由和请求策略，options 无 port 字段。它在一次受保护 native lease 中读取
实际 server/port，Endpoint 独立取得 server pin。临时 server 最后 unref 返回后，
只检查仍独立持有的 C owner 与已保存 App，不再访问可能已释放的 Zig Transport。
创建中关闭 Transport 或 Stop 会失败并撤销候选；失败 Site 不触发用户 on_closed。
静态表、CSP、文件响应、授权、Range 和总预算仍按原 [HTTPS 资源合同](https-resources.md)。

`seal()` 拒绝新监听与 Site 绑定，`close()` 另外退休 Zig owner。Linux libsoup 的
`disconnect` 允许在途请求继续；Windows 会关闭尚未归属 Endpoint 的半握手、
不完整请求头、未派送 post 和无 owner 的拒绝响应，已领取的 Endpoint/Ticket 仍可
完成。这些入口均不等待网络 drain。
宿主在正常退出时先 close Site/Endpoint，再 close Transport；App Stop 会独立执行各自
StopParticipant，Windows Transport Stop 还撤销所有连接，App 的 stopping 门先阻止
业务派送。在途消息和 Ticket 继续由 Endpoint 自己的取消/最后引用合同管理。

`close()` 返回 closed/deferred；on_closed 在最后 Zig callback pin 和 allocator free
之后恰好通知一次。它不代表 server、browser 或网络已退出。
最后原生引用只拥有 C metadata，没有 App、Zig callback context 或 caller allocator；
`transportNativeCounts()` 可在 owner/App 释放后观察 owners、servers、bytes。
不得用 on_closed 或 logical close 提前复用物理额度。

## 可用的 Profile/View 组合

模块依赖保持 `https_resources → Core`，不引入 WebView。Linux 已验页面流程是：

1. 显式 worker 读取 PEM，并准备、handoff Profile 目录；主线程 adopt 后创建 App。
2. 创建 Transport，然后 `Site.createOnTransport`，明确 mount、随机 Bearer、静态表、
   动态 handler、文件 worker 和容量。
3. 从 Site 取得规范 HTTPS origin，以该 origin 加受检 mount/start route 构造 URL。
   用同一 leaf certificate 创建专用 `web.Profile.createWithOptions`。
4. 让 View 的 `RemotePage.origins` 只授这个精确 origin，再独立给
   `request_credentials` 同一 origin 的 Bearer。header grant、GET/HEAD、Range、IPC、
   导航、IP 和 TLS 许可各自仍须显式满足；不因为 listener 本地就授予网络或文件权限。
5. App.run 返回后完成已接受工作、关闭 Site/View/Profile/Transport，显式 join 自己的
   worker，并按需要迭代宿主原生 context 退役 C-only refs。产品没有添加等待线程、轮询
   或嵌套 App 循环。Profile 目录的清理放在实际 browser/context 最后引用释放之后。

Profile 的 loopback certificate 例外是 manager 上的单 leaf + `127.0.0.1`，不是 port
pin，也不是强制 pinning。精确 origin gate 与 Bearer 发送能力因此保持独立；不要把
同 leaf 的另一 port 默认为可信页面。实际 recipe 见
[`linux_https_page_resources_smoke.zig`](../tests/linux_https_page_resources_smoke.zig)。
这套独立公共流程没有改变 `Options.local`、默认合成域或 Linux `local_site` capability。

Windows 使用同一 Site/Endpoint/Source：先显式 worker prepare、main adopt，再准备
View 的精确 HTTPS origin、请求凭据及宿主信任配置，之后通知 driver.run 并进入
App.run。Windows 生产证书须通过既有正常系统验证；本模块不替宿主安装信任或提供
TLS 绕过。测试专用固定 leaf 例外仅链接进隔离夹具，产品没有这项功能。
下述实际浏览器结果使用测试专用例外，不能据此宣称生产自签名 loopback 页已可用。
Windows Profile 级显式 pin 与同 session 多 View 的统一信任责任仍待实现。

## 实际范围和成本

Linux x86_64、固定 libsoup3.4.4/WebKitGTK2.52.6、X11 1×下，Debug/ReleaseSafe 的
纯目标各34/34通过；独立 native 目标各2/2，包含8组 owner 生命周期与合法错配 pair
的真实 parser 观察。public constructor 另测 Options 捕获、首 allocator Stop、最后 free
重入 close/quit、所有 caller OOM、tiny budget、真实 GError，以及 Site 候选中关闭并
释放 Transport、最后 free 再 Stop；失败 Site 的 on_closed 为0。

两种编译模式各完成13个独立真实页面进程：静态/动态内存、FileWindow、206/416/完整
200、原始空文件、HEAD零pread、独立取消、Stop、post Closed、缺 Bearer、callback
close 与最后 free close/quit。另一 public Transport/Site 使用同 leaf/host；宿主原生
`navigateRemote` 精确返回 OriginDenied，独立 test-only server observer 记录 wire0、
Authorization0，不把页面 CSP/CORS 拒绝当作来源策略证明。每项 Stop 后由显式 worker
实际连接同 port，结果为 ECONNREFUSED；最后 HTTP/file/Profile/View/Transport/observer
引用均为0。

实际 Debug ELF 的 Transport160、Captured32792、Site208、Endpoint496字节；C owner
在 Debug/ReleaseSafe 都为48字节。按这些类型和 Stats 的口径推导，创建后 requested208、
捕获峰值33000字节，只涵盖上述本项目值；Endpoint/Site/Profile/View 的默认字段没有新增 Transport 状态。
共享纯 parser 无运行时全局分配；这些是类型与引用成本，不是全调用链栈、SDK总内存、
RSS、吞吐量、视觉或其他平台的运行结论。

Windows 私有 TCP/TLS reactor 在 Debug/ReleaseSafe 各通过23个实际场景，包括4MiB
逐字节、HEAD0、空/短表示、策略拒绝、Full/Closed、迟到 Ticket、从未 run、seal
后 Ticket 完成、半握手/不完整头/无 owner 拒绝退休、真实非末块 WANT_WRITE 时取消、
Ticket 预算及 OOM 后保留原 borrow。每项最后 network/endpoint/channel/TLS refs 为0。
实际 C Server/Worker/Envelope/Candidate/Owner 为296/131936/24648/80/376字节；
这些是显式开启后的布局，不能推导默认文件路径、调用栈、吞吐量或总内存。

公开 Windows x86_64、固定 WebView2 SDK/已安装 Runtime 的 Debug/ReleaseSafe，各
240/240构建步骤、34/34纯测试与10个新进程模式实际通过：构造模式内8组 adopt 失败
与重入责任，其余9个浏览器模式覆盖完整生成/零表示/HEAD0、文件206逐字节/HEAD0/416、
显式取消、Stop、post Closed 保留、Endpoint close、导航、自有 browser recover、错
certificate 拒绝及 Transport.close 后已有 Ticket 完成。App、worker、browser、channel、
TLS provider/domain 与其他 native refs 结束均有明确断言；每轮465项受保护输入前后
一致。固定证书例外只在隔离 adapter 中，不链接到生产 View。

真实构造回归保留了 OptionsNotFrozen 失败；最终入口在 foreign/caller allocation 前
提取 handler 的标量，通过 noinline helper 传递，不依赖整个 Options by-value 参数
隔离 caller 内存。失败不通知 on_closed，成功 handler 恰一次；最后 free 可重入
close/Stop。实际 Windows Transport/Source/Writer/Pump 为160/16/8/8字节；独立编译
原生产 C `ZwsFilePump` record 得到40字节、8字节对齐，不能把8字节 Zig token 当作其
完整 native 存储。完整证据入口为 `tests/windows_https_producer_host.py`，由
`build-smoke-https-producer -Dhttps-resources=true -Dwebview=true` 构建；host 使用
Python3.12+、fresh evidence/profile/payload，并仅清理确认结束的自身成功目录。

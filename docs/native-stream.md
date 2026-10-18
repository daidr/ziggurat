# 原生响应的显式字节生产者

`ziggurat_native_stream` 在 Linux/Windows 提供已知长度的原生字节流。宿主的 worker
逐块生成数据，Source 可交给独立 HTTPS Endpoint；模块不导入 Core、WebView 或
HTTPS，不创建线程、App、服务或事件循环，也不保存完整生成体。Linux 原生 fetch
流程与使用隔离证书例外的 Windows App/browser HTTPS 组合已验；其他平台明确返回
`UnsupportedCapability`。

## Source 与 Writer

`prepare(main_thread, length, maximum)` 只在显式 worker 调用，返回线性的
`Prepared{source,writer}`。`main_thread` 是实际进程主线程 ID；长度可为0，
`0 < maximum <= 256MiB`，`length <= maximum`。没有未知长度或 chunked HTTP API。
`prepareWithFailure` 可保留真实原生 errno 或 Windows code；OOM、容量、参数错误
不伪造系统错误。

`Source` 是现有 `file_stream.PreparedSource` 的类型别名，表达同一个字节
consumer 协议，不表示生成流获得了文件、目录或 HTTP 权限。它直接交给
`Endpoint.Offer/Ticket.respondSource`，HTTPS 模块没有新增 native_stream 依赖。
原生 authoritative length 决定响应长度，公开缓存字段不能替代原生值。

Source 与 Writer 分别拥有同一物理通道的一份引用，不能复制、伪造或修改 owning
字段。Writer 可用 `take()` 显式移动；首次操作固定一个非 UI worker，之后不能
转由其他线程生成。`waitAccepted()` 等待 Source 被接受为 body/HEAD，或者取消。
只有 worker 等待，主线程不等待生成者。Source 未接受便释放、失败投递后回收或
接受后撤销都会唤醒 worker。

`writeAll(bytes)` 借用一块非空、最多16KiB的输入直到返回，成功后不保留输入指针。
声明长度、chunk、实际发送错误会使生成终态失败并取消通道；OS 可能已写入一部分，
不能重试整块输入。错误线程或错误 kind 的调用只是无状态的权限拒绝，不破坏原流。
`finish()` 只有精确完成声明字节数或已接受 HEAD 才成功；重复 finish 返回 Finished，
成功终态不能被后续误调用改写。`deinit()` 先撤自己的 handle，取消尚未完成的生成，
再释放引用，不 join。

HEAD 不生成 body。worker 若观察到 `.head` 可直接 finish；宿主已经拥有 HEAD
请求事实时，也可在主线程接受 Source 后直接退休 Writer，完全不调用生成器。
SDK 可能在 worker 观察之前已完成并释放 HEAD stream，此时只会观察到取消，
不能据此重发响应。实际表示长度与所有接受前限制仍适用。

## 宿主交接与撤销

宿主先通过自己的来源、方法、认证和其他业务条件，再创建或 defer 网络 duty。
典型流程是：

1. 主线程在已授权的 Site/Endpoint callback 内捕获必要数值，接管一个 Ticket。
2. 宿主启动自己的 worker，准备 Source/Writer，把 Source 与 Ticket 放入稳定 job，
   通过 `App.post` 交回主线程。成功 post 后 worker 只使用自己的 Writer。
3. 主线程调用 `ticket.respondSource(head,&source,options)`；失败保留 Source/Ticket，
   成功先消费 owning 字段，再激活原生 stream。accepted_cancelled 同样已经消费，
   不能重试。需要独立撤销时请求 Receipt 的 Control。
4. worker 等接受、生成并 finish；post 的 Full/Closed 不接管 job、Source 或 Ticket，
   原拥有者显式保留或回收。准备后的 Writer/Source 都须覆盖失败退出。
5. 导航、页面关闭等策略由宿主明确取消自己的独立 Control。Endpoint 网络身份不等于
   PageId，不自动绑定页面代数。`reader.cancel()` 不提供宿主业务撤销保证；App Stop
   封入口并取消既有 consumer，最后在 `App.run` 返回后 join 自己的 worker。

Transport、Site、Profile 的完整配置仍按[显式 HTTPS 页面流程](https-owned-transport.md)
提供：证书/私钥来自宿主，Profile 信任与端口权限独立，RemotePage 的请求权限和
exact-origin Bearer 各自明确配置。Source 不添加 Origin、Authorization 或 CORS 许可。
custom 写请求缺少实际 Origin 时继续拒绝，opaque scheme 和 `local_site` 未因此开放。

## 背压、容量和成本

文件与生成流共用现有 pollable socket channel、32个进程物理槽和每个 consumer
最多8槽的同一账本。immutable kind 明确区分文件 Pump 与生成 Writer，两者互拒，
不通过已关闭 fd 猜种类。取消、EOF、Stop 或关闭 owner 不提前归还物理槽；实际
Source/Writer/原生 Reader 最后引用释放后才归还。独立 Control 不保留物理槽。
迟到引用只有 C 状态，不借 App、View、业务 context 或 caller allocator。

Linux worker 只在非阻塞 socket 的容量和 eventfd 取消上等待。通道请求32KiB发送缓冲，
验证系统返回值不超过128KiB；没有 body 大小的项目缓冲。现有 Endpoint 每次读取
最多16KiB并保留一个发送 chunk，等待 HTTP 写出 credit 后再读。socket/writeAll
成功与 libsoup credit 都不是页面消费 ACK；浏览器、TLS、网络进程和内核可能继续
缓冲。暂停 JS reader 不保证 worker 立即阻塞，需要消费 ACK 的应用流仍使用
[独立 IPC 字节协议](resource-stream.md)。

Windows 使用同一共享 physical prefix 区分直接文件 IStream、文件 Pump 和生成
Writer。生成/文件 Pump 才分配32KiB ring，单次输入最多16KiB；普通直接文件仍为
原 IStream 路径，保留 worker-only Read 与 Seek 合同，不平白分配 ring。Writer 等待
显式接受/容量/取消事件，HTTPS worker 用同一原生 Reader；public stream() 不把它
伪装为 IStream。Windows 的独立 TLS worker 可有自己的 record 缓冲，按 Transport
预算另计。网络 credit 仍不是页面消费 ACK。

Linux x86_64 Debug/ReleaseSafe 的实际 Source/Writer/Prepared 为16/8/24字节；
共享 C physical 为80字节，与本批之前相同，kind 使用原有对齐空隙，kind 专属值
使用明确 union。未增加默认 View/Endpoint/Site/Profile 字段或普通文件通道分配。
每个显式通道仍有 physical/control metadata、socketpair/eventfd、SDK stream 及
consumer budget；SDK、内核、allocator 内部成本另计。这些尺寸不是调用栈、RSS、
吞吐量或零成本声明，宿主生成缓冲由自己的 worker 明确提供。

Windows 独立 native 检查实际得到 physical136、Control24、Reader16、ring32768
字节；直接 FileStream/Control/Budget 保持88/24/12字节，共用32字节 physical prefix。
真实混合16直接文件+16生成流只分配16个 ring，覆盖32进程槽、consumer8、held
Writer、旧 Control、4MiB、取消及最后引用归零。这些是该目标的布局与责任证据。

## 验证范围

`test-native-stream` 检查 UI/长度边界、冷 Unsupported 和线性移动。
`test-native-stream-native` 的隔离 C 实现验证真实 pollable 读取、4MiB逐字节、
HEAD/0长度、实际 EAGAIN 后取消唤醒、短/长/非法输入、7字节部分发送后 EIO、
所有项目 metadata OOM、候选失败/撤销重试、文件与生成流混合32槽和额外原生引用。
成功 finish 后由另一 worker/UI 误调用，仍须读完原成功字节和 EOF；这项保留了
真正编译运行的 RED 与修复后的 GREEN。

固定 WebKitGTK2.52.6/libsoup3.4.4、X11 1×下，Debug/ReleaseSafe 各8个独立进程
验证原生 fetch/零表示、HEAD零生成、首chunk后显式撤销、Stop、失败post保留、
导航、自有 WebProcess recover 和 Endpoint关闭。取消夹具用显式测试 gate 确定阶段，
并持有真实 Writer 引用到 App.run 返回，证明逻辑取消不提前归还槽；不是生产 ACK
或 worker 生命周期补丁。最终 HTTP/file/Profile/View/Transport 引用归零，Stop 后
实际连接原端口被拒绝。该范围不代表其他平台原生流、unknown length、跨源 CORS、
custom 写请求或视觉质量。

Windows Debug/ReleaseSafe 各通过23项独立真实 TCP/TLS oracle，以及公开流程的
10个新进程（构造模式8组、9个浏览器模式）。覆盖已知长生成、零表示、HEAD零生成、
FileWindow206/HEAD/416、取消/Stop/post Closed、Endpoint关闭、导航/recover、错误
证书及关闭 Listener 后既有 Ticket 完成，最后含 TLS provider/domain 为0。浏览器
检查专用固定 leaf 例外不进入生产；Windows 正常系统验证与下一批 Profile 级 pin
仍独立，不能把这些结果写成自签名生产页面已有信任能力。

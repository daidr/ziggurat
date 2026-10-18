# 应用资源字节流

`ziggurat_resource_stream` 是独立纯数据模块；可选 `ziggurat_webview_producer` 将它接入当前页面的类型化 IPC。它提供显式的 `ReadableStream<Uint8Array>`，不替换 fetch，不改变原生 WebResourceResponse，也不授予来源、导航或 IPC 权限。Windows Runtime 验证与纯 Windows/Linux 测试分别记录；Linux WebView 仍不支持。

## 所有权与调度

`const Bridge = producer.Bridge(Request);` 生成唯一 `open(Request)` 流式服务，返回 metadata/body frame 与最终 `{bytes,chunks}`。Bridge 在主线程用 `create(thread_safe_allocator, app, options)` 创建，`bind(page_id, fresh_ipc_session)` 绑定一个页面。session 必须全局新鲜，不能重用旧文档身份。Bridge 是独立稳定 owner，不向 View 安装隐藏 listener；宿主在页面 started/失效时显式关闭旧绑定，或通过入口的 PageId 检查使它失效。App 必须覆盖 Bridge；View/PageSession 保持稳定到解除绑定，尤其在 on_closed 释放 View 前先 close Bridge。

`receive(message)` 只在主线程处理借用消息，返回 offer/control/rejected。offer 拥有解析结果，params 借用至 `offer.deinit()`；不可复制。`accept(&offer, head, .{})` 复制 metadata 并创建固定 slabs，成功才移交一个 Writer。失败保留 offer、没有 Writer；allocator 重入接受/拒绝/deinit 同一 offer 返回 Busy。已成功回答不能再次接受。丢弃 offer 的解析存储本身不回答请求，宿主仍需 accept/reject 或终结连接。

`reject` 和 `receive` 的 rejected 将终结责任交给固定 8 槽待发送队列，**仍需 drain**。队列先占槽再改变协议状态；Full 不接管新消息/offer，宿主保留消息并在 drain 后重试，或显式终结连接。物理流容量拒绝暂时拥有 Parsed/token，编码成功才释放 pending；取消可先撤销该等待。已经编码的拒绝不再有 pending token，后来 cancel 可以返回 StaleRequest，客户端忽略对应迟到终结。编码 OOM、转换预算不足或 transport 拒绝均保留当前唯一 packet，下一次 drain 重试同一份；不能重放业务请求。

Writer 通过 `take()` 移交，不能复制。首次 write/finish 绑定唯一生产线程；之后不得更换。`tryWrite(bytes)` 复制一个非空、至多 chunk_bytes 的 chunk，Full/错误不消费输入或推进位置。Full 后只有经验证的 body ACK 归还容量；`waitWritable()` 是显式 worker futex 等待，拒绝主线程。`finish()` 标记 EOF，不归还容量；deinit 未 finish 的 Writer 取消流。纯 Writer/Control 不持有 App/View/COM，最终 Control/Budget 释放可在 worker；显式 DeliveryTask 另持 Bridge，宿主的 worker 上下文可以借用 App 来投递，其寿命必须覆盖线程和已接受任务。

宿主用 `bridge.createDeliveryTask(context, on_ready)` 创建稳定交付上下文。worker 调 `preparePost()`，非空结果由宿主显式 `App.post(task)`；成功转移一次执行责任，Full/Closed 必须 `notAccepted()`，仍由宿主决定重试或取消。空结果表示已有一份投递，不是错误。worker 最后 deinit 自己的 DeliveryTask owner；已接受投递保留独立引用。UI 回调先解除合并位再调用 on_ready，新的 ready 不会被旧回调吞掉。没有隐式 worker、自动 post、轮询或 deadline timer。

`drain(max_packets)` 每次最多 1–128 个 packet，轮转流与终结队列；仅编码和同步提交，不等待 worker。发送接受只使 held body 变为 sent，ACK 才使它 free。发送回调内同步 ACK 暂存到 commit 之后；回调内导航/关闭不能复活旧槽。send 返回错误意味着未接受；ACK 后又返回拒绝属于 TransportContractViolation，关闭绑定。状态变更后宿主显式调用 drain；`ready` 表示本轮达到批量上限，可再安排一次自己的投递。

App Stop 只逻辑关闭并唤醒阻塞 Writer，不 join、不释放仍在 worker/Offer/DeliveryTask/回调栈中使用的 Bridge。`close()` 返回 closed/deferred；`deinit()` 在未释放责任或活动回调时返回 Busy。退出后先 join 宿主线程，释放其拥有结果/投递，再 close/deinit Bridge，最后 deinit App。存储不能在 deferred/Busy 时释放。接受任务在 stopping 仍执行一次，但不再调用页面/业务 ready 回调。

## 线序、成本与边界

wire sequence 1 固定为 head；producer sequence N 对应 wire N+1。head 占 IPC in_flight，一个 head ACK 不归还 body slab。零 body/HEAD 的终结同样等待 head 已 ACK。重复累计 ACK 不额外归还 credit，旧 session/request 或超前 ACK 不能释放新流。HEAD 可保留 representation length，但禁止 body；204/205/304 同样禁止 body。未知长度允许 EOF，已声明长度必须精确匹配，否则发送失败终结。

Options 默认最多 8 流、每流 4 个 16 KiB slab、100 万 chunk、256 MiB 累计字节、8 KiB header、2 MiB requested-memory 总预算。可配置上限分别为 8/16/16 KiB/`u32_max-2`/`u53_max`/8 KiB/16 MiB。header 最多 16 项，名称 64 字节、值 2048 字节，ASCII token/可打印 ASCII，拒绝 CR/LF、重复及 framing/hop 头。metadata 复制、slabs、解析 arena、base64 scratch、一个 encoded packet/流、终结队列、旧和候选同时存在的分配、每次 View UTF-16 转换的保守峰值都计入同一 Budget。分配器管理开销、系统 Runtime/浏览器内存、JS 消费者自行保留的 chunks 不在此计量内。UI 在接收/编码/转换时明确分配；不声称零分配或零复制。

物理流直到 Writer/held Delivery 释放才归还容量，逻辑取消、EOF 或已发送终结不能绕过旧 worker 的持有。绑定旧代未完成清理时不能重新 bind；最后释放仅保留无业务指针的独立 Control/Budget。没有 UI 等 worker mutex，也不读取磁盘或网络。

`src/resource_stream/client.ts` 的 `resourceReadable(generated_call, options)` 提供 head、body、completion。metadata 立即读取一次；body 的 highWaterMark=0，未 pull 不继续调用底层 iterator。base64 每 chunk 严格校验至多 16 KiB 并分配一个输出数组；summary 只在 reader 真正排空后验证。页面/transport 错误即使发生在暂停期间也立即拒绝 completion 和 body。调用者取消、协议/预算错误均幂等 cancel；不是取消系统 JavaScript 执行的能力。

生成客户端时使用 `producer.Service(Request)` 或相同 wire 声明；客户端 `maxPending` 不得超过 Bridge 的 max_streams，`maxInFlight` 不得小于 Bridge 的 in_flight。双方显式使用相同窗口值最简单。ResourceOptions 的 chunk/total/header 限额可进一步收紧，超限会取消；它们不反向改变已经配置的宿主 slab 容量。

这条应用字节协议与[完整私有文件按需响应](pages.md#完整私有文件按需响应)互相独立。
Linux 的[原生字节生产者](native-stream.md) 已另行支持已知长度 HTTPS fetch，Source/Writer
复用文件 consumer，不采用这里的 IPC ACK；其 socket/HTTP credit 不代表页面消费。
Windows 原生 response Complete 的完整 content 要求、opaque scheme 及未知长度原生生产
仍未因此改变，这里的 Linux IPC Bridge 运行范围也未扩大。

## 验证

`zig build test-resource-stream test-resource-producer` 覆盖 SPSC/ACK、head/body 线序、所有分配失败、重入 accept/cancel/bind/free、任务 Full/退出、终结队列预算失败和取消替换。`bun test tests/resource_stream_client.test.ts` 覆盖暂停、取消、暂停期间 transport 失败、base64/metadata/summary 边界；helper 与真实生成客户端通过 strict ES2022/DOM 类型检查。

Windows ReleaseSafe 的 `zig build smoke-resource-producer -Dwebview=true` 在三次 App 生命周期中实际运行生成客户端与 ReadableStream：worker 满槽等待、暂停/恢复、重复和旧 session ACK、zero/HEAD、拒绝 packet 转换预算失败后重试、park 保留页面、导航取消、stopping 已接受投递，以及 View UTF-16 allocator 内关闭、退栈后 on_closed 立即释放整个 Session。流/投递/COM/PageHost 最终归零；私有 profile 由 worker 准备，在确认浏览器进程退出后清理。另与旧 typed IPC、四 App PageSession 和 15 App/99 次 pending close 原生回归共同运行，不以纯测试或编译代替 Runtime 验证。

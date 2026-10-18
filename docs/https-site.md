# 显式 HTTPS Site 路由

Site 组合独立 HTTPS Endpoint 与有界静态路由，不把网络请求改成 WebView 资源请求，也不开放 `Options.local`、`file://`、目录或 Linux `local_site` capability。Linux 宿主可提供受检 SoupServer；Linux/Windows 也可显式拥有 [Transport](https-owned-transport.md)，通过 `createOnTransport` 一次借用 listener 的实际身份。raw `Site.create` 仍为 Linux 入口，Windows worker prepare/main adopt 不暴露长期裸 server。证书、mount、私有 Bearer、主循环、worker 与 View 来源许可仍分别配置。Windows 浏览器验收使用隔离证书测试例外，生产 Profile 级显式 pin 尚未实现。

Site 拥有所有静态路由的 path、MIME、body、mount 和自己的记录。入口先捕获有界描述符，调用者所有字节稳定到创建返回；实现先拥有字节再验证/排序，成功后可以释放或修改调用者存储。默认最多 128 个路由、单 body 最多 16MiB，route 子预算默认 32MiB。静态表、Site、Endpoint、响应候选及 Endpoint 的 borrowed/queued reservation 要共同受 Site 总预算约束；不能把各自上限相加后称作同一个总限额。SDK/TLS/parser 的未计内部成本继续按 Endpoint 合同单列。

构造在首次调用者分配前取得独立 server 引用，覆盖静态表和 Site 自身的准备。Linux Endpoint 创建期在初次检查、安装 handler 前和安装返回后验证唯一 TLS listener 与 raw-paths；Windows 对应复核同一 Transport 的采用/监听/未封口状态。分配器或旧 handler 的退出回调撤销 transport 后不会继续发布。Endpoint 已持独立引用后，Site 先撤临时 lease、实际释放，再复核 App，最后从 constructing 发布为 open；失败统一撤销候选，且不通知用户 on_closed。持有 server 对象只保证存储寿命，不能代替 listener 仍有效。

mount 沿用 Endpoint 的 canonical prefix 校验：从 `/` 开始、以 `/` 结束、至多 256 字节，精确字面分段，无点段或重复斜杠。路由是相对于 mount 的 canonical path，`/` 表示 mount 本身。仅接受 ASCII 字母、数字、`/._-`；无 query、fragment、userinfo、端口、反斜杠、残余百分号、Unicode、点段或重复斜杠。允许单个结尾 `/`，它与无结尾斜杠的另一条路由不同。Linux SDK 在提供路径前可能规范化 unreserved escape，Site 不承诺跨平台都看到相同原始 request-target 字节；Windows 自有严格 parser 直接保留 path/query，再经过同一 policy。Endpoint 先验证真实地址、认证、完整 URI 和方法，Site 再剥离精确 mount 边界；query 独立借用，不参与静态查找，也不会被当作文件路径。

静态 GET/HEAD 按二分表查找；未命中且没有显式 handler 时为 404。HEAD 保留 authoritative representation length，不复制或读取 body。静态响应和 404 带固定 CSP、no-store 与 nosniff；CSP 只允许自身脚本/样式/connect、内联脚本/样式及 data/blob 图片，frame、worker、object、base、form 与其他来源网络保持拒绝。来源隔离和生产 TLS 规则没有因这个路由器放宽。

动态与文件 fallback 是宿主明确安装的回调，收到 Endpoint 的真实 Offer，不携带或制造 PageId。path、query 和请求只在回调内借用；需要延迟时调用原 `Offer.deferRequest`，得到独立 C-only Ticket。Ticket 可跨 Site/Endpoint/App 生命周期取消或释放；响应仍只在主线程。动态 handler 自行选择和准备文件，不存在自动目录查找或 miss 到磁盘路径的回退。

**动态/文件响应的 policy headers 是宿主责任。** `policy_headers` 只是不可变借用列表；`mergePolicyHeaders` 只是显式的纯合并/校验，不会更改任何响应或 transport。handler 须把返回列表实际放进自己的响应。合并支持输入/output 重叠，先在固定候选里检查固定字段冲突、重复、16 行和 8KiB 总限制，成功后一次发布，失败保留 output。不得把拿到这个列表或用了 Site 等同于动态响应已经应用 CSP。

Site 不注册第二套 Stop 策略：Endpoint 在 App Stop 先 seal ingress，拒绝新 Offer 和响应；宿主仍须显式 close Site。关闭先撤去入口与拥有字段，在 callback pin 退栈后再释放。`on_closed` 只证明 Site/Endpoint 的 Zig 业务 owner 不再使用上下文，不代表 listener、浏览器进程、网络连接或所有 C-only 物理引用已结束；宿主分别关闭 transport、安排 worker 并检查最后 native refs。App 覆盖所有 Site 方法和显式 close，callback 可以 close，最终 allocator free/on_closed 可以请求 quit，但不允许在 UI 回调等待 worker。

纯路由检查为 `zig build test-https-site-routes`。真实服务端检查沿用 `bash scripts/https-resources-probe.sh -Doptimize=ReleaseSafe`；可选 WebKit 组合检查为 `P01_PROBE=https-pages-zig P01_OPTIMIZE=ReleaseSafe GDK_SCALE=2 bash scripts/webkit-probe.sh`。依赖与项目盘缓存配置沿用 [HTTPS Endpoint](https-resources.md) 和 [构建缓存](build-cache.md)，不在普通库启动时安装依赖或启动服务。

检查分别覆盖静态 GET/HEAD/404 与策略头、原动态内存/完整文件/HEAD、取消与 Stop、失败 post 保留 Ticket、回调中关闭、最终 free 重入关闭/quit、迟到 Ticket 以及构造 OOM。server weak observer 与 listener 撤销检查针对两处实际重入缺口；最后临时 unpin 后的 App 复核另有源码检查，未把其他分配回调的结果当作该确切回调点已被单独触发。隐藏窗口和实际网络检查不建立视觉质量、完整 Linux local_site 或浏览器进程退出保证。

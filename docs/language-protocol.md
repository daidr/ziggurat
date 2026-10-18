# 有界语言协议

`ziggurat_language_protocol` 是显式可选的协议模块。当前纵切片包含 Content-Length/JSON-RPC、UTF-16 坐标、显式 initialize/initialized、版本同步、completion/hover/诊断转换、取消/重启、显式 workspace folders 与配置快照。它是有界的协议适配，不启动语言服务器，也不代表完整 LSP 或成熟 IDE。

合同依据 [LSP 3.17 Base Protocol](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#baseProtocol) 与 [Position 定义](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#position)。不依赖服务器 SDK；普通编辑器与 paint 不导入或自动创建协议对象。

## 帧与消息

`codec.Decoder.init(allocator, limits)` 一次预留 header/body 缓冲，后续 push 不分配。`push(bytes)` 返回 consumed 和可选 body；一次只交付一帧，粘包的剩余部分仍归宿主，宿主再次 push。body 是到下一次 push/reset/deinit 为止的借用。Decoder 线性拥有缓冲、在创建线程使用，不复制后分别 deinit。

帧只接受 ASCII header、唯一十进制 Content-Length，以及 UTF-8 Content-Type（兼容 utf8 拼写）。默认媒体类型为 application/vscode-jsonrpc。重复长度、重复 charset、歧义/非法 header、其他编码或超限在交付正文前拒绝。错误后 Decoder 保持 failed；宿主只在明确的新传输边界 reset，不尝试在损坏字节流里猜测下一帧。

`codec.Message.parse` 先做无堆 JSON 词法/深度/token 预检，再用独立预算 allocator 创建 owning JSON 树。拒绝重复 object field、非2.0版本、batch、歧义 result/error、非法 ID/params。Envelope 区分 request、notification、response 与 failure，保留字符串 ID 和真实响应错误码。所有字符串与 Value 都拥有在 Message 内，不借 Decoder body；借用到 Message.close 结束。Message 地址稳定，在创建线程查询和关闭，foreign free 重入不能再次关闭对象。

`codec.Packet.json` 先用无缓冲有界 writer 计数，在递归进入下一容器前检查 depth、在写入前检查 body，再一次分配 header+body；第二遍输出同样有界，编码后复核长度/JSON词法预算，失败不发布 Packet。输入在两遍与 allocator callback 期间是不可变借用；自定义 jsonStringify 回调自身成本仍归调用者，不承诺限制任意业务回调。Packet 是独立线性拥有的字节，宿主可明确交给自己的 I/O worker；allocator 必须支持实际创建/释放线程。编码成功仅表示字节准备成功，不表示进程已收到或接受发送责任。Client 的 validate/commit 另行确认宿主接管，不能在编码或队列 Full 时提前移动同步版本。

默认 header8KiB、body1MiB、解析拥有/候选8MiB、65536个 scanner token、64层；硬上限64KiB/16MiB/128MiB/1048576/128。token 按 Zig Scanner 实际返回的词法片段计，包括转义片段；不是仅按 JSON 容器或字段数量计。JSON live/peak 计 stable state、Arena 与增长时同时存活的旧/新存储；输入、Decoder 缓冲和 Packet 单列，不声称一个额度覆盖所有宿主队列。词法预检使用固定4KiB栈 scratch。所有协议队列和 I/O 调度仍由宿主显式界定。

## 不可变 UTF-16 坐标

`positions.Map.create(allocator, reader, limits)` 是显式两遍线性准备，适合宿主 worker。它只拥有行的 byte/UTF16 起止 metadata，没有第二份可编辑正文。Reader 仍归原 Job/Snapshot 所有者；该独立借用必须覆盖 Map 的全部查询和 close。Map 不调用 Reader.release，不能代替 Job.release，也不能让 Snapshot 在活跃 Reader 时提前释放。

Map 是可显式移交的不可变产品。宿主先结束 worker 使用，再交 owner 采用；查询和 close 不并发，allocator 支持实际准备与最后回收线程。它不访问 UI、Adapter 或 native layout。Client owner 请求/采用入口只校验和采用已准备产物，不暗中把整篇扫描或 didOpen/full-sync 序列化塞进 UI 热路径。

LSP 行识别 CR、LF 和 CRLF；它们与 Document 的 LF 聚合分别处理。toPosition 从有效 UTF-8 scalar 字节边界得到零基 line/UTF-16 character；CRLF 两字节之间返回 InsideLineEnding，避免把一个不可表示位置映射成另一个字节。toByte 按规范将超过行内容的 character 收敛到该行末端，行号越界与超过 uinteger 范围拒绝；UTF-16 surrogate pair 中间仍返回 InvalidBoundary。不是 grapheme/视觉 caret/glyph 坐标。

默认源1MiB、65536行、metadata4MiB、scan work4MiB；硬上限64MiB/1048576行/32MiB/128MiB。两遍扫描预扣2×源字节，查询以行数组二分和 Reader 已有树聚合计算，不重新扫描整篇。Cancellation 由宿主 atomic request；每个有界 Reader segment 和第二遍开始检查，取消不发布半成品。stats 的 scanned_bytes 表示成功构造的两遍源字节工作；Reader/Snapshot 内存继续在 Document 原预算内，不重复称为 Map 拥有量。

## 线程与协议产品

| 对象 / 操作 | 线程与成本 | 所有权 |
| --- | --- | --- |
| Client / begin、commit、Delivery.finish | Broker owner；固定槽和版本检查，Broker Snapshot 有界分配 | 保留 Broker client；无 IO/线程/App 队列 |
| Transport | 宿主独占移交；prepare 控制 Packet、解析初始化响应 | 一个 atomic 物理寿命借用；close 后不可复制使用 |
| Work.prepare / receive / abort | 宿主显式 worker；Map 扫描、编码、JSON 与结果转换 | Job.Reader 覆盖 Map；结束生成一个 Delivery |
| SyncWork.prepare | 宿主显式 worker；完整或增量同步准备 | 独立 Snapshot/Reader、Map、Packet；可保留最新原始版本 |
| Delivery / DiagnosticDelivery | 独立拥有结果，宿主可交 App.post | 成功投递转交 task；Full/Closed 保持原对象责任 |

线性值可显式 move，不复制后双 close、并发调用或再使用旧副本。Transport、Work、SyncWork、Delivery 和外部任务上下文均须覆盖自己全部操作与回调。worker allocator 支持实际准备/最后回收线程；Client 自身 allocator context 至 Client.close 最后 foreign free 退栈都存活。它们不借 stack allocator context，不借 Decoder body 或 Message 字符串返回结果。

所有逐字节/逐行工作都在显式 prepare/receive 中。Client 本身不调用这些入口、创建线程、阻塞 pipe、post 或 join。宿主可自建有界 worker/mailbox；paint 不调用协议解析。Host 必须在受理发送前做 validate，按 epoch/整数 ID 将 response 路由到原 Work，通知路由到有对应 server version 的 SyncWork。库不替宿主猜测到达顺序或 URI。

## 初始化与同步

`Client.create(allocator, broker, uri, language, limits)` 复制 URI/language，保持同一个 Document。一个 Client 是一个 URI/一个服务 epoch 的 owner；该服务拥有 Broker 的三个结果通道，不与不相干服务共用并要求 invalidate 不影响它们。URI 按已解析的协议标识逐字节匹配，不做文件系统 URI 规范化。URI≤4096字节、language≤128字节，均有效 UTF-8、非空且无 NUL。

owner `beginInitialize()` 分配不回绕 request ID，宿主把 Handshake 和 `openTransport()` 交给 worker。`Transport.initialize` 准备真实请求；宿主接受发送责任后 owner `commitInitialize`，worker `negotiate` 校验响应 ID/协议并得到拥有型小 Capabilities。owner `adoptInitialize` 后，宿主受理 `Transport.initialized` 的 Packet，再调用 `commitReady`。编码 OOM 可用同一 token 重试，不提前变 ready。Transport 的 snippets 宣告须与 Client.conversion.snippets 一致，否则 ConflictingCapabilities；它不解析模板。Client 配置中的 map/sync cancellation 和 conversion.request_position 保持 null；这些上下文字段由固定槽和本次 Job 设置，避免静默忽略宿主传入的取消源或请求位置。

只协商 UTF-16。服务器省略 positionEncoding 按协议缺省 UTF-16；明确选其他编码返回 UnsupportedPositionEncoding。支持静态 textDocumentSync 的整数或 options、completionProvider、hoverProvider。此版本化文档流程要求 openClose 和 full/incremental sync；缺少同步能力明确 UnsupportedSynchronization。工作区查询、补全详情 resolve 和 shutdown/exit 采用下述显式流程；任意动态注册、save 和 work progress 尚未实现。客户端 stop 仍是本地封口，不表示已发送 shutdown。

owner `captureSync(server_version)` 捕获单 authority 的 Snapshot/Reader；server version 是宿主提供的非负 i32，在同一 epoch 内严格增加。worker `SyncWork.prepare` 构造 didOpen、full didChange，或以先前 **实际 accepted** SyncWork/原始坐标 edits 构造 incremental didChange。旧/新 Reader 及 Map 不得在 prepare 期间关闭。它验证 edits 重建内容与新 Reader 完全相同，再倒序编码原始区间，使每条 change 对前一条结果仍合法；并非猜测 Document delta。规则依据 [didChange 的顺序定义](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_didChange)。

owner `SyncWork.validateSend` 紧邻宿主受理；Full/OOM 保持 accepted stamp 不变。宿主实际接管时 `takePacket()` 移交独立 Packet，再 `commit()`。若宿主的受理回调修改 Doc/stop/restart，commit 返回 accepted=true/stale=true；它保留“真正发出的版本”，不会当作未发送。新请求只有当前 committed text 与 accepted stamp 相同且无未提交 sync 时才允许。stale 的 accepted 状态需再同步或重启，不能重复发送同一 commit。宿主没有可靠原始 delta 时可显式在 worker 调用 `SyncWork.prepareFull`，给 incremental 服务器发送省略 range 的完整内容 change；不是 owner 入口隐式扫描。

SyncWork 保留是显式的：默认最多2个，足够旧 accepted 与候选同时存在；不保留无界版本历史。增量 prepare 必须用 capture 时的 accepted base version/text version，不能拿更老快照把有效 UTF16 range 错发给已前进的服务器。SyncWork.close 是 owner 操作，先结束 worker 使用，关闭 Map/Packet，再 release 自己的 Reader 和 Snapshot。若宿主从 Snapshot 取得的其他合法 Reader 尚未释放，返回 ReadersAlive 并保留 closing 壳、Snapshot 和 Client 同步计数；新 prepare/validate/commit/diagnostics 封闭，原独立 Reader 仍有效。释放这些 Reader 后再次 close 才回收 Snapshot/槽，不重复 release 原 Reader。client stop/restart 对固定 sync 控制槽发 atomic cancellation，不等 worker；准备中在 Reader segment、编辑段及序列化前后协作检查。JSON 编码本身和单次有界 Reader.read 不承诺可抢占。

## 工作区快照与发送事务

workspace 是显式 opt-in。cold 状态 `Client.enableWorkspace(options, limits)` 拥有 root_uri、folders URI/name 和大小写策略的独立不可变快照；普通 Client 不调用它时不分配 workspace 状态或产品。`folders=null` 表示单文件模式，空数组表示已打开但没有目录的工作区。root_uri 单独指定，不按文档或第一个目录猜测。本片 Folder/root URI 限于下面的 file URI 子集；普通文档 URI 仍逐字节匹配，不自动转换，也不强制位于某个根下。

启用后 owner `captureWorkspaceInitialize(handshake)`，worker `WorkspaceWork.prepare(allocator, initialize_options)`，owner validateSend，宿主接受责任后 Work.commit。options 只提供 process_id/snippets；root/folders/能力来自捕获快照，重复提供返回 ConflictingCapabilities。之后沿用 negotiate/adoptInitialize/initialized/commitReady。初始化发送 rootUri、workspaceFolders 和 workspaceFolders=true；configuration 仅在下面的独立 opt-in 启用时声明，不广告 applyEdit、文件监视或其它未接能力。worker 退出后 owner Work.close 才结束快照 pin。初次 enableWorkspace/enableConfiguration 必须在创建 Transport 前完成，保证 worker 不与配置指针的首次发布并发。

服务端 `workspace.workspaceFolders.supported` 和 `changeNotifications` 独立读取；只有支持 folders 且订阅变化时允许 live change，否则 WorkspaceRestartRequired。changeNotifications 接受 bool 或不超过128字节的静态 registration ID，后者按值拥有，不借 JSON。ready `captureWorkspaceChange(full_options)` 生成候选；worker prepare 按 URI/name 差集编码 added/removed。目录重排会形成新本地版本，反向查询返回新顺序。根 URI、null/数组模式和大小写策略没有相应 live wire 表达，修改需 `restart()` → cold `reconfigureWorkspace(options)` → 新 Transport/初始化；候选失败保留原快照，旧产品继续持旧快照。

变更发送使用短线性 scope，不能用普通 Work.commit 代替：

```zig
var send = try work.beginSend();
defer send.end();
// 宿主有界队列作同步接受决定；Full/Closed 时直接返回，原 Packet 不动。
// 接受后可 send.takePacket() 转移 Packet，或让已获准 worker 随后取走。
_ = try send.commit();
```

beginSend 在接受前预检 phase/epoch/基版本/取消、Broker Busy/stopping 及两个 generation 溢出，并持 Client/Broker 两个门。scope 不执行 IO，不等待 worker，不可用于长时操作。拒绝时 end 保留原 workspace、display、取消状态和 Packet，可重试；接受后必须 commit，不能把 end 当作撤回已发送数据。commit 不再有可恢复的 Busy/溢出分支：先发布新 workspace 版本、撤全部 current/stored 并取消旧 Job，再析构旧结果。两个门覆盖全部 foreign free 和最终状态访问；宿主接受回调重入 borrow/stop/close/再变更返回 Busy，scope 结束可重试关闭。scope 必须 owner 线性/LIFO 使用，不复制或跨线程。

版本为不回绕 u64，表示宿主接受发送责任，**不是服务器 ACK**，不向 LSP 通知添加私有 version。旧 queued Delivery/诊断仍须 finish，物理 Job/Reader 仍须释放，但不能发布到新工作区。Broker 的同一失效边界撤 finished stored 结果，Presenter 按既有 invalidation_generation 取消旧 snippet；不修改正文或另建 undo。

协议依据：[工作区查询](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/workspace/workspaceFolders.md)、[文件夹变更](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/workspace/didChangeWorkspaceFolders.md)。

## 显式反向请求

worker `Transport.workspaceRequest(allocator, body)` 返回 WorkspaceIncoming。Message 在 worker 当场释放，跨线程产品仅携带固定容量数字/字符串 ID、method 分类和静态注册信息，不借 Decoder 或 JSON 树。incoming 容量在 parse 前 atomic 预占，解析失败归还。App.post Full/Closed 不消费产品，宿主 join worker 后 owner close。

owner Incoming.capture 绑定当前 accepted 快照和版本，worker prepare，owner validateSend，宿主接受后 commit，最后 owner close。支持 workspace/workspaceFolders 的 null、空和多目录响应。准备期间 workspace 前进则 StaleWorkspace；capture 可撤旧准备并重取快照，保留原请求 ID 后重新 prepare。显式 cancel 后 capture/prepare 可生成同 ID 的 RequestCancelled；编码中取消回收候选，可再 prepare 取消响应。宿主接受后同一对象只能 commit 一次，stop/restart 竞态返回 accepted/stale，不能重复响应。

精确匹配已协商静态 ID 的单项 client/unregisterCapability 可以撤 workspace/didChangeWorkspaceFolders；按协议的 `unregisterations` 字段解析。未知 ID/不支持的混合批次返回 InvalidParams，不静默部分撤销。workspace/configuration 仅在显式启用配置时支持；其它请求（applyEdit、registerCapability 等）返回 MethodNotFound；没有隐式配置 resolver、磁盘扫描或任意动态注册表。宿主需按同一传输的有序队列发送响应/通知；这个小路由器不冒充完整 server-request 分发。

## 显式配置与来源版本

宿主在显式 worker 中调用 `configuration.Prepared.create(allocator, input, preparation)`，拥有 settings_json 及 `(scope_uri, section, value_json)` 表的独立不可变副本；不读取文件、环境变量或编辑器偏好。Prepared 不依赖 Client，可在 worker 完全结束使用后线性移交 owner。allocator context 覆盖最后释放；可选 cancellation 指针覆盖 Prepared.close 或成功移交前的全部操作。JSON 校验/复制、临时树释放后均检查取消，失败不发布半成品。owner `Client.enableConfiguration(&prepared, limits)` 仅在已 enableWorkspace 的 cold 状态采用；失败保持 Prepared，成功清空其所有权。准备与采用可以使用不同线程，不能并发使用或复制后分别 close。

settings_json 与每项 value_json 是一个完整普通 JSON 值。保持原字节和数字 lexeme，不要求 canonical JSON、不通过浮点转写大整数；拒绝重复对象键、多个值、非法 UTF-8、词法 NUL、深度/token 超限。合法字符串中的转义 NUL 作为 JSON 数据保留。scope_uri/section 则必须有效 UTF-8 且无 NUL；scope_uri 非空、至多4096字节，section 至多256字节且允许空串。同一精确 tuple 不可重复，missing section 与空 section 不同，missing scope 与明确 URI 不同。配置键只按字节精确匹配，不用 folderFor、路径前缀、点号拆分、缺省父目录或自动合并来推导设置。

初始化只在此 opt-in 下声明 `workspace.configuration=true` 与 `workspace.didChangeConfiguration.dynamicRegistration=false`。后者说明不实现动态注册，不是静态通知的服务器 ACK。ready 时初始配置版本成为 accepted；本地版本为不回绕 u64，不添加私有字段到 LSP 通知。服务重启保留 desired 配置，撤 accepted/synchronized 来源；cold `reconfigureConfiguration(&prepared)` 可明确替换后重新初始化。workspace 切换不隐式修改配置表；已捕获的配置变更同时绑定 workspace 版本，过时须重新捕获。

ready owner `captureConfigurationChange(&prepared)` 将候选移入 ConfigurationWork；worker prepare 编码真实 `workspace/didChangeConfiguration`，settings 为宿主提供的完整 JSON 值。它复用 WorkspaceState 的产品/控制槽与单一 pending change，不开第二队列。无关正文或选区修改不会使配置通知不可发送。紧邻宿主有界队列接受调用 `work.beginSend()`，与工作区变更相同：拒绝后 end 保留旧配置、显示与 Packet；接受后必须 commit。Client/Broker reservation 覆盖通知版本发布、全部旧结果逻辑撤销及最后 foreign 析构，accepted commit 没有可恢复的 Busy/溢出错误，也不在已接受后重新读取可失败的取消标志。旧 Request/Delivery/DiagnosticDelivery/SyncWork 保留原 config/workspace/epoch stamp，不在收到时补上当前版本。close 仍须显式处理其物理 Reader/槽责任。

接受新配置立即撤销旧诊断来源并返回 `ConfigurationSynchronizationRequired`，直到宿主以**同一 epoch 中更高的 server_version** 捕获、准备并接受新 SyncWork；旧版本 capture 返回 StaleVersion，旧 SyncWork 不能重新授权。即使正文未变化也需要这次显式同步，因为服务器的旧同版本诊断本身没有配置版本，无法安全区分。旧已排队 DiagnosticDelivery 返回 StaleConfiguration，已取消旧 SyncWork 的 diagnostics 返回 Cancelled；新的 accepted SyncWork 才能采用新诊断。此限制是客户端可执行的保守来源合同，不声称服务器对配置通知发出 ACK。

反向 `workspace/configuration` 复用 WorkspaceIncoming 的同一原子 incoming 容量。worker 只复制有界 query keys，owner capture pin 当前 immutable 配置，worker prepare 按 items 原顺序逐项返回，不去重响应。缺少匹配或显式 value_json=null 返回 JSON null；请求中 scopeUri/section 缺省允许、空 section 允许，显式字段 null 返回 InvalidParams。配置前进使旧响应 StaleConfiguration；owner recapture 同一原请求 ID 后可重新 prepare。配置快照与 query 独立拥有，不借 Message/Decoder 树或新配置覆盖旧读者。

prepare 的 ConfigurationCapacityExceeded、OutOfMemory 等先精确返回，保留请求和槽，不自动发送。宿主可明确调用 owner `incoming.reject()` 再 worker prepare 固定 InternalError 响应；不重新领取 incoming 额度，不隐藏原额度错误。reject 在 worker busy 时拒绝，已移出的 Packet 返回 PacketMoved、已 commit 返回 InvalidPhase，不能撤回已接受的字节。Packet 析构持 Client/Incoming 门并在 foreign free 后复核 epoch/phase/cancel。响应仍需 validate/host accept/commit，同一原 ID 仅 commit 一次；这个选择不保证后续分配必定成功。

configuration.Limits 默认 source64KiB、候选 bytes2MiB、64 entries、32 query items、query256KiB、response256KiB、work8MiB、8192 tokens、32层；硬上限1MiB/16MiB/256/64/1MiB/16MiB/64MiB/1048576/64。response 最小2048字节，查询先预扣最坏字符串 ID/envelope 与全部结果，容量失败不部分写输出。bytes 计 stable state、entry 数组、源副本、临时 JSON 树实际同时存活的峰值；source、token、work 在整份 settings+entries 累计。JSON 编码与单次有界解析不承诺可抢占，取消在阶段与 foreign scratch cleanup 后检查。enableConfiguration 另将 current/候选、全部产品/Incoming 可 pin 的旧快照、query 与 metadata 保守加入 Client reservation；采用前独立 Prepared 由宿主自己的预算负责。实际 allocation OOM 与配置限额拒绝分开，不以 reservation 冒充 RSS。

规范依据：[configuration 请求](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/workspace/configuration.md)、[didChangeConfiguration](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/workspace/didChangeConfiguration.md)。不实现任意动态注册、配置文件监视、隐式 section resolver 或 applyEdit。

## 词法 URI 与工作区预算

`file_uri.fromPath(path, .posix/.windows, output)` / toPath 使用调用者缓冲，容量不足不部分写。Windows 明确接受绝对 drive/UNC，POSIX 接受绝对路径；不查当前目录、不猜盘符。UTF-8 非 ASCII 和保留字符按字节百分号编码。拒绝 raw query/fragment、encoded separator、NUL、dot segment、重复分隔、userinfo/port 等歧义或不支持表示。authority 按 ASCII 忽略大小写；路径默认 sensitive，可显式 ascii_insensitive。没有 Unicode case folding、symlink、网络盘映射或真实文件安全边界保证。

Snapshot.folderFor 按解码后的完整路径段选最长祖先，仅供词法路由：`/project-a` 不属于 `/project`，不同 authority 不相交。同策略下等价百分号编码的重复目录拒绝。源 URI/path/name 在整个准备调用及 allocator 回调中保持不可变借用，成功快照自带字符串。

workspace.Limits 默认32目录、每快照64KiB、校验/比较 work1MiB、4个物理 Work、4个 Incoming；硬上限32/1MiB/16MiB/8/16。快照 bytes 计壳、Folder 数组和全部字符串；work 预扣校验扫描、两两去重和差集比较。JSON 编码另外受 body/token/depth 限制，单次编码不承诺可抢占。捕获使用可选 atomic cancellation，Work prepare 使用固定槽取消源，在比较和编码前后协作检查，不发布 partial 产品。

enableWorkspace 在分配前将 State、current/候选、所有 Work/Incoming 可同时 pin 的旧快照、Packet、临时 JSON 与产品 metadata 的保守 reservation 加到 Client Limits.bytes。checked 扣除避免 usize 溢出；默认仍256MiB/hard1GiB。没有预分配这些上界，stats.reservation_bytes 不是 actual/RSS；移走的 Packet、队列/Decoder 另计。close 额外拒 WorkspacesAlive，直至产品 owner close；stop/restart 只封入口，不等待产品或提前复用物理槽。

## 请求、取消与结果

owner `Client.begin(kind, position, fallback_range)` 取得同 Broker 的 Job，不创建第二正文。completion 的 fallback 必须包含请求字节位置；纯 UTF16 Map 转换仍基于该不可变 Job.Reader。worker `Work.prepare` 生成 request Packet/Map。owner `validateSend`，宿主接受队列时 `takePacket`，再 `commitSend`；队列满不 take、不 commit。Packet 新所有者在 IO 责任结束后释放，不能让队列只借 Work 内字节后提前 abort/free。commit 后 Doc 变化返回 stale 并取消逻辑请求，但 **物理固定槽仍被原 Work/Delivery 占用**，直至最终 finish。

worker `receive(transport, allocator, body)` 拒绝错误 transport/epoch、非 response/failure、非数字/错误 ID；不消费 Work，宿主可继续路由或 abort。合法服务错误形成真实 remote_code；当前 Client 不复制错误说明，完整 JSON 错误可在独立 codec.Message 查询。正常响应转换为独立 Broker OwnedResult，关闭 Map/Packet 后 release Job.Reader，形成唯一 Delivery。所有结果字符串和 edit descriptor 脱离 JSON/Reader。`abort(error)` 同样产生需要 owner finish 的 Delivery，不隐式归还槽。

`Delivery.finish()` 在 owner 尝试 publish，然后恰好一次 Broker.finish、清理拒绝结果并归还槽。旧 epoch、取消、Document/selection 变化或 stop 都不复活旧结果。hover/diagnostics 根据 committed text、completion 根据完整 revision 失效；selection-only 变化不会取消有效 hover。成功 finish 表示消费了责任，`Adopt.published`/`rejected` 才表示是否接受结果。公开 stop/restart 不等待已投递任务，也不提前回收槽；所有 queued Delivery 仍要执行/显式处理。

completion 接受数组、null、CompletionList，保留 isIncomplete，按 sortText/label 稳定排序。支持单行 TextEdit、literal insertText/label 和 additionalTextEdits，全部转为原始 byte 坐标；主 edit 要覆盖真实请求位置，附加 edits 按原 Document 规则排序/去重叠。无 textEdit 时使用宿主显式 fallback，不隐式猜词或 fuzzy filter。snippet 的 format2 保留为显式 template edit；Presenter 的 opt-in Session 在接受阶段解析，支持子集与拒绝边界见[片段会话](snippets.md)。

非空 itemDefaults、InsertReplaceEdit、改变 filterText、command、indent-adjust、跨行主 edit 等需要额外行为的结果明确拒绝，不静默丢掉编辑语义。此片不解析 markdown：hover/文档的 MarkupContent/MarkedString 原文显示为普通文字，可合并有界数组。图标 kind、tag、preselect、commit characters 等装饰/接受行为未接 Presenter，不作为本片已完成。data 与未知字段仅在下述显式 resolve 路径独立拥有并原样返回其 JSON 值，不执行扩展行为。

## 显式补全详情 resolve

宿主在 cold 且无 Transport/物理请求时调用一次 `Client.enableCompletionResolve(.{})`，并对当前 Presenter 调用 `enableCompletionRefinement()`。启用配置在 Client 整个寿命不可变，restart 也保留，不能重配置；无 Transport 并不代表旧 worker 已结束，所以物理请求数也必须为0。Work 在 owner capture 时快照原协商 policy/source/epoch，worker 不读可在重启时变化的 capabilities。默认不启用：初始化不广告 resolveSupport，completion 接收仍只用原单份 JSON 树，不复制 raw item、不创建 resolve 队列或后台任务。显式启用只广告 `completionItem.resolveSupport.properties=["detail","documentation"]`；还必须协商到服务器 `completionProvider.resolveProvider=true` 才可发起。缺失/false 返回 UnsupportedMethod，非 boolean 能力返回 InvalidCapabilities。协议依据：[LSP 3.17 completion 与 resolve](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/language/completion.md)。

启用且服务器支持时，worker 在 completion 接收阶段用一份 lossless JSON 树，给每项复制完整原 CompletionItem，包括 data 和未解释字段。保留数字 lexeme，不经 f64 转写大整数；对象空白/字符串转义形式可重新编码，不承诺原帧字节一致。排序时 raw item 与对应项一起移动。中立 `Completion.continuation` 的 source/generation/payload 都由 OwnedResult 深拷贝，普通编辑器不解释这些字节。source 是不回绕 producer 身份，generation 是原服务 epoch，旧服务或其它 Client 的 continuation 返回 ForeignContinuation。

```zig
// owner，已 prepare 当前可见 popup；这里不自动发请求或接受补全。
const choice = try presenter.completionChoice();
var work = try client.beginResolve(worker_allocator, choice);
// 显式 worker：try work.prepare();
// owner：try client.validateSend(work.token);
// 宿主有界队列接受 Packet 后：_ = try client.commitSend(work.token);
// worker：var delivery = try work.receive(&transport, response_body);
// owner，经 App.post 或 join 交接后：
const adopted = try delivery.finish(current_presenter_or_null);
```

beginResolve 在 owner 明确复制一份有界不可变 completion list；不扫描 Document、不创建新 Job/Reader/Map。allocator 必须允许宿主实际采用的线程，并覆盖发布结果最后释放，可能长于 Client/Presenter。resolve 与原请求共用固定 pending 物理槽，Full 不消费原 popup 或 choice。Work 线性移给显式 worker；prepare 只编码真实 `completionItem/resolve`，params 是原完整 item。Packet 仍按 validate→host accept→commitSend 移交。取消只封此 continuation，不撤原补全；实际 `$/cancelRequest` 仍由宿主显式发送。原始 Job 已 finish 不妨碍 resolve，continuation 也不重新占用 Broker Job。

choice 只有值身份，没有可排队的 Presenter 指针：Presenter 唯一 ID、selection/popup generation、原 Ticket/display generation/index。A→B→A、相关键盘/指针/失焦/IME/取消事件、新 popup、Doc 完整 revision、服务失效都拒绝旧 choice。metadata 采用时宿主只在这一 owner 调用借当前 Presenter；Presenter 已撤入口则传 null。短 `CompletionRefinement` scope 保留 Window callback scope、Adapter native-input gate 与 Presenter Busy；原 Window/text token/retained Space 在最终采用前重核，不另存坐标或编辑授权。

响应必须是具有相同 label 的 item。只有所选项 detail/documentation 可改变；省略它们则继承原值。detail 必须字符串，documentation 可为字符串或 plaintext/markdown MarkupContent；显示仍是普通文字。其它已提供字段（含 data、未知字段、edits、snippet tag）必须与原 JSON 同值；未提供的只读字段继承。对象键序不影响比较，数组序和数字 lexeme 严格保持，因此 `1.00` 改成 `1` 也明确拒绝。新增未知字段、改变 readonly 或 command 返回 UnsupportedResolvedProperty；不执行 command，不延迟 additionalTextEdits，不从 resolve 发起第二次接受。Broker 再核整份 typed list 次序及每项 label/edits/insertion/continuation，只有选中项元数据允许不同。

finish 的 Busy 保留完整 Delivery，可显式重试；其它陈旧/关闭/取消/格式失败通过 ResolveAdopt.rejected 消费责任并归还物理槽。App.post Full/Closed 不转移 Delivery，宿主仍须 owner finish（已撤 Presenter 时传 null）。prepare/receive 的失败不隐式 abort；宿主可明确 abort(error) 后 finish。真实 remote failure 保留 remote_code。已经发布后，旧结果析构回调另编辑正文或关闭窗口时返回 `published=true, stale_after_commit=true`，不能重发同一次 resolve。Client/Broker/Presenter 门及原 native-input scope 覆盖发布、最后 foreign free 与最后状态访问；scope 结束可能触发整个 host 的 on_closed，不再访问该 host。

resolve 不改正文、选区或 undo，不自动 prepare/invalidate；发布后宿主显式 prepare 并 invalidate。当前弹层仍绘 label，detail/documentation 通过 Broker 查询，尚无自动详情面板。用户以后接受原 item 时仍由原 Presenter/Session/Adapter 一次原子事务提交，snippet 模板和唯一 undo 合同不变。旧 workspace/config/epoch 结果使用捕获 stamp 拒绝，不在收到时补当前版本。

completion_resolve.Limits 默认 bytes16MiB/source_json2MiB/work16MiB，硬64MiB/16MiB/256MiB。每项 continuation 默认64KiB、硬1MiB，0 可关闭；转换 raw 总量默认256KiB、硬16MiB，另受 conversion/result 总额。enable 在任何产品创建前以 checked 扣除计入每槽 input+candidate 两份结果、源/响应 JSON 两树、Packet、scratch Completion 表、Work/Delivery metadata，并与普通请求取较大 reservation；不足明确 CapacityExceeded，不提高默认限额。原 Broker display、宿主 Packet 队列/Decoder 和其分配器另计，reservation 不是 RSS。work 计源 JSON 扫描上界、readonly 树比较、结果字节复制；有界 JSON 编码/解析本身不可抢占，取消在阶段和全部 foreign scratch free 之后复核。没有 paint 解析、IO、自动 worker 或定时轮询。

## 版本化诊断

worker 仅在已有 accepted SyncWork 上调用 diagnostics。它验证 notification method、URI 和 **服务器实际给出的 version**；缺失 version 返回 UnversionedDiagnostics，不在到达时读取当前 Doc 版本冒充源版本。其他 version 明确 StaleVersion；没有对应已保留 SyncWork 时，宿主丢弃或明确保留自己有预算的版本，不能猜最新地图。

DiagnosticDelivery 独立拥有结果，SyncWork 可以先关闭。owner finish 再核 epoch、accepted server/text stamp 与当前 Doc committed text，才 begin/release/publish/finish 一个诊断 Broker Job。Snapshot OOM/请求 Full 时保留 Delivery，可重试或 discard；discard 不创建 Job。默认最多4个诊断 Delivery，容量在 JSON parse 前 atomic 预占，所有解析失败归还；单个 JSON/转换和结果仍各自受预算限制。

## 显式 shutdown / exit 握手

礼貌关闭是可选的显式控制流程，仍使用同一 Client、Broker、Transport 和宿主 FIFO，不启动线程、进程、时钟或 IO。它须在 App.quit 前完成；App Stop 仍只调用非阻塞 `Client.stop`，不能等待依赖 owner 的回复。规范依据：[shutdown 请求](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_includes/messages/3.17/shutdown.md)、[exit 通知](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_includes/messages/3.17/exit.md)。

```zig
// owner；ready 前返回 NotReady。capture 不改变 ready 或已显示结果。
var work = try client.captureShutdown(.{ .deadline_ns = host_deadline_ns });
// 显式 worker：try work.prepare(worker_allocator);
// 回 owner 后，队列仅在这个短 scope 内决定是否接受：
var send = try work.beginSend(.request, host_now_ns);
defer send.end();
// Full/Closed：不 take、不 commit；end 保留原 Packet/ready/display。
// 接受时：宿主接管 try send.takePacket()；然后立即 try send.commit()。
// commit 返回后才移交 worker，写 FIFO 并路由实际响应：
// var reply = try work.receive(&transport, worker_allocator, response_body);
// owner 经 App.post 或 join：const adopted = try reply.finish();
// adopted.acknowledged 后才 worker 调用 work.prepareExit；owner beginSend(.exit,...)
// 以同一 accept→take→commit 顺序交接 exit，再由 worker 写入、wait/kill。
```

纯 Transport/Packet 编码器只生成字节，不授予发送许可。参与此流程的宿主须把所有控制发送和现有普通产品发送统一到同一 FIFO，禁止绕过 owner 准入直接写纯编码结果。initialize/initialized/cancellation 可用短 `Client.beginControlSend` scope；普通 Request、SyncWork、WorkspaceSend/Incoming 继续使用各自现有验证与接受提交合同。**宿主接受后必须先完成 commit，才允许 IO worker 消费该新产品或产生快速响应**；短 scope 不跨队列等待、阻塞 IO 或事件循环。宿主若以借用 Packet 字节入队，则必须保持其拥有体；takePacket 才显式转移 Packet，移动后的宿主责任独立计费。

request commit 在第一处 foreign free 前进入 awaiting_shutdown、取消全部旧普通逻辑工作并使 Broker stored/current 结果不可见；Client/Broker 门一直覆盖旧结果最后析构。接受后的提交不再检查后来 deadline/cancel，不会把已接受字节误报为未发送。等待期间新普通 request/notification 均被 owner gate 拒绝；已接受的服务器 request 仍可用原有有界 Incoming 池回应。此时保留原 accepted workspace/config 快照，直到 exit commit 或 force stop；没有第二个反向请求池。对端可以收到合法错误响应，客户端仍可回应，不能在关闭中发新的普通取消通知。

worker receive 只接受同 Transport/epoch 的真实数字 ID 响应：result 必须 null，或实际 JSON-RPC error（保留 remote_code）；错误 ID、非 null result、无关消息不消费 Work，宿主仍可路由或明确 abort。Message 的最后 foreign free 及 Work 中残留 Packet 清理后才发布 Reply。只有 owner `ShutdownReply.finish().acknowledged` 才允许 prepareExit；合法 error ack 也允许 exit，`abort(error)` 只产生一次需 finish 的失败责任，绝不伪造确认。exit 无 params，其 accepted commit 仅把 Client 封为 stopped，**不表示子进程已退出或字节已经写完**。实际 write/wait/kill 全由宿主 worker 负责，owner 不等待。

`status(now_ns)` 只读固定物理状态，`expire(now_ns)` 用宿主传入的绝对单调截止时间，未到返回 false；到期调用 force-local stop，宿主再明确终止 IO/进程。没有 sleep、timer、自动重发或轮询源。已接受 exit 后 expire 返回 false。旧 epoch 的 forceStop/到期 expire 返回 StaleEpoch，不能关闭重启后的服务；旧 status 仍可观察旧责任，close 仍能归还它。restart/stop 只发原子取消并封逻辑入口，不等待 worker、UI 任务或提前复用控制。

每个 Client 仅一个独立 control，使用不回绕 serial 与 phase 的完整 atomic CAS；普通 pending 槽满不会占用这个 control。Work 是线性拥有值，所有 worker 访问及收尾须独占，不能复制后并发操作；owner 只通过固定 atomic control 取消、观察和声明队列责任。worker running 时 close 返回 WorkerRunning；待 owner finish 的 Reply 返回 ShutdownReplyPending。App.post Full/Closed 不移交 Reply，宿主仍须 owner finish；成功 post 恰好执行一次。finish 后 Work 仍占 control，直到显式 close；新 capture Full，Client.close 返回 ShutdownAlive。旧 Reply/Packet/Transport 的真实物理责任不因 restart 被代为释放，旧 Work 副本不能 CAS 新 serial。close 失败保留全部责任，可在 worker/queued Reply 退役后重试；所有最后 foreign free 都处于相应 owner/physical 门内。

固定 control metadata 计入 Client 壳；capture 在任何状态发布前 checked 预扣 Work/Reply/Send/ControlSend 值 metadata、至多192字节控制 Packet 和配置 JSON 临时树上限。默认 body16KiB/json128KiB/tokens1024/depth16/work256KiB，硬上限64KiB/4MiB/8192/32/16MiB；工作单位是累计保守 byte visits，request/exit 各预扣512，receive 预扣128+3×body，重试也累计。单次 JSON 编解码不可抢占，取消在阶段边界、encoder 失败清理及全部 Message foreign scratch free 后复核；不能把 work 当 CPU 时间承诺。Work 自有 Packet 与解析临时树的共存进入 reservation；宿主移走的 Packet、Decoder/IO 队列、栈与语言服务器进程另计。没有按额度预分配大块内存，默认未使用关闭流程无新 heap。

## 关闭与预算

`Client.restart` 先预检不回绕 epoch 与 Broker invalidation generation，再撤销全部旧 logical requests、完成后仍 stored 的 displays，进入 cold。旧 Transport/Work/SyncWork/Delivery 保持自己的 epoch 和物理借用。新 epoch 可正常初始化，但仍占用的旧槽不复用。`Client.stop` 立即封新入口，发原子取消并撤销 Broker 结果；不停止普通 Adapter 编辑，不等待 UI 队列，也不杀进程。宿主自己停止 IO/进程、投递或 join worker、处理全部 Delivery、关闭 SyncWork/Transport，最后 close Client，再 close Broker/Document。App.stop 时由宿主显式调用 Client.stop；本模块没有隐式 App resource。

close 拒绝 ShutdownAlive、RequestsAlive、ReadersAlive、DeliveriesAlive、TransportsAlive。所有 owner 析构全程 Busy，直到最后 foreign free 后才撤寿命 pin。不能在 allocator callback 里释放 Client/Broker 或包含 allocator context 的整个 host。`Broker.invalidateAll` 不结束物理 Job；Presenter 在下一 prepare/native/choose/status 观察独立 invalidation generation，取消旧 snippet/Template。无新的正文修改或第二 undo。

默认8请求槽、2同步快照、4诊断 Delivery，硬上限32/8/32；另最多32个 Transport 借用。Client Limits.bytes 默认256MiB、硬1GiB，是 **所有并发产品的保守 reservation 总和**，创建时一次预检，而非真实 OS/进程 RSS。计 Client/槽/URI/语言以及每请求 Map+Packet+JSON候选+conversion、每sync PreparationLimits.bytes、每diagnostic JSON+conversion与值 metadata。没有按reservation预分配这些巨量字节；每个产品按需显式 worker 分配。转换结果限制按 Client 与 Broker 每项取较小值，不能借较大的 Broker 限额绕过服务配额。Document Snapshot/Reader/native与宿主队列/Decoder/Transport值的实际存储分别计，不称本额度覆盖。stats.reservation_bytes 是配置上界，非 actual live/peak。

Sync preparation 默认16MiB retained/candidate预算、16MiB source work、4096 edits；硬256MiB/512MiB/65536。完整准备 source work 预检4×源字节，增量为 old+5×new；这是源读取/比较/校验的保守单位，不包括任意 native/语言引擎成本或 JSON 编码所有 CPU 指令，后者另受 body/token/depth 硬限。旧 accepted Map 与候选 Map、scratch、descriptor、Packet 的共存进入 preparation peak；被宿主移走的 Packet 的队列责任仍需自己界定。query 不做 Zig 堆分配；没有 paint 解析或自动 repaint。

## 验证边界

`zig build test-language-protocol` 覆盖帧全部分片/粘包后缀、非法头/charset、JSON envelope/深度/token/内存、UTF16/CRLF/跨叶、worker移交、cancel/容量、增量原范围/逆序、结果独立拥有、全部分配故障、先发后变 Doc、已排队旧 epoch、新epoch、foreign free 重入和 WrongThread。Broker 另测 finished stored 的显式 invalidation、generation 原子失败与旧 Job迟到。

`zig build smoke-language-protocol` 从构建产物启动真实测试服务器子进程；所有 spawn/pipe IO 由显式 worker执行。隐藏 App 通过真实 App.post 完成两 epoch、UTF16 emoji增量、completion/snippet raw format、hover、versioned诊断、cancel/迟到、queued result stop与资源归零。另以真实256项满队列和Closed投递证明失败保留 Delivery。workspace 场景另启两个服务 epoch：2目录初始化→移除B/增加C→三次 server folders 查询→重启恢复已提交快照；反向请求保留真实 string ID，双方进程校验 Content-Length/JSON 帧。它不下载/启动外部语言工具，也不证明某个生产语言服务器的所有扩展或崩溃恢复政策已支持。旧 `smoke-code-editor` 验证 invalidation 释放活跃 snippet 而不改正文/undo。

workspace 纯测另覆盖 URI/百分号/分段归属、快照全分配故障、null/空模式、能力与静态 ID、反向请求重 capture/取消/容量、旧版本 queued 结果、发送 reservation 的拒绝回滚、接受提交与首次 foreign free 门禁。Broker 单测同源校验 reservation 的 generation 预检、取消无效果和 retained commit。

configuration 纯测覆盖 Prepared 全分配故障、重复键/tuple、原始大整数、exact scope/section、query 顺序、缺省/null、响应/work/item 限额不部分写、编码失败后显式 InternalError、移走 Packet 不可撤销、最后 temporary free 取消与 owner 采用/关闭 Busy 门。真实子进程另跑两个配置 epoch：初次 pull→主动 push→re-pull→更高版本同步→重启保留配置，旧同 server_version 诊断被实际拒绝；额外 quota-query 触发精确容量错误后仅发送一次原 string ID 的 InternalError，服务端检查重复/错 ID/错序即失败。所有 IO/进程/worker 和 App.post 仍是测试宿主显式管理。

`smoke-completion-resolve` 另启真实测试服务器，通过显式 worker/pipe/App.post 验证八次 continuation：大整数 data/未知字段往返、A→B→A/失焦/IME/Doc 陈旧、metadata-only 发布与后续 snippet 接受唯一 undo、只读 edit 变化拒绝、窗口和 Presenter 提前关闭。真实256项满队列与 Closed 不消费结果；Presenter Busy 后原 Delivery 可重试；旧拥有结果首次 foreign free 已见新元数据、Client/Broker/Presenter 均 Busy，回调另编辑得到 published/stale_after_commit。纯测试覆盖所有分配故障、取消不撤原 popup、旧 epoch/workspace/config、严格 readonly/array/数字比较及每个 scratch free 请求取消。此能力没有自动选择触发策略、详情 UI、延迟 edits 或任意服务扩展兼容保证。

`smoke-language-protocol-shutdown` 使用单独构建的真实子进程跑4次完整生命周期：正常 null ack、合法 error ack、服务不回复时显式到期 force kill、Reply 已排队前 owner stop。服务端实际检查 initialize→shutdown 无 params→反向 configuration 请求/响应→ack→exit 无 params 的帧与顺序，收到错误/过早 exit 即失败。反向请求只有原 Configuration Incoming 池，关闭阶段仍能答复；服务端等到这份响应才给 ack，因而不能由假 ack 跳过。另用真实256项满队列及 Closed 检查 ShutdownReply 不转移、slot/Client 在 finish 前仍保留、失败投递绝不执行、所有成功普通任务执行一次。进程 wait/kill 只在显式 worker，join 在 App.run 返回后；隐藏窗口收口核对 resources=0，不建立任何公网或生产语言服务器兼容声明。

shutdown 纯测包含整个流程的全部 allocation failure、无确认前 exit 拒绝、错 ID/non-null 拒绝、接受/拒绝队列责任、ready 前 NotReady、关闭/重启/迟到、旧 Work force 不影响新 epoch、完整 serial CAS、generation/额度失败无发布、普通 pending 满但 control 可用、旧普通响应仅退役责任、首个 foreign free 前结果已逻辑失效、最后 Packet free 双门、JSON 最后 free 取消，以及真实 worker 在 allocator barrier 内时 force stop 不等待且 WorkerRunning 保留物理责任。上述工作量/内存计数属于模块边界，不证明任意外部服务及时退出。

# 可选代码编辑服务

`ziggurat_code_editor` 在同一个 `Document` 和 `document_editor.Adapter` 上组合请求、诊断、悬浮提示与补全；语法高亮、多光标、括号匹配与变更标记见[语法高亮、多光标与变更标记](code-syntax.md)。它不创建第二份文本、选区或 undo，不启动线程，不连接语言服务器。实际分析由宿主实现，可以同步调用，也可以使用宿主自己的 worker 和 `App.post`。

## 请求与交付寿命

`Broker.create(allocator, document, .{})` 创建拥有型稳定地址，保留 Document client。全部 Broker 操作在创建线程执行。默认同时拥有8个请求槽，`Limits.pending` 硬上限32；槽只在 create 时分配，不随历史请求增长。

`begin(kind, byte_position)` 返回线性 `Job`，包括不可变 `Reader`、Ticket、原始请求位置和结果预算。宿主可以把 Job 移交给一个 worker。worker 只读取 Reader、检查 `isCancelled()`、创建 `OwnedResult`、最后调用 `Job.release()`；不访问 Broker、Adapter、Engine 或 UI。Reader 不单独 release，release 后 Job 的查询失效。

worker 释放 Reader 不等于交付结束。每个成功 begin 还必须由 owner 恰好一次调用 `finish(ticket)`，一般放在结果任务的 defer 中；publish 拒绝也要 finish。只有 Reader 已释放才允许 finish。任务已经被 `App.post` 接受时，必须等该任务执行后归还责任；不能因 worker 结束而提前归还。`Broker.close` 在任何这类责任存在时返回 `JobsAlive`，在 Presenter 存活时返回 `ClientsAlive`。

post 返回 `Full` 或 `Closed` 不接管任务或结果。宿主应保留任务上下文、显式 join 自己的 worker，再在 owner 线程释放结果并 finish。没有自动 join、自动 reap、隐藏线程或反复重试。任务上下文和 Broker 都必须覆盖已接受任务的执行期。所有 Ticket/Job 副本只能在这段寿命内使用；它们不能安全引用已经释放的 Broker。

`cancel(ticket)` 与 `stop()` 只撤销业务入口并设置取消标志，不归还仍由 worker/排队任务使用的物理槽。stop 后不能开始请求或发布结果，仍可 finish、释放 Presenter、close。Presenter 自身也进入服务停机门：enable/choose/接受和事件入口拒绝；事件入口或 snippetStatus 会撤活跃 Session/Template；停止后的 prepare 拒绝重建，cancelSnippet/close 仍可完成释放。该门只限制 Presenter，独立 Adapter 的程序化编辑继续有效，不等于关闭通用编辑器。较新同类请求在候选 Snapshot/Reader 成功后取消旧请求；失败的 begin 保持旧请求。仍有效的旧 display 保留到新结果成功发布、显式取消或版本失效。

`publish(ticket, &owned)` 只在成功时移交结果所有权。错误时调用者仍持有完整结果，负责 deinit。它验证 Ticket 代数、取消状态、worker 释放、结果种类、源文本 UTF-8 边界和 Broker 自己的预算。使用较宽预算构造的 worker 结果不能绕过 owner 的限制。重复 publish 被拒绝。

## 版本与结果预算

Document 的 `version()` 包括选择、预编辑和文本变化；`committedTextVersion()` 只在提交文本、restore、undo、redo 时单调增加，选择和临时 IME 文本不改变它，耗尽拒绝文本修改。Snapshot/Reader 保留捕获时的两个版本。

completion 绑定完整 revision 和请求位置，光标/选择/预编辑变化后不能接受旧补全。hover 与 diagnostics 绑定 committedTextVersion，因此移动光标不用重跑全文诊断。IME 组合期间暂时不显示它们，取消后可以恢复；提交后全部旧范围失效。没有猜测 delta 或把旧范围强行应用到新文本。hover 的业务展示范围由宿主请求决定；失焦、取消输入或 Escape 会隐藏当前弹层，新请求可以重新显示。

`observe()` 是显式事件/更新阶段的取消和回收；draw 不做回收。`display(kind)` 是一次 owner 调用中的只读借用，不能跨后续 Broker 修改保存切片。需要跨分配器重入保存借用时使用线性 `borrow()` scope，并在 defer 中 end；期间修改、关闭返回 Busy。停止后的客户端释放可用 `borrowForTeardown()`，它不恢复业务入口。

`OwnedResult.init(allocator, Data, ResultLimits)` 一次深拷贝全部描述符、字符串和附加编辑，拥有分配器必须允许宿主使用的分配/释放线程，并活到结果被 owner 释放之后。结果构造后内容只读，不改写切片或伪造存储。默认单份结果256KiB、128个补全、256条诊断，每个补全最多16项编辑，每段文本最多64KiB。硬上限分别为16MiB、4096、4096、64、1MiB。结果总字节包含全部嵌套描述符和字符串；Broker 自身槽及 Document Snapshot/Reader 另计各自预算。

补全项 `Completion{label,detail,documentation,edits,insertion,continuation}` 的 edits 使用同一原 revision 的字节坐标，必须严格排序、不重叠；重复同点插入和零长度触边歧义明确拒绝。label 非空且最多512 bytes。默认弹层只显示 label；detail/documentation 由宿主查询或显式启用下述纯文字详情。`insertion=.plain` 是默认值，edits.text 中的美元符保持字面文本。显式 `insertion=.{.snippet=index}` 指定唯一模板 edit，其余 edits 仍是字面附加编辑；index 必须落在 edits 内。OwnedResult 深拷贝 tag 和所有原文，Broker 使用同一请求版本/取消规则交付，不在 worker 发布或 draw 中解析模板。可选 continuation 默认 null，是 producer 提供的 `source/generation/payload` 不可变值；编辑器只拥有字节、不解释或调用服务。每项默认64KiB、硬1MiB，含在结果总额，0 禁用。

## 显式补全元数据细化

`enableCompletionRefinement()` 只启用 Presenter 值身份，不分配堆、不自动发请求。宿主从已准备且可见的 popup 取得 `completionChoice()`，它不持 Presenter 指针。选择 A→B→A、失焦/IME/输入取消、新 popup、Doc 完整版本或 Broker 显示 generation 改变后旧值不可用。每次异步返回都由宿主明确借当前 Presenter，关闭后不可复用旧指针。

owner `beginCompletionRefinement(choice)` 建立短线性 scope，`apply(&owned)` 经 Broker.refineCompletion 原子更换一份完整拥有结果。原 Job 可已 finish；不创建 Job、正文、历史或回调。只允许选中项 detail/documentation 改变，所有项的次序、label、edits、insertion、continuation 及其它项元数据必须完全保持。验证或容量/generation 失败保留候选及旧显示；成功清候选所有权并先发布新 generation，后释放旧拥有体。短 scope 持 Presenter Busy 与现有 Adapter native-input/Window pin，覆盖最后 foreign free；end 同实例幂等、owner-only/LIFO，不复制或跨 worker。

`RefinementOutcome.published` 不表示正文插入。旧结果 free 中另编辑 Doc/关闭窗口时仍是已发布，stale_after_commit 明确为 true，不把动作伪装为可重试失败。元数据发布后宿主显式 prepare/invalidate；接受仍独立走原 Adapter/Session 单事务。协议可选桥只支持 detail/documentation，原 data/未知字段与数字保持、物理槽/epoch/配置来源和取消责任见[语言协议](language-protocol.md#显式补全详情-resolve)。普通 Presenter 不启用该身份时没有新的 parse/worker/堆分配。

## 选中补全的纯文字详情

```zig
try presenter.enableCompletionDetails(.{}); // 只保存策略，不分配或请求元数据
try presenter.prepare(bounds, parameters);
window.invalidate();
```

策略启用后，Presenter 从同一 Broker 当前拥有结果取得选中项，把 `detail` 与 `documentation` 用两个换行连接。只有一项非空时直接使用它，两项都为空时不创建 Layout/Prepared。源在显式 prepare 中复制为独立文本快照，借用 Broker 的 scope 覆盖全部候选分配与最后临时源释放；不会在 draw、协议回调或 worker 中创建 UI 资源。文档中的 Markdown 标记按普通文字绘制，不解释链接、图片、HTML 或命令，也不自动请求 resolve。

面板在编辑视口内按右、左、下、上的顺序选择可容纳的矩形，不覆盖补全行。默认宽高上限360×160 DIP、下限96×32 DIP、间隔4 DIP；没有合适区域时不显示详情。它以现有系统 Layout/Prepared 处理换行、混合方向和字体 fallback，覆盖只准备该面板视口并在回放时 clip；超长文本可被视口裁掉，没有隐式滚动或全文详情 UI。IME 预编辑、失焦/取消、过期请求或已隐藏 popup 不显示旧详情。

`CompletionDetailsOptions.text_bytes` 默认16KiB，计入连接用的两个换行；这是容量上限，超限明确返回 CapacityExceeded，不静默截断。系统 Engine 自身的文本/字素/行/活跃 Layout 限额仍独立生效。详情的 Prepared 默认256K pixels/2MiB，DPI 或显式面板增大可能返回 PreparedCapacityExceeded；宿主可在启用时配置容量。每个候选在 `Limits.bytes` 中计入完整旧 View、新详情 Text、临时 UTF-8 源、4MiB Layout 保守 reservation 与显式 Prepared.bytes。它与 Broker 结果、Document/Adapter 的额度分别计算，不宣称原生字体系统内部内存的硬上限。未启用时只增加计入 Presenter/View 大小的固定可空策略和状态字段，没有详情堆、Layout、shaping 或额外回放命令。

同页 Up/Down 先提交一次选中索引，再只准备新详情，保留原行 Prepared。若详情候选 OOM/容量失败，该键已经消费，`lastLayoutError()` 记录错误，旧拥有资源保留；宿主只重试 prepare，不能重发键动作。翻页或其它显示/投影变化仍准备整页。启用详情时，metadata-only refinement 也只更新详情，但仅限 Broker 原子验证所有非元数据内容不变、显示代数精确增加一次且原 Adapter view/projection 仍有效；任意其它显示代数变化走完整准备。未启用详情的 refinement 保留完整 prepare 路径。

详情中的按下序列归详情所有，跨出面板释放也不会落入正文。正文已经接管的拖动会继续收到 move/up，包括进入详情后释放；focus/cancel 先终结 Adapter 序列，再观察可能返回 Busy 的元数据，不留下无按键拖动。没有额外 OS capture 或第二份选择状态。详情 Frame lease 与行资源遵守同一 ResourceInUse/失败帧归还规则；显式启用 Context workspace 时，整帧失败保留已提交 front。App stopping/stopped、Broker stop 或关闭窗口后业务准备/查询/接受拒绝，close/cancel/status 仍可释放资源。已经提交的接受在后续停机或布局失败时保留 committed Outcome，并记录 layout_error，不能重发插入。

本片是有界纯文字面板，没有完整 Markdown、面板滚动、独立可访问性节点或自动语言服务请求。

## 显式 snippet 补全

宿主显式调用 `presenter.enableSnippets(.{ .parse = .{}, .session = .{} })`，Presenter 才创建并拥有一个稳定 Session。默认普通 Presenter 不分配 Session、不解析模板。该策略的 Session metadata 与 Template 拥有/候选预算分别由 policy.session、policy.parse 控制，独立于 Presenter 的布局 reservation；默认成本不按整个进程聚合成一个隐式额度。

```zig
try presenter.enableSnippets(.{});
const item: code.Completion = .{
    .label = "function",
    .insertion = .{ .snippet = 0 },
    .edits = &.{.{ .range = replacement,
        .text = "fn ${1:name}($1) { ${2|first,second|};$0 }" }},
};
```

未启用时接受显式 snippet 返回 SnippetsDisabled，不按字面插入。接受仅发生于更新阶段，Broker.borrow 在全部解析/候选分配期间固定 OwnedResult，Presenter/Session 持原有 Adapter 和 Document。主模板展开、前后附加编辑、最终镜像选择一次提交，一条 undo 恢复全部原文/原选区。模板对象与字符串独立拥有；成功后 Presenter 保留它直到 Session 结束，Broker.observe 可立即释放原补全结果。Session 活跃时其 Template.close 返回 ClientsAlive。同一解析器支持有界嵌套 placeholder；`SnippetPolicy.expansion` 可显式借用宿主 resolver/cancellation，在接受时准备独立变量快照，值不借用原结果。显式 `.session.transforms=.{}` 预留有界 regex/format Runtime，接受时持有编译程序，后续 Tab 在唯一 Doc 事务中变换各自当前位置并选择下一项；默认 null 不分配这个 Runtime，包含 placeholder 变换时明确 TransformsRequired。未知变量自动 placeholder、每 cursor 独立变量环境、完整 JS 正则/Unicode case 等仍明确拒绝，精确语法/工作预算见[snippet 会话](snippets.md#有界-regex-与格式变换)。已有活跃 Session 时接受另一个 snippet 返回 AlreadyActive，不隐式嵌套或替换。

可见 popup 的导航/接受先处理，其余事件交给 Session，再将 false 转发给原 Adapter 一次。后续 text_input 同步镜像，Tab/ShiftTab 导航，Escape 退出；预编辑、失焦、取消输入或完整 revision 变化撤会话。`chooseSnippet(index)` 使用同一事务选择当前 choice，宿主随后 prepare/invalidate；`cancelSnippet()` 只撤元数据与模板。snippetStatus 查询当前会话；Presenter 保持 Session/Template 的唯一关闭权，宿主不得另行释放内部字段指向的对象。

`acceptCompletionOutcome(index)` 返回 edit、committed_revision、实际 revision、stale_after_commit、snippet_active；它只提交，不自动 prepare。旧 acceptCompletion 仍返回 EditResult。外部旧资源 free 中再编辑文档时返回已提交/陈旧，撤销各自仍在唯一 Document 历史中；不得重发原接受。原生事件接受后的布局失败也消费该事件，并记录 lastAcceptance.layout_error / lastLayoutError，宿主显式重试 prepare。后续成功 prepare 清 lastLayoutError；lastAcceptance 保留该次接受的历史结果。提交前的 OOM、语法、旧请求/选区、Window/token/Space 或停止门禁失败不改变本次文本或会话。

## 实际编辑与绘制

模块依赖核心、Document、document_editor、UI、text_layout。只使用 Broker/OwnedResult 不会构造原生 Layout。`Presenter.create(allocator, broker, adapter, engine, window, limits)` 要求 Broker 和 Adapter 指向同一个 Document，并保留两者的关闭引用。Window/App、Engine 和相关 allocator 由宿主保证覆盖 Presenter 生命周期；Engine 没有额外借用 pin，已有 Layout 时自身会拒绝提前关闭。

```zig
const presenter = try code.Presenter.create(allocator, broker, adapter, engine, window, .{});
try presenter.prepare(bounds, parameters); // 显式更新阶段
// UI Context.on_input 内：
return try presenter.handleEvent(event, bounds, parameters);
// UI draw 内：
try presenter.draw(frame, bounds, .{});
```

宿主照常 attach UI Context、bind Adapter，只把同一个输入转发一次。prepare 调用 Adapter.prepare，然后把诊断范围投影为可见下划线、创建提示/补全的系统 Layout 和 Prepared 覆盖。draw 只回放已有资源，不 shaping、不分配、不扫描全文。直接修改 Adapter、滚动、窗口/DPI/字体变化或发布结果后，宿主显式 prepare 并 invalidate。handleEvent 已组合普通输入更新、prepare 和弹层键盘处理；手动 `acceptCompletion` 成功后也要 prepare/invalidate。

可见补全的 Up/Down 改变选择；默认同页移动只更新索引和 invalidate，不重新分配或准备布局。显式详情策略仅重新准备选中项详情，翻页才重新准备最多8行。默认与详情模式的翻页都有同一动作边界：索引一旦改变，随后 prepare 失败也消费该键并记录 lastLayoutError，重试 prepare 不会再改变索引。Enter/Tab 或点击可见行根据显式 insertion 通过 Adapter 原子提交全部正文和附加编辑，只有一份 Document undo。折叠/视口外、没有足够行高、布局陈旧时不会通过键盘接受不可见补全；显式 accept 同样要求当前可见 popup。无弹层的 Escape 交回普通编辑处理。IME 组合拥有输入优先级。

Presenter 默认最多1024个可见诊断矩形、8行补全、每段弹层文本4096 bytes；超限返回明确错误，不静默截断结果。弹层宽度最多360 DIP、高度最多160 DIP（hover）或当前视口能容纳的完整补全行，绘制和命中使用同一缓存矩形，长标签/提示受弹层 clip 限制。尚未组合代码服务的可访问性节点。

`Limits.bytes` 是 Presenter 描述符与布局/覆盖的保守峰值额度：同时计算旧快照和候选，文本每份按 Engine 的4MiB硬界与显式 Prepared.bytes 预留，Engine 原生内部存储另由原生实现承担，不宣称精确测量。默认96MiB，Prepared 默认每份256K pixels/2MiB；`peak_reserved` 是额度预留峰值，不是实际 RSS。Document、Adapter 和 Broker 结果各有自己的预算。

准备失败保留旧拥有资源，但将 Presenter 标记 LayoutRequired，不能把不匹配新文档的图形当成当前帧。补全编辑已经提交后若随后的 prepare 失败，文档动作仍成功；宿主应重试布局，不能重发同一次 Enter/Tab。准备中 allocator 回调改变文档/视口/关闭窗口会拒绝候选。Broker 结果借用在全部外部分配期间 Busy；关闭用 App teardown scope，使 allocator/native 析构中关闭窗口时 on_closed 延后到 Presenter 已完成释放。Frame lease 未释放时 close/prepare 返回 ResourceInUse，失败帧也按既有 UI 事务释放 lease。

Adapter 新增 `rangeRects(revision,range,caller_buffer)`、`positionRect(revision,byte,affinity)`、`viewVersion()` 与 `projectionVersion()`。它们只查询已准备的可见段落，不分配、不 native hit-test、不改变选择。范围边界在字素内部时扩展到完整原生 advance cell；隐藏/屏幕外不返回几何，空范围不产生范围矩形。capacity 用未 clip 的矩形上界预检，失败不写 buffer。组合期间拒绝 committed 范围查询。viewVersion 在每次成功快照发布时变化；projectionVersion 只在可见文本批次/坐标、字体、视口/scale/scroll、文本版本、折叠或 IME 投影改变时提升，纯 selection 几何不变则保留。两者都不回绕。Presenter 据此复用已有诊断矩形与 hover 覆盖，只更新完整 revision/view 门禁，不因选区移动重新扫描全部诊断或构造提示布局。真正投影重建仍为每条诊断扫描涉及的可见布局 Span，成本包含诊断数与可见 Span 数之积，不宣称任意输入 O(1)。

## 验证范围

独立 `zig build test-code-editor` 覆盖拥有结果、窄预算、全部候选分配失败、请求代数、取消不归还物理槽、worker/owner 并发读写和已排队交付寿命。`zig build smoke-code-editor` 使用 Windows 独立且不切换的 desktop child，以及 Linux 隐藏原生窗口、UI Frame 和系统文本布局验证 worker→App.post、诊断和 hover/补全像素、键盘/指针接受与附加编辑一次 undo、选择不丢诊断、IME 隐藏/恢复、不可见补全、无分配同页移动、OOM/失败帧及析构重入关闭。Linux 检查由宿主在隔离 Xvfb 下执行。该检查不建立视觉质量或语言服务器兼容性结论。显式 snippet 补全另覆盖策略/接受全分配故障、模板独立 pin、拥有结果释放后镜像/choice/Tab、IME/stale、提交前后 foreign 编辑、关闭/quit 和提交后布局 OOM。本轮另覆盖父子/外部镜像、resolver 的 literal/unset/empty 规则及重入 close/quit/Doc 编辑/取消、候选完整 OOM、最后 shell free 中 Adapter client 仍保活，以及显式变量变换、compiled 程序脱离补全拥有体、逐位置变换/不同长度镜像输入和唯一 undo。该证据不表示全部 snippet 语法、完整 JS regex 或外部服务兼容已经完成；独立协议边界见[语言协议](language-protocol.md)，语法/成本见[snippet 会话](snippets.md)。

详情的独立检查为 `zig build smoke-completion-details`：Windows 使用不切换的独立 desktop，Linux 使用宿主隔离 Xvfb。它覆盖未启用时无详情分配、同页和翻页 OOM 后选中项只变一次、全部详情候选分配失败、UTF-8 组合与系统混合方向文字、1/1.5/2× 软件像素、显式 refinement 行 Prepared 复用、失败帧保留已提交面板、正文/面板跨界释放、Broker Busy 下 focus/cancel 终结拖动、IME 隐藏、唯一 undo，以及临时源/旧 Layout 最后 free 中编辑/关闭/quit、提交后 stop 的 committed Outcome。检查结束确认系统布局及平台对象归零；不构成视觉质量、完整 Markdown 或详情可访问性验证。

## 显式服务失效

`Broker.invalidateAll()` 用于协议服务重启等不伴随 Document 修改的边界：原子撤销三个 kind 的逻辑 current/stored，递增独立的 `invalidation_generation` 和 display generation。它不永久 stop Broker，也不提前 finish Job；已经 release 的 Reader、已经 finish 后仍拥有的 display、仍在 worker 或成功 App.post 内的旧责任分别处理。generation 溢出或 Busy 在任何撤销/析构前拒绝，foreign result free 全程保持 Broker Busy。

Presenter 的 prepare、原生 handleEvent、chooseSnippet 和 snippetStatus 观察此代数。旧 snippet 会话取消、独立 Template pin 归零后释放；Document 内容和 undo 不变。snippetStatus 因而是 owner 更新入口，可清理退休模板，不能在 paint 中重入它。普通新结果发布、hover/诊断更新不会仅因 display generation 改变而取消正在编辑的 snippet。协议层可按需使用独立[语言协议模块](language-protocol.md)，普通编辑器没有自动服务或 worker 成本。

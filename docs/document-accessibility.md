# 文档可访问性

`ziggurat_document_accessibility` 是可选模块，依赖核心、`ziggurat_document`、`ziggurat_document_editor` 和 UI。基础 UI、Document 和文本布局不反向导入它。原生后端包括 Windows UI Automation，以及 Linux GTK3 的单文档只读 ATK/AT-SPI 首片。

这是完整文档快照与可见几何桥接的第一片。它不把当前视口中的文字片段冒充全文，不接管编辑器的文本、选区、组合或 undo，也不宣称已完成全部文本可访问性协议。

## Linux：单文档只读 ATK/AT-SPI

窗口必须在构造时显式选择 `.accessibility_host = .children`。普通窗口不创建这个 host 或文档 provider。Linux 的 `NativeStorage` 是单值 `enum { glib }`，Options 默认选择它；Windows 保留原来的单值 `enum { system_com }` 和默认值。

```zig
const window = try app.createWindow(.{ .accessibility_host = .children });
const bridge = try access.Bridge.create(allocator, window, &.{.{
    .adapter = adapter,
    .name = "Document",
    .read_only = true,
    .selectable = false,
    .focusable = false,
}}, .{});
try bridge.attachContext(&context);
```

首片要求恰一个上述只读 Source，无 actions/scroll，且不启用 affine、word、presentation epochs/lease 或 auxiliary。这些配置在保留 Adapter 或分配前返回 `UnsupportedCapability`。Context backdrop region、Adapter committed Space、Frame offset/transform 或裁掉部分 viewport 的外层 clip 明确拒绝。单元测试 backend 没有真实 GTK host，会在原生取址边界拒绝，不能用 fake WindowData 模拟运行支持。

复用下文的显式 Reader、`prepareText`、同一 Adapter Prepared、`prepareGeometry` 与成功 front `recordGeometry` 流程。完整逻辑文本的发布与像素几何的成功呈现是两个阶段。已观察到新的提交文本版本时，先撤旧原生可读权限，再做可失败的 Reader/预算/编码准备；缺 Reader、OOM、NUL 或错误 revision 不会留下冒充新版本的旧全文。应用仍须在编辑后显式更新 Bridge，没有隐式文档 observer。未改变的有效版本在候选失败时可以保留。

ATK 文本偏移是 Unicode scalar ordinal，astral scalar 占一个位置，组合符和 ZWJ 的原始 scalar 保留。原生只保存拥有的 UTF-16、scalar/paragraph 表与几何，不保留 Document/Adapter/Reader。`GetText` 覆盖完整文档，保留 CRLF 与末尾 LF；CHAR 返回实际 scalar。U+0000 无法忠实表示为 ATK C 字符串，所以整次 publication 返回 `EmbeddedNul`，不截断或改写 Document。尚未发布、被撤权或已关闭的 character count 是 -1；成功发布的空文档是 0，真实 EOF caret 可有零宽几何。

支持只读 Text/Component 查询、完整文本、CHAR、caret offset 和缓存字符/range/point 几何。字词/句子/段落粒度、legacy boundary 查询、富文本属性、bounded ranges、选择、修改 caret、focus、scroll、EditableText/Action 接口尚未实现；不返回伪造成功动作。scalar 落在同一真实字素内时可共享其缓存 cell，不人为切分宽度。Linux point 从同一 Adapter Prepared 捕获完整原生行、caret stops 与 placement，保留原 ordinary/projected 路由、hidden 最终 snap、同 X 的 bidi 顺序与最近前驱 tie；水平滚动后 clip 外的 stop 仍参与原输入判定。字符/range extents 继续只用可见几何，不从完整命中候选重新授权隐藏内容。

point 查询先检查原 area 与 viewport 半开边界。`.all` 保留该 viewport 查询域，包括原输入已定义的 projected gap 命中；显式 paragraphs 过滤则只授权本次实际导出的可见 line 区域，未绘制行、ghost/gap、空过滤与 `.hidden` 不可命中。完整候选始终不因该过滤裁剪。native packet 同时拥有 revision、text/projection version、geometry generation、scale 与原 bounds/scroll；它与可见几何在同一成功 front 一次提交。查询只读 C-owned 单块数据，调用共享纯 kernel，不调用已退休的 Zig owner、allocator、SDK 或 shaping。没有完整 packet 时 point 不可用，不从可见 caret 表近似回退。本片只接入 Linux；Windows point 仍使用原实现，不代表其同类裁剪风险已修复。

原生几何只由成功 front 发布。失败帧保留仍有效的旧 front；成功但无匹配记录的帧撤几何。同步 native 通知后再次核 Window、Context source generation、Document revision 和 Prepared projection；回调中的编辑、换源和关闭不能让旧尾重新授予可见权限。绘制阶段只交换已拥有引用与标记，不构造文本、布局、GTK 坐标或新几何数组。

坐标缓存来自原 drawing area 的私有 token position 查询，在 attach/显式 `positionChanged`/几何准备阶段更新。单位为 GTK logical pixel，不能再乘 scale。X11 映射时按 flags 提供 WINDOW/SCREEN origin；未映射或当前 Wayland 首片只有 extent/scale，不伪造全局坐标，SCREEN/WINDOW 查询不可用。PARENT 使用原 area 的局部坐标。extent 不代表 showing；仅缓存确认的 origin 与有效几何同时存在时，才保守报告 VISIBLE/SHOWING。隐藏等原生状态变动后，应用应显式更新 position/metadata。ATK 2.52 的公共字符 extent wrapper 会把不可用的 width=-1 规范化为 x=-2/width=1；height 仍为 -1，range 的不可用四字段保持 -1。

文本替换预先拥有旧/新 UTF-8 通知 payload，在原生交换后发送实际 `text-remove::system`/`text-insert::system` 全量替换事件。它们不是编辑 ACK 或最小差异。caret scalar ordinal 真正变化才发送一次 `text-caret-moved`，包括文本变化；不变 metadata 不重复通知。caret 通知前重核 closed 与当前 text/revision/caret，Bridge 返回原生调用后另核 source/Document；先前通知关闭 provider 后不再发送新 live 事件。

所有 GTK/ATK owner 操作及 provider 的引用/释放均限主线程，迟到 ATK 引用可以跨过 Bridge、Document、Adapter 和 App 的销毁，但不能跨线程做 GObject 最后释放。generic host 的 C-only mark 只撤入口，不分配、释放、调用 GTK 或 Zig。Bridge close/detach 直接在 owner 线程撤 token/parent 关系并断开 provider，不使用 App 的 Windows NativeCleanup；在途 C invocation 另持 State pin，同时保留原 Bridge busy、Window callback scope 与 source pin。独立 immutable blob/account 的最后释放可以跨线程，完全不依赖 App 或宿主 allocator。

Linux 复用总字节/全文/cell/caret/line 上界。固定 Bridge 为 824B（x86_64 测量），本次没有新增 Bridge/Options 字段或 NativeCleanup 分配；可选 State/provider 是同一个 176B GObject，Text 固定头64B。Geometry 头因一个可空完整命中指针由112增至120B。成功命中候选在同一 geometry allocation 中追加128B header，以及每 block 24B、native line 16B、stop 16B、placement 32B，另计对齐；不创建逐查询 heap 或 Layout lease。

visible 与完整 hit 两套表各自受 `Options.lines` / `Options.carets` 限额约束，所有实际字节仍共用 `Options.bytes` 账本。完整表可能比可见表大，原来足够导出 extents 的容量不保证完整命中也够；超限整体失败。显式准备新增 host staging 为24个 block、`lines` 个 native line、`carets` 个 stop，projected 另有最多768个 placement；ordinary 不分配 placement 存储。默认上界的额外 staging 请求为328256B，projected 为352832B；这些与旧/新 C-owned candidate、原可见 staging 共同计峰值，不代表每次实际总峰值。默认未启用 DA 不承担该存储，正常 draw 仍只发布已拥有引用。

完整捕获两遍结构遍历为 O(B + L + S + P)，ordinary 的原有 hidden 归一化另计每 stop 的 I，故总成本为 O(B + L + S + P + S × I)。I 包含现 Document index/隐藏末端 grapheme 查询；`caret_work` 计显式操作，不计 tree 节点或 CPU 期限。native 构造只在准备时验证并复制；query 为 ordinary O(B + log L + log S)、projected O(P + log L + log S)，projected 端点 clamp 另可扫描所选 block 的 L 条 native line。

Stats 的 states/providers 是两个角色计数，不能当成两个物理对象；known instance 只计费一次，GObject 不冒充经 fallible block allocator 分配。account、带 header/padding 的自有块和宿主 staging 同账本，已预留但 malloc 失败的峰值仍记 peak。SDK GObject 私有存储/名字/关系/类元数据、AT-SPI transport 与 caller-owned states 不在该账本内。

每次 GetText 两遍转换所请求范围，输出独立 GLib allocation、调用者 `g_free`，单次最坏 `3 * output_units + 1` 字节；不保留第二份 UTF-8 全文，也不承诺所有未释放客户端字符串或进程 RSS 受 retained ledger 限制。全量事件转换是显式 O(old+new units) 准备成本。range limit 不产生本片不存在的 TextRange 对象；原生几何 getter 无分配、无 GTK/Document/shaping，成本受已配置的 cells/lines/carets 上界约束。

Linux 正式目标为 `test-document-accessibility`、`test-document-accessibility-linux-owner`、`smoke-document-accessibility-linux`。独立 `build-document-accessibility-atspi-client` 仅链接客户端依赖，用私有 Xvfb/D-Bus 与真实 server 做外部 AT-SPI 验证；产品不链接客户端，不在 UI 线程同步等待它。自动检查不建立视觉质量结论。可编辑、多源、语言单位、仿射与更完整 Linux 协议仍属 T06 后续工作。

下列 system_com、UIA TextRange、MTA、word 与 auxiliary 章节描述 Windows 后端；Linux 的支持边界以上节为准。

## 所有权与入口

```zig
const bridge = try access.Bridge.create(allocator, window, &.{.{
    .adapter = adapter,
    .name = "Document",
    .changed = .{ .context = host, .call = changed },
}}, .{ .native_storage = .system_com });
try bridge.attachContext(&context);
```

Bridge 拥有稳定地址，不可复制。它在第一次调用宿主 allocator 前保留所有源 Adapter；即使第二个源是未绑定输入的只读文档，分配器重入也不能提前关闭它。Adapter 又持有唯一 Document。App、源 Adapter、宿主 allocator 和已安装的 Context 必须覆盖 Bridge 的寿命。Engine 沿用 Adapter 的显式宿主寿命约定。

`attachContext` 使用 Context 的单个 `AccessibilitySource` 槽，不再次设置 Content。一个源时全文 Document 是该原生根；两个源时是拥有两个 Document 子节点的 group。这个显式根替换不合并原有 widgets 的语义树。Source 的名字在创建时复制，回调 context 借用到解绑及在途回调结束。

Context 在 query、移动通知和绘制阶段通知期间固定入口。clear、替换和 detach 先撤入口，最后一个在途回调返回后才执行一次 `unbound`。Bridge 在解绑时撤销原生 Zig context，随后将 UIA disconnection 放入 App 的 Cleanup 安全点。它不在 `WM_GETOBJECT` 或其他同步原生消息内部调用 `UiaDisconnectProvider`。

`detach` 撤销原生入口并注销停止参与者；Bridge 仍拥有 Adapter 引用、文本镜像和准备中的几何，必须再调用 `close`。`close` 以 App teardown scope 覆盖原生释放、宿主 allocator 和自身释放。重入或在途使用返回 `Busy`，不会释放对象。App 停止参与者只做 detach，宿主仍应在 App 销毁前关闭 Bridge。Context detach 也会撤销入口，因而 `on_closed` 可以关闭 Bridge 并释放宿主上下文。

高级组合宿主可显式传入 `Options.publication`，借用一个稳定的
`document_editor.PresentationLease`，把同帧原生几何与宿主输入权限关联。Bridge 独占
publisher；候选在原生发布前匹配完整 stamp，发布期间先撤旧权限，成功后纯提交。
失败帧保留旧权限，成功但无匹配记录的帧清除权限。该 POD 不拥有 Geometry、文本或
Context；宿主负责其稳定存储，活到 Bridge detach/close 退役 publisher 及所有 reader
返回。默认 null 不创建 lease 对象或新分配；此可选指针增加固定 Options/Bridge 元数据。
可编辑 Diff 应使用其上层 companion 管理此责任，避免两个 publisher 竞争同一权限。

## 完整文本与显式更新

```zig
const snapshot = try document.snapshot();
defer snapshot.close() catch unreachable;
const reader = try snapshot.borrowReader();
defer reader.release() catch unreachable;
try bridge.prepareText(&.{reader});
```

Reader 和 Snapshot 属于调用者，在这次调用期间保持存活。Bridge 不创建隐藏 Snapshot 或 worker。Snapshot 存储仍计入 Document 自己的显式预算。模型可由宿主显式 worker 使用 Reader 构造；当前 Bridge 的原生发布与系统字素分段仍在主线程完成。

`prepareText` 对每个源接收一个可选 Reader。只有提交文本版本变化时才需要 Reader，并按捕获的完整 revision 验证它；缺失时返回 `TextRequired` 并撤下对应的陈旧原生源。未知外部编辑不能靠旧坐标继续提交。

完整镜像保留 UTF-16、scalar 边界、真实段落边界和系统字素边界。NUL、CRLF 和末尾 LF 后的空 caret 段落均保留。它包括折叠、过滤、屏外文字；`GetText` 的全文结果不取自 Prepared 视口。scalar 边界拒绝 surrogate 中间位置。原生 TextRange 只保存源身份、提交文本版本和 UTF-16 范围，不永久保留历史全文。

### 显式 Unicode word 单位

`Options.word_units = true` 在完整文本候选的准备阶段使用现有系统 ICU 的 root locale 词边界及 lexical status。每个词包含其后、下一词开始前的标点与空白；开头的非词 run 单独保留，只有标点/空白的非空文档是一个单位，空文档只有零边界。CJK/Thai 的词典分段由实际安装的系统 ICU 提供，不能等同所有语言或词典版本的统一结果。位置始终是同一 committed Text 的 UTF-16 偏移，选出的边界还须属于已有 scalar/grapheme 边界；组合字符、代理对及 ZWJ 不被本层拆分。

这只实现 Word。Format 未实现独立样式范围，按 UIA 的下一较大受支持单位规则升级到 Word；Line 仍升级到真实 Paragraph，Page 仍升级到 Document。未启用时 Format/Word/Line 沿原合同升级到 Paragraph。Word 的 EOF 扩展取最后一个词，包含末尾 break；Paragraph 的终端 LF 后空 caret 段落仍独立保留。Expand、Move 和 endpoint Move 复用同一有序表，反向移动和文档端点均有界，不读取可见行来猜全文语言边界。

默认不构造词表、不调用词分段、不增加查询分配。显式启用后每个 native Text 候选在原单块存储中追加最多 `scalar_boundaries * 4` 字节，计入原 native ledger 的旧/新候选共同峰值；ICU 的内部临时开销和词典计算沿现有系统分段边界另计。本层准备按单调 cursor 验证 scalar/grapheme 与输出边界，O(scalars + graphemes + ICU segments)，不逐词二分或重复扫描前缀。每次提交文本版本仅准备一次，查询二分 O(log boundaries)、零分配、零 shaping、无宿主回调。失败不发布部分表；旧范围仍按源身份/text_version 校验，关闭后返回 element unavailable，晚引用只持 C-only native 状态，最终释放不依赖 App/Document/ICU iterator。

选区、焦点、启用状态或 composition 变化后显式调用：

```zig
try bridge.updateMetadata();
```

该路径不重建、转换或分配全文；至多处理两个源、每源 64 个选区，UTF-16 坐标复用 Document 索引查询。完整 revision 包含选区和 composition；提交文本版本只随文字提交、undo/redo 等文本发布单调变化。选区移动不会让已有 TextRange 失效，文本变化则会使旧 TextRange 返回 `UIA_E_ELEMENTNOTAVAILABLE`。

composition 期间暴露的仍是完整已提交文档，临时显示文本不是另一份文档。调用者应更新 metadata 并准备空几何；原生修改动作在组合期间明确拒绝。取消组合可重新准备原投影，提交后更新全文和布局。此片没有 TSF 或 `ITextEditProvider`。

## 同一 Prepared 的可见几何

在输入、滚动、布局或 DPI 更新阶段，先准备 Adapter，再准备 provider 的几何：

```zig
_ = try adapter.prepare(bounds, parameters);
try bridge.prepareGeometry(&.{null});
```

`Adapter.preparedGeometry` 只复制已有 Layout 的 advance cells，按原来的 Prepared batch、paragraph placement、scroll 与 clip 映射；无 shaping、native 查询或分配。每个 Layout 的 span 数组按两遍线性遍历，投影 paragraph lookup 为有界二分。一个字素可以有多个 bidi island；这些矩形不是 glyph ink，也不是猜出的字符 advance。

`Adapter.preparedCarets` 另向调用者提供的两个数组复制真实系统 caret stops、affinity 与视觉行，保留零宽 caret 和文档真实的空末行。两遍容量预检失败时不写任一数组；它与 cell 出口核验同一 revision/projection。每个缓存 stop 每遍访问一次，每个视觉行至多进行索引和 paragraph filter 的有界查找，不加载不可见段落。

Bridge 在显式准备阶段将字节范围转为全局 UTF-16 并复制到 native-owned candidate。geometry 预算同时覆盖旧 front、旧 pending、新 candidate 与临时数组。任一源失败时不会替换旧 pending 或 front。

绘制时，在实际提交各源相同 Prepared 内容之后调用：

```zig
try adapter.draw(frame, bounds, colors);
try bridge.recordGeometry(frame);
```

此操作只核验并标记已有候选，不保留 Frame。Context 在每帧 draw 前清除旧标记，只有 backend 成功呈现且输入/坐标快照已经提交，才通知 Bridge 发布几何。失败帧保留旧 front；成功帧漏掉记录、布局 stamp 过期或本帧未绘制对应内容时撤下几何，不猜可见状态。宿主必须保证记录描述的源确实以同样的过滤和 bounds 绘制。

默认只接受 window-DIP identity 几何，拒绝 Frame offset、transform workspace、Adapter 的 committed-space binding，以及不能覆盖完整源 viewport 的外层 clip。需要局部坐标与精确裁剪时，在创建 Bridge 时显式启用 `.affine_geometry = true`。该选项在 paint 外预留两个源的候选映射和原生发布存储，计入同一字节账本；未开启时不创建这些大表。

仿射源的正文、caret 与视觉行仍只准备一份局部 DIP 数据。实际绘制该源的 scope 内调用 `bridge.recordSourceGeometry(frame, source_index)`；所有源都记录到同一个成功帧才整体发布。两个源使用相同 scope 时仍可调用 `recordGeometry`。旋转、缩放、剪切、反射、offset、父级与本地矩形 clip 以及源面/窗口边界都来自 Frame 的同一候选几何，不从外接矩形猜命中。不能导出完整凸裁剪或输出超过 132 个顶点时明确拒绝，不能用近似几何代替。

Frame 的 `coordinateMapping(bounds, &output)` 只复制一个 local bounds 的值型映射，要求已安装的 `AccessibilitySource` 和当前 draw 作用域；没有 native 查询、分配或几何表追加。它保存窄化后的累计 forward/inverse、准确 window-DIP 凸多边形以及 Context/Window/Region/工作区/来源槽与候选帧身份。成功 front hook 用 `checkCommitted` 验证这份候选；源替换、关闭、detach、工作区重建或另一候选均不能复活它。这个值不保活 Context，也不授权业务输入，不可绕开原有 callback pin 当长期坐标句柄使用。

原生发布先完整验证所有来源、矩阵、有限值、逆矩阵和凸多边形，再在同一个短锁内交换 geometry 引用并复制数值映射。MTA 只保留独立 immutable blob，并在锁内复制对应映射，锁外完成 cell 四边形裁剪与 caret 命中。point 查询检查实际多边形和逆变换位置；UIA 的系统 rectangle 输出使用裁剪后多边形的 AABB。零宽 caret 按真实线段判定可见，边界计算仅容忍按实际乘积估计的浮点舍入。没有把 caret 伪装成 glyph，也不通过像素 alpha/透明 mask 推断语义区域。

窗口移动由 Context 的 `window_position` 通知更新缓存屏幕原点，无 shaping、绘制或分配；显式几何准备同时更新 DPI，比例变化先撤旧几何。普通 draw/成功 front 通知不重复查询窗口原点或 DPI。

两个源可分别提供 paragraph filter。过滤值与 `Adapter.drawParagraphs` 一样，是严格递增的真实源 paragraph ID，仅限 projected Adapter。只读 A 的 `GetText` 仍返回完整 A，Bounds、可见范围与矩形只来自实际绘制的 A 段落。B 的 UTF-16 范围从不借给 A。未实现 ghost 的选择/高亮时，A 必须设置 `read_only=true, selectable=false, focusable=false`，不会偷偷改 A 的选区或绑定它的 TextClient。

## 动作、线程与关闭

所有 Bridge、Adapter 和原生 owner 操作都在主线程。UIA MTA getters 只短暂锁住原生 State，保留匹配版本的 immutable blob 后解锁；关闭期间已经取得的 blob 可以完成读取。最后的 blob、range、provider 和 ledger 释放可以发生在 MTA，完全不访问 Bridge、App 或宿主 allocator。

选择、添加/删除选区、焦点和受支持的 scroll 动作通过固定 16 槽原生任务交给 `App.post`，包括在主线程发起的 UIA 请求。满槽、`Full` 或 `Closed` 不接管任务。成功接受后，native task 独立存活到主线程最后的 `finish_action`；Bridge 先关闭或被释放也不会丢失槽位或调用悬挂 context。

主线程执行时再次检查原 Window 代数、源、完整 revision、提交文本版本、composition、enabled 和 modal policy。陈旧任务不改变 Document。选区通过唯一 Adapter 更新，并调用可选 `changed` 通知让宿主显式准备后续布局；回调内 Bridge 是 `Busy`，可准备 Adapter，需更新 Bridge 几何时由宿主显式排队，并保证任务 context 覆盖交付寿命。布局准备失败不回滚已经提交的选区，metadata 仍尝试同步实际选区，错误通过诊断返回。

焦点动作要求该 Adapter 已拥有输入绑定；不会创建另一套 TextClient。`ScrollIntoView` 默认返回 `UIA_E_NOTSUPPORTED`。只有提供了显式 `Source.scroll` 宿主实现，才开放该动作；scroll 回调不得为定位范围暗中改变文档选区。

## 预算与成本

默认 `Options` 为总请求字节 64 MiB、1024 个存活 TextRange、每次输出/全文上限 2 Mi UTF-16 units、16384 个可见 cell、16384 个 caret stops 与 4096 个视觉行。限制均显式可调，range 硬上限 65536，cell 硬上限 16384，caret 硬上限 32768，line 硬上限 4096，总请求字节硬上限 1 GiB。低于固定 owner 存储加 1 KiB 的配置属于 `InvalidLimits`；其余资源上限拒绝返回 `CapacityExceeded`，不伪装成底层 OOM。

`native_storage=.system_com` 表明原生 immutable blobs、State、providers 与 ranges 使用系统 COM allocator，而非宿主 allocator。固定 Bridge/Cleanup 的实际请求尺寸先从总上限预留；剩余额度由独立原生原子账本统一约束 native requested bytes（包含每块内部 header/padding）和显式宿主 staging。MTA 创建 range 与主线程构造 candidate 使用同一个上限。临时宿主分配先原子预留，失败或释放再归还。

`Stats.requested_bytes/peak_reserved_bytes` 包含固定 owner、old+candidate 和临时 staging；它们不是进程 RSS。`resourceCounts` 用于原生账本/块和 charged staging 的最终释放检查，宿主固定对象另由显式 allocator 检查。系统 ICU 内部分段 scratch、UIA/COM 内部缓存及分配器自身元数据不在框架 requested-byte 账本内，不能据此声称整个系统调用峰值硬受限。

返回给 UIA 调用者的 BSTR/SAFEARRAY 由调用者持有并释放，与 retained ledger 分开：GetText 最多 `output_units`，选区最多 64，矩形最多 `4 * 16384` 个 double，可见 range 受 range 限额约束。精确 ordinal `FindText` 有每次 16M 比较工作的上限，超过明确返回 quota；它不是正则或语言搜索。

全文转换、完整 scalar/paragraph 验证与 ICU 字素分段是显式 O(document bytes/units) 准备成本。geometry 只处理已准备视口。正常 draw 只检查 stamp 和记录候选，MTA getters 不读活跃 Zig 文档、不触发 native shaping。仿射原生映射每源 2216 字节，候选与 current 分别计费；每次 getter 使用最多 136 个顶点的有界栈 scratch。凸验证为 O(vertices²)，每个输出 cell 的凸裁剪最坏为 O(vertices²)，point 在可见行和 caret 数量内扫描；这些是显式几何查询成本，不是墙钟期限或 GPU 成本保证。

## 当前边界与验证

可选 `Source.actions` 将 focus/select/scroll 交给拥有展示状态的协调器，context 保持到动作回调返回；普通 Source 保持原行为。`GeometrySelection.hidden` 显式只撤几何而保留全文，不能用空 identity paragraph filter 代替。`Options.presentation_epochs` 默认关闭；开启后 `prepareGeometrySelected` 需要非零候选 epoch，只有成功 front 才在同一原生锁内发布几何与动作 epoch。排队、接管及 owner 执行分别检查身份；没有成功 front 时不接受动作。普通桥仍使用 epoch0，不增加几何 bank 或原生对象。实际成对接线见[可编辑 Diff 辅助功能](document-diff-accessibility.md)，其中显式控件工作区提供实际绘制的 hunk/fold 节点。

`Options.auxiliary` 可显式准备双源桥下的第三个辅助子树，默认不分配 bank。paint 外复制标签、父子关系和完整 tuple key；成功 front 将它与两源几何、epoch 同锁发布，Frame 仅核对实际绘制子树并记录 POD 几何。identity 计划继续用 `recordAuxiliary`；显式 affine 计划还必须借用同一 `publication` lease，并用 `recordAuxiliaryLocal` 提供原始 local bounds，核对同一 pending Snapshot、scope/clip、offset 与正文矩阵。辅助子树只保存一份 common Mapping，按每个 local rect 精确裁剪；它的 visible polygon 可以覆盖正文之外的工具条。

原生 Invoke/ExpandCollapse 使用同一有界动作簿；affine 槽还捕获发布 serial，owner 在入口及校验回调后复验完整 lease stamp/generation，拒绝同 epoch 换 Space 的旧动作。仅显式 `Node.focusable=true` 且配置 `AuxiliaryHandler.focus` 时开放 SetFocus，同样排队到 owner；普通计划默认不支持。`acceptedAuxiliary(frame_id)` 与只读 `acceptedAuxiliaryKey(key)` 只复制成功 front 的完整 key、Frame ID、epoch 与状态，不查 pending 计划。后者允许在保留的 owner focus 回调内读取，不能修改 bank。可编辑 Diff 的 typed revert/fold、成本与单一焦点交接见[差异文档可访问性](document-diff-accessibility.md)。

已实现 Text provider 与全局 TextRange 的全文读取、选区、多范围、可见范围、精确 ordinal 搜索、scalar 安全 endpoints、系统字素 Character movement、native cached rectangles，以及独立来源/版本与关闭寿命。默认 Format/Word/Line 单位按 UIA 规则升级为 Paragraph，Page 升级为 Document；显式 Word 的准备与升级范围见上节。

`RangeFromPoint` 保留同一成功 front 的完整 immutable `PreparedHit`，调用编辑器共用的纯命中内核，返回全局 UTF-16 的退化范围。正文的完整命中表与可见区域权限分开：普通来源接受 viewport 内的点，过滤来源另要求实际可见行的半开区域；ghost、隐藏源和空过滤不扩大权限。仿射查询先验证实际 clip，再以 double 逆变换，最后一次窄化为 f32 交给共用内核。clip 只露出字素中间时，真实 caret 可以位于 clip 外；不为可见片段造位置，不读取活跃 Adapter 或重新 shaping。相同 X、换行、投影间隙、折叠与末尾空行沿用同一 Prepared 的规则。未准备可用几何返回 `UIA_E_NOTSUPPORTED`，陈旧文本或关闭返回 `UIA_E_ELEMENTNOTAVAILABLE`，非有限点或权限区域外点返回 `E_INVALIDARG`；成功的文字点查询返回非空退化范围。

Windows Geometry 同一账本 allocation 保存完整 packet、数组及其精确 Text 引用，绑定 account、来源槽、Text identity 和版本；相同内容/版本的新 Text 不能接管旧 packet。快照和候选的 foreign release 全部完成后，最后一次短锁核对 closed、发布 serial、实际来源、坐标与比例，才交出结果。root 的无命中仍是 `S_OK/NULL`，也经过同一最终有效性检查。它不因没有候选而略过换帧或关闭校验。

Windows x86_64 实测 Geometry 固定头104→112B；Native2912B、Current560B、Text64B保持。完整命中额外拥有头144B（含128B输入），packet80B；每 block24B、line16B、stop16B、placement32B及对齐，与旧/新候选和迟到 Text 引用共同计入原字节上界。没有逐查询重建 packet；UIA Range 的独立有界分配仍保留。未启用文档桥时不承担这些表，正常 draw 只发布已准备的数据。

退化范围的 `GetBoundingRectangles` 按[UIA 契约](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationcore/nf-uiautomationcore-itextrangeprovider-getboundingrectangles)返回空数组；内部真实 caret 位置不伪装成普通字符矩形。完整语言单位、编辑事件、组合语义树及更多平台/完整 Linux 协议仍是后续工作。T06 父项保持未完成。

`TextPattern2.GetCaretRange` 已提供独立的正确类型 vtable，与其他接口共享唯一 `IUnknown` 身份；返回当前主选区 caret 的退化范围，`isActive` 只表达该源是否拥有键盘焦点。临时 composition 和 annotation range 明确不支持。单文档 element 的几何是已提交 viewport；空文档有真实缓存 caret 行时也可被定位。双来源 group 只以各源实际可见行参与 bounds 和命中，过滤掉的 ghost 段落不会扩成覆盖另一源的整窗控件。接口 QI 集合在关闭后保持，方法返回 element unavailable。

没有可见文本时，`GetVisibleRanges` 按[UIA 契约](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationcore/nf-uiautomationcore-itextprovider-getvisibleranges)返回首个可见 Prepared caret 的退化范围；无可见 Prepared caret 时使用主选区 caret，不声称存在可见字符矩形。

正式目标：

```text
zig build test-document-accessibility -Doptimize=ReleaseSafe -j2
zig build smoke-document-accessibility -Doptimize=Debug -j2
zig build smoke-document-accessibility -Doptimize=ReleaseSafe -j2
zig build smoke-document-provider -Doptimize=ReleaseSafe -j2
zig build smoke-document-point-latch -Doptimize=ReleaseSafe -j2
```

隐藏 Win32/GDI 检查包含真实 MTA `CUIAutomation8.ElementFromHandle`、完整 Unicode 文档与选区交接、只读双来源/实际 paragraph 过滤几何、失败帧/移动、全文与几何分配失败、预算拒绝、64 次禁分配选区更新、创建前 Adapter pins、停止参与者、接受的原生槽位跨 close，以及普通/raw 关闭重入后 `on_closed` 释放宿主。独立 ledger/store/provider 测试另外覆盖并发 getter/publish、range 容量、COM identity 与最后 MTA 释放。它们不建立视觉质量结论。

点范围检查将真实 MTA `RangeFromPoint` 与编辑器命中结果逐点比较，包括 Unicode/bidi 行；空文档、末尾 LF、零宽 caret、容量失败双数组不变和严格原生 UTF-16 边界另有正式回归。

完整 Prepared 的原生命中矩阵在 Windows Debug/ReleaseSafe 的 GDI、硬件和 WARP 各比较2073组 owner/MTA点，覆盖普通、投影、过滤、隐藏、折叠与剪切/反射/旋转，硬件路径各有9个实际 GPU front/present。独立最终释放夹具在真实 `CoTaskMemFree` 时发布新 bank 或关闭，正文/辅助节点/无命中六组合均拒绝旧结果；受控移除最终检查时，六组合均稳定触发断言。该 hook 仅在独立测试目标启用，普通原生实现无 hook 分支或存储。自动隐藏窗口检查不建立视觉质量结论。

显式仿射检查对真实 Prepared 的所有 cell 使用独立纯几何 oracle，比对剪切、反射、旋转和分数父 clip 后的原生矩形，并在 MTA 将 point 范围逐点对照 Adapter。双来源分别在不同 scope 记录，漏掉第二来源会整体撤下几何；失败帧保留旧映射，成功但缺记录撤下旧映射。构造失败、预算拒绝、非法原生 mapping、关闭后迟到 COM 和热帧账本稳定也有回归。Linux 的只读原生 provider 与独立外部 AT-SPI 检查见上节；此 Windows 仿射验收不扩大 Linux 首片能力。

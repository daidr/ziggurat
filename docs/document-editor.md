# 大文档编辑桥

`ziggurat_document_editor` 把独立的 `ziggurat_document.Document` 接到系统文本布局、原生文本客户端和 `ui.Frame`。它只为视口附近的完整段落构造布局和绘制快照；文本、选择、预编辑和 undo/redo 仍只存在于同一个 Document。基础 UI 与旧 Editor 不导入本模块。

## 所有权与接线

模块依赖 `ziggurat`、`ziggurat_document`、`ziggurat_ui` 和 `ziggurat_text_layout`。`Adapter.create(allocator, document, engine, limits)` 返回拥有型稳定指针，必须在创建线程调用其全部方法。Document、Engine 及三个对象使用的 allocator 都要活到 Adapter 关闭之后。Adapter 持有 Document 的 client 引用，未绑定窗口时也不能提前关闭 Document；已有缓存 Layout 时 Engine.close 返回 `LayoutsAlive`；没有 Layout 时同样由宿主保证 Engine 覆盖 Adapter 生命周期，Adapter 没有另外持有 Engine borrow pin。

应用在稳定地址持有 Adapter 和 UI Context，并按以下顺序组合：

```zig
const adapter = try editing.Adapter.create(allocator, document, engine, .{});
// bounds 使用 DIP。字体的 wrap != .none 时，布局宽度取 bounds.width。
const parameters: editing.Parameters = .{
    .font = .{ .size = 18, .wrap = .word_character, .width = bounds.width },
    .scale = scale,
};
_ = try adapter.prepare(bounds, parameters);
try context.attach(window);
try adapter.bind(window);
```

`Context.on_input` 是显式更新阶段。宿主更新 bounds、scale 后调用 `adapter.handleEvent(window, event, bounds, parameters)`，并将其 bool 返回值交还 Context。它接收 text_input、preedit、cancel、pointer、wheel、resize 和完整 key_input；若宿主单独接 Content 键盘入口，可调用 `handleKey`。不要同时重复派发同一个输入。

可选的[词与逻辑行选择](document-pointer-selection.md) 使用显式原生多击能力和词索引；
`preparePointerSelection`/`clearPointerSelection` 管理入口，`handlePointerEvent` 区分
选择已提交与其后的展示失败，不允许失败后回落或重放普通 caret。
该入口也可绑定同一个已提交 Space：在相同 scope 内 capture 与 draw，成功后
`setCommittedSpace`，宿主继续转发原始窗口坐标；不要再在宿主预先映射。
pointer、选择/组合、原生 TextClient 和候选 caret 共享该 binding；失败 frame 保旧，
成功缺失 capture 撤权，具体代数与连续性规则见上述文档。

可选的[编辑前输入门](editor-pre-input.md) 在这些默认动作前同步调用宿主，区分明确的
原生 producer、typed key、preedit 和原生 UTF-16 change。Hook 内编辑后旧输入被消费，
不会再执行默认插入；组合撤销与解绑不进入业务 hook。

绘制回调只调用 `try adapter.draw(frame, bounds, colors)`。它提交预备文本、可见选择和组合下划线、caret，不读全文、不创建 Layout、不栅格化，也不从 Adapter allocator 分配。它维护自己的 clip 并把查询/绘制错误写入 Frame；线程和 Busy 校验失败不会跨线程修改 Frame。宿主仍需遵守 Context 的失败帧规则。

resize、DPI、字体、文本、选择或滚动变化都在事件/布局阶段调用 prepare，不能放到 paint。手动 `replace`、`setSelection`、undo/redo 或 scrollBy 后同样显式 prepare、设置原生候选窗 caret 并 invalidate；handleEvent/handleKey 已组合了这些步骤。手动组合时使用 `caretRect(bounds, scale)` 与 `window.setTextCaret`。

Core 在失焦、替换和关闭时撤销 TextClient；Adapter 的 unbound 回调会取消未提交组合并撤销自身 token。宿主在后续焦点回调中按业务策略重新 bind。`bind` 要求至少一次成功 prepare；重复绑定返回 `AlreadyBound`。关闭前显式 unbind；若窗口正在延迟关闭，`UnbindPending` 表示必须等 native unbound 回调结束。Adapter.close 在仍绑定时返回 `ClientAttached`，在 Frame 仍持有绘制 lease 时返回 `ResourceInUse`。输入更新期间重入返回 `Busy`，任何回调栈结束前不能释放 Adapter/context。

## 文档版本与失败语义

Adapter 跟踪 Document.revision，包括选择与预编辑变化。通过 Adapter 修改可以同步维护派生索引；直接从 Document、Snapshot restore 或另一绑定修改后，旧 draw/hit/caret 查询返回 `IndexRequired`，不会猜测丢失的 delta。应用可显式 reindex，或让下一次 prepare 重建索引。外部修改后的重建按旧逻辑行号夹紧视口，行 ID 会重新分配；不承诺恢复未知变化之前的原始段落身份。

元数据候选必须构造成功后才修改 Document。无效 UTF-8、边界、重复代数耗尽、预算或编辑前 OOM 不改变文档、redo 或原索引。Document 修改失败也会释放元数据候选。段落 ID、内容 epoch 和布局 generation 单调递增，耗尽返回 `IdExhausted`。

Document 的 undo/redo 本身不依赖布局分配。Adapter 只保留有限的元数据历史；命中时复用索引根，未命中时仍完成文档的 undo/redo，并返回 `EditResult{ changed = true, index_required = true }`。后续 reindex/prepare 失败不会撤回这个已经提交的文档动作。

布局构造使用候选 index/cache/coverage/selection/视口锚点，成功后一起替换。失败保留原拥有型资源，并把当前视图标为需要 prepare；旧文档版本的图形不能继续绘制。重建外部修改的段落索引是独立可提交阶段：后续 native prepare 失败时，新索引可以已经完成，但视图仍是 `LayoutRequired`。`status()` 区分 index_required、folds_required、layout_required 与 last_layout_error；fold_version 单独标记折叠派生状态，不伪造 Document revision。

原生输入先提交 Document，再显式 prepare。默认路径提交后的布局失败由 handleEvent/handleKey
返回 `LayoutRequired`，具体原因保存在 last_layout_error；此时不能重发同一文字。
显式 pointer 词/行路径改用上述 typed 结果，bool 委托通过诊断报告展示失败。
直接 TextClient change 对已提交动作保留 `applied`，通过诊断报告展示错误；如果已失去
输入权限则返回 `superseded`。应用可缩小预算内视口、调整配置或释放其他资源后重试
prepare。回归覆盖 native 输入已经提交而 Engine allocator OOM 的情形。

Window 在回调返回后仍核验物理客户端身份，关闭或替换可由外层返回
`StaleTextClient`；这不撤销已经提交的 Document 动作，也不是重放原编辑的许可。

需要组合多个 Adapter 的 presentation 时，可显式安装一个
`observeNativeChanges({context,call})` observer，取得 `NativeObserverToken`。
它只通知直接原生 TextClient.change 实际改变的完整 revision，普通 handleEvent 仍由宿主
原来的输入阶段组合。`NativeChange{revision,layout_error}` 包括文档已提交而自身 prepare
失败的情况；observer 同步运行在 Adapter Busy 已退出、Window callback 仍被固定的阶段，
可执行成对 prepare 或标记呈现失效。不启动任务、线程或等到 paint 才处理修改。

Observer 是借用的稳定 context，单槽注册无分配。已有 observer 时注册和 Adapter.close
返回 ObserverAttached。`clearNativeObserver(token)` 只撤该代数入口，陈旧 token 不撤新的
注册；callback 内可以 clear/reinstall，旧通知返回后不写回或再次读取 Adapter/context。
宿主须保证 context 覆盖当前 callback，若要释放自己的 context，应在 callback 最后一步或
由外层 Window on_closed 收口。Token 不能在 Adapter 已释放后使用。Observer 失败不撤销
已提交的文档动作；自身 prepare 错误和 observer 错误分别按权限/展示分类处理，
不能因 observer 成功修复而重复发送文字。

预编辑使用提交索引上的独立 overlay，只复制派生段落元数据。更新、取消、提交和 unbind 先把旧 overlay 锚点映射回提交文档，再映射到新索引；受影响区域夹到首段，未受影响的后续行保留相对位置。组合内容的字节和选择仍由 Document 拥有。提交只产生一次 undo；取消和关闭不把临时组合写入历史。

## 可见布局与输入语义

段落按 LF 分隔，段落字节包含其 LF；CRLF 原样保留为同一 grapheme 边界，最后保留一个可为空的段落。批次不拆段落、grapheme 或 shaping run。缓存以稳定段落 ID、内容 epoch、批次长度与布局 generation 验证，不以全局字节偏移验证，因此前缀插入不会让未修改的后续段落全部重新 shaping。

系统布局决定 grapheme、bidi、wrap、caret 两侧 affinity、hit test 和多矩形 selection；不会用字符等分推算 advance。独立批次开头没有全局 upstream 前文，这个合成边界不会参与命中；段落边界的 upstream caret 查询使用前一段的原生几何。可见查询结果转换回全局文档字节位置。

已有输入包括可见命中与拖动选择、wheel、视觉左右/上下、Home/End、PageUp/PageDown、Shift 选择、按 grapheme 删除、Enter/Tab、Ctrl+A、Ctrl+Z/Y、Ctrl+Home/End、原生预编辑及提交。组合期间普通键优先交给输入法；Alt/Super 与未处理快捷键返回 false。Shift+Tab 和剪贴板 Ctrl+C/X/V 留给宿主。字符通过原生 text_input 到达，完整 key 消费后不会再插入第二次文字。

`revealCaret` 和更新事件会在同一显式 prepare 中测量目标段，并在有界批次内纠正 provisional 高度，直到 caret 真正落入视口。未换行长行同时更新水平滚动；coverage 只准备视口加 16 DIP padding。宽度不足一 DIP 或高度容不下 caret 返回明确的 viewport 错误。scrollBy 单次各轴幅度不超过 1,000,000 DIP，水平总偏移限制为 16,777,216 DIP；垂直位置用段落锚点与局部偏移表示。

字体、wrap 宽度或 Parameters.version 变化使可见批次 generation 失效。仅 scale/滚动变化复用 shaping，重新准备当前视口 coverage；仅选择变化复用 text Layout。`Parameters.estimated_height` 是后续新建或失效段落的高度提示，成功 prepare（包括不绘制新快照的 cache hit）会保存它；它不重写现有准确高度，也不重置尚未访问段落的旧估算。提示必须为正、至多 16,777,216 DIP 且可由 2^-32 DIP 精确表示。

尚未测量或旧 generation 的高度是 provisional，estimated_extent 不是精确全文高度。滚动时显式测量新段落并修正索引；不会在后台遍历全文。当前切片没有滚动条、拖出视口自动滚动、caret 闪烁计时器、语法高亮、剪贴板服务、完整富文本或可访问性文本 provider，也没有超长单段分片 shaping；这些能力需要后续独立实现。

## 完整 Prepared 命中快照

`Adapter.preparedHit(expected_revision, buffers)` 显式复制当前 Prepared 的完整命中数据。`PreparedHitBuffers` 接收调用者拥有、互不重叠的 `HitBlock`、`HitLine`、`HitStop` 和 `HitPlacement` 数组；成功返回只借这些数组的 `PreparedHit`，附带 revision、committed text version、projection version、geometry generation 和 scale。缓冲区须在读取期间保持存活且不可修改；快照不借 Adapter、Document、Engine、Layout 或 allocator，这些 owner 关闭后数据仍可读取。该方法要求同 revision 的有效 Prepared，拒绝 composition、过期或缺失布局；任何失败都不修改任何目标记录。

它与 `preparedGeometry` / `preparedCarets` 的可见几何出口用途不同：完整命中保留当前 Prepared batch 的全部原生行、原始 X caret 顺序、首批次之外合成 upstream 边界的原有省略、ordinary block 路由与 hidden 最终 snap，以及 projected placement 的距离、等距顺序和端点 clamp。X/Y 裁剪或段落过滤不能删掉命中候选；对外协议须另行限定可查询区域。native X 与原 bounds/scroll 分开保存，按原输入顺序先做 f64 重基再窄为 f32，避免提前舍入。普通输入和快照 reader 复用一个私有纯 kernel，输入查询不复制整表或解析全文。

显式捕获不分配、不加载屏外 batch、不调用 shaping。它按每 block 单调 stop cursor 做预检与复制两遍。结构遍历为 O(B + L + S + P)；ordinary 每条 payload 另做原有 hidden 归一化，总捕获成本为 O(B + L + S + P + S × I)，I 包括现 Document index 查询及隐藏末端 grapheme 查询成本。两遍都计入 `Limits.caret_work`；该计数限制显式遍历/复制操作，不是 tree 节点计数或 CPU 时间期限。容量或 work 不足整次失败，不截断。普通视图可以提供空 placements，projected 则必须提供全部 placement 容量。未调用此 API 不增加持久字段、快照分配或绘制工作；原可见几何 API 的过滤和成本保持原义。

## 成本与预算

段落索引是持久 AVL，每个叶最多 32 条记录，分支聚合 byte/row、原始与可见 u128 height ticks、可见行数。高度按 2^-32 DIP 精确 dyadic 值存储，超出精度明确拒绝；先对前缀 ticks 作整数差，再转换视口局部 f64，避免巨大文档前缀吞掉小行高。查找和高度更新为 O(log P + 32)，局部编辑复制树路径和边界 chunk。构造/reindex 流式扫描文档 O(bytes + P)，不 flatten 文本；期间仍有 O(P) 的候选段落记录数组。替换大量段落的分配/回收成本与实际新增/最后释放的节点成正比；旧共享根释放不是固定 O(log P)，递归深度受 AVL 的 64 层上限限制。相邻叶在连接边界能合并时会合并，不保证任意编辑之后每叶都至少半满。

Limits 默认最多 262,144 段（硬上限 1,000,000），拥有字节预算 128 MiB，node 上限 2,097,152；限制分别生效，不保证某个行数必定装入默认字节预算。候选、旧索引、元数据历史、缓存、临时段落记录和预备 coverage 同时计入。Document 的文本树/历史和 Engine 自有资源由各自 allocator/limits 管理，不重复算入 Adapter。

可见批次默认最多 24 个，每批最多 32 完整段落，目标字节 8 KiB；单段最多 64 KiB。单次 prepare 新 shaping 字节默认至多 256 KiB，visual stops/selection rectangles 和 Prepared pixels/bytes 也有显式上限。原生 Engine 的 grapheme/line/live-layout 限额仍独立生效；超过时返回容量错误，不拆开复杂脚本段落来假装成功。

Stats 的 owned_bytes 包含 Adapter 实际 allocator 字节，以及 Layout/Prepared 公开的 owning 字节。reserved_peak_bytes 还包括每次 native 构造前的保守 reservation；native SDK 的内部 cache 和底层 allocator metadata 不可由该账本完整计数。visited_nodes/scanned_rows/reclaimed_nodes 是索引操作的饱和累计计数；shaped_batches/shaped_bytes 包括成功构造但候选稍后失败的工作。Stats 是成本观察，不是另一个文档状态来源。

本机 ReleaseSafe 隐藏原生 fixture 的 100,001 段构造，32 行 chunk 为 8,191 nodes、约 7.06 MB owning 字节（加入折叠双聚合之前的记录）、约 1.23 万次分配。一次 Windows 运行构造 7.57 ms、首部一字节替换为带 LF 文本约 80 us（91 visited nodes、32 scanned rows、12 reclaimed nodes、31 次分配）；首次 prepare 约 8.75 ms，仅 shaping 125 bytes/2 batches。Linux 一次同内容运行构造 5.97 ms，首次 prepare 12.98 ms。这些是该机器单次成本观察，包含 allocator/SDK 冷启动影响，不是性能保证或帧率结论。

## 验证

`zig build test-document-editor` 验证分组索引与线性 LF oracle、跨 chunk 随机持久编辑、精确高度、共享根和逐分配失败回滚。`zig build smoke-document-editor` 运行真实 Win32 或 GTK 隐藏窗口：10 万段只做有界可见 shaping，原生 IMM document feed/GTK surrounding/delete、提交/预编辑/undo、跨段键盘、视口 coverage、Frame replay、无 Adapter 绘制分配、失败帧/关闭 lease 归零。

同一 smoke 还以完整系统 Layout 作差分 oracle，比较复杂脚本、bidi、CRLF、emoji ZWJ、wrap、每个 grapheme 的两侧 caret、hit 与 selection。测试使用明确 Engine/Document/Adapter allocator 故障，区分编辑未提交与编辑已提交但布局失败。关闭时仍有预编辑的用例会验证提交文本未变且全部文本资源归零。隐藏绘制验证不建立视觉质量结论。

## 多选区输入

Adapter 复用 Document 的完整规范化选区与 primary。`setSelections(items, primary)`、`replaceSelections(text)` 和 `replaceMany(expected_revision, edits)` 使用与 [文档事务](document-transactions.md) 相同的规则，不增加另一个文本/选区/undo 权威。Adapter 只缓存各 caret 的视觉 affinity、竖直移动 preferred x 及绘制矩形；这些记录随 observed revision 失效。`caretRects(caller_buffer)` 复制当前可见 caret 标记（selection 下标、primary、rect），原有 caretRect 保留 primary 候选窗用途。

普通文字、Enter、Tab 和预编辑提交对全部规范化选区一次编辑；预编辑只在 primary 临时显示。左右、上下、Home/End、PageUp/PageDown 和 Shift 对各 caret 计算目标，再一次规范化发布；按 grapheme 删除先合并交叠删除范围，再一次提交。跨段竖直移动使用原生段落几何，不用估计高度当成准确 caret advance；触及的布局仍有显式预算。Ctrl+A 和未带 Shift 的 Ctrl+Home/End 收敛为单个范围/目标；Shift+Ctrl+Home/End 保留各 anchor 后规范化。原生单范围文本修改在多选时返回 MultipleSelections。

默认 Adapter.Limits.selections=64（硬上限4096）、batch_edits=4096（硬65536）；选择 scratch 和视觉状态在 create 时显式分配并计入 bytes。所有 caret/selection 的布局与绘制标记在 prepare 中构造，draw 仅回放。不保证所有 caret 能同时出现在一个有限视口；自动 reveal 围绕 primary。

## 派生段落折叠

折叠由宿主提供完整的 `Fold{id,header,end,collapsed}`，位置是当前提交文档的全局 UTF-8 字节。id 必须非0且唯一，header 是完整标题段起点，end 是排除式段起点或文档末尾。标题保持可见，标题之后至少有一个完整 body 段；CRLF 保持原样。定义可嵌套、不可交叉，标题不能重复，嵌套深度最多64。末尾无 LF 的正文段可包含在 end=document.byteLength() 中；有末尾 LF 时同位置的最终空段作为排除端点保留可见。

```zig
try adapter.setFolds(try document.version(), &.{
    .{ .id = 1, .header = header_byte, .end = after_body_byte, .collapsed = true },
});
_ = try adapter.setFoldCollapsed(1, false);
_ = try adapter.prepare(bounds, parameters);
```

setFolds 复制并验证整组定义，expected_revision 包括 selection/preedit；陈旧版本拒绝。setFoldCollapsed 按稳定 ID 查找并事务构造候选。两者在组合期间返回 CompositionActive。折叠后任何当前 caret 落在隐藏 body 时返回 CaretInsideFold，Document 选区和旧折叠不变；非空 selection 可以跨隐藏区域。`folds(caller_buffer)` 复制当前定义。默认最多4096个定义，硬上限65536，拥有记录、候选、排序索引和历史都计入 Adapter bytes。

索引在隐藏范围保留原始高度与可见高度两个聚合，惰性覆盖不逐行清零。只对有效最外层 collapsed 区间的差异修改路径；父节点折叠时子定义仍保留自己的 collapsed 值，展开父节点后恢复子折叠。按 ID 查找为 O(log F)；候选定义验证/排序为 O(F log F + F log P)，单个有效区间的索引覆盖为 O(log P + 32)。切换需要复制/验证有界定义集合，不宣称整个 toggle 为 O(log P)。

正常视口 prepare 从可见高度定位并跳过隐藏范围，不为隐藏 body shaping、测量或 raster。视口批次在隐藏边界断开；可见标题标记在 prepare 缓存为 `FoldHeaderMark{id,collapsed,rect}`，`foldHeaders(caller_buffer)` 复制它们，宿主可用同一几何绘制 gutter 和处理 toggle 输入。draw 不遍历全部定义，也不隐藏命中区域或产生业务状态。标题标记查询只覆盖当前准备的视口，尚未提供语言解析器、折叠图标样式或完整可访问性树。

左右/上下/Page 导航跨过隐藏 body；文档末尾本身隐藏时，普通 End/Right/Down 和指针命中停在最后可见段的原生边缘。Ctrl+End 或手动将 primary 放入隐藏段后，显式 prepare/reveal 会在同一候选中展开其全部祖先；候选失败保持原 fold_version、展开状态和滚动锚点。准备仍失败时旧 view 不会被当作新选择的有效图形。普通可见 prepare 不碰隐藏段；明确的 Delete/Backspace 为确认编辑端点的 grapheme，可以在事件阶段对实际隐藏端点段做一次有界原生 probe，不将其加入可见回放。

通过 Adapter 的已知文本批次映射 fold header/end。修改标题内容（含标题终止符）会保守丢弃该定义；body 改动导致不再满足完整段范围也会丢弃。已知文本编辑先映射全部 F 个定义，再在候选树上清除旧可见覆盖并重建有效区间，额外成本包含 O(F log F + F log P)，不会把它记作只有文本树的 O(log P)；只有 toggle 使用旧/新区间的对称差。映射/候选分配失败先于 Document 提交，旧文本、redo、折叠及索引不变。预编辑有自己的派生 overlay 范围，取消恢复提交定义；临时内容不是另一个 Document 文本来源。

元数据历史同时保留编辑前后 fold 范围。undo/redo 仍先由 Document 非分配提交，派生阶段以历史范围和当前同 ID 的 collapsed 值合并；普通选择落在恢复后的隐藏区域时，后续 reveal 会按正常规则展开。合并需要分配，失败时文档动作已经完成，status.folds_required 为 true，下一次 prepare 可以重试，不能再次发送同一次 undo。元数据 receipt miss 或未知外部 revision 不猜逆 delta：索引重建后返回 FoldIndexRequired，宿主必须以新 revision 提交 setFolds，或用空数组显式清空。

验证包含独立朴素行数组与随机 hide/show/height/splice、嵌套 toggle/edit/undo 差分，全部 fold/index 候选分配失败，10万行隐藏区间的访问计数上限，以及真实 Win32/GTK 隐藏窗口的 pointer toggle、跨隐藏导航、末尾隐藏命中、编辑/undo、composition、OOM/retry 和 Frame 失败/关闭。1万行正文折叠的原生 fixture 首次只 shaping 6 bytes（标题与尾段），证明该输入的可见工作边界，不是任意文档的耗时保证。

## 派生段落投影与成对事务

可选 `ProjectionPlan.create(allocator, document, placements, limits)` 为完整段落
增加前方空白或最小行高。`Placement{line,gap_before,minimum_height}` 必须按原文段号
严格递增；不重排段落，不切开 grapheme/shaping run，不增加文档字节、选区或 undo。
两种高度都向上量化到 1/64 DIP，零表示不附加对应约束；实际文本高仍由系统原生布局
决定，不能以较小 minimum 压缩文字。Plan 持有 Document client，绑定 Document 身份及
committedTextVersion。选择变化不使它失效；正文提交、undo/redo 后即使字节相同也必须
提交新 Plan。`Adapter.setProjection(plan)` 只设置下次 prepare 的派生布局策略；传 null
恢复普通布局。替换或清空时立即退掉旧的派生 Geometry 与 Plan client；旧 Prepared 文本资源
保持自己的独立寿命，但在成功 prepare 前不再作为当前布局使用。Plan 由宿主持有稳定地址，
Adapter 与候选持 client pin，close 遇存活使用者返回 ClientsAlive。

基础段落索引只保存真实原生高度。独立的持久稀疏高度树记录 gap 与超过原生高度的 padding，
不把旧投影字段带入正文 splice/history。折叠隐藏段的附加高也为零，fold generation 变化后
按候选折叠树重建这部分派生数据。投影滚动锚点使用 u128 局部 ticks；先做整数差，再转成
视口附近的 f64/f32，避免 1e12 DIP gap 抹掉段落前 2^-32 DIP 的位置。正常 identity 路径
不构造这棵树或 Placement 数组，也不增加原生查询或 shaping。

投影后的 draw、hitTest、rangeRects、positionRect、caretRect、选区/组合下划线与
TextClient caret 使用同一份显式 prepare 的段落 Placement。空白不参与选择或复制；
命中空白映射到最近的真实段落原生边缘。视觉左右/上下跨过空白，PageUp/PageDown 按
投影高度定位，仍用原生 caret/hit 确认目标。原生段落不因留白而拉伸，coverage 只覆盖
实际可见的源文本部分，draw 重放时逐段裁剪。

只读派生内容可调用 `drawParagraphs(frame,bounds,paragraphs,color)`。它只接收严格递增的
真实源段号（至多768），要求当前投影布局，以一次 Placement 遍历线性匹配这份有界列表，
复用同一 Prepared 与裁剪，不画选区、预编辑或 caret 标记。它不改变输入归属，也不构造
新的文本布局；不支持用虚构段号或 ghost 显示行号代替 Document 段号。无效输入使 Frame
失败，正常的资源 pin/reset 与失败帧命中快照规则保持一致。

`preparePair(window, a, b, bounds[2], parameters[2])` 同步构造两侧布局候选，先核验
全部版本，再执行两次无分配、无原生/用户调用的拥有权交换，最后释放旧资源。两 Adapter
在整个构造、交换和旧资源释放阶段都为 Busy。右侧失败不会先发布左侧。外部未知 Document
修改的 reindex 仍是原有独立阶段；析构回调若再次修改 Document，会把已发布图形标为陈旧，
不会宣称外部业务修改也被回滚。Window scope 覆盖整个成对调用，Planner 内关闭窗口的
on_closed 不能早于候选与 pin 清理。

成对入口只在两次 pure swap 之前返回 error，因而 error 出口不会安装候选 Plan。
成功返回的 `PairResult{sides,current,post_publish_error}` 表示拥有权已经发布。
交换之后释放旧资源会调用宿主 allocator；这些调用若修改 Document 或关闭窗口，仍成功
返回已提交结果，但 `current=false`、`post_publish_error` 按值保留失效原因。宿主必须接收
已安装 Plan 的寿命，即使图形已经失效，也不能释放它或将同一次文档编辑重做。旧资源清理
不会恢复外部业务版本，旧图形在当前版本门禁下不能继续绘制。返回的 current 只描述该次
同步检查点，不代替后续完整 revision/窗口代数门禁。

需要根据两侧实际原生高度规划位置时，使用
`projectPair(window,a,b,bounds,parameters,PairPlanner{context,build})`。
`build(context, probes[2])` 同步借用两个 LayoutProbe；`paragraph(line)` 在原有有界缓存
中准备完整原生段落，返回源字节范围、原生高与终止符信息。两侧 Adapter 此时均 Busy；
Probe 的方法、指针或副本只能在该次 callback 内使用，不能保存至任务或回调结束后。
Planner 返回 `PairProjection{plans[2],scroll_ticks?,anchors?}`。Plan 仍由宿主拥有，必须一直活到
projectPair 退栈，成功时只增加 Adapter client pin，失败不接管其宿主所有权。
`ProjectPairResult` 同样包含 sides/current/post_publish_error，并增加 projection_suspended。
scroll_ticks 使用 2^-32 DIP 整数单位；分别夹到各侧实际末端，若宿主要求相同末端对齐，
须在 Plan 中明确提供对应 padding。另一种互斥方式是 `anchors[2]`，每侧提供
`ProjectionAnchor{line,intra_ticks}`：line 为该侧真实源段号，intra 包含该段前方 gap，单位同为
2^-32 DIP。它不要求两文档全部已测量前缀具有相同绝对高度，适合只对齐当前可见行的协调器。
段号须存在且可见；不会将超大浮点全局坐标相减来猜局部位置。`viewportAnchor()` 复制当前
prepare 的源段锚点，宿主可将输入导致的 reveal 映射回自己的共享显示行。它不是文档选区。

任一侧存在预编辑时，两种成对入口都让两侧临时使用 identity 几何；projectPair 跳过
Planner，并返回 projection_suspended=true。宿主必须在同一输入更新阶段调用成对入口并
隐藏旧比较装饰，不把提交文档的旧 line offset 猜成新预编辑段号。取消后同一 text stamp
的 Plan 可恢复；提交后旧 Plan 失效。原有单 Adapter prepare 只处理该 Adapter 自身的
composition，不能代替成对更新。完整可编辑比较界面仍由上层协调器接线，此 API 本身
不是另一套编辑器。

Plan 默认最多 4096 个稀疏记录与 1 MiB 请求字节，硬上限 65536 条/64 MiB；单个 gap
和 minimum 各至多 1e12 DIP；minimum 是派生 padding 上限，不扩大任何原生段落或 coverage
plane 的限制。派生 Geometry 的旧根、候选、临时记录与
实际节点纳入 Adapter 原有节点/字节预算。设 R 为段落数、P 为稀疏记录数，首次派生构造
为 O(P log R)，单点原生高度修正为 O(log P)，投影前缀为 O(log P)；滚动定位的树遍历
包含 O(log R × log P + 32 log P)，不宣称普通 identity 的 O(log R)。Stats 节点访问与
分配计数包含这部分派生工作，estimated_extent 包含当前有效附加高度。

正式 `test-document-editor` 增加稀疏高度/折叠/大 gap 的独立线性 oracle、跨 chunk 更新、
持久 fork 逐分配 OOM、旧 text stamp 拒绝。正式 `smoke-document-diff-view` 同时验证
成对候选失败回滚、双 Busy、实际原生不等高段落对齐、caret/range/hit 一致、多行预编辑
双侧 identity/cancel 恢复、1e12 gap 保留 2^-32 DIP，以及 Planner 内 close 后 on_closed
释放两 Adapter 和自身 context。隐藏检查不建立视觉质量结论。

## 协调器借用折叠层与最终候选查询

`Adapter.reserveFolds()` 只借用空折叠槽，返回含 Adapter 身份与单调代数的
`FoldToken`。已有定义、composition 或其它借用者会明确拒绝。借用期间普通
`setFolds`/`setFoldCollapsed` 返回 `FoldOwnerConflict`，Adapter.close 返回
`FoldOwnerAttached`。该 slot 与 ProjectionPlan 是两个独立责任，不能互相替代。
token 的 Adapter 必须一直存活；代数检测不使悬挂指针安全。

`setFoldsPair(window,tokens,revisions,definitions)` 构造两组完整段落定义与索引，
核验完整 revision 后纯交换两侧，再释放旧资源。任一候选失败不改两侧 fold_version。
成功的 `FoldPairResult{current,post_publish_error}` 承认已发布责任；旧资源释放时的
外部文档修改/关闭按值报告，不能作为未发布失败来释放已安装所有者。

需要同时发布折叠、视口及派生 Plan 时，使用
`projectPairWithFolds(window,a,b,bounds,parameters,planner,PairFolds)`。
PairFolds 含两 token、完整 revisions 与借用的定义数组，数组活到该次调用返回。
定义、双布局、Plan 和最终候选检查均先完成，再一次发布两侧；待发布的 View.fold_version
与安装后 projected_fold_version 使用同一最终版本。非空定义遇 composition 拒绝；空定义
允许双侧进入 identity。它保留原有 post-publication committed outcome 合同。

`PairPlanner.prepared` 是可选的最终回调，默认 null；两侧 native Layout/Prepared
完成之后、任何拥有权发布之前同步执行。`PreparedProbe` 的 `revision()`、
`projectionVersion()`、`rangeRects()`、`positionRect()` 只读同一候选缓存，复用正式
Adapter 查询的精确 grapheme/bidi/clip 算法，不新增 shaping、native query 或分配。
此回调的容量/几何错误可取消整个候选。两 Adapter 仍 Busy，外层 Window scope 保活；
回调返回后 probes 的方法、指针和副本均不能再用，也不能留给 worker。候选装饰的拥有权
仍由宿主负责，且应在双方成功发布后、释放旧装饰前纯转移；callback 本身不会接管它。

`PairPlanner.validate` 是默认 null 的同步权限检查，不借用几何 probe；所有成对入口，
包括存在/不存在折叠和 composition identity 分支，均在最终候选检查后、双方纯发布前
调用，并再次核验候选。它允许宿主在外部分配或准备回调撤销输入权限后拒绝发布。
这是一个显式可选函数指针的固定存储成本，不在普通成对准备中创建新分配。

`NativeObserver.validate` 可选地为原生 read/change/caret 提供权限代数。Adapter 在
外部工作前捕获，外部工作后与 Document 最终提交前复核；observer 返回后不再读取
可能已关闭的 Adapter。已提交的原生编辑若随后失去权限（含代数耗尽）返回
`superseded`；其它展示错误只报告一次，保留 `applied`，不将已提交编辑变成可重试错误。
`PresentationLease` 只保存 publisher 和成功/候选关联的 POD 代数，不拥有文本、几何
或生存期；其稳定地址必须覆盖 publisher 与所有同步 reader。撤销先清成功入口，
耗尽不回绕。release 即使返回 `IdExhausted` 也已退役 publisher，析构不得因此搁置。

借用派生层期间，隐藏 caret 的 setSelection/setSelections 与视觉动作在修改 Document 前
返回 `CaretInsideFold`；协调器须先以成对事务展开，再用同一 Adapter 选择。正文编辑与
undo/redo 不猜旧派生范围，清除该层可见覆盖并等待协调器重比；composition 临时清除后
仍由同一 Document 的 overlay 提供坐标。普通应用拥有的折叠映射规则保持原合同。

`clearOwnedFolds(token)` 保留 slot、清派生定义；`releaseFolds(token)` 先撤 slot 入口再清，
旧代数返回 false。二者不分配，旧定义/receipt 及时释放；若清除了有效定义，则保留拥有的
正文根但置 `IndexRequired`，下一次显式 prepare/reindex 重建可见聚合。它不在析构中隐式
布局，也不要求应用为了回收而成功分配一次。任何 token、Planner/probe 或回调上下文均须
服从现有 owner 线程、Busy 与 Window/App 生存期规则。

可选 bar/block/underline 与失焦 outline 复用同一系统布局，见[视觉 caret](editor-carets.md)。
它们不改变上述原生、投影、选区及可访问性坐标。

# 索引文档与原生上下文

`ziggurat_document` 提供独立的 owning `Document`、不可变 owning `Snapshot` 与 `ClientBinding`。它适合需要按字节、UTF-16 和 LF 定位的文档；现有 `Editor.buffer` 仍保持自己的实现，应用不会同时维护两份文本真相。可选编辑桥负责分段 shaping 与视图导航；模块也有多选区原子事务及显式 Reader 流式字面查找，见[多选区与搜索](document-transactions.md)。这不包含完整代码编辑器、正则引擎或磁盘映射。

## 创建、修改与释放

```zig
const document = try indexed.Document.create(allocator, std.Thread.getCurrentId(), initial, .{
    .document_bytes = 64 * 1024 * 1024,
    .history_entries = 128,
});
defer document.close() catch unreachable;

const saved = try document.snapshot();
defer saved.close() catch unreachable;
try document.replace(.{ .start = 0, .end = 0 }, "开头\n");
_ = try document.undo();
_ = try document.redo();
try document.restore(saved);
```

示例中的 `indexed` 导入 `ziggurat_document`。模块只依赖核心文本客户端契约，不导入 UI、字体或 renderer。存储层在创建时记录真实 `Thread.Id`，Document/Snapshot 的操作和查询，包括读取、clone 和 close，都检查同一 owner 线程；显式 Snapshot Reader 是下文说明的只读例外，没有隐式线程交接。绑定到原生窗口时 owner 必须是应用主线程。

`Document` 和 `Snapshot` 都是稳定地址的 owning 指针。复制指针不增加所有权；需要第二个快照 owner 时显式 `clone()`。关闭后不能再次使用。快照持有自己的根引用与共享内存账本，可以晚于 Document 关闭；调用者 allocator 必须活到最后一个 owner 关闭。`restore` 仅接受同一个 Document 创建的快照，其他文档返回 `ForeignSnapshot`。快照保存提交文本、完整规范化选区及 primary 和当时的 revision，不保存虚拟 preedit。快照存在活跃 Reader 时 close 返回 `ReadersAlive`。

`replace` 先完整校验与构造候选树，成功后才交换根、清理 redo 和淘汰旧历史。OOM、容量、UTF 边界失败保留文本、选择、revision 和 undo/redo。遥测累计计数可以反映失败尝试。成功的 `replace` 产生一个历史版本，包括调用者主动提交的相同文本；不隐式全文比较。`undo`/`redo` 不分配。`restore` 作为一次可撤销编辑提交，并清除当前虚拟 preedit。

## 坐标与读取

`Position`、`Range`、`Selection` 使用 UTF-8 **字节偏移**，端点必须位于 Unicode scalar 边界。范围是半开区间；选择保留 anchor/caret 方向。模块不会自动将位置吸附到字素、单词或视觉 caret。

- `byteLength`、`scalarLength`、`utf16Length`、`lineCount` 读取聚合计数。
- `utf16Offset(byte)` 与 `byteOffsetFromUtf16(units)` 显式转换。UTF-8 续字节、UTF-16 surrogate pair 中间返回 `InvalidBoundary`，越界返回 `InvalidRange`。
- `line(index)` 返回不含终止 LF 的字节范围，CRLF 的 CR 仍留在范围中；原文不被规范化。最后一个 LF 产生一个额外空行。
- `lineAt(byte)` 计算该位置之前的 LF 数。位于 LF 自身仍属于前一行，紧接 LF 的位置属于后一行。
- `read(range, caller_buffer)` 完整复制指定范围，缓冲不足返回 `CapacityExceeded`，不截断为另一段文本。
- `writeTo(*std.Io.Writer)` 按叶顺序流式输出，不先展平全文。输出期间同一 owner 被标记 Busy，writer 的重入不能释放或替换正在遍历的 owner。

快照提供同样的只读坐标与输出方法。存储允许有效 UTF-8 中的 NUL；原生上下文不能包含 NUL，`nativeContext` 对实际返回片段报告 `EmbeddedNul`。原生绑定的 replace/text 入口也在修改前拒绝 NUL。

## 结构、预算与成本

文档使用持久化 AVL chunk 树。每叶最多 4096 字节，不拆开 scalar；每节点聚合 byte/scalar/UTF-16/LF 计数。替换复制受影响路径与边界叶，并共享不变子树。构造、计数相加与字节预算使用 checked arithmetic。树深度上限 64，节点上限 1,048,576；遍历/释放递归深度受树高限制，不随行数增长。

`Limits` 的默认值及作用：

| 字段 | 默认值 | 限制 |
| --- | --- | --- |
| `document_bytes` | 64 MiB | 当前提交文本与虚拟替换结果，硬上限 1 GiB |
| `nodes` | 131,072 | 当前文本、历史、快照、候选同时存活的全部节点，硬上限 1,048,576 |
| `live_bytes` | 256 MiB | 模块请求的全部存活分配字节，含 owner、索引、历史槽、preedit、快照与候选；不含 allocator 自身元数据 |
| `candidate_bytes` | 32 MiB | 单次 replace 在编辑开始 footprint 之上的最大同时额外字节；初始全文构造只受全局预算限制 |
| `history_entries` | 128 | 固定预分配历史槽，最多 4096；0 禁用历史 |
| `snapshots` | 128 | 同时存活的 snapshot owner 数，clone 也计数，最多 4096；0 禁用 |
| `composition_bytes` | 4096 | 预分配虚拟 preedit UTF-8 缓冲，硬上限 64 KiB |

`stats()` 报告当前/峰值 owned 字节、全部存活节点、快照数、当前树高、累计复制/访问/回收节点及最近编辑候选额外峰值。节点访问不包括一个叶内的 scalar 扫描次数；不能据此推断所有查询耗时相同。

聚合长度查询 O(1)；定位为 O(log N + 叶内扫描)，叶内最多 4096 字节；读取为 O(log N + 输出字节 + 经过的叶)。构造全文为 O(输入字节)，替换候选包含插入内容构造及树路径/边界 chunk 复制。相邻叶仅在 concat 递归实际遇到且总长不超 4096 时合并；**不保证叶至少半满**，长期编辑可能产生碎片，达到 node/live 预算时明确失败，没有后台压缩。

历史/快照让旧 chunk 继续存活。保留根为 O(1)，snapshot/clone 另有一次显式分配；最终 release 需要访问并释放真正不再引用的节点。undo/redo、restore、历史淘汰和 close 的根交换虽然常量，整体操作可能回收整棵旧树，不能称 O(1) 或纯 O(log N)。回收同步发生于 owner 线程；应用必须按文档规模和历史/快照预算安排成本。

revision 是单调 `u64`，选择与虚拟 preedit 更新也使其递增。到达最大值后所有修改返回 `IdExhausted`，不会回绕；只读查询、快照和关闭仍有效。需要继续编辑时显式重建 Document。最大 revision 的 preedit 无法通过 cancel 修改；解绑仍撤销原生入口并释放 lifetime pin，报告取消错误，留下可读取的虚拟状态直到关闭。

## 原生 TextClient

```zig
var binding = indexed.ClientBinding.init(document, app.owner);
binding.changed = .{ .context = &host, .call = Host.updateLayoutAndCandidate };
try binding.bind(window);
// 在 Content.event 中显式调用；键盘导航和绘制由宿主处理。
_ = try binding.handleEvent(window, event);
```

Binding 借用同一个 Document 作为提交文本、选择、preedit 与历史的唯一真相。`handleEvent` 只处理 `.text_input`、`.text_preedit`、`.text_preedit_cancel`，不会自动实现移动、删除键、clipboard、命中、shaping 或绘制。原生查询/修改通过核心 token 代数与焦点寿命检查，遵循[文本输入契约](text-input.md)。虚拟 preedit 更新不改提交根；commit 是一次普通候选事务和一条 undo。preedit 存在时原生 surrounding delete/reconversion 修改返回 `CompositionActive`。多选区时这些单范围修改返回 `MultipleSelections`；普通 text_input 与组合提交则对全部原始规范化选区一次提交。原生上下文与临时组合显示使用 primary。

`nativeContext(caller_buffer)` 复制包含完整选择的有界、scalar 对齐片段，报告全局 UTF-16 起止位置、选择和 revision。即使 caret 在百万字节文档尾部，也通过聚合索引查询全局位置，不扫描全文前缀。选择本身超出缓冲则明确 `CapacityExceeded`，不会把片段长度冒充整个文档坐标。IMM 和 GTK 仍使用各自已有的 4 KiB / 12 KiB 上下文上限。

`changed` 是可选的显式输入/布局回调，成功修改后同步调用，可以立即更新预备布局与候选位置，无需等 paint。回调失败保留已经提交的编辑并向调用者返回错误，宿主负责报告和重试布局。不要在 native read 回调或普通 draw 中构造文档/布局。

绑定期间 `Document.close` 返回 `ClientAttached`。主动 `unbind`、失焦、替换和关闭先撤原生入口，再清理虚拟 preedit 和释放借用。`isClosed` 包含延迟关闭；若关闭尚未到安全点，`unbind` 返回 `UnbindPending`，Binding 和 Document 必须继续存活到实际 unbound/Content.detach 以及全部使用它们的回调返回。Binding 地址在这个过程中保持稳定；它不拥有 Document allocator。

## 验证与边界

`zig build test` 包含坐标/随机编辑/AVL 差分、chunk 边界 emoji/CRLF、历史分支与淘汰、快照晚于 Document 关闭、全部分配失败点、容量、版本耗尽和 owner 线程检查。10 万行用例观测尾部查询/编辑访问与复制上限，属于该固定 fixture 的复杂度回归，不是通用吞吐量承诺。

`zig build smoke-document` 在真实隐藏 Win32/GTK 窗口上加载 10 万行，执行尾部有界文档上下文、原生 reconversion 或 surrounding deletion、提交输入、OOM 后重试与 undo、回调关闭、最终资源回收和仍可读取的 Snapshot。Windows 额外验证旧 revision 的 reconversion 确认不改变当前选择。该检查不等于真实语言引擎、TSF、完整编辑器或视觉质量验证；复杂文本布局仍须显式使用独立 shaping 模块。

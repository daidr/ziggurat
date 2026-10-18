# 多选区事务与流式查找

`ziggurat_document` 在同一个 Document 中持有文本、完整选区、primary、预编辑和历史。多选、批量替换与 worker 搜索不创建第二个文本模型或撤销栈。

## 选择与一次编辑

```zig
_ = try document.setSelections(&.{
    .{ .anchor = 0, .caret = 2 },
    .{ .anchor = 9, .caret = 6 },
}, 1);
try document.replaceSelections("文字");
_ = try document.undo(); // 恢复所有原始文本、选区方向和 primary
```

选区端点仍是 scalar 对齐的 UTF-8 字节位置。setSelections 接受无序输入并按文档顺序规范化：交叠范围、重复 caret、以及接触范围边界的空 caret 合并；两个仅相邻的非空范围保持独立。主选区身份随所在分组合并，合并范围保留该输入的 anchor/caret 方向。合并扩大范围时，不承诺内部原 caret 仍是新的范围端点。selections(caller_buffer) 返回完整复制和规范化后的 primary 下标，容量失败不写输出。selectionCount 是 O(1)。现有 selection() 返回 primary；setSelection 和 replace(range,text) 明确恢复单选语义。

replaceSelections 将每个规范化选区替换为同一字符串，所有结果 caret 同时位于各自插入末尾；删除后重合的 caret 再归并。构造或预算失败保留全部文本、选区、revision 和 redo。一次成功只递增一个 revision、写一条 undo；undo/redo 不分配。

一般批量编辑使用 `Replacement{range,text}` 与 `replaceMany(expected_revision, edits)`。每个范围都基于该 revision 的原始文档，而不是前一个替换的结果。调用者必须按 start 严格递增排序；相同 start、重叠、以及空插入范围接触相邻范围端点都返回 `OverlappingEdits`。非空相邻范围允许。模块不猜测同位置多次插入的拼接顺序。空批次不改变状态，但仍检查 expected_revision。

replaceMany 映射当前所有选区端点。正向范围的 anchor 使用 before、caret 使用 after；反向范围相反；空 caret 使用 after。位于替换内部的端点折到该插入末尾，在原范围 start 的端点按 before/after 选择插入前后。映射后规范化交叠选区，并保留 primary 方向。legacy replace 不使用此映射模式，而是单个插入末尾 caret。

单选以值直接存储，保持普通 setSelection 与单次 replace 的原有分配边界。多选版本是拥有型不可变记录，由 Document、历史和 Snapshot 的 owner 引用共享；全部引用操作与析构仍只在 owner 线程执行。历史淘汰、规范化或最终释放的成本与实际记录和节点成正比。

## 原生文本和预编辑

预编辑只在 primary 临时显示，提交树和全部原始选区版本保持不变。取消保留原选区；commitComposition 对全部原始选区以同一结果一次提交，因此一次 undo 可以完整恢复。预编辑期间不能调用改变选区或普通批量编辑的 API；revision 包含预编辑状态，旧 worker 结果也会失效。

原生 TextClient 上下文只报告 primary，IMM/GTK 单范围 delete、reconversion/select 修改在多选时明确返回 `MultipleSelections`，不暗中丢弃其他选区或重复提交。ClientBinding 的普通文字与 composition commit 使用多选事务。需要原生单范围编辑的宿主先显式恢复单选。原生 changed 回调失败仍保留已经提交的整次编辑；不能重发同一段输入。

## Snapshot Reader

Snapshot 本身继续只在 owner 线程使用。`snapshot.borrowReader()` 在 owner 线程创建一个显式只读租约，然后由宿主交给至多一个 worker。Reader 查询不修改节点引用或共享统计。节点的 counts、分支链接和叶字节在发布后不再改变；快照的 owner 根引用使它们活到最后一个 Reader 释放。worker 不使用 Document allocator，也不析构任何节点。

```zig
const saved = try document.snapshot();
const reader = try saved.borrowReader();
// 宿主显式启动 worker，并交接 reader。
// worker 完成全部查询与 cursor 使用之后：
try reader.release();
// owner 确认工作结束后：
try saved.close();
```

Reader 提供 byte/scalar/UTF16/line 查询、read 与 cursor(range)。Cursor 以借用的连续叶片段返回 `{start,bytes}`，支持跨叶、scalar 对齐范围，不展平全文或分配。端点与 surrogate 中间的拒绝规则与 Document 相同。每次定位走 O(log N) 路径、每叶至多 4096 字节；流式遍历为 O(经过叶数 + 输出字节)。Reader 查询不增加 Document 的 visited_nodes，不能据此把 worker 工作当成零成本。

首次 borrow 为该快照显式分配固定数量槽位；后续槽位复用不分配。每个 Reader 值含槽位与单调 generation，活跃槽位耗尽返回 ReadersFull，代数不回绕。release 先原子撤租，最后以 release 次序减少 active count；owner close 以 acquire 观察到零后才释放槽与根。活跃 Reader 使 Snapshot.close 返回 ReadersAlive，不等待 worker。Document 可以先于 Snapshot/Reader 关闭，但 allocator 必须活到 Snapshot 最终关闭。

Reader 值和 Cursor 复制不会增加租约。宿主必须保证一个租约的所有查询、片段使用和 Cursor 都先结束，再恰好 release 一次。release 后的值失效；在 Snapshot 确定仍存活且未并发关闭时，陈旧 generation 可以被诊断为 ReaderClosed，但这不是悬挂指针保护。Snapshot.close 后所有旧 Reader/ Cursor 方法（包括重复 release）都不能调用。不能让 owner 在已释放的陈旧副本仍被调用时并发释放其槽。

## 有界字面搜索与替换

`document.search.Iterator.init(reader, range, pattern, caller_prefix_scratch, options)` 构造 KMP 流式查询。pattern 为非空、有效 UTF-8，最多 64 KiB；prefix scratch 至少同样数量的 usize，且与 pattern 一起活到查询结束。构造 O(pattern bytes)，不分配。模式 exact 或 ascii_insensitive；后者只折叠 ASCII A-Z，未提供完整 Unicode case folding、正则或语言相关单词语义。

step(max_comparisons) 返回 match、yielded 或 done。预算为实际比较次数，包含 KMP fallback；跨叶还走至多 64 层树路径。调用者控制每次工作量、结果 buffer 和调度，不会因为一个 prefix 退回而在一次 byte 预算下执行整串比较。可选 Cancellation 由调用者持有，通过原子 request 显式取消；检查在每个 step 起始和每 256 次比较处进行。默认结果不交叠，可显式选择 overlapping；重叠结果不能直接提交到严格批量替换。

结果使用全局原始字节范围，并携带 iterator.revision。replaceMatches(document, revision, matches, replacement, caller_edit_buffer) 仅组合 caller edits 并调用 replaceMany，一次提交。结果容量由宿主限制，任何容量或 stale revision 失败都不修改文档。revision 包括选择与 preedit；即使文本相同，也不能把旧结果套到一个不同的选择/组合状态。

worker 搜索使用显式 Reader，完成后 release，再经 App.post 把拥有型结果交给主线程。post 失败仍由 worker 保有上下文；不要在 worker 调 Document、Window 或释放 Snapshot。post 成功后的结果上下文活到任务执行并由应用回收。模块没有隐式线程、结果队列或 UI 等待，也不把全文复制作为搜索前提。

## 预算与验证范围

Document.Limits 新增 selections（默认64，硬4096）、batch_edits（默认4096，硬65536）和 readers_per_snapshot（默认8，硬64；0禁用）。多选规范化 scratch、不可变选择版本、批量候选和快照槽都计入 live_bytes；编辑候选还受 candidate_bytes 限制。排序规范化为 O(S log S)，批量编辑为插入内容构造、受影响树路径及真正回收的成本；端点映射使用批量前缀和二分。Reader 持有旧根会增加保留内存，预算不会因为 worker 忽略而自动释放。

当前纯测试包含随机独立拼接 oracle、选择方向和 primary、一次 undo、旧 revision/重叠拒绝、所有多选/Reader 槽分配失败点、同快照 Reader 与 owner 编辑并发、Document 先关及 worker 只原子释放、跨 chunk KMP/交叠/ASCII/取消/逐比较预算差分。smoke-document 在真实 Win32/GTK 隐藏窗口验证多选输入、OOM 整次回滚、临时预编辑后全部提交、一次撤销、原生单范围拒绝，并由显式 worker 经 App.post 回主线程查找替换和关闭回收。`smoke-document-editor` 另覆盖实际多 caret 几何、按键/原生提交、同一 undo 与派生段落折叠；接线和能力边界见 [大文档编辑桥](document-editor.md)。这些检查不代表语法分析、完整富文本或可访问性文本 provider 已实现。

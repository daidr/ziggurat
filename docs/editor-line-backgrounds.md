# 版本化段落背景

`ziggurat_document_editor.Adapter` 可显式接收同一 Document 的完整段落背景集合。
正文、选区、预编辑与 undo 仍由 Document 唯一拥有；背景只是宿主计算的派生元数据。

```zig
const stamp = try document.committedTextVersion();
const installed = try adapter.setLineBackgrounds(stamp, &.{
    .{ .paragraph = (try document.line(2)).start, .color = 0xf0e8d0 },
});
if (!installed.current) {
    // 宿主重新读取当前正文并重新计算完整集合。
}
_ = try adapter.prepare(bounds, parameters);
// paint 中仍只调用 adapter.draw(frame, bounds, colors)。
```

`LineBackground.paragraph` 是当前**提交正文的全局 UTF-8 字节起点**，不是行号、
UTF-16 位置或视觉行号。Adapter 用 Document 的 LF 行索引核验真实段落起点；
CRLF 保留原样，终止 LF 后的最终空段也是有效段落。集合按起点严格递增，
每段最多一项，`color` 为 24 位 RGB。定义在方法返回前借用，成功后由 Adapter
拥有副本。空集合显式清除旧背景；默认没有定义时不分配定义或背景几何数组。

版本使用 `Document.committedTextVersion()`。只改选择不撤销背景；替换、restore、
undo/redo 即使恢复相同字节也产生新 stamp。陈旧提交返回 `StaleRevision`，不改变
既有集合。已有集合在正文改变后保留拥有权但不再产生绘制几何，
`status().line_backgrounds_required` 为 true，宿主必须提交新版本或显式清空。
Adapter 不猜测编辑后的行身份，也不将旧颜色自动移给相邻行。

预编辑有独立临时坐标。组合活跃时设置返回 `CompositionActive`，prepare 暂时抑制
全部已提交背景；取消组合后相同提交 stamp 的集合恢复，组合提交则按普通正文编辑
失效。该选择不会建立另一份组合文本或选区。

背景覆盖一个逻辑段的全部真实换行高度和当前视口宽度，随后受视口 clip 约束，
先于 selection、block caret 和文本绘制。折叠隐藏的段落没有背景。显式 projection
沿用该 Adapter 已准备的段落位置，背景只覆盖原生文本高度，不填充对齐 gap 或
`minimum_height` 额外留白。背景没有命中区域，也不会修改原生 TextClient/caret
或辅助技术中的插入位置。

`preparedLineBackgrounds(bounds, caller_buffer)` 复制当前可见的
`LineBackgroundMark{paragraph,color,rect}`。rect 使用与 Adapter.draw 相同的布局 DIP：
普通窗口接线为窗口 DIP，显式 Space 接线为其本地 DIP。它不返回隐藏段、过期集合
或组合中的虚构坐标。Buffer 不足返回 `BufferTooSmall`，需要当前成功 prepare。

定义默认最多 4096 项、硬上限 65536，可由 `Limits.line_backgrounds=0` 禁用。
定义副本、并存旧/新副本及可见几何都计入现有 Adapter bytes；可见矩形同时受
`Limits.rectangles` 限制。设置验证为 O(B log L)，其中 Document 的行查找使用既有
索引；prepare 在至多 24×32 个已准备段落中二分定义，O(V log B)，不扫描全文或
全部历史行。仅变更背景复用已有 shaping 和 Prepared 文本。draw 只遍历可见缓存，
不分配、不整形，也不在 paint 根据正文重算样式。

发布先交换完整定义拥有权，再释放旧副本。调用者 allocator 的 free 回调若改变
Document，方法成功返回 `LineBackgroundResult{current=false}`，不能将已发布结果
误报为尚未提交的错误。prepare 继续使用完整候选发布及最后 foreign free 后的
revision 复核；失败候选不发布一半几何。宿主不能因呈现失败重复业务编辑。

`zig build smoke-editor-line-backgrounds` 运行真实系统布局和隐藏原生窗口，核验
UTF-8/LF 段落、CRLF、复杂脚本、软换行、空行/EOF、三个 scale、projection、fold、
composition、选择/undo stamp、逐分配失败、发布前/后 allocator 重入及无 Adapter
绘制分配。它验证绘制命令和布局几何，不代替视觉质量或完整编辑控件验收。

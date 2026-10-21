# 版本化正文区间标记

DocumentEditor 的 `setRangeMarkers(expected_text_version, definitions)` 替换完整的
paint-only 标记集合。`RangeMarker.range` 是唯一 Document 的 committed UTF-8
半开字节范围；版本来自 `Document.committedTextVersion()`。Adapter 不拥有第二份
正文、选区或 undo，也不为编辑后的范围猜测新归属。

每项包含 `range`、`kind`（`background`、`underline` 或 `foreground`）、24 位 RGB `color` 和
`thickness`。范围必须非空，端点必须是有效 UTF-8 边界，不能超出文档。字素内部的
合法 UTF-8 边界按已有范围几何规则扩展到完整系统 advance cell。集合按 start 非递减；
允许相交、嵌套、重复范围与相同起点，保留调用者次序。定义借用至方法返回，成功后
Adapter 独立拥有副本和 prefix-max-end 索引。空集合显式清空；默认及空集合不建索引。

`underline` 是 **selection-cell 底边装饰**，不是字体 underline metrics，也不表示
glyph ink。厚度是布局 DIP，必须有限且在 `(0,16]`，实际不超过 cell 高度。
背景忽略厚度，但所有定义仍验证该字段。先从未裁剪 cell 的底边计算装饰，再裁剪；
滚动只显示 cell 上半部时不会在视口边缘制造新的下划线。

`foreground` 把范围内的正文改用 `color` 绘制，供语法高亮使用。prepare 为每个含
前景标记的可见 run 生成文字裁剪区：标记矩形取标记颜色，其余部分按矩形边缘切成
水平条带取正文颜色；draw 对每个裁剪区回放一次同一份 Prepared 文本，不重新 shape、
不分配。重叠的前景范围会让同一段文字绘制多次，调用者应保证每个字节至多属于一个
前景标记。裁剪区数量受 `Limits.rectangles` 的 4 倍约束，超出返回
`RectangleCapacityExceeded`。

绘制次序为段落背景、区间背景、selection、block caret、正文、区间下划线、
composition、其余 caret。每个可见 run 内同层按定义次序覆盖；不同 run 受各自 clip
约束。隐藏折叠、屏外正文和投影 gap/minimum-height 留白不产生标记。几何来自与
`rangeRects`、CodeEditor diagnostics 相同的 RunIterator、字素 snap、原 Layout 的
selection rects 和投影 clip；不按相邻行或矩形位置猜源范围。

只改选择保留集合；替换、restore、undo/redo 即使恢复相同字节也使旧集合过期。
`status().range_markers_required` 表示宿主需要提交新版本或显式清空。陈旧集合继续
拥有存储，但 prepare 不产生其几何。活跃 composition 有独立临时坐标，设置返回
`CompositionActive`，prepare 暂时抑制全部标记；取消可恢复同一 committed stamp，
提交后按普通正文变更失效。

每次成功 set/clear 前进独立、不会回绕的 metadata version。返回
`RangeMarkerResult{version,current}`；成功表示拥有权已发布。最后旧存储 free
若重入修改文档、关闭窗口或交接绑定，返回 `current=false`，不伪装成可重试的
未提交失败。候选分配之后、发布之前重新核验正文版本、composition 和窗口/绑定
生命周期；失败保留旧集合。绑定窗口在方法内持 callback pin，未绑定 Adapter 仍可使用。

设置后必须显式 prepare。`preparedRangeMarkers(bounds, caller_buffer)` 返回
`PreparedRangeMarkers{items,version,text_version,view_version,projection_version}`。
items 中的 `marker` 是该 metadata version 的定义索引，`range` 保留真实源范围，
rect 使用 Adapter.draw 相同的布局 DIP。Buffer 不足不写入。没有成功 prepare、
metadata/正文/视口过期时不将旧几何当新集合使用。仅改变标记不会重新 shape 或
更换相同覆盖的 Prepared 文本，也不改变 projectionVersion；viewVersion 仍按成功
快照发布前进。

`Limits.range_markers` 默认 4096、硬上限 65536；0 禁用非空定义。
`range_marker_work` 默认 1Mi、硬上限 64Mi，限制可见 run 查询和 cached span 扫描：
每 run 收取二分上界，每个候选收取一次，每个相交范围收取三次 span 扫描及矩形
输出次数。超出返回 `RangeMarkerWorkExceeded`。prefix-max-end 在可见 run 二分
跳过无关前缀，随后只扫描 start 早于该 run 末尾的候选，嵌套区间的保守候选也计费。
这不宣称任意重叠输入的 O(1)。可见标记矩形和单次查询 scratch 各受现有
`Limits.rectangles` 限制。定义、prefix、旧/新候选、几何和临时 scratch 同时计入
现有 Adapter bytes，不提前归还尚未 free 完成的物理存储。

所有构造在 prepare，失败候选完整释放；最终 foreign free 后仍走现有 Document
revision/prepare 发布复核。draw 只回放缓存矩形，不分配、查询全文、shape 或建立
索引。`smoke-editor-range-markers` 检查真实系统布局、隐藏窗口绘制命令、UTF-8/
组合字素/bidi/软换行、投影/折叠/组合、版本、OOM/配额/重入及 Prepared 复用；
它不建立视觉质量、排版下划线或成熟输入控件的结论。

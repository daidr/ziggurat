# 编辑器视觉 caret

DocumentEditor 与 ShapedEditor 可显式准备 bar、block、underline 及失焦描边。
这只是同一选区和系统布局的绘制投影，不引入第二份正文、选区、undo、IME 或焦点状态。
`caretRect`、`caretRects`、`positionRect`、`preparedCarets`、原生 TextClient 与可访问性
继续使用原来的 insertion-bar 几何；视觉 block 的宽度不会扩大文本服务的候选位置。

默认 DocumentEditor `Colors.caret_style = null` 和 ShapedEditor `draw` 保持原 bar 路径。
两者的 `Parameters.caret_cells = false` 默认不建立 cell 索引或 cell 像素资源。
没有 blink 定时器、隐式 worker、绘制时 shaping 或绘制时分配。

## 显式准备与绘制

先在布局/输入阶段把 `Parameters.caret_cells` 设为 true 并调用原来的 `prepare`。
它复用已拥有 Layout 与合适的 Prepared，仅准备少量视觉几何。该开关不属于 font metrics
key，不增加字体版本；从 false 切为 true 也必须走一次几何候选事务。

DocumentEditor 通过 `draw(frame,bounds,Colors)` 的可选 `caret_style` 选择样式。
ShapedEditor 保留 `draw`，另提供 `drawStyled(bounds,scale,surface,style)`。
后者要求 Surface 的可选 `paint_caret(context,Paint)`；旧 PaintCommand union 未添加 tag。
`Paint` 只含局部 DIP `rect` 与 u8 `alpha`。宿主按既有 clip/transform 绘制该矩形，
例如记录 `frame.roundedRect(rect,0,color)`，把 color.a 设为 Paint.alpha。
block 的回调发生在 Prepared 文本之前，因此字形不会被不透明矩形盖掉。
显式设置 block_alpha=255 不会自动反色；文字仍用原 text color，宿主负责色彩对比。

共享的 std-only `ziggurat_caret` 也通过两个 Adapter 的 `caret_visual` 导出。
`Style` 字段如下：

| 字段 | 含义 |
| --- | --- |
| shape | bar / block / underline，默认 bar |
| thickness | bar 宽度、underline 厚度及 outline 内描边，默认 1 DIP |
| terminal_width | 没有正宽 cell 时的明确宽度，默认 1 DIP |
| block_alpha | block 背景透明度，默认 96/255 |
| unfocused | hidden（默认）或 outline |
| enabled | false 时不画任何 caret，仍画正文与选区 |
| active | 宿主视觉活跃开关，与 Adapter 的实际 focus/binding 合取 |

thickness 与 terminal_width 必须有限、严格正且不超过 65536 DIP；alpha 的类型是 u8。
styled 绘制在提交任何绘制命令之前校验参数、回调与准备状态。
block/underline 缺少 cell 准备返回 `CaretCellsRequired`，缺回调返回 `MissingCaretPainter`。
纯样式、颜色、透明度及活动状态变化不需要重新 shape 或重新准备 A8。

ShapedEditor 的真实 focus 条件是原 Editor.focused && window_active。
DocumentEditor 保留原 TextClient token 判定；宿主在状态/输入更新阶段从实际窗口状态提供
active/enabled（失活、disabled/modal 可关闭），无需在 paint 查询原生焦点。
这些开关不绑定/解绑客户端，不改输入接管、命中、滚动、IME 或可访问性身份。

## 几何与边界

宽 caret 的目标是 caret UTF-8 边界开始的完整下一 logical grapheme。
跨度来自同一 Layout 的系统 advance cells，包含组合标记、复杂脚本、emoji 和 bidi
布局的真实结果，不把字符均分，也不使用 ink bounds 或相邻行 caret 差推宽度。
只取当前 affinity 的原生 caret 所在 visual line；该行中至少一个 cell 必须与其 X 相接。
同 grapheme 的多个 cell 分别绘制，不合成会跨过其它文字的外包矩形，不截成固定 16 项。

EOF、空行、CR/LF/CRLF、zero-advance 或 soft-wrap upstream 处若没有这样的正宽 cell，
使用 terminal_width，从原 caret X 向局部 +X 展开，保留其 Y/height。
这是明确的终端几何政策，**不是**估算空格宽度，也不猜 RTL 中不存在的下一个字形。
underline 贴在各 cell 底部，其厚度不超过该 cell 高度。

focused 且 collapsed 的 block 先画 alpha 背景，再画正常颜色的原 Prepared 文本。
非空选区或活动 composition 统一回到 bar，选区/组合标记仍使用原几何。
失焦描边只针对 collapsed、非 composition 的 caret；非空选区没有额外失焦 caret。
描边在 cell 内，由不重叠的边矩形组成，避免半透明角落重复叠加。
多个 caret 逐个使用 Document 的 selection/affinity；不扩大折叠范围或另建选区缓存。
父 clip/仿射由原 Frame 执行，Document 投影的每个 run clip 也继续限制其 caret。
滚动/reveal 继续跟随原 insertion bar，宽 cell 超出视口的部分正常被裁掉。

## 成本与失败

native advance spans 为只读借用。准备时临时 u32 逻辑排序索引占 4S 字节，
in-place heapsort 为 O(S log S)，每个 caret 的查询为 O(log S + k)，k 为实际 cells 数。
Document 的可见 Layout 至多原有 24 个；相同 Layout 在一次候选内共享一个临时索引。
临时索引、cells、新旧候选都进入原显式分配器；Document 使用原同一 bytes 账户。
ShapedEditor 仍是调用者分配器与各项容量上限，不宣称新增一个全进程内存硬限。
新增固定元数据包括 Surface 的可选 callback、Snapshot 的 buffer revision/cell slice，
以及 Document View 的 cell/visual slices 和开关；不把“默认无新堆工作”称为结构零字节增量。

`Limits.caret_work` 默认 1Mi、最大 64Mi，计索引初始化、排序比较/交换、二分与 cell
遍历；它不代表原生 shaping 或 GPU 工作。额度不足返回 `CaretWorkCapacityExceeded`。
开启 caret_cells 时，`rectangles` 同时覆盖既有 selection/composition 几何及 caret 最多四边的输出上界；
超限返回 `RectangleCapacityExceeded`，不静默截断。正常 draw 不建索引、不查询原生布局。

准备前失败保留旧拥有缓存。所有临时 foreign free 完成后才核对来源并发布候选。
ShapedEditor 捕获 buffer/display revision、selection 与 affinity；先无回调地交换资源
所有权，再释放旧资源，最后再验来源。若 old-resource allocator 回调编辑或改变组合，
返回 `LayoutRequired`，已拥有的 snapshot 保留它真实的旧 stamp，不能被画成新正文。
宿主需再显式 prepare，不应重放已经发生的编辑。Editor 与 Engine 仍须覆盖 Adapter 寿命。
发布前也再次核验旧 Prepared 的 pins，先关闭退休 Prepared，再进行旧几何的 foreign free。
live cache 字段在 allocator 回调中借 pin 的夹具用于防御性门禁，不代表 Surface 跨事务借用获准。

`smoke-editor-caret` 使用系统 selection geometry、独立逻辑索引 oracle、原生像素回放、
三 DPI、容量/OOM、同 Layout/Prepared 复用、多 caret、composition 与 final-free 重入。
软件像素 oracle 由 Prepared A8 与 source-over 计算；GPU 使用相同系统 Layout 的独立
原生命令 oracle，避免把软件字体 raster 错当 GPU 字体覆盖率。它不建立视觉质量结论。

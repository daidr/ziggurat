# 系统文本布局

`ziggurat_text_layout` 是可选的 owning 文本布局模块。Windows 用 DirectWrite 完成 shaping、系统字体 fallback、双向排序和换行，并用系统 ICU 的 character break iterator 分段；Linux 用 Pango 完成这些操作。它不依赖窗口、绘制后端或 Editor，也不替换现有简单 `measure` 接口。

本模块提供不可变布局、逻辑行、字素边界、双亲和性 caret、坐标 hit test、选区的 logical advance rectangles、显式开启的词范围查询，以及显式预备后供 GDI/D2D/Cairo 绘制的资源。按富文本 run 设置字体、垂直排版和精确 glyph ink 查询仍未提供。Editor 的可选桥接另见[编辑接口](editor.md)，这里不接管编辑文档或把整个复杂文本路线视为完成。

## 所有权与线程

```zig
const text = @import("ziggurat_text_layout");

// 在进程入口保存，不能用任意工作线程的身份替代。
const process_main_thread = std.Thread.getCurrentId();
const engine = try text.Engine.create(allocator, process_main_thread, .{});
defer engine.close() catch unreachable;

const layout = try engine.layout("Hello مرحبا 👩‍👩‍👧‍👦", .{
    .family = "",
    .locale = "en",
    .size = 16,
    .width = 240,
    .wrap = .word_character,
});
defer layout.close() catch unreachable;

const caret = try layout.caret(.{ .byte_offset = 0 });
const hit = try layout.hitTest(.{ .x = caret.x, .y = caret.y });
_ = hit;
```

`Engine` 和 `Layout` 是 opaque 指针，创建时由显式 allocator 分配稳定存储。每个指针只有一个负责 `close` 的所有者；其他指针副本只是借用。不能重复关闭，不能在关闭后查询或保留返回的 slice。Engine 必须覆盖所有 Layout 的生命周期；仍有 Layout 时 `Engine.close` 返回 `LayoutsAlive`。

主线程身份是宿主必须从进程入口传入的契约，不是 OS 自动探测，也不是把 Engine 创建线程自动认作进程主线程。传入真实身份后，worker 调用创建、布局、查询、准备或关闭都在读取 native/layout 数据之前返回 `WrongThread`。检查前只读取稳定对象中的线程身份。后台任务需要经宿主的主线程任务入口显式交接。

布局快照复制 UTF-8 文本、UTF-16 文本、字体 family 和 locale，不借用构造参数。布局保留自己所需的原生引用；没有窗口指针、异步回调、隐藏线程、队列或定时器。构造同步执行，不提供伪异步取消：失败时立即逆序释放已取得的资源。宿主在编辑或布局约束变化时显式创建替代布局，完成交接后再关闭旧布局；普通 paint 只读取既有布局。

构造调用期间，输入 slice 指向的存储必须始终有效；不能由 allocator 回调释放该存储。family/locale 在首次调用 allocator 前复制到共 382 bytes 的有界局部存储并验证。文本只分配一份拥有的 UTF-8 副本，复制之后才验证内容、计数、生成精确大小的 UTF-16 和 scalar 表；后续不再读取调用者文本。allocator 回调若经原 Editor API 修改仍有效的显示缓冲，Engine 得到内部一致的捕获内容，ShapedEditor 再用原 Editor 的版本/选择戳拒绝已过时的准备结果。它不为调用者提供跨线程可变内存同步，也不允许销毁活跃的 Editor/Engine。

## 预备与绘制

`layout.prepare(scale, PrepareOptions)` 创建拥有的 opaque `Prepared`，从同一个 native layout 生成单通道 8-bit coverage。文本不会再次交给 DrawText/Pango set_text，也不建立第二份 shaping/caret 布局。font fallback、bidi、wrap、caret 与选区仍来源于原 Layout。

```zig
const prepared = try layout.prepare(scale, .{
    // 可选：layout 本地 DIP viewport。省略时准备完整 ink plane。
    .viewport = .{ .x = 0, .y = 0, .width = 240, .height = 80 },
});
defer prepared.close() catch unreachable;

// 在当前 Frame 的 draw 中只提交已有资源；不在 draw 中 prepare。
frame.preparedText(.{ .x = 12, .y = 20 }, try prepared.view(), ui.Color.rgb(0x202020));
```

`PrepareOptions` 含 `viewport:?drawing.Rect=null` 和 `limits:PrepareLimits=.{}`。viewport 是原布局的局部坐标，裁剪而不改变文本 advance、line/caret 坐标或 shaping。滚动需要显式改变 viewport/绘制 origin 并重新准备可见区域；paint 不会按当前 clip 偷偷生成新 raster。没有 viewport 时覆盖完整 ink bounds，带两个物理像素边缘 padding；空文本仍生成有界空 coverage。

scale 范围是 0.0625..16，所有后端都要求 Prepared.scale 与目标 scale 精确匹配，错误为 `PreparedDpiMismatch`。宿主在 DPI/viewport 变化时提前准备候选资源，成功后交换，失败保留旧所有权但不能把旧资源假作匹配新文档/新 DPI。GDI 用双线性 coverage 采样处理 fractional origin，Cairo 复用预建 A8 pattern；原生边缘 AA 不保证跨后端逐像素一致。

Windows 准备使用原 `IDWriteTextLayout.Draw` 和灰度 DirectWrite bitmap target；临时 bitmap/COM 资源在 prepare 返回前释放，持久保存 allocator 拥有的 coverage。GDI 回放只把 coverage 按 RGBA source-over 合成到已有 DIB，不链接或调用 DirectWrite/ICU。D2D 回放直接 `DrawTextLayout` 同一个 `IDWriteTextLayout`，复用 renderer solid brush 并临时选择 grayscale AA；不调用 CreateTextLayout/format 或上传 coverage bitmap。Linux 准备用原 PangoLayout 绘制到 A8 surface，回放复用已拥有的 surface pattern，不在 paint 调用 Pango shaping。此分项是单色 tint，不提供原始彩色 emoji/font palette；半透明色与 alpha=0 均有明确 coverage 语义。

Prepared 不依赖 GPU device；device loss 后可在重建的 device 上继续绘制原布局，无需重新 shape/prepare。目标 resize 不改变 layout 或 viewport，宿主若需 reflow/改变可见区域应显式重建相应资源。普通回放不创建本适配层的 native glyph/layout/brush 对象、不触碰 Zig allocator；系统字体/驱动库的内部 cache 不由本模块控制。

`Prepared.view()` 返回纯数据借用 `drawing.PreparedTextView`，没有应用 callback。共享 `ziggurat_drawing_resources` 只含 std 数据/lease，不引入 native 文本库。Frame/Buffer 记录资源时固定其 Lease，按 lease 去重，最多 32 项；完成本次所有回放（包括失败、GPU 后备）后释放，不能跨 paint 保留旧 View。持有 pin 时 `Prepared.close/ensureUnused` 返回 `ResourceInUse`，`inUse` 可用于宿主的候选交换预检。Prepared 活着时 `Layout.close` 返回 `PreparedAlive`；释放顺序为 frame pins → Prepared → Layout → Engine。未入帧的 View 是普通借用，拥有者仍须覆盖其所有使用。

准备预算先于 bitmap/coverage 分配检查：每个 Layout 最多 8 个 Prepared，plane 每边最多 32,768 像素，最多 16 Mi 像素且最多 64 MiB 显式存储预算，可降低不可提高。`PrepareStats.owned_bytes` 计入 Prepared 状态和持久 coverage，`peak_plane_bytes` 还包括 Windows 同时存在的 32bpp native bitmap；Cairo pattern/系统 glyph cache 等内部对象元数据不假称计入此字节数。超限返回 `PreparedCapacityExceeded`，不把长文档偷偷 raster 到无界 plane。可用显式小 viewport 绘制 2000 段文档；它不宣称 native 全布局创建成本与可见区域无关。准备的 allocation/native 失败完整回滚，没有半成品 View。

## 坐标与文本单位

| 接口 | 单位与含义 |
| --- | --- |
| 文本、ByteRange、Caret.byte_offset、Line.start/end/next_start | 原 UTF-8 快照中的 byte offset |
| utf16FromByte / byteFromUtf16 | Unicode scalar 边界的 UTF-8 byte / UTF-16 code-unit 双向映射 |
| graphemeByte | 系统 cursor/grapheme 边界的 byte offset；索引包含最终文本末尾 |
| Rect、Point、font size、width、baseline | DIP，布局原点在左上角，向右/下为正 |
| Line.end | 不含段落分隔符的行末；next_start 包含分隔符或软换行后的下一行起点 |

字节连续区间、UTF-16 surrogate 内部都不是合法 scalar 边界。Caret 和选区端点还必须是系统字素边界；组合音标、ZWJ emoji 和 spacing mark 中间的 scalar 不自动成为可停留 caret。系统 ICU/Pango 的 Unicode 版本和字体目录属于运行环境，跨机器的分段和度量不保证完全相同。

`upstream` 使用前一个 scalar 的 trailing edge，`downstream` 使用当前位置的 leading edge。在软换行和 bidi run 边界，二者可能落在不同视觉位置。文本开头的两种亲和性相同；文本末尾的下游位置由系统终止 caret 提供。Hit test 在所选逻辑行的缓存视觉边中选择最近 x；相同位置按 byte offset/affinity 确定顺序。bidi/换行别名不保证返回原来的逻辑端点，但几何位置应可往返。`inside` 只表示点位于整体 logical layout bounds 内，不是 glyph ink 命中。

`Direction.ltr/rtl` 是显式的段落基方向，布局内部仍执行系统 bidi 排序；不自动为每段猜测基方向。`Wrap.none` 使用自然宽度，`word` 保留整个词，`word_character` 允许词内换行。字体缺失时由系统 fallback；`Metrics.missing_glyphs` 给出 shaping 结果中的缺失字形计数，不能把它当作字体安装或语言支持的完整证明。

## 词与连续非词范围

`Options.word_ranges` 默认 `false`。显式设为 `true` 时，Layout 构造从同一拥有的文本和原生布局准备词索引；`Wrap.word` 不隐式开启索引。`Layout.wordRangeAt(Caret)` 返回该快照中的 UTF-8 半开 `ByteRange`，不分配、不查询 SDK、不扫描词长，也不改变选择。

```zig
const words = try engine.layout("alpha,  beta!", .{
    .locale = "en",
    .word_ranges = true,
});
defer words.close() catch unreachable;
const first = try words.wordRangeAt(.{ .byte_offset = 5, .affinity = .upstream });
const gap = try words.wordRangeAt(.{ .byte_offset = 5, .affinity = .downstream });
// first=[0,5)，gap=[5,8)。保存数字不会延长 Layout 的生命周期。
_ = first;
_ = gap;
```

词由平台的 lexical intervals 决定；相邻词保留各自边界。词外相邻的空白、标点、独立 symbol/emoji 和换行合并为最大连续非词单位，包括 leading/trailing gap，也可以跨 CR/LF/CRLF。它不是 identifier/parser 分词，不把尾标点附给前词。非空文本完整覆盖 `[0,text.len)`，没有重叠、空洞或零长单位。

先检查 owner thread/Closed，再检查开关；未开启为 `WordRangesNotEnabled`。开启后只接受已有字素边界，非法 UTF-8 byte、scalar/字素内部、CRLF 中间和越过 EOF 都是 `InvalidCaret`，不会静默 snap。单位内部的两 affinity 返回同一单位；在共同端点，upstream 选逻辑前一单位，downstream 选后一单位，不随 bidi 的视觉左右反转。byte0 两种都选首单位，EOF 两种都选末单位；空文本只接受 byte0，返回 `[0,0)`。

Windows 复用 Engine 已拥有的 System32 ICU module；仅开启时局部解析 `ubrk_getRuleStatus`，用 `UBRK_WORD` 的 NONE/NUMBER/LETTER/KANA/IDEO 状态区间区分词与非词。缺符号时开启的 Layout 返回 `UnicodeSegmentationUnavailable`，包括空文本；普通 Layout 的必要 exports 不变。空文本不创建词 iterator、不分配 WordIndex。每个非空 iterator 在同步构造返回前关闭，使用已拥有的 UTF-16 文本，不保留 caller 或临时输出指针。

Linux 读取同一个已拥有 PangoLayout 的 readonly `is_word_start/is_word_end`，不重建 shaping，不把 `is_word_boundary` 或 `!is_white` 冒充 lexical 分类。非空 locale 沿原 PangoContext 的设置；`locale=""` 保留其 context 默认。Windows 的空 locale 走 ICU root/空 locale 路径，两者不承诺相同分词。词典、语言 fallback、Unicode/库版本可能影响范围；中日韩、撇号、underscore 等需对照当前系统 oracle，不能套用另一平台 golden。模块保留 native 错误 domain/code，不将 locale warning 当作本地词典已命中的证明。

非空索引单次申请 `8+4G` bytes（G 为该 Layout 的字素数，最大 8,192），容量不按最终词数缩水；空索引不申请。所有最终范围必须与原 scalar/字素表对齐、严格递增并恰好结束于 EOF，否则构造失败。Windows 只将词表结束位置原位转换为 UTF-8，几何仍使用原 UTF-16 positions。索引与原数组一样沿构造事务回滚，并计入所有持久/同时存活 scratch 的 `layout_bytes` 峰值。

模块附加构造工作为 O(S+G+W)，查询为 O(log G+log W)，S/W 分别为 scalar/最终单位数；ICU/Pango 内部分配、词典缓存和算法时间不在此线性扫描或 4 MiB 限额内。默认没有词表、新 word SDK 调用或 lookup；Options 增加一个 bool，LayoutState 增加一个可选拥有指针，实际 sizeof/padding 需按目标构建测量。Engine/Prepared/native C records 没有新增常驻字段。最大词表为 32,776 bytes，64 个满表共 2,097,664 bytes，不含 allocator 元数据或各 Layout 其余存储；同时保留新旧 Layout 就实际持有两份。

Linux x86_64 / Zig 0.15.2 的 Debug 与 ReleaseSafe 原生记录中，Options 为 56 bytes、LayoutState 为 672、EngineState 为 352、PreparedState 为 416，新增字段被现有 padding 吸收。四个默认输入的申请尺寸/次数、owned/peak 和 native_calls 与改动前同一 tracer 完全一致；非空 opt-in 多一次完整 `8+4G` 申请，空文本申请相同而 native_calls 多一次显式能力检查。这是这些构建的实际固定成本，不保证其他 ABI 相同，也不统计系统库内部分配或执行时间。

词索引跟随同一 Layout owner，不能以单独引用计数绕过 `PreparedAlive`/frame lease。close 先撤查询权限再释放索引；allocator free 重入中查询为 `Closed`，Engine 仍等整个 Layout 析构结束才减存活数。`layoutAllocated` 的 allocator/context 必须覆盖全部 Prepared 和最后 free。此接口没有接入 Editor 多击、词/行选择或可访问性词动作。

## 选区几何

选区返回完整字素所覆盖的 logical character advance cells；它们不是字符的 ink bounds，更不是 UIA 可见范围或屏幕可见性。多 scalar 字素会合并所有单元，同一字素若存在分离的视觉区间则保留多个 rectangle。选区以行、x 排序，同行相邻/重叠且 y/height 相同的单元合并。段落分隔符没有额外的可见 advance rectangle。

Windows 在构造期读取真实 cluster advances 和完整文本的原生 range islands，再生成 scalar cells。只有单 UTF-16 单元 cluster、完整 island、可精确表示的坐标运算且通过实际 glyph run 原生位置校验时才复用 cells；其余情况继续对完整字素调用原生 range hit testing，不均分 ligature/多 scalar advance。Linux 用一次 Pango character iterator 快照全部 scalar cells，再按字素聚合；不能仅以第一个 scalar 的 character cell 代替整个字素。两条路径都保留缺失字体或多 scalar 字素产生的多个分离单元。

调用者提供输出数组。`selectionRects` 先计算需要的容量，`OutputTooSmall` 时输出完全不变；可先调用 `selectionRectCount`。range 为半开区间，start 大于 end 返回 `InvalidRange`，非字素端点返回 `InvalidCaret`。空选区不写输出。

`Layout.advanceSpans()` 以 O(1) 借用构造时已经缓存的 `[]const AdvanceSpan{start,end,rect,line}`，不调用 native、不分配、不复制文字。start/end 是该不可变 UTF-8 快照中的完整字素 byte range；一个字素可有多项，零宽项也保留。数组按行及视觉 x 排序，不是文档逻辑顺序或 caret/hit stops，借用止于 Layout.close。高级编辑器可逐缓存线性导出几何，仍需应用自己的 placements、viewport、已提交变换和文档 offset 映射；不能直接把这些单元称为 UIA 可见范围。

## 容量与成本

Limits 的默认值也是允许的上限，宿主可以降低：

| 项目 | 上限 |
| --- | ---: |
| UTF-8 text bytes | 65,536 |
| 字素数 | 8,192 |
| 行数 | 4,096 |
| 缓存选区 rectangles | 16,384 |
| 同时存活的 Layout | 64 |
| 单 Layout 的显式存储和构造 scratch | 4 MiB |
| 单个字素的分离 rectangles | 16 |

font size 限制为 1..512 DIP，weight 为 100..900，width 为 0..1,000,000 DIP；启用换行时 width 必须大于零。family/locale 分别最多 255/127 UTF-8 bytes。输入禁止无效 UTF-8、嵌入 NUL、NaN 和 Inf。输入长度、参数和可推导的内存预算在 native 调用前检查；原生分段、行数和几何结果取得后再检查对应容量。预算不足返回错误，不交出半初始化对象。

首次分配前的最低字节门包含 Layout 状态、原 slice 长度加终止字节、family/locale 及其终止字节、一个 UTF-16 终止单元、scalar sentinel 和字素位置 sentinel。只完成状态及唯一 UTF-8 副本后，从自有文本计算 scalar/UTF-16 数量，再把全部文本、映射、位置和 character-cell 容量计入精确字节门；超限先撤这两项，尚未创建 native layout。UTF-16 直接申请所需单元数，不用额外全文临时副本。后续原生结果取得后的数组/scratch 门保持相同预算。上述 382 bytes 选项局部存储属于固定构造栈成本，既有文档大小上限不变；普通 paint 不经过这些操作。

`owned_bytes` 是持久状态、所有数组容量和快照向 allocator 请求的字节数；`peak_owned_bytes` 还包含同时存活的字素位置 scratch，以及 `32 * scalar_count` character-cell scratch。Windows 批量构造另有 `8 * native_cluster_count + 36 * native_range_count` scratch，数量来自原生容量查询，分配前计入预算。allocator 元数据、系统 font cache、原生布局内部内存不在此数内。Windows 的 line-metrics C 栈数组另有固定约 96 KiB 上限；Linux 构造使用有限次 Pango iterator 创建/释放。原生库的内部内存由系统库管理，不冒充受 Zig allocator 的 4 MiB 限额约束。

cell scratch 仅在创建期借给 C，成功或失败都先清除 native 借用再释放；cluster/range scratch 不留在 native 状态中。UTF 转换、cluster/cell 遍历随输入增长，原生 range 排序 O(I log I)，edge/span 排序分别为 O(G log G) / O(R log R)。查询快照按已声明的有界最坏容量保留，未使用容量不冒充实际字符数。

Windows 保留独立的原生 glyph run 校验。相同字体在不同高度的浮点行坐标不能共享校验结果；未被 run 覆盖的 cell、非精确浮点 island、multi-unit cluster 或不匹配的原生行框都回退到原生查询。单个 run 中采用系统给出的 cluster advance，既不测量单独字符，也不按字符数平均宽度。回退仍可能每字素查询，原生查询内部复杂度不由本模块承诺，不能把长 ASCII 单行的收益推广到所有文档。

`Engine.layoutReference(text, options)` 是显式诊断/差分接口。在 Windows 中跳过批量快照，以原来的逐位置/range 原生查询构造同类不可变 Layout；它可能显著更慢，不能放在 paint 中。在 Linux 中两者使用同一条既有 Pango character 快照路径。两者执行相同的容量、线程、错误、Prepared 依赖与关闭规则。

Layout 查询没有 shaping、native 调用或 Zig 堆分配：文本/参数/度量/行表 O(1)，单位映射和 caret O(log S/G)，hit test O(log L + log E)，选区 O(R)，其中 R 是缓存 rectangles、E 是该行的视觉边数。`native_calls` 统计创建期进入 C adapter 的次数，包含快照查找；它不等于真实位置/range 查询次数。`snapshot_cells` 表示本次临时 scalar-cell 数，Windows reference 为零。

`BuildStats.native_queries` 在 Windows 单独统计实际 DirectWrite `HitTestTextPosition`、`HitTestTextRange`、`GetClusterMetrics`、`GetLineMetrics`、创建期 `Draw` 调用，以及遍历的 glyph runs 和 bulk/fallback scalar cells。Windows reference 不构造 cells，bulk/fallback 两字段都为零。计数不包含全部 COM 方法或系统库内部工作。Linux 仅报告 bulk/fallback cell 数，其余字段为零表示未提供对应 DirectWrite 计数，不能解读成没有调用 Pango。`elapsed_ns` 是可用时从本次构造开始到快照完成的耗时，不包括随后 scratch 释放、Engine 创建或进程启动。

以下是增加词选项之前的一次 x86_64、Zig 0.15.2 ReleaseSafe 原生 smoke 历史记录，不能当作当前结构 sizeof/默认字节数：Windows NT 10.0.26220；Linux 为 WSL2 Ubuntu 24.04、kernel 6.6.87.2、Pango 1.52.1。默认 family、size 16 DIP，Engine 已创建，native 字体 cache 已由前面的复杂脚本用例使用。同一构建按每种路径连续构造三次取中位数；时间依赖机器、字体和 cache，不是跨机器保证：

| ASCII 字素 | Windows bulk / reference | Linux 同路径 | 持久请求字节 | Windows bulk / reference peak 字节 |
| ---: | ---: | ---: | ---: | ---: |
| 1,024 | 0.48 / 0.92 ms | 0.52 ms | 638,753 | 683,849 / 642,853 |
| 2,048 | 0.89 / 3.86 ms | 0.95 ms | 752,417 | 842,569 / 760,613 |
| 4,096 | 1.75 / 11.54 ms | 1.81 ms | 979,745 | 1,160,009 / 996,133 |
| 8,192 | 3.23 / 43.48 ms | 3.78 ms | 1,434,401 | 1,794,889 / 1,467,173 |

这组 ASCII 的 Windows bulk 实际 position/range 查询各 2 次，reference 分别为 `2G + 2` / `G`；bulk 多出 2 次 cluster 查询和一次创建期 run 校验 Draw。C adapter 入口仍约 `3G` 次，但命中 cell 时只查缓存。8,192 字素样本的构造 scratch peak 增加 327,716 字节，持久内存相同。

段落收益有限：`"abc\n"` 重复 1,024 次（4,096 字素、1,025 行）bulk/reference 为 9.71/11.00 ms，position 为 2,049/9,218，range 为 2/4,096，bulk peak 1,237,797 字节。Arabic/Hebrew/组合音标/ZWJ emoji 混合行重复 128 次（2,560 字素）为 9.03/9.15 ms；bulk position/range 为 1,281/258，2,304 个 scalar cells 使用 bulk，1,152 个保留 fallback，peak 987,685 字节。没有用更短的文档或近似 advance 换取这些结果。

这些数字只说明显式构造成本，不能当作 paint、显示延迟或全部脚本的性能结论。`smoke-text-layout` 同时打印 bulk/reference 的三次中位数、真实查询计数和 scratch peak；测试只断言查询/容量/语义，不用耗时阈值制造机器相关的通过条件。

## 原生能力与验证

Windows 只从 System32 加载 `icu.dll`；缺少 DLL/必要 exports 明确返回 `UnicodeSegmentationUnavailable`，不回退到削弱的字节或 scalar 分段。DirectWrite 的失败通过 `Engine.lastNativeError` 保留 HRESULT；Win32/ICU 失败使用各自 domain/code。未支持的平台返回 `UnsupportedPlatform`。

`smoke-text-words` 对独立 ICU/Pango oracle 比较每个合法 caret 的两 affinity，覆盖连续非词、CRLF、组合字素、ZWJ、RTL、中日韩、显式空 locale/fallback、wrap/reference、最大字素/文本输入、所有非法 byte、线程/容量、每个 Zig allocation 故障、源/locale 捕获、Prepared/lease 与 free 重入。oracle 独立保存 whole intervals、按 interval starts 二分，设置 2,097,152 模块 work 上限；最大输入不逐 caret 重扫 selection rectangles。`smoke-text-words-fault` 使用测试专用 adapter 计数，核默认无 word call/lookup、开启后纯查询不再进入 native、Windows enabled-empty/nonempty 缺 export 均拒绝及 iterator 配对。计数/故障 seam 不进入正常 adapter。`smoke-text-word-costs` 与改动前同一 tracer 比较请求尺寸/次数、owned/peak 和普通 native_calls；这些字段不统计所有 ICU 内部工作，不能单凭 native_calls 声称零 ICU 查询。原生验收不创建窗口或打开图像，也不建立文字视觉质量结论。

`zig build smoke-text-layout` 不创建窗口、不抓屏，实际调用 DirectWrite/Pango。已覆盖组合音标、ZWJ/肤色/旗帜 emoji、中文、Arabic/Hebrew 混合 bidi、Bengali/Thai/Myanmar 多 scalar 单元、软换行/CRLF/空段落、RTL 行边界和 terminal caret、坐标往返、输出容量事务、快照、worker 拒绝、存活依赖、每个 Zig allocation 的故障回滚与重复纯查询。批量/reference 差分覆盖每个字素的双 affinity caret、单字素与跨字素选区、完整选区、全部行坐标和小文档 prepared coverage。矩阵包含小数 font size、不同字体、bidi/wrap、CRLF/控制符、terminal caret、1,024–8,192 字长行和 2,001 行文档。长段落行顶直接取原生坐标，caret/span 用内部点归属行，避免 float 累加或边界舍入把后续行归到前一行。

`zig build smoke-text-layout-capture` 用独立子进程隔离构造边界：原 Editor API 在首次、第二次 allocator 回调把相同 byte 长度的 `é` 改成 `ab`，以及 UTF-8 已复制后的源变更。默认/reference 布局都检查 scalar/UTF-16/字素一致，Adapter 检查过时版本拒绝与重试。另验 family/locale 别名变化、捕获时非法 UTF-8/NUL、最低与精确预算、构造期 Engine Busy、全部 Zig 分配故障和资源归零。它不创建窗口；已复制后的原数组非法变化不会污染自有快照。

`zig build smoke-text-drawing -Dgpu=true` 在 Windows 隐藏 HWND 实际回放 GDI、D2D hardware/WARP，在 Linux 真实 Cairo surface 回放。软件路径按物理像素验证 prepared coverage、RGBA、clip、透明 no-op 与 1/1.5/2 scale；GPU 验证每行有实际文本像素、半透明内部 glyph、clip 和设备丢失后原布局复用。帧固定期间拒绝提前关闭，100 次纯查询与正常软件回放不触碰 Zig allocator。Windows GDI handle 数稳定；Windows/Linux 的 native engine/layout/prepared/reference/module 计数在完成后为零，测试 allocator 同时检查 Zig 泄漏。这些检查不建立字体视觉质量或屏幕显示延迟结论。

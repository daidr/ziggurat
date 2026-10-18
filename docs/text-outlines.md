# 系统文字轮廓

可选模块 `ziggurat_text_outlines` 把已经拥有的 `ziggurat_text_layout.Layout` 转为独立的 `ziggurat_vector.Path`。它不依赖 UI renderer，不在 paint 中查询字体，不为普通 UI/SVG 应用初始化字体系统。

```zig
const shape = try text_outlines.fromLayout(layout, allocator, .{});
defer shape.close() catch unreachable;
const path = try shape.path(); // 只读借用，止于 shape.close
const coverage = try path.prepare(allocator, .{
    .main_thread = process_main_thread,
    .viewport = .{ .width = 256, .height = 128 },
    .scale = 1.5,
});
defer coverage.close() catch unreachable;
```

源 Layout 和 Engine 可以在 fromLayout 返回后关闭，Shape 保留独立路径及显式请求的字形单元。Path 准备后的 A8 同样独立，可沿已有 CoverageView 上传/回放；这里不创建另一套文字 raster 或 renderer。

DirectWrite 从原布局的 DrawGlyphRun 获得实际字体、glyph indices、advances、offsets 与 bidi level，经 [GetGlyphRunOutline](https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwritefontface-getglyphrunoutline) 提取轮廓。Linux 对同一个 PangoLayout 使用 [PangoCairo.layout_path](https://docs.gtk.org/PangoCairo/func.layout_path.html)，再复制 Cairo 的 move/line/cubic/close 数据。两端都复用原来的 shaping、fallback 和换行；不以字符宽度重新安排 glyph。

轮廓位于原 Layout 的 DIP 坐标，向下为正 y。stats.first_baseline 是第一行 baseline 的 y，advance 是布局包含尾空白的逻辑宽度。若需把第一条 alphabetic baseline 放到 y=0，准备路径时显式平移 -first_baseline。多行仍保持各行原位置；advance 不是每个字符的定位表。字体 fallback、ligature、bidi 与复杂脚本结果取决于原布局和系统字体版本。

`include_cells=true` 额外输出每个实际 glyph 的完整字形单元：原 shaping 的 advance/offset 与实际 fallback font 的 ascent/descent，坐标与路径相同。空白仍有单元，零 advance 的组合字形可以有零宽度；它不是 ink bounds、字符索引、caret 或选择矩形。Snapshot 的 `cells()` 返回32字节 f64矩形，Shape 转为 Vector Bounds；默认关闭且不分配单元数组。Linux 此选项要求 Pango 1.50以上以取得每个 run 的准确 baseline，旧版本明确 UnsupportedOutline，默认单色轮廓不受此要求影响。

`Shape.takeGeometry()` 消费 Shape 壳并转移 `{path,cells}`。两者使用 `path.allocator`，调用者先 free cells，再 close Path；`takePath()` 只转移 Path 并释放可选单元。普通 `cells()`/`path()` 是借用，不能越过 Shape close 或转移。

此接口只输出**单色字体轮廓**，不输出 COLR/SVG/bitmap 的彩色 paint 数据，也不承诺与字形 hinting 后的屏幕像素完全相同。字体没有轮廓的 glyph 不贡献路径；空白可以只有逻辑 advance、没有几何。bitmap-only 字体、竖排、彩色字体的外观保真不属于本切片。转换成功也不表示完整 SVG text、tspan 或 textPath 已支持；SVG 的字体选择、逐字符定位和文字裁剪需分别接线并验收。

## 所有权与预算

Layout.outline(allocator, options) 是不依赖 Vector 的中立入口，返回拥有型 OutlineSnapshot。只含 move/line/cubic/close 的 f32 段；segments 借用止于 close。原生输出两遍处理：第一遍先验证命令容量并计数，第二遍写入完整候选，只有完全成功才发布。glyph 数先受现有 Layout 与 OutlineLimits 限制。默认最多8192 glyph、65536命令、4MiB Zig快照存储；硬上限分别65536、262144、16MiB。

fromLayout 桥默认最多8192 glyph、65536命令、16MiB峰值，字节硬上限64MiB。它的同一预算累计中立快照、转换数组、新 Path 和 Shape 元数据的同时存储；不会以最终输出大小冒充候选峰值。stats 分列 owned_bytes 与 peak_owned_bytes，失败不发布部分 Shape。allocator 私有 header、原布局、系统字体缓存和原生临时存储另计。

请求完整单元时，Snapshot 与 Shape 的两份候选单元数组也累计于同一峰值预算，glyph 数限制不重新发放。stats.cells 单列输出数，owned_bytes 包含保留数组；取消和失败完整释放。

Linux Pango/Cairo 在显式轮廓调用期间产生临时 native path；glyph 上界在调用之前检查，但不能逐命令拦截 Cairo 的内部存储，故不把命令/字节配额称为总 native 内存硬限制。DirectWrite sink 在接收每个输出命令时检查容量。取消在各有界 native 调用、foreign allocation 和转换块之间检查，不能中断单次系统字体操作。

所有接口首先检查 owner；不自动跨线程转发，不提供 worker handoff。Shape/Snapshot 的 allocator context 覆盖最后一次 close。Layout 在源快照构造开始到最后候选 free/State 访问结束期间拒绝 prepare、outline 和 close 重入；桥随后只访问独立快照，因此从转换阶段的 allocator callback 关闭源对象是安全的。析构先关闭入口，再执行 foreign free；递归 close 返回 Closed。

Engine.layoutAllocated(allocator, text, options) 让显式准备把 Layout 与其 Prepared 的全部 Zig allocations 纳入同一个场景 allocator。默认 Engine.layout 仍使用 Engine allocator。传入的 allocator context 必须覆盖该 Layout、所有 Prepared 和最后释放；Engine 自己继续使用创建它的 allocator。构造期间 Engine 拒绝重入 layout/close，失败候选完整回滚。Layout.prepare 和 Prepared.close 使用同一个 owner operation 门，防止 foreign allocation/free 回调释放正在访问的布局。

## 验证

smoke-text-outlines 使用真实 DirectWrite/Pango，覆盖 Latin、复杂脚本、混合 bidi、fallback/emoji、组合字符、空白、重复快照一致、源提前关闭、三个 DPI、O 的孔洞及两行 baseline。另验命令/glyph/精确峰值配额、全 Zig allocation-failure、取消、WrongThread、allocator 回调中的构造/释放重入及全部原生引用归零。它验证路径几何和拥有关系，不评价人工视觉质量、字体版本等价或彩色字形外观。

`smoke-text-cells` 另用独立系统字体指标 API 对照单 glyph 的四个完整单元坐标，覆盖普通/斜体和空白；复杂文字验证 glyph 数、有限边界、源提前关闭、takeGeometry、峰值减1和全部分配失败。它与 SVG 的变换后逐单元求并集、objectBoundingBox 渐变/clip/mask 对照分别验证。

## 显式 glyph / cluster 映射

`include_mapping=true` 在同一个不可变 Layout 上，额外生成拥有型源文本、glyph 记录、cluster 记录和**独立的逐 glyph 轮廓**。默认 false；普通 outline 仍为原来的两遍批量输出，不创建映射数组，也不调用映射原生入口。

```zig
const shape = try text_outlines.fromLayout(layout, allocator, .{
    .include_mapping = true,
});
const mapping = try shape.takeMapping();
defer mapping.close() catch unreachable;
try shape.close(); // mapping 的 Path / 源文本 / 记录仍由 mapping 拥有
const mapped_path = try mapping.path();
for (try mapping.clusters()) |cluster| {
    const original_utf8 = (try mapping.source())[cluster.source.start..cluster.source.end];
    _ = original_utf8;
    // cluster.mapped_segments 只索引 mapped_path.commands；不索引批量 Path。
}
```

中立接口 `Layout.outline(..., .{ .include_mapping = true })` 的 `Snapshot.mapping()` 返回 `?MappingView`，借用源文本和三个数组，寿命止于 Snapshot.close。`MappingView.mapped_segments` 和原有 Snapshot.segments 完全分开。Vector 桥的 `Shape.mapping()` 借用独立 Mapping；`takeMapping()` 转移该拥有体，Shape 仍拥有原批量 Path。第二次转移返回 MappingNotRequested。`takeGeometry()` / `takePath()` 消费 Shape 时释放未转移的 Mapping，不把映射范围配到批量 Path。Mapping 可覆盖原 Layout、Engine 和 Shape 的寿命，最后必须在 owner 线程 close 一次。所有借用都不得越过其拥有体 close / 转移。

`Cluster.source` 是原始 UTF-8 半开字节范围。Windows 使用 [DWRITE_GLYPH_RUN_DESCRIPTION](https://learn.microsoft.com/en-us/windows/win32/api/dwrite/ns-dwrite-dwrite_glyph_run_description) 的 UTF-16 textPosition/stringLength/clusterMap，再经 Layout 已有 scalar 索引转换，拒绝 surrogate 内部边界；Linux 使用原 GlyphItem 的 UTF-8 cluster 数据。cluster 是系统 shaping 的单位，不等同于 scalar、grapheme 或用户光标位置：一个源范围可以对应多个 glyph，一个 ligature 也可以覆盖多个 scalar。组合字符、复杂脚本和 ZWJ 序列保持系统给出的归属，不均分 advance、不按 ink 猜字符位置。

`Cluster.glyphs` 索引 Glyph 数组，`Cluster.mapped_segments` 与每个 `Glyph.mapped_segments` 都只索引映射路径。一个 cluster / glyph 的段范围连续，允许 count=0。公开 cluster 次序保留原生枚举：跨 run 的 bidi 源范围不保证逻辑递增；Pango 的 run glyph 数组为视觉序，DirectWrite 按其原 glyph 数组顺序输出，不能把不同平台的数组序号当稳定字符身份。Zig 只用有界临时排序验证源范围不重叠、补齐原生未绘制的源区间，不重排实际 glyph。

CR/LF 等未产生 glyph 的源范围仍保留记录，其 glyph / segment count 为0，run / origin 为 null。没有伪 glyph 或伪零坐标。空白可能有实际 glyph 和完整单元却没有可绘制轮廓；Pango 路径还可包含不产生填充的 move。Glyph 同时记录 glyph_id、run、bidi_level、原 advance、基线 pen、加原生 offset 后的 origin，以及实际字体 ascent/descent 的完整 cell。cell 不是 ink、caret、selection 或 grapheme 边界。Pango 1.50 以下明确 UnsupportedGlyphMapping；横向单色轮廓以外的原生 run 同样可被明确拒绝。

映射始终取原 run 的字体、glyph indices、advances、offsets 和 baseline。DirectWrite 对原 glyph 子串调用 GetGlyphRunOutline；Pango 对原 GlyphInfo 调用 [PangoCairo.glyph_string_path](https://docs.gtk.org/PangoCairo/func.glyph_string_path.html)。两端没有重新 shape，每个 glyph 都保留原布局位置。pen 由实际 run 起点和原 advance 累积，cell / origin 使用原 offset；DirectWrite 的轮廓 baseline 接口为 FLOAT，进入原生单 glyph 调用时按其类型舍入。

**批量轮廓与逐 glyph 映射不是同一个几何表示。** 批量输出保留原样，逐 glyph 调用的原生浮点分组及 Cairo path 边界可以不同；不能把两个段数组互换，也不承诺像素逐点相等。独立 Windows 探针观察到18DIP Latin 部分坐标相差约3.8e-6DIP，511.5DIP 长空白后 glyph 最大约0.00977DIP；这是调用粒度产生的差异，不用像素容差掩盖。消费者需要连续批量轮廓时继续使用原 Path，需要逐 glyph 变换时显式采用 Mapping 的 Path。此入口只提供映射基础，不表示 SVG 的 dx/dy/rotate/textPath 已接通。

映射和批量轮廓共用 glyph / commands / bytes 配额：commands 上限按两个段池之和检查，不为映射重新发放完整额度。Snapshot 的 bytes 包括两个池、拥有源 UTF-8、Glyph / Cluster、原生 cluster 候选、排序下标和元数据同时存活的峰值；原 UTF-16 与 scalar 索引已属于 Layout，不创建另一份未计费全文。Vector 桥同一字节账本继续覆盖中立快照、两份转换数组和两条最终 Path；`owned_bytes` 是当前拥有量，`peak_owned_bytes` 是本次构造峰值。takeMapping 后 Shape 的当前拥有量和映射计数相应减少，构造峰值及已执行工作统计保留。

新增 `limits.clusters` 默认8192、硬上限131072；`limits.work` 默认4194304、硬上限268435456。work 单位覆盖两遍批量段、两遍映射枚举/段、glyph 验证、源复制、UTF-16 索引查找的比较上界及排序上界；桥还累计两条 Path 的转换/复制，不是墙钟或系统字体内部指令计数。原生 glyph 总数仍受同一个 glyph 上限，source-only gap 同样占 cluster 配额。超限分别返回 OutlineCapacityExceeded / OutlineWorkExceeded；桥把字节/命令容量错误归一为 CapacityExceeded，OOM 仍表示底层 allocator 失败。所有限额、取消、原生失败都在候选构造阶段拒绝，无部分发布。

映射需要两遍额外原生枚举，成功时 `native_passes=4`；`mapped_commands` / `clusters` / `mapping_work` 单列成本。每个有界 run / glyph / 段及 foreign 分配前后检查取消；单次系统字体调用与 Cairo 复制不能中断，其不透明 native 缓存 / 临时 path 不包含在 Zig requested-bytes 上限中。不会新增线程、poll 或绘制时排版。

发布前先释放全部临时转换数组与原生轮廓 Snapshot，再检查取消，之后只有无 foreign 调用的所有权转移。此规则同时适用于默认批量路径与映射路径：allocator 在最后一次 scratch free 中设置取消，也返回 Cancelled 并销毁完整候选。正式测试按 allocation ordinal 对每个临时释放点逐一取消，输出 close 的释放点不混入该断言。

`smoke-text-clusters` 使用独立 C oracle 再次枚举同一原布局：DirectWrite 直接检查 clusterMap、Pango 独立检查 log_clusters，再以原位单 glyph 轮廓逐命令精确比较，不调用生产 mapping 入口。另精确比较启用前后的批量段和 cells，覆盖 RTL、ligature、组合/ZWJ、CRLF、多行/wrap/空源和 source-only controls；验证三个 DPI 的独立路径准备、源先关闭、拥有转移、合并限额/峰值减1、所有 Zig 分配失败、取消、线程门禁和析构重入，最终原生引用归零。该测试不以批量与逐 glyph 的像素近似代替映射几何正确性。

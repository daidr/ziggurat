# SVG 文本与定位

`ziggurat_svg` 的文本前端在显式 `Document.prepare` 内规范化字符、解析位置并请求几何。可选 `ziggurat_svg_text.Provider` 使用 DirectWrite/Pango 的同一系统 Layout 提取 glyph 轮廓和完整 glyph cell。普通 SVG 解析与回放不导入字体系统；图片回放不排版、不读取源文本。

文字也支持 [paint-order](svg.md#可选文本轮廓)：`paint-order="stroke"` 将描边放在填充之前，单个实例的填充与描边共用一次完整 shaping。继承到全部 tspan 的共同顺序不拆 shaping；span 自行改变顺序明确拒绝，缓存命中也检查这一条件。实色混排只替换整个 chunk 的 fill 阶段，之后或之前仍对完整轮廓描边一次；不逐 span 执行 fill+stroke。这与 [SVG 文本绘制顺序](https://www.w3.org/TR/SVG/latest/text.html#TextRenderingOrder) 对 chunk 整体 fill/stroke 的规则一致。

```zig
const provider = try svg_text.Provider.create(allocator, process_main_thread, .{});
defer provider.close() catch unreachable;
const document = try svg.Document.parse(allocator,
    "<svg viewBox='0 0 160 80'><text x='8' y='28' font-size='24'>A<tspan>V office</tspan><tspan x='8' y='64'>next</tspan></text></svg>", .{});
defer document.close() catch unreachable;
const image = try document.prepare(scene_allocator, .{
    .main_thread = process_main_thread,
    .width = 320,
    .height = 160,
    .text_provider = try provider.interface(),
});
defer image.close() catch unreachable;
```

系统 provider 的 create/interface/stats/close 与请求均属于进程主线程。上例有两个独立定位 chunk；`A` 与 `V office` 连续使用一个 Layout，第二行使用另一个 Layout。这里的行由显式 y 创建，不由换行字符或隐式换行创建。

## 字符、列表和 chunk

支持同式嵌套 `tspan`、文本节点与 CDATA。每个元素的 `x`、`y`、`dx`、`dy` 是逗号或空白分隔的有限长度列表，沿用 SVG 长度单位；x/dx 百分比参照当前 viewport 宽，y/dy 参照高。列表值在 XML 与 `xml:space` 规范化后按 Unicode scalar 消费，非 UTF-8 byte、UTF-16 code unit 或 grapheme。例如 `😀A` 消费两项；组合附加符、ZWJ 各自消费一项。

一个元素的计数包含所有后代实际输出的字符。对每个字符和每个轴，最近后代元素的有效列表项优先；列表耗尽后仍可使用祖先该字符对应的项。后代覆盖不暂停祖先计数。`display:none` 子树不输出字符、不占位置项；规范化删除的空白不占位置项。未被字符消费的列表尾部仍占列表容量。

首字符创建 chunk；后续字符有显式 x 或 y 时开始新 chunk。省略的轴保留此前的当前文本位置，初值为零。应用绝对坐标后再加该字符的 dx/dy；按当前 chunk 的实际系统 advance 更新 x，LTR 加、RTL 减；y 保留该 chunk 的 baseline。`text-anchor` 对整个 chunk 定位，`middle` 使用实际 advance 中点，start/end 结合方向处理。绝对位置可以在 scalar 边界分开组合序列；这会明确形成独立系统 shaping 请求，不能保留跨 chunk 连写。

没有绝对位置边界的同式文本合并后只 shape 一次。普通 `tspan` 边界和零 dx/dy 不拆 kerning、ligature、Arabic joining、combining 或 emoji ZWJ。实现不按字符均分 advance，不逐 scalar 调字体接口。每个 chunk 的独立轮廓与完整 cell 都按相同位置平移；多 chunk 聚合后沿既有 fill/stroke、渐变、clip、mask、opacity 流程处理，objectBoundingBox 来自完整 cell 的变换后并集。

## 同字体实色填充混排

单个连续 chunk 的嵌套 tspan 可以改变 `fill`、`fill-opacity` 和只影响填充的 `color/currentColor`。范围限于 none、实色与 currentColor；font、direction、anchor、visibility、paint-order、fill-rule、stroke 及其选项仍须与根 text 的计算结果一致。比较共同 stroke 时先解析各自的 currentColor；color 的改变若同时改变有效 stroke，返回 `UnsupportedTextSpanStyle`。CSS、presentation attribute、inline style 与普通继承继续走共同级联，不另建样式解析器。

规范化后所有字符的有效填充相同，继续接管原 batch 轮廓，不因填充请求 Mapping；已有定位调整仍按原合同选择映射。即使整段字符只位于一个不同颜色的后代 span，也以该有效填充绘制。none 与 alpha=0、RGB 相同且合成 alpha 相同的实色可视为相同。真正混排才请求原系统 Layout 的 Mapping，按 source byte 范围把填充关联到原 cluster 的独立轮廓。任何 cluster 横跨不同有效填充时返回 `UnsupportedTextPaintCluster`，不拆 glyph、不按 span 重排，不靠矩形裁剪猜测字形归属。系统映射仍须证明 grapheme 边界；无法证明时保留 `UnsupportedTextPositionCluster`。填充次序保留 provider 在 Mapping Path/Glyph 数组中声明的原 glyph paint order，source 字节或几何 x 坐标都不构成重排依据；临时 source 排序只验证覆盖。系统枚举次序及跨平台差异沿用[轮廓映射合同](text-outlines.md#显式-glyph--cluster-映射)。纯 LTR/RTL 的实际 bidi parity 须一致，否则 `UnsupportedTextPaintBidi`；未绘制的 source-only cluster 也明确拒绝。

同字体实色混排可组合下节既有单 chunk 的 dx/dy/rotate，以及根 text 的非负 textLength 配合默认或显式 spacing。原 Mapping 先且只定位一次，生成完整路径和精确 cell 四角，再按原 source 归属拆出 fill Paths；填充变化不参与 pose、advance 或 anchor。glyph/cluster paint order 保持原 provider 顺序。每个 cluster 的首 scalar 提供角度，内部 scalar 的位移仍按原规则累积到下一 cluster，不能因颜色变化硬拆它。共同描边（含 NSS）、clip/mask/effects 继续作用于完整已定位几何；旋转四角在外层 affine 后才求并集。

单 chunk 在没有有效 dx/dy/rotate 时，也可组合 textLength/spacingAndGlyphs。私有 Horizontal 栈值与普通 batch 共用同一 advance 比例和方向 anchor：x 同步缩放后平移，y 只平移，完整 cell 的 x/width 同步缩放、y/height 保留。原 Mapping 的唯一 Path 先变换一次，再分色；缓存改色不再次缩放。cell 保留各自完整边界，在外层 affine 后分别求四角并集；共同 stroke/NSS 的宽度不随该文字长度比例拉伸。此路线不构造 cluster pose、四角数组或第二次 metadata 排序，既有 Mapping 验证和全部必要几何工作仍计费。

混排 spacing 直接沿用单式 spacing 的同一定位过程：先累计相对位移，再按源逻辑 cluster 分配间距，依据最终 signed advance 区间锚定，最后旋转各完整 cluster；刚性 glyph/cell 与原 provider 绘制顺序保留。压缩与零目标也不拉伸墨迹，交叠按原 glyph 顺序合成。只有一个不可分 cluster 且目标不等于其 advance 区间时，先返回 `UnsupportedTextLengthSingleCluster`；目标相等也不能让不同有效填充穿过这个 cluster，仍返回 `UnsupportedTextPaintCluster`。一次定位后的 use 改色或分区变化不会再调整间距、anchor 或旋转。原 batch、Mapping、旧/候选 fill Paths 和精确四角共用原有字节与累计准备工作额度；spacing 只增加既有的每 cluster 间距计算，不另建一遍排序或定位。

定位模块只在完成 source 覆盖、区间、parity 和坐标验证后构造私有 Positioned 产品。填充模块接管该产品的 Mapping 与四角，不再分配第二份排序数组或重复完整 metadata 验证；另检查非空 glyph 轮廓由 move 开始，确保 fill 分区仍是独立路径。原生 provider 只能交付尚未定位的 Mapping，不能绕过这条私有准备边界。全部必要比较、变换和分区工作仍消耗同一个 text.work。

混排与多绝对 x/y chunk 仍在字体请求前返回 `UnsupportedTextPaintChunks`。混排 textLength/spacingAndGlyphs 若带有效相对位移或旋转（包括 chunk 起点的非零 dx/dy），在字体请求前返回 `UnsupportedTextLengthPositioning`；零位移与完整圈旋转按既有规则视为无调整。百分比长度与后代自有长度调整保留原有前置拒绝。混合 bidi、source-only cluster、不可证明的 grapheme 和不支持的 outline 仍明确失败；带 cluster 定位或 spacing 时沿用 `UnsupportedTextPositionBidi/Cluster/Outline`，未定位或横向伸缩混排沿用 `UnsupportedTextPaintBidi/Cluster`。没有真正填充差异、有效定位调整或 spacing 时继续原 batch。不同填充涉及 paint server 时返回 `UnsupportedTextPaintServer`；原同式 paint server 的渐变/clip/mask 合同保留。字体混排、独立 span stroke、效果与更广组合仍待实现。

填充分区只持有自身 fill Path 和已解析 brush 值。共同 stroke、text 的 vector-effect、opacity、clip、mask 与 objectBoundingBox 仍使用原完整轮廓和完整 glyph cell 并集，不使用每个颜色片的 ink bounds。根 text 的 non-scaling-stroke 继续按最外 viewport 的 host 计算；tspan 自有非默认 vector-effect 仍返回 `UnsupportedTextSpanStyle`，不会把一个 span 的描边策略套到整段。

混排 cache 持有独立 Mapping，几何身份不含具体填充颜色。每个 use 实例先重新校验计算后样式与规范化源，再按实际继承值生成分区；同一分区只更新 fill 值，不重 shape、不复制 Path，也不对已经变换的路径再次 pose。分区边界改变时先准备新候选，再释放旧 Path；已完成实例的像素或 scene brush 不借用随后会改变的缓存值。单一产品拥有 Mapping、fill Parts，以及对齐 cells 或精确四角的唯一分支；候选与旧分区同时计入峰值。普通 batch cache 保留原样式校验与轮廓接管路径；不同模式可能建立独立几何项，不承诺跨模式零请求。

## 单块文本长度

根 text 的非负 `textLength` 配合显式 `lengthAdjust="spacingAndGlyphs"`，在一次完整 shaping 后统一缩放轮廓与完整 glyph cells 的 x 坐标；y、字号及描边宽度保留 user units。anchor 使用调整后的 advance，再应用 x/y/dx/dy。支持现有普通长度单位、零长度与同式嵌套 tspan；不会为 kerning、ligature、连写或组合字符重新分段 shape。轮廓和 cells 在原拥有数组中转换，不增加一份几何候选。

上节的混排横向伸缩使用相同的比例、anchor、零 advance 与精度规则，但其首片拒绝所有有效 dx/dy/rotate。不同颜色仍须在原 cluster 边界分区；单个 cluster 可整体伸缩，不为它引入 spacing 的“没有可调间距”错误，也不允许按颜色把它拆开。非恒等比例时只检查并转换实际绘制的 Mapping Path，arc 返回 `UnsupportedTextLengthOutline`；恒等比例保留原平移能力。已被丢弃的 batch 仍计算命令和字节额度，不对它再做一次无用伸缩。

长度调整只接受一个连续 chunk。百分比、后代自有 textLength/lengthAdjust 或多个绝对定位 chunk，在首次字体请求前分别返回 `UnsupportedTextLengthPercent`、`UnsupportedTextSpanLength`、`UnsupportedTextLengthChunks`。负长度或非法 keyword 也明确失败。只有 lengthAdjust、没有 textLength 时，验证其 keyword，保留自然长度。

默认或显式 `lengthAdjust="spacing"` 使用原Layout的cluster映射：先应用dx/dy，再按调整前signed advance区间和目标长度算出差量，沿逻辑cluster顺序分配到间距；最后cluster的位移恰为差量，RTL符号相反。glyph轮廓、advance与完整cell保持原形，之后再执行anchor和rotate。同式span、纯LTR/RTL以及已有相对位置/旋转可组合，不按scalar拆开ligature、combining或ZWJ。普通无textLength文字不为此建立mapping。

spacing不拉伸glyph。极端压缩允许cluster交叠或次序反转，anchor仍依据最终advance区间；零目标不把实际墨迹压扁。只有一个不可分cluster且目标不同于其自然advance区间时返回 `UnsupportedTextLengthSingleCluster`，不伪造可调整间距；目标相同保留原几何。空文本不请求字体。映射能力、grapheme/bidi证明及预算限制沿用下节合同。

零自然 advance 不能拉成正长度，返回 `UnsupportedTextLengthZeroAdvance`；目标同为零时保留原轮廓。非有限比例或正目标比例下溢为零返回 `UnsupportedTextLengthPrecision`，转换后坐标仍受既有有限边界限制。系统轮廓使用 move/line/cubic/close，自定义 provider 的 quadratic 同样可缩放；其 arc 命令只允许恒等长度转换，否则返回 `UnsupportedTextLengthOutline`，不以近似弧线代替原几何。这些失败完整回收候选，不发布部分图片。

## 明确拒绝的输入

span 可以重申相同样式、使用计算结果相同的百分比字号、覆盖 `xml:space`，并采用上节的有界实色填充差异。改变字体、共同 stroke、visibility、paint-order 等，或添加 span 自有 transform/opacity/clip/mask/overflow 效果，返回 `UnsupportedTextSpanStyle`。绝对位置本身不扩展混排范围。

`visibility:hidden` 的 text 仍校验位置模型和 span 样式，但不调用字体 provider、不生成文字几何；可见子 span 因此会明确报不支持，不能被整个隐藏根静默裁掉。`display:none` 子树沿显示规则整体省略。

连续 chunk 的中途 dx/dy、非零 rotate 与textLength/spacing使用下述显式映射子集。混合 bidi、映射与多绝对 chunk、映射与spacingAndGlyphs等组合仍分别明确拒绝，不借近似 advance 扩展范围。

系统 provider 的字号范围是 1..512，接受水平、无 wrap、单行 chunk。Unicode 强制分行返回 `UnsupportedTextMultiline`。textPath 仅支持下节的精确折线子集；writing-mode、基线族、letter/word-spacing、字体列表、彩色 glyph 外观和完整 SVG 文本标准仍未实现。空白采用 [SVG 1.1 `xml:space`](https://www.w3.org/TR/SVG11/text.html#WhiteSpace)，包括跨 span 的规范化；CSS `white-space` 明确拒绝。此合同不等同完整 SVG2/CSS 文本布局。

## 精确折线 textPath

单个 text 可以只包含一个非空 textPath，后者可包含同字体 tspan 及已有实色填充差异。href 或带正确 namespace 的 xlink:href 必须是本地 `#id`，且目标必须是 path。首片接受一个开口、仅 move/line 的折线；路径数据中的 H/V 与相对命令沿原解析器归一化，重复的零长度 line 不产生距离。startOffset 接受现有长度单位及百分比，省略为零；method 仅 align，spacing 仅 exact，二者均可省略。text-anchor 支持纯 LTR/RTL 的 start/middle/end。

坐标依据 [SVG 1.1 textPath 元素规则](https://www.w3.org/TR/SVG11/text.html#TextPathElement)：目标路径坐标置于当前 text 用户空间，只应用目标自身 transform，忽略目标祖先的 transform/viewBox；text 的 use、外层 transform 和 viewport/viewBox 随后按既有绘制流程应用。目标 transform 只改变路径，不缩放字形。百分比依据这条已变换折线的总长度，数值长度使用 text 用户单位。

定位依据 [SVG 1.1 路径文字详细步骤](https://www.w3.org/TR/SVG11/text.html#TextPathLayoutRules)：先在假想直线上完成一次完整 shaping/anchor，再按距离求 glyph advance 中点的位置；朝向来自 advance 首尾两点的弦。跨折线转角时不以中点所在段的局部切线代替该弦。首尾采样越过路径端点时沿端点切线延长。整个 glyph 的 Bézier 点和完整 cell 四角使用相同刚体变换，保留原 provider glyph paint 顺序，随后才按原 source 分色。共同 stroke/NSS/opacity/clip/mask、whole-text objectBoundingBox 与两种 paint-order 沿用现有合同。

此首片要求每个 cluster 恰含一个 glyph；一个 glyph 对应多个 scalar 的 ligature 仍是不可分割的整体，不同有效填充切入该 cluster 继续失败。多 glyph cluster 返回 `UnsupportedTextPathCluster`，混合 bidi 沿用 `UnsupportedTextPositionBidi`，零 advance 返回 `UnsupportedTextPathZeroAdvance`。任何 glyph 中点越过有限路径范围返回 `UnsupportedTextPathOverflow`，不把它静默放到错误位置；这比标准的末端省略规则更窄。弦退化为零返回 `UnsupportedTextPathOrientation`，累计距离无法严格前进返回 `UnsupportedTextPathPrecision`。

曲线/arc/close/空或退化路径返回 `UnsupportedTextPathGeometry`，多子路径返回 `UnsupportedTextPathSubpaths`；目标不是 path 返回 `UnsupportedTextPathTarget`。pathLength、直接 path 属性、side 等未实现属性仍明确拒绝。多 textPath、路径外的普通文字、textPath 嵌在 tspan、显式 x/y/dx/dy/rotate、textLength、分段字体和独有效果均不属于本片。markup/目标几何限制在字体请求前检查；依赖原字体映射的 cluster、零 advance 和越界限制在拥有候选内检查，失败完整回收。

私有 metric 只在显式 textPath 准备时分配，路径解析、两次有限扫描、每次二分距离查询都计入累计 text.work；解析命令受 path.commands 限制，原路径、metric、Mapping、pose/cells、旧候选与像素同时计入 scene live/peak。metric 不进入 Prepared，绘制只回放独立图片。混排 cache 命中重新验证路径和样式、仅重建 fill 分区，不二次 pose；普通文字不增加 Mapping、metric 或分配。没有新增字体请求入口、线程或 I/O。

## 容量、所有权与失败

`PrepareOptions.limits.text` 的默认值与硬上限如下。除 cache 项和规范化 source bytes 外，计数累计本次准备的每次文字几何使用，包括复用同一几何的实例，以及 clip/mask 等为整体 bbox 触发的几何查询；不是仅统计最终可见文字元素数。

| 字段 | 默认 | 硬上限 |
| --- | ---: | ---: |
| instances | 64 | 256 |
| source_bytes | 65536 | 1048576 |
| glyphs | 8192 | 65536 |
| commands | 65536 | 1048576 |
| characters | 8192 | 65536 |
| position_values | 16384 | 262144 |
| chunks | 256 | 8192 |
| paint_runs | 256 | 8192 |
| work | 4194304 | 134217728 |

超限分别返回 `TextInstancesFull`、`TextSourceExceeded`、`TextCapacityExceeded`、`TextCharactersFull`、`TextPositionsFull`、`TextChunksFull`、`TextPaintRunsFull` 或 `TextWorkExceeded`。paint_runs 限制混排 source 分区和实际 fill 分区，沿用上述几何使用的累计边界；普通 batch 不计此项。位置前端先完整校验同一 text 子树再 shape；场景后续节点失败会回收整个候选，不发布半张图片。总 scene bytes 限额同时覆盖规范化 source/list/chunk/paint run、cache、Layout、轮廓、聚合数组、fill Parts 与最终候选；替换分区时旧数组与新候选同时计峰值。仍需给宿主保留的旧图片另计预算。原生 opaque 对象开销沿用[文本轮廓合同](text-outlines.md)。

没有 span 的 cache entry 不复制完整 Style；含 span 的普通 batch entry 另存继承样式，混排命中则重新校验子树，避免不同 use 上下文复用先前被允许的 span。普通单 chunk 直接接管 provider 的轮廓与 cells，不为纯 markup 增加第二份轮廓；多 chunk 才建立有界聚合。`Prepared.stats()` 公开 text_requests、text_chunks、text_characters、text_position_values 等累计数，另有独立的 text_paint_runs 与 text_paint_commands；text_commands 继续表示完整几何，不将 fill Parts 混入其中。

Provider 的稳定 lease 贯穿首次场景分配、相邻请求间隙、失败回滚和最终临时资源回收；此间系统 Provider.close/stats 返回 Busy。自定义 provider 没有 lease 时，宿主必须将其 context 保留至整个 prepare 退栈。成功结果拥有独立 pixels，Document 和 Provider 可先关闭；Buffer/renderer 持 image lease 时 image.close 返回 ResourceInUse。取消在有界准备阶段检查，不抢占一次系统字体调用。

## 连续 shaping 的相对位置与旋转

同式、水平、单连续 chunk 可以在 scalar 上指定 dx/dy/rotate，同时保留原系统 Layout 的完整 shaping。[SVG2 定位规则](https://www.w3.org/TR/SVG2/text.html#TextLayoutAlgorithm)区分列表使用的 Unicode scalar 与实际定位的 typographic character：这里以系统 cluster 为单位，且系统 provider 先验证其边界不切入已有 grapheme。一个 cluster 可以含 ligature 的多个 scalar 或组合/ZWJ 的多个 glyph；没有逐 scalar shaping、平均 advance 或按 ink 推字符。

同 cluster 的首 scalar 提供其 dx/dy 和旋转，其余 scalar 的 dx/dy 累积到下一 cluster；尾 cluster 没有后继时，不再移动已经定位的 glyph。旋转取首 scalar 的有效值。rotate 列表最后一项在该元素的剩余字符上重复，最近 span 优先，祖先仍消费相同字符槽。子 span 结束后恢复祖先对应项。全零、完整圈数或被后代完全覆盖的旋转不请求 Mapping；普通文字仍使用原批量轮廓，不增加映射数组/原生映射查询。

原 glyph pen 和 signed advance 给出真实 cluster alignment point。LTR 取其 advance 区间左端，RTL 取右端；按源逻辑序累计相对位移，保留原生视觉位置。text-anchor 依据调整后的 advance 区间求边界，不根据旋转后的 ink。旋转围绕已加相对位移的当前文本位置，不围绕 ink/cell 中心，也不旋转后续 advance。每个 glyph 轮廓仅做同一 cluster 的刚性变换。完整 cell 保留四个角，再随外层 affine 变换后求并集；不会先转成 AABB 再错误扩大 objectBoundingBox。

此首片只接收纯 LTR / 纯 RTL runs（实际 bidi parity 须与方向一致）。混合 bidi 返回 `UnsupportedTextPositionBidi`；系统 cluster 切入 grapheme、未绘制的 source-only cluster 或一个 cluster 中不能证明的 baseline 组合返回 `UnsupportedTextPositionCluster`。具体字体将 ZWJ 分成多个 cluster 时同样拒绝，不把拒绝记作 ZWJ 绘制成功。含 soft hyphen / bidi 控制字符的映射请求在字体请求前返回 `UnsupportedTextPositionControls`。保留原单行、单色轮廓及字号范围，未扩展字体混排或彩色 glyph 外观。

cluster 相对定位/旋转映射与多个绝对 x/y chunk 返回 `UnsupportedTextPositionChunks`，与textLength/spacingAndGlyphs返回 `UnsupportedTextLengthPositioning`；均在首次字体请求前拒绝。textLength本身的多chunk仍先返回 `UnsupportedTextLengthChunks`。spacing可与单chunk定位映射组合，无映射的既有多chunk和单chunk spacingAndGlyphs保持原合同。无有效相对位移/旋转的混排 Mapping 可以走上节独立横向伸缩路线。mixed font、曲线路径文字和更广组合继续是后续子项。

### Provider 映射能力及拥有关系

SVG 中立类型只依赖 Vector，不导入系统文字模块。原有自定义 provider 不需修改：`supports_mapping=false`、`Request.include_mapping=false`、`Result.mapping=null` 为默认值。需要映射而 provider 无此能力时，在 shape 调用前返回 `UnsupportedTextMapping`。系统 provider 显式声明能力，仅在请求时从同一 Layout 提取映射。

能力提供者返回额外拥有的 `text.Mapping`。`Mapping.adopt(allocator, Owned{path,source,glyphs,clusters})` 仅成功时接管整个 payload，不复制数组；失败仍由调用者回收。source 是独立 UTF-8；cluster 范围引用 source / glyphs / 自己的 Path commands，glyph 记录原 pen、advance 和完整 cell。它与 Result 原批量 Path 分离，两个 Path 不能别名，所有数组与 shell 必须使用所给 allocator 和 owner。`view()` 仅在准备期间借用；`takePath()` 消费元数据和壳、转移 Path；`close()` 消费全部拥有内容。不能在成功交接后继续使用 provider 保存的原拥有引用。

系统 provider 为中立边界显式复制映射 Path / 元数据，释放可选文字模块拥有体。旧批量 Path 保持原样；映射消费方只操作映射 Path。该瞬时双路径及复制数组、源文本、Layout、scalar records、排序/pose、四角 cell 和最终候选都在同一 scene bytes 峰值账本内。commands 配额包括映射请求产生后丢弃的批量命令、每个实例的完整几何及额外 fill Parts 命令；缓存复用仍占实例命令/glyph 配额。`text_commands` 是实例完整几何命令，`text_paint_commands` 是额外填充命令，`text_accounted_commands` 是实际配额累计，`text_mapping_requests` 是显式映射调用数。

Request.max_work / Result.work 使系统映射和中立复制工作使用剩余 scene text.work，而非每次重新获得完整额度；cache 另外累计 scalar、排序、几何与四角变换工作。native font 的不透明内部工作/存储限制仍沿用文本轮廓合同。没有新增线程、磁盘访问或 paint 时排版。

全部候选保持原生/allocator 重入门禁。相对位置消费方转移 Path 并先回收 Mapping metadata；混排消费方把完整 Mapping 保留到私有 cache 关闭，以便跨 use 重新关联填充。批量 source 几何在 cache 提交前释放。Document.prepare 等像素或 sample-color 后端全部 scratch 析构返回后，在 Document/Provider pins 仍有效时再次检查取消。最后一次 foreign free 才取消也不发布新图片；失败完整释放候选，已存在的旧 Prepared 不受影响。

## 验证边界

`test-svg` 覆盖同式嵌套、规范化 scalar/list、祖先位置覆盖、RTL/anchor、无效输入、累计容量与逐次分配失败；混排另用独立矩形路径验证颜色/透明度、整体 stroke 顺序、NSS、bbox/effects、ligature 内部 scalar 位移携带、反 source 顺序的透明 RTL、旋转 cell 四角经外层 shear 后的 bbox、跨 use 改色与分区替换且不二次 pose，并在每次 foreign alloc/free 触发取消后检查 live=0。`smoke-svg-text` 用实际系统 Layout 的独立轮廓、分开 text 元素与 glyph cell 并集作 oracle，检查跨 span 的 kerning/ligature/Arabic/combining/ZWJ、绝对 chunk、省略轴、objectBoundingBox 渐变/clip/mask；混排及带定位混排 oracle 直接按同一完整 Layout 的原 glyph paint order，将原始 pen/advance/source 解析成独立位移与旋转，再写成显式不同颜色 Path，再对照整体 stroke 的两种顺序，不逐 span 重 shape。覆盖 pixel/sample_color 及 1/1.5/2 倍尺寸，并回放到 GDI/Cairo；启用 GPU 时另验 Windows hardware/WARP。具体新增范围的运行状态应以验证记录为准，此类自动化回归不证明人工视觉质量。

```text
zig build test-svg smoke-svg-text -Doptimize=ReleaseSafe -j2
zig build smoke-svg-text -Doptimize=ReleaseSafe -Dgpu=true -j2
```

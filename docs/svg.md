# SVG 文档与准备图片

`ziggurat_svg` 是可选纯 Zig 模块，依赖路径与绘制资源 ABI。它拥有文档，在显式准备阶段产生独立的预乘 BGRA 图片，再沿现有 ImageView 上传/回放。核心、普通 UI 和不使用 SVG 的应用不导入解析器或承担图片准备成本。

当前切片已有有界 XML、path/rect/circle/ellipse/line/polyline/polygon、groups、内部 use/symbol、局部仿射、嵌套 viewport、viewBox/preserveAspectRatio、颜色/currentColor、样式级联、填充/描边/dashes、linear/radial gradient 和真正的组 opacity。局部 clipPath、alpha/luminance mask、双圆径向几何及显式 provider 驱动的单行文本轮廓已有明确子集；两种合成模式的抗锯齿合同见下文，仍不把这一切片标为完整 SVG 支持。不能处理的元素、引用或绘制特征明确失败，避免交付缺少关键内容的图片。显式准备资源驱动的嵌入栅格图片已有[有界合同](svg-images.md)；[有界patterns](svg-patterns.md) 已有显式 user-space 实色几何子集，[双端markers](svg-markers.md) 已有有界开放折线子集；更广 markers、filters 和脚本继续实施。

## 拥有与准备

```zig
const document = try svg.Document.parse(allocator, bytes, .{});
defer document.close() catch unreachable;
const image = try document.prepare(allocator, .{
    .main_thread = process_main_thread,
    .width = 64,
    .height = 64,
    .current_color = .{ .r = 32, .g = 64, .b = 128 },
});
```

Document 复制 source、decoded attributes/text 和有界树；node 查询返回只读借用，不能跨 Document.close 保存。Document 的 parse/prepare/query/close 使用同一个 owner。prepare 在所有候选分配、provider 回调与回收期间持 Busy 门，重入 prepare/close 失败；最终 close 在任何外部分配器 free 前撤销入口，递归访问返回 Closed。Prepared 与 Document 独立，可以先关闭源文档；Prepared 地址/descriptor/pixels 在借用期间稳定。准备可以在宿主独占的 worker 完成，显式成功 post 后主线程 adopt；失败 post 由 worker 释放。文本 provider 另有线程合同，不能把主线程系统 provider 交给 worker。模块不创建线程、不投递、不等待 UI。

`width/height` 指明确的输出物理像素尺寸。viewBox 按 preserveAspectRatio 的 none/九种对齐/meet/slice 映射到该画布；没有 viewBox 时使用 root 的 width/height 或本次输出尺寸作为本地画布。它是图片准备接口，不是 HTML/CSS 的 replaced-element 排版器。改变尺寸、颜色、文档或样式需要新的显式准备；普通绘制只读缓存图片。颜色以编码 sRGB 字节解析，支持标准 named colors、hex/RGB/HSL 及 alpha；不将其当作完整色彩管理。

主线程获取 `image.view()`，经 `Context.uploadImage` 或 renderer.uploadImage 显式驻留，再用 Frame.image/Buffer.image 绘制。Frame 或驻留仍持有 Lease 时，close 返回 ResourceInUse。当前结果只包含一个像素层；需要持续缩小的场景应按目标尺寸准备，不声称已有 SVG mip 或无限精度的动态矢量回放。

根 svg 的 transform 位于 viewBox 映射之外；嵌套 viewport 的 transform 同样作用于其整个 viewport。

`vector-effect` 支持 `none` 与 `non-scaling-stroke`，参与 presentation attribute、CSS 和 inline style 的同一级联，支持 inherit/initial/unset。该属性不隐式继承；例如 g/use 上的值只在目标显式 inherit 时传到其几何元素。其他 vector effect 值和组合明确返回 UnsupportedVectorEffect。text 整体轮廓可以使用，tspan 自有非默认 effect 仍返回 UnsupportedTextSpanStyle，不把它静默施加到整个文本。

non-scaling-stroke 将 centerline 经 viewBox、嵌套 viewport 和元素仿射映射到最外 SVG viewport，再在该 host 坐标构造描边宽度、cap/join、dash 和 offset。最外 svg 自身的 transform 等效于其父级变换，最后映射已经构造的 host 轮廓，仍可缩放或 shear 这份轮廓。准备遍历在该 root transform 存在时显式传递两份矩阵，use/symbol、clip 和 mask 内容的 object/content 坐标变换分别更新这两个映射；不通过逆矩阵、包围盒或临近节点猜测 host。没有 root transform 的默认路径只组合一份矩阵。

填充、原几何 objectBoundingBox、stroke paint 的 gradient 坐标、clip/mask 与整体 opacity 保持原有坐标和次序。奇异 CTM 的该描边不绘制；binary64 系数的两个乘积在 binary128 中精确比较，避免下溢或相近乘积抵消把非零行列式误判为零。依据 [SVG2 non-scaling-stroke](https://www.w3.org/TR/SVG2/painting.html#VectorEffects) 与 [host coordinate space](https://www.w3.org/TR/SVG2/coords.html#VectorEffects)。

本图片准备 API 的最外 viewport 是 width×height **输出物理像素**，没有独立 DIP/scale 参数。因此没有额外 root transform 时，改变 prepare 的尺寸或 viewBox 后，width=2 的 non-scaling-stroke 仍为2个输出像素；百分比 stroke-width/dashes 先按原近邻 viewport 的对角参考解析。准备成功后的 BGRA 图片不再保存 SVG 行为；将同一 Prepared 放大2倍回放时，它的描边像素也放大2倍。按新尺寸重新 prepare 与缩放已有图片是两个明确操作，不能把这项能力理解成运行时持续保持 DIP 描边宽度。

组 opacity 在子项完成 source-over 后乘整组 RGBA 一次，重叠区域不会按子项重复衰减。fill/stroke opacity 各作用于本次 paint。最终源图片保留 alpha，普通窗口背景在回放时才参与混合。

`PrepareOptions.compositing` 默认 `.pixel`，保留逐 paint 量化 A8、在 BGRA8 工作面合成的结果。显式选择 `.sample_color` 时，准备阶段先编译拥有型几何与索引化场景，再使用 32×1 物理像素条带、每像素16个预乘 f64 BGRA lane 合成，最终一次量化为 BGRA8。普通 paint 仍只回放这张独立图片；不会再读 XML、匹配 CSS、展开引用或构造路径。

新模式把 group/viewport/clipPath 的裁剪留在共同采样域，完成组后才应用其裁剪和 opacity；同一边缘不会因多个重叠子形状而重复衰减。它是**样本颜色合成**：渐变颜色仍在每个物理像素中心求一次，再广播到16个覆盖 lane，不是渐变颜色的面积积分。mask 仍先解析成连续的每像素 alpha，不宣称实现16 lane 的 mask 颜色场。改变模式是显式准备工作，不影响默认应用的内存与合成策略。

场景编译只存在于本次准备中，节点保存数值索引，普通 brush/gradient 保存按值描述，图片 brush 指向本次准备拥有的快照与采样描述；完成后全部释放，最终 Prepared 不借用场景或源文档。每个几何体拥有四个子行的 crossing 缓存，同一 y 的横向条带复用；clip DAG 按条带代数延迟缓存成功结果，不遍历清空未用 clip。代数不回绕，耗尽返回 GenerationExhausted。所有这些缓存遵循创建线程的 owner 合同，不提供并发查询。

## 样式与内部引用

style 元素支持 text/css、XML text/CDATA 与有界 CSS 注释；presentation attributes、style rules 和 inline style 按 specificity、source order、important 选出每个属性的唯一结果。属性支持 inherit/initial/unset；opacity/display/overflow、clip-path/mask/mask-type 和 stop-color/stop-opacity 不隐式继承；clip-rule 继承。选择器支持 ASCII type、通配符、id、class、有限 compound 与逗号列表；同一 node 最多64个 class token、每个 selector 最多8个 class。Combinators、pseudo/attribute selectors、escapes、at-rules、变量与外部样式表明确拒绝。inline style 的注释暂不支持；不能被安全解析的注释放置返回错误。样式规则不逐帧匹配。

use 只接受本文件 #id；xlink:href 必须有正确命名空间。独立的排序 ID 索引拒绝重复/空白 ID，查找为 O(log IDs)。x/y 在 use 的局部 transform 之前作用，引用继承自实例的 use；源定义的祖先不参与实例继承。同文件简单选择器仍作用于实例。symbol 和 svg 建立新的百分比参考系，use 的显式 width/height 只覆盖这些 viewport 元素的尺寸。嵌套 viewport 默认裁剪，overflow:visible 可关闭；viewport 与路径裁剪在共同的采样域求交，组 opacity 在子项完成后作用一次。目标尺寸可以为非四字节对齐宽度，A8 stride 与输出 BGRA stride 分别计算。

引用不克隆 DOM。固定64层展开栈检测直接、间接和祖先循环，另有 reference_depth 与整个准备的 node_visits 配额，分支引用不能绕过累计限制。外部文件/网络/data URL 不进入引用解析，URI percent escape 暂时明确拒绝。未知或错误类型的 paint server 使用显式 paint fallback；不支持的 server 元素本身仍返回错误。

## 可选文本轮廓

`paint-order` 支持 presentation attribute、CSS 级联与继承，以及 `normal`、`inherit`、`initial`、`unset`。显式 fill/stroke/markers 依次排列，省略项按默认顺序补到末尾；例如 `stroke` 在 fill 之前描边。无重复关键词，空值/逗号/未知项明确 `InvalidPaintOrder`。组 opacity、clip 和 mask 仍在整体内容上作用一次；像素和逐采样模式使用相同顺序。markers 槽现支持[双端 marker 引用的有界子集](svg-markers.md)，先 start 后 end；marker-mid 与更广几何/内容继续实施。语义依据 [SVG 2 paint-order](https://www.w3.org/TR/SVG2/painting.html#PaintOrder)。

纯解析器仅定义 `svg.text.Provider`，不导入字体系统。遇到 text 而没有 `PrepareOptions.text_provider` 时返回 TextProviderRequired。可选 `ziggurat_svg_text.Provider` 拥有一个系统布局 Engine，使用同一 DirectWrite/Pango Layout 的实际 glyph run 提取单色轮廓，不在绘制时重新 shape。provider 的创建、请求和关闭要求进程主线程；纯 provider 可以另行实现符合其 owner 合同的离线几何。

```zig
const provider = try svg_text.Provider.create(allocator, process_main_thread, .{});
defer provider.close() catch unreachable;
const image = try document.prepare(scene_allocator, .{
    .main_thread = process_main_thread,
    .width = 128,
    .height = 48,
    .text_provider = try provider.interface(),
});
```

支持 text 与同式嵌套 tspan 的 XML 字符数据/CDATA、x/y/dx/dy 长度列表、单字体 family 或 generic、font-size/weight/style、direction、text-anchor 与 xml:lang。列表按规范化后的 Unicode scalar 消费，最近 span 的有效项覆盖祖先同一项，祖先计数仍继续。绝对 x/y 切出独立 chunk，省略轴保留当前坐标；没有绝对定位边界的同式文本合并为一次系统 shaping，DOM 边界不拆 kerning、连写或 emoji 序列。CSS 级联和百分比 font-size 使用已经解析的父样式；start/end 根据段落方向定位，middle 使用 advance 中点。根 text 的单连续 chunk 另支持显式 textLength/spacingAndGlyphs，完整轮廓与 glyph cells 在 shaping 后同步横向拉伸，anchor 使用目标长度；默认或显式spacing通过原cluster映射调整间距、保留glyph形状；百分比、嵌套或多chunk长度明确拒绝。同式单 chunk 可显式采用原布局的 glyph/cluster 映射处理中途 dx/dy 和 rotate，保留完整 shaping、真实 pen/advance 和旋转 cell 四角；无实际调整仍使用原 batch。映射与spacingAndGlyphs、多绝对chunk、混合bidi、不能证明的cluster/grapheme关系明确拒绝；单chunk spacing可与相对位移/旋转组合。span 字体、独立 stroke 及自有变换/效果尚未接通；有界实色填充差异见下段。详见 [文本定位合同](svg-text.md)。

同字体、单连续 chunk 另支持 tspan 的 none/实色/currentColor 与 fill-opacity 差异。没有其他定位或 spacing 调整时，有效填充相同仍使用原 batch；真正混排按同一完整 Layout 的 cluster 轮廓分配填充，不按 span 重 shape，跨 cluster 内部的不同有效填充明确失败。分区只替换 fill 阶段，整体 stroke/paint-order、glyph cell bbox、opacity/clip/mask 以及根 text 的 non-scaling-stroke 保持原语义。可组合现有单 chunk dx/dy/rotate 和根 textLength 的默认/显式 spacing，完整 Mapping 只定位一次后再分色，旋转 cells 保留四角，缓存改色不再次 pose 或分配间距。无有效 dx/dy/rotate 的单 chunk 也支持 spacingAndGlyphs，与普通 batch 共用横向 placement，完整 Mapping/cells 只伸缩一次、描边宽度保留，之后才分色。spacing 的单 cluster 没有可调间距时明确拒绝不等目标；压缩保留刚性轮廓与原 glyph 绘制次序。多绝对 chunk、伸缩与有效相对定位/旋转、混合 bidi、分段 paint server、不同共同 stroke/metrics 和 span 自有效果仍拒绝；完整边界与预算见[文本合同](svg-text.md#同字体实色填充混排)。

单 textPath 首片支持本地 #path 的精确开口折线、目标自身 transform、startOffset 长度/百分比与方向 anchor。每 cluster 仅一个 glyph，原布局只 shape/pose 一次，再按 source 分色；跨转角朝向采用 advance 首尾点的弦，glyph/cell 同步刚体变换。曲线、多子路径、闭合路径、末端省略、显式定位/textLength 组合等仍明确拒绝。支持与错误范围、坐标依据及预算见[精确折线路径文字](svg-text.md#精确折线-textpath)。

系统 provider 接受 1..512 的字号和水平单行 chunk；Unicode 强制分行明确返回 UnsupportedTextMultiline。未实现曲线路径文字、writing-mode、字距/词距、基线族、字体列表或完整 SVG 文本布局；这些输入返回错误。彩色字形只提取系统提供的单色轮廓，不保证彩色字体外观。

空白处理明确采用 [SVG 1.1 的 xml:space](https://www.w3.org/TR/SVG11/text.html#WhiteSpace)：先由 XML 将字面 CRLF/CR 归一化为 LF。默认 default 删除 LF、tab 转普通空格，跨文本/CDATA/同式 tspan 节点折叠普通空格并去除首尾空格。因此 `a\nb` 为 `ab`，`中\n文` 为 `中文`，`a\tb` 为 `a b`。preserve 将 LF/tab 各转一个普通空格，保留首尾及连续空格，不产生新行；属性可以从祖先继承或在当前元素覆盖，同一 text 的 use 实例按实际空白模式分别缓存。字符引用的 LF 使用同一处理；字符引用产生的 CR 仍明确拒绝。

所有 CSS white-space 声明（包括 normal/inherit）继续返回 UnsupportedTextWhitespace，避免将 XML/SVG 1.1 规则混同 [SVG2/CSS 的 segment-break 规则](https://www.w3.org/TR/SVG2/text.html#WhiteSpace)。这不表示完整的跨语言 CSS 空白支持。

轮廓可用于 solid fill/stroke、paint server、普通 transform/use、text clipPath 及直接 use→text 裁剪。系统 provider 同时输出完整 glyph cell，以实际 glyph advance/offset、字体 ascent/descent 求 objectBoundingBox；包含 text 的容器和引用先变换每个单元的四角，再求并集。路径描边、渐变、clip/mask 和 opacity 沿同一现有几何流程。`pixel` 和 `sample_color` 保持各自的合成规则。

自定义 provider 可省略 `Result.cells`；这时普通填充、userSpaceOnUse 等不需要文字边界的绘制仍可用，需要 objectBoundingBox 则明确 UnsupportedTextBoundingBox。提供 cells 时须每 glyph 一项，与 Path 使用同一 allocator，成功后一并转移，SVG 在关闭 Path 前释放它们。数组、转换后的缓存与逐单元四角工作量累计到整个场景预算，不以 ink bounds 替代完整单元。

`Provider.lease` 是可选稳定 owner pin，贯穿 prepare 的首次分配、所有 shape、回滚及最终缓存释放。系统 provider 内置该保护，期间 stats/close 返回 Busy。自定义 provider 若不提供 lease，宿主必须让 context 存活至整个 prepare 返回；不能在相邻 shape 之间或最后 cache free 时销毁它。准备结果只保留独立图片，返回后即可关闭 provider。

provider 调用获得借用 request 与本次 scene allocator，成功时转移独立 Path 和可选 cells；它们必须属于当前 owner、使用该 allocator、具有有限 metrics，并满足剩余 glyph/command/bytes 配额。仅转移的资源可保留 allocator context，provider 不能在本次 prepare 以外保存请求或分配器。相同 owner 的无效结果立即回收；错误 owner 的结果不能合法跨线程销毁，仍由违规 provider 负责。系统 adapter 在整个场景准备和最终候选 free 期间拒绝 close/stats 重入。

每次 prepare 有独立、固定容量的 text cache，同节点的相同 resolved font/anchor/viewport/空白模式复用轮廓，含 span 时另核验继承样式，实例 transform 在外层应用。cache 不跨调用保存字体或源文档，所有最终像素独立，Document/provider 可在回放前关闭。默认最多64项（硬上限256）、规范化 UTF-8 64KiB（1MiB）、累计 glyph8192（65536）、累计 path commands65536（1Mi）、Unicode scalar8192（65536）、定位/旋转列表值16384（262144）、chunk256（8192）和 text_work4Mi（128Mi）。命中同样计实例 glyph/commands/scalar/列表值/chunk 与查找工作，不能靠 use 绕过总额；Stats 公开这些计数及 source_bytes/work/requests。Layout、outline snapshot、路径转换数组、cache 和场景候选均纳入同一 Zig live/peak 预算，原生字体/路径 opaque 临时开销按 [轮廓模块合同](text-outlines.md) 单列。取消在有界候选阶段检查，不能抢占一次系统调用。

## 渐变

linear/radial gradient 支持内部模板链、stop 样式、currentColor、stop opacity、pad/repeat/reflect、gradientTransform、userSpaceOnUse 和 objectBoundingBox。后者使用路径几何的解析包围盒，包含 Bézier 导数根和旋转椭圆极值，排除 stroke；不从低分辨率图片估计边界。box 的零宽/高不绘制该渐变。重复 offset 在右侧采用最后一个 stop；递减 offset 夹到前一 stop，线性零长度使用最后颜色。

stop 在 straight RGB/alpha 中插值，再转最终预乘 BGRA；支持 sRGB 或显式 linearRGB 插值，不与 UI 渐变的预乘颜色插值混淆。

径向几何按 SVG2 双圆形成的圆锥求值：支持内/外焦点、非零 fr、相交圆、缩小圆、等半径不同中心、椭圆化和局部仿射。对每个物理像素中心解析圆周方程，选择半径非负的最大参数 t；没有合法圆周的区域透明，不把外焦点强行移回终点圆。两个完全相同的圆不绘制；r=0 使用末色。点焦点恰位于终点圆周时，不能由有限圆周覆盖的一侧以及焦点自身，在 pad 下取末色。repeat/reflect 的该极限支持所有 stop 的 alpha 相同，或所有 stop 的 RGB 相同而仅 alpha 改变：按 offset 加权平均，在 color-interpolation 指定空间求值后转换为预乘 BGRA。RGB 与 alpha 都改变的周期平均明确返回 UnsupportedRadialAverage。pad、非相切几何不受该限制。

固定几何使用二进制幂归一化，在准备阶段分类二次项 `A=dx²+dy²-dr²`。坐标与半径减法用 TwoDiff 保留残差；高位平方差用 max-axis 分解 `(max(|dx|,|dy|)-|dr|)×(max(|dx|,|dy|)+|dr|)+min(|dx|,|dy|)²`，避免把极小的垂直分量丢在两个大平方之间。没有减法残差时，该表达式的符号/零判定有二进制有效位证明；有残差时，向外舍入的区间包含所有遗漏的交叉项/残差平方。区间跨零、归一化非零系数不能存为 f64 或中间值溢出时，明确返回 UnsupportedRadialPrecision，不用 epsilon 把近相切当作相切。它保证接受输入的分类，**不把任意 f128 运算或逐像素根称为精确算术**。分类是每个渐变固定的准备成本，无堆分配。

非零焦点圆与终点圆恰内切、导致 A=0 的奇异几何暂明确返回 UnsupportedRadialFocus，保留为后续子项。[SVG2 的相切极限文字](https://www.w3.org/TR/SVG2/pservers.html#RadialGradientNotes)明确针对点焦点；当前不把该例外扩展成非零焦点圆共同切点的颜色。逐像素仍是无分配 f64 稳定二次根/线性求解。颜色在物理像素中心求值，轮廓使用路径的4×4覆盖；不宣称解析面积积分。不可逆变换不产生 paint；极端不可表达的参数/重复周期返回明确 precision 错误。

周期平均的限制有可检验的原因：透明红到不透明蓝的一段，在 sRGB 中“先平均 straight 通道再预乘”给出预乘 RGBA `(1/4,0,1/4,1/2)`；“积分每个位置的 straight 插值后预乘颜色”是 `(1/6,0,1/3,1/2)`；“平均已预乘的 stop 端点”是 `(0,0,1/2,1/2)`。SVG 的普通 straight 插值和极限中的 weighted-average 文字不能单独确定一般变量 alpha 要取哪一个，因此当前不替它猜测。RGB 恒定时，`E[a×RGB]=E[a]×RGB`，三式一致；红色 alpha 0→1 得预乘 BGRA `(0,0,128,128)`，灰色 #808080 alpha 0→1 在 sRGB/linearRGB 都得 `(64,64,64,128)`。alpha 恒定的原有选定空间平均保持不变；不以数值 epsilon 扩大这两个子集。

## 几何裁剪与蒙版

`clip-path` 和 `mask` 接受 `none` 或单个本文件 `url(#id)`，可以来自 presentation attribute、CSS 或 inline style；外部 URL、多层 CSS mask shorthand 和 paint fallback 不属于此接口。缺失、错误类型、直接/间接循环引用明确失败。定义的样式从定义处祖先计算，use 实例继承仍来自该实例。

clipPath 支持 path、基本 shape、具备 provider 时的 text 和 use。规范要求其中的 use **直接**引用 path、text 或基本 shape；g/symbol 目标与 use 间接链以 InvalidClipUseTarget 拒绝。文本仍遵守上一节的单行/属性/bbox 边界。见 [CSS Masking 的 clipPath 内容限制](https://www.w3.org/TR/css-masking-1/#ClipPathElement)。

clipPathUnits 默认 userSpaceOnUse，也支持 objectBoundingBox；后者使用目标路径或容器展开后的解析几何包围盒，不包含描边、裁剪、蒙版、opacity。子形状按 clip-rule nonzero/evenodd 填充，忽略其颜色、描边和 opacity；display/visibility 仍控制是否贡献几何。clipPath 的 transform 和自己的 clip-path 受支持；其自身 mask 属性目前返回 UnsupportedClipContainerEffect。[CSS Masking §6.1](https://www.w3.org/TR/css-masking-1/#ClipPathElement) 定义的是子几何 silhouette 的并集及嵌套裁剪的交集，没有给出自身 mask 产生连续裁剪值后如何组合的算法；当前不从属性的适用元素范围推导额外合成语义，也不把这项拒绝直接归类为已确认的标准能力缺口。

两种模式都使用同一物理像素的 16 个 4×4 采样位；同一个 clipPath 内做位或，嵌套 clipPath/viewport 做位与。默认 `.pixel` 为裁剪显式准备 `retain_samples` 路径快照，实际 paint 的覆盖位与累计裁剪位相交后才转 A8。因此重复形状和重复裁剪不会把同一几何边缘的覆盖率再次相乘。该模式的样本平面按四像素对齐行跨度分配，每平面 `aligned_width × height × 2` 字节，加入整个准备的 live/peak 预算，准备结束全部释放，不进入最终图片。

默认模式的每 paint 独立 A8 量化会保留一项明确差别：同一组内两个完全重叠的不透明 paint，在半覆盖的裁剪边缘会累积到 alpha 192。显式 `.sample_color` 把裁剪与每个几何体的覆盖保留在16个 lane 中，组完成后才量化，这个例子得到128；嵌套或重复相同边缘仍为128。测试固定两种模式各自的结果。新模式只持有当前条带及有界组层的颜色数据，不分配全画布16份颜色平面。

maskUnits 默认 objectBoundingBox、maskContentUnits 默认 userSpaceOnUse；两者分别选择蒙版 region 和内容坐标。region 默认 x/y=-10%、width/height=120%，负尺寸失败、零尺寸为空；region 在 mask 内容准备时使用相同的采样位裁剪，避免与自身形状的重合边缘再次乘 A8。objectBoundingBox 中只接受单位数字或百分比；用户坐标允许现有长度单位。

mask 定义自身不属于 [CSS Transforms 的 SVG transformable 元素](https://www.w3.org/TR/css-transforms-1/#transformable-element)，因此其 transform 不列为标准待实现功能；当前严格子集遇到该属性返回 UnsupportedMaskTransform，内容仍可使用普通 g/shape transform。mask 与 clipPath 都属于 [SVG 容器元素](https://www.w3.org/TR/SVG2/struct.html#container-element)，[mask 属性的适用范围包含这些容器](https://www.w3.org/TR/css-masking-1/#the-mask-image)。mask 定义自身可以再引用一个本文件 mask，presentation attribute、CSS、inline style 的选择仍遵循同一套级联；clipPath 的资源解释仍遵守上一节的 silhouette 边界，保留 UnsupportedClipContainerEffect，待具体语义和独立 oracle 明确后再决定是否扩展。

自身 mask 的 target 是当前 mask 的**内容坐标系**；嵌套定义的 userSpaceOnUse 使用该坐标，objectBoundingBox 使用当前 mask 子项的解析几何边界，不能沿用最初业务 shape 的包围盒。每一级保持自己的 region、mask-type 和 color-interpolation。先完成本级内容，再乘嵌套 mask 的连续 factor，最后按本级 mask-type 转换为外层的 factor；每一级 mask 图片只解析/量化一次。默认 pixel 模式就地乘本级 BGRA 工作面，不把本级图片 source-over 到自身；sample_color 复用隔离条带组。嵌套候选、隔离层、几何与所有工作消耗同一累计预算。

内容中的 g/shape 也可再引用 mask、clipPath 和使用 opacity。直接自身、间接以及经 use 回到活动 mask 的循环均由共同 active stack 拒绝；reference_depth 不按嵌套定义重新发放。mask 定义的 opacity/filter/display 不应用于定义本身；模块仍全局拒绝未支持的 filter 属性，不执行 filter。需要组透明度时在内容中显式使用 g。

mask 内容先绘制到透明目标，再解析/量化成每个物理像素的预乘 BGRA8，转换为连续 alpha，乘完成的目标组一次。默认模式使用完整 BGRA 工作面；sample_color 使用独立条带组，解析后不把 mask 颜色合成进原目标。mask-type 默认 luminance，也支持 alpha。luminance 依据 mask 的 computed color-interpolation：sRGB 直接使用编码 RGB 的亮度系数；linearRGB 先从预乘颜色解出 straight RGB、转线性值再算亮度，两者最后都包含原 alpha。系数为 R×0.2125 + G×0.7154 + B×0.0721。定义容器只建立内容继承，定义自身 opacity 不创建额外组；需要组透明度时在内容中显式使用 g。mask 自身覆盖与目标 clip 即使位于同一分数像素边缘，也按连续 mask alpha 乘目标覆盖，不作共同 lane 的相关性消除。透明内容、图层与部分失败不发布 Prepared，所有候选存储按原 allocator 回滚。

## 输入与预算

- parse 默认输入 1 MiB、4096 个元素/文本节点、深度 32、每元素 32 属性、单属性 64 KiB、拥有存储 8 MiB。硬上限分别 16 MiB、65536 节点、64 层、64 属性、1 MiB/属性和 64 MiB 存储。文本被注释/CDATA 分成多段也分别计节点。
- 两遍读入先校验/计数，再精确分配 source/node/attribute/value 数组；没有运行时扩容树。XML 只接受 UTF-8、XML 1.0 合法字符和明确 ASCII 名称子集；支持 predefined/numeric references、CDATA、注释和有限 XML declaration。拒绝 DTD、自定义实体、外部实体与其他 processing instruction，不执行文件或网络读取。
- prepare 默认峰值 64 MiB，硬上限 256 MiB；借用的 Document、固定栈、allocator 元数据与系统 renderer 另计。默认同时最多8层隔离组，硬上限32。pixel 模式计入 Prepared、最终图片、全画布透明层、路径命令与 raster 临时数据，每层按实际完整输出尺寸计费。
- sample_color 的同一字节预算包含稳定 Builder、所有索引/brush/gradient 数组的拥有容量、全部 Geometry 与 flatten/stroke 候选、四子行 crossing scratch 的 `Σedges` 总量、clip 缓存、根与隔离组条带及最终图片。条带每个颜色层为 `32×16×4×8 = 16384` 字节，另有 scope 元数据；根层也计费。动态数组扩容时旧容量和新候选同时入峰值，不能以最终长度代替实际 live。预算 allocator 在调用宿主 allocator 前拒绝超额，返回 CapacityExceeded；真实 allocator 分配失败仍返回 OutOfMemory。结果只在全部条带成功后转移最终 Prepared/像素给原 allocator，失败不发布半张图片。
- 最终图片最多每边16384 px、16M pixels。pixel_work 默认128M、硬上限1G，按物理像素工作计费；pixel 模式计完整工作面遍历，sample_color 计命中 paint 条带、mask resolve 和最终输出 resolve。路径的 vertices/edges/edge_attempts/stroke_steps/scan_tests 同时受整个本次准备的累计预算限制，不对每个元素重新发放完整工作配额。
- sample_work 默认128M、硬上限1G。pixel 模式累计样本平面清零/复制、并/交、路径快照输出量化和 paint 覆盖量化遍历。sample_color 计所有显式 u16 clear/copy/OR/AND（包括 scope 的32项 reset），几何查询为每个输出像素保守预扣17项写入；单位是覆盖项工作，不是每 bit 独立配额。
- sample_color 另有 color_work/scene_work，默认各128M、硬上限各1G；前者按四通道 f64 lane 的清零/合成/累加及输出处理工作单位计费，不是 CPU 指令数，后者计场景构建、验证、节点/clip 访问与渐变像素求值。sort_work 默认512M、硬上限1G，计 crossing 排序比较。条带循环、查询和命中缓存不分配；全部存储在进入循环前准备。新计数在 Stats 同名字段中返回。普通无图案 pixel 场景仍为0；pixel 图案会复用同一 lane compositor，这三个字段仅累计该新增子过程，原普通 pixel 着色不计入其中，不能据此声称全面限制其颜色工作。
- parse_work 默认4MiB、硬上限64MiB，整个源校验、每次实例展开、几何边界重算、渐变模板和定义祖先样式计算均按所处理的原始属性名/值字节收费。长空白 transform/path/points 不能借反复 use 绕过累计限制。
- CSS 默认 source128KiB/rules256/declarations4096，硬上限1MiB/1024/16384，每块声明最多64项。source 和精确 rule/declaration 数组计入 prepare 的峰值，准备结束即释放。匹配、候选声明和样式值共用默认2M、硬64M的 style_work 限额。
- reference_depth 默认16、硬32，node_visits 默认65536、硬1M；绘制/几何边界展开、裁剪/蒙版引用、渐变模板/祖先/stop访问和寻找 stop 的子节点扫描累计计费。gradient_stops 默认32、硬64，固定栈存储另计；stop查找使用二分。ID索引计入 prepare 峰值，准备后释放。
- 取消在节点、几何展开、行/有界 pixel 块检查，不能中断一次 allocator、固定内存清零或 OS 调用。预算是存储和工作量边界，不是任意输入的耗时保证。

规范依据：[SVG 文档结构](https://www.w3.org/TR/SVG2/struct.html)、[坐标与变换](https://www.w3.org/TR/SVG2/coords.html)、[XML 1.0](https://www.w3.org/TR/xml/)、[CSS 颜色](https://www.w3.org/TR/css-color-3/)、[SVG 蒙版](https://www.w3.org/TR/SVG11/masking.html)和[SVG2 paint server](https://www.w3.org/TR/SVG2/pservers.html)。完整语言与明确拒绝范围以上述实现范围为准。

## 验证

`zig build test-svg` 检查拥有型树、实体/非法输入、全部分配故障、形状/路径像素对照、数值与变换次序、颜色、组透明度、clip 位集合、mask 色彩空间、双圆手算/f128 几何与准备预算。径向分类另用 binary64 位模式转换为整数×2^-1074，以任意精度整数的平方差检查符号/零，覆盖轴交换、符号、指数、相邻半径与坐标减法残差；不是用相同 f128 公式自证。极小垂直分量的外焦点有独立几何透明区断言；常 RGB 变量 alpha 有 offset/重复 stop/单 stop、两种色彩空间与双合成模式的手算像素。sample_color 增加逐 lane 独立合成 oracle、三种 DPI 的共同 clip/viewport 边界、曲线/弧线/孔洞与 A8 差分、精确峰值差1失败、全分配故障、各工作配额、取消、owner/adopt，以及重复 clip DAG 的精确 ops/sample 线性计数和代数耗尽测试。两种模式的自身 mask 都包含 alpha/sRGB/linearRGB 手算、CSS 三级链、object/content/region 坐标与显式内容组的三 DPI 等价性、直接/间接/跨 use 循环、累计配额、全部分配故障和在每个候选分配点触发取消后 live=0 的检查。

`zig build smoke-svg -Dgpu=true` 在隐藏/离屏目标分别回放 pixel/sample_color 的准备图片，检查1/1.5/2倍 DPI、clip、整图像素、Frame/residency 提前释放拒绝与 native 创建数不增长；两种模式都在 worker 关闭源 Document 后才 handoff/adopt。保留 use/evenodd clip、线性 RGB luminance mask 与外焦点 radial 的联合场景，另加自身 mask 的三级 CSS 链和独立128→64→32中心像素断言。独立径向场景还固定极小垂直分量的 cone 外透明区，以及常 RGB 变量 alpha 的红/灰周期平均手算断言，再做完整原生像素回放。硬件/WARP 还验证设备丢失后从同一快照恢复、读回一致和恢复后的常规回放不增加 native 创建数。Windows GDI/硬件/WARP 与 Linux Cairo 均有实际读回；它验证像素和生命周期，不评价人工视觉质量。每次扩大 SVG 支持范围后继续增加独立规范/oracle 和原生回放用例。

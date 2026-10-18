# SVG 顶点标记

标记适用于 `path`、`line`、`polyline` 和 `polygon`，使用 `marker-start`、`marker-mid`、`marker-end` 的局部引用。准备阶段解析、求向并合成标记；最终 `Prepared` 拥有像素快照，回放不再访问源文档、计算方向或分配标记资源。

## 路径与角色

支持有界的原始 M/L/Q/C/A/Z 路径，包括多个子路径、连续 M、M-only、M+Z、开放/闭合曲线和退化段。相对命令及 H/V/S/T 使用原有解析展开，不以控制点、flatten 点或弧中心制造新顶点。

- 整个 path 的第一个顶点接 start，最后一个接 end，其余原始顶点接 mid；内部子路径的首尾也各是 mid。
- 闭合子路径的接缝具有两个同点角色，按源顺序分别合成。整路径只有一个顶点时，依次绘制 start、end，没有 mid。
- 零长 L、所有控制点重合的 Q/C 保留原始端点。首尾重合但控制点不同的曲线仍有有效方向。
- 等端点 A 按规范省略整段，不产生顶点；零半径且端点不同的 A 按直线处理。Z 是实际闭合段，不能因其长度为零就删除角色。
- 不存在实际 mid 时不解析 mid 引用，也不检查该未实例化定义的内容或单位。原文档语法、数值与资源提供者的检查仍然成立。

全路径角色和闭合接缝依据 [SVG2 顶点标记](https://www.w3.org/TR/SVG2/painting.html#VertexMarkerProperties)；弧的省略与退化依据 [SVG2 弧参数规则](https://www.w3.org/TR/SVG2/paths.html#ArcOutOfRangeParameters)。

## 自动方向

Q/C 使用端点多项式的首个非零项求单侧方向；A 使用共享弧解析转换的端点切向，不用弦或重新 flatten 代替。内部方向取左右切线的半角，不按段长加权。

零段的 start 先借前方最近非零段的 incoming，没有才借后方 outgoing；零段的 end 先借后方 outgoing，没有才借前方 incoming。搜索限于当前子路径，全无方向时用本地正 x。先确定线性序列的双限，再处理闭合邻接；不跨 M 或循环搜索。方向域沿用 [SVG1.1 F.5 的明确子路径规则](https://www.w3.org/TR/SVG11/implnote.html#PathElementImplementationNotes)，不声称 SVG2 已明确重述这一边界。

自动方向依据 [SVG2 路径方向](https://www.w3.org/TR/SVG2/paths.html#PathDirectionality)与[标记渲染](https://www.w3.org/TR/SVG2/painting.html#RenderingMarkers)。精确 180° 折返仅在实际需要自动方向的实例返回 `UnsupportedMarkerDirection`；固定角度、未请求角色和尺寸抑制不需要该半角。内容验证先于尺寸抑制。

## 单位、定位与裁剪

`markerUnits` 默认 `strokeWidth`，也接受 `userSpaceOnUse`。普通目标的 strokeWidth 使用目标的 computed stroke-width；定义自身的 stroke-width 不替代它。即使目标 stroke 为 none，正宽度仍可绘制标记；目标宽度为零时不绘制 strokeWidth 标记。userSpace 不依赖目标描边宽度。

markerWidth/Height 默认 3，负值失败，任一零值或零尺寸 viewBox 不绘制。尺寸与 refX/refY 支持现有绝对 length，百分比和几何关键字明确拒绝。ref 默认为 0。支持原有 viewBox、preserveAspectRatio none/meet/slice。orient 默认 0，接受 number/deg/rad/grad/turn、auto、auto-start-reverse；反转只作用于 start。

设 V 为 viewBox 到 marker viewport 的映射，p 为目标顶点，r 为 ref，R 为方向，s 在 userSpace 下为 1、普通 strokeWidth 下为目标宽度，则内容映射为：

`M_target · T(p) · R · S(s) · T(-V(r)) · V`

默认/显式 hidden 在 marker viewport 矩形裁剪，clip 使用 V 之前的矩阵。visible、auto、scroll overflow 明确拒绝。

目标为 non-scaling-stroke 时，strokeWidth 标记支持统一缩放、平移、旋转和反射。设目标映射 M=O·H，H 到最外 SVG viewport，O 在它之外，Q 为 H 去掉统一尺度后保留反射的正交部分，w 为目标宽度，则映射为：

`O · T(H(p)) · Q · R · S(w) · T(-V(r)) · V`

clip 仍取 V 之前的矩阵。只接受精确保角矩阵形式，不用容差放行 shear；非保角、各向异性和退化 host 对实际非零实例返回 `UnsupportedMarkerStrokeSpace`。归一化先除最大系数再计算有界 hypot，不构造可能溢出的 1/s、w/s 或原矩阵长度。普通 marker 与 userSpace 保持原公式。

这是 [SVG2 markerUnits 与非缩放描边](https://www.w3.org/TR/SVG2/painting.html#MarkerUnitsAttribute)的保角子集。新 prepare 的位置随 host 映射改变，宽度在 host 单位固定；缩放已准备的快照仍缩放整张图，不保证运行时 DIP 宽度固定。

## 内容与组合边界

标记内容接受实色/currentColor 的基本 shapes 与 g，支持局部变换、普通 stroke/dashes、子组 opacity、visibility/display。样式来自定义的真实祖先；隐藏定义仍可引用。marker 根的 transform、非 1 opacity、clip/mask，以及内容中的 text/image/use、paint server、其他 marker 引用、clip/mask、non-scaling-stroke 明确拒绝。

目标的 fill/stroke 可继续使用既有 gradient/pattern。整体 clip、mask、opacity 在 fill、stroke 和全部标记之外只作用一次；object bbox 来自原始目标几何，不纳入标记或描边。标记不继承目标 fill/stroke 的 paint opacity。

缺失或类型不符的局部引用不绘制；已找到但超出支持范围的定义明确失败。外部 URI、URI escaping 和 paint fallback 不在本引用语法中。该范围不代表完整 SVG 支持。

## 所有权、预算与验证

两种合成后端使用同一个拓扑权威：先确定适用引用与角色数量，在首实例前完整验证，再消费单调角色流。不建立第二 Path、逐顶点数组或持久 owner。没有 marker 时不进入新增扫描；普通单段保留既有路线。

复杂路径的遍历上界为 `5N + 2S + E`，N 为源命令数、S 为子路径数、E 为输出角色数。A 在验证、描述、anchor 各至多查询一次。每次读取前计费并检查取消；定义、实例、引用深度、候选、像素及失败工作共用原预算。最后临时释放之后仍经过取消门。

x86_64 已测私有值尺寸为 Inspection 24、Role 40、冷 Cursor 256 字节；保角 helper 的 Transform 为 48、错误联合结果为 56 字节。这些不是总调用栈或 SDK 内存测量。拓扑整合后，64 条旧指纹的像素、分配 trace/次数、峰值和非遍历工作相同，其中 40 条增加了明确计费的 node visits；随后保角标记批次保持全部 64 条指纹字段。

Windows 与 Linux 的 Debug/ReleaseSafe 均已通过对应纯检查及隐藏原生回放。最终标记模块为 348 项纯测试；独立原生例覆盖全路径角色/透明源顺序，以及 ordinary、reflection、90°、start-reverse、fixed90 五组尺寸定位，使用两种合成模式、三个准备 DPI，并检查资源归零。Windows 还覆盖 GDI、硬件、WARP 和设备丢失。完整工程整合与后续能力分别记录；这些结果不建立视觉质量或应用性能结论。

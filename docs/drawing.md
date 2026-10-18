# 基础绘制

`ziggurat_ui` 将每帧绘制记录到调用者持有的有界 `commands.Buffer`，再由 GDI、D2D 或 Cairo 回放。`Frame` 负责应用局部坐标偏移；直接使用 Buffer 时坐标已经是当前源平面的 DIP。已有 RGBA 形状、圆角填充、内描边，以及线性/径向/圆锥渐变、hard stop 和陡变 stop 回放。[图片绘制](image-drawing.md)支持准备、采样、驻留和同尺寸更新，[准备文本](text-layout.md)支持有色字形覆盖；[分组](layers.md)和[仿射合成](affine-rendering.md)分别说明独立工作面与采样成本。

```zig
frame.roundedRect(bounds, 8, ui.Color.rgb(0x204060));
frame.strokeRect(bounds, 8, 2, .{ .r = 255, .g = 255, .b = 255, .a = 128 });
```

## 形状与透明度

`Color` 使用直通 alpha 的 8 位 `r/g/b/a`，默认 `a = 255`。`Color.rgb(0xRRGGBB)` 创建不透明颜色。现有 `rect`、Buffer.fill 和文本的 `u32` 颜色继续表示不透明 `0xRRGGBB`。内部 C 接口的打包值为 `0xRRGGBBAA`，与 Win32 COLORREF 不同。

形状按命令顺序进行 source-over 合成，颜色在编码 RGB 空间混合，不进行线性光颜色校正。alpha 为 0 的形状不写像素。renderer 拥有不透明窗口表面，新建 surface 初始化为不透明白色，公开绘制操作保持这个输出契约；GDI 的像素平面按 BGRX 使用。该接口不建立透明顶层窗口，也不改变窗口 opacity。帧之间不承诺保留内容，每帧仍须绘制所需背景。

`roundedRect(bounds, radius, color)` 填充整个外轮廓。`strokeRect(bounds, radius, width, color)` 的外轮廓与对应填充完全相同，描边全部位于 bounds 内。radius 描述外轮廓，自动夹到最短边的一半；width 必须大于 0，夹到最短边的一半。内轮廓向内缩 width，半径为 `max(0, radius - width)`；内轮廓为空时填充整个外轮廓。因此线宽超过半径仍保留外圆角。

负半径、非正描边宽度、NaN、无穷和无效矩形返回 `InvalidGeometry`，不占用命令槽；零面积形状允许记录并在回放时跳过。Frame 将错误记入帧失败状态，拒绝该帧回放。基础文本继续在 Buffer 中复制，形状数据按值保存；图片与准备文本通过独立资源表固定 Lease 到本次回放结束。拥有这些借用的 Buffer 不能复制为第二个 owner，必须按其 reset 契约释放。

## Clip、DPI 与后端成本

矩形 clip 与形状共用既有 32 层栈，clip 在 DIP 坐标系内随 DPI 缩放。栈不平衡或命令非法时回放失败并解除已推入的 native clip；GPU 还会中止当前帧，由 Context 使用同一份命令进行软件后备。后端的边缘抗锯齿算法不同，语义与轮廓保持一致，不承诺边缘逐像素相同。

| 后端 | 存储与正常回放成本 |
| --- | --- |
| GDI | 复用顶向下 32 位 DIB、DC 和字体；形状覆盖率直接写入 DIB，只有轮廓边缘做固定 4×4 采样，source-over 不分配临时位图。读取前 `GdiFlush` 完成前面的 GDI 文本和不透明矩形操作。工作量随相交像素面积增长。 |
| D2D | 复用 brush；圆角填充使用原生 primitive，圆角内描边使用偶奇填充路径。每个 renderer 有固定 32 项 LRU，按归一化后的宽、高、外半径和线宽查找，平移与 DPI 不改变缓存键。命中不创建路径，未命中创建新路径后才替换旧项；最多线性查找 32 项。 |
| Cairo | 在复用的 image surface/context 上构造内外轮廓，偶奇填充并恢复 context；适配层没有每形状的显式堆分配。Cairo 内部路径存储由系统库管理。 |

surface 每边最多 32768 个物理像素，单个 32 位像素平面的字节数最多 256 MiB；这不等于 GPU 全部缓冲与驱动的内存上限。尺寸、scale 和溢出检查先于 native 分配或整数转换，拒绝非法 resize 时保留原 surface。合法 resize 创建失败后 renderer 可重新 begin，已创建的资源由错误清理路径释放。D2D 还受显卡和原生设备的尺寸能力限制。

D2D 路径缓存随 renderer 释放；设备丢失也释放全部项，下一次成功绘制按需重建。不保留失效设备的绘制引用。缓存是每个窗口资源的一部分，没有全局缓存、后台线程或刷新定时器。`Renderer.geometryStats()` 提供累计创建、淘汰和当前项数，用于验证命中及回收，不是 driver 内存统计。

## 连续渐变

```zig
const stops = [_]ui.commands.brushes.Stop{
    .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
    .{ .offset = 1, .color = ui.Color.rgb(0x0000ff) },
};
frame.gradientRect(bounds, 8, .{ .linear = .{
    .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 160, .y = 0 }, .stops = &stops,
} });
frame.gradientStrokeRect(bounds, 8, 2, .{ .radial = .{
    .center = .{ .x = 80, .y = 40 }, .radius = .{ .x = 80, .y = 40 }, .stops = &stops,
} });
```

Frame 的 bounds 和渐变锚点都使用当前局部 DIP；它同时平移 bounds、linear.start/end、radial.center 和 conic.center，半径与角度保持不变。直接 Buffer API 使用当前源平面的 DIP。径向渐变为同心椭圆，radius.x/y 均须为正；线段两端不能重合，没有偏心焦点。线性/径向默认 `spread = .pad`，stop 范围之外夹到最近端色；显式 `.repeat` 与 `.reflect` 支持软件周期采样，具体接缝、透明度和整 Buffer GPU 后备见[重复与镜像渐变](gradient-spread.md)。

圆锥渐变使用同一个矩形/圆角/向内描边入口：

```zig
frame.gradientRect(bounds, 8, .{ .conic = .{
    .center = .{ .x = 80, .y = 40 },
    .start_angle_radians = 0,
    .direction = .clockwise,
    .stops = &stops,
} });
```

center 是显式局部 DIP，Frame 只平移该点。角度为 f64 弧度，0 指局部 +X；屏幕 +Y 对应顺时针，另可选择 `.counter_clockwise`。角度必须有限且绝对值不超过 `1048576 * 2π`；记录时先归一化整圈和负零，再窄化为 f32，窄化到完整一圈时归零。不依赖 bounds 自动推断中心，也不按百分比解释坐标。

采样参数是一圈的半开区间 [0,1)，精确中心明确定义为 t=0。接缝出发侧使用零点的右连续颜色，靠近一圈终点使用左极限；不在首尾之间自动插入颜色过渡。offset=1 仅定义左极限，不作为接缝出发色；若在1有多项，靠近终点的插值趋向该组第一项。重复的其它 stop 沿用最后一项拥有精确点的规则；不移动相近 stop，不加入 epsilon 色带。预乘编码 RGB、透明 stop 和 source-over 与线性/径向一致。矩形、圆角和内描边沿原 analytic 路径；path fill/stroke 与任意 A8 使用显式准备工作面的原子 [gradientCoverage](gradient-coverage.md) 记录，不增加默认渲染字段或新增 path shader。

软件圆锥分支在固定 scratch 上预计算 stop 与预乘颜色，在 shape/clip 交集中逐像素求角，不分配渐变平面。旧线性/径向扫描循环不执行 atan2。GPU 沿用单个 analytic effect、152 B brush 和624 B常量，不新增 effect/brush/cache；离线 shader 的固定代码包含圆锥分支，普通绘制不在运行时编译它。

圆锥 analytic GPU 有更窄的数值包络：首尾 stop 必须恰好为0与1且 RGBA 相同，相邻 stop 间隔至少1/1024；物理中心必须能由 f32 精确表示，物理中心及 shape 的坐标/尺寸绝对值至多65536。全部透明时直接跳过。硬 stop、极窄间隔、不连续接缝、非精确物理中心或超出包络仍是合法软件输入；renderer 在回放任何命令前返回 `UnsupportedGradientPrecision`，Context 用同一 Buffer 做 GDI 后备，不再次调用业务 draw。显式低层 GPU/offscreen 调用直接收到该错误，由宿主决定后备。不会以放宽像素误差把这些输入算成 analytic GPU 支持。

仿射 scope 先在固定 DPI 的源平面采样圆锥，再合成字节像素，父矩阵不进入角度计算。GPU 的通用仿射预检与绘制内容无关：它在任何命令回放前检查每层实际 padded quad、f32 运算范围、顶点的1/256物理像素量化及累计父矩阵；嵌套各层的源坐标误差预算相加，互为逆的变换不能绕过中间层。不满足支持范围返回 `UnsupportedTransformPrecision`，不伪造原生错误码；Context 可用同一批命令进行软件后备，显式 GPU/offscreen 调用直接返回错误。GPU texture 仍不能交给不支持它的软件 renderer。这个保守支持范围不代表任意驱动内部算术的形式证明；它与圆锥自身的角度/stop 包络分别验证。

每个渐变有 2–16 个 stop，offset 在 [0,1] 内非降排列，坐标与 offset 必须有限。相同 offset 可以有不同颜色，恰好位于该 offset 时采用最后一个 stop，即右连续；两侧分别插值到该组的第一个和最后一个颜色。完全相同的 offset/color 无损合并；只剩一个 stop 时归一化成两端相同颜色。相近但不同的 offset 不使用 epsilon 改写。alpha 为 0 的彩色 stop 不向相邻颜色泄漏隐藏 RGB：默认先将 RGB 乘 alpha，在编码 RGB 空间分别插值预乘分量和 alpha，再 source-over；不做线性光转换。全部 stop 的 alpha 为 0 时直接跳过，不遍历目标像素，也不提交 GPU effect。

Buffer 在调用期间借用 descriptor/stops，返回前复制到独立的 32 项 brush 表。Command 只有形状和内部索引，没有公开 BrushId；reset 清空命令、文本和 brush 表。Buffer 没有指向自身或调用者 stops 的指针，可整体移动。命令容量、brush 容量或验证失败时，两张表均不部分修改。当前 `Command` 为 32 B，独立 brush 表为 4864 B；没有把 16 个 stop 放进每条命令。

新代码通过 `Renderer.replayBuffer(&buffer)` 或 `replayWithResources(commands,text,brushes)` 回放；后一个接口的三个切片须来自同一有效快照，在调用结束前保持稳定。旧 `replay(commands,text)` 继续支持原有命令，遇渐变返回 `MissingResources`。资源索引越界或非法 stop 返回错误；GPU 失败时 Context 用同一个 Buffer 在软件 renderer 回放，不再次调用 draw。

GDI 与 Cairo 共用 f64 采样器，直接写入各自已经拥有的不透明 DIB/image surface，不另建渐变像素平面。每条命令先预计算投影、倒半径、预乘颜色与 stop 区间，再扫描 shape 与 clip 的交集。Cairo 在访问前 flush，完成后只 mark dirty 交集；固定 33 项矩形交集栈保留分数 clip 边缘，不能用 `cairo_clip_extents` 的 raster bbox 代替覆盖率。source-over 输出 alpha 保持 255。

软件路径的 stop 上界二分最多 5 次；默认 `.srgb` 完全覆盖的矩形可按同一区间做固定 8-lane f64 插值，跨 stop 的 chunk 逐像素处理。全不透明水平线性矩形只计算一条完整扫描行，其余完整行复制；垂直线性矩形按行填色。分数 shape/clip 边缘独立取覆盖并混合，不复制依赖旧背景的半透明结果。圆角/内描边只在外/内轮廓边缘做固定 4×4 coverage。没有 paint 期堆分配或无界缓存，固定命令 scratch 约 1 KiB 加向量临时值，工作上界由裁剪像素和 16 stops 决定。

GPU 使用自有 analytic D2D effect，直接计算 stop 边界与预乘插值，不使用原生 gradient 的查表纹理。每个 device 在显式 init/recreate 阶段只创建一个 effect；每条渐变写入固定 624 B 参数并 `DrawImage`，同一 EndDraw 中多条命令保留各自参数快照。正常回放不编译 shader、不创建 effect/gradient brush/stop collection，也不生成 CPU 渐变平面。设备丢失释放 effect，下一次设备重建恢复一个。`gradientStats()` 分别记录 effect 创建、draw 提交、实际 `PrepareForRender` 常量上传与设备恢复；D2D 可复用同参数的 render 结果，常量上传不必等于 draw 数。保留的 `brushStats()` 在 GPU/Cairo 上均为零；这些数不等于驱动内部内存或命令缓存。

GPU 在物理像素局部坐标中计算。线性 stop 使用局部投影位置；径向原点选 ellipse center 到实际可见 box 的最近点，保留 `q-stop²`，插值用有理化公式避免相近归一化半径相减。若最小 q>1，整个 box 都在最后 stop 外，使用同 effect 的常量端色。这样高目标边缘的小半径 ellipse 不会因 box 中心远离 ellipse 而出现大常量相消。线性/径向 GPU 当前要求物理 anchor、radius 与 shape 的坐标/尺寸绝对值不超过 2²¹，径向两个物理半径至少 1/4096；超出范围返回 `UnsupportedGradientPrecision`，Context 发 renderer 域诊断、无伪造系统错误码，并用原命令做 GDI 后备。软件路径继续接受符合有限值/窗口几何预算的同一输入。

**像素精度：**数学 stop 为右连续点采样，实际光栅以物理像素表示。原生像素测试对不跨 stop 的内部像素逐通道允许 3/255 舍入差异；只有 footprint 真正跨 stop 的单个物理像素允许两侧颜色的边界混合，不允许把陡变扩宽成多 DIP 色带。轮廓与矩形 clip 的边缘 AA 可因后端不同；不承诺三端逐像素完全相同。GPU 使用 f32 参数/运算，软件使用 f64；上述检查与显式数值范围不等于任意输入下的实数精确计算。

离线 HLSL、固定 DXBC 与生成元数据位于 `src/ui/shaders/`。普通构建只编入已生成字节，不需要本机 shader compiler；仅重新生成时运行 `scripts/generate-gradient-shader.ps1`，默认 Windows SDK 10.0.26100.0，记录编译器、源码与 bytecode SHA256。Shader profile 为 ps_4_0，不引入运行时编译 DLL。默认未启用 GPU 的应用不链接该实现。

## 显式插值空间

三个 descriptor 均有 `interpolation`，默认 `.srgb` 保持既有预乘编码 RGB 结果；`.srgb_linear` 在解码后的线性光 sRGB 中插值，`.oklab` 在 D65 Oklab 的矩形 L/a/b 中插值。输入始终是 straight-alpha sRGB 字节。插值空间不改变 source-over、分组、图片或输出设备的色彩管理，也不表示支持 HDR、ICC 或其它输入色域。

新模式先转换 stop 的未预乘分量，再将全部三个坐标乘 alpha（含有符号的 a/b），分别插值坐标与 alpha。alpha 恰好为0时输出全零，不用 epsilon 丢弃很小的 alpha；其它情况先除 alpha，转换回线性 sRGB，逐通道裁到 [0,1]，编码成 sRGB 后重新预乘，才进入既有 shape/clip/source-over。输出通道裁切可能改变色相，它不是感知色域映射。端点、精确 stop 与范围外夹取保留原 RGBA，不做转换往返。透明 stop 的隐藏颜色不会泄漏。黑白不透明中点在三个模式分别约为128、188、99。

模式是 brush 身份的一部分，参与去重、快照和验证。Stored 与原生基础 brush 仍各152 B，32项表仍4864 B。默认软件采样不转换或准备新颜色表；新模式每条非空命令在固定512 B栈表中转换至多16个 stop 一次，像素输出另有传递函数/逆矩阵成本，不建图片或堆缓存。GPU 新空间使用[显式准备的可选插值程序](gradient-interpolation-gpu.md)，只在该程序已准备且满足其共同数值/组合包络时回放；其它非空、非全透明输入在回放前以 `UnsupportedGradientPrecision` 拒绝，Context 用同一 Buffer 后备，显式 GPU 调用返回错误。

`smoke-gradient-interpolation` 的软件参考独立经过 XYZ，矩阵与插值使用 f128，传递函数 pow 使用 f64。它比较三空间、三几何、16 stop/重复 stop/透明颜色、三形状和三档 DPI 的324个完整平面，软件逐通道阈值为1/255，并单列完全覆盖与边缘的实测最大误差；额外验证拥有型离屏快照、反射、组 opacity 和分配失败保持旧结果。Linux 原生 Cairo 与 Windows GDI 已验证；硬件/WARP 已验证未准备或包络外输入的整批拒绝、无前缀提交、离屏含 Texture 的旧前帧/统计保持，以及 Context 一次 draw 后使用同批命令的软件后备和诊断。已准备程序的实际 GPU 共同包络、独立像素集合及默认 shader 成本验证见[显式 GPU 插值程序](gradient-interpolation-gpu.md)。

## 验证范围

`zig build smoke-drawing` 在 Windows 上运行 GDI 原生像素检查，在 Linux 上运行真实 Cairo image surface 回放。Windows 加 `-Dgpu=true` 还检查硬件 D2D 和 WARP 的 readback。测试覆盖 source-over 重叠、透明跳过、圆角、细/粗内描边、空内轮廓、矩形 clip、分数坐标、越界裁剪，以及 scale 1/1.5/2。内部像素允许很小的舍入误差；外轮廓比较允许不同抗锯齿误差。

GPU 测试还验证缓存热身后重复绘制不新增路径、超过 32 项会淘汰、设备丢失清空缓存后可以重建，deinit 后适配层 native 引用归零。GDI 检查独立 renderer 的资源数回到基线，并测试非法超大尺寸不破坏旧 surface。像素检查与隐藏窗口检查不建立可见视觉质量或显示完成延迟结论。

`zig build smoke-gradients` 对首次 begin 后不画背景的透明/半透明 stop、线性/椭圆径向、圆角内描边、clip、scale 1/1.5/2 和全透明跳过做原生像素检查；`-Dgpu=true` 加硬件/WARP readback、同帧多渐变快照、设备丢失与回收。40 个不同 descriptor 与锚点/半径动画仍只使用一个 effect；设备恢复另计一次。Cairo 检查整个平面保持 alpha=255，不创建 native gradient pattern。

`zig build smoke-gradient-analytic` 每个 backend 运行 90 个全像素 case：hard/steep、多重重合 stop、透明彩色 stop、16 stops、线性反向/对角/垂直、椭圆、百万 DIP 跨度、微小半径、clip 与三档 DPI。Linux 另检查分数 clip、嵌套和 pop 恢复。硬件/WARP 还检查 192×16384 与转置目标、百万/2 的径向长宽比、首尾边缘、hard/steep、scale 1/2；超出数值范围时验证一次业务 draw、同 Buffer GDI 回放、诊断和下一 GPU 帧恢复。纯 sampler 测试以逐像素 scalar oracle 对照向量/行复制/填充，包括非均匀旧背景、padding 和分数边缘。

Linux 显式 `zig build benchmark-gradients -Doptimize=ReleaseSafe` 对 1280×720 DIP、scale 1/2 的热回放取 7 组、每组 3 帧的中位数，比较当前采样器与隔离保留的旧 Cairo 两 pattern 路径。它包括横向 2/16 stops、垂直不透明、对角不透明/透明与透明径向；构造和首帧在计时外，只记录 CPU 提交成本，`display_latency=false`。旧路径不进入生产 UI；测得速度只适用于该机器和工作量，不建立可见视觉质量结论。

`zig build smoke-conic-gradients` 检查独立象限/acos 角度 oracle、顺逆时针、中心与接缝、重复/透明 stop、圆角内描边、clip 和三档 DPI。Windows 加 `-Dgpu=true` 验证硬件/WARP analytic 像素、捕获/离屏、设备丢失与恢复；不在 GPU 数值包络内的合法输入则检查整 Buffer 预检、一次业务 draw、GDI 后备和真实诊断。Linux 检查真实 Cairo surface 的同一软件 oracle。新圆锥与既有 linear/radial、layers、offscreen、affine 原生回归在 Windows/Linux ReleaseSafe 均通过，结束后适配层资源归零；这些是实现与生命周期证据，不代表任意角度输入都由 GPU 接受或已完成所有软件合成性能优化。

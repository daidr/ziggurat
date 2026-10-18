# 路径资源

`ziggurat_vector` 是可选纯 Zig 模块，只依赖绘制资源 ABI。`Path.create` 复制调用者的命令，`Path.parseData` 严格解析 SVG 的 `d` 数据；二者都创建稳定的拥有型 Path。Path 的创建、准备和关闭使用同一个 owner 线程，调用者保持其字段和命令不可变。准备的覆盖与源 Path 独立，Path 可先关闭。

命令包含 move、line、quadratic、cubic、elliptical arc 和 close。解析器支持 M/L/H/V/C/S/Q/T/A/Z 的相对/绝对形式、隐式重复、指数数字及紧凑 arc flags；遇到错误拒绝整个输入，不交付部分路径。close 后的隐式续段从原子路径起点开始。直接构造命令时 close 后须显式 move。它只解析路径数据，不读取 XML、CSS、文件、网络或外部资源，完整 SVG 文档属于后续 G01.5 分项。

数字必须可表示为有限 f64；非零数下溢到零返回 UnsupportedNumberPrecision，避免把非零 arc 半径悄悄变成直线。随后仍按坐标、旋转和变换预算校验。

`Arc.endpointDirections(start)` 是无分配的纯值查询，返回可空 `Arc.Directions{outgoing,incoming}`，两者是本地坐标下沿路径前进的非零有限向量，不是位置，也不保证单位长度。它不要求创建 Path、提供 allocator 或访问 owner。start、end、radius 的每个有限分量绝对值须不超过10⁹，rotation 须有限且绝对值不超过10⁹；与 `Path.create` 共用 Arc 输入校验，非法输入在退化判断前返回 `InvalidGeometry`。相同端点返回 null，包含 large-arc flag 为1的情形；这是省略 arc，不是完整椭圆。仅当端点不同，任一零半径才按直线返回共同首尾方向。负半径、过小半径校正、rotation 归一化和四种 flags 由同一解析转换处理；数值无法表示时返回 `UnsupportedArcPrecision`。

查询与 coverage/bounds 使用同一个编译期投影的端点转换。设椭圆为 `center+X*cos(θ)+Y*sin(θ)`，转换得到的端点径向分量为 q，则前进方向为 `sign(sweep)*(-X*q.y+Y*q.x)`；不以 flatten 弦推算方向，也不把端点 angle 再送入 sin/cos。geometry 专化不计算或保存 Directions，原 Result/Ellipse 布局及有效输入算式保持；新查询才计算两个解析向量并拒绝非有限或零结果。它保留共享椭圆精度检查，额外计算、输入校验和错误检查均属于本次显式查询，不声称零 CPU 成本。

本机布局检查为 Arc48、Ellipse64、Result72、Path40 字节，与加入方法前的字段布局一致；Directions 是新增32字节返回有效载荷，不含 optional/error union 的 ABI 包装，不进入任何已有拥有型 record 或 geometry 投影。声明大小不等于实际线程栈峰值，未据此给出耗时或栈峰值结论。

## 准备和借用

```zig
const path = try vector.Path.parseData(allocator,
    "M2 2H14V14H2Z M5 5V11H11V5Z", .{});
defer path.close() catch unreachable;
const prepared = try path.prepare(allocator, .{
    .main_thread = process_main_thread,
    .viewport = .{ .width = 16, .height = 16 },
    .scale = window_scale,
    .style = .{ .fill = .even_odd },
});
```

prepare 产生拥有的 A8 覆盖，4 字节对齐 stride、物理 pixel origin 和 scale 都进入 `CoverageView`。颜色在绘制命令端选择。改变 scale、路径或变换须重新准备，平移绘制 origin 和改变颜色可复用覆盖；viewport 以路径变换后的 DIP 坐标明确裁切准备范围，不根据路径自动创建巨大画布。

应用可以在显式 worker 创建 Path 并准备覆盖。`main_thread` 必须填写实际进程主线程 ID；worker 持有结果时不可查询公开 view。成功 `App.post` 后 producer 停止访问，主线程 `adopt` 转移独占 owner，再获取 view。投递失败由 worker 关闭结果。模块不创建线程、投递任务或等待 UI。

`Prepared.close` 在 Frame 或 renderer 仍持有 Lease 时返回 ResourceInUse。覆盖的地址、描述符及像素在所有借用期内稳定，颜色不烘焙进 mask。准备时分配，回放只使用已经准备和显式上传的覆盖。native A8 回放、驻留及阴影共享资源的验收沿 G01.3/G01.5 独立记录，纯数学测试不证明原生回放。

## 几何和采样语义

填充支持 nonzero 与 even-odd；填充时每个开放子路径隐式闭合。描边在路径自己的坐标中居中构造，再应用完整仿射变换，因此非等比缩放和 shear 同样影响宽度。支持 butt/square/round cap、miter/bevel/round join 与显式 miter limit。重叠描边片段先求非零覆盖，再生成一份 mask，不重复叠加 alpha。只有 move 的子路径不绘制，显式零长度 line 或 close 可按 cap 形成方形或圆形。stroke 对齐扩展尚未实现。

`Stroke.space` 默认 `.local`，保持上述轮廓随路径变换的行为。显式 `.transformed` 先把完整 centerline 映射到 `PrepareOptions.transform` 后的坐标，再在该坐标构造 width、caps、joins、dashes、dash offset 和 trim；最后只应用物理 `scale`。因此 width=2、scale=1.5 得到3px宽的轴对齐描边，非等比缩放、反射或 shear 不再改变这项宽度。曲线误差与虚线长度都在变换后的坐标约束，trim 仍为各子路径的折线长度比例。独立几何/Rows 与普通 A8 prepare 共用这一模式。

`.transformed` 可以另传 `PrepareOptions.stroke_output`（独立几何为同名 Options 字段），显式借用一份将 host 描边轮廓映射到输出坐标的 Transform。入口在首次 allocator 回调前按值捕获；两遍 count/build 不再访问调用者描述，allocator 修改它也不会改变本次候选。该变换不进入 Prepared/Geometry。这样 centerline→host→output 各有明确映射，不必反求仿射逆矩阵。局部描边或填充携带此字段返回 InvalidStrokeSpace。曲线细分同时约束最终物理误差和 dash/trim 所需 host 误差，scale 小于1时同样保持 host 长度精度，输出变换也参与圆端帽/连接的细分。普通调用不构造额外顶点平面。

两种模式复用同一个已预算的顶点平面；转换在 flatten 写入时完成，不添加第二个 centerline 或逐边模式分支。`.transformed` 是显式几何协议，奇异变换也可以产生被描边的退化中心线；SVG 的不可逆 CTM 禁止绘制规则由 SVG 模块另行执行。它不改变 `Path.bounds` 的原有几何含义，也不会在普通 UI paint 中准备路径。

`Stroke.dashes` 最多 32 个非负有限长度，单项至多 10⁹，奇数项序列重复两次，全零等同实线。`dash_offset` 接受 ±10¹² 范围内的有限数，按周期归一化；每个子路径重新开始相同相位。零长度 on 段保留 cap，允许圆点虚线。数组仅在 prepare 调用期间借用，Prepared 不保留它。

`Stroke.trim` 的 start/end 是每个子路径本地折线长度的 0–1 比例：默认 0/1 为完整路径，start=end 为空，start>end 保留前缀和后缀。trim 在原有 dash 相位上取交集。闭合路径穿过接缝的两端使用一次 join，只有实际裁切端有 cap；开放路径前后缀各自带 cap。这是一项显式路径 API，不是 SVG CSS 属性。

虚线长度和 trim 都以曲线展开后的**本地折线长度**计算；不声称解析曲线弧长或全长相对误差上限。启用它们后，细分还约束本地弦偏差，避免奇异变换将曲线压平后丢掉本地长度。数值不能前进、周期求和丢失正长度时返回 UnsupportedStrokePrecision，不悄悄删段。虚线方向遵循 [SVG 描边语义](https://www.w3.org/TR/SVG2/painting.html#StrokeDasharrayProperty)。

曲线以变换后物理像素的显式 tolerance 自适应细分，默认 0.125 px，可选 1/64–1 px；Bézier 使用控制点到弦段的距离上界，包含共线回折和零长度弦。椭圆 arc 保留解析椭圆，用变换后的轴范数约束弦误差，不先转换成固定四段 cubic。负半径取绝对值、零半径按线段、相同端点省略 arc，过小半径先修正。无法保持数值范围或最多 20 层细分仍不足时明确失败。tolerance 描述曲线折线误差，不是任意宽描边最终像素的严格误差证明。

共享 arc 转换保证每个成功 ellipse 的中心、两轴、起始角和 sweep 共8个 f64 分量全部有限；中间 coefficient 非有限也返回 `UnsupportedArcPrecision`。极小但非零的 λ 仍可能使 `(1-λ)/λ` 溢出，不能把生成的 NaN 交给后续步骤。解析 bounds、A8 prepare 与 geometry.compile 沿同一转换传播该错误。有效输入沿用原算式；每次非退化转换新增1次 coefficient 与8次结果分量的有限性判定，不新增分配或持久字段，但增加准备阶段计算，不声称零开销。无 arc 的路径不执行这些判定。

路径数据和 arc 参数遵循 [SVG 路径语法](https://www.w3.org/TR/SVG2/paths.html)与[椭圆端点参数转换](https://www.w3.org/TR/SVG/implnote.html#ArcImplementationNotes)，数值/容量拒绝范围如本页所列。

最终 scan conversion 使用每像素 4×4 固定样本；半开 Y 区间避免公共顶点重复计数，排序交点后累计 winding 或 parity。A8 是覆盖样本数 ×255/16 的四舍五入，所有后端读取同一快照。抗锯齿为离散采样，不宣称解析面积积分。

`Path.bounds(transform, cancellation)` 无分配地计算几何的解析 f64 包围盒：二次/三次曲线取导数根，椭圆取变换后的轴极值，并与 coverage 共用同一端点 arc 转换。它忽略孤立 move、stroke 和 markers；空几何返回 null。它是显式 O(commands) 查询，不在回放中计算。

需要在准备阶段组合几何区域时，可显式开启 `retain_samples`。Prepared 的 `samples` 记录同一4×4网格的16个覆盖位，行 stride 与 A8 一致；padding为零。相同网格的区域可以按位 union/intersection 后再降为 A8，避免把两个半覆盖边缘当作重复 alpha 混合。额外拥有存储为每个 aligned 像素2字节，计入拥有/峰值预算并随 Prepared 释放；默认不开启。该数组与像素同为不可变 owner 借用，不能越过 Prepared.close 或绕开 Lease 规则修改。

## 独立几何与逐行缓存

`vector.geometry.compile(path, allocator, options)` 产生拥有型 Geometry，保存独立的已展开物理边表和填充规则，不生成 A8 或整幅样本平面。它与普通 prepare 共用曲线、arc、描边、虚线和 trim 内核；Path 可以在编译成功后先关闭。Geometry 和 Rows 使用稳定指针持有，不能复制拥有型结构。普通 A8 prepare 不创建 Rows，也不承担其缓存分配成本。

```zig
const geometry = try vector.geometry.compile(path, allocator, .{
    .scale = window_scale,
    .style = .{ .fill = .even_odd },
});
defer geometry.close() catch unreachable;
const rows = try vector.geometry.Rows.create(allocator, &.{geometry}, row_bytes);
defer rows.close() catch unreachable;
var work: vector.geometry.Work = .{};
const row = try rows.prepare(0, physical_y, &work, cancellation);
try row.writeSamples(physical_x, sample_bits, &work);
```

坐标是编译后的物理像素坐标，相对于 Options 的整数 `origin_x/origin_y`，不是 DIP。每次 writeSamples 覆写至多16384个 u16；它只采样几何本身，viewport 或其他 clip 必须另在相同网格求交。相同 Geometry 条目的同一个 y 复用四个子行的排序交点和前缀 winding；横向片段二分定位后只处理相交事件，不重新展开路径或扫描整份边表。

Geometry、Rows、Row 查询及关闭都限制在创建它们的同一个 owner 线程。纯准备可以在显式 worker 中完整完成，但这里没有 adopt 或并发读取接口；Rows 对 Geometry 的 pin 仅保护寿命，**不授予跨线程访问权**。Rows 创建成功后持有所有 Geometry，后者提前 close 返回 ResourceInUse；Rows.close 释放这些 pin。Row 借用其条目的 scratch；该条目尝试准备不同 y 或 Rows.close 后，旧 Row 不可再用。其他条目使用不相交的 scratch，更新它们不使本条目失效。

Rows 一次预分配整个集合的 `4 × Σedges × sizeof(Crossing)` scratch，包含当前行不活跃的条目，另有 Rows 与条目元数据；不是只给单个 Geometry 计算预算。`Rows.stats()` 返回这些实际拥有字节；Geometry.stats 的 owned_bytes/peak_bytes 分别报告边表与编译候选峰值。组合场景还须把所有 Geometry、Rows、输出和工作面合计到同一个总预算，不能给每条路径重复发放整份场景限额。

同一个 Work 累计整个操作的 scan_tests、sort_tests 和 sample_work，默认上限分别128M、512M、128M。scan_tests 按边/子行计费；排序使用原位 heap sort 并逐比较计费，取消每256次比较检查。sample_work 每个输出像素预留最多17次 u16 写（清零和16个可能分离的样本位合并）；预算不足时不改变输出。查询不分配；排序或取消失败可能改变私有 scratch，但不发布新的 Row。斜边交点仍使用 f64，与既有 raster 保持相同的离散采样边界，不声称解析精确算术。

## 容量和成本

- 默认 Path 最多 4096 命令、1 MiB 拥有存储，硬上限 65536 命令/16 MiB。路径数据默认 1 MiB、硬上限 16 MiB，两遍解析精确分配，不保留输入或可扩容临时命令数组。
- prepare 默认最多 65536 个展开顶点、262144 条非水平边；硬上限分别 262144/1048576。起始 move 也占一个顶点槽，零长度边可不进入边表。坐标/半径绝对值最多 10⁹，变换每项最多 10⁶，转换后另验证实际可表示范围。
- 另有默认 1M、硬上限 8M 的 edge_attempts 生成预算，包含最终被水平/退化判定丢弃的边；round 圆周在进入三角函数循环前预检完整段数。计数与输出两遍各受同一限额，不允许退化变换绕过扫描预算产生无界生成工作。
- 虚线/trim 另有默认 1M、硬上限 8M 的 stroke_steps，包含长度遍历、pattern transition 和切段；超限返回 StrokeBudgetExceeded。共享单向游标遍历原始线段，不为每条虚线从头扫描整条路径，也不创建临时碎片数组。两遍各受同一限额；普通未裁切实线保留原快路。
- A8 最多 16384×16384 边长且含 stride padding 的 payload 不超过 16 MiB。默认 allocator 峰值预算 64 MiB、硬上限 128 MiB，包含最终 Prepared、覆盖、精确顶点/子路径/边/交点表和行计数。借用的源 Path、allocator 元数据和固定深度栈另计。
- 每次 prepare 预检 `height×4×edges`，默认至多 128M、硬上限 512M 次边扫描；超限返回 ScanBudgetExceeded。交点排序和逐行样本写入仍有额外成本，因此它不是耗时硬上限。取消在命令、细分、轮廓和行边界检查，不保证中断一次排序或 allocator 调用。
- `stats` 区分拥有字节、allocator 峰值、展开顶点、边及边扫描数。缓存容量、上传和设备恢复属于 renderer 统计；不把准备耗时当作帧显示时延。

当前独立测试覆盖两种填充与反射变换、64 组随机复合多边形与角度 winding oracle、椭圆解析范围、回折曲线、描边/cap、手工分段 oracle 对照的虚线/trim/闭合接缝、分数 viewport/padding、4000 次固定种子路径数据变异、全部分配失败、线程归属、显式交接与提前释放拒绝。A8 路径覆盖已通过 Windows GDI/hardware/WARP 与 Linux Cairo 的实际回放；完整 SVG 元素/样式与外部资源策略继续单独实施。

## 准备成本观测

`zig build benchmark-vector -Doptimize=ReleaseSafe` 显式运行曲线/arc/复合孔洞 fixture。以下是本机 Windows、page allocator、预热后 7 样本中位数，仅包含一次完整 prepare，不含解析、close、上传、回放或显示：

| DIP 边长 | scale | even-odd | round stroke |
| --- | --- | --- | --- |
| 32 | 1 | 0.028 ms | 0.075 ms |
| 32 | 2 | 0.048 ms | 0.214 ms |
| 128 | 1 | 0.098 ms | 0.496 ms |
| 128 | 2 | 0.268 ms | 2.189 ms |
| 512 | 1 | 0.689 ms | 5.328 ms |
| 512 | 2 | 2.379 ms | 26.088 ms |

512 DIP/2x 的圆描边使用 260 个展开顶点、9581 条非水平边，扫描约 39.24M 次；最终持有约 1 MiB，准备 allocator 峰值约 1.44 MiB。圆角描边将重叠段合并为一次覆盖，准备成本高于填充；大资源宜由显式 worker 准备并复用，改变颜色/origin 不需重建。该固定 fixture 的测量不承诺任意 SVG 或动态逐帧路径的吞吐量。

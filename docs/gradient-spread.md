# 重复与镜像渐变

线性与同心椭圆径向 descriptor 可设置 `spread = .pad | .repeat | .reflect`，默认 `.pad`。相同入口支持矩形、圆角、向内描边和已准备 A8 的 [gradientCoverage](gradient-coverage.md)，也可放入既有分组与仿射 scope。圆锥渐变维持原有一圈接缝合同，没有新 spread 参数。

```zig
frame.gradientRect(bounds, 8, .{ .linear = .{
    .start = .{ .x = 0, .y = 0 },
    .end = .{ .x = 24, .y = 0 },
    .stops = &stops,
    .spread = .reflect,
    .interpolation = .oklab,
} });
```

## 参数与颜色

线性的投影参数以 start/end 定义一周期，径向以 center 到椭圆半径定义一周期。先将参数映射到周期内，再做原有 stop 右连续查找与颜色插值：

- `pad`：不折叠参数，stop 范围外取最近端色。
- `repeat`：映射到 `[0,1)`，正负整数接缝属于周期起点。
- `reflect`：在 `[0,1]` 往返，偶整数属于起点、奇整数属于终点；负参数对称。

周期长度与首末 stop 的实际 offset 无关；周期内在首末 stop 范围之外仍取端色。重复 offset 的最后一项拥有精确点，不加入 epsilon 色带。反向线性向量保持其方向；非正径向半径或重合线性两端继续返回 `InvalidGradient`，不记录命令。

三种插值空间均沿用先预乘、插值、必要时解预乘转换再重新预乘的合同；透明 stop 的隐藏颜色不参与输出。Shape/A8 coverage、clip 与父组 opacity 各合成一次，不成为渐变周期或渐变锚点的一部分。

## 采样坐标与精度

软件周期颜色在源平面的物理像素中心投影。每条命令在像素循环前，将 anchor、axis/radius 乘实际 DPI scale；像素中心先减工作面的物理 origin，再计算 binary64 参数。Frame 的局部 offset 只平移 descriptor 一次。A8、分组和仿射捕获沿用同一源坐标，外层仿射再合成已采样的字节像素。

这避免先乘近似 inverse-scale 再投影而将精确 hard stop 移到另一侧。既有 shape/clip coverage 的采样位置不变，默认 pad 的计算与优化循环也不变。

折叠只执行固定次数的浮点运算，不按周期数循环或将周期数转成整数。支持负参数、可表示的极大有限参数和接缝附近的 subnormal。合同基于实际 binary64 投影结果；不承诺任意高频图案的低通滤波，也不将有限精度计算当作任意实数精确结果。低层 `Stored.sample(x,y)` 要求周期模式的**投影结果有限**，任意有限 f64 点配极小半径并不自动满足这个前提。

## 所有权、成本与 GPU 后备

Buffer 仍按值复制至多 16 个 stop，spread 参与 brush 身份与去重。调用者随后修改 stop 不影响已记录内容。BrushesFull/CommandsFull 仍在提交前失败，原 Buffer 保持原状态。

实测 `Stored = 152 B`、`Native = 152 B`、`Gradient = 48 B`、stop 起点 offset20，均未扩大；spread 占 Stored 既有 padding。原生 C brush、shader 与 packet 不变。默认路径新增一条命令级 spread 分支与身份比较；不宣称 CPU 或栈成本为零。周期命令使用条件进入的 48 B 投影值和既有 512 B stop 转换表，逐像素投影、折叠、查找、插值；不分配渐变平面或增加持久缓存。

当前 repeat/reflect 是软件回放能力。Analytic GPU 与显式插值程序对实际使用、非空且非全透明的周期渐变返回 `UnsupportedGradientPrecision`；整 Buffer 预检先于任意前缀命令回放。未使用资源、零面积与全透明命令保持跳过。

显式 GPU Surface 在 begin/clear 前拒绝，因此原 front、Texture 和统计保持。普通 Context 的工作目标可能已 begin/clear，但不会提交前缀命令或 present 失败的 GPU 目标；它只调用业务 draw 一次，用同一 Buffer 软件后备，后续正常 pad 帧仍可恢复 GPU。该后备可能包含整个工作面的软件采样与传输，不能称周期模式已有 GPU 插值。

## 验证范围

Linux Debug/ReleaseSafe 已实际通过 108 个完整平面：repeat/reflect × linear/radial × 三空间 × scale1/1.5/2 × 矩形/圆角/内描边，含分数 clip、重复 stop、透明 stop。额外检查 A8、组 opacity、反射、工作面 origin、热资源、最后快照 lease 和分配失败保留旧结果。独立颜色参考使用 f128 几何与 XYZ 插值，通道阈值1；两次字节合成的组合例阈值2。默认 pad 像素指纹保持 `20b4c7fbdc43939d`。

Windows Debug/ReleaseSafe 同一 108 平面与组合集合也已通过。硬件/WARP 各实际验证 Surface 清屏前的整 Buffer 拒绝、旧 front/Texture/完整统计保持，以及隐藏窗口真实 WM_PAINT 的一次 draw、repeat/reflect 软件后备和后续 pad GPU 恢复；退出后资源归零。普通窗口读回比较 BGRX 的 RGB，透明 Surface 继续比较全部 BGRA。最终根回执记录174项选定项目输入前后匹配；这不是全 SDK 闭包证明。自动像素检查不建立可见视觉质量、任意输入 GPU 支持或吞吐结论。

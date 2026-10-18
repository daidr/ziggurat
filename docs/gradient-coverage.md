# Path 与 A8 coverage 的渐变填充

`Frame.gradientCoverage(origin, view, gradient)` 使用共享的不可变 `CoverageView` 作为渐变的 alpha coverage。Vector 已准备的 fill、evenodd 孔、普通或 dashed stroke 都使用同一接口；手工准备的图标、遮罩等 A8 也适用。它接受现有 linear、radial、conic 渐变以及有界 stop、透明颜色和显式插值空间。彩色 glyph 仍属于原图像/文字协议；此接口只接收单通道 A8。

调用者在 paint 之外显式准备对应 DPI 的 coverage、上传 coverage，并通过 `Context.prepareLayers` 准备有界的合成工作面。`gradientCoverage` 不解析 Path、不重栅格化、不分配像素或原生对象，也不隐式准备工作面。CPU coverage 与 native residency 分别持有同一 Lease 的 pin。改变 DPI 时，先准备新的 coverage 和工作面，再发布新的业务 view；旧资源在 Frame 与 residency 释放后才能关闭。

```zig
// 非 paint 阶段：Path.prepare 的 fill 或 stroke 都返回同一资源协议。
const prepared = try path.prepare(allocator, .{
    .main_thread = std.Thread.getCurrentId(),
    .scale = scale,
    .viewport = .{ .x = -2, .y = -2, .width = 28, .height = 28 },
    .style = .{ .fill = .even_odd },
});
const coverage = try prepared.view();
try context.prepareLayers(allocator, .{ .size = paint_size });
try context.uploadCoverage(coverage);

// draw 回调：origin 和渐变锚点都属于当前 Frame 的用户坐标。
try frame.gradientCoverage(.{ .x = 8, .y = 12 }, coverage, .{ .conic = .{
    .center = .{ .x = 20, .y = 24 },
    .stops = &stops,
} });
```

Frame offset 分别平移 `origin` 与 brush 锚点一次。Coverage 自身的 `origin_x/origin_y` 是准备时的物理像素 placement，只用于 mask 定位，不会再次移动渐变。渐变在当前用户坐标的像素中心求色；A8 只乘该颜色与 alpha。父 clip、外层 affine 与整体 group opacity 仍沿现有合成语义一次应用，不改变命中、焦点或可访问性几何。

## 原子记录和准备边界

底层的 `commands.Buffer.gradientCoverage` 一次记录平衡的 mask group、gradient rectangle、end group。它复用现有渲染原语，不是新增 shader、native ABI 或 Command union 类型。

提交前完成描述/坐标/gradient 校验、全局硬层深、全部三条命令、brush 表和 coverage 表容量检查。只有所有检查成功，才取得必要的新 pin 并一次提交；任何记录错误保持原命令、资源表、scope 深度和 Lease 计数不变。已存在的 brush 和 coverage 复用原表项，同一 mask 在 Buffer 中只保留一份 pin。Buffer reset 释放该 pin，不能在持有资源时复制拥有型 Buffer。

独立 Buffer 并不知道将使用哪个 renderer。实际工作面的准备状态、配置层深、DPI 与 native residency 在既有整缓冲预检/资源门核验；记录成功不表示这些 native 条件已成立。Frame 的记录失败进入原有失败路径，准备或回放失败不发布部分新前帧。

显示列表会多用三条命令、一个可复用的 brush 表项、一个可复用的 coverage 表项和一层显式工作面。工作量按现有 group clear、gradient、mask/opacity/composite 账本计费，不能将它称为免费的直接 path shader。现有离屏预检为这三条命令累计五次保守整平面 visits，另有原帧和输出复制费用；这不是 FLOP 或时间承诺。未调用此操作的 Command、Buffer、Frame、Context 不增加字段，也不执行新分支。

## 边缘、alpha 与后备

共同 bilinear mask 采样的非零域为 `(-1,width) × (-1,height)`，外部 texel 为透明。合成 bounds 在源 extent 两边各包含一个物理透明 texel，先用 f64 计算，再向外窄化 f32，防止分数 origin 或 DPI 的边缘被 gradient rectangle 人为裁掉。额外透明区域不会增加实际 coverage。超出可表示几何的组合明确返回 `InvalidGeometry`。

透明子平面先得到预乘 BGRA8 渐变，再乘 mask；不会将 mask 当作第二个 stop alpha，也不对每个 path 子段分别应用整体 opacity。插值空间只影响 stop 之间的颜色，合成仍使用现有 encoded、预乘 RGB 规则。

硬件/WARP 复用现有 sRGB analytic 渐变和 mask 合成。现有 GPU 插值程序对 group 内的新空间仍不支持；合法软件渐变按现有 whole-buffer 预检走软件后备，业务 draw 不重跑。如果 Buffer 含不能软件回放的 Texture，则明确失败并保留旧前帧。本批不扩大 GPU 新插值的已验包络，也不声明 GPU 执行时间、视觉质量或性能提升。

独立原生夹具为 `smoke-gradient-coverage`；验证记录与实际通过范围另行收口。它使用独立 XYZ/f128 palette、acos/quadrant 圆锥参数与全 texel tent 权重，覆盖 literal A8、evenodd fill、弯曲 dashed stroke、三种渐变、透明/重复 stop、分数 origin/clip、整体 opacity 和三档 DPI。

本批 Linux Debug/ReleaseSafe 的软件完整集合各通过 108 次回放，另增真实反射组合在两配置各通过三 DPI、两次热回放。后者只运行新增 `ZIGGURAT_GRADIENT_COVERAGE_CASE=affine` 集合，保留前一集合原日志和 source hash；没有把旧结果改绑成最后 fixture hash。默认未设选择器时运行两者，未知选择值明确失败。Frame 的 offset/DPI 入口与 Buffer 事务/大坐标 support 纯测试通过；窗口位置、点击和语义不由本夹具验收。

Linux 实测当前声明大小为 `Command=32`、`Buffer=143480`、`StoredBrush=152`、`Frame=928`、`Context=194728` 字节；Debug/ReleaseSafe 一致。新增方法没有修改这些结构的字段，当前 Frame/Context 包含其他功能的既有状态，不能把它们的总大小或历史变化全部归因本功能。显式调用仍有至多 32 项 brush/coverage 查找、stop 复制及一层合成的实际成本；未测 stack peak、CPU/GPU 时间或能耗。

原生回放和最终驻留/Lease 检查均通过，Cairo 适配层对象归零。根独立 Windows Debug/ReleaseSafe 窄目标也已通过：GDI、hardware、WARP 的三 DPI 原集合和真实反射组合，以及两 GPU 模式下 Context 的整缓冲后备和下一 GPU 帧恢复，相关资源断言归零。后备夹具在运行时使用 `Window.contentSize()` 的物理尺寸与 scale；首次使用 DIP 尺寸准备工作面的夹具错误及失败日志单独保留。实测 scale=1.5、physical=180×60、logical=120×40；每个 Context 的 GPU 首帧、两次软件后备及返回 GPU 各只运行一次业务 draw。

该 Windows 构建实际 `Context=250280`、`Frame=928` 字节，前述 Linux 为 `Context=194728`、`Frame=928`；平台和构建配置拥有不同后端/可访问性记录，不能将这个差值归因于新 API。Windows 与 Linux 的日志各自绑定实际输入，没有用单端结果代替另一端，也不把 Context 返回 GPU 的检查称为物理 device-loss 恢复测试。

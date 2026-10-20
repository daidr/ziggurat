# 着色器与元素效果

`ziggurat_shader` 是一门有界的着色语言：程序在绘制之前编译成寄存器字节码，编译时就算出每个像素最多执行多少步；`ziggurat_ui` 用它改写元素的绘制结果（元素效果）或元素下方已画好的内容（背景着色器）。在此之上，`ui.effects.Library` 提供内置的位姿/透视变换、淡出和玻璃折射程序，声明式视图把它们接成 `Style.opacity`、`Style.pose`、`Style.effect`、`Style.refraction` 与 `View.presentColumn` 进出场过渡。

**范围说明**：程序只在 CPU 上逐像素解释执行。含有着色器命令的一帧在 D3D11 下与[背景效果](backdrop-effects.md)一样整帧改走软件回放（Windows GDI DIB、Linux Cairo 图像面）；没有 GPU 后端、没有 worker 编译与磁盘缓存，也没有吞吐量基准。像素正确性由单元测试与隐藏窗口 smoke 检查验证，不代表视觉质量评审。

## 语言

```glsl
uniform float amount;
uniform vec4 tint;
const float tau = 6.2831853;

float wave(float y) { return sin(y / size.y * tau); }

vec4 color(vec2 position, vec4 pixel) {
    return mix(pixel, tint * pixel.a, amount * wave(position.y));
}
```

- 类型：`bool`、`int`（32 位，溢出是运行时错误）、`float`、`vec2/3/4`、`mat2/3`（列主序）以及最多 64 个元素的一维数组。分量访问支持 `xyzw`/`rgba` 重排与写入（写入不得重复分量）。
- 全局：`uniform` 参数（合计至多 64 个字）、`const` 常量与辅助函数（至多 32 个，不得递归，参数至多 8 个）。内置只读量 `size`（元素盒子的 DIP 尺寸）与 `scale`（物理像素/DIP）。
- 控制流：`if/else`、`?:`、`break`、`continue`，`for` 循环必须以字面量为界、步进变量在循环体内只读，编译器据此算出循环次数（单个循环至多 `max_loop = 1024` 次）。`while`/`do` 不可用。
- 内置函数：`sin cos tan asin acos atan sqrt inversesqrt exp log exp2 log2 pow mod sign floor ceil fract round abs min max clamp mix step smoothstep dot length distance normalize cross`，`layer` 入口还可用 `sample(vec2)`。
- 入口必须恰好一个，决定程序种类：
  - `vec4 color(vec2 position, vec4 pixel)`：逐像素改色，`pixel` 是该位置的预乘 RGBA。
  - `vec2 distort(vec2 position)`：返回应当从哪里取色，结果按双线性采样，盒子外的采样为透明。
  - `vec4 layer(vec2 position)`：用 `sample(p)` 任意读取内容，例如模糊或位姿变换。

坐标是相对于盒子左上角的 DIP，颜色是 0–1 的预乘 RGBA；返回值会被夹到合法范围。

### 编译与错误

```zig
var diagnostic: ui.shader.Diagnostic = .{};
const program = ui.shader.compile(allocator, source, .{ .max_steps = 4096 }, &diagnostic) catch |err| {
    std.log.err("{d}:{d}: {s}", .{ diagnostic.line, diagnostic.column, diagnostic.message() });
    return err;
};
defer program.destroy();
```

编译失败返回 `error.InvalidShader`，`Diagnostic` 给出从 1 开始的行列与说明；分配失败返回 `error.OutOfMemory` 且不泄漏。最坏情况步数超过 `Options.max_steps`（默认 4096）的程序无法编译，因此任何程序的单像素开销都有静态上界 `program.max_steps`。程序不保留源文本。

运行时，数组越界、整数溢出、除以零和非有限结果都会停止该像素的执行（`error.ShaderFault`）：元素效果把这样的像素画成透明并计入 `faulted_pixels`，不会越界读取或回绕。

### 参数

```zig
var values = ui.shader.Values.init(program);
try values.set(program.uniform("amount").?, @as(f32, 0.5));
try values.set(program.uniform("tint").?, [4]f32{ 1, 0, 0, 1 });
```

`program.uniform(name)` 返回带程序身份、类型与长度的句柄；`Values.set`/`setElement` 拒绝其他程序的句柄、错误类型或长度（`UniformMismatch`）与非有限浮点数（`InvalidValue`）。记录命令时参数被复制，之后修改 `values` 不影响已经记录的帧。

## 元素效果

```zig
try context.attach(window);
try context.prepareShaderEffects(allocator, .{});
// 绘制回调中：
try frame.beginEffect(box, .{ .program = program, .values = &values, .margin = 8 }, .{ .opacity = 255 });
// ... 正常绘制内容 ...
try frame.endEffect();
```

`beginEffect` 到 `endEffect` 之间的内容在 `box` 外扩 `margin`（DIP）的范围内被隔离绘制，经程序改写后以 `opacity` 合成回当前目标，并遵守外层裁剪。命中测试、焦点与语义保持原布局几何，效果只改变外观。隔离有两条路径：

- 已用 `prepareGaussianWorkspace` 准备高斯工作区且容量足够时，复用高斯 scope 的透明捕获层，在 scope 结束时以程序代替滤波核，结果与内容独立绘制完全一致。
- 否则在目标平面上做两遍隔离：保存捕获区域，先在不透明黑底上画一遍内容，再在白底上画一遍，恢复原像素，由两次结果求出内容的预乘颜色与覆盖率。灰度抗锯齿边缘可以精确恢复，逐通道（ClearType）覆盖的文字取三通道平均。捕获区域超过 `Options.max_pixels`（默认 1 Mi 物理像素）时内容原样绘制并计入 `skipped`。两遍隔离不能嵌套：在一次两遍隔离内部再开的效果原样绘制其内容。

每帧的总开销（像素数 × 程序最坏步数）受 `Options.max_work` 约束，超出的效果原样绘制并计入 `skipped`。没有 `prepareShaderEffects`，或嵌套超过层深度时，内容原样绘制并计入 `shaderEffectStats().unprepared`。工作区在 `releaseShaderEffects` 或 detach 时释放，绘制路径不分配内存。

## 背景着色器

```zig
frame.backdropShader(bounds, radius, .{ .program = program, .values = &values, .margin = 12 });
```

程序改写 `bounds` 圆角矩形内、当前裁剪内已经画好的像素，读取可延伸到 `margin` 之外；与背景效果一样只看到当前 scope 的内容。它需要 `prepareShaderEffects` 与 `prepareBackdropEffects` 两个工作区，缺少任一时什么也不画并计入 `unprepared`。

## 内置程序

```zig
const library = try ui.effects.Library.create(allocator);
defer library.destroy();
var pose_values: ui.shader.Values = undefined;
if (try library.pose(&pose_values, .{ .rotate_y = 0.4, .perspective = 600 }, .{ box.width, box.height })) |effect|
    try frame.beginEffect(box, effect, .{});
```

- `pose(values, Pose, size)`：`Pose` 含平移 `x/y/z`、缩放 `scale_x/scale_y`、平面旋转 `rotate` 与绕 X/Y 轴的透视旋转 `rotate_x/rotate_y`（弧度），`perspective` 为视距（0 为正交），`origin` 为盒内比例原点。程序以 3×3 单应矩阵的逆映射采样内容；外扩边距按四角位移计算，至多 `max_pose_margin`（128 DIP），超出部分被裁掉。恒等位姿返回 null，退化（不可逆）位姿也返回 null。`Pose.mix` 用于过渡插值。
- `passthrough()`：不改变内容，配合 `opacity` 把整棵子树作为一层淡出。
- `glass(values, Glass, radius)`：背景着色器，沿圆角矩形内侧宽 `bezel` 的弧面按 `refraction` 弯折下方内容，加 `highlight` 边光与可选 `tint`。

库必须在任何记录了其效果的帧结束之前保持存活。

## 视图

```zig
try host.attach(window);
try host.prepareBackdropEffects(allocator, .{});
try host.prepareShaderEffects(allocator, library, .{});

try v.column(.{ .opacity = 0.6, .pose = .{ .rotate_x = 0.2 } });
try v.row(.{ .radius = 16, .refraction = .{ .bezel = 12 }, .padding = Insets.all(8) });
if (try v.presentColumn(&state.panel, state.open, .{}, .{ .padding = Insets.all(12) })) {
    try v.text("Details", .{});
    try v.end();
}
```

- `Style.opacity`（0–1）、`Style.pose` 与 `Style.effect` 作用于节点及其全部后代，按位姿、效果、淡出由外到内嵌套，不透明度由最外层承担；它们与裁剪按子树范围后进先出地关闭。没有 `prepareShaderEffects` 时位姿与淡出被忽略，`effect` 原样绘制内容。
- `Style.refraction` 在容器子节点之下画玻璃折射，代替 `material` 与 `background`；减少透明度或高对比度偏好下回退到它们。
- `View.presentColumn(presence, show, transition, style)` 打开一个列容器：`show` 变真时从 `transition.hidden` 位姿与 `hidden_opacity` 进入，变假后退出，退出结束返回 false（此时不要构建子节点也不要 `end`）。`Presence` 由应用以稳定地址保存，内部是 `ziggurat_animation` 的 `Channel`；运动期间按 60 Hz 请求下一帧，静止时不请求。减少动态效果偏好下立即出现与消失。

## Canvas

```zig
const canvas = try ui.Canvas.create(app, allocator, .{ .size = .{ .width = 256, .height = 128, .scale = 1 } });
defer canvas.destroy() catch {};
try canvas.paint(frame, destination, .{ .context = &chart, .run = Chart.draw }, .{});
// 内容变化后、下一帧之前：
try canvas.invalidate();
```

`Canvas` 把一段命令绘制到[离屏面](offscreen.md)得到的图片中，之后每帧直接画这张图，直到应用调用 `invalidate`。被仍在记录的帧持有的图片无法关闭（`Busy`），因此在帧之间失效。`stats()` 给出重绘与复用次数。

## 帧统计与慢帧日志

`Context.setFrameStats(.{ .enabled = true, .slow_ns = 8 * std.time.ns_per_ms })` 为每帧计时：录制（build）、预检（preflight）与回放呈现（render）三段，以及命令数与是否走软件回放；`frameStats()` 返回帧数、慢帧数、平均、最近一帧与最慢一帧。超过阈值的帧通过 `std.log`（scope `ziggurat_frames`，info 级）输出一行。未显式设置时，attach 读取环境变量 `ZIGGURAT_FRAME_STATS`：`1`/`on`/`true`/`yes` 为 8 ms 阈值，数字为毫秒阈值，`all` 记录每帧，`0`/`off`/`false`/`no` 关闭。计时只读单调时钟，不分配内存。

## 验证

- `zig build test-shader`：语言、诊断位置、静态步数上界、运行时错误、uniform 类型与分配失败。
- `zig build test-ui`：元素/背景着色器像素、两遍隔离、高斯捕获路径、预算、内置程序、Canvas 与帧统计。
- `zig build test-view`：样式包裹顺序、裁剪/效果平衡与 `presentColumn` 进出场。
- `zig build smoke-shader-effects`：隐藏窗口上未准备时的原样绘制，准备后的改色、位姿、淡出像素，背景着色器，帧统计与工作区随 detach 释放。

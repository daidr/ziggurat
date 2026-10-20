# 背景效果与加载动画

`ziggurat_ui` 提供两类按像素绘制的效果：**背景效果**读取元素下方已经画好的内容，模糊、调色后写回元素的圆角矩形内；**加载动画**按调用者给出的相位程序化地画出 29 种不确定进度指示。两者都在软件平面（Windows GDI DIB、Linux Cairo 图像面）上执行，含有它们的一帧在 D3D11 下整帧改走软件回放；`Context.backdropEffectStats().software_frames` 记录这样的帧数，不作为设备失败报告。视图层的用法见[声明式视图](view.md#背景效果)。

## 背景效果

```zig
try context.attach(window);
try context.prepareBackdropEffects(allocator, .{ .max_pixels = 1024 * 1024 });
// 绘制回调中：先画下方内容，再画效果。
frame.backdropEffect(bounds, 16, .{ .glass = .{} });
frame.backdropEffect(bar, 0, .{ .blur = .{ .radius = 6, .mask = .{ .from = 255, .to = 0, .angle = 180 } } });
frame.backdropEffect(edge, 0, .{ .scroll_edge = .{ .hard = true } });
```

`Frame.backdropEffect(bounds, radius, effect)` 以 `bounds` 与圆角 `radius`（DIP）为形状，只改写形状内、当前裁剪内的像素；命中、焦点和语义仍由调用者的布局决定。效果看到的是**当前目标**已经画好的内容：在组、变换或高斯 scope 内部，它只看到该 scope 迄今画的内容，与透明层的合成语义一致。目标平面以外的采样重复最近的边缘像素。

`Effect` 有三种：

- `glass`：玻璃材质。`style = .regular` 在浅色主题下提亮、在深色主题下压暗内容以保证上面的文字可读；`.clear` 几乎不模糊也不调色，适合放在照片和视频上。`tint` 是直通 alpha 颜色，按 alpha×0.88 向它混合；`noise` 是 0–1 的颗粒幅度，按物理像素固定，默认 0。深浅由主题背景亮度判断。
- `blur`：只模糊，不调色、不加边光。`radius` 是 DIP 高斯标准差；`mask` 让模糊沿一条线渐变：`from`/`to` 是起止 alpha（255 为全半径，0 为不模糊），`angle` 用 CSS 渐变角度（180 从上到下，0 从下到上，90 从左到右），`start`/`end` 是起止位置占线长的比例。
- `scroll_edge`：滚动内容与控件栏交界处的边缘。`hard = false`（柔和）把背景色从 85% 不透明渐隐到 0，不读取下方内容，任何后端都可绘制；`hard = true` 把下方内容以 6.4 DIP 模糊、降低饱和度后与背景色按 82.45% 混合，并在栏外侧画一条发丝线（浅色为 10% 黑、深色为 7% 白，宽 max(0.5 DIP, 1 物理像素)）。`bottom` 把栏放在底边，`background` 默认取主题背景。柔和样式建议比栏高 10 DIP。

### 玻璃的像素模型

设 m 为形状较短边（DIP），s 为缩放：

- 模糊：`.regular` 的标准差为 `clamp(0.035·m, 1, 10)·s` 像素，`.clear` 为 1·s。
- 弧面：边缘宽 `bezel = min(36, m/2)·s` 像素的区域按超椭圆截面 `(1−u⁴)^¼` 以折射率 1.5 折射，采样点沿边缘法线向内偏移，最大偏移 `1.6·bezel`；离边缘越远偏移越小，到 bezel 内侧为 0。圆角处的法线按 1.5 倍圆角计算。
- 亮度映射：亮度 `l` 按 `low + (high−low)·(1−(1−l)^curve)` 映射，色度按 `(high−low)·saturation` 缩放：浅色 regular 为 0.541/1/1.2/1，深色 regular 为 0.15/0.51/2/2.2，clear 为 0.125/1.082/1/1。
- 边光：距边缘 3 像素内加一条 1 像素宽的高斯衰减高光，强度 0.35，光来自上下两侧（左右边缘不亮）。
- 结果不透明，按形状的抗锯齿覆盖和裁剪覆盖写回；不投影。

渐变模糊按 `blurLevels` 分级：从最大模糊逐次减半到 2 像素，每级只补足方差 `√(hi²−lo²)`，逐像素按所在位置的模糊量在相邻两级之间插值。

### 工作区与预算

`prepareBackdropEffects` 显式分配三块大小为 `max_pixels` 的 BGRA 平面（默认 1 Mi 像素，即 12 MiB；总量上限 256 MiB），在 detach 或 `releaseBackdropEffects` 时释放；重复调用替换旧工作区。正常绘制不分配。每个效果的采样区为“形状∩裁剪”向外扩展模糊半径（≤128 像素）和折射偏移；采样区超过 `max_pixels` 时该效果画不透明后备色，`stats.fallbacks` 加一，其余效果照常。尚未准备工作区时，效果直接录制为不透明后备填充，`unprepared` 计数。一个 Buffer 最多 16 个背景效果，超过返回 `BackdropsFull`。

### 系统偏好

`Context.setBackdropPreferences(.{ .reduce_transparency, .high_contrast })` 由宿主根据 `ziggurat_system.desktop.preferences` 等来源显式设置，变化时请求重绘。任一为真时所有效果都录制为普通不透明填充（GPU 也能画）：玻璃取主题背景与白色（深色为控件色）的混合，并叠加 tint；模糊取主题背景，带 mask 时按 mask 的 alpha 画背景色渐变；滚动边缘取背景色，hard 样式保留发丝线。高对比度下玻璃再描 1 DIP 主题边框色。

## 加载动画

```zig
const phase = ui.loading.phase(.ring, elapsed_ns, 0);
frame.loadingIndicator(bounds, .ring, phase, ui.Color.rgb(0x2050a0), .{ .cap = .flat });
```

`Frame.loadingIndicator(bounds, kind, phase, color, options)` 把指示器按其宽高比放入 `bounds` 居中绘制。`phase` 是已完成的周期数，小数部分决定姿态；`loading.phase(kind, elapsed, duration)` 由经过的纳秒数换算，`duration = 0` 用该指示器自己的周期。模块不持有时钟、不安排帧也不分配；是否以及何时重绘由调用者决定（视图层在动画时每帧请求一次唤醒，静止时不请求）。一个 Buffer 最多 16 个指示器，超过返回 `IndicatorsFull`。

29 种指示器（`loading.all` 按此顺序）及周期：Arc 800 ms、Atom 1000、Blocks 1300、Bouncing dots 500、Cascade 1500、Circular dots 800、Classic 1200、Classic v2 800、Clock 1200、Comet 700、Compass 500、Dual 1000、Eclipse 1200、Flip 1200、Gather 1600、Leap 1800、Linear dots 900、Loading 1000、Morph 1200、Orbit 750、Pulse 1200、Radar 1500、Ring 800、Ripple 1200、Slide 2400、Snake 1400、Swirl 1200、Trace 1200、Wave 900。默认高 20 DIP，两种点行（Bouncing dots、Linear dots）宽为高的两倍，其余为正方形。

`Options` 中的变化各自只作用于部分指示器：`easing`（linear/ease_in_out/stacked）用于 Arc、Atom、Clock、Comet、Dual、Orbit、Radar、Ring、Snake、Trace；`cap`（round/flat）用于 Arc、Cascade、Dual、Ring、Snake、Trace；`sweep`（diagonal/rows/columns）用于 Blocks；`direction`（out/in）用于 Ripple；`origin`（center/bottom）用于 Wave。

## 验证范围

`zig build test-ui` 覆盖弧面折射函数端点、模糊分级、亮度映射端点、均匀与渐变模糊、玻璃提亮/压暗与上下边光、hard 边缘调色、裁剪与透明层 alpha、工作区超限后备、分配失败、偏好后备与录制回滚、每种指示器的墨迹/周期重复/越界检查及各选项的影响，并在 Cairo 与 GDI 渲染器上回放。`zig build smoke-backdrop` 在隐藏窗口里检查实际像素：玻璃提亮黑条、模糊跨黑白边界渐变、效果外像素不变、指示器换姿态、减少透明度与小工作区的后备，以及 detach 释放工作区。D3D11 下的软件改道由 Windows CI 的同一 smoke 覆盖。这些是行为与资源检查，不是视觉质量或性能结论；GPU 上的背景采样尚未实现。

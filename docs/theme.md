# 显式控件主题

`ui.Theme` 是拥有型Palette和Metrics值，包含基础控件实际使用的RGB颜色、边框、内距、indicator、thumb和track尺寸。没有字符串借用、allocator、OS观察器或全局主题。light保留现有基础控件默认颜色与尺寸，另有dark、highContrast预设；应用可以复制后定制。预设不是系统高对比模式或屏幕阅读器认证。

```zig
var custom = ui.Theme.dark();
custom.palette.accent = 0xd87936;
custom.metrics.label_gap = 10;
_ = try context.setTheme(custom);
```

setTheme先完整校验，成功复制并递增非回绕themeVersion，附着时请求完整窗口失效；相同主题不递增也不重新失效。颜色只能为24位RGB，所有尺寸有限、非负且不大于256 DIP，indicator/thumb/track尺寸为正。失败保留完整旧值。绘制、组合输入和attach/detach过渡中返回Busy；已附着时先检查owner主线程和Window寿命。关闭后的独立Context仍可由宿主独占配置，下次attach保留选定主题。

button、checkbox、radio、switch、progress、slider、双端范围和stepper使用同一主题；Frame.currentTheme为应用自己的draw返回值副本。窗口背景仍由应用明确clear，示例为`frame.clear(frame.currentTheme().palette.background)`。已有带显式Colors的文档/代码视图继续由宿主传入颜色；字体、Prepared布局及其版本仍由原文本owner显式准备，不因更换Palette隐式重建字体。系统外观偏好与reduce motion由宿主显式选择并交给对应owner。

主题更改发生在更新阶段；下一成功Frame一起发布命令、命中和语义。失败Frame保留旧已提交内容与身份。没有每次draw分配、额外timer或按控件身份维护的全局样式缓存。Metrics改变可能影响控件内部几何，宿主仍负责传入新的外部布局bounds。

`zig build test-ui smoke-theme` 验证完整值复制、每个字段的无效输入、Busy/Closed/错误线程/代数耗尽，以及自定义颜色的实际控件像素、绘制中拒绝更改和失败帧保留旧front。原有widgets/range原生交互检查继续运行；检查不包含截图或人工视觉结论。

## 广色域颜色

`ui.Color.oklch(l, c, h)` 对应 CSS 的 `oklch(l c h)`：亮度 0 到 1，色度约 0 到 0.4，色相为角度；`withAlpha(a)` 给出 `oklch(l c h / a)`。Display P3 显示不了的颜色先像 CSS 那样保持亮度和色相、降低色度，负色度按 0 处理。`ui.Color.displayP3(r, g, b)` 对应 `color(display-p3 r g b)`。Windows 与 Linux 窗口按 sRGB 绘制，所以 sRGB 之外的颜色显示为按 CSS Color 4 色域映射找到的最近 sRGB 颜色；`hex()` 返回调色板和 `Style.background` 使用的 0xRRGGBB：

```zig
var custom = ui.Theme.dark();
custom.palette.accent = ui.Color.oklch(0.72, 0.19, 250).hex();
```

`ui.gamut` 提供底层的 sRGB/Display P3/Oklab/Oklch 转换与 `map`（CSS Color 4 色域映射）。

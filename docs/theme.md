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

## 强调色与跟随桌面

`theme.withAccent(accent)` 返回一份换成强调色 `accent`（0xRRGGBB）的主题副本，并按主题的明暗给出它的各级色调：`pressed`（选中与按下的底色）和 `focus`（焦点环）是强调色叠在背景上（浅色主题 25% 与 55%，深色主题 40% 与 60% 的提亮强调色），`focused_thumb_border` 是加深的强调色（深色主题里提亮），`on_accent` 为白色，强调色亮如黄色时改为接近黑色。明暗按背景亮度判断。`null` 保留主题原有的强调色，对应桌面没有强调色的情况（Linux）。应用自己的主题这样取桌面强调色或品牌色：

```zig
const desktop = try system.desktop.preferences(app);
var theme = ui.Theme.dark().withAccent(desktop.accent);
theme.metrics.label_gap = 10;
_ = try context.setTheme(theme);
_ = try context.setTheme(ui.Theme.light().withAccent(0x7c3aed)); // 品牌色
```

`theme.withPreferences(.{ .accent, .high_contrast, .text_scale })` 返回跟随桌面设置的副本：取桌面强调色（同 `withAccent`），高对比度时边框与禁用文字向文字色靠近、焦点环取不透明的强调色、`scrollbar` 里半透明的颜色加强，`font_size` 放大到 `text_scale` 倍（限制在 0.5 到 4 倍）。已经跟随过的主题（`withPreferences` 返回的）再次跟随时，先撤回上次跟随改动的颜色，因此高对比度不会叠加加强，关掉的设置能恢复，而之后应用自己改过的颜色保留。桌面偏好变化时（`system.desktop.Watch` 的 `preferences`）对当前主题再调用一次即可：

```zig
fn followDesktop(context: *ui.Context, theme: ui.Theme, desktop: system.desktop.Preferences) !void {
    _ = try context.setTheme(theme.withPreferences(.{ .accent = desktop.accent, .high_contrast = desktop.high_contrast, .text_scale = desktop.text_scale }));
}
```

`Theme.font_size`（默认 16，即 `Font{}` 的大小）是不自带字体的文字的字号：控件的标签（`Frame.label`）和视图里没有 `Style.font` 的文本与链接，视图按它测量与绘制；设了 `Style.font` 的文字保持自己的字号。

## 广色域颜色

`ui.Color.oklch(l, c, h)` 对应 CSS 的 `oklch(l c h)`：亮度 0 到 1，色度约 0 到 0.4，色相为角度；`withAlpha(a)` 给出 `oklch(l c h / a)`。Display P3 显示不了的颜色先像 CSS 那样保持亮度和色相、降低色度，负色度按 0 处理。`ui.Color.displayP3(r, g, b)` 对应 `color(display-p3 r g b)`。Windows 与 Linux 窗口按 sRGB 绘制，所以 sRGB 之外的颜色显示为按 CSS Color 4 色域映射找到的最近 sRGB 颜色；`hex()` 返回调色板和 `Style.background` 使用的 0xRRGGBB：

```zig
var custom = ui.Theme.dark();
custom.palette.accent = ui.Color.oklch(0.72, 0.19, 250).hex();
```

`ui.gamut` 提供底层的 sRGB/Display P3/Oklab/Oklch 转换与 `map`（CSS Color 4 色域映射）。

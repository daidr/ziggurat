# 原生 UI

Ziggurat 的原生 UI 由框架自己绘制，不依赖系统控件库。分两层：

- **`ziggurat_view`**：声明式视图。应用写一个构建函数，从当前状态描述整棵视图树；Host 用弹性布局测量、排列，再录制成绘制帧。大多数应用只用这一层。
- **`ziggurat_ui`**：底层。`ui.Context` 的绘制回调直接向 `ui.Frame` 录制矩形、文字、图片和控件，适合完全自定义的画面（游戏、可视化、编辑器）。声明式视图建立在它之上，两者使用同一套控件、命中测试、可访问性语义和主题规则。

绘制在 Windows 上使用 GDI，Linux 上使用 Cairo/Pango，macOS 上使用 Core Graphics；`-Dgpu=true` 时改用 D3D11、OpenGL 或 Metal，保留软件回退。同一份应用还能编译成 WebAssembly 在浏览器中运行（[浏览器](../browsers.md)）。

## 构建函数

```zig
const view = @import("ziggurat_view");

const Settings = struct {
    name_visible: bool = true,
    volume: f64 = 0.5,
    theme: enum { light, dark, system } = .system,

    fn build(self: *Settings, v: *view.View) anyerror!void {
        try v.text("设置", .{ .font = view.Font.heading2 });
        _ = try v.toggleSwitch(&self.name_visible, "显示名称", .{});
        try v.row(.{ .gap = 8, .alignment = .center });
        try v.text("音量", .{});
        _ = try v.slider(&self.volume, .{ .minimum = 0, .maximum = 1, .step = 0.05 }, .{ .grow = 1 });
        try v.end();
        try v.segmented(.{ .name = "主题" });
        _ = try v.segment(@TypeOf(self.theme), &self.theme, .light, "浅色", .{});
        _ = try v.segment(@TypeOf(self.theme), &self.theme, .dark, "深色", .{});
        _ = try v.segment(@TypeOf(self.theme), &self.theme, .system, "跟随系统", .{});
        try v.end();
    }
};

var settings: Settings = .{};
var storage: view.Storage(64, 2048) = .{};
var host = view.Host.init(&settings, Settings.build, storage.buffers(), .{});
try host.attach(window);
```

关键规则：

- **控件绑定字段**。`checkbox`、`toggleSwitch`、`slider`、`segment` 等直接接收应用字段的指针，用户操作时由视图更新它们。
- **事件以返回值交给构建函数**。`button` 在被激活的那一遍返回 `true`；把副作用写在 `if` 分支里。构建函数应只依据状态描述视图，可以重复运行。
- **何时运行**。每次绘制运行一遍；每个输入事件也立即运行一遍并携带该事件，所以连续输入在重绘之前逐个作用于状态，不会被合并吞掉。
- **身份**。节点 ID 由父节点、兄弟序号和种类得到，跨帧稳定。顺序会变化的节点（列表项）给出 `Style.key`，`view.key(text)` 从字符串派生键。
- **固定存储**。`view.Storage(nodes, text_bytes)` 提供节点与文本的固定缓冲，绘制路径不分配；超出容量时这一帧失败并保留上一帧，错误记在 `host.last_error`。
- **地址稳定**。状态、存储和 Host 从 attach 到 detach 保持地址不变。

## 布局与样式

`column`/`row` 与 `end` 配对构成弹性布局，`grid(columns, style)` 按列轨道排列，`scroll(&model, style)` 是纵向滚动容器。一个 `Style` 同时描述容器本身和它在父布局中的参与方式：

```zig
try v.column(.{
    .gap = 12,
    .padding = .all(16),
    .alignment = .stretch,
    .background = 0xffffff,
    .radius = 12,
    .border = 0xe2e8f0,
    .border_width = 1,
    .grow = 1,
    .min_width = 240,
});
```

- 容器：`gap`、`padding`、`alignment`、`justify`、`clip`、`background`、`gradient`、`border`、`radius`、`material`（玻璃等背景效果）。
- 参与：`grow`、`shrink`、`self_align`、`width`/`height`、`min_*`/`max_*`、网格的 `column_span`、`sticky`。
- 文本与可访问性：`color`、`font`、`letter_spacing`、`name`（无可见标签时的可访问名称）、`enabled`。
- 显示：`hidden` 让节点隐藏并让出位置，但其中内容照常构建、状态保留。

细节见 [声明式视图](../view.md#布局) 与 [布局](../layout.md)。颜色、圆角、字号等主题令牌见 [主题](../theme.md)；应用自带字体见 [应用字体](../fonts.md)。

## 文本输入

可编辑文本不是用按键事件拼出来的：`ziggurat_view_text` 的字段建立在原生文本路径上，系统输入法、候选窗位置、选区、撤销与剪贴板都来自平台。

```zig
const text = @import("ziggurat_view_text");

var field = text.TextField.init(editor, &host, .{ .font = .{ .size = 16 } }, .{ .name = "名称" });
// 构建函数中：
try v.embed(field.embed(), .{ .grow = 1, .key = 7 });
```

单行与多行字段、校验、可编辑组合框和标记输入框见 `examples/text_input.zig`；大文档编辑见 [大文档编辑桥](../document-editor.md)，富文本见 [富文本编辑器](../rich-text-editor.md)，代码编辑见 [可选代码编辑服务](../code-editor.md)。

## 输入、焦点与可访问性

- Tab 在可聚焦控件之间移动，方向键在分组内移动，Enter/Space 激活；`v.bindKey(chord, window, action)` 绑定快捷键，`Options.keys` 接收没有被处理的按键。
- `pointerArea` 报告悬停、单击、双击、右击与拖动，`Style.cursor` 设置指针形状。
- 每个控件都有可访问性语义（角色、名称、值、状态）。`-Daccessibility=true` 构建原生可访问性桥：Windows UI Automation、macOS NSAccessibility、Linux ATK。`labelledBy`、`describedBy`、`errorMessage` 建立控件之间的关系，`v.announce(message)` 向读屏器播报。
- `Options.direction` 支持从右到左布局。

## 动画与效果

视图内置不透明度、模糊、位姿、进出场、共享元素与滚动滑动，也可以用 `wakeAt` 驱动自己的动画，见 [动画与唤醒](../guide/animation.md)。玻璃材质与加载指示器见 [背景效果与加载动画](../backdrop-effects.md)，自定义着色器见 [着色器与元素效果](../shader-effects.md)。

## 测试与检查

- `view.Harness` 不创建窗口，运行与 Host 相同的构建、排列和事件遍：按查询找控件、点击、拖动、键入，再检查状态和视图树大纲。见 [无窗口测试](../view.md#无窗口测试)。
- Debug 构建带有视图检查器（inspector），可以查看节点树、边界与样式。见 [开发者工具](../view.md#开发者工具（inspector）)。
- 驱动一个正在运行的应用（给测试脚本或代码代理用）见 [自动化](../automation.md)。

## 控件

所有控件按类别列在 [控件速查](./components.md)。较大的组件有自己的模块与文档：

| 组件 | 模块 | 文档 |
| --- | --- | --- |
| 虚拟列表、表格、大纲、网格视图 | `ziggurat_view_collections` | [虚拟集合](../collections.md) |
| 日历、日期/时间/数字输入、颜色选择器 | `ziggurat_view_pickers` | [选择器](../pickers.md) |
| Markdown 显示与流式回复 | `ziggurat_markdown_view` | [Markdown](../markdown.md) |
| 富文本段落与编辑器 | `ziggurat_view_rich_text`、`ziggurat_rich_text_editor` | [富文本](../rich-text.md) |
| 图表 | `ziggurat_chart`、`ziggurat_chart_view` | [图表](../chart.md) |
| 图片、SVG、图标 | `ziggurat_view_graphics` | [图片、SVG 与图标](../view.md#图片、svg-与图标) |
| 视频 | `ziggurat_view_video`、`ziggurat_video` | [视频](../view.md#视频) |
| 终端 | `ziggurat_terminal_view` | [终端](../terminal.md) |
| 页面 | `ziggurat_webview_view` | [视图中的 WebView](../embedded-webview.md) |

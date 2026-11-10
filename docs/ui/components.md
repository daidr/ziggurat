# 控件速查

这一页按类别列出 `ziggurat_view` 的控件和它们的调用形式。所有调用都在构建函数里，`v` 是 `*view.View`，最后一个参数是 `Style`。绑定型控件接收应用字段的指针；返回 `bool` 的控件在用户激活或改变它的那一遍返回 `true`。容器与 `end` 配对。

每个控件的完整规则（键盘、焦点、可访问性映射、容量）见 [声明式视图](../view.md)；整体概念见 [原生 UI 概览](./)。可交互的总览示例是 `examples/gallery.zig`（`zig build run-gallery`）。

## 文本与静态内容

| 调用 | 说明 |
| --- | --- |
| `text(value, style)` / `textf(fmt, args, style)` | 文本，`Style.font` 选字体（`view.Font.heading1`…`heading5`、`code`） |
| `badge(text, style)` | 圆角背景上的短标签 |
| `spacer(style)` | 占据剩余空间 |
| `avatar(name, picture, style)` | 头像：图片或名称首字母 |
| `icon(which, options, style)` / `image(...)` / `svg(...)` | 图标、位图与 SVG，见 [图片与媒体](#图片与媒体) |

```zig
try v.text("概览", .{ .font = view.Font.heading2 });
try v.textf("{d} 个文件", .{count}, .{ .color = 0x64748b });
try v.text("zig build test", .{ .font = view.Font.code });
```

## 操作

| 调用 | 说明 |
| --- | --- |
| `button(label, style) → bool` | 按钮；`Style.enabled = false` 禁用 |
| `link(label, style) → bool` | 链接样式的文字按钮，打开什么由应用决定 |
| `navButton(direction, style) → bool` | 后退/前进/上/下箭头按钮 |
| `toolbar(style)` … `end` | 一行工具控件，作为工具栏暴露给辅助技术 |
| `popoverMenuButton(label, style) → bool` | 打开菜单的按钮，见 [菜单与浮层](#菜单与浮层) |
| `splitButton(label, options, style) → SplitButton` | 按钮连着相关操作的菜单，见 [菜单与浮层](#菜单与浮层) |
| `pointerArea(options, style)` … `end` | 自定义可点击区域：悬停、单击、双击、右击、拖动 |

```zig
try v.toolbar(.{ .name = "编辑" });
if (try v.button("撤销", .{ .enabled = history.canUndo() })) history.undo();
if (try v.button("重做", .{ .enabled = history.canRedo() })) history.redo();
try v.end();

const row = try v.pointerArea(.{}, .{ .padding = .all(8), .cursor = .pointer });
try v.text(item.name, .{});
try v.end();
if (row.double_clicked) self.open(item);
if (row.right_clicked) self.showMenu(item, row.bounds.?);
```

## 选择

| 调用 | 绑定 | 说明 |
| --- | --- | --- |
| `checkbox(&checked, label, style)` | `bool` | 复选框 |
| `checkboxGroup(label, items, style)` | 各项 `bool` | 带三态“全选”的复选框组 |
| `toggleSwitch(&on, label, style)` | `bool` | 开关 |
| `radioGroup(style)` + `radio(T, &selected, option, label, style)` | 任意 `T` | 单选组 |
| `segmented(style)` + `segment(T, &selected, option, label, style)` | 任意 `T` | 分段控件 |
| `comboBox(current, style)` + `comboOption(T, &selected, value, label, style)` | 任意 `T` | 下拉选择 |
| `slider(&value, range, style)` | `f64` | 滑块 |
| `stepper(&value, range, style)` | `f64` | 步进器 |
| `rating(&score, count, style)` | `u8` | 评分 |

```zig
const Sort = enum { name, date, size };

try v.radioGroup(.{ .name = "排序" });
_ = try v.radio(Sort, &self.sort, .name, "名称", .{});
_ = try v.radio(Sort, &self.sort, .date, "日期", .{});
_ = try v.radio(Sort, &self.sort, .size, "大小", .{});
try v.end();

try v.comboBox(@tagName(self.sort), .{ .name = "排序" });
_ = try v.comboOption(Sort, &self.sort, .name, "name", .{});
_ = try v.comboOption(Sort, &self.sort, .date, "date", .{});
try v.end();

_ = try v.slider(&self.volume, .{ .minimum = 0, .maximum = 1, .step = 0.05 }, .{ .grow = 1 });
```

日期、时间、数字、精确小数与颜色的输入在 `ziggurat_view_pickers` 中，见 [选择器](../pickers.md)。

## 文本输入

| 调用 / 类型 | 模块 | 说明 |
| --- | --- | --- |
| `text.TextField` + `embed(field.embed(), style)` | `ziggurat_view_text` | 单行或多行文本字段，系统输入法、选区、撤销 |
| `search(style)` … `end` | `ziggurat_view` | 搜索区域，常与 `suggestions` 搭配 |
| `suggestions(style)` + `suggestion(label, style)` | `ziggurat_view` | 输入下方的建议列表（自动完成） |
| `editableComboBox(value, style)` | `ziggurat_view` | 可输入的组合框 |
| `tokenField(style)` + `token(label, style)` | `ziggurat_view` | 标记输入框 |
| `editableText(&state, value, input, options, style)` | `ziggurat_view` | 平时显示文字、双击进入编辑 |
| `findBar(&bar, input, matches, texts, style)` | `ziggurat_view` | 查找栏：上一个/下一个、选项 |
| 富文本编辑器 | `ziggurat_rich_text_editor` | 见 [富文本编辑器](../rich-text-editor.md) |
| 代码编辑器、Diff | `ziggurat_code_editor`、`ziggurat_document_diff_view` | 见 [代码编辑](../code-editor.md)、[文档对比](../document-diff-view.md) |

```zig
try v.search(.{ .name = "查找城市" });
try v.embed(query.embed(), .{ .grow = 1, .key = 1 });
try v.suggestions(.{ .name = "城市" });
for (cities) |city| if (std.mem.startsWith(u8, city, prefix)) {
    if (try v.suggestion(city, .{ .key = view.key(city) })) choose(city);
};
try v.end();
try v.end();
```

## 表单

| 调用 | 说明 |
| --- | --- |
| `field(label, info, style)` … `end` | 表单字段：标签、内容、帮助或错误；`info.required` 标记必填 |
| `fieldset(legend, style)` … `end` | 一组相关字段 |

```zig
try v.field("邮箱", .{ .required = true, .@"error" = if (self.email_valid) null else "邮箱格式不正确" }, .{});
try v.embed(self.email.embed(), .{ .key = 1 });
try v.end();
```

验证由应用决定；有错误时字段内的控件被标为无效，读屏器会读出错误。

## 集合

| 调用 | 说明 |
| --- | --- |
| `listBox(style)` + `listItem(T, &selected, option, label, style)` | 单选列表 |
| `tree(&selection, style)` + `treeItem(id, &expanded, label, style)` … `end` | 树，支持多选 |
| `table(columns, &sort, &selection, style)` + `tableRow(id, name, style)` | 可排序表格 |
| `reorder()`、`dragRows(kind)`、`dragSelect()` | 拖动排序与框选 |
| 虚拟列表、表格、大纲、网格视图 | `ziggurat_view_collections`，只构建可见行，见 [虚拟集合](../collections.md) |

```zig
try v.tree(&selection, .{ .name = "文件" });
for (roots) |entry| {
    _ = try v.treeItem(entry.id, if (entry.branch) &open[entry.id] else null, entry.name, .{});
    if (entry.branch and open[entry.id]) try children(v, entry.id);
    try v.end();
}
try v.end();
```

## 容器与布局

| 调用 | 说明 |
| --- | --- |
| `column(style)` / `row(style)` … `end` | 弹性布局 |
| `grid(columns, style)` … `end` | 网格，列轨道为 `fixed`、`fraction`（如 CSS 的 `fr`）、`minmax` |
| `scroll(&model, style)` … `end` | 纵向滚动容器，`ScrollModel` 由应用持有；支持 sticky 与吸附 |
| `split(axis, &fraction, limits, style)` … `end` | 可拖动分栏，恰好两个子节点 |
| `disclosure(&expanded, label, style)` | 折叠区标题 |
| `accordion(style)` + `section(T, &open, option, label, style)` | 手风琴 |
| `themed(&theme, style)` … `end` | 在子树里换一套主题 |
| `presentColumn(&presence, show, transition, style)` … `end` | 带进出场动画的列 |

```zig
try v.split(.row, &self.sidebar_fraction, .{ .minimum = 0.15, .maximum = 0.5 }, .{ .grow = 1 });
try v.column(.{ .padding = .all(12) });
try buildSidebar(v);
try v.end();
try v.scroll(&self.page_scroll, .{ .grow = 1 });
try buildPage(v);
try v.end();
try v.end();
```

## 导航

| 调用 | 说明 |
| --- | --- |
| `tabs(style)` + `tab(T, &selected, option, label, style)` | 标签页；内容由应用在 `end` 之后按所选值构建 |
| `sidebar(&selection, style)` + `sidebarSection(...)` + `sidebarItem(...)` | 侧边栏 |
| `breadcrumbs(style)` … `end` | 面包屑 |
| `view.Router` + `route`、`backButton`、`forwardButton` | 路由与历史，路径模式如 `/notes/{id}` |

```zig
var entries: [32]view.RouteEntry = undefined;
var router = try view.Router.init(&entries, "/notes");

// 构建函数中：
try v.toolbar(.{});
_ = try v.backButton(&router, .{});
_ = try v.forwardButton(&router, .{});
try v.end();
const page = try v.route(&router, .{});
if (page.match("/notes")) {
    for (notes) |note| if (try v.button(note.title, .{ .key = note.id })) try router.push(note.path);
} else if (page.match("/notes/{id}")) {
    try showNote(v, page.param("id"));
}
try v.end();
```

## 菜单与浮层

| 调用 | 说明 |
| --- | --- |
| `popoverMenu(style)` + `menuItem(label, options, style)`、`menuSeparator()`、`submenu(label, style)` | 视图内的菜单，附在前一个节点上 |
| `popupButton(value, expanded, style)` + `popover(&open, placement, style)` … `end` | 浮在窗口上的面板 |
| `popoverPresent(&open, &presence, transition, placement, style)` | 带进出动画的浮层 |
| `dialog(&open, options, style)` … `end` | 对话框，遮罩窗口其余部分 |
| `alertDialog(&open, alert, style) → ?usize` | 警告对话框，返回按下的按钮 |
| `tooltip(text)` | 给前一个节点加提示 |
| `view.Toasts(capacity)` + `toasts(&queue, style)` | 窗口底部的通知 |

```zig
if (try v.button("删除…", .{})) confirm = true;
if (try v.alertDialog(&confirm, .{ .title = "删除文件？", .message = "此操作无法撤销。", .buttons = &.{ "取消", "删除" }, .default = 0, .cancel = 0 }, .{})) |answer| {
    if (answer == 1) try remove(current);
}

try v.text(document.name, .{});
if (try v.popoverMenu(.{ .name = "Document" })) {
    if (try v.menuItem("Copy", .{ .shortcut = "Ctrl+C" }, .{})) copy();
    try v.menuSeparator();
    if (try v.menuItem("Wrap lines", .{ .checked = wrap }, .{})) wrap = !wrap;
}
try v.end();
```

需要系统原生的菜单栏、上下文菜单与消息框时，用 `system.Owner`，见 [菜单、托盘与桌面 API](../guide/desktop.md)；浮出到窗口之外的面板用 `system.Flyout`。

## 状态与反馈

| 调用 | 说明 |
| --- | --- |
| `progress(fraction, style)` | 进度条 |
| `loadingIndicator(kind, look, style)` | 29 种加载指示器，见 [背景效果与加载动画](../backdrop-effects.md#加载动画) |
| `meter(value, range, bands, style)` | 只读度量条，区间外用警示色 |
| `announce(message)` | 向读屏器播报 |

## 图片与媒体

```zig
const graphics = @import("ziggurat_view_graphics");

var icons = graphics.Icons.init(allocator, &host);
host.view.icons = icons.painter();
var logo = try graphics.SvgImage.init(allocator, &host, logo_bytes, .{});

// 构建函数中：
try v.icon(.settings, .{}, .{ .color = 0x4a5568 });
try v.svg(logo.picture(), .{ .alt = "Ziggurat" }, .{ .height = 32 });
try v.image(photo.view(), .{ .fit = .cover, .alt = "封面" }, .{ .width = 120, .height = 80 });
```

- 动画 GIF、APNG 与 YUV 帧：`ziggurat_view_video`；系统媒体框架播放的视频（带声音）：`ziggurat_video`。见 [视频](../view.md#视频)。
- 图表：`ziggurat_chart_view`，见 [图表](../chart.md)。
- Markdown：`ziggurat_markdown_view`，见 [Markdown](../markdown.md)。
- 页面：`ziggurat_webview_view` 把系统 WebView 放进视图的一个盒子，见 [视图中的 WebView](../embedded-webview.md)。
- 终端：`ziggurat_terminal_view`，见 [终端](../terminal.md)。

## 拖动与拖放

| 调用 | 说明 |
| --- | --- |
| `draggable(&gesture, style)` | 拖动手势 |
| `dragSource(payload, style)` | 拖动源 |
| `dropTarget(accept, style) → DropState` | 放置目标 |
| `Host.systemDragOver` / `Host.systemDrop` | 把 `system.drop.Target` 的系统拖放交给视图 |

见 [声明式视图：拖动与拖放](../view.md#拖动与拖放)。

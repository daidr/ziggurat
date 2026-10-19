# 声明式视图

`ziggurat_view` 在 `ziggurat_ui` 之上提供声明式写法：应用写一个构建函数，从当前状态描述整棵视图树；`view.Host` 用弹性布局测量、排列，再录制成 Frame。控件直接绑定应用的值，激活结果以返回值交给构建函数。底层的控件、命中、语义与主题规则保持不变，见[基础控件](widgets.md)与[布局](layout.md)。

```zig
const view = @import("ziggurat_view");

const Counter = struct {
    count: i64 = 0,
    autosave: bool = false,
    volume: f64 = 0.5,
    fn build(self: *Counter, v: *view.View) anyerror!void {
        try v.textf("计数：{d}", .{self.count}, .{});
        try v.row(.{ .gap = 8, .alignment = .center });
        if (try v.button("加一", .{})) self.count += 1;
        try v.spacer(.{});
        if (try v.button("清零", .{ .enabled = self.count != 0 })) self.count = 0;
        try v.end();
        _ = try v.checkbox(&self.autosave, "自动保存", .{});
        _ = try v.slider(&self.volume, .{ .minimum = 0, .maximum = 1, .step = 0.05 }, .{ .self_align = .stretch });
    }
};

var counter: Counter = .{};
var storage: view.Storage(64, 2048) = .{};
var host = view.Host.init(&counter, Counter.build, storage.buffers(), .{});
try host.attach(window);
```

完整示例见 `examples/view_counter.zig`（`zig build run-view-counter`）。

## 构建与输入

Host 拥有一个 `ui.Context`，从 attach 到 Context 的 detach 回调期间必须保持地址稳定，规则与普通 Context 相同。构建函数在两种场合运行，都在主线程：

- **绘制**：每次 paint 运行一遍构建，随后测量、排列、录制。失败的帧保留上一帧，错误记录在 `host.last_error`。
- **输入**：Context 每交付一个动作或数值变化，或滚轮落在滚动容器上，Host 立即运行一遍构建并携带该事件。拥有该 ID 的控件在这一遍中消费事件：`button`/`link` 返回 true，`checkbox`/`toggleSwitch`/`disclosure` 翻转绑定的布尔值，`radio`/`segment`/`tab` 选中自己的选项，`slider`/`stepper`/`split` 对绑定的**当前值**应用 `ValueChange`，`scroll` 移动它的模型。这一遍不录制也不排列，`host.view` 里的节点边界要到下一次绘制才更新；Context 随后照常使窗口失效。

因此连续输入在重绘前逐个作用于状态，不会被重绘合并吞掉。事件的 ID 若已不在树中（例如上一个事件移除了该控件），这一遍不改变任何值。构建函数应只依据状态描述视图，可以重复调用；副作用放在控件返回 true 的分支里。

## 身份

每个节点的 ID 由父节点 ID、它在兄弟中的序号和节点种类哈希得到，跨帧稳定，种类变化即换新 ID。兄弟顺序会变化的节点（列表项、条件出现的控件之后的节点）应提供 `Style.key`；`view.key(text)` 从字符串派生键。同一父节点下键必须唯一，重复会在录制时被 Context 拒绝。

## 布局

隐式根节点是填满窗口的列，样式来自 `Options.root`（默认内边距 24、间距 12、交叉轴起始对齐）。`column`/`row` 与 `end` 配对，最多嵌套 32 层；单个容器最多 256 个子节点。测量自底向上、排列自顶向下，均调用 `ui.layout.measure/arrange`，不分配内存。

`Style` 同时描述容器与它在父布局中的参与方式：

- 容器：`gap`、`padding`、`alignment`（子项交叉轴对齐）、`justify`、`clip`、`background`、`border`、`border_width`、`radius`。
- 参与：`grow`、`shrink`、`self_align`、`width`/`height`（固定尺寸）、`min_*`/`max_*`，网格子项另有 `column_span`。
- 内容：文本的 `color`，控件的 `enabled`，进度条的可访问名称 `name`。

`spacer` 默认 `grow = 1`。叶子的固有尺寸来自文本宽度与主题 metrics：按钮在文本两侧留出内边距，复选框与开关加上指示器和标签间距，进度条与滑块有默认宽度且可以收缩到零，步进器宽度是高度的四倍，两端按钮为正方形。

### 网格

`grid(columns, style)` 与 `end` 配对，子项按行自动放置进 `ui.grid` 的列轨道（`Track.fixed`、`fraction`、`minmax`），每个子项占 `Style.column_span` 列，行高随内容。`gap` 同时是行距和列距，`padding` 与 `alignment`（单元格内两个方向的对齐）沿用容器字段，`clip` 决定是否裁剪溢出。网格自身的最小和首选尺寸分别以全部子项的最小、首选尺寸求得。`columns` 是借用的，只需在本遍排列完成前有效，通常用常量数组。

### 滚动

`scroll(&model, style)` 与 `end` 配对，开始一个纵向滚动、始终裁剪的列。`ui.scroll.ScrollModel` 由应用持有，跨帧保存偏移。它的最小高度为零，首选高度是内容高度，所以要让它出现滚动，需给它固定 `height`，或者在受限的父容器里用 `grow`/收缩。每次排列都会以视口和内容尺寸调用 `model.setSizes`，偏移随内容变化被夹回有效范围；子项按内容坐标排列后整体上移 `offset.y`，因此节点边界始终是窗口坐标。内容溢出时，右侧画一条不可交互的细滑块指示位置。

Host 在每帧绘制后记录可见的滚动容器（最多 `max_scroll_regions` 个，按绘制顺序），滚轮事件落在其中时交给最内层的那个，作为一个携带 `Event.scroll` 的构建遍立即作用于模型并消费该事件；不在任何滚动容器内的滚轮照常交给 Context。目前没有滚动条拖动、键盘滚动、焦点自动显露和横向滚动。

### 标签页、分栏与工具栏

`tabs(style)` 与 `end` 配对，开始一行标签，`Style.name` 是标签列表的可访问名称；其中的 `tab(T, &selected, option, label, style)` 与 `radio` 相同地绑定一个值，激活即选中，返回选择是否改变。标签共享一个 Tab 停靠点，方向键和 Home/End 在标签间移动并选中。标签页内容由应用在 `end` 之后按所选值自行构建，视图层不保存未选中页的状态。选中的标签有底部强调条，聚焦时画焦点框。

`split(axis, &fraction, limits, style)` 与 `end` 配对，**必须恰好两个子节点**，否则 `end` 返回 `InvalidSplit`。`axis = .row` 左右分栏，`.column` 上下分栏；两个子节点在交叉轴上填满，第一个占去掉 `split_divider`（6 DIP）后长度的 `fraction`，第二个占余下部分。`limits` 是 0..1 内的 `Range`，超出返回 `InvalidRange`，绑定值每遍都被夹回其中；`step = 0` 时指针连续拖动，键盘一步为范围的百分之一。分隔条的指针按下、拖动和松开都更新值，拖动期间捕获指针；方向键增减一步（上下分栏时向下增大），PageUp/PageDown 一页，Home/End 到上下限。分栏的最小尺寸是两个子节点的最小尺寸加分隔条，但窗口更小时仍按比例分配，子节点会溢出，需要时给它们 `clip` 或滚动容器。`Style.name` 是分隔条的可访问名称。

`toolbar(style)` 与 `end` 配对，开始一行工具控件，`Style.name` 是工具栏的可访问名称。其中的叶子控件（包括嵌套行列里的）把工具栏作为可访问父节点；嵌套的单选组或标签列表仍挂在窗口根下。工具栏不改变焦点顺序，也没有溢出菜单。

启用 `-Daccessibility=true` 时，Windows UIA 把标签列表映射为 Tab / Selection（单选），标签为 TabItem / SelectionItem，工具栏为 ToolBar，分隔条为 Thumb / 可写 RangeValue（值为第一栏比例，上下限即 `limits`）。Linux 没有为普通控件提供 AT-SPI 语义，这些角色同样只在 Windows 暴露。

### 链接、徽标、分段控件与折叠区

- `link(label, style)` 画成带下划线的强调色文字，激活方式与按钮相同，返回本遍是否被激活；打开什么由应用决定，视图层不处理 URL。
- `badge(text, style)` 是圆角背景上的短标签，背景默认强调色（`Style.background` 可改），文字默认 `on_accent`（`Style.color` 可改）。它只是静态文字，不可交互，也和普通文本一样不产生语义节点。
- `segmented(style)` 与 `end` 配对，开始一行首尾相接的分段，`Style.name` 是可访问名称；`segment(T, &selected, option, label, style)` 的选择规则与 `radio` 相同，选中的分段以强调色填充。语义上是单选组和单选按钮。
- `disclosure(&expanded, label, style)` 是带三角指示的展开标签，激活时翻转 `expanded`，返回是否改变；应用在它后面按 `expanded` 构建内容。

启用 `-Daccessibility=true` 时，Windows UIA 把链接映射为 Hyperlink / Invoke，分段为 RadioButton / SelectionItem（分组为 Group / Selection），折叠区为 Button / ExpandCollapse（已展开时 Expand、已折叠时 Collapse 不重复产生动作）。

## 文本测量

`Frame.label` 使用固定的 16px 单行字体。`Options.measurer` 决定文本节点与控件标签的宽度。默认的 `Measurer.estimate` 是保守估计（窄字符 9 DIP，宽字符 16 DIP，行高 24），不调用原生字体；需要精确宽度时，应用可以提供基于 `ziggurat_text_layout` 的测量回调。测量回调在 paint 中调用，应自行缓存，避免在常规绘制路径分配。

## 存储与容量

`view.Storage(nodes, text_bytes)` 是调用者拥有的固定存储，提供节点、文本副本、布局项与矩形缓冲。`text`、控件标签都会复制进存储，`textf` 直接格式化进存储，因此构建函数可以传入临时缓冲。超出容量返回 `TooManyNodes`、`TextFull`、`TooManyItems` 或 `NestingTooDeep`，容器不配对返回 `UnbalancedContainer`；绘制中的这些错误使本帧失败并保留上一帧。底层 Frame 的每帧上限（128 个控件、2048 条命令等）同样适用。

## 嵌入与文本输入

`embed(content, style)` 加入一个自己测量、放置和绘制的叶子，用于视图层不建模的内容。`Embed` 提供：

- `measure(context, theme)`：返回最小与首选尺寸，在排列时调用。
- `place(context, id, bounds)`（可选）：每个成功的帧排列后调用一次，告知稳定的节点 ID 和窗口坐标边界。它在 paint 内运行，不能准备、分配或阻塞，需要的工作要推迟到输入阶段。
- `paint(context, frame, id, bounds)`：在绘制顺序中的位置录制内容。

`ziggurat_view_text` 用它提供可编辑文本字段。应用持有 `ziggurat_document_editor.Field` 及其 Document 和 Engine，并在 Host attach 后调用一次 `host.context.prepareTextFields(allocator, .{})`：

```zig
const text = @import("ziggurat_view_text");

var field = text.TextField.init(editor, &host, .{ .font = .{ .size = 16 } }, .{ .name = "名称" });
// 在构建函数中：
try v.embed(field.embed(), .{ .grow = 1, .key = 7 });
```

字段的边界变化时（第一次出现、窗口尺寸或布局改变），`place` 只记录新边界并向 App 投递一个任务；该任务在绘制之外调用 `Field.prepare`，第一次还会以节点 ID `attach` 到 Host 的 Context，然后使窗口失效。在准备完成之前，字段沿用上一次准备时的位置绘制，因此焦点和命中与文本保持一致，最多滞后一帧。键盘、输入法、剪贴板、焦点切换和 text_box 语义都由 Field 与 Context 处理，视图层不转发这些输入。

TextField 与 Field 的地址必须保持稳定。节点 ID 用于注册，所以当前面的兄弟节点可能变化时要给它 `Style.key`；ID 改变会记录 `TextFieldIdChanged` 而不是静默重新注册。关闭时先调用 `field.detach()` 停止推迟的工作，再按 Field 的规则 `close`。投递或准备的失败记录在 `last_error`。

## 无窗口测试

`view.Harness` 不创建窗口，直接运行与 Host 相同的构建、排列和事件遍。测试用它按查询找控件、模拟激活，再检查应用状态和视图树：

```zig
var storage: view.Storage(64, 2048) = .{};
var counter: Counter = .{};
var h = view.Harness.init(&counter, Counter.build, storage.buffers(), .{});
try h.render();
try h.click(.{ .text = "加一" });
try std.testing.expectEqual(@as(i64, 1), counter.count);
try h.change(.{ .kind = .slider }, .{ .steps = 2 });
```

- `Query` 按 `kind`、精确的 `text`（标签或文本内容）、`name`（`Style.name`）和 `key` 匹配，所有给出的字段都必须相符。匹配多于一个返回 `Ambiguous`，用 `nth` 按构建顺序选其中之一；没有匹配返回 `NotFound`。`find` 返回节点，`count` 返回匹配数。
- `click` 只接受按钮、链接、复选框、开关、单选、分段、标签和折叠区；`change` 只接受滑块、步进器和分栏，`ValueChange` 与原生输入相同；`scroll(query, delta)` 只接受滚动容器，`wheel(x, y, delta)` 像 Host 一样把滚轮交给该点最内层的可见滚动容器。目标禁用返回 `Disabled`，被自身尺寸或任一裁剪祖先完全遮住返回 `Hidden`，种类不符返回 `NotActivatable` 或 `NotAdjustable`。
- 事件遍若没有控件消费该事件（构建已不再产生这个节点），返回 `Stale`，不会静默忽略。成功的事件之后自动重新渲染，节点与 `frames` 反映新状态。
- `at(x, y)` 返回该点最后绘制的可交互节点，尊重裁剪；`clickAt` 激活它。`visible(node)` 给出裁剪后的可见矩形，`view.divider(node)` 给出分栏的分隔条矩形。
- `write(writer)` 输出缩进的树大纲（种类、文本、名称、选中或数值、禁用、取整后的边界），适合与期望文本比较。
- `Config` 提供窗口边界、主题和 `Options`（根样式与测量回调），`resize` 改变边界并重新渲染。

Harness 不经过 `ui.Context`，把嵌入叶子当作不可交互的节点，不验证原生命中、焦点、键盘导航或可访问性，也不推进时间；这些仍由隐藏窗口 smoke 和原生检查覆盖。

## 当前范围

已提供列、行、网格、纵向滚动容器、标签页、分栏、工具栏、分段控件、折叠区、链接、徽标、文本、间隔、按钮、复选框、单选组、开关、确定进度、滑块、步进器、嵌入叶子和（通过 `ziggurat_view_text`）可编辑文本字段。分栏只接受比例偏好，没有 DIP 偏好、从右到左布局和折叠；工具栏没有溢出菜单。没有悬停状态、虚拟列表和动画；需要它们时可以直接使用 `ziggurat_ui` 的 Frame API。

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
- 内容：文本的 `color`，`enabled`（容器上为 false 时其下所有节点都禁用），没有可见标签的控件或具名容器的可访问名称 `name`。

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

### 面包屑、度量条、评分与手风琴

- `breadcrumbs(style)` 与 `end` 配对，开始一行通往当前页的链接，`Style.name` 是导航区域的可访问名称。相邻项之间的间隙中央画一个淡色斜杠，`Style.gap` 为 0 时间隙取 16 DIP。当前页通常是末尾的普通文本，和其他文本一样不产生语义节点。其中的控件把导航区域作为可访问父节点。
- `meter(value, range, bands, style)` 是只读度量条，例如已用存储；`Style.name` 是可访问名称。它报告值本身，而不是完成比例。`bands` 的 `low`/`high` 是首选区间，值在区间外时用主题的 `caution` 色填充。区间超出 `range` 或 `low > high` 返回 `InvalidRange`，值被夹回 `range`。
- `rating(&score, count, style)` 绑定一个 `u8` 分数，范围 0..`count`，`count` 为 1..`ui.widgets.max_rating`（10），否则返回 `InvalidRange`。按下或拖过第 k 个标记会把分数设为 k，方向键增减 1，Home 清零，End 设为满分；返回分数是否改变。标记画成圆点，已得分的用强调色填充。语义上它是步长为 1 的滑块。
- `accordion(style)` 与 `end` 配对，开始一列分节，`Style.name` 是分组的可访问名称。`section(T, &open, option, label, style)` 绑定一个 `?T`：激活未打开的节会打开它并关闭原来打开的节，激活已打开的节会把 `open` 设为 null；返回值是否改变。分节标题与 `disclosure` 外观相同，在 `accordion` 之外调用返回 `NotContainer`。应用在每个标题后按 `open` 构建内容，这些内容也挂在分组下。

启用 `-Daccessibility=true` 时，Windows UIA 把面包屑映射为带导航地标（LandmarkType = Navigation）的 Group，度量条为 ProgressBar / 只读 RangeValue（报告实际值与上下限，LocalizedControlType 为 "meter"），评分为 Slider / 可写 RangeValue，手风琴为 Group，分节为 Button / ExpandCollapse。

### 列表框

`listBox(style)` 与 `end` 配对，开始一列单选选项，`Style.name` 是可访问名称。`listItem(T, &selected, option, label, style)` 的选择规则与 `radio` 相同：激活或方向键移动即选中，返回选择是否改变，在 `listBox` 之外调用返回 `NotContainer`。选项是整行宽度，选中的一行以强调色填充。选项共享一个 Tab 停靠点，方向键和 Home/End 在选项间移动并选中，越过两端时回绕。

长列表放进 `scroll` 容器。输入选中某个选项后，下一次排列会滚动外层所有滚动容器，用最小的位移让它完整可见。这里的选项全部参与构建和排列，不做虚拟化；大量行请直接使用 `ziggurat_ui` 的虚拟列表。

启用 `-Daccessibility=true` 时，Windows UIA 把列表框映射为 List / Selection（单选），选项为 ListItem / SelectionItem。

### 表单字段

`field(label, info, style)` 与 `end` 配对，开始一个纵向排列的表单字段：先是标签，然后是 `end` 之前构建的内容，最后是 `info` 中的错误或帮助。内容至少要有一个节点，否则 `end` 返回 `InvalidField`。`Style.gap` 为 0 时间距取 4 DIP。`Field` 有三个字段：

- `help`：画在内容下方的淡色提示。
- `error`：非 null 时取代帮助，用 `caution` 色绘制，并把字段内的控件标为无效。是否出错由应用验证后决定，视图层不做验证。
- `required`：在标签后加 " *"，并把控件标为必填。

字段内的控件把帮助或错误作为可访问说明。没有自己名称的控件（例如滑块、步进器、文本框）以字段标签作为名称；按钮、复选框等保留自己的标签。

`fieldset(legend, style)` 与 `end` 配对，开始一列相关字段，先画图例文字，并作为以图例命名的分组暴露，其中的控件以它为可访问父节点。`Style.gap` 为 0 时取 8 DIP。和任何容器一样，`Style.enabled = false` 会禁用其中的全部控件。

启用 `-Daccessibility=true` 时，Windows UIA 把说明映射为 HelpText，错误映射为 IsDataValidForForm = false，必填映射为 IsRequiredForForm，字段集映射为 Group。

### 组合框与建议列表

- `comboBox(current, style)` 与 `end` 配对：先加入一个显示 `current`（当前选项的标签）的字段，再开始它的选项列表，用 `comboOption(T, &selected, value, label, style)` 构建选项。选项每一遍都参与构建和测量，但只在列表打开时放置和绘制；在列表之外调用 `comboOption` 返回 `NotContainer`。名称取 `Style.name`，在 `field` 里没有名称时取字段标签。
- 激活组合框、或在它有焦点时按 Down/Up 打开列表，当前选项预先高亮。打开时方向键与 Home/End 只移动高亮，焦点仍在组合框上；Enter 或 Space 选中高亮项，Escape、列表外的按下、Tab 或选中都会关闭列表，焦点回到组合框（Tab 随后照常移动焦点）。列表外的按下只关闭列表，不会同时激活下面的控件。
- `suggestions(style)` 与 `end` 配对，为刚加入的节点（通常是文本输入）开始一个建议列表，`suggestion(label, style)` 加入一条建议，选中的那一遍返回 true，应用在这个分支里把它写回输入。输入或某条建议有焦点、且至少有一条建议时列表打开；Down/Up/Home/End 移动高亮而不移动焦点，Enter 选中高亮项。选中或 Escape 后列表保持关闭，直到建议标签发生变化（例如继续输入）或再次按 Down；焦点离开时关闭。
- 同一时间最多打开一个列表。列表画在其余内容之上，宽度至少与锚点相同，最高 280 DIP，默认在锚点下方，下方放不下而上方空间更大时翻到上方，并始终夹在窗口内；超出高度的选项被裁剪。选项较多时把它们放进列表里的 `scroll` 容器，高亮项会以最小位移滚入可见区。
- 搜索输入可以放在 `search(style)` 里：它与 `end` 配对，开始一行（`Style.gap` 为 0 时取 8 DIP），作为以 `Style.name` 命名的搜索区域，其中的控件以它为可访问父节点。

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

启用 `-Daccessibility=true` 时，Windows UIA 把组合框映射为 ComboBox / ExpandCollapse / 只读 Value（值为当前标签），打开的列表为其子节点 List，选项为 ListItem；搜索区域为带搜索地标（LandmarkType = Search）的 Group。

### 浮层

- `popupButton(value, expanded, style)` 是一个显示 `value`（例如选中的日期）、画法和读法都像组合框的字段，按下、Enter 或 Space 激活的那一遍返回 true，应用在这个分支里切换紧随其后的浮层的开关。名称取 `Style.name`，在 `field` 里没有名称时取字段标签。
- `popover(&open, placement, style)` 与 `end` 配对，在前一个节点（锚点）旁边开始一个浮在窗口上的面板，`open` 为 true 时返回 true，只在这时构建内容，无论返回什么都要 `end`。`Placement` 选择放在锚点的哪一侧（默认下方）、沿该侧如何对齐（默认起始边）、与锚点的间距和是否至少与锚点同宽；这一侧放不下而对侧空间更大时翻到对侧，并始终夹在窗口内（`view.placePopover` 是同一计算）。内边距默认 8 DIP，面板画成带边框的圆角矩形。
- 浮层打开时焦点移到其中第一个可聚焦的控件（构建可以用 `v.restore` 另选，`v.popover_opened` 在打开的那一遍非空）。Escape 或在面板与锚点之外按下会清除 `open`；Escape、或焦点在里面时由构建关闭，焦点回到锚点；在外面的按下照常交给下面的控件。锚点禁用时浮层关闭。同一时间最多一个浮层。
- 由嵌入叶子组成的复合控件可以用 `takeEvent(id)` 取走本遍针对自己登记的子控件 id 的事件。

启用 `-Daccessibility=true` 时，Windows UIA 把 `popupButton` 映射为 ComboBox / ExpandCollapse，把浮层映射为本地化类型为 "popup" 的 Pane。日历、日期/时间/数字输入与颜色选择器见[选择器](pickers.md)。

### 提示、通知、导航按钮与头像

- `tooltip(text)` 给刚加入的节点（在组合框选项列表 `end` 之后则是组合框）加提示。指针停在控件上或控件持有焦点超过 `Options.tooltip_delay`（默认 500 ms）后，提示出现在控件下方（下方放不下时在上方），悬停优先于焦点。按下或 Escape 会隐藏它，直到指针或焦点移到另一个控件；窗口失去焦点时也会隐藏。提示文字同时作为控件的可访问说明（已有字段说明时保留字段说明）。没有前一个节点时返回 `NotContainer`。
- `view.Toasts(capacity)` 是应用持有的固定消息队列：`show(message, .{ .action, .duration })` 复制文本并返回 id，队列满时先移除最早的消息，文本过长返回 `TextTooLong`；`dismiss(id)` 移除一条。`toasts(&queue, style)` 把队列画成窗口底部居中的一叠消息，每条带可选的动作按钮和名为 "Dismiss" 的关闭按钮。时长从第一次显示的那一遍开始计算，0 表示一直显示；动作按钮移除消息并让 `toasts` 返回它的 id 一次。每条消息是礼貌型（Polite）实时区域，出现时由读屏播报。
- `navButton(direction, style)` 是画着朝 `direction`（back/forward/up/down）的箭头的方形按钮，激活的那一遍返回 true；名称取 `Style.name`，默认是英文的 "Back"/"Forward"/"Up"/"Down"。
- `avatar(name, picture, style)` 显示 `picture`（`ImageView`，按 cover 裁剪）或 `name` 前两个词的首字母，圆底颜色取 `Style.background`，否则由名称稳定派生。默认 32 DIP 见方，不接收输入，作为以 `name` 命名的图像暴露。

### 时间与唤醒

每一遍都有一个时间，`View.time()` 读取，单位纳秒；默认来自 Host 第一次构建时启动的单调计时器，`Options.clock` 可以换成应用自己的时钟。构建函数可以调用 `wakeAt(deadline)` 要求在某一时刻再运行一遍，提示延迟和通知时长也用它。一遍中最早的请求生效，没有请求就不会再唤醒。

Host 本身不持有计时器，只在 paint 之后投递一个任务，把最早的期限交给 `Host.setScheduler` 设置的调度器。`ziggurat_view_timer` 提供基于 `ziggurat_wake.OneShot` 的调度器：

```zig
const view_timer = @import("ziggurat_view_timer");

var timer = view_timer.Timer.init(&host);
try host.attach(window);
try timer.attach(app, allocator);
// 关闭窗口或 App 之前：
try timer.close();
```

它为最早期限装定一次性计时器，期限变化时取消旧的，到期后让窗口失效重绘。没有期限时不装定，空闲窗口不做任何工作，也没有持续重绘的计时器。没有调度器时，提示和通知仍然正确，只是要等下一次因其他原因发生的重绘才会更新。

## 文本测量

`Frame.label` 使用默认的 16px 单行字体。文本节点可以用 `Style.font` 换成其他字体变体：`Font` 包含 `size`（1–1024 DIP）、`weight`（`regular`/`medium`/`semibold`/`bold`）、`italic` 与 `monospace`，并提供预设 `.body`、`.heading1`–`.heading6` 与 `.code`：

```zig
try v.text("概览", .{ .font = view.Font.heading2 });
try v.text("zig build test", .{ .font = view.Font.code });
```

字体随文本命令一起录制（命令仍为 32 字节），GDI、Direct3D 11 与 Cairo/Pango 渲染器都按它选择字形；GDI 和 Direct3D 11 各自缓存最近使用的 8 个变体，不在常规绘制路径中重复创建。

`Options.measurer` 决定文本节点与控件标签的宽度。默认的 `Measurer.estimate` 是保守估计（窄字符 9 DIP，宽字符 16 DIP，行高 24），不调用原生字体；需要精确宽度时，应用可以提供基于 `ziggurat_text_layout` 的测量回调；`measure_font(context, text, font)`（可选）在节点带字体时调用。没有它时按字号相对 16 缩放 `measure` 的结果，等宽字体按每字符 0.6 em、非常规字重加宽 5% 估算。测量回调在 paint 中调用，应自行缓存，避免在常规绘制路径分配。

## 存储与容量

`view.Storage(nodes, text_bytes)` 是调用者拥有的固定存储，提供节点、文本副本、布局项与矩形缓冲。`text`、控件标签都会复制进存储，`textf` 直接格式化进存储，因此构建函数可以传入临时缓冲。超出容量返回 `TooManyNodes`、`TextFull`、`TooManyItems` 或 `NestingTooDeep`，容器不配对返回 `UnbalancedContainer`；绘制中的这些错误使本帧失败并保留上一帧。底层 Frame 的每帧上限（128 个控件、2048 条命令等）同样适用。

### 树与表格

两者都把选择交给应用持有的 `Selection`：它记录选中项的应用 ID（非零 `u64`，在集合内唯一），而不是位置，所以改名、排序或插入行都不会改变选择。`Selection.init(.single 或 .multiple, &storage)` 以调用者的缓冲为容量，`add` 超出容量返回 `SelectionFull`；`items()`、`contains`、`set`、`add`、`remove`、`clear` 可在构建之外直接调用。`anchor` 是 Shift 范围的起点，`cursor` 是焦点行，`version` 在每次改动时递增。

- `tree(&selection, style)` 与 `end` 配对开始一棵树。`treeItem(id, expanded, label, style)` 打开一个以 `id` 为键的条目并加入它的行，返回 Enter 激活这一行的那一遍；子条目在它和对应的 `end` 之间构建，层级由嵌套决定。`expanded` 为 null 表示叶子；非 null 时行首画三角，按下三角只切换展开而不选择。应用只在 `expanded.*` 为 true 时构建子条目。
- `table(columns, &sort, &selection, style)` 与 `end` 配对开始一个表格，先画一行列头，`Column` 给出标题、`Track`（默认 `fraction(1)`）和是否可排序。激活可排序的列头时 `sort` 变为该列升序，再次激活翻转方向；返回 true 的那一遍由应用按 `sort` 排列行。不可排序的列头不取焦点。`Style.gap` 是列间距，为 0 时取 8 DIP。
- `tableRow(id, name, style)` 开始一行，`name` 是行的可访问名称（例如第一格），随后每列构建一个单元格，再 `end`。表头和所有行用同一组列宽：列宽在每次排列时由各列单元格（只计跨一列的）的最大内容尺寸统一求出，所以长文本不会让某一行错位。行放进 `scroll` 容器时表头保持不动。选中行以强调色填充，其中文本改用强调色上的前景色。
- 行共享一个 Tab 停靠点，落在 `cursor` 行。Up/Down 移动并单选，Home/End 到首尾，PageUp/PageDown 按可见行数翻页；Ctrl+方向键只移动 `cursor`，Space 单选、Ctrl+Space 切换、Shift+方向键或 Shift+Space 从 `anchor` 选到当前行，Ctrl+Shift 把范围加入已有选择，Ctrl+A 全选（多选时）。树里 Right 展开折叠的条目，已展开时进入第一个子条目；Left 折叠展开的条目，否则回到父条目。指针按下同理：Ctrl 切换、Shift 选范围、Ctrl+Shift 追加范围。移动后的行以最小位移滚入外层滚动容器。
- 行全部参与构建和排列，不做虚拟化；滚出可见区的行不绘制、也不登记命中（焦点行除外）。大量行请使用 `ziggurat_view_collections` 的[虚拟表格、大纲与网格视图](collections.md)，或 `ziggurat_ui` 的虚拟列表。`treeItem`、`tableRow` 在各自容器之外调用返回 `NotContainer`。

```zig
try v.tree(&selection, .{ .name = "文件" });
for (roots) |entry| {
    _ = try v.treeItem(entry.id, if (entry.branch) &open[entry.id] else null, entry.name, .{});
    if (entry.branch and open[entry.id]) try children(v, entry.id);
    try v.end();
}
try v.end();
```

启用 `-Daccessibility=true` 时，Windows UIA 把树映射为 Tree / Selection，条目为 TreeItem / SelectionItem / ExpandCollapse（叶子报告 LeafNode）；表格为 DataGrid / Selection，表头为 Header，列头为 HeaderItem / Invoke，排序方向放在 ItemStatus（"ascending" 或 "descending"），行为 DataItem / SelectionItem。多选集合报告 CanSelectMultiple，AddToSelection 与 RemoveFromSelection 只改动该项。

### 可编辑组合框与标记输入框

- `editableComboBox(value, style)` 与 `end` 配对，开始一个带边框的组合字段，其中放文本输入（通常是 `ziggurat_view_text` 的 `TextField`，用 `.frame = false` 去掉它自己的边框），`end` 时在末尾自动加入展开按钮。紧随其后的 `suggestions` 列表锚定在整个字段上。列表在输入获得焦点时不打开，在选项因输入变化时打开；Down、Alt+Down 或 F4 打开同一组选项，Alt+Up、F4 或 Escape 关闭；按钮切换打开状态而焦点留在输入里。选中后列表关闭，焦点回到输入。
- 输入法组合期间（`Embed.status` 报告 `composing`）列表隐藏，方向键、Enter 和 Escape 都留给输入法；组合结束后按选项是否变化恢复。
- `tokenField(style)` 与 `end` 配对，开始一个会换行的标记输入框，其中依次构建 `token(label, style)`（用 `Style.key` 保持身份）和最后的文本输入。`token` 在其移除按钮被按下、或标记有焦点时按 Backspace/Delete 的那一遍返回 true，应用在这个分支里删掉它；之后焦点回到输入。输入为空时 Backspace 或 Left 把焦点移到最后一个标记；标记之间用 Left/Right、Home/End 移动，越过最后一个回到输入。标记在可用宽度内按行排列，窗口变窄时自动换行。

`Embed.status(context)`（可选）报告嵌入输入是否正在组合、是否为空，供上面两种容器决定按键归属；`ziggurat_view_text` 的文本框已实现它。

启用 `-Daccessibility=true` 时，Windows UIA 把可编辑组合框映射为 ComboBox / ExpandCollapse，展开按钮为不取焦点的 Button；标记输入框为 List（LocalizedControlType 为 "token field"），标记为 ListItem（"token"），各带一个名为 "Remove" 的按钮。

## 嵌入与文本输入

`embed(content, style)` 加入一个自己测量、放置和绘制的叶子，用于视图层不建模的内容。`Embed` 提供：

- `measure(context, theme)`：返回最小与首选尺寸，在排列时调用。
- `place(context, id, bounds)`（可选）：每个成功的帧排列后调用一次，告知稳定的节点 ID 和窗口坐标边界。它在 paint 内运行，不能准备、分配或阻塞，需要的工作要推迟到输入阶段。
- `paint(context, frame, id, bounds)`：在绘制顺序中的位置录制内容。
- `annotate(context, annotation)`（可选）：每次 `paint` 前调用，传入外层表单字段的标签、说明、错误与必填状态；不在字段内时传空值。规则与 `place` 相同。
- `status(context)`（可选）：返回 `EmbedStatus`（是否正在输入法组合、内容是否为空），在构建和路由按键时读取，不能分配或阻塞。
- `focusable`（默认 false）：以节点 ID 登记为 Tab 停靠点，叶子自己绘制的控件仍在它上面。
- `input(context, id, EmbedInput)`（可选）：叶子上的指针与按键输入，坐标相对叶子边界。`pointer_move` 与 `pointer_leave` 跟随指针（窗口失去焦点也算离开），`pointer_down` 是主键按下（`PointerPress` 带位置、修饰键和连击次数：同一叶子上 500 ms 内、相距 4 DIP 内的按下依次计为 2、3……），`wheel` 是叶子上的滚轮（DIP，正 y 向下；不消费时交给外层滚动容器），`key` 是叶子持有焦点时其他控件都不处理的按键，`key_up` 是叶子持有焦点时松开的键（不论按下是否被它消费；窗口没有键盘时按下的键不会有松开）。返回 true 表示已消费并重绘窗口；消费按下的可聚焦叶子随即获得焦点。不消费的按键（例如 Tab）照常路由。它在主线程、绘制之外运行；被禁用、被裁剪遮住或位于打开的列表下面的叶子收不到输入，每帧最多 16 个叶子参与路由。
- `View.focusLeaf(id)` 在这一遍之后把键盘焦点交给可聚焦叶子 `id`（`place` 或 `paint` 得到的节点 ID），`View.hasKeyboard(id)` 表示该叶子持有焦点且窗口有键盘；游戏循环用它们在叶子出现时取得焦点、失去键盘时暂停。
- 消费 `pointer_down` 即捕获指针：直到松开，移动都以 `pointer_drag`（带起点、相对上一次的位移，以及是否已移出 `drag_threshold` 4 DIP）送到这个叶子，松开以 `pointer_up` 送达，指针离开叶子甚至窗口也一样。窗口失去焦点或原生捕获被取消时改为 `pointer_cancel`。下一次构建不再产生该叶子时捕获随之丢弃，之后不再调用它。

## 拖动与拖放

以下容器都按列排列，用 `end` 关闭；主键按下后移出 `drag_threshold`（4 DIP）才开始拖动，之前里面的按钮照常点击。拖动期间指针被捕获，移出窗口也继续跟随；松开结束，Escape、窗口失去焦点或捕获被取消则取消。滑块、分栏和接受按下的嵌入叶子保留自己的按下。

- `draggable(&gesture, style)` 是一个拖动区域。应用持有地址稳定的 `Gesture`；每个阶段（`start`、`move`、`end`、`cancel`）在自己的事件遍里更新它并返回该阶段，其他遍返回 null。`gesture.translation()` 是相对起点的位移，`delta` 是相对上一次事件的位移，`modifiers` 是按下时的修饰键。区域不再被构建时拖动丢失，之后第一次构建返回一次 `.cancel`。
- `dragSource(payload, style)` 在窗口内拖动一个 `Payload`（`kind` 像类型一样说明它是什么，`value` 说明是哪一个，例如条目 ID）。拖动时一份半透明副本跟随指针，返回 true 以便应用把原处画暗。
- `dropTarget(accept, style)` 接受 `Accept` 列出的内容：指定 `kind` 的 Payload，以及其他应用拖入的文件或文本。指针下最内层接受该内容的目标在拖动经过时描边并返回 `.over`，松开所在的那一遍返回 `.dropped`（`Dropped` 为 Payload、文件或文本，以及窗口坐标）。
- `reorder()` 在刚打开的表格、列表框或行/列容器上调用（要在加入任何条目之前），让指针把一项拖到其他项之间：副本跟随指针，一条线标出插入位置，松开所在的那一遍返回 `Move{from, to}`，表示原第 `from` 项移到原第 `to` 项之前（`to` 等于项数表示最后）；放回原处不产生移动，条目由应用重排。树不能重排；同一表格不能既 `reorder` 又 `dragSelect`。
- `dragSelect()` 在刚打开的树或表格上调用，让从一行开始的主键拖动像 Shift 加按下那样选中从该行到指针下一行的范围；按下时按住 Ctrl 则把范围加入已有选择。

拖动经过或越过外层滚动容器的边缘 32 DIP 内时，`reorder`、`dragSource` 与 `dragSelect` 随指针移动滚动它，越靠近边缘越快。每帧最多 32 个拖动区域/拖动源/放置目标、4 个可重排容器和 256 个可重排条目参与路由。

其他应用拖入的文件和文本经由 `ziggurat_system` 的放置目标转交：

```zig
fn hover(ptr: *anyopaque, _: z.Window, h: drop.Hover) bool {
    const host: *view.Host = @ptrCast(@alignCast(ptr));
    return host.systemDragOver(if (h.phase == .leave) null else .{ .x = h.point.x, .y = h.point.y }, h.files, h.text);
}
fn dropped(ptr: *anyopaque, _: z.Window, d: drop.Drop) void {
    const host: *view.Host = @ptrCast(@alignCast(ptr));
    const data: view.Dropped = switch (d.payload) {
        .files => |paths| .{ .files = paths },
        .text => |text| .{ .text = text },
        else => return,
    };
    _ = host.systemDrop(.{ .x = d.point.x, .y = d.point.y }, data);
}
```

`systemDragOver` 返回该点是否有目标接受所提供的内容；`systemDrop` 把数据在一遍内交给那里的目标，字节只在该遍中借用。窗口内拖动只在本窗口内进行，没有原生拖动源。

叶子的状态变化需要告诉辅助技术时，调用 `host.announce(text)`（或在构建中调用 `View.announce`）：文字作为一个没有可见内容的状态节点礼貌播报，每次调用都是新的状态，超过 256 字节时在字符边界截断。

`ziggurat_view_text` 用它提供可编辑文本字段。应用持有 `ziggurat_document_editor.Field` 及其 Document 和 Engine，并在 Host attach 后调用一次 `host.context.prepareTextFields(allocator, .{})`：

```zig
const text = @import("ziggurat_view_text");

var field = text.TextField.init(editor, &host, .{ .font = .{ .size = 16 } }, .{ .name = "名称" });
// 在构建函数中：
try v.embed(field.embed(), .{ .grow = 1, .key = 7 });
```

字段的边界变化时（第一次出现、窗口尺寸或布局改变），`place` 只记录新边界并向 App 投递一个任务；该任务在绘制之外调用 `Field.prepare`，第一次还会以节点 ID `attach` 到 Host 的 Context，然后使窗口失效。在准备完成之前，字段沿用上一次准备时的位置绘制，因此焦点和命中与文本保持一致，最多滞后一帧。键盘、输入法、剪贴板、焦点切换和 text_box 语义都由 Field 与 Context 处理，视图层不转发这些输入。

放在 `field` 里时，文本框把字段的帮助或错误作为说明，错误时标为无效，`Options.name` 为空时用字段标签作为名称。

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
- 树和表格的行：`click` 按下行的右端并单选，`clickWith(query, modifiers)` 带 Ctrl/Shift 按下，`toggleExpanded(query)` 按下树行的三角；`removeToken(query)` 按下标记的移除按钮。`click` 也接受列头、标记和组合框的展开按钮。`write` 的大纲带出行的层级、展开、选中与焦点行，以及列头的排序方向。

- `attachInput(&context)` 把之后每次渲染记录进一个未连接窗口的 `ui.Context`，`key(KeyInput)` 按窗口相同的顺序路由按键：快捷键、Tab、范围键、分组方向键、空间方向键、Home/End，最后是 Enter/Space 激活。产生的动作或数值变化交给构建函数，随后重新渲染；返回值表示是否有控件处理该键。`focused()` 返回当前焦点节点。`keyUp(KeyInput)` 把松开交给持有焦点的嵌入叶子，`windowFocus(bool)` 模拟窗口得到或失去键盘。Context 由测试持有，不能已连接窗口。

```zig
var context = ui.Context.init(&dummy, draw, action);
try h.attachInput(&context);
_ = try h.key(.{ .key = .tab });
_ = try h.key(.{ .key = .down });
try std.testing.expectEqualStrings("Sans", h.focused().?.text);
```

- 时间与浮层：`advance(ns)` 推进测试时钟并重新渲染，`deadline()` 返回上一遍请求的唤醒时刻；`hover(query)`、`hoverAt(x, y)` 与 `leave()` 移动或移走指针，`tooltip()` 返回当前显示的提示文字；`focus(query)` 直接给节点焦点。`key` 先把按键交给打开的列表或显示的提示，`clickAt` 先让按下经过列表与提示的处理，`at` 先查浮在上面的列表和通知。`write` 的大纲带出列表的打开/关闭、高亮项与提示文字。

- 指针：`press(x, y, modifiers)`、`moveTo(x, y)`、`release(x, y)` 与 `cancelPointer()` 按 Host 相同的捕获规则重放一次按下，`drag(from_x, from_y, to_x, to_y, steps)` 把它们连起来；`systemDragOver(point, files, text)` 与 `systemDrop(point, data)` 模拟其他应用的拖放。

带 `input` 的嵌入叶子在 Harness 中同样收到 `hoverAt`/`leave`、`clickAt`、上面的指针、`wheel` 与 `key` 的输入，`announcement()` 返回最近的播报文字。除此之外，Harness 把嵌入叶子当作不可交互的节点，不验证原生命中、文本输入、可访问性或原生捕获；这些仍由隐藏窗口 smoke 和原生检查覆盖。

## 背景效果

`Style.material` 是一个 `ui.BackdropEffect`，代替 `background` 画在容器的子节点之下：玻璃、对下方内容的模糊或滚动边缘，形状取 `Style.radius`。`Style.edges` 在裁剪容器（例如滚动容器）的顶部和/或底部画滚动边缘，带高 `height`（默认 24 DIP），在子节点之上、裁剪之内：

```zig
try v.row(.{ .padding = Insets.all(12), .radius = 16, .material = .{ .glass = .{ .tint = .{ .r = 40, .g = 110, .b = 200, .a = 60 } } } });
try v.text("在玻璃上", .{});
try v.end();
try v.scroll(&model, .{ .grow = 1, .edges = .{ .top = .{}, .bottom = .{ .hard = true } } });
```

效果需要 `host.prepareBackdropEffects(allocator, .{})`（在 `attach` 之后），否则画不透明填充。效果的像素模型、预算和后端行为见[背景效果与加载动画](backdrop-effects.md)。

## 加载动画

`loadingIndicator(kind, options, style)` 加入 29 种加载动画之一，作为以 `Style.name` 命名的不确定进度条暴露（Windows UIA 上是没有 RangeValue 的 ProgressBar）。`LoadingOptions` 有 `size`（高度，默认 20 DIP，宽度按宽高比）、`color`（默认主题文字色，禁用时为禁用文字色）、`duration`（0 为自身周期）、`paused`、`timer` 与 `variant`（`ui.loading.Options`）。没有 `timer` 时姿态取 `View.time()`，同一窗口的指示器同步转动；应用持有的 `LoadingTimer` 记录各自的起点，`paused` 时保持当前姿态，恢复后从该处继续。

动画中的指示器每一遍都请求 16.7 ms 后的唤醒，因此需要[调度器](#时间与唤醒)才会持续转动；暂停、减少动态效果或指示器不在树中时不请求，窗口回到完全空闲。

## 系统偏好

`host.setPreferences(.{ .reduce_motion, .reduce_transparency, .high_contrast })` 由应用按桌面偏好设置并重绘：减少动态效果让加载动画停在静止姿态，减少透明度或高对比度让背景效果变成不透明填充。

## 当前范围

已提供列、行、网格、纵向滚动容器、浮层与弹出字段、标签页、分栏、工具栏、分段控件、折叠区、手风琴、面包屑、列表框、树、表格、组合框、可编辑组合框、建议列表、标记输入框、搜索区域、表单字段与字段集、链接、徽标、度量条、评分、导航按钮、头像、提示、通知、文本、间隔、按钮、复选框、单选组、开关、确定进度、滑块、步进器、嵌入叶子（通过 `ziggurat_view_text`）可编辑文本字段，以及（通过 `ziggurat_view_pickers`）日历、日期/时间/数字输入与颜色选择器。分栏只接受比例偏好，没有 DIP 偏好、从右到左布局和折叠；工具栏没有溢出菜单。只读组合框不按输入筛选；建议列表与可编辑组合框的筛选由应用完成；表格没有列宽拖动、列重排、冻结列和行头，排序由应用完成；树与表格不做虚拟化，也没有行内编辑；树不能拖动重排，重排一次只移动一项，拖动边缘的自动滚动只随指针移动发生；悬停只用于提示，控件本身没有悬停外观；通知没有进出动画。没有虚拟列表和通用动画；玻璃没有按压放大动效。需要它们时可以直接使用 `ziggurat_ui` 的 Frame API。Linux 没有普通控件的 AT-SPI 层，上述可访问性只在 Windows UIA 上提供。

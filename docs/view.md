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
- **输入**：Context 每交付一个动作或数值变化，或滚轮落在滚动容器上，Host 立即运行一遍构建并携带该事件。拥有该 ID 的控件在这一遍中消费事件：`button` 返回 true，`checkbox`/`toggleSwitch` 翻转绑定的布尔值，`radio` 选中自己的选项，`slider`/`stepper` 对绑定的**当前值**应用 `ValueChange`，`scroll` 移动它的模型。这一遍不录制也不排列，`host.view` 里的节点边界要到下一次绘制才更新；Context 随后照常使窗口失效。

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

## 文本测量

`Frame.label` 使用固定的 16px 单行字体。`Options.measurer` 决定文本节点与控件标签的宽度。默认的 `Measurer.estimate` 是保守估计（窄字符 9 DIP，宽字符 16 DIP，行高 24），不调用原生字体；需要精确宽度时，应用可以提供基于 `ziggurat_text_layout` 的测量回调。测量回调在 paint 中调用，应自行缓存，避免在常规绘制路径分配。

## 存储与容量

`view.Storage(nodes, text_bytes)` 是调用者拥有的固定存储，提供节点、文本副本、布局项与矩形缓冲。`text`、控件标签都会复制进存储，`textf` 直接格式化进存储，因此构建函数可以传入临时缓冲。超出容量返回 `TooManyNodes`、`TextFull`、`TooManyItems` 或 `NestingTooDeep`，容器不配对返回 `UnbalancedContainer`；绘制中的这些错误使本帧失败并保留上一帧。底层 Frame 的每帧上限（128 个控件、2048 条命令等）同样适用。

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
- `click` 只接受按钮、复选框、开关和单选；`change` 只接受滑块和步进器，`ValueChange` 与原生输入相同；`scroll(query, delta)` 只接受滚动容器，`wheel(x, y, delta)` 像 Host 一样把滚轮交给该点最内层的可见滚动容器。目标禁用返回 `Disabled`，被自身尺寸或任一裁剪祖先完全遮住返回 `Hidden`，种类不符返回 `NotActivatable` 或 `NotAdjustable`。
- 事件遍若没有控件消费该事件（构建已不再产生这个节点），返回 `Stale`，不会静默忽略。成功的事件之后自动重新渲染，节点与 `frames` 反映新状态。
- `at(x, y)` 返回该点最后绘制的可交互节点，尊重裁剪；`clickAt` 激活它。`visible(node)` 给出裁剪后的可见矩形。
- `write(writer)` 输出缩进的树大纲（种类、文本、名称、选中或数值、禁用、取整后的边界），适合与期望文本比较。
- `Config` 提供窗口边界、主题和 `Options`（根样式与测量回调），`resize` 改变边界并重新渲染。

Harness 不经过 `ui.Context`，不验证原生命中、焦点、键盘导航或可访问性，也不推进时间；这些仍由隐藏窗口 smoke 和原生检查覆盖。

## 当前范围

已提供列、行、网格、纵向滚动容器、文本、间隔、按钮、复选框、单选组、开关、确定进度、滑块和步进器。没有悬停状态、文本输入、虚拟列表和动画；需要它们时可以直接使用 `ziggurat_ui` 的 Frame API。

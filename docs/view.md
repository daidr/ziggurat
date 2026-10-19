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
- **输入**：Context 每交付一个动作或数值变化，Host 立即运行一遍构建并携带该事件。拥有该 ID 的控件在这一遍中消费事件：`button` 返回 true，`checkbox`/`toggleSwitch` 翻转绑定的布尔值，`radio` 选中自己的选项，`slider` 对绑定的**当前值**应用 `ValueChange`。这一遍不录制任何内容，Context 随后照常使窗口失效。

因此连续输入在重绘前逐个作用于状态，不会被重绘合并吞掉。事件的 ID 若已不在树中（例如上一个事件移除了该控件），这一遍不改变任何值。构建函数应只依据状态描述视图，可以重复调用；副作用放在控件返回 true 的分支里。

## 身份

每个节点的 ID 由父节点 ID、它在兄弟中的序号和节点种类哈希得到，跨帧稳定，种类变化即换新 ID。兄弟顺序会变化的节点（列表项、条件出现的控件之后的节点）应提供 `Style.key`；`view.key(text)` 从字符串派生键。同一父节点下键必须唯一，重复会在录制时被 Context 拒绝。

## 布局

隐式根节点是填满窗口的列，样式来自 `Options.root`（默认内边距 24、间距 12、交叉轴起始对齐）。`column`/`row` 与 `end` 配对，最多嵌套 32 层；单个容器最多 256 个子节点。测量自底向上、排列自顶向下，均调用 `ui.layout.measure/arrange`，不分配内存。

`Style` 同时描述容器与它在父布局中的参与方式：

- 容器：`gap`、`padding`、`alignment`（子项交叉轴对齐）、`justify`、`clip`、`background`、`border`、`border_width`、`radius`。
- 参与：`grow`、`shrink`、`self_align`、`width`/`height`（固定尺寸）、`min_*`/`max_*`。
- 内容：文本的 `color`，控件的 `enabled`，进度条的可访问名称 `name`。

`spacer` 默认 `grow = 1`。叶子的固有尺寸来自文本宽度与主题 metrics：按钮在文本两侧留出内边距，复选框与开关加上指示器和标签间距，进度条与滑块有默认宽度且可以收缩到零。

## 文本测量

`Frame.label` 使用固定的 16px 单行字体。`Options.measurer` 决定文本节点与控件标签的宽度。默认的 `Measurer.estimate` 是保守估计（窄字符 9 DIP，宽字符 16 DIP，行高 24），不调用原生字体；需要精确宽度时，应用可以提供基于 `ziggurat_text_layout` 的测量回调。测量回调在 paint 中调用，应自行缓存，避免在常规绘制路径分配。

## 存储与容量

`view.Storage(nodes, text_bytes)` 是调用者拥有的固定存储，提供节点、文本副本、布局项与矩形缓冲。`text`、控件标签都会复制进存储，`textf` 直接格式化进存储，因此构建函数可以传入临时缓冲。超出容量返回 `TooManyNodes`、`TextFull`、`TooManyItems` 或 `NestingTooDeep`，容器不配对返回 `UnbalancedContainer`；绘制中的这些错误使本帧失败并保留上一帧。底层 Frame 的每帧上限（128 个控件、2048 条命令等）同样适用。

## 当前范围

已提供列、行、文本、间隔、按钮、复选框、单选组、开关、确定进度和滑块。没有悬停状态、滚动容器、文本输入、网格和动画；需要它们时可以直接使用 `ziggurat_ui` 的 Frame API。

# 图表

图表分两个模块：

- `ziggurat_chart`：纯 Zig，不依赖 App、窗口或 UI。提供尺度与刻度、绘图区布局、标记位置、折线/面积/扇形路径、堆叠、稠密折线降采样、图例布局和选择状态。所有结果写入调用者提供的存储，不分配。
- `ziggurat_chart_view`：把图表作为[声明式视图](view.md)的嵌入叶子画出来，只使用 `ziggurat_view` 的公开 `View.embed`。

图表没有自己的外观：颜色、尺寸都由调用者给出，未给的文字与网格颜色取当前主题。

## 位置约定

绘图区内的位置是 0 到 1 的比例：横向从左边起，纵向从**底边**向上，与数值增长方向一致。尺度把数据换成比例，`chart.x(r, f)` / `chart.y(r, f)` 再把比例换成绘图区矩形 `r` 中的 DIP 坐标。

## 尺度

- `chart.Linear.init(lo, hi)` 映射数值。`nice(n)` 把定义域向外取整到约 n 个刻度的整值（0..87、10 个刻度得 0..90；5 个刻度得 0..100）；`ticks(n, &out)` 写出间隔为 10 的幂乘 1、2 或 5 的刻度，标签的小数位数由步长决定，或由 `format` 自定义。`at`、`span`、`invert` 做正反映射，`clamp` 把定义域外的值压到两端。`chart.extent(values)` 求忽略 NaN 的最小最大值，没有数据时为 0..1。
- `chart.Band.init(labels)` 给每个分类一条带：`band(i)`、`at(i)`、`width()`、`index(f)`（带之间的空隙归属相邻的带），`padding(inner, outer)` 以步长比例留出间隔，`ticks(&out)` 把标签放在各带中央。
- `chart.Time.init(from, to)` 映射以毫秒计的 Unix 时间。`offset` 是所在地相对 UTC 的固定分钟偏移，刻度落在该偏移下的整时刻上：秒、刻钟、午夜、周日、月初或年初，按跨度选择；默认标签只写相对上一级整单位变化的部分，如 `2026`、`Mar`、`Mar 5`、`14:00`、`09:14`、`:30`、`.250`。`chart.fromCivil` / `chart.toCivil` 在公历时间与毫秒之间换算。

刻度是 `chart.Tick`：`at` 比例、`value` 数值和最长 32 字节的内联标签（超长时在 UTF-8 边界截断），所以刻度数组可以放在应用状态里反复写，不需要分配。输出数组太短时返回 `error.TooManyTicks`。

## 绘图区与标记

`chart.layout(bounds, axes, gap, measure)` 按每条有刻度的坐标轴最宽（或最高）标签留出空间，`gap` 把标签与绘图区隔开，其余是绘图区；`Layout.label(side, tick, size, gap)` 给出以刻度为中心的标签矩形，绘图区外的刻度返回 null。

标记位置都相对绘图区：

- `chart.rect(area, x_span, y_span)`：柱、区间带、热图格。
- `chart.point(area, x, y, w, h)`：以点为中心的 w×h 盒子，如散点。
- `chart.ruleX(area, x, width)` / `chart.ruleY(area, y, height)`：贯穿绘图区的竖线或横线，如阈值、均值、选中点。
- `chart.anchor(area, x, y, h, v, size)`：把任意大小的盒子锚在点上；`.center, .end` 放在点的正上方。

## 折线、面积与扇形

`chart.line(&path, r, xs, ys, curve)` 与 `chart.area(&path, r, xs, lo, hi, curve)` 把路径写进 `chart.Path`（调用者提供命令存储，存储不足返回 `error.PathFull`）。NaN 把折线或面积断开；`lo` 为 null 时底边是绘图区底部。曲线有 `.linear`、`.monotone`（不越过相邻两点取值的平滑曲线）以及 `.step_after`、`.step_before`、`.step`。`chart.curve` 单独返回分段，便于自定义绘制。

`chart.pie(values, pad, &out)` 从十二点方向顺时针按占比分圆，负值和 NaN 不占位置；`chart.sector(&path, center, inner, outer, slice)` 写出饼或环的一片，`pad` 沿片保持等宽缝隙；`chart.polar` 给出角度上的点，`chart.sliceAt` 找出某点下的片。`chart.nearest(xs, f)` 找出升序比例中离指针最近的点。

## 堆叠

`chart.stack(series, how, out)` 中 `series[s][i]` 是第 s 个系列的第 i 个值，`out[s][i]` 得到它在第 i 个堆中的 `Segment`：

- `.standard`：正值自 0 向上堆，负值自 0 向下堆。
- `.normalized`：同上，但按各值绝对值之和归一，正值堆从 0 到 1。
- `.center`：围绕 0 居中，如河流图。

NaN 与短系列缺失的值不占位置。

## 实时数据

数千个样本的折线每帧重画时，`chart.minMax(dst_x, dst_y, xs, ys, pixel_width)` 保留每个物理像素列的最低与最高样本（保持原顺序）以及每段的端点，窄峰不会丢失；NaN 或 Inf 断线，绘图区左右之外的点只各保留最近的一个。`xs` 必须不减。结果写入调用者的缓冲，预热后不分配；原始样本仍应保留给选择与读数使用。

## 图例与选择

`chart.legend(bounds, items, options, measure, &out)` 把色块与名称排成在 `bounds.width` 内换行的行，返回占用的尺寸。

`chart.Selection` 是指针与键盘共同驱动的选择状态：`pointer(f, xs)` 在指针进入或移动时选最近的点，离开（传 null）时清除；指针停住不动时不覆盖键盘的选择。`key(k, count)` 处理左右方向键、Home、End 与 Escape，从无选择按右键选第一个，按左键选最后一个。返回的 `Change.announce` 表示键盘把选择移到了新点，应当把该点的描述交给辅助技术。

## 在视图中绘制

```zig
const chart = @import("ziggurat_chart");
const chart_view = @import("ziggurat_chart_view");

const Sales = struct {
    figure: *chart_view.Chart,
    sales: [6]f64,
    xs: [6]f32 = undefined,
    ys: [6]f32 = undefined,
    left: [16]chart.Tick = undefined,
    bottom: [6]chart.Tick = undefined,

    fn build(self: *Sales, v: *view.View) anyerror!void {
        const x = chart.Band.init(&months).padding(0.3, 0.15);
        const y = chart.Linear.init(0, chart.extent(&self.sales).hi).nice(4);
        self.figure.begin(.{ .left = try y.ticks(4, &self.left), .bottom = try x.ticks(&self.bottom) });
        for (self.sales, 0..) |value, i| {
            try self.figure.add(.{ .bar = .{ .x = x.band(i), .y = y.span(0, value), .color = ui.Color.rgb(0x2a7fd4), .radius = 3 } });
            self.xs[i] = x.at(i);
            self.ys[i] = y.at(value);
        }
        try self.figure.add(.{ .line = .{ .xs = &self.xs, .ys = &self.ys, .color = ui.Color.rgb(0xd47f2a), .curve = .monotone } });
        try self.figure.setLegend(&.{ .{ .label = "销售额", .color = 0x2a7fd4 }, .{ .label = "趋势", .color = 0xd47f2a } });
        try v.embed(self.figure.embed(), .{ .grow = 1, .self_align = .stretch });
    }
};

var storage: chart_view.Storage(32, 8, 4) = .{};
var figure = chart_view.Chart.init(&host, allocator, storage.buffers(), .{ .name = "每月销售额" });
defer figure.deinit(); // 在 Context detach 之前、paint 之外
```

每次构建先 `begin(axes)`，再按绘制顺序 `add` 标记：`bar`、`point`、`rule_x`、`rule_y`、`label` 直接用 Frame 的圆角矩形与文字绘制；`line`、`area`、`sector` 画成覆盖蒙版。`setLegend` 设置图例（`options.legend` 为 `.top`、`.bottom` 或 `.none`），`value` 是图表作为图像节点读出的值，例如选中点的描述。刻度、数据切片与图例条目都是借用的，必须在下一次构建前保持有效且不变。

蒙版按绘图区尺寸、缩放、标记类型、曲线、线宽和数据内容的键准备，颜色不在键内。paint 只比较键：键变化时在 paint 之后投递一个任务准备新蒙版、上传并释放旧蒙版，然后请求重绘；键不变时 paint 直接回放已上传的蒙版，不分配、不投递。准备完成前，为其他尺寸或缩放准备的蒙版不会被画出。准备失败或得到空路径时记录在 `last_error`，同一个键不会反复重试。需要在构建后立即可用的场合可以在 paint 之外调用 `prepareAll()`。

`Chart` 被投递的任务引用，从首次嵌入到 `deinit` 期间必须保持地址稳定。`deinit` 释放全部蒙版，必须在 Context detach 之前、paint 之外调用。

`smoke-chart` 在隐藏窗口里验证首帧投递、蒙版准备与复用、数据变化后的重新准备与释放。

## 悬停与键盘选择

构建时调用 `figure.select(xs, describe)`，传入升序的比例位置（借用，下一次构建前保持有效），图表就成为一个 Tab 停靠点：指针在绘图区上移动时选最近的点，移出绘图区或离开图表时清除；在绘图区按下取得焦点；获焦时左右方向键、Home、End 移动选择，Escape 清除（没有选择时 Escape 不被消费）。`describe` 把点写成文字，作为图表图像节点的值，键盘移到新点时通过 `Host.announce` 播报。选择保存在 `figure.selection` 中、跨构建保留，构建函数读 `selection.index` 用标记画出来：

```zig
figure.select(&self.xs, .{ .call = describeMonth });
if (figure.selection.index) |i| {
    try figure.add(.{ .rule_x = .{ .x = self.xs[i], .color = ui.Color.rgb(0x888888) } });
    try figure.add(.{ .point = .{ .x = self.xs[i], .y = self.ys[i], .color = accent, .size = 8 } });
}
```

获焦时绘图区外画一圈主题焦点色描边。没有调用 `select` 的图表不参与输入，也不是 Tab 停靠点。

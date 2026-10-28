# 富文本

`ziggurat_view_rich_text` 把一组样式各异的 `Span` 排成一段可折行的文字，作为声明式视图的自测量叶子（`view.Embed`）。它是新的独立模块，不改变视图层的节点种类。

```zig
const rich = @import("ziggurat_view_rich_text");

var label = rich.RichText.init(allocator, .{ .measurer = host_measurer, .width = 320 });
defer label.deinit();
try label.setSpans(&.{
    .{ .text = "Saved " },
    .{ .text = "report.pdf", .weight = .semibold },
    .{ .text = " to " },
    .{ .text = "Documents", .color = theme.palette.accent, .underline = true },
});
// 在构建函数中
try v.embed(label.embed(), .{});
```

## Span

`Span` 留空的字段取周围文字的样式（`Options.font` 与 `Options.color`，颜色为 null 时取主题正文色）：

- 字体：`size`、`weight`、`italic`、`monospace`。
- `color`：文字颜色。
- 线条：`underline`、`wavy_underline`（拼写错误式的波浪线）、`strikethrough`；`decoration_color` 与 `decoration_thickness` 设定线条颜色与粗细，默认取文字颜色和随字号增长的粗细。
- `background`：高亮底色，默认填满所在行高；`radius` 大于 0 时改为贴合字形、略宽于文字的圆角底，用于行内代码。
- `baseline_shift`：把这个 span 的文字抬高若干 DIP（负数为降低），配合较小的 `size` 做上标与下标：脚注编号、指数、化学式。行会为它留出高度，它的线条和圆角底随文字一起移动。
- `object`：把这个 span 当作一个不可拆开的内联对象（如公式或图标），宽、高和基线以下的深度取自 `Object`，文字只用于辅助判断，不绘制。对象和文字一起折行，行会为它留出高度；绘制交给 `options.objects` 的 `ObjectPainter`，它拿到对象所在的矩形，未设置时对象留空。

```zig
try label.setSpans(&.{
    .{ .text = "H" },
    .{ .text = "2", .size = 10, .baseline_shift = -3 },
    .{ .text = "O 在 100 °C 沸腾" },
    .{ .text = "1", .size = 10, .baseline_shift = 6 },
});
```

`text` 被借用，在下一次 `setSpans` 或 `deinit` 之前必须保持有效。

## 折行与测量

`setSpans` 在主线程、绘制之外运行：它用 `Options.measurer` 测量每个词（一个词及其后的空格，或单个中日韩字符），并为全部 run 与行预留存储。跨 span 相接、中间没有空格的文字视为同一个词，一起换行。`\n` 强制换行，连续换行产生空行。`setWidth(width)` 按新宽度重新折行，不分配也不测量文字，宿主可以在宽度变化时直接调用；`width` 为 0 时只在换行符处断行。超过宽度的单个词不拆分，越出部分被叶子边界裁剪。

同一行内不同字号的 run 对齐同一基线，行高取最高的 run。基线按标签字体在其边界内垂直居中的规则估算。叶子的最小与首选尺寸都是当前折行结果；`spanAt(point)` 返回某个局部坐标下的 span 序号。

## 段落排版

按书籍排版一段文字时，`Options` 还有：

- `line_height`：行高为 `font.size` 的倍数，多出的空间上下各半，例如中日韩正文常用 1.8。为 0 或小于文字所需高度时取行自身的高度。
- `justify`：两端对齐。按 `width` 折出的每一行都拉伸到 `width`，但每段的最后一行（换行符之前或文字末尾）不拉伸；拉伸量平均分给词间空格以及汉字、假名和中日文标点之后的空隙。没有可拉伸处的行（例如跨 span 粘连的长词）保持原样。
- `indent`：首行缩进若干 DIP，首行按缩进后的宽度折行；换行符之后的行不缩进。

软连字符 U+00AD 是一个可断行的位置：行在这里断开时显示连字符 `-`，其他位置不显示也不占宽度，与浏览器一致。行在软连字符处断开时会为连字符留出宽度，放不下就提前在上一个可断处断行。框架不会自行按语言断字。

`textLines()` 返回当前折行结果的各行（从上到下）：`y`、`height`、`baseline`、文字在基线上下的 `ascent` 与 `descent`、左边缘 `x`（首行为缩进）、`width`，以及该行在各 span 文字依次相接后的字节范围 `start`/`end`（含行尾空格，不含结尾换行符）。分页时找出页底以下的第一行，它的 `start` 就是下一页开始的位置：

```zig
for (label.textLines()) |line| {
    if (top + line.y + line.height > page_bottom) {
        next_page_starts = line.start;
        break;
    }
}
```

## 绘制

每个 run 以其 span 的字体作为单行标签绘制，因此 run 内部由系统文本引擎 shape，跨 run 不连写。绘制顺序为全部背景、各 run 文字、线条；线条只覆盖 run 的可见宽度，不含行尾空格。波浪线由每段两倍线宽的短矩形组成三角波，每 100 DIP 约 50 个绘制命令（线宽 1 时），窗口的绘制命令缓冲有上限，长篇波浪线应节制使用。绘制只读取缓存的 run 和行，不分配。

测量器应与视图宿主一致；估算测量器与实际字体宽度不同时，标签边界留有一个字号的余量以避免省略号，但线条和背景仍按测量宽度绘制。

富文本叶子目前不向辅助技术提供文字，也不处理指针或键盘输入；需要可访问文字或可激活链接时使用视图的 `text` 与 `link` 节点。

## 检查

`zig build test-view-rich-text`：跨 span 的词、换行与中日韩断行、混合字号基线、背景/波浪线/删除线/下划线的绘制次序与几何、测量与主题颜色，以及行高倍数、两端对齐、首行缩进、软连字符、上下标与各行的范围。

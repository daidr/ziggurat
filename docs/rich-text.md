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

`text` 被借用，在下一次 `setSpans` 或 `deinit` 之前必须保持有效。

## 折行与测量

`setSpans` 在主线程、绘制之外运行：它用 `Options.measurer` 测量每个词（一个词及其后的空格，或单个中日韩字符），并为全部 run 与行预留存储。跨 span 相接、中间没有空格的文字视为同一个词，一起换行。`\n` 强制换行，连续换行产生空行。`setWidth(width)` 按新宽度重新折行，不分配也不测量文字，宿主可以在宽度变化时直接调用；`width` 为 0 时只在换行符处断行。超过宽度的单个词不拆分，越出部分被叶子边界裁剪。

同一行内不同字号的 run 对齐同一基线，行高取最高的 run。基线按标签字体在其边界内垂直居中的规则估算。叶子的最小与首选尺寸都是当前折行结果；`spanAt(point)` 返回某个局部坐标下的 span 序号。

## 绘制

每个 run 以其 span 的字体作为单行标签绘制，因此 run 内部由系统文本引擎 shape，跨 run 不连写。绘制顺序为全部背景、各 run 文字、线条；线条只覆盖 run 的可见宽度，不含行尾空格。波浪线由每段两倍线宽的短矩形组成三角波，每 100 DIP 约 50 个绘制命令（线宽 1 时），窗口的绘制命令缓冲有上限，长篇波浪线应节制使用。绘制只读取缓存的 run 和行，不分配。

测量器应与视图宿主一致；估算测量器与实际字体宽度不同时，标签边界留有一个字号的余量以避免省略号，但线条和背景仍按测量宽度绘制。

富文本叶子目前不向辅助技术提供文字，也不处理指针或键盘输入；需要可访问文字或可激活链接时使用视图的 `text` 与 `link` 节点。

## 检查

`zig build test-view-rich-text`：跨 span 的词、换行与中日韩断行、混合字号基线、背景/波浪线/删除线/下划线的绘制次序与几何、测量与主题颜色。

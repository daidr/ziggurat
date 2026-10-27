# 富文本编辑器

富文本由三个可选模块组成：

- `ziggurat_rich_text`：属性文本模型 `Text`（段落 + 带属性的 run）、可撤销的 `Document`，以及 HTML、RTF、Markdown 与编辑器自有 JSON 剪贴板格式的编解码。纯 Zig，只依赖 Markdown 解析器。
- `ziggurat_rich_text_editor`：声明式视图中的编辑器叶子 `Editor`，在 `Document` 之上排版、绘制并接收键盘、指针与输入法。
- `ziggurat_rich_text_clipboard`：把编辑器接到 `ziggurat_system` 的系统剪贴板。

另有 `ziggurat_text_measure`：用平台文本排版（Linux Pango、Windows DirectWrite）测量文字宽度的 `view.Measurer`，按文字与字体缓存。视图和编辑器默认使用估算宽度；传入它以后，换行位置与绘制一致。

```zig
const rt = @import("ziggurat_rich_text");
const rich = @import("ziggurat_rich_text_editor");
const clipboard = @import("ziggurat_rich_text_clipboard");
const measure = @import("ziggurat_text_measure");

const native = try measure.Native.create(allocator, std.Thread.getCurrentId());
defer native.destroy();
var host = view.Host.init(&state, State.build, storage.buffers(), .{ .measurer = native.measurer() });

var doc = rt.Document.init(allocator, try rt.parseMarkdown(allocator, "# 标题\n\n正文"));
defer doc.deinit();
var board: system.clipboard.Board = undefined;
try board.init(app, .{});
defer board.deinit();
var system_clipboard = clipboard.SystemClipboard.init(allocator, &board);
defer system_clipboard.deinit();
var editor = rich.Editor.init(&host, allocator, &doc, .{ .measurer = native.measurer(), .clipboard = system_clipboard.clipboard() });
defer editor.deinit();

// 在 build 回调里：
try editor.emit(v, .{ .grow = 1, .self_align = .stretch, .key = 2 });

// 窗口关闭后、Context 分离前：
system_clipboard.cancel();
editor.detach();
```

完整示例见 [rich_text.zig](../examples/rich_text.zig)（`zig build run-rich-text`）。

## 文本模型

- `Text` 是段落序列。每段有 `ParagraphStyle`（标题级别 0–6、列表类型 bullet/number/task、任务是否完成、缩进、对齐、引用、代码块）和一串 `Run`，每个 run 带 `Attributes`（字体族、字号、字重、斜体、下划线、删除线、前景与背景色、行内代码、链接、标签、附件）。位置以 Unicode 标量计，段落之间的换行算一个位置。
- 附件（图片、绘图等）占一个对象替换字符 U+FFFC，带名称、URL 与尺寸；编辑器为它留出盒子，由 `Options.attachment_painter` 绘制，没有时画一个带名称的框。
- `Document` 持有文本、选择与输入属性。所有修改经 `Edit` 记录为可逆步骤，相邻的打字合并为一个撤销步骤；撤销栈上限为 `max_undo`。格式命令（加粗、链接、列表、缩进、对齐等）作用于选择，选择为空时改变输入属性。

## 编解码

| 格式 | 读 | 写 |
| --- | --- | --- |
| HTML | `parseHtml`：常见块与行内元素、`style` 中的颜色/字重/斜体/装饰、列表与任务、链接、图片；脚本与样式被丢弃 | `toHtml` |
| RTF | `parseRtf`：字体表、颜色表、`\b` `\i` `\ul` `\strike`、段落对齐与缩进、Unicode 转义、Windows 代码页 | — |
| Markdown | `parseMarkdown`：标题、列表、任务、引用、代码块、强调、行内代码、链接、图片 | `toMarkdown`，必要时转义 |
| 自有 JSON | `clip.parse`，同一进程复制的内容带着附件原样粘贴 | `clip.json`，也可用于保存文档 |

## 编辑器

- 排版按段落进行，只排版视口附近的段落；其余段落的高度用已测段落的平均值估算，并存在 Fenwick 树中，滚动定位与命中测试都是 O(log n)。绘制不排版：尺寸变化后的排版在绘制后投递的任务和输入处理中完成。
- Markdown 快捷方式：段首输入 `# `…`###### `、`- `、`* `、`1. `、`[ ] `、`[x] `、`> `，以及在空段落里输入 ```` ``` ```` 后回车，会转换成对应的段落样式；在单词两侧输入 `**粗体**`、`*斜体*`、`` `代码` ``、`~~删除线~~` 会转换成对应属性。`Options.no_markdown` 关闭它们。
- 快捷键（Windows 与 Linux）：Ctrl+B/I/U 加粗/斜体/下划线，Ctrl+Shift+X 删除线，Ctrl+Shift+E 行内代码，Ctrl+K 链接（`Options.on_link_command` 可接管为弹出输入框），Ctrl+Shift+7/8/L 编号/项目符号/任务列表，Ctrl+]/[ 缩进/减少缩进，Ctrl+L/E/R 左/中/右对齐，Ctrl+Alt+0–6 正文与标题，Ctrl+Z/Ctrl+Y（或 Ctrl+Shift+Z）撤销/重做，Ctrl+Shift+V 粘贴并匹配样式。Ctrl+方向键按词移动，Home/End、PageUp/PageDown、双击选词、三击选段。
- 列表里回车延续列表，空列表项回车退出列表；段首退格先去掉段落样式。点击任务框切换完成状态，点击链接交给 `Options.on_link`，否则只把 http、https 与 mailto 链接交给 `Options.open_url`（见 `safeToOpen`）。
- 输入法：编辑器注册为 Context 的文本字段，预编辑文字在光标处显示并带下划线，候选窗口跟随光标。快照中的偏移是 UTF-16 码元，`units`/`runeOfUnits` 负责换算。
- 无障碍：叶子是 `.text_box`，值为有界的纯文本。
- `Editor.runCommand` 供工具栏与菜单调用；`takeChanged` 报告用户是否改过文本，`Options.on_change` 在每次用户编辑后调用。

## 剪贴板

`SystemClipboard` 复制时同步写入自有格式（`application/x-ziggurat-rich-text`）、HTML 与纯文本。粘贴时依次异步读取自有格式、HTML、RTF（Windows 为注册格式 “Rich Text Format”，GTK 为 `text/rtf`）、Markdown（`text/markdown`）与纯文本，全部读完后交给 `Editor.paste`，由编辑器取能解析的最丰富格式；粘贴并匹配样式时只读纯文本。数据超出缓冲时按需要的大小重读一次，超过 `limit`（默认 16 MiB）的格式视为没有。正在读取时再次粘贴会取代前一次。应用也可以实现自己的 `Clipboard` 接口，例如在测试中直接调用 `Editor.paste`。

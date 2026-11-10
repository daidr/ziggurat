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

### 段落 ID

`ParagraphStyle.id` 是应用给段落起的名字，用作应用为它保存的内容（批注、时间线等）的键。编辑器不显示它，它跟着段落的文字走：

- 拆分段落时 ID 留在前半段；在段首回车把段落整体下移时 ID 跟到后半段。另一半没有 ID。
- 合并两个段落时保留前一段的 ID，除非前一段已经为空。
- 粘贴或插入的段落没有 ID：`Text.replace` 从不采用插入文字里的 ID，所以不会有两个段落同名。

撤销和重做会连同文字带回 ID，自有 JSON（`toJson` 不带副本名时）保存 ID；剪贴板、HTML、Markdown 和 RTF 都不带 ID。ID 可以在构造文本时给出（`Text.of`、`clip.parse`），也可以让文档为编辑新产生的段落命名，命名发生在产生它们的那一步撤销里：

```zig
const Ids = struct {
    next: u64 = 0,
    fn name(context: ?*anyopaque, buffer: *[rt.Namer.max]u8) []const u8 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.next += 1;
        return std.fmt.bufPrint(buffer, "p{d}", .{self.next}) catch "";
    }
};
try doc.identifyParagraphs(.{ .context = &ids, .name = Ids.name });
```

`identifyParagraphs` 会立即为当前没有 ID 的段落命名，之后 `setText` 和每次替换产生的段落也会被命名；在编辑之前调用它，之前的撤销步骤保留原来的文本。传 null 停止命名。格式状态（`Document.formatting`）比较段落样式时忽略 ID。

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
- 快捷键（Windows 与 Linux）：Ctrl+B/I/U 加粗/斜体/下划线，Ctrl+Shift+X 删除线，Ctrl+Shift+E 行内代码，Ctrl+K 链接（`Options.on_link_command` 可接管为弹出输入框），Ctrl+Shift+7/8/L 编号/项目符号/任务列表，Ctrl+]/[ 缩进/减少缩进，Ctrl+L/E/R 左/中/右对齐，Ctrl+Alt+0–6 正文与标题，Ctrl+Z/Ctrl+Y（或 Ctrl+Shift+Z）撤销/重做，Ctrl+Shift+V 粘贴并匹配样式。Ctrl+方向键按词移动、双击选词时，每个汉字、平假名与片假名各自成词，拉丁字母、数字与韩文按连续的一串成词。Home/End、PageUp/PageDown、双击选词、三击选段。
- 列表里回车延续列表，空列表项回车退出列表；段首退格先去掉段落样式。点击任务框切换完成状态，点击链接（带链接的附件在整个框上都可点击，悬停时显示链接指针）交给 `Options.on_link`，否则只把 http、https 与 mailto 链接交给 `Options.open_url`（见 `safeToOpen`）。只有在同一个链接上按下又松开、期间指针移动不到 4 DIP 时才算点击，按下后拖动选择文字不会打开链接。
- 输入法：编辑器注册为 Context 的文本字段，预编辑文字在光标处显示并带下划线，候选窗口跟随光标。快照中的偏移是 UTF-16 码元，`units`/`runeOfUnits` 负责换算。
- 无障碍：叶子是 `.text_box`，值为有界的纯文本。
- `Editor.runCommand` 供工具栏与菜单调用；`takeChanged` 报告用户是否改过文本，`Options.on_change` 在每次用户编辑后调用。
- 右键菜单：`Options.menu`（`MenuBuilder{ context, build }`）给编辑器一个上下文菜单，右键或菜单键打开，`build(context, v, editor)` 往菜单里加项；没有它编辑器没有菜单。`Editor.editItems(v)` 加入剪切、复制、粘贴与全选，按当前选区与只读状态启用，选中后在编辑器上执行；`editEntries()` 只给出这些项，供应用自己摆放。右键按下时，若不在选区内，光标先移到按下处（与文本框一致），编辑器取得焦点，菜单关闭后焦点回到编辑器，菜单项因此作用在右键处。视图层的叶子用 `Embed.secondary_press` 得到这次按下。
- `Options.on_key`（`KeyFilter`）在编辑器处理每个按键之前被询问，返回 true 即拿走该键，编辑器不再处理，例如文字上方的补全列表接管方向键、回车和 Escape。
- `Options.span_styler`（`SpanStyler`）拿到一个段落将要绘制的 spans，追加想要的 spans：拆分、着色或换字体，文字必须相同且顺序不变（文字不同时忽略），例如按语言给代码块着色。它的行为变化时改 `Options.spans_version`，段落会重新排版。
- `Options.space`（`Spacer{ context, above }`）在段落上方留出主题之外的空间：`above(context, index)` 拿到段落序号（从 0 起），返回要在它上方额外留出的 DIP，负数按 0。拖动一段文字到别处时，应用在它要去的位置让出一块空间，下面的段落随之下移，就像列表为拖动的项让位。它在排版段落时询问，视野内的段落每帧都问，所以返回值可以逐帧变化，段落与 `visibleParagraphs` 给出的方框随之移动。
- `Options.no_scrollbar` 不画编辑器自己的滚动条，原来滚动条位置的按压交给文字：应用让编辑器和文字一样高、与周围的页面（标题、属性与正文）一起滚动时，只显示页面的滚动条，即使某一帧给编辑器的高度不够（例如分栏变窄、文字换行变多）、编辑器自己稍微滚动，也不会出现第二条。编辑器仍会滚动以保持光标可见，也仍响应滚轮。
- `Editor.caretRect()` 给出本帧光标的位置（相对编辑器叶子左上角、已计入滚动，单位 DIP）以及是否在可见范围内，供应用把弹出框放在光标旁。读取时排版可见部分；之后的绘制发现光标位置与读到的不同时会再请求一帧，所以弹出框跟随输入、滚动和宽度变化。编辑器尚未排版时返回 null 并请求一帧。

## 段落间隔与首行缩进

正文段落（不是标题、列表项或代码）默认紧挨在一起，适合笔记。排版散文时可以用 `Theme` 的两种方式把段落分开：

- `first_line_indent`：正文段落首行缩进若干 em（印刷小说常用约 1.2）。标题、列表、代码块、空段落或非左对齐段落（例如居中的场景分隔 “* * *”）之后的第一段不缩进，引用的第一段也不缩进；只有左对齐（`.start`）的段落缩进。
- `paragraph_spacing`：两个正文段落之间留出若干 em 的空隙，适合屏幕阅读。标题保留自己的上下间距。

缩进不是字符：光标、选择、点击和方向键都会跳过它，与文字处理软件一致。

## 屏幕上的段落

`Editor.visibleParagraphs()` 返回视口中的段落（含部分可见的）：段落序号、起始字符位置，以及它各行的顶部与高度（DIP，相对编辑器叶子的顶部、已计入滚动）。段落上下的空隙（标题外边距、段落间隔）不计入，所以在 `top` 处画的标记与首行对齐。在构建视图时读取它，把侧栏放在编辑器旁、与编辑器同一顶部，在侧栏顶部加上各段的 `top` 处绘制，例如时间线、页边批注或段落编号。编辑器滚动、宽度变化或为显示光标而移动时，绘制会发现段落位置与读取时不同并请求下一帧，侧栏随之更新，应用不必监听滚动。它只返回已排版的可见段落，长文档与短文档的开销相同；编辑器第一次排版之前返回空。

一个文档可以同时显示在两个编辑器里（例如同一页显示在两个窗格）。`visibleParagraphs` 与 `caretRect` 在各自的 `Editor` 上读取、读到的结果也存在那个编辑器里，所以每个编辑器给出自己宽度下的段落，绘制时只与自己被读到的结果比较，两个编辑器不会互相触发帧。

编辑器和文字一样高、放在滚动容器里时（整页一起滚动），每个段落都在编辑器的框内：编辑器每帧只绘制画面裁剪区（`Frame.visibleRect()`）里的段落，各段的起始字符位置在段落列表里随前一段累加记录，裁剪区外的段落不绘制。

## 剪贴板

`SystemClipboard` 复制时同步写入自有格式（`application/x-ziggurat-rich-text`）、HTML 与纯文本。粘贴时依次异步读取自有格式、HTML、RTF（Windows 为注册格式 “Rich Text Format”，GTK 为 `text/rtf`）、Markdown（`text/markdown`）与纯文本，全部读完后交给 `Editor.paste`，由编辑器取能解析的最丰富格式；粘贴并匹配样式时只读纯文本。数据超出缓冲时按需要的大小重读一次，超过 `limit`（默认 16 MiB）的格式视为没有。正在读取时再次粘贴会取代前一次。应用也可以实现自己的 `Clipboard` 接口，例如在测试中直接调用 `Editor.paste`。

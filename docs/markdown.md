# Markdown

`ziggurat_markdown` 把 Markdown 解析成有界节点树：CommonMark 的块与行内结构，加上 GitHub 风格的表格、任务列表、删除线和扩展自动链接。它是纯 Zig，只读取传入的源文本；节点与文本放在调用者提供的固定缓冲里，解析不分配、不按输入嵌套递归。`ziggurat_markdown_view` 把树映射为声明式视图节点，`ziggurat_markdown_code` 用系统文本引擎以等宽字体绘制代码块。

```zig
const md = @import("ziggurat_markdown");
const mv = @import("ziggurat_markdown_view");

var parsed: md.Storage(2048, 64 * 1024) = .{};
const tree = try md.parse(source, parsed.buffers());

fn build(self: *Reader, v: *view.View) anyerror!void {
    if (try mv.build(v, self.tree, .{ .width = self.width, .theme = self.theme }, .{})) |activation| switch (activation) {
        .link => |url| self.open(url),
        .task => |task| self.toggle(task.node, task.checked),
    };
}
```

## 解析

`parse(source, buffers)` 要求有效 UTF-8，否则返回 `InvalidText`；换行可以是 LF、CR 或 CRLF，NUL 替换为 U+FFFD。返回的 `Tree` 借用缓冲，在缓冲复用前有效，不借用源文本：段落、标题和表格单元格的内容会复制进文本缓冲，再在其上做行内解析。节点用尽返回 `TooManyNodes`，文本缓冲用尽返回 `TextFull`，链接引用定义超过 128 条返回 `TooManyDefinitions`。

树的根是 `document`。块节点有 `paragraph`、`heading`（`level` 1 到 6）、`thematic_break`、`block_quote`、`list`（`ordered`、`start`、`marker`、`tight`）、`list_item`（`task`）、`code_block`（`text` 含末尾换行，`fenced`，`url` 是信息串首词，`title` 是完整信息串）、`table`、`table_row`（`header`）和 `table_cell`（`alignment`）。行内节点有 `text`、`soft_break`、`hard_break`、`emphasis`、`strong`、`strikethrough`、`code`、`link` 与 `image`（`url`、`title`，`autolink` 标记裸地址）。块节点的 `line` 是起始源码行（从 0 计）。

`Tree.children` 遍历直接子节点，`Tree.walk` 以进入/退出事件做深度优先遍历，叶子只有进入事件；两者都不递归。`plainText` 把子树的文本拼进调用者缓冲，不截断 UTF-8 序列。`html.write` 按 CommonMark 与 GitHub 的常规形式输出 HTML，文本与属性都会转义，目的地按需百分号编码。

### 支持范围

- 块：ATX 与 Setext 标题、主题分隔线、缩进与围栏代码块、块引用（含惰性续行）、有序/无序列表（紧凑与松散）、链接引用定义、段落。Tab 按 4 列制表位展开。
- 行内：反斜杠转义、实体与数字字符引用、代码段、强调与加粗（含分隔符规则与「三的倍数」规则）、行内链接与图片、完整/折叠/快捷引用链接、尖括号自动链接、硬换行与软换行。
- GitHub 扩展：表格（对齐、`\|` 转义、缺少的单元格补空、多余的丢弃，最多 64 列）、任务列表项 `[ ]`/`[x]`、`~` 与 `~~` 删除线、`www.`/`http://`/`https://` 与电子邮件扩展自动链接。

有意的取舍：原始 HTML（HTML 块与行内标签）按字面文本保留，不会作为标记执行，因此不可信文档不能借此注入内容；命名字符引用只识别常用的约 80 个名称，其余保持字面；链接标签匹配只折叠 ASCII 大小写。对照 CommonMark 0.31.2 规范样例（除 HTML 块与原始 HTML 两节），除上述取舍和 GitHub 扩展自动链接造成的差异外全部一致。

### 边界

块容器（块引用、列表、列表项）最多嵌套 32 层，更深的标记作为文本保留而不是报错。行内解析每个块最多跟踪 256 个分隔符和 64 个方括号，超出的部分保持字面文本，因此病态输入的工作量随输入线性增长。

## 视图

`mv.build(v, tree, options, style)` 在应用的构建函数中把整棵树加为一个列（`style.gap` 为 0 时取 `options.gap`），返回本遍交付的激活：

- `.link`：被激活的链接目的地，借用自树。链接用 `View.link` 绘制，键盘、焦点与激活规则和普通链接相同；折行后链接在每一行上都可以激活。
- `.task`：被切换的任务复选框和新的状态。`options.interactive_tasks` 为 false（默认）时复选框禁用、只显示状态。`taskOffset(source, node.line)` 找到该行任务标记的方框字符，`toggleTask` 把新状态写回源文本，应用随后重新解析。

段落按 `options.width` 贪心折行：在空格处断开，中日韩文字可以在任意两个字之间断开，单个超宽的词按字符拆开。测量使用 `options.measurer`，应与视图宿主的 Measurer 一致。每行是一个 `row`，同一样式的连续文字是一个节点；超过 128 个子节点的块、行和列表会嵌套到子列中，保持在视图容器的子节点上限以内。

映射：标题与段落是文字行；块引用是左侧竖条加内容列；列表是标记列（`•`、`◦`、`▪` 按层级，或 `1.`/`1)` 编号）加内容列，紧凑列表的间距取 `tight_gap`；分隔线是 1 DIP 高的条；表格每行是等宽列的 `grid`，表头行带底色，单元格按列对齐；行内代码放在带底色的小行容器里；图片显示替代文字。

颜色默认取自 `options.theme` 的调色板，可以用 `options.colors` 逐项替换。视图文本节点目前只有颜色可变，字号、粗体与斜体由文本节点的固定字体决定，所以标题、强调、加粗和删除线暂以颜色区分；视图层提供字体变体后再改用对应字体。

## 等宽代码块

`options.code` 接受一个 `CodeFace`：它为代码块返回自测量、自绘制的 `Embed`，返回 null 时代码块按普通文字逐行显示。`ziggurat_markdown_code.CodeBlocks(capacity)` 是基于 `ziggurat_text_layout` 的实现：

```zig
var blocks: code.CodeBlocks(16) = .{};
try blocks.prepare(engine, allocator, tree, window_scale, .{});
options.code = blocks.face();
```

`prepare` 在主线程、绘制之外为树中前 `capacity` 个代码块（最多 32 个，即一帧可绘制的预排版文本数）创建布局并按窗口缩放光栅化，默认字体在 Windows 上为 Consolas，在 Linux 上为 fontconfig 的 monospace。嵌入只按内容哈希匹配同一位置的代码块，重新解析后未重新准备的代码块回落为普通文字。绘制时缩放与准备时不同，则先用标签字体逐行绘制，直到应用为新缩放重新调用 `prepare`。仍有帧在使用旧的预排版文本时，`prepare` 与 `release` 返回 `Busy`，旧内容继续可用。

## 检查

- `zig build test-markdown`：块、行内、表格、任务列表、扩展自动链接、HTML 输出与上限。
- `zig build test-markdown-view`：视图映射、折行、链接/任务激活、代码块嵌入与长文档嵌套。
- `zig build smoke-markdown-code`（Windows/Linux）：默认字体等宽、预排版尺寸进入视图嵌入、过期树不匹配、释放全部原生资源。

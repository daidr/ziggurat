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

中日韩文本放宽了一条规则：中文常在强调两侧不留空格，例如 `**结论。**后文`。严格 CommonMark 中结束符夹在标点与汉字之间时不能闭合，星号会按字面显示。紧挨中日韩字符、全角标点或弯引号时，`*` 与 `~~` 不再因相邻标点而不能开闭；`_` 和单个 `~` 仍按 CommonMark 规则（`snake_case` 不变，`第1章~“附录”` 这类范围不会变成删除线）。规范样例里没有这种位置出现中日韩文本，所以仍全部通过。

有意的取舍：原始 HTML（HTML 块与行内标签）按字面文本保留，不会作为标记执行，因此不可信文档不能借此注入内容；命名字符引用只识别常用的约 80 个名称，其余保持字面；链接标签匹配只折叠 ASCII 大小写。对照 CommonMark 0.31.2 规范样例（除 HTML 块与原始 HTML 两节），除上述取舍和 GitHub 扩展自动链接造成的差异外全部一致。

### 数学公式

`md.parseWith(source, &buffers, .{ .math = true })` 额外识别公式，`md.parse` 不识别。`\(…\)` 是行内公式，`\[…\]` 和 `$$…$$` 是独立公式；`dollar_math`（默认开启）时 `$…$` 也是行内公式。开头的 `$` 后紧跟空白或数字、结束的 `$` 前是空白或后面紧跟数字时不构成公式，所以 `$5 和 $10` 保持为文字。公式是 `.math` 节点，`text` 为 TeX 源码，`level` 为 1 时是独立公式；HTML 输出为带 `math math-inline` 或 `math math-display` 类的 `span`，内容保留定界符，交给页面上的公式渲染器。



### GitHub 提示块、提及与引用

`ParseOptions` 的 `alerts`、`mentions`、`references` 分别读取 GitHub 评论里的三种写法，`ParseOptions.github` 同时打开三者，默认都关闭：

- 提示块：顶层块引用的第一行单独是 `[!NOTE]`、`[!TIP]`、`[!IMPORTANT]`、`[!WARNING]` 或 `[!CAUTION]`（不区分大小写，两侧可有空格或 Tab；之前可以有空的引用行）时，这个块引用的 `alert` 是对应种类，标记行不属于它的内容，正文从下一行开始。标记独占一段且后面还有块时也是提示块；整个引用只有标记、标记后还有文字（`> [!NOTE] 正文`）、未知种类、嵌套在列表或其他引用里，或标记前已有文字时，仍是普通块引用。`Alert.title()` 给出 GitHub 显示的标题。HTML 输出与 GitHub 相同的 `markdown-alert` div，不含图标。
- 提及：`@octocat` 与 `@github/docs` 是 `.mention` 节点，`Tree.login` 返回 `octocat` 或 `github/docs`。登录名是字母、数字与连字符（以字母或数字开头，最多 39 个），前面不能紧挨单词字符，后面不能紧跟单词或“点加单词”（所以 `me@example.com`、`@octocat.dev` 不是提及）。
- 引用：`#123`、`GH-123`（不区分大小写）与 `octocat/hello#123` 是 `.reference` 节点，`Tree.reference` 返回仓库（本仓库为空）与编号。编号 1 到 10 位、不以 0 开头，后面不能紧跟单词。

提及与引用只在代码、链接和图片之外的文本里识别，与 GitHub 一样：强调结束后紧挨的位置算作单词开头（`_a_#1`、`**b**@octocat` 会识别），实体或转义写出的 `&#64;octocat` 也会识别。原始 HTML 按字面保留，但与 GitHub 一样，原始 HTML 的 `a`、`code`、`pre`、`style`、`script` 元素里不识别（`<code>@x</code>` 的 `@x` 仍是文字；自闭合的 `<pre/>` 不算打开）。它们在 HTML 与 `plainText` 中按原文输出：是否存在、链接到哪里由视图决定。

块容器（块引用、列表、列表项）最多嵌套 32 层，更深的标记作为文本保留而不是报错。行内解析每个块最多跟踪 256 个分隔符和 64 个方括号，超出的部分保持字面文本，因此病态输入的工作量随输入线性增长。

## 视图

`mv.build(v, tree, options, style)` 在应用的构建函数中把整棵树加为一个列（`style.gap` 为 0 时取 `options.gap`），返回本遍交付的激活：

- `.link`：被激活的链接目的地，借用自树。链接用 `View.link` 绘制，键盘、焦点与激活规则和普通链接相同；折行后链接在每一行上都可以激活。
- 链接右键菜单：`options.link_menu`（`LinkMenu{ context, build }`）给每个外部链接（不以 `#` 开头）加一个右键弹出菜单，`build(context, v, url)` 在菜单里加菜单项，例如“复制链接”“在浏览器中打开”。
- `.task`：被切换的任务复选框和新的状态。`options.interactive_tasks` 为 false（默认）时复选框禁用、只显示状态。`taskOffset(source, node.line)` 找到该行任务标记的方框字符，`toggleTask` 把新状态写回源文本，应用随后重新解析。

段落按 `options.width` 贪心折行：在空格处断开，中日韩文字可以在任意两个字之间断开，单个超宽的词按字符拆开。测量使用 `options.measurer`，应与视图宿主的 Measurer 一致。每行是一个 `row`，同一样式的连续文字是一个节点；超过 128 个子节点的块、行和列表会嵌套到子列中，保持在视图容器的子节点上限以内。

映射：标题与段落是文字行；块引用是左侧竖条加内容列；列表是标记列（`•`、`◦`、`▪` 按层级，或 `1.`/`1)` 编号）加内容列，紧凑列表的间距取 `tight_gap`；分隔线是 1 DIP 高的条；表格每行是等宽列的 `grid`，表头行带底色，单元格按列对齐；行内代码放在带底色的小行容器里；图片显示替代文字。

不使用富文本嵌入（`options.rich`）时，字体通过 `Style.font` 表达：标题按级别使用 `.heading1` 到 `.heading6`，表头为半粗体，正文用标签字体；强调是斜体，加粗是粗体（已是粗体的标题保持不变），两者可以叠加；行内代码与回退显示的代码块行使用等宽字体，行内代码的字号按 `.code` 与正文的比例随所在块缩放。折行按各段文字的实际字体测量，所以标题会比正文更早换行。链接沿用所在块的字体（标题里的链接是标题字号，加粗里的链接是粗体），`options.link_weight` 给链接文字设最低字重（默认 `.regular` 不设下限），已经更粗的保持不变，使链接在灰度主题或色觉障碍读者面前不只靠颜色区分；链接里的行内代码保留等宽字体与底色，字重随链接一起提升。删除线没有对应的字体变体，以 `strikethrough` 颜色区分。颜色默认取自 `options.theme` 的调色板，可以用 `options.colors` 逐项替换；强调与加粗默认使用正文颜色。

### 提示块与提及链接

提示块显示为左侧竖条、图标和标题都取该种类颜色的块引用，正文保持正文颜色。颜色默认是 GitHub 的配色（按 `options.theme` 背景的明暗取浅色或深色版本），可用 `options.colors.alerts` 按 note、tip、important、warning、caution 的顺序替换；图标是 `view.Icon` 的 `info`、`light_bulb`、`report`、`warning` 与 `stop`。

`options.resolve`（`Resolve{ context, destination }`）把提及与引用变成链接：`destination(context, tree, index)` 返回目的地（例如应用内的路径），激活时作为 `.link` 交付，与普通链接相同；返回 null 时保持文字，如同 GitHub 对不认识的人或 issue 的处理。没有 `resolve` 时它们都是文字。提及链接以粗体显示。每次构建都会对显示的每个提及与引用调用一次，应查询手头已有的数据（例如一张表），查询结果变化时下一遍自然跟随。含有已解析链接的块不交给 `options.rich`，而用视图文字与链接构建。

### 流式回复

语言模型的回复是一点点到达的。`mv.show(v, &state, source, streaming, reveal)` 返回本遍要显示的 `source` 前缀：文字不按网络送达的节奏成块出现，而是匀速地一个单位一个单位显示，追上 `Reveal.catch_up_ns`（默认 250 ms）内到达的部分，积压越多越快，每秒至少几百字节；每个单位淡入（`Reveal.fade_ns`，默认 300 ms，负数不淡入，系统要求减少动态效果时也不淡入）。应用把前缀解析成树，再用 `options.reveal = &state` 构建：段落文字按显示的时刻分段淡入，代码块、分隔线和整体交给 `options.rich` 绘制的段落按块淡入。`RevealState` 由应用为每份流式文档保留。

`Reveal.unit`：`.word`（默认，一个词及其后的空格；中日文每个汉字和假名各算一个词）、`.character`、`.sentence`（句号、问号、感叹号后接空格，或中文句末标点、换行；流式中只显示完整的句子）、`.line`、`.paragraph`（空行之间的块）和 `.at_once`（不控制节奏）。

回复完成后在同一处、用同一个状态把 `streaming` 改为 false，还没显示完的部分继续进来；其他交给已完成文档的文字立即显示，修改文本也一样。`state.revealed()` 在构建之后读取，表示全部文字都已显示且淡入结束：聊天在回复完成并 `revealed()` 后才显示时间和操作按钮，而不是在最后几个字节到达、文字还在进来的时候。立即显示的文字（`.at_once`、没有流留下待显示内容的已完成文档、修改）在到达的那一遍就是 revealed；没有淡入时在最后一个单位显示出来时 revealed；更多文字到来又变回 false。对流式文档它只说明到目前为止到达的文字都显示了，是否还会有更多由调用方判断；按句、行、段显示时被扣住的不完整部分会让它保持 false，直到流结束。视图在显示和淡入期间自己请求下一帧，因此每遍读取它的调用方会看到它自动变成 true。

```zig
const shown = mv.show(v, &self.reveal, reply.text, !reply.done, .{});
const tree = try md.parse(shown, self.parsed.buffers());
_ = try mv.build(v, tree, .{ .reveal = &self.reveal }, .{});
if (reply.done and self.reveal.revealed()) try v.text(reply.time, .{});
```

### 锚点

`options.anchor` 给出标题的 slug（可带或不带 `#`），视图在文档首次显示、被另一份文档替换（新文本不是旧文本的延续）以及锚点改变时，把该标题以最小滚动量滚入视野，例如打开 `guide.md#install` 或回到读者上次的位置；`options.anchor_version` 改变时再滚一次，用于连续两次请求同一标题。需要同时传入应用持有的 `options.anchor_state: *AnchorState`，它记录上次应用的锚点、版本与文本，不传时忽略锚点。标题的 slug 与 GitHub 一致（`slug(text, buffer)`）：小写，空格变连字符，去掉 ASCII 标点，其他文字保留；`headingNamed(tree, name)` 查找第一个匹配的标题。正文里的 `#heading` 链接照常作为 `.link` 激活交给应用，应用自行把它设为锚点：

```zig
if (try mv.build(v, tree, .{ .anchor = self.anchor, .anchor_version = self.version, .anchor_state = &self.anchor_state }, .{})) |activation| switch (activation) {
    .link => |url| if (std.mem.startsWith(u8, url, "#")) {
        self.anchor = url;
        self.version += 1;
    } else self.open(url),
    .task => {},
};
```

视图要放在滚动容器里锚点才有作用；滚动通过 `View.scrollIntoView(id)` 完成，它在本遍排列后把节点以最小滚动量显露出来。

## 等宽代码块

`options.code` 接受一个 `CodeFace`：它为代码块返回自测量、自绘制的 `Embed`，返回 null 时代码块按普通文字逐行显示。`ziggurat_markdown_code.CodeBlocks(capacity)` 是基于 `ziggurat_text_layout` 的实现：

```zig
var blocks: code.CodeBlocks(16) = .{};
try blocks.prepare(engine, allocator, tree, window_scale, .{});
options.code = blocks.face();
```

`prepare` 在主线程、绘制之外为树中前 `capacity` 个代码块（最多 32 个，即一帧可绘制的预排版文本数）创建布局并按窗口缩放光栅化，默认字体在 Windows 上为 Consolas，在 Linux 上为 fontconfig 的 monospace。嵌入只按内容哈希匹配同一位置的代码块，重新解析后未重新准备的代码块回落为普通文字。绘制时缩放与准备时不同，则先用标签字体逐行绘制，直到应用为新缩放重新调用 `prepare`。仍有帧在使用旧的预排版文本时，`prepare` 与 `release` 返回 `Busy`，旧内容继续可用。

## 富文本段落

`options.rich` 接受一个 `RichFace`：它为段落、标题和表格单元格返回富文本嵌入，返回 null 时按上文映射为文字节点。`ziggurat_markdown_rich.RichBlocks` 是基于[富文本](rich-text.md)的实现：

```zig
var blocks = mr.RichBlocks.init(allocator);
defer blocks.deinit();
try blocks.prepare(tree, .{ .measurer = measurer, .theme = theme });
options.rich = blocks.face();
```

`prepare` 在主线程、构建与绘制之外运行，为树中不含链接和图片的段落、标题与表格单元格生成 span：强调为斜体，加粗为粗体，删除线带横线，行内代码用等宽字体（正文字号的 7/8）放在圆角底色上，标题按级别取 `heading_sizes` 字号与 `heading_weight` 字重。含链接或图片的块仍按上文映射，链接保持键盘可达。构建时嵌入只按节点序号和内容哈希匹配，并按该块的宽度不分配地重新折行，颜色取该块的正文颜色（块引用中为引用颜色）；重新解析后未重新准备的块回落为文字节点。span 借用树的文本，树在其缓冲复用前必须保持有效。富文本嵌入不向辅助技术提供文字，见富文本一节的限制。

`options.inline_math` 接受一个 `InlineMath`：它测量并绘制行内公式，公式成为富文本中的对象 span（宽、高与基线以下的深度由 `measure` 给出），和周围文字一起折行并落在同一基线上；`measure` 返回 null 或未设置 `inline_math` 时，公式以等宽字体和 `math` 颜色显示 TeX 源码。

## 检查

- `zig build test-markdown`：块、行内、表格、任务列表、扩展自动链接、HTML 输出与上限。
- `zig build test-markdown-view`：视图映射、折行、链接/任务激活、代码块嵌入与长文档嵌套。
- `zig build test-markdown-rich`：行内样式到 span 的转换、含链接的块保持链接节点、嵌入按宽度折行与过期树回落。
- `zig build smoke-markdown-code`（Windows/Linux）：默认字体等宽、预排版尺寸进入视图嵌入、过期树不匹配、释放全部原生资源。

# 语法高亮、多光标与变更标记

`ziggurat_code_syntax` 是纯 Zig 模块，不依赖窗口、文本引擎或 Document：按行切分 token、增量维护行状态、匹配括号、查找整词。`ziggurat_code_editor` 在其上把结果接入同一个 Document 与 `document_editor.Adapter`：可见行变成前景区间标记，多光标与括号命令只改选区，变更标记比较 Document 与基准文本。

## 词法器与语言

`Tokenizer{context, call}` 对一行（不含换行）给出 `Token{end, kind}` 序列和下一行的起始状态。状态是不透明的 `u64`，同一状态和同一行总得到同一结果，因此行状态可以缓存并在编辑后从首个变化处继续。超过 `max_line`（10000 字节）的行整体按普通文字处理，不推进状态。`TokenKind` 覆盖关键字、类型、函数、变量、属性、常量、数字、字符串、转义、正则、注释、运算符、标点、标签、属性名、元信息、Markdown 标题/强调/加粗/链接/代码、diff 增删和非法字符。

`Lexer` 是可配置的通用词法器：行注释、可嵌套或不嵌套的块注释、多种字符串（含原始串、多行串和插值）、按大小写或不区分大小写的关键字表、首字母大写即类型、调用即函数、`key:` 即属性、装饰器、预处理指令、正则字面量和 `$变量`。JSON、TOML、CSS、HTML/XML（含内嵌 script/style）、Markdown（围栏代码按语言名委托）与 diff 有专用词法器。

`languages` 内置 28 种语言：Go、JavaScript、TypeScript、JSON、Python、Rust、C、C++、Java、Kotlin、Swift、C#、Shell、YAML、TOML、SQL、Ruby、Lua、PHP、CSS、HTML、XML、Markdown、diff、Dockerfile、Makefile、Protobuf 和 Zig。`Language` 还带注释记号、括号对（可声明在哪些 token 中不算括号）、自动闭合对、单词字符和缩进习惯。`forFile(name)` 按扩展名或完整文件名查找，`named(name)` 接受常见别名。

`Theme.light()` 与 `Theme.dark()` 是两套默认配色，`Theme.default(dark, background, text, accent)` 按应用的底色、文字色与强调色派生一套；`color(kind)` 与 `style(kind)` 给出每类 token 的颜色与粗细/斜体，`added`/`modified`/`deleted` 供变更标记使用。

## 增量高亮

`Highlighter` 记录每行起始状态和已确认的前沿。`edit(start, old_end, new_end)` 告知行替换；不知道编辑的宿主可以只调用 `sync(source)`，它按行哈希找出未变的前缀和按行数差对齐的后缀。`highlight(source, last, budget)` 从前沿向 `last` 推进至多 `budget` 行，返回是否已覆盖；`tokens(index, text, buffer)` 用该行起始状态重新切分。某行结束状态与旧值相同时，其后各行状态不再重算。

`code_editor.Highlighting` 把它接到 Document 上：`update(adapter, first, count, extra)` 同步文本版本，推进到可见行，把这些行中颜色不同于正文颜色的 token 合并为 `foreground` 区间标记，再与宿主自己的标记（例如查找结果的下划线）按起点合并后交给 `setRangeMarkers`。返回的 `ready=false` 表示本次预算没有覆盖可见行，宿主应 post 一次后续任务；`current=false` 表示有更新的编辑或输入法组合，等下一次变化。主题的粗细与斜体目前不绘制：编辑器每段只用一种字体 shape。标记数不超过 `Options.max_markers`，应与编辑器 `Limits.range_markers` 一致。

## 多光标与括号

`MultiCursor`（`multicursor.Commands`）的命令都只通过 `Adapter.setSelections` 改选区，由编辑器合并重叠：

- `selectNext(adapter, previous)`：光标在单词内时先选中该词，之后逐个加入下一处（或上一处）整词匹配，到达末尾后回绕；`selectAllMatches` 一次选中全部。
- `addCaret(adapter, .above/.below)`：在上一行或下一行同一显示列（按制表位）加入光标；反方向再执行时按加入次序撤回。
- `selectLarger`/`selectSmaller`：按单词、字符串内部、字符串、括号内部、括号、整行、全文逐级扩大，缩小时按记录退回。
- `splitIntoLines`：把每个跨行选区拆成每行一个。
- `toBracket(adapter, extend)`：跳到配对括号，或选中到它；`bracketsAround` 返回包围光标的括号对。括号匹配跳过字符串和注释中的括号。
- `single`：只保留主选区；`undoSelection(adapter, redo)`：撤销或重做选区变化，不影响文本 undo。

选区被其他输入改变后，这些命令的连续状态从头开始。

## 变更标记

`GitGutter.setBase(text)` 把基准文本（例如上次打开或保存的内容）复制为只读 Document；`update(document)` 在已提交文本版本改变时用 `ziggurat_document_diff` 重新比较。`status(line)` 给出 `added`、`modified`、`deleted_above`（其上方有被删除的行）或 `unchanged`，`goToHunk(adapter, .next/.previous)` 循环跳到下一处变化，`revertHunks(adapter)` 把选区所在行涉及的变化恢复为基准内容，作为一次可撤销编辑。`paint` 只读取编辑器已准备的位置几何，在行号栏右侧画竖条或删除楔形。比较超出 diff 的上限时返回错误，直到下一次成功之前没有标记。

## 检查

- `zig build test-code-syntax`：各语言词法、多行状态、增量同步、括号匹配与整词查找。
- `zig build test-code-editor`：前景标记随编辑移动、整词与全部匹配、上下加光标与选区撤销、语法逐级扩选、按行拆分、括号跳转、变更标记与恢复。
- `zig build smoke-editor-range-markers`：前景标记在真实系统布局下按颜色裁剪绘制。

示例 `examples/code_editor.zig` 使用以上全部功能。该证据不表示与任何特定编辑器的高亮结果逐字一致。

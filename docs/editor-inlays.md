# 行内提示与建议

DocumentEditor 可以在行内显示不属于 Document 的文字：语言服务推断的类型（inlay
hint）、行尾的诊断或 blame（trailing），以及光标后由模型给出的补全建议
（suggestion）。这些文字按 committed 源字节插入要 shape 的文本，用
`Colors.inlay`（默认 `0x8a8f98`）淡色绘制；caret、选区、命中、可访问性和原生文本
客户端只看到 Document 自己的字节。

## 提示与行尾文字

`setInlays(expected_text_version, definitions)` 替换整组 `Inlay{offset, text, kind}`。
`offset` 是 committed UTF-8 字节，必须是有效边界，不超出文档；集合按 offset
非递减（否则 `InvalidOrder`）。`text` 是一行非空 UTF-8，不含 CR/LF，至多
`max_inlay_text`（1024）字节（否则 `InvalidInlay`）。项数受 `Limits.inlays`
（默认 4096）约束，超出返回 `InlayCapacityExceeded`。空集合清空。

`kind` 决定 caret 怎样对待它：

- `hint`（默认）放在所在字节之前：该字节的 caret 显示在提示之后，以该字节结束的
  选区不覆盖提示，左右方向键一步跨过整段提示。
- `trailing` 显示方式同 hint，但 caret 停在它之前，选到行尾也不覆盖它，用于行尾的
  诊断和 blame。

同一字节上 hint 在前、trailing/建议在后，caret 正好在两者之间。点在提示文字上的
任何位置都落在它所在的源字节。

行内文字跟着编辑移动：它们按 Document 的 [改动日志](./document.md#改动日志与位置映射)
（`mapOffset(…, .right)`）映射到当前文本，所以不论改动来自编辑器、输入法、
undo/redo 还是宿主直接修改 Document 都会跟随。在行内文字所在字节输入的文字放在
它之前（提示跟到新文字后面），被替换掉的范围里的行内文字移到替换文字的末尾。
`setInlays` 的 `expected_text_version` 可以是较早的版本（例如迟到的语言服务结果），
集合会先映射到当前文本。日志不再覆盖其版本（被淘汰或 restore 之后）时集合过期，
`status().inlays_required` 提示宿主重新设置；这时 `setInlays` 对该旧版本返回
`StaleRevision`。只改选区保留集合。composition 期间与密码遮罩时不显示任何行内
文字。这与 [区间标记](./editor-range-markers.md) 不同：区间标记在正文改变时一律
过期，需要按新版本重新计算（参考框架同样如此）。
返回 `InlayResult{version,current}`，`current=false` 表示发布后编辑器又变了。

## 建议

`setSuggestion(expected_revision, offset, text)` 在 `offset` 显示一段建议：第一行，
有多行时再加 " …"（超长按字符截到 1024 字节）。`expected_revision` 是
`Document.version()`，包含正文与选区；任何编辑或 caret 移动都会让建议消失。
空文本清除。`suggestion()` 返回仍然有效的完整文本或 null。

只有一个空选区且 caret 正在 `offset` 时，Tab（或 `acceptSuggestion()`）插入完整
建议文本，作为一次普通编辑进入 undo。CodeEditor 中补全列表打开时 Tab 先接受补全，
snippet 会话先跳到下一个占位符，然后才轮到建议，最后才是插入制表符。

## 实现要点

每个 shape 批次在创建时把落在本批源字节范围内的行内文字插入 shape 文本，并保存
源字节、字素边界、行和 advance span 的源坐标副本；除绘制外的所有查询都经过这层
映射。行内文字自己的 caret 停靠点都映射到所在源字节。集合或建议变化会换新布局
generation，重新 shape 可见批次；没有行内文字时与原来完全一致，不多分配。
淡色绘制复用前景区间标记的文字裁剪区。

`smoke-editor-range-markers` 检查真实系统布局下提示后与行尾前的 caret 位置、
选到行尾不覆盖 trailing、在提示文字上的命中、方向键跨过提示、淡色绘制、Tab 接受
建议、编辑、undo 与宿主直接修改时跟随移动、按旧版本设置时映射、restore 后过期，以及 caret 移动时建议消失。

# 虚拟集合

`ziggurat_view_collections` 在[声明式视图](view.md)里提供三种虚拟集合：列可调整、移动和排序的表格（`table`），一棵行组成的树（`outline`，也可以放进表格的列里，`outlineTable`），以及按网格排列的项目（`gridView`）。它们只绘制可见的行，只在一行出现时向应用要它的内容，所以百万行与十行的成本相同。整个模块不分配，只用 `ziggurat_view` 的公开接口：每个集合是一个可聚焦的嵌入叶子，自己绘制行并处理指针、滚轮与按键，再以语义子节点向辅助技术暴露可见行。

应用持有状态（`TableState`、`OutlineState`、`GridState`），地址必须稳定：构建它的每一遍、以及窗口还向它投递输入期间都要有效。行由应用给出的键识别，选择和滚动位置因此跟随项目，排序、插入或删除行都不会让它们错位。同一集合的所有行一样高。

```zig
const collections = @import("ziggurat_view_collections");

const Files = struct {
    files: []const File,
    table: collections.TableState = .{},
    chosen: collections.Selection,          // .init(.multiple, &storage)
    sort: ?collections.SortOrder = null,

    fn key(ctx: ?*const anyopaque, row: usize) u64 { ... }   // 非零且唯一
    fn cell(ctx: ?*const anyopaque, row: usize, column: usize, scratch: []u8) collections.Cell { ... }

    fn build(self: *Files, v: *view.View) anyerror!void {
        const columns = [_]collections.Column{
            .{ .title = "名称" },
            .{ .title = "大小", .width = 90, .alignment = .end, .sortable = true },
        };
        self.table.selection = &self.chosen;
        self.table.sort = &self.sort;
        const result = try collections.table(v, &self.table, &columns,
            .{ .context = self, .count = self.files.len, .key = key },
            .{ .context = self, .call = cell },
            .{ .style = .{ .grow = 1, .self_align = .stretch, .name = "文件" } });
        if (result.sorted) self.resort();
        if (result.submitted) |row| self.open(row);
    }
};
```

## 行与内容

`Rows` 给出行数和可选回调，它们的 `context` 在构建、绘制和输入期间都必须有效：

- `key(row)`：行所属项目的非零唯一键；没有时第 `i` 行的键是 `i + 1`（按位置选择）。
- `label(row, scratch)`：行的文字。集合有焦点时键入它的前几个字母会选中它，辅助技术以它为行名；表格没有它时用第一个非行头列的文字。
- `header(row)`：标出分节标题行。标题行横跨所有列（表格用第 0 列的内容），顶部那一节的标题固定在顶部，直到下一个标题把它推走。向前查找标题最多 `header_search`（4096）行。

`CellSource.call(row, column, scratch)` 返回 `Cell`：文字、颜色、字体和文字前的方形图片。文字在绘制时复制，可以写在给出的 512 字节临时缓冲里。选中时文字改用强调色上的前景色。

## 选择

`collections.Selection` 以应用提供的存储保存选中项目的键，按键排序，所以查询是 O(log n)，范围选择一次排序并入；存储长度是能同时选中的最多项数，超出时状态的 `core.last_error` 记为 `SelectionFull`，选择保持不变（Ctrl+A 在行数多于容量时整体拒绝）。`.single` 只选一行。`anchor` 是 Shift 范围的起点，`cursor` 是键盘所在行，`version` 随每次改动递增。已不在集合中的键会保留，由应用移除。

- 单击选中一行；Ctrl+单击加入或取出；Shift+单击从 anchor 选到这一行，Ctrl+Shift 把范围加入已有选择；在空白处单击清除选择。
- Up/Down、Home/End、PageUp/PageDown 移动并选中，Shift 扩展范围，Ctrl 只移动光标；Space 选中光标行，Ctrl+Space 切换，Shift+Space 选范围；Ctrl+A 全选（多选时）。移动后的行以最小位移滚入可见区。
- Enter 或双击在 `Result.submitted` 报告行号；双击还在 `Result.double_clicked` 给出指针下的行与列（列是传入列数组的下标），点击照常选择。
- 键入字母或数字（ASCII，不分大小写）按 `label` 前缀查找，1 秒内连续键入组成前缀；重复同一个字母依次跳到下一个以它开头的行。
- `drag_select`（多选）：从一行开始的主键拖动像 Shift+单击那样选中经过的行，按下时按住 Ctrl 则加在已有选择之上（已有选择超过 256 项时只增不减）。指针靠近或越过上下边缘时随时间滚动，越远越快（最快 1200 DIP/s），需要视图的[调度器](view.md#时间与唤醒)持续唤醒；拖动期间 `Result.drag_selecting` 为 true。按下已选中的行要等松开才改选择，因此拖动已选的行不会丢掉选择。
- `TableState.extendTo(row)` 像 Shift+单击该行一样扩展选择。

`Result.changed` 报告用户改变了选择；结果在输入之后的下一遍构建中返回。

## 滚动

集合自己滚动：滚轮和触控板纵向滚动（横向滚动列），到达边界时不消费，交给外层滚动容器；右侧与底部画不可交互的指示条，右侧条可以拖动。

- 行变化时集合保持顶部的项目不动：顶部那一行的键在原位置附近 `anchor_search`（4096）行内找到后，偏移随之调整，例如在上方加载旧消息时。`keep_offset` 改为保持偏移（适合随数据重新排序的行），选择仍跟随项目。
- `follow_end` 从末尾开始，内容增长时保持末尾可见，直到用户滚离；滚回末尾后继续跟随。`scrollToEnd()` 也重新开始跟随。
- `scrollTo(row, .start/.center/.end/.nearest)`、`scrollIntoView(row)`、`scrollToEnd()`、`setScrollOffset(f64)`；`visible()` 返回上一次绘制时可见的首末行，`atEnd()` 表示末尾是否可见，用于接近末尾时加载更多。在第一次绘制之前请求的滚动会在知道尺寸后应用。

偏移以 f64 DIP 保存。

## 表格

`Column` 有 `id`（为 0 时取标题的键）、标题、`width`（0 表示平分其他列剩下的空间）、`min_width`/`max_width`、`alignment`、`sortable`、`fixed` 和 `row_header`。最多 `max_columns`（64）列，id 必须唯一。

- **调整宽度**：拖动列头的右边缘（±4 DIP）调整该列宽度，限制在最小与最大宽度之间；它之前平分空间的列固定为当前宽度，使边缘跟随指针。双击边缘按标题与可见单元格的文字宽度适配该列（`TableOptions.measurer` 给出文字宽度，默认是视图的保守估计）。
- **移动**：拖动列头把列移到其他列之间，一条线标出位置；`fixed` 列保持原位与原宽度，排在开头的 fixed 列在横向滚动时保持可见（冻结列）。
- **横向滚动**：列总宽超过表格时横向滚动，表头随之移动；没有单元格选择时 Left/Right 也横向滚动。
- **保存布局**：`TableState.layout(&buffer)` 按显示顺序给出每列的 id 和宽度（平分的列为 0），`Result.arranged` 在用户调整或移动列时为 true；`restore(saved)` 在下一遍按 id 恢复顺序与宽度，未知的列按自身顺序跟在后面。
- **排序**：设置 `TableState.sort` 后，单击可排序列头按它升序，再次单击反转；表头画箭头，辅助技术读到方向，`Result.sorted` 报告变化，行的顺序由应用按 `sort` 排列（用 `key` 让选择跟随行）。设置 `sort_by`（`SortKeys`，最多 8 列）时按多列排序：普通单击只按这一列（已是第一列时反转），Ctrl+单击或 Shift+单击把列追加为升序，再按一次变降序，第三次移除；多列时列头显示次序号，`sort` 保持为第一列。行头列不排序。
- **重排行**：`reorder`（不能同时 `drag_select`）让用户把行拖到其他位置，一条线标出插入点；松开时 `Result.moved` 给出拖动的行、插入到哪一行之前（等于行数表示末尾），以及该行是否已选中（是则应用移动所有选中的行）。放回原处不产生移动。
- **悬停与外观**：悬停行有浅色背景；选中行从边到边以强调色填充，`round_rows` 改为圆角。

### 单元格选择

`cell_select`（需要多选 `Selection` 和 `TableState.cells`）让表格像电子表格那样选择一块单元格：选中的行 × 从 `Cells.anchor` 到 `Cells.cursor`（按显示顺序）的列，`all` 表示所有列。只有一块，不支持不相邻的多块。

- 单击单元格选中它的行和列；Shift+单击把行和列都扩展到它；Ctrl+单击切换行并保留列。拖过单元格选中经过的块，靠近边缘时上下左右滚动。
- Left/Right 移动光标列，Shift 扩展列；不带 Shift 的上下键把列收回到光标列；Ctrl+A 选中所有行和列。大纲表格里 Left/Right 仍用于展开折叠，列只能用指针选择。
- `row_header` 列（如行号）单击或拖动选中整行（所有列），单击它的列头选中所有行。
- 块内单元格以强调色填充，整行选中时行头也填充；表格有焦点时光标单元格带边框。`cellSelected(row, column)` 告诉单元格回调该格是否选中，`selectedColumns(&buffer)` 按显示顺序返回块的列，`selectColumns(from, to)` 选中所有行和一段列。

## 大纲

`Tree` 给出 `count(parent)`（`null` 表示顶层；为 0 的项目是没有箭头的叶子）、`child(parent, index)`、`label(item, scratch)` 和 `revision`（树的项目改变时递增，展开折叠不需要改）。`OutlineState.open` 是展开项目的 `Selection`（多选），`rows_buffer` 是应用提供的可见行缓冲，容量不足时构建返回 `RowsFull`。可见行在 `open.version` 或 `revision` 改变时按深度优先重新收集，深度最多 `max_depth`（64）层；`rows()`、`item(row)`、`depth(row)` 读取它们。行的键就是项目，选择与位置随项目跟随展开折叠。

- 单击箭头展开或折叠（Alt+单击连同其中所有项目），不改变选择。
- 有焦点时 Right 展开光标项目，已展开则移到第一个子项；Left 折叠，已折叠则移到父项；加 Shift 展开或折叠其中所有项目。
- 折叠一个其后代持有光标的项目时选中该项目。
- `Result.toggled` 报告展开状态的改变。`OutlineOptions.indent` 是每层缩进（默认 16 DIP）。

`outlineTable(v, &state, columns, tree, cell, options)` 把大纲放进表格的列：传入的第 0 列显示缩进与箭头，单元格回调按项目和列给出内容，列可以像表格那样调整、移动和排序。

## 网格视图

`gridView(v, &state, items, item, options)` 把项目排成尽可能多列，每项至少 `min_item_width` 宽并平分剩余宽度，行高 `item_height`，`gap` 是项目之间与四周的间距。`GridItem` 是一张图片（按比例缩放）和下方一行文字。

- 单击或方向键（两个方向）选中，Home/End、PageUp/PageDown 按整页行移动，Ctrl+单击切换，Shift+单击与 Shift+方向键按项目顺序选范围，Ctrl+A 全选，Enter 或双击提交；键入字母按 `label` 查找。
- `drag_select` 与 `reorder` 与表格相同；重排时一条竖线标出插入位置。
- `columns()` 返回当前列数，`visible()` 返回可见行的首末项目。

## 可访问性

启用 `-Daccessibility=true` 时，Windows UIA 把表格与大纲表格映射为 DataGrid，表头为 Header，列头为 HeaderItem（排序方向放在 ItemStatus，调用它即单击排序），可见行为 DataItem / SelectionItem；没有列的大纲为 Tree，行为带层级和展开状态的 TreeItem；网格视图为 List，项目为 ListItem。每帧最多暴露 `max_semantic_rows`（40）个可见行（窗口的语义树共 128 个节点）。辅助技术选择、加入、移出、展开和折叠这些行时作用于对应项目。屏外行不暴露，行也不报告“第几项/共几项”；单元格选择的块不单独暴露。Linux 没有普通控件的 AT-SPI 层。

## 当前范围

没有列头和单元格的右键菜单（嵌入叶子只收到主键按下）、单元格内的原位编辑、可变行高与按内容测量行高、跟随末尾的动画、RTL 镜像、网格的分节标题。键入查找只识别 ASCII 字母与数字。

## 验证

`zig build test-view-collections` 已接入默认 test/check，用无窗口 Harness 覆盖：选择的排序存储与范围；十万行表格只暴露可见行、单击/Ctrl/Shift 选择、方向键/Home/End/PageDown/Ctrl 移动/Ctrl+Space/Enter、容量不足的 Ctrl+A；滚轮与双击；键入查找；单列与多列排序、列宽拖动、双击适配、列移动、布局保存与恢复；辅助技术选择与列头排序；插入行时保持顶部项目、`keep_offset`、`follow_end`；`scrollTo` 的四种对齐；拖选与边缘滚动；行重排；单元格块选择、行头、冻结列与横向滚动；大纲的箭头、Left/Right、Shift 全部展开折叠、折叠时选中父项与辅助技术展开；大纲表格；网格视图的列数、二维移动、范围选择与窗口变窄。隐藏窗口检查 `zig build smoke-view-collections` 经窗口的 Context 向百万行表格发送按键并以 GDI/Cairo 绘制，验证选择、范围、提交、滚动与焦点。这些检查不验证真实读屏播报或视觉效果。

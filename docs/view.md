# 声明式视图

`ziggurat_view` 在 `ziggurat_ui` 之上提供声明式写法：应用写一个构建函数，从当前状态描述整棵视图树；`view.Host` 用弹性布局测量、排列，再录制成 Frame。控件直接绑定应用的值，激活结果以返回值交给构建函数。底层的控件、命中、语义与主题规则保持不变，见[基础控件](widgets.md)与[布局](layout.md)。

```zig
const view = @import("ziggurat_view");

const Counter = struct {
    count: i64 = 0,
    autosave: bool = false,
    volume: f64 = 0.5,
    fn build(self: *Counter, v: *view.View) anyerror!void {
        try v.textf("计数：{d}", .{self.count}, .{});
        try v.row(.{ .gap = 8, .alignment = .center });
        if (try v.button("加一", .{})) self.count += 1;
        try v.spacer(.{});
        if (try v.button("清零", .{ .enabled = self.count != 0 })) self.count = 0;
        try v.end();
        _ = try v.checkbox(&self.autosave, "自动保存", .{});
        _ = try v.slider(&self.volume, .{ .minimum = 0, .maximum = 1, .step = 0.05 }, .{ .self_align = .stretch });
    }
};

var counter: Counter = .{};
var storage: view.Storage(64, 2048) = .{};
var host = view.Host.init(&counter, Counter.build, storage.buffers(), .{});
try host.attach(window);
```

完整示例见 `examples/view_counter.zig`（`zig build run-view-counter`）。

## 构建与输入

Host 拥有一个 `ui.Context`，从 attach 到 Context 的 detach 回调期间必须保持地址稳定，规则与普通 Context 相同。构建函数在两种场合运行，都在主线程：

- **绘制**：每次 paint 运行一遍构建，随后测量、排列、录制。失败的帧保留上一帧，错误记录在 `host.last_error`。
- **输入**：Context 每交付一个动作或数值变化，或滚轮落在滚动容器上，Host 立即运行一遍构建并携带该事件。拥有该 ID 的控件在这一遍中消费事件：`button`/`link` 返回 true，`checkbox`/`toggleSwitch`/`disclosure` 翻转绑定的布尔值，`radio`/`segment`/`tab` 选中自己的选项，`slider`/`stepper`/`split` 对绑定的**当前值**应用 `ValueChange`，`scroll` 移动它的模型。这一遍不录制也不排列，`host.view` 里的节点边界要到下一次绘制才更新；Context 随后照常使窗口失效。

因此连续输入在重绘前逐个作用于状态，不会被重绘合并吞掉。事件的 ID 若已不在树中（例如上一个事件移除了该控件），这一遍不改变任何值。构建函数应只依据状态描述视图，可以重复调用；副作用放在控件返回 true 的分支里。

## 身份

每个节点的 ID 由父节点 ID、它在兄弟中的序号和节点种类哈希得到，跨帧稳定，种类变化即换新 ID。兄弟顺序会变化的节点（列表项、条件出现的控件之后的节点）应提供 `Style.key`；`view.key(text)` 从字符串派生键。同一父节点下键必须唯一，重复会在录制时被 Context 拒绝。

## 布局

隐式根节点是填满窗口的列，样式来自 `Options.root`（默认内边距 24、间距 12、交叉轴起始对齐）。`column`/`row` 与 `end` 配对，最多嵌套 32 层；单个容器最多 256 个子节点。测量自底向上、排列自顶向下，均调用 `ui.layout.measure/arrange`，不分配内存。

`Style` 同时描述容器与它在父布局中的参与方式：

- 容器：`gap`、`padding`、`alignment`（子项交叉轴对齐）、`justify`、`clip`、`background`、`border`、`border_width`、`radius`。
- 参与：`grow`、`shrink`、`self_align`、`width`/`height`（固定尺寸）、`min_*`/`max_*`，网格子项另有 `column_span`。
- 内容：文本的 `color`，`enabled`（容器上为 false 时其下所有节点都禁用），没有可见标签的控件或具名容器的可访问名称 `name`。
- 隐藏：`hidden = true` 让节点和其中构建的一切隐藏并让出位置，相邻节点合拢，也不为它留间距；它不绘制、不接收指针与焦点，也不暴露给可访问性客户端。与不构建它不同，其中的内容照常构建，应用绑定给它们的状态（滚动偏移、正在编辑的文本、动画）保留到再次显示。隐藏时其中的焦点离开；锚定在它上面的浮层、弹出列表和提示随它隐藏，其中的对话框不遮罩窗口。

```zig
try v.column(.{ .hidden = !self.show_details, .gap = 8 });
try v.embed(self.notes.embed(), .{});
try v.end();
```

- 盒阴影：`shadows`（`[]const BoxShadow`，至多 `max_shadows` 个）如 CSS 的 `box-shadow`：节点的圆角矩形按 `x`、`y` 偏移，按 `spread` 外扩（负值内缩，圆角随之增减），按 `blur`（CSS 的模糊半径，即高斯标准差的两倍）模糊，以 `color` 画在背景之下，第一个在最上。阴影不占空间、不裁剪，只画在盒子之外：没有不透明背景的盒子用偶奇路径裁剪把盒子本身挖掉，半透明的盒子不会透出阴影。模糊需要 `Host.prepareShaderEffects`，与 `blur` 相同，没有时阴影是锐利的。切片在帧绘制前借用。
- 渐变：`gradient` 以渐变代替 `background` 填充容器（按 `radius` 圆角），`border_gradient` 以渐变代替 `border` 的颜色描边 `border_width` 宽的边框；材质与折射仍优先。`Gradient` 有三种，位置都按节点盒子的比例给出，盒子变化时跟着走，色标 `GradientStop{ color, at }` 按 0 到 1 的位置排列（乱序的色标上移到前一个的位置，与 CSS 相同），最多 16 个，`oklab = true` 时在 Oklab 色彩空间混色：
  - `linear{ angle, stops }`：沿穿过盒子中心的直线，`angle` 是从正上方顺时针的角度（180 自上而下，90 自左向右），直线长度等于盒子在该方向上的跨度，同 CSS 的 `linear-gradient()`。
  - `conic{ center, angle, stops }`：绕 `center` 从 `angle`（从正上方顺时针）转一整圈，同 CSS 的 `conic-gradient()`。
  - `radial{ center, radius, stops }`：从 `center` 呈圆形向外扩散，`radius` DIP 处到达 1；`radius` 为 0 时到达离中心最远的角，同 CSS 的 `radial-gradient()` 默认的 `farthest-corner`。中心之前显示第一个颜色、半径之外显示最后一个颜色，用于光晕、聚光与暗角。`center` 为 null 时是盒子中心。

```zig
const stops = [_]view.GradientStop{ .{ .color = ui.Color.rgb(0xa5b4fc), .at = 0 }, .{ .color = ui.Color.rgb(0x312e81), .at = 1 } };
try v.column(.{ .width = 240, .height = 140, .radius = 16, .gradient = .{ .radial = .{ .center = .{ .x = 0.3, .y = 0.2 }, .stops = &stops, .oklab = true } } });
```

- 局部主题：`themed(&theme, style)` 与 `end` 配对，开始一个其中的节点以 `theme` 构建的列（等价于 `Style.theme`）：它们按该主题的 metrics 测量，按它的配色绘制（控件、焦点环、文字），列本身在没有 `background` 时填充该主题的背景色，与根节点填充窗口主题相同。其中打开的浮层、菜单、对话框和提示同样用这个主题；根节点与它之后的节点仍是窗口主题。`v.scopeTheme()` 返回正在构建处的局部主题（窗口主题时为 null）。主题按指针借用，到本遍绘制完成前有效。
- 忽略输入：`ignore_input = true` 让节点及其中的一切不挡指针与键盘：按下、滚轮和悬停落到下面的内容，Tab 跳过它们，其中的焦点离开；但它们照常绘制并留在可访问性树中，屏幕阅读器的按下与点击一样生效。悬停才显示的按钮可以以 `opacity = 0` 常驻供读屏使用，而不抢所在行的按下。
- 对辅助技术隐藏：`access_hidden = true` 让节点及其中的一切照常绘制、照常接收指针与键盘，但不进入可访问性树，如同 HTML 的 aria-hidden：叠在下面的卡片、交叉淡化时画出的旧文字副本不会被读屏读到，它们的文字不计入外层控件的名称（见下文无外观控件），辅助技术的请求也到不了它们。锚定在其中的浮层、菜单、列表与提示一并隐藏。与 `ignore_input` 同时设置即为惰性（inert）；`presentColumn` 正在退出的内容就是这样。检查器把这样的节点的角色显示为 ignored。
- 对辅助技术禁用：`access_disabled = true` 告诉辅助技术节点及其中的一切不可用，如同 HTML 的 aria-disabled，但它们保留指针、键盘焦点、Tab 顺序中的位置和外观：读屏仍能到达并读出它们（读作不可用，连同说明原因的描述），只是不会按下或编辑它们（`Context` 丢弃这些请求）。点击和按键照常交给应用，由应用在不可用时忽略。不变暗；`enabled = false` 才一次做完全部。
- 不进 Tab 顺序：`tab_stop = false` 让可聚焦节点不被 Tab 经过，如同 tabindex=-1，按下、组内方向键和 `Host.focusNode` 仍能聚焦它。
- 角色：`role` 让容器或文本在辅助技术面前不只是分组或一段文字：`.region`（地标区域，用 `name` 命名）、`.navigation`、`.article`、`.group`、`.log`（聊天记录，新增的内容会被礼貌地读出）、`.timer`、`.alert`（出现或改变的内容立即打断朗读）、`.status`（状态信息，如“已选 3 行”“已保存”：其中的文字改变时整段礼貌地读出，如 aria-atomic；状态按元素 ID 与上一帧对照，前面会增删兄弟节点时给它 `key`，ID 变了视为新出现，不读；辅助技术刚接入时与状态第一次出现时不读；在 log、alert 或另一个 status 之内的只作为它们的一部分）、`.separator`、`.heading`（级别取自字体：`Font.heading1` 为 1 级，依此类推）、`.grid`（单元格接收焦点与方向键的表格，如应用自绘的电子表格）、`.tree_grid`（行可展开的网格）、`.row` 与 `.cell`（这类表格的行与单元格）、`.deletion` 与 `.insertion`（差异视图里删去与加入的行、划掉的旧价格）、`.tab_panel`（标签页的内容：用 `name` 按其标签命名，并让标签用 `controls` 指向它）、`.main`（窗口的主要内容，一个窗口一个，不必命名）、`.banner`（窗口顶栏，带应用名或窗口标题，至多一个）、`.content_info`（窗口页脚或状态区里关于内容的信息，如字数、作者，至多一个）与 `.complementary`（补充主要内容、自身也成立的侧栏或检查器；有多个时用 `name` 区分）。屏幕阅读器会列出这些地标并在其间跳转。带角色的容器里的文本节点作为文本进入可访问性树，供实时区域朗读。
- 表格与集合的位置：`row_count`、`column_count`（aria-rowcount/aria-colcount，表头行计入，0 表示按已构建的数）放在表格或网格上，`row_index`、`column_index`（aria-rowindex/aria-colindex，从 1 起）放在行或单元格上，供只构建可见部分的表格读出“第 41 行，共 1000 行”；`position_in_set` 与 `set_size`（aria-posinset/aria-setsize，从 1 起，0 不设）放在自建的列表、列表框、树、菜单或标签列表的条目上，优先于内置集合按已构建的条目数出的位置。虚拟表格自己报出全部行数、列数和行、列头的索引。`multiselectable`（aria-multiselectable）声明自建的列表框、网格、树或树网格可以多选；`access_selected`（aria-selected）把标签、选项、行、单元格或树条目报为选中或未选中，而不画内置选中行的强调色，供用自己方式显示选择的条目使用。
- `read_only`（aria-readonly）告诉辅助技术用户不能改它的值，只在 ARIA 允许的角色上报出：文本框、组合框、复选框、开关、滑块、数字框、单选组、列表框、网格、树网格，以及网格的单元格与行列表头（`role = .grid`/`.tree_grid` 的自建网格，或 `.cell`）；按钮、区域等其他角色不报。视图自己的控件行为不变，只改变报给辅助技术的状态。检查器与自动化插件也按 `Style.role` 报出容器与文字的角色（`tabpanel`、`main`、`banner`、`contentinfo`、`complementary`、`grid`、`gridcell` 等），自动化树把 `read_only` 报为 `readOnly` 状态。
- 校验、方向与搜索：`invalid`（aria-invalid）把值标为不合法而不带消息，例如失焦时仍为空的必填字段；`orientation`（`.horizontal` 或 `.vertical`，aria-orientation）告诉辅助技术自建的滑块、分隔线、分栏、工具栏、标签列表或菜单朝哪个方向排列，不设时平台按形状猜；`search`（role=searchbox）让文本输入成为搜索框，`search` 区域里的输入自动如此。
- 自绘文本框：应用自己绘制并处理按键的文本框（嵌入叶子用 `frame.semantic` 记录 `.text_box` 节点）用 `read_only` 与 `multi_line`（aria-readonly、aria-multiline）告诉辅助技术它只读、可多行；其他角色忽略 `multi_line`，只读的文本框不接受辅助技术改值。框架自带的编辑器自己决定：多行的 `TextField`（`ziggurat_document_editor.Field` 的 `multiline`）与富文本编辑器报告多行。Linux ATK 报 multi-line 而不是 single-line 状态，macOS 报 AXTextArea 角色而不是 AXTextField，Windows 在 AriaProperties 里给出 `multiline=true` 与 `readonly=true`。
- ARIA 属性：`role_description`（aria-roledescription）、`key_shortcuts`（aria-keyshortcuts，如 "Control+S"）、`value_text`（aria-valuetext，如 "5 星中的 3 星"）、`busy`（aria-busy）、`current`（aria-current）、`popup`（aria-haspopup，给自己构建弹出内容的按钮）、`sort`（aria-sort）、`auto_complete`（aria-autocomplete）。三个平台分别映射到 ATK 的状态与对象属性、NSAccessibility 的属性（含旧 API 的 AXEnabled 等）与 UI Automation 的属性（LocalizedControlType、AriaProperties、AcceleratorKey、LiveSetting、LandmarkType、HeadingLevel）。
- 标签与控制关系：`v.labelledBy(control, label)` 用视图自己画出的标签文字给控件命名，代替控件自己的名称，如同 aria-labelledby；点击标签会把点击交给控件，如同 HTML 的 `<label for>`：聚焦它（或组里选中的那一项），并点击复选框、开关或单选按钮。`v.controls(control, controlled)` 声明一个节点控制另一个（aria-controls），例如按钮与它展开的面板。两者都在两个节点建好之后调用，id 由 `lastNode().id` 取得。`v.describedBy(control, hint)`（aria-describedby）让视图画出的提示或帮助文字在控件的名称和值之后读出，即使提示本身对辅助技术隐藏；`v.errorMessage(control, message)`（aria-errormessage）指出保存错误消息的节点：控件不合法（`Style.invalid` 或所在字段的错误）期间，消息先于提示读出，辅助技术也能跳到它。两者同样在节点建好之后调用。

三个平台对这些属性的映射：Linux ATK 用 table/tree table 角色与 xml-roles grid/treegrid/searchbox、content deletion/insertion 角色、rowcount/colcount/rowindex/colindex 属性、described-by/description-for 与 error-message/error-for 关系、vertical/horizontal 状态；macOS 用 AXTable、AXDeleteStyleGroup/AXInsertStyleGroup、AXSearchField 子角色、AXARIARowCount 等属性、AXErrorMessageElements、AXOrientation，旧 API 也回答 AXHelp，列表没有自己的大小时取其条目的 set_size 作为 AXRowCount；Windows 共享层把网格报为 DataGrid，表格、网格与树状网格带 Grid 与 Table 模式，其单元格与行列标题带 GridItem 与 TableItem（按 row_index/column_index、行的 position 或已建出的行与单元格数出所在行列），可选的单元格带 SelectionItem；删除与插入报为本地化类型 deletion/insertion 的文本、搜索框报为 search box 的编辑框，给出 Orientation（滑块与分隔线默认横向）、FullDescription、ControllerFor（controls，无效时加上 error_message）、DescribedBy、AriaRole、Level、PositionInSet 与 SizeOfSet；`.tab_panel` 是本地化类型为 tab panel 的 Pane，`.main` 是 main 地标类型的 Group，`.banner`、`.content_info`、`.complementary` 是自定义地标类型、分别名为 banner、content information、complementary 的 Group；Linux ATK 把 tab panel 报为 scroll pane、这四个地标报为 landmark，都带 xml-roles；macOS 把 tab panel 报为角色描述为 tab panel 的 AXGroup，四个地标报为 AXLandmarkMain/AXLandmarkBanner/AXLandmarkContentInfo/AXLandmarkComplementary 子角色的 AXGroup。名称、启用、有效性、描述、AriaProperties、勾选、选中、展开、范围值与文本值变化时，Windows 发属性变化事件，焦点移动时发焦点事件。
- 焦点环：持有键盘焦点的控件画主题的焦点环：宽 `Metrics.focus_ring_width`（默认 2 DIP），内缘在控件边缘外 `Metrics.focus_ring_offset`（默认 1 DIP；0 落在边缘上，负数在边缘内），颜色为调色板的 `focus`。列表、树与表格的行、列头会被外层列表裁剪，默认画在行内。`Style.focus_ring_offset` 单独设置一个节点的偏移，例如外层容器裁剪越界内容时用负值把环画到里面；`Style.focus_ring_color` 单独设置颜色。
- 滚动指示器：滚动容器的 `scrollbars = false` 不画滚动指示器，滚轮、按键和辅助技术照常滚动，适合自己绘制指示的表面。
- 占位符：`search`、`tokenField` 与 `editableComboBox` 的 `placeholder` 与 `placeholder_color` 交给直接放在其中的文本输入，输入为空且没有输入法组合时显示（见下文 `TextField` 的同名选项）。
- 层叠顺序：`z_index`（默认 0）决定兄弟节点的绘制先后，如 CSS 的 `z-index`：数值大的画在上面、先接收指针，相同的保持构建顺序。它只改变绘制与命中，不改变排布，Tab 顺序与读屏顺序仍按构建顺序。

`spacer` 默认 `grow = 1`。叶子的固有尺寸来自文本宽度与主题 metrics：按钮在文本两侧留出内边距，复选框与开关加上指示器和标签间距，进度条与滑块有默认宽度且可以收缩到零，步进器宽度是高度的四倍，两端按钮为正方形。

### 网格

`grid(columns, style)` 与 `end` 配对，子项按行自动放置进 `ui.grid` 的列轨道（`Track.fixed`、`fraction`、`minmax`），每个子项占 `Style.column_span` 列，行高随内容。`gap` 同时是行距和列距，`padding` 与 `alignment`（单元格内两个方向的对齐）沿用容器字段，`clip` 决定是否裁剪溢出。网格自身的最小和首选尺寸分别以全部子项的最小、首选尺寸求得。`columns` 是借用的，只需在本遍排列完成前有效，通常用常量数组。

`fraction` 轨道按 CSS 的 `fr` 分配：先给各轨道按内容的基础尺寸，余下的空间按权重分给 `fr` 轨道，分到的少于基础尺寸的轨道停在基础尺寸，其余的重新按权重分；`fr` 轨道本身的最小尺寸为 0，宽内容的列可以缩到内容以下。`Track.fractionMinContent(weight)` 是 `minmax(min-content, Nfr)`：它不会缩到内容的最小尺寸以下，分不到时溢出。

### 滚动

`scroll(&model, style)` 与 `end` 配对，开始一个纵向滚动、始终裁剪的列。`ui.scroll.ScrollModel` 由应用持有，跨帧保存偏移。它的最小高度为零，首选高度是内容高度，所以要让它出现滚动，需给它固定 `height`，或者在受限的父容器里用 `grow`/收缩。每次排列都会以视口和内容尺寸调用 `model.setSizes`，偏移随内容变化被夹回有效范围；子项按内容坐标排列后整体上移 `offset.y`，因此节点边界始终是窗口坐标。内容溢出时，右侧画一条不可交互的细滑块指示位置。

`Style.scrollbars = false` 时不画这条滑块，其余滚动行为不变。

自己滚动、不经滚动容器的视图（终端、富文本编辑器、虚拟表格与大纲）用 `ui.scroll.Bar` 画滚动条，外观与滚动容器一致，跟随主题：`box` 是滑块所沿的视图（右边缘，`leading` 时左边缘，横向时底边），`view`、`content`、`offset` 是可见长度、总长度与偏移，单位任意（终端用行数）。`Frame.scrollbar(bar, .{ .dragging, .color })` 画滑块：默认主题的 `track` 色，`color` 给自有配色的视图（如终端）替换；拖动时向内容一侧加宽 2 DIP；无处可滚时什么也不画。`thumb` 给出滑块矩形，`offsetAt(start)` 把拖动中滑块起点换算成偏移，`hit(point)` 判断指针是否在边缘 12 DIP 的条带上。终端与富文本编辑器只在指针位于其上或拖动滑块时显示滚动条；虚拟集合与滚动容器一样常显。

`ui.scroll.Style` 是滚动条的样式：`track_width`（整条宽度，含轨道）、`thumb_width`（滑块宽度，在轨道里居中）、`radius`（滑块圆角，null 时两端全圆）、`square`（直角）、`min_length`（滑块最短长度）、`flush`（轨道与滑块延伸到两端，不留边距），以及颜色 `track`（设置时沿整条画轨道）、`thumb`、`thumb_hovered`（指针在滚动条上）与 `thumb_dragged`（拖动中），颜色为 0xAARRGGBB，alpha 为 0 视为不透明。`Theme.scrollbar` 给主题的全部滚动条一种样式，滚动容器的 `Style.scrollbar_style` 代替它；`Frame.scrollbar` 对样式为零值的 `Bar` 使用主题的，`Frame.scrollbarStyle()` 给出主题的样式，供自己滚动的视图在输入时按同样的几何判断（虚拟集合、终端与富文本编辑器都这样接入）。`Bar.paintStyled(target, rest, .{ .dragging, .hovered })` 画轨道与该状态的滑块，`trough()` 是整条的矩形，供在条上画标记的视图使用。零值样式与以往完全相同：4 DIP 宽的圆角滑块，离边缘与两端 2 DIP，主题的 `track` 色，没有轨道。像代码编辑器那样的滚动条：

```zig
theme.scrollbar = .{ .track_width = 14, .thumb_width = 10, .square = true, .flush = true, .thumb = 0x66_79797a, .thumb_hovered = 0xb3_646464, .thumb_dragged = 0x66_bfbfbf };
```

Host 在每帧绘制后记录可见的滚动容器（最多 `max_scroll_regions` 个，按绘制顺序），滚轮事件落在其中时交给最内层的那个，作为一个携带 `Event.scroll` 的构建遍立即作用于模型并消费该事件；不在任何滚动容器内的滚轮照常交给 Context。目前没有滚动条拖动、焦点自动显露和横向滚动。

滚动容器也可以用键盘滚动：控件与应用都没有处理的按键里，Up/Down 滚一行（40 DIP），PageUp/PageDown 与 Space/Shift+Space 滚一页（视口高度减一行，至少半个视口），Home/End（macOS 上还有 Cmd+Up/Down）滚到顶或底。按键交给焦点所在、在这个方向上还能滚的最内层滚动容器；焦点不在滚动容器里时交给指针下的。焦点接收文本时（`focusTakesText`）Space 不翻页，照常输入空格。

`Style.sticky`（`Sticky{ top, right, bottom, left }`，单位 DIP）让节点如 CSS 的 `position: sticky` 停在最近的滚动容器（没有时是窗口）边缘：滚动让它越过设定的距离时，它连同后代平移回来停住，直到它的父容器的内容区滚走、把它推出去。分节列表的标题因此停在顶部，下一节的标题到来时把它顶走。停住的节点画在兄弟节点之上，命中与可访问性边界跟随平移后的位置。

滚动容器的 `scroll_snap`（`.mandatory` 或 `.proximity`）让滚动结束时停在吸附点上，如 CSS 的 `scroll-snap-type`：其中设置了 `snap_align`（`.start`、`.center`、`.end`）的后代各给出一个吸附点（嵌套的滚动容器内的不算）。`mandatory` 总是停在一个吸附点：一次滚动之后停在滚动方向上的下一个，不再往回；`proximity` 只在离最近的吸附点不到视口三分之一时吸过去。比视口还大的节点在其内部可以自由滚动。

`View.scrollIntoViewWith(id, .{ .block, .glide })` 把节点滚进外层滚动容器的视口，`block`（`ScrollAlign`）是 `.nearest`（默认，已经可见时不动，同 `scrollIntoView`）、`.start`、`.center` 或 `.end`，同 DOM 的 `scrollIntoView({ block })`；`glide`（`animation.Tween`）让偏移按缓动滑过去，而不是跳过去，系统要求减少动态效果时直接跳。新的滚动打断滑动。

`View.inView(id, .{ .margin, .amount })` 回答节点在上一遍是否进入了视口（外层滚动容器与窗口的交集），如 IntersectionObserver：`margin`（`Insets`）把视口向外扩（负数向内收），用于提前加载；`amount`（0–1）要求可见部分至少占节点面积的这个比例，0 表示接触即算。

### 标签页、分栏与工具栏

`tabs(style)` 与 `end` 配对，开始一行标签，`Style.name` 是标签列表的可访问名称；其中的 `tab(T, &selected, option, label, style)` 与 `radio` 相同地绑定一个值，激活即选中，返回选择是否改变。标签共享一个 Tab 停靠点，方向键和 Home/End 在标签间移动并选中。标签页内容由应用在 `end` 之后按所选值自行构建，视图层不保存未选中页的状态。选中的标签有底部强调条，聚焦时画焦点框。

`split(axis, &fraction, limits, style)` 与 `end` 配对，**必须恰好两个子节点**，否则 `end` 返回 `InvalidSplit`。`axis = .row` 左右分栏，`.column` 上下分栏；两个子节点在交叉轴上填满，第一个占去掉 `split_divider`（6 DIP）后长度的 `fraction`，第二个占余下部分。`limits` 是 0..1 内的 `Range`，超出返回 `InvalidRange`，绑定值每遍都被夹回其中；`step = 0` 时指针连续拖动，键盘一步为范围的百分之一。分隔条的指针按下、拖动和松开都更新值，拖动期间捕获指针；方向键增减一步（上下分栏时向下增大），PageUp/PageDown 一页，Home/End 到上下限。分栏的最小尺寸是两个子节点的最小尺寸加分隔条，但窗口更小时仍按比例分配，子节点会溢出，需要时给它们 `clip` 或滚动容器。`Style.name` 是分隔条的可访问名称。分栏的 `Style.split_reset` 给出一个比例，双击分隔条时第一栏回到这个比例（仍按 `limits` 夹住），为 null 时双击不改变尺寸。

`toolbar(style)` 与 `end` 配对，开始一行工具控件，`Style.name` 是工具栏的可访问名称。其中的叶子控件（包括嵌套行列里的）把工具栏作为可访问父节点；嵌套的单选组或标签列表仍挂在窗口根下。工具栏不改变焦点顺序，也没有溢出菜单。

启用 `-Daccessibility=true` 时，Windows UIA 把标签列表映射为 Tab / Selection（单选），标签为 TabItem / SelectionItem，工具栏为 ToolBar，分隔条为 Thumb / 可写 RangeValue（值为第一栏比例，上下限即 `limits`）。Linux 没有为普通控件提供 AT-SPI 语义，这些角色同样只在 Windows 暴露。

### 链接、徽标、分段控件与折叠区

- `link(label, style)` 画成带下划线的强调色文字，按下与 Enter 激活它（Space 不激活，如同网页的链接，留给外层滚动），返回本遍是否被激活；打开什么由应用决定，视图层不处理 URL。
- `badge(text, style)` 是圆角背景上的短标签，背景默认强调色（`Style.background` 可改），文字默认 `on_accent`（`Style.color` 可改）。它只是静态文字，不可交互，也和普通文本一样不产生语义节点。
- `segmented(style)` 与 `end` 配对，开始一行首尾相接的分段，`Style.name` 是可访问名称；`segment(T, &selected, option, label, style)` 的选择规则与 `radio` 相同，选中的分段以强调色填充。语义上是单选组和单选按钮。`Style.fill_equally` 让分段控件与父容器同宽（在行里伸展、在列里拉伸），各分段平分宽度，比份额长的标签以省略号结尾，外观、按键与单选组语义不变；同时设了 `width` 时宽度是控件自己的，分段仍平分它。
- `disclosure(&expanded, label, style)` 是带三角指示的展开标签，激活时翻转 `expanded`，返回是否改变；应用在它后面按 `expanded` 构建内容。

启用 `-Daccessibility=true` 时，Windows UIA 把链接映射为 Hyperlink / Invoke，分段为 RadioButton / SelectionItem（分组为 Group / Selection），折叠区为 Button / ExpandCollapse（已展开时 Expand、已折叠时 Collapse 不重复产生动作）。

### 面包屑、度量条、评分与手风琴

- `breadcrumbs(style)` 与 `end` 配对，开始一行通往当前页的链接，`Style.name` 是导航区域的可访问名称。相邻项之间的间隙中央画一个淡色斜杠，`Style.gap` 为 0 时间隙取 16 DIP。当前页通常是末尾的普通文本，和其他文本一样不产生语义节点。其中的控件把导航区域作为可访问父节点。
- `meter(value, range, bands, style)` 是只读度量条，例如已用存储；`Style.name` 是可访问名称。它报告值本身，而不是完成比例。`bands` 的 `low`/`high` 是首选区间，值在区间外时用主题的 `caution` 色填充。`bands.normal_color` 与 `bands.caution_color` 以应用自己的颜色（0xRRGGBB）代替区间内的强调色和区间外的 `caution` 色，未设的保持主题色；没有区间的度量条全程用 `normal_color`，即单色度量条。`Style.background` 是轨道颜色。`progress(fraction, style)` 是确定进度条：`Style.color` 代替强调色作为填充，`Style.background` 代替轨道色，如配额条用产品自己的颜色。区间超出 `range` 或 `low > high` 返回 `InvalidRange`，值被夹回 `range`。
- `rating(&score, count, style)` 绑定一个 `u8` 分数，范围 0..`count`，`count` 为 1..`ui.widgets.max_rating`（10），否则返回 `InvalidRange`。按下或拖过第 k 个标记会把分数设为 k，方向键增减 1，Home 清零，End 设为满分；返回分数是否改变。标记画成圆点，已得分的用强调色填充。语义上它是步长为 1 的滑块。
- `accordion(style)` 与 `end` 配对，开始一列分节，`Style.name` 是分组的可访问名称。`section(T, &open, option, label, style)` 绑定一个 `?T`：激活未打开的节会打开它并关闭原来打开的节，激活已打开的节会把 `open` 设为 null；返回值是否改变。分节标题与 `disclosure` 外观相同，在 `accordion` 之外调用返回 `NotContainer`。应用在每个标题后按 `open` 构建内容，这些内容也挂在分组下。
- 手风琴的标题之间用 Up、Down 移动焦点（循环），Home、End 移到第一个与最后一个；Enter 与 Space 打开或关闭。
- `accordionItem(&expanded, style)` 是没有外观的手风琴标题：打开一个容器（默认横排），由应用在里面构建标题、摘要和箭头并用 `Style.background` 等绘制，`end` 关闭后在 `expanded` 为真时构建内容。激活切换 `expanded`，各节独立开合，返回是否改变；按键与 `section` 的标题相同，辅助技术读作以 `Style.name` 或其中文字命名的展开器，并画主题的焦点环。手风琴裁剪内容时，用负的 `Style.focus_ring_offset` 把标题的焦点环画在里面。

启用 `-Daccessibility=true` 时，Windows UIA 把面包屑映射为带导航地标（LandmarkType = Navigation）的 Group，度量条为 ProgressBar / 只读 RangeValue（报告实际值与上下限，LocalizedControlType 为 "meter"），评分为 Slider / 可写 RangeValue，手风琴为 Group，分节为 Button / ExpandCollapse。

### 列表框

`listBox(style)` 与 `end` 配对，开始一列单选选项，`Style.name` 是可访问名称。`listItem(T, &selected, option, label, style)` 的选择规则与 `radio` 相同：激活或方向键移动即选中，返回选择是否改变，在 `listBox` 之外调用返回 `NotContainer`。选项是整行宽度，选中的一行以强调色填充。选项共享一个 Tab 停靠点，方向键和 Home/End 在选项间移动并选中，越过两端时回绕。

长列表放进 `scroll` 容器。输入选中某个选项后，下一次排列会滚动外层所有滚动容器，用最小的位移让它完整可见。这里的选项全部参与构建和排列，不做虚拟化；大量行请直接使用 `ziggurat_ui` 的虚拟列表。

启用 `-Daccessibility=true` 时，Windows UIA 把列表框映射为 List / Selection（单选），选项为 ListItem / SelectionItem。

### 表单字段

`field(label, info, style)` 与 `end` 配对，开始一个纵向排列的表单字段：先是标签，然后是 `end` 之前构建的内容，最后是 `info` 中的错误或帮助。内容至少要有一个节点，否则 `end` 返回 `InvalidField`。`Style.gap` 为 0 时间距取 4 DIP。`Field` 有三个字段：

- `help`：画在内容下方的淡色提示。
- `error`：非 null 时取代帮助，用 `caution` 色绘制，并把字段内的控件标为无效。是否出错由应用验证后决定，视图层不做验证。
- `required`：在标签后加 " *"，并把控件标为必填。

字段内的控件把帮助或错误作为可访问说明。没有自己名称的控件（例如滑块、步进器、文本框）以字段标签作为名称；按钮、复选框等保留自己的标签。

`fieldset(legend, style)` 与 `end` 配对，开始一列相关字段，先画图例文字，并作为以图例命名的分组暴露，其中的控件以它为可访问父节点。`Style.gap` 为 0 时取 8 DIP。和任何容器一样，`Style.enabled = false` 会禁用其中的全部控件。

启用 `-Daccessibility=true` 时，Windows UIA 把说明映射为 HelpText，错误映射为 IsDataValidForForm = false，必填映射为 IsRequiredForForm，字段集映射为 Group。

### 组合框与建议列表

- `comboBox(current, style)` 与 `end` 配对：先加入一个显示 `current`（当前选项的标签）的字段，再开始它的选项列表，用 `comboOption(T, &selected, value, label, style)` 构建选项。选项每一遍都参与构建和测量，但只在列表打开时放置和绘制；在列表之外调用 `comboOption` 返回 `NotContainer`。名称取 `Style.name`，在 `field` 里没有名称时取字段标签。
- 激活组合框、或在它有焦点时按 Down/Up 打开列表，当前选项预先高亮。打开时方向键与 Home/End 只移动高亮，焦点仍在组合框上；Enter 或 Space 选中高亮项，Escape、列表外的按下、Tab 或选中都会关闭列表，焦点回到组合框（Tab 随后照常移动焦点）。列表外的按下只关闭列表，不会同时激活下面的控件。
- `suggestions(style)` 与 `end` 配对，为刚加入的节点（通常是文本输入）开始一个建议列表，`suggestion(label, style)` 加入一条建议，选中的那一遍返回 true，应用在这个分支里把它写回输入。输入或某条建议有焦点、且至少有一条建议时列表打开；Down/Up/Home/End 移动高亮而不移动焦点，Enter 选中高亮项。选中或 Escape 后列表保持关闭，直到建议标签发生变化（例如继续输入）或再次按 Down；焦点离开时关闭。
- 同一时间最多打开一个列表。列表画在其余内容之上，宽度至少与锚点相同，最高 280 DIP，默认在锚点下方，下方放不下而上方空间更大时翻到上方，并始终夹在窗口内；超出高度的选项被裁剪。选项较多时把它们放进列表里的 `scroll` 容器，高亮项会以最小位移滚入可见区。
- 搜索输入可以放在 `search(style)` 里：它与 `end` 配对，开始一行（`Style.gap` 为 0 时取 8 DIP），作为以 `Style.name` 命名的搜索区域，其中的控件以它为可访问父节点。

```zig
try v.search(.{ .name = "查找城市" });
try v.embed(query.embed(), .{ .grow = 1, .key = 1 });
try v.suggestions(.{ .name = "城市" });
for (cities) |city| if (std.mem.startsWith(u8, city, prefix)) {
    if (try v.suggestion(city, .{ .key = view.key(city) })) choose(city);
};
try v.end();
try v.end();
```

启用 `-Daccessibility=true` 时，Windows UIA 把组合框映射为 ComboBox / ExpandCollapse / 只读 Value（值为当前标签），打开的列表为其子节点 List，选项为 ListItem；搜索区域为带搜索地标（LandmarkType = Search）的 Group。

### 浮层

- `popupButton(value, expanded, style)` 是一个显示 `value`（例如选中的日期）、画法和读法都像组合框的字段，按下、Enter 或 Space 激活的那一遍返回 true，应用在这个分支里切换紧随其后的浮层的开关。名称取 `Style.name`，在 `field` 里没有名称时取字段标签。
- `popover(&open, placement, style)` 与 `end` 配对，在前一个节点（锚点）旁边开始一个浮在窗口上的面板，`open` 为 true 时返回 true，只在这时构建内容，无论返回什么都要 `end`。`Placement` 选择放在锚点的哪一侧（默认下方）、沿该侧如何对齐（默认起始边）、与锚点的间距和是否至少与锚点同宽；这一侧放不下而对侧空间更大时翻到对侧，并始终夹在窗口内（`view.placePopover` 是同一计算）。内边距默认 8 DIP，面板画成带边框的圆角矩形。
- `popoverPresent(&open, &presence, transition, placement, style)` 是带进出动画的 `popover`：打开时从 `transition.hidden` 进入，`open` 清除后面板继续构建并按 `transition` 退出，退出结束前返回 true；退出期间面板不接收指针、键盘与焦点，也不进入可访问性树，不算作打开的浮层（Escape 与外部按下照常交给窗口）。减少动态效果时立即出现与消失。
- 浮层打开时焦点移到其中第一个可聚焦的控件（构建可以用 `v.restore` 另选，`v.popover_opened` 在打开的那一遍非空）。Escape 或在面板与锚点之外按下会清除 `open`；Escape、或焦点在里面时由构建关闭，焦点回到锚点；在外面的按下照常交给下面的控件。锚点禁用时浮层关闭。同一时间最多一个浮层。
- 由嵌入叶子组成的复合控件可以用 `takeEvent(id)` 取走本遍针对自己登记的子控件 id 的事件。

启用 `-Daccessibility=true` 时，Windows UIA 把 `popupButton` 映射为 ComboBox / ExpandCollapse，把浮层映射为本地化类型为 "popup" 的 Pane。日历、日期/时间/数字输入与颜色选择器见[选择器](pickers.md)。

### 菜单

窗口里自绘的菜单，例如右键菜单，带普通项、复选项、单选项、分隔线与子菜单：

```zig
try v.column(.{ .padding = .all(8) });
try v.text(document.name, .{});
try v.end();
if (try v.popoverMenu(.{ .name = "Document" })) {
    if (try v.menuItem("Copy", .{ .shortcut = "Ctrl+C" }, .{})) copy();
    _ = try v.menuItem("Paste", .{}, .{ .enabled = can_paste });
    try v.menuSeparator();
    if (try v.menuItem("Wrap lines", .{ .checked = wrap }, .{})) wrap = !wrap;
    if (try v.submenu("Zoom", .{})) {
        for (levels, 0..) |label, i| {
            if (try v.menuItem(label, .{ .checked = zoom == i, .radio = true }, .{ .key = i })) zoom = i;
        }
    }
    try v.end();
}
try v.end();
```

- `popoverMenu(style)` 与 `end` 配对，以前一个节点为锚点，菜单打开时返回 true，只在这时构建菜单项，无论返回什么都要 `end`。在锚点上按下次键（右键）时菜单在指针处打开；焦点在锚点内时按菜单键或 Shift+F10，菜单在锚点下方打开并高亮第一项。锚点嵌套时最内层的锚点打开自己的菜单，右键落在锚点里的控件上也一样。
- `menuItem(label, options, style)` 在选中它的那一遍返回 true（按下、Enter 或 Space），菜单随之关闭，焦点回到打开菜单之前的控件。`MenuItemOptions.checked` 非空时是复选项，加上 `radio` 画成单选的圆点；`shortcut` 只显示在项的末端并作为描述朗读，快捷键本身用 `bindKey` 绑定。禁用的项画成灰色，不能高亮，也不能选择。
- `submenu(label, style)` 加一项并开始它的子菜单，与 `end` 配对，子菜单显示时返回 true。子菜单放在这一项的末端一侧、与它顶部对齐，放不下时翻到另一侧；顶层菜单在右下放不下时向左、向上翻，并夹在窗口内。`menuSeparator()` 在两组项之间画一条线。面板最窄 160 DIP，内边距默认 4 DIP，最多 8 层。
- 项还可以带 `ItemOptions.subtitle`（标签下方的第二行小字）、`trailing`（快捷键之前的尾部值，如“125%”）、`danger`（危险操作：文字与图标用主题的 `danger` 色，高亮时与强调色对比不足 3:1 就改用强调色上的文字色）与 `icon_color`（图标颜色）；副标题、尾部值与提示或快捷键依次作为描述朗读。`Style.key` 给项一个稳定的身份。`menuItemState(label, options, style)` 与 `menuItem` 相同，但返回 `MenuItemState`，`highlighted` 让应用在键盘或指针停在某项时预览它（例如字号菜单在高亮时就预览字号）。`menuItemContent(label, options, style)` 打开一个画法与普通项相同的项容器（默认竖排，带普通项的内边距），里面的内容由应用构建并 `end`，`label` 用于命名与首字母跳转，返回 `MenuItemState`。菜单面板的 `Style.max_width` 限制面板宽度，过长的标签以省略号截断，子菜单沿用它。
- `ItemOptions.keep_open` 让菜单项被选中（按下、Enter 或 Space）后菜单保持打开、高亮留在该项上，例如账户菜单里切换主题的一排单选项。
- 打开期间菜单接管按键：Up、Down、Home、End 在最深一层的可用项之间移动高亮并循环，字母移到下一个以它开头的项；Right、Enter 或 Space 打开子菜单并高亮其第一项，Left 或 Escape 关闭最深一层子菜单，顶层的 Escape 与 Tab 关闭菜单并交还焦点。从右到左时 Left 与 Right 互换。指针移到项上会高亮它并打开它的子菜单、关闭更深的子菜单；在所有面板之外按下会关闭菜单，并照常交给下面的控件；面板上的滚轮不会滚动下面的内容。
- `popoverMenuButton(label, style)` 是一个菜单按钮：画法像带箭头的组合框，菜单画在窗口里、它的下方并与它的起始边对齐，下方放不下时翻到上方。按下、Enter、Space 或 Down 打开菜单并高亮第一项，Up 打开并高亮最后一项（WAI-ARIA 菜单按钮模式），菜单显示时再按按钮会关闭它，期间按钮读作已展开。菜单的按键、首字母跳转、子菜单和焦点交还都与 `popoverMenu` 相同，选中或 Escape 后焦点回到按钮。与 `end` 配对，菜单打开时返回 true，只在这时构建菜单项。名称取 `Style.name`，否则取 `label`。按钮读作打开菜单（`has_popup`）。`popoverMenuButtonWith(label, .{ .placement, .open, .max_width }, style)` 另外给出：`placement`（`view.Placement`）让菜单像浮层一样附着在按钮的某一边与对齐方式上，放不下时翻转并夹在窗口内，从右到左时镜像；`open`（`*bool`）由应用持有菜单是否打开，应用把它设为 true 或 false 就打开或关闭菜单，用户打开或关闭菜单时它也随之更新；`max_width` 限制面板宽度；`panel`（`view.MenuPanel`）让菜单面板及其子菜单的面板换上应用自己的外观：`background`、`border`、`border_width`（0 为无边框）、`radius`、`padding` 与 `shadows`（同 `Style.shadows`；主题的菜单不画阴影），设了的字段取代主题的，菜单的位置、与按钮的间距和菜单项的画法不变：

```zig
const shadow = [_]view.BoxShadow{.{ .y = 18, .blur = 50, .color = .{ .r = 0, .g = 0, .b = 0, .a = 115 } }};
if (try v.popoverMenuButtonWith("更多", .{ .panel = .{ .background = 0x1e1e2e, .border = 0x45475a, .border_width = 1, .radius = 12, .shadows = &shadow } }, .{})) {
    _ = try v.menuItem("重命名", .{}, .{});
}
try v.end();
```
- `splitButton(label, options, style)` 是拆分按钮：一个按钮与一个打开相关操作菜单的箭头连成一个控件，如“保存”旁边的“另存为…”。前段按钮显示 `label` 并执行动作，后段箭头（从右到左时在起始边）像菜单按钮那样在整个控件下方打开菜单。返回 `SplitButton{ clicked, shown }`：`clicked` 是按钮被按下、Enter 或 Space 激活；`shown` 时构建菜单项，无论如何都用 `end` 关闭菜单。它是 Tab 的一站（按钮的，按钮禁用时是箭头的），Left 与 Right 在两段之间移动焦点（从右到左时反过来）；箭头上的 Down、Up、Enter、Space 和任一段上的 Alt+Down 打开菜单。`options.button_enabled = false` 只禁用按钮的动作，箭头仍能打开菜单；`Style.enabled = false` 禁用整个控件。`options.menu` 是菜单按钮的 `placement`、`open` 与 `max_width`。辅助技术看到以 `Style.name` 或 `label` 命名的分组，里面是按钮和打开菜单的菜单按钮；箭头以 `options.arrow_label` 命名，为空时按视图的语言取“More options”（英语、日语、简体与繁体中文，`menu.moreOptions(language)`），菜单显示时读作已展开。
- 没有外观的菜单，用于项的布局由应用决定的菜单，例如头像加名字或色块：`menuButtonBase(style)` 打开一个作为菜单按钮的容器，应用在其中构建按钮内容，`end` 后用 `popoverMenuBase(style)` 构建菜单；`popoverMenuBase` 跟在任意节点之后则是它的右键菜单，打开方式与 `popoverMenu` 相同。菜单面板只画 `style` 给出的背景、边框与圆角，没有默认的内边距和最小宽度。`menuItemBase(options, style)` 打开一个项容器（默认横排），由应用填充并在 `highlighted` 时自己画高亮，`end` 关闭；返回的 `MenuItemState` 带 `clicked`（选中，菜单随之关闭）与 `highlighted`。`options.checked` 与 `radio` 让它成为复选项或单选项，读屏报告选中与否；`shortcut` 作为描述朗读。`submenuItemBase(style)` 打开一个会展开子菜单的项，`end` 后用 `submenuBase(style)` 构建子菜单，子菜单以该项命名。项以 `Style.name` 或其中的文字命名，首字母跳转也用它。按键、焦点和语义与 `popoverMenuButton` 和 `popoverMenu` 完全相同；分隔线和小标题是应用自己放在项之间的节点。`menuGroupBase(style)` 在面板里打开一行由按键当作一站的项（`end` 关闭），例如账户菜单里“浅色、深色、跟随系统”三个 `keep_open` 单选项：Up、Down、Home 与 End 落在这一行时停在其中选中的项（没有则第一项），Left 与 Right 在行内循环移动（从右到左时反过来）；辅助技术看到一个以 `Style.name` 命名、包含这些项的分组。
- 右键菜单的位置相对锚点的整个盒子计算，所以锚点部分滚出视野时菜单仍在指针处打开。
- 焦点跟随高亮，辅助技术读出键盘所在的项；用指针打开时焦点在第一项上但不高亮。同一时间最多打开一个菜单；锚点不再构建或被禁用时菜单关闭。

启用 `-Daccessibility=true` 时，Windows UIA 把菜单映射为 Menu，把项映射为 MenuItem：普通项提供 Invoke，打开子菜单的项另提供 ExpandCollapse（展开即打开子菜单），复选项与单选项提供 Toggle。

### 提示、通知、导航按钮与头像

- `tooltip(text)` 给刚加入的节点（在组合框选项列表 `end` 之后则是组合框，在菜单或浮层 `end` 之后则是它们依附的节点）加提示。指针停在控件上或控件持有焦点超过提示延迟后，提示出现在控件下方（下方放不下时在上方），悬停优先于焦点。延迟取控件构建时所在主题的 `Theme.tooltip_delay`（纳秒）：0 表示用 `Options.tooltip_delay`（默认 600 ms），负数表示立即显示；所以用 `themed` 包住一个工具栏就能给它单独的延迟。一个提示消失后，在延迟的三分之二（默认 400 ms）内移到另一个有提示的控件会立即显示，像指针沿工具栏移动时那样。按下或 Escape 会隐藏它，直到指针或焦点移到另一个控件；窗口失去焦点时也会隐藏。在菜单或浮层（`popoverMenuButton`、`popoverMenu`、`popover`）的 `end` 之后调用时，提示加给它们依附的节点。节点的菜单、浮层或下拉列表显示时（无论由按下、Down/Enter/Space 还是右键打开），它的提示不显示；显示期间指针回到节点、关闭后焦点回到节点也不再显示，直到指针和焦点都离开它。提示文字同时作为控件的可访问说明（已有字段说明时保留字段说明）。没有前一个节点时返回 `NotContainer`。
- `view.Toasts(capacity)` 是应用持有的固定消息队列：`show(message, .{ .action, .duration })` 复制文本并返回 id，队列满时先移除最早的消息，文本过长返回 `TextTooLong`；`dismiss(id)` 移除一条。`toasts(&queue, style)` 把队列画成窗口底部居中的一叠消息，每条带可选的动作按钮和名为 "Dismiss" 的关闭按钮。时长从第一次显示的那一遍开始计算，0 表示一直显示；指针停在通知上或键盘焦点在通知里（窗口有键盘时）时，通知的时间暂停；窗口处于后台或隐藏时时间照走，因为通知讲的是会过时的消息（如托盘应用窗口隐藏时下载完成）：时间在此期间用完的消息在下一遍构建时直接移除，不会显示。动作按钮移除消息并让 `toasts` 返回它的 id 一次。每条消息是礼貌型（Polite）实时区域，出现时由读屏播报。
- `navButton(direction, style)` 是画着朝 `direction`（back/forward/up/down）的箭头的方形按钮，激活的那一遍返回 true；名称取 `Style.name`，默认是英文的 "Back"/"Forward"/"Up"/"Down"。
- `avatar(name, picture, style)` 显示 `picture`（`ImageView`，按 cover 裁剪）或 `name` 前两个词的首字母，圆底颜色取 `Style.background`，否则由名称稳定派生。默认 32 DIP 见方，不接收输入，作为以 `name` 命名的图像暴露。

### 时间与唤醒

每一遍都有一个时间，`View.time()` 读取，单位纳秒；默认来自 Host 第一次构建时启动的单调计时器，`Options.clock` 可以换成应用自己的时钟。构建函数可以调用 `wakeAt(deadline)` 要求在某一时刻再运行一遍，提示延迟和通知时长也用它。一遍中最早的请求生效，没有请求就不会再唤醒。构建之外（例如嵌入叶子收到数据时）用 `Host.wakeAt(deadline)` 预约一遍，它和构建中的请求一起取最早者，到期后清除；`Host.schedules()` 表示宿主是否有调度器。

看起来以较低帧率也同样平滑的动画（缓慢的波浪、电平表、转动的唱片）用 `animationFrameRate(fps)` 代替逐帧的 `wakeAt`：下一遍落在最少整数个显示刷新之后，且仍至少有 `fps` 帧每秒。按 `display_refresh_hz`（60）计算，帧率向上取到 60、30、20、15 等能整除的档位；`frameInterval(fps)` 给出对应间隔。同一帧率的请求落在同一条时间网格上，因此多个动画共用同一遍；窗口按所有请求中最快的那个绘制。0、负数或高于刷新率的帧率按每次刷新绘制。

Host 本身不持有计时器，只在 paint 之后投递一个任务，把最早的期限交给 `Host.setScheduler` 设置的调度器。`ziggurat_view_timer` 提供基于 `ziggurat_wake.OneShot` 的调度器：

```zig
const view_timer = @import("ziggurat_view_timer");

var timer = view_timer.Timer.init(&host);
try host.attach(window);
try timer.attach(app, allocator);
// 关闭窗口或 App 之前：
try timer.close();
```

它为最早期限装定一次性计时器，期限变化时取消旧的，到期后让窗口失效重绘。没有期限时不装定，空闲窗口不做任何工作，也没有持续重绘的计时器。没有调度器时，提示和通知仍然正确，只是要等下一次因其他原因发生的重绘才会更新。

工作线程的数据经 `App.post` 回到主线程。投递的任务本身不重绘：每次都 `Window.invalidate` 会让视图在每次投递后都重新构建一遍，不管状态是否变了。轮询很少变化的数据（连接数、状态）时，在任务里和应用状态比较，只有变了才 `invalidate`：

```zig
fn apply(ptr: *anyopaque) void {
    const update: *Update = @ptrCast(@alignCast(ptr));
    defer update.release();
    if (update.count != app.connections) {
        app.connections = update.count;
        app.window.invalidate();
    }
}
// 工作线程：
try app.post(.{ .context = update, .call = apply });
```

### 元素卸载

`v.onUnmount(.{ .context, .run })` 让刚加入的节点在消失时运行一次函数：不再构建它的第一帧之后、包着它的 `presentColumn` 退场结束之后，以及窗口关闭时（Host 在内容从窗口分离时，Harness 在 `close()` 时），都在主线程上。视图在这里停止它为这个节点开始的工作（流式请求、计时器、订阅），不必自己记录上一帧构建了什么：

```zig
try v.column(.{ .key = view.key(feed.url) });
try v.onUnmount(.{ .context = feed, .run = Feed.stop });
for (feed.lines()) |line| try v.text(line, .{});
try v.end();
```

每次调用替换函数，运行的是最后给出的那个；某一遍没有调用时保留之前给的，传 `null` 则取消且不运行。节点按 ID 认出，兄弟会变化的节点要给 `Style.key`。失败的帧不运行任何函数。函数可以改应用状态，需要重绘时自己 `Window.invalidate`。同时最多 `view.max_unmounts`（64）个节点持有函数，再多返回 `TooManyItems`。

## 文本测量

`Frame.label` 使用默认的 16px 单行字体。文本节点可以用 `Style.font` 换成其他字体变体：`Font` 包含 `size`（1–1024 DIP）、`weight`（`regular`/`medium`/`semibold`/`bold`）、`italic` 与 `monospace`，并提供预设 `.body`、`.heading1`–`.heading6` 与 `.code`：

```zig
try v.text("概览", .{ .font = view.Font.heading2 });
try v.text("zig build test", .{ .font = view.Font.code });
```

字体随文本命令一起录制（命令仍为 32 字节），GDI、Direct3D 11 与 Cairo/Pango 渲染器都按它选择字形；GDI 和 Direct3D 11 各自缓存最近使用的 8 个变体，不在常规绘制路径中重复创建。

`Options.measurer` 决定文本节点与控件标签的宽度。默认的 `Measurer.estimate` 是保守估计（窄字符 9 DIP，宽字符 16 DIP，行高 24），不调用原生字体；需要精确宽度时，应用可以提供基于 `ziggurat_text_layout` 的测量回调；`measure_font(context, text, font)`（可选）在节点带字体时调用。没有它时按字号相对 16 缩放 `measure` 的结果，等宽字体按每字符 0.6 em、非常规字重加宽 5% 估算。测量回调在 paint 中调用，应自行缓存，避免在常规绘制路径分配。

## 存储与容量

`view.Storage(nodes, text_bytes)` 是调用者拥有的固定存储，提供节点、文本副本、布局项与矩形缓冲。`text`、控件标签都会复制进存储，`textf` 直接格式化进存储，因此构建函数可以传入临时缓冲。超出容量返回 `TooManyNodes`、`TextFull`、`TooManyItems` 或 `NestingTooDeep`，容器不配对返回 `UnbalancedContainer`；绘制中的这些错误使本帧失败并保留上一帧。底层 Frame 的每帧上限（128 个控件、2048 条命令等）同样适用。

### 树与表格

两者都把选择交给应用持有的 `Selection`：它记录选中项的应用 ID（非零 `u64`，在集合内唯一），而不是位置，所以改名、排序或插入行都不会改变选择。`Selection.init(.single 或 .multiple, &storage)` 以调用者的缓冲为容量，`add` 超出容量返回 `SelectionFull`；`items()`、`contains`、`set`、`add`、`remove`、`clear` 可在构建之外直接调用。`anchor` 是 Shift 范围的起点，`cursor` 是焦点行，`version` 在每次改动时递增。

- `tree(&selection, style)` 与 `end` 配对开始一棵树。`treeItem(id, expanded, label, style)` 打开一个以 `id` 为键的条目并加入它的行，返回 Enter 激活这一行的那一遍；子条目在它和对应的 `end` 之间构建，层级由嵌套决定。`expanded` 为 null 表示叶子；非 null 时行首画三角，按下三角只切换展开而不选择。应用只在 `expanded.*` 为 true 时构建子条目。
- `table(columns, &sort, &selection, style)` 与 `end` 配对开始一个表格，先画一行列头，`Column` 给出标题、`Track`（默认 `fraction(1)`）和是否可排序。激活可排序的列头时 `sort` 变为该列升序，再次激活翻转方向；返回 true 的那一遍由应用按 `sort` 排列行。不可排序的列头不取焦点。`Style.gap` 是列间距，为 0 时取 8 DIP。
- `tableWith(columns, &sort, &selection, style, .{ .header_cell = .{ .context, .call } })` 是带更多选项的 `table`：`header_cell.call(context, v, column)` 在构建每个列头时调用，`column` 是传入列数组的下标，它构建的内容放在列头标题与排序箭头之后、与标题同一行（如列的类型标记），列头仍按列对齐、仍可点击排序。
- `tableRow(id, name, style)` 开始一行，`name` 是行的可访问名称（例如第一格），随后每列构建一个单元格，再 `end`。表头和所有行用同一组列宽：列宽在每次排列时由各列单元格（只计跨一列的）的最大内容尺寸统一求出，所以长文本不会让某一行错位。行放进 `scroll` 容器时表头保持不动。选中行以强调色填充，其中文本改用强调色上的前景色。
- 行共享一个 Tab 停靠点，落在 `cursor` 行。Up/Down 移动并单选，Home/End 到首尾，PageUp/PageDown 按可见行数翻页；Ctrl+方向键只移动 `cursor`，Space 单选、Ctrl+Space 切换、Shift+方向键或 Shift+Space 从 `anchor` 选到当前行，Ctrl+Shift 把范围加入已有选择，Ctrl+A 全选（多选时）。树里 Right 展开折叠的条目，已展开时进入第一个子条目；Left 折叠展开的条目，否则回到父条目。指针按下同理：Ctrl 切换、Shift 选范围、Ctrl+Shift 追加范围。移动后的行以最小位移滚入外层滚动容器。
- 行全部参与构建和排列，不做虚拟化；滚出可见区的行不绘制、也不登记命中（焦点行除外）。大量行请使用 `ziggurat_view_collections` 的[虚拟表格、大纲与网格视图](collections.md)，或 `ziggurat_ui` 的虚拟列表。`treeItem`、`tableRow` 在各自容器之外调用返回 `NotContainer`。

```zig
try v.tree(&selection, .{ .name = "文件" });
for (roots) |entry| {
    _ = try v.treeItem(entry.id, if (entry.branch) &open[entry.id] else null, entry.name, .{});
    if (entry.branch and open[entry.id]) try children(v, entry.id);
    try v.end();
}
try v.end();
```

启用 `-Daccessibility=true` 时，Windows UIA 把树映射为 Tree / Selection，条目为 TreeItem / SelectionItem / ExpandCollapse（叶子报告 LeafNode）；表格为 DataGrid / Selection，表头为 Header，列头为 HeaderItem / Invoke，排序方向放在 ItemStatus（"ascending" 或 "descending"），行为 DataItem / SelectionItem。多选集合报告 CanSelectMultiple，AddToSelection 与 RemoveFromSelection 只改动该项。

### 可编辑组合框与标记输入框

- `editableComboBox(value, style)` 与 `end` 配对，开始一个带边框的组合字段，其中放文本输入（通常是 `ziggurat_view_text` 的 `TextField`，用 `.frame = false` 去掉它自己的边框），`end` 时在末尾自动加入展开按钮。紧随其后的 `suggestions` 列表锚定在整个字段上。列表在输入获得焦点时不打开，在选项因输入变化时打开；Down、Alt+Down 或 F4 打开同一组选项，Alt+Up、F4 或 Escape 关闭；按钮切换打开状态而焦点留在输入里。选中后列表关闭，焦点回到输入。
- 输入法组合期间（`Embed.status` 报告 `composing`）列表隐藏，方向键、Enter 和 Escape 都留给输入法；组合结束后按选项是否变化恢复。
- `tokenField(style)` 与 `end` 配对，开始一个会换行的标记输入框，其中依次构建 `token(label, style)`（用 `Style.key` 保持身份）和最后的文本输入。`token` 在其移除按钮被按下、或标记有焦点时按 Backspace/Delete 的那一遍返回 true，应用在这个分支里删掉它；之后焦点回到输入。输入为空时 Backspace 或 Left 把焦点移到最后一个标记；标记之间用 Left/Right、Home/End 移动，越过最后一个回到输入。标记在可用宽度内按行排列，窗口变窄时自动换行。

`Embed.status(context)`（可选）报告嵌入输入是否正在组合、是否为空，供上面两种容器决定按键归属；`ziggurat_view_text` 的文本框已实现它。

启用 `-Daccessibility=true` 时，Windows UIA 把可编辑组合框映射为 ComboBox / ExpandCollapse，展开按钮为不取焦点的 Button；标记输入框为 List（LocalizedControlType 为 "token field"），标记为 ListItem（"token"），各带一个名为 "Remove" 的按钮。

### 对话框、警告对话框与表单页

- `dialog(&open, options, style)` 与 `end` 配对，开始一个浮在整个窗口上的对话框，返回 `DialogState`：`.open` 时构建内容，`.dismissed` 表示 Escape 或按下遮罩在这一遍把 `open` 清除，其余为 `.closed`；无论返回什么都要 `end`。`DialogOptions` 有 `role`（`.dialog` 或 `.alert`）、`position`（`.center` 居中，`.top` 贴着窗口顶边）、`dismiss_on_escape`、`dismiss_on_scrim`（警告对话框总是忽略）与 `description`。名称取 `Style.name`；内边距默认 16 DIP、间距 12 DIP；宽度在窗口有余地时至少为 `view.dialog_min_width`（320 DIP），并与窗口边缘保持 `view.dialog_margin`（24 DIP）。`sheet(&open, options, style)` 是 `position = .top` 的同一控件。
- 显示期间窗口其余部分画上半透明遮罩，并且不接收按下、按键和焦点：其中的命中区仍然遮挡指针但被禁用，语义节点报告为禁用，因此 Tab 与 Shift+Tab 只在对话框内循环；滚轮、悬停与按键绑定也只到达对话框内部。在遮罩上按下先关闭对话框里打开的列表或浮层，再按 `dismiss_on_scrim` 关闭对话框，按下本身不会传到下面。对话框外的浮层与通知仍会绘制，但同样不接收输入。
- 打开时焦点移到对话框中第一个可聚焦的控件；内容中调用 `v.initialFocus()` 可改为刚加入的节点。无论怎样关闭（Escape、遮罩、构建清除 `open`、或不再构建），焦点都回到打开时持有焦点的控件。对话框不能放在弹出列表、浮层或另一个对话框里（`NotContainer`），里面可以有组合框、建议列表、浮层与通知。同一时间只显示一个对话框，另一个尚在显示时打开新的返回 `Busy`。
- `alertDialog(&open, alert, style)` 是一个完整的警告对话框：标题、可选的消息和一行回应按钮。`Alert.default` 是打开时取得焦点的按钮，`Alert.cancel` 是 Escape 给出的回应（为 null 时 Escape 不起作用）；按下按钮或 Escape 清除 `open` 并返回该按钮的序号，其余时候返回 null。它自己 `end`，不需要再调用。

```zig
if (try v.button("删除…", .{})) confirm = true;
if (try v.alertDialog(&confirm, .{ .title = "删除文件？", .message = "此操作无法撤销。", .buttons = &.{ "取消", "删除" }, .default = 0, .cancel = 0 }, .{})) |answer| {
    if (answer == 1) try remove(current);
}
if (try v.dialog(&settings_open, .{ .description = "选择文件的打开方式" }, .{ .name = "设置" }) == .open) {
    _ = try v.checkbox(&prefs.autosave, "自动保存", .{});
    if (try v.button("完成", .{})) settings_open = false;
}
try v.end();
```

启用 `-Daccessibility=true` 时，Windows UIA 把对话框映射为报告 IsDialog 的 Pane，LocalizedControlType 为 "dialog" 或 "alert dialog"，名称与说明来自 `Style.name` 与 `description`。

### 侧边栏

- `sidebar(&selection, style)` 与 `end` 配对开始一个导航侧边栏，它就是一棵树：选择由应用持有的 `Selection`（通常为单选）按条目 ID 记录。`sidebarSection(id, title, expanded, style)` 加入一个分区标题，`expanded` 为 null 表示总是展开；返回 true 时在它之后构建条目，无论返回什么都要 `end`。`sidebarItem(id, label, options, style)` 加入一个条目，`SidebarItemOptions` 有 `icon`（`ImageView`，画在缩进之后、标签之前）与 `badge`（画在行尾的计数或短状态，并作为说明播报）；按下、方向键或 Enter 选中它的那一遍返回 true。标题和条目的 ID 在同一个侧边栏内唯一。
- 键盘沿用树的规则并有三点不同：Up/Down、Home/End 到达标题时只移动焦点行而不选中；Space 或 Enter 在标题上切换展开；字母或数字移到下一个（循环）标签以它开头的行。按下标题切换展开，Left 从条目回到所属标题，Right 展开标题。标题文字以弱化颜色绘制。
- 侧边栏没有默认背景，用 `Style.background` 或 `Style.material` 与内容区分；条目很多时放进 `scroll` 容器。

```zig
try v.sidebar(&selection, .{ .name = "位置", .width = 220, .background = 0xf4f6f8 });
if (try v.sidebarSection(1, "资料库", &library_open, .{})) {
    if (try v.sidebarItem(10, "收件箱", .{ .icon = inbox_icon, .badge = unread_text }, .{})) show(.inbox);
    if (try v.sidebarItem(11, "草稿", .{}, .{})) show(.drafts);
}
try v.end();
try v.end();
```

启用 `-Daccessibility=true` 时，Windows UIA 把侧边栏映射为 Tree / Selection，标题与条目都是 TreeItem，标题报告 ExpandCollapse。

### 可编辑文本

- `editableText(&state, value, input, options, style)` 平时显示 `value`，像按钮一样接收按下、Enter、Space 与 F2，开始编辑后由 `input`（通常是 `ziggurat_view_text` 的 `TextField` 的 `embed()`）取代并获得焦点。返回 `Edit`：`.begin` 时应用把当前文本载入输入，`.commit`（Enter 或焦点离开输入）时把输入的文本写回，`.cancel`（Escape）时保留原文本；其余时候返回 null。结束后焦点回到标签，除非它已经移到别处。
- `EditableText` 由应用持有并保持地址稳定。`EditableOptions` 有 `hint`（作为标签的提示和说明，例如 "按 Enter 或 F2 重命名"）与 `placeholder`（值为空时显示）。标签以 `value` 命名，`Style.name` 命名输入；兄弟节点会变化时给它 `Style.key`。
- 输入法组合期间 Enter 与 Escape 留给输入法，需要 `Embed.status` 报告 `composing`（`TextField` 已实现）。

启用 `-Daccessibility=true` 时，标签是以文字命名的 Button，输入是 TextField 自己的 Edit。

### 查找栏

- `findBar(&bar, input, matches, texts, style)` 在 `bar.open` 为 true 时显示一个名为 "Find" 的工具栏：查询输入（通常是 `TextField`）、当前位置（"2 of 7"，没有结果时显示 "No results"，输入为空时不显示）、上一个与下一个按钮（没有匹配时禁用）、"Match case" 与 "Whole word" 复选框和 "Done" 按钮。返回本遍的 `FindEvent`：`.opened`、`.next`、`.previous`、`.options`（`case_sensitive` 或 `whole_word` 变化，需要重新搜索）或 `.closed`；其余时候返回 null。
- 查询、搜索和匹配都由应用持有：`FindMatches` 给出 `count` 与 `current`，`step(forward)` 计算前进或后退（循环）后的序号。查询变化由应用从输入自己得知。输入里 Enter 前进、Shift+Enter 后退；整个窗口内 F3 与 Shift+F3 相同，栏关闭时 F3 打开它；栏内任一控件上的 Escape 或 "Done" 关闭它。打开时焦点移到输入，关闭后回到打开前的控件。位置变化时播报新的位置文字。`FindTexts` 提供所有可见文字，用于本地化。
- 与 `ziggurat_document_diff_view` 的查找对接时，`.next`/`.previous` 对应 `Options.direction` 的 `.next`/`.previous`，`case_sensitive` 对应 `Case.exact`，否则为 `.ascii_insensitive`；那里的查找没有整词选项，也不给出匹配总数，整词与计数由应用自行处理。

```zig
if (try v.findBar(&find, query_field.embed(), matches, .{}, .{ .key = 1 })) |event| switch (event) {
    .next, .previous => matches.current = matches.step(event == .next),
    .options, .opened => try research(),
    .closed => {},
};
```

### 三态复选框与复选框组

- `checkboxState(&state, label, style)` 绑定一个 `CheckState`（`unchecked`、`checked`、`mixed`）。部分选中画成短横线；激活时未选中或部分选中变为选中，选中变为未选中，返回 true。只有应用会设为 `mixed`。`CheckState.of(values)` 从一组布尔值求出状态。
- 没有外观的标签页、选项、选择框与树行，打开的都是由应用填充和绘制的容器（默认横排），以 `Style.name` 或其中的文字命名，保留内置控件的按键、焦点与语义：
  - `tabBase(T, &selected, option, style)` 放在 `tabs` 里，`listItemBase(T, &selected, option, style)` 放在 `listBox` 里，与 `tab`、`listItem` 一样选择 `option`，返回选择是否改变；方向键、Home 与 End 跳过 `enabled = false` 的项。
  - `selectBase(style)` 打开选择框的触发器，`end` 后用 `selectListBase(is_open, style)` 构建它的列表（只在返回 true 时构建选项，无论如何都要 `end`），列表只画 `style` 给出的背景、边框与圆角。按键与语义同 `comboBox`。`is_open` 不为 null 时由调用方持有是否打开：置位即打开、清零即关闭，用户按触发器、Escape、在外面按下或选中选项时视图把结果写回。`selectOptionBase(T, &selected, value, style)` 是其中的选项，返回 `OptionState{ changed, highlighted, selected }`，选中后列表关闭、焦点回到触发器；方向键跳过禁用的选项。
  - `noSuggestions(label, style)` 在建议列表或组合框列表里加入一行“无匹配”：输入有焦点时让列表保持打开，不接受高亮与按下，读作不可用的选项。
  - `treeItemBase(id, &expanded, style)` 打开树的一行（应用画缩进、展开箭头、图标与标题以及选中行的背景），`end` 关闭这一行，随后在 `expanded` 为真时构建子条目，再用一个 `end` 关闭条目。返回 `TreeRowState{ activated, selected, cursor, level }`；选择、按键（Up/Down 移动，Right/Left 展开与折叠）与语义同 `treeItem`，展开箭头由应用自己的控件翻转 `expanded`。
- `checkboxBase(&checked, style)` 与 `checkboxStateBase(&state, style)` 是没有外观的复选框：打开一个容器（默认横排），由应用按值画出自己的方框与标签，`end` 关闭。前者激活时切换布尔值；后者绑定 `CheckState`，与 `checkboxState` 一样按下（或焦点在其上时按 Space）把未选中或部分选中变为选中、把选中变为未选中，部分选中时读屏报告“部分选中”。二者都以 `Style.name` 或其中的文字命名，并画主题的焦点环。
- `checkboxGroup(label, items, style)` 构建一个总复选框，以及其下缩进 30 DIP 的 `CheckboxItem` 复选框（各绑定一个布尔值，可单独禁用）。总复选框的状态由子项派生：全部选中为选中，全部未选中为未选中，否则为部分选中；激活它时，除非所有启用的子项都已选中（此时全部取消），否则把它们全部选中。任何值变化时返回 true。

启用 `-Daccessibility=true` 时，部分选中的复选框在 UIA 上报告 ToggleState Indeterminate。

### 按键绑定

`bindKey(chord, window, action)` 把一个 `ui.widgets.Chord` 绑定到动作 id：`window` 为 false 时只在刚加入的节点持有焦点时生效，为 true 时在整个窗口生效。按下时以 `.action = action` 在单独的一遍交付，由构建用 `takeEvent(action)` 取走，先于任何控件看到这个键。焦点上的绑定优先于窗口绑定，先绑定的优先；打开的弹出列表先处理按键，焦点上的绑定先于浮层与对话框的 Escape。焦点输入正在组合时忽略，对话框显示时只有其中的绑定生效。绑定每一遍都要重新建立，每帧最多 `view.max_key_bindings`（32）个。`Chord.allow_repeat` 让按住时的自动重复也触发绑定；交付动作的那一遍里 `v.shortcutRepeated()` 告诉这次是不是自动重复，如同网页的 `KeyboardEvent.repeat`：按住时步进的动作接收每一次，切换类的只接收第一次按下。上面的可编辑文本和查找栏都用它实现。

### 路由与历史按钮

- `Router` 是一个窗口（或窗口一部分）的页面历史，像浏览器为一个标签页保存的那样。应用持有 Router 和它使用的 `RouteEntry` 数组，`Router.init(&entries, "/")` 之后保持地址稳定，不分配内存。位置是带可选查询的路径，例如 "/notes/42?tab=info"，最长 `view.max_location`（256）字节。
- `push(target)` 前往当前页之后的页并丢弃其后的历史；`target` 是绝对路径，或像网页链接那样相对当前页解析（"edit"、"../settings"、"?tab=info"），其中的 `.` 与 `..` 被消去，控制字符与 `#` 返回 `InvalidLocation`。前往当前位置什么也不做。`replace(target)` 原地替换当前页，Back 不会回到它。`back`、`forward` 与 `go(n)` 在历史中移动并停在两端，`canGoBack`/`canGoForward` 判断能否移动。历史满时丢弃最旧的条目。`location`、`path`、`query(name)` 与 `title` 读当前页，`entryAt(offset)` 读前后的条目，用于应用自己的历史菜单。
- `route(&router, style)` 与 `end` 配对构建当前页：一个按页键控的列，不同页的节点从不共享身份；路径相同、查询不同的位置是同一页，保留身份和焦点。默认 `grow = 1` 并横向拉伸。返回的 `Route` 用 `match(pattern)` 按模式区分路径：两条斜线之间的部分要么与路径相同，要么是 `{name}`（任一部分），末尾的 `{name...}` 取余下的路径（可以为空），尾部斜线无关紧要，各部分按原样比较，不解码转义。用 `{name...}` 匹配的页是一个布局：只在余下部分不同的页共享它的节点身份，因此布局内的侧栏或标签页保持状态。`param(name)` 与 `query(name)` 读出取值。`title(text)` 给页面命名：它是页面的可访问名称，显示时播报，并随历史条目保存（最长 96 字节，在字符边界截断）。在构建页面内容之前调用 `match`。
- 焦点在离开的页里时，前往另一页把焦点移入新页：移到该页上次显示时持有焦点的控件，否则移到它的第一个控件。焦点在页外时（例如用侧栏选择页面）焦点不动，改为播报新页的标题。
- Alt+Left 与 Alt+Right（从右到左时互换）、键盘的浏览器后退/前进键和鼠标的后退/前进侧键在持有焦点的路由中后退与前进，焦点不在任何路由中时作用于窗口中第一个构建的路由。到达历史两端时这些键留给其他控件。Backspace 不导航。
- `backButton(&router, style)` 与 `forwardButton(&router, style)` 加入名为 "Back"/"Forward"（`Style.name` 可覆盖）的导航按钮，在历史两端禁用，从右到左时箭头指向另一侧；移动历史的那一遍返回 true。

```zig
var entries: [32]view.RouteEntry = undefined;
var router = try view.Router.init(&entries, "/notes");

try v.toolbar(.{});
_ = try v.backButton(&router, .{});
_ = try v.forwardButton(&router, .{});
try v.end();
const page = try v.route(&router, .{});
if (page.match("/notes")) {
    page.title("全部笔记");
    for (notes) |note| if (try v.button(note.title, .{ .key = note.id })) try router.push(note.path);
} else if (page.match("/notes/{id}")) {
    page.title("笔记");
    try showNote(v, page.param("id"));
} else if (page.match("/settings/{section...}")) {
    page.title("设置");
    try settings(v, page.param("section"));
}
try v.end();
```

启用 `-Daccessibility=true` 时，页面是以标题命名的 Group，历史按钮是 Button。

### 图片、SVG 与图标

- `image(picture, options, style)` 显示一张已解码、准备并上传的位图（`ImageView`，见[图片](images.md)），自然尺寸是第 0 级的像素数作为 DIP；`svg(picture, options, style)` 显示一个按布局尺寸绘制的矢量图；`icon(which, options, style)` 显示内置图标集中的一个。它们都是不接收输入的叶子。`Style.width`/`height` 覆盖自然尺寸；图片与 SVG 在拥挤的行中可以缩到零，图标保持自身大小。
- `ImageOptions.fit` 决定图片如何填充盒子：`contain`（默认，保持比例放进盒子）、`cover`（保持比例盖满盒子，超出部分裁掉）、`fill`（拉伸到盒子）与 `none`（自身尺寸、居中并裁剪）。`alt` 是给可访问性客户端的替代文字，作为图片的名称；没有 `alt`，或设置 `decorative`，图片是装饰性的，不暴露给可访问性客户端。
- 图标在 24×24 网格上以 2 单位宽的圆头描边绘制，由 `Style.color` 着色，默认取主题文字色（禁用时为禁用文字色）。`IconOptions` 有 `name`（可访问名称；没有名称时是装饰性的，图标旁有标签时应命名按钮而不是图标）、`size`（默认 20 DIP）与 `mirror`（从右到左时是否镜像，null 时只镜像水平的 chevron 和箭头）。`view.Icon` 列出全部图标：chevron 与箭头的四个方向、close、check、plus、minus、search、menu、more_horizontal、more_vertical、settings、home、info、warning、error_circle、help、star、heart、trash、edit、copy、refresh、download、upload、external_link、folder、file、calendar、user、bell、lock、eye、filter、play、pause、light_bulb、report 与 stop。图标的路径数据由本项目绘制，`view.icons` 提供 `pathData()` 与 `directional()`。
- 绘制只读取绘制之前准备好的内容。SVG 与图标由应用提供的绘制器画出：`SvgPicture` 与 `IconPainter` 在 paint 中被调用，不能分配或准备；没有对应尺寸像素的绘制器什么也不画，在绘制之后准备。`ziggurat_view_graphics` 提供这两个绘制器：
  - `Icons.init(allocator, &host)` 为一个 Host 绘制图标，`host.view.icons = icons.painter()`（或在 `Options.icons` 中传入）。它把图标按物理像素尺寸、缩放与镜像准备成覆盖遮罩，最多保留 `max_icons`（16）个，最久未用的先被替换；遮罩与图片共享渲染器的驻留预算。
  - `SvgImage.init(allocator, &host, bytes, options)` 解析一个 SVG 文档，自然尺寸取根元素的 `width`/`height`，否则取 `viewBox`，否则为 24×24，`SvgOptions` 可覆盖。`picture()` 交给 `svg`。它以节点颜色作为 `currentColor`，按绘制的像素尺寸准备一张图片；尺寸或颜色变化后重新准备，失败的准备在尺寸或颜色再次变化前不重试。
  - 两者都在绘制发现缺少像素时投递一个任务，在主线程上准备并上传后重绘；未变化的视图绘制时不分配。`last_error` 记录第一个错误。在绘制之外、Context 分离之前调用 `deinit` 释放资源。

```zig
var icons = graphics.Icons.init(allocator, &host);
host.view.icons = icons.painter();
var logo = try graphics.SvgImage.init(allocator, &host, logo_bytes, .{});
defer logo.deinit();
defer icons.deinit();

try v.icon(.settings, .{}, .{ .color = 0x4a5568 });
try v.svg(logo.picture(), .{ .alt = "Ziggurat" }, .{ .height = 32 });
try v.image(photo.view(), .{ .fit = .cover, .alt = "封面" }, .{ .width = 120, .height = 80 });
```

启用 `-Daccessibility=true` 时，有名称的图片、SVG 与图标在 UIA 上是 Image。

### 视频

`ziggurat_view_video` 的 `Player` 播放视频，`player.show(v, options, style)` 像 `image` 显示位图那样布局、填充并命名当前画面（`ImageOptions` 的 `fit`、`alt` 与 `decorative` 照常生效，自然尺寸是画面的像素数作为 DIP）。播放器有两种来源：

- `ziggurat_video` 用系统自己的媒体框架打开视频文件和流：macOS 的 AVFoundation、Linux 的 GStreamer、浏览器的 video 元素。系统在能用硬件时用硬件解码，并同步播放声音；画面留在解码器放下的地方交给窗口的渲染器（见下文）。MP4/MOV 里的 H.264 与 AAC 在各处都能播放，HEVC、VP9、AV1 取决于系统是否有解码器，HLS 流在 macOS 与浏览器上可用。
- 应用内的解码器：`GifDecoder` 与 `ApngDecoder` 在所有系统上播放动画 GIF 与 PNG，没有声音，适合任何时候都不应依赖系统的背景；自己的 `Decoder` 播放其他格式。

```zig
const video = @import("ziggurat_view_video");
const system_video = @import("ziggurat_video");

const trailer_mp4 = @embedFile("trailer.mp4");
// 或 system_video.open(allocator, &host, path)、openUrl(allocator, &host, url)
var trailer = try system_video.openData(allocator, &host, trailer_mp4);
// 在 Context 分离之前、绘制之外：
defer trailer.deinit();

var decoder = try video.GifDecoder.init(allocator, waves_gif);
defer decoder.deinit();
var waves = try video.Player.init(allocator, &host, decoder.decoder());
waves.setLoop(true);
waves.setMuted(true);
defer waves.deinit();

// 构建中：
try waves.show(v, .{ .fit = .cover, .alt = "海浪" }, .{ .grow = 1, .self_align = .stretch });
try trailer.show(v, .{ .fit = .contain, .alt = "预告片" }, .{ .grow = 1, .self_align = .stretch });
if (try v.button(if (trailer.playing()) "暂停" else "播放", .{})) {
    if (trailer.playing()) trailer.pause() else trailer.play();
}
var at = @as(f64, @floatFromInt(trailer.position())) / std.time.ns_per_s;
const length = @as(f64, @floatFromInt(trailer.duration())) / std.time.ns_per_s;
if (try v.slider(&at, .{ .minimum = 0, .maximum = @max(length, 0.001), .step = 0.1 }, .{ .name = "进度" })) {
    trailer.seek(@intFromFloat(at * std.time.ns_per_s));
}
```

播放器：

- 播放器只创建一次（不要在构建中创建），保持地址稳定，同一时间只在一处显示。新播放器在第一次显示时开始播放。`pause` 停在当前画面，`play` 从停下处继续；播完后 `play` 从头再播。`playing()` 说明是否在播放，`ended()` 说明是否播到了结尾（停在最后一帧），`setLoop(true)` 让视频每次结束时无间隔地从头再播。`seek(ns)` 显示该时刻的画面并从那里继续（暂停时保持暂停）；`position()` 与 `duration()` 给出播放位置和长度（直播流为 0）。`setRate` 加快或放慢播放，声音保持音高；`setVolume` 与 `setMuted` 设置声音。`err()` 给出在结尾之前让视频停下的错误（文件无法解码、流中断），`last_error` 记录上传或投递失败。`close()` 停止播放和声音，视频停在当时的画面。播放器的方法都在主线程上调用。
- `Player.init` 立即解码 GIF 等解码器的第一帧，没有帧的视频返回 `error.EmptyVideo`。系统的视频立即打开、在后台加载：第一张画面到来之前 `ready()` 为 false、尺寸为 0×0；流等待数据时 `buffering()` 为 true，供视图显示加载指示。这些状态每次变化都会绘制一帧窗口，视图不需要轮询。
- 解码器的视频完全在主线程上进行：播放中的视频在构建时用 `wakeAt` 请求当前帧结束时的下一遍；发现帧已到期的那一遍投递一个任务，在绘制之后把下一帧解码进播放器的 `ui.PixelImage`、提交并重绘。窗口有一段时间没有绘制时，期间到期的帧会被解码后跳过，只显示最后一帧，视频跟着时钟走而不是越落越远（一次最多跳 `max_skipped` 帧）。解码器的 `seek` 从头解码到该帧。
- 系统的视频按它的声音所用的时钟走：每次构建窗口的一帧，播放器在绘制之后向引擎取该帧显示时到期的画面；画面到来时（GStreamer 的 appsink、浏览器的 `requestVideoFrameCallback`）或按视频的帧率（AVFoundation）再绘制下一帧：120 Hz 屏幕上的 24 fps 视频每秒只绘制 24 帧。
- 静音的视频是一幅画面，就像背景：它只在视图构建它且窗口有部分可见时前进；离开视图（例如切到别的标签页）或窗口被隐藏后，它停下，回来时从停下处继续，期间什么也不解码。系统要求减弱动态（`Preferences.reduce_motion`）时，它静止不动（解码器的显示第一帧）。有声音的视频在看不见时继续播放（如同浏览器标签页），减弱动态时也照常播放，因为是用户要求播放的；解码器的视频没有声音，总是前一种。
- 视频与图片一样默认是装饰性的；有 `alt` 时对可访问性客户端是名为它的 Image。

解码器：

- `GifDecoder` 解码动画 GIF：每帧画在前面各帧留下的画面之上，并按帧的处置方式（保留、清为透明背景、恢复为绘制前）处理，与浏览器一致；10 ms 及以下的帧显示 100 ms。循环与否只看 `setLoop`，不看 GIF 自带的循环次数。
- `ApngDecoder` 解码动画 PNG：每帧按处置方式（保留、清为透明、恢复为绘制前的画面）和混合方式（替换、叠加）画在前面各帧留下的画面上，与浏览器一致；10 ms 及以下的帧显示 100 ms，不是动画的 PNG 是只有一帧的视频。每一帧保持压缩，播放到它时才解码；`duration()` 给出动画总长。循环与否只看 `setLoop`，不看 PNG 自带的播放次数。解码在 `ziggurat_apng` 模块（`src/images/apng.zig`），PNG 本身由 `ziggurat_png` 解码，终端的 Kitty 图片也用它。
- 其他格式实现自己的 `Decoder`：`next(context, pixels)` 把下一帧以预乘 BGRA、自上而下的行写入 `width * height * 4` 字节并返回显示时长（纳秒，0 表示 100 ms），最后一帧之后返回 null；`rewind(context)` 回到第一帧之前；可选的 `duration` 给出总长，`duration()` 由它报告（GIF 与 APNG 的有）。
- 应用自己解码（例如用 FFmpeg）的直播流或视频不必走 `Decoder` 的 BGRA：把每帧的 Y′CbCr 平面交给 `ui.VideoImage.commitYuv(&host.context, frame)`，在构建里 `v.image(image.view().?, …)` 显示（见下文“应用自己的 YUV 画面”）。

应用自己的 YUV 画面：

`ui.YuvImage` 是一帧 4:2:0 的 Y′CbCr 画面，正如视频解码器给出的那样：`format` 为 `.nv12`（亮度一个平面，Cb 与 Cr 交织的色度一个平面，硬件解码器 VideoToolbox、Direct3D、VA-API 留下的样子）或 `.i420`（亮度、Cb、Cr 各一个平面，软件解码器如 FFmpeg 的 YUV420P）；`width`、`height` 是像素尺寸，色度宽高各为一半（向上取整）；`planes` 与 `strides` 是各平面及其行长（字节，可以比样本长，解码器会填充）；`matrix` 选 `.bt601`（标清与 JPEG）、`.bt709`（高清，多数流、摄像头与录屏）或 `.bt2020`（超高清，只用它的矩阵，HDR 按 SDR 的传递函数显示）；`full_range` 表示样本取满 0～255，而不是视频的 16～235（亮度）与 16～240（色度）。

```zig
// 在绘制之外，每来一帧：
try picture.commitYuv(&host.context, .{
    .format = .nv12, .width = 1920, .height = 1080,
    .planes = .{ luma, chroma, &.{} }, .strides = .{ luma_stride, chroma_stride, 0 },
    .matrix = .bt709,
});
if (host.context.window) |window| window.invalidate();
// 构建里：
if (picture.view()) |shown| try v.image(shown, .{ .fit = .contain }, .{ .grow = 1 });
```

GPU 渲染器上传这些平面（每像素 1.5 字节，BGRA 要 4 字节），在着色器里边采样边转换，CPU 不做任何转换，而转换本是显示一帧的大部分开销；软件渲染器和截图在绘制时才转换。NV12 的平面原样交给渲染器，不复制；I420 的 Cb 与 Cr 交织进图像自留的一个 NV12 色度平面（画面字节数的四分之一），这样渲染器和着色器只认一种平面布局。平面不复制，所以到下一次提交前保持不变（I420 的色度除外）。平面装不下画面时（尺寸为 0、行长短于样本、平面字节不够、NV12 色度行长为奇数、未知格式或矩阵）`commitYuv` panic，而不是让渲染器越界读；`YuvImage.check()` 先返回同样的判断供测试或校验。画面按自己的尺寸显示，由 GPU 在采样时缩放，不像缩小很多显示的图片那样生成减半的副本：解码器能给出显示尺寸的画面时就让它给。`zig build benchmark-video-frames -Dgpu=true -- [帧数]` 在真实窗口里每帧提交一张新的 1920×1080 画面并显示为 1280×720：CPU 转成 BGRA 再上传、NV12 平面、I420 平面三种，有限与全范围各一遍，每帧读回窗口中心并核对颜色（OpenGL 在 llvmpipe 上需 `ZIGGURAT_GL=on`）；Linux 的 llvmpipe 上 Debug 构建 NV12 约 20 ms 一帧，BGRA 约 240 ms。

系统视频（`ziggurat_video`）：

| 系统 | 框架 | 画面交给渲染器的形式 |
| --- | --- | --- |
| macOS | AVFoundation（`AVPlayer` 与 `AVPlayerItemVideoOutput`），用 VideoToolbox 解码 | IOSurface 支持的 NV12 `CVPixelBuffer`，Metal 用 `CVMetalTextureCache` 包成纹理，不复制 |
| Linux | GStreamer 1.x（`playbin` 与 `appsink`），装有 VA-API 时用它解码；首次打开视频时 dlopen | NV12 平面，每像素 1.5 字节，OpenGL 原样上传为 R8 与 RG8 纹理，由着色器转换 |
| Windows | Media Foundation（帧服务器模式的 `IMFMediaEngine`），在引擎自己的 Direct3D 11 设备上解码（GPU 有 DXVA 时用它），没有 GPU 时用 WARP | 引擎转换成 BGRA 的纹理，三张轮换，以 NT 句柄共享并由 keyed mutex（key 0）同步；Direct3D 11 在自己的设备上按纹理身份打开一次后直接采样。设备不能共享纹理时，每张画面读回内存 |
| 浏览器 | video 元素 | 元素本身，WebGL 从它 GPU 到 GPU 上传 |

- `open` 打开文件（浏览器里是相对页面的 URL），`openUrl` 打开 `file:`、`http:`、`https:` URL 或 HLS 播放列表，`openData` 打开内存中的字节（例如嵌入的文件）而不写入文件：macOS 经 `AVAssetResourceLoader` 从内存应答，Linux 经 memfd，Windows 经内存中的 `IMFByteStream`，浏览器经 Blob URL。字节在播放器关闭之前保持不变。
- `error.Unsupported` 表示系统没有能播放视频的框架，例如没有 GStreamer 及其 base 插件的 Linux，应用可以改为显示 GIF。能播放什么格式由系统决定。Linux 需要 `gstreamer1.0-plugins-base`，以及 `gstreamer1.0-libav`（或其他 H.264 解码器）才能播放 H.264；缺少解码器表现为 `err()`。
- 软件渲染器在绘制前把画面转换为 BGRA（macOS 锁定 `CVPixelBuffer` 读取平面，Windows 在引擎设备上把共享纹理复制到 staging 读回，浏览器经 canvas 读回）；OpenGL、Metal、Direct3D 11 与 WebGL 直接采样画面，NV12 按 BT.601/709/2020 矩阵与有限/全范围转换。没有应用导入 `ziggurat_video` 时不会链接其中任何部分。
- 浏览器不允许页面在用户交互之前播放声音时，视频改为静音播放。
- 测试用的片段 `test_clip`（1.2 s 红、绿、蓝）与示例的预告片由 `scripts/make-video-clips.sh` 用 ffmpeg 生成，H.264 不含 B 帧，因此没有编辑列表推迟画面时间。`zig build test-video` 用系统引擎在内存与文件两种来源上检查播放顺序、结尾与暂停时的跳转；`zig build smoke-video` 在真实窗口中检查软件渲染以及 `-Dgpu=true` 时 OpenGL、Metal 或 Direct3D 11（WARP，直接采样共享纹理）绘制的颜色。

示例 `zig build run-video` 在窗口上方循环播放一段 GIF（由 `scripts/make-waves-gif.py` 生成），“Watch the trailer”在它的位置播放带声音的预告片，带播放/暂停、进度条、静音与关闭。

### 从右到左布局

- `Options.direction`（`.ltr` 或 `.rtl`）给出视图的方向，通常来自应用的语言区域：`view.Direction.of(locale.direction())` 接受 `ziggurat_i18n` 的方向，视图模块本身不依赖它。`host.setDirection(value)` 改变方向并重绘；`currentDirection()` 在构建中读出根的方向。任何容器可以用 `Style.direction` 指定自己的方向，其中构建的节点继承它，例如在从右到左的界面中放一段从左到右的代码或数字。
- 从右到左时，除分栏以外的每个容器在常规布局之后把子节点沿自身边界镜像：行从右侧开始，列的起始对齐是右边缘，左右内边距互换，网格的列从右侧排列，标记输入框从右侧换行。坐标系不镜像：边界、指针位置与绘制中 x 仍向右增长。
- 文本从盒子右侧开始；弹出列表与锚点右边缘对齐，浮层交换起始与末尾对齐，滚动指示条移到左边缘；后退/前进导航按钮与方向性图标指向另一侧，Alt+Left/Alt+Right 的含义互换。标签页、分段控件、树与标记输入框中 Left/Right 按屏幕上的方向移动；空间方向键导航本来就跟随镜像后的边界。

```zig
var host = view.Host.init(&state, State.build, storage.buffers(), .{ .direction = view.Direction.of(localizer.direction()) });
try v.row(.{ .direction = .ltr });
try v.text("+1 555 0100", .{});
try v.end();
```

## 指针区域与指针形状

`pointerArea(options, style)` 与 `end` 配对，开始一个按列排列的指针区域，返回 `PointerArea`，描述这一遍时指针在它上面的情况，用于自绘控件、画布和需要右键菜单的行：

```zig
const row = try v.pointerArea(.{}, .{ .padding = Insets.all(8), .background = if (hovered) theme.palette.field else null, .cursor = .pointer });
try v.text(item.name, .{});
try v.end();
hovered = row.hovered;
if (row.double_clicked) self.open(item);
if (row.right_clicked) self.showMenu(item, row.bounds.?);
```

- `hovered`：指针在它上面且没有被打开的列表或浮层盖住（嵌套的区域同时悬停）；`position` 是悬停时相对 `bounds` 的指针位置；`pressed`：主键在它上面按下且指针仍在其上，`pressed_button` 是在它上面按住的键（主键、副键或中键，按下期间一直保留）。
- `pressed_inside`：这一遍的按下落在区域里，即使按下属于里面的控件或更内层的区域，也在按下之后构建的第一遍报告一次，例如单元格看到 Alt+按下而所在行照常选中。`press_canceled`：在它上面的按下在这一遍被取消（系统收走指针、窗口失去焦点），区域借此放下按下的样子，不会把它当作单击。
- `pointer`：悬停或按下时的指针样本 `z.PointerSample`：`device` 是鼠标、笔还是手指，`pressure` 是 0 到 1 的压力（没有压力的设备按下时为 0.5，否则为 0），画布用它画出粗细。Linux 从 GDK 的源设备与压力轴取得，macOS 从事件的子类型、压力与数位板事件取得，浏览器从 `PointerEvent.pointerType` 与 `pressure` 取得（只跟随主指针，按住一个键时按下另一个键作为和弦的按键变化送达，`pointercancel` 只取消而不算松开）；Windows 目前总报鼠标。`Window.pointerSample()` 给出窗口最近一次的样本。
- `clicked` 与 `clicks`：主键在它上面按下、又在它上面松开，`clicks` 是这次按下的连击数（同一区域上 500 ms 内、相距 4 DIP 内的按下依次计为 2、3……）；`double_clicked` 在第二次按下时报告；`right_clicked` 与 `middle_clicked` 分别是副键与中键的单击，同样在松开时计数。`pressed_now` 是这一遍按下的键，`modifiers` 是按下时的修饰键。
- 这些事件各自在单独的一遍交付，和控件返回 true 一样，应用在那一遍里处理；之后的绘制遍只保留 `hovered`、`pressed`、`position` 与 `bounds`。`bounds` 是上一次排列的窗口边界，第一帧之前为 null。
- 按下先交给控件：落在区域内按钮上的按下属于按钮，副键与中键在控件上也不交给区域。最内层的区域得到按下。窗口失去焦点或捕获被取消时按下作废，不计为单击。禁用的区域只报告 `bounds`。
- `AreaOptions.observe` 让区域只观察指针，不参与按下的路由：按下照常落到它里面的控件和其他区域上，它仍报告 `hovered` 与 `position`，并在里面的控件被按住期间报告 `pressed`，例如聊天行在按住其中的按钮时画出按下的样子。
- `AreaOptions.maximize_button` 把区域标成窗口的最大化按钮，给隐藏了系统按钮（`hide_window_buttons`）、自己画按钮的窗口用：Windows 11 上指针停在上面会弹出贴靠布局，与系统按钮一样（`Window.setMaximizeButton`）。区域照常接收指针，点击后由应用最大化窗口；每帧只有第一个这样的区域生效，其他平台忽略。
- `AreaOptions.drag_window` 把区域变成拖动窗口的把手，给自绘标题栏的窗口（`.custom` 或 `.borderless` 装饰）用：区域里没有控件的地方主键按下交给窗口（Host 在交付这次按下时调用 `Window.startMove`），区域不报告主键的按下与单击；双击做系统标题栏双击做的事（`Window.titleBarDoubleClick`：macOS 按“连按窗口标题栏以”缩放、最小化或不操作，Windows 与 Linux 最大化或还原，不可最大化的窗口不变）。把手的双击另有含义时（例如侧栏空白处双击新建一项），再设 `AreaOptions.window_double_click`：双击在 `PointerArea.window_double_clicked` 报告给应用，窗口不再缩放，单击仍拖动窗口（普通区域的 `double_clicked` 做不到这一点，因为它不拖窗口）。第三次连击重新拖动窗口。Harness 用 `window_moves` 与 `title_bar_double_clicks` 记下把手交给窗口的拖动与双击：

```zig
const side = try v.pointerArea(.{ .drag_window = true, .window_double_click = true }, .{ .grow = 1 });
// …侧栏内容…
try v.end();
if (side.window_double_clicked) self.newItem();
```
- 区域在指针进入和离开时重绘；`AreaOptions.track` 让它随指针移动重绘，使 `position` 跟随。每遍最多 `max_pointer_areas`（32）个区域参与路由。

`Style.cursor`（`view.Cursor`，即 `z.Cursor`）设置指针在节点及其后代上的形状，除箭头、文本、指针、移动、缩放与禁止等之外还有 `progress`、`wait`、`help`、`cell`、`zoom_in`、`zoom_out`、`all_scroll` 与 `no_drop`（Linux 与浏览器用 CSS 名字，macOS 用系统光标，没有对应的回退到相近的形状，Windows 用系统光标）。Host 从指针下最内层的节点向外找：第一个设置了形状的节点决定形状；先遇到没有设置形状的控件则显示默认箭头，因此按钮里不会出现外层的形状。链接默认显示 `pointer`，分栏的分隔条显示 `resize_ew`（左右排列）或 `resize_ns`（上下排列），`Embed.cursor` 回调让嵌入叶子按点回答（`ziggurat_view_text` 的文本字段显示 `text`，虚拟表格在列头右缘显示 `resize_ew`）。按下期间保持按下时的形状，松开后更新。Host 在指针移动、松开和每帧之后通过 `Window.setCursor` 设置，形状不变时不调用原生接口；Harness 用 `cursor()` 返回当前指针位置的形状。

`Style.hit_test`（`ui.HitTest{ context, func }`）让节点的控件只在应用给出的形状里接收指针：`func(context, x, y, box)` 收到指针位置与节点的盒子（都在控件录制时的坐标里，变换后的控件按变换反算），返回 true 时才算按在控件上，否则按下与悬停落到下面的内容。环形按钮只在环带上响应，饼图的扇区各管一块；路径可以用 `vector.Path.contains(allocator, point, rule, transform, tolerance)` 判断。它只作用于节点自己的控件，后代照常按盒子命中；嵌入叶子用 `Frame.setHitTest` 对它录制的控件设置同样的形状。

## 焦点与观察输入

- `v.focusWithin(id)` 告诉焦点是否在节点 `id` 本身或它里面（`:focus-within`），浮层、菜单和列表按它们锚定的节点算在里面；`v.focusLeft(id)` 在焦点刚从节点里离开（到了外面或窗口失去键盘）后构建的那一遍报告一次，例如表单在离开字段组时校验。焦点链来自上一遍的树，读过它们的帧在焦点移动后多构建一遍，使按焦点画出的样子随即更新。
- `v.focusTakesText()` 告诉焦点是否接收文本输入：嵌入叶子用 `Embed.takes_text` 回答，文本字段在可编辑时、富文本编辑器在非只读时、终端总是为真。单键快捷键用它让位，命令面板里字段在打字时不抢字母键。
- `observeInput(style)` 与 `end` 配对，开始一个观察其中输入但不拿走输入的列：焦点在它本身或里面时按下与松开的键（含按住重复）、输入的文本与输入法组合、编辑命令（`edit`：编辑菜单发出的复制、粘贴、撤销等，以对应的按键表示；键入的快捷键会先作为 `key_down` 出现），以及在它上面按下与松开的指针键，各自以 `Observed` 在单独的一遍先于正常路由送达（外层的先），之后输入照常交给持有焦点的控件、快捷键与 Tab；其他遍返回 null。演示在第一次按键时停下，面板在其中的字段被输入后隐去提示。移动焦点的键（如 Tab）的松开在焦点到达处观察到。`v.observing()` 告诉上一遍是否有这样的列。
- 构建或应用把焦点移到另一个节点时（`v.restore`、`initialFocus`、`focusLeaf`、`Host.focusNode`、`TextField.focus`），外层滚动容器在下一帧以最小位移把它滚入视野，如同网页的 `element.focus()`。只在焦点移动时滚一次：每一遍都给同一节点焦点不会打断用户的滚动，节点滚出视野失去焦点后再给它也不滚。按住指针键期间不滚（按下得到的焦点就在指针下，例如按住分隔条把手聚焦的那一行），过渡把焦点交还给延后出现的内容时也不滚。要换一种对齐方式，在给焦点的那一遍调用 `scrollIntoViewWith`，它优先。不在视野里的节点没有注册控件，这时它先滚入视野，下一帧注册后再拿到焦点。
- Tab 与 Shift+Tab 把焦点移到的控件同样以最小位移滚入视野。滚动视图里完全滚出视野的控件不在控件表里，Tab 也不会跳过它：按构建顺序下一个可以停留的控件（按钮、链接、复选框、开关、滑块、文本框、可聚焦的嵌入叶子等）在滚动视图里且看不见时，视图先把它滚入视野、再给它焦点（`View.tabBeyond`）；列表、树、标签、分段与单选组这类只占一站、站内用方向键的控件仍交给控件表。
- 延后出现的内容（`presentColumn` 的 `unseen` 阶段）里请求的焦点等内容出现后再给出，除非焦点期间已移到别处。打开列表或菜单并用方向键高亮条目时，提示跟随高亮项（aria-activedescendant），而不是持有焦点的输入框。

## 换行文本

`Style.wrap` 让文本节点按宽度换行：在空格之后、表意文字两侧和换行符处断行，比一行还宽的词在字符之间断开。`Style.max_lines` 限制显示的行数，被截断时最后一行以省略号结尾。最小宽度是最长的不可断开片段，首选宽度是不换行时最宽的一行；排列时先按单行排列，文本得到的宽度不够时以该宽度（列中取父容器的内宽）重新测量并再排列一次。行高取测量回调对空文本给出的高度，每行作为一个单行标签录制，从右到左时靠尾端对齐。`Style.truncate_middle` 把省略号放在最后一行的中间而不是末尾，像显示长路径的文件列表保留文件名：这一行保留尽可能多的开头和所在段落的结尾，省略号两边大致一样宽，字符保持完整；单行文本比盒子宽时也这样截断，最小宽度缩到省略号（换行时比一行还宽的词照常在字符之间断开）。段落本身放得下、只是后面的文字被截掉时，省略号仍在行尾。

`Style.balance` 让换行文本各行宽度接近，如 CSS 的 `text-wrap: balance`：保持按全宽换行时的行数，取仍能容下这些行的最窄宽度（按 0.25 DIP 二分），两行的标题从中间附近断开，而不是第二行只剩一个词。适合标题、说明和卡片标签这类短文本，需要 `wrap`；富文本的 `Options.balance` 相同。

`Style.letter_spacing` 在文本和链接的每个字符之后多留若干 DIP，如 CSS 的 `letter-spacing`：正数拉开，用于小号大写标签，负数收紧。设在容器上时里面的文本都继承，文本自己设的优先；0 去掉外层的间距，用于加宽间距的标签里的数字；null 取外层的。间距随 `Font.letter_spacing` 交给测量回调和文本命令，宽度、换行、截断与省略号都计入它，最后一个字符之后的间距也算在宽度里，与浏览器和 DirectWrite、Core Text 的测量一致；Pango 只在字符之间加间距，平台测量（`text_measure.Native`）替它补上末尾的那一份。默认的估算测量器按码点数加间距。

```zig
try v.column(.{ .letter_spacing = 2 });
try v.text("SPACED CAPITALS", .{ .font = .{ .size = 12, .weight = .bold } });
try v.text("4.2.1", .{ .letter_spacing = 0 });
try v.end();
```

## 上一帧的边界

`View.boundsOf(id)` 与 `Host.bounds(id)` 返回节点在上一次排列中的窗口边界，供绘制之外使用，例如把原生弹出菜单放在某个节点旁边；`lastNode().id` 给出刚加入节点的 ID。`Storage` 自带记录；自行组装 `Buffers` 时提供 `placed` 缓冲（与节点同容量），否则不记录。

## 应用按键

`v.keyDown(key)`、`v.codeDown(code)` 与 `v.keysDown()` 告诉窗口里此刻按住了哪些键，不论焦点在哪个控件、键是否被控件处理，也不会把键从控件那里拿走：快捷键速查表可以在搜索框持有焦点时点亮按住的键。读过它们的帧会在按住的键变化时重绘。键按快捷键的名字计，布局打不出 `z.KeyCode` 名字的键按位置计；修饰键看 `modifiers`。窗口失去键盘时放开所有键。

每个按键事件还带有 `KeyInput.code`（`z.KeyPosition`）：按物理位置命名的键，取 USB HID 用法、按网页 `KeyboardEvent.code` 的名字命名（`.key_a`、`.shift_left`、`.intl_ro` 等），与布局无关，Linux（evdev）、Windows（扫描码）、macOS（虚拟键码，含 flagsChanged 的左右修饰键）与浏览器（`KeyboardEvent.code`）都会上报。

`Options.keys` 是应用自己的按键处理：`key` 收到视图、按键绑定、嵌入叶子和控件（快捷键、Tab、方向键、Home/End、Enter/Space）都没有处理的按下，返回 true 表示已处理，随后运行一遍并重绘；`key_up` 收到持有焦点的嵌入叶子没有消费的每次松开（窗口有键盘时）。两者在主线程、绘制之外运行；焦点在文本字段中时按键交给文本字段。Harness 的 `key` 与 `keyUp` 按同样的顺序调用它们。

文本字段（`ziggurat_view_text`）的 `TextField.focus()` 把键盘焦点交给字段：字段已注册时立即生效，否则在注册它的帧之后生效；`Options.attached` 在字段首次注册到窗口后调用。`Host.focusNode(id)` 对任意节点做同样的事。围着输入的字段外框（`search` 区域、`editableComboBox` 与 `tokenField`）把交给它的焦点转给其中的输入，`v.restore`、`initialFocus` 与 Harness 的 `focus` 相同；`hasKeyboard` 对外框报告其中输入的焦点。

## 嵌入与文本输入

`embed(content, style)` 加入一个自己测量、放置和绘制的叶子，用于视图层不建模的内容。`Embed` 提供：

- `measure(context, theme)`：返回最小与首选尺寸，在排列时调用。
- `place(context, id, bounds)`（可选）：每个成功的帧排列后调用一次，告知稳定的节点 ID 和窗口坐标边界。它在 paint 内运行，不能准备、分配或阻塞，需要的工作要推迟到输入阶段。
- `paint(context, frame, id, bounds)`：在绘制顺序中的位置录制内容。
- `annotate(context, annotation)`（可选）：每次 `paint` 前调用，传入外层表单字段的标签、说明、错误与必填状态；不在字段内时传空值。规则与 `place` 相同。
- `status(context)`（可选）：返回 `EmbedStatus`（是否正在输入法组合、内容是否为空），在构建和路由按键时读取，不能分配或阻塞。
- `focusable`（默认 false）：以节点 ID 登记为 Tab 停靠点，叶子自己绘制的控件仍在它上面。
- `input(context, id, EmbedInput)`（可选）：叶子上的指针与按键输入，坐标相对叶子边界。`pointer_move` 与 `pointer_leave` 跟随指针（窗口失去焦点也算离开），`pointer_down` 是主键按下（`PointerPress` 带位置、修饰键和连击次数：同一叶子上 500 ms 内、相距 4 DIP 内的按下依次计为 2、3……），`wheel` 是叶子上的滚轮（DIP，正 y 向下；指针下的所有叶子从最后绘制的开始依次收到它，直到有一个消费，例如编辑器上方挡住按下的注释不消费时滚轮落到编辑器；都不消费时才交给外层滚动容器），`key` 是叶子持有焦点时其他控件都不处理的按键，`key_up` 是叶子持有焦点时松开的键（不论按下是否被它消费；窗口没有键盘时按下的键不会有松开）。返回 true 表示已消费并重绘窗口；消费按下的可聚焦叶子随即获得焦点。不消费的按键（例如 Tab）照常路由。它在主线程、绘制之外运行；被禁用、被裁剪遮住或位于打开的列表下面的叶子收不到输入，每帧最多 16 个叶子参与路由。
- `View.focusLeaf(id)` 在这一遍之后把键盘焦点交给可聚焦叶子 `id`（`place` 或 `paint` 得到的节点 ID），`View.hasKeyboard(id)` 表示该叶子持有焦点且窗口有键盘；游戏循环用它们在叶子出现时取得焦点、失去键盘时暂停。
- 消费 `pointer_down` 即捕获指针：直到松开，移动都以 `pointer_drag`（带起点、相对上一次的位移，以及是否已移出 `drag_threshold` 4 DIP）送到这个叶子，松开以 `pointer_up` 送达，指针离开叶子甚至窗口也一样。窗口失去焦点或原生捕获被取消时改为 `pointer_cancel`。下一次构建不再产生该叶子时捕获随之丢弃，之后不再调用它。

`Options.after_frame`（可选 `FrameHook{context, run}`）在 Host 每次成功绘制的帧末、所有叶子的 `place` 之后调用一次，规则同 `place`。跟随叶子放置的原生内容用它发现本帧没有构建的叶子，例如[视图中的 WebView](embedded-webview.md)。`Host.attachBackdrop(owner)` 代替 `attach(window)`，把 Host 作为 `composition.Owner` 的全窗背景，原生区域位于其上；Context 需使用 `.gdi` 渲染模式。

## 拖动与拖放

以下容器都按列排列，用 `end` 关闭；主键按下后移出 `drag_threshold`（4 DIP）才开始拖动，之前里面的按钮照常点击。拖动期间指针被捕获，移出窗口也继续跟随；松开结束，Escape、窗口失去焦点或捕获被取消则取消。滑块、分栏和接受按下的嵌入叶子保留自己的按下。

- `draggable(&gesture, style)` 是一个拖动区域。应用持有地址稳定的 `Gesture`；每个阶段（`start`、`move`、`end`、`cancel`）在自己的事件遍里更新它并返回该阶段，其他遍返回 null。`gesture.translation()` 是相对起点的位移，`delta` 是相对上一次事件的位移，`modifiers` 是按下时的修饰键。区域不再被构建时拖动丢失，之后第一次构建返回一次 `.cancel`。
- `dragSource(payload, style)` 在窗口内拖动一个 `Payload`（`kind` 像类型一样说明它是什么，`value` 说明是哪一个，例如条目 ID）。拖动时一份半透明副本跟随指针，返回 true 以便应用把原处画暗。`dragSourceState(payload, style)` 相同，返回 `DragSourceState{ dragging, missed }`：在没有接受它的目标处松开的那一遍，`missed` 是松开处的窗口坐标，例如把标签页拖到空处时开新窗口；Escape 与取消不算落空。
- `dropTarget(accept, style)` 接受 `Accept` 列出的内容：指定 `kind` 的 Payload，以及其他应用拖入的文件或文本。指针下最内层接受该内容的目标在拖动经过时描边并返回 `.over`，松开所在的那一遍返回 `.dropped`（`Dropped` 为 Payload、文件或文本，以及窗口坐标）。
- `reorder()` 在刚打开的表格、列表框或行/列容器上调用（要在加入任何条目之前），让指针把一项拖到其他项之间：副本跟随指针，一条线标出插入位置，松开所在的那一遍返回 `Move{from, to}`，表示原第 `from` 项移到原第 `to` 项之前（`to` 等于项数表示最后）；放回原处不产生移动，条目由应用重排。树不能重排；同一表格不能既 `reorder` 又 `dragSelect`。
- `dragRows(kind)` 同样在刚打开的表格、列表框或行/列容器上调用（要在加入任何条目之前），让条目被拖出容器交给别处（返回 `?DragMiss`：在没有目标处松开的那一遍给出载荷与窗口坐标）：按下条目移动超过阈值后拖动 `Payload{ .kind = kind, .value = i }`（`i` 是条目在容器里的序号，表格从第一行数起），副本跟随指针，指针下最内层接受该 `kind` 的 `dropTarget` 在松开时收到它，和 `dragSource` 一样。容器本身什么都不收，也不在条目之间画插入线，因此容器里的目标（比如文件列表里文件夹那一行）或容器外的目标都能在指针所在处收到。比如文件浏览器把文件拖进文件夹行。表格（带多选 `Selection`）里按下已选中的行时，拖动的是全部选中行：载荷仍是按下的那一行，应用在自己的 `Selection` 里找到其余行，指针旁用强调色小圆角标显示行数（`View.dragBadge()`）；没有修饰键按下已选中的行要等松开才只选中它，所以拖动保留选择。嵌入叶子（如虚拟表格）可通过 `Embed.drag` 在拖动超过阈值后返回 `EmbedDrag{payload, count, ghost, label}`，把拖动交给视图：叶子收到 `pointer_cancel`，之后与 `dragSource` 一样投放。树不能拖出行；同一容器不能既 `dragRows` 又 `reorder` 或 `dragSelect`。
- `dragSelect()` 在刚打开的树或表格上调用，让从一行开始的主键拖动像 Shift 加按下那样选中从该行到指针下一行的范围；按下时按住 Ctrl 则把范围加入已有选择。

拖动经过或越过外层滚动容器的边缘 32 DIP 内时，`reorder`、`dragRows`、`dragSource` 与 `dragSelect` 随指针移动滚动它，越靠近边缘越快。每帧最多 32 个拖动区域/拖动源/放置目标、4 个可重排或可拖出条目的容器和 256 个这样的条目参与路由。

其他应用拖入的文件和文本经由 `ziggurat_system` 的放置目标转交：

```zig
fn hover(ptr: *anyopaque, _: z.Window, h: drop.Hover) bool {
    const host: *view.Host = @ptrCast(@alignCast(ptr));
    return host.systemDragOver(if (h.phase == .leave) null else .{ .x = h.point.x, .y = h.point.y }, h.files, h.text);
}
fn dropped(ptr: *anyopaque, _: z.Window, d: drop.Drop) void {
    const host: *view.Host = @ptrCast(@alignCast(ptr));
    const data: view.Dropped = switch (d.payload) {
        .files => |paths| .{ .files = paths },
        .text => |text| .{ .text = text },
        else => return,
    };
    _ = host.systemDrop(.{ .x = d.point.x, .y = d.point.y }, data);
}
```

`systemDragOver` 返回该点是否有目标接受所提供的内容；`systemDrop` 把数据在一遍内交给那里的目标，字节只在该遍中借用。窗口内拖动只在本窗口内进行；视图尚未接入 `system.drag.Source` 的原生拖出。

叶子的状态变化需要告诉辅助技术时，调用 `host.announce(text)`（或在构建中调用 `View.announce`）：文字作为一个没有可见内容的状态节点礼貌播报，每次调用都是新的状态，超过 256 字节时在字符边界截断。

`ziggurat_view_text` 用它提供可编辑文本字段。应用持有 `ziggurat_document_editor.Field` 及其 Document 和 Engine，并在 Host attach 后调用一次 `host.context.prepareTextFields(allocator, .{})`：

```zig
const text = @import("ziggurat_view_text");

var field = text.TextField.init(editor, &host, .{ .font = .{ .size = 16 } }, .{ .name = "名称" });
// 在构建函数中：
try v.embed(field.embed(), .{ .grow = 1, .key = 7 });
```

字段的边界变化时（第一次出现、窗口尺寸或布局改变），`place` 只记录新边界并向 App 投递一个任务；该任务在绘制之外调用 `Field.prepare`，第一次还会以节点 ID `attach` 到 Host 的 Context，然后使窗口失效。在准备完成之前，字段沿用上一次准备时的位置绘制，因此焦点和命中与文本保持一致，最多滞后一帧。键盘、输入法、剪贴板、焦点切换和 text_box 语义都由 Field 与 Context 处理，视图层不转发这些输入。

放在 `field` 里时，文本框把字段的帮助或错误作为说明，错误时标为无效，`Options.name` 为空时用字段标签作为名称。

`Options.placeholder` 是输入为空且没有输入法组合时显示的文字（例如“搜索”），为空时取外层 `search`、`tokenField` 或 `editableComboBox` 的 `Style.placeholder`；没有名称和字段标签时它也作为文本框的可访问名称。`placeholder_color` 是它的颜色，默认是主题的弱化文字色，只影响绘制，不改变输入的文字与主题。`Options.caret_width` 以 DIP 设定光标宽度，按设备像素取整、至少一个像素，用于块状光标、大字号主题或演示；0 或负数隐藏光标而字段仍可编辑。它只影响绘制，布局、输入法候选位置和闪烁不变；为 null 时沿用 `colors.caret_style` 或平台的一像素光标。`Options.max_length` 像 HTML 的 `maxlength` 那样限制用户能让文字达到的长度（UTF-16 码元）：键入、粘贴或输入法提交的文字截到光标处放得下的部分，放不下的按键什么也不改；应用设置的文字不截断，0 不限制，null 沿用 Field 自己的 `max_length`。`setMaxLength(n)` 之后改变它。

TextField 与 Field 的地址必须保持稳定。节点 ID 用于注册，所以当前面的兄弟节点可能变化时要给它 `Style.key`；ID 改变会记录 `TextFieldIdChanged` 而不是静默重新注册。关闭时先调用 `field.detach()` 停止推迟的工作，再按 Field 的规则 `close`。投递或准备的失败记录在 `last_error`。

## 无窗口测试

`view.Harness` 不创建窗口，直接运行与 Host 相同的构建、排列和事件遍。测试用它按查询找控件、模拟激活，再检查应用状态和视图树：

```zig
var storage: view.Storage(64, 2048) = .{};
var counter: Counter = .{};
var h = view.Harness.init(&counter, Counter.build, storage.buffers(), .{});
try h.render();
try h.click(.{ .text = "加一" });
try std.testing.expectEqual(@as(i64, 1), counter.count);
try h.change(.{ .kind = .slider }, .{ .steps = 2 });
```

- `Query` 按 `kind`、精确的 `text`（标签或文本内容）、`name`（`Style.name`）和 `key` 匹配，所有给出的字段都必须相符。匹配多于一个返回 `Ambiguous`，用 `nth` 按构建顺序选其中之一；没有匹配返回 `NotFound`。`find` 返回节点，`count` 返回匹配数。
- `click` 只接受按钮、链接、复选框、开关、单选、分段、标签和折叠区；`change` 只接受滑块、步进器和分栏，`ValueChange` 与原生输入相同；`scroll(query, delta)` 只接受滚动容器，`wheel(x, y, delta)` 像 Host 一样把滚轮交给该点最内层的可见滚动容器。目标禁用返回 `Disabled`，被自身尺寸或任一裁剪祖先完全遮住返回 `Hidden`，位于显示中的对话框之外返回 `Inert`，种类不符返回 `NotActivatable` 或 `NotAdjustable`。
- `click`、`clickWith` 与 `rightClick(query)` 在发送任何输入之前，像指针那样检查匹配到的元素：窗口里看不到它的任何部分（自身尺寸、裁剪祖先、裁剪内缩或窗口边界）返回 `Hidden`；它可见部分的中心（`clickWith` 是按下的那一点，行的右端）会落到另一个控件、嵌入叶子、打开的菜单或弹出层、浮层的面板上，或落在不接收按下的地方（例如 `ignore_input` 的节点）返回 `Covered`。它们不会把目标滚动到视野里，也不另找未被遮挡的点；`find` 仍返回这样的元素（`visible` 可能为 null），`clickAt` 仍在给定的坐标按下，不检查目标。按 `text` 等查询匹配到多个元素而没有给 `nth` 时（例如一段文字和它唯一的行内链接同名），它们逐个按真实的输入目标检查候选，用按下能到达的那一个；能到达的不止一个返回 `Ambiguous`，一个都到达不了返回第一个候选的错误，都不发送输入。`rightClick` 还要求那一点打开的上下文菜单是元素自己的，或包住它的最近元素的，然后像 `clickButtonAt(…, .secondary, …)` 一样发送次键点击并返回是否有菜单或指针区域接收；元素自己没有菜单、而那一点打开的菜单的锚点在它里面时也接受，例如右键点到行里的内容列，打开的是行的菜单。
- 事件遍若没有控件消费该事件（构建已不再产生这个节点），返回 `Stale`，不会静默忽略。成功的事件之后自动重新渲染，节点与 `frames` 反映新状态。
- `at(x, y)` 返回该点最后绘制的可交互节点，尊重裁剪；`clickAt` 激活它。`visible(node)` 给出裁剪后的可见矩形，`view.divider(node)` 给出分栏的分隔条矩形。
- `write(writer)` 输出缩进的树大纲（种类、文本、名称、选中或数值、禁用、取整后的边界），适合与期望文本比较。
- `Config` 提供窗口边界、主题、`Options`（根样式与测量回调）和初始 `preferences`（第一帧就在减弱动态、粗指针等偏好下构建），`resize` 改变边界并重新渲染，`setPreferences(value)` 改变偏好并重新渲染。`key`、`keyUp`、`typeText`、`press` 与 `release` 和 Host 一样先经过 `observeInput` 的观察遍。
- 树和表格的行：`click` 按下行的右端并单选，`clickWith(query, modifiers)` 带 Ctrl/Shift 按下，`toggleExpanded(query)` 按下树行的三角；`removeToken(query)` 按下标记的移除按钮。`click` 也接受列头、标记和组合框的展开按钮。`write` 的大纲带出行的层级、展开、选中与焦点行，以及列头的排序方向。

- `attachInput(&context)` 把之后每次渲染记录进一个未连接窗口的 `ui.Context`，`key(KeyInput)` 按窗口相同的顺序路由按键：快捷键、Tab、范围键、分组方向键、空间方向键、Home/End，最后是 Enter/Space 激活。产生的动作或数值变化交给构建函数，随后重新渲染；返回值表示是否有控件处理该键。`focused()` 返回当前焦点节点。`keyUp(KeyInput)` 把松开交给持有焦点的嵌入叶子，`windowFocus(bool)` 模拟窗口得到或失去键盘，`windowHidden(bool)` 模拟窗口被隐藏（最小化）或重新显示。Context 由测试持有，不能已连接窗口。

```zig
var context = ui.Context.init(&dummy, draw, action);
try h.attachInput(&context);
_ = try h.key(.{ .key = .tab });
_ = try h.key(.{ .key = .down });
try std.testing.expectEqualStrings("Sans", h.focused().?.text);
```

- 时间与浮层：`advance(ns)` 推进测试时钟并重新渲染，`deadline()` 返回上一遍请求的唤醒时刻；`hover(query)`、`hoverAt(x, y)` 与 `leave()` 移动或移走指针，`tooltip()` 返回当前显示的提示文字；`focus(query)` 直接给节点焦点。`key` 先把按键交给打开的列表、按键绑定、对话框或显示的提示，`clickAt` 先让按下经过列表、对话框遮罩与提示的处理，`at` 先查浮在上面的列表、对话框和通知，并跳过对话框之外的节点。渲染遍要求的焦点（例如刚打开的对话框里的第一个控件）在渲染后给出，与 Host 在绘制后给出相同。`click` 也接受可编辑文本的标签。`write` 的大纲带出对话框的打开/关闭、复选框的部分选中，以及侧边栏的标题与徽标。`write` 的大纲带出列表的打开/关闭、高亮项与提示文字。

- 路由与方向：`mouseButton(.back)` 与 `mouseButton(.forward)` 像鼠标侧键那样在历史中移动，返回是否被处理；`setDirection(value)` 改变方向并重新渲染。`write` 的大纲为图片与 SVG 带出填充方式，为镜像的图标带出 `mirrored`。

- 指针：`usePointer(device, pressure)` 设定之后按下、移动与松开的指针样本（如笔与 0.6 的压力）；`press(x, y, modifiers)`、`moveTo(x, y)`、`release(x, y)` 与 `cancelPointer()` 按 Host 相同的捕获规则重放一次按下，`drag(from_x, from_y, to_x, to_y, steps)` 把它们连起来；`systemDragOver(point, files, text)` 与 `systemDrop(point, data)` 模拟其他应用的拖放。

- 像素：`image(surface)` 把上一遍渲染按窗口的样子画出来（背景 `Options.background` 或主题背景，加上视图绘制的内容，打开时还有 inspector），由 `ui.offscreen.Surface` 按它的尺寸和缩放画成一张图片，用于截图比对和像素检查；需要 `attachInput`，返回的 `Snapshot` 由调用方关闭。离屏表面需要应用的主线程（`z.App`），所以它用在 smoke 与工具里，而不是单元测试中；`smoke-view` 用它检查面板与背景的颜色。

带 `input` 的嵌入叶子在 Harness 中同样收到 `hoverAt`/`leave`、`clickAt`、上面的指针、`wheel` 与 `key` 的输入，`announcement()` 返回最近的播报文字。除此之外，Harness 把嵌入叶子当作不可交互的节点，不验证原生命中、文本输入、可访问性或原生捕获；这些仍由隐藏窗口 smoke 和原生检查覆盖。

`h.recordSemantics(&context)` 让之后每次渲染都像窗口一样记录可访问性树（需要 `-Daccessibility=true` 构建，否则跳过测试），`h.accessible(query)` 或 `h.accessibleId(id)` 读出辅助技术会得到的内容：`role()`、`name()`、`value()`、`description()`、`roleDescription()`、`keyShortcuts()`、`valueText()`、`parent()`，以及 `entry` 里的各状态（`enabled`、`focusable_disabled`、`focused`、`checked`、`expanded`、`selected`、`busy`、`current`、`popup`、`level`、`controls`、`invalid`、`search`、`vertical`/`horizontal`、`position`/`set_size`、`row_count`/`column_count`/`row_index`/`column_index`、`described_by`、`error_message` 等）。`h.clipboard()` 给出 Harness 自己的剪贴板（`ui.editor.Clipboard`），测试把它交给要复制或粘贴的控件（文本框的 `clipboard`、检查器、终端等）代替系统剪贴板：`h.clipboardText()` 读出最后写入的文字，`h.setClipboardText(text)` 模拟别的应用复制，`h.failClipboard(err)` 让之后的写入失败并返回 `err`（如系统拒绝），传 null 恢复。`h.accessibleAll(&buffer)` 按记录顺序（绘制顺序，父节点在子节点之前）列出除窗口根之外的全部语义节点，返回写入的部分，缓冲区放不下时返回 `NoSpaceLeft`。`editCommand(EditKey)` 像编辑菜单那样发送一条编辑命令，让 `observeInput` 的列看到它。`codeDown` 与 `codeUp` 按位置按下与放开键。

## 背景效果

`Style.material` 是一个 `ui.Material`，代替 `background` 画在容器的边框和子节点之下：玻璃、对下方内容的模糊、滚动边缘，或自己绘制的 `custom` 材质，形状取 `Style.radius`。`Style.edges` 在裁剪容器（例如滚动容器）的顶部和/或底部画滚动边缘，带高 `height`（默认 24 DIP），在子节点之上、裁剪之内：

```zig
try v.row(.{ .padding = Insets.all(12), .radius = 16, .material = .{ .glass = .{ .tint = .{ .r = 40, .g = 110, .b = 200, .a = 60 } } } });
try v.text("在玻璃上", .{});
try v.end();
try v.scroll(&model, .{ .grow = 1, .edges = .{ .top = .{}, .bottom = .{ .hard = true } } });
```

效果需要 `host.prepareBackdropEffects(allocator, .{})`（在 `attach` 之后），否则画不透明填充。效果的像素模型、预算和后端行为见[背景效果与加载动画](backdrop-effects.md)。

`custom` 材质是一段绘制代码：`paint(context, frame, box, radius)` 在 `box`（帧的 DIP 坐标）上用 `ui.Frame` 能画的任何东西填充，例如渐变、背景效果或背景着色器；`context` 要比画它的每一帧都活得久。组件包可以这样提供自己的材质：

```zig
const Stripes = struct {
    color: ui.Color,
    fn paint(context: ?*const anyopaque, frame: *ui.Frame, box: ui.Rect, radius: f32) anyerror!void {
        const self: *const @This() = @ptrCast(@alignCast(context.?));
        frame.roundedRect(box, radius, self.color);
        frame.roundedRect(.{ .x = box.x, .y = box.y, .width = box.width, .height = box.height / 2 }, 0, self.color.withAlpha(0.5));
    }
};
const stripes: Stripes = .{ .color = ui.Color.oklch(0.7, 0.15, 250) };
try v.row(.{ .radius = 12, .material = .{ .custom = .{ .context = &stripes, .paint = Stripes.paint, .name = "stripes" } } });
```

不经过视图时，`frame.material(bounds, radius, value)` 画同样的材质。

### 交互玻璃与玻璃组

交互玻璃像 AppKit 的 interactive glass 一样：指针悬停时边光变亮、表面略微提亮、着色加深（120 ms 内），按下时玻璃左右各长 1.1 DIP、上下各长 0.45 DIP（150 ms 内）。`ui.backdrop_effects.Glass` 的 `hover`、`press`（0–1）就是这两个量；`view.GlassInteraction` 由应用放在稳定地址，跟随玻璃上的指针区域计算它们，动画进行中自动请求下一帧，减少动态效果时直接到位：

```zig
var state: view.GlassInteraction = .{};
const area = try v.pointerArea(.{}, .{ .radius = 20, .padding = Insets.all(10), .material = .{ .glass = try state.glass(v, .{}) } });
try v.text("Glass", .{});
try v.end();
try state.follow(v, area);
```

`glass` 取本轮的悬停与按下量，`follow` 把它们对准指针区域本轮的状态，下一轮显示。

`Style.glass_group` 让容器里标了 `glass_pane` 的节点（最多 8 个）共用一片玻璃，像 AppKit 的 glass effect container：靠得近的面板边角融合成一个表面，分开时各自成形，整片只有一圈弧面与边光。面板保留自己的背景、边框和命中区域：

```zig
try v.row(.{ .gap = 6, .glass_group = .{ .radius = 20, .merge = 24 } });
_ = try v.button("Cut", .{ .glass_pane = true });
_ = try v.button("Copy", .{ .glass_pane = true });
try v.end();
```

`merge`（默认 24 DIP）是平滑最小值的宽度，大约能把相距 12 DIP 以内的面板连起来，0 让它们保持分开；`style`、`tint`、`clarity` 同玻璃，材质取最小面板那么大的玻璃。它是 `ui.effects.Library.glassGroup` 的背景着色器（符号距离场的平滑并集，5×5 采样模糊、弧面折射、亮度映射、着色与上下边光），需要 `host.prepareShaderEffects`；在此之前以及减少透明度时，每个面板各自画成普通玻璃材质（减少透明度时是不透明表面）。

## 不透明度、位姿与进出场

`Style.opacity`（0–1）把节点及其后代作为一层淡出，如 CSS 的组不透明度：重叠的子节点、子节点与容器自己的背景不会互相透出。为了少一次合成，作用域先平着录制、把透明度乘到每个绘制物上，关闭时检查其中的绘制物在裁剪内是否互相重叠，重叠时才改成一个按该透明度合成的组（`Frame.pushOpacity` 同样如此），互不重叠时两者画出来完全一样。含背景模糊的作用域保持平铺，组的嵌套深度超出渲染器的层数时也保持平铺；`Style.pose`（`ui.effects.Pose`）平移、缩放、旋转或按透视绕 X/Y 轴转动它们；`Style.effect` 用自定义着色器改写它们的绘制；`Style.refraction` 在容器下方画玻璃折射。命中、焦点和语义保持排布后的盒子。`View.presentColumn(&presence, show, transition, style)` 让一个列容器在 `show` 切换时按 `ziggurat_animation` 的运动进入和退出，退出结束后返回 false：

```zig
try host.prepareShaderEffects(allocator, library, .{}); // attach 之后
if (try v.presentColumn(&state.panel, state.open, .{ .hidden = .{ .y = 12, .scale_x = 0.96, .scale_y = 0.96 } }, .{ .padding = Insets.all(12) })) {
    try v.text("详情", .{});
    try v.end();
}
```

`Style.blur` 把节点及其后代作为一层按高斯模糊（标准差，DIP），画出的内容最多越过盒子三倍标准差。`Pose` 的 `x_percent`、`y_percent` 按节点自身宽高的百分比平移，如 CSS 的 `translate(-50%, -50%)`，随尺寸变化跟随。

`Transition` 的 `hidden`、`hidden_opacity` 与 `hidden_blur` 是内容不显示时的位姿、不透明度与模糊，它在这些与自己的样式之间移动；模糊与 `Style.blur` 按高斯叠加。`exit_to`（`Away`：位姿、不透明度、模糊）是离开时去往的地方，为空时回到 `hidden`。离开的方向在内容开始离开的那一遍固定，之后的构建改变方向也不会让已在离开途中的内容转向；所在容器的 `Style.child_exit` 在那一遍代替 `exit_to`，像向导、日历或轮播后退时，离开的页按这一步的方向离开，尽管它是在前进时构建的。`after_exits` 让内容一次一个出现：同一容器里还有内容在离开时，新内容先在布局中占好位置但不绘制、不接收输入，离开的内容消失后再按 `enter` 进入；它第一次出现时也等一帧，以便得知同一遍里开始离开的兄弟；在出现之前就被移除时什么也不留下。退出期间内容不接收指针与键盘，也不进入可访问性树。`delay_ns` 是进入前等待的时长（纳秒），如列表的行一个接一个进来、每行的延迟更长；离开前也等待同样的时长，除非 `exit_delay_ns` 另有规定：为 0 时等待 `delay_ns`，为负时不等待（一个接一个进来的行一起离开），为正时等待它自己的时长，如同 CSS 为每个状态设置 transition-delay。`instant` 的退出没有可延迟的过程。

```zig
const way: f32 = if (state.back) -1 else 1;
try v.column(.{ .grow = 1, .child_exit = .{ .pose = .{ .x_percent = -30 * way } } });
const page: view.Transition = .{ .hidden = .{ .x_percent = 30 * way }, .hidden_blur = 4, .after_exits = true };
for (&state.pages, 0..) |*presence, i| if (try v.presentColumn(presence, state.step == i, page, .{ .grow = 1 })) {
    try buildPage(v, i);
    try v.end();
};
try v.end();
```

运动期间每遍请求下一帧唤醒，静止时不请求；减少动态效果时立即出现与消失。没有 `prepareShaderEffects` 时不透明度、位姿与模糊被忽略。

颜色默认在 sRGB 中预乘混合；`ui.Color.mixOklab(a, b, t)` 在 Oklab 中混合，与渐变的 `.oklab` 插值相同：两个饱和色之间的中点保持亮度与饱和度，而不是经过发灰发暗的中间色（黄到蓝经过蓝色而不是灰色）。共享元素的 `Match.oklab` 让飞行途中的背景、边框与文字颜色这样混合。语言、隔离方式与预算见[着色器与元素效果](shader-effects.md)。

### 裁剪与遮罩

`Style.clip_inset`（`ClipInset`：`top`、`right`、`bottom`、`left`、`radius`，`percent` 时按盒子宽高的百分比）把节点的背景、边框和后代裁到盒子内缩后的矩形，如 CSS 的 `clip-path: inset()`。它不是层，每遍都可以改：应用把插值从 100% 动画到 0 就是擦入效果。被裁掉的部分不接收点击，后代的命中区也与裁剪相交。

`Style.mask`（`Gradient`）按渐变在节点盒子上的 alpha 遮罩节点和它画的一切，如 CSS 的 `mask-image`：线性、径向与圆锥渐变都可以，颜色不起作用，盒子（或 `clip_inset`）之外什么也不显示。上下边缘淡出的列表用 180° 的线性渐变，从透明到黑再回到透明。遮罩逐个作用于节点画的每个绘制物，而不是先把它们画进一层再遮罩：遮罩半透明处两个重叠的子元素会互相透出，如同各自带了不透明度；`Style.opacity`、位姿和效果这类层在遮罩里作为一个绘制物。点击不被遮罩。

嵌入叶子可以直接用 `ui.Frame.pushRoundedClip(bounds, radius, mask)` 与 `pushPathClip(path, transform)` 裁剪，`pop_clip` 结束；`pushPathClipRule(path, transform, rule)` 按 `vector.FillRule` 决定路径内部，`.even_odd` 时相交的子路径重叠处被挖空，同 SVG 的 `clip-rule`；路径可以由 `view.parsePath`（`ui.parsePath`）从 SVG path data 读出，数据有错时按 SVG 的做法画到第一个读不懂的片段为止，`PathReport` 给出错误与字节偏移。圆角裁剪内录制的控件只在圆角矩形内接收指针；变换后的命中区按变换反算精确判断，而不是按外接矩形。

遮罩按形状、尺寸与缩放缓存，同一形状再画不重新生成；上一帧没有用到的遮罩在下一次绘制开始时释放。缓存最多 128 项、64 MiB，单个遮罩每边最多 8192 个设备像素；没有空间时裁剪退回为外接矩形（`Context.clipMaskStats()` 的 `refused` 计数），不会丢掉已经画好的内容。软件渲染器（Linux、macOS CPU）在每个绘制物画之前保留它可能改变的像素，画完按遮罩把画出的像素与保留的像素混合；互不重叠的相邻绘制物合成一批一起混合，结果相同。Metal 把每批绘制物画进以覆盖遮罩为蒙版的组。Windows（D3D11 与 GDI）暂时退回为矩形裁剪。

### 位姿动画

`Style.pose_motion` 给节点一个 `ziggurat_animation` 的运动：之后每遍构建改变它的 `pose` 或 `opacity` 时，节点从上一帧画到的位置和不透明度沿这个运动移到新的值（`src/view/posed.zig`），中途被改向时从当前位置继续，运动期间每遍请求下一帧唤醒。

位姿从节点第一次被摆出的地方开始：上一帧没有摆出它（比如第一次构建它）时，它直接显示在这一帧的位姿上，要等之后某一遍把它摆到别处才会动。要让它从某个位姿进场（比如浮层面板显示时上浮淡入），在一遍构建里把它摆在那里并请求下一遍，下一遍再摆回原位：

```zig
const p: ?ui.effects.Pose = if (!state.entered) .{ .y = 8 } else null;
const opacity: f32 = if (!state.entered) 0 else 1;
if (!state.entered) {
    state.entered = true;
    v.wakeAt(v.time()); // 请求紧接着的下一遍
}
try v.column(.{ .key = 1, .pose = p, .opacity = opacity, .pose_motion = .{ .spring = .{} } });
```

没有第二遍构建时，它就停在第一个位姿上。出现在上一帧已经显示的容器里的节点（比如列表新加的一行），用 `presentColumn` 的进场运动。减少动态效果时位姿立即到位，只有不透明度仍然平滑变化。和 `pose` 一样只移动画出来的内容，命中、焦点和语义保持排布后的盒子。

### 共享元素

`Style.match = .{ .key = ... }` 给节点一个与另一个节点共享的身份，比如网格里照片的缩略图与详情页里的大图（`src/view/matched.zig`）。带某个 key 的节点出现时，如果上一帧是另一个节点带着同一个 key，它就从那里飞过来：从那个节点的盒子到自己的盒子（内容按比例缩放，不按每个尺寸重排），从那个节点的外观到自己的：背景、边框和文字颜色、圆角、不透明度和位姿，旋转（含绕 X/Y 轴的 3D 转动）走较短的方向。`motion` 是 `ziggurat_animation` 的运动，默认 300 ms 缓出；被打断时从当前画到的位置继续。

```zig
const photo: view.Match = .{ .key = p.id, .motion = .{ .spring = .{} }, .fly = true };
if (state.open == null) {
    try v.image(p.thumb, .{}, .{ .key = p.id, .width = 64, .height = 64, .match = photo });
} else {
    try v.image(p.full, .{}, .{ .key = 1, .width = 320, .height = 240, .match = photo });
}
```

`fly = true` 时，飞行中的节点画在所在层（窗口内容，或它所在的浮层）其余内容之上，越出祖先的裁剪和不透明度，并沿用它外围 `Style.theme` 的主题；离开的那个节点跟着一起飞并在后半程淡出，新的节点在前半程变为不透明，二者交叉淡化，离开的画在新的下面。离开的节点这一帧仍在构建时（比如正在退出的页面）就是它本身；已经不再构建时，是它最后一帧的副本（`matched.Copy`：盒子、背景、边框、圆角、文字与不透明度，颜色在复制时按主题解析，图片等借用的资源不复制，最多 `matched.copy_nodes` 个节点）。飞行中的节点自己连同外围节点一起被移除时，它的副本按原路线继续飞，到终点时淡出。飞完后仍在的那个不会再飞回来，直到它不再构建。一次只让一个节点带某个 key（交叉淡化时的两个除外）；View 同时跟踪 `matched.capacity`（32）个身份、`matched.max_copies`（8）个副本。飞行中的节点在它画出的位置接收指针：它和后代的命中区与语义边界按位姿的平移、缩放和旋转（绕原点，含绕 X/Y 轴的转动）移到画出的位置（`ui.Frame.setHitMap`，转动后取画出区域的外接矩形），并排在所在层其余命中区之上，所以点击飞行途中的按钮会激活它；落地后回到排布后的盒子。焦点顺序不变。需要 `prepareShaderEffects`，否则直接出现在原位；减少动态效果时也直接出现在原位。

`morph = true` 用在文字节点上：两个文字共有的字符从原来的位置移到新的位置，大小随字号渐变，其余字符淡出或淡入（`src/view/morph.zig`）。字符按最长公共子序列配对以保持顺序，剩下的相同字符按相对位置取最近的一个，就像字母重新排列。它既用于从同 key 的另一个文字节点飞来，也用于同一个节点的文字原地改变（比如计数从 12 变成 123）。变形时节点不再按位姿缩放，离开的节点不再单独绘制（它的字符就是变形的起点）；超过 `morph.max_chars`（64）个字符的文字不配对，整体交叉淡化。列出自己字符的嵌入叶子（`Embed.glyphs`，富文本 `RichText` 已实现）同样可以变形：每个字符带自己在叶子内的位置、字体和颜色，配对的字符在两种样式之间移动、缩放并渐变颜色，变形期间由视图逐字绘制，结束后叶子恢复自己的绘制；字符、样式或颜色改变都会触发原地变形。View 同时为 `matched.max_glyph_texts`（4）个这样的叶子保留字符，下划线、底色与内嵌对象在变形期间不绘制。

## 子树缓存

`Style.cache = cache`（`ui.Cache.create(app, allocator)` 创建，Host 销毁前 `cache.destroy()`）把节点及其后代画进一张图片，每帧比较它们记录的命令（移到图片原点后哈希），相同就直接画这张图片，不再光栅化子树；内容、尺寸、DPI 或主题变化时才在离屏工作面重画（`src/ui/cache.zig`，底层是 `Frame.beginCache` / `endCache`）。

- 图片覆盖子树实际画到的范围（含阴影、外描边），按设备像素对齐，所以整像素平移也复用同一张图片；与 Linux/macOS 的局部重画配合，图片不变时其所在区域不会被重画。
- 命中、焦点和语义照常记录，按钮等控件在缓存里仍可交互。
- 只缓存普通绘制、裁剪、加载指示器和不带滤镜的分组；子树含变换、元素效果、背景效果、滤镜、GPU 纹理，或超过 4096 像素宽高、200 万像素时照常绘制（`cache.stats().direct` 计数）。
- 图片在透明离屏工作面上画，文字为灰阶抗锯齿；边缘半透明处与直接绘制可能差一两个色阶。
- 被替换的旧图片由 Context 在下一帧开始时释放。

## 加载动画

`loadingIndicator(kind, options, style)` 加入 29 种加载动画之一，作为以 `Style.name` 命名的不确定进度条暴露（Windows UIA 上是没有 RangeValue 的 ProgressBar）。`LoadingOptions` 有 `size`（高度，默认 20 DIP，宽度按宽高比）、`color`（默认主题文字色，禁用时为禁用文字色）、`duration`（0 为自身周期）、`paused`、`timer`、`frame_rate`（每秒帧数，null 为每次刷新，见 `animationFrameRate`）与 `variant`（`ui.loading.Options`）。没有 `timer` 时姿态取 `View.time()`，同一窗口的指示器同步转动；应用持有的 `LoadingTimer` 记录各自的起点，`paused` 时保持当前姿态，恢复后从该处继续。

动画中的指示器每一遍都请求 16.7 ms 后（设置了 `frame_rate` 时按该帧率）的唤醒，因此需要[调度器](#时间与唤醒)才会持续转动；暂停、减少动态效果或指示器不在树中时不请求，窗口回到完全空闲。

## 系统偏好

`host.setPreferences(.{ .reduce_motion, .reduce_transparency, .high_contrast })` 由应用按桌面偏好设置并重绘：减少动态效果让加载动画停在静止姿态，减少透明度或高对比度让背景效果变成不透明填充。`pointer` 与 `any_pointer`（`z.PointerAccuracy`：`.fine`、`.coarse` 或 `.none`）、`no_hover` 与 `no_any_hover` 对应 Media Queries 4 的 pointer、any-pointer、hover 与 any-hover，零值是鼠标的：触屏优先的布局给粗指针更大的目标，只在悬停时出现的内容只给能悬停的指针；`hover()` 与 `anyHover()` 是它们的正面读法。应用从 `system.desktop.Preferences` 的同名字段取得。

## 窗口隐藏

`v.windowHidden()` 返回窗口此刻是否完全不在屏幕上，相当于网页的 `document.hidden`：窗口被隐藏或最小化（Linux 在 X11 上报告最小化，Wayland 不报告）。显示时钟、价格或播放进度的视图在隐藏时停下这些工作，显示后刷新。从某次构建第一次询问起，窗口隐藏时 Host 会在不绘制的情况下再构建一次，重新显示时下一帧再构建；没问过的视图不会因此多构建。隐藏时的这次构建不等帧：macOS 上隐藏或最小化的窗口不再显示（display link 也停），Windows 不给最小化的窗口发 WM_PAINT，等帧就要等到窗口重新显示。窗口在某次构建当中被隐藏（例如构建里调用了 `perform(.minimize)`）时，这次构建读到的仍是显示状态，隐藏时的构建在它结束后从应用队列补上。`zig build smoke-window-hidden` 在 macOS 上隐藏和最小化、在 Windows 上最小化窗口，检查各构建一次、显示后再构建一次（Linux 只报告最小化，CI 上没有能最小化窗口的窗口管理器，跳过）。只是移动的动画帧在隐藏时本来就不画。无窗口测试用 `Harness.windowHidden(bool)` 模拟。

## 屏幕刷新率

动画按窗口所在显示器的刷新率排帧，不再固定 60 Hz：`Host` 每次构建前用 `Window.refreshRate()`（Linux 取 `gdk_monitor_get_refresh_rate`，未知时为 0）设置 `View.refresh_interval`，位姿、匹配过渡、集合动画与加载动画都按这一间隔请求下一帧，`animationFrameRate` 降帧时也落在整刷新周期的网格上（`frameIntervalAt`）。刷新率未知时仍按 16 ms。inspector 的 `refresh_hz` 同样取自窗口。

## 开发者工具（inspector）

`Options.inspector` 给 Host（或 Harness）一个 `view.Inspector`，像浏览器的开发者工具那样把视图的元素显示在停靠在窗口右侧的面板里：元素树写成标记，选中元素的样式、盒模型与属性，悬停或选中元素时在内容上画出的高亮，帧耗时，以及问题。

```zig
var inspector: view.Inspector = .{};
var host = view.Host.init(&app, App.build, storage.buffers(), .{ .inspector = &inspector });
```

只有带 inspector 的构建才有它：默认是 Debug 构建，`-Dinspector=true` 或 `-Dinspector=false` 改变这一点（`view.inspector.enabled`）。不带它的构建（`ziggurat build` 默认的 ReleaseSafe 等发布构建）里 Host 与 Harness 忽略 `Options.inspector`，`Options.tools()` 在编译期就是 null，inspector 的代码不会编进程序。

- 打开与拾取：F12 或 Ctrl+Shift+I 打开或关闭，Ctrl+Shift+C 打开并进入拾取，Escape 停止拾取；`enabled = false` 时这些键交给视图。打开时内容得到窗口减去面板的宽度（默认 420 DIP，至少 260，给内容留至少 160；窗口窄于 520 时各占一半），拖动面板左缘改变宽度。面板按主题背景的明暗选用浅色或深色配色，自身始终从左到右。
- 元素树：每个元素按种类写成标签（`<Button>`、`<TreeRow>`、根是 `<Column>`），带 `key` 与 `name` 属性和文本节点的文字；靠近根的三层默认展开，点三角展开或收起，按住 Alt 展开或收起其中全部。悬停一行在内容上高亮它的元素：内容蓝色、内边距绿色、边框黄色，附带提示框（种类与 key、尺寸、文字颜色与字体、背景、内边距，以及辅助技术看到的名称、角色和能否用键盘聚焦）。点一行选中；面板有键盘时上下键、Home/End 移动选中，左键收起或回到父元素，右键展开或进入第一个子元素。面板有键盘时 Ctrl+F 在树上方打开查找栏：输入的文字（不区分大小写）匹配元素的标签名、文字、`name` 或 `key`，选中第一个匹配并在树中展开、滚动到它，查找栏显示“第几个/共几个”；Enter 与 Shift+Enter（或栏里的上下箭头）在匹配之间前后移动，Backspace 删字，Escape 或 × 关闭。打开查找栏时窗口里持有键盘的文本字段失去焦点，输入进入查找栏；Harness 用 `typeText` 输入。树下的路径条显示从根到选中元素的路径，点其中一项选中它。
- 拾取：工具栏的拾取按钮或 Ctrl+Shift+C 之后，指针下最内层的元素高亮（浮层优先于流内元素），按下选中它并在树中展开到它；这次按下和松开交给 inspector，不会点到元素。
- 详情：Styles 把元素设置的样式写成一条 CSS 规则（`flex-direction`、`gap`、`padding`、`border`、`background-color`、`font-size`、`white-space`、`line-clamp` 等）；Computed 画出边框、内边距与内容的盒模型及尺寸，再按名称列出布局后的值（位置、尺寸、方向、字体、颜色、不透明度，滚动容器的滚动偏移与内容尺寸）；Properties 列出种类、id、key、构建位置、文字，状态（焦点、悬停、禁用、选中或数值），以及辅助技术看到的名称、角色和能否聚焦。
- 实时修改样式：Styles 在规则下面列出 `element.style`：`gap`、`padding`、`width`、`height`、`min-width`、`min-height`、`flex-grow`、`border-radius`、`border-width`、`opacity`、`font-size` 与三种颜色，未改的灰显当前值。点值开始输入（从当前值开始），Enter 或点别处应用，Escape 取消，Tab/Shift+Tab 应用后转到下一个或上一个；上下方向键把数值加减 1（Shift 为 10，`opacity` 为 0.1）并立即应用。数值可带 `px`，颜色写 `#rgb`、`#rrggbb` 或 `0xrrggbb`，`none`（尺寸也可写 `auto`）去掉颜色或尺寸；不合法的值留在输入框里等待修改。视图在每遍构建这个元素时把改动套在应用给出的样式上，直到点 Reset；`Inspector.setOverride`/`resetOverrides`/`restyle` 也可直接调用，最多同时 64 处改动。点 Copy as Zig 把这个元素的改动写成 `view.Style` 字段的 Zig（如 `.{ .gap = 12, .padding = .all(18), .background = 0x1a73e8 }`）放进 `Inspector.clipboard`（应用提供，例如 `ziggurat_system` 的剪贴板），`copied()` 返回它，粘进构建它的代码即可。
- 强制状态：Styles 的 `:hov` 一行可以给选中元素勾上 `:hover`、`:active`、`:focus`：指针区域按悬停或按下（`:active` 同时算悬停）报告，控件按按下或焦点绘制，不管指针和键盘实际如何；焦点只在绘制时替换，不改变真正的键盘焦点。`forceState` 与 `forced` 是对应的接口。
- 源码位置：面板打开时，视图构建选中元素的那一刻记下调用栈（只对这一个元素，每遍一次），inspector 用构建的调试信息找出第一个不在视图自身文件和标准库里的调用，即应用调用 `v.button(...)` 等的文件与行。Styles 的规则右侧显示文件名与行号，Properties 的 `built at` 显示完整路径；`Inspector.source()` 返回它。调用栈变化时才重新查找，查找时调试信息的读取会分配内存；没有调试信息的构建不显示。文件在本机存在时文件名显示为链接，点它在编辑器里打开那一行：命令取 `ZIGGURAT_EDITOR`，否则 `VISUAL`、`EDITOR`，行号按各编辑器的方式传入（VS Code 系 `-g file:line`，Zed/Sublime/Helix `file:line`，JetBrains `--line`，vim/emacs/nano 等 `+line file`）；都没设置时用系统默认程序打开文件。失败记到 Issues。用 `-trimpath` 之类去掉路径的构建不显示为链接。
- 性能与问题：Performance 显示最近 120 帧构建、排列与绘制的耗时柱状图，以及最近一帧、平均、最慢、显示器刷新率（`refresh_hz`，默认 60）和元素数，参考线是一帧的预算。Issues 列出构建中发现的问题，工具栏显示其数量：同一父元素下两个元素给了同一个 `key` 时它们共享一个身份，点击、焦点或滚动会落到另一个上；每个问题只记一次。Harness 默认（`Config.strict`）在这种构建上直接让 `render` 返回 `error.DuplicateKey`，`issue()` 给出说明，测试因此在出错的地方失败。帧的元素超过 `max_elements`（1024）时树只显示前面的部分并记为问题。
- 布局叠加层：树中排布子元素的元素行尾有 flex 或 grid 徽标，点击后在内容上一直显示它的布局（最多同时 8 个，再点关闭）：flex 容器的内边距和子元素之间的间隙画成紫色，grid 在子元素所占轨道的每条边画线；外框描边。
- 工具栏的 RTL 按钮把窗口按从右到左布局，再点恢复，用来在翻译之前检查界面；它设置 `direction_override`，Host 与 Harness 在下一遍应用它。

带 inspector 的构建也带[自动化](automation.md)：设置 `ZIGGURAT_AUTOMATION` 后，另一个进程可以通过套接字读取视图的元素并操作它们。

inspector 在视图之后绘制在同一帧上，并先于视图接收落在面板上的指针、滚轮以及它自己的按键，因此不向视图增加节点、控件或可访问性元素，也不占用视图的存储。它显示上一帧排列后的元素，复制在自身的固定存储里（约 300 KB），不分配；应用把它放在稳定的地址。Harness 的 `key`、`clickAt`、`press`/`moveTo`/`release`、`hoverAt`、`wheel`、`cursor()` 与 `image` 按 Host 相同的顺序经过它。显示器刷新率需要应用设置 `refresh_hz`，Host 不从显示器读取。

## 当前范围

已提供列、行、网格、纵向滚动容器、浮层与弹出字段、对话框、警告对话框与表单页、侧边栏、可编辑文本、查找栏、三态复选框与复选框组、按键绑定、路由与历史按钮、图片、SVG 与图标、视频（通过 `ziggurat_view_video` 的 GIF 与 APNG 解码器，或 `ziggurat_video` 的系统媒体框架）、从右到左布局、标签页、分栏、工具栏、分段控件、折叠区、手风琴、面包屑、列表框、树、表格、组合框、可编辑组合框、建议列表、标记输入框、搜索区域、表单字段与字段集、链接、徽标、度量条、评分、导航按钮、头像、提示、通知、文本、间隔、按钮、复选框、单选组、开关、确定进度、滑块、步进器、嵌入叶子（通过 `ziggurat_view_text`）可编辑文本字段，以及（通过 `ziggurat_view_pickers`）日历、日期/时间/数字输入与颜色选择器。分栏只接受比例偏好，没有 DIP 偏好和折叠，从右到左时也不镜像；从右到左时基础控件内部（复选框标记的位置、滑块的填充方向、树的缩进与三角）不镜像；路由没有页面过渡动画、历史菜单和转义解码，页面状态由应用持有；工具栏没有溢出菜单。只读组合框不按输入筛选；建议列表与可编辑组合框的筛选由应用完成；表格没有列宽拖动、列重排、冻结列和行头，排序由应用完成；树与表格不做虚拟化，也没有行内编辑；树不能拖动重排，重排一次只移动一项，拖动边缘的自动滚动只随指针移动发生；内置控件本身没有悬停外观（自绘控件可用指针区域的 `hovered`）；通知没有进出动画；对话框没有进出动画，一次只显示一个，也不能拖动或改变大小；可编辑文本单击即开始编辑；查找栏不自己搜索，也不高亮匹配；侧边栏的选中行在失去焦点时外观不变。没有虚拟列表和通用动画；玻璃没有按压放大动效。需要它们时可以直接使用 `ziggurat_ui` 的 Frame API。Linux 没有普通控件的 AT-SPI 层，上述可访问性只在 Windows UIA 上提供。

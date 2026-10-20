# 选择器

`ziggurat_view_pickers` 在[声明式视图](view.md)里提供日历、日期输入、时间输入、数字输入、颜色选择器和打开它的颜色按钮（color well）。它只用 `ziggurat_view` 的公开接口：节点、嵌入叶子、`popover` 浮层与 `takeEvent`，文字经 `ziggurat_i18n` 按 locale 格式化和解析。整个模块不分配。

每个控件绑定应用的一个值，并在应用持有、地址稳定的状态结构（`Calendar`、`DateInput`、`TimeInput`、`NumberInput`、`ColorPicker`、`ColorWell`）里保存光标、正在输入的文字和浮层开关。状态在构建它的每一遍、以及窗口还向它投递输入期间都必须有效。值被改动的那一遍函数返回 true。

```zig
const pickers = @import("ziggurat_view_pickers");

const Form = struct {
    due: pickers.Date = .{ .year = 2024, .month = 3, .day = 15 },
    due_state: pickers.DateInput = .{},
    start: pickers.TimeOfDay = .{ .hour = 9 },
    start_state: pickers.TimeInput = .{},
    amount: f64 = 1,
    amount_state: pickers.NumberInput = .{},
    fill: pickers.Rgba = pickers.Rgba.rgb(0x3b82f6),
    fill_state: pickers.ColorWell = .{},
    region: pickers.Region = .{ .locale = i18n.Locale.parse("de-DE") catch unreachable },

    fn build(self: *Form, v: *view.View) anyerror!void {
        try v.field("截止日期", .{}, .{});
        _ = try pickers.dateInput(v, &self.due_state, &self.due, .{ .calendar = .{ .region = self.region } });
        try v.end();
        _ = try pickers.timeInput(v, &self.start_state, &self.start, .{ .region = self.region, .style = .{ .name = "开始" } });
        _ = try pickers.numberInput(v, &self.amount_state, &self.amount, .{ .minimum = 0, .maximum = 100, .step = 0.5 }, .{ .region = self.region, .style = .{ .name = "数量" } });
        _ = try pickers.colorWell(v, &self.fill_state, &self.fill, .{ .style = .{ .name = "填充" } });
    }
};
```

## 区域与文字

`Region` 给出 locale；周的第一天、一年第一周至少包含的天数和 12/24 小时制默认从 locale 的地区推出（见[本地化](i18n.md)），也可以逐项指定。`Texts` 是没有可见文字的部分给辅助技术读的名称（上/下个月、时、分、上午/下午、饱和度与亮度、色相、不透明度、Hex），默认英文，应用负责本地化。

## 日历

`calendar(v, &state, &date, options)` 画一个月：标题是按 locale 写的月份与年份（`März 2024`、`2024年3月`），两侧是上/下个月的导航按钮，下面是 6 周 × 7 天的网格，从区域的一周第一天开始；`week_numbers` 在左侧加按区域规则计算的周数。`today` 由应用给出（它知道自己的时区），画成描边。

- 按下某天选中它。网格有焦点时，方向键按天/周移动并直接选中，Page Up/Page Down 按月（加 Shift 按年），Home/End 到本月第一天/最后一天；Enter 或 Space 选中光标所在的天。
- `minimum`/`maximum` 之外的天和 `disabled` 回调标出的天变暗且不能选；按键和导航按钮停在范围内，范围只有一个月时两个导航按钮都禁用。
- 光标移动时礼貌播报完整日期（`Saturday, April 1, 2023`）。Windows UIA 把网格映射为 Calendar，值为光标所在日期；每一天是带完整日期名称的子按钮（选中时 checked），辅助技术调用它就选中那一天。

## 日期输入

`dateInput` 是一个显示短格式日期（`3/15/24`）、读作组合框的字段。按下、Enter 或 Space 在它下方打开日历浮层，焦点落在日期网格上。浮层里方向键、Page Up/Page Down、Home/End 只移动光标而不改值；按下某天、Enter 或 Space 选中，浮层关闭，焦点回到字段；Escape 或在浮层外按下则不改值关闭。

## 时间输入

`timeInput` 是一个包含时、分（12 小时制时还有上午/下午）三段的字段。分隔符和上午/下午在时之前还是之后都取自 locale 的短时间模式，如 `h:mm a`、`H:mm`、`a h:mm`、`H 'h' mm`。

- 左右方向键或 Tab/Shift+Tab 在段之间移动（到头时 Tab 照常离开字段）；Up/Down 绕着钟面步进当前段，12 小时制下时数在同一半天里循环，上午/下午段则在两者之间切换。
- 键入数字设置当前段：第一位直接生效，第二位与第一位组成两位数，超出范围时从这一位重新开始；时数输满两位，或第一位已经不可能再接第二位时，自动跳到分。在上午/下午段键入 A 或 P（或 locale 名称的首字母）选择半天。
- 秒保持不变。辅助技术看到一个以 `Style.name` 命名的组，里面每段是带范围值的 Spinner，可以直接设置。

## 数字输入

`numberInput(v, &state, &value, range, options)` 是两侧带 −/+ 按钮的文本字段，按 locale 的数字、小数点和负号显示，小数位数取步长的小数位（步长 0.25 显示两位）。

- −/+ 按钮和 Up/Down 按 `range.step` 步进，Page Up/Page Down 按 `range.page_step`，结果夹在范围内。
- 字段显示数值时键入数字、负号或小数点会替换整段文字；之后的键入、Backspace/Delete 与左右/Home/End 编辑文字。文字一旦是范围内的数字就立即生效（按步长的小数位舍入），否则保留上一个值；Enter 或失去焦点时文字重新按格式显示，Escape 放弃正在编辑的文字。解析接受 locale 的小数点和分组符，也接受 `.`（在分组符不是 `.` 时）和 ASCII 数字。
- 辅助技术看到一个 Spinner，值为当前文字，带范围值。

## 颜色选择器与颜色按钮

`colorPicker` 从上到下是：饱和度（横向）× 亮度（纵向）方块、色相滑块（0–360）、不透明度滑块、预览和 Hex 字段、12 个预设色（`default_swatches`，6 列，悬停提示名称）。选择器内部按 HSV 保存，因此调到灰色或黑色后色相不丢失。

- 方块有焦点时方向键按 1%（加 Shift 按 10%）调整饱和度和亮度，按下直接定位；拖动等指针捕获可用后再接入。两个滑块随指针拖动和按键变化。
- Hex 字段显示 `#rrggbb`，不透明时省略 alpha，否则为 `#rrggbbaa`；键入的 `#rgb`、`#rgba`、`#rrggbb`、`#rrggbbaa`（`#` 可省略，大小写皆可）一旦合法就生效。
- 预设色是按钮，选中的那个带描边并读作 checked；`swatches` 可以换成应用自己的列表，最多 `max_swatches` 个。

`colorWell` 是一个显示当前颜色的按钮，按下、Enter 或 Space 在它下方打开颜色选择器浮层，Escape 或浮层外的按下关闭并把焦点还给按钮。Windows UIA 把它映射为带 Invoke、ExpandCollapse 和只读 Value（Hex 文字）的 Button，本地化控件类型为 "color well"。

## 浮层

日期输入和颜色按钮都用视图的 `popover(&open, placement, style)`：它锚定在前一个节点上，默认放在下方并左对齐，下方放不下而另一侧空间更大时翻到另一侧，并始终夹在窗口内；打开时焦点移到其中第一个控件，Escape 或在浮层与锚点之外按下就关闭，Escape 和由构建关闭时焦点回到锚点；在外面的按下照常交给下面的控件。Windows UIA 把浮层映射为本地化类型为 "popup" 的 Pane。见[声明式视图](view.md#浮层)。

## 验证

`zig build test-view-pickers` 已接入默认 test/check，用无窗口 Harness 覆盖：日期换算、月份边界与日历范围；按 locale 的周起始、周数与标题；按键与按下选择、禁用日与范围限制、辅助技术按 id 选日；日期输入的打开、选中、Escape 与外部按下关闭及焦点归还；时间输入在 12/24 小时制下的步进、键入、上午/下午、分隔符布局与按段设置；数字输入的步进、键入、范围、德语分隔符与 Escape；Hex/RGB/HSV 换算；颜色按钮浮层中预设色、色相与不透明度滑块、方块按键与按下、Hex 键入和 Escape；浮层翻转。隐藏窗口检查 `zig build smoke-pickers` 经窗口的 Context 发送按键并以 GDI/Cairo 绘制，验证日期浮层打开时的焦点投递、选择后焦点回到字段、时间分段、数字步进与键入，以及颜色按钮浮层的打开、按键和 Escape 关闭。这些检查不验证真实读屏播报或视觉效果；Linux 没有普通控件的 AT-SPI 层。

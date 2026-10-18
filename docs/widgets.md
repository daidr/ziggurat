# 基础控件

需要按控件身份区分主按钮单击、双击与三击时，显式使用 [`Frame.clickButton` 注册路径](pointer-clicks.md)。普通按钮的 API 与动作回调保持原合同。

`ziggurat_ui.Frame` 提供 `checkbox`、`radio`、`toggleSwitch`、确定进度的 `progress`、`slider`、双端 `rangeSlider` 和 `stepper`，与原有 `button` 共用有界绘制、输入和语义管线。它们由内容后端绘制，不为每个控件创建原生子窗口。

```zig
try frame.checkbox(1, check_bounds, "自动保存", state.autosave, .{});
try frame.toggleSwitch(2, switch_bounds, "通知", state.notifications, .{ .enabled = state.can_change });
try frame.radioGroup(10, group_bounds, "显示模式");
try frame.radio(11, first_bounds, "列表", state.mode == .list, .{ .radio_group = 10 });
try frame.radio(12, second_bounds, "网格", state.mode == .grid, .{ .radio_group = 10 });
try frame.progress(20, progress_bounds, state.fraction, .{ .name = "下载进度" });
```

应用拥有业务状态；以上方法只读取值。`Context.on_action(state, id)` 收到激活的 ID 后，由应用切换布尔值或选择枚举。连续输入不等待重绘，也不依据上一帧的布尔值计算新状态。应用状态变化后显式 `window.invalidate()`；Context 自己处理的输入会自动使窗口失效。

ID 为非零 `u64`，同一帧唯一，跨帧保持身份。同一 Bridge 的存续期间，ID 的语义身份和角色必须保持不变；切换控件类型应分配新 ID。`widgets.Options` 提供 `enabled`、`semantic_parent`、`radio_group`、可访问名称 `name` 与 `shortcut`。`buttonWithOptions` 增加这些选项，原 `button(id, bounds, label)` 签名保留。所有坐标使用 DIP，跟随 Frame 的 offset 与 clip；名称和标签在有界存储中复制。

指针在同一仍存在且启用的 ID 内按下、释放才触发普通动作。禁用控件阻挡其下方命中，但不会获得焦点或激活。完全裁剪、零面积和进度控件不进入 Tab 顺序；按下后移除或禁用会取消激活。Tab/Shift+Tab 按绘制顺序正反循环，Space/Enter 激活当前普通控件。Radio 以显式 `radio_group` 共享一个 Tab 停靠点，优先进入已选且可用的项；方向键循环选择，Home/End 选择首末可用项。其他普通控件用方向键在对应方向按几何距离导航，Home/End 到首末可用项。Radio 组至多一个选中项，重复选择返回 `MultipleRadioSelection`，应用负责维持该约束。

`progress` 的有限 `fraction` 截断到 0..1，非有限值返回 `InvalidProgress`。它没有动作或焦点，不提供自动动画或不确定进度时钟。应用依据实际进度请求重绘。

数值控件必须先设置 `Context.on_value(state, id, change)`。`ui.Range` 明确有限的 `minimum`、`maximum`、`step` 和可选 `page_step`；绘制拒绝越界、非有限或反向数值。`ValueChange` 是绝对 `set`、相对 `steps/pages` 或 `minimum/maximum`。应用将动作应用到自己的**当前值**，避免连续输入在重绘前重复使用旧值：

```zig
const limits: ui.Range = .{ .minimum = 0, .maximum = 100, .step = 5 };
try frame.slider(21, slider_bounds, state.volume, limits, .{ .control = .{ .name = "音量" } });
try frame.rangeSlider(.{ .group = 30, .low = 31, .high = 32 }, range_bounds,
    state.interval, limits, .{ .name = "区间" });
try frame.stepper(40, stepper_bounds, state.count, limits, .{ .name = "数量" });
// on_value: state.volume = try limits.apply(state.volume, change);
// 区间状态可用 ui.RangeValues；分别调用 limits.applyLow/applyHigh。
```

Slider 按下即定位，拖动期间保留原 ID，移出轨道仍更新并截断到端点，松开、丢失捕获、禁用或成功帧移除即结束。横向向右、纵向向上增大。双端分别有稳定焦点/动作 ID 与语义父组，两端都是 Tab 停靠点；`applyLow/applyHigh` 读取应用当前两值，限制交叉且不挪动另一端。每端可独立禁用。方向键增减一步，PageUp/PageDown 增减一页，Home/End 到范围端点。`step=0` 允许指针连续值，键盘一步为范围的百分之一；默认一页为十步。最大端点即使不整除步长也可到达，反向一步回到其下方步点。

相对动作保留方向：正次数不减小当前有效值，负次数不增大，零次数原样保留，包括应用赋值或双端截断产生的非步点值。一步从非步点到该方向的下一步点；一页先加实际 `page_step` 再按步长量化，结果受上述方向限制，因此过小的一页可以不改变当前值。

Stepper 是数值显示与左右减/加按钮，不提供直接文本编辑或按住自动重复。中心点击仅聚焦；按钮必须在同一方向区域内按下、释放，跨区域释放取消。键盘与 Slider 使用相同步进规则。应用可以选择不同的业务更新策略，UIA 与指针均走同一个 `on_value`。

快捷键通过 `Options.shortcut = .{ .key = .s, .modifiers = .{ .control = true } }` 显式绑定，支持完整 `z.KeyCode` 与 Shift/Control/Alt/Super 组合，默认忽略重复。默认平面注册不允许相同组合重复绑定，禁用/不可见项不匹配。显式 `Context.prepareShortcutScopes` 可启用[嵌套快捷键范围](shortcut-scopes.md)，在同一个成功输入 front 内允许父子覆盖及不同 sibling 的绑定，保留同 scope 歧义检查。普通控件触发同一 `on_action`，数值控件的快捷键只聚焦该控件。原生内容通过可选 `Content.key_input` 提前消费 keydown；未安装该入口时保留旧事件和文本路径。

UI 的 `on_input` 先收到一次 `.key_input`；若未消费，已有编辑键映射为一次 `.edit_key` 或 `.key`，供现有编辑器路由。编辑器有机会先消费自己的输入，未支持的键再匹配快捷键；已经进入 preedit 的组合输入和 AltGr 保留给 IM。裸字母绑定是显式应用快捷键，会优先于普通字符翻译。`Editor.handleEvent` 的返回值表示已消费，`Editor.key` 仍表示内容/选择是否改变。编辑输入失败时，宿主应报告错误并返回 `true`，否则剪贴板失败的 Ctrl+C 等可能误落到同组合的应用动作。丢失捕获和焦点会先清内部拖动状态，宿主仍可收到通知。

每个控件追加命中区、复制语义和绘制命令时执行同一事务；容量、重复 ID、字符串或语义错误会回滚该控件的全部追加。整个绘制回调成功且 Frame 栈平衡后才提交新的命中快照，失败帧保留之前的快照。绘制过程中不会分配 Zig 堆内存。当前容量是 128 个控件、128 个语义节点（含根与组）、2048 条绘制命令、64 KiB 绘制文本；单段文本最多 2048 字节。重复 ID 与分组检查使用有界线性扫描。

同步原生操作可能重入 paint。Context 会合并嵌套 paint，保留外层 Frame 的命令、输入和语义；外层退栈后再使窗口失效，不递归调用应用 draw 或引入刷新定时器。Windows 原生 WM_PAINT 与 Linux GTK draw 的隐藏窗口回归均覆盖这一边界。

启用 `-Daccessibility=true` 时，Windows UIA 使用显式语义：

| 控件 | UIA 角色与模式 |
| --- | --- |
| Button | Button / Invoke |
| Checkbox、Switch | CheckBox / Toggle，读取当前 checked |
| Radio | RadioButton / SelectionItem，Select 产生同一业务动作 |
| RadioGroup | Group / Selection，单选，允许初始无选择 |
| Progress | ProgressBar / 只读 RangeValue，0..100 |
| Slider / 双端的每一端 | Slider / 可写 RangeValue，当前值、动态上下界与步长 |
| Stepper | Spinner / 可写 RangeValue，不声明文本 Value 模式 |

Radio 的 `AddToSelection` 在已有其他选中项时拒绝操作；`RemoveFromSelection` 不取消已选项。`Select` 已选项时不重复产生动作。禁用动作返回 `ElementNotEnabled`。UIA 动作经现有 owner 线程入口调度，状态在下一次成功绘制后发布；不在 provider 中保存另一份业务状态。节点移除或窗口关闭后，独立原生 provider 的属性与动作返回 `ElementNotAvailable`；COM 接口集合保持创建时的身份，原先支持的 `QueryInterface` 仍成功并正确增加引用。UIAutomationClient 可缓存只读元数据，因此关闭后的 Progress SetValue 仍可能直接得到 `InvalidOperation`。

`zig build smoke-widgets` 按当前目标运行原生隐藏窗口检查。Windows 实测指针、Tab/Space、Radio 方向/Home/End、禁用、裁剪、移除、失败帧和关闭重入；加 `-Daccessibility=true` 还通过真实 MTA UIAutomationClient 检查 Toggle、SelectionItem、Selection 和 RangeValue，并验证关闭后的原生引用失效。Linux 已在 Ubuntu 24.04、Zig 0.15.2 和隔离 Xvfb/X11 中通过 GTK 原生按钮/键盘信号及 Cairo/Pango 绘制，覆盖同样的控件交互与关闭，`G_DEBUG=fatal-criticals` 下原生资源归零。单元测试覆盖命令/字符串失败回滚与输入快照。这些检查不证明视觉质量、完整屏幕阅读器兼容性或 Linux AT-SPI 支持。

`zig build smoke-widget-ranges` 在 Windows 与 Linux 原生隐藏窗口中验证范围拖动、越界释放、双端限制、独立禁用、Stepper 区域、连续步进、正反焦点导航、快捷键、编辑器消费失败与关闭重入。Windows 还通过实际队列与框架消息循环验证消费发生在 `TranslateMessage` 前，Space/Enter 不重复生成文本，普通字符仍只交付一次；加 `-Daccessibility=true` 使用真实 MTA UIAutomationClient 读写 Slider/Spinner RangeValue，并检查动态上下界、禁用、节点移除、关闭后的 COM 引用和资源归零。Linux 验证 GTK 原生信号路径与资源回收，没有声明 AT-SPI。测试不代表真实语言 IME 的完整兼容性。

自定义 `Frame.addControl` 的 `focusable=false` 仅排除键盘导航，启用且可见时仍可指针点击；`pointer_enabled=false` 只阻止指针激活，仍保留遮挡。进度控件同时关闭这两项。禁用项依然遮挡下面的控件。`Context.hitControl(point)` 返回最近成功帧的顶层命中项，包括禁用项，便于宿主决定是否向正文继续路由。`focusControl(id)` 与 `blurControls()` 只管理这套控件焦点。保留文档的宿主应先撤销唯一 TextClient，再移交给控件；反向移交先清控件焦点，再绑定正文。`Window.hasTextClient()` 是 owner 线程 O(1) 的物理占用查询，禁用/模态不会把占用伪装为空。默认指针、键盘及 UIA 焦点入口也拒绝与该占用并存；原生聚焦重入后重新校验客户端、窗口和 accepted ID。旧代、禁用、原生拒绝与重入撤焦点均返回明确错误。


显式注册的 [Document 字段](document-fields.md) 可复用同一 Input.focused 和前台事务，自动撤销自己的 TextClient 后向兄弟控件交接。普通宿主 TextClient 的显式移交规则保持；UI 不导入 DocumentEditor。

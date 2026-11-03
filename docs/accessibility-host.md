# 原生可访问性子节点宿主

本片已通过 Linux 通用原生宿主检查和 Windows 构造入口拒绝检查。它提供原生子节点的生命周期边界；文档 AtkText、AT-SPI 查询与编辑动作仍另行实现和验收。

```zig
const window = try app.createWindow(.{ .accessibility_host = .children });
```

`WindowOptions.accessibility_host` 默认为 `.platform`。Linux 默认仍创建普通 GTK DrawingArea；`.children` 在构造时选择可承载一个原生可访问性子节点的 DrawingArea 子类，绘制、输入和 IM 上下文仍使用原来的 widget。Windows 和其他真实后端对 `.children` 返回 `UnsupportedCapability`，不创建替代窗口。测试后端仅验证核心合同，不能证明 GTK 或辅助技术支持。

核心只管理通用原生子节点和宿主寿命，不导入 Document、UI 或 AtkText。可选内容模块通过窗口回调固定作用域使用私有平台适配；应用不需要自行取得或保存平台记录指针。子节点的文本和几何、发布版本、预算及动作责任由相应内容模块承担。

绑定分为 prepare、mount 和 withdraw。prepare 成功后，调用者拥有 token 并在 mount 前保存它。宿主始终最多一个 prepared 或 mounted binding；替换必须先 withdraw 旧节点，不承诺两个 provider 的原子替换。原始子节点引用不被消费。发布点之后的信号关闭可以立即退休一个已经接受的绑定；它仍履行已接受的释放责任。

退休先撤销 slot 和查询入口，再断开原生 parent 关系并通知。正常关闭、原始 area/window 销毁和构造回滚使用同一退休规则。GTK 原始窗口销毁中的 hide/unrealize 可早于 destroy 信号，本片不承诺早于这些 SDK 信号撤权；area dispose 和 accessible 处置前必须完成退休。重入尾部只能释放自己固定的旧对象，不能清除新绑定。

所有宿主操作和 GTK/ATK 引用释放都在 owner thread，包括 App 已退休之后的外部旧引用。外部引用只保留已失效的独立原生状态，不能进入已 detach 的 Zig 对象。原生 GType/class 元数据可以存活至进程结束；tracked resource 归零不等同于全部 GTK/ATK 内存归零。

未选配窗口不注册新宿主 GType，不创建绑定、子节点、文本缓存、任务或监视器。x86_64 ReleaseSafe 实测 `WindowOptions` 两平台均为144→152字节，`WindowRecord` Linux为488→496、Windows为752→760；`App` Linux4456、Windows5144及`Window`24字节不变。Linux token为72字节，选配area实例80字节（基类之外40）、host实例128字节（基类之外40），原NativeWindow仍416字节。SDK class、分配器额外开销和调用栈另计，不据此声称零CPU或二进制成本。

作者Debug/ReleaseSafe×1x/2x原生各8组、18个child精确finalize通过。root独立ReleaseSafe2x为45/45步骤、246/246纯测试，覆盖相同8组、实际公开构造入口、400窗口复用、App停机、作用域输入、合成和仿射UI；12源及UI依赖8源后验哈希一致。Windows独立公开入口与作用域输入为22/22步骤、152/152纯测试和GDI/hardware/WARP三个实际回放均通过。common rollback helper已覆盖，真实构造失败注入、直接parent属性通知、wrong-thread运行与外部AT-SPI仍须分别验证。

私有平台接口还可从已拥有的 live token 显式捕获原始 area 的32字节位置快照，不借 App 或窗口记录。尺寸和坐标使用 GTK 逻辑单位，scale 另列；可用 flags 区分尺寸、window 原点和 screen 原点。映射中的 X11 原点按实际 parent GdkWindow 加 area allocation，并以实际 Gdk toplevel 为 window 基准；未映射及本片未验证的 Wayland 原点不提供。调用失败保持输出不变，provider 应在显式更新时缓存，不在绘制或 ATK getter 内查询。

位置增量经 root Debug/ReleaseSafe×1x/2x 各19/19步骤检查，含与 GTK 自身 AtkComponent 的整数坐标对照、非零 area 偏移、真实窗口移动和负奇数物理像素的 HiDPI 舍入回归；真实 mount 信号内 BUSY、错误线程、隐藏、原始 area/live window 关闭及跨 App 的旧 token 均覆盖。token72、NativeWindow416不变。该检查不承诺多次 X11 查询之间的服务器原子快照、任意 viewport 可见性或 SDK 内部分配成本。

## UI 语义树（Linux ATK）

以 `-Daccessibility=true` 构建时，`ui.Context` 在 Linux 上把每帧的语义树发布为 ATK 对象，GTK 的桥经 AT-SPI 交给 Orca 等辅助技术，与 Windows UI Automation、macOS NSAccessibility 使用同一份 `accessibility.Tree`。窗口需以 `.accessibility_host = .children` 创建：语义树挂在绘图区可访问对象下的一个根对象之下，每个节点一个 ATK 对象。普通窗口仍不注册宿主类型；`Context.attach` 在这样的窗口上照常工作，只是不发布语义，并报告一次 `AccessibilityHostRequired` 警告。

- 节点按 ID 跨帧保留对象，只对变化发出信号：子节点增删（`children-changed`）、状态变化（`state-change`，焦点单独通知）、范围值（`accessible-value`）、文本框内容的增删与光标/选区移动（`text-insert`/`text-remove`/`text-caret-moved`/`text-selection-changed`）、列表选中行变化（`selection-changed`）。新出现的状态消息节点以礼貌级别播报一次（ATK 的 `notification` 或 `announcement` 信号）。
- 接口按角色：所有节点有 AtkComponent（范围、按点查找、取焦点）与 AtkAction（可按下的为 `click`，可展开的树项另有 `expand or contract`）；滑块、步进器、进度条和仪表有 AtkValue；静态文本有 AtkText；文本框、组合框和标记字段有 AtkText 与 AtkEditableText；列表、树、表格和标签列表有 AtkSelection，选中某行等同按下它。行与标签带 `posinset`/`setsize` 属性，树项带 `level`。
- 偏移按字符计，交给内容的选区换算为 UTF-16 单位；编辑以整段新值经 `set_value` 动作交给内容。动作与 Windows、macOS 一样经 `App.post` 排队，在主线程上按发出时的接收者授权执行；禁用或已移除的节点、过期的接收者都会拒绝。
- 坐标为绘图区逻辑像素，乘以窗口缩放；屏幕与窗口原点在发布帧和窗口移动时经宿主的位置快照读取，ATK getter 中不查询 GTK。仿射变换的内容以可见包围盒报告范围，并保留精确几何：按点查找时只命中点确实落在其变换后的盒子与各级裁剪内的节点（macOS 同样）。

`zig build smoke-accessibility-linux -Daccessibility=true` 在 Xvfb 中以 ATK 接口检查角色、名称、值、状态、范围、各类动作、选区换算与状态播报，并确认关闭后对象与动作归零。

# 控件指针多击

`Frame.clickButton` 为显式注册的按钮提供主按钮单击、双击与三击。窗口先以 `WindowOptions.native_pointer_clicks = true` 创建，Context attach 后再调用 `preparePointerClicks(allocator, registration)`。窗口未开启原始输入能力时，准备返回 `UnsupportedCapability`，不调用传入 allocator，也不改变已显示控件。

Core 的 receipt、原始时间与系统阈值见[指针输入](pointer-input.md)。窗口级 `window_count` 不是控件计数。控件按稳定 target、registration、Context attachment 和真实原始时序独立分类；A、B、B、B 的按钮回调计数是 1、1、2、3，连续第四击重新从 1 开始。当前第一片只接受主按钮 registered button。

## 注册与回调

`PointerClickRegistration` 包括借用的 `context`、可选 `on_input` 和必需 `on_click`。已准备 Context 的 pointer down、up、move 调用这份 registration 的 `on_input`，取代这些事件的 `Context.on_input`；其他事件仍沿用 `Context.on_input`。需要原处理器时，显式把它注册为同一个函数。消费预处理事件会终止本次控件分派。

在 update 阶段调用 `Context.newClickTarget(id)`，把返回的 `ClickTarget` 保存在宿主状态中；draw 中反复用同一个 token 调用 `frame.clickButton(target, bounds, text, options)`。不要在每次 draw 重新 mint。token 借用原来的稳定 Context，不能在该 Context 生命周期结束后使用。

一次已配对、仍获授权的主按钮 release 只调用一次 `on_click`。`ControlClick` 含 `id`、`count`、`button`、当前 `press` 和窗口 DIP `position`。返回 `accepted` 才可能保存下一击的连续性；`rejected` 仍表示本次回调已经执行。任何拒绝、过期或重入失效都不会重试 `Context.on_action`。普通按钮的指针，以及键盘 Space/Enter、快捷键和 UIA Invoke，继续使用已有 `on_action` 路径。

键盘激活本身不 claim、写入或额外清除指针历史。显式 `focusControl`/`blurControls`、真实窗口焦点或文本生命周期、registration 变化仍各自撤销指针连续性；原生回调内 receipt 的可用期继续由 Core 决定。

receipt 必须属于本次真实 Core 回调及 phase。注册按钮在预处理后、改变 focus/claim 前再次核对原来的 receipt。原始 timing 缺失时，合法配对仍可产生当前单击，不能延续多击历史。下一次 down 的 `previous_completed_sequence` 必须对应上次接受动作；未配送的其他按钮或未知按钮原始 down 也能打断连续性。

## 已显示前台与坐标

target 绑定与普通按钮的命令、hit、语义记录在同一候选事务中。真实绘制成功才发布新 hit 前台；失败候选保留旧前台。候选 bank 不提供输入权限，重绘或预处理器不能把已进入的旧 down 转给新 bank。

Input 仍是唯一命中权威。每次成功前台替换在覆盖旧 hit 数据前，分别核对上次接受动作的位置和当前 held down 的位置：相同 target 与 hit bounds、相同最上层可用命中、相同实际矩阵以及完整父 clip 链才能保留相应连续性。比较实际值，不依赖可复用的 Space/clip ID、AABB 或哈希。disabled 控件也参与原来的反向命中遍历。

若已按下的 registered hit 在新前台变成同 ID 的普通按钮，原按压同时取消；旧 release 不会因此进入普通 `on_action`。普通按压跨相同普通前台的既有规则保持不变。

`replacePointerClickRegistration` 即使收到相同函数与 context 值，也会推进非回绕 registration 并使旧 token 失效。`clearPointerClicks` 撤销语义权限，但保留已显示的非零注册标记；这些旧 hit 持续拒绝指针激活，不退回普通按钮。成功提交新的普通按钮前台才移除相应标记。再次 prepare 复用同一 owner 并推进 installation；detach 后同一个 Context 重新 attach 也保留其 issuer 高水位。计数器耗尽永久撤销语义权限，普通全零标记绘制仍可继续。

## 所有权与成本

调用者显式提供 allocator。完整 owner 包含两份有界 128-hit 关联 bank、单份 held/history、代数、回调描述、allocator 与引用计数，编译时检查整个记录不超过 4096 字节。它不建立另一份 hit 表、焦点模型、几何快照、dispatcher 或 timer。Context 只增加可选 owner 指针、installation 高水位和准备标记；默认未准备不分配 owner，普通 draw 不进行该功能的堆分配。

clear 与重新注册保留同一 owner，切换 allocator 返回 `AllocatorMismatch`。detach 先撤销入口和权限，再释放 Context 持有的引用；已进入回调保留独立引用到退出。allocator 及其 `allocator.ctx` 必须覆盖最后一次 owner 释放，不能因为 `on_closed` 允许释放 Context 就同时销毁仍被 owner 借用的 allocator 上下文。退役旧引用可与后续 attachment 的新 owner 重叠，4096 是每份完整 owner 的上限，不是所有退役对象的合计峰值。

关联与命中沿 Input 现有容量受限。单次提交至多比较两处保留点；每点遍历已有至多 128 个 hit，仿射裁剪沿已有至多 32 层 clip 链。准备、重注册、mint 属于 update 阶段；paint 或候选构建中返回 `Busy`。首次分配 OOM、allocator 重入清除/关闭或 attachment 变化均不发布半成品 owner。

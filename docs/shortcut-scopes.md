# 嵌套快捷键范围

`ziggurat_ui` 的可选 shortcut workspace 在现有 Input 命中候选和成功 front 上附加有界范围。控件 ID、快捷键、焦点和动作仍使用现有 Input 与 `Context.on_action`；Core 的 Window、模态和 TextClient 权限保持唯一。没有独立 dispatcher、计时器或后台线程。

在显式更新阶段调用 `try context.prepareShortcutScopes(allocator, options)`。可在 attach 前准备；attach 后须在 owner 线程调用。普通 Context 不分配这块存储。准备失败保留旧 workspace/front；旧 workspace 有活动 key 或已接受且未退休的任务时，重新准备返回 `Busy`。

```zig
try context.prepareShortcutScopes(allocator, .{});

// draw：仅登记本帧候选，不能在这里更新业务或执行动作。
try frame.beginShortcutScope(10, .{});
try frame.buttonWithOptions(1, parent_bounds, "查找", .{
    .shortcut = .{ .key = .f3 },
});
try frame.beginShortcutScope(11, .{});
try frame.buttonWithOptions(2, child_bounds, "下一个结果", .{
    .shortcut = .{ .key = .f3 },
});
try frame.endShortcutScope();
try frame.endShortcutScope();
```

隐式 window root 的 scope ID 为 0，不能重声明。其他 scope 使用非零稳定 `u64` ID，同一候选唯一。最多32个 scope（含 root）、16层、128个原有 hit；`ShortcutScopesOptions.capacity/depth` 可降低这两个上限。scope 必须词法配对。无效、歧义、超限或未平衡候选整帧失败，renderer 失败也不会发布任何新 scope。hit、membership、scope、可见性和 serial 在同一个成功 front 发布；widget 自身的 checkpoint/rollback 继续按同一 hit 下标工作。

启用 workspace 后，公开低层 `Input.addWithOptions` 也要求正在构造候选，否则返回 `NoFrame`，不能在两帧之间偷偷追加快捷键。默认未启用时保留原有平面接口。

## 路线和权限

未消费的键按以下顺序查找：实际控件焦点的最内 scope 及祖先；最上层可用 overlay 及祖先；window root。已经查过的祖先不重复查找，较低 sibling overlay 不作为 fallback。相同 scope 内相同 key 和完整 modifiers 一律 `DuplicateShortcut`，包括 disabled 或不同 `allow_repeat` 的声明。父子相同 chord 由最近可用子项覆盖。先选 chord 再核 `allow_repeat`，子项拒绝 repeat 时不会激活父项。

overlay 显式使用 `.kind = .overlay, .overlay_order = n`，order 必须非零、全候选唯一，嵌套 overlay 的 order 必须高于其祖先。是否可见来自同一 hit front 的真实几何和精确 affine clip；空或完全裁剪范围不抢键。需要只有语义/装饰的 overlay 阻挡背景时，可显式登记一个 `focusable=false, pointer_enabled=false` 的可见 anchor hit，不能为其绑定 shortcut。

`.keyboard_barrier = true` 仅用于 overlay，将注册快捷键限制到最高有效 barrier 的子树。可见但内部控件全部禁用的 barrier 仍阻止背景。超出该子树却声明更高可见 overlay 的候选返回 `ConflictingOverlayScope`。scope 的 `enabled=false` 继承到子 scope，停用其快捷键路线。

这是快捷键启用范围。它不建立 popup 生命周期、Tab trap、焦点恢复、指针阻挡或 Window 模态。原 `on_input` 显式预处理仍先于范围分派；应用主动消费的键不受 keyboard barrier 重解释。

有真实 TextClient 时，忽略残留的控件焦点。正文宿主取得成功 front 的 `try context.shortcutScope(id)`，再用当前 `Window.textClientToken()` 调用 `associateTextShortcutScope(scope, token)`。这只关联现有物理 token，不安装、解绑或聚焦客户端。token、Window、安装 epoch 和当时 front serial 必须完整匹配；旧 scope token 不能用于新 front。之后同一 stable scope ID 可随成功 front 继续解析；成功 front 删除该 ID 会撤关联，以后重用 ID 不会恢复。更换 TextClient 后须显式重新关联。

范围键入口要求真实窗口 focused、enabled、未被 Core 模态阻挡、未关闭/停止，并保留原文本 mode/preedit 权限。typed `.key_input` 先调用一次，未消费时再调用一次既有 legacy 映射，仍未消费才进入快捷键/控件导航。两个回调后重核物理 token、mode、焦点、routing epoch、安装和 front；回调中发布无关 front 会终止旧键。已经进入 preedit 的输入仍交给 IM；这不证明真实语言 IME 的完整兼容性。

## Escape 等待一次对应 front

`deferUnhandledEscape()` **仅允许本次输入回调内的裸、非 repeat、无 modifier Escape**。其他键返回 `InvalidDeferredShortcut`，回调之外返回 `NoKeyInput`。不补发原生 key、CHAR、文本或系统命令。

宿主在 typed `on_input` 的更新阶段完成显式准备，保存返回的 `ShortcutRequestToken` 并返回 false。该 Escape 从此保持 consumed。对应 draw 用 `try frame.acceptShortcutRequest(token)` 标记本次候选；只有携带这个精确 request 的成功 front 能满足等待。draw 中只投影，不执行业务。

外层 paint 清理退出后最多 `App.post` 一次。任务使用精确成功 serial 查找 Escape 注册；没有匹配才调用 `ShortcutScopesOptions.unhandled` 提供的显式 fallback 一次。任务不再次调用 typed/legacy 预处理。动作或 fallback 应在更新阶段清宿主保存的 request token，以免之后把已结束 token 传给新 Frame。

终结的 frame attempt 失败时，沿用原成功 front，仍最多排一次 continuation；renderer.begin、transform 代数或预检失败也属于这类终结失败。零尺寸、既有可重试 PresentationBusy/wake 保持 waiting，不添加等待或轮询。无关新 front、queued 后换 front、不同新键、失焦/回焦、cancel、preedit 生命周期、正文输入、mode/token 变化、clear 或关闭都会撤旧责任。同 Escape repeat 只合并消费。`cancelDeferredShortcut(token)` 可显式撤逻辑请求；已被 App 接受的任务仍须退休。

任务 post 返回 `Full`/`Closed` 时未转交所有权，立即取消该 Escape、归还 task pin 并报告 `.operation = .post`。`shortcutScopesStats().last_error` 可查询最后失败。不会在 paint 中临时执行 fallback、无限重试或借 cleanup 绕过业务队列容量；此时不保证 fallback。

## 寿命和费用

workspace 是显式 allocator 创建的独立 owner，Context 自持一份引用，成功 post 另持一份。detach/clear 先撤销 Context 入口；任务在入口为空时只退休 owner。`on_closed` 可以立即释放 Context，之后任务不解引用它。任务/诊断/业务回调边界使用现有 callback pin；退出 callback scope 后只访问独立 owner。ScopeToken/RequestToken 自身仍是借用值，不能在 Context 释放后调用其 Context API。

每次使用借用 token 时，原 Context 对象都必须仍在寿命内。安装 epoch 只保证跨**同一个 Context 对象**的 clear/reprepare/detach 不复用；对象寿命结束后在同地址重新 `Context.init` 不提供全局 issuer 身份，也不能拿旧 token 验证新对象。已接受 post 持独立 workspace 跨 Context 释放，是另一条所有权合同。

**allocator 及其 `allocator.ctx` 必须活到最后一条已接受任务退休**。不能因为 `on_closed` 已释放 Context 就同时销毁借宿主字段的 allocator context。App 按原合同活到所有已接受 post 退出，workspace allocator 可使用独立且覆盖这段寿命的宿主存储。

`clearShortcutScopes()` 关闭入口但附着期间保留一个 closed workspace，旧 scoped hits 持续拒绝快捷键，不能退回 flat 匹配抢走父子重复 chord。下一次 prepare 成功安装新 workspace 后，也必须等新的成功 front；实际 detach 清除 hits 后，新 attachment 才恢复默认平面模式。clear 不是移除整套控件。安装、front、request 和 routing 代数不回绕，耗尽明确拒绝或关闭对应入口。

控件焦点每次实际变化都撤旧请求并推进同一 routing epoch，包含临时切走再切回的情况。Context 宿主使用 `focusControl/blurControls` 保留原生授权；操作低层 Input 模型时使用 `setFocused`，不要直接改其 `focused` 字段绕过取消协议。

x86_64 Linux、Zig 0.15.2、gpu/accessibility 关闭时，旧/新实际布局：Input 45152→45168B，Context 194696→194712B；Hit176B、Frame928B、widgets.Options48B 均不变，alignment均8。默认有两 word（16B）固定成本，未准备时无新增 heap。选配 workspace2344B，一次分配含两个完整 bank、全部任务槽和所有有界 scratch；普通替换准备峰值4688B，不含 allocator 自身开销。closed 但仍有 owner/task pin 的整块存储计入实际物理存活，不能按逻辑 cancel 计为释放。其他平台/编译选项须分别测量。

普通 key 和 normal draw 不分配 scope heap。scope完整验证有界 O(S²+H²)，S≤32/H≤128；键匹配 O(S+H+depth)，没有输入时不扫描路线。默认 flat 路径只判可空指针；scoped key/match/post helper 独立，不把其 rank/authority scratch 常驻到默认路径。Debug/ReleaseSafe 的具体栈和编译配置见验证布局证据，不能从固定字段尺寸推定零栈成本。

验证目标：`zig build test-shortcut-scopes` 使用 test backend；`zig build smoke-shortcut-scopes` 使用当前目标原生后端。Linux fixture 在隔离 Xvfb 映射 GTK 顶层并等待真实 GDK focus，经 GTK key signal、Cairo renderer 和 App FIFO 验证；Windows fixture保存/清理/恢复线程键盘状态并要求 SetFocus/GetFocus 前置条件。测试不建立视觉质量、任意全局快捷键或真实语言 IME 的完整兼容性。

原生 fixture 默认软件模式。Windows 用 `--renderer hardware` 或 `--renderer warp`（构建时须 `-Dgpu=true`）选择实际 GPU 路径；它提交非空背景命令，并要求 `gpu_frames`、设备/目标创建及 presents 都非零，且软件帧/fallback 为零。Linux 明确拒绝这两个参数，使用 Cairo。仅编译 GPU 选项不等于这两种执行已经通过。

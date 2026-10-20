# 窗口状态与关系

所有窗口方法在 App 的 owner 主线程调用。`createWindow` 创建隐藏窗口；挂接 Content 后显式 `show`。关闭中的窗口与过期值句柄返回 `Closed`，不会恢复已关闭的槽位。

## 客户区与屏幕位置

```zig
const window = try app.createWindow(.{ .width = 720, .height = 480 });
const caps = try window.capabilities();
const before = try window.clientBounds();
try window.setClientBounds(.{
    .position = if (caps.client_position) .{ .x = 120, .y = 160 } else null,
    .width = 800,
    .height = 500,
});
```

`ClientBounds.width/height` 是整数 DIP 客户区尺寸，不包含系统边框、标题栏或菜单。设置范围为 1…32768，且不能小于创建时的 `min_width/min_height`。`resize(width,height)` 保留位置。`setClientBounds` 的空 `position` 也保留位置；读取为空表示平台不提供可靠的顶层屏幕位置。

`contentSize()` 查询当前物理客户区 width/height 和 DIP scale，不需要等待 paint，也不分配。它返回当前原生分配尺寸；GTK 尚未完成布局时可能仍是初始分配，不能把它当作最近 resize 请求已经完成的证明。区域布局用 DIP，原生附件按这个 scale 转换一次。

`ScreenPoint` 表示客户区左上角，坐标允许为负。屏幕位置没有统一的跨显示器 DIP 空间：

| 平台 | 位置单位 | 行为 |
| --- | --- | --- |
| Windows | 虚拟桌面的物理像素 | 按目标位置移动后读取窗口实际 DPI，再计算客户区尺寸；跨显示器移动可能同步产生多次 resize |
| GTK/X11 | 桌面逻辑坐标 | 使用 STATIC gravity，使 move/get_position 表示客户区原点；窗口管理器仍可调整请求 |
| GTK/Wayland | 不提供位置 | 查询为 null；指定位置返回 `UnsupportedCapability`，不会顺带提交尺寸变更 |

Windows 每显示器 DPI 在进程启动时启用；嵌入到已先行配置 DPI 的宿主进程时，宿主负责提供兼容的 DPI 上下文。客户区 DIP 与物理像素转换可能有整数舍入。尚未用多个不同 DPI 的物理显示器验证跨屏行为。

`setClientBounds` 要求普通状态：最大化、最小化和全屏窗口须先还原。兼容的 `resize` 保留原有最大化/最小化原生行为，但全屏期间同样返回 `InvalidWindowState`。GTK 的几何设置是 WM 请求，成功不保证立即达到指定值；通过 `resize` 事件后查询实际 bounds。

验证错误在原生修改之前返回。原生窗口操作通常不可原子提交；例如 Windows 跨屏移动分两步完成 DPI 与客户区调整，若中途原生失败，位置可能已变化。失败通过错误返回和同步诊断 sink 报告，真实原生错误码在回滚之前捕获。

## 全屏与置顶

```zig
if (caps.always_on_top) try window.setAlwaysOnTop(true);
if (caps.fullscreen) try window.setFullscreen(true);
// 退出全屏后还原进入前的普通位置、尺寸和最大化/最小化状态。
try window.setFullscreen(false);
```

`capabilities()` 按窗口当前显示环境查询 `client_position/fullscreen/always_on_top`。X11 每次检查 WM 公布的能力；无 WM 时不会把全屏或置顶当作成功。Wayland 支持标准全屏请求，但不提供任意置顶能力。macOS 后端尚未实现。

全屏不隐式设置置顶。置顶策略可在全屏中独立修改，退出全屏后保留修改后的值。全屏期间禁止 `resize`、`setClientBounds` 和 `perform(.minimize/.maximize/.restore)`，以保持退出时的还原边界；show/hide、enable/disable、focus 和显式关闭仍可使用。

Windows 保存原生 `WINDOWPLACEMENT`、窗口样式与扩展样式，进入所在显示器完整区域的无边框全屏；退出时还原普通几何和之前的最大化/最小化状态。隐藏普通窗口进入/退出全屏仍保持隐藏。为了避免在原生还原中显示一个被隐藏的最小化窗口，这一组合进入全屏返回 `InvalidWindowState`；先 restore 或 show 后重试。原生菜单句柄保持其所有权，全屏时客户区覆盖完整显示器，退出后菜单恢复。隐藏、启用和置顶在全屏期间的显式修改不会被旧快照覆盖。

GTK 保存普通几何及已观测的最大化/最小化状态，使用原生 fullscreen/unfullscreen 请求；WM 确认离开全屏后恢复几何与状态。调用不阻塞等待 WM，不启动轮询，也不运行嵌套消息循环。连续 enter/exit 可取消尚未应用的请求，窗口管理器保留最终决定权。

## 运行期窗口策略

```zig
try window.setTraits(.{ .resizable = false, .maximizable = false });
try window.setClosable(false); // 用户关闭请求直接 cancelled，不调用 on_close
if ((try window.capabilities()).opacity) try window.setOpacity(0.85);
try window.setIgnorePointer(true); // 指针穿透到下方窗口，键盘焦点不变
try window.flashFrame(true);
try window.setDocumentEdited(true); // 标题前加 "*"
```

`WindowTraits` 含 resizable/movable/minimizable/maximizable/closable，`WindowOptions` 有同名构造字段，`traits()` 读回当前值，`setTraits` 一次更新全部，`setResizable` 等是单项便捷写法。resizable 同时决定自定义装饰的缩放边与 `startResize`；movable 为 false 时 `startMove` 返回 `InvalidWindowState`；closable 为 false 时 `requestCloseFrom(.user)` 返回 `cancelled`，应用自己的 `requestClose` 与 `destroy` 不受影响。Windows 改写 `WS_THICKFRAME/WS_MINIMIZEBOX/WS_MAXIMIZEBOX`（不可缩放的窗口没有最大化按钮，与创建时一致），把系统菜单的关闭项置灰（关闭按钮与 Alt+F4 随之失效），并在 `WM_SYSCOMMAND` 拒绝被禁用的最小化、最大化、移动与关闭；全屏期间只更新退出时恢复的样式。GTK 设置 resizable/deletable，X11 另以 Motif 功能提示告知 WM 移动、最小化、最大化，提示由 WM 决定是否遵守；禁用可缩放时先固定当前尺寸，避免收缩到自然尺寸。禁用最小化或最大化需要 `capabilities().window_buttons`（Windows、X11）。

`setOpacity(0..1)`、`setIgnorePointer`、`setContentProtection`、`flashFrame`、`setSkipTaskbar` 各有同名能力位。Windows 以 `WS_EX_LAYERED` + `SetLayeredWindowAttributes` 实现整体透明，指针穿透再加 `WS_EX_TRANSPARENT`；内容保护使用 `WDA_EXCLUDEFROMCAPTURE`，旧系统退回 `WDA_MONITOR`（截图中显示为黑色）；闪烁用 `FlashWindowEx` 持续到窗口回到前台；任务栏隐藏经 `ITaskbarList::DeleteTab`，资源管理器重启（`TaskbarButtonCreated`）后重新隐藏。GTK 以 `gtk_widget_set_opacity`（需要合成器，否则不提供 opacity 能力）、空输入形状、urgency hint 与 skip-taskbar hint 实现；Linux 不提供内容保护。`opacity` 与 `skip_taskbar` 也可在 `WindowOptions` 中设定，创建后立即应用，能力不足时创建失败并回收窗口。

`setDocumentEdited(true)` 在 Windows 与 Linux 的原生标题前加 `*`，与系统编辑器一致；`setTitle` 保留该标记，`title(buffer)` 读回不含标记的标题。窗口记录持有一份标题副本，由 App 的分配器分配，随记录释放。

## App 激活

`AppOptions.activation` 在 App 的第一个窗口获得键盘焦点、或最后一个焦点窗口失去焦点时回调 `changed(context, app, active)`；`app.isActive()` 返回最近一次报告的值。焦点在本 App 的窗口之间移动不报告：焦点事件只标记待定，到下一个 dispatch 安全点再汇总比较。焦点窗口关闭等同失去焦点。

## 请求、观测与回调

`WindowState.fullscreen/always_on_top` 是已观测状态；`fullscreen_requested/always_on_top_requested` 是最近接受的应用策略。GTK 上二者可能不同；外部用户或 WM 也可以改变观测状态。再次设置相同策略仍会纠正已观测到的外部变化；它不会自动强制覆盖用户选择。`setFullscreen(false)` 和 `setAlwaysOnTop(false)` 可撤销请求。外部进入全屏而无框架快照时，离开全屏交由 WM 恢复原生几何。Windows 由同步原生转换更新二者。

GTK 的状态通知与配置通知独立到达，已观测到 fullscreen 不表示同一次回调中的客户区已经改变。依赖完成几何的工作须同时等待目标状态和实际 bounds，不依赖两类原生事件的先后顺序。

Content 收到去重的 `Event.window_state: WindowState`；相同快照不重复通知。应用先用 `state()` 查询当前值，再由事件推进依赖实际状态的工作。原生操作可同步触发回调，因此事件可能在 setter 返回前到达。请求正在同步修改时，回调中再次调用几何、全屏、置顶或 `perform` 返回 `Busy`；读取状态和请求关闭仍安全。需要后续变更时显式 `App.post`。

`Event.window_position` 单独通知原生父几何可能变化，供原生内容更新parent-position依赖；Windows来自WM_MOVE，GTK来自configure-event，可能与resize一起到达。该通知不提供坐标、不承诺精确去重，也不在Wayland虚构全局位置；空闲不检查位置。

状态事件和 resize 事件都固定窗口记录；回调中关闭沿用安全点销毁、一次 detach、最后 `on_closed` 的契约。诊断 sink 同样在固定作用域内运行。Zig 几何、全屏与置顶 API 没有操作期堆分配；GTK/X11 的置顶观测在属性变更事件中有界读取最多 256 个原生 atom，及时释放原生缓冲，查询与绘制直接使用缓存。

## 所属窗口与模态

```zig
const editor = try app.createWindow(.{ .title = "Editor" });
const dialog = try app.createWindow(.{
    .title = "Settings",
    .owner = editor,
    .modal = true,
});
// 挂接内容后显示；不会运行嵌套消息循环。
try dialog.perform(.show);
```

`owner` 在创建时固定，必须是同一 App 的存活窗口。`modal = true` 必须提供 owner，否则返回 `OwnerRequired`；不同 App 返回 `ForeignApp`，过期或关闭中的 owner 返回 `Closed`。`capabilities().owned_windows/modal_windows` 明确平台支持。Windows 使用原生顶层 owner，GTK 使用 transient-for 和每棵所属树独立的 window group。所属窗口仍是独立顶层窗口，不嵌入 owner 客户区。

隐藏的模态窗口不阻塞输入。成功 `perform(.show)` 后，它成为所属树最新的活动模态窗口；整棵树仅该窗口及其后代可交互。中间允许穿过非模态所属窗口，多个分支按最后显示的模态窗口决定。无关系的根窗口不受影响。`relationship()` 返回直接 owner、创建时 modal、当前 modal_active 及直接活动模态子窗口数量；嵌套计数独立保留，隐藏或关闭最新模态窗口后恢复先前分支。

`WindowState.enabled_requested` 保存应用显式 enable/disable 的意图，`modal_blocked` 表示关系策略的阻塞，`enabled` 表示实际原生启用状态。模态阻塞不能通过 `perform(.enable)` 绕过；解除模态后仍保留应用原先的禁用意图。Core 同样拦截阻塞窗口的内容输入，覆盖直接投递的原生消息。

`perform(.focus)` 对模态阻塞窗口返回 `ModalBlocked`，应用禁用窗口返回 `Disabled`。`focusTarget()` 查询当前可交互的目标。隐藏或关闭当前活动所属窗口时，Core 尝试恢复 owner 或其当前模态目标的焦点。焦点受操作系统限制：Windows 可返回 `FocusDenied`，即使本线程键盘焦点已经移动；GTK 向 WM 提交激活请求，须由后续状态事件确认。自动焦点恢复是尽力操作，关闭过程不会等待激活。

## 弹出窗口角色

`WindowOptions.popup = .{ .focusable, .topmost, .shadow, .handler }` 在创建时把 `.borderless` 窗口设为弹出窗口（浮出窗口、菜单式列表、悬停卡片）：没有任务栏和分页器条目，用户不能移动或缩放；非 `.borderless` 或模态返回 `InvalidPopup`。可以有 owner，此时它在 owner 之上并随 owner 关闭。非 focusable 的弹出窗口显示、`perform(.focus)` 和指针按下都不改变活动窗口；focusable 的显示时取得键盘，失去键盘（Windows 激活离开，且新活动窗口不是它或它拥有的窗口）或 Linux 上外部按下、抓取被打断时，Core 在安全点调用 `handler.dismiss`。owner 报告 `resize`/`window_position` 后，Core 依次调用其弹出子窗口的 `handler.owner_moved`。任何弹出窗口在 Content 未消费的无修饰 Escape 上按 `requestCloseFrom(.user)` 关闭。放置与驳回策略由 `ziggurat_system` 的 `Flyout` 实现，见[系统工具](system.md#浮出窗口)。

## 关系树关闭

`requestClose()` 先检查目标及全部后代；目标收到原始 `CloseReason`，后代收到 `.owner`。任意仍存活窗口否决，则不开始此次树关闭。`App.requestQuit()` 同样先检查全部窗口，使用 `.quit`。预检回调中再次请求关闭/退出返回 `in_progress`，创建窗口返回 `CloseInProgress`。无条件 `destroy()` 与 `quit()` 仍绕过否决。

通过预检后按后代优先关闭，后代 Content detach 和 `on_closed` 全部完成后才通知 owner。直接调用原生销毁也会关闭存活后代；关系记录固定到最后一次通知，不会访问复用槽位。回调中销毁依旧延迟到安全点，无嵌套消息循环。

原生销毁失败会重新开放仍存活的窗口及关闭中的祖先，恢复仍可见模态窗口原有顺序和阻塞策略；已关闭后代不会复活。诊断保留失败时的原生错误码，应用可重试。GTK 最后一个本方组成员销毁时，以持引用的原生窗口快照解除辅助窗口对本组及 transient 的借用，不销毁辅助窗口本体。

关系链接/移除为 O(1)，无模态时的输入查询也是 O(1)。模态策略变化按存活关系树更新启用缓存；普通输入与绘制读取缓存，不扫描窗口历史。深树关闭使用迭代后序队列，不递归、不增加 Zig 关闭期分配；GTK 组终止时的辅助关系清理属于原生关闭路径。

## 键盘消费边界

`Content.key_input` 可选回调接收 `KeyInput { key, modifiers, repeat }`，返回 true 消费此次 key-down，阻止对应的旧 key/edit 与文本转换。未提供回调时保留旧事件路径；Core 不自动额外调用 `Content.event(.key_input)`。UI 模块的 consumer 可把这个事件交给应用观察，再决定是否消费。

`KeyCode` 是当前键盘布局去掉 Shift/Lock 后的逻辑键；例如 Shift+1 对应 `digit1`，Shift+字母仍对应小写枚举，同时 `modifiers.shift = true`。文本由原生文本/输入法事件提供，不能由 KeyCode 推导。枚举覆盖字母、数字、F1…F24、导航与编辑键、常用标点、数字键盘、媒体音量及浏览器键；无法表示的布局符号为 `unknown`。`modifiers` 保留 shift/control/alt/super，GTK 不把未消费的 Alt/Super 组合降为无修饰编辑或普通文字。

Windows 主消息循环先验证本方 window class 与所属线程，在 `TranslateMessage` 之前调用 consumer；消费后跳过 Translate/Dispatch，裸字符快捷键不会额外插入字符。直接 SendMessage 也有相同优先级的回退，两条路径每次消息只调用一次，consumer 先于普通原生 service 键消息。GTK 在 IM filter 之前处理 consumer，以硬件码和当前 layout/group 计算去 Shift/Lock 的逻辑键。正在组合的 IME 优先；AltGr 文本不当作 Control+Alt 快捷键。回调沿用 Window pin，回调中关闭会阻止继续向旧窗口发送编辑事件。

## 无边框与自定义标题栏

```zig
const TitleBar = struct {
    fn hit(_: *anyopaque, _: z.Window, point: z.Point) z.WindowHit {
        // 按钮、编辑器等交互区应返回 client。
        return if (point.y < 32) .caption else .client;
    }
};
const window = try app.createWindow(.{
    .decoration = .custom,
    .resizable = true,
    .resize_border = 6,
    .hit_test = .{ .context = &title_bar, .query = TitleBar.hit },
});
```

`decoration` 在创建时固定。默认 `.system` 保留原生装饰，不调用自定义命中回调；同时指定 `hit_test` 返回 `InvalidWindowDecoration`。`.borderless` 去掉系统装饰，无自动缩放边缘；`.custom` 同样由应用绘制客户区，并在客户区内预留 `resize_border` DIP 的八方向缩放边缘，默认 6，可设置为 0…64。预留边缘先于应用回调，窄窗口会把边缘限制到尺寸的一半。`resizable = false` 禁止用户缩放和原生最大化命令；程序显式几何设置仍沿用原有 API。

`HitTestHandler.query` 接收客户区 DIP 坐标，返回 `.client/.caption/.system_menu` 或八方向边缘。回调的 context 由应用持有，成功创建后必须保留到 `on_closed`；Content 替换不会改变它。回调应同步、短小且不阻塞，不在查询中分配或读取磁盘。`Window.hitTest(point)` 使用同一策略；递归查询直接返回 `.client`，不会再次进入 handler。关闭、禁用、模态阻塞和全屏时命中降为客户区；最大化或禁止缩放时忽略缩放命中。回调返回前若窗口状态变化，会重新检查策略，防止旧结果继续触发原生操作。

标题栏文字、关闭/最小化/最大化按钮及其焦点、快捷键与可访问性由应用内容负责。按钮区域返回 `.client`，再调用 `perform` 或 `requestClose`；`.caption` 区域交给系统拖动及双击最大化策略。此 API 不提供系统绘制的标题栏按钮或 Windows Snap Layout 按钮浮层。Windows 自定义最大化客户区使用显示器工作区，全屏使用完整显示器；缩放边缘、最小客户区和跨 DPI 几何沿用 DIP 规则。自定义装饰下附加的 Win32 原生菜单当前只预留一行系统菜单栏高度，多行折叠菜单栏未支持；此限制不影响单独的系统窗口菜单。

| 能力 | Windows | GTK/X11 | GTK/Wayland |
| --- | --- | --- | --- |
| `custom_decoration` | 支持 | 支持 | 不支持，创建非 system 装饰返回 `UnsupportedCapability` |
| `native_move_resize` | 支持 | 由 WM 的 `_NET_WM_MOVERESIZE` 决定 | 不支持 |
| `system_menu` | 支持 | 由 WM 的 `_GTK_SHOW_WINDOW_MENU` 决定 | 不支持 |
| `transparent` | 未实现，false | 未实现，false | 未实现，false |
| `backdrop_material` | `.system` 装饰且 Windows 11 build 22621 及以上 | 不支持 | 不支持 |

`Window.setBackdrop(material)` 选择合成器在原生系统框架后绘制的材质：`.mica`、`.acrylic`、`.mica_alt`、`.none`，或 `.system` 恢复平台默认。Windows 用 DWM 的 system backdrop 窗口属性实现，在主线程同步提交；能力按进程读取一次的真实系统版本与窗口装饰判断，不支持时在任何原生调用前返回 `UnsupportedCapability`，原生拒绝返回 `WindowUpdateFailed` 并保留 HRESULT 诊断。框架不保存所选材质，也不在关闭后恢复；宿主需要跨启动保留时自己存储。材质只出现在系统标题栏/边框等非客户区，客户区仍由现有渲染器不透明绘制；`.borderless/.custom` 没有系统框架，因而报告不支持。系统可能因电源模式、透明效果设置或窗口失焦以纯色替代材质，这属于系统策略。

客户区透明（`transparent`）仍未实现：它需要渲染器输出预乘 alpha 并改变整窗合成方式，不能只靠窗口属性完成。无边框能力不表示具备透明合成、模糊或背景材质。X11 无 WM 时仍可创建无边框窗口，但不能据此认为原生拖动、缩放或系统菜单可用；调用前查询每窗口的 capabilities。不支持的操作明确返回 `UnsupportedCapability`。Openbox 验证环境支持移动/缩放，未公布系统窗口菜单协议。

## 原生交互与重入

内容可在本窗口当前的原生 `pointer_down` 回调中调用 `startMove()` 或 `startResize(edge)`。这会借用当前按下事件一次；同一按下不能重复消费，也不能交给其他窗口或留到 `App.post` 中使用。无有效事件返回 `InvalidGesture`。失焦、隐藏、禁用、模态阻塞和关闭会使借用及排队命令失效，之后重新获得焦点或启用不会恢复旧命令。Windows 原生移动消息使用有符号 16 位屏幕坐标，超出该范围的按下仍发送普通内容输入，但不能作为该原生交互的手势。

`showSystemMenu()` 在 Windows 可显式请求菜单；GTK 的菜单请求还需要当前有效原生按下事件。所有入口先检查关闭、实际启用、模态、可见及全屏状态；最大化或禁止缩放时拒绝 `startResize`。Windows 已有排队交互或正在原生移动/缩放/菜单循环中时返回 `Busy`。在 X11 上，成功表示 GTK 向 WM 提交了操作，不表示窗口已经移动；依赖结果的工作应等待实际 bounds/resize 事件。

Windows 把接受的交互放入本窗口的私有消息，使用单调序号匹配一次请求；失效的旧消息不能消费后来请求。提交时和执行前均检查策略。系统的移动、缩放和菜单本身会进入原生嵌套分发，框架不自行泵消息。调用系统默认处理之前先结束当前 Zig callback scope，再确认原生窗口仍属于同一代记录；嵌套回调各自固定记录，因此已接受的 `App.post`、关闭和退出可在系统交互期间到达安全点。退出同时请求取消当前原生交互，不等待用户释放鼠标。

普通查询、命中和绘制不增加 Zig 分配或轮询。GTK 缩放光标在创建时构造、销毁时释放，移动事件只切换已有光标。原生回调中关闭仍保持一次 detach 和最后 `on_closed`，不会把旧手势交给复用的窗口记录。

## 运行期枚举与查找

`App.listWindows(output)` 在调用者数组中返回当前 open 窗口的值句柄快照，顺序未指定。容量不足返回 `OutputTooSmall`，不改写任何输出；关闭中窗口不进入快照。只遍历当前活动链两次，O(n) 且无分配、原生调用或业务回调，不扫描历史槽位。快照不固定窗口生存期，迭代时可显式关闭或新建窗口；使用返回句柄仍遵守普通 generation 检查。

`App.findWindow(window.diagnosticId())` 用槽位和代数在 O(1) 查找同一个 App 中仍 open 的窗口，关闭中、已回收、旧代数或不存在的身份返回 null。身份只在原 App 使用期内有效，不能跨 App 或用于磁盘上的文档身份。应用自行保存文档 ID 与窗口运行期身份的映射。App 必须覆盖所有返回句柄的使用期。

焦点继续使用 `window.perform(.focus)` 和 `focusTarget()` 的模态树规则；OS 可以拒绝抢占前台。枚举或查找本身不激活窗口。显示器约束、离屏恢复和版本化窗口状态持久化继续属于 W04 的后续分项，不能把运行期 ID 持久化来恢复窗口。

## 验证

`zig build smoke-window-policy` 在隐藏窗口上核对运行期窗口策略落到原生窗口：Windows 的样式位、系统菜单关闭项、分层透明、指针穿透、显示亲和性与标题标记；GTK 的 resizable/deletable、透明度（有合成器时）、urgency 与 skip-taskbar hint。

`zig build smoke-window-state` 在 Windows 未激活的独立 desktop 上检查尺寸/位置、普通与最大化/最小化全屏还原、置顶、菜单、隐藏状态和回调内原生销毁。不会切换用户桌面。

Linux 在隔离 Xvfb 和支持 fullscreen/above 的 WM 下运行 `zig build smoke-window-state -- --require-wm`。测试仅由正式状态/resize 事件推进，要求实际 WM 状态及 bounds 还原；没有 WM 时该参数明确失败。省略参数可验证当前显示环境中不支持操作的失败路径；Wayland 的隐藏窗口检查覆盖无位置与无置顶能力，不代表已验证 Wayland 全屏运行。测试含有界 watchdog，结束后核对原生资源归零。

`scripts/linux-window-state.sh` 在 2560×1600 物理像素的隔离显示中依次运行状态、关系和装饰检查。另以 `GDK_SCALE=2` 运行同一脚本可检查 2 倍缩放；该桌面尺寸保留足够逻辑空间容纳测试几何及系统装饰。全屏检查要求状态与显示器完整逻辑 bounds 都已确认。

`zig build smoke-window-relationships` 验证真实 owner/transient、跨非模态层的多个模态分支、原生禁用与焦点恢复、后代否决、子窗口优先通知及原生销毁重入。Windows 使用未激活的独立 desktop；Linux 在隔离 WM 下使用 `-- --require-wm`，连续创建多轮 App，逐轮核对 GTK 原生资源归零。单元测试另覆盖原生 show/destroy 失败、模态顺序恢复、关闭预检重入与无分配的千层关系树回收。

`zig build smoke-key-input` 使用隐藏原生窗口验证逻辑键/修饰/重复、AltGr 和输入法组合优先、回调关闭。Windows 另验证 direct/queue 的 consumer 与 service 次数、外部 HWND 不被当成本方记录；GTK 使用真实 IM simple 的组合流程及本机 keymap 验证 Shift 逻辑键。控件集成的 `smoke-widget-ranges` 检查消费裸字符快捷键后无额外文字、编辑器 Space/Enter 及普通文本各走一次。没有以这些检查声称覆盖全部输入法或物理键盘布局。

`zig build smoke-window-chrome` 检查自定义客户区、DIP 命中/最小尺寸、最大化/全屏来回还原和命中回调中的原生销毁。Windows 在未激活 desktop 的独立子进程中实际进入移动、缩放和系统菜单循环，核对循环内投递的关闭/退出任务各执行一次，并覆盖公开手势排队及禁用、模态、失焦后的旧命令失效。子进程退出后释放 desktop，不切换用户桌面。同一测试比对独立读取的系统版本与 `backdrop_material`：支持时依次提交五种材质并在 DWM 允许读回时核对原值，不支持或非系统装饰时核对 `UnsupportedCapability`，关闭后返回 `Closed`。这不建立材质的视觉效果结论。

Linux 在隔离 Xvfb/Openbox 下使用 `zig build smoke-window-chrome -- --require-wm`；该参数要求实际移动/缩放和全屏能力。独立输入驱动进程通过 XTest 触发真实按下，再由内容调用 `startMove/startResize`，必须同时观察到 WM 改变位置和宽高才能通过。运行此测试需要 `libXtst.so.6`，它不是框架生产依赖。测试只在专用 DISPLAY 中运行；无 WM 时不把已提交的输入当作操作完成。

单元测试验证尺寸和能力失败不修改几何、原生失败可重试、过期句柄、重入 Busy、通知去重、无 Zig 操作期分配，以及关闭回调的保留与回收。隐藏或隔离原生检查不证明视觉质量、多显示器 DPI 或所有 WM 的兼容性。

`smoke-window-registry` 在真实隐藏窗口中创建/关闭 400 个窗口，验证有界快照、callback pin 中关闭、槽位复用和旧身份查找拒绝；完成时 records=0、槽位峰值=3。单元测试另验输出容量事务，以及对旧快照边迭代边关闭/替换，避免借用原生记录指针。

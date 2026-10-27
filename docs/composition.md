# 窗口内容组合

`ziggurat.composition.Owner` 是窗口唯一的 `Content` 所有者。它不依赖 UI 或 WebView；可选模块通过 `Participant` 接入。一个窗口只有一个 Owner，一份 participant 同时只能由一个 attachment 拥有。当前区域组合仍在实施，不能将此生命周期层当作完整的混合渲染、焦点或可访问性实现。

```zig
const owner = try z.composition.Owner.create(allocator, window, .{ .capacity = 16 });
const region = try owner.reserve(.{
    .bounds = .{ .x = 160, .y = 40, .width = 480, .height = 320 },
});
try region.attach(participant);
```

App、Owner 和 participant 使用进程主线程。Owner 复制 participant 的回调表，借用其 context；context 保持稳定直到真正的 detach 返回。Owner 必须长于所有 Region 句柄的使用，包括查询过期句柄；`close` 后不允许继续访问任何副本。Owner 不持有页面、文本、图片或渲染器。

## 区域与回调寿命

`reserve` 取得一个有界空槽，`Region.attach` 执行 provider 的 attach 事务。attach 期间的暂定 Region 可取得 snapshot 和 callback scope。provider 返回错误时自行回滚候选资源，Owner 不再调用 detach；空槽仍归宿主，可重试 attach 或 remove。attach 成功后，Owner 承担恰好一次 detach，包括 attach 回调中同步 remove 的情况。remove 不会被成功返回复活。

`Region` 是 Owner、slot、generation 的值句柄。槽复用增加代数，达到上限后永久停用该槽，绝不回绕。`remove` 立即使句柄失效，新 snapshot、update 和 callback 入口返回 Closed。已取得的 `Scope` 同时 pin 区域和真实 Window；最后一个 scope 与组合事件退出后才调用 provider.detach。detach 收到的 Region 已失效，应使用 provider 自己保存的资源和 Window。未退出的回调不能释放自己的 context。

通过原生异步入口、公开资源方法或业务 responder 访问区域拥有的 participant 时，要先取得对应 Region scope，并在可能重入的业务回调后重查 attachment 是否仍有效。只 pin Window 不足以保护区域：区域已被移除时，窗口可能仍然打开。独立 PageSession 的普通页面回调由 App/Session scope 保活，只有挂载、停放和几何操作另取 Region scope，页面不依赖旧区域继续存活。scope 是线性 guard，必须恰好 end 一次，不复制、不跨线程保存。

暂定 attach 在普通事件之外还可收到 native_parent_destroying，用于父原生窗口同步销毁时撤离已创建的子树；attach 失败仍由 provider 自己回滚。通知也包含已移除但仍待 detach 的 provider，由内部 scope 保活；只做缓存 transport 的有界原生撤离，不进入 COM/业务回调，见[应用停止契约](application-resources.md)。

Owner.detach 在没有活动 callback/事务时同步撤销 Window.Content 并关闭全部区域，否则返回 Busy。窗口关闭通过核心既有安全点在 callback pins 退出后执行相同 teardown；所有 native 区域按反向保留顺序 detach，最后 detach 全窗 backdrop。之后宿主可以 Owner.close 释放槽存储，例如在 on_closed 中；close 不主动关闭窗口，也不替宿主释放 participant。

## 布局、输入与成本

Viewport 的 bounds 使用窗口客户区 DIP，visible 显式控制可见性，允许空区域；坐标和末端必须有限且在 ±1,000,000 内，宽高不得为负。update 的 provider 回调负责原生候选和失败回滚，成功后才发布新的逻辑 viewport。相同值不调用 provider。snapshot 同时包含真实 Window、viewport、kind 和当前物理客户区 Size/scale；`Window.contentSize` 可在 paint 外查询原生尺寸。

最多保留一个全窗 backdrop，其 viewport 随真实 resize/paint 自动更新。事件仍使用原始窗口 DIP 坐标和 Paint，不自动变换或裁剪任意 renderer。全窗背景先收到 paint，随后才通知区域；本片不提供全场景绘制事务，也不使多个 renderer 的前端提交原子化。原生 windowed 内容仅承诺矩形区域，airspace、透明覆盖、任意 clip 和 GPU composition 需要后续后端实现。

pointer 按区域保留顺序反向命中；按下后的 move/up 继续发给同一个捕获区域，取消、隐藏、零面积或移除撤销捕获。隐藏/零面积成功提交后发送取消和失焦，并通知仍存活的键盘接收者；失败更新保留原状态。原生 child 自己消费的输入不会由父窗口复制。Owner.focus 只选择父窗口事件的显式键盘接收者；它在完整 callback pin 下发送失焦/聚焦，嵌套 focus 返回 Busy。原生焦点、跨 surface Tab/IME 与完整混合输入仍需独立接线和验收。可访问性入口首片只转发 backdrop，不宣称已有组合可访问树。

原生位置变化通过 window_position 广播；Windows来自WM_MOVE，GTK来自configure-event，后者可以同时伴随resize。它只表示原生父几何可能变化，不承诺Wayland屏幕坐标或精确去重，provider可据此更新原生parent-position依赖。没有周期性位置检查。

Window.TextClient目前仍由宿主显式bind/unbind，独立于UI.Context。移除含编辑器的backdrop前，宿主需要解除对应Editor/DocumentEditor绑定；只移除UI不会替宿主猜测并撤销当前文本客户端，仍绑定的Adapter也会拒绝close。区域级文本客户端归属继续在混合输入任务中实施。

默认预留16槽，硬上限256，create 只分配 Owner 和槽数组。普通事件、reserve/attach 元数据、update/remove 和 scope 不做框架分配；provider 的资源成本另计。事件快照使用固定栈，新增区域不加入已开始的同一次广播，删除区域后不再发送。活跃链与固定容量槽扫描独立于历史复用次数；无 worker、周期计时器或空闲刷新。

## 验证

`zig build test-core` 包含窗口单所有者、attach/update 故障事务、暂定区域移除、代数复用、callback remove、focus 关闭重入与所有 Owner 分配故障。`zig build smoke-composition` 在真实窗口进行1000次区域复用/更新/移除、10次持 pin 原生关闭，注入分配器禁止 Owner 后续分配，检查1010次 attach/detach 配对和窗口记录归零。

## 内容适配

`ui.Context.attachBackdrop(owner)` 保留全窗背景并使用既有 Frame/资源事务；当前显式选择 `.gdi`，Windows 对应 GDI、Linux 对应 Cairo。Windows GPU child 与浏览器 child 的遮挡还未验收，因此拒绝自动/hardware/warp 模式。普通 `Context.attach(window)` 继续使用原来的单 Content 路径。`smoke-composition-ui` 检查实际像素、输入、resize、失败帧、UIA 失效和分配器重入关闭；Windows Debug/ReleaseSafe、Linux Debug/ReleaseSafe 及 Linux 2x 已通过。

Windows `web.View.attachRegion(region, options)` 将一份稳定 View 接到 native 区域，不占用第二个 Window.Content。DIP 边缘只按当前 scale 舍入一次；bounds/visibility 原生更新失败回滚两项，回滚失败关闭 controller 并报告失败。异步 controller 创建、reload/recover 都使用最新已提交的区域几何。`window_position` 显式通知 SDK 父窗口位置变化。

旧 View 路径隐藏保留页面和 PageId；remove 关闭 controller、终结请求并使 PageId 失效，最后一个 scope 退出后才完成 detach。同一 View 可以重新 attach，文档代数继续增加。需要跨宿主保留 DOM 时使用独立 [PageSession](pages.md#离窗页面会话)：移除旧 Region 只停放页面，旧 provider detach 完成后显式 attachRegion。它拥有自己的 bridge/parking HWND，原生 controller 不改固定父窗口；App停止先关闭页面资源再完成旧provider detach。所有公开提交、结果转换和 responder 仍按其所有者重查入口；分配器回调中 remove、导航或关闭不能把旧结果提交到新页面，失败不接管调用者拥有的参数。

`zig build smoke-composition-webview -Dwebview=true` 在同一个真实 HWND 上组合 GDI 背景与两个 WebView，验证 child 原生几何/可见性、独立 DOM marker、单页 reload、移动/resize、pending 创建时移除及立刻复用、ready/resource 回调移除与请求终结。最终 COM/controller/deferral 和背景资源归零。该检查已在 Windows ReleaseSafe 通过，不包含人眼视觉质量、任意 overlay 或跨 surface Tab/IME 验收。

运行 `zig build run-rectangular-pages -Dwebview=true` 可查看[双页面示例](../examples/rectangular_pages.zig)：隐藏左侧保留计数，关闭后重新打开创建新文档，右侧页面独立运行。每个页面使用独立用户配置目录。

声明式视图里的页面见[视图中的 WebView](embedded-webview.md)：`ziggurat_webview_view` 用 Host 的 `after_frame` 钩子把每个页面区域放在其叶子的 bounds 上，未构建的页面隐藏并保留。

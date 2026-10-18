# 应用资源与停止

窗口之外的原生资源可以通过 `App.registerStop(*StopParticipant)` 交给应用退出协议。节点由资源自己持有，地址稳定；App 只保存侵入链表，没有参与者表或注册分配。默认最多256项，可用 `AppOptions.stop_capacity` 调整，硬上限65536。注册/取消为 O(1)，停止只遍历当前参与者，没有空闲扫描或计时器。

```zig
var stop_node: z.StopParticipant = .{
    .context = &resource,
    .stop = Resource.stop,
};
const token = try app.registerStop(&stop_node);
```

App、节点和 context 的生存期覆盖注册。`stop(context) !void` 在主线程运行，执行有界、非阻塞的关闭。成功后核心不再访问节点，因此回调可以在最后一步释放自己的整个存储。失败必须保留节点注册字段、context 地址和 stop 函数；业务 context 可以记录已完成阶段，重试不得重复终结逻辑请求。原生错误码由资源在失败现场按值报告，App 的 `app_stop` 诊断只记录返回的 Zig error，不猜测之后可能已被覆盖的原生码。

普通关闭可以调用 `App.cancelStop(token)`：返回 true 交还停止责任，调用者随后自行关闭资源；该操作本身不关闭资源。false 表示不匹配，不能据此释放正在关闭的资源。`StopInProgress` 表示节点已被本次停止批次接管或上次停止失败，存储必须保留，不能通过取消抢先释放。Token 借用 App 和节点；取消成功后若释放节点，所有 Token 副本均不能再使用，包括查询旧 Token。代数只防仍存活节点重新注册后的旧身份复活。

## 停止顺序与失败

`quit` 接受关闭后立即 seal 注册入口、撤销 native waits 并关闭 post 队列。shutdown 先执行全部已接受 post，恰好一次；已经接受的任务仍可以取消尚未接管的注册并自行清理。随后先将整批参与者标为 taken，再按注册逆序执行停止，最后完成普通窗口销毁、Content.detach、Cleanup 和 backend 关闭。应用主动关闭或直接销毁原生窗口可以早于该自动顺序。

任务在 dispatcher 内调用 quit 后，该轮剩余已接受任务仍执行，但 dispatcher 不再提前清理它们请求的 deferred 窗口或 Cleanup；由 shutdown 统一先停止参与者，再完成这些销毁。停止失败时原生窗口及其内容继续保留，finishShutdown 重试不会重放任务。主动直接调用原生销毁仍遵循前述提前关闭边界。

Windows 的移动、缩放和菜单循环也遵循该顺序。quit 只释放根窗口属于当前 App 的鼠标捕获，让原生循环返回后进入统一 Stop；同一线程上的其他 App 或宿主窗口保留自己的捕获。原生取消可以同步重入，平台层不跨越该调用保留 WindowRecord 指针。

已经 stopped 的 App 仍能在普通 dispatcher 安全点执行迟到的 mandatory Cleanup；这不会重新开放 post 或重放 Stop。App 必须活到这些释放完成，业务生产者仍由宿主停止并 join。

一个 stop 请求关闭另一项尚未执行的参与者时，后者保留存储直到自己的 stop 回调。整个批次继续执行，收集第一个错误；本次每项只尝试一次，没有自动重试或轮询。失败时 App 保持 stopping，原生平台仍存活，失败节点仍归 App，未执行自动窗口销毁。已经成功的停止和 post 不会重放。

`run` 可以返回停止错误。宿主修复失败资源的条件后，显式 `try app.finishShutdown()` 再推进一次；它只接受 stopping，stopped 幂等，回调/dispatch/deinit 中返回 Busy。成功后仍需 join 自己的生产者，最后 deinit App。`deinit` 会尝试完成关闭，仍失败则 panic，不能释放仍被资源借用的 App。

参与者不是主循环 keepalive。零窗口应用仍按既有策略退出，随后停止这些资源；停靠窗口或后台会话不能通过注册悄悄维持运行。

## 回调作用域

`App.beginCallback() ?AppCallbackScope` 固定应用活动，不创建或固定 WindowRecord；stopping/stopped 拒绝普通新入口。`App.beginTeardownCallback()` 专供 close/detach，在 stopping/stopped 和 deinit 的 stop 回调中仍能保活 App，但不授权创建窗口、投递任务、注册 watch 或新业务操作。调用者必须保留各自入口的关闭检查。

两种 scope 都在主线程使用，是必须恰好 end 一次的线性 guard，不能复制、跨线程保存或在 App.deinit 后访问。回调中不得析构 App。scope 只固定寿命，不自动取消 worker、保持应用运行或处理业务结果；宿主仍负责显式线程与结果交接。

## 父原生窗口销毁

`Content.native_parent_destroying` 是可选的早期通知；composition 同步转发到仍持有 provider 的区域，包括暂定 attach 和已移除但尚未 detach 的区域。attach 失败仍由 provider 自己回滚，不因收到早期通知转移 detach 责任。

Windows 在 WM_DESTROY 同步调用通知，此时原生子窗口仍在。provider 只能使用事先缓存的 transport 做有界 Win32 隐藏/撤离和失效标记，不分配、不调用 COM 或业务回调；Window/Region 已 closing，不能再通过 snapshot/beginCallback 取正常入口。其他平台的通知不承诺 Windows 子树顺序。

核心内部固定 Window/Content，composition 固定 provider，但早期通知自身不触发普通 detach；真正的 COM、请求终结与 closed 通知仍在普通安全点结算。单一 WindowService 继续用于菜单/托盘，不被内容撤离占用。

`zig build test-core` 包括批次接管、失败重试、自释放、满队列、作用域及暂定 attach 回滚。`zig build smoke-app-stop` 验证真实主循环和256项已接受任务；Windows 另在真实 WM_DESTROY 下从暂定/移除区域撤离子窗口，on_closed 立即释放 Owner，最后参与者/窗口记录归零。该检查不创建浏览器 controller，不证明 DOM 保留或混合输入。

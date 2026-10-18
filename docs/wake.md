# 主线程单次唤醒

`ziggurat_wake.OneShot` 是独立可选 owner，依赖核心。Windows 使用一个 synchronization waitable timer 和 App 的有界 native wait 注册；Linux 使用默认 GMainContext 上的一个自定义 GSource。它不创建窗口、线程、业务 post 或事件循环，不自动保活 App，也不生成周期性 timer。

```zig
const timer = try wake.OneShot.create(app, allocator, .{
    .context = stable_context,
    .fire = onDeadline,
}, .{});
const first = try timer.armAfter(16_666_667);
const replacement = try timer.armAfter(8_333_334);
std.debug.assert(!try timer.cancel(first));
_ = try timer.cancel(replacement);
_ = try timer.close();
```

成功 create 后 Timer 地址固定；allocator 和 callback context 必须覆盖最终关闭。所有入口先校验创建主线程，再访问 App/native。`armAfter` 接受1ns–1小时，以不回绕 generation 返回 Token；重新 arm 替换旧截止时间，旧 Token 不能取消新的 arm。无效参数或代数耗尽保持旧状态；native arm/watch 失败则明确撤销本 owner 的活动期限。Windows 的16个 native wait 槽与其他设施共享，容量不足返回 TooManyWaitables。App stop participant 容量也独立生效，注册失败回滚候选 native 对象与壳。

fire 前先撤销本次 armed 状态及 wait token，callback 可同步重设下一次截止时间。没有再次 arm 就没有下一次唤醒；cancel 只撤本次期限，保留可复用 owner。相对期限按 Windows 100ns、GLib µs 的 API 单位向上取整，实际交付精度与延迟由 OS/硬件/主循环调度决定，不承诺纳秒级显示时序。动画应在 callback 用自己的单调时钟重新采样，跳过迟到帧，无需逐帧追赶。

Linux source 在 dispatch 前重查当前 ready time：另一 source 在主循环已选中它后 cancel/rearm，不会把旧到期错误交给新一代期限。自定义 dispatch 自行清 ready time，普通 GSource timeout 的重复行为没有参与。取消后 source 不因时间流逝而唤醒，不在 idle 轮询检查截止时间。

## 关闭与停止

`close` 先撤入口、取消 wait/source/native handle。在自己的 fire callback 内返回 deferred，callback 退栈后才释放 Zig 壳，并可执行可选 `on_closed` Task；普通 close 返回 closed。on_closed 只对应成功构造后的最终显式关闭，且只通知一次，可以立即释放包含 allocator context 的整个宿主对象。已经开始关闭时的 allocator 重入得到 Closed；最终通知后不得再使用 Timer 指针。Linux 当前 C dispatch 仅保留独立 native 尾部引用，释放后不再访问 Zig 或业务 context。

App stop 取消并释放 native 资源，清除 Timer 的 App 借用，保留宿主拥有的壳，不触发 deadline callback。之后仍须 close；这一步可以在 App.deinit 后执行。若 App 已 take stop 节点，抢先 close 返回 StopInProgress，责任仍由 stop callback 完成。callback/native/allocator 期间的 App scope 保持 App 寿命，不能在这些调用内强行 deinit App。on_closed 和 fire 使用的上下文是显式借用，不会被丢进隐藏队列。

每个 owner 有固定 Zig/C 元数据与一个 native timer/source，显式 allocator 只负责 Zig 壳，系统内部对象另由 `nativeCounts` 观察数量，不冒充进程内存上限。关闭后计数归零；在 callback 内关闭时，C dispatch 的最后引用可能到原生退栈才归零。

## 动画接线与验证

将[动画](animation.md)的 nextWake 与宿主 now 相减，显式 armAfter；暂停/结束返回 null 时 cancel 当前 Token。只有业务值变化才使对应窗口或区域失效。纯动画模块不导入本模块，普通 App/UI 也不创建 Timer。

`zig build smoke-wake` 使用真实 Win32/GTK 主循环，验证动画按需重设、旧 Token、已选中 source 的重排/关闭、callback 关闭、App stop、App.deinit 后关闭壳、错误线程、stop Full/taken、Zig OOM、构造 allocator quit、释放 allocator 重入/finishShutdown Busy，以及 on_closed 立即释放整个宿主。结束后核对全部 native counts 与 DebugAllocator，无截图或人工视觉结论。

原生依据：[GLib 自定义 Source 的 ready time](https://docs.gtk.org/glib/method.Source.set_ready_time.html)、[SourceFuncs dispatch 合同](https://docs.gtk.org/glib/struct.SourceFuncs.html)、[Windows SetWaitableTimer](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setwaitabletimer)。

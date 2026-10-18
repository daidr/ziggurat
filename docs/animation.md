# 显式时钟动画

`ziggurat_animation` 是可选纯 Zig 模块。Channel、Timeline、Playhead 是调用者拥有的值，不保存 App、Window、allocator、业务 callback 或平台句柄。更新由调用者在自己的 update 阶段传入同一来源的单调纳秒时间；普通绘制只读取已准备的业务值。模块不创建线程、timer 或循环，不自动使窗口失效。

```zig
var channel = try animation.Channel.init(0);
try channel.retarget(now_ns, 1, .{
    .motion = .{ .spring = .{ .frequency_hz = 3, .damping_ratio = 1 } },
});
const current = try channel.advance(now_ns);
const wake_at = try channel.nextWake(now_ns, 16_666_667);
// 宿主将 current.value 写入业务状态；仅在变化时 invalidate。
// wake_at 为 null 时撤销自己的唤醒，否则显式安排一次截止唤醒。
```

## 数值与调度合同

Channel 支持 instant、tween 和 spring。tween 提供 linear、smoothstep、cubic_out 曲线及解析速度。spring 使用频率和阻尼比，分别求欠阻尼、临界和过阻尼解析解；每次从固定的 retarget 原点求值，跳过帧不补跑积分。临界附近使用 sinc/sinhc 稳定形式，过阻尼用衰减的两个特征根，避免先生成溢出的 cosh 再乘零。它是 f64 数值计算，不承诺任意参数的数学精确值。

retarget 先在指定时间采样旧运动，spring 默认继承该时刻速度，也可显式覆盖。tween 使用新曲线的速度。delay 在开始前保持当前值、速度为零；spring 在开始时使用保留的初速度。重复调用 retarget 会重新定义运动，宿主应只在目标或策略改变时调用。所有时间/参数错误都不发布部分状态。

输入 value/target/显式速度必须有限且绝对值不超过1e12；spring 频率0.001–1000 Hz，阻尼比0–1000，正的位置/速度阈值至多1e12。运动 duration、spring cutoff、delay 各至多一小时。spring 同时达到两个阈值才以 `settled` 停止；默认60秒的显式 cutoff 以 `deadline` 报告，即使无阻尼也不会无限请求唤醒。tween 到期报告 `finished`。cancel 停在当前值，jump 立即指定值。

`setReducedMotion(now, true)` 让活动运动立即到达目标，后续 retarget 也直接完成；恢复 false 不自动重放。它是宿主传入的策略，尚未自动读取 OS 可访问性偏好。`nextWake` 只返回时间，不读取时钟或执行工作；delay 直接返回开始时间，resting 返回 null。cadence 为1ns–1s，由宿主明确选择。过期但尚未 advance 的活动状态请求立即处理；时间倒退或不可表达的截止时间明确失败。

## 时间线与播放头

Timeline 在初始化时复制1–64个有明确 `at_ns`、from/to、Tween 的 Track，轨道可以重叠或错开，总时长至多一小时。输入随后可释放或修改。Timeline 保持不可变，`sample(index, position_ns)` 只计算指定轨道，不遍历全部轨道或访问业务对象。它共享 Channel 的曲线实现。

Playhead 单独拥有整数播放位置和单调时钟：play 从当前位置向指定方向继续，restart 从对应端点重播，pause 保持位置，seek 定位并暂停。任意长的调度间隔在一次 advance 中处理，不逐帧追赶。reduced motion 将播放直接移到当前方向的终点；暂停或终止后 nextWake 返回 null。轨道身份由宿主自己的字段/控件 ID 对应，模块没有全局 key 表或历史状态缓存。

暂停时可用`configureRepeat(.{ .iterations = 4, .alternate = true })`设置有限循环。默认一次，最多1,000,000次且总duration不超过1小时。当前position是首段起点，seek/restart重置完成次数，pause/play保留剩余次数；重复到边界时下一段立即开始，alternate在每个边界换向。advance通过整数除法一次跳过全部错过的段，仍为O(1)。reduce motion直接完成剩余序列，终点由最后一段方向决定，不需要为每段安排回调。总截止时间无法表示时play/restart保持完整旧状态。

Timeline.sample的velocity是对时间线位置的导数；反向Playhead对应的墙钟速度由宿主乘方向符号。它们是独立的值对象，时间线不借用或自动跟随某个播放头。

所有更新/采样均无分配、无 native 调用；Channel 和 Playhead 操作为 O(1)，Timeline 初始化 O(tracks)，单轨采样 O(1)。可复制值需要宿主独占访问，不能同时从两个线程修改同一份状态。原生期限使用独立[唤醒 owner](wake.md)，变化区域使用[局部失效](invalidation.md)，基础控件使用[显式主题](theme.md)；纯动画不依赖这些模块。变换命令和失效复用继续实施，G02 尚未完成。

## 验证

`zig build test-animation` 已接默认 test/check。测试包括独立临界闭式与 RK4 oracle、三类阻尼和临界相邻浮点值、固定原点的帧分割一致性、重定向速度、极端合法参数、delay/cancel/reduced motion、无活动唤醒、重叠轨道与源数组独立、暂停/seek/反向以及全部时钟边界事务。纯数学检查不替代原生 timer、显示延迟或 OS 偏好交互验收。

`zig build smoke-animation-ui` 将有限往返 Timeline、OneShot 和普通 Context 连接到真实原生队列。更新阶段只在数值变化时提交旧/新 bounds 的 damage 并显式安排下一次期限，draw 读取已准备状态；结束后的任务验证成功 Frame 的命中快照。Windows 与 Linux X11 2x 已验证普通/reduced-motion 序列、结束后不再 armed、App 停止与全部资源归零。测试允许系统合并 paint，不据此宣称每次期限对应一个显示帧、空闲 frame 数或显示延迟。

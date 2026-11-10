# 动画与唤醒

Ziggurat 没有持续重绘的定时器。窗口只在有原因时绘制：输入、状态变化、或者应用明确请求的某个截止时间。动画因此是“请求下一帧”，停下后什么也不调度，空闲窗口不消耗 CPU。

## 在视图中请求下一帧

声明式视图的每一遍都有一个时间（`View.time()`，单调纳秒）。构建函数用 `wakeAt(deadline)` 要求在某一时刻再运行一遍；一遍中最早的请求生效，没有请求就不再唤醒。

```zig
fn build(self: *Clock, v: *view.View) anyerror!void {
    const now = v.time();
    const second = now / std.time.ns_per_s;
    try v.textf("已运行 {d} 秒", .{second - self.started}, .{});
    v.wakeAt((second + 1) * std.time.ns_per_s); // 下一整秒再构建
}
```

看起来低帧率也平滑的动画（缓慢的波浪、电平表）用 `animationFrameRate(fps)`：下一遍落在整数个显示刷新之后，多个动画共用同一条时间网格。

Host 本身不持有计时器。`ziggurat_view_timer` 把最早的期限交给一个一次性计时器：

```zig
const view_timer = @import("ziggurat_view_timer");

var timer = view_timer.Timer.init(&host);
try host.attach(window);
try timer.attach(app, allocator);
// 关闭窗口或 App 之前：
try timer.close();
```

期限变化时它取消旧的计时器，到期后让窗口失效重绘；没有期限时不装定。

窗口完全看不见时不画帧：macOS 上隐藏、最小化的窗口，Windows 与 Linux X11 上最小化的窗口都收不到帧，动画请求的下一帧要等窗口重新露出来才画，那一帧带上期间的全部变化。Windows 与 X11 只告知最小化，Wayland 什么也不告知，所以被其他窗口遮住或在别的桌面上的窗口在这些系统上照常绘制。视图要在看不见时停下时钟、播放进度这类工作，用 `View.windowHidden()`（见[视图文档](../view.md)）。

## 视图内置的过渡

不需要自己写插值的常见效果，视图已经内置：

- `Style.opacity`、`Style.blur` 与位姿（平移、缩放、旋转）。
- `presentColumn(&presence, show, transition, style)`：内容出现与离开时的进出场，离开的内容在动画结束前继续显示。
- `popoverPresent`：带过渡的浮层。
- `scrollIntoViewWith(id, .{ .glide = tween })`：滚动时滑过去而不是跳过去。
- 共享元素过渡与位姿动画。

```zig
try host.prepareShaderEffects(allocator, library, .{}); // attach 之后，启用不透明度、位姿与模糊
if (try v.presentColumn(&state.panel, state.open, .{ .hidden = .{ .y = 12, .scale_x = 0.96, .scale_y = 0.96 } }, .{})) {
    try v.text("详情", .{});
    try v.end();
}
```

运动期间每遍自动请求下一帧，静止时不请求。系统要求减少动态效果时内容立即出现与消失。详见 [声明式视图](../view.md#不透明度、位姿与进出场)。

## 显式时钟动画

`ziggurat_animation` 是纯 Zig 模块：`Channel`（单个数值的 tween 或 spring）、`Timeline`（多轨道）与 `Playhead`（播放、暂停、反向、循环、拖动定位）都是调用者拥有的值，不保存 App 或窗口，也不创建线程或计时器。

```zig
const animation = @import("ziggurat_animation");

var channel = try animation.Channel.init(0);
try channel.retarget(now_ns, 1, .{
    .motion = .{ .spring = .{ .frequency_hz = 3, .damping_ratio = 1 } },
});
const current = try channel.advance(now_ns);
const wake_at = try channel.nextWake(now_ns, 16_666_667);
// 把 current.value 写进业务状态；wake_at 为 null 时动画已经停下。
```

- tween 提供 linear、smoothstep、cubic_out 曲线；spring 按频率和阻尼比求解析解，跳过的帧不补跑积分。
- 在视图里，把 `nextWake` 的结果交给 `v.wakeAt`；在底层 `ui.Context` 里，交给 `ziggurat_wake.OneShot`。

示例：`examples/timeline.zig`（`zig build run-timeline`）。完整的数值与调度约定见 [显式时钟动画](../animation.md)。

## 主线程单次唤醒

不使用视图时，`ziggurat_wake.OneShot` 在主线程上装定一次截止唤醒：

```zig
const wake = @import("ziggurat_wake");

const timer = try wake.OneShot.create(app, allocator, .{
    .context = &state,
    .fire = State.onDeadline,
}, .{});
const token = try timer.armAfter(16_666_667);
_ = try timer.cancel(token);
_ = try timer.close();
```

重新装定会替换旧的期限，代数取消保证迟到的旧期限不会触发；App 停止时回收。Windows 使用 waitable timer，Linux 使用 GLib Source。它不生成周期性计时器：每次触发后由应用决定是否再装定。见 [主线程单次唤醒](../wake.md)。

## 游戏循环

需要固定步长更新的游戏用 [`ziggurat_game`](../game.md)：世界按每秒 60 步更新，与显示刷新率无关，每帧在最近两步之间插值绘制；失去键盘时可以暂停。

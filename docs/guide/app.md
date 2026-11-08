# 应用与生命周期

一个 Ziggurat 进程有一个 `App`。它拥有全部窗口、主线程任务队列和原生事件循环。

```zig
const app = try z.App.init(allocator);
defer app.deinit();

const window = try app.createWindow(.{ .title = "Notes", .width = 900, .height = 600 });
try content.attach(window);
window.show();

try app.run(); // 原生事件循环；最后一个窗口关闭后返回
```

## 主线程

`App.init` 记下调用它的线程作为 **owner 线程**。所有原生操作、窗口方法、内容回调（绘制、输入、关闭）都在这个线程运行。框架不会在背后创建线程，也不会为了实现同步接口嵌套运行事件循环。

后台工作由应用自己创建线程完成，结果用 `App.post` 交回主线程：

```zig
const Loaded = struct {
    task: z.Task,
    notes: *Notes,
    text: []u8,

    fn run(context: *anyopaque) void {
        const self: *Loaded = @ptrCast(@alignCast(context));
        self.notes.adopt(self.text); // 在主线程：可以访问窗口与视图
        self.notes.window.invalidate();
    }
};

// 在 worker 线程中：
loaded.task = .{ .context = loaded, .call = Loaded.run };
app.post(loaded.task) catch |err| switch (err) {
    error.Full, error.Closed => {}, // 没有投递：数据仍归 worker，由它释放
    else => return err,
};
```

- 队列容量固定（256 项）。成功投递的任务在关闭完成之前一定执行一次；返回 `Full` 或 `Closed` 时不转移执行责任。
- 投递本身不重绘；任务里状态确实变化时再调用 `window.invalidate()`。
- `App.run` 返回后先 join 所有生产者线程，再 `App.deinit`。

需要在将来某个时刻在主线程上做事（动画的下一帧、自动保存），用 [`ziggurat_wake.OneShot`](../wake.md) 装定一次截止唤醒，而不是开一个轮询线程。

## 窗口句柄

`createWindow` 返回的 `Window` 是一个**值句柄**：包含 App 指针、槽位和代数。窗口关闭后原生记录及时回收，槽位可以复用，但旧句柄的代数不再匹配，调用会返回 `Closed`，不会误命中新窗口。App 必须比所有句柄的使用期都长。

窗口创建时是隐藏的。先挂内容（`view.Host`、`ui.Context`、`web.View` 等），再 `show()`。窗口的选项、状态、全屏、透明、无边框等见 [窗口](./windows.md)。

## 关闭与退出

关闭分为“请求”和“强制”两种：

| 调用 | 行为 |
| --- | --- |
| `window.requestClose()` | 询问窗口的 `on_close`，可被否决；返回 `closed`、`cancelled`、`deferred` 或 `in_progress` |
| `window.destroy()` | 强制关闭，不询问 |
| `app.requestQuit()` | 先预检**全部**窗口的否决，都允许后才退出；不会关一半 |
| `app.quit()` | 无条件退出，用于错误路径 |

```zig
const window = try app.createWindow(.{
    .title = "Untitled",
    .on_close = .{ .context = &doc, .request = Doc.onClose },
    .on_closed = .{ .context = &doc, .notify = Doc.onClosed },
});

fn onClose(context: *anyopaque, _: z.Window, reason: z.CloseReason) z.CloseDecision {
    const doc: *Doc = @ptrCast(@alignCast(context));
    return if (doc.dirty and reason == .user) .cancel else .allow; // 例如先弹出保存提示
}
```

- 回调里触发的销毁延迟到安全点执行；内容只 detach 一次。
- `on_closed` 在原生销毁与 detach 之后通知一次，构造失败的窗口不会收到它。窗口回调的 context 必须保持有效直到 `on_closed`。
- `isClosed()` 包含“关闭中”，不能据此提前释放 context。

默认最后一个窗口关闭时 `run` 返回。托盘常驻类应用设置 `AppOptions.on_all_windows_closed`，App 会在没有窗口时继续运行，直到 `requestQuit` 或 `quit`：

```zig
const app = try z.App.initWithOptions(allocator, .{
    .on_all_windows_closed = .{ .context = &tray_app, .closed = TrayApp.allClosed },
});
```

## 窗口之间的关系

创建时用 `owner` 指定拥有者，用 `modal = true` 创建模态窗口。父窗口关闭会先预检整棵拥有子树，再按子到父的顺序释放；模态窗口使用同一个主循环，限制整棵拥有树的输入。见 [窗口状态与关系](../windows.md)。

## 应用身份与系统集成

一个应用 ID（如 `com.example.notes`）贯穿单实例锁、Windows AppUserModelID、Linux `.desktop` 文件与注册的处理程序。在 `App.init` 之前设置：

```zig
const system = @import("ziggurat_system");

try system.identity.setProcessIdentity("com.example.notes");
var primary = (try system.instance.claimOrForward(.{ .id = "com.example.notes" }, .{
    .cwd = cwd,
    .arguments = args[1..],
}, 8)) orelse return; // 已有实例在运行：参数已转发给它
defer primary.deinit();
```

单实例与参数转发、系统目录、登录启动、URL scheme 与文件关联、阻止休眠、任务栏与 Dock 状态见 [单实例与系统集成](../os-integration.md)。

## 停止与清理

- 需要在 App 停止时取消或释放的资源可以注册为停止参与者（`StopParticipant`），见 [应用资源与停止](../application-resources.md)。
- 原生资源的最终释放用 `App.deferCleanup`，它不占用业务任务队列的容量。
- 框架报告的错误可以通过 `AppOptions.diagnostics_sink` 接收，见 [错误诊断](../diagnostics.md)。

# 错误诊断

同步操作仍返回 Zig error。可选的诊断目的地补充领域、操作、原生码与窗口代数，不改变返回值或执行责任。

```zig
var recorder: z.diagnostics.Recorder(64) = .{};
const app = try z.App.initWithOptions(allocator, .{
    .diagnostics_sink = recorder.sink(),
});
defer app.deinit();
```

Recorder 由调用者持有，地址保持稳定，寿命覆盖 App；即使 App 初始化失败，记录仍然可读。记录只包含值，不借用错误文本、窗口指针或临时字符串。窗口身份 `{ index, generation }` 只用于关联，不延长窗口寿命；多个 App 的身份需要通过调用者上下文区分。

`Diagnostic.code == null` 表示没有原生码，`0` 是一个确切的码。HRESULT 保留原始 32 位值，不能按 Win32 错误码解释。平台在失败位置捕获数值，再执行资源回滚，纯 Zig 校验错误不会附带上次失败的原生码。`last_native_error` 和 WebView 的 `last_hresult` 保留兼容用途，无法代替结构化记录。

框架报告在主线程同步调用 sink，并建立活动作用域；sink 请求的窗口销毁等待安全点，递归报告被抑制。sink 不得析构 App，也不应阻塞。队列 `Full` / `Closed` 是正常背压结果，不会自动向 sink 洪泛。应用可以在任意线程直接调用 Recorder；自定义共享 sink 自行同步。

Recorder 写入 O(1)，没有动态分配，仅错误记录和快照使用短 mutex。容量满后覆盖最旧记录；`dropped` 是永久覆盖数，饱和而不回绕。`snapshot(buffer)` 按时间顺序复制最新记录，返回 `count`、`retained` 和 `dropped`。缓冲太短时省略 `retained - count` 条仍保留的记录，不会增加 `dropped`。

初始化错误、绘制错误、WebView 异步失败和文本转换失败走同一出口。WebView 原有失败事件继续保留，应用无需为了诊断改变内容模块依赖。

验证入口：`zig build test`、`zig build smoke-diagnostics`。后者实际制造 COM apartment 冲突，确认 HRESULT 在初始化回滚后仍可读取，并验证之后能够创建新 App。

# 显式扩展生命周期

`ziggurat_extensions` 是独立的纯 Zig 模块，管理每个应用自己的插件依赖和初始化/关闭顺序。应用提供 `Plugin` 描述，不存在进程全局注册表，也不自动装载动态库、绑定 IPC、创建线程或添加事件循环。网络、数据库和终端等能力由后续独立模块实现。

```zig
const ext = @import("ziggurat_extensions");

var graph = try ext.Graph.init(&.{
    .{ .name = "storage", .context = &storage, .start = startStorage, .stop = stopStorage },
    .{ .name = "documents", .requires = &.{"storage"}, .context = &documents, .start = startDocuments, .stop = stopDocuments },
});
try graph.start();
defer graph.stop() catch unreachable;
// 创建窗口、显式绑定服务、运行 App；离开前撤销并 join 后台工作。
```

`start` 签名为 `fn (*anyopaque) anyerror!void`，`stop` 为 `fn (*anyopaque) void`。Graph 在创建线程访问，回调同步执行且必须及时返回；UI 线程上的初始化/关闭不得等待依赖该线程的后台任务。异步业务需要应用显式发起、取消、join，再在安全点调用 `stop`，Graph 不把同步回调伪装成异步完成。

最多 64 个插件，名称为 1–64 字节 ASCII 小写字母、数字或连字符，以字母开头。整个图在任何回调之前校验：重复名称/依赖、缺失依赖、容量和依赖环均失败，不初始化任何插件。描述、名称和依赖只在 `init` 期间借用；初始化复制名称、回调和上下文指针，计算固定拓扑顺序。无依赖关系的可启动项按声明顺序选择。每个成功初始化的插件只关闭一次，顺序与启动相反，关闭过程中其前置依赖仍有效。

业务上下文应保持到插件关闭回调返回；插件自身初始化失败时负责释放自己部分取得的资源，Graph 只回滚之前成功初始化的插件。`failure` 保存原始错误与原声明索引，不会被回滚覆盖；`pluginName(index)` 返回 Graph 拥有的名称借用，原描述已释放后仍可用于诊断。失败、取消或正常关闭之后均为终态；需要新运行时显式构造新 Graph，不自动重试具有副作用的初始化。

`start`/`stop` 回调重入 `start`/`stop` 返回 `Busy`。`requestStop` 可在回调中调用：启动期间等待当前初始化返回，然后立即逆序回滚并返回 `StartCancelled`；运行期间只记录意图，宿主完成异步业务撤销后显式 `stop`。启动前已请求停止时不调用任何初始化。`stop` 在终态幂等，`isActive` 只表示初始化成功且尚未开始关闭的插件。从首次调用 `start` 到终态关闭返回，Graph 是成功初始化责任的唯一所有者，应保持稳定地址，不得复制、移动、覆盖或跨线程操作；复制运行中的值再分别 `stop` 会错误地重复释放业务资源。

图使用固定数组和位集；名称解析为 O(VE)，拓扑排序为 O(V²)，V≤64、E≤4096；状态查找 O(V)，启动/关闭 O(V)，不进行堆分配。仅应用显式使用时有成本；它不依赖核心、UI 或 WebView。单元测试覆盖全图预检、64 位上界、描述快照、实际分配故障回滚、取消、重入、跨线程拒绝和恰好一次关闭。运行 `zig build test check`，Windows/Linux 使用相同模块；这些检查不宣称已有网络/数据库插件。

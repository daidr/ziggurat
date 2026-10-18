# 类型化 IPC

独立模块 `ziggurat_ipc` 用编译期类型描述服务：

```zig
pub const Service = struct {
    pub const methods = .{
        .add = ipc.Method(struct { a: i32, b: i32 }, i32, enum { overflow }, void),
        .watch = ipc.Method(struct { topic: []const u8 }, void, enum { unavailable }, []const u8),
    };
};
```

`Method` 依次指定参数、最终结果、错误枚举与流元素；`void` 流元素代表普通调用。生成器同时输出 TypeScript 类型、实际 Promise / AsyncIterable 客户端和运行时形状检查。

```powershell
zig build ipc-client -Dipc-service=examples/counter_service.zig
```

结果在 `zig-out/share/ziggurat/client.ts`。生成器在构建主机运行，和应用的目标平台分开。前端使用自己的构建工具编译 TypeScript；核心构建不要求前端运行时。

协议版本为 `1`。宿主为每个窗口文档分配新的随机 32 字符十六进制 session。请求携带 session、单调递增 ID 和客户端槽位；宿主以固定数组 O(1) 解析 pending 身份，复用槽位不会接受旧请求的结果或取消。session 用于文档隔离，不替代浏览器来源与 frame 检查。

`Router(Service, Limits)` 不执行用户方法，也不建立线程；`receive` 产生有类型的 call、cancel 或 ack 动作。JSON 分配器显式传入。返回的 `Received` 拥有解析 arena，参数与字符串只活到 `deinit`；异步工作必须保留 Received 或复制需要的数据。

`complete`、`fail` 和 `chunk` 返回调用者拥有的消息。编码先检查字节限额，分配失败不消耗 pending 或流额度。流最多有 `max_in_flight` 个未确认元素；客户端在消费元素时发送累计 ACK，宿主收到后归还额度，超限返回 `Backpressure`。客户端的固定队列只允许一个未完成的 `next()`。

`contains(token)` 是 owner 线程上的零分配只读成员检查，不保留请求或参数寿命。解析/编码会调用外部分配器，因此 Router 在发布 pending、消费 pending 或递增序号前重新核对 session、slot 和 id；分配回调取消后复用的槽不会被旧回复改动。相同流的嵌套 chunk 若已先占用序号，外层返回 `StreamChanged` 并释放未发布包；有效累计 ACK 可以在编码期间推进，不会被回滚。close/reset 使正在编码的旧 token 失效。宿主仍须保活 Router、Received、输入字符串和实现上下文，成员检查不代替这些所有权约束。

`receiveWithRejection` 为可寻址的无效调用返回终结拒绝信息，宿主通过 `protocol.reject` 回复，避免页面 Promise 一直等待。重复请求不发送可能误伤原请求的拒绝包。取消后旧 token 失效；`close` / `reset` 用调用者缓冲返回所有需取消的工作 token，缓冲不足时原子失败。

发出消息之后，如果 transport 拒绝接收，应用必须重试同一拥有的消息，或关闭整个 session，不能丢包后继续发送。窗口关闭、文档切换或恢复时关闭旧 session，并为新文档分配全新 session。

## 编译期服务调度

`Dispatcher(Service, Impl, Context, limits)` 在 Router 之上按服务声明调用实现，不要求宿主逐方法 switch。Impl 和 Context 均由调用者提供，IPC 不导入 App/Window，不保存它们的全局指针，也不建立线程、任务队列或 transport。

同步实现必须精确采用 `fn(*Impl, *Context, Service.methods.name.Params) ipc.Reply(Service, "name")`；Reply 为 `result: Result` 或 `failure: {code: ErrorCode, message: []const u8}`。编译器检查所有服务方法存在、参数类型和返回类型，未声明的错误枚举值无法编译。原生或业务错误由实现显式映射为声明的 failure，不把任意 Zig error set 当作 wire 错误。

```zig
const limits: ipc.Limits = .{};
const WatchWork = ipc.Work(Service, limits, "watch");
const Context = struct { watch: ?WatchWork = null };
const Impl = struct {
    pub fn add(_: *@This(), _: *Context, params: Service.methods.add.Params) ipc.Reply(Service, "add") {
        const sum = @addWithOverflow(params.a, params.b);
        if (sum[1] != 0) return .{ .failure = .{ .code = .overflow, .message = "Integer overflow" } };
        return .{ .result = sum[0] };
    }
    pub fn watch(_: *@This(), context: *Context, work: WatchWork) void {
        // 应用保证有空槽；这是从 handler 参数到应用状态的一次所有权交接。
        context.watch = work;
    }
};
const Dispatch = ipc.Dispatcher(Service, Impl, Context, limits);
var dispatcher = Dispatch.init(session);
var implementation: Impl = .{};
var context: Context = .{};
var action = try dispatcher.dispatch(allocator, &implementation, &context, message);
```

dispatch 返回以下 action，传输仍由宿主显式执行：

| action | 所有权和后续操作 |
| --- | --- |
| reply | 调用方拥有 PendingReply；执行 `action.reply.encode(&dispatcher.router, allocator)` 后发送拥有的 packet，并调用 `action.reply.deinit()` |
| taken | 实现函数已接管 Work；action 只携带 token，不另持有请求数据 |
| cancel | Router 已移除请求槽；宿主按 token 取消业务工作并释放对应 Work/Reply |
| ack | 携带 token 和累计 sequence；归还的流额度已写入 Router，宿主可继续显式生产 chunk |
| rejected | 可寻址无效调用的 token/code；宿主可用 `protocol.reject` 编码终结拒绝 |

同步 dispatch 只执行实现一次，返回的 `PendingReply` 保留完整 Received arena、类型化 result/failure union 和 token，尚未消耗请求槽。encode 成功才结束 pending；分配或消息限额失败时，原对象及 Router 状态保持不变，可重试同一对象的 encode，不能重新调用 handler。成功编码后再次 encode 返回 `AlreadyEncoded`；transport 失败时重试已拥有的 packet。解析阶段的分配失败发生在 handler 运行前，不产生业务副作用。

Reply 中的请求字符串由保留的 arena 保障寿命；借用 Impl/Context 的字符串、切片等必须由应用保持存活且内容稳定，直到成功 encode 或放弃并 deinit。模块不会为了延长这些外部数据的寿命而隐藏复制。无效 UTF-8、非有限数或无法满足的大小限制由宿主显式终结失败或关闭 session，不自动重跑业务逻辑。

延迟和流实现采用 `fn(*Impl, *Context, ipc.Work(Service, limits, "name")) void`，按值接管 typed params、token 和整个 Received arena；Dispatcher 不再释放这份数据。普通方法也可延迟接管，流方法也可直接同步返回最终 Reply。应用用原 `dispatcher.router.complete/fail/chunk` 回应 Work.token；异步计算和跨线程结果交接由应用管理。Work 不保留 Router、Context 或 App 指针，不把它们的寿命扩展到后台。

`Work` 与 `PendingReply` 都是拥有资源的不可复制值：handler 初次移交后，用 `take()` 显式移动到新存储，源对象失效；源/目标的指针 deinit 各自幂等，释放后的 take/encode 返回 `Released`。直接复制拥有值再分别析构违反契约。deinit 只释放解析存储，不静默结束仍在等待的页面请求；释放前需完成/失败该 token，或处理已收到的 cancel/close/reset。

`dispatcher.router.close/reset` 继续用调用者缓冲返回需取消的 token。关闭或换文档后，未编码 Reply 与旧 Work 的回应会返回 Closed/StaleSession/StaleRequest；宿主仍需释放它们持有的 arena。这样取消不会误释放正在使用的参数，迟到结果也不能完成复用后的请求槽。

## 类型化事件

事件 schema 可以独立于 RPC 服务存在，也可以通过 `Service.events` 与方法一起生成客户端：

```zig
const Notifications = struct {
    pub const events = .{
        .changed = ipc.Event(struct { path: []const u8, revision: u32 }),
        .reset = ipc.Event(void),
    };
};
// Service 中可声明 pub const events = Notifications.events;
const Events = ipc.EventSession(Notifications, .{});
var events = Events.init(session);
```

`Event(T)` 复用严格 wire 类型规则，但不创建请求或流。`generate(Notifications, allocator)` 可直接生成只有事件的客户端；既有只有 methods 的服务仍可使用。事件名称位于独立的 `Events` TypeScript 类型，`on` 的名称和回调参数都从 Zig schema 推导并在收到消息时验证。

声明 events 后，方法名 `on`、`listenerCount` 和 `subscriptionCount` 留给事件 API；没有 events 的既有 RPC 服务继续允许这些方法名。

```ts
const off = client.on("changed", ({ path, revision }) => {
  console.log(path, revision);
});
off(); // 幂等；最后一个同名监听器移除时发送 unsubscribe
```

一个客户端对同一事件只建立一条 wire 订阅。重复注册同一个函数创建独立监听器，每个返回的 off 只移除自己。回调按注册次序同步执行；回调中移除的后续监听器立即跳过，新加入的监听器从下一事件开始。关闭立即清空入口并停止剩余回调。回调抛错时继续本次仍有效的监听器，最后向 `receive` 调用方抛出首个错误，不破坏 RPC。回调中允许正常 RPC 回复；重入投递另一个当前事件抛 `ReentrantEvent`，不建立隐藏队列或递归事件循环。应用应在当前派发返回后重试该尚未接受的事件。

事件使用 `subscribe` / `unsubscribe` / `event` kind 和独立 `subscription` 代数，不占 RPC 的 slot、id 或流 ACK。宿主将前两种 kind 交给 `events.receive(allocator, bytes)`；已有解析结果可调用 `receiveValue(value)` 避免重复解析，此时调用者先验证原始字节上限并拒绝重复 JSON 字段。call/cancel/ack 保持交给 Router。订阅控制验证失败由宿主报告并关闭该文档连接；没有隐藏的订阅重试或确认 Promise。

宿主在异步工作开始前捕获目标身份，完成后使用原 token：

```zig
const captured = events.token("changed");
const packet = try events.emit("changed", allocator, captured, .{
    .path = "notes.txt", .revision = 7,
});
defer allocator.free(packet);
try view.post(packet);
```

token 绑定文档 session、事件和订阅代数。未订阅返回 `NotSubscribed`；退订或重新订阅后旧 token 返回 `StaleSubscription`；重载后的旧 token 返回 `StaleSession`。`close` 清空所有订阅并拒绝发送；`reset` 必须使用全新文档 session。应用须同时关闭或 reset 对应 Router，并在页面关闭或重载时调用旧 client.close。已经送入 transport 的旧包无法撤回；客户端会按 session 和订阅代数忽略它们。

emit使用捕获token中的session编码，分配器回调返回后再次验证session/订阅/关闭状态；未发布包在失效时释放，不能借重载回调把旧业务值编码为新页面事件。EventSession、payload和显式broadcast目标仍由宿主保活到调用结束。

默认每文档最多 32 个已订阅事件、客户端最多 64 个监听器，每包最多 64 KiB；所有上限可显式配置，host/client 须使用匹配配置。schema 最多 256 个名称。接收 JSON 与生成发送包使用显式 allocator；订阅表不分配。监听器在注册时分配，正常派发线性遍历有界链表，不复制监听器快照。空闲没有任务、定时器或轮询。事件不提供流消费 ACK；需要每条消费背压的数据使用已有 stream API。

## 显式广播

`Events.broadcast(event, allocator, targets, value, outcomes)` 只访问调用者给出的 `[]const Events.Target`。每项目标包含稳定 EventSession 指针、提前捕获的 token，以及同步借用 packet 的 context/send 函数；目标及上下文保持到本次调用返回。模块不注册全局窗口表。

调用前检查目标数量（默认最多 64）、outcomes 容量和重复 session；失败不发送任何包。之后按目标顺序处理，outcomes 与输入下标对应，逐项为 `sent`、`not_subscribed` 或 `failed: anyerror`，返回数量统计。某目标编码、session 或 transport 失败不会回滚其他已接受发送，也不会阻止后续目标。send 必须在接收前失败，成功返回则已经承担发送责任；它不能在接收成功后用页面业务回调错误伪装 transport 失败。

事件编码不消耗请求槽或额度，失败目标可使用同一 token/值重建并重试相同包，或由宿主关闭该文档的事件与 RPC 连接。没有自动跨目标事务、重试队列或未声明的目标扩展。

验证包括主构建中的 Zig 协议/事件/调度测试、`bun test tests/ipc_client.test.ts tests/ipc_events.test.ts` 的生成客户端测试，以及生成客户端与页面的严格 TypeScript 检查。调度测试覆盖单次副作用、编码分配失败后重试、拥有值移动、取消/close/reset 后迟到结果拒绝与流 ACK。`smoke-ipc -Dwebview=true` 用实际 WebView transport 连接客户端与 Dispatcher/EventSession，覆盖同步 Reply 与接管 stream Work、类型化事件、退订、已排队旧事件抑制和 token 在 reset/close 后失效，并保留 RPC/error/stream ACK/cancel 覆盖。后者需要 Bun 构建测试页面；隐藏窗口检查不代表视觉质量。

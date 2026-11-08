# 从页面调用 Zig

`ziggurat_ipc` 用编译期 Zig 类型描述服务：方法、错误码、流和事件。框架据此生成 TypeScript 客户端（类型、Promise / AsyncIterable 调用和运行时形状检查），并在 Zig 一侧按声明分派到实现。没有运行时反射，协议在两端都严格校验。

## 声明服务

```zig
// src/service.zig
const ipc = @import("ziggurat_ipc");

pub const Service = struct {
    pub const events = .{
        .changed = ipc.Event(struct { path: []const u8, revision: u32 }),
    };
    pub const methods = .{
        .add = ipc.Method(struct { a: i32, b: i32 }, i32, enum { overflow }, void),
        .watch = ipc.Method(struct { topic: []const u8 }, void, enum { unavailable }, []const u8),
    };
};
```

`ipc.Method(Params, Result, ErrorCode, StreamItem)` 依次给出参数、最终结果、错误枚举与流元素；流元素为 `void` 表示普通调用。服务文件只能导入 `ziggurat_ipc` 与 `ziggurat_resource_stream`，这样生成器可以在构建主机上独立编译它。

## 生成客户端

在 `ziggurat.json` 中指明服务与输出位置：

```json
{
  "service": "src/service.zig",
  "bindings": "web/src/client.ts"
}
```

然后运行：

```sh
ziggurat generate
```

它在框架检出中运行 `zig build ipc-client -Dipc-service=src/service.zig`，把客户端写到 `bindings`（内容未变时不改写文件）。同时配置了 `i18n` 时还会生成消息访问器，见 [本地化](../i18n.md)。前端用自己的构建工具编译 TypeScript，核心构建不需要前端运行时。

## Zig 一侧：实现与分派

`ipc.Dispatcher(Service, Impl, Context, limits)` 按声明调用实现。编译器检查每个方法都已实现、参数与返回类型正确，未声明的错误码无法编译：

```zig
const limits: ipc.Limits = .{};
const WatchWork = ipc.Work(Service, limits, "watch");

const Context = struct { watch: ?WatchWork = null };
const Impl = struct {
    pub fn add(_: *Impl, _: *Context, params: Service.methods.add.Params) ipc.Reply(Service, "add") {
        const sum = @addWithOverflow(params.a, params.b);
        if (sum[1] != 0) return .{ .failure = .{ .code = .overflow, .message = "Integer overflow" } };
        return .{ .result = sum[0] };
    }
    // 流与延迟方法接管 Work，稍后用 router.chunk / complete / fail 回应。
    pub fn watch(_: *Impl, context: *Context, work: WatchWork) void {
        context.watch = work;
    }
};

const Dispatch = ipc.Dispatcher(Service, Impl, Context, limits);
var dispatcher = Dispatch.init(session);
var action = try dispatcher.dispatch(allocator, &implementation, &context, message);
switch (action) {
    .reply => |*pending| {
        defer pending.deinit();
        const packet = try pending.encode(&dispatcher.router, allocator);
        defer allocator.free(packet);
        try page.post(packet);
    },
    .taken => {},                  // 实现接管了 Work
    .cancel => |token| cancel(token), // 页面取消了请求
    .ack => |ack| produceMore(ack.token), // 流的背压额度已归还
    .rejected => |rejected| reject(rejected),
}
```

- 同步实现返回 `ipc.Reply`；需要后台工作的实现接管 `Work`，在应用自己的线程完成后经 `App.post` 回到主线程，再用原 token 回应。
- 页面关闭或重载后，迟到的结果被 Router 以 `StaleSession` / `StaleRequest` 拒绝，不会完成复用后的请求槽。
- 流最多有 `max_in_flight` 个未确认元素，客户端消费时发送累计 ACK，超限返回 `Backpressure`。

## 页面一侧

```ts
const sum = await client.add({ a: 1, b: 2 }).result;

const watch = client.watch({ topic: "log" });
for await (const line of watch) console.log(line);
watch.cancel(); // 取消请求

const off = client.on("changed", ({ path, revision }) => console.log(path, revision));
off();
```

宿主回复的错误是 `RemoteError`，`error.code` 是声明的错误码之一。

## 接到页面上

每个文档需要一个新的随机 session，页面刷新或导航时旧 session 必须作废。最省事的做法是把服务作为页面 runtime 的**插件**接入：Host 负责握手、为每个文档分配 session，并在文档离开时通知插件。

```zig
// Zig：实现 page_runtime.Endpoint 的 open / receive / close，然后
try page.host.use(my_service.plugin()); // 名称如 "notes"，页面以 "plugin:notes" 访问
```

```ts
import { service } from "@ziggurat/runtime";
import { createClient } from "./client";

const client = await service("plugin:notes", createClient);
```

插件的回调约定、页面包与清单见 [插件](../plugins.md)；仓库中的 fetch、websocket、sqlite、watch 插件是完整的参考实现（`src/page_runtime/plugins/`）。

不使用页面 runtime 时，也可以直接把生成的 `createClient(post, session)` 接到 `window.chrome.webview.postMessage` 上，由应用自己生成 session 并发给页面，规则见 [类型化 IPC](../ipc.md)。

## 事件广播

`ipc.EventSession` 给已订阅的文档推送类型化事件；`Events.broadcast` 向调用者给出的多个页面依次发送，逐项报告 `sent`、`not_subscribed` 或 `failed`。见 [类型化 IPC：显式广播](../ipc.md#显式广播)。

# 网页前端

应用可以用系统 WebView 显示网页界面：Windows 是 WebView2，Linux 是 WebKitGTK 4.1，macOS 是 WKWebView。页面由框架从内存或应用自己的资源提供，不需要本地 HTTP 服务器；业务状态留在 Zig 里，页面通过消息或类型化 IPC 调用它。

构建时打开 `-Dwebview=true`（`ziggurat init --template web` 生成的 `build.zig` 已经传入）。各平台的运行时依赖见 [系统要求](./requirements.md)。

## 第一个页面

```zig
const web = @import("ziggurat_webview");
const html = @embedFile("index.html");

const State = struct {
    count: usize = 0,

    fn event(context: *anyopaque, page: *web.View, ev: web.Event) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (ev) {
            .message => |message| {
                if (!std.mem.eql(u8, message, "increment")) return;
                self.count +%= 1;
                var buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d}", .{self.count}) catch unreachable;
                page.post(text) catch |err| std.log.err("post: {s}", .{@errorName(err)});
            },
            .failed, .process_failed => page.window.?.app.quit(),
            else => {},
        }
    }
};

var state: State = .{};
var page = web.View.init(allocator, &state, State.event);
const window = try app.createWindow(.{ .title = "Counter" });
try page.attach(window, .{ .html = html, .user_data_folder = profile_folder });
window.show();
try app.run();
```

页面一侧：

```html
<p>Count: <output id="count">0</output></p>
<button id="increment">Increment in Zig</button>
<script>
  window.chrome.webview.addEventListener('message', event => {
    document.getElementById('count').textContent = event.data;
  });
  document.getElementById('increment').addEventListener('click', () => {
    window.chrome.webview.postMessage('increment');
  });
</script>
```

三个平台的页面都使用同一组 `window.chrome.webview.postMessage` / `addEventListener('message')`。

- 初始化是异步的：`Event.ready` 之前 `post` 返回 `NotReady`。`Event.failed` 携带原生错误，`process_failed` 表示页面进程终止，应用可以显式重载或恢复。
- `Event.message` 的字节只在回调期间借用。
- 页面数据（Cookie、存储）放在哪里由应用显式决定：Windows 传应用专用的绝对路径 `user_data_folder`；Linux 传同一 App 创建的 `web.Profile`（持久）或 `.storage = .ephemeral`（临时）。`ziggurat init --template web` 生成的代码演示了两条路径，见 [Linux 显式页面存储](../webview-profile.md)。

## 本地资源

发布态把前端构建产物嵌入可执行文件：

```sh
zig build web-assets -Dweb-assets=frontend/dist -Dweb-entry=/index.html
```

生成的模块导出入口文档与资源表，附加时作为本地站点提供，默认来源是 `https://app.ziggurat.invalid`：

```zig
const frontend = @import("web_assets");
const resources = frontend.resourceTable(web.Resource);

try page.attach(window, .{
    .html = frontend.html,
    .user_data_folder = profile_folder,
    .local = .{ .start_path = frontend.entry_path, .resources = &resources },
});
```

开发态用 `ziggurat_assets.Snapshot` 在工作线程读取前端目录的不可变快照，变化后 `View.reload` 换上新快照；`ziggurat dev --frontend "npm run build -- --watch"` 让前端监视命令和应用一起运行。生成器的 `build.zig` 写法、快照预算与目录通知见 [本地 Web 资源](../web-assets.md)。

更大的资源（视频、文件下载）可以按需流式提供而不整份放进内存，见 [应用资源字节流](../resource-stream.md) 与 [独立文件流](../file-stream.md)。

## 安全默认值

页面行为由 `web.View` 的策略控制，默认是拒绝：

- 导航、frame、弹窗、下载与权限请求默认拒绝；内存 HTML 页面有不可被文档放宽的 CSP。
- 远程页面需要显式声明允许的来源（`navigateRemote`、来源策略）。
- 权限（摄像头、麦克风、通知等）与下载以异步决定交给应用。
- 内容拦截规则、Cookie 存储、Profile 清理、查找、截图与 PDF 都是显式的工具接口。

完整规则见 [页面来源、请求策略与代数](../pages.md)。只附加可信页面；同源代码共享 DOM 的能力不是安全隔离边界。

## 页面 runtime

可选模块 `ziggurat_page_runtime` 和页面包 `@ziggurat/runtime` 给页面提供窗口控制、语言与方向、桌面偏好、拖入的文件和文档状态，并承载插件服务。

```zig
const runtime = @import("ziggurat_page_runtime");

page.window = .{ .window = window };
page.host = .init(allocator, .{
    .transport = .{ .context = &page, .send = Page.send }, // 调用 View.post
    .controls = page.window.controls(),
    .window_id = window.diagnosticId().index,
    .locale = catalog.negotiate(&.{i18n.locale.system() orelse i18n.Locale.root}),
    .preferences = .fromDesktop(try system.desktop.preferences(app)),
});
// Event.message 中：if (page.host.receive(text) == .foreign) handleAppMessage(text);
// 导航或进程失败时：page.host.pageChanged();
```

```ts
import { connect, currentWindow, onLocaleChange, onFileDrop } from "@ziggurat/runtime";

const runtime = await connect();
document.documentElement.lang = runtime.locale;
document.documentElement.dir = runtime.dir;
onLocaleChange((locale, dir) => {
  document.documentElement.lang = locale;
  document.documentElement.dir = dir;
});
onFileDrop(({ paths, x, y }) => openFiles(paths, document.elementFromPoint(x, y)));
closeButton.onclick = () => currentWindow.close();
```

- 内置窗口服务：`minimize`、`maximize`、`toggleMaximize`、`toggleFullScreen`、`closeWindow`（仍遵守关闭否决）、`setTitle`，用来做网页里的自定义标题栏。
- runtime 把强调色和文字缩放写到 `:root` 的 `--ziggurat-accent` 与 `--ziggurat-text-scale`。
- 每个文档（包括刷新）重新握手并得到新的 session，旧文档的请求不会串到新文档。

详见 [页面 runtime](../page-runtime.md)。页面里的本地化（与 Zig 共用同一份消息目录）见 [页面 i18n](../page-runtime.md#页面-i18n)。

## 调用 Zig 服务

字符串消息适合简单的应用；有结构的接口用 `ziggurat_ipc` 在 Zig 中声明服务，再生成 TypeScript 客户端：

```ts
const sum = await client.add({ a: 1, b: 2 }).result;
for await (const line of client.watch({ topic: "log" })) console.log(line);
```

见 [从页面调用 Zig](./bindings.md)。

## 与原生 UI 组合

- 一个窗口可以同时有原生区域和矩形 WebView 区域（`examples/hybrid.zig`：原生侧栏 + 页面），见 [窗口内容组合](../composition.md)。
- `ziggurat_webview_view` 把页面放进声明式视图的一个盒子，随布局移动、裁剪和缩放，见 [视图中的 WebView](../embedded-webview.md)。
- `PageSession` 让页面离开窗口停放并在另一个宿主挂载时保留 DOM。

## 引擎检测

`ziggurat_webview_runtime` 在不创建 App 或页面的情况下发现系统引擎及其版本，适合在启动前提示用户安装 WebView2 Runtime 或 WebKitGTK，见 [无页面的引擎发现](../webview-runtime.md)。`ziggurat doctor --webview` 做同样的检查。

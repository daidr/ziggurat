# 页面 runtime

可选模块 `ziggurat_page_runtime` 把一个页面文档接到宿主：内置 runtime 服务提供窗口控制，事件推送语言、方向、桌面偏好、拖入文件和文档状态；应用的插件服务经同一条页面消息通道接入。页面侧是 `packages/runtime` 的 `@ziggurat/runtime` 包。模块只依赖核心、`ziggurat_ipc` 与 `ziggurat_i18n`，不导入 WebView：宿主把页面消息交给 `Host.receive`，把 Host 发出的包交给 `View.post`。

## 宿主接线

```zig
const runtime = @import("ziggurat_page_runtime");

const Page = struct {
    view: web.View,
    window: runtime.WindowControls,
    host: runtime.Host,

    fn send(context: *anyopaque, bytes: []const u8) !void {
        const self: *Page = @ptrCast(@alignCast(context));
        try self.view.post(bytes);
    }

    fn pageEvent(context: *anyopaque, _: *web.View, event: web.Event) void {
        const self: *Page = @ptrCast(@alignCast(context));
        switch (event) {
            .message => |text| if (self.host.receive(text) == .foreign) handleAppMessage(text),
            .process_failed, .failed => self.host.pageChanged(),
            else => {},
        }
    }
};

page.window = .{ .window = window };
page.host = .init(allocator, .{
    .transport = .{ .context = &page, .send = Page.send },
    .controls = page.window.controls(),
    .window_id = window.diagnosticId().index,
    .locale = catalog.negotiate(&.{i18n.locale.system() orelse i18n.Locale.root}),
    .preferences = .fromDesktop(try system.desktop.preferences(app)),
});
try page.host.use(sqlite_plugin.plugin());
// 关闭页面或窗口时：
page.host.detach();
```

Host 不分配、不建线程、不保存全局状态；`receive` 与 `emit` 只用 init 时传入的 allocator 解析和编码单个包。Host、`WindowControls` 与插件 endpoint 在 detach 前保持稳定地址，所有调用都在主线程。`receive` 对不属于 runtime 的消息返回 `.foreign`，应用照常处理自己的字符串消息；runtime 消息（包括过期 session 的包）返回 `.handled`。

## 握手与 session

页面发送 `{"ziggurat":"hello","v":1}`。Host 为内置服务和每个插件各生成新的随机 32 位十六进制 session（默认使用系统 CSPRNG，测试可传入 `random`），先取消旧文档的工作再回复配置：

```json
{"ziggurat":"runtime","v":1,"platform":"linux","windowId":3,"version":"0.1.0-dev",
 "locale":"zh-Hant-TW","dir":"ltr",
 "preferences":{"accent":"#0a84ff","colorScheme":"dark","reduceMotion":false,"reduceTransparency":false,"highContrast":false,"textScale":1},
 "services":{"runtime":"<session>","plugin:sqlite":"<session>"}}
```

每个文档（包括刷新、导航）各发一次 hello，因此 session 绝不跨文档复用。路由只看消息开头：hello 必须逐字节相同，服务消息必须以生成客户端写出的 `{"v":1,"session":"<session>"` 开头；其他形式按 `.foreign` 交给应用。导航或进程失败时调用 `pageChanged()`，Host 关闭所有服务、通知插件，直到下一份 hello 前不发送任何包。发送失败（transport 拒绝）同样结束这次连接，不跳过已拥有的包继续发送。

平台名使用 `win32`、`linux`、`darwin`。`version` 默认是框架版本，`window_id` 由应用提供并在打开的窗口中唯一。

## 内置服务

方法都同步回复：`minimize`、`maximize`、`unmaximize`、`toggleMaximize`、`isMaximized`、`toggleFullScreen`、`closeWindow`、`setTitle({title})`。失败使用声明的错误码：`invalid_state`（全屏中最小化、模态阻塞、窗口禁用等）或 `unavailable`（窗口已关闭或原生操作失败），message 为 Zig 错误名。`closeWindow` 先发送回复再调用 `requestClose`，因此仍遵守取消；关闭可能在同一回调中 detach 页面。

事件：

| 事件 | Host 调用 | 载荷 |
| --- | --- | --- |
| `locale` | `setLocale(locale)` | `{locale, dir}`，方向由 `ziggurat_i18n` 按脚本推断 |
| `preferences` | `setPreferences(prefs)` | 强调色 `#rrggbb` 或 null、配色、减少动态/透明、高对比、文字缩放 |
| `fileDrop` | `fileDrop(paths, x, y)` | 绝对路径与 CSS 像素坐标 |
| `documentState` | `documentState(state)` | 名称、路径、已编辑、只读、冲突、已删除 |
| `documentReload` | `documentReload()` | 无 |

`setLocale` 与 `setPreferences` 同时更新下一份文档的初始配置。emit 返回 `true` 表示已发送，`false` 表示当前没有已连接且订阅的页面；包超过 64 KiB 等编码错误原样返回。`Preferences.fromDesktop` 按字段名复制 `system.desktop.Preferences`，不导入系统模块；平台不报告透明度偏好时页面得到 false。

## 页面包

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
titlebarClose.onclick = () => currentWindow.close();
```

`isZiggurat()` 报告页面是否在 Ziggurat 窗口里（存在 `window.chrome.webview` 传输）。`connect()` 每个文档只握手一次；同一页面里打包进来的多份包副本共享这一连接。浏览器标签页中 `connect()` 立即拒绝，宿主没有为该页面接入 Host 时它一直等待（可由应用自行加超时）。`runtime()`、`locale()`、`direction()`、`preferences()` 在连接完成前抛错，之后同步返回并随事件更新。`onLocaleChange`、`onPreferences`、`onFileDrop`、`onDocumentState`、`onDocumentReload` 可在连接前调用，返回的函数幂等地退订；runtime 自己先于页面监听器更新 `locale()`/`preferences()`。

runtime 把强调色和文字缩放写到 `:root` 的 `--ziggurat-accent`、`--ziggurat-text-scale`。错误来自宿主回复时 `isRemoteError(error)` 为 true，`error.code` 是声明的错误码。

`service(name, createClient, limits?)` 为插件包连接生成客户端：按配置中的 session 创建，每个文档每个服务一个客户端，消息按 session 只分发给对应客户端；宿主未注册该插件时拒绝并提示 `Host.use`。

内置服务的生成客户端位于 `packages/runtime/src/generated/runtime.ts`，由 `zig build page-runtime-clients` 从 Zig schema 重新生成；`zig build test` 中的 `check-page-runtime-clients` 在提交的客户端与 schema 不一致时失败。

## 页面 i18n

`@ziggurat/runtime/i18n` 使用与 `ziggurat_i18n` 相同的消息语法、校验规则、语言标签解析、回退链、协商与伪本地化：同一条消息在 Zig 和页面中同样有效或同样报错。

```ts
import { createCatalog } from "@ziggurat/runtime/i18n";

const catalog = createCatalog({ source: "en", messages: { en: english, de: german } });
const localizer = catalog.localizer(catalog.negotiate([runtime.locale]));
title.textContent = localizer.format("files", { count: 3 });
```

`formatMessage(locale, pattern, args, options)` 格式化单条消息：数字参数接受 number 与 bigint，select 接受字符串，date/time 接受 `Date`；缺失参数、类型不符和语法错误抛出带 `code` 的 `MessageError`（与 Zig 的 `MissingArgument`、`ArgumentType`、`InvalidMessage`、`NestingTooDeep`、`OutOfRange` 对应）。RTL locale 中字符串参数默认包在 U+2068/U+2069 隔离符中。Catalog 在创建时校验全部消息，嵌套对象用 `.` 展平；缺失键写出键名。显示 locale 自己回退链里的消息用显示 locale 的格式，落到 source 回退时沿用 source 的格式；`en-XA`、`ar-XB` 使用 source 消息并做伪本地化。

复数类别、数字与日期使用浏览器的 `Intl`（数字最多 3 位小数、五成双舍入；日期使用页面所在时区），不内置数据表，因此与 Zig 模块手工整理的数据在少数 locale 的细节上可能不同，例如 AM/PM 前的空格字符、阿拉伯语数字集。

## 查找高亮

`find.script(allocator, text, options)` 生成交给 `View.evaluateJS` 的自包含脚本：首次执行定义 `window.__zigguratFind`，在顶层文档的可见文本中查找不重叠的匹配，全部高亮，把当前匹配滚动到视野中央，并求值为 `{matches, active}`；`find.parseResult` 校验结果。`find_next` 在同一文本上前进，`backward` 反向，否则从头开始；`match_case` 区分大小写。被标记拆开的文本（如 `a<b>b</b>`）不被找到；脚本、样式、表单控件和隐藏元素中的文本被跳过。支持 CSS Custom Highlight API 的引擎不修改 DOM；其他引擎用 `<mark data-ziggurat-find>` 包裹匹配，`find.stop_script` 移除全部高亮并恢复文本节点。查找不移动焦点或选区。

```zig
const script = try runtime.find.script(allocator, query, .{ .find_next = true });
defer allocator.free(script);
_ = try view.evaluateJS(script, .{ .timeout_ms = 1000 }, completion);
// 完成回调里：const result = try runtime.find.parseResult(allocator, json);
```

它与 WebView 的原生查找（`Options.tools.find`）互不依赖：原生查找由引擎实现、各平台选项不同；脚本查找在两个平台给出相同的计数与高亮。

## 验证

`zig build test-page-runtime` 覆盖握手配置、foreign/过期消息分流、窗口方法回复与错误码、先回复后关闭、事件订阅与下一文档初始值、非法订阅关闭连接、新文档取消旧 session 与插件、发送失败、插件名校验、偏好转换、查找脚本与结果校验、插件清单，以及 `WindowControls` 在测试后端上的状态切换；`zig build test` 同时检查提交的生成客户端。`bun test packages` 用模拟宿主覆盖握手、窗口控制、事件顺序、连接前注册的监听器、插件 session 分发，以及与 Zig 模块相同用例下的 i18n 结果和查找匹配器。

`smoke-page-runtime -Dwebview=true` 在隐藏窗口的真实页面里运行打包后的 `@ziggurat/runtime`：握手配置、`setTitle`/最大化往返、locale 与拖入文件事件、插件 session 上的生成客户端调用、两种查找路径（Custom Highlight 与 `<mark>` 回退）共 20 步的计数/前进/后退/大小写/清除，以及 `closeWindow` 先回复后关闭。需要 Bun 打包测试页面。Linux 已在 WebKitGTK 2.52.6 本地通过；Windows 由 CI 的 WebView2 步骤运行。隐藏窗口检查不代表高亮的视觉质量。

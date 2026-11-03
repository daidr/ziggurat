# 浏览器（WebAssembly）

同一份原生 UI 应用可以不改代码编译成 `wasm32-wasi`，在浏览器页面里运行。Zig 一侧照常 `App.init`、`createWindow`、`run`；`web/ziggurat.js` 是页面一侧的加载器，负责实例化 `app.wasm`、提供画布、文字、输入和系统设施，`web/index.html` 是最小页面。

## 构建与运行

- 项目：`ziggurat build --platform web` 以 `-Dtarget=wasm32-wasi` 构建，生成的 `build.zig` 经 `addApplicationResources`（即 `addBrowserSite`）把 `index.html`、`ziggurat.js` 与 `app.wasm` 装到 `zig-out/web`，这是可以放在任何静态服务器上的站点。
- 开发：`ziggurat dev --web` 构建 Debug 版，在 `http://localhost:5174`（`--port` 可改）提供 `zig-out/web` 并打开浏览器；源码变化时重新构建，页面每 500 ms 询问构建号，变了就自己刷新。服务只监听 127.0.0.1，所有响应带 `cache-control: no-store`。
- 本仓库：标了 `.browser = true` 的示例有 `zig build web-<名称> -Dtarget=wasm32-wasi`，`zig build web -Dtarget=wasm32-wasi` 构建全部，输出在 `zig-out/web/<名称>/`。依赖子进程、终端、托盘、全局菜单栏、原生 WebView 或拖放的示例不标。
- `addBrowserSite` 为可执行文件打开 `rdynamic`、导出函数表（页面经 `__indirect_function_table` 回调 Zig 给出的函数）、8 MiB 栈与可增长内存。

页面以 `fetch` 加载 wasm，所以必须经 HTTP 提供，不能直接打开文件；服务器要把 `.wasm` 标成 `application/wasm`。

## 窗口与绘制

- 窗口画在页面画布上：有 `id="ziggurat"` 的元素时填满它，否则填满整页。后打开的窗口盖住先前的；尺寸、位置、最小最大尺寸与标题栏选项不起作用，页面标题取最后打开的窗口的标题。窗口能力报告不支持客户区定位，因此[窗口位置恢复](window-placement.md)返回 `UnsupportedCapability`。
- 绘制用内存软件渲染器，按设备像素比渲染，经 2D canvas 呈现，只在有变化的浏览器帧重画。WebGL 2 渲染器尚未接入。
- 文字由浏览器测量、分段（`Intl.Segmenter`）与绘制，字体为 `system-ui` 等 CSS 字体族并由浏览器回退与整形；断行在 Zig 侧按浏览器给出的断点贪心进行。没有子像素抗锯齿；系统文字轮廓不可用（`ZTL_UNSUPPORTED_OUTLINE`）。声明式视图在浏览器里默认用浏览器测量文字。

## 输入

指针（含点击计数）、滚轮与触控板、按键、输入法（屏外 textarea 放在光标处组合）、剪贴板文本（页面的 copy/cut/paste 事件）。Mac 上 ⌘ 当作 Ctrl。右键菜单是页面里的 HTML 菜单，消息框用 `alert`/`confirm`。

## 系统设施

| 设施 | 浏览器中 |
| --- | --- |
| 第一个 Router | 跟随标签页地址的片段（`#/notes/42`）：push/replace/go 写入 history，后退前进回到对应位置 |
| 计时器与唤醒 | `setTimeout` 与 `MessageChannel`，没有线程 |
| 音频输出 | Web Audio，首次用户手势后开始发声 |
| 手柄 | Gamepad API，标准映射一一对应 |
| 剪贴板 | 文本；读写在页面的复制粘贴事件中完成 |
| 外观偏好 | `prefers-color-scheme` 等媒体查询；`<html data-ziggurat-theme="dark|light">` 可覆盖 |
| 打开链接 | 新标签页 |
| 单实例 | 每个页面都是自己的实例：`claim` 总返回 primary，`receive` 立刻返回 `stopped` |
| 更新 | 页面加载时就是最新版本：`FeedBackend` 报告不可更新，检查与安装返回 `error.UpdatesDisabled`，不重启 |
| 窗口状态 | 不保存，由页面布局 |
| 托盘、全局快捷键、通知、文件对话框、应用菜单栏 | `UnsupportedCapability` |

## 验证

CI 的 Linux 任务构建全部浏览器示例，并用 `tests/web/smoke.py` 在无头 Chromium 中运行 `browser-smoke`：检查页面标题、Router 与地址片段、点击后的像素和 history 前进后退，并在启动时确认单实例、更新和窗口位置的浏览器行为。找不到 Chromium 时跳过。

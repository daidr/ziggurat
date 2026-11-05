# 浏览器（WebAssembly）

同一份原生 UI 应用可以不改代码编译成 `wasm32-wasi`，在浏览器页面里运行。Zig 一侧照常 `App.init`、`createWindow`、`run`；`web/ziggurat.js` 是页面一侧的加载器，负责实例化 `app.wasm`、提供画布、文字、输入和系统设施，`web/index.html` 是最小页面。

## 构建与运行

- 项目：`ziggurat build --platform web` 以 `-Dtarget=wasm32-wasi` 构建，生成的 `build.zig` 经 `addApplicationResources`（即 `addBrowserSite`）把 `index.html`、`ziggurat.js` 与 `app.wasm` 装到 `zig-out/web`，这是可以放在任何静态服务器上的站点。
- 开发：`ziggurat dev --web` 构建 Debug 版，在 `http://localhost:5174`（`--port` 可改）提供 `zig-out/web` 并打开浏览器；源码变化时重新构建，页面每 500 ms 询问构建号，变了就自己刷新。服务只监听 127.0.0.1，所有响应带 `cache-control: no-store`。
- 本仓库：标了 `.browser = true` 的示例有 `zig build web-<名称> -Dtarget=wasm32-wasi`，`zig build web -Dtarget=wasm32-wasi` 构建全部，输出在 `zig-out/web/<名称>/`。依赖子进程、终端、托盘、全局菜单栏或原生 WebView 的示例不标。
- `addBrowserSite` 为可执行文件打开 `rdynamic`、导出函数表（页面经 `__indirect_function_table` 回调 Zig 给出的函数）、8 MiB 栈与可增长内存。

页面以 `fetch` 加载 wasm，所以必须经 HTTP 提供，不能直接打开文件；服务器要把 `.wasm` 标成 `application/wasm`。

## 窗口与绘制

- 窗口画在页面画布上：有 `id="ziggurat"` 的元素时填满它，否则填满整页。后打开的窗口盖住先前的；尺寸、位置、最小最大尺寸与标题栏选项不起作用，页面标题取最后打开的窗口的标题。窗口能力报告不支持客户区定位，因此[窗口位置恢复](window-placement.md)返回 `UnsupportedCapability`。
- 绘制按设备像素比进行，只在有变化的浏览器帧重画。画布有 WebGL2 时用 OpenGL 渲染器：与 Linux 是同一份 `src/ui/gl_renderer.c` 和同一套着色器，只是 OpenGL 调用经 `src/ui/gl_web.h` 由页面在画布的 WebGL2 上下文上执行。页面补上 WebGL2（OpenGL ES 3.0）缺的部分：纹理缓冲用宽 1024 的浮点 2D 纹理代替，BGRA 上传和读回在页面里交换通道，透明边框钳制改为边缘钳制并在着色器里把遮罩外读成透明，`#version 330 core` 换成 `#version 300 es`。帧画进渲染器保留的帧缓冲，再整幅复制到画布；文字仍由浏览器绘制（与软件渲染器同一条路径），所以两种渲染器画出的文字相同。上下文丢失时页面阻止默认行为、这期间不出帧，浏览器恢复上下文后渲染器重建着色器和对象，已上传的图片与遮罩在之后的帧里重新上传，并重画整帧。画布没有 WebGL2（或 `Ziggurat.run(app, { renderer: "2d" })` 要求软件渲染）时回退为内存软件渲染器，经 2D canvas 呈现；同一画布一旦取了 2D 上下文就不再尝试 WebGL2。个别帧落到软件渲染器时（例如尚未上传的图片），像素经 WebGL2 显示在同一画布上。
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
| 窗口状态 | 不保存，由页面布局；标签页不可见（`visibilitychange`）时窗口报告为最小化，`View.windowHidden` 随之为 true |
| 文件与文本拖放 | `system.drop.Target`：拖到画布上的文件在放下时由页面读出，保存在页面自己的路径下，如 `/ziggurat-drop/3/photo.png`，放下事件给出这些路径；模块的文件调用（WASI 的 `path_open`、`fd_read`、`fd_seek`、`fd_filestat_get`、`fd_readdir` 等，预打开目录 `/`）可以只读地打开、读取、stat 和列出它们，最近 16 次放下的文件保留。文件名里的 `/` 换成 `_`，同名加序号。纯文本按 `text/plain` 放下。`DataTarget` 不支持 |
| 托盘、全局快捷键、通知、文件对话框、应用菜单栏 | `UnsupportedCapability` |

## 验证

CI 的 Linux 任务构建全部浏览器示例，用 `tests/web/imports.py` 确认每个 wasm 只导入页面提供的函数（否则页面启动即 LinkError），并用 `tests/web/smoke.py` 在无头 Chromium（无 GPU 时为 SwiftShader）中把 `browser-smoke` 运行两遍：一遍用 WebGL2 渲染器，确认帧都由 OpenGL 画出、没有落到内存，并用 `WEBGL_lose_context` 丢失再恢复上下文后重画；一遍强制软件渲染器。每遍检查页面标题、Router 与地址片段、点击后的像素、history 前进后退、右键 HTML 菜单，以及拖放文件（应用按给出的路径读取内容与大小）和拖放文本，并在启动时确认单实例、更新和窗口位置的浏览器行为。Chromium 取 PATH 上的真实 chromium，否则由 `scripts/ci-chrome.sh` 下载固定版本的 Chrome for Testing 无头 shell 并缓存；本地找不到 Chromium 时跳过。

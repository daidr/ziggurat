# ziggurat 命令

`zig build cli` 生成 `ziggurat` 和同目录的安装存根 `ziggurat-setup`。命令只调用本机 `zig`（可用 `ZIG` 指定），不下载任何依赖。

```text
ziggurat init DIR [--template native|web|hybrid] [--name NAME] [--id IDENTITY] [--framework PATH]
ziggurat dev [--watch DIR]... [--frontend COMMAND] [-- ZIG_BUILD_ARGS...]
ziggurat build [--debug] [--target TRIPLE] [--package] [-- ZIG_BUILD_ARGS...]
ziggurat package setup|deb --zip PACKAGE ...
ziggurat doctor [--webview]
```

## init

在空目录中生成 `build.zig`、`build.zig.zon`、`src/main.zig`、`.gitignore` 和 `ziggurat.json`。依赖以相对路径指向本框架检出（默认是构建 CLI 的那份源码），`build.zig.zon` 的 fingerprint 按 Zig 0.15.2 规则由包名生成。三种模板：

- `native`：声明式视图计数器，只依赖 `ziggurat` 与 `ziggurat_view`。
- `web`：WebView 页面和嵌入的 `src/index.html`，页面与 Zig 通过同一套 `window.chrome.webview` 消息往返；Linux 在启动前由 worker 准备私有 Profile 目录。
- `hybrid`：同一状态驱动一个原生视图窗口和一个页面窗口，任一侧的操作同步到另一侧。

生成的 `build.zig` 调用本框架 `build.zig` 公开的 `addApplicationResources`，在 Windows 上嵌入清单、版本与图标资源。名称只接受不含引号、尖括号、`&`、`@` 和反斜杠的文本，identity 只接受 ASCII 字母、数字、点、下划线与连字符。

## dev

先运行 `zig build`，成功后把安装出的可执行文件作为自己的子进程启动。每 300 ms 比较 `src/`、`build.zig`、`build.zig.zon` 与 `--watch` 目录中文件的路径、大小和修改时间（跳过点目录、`zig-out` 和 `node_modules`）；变化时终止应用并重新构建，构建失败则等待下一次变化。`--frontend` 用系统 shell 启动前端监视命令，退出时一并结束。轮询只发生在开发命令中，与应用的空闲路径无关。

## build

以 ReleaseSafe（`--debug` 时为 Debug）运行 `zig build`。`--package` 读取 `ziggurat.json`，把 `zig-out/bin` 中的可执行文件、Windows 上存在的 `WebView2Loader.dll` 和项目根的 LICENSE 打成 `dist/<identity>-<os>-<arch>-<version>.zip`，并打印其 SHA-256。该包可直接交给 `ziggurat-update release` 签名发布，或交给 `ziggurat package` 生成安装程序与 deb，见 [打包](packaging.md) 和 [更新](updates.md)。打包确定性只针对同一组输入与工具环境；编译产物本身是否逐字节一致取决于 Zig 编译器。

## doctor

报告主机、`zig version` 是否为 0.15.2、git；Linux 上用 pkg-config 检查 GTK 3、Pango、ICU（`--webview` 时 WebKitGTK 4.1 与 libsoup 3 为必需）以及是否有显示；Windows 上检查框架的 WebView2 SDK 目录和注册的 WebView2 Runtime 版本；当前目录的 `ziggurat.json` 是否有效。缺少必需项时退出码为 1。它只读取版本信息，不初始化任何页面或窗口；页面能否真正启动见 [引擎发现](webview-runtime.md)。

## 验证

`zig build test` 覆盖三种模板的渲染、名称与 identity 清理、非空目录与缺失框架拒绝，以及变化检测忽略构建输出。本地在 Linux 上用三种模板各生成项目、对本仓库实际 `zig build`，并在 Xvfb 中各运行 8 秒无错误退出（未做页面内容或视觉检查）；`dev` 在修改源文件后重建并保持单个应用进程；`build --package` 两次产生相同摘要。Windows 只完成交叉编译。

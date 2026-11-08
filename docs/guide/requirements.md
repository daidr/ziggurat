# 系统要求

## 工具链

- **Zig 0.17.0**。构建脚本和生成的项目都以它为准（`build.zig.zon` 的 `minimum_zig_version`）。框架代码通过共享模块 `ziggurat_io` 使用 `std.Io`。
- 复杂系统 ABI 用局部 C/Objective-C 适配，由同一个 Zig 工具链编译，不需要 C++ 运行时。
- 已知的编译器问题与绕过方式记录在 [工具链已知问题](../toolchain-known-issues.md)。

`ziggurat doctor` 检查下面列出的依赖；`--webview` 另外检查系统 WebView。

## Windows

- Windows 10 或更新版本，x86_64。原生 UI 使用 Win32/GDI，`-Dgpu=true` 启用 D3D11/DirectWrite，`-Daccessibility=true` 启用 UI Automation。
- **WebView**：需要系统已安装的 WebView2 Runtime（不自动安装）。构建需要 WebView2 SDK，用 `./scripts/fetch-webview2.ps1` 获取；可执行文件旁需要 `WebView2Loader.dll`，构建会一并安装它和 SDK 许可文件。

```powershell
./scripts/fetch-webview2.ps1
zig build run-web-counter -Dwebview=true
```

## Linux

- GTK3、Pango/Cairo、ICU 的开发包与 pkg-config：

```sh
sudo apt-get install libgtk-3-dev libpango1.0-dev libicu-dev pkg-config
```

- **WebView**（可选，`-Dwebview=true`）：WebKitGTK 4.1（2.40 及以上）与 libsoup 3，例如 `libwebkit2gtk-4.1-dev`。
- **GPU**（可选，`-Dgpu=true`）：OpenGL，通过 libepoxy/EGL。
- **可访问性**（可选，`-Daccessibility=true`）：ATK/AT-SPI。
- 托盘与通知走会话总线（需要 status-notifier 宿主与通知守护进程）；全局快捷键只在 X11 上可用；Wayland 不提供任意窗口位置和置顶。
- 在 WSL 中开发时，把 Zig 本地缓存放在 Linux 文件系统，见 [构建缓存](../build-cache.md)。

## macOS

- macOS 15.0 及以上（Zig 支持的最低版本），Apple 芯片或 Intel。
- Xcode 命令行工具与 macOS SDK（`xcode-select -p`、`xcrun --show-sdk-path`）。
- 原生 UI 使用 AppKit，`-Dgpu=true` 启用 Metal，`-Daccessibility=true` 启用 NSAccessibility；WebView 使用系统 WKWebView。
- 分发给其他 Mac 需要 Developer ID 签名与公证；没有签名身份时 `ziggurat` 改为 ad hoc 签名，见 [构建与分发](./distribution.md)。

## 浏览器

原生 UI 应用可以不改代码编译成 `wasm32-wasi` 在浏览器中运行（`ziggurat build --platform web`），需要支持 WebAssembly 的现代浏览器，有 WebGL2 时用 GPU 渲染。见 [浏览器（WebAssembly）](../browsers.md)。

## 构建选项

框架的 `build.zig` 提供以下可选开关，生成的项目把需要的开关传给依赖：

| 选项 | 作用 |
| --- | --- |
| `-Dwebview=true` | 构建系统 WebView（Windows WebView2、Linux WebKitGTK、macOS WKWebView） |
| `-Dgpu=true` | 构建 GPU 渲染器（D3D11 / OpenGL / Metal），保留软件回退 |
| `-Daccessibility=true` | 构建原生可访问性桥（UIA / ATK / NSAccessibility） |
| `-Dhttps-resources=true` | 构建可选的回环 HTTPS 资源传输 |
| `-Dwebp=true` | 构建固定版本的 WebP 解码器（先获取源码） |
| `-Dinspector=true` | 构建视图检查器（默认只在 Debug 构建） |

## 平台能力

各模块在运行时报告实际能力（例如 `window.capabilities()`、`system.capabilities`、`web.backendCapabilities()`）。平台缺少某项能力时返回 `UnsupportedCapability`，应用据此退回。各模块文档的“验证”一节写明了在哪些平台和环境中实际检查过。

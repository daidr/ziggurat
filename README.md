# Ziggurat

Ziggurat 是以 Zig 为中心的桌面应用框架。小内核管理窗口、生命周期和主线程调度，自绘 UI、系统 WebView、类型化 IPC、系统设施和更新工具按需导入。工具链固定为 **Zig 0.15.2**，API 仍处于早期演进阶段。

Windows x86_64 已实现 Win32/GDI、可选 D3D11/DirectWrite、WebView2、UI Automation、系统菜单、托盘、剪贴板、异步文件选择、全局快捷键与通知区通知。Linux 已通过 GTK3/GLib/Cairo/Pango 的真实桌面运行检查，可选 WebKitGTK 已验收显式 ephemeral HTML、独立持久 Profile、custom 本地资源/文件流、远程来源策略、矩形区域及可跨宿主保留 DOM 的离窗会话。各模块公开实际 capability；macOS 运行后端、完整 Linux 页面策略和完整控件库继续按计划实施。

## 运行

Windows 自绘示例使用系统库：

```powershell
zig build run-counter
zig build run-counter -Dgpu=true -Daccessibility=true
```

WebView 使用已安装的系统 WebView2 Runtime；SDK 与 Runtime 是不同依赖：

```powershell
./scripts/fetch-webview2.ps1
zig build run-web-counter -Dwebview=true
zig build run-rectangular-pages -Dwebview=true
```

安装产物在 `zig-out/bin/`。WebView EXE 需要同目录下的 `WebView2Loader.dll` 和系统 Runtime；构建同时安装 SDK 许可文件，不自动安装 Runtime。

Linux 需要 GTK3、Pango/Cairo 开发包和 pkg-config：

```sh
sudo apt-get install libgtk-3-dev libpango1.0-dev pkg-config
zig build run-counter
```

WSL 应将 Zig 本地缓存放在 Linux 文件系统，见 `scripts/linux-check.sh`。安装依赖、跨目标编译与真实桌面运行是不同验证层次。

## 模块

| 模块 | 职责 | 实际平台依赖 |
| --- | --- | --- |
| `ziggurat` | App/Window/Content、显式组合区域、关闭策略、有界任务、诊断与安全点清理 | Win32；GTK3/GLib |
| `ziggurat_ui` | 有界绘制、RGBA/圆角/渐变、独立透明离屏资源、布局/网格/裁剪/滚动、显式主题、编辑/范围控件与稳定输入 | GDI/Cairo/Pango；可选D3D11、共享GPU纹理/离屏target、UIA |
| `ziggurat_webview` | 异步页面、独立可停放会话、HTTPS 本地资源、来源与权限策略、显式恢复/重载 | Windows x86_64 WebView2；Linux WebKitGTK ephemeral/显式持久Profile、custom异步资源/显式文件泵与远程请求扩展 |
| `ziggurat_ipc` | 编译期服务调度、拥有的 Reply/Work、请求/取消/流与 ACK、事件/订阅/广播、TS 生成 | 纯 Zig；生成客户端为 TypeScript |
| `ziggurat_resource_stream` | 固定 slab 字节生产者、有效 ACK 背压、取消、独立预算与严格 wire 格式 | 纯 Zig；worker/投递由宿主显式管理 |
| `ziggurat_file_stream` | 私有普通文件、显式 worker pump 与独立 consumer 的线性交接 | Linux GIO/POSIX、Windows 有界 channel/overlapped 文件泵；生产 consumers 共用进程容量 |
| `ziggurat_native_stream` | [已知长度的原生字节生产者](docs/native-stream.md)、独立 Source/Writer 与明确撤销 | Linux/Windows 显式 worker、每块≤16KiB，与文件共用 consumer/物理账本，不依赖 WebView/HTTPS |
| `ziggurat_http_response` | HTTP 方法、头部规则、响应校验与拥有型元数据 | 纯 Zig；WebView 保留同类型别名，不拥有服务器或请求生命周期 |
| `ziggurat_https_resources` | 回环 HTTPS Transport、受检 Site/Endpoint、显式认证、Ticket 与文件背压 | 显式 `-Dhttps-resources=true`；Linux libsoup/GIO，Windows worker/Winsock/固定 TLS1.2；生产自签名 Profile pin 待实现 |
| `ziggurat_webview_runtime` | [显式 worker 的无页面引擎发现](docs/webview-runtime.md)、版本与分阶段原生错误 | 独立可选模块；Windows 首片，显式 loader 路径；不创建 App、Profile 或页面 |
| `ziggurat_webview_producer` | 当前 PageId 上的应用字节流、拥有回复重试与显式生产者交付 | 可选 Windows WebView2 + IPC；不替换 fetch 或授予来源权限 |
| `ziggurat_animation` | 显式时钟的 tween/spring、固定容量时间线、播放头与下一次唤醒请求 | 纯 Zig、无分配/线程/timer |
| `ziggurat_wake` | 主线程单次截止唤醒、代数取消与 App 停止回收 | Windows waitable timer；Linux GLib Source；独立按需导入 |
| `ziggurat_window_placement` | 显式显示器快照、离屏约束恢复与版本化状态存储 | Windows/X11；宿主事件推进，磁盘 I/O 由显式 worker 执行 |
| `ziggurat_assets` | 显式磁盘快照、目录通知、构建期内容寻址嵌入 | 快照/嵌入可移植；目录通知为 Windows |
| `ziggurat_system` | 系统菜单、托盘、文本剪贴板、异步选择器、全局快捷键、通知区通知、显式 Shell worker | 窗口设施/图标为 Windows；executable 启动为 Windows/Linux |
| `ziggurat_update` | Ed25519 元数据、限长流校验、ZIP 清单和版本目录发布 | 纯 Zig + OS 文件系统 |
| `ziggurat_extensions` | 显式插件依赖、初始化、失败回滚与逆序关闭 | 纯 Zig、固定容量，无隐式服务或线程 |
| `ziggurat_text_layout` | 独立拥有的系统 shaping、字素/坐标、双向/换行、caret 与选区查询 | DirectWrite + 系统 ICU；Pango；可选导入 |
| `ziggurat_text_outlines` | 从已有系统 Layout 显式导出独立单色 Path，可选真实 glyph/cluster 映射与完整字形单元 | 可选 text_layout + vector；默认批量轮廓不请求映射，同一布局不另 shaping |
| `ziggurat_svg_text` | 将系统 Layout 的单色字形轮廓接入显式 SVG 文字准备 | 可选 svg + text_layout + text_outlines；不在 paint 排版 |
| `ziggurat_shaped_editor` | 可见覆盖准备、字素编辑、bidi/软换行导航与 IME 展示桥接 | 显式依赖 UI 与系统文本布局 |
| `ziggurat_caret` | 有界字素 cell 索引及 bar/block/underline/失焦轮廓几何 | 纯 Zig；适配器显式准备，不改变原生文本服务的插入几何 |
| `ziggurat_document` | 持久 chunk 索引、原子多选编辑/undo、worker Reader、流式字面搜索及原生文本上下文 | 仅依赖核心；可选视图由 document_editor 接入 |
| `ziggurat_document_editor` | 同一文档的可见段落 shaping、多个视觉 caret/IME、派生嵌套折叠和增量失效 | 显式依赖 core/Document/UI/系统布局；有界准备 |
| `ziggurat_document_accessibility` | 完整文档不可变文本、同一准备几何和有界异步辅助动作 | 可选 Windows UIA/COM；MTA 不访问 Document 或 UI 对象 |
| `ziggurat_code_editor` | 同一文档的版本化请求、拥有诊断/hover/补全与可见浮层 | 显式依赖 Document/Adapter/UI/系统布局；宿主实现分析与 worker |
| `ziggurat_language_protocol` | 有界协议分帧、UTF-16 同步、补全/hover/诊断、显式工作区/配置、补全详情解析与取消/重启 | 可选模块；协议状态由owner采用，I/O与子进程由宿主显式管理 |
| `ziggurat_document_diff` | 两份 Reader 的精确行差异与拥有型 Hunk | 纯 Zig，仅依赖 Document；显式内存/工作/编辑距离预算 |
| `ziggurat_document_diff_view` | 同一文档对的版本化交付、可编辑双栏/统一视图、行内标记、导航与原子 revert | 显式依赖 Document/Adapter/UI/系统布局；上下文折叠和完整可访问语义继续实施 |
| `ziggurat_document_diff_accessibility` | 可编辑 Diff 双源全文、真实删除行几何与同根有界辅助控件 | 可选 Windows UIA；复用原 Document/Adapter 与唯一 Diff 协调者 |
| `ziggurat_virtual_list` | 稳定行 ID、可变高度索引、滚动锚点与有界可见回放 | 单向依赖 UI；完整虚拟控件集继续按计划实施 |
| `ziggurat_images` | 有界 PNG/JPEG/BMP/首帧 GIF、可选 WebP、EXIF 与独占像素交接 | 系统 WIC/GdkPixbuf；有界 LZW；可选固定源码 WebP |
| `ziggurat_image_drawing` | 不可变预乘像素、裁切与 mip 准备；显式上传、同尺寸更新和有界驻留 | 独立依赖图片与绘制资源；GDI/Cairo/D2D 回放 |
| `ziggurat_vector` | 拥有型路径、SVG 路径数据解析、填充/曲线/变换/描边与显式 A8 准备 | 纯 Zig，只依赖绘制资源；完整 SVG 文档另行实施 |
| `ziggurat_svg` | 有界 XML、形状/样式级联/use/symbol/viewport、渐变、裁剪/蒙版、显式文字 provider、可选逐采样颜色合成和 BGRA 准备 | 纯 Zig；更广文字排版、SVG 几何与容器效果继续实施 |
| `ziggurat_shadows` | 有预算的圆角内外阴影 A8 准备与独占交接 | 纯 Zig，只依赖绘制资源；显式上传后回放 |
| `ziggurat_gaussian` | 已合成 BGRA 快照的有界高斯准备、显式 worker 与拥有型图片 | 纯 Zig，只依赖绘制资源；零 sigma 保留原图片身份，实时模糊 scope 继续实施 |
| `ziggurat_drawing_resources` | 纯数据绘制借用与 owner-thread lease | 纯 Zig，无 native/font 依赖 |

核心不导入内容或扩展模块。每个窗口有一个内容所有者，系统设施另有独立服务入口；composition 已支持全窗 GDI/Cairo 背景和 Windows/Linux 独立矩形 WebView 区域，两个平台的 PageSession 均可离窗停放并在跨宿主挂载时保留 DOM。任意遮挡与完整混合输入继续分项实施。`rectangular-pages` 展示两个页面独立计数、隐藏保留和关闭重建。基础编辑模型保留 UTF-8 scalar 与逻辑行接口；可选 shaped editor 将同一文档接到系统字素、bidi、软换行和准备文本绘制，不在 paint 整形。真实语言引擎与完整平台文本服务继续按计划验收。

## 生命周期

`App.createWindow` 返回含 App、槽位和代数的值句柄。原生记录及时回收，旧句柄不会命中复用槽位。App 必须覆盖句柄使用期。UI Context/View 在 detach 前保持稳定地址；窗口回调上下文保持到 `on_closed`，已接受任务引用的存储还需覆盖任务执行期。

`requestClose`/`requestQuit` 允许否决，应用退出先预检全部窗口。`destroy`/`quit` 强制关闭。回调内销毁延迟到安全点；内容只 detach 一次，`on_closed` 在原生销毁与 detach 后通知一次。`isClosed` 包含关闭中状态，不能据此提前释放上下文。

拥有关系在创建时明确指定。父窗口关闭先预检整个拥有子树，按子到父顺序释放；模态窗口使用同一个主循环，最新可见模态分支限制整棵拥有树的输入，并与应用显式设置的 enabled 状态分别维护。

所有原生操作和 UI 回调都在进程主线程。后台线程通过 `App.post` 交接短任务；成功投递的任务退出前执行一次，`Full`/`Closed` 不转移执行责任。`run` 返回后 join 生产者，再 `App.deinit`。原生最终释放可使用独立的资源自带清理节点，不消耗业务队列容量。

## 检查与工具

```powershell
zig fmt --check build.zig build_support src examples tests tools
zig build test check -Dwebview=true -Dgpu=true -Daccessibility=true
zig build test-file-stream test-http-response test-caret test-gaussian
zig build smoke smoke-lifecycle smoke-diagnostics smoke-packaging smoke-waitables smoke-wake smoke-native-reentry smoke-ime-cancel smoke-cleanup smoke-editor smoke-editor-routing
zig build smoke-system smoke-system-events smoke-shell smoke-picker smoke-picker-result
zig build smoke-widgets smoke-widget-ranges -Daccessibility=true
zig build smoke-window-registry smoke-app-stop smoke-composition smoke-window-state smoke-window-relationships smoke-window-chrome smoke-key-input smoke-damage
zig build smoke-drawing smoke-gradients smoke-gpu smoke-gpu-fallback smoke-gpu-domain smoke-gpu-offscreen -Dgpu=true
zig build smoke-accessibility smoke-ui-config smoke-composition-ui -Daccessibility=true
zig build smoke-text-layout smoke-text-outlines smoke-text-cells smoke-text-drawing smoke-shaped-editor smoke-shaped-editor-native smoke-editor-caret smoke-editor-line-backgrounds smoke-editor-pre-input smoke-editor-range-markers smoke-text-input-mode smoke-text-client smoke-document smoke-document-editor smoke-code-editor smoke-document-diff-view smoke-virtual-list smoke-images smoke-image-prepare smoke-image-drawing smoke-image-update smoke-gradient-analytic smoke-coverage smoke-layers smoke-offscreen smoke-gaussian smoke-svg smoke-svg-text
zig build smoke-language-protocol smoke-completion-resolve smoke-diff-caret smoke-diff-commands
zig build test-affine test-affine-state smoke-affine-renderer smoke-affine-ui -Dgpu=true -Daccessibility=true
zig build smoke-webview smoke-composition-webview smoke-page-host smoke-page-session smoke-webview-policy smoke-page smoke-page-remote smoke-page-authorization smoke-script smoke-browser-tools smoke-request-policy smoke-resource-async smoke-resource-file smoke-scheme smoke-resource-producer smoke-permission smoke-download smoke-browser-policy smoke-ipc smoke-assets -Dwebview=true
zig build ipc-client -Dipc-service=examples/counter_service.zig
zig build web-assets -Dweb-assets=tests/assets_fixture
zig build update-tool -Doptimize=ReleaseSafe
```

`test` 使用测试后端验证核心不变量，并运行纯 Zig 布局、编辑、协议、资源、打包和更新测试；不创建原生窗口。`check` 编译普通目标后端探针与选中功能的所有示例/检查。原生 smoke 使用真实系统 API；多数窗口隐藏，GPU 就绪检查使用屏幕外窗口，文件选择测试会短暂启动并取消系统对话框。它们不证明视觉质量、真实输入法语言引擎输入或文件选择成功路径。WebView smoke 需要已安装 Runtime。

Linux 上使用 `zig build test check smoke-linux`，包括 GTK 生命周期、绘制、Unicode 输入、调度和外部原生销毁；X11 下另以 `GDK_SCALE=2` 验证实际 2x。CI 定义位于 `.github/workflows/ci.yml`，覆盖 Windows/Linux；WebView 运行检查按需启用。本轮已验证配置和本地等价命令，远端 workflow 尚未执行。

Ziggurat 使用 [MIT 许可证](LICENSE)。源码包包含 LICENSE，构建安装到 `share/ziggurat/LICENSE`。打包本仓库示例时传入 `-LicensePath LICENSE`；下游应用仍显式提供自己的许可文件。签名、更新和基准工具见以下文档。

- [架构](docs/architecture.md)、[设计原则](docs/philosophy.md)、[路线图](docs/roadmap.md)、[完整实施计划](docs/implementation-plan.md)
- [窗口状态与关系](docs/windows.md)、[内容组合](docs/composition.md)、[布局](docs/layout.md)、[基础控件](docs/widgets.md)、[虚拟列表](docs/virtual-list.md)、[基础绘制](docs/drawing.md)、[透明分组](docs/layers.md)、[离屏快照](docs/offscreen.md)、[路径资源](docs/vector.md)、[SVG 文档](docs/svg.md)、[系统文本布局](docs/text-layout.md)、[编辑器桥接](docs/editor.md)、[索引文档](docs/document.md)、[文档视图](docs/document-editor.md)、[编辑前输入门](docs/editor-pre-input.md)、[区间标记](docs/editor-range-markers.md)、[原生文本上下文](docs/text-input.md)、[窗口输入模式](docs/text-input-mode.md)、[图片解码](docs/images.md)、[图片绘制](docs/image-drawing.md)
- [错误诊断](docs/diagnostics.md)、[图标与打包](docs/packaging.md)
- [应用资源与停止](docs/application-resources.md)、[代码编辑服务](docs/code-editor.md)、[Snippet 会话](docs/snippets.md)、[完整文档辅助功能](docs/document-accessibility.md)、[快照差异](docs/document-diff.md)、[双栏比较](docs/document-diff-view.md)
- [窗口位置恢复](docs/window-placement.md)、[语言协议](docs/language-protocol.md)
- [Diff 文档辅助功能](docs/document-diff-accessibility.md)、[SVG 文字排版](docs/svg-text.md)
- [IPC](docs/ipc.md)、[应用字节流](docs/resource-stream.md)、[页面导航](docs/pages.md)、[文档初始化器](docs/document-initializers.md)、[独立 Cookie 存储](docs/cookie-store.md)、[Web 资源工具](docs/web-assets.md)、[系统设施](docs/system.md)
- [签名更新](docs/updates.md)、[性能与复现实验](docs/performance.md)
- [扩展生命周期](docs/extensions.md)
- [显式时钟动画](docs/animation.md)、[单次唤醒](docs/wake.md)、[系统文字轮廓](docs/text-outlines.md)
- [仿射坐标与输入](docs/affine.md)、[仿射栅格合成](docs/affine-rendering.md)、[多窗口设备域测量](docs/gpu-performance.md)
- [局部失效](docs/invalidation.md)
- [构建缓存与 WSL 容量](docs/build-cache.md)
- [共享 GPU 资源](docs/gpu-resources.md)、[GPU 离屏](docs/gpu-offscreen.md)
- [显式控件主题](docs/theme.md)

Linux 可选 WebKitGTK 使用显式 `.storage = .ephemeral`，或由宿主 worker 准备目录、同一 App 创建的持久 `Profile`。支持可信 HTML、顶层 IPC、页面与有界脚本，以及显式 custom scheme 的静态/异步响应、worker 文件快照/按需文件泵、独立矩形页面区域、可离窗停放的 PageSession 和需单独部署请求扩展的远程来源。可选 [CookieStore](docs/cookie-store.md) 直接绑定 Profile，无页面时也能执行有界 URL 查询和显式授权的写入/清 Cookie；普通页面不会自动创建它。宿主已有回环 HTTPS 服务时，可在 Profile 创建期显式冻结 `127.0.0.1` 的证书例外与直连策略，沿用 RemotePage 权限；内存/文件资源的 HTTPS 运输与更广浏览器工具继续实施。存储预算、证书例外范围及关闭边界见[Linux Profile](docs/webview-profile.md)，依赖、能力查询及实际检查见[页面策略](docs/pages.md)。

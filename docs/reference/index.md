# 模块索引

Ziggurat 的每项能力都是一个独立的 Zig 模块，在应用的 `build.zig` 里按需导入。核心不导入任何内容或扩展模块；可选的平台依赖（WebView、GPU、可访问性、HTTPS 资源、WebP）由构建选项打开，见 [系统要求](../guide/requirements.md#构建选项)。

```zig
const ziggurat = b.dependency("ziggurat", .{ .target = target, .optimize = optimize, .webview = true });
exe.root_module.addImport("ziggurat", ziggurat.module("ziggurat"));
exe.root_module.addImport("ziggurat_view", ziggurat.module("ziggurat_view"));
exe.root_module.addImport("ziggurat_system", ziggurat.module("ziggurat_system"));
```

模块之间的依赖关系图见 [架构](../architecture.md)。

## 核心与应用

| 模块 | 用途 | 文档 |
| --- | --- | --- |
| `ziggurat` | App、窗口、内容、关闭策略、主线程任务、诊断与安全点清理 | [应用与生命周期](../guide/app.md)、[窗口](../guide/windows.md) |
| `ziggurat_io` | 进程共享的 `std.Io`（文件、进程、网络） | — |
| `ziggurat_wake` | 主线程单次截止唤醒 | [主线程单次唤醒](../wake.md) |
| `ziggurat_animation` | 显式时钟的 tween/spring、时间线与播放头 | [显式时钟动画](../animation.md) |
| `ziggurat_window_placement` | 显示器快照、离屏约束恢复与版本化窗口状态 | [窗口放置](../window-placement.md) |
| `ziggurat_extensions` | 显式插件依赖、初始化、失败回滚与逆序关闭 | [显式扩展生命周期](../extensions.md) |
| `ziggurat_system` | 菜单、托盘、通知、快捷键、剪贴板、拖放、选择器、单实例、系统集成 | [桌面 API](../guide/desktop.md)、[系统工具](../system.md) |
| `ziggurat_i18n` | 语言协商、ICU 消息、复数、数字与日期格式、伪本地化 | [本地化](../i18n.md) |
| `ziggurat_document_app` | 文档应用：每文件一个窗口、保存提示、自动保存、崩溃恢复、最近文档 | [文档应用](../document-app.md) |
| `ziggurat_audio` | 音效与流式音乐（WAV、FLAC、Ogg Vorbis、MP3、AAC/MP4） | [音频](../audio.md) |
| `ziggurat_video` | 用系统媒体框架播放视频文件与流 | [视频](../view.md#视频) |
| `ziggurat_game` | 固定步长循环、按位置的按键、相机、手柄 | [游戏](../game.md) |
| `ziggurat_automation` | 从另一个进程驱动正在运行的应用 | [自动化](../automation.md) |

## 原生 UI

| 模块 | 用途 | 文档 |
| --- | --- | --- |
| `ziggurat_ui` | Frame 绘制、控件、布局、滚动、主题、命中测试、可访问性语义 | [基础控件](../widgets.md)、[布局](../layout.md)、[主题](../theme.md) |
| `ziggurat_view` | 声明式视图：构建函数、弹性布局、控件、浮层、动画、Harness | [原生 UI](../ui/)、[声明式视图](../view.md) |
| `ziggurat_view_text` | 视图中的可编辑文本字段 | [原生 UI：文本输入](../ui/#文本输入) |
| `ziggurat_view_timer` | 把视图的唤醒请求变成一次性计时器 | [动画与唤醒](../guide/animation.md) |
| `ziggurat_view_graphics` | 视图里的图标、SVG 与图片 | [图片、SVG 与图标](../view.md#图片、svg-与图标) |
| `ziggurat_view_video` | 视图里的动画 GIF、APNG 与视频帧 | [视频](../view.md#视频) |
| `ziggurat_view_collections` | 虚拟表格、列表、大纲与网格视图 | [虚拟集合](../collections.md) |
| `ziggurat_view_pickers` | 日历、日期/时间/数字输入、颜色选择器 | [选择器](../pickers.md) |
| `ziggurat_view_rich_text` | 带样式文字段落 | [富文本](../rich-text.md) |
| `ziggurat_rich_text`、`ziggurat_rich_text_editor`、`ziggurat_rich_text_clipboard` | 富文本文档、编辑器与系统剪贴板 | [富文本编辑器](../rich-text-editor.md) |
| `ziggurat_markdown`、`ziggurat_markdown_view`、`ziggurat_markdown_code`、`ziggurat_markdown_rich` | Markdown 解析、显示、代码块与富文本段落 | [Markdown](../markdown.md) |
| `ziggurat_chart`、`ziggurat_chart_view` | 尺度、标记与视图中的图表 | [图表](../chart.md) |
| `ziggurat_terminal`、`ziggurat_terminal_view` | 伪终端、终端仿真与视图 | [终端](../terminal.md) |
| `ziggurat_shader` | 元素效果的有界着色语言 | [着色器与元素效果](../shader-effects.md) |
| `ziggurat_virtual_list` | 稳定行 ID、可变高度索引与滚动锚点 | [可变行高虚拟列表](../virtual-list.md) |
| `ziggurat_fonts` | 应用自带字体 | [应用字体](../fonts.md) |
| `ziggurat_text_measure` | 用平台文本布局测量的视图测量器 | [声明式视图：文本测量](../view.md#文本测量) |

## 文本与编辑

| 模块 | 用途 | 文档 |
| --- | --- | --- |
| `ziggurat_text_layout` | 系统 shaping、字素、双向、换行、caret 与选区 | [系统文本布局](../text-layout.md) |
| `ziggurat_text_outlines` | 从系统布局导出单色字形轮廓 | [系统文字轮廓](../text-outlines.md) |
| `ziggurat_shaped_editor` | 字素编辑、bidi/软换行导航与输入法桥接 | [编辑器与系统布局](../editor.md) |
| `ziggurat_caret` | caret 几何 | [编辑器视觉 caret](../editor-carets.md) |
| `ziggurat_document` | 持久 chunk 索引、多选区编辑与撤销、流式搜索 | [索引文档](../document.md) |
| `ziggurat_document_editor` | 大文档的可见段落排版、多 caret、折叠 | [大文档编辑桥](../document-editor.md) |
| `ziggurat_document_accessibility` | 文档的原生可访问性 | [文档可访问性](../document-accessibility.md) |
| `ziggurat_code_editor`、`ziggurat_code_syntax` | 代码编辑服务、语法高亮与多光标 | [代码编辑](../code-editor.md)、[语法高亮](../code-syntax.md) |
| `ziggurat_language_protocol` | 有界语言服务协议客户端 | [有界语言协议](../language-protocol.md) |
| `ziggurat_document_diff`、`ziggurat_document_diff_view`、`ziggurat_document_diff_accessibility` | 行差异、双栏/统一对比视图与可访问性 | [快照差异](../document-diff.md)、[文档对比](../document-diff-view.md) |

## 绘制与图像

| 模块 | 用途 | 文档 |
| --- | --- | --- |
| `ziggurat_drawing_resources` | 绘制借用与 owner 线程 lease | [基础绘制](../drawing.md) |
| `ziggurat_images`、`ziggurat_png`、`ziggurat_gif`、`ziggurat_apng` | PNG/JPEG/BMP/GIF/APNG/WebP 解码与像素交接 | [图片解码](../images.md) |
| `ziggurat_image_drawing` | 图片准备、上传与驻留 | [图片准备与绘制](../image-drawing.md) |
| `ziggurat_vector` | 路径、SVG 路径数据、填充与描边 | [路径资源](../vector.md) |
| `ziggurat_svg`、`ziggurat_svg_text` | SVG 文档与文字 | [SVG](../svg.md)、[SVG 文本](../svg-text.md) |
| `ziggurat_shadows` | 圆角内外阴影 | [阴影](../shadows.md) |
| `ziggurat_gaussian` | 高斯模糊资源 | [高斯滤波](../gaussian.md) |

## 网页与 IPC

| 模块 | 用途 | 文档 |
| --- | --- | --- |
| `ziggurat_webview` | 系统 WebView 页面、本地资源、来源与权限策略、页面会话 | [网页前端](../guide/frontend.md)、[页面](../pages.md) |
| `ziggurat_webview_view` | 把页面放进声明式视图 | [视图中的 WebView](../embedded-webview.md) |
| `ziggurat_webview_runtime` | 无页面的引擎发现与版本 | [引擎发现](../webview-runtime.md) |
| `ziggurat_webview_producer` | 当前页面上的应用字节流 | [原生字节生产者](../native-stream.md) |
| `ziggurat_page_runtime` | 页面 runtime：窗口控制、语言、偏好、插件 | [页面 runtime](../page-runtime.md) |
| `ziggurat_ipc` | 编译期服务、调度、事件与 TypeScript 生成 | [从页面调用 Zig](../guide/bindings.md)、[类型化 IPC](../ipc.md) |
| `ziggurat_assets` | 前端资源的磁盘快照与构建期嵌入 | [本地 Web 资源](../web-assets.md) |
| `ziggurat_resource_stream`、`ziggurat_file_stream`、`ziggurat_native_stream` | 页面资源的有界字节流 | [资源流](../resource-stream.md)、[文件流](../file-stream.md) |
| `ziggurat_http_response`、`ziggurat_https_resources` | HTTP 响应规则与回环 HTTPS 传输 | [HTTPS 资源](../https-resources.md) |
| `ziggurat_plugin_fetch`、`ziggurat_plugin_websocket`、`ziggurat_plugin_sqlite`、`ziggurat_plugin_watch` | 标准页面插件 | [插件](../plugins.md) |

## 网络、数据与分发

| 模块 | 用途 | 文档 |
| --- | --- | --- |
| `ziggurat_net` | HTTP fetch 与 WebSocket 客户端，系统代理 | [Fetch 与 WebSocket](../net.md) |
| `ziggurat_sqlite` | 嵌入式 SQLite：连接、预编译语句、事务、迁移 | [SQLite](../sqlite.md) |
| `ziggurat_update` | Ed25519 签名更新、增量、发布与回滚 | [签名更新](../updates.md) |
| `ziggurat_updater` | 现成的更新提示窗口 | [签名更新：更新窗口](../updates.md#更新窗口) |

## 命令行工具

| 工具 | 构建 | 文档 |
| --- | --- | --- |
| `ziggurat` | `zig build cli` | [ziggurat 命令](../cli.md) |
| `ziggurat-update` | `zig build update-tool` | [签名更新：命令行工具](../updates.md#命令行工具) |
| `ziggurat-automation` | 见文档 | [自动化：命令行](../automation.md#命令行：ziggurat-automation) |

## 设计文档

这些页面记录实现约定与验证范围，供贡献者参考：[架构](../architecture.md)、[设计原则](../philosophy.md)、[性能约束与验证](../performance.md)、[构建缓存](../build-cache.md)、[工具链已知问题](../toolchain-known-issues.md)、[路线图](../roadmap.md)、[完整功能实施计划](../implementation-plan.md)、[开发检查点](../development-checkpoint.md)。

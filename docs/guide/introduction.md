# 简介

Ziggurat 是以 Zig 为中心的桌面应用框架。应用用 Zig 写业务状态和逻辑，界面可以是框架自绘的**原生 UI**，也可以是系统 WebView 中的**网页前端**，或者两者在同一个窗口里组合。

```zig
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");

const Hello = struct {
    count: i64 = 0,
    fn build(self: *Hello, v: *view.View) anyerror!void {
        try v.textf("点了 {d} 次", .{self.count}, .{});
        if (try v.button("再点一次", .{})) self.count += 1;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var hello: Hello = .{};
    var storage: view.Storage(16, 256) = .{};
    var host = view.Host.init(&hello, Hello.build, storage.buffers(), .{});

    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Hello", .width = 420, .height = 240 });
    try host.attach(window);
    window.show();
    try app.run(); // 最后一个窗口关闭后返回
}
```

## 两种内容，一个内核

| | 原生 UI | 网页前端 |
| --- | --- | --- |
| 模块 | `ziggurat_view`（建立在 `ziggurat_ui` 之上） | `ziggurat_webview` + `ziggurat_page_runtime` |
| 渲染 | GDI/Cairo/Core Graphics，可选 D3D11/OpenGL/Metal | WebView2 / WebKitGTK / WKWebView |
| 状态 | 构建函数直接读写应用的 Zig 字段 | 页面通过类型化 IPC 调用 Zig 服务 |
| 适合 | 体积小、启动快、深度系统集成的工具 | 已有 Web 技术栈、复杂富内容 |

两者共享同一套 App/窗口生命周期、关闭策略、主线程规则和系统设施。一个窗口可以把原生侧栏和矩形 WebView 区域组合在一起（见 [窗口内容组合](../composition.md) 与 `examples/hybrid.zig`）。

## 设计取向

- **小内核**：核心 `ziggurat` 只拥有 App/Window/Content、关闭策略、有界任务队列、诊断与安全点清理。其他能力都在独立模块中，按需在 `build.zig` 里导入。
- **显式所有权**：分配器从调用者传入；窗口是带 App、槽位和代数的值句柄，旧句柄不会命中复用的槽位；每个内容对象有明确的 attach/detach 时机。
- **单一主线程**：所有原生操作与 UI 回调都在进程主线程。后台线程由应用自己创建，用 `App.post` 把短任务交回主线程。框架不嵌套事件循环、不做阻塞 UI 等待。
- **空闲即安静**：没有持续重绘定时器；动画通过显式截止时间请求下一帧，停下后什么也不调度。
- **能力如实报告**：各模块的 `capabilities` 反映实际实现。平台缺少某项能力时返回 `UnsupportedCapability`，而不是静默成功。

完整的原则见 [设计原则](../philosophy.md)，模块之间的依赖见 [架构](../architecture.md)。

## 模块一览

常用模块：

| 模块 | 用途 |
| --- | --- |
| `ziggurat` | App、窗口、生命周期、主线程任务 |
| `ziggurat_view` | 声明式原生视图：布局、控件、浮层、动画、Harness 测试 |
| `ziggurat_view_text` | 视图中的可编辑文本字段（系统输入法、选区、撤销） |
| `ziggurat_ui` | 底层自绘 UI：Frame 绘制、控件、主题、命中测试、可访问性语义 |
| `ziggurat_webview` | 系统 WebView 页面、本地资源、来源与权限策略 |
| `ziggurat_page_runtime` | 页面 runtime：窗口控制、语言、偏好、插件服务 |
| `ziggurat_ipc` | 编译期描述服务，生成 TypeScript 客户端 |
| `ziggurat_system` | 菜单、托盘、通知、快捷键、剪贴板、拖放、文件选择器、单实例 |
| `ziggurat_i18n` | ICU 消息、复数、数字与日期格式、伪本地化 |
| `ziggurat_document_app` | 文档应用：每文件一个窗口、自动保存、崩溃恢复 |
| `ziggurat_audio` | 音效与流式音乐 |
| `ziggurat_update` / `ziggurat_updater` | 签名更新与更新窗口 |

全部模块及其平台依赖见 [模块索引](../reference/)。

## 当前状态

Ziggurat 仍处于早期演进阶段，API 会变化。工具链固定为 **Zig 0.17.0**。Windows、Linux（GTK3）和 macOS 都有原生后端；具体平台差异写在各模块文档的“验证”或“已验证范围”一节，见 [系统要求](./requirements.md)。

# 窗口

窗口由 `App.createWindow(options)` 创建，返回值句柄 `z.Window`。新窗口是隐藏的：挂上内容后调用 `show()`。所有窗口方法都在主线程调用；关闭中或过期的句柄返回 `Closed`。

```zig
const window = try app.createWindow(.{
    .title = "Editor",
    .width = 960,
    .height = 640,
    .min_width = 480,
    .min_height = 320,
});
try host.attach(window);
window.show();
```

## 创建选项

`z.WindowOptions` 的常用字段（尺寸以 DIP 计）：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `title` | `"Ziggurat"` | 标题，原生 API 复制后不再借用 |
| `width` / `height` | 720 / 480 | 客户区尺寸，不含边框、标题栏或菜单 |
| `min_width` / `min_height` | 0 | 最小客户区尺寸 |
| `decoration` | `.system` | `.system` 系统边框；`.custom` 去掉系统边框、由应用绘制标题栏；`.borderless` 无边框也无自动缩放边 |
| `resizable`、`movable`、`minimizable`、`maximizable`、`closable` | true | 窗口特性，创建后可用 `setTraits` 修改 |
| `owner` / `modal` | null / false | 拥有关系与模态，创建时固定 |
| `transparent` | false | 透明背景，绘制留空的地方透出桌面 |
| `vibrancy` / `vibrancy_tint` | `.none` | 窗口后面的系统材质（macOS 的 Liquid Glass 等，Windows 11 的 Mica/Acrylic） |
| `corner_radius` | 0 | `.borderless`/`.custom` 窗口的圆角 |
| `opacity`、`skip_taskbar` | 1、false | 整体不透明度、不在任务栏显示 |
| `focus_on_show` | true | false 时显示窗口不抢走键盘，适合后台工作弹出的提示 |
| `popup` | null | 弹出窗口角色：浮出层、菜单式列表、悬停卡片 |
| `hit_test` | null | 自定义标题栏的命中测试 |
| `on_close` / `on_closed` | null | 关闭询问与关闭后通知，见 [应用与生命周期](./app.md#关闭与退出) |

## 大小、位置与状态

```zig
const caps = try window.capabilities();
try window.setClientBounds(.{
    .position = if (caps.client_position) .{ .x = 120, .y = 160 } else null,
    .width = 800,
    .height = 500,
});
if (caps.fullscreen) try window.setFullscreen(true);
if (caps.always_on_top) try window.setAlwaysOnTop(true);
try window.perform(.maximize); // show、hide、minimize、maximize、restore、focus、enable、disable
const state = try window.state(); // visible、minimized、maximized、focused、fullscreen ...
```

- `capabilities()` 按窗口当前的显示环境报告能力。Wayland 不提供任意顶层位置与置顶，此时位置读为 null，设置返回 `UnsupportedCapability`。
- 退出全屏会还原进入前的位置、尺寸和最大化/最小化状态。
- `setZoom(z)`（0.25 到 5）锐利地放大窗口内容：内容在 1/z 的空间里布局，按放大后的尺寸光栅化。

记住并恢复窗口的位置与大小（跨显示器、离屏约束）用 [`ziggurat_window_placement`](../window-placement.md)。

## 运行期策略

```zig
try window.setTitle("notes.md");
try window.setDocumentEdited(true);     // Windows 与 Linux 在标题前加 "*"
try window.setTraits(.{ .resizable = false, .maximizable = false });
try window.setClosable(false);          // 用户关闭请求直接取消
try window.setOpacity(0.85);
try window.setIgnorePointer(true);      // 指针穿透到下方窗口
try window.setInputRegion(&.{character}); // 只有这些矩形接收指针，其余穿透
try window.setContentProtection(true);  // 截图与录屏中不显示
try window.flashFrame(true);
```

每项都有对应的能力位；平台不支持时返回 `UnsupportedCapability`。完整的平台行为见 [窗口状态与关系](../windows.md)。

## 自定义标题栏

`decoration = .custom` 去掉系统边框，应用自己画标题栏。`hit_test` 回调把标题区域报告为 `.caption`，平台便原生地移动窗口，双击时最大化；`resize_border`（默认 6 DIP）范围内的边缘用于缩放。

```zig
fn hit(context: *anyopaque, _: z.Window, point: z.Point) z.WindowHit {
    const self: *Chrome = @ptrCast(@alignCast(context));
    const caption = self.caption orelse return .client;
    return if (caption.contains(point)) .caption else .client;
}

const window = try app.createWindow(.{
    .decoration = .custom,
    .hit_test = .{ .context = &chrome, .hit = Chrome.hit },
});
```

用声明式视图时更简单：给标题区域的指针区域设 `drag_window`，Host 会在空白处按下时调用 `Window.startMove`，双击时执行系统的标题栏双击动作。完整示例见 `examples/frameless.zig`（`zig build run-frameless`），不支持自定义边框的环境（例如 Wayland）会退回系统边框。

## 透明与材质

```zig
const pet = try app.createWindow(.{
    .decoration = .borderless,
    .transparent = true,
    .skip_taskbar = true,
    .width = 320,
    .height = 240,
});
```

`transparent` 让绘制留空的地方透出桌面（Linux 需要合成器，`capabilities().transparent` 报告帧是否保留 alpha）。`vibrancy` 在窗口后面放一层系统材质：macOS 支持全部 NSVisualEffectView 材质与 macOS 26 的 Liquid Glass，Windows 11 22H2 起支持 Mica、Acrylic 与 Tabbed，Linux 不显示材质。原生 UI 里的玻璃效果见 [背景效果](../backdrop-effects.md)。

## 拥有关系、模态与弹出窗口

```zig
const dialog = try app.createWindow(.{ .title = "设置", .owner = editor, .modal = true });
try settings_host.attach(dialog);
try dialog.perform(.show); // 不运行嵌套消息循环
```

- 模态窗口显示期间，整棵拥有树只有它及其后代可以交互；关闭或隐藏后恢复。
- `popup` 角色把 `.borderless` 窗口变成弹出窗口：没有任务栏条目，可以不抢键盘，点到别处时通知应用关闭。大多数应用直接用 `system.Flyout`（见 [菜单、托盘与桌面 API](./desktop.md#浮出窗口)）。

## 窗口内容

每个窗口有一个内容所有者：

| 内容 | 模块 | 用途 |
| --- | --- | --- |
| `view.Host` | `ziggurat_view` | 声明式原生 UI，见 [原生 UI](../ui/) |
| `ui.Context` | `ziggurat_ui` | 直接录制 Frame 的底层自绘 UI |
| `web.View` | `ziggurat_webview` | 系统 WebView 页面，见 [网页前端](./frontend.md) |

同一窗口里组合多个区域（例如原生侧栏 + 矩形 WebView），见 [窗口内容组合](../composition.md)。系统设施（菜单、托盘、快捷键）不占用内容，而是挂在窗口的 `system.Owner` 上。

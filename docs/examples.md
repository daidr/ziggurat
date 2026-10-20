# 示例应用

`examples/` 下的应用示例只使用公开模块，展示一个桌面应用通常需要的能力。每个示例都在 `build.zig` 的 `app_examples` 表中登记，Windows 与 Linux 上提供：

- `zig build run-<名称>`：构建并运行；
- `zig build example-<名称>`：只编译并安装这一个示例到 `zig-out/bin/`；
- `zig build examples`：编译全部示例；`zig build check` 同样编译它们；
- `zig build test-examples`：运行示例里用 `view.Harness` 写的无窗口测试，也包含在 `zig build test` 中。

| 名称 | 文件 | 展示内容 |
| --- | --- | --- |
| `hello` | [hello.zig](../examples/hello.zig) | 最小应用：构建函数、固定存储、Host attach 与 `App.run` |
| `todo` | [todo.zig](../examples/todo.zig) | 文本输入添加条目、复选框完成、分段筛选、按键保持列表项身份 |
| `notes` | [notes.zig](../examples/notes.zig) | 文档应用模型：每文件一个窗口、新建/打开/保存/另存为、标题中的未保存标记、关闭与退出前询问、定时自动保存、最近文档；文件 I/O 在应用自己的 worker 上 |
| `gallery` | [gallery.zig](../examples/gallery.zig) | 控件总览：侧栏列表 + 分栏 + 滚动页，覆盖按钮、选择、数值、导航、集合、表单与反馈（提示、通知）控件 |
| `frameless` | [frameless.zig](../examples/frameless.zig) | 无边框窗口与自绘标题栏：标题区命中为 caption、最小化/最大化/关闭、边缘缩放；不支持自定义边框时退回系统边框 |
| `menubar` | [menubar.zig](../examples/menubar.zig) | 菜单栏（快捷键、勾选项、子菜单）、右键上下文菜单、托盘图标及其菜单、非阻塞消息框 |
| `clipboard` | [clipboard.zig](../examples/clipboard.zig) | 剪贴板文本/HTML/文件写入、延迟提供、变化通知与按格式读取 |
| `drag-drop` | [drag_drop.zig](../examples/drag_drop.zig) | 窗口作为拖放目标：悬停状态、按类型接受、显示拖入的路径或文本 |
| `text-input` | [text_input.zig](../examples/text_input.zig) | 表单字段校验、多行文本、带建议的可编辑组合框、标记输入框 |
| `code-editor` | [code_editor.zig](../examples/code_editor.zig) | 等宽多行编辑、词法着色（范围标记）、行号栏、查找替换、打开/保存、状态栏行列 |
| `chart-streaming` | [chart_streaming.zig](../examples/chart_streaming.zig) | 实时图表：环形缓冲、两条序列、暂停/继续；只在采样运行时装定一次性唤醒 |
| `piano` | [piano.zig](../examples/piano.zig) | 音频：代码合成音色、鼠标与键盘弹奏、波形与音量、八度变速 |
| `launcher` | [launcher.zig](../examples/launcher.zig) | 全局快捷键唤出窗口、搜索过滤、方向键与回车执行、Escape 隐藏、Shell 打开 |
| `timeline` | [timeline.zig](../examples/timeline.zig) | 动画时间线：多轨缓动、播放/暂停/反向/拖动定位、减少动态效果；只在播放时唤醒 |
| `i18n` | [i18n.zig](../examples/i18n.zig) | 运行时切换语言（英文、中文、阿拉伯文、俄文）、复数规则、数字与日期格式化、窗口标题更新 |
| `farm` | [farm.zig](../examples/farm.zig) | 小游戏：`ziggurat_game` 固定步长循环、按位置的 WASD/方向键、手柄左摇杆与按键、跟随相机（3 倍、整像素）、帧间插值、失去键盘时暂停 |
| `hybrid` | [hybrid.zig](../examples/hybrid.zig) | 混合应用：原生侧栏 + 矩形区域中的系统 WebView 页面，双向消息；需要 `-Dwebview=true` |

早期示例 `counter`、`view-counter`、`web-counter`、`rectangular-pages` 与 `counter_service.zig`（IPC 客户端生成）保持不变。Markdown、终端与浮出窗口的示例等对应模块合入后再补。

## 运行说明

- 示例在 Linux 的 Xvfb 中启动并保持运行，测试块在无窗口 Harness 中通过；交互（拖动标题、菜单点击、真实拖放、托盘、发声）没有在自动检查中验证。
- `launcher` 的全局快捷键与 `frameless` 的自定义边框在 Wayland 上不可用，示例会显示说明并退回。
- `piano` 在没有音频设备时按模块规则静音运行，并在状态行报告原因。
- `notes` 与 `code-editor` 接受一个文件参数：`zig build run-notes -- 文件.txt`。

## 编写示例时发现的 API 缺口

以下是示例只能绕开实现、留待后续补齐的公开 API：

**视图与输入**
- `view.Host` 没有给应用的右键、中键、双击事件，也没有应用级快捷键或“无人处理的按键”钩子；`menubar`、`piano`、`launcher` 只能包装 `host.context.on_input`。
- 按键抬起只交给嵌入叶子（`EmbedInput.key_up`），`piano` 仍用固定时长的音符。
- 在绘制之外拿不到节点的窗口坐标；`frameless` 用嵌入叶子的 `place` 记录标题区。
- 没有指针光标形状与自定义按钮的悬停外观。
- `view.Host` 不能作为组合区域的背景层 attach，`hybrid` 的侧栏只能用 Frame API。
- 布局不能按从右到左镜像，`i18n` 只把阿拉伯文对齐到尾端。
- 没有会换行的多行静态文本，也没有声明式的虚拟列表；每帧 128 个控件的上限让列表示例需要固定条目上限。
- `Harness.click` 不接受 `listItem`。

**文本编辑**
- `editing.Field`/`TextField` 没有密码（掩码）选项，值上限 16 KiB，没有区间替换、按范围着色文字和行号栏；`code-editor` 以背景色范围标记着色，并借助 `viewportAnchor`/`positionRect` 自建行号。
- `TextField` 没有 attach 完成通知与 `focus()`；`submit`/`changed` 回调在输入处理中运行，`Field.setValue` 必须用 `App.post` 推迟。
- `editing.Field` 需要同步剪贴板，而系统剪贴板读取是异步的（同步 `readText`/`writeText` 只在 Windows 提供）。

**系统设施**
- 只能接收拖放，不能从窗口发起拖出（`drag_source` 为 false）。
- 托盘与菜单图标没有可移植的来源（Windows 为 `HICON`，Linux 为 `GdkPixbuf`），菜单项没有图标；Linux 上没有托盘宿主时 `show` 仍成功，应用无法得知图标是否可见。
- 剪贴板没有清空接口，也没有图片（PNG）解码与显示的便捷函数。
- `shell.Worker` 需要应用自建线程，没有主线程一次性异步打开 URL/路径的辅助。
- 没有按应用划分的数据/配置目录 API；`notes` 在 worker 中调用 `std.fs.getAppDataDir`。

**文档、图表与动画**
- 文档应用没有共享的文件 I/O worker，每个应用都要自建线程、队列与 join；在还没有窗口时不能先打开文件（没有窗口时 `App.run` 立即返回）。
- 用户关闭窗口时，图表没有文档化的“在 Context detach 之前”释放点；`chart-streaming` 在 `on_close` 中释放并在 `run` 后再次释放，`App.quit` 会跳过 `on_close`。
- 缓动只有 linear、smoothstep 与 cubic_out；播放头没有无限循环（重复次数有限）。
- WebView 没有“带本地资源加载页面”的一步式辅助，持久 Profile 与 ephemeral 要按平台手动选择。

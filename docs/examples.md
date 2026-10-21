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
| `notes` | [notes.zig](../examples/notes.zig) | 文档应用模型：Markdown 与文本笔记每文件一个窗口、新建/打开/保存/另存为、标题中的未保存标记、关闭与退出前询问、定时自动保存、最近文档、字数；崩溃或强制退出后恢复未保存内容；其他程序改动文件时未编辑的笔记自动重载，已编辑的显示横幅选择保留或还原；文件 I/O 在应用自己的 worker 上，目录监视在另一个线程 |
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
| `loading` | [loading.zig](../examples/loading.zig) | 全部 29 种加载指示器分页展示，尺寸、颜色、缓动、线端与暂停选项；暂停时不装定任何唤醒 |
| `terminal` | [terminal.zig](../examples/terminal.zig) | 用户的 shell 运行在终端视图中：窗口标题跟随 shell，shell 退出后关闭窗口 |
| `text-buffer` | [text_buffer.zig](../examples/text_buffer.zig) | 10 万行混合文字的大文档直接由编辑器 Adapter 编辑：只排版视口附近的行，状态行读取文档索引中的行数、字符数与版本 |
| `native` | [native.zig](../examples/native.zig) | 桌面集成一览：菜单栏（快捷键、勾选、互斥项）、右键菜单、托盘、多选文件对话框、问答消息框、通知、全局快捷键 Ctrl+Shift+Space、剪贴板、深色模式与系统外观变化、主显示器信息 |
| `hybrid` | [hybrid.zig](../examples/hybrid.zig) | 混合应用：原生侧栏 + 矩形区域中的系统 WebView 页面，双向消息；需要 `-Dwebview=true` |

早期示例 `counter`、`view-counter`、`web-counter`、`rectangular-pages` 与 `counter_service.zig`（IPC 客户端生成）保持不变。Markdown 与浮出窗口的示例等对应模块合入后再补。

## 运行说明

- 示例在 Linux 的 Xvfb 中启动并保持运行，测试块在无窗口 Harness 中通过；交互（拖动标题、菜单点击、真实拖放、托盘、发声）没有在自动检查中验证。
- `launcher` 的全局快捷键与 `frameless` 的自定义边框在 Wayland 上不可用，示例会显示说明并退回。
- `piano` 在没有音频设备时按模块规则静音运行，并在状态行报告原因。
- `notes` 与 `code-editor` 接受一个文件参数：`zig build run-notes -- 文件.txt`。
- `notes` 的恢复快照写在应用数据目录的 `ziggurat-notes/recovery` 下；Xvfb 中验证过外部改动后的自动重载，以及从未正常结束的会话恢复无标题笔记和带冲突标记的文件笔记。
- `native` 在关闭窗口时隐藏到托盘（托盘可用时），从托盘或全局快捷键唤回；Linux 上托盘需要 status-notifier 宿主，通知需要通知守护进程。

## 编写示例时发现的 API 缺口

以下是示例只能绕开实现、留待后续补齐的公开 API：

**视图与输入**
- `view.Host` 不能作为组合区域的背景层 attach，`hybrid` 的侧栏只能用 Frame API。
- 每帧 128 个控件的上限让不用虚拟集合的列表示例需要固定条目上限。

**文本编辑**
- `editing.Field`/`TextField` 没有密码（掩码）选项，值上限 16 KiB，没有区间替换、按范围着色文字和行号栏；`code-editor` 以背景色范围标记着色，并借助 `viewportAnchor`/`positionRect` 自建行号。
- `editing.Field` 的值上限是 16 KiB，而且每次提交都复制整个值，大文档不能放进声明式视图；视图也不把原生文本输入转给嵌入叶子。`text-buffer` 因此不用 `view.Host`，直接在 `ui.Context` 中驱动 `editing.Adapter`，自己绘制标题与状态行。
- `submit`/`changed` 回调在输入处理中运行，`Field.setValue` 必须用 `App.post` 推迟。
- `editing.Field` 需要同步剪贴板，而系统剪贴板读取是异步的（同步 `readText`/`writeText` 只在 Windows 提供）。

**系统设施**
- 只能接收拖放，不能从窗口发起拖出（`drag_source` 为 false）。
- 菜单项没有单选（radio）类型，`native` 用两个勾选项和 `setItemState` 模拟互斥。
- 最后一个窗口关闭时 `App.run` 返回，没有“只留托盘继续运行”的选项；`native` 在关闭时改为隐藏窗口。
- 主题不会自动跟随系统外观；`native` 用 `desktop.Watch` 监听偏好变化后调用 `setTheme`。
- 同步剪贴板读写只在 Windows 提供，`terminal` 的复制粘贴在 Linux 上不可用；终端里 Ctrl+点击链接需要应用自建 `shell.Worker`，示例没有接入。
- 一帧最多绘制 `ui.loading.max_entries`（16）个加载指示器，视图不做裁剪，`loading` 因此分页显示。
- 目录监视器只能在自建线程上使用；被删除的监视根不会自动恢复，`notes` 在打开的笔记集合变化时才重新添加。
- 托盘与菜单图标没有可移植的来源（Windows 为 `HICON`，Linux 为 `GdkPixbuf`），菜单项没有图标；Linux 上没有托盘宿主时 `show` 仍成功，应用无法得知图标是否可见。
- 剪贴板没有清空接口，也没有图片（PNG）解码与显示的便捷函数。
- `shell.Worker` 需要应用自建线程，没有主线程一次性异步打开 URL/路径的辅助。
- 没有按应用划分的数据/配置目录 API；`notes` 在 worker 中调用 `std.fs.getAppDataDir`。

**文档、图表与动画**
- 文档应用没有共享的文件 I/O worker，每个应用都要自建线程、队列与 join；在还没有窗口时不能先打开文件（没有窗口时 `App.run` 立即返回）。
- 用户关闭窗口时，图表没有文档化的“在 Context detach 之前”释放点；`chart-streaming` 在 `on_close` 中释放并在 `run` 后再次释放，`App.quit` 会跳过 `on_close`。
- 缓动只有 linear、smoothstep 与 cubic_out；播放头没有无限循环（重复次数有限）。
- WebView 没有“带本地资源加载页面”的一步式辅助，持久 Profile 与 ephemeral 要按平台手动选择。

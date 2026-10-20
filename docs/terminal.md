# 终端

`ziggurat_terminal` 是可选模块：在伪终端上运行程序（Linux 为 Unix PTY，Windows 为 ConPTY 伪控制台），把程序输出解释成带 scrollback 的字符网格，并把按键、粘贴、鼠标和焦点编码成程序期望的转义序列。它只依赖核心的 `App.post`。`ziggurat_terminal_view` 是声明式视图中的终端叶子，额外依赖 UI 与视图模块。

```zig
const term = @import("ziggurat_terminal");
const terminal_view = @import("ziggurat_terminal_view");

// 应用持有终端与视图，二者地址在显示期间保持不变。
var terminal = try term.Terminal.init(allocator, .{ .screen = .{ .scrollback = 5000 } });
defer terminal.deinit();
var tv = terminal_view.TerminalView.init(&host, allocator, &terminal, .{ .clipboard = clipboard, .notify = notify });
tv.bind();
try host.context.prepareTextFields(allocator, .{}); // 终端作为文本字段接收输入

// 在 build 回调里：
try v.embed(tv.embed(), .{ .grow = 1, .self_align = .stretch, .key = 2 });

// 网格尺寸在第一帧后确定，再以该尺寸启动 shell：
const session = try term.Session.spawn(allocator, app, .{ .size = tv.applied.? }, tv.sink(), .{});
tv.attachSession(session);
// 结束时：
tv.detach();
session.close();
```

## 会话与线程

- `Session.spawn` 在主线程调用，启动程序并创建显式的读、写线程（Windows 另有一个等待进程退出的线程）。线程在无事可做时阻塞在 `poll`/事件上，不轮询。没有隐藏的线程池。
- 输出先进入有界环形缓冲（默认 256 KiB），满了以后读线程停止读取，程序的写入因此在伪终端上阻塞，这就是背压。主线程经 `App.post` 一次取一块（默认 32 KiB）交给 `Sink.output`；同一时间最多排队一个投递任务。
- `write` 把字节整体放入输入环（默认 64 KiB），空间不足返回 `Full`，会话已关闭或写端结束返回 `Closed`，失败时不保留任何字节。`writable` 给出当前空间。
- 程序退出后，剩余输出先全部交付，`Sink.exited` 才在主线程调用一次。Linux 上被信号杀死报告 `.signal`，其余报告退出码。
- `close` 不阻塞：之后 `Sink` 不再被调用；工作线程先向程序的进程组发 SIGHUP，程序在 2 秒内不退出就 SIGKILL（Windows 直接结束进程），回收子进程，最后一个线程释放会话。`liveSessions()` 给出尚未释放的会话数。App 停止投递后会话不再投递，只等 `close` 收尾。
- `Command` 设置程序与参数（为空时 Linux 用 `SHELL` 或 `/bin/sh`，Windows 用 `COMSPEC` 或 `cmd.exe`）、工作目录、追加或覆盖的环境变量和初始尺寸。Linux 上子进程是新会话的首进程，伪终端是它的控制终端，`TERM` 默认 `xterm-256color`，并设置 `COLORTERM=truecolor`。Windows 的伪控制台函数在运行时从 kernel32 加载，系统不提供时 `spawn` 返回 `Unsupported`。
- `resize` 同时更新伪终端尺寸（含像素尺寸），Linux 上程序收到 SIGWINCH。

## 解析与屏幕

- 解析器是纯 Zig 的 DEC/ANSI 状态机：UTF-8（非法字节显示为 U+FFFD）、C0 控制、ESC、CSI（含私有前缀、中间字节和冒号子参数）、OSC（BEL 或 ST 结束，超过 `osc_bytes` 的整条丢弃）；DCS、APC、PM、SOS 被安全跳过，CAN/SUB 取消当前序列。
- 屏幕是固定的单元网格，每个单元带码点、宽度（窄、宽、宽字符右半）和样式。样式包括前景、背景、下划线颜色（默认、256 色调色板、24 位真彩），粗体、暗淡、斜体、闪烁、反显、隐藏、删除线、上划线，以及单线、双线、波浪、点线、虚线下划线。
- 光标移动与保存恢复、自动换行与延迟换行、插入模式、原点模式、滚动区（DECSTBM）、制表位、插入/删除行与字符、擦除（ED/EL/ECH，含选择性清除 scrollback 的 `ED 3`）、重复（REP）、DEC 线框字符集、`DECALN`、软硬复位。
- 主屏顶部滚出的行进入 scrollback：按行裁掉尾部空白后存入有界环，同时受行数（`scrollback`）和单元总数（`scrollback_cells`）两个上限约束。备用屏（1047/1048/1049）没有 scrollback。查看历史时视口保持在原内容上，新输出不把它拉回底部。
- 改变尺寸时不重排已换行的段落：行数减少时顶部的行推入 scrollback 以保持光标所在的行，增加时从 scrollback 拉回。
- 宽字符按东亚宽度表占两格，零宽字符与组合字符不占格。写入时覆盖宽字符的一半会清掉另一半。
- 回复：DA1/DA2、XTVERSION、DSR 状态与光标位置、DECRQM、窗口与单元像素尺寸（`CSI 14/16/18 t`），以及 OSC 4/10/11/12 颜色查询。回复累积在 `pendingReplies()`，视图把它们写回程序。
- OSC：0/2 标题、7 当前目录、8 超链接（id 存在固定容量的环里，滚走的链接自然失效）、4/104 调色板、10/11/12 与 110/111/112 默认颜色、52 剪贴板。
- **OSC 52 默认拒绝**：`ClipboardPolicy` 的 `read` 与 `write` 都默认 `false`，被拒绝的请求直接丢弃，不分配。允许写入时事件 `clipboard_write` 交给应用，允许读取时由 `answerClipboard` 回复。

## 输入编码

- 方向、Home/End、Insert/Delete、PageUp/PageDown、F1–F12 按 xterm 规则编码，带修饰键时附加参数 `1 + Shift + 2·Alt + 4·Ctrl + 8·Super`；应用光标键（DECCKM）与应用小键盘模式用 SS3 形式。Ctrl+字母、Ctrl+@/[/\\/]/^/_、Alt 前缀 ESC、Backspace 发 DEL、Enter 在换行模式下发 CR LF。普通可打印字符不在这里编码，而是经文本输入（含输入法）原样发送。
- 粘贴在程序打开 bracketed paste（2004）时包上 `ESC[200~`/`ESC[201~`，并去掉文本中的 ESC，使粘贴内容无法提前结束粘贴，换行统一成 CR；未打开时只做换行转换。
- 鼠标上报支持 X10（9）、普通（1000）、按键拖动（1002）、任意移动（1003）四种跟踪，以及 X10、UTF-8（1005）、SGR（1006）、urxvt（1015）、SGR 像素（1016）五种编码；焦点上报（1004）。

## 视图

- 叶子按单元格绘制：每行先画合并后的背景色段，再按相同颜色与字体合并成文本段，宽字符逐个画在自己的格子上，保证网格不被后备字体的字宽推移。下划线、删除线、上划线用矩形画出。每帧接近命令上限时停止追加文本，而不是让整帧失败。未变化的终端重绘不分配、不投递任务；空闲时没有任何定时器。
- 光标支持方块、下划线、竖线三种形状；失焦时画空心方块。正在组合的输入法文本显示在光标处并加下划线，输入法候选窗跟随光标。
- 尺寸：在绘制时计算网格，变化时投递一个任务调整屏幕与伪终端尺寸，并在同一任务里注册为 Context 的文本字段，从不在绘制中注册或改尺寸。单元尺寸默认由测量器按等宽字体计算，也可以指定。
- 键盘：Ctrl+Shift+C/V 与 Ctrl+Insert/Shift+Insert 复制粘贴；有选区时 Ctrl+C 复制并清除选区，否则发送中断；Shift+PageUp/PageDown/Home/End 滚动 scrollback；其余按键编码后发给程序，输入时视口回到底部。
- 指针：拖动选择、双击选词、三击选行，Shift+点击扩展选区，拖出上下边缘时滚动；`copy_on_select` 让选区结束时自动复制。程序跟踪鼠标时按下、拖动、松开和滚轮上报给程序，按住 Shift 仍可本地选择。Ctrl+点击链接经 `Notice.open` 交给应用打开；悬停时链接显示下划线。链接来自 OSC 8，或文本中识别出的 `http(s)`、`ftp`、`file`、`ssh`、`git`、`mailto` 地址（去掉末尾的标点与不配对的括号）。
- 滚轮：每格 3 行（可配置）滚动 scrollback；备用屏上若程序未跟踪鼠标，按 1007 模式（默认开启）发送上下方向键。
- 通知：响铃、标题、当前目录、程序退出、打开链接都经 `Options.notify` 在主线程交给应用；剪贴板读写经 `Options.clipboard` 由应用提供。没有 `Session` 时可用 `Options.send` 接收发给程序的字节。
- 可访问性：叶子发布 `text_box` 语义节点，名称取 `Options.name`，值为光标所在行的文本。

## 限制

- 非主按钮的按下只在程序跟踪鼠标时上报；本地右键菜单与中键粘贴未实现。
- 改变宽度时不按软换行重排段落。
- 不渲染 Sixel 等图像协议，DCS 内容被跳过。

## 验证

`zig build test-terminal` 已接默认 test/check：解析器状态机与 UTF-8、宽度表、屏幕编辑与滚动区、scrollback 上限与改尺寸、备用屏、SGR 全部形式、回复、OSC 标题/颜色/超链接/剪贴板策略、按键/粘贴/鼠标/焦点编码、选择文本与链接识别；Linux 上真实 PTY 的终端判定、环境变量、尺寸与退出码，会话的回显、按序交付、背压、退出只报告一次，以及忽略 SIGHUP 的程序被强制结束；视图的网格计算、按键/文本/粘贴/回复、选择与复制、鼠标上报、滚轮滚动 scrollback 与备用屏方向键。`zig build smoke-terminal` 在隐藏窗口里显示终端叶子，以实际网格尺寸启动 shell，经平台文本输入路径输入命令、经原生按键发送回车，确认 shell 的输出出现在屏幕上、`stty size` 与网格一致（Linux），再退出 shell 并确认会话释放、无资源泄漏。Windows 的 ConPTY 路径由交叉编译和 CI 的 Windows smoke 运行覆盖。

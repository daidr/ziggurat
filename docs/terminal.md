# 终端

`ziggurat_terminal` 是可选模块：在伪终端上运行程序（Linux 为 Unix PTY，Windows 为 ConPTY 伪控制台），把程序输出解释成带 scrollback 的字符网格，并把按键、粘贴、鼠标和焦点编码成程序期望的转义序列。它只依赖核心的 `App.post`。`ziggurat_terminal_view` 是声明式视图中的终端叶子，额外依赖 UI 与视图模块。

```zig
const term = @import("ziggurat_terminal");
const terminal_view = @import("ziggurat_terminal_view");

// 应用持有终端与视图，二者地址在显示期间保持不变。
var terminal = try term.Terminal.init(allocator, .{ .screen = .{ .scrollback = 5000 } });
defer terminal.deinit();
var tv = terminal_view.TerminalView.init(&host, allocator, &terminal, .{ .clipboard = clipboard, .notify = notify });
defer tv.deinit();
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

- 解析器是纯 Zig 的 DEC/ANSI 状态机：UTF-8（非法字节显示为 U+FFFD）、C0 控制、ESC、CSI（含私有前缀、中间字节和冒号子参数）、OSC（BEL 或 ST 结束，超过 `osc_bytes` 的整条丢弃）、APC（分段交给处理方，承载 Kitty 图像）；DCS、PM、SOS 被安全跳过，CAN/SUB 取消当前序列。
- 屏幕是固定的单元网格，每个单元带码点、宽度（窄、宽、宽字符右半）和样式。样式包括前景、背景、下划线颜色（默认、256 色调色板、24 位真彩），粗体、暗淡、斜体、闪烁、反显、隐藏、删除线、上划线，以及单线、双线、波浪、点线、虚线下划线。
- 光标移动与保存恢复、自动换行与延迟换行、插入模式、原点模式、滚动区（DECSTBM）、制表位、插入/删除行与字符、擦除（ED/EL/ECH，含选择性清除 scrollback 的 `ED 3`）、重复（REP）、DEC 线框字符集、`DECALN`、软硬复位。
- 主屏顶部滚出的行进入 scrollback：按行裁掉尾部空白后存入有界环，同时受行数（`scrollback`）和单元总数（`scrollback_cells`）两个上限约束。备用屏（1047/1048/1049）没有 scrollback。查看历史时视口保持在原内容上，新输出不把它拉回底部。
- 宽度变化时主屏与 scrollback 按软换行重排（回流）：软换行的行先接回成一段，再按新宽度换行；放不下的宽字符整个移到下一行，在行尾留空格，再变宽时这个空格去掉。光标停在原来的字符上（等待换行的状态也保留），`Terminal.resize` 的 `tracked` 位置（视图的选区两端）与主屏放置的 Kitty 图像随所在格子移动，scrollback 滚回的位置也跟着所在行。原本占满屏幕时保持底部对齐，否则保持顶部那一行不动；光标始终可见。备用屏不重排，只在右侧截断。行数减少时顶部的行推入 scrollback 以保持光标所在的行，增加时从 scrollback 拉回。
- 宽字符按东亚宽度表占两格，零宽字符与组合字符不占格。写入时覆盖宽字符的一半会清掉另一半。
- 回复：DA1/DA2、XTVERSION、DSR 状态与光标位置、DECRQM、窗口与单元像素尺寸（`CSI 14/16/18 t`），以及 OSC 4/10/11/12 颜色查询。回复累积在 `pendingReplies()`，视图把它们写回程序。
- OSC：0/2 标题、7 当前目录、8 超链接（id 存在固定容量的环里，滚走的链接自然失效）、4/104 调色板、10/11/12 与 110/111/112 默认颜色、52 剪贴板。
- **OSC 52 默认拒绝**：`ClipboardPolicy` 的 `read` 与 `write` 都默认 `false`，被拒绝的请求直接丢弃，不分配。允许写入时事件 `clipboard_write` 交给应用，允许读取时由 `answerClipboard` 回复。

## 图像

程序用 Kitty 图像协议（`ESC _ G 键=值,… ; 载荷 ESC \`）显示图片，行为与 Ghostty 一致：

- 传输：`a=t` 只传、`a=T` 传并放置、`a=q` 查询（只检查能否读取，不保存）。格式 `f=24`（RGB）、`f=32`（RGBA，默认）、`f=100`（PNG，纯 Zig 解码，支持全部颜色类型、位深与隔行，`tRNS` 透明）；`o=z` 为 zlib 压缩；`m=1` 分块传输，后续块沿用第一块的键。介质 `t=d` 直接载荷，`t=f` 文件（`S`、`O` 取其中一段，拒绝 `/proc`、`/sys`、`/dev`），`t=t` 临时文件（须在临时目录且路径含 `tty-graphics-protocol`，读后删除），`t=s` 共享内存（Linux，读后删除）。宽高不超过 10000，单张数据不超过 400 MB。
- 编号：`i` 为图片 id，`I` 为图片编号（终端分配 id，回复同时带两者，按编号放置取最新的那张），两者都没给时终端分配 id 且不回复。同一 id 再传替换像素，原有放置保留。
- 放置：`a=p` 或 `a=T` 放在光标处；`x/y/w/h` 取图片的一部分，`c/r` 指定占用的格数（只给一个时保持宽高比），`X/Y` 是首格内的像素偏移，`z` 决定层次：小于 -2^30 画在格子背景之下，负数画在文字之下，其余画在文字之上，同层按 z 排序。`p` 为放置 id，同一图片同一 id 再次放置即移动；`C=1` 不移动光标，否则光标移到最后一行、最后一列之后。`U=1` 的虚拟放置被接受但不绘制。放置随文字滚动进入 scrollback，滚出 scrollback 后删除。
- 删除 `a=d`：`d=a` 全部、`i` 按 id（可带 `p`）、`n` 按编号、`c` 光标所在格、`p` 指定格、`q` 指定格且 z 相同、`x` 列、`y` 行、`z` 层、`r` id 区间；小写只删放置，大写同时释放不再被放置的图片。
- 回复 `ESC _ G i=…[,I=…][,p=…];OK ESC \` 或 `ENOENT`、`EINVAL`、`ENOMEM` 等错误；`q=1` 不回复成功，`q=2` 都不回复。
- 主屏与备用屏各有自己的图片；`ED 2` 清屏时清除当前屏的图片，进入 1049 备用屏、离开 1047 时清除备用屏的，`RIS` 全部清除。每屏的图片总量受 `Options.image_limit` 约束（默认 320 MB），超出时先淘汰未被放置的最旧图片，再淘汰最旧的；为 0 时拒绝所有图片命令（不回复），程序因此改用其他显示方式。
- 视图在绘制时遇到尚未上传的图片就投递任务，在任务里把可见放置的图片转成预乘 BGRA 上传到窗口（超出窗口单图上限时按比例缩小），不再可见或已删除的图片在任务里释放，像素在没有帧引用后才回收。绘制时整张图按放置缩放后裁剪到放置区域与网格内，不另做裁剪上传。

## 镜像、快照与历史

服务端保持会话运行、窗口在别的进程里显示时（如终端复用器），服务端的 `Terminal` 接收程序输出，窗口的终端只显示服务端发来的帧：

- `Mirror.init(allocator, &terminal)` 为一个窗口建立镜像，`frame(&out, now_ms)` 把“让已显示之前各帧的终端变成现在这样”的 VT 序列追加到 `out`，没有变化时什么也不追加。窗口的终端像读程序输出一样读这些帧，于是逐格显示服务端的屏幕与 scrollback、光标、改变它发送内容的模式（光标键、小键盘、鼠标跟踪与编码、焦点、bracketed paste、反显）、指针形状、程序设置的颜色（OSC 4/10/11/12，未设置的复位为窗口自己的主题）、标题和 Kitty 图像。它从不自己排布程序的输出，因此不会显示成别的样子。
- 帧在原位绘制行；滚出屏幕的行按顺序从窗口屏幕顶部经过，使窗口的 scrollback 与服务端一致，软换行保持为软换行，每个格子带自己的样式。首帧、尺寸变化后的帧以及无法跟上的切换会让窗口终端从头开始；scrollback 被清空时帧带上 `ED 3`。程序持有同步更新（2026 模式）时最多一秒内不出帧，`frame` 返回 true 表示稍后还有一帧。`reset` 让下一帧从头开始，一个终端可以有任意多个镜像。
- 光标形状：程序未改动时发 `DECSCUSR 0`，由窗口终端自己的设置决定；程序设置了就沿用程序的。
- 剪贴板：程序写剪贴板（OSC 52）随帧传给窗口终端，由窗口按自己的策略处理；服务端 `ClipboardPolicy.forward_read` 打开时，程序的读取随第一个出帧的镜像转发给窗口回答，服务端自己不回答。
- 窗口侧的视图设 `resize_by_conn`：视图只把适合的网格尺寸和单元像素尺寸经 `Options.conn.resize` 告诉服务端，屏幕保持原尺寸，直到应用在服务端流说明已改尺寸时调用 `TerminalView.resize`。`Options.conn.theme` 把视图采用的主题告诉服务端。服务端用 `Terminal.resizePixels` 与 `Terminal.useTheme` 接收，程序查询像素尺寸或颜色时得到窗口的值。用户的清屏由服务端执行：窗口用 `hooks.clear` 转给服务端，服务端调用 `Terminal.clearScreen`，下一帧显示结果。
- `snapshot(allocator, &terminal)` 返回终端显示的全部内容：scrollback、主屏（备用屏显示时也包括主屏）与当前屏的样式文本、图像、光标、模式、颜色、标题，以及自动换行、插入、换行模式和字符集。喂给同尺寸的新终端即显示相同内容。
- `history(allocator, &terminal)` 返回 scrollback 与屏幕直到光标所在行（若其下方为空则到最后一个非空行）的内容，不带光标与模式，供程序结束后接管会话的终端使用：喂进去后光标停在内容下方，下一个程序从下面开始。备用屏显示时返回 null。

## 输入编码

- 方向、Home/End、Insert/Delete、PageUp/PageDown、F1–F12 按 xterm 规则编码，带修饰键时附加参数 `1 + Shift + 2·Alt + 4·Ctrl + 8·Super`；应用光标键（DECCKM）与应用小键盘模式用 SS3 形式。Ctrl+字母、Ctrl+@/[/\\/]/^/_、Alt 前缀 ESC、Backspace 发 DEL、Enter 在换行模式下发 CR LF。普通可打印字符不在这里编码，而是经文本输入（含输入法）原样发送。
- 粘贴在程序打开 bracketed paste（2004）时包上 `ESC[200~`/`ESC[201~`，并去掉文本中的 ESC，使粘贴内容无法提前结束粘贴，换行统一成 CR；未打开时只做换行转换。
- 鼠标上报支持 X10（9）、普通（1000）、按键拖动（1002）、任意移动（1003）四种跟踪，以及 X10、UTF-8（1005）、SGR（1006）、urxvt（1015）、SGR 像素（1016）五种编码；焦点上报（1004）。

## 视图

- 叶子按单元格绘制：每行先画合并后的背景色段，再按相同颜色与字体合并成文本段，宽字符逐个画在自己的格子上，保证网格不被后备字体的字宽推移。下划线、删除线、上划线用矩形画出。每帧接近命令上限时停止追加文本，而不是让整帧失败。
- 线框（U+2500–U+257F，虚线除外）、方块元素（U+2580–U+259F）与 Powerline 分隔符（U+E0B0–U+E0B7）不取字体字形，而是按设备像素自行绘制：直线与方块是对齐像素的矩形，相邻格子的线严丝合缝，行高大于字形时也不留缝；圆角、斜线、三角与半圆按行扫描成带边缘覆盖率的线段。双线在拐角与交叉处按内外线衔接，阴影块（░▒▓）按 1/4、1/2、3/4 不透明度填充。同色相接的矩形合并成一个，满屏线框也只用少量绘制命令；命令余量不足时跳过需要逐行扫描的字符。方块光标下的这些字符用光标文字色重画。未变化的终端重绘不分配、不投递任务；空闲时没有任何定时器。
- 光标支持方块、下划线、竖线三种形状；失焦时画空心方块。正在组合的输入法文本显示在光标处并加下划线，输入法候选窗跟随光标。
- 尺寸：在绘制时计算网格，变化时投递一个任务调整屏幕与伪终端尺寸，并在同一任务里注册为 Context 的文本字段，从不在绘制中注册或改尺寸。单元尺寸默认由测量器按等宽字体计算，也可以指定。
- 指针：拖动选择、双击选词、三击选行，Shift+点击扩展选区，拖出上下边缘时滚动；`copy_on_select` 让选区结束时（以及全选时）自动复制。程序跟踪鼠标时按下、拖动、松开和滚轮上报给程序，按住 Shift 仍可本地选择。
- 滚轮：每格 3 行（可配置）滚动 scrollback；程序跟踪鼠标时上报滚轮；备用屏上按 1007 模式（默认开启）发送上下方向键；按住 Ctrl 时缩放。
- 通知：响铃、标题、当前目录、桌面通知（OSC 9、OSC 777）、程序退出、打开链接、复制、搜索进度与右键菜单请求都经 `Options.notify` 在主线程交给应用；剪贴板读写经 `Options.clipboard` 由应用提供。没有 `Session` 时可用 `Options.send` 接收发给程序的字节。
- 可访问性：叶子发布 `text_box` 语义节点，名称取 `Options.name`，值为光标所在行的文本。
- `TerminalView.deinit` 释放搜索用的缓冲与上传的图片。

## 主题

`Options.theme` 设置前景、背景、光标及其下文字、选区及选中文字、搜索匹配及其文字、16 色调色板（256 色的其余部分是 xterm 的色立方和灰阶）；`dark_theme` 同时设置时用于深色窗口。两者都不设时终端随窗口外观（由视图的 `ui.Theme` 背景判断）取 `term.theme.dark` 或 `term.theme.light`：窗口的背景与文字，配 Visual Studio Code 的调色板。`setTheme(theme, dark_theme)` 在运行中切换。程序仍可用 OSC 4/10/11/12 改色：程序设过的颜色在切换主题后保留，直到程序用 OSC 104/110/111/112 或 RIS 复位，复位后回到当前主题的颜色。

内置 Ghostty 附带的全部主题（来自 iTerm2-Color-Schemes，MIT 许可）：

```zig
const mocha = term.theme.builtinTheme("Catppuccin Mocha").?; // 先精确匹配，再忽略大小写
const latte = try term.theme.lookup(allocator, &env, "Catppuccin Latte");
var tv = terminal_view.TerminalView.init(&host, allocator, &terminal, .{ .theme = latte, .dark_theme = mocha });
```

`lookup` 与 Ghostty 一致：先找用户 Ghostty 主题目录里的同名文件（`$XDG_CONFIG_HOME/ghostty/themes`，默认 `~/.config/ghostty/themes`，Windows 无 XDG_CONFIG_HOME 时用 `%LOCALAPPDATA%\ghostty\themes`），再找内置主题；绝对路径直接读该文件。`names` 列出用户主题与内置主题（忽略大小写排序、去重），供选择器使用。`parse` 读 Ghostty 格式（`palette = 0=#45475a`、`background`、`foreground`、`cursor-color`、`cursor-text`、`selection-background/foreground`、`search-background/foreground`、`search-selected-background/foreground`），颜色为 `#rgb`、`#rrggbb`、`#rrrgggbbb`、`#rrrrggggbbbb` 或不带 `#` 的前两种；其他选项、第 16 个以后的调色板项、`cell-foreground`/`cell-background` 被忽略，未给出的颜色取 `dark`（背景为浅色时取 `light`）。搜索颜色缺省为 Ghostty 的浅琥珀与浅橙底、黑字。

## 搜索

`startSearch(text)` 在屏幕与 scrollback 中搜索（备用屏上只搜屏幕），除 ASCII 字母大小写外精确匹配，匹配可跨软换行；匹配高亮显示，并随新输出更新（在绘制后投递的任务里重新搜索，绘制本身不分配）。最新的匹配被选中并显示。`searchNext` 选向更旧输出的下一个，`searchPrevious` 反向，都会循环，且匹配不在视口内时滚动到视口中部，避开贴边的查找栏。再次搜索同一文本保留选中项，空文本或 `endSearch` 结束搜索。`Notice.search` 报告 `total` 与 `selected`（1 为最新）。终端不画查找栏，由应用绘制并绑定按键。

## 按键

按键依次经过 `Hooks.key`、按键绑定、程序。默认绑定是 Ghostty 在各平台的默认值（`term.keybind`）：

| 动作 | Linux 与 Windows | Windows 另有 |
| --- | --- | --- |
| `copy` | Ctrl+Shift+C、Ctrl+Insert | Ctrl+C（performable） |
| `paste` | Ctrl+Shift+V、Shift+Insert | Ctrl+V（performable） |
| `select_all` | Ctrl+Shift+A | |
| `clear_screen` | | Ctrl+Shift+K |
| `increase/decrease/reset_font_size` | Ctrl+=、Ctrl++、Ctrl+-、Ctrl+0 | |
| `scroll_page_up/down`、`scroll_to_top/bottom` | Shift+PageUp/PageDown，Linux 另有 Shift+Home/End | Ctrl+Shift+PageUp/PageDown/Home/End |

`Options.keybinds` 在默认值之上追加：同键同修饰的绑定替换默认值，绑定到 `.none` 即解绑（按键交给程序），`no_default_keybinds` 从空表开始。performable 绑定只在动作真正做了事时吞键：无选区时 Ctrl+C 仍是中断；performable 的复制会放开选区，下一次按键就到达程序。清屏与滚动绑定都是 performable，全屏程序照常收到。`.ignore` 吞键不做事。被钩子或绑定吞掉的按键不会再输入其文字。Super 组合键留给应用快捷键。

`clear_screen`（以及右键菜单的 Clear）清除 scrollback 和光标行以上的屏幕，光标行移到顶部，保留 shell 提示符；先询问 `Hooks.clear`，全屏程序的屏幕上不做。`clearScrollback` 只清 scrollback。缩放每步 1 DIP，最小 1，重置回 `Font.size`；`Hooks.zoom` 可以接管。

## 链接、右键与复制

- 按住 Ctrl 时，指针下的链接加下划线（Ctrl 的按下与松开由按键与按键释放得知），`hoveredLink()` 给出链接、是否文件路径及其相对视图的格子矩形，供应用显示预览；`pointerShape(shift)` 给出指针形状：链接上为手形，程序用 OSC 22 指定的形状，程序跟踪鼠标时为箭头（按住 Shift 选择时为 I 形），否则为 I 形。Ctrl+点击在程序跟踪鼠标时也会打开链接，这次按下的移动与松开都不再交给别人。
- 链接来自 OSC 8，或文本中的 `http(s)`、`ftp`、`file` 地址与 `mailto:`（去掉末尾的标点与不配对的括号）。设置 `Hooks.open_link` 后还识别文本中的文件路径（`/abs/path`、`~/notes.md`、`./a.go`、`src/app.go:12:3`、`main.go:250`）。钩子未接手的超链接与地址经 `Notice.open` 由应用交给系统打开，文件路径则不打开。
- `right_click` 决定副键点击：`.context_menu`（默认）发出 `Notice.context_menu`，应用在该点弹出 `contextMenu()` 给出的 Copy、Paste、Select All、Clear（Clear 前有分隔线，各项带绑定的快捷键，无选区时 Copy 不可用，全屏程序上 Clear 不可用）并把选中项交给 `choose`；`.paste`、`.copy`、`.copy_or_paste`（有选区复制，否则粘贴）、`.ignore`。复制会放开选区。程序跟踪鼠标时仍收到点击，除非按住 Shift。
- `Notice.copied` 报告终端写入剪贴板的文字与来源：`.user`（复制键、菜单、副键复制）、`.select`（`copy_on_select`）、`.program`（OSC 52）。

## 字体、对比度与留白

- `Options.font`：`size`（DIP，默认 13）、`weight`（100–900，映射到 UI 字体的常规、中等、半粗、粗体；粗体文字在此基础上加 300，至少 700）、`line_height`（行高倍数，文字在行内居中）。`setFont` 运行中更换字体并取消缩放。
- `minimum_contrast` 是文字与背景的最小 WCAG 对比度（1 到 21，默认 1 即不调整）：对比不足的文字向黑或白中与背景对比更大的一方混合，混合量是达到对比度所需的最小值；线框、方块、旧式计算机符号与 Powerline 符号保持原色。`setMinimumContrast` 运行中修改。
- `padding` 是网格四周的留白，横向 6、纵向 4 DIP，负值为无。`padding_color` 为 `.background`（默认）、`.extend`（每个格子都有自己背景色的行，把边缘格子的背景延伸到留白，顶行与底行向上下延伸，全屏程序的颜色因此铺满视图）或 `.extend_always`（所有行都延伸）；单独一个反显字符（程序自己画的光标）不延伸。`transparent` 不画终端背景，下面的内容透出，自有背景色的格子照常绘制。

## 限制

- 字体族与 OpenType 特性需要 UI 字体按族名选择与注册后才能接入；目前使用系统等宽字体。
- 指针形状由应用依 `pointerShape` 设置，视图本身不改变系统指针。
- 改变宽度时不按软换行重排段落。
- 不渲染 Sixel；Kitty 图像的动画帧（`a=f/a/c`）回复未实现，Unicode 占位符的虚拟放置不绘制。

## 验证

`zig build test-terminal` 已接默认 test/check：解析器状态机与 UTF-8、宽度表、屏幕编辑与滚动区、scrollback 上限与改尺寸、宽度变化时的回流（宽字符、等待换行、跟踪位置、图像与选区跟随）、自绘线框/方块/Powerline 字符的像素几何、备用屏、SGR 全部形式、回复、OSC 标题/颜色/超链接/剪贴板策略、按键/粘贴/鼠标/焦点编码、选择文本与链接识别；Linux 上真实 PTY 的终端判定、环境变量、尺寸与退出码，会话的回显、按序交付、背压、退出只报告一次，以及忽略 SIGHUP 的程序被强制结束；视图的网格计算、按键/文本/粘贴/回复、选择与复制、鼠标上报、滚轮滚动 scrollback 与备用屏方向键；主题（内置主题、主题文件、用户主题目录、程序改色在切换主题后保留）、搜索（跨 scrollback 与软换行、上下切换并滚动、随输出更新）、按键绑定（平台默认、performable、解绑与忽略、钩子吞掉文字）、缩放与清屏、副键动作与右键菜单、Ctrl 悬停与打开链接、文件路径识别、最小对比度；Kitty 图像（分块与 base64 解码、RGB/RGBA/PNG/zlib、放置与光标移动、按 id/格/层/区间删除、超限淘汰、随 scrollback 滚出、两屏分开与清屏清除、回复与静默）、PNG 解码（各种滤波、压缩、低位深与调色板、Adam7）以及图像的绘制位置与层次；镜像（逐格一致的屏幕与 scrollback、滚动、软换行与宽字符、超链接、清空 scrollback、备用屏切换、改尺寸、清屏，模式、颜色、标题、光标与剪贴板的传递，同步更新的延迟，图像的发送、放置与删除）、快照（含备用屏下的主屏与布局模式）和历史，以及视图把主题告诉连接、按连接改尺寸。`zig build smoke-terminal` 在隐藏窗口里显示终端叶子，以实际网格尺寸启动 shell，经平台文本输入路径输入命令、经原生按键发送回车，放置一张 Kitty 图像并确认它被上传、绘制、删除后释放，整屏绘制线框、方块、圆角、斜线与 Powerline 字符且不超出帧的命令上限，确认 shell 的输出出现在屏幕上、`stty size` 与网格一致（Linux），再退出 shell 并确认会话释放、无资源泄漏。Windows 的 ConPTY 路径由交叉编译和 CI 的 Windows smoke 运行覆盖。

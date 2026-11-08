# 自动化

`ziggurat_automation` 让另一个进程驱动正在运行的应用：端到端测试或 agent 列出应用的窗口，读取视图显示的元素，对元素执行操作，发送指针、滚轮、按键和文本输入，选择菜单栏里的项，在页面里求值脚本，把窗口截成 PNG，并等待窗口稳定。它在 Linux 和 Windows 上使用同一个协议：Unix 域套接字上的换行分隔 JSON。

元素就是视图交给辅助技术的那些，所以客户端看到的是屏幕阅读器看到的，并像屏幕阅读器那样操作它们；元素带有视图的 ID 和应用用 `Style.key` 给的 key。`view.Harness` 仍然是在 `zig build test` 里测试视图的方式；这个模块面向构建好的应用，从外部驱动。

客户端可以自己说[协议](#协议)，也可以运行 [`ziggurat-automation`](#命令行ziggurat-automation)，它是给 agent 用的命令行客户端。

## 打开

应用链接这个模块并在 `App.run` 之前启动服务；把它留在测试构建里，发布构建不链接：

```zig
const automation = @import("ziggurat_automation");

const server = try automation.start(allocator, app, .{});
try app.run();
if (server) |value| value.stop();
```

```sh
ZIGGURAT_AUTOMATION=/tmp/app.sock ./zig-out/bin/app
```

只有 `ZIGGURAT_AUTOMATION` 给出套接字路径时才监听，否则 `start` 返回 null，什么都不做；`Options.path` 可以代替环境变量。没有视图 inspector 的构建不包含它，和 inspector 一样：默认只有 Debug 构建带 inspector，`-Dinspector=true` 或 `-Dinspector=false` 改变这一点（`automation.enabled`），`ziggurat build` 默认的 ReleaseSafe 等发布构建不带。这样的构建链接了模块也会忽略 `ZIGGURAT_AUTOMATION`，并在标准错误上说明。

`start` 在主线程调用，分配器要线程安全；`stop` 在 `App.run` 返回之后、仍在主线程调用，它关闭连接、删除套接字并释放服务。路径上留着的、由没来得及关闭它就结束的应用留下的套接字会被替换；有应用在监听的套接字（`error.AddressInUse`）或不是套接字的文件（`error.NotSocket`）保持原样。

## 协议

客户端连接套接字后写请求，每行一个 JSON 对象。应用在单独一行回答每个请求，按顺序，前一个回答之后才处理下一个；需要并行的客户端（例如一个窗口 `idle` 的同时另一个窗口在操作）开多个连接。

```json
{"id": 1, "method": "tree", "params": {"window": 1}}
```

`id` 可以是任意 JSON 值，回答原样带回。回答有 `result`，或者有 `error`，其中 `code` 供程序判断，`message` 供人阅读：

```json
{"id": 1, "result": {"window": 1, "nodes": [...]}}
{"id": 2, "error": {"code": "no_window", "message": "no window 7"}}
```

| code | 含义 |
| --- | --- |
| `parse_error` | 这一行不是 JSON 对象（此时 `id` 为 `null`），或超过 16 MiB。 |
| `invalid_request` | 没有 method，方法不接受的参数，或无法使用的值。 |
| `unknown_method` | 没有这个方法。 |
| `no_window` | 没有这个 ID 的窗口，或应用没有窗口。 |
| `no_element` | 窗口上一帧没有这个 ID 或 key 的元素。 |
| `unsupported` | 窗口做不到，例如读取页面的元素。 |
| `timeout` | `idle` 在 `timeout` 之后放弃。 |
| `failed` | 应用没能做到，例如脚本抛出异常。 |

除 `windows` 外的方法都接受 `window`，即 `windows` 列出的 ID；省略时是获得焦点的窗口，否则是第一个。坐标和尺寸以 DIP 为单位，相对窗口内容区，与元素的 bounds 相同。应用退出时连接关闭，正在等待和之后的请求不再有回答。

| 方法 | 参数 | 结果 |
| --- | --- | --- |
| `windows` | | `{windows: [{id, title, kind, url?, bounds, contentBounds, focused, visible}]}` |
| `tree` | `window` | `{window, focus?, nodes: [...], announcements?}` |
| `act` | `window`、`id` 或 `key`、`action`、`text?`、`from?`、`to?` | `{}` |
| `input` | `window`、`events` | `{}` |
| `menu` | `window`、`path` | `{}` |
| `capture` | `window` | `{png, width, height}` |
| `eval` | `window`、`script` | `{value}` |
| `idle` | `window`、`timeout?` | `{}` |

### windows

列出打开的窗口，按打开顺序，ID 从 1 开始，窗口关闭前保持不变。`kind` 是原生界面窗口的 `content`，或显示网页的窗口的 `page`，后者给出 `url`（页面 `location.href` 的值）。`bounds` 与 `contentBounds` 都是 `{x, y, width, height}`：`contentBounds` 是内容区在屏幕上的位置和大小，`bounds` 是连同窗框（标题栏、边框）的整个窗口。窗框来自平台告诉的装饰尺寸（X11 的 `_NET_FRAME_EXTENTS` 或 GDK 的窗框范围、Windows 的 `GetWindowRect`），与 `contentBounds` 用同样的单位：位置是屏幕坐标，宽高是 DIP；平台不告诉窗框时（Wayland、macOS、没有窗口管理器的 X 服务器）两者相同。

```json
{"id": 1, "method": "windows"}
{"id": 1, "result": {"windows": [{"id": 1, "title": "Counter", "kind": "content", "bounds": {"x": 440, "y": 387, "width": 400, "height": 275}, "contentBounds": {"x": 440, "y": 387, "width": 400, "height": 275}, "focused": true, "visible": true}]}}
```

### tree

窗口上一帧的元素，按树序，父元素在子元素之前。窗口还没有排列过时，`tree` 先请求一帧并等它（最多 2 秒）。

```json
{"id": 2, "method": "tree", "params": {"window": 1}}
{"id": 2, "result": {"window": 1, "focus": "5878896818624359798", "nodes": [
  {"id": "15956256791619451359", "role": "text", "label": "Count: 0", "bounds": {"x": 20, "y": 20, "width": 360, "height": 18}},
  {"id": "5424175759328386547", "role": "button", "key": "17487022006909920864", "label": "Add", "bounds": {"x": 20, "y": 48, "width": 360, "height": 32}, "states": ["focusable"], "actions": ["press", "focus"]}
]}}
```

节点有 `id`、不在顶层时的 `parent`、`role`，以及它具有的 `key`、`label`、`value`、`description`、`bounds`、`states`、`actions`、`min`、`max`、`now`、`step`（滑块、步进器、评分、进度条、度量条）、`level`（树行，从 1 开始）和 `selection`（嵌入的文本字段，`[from, to]`，单位与 `selectText` 相同，是 UTF-16 码元；光标处两者相等）。嵌入的文本字段也在 `value` 中报告文字；密码字段两者都不报告。滚动容器里的元素在 `actions` 中列出 `scrollIntoView`，文本字段列出 `selectText`。ID 是数字字符串：它们是 64 位，JavaScript 的数字会丢失精度。

`key` 是元素的 `Style.key`，同样写成数字字符串。和可能随视图变化的 ID 不同，key 是应用自己给元素起的、长期不变的名字；测试要找的元素应该有自己的 key。视图用 `view.key("add")` 把文字变成 key，请求里也可以直接写 `"add"`：不是纯数字的字符串按 `view.key` 计算，数字或数字字符串按原值匹配，所以 `tree` 列出的值也能用。

```zig
if (try v.button("Add", .{ .key = view.key("add") })) self.count += 1;
_ = try v.slider(&self.level, .{ .minimum = 0, .maximum = 10, .step = 1 }, .{ .key = view.key("level"), .name = "Level" });
```

只有辅助技术会读到的元素在树里：只负责排列的行和列、间隔没有节点，带不带 key 都一样；有 `name` 的容器作为 `group` 出现。关闭的弹出层、浮层和对话框里的元素不在树里。角色有 `group`、`text`、`button`、`link`、`checkBox`、`radio`、`radioGroup`、`switch`、`slider`、`stepper`、`progress`、`meter`、`tab`、`tabList`、`list`、`listItem`、`tree`、`treeItem`、`table`、`row`、`columnHeader`、`dialog`、`alertDialog`、`popup`、`toolbar`、`image`、`comboBox`、`popUpButton`、`textField`、`scroll`、`status`、`splitter` 和 `disclosure`。状态有 `focusable`、`disabled`、`checked`、`mixed`、`selected`、`expandable`、`expanded`、`invalid`、`search`、`segment`、`sortAscending`、`sortDescending`、`vertical` 和 `offscreen`（被滚动容器或裁剪完全挡住）。`announcements` 是视图最近一次播报的文字。

显示网页的窗口没有树：`tree` 回答 `unsupported`，客户端用 `eval` 读页面。

### act

像辅助技术那样对元素执行操作：用 `id` 找元素，或在恰好一个元素有这个 key 时用 `key`。

```json
{"id": 3, "method": "act", "params": {"window": 1, "key": "add", "action": "press"}}
{"id": 4, "method": "act", "params": {"window": 1, "key": "level", "action": "setValue", "text": "7"}}
```

| action | 作用 |
| --- | --- |
| `press` | 点击按钮、勾选复选框、选中标签页或行，聚焦它落在的控件。 |
| `focus` | 把键盘焦点交给元素。 |
| `increment`、`decrement` | 让滑块、步进器、评分或分栏走一步。 |
| `setValue` | 滑块、步进器、评分取 `text` 表示的数值；文本字段全选后用 `text` 替换（空文本时删除）。 |
| `insertText` | 在文本字段的光标处输入 `text`。 |
| `expand`、`collapse` | 展开或收起树行、折叠区。 |
| `selectText` | 聚焦文本字段并选中 `from` 到 `to`（UTF-16 码元，与 JavaScript 字符串下标一致），光标落在 `to`；`from` 大于 `to` 时回答 `invalid_request`。 |
| `scrollIntoView` | 滚动元素外面的每个滚动容器，让它进入视野；对被滚出视野或禁用的元素也有效，下一帧显示新的位置。 |

操作经过与点击、按键、输入相同的事件到达视图的构建函数，之后窗口重绘。禁用的、被模态层挡住的或完全不可见的元素回答 `failed`（`scrollIntoView` 只对隐藏的元素这样回答）；元素不支持的操作回答 `unsupported`；滑块等收到的不是数值时回答 `invalid_request`。

### input

按顺序把事件发给窗口的内容，走系统事件的同一条路径：

```json
{"id": 5, "method": "input", "params": {"window": 1, "events": [
  {"type": "click", "x": 200, "y": 99},
  {"type": "text", "text": "Grace"},
  {"type": "key", "key": "CmdOrCtrl+A"}
]}}
```

| type | 字段 |
| --- | --- |
| `pointerMove` | `x`、`y`、`mods?` |
| `pointerDown`、`pointerUp` | `x`、`y`、`button?`、`clicks?`、`mods?` |
| `click` | `x`、`y`、`button?`、`clicks?`、`mods?`：先移动，再为每次点击按下并松开 |
| `wheel` | `x`、`y`、`dx`、`dy`、`precise?`、`mods?`：滚动 `dx`、`dy` DIP |
| `keyDown`、`keyUp`、`key` | `key`：按菜单快捷键的写法给出键和修饰键，如 `Enter`、`Shift+Tab`、`CmdOrCtrl+Z`；`key` 按下并松开 |
| `text` | `text`：输入的文字，或输入法提交的文字 |

`button` 是 `left`（默认）、`right` 或 `middle`；`clicks` 是双击、三击的次数（1 到 3）；`mods` 列出 `shift`、`ctrl`、`alt`、`super` 和 `cmdOrCtrl`（macOS 上是 Command，其他平台是 Control）。按键事件不输入文字：需要文字时另发 `text` 事件，和后端为能输入文字的键同时发出两者一样。

内容在下一帧之前依次处理一个请求里的事件，如同这些事件同时到达。后一个事件依赖前一个事件显示的结果时（例如在点击聚焦的字段里输入），中间用 `idle` 等待。输入只发给原生界面窗口；页面回答 `unsupported`，客户端用 `eval` 驱动页面。

### menu

按路径上的标签选择窗口菜单栏里的项，和菜单栏一样，在项的动作返回之后回答。标签忽略助记符（`&File`、`_File` 都匹配 `File`）：

```json
{"id": 6, "method": "menu", "params": {"path": ["File", "New Window"]}}
```

它从 `ziggurat_system.Owner` 给窗口安装的菜单栏中选择。没有菜单栏的窗口回答 `unsupported`；找不到的项、禁用的项和打开子菜单的项回答 `failed`。托盘图标的菜单和打开的上下文菜单不在范围内：系统在自己的循环里显示上下文菜单，所以不要通过 `input` 右击打开它。

### capture

窗口内容区的 PNG 图片，base64 编码，`width` × `height` 物理像素：原生界面按显示的样子，包括其中的页面。Linux 从 GDK 窗口读取像素；Windows 用 `PrintWindow`，它也向 DirectComposition 内容（交换链、WebView2）要像素。

### eval

在显示网页的窗口里求值 JavaScript，与 `web.View.evaluateJS` 相同：返回表达式的值（JSON），等待 Promise。脚本最多运行 30 秒。原生界面窗口和不带 WebView 的构建回答 `unsupported`。

```json
{"id": 7, "method": "eval", "params": {"window": 2, "script": "document.title"}}
{"id": 7, "result": {"value": "Todo"}}
```

### idle

窗口稳定后回答，让客户端等界面而不是睡眠：原生界面在内容不再请求未绘制的帧时稳定（`Window.framePending()`，并且视图已经排列过）；页面在加载完成并回答一段脚本后稳定。之后才到期的计时器不算在内。永远不稳定的内容（例如一直在动的指示器）永远不会回答：给出 `timeout`（毫秒），超时后以 `timeout` 失败。看不见的窗口在下一节说明。

```json
{"id": 8, "method": "idle", "params": {"window": 1, "timeout": 5000}}
```

### 看不见的窗口

完全看不见的窗口（隐藏或最小化的，以及在 macOS 上被其他窗口完全盖住或在锁屏之后的）把帧留到它再显示时才绘制：GTK 不绘制隐藏窗口，macOS 不绘制隐藏窗口，锁屏时也不绘制任何窗口。对这样的原生界面窗口，请求自己构建窗口正在等待的那一帧（`Host.settle`）：读 `tree` 之前、`act` 和 `input` 之后、`capture` 之前、`idle` 每次检查时。于是 `act` 与 `input` 立即生效，`tree` 和 `capture` 读到的是窗口现在显示的内容；`idle` 只等这种待构建的帧，不等窗口显示后才会画的帧，所以不会一直等下去。窗口显示后照常绘制那一帧。GTK 截不到隐藏窗口，`capture` 以 `failed` 回答；macOS 会把隐藏窗口的视图画进截图。

## 客户端

任何能打开 Unix 域套接字的语言都可以作为客户端。Zig 中：

```zig
const address = try std.Io.net.UnixAddress.init("/tmp/app.sock");
const stream = try address.connect(io);
defer stream.close(io);
var read_buffer: [1 << 20]u8 = undefined;
var write_buffer: [4096]u8 = undefined;
var reader = stream.reader(io, &read_buffer);
var writer = stream.writer(io, &write_buffer);
try writer.interface.writeAll("{\"id\":1,\"method\":\"act\",\"params\":{\"key\":\"add\",\"action\":\"press\"}}\n");
try writer.interface.flush();
const answer = try reader.interface.takeDelimiterInclusive('\n');
```

在 shell 中用 `socat`：

```sh
echo '{"id": 1, "method": "windows"}' | socat - UNIX-CONNECT:/tmp/app.sock
```

`tests/automation_smoke.zig`（`zig build smoke-automation`）是一个完整的例子：它显示一个视图窗口和菜单栏，从另一个线程通过套接字依次调用全部方法，最后用菜单退出应用。

## 命令行：ziggurat-automation

开发应用的 AI 编程 agent 想用短命令看界面、操作界面，读短的回答：不想自己写套接字客户端，也不想把整棵 JSON 树和 20 位的元素 ID 读进上下文。`ziggurat-automation` 就是这样的客户端，走同一个套接字：

```sh
ziggurat-automation open --socket /tmp/app.sock
ziggurat-automation snapshot -i
# @e2 [button] "Add" key=17487022006909920864
# @e3 [checkBox] "Greet" key=13206820971831191612
ziggurat-automation press key=add --settle
# - @e1 [text] "Count: 0"
# + @e1 [text] "Count: 1"
# = @e2 [button] "Add" key=17487022006909920864
ziggurat-automation fill key=level 7 --settle
ziggurat-automation screenshot /tmp/app.png
ziggurat-automation close
```

`snapshot` 每个元素一行：短 ref（`@e1`）、角色、标签、值、key 和状态，空的省略；`-i` 只留控件，`--full` 补上占位文字、描述、范围、选区、层级、动作、bounds 和元素 ID，`--json` 打印协议原样的回答。动作接 ref、`key=<key>` 或 `id=<digits>`，覆盖协议的方法：`press`、`fill` 及其他 `act` 操作、`click`、`pointer`、`wheel`、`type`、`key`、`menu`、`eval`、`wait`、`screenshot`（写到文件）和 `windows`。key 和 `tree` 一样写成数字；`key=add` 按 `view.key("add")` 计算，`key='"7"'` 按 `view.key("7")` 计算。带 `--settle` 时，动作用 `idle` 等窗口稳定（有超时，默认 10 秒），然后打印与上次快照相比的变化：`+`、`-` 表示出现、消失或变化的元素（变化的元素先 `-` 旧样子再 `+` 新样子），`=` 表示它们周围没变的元素，都带 ref。

会话（`--session`，或环境变量 `ZIGGURAT_AUTOMATION_SESSION`，默认 `default`）把套接字、目标窗口和 ref 存在用户缓存目录下自己的文件里（Linux `$XDG_CACHE_HOME/ziggurat/automation/<name>.json`，macOS `~/Library/Caches/…`，Windows `%LOCALAPPDATA%\…`），并排工作的 agent 不会改动彼此的 ref。元素显示期间它的 ref 一直有效，ref 永不分给别的元素：元素消失后，用它的 ref 会被拒绝为 stale，而不是落到别的元素上；元素再出现时得到新的 ref。`close` 结束会话，应用继续运行。

`ziggurat-automation skills` 打印它的指南，即编进命令里的 `SKILL.md`：这个版本的命令、会话、选择器、ref、稳定与差异、限制和错误，别的不写。`version` 打印构建它的 Ziggurat 版本。退出状态 0 成功，1 失败，2 命令行用错；错误写到标准错误，以 `error: ` 开头，应用的错误带协议的 code。

### 构建

命令在框架里，用应用依赖的那份 Ziggurat 构建，命令和它的指南才与应用一致：

```sh
zig build automation-cli          # zig-out/bin/ziggurat-automation
```

`zig build` 默认也安装它。应用的 `build.zig` 可以从依赖里装到应用旁边：

```zig
b.installArtifact(b.dependency("ziggurat", .{}).artifact("ziggurat-automation"));
```

它只用标准库和套接字，和模块一样在 Linux、Windows 与 macOS 上运行。升级应用的 Ziggurat 不会更新已经构建的命令：重新构建，指南随之更新。`zig build test-automation-cli` 运行它的单元测试，`zig build smoke-automation-cli` 显示一个视图窗口，用这些命令驱动它。

### 给 agent 的 skill

指南来自命令本身，agent 的配置只需说明它存在。把下面这段存成 skill，Claude Code 放在 `.claude/skills/ziggurat-automation/SKILL.md`，Codex 等读 `.agents/skills` 的 agent 放在 `.agents/skills/ziggurat-automation/SKILL.md`：

````markdown
---
name: ziggurat-automation
description: Use when reading a Ziggurat app's native UI elements and acting on them, sending pointer, wheel, key and text input, choosing menu bar items, evaluating scripts in pages, or taking screenshots of a running Ziggurat app.
---

This file is a discovery stub, not the usage guide. Before running a ziggurat-automation command, load the actual workflow from the CLI:

```bash
ziggurat-automation skills # start here
```

Do not probe first with --help or --version. Only if the command is missing, build it from the Ziggurat checkout the app depends on with `zig build automation-cli`.
````

## 安全

打开套接字的人可以像应用的用户那样驱动应用，并在应用的页面里运行脚本：不要把这个模块放进发布的构建。`ziggurat-automation` 和其他客户端一样只是套接字的客户端：它不监听，只连得上正在监听的应用。它需要两次主动开启：应用必须链接它，并且只在设置了 `ZIGGURAT_AUTOMATION` 时监听；不带 inspector 的构建无论链接与否都不包含它。

套接字只属于用户：Linux 上它在 `0177` 的 umask 下创建并设为 `0600`；Windows 上套接字的文件没有权限位，它继承所在目录的访问控制列表，用户的配置目录和临时目录只有用户自己能访问。把套接字放在只有用户能写入的目录里，不要放在与他人共享的目录。

## 平台

Windows 需要 Windows 10 1803 或更高版本（Unix 域套接字）。其他平台（包括目前的 macOS 后端）上模块可以编译，`capture` 与 `menu` 回答 `unsupported`。

## 实现

- 每个连接一个线程读取请求，经 `App.post` 切到主线程执行，主线程任务在应用退出时仍会运行，所以等待不会悬空；`App.post` 失败（应用已经停止）时连接关闭。
- `windows` 的窗框来自 `ziggurat_window_placement.frameMetrics`，与窗口位置记忆用的是同一份装饰尺寸。
- 核心为它提供 `Window.attachedContent()`、`framePending()`、`emitKey()`、`activateMenuItem()` 和 `capture()`；`ui.Context.ofWindow`、`view.Host.ofContext` 和 `webview.View.ofWindow` 从窗口找到视图或页面，不需要全局注册表。
- `view.Host.perform(id, action)` 执行无障碍操作；`Host.arranged` 表示视图排列过，`tree` 与 `idle` 用它等待排列后的 bounds。
- 窗口完全看不见时（`Window.outOfSight()`），`Host.waitsOutOfSight()` 表示有一帧在等着构建：内容请求过、而且之后没有在窗口外构建过的帧（`Window.frameAsked()`），或者事件 pass 之后视图还没排列。`Host.settle()` 立即构建并排列它，再用 `Window.builtOutOfSight()` 记下，这一帧在 `framePending()` 里不再算待绘制，直到内容再次请求；窗口显示后仍然绘制它。

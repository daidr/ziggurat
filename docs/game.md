# 游戏

`ziggurat_game`（`src/game`）是应用框架之外、游戏才需要的部分，按需引入：在视图叶子里运行游戏循环的 `View`、看二维世界的 `Camera`、像素画整数倍缩放的 `integerFit`，以及读游戏手柄的 `gamepad`。它只依赖公开的 `ziggurat`、`ziggurat_ui` 与 `ziggurat_view`，不分配内存，全部在主线程运行。示例 [examples/farm.zig](../examples/farm.zig) 用到了全部这些：`zig build run-farm`。

## 游戏循环

游戏是一个带 `update` 与 `draw` 的结构体，`Game.bind` 把它绑定成 `Game`：

```zig
const Farm = struct {
    x: f32 = 0,
    px: f32 = 0, // 上一步的位置
    pub fn update(self: *Farm, in: *const game.Input) void {
        self.px = self.x;
        if (in.down(.d)) self.x += 2;
        if (in.pressed(.space)) self.jump();
    }
    pub fn draw(self: *Farm, frame: *ui.Frame, bounds: view.Rect, alpha: f64) !void {
        // 介于最近两步之间，按这一帧进入下一步的比例。
        const x = self.px + (self.x - self.px) * @as(f32, @floatCast(alpha));
        frame.rect(.{ .x = bounds.x + x, .y = bounds.y, .width = 16, .height = 16 }, 0x2a6fd4);
    }
};

var loop = game.View.init(game.Game.bind(&farm)); // 地址在构建期间保持稳定
// 构建函数中：
try loop.build(v, .{ .grow = 1, .name = "Farm" });
```

步长固定：每秒 `game.rate`（60）步，或游戏结构体的 `pub const rate: u32` 指定的步数，与显示刷新率无关，60 Hz 与 120 Hz 的显示器上玩起来一样，物理也保持稳定。`draw` 每帧运行，`alpha`（0 到 1）是这一帧进入下一步的比例，用于在最近两个位置之间插值。窗口看不到等暂停之后，最多补 `max_catch_up`（0.25 秒）的步数。在同一时刻绘制两次不会重复走步。

`View.build` 每次构建都用 `View.wakeAt` 要下一帧（`frame_interval`，约 60 Hz），所以窗口需要像其他动画一样有 `ziggurat_view_timer.Timer`；不再构建这个叶子时就不再唤醒，空闲窗口不做事。步在叶子绘制时按这一遍的时间（`View.time()`）运行，`Harness` 推进时钟即可无窗口测试。

### 输入

`game.Input` 是某一步看到的玩家输入：

| 方法 | 含义 |
| --- | --- |
| `down(k)` | 按住键 `k` |
| `pressed(k)`、`released(k)` | 上一步以来按下或松开了 `k`，即使在两步之间按下又松开 |
| `pointer()` | 指针相对视图左上角的位置，以及是否在视图上 |
| `pointerDown(b)`、`pointerPressed(b)`、`pointerReleased(b)` | 指针按键 `b`（0 为主键） |
| `wheel()` | 上一步以来滚轮滚动的距离（DIP，向下、向右为正） |
| `size()` | 视图尺寸 |
| `focused()` | 视图持有键盘：没有键盘时游戏应暂停 |

键按位置识别（`z.KeyInput.physical`）：`.w` 在任何布局下都是 W 所在位置的键，适合 WASD；原生事件没有位置时退回逻辑键。叶子第一次出现时以及被按下时获得键盘焦点，带 Ctrl、Alt 或 Super 的按键留给菜单和快捷键；叶子或窗口失去键盘时放开所有按住的键，因为它们的松开事件不会再来。视图只把主键交给嵌入叶子，所以 `pointerDown(1)`、`pointerDown(2)` 目前总是 false。

为此核心增加了两项：`z.KeyInput.physical`（Windows 由扫描码、Linux 由 evdev 键码换算，见 `z.physical_keys`）和 `Content.key_release`（只交给要求它的内容）。`ui.Context.on_key_release` 转发松开；视图把它作为 `EmbedInput.key_up` 交给持有焦点的嵌入叶子，`View.focusLeaf(id)` 让构建请求聚焦一个叶子，`View.hasKeyboard(id)` 判断叶子持有焦点且窗口有键盘。`Harness.keyUp` 与 `Harness.windowFocus` 在无窗口测试中回放它们。

## 相机

`game.Camera` 让世界坐标 `x, y` 显示在视图中央，放大 `zoom` 倍（0 视为 1），转过 `rotation` 度。世界单位在缩放为 1 时是 DIP。`camera.draw(frame, bounds, context, drawWorld)` 把 `drawWorld(context, *Lens)` 用世界坐标画的内容裁剪到视图里：

```zig
const camera: game.Camera = .{ .x = player.x, .y = player.y, .zoom = 3 };
try camera.draw(frame, bounds, scene, Scene.paint);
// Scene.paint 中：
lens.rect(.{ .x = col * 16, .y = row * 16, .width = 16, .height = 16 }, 0x6fae4f); // 镜头外的被剔除
const world = camera.toWorld(bounds, pointer.x, pointer.y); // 指针在世界中的位置
```

`Lens` 把世界矩形映射到帧（`map`），并提供 `rect`、`roundedRect`、`strokeRect`、`image` 与 `label`，镜头看不到的直接跳过（`shows`）；其他绘制用 `lens.frame` 与 `lens.map`。不旋转时世界按整屏幕像素移动，在整数世界单位上画的图块边缘总落在像素上。`visible` 返回镜头看到的世界范围（旋转时为外接矩形），供自己遍历图块的游戏剔除；`transform` 返回世界到窗口的仿射变换。旋转的相机通过帧变换绘制，需要先用 `ui.Context.prepareTransforms` 准备能容纳可见世界的源尺寸，否则返回 `TransformsNotPrepared`。

## 像素完美缩放

`game.integerFit(scale, width, height, bounds)` 返回 `width`×`height` 像素的画布在 `bounds` 中能显示的最大整数倍位置（每个画布像素对应整数个屏幕像素，至少 1 个，居中留黑边）与倍数。`scale` 是帧的 `frame.size.scale`；目标矩形落在整屏幕像素上。用 `.sampling = .nearest` 画这块画布即可像素完美；视图坐标 x 处的指针在画布的 `(x + bounds.x - dst.x) * width / dst.width`。渲染到可复用纹理的画布抽象尚未提供，游戏可以先把世界画进准备好的动态图片。

## 游戏手柄

`gamepad` 用同一个标准布局读所有手柄：按位置命名的按键、两个摇杆、模拟扳机和十字键。

```zig
var pads: gamepad.Gamepads = .{};
defer pads.deinit();
var last: gamepad.State = .{};

var buffer: [gamepad.max_pads]gamepad.Pad = undefined;
const found = pads.pads(now, &buffer);
if (found.len > 0) {
    const s = found[0].state();
    const stick = s.leftStick(); // -1 到 1，向右、向下为正，带死区
    if (s.justPressed(last, .south)) player.jump();
    last = s;
}
```

`Gamepads` 由应用持有，固定最多 `max_pads`（8）个手柄，不分配内存。`pads(now, &buffer)` 按连接顺序返回已连接的手柄，最多每 `scan_interval`（1 秒，`now` 为单调纳秒）重新查找一次；游戏每帧调用一次即可。`Pad` 是值句柄：从连接到断开有效，断开后 `connected()` 为 false、读到的状态全部松开；重新插上是一个新的 Pad。`name()` 是厂商给的名字。`state()` 读取当前状态，保留上一次的值即可区分刚按下（`justPressed`）与按住。

| 按键 | Xbox | PlayStation | Nintendo |
| --- | --- | --- | --- |
| `south` | A | Cross | B |
| `east` | B | Circle | A |
| `west` | X | Square | Y |
| `north` | Y | Triangle | X |
| `left_shoulder`、`right_shoulder` | LB、RB | L1、R1 | L、R |
| `left_trigger`、`right_trigger` | LT、RT | L2、R2 | ZL、ZR |
| `back`、`start` | View、Menu | Create、Options | −、+ |
| `left_stick_button`、`right_stick_button` | LS、RS | L3、R3 | |
| `up`、`down`、`left`、`right` | 十字键 | 十字键 | 十字键 |
| `guide` | Xbox | PS | Home |

按键值为 0 到 1（`value`），扳机按扣下的程度；`pressed` 以四分之一为界。轴（`axis`）为 -1 到 1，向右、向下为正，是手柄报告的原值；`leftStick`、`rightStick` 带径向死区（`deadzone`，0.15），静止的摇杆读数为 0，各方向倾斜程度一致。

| 平台 | 来源 | 手柄 |
| --- | --- | --- |
| Windows | XInput（按需加载 `xinput1_4.dll`、`xinput1_3.dll` 或 `xinput9_1_0.dll`） | Xbox 手柄以及表现为 Xbox 手柄的设备（Steam Input 可以转换其他手柄）；序号 100 的导出能读 Guide 键 |
| Linux | evdev，`/dev/input/event*` | 内核驱动报告为手柄、当前座席用户可读的设备；Xbox 手柄（xpad、Steam 虚拟手柄）按 BTN_X/BTN_Y 报告的 X、Y 按实际位置读取 |

其他平台没有手柄。Windows 没有 Steam Input 或转换驱动时看不到 PlayStation 与 Nintendo 手柄。XInput 查询空槽位较慢，所以只在扫描时查询未知槽位；已知手柄在读取时发现断开。真实手柄的热插拔与各品牌映射没有在自动检查中验证，单元测试用假后端覆盖连接顺序、扫描间隔、断开与重连，并检查 XInput 与 evdev 的映射。

## 测试

`update` 是普通的 Zig 函数，可以不开窗口测试世界本身。视图在 `view.Harness` 里像其他叶子一样运行：`attachInput` 之后 `key` 与 `keyUp` 在帧之间按住或松开键，`advance` 推进的时间够一步才会走一步。`zig build test-game` 运行模块测试，`zig build test-examples` 包含 farm 的回放测试。

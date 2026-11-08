# 快速开始

这一页从零开始创建、开发并构建一个 Ziggurat 应用。

## 1. 准备工具

- **Zig 0.17.0**。框架固定这一版本，其他版本不保证能编译。
- 平台依赖：Windows 使用系统库；Linux 需要 GTK3、Pango/Cairo 开发包与 pkg-config；macOS 需要 Xcode 命令行工具与 SDK。详见 [系统要求](./requirements.md)。

取得框架源码，并构建命令行工具：

```sh
git clone https://github.com/daidr/ziggurat.git
cd ziggurat
zig build cli
```

`zig build cli` 在 `zig-out/bin/` 生成 `ziggurat` 和安装存根 `ziggurat-setup`。可以把这个目录加入 `PATH`。命令只调用本机的 `zig`（用环境变量 `ZIG` 指定其他路径），不下载任何依赖。

检查本机环境：

```sh
ziggurat doctor            # 原生 UI 所需
ziggurat doctor --webview  # 另外检查系统 WebView
```

`doctor` 报告 Zig 版本、git、各平台的原生依赖与签名身份，缺少必需项时以退出码 1 结束。

## 2. 创建项目

```sh
ziggurat init hello --template native --name "Hello" --id com.example.hello
cd hello
```

`init` 在空目录中生成：

```text
hello/
├── build.zig          # 导入框架模块并嵌入应用资源
├── build.zig.zon      # 以相对路径依赖框架检出
├── ziggurat.json      # 名称、identity、版本、图标、签名等项目配置
├── src/main.zig       # 应用入口
├── .gitignore
└── .agents/skills/    # 给代码代理的维护技能
```

三种模板：

| 模板 | 内容 |
| --- | --- |
| `native` | 声明式视图计数器，用 `ziggurat` 与 `ziggurat_view` |
| `web` | WebView 页面与嵌入的 `src/index.html`，页面和 Zig 通过消息往返 |
| `hybrid` | 同一份状态驱动一个原生视图窗口和一个页面窗口，任一侧的操作同步到另一侧 |

`--framework PATH` 指定框架检出的位置，默认是构建这个 CLI 的那份源码。

## 3. 开发

```sh
ziggurat dev
```

`dev` 先运行 `zig build`，成功后启动应用。它监视 `src/`、`build.zig`、`build.zig.zon` 与 `--watch` 指定的目录，文件变化时结束应用、重新构建并再次启动；构建失败则等待下一次变化。使用前端构建工具时，用 `--frontend "npm run dev"` 让它一并启动和结束。

也可以直接使用 Zig 构建系统：

```sh
zig build run   # 构建并运行
zig build test  # 运行 src/main.zig 中的测试
```

## 4. 看懂生成的代码

`native` 模板的 `src/main.zig`：

```zig
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");

const State = struct {
    count: i64 = 0,

    fn build(self: *State, v: *view.View) anyerror!void {
        try v.text("Hello", .{});
        try v.textf("Count: {d}", .{self.count}, .{});
        try v.row(.{ .gap = 8, .alignment = .center });
        if (try v.button("-", .{ .width = 44 })) self.count -= 1;
        if (try v.button("+", .{ .width = 44 })) self.count += 1;
        if (try v.button("Reset", .{ .enabled = self.count != 0 })) self.count = 0;
        try v.end();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var state: State = .{};
    var storage: view.Storage(64, 2048) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Hello" });
    try host.attach(window);
    window.show();
    try app.run();
}
```

- `State.build` 是**构建函数**：每次绘制和每次输入时运行，从当前状态描述整棵视图。按钮在被激活的那一遍返回 `true`，副作用写在 `if` 分支里。
- `view.Storage(64, 2048)` 是视图的固定存储（节点数与文本字节），不在绘制路径上分配。
- `state`、`storage` 和 `host` 必须在窗口显示它们期间保持地址不变，所以放在 `main` 的栈上。
- `createWindow` 创建隐藏窗口；挂上内容后再 `show`。`app.run()` 在最后一个窗口关闭后返回。

视图的写法见 [原生 UI 概览](../ui/)；应用、窗口与线程规则见 [应用与生命周期](./app.md)。

## 5. 测试

`view.Harness` 不创建窗口，运行与真实窗口相同的构建、布局和事件：

```zig
test "加号让计数加一" {
    var state: State = .{};
    var storage: view.Storage(64, 2048) = .{};
    var h = view.Harness.init(&state, State.build, storage.buffers(), .{});
    try h.render();
    try h.click(.{ .text = "+" });
    try std.testing.expectEqual(@as(i64, 1), state.count);
    _ = try h.find(.{ .text = "Count: 1" });
}
```

运行 `zig build test` 即可，CI 中不需要显示器。更多查询与输入方法见 [无窗口测试](../view.md#无窗口测试)；驱动一个正在运行的应用见 [自动化](../automation.md)。

## 6. 构建与分发

```sh
ziggurat build                     # ReleaseSafe 构建本机平台
ziggurat build --package           # 另外打成更新包 dist/<identity>-<os>-<arch>-<version>.zip
ziggurat build --platform linux/x86_64,windows/x86_64,macos/universal --package
```

更新包可以交给 `ziggurat package` 生成安装程序、deb 与 PKGBUILD，或者交给 `ziggurat publish` 发布到 GitHub Releases 或 S3。macOS 目标还会写出签名的 `.app` 与磁盘映像。见 [构建与分发](./distribution.md)。

## 下一步

- 跑一遍仓库里的示例：在框架目录运行 `zig build run-gallery`、`zig build run-notes` 等，列表见 [示例应用](../examples.md)。
- 想用网页做界面：读 [网页前端](./frontend.md)。
- 需要菜单、托盘、通知：读 [菜单、托盘与桌面 API](./desktop.md)。

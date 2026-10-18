# 本地 Web 资源

`ziggurat_assets` 是独立资源模块，不导入窗口或 WebView。发布态把构建好的前端转成可编译的嵌入模块；开发态显式读取不可变快照，通过主线程队列替换文档。两个路径都使用 `ziggurat_webview` 的本地 HTTPS 资源接口，不需要本地 HTTP 服务器。

## 发布态嵌入

先运行应用自己的前端构建，再生成资源：

```powershell
zig build web-assets -Dweb-assets=frontend/dist -Dweb-entry=/index.html
```

默认输入为 `tests/assets_fixture`，默认入口为 `/index.html`。生成目录为 `zig-out/share/ziggurat/web-assets`，包含 `assets.zig` 与以 SHA-256 命名的 `.blob` 文件。整个目录是编译输入；应用编译后不需要这些磁盘文件。生成器复制实际文件内容，不生成指向原输入目录的绝对路径。

生成模块导出：

| 成员 | 内容 |
| --- | --- |
| `html` | 入口文档的嵌入字节 |
| `entry_path` | 入口的 URL 路径 |
| `digest` | 整个有序资源快照的 SHA-256 十六进制字符串 |
| `total_bytes` | 所有文件的字节总数 |
| `resourceTable(comptime Resource: type)` | 除入口文档以外的资源数组；元素具有 `path`、`mime`、`bytes` 字段 |

将生成文件注册为应用的构建模块后，可以直接附加：

```zig
const web = @import("ziggurat_webview");
const frontend = @import("web_assets");
const resources = frontend.resourceTable(web.Resource);

try view.attach(window, .{
    .html = frontend.html,
    .user_data_folder = absolute_application_profile,
    .local = .{
        .start_path = frontend.entry_path,
        .resources = &resources,
    },
});
```

`user_data_folder` 必须是应用专用的绝对路径。本地来源默认为 `https://app.ziggurat.invalid`。文档与资源由内存提供；导航、frame、弹窗、下载和权限的默认拒绝政策仍然适用。应用负责文档的 CSP 与脚本逻辑。

在应用自己的 `build.zig` 中，生成器使用主机目标。`tools/web_assets.zig` 需要导入名为 `ziggurat_assets` 的模块，参数为 `INPUT_DIRECTORY OUTPUT_DIRECTORY [ENTRY_PATH]`。生成步骤与应用编译的依赖可写为：

```zig
const generate_assets = b.addRunArtifact(asset_generator);
generate_assets.addDirectoryArg(b.path("frontend/dist"));
const output = generate_assets.addOutputDirectoryArg("web-assets");
generate_assets.addArg("/index.html");
const embedded = b.createModule(.{
    .root_source_file = output.path(b, "assets.zig"),
    .target = target,
    .optimize = optimize,
});
app.root_module.addImport("web_assets", embedded);
```

生成器先写内容寻址的文件，最后原子替换 `assets.zig`。同一快照的源码和文件名确定一致。输出应使用专用构建目录；工具拒绝输出位于输入目录内部。工具不会删除输出中的其他文件或旧 blob，构建缓存的清理由构建系统负责。

## 开发态快照

`Snapshot.load(allocator, directory, limits)` 同步读取整个目录，拥有读取到的路径和字节。目录必须允许迭代，只借用到调用结束。快照不可变，`find("/app.js")` 按精确 URL 路径查找；`sameContent` 比较内容摘要，不依赖保存时间戳。

```zig
const assets = @import("ziggurat_assets");
var snapshot = try assets.Snapshot.load(allocator, directory, .{});
const document = snapshot.find("/index.html") orelse return error.EntryNotFound;
const table = try snapshot.resourceTable(web.Resource, allocator, "/index.html");
// table 显式分配；它的 bytes 借用 snapshot。
```

在工作线程读取快照，或者在进入事件循环前完成初次读取。不要在绘制回调或 `ResourceHandler` 中打开磁盘文件。`resourceTable` 的分配器也由调用者提供；`View.attach` 和 `View.reload` 会复制表的路径、MIME 等元数据，资源正文继续借用快照。

所有加载错误都由调用者处理。编辑过程中删除、重命名或改写文件，可能使加载失败；成功快照也不承诺整个目录来自一次原子提交。保持上一份有效快照，并根据后续通知重新读取。需要多个文件的一致发布时，由前端构建工具提供完成信号或原子目录切换。

默认预算如下，调用者可显式提供 `Limits` 调整：

| 项目 | 默认上限 |
| --- | --- |
| 文件数 | 4096 |
| 遍历项数，含目录 | 8192 |
| 子目录深度 | 32 |
| URL 路径字节数 | 4096 |
| 单文件字节数 | 16 MiB |
| 总文件字节数 | 64 MiB |

读取预算不改变 View 的独立资源数量、路径长度与 `Options.max_resource_bytes` 限制；超出时附加或更新仍会返回明确错误。

路径分量只接受 ASCII 字母、数字、`-`、`_`、`.`，不接受 `.`、`..` 或结尾的点。链接、目录联接与其他非普通文件拒绝加载。子目录与文件通过已持有的父目录打开，不跟随末级链接。常见 Web 类型使用固定 MIME 映射，其余为 `application/octet-stream`。入口文档还必须是有效 UTF-8，且不能含 NUL。

## 文件通知与文档替换

Windows 的 `DirectoryWatch` 只持有一个原生目录通知句柄，不创建线程、计时器或用户态异步 I/O 缓冲。它通知本地目录树内的文件名、目录名、大小或写入时间变化，不能保证报告根目录自身的删除或替换。其他系统的这一接口显式返回 `UnsupportedPlatform`。

主线程把句柄交给 `App.watchNative`。该注册是一次性的：

```zig
var native_error: u32 = 0;
var watch = try assets.DirectoryWatch.init(allocator, absolute_directory, &native_error);
const token = try app.watchNative(try watch.nativeHandle(), .{
    .context = state,
    .call = on_directory_changed,
});
```

推荐的更新顺序：

1. 在目录回调中调用一次 `watch.rearm()`，然后重新注册 `App.watchNative`。回调保持短小。
2. 启动调用者管理的快照工作线程。已有读取进行时合并通知，记录还需再读取一次；不要为每个通知无限启动工作线程。
3. 工作线程读取候选快照，通过 `App.post` 交给主线程。返回 `Full` 或 `Closed` 时，执行责任仍在调用者；释放结果或按应用自己的策略重试。
4. 主线程比较摘要。相同时释放候选；变化时构造候选资源表并调用 `view.reload(options)`。
5. 收到 `resources_released` 后释放上一份快照。新文档加载后用页面消息握手，确认需要的 DOM 和脚本已经运行。

`DirectoryWatch.init` 的第三个参数是可选的 `*u32`，可保存初始化失败时的原生错误码；`rearm` 的原生失败码位于 `watch.last_error`。注销 App 的等待注册后再 `watch.deinit()`。关闭应用时停止生产者，并在 `App.deinit` 之前 join；模块本身不替调用者创建或管理工作线程。

`View.reload(options)` 先校验并复制完整新配置，再提交一个有界主线程任务。配置无效、分配失败、队列 `Full` 或 App `Closed` 时，当前配置和文档保留。成功提交后，`View.post` 在新控制器 ready 前返回 `NotReady`；同时发起的 reload/recover 返回 `RecoveryInProgress`。

执行更新时，旧回调先退栈，旧控制器关闭并清除其 Zig 入口，再释放旧配置并发出一次 `resources_released`，随后创建新控制器。该事件表示旧资源正文可以释放，不表示新页面已加载。响应流已经复制正文，独立于这些快照。新控制器创建失败会发出 `failed`；新配置仍保留，应用可以显式 `recover`，或提交另一份 `reload`。

如果窗口在更新任务执行前关闭，detach 会同时清理当前与待提交配置；此时不会发送 `resources_released`。应用在 `WindowOptions.on_closed` 中释放这两份资源正文，并保持 View 与回调上下文到约定的关闭完成点。`isClosed` 不能代替这一通知。若已接受的任务仍引用应用上下文，还要保持该存储到这些任务执行完成。

## 验证边界

`zig build test` 包含资源快照和生成器测试，以及实际编译运行生成资源模块的检查。覆盖内容变化、删除、预算、链接拒绝、构造分配失败、确定性输出、二进制复制和生成器 OOM 保留旧源码。测试不要求前端 fixture 的固定内容，因此可以使用自定义 `-Dweb-assets`。

`zig build smoke-assets -Dwebview=true` 使用隐藏窗口、实际磁盘修改和原生目录通知，运行工作线程读取、`App.post`、`View.reload` 和页面消息的完整闭环。它检查 DOM 版本更新、旧快照释放、无效配置/OOM/满队列回滚，以及排队更新关闭后复用 View 时没有旧回调进入新对象。结束时检查适配层 COM 资源归零。该检查需要固定 SDK 与已安装的 WebView2 Runtime；它不建立视觉质量结论。

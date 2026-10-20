# watch 插件

watch 插件让页面跟踪应用允许的目录和文件的变化，例如编辑器打开的项目。Zig 半部是 `ziggurat_plugin_watch` 模块（`src/page_runtime/plugins/watch.zig`），页面半部是 `@ziggurat/plugin-watch` 包（`packages/plugin-watch`），清单是包内的 `ziggurat-plugin.json`，不需要原生库。约定见[插件](plugins.md)；底层的系统监视见[文件监视](file-watch.md)。

## 宿主

```zig
const watch_plugin = @import("ziggurat_plugin_watch");

var plugin: watch_plugin.Plugin = undefined;
try plugin.init(allocator, .{
    .post = .app(app),
    .roots = &.{
        .{ .name = "project", .path = project_dir, .recursive = true, .ignore = ignore },
        .{ .name = "settings", .path = settings_file },
    },
});
defer plugin.deinit(); // App.run 返回、Host.detach 之后，App.deinit 之前
try host.use(plugin.plugin());
```

- 页面只用名称指定 root，不能指定路径。名称为 1–64 字节小写 ASCII 字母、数字和 `-`，以字母开头。`init` 在主线程调用，路径必须是绝对路径且此时是目录或文件，否则返回 `InvalidRoot`；它解析路径中的 symlink 并复制 root。目录 root 记下当时的身份，之后被替换成另一个目录时请求以 `io` 失败。`allocator` 必须线程安全。
- `recursive` 允许页面监视其中的子目录及其内容；否则只能监视 root 本身和其中的文件。
- `ignore` 在 worker 上以相对 root、以 `/` 分隔的路径询问每个文件和目录；被忽略的目录不会被列出、报告或计入 `max_entries`。Linux 上系统监视仍会为被忽略的子目录建立 inotify watch（计入 `max_directories`）。
- `resolve` 在主线程为不在 `roots` 中的名称给出 root（例如用户在对话框中选择的目录），返回 null 表示不认识；返回的字符串会被复制。
- `allow` 在主线程看到 root 名、路径和是否递归，可以拒绝请求。
- 每个页面同时最多 8 个监视；多个页面的插件可共享一个 `Quota`（默认上限 128）。
- 每个监视有一个由插件启动的 worker，监视结束后在主线程的 drain 中 join；`deinit` 停止并 join 全部 worker。插件不使用全局线程池。
- 一个监视最多保留 `max_entries`（默认 8192）个文件和目录的快照，递归监视最多让系统监视 `max_directories`（默认 8192）个目录；超过时以 `limit` 结束。

## 页面

```ts
import { watch } from "@ziggurat/plugin-watch";

const watcher = await watch("project", { recursive: true });
for await (const events of watcher) {
  for (const event of events) console.log(event.op, event.path, event.oldPath);
}
```

`watch` 在一切都已被监视后 resolve。`path` 选择 root 中的目录或文件（相对 root、以 `/` 分隔，如 `"src"`、`"package.json"`），不能离开 root，也不能穿过 symlink。

事件有 `op`（`create`、`write`、`remove`、`rename`）、`path`（相对被监视对象、以 `/` 分隔，`.` 是被监视对象本身）、`oldPath`（rename 的来源）和 `isDir`。开始时已有的内容不报告。

- 监视比较它看到的与之前看到的：事件说明不同之处，而不是每一步。连续写多次是一个 `write`，期间创建又删除的文件不报告。应把事件当作重新读取文件的提示。
- `write` 表示文件大小或修改时间变化；权限等元数据和目录本身的写入不报告。
- 身份（设备与 inode，Windows 为文件索引）移到另一路径且前后都唯一时是 `rename`；随目录一起移动的内容由目录的 `rename` 表达。硬链接使身份不唯一时报告为 `remove` 加 `create`；同名被替换也是 `remove` 加 `create`。
- 监视文件时通过其目录监视：编辑器以替换方式保存是 `.` 的 `write`，删除是 `remove`，再出现是 `create`。
- 被监视的目录（或被监视文件所在的目录）被删除、移走或替换时，最后一批只有 `.` 的 `remove`，迭代结束。

变化静默 50 ms 后报告，持续变化时最多等待 500 ms（`debounceMs` 大于 500 时以它为准）；`debounceMs` 为 0 表示 50 ms，负数表示不等待，最大 60000。宿主在页面取走一批之前不会再次查看，页面忙时不会丢失变化；一批超出一条消息时分成几部分发送，页面合并后再交给迭代。

`watcher.close()`、跳出 `for await` 或 `signal` 中止都会停止监视，页面离开或换代也会。`watcher.closed` 在监视停止后 settle：正常结束 resolve；出错时以错误 reject，`signal` 中止时以 `signal.reason` reject。错误是 `WatchError`，`code` 为：

- `denied`：不是 root 名称、`allow` 拒绝、路径不在 root 中或穿过 symlink，或对非递归 root 请求递归监视或监视其中的目录；
- `not-found`：路径不存在；
- `limit`：页面或应用的监视过多，条目或目录超过上限，或 `debounceMs` 超过 60000；
- `unsupported`：平台不能监视文件；
- `path-encoding`：文件名不是合法 UTF-8；
- `io`：其他错误，例如 root 在应用启动后被替换。

## 平台

监视跟踪目录中的内容，不跟随其中的 symlink 和 Windows junction。只应暴露应用控制的目录：名称让页面无法选择路径，但其他程序仍可移动或替换目录中的内容。

- Linux：每个监视一个 inotify 实例，每个目录一个 watch，受系统 `fs.inotify.max_user_watches` 限制。被监视的目录被删除时，监视通过检查路径的身份发现，不依赖内核在句柄关闭后才发出的事件。
- Windows：每个监视一个 `ReadDirectoryChangesW` 句柄。被监视目录自身的重命名不能可靠检测。

## 验证

`zig build test-plugin-watch` 在临时目录中运行真实的系统监视：递归监视的创建、写入、目录 rename 配对（不报告随之移动的内容）、新目录及其中文件、删除，以及目录被删除时以 `.` 的 `remove` 结束；文件监视的写入、替换保存、删除与再出现；被拒绝和不存在的请求、运行期授予的 root、共享配额与页面换代、root 校验；以及快照比较的 rename 配对、替换与硬链接。`bun test packages` 覆盖页面包。`smoke-plugin-watch -Dwebview=true` 在真实 WebView 中经页面包监视临时目录：被拒绝的 root、ready、创建、rename 配对、写入和关闭。Linux（WebKitGTK，隐藏窗口）上已运行通过；Windows 的单元测试由 CI 运行，WebView smoke 列在 CI 手动触发的 WebView2 任务中。这些检查不建立性能结论，大规模目录树的耗时未测量。

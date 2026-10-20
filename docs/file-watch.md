# 文件监视（粗模式）

`system.watch` 提供 S03 的粗模式文件监视：只报告应当重新检查的目录，不读取文件 metadata、不跟踪文件身份、不伪造 rename 配对。需要按稳定身份匹配 rename 的详细模式尚未实现，`watch.capabilities.detailed` 为 false。`watch.capabilities.coarse` 与 `system.capabilities.file_watch` 在 Windows/Linux 为 true，其他目标 `init` 返回 `UnsupportedCapability`。

## 线程与所有权

`Watcher.init(allocator, main_thread_id, options)` 只能在应用自己创建的后台线程调用，拒绝 UI 线程（`UiThreadForbidden`）。除 `interrupt()` 外，所有方法和 `deinit()` 都在创建线程调用，其他线程返回 `WrongThread`。Watcher 不持有 App/Window，不创建线程、不轮询、不投递任务；结果由宿主自行通过 `App.post` 交付并处理 `Full/Closed`。初始化后不可复制，其他线程可能调用 `interrupt()` 期间地址保持稳定。

全部缓冲在 `init` 一次分配：root 表、目录槽与两份目录路径池（用于压缩）、pending 条目与路径字节、2×(`max_path_bytes`+1) 路径暂存、原生读取缓冲（Linux 一份，Windows 每 root 一份），Linux 另有 watch descriptor 表（2×`max_directories` 向上取 2 的幂，线性探测、删除后移位，无墓碑）和遍历栈。之后的 `addRoot`、`wait`、`removeRoot` 不再分配。`deinit` 取消并等待原生读取、关闭所有句柄/FD 并释放内存；重复调用无副作用，之后的调用返回 `Closed`。

`interrupt()` 线程安全，可在任意线程调用；它唤醒正在阻塞或下一次的 `wait`，未被观察到的多次唤醒合并为一次。`deinit` 开始后不得再调用；常规关闭顺序为 UI 线程 `interrupt()`，worker 退出循环并 `deinit()`，UI 线程 join。

## 选项与预算

| 选项 | 默认 | 含义 |
| --- | --- | --- |
| `recursive` | true | Linux 在预算内遍历子目录逐个加 watch；Windows 使用原生 subtree 标志 |
| `debounce_ms` | 50 | 最后一个原生事件后的静默时间，到期后批次就绪 |
| `max_latency_ms` | 500 | 从首个未交付事件起的最大等待；持续写入不会无限推迟批次 |
| `max_roots` | 8 | Windows 最多 63（等待句柄上限 64 减中断事件） |
| `max_directories` | 4096 | Linux：inotify watch 总数（每个被监视目录一个）；Windows：每 root 一个 |
| `max_pending` | 512 | 未交付的不同 (root, 目录) 数；合并为线性比较 |
| `pending_path_bytes` | 128 KiB | 未交付目录路径字节 |
| `directory_path_bytes` | 512 KiB | 被监视目录完整路径字节，内存占用两倍 |
| `native_buffer_bytes` | 64 KiB | 4 KiB–1 MiB 且 8 字节对齐；Windows 网络共享拒绝大于 64 KiB 的缓冲 |

`debounce_ms` 不得大于 `max_latency_ms`，非法组合返回 `InvalidOptions`。

## Root

`try watcher.addRoot(absolute_path)` 返回 `Root{ index, generation }`。路径借用到返回，去掉末尾分隔符后原样作为报告路径前缀，不做规范化或 realpath。**`addRoot` 返回即 ready**：原生 watch 已建立，此后的变更都会报告；返回前发生的变更不保证报告，宿主应在 `addRoot` 之后做初始扫描。Linux 初始遍历超出目录或路径预算返回 `DirectoryBudgetExceeded`，系统 watch 上限返回 `WatchLimitReached`，子目录不可读等错误同样使 `addRoot` 失败并释放已加的 watch；与已有 root 共享目录 inode（重叠 root）返回 `OverlappingRoot`。Windows 各 root 独立，不检测重叠。

`removeRoot(root)` 释放该 root 的原生资源并丢弃其未交付事件；过期 id 返回 `UnknownRoot`。`isIncomplete(root)` 报告该 root 是否有子目录未被监视。

## 等待与批次

```zig
var events: [64]watch.Event = undefined;
var paths: [64 * 1024]u8 = undefined;
const batch = try watcher.wait(&events, &paths, 1000);
for (batch.events) |event| switch (event) {
    .changed => |change| rescanDirectory(change.root, change.path),
    .overflow => |lost| rescanRoot(lost.root),
    .root_removed => |gone| forgetRoot(gone.root),
};
```

`wait(events, path_storage, timeout_ms)` 在 worker 上阻塞，直到批次就绪（`wake = .batch`）、`timeout_ms` 到期（`.timeout`，null 表示无限等待）或被中断（`.interrupted`）。超时或中断时只返回已经就绪的事件，未到 debounce 的事件保留。超时为 0 时仍非阻塞读取一次原生事件。`changed.path` 借用调用者 `path_storage`，直到下一次 `wait`。

同一批次内相同 (root, 目录) 合并为一个 `changed`。调用者 `events` 或 `path_storage` 容量不足时，放不下的事件按顺序保留到下一次 `wait`，`batch.more` 为 true，已就绪的剩余事件下一次立即返回；没有事件能放下时（`events` 为空或首个路径大于 `path_storage`）返回 `ResultCapacityExceeded` 且不消费任何事件。

事件语义：

- `changed{ root, path }`：`path` 目录的直接条目发生变化，宿主应重新列出该目录；列表中新出现的子目录由宿主视为新目录扫描。Linux 也会对新建或移入的子目录本身报告 `changed`，覆盖其 watch 建立前写入的内容。
- `overflow{ root, reason }`：宿主必须重新扫描整个 root，该 root 尚未交付的 `changed` 已丢弃，overflow 交付前的后续 `changed` 也不再记录。`native_queue` 来自 inotify `IN_Q_OVERFLOW`（影响所有 root）或 Windows 零字节完成/`ERROR_NOTIFY_ENUM_DIR`；`pending_capacity` 表示 `max_pending`/`pending_path_bytes` 耗尽；`incomplete_tree` 表示运行期新子目录无法加 watch（目录预算、系统上限、访问或路径长度），root 此后保持 incomplete，直到宿主 remove 后以更大预算重新 add。监视从不在丢事件后继续表现为健康。
- `root_removed{ root }`：root 被删除、移动或不再可监视。交付该事件即释放 root，之后其 id 过期。

## Linux

使用 `inotify_init1(IN_NONBLOCK|IN_CLOEXEC)` 和 `eventfd` 中断，`poll` 等待两个 FD；没有计时器线程或轮询循环，超时只作为 `poll` 参数。监视 mask 为 create/delete/modify/attrib/close_write/moved_from/moved_to/delete_self/move_self，加 `IN_ONLYDIR|IN_EXCL_UNLINK`；子目录加 `IN_DONT_FOLLOW`，遍历不跟随 symlink，同一 root 内重复 inode（bind mount 回环）只监视一次。目录先加 watch 再列出，新建（`IN_CREATE|IN_ISDIR`）或移入（`IN_MOVED_TO`）的子树在预算内补加 watch；`IN_MOVED_FROM` 移除旧路径下的整个子树 watch，避免用陈旧路径报告。子目录 `IN_IGNORED` 释放槽位；root 的 `IN_IGNORED`/`IN_DELETE_SELF`/`IN_MOVE_SELF`/`IN_UNMOUNT` 产生 `root_removed`。路径最长 4095 字节。

## Windows

每个 root 以 `FILE_LIST_DIRECTORY` 和 `FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OVERLAPPED` 打开目录句柄，共享读/写/删除，使用 manual-reset 事件做 overlapped `ReadDirectoryChangesW`；递归由原生 `bWatchSubtree` 提供。`interrupt()` 设置 manual-reset 事件，`wait` 用 `WaitForMultipleObjects` 同时等待中断和各 root，处理一个完成后再非阻塞检查其他 root，避免低序号 root 饿死其他 root。条目变化报告其父目录（原生相对路径的上一级，UTF-16 按 WTF-8 转换），不判断条目是否目录；短文件名不展开。零字节完成或 `ERROR_NOTIFY_ENUM_DIR` 为 `native_queue` overflow；句柄 delete pending、读取失败或重新提交失败为 `root_removed`，`last_failure` 保存 Win32 码。root 自身被重命名不能可靠检测。`removeRoot`/`deinit` 先 `CancelIoEx`，再以 `GetOverlappedResult(..., TRUE)` 等待完成，之后才关闭句柄和事件。

## 已验证范围

`zig build test-file-watch` 覆盖 pending 合并/FIFO/容量、目录路径池压缩与预算、descriptor 表删除抖动、root 路径校验、拼接上限和 UI 线程拒绝。

`zig build smoke-file-watch` 在 Linux（Debug 与 ReleaseSafe）实际运行：在临时目录中由宿主创建的 worker 线程运行 Watcher，验证空闲超时、零超时读取、文件创建/修改、嵌套目录新建并立即写入、目录重命名后新路径报告且旧路径不再出现、文件和子树删除、20 次写入在一个 debounce 窗口内合并、持续写入下首个批次受 `max_latency_ms` 约束（本机约 200 ms）、容量为 1 的批次逐个顺延且不丢事件、`ResultCapacityExceeded` 不消费事件、跨线程 `interrupt` 与预先中断、跨线程调用 `WrongThread`、`max_pending` 溢出、`max_directories` 初始失败与运行期 `incomplete_tree`、root 删除、重叠 root、非递归模式，以及 12 轮 init/addRoot/deinit（含重复 deinit）后 `/proc/self/fd` 计数回到基线。

**Windows 路径只验证了 `x86_64-windows-gnu` 交叉编译（`zig build build-smoke-file-watch -Dtarget=x86_64-windows-gnu`），尚未在 Windows 上运行；** CI 的 Windows 列表包含 `smoke-file-watch`，其结果以实际运行为准。inotify 原生队列溢出和 Windows 零字节完成未被人为触发，只验证了代码路径编译；网络共享、可移动卷卸载和大规模目录树（数万目录）的行为与耗时未测量。本模块的详细模式与 ignore 规则未实现；页面监视入口、按名称授权和基于快照比较的详细事件由 [watch 插件](plugin-watch.md) 提供。

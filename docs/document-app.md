# 文档应用模型

`ziggurat_document_app` 是只依赖核心的可选模块，为“每个文件一个窗口”的文档型应用提供文档身份、重复打开检测、最近文档、关闭与退出预检中的未保存状态、原子保存、自动保存调度、外部修改冲突检测和崩溃恢复。模块没有全局状态、allocator、后台线程或计时器；文档内容、序列化格式和提示界面都属于宿主。

模块分两层：

- `Registry` 是主线程状态。槽位数组由调用者提供，容量固定，不分配；它记录每个文档的身份、窗口、修订号、磁盘戳和待处理的关闭。
- `Files` 与 `recovery.Session` 是显式阻塞 I/O，只能在宿主自己的 worker 上调用，结果通过 `App.post` 回到主线程再交给 `Registry`。`Files.ui_thread` 设为 App 所有者线程时，主线程调用返回 `UiThreadIo`；只有 `App.run` 返回后的收尾工作可以传 null。

## 身份与重复打开

```zig
// worker
const identity = try files.resolve(path);
// 主线程（App.post 之后）
switch (try registry.claim(&identity)) {
    .existing => |doc| _ = try registry.reveal(doc),
    .reserved => |doc| {
        // worker 读取 files.read(...)，回到主线程后创建窗口
        const window = try app.createWindow(.{ .on_close = registry.closeHandler(), .on_closed = registry.closedHandler() });
        try registry.attach(doc, window, loaded.stamp);
    },
}
```

`resolve` 只接受绝对路径，解析符号链接后得到规范路径，并记录文件对象键（Linux 为设备号与 inode，Windows 为卷序列号与文件索引）。两个身份在路径相同，或双方对象键都已知且相同（硬链接、不同写法）时视为同一文档。Windows 路径按 ASCII 忽略大小写比较；其他系统按字节比较。原子替换会给同一路径换新的对象键，所以路径匹配始终有效，保存后的新键由 `attach`、`finishSave` 和 `reloaded` 更新。

`claim` 在文档仍在加载、尚无窗口时也返回 `existing`，并发的两次打开因此只产生一个窗口；`reveal` 在没有窗口时返回 false。加载或创建窗口失败时调用 `cancel` 释放预留。`claimUntitled` 分配“Untitled N”文档，`displayName` 返回文件名或该名称。一个窗口只能绑定一个文档（`WindowInUse`）。

## 未保存状态与关闭、退出

`edited` 每次内容变化递增修订号，保存完成把已保存修订号推进到保存时的修订。两者不同即为 dirty。`changed` 通知只在 dirty、冲突或身份变化时触发，宿主据此更新标题或菜单。

窗口关闭时 `allowClose`（或 `closeHandler`）对 dirty 且没有放弃决定的文档返回 cancel，并记录待处理的关闭原因，调用 `close_blocked`。通知运行在关闭回调中，不能阻塞、等待对话框或嵌套事件循环：宿主显示异步提示，之后保存或调用 `discard`，再重新请求关闭。保存完成时 `SaveOutcome.retry_close` 给出等待中的原因。用户取消提示时调用 `abandonClose`。

`discard` 只针对当前修订；之后的任何编辑都会撤销它，避免用户确认后继续输入的内容被静默丢弃。

`Registry.requestQuit` 在 App 自己的退出预检之前检查所有文档：只要有一个阻塞文档就标记所有阻塞文档为等待退出、调用一次 `quit_blocked` 并返回 cancelled，没有窗口提前关闭。`blocking` 列出这些文档，宿主可以用一个提示覆盖全部（全部保存、`discardAll` 或取消），再次调用 `requestQuit`。宿主直接调用 `App.requestQuit` 时，核心以 quit 原因询问的关闭回调同样走这条路径。`App.quit` 与 `Window.destroy` 仍然绕过否决。

窗口的 `on_closed` 调用 `closed`（或使用 `closedHandler`）释放槽位，代数递增，旧的 `DocumentId` 与保存凭据不会作用于复用槽位。`released` 通知报告恢复快照名称以及 `unsaved`：强制关闭或强制退出时仍有未保存内容，宿主应保留快照供下次恢复；否则删除快照。

## 原子保存与冲突检测

```zig
const ticket = try registry.beginSave(doc, .normal);
// worker：序列化 ticket.revision 对应的内容
const result = try files.save(ticket.path.slice(), bytes, &write_buffer, .{ .expected = ticket.expected });
// 主线程
switch (result) {
    .saved => |stamp| _ = try registry.finishSave(&ticket, stamp),
    .conflict => try registry.conflictSave(&ticket),
}
```

`Files.save` 在目标旁写临时文件，flush、sync 后 rename 覆盖。写入、同步或 rename 失败都保留原文件。POSIX 保留原文件的权限位，并尽力同步父目录项；这是原子可见性，不是对所有文件系统的掉电持久性承诺。Windows 上的 rename 不保留原文件的 ACL 或备用数据流。

磁盘戳包含大小、修改时间和对象键。`expected` 非空时，写入前和 rename 前各比较一次；不一致返回 `.conflict`（`modified` 或 `missing`），不替换文件。第二次比较到 rename 之间其他进程的写入无法检测；粗粒度时间戳文件系统上同一时间刻内大小不变的修改也无法仅凭元数据发现。`Files.probe` 不读内容地比较磁盘与已知戳，宿主在激活窗口等显式时机调用，发现修改后 `externallyModified`。

冲突状态暂停自动保存，`beginSave(.normal)` 返回 `Conflict`。宿主让用户选择重新载入（`reloaded`，内容来自磁盘、文档变为干净）或覆盖（`beginSave(.overwrite)`，跳过比较）。每个文档同一时刻只有一个保存（`SaveInProgress`）；保存期间的编辑使保存完成后仍为 dirty。保存失败用 `failSave`，状态和等待中的关闭不变。

另存为先在 worker 上 `resolveTarget`（目标可以尚不存在：解析父目录并保留文件名），再 `beginSaveAs`。目标已由另一个文档打开时返回 `AlreadyOpen`，保证每个文件仍只有一个窗口。完成后未命名文档变为文件文档，旧快照名称在 `obsolete_snapshot` 中返回。

## 自动保存与快照调度

`Policy` 设定自动保存的静默延迟与从首次未保存编辑起的最长延迟，以及恢复快照的对应延迟。时间由调用者以纳秒传入，registry 不读时钟也不启动计时器。`nextDeadline` 返回最早的截止时间，没有待处理工作时为 null，宿主空闲时就不需要任何计时器。到期后 `dueAutosaves`/`dueSnapshots` 列出文档；传入 `maxInt(i128)` 可在失去焦点等时机立即刷新全部。自动保存只针对文件文档，跳过正在保存或处于冲突中的文档；快照也覆盖未命名文档。

## 崩溃恢复

`recovery.Session` 是一个进程的快照目录，名称由宿主提供的随机 nonce 决定，并对其中 `lock` 文件持有排他锁。进程崩溃时操作系统释放锁，下次启动 `recovery.orphans` 列出锁可获取的会话，即未正常结束的进程；仍在运行的其他实例的会话被跳过。`Session.adopt` 获取孤立会话的锁，使两个实例不会同时恢复同一会话。

```zig
const ticket = try registry.beginSnapshot(doc);
// worker
try session.write(&ticket.name, .{ .path = path, .base = stamp, .revision = ticket.revision, .saved_ns = now, .content = bytes }, &encoded, &write_buffer);
// 主线程
if (registry.finishSnapshot(&ticket) == .obsolete) { /* worker 上 session.remove(&ticket.name) */ }
```

快照文件原子替换，格式带版本魔数和 CRC32，截断、损坏或外来文件被拒绝。名称对文件文档是规范路径的哈希，对未命名文档是序号。快照记录原路径和编辑所基于的磁盘戳，恢复时宿主可以用 `Files.probe` 发现磁盘在崩溃后又被修改。恢复的文件文档按正常打开流程 `claim`/`attach` 后以 `edited` 标记为 dirty。

文档保存或改名后，旧快照由 `finishSave` 的 `obsolete_snapshot` 或 `finishSnapshot` 的 `.obsolete` 报告，宿主在 worker 上删除。正常退出时 `Session.finish` 删除整个会话目录；`close` 只释放锁并保留快照。

## 最近文档

`Recent` 在调用者提供的存储里保存最近打开的绝对路径，最新的在前，重复路径移到最前，满时淘汰最旧的。`encode`/`decode` 使用带版本头的逐行文本，`decode` 只在整个输入有效时替换列表。持久化通过宿主 worker 上的文件读写完成；文件已不存在的条目由宿主用 `Files.probe` 判断后 `remove`。系统级最近文档与任务栏跳转列表的注册不在本模块中。

## 验证

`zig build test-document-app` 使用核心测试后端验证重复打开、关闭和退出预检、放弃决定的撤销、强制关闭的未保存报告、槽位复用、自动保存与快照截止时间、另存为冲突、快照过期，以及 Linux 上的符号链接与硬链接身份、原子保存与权限保留、外部修改冲突、快照编码与会话锁。Windows 目标只经过交叉编译，尚无运行验证。

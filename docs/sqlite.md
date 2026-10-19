# SQLite

`ziggurat_sqlite` 是可选模块，静态链接固定版本的 SQLite amalgamation，提供连接、预处理语句、类型化绑定、逐行读取、事务与 savepoint、以及基于 `PRAGMA user_version` 的迁移。模块不导入核心，也不持有 App、Window、线程或全局状态。

## 获取源码与构建

构建不访问网络。先运行：

```sh
python scripts/fetch-sqlite.py            # 下载、校验并解出 .deps/sqlite-3.54.1
python scripts/fetch-sqlite.py --verify-only
zig build test-sqlite
```

脚本只从 `https://sqlite.org/2026/sqlite-amalgamation-3540100.zip` 下载 SQLite 3.54.1，同时校验大小 2990966 字节、SHA-256 `0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9` 与官方发布页给出的 SHA3-256 `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30`。只解出 `sqlite3.c`、`sqlite3.h`、`sqlite3ext.h`，不解出命令行 shell；已有目录逐字节核对，不覆盖、不递归删除。

源码缺失时 `zig build` 的配置阶段照常进行，只有实际编译 SQLite 的步骤失败并提示先运行脚本。因此 `test-sqlite` 不在 `test`/`check` 中，CI 在两个平台单独拉取后运行。宿主以模块名 `ziggurat_sqlite` 导入。

编译选项：`SQLITE_THREADSAFE=2`（连接不在线程间并发共享，因此不需要每连接互斥锁）、`SQLITE_DQS=0`（双引号只表示标识符）、关闭 shared cache、扩展加载与已弃用接口，启用 FTS5、R*Tree 与数学函数，WAL 默认 `synchronous=NORMAL`。SQLite 为公有领域代码，分发时无需附带许可文本。

## 连接

```zig
const sqlite = @import("ziggurat_sqlite");

var db = try sqlite.Database.open(allocator, path, .{
    .mode = .read_write_create, // .read_only / .read_write
    .busy_timeout_ms = 5000,    // 等待其他连接的锁，超时返回 error.Busy
    .foreign_keys = true,
    .journal = .wal,
    .ui_thread = app_owner_thread_id,
});
defer db.close();
```

`allocator` 只用于路径的临时 NUL 结尾副本，调用返回前释放。SQLite 引擎自身的页缓存、语句与中间结果由引擎的系统分配器管理，`close` 时释放；它们不计入调用者 allocator，也不能被其恢复。每个连接使用私有页缓存。`openMemory` 打开随 `close` 消失的内存数据库。

`close` 前必须 finalize 所有语句（Debug 断言）；未提交的事务被回滚。连接打开时设置的 `ui_thread` 让所有可能阻塞的调用（open、exec、prepare、step、事务、迁移）在该线程上返回 `error.UiThreadIo`，`close` 与 `rollback` 在该线程上触发断言。

## 语句、绑定与读取

```zig
try db.exec(
    \\CREATE TABLE note (id INTEGER PRIMARY KEY, title TEXT NOT NULL, body BLOB);
    \\CREATE INDEX note_title ON note(title);
);

var insert = try db.prepare("INSERT INTO note (title, body) VALUES (?, ?)");
defer insert.finalize();
try insert.exec(.{ "hello", sqlite.blob(bytes) }); // 绑定、执行到底、reset
const id = db.lastInsertRowId();

var query = try db.prepare("SELECT id, title, body FROM note WHERE title LIKE :pattern");
defer query.finalize();
try query.bindNamed(":pattern", "h%");
while (try query.next()) |row| {
    const Note = struct { id: i64, title: []const u8, body: ?[]const u8 };
    const note = try row.decode(Note);
    try titles.append(allocator, try allocator.dupe(u8, note.title));
}
```

- `exec` 执行零到多条以 `;` 分隔的语句并丢弃结果行；`prepare` 只接受一条语句，多条返回 `MultipleStatements`，只有空白/注释返回 `EmptyStatement`。`preparePersistent` 提示语句会长期缓存复用。
- `bind(index, value)` 从 1 开始；`bindAll` 按位置绑定元组，元素数必须等于参数数；`bindNamed` 使用带前缀的名称。支持 `null`、可选值、bool、整数（超出 i64 返回 `IntegerOverflow`）、枚举、浮点、字节切片/字符串字面量（TEXT）、`sqlite.blob(bytes)`（BLOB）、`ZeroBlob` 和 `Value`。文本与 BLOB 在绑定时复制，参数无需活过调用。
- `rebind(args)` = reset + 清除旧绑定 + `bindAll`，用于复用查询语句；`Statement.exec(args)` 在此基础上执行到底并 reset。
- `next()` 返回借用的 `Row`；其中的文本/BLOB 切片在下一次 `step`/`next`/`reset`/`finalize` 前有效，需要保留时用 `row.dupe(allocator, i)` 或自行复制。
- `row.get(T, i)` 从 0 开始，不做静默转换：可选类型接受 NULL，非可选遇 NULL 返回 `UnexpectedNull`；整数、枚举、bool 要求 INTEGER 存储；浮点接受 INTEGER 或 REAL；`[]const u8` 接受 TEXT 或 BLOB；`Value` 原样返回动态类型。其他存储类型返回 `TypeMismatch`。`decode(T)` 按列顺序填充结构体，字段数必须等于列数。
- 只读完部分结果的语句仍持有读快照：在同一连接上 `COMMIT` 或检查点之前先 `reset`，否则 `COMMIT` 返回 `Busy` 且事务保持打开。

错误映射为 `sqlite.Error`（`Busy`、`Constraint`、`ReadOnly`、`Interrupted`、`SqlError` 等）。`db.lastError()` 返回扩展结果码与 SQLite 消息，消息在同一连接的下一次调用前有效，例如 UNIQUE 冲突为 `2067`。

## 事务与 savepoint

```zig
var tx = try db.begin(.immediate); // .deferred / .exclusive
errdefer tx.rollback();
try insert.exec(.{ "a", null });
var inner = try db.savepoint();
errdefer inner.rollback();
try insert.exec(.{ "b", null });
try inner.commit();
try tx.commit();
```

`begin` 在已有事务时返回 `TransactionActive`；嵌套工作使用 `savepoint`，它在事务内外都可用，必须按创建的逆序提交或回滚。`rollback` 幂等且不返回错误，适合 `errdefer`。`commit` 失败（如 `Busy`）时事务保持打开，可以重试或回滚；SQLite 已自动回滚的情况下 `rollback` 不再执行语句。

## 迁移

```zig
const migrations = [_]sqlite.Migration{
    .{ .version = 1, .sql = "CREATE TABLE note (id INTEGER PRIMARY KEY, title TEXT NOT NULL)" },
    .{ .version = 2, .sql = "ALTER TABLE note ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0" },
    .{ .version = 3, .sql = "CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT)", .run = seedSettings },
};
const report = try db.migrate(&migrations); // report.from → report.to
```

版本必须为正且严格递增，否则返回 `InvalidMigrations`。每个待执行版本在独立的 IMMEDIATE 事务中执行其 SQL、可选的 `run` 数据步骤并写入 `user_version`，失败时保留之前已完成的版本，失败版本整体回滚。事务内重新读取版本，因此多个进程同时迁移时每步只执行一次。数据库版本高于所有已知迁移时返回 `SchemaTooNew`；已有事务时返回 `TransactionActive`。`userVersion`/`setUserVersion` 可直接读写版本。

## 线程与不阻塞主线程

SQLite 调用会读写磁盘并可能等待其他连接的锁，不应在 App 主线程上运行。一个 `Database` 及其语句同一时刻只属于一个线程；可以在线程间转移，但不能并发使用。推荐由宿主自己的 worker 线程拥有连接，主线程把请求交给 worker，worker 完成后用 `App.post` 把结果带回主线程：

```zig
const Lookup = struct {
    app: *ziggurat.App,
    pattern: []const u8,
    result: sqlite.Error!usize = 0,

    // worker 线程：拥有 db，执行查询
    fn run(self: *Lookup, db: *sqlite.Database) void {
        self.result = count(db, self.pattern);
        // post 成功后任务在 App 关闭前恰好执行一次；返回 Full/Closed 时所有权仍在 worker。
        while (true) {
            self.app.post(.{ .context = self, .call = deliver }) catch |err| switch (err) {
                error.Full => { // worker 上退避重试，不阻塞 UI
                    std.Thread.sleep(std.time.ns_per_ms);
                    continue;
                },
                error.Closed => return self.discard(), // App 正在关闭：在 worker 上释放
            };
            return;
        }
    }

    fn count(db: *sqlite.Database, pattern: []const u8) sqlite.Error!usize {
        var stmt = try db.prepare("SELECT count(*) FROM note WHERE title LIKE ?");
        defer stmt.finalize();
        try stmt.bindAll(.{pattern});
        const row = (try stmt.next()) orelse return 0;
        return @intCast(try row.get(i64, 0));
    }

    // 主线程：更新状态并使窗口失效
    fn deliver(context: *anyopaque) void {
        const self: *Lookup = @ptrCast(@alignCast(context));
        state.applyCount(self.result);
        window.invalidate();
    }
};
```

规则：

- 连接以 `.ui_thread = <App 所有者线程 id>` 打开，误在主线程上调用会得到 `UiThreadIo`，而不是卡住事件循环。
- `App.post` 交接的数据（例如 `Lookup`）由宿主分配并保持稳定地址，直到 `deliver` 运行；需要复制到主线程的文本在 worker 上用宿主的 allocator 复制，`Row` 借用的切片不能跨线程交接。
- 取消：`db.interrupt()` 可以在任意线程调用，正在运行和随后排队的语句以 `Interrupted` 结束，连接仍可继续使用；调用者保证中断时连接未被关闭。主线程关闭窗口或 App 时先中断，再等待 worker 自己收尾并 `close`。
- 多个 worker 需要并发访问时各自打开连接；WAL 模式允许一个写者与多个读者并行，写冲突在 `busy_timeout_ms` 后返回 `Busy`。
- 模块不提供隐式线程池或同步等待包装；队列、重试与关闭顺序由宿主决定。

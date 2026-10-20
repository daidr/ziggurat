# sqlite 插件

sqlite 插件让页面使用宿主给定目录中的 SQLite 数据库。Zig 半部是 `ziggurat_plugin_sqlite` 模块（`src/page_runtime/plugins/sqlite.zig`），页面半部是 `@ziggurat/plugin-sqlite` 包（`packages/plugin-sqlite`），清单是包内的 `ziggurat-plugin.json`。约定见[插件](plugins.md)。

## 宿主

```zig
const sqlite_plugin = @import("ziggurat_plugin_sqlite");

var plugin: sqlite_plugin.Plugin = undefined;
try plugin.init(allocator, .{ .post = .app(app), .directory = data_dir });
defer plugin.deinit(); // App.run 返回、Host.detach 之后，App.deinit 之前
try host.use(plugin.plugin());
```

- `directory` 必须是绝对路径。页面只给出其中的文件名；打开可写数据库时，缺失的目录（包括 `directory` 本身）会被创建。
- SQLite 在 `init` 时以 `std.DynLib` 加载：`library` 为 null 时依次尝试系统库（Windows 为 `winsqlite3.dll`、`sqlite3.dll`，Linux 为 `libsqlite3.so.0`、`libsqlite3.so`），也可以给出路径。版本须不低于 3.7.14。加载失败时插件照常启动，页面打开数据库以 `unsupported` 失败。应用要随包分发自己的 SQLite 时，在应用的清单中声明该库，并把路径传给 `library`。宿主 Zig 代码直接使用数据库时用可选的 [`ziggurat_sqlite`](sqlite.md) 模块；插件在运行时加载库，因此不需要先拉取 amalgamation，也留在 `test` 和 `check` 中。
- `workers`（默认 2）个 worker 由 `init` 启动、`deinit` join，插件不使用全局线程池。同一连接的操作按到达顺序逐个执行，不同连接可以并行。`allocator` 必须线程安全。
- `busy_timeout_ms`（默认 5000）是等待其他连接所持锁的时间，负数表示不等待。
- `max_result_bytes`（默认 64 MiB）限制一次查询返回的行，超过时以 `limit` 失败。
- 每个页面最多同时打开 16 个连接、32 个未完成操作。页面离开或换代时，它的操作被中断，连接被关闭。

## 页面

```ts
import { open } from "@ziggurat/plugin-sqlite";

const db = await open("app.db");
await db.execute("CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY, title TEXT, done INTEGER)");
const inserted = await db.execute("INSERT INTO tasks(title, done) VALUES (?, ?)", ["Write docs", false]);
const { columns, rows } = await db.query("SELECT id, title FROM tasks WHERE done = ?", [false]);
await db.transaction([
  { sql: "UPDATE tasks SET done = ? WHERE id = ?", params: [true, inserted.lastInsertId] },
  { sql: "INSERT INTO tasks(title, done) VALUES (?, ?)", params: ["Ship", false] },
]);
await db.close();
```

- `open(name, { readOnly })`：`name` 是目录中以 `/` 分隔的相对路径，或私有的 `":memory:"`。不能为空、为绝对路径、含 `.`/`..` 或空段、含 `\` 和 Windows 不允许的字符、以 `.` 或空格结尾，也不能是 Windows 设备名（如 `nul`、`com1.db`）；路径不能穿过 symlink，数据库本身必须是普通文件。只读打开不会创建数据库。外键约束默认开启。
- `execute(sql, params)` 执行恰好一条语句，返回 `{ changes, lastInsertId }`；`lastInsertId` 是 bigint。`RETURNING` 的行被读完丢弃，需要它们时用 `query`。
- `query(sql, params)` 返回 `{ columns, rows }`，重名列保留顺序。超出一条消息的结果分成几部分发送，页面合并后返回；大结果应自行分页。
- `transaction(statements)` 以 `BEGIN IMMEDIATE` 执行一批语句并提交；任一语句失败时整体回滚，错误信息以 `statement N:` 指明是第几条。
- `close()` 关闭连接；并发和重复的调用共享同一次关闭，关闭后的调用以 `closed` 失败。

值：SQLite 的 NULL、INTEGER、REAL、TEXT、BLOB 分别对应 `null`、`number`（超出安全整数范围时为 `bigint`）、`number`、`string` 和 `Uint8Array`。参数还接受 `boolean`（绑定为 0 和 1）。超出安全整数的 `number`、非有限数和超出 64 位的 `bigint` 在发送前被拒绝。读出的 `Infinity`、`-Infinity` 和 `NaN` 保留。不是合法 UTF-8 的 TEXT 中的非法字节被替换为 U+FFFD。一次调用的参数受 64 KiB 消息上限约束。

语句必须是一条：多条语句、空语句以 `invalid` 失败。页面不能自行开始或结束事务（`BEGIN`、`COMMIT`、`SAVEPOINT` 等），也不能 `ATTACH`/`DETACH` 或 `VACUUM INTO`，这些以 `denied` 失败。

错误是 `SqliteError`，`code` 为：

- `invalid`：语句不是一条、参数数量或值不对；
- `denied`：名称不合法、穿过 symlink，或语句被禁止；
- `closed`：连接已关闭，或操作因页面离开而中断；
- `limit`：连接或操作过多，或结果超过上限；
- `unsupported`：SQLite 库无法加载；
- `sqlite`：SQLite 报告的错误，信息含扩展错误码。

## 验证

`zig build test-plugin-sqlite` 使用系统 SQLite 在临时目录中运行：各存储类型的往返（含 64 位整数、无穷大、空 BLOB 和非法 UTF-8 文本）、`RETURNING` 与 `changes`、语句检查（参数、多条语句、被禁止的语句）、多部分查询与结果上限、事务提交与回滚、第二个连接与只读连接、名称与 symlink 拒绝、嵌套目录创建、连接上限与页面换代时关闭、取消正在运行的查询，以及缺少库时的 `unsupported`。`bun test packages` 覆盖页面包的编码、解码、错误和关闭。`smoke-plugin-sqlite -Dwebview=true` 在真实 WebView 中经页面包使用嵌套目录中的数据库：被拒绝的名称、BLOB 与 bigint、分批事务与回滚、多部分查询和只读重新打开。Linux（WebKitGTK，隐藏窗口）上已运行通过；Windows 的单元测试由 CI 运行，WebView smoke 列在 CI 手动触发的 WebView2 任务中。这些检查不建立性能结论。

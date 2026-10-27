# 独立 CookieStore

`ziggurat_webview.CookieStore` 在 Linux 显式绑定一个已准备的 `Profile`，直接使用其 WebsiteDataManager。它不创建 View、WebContext、Window、后台线程、定时器或 App keepalive。普通 View 不会自动构造 Store。Windows 的独立 Store 返回 `UnsupportedCapability`，且在读取 App/Profile 或调用 allocator 前拒绝；既有 View 工具接口不变。

```zig
const store = try web.CookieStore.create(allocator, app, profile, .{});
const operation = try store.query(.{
    .url = "https://example.test/account",
    .name = "session",
}, .{ .context = state, .complete = completed });
```

App 必须覆盖 Store 的全部使用，包括显式 `close`。所有方法与回调在进程主线程执行。异步操作不维持 App 存活；宿主需要已有窗口等明确的运行责任。没有窗口时，App 的正常退出会停止 Store，不能靠 Store 隐式运行另一个事件循环。

## 查询与授权

默认只读。`query(Filter, Completion)` 接受 HTTP/HTTPS URL，URL 适配由引擎执行。可选 `name/domain/path` 对返回的原生身份做精确 UTF-8 字节匹配；不去掉 domain 前的点，不推测子域，也不提供端口隔离。结果包含 HttpOnly、Secure、SameSite 和可选 Unix 到期秒数。`expires=null` 表示会话 Cookie。

`listAll(Completion)` 只读枚举整个 Profile 的 Cookie，要求创建时显式 `allow_read_all=true`。默认、仅 write 或仅 clear 授权均在提交和结果分配前返回 `PermissionDenied`；这三个授权互不隐含。它不使用某个 URL 的可发送性过滤，因此结果可包含其他域、其他 path、HttpOnly 和 Secure Cookie；这是宿主对整个 Profile 的读取能力。结果顺序由引擎决定，不承诺排序或稳定顺序。行数、结果字节与 Store 峰值额度与 query 相同；超过任一限制完成 `.result_too_large`，不会返回部分成功或静默截断。它没有分页、跨操作原子快照或持久化屏障。

```zig
const reader = try web.CookieStore.create(allocator, app, profile, .{ .allow_read_all = true });
const operation = try reader.listAll(.{ .context = state, .complete = completed });
```

`allow_write=true` 单独授权 `set`、`deleteExact` 和 `deleteKey`，包括 HttpOnly Cookie。这是对整个 Profile 的授权，不是某个页面 origin 的许可。`allow_clear=true` 独立授权 `clear(.entire_profile_cookies)`；它不依赖 write，也不授予 write。clear 只选择 Cookie 数据，不清 localStorage、缓存、密码或其他网站数据。

`deleteExact(cookie, completion)` 接受完整 Cookie 快照，通常直接来自 Batch。当前原生实现按 name/domain/path 和 expected value 删除；旧 value 对应的 Cookie 已更新时，操作可能成功完成却未删除新值。它不是原子 compare-delete，也不声称无值 key-only 删除。删除不套用新增 Cookie 的 SameSite/到期策略，以便删除已有 legacy Cookie。

`deleteKey(Key, Completion)` 无须 Cookie value，按原生 name/domain/path 身份提交一次已过期 Cookie 的 add。它先检查 owner、Busy、App/Profile 入口和独立 write 授权，再读取借用 key 字节；read-all、clear、replace-all 的任意组合都不隐含 write。输入 name/domain/path 与现有 Key 校验共用固定长度、UTF-8 和字符规则，并在调用 SDK 前复制。它不读取 Cookie 列表，不查旧值，不把 deleteExact 或 clear/replaceAll 拼成无值删除。

```zig
const writer = try web.CookieStore.create(allocator, app, profile, .{ .allow_write = true });
const operation = try writer.deleteKey(.{
    .name = "session",
    .domain = "example.test",
    .path = "/account",
}, .{ .context = state, .complete = completed });
```

已核对 libsoup 3.0.7/3.4.4 的原生 jar：domain lookup 大小写不敏感，但保留 leading dot；`example.test` 的 host-only 身份与 `.example.test` 的 domain 身份分别匹配，不自动增删点。name/path 精确匹配，不扩展子 path。现有 value、Secure、HttpOnly、SameSite 和到期属性不参与该身份比较；所以 value 更新后仍可无值删除。absent key 是 no-op，不新增空值 Cookie。整个引擎对域名格式及规范化的最终处理仍由 SDK 决定，不能由上述已核对实现推出跨引擎的字节身份合同。

提交的 tombstone 固定为 empty value、Secure、HttpOnly、SameSite=Lax 和 Unix 0 到期；它沿用 SDK 的已过期写入语义，不设置计时器等待过期。这覆盖合法的 `__Secure-` 与 host-only、path=/ 的 `__Host-` 身份。引擎仍可在身份查找前拒绝公共后缀、非法前缀等 Cookie；该入口不保证清除 SDK 当前写入策略不接受的 legacy 身份，持有完整快照时可使用 deleteExact。它也不是删除整个域或所有同名 Cookie 的接口。

该路径复用自 2.20 已有的 add/finish 强引用，没有新增可选符号 pair 或提高 2.40 加载边界。[WebKit 2.40.5 API](https://github.com/WebKit/WebKit/blob/webkitgtk-2.40.5/Source/WebKit/UIProcess/API/glib/WebKitCookieManager.cpp) 与 [2.52.6 Soup backend](https://github.com/WebKit/WebKit/blob/webkitgtk-2.52.6/Source/WebCore/platform/network/soup/NetworkStorageSessionSoup.cpp) 将单 Cookie 传给 Soup jar；[libsoup 3.4.4 jar](https://github.com/GNOME/libsoup/blob/3.4.4/libsoup/cookies/soup-cookie-jar.c) 在匹配身份后按 expired 分支删除，不比较旧 value。`.completed` 仍只表示 SDK 的异步受理责任已结束，不能证明实际改变、与并发页面写入的顺序、事务、同步可见或 fsync。观察结果应显式 query 或实际 HTTP 请求；cancel、Stop、close 不能回滚已经发生的过期写入。

URL 查询、add、delete 和 Cookie-only clear 沿用 WebKit 2.40 接口。`listAll` 使用自 2.42 提供的[异步全量枚举](https://webkitgtk.org/reference/webkit2gtk/stable/method.CookieManager.get_all_cookies.html)及其 [finish](https://webkitgtk.org/reference/webkit2gtk/stable/method.CookieManager.get_all_cookies_finish.html)。Linux ELF 中这两个入口都为可空弱引用，只有完整 pair 可用才接受操作；旧 Runtime 缺任一入口时返回 `UnsupportedCapability`，不调用 Completion、不取得物理槽或分配操作存储。该检查仍遵守进程主线程和 Store/App/Profile 已关闭的拒绝规则。加载器解析这两个弱引用；普通构造和 query 没有逐次符号查询，不增加 Store/Op 字段、对象或分配。使用同一个已由既有强引用依赖保留的 WebKit 库，不另开 loader；Options 在已验 64 位 Linux 上仍为 56 字节，新 grant 使用既有 padding。这里保留 2.40 的加载边界，不把编译时 SDK 版本当作运行时能力。

`replaceAll(rows, Completion)` 是独立授权的非空原生批量替换，要求 `allow_replace_all=true`。read-all、write、clear 的任意组合均不授予 replace-all；replace-all 也不授予这三者。输入先按 descriptor 长度做 checked aggregate 预检，再验证所有 Cookie 的写入策略与 exact `name/domain/path` 重复身份，随后完整复制元数据和字符串，最后只调用一次原生 [replace_cookies](https://webkitgtk.org/reference/webkit2gtk/stable/method.CookieManager.replace_cookies.html)。不读取旧集合，也不以 clear/set 拼接替代。

```zig
const replacer = try web.CookieStore.create(allocator, app, profile, .{ .allow_replace_all = true });
const operation = try replacer.replaceAll(&replacement_cookies, .{ .context = state, .complete = completed });
```

输入必须为非空且不超过 `limits.max_rows`，硬上限 128。空输入返回 `EmptyCookieReplacement`，不调用 SDK 或 Completion；2.42 与已验 2.52 SDK 都拒绝空 GList，没有接受责任或回调可等待。显式清空仍走独立 clear 授权。exact 重复身份返回 `DuplicateCookieIdentity`；不会替调用者规范化 domain。已核对 libsoup 3.4.4 的构造器直接复制 domain 字节，leading dot 区分域匹配与精确 hostname；整个引擎对大小写、域策略及冲突的最终处理仍由原生实现决定。exact 去重不保证引擎视角下一定有相同行数或无冲突。它在最多 128 行和 aggregate 32 KiB 内做受限 O(N²) 比较，不能作为无限数据接口。

适配层校验、容量、malloc 或原生 Cookie 构造失败发生在接受前，不调用 Completion，旧集合不受该请求影响。一旦 SDK 受理，失败、cancel、Stop 或 close 都不能保证保旧、撤销副作用或回滚。官方 Soup 后端以原生一次替换入口完成删除/添加，未提供事务回滚合同；本模块不承诺其他页面看不到中间状态、所有输入均实际保留、与并发页面写入的排序，或 fsync。`.completed` 只是 SDK 报告完成，显式 query/listAll 或实际请求用于观察结果。

replace 的 async/finish 同样使用完整可空弱引用 pair，缺任一入口接受前返回 `UnsupportedCapability`。其他平台的冷 Store 尚未实现。

## 接受、结果与取消

成功返回 Operation 前，逻辑槽和物理 Op 已发布，随后才调用原生引擎。回调可能在方法返回前发生；回调内 close 可能使返回的 token 随 `on_closed` 失效。Store 必须覆盖每一次 token 的使用，关闭后的悬垂指针不受代数保护。

接受前的 `Full/Closed/OutOfMemory/CapacityExceeded` 不调用 Completion，不接管其 context。接受后恰好完成一次；`Result.completed` 只表示 SDK 成功结束操作，可能是 no-op，不证明 Cookie 一定改变、写入磁盘或已经 fsync。需要可见性时显式 query，或检查下一次真实 HTTP 请求。

查询成功将 `Result.cookies` 的 Batch 所有权交给 Completion，包括空 Batch：

```zig
fn completed(context: *anyopaque, input: web.cookies.Result) void {
    _ = context;
    var result = input;
    defer if (result == .cookies) result.cookies.deinit();
    switch (result) {
        .cookies => |batch| useRows(batch.rows),
        .completed => {},
        else => handleFailure(result),
    }
}
```

Batch 只有一个 owning allocation，完全脱离 GLib/Profile/Store/App。通过 `take()` 线性移交；旧值清空后 `deinit()` 幂等，移动后的 `take()` 返回 `BatchMoved`。allocator 必须覆盖 Batch 生存期；跨线程释放还要求该 allocator 本身允许。宿主保留多个 Batch 的总额由宿主管理，不占已经转交的 Store 额度。

`Filter.domain` 是精确的原生字节比较。需要像浏览器 Cookie 列表那样按站点挑选时，对拥有的 Batch 调用 `keepDomain(domain)`：保留该域及其子域的 Cookie，忽略大小写和任一侧的前导点（`example.com` 保留 `.example.com`、`www.example.com`，不保留 `badexample.com`），判断规则即 `cookies.inDomain`。`sort()` 按 domain（忽略大小写）、path、name 排序。两者都在 Batch 自己的存储里原地进行，不分配。

`operation.cancel()` 先摘除逻辑入口，再取消 native，并同步完成一次 `.cancelled`。它不保证撤回已经开始的写入。物理槽继续占用到 native result 真正结束；因此 logical_pending 为零时仍可能 `Full`。首片没有隐式 timeout，宿主可用自己的显式 deadline 触发 cancel。

## 停止与最终释放

每个 Store 注册自己的 App Stop 节点。停止先撤销 C→Zig 入口、整批摘下所有逻辑槽，再取消 native 并逐个完成 `.stopped`。已接受 App posts 仍先执行；Store 的停止不创建新业务入口。Profile 的 seal/close 只阻断新操作，已经接受的操作仍可完成；Store Stop 则终结逻辑回调责任。

`close()` 先尝试取消 Stop 注册；节点已被本轮停止接管时返回 `StopInProgress`，保留原状态。通常关闭立即释放 Zig owner；活动 callback/allocator 栈仍固定 owner 时返回 `.deferred`，最后 pin 退栈才释放。关闭中的递归 close 同样 deferred。替换输入/结果时的 allocator 重入可关闭 owner；候选结果随后释放，不重复完成业务回调。

可选 `on_closed` 表示 Zig owner 的最后一次使用已结束，context 可以释放。它可能早于原生物理完成，并非 C 资源、NetworkProcess 或文件系统归零屏障。迟到回调始终调用对应 finish，只访问 C-only 状态；实际 GTask finalization 释放 source object 后才归还 Op/manager/Profile lease。没有继续迭代 owner context 时，已经取消的 C-only 操作可留到后续循环或进程结束。

`web.cookieStoreNativeCounts()` 原子观察本适配层尚存的 Store、Op 与 requested malloc bytes，可以在 Zig Store 释放后使用。它不包含引擎内部引用，不构成引擎退出保证。所有 WebKit GObject 的最终 unref 仍要求进程主线程。实现对 result 的 GTask 类型与 finalizer 线程断言；不能把通用 GTask 的 callback 线程保证扩大为所有 finalizer 都在该线程。

## 容量与分配

默认且硬上限均为 8 个并发逻辑/物理操作、128 行。单 Batch 默认 64 KiB，硬上限 256 KiB，包含 Cookie 记录与字符串；超限返回 `.result_too_large`，不静默截断。输入固定限长，整个 Op 输入最多 32 KiB。替换输入包含每行 native Row、嵌入 GList 节点和四个 NUL 字符串；它不占 result_bytes，但与 Op 固定头、其他未完成操作和候选 Batch 共用 Store 总额度。已验 64 位 Linux 的 Row 为 80 字节、GList 节点 24 字节；节点与全部 raw 输入在一次 malloc 中，释放时只逐个释放 SoupCookie，节点随整块 Op 释放。Zig/C 各自最多 128 行的固定 descriptor 捕获位于调用栈；不是测得的总栈峰值。Store requested storage 默认 1 MiB、硬上限 4 MiB，候选 Batch 与 C Op/raw inputs 同时存在计入峰值。

计数只覆盖本项目实际 malloc 和调用者 allocator：Zig owner（含固定簿/Stop 节点）、C owner、Op、raw 输入副本、候选 Batch。GLib/libsoup 的 Cookie 对象及其再次复制的字符串、GCancellable、GTask、qdata 和引擎返回的完整 GList 不在此计数。query/listAll 共享固定 128 行的适配层暂存，不复制完整 GList；SDK 在 finish 前已生成完整列表，超限后释放也仍遍历整个列表。固定 pending/input 上限约束项目操作个数与输入尺寸，不能限制引擎全量枚举的峰值、工作量或响应延迟。GLib 系统分配失败可能终止进程。

Store 创建临时占两份 Profile config lease，稳定后占一份：先取得临时 lease，在任何 caller allocation 前捕获 C-only Profile 与 manager 强引用，再交还临时 lease。因此 Profile `leases=1` 会使创建返回 Full；这不是额外 WebContext。最后物理释放才交还 Store 的那份 lease。共享 Profile 的既有 Context 与其他配置另按 Profile 限额计算。

`stats().owned_bytes` 是本项目当前 requested owned bytes；`peak_reserved_bytes` 还包括已通过预检但 allocator 随后可能失败的候选保留额，包括非空替换的完整输入候选。失败的替换可以增加保留峰值，当前字节/槽/回调责任仍不增加；旧 single 请求的统计路径不由此改变。转交的 Batch 不留在 Store 当前计数中。原生 malloc 失败、调用者 owner/result 分配失败均保留明确的接受边界。已验 Linux 64 位的 C Store 仍为 160 字节、Op 仍为 96 字节；单 Cookie 与替换 GList 使用按 kind 区分的同尺寸 union。Options 仍为 56 字节，未启用替换不构造节点或输入块；没有零二进制/零指令或吞吐测量的声称。

deleteKey 复用 single Op 与同一个 32 KiB 输入和 Store 账本；只有 name/domain/path 的副本及统一字符串区的 NUL，不保留 value 快照或查询结果。没有新 Store/Options/Op 字段、owner、worker 或默认分配。其 SoupCookie、到期 GDateTime、GTask 等 SDK 内部分配沿用上述统计边界；迟到完成调用 add_finish，物理额度仍等 GTask 最终释放归还。

## 已验范围

实际原生运行环境为 WebKitGTK 2.52.6、libsoup 3.4.4、GLib 2.80.0。最低 2.40 的相关 GTask/owner IPC 路径只做官方源码核验，不宣称在 2.40 Runtime 实跑。GTask 的通用线程限制见[官方说明](https://docs.gtk.org/gio/class.Task.html)；最终释放顺序另核对 GLib 2.80 的 [GTask](https://github.com/GNOME/glib/blob/2.80.0/gio/gtask.c) 和 [GObject](https://github.com/GNOME/glib/blob/2.80.0/gobject/gobject.c)。

`test-cookies` 验证纯结果预算、UTF-8、线性移动/递归 deinit、固定槽代数和 OOM，以及非空替换的 descriptor-only aggregate/身份预检。`test-webkit-cookies` 在独立 test 对象中验证 C malloc 失败、容量拒绝、读取/替换/无值删除同步完成内 close，以及缺 async、缺 finish、两者均缺时的接受前拒绝；替换的 malloc/第一个或后续 SoupCookie 构造故障、无值删除的 malloc/Cookie 构造故障后，通过真实引擎再次 query 观察旧 Cookie 保留。生产没有这些故障分支。`smoke-webview-cookies-linux` 通过正常 App 循环验证无 View/Context 的冷操作、expected-value/path 删除、无值身份删除的 domain/path 隔离与大小写 lookup、Secure/HttpOnly/有效前缀/更新值/空值/absent、全量空/跨域与 path 的完整结果、非空批量替换/旧值消失/调用返回后复用输入/授权与输入失败保旧、两层结果容量、读取/替换/无值删除的 Stop/close/cancel 与物理 Full、读取 allocator 重入/OOM、Batch 跨 App，以及首 HTTP 请求/两页面共享/清 Cookie 保留 localStorage。兼容性另检查旧头声明和 ELF 弱引用；这不能代替 2.40 Runtime 实跑。隐藏集成检查不代表视觉质量或引擎持久化屏障。

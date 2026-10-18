# Linux 显式页面存储

`ziggurat_webview.Profile` 是可选、单 App 的持久存储所有者。它显式共享一个 WebKit WebsiteDataManager，每个 View 或 PageSession 配置仍创建独立 WebContext，避免把 scheme、请求策略或页面回调的入口共享成第二份状态权威。临时页面继续选择 `.storage = .ephemeral`；Windows 保留已有绝对 `user_data_folder` 配置，暂不接受这个 Profile owner。

## 准备与接入

磁盘准备只在宿主显式 worker 执行：

```zig
var prepared = try web.profile_storage.Prepared.prepare(
    allocator, main_thread_id, absolute_private_root, .{},
);
try prepared.handoff();
```

`Prepared` 地址在交接及全部借用期间稳定。宿主通过 `App.post` 交接；投递失败仍持有该值和释放责任，按 `reclaim` 取回 worker 所有权，不能丢弃任务或让局部变量退栈。worker 的分配器必须允许最终 owner 线程释放。主线程接受后：

```zig
try prepared.adopt();
const profile = try web.Profile.create(allocator, app, &prepared, .{});
try view.attach(window, .{
    .html = "<title>Explicit storage</title>",
    .storage = .profile,
    .profile = profile,
});
```

App 覆盖 Profile 的全部调用和 `close`，后者必须由宿主显式执行。一个 Profile 只能用于创建它的 App；`ForeignApp` 在第一次候选分配前拒绝。持久配置要求 `.profile` 与空 `user_data_folder`；临时配置不能同时指定 Profile。远程来源还必须显式设置匹配的 `.credentials = .profile`，并保留独立的 origin、方法、header 和请求扩展授权，选择持久存储不扩大网络权限。

创建先取得 Prepared 的有代数 lease，再调用宿主分配器。失败不发布半个 owner，不留 Stop 节点；原生 manager 一旦构造成功，就永久消费这一 Prepared epoch，即使外层创建最终失败，也不能再用它创建第二个 manager。显式关闭 Prepared 只释放它自己的目录 FD、锁 FD 和元数据，不删除已有数据。每个原生 Profile 自己复制路径并持有同一 open-file-description 的锁 FD 副本，最后 native-only 引用只执行 `close`，不提前 `LOCK_UN`。

## 目录与锁边界

根路径必须绝对、有效 UTF-8、无 NUL；根与生成子路径连同终止 NUL 均须在 4096 字节内，根长度为最长的固定子路径预留空间。逐级用 `O_NOFOLLOW` 打开全部祖先；祖先必须已经存在，仅创建最后一层 root 及固定 `data`、`cache`、Cookie 文件和锁文件。root、data、cache 属于有效 UID 且权限精确为 `0700`；Cookie/锁文件是同 UID、单链接的普通文件，权限精确为 `0600`。在建立子项前取得非阻塞排他 `flock`，占用返回 `ProfileStorageInUse`。没有递归创建、递归删除、自动迁移或隐藏 worker。

宿主保证路径私有，不在存活期间替换或重命名目录/文件。这是协作的应用所有权约束，不是文件系统沙箱。不要把锁可重新取得、C 引用归零或 `Profile.close` 当成 WebKit NetworkProcess/WebProcess 退出、存储 flush 或 fsync 屏障；同进程立即新建 manager 的引擎文件访问边界尚无此保证。应用需要重用目录时，自行建立与实际引擎寿命相符的边界。

## 关闭、重载与恢复

Profile 注册自己的稳定 App Stop 节点。App 封入口并执行全部已接受 posts 后，Stop 只 seal Profile，拒绝新的配置 lease/Context，不等待窗口或引擎退出。正常窗口及 Session 随既有顺序关闭，宿主最后显式 `profile.close()`。某个其它 Stop 正在接管本 Profile 节点时，`close` 返回 `StopInProgress`，不释放对象，之后仍须重试。Profile 的最后一次宿主 allocator free 在 App teardown scope 内，重入关闭窗口不能使 `on_closed` 提前释放仍在使用的宿主状态。

View 配置在第一次 allocator 回调前将公共 Profile 指针转换成 C-only lease，之后不保存可被宿主关闭的 Zig Profile 指针。`Profile.close` 可先于既有 View/Context，旧页继续使用独立的原生引用；晚到 finalizer 不访问 App、Profile、宿主 allocator 或业务回调。全部 WebKit 操作及所保留 GObject 的最后一次 unref 都仍是进程主线程操作，不能把 native-only 存储理解成任意 worker 可访问 WebKit。

首次 `attach`、`attachRegion`、`PageSession.open` 在 API 成功返回前都还是候选：原生准备的临时 allocator 调用，包括最后一次 scratch free，重入关闭 Profile 时返回 `Closed` 并回滚全部候选。原生构造期间可能已经发起请求，这个回滚合同不等于失败前零网络 I/O。

`reload` 在投递前构造新的 Context，完成候选分配/临时清理、核验 Profile 和宿主状态，再一次 admit、投递。投递前的 `Full`、`Closed`、OOM 保留旧 DOM；新旧配置和两个真实 Context 同时计入限额。成功 post 是接受边界，此后 seal/close Profile 不撤销已经 admit 的 Context，包括 `page_changed` completion 重入关闭 Profile。App/Region 关闭仍执行已接受任务一次并释放责任，不复活已关闭宿主。

显式 `recover` 同样提前预留、admit 一个新 Context；普通 borrow 在 seal 后仍返回 `Closed`。它不通过先销毁旧 Context 来腾出槽位，不自动重启或开启 worker。PageSession 的停泊、跨宿主移动不更换 Context、存储或 PageId；真实 document 重载才沿既有代数规则更新。

## 成本与预算

Prepared 默认 16 个逻辑 lease，硬上限 64，默认 32 KiB 元数据、硬上限 1 MiB。lease 不代表引擎的物理引用上限。Profile 默认 16 个 Context、32 个同时配置 lease，硬上限分别 64、256；这些容量不分配大槽表。原生 Context 从构造到其 GObject 实际 finalize 都占槽，逻辑 close 或 `run_dispose` 不提前返还。

Profile 默认 64 KiB、硬上限 1 MiB，统计实际宿主 owner 值、C owner/path 副本和 Context token 请求字节，包括旧、新 Context 同时存活。配置 lease 以计数限额约束，不额外分配 C 对象。`stats` 的 current/peak 与 Context/lease 数各自明确；View 自己的拥有型配置及内联尾部使用 View 的 allocator，不重复计作 Profile 原生元数据。WebKit/GLib 引擎对象、缓存、网络进程和内部 system allocation 不在这份元数据预算内；其 OOM 可能终止进程，不能伪装成调用者 allocator 的可恢复 OOM。Cookie SQLite 配置在第一次 Context/导航前安装，HTTP credential 持久存储保持禁用。

临时 View 不创建 Profile 对象、Profile Stop 节点或配置尾部存储，不增加普通配置分配次数；Options/OwnedConfig 新增 nullable 指针字段是固定元数据成本。持久配置的 ProfileState 内联于已有拥有型配置分配的对齐尾部，没有额外 Zig 堆对象。普通 paint 不读取磁盘、不准备 Profile、不新建 Context。

## 实际验证

`test-profile-storage` 是跨平台纯验证；Linux 显式 `test-profile-storage-files`/`scripts/test-profile-storage.sh` 验实际私有目录、权限/symlink/锁、FD、交接、全部 allocator 故障和 NativeClaim。`test-webkit-profile`/`P01_PROBE=profile-owner` 用 GTK 主线程实际构造 manager/Context，覆盖容量、独立 Context、dispose 与 finalize 区别、晚引用、线程门禁、一次 admit 与永久 claim，末 native requested bytes/ref 为零。

`smoke-webview-profile-linux`/`P01_PROBE=profile-zig` 使用私有 loopback 服务、显式宿主 worker 和顺序 UI 子进程。seed 子进程实际退出后，新子进程首个 HTTP 请求携带原 Cookie，页面读取原 localStorage；临时子进程首请求无该 Cookie，原本禁用的 localStorage 仍为 undefined。这证明本机该关闭/重启序列可恢复，父进程的 `Child.wait` 只证明 UI 子进程退出，不证明其全部引擎后代已经退出或发生 fsync。

同一目标另验两个真实 View 的 Context 不同而 manager 相同、共享存储、全部宿主配置分配故障、post Full 旧页不变、已接受重载在回调中关闭 Profile 后仍完成、接受前 allocator 关闭 Profile 则拒绝且旧页可执行 JS、停泊 Session 和 App Stop。终止测试拥有的 WebProcess 后，显式 recover 已接受再关闭 Profile，仍由预构造 Context 恢复，旧 PageId 被拒绝。wrapper 夹具覆盖注册 Full/OOM、外 App、taken Stop、构造期间 quit、三个首次入口的 alloc/末次 scratch free 撤销，以及 App/Prepared/公共 owner 关闭后原生引用的独立最终释放。测试只使用自有页面/目录，不读取用户 Profile，不建立视觉质量或完整 CookieStore/HTTPS local/原生权限支持的结论。

## 创建期冻结的回环 HTTPS 证书例外

宿主已经运行自己的 HTTPS 服务时，可以明确创建一个带回环证书例外的 Profile：

```zig
const profile = try web.Profile.createWithOptions(allocator, app, &prepared, .{
    .limits = .{},
    .loopback_https = .{ .certificate_pem = public_certificate_pem },
});
try view.attach(window, .{
    .html = "", .storage = .profile, .profile = profile,
    .remote = .{
        .url = "https://127.0.0.1:44321/start",
        .origins = &.{.{ .origin = "https://127.0.0.1:44321", .ipc = true }},
        .credentials = .profile, .allow_insecure_loopback = true,
    },
    .request_policy_extension = .{ .directory = installed_policy_directory },
});
```

`LoopbackHttps` 只接受一个最多16KiB的 certificate-only PEM；host 固定为规范的 `127.0.0.1`。私钥、证书链、额外 PEM block、NUL 及尾随非空内容拒绝；原生 X.509 解析仍可失败。证书来自内存；如需读取文件，由宿主先在自己的 worker 有界读取，主线程不打开证书文件。`createWithOptionsAndFailure` 可接收真正的 errno 或 GLib domain/code，验证、容量和 allocator 错误不会伪造原生失败码。缺少 GIO TLS 后端返回 `TlsBackendUnavailable`，保留对应的真实 GError；不会降级成忽略 TLS 错误。旧 `create`/`createWithFailure` 保持原合同。

例外属于整个 WebsiteDataManager，而非单个 View 或端口。同一 Profile 的所有 Context 共享这份创建期冻结的信任。它允许这个 host 上指定叶证书的 TLS 验证错误，**不是强制 certificate pinning**；另一张正常受信证书仍按系统验证规则通过。TLS 总体策略保持 `FAIL`，不忽略其他证书或 host 的错误。没有动态增加、撤销或轮换接口；需要另一份信任应创建独立 Profile，并遵守原有目录/引擎寿命边界。[WebKit 证书例外 API](https://webkitgtk.org/reference/webkit2gtk/2.40.0/method.WebContext.allow_tls_certificate_for_host.html)

选择该选项同时把整个 manager 的代理策略固定为 `NO_PROXY`；不会修改系统或进程环境代理。每个实际 Context 在发布给 View 前应用同一例外，随后仍必须通过现有请求扩展握手和精确 origin/method/header/IPC 授权，证书信任不代替这些权限。[代理 API](https://webkitgtk.org/reference/webkit2gtk/2.40.0/method.WebsiteDataManager.set_network_proxy_settings.html) Profile seal/close 不撤销已接受 Context 的信任，也不保证引擎已退出；显式 recover 使用同一冻结配置构造新 Context，不自动修复证书或重试失败加载。

地址是服务器真实 HTTPS origin，不改写成 custom scheme。端口属于 origin/localStorage 身份，但 Cookie 仍按 host/path 规则跨端口；随机端口不是 Cookie 隔离或访问认证。服务端的身份、权限、请求/响应体上限、磁盘、连接数量、取消和退出由宿主自己管理。框架不创建服务器、窗口、第二份 Owner、worker 或 TLS 隐藏服务；WebKit、GIO 和 TLS 后端自身仍有系统内部线程和分配成本，不能把框架没有启动 worker 理解为整个 SDK 无线程。

TLS 分支位于独立 noinline 构造函数，使用固定约16KiB的栈捕获；在首次 caller allocator 回调前已独立拥有原 PEM 和 Prepared claim。Profile bytes 的构造峰值包含这份固定 Captured、实际 PEM 副本、对齐和 C metadata；成功后 current 只计算仍持有的本项目请求字节。GLib certificate、TLS 后端及网络进程内部存储不在该计数内。默认创建不进入 Captured 栈帧，也不创建证书对象；原生 owner 增加一个固定的 nullable TLS metadata 指针。晚到引用只保留 C 存储，公共 owner 关闭时撤销证书对象入口，最后 C-only 释放不回访 App/Zig/宿主 allocator。

该接口只为现有 `RemotePage` 增加明确的本地 TLS 例外，不开放 Linux `local_site`、HTTPS 内存资源拦截或文件目录映射。现有 custom `Responder`/`OwnedFileResponse` 不会自动变成 HTTPS 服务器。专用 `test-profile-tls` 仅纯验证，不启动网络；`test-webkit-profile-tls` 与 `smoke-webview-https-linux` 是宿主显式运行的原生检查，测试私钥仅属于公开 fixture 数据，不用于生产服务。

原生夹具将三种拒绝分开验证：默认 Profile 确实使用环境代理；另一个默认 Profile 由测试宿主只设置 `NO_PROXY`，直连后明确返回 `G_TLS_ERROR_BAD_CERTIFICATE`；创建期证书例外对不同证书、`localhost` 仍拒绝。默认直连使用成功授权场景之后新建的 manager，证明此前 Profile 的例外未传播到该 manager，不据此泛化系统 CA 信任。服务器的连接尝试和实际 HTTP handler 计数独立，不能把代理失败当成证书验证证据。另在任何 Context/连接建立前停止测试自有 HTTPS listener，加载明确失败且 HTTP/IPC/代理计数均为零，不退回 HTTP/custom。成功页面另验 `isSecureContext`、真实 HTTPS origin、首请求 Secure/HttpOnly Cookie、两端口 Cookie 查询与 HTTP 携带、端口隔离的 localStorage、请求扩展握手前零请求，以及独立的 origin/method/header/IPC 拒绝。

同一目标覆盖构造 OOM、首次 caller allocator 擦除原 PEM/关闭 Prepared/quit、最后 free 重入；Session 停泊与重挂保留 DOM/PageId，测试自有 WebProcess 终止后显式恢复的 Context 在 Profile seal 后仍完成，旧 PageId 被拒绝。停泊页面在同轮脚本提交后停止，脚本得到一次 `detached`，已接受 post 执行一次；显式测试末尾 drain 只检查晚到 native-only 引用，不是生产关闭中的嵌套循环或引擎 flush 屏障。

本机运行使用 WebKitGTK 2.52.6、libsoup 3.4.4 和 GIO GnuTLS 后端。环境原先缺少 `glib-networking`，原生返回真实 `G_TLS_ERROR_UNAVAILABLE`；测试 runner 用显式 `P01_TLS_ROOT` 将 Ubuntu noble 的 `glib-networking` 2.80.0-1build1 私有依赖叠加到隔离 namespace，不改系统或已固定 SDK。真实 HTTPS 验证需要可用的 GIO TLS 后端，不能用编译通过代替握手；最低 2.40 API 的兼容性来自 SDK/源码合同，未声称在实际 2.40 Runtime 运行。

作者检查中，HTTPS 目标在 Linux Debug/ReleaseSafe、1×/2×四组均实际通过，每组含十四个网络/生命周期模式和两个构造重入场景，末引用为零。独立 native owner 四项测试在 Debug/ReleaseSafe 通过；另在不设置 TLS 依赖 overlay 的旧 Profile/CookieStore/Session 路径执行 ReleaseSafe 2×回归。以上为隐藏窗口集成结果，不建立视觉质量、通用本地 HTTPS 资源映射或全部原生网络权限的结论。

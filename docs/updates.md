# 签名更新与版本发布

`ziggurat_update` 是可选的纯 Zig 模块。它负责签名元数据、发布索引、限长流校验、可续传下载、增量补丁、ZIP 清单核验、版本目录发布、保留与回滚。何时检查、提示界面、退出确认和重新启动的时机由应用决定；模块提供在关闭完成后启动新版本的函数。网络与磁盘操作都会阻塞，应用应放在自行管理的工作线程中，通过 `App.post` 返回结果；模块不创建线程。

## 信任与格式

应用内固定 `Policy`：应用 identity、目标平台、当前四段版本、公钥及元数据和归档上限。`parseAndVerify` 返回拥有字符串存储的 `Verified`，用完调用 `deinit`。不接受未知或重复字段、HTTP URL、带凭据或 fragment 的 URL、错误 identity/target、同版本或降级更新。默认元数据最多 16 KiB，归档最多 256 MiB。

Ed25519 签名绑定 identity、四段版本、target、HTTPS URL、字节数和 SHA-256；签名输入使用固定版本的规范格式。JSON 空白和字段次序不影响签名。版本各段是 `u16`，按数值比较，不实现预发布标签或版本区间。HTTPS URL 不会被模块自动访问。

下载时可把 `stage(manifest, reader, writer)` 接到调用者的传输与临时文件上，使用 16 KiB 缓冲校验精确长度与 SHA-256。失败的 stage 必须丢弃；该函数不安装文件。签名元数据本身不会使网络传输成为非阻塞操作。

## 发布事务

`publication.publishZip(allocator, root, archive, &verified, limits)` 使用应用专用、由应用保护的目录：

```text
root/
  update.lock
  current.json
  releases/<target>-<major.minor.patch.revision>/
  staging/<random>/
```

它先取得非阻塞 OS 文件锁，把调用者的可写归档复制到私有 stage，并在复制时校验签名绑定的长度和摘要；后续只解析该副本。默认最多 128 个文件、512 MiB 展开内容、64 KiB package.json。所有中央目录名称与大小先通过检查才解压。只接受扁平 ASCII 文件名，拒绝路径穿越、分隔符、大小写别名和 Windows 保留设备名。

`package.json` 必须匹配 identity、target、四段版本，列出除自身之外的完整文件集合、大小和 SHA-256，并指定实际存在的 executable。该格式与 `scripts/package.ps1` 一致；额外包元数据可以扩展。归档和清单的哈希都通过后，payload 文件同步落盘，版本目录整体移入 `releases`，最后原子替换 `current.json`。

旧版本目录和用户数据不被覆盖。发布前重新读取当前 marker，阻止旧进程把更新版本覆盖回去。两个更新器竞争返回 `UpdateInProgress`。若进程在版本目录移动后、marker 发布前中断，重试会比较已有目录的完整文件集合和逐字节内容，仅在与新验签 stage 完全相同后复用目录并重试 marker；不一致返回 `ReleaseContentMismatch`。进程被终止可能留下私有 staging 目录，宿主可以在确认没有更新任务时清理；模块不自动删除旧版本。

`readCurrent` 返回受约束的相对路径与版本，供宿主启动器选择版本。marker 所在目录由应用保护，它本身不是抵御本地目录篡改的认证边界。原子文件切换不等于对所有文件系统的断电持久性保证。更新器不会自动终止正在运行的程序，也不覆盖 Windows 正在运行的 EXE。

## 发布索引、增量与密钥轮换

`feed.check(allocator, bytes, policy, installed)` 读取最多 1 MiB 的发布索引 `feed.json`：`releases` 是逐条签名的完整清单，`deltas` 是逐条签名的增量清单。索引本身不签名，客户端只对选中的条目逐一验签；策略的版本下限拒绝重放的旧条目。索引可以扣留新版本，不能让客户端接受伪造版本。它选出本 identity/target 中最新的完整版本；本 target 的条目验签失败时整个检查失败，而不是静默退回较旧版本。返回的清单各自拥有存储，用完调用 `deinit`。

增量清单绑定 identity、target、来源版本与来源归档的大小和 SHA-256、补丁 URL/大小/SHA-256，以及结果归档的大小和 SHA-256。签名输入同样是固定版本的规范格式。只有当前版本、保留的已安装归档摘要和结果摘要都与完整清单一致时才会选中增量；其他构建的同版本来源被跳过而不是报错。`delta.applyVerified` 先按签名校验补丁字节，再从保留归档重建完整归档，复制范围按声明的来源大小检查，结果不超过签名大小，最后比对结果摘要。任何失败都由调用者丢弃输出并下载完整归档。补丁格式是简单的复制/插入指令流，由发布工具在内存中生成；它不是通用二进制差分格式。

`Manifest.endorsement` 支持密钥轮换：受信任的旧密钥对新公钥签署 `ziggurat-key-v1` 声明（绑定 identity），新密钥签署的版本附带该声明，旧客户端据此接受。声明不可链式传递，也不提供吊销；新版本应用把新公钥放进自己的 `Policy`，过渡期可用 `additional_public_keys` 同时信任两把密钥。

## 下载、保留与回滚

`download.fetch(manifest, source, partial, &control)` 把传输写入调用者的部分文件。已有前缀先重新计算摘要再续传；来源不支持续传时从零开始。`Control.cancel` 可在任意线程调用，取消保留部分文件供下次续传；完整但摘要错误的文件会被截断。进度在 worker 上回调，UI 宿主用 `App.post` 转交，`Full` 时丢弃中间值即可。`http.Source` 基于调用者持有的 `std.http.Client`，用 `Range` 续传，200 响应即从头开始；HTTPS 证书使用该客户端的系统 CA，请求走系统代理（见 [net.md](net.md) “系统代理”），客户端自己设置了代理时保留其设置。`http.get` 读取有上限的小文档，如发布索引。模块不创建线程。

`publishZip` 的 `retain_archive` 把验证过的归档保留为 `archives/<release>.zip`，供下一次增量使用。`retention.currentArchive` 打开并重新计算当前版本保留归档的摘要。`retention.rollback` 在更新锁内逐个文件对照该版本的 package.json 重新校验，再原子切换 `current.json`；回滚是宿主的明确决定，之后的检查仍会提供较新版本，是否跳过由宿主决定。`retention.prune(keep)` 删除最新 `keep` 个之外的旧版本及其归档，当前版本和比它新的版本始终保留；旧版本可能仍在运行时不要清理。

`launch.currentExecutable` 解析当前版本可执行文件的绝对路径。`launch.spawnDetached` 在 `App.run` 返回、旧进程的窗口和回调都结束之后启动新版本：先用 `requestQuit` 走正常的退出否决，再在关闭完成后启动，更新器自身不终止任何进程。

## 更新窗口

可选的 `ziggurat_updater` 模块是应用的更新提示窗口：后台按 `interval`（默认一天，启动后 `first_check_delay` 秒先查一次）检查新版本，发现后显示版本、更新说明，提供“安装更新”“跳过此版本”“稍后提醒”和“以后自动安装”的复选框；安装时显示可取消的下载进度，完成后提供重新启动。用户从菜单（`menuLabel` 给出“检查更新…”）调用 `checkForUpdates` 时窗口立即出现，并报告已是最新、检查失败或此构建无法自行更新。网络与磁盘工作由 `Backend` 完成，`FeedBackend` 使用本模块的签名发布索引；用户的选择保存在 `state_dir` 的 updater.json。

- 文字跟随 `locale`：内置英语、简体与繁体中文、荷兰语、法语、德语、意大利语、日语、韩语、波兰语、葡萄牙语（pt-BR）、俄语、西班牙语、土耳其语和乌克兰语；只为一个地区提供的语言（如 pt-BR）也用于同语言的其他地区。`languages` 覆盖内置文字或增加语言。
- 更新说明按 Markdown 显示（标题、列表、强调、代码、引用、链接），无法解析时按纯文本换行显示，超过 16 KiB 在行尾截断。链接经 `open_link` 交给宿主打开，未设置时不响应。
- `icon` 是宿主已上传的应用图标，显示在文字左侧 64 DIP，窗口相应加宽。
- 后台检查发现新版本时，像 Sparkle 的更新提示那样显示窗口：应用正处于激活状态或用户主动检查时窗口在前并获得键盘，否则显示但不从其他应用夺走键盘（`WindowOptions.focus_on_show = false`）。
- 检查或安装失败时，错误详情完整换行显示在说明下方，不截断、不用遮住标题的提示框。
- `availableVersion()` 是上次检查发现的新版本，没有时为空：检查前、检查失败或已是最新、此构建无法自行更新，以及用户跳过的版本（用户主动检查时除外）都为空；已下载等待重启的更新保留其版本直到应用重新启动。它复用已有的检查结果，不另发请求；变化时与上次检查时间一起经 `on_change` 在主线程通知一次，应用的更新角标、设置页或重启提示据此重新读取。

### 预发布版（beta 通道）

`release --prerelease` 把该版本记作预发布版：静态目录里多一个 `<identity>-<version>.prerelease` 标记，重建的 `feed.json` 在 `prereleases` 中列出它。默认的检查跳过这些版本，`feed.checkChannel(..., .{ .prereleases = true })` 才会选中。更新窗口里由 `Updater.setPrereleases(true)` 为选择了 beta 的用户打开，下一次检查起生效；关闭后不会降级，直到有比当前预发布版更新的正式版才再次更新。这个选择只在本次运行内有效，应用自己保存（例如在设置里）并在启动时设置。命令行的 `check` 与 `fetch` 以 `--prereleases` 打开。

### 应用自己的更新源

有自己更新服务、需要用户凭据的接口或运行时切换通道的应用，可以给 `FeedBackend` 一个 `UpdateSource`（`Config.source`，或运行时 `FeedBackend.setSource`，传 null 恢复 `Config.feed`）：`feed(context, allocator, prereleases)` 返回发布索引（`release` 写出的 feed.json，至多 1 MiB），`files` 是下载归档与补丁的 `download.Source`，按索引里的 URL 取文件。两者都在后台工作线程上调用。来源只替换传输：解析与上限、大小、对构建内公钥的签名校验、暂存与发布都与默认索引相同，未用该公钥签名的版本或补丁被拒绝，应用保持原样。一次安装沿用找到该版本的那次检查的来源与通道。

默认的 HTTP 传输以固定的 `ziggurat-updater` 作为 User-Agent，不带应用名：有的发布主机对含非 ASCII 字节的 User-Agent 返回 400。

## 命令行工具

```powershell
zig build update-tool -Doptimize=ReleaseSafe
zig-out/bin/ziggurat-update.exe --help
```

```text
ziggurat-update keygen PRIVATE_SEED_FILE PUBLIC_KEY_FILE
ziggurat-update sign ZIP MANIFEST PRIVATE_SEED_FILE ID TARGET 1.2.3.0 HTTPS_URL [ENDORSEMENT]
ziggurat-update verify MANIFEST PUBLIC_KEY_FILE ID TARGET 1.2.2.0
ziggurat-update publish MANIFEST PUBLIC_KEY_FILE ID TARGET 1.2.2.0 ZIP ROOT
ziggurat-update current ROOT ID TARGET
ziggurat-update pack OUTPUT_ZIP NAME ID TARGET VERSION EXECUTABLE FILE...
ziggurat-update endorse TRUSTED_SEED_FILE NEW_PUBLIC_KEY_FILE ID ENDORSEMENT
ziggurat-update release DIR ID TARGET VERSION ZIP PRIVATE_SEED_FILE BASE_HTTPS_URL [--endorsement FILE] [--notes FILE] [--prerelease] [--from OLD_ZIP OLD_VERSION]...
ziggurat-update check FEED PUBLIC_KEY_FILE ID TARGET ROOT [--prereleases]
ziggurat-update fetch FEED PUBLIC_KEY_FILE ID TARGET ROOT [--prereleases]
ziggurat-update rollback ROOT ID TARGET VERSION
ziggurat-update prune ROOT ID TARGET KEEP
```

私钥输入是含 32 个原始字节的 seed 文件，不放到命令行参数或分发包中；公钥文件同样是 32 个原始字节。`keygen` 独占创建文件；POSIX 私钥权限为 0600，Windows 使用调用者目录继承的 ACL，签名目录应预先受到保护。`sign` 不覆盖已有清单。

`pack` 在任何平台生成更新包：排序的存储式 ZIP、固定时间戳和 package.json 清单，同一组输入得到同一字节。`release` 把完整归档、签名清单、对每个 `--from` 生成的补丁及其签名清单写入静态发布目录，再从目录中该 identity 的全部清单重建 `feed.json`。Ed25519 签名是确定性的，同样输入重跑不会改变已有文件；同名但内容不同的资产返回 `AssetConflict`，不覆盖。补丁不足完整归档 90% 时才会生成。上传由发布者用自己的凭据把该目录同步到任意静态 HTTPS 主机；本工具不保存或读取任何上传凭据。

`check` 和 `fetch` 接受 https:// 索引或本地文件。`fetch` 优先下载增量并从保留归档重建，失败时回退完整归档，然后发布并保留归档。

不要从更新服务器下载公钥后直接信任它；应用的公钥来自受信任的初始分发。此模块不提供密钥吊销或自动回滚策略。

## 验证

`zig build test` 覆盖签名字段篡改、目标/版本/容量、流短读/超长/摘要失败、所有分配失败位置、实际文件锁、ZIP 路径与清单拒绝、原子 marker 之前的中断恢复，以及 staging 清理。新增部分覆盖补丁对平移/修改/截断/无关输入的重建与畸形补丁拒绝；增量清单对来源、结果和轮换密钥的绑定，伪造或错 identity 的背书；索引选择、条目篡改与结果不一致的拒绝及全部分配失败；取消后续传、短响应续传、无 Range 重来、前缀损坏与超长；本机回环 HTTP 服务上的 Range 与 200 两种响应；以及从安装、增量升级（损坏补丁回退）、完整升级、回滚（篡改阻止）到清理的完整流程。这些测试不访问外部网络。

Windows 上执行 `tests/update_package_smoke.ps1`，会临时生成密钥和仅用于测试的许可文本，调用真实 packager 生成 deflate ZIP，签名、验证并发布它，再运行新版本目录中的工具程序。它还检查错误目标、降级、元数据/归档篡改、重复发布、原程序与用户数据不变，最后删除精确的测试临时目录。测试文本不授予项目许可证。

# 签名更新与版本发布

`ziggurat_update` 是可选的纯 Zig 模块。它负责签名元数据、限长流校验、ZIP 清单核验和版本目录发布。网络请求、界面、退出确认、重新启动和旧版本保留由应用负责。磁盘操作会阻塞，应用应放在自行管理的工作线程中，通过 `App.post` 返回结果。

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

## 命令行工具

```powershell
zig build update-tool -Doptimize=ReleaseSafe
zig-out/bin/ziggurat-update.exe --help
```

工具提供 `keygen`、`sign`、`verify`、`publish` 和 `current`。私钥输入是含 32 个原始字节的 seed 文件，不放到命令行参数或分发包中；公钥文件同样是 32 个原始字节。`keygen` 独占创建文件；POSIX 私钥权限为 0600，Windows 使用调用者目录继承的 ACL，签名目录应预先受到保护。`sign` 不覆盖已有清单。

```text
ziggurat-update keygen PRIVATE_SEED_FILE PUBLIC_KEY_FILE
ziggurat-update sign ZIP MANIFEST PRIVATE_SEED_FILE ID TARGET 1.2.3.0 HTTPS_URL
ziggurat-update verify MANIFEST PUBLIC_KEY_FILE ID TARGET 1.2.2.0
ziggurat-update publish MANIFEST PUBLIC_KEY_FILE ID TARGET 1.2.2.0 ZIP ROOT
ziggurat-update current ROOT ID TARGET
```

不要从更新服务器下载公钥后直接信任它；应用的公钥来自受信任的初始分发。此模块不提供密钥轮换协议、增量补丁或自动回滚策略。

## 验证

`zig build test` 覆盖签名字段篡改、目标/版本/容量、流短读/超长/摘要失败、所有分配失败位置、实际文件锁、ZIP 路径与清单拒绝、原子 marker 之前的中断恢复，以及 staging 清理。

Windows 上执行 `tests/update_package_smoke.ps1`，会临时生成密钥和仅用于测试的许可文本，调用真实 packager 生成 deflate ZIP，签名、验证并发布它，再运行新版本目录中的工具程序。它还检查错误目标、降级、元数据/归档篡改、重复发布、原程序与用户数据不变，最后删除精确的测试临时目录。测试文本不授予项目许可证。

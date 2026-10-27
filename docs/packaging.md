# Windows 资源与打包

`build_support/packaging.zig` 的 `addWindowsResources` 把显式 Metadata 与 ICO 转成清单、VERSIONINFO 和图标资源，由 Zig 自带资源编译器参与构建。每个可执行文件有独立的生成目录，构建结果依赖实际输入文件。

应用提供 assembly identity、显示名称、四段版本和 ICO（或由 PNG 在构建时生成的 ICO，见 [ziggurat 命令](cli.md#图标)）。`Metadata.language` 是名称与描述所用语言的 BCP 47 标签（默认 `en-US`），`translations` 给出其他语言的名称与描述：版本资源为每种语言写一张以“语言 ID + 代码页 1200”为键的字符串表（如 `080404B0`），`Translation` 列出全部语言，Windows 文件属性按系统语言显示，没有时显示应用自己的语言。语言 ID 依次按“语言-地区”“语言-文字”“语言”查表，不带文字的中文按地区区分简繁；Windows 没有 ID 的语言与重复的 ID 被跳过并在构建时警告。清单声明 UTF-8 活动代码页。可选描述、公司名称与版权不填虚构值。清单使用 `asInvoker`、PerMonitorV2、长路径支持和 Windows 10 兼容声明；版本资源与清单使用同一个版本来源。XML 和 RC 分别校验与转义，RC 引号采用双写语法。资源 ID 为图标 `101`、清单 `1`、版本 `1`。

默认图标含九种尺寸，PNG RGBA 图像共 4,181 字节。`assets/generate-icon.ps1` 从确定的几何生成图像；正式构建直接消费已保存 ICO。应用可以替换 ICO，无需修改原生窗口实现。

`AppOptions.icon_policy` 有三个值：`automatic` 在资源不存在时使用系统默认；`disabled` 不加载图标；`required` 将缺失资源作为初始化错误。其他图标加载失败不会静默忽略。类图标由 App 持有到注销类之后，每个窗口另持有一对图标；DPI 重载先安装新句柄，再销毁旧句柄。

Ziggurat 使用仓库根目录的 MIT `LICENSE`；Zig 源码包与构建安装文件都包含它。打包本仓库示例时显式选择该文件：

```powershell
pwsh -NoProfile -File scripts/package.ps1 -Name MyTool `
  -ExecutablePath zig-out/bin/counter.exe -LicensePath LICENSE
```

`-WebView` 额外收集同目录 Loader 与 SDK 许可证，也可显式指定路径。脚本检查 PE 架构、嵌入版本与清单的一致性，生成排序且时间戳固定的 ZIP、文件大小/SHA-256 清单和归档 SHA-256。原生包不加入 WebView 依赖；WebView 包准确标明系统 Runtime 未包含。脚本不会自动安装 Runtime。

通用脚本继续要求 `-LicensePath`，下游应用应传入自己的许可文件；框架的 MIT 选择不会替应用选择许可证。包内文件名为 `LICENSE.txt`，正文保留输入文件的完整字节。隔离测试仍可传入标明用途的 fixture；CI 中本仓库的打包与签名检查使用正式 LICENSE。打包的确定性指同一组输入在同一工具环境重复产生相同归档，不保证不同编译器或压缩库版本的二进制一致。

`zig build smoke-packaging` 检查实际 EXE 的清单（含 UTF-8 代码页）、Unicode/引号/反斜杠版本文本、第二种语言的字符串表、由 `assets/application.png` 在构建时生成的七尺寸图标，以及 1000 次图标重载后的 USER/GDI 计数。`tests/packaging.ps1` 检查 ZIP 排序、文件清单与哈希、许可依赖和版本不一致拒绝路径。

## Authenticode 签名

`sign-package.ps1` 接受 CurrentUser/My 中的证书指纹，或显式 PFX 与 SecureString 密码。它复制原始 EXE 到独占临时目录，签署副本、核验签名与信任，再调用同一 packager；原始编译产物保持不变。签名报告记录实际 signer、信任结果与签名前后 SHA-256，包内清单描述签署后的 EXE。

```powershell
./scripts/sign-package.ps1 -Name Tool -ExecutablePath zig-out/bin/counter.exe `
  -LicensePath path/to/application-license.txt -CertificateThumbprint CERTIFICATE_THUMBPRINT
```

可用 `-TimestampServer` 显式选择 HTTPS 时间戳服务。默认必须通过系统信任验证；签名不能赋予程序未获得的分发许可。`-AllowUntrustedTestCertificate` 只用于测试，精确接受未受信任根的测试证书并把报告标记为 test_only，不把其他签名错误当成成功，不修改受信任根存储。

`tests/signing.ps1` 实际生成一天有效的测试代码签名证书，验证 store/PFX 两条路径、严格生产拒绝、ZIP 中的签名与摘要、修改映射代码后的 HashMismatch，以及原文件不变；finally 删除该测试证书和临时私钥。更新通道的 Ed25519 签名属于另一层，见 [更新模块](updates.md)。

## 安装程序、启动器与卸载

`zig build setup-stub` 生成 `ziggurat-setup`，它按自身内容决定角色。`ziggurat package setup --zip PACKAGE` 把更新包、安装配置和带 SHA-256 的尾部追加到存根之后，得到一个单文件安装程序；Windows 产物应在追加后再做 Authenticode 签名，存根按 PE 证书目录跳过证书表（单元测试使用构造的 PE 头，尚未用真实签名的安装程序验证）。追加的摘要只用于拒绝截断或损坏，真实性来自代码签名。

```text
SETUP [--silent] [--scope user|machine] [--dir PATH]
uninstall [--silent] [--purge]
```

| | 用户范围（默认） | 机器范围 |
| --- | --- | --- |
| Windows 根目录 | `%LOCALAPPDATA%\Programs\<identity>` | `%ProgramFiles%\<identity>`，需管理员 |
| Windows 集成 | 开始菜单快捷方式、HKCU 卸载项 | ProgramData 开始菜单、HKLM 卸载项 |
| Linux 根目录 | `$XDG_DATA_HOME/<identity>/install` | `/opt/<identity>`，需 root |
| Linux 集成 | `applications/<identity>.desktop`、可选 hicolor 图标、`~/.local/bin` 链接 | `/usr/share` 与 `/usr/local/bin` |

安装复用更新发布事务：包内容先复制到私有 stage 并校验摘要与清单，再原子切换 `current.json`，并保留归档供以后的增量更新。根目录同时放入启动器（存根副本，以应用可执行文件命名）、`uninstall` 和 `install.json`。启动器读取 `current.json` 启动当前版本并转发参数：Linux 直接替换进程，Windows 分离启动后立即退出，以免占用自身文件。同版本重新运行等于修复启动器和集成；更旧版本返回 `NewerVersionInstalled`；首次安装失败会删除根目录和已写的集成，升级在发布后失败会回滚到原版本。卸载删除集成和根目录，保留 `LOCALAPPDATA`（Linux 为 `$XDG_DATA_HOME`）下 `<identity>` 的用户数据，`--purge` 一并删除（Windows 还删除 `APPDATA\<identity>`）。Windows 卸载器先把自己复制到 `%TEMP%`，等原进程退出后再删除安装目录，临时副本在允许时登记为重启后删除。

用户范围安装的目录由当前用户写入，应用内更新可以直接发布到该根目录。机器范围和 deb 安装的目录对普通用户只读，应通过新的安装程序或系统包管理器升级。安装程序是命令行程序，没有图形向导，不关闭正在运行的应用。启动器带有存根自己的资源（Windows 图标与版本信息），快捷方式图标因此也来自存根。文件关联不在本工具内注册。

`tests/setup_smoke.sh`（Linux）和 `tests/setup_smoke.ps1`（Windows）在私有 HOME 或重定向的 `LOCALAPPDATA`/`APPDATA` 中用真实安装程序完成安装、经启动器运行并检查参数、升级、拒绝降级、卸载保留用户数据和 `--purge`。Windows 脚本另检查 HKCU 卸载项和快捷方式目标，唯一的共享状态是测试 identity 的卸载项，结束时再次删除。

## Debian 包

`ziggurat package deb --zip PACKAGE --maintainer "NAME <EMAIL>"` 写出 Linux 更新包对应的 `.deb`：文件位于 `/usr/lib/<executable>/`，`/usr/bin/<executable>` 是相对链接，另有 desktop 条目、`/usr/share/doc/<executable>/copyright`（来自包内 LICENSE.txt）和可选 `--icon` PNG。控制文件包含 Installed-Size 与 md5sums；默认依赖 GTK 3 与 Pango，`--webview` 加入 WebKitGTK 4.1 与 libsoup 3，`--depends` 可完全替换。postinst/postrm 在工具存在时刷新菜单与图标缓存，失败不阻止安装。成员是未压缩的 tar，时间戳取 `SOURCE_DATE_EPOCH`（默认 0），同样输入得到同样字节。包未签名；仓库签名属于发布者的 APT 仓库配置。Linux 冒烟检查用 `dpkg-deb` 核对控制信息与内容，在有无密码 root 的环境中再实际安装、运行并移除。

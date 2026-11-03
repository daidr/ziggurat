# ziggurat 命令

`zig build cli` 生成 `ziggurat` 和同目录的安装存根 `ziggurat-setup`。命令只调用本机 `zig`（可用 `ZIG` 指定），不下载任何依赖。

```text
ziggurat init DIR [--template native|web|hybrid] [--name NAME] [--id IDENTITY] [--framework PATH]
ziggurat dev [--watch DIR]... [--frontend COMMAND] [-- ZIG_BUILD_ARGS...]
ziggurat build [--debug] [--target TRIPLE | --platform LIST] [--package] [--sign IDENTITY] [--skip-dmg] [--skip-notarize] [-- ZIG_BUILD_ARGS...]
ziggurat package setup|deb|pkgbuild|app|install-script|install-ps1 --zip PACKAGE ...
ziggurat publish DIR (--github OWNER/REPO --tag TAG ... | --s3 BUCKET --url BASE ...)
ziggurat generate [-o FILE] [--framework PATH] [DIR]
ziggurat i18n check [DIR]
ziggurat install-skills [DIR]
ziggurat icon PNG [-o FILE]
ziggurat sign FILE...
ziggurat vet [DIR]
ziggurat doctor [--webview]
```

## init

在空目录中生成 `build.zig`、`build.zig.zon`、`src/main.zig`、`.gitignore` 和 `ziggurat.json`。依赖以相对路径指向本框架检出（默认是构建 CLI 的那份源码），`build.zig.zon` 的 fingerprint 按 Zig 0.17.0 规则由包名生成。三种模板：

- `native`：声明式视图计数器，用到 `ziggurat` 与 `ziggurat_view`。
- `web`：WebView 页面和嵌入的 `src/index.html`，页面与 Zig 通过同一套 `window.chrome.webview` 消息往返；Linux 在启动前由 worker 准备私有 Profile 目录。
- `hybrid`：同一状态驱动一个原生视图窗口和一个页面窗口，任一侧的操作同步到另一侧。

项目同时带上 `.agents/skills` 中的代理技能（见 [install-skills](#install-skills)）。三种模板的应用模块都导入 `ziggurat_i18n`，供生成的消息访问器使用。

生成的 `build.zig` 调用本框架 `build.zig` 公开的 `addApplicationResources`，在 Windows 上嵌入清单、版本与图标资源。名称只接受不含引号、尖括号、`&`、`@` 和反斜杠的文本，identity 只接受 ASCII 字母、数字、点、下划线与连字符。

## dev

先运行 `zig build`，成功后把安装出的可执行文件作为自己的子进程启动。每 300 ms 比较 `src/`、`build.zig`、`build.zig.zon` 与 `--watch` 目录中文件的路径、大小和修改时间（跳过点目录、`zig-out` 和 `node_modules`）；变化时终止应用并重新构建，构建失败则等待下一次变化。`--frontend` 用系统 shell 启动前端监视命令，退出时一并结束。轮询只发生在开发命令中，与应用的空闲路径无关。

## build

以 ReleaseSafe（`--debug` 时为 Debug）运行 `zig build`。`--package` 读取 `ziggurat.json`，把 `zig-out/bin` 中的可执行文件、Windows 上存在的 `WebView2Loader.dll`、项目根的 LICENSE 和 `icon` 指定的 PNG（包内名为 `icon.png`）打成 `dist/<identity>-<os>-<arch>-<version>.zip`，并打印其 SHA-256。该包可直接交给 `ziggurat-update release` 签名发布，或交给 `ziggurat package` 生成安装程序、deb 与 PKGBUILD，见 [打包](packaging.md) 和 [更新](updates.md)。打包确定性只针对同一组输入与工具环境；编译产物本身是否逐字节一致取决于 Zig 编译器。

`--platform` 接受逗号分隔的 `OS/ARCH` 列表，依次构建到 `zig-out/<os>-<arch>`：OS 为 `macos`、`linux`、`windows`（`darwin` 同 `macos`），ARCH 为 `x86_64`、`aarch64`（`amd64`、`arm64` 亦可），另有 `macos/universal`。与本机相同的平台不传 `-Dtarget`，保留本机系统库；其他平台传 `-Dtarget=<arch>-<os>`（Linux 加 `-gnu`）。`macos/universal` 先分别构建 `aarch64` 与 `x86_64`，再把两个 Mach-O 合成一个通用可执行文件（CLI 自己写 fat 头，各切片按 16 KiB 对齐，与 lipo 相同，不需要 Xcode）。与 `--target` 互斥；`--package` 为每个平台各写一个更新包。

目标是 macOS 时（`--platform` 中的 macOS 平台，或 `--target`/本机为 macOS），`build` 还会读取 `ziggurat.json`，在 `dist/macos-<arch>/` 写出签名的 `<名称>.app`，并在 Mac 上写出磁盘映像 `<可执行文件>-<版本>-<arch>.dmg`（通用应用为 `<可执行文件>-<版本>.dmg`）；`--skip-dmg` 不做映像，其他系统上跳过映像并提示。签名身份取 `--sign`，否则 `macos.signingIdentity`，默认 `-`（ad hoc）。配置了 `macos.notarize` 时映像会提交公证，`--skip-notarize` 跳过。公证要求 Developer ID 身份、`provisioningProfile` 要求非 ad hoc 身份，两者在开始构建前检查。详见 [macOS 应用包](packaging.md#macos-应用包签名与磁盘映像)。

## package app

`ziggurat package app --zip PACKAGE` 把 macOS 更新包（`macos-aarch64`、`macos-x86_64` 或 `macos-universal`）里的可执行文件写成 `dist/<target>/<名称>.app`（`--output DIR` 可改）并签名，`--dmg` 再写磁盘映像（只在 Mac 上，公证规则同 `build`，`--skip-notarize` 跳过）。当前目录的 `ziggurat.json` 提供图标、签名与 Info.plist 配置，其 identity 必须与包一致；没有该文件时只按包的清单命名应用、ad hoc 签名。

## package install-script

`ziggurat package install-script --zip PACKAGE` 为 Linux 或 macOS 更新包写出 `dist/install.sh`（`--output` 可改），同一个脚本在两种系统上都能用。Linux 上脚本不需要 root 或包管理器：它运行应用的安装程序（`package setup` 的产物，名为 `<可执行文件>-<版本>-<target>-setup`），以用户范围安装到 `$XDG_DATA_HOME/<identity>/install`，并写入菜单条目和 `~/.local/bin` 中的命令，之后应用可以自行更新。

```text
sh install.sh [SETUP]      # 运行给定的安装程序，否则运行脚本旁同版本的安装程序，否则下载最新的
sh install.sh --uninstall  # 运行已安装的 uninstall，保留设置与用户数据
curl -fsSL https://github.com/OWNER/REPO/releases/latest/download/install.sh | sh
```

- `--github OWNER/REPO`：从 GitHub API 列出发布（每页 100 个，最多 10 页），取最新的、非草稿非预发布、标签以 `--tag-prefix` 开头的发布中名为 `<可执行文件>-…-linux-<arch>-setup` 的资产。
- `--url BASE`：从 `BASE<可执行文件>-<版本>-linux-<arch>-setup` 下载，版本即生成脚本的包版本，所以每次发布都要重新上传脚本（S3 发布给 install.sh 加 `Cache-Control: no-cache`）。
- `--webview`：安装后用 ldconfig 检查 WebKitGTK 4.1，缺少时提示按发行版安装的命令；无法判断时（没有 ldconfig 或缓存）不提示。

脚本在 Linux 上拒绝 root 运行，按 `uname -m` 选择 `linux-x86_64` 或 `linux-aarch64`，下载用 curl，没有时用 wget。安装程序自己校验内容摘要；脚本只负责找到并运行它。

macOS 上脚本安装磁盘映像中的应用：给定的映像，否则脚本旁的 `<可执行文件>-<版本>-<arch>.dmg` 或通用的 `<可执行文件>-<版本>.dmg`，否则下载（`--github` 时取最新合格发布中本架构的映像，没有则取同一发布的通用映像；`--url` 时先试本架构的文件名再试通用的）。Rosetta 下的 shell 也按 Apple 芯片选择。它以 `osascript` 请应用退出，10 秒后仍在运行就结束包内进程；把应用先复制到目标目录中的临时名再替换旧版本，目标是已安装的位置，否则可写时为 `/Applications`，再否则 `~/Applications`；最后打开应用。curl 下载的文件没有隔离属性，所以不会出现 Gatekeeper 的“从互联网下载”提示；应用仍须签名（分发给其他 Mac 时须公证）。`--uninstall` 先请应用退出再删除应用包，不动设置与数据。测试用 `<可执行文件大写>_INSTALL_DIR` 指定目录，`<可执行文件大写>_NO_OPEN=1` 不打开应用。

单元测试用假安装程序、假 curl 和假 API 响应检查 Linux 的三条来源与卸载，并用假的 `uname`/`hdiutil`/`osascript` 检查 macOS 分支（Rosetta 识别、通用映像回退、先退出旧应用、替换与卸载）；Linux 上另用真实的 `package setup` 产物在私有 HOME 中完成了安装与卸载，macOS runner 上用真实映像安装与卸载（见 [打包](packaging.md#macos-应用包签名与磁盘映像)）。

## package install-ps1

`ziggurat package install-ps1 --zip PACKAGE` 为 Windows 更新包写出 `dist/install.ps1`：

```powershell
irm https://github.com/OWNER/REPO/releases/latest/download/install.ps1 | iex
```

脚本在 Windows PowerShell 5.1 与 PowerShell 7 中运行，内容全为 ASCII（5.1 把 GitHub 不带字符集的下载按 Latin-1 解码，非 ASCII 字符写成 `[char]` 码）。它按处理器架构（x64 PowerShell 跑在 Arm 电脑上时按 Arm）选择 `<可执行文件>-…-windows-<arch>-setup.exe`：`--github` 从最新的合格发布中查找，`--url` 用生成时的版本拼出文件名。同一发布有 `SHA256SUMS` 时，安装程序必须列在其中且 SHA-256 一致，否则不安装。安装位置取 HKCU 卸载项的 `InstallLocation`，没有时为 `%LOCALAPPDATA%\Programs\<identity>`（设了 `windows.installDirName` 时用它）；若应用正在从该目录运行，先请窗口关闭，10 秒后结束仍在运行的进程；然后以 `--silent --scope user --dir` 运行安装程序并打开应用。测试用 `$env:<可执行文件大写>_DOWNLOAD_URL` 与 `_NO_OPEN`。Windows CI 用真实安装程序与本机 HTTP 服务在 5.1 和 7 中各安装一次，并检查错误摘要被拒绝。

## publish

`ziggurat publish DIR` 上传 `ziggurat-update release` 写出的发布目录（以及安装程序、install.sh）。先传归档、补丁与安装程序，再传签名清单，最后传 `feed.json`，任何时刻读到的索引都不会指向尚未上传的文件；每个清单的 URL 必须在本次发布之下且指向目录中的文件，否则在上传前失败。

- `--github OWNER/REPO --tag TAG [--notes FILE] [--not-latest]`：用 GitHub CLI（`GH` 可指定）上传，发布不存在时创建草稿，全部平台上传后再手动发布。
- `--s3 BUCKET --url BASE [--prefix DIR] [--region REGION] [--endpoint URL] [--path-style]`：每个文件一次 AWS Signature Version 4 签名的 PUT，凭据只从 `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY` 与可选的 `AWS_SESSION_TOKEN` 读取，不写入任何文件。`BASE` 是该前缀对外提供的地址，以 `/` 结尾，用于检查清单。区域默认取 `AWS_REGION`、`AWS_DEFAULT_REGION`，再默认 `us-east-1`；`--endpoint` 指向 Cloudflare R2 等兼容服务（只能是服务地址，不含路径），此时以及桶名含点时默认路径式寻址。`feed.json` 与 `install.sh` 带 `Cache-Control: no-cache`，文件按扩展名设置类型（`.sh` 为 `text/plain`，便于在浏览器中先查看）。不跟随重定向；失败时显示服务返回的 XML 错误码与消息，桶在其他区域时提示 `--region`。`HTTPS_PROXY` 等代理变量照常生效。

签名用文档公开的 S3 示例向量检查，上传与错误解析用本机 HTTP 服务检查；没有对真实 AWS 或 R2 账号做上传。

## generate

`ziggurat generate [DIR]` 读取项目的 `ziggurat.json`：

```json
{
  "i18n": { "dir": "src/locales", "source": "en" },
  "bindings": "web/src/client.ts",
  "service": "src/service.zig"
}
```

先处理 `i18n`（缺省 `dir` 为 `src/locales`，`source` 为 `en`）：检查目录中的消息目录（同 `i18n check`，有错误时列出并失败），然后写出两份访问器，内容未变时不改写文件：

- `<dir>/catalog.zig`：`source`、`languages`、按语言排列的 `bundles`（编译期校验每条消息），`catalog(allocator)` 生成借用这些消息的 `i18n.Catalog`，`Messages.in(&localizer)` 为每个键提供一个带类型参数、写入 `*std.Io.Writer` 的函数。目录放在 `src/` 下，应用即可 `@import("locales/catalog.zig")`。
- 有 `bindings` 时，客户端旁的 `<dir 的名字>.ts`（如 `web/src/locales.ts`）：所有语言的消息随页面打包，首帧即为正确语言；由 `@ziggurat/runtime/i18n` 的 `createCatalog` 格式化，导出 `messages`、`messagesIn(locale)` 与 `languages`，`Messages` 接口为每个键给出类型化方法。

然后有 `bindings` 时生成 IPC 客户端：在框架检出（默认是构建 CLI 的那份，`--framework` 可改）中运行 `zig build ipc-client -Dipc-service=<service>`，把产生的 TypeScript 客户端写到 `bindings`；`-o FILE` 覆盖 `bindings`。服务文件只能导入 `ziggurat_ipc` 与 `ziggurat_resource_stream`。

消息目录是 `<tag>.json`，以规范形式的 BCP 47 标签命名（`en.json`、`zh-Hant.json`），伪 locale（`en-XA`、`ar-XB`）不能有文件。键以字母开头，只含字母、数字与 `_`，成为访问器的名字；与生成代码自身声明重名的键被拒绝。source 文件中 `@key` 描述消息：`description` 进入两侧的文档注释，`placeholders` 按顺序声明参数与类型（`String`、`int`、`double`、`num`、`DateTime`、`Object`，对应 Zig 的 `[]const u8`、`i64`、`f64`、`f64`、`i18n.Instant`、`i18n.Value`）。未声明的参数按用法推断：plural、selectordinal 与 number 为 int，date 与 time 为 DateTime，其他为 String。`@@locale` 必须与文件名一致，其他 `@@` 属性忽略。

## i18n check

`ziggurat i18n check [DIR]` 列出消息目录的问题，带文件与行号。错误：文件名不规范、JSON 无效、重复键、非字符串值、消息语法错误、非法键、声明类型与用法不符、译文用了 source 消息没有的参数或类型不符、译文中有 source 没有的键。警告：译文缺少的消息（显示时回退到 source）、译文没有用到的参数、声明但未用的占位符、没有消息的描述，以及 plural/selectordinal 中该语言规则不会选中的类别或缺少的类别（缺少的类别显示 other 分支）。有错误时退出码为 1，警告不影响退出码。语言的类别集由 `ziggurat_i18n` 的复数规则取样得到（`plural.cardinalCategories`、`plural.ordinalCategories`），参数与分支由 `message.visit` 读出。

## install-skills

`ziggurat install-skills [DIR]` 把随 CLI 打包的代理技能写入 `DIR/.agents/skills`（目前是 `ziggurat-maintenance`：所有权、生命周期、主线程、声明式视图、消息目录与验证规则）。只替换打包的文件，保留其他技能和技能目录中的其他文件。

## 图标

`ziggurat.json` 的 `icon` 是一张正方形 PNG（最好 1024×1024）。`build --package` 检查它是正方形 PNG 后放进更新包，`package setup` 与 `package deb` 在没有 `--icon` 时用包里的 `icon.png` 作 Linux 菜单图标。Windows 可执行文件的图标由应用的 `build.zig` 嵌入：

```zig
ziggurat_build.addApplicationResourcesWithIcon(b, exe, ziggurat, metadata, .{ .png = b.path("icon.png") });
```

构建时一个为本机编译的小工具把 PNG 缩放到 16、24、32、48、64、128、256 像素并写成 PNG 载荷的 `.ico`：缩小按面积平均，放大按双线性采样，都在预乘颜色上进行，透明像素不会把边缘变暗。`.ico = ...` 直接用现成的 ICO，`.default` 是框架自带图标。`ziggurat icon PNG [-o FILE]` 单独生成同样的 `.ico`，默认写在 PNG 旁边。PNG 读写不依赖平台：解码支持全部标准颜色类型、位深与隔行，编码输出 8 位 RGBA（自适应行滤波、固定 Huffman 的 deflate），同样输入得到同样字节。

## Windows 签名

`ziggurat.json` 的 `windows` 说明如何对 Windows 可执行文件和安装程序做 Authenticode 签名，SmartScreen 因此不再警告：

```json
{
  "windows": {
    "certificate": "certs/app.pfx",
    "timestampUrl": "http://timestamp.digicert.com"
  }
}
```

- `certificate`：相对项目的 `.pfx`，密码只从环境变量 `ZIGGURAT_WINDOWS_CERTIFICATE_PASSWORD` 读取。Windows 上用 PATH 中或最新 Windows 10/11 SDK 的 `signtool`（`sign /f … /fd sha256 /tr … /td sha256`），其他系统用 `osslsigncode`（签到 `.signed` 临时文件后替换原文件）。
- `timestampUrl`：RFC 3161 时间戳服务，默认 `http://timestamp.digicert.com`。
- `signCommand`：代替以上两项的 shell 命令，`%1` 换成加引号的文件路径，适合签名服务和硬件令牌上的证书，例如 `"signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 /a %1"`。命令输出照常显示，命令行本身不显示，因为其中可能有凭据。

`build --package` 在打包前签署 `zig-out/bin` 中的可执行文件；`WebView2Loader.dll` 这类已由发布者签名的库保持原签名，没有签名的 PE 文件会一并签署。`package setup` 在追加更新包之后签署 Windows 安装程序（存根跳过证书表，所以签名必须在最后）。`ziggurat sign FILE...` 按同样配置签署任意文件。签名在 Linux 上用 osslsigncode 2.8 与自签名测试证书实际验证过（证书与 `signCommand` 两条路径、默认时间戳服务）；Windows 上的 signtool 路径只做了命令行单元测试。

## vet

`ziggurat vet [DIR]` 先对项目的 `build.zig` 和 `src/` 下每个 `.zig` 文件运行 `zig ast-check`，然后检查视图生命周期：只在一次构建中有效的 `*view.View`，和只在一次绘制中有效的 `*ui.Frame`，不能存进结构体字段、容器级 `var` 或 `std.Thread.spawn` 的参数（构建和绘制只在主线程运行，结果应通过 `App.post` 交回）。以这些类型为参数的回调签名是正常用法，不报告；持久的状态、`view.Host` 和缓冲区也不受影响。检查只读语法树：它跟随文件给 `@import("ziggurat_view")`、`@import("ziggurat_ui")` 起的名字及 `View`/`Frame` 的别名，看不到类型的值（例如由调用推断的）不检查。有问题时逐条打印 `文件:行:列` 并以状态 1 退出。

## 控制台输出

`generate`、`i18n check`、`install-skills` 与 S3 发布在标准错误上每步一行。终端上进行中的步骤显示旋转指示、已用时间和当前进度（如上传的字节数），结束时改写为成功或失败及耗时；不是终端时开始与结束各打印一行。`NO_COLOR` 关闭颜色，`FORCE_COLOR` 在非终端输出中开启颜色，`TERM=dumb` 不重绘；Linux 虚拟控制台和字体不全的 Windows 控制台改用简单符号。旋转指示由一个只在终端输出时启动的线程重绘，命令结束前停止。

## doctor

报告主机、`zig version` 是否为 0.17.0、git、gh（可选，用于 `publish --github`）；Linux 上用 pkg-config 检查 GTK 3、Pango、ICU（`--webview` 时 WebKitGTK 4.1 与 libsoup 3 为必需）以及是否有显示；Windows 上检查框架的 WebView2 SDK 目录和注册的 WebView2 Runtime 版本；macOS 上检查系统版本（15.0 及以上，与 Zig 支持的最低版本一致）、`xcode-select -p` 的开发者工具、`xcrun --show-sdk-path` 的 macOS SDK（前两项缺少时为错误），以及钥匙串中 Developer ID Application 身份的数量（没有时提示只能 ad hoc 签名）；当前目录的 `ziggurat.json` 是否有效，在 macOS 上还按其 `macos` 配置检查 notarytool（配置公证时必需）与 actool（使用 `.icon` 图标时）。缺少必需项时退出码为 1。它只读取版本信息，不初始化任何页面或窗口；页面能否真正启动见 [引擎发现](webview-runtime.md)。

## 验证

`zig build test-cli` 运行 CLI 的单元测试（含 PNG 编解码与外部解码器互通的样本、图标缩放、ICO 目录、签名命令行与 PE 证书表识别、vet 的报告与例外），`zig build test-i18n-generated` 从 `tests/i18n_fixture` 生成访问器后编译并在多种语言中调用它们。`zig build test` 覆盖三种模板的渲染、名称与 identity 清理、非空目录与缺失框架拒绝，以及变化检测忽略构建输出。本地在 Linux 上用三种模板各生成项目、对本仓库实际 `zig build`，并在 Xvfb 中各运行 8 秒无错误退出（未做页面内容或视觉检查）；`dev` 在修改源文件后重建并保持单个应用进程；`build --package` 两次产生相同摘要。Windows 只完成交叉编译。CLI 测试另覆盖 Info.plist、本地化目录、应用包结构、通用可执行文件、codesign 参数、`.DS_Store` 与 dmgbuild 输出逐字节一致、二进制 plist、icns 和 install.ps1 引号规则。

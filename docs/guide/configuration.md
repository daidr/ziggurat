# 项目配置

`ziggurat init` 在项目根目录写出 `ziggurat.json`。`ziggurat build`、`package`、`generate`、`doctor` 等命令从这里读取应用的名称、身份、版本与分发配置。文件严格解析：名称、identity、可执行文件名和版本不合规时命令直接失败。

```json
{
  "name": "Hello",
  "identity": "com.example.hello",
  "executable": "hello",
  "template": "native",
  "version": "1.2.0.0",
  "icon": "assets/icon.png",
  "copyright": "© 2026 Example Ltd.",
  "homepage": "https://example.com/hello",
  "license": "MIT",
  "i18n": { "dir": "src/locales", "source": "en" },
  "service": "src/service.zig",
  "bindings": "web/src/client.ts",
  "urlSchemes": ["hello"],
  "fileAssociations": [{ "ext": ["hello"], "name": "Hello Document", "role": "Editor" }],
  "windows": {
    "certificate": "certs/app.pfx",
    "timestampUrl": "http://timestamp.digicert.com",
    "installDirName": "Hello"
  },
  "macos": {
    "signingIdentity": "Developer ID Application: Example Ltd. (TEAMID)",
    "notarize": { "keychainProfile": "ci" },
    "infoPlist": { "NSCameraUsageDescription": "Scan documents." }
  },
  "linux": { "command": ["hello", "hl"] },
  "installerHooks": { "install": "\"%ZIGGURAT_APP%\" --register-helper" }
}
```

## 基本字段

| 字段 | 必需 | 说明 |
| --- | --- | --- |
| `name` | 是 | 显示名称。不能含引号、尖括号、`&`、`@` 和反斜杠 |
| `identity` | 是 | 应用 ID，如 `com.example.hello`：只含 ASCII 字母、数字、点、下划线与连字符。单实例锁、AppUserModelID、`.desktop` 文件、macOS bundle ID 与更新包都用它 |
| `executable` | 是 | 可执行文件名，与 `build.zig` 中的 `addExecutable` 名称一致 |
| `template` | 是 | `native`、`web` 或 `hybrid`，记录项目由哪个模板生成 |
| `version` | 否 | 四段版本，默认 `0.1.0.0`。更新包、安装程序与 macOS bundle 使用它 |
| `icon` | 否 | 正方形 PNG（最好 1024×1024）。`build --package` 以 `icon.png` 放进更新包，Linux 安装程序与 deb 用作菜单图标 |
| `copyright` | 否 | macOS bundle 的 `NSHumanReadableCopyright` |
| `homepage`、`license` | 否 | 写进 PKGBUILD；`license` 是 SPDX 表达式 |

Windows 可执行文件的图标与版本资源由应用的 `build.zig` 嵌入（`addApplicationResources` / `addApplicationResourcesWithIcon`），见 [ziggurat 命令：图标](../cli.md#图标)。

## 代码生成

| 字段 | 说明 |
| --- | --- |
| `i18n.dir` | 消息目录所在目录，默认 `src/locales`，内含 `<语言标签>.json` |
| `i18n.source` | 源语言，默认 `en` |
| `service` | 导出 `Service` 类型的 Zig 文件，`ziggurat generate` 由它生成 TypeScript 客户端 |
| `bindings` | 生成的 TypeScript 客户端写到哪里 |

`ziggurat generate` 检查消息目录、写出 `<dir>/catalog.zig`（以及配置了 `bindings` 时的页面消息模块），再生成 IPC 客户端。见 [本地化](../i18n.md) 与 [从页面调用 Zig](./bindings.md)。

## 系统集成

| 字段 | 说明 |
| --- | --- |
| `urlSchemes` | 应用处理的深链 scheme，macOS bundle 会声明它们 |
| `fileAssociations` | 应用打开的文件类型：`ext`（不带点）、`name`、`role`（`Editor` 或 `Viewer`）、`mimeType` |

Windows 与 Linux 上的 scheme 与文件关联在运行时按用户注册，见 [单实例与系统集成](../os-integration.md#url-scheme-与文件关联)。

## Windows

| 字段 | 说明 |
| --- | --- |
| `windows.certificate` | 代码签名证书 `.pfx`（相对项目）。密码只从环境变量 `ZIGGURAT_WINDOWS_CERTIFICATE_PASSWORD` 读取 |
| `windows.timestampUrl` | RFC 3161 时间戳服务，默认 `http://timestamp.digicert.com` |
| `windows.signCommand` | 代替以上两项的签名命令，`%1` 换成加引号的文件路径，适合签名服务和硬件令牌 |
| `windows.installDirName` | 安装目录名，代替 identity，如 `%LOCALAPPDATA%\Programs\Hello` |

签名在 Windows 上用 `signtool`，其他系统上用 `osslsigncode`。见 [ziggurat 命令：Windows 签名](../cli.md#windows-签名)。

## macOS

| 字段 | 说明 |
| --- | --- |
| `macos.signingIdentity` | 签名身份，如 `Developer ID Application: Jane Doe (TEAMID)`；默认 `-`（ad hoc，只能在构建它的 Mac 上运行） |
| `macos.notarize` | `{ "keychainProfile": "...", "keychain": "..." }`：把磁盘映像提交公证并装订票据，需要 Developer ID 身份。凭据用 `xcrun notarytool store-credentials` 存进钥匙串 |
| `macos.icon` | 代替 `icon` 的 macOS 图标：`.icns`、actool 编译的 `Assets.car`，或 Icon Composer 的 `.icon`（需要 Xcode 26） |
| `macos.minimumSystemVersion` | 最低系统版本，默认 `15.0` |
| `macos.entitlements` | 签名使用的 entitlements 属性列表 |
| `macos.provisioningProfile` | 嵌入为 `Contents/embedded.provisionprofile`；不能与 ad hoc 签名同用 |
| `macos.infoPlist` | 额外的 Info.plist 键，覆盖框架自己的，例如权限用途说明 |
| `macos.dmgTitle` | 磁盘映像的卷名，默认是应用名 |

## Linux

| 字段 | 说明 |
| --- | --- |
| `linux.command` | 运行应用的命令名：一个名字，或 `["my-app", "ma"]` 这样的列表以加一个短名；默认是可执行文件名。deb 与 PKGBUILD 在 `/usr/bin`、用户范围安装程序在 `~/.local/bin` 为每个名字建链接 |

## 安装钩子

`installerHooks` 是安装程序运行的应用自己的命令，静默安装也运行：

| 钩子 | 时机 |
| --- | --- |
| `init` | 写入任何内容之前；失败则不安装 |
| `install` | 应用装好并完成系统集成之后 |
| `uninstall` | 卸载程序删除应用目录之前；失败不阻止卸载 |

命令在 Linux 上由 `/bin/sh -c` 运行，在 Windows 上写成临时批处理文件的一行运行。环境变量有 `ZIGGURAT_INSTALL_DIR`、`ZIGGURAT_SCOPE`（`user` 或 `machine`）、`ZIGGURAT_VERSION` 与 `ZIGGURAT_SILENT`，`install` 与 `uninstall` 另有启动器路径 `ZIGGURAT_APP`。应用内更新只替换文件，不运行这些命令。见 [资源、打包与安装程序](../packaging.md#安装程序、启动器与卸载)。

## 检查

`ziggurat doctor` 会报告当前目录的 `ziggurat.json` 是否有效，并在 macOS 上按 `macos` 配置检查公证与图标工具是否可用。

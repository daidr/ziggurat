# Windows 资源与打包

`build_support/packaging.zig` 的 `addWindowsResources` 把显式 Metadata 与 ICO 转成清单、VERSIONINFO 和图标资源，由 Zig 自带资源编译器参与构建。每个可执行文件有独立的生成目录，构建结果依赖实际输入文件。

应用提供 assembly identity、显示名称、四段版本和 ICO。可选描述、公司名称与版权不填虚构值。清单使用 `asInvoker`、PerMonitorV2、长路径支持和 Windows 10 兼容声明；版本资源与清单使用同一个版本来源。XML 和 RC 分别校验与转义，RC 引号采用双写语法。资源 ID 为图标 `101`、清单 `1`、版本 `1`。

默认图标含九种尺寸，PNG RGBA 图像共 4,181 字节。`assets/generate-icon.ps1` 从确定的几何生成图像；正式构建直接消费已保存 ICO。应用可以替换 ICO，无需修改原生窗口实现。

`AppOptions.icon_policy` 有三个值：`automatic` 在资源不存在时使用系统默认；`disabled` 不加载图标；`required` 将缺失资源作为初始化错误。其他图标加载失败不会静默忽略。类图标由 App 持有到注销类之后，每个窗口另持有一对图标；DPI 重载先安装新句柄，再销毁旧句柄。

Ziggurat 使用仓库根目录的 MIT `LICENSE`；Zig 源码包与构建安装文件都包含它。打包本仓库示例时显式选择该文件：

```powershell
pwsh -NoProfile -File scripts/package.ps1 -Name MyTool `
  -ExecutablePath zig-out/bin/counter.exe -LicensePath LICENSE
```

`-WebView` 额外收集同目录 Loader 与 SDK 许可证，也可显式指定路径。脚本检查 PE 架构、嵌入版本与清单的一致性，生成排序且时间戳固定的 ZIP、文件大小/SHA-256 清单和归档 SHA-256。原生包不加入 WebView 依赖；WebView 包准确标明系统 Runtime 未包含。脚本不会自动安装 Runtime。

通用脚本继续要求 `-LicensePath`，下游应用应传入自己的许可文件；框架的 MIT 选择不会替应用选择许可证。包内文件名为 `LICENSE.txt`，正文保留输入文件的完整字节。隔离测试仍可传入标明用途的 fixture；CI 中本仓库的打包与签名检查使用正式 LICENSE。打包的确定性指同一组输入在同一工具环境重复产生相同归档，不保证不同编译器或压缩库版本的二进制一致。

`zig build smoke-packaging` 检查实际 EXE 的清单、Unicode/引号/反斜杠版本文本、九尺寸图标，以及 1000 次图标重载后的 USER/GDI 计数。`tests/packaging.ps1` 检查 ZIP 排序、文件清单与哈希、许可依赖和版本不一致拒绝路径。

## Authenticode 签名

`sign-package.ps1` 接受 CurrentUser/My 中的证书指纹，或显式 PFX 与 SecureString 密码。它复制原始 EXE 到独占临时目录，签署副本、核验签名与信任，再调用同一 packager；原始编译产物保持不变。签名报告记录实际 signer、信任结果与签名前后 SHA-256，包内清单描述签署后的 EXE。

```powershell
./scripts/sign-package.ps1 -Name Tool -ExecutablePath zig-out/bin/counter.exe `
  -LicensePath path/to/application-license.txt -CertificateThumbprint CERTIFICATE_THUMBPRINT
```

可用 `-TimestampServer` 显式选择 HTTPS 时间戳服务。默认必须通过系统信任验证；签名不能赋予程序未获得的分发许可。`-AllowUntrustedTestCertificate` 只用于测试，精确接受未受信任根的测试证书并把报告标记为 test_only，不把其他签名错误当成成功，不修改受信任根存储。

`tests/signing.ps1` 实际生成一天有效的测试代码签名证书，验证 store/PFX 两条路径、严格生产拒绝、ZIP 中的签名与摘要、修改映射代码后的 HashMismatch，以及原文件不变；finally 删除该测试证书和临时私钥。更新通道的 Ed25519 签名属于另一层，见 [更新模块](updates.md)。

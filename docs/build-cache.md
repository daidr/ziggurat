# 构建缓存

原生 C 适配由 `build_support/native.zig` 创建独立 object 或静态库成员构建根，再显式附加给使用模块。Zig 0.15.2 下，导入模块直接拥有 C 源时，已实际复现只修改间接头文件却复用旧对象的情况。独立构建根的头文件依赖由编译步骤跟踪；同一模块的消费者复用该产物。编译需要的 include/pkg-config 配置属于原生构建根，最终系统库仍由消费模块明确声明，可选后端继续按需构建。

`add` 用于随消费模块链接的 object；`addArchive` 将可选代码放进独立静态库成员，由真实符号引用拉取。具体可执行文件是否排除了未用代码，仍须检查实际链接产物，不能仅由库的形式推断。

以下回归检查把实际构建 helper 和最小两级头文件样例复制到独立目录，分别对 object 和 archive 第一次读到 17，再仅修改间接头文件为 29，用原缓存重新构建并检查实际程序结果。Windows/Linux 均实跑通过两种链接形式；测试保留四次日志和样例，不修改工程头文件：

```powershell
./scripts/test-native-header-cache.ps1
```

```bash
bash scripts/test-native-header-cache.sh
```

Linux 通过 `ZIG_BIN` 显式指定工具链；Windows 可传 `-ZigPath`。两者使用项目盘上的缓存，检查已接入 CI，远端执行结果需单独确认。

清理前等待所有 Zig 构建和原生测试退出。脚本默认预览，显式传入执行参数才删除。默认保留最近 24 小时改动过的候选目录；需要在一轮验证结束后清空生成缓存时，将时间设为 0。

磁盘受限时，同一绝对源码目录的验证按阶段复用本地缓存和安装前缀，不为每个切片复制整套缓存。Windows 的全局缓存使用 `windows-global`；Linux 使用已挂载的 Linux 文件系统。live checkout 与固定源码副本必须各自绑定不同本地缓存，即使串行验证也不能交替共用；全局缓存可以共享。源码固定副本只保留一份；小型日志、SHA256 清单和验收记录写入 `.validation`，必要源码增量副本也保存在缓存外。这些本地目录已忽略，不作为分发依赖。

实际验证曾在两个源码目录共用本地缓存后出现混合产物：新 SVG 隐藏原生程序包含闭合标记，但纯测试复用了旧201项程序。保留该日志，并改用独立本地缓存重新编译，实际得到218项及新断言；前一结果不计作新纯测试验收。这里不据此判断其它失败的原因。固定源码哈希只能证明输入，须同时核对实际测试数量、新行为及所运行产物身份。

手动删除正在使用的缓存会使有效验证中断；删除源码副本或日志还会丢失该次验收依据。恢复时先停相关构建、保全当前源与残存记录，再重跑实际缺失的检查，不把缺文件失败记作源码回归，也不把旧的中间版本通过记作最终整合通过。空间足够时不为重跑而先清空可复用缓存。

Windows：

```powershell
./scripts/clean-cache.ps1 -Scope All
./scripts/clean-cache.ps1 -Scope All -OlderThanHours 0 -Apply
```

`-CacheRoot .zig-cache/managed/windows-live-review-cache` 可把范围缩小到已存在且已识别的单个缓存；预览与执行使用相同参数。它仍要求 WSL、编译器及相关缓存程序全部停止，不登记任意目录或绕过原有删除检查。

Linux/WSL：

```bash
bash scripts/clean-cache.sh --global
bash scripts/clean-cache.sh --global --older-than-hours 0 --apply
```

只清一个已存在、已被脚本识别的 Linux 缓存时，可传 `--cache-root "$ZIG_LOCAL_CACHE_DIR"`；先执行不带 `--apply` 的预览，再用相同路径执行。此参数不会把任意目录登记为缓存，也不绕过文件系统、链接、活动程序或生成目录检查。已结束验证的来源证据若只在 `h` 中，清理前应先将小型依赖清单及必要原文保存到缓存外。

Windows 范围为项目 `.zig-cache`、其直接子缓存、`managed` 下登记命名的缓存，以及显式 `Global`/`All` 选择的 `%LOCALAPPDATA%/zig`。Linux 还识别用户 `~/.cache/ziggurat` 下的本地/全局缓存及挂载的专用缓存目录，`--global` 加入默认用户 Zig 全局缓存。Linux 脚本按 superblock magic 识别 ext、XFS、Btrfs、tmpfs 和 overlay，跳过共享或未知文件系统；同一 DrVFS 在不同工具版本中可能显示为 `9p` 或 `v9fs`，不依赖这个名称。因为 `/proc` 无法检查 Windows 编译器活动，共享盘缓存由 Windows 脚本处理。

脚本仅选择识别出的缓存根下 `o/h/z/tmp/b` 生成目录，保留检查点源码、日志、工具链、下载依赖、安装输出和缓存镜像。包含链接/junction 的候选整体跳过。执行前及每次删除前检查活动程序，重新扫描候选；发现 Zig 编译器、从缓存运行的程序，或无法检查的本用户程序时拒绝清理。Windows 脚本在任何 WSL 发行版运行时拒绝执行删除，可在 WSL 内使用 Linux 脚本，或在所有任务结束后关闭 WSL 再清理 Windows 缓存。清理期间不要启动新的构建；脚本不提供跨进程构建锁。

通用隐藏窗口检查同时提供 `build-<目标名>`，例如
`zig build build-smoke-document-diff-view` 只构建安装产物，便于在其它原生检查退出后
再显式运行；`smoke-document-diff-view` 仍会构建并运行。两种入口使用相同源、参数和
安装产物，单独构建不代表原生检查通过。已有专用检查保留各自明确的构建/运行入口。

## WSL 与系统盘

DrVFS 上，已打开可执行文件所在目录可能无法重命名；本项目已实际遇到 Zig 构建器发布缓存失败。Linux 本地缓存应使用 Linux 文件系统。需要将缓存容量留在 D 盘等数据盘时，可以将专用 ext4 镜像存放在项目内，并挂载给 WSL。

从 Windows PowerShell 执行一次创建；已有镜像时 `--create` 会拒绝覆盖：

```powershell
wsl -d Ubuntu-24.04 --user root -- bash /mnt/d/devFolder/ziggurat/ziggurat/scripts/mount-wsl-cache.sh --create
```

WSL 重启后重新挂载已有镜像：

```powershell
wsl -d Ubuntu-24.04 --user root -- bash /mnt/d/devFolder/ziggurat/ziggurat/scripts/mount-wsl-cache.sh
```

镜像为 `.zig-cache/managed/wsl-cache.ext4`，容量上限 16 GiB；挂载点 `/mnt/wsl/ziggurat-cache`。脚本只允许项目位于 `/mnt/d` 至 `/mnt/z`，不修改发行版或系统磁盘。清理只释放镜像内部容量，不删除或格式化镜像，也不承诺立即增加宿主 C 盘可用容量。

Linux/WebKit 检查脚本通过 `linux-cache-env.sh` 默认使用该挂载点；未挂载时明确失败。直接构建显式传入本地/全局缓存；并行任务分别使用不同本地缓存和安装输出前缀，避免覆盖另一任务尚未运行的可执行文件。串行阶段只在同一绝对源码目录内复用本地缓存；源码清单不替代实际运行二进制的身份核验：

```bash
mountpoint -q /mnt/wsl/ziggurat-cache || exit 2
zig build test check -j1 \
  --cache-dir /mnt/wsl/ziggurat-cache/root-cache \
  --global-cache-dir /mnt/wsl/ziggurat-cache/global \
  --prefix .zig-cache/managed/linux-out
```

普通 Linux 文件系统上的工程可直接使用项目内缓存。WebKit 脚本支持 `ZIGGURAT_LINUX_CACHE_ROOT` 显式指定另一个 Linux 文件系统目录；`P01_BUILD_CACHE`、`P01_GLOBAL_CACHE` 和 `P01_RUNTIME_CACHE` 可分别覆盖对应缓存。

独立 C 探针的可执行文件和请求策略扩展也写入项目 `managed` 下的 `webkit-out/probes`、`webkit-request-out` 或 `content-out`，用 `P01_OUTPUT_DIR` 显式覆盖。运行期数据使用 `P01_RUNTIME_CACHE` 下的 `data`；私有引擎挂载目录位于对应输出目录。检查脚本只读取已下载的 SDK 依赖，不向用户目录追加编译产物。

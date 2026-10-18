# 独立文件流与显式 consumer

可选模块 `ziggurat_file_stream` 提供私有普通文件、显式 worker pump 和独立原生 consumer 之间的有界交接。Linux 使用 GIO/POSIX，Windows 使用共享有界 channel 与 overlapped 文件泵；它不依赖 App、Window、View、HTTP 响应或 TLS 服务，不创建线程、服务器或事件循环。其他平台返回 `UnsupportedCapability`。既有 Windows WebView 直接文件响应仍使用原 IStream 路径，并与新 channel 共用物理账本。

该模块不授予文件系统、页面或网络权限。宿主在自己的 worker 打开文件，并保证传输期间没有其他写入者、可写映射或替换内容。复制 fd 只保留已打开对象，不能证明字节不可变；文件缩短或读取失败仍会成为真实传输错误。

可选[原生字节生产者](native-stream.md)以 `Source` 别名复用同一个 consumer 协议和
physical账本，由独立 Writer 生成已知长度字节。文件 Pump 与生成 Writer 有明确不变的
kind，两者互拒；别名不授予文件权限。原有 prepare/prepareWindow 的完整普通文件检查、
worker边界、ABI与错误顺序保持。

## 所有权与交接

`PreparedSource.prepare` 只能在调用者明确提供的 main-thread ID 之外运行。它借用文件，保留原 seek position，返回两个独立的线性拥有值：`PreparedSource` 与 `Pump`。prepare-time 长度是本次传输的权威长度，不在 owner 采用时重新 stat，也不复制整个文件内容。

`PreparedSource.prepareWindow(main_thread, file, FileWindow{ .offset = ..., .length = ... }, maximum)` 与 `prepareWindowWithFailure` 只准备指定的 `[offset, offset+length)` 字节表示，使用相同的显式 worker、私有不可变源和双引用合同。`maximum` 仍限制整个普通文件，硬上限仍为 256MiB；不能用小窗口绕过源文件上限。原生 size 必须满足 `offset <= size`、`length <= size-offset`，否则返回 `InvalidFileWindow`，不截断或扩大请求。零 length 只代表空表示，包括 EOF 处的空窗口，不代表“读到文件尾”。逻辑错误清空 `native_failure`，真实系统调用失败才提供 errno；原有 prepare 的 ABI 与错误顺序保持。

`PreparedSource.length` 是可改写的公开便利缓存；消费者使用 `authoritativeLength()` 的原生选定长度，不能借改写缓存改变读取范围或 Content-Length。window 的 pump 从捕获的 base offset 执行 Linux pread 或 Windows overlapped ReadFile，并限制最后一个 chunk，保留调用者 seek position。截断或实际 I/O 错误仍是传输失败，不把短 body 当作成功。

`Pump.pump` 由宿主自己的 worker 执行，等待 consumer 接受或取消，然后通过固定 chunk 和 socket 背压读取。它可能阻塞这个显式 worker；不能在 UI 调用。模块没有 regular-file `GInputStream` 的隐式异步读取后备。取消唤醒等待中的 poll，但不能抢占已经开始的普通文件 `pread`。宿主负责 worker 生命周期和 join，owner 不等待 worker 回调自己。

owner 使用 `Budget` 调用 `PreparedSource.prepareConsumer`，得到一个暂定 `ConsumerCandidate`。候选的 `stream()` 是 Linux 专用、借用的 socket-backed `GInputStream`，不是文件流；需要在采用后继续读取的 Linux consumer 必须先取得自己的 GObject 引用。Windows 的该 getter 在检查/消费候选前返回 `UnsupportedCapability`，不返回私有 Reader 或伪造 IStream；正常公共流程是 Source → Endpoint.Offer/Ticket，内部 driver 明确取得同一 consumer Reader。

- `abort` 消费候选、归还暂定 consumer reservation，保留原 prepared source/pump，允许宿主修正失败后重试。
- `admit` 只能发生在 consumer 已不可撤销地接受一次响应责任之后。它消费候选、转移 reservation 并唤醒 pump，不存在接受之后再返回可重试失败的 native 步骤。接受边界同时发生关闭或取消时使用 `accepted_cancelled`，仍须完成已接受责任。
- `HEAD` 仍走相同接受和物理引用协议，但 pump 不执行 `pread/ReadFile`；不能把 HEAD 的零字节读取误当作无需清理。

接受只是本地责任转移，不是对端已消费数据的 ACK。HTTP transport 的写入进度、页面应用层 ACK 和文件 pump 的 socket credit 必须分别管理。此模块本身不实现 HTTP/TLS transport 或页面资源路由。

FileWindow 不解析 HTTP Range，也不生成 206、Content-Range 或目录路由。宿主可在独立授权的显式资源路由中把选定字节作为完整 HTTP200 表示；这不开放默认 Range 请求策略或 HTTPS local_site，也不暗中改变既有 WebView FileResponse 便利 API。

可选 `Control` 是独立取消引用，可显式 clone，并可跨线程取消。它不保留 source、stream、physical slot、Budget、App 或 caller allocator。保留一个旧 Control 不能占住已经完全释放的文件槽，也不能取消后续复用的新文件。

所有拥有值均为线性能力，复制结构体不产生新的关闭责任。未接受的结果投递若遇到 `App.post` 的 `Full` 或 `Closed`，宿主保留 source/pump 并自行清理；成功 post 则按原 App 合同完成 owner 交接。迟到的原生流引用只依赖 C/GObject 存储，不回调已经释放的 Zig owner。

## 容量与实际释放

单文件硬上限为 256MiB；单 consumer 最多八个 reservation，同一进程的文件与生成流共用32个物理通道。chunk 固定 16KiB，没有与文件大小成比例的 body allocation。consumer 的限制可显式降低，不能超过硬上限。

进程物理槽由 source、pump 和实际 stream 引用共同保留。逻辑取消、关闭 Budget 或 `GInputStream.close` 都不等于最后释放；实际 final unref 后才允许槽复用。一个进程的生产 consumers 必须链接同一份 native implementation，不能把源文件按每个 consumer 重编译，从而产生多份看似独立的全局 32 槽计数。故障注入的测试实现也不能与生产实现混入同一个可执行文件。

whole-file 与 window 共用同一 physical/control/reservation 账本。Linux window 只增加一个 base offset，不增加 allocation 或工作线程；实际 x86_64 C 布局中物理文件头为 80 字节，旧头为 72 字节，Control/Budget/Candidate 仍为 32/12/32 字节。32 个物理文件最多增加 256 字节的结构体请求大小；这不是 malloc 分档、RSS、内核 socket 或 GLib/SDK 存储的总量保证。未创建文件源的默认路径没有这份分配。

Windows worker 重新打开同一受借普通文件，先检整个文件 hard maximum，再检窗口。
独立文件 handle/event 跟随 Pump；取消时 CancelIoEx 后在 worker 排空实际 overlapped
操作，才让栈 OVERLAPPED 和16KiB输出离开作用域。UI 不 ReadFile、wait 或 join。
直接 IStream 的 worker-only Read/Seek 继续原合同，新 Pump 与 Writer 互拒 kind。
实际 Debug/ReleaseSafe native 覆盖4MiB的256次读取、offset7/length111113的7次读取、
HEAD与空窗口0读取、OOM、阻塞取消、保留 producer 及最后引用归零；字节逐个验证，
借用文件游标保持不变。Windows 公开 HTTPS/browser 组合的验收范围另见 Transport。

容量是并发物理对象的界限，不是总进程 RSS、内核 socket 缓冲或系统库内部 allocations 的配额。metadata 使用原生分配；GLib 的 GObject allocator 具有进程级 OOM 终止语义，不宣称所有系统分配都能以 `OutOfMemory` 恢复。

## 兼容层与检查

WebView 的公开 `OwnedFileResponse`、`FilePump` 和 `StreamTicket` 保留原有形状、错误与所有权。Linux 内部借用同一独立模块，原生页面层仍负责实际响应接受；兼容 C 头只转引声明，兼容 C 文件不再包含另一份实现。Windows 分支不因此换用 GIO。

`zig build test-file-stream` 检查独立 wrapper 的前置条件；Linux `zig build test-webkit-file -Dwebview=true` 验证原有文件读取、故障、取消和 final-reference 行为，并加入多个 consumer 共享进程容量的回归。公开页面的动态/文件、HEAD、导航与关闭仍须运行原生集成检查。单纯编译或独立 console 测试不证明浏览器与 HTTP transport 已完成。

FileWindow 已在 Linux/X11 Debug 与 ReleaseSafe 分别通过上述两目标，并通过 `smoke-https-pages -Dwebview=true -Dhttps-resources=true` 的真实 Site/Endpoint/WebKit 组合。独立 pread 参考验证非零 offset 的跨 chunk 字节、单字节、末尾与空窗口；HEAD/empty 为零 pread，原 fd 关闭、seek 不变、错误/OOM、取消/背压和最后引用均有检查。页面另逐字节验证 offset17/length65541 的 HTTP200、选定 Content-Length、固定 policy headers、HEAD 与 empty GET；已有九种生命周期/路由模式保持，最终 HTTP/file/Profile/View 引用归零。这些检查不建立视觉质量、HTTP Range 或跨平台原生支持。

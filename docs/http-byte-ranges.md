# HTTP 字节范围

`http_response.byte_range` 提供纯解析、数字选择和 Content-Range 格式化。
它借用输入到函数返回，结果只保存数字；不分配内存、不访问文件、不发起请求。
宿主先验证请求权限、选择稳定的表示身份并处理其他 HTTP 前提条件，再使用这些函数。
该纯模块不会自动启用 Endpoint、Site 或 WebView 的 Range 请求。
Linux HTTPS Endpoint/Site 可单独显式设置 `range_requests = true`；它不改变 WebView 的请求头权限。

## 解析与选择

`parse(value)` 最多接收256字节字段值。`bytes` 单位不区分 ASCII 大小写；允许字段外侧的空格或 TAB，但单位与 `=` 之间、数字内部不允许空白。
逗号列表最多接受8个空项，包括开头和末尾；`bytes=,0-1,` 仍是一个范围，全部为空则拒绝。
十进制数字可带前导零，闭区间的起点不能大于终点。

`Parsed.single` 包含 `Spec.closed{first,last}`、`Spec.from` 或 `Spec.suffix`。
多个合法范围返回 `multiple`，超过 u64 数值能力返回 `numeric_limit`；遇到逗号或溢出后仍检查完整语法，错误尾部不会被忽略。
两个条件同时存在时，完整校验后以 `numeric_limit` 为先。
未知单位返回 `unknown_unit`，只检查其值非空、受长度限制且不含危险控制字符，不声称理解该单位的语法。

`select(spec,total)` 返回 `Selection.full`、`partial{offset,length,total}` 或 `unsatisfiable{total}`。
它独立校验调用者手工构造的 Spec，不能靠“之前解析过”跳过校验。
闭区间末尾按实际长度截断；起点位于非空表示之外或后缀长度为0时不可满足。
本模块选择忽略空表示上的范围请求，返回 `full`。所有 u64 边界先做减法界限检查，再计算包含式长度。

`evaluate(method,parsed,total,if_range,current_etag)` 对已获授权的 GET/HEAD 应用以下选择：

| 条件 | 结果 |
| --- | --- |
| GET、一个可满足范围、没有 If-Range 或强 ETag 精确匹配 | `partial` |
| GET、受支持的单范围不可满足 | `unsatisfiable` |
| HEAD、没有 Range、未知单位、合法多范围、数值超限、空表示 | `full` |
| If-Range 不匹配、弱标签、日期、缺少当前强标签或无效值 | `full` |

这里的 `method` 是模块自己的 `.get`/`.head` 枚举，不扩大其他方法权限。
宿主把 `partial` 映射为206，把 `unsatisfiable` 映射为416；合法多范围只是不做 multipart 处理，按完整200响应，不能仅因缺少 multipart 实现而伪报416。
其他 HTTP 条件应先由宿主决定304/412等正常结果；这个函数不是完整缓存或条件请求处理器。

`ifRangeMatches` 仅支持受256字节限制、精确匹配且语法有效的强实体标签。
不从文件大小、修改时间或名字推断标签强度；HTTP-date 验证尚未实现，使用完整响应。
纯函数允许的标签字节与 OWS 不表示运输策略一定允许它们；Endpoint/WebView 已有更严格的字段限制仍独立生效。

## 格式化与文件响应

`formatContentRange(selection,output)` 接收调用者的 `[]u8` 缓冲区，返回借用其内容的切片，不附加 NUL。
完整 u64 部分范围最多需要68字节，可用 `[72]u8` 留出余量。
它独立验证公开 Selection：部分范围要求 total、length 非0，offset 小于 total，length 不超过 total-offset；不可满足范围的 total 非0。
`full` 不生成 Content-Range。形状错误或空间不足时，整个输出缓冲区保持原样。

宿主在显式 worker 中取得已授权文件的完整长度，再把部分选择的 offset/length 映射到 [`FileWindow`](file-stream.md)。
完整源仍受 FileStream 的硬上限约束；文件身份及内容必须稳定到运输结束。
不要在 UI 回调中打开、stat、seek 或读取文件。
实际响应仍使用原有头数量/字节预算、CSP、Offer/Ticket 和最后原生引用计费；Content-Length 由运输层的权威长度产生，不作为普通响应头注入。
HEAD 使用完整表示元数据且不读文件正文。

## HTTPS 请求准入与借用

`Endpoint.Options.range_requests` 和 `Site.Options.range_requests` 默认为 `false`。
配置在第一次原生引用操作或调用者分配前捕获；纯 `Policy.captureInto` 无论目标原先内容如何，都显式恢复 `false`。
开启后仍须独立满足 listener、实际地址、Host、Bearer、可选 Origin、GET/HEAD 和无请求正文的原有门禁。
这不修改 `browserManaged`：WebView 页面发送 Range 时仍须有该可信 origin 的显式 `request_headers` grant。

开启后的 GET 最多允许一个 SDK 观测到的 Range 字段；值最多256字节，完整校验语法后才派送。
当 Range 存在时，重复 If-Range 同样拒绝。重复字段、过长值或坏语法返回策略403，尚未打开文件或派送业务，不能冒充不可满足的416。
If-Range 单独出现时维持原有忽略语义。
HEAD 仅受原有64头、16KiB及每字段边界约束，不解释 Range/If-Range，不因其范围语法错误或重复而执行 GET 的特殊拒绝。

`Endpoint.Request.headers` 和 `Site.Request.headers` 直接借用已有的最多64行描述符及其名称/值，只有当前业务 callback 返回前有效。
同步 respond、defer 或 callback 内 close 不缩短这个借用期；Ticket、worker 和响应不能延长它。
宿主在回调内提取数字解析结果与自己的强标签匹配结论，再把这些拥有型数值交给显式 worker，不能保存该 slice、头描述符或其字节指针。
列表包含认证字段，不应整表写入日志。

准入本身不选择部分响应。静态 Site route 和普通响应依旧可以返回完整200。
动态文件路由须在授权、其他前提条件和稳定表示身份检查后，由宿主选择206/416/200，实际附加 Content-Range、强标签及所需 policy headers，并用现有 Offer/Ticket 接受合同运输。
原生 `accumulate=false` 的发送路径没有委托 SDK 自动处理范围。

固定 libsoup3.4.4 的独立 HTTP/1.1 TLS 观察中，iterator 保留了被测两行重复 Range/If-Range。
本策略只对 SDK 实际提供的行负责，不承诺恢复被上游合并或丢弃的原始 wire 重复。
纯函数与请求准入已有实际 Debug/ReleaseSafe 回归。
固定 X11/WebKitGTK2.52.6/libsoup3.4.4 的同源 HTTPS 页面还逐字节验证两个206、416、错标签/合法多范围/未知单位的完整200，以及 HEAD 零 pread。
416只取得 worker 元数据，不创建 FileStream；空表示另用已授权非空源上的0B FileWindow 验证 GET/HEAD200，不能把它说成原始空文件的 stat 场景。
每项最后 HTTP/file/Profile/View 引用归零；这些是隐藏窗口运输和寿命验证，不代表其他引擎、视觉质量、跨源 CORS 或整个本地站点能力。
`Options.local`/`local_site` 的支持范围没有因此增加。

Linux x86_64 的实际 D/RS 类型比较中，Policy 为294字节（原292）；Endpoint/Options 与 Site/Options 大小不变，新增 flag 使用现有填充。
两个公开 Request 各增加16字节 slice；描述符和字段字节继续借用已有64行栈表，不新增头数组或堆分配。
默认关闭不进入独立 noinline Range parser；这些是源码与 sizeof 边界，不是全调用链栈峰值、RSS 或吞吐性能测量。

## 拥有型文件响应

`https_resources.FileRequest.capture(method, request.headers, representation)` 在已授权的
GET/HEAD callback 内复制强 ETag、MIME 和数字选择信息，不分配、不访问文件，也不保留
借用的请求头。宿主须先决定其他条件请求的304/412结果，并保证 ETag 指向之后运输的
同一份稳定字节；helper 不从文件名、stat 或时间推断强标签。ETag 最多256字节，MIME
最多127字节，均采用现有响应头的安全字符限制。其他方法明确返回 `MethodDenied`。
公开手工构造的 `FileRequest` 在每个消费入口重新校验长度、方法和 Parsed，包括 HEAD
以及 If-Range 不匹配时不会使用的数字；不能用错误长度访问其内联数组。

显式 worker 调用 `PreparedFileResponse.prepare(main_thread, file, maximum, request)`，
返回 `PreparedFile{ response, pump }`。它先验证完整 regular file 与整个文件的 maximum，
再按请求生成以下结果；文件必须由宿主预先授权并保持私有、不可变，直到运输结束。

| 选择 | 响应与 worker 责任 |
| --- | --- |
| full | 200、完整长度；GET 使用原文件源，HEAD 保留真实源验证与物理账但零 pread |
| partial | 206、选定的 FileWindow、Content-Range 与选定长度 |
| unsatisfiable | 416、零 body、Content-Range `bytes */total`，不创建 FileStream 或 Pump |

helper 统一附加强 ETag、CSP、no-store 和 nosniff；Content-Length 仍由 Endpoint 的权威
源长度决定。空文件上的范围按完整200处理。合法多范围、未知单位、数值超限和未匹配
If-Range 均返回完整表示。没有自动打开路径、目录映射或更改权限的操作。

`response` 和可选 `pump` 是两个独立线性拥有值。宿主通过成功的 `App.post` 把稳定
response 交回主线程，worker 保有 Pump 并调用 `pump()`/`deinit()`；文件句柄、任务
存储和线程仍由宿主管理。HEAD 的 Pump 可在接受后直接 deinit，416 没有 Pump。
post 返回 `Full/Closed` 时仍由调用者释放或保留这两个责任，主线程不等待 worker。

`Offer.respondPreparedFile(&response, options)` 与 Ticket 上同名方法使用原 Endpoint
单一提交事务。接受前的 OOM、预算、关闭或源验证失败保留 response 与 Ticket；接受时
先撤 response 的 ready/source 及 Ticket，再进入可能重入的原生清理。
`accepted_cancelled` 仍表示已接管一次，不能重试。返回后可以直接释放 response 的
宿主存储；接口不在 foreign cleanup 后再读取它。prepare 后不允许复制或修改 response
的任何字段，只能提交或 deinit。Pump、receipt control、晚到 Ticket 仍按既有最后物理
引用合同释放，`on_closed` 不是网络或 worker 已退出的屏障。

公开 helper 在 Linux Debug/ReleaseSafe 纯目标各30/30通过；TLS/App 各完成42种模式，
新增206、HEAD零pread、接受前拒绝、独立取消和 post Full/Closed 的线性责任回归。
独立 ReleaseSafe 故障进程分别覆盖 HTTP/file 候选的两个项目分配失败点，保留同一个
response/Ticket 并随后成功提交206，最后引用归零。SDK fatal OOM 不在注入范围内。
同源 WebKit 两种编译模式实际使用该公开接口核验七个范围请求，以及原始 sealed 空文件
的 GET/HEAD；当前空文件检查与上一节早期0B窗口检查分别保留。

实际 Linux x86_64 Debug ELF 的类型记录为 FileRequest432、PreparedFileResponse504、
PreparedFile520、opt-in Metadata632字节；同一已运行 ELF 对比中 Endpoint496、Site208
和私有 Input64字节保持不变。默认 Endpoint/Site/Remote 不新增字段或分配；响应头
metadata 仅在显式 noinline prepared 入口使用。这里是类型和源码成本，不是调用链栈峰值
或 SDK 总内存测量。

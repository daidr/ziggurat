# 文档初始化器

Windows 与 Linux 的 `backendCapabilities().document_initializers` 为 true，支持 `document_start` 和页面 world，frame 可以是顶层（默认）或 `all`；其他组合明确拒绝，不回退成不同的执行方式。两端复用同一拥有层、可信函数体编译器和事务簿。Windows 使用 WebView2 Add/Remove；Linux 使用 WebKitGTK 2.40 基线已有的精确 user-script 对象接口，内部 bridge 与用户 batch 分别拥有，逐对象移除，不调用 `remove_all_scripts`。引擎验证的范围分别列在下文。

每项初始化器包含宿主信任、语法有效的普通函数体 `body` 和精确 HTTPS `origins`。有效函数体按列表顺序分别调用，局部声明属于自己的函数作用域，`return` 只结束这一项；未捕获的 `throw` 终止后续项。它不是多个独立全局程序或模块的拼接，不支持顶层 `import` 或 `await`。代码直接编入一个原生 batch，不使用 `eval` 或 `Function` 构造；安装接受不证明 JavaScript 语法或运行成功，也不承诺绕过页面 CSP、sandbox 或其他引擎限制。

本包装不是不可信代码 sandbox，也不包含 JavaScript parser。origin、return 和 throw 的包装语义只约束语法有效的 ordinary function body；无效 body 可以闭合括号逃出包装，甚至让整个拼接程序仍然有效。宿主不能把未审定的外部文本视作受守卫约束的不可信脚本；接收这种输入需要将来独立的解析或隔离能力。VM oracle 特别保留了这个负例，不把字符串守卫断言当作安全证明。

每份函数体调用前，batch 都重新检查当前仍为顶层、协议为 HTTPS、实际 origin 等于其中一个规范化来源。iframe、opaque origin 和 `about:blank` 不执行函数体；不会为了它们放宽为 URL 前缀匹配。

`frames = .all` 的项去掉顶层检查，在每个 frame 中按该 frame 自己的 origin 检查；只要有一项是 `all`，Linux 就把整个 batch 注册为 `WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES`（WebView2 的脚本本来就进入所有 frame），`top` 的项仍只在顶层运行。`origins` 只写一个 `"*"`（`document_initializers.any_origin`）时去掉来源检查，任何来源的文档都运行，包括 opaque 和 `about:blank`；`"*"` 不能与其他来源并列。注意 Linux 页面默认 CSP 的 `frame-src 'none'` 与两个后端对子 frame 导航的拒绝，让子 frame 只能是同一文档创建的空白 frame。这只是用户代码的执行范围，不授予导航、TLS 例外、网络请求或 IPC。页面 world 与页面共享对象，不是隔离执行环境；可信宿主代码自行决定向页面暴露什么。

默认空表没有拥有存储、UTF-16 batch、原生 script ID 或事务簿。非空入口只在独立 noinline 栈帧捕获最多八项及每项八个来源的 slice 描述符；没有正文大小的栈副本。调用者的输入字节须稳定到入口返回。实现先复制全部正文和原始来源，再检查 UTF-8/NUL、精确来源、重复及大小，并派生 UTF-16。入口描述符即使在 caller allocator 重入时被替换，也不改变捕获的项；入口返回后可释放或修改原始存储。

创建期入口为 `Options.document_initializers` 和 `initializer_limits`。运行期 `View.replaceDocumentInitializers(entries, completion)` 成功接管 completion，返回的 `InitializerReplacement.cancel()` 只作逻辑取消。非空创建配置在首个文档导航前安装；替换只作用于未来文档。默认 View 仅保留可空 domain/controller 指针和准备期门禁位；无表不创建 initializer C 预算、候选或用户 SDK 注册。首次非空配置或显式替换建立预算域后，View 独立持有该域至 detach，清空配置也不丢失它。第一次显式替换才分配事务 controller，其独立引用覆盖 caller allocator 重入关闭 attachment；准备期门禁也挡住这种重入的新导航或第二次替换。

上限为八项、每项正文 32KiB、总正文 256KiB、每项八个来源、总原始来源 8KiB；单来源最多 1024 字节。来源沿用共享解析器规范化 scheme、host、IPv6 和默认端口。预算默认 4MiB，最多 8MiB，计算同时存活的框架拥有 owner、描述符、正文、原始/规范来源、编码 batch 和独立原生副本。旧批次、新候选和迟到原生引用共用预算，逻辑取消或 close 不提前返还尚存物理内存的额度；SDK 自有分配不在该字节计数内。准备不发生在 paint，也不启动隐式 worker。

一旦该 View 具有预算域，reload 继续使用同一域并拒绝改变 `initializer_limits`。C 域本身、Zig source/controller 记录、原生 owner/handler、encoded source 和 script ID 的请求字节均计费；C 域使用原子引用和原子字节额度，额外 COM release 不借用 Zig allocator。普通替换 revision 从 1 开始，只计接受后成功提交的替换，不是 PageId 或 SDK script ID；reload/recover 不重置替换序列。

事务至多一笔。首先保留身份，再在原生接受后接管 completion；同步失败保持调用者拥有上下文。当前导航仍在进行时返回 `Busy`，候选注册期间不允许新导航，也不制造 PageId。安装成功只影响未来文档，不能撤回当前文档已运行代码；批次 revision 独立于文档代数。park 保留已拥有配置，reload/recover 按各自拥有的配置重建。

成功的 `cancel` 撤去 completion 并只完成一次，但物理 Add 仍 pending 时继续 `Busy`。Windows Add 完成 handler 开始处理结果就是提交点；清空批次则在首个 Remove 前提交。提交后 `cancel` 返回 false，仍由该操作安装成功或失败完成一次；原生 try-cancel 握手先于 Book 撤去 completion，不能在 destructive Remove 重入时声称取消成功。提交前取消而迟到 Add 成功，仍须撤销候选 script ID；确认原生操作及其清理退休后才返还事务槽。任一 Remove 的结果不确定都挡住未来导航，并保留旧逻辑配置供显式 recover，reload 也拒绝绕过该门；已经取消的事务不能因此再回调一次。关闭先撤销入口及逻辑完成；迟到原生回调只接触独立 C 存储、script ID 和 C 预算，不访问 Zig View/App。Linux 的同步提交点与取消范围见下文。

纯簿只返回已撤出的 `Delivery`，不在内部调用业务代码。每份非空拥有存储独立 retain 预算上下文，先撤掉全部指针再调用外部分配器 free，并在 free 实际返回后归还物理字节，最后才释放自身上下文引用。即使 free 重入关闭 View，预算也不能提前销毁；空表不 retain。原生副本和 handler 同样必须独立持有 C 预算上下文，不依赖 Zig owner 仍存在。公开桥必须先完成自身状态更新与拥有责任交接，最后才调用 completion；completion 可以关闭或 reload，此后不能再访问旧 View。原生 handler 的额外引用仍可保留 C 对象及其额度，不被当作逻辑请求槽提前回收。

已完成的独立验证：拥有层和事务簿 Debug/ReleaseSafe 各 18 项纯测试；另一个 JavaScript 引擎对实际 Owned 输出执行 14 项断言，覆盖有效函数体的 return、throw、局部作用域、Unicode/末尾注释及每项 exact top/HTTPS 守卫，并关闭字符串动态 codegen，另含无效 body 逃出包装的合同负例。它不证明浏览器注入时机、真实 frame origin、CSP 或 Runtime 支持。原生 SDK double 则验证直接 NavigationStarting 门禁、初始注册先于 ready、替换/清空/取消/失败、不确定 Remove 封锁、Remove 重入取消提交点、关闭重入及实际最后引用返还额度。

真实 Runtime 的四种模式为 `exercise`、`close_pending`、`stop_pending` 和 `wrong_certificate`。主流程分别检查首文档初始化、调用者改写输入后在 completion 内 reload 已拥有配置、异源与 opaque 文档不执行、throw 中断后续、注册尚未退休时拒绝页面自身导航、取消后旧批次保持、显式 recover 重放、清空及再次替换；每份文档同时检查 no-src 子 frame 不执行和页面 `Function` 被 CSP 拒绝。受控 TLS 服务端独立要求恰好 8/1/1/0 个 HTTP 请求，原生 callback 还必须记录被拒绝的导航请求；不会仅凭页面消息判定通过。普通关闭和 App Stop 均只完成一次 detached，错误证书零业务请求，最后窗口、COM、预算字节和观察器引用归零。

运行需固定 WebView2 SDK、已安装 Runtime 与 Python 3.12+，从项目根执行；Python host 只使用标准库，TLS thumbprint 例外仅存在于独立测试对象，生产不增加证书放宽：

```powershell
zig build test-document-initializers test-document-initializers-native test-webview build-smoke-document-initializers -Dwebview=true -Dwebview2-sdk=.deps/webview2 -Doptimize=ReleaseSafe -j1 --cache-dir .zig-cache/managed/windows-validation-cache --global-cache-dir .zig-cache/managed/windows-global --prefix .zig-cache/managed/validation-out --summary all
python -B tests/windows_https_initializers_host.py --exe .zig-cache/managed/validation-out/bin/smoke-document-initializers.exe --cache .zig-cache/managed/windows-initializers-runtime --log .validation/initializers-runtime.json
```

将优化参数改为 `Debug` 重复运行同一四模式即可。host 为每模式建立精确命名的私有 Profile，失败时保留并记录 JSON；成功须先确认浏览器退出和严格请求计数，再核对解析后根目录、名称与非 symlink/junction 才清理本次目录。驱动的显式 watchdog 和浏览器等待 worker 由测试拥有，join 发生在 App.run 返回之后，库没有增加线程、UI 等待或嵌套消息循环。这些证据限已安装的 Windows Runtime，不证明未经验证引擎版本、Linux 注入能力或视觉质量。

## Linux 注册与生命周期

Linux 保留同一编译器的实际 UTF-16 输出，在原生 prepare 中严格转换为独立、计费的 UTF-8；拒绝 NUL、孤立 surrogate 和超过 512Ki 个 UTF-16 unit 的原生描述符，不以替换字符或另一套字符串模板改变程序。转换在主线程作两次有界线性遍历，UTF-8 副本最多为每 unit 三字节加终止 NUL；SDK 构造及注册也同步占用该线程，不承诺固定延迟或引擎总内存上限。prepare 完成有界捕获和全部框架分配，不调用 SDK、不接管 completion。Book 接受后 activate 创建顶层、document-start、页面 world 的 WebKitUserScript；它在第一处 Add/Remove 前提交，并用精确对象替换旧 batch。SDK source/boxed 对象的内部存储不借用 Zig allocator。

[WebKitGTK 2.40 的 manager 实现](https://github.com/WebKit/WebKit/blob/webkitgtk-2.40.0/Source/WebKit/UIProcess/API/glib/WebKitUserContentManager.cpp#L219) 已有逐对象 remove（自 2.32），add 明确不向当前文档立即注入。这两项是同步 void 接口，没有每请求异步 finish、WebProcess ACK 或原子 replace。这里的 installed 只证明本地 manager 已接受未来文档的注册集合，不能证明脚本已传至所有进程、语法有效或执行成功。导航门覆盖宿主入口、原生 policy、首次文档、refresh/history 和 recover；同一 UI 调用中的注册替换不开放中间集合给新的受控导航，也不制造 PageId。

每次导航先准备新 bootstrap；撤权和资源回调返回后，重新检查 C state、导航身份和代数，再取得当前 batch 并单独 retain。实现只逐个移除自己拥有的旧 private/public bootstrap，添加新 private/public，再将同一 batch 对象置于末尾；bootstrap 与用户初始化器不会互删，用户代码在未来文档中可见公开 bridge。旧文档已执行的代码不会因替换、清空或取消而撤回。

Linux 提交点在第一次同步注册修改之前。原生提交前取消只丢弃候选；提交后 try-cancel 返回 false。正常公开调用会在返回之前同步退休，因此返回的 replacement 通常已经不可取消；不模拟尚存的异步安装窗口。原生 source/槽先退休、拥有指针先更新，再调用 completion。completion 可以同栈再次 replace、关闭或 Stop；之后只允许独立 C pin 和预算引用收尾，不访问旧 Zig 对象。SDK 不回调该操作的 userdata，所以不存在借 View/App 等待迟到 finish 的责任。Windows 的异步 Add、迟到清理和不确定 Remove 规则仍按其自己的原生路径执行。

Linux x86_64 Debug 产物的 DWARF 实测公开 View 仍为 5024B；C State 从已有 capture 版本的 2472B 增至 2496B，增加 initializer owner 和两个 bootstrap 指针。默认没有 initializer 拥有分配；两个已有 bootstrap 的 SDK boxed 引用现在持有至下次替换或关闭，这不是 SDK 内存零成本。选配预算域 32B、原生 owner 32B、物理 operation 56B 加有界 UTF-8 副本均计费；Zig Config/Controller 沿既有记录计费。SDK 自有 script、进程副本及其内部 OOM/执行成本不受此框架字节预算约束。第一次显式失败可留下空 optional controller/owner 和已建立的预算域至关闭；它不代表整个对象逐字节回到调用前。

Linux 独立夹具使用测试自有 worker 准备私有 Profile、固定测试证书和同主循环上的双 TLS 来源服务，不修改系统证书或代理。真实 WebKitGTK 2.52.6 验证首文档 Unicode/return/局部作用域、输入拥有、旧文档保持、异源和 no-src 子 frame、throw、替换/清空后的 bootstrap、completion 同栈再替换、进程终止后的 recover/旧 PageId 失效，以及 completion 和 ready 中 close/Stop。主流程严格要求 10 份文档、10 条消息、5 次安装和服务端 8/1 次请求；关闭首 ready 的两个模式业务请求为零。每种模式均要求最后 Profile/View/initializer 责任及预算归零。C-only oracle 另覆盖严格编码、实际 malloc/calloc 失败、共享额度、初始关闭、SDK 构造失败保旧、提交点取消及 SDK 修改中的关闭。

```bash
P01_PROBE=initializers-owner P01_OPTIMIZE=Debug bash scripts/webkit-probe.sh
P01_PROBE=initializers-zig P01_OPTIMIZE=Debug P01_TLS_ROOT=/absolute/private-tls/root bash scripts/webkit-probe.sh
```

这些模式在 Debug/ReleaseSafe 中分别以 GDK_SCALE 1 和 2 各运行一次，即每种优化两次；C-only 七组也在每种优化运行两次。两个优化的 WebView 单元均为 97 通过、8 项既有跳过，纯编译器/事务簿均为 18 项。另在 recover 前独立持有旧 SDK widget 引用，核新 View 仍使用唯一预算域并最终释放测试自己的引用。不能把这个 raw SDK 引用当成第二个 C owner 必须存活的证明：[GObject 弱通知](https://docs.gtk.org/gobject/method.Object.weak_ref.html) 对应 dispose，GTK destroy 后适配层可能已退休。`zwk_counts` 的 states/views 与本夹具的归零断言只证明被追踪的适配层 owner、操作和框架预算退休；不证明所有 SDK 对象、引擎进程内存或缓存均已消失。

真实 TLS 需要可用的 GIO GnuTLS 后端；私有依赖覆盖仅通过现有 runner 的 namespace 配置，不能把缺少 TLS 后端的失败算作注入验证。最低 2.40 兼容边界来自对应 public API/源码；没有声称实际运行过 2.40 引擎或完成视觉 QA。

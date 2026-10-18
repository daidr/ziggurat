# 无页面的引擎发现

独立可选模块 `ziggurat_webview_runtime` 在 Windows 与 Linux 提供 `probe(main_thread, options)`。它不依赖 Core、UI 或 WebView 模块，不创建 App、窗口、Profile、COM apartment 或浏览器 Environment，也不调用 GTK 初始化。Windows 查询 SDK 的引擎发现结果；Linux 只查询显式 DSO 句柄解析到的库版本入口。默认自绘应用没有这项动态加载成本。其它平台返回 `UnsupportedCapability`。

调用者在自己创建的 worker 上传入实际进程主线程身份。主线程调用先返回 `UiThreadForbidden`，不读取路径、不加载库。模块不创建线程、不投递任务、不回调业务代码；宿主负责 worker 回收和通过 `App.post` 交付结果，UI 回调不能等待 worker。探测包含系统 loader、Windows 注册表与磁盘工作，可能阻塞；库没有隐式超时或重试。

```zig
// 在宿主已经创建的 worker 中执行。
const result = try runtime.probe(main_thread, .{
    .loader_path = "D:/application/WebView2Loader.dll",
});
// result 是独立值；result.version() 仅在该值存活期间借用其固定存储。
```

`loader_path` 在 Windows 必须显式指向已经部署的绝对 DLL 路径。只接受 drive-rooted 或普通 UNC 路径，不接受相对路径、drive-relative、设备路径、NUL 或坏 UTF-8。载入只使用 `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32`，不搜索 PATH 或当前目录。loader 与可选 `browser_executable_folder` 都先复制为有界 UTF-16，再执行原生调用；每条路径至多32767个 UTF-16 units。实现声明两份各64KiB的固定路径缓冲，没有调用者 allocator；这不包括系统 loader、SDK 和原生返回字符串的内部开销，也不是实测栈峰值。

Windows 返回值区分：

| 状态 | 含义 |
| --- | --- |
| available | SDK 成功发现一个引擎，并取得非空、有界 UTF-8 版本字符串 |
| runtime_absent | SDK 查询返回精确 `HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)` |
| failed | loader 加载、入口查询、其他 SDK 错误或返回值合同失败 |

Windows 失败保留 `phase`、`domain` 和原生数值，不把缺 loader 或访问拒绝说成引擎未安装。Result 自己拥有至多256字节的版本存储，移动或复制后没有自指针。SDK 返回 UTF-16 字符串至多检查512 units，空、过长或坏编码均失败；原字符串始终经 `CoTaskMemFree` 释放，最后释放本次 loader 引用。成功或失败都不保留模块级缓存或全局 allocator。

Windows 取消是显式原子标记，只在系统调用前后检查，不能抢占一次系统 loader 或 SDK 查询。调用者保持路径到复制结束、取消对象到函数返回的寿命。探测成功只说明当时的发现结果；不保证随后 Environment 创建成功、Profile 可写、权限已授予，或指定目录最终被使用。SDK 的环境和系统策略覆盖仍生效，并可能选择带 Beta/Dev/Canary 后缀的引擎。[SDK 查询合同](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/webview2-idl#getavailablecorewebview2browserversionstring) 定义这些覆盖、未找到错误和字符串释放责任。`backendCapabilities()` 继续只描述框架适配器已实现的能力。

`zig build test-webview-runtime` 运行路径、线程入口、拥有型版本、错误分类与清理故障测试，无页面。Windows 的独立 harness 通过 `zig build build-smoke-webview-runtime` 构建，再传入 loader 的绝对路径执行。它查询引擎九次，验证每次 loader 引用释放、预热后进程 handle 数不增长、最终无存活子进程，以及缺 DLL 与缺导出入口的差别。查询成功不等于页面初始化验收。

## Linux 显式库版本

Linux 的 `loader_path` 是至多4095字节的绝对 POSIX UTF-8 DSO 路径，拒绝空路径、相对路径、NUL 和坏编码。实现先捕获到4096字节的带终止符栈缓冲，再加载；不做独立 stat/open/realpath 预检，也不要求 `.so` 后缀，允许版本化的库文件。`browser_executable_folder` 非空时返回 `UnsupportedOption`，而且先于读取路径字节；null 和空 slice 都不选择浏览器。主线程拒绝、已取消、此选项拒绝、路径捕获按这一次序执行。

```zig
const result = try runtime.probe(main_thread, .{
    .loader_path = "/deployed/lib/libwebkit2gtk-4.1.so.0",
});
if (result.status == .available) {
    // 本次显式加载句柄解析到的库版本；没有创建或验收 Runtime。
    consumeVersion(result.version());
} else {
    // diagnostic() 是原始字节，不保证 UTF-8；输出时按宿主诊断策略编码。
    consumeFailure(result.failure.?, result.diagnostic());
}
```

实现只使用 libc/libdl，生产模块不链接 GTK/WebKit。`dlopen` 采用 `RTLD_NOW | RTLD_LOCAL`，随后在调用任何 getter 前解析全部 `webkit_get_major_version`、`webkit_get_minor_version` 与 `webkit_get_micro_version`。每个 `dlsym` 都先清 dlerror、查询、再立即检查并拥有诊断；null 地址但没有 dlerror 另作不可调用入口的合同失败。三个 unsigned 返回值格式化成 major.minor.micro，不读取编译期版本宏。[2.40 getter 源码](https://github.com/WebKit/WebKit/blob/webkitgtk-2.40.0/Source/WebKit/UIProcess/API/glib/WebKitVersion.cpp#L68)与[2.52.6 getter 源码](https://github.com/WebKit/WebKit/blob/webkitgtk-2.52.6/Source/WebKit/UIProcess/API/glib/WebKitVersion.cpp#L68)都只返回库内常量，不调用 GTK 或 WebKit 初始化。

Linux 的 available 只表示该显式句柄解析到了三个版本入口并返回数值；`dlsym(handle, name)` 也搜索该库的依赖作用域，所以入口不一定由目标文件本身定义。这不认证库身份，不证明最低适配版本、显示服务器、引擎辅助程序、Profile 权限、View 或页面可用。绝对目标路径不会限制传递依赖的 RUNPATH、`LD_LIBRARY_PATH`、系统缓存和宿主 loader 策略。不要把某个错误文本、可加载库或构建时头版本当作 Runtime 可初始化。

Linux 所有原生失败均为 failed，不返回 runtime_absent。Failure 保留 phase/domain；`dynamic_loader` 的 code=0 表示此 API 没有可移植的数值错误码，不能冒充 errno。诊断保留 dlerror 原文字节前缀，不解析文本分类。`contract` code1 表示没有 dlerror 的 null 入口，code2 表示数值版本格式化失败。找不到文件、依赖缺失、符号缺失和加载格式错误均保留实际阶段。

Linux Result/Failure 与 Windows 使用独立类型分支；跨平台调用只依赖 status、failure 和 version() 的拥有型语义，不将平台布局当序列化协议。Linux 的单一256字节 payload 在成功版本和失败诊断之间复用，failed 的 version() 为空。`failure.diagnostic_truncated` 明示前缀是否截断。若主失败后 dlclose 也失败，`cleanup_failure` 与 `cleanupDiagnostic()` 保留第二错误，两份诊断各至多128字节并各自标记截断；没有第二个大数组或调用者 allocator。当前 x86_64 实测 Linux Result=288字节/align4、Failure=8/align4；旧/新 Windows Result均272/align4、Failure均8/align4、Options均40/align8，字段偏移和既有枚举值一致。Linux 固定 Result 成本增加16字节，Windows 不增加。

每次成功 open 后只尝试一次 close；取消和缺入口也走同一清理点。成功 close 以后最终取消可以返回 Cancelled；如果 close 失败则优先返回 failed/release_loader，避免取消吞掉释放失败，不循环重试，也不声称该引用已经归零。主错误和清理错误同时出现时两者均保留。原生调用不能被标记抢占，没有隐藏超时、回滚或等待 UI 的路径。

加载会执行 DSO 及传递依赖的构造器。已检2.52.6产物含静态资源注册、元数据和析构登记；系统 loader/SDK 仍可分配、登记全局状态，不能把本模块4KiB路径缓冲和288字节 Result当 SDK 内存上限或实测栈峰值。[dlopen/dlclose](https://man7.org/linux/man-pages/man3/dlopen.3.html)的引用计数不保证立即 unmap、撤销所有登记或归还 RSS；其它代码已经持有该库时，本次 close 后库仍存在不等于引用泄漏。调用者必须信任这条可执行代码路径。

`zig build smoke-webview-runtime-linux` 在无 App/页面的独立 harness 验证4个版本夹具 DSO 和一个受控缺依赖 consumer：三个单独缺入口、先解析全部再调用、拥有型结果、外部持库与构造器中的取消。consumer 的唯一依赖保留在构建目录且不安装，没有 RPATH/RUNPATH。`--` 后可给真实 DSO 路径，另可用 `--failed-load <绝对受控consumer路径>` 验证缺依赖；harness 不运行编译器或创建缺库状态。`build-smoke-webview-runtime-linux` 只安装程序/夹具；`build-webview-runtime-linux-oracle` 构建独立 C worker 三 getter oracle。真实探测只验证所选句柄版本；没有运行 GTK 初始化、浏览器或视觉 QA。

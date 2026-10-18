# 图片解码与交接

独立模块 `ziggurat_images` 在调用者创建的后台线程同步解码内存中的 PNG、JPEG、BMP、首帧 GIF，以及显式启用的静态 WebP。默认 UI 与核心均不导入它。Windows 的前三种格式使用系统 WIC，Linux 使用显式 PNG/JPEG/BMP GdkPixbuf loader；GIF 使用有界 Zig 解码器，WebP 使用可选的固定版本 decoder。没有文件读取、网络、隐藏线程或自动投递。

`Worker.init(process_main_thread_id)` 拒绝主线程；同一 worker 线程调用 `decode` 和 `deinit`。输入只借用至 `decode` 返回，成功返回稳定地址的拥有型 `*Image`，像素为从上到下的 straight RGBA8。JPEG 按 EXIF 1–8 方向变换；没有有效方向元数据时按编码方向输出。PNG 只取静态默认图像，不提供动画时钟或多帧接口。色彩管理/HDR、增量解码和多帧播放仍待实现；显式 GPU 上传由独立绘制模块提供。

BMP 只接受独立 `BM` 文件与已知的 12/40/52/56/108/124 字节 DIB 头。预检文件长度、保留字段、像素偏移、调色板、DWORD 行对齐和完整像素容量。支持 RGB、相应 4/8-bit RLE 和 16/32-bit 通道位掩码；拒绝嵌入 PNG/JPEG、未知头、重叠/不连续掩码与 top-down RLE。`BI_RGB` 的未使用字节和调色板保留字节统一视为不透明；显式 alpha mask 按原始整数通道归一，避免系统 codec 对 alpha 的不同解释。已列头类型不表示每种子组合均经过原生运行，真实夹具范围见下方。

GIF87a/89a 返回逻辑画布上的第一个 raster graphic，画布先清为透明，图片矩形外以及透明索引处保持 RGBA 全零；不使用逻辑背景色合成，不执行后续 disposal 或动画。支持全局/局部调色板、交错行、透明索引、comment/application extension。plain-text graphic 和未知 extension 明确拒绝。只扫描并解码第一幅图的有界 subblocks，后续帧不参与分配或验证，因此此接口也不是完整 GIF 文件校验器。LZW 使用固定 4096 项字典和 4096 字节展开栈，支持字典增长、满字典延迟 clear 以及 KwKwK 特例；要求首个 clear、完整像素数和结束 code。没有按动画帧数分配内存。

WebP 默认不链接 codec，`capabilities.webp == false`，输入返回 `UnsupportedFormat`。在 Windows 运行 `scripts/fetch-webp.ps1`，Linux 运行 `sh scripts/fetch-webp.sh`，再使用 `-Dwebp=true`。脚本从官方 release 地址下载 libwebp 1.6.0，校验 SHA-256 `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`；普通 build 不访问网络或运行 configure。decoder-only 源与依赖许可放在 `.deps`，构建不加入 encoder/demux/mux/工具。分发开启该功能的二进制时，保留安装到 `share/ziggurat/libwebp` 的 COPYING/PATENTS/AUTHORS；宿主自行打包时同样包含这些文件。

WebP 支持静态 VP8/VP8L/VP8X alpha，先验证 RIFF 长度、每个 chunk 及 padding，再用 `WebPGetFeatures` 预检并核对实际解码尺寸。动画明确返回 `UnsupportedAnimation`；ICC/EXIF/XMP 不改变颜色或方向。依照[上游解码 API](https://developers.google.com/speed/webp/docs/api)，输出直接写同一个调用者像素平面，内部 codec 工作内存另计。上游内部 worker 在编译时关闭，解码配置也明确 `use_threads=0`；固定版本的 DSP 表先由一次性初始化同步发布，之后多个应用 worker 可并发解码，不为每次 decode 加全局串行锁。不公开内部 dispatch/worker 修改入口，也不支持在同一进程另行修改这份嵌入 decoder 的全局表。

编码输入最多 32 MiB，单边最多 16384 px、像素最多 16 Mi、解码像素最多 64 MiB。`DecodeOptions.limits` 只允许降低这些上限。预检 PNG IHDR、JPEG marker/segment 和 EXIF 偏移、BMP 头/像素范围以及 GIF 画布/首图/调色板/subblocks，在输出分配和原生解码前拒绝越界尺寸；原生 decoder 再核对容器和实际尺寸，损坏数据返回 `InvalidImage`。JPEG 转向临时拥有两份像素，Zig 像素峰值最多 128 MiB，另有系统 codec 的工作内存；GIF 只需要一份像素画布和固定约 16 KiB 解码栈。上限不等于整个进程内存配额。

`Worker.last_failure` 只保留本次解码实际报告的 HRESULT、GError 的 domain/code 或 WebP status，在 native 清理之前捕获；本地头部/预算/取消拒绝不带伪造原生码，也不会沿用上次错误。原生 API 报告可恢复的内存不足时返回 `OutOfMemory`；系统库内部缓存、codec 内部 malloc 与进程级致命分配策略不属于 Zig allocator 的故障注入范围。`nativeReferences()` 记录适配器自己持有的 worker/COM/loader 引用，不计 codec 内部临时对象；解码返回后只剩 worker，worker 关闭后为零。

取消通过调用者持有的原子 `Cancellation` 请求，在进入原生解码前、返回后和发布结果前检查。BMP alpha 归一每 32 行检查，GIF 每个 LZW code 检查。系统同步解码调用内部不能被抢占；超时、线程 join 和关闭策略由宿主安排。取消或任何分配失败都不发布部分 Image。

Worker 创建的 Image 初始属于 worker。通过成功的 `App.post` 把其指针交给主线程；失败 `Full/Closed` 不转移所有权，仍由 producer 关闭。producer 移交后停止访问，主线程调用 `image.adopt()` 完成独占交接。该模块不引用 App，投递结构和并发同步由宿主显式提供。allocator 必须覆盖 Image 的完整寿命并允许转交后的线程释放；原生解码资源在 `decode` 返回前已释放，因此 worker 可以先关闭。

`image.pixels()` 返回直到关闭前有效的只读借用；不要复制拥有型 Image，也不要在 producer 和接收方同时访问。`close` 要求 owner 线程且公共绘制 `Lease` 无 pin，否则返回 `WrongThread/ResourceInUse`；adopt 同样拒绝仍有 pin 的交接。释放前先关闭入口，foreign allocator 析构回调重入查询/关闭返回 `Closed`。最终关闭之后指针不可再使用。

`zig build smoke-images` 在 Windows/Linux 无窗口运行真实 Worker，检查 PNG alpha、JPEG、全部 EXIF 方向，BMP 24-bit/top-down/32-bit unused alpha/565/palette/RLE8/V4 alpha/CORE，GIF 局部调色板/交错/偏移/透明、12-bit 字典/延迟 clear/KwKwK/动画只取首帧，以及损坏输入、容量拒绝、取消、逐分配 OOM 回滚、独占交接和提前关闭。GIF 与独立 literal RGBA/Pillow 编码的 oracle 比较，手工延迟 clear fixture 也由 Pillow 反向验证。纯头部测试覆盖畸形偏移/调色板/尺寸/截断和随机变异。独立可选的预乘/crop/mip 准备、Frame 图片与三后端显式驻留见[图片绘制](image-drawing.md)；解码本身不自动上传或绑定窗口。

`zig build smoke-images -Dwebp=true` 还检查有损/无损与 alpha 的独立 Pillow RGBA oracle、四个 worker 同时首次解码、RIFF 逐前缀截断、动画拒绝、实际失败 status、取消和全部 Zig allocation 故障回滚。默认关闭时实际检查明确拒绝。Windows/Linux 均执行同一固定源码 decoder；这些检查不证明人工视觉质量或整个 codec 内部内存配额。

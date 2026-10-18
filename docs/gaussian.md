# 已合成子树的高斯滤波资源

可选模块 `ziggurat_gaussian` 只依赖标准库和 `ziggurat_drawing_resources`。它读取已有的预乘 BGRA8 `ImageView`，显式准备滤波结果；不创建窗口、原生对象、线程、任务、计时器或事件循环。普通 Context 不导入或初始化滤波器，也不预留额外工作面。

一个完整的子树准备链是：现有 `commands.Buffer` → `ui.offscreen.Surface.render` 的透明 `Snapshot` → Gaussian Work → 已准备图片 → 原有上传和 `Frame.image`。这样重叠子项先完成 source-over，之后才滤波。它与逐个模糊子项后再合成不同，也不等于单色 A8 阴影。

本片提供显式准备的视觉资源，不会自动捕获既有 Frame/widget 分支。命中、焦点和可访问性几何仍由调用者原有布局拥有；滤波光晕不会扩展业务命中区域。实时 Frame 模糊 scope、GPU 两遍滤波、backdrop 捕获与自动场景失效不属于本片。

## 显式准备与 worker

```zig
const processor = try gaussian.Processor.create(allocator, owner_thread, .{});
// Processor 必须覆盖全部 Work 和 Prepared；allocator context 更长。
const work = try processor.capture(try snapshot.view(), .{
    .sigma = 4, // DIP 标准差
    .scale = scale,
});
// 宿主可以在自己管理的 worker 调用 work.run()。
// run 返回后，仍须在 owner 调用 work.finish() 或 work.close()。
```

`capture`、`finish`、`close` 和结果访问需要 Processor 的 owner 线程。`capture` 在首次调用外部分配器前校验完整图片描述，并取得原 source Lease pin；复制 base-level 描述，不把 worker 指向调用者临时描述。完整 mip 存储会被这份 Lease 保留，虽然非零滤波只采样 level 0。

`capture` 显式分配结果壳、输出像素和横向 scratch，并准备有限 kernel。worker 的 `Work.run` 只读取固定的原像素与 kernel，写入候选和 scratch；不调用 allocator、Lease、App、Window 或 native API。宿主必须保证原图片符合不可变、预乘 BGRA8 的 ImageView 合同，不能在 pin 期间修改其描述或像素。`TextureView` 没有 CPU 像素，不能传入，也不会触发同步 GPU readback。

一个 Processor 最多持有一个物理 Work。Work 是线性能力；复制不产生另一份执行或关闭责任。serial 与 phase/cancel 在同一个原子字中授权，代数不回绕，旧 Work 不能取消或执行复用槽中的新工作。worker 完成使用 release 发布；owner finish 使用 acquire 观察全部候选。worker 在终态发布后不再访问共享状态。

`run` 成功或报错都只表示计算已结束，物理责任尚未回收。`finish` 的 `NotReady` / `Busy` 保留 Work；终态成功、`Cancelled` 或计算错误消费 Work。`close` 可放弃尚未执行或已完成的 Work，运行中返回 `Busy`，不等待。`Processor.close` 在仍有 Work 或 Prepared 时返回 `Busy`，调用者先显式收尾。

宿主负责线程、唤醒、交接和 join。若通过 `App.post` 交回 owner，`Full` / `Closed` 不转移 Work 责任，宿主保留上下文以便重试或由 owner 清理。本模块不阻塞 UI 等待 worker。Processor 不自动注册 App Stop；停止时宿主可以请求取消，并在 worker 终态后完成 owner 清理。CPU 资源不借用 App，仍可在 App 关闭后收尾。

`Work.cancel` 可以跨线程调用，使用带 serial 的原子授权。`Options.cancellation` 是可选、显式借用的协作 flag，存活期覆盖 Work；capture 在分配返回后及发布前检查，worker 在有限像素块和末尾检查，finish 在临时析构返回后检查。flag 的检查点不是抢占屏障；`Work.cancel` 还与 finish 最终提交 CAS 串行化。无论使用哪种方式，已发布结果不会因之后的取消被撤销。

## 像素、透明外延与 placement

输入格式由现有 `ImageView` 类型限定：top-down、预乘 BGRA8、合法 mip 描述。它不是 straight RGBA 接口，不会再次 premultiply 或解预乘，也不会把透明像素里的隐藏 straight RGB 带入滤波。

`sigma` 是非负有限 DIP 标准差，`scale` 支持 `[1/16, 16]`。物理标准差为 `sigma * scale`，半径 `R = ceil(3 * sigma_pixels)`，最大 128 px，超出明确拒绝。有限离散 kernel 在整数 `[-R,R]` 取高斯权重并归一化。没有静默降采样、box-filter 替换或数值 epsilon 模式切换。

横向与纵向分别对预乘 B/G/R/A 使用相同权重，每遍输出 round/clamp 到 BGRA8。因为权重非负且量化单调，合法输入的 RGB 仍不大于 alpha。这是既有 encoded RGB 约定下的卷积，不是 linear-light 滤波。相对于只在最后量化一次的直接二维卷积，两遍中间量化允许最多一字节差；该差别不用于放宽边界、坐标或源合成语义。

输入以外恒为透明黑，不 clamp/repeat/mirror。输出宽高分别增加 `2R`；`Prepared.stats().placement` 为 `(-R/scale,-R/scale)` DIP，放置时相对输入原点加这个偏移。输出按同一 scale 使用自然尺寸，光晕属于图片内容。尺寸、字节和算术溢出在分配前拒绝。

子项自己的 clip、opacity、mask 已经进入源合成。父级 clip、整体 opacity/mask 应在滤波结果回放时一次应用。不能为了省源面积而先裁成父 clip 的可见矩形：该矩形外的源像素可能经 kernel 影响内部。既有普通透明组只按父 clip 的整数 bbox 限制工作，不能直接当作带正确 halo 的模糊组。

零 sigma 使用原 ImageView 的 passthrough：原 identity、Lease、levels 指针和 mip 内容不变；没有 kernel、输出像素、scratch 或 filter samples。仍有显式结果壳及一份原 source pin。关闭这个壳只释放自身 pin，已记录 Frame 或已上传驻留各自持有原 Lease，不依赖壳的存活；不会仅为包装创建新的 native 图片身份。

非零结果拥有独立像素、一个新且不回绕的 raster identity 和自己的 Lease，只有一个 mip。finish 完成临时析构并通过最终状态/取消门后才发布；失败不发布候选，原图片不变。源 pin 穿过 capture 回滚及 finish 的最后外部析构，完成后在 owner 释放。源 Snapshot 在这些 pin 期间不能 close；其 Surface/App 可以先关闭，因为 Snapshot 已独立拥有 CPU 存储。

非零 `Prepared.close` 在 Frame/residency 借用存在时返回 `ResourceInUse`。关闭先撤可读存储并标记 Closed，再调用外部 free，结果自身的 view/stats/close 重入返回 `Closed`。Processor busy 门覆盖全部外部清理，防止重入开始新候选或关闭其账户。非零结果不再依赖源，但仍须先于 Processor.close 关闭。

## 统一预算

默认 `Limits.bytes=64MiB`，硬上限 256MiB；单个 Processor 的额度包含自身固定状态。默认 `filter_samples=128Mi`，硬上限 1Gi。源和输出仍受公共 ImageView 的尺寸、像素、mip 和 byte_len 界限约束。没有配置外的无界结果池：所有仍存活的 Prepared 与当前唯一 Work 累计到同一账户。

令源宽高为 `Ws,Hs`，展开后为 `Wo=Ws+2R, Ho=Hs+2R`，`K=2R+1`：

- 输出像素：`4*Wo*Ho` bytes。
- 横向 scratch：`4*Wo*Hs` bytes。
- 预检 kernel visits：`K*(Wo*Hs + Wo*Ho)`，包括透明越界位置的检查。一个 visit 处理四通道，不是标量 FLOP 数或实测时间。
- kernel、Work、Processor、结果壳和计数器的固定大小进入字节额度。

在首次候选分配前预检：`旧结果实际拥有存储 + Processor 元数据 + 新候选/临时存储请求 + 全部借用源的完整 byte_len`。零 sigma 结果继续保留原 source mip 存储，直到它关闭。若源本身也是本 Processor 的旧结果，保守 reservation 可能重复计入同一物理存储；不把它伪报为实际拥有量。

`owned_current/owned_peak` 只计本模块成功取得的实际 allocations，OOM 不虚增；`requested_current` 计当前已预留的本模块存储请求；`borrowed_source_bytes` 计 Lease 保留的外部完整源 payload；`reserved_current/reserved_peak` 是二者合计的保守额度。外部分配返回时业务 stats 被 busy 门挡住，正常观察点的实际数值保持一致。所有算术和剩余额度检查先于 allocation。

该预算不是源对象的物理配额或总进程 RSS，也不包含后续窗口 front/work、图片/A8 驻留、系统字体或 GPU driver 内部存储。原图片和新的滤波结果须在宿主发布新业务 view 前同时存活；宿主还应按既有 workspace/image aggregate 预算上传。失败保持原业务 view，不假称跨软件/GPU上传原子。绘制和设备恢复复用既有图片协议，不重新执行高斯或业务 draw。

## 验证边界

纯测试使用独立直接二维高斯 oracle，检查合成重叠输入、透明与半透明颜色、展开边缘、量化误差、零 sigma 原资源身份、旧结果与全部 mip 保留预算、旧 Work 代数、实际 worker、全部分配失败、取消和最终 free 重入。它们不证明三后端原生回放、设备恢复或 UI 命中集成；这些需要独立的 Snapshot → 滤波 → 上传/回放夹具。

性能测量须将源子树合成、capture/候选分配、worker 卷积、owner finish、native upload、warm replay 和 end/CPU submission 分开。kernel visits 是预检工作量，不是刷新率承诺；本片尚未发布性能结果。

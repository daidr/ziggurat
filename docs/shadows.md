# 阴影与共享覆盖资源

`ziggurat_shadows` 显式准备圆角矩形的 outer/inset 阴影 A8 快照。准备、上传和绘制是三个独立阶段；普通 paint 只借用快照和已有 native 资源，不生成模糊、分配像素平面或创建 worker。

```zig
const shadow = try shadows.PreparedShadow.create(allocator,
    .{ .width = 240, .height = 120, .radius = 16 },
    .{ .offset = .{ .x = 0, .y = 4 }, .spread = 1, .sigma = 4 },
    .{ .main_thread = main_thread, .scale = scale });
const view = try shadow.view();
try context.uploadCoverage(view); // 更新/布局阶段，paint 外
// draw 中：try frame.coverage(.{ .x = 20, .y = 20 }, view, rgba);
// 最后：先 releaseCoverage(view.identity)，再 shadow.close()。
```

`PreparedShadow` 是稳定地址的 owning 对象，关闭后不能使用它或未固定的 view。准备可在显式 worker 独占运行；成功交接后，由 `PrepareOptions.main_thread` 指定的线程调用 `adopt()`，之后才能从该线程取得 view。模块不启动线程，不验证调用者传入的线程 ID 是否确为进程主线程；宿主负责传入 App 所在线程。主线程直接准备的对象已经 adopted。输入几何被复制，结果独立于调用时的临时值。

`close()` 在 Frame 或 renderer 仍固定资源时返回 `ResourceInUse`。Frame 的临时 pin 保留到本次所有回放结束，包括软件后备、失败帧和绘制回调中的关闭。显式上传的 native 驻留另有 pin，必须 release/evict/renderer.deinit；关闭窗口时 Context 完成释放。不可复制 owning 状态或在 pin 存在时修改像素和 descriptor。

## 几何与滤波

尺寸、圆角、offset、spread 和 sigma 都以 DIP 表示，scale 是准备目标的物理像素/DIP。圆角表示外轮廓半径并限制到半个短边。outer 的正 spread 扩大 caster，inset 的正 spread 缩小内部 hole；offset 平移 caster/hole。负 spread 反向作用，退化到空的 caster/hole 仍有确定结果。

每个圆角轮廓用固定 4×4 子像素覆盖准备。滤波是明确的离散 Gaussian：物理 sigma=`sigma*scale`，半径=`ceil(3*sigma*scale)`，权重在该有限核内归一化；水平和垂直两 pass 分别舍入到 A8。这不是无限支撑的连续 Gaussian，也不承诺与其他系统模糊 API 的边缘逐像素一致。

outer 结果为 `blur(caster) * (1-original)`，inset 为 `original * blur(1-hole)`，乘法在 A8 域舍入。outer 不覆盖原形内部，inset 不越过原形外部。颜色独立于 mask，可复用同一快照绘制不同 RGBA。透明度在回放时乘 coverage，并对当前不透明窗口平面执行 source-over。当前窗口目标仍是不透明平面；本模块没有通用透明离屏、组 opacity、任意内容 blur 或背景采样能力。

Coverage 原点是相对准备几何原点的有符号物理像素坐标，view 同时保留 scale。`Frame.coverage(origin, view, color)` 的 origin 是 DIP，加上 Frame 的当前 offset；不会平移业务几何或重建 mask。scale 必须与当前 Paint 完全一致，否则返回 `CoverageDpiMismatch`。DPI 变化后由宿主重新 prepare/upload，不在 draw 自动重采样。分数平移使用双线性 A8 采样，边界最多有 native 采样/裁剪的像素舍入差别。

## 有界成本与取消

`PrepareOptions` 的默认 peak bytes 为 64 MiB、filter samples 为 128 Mi 次。bytes 最大 256 MiB；输出 `stride*height` 最大 16 MiB，单边最大 16384，stride 四字节对齐。物理滤波半径最大 128；超限返回 `CapacityExceeded`，不退化成其他模糊。较大阴影须由应用减少尺寸/sigma，或使用未来的显式分块设施。

准备先验证所有尺寸、转换、bytes 和滤波工作预算，再分配 State、输出和两个 scratch plane。公开 `Stats.bytes` 是保留 State+输出；`peak_bytes` 还包括两个 scratch 和固定权重表；`filter_samples` 为宽×高×核长×2，不包含轮廓与最终乘法遍历。准备时间随该工作量增长，调用者不能把高预算 prepare 当作低延迟 UI 操作。当前全平面准备不按后续 clip 缩小预算。

`cancellation` 是调用者拥有的 `std.atomic.Value(bool)`，必须活过 create。入口、分配后的行/列块、两次滤波和输出阶段以 acquire 检查它；失败释放全部候选存储，不发布部分 Prepared。检查之间仍会完成有界的采样工作，native 上传本身同步且不可抢占。`Stats.elapsed_ns` 仅计 create 中的准备时间，不包括排队、上传或显示。

## Coverage 上传与共享缓存

`drawing.CoverageView` 是独立于文本、path、阴影生产者的纯数据 ABI：稳定 Lease、唯一 identity 和 A8 `Coverage`。所有栅格生产者通过 `reserveRasterIdentity()` 取得同一进程内、不回绕的非零 identity。调用者不能用已有 identity 表示新像素版本。

GDI 的静态 `uploadCoverage` 只验证；回放直接读取 CPU 快照，无 native 上传或跨帧驻留 pin。Cairo 显式创建 A8 surface+pattern，D2D 显式创建 A8 bitmap；回放只查找已有 identity，不自动上传或淘汰。native 丢失时保留 CPU descriptor/lease，在设备恢复时重建有界驻留集合；恢复成本由 coverage stats 单独计数。关闭或 release 先释放 native 对象，再释放 CPU pin。

图片和 Coverage 合计最多 **32** 个驻留槽，并共享同一个字节预算。`setRasterBudget` 与兼容的 `setImageBudget` 修改同一预算；`RasterStats` 给出总项数、总 bytes、budget 和候选 peak。ImageStats 与 CoverageStats 分别记录自己实际发生的操作，不表示两份独立预算。GDI 静态图片/覆盖不占槽，GDI dynamic 图片仍占显式元数据槽。

Coverage 的 GPU 驻留按 `(width+2)*(height+2)` A8 计费：显式 upload/device restore 给四周加入一像素透明 halo，保证边缘非零的 mask 做分数平移时也以透明外延双线性采样，不能依赖 FillOpacityMask 的边界 clamp。原 CPU view、identity 和维度保持不变。候选构造时临时分配同样大小的有界 padding plane，创建 bitmap 后立即释放；`CoverageStats.native_scratch_peak_bytes` 单独记录其实际峰值，不计为已驻留 bytes。正常命中回放没有这个分配。加 halo 后的尺寸仍受 native 最大 bitmap 尺寸限制，超限明确上传失败。

Cairo 对未四字节对齐的外部 stride 在显式 upload 创建对齐副本，按 `max(source_stride, aligned_width_stride)*height` 保守计费。内置 path/shadow 已四字节对齐，无该副本。数字是受控像素 payload，不能代表 driver/COM/Cairo 元数据或系统实际显存。静态图片计一份 BGRA/mips，dynamic 图片计两 bank；不会给 Coverage 分配动态 bank。

候选 native 完整创建成功后才按共享 LRU 淘汰和提交；失败保持旧驻留、预算和 leases。候选与旧驻留可能短时并存，像素计费峰值不超过两倍已配置预算，另加有界 native metadata。LRU 只在显式 upload/budget 操作淘汰，draw 命中仅更新固定 metadata。跨 software/GPU 的 Context 调用是分别提交，GPU 失败可能保留 software 的成功驻留，调用者可重试或显式 release。修改这些资源前 Context 先取消旧 GPU ready wait。

`Buffer` 对 Coverage 另有 32 项 frame 表，按 lease 去重，追加失败不增加 pin 或部分写命令；这些 frame 表不是 native 缓存槽。64-bit 共享缓存固定 metadata 为 5104 bytes，Frame Coverage 表另占约 1.8 KiB，native 的每槽 descriptor/指针表也固定预留。这些成本不随历史资源数增长，不引入首次 paint allocator。旧 `replay`/资源入口保持可用，缺少 Coverage 表时明确返回 `MissingResources`。`replayBuffer` 自动带齐资源表。

## 验证边界

`smoke-coverage` 实际运行 GDI、硬件/WARP D2D 和 Cairo：outer/inset、曲线/arc/复合洞和描边 A8，1×/1.5×/2× DPI、RGBA、分数平移、clip、非对齐行填充，逐物理像素与准备快照的 source-over oracle 比较。它还覆盖共享 LRU32、混合图片预算、候选部分失败、原 dynamic transition 重试、资源表满/重复借用、失败帧、callback 内关闭、GPU wait 关闭及设备恢复。原生对象创建数在热回放保持不变，结束后归零。

这些隐藏窗口/读回检查验证数据路径与资源契约，不建立视觉质量、显示延迟或任意阴影持续帧率保证。通用 offscreen 与组 opacity 仍需要独立的显式 workspace、透明 target 与 frame rollback 契约，尚未由此切片实现。

## 准备、上传与回放测量

固定 fixture 为 256×128 DIP、圆角 16、sigma 0/4/12；主线程 page allocator 显式准备取 9 次中位数。上传测第一次 native 构造，热回放取 9 样本×3 次命令的中位数，排除 begin、清背景、上传与 end。全部原始汇总、环境、命令和源码 hash 见[测量数据](shadow-performance.json)。

2026-10-16，Ryzen 7 9800X3D、Zig 0.15.2 ReleaseSafe：Windows 准备在 1× 为 0.714/2.198/7.097 ms，2× 为 2.715/13.959/54.741 ms；GDI 热回放分别为 0.139/0.213/0.373 ms 与 0.550/0.842/1.487 ms。WSL Ubuntu/Cairo 准备为 0.401/1.788/6.561 ms 与 1.407/12.275/53.174 ms，热回放为 0.004/0.009/0.019 ms 与 0.017/0.038/0.084 ms。这些数据说明大 sigma/高 DPI 准备应由宿主放到显式 worker，不能在 draw 重做。

Windows 硬件模式第一次 A8 上传约 0.257–0.467 ms，WARP 约 0.037–0.221 ms。GPU 的热 replay CPU 命令记录约 0.7–1.0 μs，end/present CPU 提交约 53–180 μs；它们不表示 GPU 执行时间或显示延迟。硬件、WARP 和 Cairo 的 adapter native 对象分别稳定为 1/1/2，热回放无新增创建；9/9 次 end 被接受。此处隐藏窗口和离屏目标不建立可见帧率保证。

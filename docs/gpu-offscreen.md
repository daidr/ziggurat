# 拥有型 GPU 离屏资源

Windows `-Dgpu=true` 的 `ui.gpu_offscreen.Surface` 在显式 DeviceDomain 中创建固定尺寸的透明目标。它直接回放现有 commands.Buffer，使用同一 D2D renderer、文本布局、图片、A8、渐变与分组实现；不创建 HWND、swapchain、ready HANDLE 或 CPU 像素平面。默认 Context 不创建此对象。

可选 `Options.transform_source` 显式预留仿射子面池及独立命令 descriptor 表，源大小使用 DIP。池大小、透明 guard、混合嵌套和采样规则见[仿射回放](affine-rendering.md)；未启用时保留原有工作面公式和成本。启用后，workspace reservation 按窗口 front/work 加最大子面池计算，descriptor 表纳入 metadata，`render_work` 硬上限为512Mi。render 在任何外部分配前独立捕获、校验并复制变换 descriptor，不借用源 Buffer 的可变表。

```zig
const surface = try ui.gpu_offscreen.Surface.create(domain, allocator, .{
    .size = .{ .width = 256, .height = 128, .scale = 1 },
    .max_depth = 2,
    .resident_bytes = 0, // 无 CPU 图片/A8 上传时可以不预留驻留空间
});
defer surface.close() catch unreachable;
var buffer: ui.commands.Buffer = .{};
defer buffer.reset();
try buffer.roundedRect(.{ .x = 8, .y = 8, .width = 200, .height = 96 }, 8,
    .{ .r = 40, .g = 100, .b = 220, .a = 128 });
try surface.render(&buffer);
const texture = try surface.snapshot();
defer texture.close() catch unreachable;
// 同 Domain 的窗口 Frame 可借用：
// try frame.texture(destination, try texture.view(), .{});
```

所有操作在 App owner 主线程。Surface 和 allocator context 覆盖其 close；快照 Texture 使用 Domain 的 allocator，后者覆盖 Domain 及全部 Texture 的回收。Surface、Texture 和 renderer attachment 全部释放后才能 Domain.close。不要复制拥有对象；公开对象是稳定 opaque 指针，视图按 Lease 借用。

## 渲染与导出分开计费

create 一次准备透明 front/work 和最多四个 group 平面；透明根不占用 group 深度。render 在固定 work 平面回放，成功 EndDraw、owner/phase/代数复验后才以无分配交换提交 front。普通 render 不分配 Zig 存储、bitmap 平面、纹理 slot 或输出壳；几何缓存首次 miss 与 legacy 文本的系统 shaping 成本仍与现有 renderer 相同，不宣称系统内部零分配。PreparedText 使用已经拥有的系统布局。

snapshot 是单独的显式成本：占用一个 Domain 固定 slot，分配独立 bitmap，并从已提交 front 复制。两张 bitmap 均来自同一 D2D device；它们不共享可修改的像素存储。下一 render、work/front 轮换和 Surface.close 都不修改旧 Texture。支持同 Domain 旧快照作为下一次 render 的输入；它与当前 work 没有别名。未成功 render 时 snapshot 返回 NoFrame。

导出是预乘 BGRA8、一个 mip，宽高为物理像素；调用者给 Frame.texture 的 destination 使用 DIP。支持 nearest/linear；非1×1快照未提供 mip_linear 链，明确返回 MipmapsUnavailable。没有伪造 CPU ImageView、PNG 编码、worker handoff、跨设备/HANDLE 导入或隐式软件快照。

生产 render/snapshot 不创建 staging 资源、不 Map GPU 像素、不调用 fence/wait，也不为了 fallback 重跑业务 draw。EndDraw 和 [CopyFromBitmap](https://learn.microsoft.com/en-us/windows/win32/api/d2d1/nf-d2d1-id2d1bitmap-copyfrombitmap) 仍是同步系统 API，后者可能触发原生 batch flush；这里不承诺其 CPU 调用耗时或硬件执行已经完成。readFrontForTest 是单独的同步诊断读回，只用于测试。

## 统一预算

Domain.texture_bytes 共同约束已拥有的当前代数 Texture、完整未发布 snapshot/upload 候选，以及所有 Surface 的 workspace reservation。workspace 按 `width×height×4×(max_depth+2)` 计费；达到上限在任何 Surface allocator/native allocation 前失败。Domain 有32个 texture slot 和32个 renderer attachment，Surface 使用一个 attachment，快照使用独立 texture slot；不驱逐调用者仍拥有的快照。

Domain.total_bytes 创建时已经预留基础 metadata 和完整 texture_bytes；每个 Surface 再预留其 Zig State（含固定捕获 Buffer）、native State/workspace metadata，以及 `2×resident_bytes`。后者覆盖 source 图片/A8 的旧驻留与完整上传候选；图片与 A8 共用一张按需增长的缓存槽表。零 resident_bytes 明确拒绝正大小的图片/A8上传，typed GPU texture 输入不需要这个缓存。逻辑 texels、adapter metadata 与 allocator headers、驱动布局、字体/effect 内部存储分开，不能据此推断实际显存或 RSS。

Domain.stats 分列 texture pixel_bytes、workspace_reservation、metadata_reservation、raster_reservation、total_reservation 及 peak_total_reservation。peak_reserved_bytes 是旧纹理、工作面和完整候选的合计 texel reservation 峰值，失败候选也可增加它。Surface.stats.workspace_actual 在其 native 平面确实存在时计逻辑像素字节，loss/stop 后为0；workspace_reserved 在壳关闭前继续保留。raster_current 是可恢复驻留描述的逻辑 charge，raster 子表的 native_objects 单独表示当前 adapter refs。reservation 不等于实际系统分配。

render_work 默认128Mi、硬上限1Gi单位，以整画布 clear、各命令和 group 操作为保守 plane visits，完整预检后才回放；它不是系统字形查询、native shaping、驱动执行或耗时上限。尺寸不超过16384，像素不超过16Mi，max_depth 为1..4；实际预算仍可能更早拒绝。

## 事务、借用与停止

render 先校验整批命令、UTF-8、栈、资源、scale、Domain/generation、工作量与已上传 residency；再在固定内部 Buffer 独立 pin/copy。没有 raw-copy owning Buffer，也不消耗调用者原 Buffer。缺少资源、跨 Domain、无效命令与工作量不足不提交 front；native回放/结束错误同样丢弃 work。父 fractional clip 只在 group 最终合成应用一次；透明度/mask/文字继续遵守原分组契约。

整个 Surface operation 都有外层 Domain/App scope。captured pins、最后一次 State 访问和 busy 清除先完成，随后退出 scope。allocator/native 重入不能 close 或再次操作正在使用的 Surface。构造失败先回收 GPU、全部 foreign allocations 和 provisional attachment，再退出 App scope；关闭先撤入口，GPU/CPU residency 析构及壳 allocator free 全部退栈后才释放 reservation/attachment。构造与最后释放期间 Domain.stats 返回 Busy，避免观察半完成的 ledger。Domain allocator context 不得在最后资源释放之前销毁。

DeviceLost 使整个 Domain generation 失效，旧 front 和旧 GPU快照不能继续保证可用。Surface 稳定壳、固定计划和 workspace reservation 留到显式 close；Domain.recreate 后旧 snapshot 仍是 StaleTextureGeneration，旧 Surface front 为 StaleSurfaceGeneration，必须成功 render 才能再次导出。CPU 图片/A8驻留描述的恢复沿用 renderer 的有界恢复机制，并计 native restores。App.stop 撤 native payload，不释放仍被调用者使用的壳；App.deinit 后仍可完成 Surface/Texture close。软件 fallback 必须由宿主独立持有 CPU资源并显式选择，不自动读回 GPU。

## 原生验收

smoke-gpu-offscreen 使用实际 D2D targets 与硬件/WARP，验证三DPI透明像素、group/opacity/mask/fractional parent clip、预乘渐变、图片、PreparedText/legacy灰度字形、四层group、同 Domain 快照输入、重复回放稳定、旧快照独立、错误旧front保留、候选失败、slot/聚合预算、分配故障、allocator重入、关闭通知释放整个宿主、owner线程与loss/stop。native读回仅用于这些像素证据，不等同显示延迟或视觉质量检查。

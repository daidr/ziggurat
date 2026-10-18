# 显式 GPU 设备域与纹理

`ui.gpu_resources` 是 Windows `-Dgpu=true` 的显式资源入口。默认 Context 继续独立创建原有 renderer，不创建 DeviceDomain、共享设备或纹理表。此处的 `TextureView` 只有 GPU binding，没有 CPU 像素，不能转换成 `ImageView`。

```zig
const domain = try ui.gpu_resources.DeviceDomain.create(app, allocator, .{});
defer domain.close() catch unreachable;
const texture = try domain.upload(cpu_image_view);
defer texture.close() catch unreachable;

var context = ui.Context.init(&state, draw, action);
context.gpu_domain = domain;
try context.attach(window);
// draw 中：try frame.texture(destination, try texture.view(), .{});
// 先等待实际 content detach，再关闭 texture/domain。
```

DeviceDomain、Texture、Context、renderer 和所有回调只在 App 的 owner 主线程使用。Domain 只能挂接同一个 App 的 Context；配置在 attach 时冻结到 renderer，之后修改 Context.gpu_domain 不会改变已有设备。hardware 与 WARP 是显式创建选项，不互相自动重试。Domain 的 driver 是设备权威：Raw Renderer.Options.driver 仅用于未指定 Domain 的路径；Context 显式指定 hardware/warp 且与 Domain 不符时返回 DomainDriverMismatch，automatic 接受已选 Domain。显式 Domain 初始化失败会使 attach 回滚，不降级为无 Domain 的 renderer。每个 renderer 有独立 D2D device context、窗口 target 与既有 cache，同一个 Domain 的纹理和 contexts 来自同一 D2D device。[Direct2D 资源域](https://learn.microsoft.com/en-us/windows/win32/direct2d/resources-and-resource-domains)允许这种共享；跨 Domain 的纹理明确失败。

## 拥有与借用

`Domain.upload(ImageView)` 同步上传已有预乘 BGRA8 mip 链。调用开始后先独立 pin CPU 源，再进入 allocator；成功返回的 Texture 不再保留 CPU 描述符或 pixels。普通 Frame 回放只借用已上传的 native bitmap，不解码、上传、分配纹理、读取 GPU pixels 或重新调用业务 draw。

Texture 拥有不可变纹理；`view()` 返回携带 lease、Domain identity、generation 和 token 的只读描述符。Buffer.texture / Frame.texture 共用32项表，按 lease 去重；每个成功记录的资源 pin 一次，在全部 replay、失败或 detach 后 reset 释放。Texture.close 在任一 Frame pin 存在时返回 ResourceInUse。关闭先撤 token/标记壳关闭，再执行 allocator free；free 回调重入该 Texture 得到 Closed，重入 Domain 业务或 close 得到 Busy。Domain 的 allocator context 必须覆盖 Domain 和其全部 Texture 的释放。

Domain 固定支持32张 Texture 和32个 renderer attachment。它不驱逐调用者仍拥有的 Texture，满表返回 Full；close 要求全部 Texture 和 attachment 已释放，否则 ResourceInUse。每项只是有界 owning metadata，未提供隐式全局设备注册、共享 HANDLE 导入或跨进程纹理。

原生 renderer 的显式 Domain 路径在 native 操作期间持 App callback scope，active begin 到 end/discard/abort 的 scope 也明确配对。原生操作触发同步窗口消息时，关闭和 detach 留到该 scope 的安全点；调用者必须结束或 deinit 未完成的 draw，不能持 active renderer 再等待 App shutdown。

Domain.stats 在 active renderer、完整 Surface operation 和 cleanup scope 中返回 Busy；在这些事务之外查询。局部 Renderer/Surface 的统计有各自 owner/重入规则，不用 Domain 半完成的计数推断资源已经可回收。

未发布 LayerCandidate 由调用者独占，必须在其 renderer.deinit 前 commit 或 destroy。commit 检查同一个 renderer 和 Domain generation；loss 后先报 DomainDeviceLost，recreate 后旧候选报 StaleLayerCandidate。候选的 bitmap references 不属于 Domain 自有 payload，loss 不代替调用者销毁它。Context 只在两个候选均成功后提交；GPU 的可失败检查先完成，随后软件提交没有分配或失败点。

## 失效与关闭

Domain 的 generation 非回绕。DeviceLost 一次使整个 Domain 失效，先关闭 ingress、撤全部 attachment 的借用 native wait token，再释放相关 device 资源。固定记录在整批清理期间不可复用；回调只做内部 owner 清理，不调用应用业务。Texture/renderer 的稳定壳、token 与 attachment 借用继续存在，直到调用者明确释放；不能把 native payload 被撤销写成壳已销毁。

Raw Renderer 若使用 App.watchNative 观察其借用的 frameReadyHandle，init 时必须提供指向同一稳定 `?NativeWaitToken` 的 `native_wait_slot`；Context 自动提供该 slot。失效时先把 slot 置空，再 unwatch，最后才 CloseHandle。已经触发的一次性 token 可正常返回 false，不重复执行 task。

失效后的 Texture.view 返回 TextureDeviceLost；显式 `Domain.recreate()` 创建新设备后，旧 Texture 仍是 StaleTextureGeneration。它不会恢复旧 native pixels，也不会重新上传过去的 CPU 源；调用者应释放旧 Texture、上传新的不可变资源并显式 invalidate。generation 耗尽返回 GenerationExhausted，不重置或复用旧 identity。

App.stop 先撤 Domain native payload 和 waits，保留稳定 metadata 供稍后的 Window detach、renderer deinit、Texture.close 使用。最终是否全部原生引用归零以完整 shutdown 和这些显式释放为准；Domain.stats.native_objects 只计 Domain 自己持有的 COM references，不包含 attachment renderer 尚持有的字体、factory、State 等资源。App.deinit 后可完成已停止资源的壳回收；之后不能重新 upload、recreate 或 attach。

## 整帧失败边界

GPU renderer 在本批第一个 native draw 前验证全部 texture 命令的 Domain、generation、尺寸和采样参数。跨 Domain、已失效 token 或缺少显式 Domain 明确失败，保留仍有效的 accepted front；不提交新的 input/semantics。软件 renderer 在任何命令执行前拒绝整个含 texture 的 batch，不能把 GPU 资源当 CPU 图片采样。物理 DeviceLost 已使旧 device payload 不可用，不能承诺它仍可显示。

失败不会读取 GPU 到 CPU，不回调应用 draw 生成另一份内容。需要软件策略的调用者应独立保留 CPU ImageView 或软件离屏 Snapshot，并在业务状态中显式选择；此 API 不提供假 CPU fallback。没有 fence/readiness 或同步读回的性能承诺。显式 [GPU离屏 Surface](gpu-offscreen.md) 使用同 Domain 生成独立不可变 Texture，仍遵守这里的代数、slot和借用规则。

## 配额与统计

`texture_bytes` 默认32MiB、硬上限256MiB，计各 mip 的 `width×height×4` 逻辑 texels，包含所有旧 Texture 和完整未发布候选。源行 padding 不成为纹理 texels。候选每个 mip 全部成功后才发布 token；中途 OOM 完整回收候选，不改已有 Texture。没有 upload 时的隐式 LRU 或 draw 时补建。

`total_bytes` 默认64MiB、硬上限512MiB，创建前统一预检 `固定 Zig/native Domain metadata + 32个 Texture 壳 reservation + texture_bytes`。拥有型 GPU Surface 的 metadata 与 source raster candidate reservation 继续加入同一总额，workspace 与 Texture/candidate 共用 texture_bytes。每个普通 Context 的 layer planes、renderer CPU/image/A8 residency 和 renderer State 仍由原 owner 与其既有预算负责，不把 Domain 的64MiB说成全部窗口或进程的总开销。D3D/D2D/字体对象内部存储、驱动布局与 allocator headers 是 opaque native 开销，不用逻辑 texel 预算推断显存/RSS。

`pixel_bytes` 是当前 generation 成功发布的逻辑纹理 payload，loss/stop 后为0；stale Texture 壳仍计 textures 和固定 slot。`peak_reserved_bytes` 是旧 payload、workspace reservation 加完整 upload/snapshot 候选的峰值，故失败候选也可增加它，不表示实测显存。workspace_reservation、raster_reservation、metadata_reservation、total_reservation 和 peak_total_reservation 单列完整配置成本。bitmap_creations 计成功创建的每个 native mip，包含随后被回滚的候选。热回放不增加这些计数。native_objects 计本 Domain 持有的 COM references；不包含 driver/cache 内部对象。

`smoke-gpu-domain` 是独立的 hidden-window 验证入口；它的同步 readback 只用于像素检查，不进入生产 draw 或资源导出协议。

`benchmark-gpu-domain` 另测1/4/8个隐藏窗口的共享/独立域：创建、CPU提交、busy、逻辑预算、整个进程内存和最终回收分别记录，不做GPU完成或显示延迟承诺。工具范围、复现命令和原始样本见[多窗口设备域测量](gpu-performance.md)。

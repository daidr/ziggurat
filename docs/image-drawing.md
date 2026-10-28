# 图片准备与绘制

`ziggurat_images` 负责系统解码；可选模块 `ziggurat_image_drawing` 负责独立的 CPU 绘制快照。UI 只依赖 `ziggurat_drawing_resources` 的借用 ABI，普通绘制应用不会因图片命令链接 WIC 或 GdkPixbuf。实现覆盖 PNG/JPEG 的裁剪、预乘、mip、显式上传、三端采样，以及显式预留双 bank 的同尺寸更新。动画解码、视频、增量 dirty-region 上传、HDR、色彩管理和任意 source rect 的纹理视图仍待实现。

## 交接与寿命

解码得到的 `*images.Image` 独占属于 worker。`PreparedImage.create(allocator, image, options)` 只能在 Image 的当前 owner 调用；它读取 straight RGBA8，复制为独立、不可变的 premultiplied BGRA8，并可生成完整 mip 链。返回后可以关闭原 Image 和 Worker。调用者可以在解码 worker 上完成这次准备，也可以先 adopt Image 后在主线程显式准备，后者的像素扫描成本由调用者承担。

准备跨分配、失败回滚和最后源描述读取持有源 Image 的 Lease；allocator 回调不能回收源像素。Image 与 PreparedImage 在最终释放前撤销查询/关闭入口，foreign free 重入返回 Closed；最终指针释放后不得再使用。该保护不创建线程或改变显式 worker/交接责任。

worker 创建的 PreparedImage 在 producer 停止访问且通过 join、成功的 App.post 或其他明确同步交接后，由主线程 `adopt()`。投递失败不交接所有权。`view()` 要求 adopted owner，返回直到 close 前有效的只读 ImageView；不是拥有型对象，也不得修改其 lease、identity、mip 描述或像素。PreparedImage 是稳定地址的 opaque owning pointer，不复制、移动或在关闭后使用。

```zig
// Worker owner，Image 与 PreparedImage 的 allocator 均由应用提供。
const picture = try image_drawing.PreparedImage.create(allocator, decoded, .{
    .source = .{ .x = 32, .y = 16, .width = 128, .height = 64 },
    .mipmaps = true,
    .cancellation = &cancel,
});
// 显式交接后，在主线程：
try picture.adopt();
const view = try picture.view();
try context.uploadImage(view); // paint 外
// draw 回调：
try frame.image(bounds, view, .{ .fit = .contain, .sampling = .mip_linear });
// 最终关闭或替换前：
_ = try context.releaseImage(view.identity);
try picture.close();
```

Frame 命令持有临时 Lease pin，直到本次 paint 最终 reset；成功、失败、GPU deferred、软件 fallback 和 draw 内关闭均释放该 pin。Cairo/GPU 的显式 residency 另持跨帧 pin，直到 release、upload/budget 驱逐或 renderer deinit。`close()` 在任一 pin 存在时返回 `ResourceInUse`，对象仍有效。GDI 的静态 uploadImage 路径直接读取 CPU 快照，无独立上传、驻留或跨帧 pin；显式动态注册另持 CPU residency pin，见后文。Context 的 upload、update、release 和 budget 操作拒绝 paint 重入；所有资源修改前撤销借用的 GPU readiness watch，避免设备故障关闭 HANDLE 后仍被 App 等待。

Context 先执行软件后端，再执行启用的 GPU 后端。每个后端独立事务；GPU 上传失败可能留下已成功的软件驻留，可显式选择 GDI 或分别释放。这里不承诺两个后端的原子提交。

## 源裁剪、坐标与采样

`PrepareOptions.source` 是解码后、EXIF 方向已应用的整数像素矩形，必须非空且完全在源图内。准备时复制该区域；linear 与 mip 的边缘都 clamp 到这份独立区域，不会采到 atlas 的邻图。

`Frame.image(destination, view, options)` 的 destination 使用 DIP，并遵守 Frame offset 与 clip。`alignment` 的 x/y 为有限的 0..1，默认居中；stretch 拉伸至全部 destination，contain 等比缩小至其中并保留空白，cover 等比覆盖并按 alignment 裁去超出部分。源坐标由适配器计算，调用者不传递原生句柄。DPI 参与物理像素映射和 LOD 选择，图片无需因 DPI 改变重新 decode 或 prepare。

nearest 取最近像素，linear 在 level 0 对预乘通道和 alpha 做双线性采样。mip_linear 按实际 source/destination 物理像素比例选择最近的 mip，再做双线性采样；它不是 trilinear，也不提供各向异性过滤。未生成 mip 的非 1×1 图片请求 mip_linear 返回 `MipmapsUnavailable`。mip 尺寸逐级 floor-half 并至少保留 1，area filter 使用完整源像素覆盖权重，奇数尺寸的末列/行被计入且不会越界。

颜色分量在 8-bit 编码数值空间预乘、过滤与混合，不声称线性光或 ICC 正确。透明像素的 RGB 在准备时归零，透明彩色像素不会向邻点渗色；opacity 在预乘采样之后统一缩放 source。当前 renderer 的目标保持不透明，结果使用 source-over，并继承既有 clip。不同 native rasterizer 的边缘覆盖和取整允许少量通道差异；测试的内部像素容差为 3/255，不代表所有边缘逐像素相同。

## 预算与明确成本

CPU 准备只有稳定 State 和一个连续像素 allocation；mip descriptors 固定最多 15 项。PrepareOptions.bytes 默认并最多 96 MiB，计入 State 与整个像素 pool；源图仍受解码的 16384 单边、16 Mi 像素限制。stats 区分 bytes、pixel_bytes、levels 和可用时的 elapsed_ns。crop 与 mip 的时间随处理像素增长；不在常规 paint 解码、重建 mip 或分配 Zig 堆。

取消在入口、crop/每层 mip 的每 32 行边界和发布前检查；分配或取消失败不发布部分资源。系统 decode 和 native upload 本身是同步调用，不能在调用中抢占。宿主负责线程、deadline、关闭与 join，不存在隐藏 worker。

GPU/Cairo 的图片与 A8 Coverage 共用一张驻留槽表，起始 32 槽，满了按倍数增长（最多 65536 槽，到顶才按 LRU 腾出一槽），驻留数量由字节预算而不是槽数限制。默认共享 pixel payload budget 为 64 MiB，`setRasterBudget(bytes)` 与兼容的 `setImageBudget(bytes)` 接受 1..256 MiB 并修改同一预算。缓存在显式 upload、降低 budget 和窗口帧补传（见下）时按 LRU 淘汰；渲染器层的 draw 只查找和更新最近使用次序，未上传图片返回 `ImageNotUploaded`。重复上传同 identity 为命中，不创建原生对象。查找按槽表线性扫描，成本随当前槽数增长。Coverage 的准备与上传契约见[阴影与覆盖](shadows.md)。

一帧里同一 Lease 的不同 identity 各占 Buffer 图片表的一项，分别绘制；图片表每帧最多 256 个不同图片（原为 32），超出时追加返回 `ImageResourcesFull`。窗口 Context 在回放前让这一帧画到的图片与 Coverage 都驻留：缺的（从未上传、已释放或被淘汰的）就地上传，只淘汰这一帧没画到的项；这一帧本身超过预算时全部保留、暂时超出预算，直到下一次显式 upload 或 budget 变更再按 LRU 收回。Direct3D 11 在绘制中不能上传，所以缺图的那一帧改在软件（GDI）上画，画完再把缺的上传到 GPU，下一帧回到 GPU。离屏 Surface 与渲染器的直接回放不补传，仍返回 `ImageNotUploaded` / `CoverageNotUploaded`。被淘汰后又被帧补传回来的动态图片成为静态驻留，`PixelImage.commit` 遇到 `ImageNotDynamic` 会释放它再重新注册动态驻留。

上传先验证预算，再创建一份完整候选 native mip 集合；所有层成功之后才驱逐旧项并提交。第 N 层 OOM/一般故障释放整个候选，保留旧驻留及其 pin。候选与旧驻留同时存在的瞬时 payload 上限是 `budget + min(budget, 96 MiB)`；`peak_reserved_bytes` 记录生命周期内这种保守预留峰值，允许失败尝试增加。`pixel_bytes` 只计已提交驻留。它们都不是实际进程内存或显存测量：GPU/codec 驱动元数据、对齐和系统缓存另计；Cairo surface 借用 CPU pool，payload 统计同样按全尺寸保守计费。

Cairo 显式 upload 创建各 mip 的 surface 和 pattern，draw 仅设置既有 pattern 的 matrix/filter。GPU upload 创建 D2D bitmap；resize 保留驻留，device loss 释放 native bitmap 但保留 CPU 描述与 residency pin，下一次设备创建在固定预算内恢复驻留集合。恢复可能发生在下一次 begin，是单独计数的有界重新上传成本，不属于正常缓存命中 paint 的零上传路径。设备恢复失败不发布半个候选，宿主可以使用已有 CPU 快照在 GDI 回放。

`imageStats()` 只记录图片的请求、成功上传、恢复、淘汰、draw/hit/miss、驻留项数、payload bytes、native_objects 和图片候选预留峰值；其中 budget 是共用预算。`coverageStats()` 单独记录 A8，`rasterStats()` 给出二者总量与混合候选峰值。GDI 的静态 uploadImage 路径没有 residency，其驻留数量为零；动态注册会计入 CPU 驻留项、payload 与提交次数，但没有真正的 native 上传，native_objects/native_creations 始终为零。native_objects 只计适配器持有的对象引用，不代表系统内部缓存。

## 同尺寸更新

`Context.uploadDynamicImage(view)` 显式注册可更新的驻留项。GDI 只在同一张可增长槽表里记录 CPU view 元数据并持 residency pin，按 1×payload 计费；其静态 `uploadImage` 仍无驻留。Cairo/GPU 预留 active/inactive 两套 mip surface/pattern 或 bitmap，按 2×payload 计费。Cairo 两套 bank 各有自己的固定连续像素 pool，区别于静态 surface 直接借用 PreparedImage pool 的零拷贝路径。静态调用不会隐式支付双 bank 成本。

Renderer 的图片/Coverage 共享固定缓存元数据在 64-bit 为 5104 bytes，native state 的双 bank 指针表也在初始化时固定预留；这份结构体增量不随历史资源数增长。额外纹理和像素 pool 只在显式 dynamic upload 或 Coverage upload 创建，不为节省固定字段而引入隐藏 allocator 或首次 paint 分配。

`Context.updateImage(old_identity, new_view)` 要求已注册的 dynamic 项，且新旧所有 level 的 width/height/stride/byte_len 完全相同。新 identity 已被同 renderer 的另一项占用时返回 `ImageAlreadyUploaded`，静态项返回 `ImageNotDynamic`，shape 不同返回 `ImageShapeMismatch`；变尺寸需显式 release/upload，不在 update 中重新分配。对当前同 identity 的调用只做校验，没有 copy。update 不执行 decode、premultiply 或生成 mip；新版本先经独立 PreparedImage 准备，CPU source 始终不可变。

Lease 的 `pins` 包含所有借用与驻留，`residency_pins` 是其驻留子计数。替换前要求旧资源 `pins == residency_pins`；任何 renderer 的 Frame/Buffer 正在借用旧图都使操作返回 `ResourceInUse`。其他 renderer 单纯持有旧版驻留不阻止本 renderer 更新，也不会被更新：其原生对象、旧 CPU view 和 pin 都保持有效。成功后本 renderer 释放旧 residency 并持有新版 residency，原资源可以在所有其他使用方也释放后关闭。

Cairo/GPU update 完整写入 inactive 的所有 mip，全部成功才切换 active、注册 identity 与 CPU 描述。第 N mip 失败时 inactive 可以含未发布的混合数据，旧 active 及旧 identity 完整保留；重试总是完整覆盖 inactive，不把部分 bank 发布给 draw。正常 update 只复制数据和修改固定元数据，不新建或淘汰纹理、surface、pattern、pool。同步 native copy 不能中途取消；库和驱动内部缓存成本不由适配器对象计数保证为零。

device loss 释放两个 native bank，但保留最后成功提交的 CPU view 与 residency pin。设备恢复用这个完整版本重建两个 bank，再继续更新；失败的新 CPU view 不会取代它。`native_creations` 会记录恢复时的创建，`restores` 记录恢复项数，不把恢复解释为正常更新的对象复用。

跨后端仍是依次提交。software 已提交 old→new 而 GPU 失败时，允许使用完全相同的 `(old_identity, new_view)` 重试：每项只保留一个 `last_from_identity`，当 old 已不存在、new 是该项当前的同一 lease/descriptor table，且恰好是最后一次 transition 时，已提交的后端返回成功而不再次 copy 或增加 updates。任意缺失 old 不会因 new 恰好驻留就成功；更久的 transition 不保留，释放/驱逐也清除该历史。不保存或访问已经释放的旧 Lease 指针。

宿主只在整个 Context update 成功后发布新业务 view，并显式 `window.invalidate()`。Context 不修改业务状态或已记录的 Frame。失败时保持旧业务 view，随后重试这个 transition，或显式 release 两个 identity 再安排上传。Cairo/GPU 对已移除的旧 identity 返回 `ImageNotUploaded`；GDI 的普通 draw 直接采样传入的不可变 CPU view，所以旧 view 即使不再注册也仍可画。这使 GPU 失败时旧业务快照仍可正确回放到 GDI；它不表示各后端的驻留版本在部分失败后相同。

驻留 budget 计入静态 1×和动态 2×（GDI 动态 1×）payload，降低预算只在显式调用时淘汰。初始动态上传同样先创建完整两 bank 候选再驱逐，Cairo/GPU 的临时预留上限扩为 `budget + min(budget, 192 MiB)`，静态路径仍是此前的 96 MiB 候选上限。PreparedImage 的源 pool、调用者同时保留的其他版本、系统对象元数据与实际显存对齐另计。正常同尺寸 update 没有新的 bank 候选或 payload allocation。

stats 的 `update_requests` 包含失败和重试；`updates/update_bytes` 只计成功的新版本提交和该完整版本的源 payload 字节数，幂等 no-op 与失败 copy 不计入成功 bytes。`dynamic_entries` 记录驻留动态项；`native_creations` 累计适配器实际创建的 bitmap 或 Cairo surface/pattern，包括失败候选和设备恢复，不能替代驱动分配量统计。

## 验证

`zig build smoke-image-prepare` 使用真实系统 PNG 解码，覆盖 worker 准备、原图提前关闭、独占 adopt、裁剪、预乘、完整 mip、逐 allocation OOM，以及两次分配后取消的回滚。纯测试覆盖 27×27、31×7、3×27 的完整奇数 mip 链。

`zig build smoke-image-drawing -Dgpu=true` 在 Windows 隐藏窗口实际检查 GDI、硬件 D2D 和 WARP 像素；Linux 相同步骤检查 Cairo。1/1.5/2 scale 覆盖 nearest/linear/mip、透明彩色输入、opacity、contain/cover、源裁剪隔离和 clip。Cairo/GPU 还检查第 2 mip 创建失败后的旧图可画、超过 32 项时槽表增长而不驱逐、预算 LRU、miss、重复回放无额外 upload 和 native 资源归零。Context 检查一帧画 33 张未上传、超出预算的图片仍逐张画出（Cairo 逐像素，GPU 首帧走 GDI、下一帧回到 GPU）、预算变更收回、failed frame、draw 内关闭和最终 pin 释放；Windows GPU 检查 pending readiness watch 先取消，再模拟 upload device loss、恢复和 GDI fallback。这些是像素与生命周期检查，不声明可见效果质量或显示延迟。

`zig build smoke-image-update -Dgpu=true` 使用真实解码的两个不可变版本，在 GDI、硬件 D2D、WARP 和 Linux Cairo 检查 base/1×1 mip 像素。65 次提交后 native 对象和累计创建数不增长；第二 bank 创建失败、第 2 mip 更新失败均保留旧版本可画，Frame pin 阻止替换，另一个 renderer 的旧驻留保持有效。另查 shape/预算/静态项拒绝、精确 transition 重试、旧 identity 差别、Context 分后端失败后重试、watch 先撤销、device-loss 完整恢复、旧业务快照 GDI fallback 和 draw 内关闭释放全部借用。

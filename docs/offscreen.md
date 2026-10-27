# 透明离屏图片

`ui.offscreen.Surface` 在显式准备阶段复用 GDI/Cairo 软件 renderer，将现有 `commands.Buffer` 回放到透明根工作面，输出独立、不可变的预乘 BGRA8 `Snapshot`。普通窗口 Context 没有新增平面或初始化成本；本模块不创建窗口、线程、计时器或事件循环。支持 Windows 和 Linux 的 little-endian 目标，其他字节序明确返回 `UnsupportedPixelEndian`。

可选 `Options.transform_source` 显式预留仿射子面池及独立命令 descriptor 表，接受同一 Buffer 的 `begin_transform` / `end_transform`。源大小使用 DIP，池、透明 guard、混合嵌套及采样边界见[仿射回放](affine-rendering.md)。没有设置该选项时不分配 descriptor 表，遇到变换命令返回 `TransformsRequired`。Surface 捕获命令时按值复制 descriptor；源 Buffer reset 或解绑后不影响本次 render。启用变换时 `render_work` 硬上限为512Mi，按最大池平面保守计费。

```zig
const surface = try ui.offscreen.Surface.create(app, allocator, .{
    .size = .{ .width = 256, .height = 128, .scale = 1 },
    .max_depth = 2,
});
defer surface.close() catch unreachable;

var buffer: ui.commands.Buffer = .{};
defer buffer.reset();
try buffer.roundedRect(.{ .x = 4, .y = 4, .width = 80, .height = 40 }, 8,
    .{ .r = 32, .g = 96, .b = 192, .a = 128 });
try buffer.finish();
const snapshot = try surface.render(&buffer);
defer snapshot.close() catch unreachable;
const view = try snapshot.view();
try context.uploadImage(view);
defer _ = context.releaseImage(view.identity) catch unreachable;
// draw 中把同一 view 交给 Frame.image。
```

## 生命周期与事务

Surface 是稳定、不可复制的 opaque owner。`create` 需要一个仍接受业务操作的 App，所有操作均先检查该 App 的进程主线程身份；成功后注册 App stop participant。创建失败，包括 stop 容量 `Full`，回滚全部候选、原生对象和拥有存储。Surface 固定物理尺寸和 DPI；创建另一个 Surface 是另一份独立预算，调用者负责多个 Surface 的合计成本。

`render` 是显式准备工作，宜在应用的更新/布局阶段调用。它不会消费或 reset 源 Buffer。任何外部分配前先完整校验命令、资源、clip/group 平衡与工作配额，把实际命令、文本、brush 和资源描述复制到 Surface 预留的有界记录，并逐项取得独立 Lease pin。失败只释放本次已取得的 pin，不 raw-copy 一个拥有借用的 Buffer。因此分配器回调重置源 Buffer 后，本次 render 仍使用完整快照；源资源在这些 pin 释放前仍不能 close。

输出候选的壳、像素、账户配额和不回绕的 raster identity 在回放前准备。根工作面清零，不从白色窗口 front 导出，也不用额外 wrapper group，公开的全部 group 深度仍可使用。成功完成全部回放和原生 flush 后复制到候选像素，交换 front/work，再发布 Snapshot。回放、导出或分配失败不发布半张图片，不提交新的 front；下一次 render 从透明工作面重新开始。普通命令回放与输出复制没有 Zig 堆分配。

每个业务入口用 App callback scope 保持 App 寿命，并在外部分配返回后重验其 phase。Surface 的 busy 门拒绝分配器/原生回调中的重入 render、upload、stats 和 close；App 停止后业务入口返回 `Closed`。关闭使用 teardown scope；若 App 已接管 stop 节点，显式 close 返回 `StopInProgress`，由 stop callback 完成原生收口。

App stop 释放 Surface 的全部 native workspace/驻留，撤销其 App 指针，保留调用者拥有的 Surface 壳；之后仍需调用 `Surface.close`。关闭壳可在 App.deinit 后进行。已有 Snapshot 不借用 Surface、Buffer、字体、原生位图或 App，仍然有效。Surface、Snapshot 及共享账户的 allocator context 必须覆盖 **Surface 和最后一张 Snapshot** 的全部释放；账户与像素只在创建的 owner 主线程访问和回收，不提供 worker handoff。

Snapshot 的 `view()` 返回一层稳定的 `ImageView`，复用 Frame pin、图片驻留与 releaseImage 合同。任一借用存在时 `Snapshot.close` 返回 `ResourceInUse`。开始关闭后先撤销可读存储并标记关闭，再进入 allocator 回调；这些回调重入同一 Snapshot 的 view/stats/close 得到 `Closed`。最终输出没有 mip，未提供编码文件或 GPU target 导出接口；硬件/WARP 的验证是上传这份软件快照后的真实回放，不代表 GPU 离屏渲染或同步读回。

Surface 仍存在时，Snapshot 关闭期间还暂时关闭该账户的业务入口和显式 Surface.close/stats，返回 `Busy`，直到像素及壳的全部 free 回调退栈。这样壳 free 回调不能趁账户归还配额又创建一张候选，绕过实际峰值；App stop 的 native 收口仍可完成。Surface 已关闭后没有新 render 入口，最后一张 Snapshot 先释放共享账户，最后释放仍标记 Closed 的壳，避免账户 free 回调访问已释放的对象。

## 命令与资源

填充、RGBA、圆角/内描边、严格渐变、矩形 clip、prepared text、图片、A8 与透明 group 使用同一命令和 renderer。group opacity、parent fractional clip 与 mask 的次序沿用[分组工作面](layers.md)。透明根不占用 group/clip 层。改变 opacity 或业务资源仍须显式重新 render；Snapshot 自身和已记录旧 view 不会原地更新。

图片和 A8 在 `surface.uploadImage` / `surface.uploadCoverage` 显式上传，释放用对应 release 方法。Cairo 必须有匹配驻留，缺失返回 `ImageNotUploaded` / `CoverageNotUploaded`；GDI 静态路径直接读取 CPU view。A8 与 prepared text 必须匹配 Surface.scale。缓存仍是共享的可增长槽表、一个 LRU 和合计 pixel byte 预算，驱逐只发生在显式上传，Surface 回放不会补建资源（补传只发生在窗口 Context 的帧里）。Surface 首片不提供动态驻留更新包装；可显式上传新的不可变 identity。

默认 legacy text 策略是 grayscale。GDI 在创建时预备灰阶字体和复用 glyph scratch；Cairo 在创建时设置灰阶 font options。透明根和透明组都保留正确 alpha，不使用 ClearType 颜色条纹重建覆盖。`legacy_text=.disabled` 在预检拒绝旧 text 命令，prepared text 仍可使用同一份已拥有的 shaping/coverage。legacy text 的系统 shaping、字形缓存和字体内部成本属于 native text API；需要预备 shaping 的路径使用 prepared text。此处不承诺字体边缘在两个系统逐像素相同。

## 有界成本

默认 `workspace_bytes=64MiB`、`resident_bytes=8MiB`、`output_bytes=16MiB`，**不是三份可独立耗尽的默认额度**。`total_bytes=64MiB` 在任何分配前统一检查：

`实际 workspace 平面 + Surface/Account/adapter 固定元数据 + 2×resident 上限 + output 上限 <= total_bytes`

workspace 由现有 layer Plan 计算 front/work/groups，GDI grayscale 还包含一个 glyph scratch。固定元数据包含预留 Buffer/缓存记录、稳定壳和确切的适配器结构体大小。Snapshot 壳的大小进入每张输出的 output 账户，输出上限必须至少容纳一张完整候选。系统 DC/位图/字体、Cairo/Pango 对象的内部存储与 allocator headers 不可由这些像素字节推断，作为 opaque native 开销另列对象数；不把 byte 预算称为进程 RSS 上限。

`resident_bytes` 单独限制图片/A8 的逻辑驻留 payload，显式上传候选完成后才淘汰旧项。统一总预检为其保守预留两倍上限，覆盖旧驻留加新候选；这部分 reservation 不表示已经分配两套纹理。输出账户以实际 `Snapshot metadata + pixels` 累计所有旧快照和新候选，在首次分配前拒绝超额。Surface 关闭后账户由仍存活的 Snapshot 持有，到最后一个引用才回收。所有 limit 的总硬上限为256MiB，resident 的输入上限还受现有图片 payload 界限约束；输出最多每边16384 px、16M pixels，始终可作为 ImageView 使用。

`render_work` 默认128M、硬上限1G，是保守的全画布遍历工作单位。清 work 和复制输出先计2遍；每个 fill/shape/gradient/image/A8/prepared text 计1遍；旧 text 计3遍；begin_group 计1遍，end_group 计3遍，以涵盖 clear、opacity、mask 与 parent composite；clip/元数据另有原 Buffer 固定容量。实际裁剪很小时仍按整画布收费，配额不足在分配或绘制前返回 `RenderWorkExceeded`。它不是精确 CPU 指令、native shaping 时间或实际被改写像素的计数。

低层 SoftwareRenderer 的 ordinary/offscreen 入口有明确模式边界：active offscreen 期间普通 begin/endChecked 返回 `SurfaceModeMismatch`，active ordinary 也不能用 endOffscreen 导出。成功提交的 front 单独记录透明身份，abort 不改该身份；透明 front 的 releaseLayers 返回 `OffscreenSurface`，不能把它转成普通窗口的 opaque plane。只有一次完整成功的 ordinary commit 才重新允许普通 release；这些检查不为普通窗口增加像素遍历或分配。

`stats.workspace_bytes` 和 `layers` 表示当前仍持有的 native workspace，stop 后归零；`metadata_bytes` 在 stop 后只剩 Surface/Account 的壳。`resident_current` 是当前逻辑 payload；`resident_candidate_bound` 是两倍上限。`output_current` 在正常可观察点表示实际拥有的快照存储，内部候选 reservation 期间业务 stats 不可重入观察。`output_peak` 只计 allocator 成功返回的壳/像素 allocations；壳 OOM 不凭空增加峰值，像素 OOM 只计已分配的候选壳。`reserved_peak` 是配置总 reservation 上界，不能当作实测分配峰值。`last_render_work` 是最近一次成功 render 的预检工作量。原生对象/创建数沿用 renderer 的持久资源计数，不宣称包含系统字体缓存的每次内部操作。

## 验证

`zig build smoke-offscreen -Dgpu=true` 在 Windows GDI 和 Linux Cairo 实际准备透明根图片，覆盖三种 DPI、完整4层分组、半透明重叠、parent fractional clip、opacity/mask、prepared/legacy glyph、alpha 渐变和图片。快照在 reset 源 Buffer、关闭 Surface 后上传到 GDI、硬件 GPU、WARP 或 Cairo，逐像素验证其预乘 source-over；正常重复准备的持久 native 创建数保持稳定。

同一目标检查全部 Zig 分配失败、每个 native plane 的候选故障、绘制后导出失败回滚、Cairo 缺驻留的真实中途失败与恢复、Lease acquire 部分失败、output 旧+候选合计上限、全画布 work 配额、错误输入在 allocator 前拒绝、线程入口拒绝、stop 注册失败/taken 所有权、分配器重入 reset/close/quit、Snapshot deinit 回调重入、App.deinit 后快照仍可用，以及最终 allocator live/native reference 归零。它验证像素和寿命，不评估人工视觉质量。

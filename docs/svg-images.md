# SVG 显式嵌入栅格图片

SVG 的 `image` 首片接受宿主已经准备的不可变 `drawing.ImageView`，在本次 `Document.prepare` 复制其 base level，按目标物理像素尺寸采样并合成到独立 Prepared。SVG 模块只依赖 Vector 和共享绘制资源，不导入解码器或 UI，不创建线程，不读取文件或网络，不等待外部工作。

## Provider 与来源

`PrepareOptions.image_provider` 指向 `svg.image.Provider`。Provider 包含稳定 `context`、必需的 `drawing.Lease`、同步 `resolve_fn(context, complete_data_uri)` 和本次准备的 Limits。宿主先通过显式图片工作流解码并准备资源，再调用 SVG；回调只能查找已经准备好的资源，不能临时解码、I/O、阻塞等待或投递后台工作。返回 view 及其所有 level descriptor/pixels 必须不可变，属于当前准备 owner，并且至少存活到 SVG 同步取得 lease。不能把主线程资源直接交给其他线程。

来源只接受大小写精确、无空白/额外参数的 `data:image/png;base64,`、`jpeg`、`bmp`、`gif`、`webp` 加规范 base64，含正确 padding bits。完整 data URI 是精确资源键；SVG 不解码 payload、不验证媒体内容与资源对应关系，该匹配由宿主在准备资源时负责。不同 URI 即使最终图片相同也属于不同缓存项。`href` 优先于有正确命名空间的 `xlink:href`，两者出现时均须满足来源限制。HTTP、文件、相对路径、fragment、SVG 嵌套图片、percent escape、其他媒体类型均明确失败。

prepare 在首次外部分配前按值捕获 Provider 配置并取得 provider lease，贯穿所有成功/失败清理和最终取消复核。调用者的 Provider descriptor 无需保持内容不变，但 context/lease 所有者必须保持稳定，lookup 表也必须拥有或安全借用其资源；provider lease 不能替代宿主对表中尚未返回资源的生命周期管理。每次 resolve 返回后先取得图片 lease、验证所有 level descriptor，并捕获 base-level 值，再做任何分配；所有行复制、非预乘拒绝及其失败清理都持有图片 pin。成功的源 pin 随缓存保留到该快照最后一次准备清理完成，不随一次 paint 结束而释放。缓存销毁释放像素和 descriptor 后才释放源 pin。provider 最后释放前，Document 再复核取消；之后只剩纯 lease release 和所有权返回。Prepared 不保存任何 provider、源资源、Document 或临时场景引用。

缺 provider、查找失败、非法 view、非预乘像素或任一预算失败都会丢弃整个候选，没有透明占位或隐式后备。View 的 BGRA 各颜色通道不得大于 alpha，源 padding 不复制，mip levels 不用于采样。

## 几何与合成范围

支持 `x/y`（默认0）、必需的显式 `width/height`，沿用 SVG 长度/百分比参考；负尺寸失败，零尺寸关闭绘制且不请求资源。支持 `preserveAspectRatio=none`、九种对齐的 meet/slice，默认 xMidYMid meet。缺尺寸、auto/intrinsic sizing、defer、object-fit/object-position 不属于本片。只支持默认或显式 `overflow:hidden`；作者设为 visible、auto 或 scroll 均明确 UnsupportedImageOverflow，不提供滚动界面。私有样式保留 auto/scroll 标记并沿 winning CSS/继承/initial/unset 同步或重置；不更改普通 viewport 原有裁剪行为。

base level 的像素矩形先适配定位矩形，再经过当前 SVG 仿射。slice 始终在局部定位矩形裁剪，然后应用外层 transform；meet 留白透明。奇异映射不绘制，无法表示逆映射时明确 UnsupportedImagePrecision。对象边界始终是 `x/y/width/height` 定位矩形，排除适配留白、透明像素、stroke 与裁剪。outer affine 在各自正确的坐标阶段应用，objectBoundingBox clip/mask 使用该定位边界。

图片忽略 shape 的 fill/stroke/paint-order。支持现有 `use`、嵌套 viewport、根/局部 affine、visibility/display、整图及父组 opacity、clipPath、alpha/luminance mask，并可以作为 mask 内容。作为 clipPath 几何目标仍明确拒绝。image 只允许描述性子元素，不解析外部内容、脚本或动画。

两种合成模式都在输出物理像素中心逆映射到源图，以半像素对齐、边缘夹取的四点双线性插值采样预乘 BGRA，保持连续通道到各自的合成量化阶段。pixel 仍逐 paint A8/BGRA8 量化；sample_color 向几何覆盖的16个 lane 广播同一像素中心颜色。图片颜色不是面积积分，不使用 mip 过滤，不声称色彩管理、动态矢量回放或 GPU 准备。

## 预算与默认成本

Provider.Limits 默认 requests64、instances1024、pixels16Mi、bytes96Mi、work128Mi，均有硬上限校验。requests 是不同键的实际查询次数；instances 是实际生成的图片 paint descriptor 数；pixels 是不同快照 base-level 像素的累计复制额度。bytes 同时预留每个保留源 view 的全部 level byte_len 和本次 tight base-level 像素，包含源与候选，不测量分配器私有头。image.work 累计缓存键比较、请求键、复制像素与 paint descriptor 工作，命中仍计查找工作。失败和被丢弃步骤不退还累计工作额度。

所有拥有的缓存、Snapshot、Paint、像素与几何候选另受 scene.bytes 的 live/peak 约束，增长不绕过同时存活额度；输出采样沿既有 pixel_work/sample_work/scene_work 预算，sample_color 每个图片采样另计16次固定通道步骤。BBox 探测不请求/复制资源。取消在行、固定像素步长和阶段边界检查，不抢占一次宿主回调。

没有实际 image 时无新增 heap、provider 请求或图片工作。64位当前布局 Options328→336、Work1088→1104；Brush64、Node64、Program136、Prepared352 均不增长。Provider64、optional Provider72 是本次调用的配置快照描述大小，不是测得的栈峰；私有通用 Resources80、Snapshot56、Paint64 仅按图片需要分配；Resources 在 patterns 接入时从原 Cache72 增加8字节，没有额外 owner 分配层。默认样本的8组像素/分配次数/工作对照一致；pixel 的完整分配 trace/peak 一致，sample_color 因 Builder 包含 Work 而增加16字节固定分配和 peak，其余分配序列不变。这是结构与确定性计数证据，不是耗时或吞吐结论。

## 规范依据与验证边界

[SVG2 embedded placement/image](https://www.w3.org/TR/SVG2/embedded.html#Placement) 定义定位矩形、零尺寸关闭、宽高比适配和默认 hidden overflow；本片显式拒绝 auto sizing 与作者 visible/auto/scroll overflow。[SVG2 bounding boxes](https://www.w3.org/TR/SVG2/coords.html#BoundingBoxes) 规定 image 的边界来自定位矩形。本实现不以 fitted rectangle 或非透明像素代替它。

纯测试用固定预乘像素与独立矩形/权重 oracle 核对适配、仿射、定位 bbox、use 复用、mask、拒绝条件、所有分配失败、重入关闭和最后临时 free 触发取消。原生 `smoke-svg-image` 显式 worker 解码本地内嵌 PNG，先核固定解码结果，再在两种合成模式/三种准备尺寸核独立双线性与覆盖 oracle，并回放到现有原生 renderer。实际执行平台和优化模式以验证日志为准；编译或隐藏窗口像素检查不代表浏览器兼容或视觉质量。

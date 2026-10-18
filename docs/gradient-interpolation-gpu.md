# 显式 GPU 插值程序

渐变的 `interpolation` 选择色标之间的插值空间。输入仍是直通 alpha 的 sRGB 字节，目标仍是编码 sRGB 的预乘 BGRA；这不是全局色彩管理。软件支持范围和默认 `.srgb` 结果不变。

`Context.prepareGradientInterpolation()`、`d3d11.Renderer.prepareGradientInterpolation()` 和 `gpu_offscreen.Surface.prepareGradientInterpolation()` 在 owner 线程、绘制之外显式准备独立程序。同设备重复准备不创建第二个程序。未启用 GPU 返回 `GpuNotEnabled`，明确采用软件的 Context 返回 `GraphicsUnavailable`。准备可创建原生对象、加载 shader 和触发驱动 JIT；不承诺驱动首帧没有其它内部工作。准备不是 UI 绘制的隐式操作。

直接 Renderer 的 `gradientInterpolationReady()` 和 `gradientInterpolationStats()` 同样限定 owner 线程；错误线程在访问原生对象前返回 `WrongThread`。只读查询不恢复设备或准备程序。

## 数值与组合范围

可选程序共用既有 analytic 几何内核：线性、椭圆径向、圆锥，矩形、圆角和内描边；色标可透明。group、分数 clip、A8 `gradientCoverage` 和显式 affine source 沿原有离屏层/驻留/变换预检，不再仅因选择新空间而后备。没有原来整目标两边512像素的限制。

新插值仍有独立保守包络：scale 为有限的1/16至16；物理源几何和渐变 anchor 的绝对坐标不超过16384；线性长度至少8物理像素，径向两个半径至少4物理像素；不同线性/径向色标在轴长/最小半径度量上间隔至少1/8物理像素。圆锥沿用周期端色一致、精确可表示物理中心和至少1/1024参数间隔的门禁。

这些绝对界限还不是充分条件。预检按最窄色标区间和插值空间估计几何误差：线性投影同时计 float 点积、单位方向及传输色标的误差，分母扣除两端色标误差；精确半像素轴向和1/64投影色标保留独立精确路径。径向要求物理中心精确可表示为 f32，径向/圆锥均限制归一化区间相对误差。几何预算为半个8位输出通道，含透明度的灵敏度上界分别取线性RGB14、Oklab300；剩余预算留给转换和量化。过陡的径向/圆锥或大源平面中极短的斜向过渡可返回 `UnsupportedGradientPrecision`，没有单独改动软件语义。圆锥的跨硬件 transcendental 精度仍依赖实际像素验收，不把有限坐标或一条 HLSL intrinsic 定义当作任意驱动的误差证明。

重复色标保留原始顺序，最后一个相同 offset 拥有边界。精确半像素轴向线性投影允许硬边；曲线/斜线硬边及圆锥不连续接缝保持软件精度路径。没有移动、软化或删掉色标。有限输入不等于一定在 GPU 包络内，边界也不代替既有 affine 组合预检。

整缓冲在第一条绘制命令前检查准备状态与数值域，GPU Offscreen 在清 work 平面前检查。拒绝保留前帧和绘制计数；Context 可用同一 Buffer 整体软件后备。不能软件回放的 GPU Texture 不被隐式读回，返回原有错误并保留已提交前帧。

## 颜色、所有权与成本

每条新空间命令在回放时准备固定272字节 packet，并由同步原生入口复制，不保留 Zig 指针，不逐像素重新转换 stop。线性RGB或有符号 Oklab 在所选空间预乘后插值；先用插值 alpha 去预乘，再逆变换、裁剪线性RGB通道、编码并预乘输出。精确零 alpha 输出零，没有丢弃微小 alpha 的 epsilon；隐藏透明颜色不泄漏。有符号 a/b 不在插值前裁剪，精确端点返回原字节的预乘值。

默认程序继续使用原624字节常量和152字节原生 brush；完整默认离线 shader 字节与原版相同。独立程序保留显式链接成员、可选 owner 和准备事务，默认不注册/创建它。本批未给 State/Renderer/Brush/Command/Buffer/Frame/Context 新增字段。共享 C 几何 helper 和内部实参是实际实现改动，不用布局不变推断 CPU 或栈成本。可选离线字节4992→20476；这不是执行时间或驱动内存测量。

准备先保留已知 metadata 预算，再创建候选，旧 owner 和候选同时计费；最后外部原生释放返回后重新核验 attachment、应用状态和设备代数，再无外部调用地发布。失败不发布候选。驱动/JIT/系统缓存和分配器管理开销不属于本项目可观测 metadata 硬限。

设备丢失先撤 ready 再释放 effect/context；control 和 factory 注册引用可以保留。普通设备恢复不加载可选程序，需要宿主显式 recreate 后重新 prepare。`releaseGradientInterpolation()` 限绘制之外，先撤入口再释放引用和归还 metadata；前帧是像素，不借 effect。关闭/App Stop 同样先撤入口，迟到引用仅访问独立 C 状态。

## 验证边界

Windows 固定源 Debug/ReleaseSafe 均通过164项纯测试，以及两driver的数值拒绝、旧front/Texture和完整统计保持。原可接受的病态斜线实际产生角点3（独立XYZ oracle期望6）；现在该缓冲在清屏前返回精度错误，真实 Context 一次记录、一次整体软件回退后角点仍为6。径向/圆锥的临界0.1875间隔实际GPU逐像素通过，0.125的Oklab间隔在清屏前拒绝。最终权重估计保留+12u（u=2^-24），包括reduced reciprocal及后续算术的预算。

ReleaseSafe 完整原生集合通过：576旧色彩oracle平面、36默认程序逐字节对照、新增360个两空间共同范围平面及4个宽4096像素平面；hardware/WARP、准备DPI1/1.5/2、透明/硬边/圆角/内描边/A8/分数clip/group/反射均在该集合中。重复回放没有新建暖对象；候选失败、metadata限额、错误线程、设备丢失/重建、App Stop及最后外部释放重入检查通过，已知资源归零。Debug还保留了先前共同范围shader的360+4通过记录；最终+12u完整集合只在ReleaseSafe执行，不重复冒称四矩阵。

独立色彩 oracle 使用不同XYZ矩阵、f128插值和f64 transfer pow；几何使用物理4×4枚举，圆锥用acos/象限，A8用源texel tent求和。已测圆锥范围不构成任意驱动atan2误差的证明，未承诺任意有限极值和任意affine组合。离线shader编译或Linux纯测试不能代替上述Windows像素证据。未完成GPU timestamp吞吐/默认时延基准，不据字节相同、记录大小或测试耗时声明性能提升。

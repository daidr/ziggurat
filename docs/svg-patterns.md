# SVG 有界图案绘制

`fill/stroke="url(#pattern)"` 在显式 prepare 内将可见 tile 编译成拥有型矢量场景。一次完整 pattern paint 在共同16-lane域合成，再成为最终 Prepared 的一部分；draw 只回放独立图片，不展开、解码或分配。

## 定位、模板与支持范围

`patternUnits` 支持默认 objectBoundingBox 和显式 userSpaceOnUse；`patternContentUnits` 支持默认 userSpaceOnUse 和 objectBoundingBox。x/y、width/height 默认0，负尺寸失败，零尺寸不绘制。tile 百分比按所选 units 求值：BBox 为1，user space 为近邻 SVG viewport。BBox 使用目标未描边几何；文字使用 provider 完整 glyph cells，缺 cells 明确 UnsupportedTextBoundingBox，零宽/高 BBox 不绘制。描边宽度及 NSS 不改变这个 BBox。

支持 viewBox 的非零原点、preserveAspectRatio 的 none/对齐/meet/slice，指定 viewBox 后 content units 不参与内容映射。支持 patternTransform 仿射、目标仿射与 root/viewBox。tile clip 使用 grid 映射，内容使用独立 content 映射，不能拿经过 viewBox 的内容矩阵裁 tile。无 viewBox 时内容原点是当前 tile 的 x/y。

本地 href/xlink:href 可继承 x/y/width/height、两类 units、patternTransform、viewBox、preserveAspectRatio；最近显式值优先。自身除描述性节点外没有内容时，选择最近模板的实际内容，并从引用 pattern 的 computed style 继承，不能把模板自身祖先样式当作 clone 父样式。只借用本次 Document 的不可变 source slices，不克隆 DOM。链有32项硬限、累计 reference_depth/node/parse/style 预算与 cycle 检查；外部资源不进入模板解析。

两组尚无确定坐标合同的组合统一返回 UnsupportedPatternCoordinateSpace：无 viewBox、两类 units 不同且 patternTransform 非 identity；或 viewBox 使用 objectBoundingBox、目标 BBox 非等宽高且 preserveAspectRatio 非 none。该门在共同 Plan 一次判断，不逐 tile 猜测或改期望像素。第一组在 BBox 查询前拒绝；第二组复用已有目标的 BBox。Document/目标几何可能已经分配或 shape，但门前不创建 pattern Resources/ledger/RGBA/scene owner、不展开模板内容、不另作 shape/font 请求。通过后才生成目标输出 geometry 和可见 grid，不再次 resolve/BBox/shape。

内容支持 g/path/rect/circle/ellipse/line/polyline/polygon、实色/currentColor、局部仿射、普通描边/dashes、组透明度与 visibility/display。内容几何、stroke/dash 百分比继续明确拒绝。定义从真实祖先继承；定义或祖先 display:none 不妨碍引用。overflow 只支持默认/显式 hidden；visible/auto/scroll 明确拒绝。pattern 根的 transform、opacity/clip/mask，内容 text/image/use/其他 paint server/clip/mask/marker 仍拒绝。目标上的 clip/mask/opacity 保留原合同；不支持的已找到 pattern 不能静默使用 paint fallback。

## 一次 paint、预算与所有权

两个相邻 tile 各自先量化成 A8=128 后 source-over 只得192，连续红色应为255。因此 tile clip、内容、目标几何在共同覆盖 lanes 内完成一次 paint；fill/stroke opacity 最后乘一次。sample_color 复用现有场景；pixel 创建临时场景 owner，先获得完整 RGBA 层再按原 pixel 合成规则提交。普通 pixel paint 的量化规则不变。

候选范围从输出几何与画布反变换到 grid。floor/ceil、带符号范围、行列乘积、四角有限性及可推进性在枚举前检查；极小 period/巨大 shear 或不可表示坐标失败，不能先进入无界循环。空 tile 同样消耗 visit；定义、模板链、children、tile 与所有几何/lane/像素工作累计计费，不重置本次 prepare 额度。

pixel 临时 owner 借用父 Sheet/refs。文字的 BBox 查询通过一次调用内显式 bounds_source 借用父文字 cache，不将借用 cache 存入 Builder，不关闭父 owner，也不重复 shape。allocator 桥接把旧存储与增长候选实时计入父 live/peak；成功和失败只合并一次工作。Prepared 不借用定义、模板 slices、Plan 或临时场景，所有候选失败整批丢弃；最后 foreign free 后仍检查取消。

pixel 的 color/scene/sort 统计只覆盖 pattern 共用 lane compositor，不代表普通 pixel 的全部颜色工作。既有条件 Resources 为80字节，pixel pattern 首用另有96字节 Scene.Work。新 Grid 为1056字节（原976，+80），Plan1024、Template160、attribute scratch288、chain256；这些是仅 pattern 准备的私有值/局部存储，不是持久 owner 或实际栈峰值。Style864、SVG Frame1000、Work1104、Options336、Prepared352、Builder1576 与普通场景拥有记录不增长。无 pattern 路径无新分配/扫描；不能据此声称 CPU 或实际栈零成本。

## 依据与验证边界

[SVG2 patterns/paint-server templates](https://www.w3.org/TR/SVG2/pservers.html#Patterns) 定义 units、模板和变换顺序；[object bounding box units](https://www.w3.org/TR/SVG2/coords.html#ObjectBoundingBox) 定义未描边 BBox 和退化效果。未决组合保留 [SVGWG 293](https://github.com/w3c/svgwg/issues/293) 的显式边界，不声称其已有统一解释。

本批 Debug/ReleaseSafe 相关纯测试均通过：28项 pattern、4项 foreign-free 取消、15项默认/marker 指纹测试；两优化的64条完整像素/分配/peak/work记录与旧源码逐字一致。早拒绝额外用零 allocation allowance 和 fail-index=0 分别核 sample_color/pixel，逐分配失败同时保留旧 Prepared 的 pixels/identity。原有接缝、NSS/目标 clip、整体透明度与样式祖先回归保留。

Linux 隐藏原生 expanded_pattern 已在 Debug/ReleaseSafe 各一轮通过，两 compositing modes 各3个准备 DPI，核 BBox 条纹、非零 viewBox 原点与 letterbox、模板 host currentColor、一次透明度、worker→主线程交接、源销毁后的回放及最后 pins。Windows 同一新增集合已在两优化的 GDI/hardware/WARP、两 compositing modes、3个准备 DPI 下通过并资源归零。没有重复旧全集合；本文件不声明视觉质量或吞吐结果。

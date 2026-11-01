# 客户区局部失效

`try window.invalidateRect(bounds)` 使用客户区 DIP，主线程调用，不分配、不立即绘制。有限坐标绝对值与尺寸各不超过1,000,000；宽高不能为负。无效参数返回InvalidGeometry，零面积为空操作，关闭中的句柄返回Closed。App仍须覆盖Window句柄使用期。

Windows按实际DPI转物理像素，边界向外取整并裁到客户区；GTK按逻辑widget坐标向外取整，再裁到DrawingArea尺寸，高DPI时允许覆盖更多物理像素。完全在客户区外的请求不产生更新。多次请求交由系统更新区域合并，不保存一个随历史请求增长的表。

原生失败使用window_update诊断并保留Window pin到sink返回。InvalidateRect只文档化布尔返回值，因此失败不附会旧GetLastError；缺少原生错误码时code保持null。错误路径仍清除上一操作的失败码，并允许sink延迟关闭窗口。

动画使对象移动或缩小时，宿主同时失效旧、新绘制边界，并计入stroke、shadow等外扩范围。只有采样的可见值改变才请求失效；nextWake为null时停止arm。重排布局、DPI/字体/主题变化、未知绘制外扩时使用完整`window.invalidate()`。原生系统还可以因曝光、resize等原因要求更大的区域，应用必须能随时绘制完整视图。

局部失效是原生damage提示。Context仍重建完整命令、hit和semantic候选，以成功帧原子提交；GPU回放/Present及分组合成仍处理全帧。

## 软件工作面只重画变化部分

Linux（Cairo）和 macOS（Core Graphics）的软件工作面跨帧保留像素，Context 据此只重画变化的部分（`src/ui/damage.zig`）：

- 每帧把每条绘制命令连同外层裁剪和它读取的资源（文本字节、渐变色标、图片/覆盖层身份、预排文本像素、加载指示器的相位）哈希，按顺序折进它边界（设备像素，外扩2像素抗锯齿）覆盖的瓦片。瓦片默认16设备像素，平面大时加倍，最多2048块。
- 与上一帧哈希不同的瓦片即为损坏区。相邻行同列的损坏瓦片合成矩形，再合并重叠或相接且不增面积的，超过8个时合并并集增长最少的一对，直到最多8个互不重叠的矩形。
- 矩形碰到的文本命令（平台排版的文字）会被整个包进矩形，免得裁剪从文字中间切过：Cairo 在这种裁剪下画亚像素文字与整帧不同。
- 每个矩形单独在裁剪下重放：跳过边界不相交的绘制命令，透明窗口先把该矩形清成透明。其余像素保留上一帧，因此结果与整帧重画逐像素一致（`zig build test-ui` 有对照测试，覆盖分数DPI、半透明移动图形、裁剪和透明窗口）。
- 下列情况整帧重画：首帧、尺寸/DPI/透明模式变化、平面重建或分离；帧里有分组、变换、元素效果、背景效果或背景着色器（其像素依赖周围内容）；启用了图层；损坏面积超过一半；上一帧失败或走了GPU。
- 帧完全相同则不重放任何命令，只呈现保留的平面。

`Context.damageStats()` 返回软件帧数、局部重画帧数和上一帧的损坏矩形。Windows 的 GDI 与 Direct3D 11 路径目前仍整帧重画。

`zig build smoke-damage` 通过屏幕外实际窗口读取系统更新区域，覆盖分数DIP、裁剪、合并、无效/空请求和关闭代数；Linux另在GDK_SCALE=2运行。核心测试还验证实际worker先返回WrongThread、旧句柄不能使复用槽失效。Windows/Linux ReleaseSafe均通过，未使用截图。

原生合同：[Windows InvalidateRect](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-invalidaterect)、[GTK queue_draw_area](https://docs.gtk.org/gtk3/method.Widget.queue_draw_area.html)。

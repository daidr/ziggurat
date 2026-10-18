# 客户区局部失效

`try window.invalidateRect(bounds)` 使用客户区 DIP，主线程调用，不分配、不立即绘制。有限坐标绝对值与尺寸各不超过1,000,000；宽高不能为负。无效参数返回InvalidGeometry，零面积为空操作，关闭中的句柄返回Closed。App仍须覆盖Window句柄使用期。

Windows按实际DPI转物理像素，边界向外取整并裁到客户区；GTK按逻辑widget坐标向外取整，再裁到DrawingArea尺寸，高DPI时允许覆盖更多物理像素。完全在客户区外的请求不产生更新。多次请求交由系统更新区域合并，不保存一个随历史请求增长的表。

原生失败使用window_update诊断并保留Window pin到sink返回。InvalidateRect只文档化布尔返回值，因此失败不附会旧GetLastError；缺少原生错误码时code保持null。错误路径仍清除上一操作的失败码，并允许sink延迟关闭窗口。

动画使对象移动或缩小时，宿主同时失效旧、新绘制边界，并计入stroke、shadow等外扩范围。只有采样的可见值改变才请求失效；nextWake为null时停止arm。重排布局、DPI/字体/主题变化、未知绘制外扩时使用完整`window.invalidate()`。原生系统还可以因曝光、resize等原因要求更大的区域，应用必须能随时绘制完整视图。

局部失效是原生damage提示。当前Context仍重建完整命令、hit和semantic候选，以成功帧原子提交；软件工作面、GPU回放/Present及分组合成仍可能处理全帧。此API不提供按控件保留显示列表或dirty-tile renderer，不据此承诺动画GPU成本只与矩形面积相关。

`zig build smoke-damage` 通过屏幕外实际窗口读取系统更新区域，覆盖分数DIP、裁剪、合并、无效/空请求和关闭代数；Linux另在GDK_SCALE=2运行。核心测试还验证实际worker先返回WrongThread、旧句柄不能使复用槽失效。Windows/Linux ReleaseSafe均通过，未使用截图。

原生合同：[Windows InvalidateRect](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-invalidaterect)、[GTK queue_draw_area](https://docs.gtk.org/gtk3/method.Widget.queue_draw_area.html)。

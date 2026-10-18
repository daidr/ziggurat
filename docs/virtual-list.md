# 可变行高虚拟列表

`ziggurat_virtual_list` 是独立、按需依赖 `ziggurat_ui` 的模块。它拥有行 ID、高度和位置索引，并把可见行提交给真实 `ui.Frame` 回调。基础 UI 不导入它；没有隐式测量、worker、timer 或 paint 分配。行文本、业务对象、scroll 和选中 ID 由应用持有。

本文描述基础 List。多选、列表键盘导航和 recipient 挂载由独立可选的 [Control](virtual-list-control.md) 提供；完整原生集合按平台单独验收，不能由位置索引或若干可见按钮代替。table、tree、自动估计高度、拖动重排和分组 sticky header 仍是后续工作。

## 所有权与更新

```zig
const virtual = @import("ziggurat_virtual_list");
const rows = [_]virtual.Row{
    .{ .id = 101, .height = 28.1 },
    .{ .id = 102, .height = 44 },
};
const list = try virtual.List.create(allocator, process_main_thread, &rows, .{});
defer list.close() catch unreachable;
```

`create` 返回一个拥有者指针；复制指针只是借用。分配器和进程主线程身份显式传入，所有方法包括查询和 `close` 都检查该线程。输入 records 被复制，构造完成后无需保留原数组；List 不借用其中任何业务对象。关闭前必须结束所有借用，关闭后不能继续使用指针。

`Row.id` 必须非零且唯一。`Row.height` 为 finite、positive、最多 1,000,000 DIP 的 f32；接受时向上量化为 1/64 DIP 的整数 ticks。`row(index)` 返回实际接受的高度，`rowTop(index)` 和 `totalHeight()` 返回 f64 DIP。全部总高度均由 u64 ticks 累加，反复增减不会积累浮点漂移。

`replace(rows)` 完整校验并构造新索引，成功后才交换并释放旧索引。重复 ID、无效记录、容量或 OOM 都保留旧列表；输入可以重新排序、插入或删除。`setHeight(id, height)` 更新已有行，返回量化后的高度是否变化；未知 ID 返回 `UnknownRow`。它不分配，也不自动修改应用的 scroll。

高度必须在显式更新/布局阶段由应用提供。宽度、字体、文本或业务内容改变时，应用先准备需要的高度，再调用 `setHeight` 或 `replace`。绘制回调不应借机触发整表测量。

## scroll、锚点与身份

scroll 使用 f64 DIP，与 Frame 的局部 f32 坐标分开。百万行总高度可能超过 f32 的细粒度表示范围；不要把它先存进 `ui.scroll.ScrollModel.offset.y` 再转换回来。应用可以自行把 wheel delta 加到 scroll 后调用 `clampScroll`。viewport 高度为 finite、非负且最多 1,000,000 DIP；零高度返回空可见区间。

可见末端直接比较行前缀与 scroll 的差值，不先形成 `scroll + viewport`；相等时保留减法残差以确定严格半开端点。总高度达到 10¹² DIP 时，极小正 viewport 仍能命中所在行或跨过的下一行，不会因加法舍入变成空区间。若 `total - viewport` 舍入回 total，正 viewport 的最大 scroll 取 total 下一个较小的可表示 f64 值；这时无法表达更近的起点。只有零 viewport 才允许精确停在 total。

```zig
const keep = try list.anchor(scroll, viewport_height);
try list.replace(updated_rows); // 失败时 scroll 和旧索引都不变
scroll = try list.resolve(keep, viewport_height);
```

锚点保存 `{id, old_index, intra_offset, global_end}`。`resolve` 优先找到同一 ID；删除后选择原 index 处的后继，越过末尾则选择最后一行。保留行内 inset；普通锚点的 inset 达到或超出新行高时收到该行最后一个 tick，保留仍存在的行 ID。最终 scroll 仍按新的内容和 viewport 范围 clamp。空列表解析为零。resize 后可以用同一个锚点和新的 viewport 高度重新解析。仅在零 viewport 且原 offset 正好为总高时，`anchor` 标记 `global_end`；这个特殊端点在替换、重排、插入或高度改变后始终跟随新列表的全局末端，恢复非零 viewport 时 clamp 到新的最大 scroll，不跟随旧末行的重排位置。

`indexOf(id)` 返回当前 index 或 null；`row(index)` 读取当前记录。选中 ID 只保存在业务状态中，重排无需复制或重建选中状态。删除所选行后的行为由应用决定，不悄悄选中新的 index。

`reveal(id, scroll, viewport, alignment)` 返回新的 scroll，不写入隐藏状态。alignment 支持 `nearest/start/center/end`；nearest 用最小变化显示整行，行比 viewport 高时对齐行首。应用可在键盘选择后调用它。

## 真实 Frame 绘制

```zig
fn paintRow(ptr: *anyopaque, frame: *ui.Frame, row: virtual.RowView) !void {
    const app: *AppState = @ptrCast(@alignCast(ptr));
    try frame.button(row.id, row.bounds, app.labelFor(row.id));
}

// 在 Context.draw 内调用；draw 本身是 void，错误由宿主处理。
_ = list.render(frame, bounds, scroll, .{}, .{
    .context = app,
    .draw = paintRow,
}) catch return;
```

`visibleRange(scroll, viewport)` 返回与半开 viewport 相交的半开行范围 `{first,end}`。它不加 overscan，不限制查询结果行数。`render` 默认在两端各加 2 行 overscan，最多回调 128 行；`DrawOptions.overscan` 可设 0..16，`max_visible` 可设 1..128，限制包含 overscan。超出上限会在任何行回调前返回 `VisibleCapacityExceeded`，不截断绘制后假装完整。

`RowView` 包括稳定 ID、当前 index、实际高度、f64 全局 top、Frame 坐标 `bounds` 和与 viewport 相交的 `visible_bounds`。全局 top 与 scroll 先在 f64 中相减，再加局部 bounds 原点并转换成 f32；不会先把长文档坐标截成 f32。巨高行的背景可以直接画 `visible_bounds`，避免用很远的边缘做局部绘制。overscan 行可能有零面积 visible bounds，它们仍算在回调预算内。

List 在回调期间保持 Busy：`close/replace/setHeight` 和嵌套 `render` 返回 `Busy`，只读查询仍可使用。回调的 context 和 RowView 只借用到返回。List 不分配、不查询字体或测量文本；业务回调自身的成本仍由应用负责。

render 保持窗口回调作用域，关闭会延迟到安全点。每个行回调后检查 Frame 错误和窗口关闭；出现错误立即停止后续行。回调必须平衡自己添加的 clip/offset。List 检测不平衡并恢复进入前的栈；命令容量耗尽时也恢复 Frame 栈元数据。绘制/参数错误会设置 `Frame.failure`，即使调用者 catch，Context 仍按既有规则放弃整帧及新的输入命中快照。线程错误和 Busy 拒绝不修改 Frame。

可见行的 `frame.button` 接入既有 UI 输入/焦点/单个控件语义，ID 应保持稳定。回调上限不是额外的 widget 容量：每行多个控件仍共同使用 UI 固定快照预算。应用自行处理 wheel、选择 ID 和键盘 reveal；List 不安装另一个输入状态机，也不宣称具有整表可访问性。

## 明确成本与验证

| 项目 | 规则 |
| --- | --- |
| 行数 | 默认 100,000；硬上限 1,000,000，可降低 |
| 持久显式预算 | 默认/最高 64 MiB，可降低 |
| 构造/替换峰值预算 | 默认/最高 128 MiB，可降低，不低于持久预算 |
| 构建 | 验证及 Fenwick O(N)，ID 排序 O(N log N) |
| 行定位、ID 查找、高度更新 | O(log N) |
| row(index)、count、totalHeight | O(1) |
| visibleRange | 两次有界 Fenwick 定位，O(log N) |
| render | O(log N + V)，V 包含可见和 overscan 行 |

在 64 位目标，显式数组为 `16*N` 行 records、`16*N` ID records 和 `8*(N+1)` Fenwick bytes，另有固定拥有者状态。`BuildStats.owned_bytes` 记录持久请求，`peak_owned_bytes` 包含替换期间仍存活的旧数组和候选；allocator 元数据、宿主输入 rows、Frame/原生 renderer 内存不计入这些字段。候选峰值检查先于分配。不使用全局 allocator 或隐式后台构建。

模块单测包含百万/十万行与定位节点数观测、3000 次 Fenwick/线性 oracle 随机差分、半开分数边界、末尾/零 viewport 锚点、重排/删除/resize、重复 ID、每个候选 allocation 故障、容量事务、跨线程拒绝和反复高度更新。百万行用例保留 1,000,000 DIP 行高，总高 10¹² DIP；独立线性 f128 oracle 覆盖末行极小 viewport、跨行及精确端点，还单独验证最小正 subnormal viewport/offset 的严格边界和 terminal clamp。

`zig build smoke-virtual-list` 在 Windows 隐藏窗口和 Linux 隔离 Xvfb 下实际提交 Frame，读取 renderer 内部像素，发送原生 pointer/wheel/key 事件，验证宿主稳定 ID 选择与 reveal。还覆盖 callback Busy、render 不使用 List allocator、callback/Frame/clip/offset/命令容量/可见行容量失败、旧命中快照保留、绘制中关闭与资源归零。这些自动化检查不构成屏幕视觉质量或整表可访问性验证。

# 显式布局

`ui.layout.arrange` 提供一维 row/column 的约束、grow/shrink、padding、gap、对齐与 overflow；`ui.grid.compute` 增加显式放置的二维轨道布局。两者计算 DIP 矩形，调用者持有输入与输出存储，绘制仍由 Frame 完成。

一维弹性布局的父尺寸由 `arrange(bounds,options,items,output)` 明确给定。`Item.main_max_percent` 使用百分数，50 表示父 inner main-axis 的50%，0合法，也允许大于100的有限非负值。基准是扣除两侧 padding 后、扣除 item gap 前的完整 inner 长度；row 对应宽度，column 对应高度。它与 `constraints.max` 取较小上限，再执行有界 grow/shrink，不通过反复扣除 gap 或其他 item 的尺寸改变百分比基准。

`content_minimum` 是调用者提供的内容最小尺寸，默认零。主轴的自动内容 minimum 先被已解析 max 夹住；`main_minimum` 为 null 时使用它，非 null 时显式替代它，包含显式0。`constraints.min` 始终是硬下界，优先于解析得到的百分比 max；独立的显式 `main_minimum` 优先于百分比或绝对 max。因此过大的显式 minimum 会留下 overflow。既有绝对 `Constraints` 仍须自身有效，绝对 min 大于其绝对 max 仍是 `InvalidConstraints`，不能用 minimum 优先级绕过该校验。cross-axis 的内容 minimum 被绝对 max 夹住，仍保留绝对 min 下界。

```zig
const items = [_]ui.layout.Item{
    .{
        .preferred = .{ .width = 180, .height = 24 },
        .content_minimum = .{ .width = 80, .height = 20 },
        .main_max_percent = 50,
        .grow = 1,
        .baseline = 17,
    },
    .{
        .preferred = .{ .width = 80, .height = 20 },
        .main_minimum = 0,
        .grow = 1,
        .baseline = 14,
    },
};
// 父主轴尺寸未知时，先求与百分比无关的内容 minimum / preferred。
const measured = try ui.layout.measure(.{ .axis = .row, .gap = 8 }, &items);
// 宿主选择确定的父尺寸，随后仅对这个尺寸解析一次百分比并分配。
var rectangles: [items.len]ui.Rect = undefined;
const result = try ui.layout.arrange(bounds, .{ .axis = .row, .gap = 8 }, &items, &rectangles);
_ = measured;
_ = result;
```

`measure(options,items)` 是父主轴尺寸未知时的内容测量，返回 `Measurement.minimum/preferred`，包含两维 padding 和主轴 gap；空项只包含 padding，没有 gap。它忽略百分比，但保留绝对 max、显式 minimum 和基线组的 ascent/descent。宿主随后选择确定父尺寸并调用 `arrange`；最终内容尺寸可以小于先前 preferred。测量不把所得尺寸再次作为百分比基准，不求隐藏固定点。宿主预解析约束时也须采用相同的未知/已知阶段，不能把绝对 max 当作百分比支持。

`Item.baseline` 是从自身 cross 起点到基线的有限非负 DIP 偏移。提供该值的项组成同一基线组，使用受约束的 preferred cross 尺寸，优先于普通 alignment，不参与 stretch。组的 ascent 为最大偏移，descent 为最大 `cross_size - baseline`，从 inner cross 起点排列；minimum 和 preferred 测量分别计入对应的 descent。偏移同时建立该项的 cross minimum，不能超过绝对 cross max。缺省项继续使用普通 alignment，不自动猜测字体基线。row 的偏移沿 y，column 的偏移沿 x；文本 shaping 和实际数值由调用者负责。

`arrange` 在空间不足时收缩到解析后的 minimum，无法容纳时保留完整内容尺寸和 overflow；基线组也可以沿 cross 方向溢出。`Overflow.clip` 返回 inner 矩形，`visible` 返回 null，由调用者显式配对绘制 clip。正常对齐、基线和 grow/shrink 都不会执行字体测量、原生调用或分配。

一维布局最多256项。百分比使用 f64 中间值，尺寸、位置、远边界和最终结果须能表示为有限 f32；非法约束、容量不足或溢出时不写任何调用者矩形，成功时只写 `items.len` 项。求解使用固定栈数组，grow/shrink 按容量/权重阈值排序后饱和分配，复杂度为 `O(I log I)`，不随 DIP 距离迭代。与先前一维实现相比，事务暂存增加4096字节，已解析主轴上下界增加4096字节；这是固定数组载荷，未宣称编译后的总栈帧大小或运行耗时。

```zig
const columns = [_]ui.grid.Track{
    ui.grid.Track.fixed(120),
    ui.grid.Track.minmax(80, 240, 1),
    ui.grid.Track.fraction(2),
};
const rows = [_]ui.grid.Track{ ui.grid.Track.fixed(32), ui.grid.Track.fraction(1) };
const items = [_]ui.grid.Item{
    .{ .row = 0, .column = 0 },
    .{ .row = 1, .column = 1, .column_span = 2, .minimum = .{ .width = 100, .height = 40 } },
};
var rectangles: [items.len]ui.Rect = undefined;
const result = try ui.grid.compute(bounds, &columns, &rows, &items, .{
    .padding = ui.layout.Insets.all(8),
    .column_gap = 8,
    .row_gap = 6,
}, &rectangles);
if (result.clip) |clip| try frame.pushClip(clip);
// 按 rectangles 绘制内容；需要 clip 时由调用者配对 popClip。
```

每轴最多 64 条轨道、最多 256 个 item。`Track` 的 `min/max/fr` 明确约束：`fixed` 固定尺寸；`fraction` 用正权重分配剩余空间；`minmax` 组合上下界与权重。`fr == 0` 的可增长轨道采用内容 preferred 尺寸；`Track{}` 即无上界的内容轨道。`max` 可为正无穷，其余尺寸与权重必须有限且非负。

先处理全部 item minimum，再处理 preferred。每阶段按 span 长度递增，同一 span 的请求都基于同一组前快照计算；每条轨道取各请求提案的最大尺寸后统一提交。因此相同放置与约束不因 item 声明顺序变化而改变轨道尺寸。重叠 span 可使另一个约束获得额外空间，但不会撤销已满足的 minimum。preferred 只增长 `fr == 0` 的轨道；之后正 fr 轨道按权重分享剩余空间，达到 max 后将剩余份额分给其他轨道。

内容轨道的 preferred 超出可用空间时，按超出 minimum 的容量比例收缩；minimum 阶段的完整轨道快照是下界，因此已满足的跨格 minimum 不被破坏。固定轨道与正 fr 轨道不参与这一步。轨道不自动缩到 minimum 以下。如果固定尺寸、最大尺寸或 minimum 已无法容纳，结果保留 `content_size`、`overflow` 和 `unmet_minimum_items`，由应用决定滚动或改变约束。item 的 `align_x/align_y` 可覆盖默认 stretch；非 stretch 使用 preferred 与 minimum 的较大值，并限制在已求出的 cell 内。`justify_columns/justify_rows` 在轨道达到上界后对剩余空间作 start/center/end/space_between 分配。padding 大于容器时 inner 尺寸为零，溢出依然显式报告。

显式 `compute` 的 row/column 与 span 必须指向已有轨道，span 非零。`compute` 返回非法轨道、几何、放置、容量或坐标溢出错误；失败时不改写输出矩形。成功时输出顺序与输入 item 相同。函数无分配器、无堆分配，也不执行原生操作。

固定工作存储与输出暂存均在栈内。设 item 数为 I、列数 C、行数 R：按 span 分组扫描为 `O(I × (C + R))`，每个约束只在所属 span 组求解一次；饱和阈值排序为 `O(I × (C log C + R log R))` 的上界。`Result.metrics` 提供 item 访问、轨道访问和阈值比较次数，工作量不按 DIP/像素距离循环。最大规模单元测试实际求解 64 × 64 轨道、256 个重叠跨格 item，并对普通及极大视口的访问/比较次数设界；另有全部 24 种声明排列、span 重叠、上下界、溢出和极端权重回归。这些是算法行为检查，不是帧率基准。

`AutoItem` 的 row/column 可省略。`placeAuto(explicit_column_count, explicit_row_count, items, options, placements)` 仅计算放置；`computeAuto` 将放置和轨道求解组合为一次输出事务：

```zig
const items = [_]ui.grid.AutoItem{
    .{ .row = 0, .column = 1 },
    .{ .column_span = .{ .count = 2 }, .preferred = .{ .height = 24 } },
    .{ .column_span = .to_end, .preferred = .{ .height = 40 } },
};
var rectangles: [items.len]ui.Rect = undefined;
var placements: [items.len]ui.grid.Placement = undefined;
const result = try ui.grid.computeAuto(bounds, &columns, &.{}, &items, .{}, &rectangles, &placements);
```

先保留完全显式的 cell，再为固定 row 的项找列，最后按输入顺序为固定 column 与全自动项使用同一 row-major 稀疏 cursor。cursor 只向前，不回填之前的洞。显式 cell 默认可重叠，绘制次序仍由应用决定；自动项绕过这些 cell 的 occupancy。设置 `PlacementOptions.reject_explicit_overlap` 可拒绝显式重叠。占用以 64 个 `u64` 位集表示，span 检查按行做 mask 操作，不逐像素迭代。

显式 column 位置或 count span 超出初始列时，先在 64 列容量内增加隐式列，再按需要增加行，最多 64 行。新增行列默认使用 `Track{}`，按内容 preferred 尺寸增长；`AutoOptions.implicit_row/implicit_column` 可分别改变约束，显式轨道保持原值。省略所有配置轨道仍提供一列内容轨道；空布局还提供一条零高度内容行。`Span.count` 必须大于零；`Span.to_end` 始终绑定初始配置的末轨，无配置时按一条默认内容轨道解析，不因其他 item 扩出隐式行列而改变含义。放置超出行容量返回 `GridFull`；位置/span 超过轨道上限返回 `InvalidPlacement`。非法放置、重叠策略或后续求解失败时，rectangles 与 placements 均保持原值。

`computeMeasured` 增加显式 `Measurer`，提供 `intrinsic(context,index)` 与 `constrained_height(context,index,width)` 两个回调。成功路径每项各调用一次：先取得 minimum/preferred 并分配宽度，再按实际 item 宽度测高度，最后重新求解行。第二回调只返回高度，不能改变列宽，因此没有隐藏固定点循环。内部有一次放置预检与两次有界求解；返回的 metrics 属于最后一次求解。应用负责字体、换行、缓存、回调成本与错误；任何回调失败都不改写调用者输出。回调期间输入切片必须保持有效且不变，计算本身无共享全局状态，可由调用者显式重入。

自动放置最多检查 `I × (C + 1) + R × C` 个候选位置，每个候选检查至多 R 个占用 mask，另有每项至多 R 次置位；`PlacementResult.metrics` 记录实际候选与 mask 检查数。测试实际填满 64 × 64 cells，验证稀疏 cursor、显式与自动混用、跨格、配置末轨、隐式内容行、满容量与失败事务；测量测试验证已分配宽度驱动最终行高以及回调错误。

二维网格当前范围不包含命名区域、subgrid 或网格内 baseline 对齐；一维基线组使用上面的独立 `Item.baseline`，不改变网格的 `Align` 类型。测量接口不替应用选择字体或实现完整 shaping/换行引擎；它明确连接应用的测量结果与布局求解，不等同于完整 CSS Grid。

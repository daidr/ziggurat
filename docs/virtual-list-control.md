# 虚拟列表控件

`ziggurat_virtual_list.Control` 在一个拥有者中组合基础 `List`、选择状态和可选 UI 接入。基础 `List` 的字段、分配和依赖保持原有合同；只使用索引或自行组织输入的应用仍可直接使用它。`Control` 的查询、更新、挂载和关闭都要求创建时明确传入的进程主线程身份。

```zig
const virtual = @import("ziggurat_virtual_list");
try context.prepareRecipients(allocator, .{ .recipients = 4 });
const control = try virtual.Control.create(allocator, process_main_thread, rows, .{});
defer control.close() catch unreachable;
try control.attach(context, 70);
```

传入的 rows 必须在调用返回前保持不变，包括 caller allocator 的回调期间。构造复制行记录，成功返回后可以释放输入。Options 的标量、预算、context 和回调在首次分配前通过独立边界捕获；allocator 回调改变调用者原 Options 不会改变本次操作。`Control.model()` 只借用同一个只读 List，不转移所有权；不能绕过 Control 修改或关闭该 List。

Context、Window 的 App、回调 context 以及 allocator 必须满足各自的稳定地址和存活合同。`close()` 先撤回注册，再回收业务模型。进入中的绘制、输入或业务回调持有借用；在这些回调内关闭会返回 `ResourceInUse` 并留下已退役的壳。回调返回后再次关闭才回收壳，不能把该错误当作已经释放。

## 选择、滚动与输入

`rowToken(id)` 返回 `{id, incarnation}`。重排和行高变化保留仍存在行的 incarnation；删除后再加入相同 ID 会获得新 incarnation。旧 row token 不能操作新行。结构 revision 只在替换、顺序或实际行高变化时推进；选择 revision 单独推进，所以多次输入可以在下一次 paint 前连续更新选择。

`select(token, mode)` 支持 replace、toggle、extend 和 add_extend；`selectAll`、`clearSelection`、`selected`、`selectedCount` 和带 revision 校验的 cursor 提供批量操作及遍历。caret 与 anchor 单独保留。`replace` 保留仍存在 ID 的选择、caret 和 anchor，删除的项消失；滚动使用原可见锚点在新模型中重新解析。`setHeight` 同样保留可见锚点。`setScroll` 和 `scrollOffset` 使用 f64 DIP，并明确接受当前 viewport 高度。

绘制调用 `control.draw(frame, bounds, name, renderer, options)`，行回调收到基础 RowView、row token、selected、caret 和 anchor。绘制只读取业务状态，不提交选择或滚动变化。一个 viewport 注册一个输入 recipient；行回调可以绘制内容，需交互的子控件仍使用 UI 原有预算和命中优先级。

| 操作 | 行为 |
| --- | --- |
| 普通主键点击、拖动 | 替换并扩展连续选择 |
| Ctrl 点击 | 切换该行 |
| Shift / Ctrl+Shift | 从 anchor 扩展 / 累加扩展 |
| 次键点击 | 已选行保留整个选择，否则选中该行 |
| 上下、Home/End、PageUp/PageDown | 按当前行高移动 caret 并 reveal |
| Ctrl 导航 / Shift 导航 | 只移动 caret / 扩展选择 |
| Ctrl+A、Space、Enter | 全选、选择 caret 行、调用 activated |
| viewport 上的 wheel | 更新滚动，不取得控件焦点 |

焦点只在成功呈现后可取得。冷业务操作和 Catalog 准备只校验注册 membership，不授予输入或 native action 权限。成功帧将模型结构 revision 和实际 scroll 一起保存为 receipt。失败或取消的候选帧保留旧命中、旧坐标和旧 receipt；指针按实际呈现的 scroll 定位。结构更新后，旧画面不再授予新行输入权限，直到新帧成功。单独选择变化不使该 receipt 失效。

拖到 viewport 外时，可选 `edge_scroll` 回调通知宿主启动或停止明确拥有的 deadline。启用该功能的 Window 必须显式设置 `native_pointer_clicks = true`，为原生按下状态准备固定拥有者。宿主在该 deadline 调用 `advanceDragScrolling(seconds)`；参数为有限的 0..1 秒，速度由 `edge_max_speed` 限制。该方法检查原生 held 凭证、仍活动的 recipient、结构 receipt 和当前 viewport；它不复用仅限原生 down/up 回调的 timing snapshot。普通指针按已呈现 receipt 定位；显式 deadline 按推进后的业务 scroll 计算 range，因此连续 deadline 无需等待 paint。viewport 外的指针夹到相应 viewport 的半开可见范围，越界距离只决定滚动速度。失败 paint 保留旧 native/hit front，不回滚已经提交的业务选择和 scroll。控件不创建 timer、worker、等待或 idle redraw。焦点撤回、手势结束、更新、关闭或按下失效都会停止该请求。

## 完整原生集合

完整原生集合在 Windows 使用现有 Window UIA 根；Linux 当前返回 `UnsupportedPlatform`，不借列表接口宣称存在完整 UI ATK 根。原生路径须启用 UI accessibility 并显式准备 recipient、坐标和列表预算。当前公开挂载链已通过两平台 pure 回归；Windows 完整集合的原生运行验收单独记录，不能由该 pure 结果替代。

```zig
try context.prepareVirtualLists(.{ .lists = 1 });
// create 的 native_semantics 必须明确为 true。
const input = try control.snapshotCatalog(allocator, labels, .{});
defer input.close();
const product = try virtual.Control.NativeCatalog.prepare(input, native_model_budget);
errdefer product.close();
try control.installCatalog(product); // 成功消耗 product；失败仍由调用者拥有。
```

labels 明确提供每一行 ID 和 UTF-8 名称，顺序与当前 rows 一致。描述符和文本在 snapshot 返回前保持不可变。snapshot 使用同一索引中的实际 ticks、incarnation 和已排序 ID；不临时复制另一份 N 行描述符。返回的不可变 input 可以交给应用明确创建的 worker，`NativeCatalog.prepare` 复制为只含 C 所有权的 product；worker 完成后用 `App.post` 将 product 交回主线程安装。post 失败时调用者仍拥有 product。安装重新校验注册、结构和完整行数，并从当前选择种子初始化；后台准备不能把较新的选择倒退。

原生集合包含所有行的名称、逻辑导航、ItemContainer 查找、Selection/Selection2、SelectionItem、VirtualizedItem 和 ScrollItem。屏外行保留完整语义，Realize 不创建另一个业务行或隐式 worker；ScrollIntoView 排入主线程更新并等待正常成功 paint 发布。原生请求在请求时捕获注册、model、publication、row 和 incarnation；延迟队列里的旧请求不能在 dispatch 时按相同 ID 找到新行。

普通语义节点、recipient keys、列表选择 bitmap 和 viewport/mapping 在同一个 C State 锁内发布成功 front。选择事件只传本次改变的 words；成功 paint 只复制累计触及的 words。失败 paint 不发布 pending 选择或滚动。COM getter 在锁内复制可变选择/viewport，标签读取通过不可变 Model pin 保活；原生对象和迟到请求不借用 Zig 模型、Context 或 caller allocator。关闭先撤回，再在锁外执行 COM disconnect。

## 预算与复杂度

基础 List 仍按 [基础列表合同](virtual-list.md) 计费。Control 另有明确的 `adapter_bytes`、`model.bytes` 和替换 `model.peak_bytes`，构造前检查预算。百万行的选择/incarnation 数组请求为 9,125,000 bytes，另加固定模型头；事件和 paint 不使用 Control allocator。选择范围操作在事件阶段按触及 words 工作，绘制为 O(log N + V)。

recipient receipt 每个显式槽增加 32 bytes，Mark、Input 和 Context 没有新增大数组。完整集合另计 Store/ledger/binding metadata、动态 Model、Provider 和请求 scratch，`virtualListStats` 分项报告实际请求。64 位布局中 Store 为 984 bytes、ledger 24 bytes、每个 list binding 4608 bytes；这些成本仅在 `prepareVirtualLists` 后出现。UIA row provider 为 128 bytes，只保留轻身份和 C State；它不为每个外借 provider 复制标签。

不可变 Catalog 默认上限为 1,000,000 行、64 MiB owned、8 MiB 文本、每标签 4096 bytes；native Model budget 单独限制实际仍存活的 Model bytes。首次 adopt 计费，实际最后 free 才退回，迟到 getter pin 不能通过反复替换绕过预算。Selection front/pending、validation scratch 和累计 dirty journal 显式包含在该 Model 请求中。所有额度、OOM、旧模型和失败帧都保留旧成功发布；预算不包括系统 SDK 自身的 opaque 分配。

# 2D affine scope

自绘 UI 可显式准备有界的离屏源面，再把完整源面作为一个 2D affine scope 合成。文字、渐变、图片、遮罩和控件先在同一局部平面绘制，再一同变换。普通 Context 不分配变换工作区；这项能力没有引入刷新时钟。透视和 3D 不在当前接口范围内。

```zig
try context.prepareTransforms(allocator, .{
    .layers = .{ .size = try window.contentSize(), .max_depth = 4 },
    .source_size = .{ .width = 400, .height = 240 },
});

// 在 draw 回调内；source_size 为本 scope 的实际局部 DIP 范围。
try frame.beginTransform(.{ .width = 400, .height = 240 }, .{
    .xx = 0.8, .yx = 0.6, .xy = -0.6, .yy = 0.8,
    .x0 = 180, .y0 = 20,
});
try frame.button(7, .{ .x = 20, .y = 20, .width = 120, .height = 30 }, "Apply");
try frame.captureSpace(40, .{ .x = 20, .y = 70, .width = 300, .height = 80 });
try frame.endTransform();
```

`prepareTransforms` 在绘制回调外准备候选。`layers.size` 是当前窗口的像素尺寸与 scale；`source_size` 是每层允许的最大局部 DIP 尺寸。每个 `beginTransform` 的源平面原点固定为 `(0,0)`，其实际范围必须落在准备上限内。源面可以大于窗口，因此原位置在窗口外、变换后进入窗口的内容仍能绘制。超出源范围的内容会被裁掉。

`Affine` 使用 `{xx,yx,xy,yy,x0,y0}`，局部点映射为 `(xx*x+xy*y+x0, yx*x+yy*y+y0)`。子 scope 的矩阵映射到父 scope；父级 `pushOffset` 先参与该组合。提交的矩阵会统一收窄为可由各原生后端使用的数值；绘制和逆向命中使用这份数值。负缩放可用，奇异、病态、非有限值和超限几何明确报错。`pushOffset` 仍只表示平移。

scope 内 `frame.size` 表示本地源面的像素尺寸，`frame.sourceBounds()` 返回精确 DIP 范围；`frame.windowSize()` 返回原窗口尺寸。子级 clip 和 group bounds 在本地坐标中定义，父级 clip 在最终合成时应用。嵌套 group/transform 共用最多四层的栈；opacity 和 mask 按其 group 应用一次。栈不平衡使整个候选帧失败。

容量为每帧最多 64 个变换命令、64 个显式捕获 Space、128 条几何 clip、128 个控件和 128 个语义节点。clip 祖先最多 32 层。`render_work` 限制预检估算的源面/合成访问量，默认 128 Mi 次、上限 512 Mi 次，不是墙钟期限。准备时检查旧资源与候选像素、Zig 变换快照和可选 native UIA 几何的合计预算；`transformStats()` 报告当前元数据和代数，`layerStats()` 单列原生后端元数据。预算不包括驱动、系统绘制栈及全部系统对象内部内存。像素池、透明 guard 和采样精度见[渲染边界](affine-rendering.md)。

## 输入与已提交 Space

控件的 bounds、range track 和步进按钮均使用局部坐标。命中先逆变换，再检查全部 clip，旋转后的外接矩形角落不会误命中。禁用控件只在其实际形状内遮挡；拖动捕获允许位置越出 clip，释放和取消仍遵守控件原有规则。Tab/键盘动作保留稳定 ID，方向导航使用裁剪后的窗口几何。

`captureSpace(id,bounds)` 只登记本候选帧。成功显示后，`context.committedSpace(id)` 返回借用 `SpaceToken`；它包含 Context 身份与不回绕的帧代数。Context 必须覆盖 token 的使用期，每次方法调用都会固定当前 Window/Region 并检查代数。新成功帧、释放资源或 detach 后旧 token 失效；失败帧保留旧 token、输入与语义快照。

token 提供 `contains`、`localPoint`、`windowBounds`、`mapEvent` 和 `setTextCaret`。业务输入先用 `contains` 判断 pointer-down 是否属于编辑器，再用 `mapEvent` 转换 pointer/wheel 的位置。默认保持 wheel 的轴和滚动量；显式 `.wheel = .local_vector` 才逆变换其 delta。键盘、文本和 composition 字节不做坐标变换。捕获拖动需要映射范围外的点，不能用 `contains` 拦截每次 move。

`token.binding()` 产生显式借用 `SpaceBinding`，供 retained 客户端跟随同一稳定 ID 的后续成功帧。它另保存工作区不回绕 epoch 和 Window/Region 身份；释放重建、detach、区域代数改变不会因为同地址同 ID 而复活。成功的同工作区 reprepare 保留绑定。`resolve()` 获取最新 token；新成功帧没有该 ID 时返回 `SpaceNotFound`，失败帧继续使用上一快照。

编辑器持有的选择、布局与滚动仍属于应用。绘制时在同一变换 scope 内调用编辑器；事件处理使用对应已提交 token。原生 IME 光标通过 `token.setTextCaret(local_caret)` 提交裁剪后窗口 AABB，零宽 caret 按线段处理。系统候选窗口使用这个轴对齐锚点，不旋转系统输入窗口。直接把局部 caret 交给 `Window.setTextCaret` 会产生错误坐标；尚未采用 Space 的编辑器宿主不能宣称支持变换输入。

DocumentEditor 的原生客户端先正常 `bind(window)`，成功显示后显式 `adapter.setCommittedSpace(token)`；bounds、缓存布局、CodeEditor popup 均保持局部 DIP。应用把事件经 token 映射后只转发一次。Adapter 通过 `SpaceBinding` 检查原生 read/change 与输入权限，并在派生 index 的外部分配返回后、提交本次正文改动前再次检查原绑定。实际 Document mutator 调用期间另安装无分配的 `CommitGuard`，在 Document 自身候选准备结束、纯发布前验证原 Window/token/Space；guard 到字段发布之间没有外部分配或释放。它只覆盖本次原生修改，不限制其他阶段宿主主动提交的独立编辑。真正提交过的编辑不会因为后续布局/光标更新失败而回滚；旧资源释放期间宿主另改正文会使派生 index 明确失效，不能重发已经提交的编辑。`syncNativeCaret()` 只读取已准备布局，可由成功 front hook 调用，不隐式 shape 或 prepare。`clearCommittedSpace()` 显式切回窗口坐标；unbind 在其他清理前撤销借用。Context 必须覆盖该绑定及 unbind 回调的完整使用期。它没有引入第二份正文或选择权威，也不依赖 UIA。

需要把宿主动作组合成原生输入事务时，使用 `var scope = try adapter.beginNativeInput(window); defer scope.end();`。作用域借用已绑定的 Window、文本 token 和 Space，并固定 Adapter/Window 寿命；内部每次修改仍单独通过 Document 最终提交守卫。嵌套作用域按逆序结束，保留最初授权；撤销或替换绑定不能通过再进入恢复。App 已进入 stopping/stopped 时也返回 `Closed`，不必等待原生窗口销毁。作用域不得复制；普通程序化编辑不因此自动受原生焦点或坐标限制。

## 显式可访问性来源

`Context.installAccessibilitySource` 借用单个 `AccessibilitySource`，返回带 Context 身份和单调代数的 token；`clearAccessibilitySource` 只撤销匹配的入口。来源的 `query` 可处理原生查询，返回 null 时回落到原控件 Bridge；可选 `position_changed` 只处理窗口原点变化。`phase` 接收 `frame_begin` 和 `committed`：前者在候选帧就绪、draw 前调用；后者只在同一来源已收到 begin 且坐标/输入提交后调用。失败帧不发 committed；draw 中新装的来源等待下一帧。hook 不能用来隐式准备布局。

query、phase、position 共用固定 entry pin，并受 Window/Region scope 保护。clear、replace 和 detach 先撤入口，最后一个旧回调返回才调用一次 `unbound`，此后来源可释放自己的 context。两个固定 entry 槽允许在旧回调内替换一次；两个槽仍被占用时继续替换返回 `Busy`。通知 old-source unbound 之前已发布替代入口，因此回调关闭 owner 后，刚返回的 install token 可能已经退休；不能据其返回推断窗口仍存活。不把来源返回的全文范围、role 或 geometry 从绘制命令猜出，也不自动合并独立全文根和控件树。

独立来源可在 draw 中用 `Frame.coordinateMapping(local_bounds, &output)` 导出单个 bounds 的值型 forward/inverse 与准确凸裁剪，不复制整个 Frame 或几何表。它要求当前已安装的 source，只能在对应成功 `committed` 回调内用 `checkCommitted(context)` 发布；Source 槽与候选帧使用独立不回绕代数，失败帧不能混成旧 front，来源替换立即失效。输出还核验 Window/Region 和工作区 epoch，自己不保活这些借用对象。这个零分配出口不是输入授权或可长期解析的 SpaceBinding。

启用原控件 semantics 的 Frame 可在同一 draw scope 中调用 `frame.semanticLocalBounds(ids, output)`，一次批量读取已记录节点的真实局部矩形，再把它们的 union 交给同一 scope 的 `coordinateMapping`。输入最多128个 ID，输出至少同长；成功只写前 `ids.len` 个 Rect，任一错误保留整个输出。空批仍验证 Frame 和完整 Tree 后成功，重复请求 ID 返回重复矩形。容量错误为 `SemanticExportCapacityExceeded`，不存在为 `MissingSemanticNode`；未启用或没有变换 Snapshot 为 `SemanticGeometryRequired`，Tree 与当前 pending Snapshot 的身份/节点长度不一致为 `InvalidSemanticGeometry`，节点的 space 或 clip 与当前 scope 不同为 `SemanticScopeMismatch`。Linux 构建在编译期不保留原控件 Tree，公共入口在相同 live/main-thread/source/candidate 校验后返回 `SemanticGeometryRequired`，没有因此启用 AT-SPI 或 affine auxiliary。

该查询直接读取同一 Snapshot 的 semantic descriptor，不从窗口 AABB 反推矩形。descriptor 已包含记录时的 `pushOffset`；相同 Ref 不表示记录偏移相同，出口以当前 Frame.offset 精确重基。减法结果必须可用 f32 Rect 表示，原点、宽高以及平移后两端点都必须精确恢复原 raw 矩形，否则返回 `InvalidGeometry`。例如不同整数 offset 可以精确重基；很大的 offset 或不可精确表示的小数差值可能拒绝，不能用舍入/epsilon 静默移动控件。完整 Tree/UTF-8/父子关系和 descriptor Ref/clip 链只校验一次，再有界查找所有 ID。临时栈最多128个 Rect（2 KiB）；没有堆分配、表追加、native 查询、额外持久字段或可逃逸查询 token。此出口只证明本候选的数值几何，不授权输入或原生动作，也不表示已开启 affine controls 桥。

全文 provider 可显式开启 `Bridge.Options.affine_geometry`，在 paint 外准备预算内映射存储，在各源实际绘制 scope 内记录。MTA 只读取独立原生数值，不接触 Frame/Adapter/Context；精确 polygon 决定 point 命中与 cell 裁剪，系统 bounds 才取 AABB。详细容量、默认 identity 成本和未支持项见[文档可访问性](document-accessibility.md)。

## 发布、失败和回收

命令、输入映射、捕获 Space 和语义几何使用同一帧事务。失败预检、绘制失败及尚未接受的呈现保留上一成功帧的快照。成功的同尺寸/scale 重新准备资源也保留已提交 front 和映射，直到新帧成功。准备/释放是主线程上的显式操作；外部 allocator 和原生回调可请求关闭，外层 Window/Region scope 保持 Context 到回滚结束。

`releaseTransforms`、切回 `prepareLayers` 或 `releaseLayers` 在已提交帧仍含 transform 或 captured Space 时返回 `ResourceInUse`。先成功提交不含两者的普通帧，再显式释放。detach 总会清理工作区和原生资源。不得复制或提前释放 Context、descriptor storage 或借用 token 的所有者。

Windows UIA 的 native 快照复制逆矩阵与 clip 链，跨线程 provider 不读取 Zig Context。节点 bounds 返回裁剪后的窗口外接矩形，`ElementProviderFromPoint` 检查精确局部形状。窗口移动只更新缓存的 screen origin，不重排或重绘。关闭先断开 Context，迟到 COM 引用返回 `ElementNotAvailable`。Linux 当前没有对应 AT-SPI 实现。

## 验证范围

`test-affine`、`test-affine-state` 覆盖逆矩阵、收窄、凸裁剪、越界、容量、回滚和代数；`test-ui` 覆盖 Frame/Input 的候选发布。`smoke-affine-ui -Daccessibility=true` 在 Windows 隐藏窗口中验证旋转控件、离轨拖动、编辑器文本、真实 IMM 光标、UIA 客户端/精确命中/移动、失败帧、准备重入关闭和立即释放 Context。Linux 同目标使用私有 Xvfb/Openbox、GTK pointer/key/IM commit 与 Cairo，验证原生 caret-location 提交及资源归零；它没有证明输入法候选 UI 或 AT-SPI。原生像素与 GPU 检查由 `smoke-affine-renderer` 覆盖。这些自动化检查不等同于人眼视觉质量评估。

`smoke-affine-document` 分别运行 DocumentEditor 和 CodeEditor，验证原生文本提交、Windows IMM reconversion/位置或 GTK surrounding、成功 phase 光标重定位、缺失 Space/重建工作区、Adapter 与 Document 候选分配期间撤销/关闭/停止 App 后原生编辑不改正文、嵌套输入作用域，以及单事务正文+最终选择的 OOM/undo/redo。

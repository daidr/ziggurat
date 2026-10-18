# 文档词与逻辑行选择

`document_editor.Adapter` 可显式启用主按钮多击选择。它用于一个 Document，接收原始窗口 DIP 输入，支持普通坐标或显式绑定的 committed Space，以及正常滚动。折叠、projection 和 Diff 不接受此配置。文本、选择、组合和 undo 仍由同一个 Document 拥有。

窗口构造时设置 `native_pointer_clicks=true`；布局参数显式设置 `font.word_ranges=true`，完成 `prepare` 和 `bind` 后调用 `preparePointerSelection(window)`。它不自动更改字体选项。默认不开启词索引或手势 owner。缺少原生能力、词索引、合法几何或可用代数时，准备失败，保留先前拥有的资源。

宿主对每次 pointer down/move/up 调用一次 `handlePointerEvent(window, event, bounds, parameters)`。返回的 `PointerResult` 区分：

- `handled`：这一编辑器路由是否消费事件。false 可以转交别的消费者，不能再把同一事件交给此 Adapter 的 `handleEvent`。
- `selection_committed`：请求的选择已经被接受；幂等选择也可为 true。
- `input_error`：准备或权限失败，未提交请求的选择。此前组合取消可能已完成，不能据此重放输入。
- `presentation_error`：选择已经提交，随后布局或原生 caret 展示失败。修复条件后显式 prepare，不能重发选择。

启用后，原 bool `handleEvent` 的 pointer 分支委托同一路径、通过诊断报告这两类错误，并保留 handled 结果。失效 receipt、错误绑定、重复动作、失去词配置或不支持的几何都拒绝此动作，不回落为普通 caret。

第一击在 down 选择 grapheme caret；第二击 down 选择系统 Layout 的词或连续非词区间；第三击 down 选择完整逻辑 LF 行，包括其 LF/CRLF 终止符；第四击重新从单击开始。逻辑行不是软换行后的视觉行，也不是被视口截断的文本。词区间夹在该段落内容中，不越过行尾 LF/CRLF；空段落的词区间为空。各平台的系统词法边界允许不同。

up 完成最后一次拖选，不重复 down 动作。双击或三击后的拖选按完整词/逻辑行扩展，反向跨过起点时以原区间另一端为 anchor。Shift 作为单击延伸当前 Document anchor，并中断多击连续性。Ctrl/Alt/Super 组合由宿主在转发前处理；此路由返回 `UnsupportedPointerModifiers`。没有可靠原生 timing 的当前动作仍可单击，但不建立连续历史。语义计数不采用窗口 raw count。

`clearPointerSelection()` 撤销词/行手势并让下一次新按压恢复普通 caret。已发行的旧 down、旧 held up 不能借 clear 或 reinstall 再次动作。owner 的记账分配保留到 Adapter.close；clear 不释放它。TextClient unbound 撤销当前绑定权限，后续绑定须显式 prepare 才重新启用词/行手势。键盘、原生文本/组合、失焦、取消和显式滚动会中断相应拖选/历史；没有额外定时器或 dispatcher。

输入沿用现有 Adapter client/Window scope。所有 Layout probe 及其释放发生在该 scope 结束前；scope.end 可触发 unbound/on_closed 并释放 Adapter，之后没有 Adapter 或预算访问。Document、Engine、allocator 维持原有生命周期合同。

## 同一个已提交编辑 surface

宿主在绘制的同一个 transform/clip/offset scope 内调用 `frame.captureSpace(id, bounds)` 和 `adapter.draw(frame, bounds, colors)`。一次成功 paint 后，用 `adapter.setCommittedSpace(try context.committedSpace(id))` 绑定；Context 的稳定地址覆盖使用、解绑和关闭。随后传给 Adapter 的 pointer 与 wheel 事件保持原始窗口坐标，不能先调用 `SpaceToken.mapEvent`。`bounds` 必须精确等于 capture 的局部 bounds。

该 binding 跟随原 workspace、Window 和 Region 的后续成功前台。输入先取得原始 native receipt，再用一次已接受映射处理位置；wheel 只映射命中位置，保留物理轴策略。正文外或精确 clip 多边形外的 down 与其真实 paired up 都不消费。该配对处置不是权限：up 仍须通过当前 Core receipt；新 primary down、clear、解绑或 binding 变更会退役记录。其他按钮或程序选区变化不会把这个 outside up 重新变成正文动作。

成功重绘总会获得新的 frame generation。若同 ID 的局部 bounds、前后矩阵及完整 clip chain 精确相同，则沿用几何 version，允许下一击或既有拖选继续。成功改变 transform、clip 或 bounds 会使旧 held continuation 失效；失败 frame 保留原前台。成功 frame 缺失该 ID 时，后续 pointer、原生文本 read/change 和 caret 同时失去坐标权限。release/reprepare 的旧 binding 不会复活，须重新显式绑定。

每次输入另外捕获精确 frame generation。分配、原生文本验证、Layout/probe 释放等外部调用后，以及 Document 最终修改前，都核验同一次输入；中途即使以同 ID 发布了几何相同的新 frame，旧事务也不能继续提交。几何 version 只证明跨事件连续性，不替代这条提交门。普通 `clearCommittedSpace()` 显式恢复窗口坐标，并撤销既有手势。

原生 TextClient、组合、选择和候选 caret 使用同一个 binding；不注册第二 publisher。宿主在更新阶段调用 `syncNativeCaret()`，以刚接受的 Space 刷新候选位置；查询和 draw 不隐式 prepare。已有可访问性桥仍是独立显式消费者，本路径不扩大它的平台或投影能力。

owner 从现有 Adapter 预算显式分配且完整大小限制为4096字节；当前 Linux Debug 为一次1856字节分配，clear/reinstall 复用它。本批实测 Adapter State 仍为3008字节，NativeInput 从192增至200、NativeInputScope 从216增至224；Context/Input/Frame 的固定记录不因该 surface 增字段。显式 transform workspace 的两个64项 capture bank 各项新增一个 u64；提交仅执行有界几何比较，不分配或回调。默认绘制不构造 owner，也不请求词边界。这些是特定构建的记录尺寸与 caller 分配，不是完整调用栈、SDK 内存或运行性能测量。

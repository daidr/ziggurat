# 原生文本上下文桥接

窗口可显式选择系统输入或键盘/本地 compose；接口、取消交接与平台能力边界见
[窗口文本输入模式](text-input-mode.md)。它沿用本页唯一 TextClient/Document。

核心 `Window.setTextClient(client)` 注册一个显式借用的文本客户端，返回包含窗口身份和单调代数的 `TextClientToken`。`clearTextClient(token)` 只撤销匹配的当前连接；旧代数和其他窗口的 token 不会解除新连接。核心只保存 opaque context 与函数指针，不导入编辑器或系统 shaping 模块，也不复制文档。

客户端提供 `owner: Thread.Id`、`read(context,window,destination)!Snapshot`、`change(context,window,Change)!ChangeResult` 及可选的 `unbound`。所有调用在进程主线程；错误线程在触及窗口记录或客户端前返回 `WrongThread`。客户端和回调借用的存储地址保持稳定，直到解绑通知和已经进入的回调全部返回。共享 Content 上下文仍遵守 Content/on_closed 的更长生命周期。

## 上下文与修改

`Snapshot.range` 是上下文在**已提交文档**中的全局 UTF-16 半开范围，`selection.anchor/caret` 也是全局 UTF-16 单位并保留方向。`bytes` 报告 destination 中初始化的 UTF-8 字节数；`revision` 必须随文档、选择或 preedit 变化单调更新，耗尽必须停止提供上下文。`composition` 表示虚拟 preedit 正在替换的 committed 范围，preedit 字符串本身不进入这份 committed 上下文。

read 把包含完整选择、标记替换范围及附近文本的连续上下文写入调用者缓冲。不能把局部切片长度冒充全局范围，也不能截断 scalar 或 surrogate pair。容量不足返回 `CapacityExceeded`；核心在原生使用前再次核对 UTF-8、range 长度、选择和组合边界。客户端可提供部分文档，原生请求不能借此修改上下文以外的字符。

`Change.select` 设置方向选择，`Change.replace` 以明确 UTF-16 范围替换文本。客户端先验证所有范围与容量，再修改唯一文档，并在返回前显式更新候选位置和所需布局。查询不 shaping、不分配；修改后的 prepare 是应用明确选择的输入阶段成本。正常 draw 不承受这些查询或构造。

`ChangeResult.applied` 才确认原请求；`rejected` 表示宿主消费但未改变已核验状态，
`superseded` 表示原请求被宿主的编辑或许可变化替代。后两项不自动重试或产生错误
诊断，也不回滚宿主自己已提交的编辑。原范围/容量/线程错误保留 error；详见
[编辑前输入门](editor-pre-input.md)。`Event.text_input` 同时携带借用 text 与明确
producer，区分 Win32 字符/IMM result、GTK 文本服务 commit/键值后备和宿主事件，
不从当前组合状态推断来源。

`readTextClient` / `changeTextClient` 固定窗口与回调作用域，拒绝递归查询/修改或回调内替换连接的 `Busy`。回调请求关闭后原生结果失效；原生直接关闭也要等现有回调退栈才解绑。关闭先清客户端入口，再通知解绑，然后 detach Content。失焦先撤销入口和原生组合，再通知旧客户端，最后发送宿主 focus 事件；宿主可在该事件重新绑定。新连接不会被迟到的旧 token 或解绑清理移除。若 set/clear 的原生取消或解绑通知同步触发失焦，事务消费该 pending 状态；set 返回 `FocusLost` 并保持入口为空，不把旧失焦延迟施加给随后连接。正在替换/清除的回调内再次绑定返回 `Busy`，宿主可在外层返回后显式重试。原生取消失败时 set/clear 返回该错误，旧入口已经撤销并通知，不安装新连接，也不恢复已解绑的上下文；下一次显式 bind 可重试。无返回值的失焦清理将取消错误交给诊断 sink。

## Editor 绑定

`ui.editor.TextBinding` 是独立文件中的小桥接，借用同一个 Editor，不拥有第二份文本或撤销栈，不导入 shaping：

```zig
var binding = ui.editor.TextBinding.init(&editor, process_main_thread);
binding.changed = .{ .context = &state, .call = onNativeDocumentChanged };
try binding.bind(window);
// 关闭窗口前，或切换字段时：
try binding.unbind();
```

保持 binding 地址稳定。已有连接需先解绑；不要把同一 Binding 同时放入两个窗口。`changed` 在原生修改后同步调用，宿主通常执行 shaped Adapter.prepare、Window.setTextCaret，再 invalidate。普通键盘/commit/preedit 事件仍通过现有 Editor/Adapter.handleEvent 输入路径接收，不重复处理。失焦自动解绑后，宿主在实际字段重新获焦时 bind。

同一 Editor 同时只有一个原生 Binding owner。旧原生 client 仍实际安装时，另一个 Binding 的 bind 返回 `EditorAlreadyBound`，包括旧窗口已 disable 或等待关闭的情况；原生安装事务中的重入 bind 返回 `Busy`。原生撤销已移除旧 token 后，撤销回调可以同步绑定新 owner；新安装失败不提前发布 owner。旧 `unbound` 总是撤销自身 token 和坐标借用，只有它仍是 Editor 当前 owner 时才清焦点与 preedit，因此旧回调的尾部不会取消新 owner 的预输入。

Binding 使用 TextBuffer 的单调 revision 和 UTF-16 转换，方向选择、明确范围替换、preedit 和 undo 都读取或修改同一个 TextBuffer。替换复用 Editor 的换行/Tab/NUL 检查与容量/历史事务。无效范围、surrogate 中间位置、容量或历史失败不改变文档；成功编辑后的 prepare 失败保留该编辑，返回错误供报告和显式重试，不能用陈旧布局绘制新文本。Binding 自身不分配查询/编辑存储；TextBuffer 与 Editor 的容量在初始化时显式分配。

### 小型 Editor 的已提交坐标

默认 Binding 继续使用窗口 DIP。应用在已成功显示的变换帧后，可显式调用
`binding.setCommittedSpace(try context.committedSpace(id))`，与同一小型 Editor 或
ShapedEditor 的准备/绘制使用相同局部 bounds。它借用现有 SpaceBinding，跟随同一
Context/Window/Region/工作区的稳定 ID；没有第二套变换树、文本或选择。

原生 read/change 在触及正文或调用者输出前检查实际 Window/TextClient 连接和已提交
Space。新成功帧省略 ID 时返回 `SpaceNotFound`；失败帧保留上一成功映射；释放、
重建或 detach 后旧工作区返回 `StaleSpace`，同地址和同 ID 不会复活旧授权。
`clearCommittedSpace()` 撤销已经 opt-in 的坐标借用，此后原生 read/change 和
`setTextCaret` 拒绝，直到显式选择新 Space，或完成 unbind 后重新 bind。它不会静默
改用窗口坐标。未 opt-in 的默认 Binding 调用 clear 没有副作用。
`hasCommittedSpace()` 只报告是否仍持有该借用，不代替其每次使用时的有效性检查。

宿主的 changed/成功 front 回调使用
`binding.setTextCaret(try shaped_adapter.caretRect(local_bounds, scale))`。caret 从同一
已提交映射转为裁剪后的窗口 AABB；候选窗口本身不旋转。该接口不 prepare、不 shape，
不在 draw 中调用。无效/不可逆变换不能成为成功 Space；旧 token 不能安装新绑定。
普通 pointer/wheel 仍由宿主用同一 SpaceToken.mapEvent 显式映射后转发一次。

Binding 和 Context 都须覆盖全部已进入的调用。clear/unbound 先撤借用，再进行后续
清理；回调返回后核验连接与局部坐标代数，不继续读取已撤销的旧 Context。关闭已接受
但 unbound 尚未通知时，`unbind()` 返回 `UnbindPending`，保留 token 与借用，宿主在
外层正常 dispatch 完成通知后才能释放。`Window.isClosed()` 不是提前释放许可。
Changed 是提交后最后的宿主调用；它可以 clear、关闭或请求下一次呈现，正文不会因此
回滚或重复输入。原有 TextBuffer 编辑在已预分配存储中纯提交，不加入新的 Document
或提交守卫。

默认路径只增加固定字段和身份判断；opt-in 解析既有有界几何表，不新建索引或分配。
读写、坐标/caret 提交与正常 draw 均不为此桥分配。独立
`smoke-affine-text-binding` 覆盖真实系统布局与原生上下文、方向 UTF-16 选择和唯一
undo、成功/失败 front、显式撤销/缺失/重建 Space、候选位置和延迟 unbound；Windows
另对照实际 IMM 候选锚点，Linux 验证 GTK surrounding/delete 与 caret 提交调用。
这不是新的视觉验收、TSF 或所有语言引擎认证。

这个 Binding 复用现有连续 TextBuffer 的 UTF-16 转换，读取全局位置仍会扫描文档前缀；有限上下文输出不等于查询成本只随输出长度增长。没有在 native query 中暗中建立索引或 shaping。大文档的持久位置索引与编辑复杂度继续由 T03 实施；自定义 Client 可在自己的显式更新阶段维护索引。

## Windows 与 GTK

Windows 实际处理 `WM_IME_REQUEST` 的 `IMR_DOCUMENTFEED`、`IMR_RECONVERTSTRING` 和 `IMR_CONFIRMRECONVERTSTRING`。使用最多 4096 字节 UTF-8 上下文、4096 单位 UTF-16 栈缓冲；容量不足拒绝，不截断所选文本。RECONVERTSTRING 的长度按 UTF-16 单位，offset 按字节。填充 offer 后缓存窗口客户端代数、revision、实际全局范围和内容指纹；确认时重新查询并核对全部字段、原文、surrogate、composition/target 包含关系，随后同步更新选区，后续原生 commit 替换该范围并进入原有 undo。失焦、重复确认或任何文档版本变化都不会让宿主接受旧 offer 的选择调整。按 IMM 的官方约定，CONFIRM 返回 0 允许 IME 继续采用原始 offer，而不是要求 IME 取消；因此这些校验不保证所有原生语言引擎停止使用旧 offer 启动后续组合。绑定替换会撤销入口并调用 native cancel，但迟到的 IMM 消息没有客户端代数标签，仍需真实语言引擎验证，不能当成 TSF 会话隔离。

Windows 的显式 `Window.cancelTextComposition`、解绑及失焦先撤销旧的本地组合标志、未配对 surrogate 和 reconversion offer，再通知内容撤销旧 preedit，随后调用 IMM。原生标记的活跃组合只通知一次；重复 END 或取消不重复通知已经撤销的组合。取消失败也不恢复旧状态。取消本身不解绑仍有效的客户端，`clearTextClient` 的入口和代数规则保持不变。

Core 的原生解绑取消作用域中，物理客户端入口已经撤销，此时的取消改为生命周期事件 `text_preedit_revoked`。Context 同步清除本地 composing，并在 `on_input` 前消费该事件；唯一的 `TextClient.unbound` 回调继续负责撤销文档中的虚拟组合，不向正在解绑的旧业务 owner 再投递编辑。持有虚拟组合的客户端应在 `unbound` 中清理自己的组合，不能依赖解绑时重新进入业务输入。作用域外的显式取消、以及没有注册 TextClient 的普通编辑器，仍使用 `text_preedit_cancel` 进入原业务输入路径。这个区别由明确的解绑作用域决定，不由 `Busy` 错误或仅仅客户端为空推断。

取消通知可以同步关闭窗口、替换客户端或启动新组合；原生取消前重新检查窗口和客户端身份，避免把旧操作施加到新连接或新组合。IMM 返回后不再清理本地字段，END 也在通知前撤旧状态，因此回调创建的新组合和 decoder 状态不会被旧尾部写入覆盖。实际失焦仍撤销该窗口的输入责任。未被显式取消的活跃 IME 继续优先处理导航键和 Tab，不强行交给控件导航；这些本地规则不为没有代数标签的迟到 IMM 消息建立会话隔离。

GTK3 实际连接 `retrieve-surrounding` 与 `delete-surrounding`。上下文最多 12288 字节，cursor 转成该切片内的 UTF-8 byte offset；删除的 offset/count 按 Unicode scalar 计数，再转换为明确的全局 UTF-16 范围。超出这份有界上下文的请求失败，不从截断上下文推断全文。GTK 同步复制上下文；局部栈缓冲不会逸出。

当前两个原生适配对活跃虚拟组合的文档上下文请求/周围删除明确拒绝，保留组合与 committed 文档。IME 可完成或取消组合后重试；已有 preedit/result 与候选定位事件继续可用。此切片不提供 TSF text store、完整 marked-document 查询、丰富 clause/属性或所有语言引擎认证，也不是完整成熟输入控件或辅助技术文本实现。

## 验证

`zig build smoke-text-client` 在 Windows 使用真实窗口过程发送 IMM 文档请求、确认、失效和 Unicode commit，在 Linux 的真实 GtkIMContext 通过公开 surrounding/delete API 进入原生信号。两端检查 UTF 坐标、候选/prepare 在下一 paint 前更新、撤销、旧代数、容量/边界与关闭资源。主单元测试覆盖 owner 线程、回调重入、原生绕过关闭、解绑次序和无分配查询/编辑。它们没有自动输入真实语言引擎，也不建立候选 UI 的视觉质量结论。

Windows 的 `smoke-ime-cancel` 在不切换的私有 Desktop 上，使用独立 HIMC、真实窗口过程和 Context 事件桥检查显式取消、成功与失败解绑、重绑、旧 token、取消通知重入、新组合、直接原生关闭及失焦。实际 Document/Adapter 组分别验证仍绑定时取消、主动解绑和关闭窗口：虚拟组合被撤销，正文和 undo 不变，生命周期事件不能进入 `on_input`。纯测试锁定 END 通知前撤状态和回调中新 START/surrogate 的保留。这些是消息级生命周期回归，不是通过真实语言引擎自动打字的验证。

原生单位与确认返回值见 [IMR_CONFIRMRECONVERTSTRING](https://learn.microsoft.com/en-us/windows/win32/intl/imr-confirmreconvertstring)、[RECONVERTSTRING](https://learn.microsoft.com/en-us/windows/win32/api/imm/ns-imm-reconvertstring)、[GtkIMContext.set_surrounding](https://docs.gtk.org/gtk3/method.IMContext.set_surrounding.html) 与 [delete-surrounding](https://docs.gtk.org/gtk3/signal.IMContext.delete-surrounding.html)。

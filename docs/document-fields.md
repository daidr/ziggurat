# Document 字段

`ziggurat_document_editor.Field` 将调用者的一个 `Document` 接入普通控件焦点、
原生文本、准备好的系统布局与 UI 命中事务。Field 拥有一个 Adapter；Document、
Engine 和它们的 allocator 由调用者管理，必须活到 Field.close 成功。UI 不导入
DocumentEditor，也不保存第二份正文、选区或撤销栈。

窗口附加 Context 后，显式调用 `context.prepareTextFields(allocator, options)`。
它使用同一 Space workspace 准备坐标元数据和有界注册表，不准备 software/GPU
transform 像素平面。真正的 `Frame.beginTransform` 仍要求显式
`Context.prepareTransforms`。普通字段可直接使用 clip/offset 和 capture 几何。
Windows 已附加的无障碍语义启用时，坐标准备还会创建一个 16472 字节的原生几何
owner，计入 `CoordinateOptions.bytes` 和 `transformStats().metadata_bytes`；它在
paint 外准备，后续升级 transform 不重复分配，释放坐标元数据时同步撤销。

创建 Field 后先在输入或布局阶段 `prepare(bounds, parameters)`，再
`attach(&context, stable_id)`。draw 回调调用 `field.draw(frame, colors, name)`；
draw 只读取已准备内容、发出命令和注册元数据，不绑定文本客户端、不分配或编辑。
Field.draw 使用的 bounds 就是 prepare 的本地矩形。只有成功呈现的帧能发布它的
命中、坐标和 text_box 语义；失败帧保留旧前台。
当前待发布命中中的注册 Field 使用自己的无障碍操作路由，不要求宿主另装旧式
handler；仅有旧前台、相同 ID 或已撤销的注册不能取得该路由。普通可写 text_box
仍须提供宿主 handler。

`Input.focused` 是唯一控件焦点。pointer、Tab/Shift+Tab、显式 `field.focus()` 和
原生可访问操作都验证当前已发布的注册身份。兄弟按钮交接会先撤销字段自己的
TextClient；无关的宿主 TextClient 不会被字段强占。预处理之前固定接受者，外层
事件不能改用回调中新增的注册。关闭会先撤销注册，旧前台只保留拒绝旧输入所需
的 serial，不保留业务回调指针。

`field.blur()` 只撤销与该注册精确匹配的焦点和 TextClient；对未聚焦字段调用
不会撤销兄弟字段。真实原生 press 的身份不会因绑定字段而重发或放宽。若激活
顶层窗口本身改变了原输入身份，旧 press 按原规则拒绝；宿主应在已经取得原生
焦点的窗口内派送需要该身份的点击。

单行字段拒绝程序或原生替换中的换行，粘贴将 CR/LF、CRLF 和 Unicode 行分隔符
归一为空格。Enter 调用显式 submit；多行字段插入 LF，`accept_tab` 控制 Tab
是否插入。readonly 允许选区、移动和复制，拒绝文本、preedit、删除、剪切、粘贴、
撤销/重做和 SetValue；disabled 不接收编辑或焦点。`setPolicy` 立即撤权，新的
enabled/readonly 语义在下一次成功前台发布。

兼容 `edit_key` 在 Field 边界归一后只经过一次键盘策略；不另发第二次 typed
输入。原生替换先校验 UTF-16 端点与顺序，再计算容量；无效范围拒绝且不编辑。
字体 family/locale 复用 Adapter 已拥有的有界拷贝，调用者在 prepare 返回后
可以释放输入字体字符串；没有为 Field 再增加字体 heap。

`scrollBy` 改变视口后准备同一 Adapter 的布局；已绑定时通过同一已提交 Space
同步原生 caret，然后请求重绘。展示或 caret 同步失败不撤回已经改变的视口，
不能将错误当作重复施加滚动量的许可。

Field 的 `setValue`、`select`、`undo`、`redo` 返回 `TextFieldResult`。
`text_committed` 与 `presentation_error` 可同时成立：展示失败不撤回已提交的
Document 改动，不允许重放。changed 使用 Document 的 committed-text version
去重，在调用业务回调前先记录版本；单独的选区和组合预览不会通知 changed。

剪贴板显式注入 `ui.editor.Clipboard` 的同步有界 read/write 能力；Field 不建立
阻塞的系统剪贴板等待。Windows 宿主可使用现有 system.clipboard，Linux 该
system 能力目前不支持，应用应明确提供自己的能力。word/logical-row 多击需要
FieldOptions.words、准备字体的 word_ranges 和 Window.native_pointer_clicks
都显式启用；默认不创建词索引、不复制 Core 的原始多击历史。

`value_bytes` 限定两个 scratch 中每个缓冲的大小及当前可展示/导出的字段值。
`storage_bytes` 限制 Field 壳和两个缓冲；Adapter、Document、Engine 各自预算
另外计算。当前文档或其历史超过展示上限时，显式 prepare/展示返回错误，不截断
业务正文。UI 注册表有 fields/bytes 上限；坐标元数据、注册表、Field/Adapter 与
真正的像素平面分别计费。默认无字段路径只有一个可空 Input 指针，不分配这些
owner；精确结构和原生分配结果由对应验证报告给出。

Field 地址从 attach 到 close 保持稳定，Context 也须覆盖 token 的每次使用。
close 返回 ResourceInUse 时注册已经撤销，但仍有同步回调借用，调用者必须保留
Field 并在回调退出后重试，不能立即释放其存储或 allocator。旧 close 重试不会
撤销已重用槽的新 serial。Window 关闭与 Context detach 不替代 Field.close；
App 仍须覆盖最后一次 Window/token 使用。

整个 close 清理阶段保持独立关闭门；最后的调用者 allocator.free/destroy
重入 close 也返回 ResourceInUse，不会再次访问已经释放的 Adapter。关闭失败
时仍保留可重试的壳，已成功完成的撤销步骤不会重新发布。

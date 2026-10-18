# 编辑前输入门

`ziggurat_document_editor.Adapter.setPreInputHook(?PreInputHook)` 在唯一 Adapter
执行默认输入动作前同步调用宿主。默认 null 不分配或复制正文，不创建任务、线程或
延续；配置 hook 同样不分配。Document 继续唯一拥有正文、方向选择、组合和 undo。

```zig
try adapter.setPreInputHook(.{ .context = &state, .call = beforeInput });
// Context.on_input 仍将事件交给 adapter.handleEvent 一次。
// 先成功清除，再释放 state；或让 state 覆盖 Adapter.close 成功返回。
try adapter.setPreInputHook(null);
```

`PreInput` 分为 `key: KeyInput`、`text: TextInput`、`preedit: TextPreedit` 和
`native_change: text.Change`。text/preedit/replacement 中的字符串只借用到本次
callback 返回，不得保存或安排稍后执行。原生 change 的坐标仍是提交正文的全局
UTF-16 单位，不将它伪装为 UTF-8 或临时显示偏移。

Core 的 `Event.text_input` 现在包含 `TextInput{text,producer}`。producer 必须显式
给出，描述实际交付路径：

| producer | 来源 |
| --- | --- |
| win32_character | Win32 WM_CHAR / WM_UNICHAR，含原有 surrogate 解码 |
| imm_result | IMM 的 GCS_RESULTSTR |
| gtk_text_service_commit | GtkIMContext commit 信号 |
| gtk_keyval_fallback | GTK 文本服务未处理后，GDK keyval 的 Unicode 后备 |
| application | 宿主显式构造的事件 |

这些标签不是输入可信度或物理键盘证明。GTK commit 可以承载普通键盘翻译，不能
全部称为语言输入法结果；Win32 字符消息也可能被程序发送。组合状态仍参与唯一
Document 的默认替换操作，但不被用来猜测 producer。

Hook 返回 `pass` 或 `consume`，不通过 error 表达否决。`pass` 仅在 Document 完整
revision、TextClient token、Space、已发布 view/projection stamp 和窗口输入许可
均未变化时执行默认动作。回调已经编辑、选择、交接绑定或关闭时，即使返回 pass
也消费旧输入。Hook 可通过原 Adapter 的普通编辑 API 更新业务；不得重入输入、
准备布局或替换/清除正在执行的 hook。prepare、成对 prepare 和 planner 共用候选
准备边界，都在 hook-running 时返回 Busy。Adapter 的 client pin 拒绝回调内 close，
Window/App callback scope 则覆盖关闭安全点。Hook context 始终借用到显式清除或
Adapter.close 成功，Window.isClosed 不提供提前释放它的许可。

只有完整 `key_input` / `handleKey` 调用 key hook。Context 在同一物理键的 typed pass
后提供的旧 `edit_key` / `key` 兼容映射不再次调用 hook。宿主可用自己的 chord 状态
消费首键与后续键；原生仍用原来的 consumed 返回值阻止字符翻译。这里不增加另一份
快捷键或 chord 状态。生命周期取消、失焦撤销、preedit_revoked 与 unbound 必须完成
原有清理，不能由 hook 否决，也不会进入业务 hook。

Event 入口被消费后返回 true。Hook 自己已完成编辑后，自动呈现失败只保存在
`status().last_layout_error/layout_required`，宿主显式重试 prepare，不能重发输入。
这也覆盖旧资源最后 free 回调再次改变 Document 的情况。没有消费的默认输入继续
沿用原来的提交/呈现失败合同。

`text.Client.change` 和 `Window.changeTextClient` 返回 `text.ChangeResult`：

| 结果 | 原生责任 |
| --- | --- |
| applied | 原请求已成功处理，包括同值选择；可以向原生确认 |
| rejected | 宿主消费，原请求未执行且被核验的状态未变 |
| superseded | 原请求未执行；hook 已改变正文/选择/许可或关闭，自己的编辑不回滚 |

IMM reconversion 确认和 GTK surrounding-delete 只有 applied 才返回成功；另两项
拒绝原请求，不自动重试，不作为错误诊断。客户端返回 rejected 后窗口或 token
已经失效时，Core 将其提升为 superseded。范围、容量、线程和真实呈现错误仍保留
error 通道；原有 applied 结束时的 token/许可复核也保持有效。Hook 引起的 native
正文变化仍通过原 observer 通知，以便宿主重新准备成对文档；observer 回来后不再
读取可能已经关闭的 Adapter。

本切片只覆盖 DocumentEditor 的事件入口、handleKey 和直接原生 TextClient change。
更上层 Presenter/snippet 已消费的输入、旧 scalar/ShapedEditor 的宿主回调仍遵守其
既有路由，不自动转送到这个 hook；它们本次只迁移明确的 text payload。

`smoke-editor-pre-input` 的夹具核验真实字符/GTK commit producer、typed/legacy 单次
门、显式 native 否决、callback 编辑/关闭/重入、三类 prepare 拒绝、呈现失败保留编辑
与同一 undo。原生语言引擎、TSF 与完整快捷键 scope 仍是独立验收事项。

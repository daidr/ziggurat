# 窗口文本输入模式

`WindowOptions.text_input_mode` 与 `Window.setTextInputMode(mode)` 为每个框架窗口
显式选择原生输入服务。默认 `.system`；`.keyboard_compose` 保留当前键盘布局的
普通字符和本地 compose，绕过该窗口的系统语言输入上下文。它不改变进程、线程、
子 WebView 或操作系统当前语言配置。文档、选择、preedit 与 undo 仍由原有
TextClient/Document 拥有，不创建第二份编辑状态。

setter 返回独立的 `TextInputModeResult.applied/superseded`，不是文档修改结果。
同值调用无副作用；正在切换时再次调用返回 `Busy`。`textInputMode()` 返回已经
成功选择的窗口策略，不报告用户 IME 的 open 状态。`textInputStamp()` 是无分配的
模式和单调 epoch；只有真实成功切换才前进。耗尽时拒绝新切换，不复用旧 authority。
所有接口在 App owner 主线程调用。

切换先固定窗口回调生命周期、撤销旧本地组合，再取消旧原生组合。宿主收到取消时
可以关闭、替换 TextClient 或开始新组合；这些行为使旧切换返回 `superseded`，不会
覆盖新 authority。取消已经发生时不会回滚或重放文本。真正的原生失败保留 error，
getter 仍报告实际已成功选择的策略；没有自动重试或延迟恢复任务。

Windows 使用 HWND 的 `ImmAssociateContextEx` 解除 IMM 关联，恢复时使用
`IACE_DEFAULT`。恢复的是该窗口默认 context，不承诺恢复宿主私下安装的任意自定义
HIMC；框架不创建、销毁或修改共享默认 HIMC 的内容。普通 `WM_CHAR/WM_UNICHAR`
继续译码；禁用时旧 IMM composition/result/reconversion 消息没有业务副作用。
这不是 TSF text store，也不宣称认证了所有现代语言引擎或触控输入。尤其官方说明
IME profile change 不一定发送 `WM_INPUTLANGCHANGE`，不能把该消息测试解释为
全部 TSF profile 切换的保证。

GTK `.system` 使用 `GtkIMMulticontext`，`.keyboard_compose` 使用
`GtkIMContextSimple`。Simple 仍支持 compose 表、用户 Compose 文件、preedit 和
Ctrl+Shift+u Unicode 输入，因此模式不承诺“无 preedit”。每次真实切换创建一个
新的目标 context；目标接收窗口、候选位置并通过 authority 最后复核后，先发布
新 context/epoch，再撤旧六信号入口并 focus-out/reset/detach，最后恢复新 focus。
提交之后的回调属于新模式，释放旧对象不会把已生效结果变成重试错误。退休对象即使仍被 SDK
引用，后来信号也不能在模式来回切换后复活。释放入口只操作原生对象，不访问已
关闭的 Zig 内容。没有闲置备用 context。默认路径只创建原来的一份系统 context。
GTK/GObject 自己的分配遵循其原生失败机制，不承诺 caller allocator 可恢复 OOM。

原生 key filter 和 UI typed/legacy 路由在回调后核对模式 epoch，改变模式会停止该
物理事件后续的旧 fallback。DocumentEditor pre-input 和原生提交作用域也保存此
stamp；hook 改变模式后原输入返回 superseded，不把同一输入提交到新服务。正常
框架路径只增加固定记录字段、身份比较和栈上 stamp；不分配、不扫描文档，也没有 timer、
轮询、后台任务或 paint 成本。

纯测试覆盖同值/默认、分配失败门、原生失败、重入、替换连接、新组合、关闭和 epoch
耗尽。隐藏原生夹具验证真实 Windows IMM 关联、字符/代理对/TranslateMessage、旧
IMM 消息，以及 GTK 实际 context 类、compose/Unicode、退休强引用信号和回调交接。
Windows 还核对整条消息的窗口/输入许可/关联代数/模式/本地会话/producer 消息代数 authority：替换字符回调后不
续写旧 surrogate 或发送旧 BMP，result 回调后不继续查询旧 HIMC，IMR read 回调后
不恢复旧 reconversion offer。同一 authority 下 result 与新 preedit 仍可共享消息，
普通正文提交的文档 revision 变化不会撤销它。回调结束时的输入许可用于复核；不
承诺记录回调内 disable 后又 enable 的完整历史。同步重入的新字符消息拥有自己的
代数，外层旧尾部不会覆盖其 decoder；本次取消自身的 END 清理不冒充新输入。
这些是消息和上下文集成检查，不是视觉验收或所有语言引擎认证。

原生合同来源：

- [IMM 关联](https://learn.microsoft.com/en-us/windows/win32/api/imm/nf-imm-immassociatecontextex)
- [输入语言消息及 TSF profile 限制](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-inputlangchange)
- [GTK Simple compose/Unicode](https://docs.gtk.org/gtk3/class.IMContextSimple.html)
- [GTK reset](https://docs.gtk.org/gtk3/method.IMContext.reset.html)

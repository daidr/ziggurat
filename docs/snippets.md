# 有界 snippet 会话

`ziggurat_code_editor.snippets` 提供独立拥有的 `Template` 和更新阶段使用的 `Session`。Document 仍是正文、选区、预编辑与 undo/redo 的唯一所有者；会话只保存有界的派生字节范围和一个 Template 借用。没有第二份可编辑正文、后台线程、隐式调度、绘制时解析或布局。

```zig
const snippet = code.snippets;
const template = try snippet.Template.parse(allocator,
    "fn ${1:name}($1) { ${2|first,second|};$0 }", .{});
defer template.close() catch unreachable;
const session = try snippet.Session.create(allocator, adapter, .{});
defer session.close() catch unreachable;

const revision = try document.version();
const outcome = try session.start(template, revision,
    &.{(try document.selection()).range()}, 0);
// 更新后显式 adapter.prepare、window.invalidate；draw 复用 Adapter.draw。
_ = outcome;
```

除直接 Session 调用外，Broker/Presenter 已提供显式 snippet 补全链：Completion.insertion 默认 plain；显式 snippet tag 指向 edits 内唯一模板文本，其余 edits 为字面附加编辑。宿主先调用 Presenter.enableSnippets 才启用接受与后续会话，普通补全不自动解释美元符。Presenter 在接受阶段解析拥有的 Template 并持有到会话结束，不在 draw 解析；Broker 可在接受后释放原结果。语言协议适配仍为独立范围，完整接口/成本/committed outcome 见[代码服务](code-editor.md#显式-snippet-补全)。

## 语法与索引

支持 `$n`、`${n}`、`${n:placeholder}`、`${n|first,second|}`，编号为0..65535。非零编号按数字顺序导航，编号0是最后位置；没有显式0时在结果末端补一个。显式0最多一次。第一次定义的 placeholder/choice 为其所有引用提供同一个初值，允许引用出现在定义之前。重复定义明确 `DuplicateDefinition`，不猜测哪个默认值优先。

普通文本与 placeholder 用反斜杠转义反斜杠、美元符和右花括号；choice 另可转义逗号和竖线。choice 可包含空项。其他转义报 `InvalidEscape`。输入必须是无 NUL 的 UTF-8，解析后保存独立拥有的展开文本、默认值、choice 及出现位置，源字符串可立即释放。

placeholder 默认值可嵌套，例如 `${1:a${2:b}} $1 $2` 展开为 `ab ab b`。父项镜像包含完整的子范围结构；每个同编号子项仍是相同值的镜像。定义依赖自环或跨编号循环返回 `CyclicPlaceholder`；语法嵌套和实际镜像展开深度分别受同一 depth 上限约束。嵌套的 `$0` 明确 `UnsupportedNestedFinalStop`，choice 项仍是字面文本，不接受嵌套表达式。此能力不表示在活动会话中插入第二个 snippet session。

支持下面限定的 regex/格式变换；不支持的构造明确拒绝，不退化成字面替换或通用脚本。变量需要显式 resolver；普通 `Template.parse` 不读取任何宿主变量。

所有范围为 UTF-8 字节半开区间，端点由 Document 验证为 Unicode scalar 边界。它们不表示 UTF-16、字素、视觉 caret 或 glyph 索引。`selectActive` 的相对 anchor/caret 也使用字节；普通 Editor 的字素导航继续由原 Adapter 负责。

## 文本和选区事务

`start(template, expected_revision, ranges, primary)` 在每个原文范围独立插入同一展开结果。ranges 必须排序且无重叠或同点插入歧义；primary 指定主要插入实例。最小非零 tabstop 的全部镜像成为 Document 的真实多选区，定义出现位置在主要实例中保持 primary。没有非零 tabstop 时提交后直接结束。

`edit(text)` 对当前活动镜像的同一个相对选区原子替换，提交后留下相同相对 caret；继续输入会插入在该 caret 后。变换后镜像长度可以不同：当前每项都被完整选择时，输入替换各自的完整范围；部分选区仍须具有相同相对 anchor/caret。`replaceActive(text)` 显式替换各自整项并选中新的完整值；`choose(index)` 使用活动 tabstop 的一个 choice，语义相同。`selectActive(selection)` 显式设置全部镜像的相同相对选区。普通输入每次产生一条正文 undo，选区操作不增加正文 undo；Tab 若实际执行变换则按下面的合同提交一次正文 undo。

`next(false)` / `next(true)` 按编号向后/向前选择仍有存活出现位置的整个 placeholder，跳过已撤去的子项；在首个存活项向前保持该项，到0后结束会话。`cancel()` 只撤派生范围和 Template 借用，不回滚正文、不擅自折叠 Document 多选区。取消后仍可再次 start。

编辑子项时，所有存活的同编号镜像同时变更，其祖先范围随长度变化，正文仍只改一次。整项替换父项会撤去该父项中所有子范围；部分编辑只撤去被触及的子树，完全不相交的子项继续有效。某个编号在父项以外仍有出现位置时，那些位置保持镜像并继续参与 Tab。父范围、子范围、存活标记只在正文事务成功后一起换 bank。

所有范围半开。父项中的空插入在子范围起点之前、终点之后；若空子项和插入点重合，按不可变展开顺序决定左右偏向。与父项编辑相交的子项脱离链接，不把这一次编辑偷偷传播给另一个独立父项。对子项自身编辑则更新所有同编号位置。同编号出现位置不能互相包含，因为模板依赖循环已被拒绝。

多个同编号的空 placeholder 若位于同一点，或一次编辑会把镜像的最终选区合并到同一点，返回 `AmbiguousTabstops`，保持事务前正文与会话。不会让 Document 的选区规范化默默丢掉一个镜像。正文/会话容量、Unicode 端点和最终选区全部在提交前校验。

Document 新增 `replaceManyWithSelections(expected_revision, edits, final_selections, primary)`：edits 使用原文坐标，final_selections 使用候选正文坐标。候选树、全部最终选区与规范化版本成功后才一次 publish；不以 `replaceMany` 再 `setSelections` 拼成两个事务。一次 undo 恢复原文和原选区，redo 恢复插入文本与本次最终选区。Adapter 的同名入口使用同一事务维护段落索引/折叠，不复制正文历史。`Session.startCompletion(template,expected_revision,edits,snippet_index)` 将一个主模板和所有前后字面编辑提交为同一事务；前置附加编辑的长度变化进入最终 tabstop 字节位置，编辑数量受 insertions 和预留 edits 容量限制。

Document 的 `beginCommitGuard` 提供 owner-thread、无分配的瞬时发布门禁。Adapter 只在每次真正调用 Document mutator 的范围安装它；校验发生于候选树/最终选区准备后，紧邻无外部调用的状态发布。旧树、历史与选区的 foreign free 排在发布之后。scope 是线性借用，必须结束；validate 只读、不得分配、变更 Document、结束 scope 或释放 context。原生输入 scope 不在两次 mutator 之间保留 Document guard，因此不增加隐藏排队或第二份授权状态。

Session 将前置 OOM、容量、陈旧版本、组合或范围错误返回为 error，原会话与本次文档操作保持不变。宿主在 foreign allocator 中自行进行的独立编辑不属于回滚对象。特别是 Adapter 已提交、释放旧派生资源时，分配器可再修改 Document：此时返回 `Outcome{committed=true, committed_revision=本次提交版本, stale_after_commit=true, active=false}`，同时 revision 报告实际观测版本。调用者不得重发该次文本动作；独立编辑和 snippet 在原 Document 中仍各有一条 undo。

提交版本由校验过的 expected revision 加1确定，耗尽在事务前拒绝。普通正常返回包含 committed/active/revision，供宿主安排下一次布局；Session 不自动刷新业务 view 或重新执行输入。

## 输入、陈旧与 IME

宿主可先调用 `session.handleEvent(window,event)`，只把返回 false 的同一事件交给现有 Adapter/Presenter 一次。该帮助函数处理 text_input、Tab/ShiftTab、Escape；通过 `Adapter.beginNativeInput(window)` 固定 Window callback scope、Adapter 寿命和原有 text-client/committed-Space 授权。Window 必须是该 Adapter 已绑定的窗口；嵌套 scope 保留最初授权，不以较新的绑定替换。关闭、退出或 Space 失效会在实际 Document 发布前再次拒绝。命中/焦点/空间变换和布局由既有内容层负责，Session 不自行路由坐标。普通程序化 start/edit 不要求 Window，也不隐式开启原生输入 scope。

直接程序化修改选区、undo/redo、外部文本或其他完整 revision 变化会使旧会话失效。直接 `edit/choose/next/selectActive` 返回 `StaleRevision`，不猜测文本 delta。事件入口发现该情况时显式结束会话，返回 false，让普通编辑继续一次；不会吞掉下一个输入。其他导航/删除键仍走普通 Adapter，若其改变 revision，下一次事件按这个规则结束 snippet；本片没有重新实现一套字素删除/导航算法。

预编辑、失焦和取消输入先结束会话，随后由正常原生客户端处理。已经存在 composition 时 start/直接修改返回 `CompositionActive`。不把虚拟预编辑当提交正文同步镜像，不接管系统候选位置或复制 IME 状态。

## 显式变量准备

```zig
fn resolve(context: *anyopaque, name: []const u8,
    output: *code.snippets.ValueWriter) !code.snippets.Resolution {
    _ = context;
    if (std.mem.eql(u8, name, "NAME")) {
        try output.writeAll("猫");
        return .value;
    }
    return .unsupported;
}
const template = try code.snippets.Template.parseResolved(allocator,
    "${1:${NAME:default} ${2:child}} $1 $2", .{},
    .{ .resolver = .{ .context = &host, .resolve = resolve } });
```

支持 `$NAME`、`${NAME}`、`${NAME:默认分支}`，名字为 ASCII 字母或下划线开头，随后可有数字。resolver 在每次准备中对每个实际需要的不同名字最多调用一次。`.value` 把 writer 已写入内容作为字面 UTF-8；它即使含 `$1` 也不再解析。空 `.value` 会抑制默认分支。`.unset` 使用默认分支，缺少默认分支时为空；分支内可以包含 placeholder 或另一变量。`.unsupported` 明确 `UnsupportedVariable`，不自动猜值或合成新编号。未知变量自动变 placeholder、每插入 cursor 独立变量环境仍不在本片范围。`${NAME/regex/format/flags}` 在准备时对原始变量快照求值；unset 输入为空，同名变量的原值仍只解析一次，不把一次变换的输出写回变量缓存。

解析先验证全部语法；随后只登记被选中变量分支内的 placeholder 定义。值覆盖的默认分支不产生活动 tabstop，但其中不支持的变换或嵌套 final stop 仍因语法边界而拒绝。resolved Template 是一次宿主上下文快照；程序化多范围 start 重复使用同一快照。框架不读取环境变量、时钟、随机数、剪贴板或文件。

`ValueWriter.writeAll` 直接复制到候选的有界连续存储，不分配；writer、name 和它的存储只借用至回调退栈，不得保存。resolver 的 context 和 cancellation 指针须覆盖整个调用及候选清理。输出不借用宿主字符串，原 resolver/source 随后可释放。宿主自定义 callback 的执行时间不能由 parser work 计数抢占；该回调必须同步、有限且不阻塞，不在其中等待 UI 或启动嵌套事件循环。

`ParseOptions.cancellation` 是可选原子标志，宿主调用 `request()`。解析/展开、writer、resolver 返回以及最后一次 foreign 候选 free 后均检查，取消不会发布半成品 Template。取消只约束本次显式准备，不撤销已经开始或提交的 Document 事务；活动会话用 `Session.cancel()` 明确结束。没有隐藏 worker 或重试。

Presenter 策略通过 `enableSnippets(.{ .expansion = .{ .resolver = ..., .cancellation = ... } })` 显式配置。这些可选指针借用至 Presenter.close；只在接受 snippet 时调用，prepare/draw 不调用 resolver。接受全程保持 Broker 借用和原生输入授权，准备期 Session 额外 Busy；callback 或 allocator 独立改文档、关闭窗口、撤输入授权或退出时，旧结果不能借此越过最终 Document 发布门。

## 有界 regex 与格式变换

```zig
const template = try snippet.Template.parse(allocator,
    "${1:name} ${1/(.*)/${1:/upcase}/} ${2:next}$0", .{});
const session = try snippet.Session.create(allocator, adapter,
    .{ .transforms = .{} });
// Presenter 策略：enableSnippets(.{ .session = .{ .transforms = .{} } })。
```

`${n/regex/format/flags}` 是该出现位置自己的变换，不修改同编号其他位置的格式。初次插入仍使用原始默认值；只有实际离开活动 tabstop 的 Tab/ShiftTab 才读取每个变换位置的当前 Document 文本。退到首项而没有离开不运行变换，Escape/取消/IME 也不运行。重访后再次离开会对该位置当时的值重新求值，因此非幂等变换会再次改变它。

变换源编号须为没有子 tabstop 的 leaf，可以位于嵌套父项内；完整展开森林在 Template 发布前校验，父项源返回 `UnsupportedTransformSource`，编号0变换返回 `UnsupportedFinalTransform`。所有位置的输出、总结果容量、范围平移、祖先长度和下一组选区均在提交前准备；一个离开动作通过原 `replaceManyWithSelections` 产生至多一次正文事务/undo。各自值不变时只选择下一项，不制造正文 undo。失败不改变当前 active id、正文、选区或已提交范围；所有成功/陈旧后提交结果继续用 `Outcome`，不得重发已提交动作。

正则接受串联、按顺序选择的 `|`、捕获组、`(?:...)`、`.`、字符类/范围/反选、`\d\w\s` 与大写反选、`^ $ \b \B`、贪婪/惰性 `* + ? {m,n}`，及 `g i m s u`。支持常用控制字符、十六进制和 Unicode escape。`\w`/word boundary 使用 ASCII 字母、数字、下划线；`.` 的换行集合为 LF/CR/U+2028/U+2029，`\s` 使用固定的 ECMAScript WhiteSpace/LineTerminator 集合，不受 locale 影响。

`u` 按 Unicode scalar 消耗，未设置时按 UTF-16 code unit；capture/正则内部偏移也是 UTF-16，Document 最终范围仍为 UTF-8 字节。全局空匹配按对应单位推进。非 `u` 可以拆开 surrogate pair，但最终结果必须能编码为合法 UTF-8；无法重新配对返回 `UnsupportedSurrogateResult`，不输出 WTF-8。`i` 的模式字面/范围和全部输入限定 ASCII，非 ASCII 明确 `UnsupportedRegexCase`，不假装实现 Unicode case folding。

不支持 backreference、lookaround、named capture、Unicode property/set、未知 flag；返回明确错误。会重复执行的 nullable atom 一律 `UnsupportedNullableRepeat`（如 `(a?)*`、`(a*)+`、`(^)?`），不是以任意迭代次数截断。编译器验证 epsilon 子图为 DAG；有界重复展开也受指令/工作预算限制。此范围不表示完整 JavaScript RegExp 兼容。

format 接受 `$n`/`${n}`（0为整个匹配）、`${n:/upcase}`、`downcase`、`capitalize`、`${n:+if}`、`${n:?if:else}`、`${n:-else}`、`${n:else}`。条件按 capture 是否非空选择；未匹配与不存在的 capture 作为空。capitalize 只大写首 ASCII 单元而保持后续原样。所有 case 操作的 capture 必须全为 ASCII，否则 `UnsupportedCaseMapping`。条件分支为字面文本，不递归解释 capture/format；嵌套表达式、其他 case 方法明确拒绝。格式字面可转义 `\\`、`\/`、`\$`、`\}`、`\:`；裸 `$` 须跟数字或花括号数值引用。

有匹配时按 regex flag 替换，其他文本保留；完全无匹配时保持原输入。唯一例外是 format 至少有一个**非空 else 分支**：此时以空 captures 展开整个 format 一次；`${1:-}`、`${1:?yes:}` 不触发该例外。

正则执行没有回溯搜索、脚本环境、隐藏线程或临时堆分配。显式 Runtime 一次预留 `ceil(P/8) × (input_bytes+1)` 可达位表、UTF-16 输入/capture 和候选输出；一次 `g` 操作只建一次表，按有序分支重建 captures。表计算为 O(N×(P+R)) 上界，N为实际 UTF-16 长度，P为指令数，R为整个程序字符类项数；重建、capture 清除、字符类扫描、转换、格式/比较/复制及会话范围更新另逐项扣 `work`，不把预算单位冒称 CPU 时间。

`Session.Limits.transforms` 默认 null，不创建 regex Runtime 或结果缓冲；含 placeholder 变换的 start 明确 `TransformsRequired`。opt-in 默认128指令、16 captures、输入16KiB、单结果16KiB、总结果64KiB，输入 UTF-8 scratch、位表、UTF-16 输出和结果缓冲全额加入原 `Session.bytes`（默认仍512KiB）。配置更大时必须显式提高总额度，否则 create 在分配前失败，不悄悄扩大预算。相同大小的新 immutable 模板仍由 Template 独立持有，Session 不增加第二正文。

Parser 默认最多128个 compiled transforms（硬1024），每个 regex 默认4096 source bytes/128指令/16 captures/1024字符类项，format 默认4096 source bytes/256 parts；整个 Template 的旧新容量、编译临时存储和最终程序都经过原 parser bytes/work 总账户。变量变换仅在实际准备时按 `ParseOptions.transform_runtime` 显式分配一个可复用临时 Runtime 与结果缓冲，并在发布前释放，不带进 draw。

`ParseOptions.cancellation` 贯穿 regex/format 编译、DAG、变量运行和最后 foreign scratch free 后的发布复查；Session opt-in 的 `transforms.cancellation` 在表构造、trace/格式/复制时检查。指针须覆盖对应准备/Session。Session flag 只约束移交 Adapter 前的候选计算；移交后不抢占原 Document 事务，也不另装第二个发布 guard，Window/token/Space 仍由原生输入 guard 校验。取消不撤已提交 Doc；外部分配器和 resolver 自己的执行时间不受此工作计数抢占。

## 所有权、重入和预算

Template、Session 都是稳定 owning opaque 指针，全部方法检查创建线程。复制指针仅为借用；关闭后不能继续使用。Template 的 `borrow()` 是显式线性 pin，必须恰好 end 一次；Session 从任何事务分配前到最后一次使用保持自己的独立 pin，活动期间 Template.close 返回 `ClientsAlive`。`Template.view()` 只是调用者管理的只读借用，不跨 close 保存。

Session 保留 Adapter client，Adapter 又保持 Document 寿命；Session 存在时 Adapter.close 返回 `ClientsAlive`。allocator context 必须覆盖最终 close。会话业务入口的 busy 门覆盖所有 Document/Adapter 分配与释放；重入 close/cancel/edit/status 返回 Busy。close 先撤入口和 Template 借用，再释放存储，最后释放 Adapter 引用。绘制资源仍按原 Frame Lease 释放，Session 不拥有字体、Prepared 或 Window native 句柄。Presenter 的 Adapter client 穿过最后一次自身 shell foreign free，最终回调仍不能关闭 Adapter；其后才释放。Presenter 自己保留 Session client 到关闭，以防候选 Template 的 foreign cleanup 销毁它；外部 `Session.close` 返回 `ClientsAlive`。`retainClient/releaseClient` 是同线程显式借用，必须配对。

`Session.beginPreparation()` 返回线性 `Preparation` scope，持 Busy 至 `end()`；同一 scope 的 end 幂等，禁止复制或在结束前释放 Session。这用于显式 resolver/候选析构阶段，不能与活动会话重叠。它不建立第二个正文事务，也不保持 Document guard。Presenter 在此 scope 退出后立即走既有 startCompletion。

Parser 默认 source64KiB、展开结果1MiB、512个展开出现位置、128个 stop、256个 choice、4096个语法节点、depth16、128个不同变量、变量输出总共64KiB，拥有与候选同时存活字节4MiB、work4Mi。对应硬上限为1MiB/16MiB/4096/1024/4096/65536/depth64/1024/16MiB/64MiB/work128Mi。变量缓冲只在实际解析变量时显式分配一次，按配置的 variable_bytes 全额计入实际峰值；无变量模板不分配它。

同一套 parser 处理平面与嵌套语法，不维护两套默认值或镜像语义。准备的临时 AST、独立 source、解析值、变量输出、展开结果/范围及 ArrayList 增长时旧新容量全部计入同一 bytes 峰值；最后只保留独立模板数据。展开按实际复制数量检查 output_bytes、occurrences/work，指数镜像不能绕过总量限制。work 包括源验证、扫描/查找、展开/输出复制、变量验证、默认值快照及排序保守计费；宿主 callback 和 allocator 本身的内部耗时不冒称受此计数限制。stats 分列最终 owned、实际分配 peak 和 preparation work。

Session create 一次预留双范围 bank、编辑/选择/索引 scratch，默认512个出现位置、64个插入实例、512KiB metadata、每次文本1MiB。硬上限4096/256/16MiB/16MiB；范围预算是全部实例总和。work 默认1Mi、硬上限32Mi，预扣每次更新的镜像数×全部出现位置，并逐步扣祖先链接访问；metadata 重定位最坏 O(镜像数×全部出现位置×depth)。范围 bank 保留被撤子项的固定槽位，不随历史编辑增长；新 start 重用预留空间。正常会话运算不从自己的 allocator 分配，实际 Document/Adapter 候选成本受各自原有预算限制。它们属于显式更新工作，不在 draw 中调用。

## 验证边界

`test-snippets` 以同一个会话实现的 Document 目标检验语法、前向/嵌套镜像、父子部分与整项替换、空范围边界偏向、choice、Unicode、多光标、导航/完成、每次编辑唯一 undo、stale/composition、工作量拒绝和完整分配故障。resolver 回归覆盖重复名字只解析一次、literal 输出、unset/empty/unsupported、变量/节点/深度/指数展开预算、resolver 中取消与最后候选 free 中取消。Document 纯测另锁候选最终选区、UTF边界、OOM 与 undo/redo。

变换回归覆盖顺序/贪婪/惰性、迭代 capture 清除、UTF16/u 与全局零宽推进、无匹配非空 else、输出孤立 surrogate、ASCII 限制、极端重复/nullable 拒绝、单表与病理 alternation 工作上界、编译/Runtime/Template/Session 全分配故障、总结果/取消失败不发布，以及多 cursor/嵌套 leaf 的祖先范围和不同长度镜像全选。开发用 `bun tests/snippet_regex_oracle.ts <regex-output.zig> <transform-output.zig>` 产生独立 Zig fixture，以原生 `RegExp` indices/replace 验证3984组匹配/capture和8032组替换结果；Bun不进入库运行依赖。

`smoke-snippets` 在 Windows 独立且不切换的 desktop child、Linux 隔离 Xvfb 的原生窗口中接 UI Context、Adapter、系统文本布局和真实 Tab。Windows 文本通过 WM_CHAR，Linux通过同一文本事件入口；不宣称已测真实 IME 引擎。夹具覆盖原生输入、镜像/choice、多项文本历史、Adapter候选OOM、陈旧/预编辑优先级、foreign提交前/提交后重入、Document候选分配回调中关闭窗口且拒绝原提交、关闭和全部原生文本引用归零；变换 Tab 也单独覆盖这些发布边界。绘制仅回放预备布局，Frame pin期间重新prepare明确拒绝。`smoke-code-editor` 另覆盖拥有型补全→resolver/变量变换→独立 compiled Template→Broker 结果提前释放→真实 Tab/逐位置变换/不同长度镜像输入/单次 undo/IME，及 resolver 重入关闭、退出、独立修改文档、取消和 unsupported。该证据不建立视觉质量、外部语言服务兼容或全部 snippet 语法兼容结论。

协议服务边界可调用 `Broker.invalidateAll()`；它会撤去已经 finish 后仍存储的补全/悬浮/诊断，而不永久停 Broker。Presenter 下一次 prepare、原生输入、chooseSnippet 或 snippetStatus 会观测独立失效代数，取消当前 Session 并释放其独立 Template，Doc 字节/历史不变。普通另一个结果的发布不会据此取消 snippet。详见[语言协议](language-protocol.md)。

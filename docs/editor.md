# 编辑器与系统布局

`ziggurat_ui.editor.Editor` 拥有有界 UTF-8 文档、选择、preedit、撤销历史、焦点和滚动状态。默认实现通过应用提供的 `Surface.measure/paint` 工作，按 scalar 和逻辑行导航；它不导入系统文本布局模块。

可选 `ziggurat_shaped_editor` 在同一个 Editor 上增加系统字素、双向文本和软换行的视觉导航，以及已经准备好的文本绘制。它借用 Editor 和 `ziggurat_text_layout.Engine`，拥有当前 Layout、Prepared 和查询索引，不复制第二套可编辑文档或撤销栈。

## 初始化与输入阶段

```zig
const text = @import("ziggurat_text_layout");
const shaped = @import("ziggurat_shaped_editor");

const engine = try text.Engine.create(allocator, process_main_thread, .{});
defer engine.close() catch unreachable;
var editor = try ui.editor.Editor.init(allocator, .{
    .multiline = true,
    .autofocus = true,
}, "Hello 中文 אבג");
defer editor.deinit();
var adapter = try shaped.Adapter.init(allocator, &editor, engine, .{});
defer adapter.deinit() catch unreachable;

const parameters: shaped.Parameters = .{
    .font = .{ .size = 18, .wrap = .word_character },
    .scale = scale,
};
_ = try adapter.prepare(bounds, parameters);

// 在输入回调中，而非 paint 中执行：
const consumed = try adapter.handleEvent(event, bounds);
_ = try adapter.prepare(bounds, parameters);
const caret = try adapter.caretRect(bounds, scale);
try window.setTextCaret(.{
    .x = caret.x, .y = caret.y,
    .width = caret.width, .height = caret.height,
});
```

Engine 使用进程入口提供的真实主线程身份。Adapter 的 prepare、输入、查询、draw 和 deinit 均检查同一线程，工作线程在访问编辑状态前返回 `WrongThread`。Editor、Engine 及回调借用的 Adapter 地址必须保持稳定；Engine 覆盖所有 Layout，Editor 覆盖 Adapter 的使用期。

应用把事件交给 Adapter；不要再把已消费事件交给默认 Editor。`handleEvent` 的 bool 表示是否消费，边界上的已识别编辑键也返回 true，防止快捷键或文本转换再执行一次。普通可打印键保留原生文本路径，Space/Enter/接受的 Tab 通过完整 key-input 路径插入一次。Alt/Super 和未实现的 Control 组合返回 false，不降为普通编辑动作。

使用 UI Context 时，`on_input` 也接收 `.resize(Size)`，这是显式布局阶段。Size 的 width/height 为物理像素，应用除以 scale 得到 DIP viewport，更新 `Parameters.scale` 后调用 prepare；零尺寸窗口可跳过准备。GTK 从客户区实际 allocation 与 scale-factor 变化发送去重通知。configure 另保留当前真实分配尺寸的兼容通知，用于位置或未映射几何的观察；它可能与上一通知相同，不把尚未落实到 allocation 的请求尺寸冒充可绘制尺寸。Context 保留本身的 invalidate，prepare 成功后才提交应用保存的 viewport。不要等到 draw 中发现尺寸变化才 shaping。

文本、preedit 和剪贴板修改复用 Editor 的验证与历史。默认单行仍拒绝回车插入，粘贴按现有规则规范换行和 Tab。剪贴板由应用显式设置 `editor.clipboard`。原生组合取消同样由应用设置 `composition_context/cancel_native_composition`；Adapter 不自行保存 Window 或注册窗口回调。

## 缓存与失败

`prepare` 是显式、同步且允许分配的输入/布局阶段。字体、locale、基方向、文本、换行宽度或 `Parameters.version` 改变时构造新的 owning Layout；宽度在启用 wrap 时取客户区 `bounds.width`。外部字体目录等变化可通过 version 失效，不依赖全局隐藏字体代数。

选择、亲和性和 preedit 的选择区变化只重新计算几何。滚动、DPI、viewport 或 caret reveal 变化只重新准备可见覆盖，保持原来的 shaping 快照。覆盖范围使用最终滚动位置，并在四边各加 16 DIP 余量；它不会为整个长文档创建超高或超宽位图。Editor 的 `display_revision` 只是缓存失效标记。直接修改 `editor.buffer` 中的文本/preedit 后仍必须调用 `editor.refresh()`；选择变更由 prepare 直接核对。

候选布局、选择矩形、最终滚动及覆盖准备全部成功后，才一起替换旧缓存并提交 scroll/reveal。分配、原生 shaping、覆盖容量或索引容量失败时，旧拥有资源和原滚动策略保持完整。已经成功的文档编辑属于 Editor，不会因为随后 prepare 失败而丢失；应用可报告错误并重试。`draw` 对陈旧文本、选择、尺寸、DPI 或滚动 viewport 返回 `LayoutRequired`，不会用旧布局绘制新文档。

正在同一 Adapter 调用中重入会返回 `Busy`。当前 Frame 正在借用 Prepared 时，prepare/deinit 返回 `ResourceInUse`，不会释放正在回放的资源。资源借用到本次 draw/replay 事务结束；失败帧、关闭和 GPU 转软件回放也必须结束这份借用。正常关闭时在窗口安全点之后释放 Adapter，再释放 Editor 和 Engine；不可在正在绘制的回调中强制释放其存储。

## 视觉编辑语义

所有文档/选择偏移仍为 UTF-8 byte offset。左右使用布局的视觉 caret 边缘，保留 bidi 和 soft-wrap 的 upstream/downstream 亲和性；同一几何位置的别名不会造成重复按键停留。Backspace/Delete 删除整个系统字素，例如组合音标和 ZWJ emoji，不拆成 scalar。上下保留期望 x，Home/End 使用当前视觉行边缘，PageUp/PageDown 按 viewport 高度导航，Shift 扩展现有逻辑选择，Control+Home/End 到文档边界。

选择仍是 TextBuffer 的单个逻辑连续范围。双向文本的选区可产生多个不连续视觉矩形，不新增第二份视觉选择状态。外部 scalar 选择落在字素内部时，只把展示几何向外扩到完整字素；caret 展示向后一个合法边界对齐，不改写原始 IME 的字节偏移。

preedit 仅虚拟替换 committed range，系统 Layout 看到的是组合后的显示文本。候选 caret 使用 preedit 内选择的视觉位置；提交才形成一次文档历史项，取消恢复 committed text。指针或导航取消组合后，在明确的输入边界重新准备 committed 布局再命中。指针拖动继续使用布局 hit test 和现有滚动模型。

此适配器尚不提供词级 Control+Left/Right、富文本 runs、多光标、密码字段、语法高亮或文档虚拟化。它也不自动发布 UIA Text ranges；应用的语义/可访问性接口仍须绑定同一文档。字素与字体结果取决于系统 ICU/Pango 和安装的字体，不是全部输入法的兼容认证。

## 绘制

```zig
fn paintCommand(ptr: *anyopaque, command: shaped.PaintCommand) !void {
    const frame: *ui.Frame = @ptrCast(@alignCast(ptr));
    switch (command) {
        .text => |run| try frame.preparedText(
            run.origin, try run.prepared.view(), ui.Color.rgb(0x202020),
        ),
        .selection => |rect| frame.rect(rect, 0xb4cfff),
        .composition => |rect| frame.rect(rect, 0x5070b0),
        .caret => |rect| frame.rect(rect, 0),
    }
}

// 当前 Frame 的 paint 回调中：
try frame.pushClip(bounds);
try adapter.draw(bounds, scale, .{ .context = frame, .paint = paintCommand });
try frame.popClip();
```

draw 只读取当前快照、平移已准备好的矩形并提交 Prepared，不 shaping、不测量前缀、不分配。调用者负责 viewport clip、颜色及装饰；字体与字距来自同一个 Layout。Prepared 覆盖和原生布局均由可选文本模块持有，GDI/Cairo 与可选 GPU 回放使用相同快照。窗口 resize、DPI 或字体配置改变必须先在布局阶段 prepare，再请求 paint。

容量沿用 TextBuffer 与 Engine 的显式配置：默认文档 64 KiB、8,192 字素、4,096 行。Adapter 默认最多 16,386 个双亲和性视觉停止点和 16,384 个选区/组合矩形；可降低限额，超出明确报错。覆盖默认上限为 16 Mi 像素和 64 MiB 原生临时平面加持久数据，不代表系统字体缓存也由 Zig allocator 限制。当前为全段 shaping 和有界索引，长单行的 Windows 创建成本仍受系统查询影响，不声称适用于无限大文档。

## 验证

`zig build smoke-shaped-editor` 实际调用系统布局与覆盖准备，验证组合音标/emoji 删除、bidi 视觉导航、wrap/滚动、preedit/提交/撤销、缓存重用、分配失败及 lease 事务。超高文档用例要求布局高于 32,768 DIP，但只准备可见 plane；失败不提交 scroll/reveal。重复 draw 在 allocator 故障注入下保持不分配。

`zig build smoke-shaped-editor-native` 使用原生窗口与正式 UI Context，验证真实文本/键消息、系统组合输入路径、预备文本回放、候选 caret，以及失败帧和 draw 内关闭后的 pin 归零。Windows 保持隐藏，还以真实 WM_SIZE 检查 resize→prepare→paint；`-Dgpu=true` 检查设备失败后同一 Prepared 转入 GDI 回放。Linux 在专用 Xvfb DISPLAY 内映射窗口，等待实际服务器 configure/allocation 后完成同一 resize 闭环，并以 GTK critical 作为失败；1x/2x 分别运行。这些检查不依赖浏览器或截图，也不建立视觉质量、物理跨屏 DPI 或真实语言引擎候选 UI 的验证结论。

## 原生文档上下文

可选 `ui.editor.TextBinding` 将同一个 Editor 暴露为有代数与主线程约束的 committed 文档客户端。它连接 Windows IMM document-feed/reconversion 和 GTK surrounding/deletion，复用既有历史，原生修改后通过宿主 changed 回调显式 prepare/caret，不等待 paint。具体容量、组合期间拒绝、解绑与失败语义见[原生文本上下文桥接](text-input.md)。这不改变默认 Editor 的布局依赖，也不表示 TSF 或完整输入控件已经完成。

ShapedEditor 可显式准备 block/underline 的真实 grapheme cell 并使用 `drawStyled`。
默认 `draw` 保持原 bar，文本服务继续使用原窄 caret；见[视觉 caret](editor-carets.md)。

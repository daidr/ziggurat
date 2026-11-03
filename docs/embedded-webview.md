# 视图中的 WebView

`ziggurat_webview_view` 把系统 WebView 页面当作声明式视图里的一个叶子来布局：它和按钮、文本一样参与行列与 `grow`，页面显示在叶子的盒子里。适合文档页、每个标签页一个页面、应用自己生成的 HTML 预览等场景。

```zig
const view = @import("ziggurat_view");
const web = @import("ziggurat_webview");
const embedded = @import("ziggurat_webview_view");

const Browser = struct {
    docs: embedded.WebView = undefined,
    docs_page: web.View = undefined,
    show_docs: bool = true,

    fn build(self: *Browser, v: *view.View) !void {
        try v.row(.{ .grow = 1, .alignment = .stretch });
        try v.text("侧栏", .{ .width = 160 });
        if (self.show_docs) try self.docs.show(v, .{ .grow = 1 });
        try v.end();
    }
};

// 窗口的 Content 是一个 composition.Owner：Host 是全窗背景，页面是其上的原生区域。
var host = view.Host.init(&browser, Browser.build, storage.buffers(), .{});
host.context.render_mode = .gdi;
const owner = try z.composition.Owner.create(allocator, window, .{});
var web_views = embedded.WebViews.init(&host, owner);
host.options.after_frame = web_views.hook();
_ = try host.attachBackdrop(owner);
browser.docs_page = web.View.init(allocator, &browser, pageEvent);
try web_views.add(&browser.docs, &browser.docs_page, .{ .html = html, .storage = .ephemeral });
```

## 创建与移除

`WebViews` 属于一个窗口，管理最多 16 个页面，地址从 `init` 起保持稳定，直到所有页面移除。它的 `hook()` 要装进 Host 的 `Options.after_frame`。`add(item, page, options)` 为页面保留一个原生区域，先隐藏，再用 `options` 把 `web.View` 挂到该区域；`item` 与 `page` 的地址同样要保持稳定。页面的导航、脚本、IPC、工具等都通过 `web.View` 照常使用，见[页面导航](pages.md)。

`WebView.remove()` 移除区域，这会关闭页面（同 `attachRegion` 的语义）。窗口关闭时 Owner 按反向顺序 detach 全部区域，之后在 `on_closed` 中 `owner.close()`。

页面只创建一次，和窗口一样，不要在构建函数里创建；构建函数只负责显示。某一帧没有构建的页面会隐藏并保留原状，所以标签页视图只构建当前标签的页面，切回来时页面还在原处：

```zig
if (self.tab == .docs) try self.docs.show(v, .{ .grow = 1 }) else try self.changelog.show(v, .{ .grow = 1 });
```

## 盒子

页面没有自身尺寸。用 `grow`、拉伸对齐或显式宽高给它空间。页面填满叶子的 bounds；叶子被滚动容器或裁剪区域完全裁掉时页面隐藏。

每一帧结束、所有叶子的位置确定后，`after_frame` 钩子比较每个页面想要的视口与已经应用的视口；有变化时投递一个主线程任务，在绘制之外更新原生区域的位置、大小和可见性。没有变化的帧不做任何事，也没有计时器或轮询。更新失败记录在 `WebViews.last_error`，可用 `takeError()` 取出。

## 滚动外面的原生 UI

阅读类界面常把文档放在原生滚动容器里：文章夹在原生的标题与评论之间、邮件串里的一封邮件、原生卡片中渲染好的笔记。此时页面与内容一样高，自己没有可滚的东西，滚轮在页面上应当滚动外面的容器，就像在周围的原生元素上一样。`web.Options.scroll_to_container = true` 做到这一点：页面上的滚轮和触摸板滚动交给指针下的原生 UI（鼠标滚轮按行、触摸板按距离，方向与修饰键不变），页面本身永不随之滚动，但仍接收按下、键盘与选择。默认关闭，页面自己接收滚轮，适合会自行滚动的页面（文档站点、浏览器标签页、编辑器）。

```zig
try web_views.add(&article, &page, .{ .html = html, .scroll_to_container = true });
// 构建时：
try v.scroll(&list, .{ .grow = 1 });
try v.text("标题", .{});
try article.show(v, .{ .height = article_height }); // 页面告诉应用的高度
try v.text("评论", .{});
try v.end();
```

Linux 上 WebKitGTK 部件的滚动事件在 WebKitGTK 处理之前转给窗口的绘制区域（屏幕上同一点），组合层再把该区域上的滚轮交给背景（`Region.passWheel`），即 Host 的原生 UI。Windows 与 macOS 暂未实现，页面仍自己接收滚轮。

## 页面留下的按键

邮件应用在列表旁边用 Web 视图显示一封邮件的 HTML，列表靠键盘操作：J、K 切换邮件，Ctrl+K（macOS 为 Cmd+K）打开命令面板。用户点进邮件选择文字或打开链接后键盘归页面，但 J、K 和 Ctrl+K 仍然有效：页面没有处理的按键交给原生 UI，作为窗口自己的按键（`KeyInput.from_page` 为 true），窗口的快捷键与 `view.Host.Options.keys` 都能看到。原生 UI 中原本有焦点的控件失去焦点，以免方向键、退格之类移动它的光标；键盘仍归页面，页面照常选择、复制、输入和打开链接。这类按键之后没有文字与释放事件。

页面在以下情况保留按键：在 `keydown` 处理中取消它（`preventDefault`）；在文本框、textarea 或可编辑内容里用它输入或编辑，或输入法正在组字；页面自己用它做事（链接上的 Enter、可滚动时的方向键与空格等，由引擎判断）；Tab（在页面内移动并移出页面）和单独按下的修饰键。

- Linux：WebKitGTK 在 Web 进程答复页面未处理后再次派发该按键，其类处理函数随后放行；区域在子部件的 `key-press-event` 上以 `G_CONNECT_AFTER` 接收这些按键（`zlg_region_forward_keys`）。
- macOS：WebKit 把页面未处理的按键沿响应链交给 WKWebView 的父视图，即窗口的内容视图；它在页面持有键盘时只把按键交给内容，不经输入法、不产生文字或编辑命令。Esc（及 Cmd+.）先以 `cancelOperation:` 命令到达，同样作为 Esc 交给内容。
- Windows：WebView2 不报告页面未处理的按键，尚未实现。

## 圆角与缩放

页面按叶子的 `Style.radius` 裁成圆角，并按住它的 pose 移动和缩放：`view.Embed.present` 在每次绘制前告诉叶子它显示的位置（各级平面 pose 作用后的框）、缩放和圆角。缩放时页面不重新排版，而是按叶子排版时的尺寸布局，像一张图片那样缩小或放大显示；旋转或透视的 pose 不影响页面位置。区域的 `composition.Viewport` 为此带有 `layout_width`/`layout_height`（页面排版尺寸，0 为显示尺寸）和 `radii`（页面 DIP 中、从左上起顺时针的四个圆角半径），圆角外的点不属于该区域。

- Linux：GTK 3 不能变换部件，页面部件按显示尺寸放置，WebKit 以缩放倍数额外缩放页面（`webkit_web_view_set_zoom_level`），使其按原尺寸的 CSS 像素排版；绘制时按圆角以整像素行裁剪，圆角外的像素不接收指针。
- macOS：WKWebView 以 `pageZoom` 携带缩放倍数；半径相同时用图层的连续圆角（`cornerCurve`），不同时用圆角路径的遮罩。
- 两个平台上 `web.View.zoom`/`setZoom` 读写的都是页面自己的缩放，不含上述倍数。Windows 尚未实现。

## 限制

页面是窗口内的原生矩形子窗口（Windows 为 WebView2 controller，Linux 为 WebKitGTK widget），位于 Host 绘制的背景之上：

- 原生 UI 画在页面所在区域的内容（包括弹出层、菜单、对话框、提示）会被页面遮住，不会盖在页面上方；需要覆盖页面的浮层请放在页面之外，或在浮层打开期间不构建页面。
- 叶子部分被裁剪时，页面仍按完整 bounds 显示，不做任意形状裁剪；不透明度不作用于页面。圆角与缩放见下节。
- 指针和键盘输入由原生页面直接接收（页面未处理的按键除外，见上节）；Tab 不会在原生控件与页面元素之间连续移动。
- 读取窗口背后内容的效果（如玻璃、背景模糊）看不到页面；窗口截图中页面位置为背景色，`web.View.capturePreview` 可截取页面本身。

## 验证

`zig build smoke-embedded-webview -Dwebview=true` 在真实窗口中检查：页面区域与叶子 bounds 一致，不构建时隐藏，再次构建时以同一个 PageId 显示，退出时原生资源与分配归零。Linux 在 Xvfb 下运行，Windows 在 CI 的 WebView 任务中运行。`zig build smoke-webview-scroll-linux -Dwebview=true` 把带 `scroll_to_container` 的页面放进原生滚动容器，经 GTK 事件路径向页面发送触摸板滚动，确认滚动的是外面的容器；随后让页面取得键盘，发送页面取消的 H、Tab 与页面未处理的 J，确认只有 J 作为 `from_page` 按键到达原生 UI。

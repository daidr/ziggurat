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

## 限制

页面是窗口内的原生矩形子窗口（Windows 为 WebView2 controller，Linux 为 WebKitGTK widget），位于 Host 绘制的背景之上：

- 原生 UI 画在页面所在区域的内容（包括弹出层、菜单、对话框、提示）会被页面遮住，不会盖在页面上方；需要覆盖页面的浮层请放在页面之外，或在浮层打开期间不构建页面。
- 叶子部分被裁剪时，页面仍按完整 bounds 显示，不做圆角或任意形状裁剪；不透明度不作用于页面。
- 指针和键盘输入由原生页面直接接收；Tab 不会在原生控件与页面元素之间连续移动。
- 读取窗口背后内容的效果（如玻璃、背景模糊）看不到页面；窗口截图中页面位置为背景色，`web.View.capturePreview` 可截取页面本身。

## 验证

`zig build smoke-embedded-webview -Dwebview=true` 在真实窗口中检查：页面区域与叶子 bounds 一致，不构建时隐藏，再次构建时以同一个 PageId 显示，退出时原生资源与分配归零。Linux 在 Xvfb 下运行，Windows 在 CI 的 WebView 任务中运行。

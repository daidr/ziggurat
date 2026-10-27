# 应用字体

`ziggurat_fonts` 管理文字可用的字体族：应用自己注册的 TrueType / OpenType 字体（含字体集合）与系统已安装的字体族。所有函数在进程主线程调用。

```zig
const fonts = @import("ziggurat_fonts");

// 注册字体数据；空名称表示使用字体自己的族名。
const brand = try fonts.register(allocator, @embedFile("Brand-Regular.ttf"), "Brand");
// 任意族名（注册的或系统的）都可以换成 id，同名（不分大小写）得到同一个 id。
const serif = try fonts.family("Georgia");

// 绘制与视图使用 ui.Font.family：
try v.text("标题", .{ .font = .{ .size = 24, .family = brand } });
// 文本排版直接按名称：
const layout = try engine.layout("文字", .{ .family = "Brand", .size = 16 });

// 字体设置界面：已注册的在前，然后是系统的，各自按名称排序（不分大小写）。
const list = try fonts.families(allocator);
defer fonts.freeFamilies(allocator, list);
for (list) |item| std.debug.print("{s} mono={} registered={}\n", .{ item.name, item.monospaced, item.registered });
```

## 字体族 id

- `ui.Font.family` 是 `fonts.family` 发出的 id（1–63），0 表示界面字体，`monospace` 时为等宽字体。id 进入 `FontKey` 的 6 位，所以每个进程最多 63 个族名；超出返回 `error.TooManyFamilies`。
- `fonts.systemName(id)` 是交给系统的名称：以别名注册的字体解析为字体自己的族名（`name` 表 ID 1，优先英文），其他族名原样传递。`fonts.resolve(name)` 对名称做同样的解析，`ziggurat_text_layout` 在建立排版前调用它，所以排版、测量和绘制使用同一个字体。
- `ziggurat_text_measure` 的原生测量器和富文本编辑器同样按 `Font.family` 测量。富文本的 `Attributes.font`（HTML `font-family`、RTF 字体表给出的 CSS 族列表）取第一个族；`monospace` 转为等宽，`sans-serif`/`system-ui` 为界面字体，`serif` 为平台衬线字体。

## 注册

`register` 先解析字体：每个面的族名与 `post.isFixedPitch`（用于 `monospaced`）。数据按 SHA-256 前 16 字节命名，写入用户缓存目录下的 `ziggurat/fonts/<hash>.font`（Linux 为 `$XDG_CACHE_HOME` 或 `~/.cache`，Windows 为 `%LOCALAPPDATA%`），先写临时文件再改名；同样的数据再次注册只增加名称，不重复交给系统。

- Linux：`FcConfigAppFontAddFile` 把文件加入当前 fontconfig 配置的应用字体，并对 Pango 默认字体映射调用 `pango_fc_font_map_config_changed`；`ziggurat_text_layout` 的引擎各有自己的字体映射，在下一次排版前按注册代数刷新。
- Windows：`AddFontMemResourceEx` 让 GDI 渲染器可用该字体（进程私有）；DirectWrite 渲染器与文本排版用系统字体集加上注册文件建立字体集合（需要 `IDWriteFactory3`，Windows 10 起），注册后下一次创建文本格式时重建，缓存的变体格式随之丢弃。
- 其他平台返回 `error.UnsupportedCapability`。

`families` 每次调用都向系统列举字体族（Linux 为 Pango 默认字体映射，去掉 Sans/Serif/Monospace/System-ui 这些别名；Windows 为 DirectWrite 系统字体集合，英文名称），可能需要几十毫秒。以应用给出的名称注册的字体只以该名称列出，不再以自己的族名出现在系统部分。

冒烟检查 `zig build smoke-fonts` 复制一个系统字体，以别名注册后检查族列表与排版宽度。

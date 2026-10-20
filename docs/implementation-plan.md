# 完整功能实施计划

本计划覆盖桌面框架从基础内核到应用控件、系统集成和交付工具的完整能力。它是持续实施清单，不以已有基础模块代替尚未实现的功能。早期八项基础切片与原有验证记录保留在[路线图](roadmap.md)。

整体状态：实施中。只有全部任务满足各自验收条件后，才能将完整计划标为完成。

## 状态与完成条件

- 待实现：尚无满足该项验收条件的实现。
- 进行中：已明确接口、所有权和实现范围，正在实现或验证。
- 部分完成：列出的子项已有实现，剩余部分明确保留。
- 已完成：公开 API、真实实现、正常/失败/关闭路径、适当测试和使用文档齐全；平台范围必须注明。

编译通过、接口占位、单一成功路径或测试替身均不能单独证明原生平台完成。平台编译、原生集成、人工交互和性能验证分别记录。没有原生运行环境时保留未验证状态，不把对应平台标为完成。

每个任务应先确定不变量：谁拥有状态，谁分配/释放，在哪个线程执行，哪些操作使内容失效，关闭与重入如何处理。核心不依赖扩展模块，不引入全局业务状态、隐式线程池、UI 阻塞等待或空闲轮询。可选功能只有显式使用时承担成本。

## 执行顺序与并行边界

1. W01、U01、I01、S01 可在各自模块内并行，分别整合和验收。
2. W02/W03 与 P01 共同冻结平台窗口契约；G01/U02/T01 建立后续控件所需的绘制、布局和文本边界。
3. B01–B04 与 H01–H03 按页面生命周期、合成、输入顺序推进；不得直接把第二份内容塞入单所有者窗口。
4. 系统集成、文档模型、本地化和音频按独立模块实施；其依赖满足后可与 UI 进度并行。
5. 平台、安装、更新、CLI 和示例贯穿各阶段，最后按 V01–V04 做集成验收。
6. G01.5、T04与P01仍为当前实现优先级；新增G01.7/8、G04先固定资源/准备/后备合同，再并行推进可分离子项。系统监视、终端与平台交付按各自依赖实施，不因已列入清单就宣称已完成。

共享核心或同一个原生 ABI 同时只由一个任务修改。实现一个任务后立即 review、验证并记录证据，再推进依赖它的任务；发现设计缺口时修正公共边界，不积累特例。

## 窗口与应用

| ID | 状态 | 范围 | 验收与依赖 |
| --- | --- | --- | --- |
| W01 | 已完成（Windows/X11） | DIP 客户区尺寸、明确坐标系的屏幕位置、全屏进入/退出、置顶 | 普通/max/min 还原、外部 WM、状态事件、失败/重入/关闭；Wayland 能力失败已验，全屏运行未验 |
| W02 | 已完成（Windows/X11） | 拥有/瞬态窗口、模态窗口、关闭及焦点策略 | 父关闭传播、整树模态输入策略、取消与异常回滚；独立顶层窗口，不嵌套事件循环或替代 H02 内嵌内容；依赖 W01 |
| W03 | 部分完成（Windows/X11） | 无边框、自定义标题栏、原生拖动/缩放、透明与材质 | W03.1 装饰/命中/原生交互已验收；W03.3 Windows 系统框架材质已实现（运行验证见记录）；W03.2 客户区透明、Linux/Wayland 材质继续待实现；DPI/最大化/系统菜单；依赖 W01 |
| W04 | 部分完成（Windows/X11） | 窗口枚举/查找、焦点、显示器约束与状态持久化 | 运行期枚举/查找、显式显示器快照、离屏恢复及版本化 worker 存储已验；经 S03 monitors 订阅的显示器变化可达性判断与重新放置已接入（X11 RandR 实测），物理混合 DPI/热插拔、Windows 真实显示器变化与其他平台继续，不在 paint 访问磁盘 |
| W05 | 部分完成（Linux 已验；Windows 已编译，待原生运行） | 应用激活、单实例与参数转发 | OS 锁与显式 IPC；启动竞争、旧实例关闭、恶意/超长参数和用户隔离；W05.1 `system.instance` 已有 per-user 锁、显式 worker 接收、有界帧与拒绝、停止和崩溃回收，激活由宿主经 `App.post` 执行，见[单实例与系统集成](os-integration.md) |

## 布局、控件与绘制

| ID | 状态 | 范围 | 验收与依赖 |
| --- | --- | --- | --- |
| U01 | 已完成（Windows/Linux） | checkbox、radio、switch、progress、禁用态 | 原生输入、失败帧/嵌套 paint、关闭、Windows UIA 身份及资源回收；无每帧分配 |
| U02 | 部分完成（Windows/Linux） | slider、双端范围、步进控件、焦点导航、快捷键与多击 | U02.1、U02.2嵌套scope/显式Escape续交、U02.3原生时序入口与显式注册主按钮多击、普通及committed Space下单文档词/逻辑行选择已分项验；更广未消费键续交、折叠/投影视图的编辑器选择及其他控件多击继续；直接键入数字归 T02；依赖 U01 |
| U03 | 已完成（纯布局合同，Windows/Linux） | grid 与可组合约束布局 | U03.1 grid/span/对齐/自动放置/隐式轨道及U03.2弹性百分比上限、内容/显式minimum优先级、数值基线与未知父尺寸测量已验；失败输出事务、硬界与overflow明确；分隔拖动归U06 |
| U04 | 部分完成（Windows/Linux） | 虚拟 list、table、tree/outline、grid view | U04.1 可变行高列表/可见回放/稳定 ID 锚点已实现；U04.2 声明式视图的单选列表框（非虚拟）已实现；U04.3/U04.4 声明式视图的非虚拟 table（共享列宽、排序指示、单/多选）与 tree（展开折叠、层级键盘）已实现；虚拟 table/tree、列宽拖动/冻结/重排与 grid view 继续待实现；基础依赖 U02.1/T01 |
| U05 | 部分完成（U05.1 只读组合框、建议列表与搜索区域；U05.2 可编辑组合框与 token field） | combobox、autocomplete、search、token field | popup 所有权、输入法、筛选取消、键盘与焦点恢复；可编辑组合框、输入法组合期间的建议处理与 token field 已在声明式视图实现，读屏实际播报与 Linux 可访问性继续；依赖 U02.2/T02/W02 |
| U06 | 部分完成（U06.1 声明式视图的 tabs/toolbar/比例 split；U06.2 tooltip、toast 与一次性唤醒） | tabs、sidebar、toolbar、split、tooltip、toast | 生命周期、遮挡/命中、延迟唤醒撤销与可访问性；split 的 DIP 偏好、RTL、折叠与 sidebar、toast 动画继续；基础依赖 U02.1/G02，popup scope另依赖U02.2 |
| U07 | 部分完成（U07.1 声明式视图的日历、日期/时间/数字输入、颜色选择器与颜色按钮、通用浮层，Windows UIA） | calendar、date/time、color picker | locale/范围/键盘/可访问性已在无窗口测试中验证，见[选择器](pickers.md)；颜色方块已可按住拖动；读屏实际播报与 Linux 可访问性继续；依赖 L01/U05 |
| U08 | 已完成（U08.1 link、badge、segmented、disclosure；U08.2 meter、rating、breadcrumbs、accordion；U08.3 avatar 与导航按钮，Windows UIA） | badge、avatar、link、meter、rating、segmented、accordion、breadcrumbs 与导航按钮 | 稳定身份、分组/展开/链接动作、键盘和语义；不把静态文字/矩形算成完整控件；Linux AT-SPI 不在本行范围；基础依赖 U02.1/G01 |
| U09 | 部分完成 | chart 的数值/分类/时间尺度、axes、marks、stacking 与 selection | 已有纯 Zig `ziggurat_chart`（尺度/刻度、布局、路径、堆叠、降采样、图例、选择状态）与 `ziggurat_chart_view`（视图嵌入、绘制后准备的覆盖蒙版），见[图表](chart.md)，悬停与键盘选择经视图嵌入输入接口接入 |
| U10 | 部分完成（U10.1 声明式视图的 field/fieldset、说明与验证状态、禁用继承；U10.2 嵌入叶子的可聚焦、指针/按键输入与播报，文本节点字体变体） | form、field/fieldset、验证提示与自定义控件契约 | 标签关联、禁用继承、错误语义、测量/绘制/输入/快照事务；嵌入叶子已能登记 Tab 停靠、接收局部坐标指针与焦点按键并礼貌播报，文本节点可按 `Style.font` 选择字号/字重/斜体/等宽并在 GDI/D3D11/Cairo 绘制；form 提交与焦点跳到首个错误、叶子的指针捕获与拖动继续；依赖 U02.1/U03.2/T02/T06 |
| G01 | 部分完成 | 圆角、描边、渐变、阴影、透明度、图片与 SVG/path | RGBA/圆角/内描边、图片驻留/同尺寸更新、严格渐变、圆角阴影/path、有界分组和独立软件/GPU离屏已验收；完整 SVG 继续实施；三后端同一语义与明确资源上限 |
| G02 | 进行中 | theme、动画时间线、spring、变换与局部失效 | 显式动画/有限重复、基础控件主题、Windows/Linux单次唤醒/局部失效、仿射栅格scope/同帧坐标、通用GPU精度预检/整帧后备、共享软件采样及单Document保留坐标桥已验；过滤变换性能、折叠/投影编辑器输入与更广失效复用继续；依赖 G01 |
| G03 | 进行中 | 共享 GPU 资源、文本/图片缓存与多窗口性能 | 显式DeviceDomain/纹理寿命与预算先行；按测量决定缓存容量与淘汰；设备丢失、跨窗口关闭和显存/内存基线；依赖 G01/V02 |
| G04 | 待实现 | 可选可编程着色器、类型化参数、形状填充与元素效果 | 独立准备/编译与拥有型产品，明确软件与各GPU后端能力；不得在paint编译或等待worker；分项见下表；依赖 G01/G03 |

G01 分项独立验收，父项只有以下分项全部完成后才可标为已完成：

| ID | 状态 | 范围 | 验收 |
| --- | --- | --- | --- |
| G01.1 | 已完成（Windows/Linux） | RGBA 形状、圆角填充、向内描边 | 统一外轮廓半径；GDI/D3D11/Cairo 像素、alpha/clip/DPI、几何缓存边界与设备丢失已验收 |
| G01.2 | 已完成（Windows/Linux） | 线性/径向渐变 | 三后端严格 hard/steep/预乘语义，分数 clip、极端椭圆数值、显式精度后备、设备丢失/回收和普通渐变成本已验收 |
| G01.3 | 已完成（Windows/Linux；GPU为Windows） | 阴影与离屏合成 | 有界阴影/分组、独立软件BGRA和显式GPU target/snapshot；尺寸/旧候选预算、复用、DPI/裁剪、失败与设备丢失已验；不含跨设备导入或GPU读回导出 |
| G01.4 | 已完成（Windows/Linux，静态/首帧） | 图片解码、采样与绘制 | PNG/JPEG/BMP/首帧 GIF/显式可选 WebP/EXIF、crop/预乘/mip、三端采样、驻留/设备恢复及双 bank 更新；多帧播放、增量和色彩管理明确不在该切片范围 |
| G01.5 | 进行中 | path、SVG 与图标资源 | 有界解析/曲线/填充规则/描边/变换、外部资源策略、缓存与后端回放 |
| G01.6 | 已完成（Windows/Linux） | 文本 RGBA、分组透明度与 mask | 重叠内容作为整体合成、嵌套/clip/错误回滚、有界工作面、设备丢失；独立离屏资源导出另行实施 |
| G01.7 | 部分完成（Windows/Linux） | 圆锥渐变、统一 stop 与可选色彩插值 | 三种渐变的软件显式sRGB、linear-sRGB、Oklab已验；Windows可选统一GPU程序在明确数值/组合范围内支持新空间，范围外绘制前整buffer后备；透明stop、圆角/内描边、A8、分数clip/group与反射及失败保旧分别验；更广精度与实际GPU性能继续，不自动扩大G01.2范围 |
| G01.8 | 已完成（Windows/Linux，GPU为Windows） | 完整元素子树的高斯模糊 | 显式快照准备及live子树scope、共享Q24软件核和可选GPU两遍滤波已验；完整透明halo、父clip/mask/opacity后合成、反射、失败保旧、最后lease及设备丢失分别验证；绘制前准备有界资源，命中/焦点/语义几何保持原合同 |

G01.2 以真实逐像素差分验收，没有扩大整个陡变区域的容差。相同 offset 使用右连续规则；GPU 使用离线编译的 analytic effect，两端软件复用有界采样，无法证明精度时同一命令缓冲回退。具体数值边界、普通渐变测量和后备策略见[基础绘制](drawing.md)。

线性/径向渐变另已支持显式 `repeat`/`reflect` spread，与三种插值空间、透明 stop、分数 clip、A8 和分组合成组合验证。默认仍为 `pad`；Windows GPU 对新增 spread 返回有类型的能力拒绝，由普通 Context 在同一命令缓冲执行软件后备，不宣称该模式已有 GPU 程序。周期投影在每条命令进入像素循环前准备；既有 stop/命令数组布局和默认 pad 像素保持不变。Windows/Linux Debug 与 ReleaseSafe 的软件、原生合成、失败保旧及 Windows hardware/WARP 后备分别通过，具体数值范围见[周期渐变](gradient-spread.md)。

G01.7 的插值空间由每个渐变显式选择，默认仍为既有 sRGB 语义。linear-sRGB 与 Oklab 在选定空间预乘插值，再转换回 sRGB 输出；Oklab 的有符号通道、透明色、重复 stop 与精确端点分别验证。首片明确使用线性 RGB 通道裁剪处理越界，不宣称完整色域映射或全局色彩管理。默认路径不增加转换表准备；GPU 新模式须独立证明其窄化、转换和采样精度，并测量统一 shader 对默认模式的成本，无法证明时在整缓冲绘制前后备。

G01.8 包含原有透明快照的f64 Processor，以及独立的live子树scope。live scope仅记录一次正文，在显式声明的完整源范围和透明halo上合成，使用相同Q24整数核做水平、垂直两遍滤波，最后应用父clip/mask/opacity；命中、焦点、caret和Space沿用几何范围。`R=ceil(3*sigma*scale)`最大128，scale范围为1/16至16，旧owner、候选、scratch、元数据及保留资源同时预检预算。资源和可选GPU程序在绘制前显式准备，正常paint不分配滤波工作面、编译shader或启动worker。独立literal像素oracle、GDI/Cairo/hardware/WARP回放、关闭和最后lease、逐分配/原生失败及设备丢失已验证；支持范围与两种数值合同见[高斯子树scope](gaussian-scopes.md)。backdrop与任意可编程元素效果分别归E06/G04，实际吞吐量另由V02测量。

G01.3 已验收显式准备的圆角内外阴影、共享 A8 驻留及独立透明离屏资源。G01.5 已有路径/路径数据/填充/曲线/仿射/描边/dashes/trim，以及 SVG 文档、样式、内部引用、渐变、局部 clipPath、alpha/luminance mask、嵌套 mask、两种合成模式和可选系统文字轮廓；连续文字定位、textLength、开放折线 textPath 与显式资源提供者的嵌入图片子集分别验收。pattern 已支持两类 units、viewBox/PAR、本地模板与 host 样式继承，连续 tile 共享 lane 合成；Windows/Linux 两优化与三准备 DPI 原生回放通过，两组未决坐标组合明确拒绝，内容仍限定实色几何。marker 的端点/中间顶点、零长度段、闭合接缝、多个子路径与省略弧已统一为有界拓扑流，通过 Windows/Linux 原生回放。混合字体、更广路径文字/图片策略、paint-server 内容组合及 filters 继续实施，不能把局部 clip/mask 重列为全无实现。`Path.parseData` 只解析 `d` 属性，SVG 文档使用独立可选模块。G01.6 的透明工作面与分组 opacity/mask 已验收，不复用保持 alpha=255 的窗口平面，也不把对子项分别降 alpha 算成分组合成。

U04 同样分项验收：U04.1 建立显式行 ID、可变高度索引、可见范围回放与滚动锚点；U04.2 补齐列表选择/键盘及完整虚拟语义；U04.3 实施 table 的列测量/冻结/排序；U04.4 实施 tree/outline 的稳定展开与层级选择；U04.5 实施二维 grid view。索引助手或只画可见行不能单独算作整个虚拟控件集完成。

U03.1保留已验收的64×64/256项grid、顺序无关约束、输出事务、收缩与两阶段测量。U03.2已实现显式main-axis百分比上限（相对于扣padding后、扣gap前的父尺寸）、自动内容minimum与显式minimum的优先级、row/column数值基线。未知父主轴的measure忽略百分比，不反推结果或求固定点；arrange按已知父尺寸一次解析。显式minimum和有效绝对min保留硬下界，冲突报告overflow；全部坐标与结果检查后统一写出。固定256项、无allocator/原生调用；字体基线由调用者测量，不声称完整CSS布局。见[布局合同](layout.md)。

U04.2/3的选择覆盖行拖选与二维cell block；稳定行/列ID、range锚点、Ctrl/Shift、右键保选、RowHeader整行/列头全选、列重排与RTL视觉方向分别验收。两轴边缘滚动和仿射命中独立验证；失败帧保留旧成功快照，删除/取消/关闭撤销相应临时拖动与失效目标，旧事件不得作用于新行/列。行reorder与拖选冲突显式处理。全选/大范围选择不得在每帧遍历全部行，模型与临时工作空间有界；多击行为另依赖U02.3。

新增待实现的U04.6滚动策略区分可见item锚点、绝对offset和follow-end；复用已有索引/anchor基础，selection锚点不随offset模式改变。follow仅在尾部启用，用户滚离停止、回到底恢复；内容装得下时仍遵start/center/end。覆盖append/grow/shrink/remove、viewport resize、恰好fit、整段瞬时到达和过渡期间用户滚动；ReduceMotion直接到位，最后唤醒撤销，与G02协同而无idle timer。

U06.1 split仍待实现：DIP/百分比两种偏好值与实际显示divider分离，窗口不足时两pane仍按明确约束显示，不覆盖宿主偏好；拖动/键盘从实际divider起算。横/纵、RTL、min/max、缩小再放大、禁用/取消/关闭及真实Splitter RangeValue分别验收，不归入已完成grid。

U10 form/field仍待实现：共享label列按实际control首baseline对齐，description/error不改变label基准；无文字control、行内装饰、fieldset共同测量。label点击focus/toggle、accessible name/description/error关联及禁用继承必须指向实际control，并由原生辅助功能验证。

跨U04/U06/U10保留显式非零u64稳定身份，改名/重排不换state、内容相同的不同对象不合并；父域、移除和generation复用不能接管旧focus/编辑/lease。若增加typed-key辅助器，应明确namespace/generation/容量与零分配路径，不引入默认reflection、格式化key或隐藏hash表；不为API外形推翻现有身份模型。

U02.1保留已验收的拖动捕获、Shift+Tab/方向/分组、键盘增减、disabled、原生队列与Windows UIA。U02.2已有focused内层、显式overlay顺序/barrier和window快捷键scope，以及bare非repeat Escape的一次显式owner continuation；它只隔离注册快捷键，不替代W02模态窗口或U06 popup输入策略。成功front/token限定可用注册，旧frame/卸载/失败候选不能抢键，重复/重入不执行两次业务，不在paint修改业务状态。其他未消费键的通用续交、popup/合成整合仍与U06/H03继续，见[作用域合同](shortcut-scopes.md)。

U02.3已完成显式开启的原生receipt/原始时序入口，以及稳定Context target的主按钮注册、独立控件单/双/三击与第四击重置。原始窗口计数不代替控件计数；处理器更换、失效入口、失败帧、仿射clip、未知按钮打断与回调关闭均有分项验证，见[原生指针事实](pointer-input.md)和[注册控件合同](pointer-clicks.md)。单Document的caret/词/逻辑行及单位拖选已支持普通窗口和显式committed Space，保留同几何跨帧连续性、每次输入的精确frame guard、原始坐标和唯一映射；同一绑定也服务滚动、IME和caret。见[文档选择合同](document-pointer-selection.md)。折叠/投影视图、其他控件多击及更广组合继续，不从相邻位置或paint顺序猜目标，也不把这些子项算作整个U02.3完成。

U04/U06/U10的复合控件保持owner事件即时消费：按压选择后，子editor正确接收后续字符，Changed/Submitted恰好一次；builder重入、失败帧与重绘合并不能重放业务。成功编辑和后续展示失败分别报告，不为了constructor外形把业务写入draw路径。

G03 还须分开验证两类性能边界。遮挡剔除只省略能证明被后续不透明内容完整覆盖的绘制命令，保留输入、业务构建和资源lease；透明、抗锯齿边缘、圆角、仿射、clip、mask及读取backdrop均不能按外接矩形武断剔除。无可用遮挡者的场景避免额外规划成本，使用有界工作空间，并比较开启/关闭优化的像素与实际命令/像素工作量。

元素效果的离屏层按稳定身份复用，区分实际内容矩形与已分配容量；小幅移动/缩放不逐帧重建纹理，扩容/收缩策略进入显式峰值预算。旧buffer/快照仍持lease时不能提前释放；停止绘制、移除、关闭及设备丢失后回收不再被引用的临时层，资源随并发峰值而非历史帧数增长。重复清理和失败帧也须验证。

各GPU后端分别测量有界in-flight帧、drawable/上传缓冲与呈现背压；不能由增加缓冲直接宣称降低延迟。比较主线程等待、输入到显示延迟与峰值内存，空闲时收缩临时资源；停机仍完成已接受责任，不能通过多帧堆积或UI等待掩盖资源不足。缺少对应原生环境的后端保留未验证状态。

G04 分项如下；具备固定内部shader不代表公开可编程能力已经完成，语言/IR与后端格式应独立设计，不要求应用使用某一宿主语言语法。

| 子项 | 状态 | 边界与验收 |
| --- | --- | --- |
| G04.1 | 待实现 | 有界类型系统/中间表示、数字/向量/矩阵/数组、受限控制流、图像采样与CPU执行基准；非法程序/非有限值/整数边界、循环和执行预算、精确错误位置；产品不借源文本 |
| G04.2 | 待实现 | 显式worker编译与预热、owner采用、ready/failed/cancelled状态；按设备/格式/编译选项区分缓存，磁盘损坏/版本变化可回退；缓存有界且可清理，paint不阻塞、不启动隐藏线程或隐式重试 |
| G04.3 | 待实现 | 预查类型化uniform句柄和可复用值缓冲；拒绝跨程序/旧代数/类型与长度错误；记录命令时复制参数，后续修改不能影响已接受帧；图像/程序资源借用与预算明确 |
| G04.4 | 待实现 | 矩形与圆角、path填充/描边、文字与图标coverage填充；预乘alpha、边缘与彩色glyph策略；软件/硬件/后备三者使用独立oracle，不以编译成功代替像素验证 |
| G04.5 | 待实现 | color/distortion/layer元素效果；独立有界输入层、采样外扩与透明越界；效果只改变外观，绘制/命中/语义坐标关系明确；层复用/失败回滚遵守G03 |
| G04.6 | 待实现 | 当前帧backdrop采样与可选预模糊；捕获点/顺序/变换/采样边界明确，防止读写同纹理和错误遮挡剔除；嵌套/设备丢失/预算失败；与E06共用资源而非重复截图 |

U09 的实时折线须保留源数据供选择/读数，按可见物理像素列准备保极值的有界降采样；保留窄峰、数据段端点和NaN/Inf断线，声明横坐标排序前提及重复值策略。独立polyline回放需验证圆角连接/端帽、透明重叠、clip/仿射/DPI；不能用不透明分段快路径改变半透明结果。准备成本、绘制命令和预热后分配分别计量。

## 文本与编辑器

| ID | 状态 | 范围 | 验收与依赖 |
| --- | --- | --- | --- |
| T01 | 已完成（Windows/Linux） | 系统 shaping、grapheme、bidi、软换行、视觉 caret/hit test | T01.1 布局/查询、T01.2 准备绘制/编辑器桥接、T01.3 批量位置快照已验收；UTF-8/UTF-16/字素、复杂脚本/emoji/RTL/选区/fallback；原生回退与多段落构造成本见文档，成熟输入控件与辅助技术仍属 T02/T06 |
| T02 | 进行中 | 完整输入控件、IME/候选/组合、平台文本服务 | 保留客户端及IMM/GTK surrounding、单Document普通字段的焦点/单多行策略/组合/注入clipboard/滚动caret与Windows Value动作已分项验；TSF、真实语言引擎、Linux系统clipboard及更广投影编辑继续；依赖T01 |
| T03 | 已完成（Windows/Linux，有界段落视图） | 可扩展文档 buffer、多选区、查找替换、折叠 | 单文档原子多选编辑/撤销、worker快照流式字面搜索及派生段落折叠已验收；段落/缓存/元数据上限明确，语言服务与成熟字段UI另验；依赖 T01 |
| T04 | 进行中 | 代码编辑 hooks、补全、hover、诊断、Diff | T04.1版本化Broker/Presenter、T04.2行差异/双栏/统一可编辑比较、行内标记及成对上下文折叠已验收；可访问语义与语言工具继续分项；依赖 T03 |
| T05 | 待实现 | 富文本与 Markdown 展示/编辑 | 结构化模型、链接/嵌入资源/复制、非可信内容约束与大文档；依赖 G01/T03 |
| T06 | 进行中 | UIA/AT-SPI/NSAccessibility 完整控件与文本语义 | Windows文档/MTA、空caret/TextPattern2、仿射凸裁剪与辅助动作，以及Linux单源只读AT-SPI/完整Prepared命中已分项验；Windows完整候选point迁移、Linux动作/多源、完整语言单位与其他平台继续；依赖 T01/U04/P02 |
| T07 | 待实现 | 可选字体资产注册、系统/应用字体发现 | 显式准备、有界字体数据/枚举、monospaced与来源、别名/去重、缓存失效及旧Layout最后lease；依赖 T01 |

普通 Document 字段复用一个 Adapter 和调用者唯一 Document/undo，UI 只保留有界注册、成功前台标记与借用 pin。键盘、pointer、Tab、readonly/disabled、单多行与提交、注入剪贴板、原生替换、changed 去重、失败呈现及关闭重入分别验收；已提交 Space 统一命中和滚动后的原生 caret。Windows 已验实际 IValueProvider.SetValue 回程及 readonly 拒绝，坐标准备将语义几何独立 owner 计入 metadata，保持像素平面未准备。真实语言引擎、TSF、Linux 系统 clipboard 和投影/折叠视图仍分别实施。见[Document 字段](document-fields.md)。

T03 分项推进：T03.1 已完成独立有索引的持久文档、拥有型快照及同一文档的 TextClient 桥接；T03.2 已完成可见段落布局、原生编辑桥与增量失效，保持同一份文本/undo；T03.3 已完成多选区原子编辑、流式字面查找替换与派生段落折叠。搜索弹窗、clipboard、语言折叠解析器和辅助文本语义仍按各自任务推进，不能由索引与桥接测试推定完整应用交互。

T04 的差异编辑按以下能力继续推进；只读比较不替代完整编辑器：

| 子项 | 状态 | 边界 |
| --- | --- | --- |
| T04.2.1 | 已完成 | 有界Reader行差异、拥有Hunk与最短整行编辑保证，宿主显式worker |
| T04.2.2 | 已完成（Windows/Linux，只读） | 文档对交付、双栏换行/空白对齐、滚动导航与一次undo的原子revert；成本复用继续优化 |
| T04.2.3 | 已完成（Windows/Linux，无折叠双栏） | 唯一Adapter共享段落投影、双侧发布及committed outcome；编辑/选择/IME/原生几何一致；折叠对齐与组合可访问语义按T04.2.4继续 |
| T04.2.4 | 进行中 | 统一视图、行内差异/成对折叠及Windows双源全文/真实删除行/有界hunk与fold业务控件已验；Tab偶发回归与其他平台语义继续，不伪造文档offset |
| T04.2.5 | 已完成（Windows/Linux，显式接口） | 真实active side/primary caret/current hunk、typed语义命令及有界字面Find已验；inside、前后边界、EOF/空hunk、旧比较与提交后呈现失败明确；查找弹窗/regex等成熟交互另归T02/U05，不以手动selected_hunk冒充caret归属 |
| T04.3 | 部分完成（Windows/Linux） | 拥有型snippet会话、嵌套placeholder/显式变量、有界regex/format变换、补全展开、版本化语言协议、显式工作区/配置、元数据resolve、可选纯文本详情及显式graceful shutdown已验；Markdown/滚动/详情语义与更广语言能力继续 |

T02/T04 的 DocumentEditor 预输入 hook 首片已实现并通过 Windows/Linux 有界整合：显式区分 key、带实际 producer 的正文、preedit 和 native replacement；消费、回调编辑/关闭/重入及原生 applied/rejected/superseded 各有合同；详见[编辑前输入门](editor-pre-input.md)。更高层 Presenter/snippet 已消费的输入不自动转送，完整快捷键 scope 继续由 U02.2 实施。显式 system/keyboard_compose 模式已通过 Windows/Linux 有界原生验证：Windows 使用窗口 IMM 关联，GTK 使用单一活动文本上下文并撤销退休上下文的信号；不能以清空 composition 或忽略 preedit 冒充关闭原生输入法。实际语言引擎与 TSF 仍分别验收。

编辑器展示中的 bar/block/underline caret 与失焦轮廓已按 Windows/Linux 有界子项验收：显式准备同一 Layout 的真实字素 advance cells，paint-only 样式不改变 shaping、原生文本服务或辅助技术的插入几何；默认仍使用原 bar。bidi/软换行/EOF/空行、IME/非空选区回退、预算和最后 foreign free 后的版本复核均有独立原生回归，证据见下方实施记录。版本化 LF 段落背景及有界 committed UTF-8 区间背景/下划线已分别验证，坐标均来自同一 Prepared，正文变化后由宿主重算；诊断 producer 等更高层整合继续，不按相邻行猜归属。Document已有anchor/caret的有向UTF-8 byte选区基础，补反向拖动、Shift、IME、undo和原生上下文回归，不重建另一组选区或复制正文。

T05 的混合样式应将影响metrics的字重/字体runs与仅影响paint的颜色分开；仅改颜色不重新shape，预热后的paint不分配样式数组。Markdown 链接沿用显式主题的 link 颜色和焦点/禁用语义，主题变化只使相应绘制失效，不硬编码链接色或改变文档/选区身份。覆盖跨段落可见范围、组合插入、重叠区间、样式版本与缓存失效；保持T03的唯一Document/undo，不能把现单字体布局算作混合样式已经完成。

T07 负责可选字体注册与发现，不扩大T01已验收布局范围：有界拥有型字体数据、应用/系统来源、monospaced属性、别名/重复名策略及注册后的cache失效。首次系统枚举由显式准备承担，paint不扫描字体；枚举结果独立拥有，旧Layout仍保留其字体资源到最后lease。系统未开放枚举的平台明确返回能力限制，不伪造完整系统列表。

## 页面、协议与混合内容

| ID | 状态 | 范围 | 验收与依赖 |
| --- | --- | --- | --- |
| I01 | 已完成 | 类型化事件、订阅/退订、显式广播、TS 生成 | 纯 Zig/生成 TS；真实 Windows WebView 闭环；session/重入/部分失败/旧客户端兼容检查通过 |
| I02 | 已完成 | 编译期服务调度与显式 caller 上下文 | 签名/错误类型校验、拥有的 Reply/Work、OOM 编码重试不重复业务副作用、真实 WebView 调度 |
| B01 | 部分完成（Windows/Linux） | page 导航、远程/文件资源策略、历史、标题/加载状态 | B01.1 本地页面与 B01.2 远程/显式文件快照已验收；methods/headers、私有文件按需读取与原生 scheme 由 B05.1–B05.3 验收，未开放 file:// 目录；导航中关闭/重定向/失败和 IPC 绑定 |
| B02 | 部分完成（Windows/Linux） | 异步 JS 求值、zoom、user agent、devtools、用户注入脚本 | B02.1既有Windows操作及B02.2两平台文档起始主frame初始化器/有序替换首片已验；Linux DevTools 开关/独立 inspector 已验，两平台 B02.1 属性操作对齐；其他时机/frame/world继续，未做人眼工具窗展示验收；依赖 B01 |
| B03 | 部分完成（Windows/Linux） | cookie/data store、find、截图、打印/PDF | Windows View Cookie/Profile清理、原生find、预算PNG、异步PDF，以及Linux独立CookieStore的URL/显式授权全量查询、写入/快照删除/身份删除/非空完整替换/清Cookie、原生PNG、整体数据清理和有界substring Find/显式unknown状态已分项验收；整词/高亮关闭等不支持选项明确拒绝，Linux PDF及系统打印机输出继续，无页面Windows CookieStore仍明确不支持；依赖 B02 |
| B04 | 已完成（Windows，宿主显式策略） | 下载管理、权限决策与持久策略 | B04.1 有界下载/临时权限与 B04.2 版本化宿主规则已验收；宿主负责规则执行与 worker I/O，合作取消不等于硬磁盘配额；依赖 B01/I01 |
| B05 | 部分完成（Windows/Linux） | 自定义协议、请求/响应与资源流 | Windows B05.1–B05.4及Linux有界custom读取/头授权、异步资源/文件泵、HTTP Range/准备文件响应、独立TLS站点、两平台已知长producer已分项验收；Windows实际HTTPS/browser链使用测试证书例外，生产Profile级pin待实现；Linux custom写请求受实际Origin缺失限制，opaque scheme及更广策略继续；不在UI线程磁盘等待；依赖 B01/I01 |
| H01 | 已完成（Windows/Linux 页面与区域） | page/viewport 与窗口分离、多份内容生命周期 | H01.1 组合所有者/UI backdrop/矩形页面与H01.2独立PageSession/跨宿主DOM/App停机接线已验收；更广Linux页面策略及其他平台归P01/P04；依赖 W02/B01 |
| H02 | 待实现 | 自绘内嵌 WebView、布局/clip/overlay/遮挡 | 原生 child/composition surface、DPI/滚动/resize/设备丢失；依赖 H01/G01 |
| H03 | 待实现 | 混合焦点、Tab、输入法、拖放与可访问性 | Web/native 交接、modal/popup、捕获与关闭；依赖 H02/T02/T06 |

| 子项 | 状态 | 边界 |
| --- | --- | --- |
| H01.1 | 已完成（Windows/Linux UI与矩形WebView） | 唯一Content Owner、代数Region、全窗软件backdrop与多个矩形页面；隐藏保留、remove关闭，不保留离窗DOM |
| H01.2 | 已完成（Windows/Linux） | App停止、独立PageSession、跨宿主DOM保留、parked操作、原生撤离/回滚及Runtime故障闭环已验；Windows关闭失败显式重试，Linux无parking窗口并沿用ephemeral与请求策略 |

本地 HTTPS 运输还依赖独立凭据能力：

| 子项 | 状态 | 验收范围 |
| --- | --- | --- |
| B01.3 | 已完成（Windows/Linux，显式 Bearer） | 创建期冻结的 exact-origin Bearer 已验证首请求、子资源、逐跳重定向、重载/恢复、跨 Profile 隔离及最后 secret 存储回收。HeaderGrant 只校验观察到的头；非空独立配置才拥有 Authorization 装饰责任，不保证匿名 Profile 或控制 SDK 后加认证；依赖 B01.2/P01 |

B02 分项：

| 子项 | 状态 | 验收范围 |
| --- | --- | --- |
| B02.1 | 已完成（Windows/Linux） | 既有异步JS、zoom、user agent与devtools（Linux DevTools 为独立 inspector 顶层窗口）；有界双层请求/结果、取消/超时/导航/detach、单槽完成重入与属性恢复 |
| B02.2 | 部分完成（Windows/Linux 首片） | document-start/top-frame/page-world 的拥有型可信初始化函数体、精确 HTTPS 来源和有序整批替换已通过独立原生验收；初始安装完成才允许导航，失败保旧、旧 ID/关闭/reload/取消回收均验证。Linux提交表示本地future-document manager已安装，不承诺WebProcess ACK或当前文档执行；其他时机/frame/world继续 |

当前细分实施顺序：B01.1 本地页面导航、历史、元数据与代数 → B01.2 远程/文件来源和只读资源策略 → B02 页面操作 → H01 内容生命周期分离；写 method、headers 与流通过 B05 的显式协议推进。本地 Runtime 验证不代替远程策略验证，也不将 URL 参数或网络访问隐藏加入默认可信来源。

当前优先并行推进 G01.5 系统字形轮廓与 SVG 文字、G02 仿射合成及绘制/输入/语义的同一坐标映射、T04.2.4 上下文折叠与编辑器语义，以及 P01 页面与文件策略。独立透明离屏、可编辑双栏/统一 Diff 的行内差异、显式 IPC 字节生产者与 Linux 静态 custom 站点已经分别验收，证据见后文。各切片通过后继续父项剩余验收，不将有界首片的完成推广为整个能力集完成。

## 系统与文档集成

| ID | 状态 | 范围 | 验收与依赖 |
| --- | --- | --- | --- |
| S01 | 已完成（Windows） | 全局快捷键、通知区通知 | 原生注册/冲突/注销、稳定事件 ID、Owner 关闭与诊断重入检查；Linux/macOS 见 P02/P04 |
| S02 | 部分完成 | shell 打开 URL/文件、定位、回收站、文件图标、应用发现/启动 | S02.1 executable 启动、S02.2 URL（https/http/mailto 默认白名单）/关联文件/定位、S02.3 回收站（Windows/Linux）及 S02.4 Windows 16/32px 不透明图标已实现；完整图标（Linux/高分辨率/透明）与安装应用发现/按身份启动待实现；真实关联程序/资源管理器显示未自动验证 |
| S03 | 部分完成 | 多显示器、主题/accent/可访问性偏好、网络、电源与文件监视 | 显示器/偏好/电源/网络快照与合并变化订阅（Windows/Linux）、粗模式文件监视（inotify/ReadDirectoryChangesW）已实现；详细文件监视（快照/rename 匹配）、Linux 电源来源变化、Wayland 显示器、portal 配色待实现；Windows 路径首次运行在 CI |
| S04 | 部分完成（登录启动、深链、文件关联：Linux 已验，Windows 已编译待原生运行） | 密钥存储、登录启动、深链和文件关联 | OS 权限/用户作用域、安装与运行时分工、卸载和参数转发；依赖 W05/R01；S04.1 `system.integration` 按用户注册/卸载并供安装程序调用；密钥存储继续待实现 |
| S05 | 部分完成 | 多格式剪贴板、transfer、惰性 provider、原生拖放 | Board 的 text/HTML/PNG/文件/自定义事务写入、异步读取、惰性 provider、变化事件、Windows 有界占用重试及 Windows/Linux 放置目标已实现；拖动源（需模态拖动循环）未提供；真实跨进程拖放、他进程占用重试与退出渲染未自动验证 |
| S06 | 部分完成（Windows/Linux） | 异步消息对话框、上下文菜单与菜单快捷键 | S06.1 两平台上下文菜单与异步消息框、Windows 菜单栏快捷键已验；非嵌套循环（Windows 菜单在私有安全点进入系统菜单循环）、取消/关闭、禁用祖先、旧消息隔离分别验证；Linux 菜单栏与快捷键分发、物理输入与视觉验收继续；依赖 W02/U02 |
| S07 | 部分完成（Linux 已验；Windows 已编译待原生运行） | 应用身份/系统目录、任务栏或 Dock badge/progress/menu、阻止休眠 | 按平台 capability、用户作用域、原生引用/电源断言配对与最后 owner 回收；依赖 S03/P03；S07.1 身份、目录、任务栏进度/叠加图标/launcher 计数与提醒、休眠断言已实现；任务栏/Dock 菜单与 macOS 继续 |
| S08 | 部分完成（Windows） | 独立托盘/status item、多图标、菜单与popover锚定 | 窗口Owner单托盘/任务栏重建恢复，及 S08.1 App 独立多 item、可选稳定 GUID、锚定托盘菜单、App 停止回收已验；标题与popover亮态（无 Windows 对应）、Linux/macOS 继续；其余平台依赖 P02/P04 |
| D01 | 待实现 | document 模型、每文件窗口与最近文档 | 文档身份/重复打开、保存/另存、dirty/关闭/quit 预检；依赖 W02/S02 |
| D02 | 待实现 | 自动保存、外部修改、冲突检测与崩溃恢复 | 原子保存、版本戳/恢复副本、后台 I/O、丢失与权限错误；依赖 D01 |
| D03 | 待实现 | Jump List/最近文档平台集成与文档菜单 | 隐私/删除失效项、菜单状态与多窗口；依赖 D01/S04 |

S03 的网络状态使用明确的online/metered/unknown类型化快照和变化订阅；online只描述本地连接状态，不保证目标服务器可达，不添加隐式HTTP探测。首个订阅者启动原生监视，最后一个订阅者/owner关闭即撤销；线程交付、旧generation和队列Full/Closed责任明确。主题、accent可空、text scale、reduce motion/transparency等偏好由宿主显式桥接页面初始脚本和变化事件，reload/恢复不得沿用旧页回调，默认不启动额外监视或轮询。

S05 的多格式/惰性provider之外还须处理剪贴板被占用：保留原错误码，使用可取消的有界重试及显式调度，不在UI线程sleep/等待或嵌套消息循环。覆盖另一进程占用、延迟渲染互等、关闭/停机、超时及全部格式失败；现Windows文本helper不等于完整剪贴板服务。

S03 的文件监视分为两个独立合同：详细模式维护有界快照/变更批次并按稳定文件身份匹配rename；粗模式仅报告应重新检查的目录，不读取全部文件metadata、不伪造精确rename。递归/ignore、debounce与最大延迟、初始ready、队列/批次背压、条目/FD/工作预算均明确；系统overflow触发受限重新扫描或明确失败，不能永久丢事件而仍报告健康。平台原生监视按能力实现，宿主显式管理worker，不在UI阻塞等下一批。

详细模式扫描以已打开目录/文件身份校验相对条目，覆盖symlink/junction替换、watch root移动/删除、原子替换与删后重建；hardlink或身份不唯一时不猜rename，大批量配对不能退化成两两路径比较。粗模式对overflow提供全根hint，不能用于需要精确跟踪文件身份的文档。页面监视入口另需显式根目录授权/预算与旧页撤销，不因有通用IPC而自动开放磁盘范围。现开发资源变更通知不代表该完整服务已完成。

D02 的外部修改/文档追踪必须覆盖另一程序save-replace后紧接rename：使用事件对应的文件身份，不能只事后stat旧路径。应用自有读/rename在Windows sharing冲突下由worker做有界可取消重试，其他权限/缺失错误及时返回；失败不丢dirty正文或错误迁移文档身份。验收包含竞争保存、连锁重命名、删除/恢复、关闭/quit与最终零句柄。

B03 增补独立App/profile拥有的CookieStore：首个页面加载前即可提交操作，明确是否允许无页面时启动原生环境，不创建隐藏窗口；与View/PageSession共享哪个profile由宿主显式选择。拥有型有界all/filter查询、URL/name/domain/path匹配与精确domain/path删除分别定义，读取/清除整个profile要求显式授权；重复名/路径、HttpOnly/secure/SameSite、队列Full/取消/关闭与最后native引用均验收。现按已授权URI操作的View工具继续保留既有合同，不由本项扩大默认权限；区分原生受理与查询可见的完成状态，使用显式初始化屏障验证首页面首个请求前cookie已经生效。

Linux CookieStore 已分项验收 URL 查询、独立显式授权的全量读取、设置、带当前值的完整 Cookie 快照删除、仅按 name/domain/path 的身份删除、非空完整替换，以及独立授权的仅 Cookie 清除。快照删除包含值匹配，不能代表无条件删除，也不承诺原子 compare-delete；身份删除使用单次过期 tombstone，完整替换使用一次真实原生操作，不隐藏读取或 clear/set 序列。返回成功仍须由后续查询验证可见状态，不承诺持久化或受理后的回滚。Windows 的无页面独立入口先明确 Unsupported，不借隐藏 controller 实例伪装此能力。预算仅覆盖本项目请求的 malloc 和调用者 allocator；libsoup/GLib 对象、其内部字符串、引擎列表及进程成本另列，并以输入长度和 pending 上限约束其个数。

S08保留现Windows窗口Owner单托盘、图标/tooltip更新、消息与任务栏重建基础；独立App级多item及下述新增能力仍待实现。位置保留按各平台真实能力验收，稳定ID由应用提供，不从创建顺序或图标路径猜；多个item销毁/重建及跨启动不串位。popover/menu正常关闭、取消、owner关闭与异常路径均撤亮态；不支持的位置/亮态能力明确返回。S01已验收的Windows通知区气泡保持原范围，P02/P04分别实现原生托盘/状态项。

P04 的通知增补可选发送者身份/头像：独立拥有的显式ID、名称、编码图片和会话分组，有界解码/复制；数据是否交给系统由宿主选择，不把ID推断为邮箱/电话。授权/entitlement或原生转换失败时提供明确普通通知后备；Show/Close/clear与迟到回调共用同一通知寿命，同ID替换/clear/Stop撤销旧异步准备，晚到完成只回收原生责任。不能以普通通知成功代替发送者外观的真实平台验收。

S04 的系统密钥服务需区分缺库/会话bus/服务不可用的Unsupported，与已存在但locked/denied及真实I/O错误；取消、最后订阅/句柄和原生错误完整保留。测试使用私有服务或假bus，不读取用户真实凭据。D03的Jump List另验整批Tasks提交、失败保旧、Recent类别与宿主声明的working directory；Unicode/空参数/引号/尾反斜杠通过真实子进程核验argv，不能靠字符串相似判定正确。S01保留owner线程串行注册，不为并发调用复制第二注册表；增加显式post/重入/冲突回归。


## 平台补齐

| ID | 状态 | 范围 | 验收与依赖 |
| --- | --- | --- | --- |
| P01 | 部分完成（Linux/X11） | Linux WebKit 后端 | GTK3 content host、ephemeral HTML、持久Profile/CookieStore、custom读取/显式头授权、worker文件流与显式FileWindow、远程策略、矩形区域、PageSession及有界原生Find已验收；创建期证书例外、exact-origin Bearer和独立Endpoint组合已验。FileWindow只选择宿主授权的字节表示；显式GET/HEAD范围准入、借用头与宿主TLS运输的206/416文件窗口已分项验收，local_site仍未开放。当前Runtime custom写请求无实际Origin而拒绝；文件响应公开组合、完整local_site、PDF/其他工具继续；依赖 B01 |
| P02 | 部分完成 | Linux 菜单、托盘、选择器、clipboard、系统服务与可访问性 | X11/Wayland/portal 差异显式化，不用假成功；依赖 S01–S06 |
| P03 | 待实现 | macOS AppKit 窗口、主循环、输入与自绘 | 主线程/ARC 或显式 retain/release、DPI/IME/关闭资源；依赖 W01–W03/T01 |
| P04 | 待实现 | macOS WKWebView、系统设施、可访问性与 GPU | 实际平台运行和签名权限；依赖 P03/B01/S01–S06 |
| P05 | 待实现 | ARM64 构建/原生验证与浏览器目标 | 分别记录可编译/可运行/能力缺口；浏览器目标单独定义宿主生命周期与资源规则 |

P01 的 Linux HTTPS 本地来源分两片实施。首片由宿主提供已运行的 loopback HTTPS 服务，独立 Profile 在创建期冻结单一 canonical `127.0.0.1` 的有界 certificate-only PEM、直连无代理和 TLS 错误拒绝策略；默认 Profile 不构造证书对象。证书例外属于共享 manager/session 的 host 范围，没有端口隔离或公开单项撤销，不是强制证书 pin，正常系统信任仍有效。各实际 Context 在发布前应用同一冻结策略，首请求继续受请求扩展 ACK、精确 origin/method/header 和 IPC 门禁约束。宿主读取文件、运行服务和管理 worker，框架不创建服务器或隐式 worker；系统 TLS 自有线程成本另列。

首片已验证真实握手、无例外/错证书/错 host、系统代理存在时仍直连、首请求 Cookie、跨 Profile 隔离及重载/恢复/停放/停机后的最后释放，具体证据见后文。不同端口隔离 origin/localStorage，但同 host 的 Cookie 不因端口隔离。独立有界 HTTPS 运输及其实际内存/动态/文件页面组合已在后续切片验证；它仍不把远程网络响应称为 `Responder.respondFile`，Linux `local_site` 保留 false，secure 自定义协议也不等于 HTTPS。

独立资源运输已由可选 `ziggurat_https_resources` 提供：宿主显式拥有 TLS-only HTTP server、主循环和 worker，Endpoint 拥有独立网络请求身份、有界内存响应、GET/HEAD、Bearer 认证与精确 origin 门禁，网络写入 credit 不冒充页面消费 ACK。文件复用既有中立 `ziggurat_file_stream` 的 pollable/pump/取消与物理引用，consumer 接受边界不依赖 WebKit custom response。一次有界 chunk、关闭累积、慢客户端背压、HEAD 零读取、短文件/EIO、断开/取消和最后物理容量归还均有正式原生回归；不使用会隐式启动文件 I/O 线程的默认 async fallback。Cookie、loopback 或缺失 Origin 本身都不是认证，宿主 server 的连接/解析/超时及系统 TLS 内部成本另列。Linux WebKit 与公开 Endpoint 的真实组合已验证，仍须显式配置 Profile、证书、请求许可与独立凭据，尚不扩大 `local_site` capability，见[HTTPS 资源](https-resources.md)。

现有 `request_headers`/HeaderGrant 只约束已观察的头，不添加凭据。Windows/Linux 的 `RemotePage.request_credentials` 独立负责创建期 Bearer 装饰：secret 在原生请求前冻结，仅对精确来源生效，每次重定向重验且不交给其他 origin/Profile，不把 secret 放 URI 或借 Cookie/缺失 Origin 代替认证。非空配置先撤原 Authorization，再按普通策略核验并为精确目标装饰；不能与观察型 Authorization HeaderGrant 混用。两个 Runtime 的首请求、子资源及逐跳计数均已通过；完整 HTTPS 本地站点便利层继续独立实施，见[请求凭据](request-credentials.md)。

## 可选模块

| ID | 状态 | 范围 | 验收与依赖 |
| --- | --- | --- | --- |
| L01 | 部分完成 | catalog、locale、ICU message/plural、数字/日期与 RTL | 已有纯 Zig `ziggurat_i18n`：编译期/加载期校验、无分配格式化、locale fallback 与协商、约 50 种语言复数规则、数字/日期、pseudolocale 与方向查询，见[本地化](i18n.md)；控件双向布局、时区数据、货币数据与完整 CLDR 覆盖待实现 |
| A01 | 部分完成 | 音频解码、内存音效与流式播放 | 已有 `ziggurat_audio`：WAV、纯 Zig FLAC、MP3（minimp3）与 Ogg Vorbis（stb_vorbis）、内存音效与流式播放、seek/音量/pan/速度/循环与区间循环、混音线程无分配、WASAPI 与 PulseAudio/ALSA、默认设备切换重开、空闲关闭与无设备静音走时，见[音频](audio.md)；CI 主机无声卡，真实设备出声尚待本地验证 |
| E01 | 已完成 | 插件注册与显式初始化/关闭依赖 | 固定容量应用级依赖图、全图预检、失败逆序回滚、取消/重入/线程；Windows/Linux 运行及独立 review 通过 |
| E02 | 首片完成 | Fetch 与 WebSocket | 显式 transport/worker、取消/背压/大小限制、TLS/断线、类型化客户端；依赖 E01/I01 |
| E03 | 首片完成 | SQLite | 已有可选 `ziggurat_sqlite`：脚本拉取并校验固定 amalgamation，连接、预处理语句、类型化绑定、借用行读取、事务/savepoint、`user_version` 迁移、`interrupt` 取消与 `ui_thread` 主线程拒绝，`test-sqlite` 在 Windows/Linux CI 运行，见[SQLite](sqlite.md)；在线备份、增量 BLOB I/O、自定义函数与加密待实现 |
| E04 | 待实现 | PTY 与终端视图 | 子进程/终端解析、输入/resize/流控/退出和回收；依赖 E01/T01/G01 |
| E05 | 待实现 | game loop、camera、gamepad 与材质扩展 | 显式启停时钟、输入热插拔、帧/功耗预算与平台能力；依赖 E01/G02 |
| E06 | 首片完成 | backdrop blur、glass 与滚动边缘合成 | 已有 `Frame.backdropEffect`：均匀/渐变模糊、玻璃（regular/clear、tint、颗粒、弧面折射、亮度映射、边光）与柔和/硬滚动边缘，在 GDI/Cairo 软件平面采样，含效果的帧在 D3D11 下整帧软件回放；显式工作区预算与超限后备、减少透明度/高对比不透明后备；另有 29 种由显式相位驱动的加载动画与视图层 `Style.material`/`Style.edges`/`loadingIndicator`，见[背景效果与加载动画](backdrop-effects.md)；GPU 背景采样与按压动效待实现 |

E04 继续分项实施，均为待实现，不由PTY或静态终端绘制单独代表完成：

| 子项 | 范围与验收 |
| --- | --- |
| E04.1 | 有界byte连接/PTY、parser与屏幕模型；显式worker读写/背压、resize/scrollback策略、进程退出、半关闭、取消与最后引用回收 |
| E04.2 | 默认/自定义快捷键与performable状态、应用预输入hook；未执行动作仍交给程序，吞key时对应text/release规则明确；应用mouse协议、整行滚动、选择与zoom优先级 |
| E04.3 | 拥有型多MIME transfer快照、异步按需读取与粘贴流控；offered/sending/sent/not-taken及模式变化、取消/关闭；不把借用的原生provider交给worker |
| E04.4 | 程序请求读取/写入剪贴板的显式deny/allow/ask策略；默认deny，OSC52/5522等请求有界，首个回答生效；晚答、无view、关闭与权限拒绝不能发送泄漏数据 |
| E04.5 | CopyOnSelect含SelectAll与运行期切换；图像无文本粘贴在bracketed模式下的明确行为，非支持程序返回无文本；无默认静默格式转换 |

E04的解析/协议识别、原生PTY和人工交互分别验收；剪贴板格式/权限机制复用S05，不建立第二全局剪贴板状态。E05的可编程材质依赖G04，不能由固定内部shader或示例效果算作公开能力完成。

## 分发、开发工具与集成验收

| ID | 状态 | 范围 | 验收与依赖 |
| --- | --- | --- | --- |
| R01 | 部分完成（R01.1 单文件安装/启动/卸载程序） | Windows 安装/卸载器与文件关联 | 用户/机器作用域、静默安装、升级/回滚/卸载用户数据、真实签名 |
| R02 | 部分完成（R02.1 Linux desktop 条目、deb 与用户/系统范围安装；macOS 不在本轮范围） | Linux desktop/deb/安装脚本、macOS app/DMG/公证 | 权限/图标/依赖/卸载、签名与 stapling；依赖 P02/P04 |
| R03 | 部分完成（R03.1 发布索引检查、可续传下载、进度/取消与关闭后启动） | 更新检查/下载/进度/取消、提示 UI 与重启 | 重用现有验签发布；feed 版本/网络错误/部分文件/运行 EXE与退出否决；依赖 I01/U06 |
| R04 | 部分完成（R04.1 签名增量、全量回退、保留/回滚/清理与密钥背书） | 增量更新、失败全量回退、版本保留/回滚/密钥轮换 | 签名覆盖来源目标、大小限制、故障注入、旧客户端升级；依赖 R03 |
| R05 | 部分完成（R05.1 静态发布目录、增量生成与幂等索引） | GitHub/S3 发布、增量生成与发布清单 | 显式凭据和发布动作、幂等重试/资产一致性；私钥不进入工程；依赖 R04 |
| R06 | 部分完成（R06.1 init/dev/build/package/doctor 与三种模板） | 统一 init/dev/build/doctor CLI 与模板 | 原生/Web/混合模板、前端与原生 watch、诊断、可复现构建；依赖 H02/R01 |
| V01 | 待实现 | 多窗口文档、自绘大列表、Web 与混合应用示例 | 覆盖完整业务流程、失败/取消/退出路径；示例不能替代模块测试 |
| V02 | 待实现 | 长期内存/多窗口/GPU/冷启动/输入到显示基线 | 可复现硬件/驱动/系统与统计口径，资源随并发峰值而非历史次数增长 |
| V03 | 待实现 | 原生交互、输入法与屏幕阅读器验收 | 与隐藏窗口检查分开；需要真实平台与明确的交互验证，不由单测推定 |
| V04 | 待实现 | Windows/Linux/macOS 远端 CI 与分发演练 | 各平台运行证据、真实证书/仓库配置；编译探针不替代运行 |
| V05 | 部分完成（V05.1 声明式视图无窗口驱动、V05.2 无窗口键盘回放） | 无窗口交互测试、控件树/布局/绘制 inspector | 可重放输入、稳定节点、错误快照、测试/生产成本隔离；inspection 与运行中窗口关闭安全；依赖 U10/G01 |
| V06 | 待实现 | 可选模块的链接、启动与默认运行成本隔离 | 最小core/自绘/Web/无IPC/无文档/无本地化样例分别测量；不用的生成器、字体、日期数据、解析器和原生后端不启动或进入默认依赖；依赖 R06/V02 |

V05 的测试时钟由每个测试实例显式持有，默认冻结，只由advance/step推进；复用动画已有的调用者单调时钟边界，补齐统一测试驱动，覆盖动画、deadline、tooltip、多击、编辑合并与取消。大步跳时按定义的到期顺序执行，停止后无残留唤醒；不修改生产全局时钟、不用真实sleep证明时序。原生输入注入以已处理事件/序号为完成条件，保留有界截止时间，输入hook返回与应用处理完成之间的关系必须明确。性能回归比较固定场景的帧/命令/分配/shape/采样工作计数，时间仅作为独立硬件指标。

V06保留现有core/UI/Web可选模块边界，新增系统化成本验收，不把已有按需加载基础记为缺失；分别核验链接依赖、进程/线程、注册订阅、启动分配和默认静态数据。基线与阈值由本项目可复现样例确定，不移用其他硬件或工具链的数字。

R06/V04 的依赖准备须先完成有界下载/校验/发布，再开始并行测试；同一缓存跨进程竞争使用明确锁和原子发布，失败/截断不留下可用假象。工具的原生调用检查覆盖条件编译及C ABI入口，不能只检查普通源文件。工具与测试设施保留独立依赖边界。

R06/B01 增加不启动页面的Runtime可用性诊断，区分已实现backend能力、已安装引擎/版本、初始化结果及权限/配置失败；探测自身的线程/阻塞/动态库成本明确。`backendCapabilities`继续只描述实现合同，不能以true冒充实际Runtime可用，也不为自绘应用默认加载Web后端。

R02/P04 的macOS打包按显式配置在签名前嵌入provisioning profile，并校验其与签名方式、bundle身份和entitlements的组合；dev/正式身份分别处理，配置失败不悄悄丢弃profile或受限能力。app/DMG/更新归档必须携带同一已签名产物，profile变化触发重建，真实授权与公证仍需对应系统验证。语言资源生成合并保留应用自有InfoPlist.strings键，明确覆盖优先级；有界解析UTF-8/UTF-16和受支持plist形式，坏输入不覆盖旧产物，输出symlink不能使生成器改写源资源。无frontend或未用日期格式化的应用不生成无关语言前端产物、不默认链接日期数据；与L01/V06共同验收。

## 实施记录

### 2026-10-17 能力与验收补充

- 新增G04六个着色器子项、G01.7圆锥/色彩插值、G01.8元素模糊、T07字体资产和V06默认成本验收；补G03遮挡/离屏层/in-flight资源、U09实时折线及V05确定性测试驱动。
- U02/U03/B02在保留已验收首片的基础上列为部分完成，分别增加嵌套快捷键/多击、弹性百分比约束、拥有型用户脚本；补U04选择/滚动、U06 split、U10 form、T02/T04输入与展示、T04.2.5真实caret-hunk查询。稳定ID、有向选区和调用者时钟已有基础，不重复新建替代模型。
- 细化独立CookieStore、精确/粗粒度文件监视、文档save/rename竞争、网络/偏好订阅、密钥/剪贴板错误与忙状态、终端协议，以及App级多托盘、macOS发送者通知/签名前profile/语言资源合并。
- 新增能力均仍待实现或作为原有部分完成项的剩余验收；本次计划修订没有扩大历史测试的证明范围。示例、文档重排、发布版本及修复性变更分别转入已有任务的验收，不据此复制独立功能项。

### I01 类型化事件

- 入口：`src/ipc/events.zig`、`schema.zig`、`client.ts.in`；`docs/ipc.md` 定义寿命、容量、回调重入与部分广播失败语义。
- Zig 协议/事件 17 项通过；Bun 客户端 16 项、113 断言通过；生成客户端、事件 API 正反例、纯事件与原有纯 RPC 名称兼容均通过严格 TypeScript 检查。
- `zig build smoke-ipc -Dwebview=true` 通过真实 Runtime 的订阅→类型化消息→退订→旧消息抑制，以及 reset/close token 失效；原 RPC、错误、流 ACK 和取消继续通过。检查不评价视觉质量。
- 构建显式声明测试页面和导入的生成客户端为 Bun 输入，防止使用旧 bundle；`tests/ipc_fixture_check.zig` 检查工程内客户端与当前生成器/schema 一致。
- 事件不提供消费 ACK，需要消费背压时使用 stream；宿主显式管理 session 与 transport，不存在全局广播注册表。

### S01 全局快捷键与通知区通知

- 入口：`src/system/windows.zig`、`types.zig`；`docs/system.md` 记录完整 API 与 Windows 能力边界。
- `zig build smoke-system-events` 在 Debug/ReleaseSafe 通过真实注册、冲突、注销、Owner 更换/关闭和 ID 耗尽检查；12 轮关闭后 USER=6、GDI=10 保持不变，系统快捷键可以重新注册。
- 通知通过真实 Shell 提交，原生消息注入验证点击、旧 ID、pending 关闭清理；预先删除 Shell 项制造失败，诊断 sink 重新附加 Owner 后旧点击不进入替换服务。
- 这是通知区通知，不等于现代 Toast 或送达保证；物理按键、人工点击和可见展示未由这些检查证明。Linux/macOS 对应 API 显式不支持，继续由 P02/P04 实施。

### W01 窗口几何与状态

- 入口：`src/root.zig` 与平台适配器；`docs/windows.md` 说明 DIP/屏幕坐标、动态 capability、异步请求和已观测状态、状态事件、Busy 与非原子失败边界。
- Windows 在未激活的独立 desktop 验证普通/最大化/最小化全屏还原、置顶、菜单客户区、隐藏状态、重入与原生关闭；不会切换用户桌面。
- Linux 隔离 Xvfb/Openbox 使用正式状态/resize 事件推进相同还原、置顶和关闭场景；另覆盖 WM 从外部进入/退出全屏后重新施加策略，无自有快照时不伪造还原几何。
- `scripts/linux-window-state.sh` 实际跑通独立 Xvfb、WM readiness、`--require-wm` 和退出清理。无 WM 明确失败；Wayland 隐藏窗口只验证无位置/置顶能力，不把其全屏运行记为通过。
- 失败出口先保留现场诊断，再发布回滚后的最终状态；部分状态→回滚与诊断回调重入单测通过，原生资源在关闭后归零。

### U01 基础控件与 U03 网格

- 入口：`src/ui/widgets.zig`、`input.zig`、`grid.zig`；见 `docs/widgets.md` 与 `docs/layout.md`。
- Windows/Linux 原生输入验证四类控件、分组、禁用/裁剪/移除、失败帧、嵌套 paint 和回调内关闭。绘制只读业务状态，输入/命令/语义事务提交，无每帧 Zig 堆分配。
- Windows 实际 UIA 客户端及保留的原生 provider 验证 Toggle/SelectionItem/Selection/RangeValue；移除/关闭后 QueryInterface 保持原接口身份，而属性与动作返回 ElementNotAvailable。有效节点 OOM 和缺失节点的错误码分别验证，最终独立引用归零。
- Grid 覆盖 fixed/fr/minmax、跨格、同 span 共享提案与声明顺序置换、内容轨道收缩、自动放置/重叠策略/隐式轨道、配置末轨与两阶段测量。容量/无效参数/测量失败均不部分改写输出；最大规模与极端权重有工作量边界检查。
- 测量由应用显式提供字体、换行和缓存；没有把测量 hook 算作完整 shaping 引擎，也不声称 Linux AT-SPI 或人工视觉验收。

### I02 编译期服务调度

- 入口：`src/ipc/dispatch.zig`、`dispatch_test.zig`；`docs/ipc.md` 给出 handler 签名与 caller context、Reply/Work 的借用和移动规则。
- IPC Zig 测试合计 24 项，包括同步副作用仅执行一次、分配失败后只重试编码、延迟参数 arena、声明错误、流 ACK、取消/close/reset 和全分配故障检查；6 类错误签名的实际编译探针均被拒绝。
- 真实 `smoke-ipc` 已通过 Dispatcher 和拥有的 stream Work 执行原有方法，结束时 pending=0、subscriptions=0；RPC 与事件兼容检查继续通过。

### 本批整合

- Windows Debug/ReleaseSafe 与 Linux ReleaseSafe 的 test/check、相关原生窗口/控件/生命周期/WebView 检查通过；详细平台边界留在各模块文档。CI 接线已更新，未声称远端执行。
- smoke 只构建/安装自己的程序；WebView 检查额外显式依赖 loader 与许可，纯核心检查不再因为不相关示例或 UI 中间态而被阻断。全新输出目录的真实 WebView 检查通过。
- 各模块完成交叉 review；确认问题均已修复并补对应检查。该批完成时 W02、U02、G01、T01、P01 等尚未实现；后续批次按下列证据更新，完整计划没有标为完成。

### E01 显式扩展生命周期

- 入口：`src/extensions/root.zig`，独立模块 `ziggurat_extensions`；[扩展生命周期](extensions.md) 说明插件上下文、唯一所有者、线程与异步业务撤销边界。
- 固定 64 项、拥有名称快照、全图预检和拓扑排序；初始化失败保留原始错误，只逆序关闭已成功插件。失败的当前插件自行回滚，Graph 不引入全局服务表、隐藏线程或事件循环。
- Windows Debug/ReleaseSafe/ReleaseSmall 与 Linux ReleaseSafe 各 9 项测试通过，包括实际分配失败、描述快照、最末 bit、取消、回调重入、跨线程拒绝与恰好一次关闭。ARM64 Windows/Linux 编译探针通过，未宣称对应原生运行。
- 独立 review 无确认缺陷；补充了启动后禁止复制/移动 owning Graph 的明确约束。网络、SQLite、终端和其他业务插件继续分别在 E02–E06 验收。

### G01.1 RGBA 形状与内描边

- 入口：`src/ui/geometry.zig`、`commands.zig` 和三个 renderer；[基础绘制](drawing.md) 记录外轮廓、颜色、裁剪、缓存与成本。
- `roundedRect` 和 `strokeRect` 保持相同外轮廓半径，描边向内；没有用小半径时变方角的特例替代完整语义。GDI 复用 DIB，D2D 用固定 32 项几何缓存，Cairo 偶奇填充内外轮廓。
- Windows Debug/ReleaseSafe 真实 GDI、硬件 D2D 和 WARP，以及 Linux ReleaseSafe 真实 Cairo 通过 scale 1/1.5/2、alpha 叠加、clip、细/粗描边与故障回放检查。边缘 AA 允许后端差异，不声明逐像素相同。
- 热缓存、平移、32 项上界和淘汰、设备丢失释放/重建及 native 引用归零通过；软件 surface 限 32768px/边、256MiB 像素平面。极大尺寸/scale 在 native 分配和整数转换前失败并保留原 surface。
- 交叉 review 已修正轮廓语义、尺寸/scale 边界与测试 DC 释放次序；渐变、阴影、图片、path 和其他透明度分别保留为 G01.2–G01.6。

### W02 拥有窗口、模态与原生键盘边界

- `WindowOptions.owner/modal` 在创建时固定关系；核心拥有整棵关系树，最新可见模态分支限制根树中的其他分支。显式 enabled 与模态禁用分别保存，正常输入用缓存结果，不逐事件扫描或分配。
- 父关闭预检所有后代，取消不部分自动关闭；强制销毁按子到父排队。show/destroy 失败恢复仍存活的模态状态；回调固定、旧句柄代数、原生外部销毁与跨非模态层的模态关系均验证。
- Win32 owner 与 GTK transient/group 使用平台实际能力。Windows 独立且未激活的 desktop、Linux 隔离 Xvfb/Openbox 原生检查通过；Linux 三轮 App 关闭原生计数逐轮归零，GTK 自己创建的辅助窗口借用组关系在最后框架成员关闭时解除。
- `Content.key_input` 明确返回消费结果；Windows 在 TranslateMessage 之前消费，GTK 在非组合状态下先处理快捷键，保留 IME/AltGr 优先。实际队列/直接消息、Shift 键映射、repeat、组合输入、Alt/Super、外部 HWND userdata 安全与回调内关闭检查通过。
- review 修复整树模态策略、销毁失败恢复、原生捕获发生在策略过滤之前、失效 HWND 释放捕获以及 GTK 组残留引用。焦点激活仍由 OS 决定，不声明所有 WM/物理键盘布局或人工输入法体验均已验收。

### U02 范围控件与键盘导航

- 入口：`src/ui/input.zig`、`widgets.zig`、`root.zig` 和可选 UIA bridge；见[基础控件](widgets.md)。slider、双端范围、步进按钮使用显式应用值和相对 `ValueChange`，不把上一帧数值当业务事实；指针捕获不依赖重绘频率。
- Shift+Tab、空间方向、分组 Home/End、快捷键修饰与 repeat 策略、编辑器优先消费已实现。Win32 真实 App.run/PostMessage 队列确认被消费的快捷键不再产生 CHAR，编辑器普通文本与空格只进入一次。
- Windows Debug/ReleaseSafe 和 Linux ReleaseSafe 原生范围控件检查通过；Windows 真实 MTA UIA RangeValue 覆盖动态边界、只读/禁用、移除/关闭、保留 provider 的 QI 身份和引用归零。
- 独立 review 修复步进按钮按下/释放跨区、被 host 消费的 cancel_input 未清理拖动以及数值量化反向。非步点值、小 page、正负与零次相对操作、双端边界均有回归；相对动作不会反向，零次保留有效原值。直接键入数值继续由 T02 完成。

### G01.2 连续渐变与精度边界

- 有界命令缓冲拥有渐变资源，32 项、每项最多 16 stops，Command 保持 32 B；整份 Buffer 可移动/复制，无指向自身的资源指针。记录资源/命令为事务，旧 replay 遇到缺少资源明确失败。
- GDI、D2D 和 Cairo 统一预乘 RGB/alpha 插值、source-over 和 DIP 坐标。Cairo 使用 alpha 与预乘颜色两遍组合；当前窗口 surface 从首帧起是不透明平面，该不变量由实现保持，透明离屏合成仍归 G01.6。
- Windows GDI/硬件 D2D/WARP 与 Linux Cairo 的 ReleaseSafe test、smoke-gradients、smoke-drawing 通过；覆盖 1/1.5/2、clip/椭圆/内描边、首次透明背景、全透明不创建、缓存命中/32 项淘汰、设备丢失/恢复和资源归零。移动 anchor/radius 或改变 DPI 不重建颜色 stop 缓存。
- 实测 D2D 长跨度在极近 stops 附近产生约 8 DIP 过滤区，因此只把连续渐变子项记录为已交付，G01.2 整体保持部分完成。严格 hard stop 与陡变精确回放仍须实现，不能以像素容差或无说明的软件降级绕过。

### 第二批整合

- 冻结源的 Windows test/check 与核心/窗口/键盘/控件/生命周期检查通过；全功能 `-Dwebview=true -Dgpu=true -Daccessibility=true` 的 test/check/smoke-webview 通过，真实 WebView 15 个 App、99 次 pending close 后 adapter COM 计数归零。
- Linux test/check 与隔离 Xvfb/Openbox 的关系/键盘/范围控件检查通过。上述 GPU、GTK、UIA 和 WebView 检查是原生集成证据，不代表人工视觉、屏幕阅读器或所有平台交互验收。
- 各模块交叉 review 已完成，CI 接入新范围/关系/键盘/绘制/渐变检查；远端 workflow 仍未执行。下一批继续推进 W03、S02 和 T01，未实现部分保留在同一计划。

### 第三批边界

- W03.1 装饰/命中/原生拖动缩放与系统菜单；W03.2 透明窗口；W03.3 材质。先验收 W03.1，不把 capability=false 的后两项算作已实现。
- S02.1 显式 worker 的 executable/argv 启动与 Child 回收；S02.2 URL/关联文件/定位；S02.3 回收站；S02.4 文件图标；S02.5 应用发现/启动。子进程与图标先独立验证，不在主线程做可能阻塞的 Shell/磁盘操作。
- T01.1 独立拥有的系统布局、坐标/字素、caret/hit/selection 查询；T01.2 预备布局绘制/缓存与既有编辑器桥接。T01.1 不会让现有 scalar 编辑器自动具备完整 bidi/grapheme 行为。
- B01.1 本地页面导航与页面代数；B01.2 远程/文件来源策略。页面代数与 IPC 随机 session 各自解决寿命和协议隔离，应用在 started 重置 session。

### T01.1 独立系统文本布局

- 可选模块 `ziggurat_text_layout`，见[系统文本布局](text-layout.md)。opaque Engine/Layout、调用者主线程身份、输入快照与显式预算；查询只读已经构造的系统布局缓存，不进行 native 调用或分配，不改变现有编辑器行为。
- Windows DirectWrite/系统 ICU 与 Linux Pango 的 Debug/ReleaseSafe 原生 smoke 通过：组合符、ZWJ/肤色/旗帜、Arabic/Hebrew bidi、Bengali/Thai/Myanmar 多 scalar 选区、软换行/空行/CRLF、双亲和性 caret/hit test、UTF 坐标、事务输出、线程拒绝及逐分配点回滚；Zig 和 native 资源回到基线。
- review 修复 Linux 只取字素首 scalar 的选区遗漏、原生 range API 在缺字体时漏格、纯 RTL terminal caret；现在构造期一次 character-cell 快照覆盖整字素。logical advance cells 不等于 glyph ink bounds，不宣称绘制、Editor 或屏幕阅读器验收。
- Windows 4096 字素长行构造样本约 11.75ms，已观察到 native 位置查询的超线性成本；后续 T01.3 须以批量快照/缓存与量测改善该边界。Linux 同样本约 1.96ms。详细环境限制、内存与复杂度列在模块文档，不能作为跨机器性能保证。

### W03.1 装饰与原生交互

- 创建时选择 system/borderless/custom、resizable 与 DIP 边缘/命中策略；Core 统一线程、模态/禁用/全屏门禁和 callback pin。自定义按钮的内容与辅助语义由应用提供；原生手势只借用当前按下一次，失焦/隐藏/禁用/关闭后不能复活。
- Windows 真实进入系统 move/size/menu 循环，默认处理前结束外层 Zig pin并复核原生身份；循环内已接受任务可以执行关闭、退出与原生销毁，不由框架额外泵消息。隐藏独立 desktop 子进程结束后回收资源，不切换用户桌面。
- Linux 隔离 Xvfb/Openbox 的 1x/2x chrome/关系/键盘检查通过，XTest 独立驱动确认 WM 实际移动和缩放。测试依赖 libXtst，仅为验收使用；框架生产依赖不增加该库。
- 集成 review 发现旧测试假定状态和几何原子更新、2x 桌面过小导致 WM 合法调整位置，以及 XTest 把逻辑坐标当物理坐标。分别改为等待状态与精确 monitor bounds、使用 2560×1600 隔离桌面、明确坐标换算；未为测试修改生产几何语义，临时诊断已移除。
- Wayland 自定义装饰、透明/材质和自定义装饰下多行折叠菜单栏仍未实现。能力与具体边界见[窗口](windows.md)，不能将 W03.1 完成等同于 W03 完成。

### S02.1 启动进程与 S02.4 图标切片

- `system.shell.Worker` 仅在宿主显式创建的后台线程执行，传入主线程身份，公开阻塞成本；不持 App/Window，不创建线程或投递回调。Child 由同一 worker 恰好一次 wait/terminateAndWait，结果投递失败也不转移回收责任。
- Windows 直接 `CreateProcessW` 指定绝对 `.exe`，Linux 绝对路径 argv；Windows Debug/ReleaseSafe 及 Linux ReleaseSafe 的受控 self-helper 验证 Unicode/空参数/引号/空白/反斜杠/字面 Shell 字符/cwd、预取消、错误、跨线程拒绝、终止与重复回收，重复轮次句柄/FD 无增长。
- Windows 只读系统图标查询返回指定背景的 16/32px RGBA，不把原生 icon/bitmap/DC 带到 UI；容量/取消/失败不部分发布像素，12 轮 GDI/句柄保持稳定。系统首次失败调用存在进程全局预热开销，测试与文档明确记录，没有把它误报或掩盖为模块自有泄漏。
- 同步系统调用不能中途强制取消；无 URL/文件关联/定位/回收站/安装应用能力时 capability=false。完整透明/高分辨率图标与非 Windows 图标也继续待实现。

### B01.1 本地页面生命周期

- 入口：`src/webview/root.zig`/`webview2.c`，见[页面导航](pages.md)。显式本地导航、原生历史、刷新/停止、可选 DOM/来源/标题/加载观察；PageId 跨 detach/re-attach 不复活，postFor 拒绝旧代数、加载中和失败页面，应用在 started 重置 IPC session。
- 真实 Runtime 的三轮 controller 生命周期覆盖默认脚本拒绝、显式允许本地脚本导航、宿主导航/前进后退/同址刷新、元数据 OOM 仍发布 started、旧代数及事件内关闭；COM 计数归零。既有 15 App/99 pending close、策略/崩溃恢复和生成客户端 IPC 检查继续通过。
- 独立 review 修复历史授权被别的导航消费、失败加载后向旧文档回复、原生 URI 无界复制。32 项原生回调 ABI 用例覆盖 NavigationKind/redirect/QI 失败与 16384/16385 来源边界；三个生产 pageNotify 单测覆盖失败/不可信来源/代数耗尽与关闭 pin，不需要 Runtime。
- 原生来源与 Zig 元数据分别有长度边界，大 NavigateToString data URI 仅保留实际 about:blank 来源。相同 URI 的旧消息仍需 IPC session 隔离，PageId 不替代协议认证；B01.2 远程/文件资源策略与 B02 页面操作继续待实现。

### 第三批整合验收

- Windows Debug 全功能 `test/check` 与窗口装饰/关系/键盘、范围控件/真实 UIA、文本布局、本地页面/授权、策略恢复和生成客户端 IPC 共 135 个构建步骤通过；158/159 项测试通过，1 项按平台边界跳过。ReleaseSafe 全功能 test/check、基础 native/生命周期/WebView 检查通过，1000 个实际绘制窗口后 GDI 12→12、USER 6→6，记录为零且槽位峰值为 1。
- Windows 原生重入、窗口状态、编辑器与路由、真实 MTA 可访问性回归继续通过。绘制/连续渐变的 GDI、硬件、WARP 与 Cairo 验收证据沿用本批已冻结的对应记录，没有用编译替代运行。
- Linux ReleaseSafe test/check、文本布局/Shell 通过；修正测试后 `scripts/linux-window-state.sh` 在 1x/2x 每次顺序执行 state/relationships/chrome 均通过，XTest 确认真实移动/缩放。2x 的 GTK 生命周期/键盘/基础及范围控件回归通过，原生引用归零。
- 临时诊断已清除；fmt 检查通过，项目文档/源码/测试保持自包含。CI 已接线上述检查及仅用于测试的 libxtst6，尚无远端 workflow 执行证据。
- 完整计划继续实施中：G01.2 的严格硬边/陡变精度、绘制/编辑器桥接、远程/文件页面策略、窗口透明/材质、完整 Shell/平台等任务仍按各自条件验收；上述批次完成不表示完整功能对齐。

### T01.2 准备文本绘制与编辑器桥接

- 独立 `ziggurat_drawing_resources` 只包含有界数据视图与 owner-thread Lease；基础 UI 不因此导入系统文本模块。Frame 首次记录时固定同一 Prepared，最后 GPU/软件回放、失败或关闭后统一 reset 释放，不跨帧保留这份借用；提前关闭明确返回 ResourceInUse。
- 系统 Layout 显式准备有预算的 A8 覆盖，GDI/Cairo 直接复用，D2D 绘制同一个 IDWriteTextLayout。Windows/Linux Debug/ReleaseSafe 实际检查 scale 1/1.5/2、逐软件像素的 RGBA/clip/透明 no-op、硬件与 WARP 的逐行覆盖、半透明 glyph 和设备丢失复用；Zig allocator 与原生 engine/layout/prepared/reference/module 引用回到基线。
- 可选 `ziggurat_shaped_editor` 保留单一 Editor 文档/历史，支持字素删除、双向/软换行视觉导航、虚拟 preedit、候选 caret 和滚动。只准备当前可见覆盖；滚动/DPI 不重新 shaping，事务失败不提交 scroll/reveal，draw/hit/caret 陈旧时返回 LayoutRequired。
- 高文档保留 2000 段原用例，修正 Windows 累加行高的浮点误差及边界归属；小 viewport 成功，全文大 plane 按预算拒绝。原生输入、失败帧、draw 内关闭和 GPU→GDI 后备保持 pin 归零。
- Context.on_input 同时接收正式 resize/scale，显式布局发生在后续 paint 之前。GTK 用 area allocation 与 scale-factor 通知补齐准确内容尺寸，同时保留 configure 的几何观察唤醒；不能由相同绘图区尺寸推断窗口位置或 fullscreen 转换已结束。真实 Windows resize 与 Linux 1x/2x server configure→allocation→prepare→paint 闭环通过，Linux state/relationships/chrome 原矩阵在 1x/2x 均通过。此次修复没有添加轮询、paint 内 shaping、时延补丁或修改几何断言，临时诊断已撤销。
- Windows 原生位置查询的超线性构造成本没有因接入绘制而消失；独立拆为 T01.3 批量位置快照优化，未将 T01 父项标为完成。UIA 可见 glyph、全部语言引擎和成熟输入控件继续属于 T02/T06。

### B01.2 远程页面与文件快照

- 远程 URL 与最多 32 项精确 origin grants 显式配置；导航、拦截的只读请求和双向 IPC 分开授权，凭据 profile 明确接受。CreateUri/IUri 规范化 scheme/host/port；拒绝 URL 凭据、混淆数字地址、保留本地来源、文件/data/blob 和未知来源。重定向必须沿同一正在进行的原生导航并逐跳验证。
- 真实 Runtime 私有 loopback 服务验证不同随机端口、frame、POST 与未知请求拒绝，默认 IPC 拒绝、显式 IPC 往返、重载 PageId 失效；原本地导航/策略/恢复矩阵继续通过，关闭后的适配器 COM=0。原生 callback ABI 另直接验证 URL 边界及一次性授权。
- 文件只接收调用者已打开的 regular file，由显式 worker 有预算地复制为内存站点，不开放目录或 file://。Unicode 文件、资源改盘后快照仍不变、取消、容量、重复路由、逐分配点 OOM 回滚和回调关闭均通过。
- 当前 HTTP 请求只有 GET/HEAD；方法/headers/异步流继续由 B05 实施。Runtime 拦截不是系统网络沙箱，未声称覆盖 DNS/WebSocket/WebRTC 或全部缓存流量，也未把回环 HTTP 检查当成公网 TLS/代理/证书交互验收。详见[页面策略](pages.md)。

### G01.4 图片解码切片

- 可选 `ziggurat_images` 在显式 worker 使用系统 WIC/GdkPixbuf 解码 PNG/JPEG；有界头部预检先于像素分配，核对原生实际尺寸，JPEG 支持全部 EXIF 方向。失败/取消不发布部分 Image，解码结束不保留 native codec 对象。
- Windows Debug/ReleaseSafe、Linux ReleaseSafe 的真实 codec 检查通过，覆盖 alpha、方向、损坏输入、尺寸预算、逐分配 OOM、owner 线程、独占 adopt 与提前释放 pin 拒绝；测试 allocator 无泄漏，adapter native refs=0。
- 该记录描述最初解码切片；后续采样、驻留和更新证据分别记录在下方。容量和像素峰值见[图片](images.md)，完整 G01.4 仍保留未实现格式。

### B02 页面操作

- evaluateJS 使用独立固定 16 个逻辑/原生 pending 槽、单调 token 和 PageId；成功接管一次 completion，提交失败不接管 context。JSON 有显式字节预算与借用寿命，取消/超时/导航/重建/detach各有终结结果，不宣称逻辑取消会中断系统 JavaScript。
- 每 View 仅有一个惰性 waitable timer，通过 App.watchNative 等待最近截止时间，无轮询或嵌套消息泵。提交前准备失败恢复旧等待；已接受后的重新 arm 失败终结旧请求。真实 completion 先释放 native pending，再调用业务回调；最终 COM Release 仍只访问独立 State。
- 独立 review 以 max_pending=1 的真实 Runtime 回归先复现完成回调内提交错误返回 Full，再修正 Invoke 时解除 pending；反复取消未完成请求仍受原生容量限制。补齐完成回调 close/reload 后不再发送旧页面事件与成功结果，fakebackend生产入口与 native ABI 检查通过。
- zoom、User-Agent 与 DevTools 开关按显式主线程属性操作；配置复制、set失败回滚、reload应用新配置、recover保留override均有检查。自动检查不打开工具窗或声称其展示质量。
- Windows Debug/ReleaseSafe 真实 script 检查，以及 ReleaseSafe 的 script/webview/policy/page/remote/authorization/IPC/assets 八项矩阵共42步骤通过。结果/OOM限制、超时、取消、单槽重入、导航/关闭、属性查询及自有 Runtime crash→recover后 adapter COM/allocator/记录均归零。完整test/check在下一次所有并行绘制/文本改动冻结后统一重跑。

### W04.1 运行期窗口快照与查找

- App.listWindows 只访问活动链，以两遍 O(n) 保证容量失败不改输出，无回调、native 调用或分配；findWindow 在同一 App 以槽位/代数 O(1) 查找并排除 closing。ID 不跨 App 生存期、不作为持久文档 ID。
- Windows Debug 和 Linux ReleaseSafe 实际创建/关闭 400 个原生窗口，覆盖 callback pin 中关闭与槽位复用，records=0、槽位峰值=3。单元测试覆盖旧快照边迭代边关闭替换；独立 source review 未发现确认缺陷。显示器与持久状态继续待实现，见[窗口](windows.md)。

### G01.4 静态图片准备、上传与回放

- 可选 `ziggurat_image_drawing` 创建独立不可变 BGRA 预乘/crop/mip 快照，原 decoded Image 可先关闭；UI 只导入绘制 ABI。显式 worker 准备及取消、分配故障不发布部分资源，Frame 临时 pin 与 renderer 跨帧 residency 分别配对。
- GDI 直接采样 CPU 快照；Cairo/D2D 在 paint 外显式上传，固定 32 项 LRU、默认 64 MiB payload 预算，命中回放不重新创建资源。全部候选 mip 成功后才驱逐旧项，原生中途失败保留旧缓存；设备丢失保留有界 CPU 描述，恢复重建单独计数。
- Windows Debug/ReleaseSafe 的 GDI、硬件 D2D、WARP，以及 Linux Debug/ReleaseSafe 的 Cairo 已实际验证 scale 1/1.5/2、nearest/linear/mip、alpha/clip、contain/cover、crop 边缘隔离、预算/LRU/重复上传和 native 引用归零。第 2 mip 故障后旧图仍可画；Context 的失败帧、draw 内关闭和 upload device loss 前先撤销 borrowed wait HANDLE 均通过。
- 独立 review 修复奇数 mip 的浮点终端边界，27×27、31×7、3×27 完整链回归通过；同步保留 codec 首个真实 HRESULT/GError，清理和本地容量失败不伪造错误码。统计明确区分 payload 预留峰值与实际进程内存/显存。
- 同尺寸更新的独立实施记录见下；mip_linear 为最近 mip 内双线性，非 trilinear。色彩管理、HDR 与多帧播放未实现，完整约束见[图片绘制](image-drawing.md)。

### T01.3 Windows 批量位置快照

- 使用真实 cluster advance、完整原生 range island 和精确浮点网格建立候选；每个实际 glyph run 单独校验原点/行框，无法证明的多 UTF-16 cluster、未覆盖 cell 或非精确 island 继续原生查询。没有按 scalar 均分 ligature、估算 advance 或跨 run 复用未经证明的舍入结果。
- cluster/range/cell 临时空间由调用者 allocator 分配，先计入 layout_bytes 峰值预算；所有失败先撤销 native 借用再释放 scratch。BuildStats 分开记录 position/range/cluster/line/draw 查询、bulk/fallback cell 和临时峰值；layoutReference 保留明确较慢的 Windows 原生 oracle。
- 正式差分覆盖双 affinity caret、逐字素/多 island 选区、全部 line、hit test、相同准备覆盖、控制符/CRLF/制表符、复杂脚本/emoji/字体与小数字号、长行及 2001 行文档。另一个 reviewer 在独立 native probe 实跑 3000 组混合文本，九字体、十字号、多 weight/方向/wrap 均与原生 caret/选区一致，未发现确认缺陷。
- 同构建 ReleaseSafe、每组 3 次中位数：ASCII 1024/2048/4096/8192 字素从约 0.92/3.86/11.54/43.48 ms 降至 0.48/0.89/1.75/3.23 ms；8192 字素的原生 position 查询从 16386 降至 2、range 从 8192 降至 2，临时总峰值从 1467173 增至 1794889 B。1025 行和混合脚本仅有有限收益，不能据长行结果宣称全部脚本/段落线性。
- Windows Debug/ReleaseSafe 与 Linux ReleaseSafe 的真实文本 smoke、Windows GPU 与 Linux Xvfb 的 shaped editor/native/text drawing、test/check 均通过。完整输入法语言引擎、reconversion 与屏幕阅读器交互继续由 T02/T06/V03 验收，见[系统文本布局](text-layout.md)。

### B03 Cookie、查找、PNG 与 PDF

- 默认拒绝，各工具单独显式启用。Cookie 枚举要求明确授权的 URI，写入/删除另接受实际 domain/path/secure scope；Cookie 没有端口隔离，不把精确 origin 授权描述为 Cookie host-only 保证。原生 mutation 接受不承诺紧接读取立即可见。
- Profile 清理明确选择整个 Profile；原生 find 单场次/代数/替换重入并抑制默认弹窗。PNG 编码使用固定预算 COM sink，溢出不交付部分文件；PDF 由 Runtime 异步写宿主 worker 准备的私有绝对路径，成功借用返回 pdf_path，UI 不读文件。PDF 输出与编码本身没有硬字节/耗时预算，取消不撤回已经提交的副作用。
- 工具另有 8 个逻辑/原生 pending 槽，与 JS 共用一个惰性 deadline timer；首次完成释放 native 容量后才调业务。独立 review 修复正常 App.quit 时两簿交错清理重挂 timer 而误发 timer_failed：现先统一 snapshot/take，再撤等待并执行回调，终结原因保持 detached，回调新请求不混入旧批次。
- ReleaseSafe 独立单测 15/15；全新缓存/前缀的 script/tools/authorization/webview/policy/page/remote/IPC/assets 九项目标 47/47 构建步骤真实通过。自有隐藏页面的 PNG 签名/IHDR 与私有 Unicode PDF 签名/页结构、Cookie 跨端口/HttpOnly/删除/Profile 数据清理、find 前后跳转、容量/取消/双 deadline 关闭和重复/迟到 COM 均验收，allocator/COM/stream/pending 回到基线。
- 未触发系统打印机、工具窗或用户文件操作，不把格式/生命周期检查写成人工视觉质量证明。系统打印机输出、Linux WebView 和实际平台交互继续待实施或验收，见[页面工具](pages.md)。

### G01.4 同尺寸图片更新与格式扩展

- 显式 dynamic 注册为 Cairo/D2D 提前建立 active/inactive 两套 mip，正常 update 只复制完整新版本，不新建 native bank。GDI 保留固定 CPU 驻留元数据和 1×payload，静态 GDI 路径仍直接读取不可变像素；跨 renderer 的 residency 与本次 Frame pin 分别计数。
- 第二 mip 更新失败不发布已复制的第一 mip；device loss 只恢复最后一次成功提交的完整 CPU 版本。每项只保留最后一个 old→new identity，支持 software 成功而 GPU 失败后的精确 transition 重试，不保存已释放的旧 Lease。
- Windows Debug/ReleaseSafe GDI/硬件 D2D/WARP 与 Linux Debug/ReleaseSafe Cairo 的真实像素检查通过：65 次提交后 native 对象/创建数不增长，双 bank 建立失败、更新失败、设备恢复、跨 renderer 旧 pin、Frame 拒绝、预算/resize/DPI、watch 撤销、Context 部分提交重试和关闭回收均有覆盖。
- BMP 增加已知 DIB/offset/palette/stride/mask 预检与显式 alpha 归一，Windows/Linux 真实 WIC/GdkPixbuf 解码覆盖 RGB/top-down/565/palette/RLE8/V4 alpha/CORE。首帧 GIF 使用固定 4096 项 LZW 字典和单一画布，Windows/Linux Worker 检查覆盖 interlace/local palette/透明/offset、12-bit 字典、deferred clear、KwKwK 和只取首帧。独立 review 未发现确认问题；另外 256 组固定种子 Pillow→RGBA 差分通过，不能由格式数增加推定全项完成。
- WebP 显式 `-Dwebp=true` 才编译固定 1.6.0 decoder 源，fetch 脚本核对官方 tar 的 SHA-256，普通 build 无网络/configure。上游 worker 在编译时关闭，固定 DSP 表一次性发布后允许宿主多个 worker 并发；RIFF/chunk 边界和 features 预检先于单一像素平面分配。Windows/Linux 的有损/无损/alpha oracle、四 worker 同时首次解码、逐前缀截断、动画拒绝、实际 status/取消及全部 Zig allocation 回滚通过。独立 review 修复首次并发系数表初始化遗漏，初始化 OOM 不发布就绪、后续可重试；修复后的两端 Debug/ReleaseSafe 检查通过，完整色彩管理与多帧播放另行保留；许可安装和能力边界见[图片](images.md)。

### U04.1 可变行高虚拟列表

- 可选 `ziggurat_virtual_list` 单向依赖 UI，显式拥有稳定行 ID、高度、排序 ID 索引与 u64 Fenwick 树；业务 scroll/selection 不复制进隐藏状态。高度向上量化为 1/64 DIP，默认十万行、硬上限百万行，构造 O(N log N)，位置/高度更新 O(log N)，回放仅处理可见和有界 overscan。
- replace 的候选预算/重复 ID/OOM 不改变旧状态；render 不使用 List allocator，Busy 拒绝回调内修改/关闭/重入，错误与 clip/offset 不平衡使整帧失败，保留旧输入命中快照。Window callback pin 覆盖最终 Frame 错误访问，防止 on_closed 提前释放状态。
- 独立 review 修复行高缩小时 inset 恰好等于新高度落到下一行，以及 10¹² DIP 总高下微小正 viewport 被浮点加法吞掉。可见末端使用差值和减法残差维持半开边界；正 viewport clamp 明确处理不可表示的 terminal 起点。
- Windows/Linux ReleaseSafe 独立单测 9/9，含 3000 次线性差分、逐分配故障和独立 f128 极值 oracle；Windows Debug/ReleaseSafe hidden native、Linux Xvfb 1x/2x 的真实像素/input/wheel/key、稳定 ID/reveal、容量/失败事务与关闭后 native0 均通过。百万行持有 40,000,160 B，位置查询最多 20 节点；这是观测而非跨机器性能保证。完整列表导航/语义、table/tree/grid 继续由 U04.2–U04.5 实施，见[虚拟列表](virtual-list.md)。

### B05.1 请求策略与拥有型异步响应

- 精确来源的 requests 总开关下，GET/HEAD 默认、POST/PUT/PATCH/DELETE/OPTIONS 逐项授权；固定浏览器头集合之外的每个 header 名称和可选精确 ASCII 值均需显式 grant。名称用 ASCII fold，不依赖进程 locale，不改写网络 body 或 headers。Cookie/Origin 等由 Runtime 管理，拦截仍不等于完整网络 sandbox。
- 响应 status/headers/body 硬预算先验证；HEAD 保留 representation length 而不发 body，204/304 不伪造 Content-Length。最多 8 个 native/logical deferral、1 ms–10 分钟 deadline，共用 JS/tools 的单 timer。原生先挂缓存 403，再移交请求；失败/关闭不依赖分配新的拒绝 body，所有 Complete/Release 恰好一次。
- OwnedResponse 在显式 worker 一次分配复制完整响应，成功 post 后主线程按页代数提交；成功消费，验证/旧 ID/关闭/原生失败保留拥有结果，失败 post 仍由 producer 释放。初始文档 loading 阶段同样可 defer。提交仍有最多 16 MiB native copy，不把整块 buffer 当作真正流或零复制。
- 独立 root 单测 20/20；Windows ReleaseSafe 新请求/异步/授权 ABI 与既有本地/远程/script/tools 矩阵通过。root 全新缓存的 11 目标中，新功能及其余兼容检查均通过；Cookie 工具测试发现旧的“单次 JS 往返等于删除完成”假设，已改测试专用有界事件观察并保留实际删除断言，当前 root 对应 11 项检查分别复验通过。测试还改用每次运行私有 profile 并等待自己的 Runtime 退出后清理；没有由此推断旧 ClearFailed 的根因。B05.2 私有完整文件的按需读取/取消和 B05.3 原生 scheme 注册继续实施；合成 HTTPS 站点不算注册独立 scheme，见[页面](pages.md)。

### T02.1 保留客户端与原生文档上下文

- core 只持有 opaque TextClient 与窗口内单调代数，不拥有第二份文档。所有 read/change/unbound 在主线程 callback pin 内，查询使用调用者存储，UTF-8/全局 UTF-16/方向选择/范围与 revision 再校验。替换、失焦和关闭先撤旧入口，再 native cancel/解绑；显式取消失败仍通知旧 owner、返回错误且不安装新客户端。
- 独立 TextBinding 继续读写同一个 Editor/TextBuffer/undo，以单一 `Changed{context,call}` 明确连接输入阶段的 Adapter.prepare 与候选位置；不等待下一 paint。连续 TextBuffer 的全局 UTF-16 查询仍扫描文档前缀，大文档索引继续由 T03 实施。
- Windows 接通真实 IMM DOCUMENTFEED/RECONVERT/CONFIRM；GTK 接通 surrounding/delete，将 byte cursor/scalar offset 转成全局 UTF-16。活跃虚拟 preedit 的上下文修改明确拒绝，保留组合。CONFIRM 返回 0 只表示宿主不接受调整，IME 可能仍用原 offer；不把这份桥接宣称为完整 TSF 会话或语言引擎隔离。
- 独立 review 修复 set/clear 期间失焦残留影响下一客户端、解绑缺失 Window scope、原生绕过关闭的延迟条件和 callback 结构不一致。最新 core Windows 62/62、Linux 61/61，Binding 30/30；Windows hidden native 和 Linux Xvfb 1x/2x 实际覆盖 UTF 坐标、确认/提交/撤销、候选更新、surrogate/容量、旧代数、native read 回调中直接销毁和资源归零。本批全局 Windows Debug/ReleaseSafe 与 Linux ReleaseSafe test/check、相应 native 检查通过；TSF、marked-document、成熟输入字段和真实语言引擎仍在后续，见[文本上下文](text-input.md)。

### G01.2 严格渐变整合

- 软件采样直接复用已有窗口平面，固定 16 stop scratch；以预乘颜色和右连续 upper bound 处理重复 offset，水平不透明矩形复用完全覆盖行，线性区间可用固定 8-lane 批量采样。Cairo 保留精确物理 clip 栈，flush/dirty 后只写实际交集，没有请求期第二幅渐变位图。
- GPU 每 device 一个自定义 analytic effect，离线 DXBC、固定 624 B 参数；多次 DrawImage 的常量快照由实际 Runtime probe 验证，draw 不编译 shader 或创建 effect。最近可见点作为椭圆展开原点，修复极端纵横比下 quadratic 消减。无法证明精度时显式返回局部错误，同一 Buffer GDI 后备只调用一次业务 draw，后续帧可恢复 GPU；诊断不伪造系统 HRESULT。
- GDI、硬件 D2D、WARP 与 Cairo 的正式 90 组逐像素 hard/steep/预乘/16-stop/clip/DPI 回归通过；另有独立 36 组 tall/wide/outside/tiny/hard/steep/scale probe。设备丢失与关闭引用归零。测试只对真实像素 footprint 横跨 stop 的样本接受两侧颜色凸包，没有扩大整段陡变容差。
- 独立 Linux warm replay，1280×720 DIP、7 样本×3 帧：1x 水平/垂直约 0.032/0.034 ms、对角不透明/alpha 约 0.91/1.12 ms、径向 alpha 约 5.62 ms；2x 径向约 22.14 ms。与同构旧 Cairo probe 相比未见普通渐变回退；该局部回放量测不含显示，也不承诺持续 60 Hz，完整范围见[绘制](drawing.md)。

### 本批全局整合

- Windows Debug 和 ReleaseSafe 各 147/147 构建步骤成功，191/192 测试通过、1 项按平台边界跳过，包含 test/check、真实生命周期、严格渐变、TextClient、虚拟列表、同尺寸图片更新、硬件/WARP 与失败后备。1000 个实际绘制窗口关闭后 records=0、slots=1、GDI 12→12、USER 6→6。
- Linux ReleaseSafe test/check 与文本/图片/更新等共 78/78 步骤、187/187 测试通过；Xvfb 1x/2x 各 21/21 步骤，含真实 GTK 主循环、输入法文档上下文、准备编辑器、严格渐变和虚拟列表，native 引用归零。可选 WebP 的 Windows/Linux Debug/ReleaseSafe Worker 检查另行通过。
- 上述记录是本批冻结源码的整合基线。后续 A8/阴影/路径、有索引文档与文件流新增实施继续各自 review/验收，完整路线图仍为实施中。

### T03.1 索引文档与持久快照

- 独立 `ziggurat_document` 仅依赖 core 的 TextClient 契约，拥有确定平衡的持久 AVL chunk 树；每节点聚合 byte/scalar/UTF-16/LF，叶不拆 scalar。候选根、选择、revision 和历史一次提交，逐分配失败保留旧文档与 redo。公开坐标严格拒绝 surrogate 中间，不隐式规范化 CRLF。
- Snapshot 显式 clone/close，可以晚于 Document 关闭；所有 owner 仍受同一实际线程限制，allocator 活到最后一份快照。live/node/candidate/history/preedit/snapshot 均有明确预算，深度上限 64；同步最终回收按实际不再共享的节点计成本，不把根交换写成整个操作 O(1)。叶可能碎片化，达到预算失败而不偷偷后台压缩。
- TextClient 借用同一 Document，nativeContext 通过索引读取有界片段；原生 read 不分配、不扫描全文前缀。changed 显式通知输入阶段的布局/候选更新，失败保留已提交编辑。关闭尚未到安全点时 unbind 返回 UnbindPending；revision 耗尽仍释放原生绑定 lifetime pin，不因 preedit 取消失败泄漏文档。
- Windows/Linux ReleaseSafe 独立 16/16 单测通过，包含 1600 次 UTF/行/AVL 差分、10 万行尾部访问/复制、全部分配点、快照/历史/owner/版本耗尽。Windows Debug/ReleaseSafe 实际 IMM、Linux Xvfb 1x/2x 实际 surrounding/delete/commit 覆盖百万字节尾部上下文、OOM 重试/undo、陈旧确认、回调关闭与关闭后 Snapshot 读取，allocator/native 引用归零。root 另行源码 review、16/16 单测和 Windows Debug native 复验通过。
- T03.2 可见批次布局与增量段落索引继续实施；这份索引不替代成熟编辑控件，见[索引文档](document.md)。

### B05.2 完整私有文件响应

- 默认 file_streams=null，不创建 Budget、Control、FTM、event 或文件对象。worker 预先 ReOpenFile 为独立 readonly/OVERLAPPED 句柄，验证 regular file/完整大小与元数据预算，保留宿主句柄和 cursor；单文件最多 256 MiB。prepareWithFailure 只在真实原生失败时给出 HRESULT，本地校验/OOM 不伪造代码。
- UI commit 只复制句柄与有界元数据，不打开/读取/stat 文件；同步与 deferred 入口均成功消费 OwnedFileResponse、失败保留。HEAD 保留完整 length 而不创建物理流；204/205/304 body 与 header 规则沿同一验证。初始 loading document 也可异步提交。
- Runtime 持有独立 FTM IStream，在后台最多 64 KiB 一段读取。Read/Seek 序列化位置；UI Read 明确失败、UI Seek 只 try-lock。取消期间保持 OVERLAPPED/event/调用者缓冲，后台确认真实完成后才能退栈；App.quit/deinit 不 join 后台读取。StreamTicket 可在 App/View 关闭后任意线程 clone/cancel/deinit，不持有 IStream 物理槽。
- 每 attached Budget 最多 8 个物理流，进程硬上限 32，只在最终 COM Release 归还；EOF、Complete、取消和导航不提前归还，降额与 recover 不重置绕过。State 只持有固定 Control 引用，导航/关闭先摘旧代数再取消，迟到流不访问 Zig/View/STA 状态。
- 独立生产 ABI 实际验证 32/8 容量、EOF/cancel 保留槽、降额、owner Budget 先释放、MTA 独立 cursor 与最终归零；真实 ReadFile 返回 IO_PENDING 的取消路径确认 drain 完成。真实 Runtime 三 App 场景覆盖默认拒绝、HEAD、同步/deferred 各 4 MiB 完整字节、worker post、失败保留与 completion 内 quit 后的迟到 ticket 释放。root 新版 12 目标整合 62/62 步骤通过，所有 COM/tools/file 引用回到零。
- 此处为提交前已经完整存在的文件，由 Runtime 按需 pull；应用 ACK/边生成边传与真正生产者流背压仍保留为后续切片。文件 sharing 不等于禁止所有既有可写 mapping，宿主仍负责协调私有文件生产。B05.3 原生 custom scheme 正在实施，见[页面](pages.md)。

### 应用 stopping 阶段的页面终结

- 整合复现 App.quit 已撤 native waits、窗口尚 open 时，迟到 tool completion 重新挂计时器，错误把其他簿终结为 timer_failed。确定性回归直接进入真实 View completion 路径，先复现 script=timer_failed/tool=cookies/resource=timer_failed。
- 统一将 App stopping/stopped 纳入提交与完成门禁；新业务/cancel 返回 Closed 并保留拥有输入，迟到完成/page/timeout/process 不抢先修改旧簿，由 detach 恰好一次交付 detached。恢复期间的 pending/current config 仍保留到原定清理点，没有因抑制业务通知提前释放页面 body。
- View 22/22 单测、focused 五目标及新版工具连续 20 次 Runtime 检查通过；root 独立完整 12 目标 62/62 步骤通过，PNG/PDF/Cookie 与终结原因断言全部保留。该确认缺陷与修复有生产入口证据，不将之前未再复现的 ClearFailed 推定为相同根因。

### G01.3/G01.5 共享 A8、圆角阴影与路径

- 独立 CoverageView 与 Lease/非零单调 identity，Frame 32 项固定借用；图片/A8 共用 32 个 native 槽、一个 LRU 和总预算，候选先完整建立再淘汰旧资源。GPU 保存原始 inline descriptor，上传/恢复增加透明 halo，修复非零边缘在分数像素位置的硬边；实际 bitmap charge 与 native scratch 峰值分别记录。
- 圆角阴影显式准备 separable truncated Gaussian，内/外阴影、spread/offset/scale、bytes/work/cancel 均有界。内阴影只计算原轮廓的有限滤波邻域，offset±10⁶ 不扩大工作面；独立二维卷积 oracle、失败回滚和 worker 交接通过。透明离屏与组 opacity/mask 仍在 G01.6 实施。
- Path 拥有命令/严格 d 属性解析、Bézier/解析 ellipse 自适应细分、fill rule/完整仿射/居中描边；新增 dashes/负 offset/零长度点/逐子路径相位与 trim，闭合接缝使用 join。长度沿本地展开折线度量，不宣称解析弧长。独立 edge_attempts/stroke_steps/scan_tests 阻止退化变换、密集虚线绕过生成工作预算；准备阶段不创建临时碎片数组。
- Windows Debug 与 Linux ReleaseSafe 各 18/18 路径测试通过，含手工分段像素 oracle、4000 次固定种子解析变异、随机 winding 差分、逐分配故障。root 独立 Windows ReleaseSafe A8/旧静态图片/连续65次图片更新共17/17步骤通过，GDI/硬件/WARP资源归零；作者 Windows Debug/ReleaseSafe 和 Linux Debug/ReleaseSafe 原生回放复验通过。新增 dashes 原生组合回放将另行记录，不由纯测试推定。
- root 重测 256×128 DIP 圆角阴影，prepare 的 9 样本中位数：σ=0/4/12，Windows 1x 约0.71/2.20/7.10ms、2x约2.72/13.96/54.74ms；Linux 1x约0.40/1.79/6.56ms、2x约1.41/12.27/53.17ms。GPU warm replay只是 CPU 记录，end只是CPU提交，未等待GPU或显示；所有样本正常回放原生创建数不增长。详见[阴影](shadows.md)与[路径](vector.md)。
- G01.5 还需完整 SVG 形状、groups/use/symbol、paint/styles、clip/mask 和外部资源策略；没有将路径数据解析当作 SVG 文档已完成。

### B05.3 原生页面 scheme 注册

- Options.custom_schemes 最多 4 项，复制/规范化/排序名称与每项最多 8 个精确 request_origins；独立 COM EnvironmentOptions4/Registration 持有 UTF-16 metadata，Get* 用 CoTaskMemAlloc 返回独立数据/引用。默认空集不创建这些原生对象，迟到 Release 不借用 Zig/View；名称和保留协议、字符串/数量/OOM 均有界。
- LocalSite.scheme 选择真实 scheme://host/path，只支持 authority=true；treat_as_secure 与 scheme_ipc 均显式开启，默认拒绝 custom 双向 IPC。Origin 前置过滤与 Runtime CORS 名单共用具名 request_origins：缺 Origin 的 GET/HEAD 不证明发起者，写方法缺 Origin/重复/null/非精确值在 Zig handler 前复用缓存 403。方法/头、远程 HTTP(S)、Cookie 和页面代数仍有独立门禁。
- custom origin 只含 scheme+host。配置拒绝端口/userinfo，原生事件仍可见的非法 authority 也拒绝；本机 Runtime 实际会在事件前移除这两类字段，测试按相同 origin 的规范化别名验收，不声称端口/用户信息隔离。未注册 OS 协议、开放 file 目录或引入网络服务；opaque scheme 与跨平台仍未实现。
- 同一 View reload 的注册集不可变，变化同步返回 SchemeEnvironmentChange，即使 profile 路径不同也不排队；recover 复用拥有配置。同 profile 的不兼容另一个 View 在真实 Runtime 返回 0x8007139f，不隐式改策略、重试或 UI 等待。
- 独立 ReleaseSafe 生产 View 单测 27/27，含 metadata/OOM、事务拒绝与既有三簿 shutdown/reentry；扩展 ABI 覆盖 COM identity、options 先释放后的 registration/字符串独立寿命、原生非法 authority/Origin/默认 Cookie/IPC 拒绝。真实 smoke-scheme 两组 secure=true+同源名单、secure=false+空名单均通过，每组 3 代文档、3 次 worker deferred completion、4 条显式 IPC、POST/CORS/头拒绝、私有 profile mismatch 与崩溃恢复；关闭后 records/COM=0。
- 作者全新 cache/prefix 的 13 目标 Runtime/ABI 矩阵 67/67 步骤通过，包含旧 15 App/99 pending close、JS、Cookie/PNG/PDF、IPC/assets、remote、method/header、async/file。最终纯 metadata IPv6 URL 序列化修正后，作者新 cache scheme/auth 11/11 通过；root 独立源码 review 无新增确认缺陷，并独立 ReleaseSafe scheme/auth/file 16/16 通过，含真实 IO_PENDING 完成 drain。验证不触公网、用户文件或系统工具窗；完整边界见[页面](pages.md)。
### T03.2 同一索引文档的可见编辑桥

- 新可选 `ziggurat_document_editor` 借用同一 Document/Engine，拥有段落元数据、可见 Layout/Prepared 和有限元数据历史；不镜像第二份文本或 undo。派生候选先于 Document 编辑构造；编辑已提交后的 shaping OOM 返回 LayoutRequired，禁止重发同一输入。
- 段落索引改为每叶至多32行的持久AVL。100001段在本机ReleaseSafe约7.06MB、8191nodes、1.23万次构造分配；首部编辑约91visited/32scanned/12reclaimed/31alloc。保留estimated高度与准确高度的区别，使用u128的2^-32 DIP整数差得到局部f64位置；draw不分配或shaping。
- 独立review实证复现80LF preedit滚到尾部后缩为单段造成旧anchor越界。统一反向overlay→committed和正向新edit mapping，update/commit/cancel/unbind共用；新回归先RED再GREEN，不用单点夹紧隐藏状态错误。另修独立batch虚拟upstream的hit tie、测量后垂直reveal与未换行长行水平reveal。
- 作者Windows ReleaseSafe、Linux ReleaseSafe的6/6纯索引测试和Windows实际IMM/Linux Xvfb1x/2x原生smoke通过；root独立Windows Debug9/9步骤、6/6测试与真实绘制通过，资源归零。完整Layout oracle对复杂脚本/CRLF/emoji/bidi/wrap的双affinity caret、hit、selection保持严格差分；包括多个allocator故障、undo metadata miss已提交后reindex OOM、Frame pins和关闭活跃组合。
- T03.3多选区、流式查找替换与折叠继续实施，成熟clipboard/滚动条/辅助文本语义另行验收；见[大文档编辑桥](document-editor.md)。

### G01.5 SVG 文档首个绘制切片

- `ziggurat_svg` 独立拥有有界XML树，显式prepare为单层预乘BGRA ImageView；基础形状、Path、局部仿射、viewBox对齐、颜色/currentColor、inline style/继承、dashes和真正组opacity已接通。worker独占准备、主线程adopt，源Document可先关闭；普通回放沿既有图片驻留缓存，未在draw解析或分配。
- XML拒绝DTD、外部实体和其他processing instruction，引用只保留明确内部边界；当前不支持的元素/绘制属性返回错误。准备时byte/layer/pixel_work和geometry/scan预算累计于整个场景，不能靠多个元素重新领取完整生成限额。样式表、use/symbol、渐变、clip/mask和完整viewport语义继续实施，G01.5仍进行中。
- Windows Debug与ReleaseSafe、Linux ReleaseSafe各9/9纯测试通过（XML/实体/数值/变换/颜色、独立形状路径像素、整组透明度重叠、全分配故障/预算）。Windows GDI/硬件/WARP和Linux Cairo的实际smoke通过1/1.5/2倍DPI、整图像素、clip、worker owner交接、Frame/驻留提前释放拒绝、warm native创建数不增长及引用归零；没有据此宣称完整SVG或视觉质量验收。

### B04.1 有界下载与临时权限

- Windows权限默认拒绝，显式exact origin/kind/gesture门禁与当前committed PageId共同校验；允许/拒绝都禁止写入profile。defer使用同一截止唤醒，不等待UI，导航/恢复/关闭先移出请求再完成回调。Runtime可能缓存内存决策，不把ephemeral描述为每次调用都重新询问，也不把宿主决策当作OS权限。
- 下载默认取消，显式目标HTTP(S)来源、并发/已知大小/接收软上限。目标由worker在宿主私有目录准备，UI accept成功后才转移所有权；native同步事件先静默，owner接管后activate。view寿命的下载可跨普通导航；reload/recover/detach取消，取消不删除部分文件。暂停/恢复的返回只表示原生请求被接受，状态变化由原生事件确认。它不新增网络/导航授权，不提供原子无覆盖或硬磁盘配额。
- 原生COM/actions预算跨recover保持到末个handler Release，五类请求统一先snapshot/take/cancel再回调；活跃下载没有进度轮询定时器。ABI注入覆盖GetDeferral/Complete/接受失败、同步完成、迟到重复handler、getter中重入取消和跨State物理预算。
- 作者ReleaseSafe39/39纯测试及6目标31/31步骤通过；root独立ReleaseSafe权限/下载/授权16/16步骤通过。真实Runtime覆盖7 offers/7 terminals、三份256KiB逐字节worker验证、跨导航、超时/取消/软上限、暂停事件后snapshot/resume与quit；权限允许/拒绝/gesture/过期PageId/四簿退出均验证，COM/actions/records归零。持久规则B04.2继续实施，B04父项仅部分完成。

### G01.6 三后端透明分组与帧提交

- Context显式预留front/work/最大4层group和可选GDI灰度文字scratch；先检查软件+GPU总预算，两套候选全部成功才提交。默认未启用时不分配；DPI/尺寸变化要求显式重备。RGBA primitive、图片、A8、prepared text与legacy label均保留alpha，重叠子项完成后统一乘opacity/mask/父clip一次。
- 预检/回放/end/PresentationBusy失败保留旧front、命中、焦点和已发布语义；软件后备成功后才隐藏旧GPU child并提交。review补齐了提前提交input/semantic、双端失败隐藏旧GPU图层和group内widget漏祖先clip三个边界，各有真实Context回归。
- Windows Debug/ReleaseSafe及Linux Debug/ReleaseSafe相关原生矩阵通过，Linux另有Xvfb 2x检查；root独立Windows ReleaseSafe GPU/UIA六目标32/32步骤通过，GDI预热句柄18恒定、owned text refs与GPU对象归零。独立35/35单测包含20k整数预乘oracle和6fraction×3DPI row-fill像素对照。固定工具链的Linux Debug optional-error比较问题有最小复现与等价unwrap避让，见[工具链说明](toolchain-known-issues.md)，不降低错误身份检查。
- 正式性能在其他agent暂停编译/原生/测量期间顺序运行，Windows5/5、Linux4/4步骤，24行数据见[layers-performance.json](layers-performance.json)。1280×720 DIP的nested GDI回放1x约9.101ms/2x38.075ms，Cairo约0.996/3.862ms；GPU值只记CPU录制/end提交，不包含GPU执行或显示。GDI opaque整行填充与整数预乘路径替代不必要的逐像素f64工作，仍保留fractional coverage；不承诺2x60Hz。独立离屏拥有型资源导出不在本项冒充完成，见[分组工作面](layers.md)。

### G01.5 样式、内部引用与渐变切片

- 增加CSS compound/type/id/class与重要性/特异性/顺序级联，内部use/symbol、嵌套viewport与显式overflow，以及有模板的linear/radial渐变、解析几何object bbox、stop/currentColor/straight alpha/linearRGB与spread。非法语法/外部URL、循环和不支持的径向几何明确失败；clip/mask继续实施。
- vector共用arc转换计算解析bounds；可选retain_samples持有同4×4格点u16，额外2B/aligned pixel计入拥有/峰值，供几何union/intersection，不用重复alpha混合作为区域布尔操作。默认路径不开启。
- Windows Debug当前vector22/SVG20共42/42；Windows ReleaseSafe和Linux ReleaseSafe此前vector22/SVG19共41/41与真实SVG回放通过。原生fixture已含CSS/use/symbol/渐变，三DPI、完整像素、worker交接、Frame/驻留pin与native创建稳定；最新累计parse_work及URL token重要性回归继续纳入本轮复核，未将历史矩阵当作全部新代码已验收。
- 独立review指出引用可反复解析长空白transform绕过节点/几何预算，现新增整个scene的parse_work（默认4MiB/hard64MiB），render实例与渐变模板/祖先处理前计attribute字节。64KiB空白transform/d/points×128回归：低限额明确拒绝，高限额成功且统计>8MB；17×13 viewport回归另覆盖A8 stride padding。

### B04.2 宿主持久页面策略

- 可选 policy_store 拥有按 canonical HTTP(S) origin、权限种类/下载区分的排序规则；namespace/epoch、TTL、版本及不可回绕的进程身份共同限制复用。lookup 为 O(log N)，默认256条/128KiB、硬上限1024条/1MiB。拥有型 DecisionLease 在原生提交前重新验证，撤销使旧 lease 失效；不持久化 COM、PageId 或可重复使用的文件路径授权。
- 规则快照在 owner 编码，显式 worker 执行同目录独占临时文件写入、flush、关闭和 rename；失败保留旧文件，清理失败报告临时文件名。加载使用未采用的独立候选，通过 App.post 在主线程采用；无自动线程、自动保存或热加载。CRC 只检测损坏，不提供认证，也不宣称目录 fsync。
- 下载约束的 intersect 只返回约束数据。宿主在 accept 前检查已知大小/未知大小策略，并按规则的 received 软上限消费进度和取消，或创建更窄的 View 策略；终结还需核对结果。撤销不撤销 Runtime 会话缓存、既有 OS 授权或自动取消现有下载，取消不保证硬磁盘配额。
- 作者 Windows/Linux 独立规则测试各17/17、Windows C+Zig生产模块46/46通过。root独立 ReleaseSafe smoke-browser-policy 8/8步骤通过：6次worker保存/加载/post/adopt、权限允许及撤销、64KiB文件逐字节验证、旧lease提交前拒绝且目标不存在；View原生上限65536字节时，规则上限1字节在32768字节的真实进度回调触发取消。COM/actions/records归零；测试已加入显式WebView CI，远端workflow尚未执行。

### T03.3 原子多选、快照搜索与派生折叠

- Document拥有唯一文本与undo；规范化多选区和版本化replaceMany在一个候选里发布，一次输入/IME提交和多caret删除均只创建一个revision/undo。Snapshot预先保留Reader槽，worker只读持久树，释放后显式post给owner做版本校验与原子替换；KMP支持预算step/取消，不flatten整份文档。
- Adapter真实绘制多个caret/selection，保留各自视觉affinity/preferred X，按原生布局处理bidi/CRLF/跨batch边界。完整段落折叠的稳定ID、嵌套/交叉校验与collapsed状态独立于文本；持久AVL采用lazy visibility，隐藏大范围无需逐行扫描或shaping。toggle只应用有效区间对称差；文本edit额外映射F个定义并重新应用，成本包含F log F + F log P，不将其冒称纯O(log P)。
- caret隐藏被明确拒绝；reveal在候选中展开全部祖先，OOM保留旧可见状态。已知edit映射范围、undo/redo按ID保留当前collapse状态；未知外部delta要求显式重索引/重新提供folds。元数据恢复失败不撤销已经成功的Document undo。
- 作者Document30/30与Adapter12/12，Windows/Linux Debug/ReleaseSafe原生矩阵及Linux1x/2x通过。root独立Document30/30；ReleaseSafe core/Adapter80/80与两项真实document smoke共17/17步骤通过，10万段落的前缀edit只访问91节点/扫描32行，真实Frame、IME、多选、隐藏末尾导航、undo/OOM和关闭资源归零。该时长与构造统计来自本机检查，正式性能基线另按V02采集。

### G01.5 采样裁剪、蒙版与双圆径向切片

- clipPath使用4×4位集合求并/交，包含viewport/对象几何边界/use/evenodd；mask拥有透明BGRA候选和独立region/content坐标，按computed color-interpolation计算sRGB或linearRGB luminance/alpha。整场sample_work与既有bytes/parse/style/node/geometry/pixel配额共同约束准备，无paint解析或隐式worker。
- 径向按SVG2双圆圆锥求解非负半径的最大参数，覆盖外焦点/相交/缩小/等半径等几何；点相切奇点有明确pad/周期平均处理。独立review修复根transform/viewBox顺序、寻找stop漏计node访问，以及非零linear端点差平方下溢误判常量。
- 作者Windows/Linux Debug/ReleaseSafe各vector22/SVG34共56/56与原生回放通过；root独立ReleaseSafe Windows12/12、Linux11/11步骤，均56/56加真实SVG。Windows GDI/hardware/WARP三DPI整图、source关闭后worker快照交接、Frame/驻留pin与设备恢复均通过。
- G01.5仍在实施：每paint独立AA保留组分数边缘192/全sample颜色128的明确差别；text clip、mask定义自身mask、非零焦点圆A=0相切等仍待后续实现。规范要求clipPath的use直接引用shape/text，use链和g/symbol并非待补标准能力；mask定义自身transform也不属于标准transformable元素能力。完整范围和错误见[SVG文档](svg.md)，不以新切片代替完整SVG完成。

### H01.1 组合区域与原生内容适配

- 核心 Owner 是唯一 Window.Content，预分配16个区域槽（硬上限256），Region 使用非回绕代数；移除立即撤入口，Region/Window 双 scope 退栈才 detach。provider 准备候选并回滚，成功后发布几何；native 区域逆序释放，backdrop 最后释放。默认事件和槽复用不分配，不按历史次数扫描。
- 输入覆盖逆序命中、捕获、隐藏/零面积撤销、失败几何保留和焦点回调重入。UI 首片为显式 GDI/Cairo 全窗背景；WebView 使用真实 native child、DIP 边缘统一舍入、bounds/visibility 原生回滚和父位置通知。独立 review 修复 stale backdrop 捕获、隐藏后激活、焦点回调关闭、旧结果转换中失效和 allocator 二次 attach。
- Windows/Linux 核心1000次槽复用及持 pin 原生关闭通过；UI 原生像素/资源/输入、Windows UIA 失效与 Linux 1x/2x 通过。WebView 作者 ReleaseSafe 54项纯回归、另9个Runtime目标47/47步骤，覆盖真实 GDI+双页面、DOM 独立/隐藏保持、reload/pending 复用、回调 remove、旧 responder/拥有参数拒绝与全部 COM/背景资源归零。新检查已接入显式 WebView CI；远端尚未运行。
- H01.2 继续实现页面独立所有权、跨宿主 DOM 保留及 App 停止参与者。H02 任意 clip/overlay、GPU airspace 与 H03 原生混合焦点/Tab/IME/可访问树仍保留；矩形区域首片不替代这些能力。

### H01.2 应用资源与早期原生撤离基础

- App使用资源自带稳定节点，register/cancel零分配O(1)，seal立即撤入口；已接受post全部执行后整批take、逆序stop，再进入普通窗口和Cleanup关闭。错误继续终结其他节点、保留失败存储/backend，由finishShutdown显式重试，不重放post/逻辑完成。普通App callback与teardown scope分离新业务入口和关闭期寿命，均不创建WindowRecord；节点不隐式keepalive。
- Content/Participant的早期native_parent_destroying在Windows父WM_DESTROY同步撤离子树，包含provisional attach和removing provider；该通知只做有界native工作，不触发COM/业务/普通detach。attach失败自行回滚，成功才转移detach责任。独立review无新增确认问题。
- root Windows Debug/ReleaseSafe核心各89/89及smoke-app-stop各8/8步骤；Linux ReleaseSafe核心88/88及原生7/7，另此前Linux Debug/ReleaseSafe 2x组合/UI矩阵各16/16。Windows七个相关原生目标39/39步骤，包括1000次绘制窗口、任务配额/公平性、GDI/UIA组合与真实双WebView、15Apps/99次pending关闭，资源归零。新零窗口run/self-free、满256项post先于stop、native失败重试和on_closed立即释放Owner有专门回归；原生child保存不等于浏览器DOM保存。

### G01.5 拥有型几何与逐行缓存

- vector公开可选geometry namespace，编译后拥有边与物理bounds，源Path可先关闭；旧A8与新Geometry共享唯一flatten/stroke/arc内核，旧prepare未分配Rows或新增缓存。Rows按所有几何体Σedges一次准备四子行crossing scratch并显式pin Geometry，横向条带二分prefix winding，query零分配；不作为跨线程共享句柄。
- scan、sort comparison、sample写入分别累计，整组scratch/元数据精确计入bytes；取消或预算失败不发布新Row/输出，Row只借同entry下一次prepare前的缓存。作者四环境窄验与默认图接线通过，root独立ReleaseSafe vector31/SVG36共67/67。
- SVG严格拒绝clipPath的间接use及g/symbol目标；变量alpha的点相切周期平均返回UnsupportedRadialAverage，保留pad/非相切/常量alpha。后续compiled scene与f64逐sample颜色条带仍在实施，尚未替换默认SVG每paint A8合成语义。

### G01.5 可选逐采样颜色场景

- 显式PrepareOptions.compositing=.sample_color先编译有界postorder场景，再以32×1条带、每pixel16份f64预乘颜色合成。组clip/opacity在全部子项后作用一次；引用、CSS、transform和渐变在准备阶段解析，Raster不持源字符串、不在draw解析。默认pixel模式与旧像素结果保持兼容。
- Builder的稳定预算allocator覆盖全部旧/新capacity、Path/Geometry scratch、Σedges Rows、条带/元数据和输出像素的同时存活；候选成功才把拥有像素/Prepared交给原allocator。color/scene/sort/sample/pixel分别累计，所有work和取消错误不发布部分Prepared。Clip DAG按条带epoch懒缓存，未访问clip不每帧清空，重复子图只计算一次。
- 组半像素边缘的明确oracle为新模式alpha128、默认alpha192；曲线/arc/evenodd与独立A8覆盖逐像素差分。gradient仍只在pixel center求色后广播16份，mask仍先resolve/量化到连续BGRA8再求factor；不把它们宣称为16份渐变积分或mask颜色场。text clip、mask定义自身mask及非零焦点圆A=0继续实施。
- 作者Windows/Linux Debug/ReleaseSafe各vector31+SVG63共94/94与双模式原生检查通过；root独立Windows ReleaseSafe12/12步骤、Linux ReleaseSafe11/11步骤，均94/94加双模式实际回放，覆盖GDI/hardware/WARP三DPI全图、Cairo、worker源先关闭、Frame/驻留pin、设备恢复与引用归零。root编译链/预算/寿命review无新增确认项。完整G01.5继续实施，详见[SVG](svg.md)。

### T04.1 同一文档的代码服务与可见浮层

- 可选Broker拥有固定请求槽，worker只借Snapshot Reader并创建有界OwnedResult；Reader release之后仍由owner显式finish交付责任。取消/stop不提前回收物理槽，post拒绝不接管结果。原文、选择与undo只有一份Document，附加补全编辑一次原子提交。
- completion绑定完整revision与位置；诊断/hover使用独立committedTextVersion，纯选择不丢结果，IME暂时隐藏。Adapter成功prepare后按可见几何生成projectionVersion，Presenter纯选择复用下划线与浮层；完整revision仍限制输入和draw。默认绘制只回放Prepared和矩形，没有分析器、服务进程或隐藏worker。
- 作者Windows/Linux ReleaseSafe各56/56纯测试及真实native通过，Windows另有Debug原生检查；root独立Windows ReleaseSafe同矩阵15/15步骤、56/56纯测试及实际worker→post、原生键盘/指针、glyph/诊断/popup像素、原子undo、IME、OOM/失败帧、raw/native关闭重入，资源归零。新检查已加入Windows/Linux原生CI配置，远端未运行。
- 本机窄测4096-byte单段、64次选择/prepare，1/256条诊断均无新增shaping；优化前256条median约1.87ms，几何缓存后约0.5µs。它只测CPU更新，存在其他构建负载，不是V02正式显示基线；工具入口benchmark-code-editor。T04.2行差异模型及可见Diff、snippet与语言协议继续实施，见[代码服务](code-editor.md)。
- root独立Linux ReleaseSafe 2x读回最初暴露fixture将物理坐标再次按DIP缩放；改用既有raw pixel读取后保持原色值/几何断言，重新8/8步骤及实际glyph/诊断/popup检查通过，资源归零。生产绘制没有为测试放宽行为。

### T04.2 快照行差异模型（实施中）

- 新可选document_diff只借两份Reader，拥有行索引、最远前沿/三角追踪及Hunk元数据；不保全文、修改文档或启动线程。成功保证精确行相等与最短整行插入/删除，所有预算和取消失败不发布部分结果。宿主负责Document身份/请求代数与版本交接，模型不把相同版本号当成相同文档。
- root Windows Debug/ReleaseSafe与Linux Debug各10/10，包括961组二元序列的独立DP距离及完整重建oracle、真实末尾换行/CRLF/Unicode、强制hash碰撞、不同树叶切分、所有分配失败、预算边界和worker期间owner编辑。独立review和可见桥仍在推进，不能据此标为完整Diff控件；见[快照差异](document-diff.md)。
- 独立review额外3000组随机oracle未发现算法问题，并确认allocator.free重入会重复释放Result；已改为先撤销拥有存储再free，正式回归覆盖。正式图再加入512组混合Unicode/CRLF/NUL随机oracle，现Windows Debug/ReleaseSafe及Linux ReleaseSafe各12/12。可见桥继续实施。

### H01.2 独立页面会话与停机整合

- PageSession拥有唯一View、固定bridge和隐藏parking，普通页面回调固定App/Session，provider操作另固定Region；park/remove/正常或raw父关闭保留同一controller、DOM、PageId和五簿，旧provider detach后才能重挂。旧View路径不创建新host或停止节点。初始尺寸为显式物理像素，停放不隐式keepalive。
- 独立review确认park的原生重入可先remove旧Region，外层缺少Region pin导致状态复活或借用已释放Owner；已加区域scope及foreign后检查并正式回归。root另确认移动bridge需SDK父位置通知，普通mount/park/rollback统一viewport后Notify，并跨两次COM独立pin State；早期WM_DESTROY仍仅Win32，不在其中终结业务或调用COM。
- native构造/每次calloc/HWND/close失败保留清理责任，真实OS静默尺寸截断按几何不符回滚；App停止先排空accepted post，再关闭页面物理资源，普通Window/provider detach最后完成。成功open最终on_closed可立即free整个Session；失败open不通知，native失败可显式close/finishShutdown重试，逻辑完成不重复。
- 作者ReleaseSafe62/62、11个既有Runtime/ABI目标55/55，以及最终SDK通知切片15/15通过；root独立test-webview加5个原生目标28/28、62/62，覆盖真实4App的初始停放/跨宿主/raw销毁/立即free、parked及mounted三deadline、accepted停止任务destroy、allocation关闭重入，另有双页面组合与旧15Apps/99pending关闭。COM、host/parking/bridge、watch/stop/Window记录归零；CI已接两新target，远端未执行。H02/H03与Linux/macOS WebView仍按原任务实施，见[页面会话](pages.md#离窗页面会话)。

### G01.5 mask定义自身mask

- 两种compositing均支持mask定义自己的computed mask引用，nested target使用当前mask内容坐标及其子几何bbox；pixel模式就地乘nested连续factor，sample_color复用postorder隔离group，不把mask内容source-over进自身。每层按自己的alpha/luminance和sRGB/linearRGB解析，定义自身opacity/display仍不创建图形组。
- 共享active stack/reference_depth拒直接/间接/跨use循环，所有nested planes、几何和parse/style/node/pixel/color/sample工作纳入原总预算。覆盖手算64/32/14、CSS三级128→64→32、object/user坐标与显式g mask三DPI等价、所有分配失败及每个分配点触发取消后live归零。clipPath自身mask及非零焦点圆A=0继续保留明确错误。
- 作者四个Windows/Linux Debug/ReleaseSafe配置均vector31+SVG69共100/100；root独立Windows ReleaseSafe12/12步骤、Linux ReleaseSafe11/11步骤，均100/100及两mode×原scene/own-mask的实际原生回放，GDI/hardware/WARP/Cairo三DPI、worker源先close、pin/设备恢复/native稳态和引用归零。独立窄source review无新增确认项；G01.5仍在实施。

### 本轮整图检查

- Windows ReleaseSafe的test/check启用WebView、GPU与UIA：200/200构建步骤通过，470项测试通过、1项按平台条件跳过；Linux ReleaseSafe91/91步骤、399/399测试通过。这轮包含H01.2、T04.1、拥有型Diff模型及尚未导出可见View的纯请求/行索引、SVG逐采样与own-mask。普通目标后端和所有选中原生检查均实际编译。
- 上述整图编译不替代各节独立原生运行，也不包含后续新接入的Diff View、producer背压或新的径向分类修复；这些切片完成后继续窄验并重新整合。已通过全仓zig fmt与CI YAML解析；尚未执行远端workflow。

### B05.4 有界字节生产者与页面消费（实施中）

- Control只拥有固定SPSC slabs、原子取消及worker等待序号，不保存App/View/COM；发送成功仍占用槽，只有有效累计ACK归还额度。Writer/Delivery有显式take，物理控制块覆盖它们的最终release；UI不等待worker，不启动隐式线程或定时轮询。
- 元数据占wire sequence 1，body sequence N映射为wire N+1。元数据ACK不释放body slab，零body/HEAD也必须等元数据ACK才能终结；发送回调中的提前ACK延后至transport成功和Delivery.commit，失败保留同一packet，关闭不能复活旧credit。
- 页面客户端使用highWaterMark=0的ReadableStream、一次元数据读取与单一body pull；base64输出有界、规范padding，核对头部/总字节/块数/结束摘要。独立review确认暂停消费时transport失败未终结本地completion，现已连接异步终结；正式回归无需再次pull即可拒绝completion和body。
- root独立ReleaseSafe纯层9/9、Bun客户端7/7及70项断言、strict ES2022/DOM TypeScript检查通过。绑定View/PageId、App停止、发送重入、页面导航/停放和真实Runtime交接继续实施；这些纯层结果不代表B05.4完整验收。
- 纯模块ziggurat_resource_stream现包含wire元数据/base64与独立预算账户，已接默认test/check和test-resource-stream；root Windows/Linux ReleaseSafe各13/13。View新增显式零分配PageCallbackScope固定旧attachment/session的物理寿命，返回外部allocator/transport后仍必须重验PageId；root独立WebView63/63通过，原生Bridge继续单独验收。
- 可选ziggurat_webview_producer使用现有来源授权和PageCallbackScope；共享Bridge本身不导入WebView，已接默认test/check及独立test-resource-producer。root Windows/Linux ReleaseSafe各10/10，覆盖producer物理责任、显式wake投递、发送/分配器重入、终结回复预算不足时保留同一packet重试，以及有界队列公平性。取消排队拒绝的回收和真实Runtime闭环继续核验，不据此提前完成B05.4。
- 取消排队的物理容量拒绝现按完整token先撤入口再释放Parsed，不会在后续drain反复编码已取消请求或触及替代slot。root Windows/Linux ReleaseSafe标准ipc-client生成、Bridge11项与生成fixture一致性1项均通过（各9/9步骤、12/12测试）。真实页面交接另行独立验证。
- B05.4应用流首片现已验收：root独立Windows ReleaseSafe50/50步骤、118/118纯测试及producer/旧IPC/PageSession/WebView/窗口生命周期实际通过，Linux ReleaseSafe11/11步骤、55/55纯测试通过。真实三个App验证暂停body阻塞生产者、有效ACK恢复、重复/旧ACK、zero/HEAD、取消等待worker物理释放、park/remount继续、导航fresh session、终结转换预算不足后同包重试、stopping accepted post，以及View UTF16 allocator关闭Session后外层scope退栈才on_closed立即free。最终streams/tasks/COM/host/Window记录归零；旧15App/99pending关闭和1000绘制窗口兼容通过。对应目标已接CI配置，远端未执行；原生fetch producer与opaque scheme仍未提供。见[应用字节流](resource-stream.md)。

- Windows 已知长原生 producer 现通过独立 HTTPS worker、公开 Source/Transport/Site/View 交接；两优化各23项 TCP/TLS 与10个公开进程模式通过，构造重入、精确长度、HEAD0、文件206/416、背压撤销、Stop/迟到引用及最后资源归零。真实浏览器使用隔离固定 leaf 测试例外，不能据此宣称生产自签名 loopback 信任已提供；后续需 Profile/session 级一致 pin，B05 保持部分完成。见[显式 HTTPS](https-owned-transport.md)。

### G01.5 径向分类与恒色周期透明度

- 独立反例确认直接f128平方相加仍可丢失极小垂直分量，把外焦点错判为相切并将透明区域填末色。固定准备阶段改用max-axis平方差分解；TwoDiff保存坐标/半径减法残差，向外舍入区间无法确定符号时明确拒绝。没有epsilon相切判断，逐像素仍为无分配f64根求解，不宣称通用精确算术。
- 独立BigInt dyadic oracle覆盖612组轴/符号/指数/邻接半径以及1024组随机减法残差；新增原几何反例两种mode透明像素。repeat/reflect的点相切极限支持恒RGB、变量alpha，保留恒定颜色分量和sRGB端点：红色0→1透明度得预乘BGRA 0/0/128/128，#808080得64/64/64/128。RGB与alpha同时改变、非零fr的A=0继续保留明确错误。
- 作者Windows/Linux Debug/ReleaseSafe均vector31+SVG77共108/108；root独立Windows ReleaseSafe12/12步骤、Linux ReleaseSafe11/11步骤，均108/108加实际原生六组合（pixel/sample_color×scene/own-mask/radial）。GDI/hardware/WARP/Cairo三DPI、worker关闭源、独立透明/红/灰像素、Frame/驻留pin、设备恢复和native稳态资源归零。完整SVG仍按G01.5继续实施。

### G01.3 独立透明离屏资源（实施中）

- 固定尺寸的可选Surface复用SoftwareRenderer与有界commands.Buffer，显式准备独立透明根工作面；首片使用GDI/Cairo，不同步等待GPU读回，也不消耗一个额外用户group层。拥有型Snapshot保存独立预乘BGRA、Lease与非回绕身份，源Buffer reset或Surface关闭后仍能回放；跨worker交接、mip生成和文件编码另验。
- Surface接App停止参与者，所有外部allocator/native入口由App scope与busy门保护，停止只撤原生资源，调用者显式关闭壳。工作面、resident旧/候选、所有仍存活输出与候选以及固定元数据在创建时统一预检；native字体/驱动内部存储明确另列，不冒充进程内存统计。输出账户覆盖Surface关闭后的最后一个Snapshot，render在执行前检查保守工作上限。
- 软件首片已验收：作者Windows/Linux Debug/ReleaseSafe通过；root独立Windows ReleaseSafe GPU六目标32/32步骤、Linux ReleaseSafe六目标26/26步骤通过。覆盖三DPI透明根/完整4层group、RGBA/gradient/fractional clip、两类真实glyph、image/A8/mask；Snapshot在源Buffer reset、Surface/App/字体关闭和源像素改写后仍正确回放。GDI/hardware/WARP/Cairo的快照上传逐像素检查、设备恢复、旧layers/coverage/images/65次动态commit与SVG六组合兼容均过，持久native/text/lease归零。
- 全Zig/每个native plane分配失败、回放后导出失败、预算不足不分配、Cairo缺驻留恢复、线程拒绝、stop Full/taken、allocator关闭/quit与Snapshot释放重入有正式回归。输出峰值只计成功分配，关闭壳的foreign free退栈前阻止同账户新render/close，真实App.stop仍能只收native。GPU独立target尚未实现；其DeviceDomain、固定export slots、跨设备/软件后备与DeviceLost代数按G03继续，不将CPU快照上传回放算作GPU离屏渲染。见[离屏快照](offscreen.md)。

### T04.2.2 有界双栏比较与原子revert

- 新可选document_diff_view拥有配对Inbox、双Snapshot及有界可见缓存；worker释放Reader后仍需owner finish交付责任，取消/stop不提前归还槽，接收预算独立复核。Result显式take防止同版本的已移动结果被二次接受，old/candidate资源用显式所有权转移。
- Hunk段与整数height/Fenwick元数据构造不读全文行、不做native shaping；可见完整段落成批准备，双侧按最大实际高度对齐，缺失一侧是显式blank。draw只有Prepared/矩形回放。revert只读保留Snapshot中的指定范围，经当前text stamp/target full revision校验后调用同一Adapter一次replaceMany/undo；没有第二份文本、选区或IME状态。
- 作者Windows Debug/ReleaseSafe、Linux ReleaseSafe 1x/2x通过；root独立Windows ReleaseSafe16/16、Linux ReleaseSafe 2x14/14，均Diff14+View9共23/23，并另通过Linux1x原生。覆盖真实双Reader worker→App.post、空文档/末尾LF/CRLF、单侧wrap/blank像素对齐、原生key/pointer/wheel、单次undo与重新比较、IME拒绝、OOM/失败帧/draw关闭及资源归零。检查已加入本地CI配置，远端未执行。
- 10万行实际只构造4个正文batch，纯选择更新新增0个正文layout；本机初次prepare Windows约12.2ms、Linux2x约3.31ms，warm滚动约2.69/0.364ms。工具benchmark-document-diff-view仅计CPU准备，不含比较/setup/replay/显示，当前有其他构建负载，不是V02正式基线。独立性能review发现静态header每次滚动重建，继续优化并单独计数，不用正文shape为0掩盖标题成本。
- 静态标题现按slot/font generation/scale/height共享拥有资源，origin仅影响回放；候选失败保留旧header与其预算。root独立Windows ReleaseSafe13/13步骤、Linux2x11/11步骤，各9/9纯测试及最新原生回归通过。100000行64次warm滚动的header Layout/Prepared新增均0、复用192次，Windows median约1.635ms、Linux2x约0.335ms；保守峰值reservation由161261112降为123512520字节。前后观测仍有并发负载，Windows有明显改善，Linux差异接近噪声，不作显示帧率或隔离基线承诺。

### I01 外部分配器重入的发布边界

- 资源流接线的独立review与实际红测确认：Router编码时跨allocator保留Pending指针，取消后复用slot会让旧chunk写入新请求，旧complete/fail也可能释放新slot。现编码返回后重新核对method/session/slot/id，chunk另核对原sent；有效ACK仍允许推进，嵌套chunk已先占序号则外层返回StreamChanged并释放未发布包。解析也在typed参数完成后复核closed/session/ID/slot，新增contains只读成员检查，无额外表或分配。
- 同类event回归确认关闭后编码仍能成功；emit现固定captured token session编码，并在allocator返回后重验session/订阅/关闭状态，避免旧业务值被重载回调带进新页面session。宿主仍负责保活Router/EventSession、Received、payload和目标上下文。
- root Windows Debug/ReleaseSafe、Linux ReleaseSafe纯IPC各29/29，含取消/复用、关闭/reset的每个解析分配点、嵌套chunk/有效ACK和event失效；Bun RPC/events/resource客户端共23/23、183断言。真实Runtime随B05.4接线继续验收，这些纯层结果不代替新桥的原生交接。

### T04.2.3 共享段落投影与双侧发布基础

- Adapter的可选Plan绑定唯一Document与committed text stamp，保持原段落顺序，以稀疏gap/minimum-height派生独立高度树；不改变文本offset、选择、undo或基础行度量。可见paragraph Placement用于draw、hit、range/position、滚动和原生caret几何。任一侧preedit时双侧暂停投影，取消可恢复；文本edit/undo即使恢复同字节也使旧plan失效。
- projectPair先构造两份候选，以同步借用LayoutProbe测量完整段落，再接收宿主拥有Plan；两个Adapter保持Busy到双方纯发布及旧资源释放结束。发布前失败不发布单侧；发布后旧资源释放导致外部变更时返回成功的committed outcome并指明current=false/post_publish_error，已安装Plan责任不回滚。大gap保留整数局部intra，先作2^-32 DIP整数差再转换视口f64，不以epsilon吞掉小偏移。默认无投影路径不复制全文或构造稀疏树。
- root独立Windows ReleaseSafe纯15/15、三项真实编辑器检查16/16步骤；Linux ReleaseSafe 2x纯15/15、三项原生13/13步骤。正式Diff夹具含右侧候选失败、双方Busy、不等高对齐、caret/range/hit、双方IME/cancel、1e12 DIP gap后保留一个2^-32 DIP tick，以及Planner关闭Window后on_closed立即释放两Adapter/context；所有资源归零。可编辑Diff Coordinator继续实施，本基础不单独替代T04.2.3完整验收。

### G02.1 显式时钟与单次唤醒基础

- 可选纯ziggurat_animation无allocator/native/线程/timer依赖，提供Channel的tween、解析spring、延迟/取消/reduce motion、固定64轨Timeline和整数Playhead。按固定起点采样，迟到直接跳到当前时刻；spring重定向保留速度，有限截止以deadline原因结束，不伪称物理settle。错误用候选值回滚，容量、数值、时钟倒退及溢出明确拒绝。
- 可选ziggurat_wake以稳定OneShot owner接App stop：Windows借用原有有界native wait注册，Linux自定义GSource；无隐式post/worker/循环。fire前撤本次入口，只有显式rearm才再次唤醒。旧generation不可取消新期限；已选中的GLib source在dispatch前复核新ready time，关闭/重排不会交付旧期限。App stop只释放native，调用者在App.deinit后仍可显式关闭壳。
- 纯动画Windows/Linux ReleaseSafe各12/12通过，包含独立RK4/临界闭式oracle、固定起点采样、重定向速度、近临界参数和事务错误。OneShot作者与独立只读review、Windows/Linux Debug/ReleaseSafe真实主循环均通过；root ReleaseSafe Windows16/16步骤含旧smoke/1000窗口，Linux13/13含旧stop/GTK检查。正式用例覆盖stop Full/taken、错误线程、OOM、满16wait槽、selected source关闭/重排、callback关闭、foreign allocator重入、finishShutdown Busy及on_closed立即释放整个宿主，最后native和allocator归零。独立无GUI GLib探针也验证同轮selected source不迟到误调。
- 已接默认test/check、test-animation及smoke-wake、CI配置；远端workflow未执行。theme、变换命令、局部失效和动画编排继续实施，G02未完成。见[动画](animation.md)和[单次唤醒](wake.md)。

### 本轮默认与可选整图复验

- Linux ReleaseSafe test/check为101/101步骤、460/460测试；Windows ReleaseSafe启用WebView/GPU/UIA最终217/217步骤、532/533通过、1项平台条件跳过。覆盖Diff双栏与共享投影、producer桥、SVG108项、离屏软件首片、纯动画12项以及已有后端；Windows还编译单次唤醒目标。各原生运行仍按独立切片证据验收。
- Windows首次整图唯一失败是编译器读取本机stdlib Target/xcore.zig时Unexpected，文件实际存在且可读；项目源不变的窄目标和整图重试通过，原因未确认。此结果不包含后续EditableSplit的committed outcome/native observer、新GPU DeviceDomain或Linux公开WebKit后端，不以这些整图数字提前标记它们完成。

### G02.2 客户区局部失效

- Window.invalidateRect在主线程/Window scope内验证DIP范围与零面积，Windows按实际scale向外取物理像素并裁客户区，GTK向外取逻辑widget坐标后裁DrawingArea；原生更新区域自然合并，无历史请求表或新分配。完整Context命令/输入/语义事务仍保留，不把OS damage提示算作dirty-tile/GPU部分回放。
- 独立只读review未发现确认缺陷。root Windows ReleaseSafe核心91/91、原生4/4步骤通过；Linux核心90/90、1x原生3/3及2x四目标15/15通过，后者含content host/wake/旧GTK生命周期。系统真实region检验分数边界、负位置裁剪、合并、空/无效请求与closing；worker/旧代数拒绝通过。已接check与CI配置，远端未执行；主题、变换、失效复用继续实施。见[局部失效](invalidation.md)。

### T04.2.3 可编辑双栏与原生变更闭环验收

- EditableSplit只派生对齐和焦点；两Adapter保持唯一文本/选择/undo/IME，单一聚焦TextClient。共享整数行索引驱动滚动/导航，可见段落以稀疏gap和minimum-height对齐，不强制测量未显示前缀。普通文本提交使旧Diff过期；重比交付仍按完整文档对/stamp/serial，revert保留一次undo。
- 成对API区分发布前错误与发布后的失效：任何成功结果都已移交安装的Plan责任；旧Prepared/allocator清理重入修改Document或关闭Window时以current=false/post_publish_error通知，调用者不会释放仍在Adapter借用的候选。正式真实旧资源free hook覆盖此边界。
- Adapter单槽NativeObserver以非回绕token显式注册，阻止仍借用它时关闭；只在直接原生TextClient操作实际改变revision后、Adapter Busy退出后通知，携带已提交后的layout_error。回调可撤销/重装观察入口，末尾不再访问Adapter。原生提交后准备OOM仍通知并可修复，同一TextClient服务IMM文档重转换与GTK surrounding delete。
- root独立Windows ReleaseSafe22/22步骤、Linux2x19/19步骤，各25/25纯测试与Diff/文档编辑/代码编辑三native通过；作者最终Linux1x19/19与Windows Debug通过。正式夹具含双方IME/cancel与focus loss、1000行CtrlEnd/reveal、empty/EOF/trailing-LF、16个OOM点、真实候选坐标、失败帧、planner/native observer关闭后on_closed立即free，以及全部native/text/lease归零。CtrlHome/End即使selection原本已在端点也明确reveal。
- T04.2.3的无折叠双栏切片已验收。统一视图、行内差异、fold对齐和组合可访问语义继续实施，不以该结果标记整个T04完成。

### G03.1 显式共享设备域与纹理验收

- Windows可选DeviceDomain拥有明确hardware/WARP设备、固定32纹理/32attachment和统一旧/候选texel预算；Context默认仍用原有独立renderer。上传后Texture不借CPU pixels，typed TextureView带Domain/代数/Lease且不能冒充ImageView。整帧native draw前校验全部纹理；跨设备、失效或软件renderer明确拒绝，不做读回/隐式补绘。
- loss/stop先关闭入口并逐一清token/unwatch，再关闭DXGI句柄；整批native释放门阻止attachment复用。stop只释放native payload，renderer/Texture稳定壳继续显式回收。raw资源操作固定App，LayerCandidate绑定owner与Domain generation，旧设备候选拒绝提交；GPU提交成功后软件候选无失败点交换，保留双后端准备事务。
- 作者Windows Debug正式Domain6/6、私有Debug/ReleaseSafe纯70/70及native通过；root独立ReleaseSafe正式Domain6/6硬件/WARP通过，旧GPU/fallback/layers/offscreen/image-update五目标也全通过。三DPI检查alpha/fit/彩色mip/clip、跨Domain整帧拒绝、容量/预算/nth-mip失败、loss/recreate、双watch撤销、全部Zig分配失败/重入/错误线程、满attachment回滚和App.deinit后壳释放，最终references归零。作者Linux旧layers/offscreen9/9通过。
- 当前为共享GPU上传资源首片；真正GPU离屏target与显式snapshot导出继续实施。Domain logical texel/metadata预算不冒称整个进程RSS、驱动显存或attachment缓存总开销。见[共享GPU资源](gpu-resources.md)。

### G02.3 显式基础控件主题与有限重复

- UI Theme是完整复制的RGB Palette/Metrics值，无字符串借用或全局观察器。setTheme在更新阶段完整验证/equality/nonwrap后发布，已附着时固定Window并请求全窗失效；painting/composing/attach过渡返回Busy。button/checkbox/radio/switch/progress、slider/双端范围/stepper使用同一尺寸/颜色；字体与文档视图的显式Colors仍由原owner准备。
- 独立只读review未发现确认缺陷。Windows ReleaseSafe主题和UI纯层9/9步骤、73/73测试通过；实际自定义控件像素、Metrics更新、绘制中Busy、失败frame保留旧front与旧slider track分别通过Windows6/6和Linux2x5/5。Linux UI纯64/64、旧widgets/range原生通过；原先像素helper重复缩放及固定index误取progress记录的夹具错误均已修成raw pixel/稳定ID，无生产规避。
- Playhead新增显式有限configureRepeat/alternate，最多1,000,000次且总duration至多1小时；pause保留次数、seek/restart重置，整数除法O(1)跨过错过的周期。reduce motion直接完成最后方向，总deadline溢出不发布候选。Windows/Linux纯动画各15/15通过独立遍历oracle、百万周期帧分割一致性、暂停/seek/反向/reduce motion与容量/时钟事务；Linux ReleaseSafe主题/原生唤醒/动画合计12/12步骤通过，含1x实际主题像素。变换命令、失效复用和系统偏好接线仍继续实施，不提前完成G02。

### T04.2.4 统一Diff首片

- EditableUnified与双栏共用同一presentation State、预算、Inbox和双Adapter；common使用B、deleted使用只读A、added使用B，hunk内保持删除记录先于新增。纯metadata将每hunk展开两个有序范围再复用整数Fenwick，不读源文本、不制造B offset。target B仍是唯一可绑定/编辑/选择/IME/undo来源，ghost点击只选hunk，composition临时只画B identity。
- Adapter.drawParagraphs将有界、严格递增source paragraph IDs与既有Placement Runs线性merge，单次遍历、同Prepared，不画源A的marks/caret，不每ghost重放整个pane、不在paint分配或shaping。新范围过滤错误使Frame失败并释放本次pin。
- 作者Windows Debug/ReleaseSafe及Linux1x/2x通过；root独立Windows ReleaseSafe22/22步骤、30/30纯测试与三native通过，Linux2x同组30项纯测试及Diff/文档编辑/代码编辑原生全部通过。新夹具验证ghost/add顺序与真实glyph像素、B选区不因ghost点击改变、唯一native client、跨ghost导航/编辑/undo、resize caret、IME/cancel、revert/OOM、200行ghost对空B的可见预算与关闭资源归零。300组多hunk独立线性oracle及100000 common行仅metadata通过。
- 统一视图首片已验收；行内差异、上下文折叠对齐、组合可访问语义与显式native overlay更新链继续实施。不同presentation owner不能抢占同一个Adapter observer槽，实际组合必须由宿主显式串接prepare；不引入隐藏订阅表。

### P01a Linux可信HTML后端验收

- -Dwebview=true在Linux显式链接GTK3+Soup3的WebKitGTK API4.1，最低2.40；默认Core/UI不链接引擎。Storage默认profile维持Windows绝对路径契约，Linux首片必须显式ephemeral且folder为空，使用原生临时WebContext。不支持的local/remote/file/scheme/tools/permissions/downloads/devtools/regions/PageSession配置在分配/接管前拒绝，关闭入口优先Closed；capabilities仅表示实现契约，不表示引擎安装或授权。
- 私有GtkOverlay host按需创建，原Window/DrawingArea/IM对象与signals保持，冷重挂载重建的GdkWindow明确取消旧输入并重绑IM。每个signal/source/异步任务持独立C State；close先owner=null，再断signals/取消，迟到callback必须实际finish后才归还物理pending和引用。NativeFailure分别保存真实HRESULT或GLib domain/code，不伪造错误namespace。
- 顶层私有script world通过isTrusted/source/top/about:blank及非回绕document generation校验；严格默认CSP拒外网connect/frame/worker/object/base/form，权限/认证/下载/脚本对话框/文件及颜色选择/打印/通知/弹窗/上下文菜单均显式拒绝，普通select选项菜单保留。该边界不是通用网络sandbox，也不是HTTPS local的替代。
- root审查提出直接window.postMessage绕facade带NUL可截断的疑点，作者真实引擎红测确认prefix被误收。私有listener现按scalar计算UTF8字节并拒NUL；C改为JSC GBytes明确长度+memchr二次校验。正式负例直接绕facade、测试宿主私有world直调native handler，并验证65536B多字节正例/65537B拒绝，不依赖strlen截断。
- root独立strict C contract两模式与backend均exit0；公开Zig烟雾1x/2x各5/5步骤，四App正常/timeout/raw-close/reload/真实进程终止后recover、旧PageId、配置及编码全部allocator故障、ready前on_closed立即free、GLib脚本域码/UA OOM通过，native/core/host归零。Linux纯3/3步骤59/66通过、7项Windows原生宿主专有skip；Windows纯+旧smoke11/11步骤64/66通过、2项Linux专有skip，15App/99pending关闭/COM0。
- 验证为WSL Ubuntu24.04/Xvfb X11、GTK3 3.24.41、WebKitGTK2.52.6、Soup3 3.4.4；保留引擎sandbox，隔离依赖以私有namespace只读挂载，未改系统安装。新增可选CI配置，远端未执行；未据此宣称Wayland、GPU、完整混合焦点、AT-SPI或完整P01完成。下一片建立WebProcess发送前不可变请求策略，再接本地/远程/文件资源。见[页面策略](pages.md)。

### G01.3 GPU透明离屏与统一资源预算验收

- gpu_offscreen.Surface使用显式DeviceDomain、固定透明front/work/group目标；render复用工作面，snapshot单独占32槽之一并复制为独立不可变GPU Texture。同设备旧快照可作输入；没有HWND/swapchain/CPU平面、生产读回、阻塞fence或隐式软件fallback。
- 先完整命令/资源/代数/驻留/工作量预检，再独立pin和capture；失败不提交front。Domain统一预留workspace、旧/候选Texture、Surface metadata及两份resident上限。logical reservation与native/driver/RSS分开；设备丢失保持稳定壳但旧front/Texture失效，App停止释放native后仍可显式close。
- root审查发现构造失败的borrow释放晚于App scope，以及普通operation最后State写入晚于内层scope两个关闭重入缺口；已以整个Surface操作的外层Domain/App scope修正，captured释放/最后写入/busy退出先于scope.end。close保留borrow直到foreign State free完全退栈，构造失败先释放provisional attachment。
- 作者Windows Debug正式9/9步骤、UI纯75/75，ReleaseSafe新Surface/Domain11/11；root独立ReleaseSafe七目标37/37通过，含旧GPU/fallback/layers/CPUoffscreen/image-update。硬件/WARP×1/1.5/2 DPI验证透明像素、fractional clip、mask/gradient/image/prepared与legacy text、四层group、旧snapshot独立、预算/slot/allocation/native故障、错误线程、allocator关闭/quit后on_closed立即free整个宿主、loss/recreate/stop及资源归零。Linux作者默认UI纯66/66与旧CPUoffscreen8/8通过。
- 阴影、分组、独立软件/GPU离屏范围现完成；SVG、共享缓存/多窗口性能和变换仍按父项实施。见[GPU离屏](gpu-offscreen.md)。

### T04.2.4 精确行内差异与保留标记

- 纯intraline按changed hunk内同序号行配对，保留原文UTF8 scalar边界和真实CR/LF/NUL；公共前后缀精确裁掉后做有界LCS，整个Job累计bytes/pairs/spans/cells/work与取消，不按行重置预算、不静默截断。不是字素比较或模糊行匹配。
- Inbox.publishDetailed对line/details校验同一对Snapshot/stamp/serial和旧+候选接收预算，两份take均为纯移动，新Display先拥有后才析构旧资源；拒绝不移动任何结果，零span也不能二次交付。worker释放Readers后仍由owner显式finish。
- EditableSplit/EditableUnified在prepare复用同Adapter的缓存排版，将scalar范围扩大到真实grapheme与bidi islands，空/行尾无advance用实际caret。draw只回放有界标记；选择变化复用marks、不重查range。pair已提交后的marks OOM/capacity/foreign free关闭仍保留已安装Plans责任，显式要求重新prepare，不把发布后失败伪装未发布。
- 作者Windows Debug/ReleaseSafe、Linux1x/2x通过；root独立Windows ReleaseSafe22/22步骤、Linux2x19/19步骤，各40/40纯测试及Diff/DocumentEditor/CodeEditor三原生通过。包括512组独立scalar DP/reconstruction oracle、7000字公共前后缀仅4cell、所有分配点/取消/真实worker→App.post双交付、family emoji/combining/bidi/空caret与两色像素、限额1/marks OOM、IME/undo、失败帧和旧marker free关闭，最后资源归零。
- 只读旧View仍为整行标记；上下文折叠与组合可访问语义继续实施，T04.2.4未完成。

### G02 有限重复的独立复核

- 独立review未发现确认缺陷；另4000组×40次随机play/pause/seek/reconfigure/reduced操作，将bulk advance与逐1ns推进全状态差分，ReleaseSafe通过。该纯数值证据不替代显示时序或OS偏好。
### G02 动画与UI原生队列闭环

- 新smoke-animation-ui在普通更新阶段组合Timeline/OneShot/Window.invalidateRect，draw只读取准备值；完成后通过显式App.post验证成功Frame的命中位置。三段往返与reduced motion均正确结束且timer不再armed，App.stop/Window关闭后壳和native归零。
- root独立Windows ReleaseSafe6/6、Linux X11 2x5/5步骤通过。夹具不强制paint、不假设每期限一帧；局部失效仍只是OS damage，不声称命令/绘制局部复用或显示延迟。已接check及Windows/Linux1x2x CI命令；同时修正可选WebKit检查应属于Linux bash job的接线，YAML及平台/shell归属检查通过，远端workflow未执行。
### G01.5 同一系统排版的独立单色字形轮廓

- Layout.outline显式枚举已有系统布局：Windows使用原font/glyphIndices/advances/offsets/bidi的GetGlyphRunOutline；Linux PangoCairo.layout_path读取同PangoLayout。两次有界枚举分别计数/复制move/line/cubic/close；glyph/commands/bytes/取消在native调用和foreign allocation边界检查，不另shape。
- OutlineSnapshot不保留Layout/Engine，独立单色DIP轮廓；可选ziggurat_text_outlines将其转换成独立vector.Path。默认Core/UI没有vector/native outline依赖。桥的字节预算覆盖snapshot、转换数组和输出Path的同时存在峰值；Pango内部Cairo/font path存储为不可观测native临时成本，不冒称同一硬内存上限。彩色字体的颜色层/bitmap不是该单色轮廓合同。
- 作者Win Debug/ReleaseSafe与Linux ReleaseSafe通过；root独立Windows ReleaseSafe新旧text目标10/10步骤、Linux8/8通过。复杂脚本/组合/emoji/bidi/fallback/空白、O空洞、两行baseline、三DPI Path覆盖、精确peak-1拒绝、所有Zig OOM/cancel、错误线程、allocator重入期间Layout Busy/Engine LayoutsAlive，以及第3次分配后先关闭源Layout/Engine仍可完成独立Path，最后native与allocator归零。
- 本片只完成同排版的轮廓桥；SVG text provider、场景累计预算、定位和clip/use继续实施，不提前声明完整SVG文字。

### G01.4 图片准备的foreign allocator寿命复核

- 实际回归先确认：PreparedImage.create的两个分配回调均能成功关闭正在读取的源Image；加入源Lease后，源与Prepared析构的foreign free回调仍可递归close。现准备跨全部allocator/回滚/最后源描述读取固定Lease；Image/PreparedImage在释放前先设置closing，重入查询/close明确Closed，borrow期间adopt明确ResourceInUse而非assert或移动owner。
- Retained allocator延迟物理free，真实close调用稳定复现两种失败且不依赖UAF碰巧崩溃；另真实worker持borrow、主线程adopt拒绝、worker释放后正常adopt通过。root Win ReleaseSafe图片四目标22/22（含hardware/WARP采样与动态更新），最终新增handoff的窄Win6/6/Linux5/5通过；Linux其余三图片native也通过。独立源码review无新增确认缺陷。该修复不改变图片格式/采样语义。
### G01.5 场景allocator与系统Layout门禁

- Engine.layoutAllocated显式选择Layout及全部Prepared的allocator，默认layout不变；Engine本体仍由创建allocator拥有。构造期间Engine Busy阻止其在首个live Layout发布前被foreign allocator关闭。Layout.prepare/outline共用operation门，Prepared析构将parent门保持到最后free和计数访问，Layout/Engine/Prepared均先关闭入口再析构。
- 作者Windows Debug/ReleaseSafe、Linux ReleaseSafe正式outlines用例通过，旧Windows Layout/绘制11/11通过；root独立Windows ReleaseSafe outlines+text-drawing11/11、Linux9/9通过。正式用例覆盖构造和prepare重入、三个析构递归Closed、Engine allocator不接收Layout/Prepared存储、全部布局及Prepared OOM，native与allocator归零。SVG场景provider继续实施。

### 最新一致源码快照整图复验

- 在所有任务可编译时仅短暂停写，复制512个源码/fixture/文档到独立ignored checkpoint，之后所有agent继续开发，不持有长时间全局freeze。Linux ReleaseSafe test/check为106/106步骤、488/488测试；Windows开启WebView/GPU/UIA，最终test/check加smoke/lifecycle/WebView为239/239步骤、561/564通过、3项明确平台skip。1000窗口records归0、slots1，GDI12→12/USER6→6，实际Runtime15App/99pending关闭/COM0。
- Windows首次唯一失败为stdlib math/ldexp.zig读取Unexpected；文件实际可读、SHA256=2C3C54F8E10FB9EBAAE5443832BBC4AD3D87FF35A50E109B71C0D8844FEAEEAA。项目源码完全不变的窄smoke-images及整图复验通过，原因未确认，不以此修改生产代码或断言杀毒/内存原因。
- 本快照包含GPU离屏/共享设备、Theme、动画15项、wake/damage/UI闭环、行内Diff40项及旧可选模块；不包含后续Image寿命修复、layoutAllocated门禁、成对上下文fold和custom本地页面新接线。它们继续按各自独立证据记录，不用旧整图数字冒称最新工作树全部完成。

### P01b Linux显式custom静态站点与worker文件快照

- Linux接入单一显式注册的custom scheme、精确host/start_path与静态GET/HEAD。独立custom_local_site=true；HTTPS local_site、宽custom_schemes、remote_pages、按需file_responses仍false。非默认methods/headers/request origins、dynamic document/async资源和目录/file://不自动开放，保持分配/接管前拒绝。
- FileSnapshot仍由宿主worker基于明确文件句柄准备，经App.post交接；静态资源按既有resources_released/detach借用，C handler交付前复制为独立GMemoryInputStream。物理budget跨View reload/recover保留，最多8response/32MiB body、全进程32流，HEAD/空流也计数；EOF/close/逻辑取消不提早归还，最后unref才释放。native存储和元数据有固定数量/长度上界，不等同引擎内部缓存或RSS。
- root独立strict C local-test/local通过，实际验证初始budget/复制候选OOM、降额、32个空流、旧owner先释放后仍读原字节、末引用归零；真实引擎验证同源脚本/GET/HEAD/404、MIME/nosniff、默认/显式IPC及已配置的来源边界。库无UI磁盘读取、隐式worker或嵌套loop；不以本片推定远程策略完整。
- root公开Zig Windows ReleaseSafe四目标21/21步骤、66/68纯通过/2Linux skip，含旧WebView15App/99pending、Windows scheme和remote/fileSnapshot兼容；Linux ReleaseSafe公开1x/2x各5/5、纯3/3步骤61/68通过/7Windows skip、Debug公开5/5通过。新增真实worker FileSnapshot→post/adopt、双向IPC、reload及终止本fixture WebProcess后recover、同budget指针、旧PageId拒绝、全部Zig allocation失败和逐点alloc/free关闭后on_closed立即释放View，最终预算/流/body/native/core归零。
- 新关闭夹具最初误将attach返回当最终安全点；实测activity_depth0、pending_destroys1，补正常App.dispatch后通过，没有修改生产关闭次序。源码接手时的C逻辑括号/匿名返回类型语法问题已窄修。可选CI加入local-test/local，YAML及平台归属检查通过，远端未执行。
- 实际环境沿P01a；HTTPS本地、远程、按需文件流、多注册动态策略、区域/PageSession和更广浏览器工具继续实施。见[页面策略](pages.md)。

### G01.5 显式 SVG 文字 provider 与场景预算

- 纯 SVG 只定义同步文字 provider；可选 `ziggurat_svg_text` 使用复用 Engine 和场景 allocator，从同一系统 Layout 导出独立单色 Path。来源 Document 与 provider 可在准备结果回放前关闭；paint 不解析、排版或提取字形。Document 在全部 foreign allocator/provider 调用及回滚期间 Busy，最终释放先撤销入口。
- 首片支持单一 text 块、单值 x/y/dx/dy、方向/anchor、继承字体、填充/描边/变换/透明度和 text/use/clip。明确采用 SVG 1.1 default 空白处理；CSS white-space、preserve、tspan/textPath/逐字符位置和完整 glyph-cell objectBoundingBox 继续实施，不把 ink bounds 当作该边界。所有临时 Layout/Path/cache、字形/命令/源字节/工作量与整个场景的旧候选使用同一累计预算。
- 作者 Windows Debug/ReleaseSafe、Linux ReleaseSafe 通过。root 独立 Windows ReleaseSafe `test-svg smoke-svg-text smoke-svg -Dgpu=true` 为14/14步骤、84/84纯测试；Linux ReleaseSafe 2倍缩放为12/12步骤、84/84纯测试。真实字体 Path 逐像素 oracle、text 与 use→text clip、两种合成模式、三档 DPI、GDI/hardware/WARP/Cairo 回放与复用、源提前关闭、全部 OOM/逐候选取消/精确峰值减1、owner/递归关闭检查通过，最终资源归零。普通和可选 CI 已接目标，远端未执行。

### T04.2.4 成对上下文折叠与发布前几何

- 只折叠 unchanged source 行，保留真实正文 header，不隐藏 hunk 或虚构 ghost 的 B offset。拥有型 ContextIndex 只处理有界比较元数据；collapsed/expanded 映射、统一/双栏行索引与 source range 使用同一份 authority。正文、选择、历史和 IME 仍由原 Document/Adapter 拥有。
- Adapter 使用带非回绕代数的显式 fold owner token；普通折叠入口拒绝冲突，撤销不分配，旧 token 不能释放新 owner。双侧 FoldCandidate、Layout、Plans、索引和标记在全部准备成功后发布；PreparedProbe 复用将要发布的缓存几何，在发布前完成标记容量/几何校验。旧资源析构造成关闭或新 revision 时返回已提交 outcome，不能谎称回滚。所有 foreign allocator 返回后复核完整 revision，覆盖 composition 变化。
- 作者 Windows Debug/ReleaseSafe 与 Linux ReleaseSafe 1x/2x 通过；root 独立 Windows ReleaseSafe 为19/19步骤、30/30视图纯测试，Linux ReleaseSafe 2x为16/16步骤、30/30纯测试，包含 Diff/DocumentEditor/CodeEditor 三组实际原生检查。真实 gutter 像素/点击、跨隐藏行导航、只 reveal 不改选择、隐藏 caret 拒绝、双侧及 coordinator OOM、单标记容量失败保旧 fold/Plan/viewport、IME identity/cancel、编辑/undo/旧 serial、失败 Frame 与关闭均通过，资源归零。
- 新增独立原生 TextClient 链已由作者 Windows Debug 与 Linux ReleaseSafe 2x 验证：IMM feed/reconversion 拒绝隐藏 caret 且不改 revision，接受可见选择后 observer 同步刷新两侧；GTK surrounding/delete 不借 UI 事件也清除两侧派生折叠，undo/refresh 恢复。完整文档可访问文本、跨线程快照及 Diff ghost 独立语义继续实施；本片不宣称 T04/T06 全部完成。

### 第二份一致源码快照整图复验

- 短暂停写复制534个源码/fixture/文档，保留独立 ignored checkpoint 后恢复并行开发。Linux ReleaseSafe test/check 为108/108步骤、500/500测试；Windows ReleaseSafe 开启 WebView/GPU/UIA 的 test/check、smoke、smoke-lifecycle、smoke-webview 为245/245步骤、575/578测试通过、3项平台 skip。
- 实际1000窗口后 records=0、slots=1，GDI12→12/USER6→6；连续任务期间原生 timer 调度20次，原生队列填入9998条消息达到配额后，已接受任务仍执行一次；WebView Runtime 15App/99pending关闭后COM=0。本快照包含图片寿命修复、layoutAllocated门禁、SVG文字首片、成对上下文fold和Linux custom静态页面；不包含后续完整字形单元、仿射renderer/Frame/UIA及文档文本无障碍新实现。

### G03 多窗口共享设备域测量首片

- 新增显式 `benchmark-gpu-domain`，真实隐藏窗口上比较1/4/8窗口、共享一份Domain/Texture与每窗口独立资源；hardware/WARP各3trial，总36样本。准备与预热后的64轮提交分开记录，普通测量不加GPU等待/像素读回/事件循环；Present busy与完成次数分别保留。
- 两类配置预热后显式Zig allocation、renderer target/device与domain bitmap创建均不增长，最后adapter引用/窗口记录归零。共享1份262144字节逻辑纹理与独立N份的关系由计数验证；整个进程WS/private包含宿主和驱动缓存，逻辑payload不是显存测量。
- 最终采集前已结束整图检查，三个任务短暂停止构建/测试，其他后台系统负载不受控制。保留源码/可执行/报告哈希与环境，详见[测量](gpu-performance.md)。本机hardware的4/8窗口共享setup更低而提交p50更高，不据资源副本关系推定速度收益。缓存容量/淘汰和更广长期基线继续，G03/V02未完成。

### G01.5 完整字形单元、文字边界与 XML preserve

- `Layout.outline`/TextOutlines 显式 `include_cells` 保留原 glyph run 的 advance/offset 和实际字体 ascent/descent；默认不分配单元数组。Snapshot/Shape 候选双数组计入同一预算，独立输出可在 Layout/Engine 关闭后使用，takeGeometry 同时转移 Path/cells。Linux 准确 run baseline 使用 Pango1.50以上，旧版本对此选项明确拒绝。
- 系统 SVG provider 提供完整单元；文字、父容器及 use 的 objectBoundingBox 对每单元四角先变换再并集，用于渐变/clip/mask。自定义 provider 可不提供 cells，需要该边界时仍明确拒绝。场景 lease 跨首次分配、相邻 shape、回滚和最后 cache free 保持 provider owner，关闭/stats 期间 Busy，不让 allocator 回调撤掉待用 context。
- root 独立字体指标 oracle Windows Debug4/4、Linux ReleaseSafe3/3通过；完整边界和preserve后 Windows ReleaseSafe GPU 为9/9步骤、90/90纯测试，Linux ReleaseSafe2x为8/8步骤、90/90。覆盖真实字体显式用户坐标对照的渐变/clip/mask，两种合成模式/三档DPI、GDI/hardware/WARP/Cairo回放；纯几何另验分离单元旋转后tight边界、无效cells/全部OOM/取消/预算减1与每个allocator回调owner pin，最后refs0。独立源码review未发现确认缺陷。
- XML preserve 将LF/tab各转一个普通空格，保留首尾/连续空白，跨节点与继承/use cache模式分别验证；default处理不变，CSS white-space与引用CR仍明确拒绝。完整tspan/textPath/逐字定位、基线族/字体run等继续，G01.5未完成。`smoke-text-cells`已接CI入口，本地等价命令已跑，远端未执行。

### G02 仿射栅格合成与已提交坐标

- 显式prepareTransforms建立独立窗口front/work与按最大源DIP/DPI计算的有界层池，源面可以大于窗口；一像素透明guard参与双线性采样，源的fractional边缘只裁一次，父clip在最终合成应用。GDI/Cairo/D2D复用同层资源，普通Context不分配大池或变换表，正常回放不新增目标/上传/排版/GPU等待。
- Command仅保存u8描述索引，外部稳定TransformStorage含64个值描述；独立capture复制表并持资源lease，foreign allocator重用源Buffer不改变回放。Frame/Input/Space/UIA在成功front后一起发布；失败候选保留旧front/坐标，显式捕获Space有不回绕代数，逆向命中检查各自clip，IME锚点只从已提交Space转为系统AABB。
- root Windows ReleaseSafe25/25步骤、110/110纯测试，Linux ReleaseSafe18/18、98/98通过，包含两端实际smoke-affine-renderer/UI。作者额外Windows Debug与完整旧renderer回归35/35、Linux25/25通过。三DPI覆盖reflection/旋转/shear/非均匀scale、mixed scopes、fractional源/parent clip、same-depth重用、prepared glyph、全OOM、front保留和GPU loss/recreate。原生UI覆盖旋转控件/离轨drag、文本/候选锚点、Windows MTA UIA精确形状/移动后origin、关闭后立即free，native资源归零。
- Cairo/Pixman测试路径的7bit双线性系数误差仅应用于对应单级混色fixture，未把它扩大到所有pixel或任意nested场景。更多多级采样及DocumentEditor保留式TextClient的committedSpace桥继续。见[坐标合同](affine.md)与[渲染成本](affine-rendering.md)。

### G02 多级采样与保留式原生输入的提交门禁

- 更强的双级非整数变换 oracle 按每级 BGRA8 量化比较，确认硬件在一个2x混合像素重复应用 primitive 边缘 alpha：期望0x24000024、实际0x20000020。D2D 仅在 endTransform 的 bitmap composite 保存/切换 aliased AA 并恢复；父 clip 不变，未增加透明 padding、预算或通用容差。root Windows ReleaseSafe 四个渲染相关目标21/21步骤通过，Linux同一双级fixture与完整renderer亦通过；合并矩阵的一次重采样另被证明不等于分级输出。
- SpaceBinding 只跟随原 Context/Window/Region/workspace 中的稳定捕获 ID；新成功帧更新坐标，失败帧保留旧front，release/detach/recreate不复活旧授权。DocumentEditor 同一 TextClient 继续读唯一 Document，caret 从已提交映射转为原生候选锚点，不保留另一份编辑文本。
- Adapter.beginNativeInput 统一借用 Window/token/Space，嵌套调用保留原入口身份。原生变更在分配前及 Document 最终发布点分别验证 Window、实际 TextClient token、App 停机和原 Space；Document 的通用 CommitGuard 不依赖 UI。最终检查与 root/selection/version 发布之间无 foreign 操作，history/旧节点析构在提交后进行。
- 新正式反例先在 Document 自身 allocator 中撤 Space，实际得到错误但文档版本17→18；修复后拒绝本次提交，正文/选择/undo保持。Adapter allocator、Document allocator 内关窗/App.quit、撤 Space、嵌套授权、批量最终选区/OOM、提交后 foreign 另一次编辑均单独覆盖；后者返回 changed/index_required，不能重试已提交动作。
- 作者 Windows ReleaseSafe33/33步骤129/129纯测试、Linux29/29步骤117/117及实际原生均通过。root 固定583文件快照的 Windows 相关原生通过；Linux完整test/check为637通过、7平台skip，但2x发现两个fixture误把physical尺寸交给GTK逻辑paint。另建只替换这两fixture的快照，root独立ReleaseSafe2x两目标9/9实际通过、资源0，生产后端和断言未放宽。完整Windows编译的两次标准库读取Unexpected另保留日志复验，不记作全图已绿。

### T06 完整文档原生文本首片

- 可选 ziggurat_document_accessibility 使用同一显式 Reader 准备完整 UTF-16/scalar/grapheme/paragraph 快照；选择变化复用文本，几何来自同一 Adapter Prepared。双源各保留真实文档身份，统一差异的只读 ghost 不冒充可编辑正文，未绘制源不制造可见段落。
- MTA 只读独立原生不可变对象；短锁只保护 retain/状态复制，BSTR/SAFEARRAY 构造在锁外。Range按text stamp定位，不永久pin旧全文。辅助动作走固定16槽与App.post，owner再次验证revision/权限后只经唯一Adapter修改；关闭先撤业务context，迟到原生引用保持系统COM分配器与原子账本，末引用释放后归零。
- 默认identity几何首片支持完整GetText/Unicode范围、选择、可见段和显式宿主ScrollIntoView；未准备几何不伪造全文框。来源Adapter在首个foreign分配前全部pin，Geometry只随成功front提交，失败帧保旧；窗口移动只更新原生origin。
- 作者 Debug/ReleaseSafe各8/8步骤、5/5模型测试及真实CUIAutomation8 MTA客户端通过。root独立ledger3/3、store2/2、provider1/1和固定快照实际smoke通过；保留类型检查的ReleaseSafe发现并修正IUnknown/vtable错配，Provider与SAFEARRAY Range均返回真正IUnknown接口，未禁sanitizer。
- point range、真实空caret/仿射几何及完整语言单位继续实施；TextEdit/TSF/AT-SPI/macOS/完整语义树尚未验收，T06不标完成。见[完整文档辅助功能](document-accessibility.md)。

### T04.3 Snippet 与显式补全交付

- Template/Session 显式拥有有界模板和范围元数据，支持数字tabstop、placeholder、镜像、choice、多插入点、Tab/Shift+Tab和$0结束；没有第二份可编辑正文。Document.replaceManyWithSelections将正文与结果选区作为同一undo事务，所有候选/预算/选择验证在提交前完成。
- 首片 Windows Debug/ReleaseSafe与Linux Debug1x/ReleaseSafe2x各43项纯测试及原生Session smoke通过；root固定快照实际smoke同样通过。原生事件复用Adapter统一门禁，Document allocator中关窗也不提交；程序化start/edit仍由宿主显式传revision，IME或外部编辑撤销陈旧会话。
- 后续显式Completion.insertion.snippet把唯一模板编辑与额外字面edits一并展开；Broker拥有原始结果，Presenter显式enableSnippets才分配Session，独立Template在Session结束前稳定持有。提交后的layout错误进入CompletionOutcome/lastLayoutError，消费本次输入，不把已生效动作报成可重试插入失败。Broker服务stop后Presenter撤会话，普通Adapter仍可独立编辑。
- 该补全片作者Windows ReleaseSafe17/17步骤31/31、Linux Debug1x/ReleaseSafe2x各15/15步骤31/31及两类原生smoke通过，包含全部分配失败、额外edits一次undo、释放OwnedResult后的镜像输入、提交前/后重入、关闭/停机与布局失败；root独立固定快照Linux2x15/15、Windows组合37/37步骤及对应两种原生smoke均通过。语言协议、变量、regex与嵌套placeholder继续，父T04.3仍部分完成。见[Snippet合同](snippets.md)。

### P01c Linux 显式远程请求与页面寿命

- remote_pages已接实际View；Linux明确storage/credentials=ephemeral，宿主部署匹配的WebProcess扩展并传绝对原生代码目录。每个View独立不可变策略，先装发送前过滤，再核ABI/策略ID/PageID与bootstrap完成，之后才ready和首次远程请求。缺失与错误ABI实际均为零请求，错误码分别区分超时/身份/准备失败；普通HTML不加载扩展或分配RemoteData/握手timer。
- 最多32精确origin，navigation/request/IPC分别授权；实际method/header前置过滤及逐跳请求检查，HTTP只限显式回环。Windows和Linux的IPv4映射/兼容IPv6回环均要求opt-in；Windows原生URI反例先红后ReleaseSafe回归绿，DNS名称127.example.test不被当作回环。
- 构造式CSP与服务器CSP叠加，拒worker/WebSocket/frame/object/form等；服务器返回宽松CSP的实际HTTP夹具仍测得相关请求0。顶层重定向与脚本导航开关分别实测：禁止目标请求0、开启目标请求1；不将UI策略、CSP和扩展称为OS网络沙箱。
- root公开View ReleaseSafe1x与Debug2x实际通过：所有caller allocator故障、ready中立即关闭/零HTTP、来源独立IPC拒绝、显式导航、当前页refresh、reload、终止自有WebProcess后recover、新握手与旧PageId拒绝。页内fragment保持PageId/IPC且不新增服务器请求，整页加载才递增文档代数；全部迟到adapter/native refs归零。Linux纯WebView测试68通过、7平台skip，原HTML/custom/worker文件快照2x原生回归同样通过。
- 新增可选CI入口并解析YAML，本地等价检查已跑，远端未执行。Linux历史API、HTTPS本地站点、按需文件流、Region/PageSession及更广引擎环境继续，P01保持部分完成。见[页面策略](pages.md)。

### W04 显式显示器约束与状态恢复

- 新可选 window_placement 使用最多64个显式显示器快照，区分Windows物理桌面坐标与X11逻辑桌面单位；DIP客户区尺寸单独保存。连接器key仅为建议身份，缺失时按相交/最近/primary选择，完整外框约束在当前workarea内，最小尺寸放不下明确失败。
- Tracker仅从真实native client/frame和已确认normal状态采集；max/min/full不覆盖正常矩形，special回normal要求宿主confirmNormal。Restorer只由真实宿主事件推进，退出full、restore、max/full/topmost请求各一次；晚到观察继续waiting，不用固定重试或隐式pump猜测WM完成。实际client尺寸/位置和frame工作区包含关系均确认后才complete。
- Store使用调用方有界存储，严格版本/CRC/长度/保留字与重复key验证后单次替换；损坏、容量和编码失败保留旧值。Files只在显式worker执行目录句柄内的原子临时写入/flush/sync/rename，未默认选路径或在paint读盘；原子可见性不声称父目录断电持久性。
- 作者Windows Debug/ReleaseSafe各8/8步骤9/9纯及真实native、Linux ReleaseSafe1x/2x各7/7步骤9/9纯及真实WM通过。root独立快照Linux2x7/7、Windows组合37/37步骤45项纯及五类native通过，源码review无确认缺陷。包含负坐标/移除屏幕/跨坐标系/随机fit、每字节损坏、worker失败重试、真实创建销毁后重开、normal/max/full与普通/raw关闭后资源0。物理热插拔、真实混合DPI、变化订阅与其他平台继续；父W04保留部分完成。见[窗口恢复](window-placement.md)。

### T06 同一 Prepared 的点定位与真实 caret

- Adapter.preparedCarets显式导出已有视觉stop/affinity与line几何，不另shape或建文本副本；两遍容量预检，失败不改调用方输出。Unicode/组合/双向同X位置按Prepared相同lower_bound和前驱规则选择，空文档与末尾LF使用真实caret line。
- Windows RangeFromPoint在MTA只读独立native text/geometry，锁外精确选行与caret；单源Bounds使用真实viewport，双源只用实际可见line，filtered ghost不扩张到另一source。没有geometry明确NotSupported，退化range的BoundingRectangles仍为空，不制造字形。
- 独立typed ITextProvider2有真正vtable和统一IUnknown身份；GetCaretRange使用真实primary/focus，composition明确NotSupported，关闭后QI稳定而文本访问Unavailable。空文档VisibleRanges返回真实退化range，仍属于同一文本版本。
- 作者Windows Debug/ReleaseSafe及全部typed slots的strict UBSan通过；root独立第二阶段固定快照Windows ReleaseSafe13/13步骤、5/5模型及真实MTA/UIA和prepared geometry通过，另独立strict C/UBSan1/1通过。第一阶段Linux2x8/8步骤15/15纯与真实缓存caret oracle通过，最终refs0。仿射映射正在实施，完整语言单位、其他平台和TSF仍未完成。

### 第三份一致源码快照整图复验

- 固定583文件快照Windows ReleaseSafe开启WebView/GPU/UIA，串行复验test/check及本轮相关native共288/288步骤、652/657测试通过、5项明确平台skip。1000窗口records0/slots1，GDI12→12/USER6→6；9998条原生队列消息达到配额后已接受任务仍执行一次，WebView15App/99pending关闭后COM0。
- 首轮两处标准库文件读取Unexpected保留原始日志；项目源码和测试完全不变，仅改-j1复验后全部通过，未确认系统性根因，未修改工具链或禁类型检查。Linux同快照test/check为637通过/7平台skip，两个2x夹具尺寸问题在只替换夹具的独立快照9/9实际通过。
- 本快照不包含后续snippet补全桥、TextPattern2/点定位、窗口恢复、最新远程fragment策略与语言协议客户端；它们分别按后续独立证据验证，不用这一整图数字冒称最新工作树已全部验收。

### T06 成功帧的仿射文档几何

- Frame.coordinateMapping显式复制同一变换/凸裁剪值与Context/Window/Region/source/workspace代数；source候选仅随实际成功front提交。Bridge显式开启affine_geometry才分配固定双bank；paint只复制值，不shape、分配或建立原生对象。
- 原生文本/geometry/mapping同锁捕获后在MTA锁外查询，精确逆变换point并检查凸裁剪，字符矩形逐单元裁剪后才取系统AABB。count0明确不可见，无identity回落；缺record/新source/失败候选不制造几何。窄clip只露glyph内部时保留该真实行的全部caret候选，不要求caret本身落在clip内；退化range仍无字符矩形。
- 作者Windows ReleaseSafe26/26步骤99纯、Linux ReleaseSafe2x22/22步骤102纯及真实原生通过；严格C/UBSan2/2通过。root独立Windows Debug开启GPU/UIA为29/29步骤114/114纯和四类原生通过，资源归零。覆盖reflection/shear/旋转、fractional parent clip、双源、无renderer transform的offset/partial clip、同X bidi、窄clip反例、OOM/失败front/缺record/关闭与预热账本稳定。完整语言单位、Diff混合语义、AT-SPI/NSAccessibility继续，父T06未完成。

### P01d Linux 异步 custom 响应与显式文件泵

- 动态入口按需建立固定8槽，复用公开Responder/ResourceId/Book及单次deadline。立即响应、宿主worker准备的OwnedResponse和App.post交付共用验证/预算/取消链；未配置handler不分配动态状态。URI/GET/HEAD/头、CSP/no-store/nosniff先校验，HEAD保留真实表示长度而不读取正文。
- OwnedFileResponse.preparePumped仅在显式worker准备，返回独占response/pump。接受提交后才打开GET/HEAD gate；GET使用固定16KiB pread与有界socket背压。原生私有GInputStream/GPollableInputStream/GFileDescriptorBased只由MainContext readiness/idleSource推进，不创建隐藏I/O线程。读错误/截短通过流错误传播，不能以短EOF假成功；未启动pump也可取消。
- Candidate/Physical/control分离：失败提交保留response/pump；原生实际接受后才移动所有权。每View8、进程32物理流直到最后引用才返还，ticket不延长物理FD/预算；导航/reload/恢复/进程失败/close撤销control，迟到对象只保留独立原生状态。OwnedResponse在foreign allocator释放前先清空入口，避免重入重复free；资源诊断在业务completion前记录一次。
- root独立Linux ReleaseSafe公开动态5/5、Debug2x5/5均实际通过：动态start文档、立即/延迟响应、HEAD、404/timeout、私有524325字节文件、截短真实红→绿、已接受但未启动pump取消，以及资源回调中关闭后立即释放整个heap宿主，全部资源0。最终pure为69/76通过、7平台skip；普通HTML/custom与worker快照/进程恢复2x5/5、公开远程5/5、严格request扩展C检查亦通过。文件底层另有Debug/ReleaseSafe、真实async/零FD/OOM/截短及ASan/UBSan证据，见[页面策略](pages.md)。不据此宣称HTTPS本地站点、PageSession/Region或完整网络沙箱完成。

### 缓存维护与 WSL 构建位置

- 新增Windows/Linux预览优先清理脚本，仅选择识别缓存根的生成目录；保留源码检查点、日志、依赖、输出和镜像，拒绝活动构建并在删除前复查。两端预览、语法和独立只读review通过；正式预览夹具分别验证普通生成目录、检查点保留、子链接与缓存根链接保护，没有执行删除。Linux跳过无法检查Windows进程的共享DrVFS缓存；本轮未执行Windows删除。
- WSL旧项目缓存已由约21GiB降至1.6GiB，C盘即时可用容量仍约15GiB，未把ext4内部空闲冒称宿主回收。D盘DrVFS上的构建器rename失败独立重现后，改为D盘16GiB有界ext4镜像；最终语言/辅助功能/WebView真实构建已通过。检查入口共用显式缓存配置，挂载恢复与清理命令见[构建缓存](build-cache.md)。

### T04.3 显式语言客户端与版本化交付

- 新可选模块拥有有界Content-Length/JSON-RPC、UTF-16/CR/LF/CRLF Map、initialize/initialized、full/incremental同步、completion/hover/versioned诊断，以及cancel/epoch重启。一个URI/服务逻辑通道共享唯一Document/Broker；不启动进程、线程、IO、timer或App任务，宿主显式worker承担扫描/编码/转换与运输。
- prepare、宿主受理Packet、owner commit分开；Full/Closed/编码失败不提前推进同步版本，已受理后文档变化返回stale但保留真实已发送stamp。无版本诊断、其他position encoding和未实现的编辑语义明确拒绝，不以到达时Doc版本补造诊断版本。旧epoch撤销logical显示，物理Work/Sync/Transport/Delivery直到各自最终归还才返槽。
- 复审补齐三处边界：编码writer在进入第129层或超过body时立即停止，避免先触发Stringify固定深度assert；SyncWork.close遇独立Reader时保留Snapshot/计数，释放额外Reader后可重试；所有reservation乘加在已验证1GiB预算内逐项预检，32位usize也不先溢出。三者均有实际拒绝/重试或零分配回归。
- root独立Windows ReleaseSafe四目标17/17步骤、Linux Debug2x四目标15/15步骤，各46/46纯及实际协议/旧编辑器native通过；协议fixture真实启动两个子进程epoch、五个请求，并验证Unicode增量、snippet原文、hover/版本诊断、取消/迟到、queued-stop、满队列与Closed，最后资源0。没有把fixture当作生产语言服务器全扩展验收。工作区、动态注册、resolve、宿主graceful shutdown和完整snippet语法继续，父T04.3仍部分完成。见[语言协议](language-protocol.md)。

### G01.5 同式 tspan 与字符定位 chunk

- 显式准备的Unicode scalar模型在XML空白规范化后消费祖先x/y/dx/dy列表，最近有效列表优先；同式span本身不打断shaping。首字符或绝对x/y创建chunk，每个chunk按真实系统advance、方向和anchor定位，聚合轮廓与完整glyph-cell边界；省略轴保留当前文本位置。
- source/chars/position/chunk/work及临时Plan/旧候选/字体产物受同一场景预算约束。单chunk直接接管已有产物；无span的cache不复制整份Style。paint不解析、整形或分配。midchunk非零相对调整、非零rotate、跨font/paint/visibility与span自有效果明确拒绝，不能用逐字符shape伪造复杂文字。
- 作者最终Windows GPU ReleaseSafe9/9步骤、Linux8/8，各98/98纯与真实native通过。root固定621文件后只overlay12个SVG路径，独立Windows GPU ReleaseSafe14/14、Linux ReleaseSafe2x12/12，各98/98纯、GDI/hardware/WARP/Cairo原生和最终资源0。覆盖kerning/ligature/Arabic/combining/ZWJ、祖先覆盖/绝对chunk/RTL、full-cell渐变/clip/mask、两模式/三DPI、所有候选OOM/取消/lease。隐藏父text中的可见子span曾被静默忽略，正式反例先红后明确Unsupported，整段hidden仍零字体请求；未放宽生产像素断言。
- 完整glyph/cluster轮廓映射、混合样式、textPath/基线族和完整SVG文本仍继续，G01.5保留进行中。见[文本定位合同](svg-text.md)。

### T04.3 嵌套 placeholder 与显式变量

- 同一有界 parser 处理平面、嵌套默认值和变量选择分支，展开结果为拥有型模板与父子范围森林。子项编辑更新祖先和全部镜像，父项替换撤销相交子项；每次动作仍只提交一次 Adapter/Document 事务和一条 undo。定义依赖环、指数展开与深度/节点/出现位置/字节/工作预算在发布前拒绝。
- Resolver 由宿主显式传入，每个实际需要的名字只调用一次；ValueWriter 只产生字面字节，区分空值、unset 与 unsupported，不隐式读取环境、文件、时钟或剪贴板。取消检查覆盖最后一次 foreign AST/source free；Session 准备期 Busy，Presenter 保持独立 Session client，其 Adapter pin 穿过自身最后一次 foreign free。
- 作者 Windows/Linux 的 Debug/ReleaseSafe 各四目标通过，每组52项测试执行及两个真实原生检查，资源0。root独立621文件快照 Windows ReleaseSafe17/17步骤、Linux Debug2x20/20步骤均为52/52；后者另验证真实远程页面。包含父子/镜像/Unicode/多光标、单次undo、全分配失败、resolver取消/独立编辑/关窗/退出，以及最终shell释放回调仍不能关闭Adapter。
- regex/format、unknown变量自动placeholder、nested $0、活动会话嵌套与每cursor独立变量环境继续明确拒绝；父T04.3仍部分完成。见[Snippet合同](snippets.md)。

### 第四份一致源码快照整图复验

- 同一621文件快照 Windows ReleaseSafe开启WebView/GPU/UIA，test/check与相关native共315/315步骤、698/703测试通过、5项明确平台skip。1000窗口后records0/slots1，GDI12→12/USER6→6，9998条原生队列消息达到配额后已接受任务仍执行一次，WebView15App/99pending关闭后COM0；异步响应/文件、仿射绘制/输入/文档、UIA/caret、SVG、语言协议、窗口恢复和snippet原生检查通过。未把check内仅编译的其他native目标算作运行验收。
- 固定621文件快照 ReleaseSafe、WebKit开启、隔离Xvfb/2x及私有引擎挂载环境，test/check和协议、HTML/custom/动态/远程页面、SVG文字/栅格、编辑器、仿射绘制/输入/文档、prepared caret和snippet原生检查共174/174步骤，686/693测试通过、7项明确平台skip；相关原生资源归零。源码清单SHA256复核一致，未用活动工作树冒充该快照。
- 首次远程检查揭示相对 --prefix 的安装目录未经绝对化便传入原生扩展配置；原目录校验正确拒绝。旧快照以绝对prefix完成整图复验；build将安装路径显式基于工程根解析的修复，在后续snippet快照使用相对prefix运行真实远程检查通过，没有放宽目录校验或禁用请求扩展。
- 本整图不包含后续SVG隐藏父项/可见子项拒绝修复、嵌套snippet、Diff可访问桥、paint-order与Linux历史导航。前三项各有独立固定快照证据；后两项继续实施，不把整图数字推广到未验收新源文件。

### T04.2.4 可编辑 Diff 的双源文档语义

- 新可选 companion 复用原有两个 Document/Adapter 和唯一 Diff coordinator，保留完整独立 UTF-16 文本身份；统一模式的A只读且不获输入，只有实际删除行导出A几何，common/隐藏A不伪造可见矩形。组合期间不把overlay字节当committed文本。
- copyPresentation显式拷贝有界可见行与非回绕epoch，绑定comparison serial、双方文档/投影/视图版本。两侧候选geometry及辅助动作epoch仅在成功front同锁发布；MTA只读独立原生快照，旧queue在native take与owner coordinator两侧再次验证。选择/焦点/滚动复用coordinator，Doc候选分配后的最终guard检查窗口和另一份文档；提交后的布局错误作为outcome，不重发选择事务。
- author Windows Debug/ReleaseSafe实际MTA、旧Doc UIA/完整Diff矩阵及strict C/UBSan3/3通过。root独立625文件快照 Windows Debug开启GPU/UIA共41/41步骤、72/73测试通过1平台skip；Linux ReleaseSafe2x共26/26步骤、38/39通过1平台skip。新paired UIA、旧Doc UIA、完整Diff/仿射文档/prepared caret/嵌套snippet编辑器原生资源均归零。Linux对新companion明确Unsupported，未据此宣称AT-SPI完成。
- 回归覆盖真正A删除行offset及group命中、empty/terminal-LF caret、跨source range拒绝、已换comparison但未换native front、failed front、组合/disabled、全分配失败、Doc Busy allocator内关窗拒绝提交，以及最终shell foreign free期间coordinator保持ClientsAlive。只对实际折叠/不可见caret准备衍生布局，普通多选不逐项重复prepare。
- hunk/revert与fold控件、旧只读View、仿射Diff输入/语义和其他平台继续实施，父T04.2.4/T06未完成。见[Diff辅助功能](document-diff-accessibility.md)。

### G01.5 填充与描边的显式绘制顺序

- SVG paint-order 使用固定三槽保存 fill/stroke/markers 的唯一顺序，省略操作按默认顺序补齐；两种合成模式共用解析后的顺序。fill/stroke 的既有几何与颜色逻辑不变，元素和分组 opacity、clip、mask 仍在操作外只应用一次。markers token 不引入 marker 元素或引用支持，它们仍明确拒绝。
- 继承、重置、presentation attribute、stylesheet/inline 与 important 沿既有 cascade；属性容量由枚举项数计算。单实例同式文字填充与描边共享一次完整 shaping，不按字符拆分；span 的顺序变化包括缓存命中时仍明确拒绝。跨 use 的含 span 完整样式键变化仍可能重新准备，不声称所有实例都不增加字体请求。
- root 固定626文件快照 Windows GPU Debug14/14、Linux Debug2x12/12，主树 Windows GPU ReleaseSafe14/14，每组104/104纯测试及 GDI/hardware/WARP/Cairo 实际回放通过，资源0；固定快照清单 SHA256 复核一致。另经独立源码审查和缓存探针，三个无span/相同span样式/不同span样式组合的实际请求数为1/1/2。
- 逐像素对照独立 fill/stroke 元素 oracle，覆盖全部排列/部分列表、半透明重叠、渐变、分数裁剪、mask、元素/分组透明、RTL/ligature、两模式/三DPI及所有候选分配失败。未知/重复/混合normal等输入拒绝，G01.5和完整SVG继续实施。见[SVG](svg.md)及[文本定位](svg-text.md)。

### T04.3 有界 snippet 变换与原子 Tab 提交

- 独立拥有型 regex/format 程序保留 UTF-16 capture 与显式 Unicode scalar 推进，不导入脚本或原生正则运行环境。一次反向可达表供整次全局匹配共用；有序 trace 保留选择优先级、贪婪/惰性及 capture 清除。source/指令/类项/输出/工作量与候选峰值均有硬上限，nullable 重复、回溯引用、lookaround、Unicode case 等未实现输入明确拒绝。
- format 支持 capture、条件/非空 else 和 ASCII case 子集；变量在模板准备中按显式 resolver 的字面结果变换，placeholder 按每个 occurrence 的实际文本在离开 tabstop 时变换。Session 默认不建 Runtime，opt-in 在 create 预留固定 workspace/input/总结果缓冲；Tab 不从会话 allocator 分配，先准备全部编辑、祖先/镜像范围与下一组选区，再通过唯一 Adapter 提交一条 undo。不同长度镜像的再次全选编辑使用各自完整范围，未改变正文则只更新选择。
- 编译/变量候选取消贯穿最后 foreign scratch free；Session 取消限于进入 Adapter 事务前的变换准备。提交沿用原 Doc 版本/窗口守卫，提交后独立修改报告 committed+stale，不重发业务操作，也不安装第二个事务门。
- 作者 Windows/Linux Debug/ReleaseSafe 各四目标通过，每组90项测试执行及两个真实原生编辑器资源0。root 固定632文件快照 Windows ReleaseSafe25/25、Linux ReleaseSafe2x22/22，均112/112（37项snippet、53项编辑器、22项语言协议），包含实际补全/Tab/不同长度镜像、撤销/IME、Doc候选分配时关窗、提交前后foreign编辑与两个子进程epoch。独立原生RegExp oracle另通过3984组匹配/capture与8032组替换，未把它们当作全部语法兼容证明。
- 仅 leaf source 支持 placeholder 变换；更广 format、Unicode case、workspace与其他语言服务能力继续实施，父T04.3未完成。详见[Snippet](snippets.md)。

### G01.5 单连续文本块的长度拉伸

- 根 text 的显式 textLength/spacingAndGlyphs 在一次完整 shaping 后，原位变换轮廓的全部控制点与完整 glyph cells，anchor 使用目标 advance。y、字号和 user-unit stroke width 保留，不拆 kerning/ligature/Arabic/combining/ZWJ，也不为该调整建立另一份几何数组；同式 span 和相同 use 仍走既有缓存。
- 负长度、非法 keyword、默认 spacing、百分比、后代自有长度和多个绝对定位 chunk 明确拒绝；后四类在首个字体请求前失败。零自然 advance 不能扩为正长度，正比例下溢/非有限比例及转换后的坐标越界明确失败。系统轮廓支持全部既有命令；自定义 provider 的 quadratic 也支持，arc 仅接受恒等缩放，非恒等返回明确错误，不近似改写。
- root 固定629文件快照 Windows Debug GPU14/14与Linux Debug2x12/12，各110/110测试及GDI/hardware/WARP/Cairo真实回放通过，资源0；主树先前Windows ReleaseSafe同组三目标14/14通过。独立源码审查未确认阻塞，最终固定清单SHA256复核一致。
- 独立系统原轮廓生成path oracle，覆盖48/96目标长度、复杂文字、描边/paint-order、渐变/分数clip/mask/组透明度、两模式/三DPI；纯回归另锁RTL全部anchor、Bezier控制点、完整cell而非ink边界、零长度、use复用、极小比例及全分配失败。Linux首次正式红由oracle把仿射平移拆成两次相减引起；只统一oracle的仿射运算分组后严格逐像素转绿，生产源及阈值未改，旧快照保留。
- 完整spacing、nested/multi-chunk textLength与逐glyph定位映射继续，G01.5未完成。详见[文本长度合同](svg-text.md#单块文本长度)。

### 本地构建缓存维护

- Windows/Linux 提供独立预览优先清理脚本，只选择已登记缓存根内的生成目录，跳过链接、检查点、日志、工具链、SDK和安装产物。删除前重新检查活动编译器/缓存程序、目录链接和时间；Windows不能枚举WSL内编译器，因此任何发行版运行时拒绝删除，Linux跳过无法核验Windows进程的DrVFS共享缓存。调用者仍须停止所有相关构建，脚本不提供构建锁。
- Windows预览夹具实际验证普通候选、检查点、子junction和根junction保留；Linux隔离夹具验证对应链接边界，默认预览不删除哨兵。Windows执行删除分支本轮未运行，不将预览算作删除验收。
- WSL检查使用项目盘的独立16GiB ext4缓存镜像，缺挂载明确失败；既有镜像不重格式化，挂载验证镜像身份。普通Linux沿项目本地缓存；各并行任务有独立local cache并共享显式global。C探针、扩展与运行期数据写入项目managed目录，不继续向SDK用户目录追加编译产物。
- 构建及两端清理入口见[缓存合同](build-cache.md)。释放Linux文件系统空间不等同宿主系统盘立即回收，不自动关闭WSL或压缩其系统磁盘。

### T01/G01.5 可选原布局字形映射

- Layout 的显式 include_mapping 导出真实 glyph/run/bidi、UTF-8 cluster 范围、pen/origin/signed advance、完整 cell 和逐 glyph 轮廓范围；保持原系统枚举顺序，不用字符均分、ink 邻近或再次 shaping 推断关系。DirectWrite 使用原 description 的 UTF-16 clusterMap，Pango 使用原 GlyphItem/log_clusters；逻辑 source 与视觉 glyph 顺序不强求相同。
- 映射拥有独立 Path/source/metadata，不能把其 ranges 配给原批量 Path；源 Layout/Engine 可先关闭。默认仍用原批量路径，不分配映射数组或增加映射查询。逐 glyph 与批量字体轮廓存在原生浮点分组差异，两种表示分别校验，不声称逐命令或逐像素恒等。
- 所有旧/候选数组、批量及映射 Path、源文本、临时排序/转换共享 bytes/commands/work 上限。正式 CancelOnFree 反例确认最后 scratch free 可以请求取消；修复将全部临时清理移到最终取消检查前，每个 default/mapping 预发布 free ordinal 均有回归，失败不发布半个 Shape。
- 作者 Windows/Linux Debug、ReleaseSafe 的三个原生目标全部通过。root 固定635文件快照 Windows GPU ReleaseSafe37/37、Linux Debug2x30/30，各110/110纯测试及真实 text-layout/clusters/outlines/cells、SVG、代码编辑器和完整 Diff 检查成功；GDI/hardware/WARP/Cairo 三 DPI及最终资源0。独立原生 C oracle覆盖40组系统布局、UTF-8覆盖、真实glyph位置/segments，另覆盖全部候选OOM、共享峰值/工作预算与取消。
- CI加入显式 smoke-text-clusters；此处记录本地验证，不宣称远端CI已经运行。SVG定位的映射consumer、混合样式/textPath及完整文字能力仍继续，G01.5保留进行中。见[系统文字轮廓](text-outlines.md)。

### T04.2.4 同一文档原生根的有界辅助控件

- 可选 auxiliary plan 保存拥有型 label/role/key/父子关系，在准备阶段分配；Frame 只记录实际画出的节点/有界几何与状态，不借 Frame 或 native query。成功 front 将两个正文 geometry、控件 plan/geometry 和非回绕 presentation epoch 同锁发布；缺少实际记录则撤辅助树，失败帧保留旧 front。
- Windows 同一原生文档根下导出 A/B 全文及 Tools/Action 子树，真实 CUIAutomation8 MTA 经普通导航找到同树控件并执行 Invoke/ExpandCollapse。provider 的完整稳定 key 不截断，角色决定固定 QI pattern；失效对象返回 unavailable。MTA 不访问 Document/Adapter/UiContext；动作经版本、窗口 enabled/modal、组合与 owner handler 验证。默认 auxiliary=null 不分配额外 bank 或查询原生控件。
- 当前 plan/provider 的 State 引用环由 disconnect 显式拆除，最后引用不依赖历史表。root审查发现 generic Bridge.close 先撤 Source Adapter pin 的实际反例：scratch及最终shell free的重入能提前关闭源。修复将两个源引用保留到全部scratch、shell和native account最终释放之后，destroy后只使用栈副本。正式红日志保留；关闭返回后两Adapter可成功关闭，证明未滞留引用。
- root固定630文件首版 Windows GPU/UIA ReleaseSafe33/33、102/103测试通过1平台skip；Linux ReleaseSafe2x14/14、90/91通过1skip及完整Diff原生资源0。只overlay最终pin修复两文件的第二份630文件快照，Windows同配置12/12步骤、6/6纯与新旧真实UIA成功，scratch/final均观测ClientsAlive，资源0；Linux7/7步骤、7/8通过1明确平台skip。清单SHA256复核一致，Linux未实现AT-SPI。
- hunk/revert、上下文折叠业务与单一焦点交接继续实施；本片不把auxiliary技术动作当作完整Diff控件。父T04.2.4仍进行中，见[Diff辅助功能](document-diff-accessibility.md)。

### P01 显式历史事务与当前文档恢复

- Linux本地/远程页面直接观察真实BackForwardList、URI和loading，不维护影子历史表。拥有型单次导航事务绑定非回绕serial、目标URI/原生item和阶段；same-DOM返回保持PageId/private IPC，跨文档在policy接受前撤旧文档，异常STARTED失败封口。HTML默认路径不建立历史分配。
- initial URL与有界owned current URI分开；refresh使用已提交当前地址。正式原生反例确认host导航受理后在STARTED前stop会撤IPC：此时没有可信文档或活动事务的same-DOM back返回NotReady，明确完整host导航可恢复。没有依据未复现的URI假设增加补丁。
- 独立实际WebKit事件探针覆盖21步骤/5个DOM/5对started-completed，区分pushState、同DOM与跨文档back及refresh。作者Debug/ReleaseSafe和1x/2x、旧HTML/动态/远程检查通过。root固定628文件快照 Linux ReleaseSafe2x117/117步骤、70/77通过7平台skip及四个实际页面目标全部资源0；Windows GPU/UIA/WebView ReleaseSafe243/243、72/77通过5skip，1000窗口records0/slots1、GDI12→12/USER6→6、原生队列9998消息配额下已接受任务一次、15timer ticks与15App/99pending COM0。check仅编译的目标不算运行。
- 页面区域、HTTPS本地来源和更广平台策略继续，P01未完成；见[页面合同](pages.md)。

### T04.3 显式工作区与发送提交

- 可选工作区拥有rootUri/文件夹名称和URI的不可变快照，区分null与空文件夹；只按解码后的完整路径段选择最长显式folder，不读取文件、不推断安全归属。路径/URI转换先验证和准备候选，再写调用者缓冲；拒绝歧义authority、编码分隔符、dot段和非法UTF-8。
- 初始化、差集变更与反向workspaceFolders查询均分开capture/worker prepare/host queue/owner commit。变更的线性send scope在host受理前同时保留Client与Broker门，预检phase/epoch/基版本/取消/代数上限；Full/Closed/end保持旧workspace、显示和Packet。受理后一次commit发布新版本、撤所有旧stored/current并取消Job，foreign析构前已逻辑失效，不能在accepted之后再报Busy/OOM导致新旧策略分叉。旧物理lease仍须各自归还。
- 反向请求在worker释放JSON Message，仅以有界owned产品和原始请求ID跨线程；共用固定incoming容量，Full/Closed保留责任。已知静态workspace注册可撤销，其余方法明确MethodNotFound；旧epoch或旧workspace不得影响新状态。rootUri/单文件模式变更要求显式restart再cold reconfigure。
- 作者Windows/Linux Debug、ReleaseSafe每组35协议+54编辑器=89/89，真实旧/新child、反向query、App.post Full/Closed及最终资源0。root固定638文件快照 Windows ReleaseSafe22/22、Linux ReleaseSafe2x19/19，各89/89及实际协议/代码编辑器/snippet通过；两个旧child epoch/5请求、新workspace流程/3反向响应、不可变快照、重启与资源0。父T04.3仍部分完成，配置、resolve、graceful shutdown和更广能力继续，见[语言协议](language-protocol.md)。

### P01 独立矩形页面区域

- Linux View.attachRegion复用唯一核心composition Owner/Region，每个真实WebKitView保留独立DOM/页面代数。首个区域建立共享GTK overlay，保留原drawing area/IM与backdrop，末区域撤离恢复原area；普通全窗路径不建立region layer，区域与独占host互斥。宿主/layer/NativeWindow的物理引用覆盖最后GTK释放及重入，先撤入口、后析构，不保存历史宿主表。
- 更新仅提交显式矩形/显隐，不使用View allocator或重建文档。物理边缘先舍入，再按原生整数scale向外量化GTK逻辑边界；负坐标/分数边缘/空区域都有独立实际几何回归。混合Tab/输入法、任意裁剪、跨宿主保DOM的PageSession和AT-SPI仍未完成，regions capability不代表这些能力。
- 正式最后scratch-free关窗反例先红后修：初始普通/区域attach在全部临时释放后再核attachment/stopping，错误回收native候选和各类budget，不返回成功。独立审查确认ZLG和ZWK的INVALID/OOM枚举不同；隐藏区域focus实际返回值反例先红，现create/viewport/focus统一显式转换。两处旧源与红日志均保留。
- 原生GTK夹具12轮双子项、精确geometry/IM身份、候选OOM、重入detach/visible与raw parent close均通过，GCC ASan及1x/2x最终资源0。公开fixture涵盖两DOM/变量与PageId保留、无分配move/hide/empty、显式callback pin撤离、旧槽代数、候选OOM、peer身份、pending normal/raw close，以及HTML/custom四种最终free关闭。夹具以安装时显式身份标记选原生child，不按页面title/位置猜归属。
- root固定642文件最终副本Linux ReleaseSafe2x28/28步骤、70/77通过7明确平台skip，HTML/custom、动态worker文件、远程扩展、历史、新区域与1000次composition复用均资源0；Windows ReleaseSafe16/16、72/77通过5skip，15App/99pending COM0及旧page路径通过。相同Windows生产源的composition/GDI双页面另9/9通过；其首次运行业务/COM成功但fixture在10秒未确认外部Runtime退出，原日志保留，单独同源重跑通过且未改等待时限。首次区域副本有未定位断言失败，后续增强身份/几何诊断后的最终副本通过，不将首轮算通过。
- 全部最终源码清单SHA256复核后按本片验收，CI加入可选原生区域目标；远端CI未执行。完整P01/H02/H03继续，见[页面区域](pages.md#原生页面区域)。

### T04.3 显式配置与诊断来源

- 独立 worker 准备不可变 JSON 配置，保留原数字字节；scope URI/section 使用精确 tuple 匹配，不从路径、工作区归属或点号推断继承。缺省与空字符串有区别，未匹配返回 null，拒绝重复 JSON 键和重复 tuple。默认未启用时没有新增配置快照或能力声明。
- 配置变更复用工作区的固定产品/控制槽，反向 query 复用同一 incoming 容量。接受发送前保留 Client/Broker 两个门；Full/Closed/end 保留旧配置、显示和 Packet，接受后一次提交先撤旧逻辑结果，再释放外部资源。配置快照、所有旧请求/同步/交付携带原 epoch/workspace/config stamp，旧物理槽不会提前复用。
- 新配置接受后，显式更高 server_version 的同步成功才恢复诊断和语言请求；旧同版本诊断不能在到达时套用当前配置。超预算 prepare 精确失败，宿主可选择同一 incoming 显式 InternalError，仅回复原 string ID 一次；不隐藏额度失败或另开池。
- 作者四种 Windows/Linux Debug/ReleaseSafe 配置均通过99/99纯与实际子进程；root固定644文件快照 Windows ReleaseSafe17/17步骤、Linux ReleaseSafe2x15/15，各45协议+54编辑器=99/99，真实两个配置epoch的pull/push/re-pull/重启、更高版本同步、旧诊断拒收和配额失败响应均通过，原编辑器/旧协议资源0。全部清单SHA256复核一致。resolve、graceful shutdown与更广语言能力继续，T04.3仍部分完成，见[语言协议](language-protocol.md#显式配置与来源版本)。

### G01.5 连续布局的字形定位消费

- 同式单chunk的dx/dy/rotate使用原系统glyph/cluster映射，按逻辑source累加位移、按真实signed advance定位与anchor，再对完整cluster做刚性旋转；不按scalar重新shape、不均分advance。cluster内后续scalar的dx/dy移交下一cluster，rotate按有效列表首项及元素尾值重复规则处理。
- 映射Path独立拥有，完整cell四角保留到外层affine之后再求并集；系统批量Path、映射副本、scalar/pose/排序/候选与foreign scratch共存进入同一峰值/工作账本。普通文字、零旋转和完整圈数不请求额外mapping。最终foreign析构之后在Document/Provider物理pin仍有效时复核取消，不发布已取消图片。
- 作者Windows/Linux Debug/ReleaseSafe四矩阵均120/120纯，原生两模式/三DPI/GPU和全候选OOM/取消通过。root独立648文件快照 Windows GPU ReleaseSafe9/9步骤、Linux Debug2x8/8，各120/120；真实Windows6组接受，Linux5组接受/1组明确cluster拒绝，最终资源0。全部清单SHA256复核一致。anchor负位移疑点经标准算法核实撤回，仅补固定数值回归，未作生产修补。
- 混合bidi、不能证明的grapheme/cluster关系、多绝对chunk与mapping/textLength组合明确拒绝；拒绝不计作绘制成功。混合样式/textPath/完整spacing继续实施，G01.5仍进行中，见[文本定位](svg-text.md#连续-shaping-的相对位置与旋转)。

### G01.5 单连续文本块的字距长度调整

- `textLength` 的默认或显式 `lengthAdjust="spacing"` 使用同一系统 Layout 的真实 cluster；先累计 dx/dy，再按逻辑源序分配带方向的长度差，最后按调整后 signed advance 区间执行 anchor 和刚性旋转。字形轮廓与原 advance 不缩放，不按字符重新排版，也不平均原字宽。零长度与跨序压缩保持原字形；单 cluster 只有目标等于原长度时接受，否则明确返回 `UnsupportedTextLengthSingleCluster`。
- 沿用既有 pose/排序和有界工作账本，没有新增逐帧排版或独立映射分配。普通无调整文字保持原批量路径；spacing 显式要求 Mapping。所有候选 OOM、每次临时释放触发取消以及最后 foreign free 均验证回滚和资源归零。多绝对 chunk、混合 bidi、nested textLength、混合样式和 textPath 继续保留明确边界。
- 独立审查未确认生产缺陷；补齐原生 oracle 中相对 dx 对 anchor 区间的独立计算，并新增非零首 dx/内部 dx、压缩、RTL/旋转组合。纯测试增加固定数值的 LTR/RTL、三种 anchor、展开/压缩，以及非均匀和零 advance、反序存储三个 cluster，避免以生产公式生成期望值。
- root 固定652文件副本，最终 Windows/Linux Debug/ReleaseSafe 均124/124纯测试通过；Linux Debug 使用独立本地缓存确认最终新增用例。相同生产与原生夹具的前一副本 Windows GPU ReleaseSafe9/9步骤、Linux Debug2x8/8步骤通过，各123/123；真实Windows13组接受，Linux12组接受/1组明确cluster拒绝，双模式/三DPI及GDI/hardware/WARP/Cairo回放、全候选OOM和最终资源0。最终副本仅增加一个纯测试文件，清单SHA256核对一致，完整G01.5仍进行中，见[文本长度合同](svg-text.md#单块文本长度)。

### T04.3 显式补全详情解析

- 显式启用后才保存拥有型 continuation，绑定不可回绕 source/服务epoch；原始data、未知字段和数字lexeme保持。worker只使用请求创建时捕获的策略与不可变数据，不能读取重启时可变的capabilities。默认路径不建立continuation存储，不自动发请求、创建线程或解释command。
- ResolveWork与普通请求共用固定物理pending槽，不新建Broker Job/Reader。候选仅允许选中项detail/documentation变化，原编辑、snippet、顺序和其余字段由无损JSON比对及Broker类型化比对共同约束。独立Presenter值身份、选择/popup代数、完整Doc revision、IME、宿主输入门、epoch/workspace/config和显示来源阻止A→B→A及迟到结果覆盖。
- owner采用时先发布新元数据再释放旧结果，Client/Broker/Presenter及Window/Adapter的门覆盖最后foreign free；已发布后回调编辑用published/stale_after_commit报告。App.post Full/Closed仍保留Delivery责任，Presenter Busy允许显式重试；关窗后可传null回收，不保存异步Presenter指针。每槽预检旧/新结果、两棵JSON树、Packet和scratch的共存额度。
- 作者Windows/Linux Debug/ReleaseSafe纯与真实child检查通过；root固定655文件快照Windows ReleaseSafe29/29步骤、Linux ReleaseSafe2x25/25步骤，各53协议+56编辑器+37snippet=146/146。真实8次resolve涵盖原数据往返、选择/失焦/IME/Doc/只读修改拒绝、关闭、满队列、Busy重试、最终free重入，以及原snippet单事务undo；旧协议、工作区/配置和编辑器全部资源0。另一个只读reviewer独立109/109纯测试通过，无确认生产问题；最终15文件及快照SHA256复核一致。
- CI接入真实resolve目标，此处仅记录本地验证，远端未执行。详情展示、延迟edit/command、graceful shutdown和更广能力继续，T04.3保留部分完成，见[语言协议](language-protocol.md)。

### T04.2.4 有界 hunk 与上下文业务控件

- 调用者显式提供稳定Controls工作区、工具栏几何和可见hunk，prepare在paint外构建双bank的有界节点/label；Frame只回放真实button/semantic，成功的native front才授权动作。typed revert/context意图统一进入Diff协调者，原Document/Adapter仍是唯一文本、选区、IME和undo所有者，业务变化与后续展示失败分开报告。
- Pointer、Tab/Space及UIA动作共用窗口/disabled/modal/composition/Doc/比较serial/展示epoch和真实源选择门。控件接管前撤真实text client，正文接管前撤控件焦点；只读physical client查询保持单一输入权威。UIA SetFocus在owner执行，未知C flags拒绝，旧节点保留接口身份但不能操作新front。
- 首片辅助节点总数65、两份label各4KiB、固定hunk/context上限均进Bridge预算，默认未启用不建工作区。实际发现的Progress pointer资格和大group遮挡正文命中问题分别由正式回归修复，没有增加paint分配或扫描历史宿主。
- root固定652文件Windows GPU/UIA/WebView ReleaseSafe303/303步骤，786/793测试通过7平台skip；Linux ReleaseSafe2x162/162步骤，776/784通过8skip。真实旧/新Diff、输入路由、四类范围控件、完整UIA、仿射文档、窗口/页面生命周期与关闭资源0；Windows1000窗口records0/slots1、GDI12→12/USER6→6。此为该固定副本验收，不代表之后新增切片已在同一完整检查中运行。
- 作者曾在大型矩阵观察到两次未定位Tab焦点失败，保留失败摘录，未改等待/断言或做推测性生产修补。最终仅增加固定64项POD消息/输入诊断ring的独立652文件副本，root Windows ReleaseSafe8/8步骤、3/4纯通过1skip及完整5个场景真实UIA/业务控件成功、资源0；所有原始21文件及最终单fixture哈希核对。该通过不能证明旧偶发失败原因已解决，继续保留回归跟踪。Linux AT-SPI、更广快捷键scope与完整T04.2.4仍继续，见[Diff辅助功能](document-diff-accessibility.md)。

### T04.2.5 真实源 caret 与当前 hunk 查询

- `activeSide()`保留最后成功绑定并同步caret的编辑源，默认B、unified始终B；blur/工具栏焦点不改变来源。`cursor()`直接查询唯一Document的primary caret、UTF-8 byte、LF逻辑行及UTF-16列、revision/text_version，不要求prepare，不从可见行、ghost或手选hunk推断。
- `currentHunk()`只借当前fresh比较，基于源逻辑行做upper-bound二分。非空范围半开，零侧hunk归插入行；无尾LF的EOF零侧折到真实terminal caret行，同有效起点取结果顺序最后项。before-first/空比较返回null，after-last保留末hunk并inside=false；stale比较明确ComparisonRequired，cursor仍可查实际Doc。窗口/App/Inbox关闭、Busy/错误线程及双方IME保留明确门禁。
- 查询不分配、不shape、不扫描可见行或全文件，也不修改选区、焦点和scroll。源坐标查询使用Document聚合树与有界叶，hunk元数据二分；65536项最多17次比较。原生夹具1024轮三查询在allocator拒绝时没有分配尝试或额外排版，覆盖reverse/multi primary、emoji/CRLF/空文档/EOF、ghost与手选分离、fold/wrap/scroll、失败focus及close重入。
- 作者Windows/Linux Debug/ReleaseSafe四配置各36/36纯及新旧完整Diff原生通过。root固定657文件副本Windows ReleaseSafe17/17步骤、94核心+36Diff=130/130，Linux ReleaseSafe2x15/15步骤、93核心+36Diff=129/129，新caret及旧split/unified/intraline/context/fold/IME/OOM/失败帧/关闭均资源0。另一只读review核对全部5文件、底层树查询及EOF有序性，无确认问题；清单SHA256一致。CI已接真实caret目标，远端未执行。typed语义命令和Find仍待后续片，T04.2.5保留部分完成，见[Diff文档视图](document-diff-view.md)。

### W01/H01.2 dispatcher 退出与迟到清理

- accepted post内quit后，dispatcher继续排空已接受任务，将deferred Window/Cleanup留给统一shutdown，固定accepted→Stop→detach/closed；Stop失败保留物理窗口，finishShutdown不重放业务。旧实现纯回归实际出现detach/closed先于Stop，修复后恢复顺序。
- Windows原生move/size循环的独立旧/新对照确认：仅延迟销毁会停在DefWindowProcW的原生循环；quit现确认capture根属于当前App后释放，不保WindowRecord跨ReleaseCapture重入，不改其他App或外部宿主的capture。正式9种move/size/menu/gesture/raw/stale模式均锁定accepted→Stop→closed，另验证本App子窗口和外部窗口的capture归属。
- stopping与stopped分开：前者等待Stop，后者仍能在普通安全点处理迟到mandatory Cleanup。纯红测实际为expected 2/found 0；修复后两级清理各一次，post仍Closed、Stop不重放且零新增分配。旧页面单测的收尾改用finishShutdown，并再次检查completion/listener次数。
- root固定657文件副本Windows Debug/ReleaseSafe各95/95、Linux两配置各94/94。Windows真实chrome、cleanup、native-reentry、AppStop及1000绘制窗口通过，GDI13→13、USER6→6、records=0/slots=1；旧PageSession/WebView Debug真实Runtime通过。首次快照命令未显式指向SDK，两个页面目标仅编译失败；补绝对SDK参数后重新执行成功，未据此前失败宣称运行通过。见[应用资源](application-resources.md)。

### P01/H01.2 Linux 离窗页面会话

- 复用稳定地址的唯一Session/View、PageId/历史和五簿、App Stop及现有WebKit State。停放直接持有无父未realize的WebKit widget，不创建parking GtkWindow、额外WindowRecord、第二页面模型或隐藏worker；普通View无新增Session专有对象。公开page_sessions capability现为true，仍明确ephemeral，原custom/remote/file来源策略不变。
- 挂载前发布暂定Host供早期通知识别。真实GTK set_parent重入raw parent destroy曾使child被提前unparent而崩溃；现撤离既有整层以保留child-parent链到foreign退栈，之后由普通安全点拆卸。C State/Host/Layer/NativeWindow及Zig Session/Window/Region引用链穿过最后foreign free。独立源码review逐哈希核对生产8文件，无确认缺陷。
- 实测覆盖零parking窗口的精确初始尺寸、DPI整数可表示性、负/分数区域边缘、失败attach/update保旧、stale与非回绕epoch；DOM/PageId/已接受JS、deferred资源和私有文件流跨两个宿主保留；同层双Session独立park/close及raw销毁后双rehost；挂载/停放reload和自有WebProcess recover；远程ACK前零请求、fragment/history/refresh与旧PageId拒绝。
- 关闭专项覆盖全部host分配失败、构造完成的最后scratch free中close/quit、on_closed立即释放整个Session、queued reload在Session释放后静默、mounted/parked请求各detached一次、accepted destroy post先于Stop、零窗口不keepalive，以及未启动文件pump取消/0pread/worker post Closed自行归还拥有结果。晚到native引用只由夹具显式App收尾，最终窗口/Region/Stop/脚本/资源/文件/native预算归零。
- 三项新增寿命夹具作者Debug/ReleaseSafe各1×/2×5/5实际通过。root最终固定669文件副本独立Debug1×与ReleaseSafe2×Session各5/5，Linux页面纯71/77通过、6平台skip；旧HTML/custom/dynamic/navigation/regions/remote及strict session-host另固定副本ReleaseSafe2×均过。相同最终源Windows ReleaseSafe20/20步骤、95核心+72页面=167/172通过、5平台skip，真实旧Session和15App/99pending COM0通过；26个overlay SHA均与main一致。
- 文档与可选CI已接session-host/session-zig的1×/2×并解析YAML；远端未运行。Wayland、不同缩放宿主、混合焦点/IME/AT-SPI及任意覆盖未建立运行证据，HTTPS本地站点、持久Profile及更广浏览器策略仍保留，P01继续部分完成。见[离窗页面会话](pages.md)。

### G02 GPU 极端父变换精度复核

- 圆锥切片的独立逐像素oracle发现极小缩放与大剪切不符既定bilinear结果。用不含gradient的256个普通solid fill重建相同源平面，仍复现scale=1/4096中心颜色错误及shear=65536的大平移采样错误，确认是现有GPU affine composite的共性边界；不把它归为圆锥角度问题，也不以圆锥专有限制宣称修复G02。
- 保留真实红测、源和exe；继续分析D2D坐标/逆变换与采样精度，建立覆盖嵌套每stage和累计parent的通用GPU包络。无法证明时必须在整Buffer任何绘制前拒绝，由Context用同一业务Buffer软件后备；低层调用返回明确错误，不改变原bilinear/无area filter合同或放宽像素oracle。此项尚未验收。

### T04.2.5 显式语义命令与提交回执

- DocumentEditor提供`runCommand`，Diff split/unified提供`run`，显式操作undo、redo、全选、定向选区和多选替换。它们复用原Document/Adapter及唯一undo；窗口菜单/工具栏无需伪造键盘输入，也不改变手选hunk。调用者提供每个当前canonical selection两项scratch，不继承业务辅助控件的固定容量；配置97选区的纯回归已覆盖。
- 一次Document最终guard合并owner权限和已有NativeInputScope。提交stamp在Document返回后、Adapter receipt/fold/index的foreign free之前捕获；text_version和真实canonical选区分别判定变化。提交后的分配/呈现失败、外部编辑、禁用或退出返回拥有原始commit身份的结果，不把已提交操作变成可重试错误。Diff prepare/syncCaret所有成功返回出口继续复核来源与revision，首次呈现错误保留。
- 作者Windows/Linux Debug/ReleaseSafe四配置各56/56纯，新原生回归包括64个Document/Adapter/呈现分配失败点、direct native input在禁用/退出前后的拒绝、post-presentation修改target/peer/关闭，以及多选单次undo和暖GDI/USER稳定。另一只读reviewer逐哈希复核7文件及底层guard/Window pin，无确认问题。
- root固定673文件副本Windows ReleaseSafe新命令、旧caret和完整Diff为24/24步骤、95核心+36Diff=131/131，另DocumentEditor20/20；Linux ReleaseSafe2x同组25/25、94核心+36Diff=130/130，另DocumentEditor20/20。新旧原生资源归零，最终冻结清单一致。CI接入typed命令，远端未运行；Find继续独立实施，T04.2.5仍部分完成，见[Diff文档视图](document-diff-view.md)。
### R06 原生 C 间接头文件增量构建

- 实际最小复现确认Zig 0.15.2下 imported module直接拥有C源时，只修改二级头文件会复用旧对象与旧程序结果；直接构建根则会重编。原生适配统一改为独立object构建根，消费模块显式附加，同模块多个程序复用一个对象。compile includes/pkg-config属于该对象，最终链接库仍显式保留；核心与可选GPU/UIA/WebView的依赖开关不变。
- 可选WebP整批C源改用独立static archive构建根，保留固定源码、配置、CPU分支、系统库及许可安装。COFF不支持将多个C translation unit合为一个object，实际编译失败后采用archive，没有拼接源或依赖人为touch。
- PS1/SH正式回归复制实际helper和两级头文件样例，使用同一缓存读17，再只改二级头为29，Windows/Linux实际结果均29。编译缓存与保留的源码/日志分开，位于项目盘及受支持Linux文件系统；脚本没有删除操作。独立review另以双translation unit archive验证同缓存17→29，两轮5/5；迁移、include/link和默认按需构建源码review无确认问题。
- 新构建图Windows ReleaseSafe系统矩阵51/51步骤：完整文档UIA、Diff UIA/业务控件、UI配置、一次唤醒、系统菜单/托盘、选择器结果和图片均实际通过，USER/GDI暖后稳定、资源归零；WebP真实解码11/11，页面纯72/77通过5平台skip且两个SDK C对象实际编译。GPU硬件/WARP新圆锥与通用变换检查已由作者在新C对象图运行，绘制性能仍单独收口。
- Linux ReleaseSafe新图核心94/94与真实WebP15/15步骤，2x窗口位置/唤醒14/14、2x完整PageSession11/11均实际通过；typed Diff固定副本另有新图回归。正式头文件回归已接CI并解析YAML，远端未执行。统一CLI、完整默认成本和全路线图仍继续，见[构建缓存](build-cache.md)。
### P01 持久目录的显式准备层

- 新增独立`profile_storage.Prepared`，仅由宿主显式worker执行目录/文件I/O；主线程采用已准备的线性资源。路径有界、UTF-8/绝对规范路径，逐祖先O_NOFOLLOW，只可创建最后私有root及固定data/cache/SQLite/lock项；验证euid、类型、私有权限和文件硬链接。准备前完整预分配metadata，失败关闭自身FD，不删除已有数据或递归建目录。
- 目录排他用非阻塞flock；五个自身FD均CLOEXEC。handoff失败可由worker reclaim，adopt与逻辑lease不分配，lease容量/非回绕generation/metadata预算显式，close穿过最后foreign free仍Busy且先撤入口。逻辑lease不是引擎异步引用预算；关闭只close自身FD，不LOCK_UN，因此同一open-file-description的native副本可独立保锁。
- 作者Windows Debug/ReleaseSafe各5/5纯；Linux两配置各5/5纯和7/7文件测试。root固定两文件副本独立Windows ReleaseSafe5/5、Linux ReleaseSafe5/5+7/7，涵盖所有metadata分配失败、锁冲突、symlink/权限/硬链、已有数据保留、worker往返、外国线程拒绝、stale lease及dup在原owner关闭后继续排他，FD回到基线；两文件哈希一致，源码review无确认问题。
- 这只是准备层，尚未接入View、PageSession或backend capability，Linux公开页面仍要求ephemeral。持久Profile manager/独立Context、首请求Cookie与跨进程退出后恢复继续；不把目录锁、GObject最终释放或owner关闭冒充磁盘flush/fsync/NetworkProcess退出屏障。

### P01 持久 Profile 的私有原生所有者

- 私有原生层拥有一个 WebsiteDataManager，每个 Context 独立创建；不创建 Window、WebView、worker 或 App 停止节点。Context 数量和本层申请的元数据字节各有容量，GLib/WebKit 内部内存及进程另计。封入口和关闭 owner 均不等待仍存活的 Context。
- Prepared 新增有代数的线性 NativeClaim，失败可 abort，成功永久消费本次准备。这样同一 open-file-description 的重复借用不能绕过 flock 创建第二个 manager；重建须关闭 Prepared，再由显式 worker 重新准备，原生晚引用仍持锁时返回冲突。路径和锁在第一宿主分配前固定，构造失败及最终 foreign free 的重入均有覆盖。
- 独立回归实际证明弱引用通知会在 dispose 时提前归还计费；原实现红保留，改由私有 qdata destroy 通知在最终释放时归还 Context/manager 引用和独立 C 存储。真实 run_dispose、晚强引用、主线程末次 unref、逻辑 close 后锁仍占用及最终计数归零均通过。所有借出的 WebKit 引用仍限 owner 主线程，私有 qdata 不得被覆盖或窃取；没有迟到 Zig/App 回调。
- 作者严格 C、Linux Debug/ReleaseSafe 原生各 6/6，Windows 两配置私有 Profile 与准备层纯逻辑各合计 7/7。root 新构建目标 Windows ReleaseSafe 准备层 6/6，Linux 准备层及真实文件检查合计 13/13；固定 696 文件副本的原生层新主构建入口 5/5 步骤、6/6 实际通过，独立交叉 review 无新增确认问题。
- `test-profile-storage` 已接默认纯测试，Linux 显式文件目标通过 `scripts/test-profile-storage.sh` 运行；私有原生检查使用 `P01_PROBE=profile-owner`，缺测试目录明确失败。CI 配置已接，远端未执行。公开单 App Profile、页面/停放会话接线、首请求 Cookie 与跨进程恢复继续实施，未据此打开持久存储 capability；GObject 释放和目录锁均不代表引擎 flush 或子进程退出屏障。

### T04.2.5 显式字面查找与源授权

- 可选 Find 固定 coordinator 寿命，只捕获原 Document 的 Snapshot/Reader、查询和前缀存储；宿主显式安排 worker、App.post、stop、finish 与 join。普通 Diff 不创建查找器、线程、索引或正文副本。默认两槽、4 KiB 查询和 256 KiB 本层元数据，硬上限及旧候选共存计费明确；Document 快照、Reader 和原生布局仍各走原预算。
- worker 复用既有 KMP，前缀准备按保守 3P 工作量计费，step 严格累计实际比较次数。next 从选区末尾开始，previous 在必要前缀结束；wrap 复用同 Reader 的 restart，不重建前缀，并保留重叠匹配和 UTF-8 边界。512 个独立线性方向 oracle、密集匹配、近首尾小预算、取消、陈旧 Work 以及 ReadersAlive 重试均已覆盖。
- 来源包含真实 side、非回绕的原生绑定代数、两份 Document revision/text version 和 primary selection。成功取得输入绑定就撤销旧授权，即使后续 caret 同步报错。实际回归曾证明 B 已绑定而 caret InvalidGeometry 时旧 A 查找仍提交选区；现先发布新 acquisition，再同步 caret，保留同一正式红到绿证据。A-B-A、选区/IME ABA、equal-text 编辑、peer 改动及停机均不能复活旧结果。
- apply 沿用 typed selection 命令及 Document 最终 guard，不另建选区或 undo；提交后的呈现错误仍返回原 committed outcome，ticket 恰好消费一次。Full/Closed 不转移宿主投递责任，release 不复用物理槽，已接受任务最后使用后才 finish。构造清理顺序按寿命不变量加固并验证 12 组 close/quit/OOM/Closed，未将其宣称为已复现的 native UAF；App.stopping 入口错误优先级另有真实红到绿回归。
- 最终 8 文件冻结后，作者 Windows Debug/ReleaseSafe 各 24/24 步骤、Linux Debug 2×/ReleaseSafe 1×各 25/25，每组 91/91 纯测试及新 Find、旧 caret、typed 三项实际原生检查通过，资源归零。root 固定 699 文件副本 Windows ReleaseSafe 新 Find 8/8 步骤，Linux ReleaseSafe 2×为 29/29 步骤、91/91 纯测试及新 Find/旧 caret/typed/完整 Diff 实际通过，清单核对一致。
- CI 已接新 Find，远端未执行。本子项按显式接口范围验收；查找 UI、regex/locale 匹配和完整字段交互另列任务，T04 及 T04.2.4 的既有剩余项仍继续。见[Diff 文档视图](document-diff-view.md)。

### G01.7/G02 圆锥与仿射回放

- 圆锥复用有界 brush/stop 与离线 analytic effect，明确中心、起始角、方向及右连续接缝；矩形、圆角和内描边由独立象限/acos oracle 对照。软件只在圆锥分支计算角度，既有线性/径向路径不变；普通绘制不编译 shader、不生成圆锥像素资源。
- 通用 GPU 预检覆盖实际 f32 quad、逐层采样及累计 parent，包含原生顶点栅格化误差；不在受验包络的合法输入在整 Buffer 绘制前拒绝，Context 使用同一 Buffer 后备且不重跑业务 draw。极小缩放和大剪切不再走已知不符合同的 GPU 路径；部分普通非整数嵌套也保守后备。旧非整数嵌套例保留为软件像素与 GPU 拒绝回归，另外用可证明的二进制系数验证硬件/WARP 每层采样，未换例后宣称旧例由 GPU 修复。
- Cairo 借用已有工作平面，与 GDI 共享有界 f64 四点采样；使用实际 source 范围及透明 guard，采样期间没有 callback/分配/native 调用。完成后只标记紧界并恢复 parent；普通无变换回放不变。独立回归同时保留旧 Cairo 极小缩放偏差及大剪切错误，失败仍保留原 front。
- 作者冻结 26 文件，Windows ReleaseSafe 新旧绘制为 35/35 步骤、UI 118/118 纯，Linux ReleaseSafe 2×为 34/34 步骤、111/111 纯；适配层资源归零。root 同源固定副本 Windows 默认 test/check 与绘制/生命周期为 285/285 步骤、783/785 测试通过/2 平台跳过，Linux ReleaseSafe 2×为 177/177、776/777 通过/1 跳过；圆锥、90 组旧 analytic、gradients/layers/offscreen/affine 及 App Stop 真实原生均通过。Windows 另跑 SVG/文字、仿射 UI/Document、几何与 shaped editor 使用方 37/37，资源归零。离线 HLSL 和 18788 B DXBC 均与生成元数据哈希一致，生产/测试/Shader 的冻结源码与副本一致；这不代表之后其他切片已在同一全图运行。CI 已接两端软件圆锥检查，远端未运行。
- 独立 378 场景、4 次预热和 21 次采样的 Cairo 对照仍显示过滤变换成本缺口：完整矩阵最大 sampler/native 比值为 4.74，不能用部分表格的较小值代替。整数网格与八像素向量采样已有改善，过滤缩放/平移继续测量优化；优化候选只有维持逐字节 oracle 且有实际收益才采用。G01.7 的 path/显式色彩插值和 G02 的性能均未完成。见[基础绘制](drawing.md)、[仿射回放](affine-rendering.md)和[性能验证](performance.md)。
- 后续三个仅在隔离目录的 row-gather 候选均通过 12 项纯检查，分别用 ABBA 短测比较同一基线；局部 quarter/half 有改善，一般域及 shear/double 未建立稳定收益，最后一组基线本身也有明显波动。候选按停止条件弃用，未进入生产或正式 378 场景验收，26 文件哈希与正式性能表保持不变；不将短测当成已解决性能缺口的证据。

### T04.3 显式语言服务优雅退出

- 一个固定 control 独立于普通 pending 请求槽，按非回绕 serial/epoch 和 CAS phase 保留物理责任；捕获与 worker 编码不撤 ready，普通请求槽满仍可准备 shutdown。Client 固定元数据及 Work/Reply、Packet/JSON 峰值进入显式预算，没有默认线程、额外控制队列或隐式时钟。
- owner 的短 Send scope 持 Client/Broker 门跨宿主 FIFO 接受决定。Full/Closed/OOM 前保留旧 display 和 Packet；接受后必须 commit，随后宿主才将同一产品交给 IO worker。shutdown 无 params，仅匹配 ID 的 null result 或真实服务错误可允许准备无 params 的 exit；等待期间仍可回复反向 configuration 请求，禁止新普通请求/通知。接受 exit 只表示本地停止，实际写管道、wait/kill 均由宿主 worker 完成。
- deadline/force 为显式 owner 操作，restart 只撤旧逻辑授权、不提前复用物理 control。root 审查发现旧 Work 的 force/expire 缺少 epoch 门；正式红测复现旧 shutdown 会停止已重新 ready 的新连接，增加 epoch 检查后返回 StaleEpoch，新连接继续 ready。旧 Reply 仍需 finish，旧 Work 仍可 close，不用逻辑取消替代资源回收。
- 原生四 child 流程覆盖 null/error 响应、服务在回应 shutdown 前反向拉取配置、无响应时显式超时终止、已排队回执前 stop；另有 Reply 专属 App.post Full/Closed，失败不消费，已接受普通任务执行一次后由 owner finish。真实 worker allocator barrier 验证 force 不等待、WorkerRunning/ShutdownAlive 保留责任，以及恢复后取消清理。反向请求临时还原普通 ready 门会实际 NotReady；这是本纵片候选的正式红到绿边界，未将其描述成旧版本已具有完整退出实现。
- 8 文件冻结后，root 固定 706 文件副本 Windows ReleaseSafe 33/33 步骤、Linux ReleaseSafe 2×为 32/32，各 119/119 纯测试；新退出、旧协议/工作区/配置、resolve、代码编辑器和 snippet 实际原生通过，资源归零，全部冻结哈希一致。CI 两平台已接新目标并解析 YAML，远端未运行。父 T04.3 的详情展示及更广语言能力继续，见[语言协议](language-protocol.md)。

### P01 单 App 持久 Profile 与页面接线

- 公开 Profile 在一个调用者分配中内联私有 owner，属于唯一 App；App Stop 只 seal，不等待 Context。View 在首次 foreign 分配前取得 C-only 配置 lease，不保存可被提前关闭的 Zig Profile 指针；持久状态使用已有配置存储的对齐尾部。普通 ephemeral 不创建 Profile、Stop 节点或额外尾部对象，新增 nullable 字段的固定成本另列。
- 成功 post 是 reload/recover 接受边界。新 Context 在投递前构造、计费和一次 admit，Full/Closed/OOM 保留旧页面；已接受候选即使随后 Profile.close 仍履行责任。初次 window/region/session 则在 API 返回前仍属候选；六组正式红例证明 native scratch 分配或最后 free 关闭 Profile 后原本仍会成功，现仅三个首次入口在 scratch 全部释放后检查、完整回滚，不误收紧已接受重载。
- 真实顺序 UI 子进程已验证首请求 Cookie 与 localStorage 恢复，ephemeral 对照不读该 Cookie、仍保持原有 localStorage 禁用行为；还覆盖共享 manager/独立 Context、所有宿主配置分配失败、队列满、停泊 Session、进程失败后的显式 recover、Stop 和晚原生引用。目录锁、qdata 最终释放、UI Child.wait 均不冒充 NetworkProcess/WebProcess 退出、flush 或 fsync 屏障；目录再次使用仍须宿主建立实际引擎寿命边界。
- 16 文件冻结后，作者 Debug/ReleaseSafe × 1×/2×公开目标各 13/13，旧 ordinary/remote/dynamic ReleaseSafe 2×各 13/13，私有新构建入口 8/8 实际原生测试通过。独立只读 review 的首次结论漏查最后 scratch free 撤销门；正式红例后再核对三处修复及失败清理，无新增确认问题，没有将首轮 no-finding 当作覆盖证明。
- root 固定 706 文件副本独立 Linux ReleaseSafe 2×：私有层 5/5 步骤、8/8，公开目标 13/13，页面纯 11/11 步骤、72/78 通过/6 平台跳过，旧 PageSession 13/13；Windows ReleaseSafe 29/29 步骤、79/84 通过/5 跳过，旧 WebView/Session/Host/remote 真实 Runtime 通过、COM 归零。随后打开 Linux persistent_profile，发布元数据后重新通过页面纯与公开目标。CI 已接 1×/2×公开检查并解析 YAML，远端未运行；HTTPS local、独立 CookieStore、浏览器工具及其他平台继续。见[存储合同](webview-profile.md)。

### B03/P01 无页面 CookieStore 首片

- 独立 Store 显式绑定 App/Profile，在首个 View、WebContext 或 Window 之前查询 HTTP(S) URL；可选精确 name/domain/path 过滤，结果为调用者独立拥有的有界 Batch。默认只读，write 与仅清 Cookie 分别授权，不扩大页面 origin 权限，不创建隐藏页面、worker、timer 或 keepalive。
- `deleteExact` 采用完整快照的 expected value；已更新值不会被旧快照当作无条件身份删除。SDK 成功完成可能是 no-op，必须以查询或下一次真实 HTTP 请求观察变更。全量枚举/替换、无值身份删除和 Windows 冷 Store 继续明确不支持。
- 创建先取得 C-only Profile/manager 引用，再进入 caller allocator；取消/Stop 先撤逻辑槽，最后物理 GTask 释放才归还 C 操作。实际发现并修正回调尾部过早释放 manager 的崩溃：操作改由 GTask 私有 qdata 持有，覆盖其 source 最后释放，迟到路径不访问 Zig/App/allocator。`on_closed` 仍不是物理或持久化屏障。预算区分本项目请求存储与 GLib/libsoup/引擎内部分配，不能将返回行上限当作引擎枚举工作上限。
- 13 文件冻结并完成独立只读 review。root 固定 716 文件副本 Linux ReleaseSafe 2×：纯 Cookie 5/5，私有故障目标 7/7 步骤、1/1，公开 Cookie 目标 15/15，覆盖冷操作、十种寿命模式和两个真实 HTTP 页面；旧 Profile/Session/remote 各 15/15，页面纯 13/13、73/79 通过/6 平台跳过。Windows 页面纯 7/7 步骤、85/90 通过/5 平台跳过，冷入口在读取 App/Profile 或分配前返回 Unsupported；旧 WebView/Session/Host/remote 真实 Runtime 回归 26/26 步骤，15 个 App、99 次待关闭及停泊/挂载停机后 COM 和原生资源归零。实际 WebKit 为 2.52.6，最低 2.40 仅源码合同核验。CI 已接私有目标及公开 1×/2×，配置解析通过，远端未运行。见[Cookie 存储](cookie-store.md)。

### T04.3 显式纯文本补全详情

- Presenter 显式 opt-in，使用独立 Layout/Prepared 展示所选项的 detail/documentation；默认路径不构造详情布局，默认同页导航仍只更新选中项和失效区域。详情文本、像素和 Prepared bytes 有界，候选、旧布局与 scratch 同时计入现有总预算；放不下时不分配隐藏面板，不在 paint 整形。
- 同页选择及满足版本条件的元数据精化复用已有行 Prepared。详情开始的指针序列由详情消费，编辑器开始的序列仍完整转发给唯一 Adapter，跨面板释放不会丢失；焦点/取消优先撤路由。翻页已提交选择后呈现 OOM 只记录次级布局错误，不让重试再次导航或重复编辑，默认模式沿用相同提交边界。
- 修正三个已复现的重入窗口：Rect scratch 最后释放后发布陈旧布局、source 最后释放期间 App 停止后继续发布，以及翻页已提交后以未提交错误返回。所有 foreign free 之后重新核验可用性和版本；回调/绘制 lease 保证最终关闭前不释放 owner。单一 Document/undo、IME、失败帧保旧、关闭与最终资源归零均验收。
- 5 文件冻结并经独立 review，作者 Windows/Linux Debug/ReleaseSafe 四配置各 95/95 纯及新旧原生检查通过。root 固定 708 文件副本 Windows ReleaseSafe（GPU/UIA）完整 test/check 与相关原生目标 289/289 步骤、832/834 通过/2 平台跳过；Linux ReleaseSafe 2×为 179/179、825/826 通过/1 平台跳过。包含真实 resolve/退出子进程、旧编辑器/snippet、3DPI 软件像素与 App Stop/关闭回收。CI 两平台已接并解析，远端未运行。Markdown、可滚动详情、完整详情辅助语义和更广语言能力继续，父 T04.3 保持部分完成。见[代码编辑服务](code-editor.md)。

### G01.7 显式渐变插值空间的软件首片

- 每个渐变显式选择 sRGB、linear-sRGB 或 Oklab；统一有界 stops，精确端点/重复 stop 保留原色，透明端点不泄漏隐藏 RGB。先在选定空间预乘插值，再转换为编码 sRGB 预乘输出；有符号 Oklab 通道不提前裁剪，逆变换后仅做线性 RGB 通道裁剪，不宣称完整色域映射或全局色彩管理。
- 默认 sRGB 数值和采样循环保留，不准备转换表；新模式每命令准备一次 512B 栈调色板。Stored 仍为 152B、32 项 brush 表 4864B，Command 仍为 32B；原有 GPU shader 的 624B constants 与 18788B DXBC 不变。
- 可见的新插值模式在整缓冲绘制前返回 GPU 精度不支持，Context 可将同一 Buffer 交软件后备。独立 GPU Offscreen 在 begin/clear 前执行共享预检，拒绝不改变旧成功 front/层统计；已实际复现并修正原先提前 clear 的问题。下一次默认模式仍可使用 GPU，不扩大 GPU 新模式能力。
- 10 文件最终冻结，root 固定 711 文件副本 Windows ReleaseSafe（GPU/UIA）80/80 步骤、123/123 纯，Linux ReleaseSafe 2×为 38/38、116/116；新 GDI/Cairo 各 324 场景、三 DPI、独立 XYZ/f128 矩阵与插值及 f64 transfer-pow oracle，最大通道误差为 1/255、形状/clip 边缘为 0。包含拥有型 capture/reflection/group/OOM、GPU HW/WARP 拒绝、旧渐变/圆锥/分组/离屏/仿射，以及 Windows SVG/文字/编辑器和核心关闭回收。相同数值实现的 Linux 全量 test/check 另为 183/183、791/792 通过/1 平台跳过。CI 已接并解析，远端未运行；GPU 新空间须另证坐标/量化/混合精度并测量默认成本，仍在实施。见[基础绘制](drawing.md)。

### G01.7 GPU 插值候选的精度与默认成本

- 隔离目录中的候选只接受不透明、轴对齐、整数物理边界、无父变换/分组的线性渐变，并进一步限制坐标与 stop 网格。hardware/WARP、三 DPI 的 576 个新空间像素平面相对独立 oracle 最大误差为一字节；36 对默认模式新旧平面逐字节一致。这只建立候选窄域的正确性，未开放生产 GPU 新空间能力。
- 统一 shader 候选使离线字节码从 18788B 增至 22804B。预先固定的默认模式性能检查覆盖两驱动、两尺寸、三种渐变、两种 stop 数，共 24 组，每组五个 ABBA block；保留 96 条预热和 480 条测量 query，120 个 block，所有 timestamp/disjoint/调用有效性检查通过，最短区间 11232 ticks，最终资源为零。
- 两个 WARP 组的中位比值为 1.066847 和 1.058437，超过 5% 门槛；包括这两组在内的 18/24 组同时触发预定噪声条件。不能据此宣称稳定回退幅度，也不能将其记作性能通过；没有剔除、补采或调整门槛。统一 shader 未合入，生产默认程序与已验收软件后备保持原合同。后续先评估独立、显式准备的新模式程序及其构造/驻留成本，再重新建立相应精度和性能证据。

### P01 创建期回环 HTTPS 证书例外首片

- `Profile.createWithOptions` 显式冻结单一 `127.0.0.1` 的有界 certificate-only PEM 和 manager 直连策略；默认 Profile 不进入证书捕获栈帧或创建证书对象。原有创建 API 保持兼容，缺失 GIO TLS 后端、证书解析和原生失败保留真实错误域/代码。例外属于 host 而非端口，不提供强制 pin 或动态单项撤销。
- 在首次 caller allocator 前捕获 PEM 并取得 Prepared claim；每个实际 Context 发布前应用同一例外，沿用 TLS FAIL、请求扩展 ACK、精确 origin/method/header 和独立 IPC 门禁。成功 post 接受的 reload/recover 在之后 seal 时仍履行责任，迟到引用只使用 C-only 存储。预算明确区分固定构造栈、本项目请求字节和 GLib/TLS/网络进程内部成本；服务器、私钥、worker 与连接/磁盘预算均由宿主管理。
- 14 个作者文件加独立 Unsupported 回归形成 15 文件冻结，完成独立只读 review。作者 Debug/ReleaseSafe × 1×/2×真实 HTTPS 目标各 17/17 步骤，含十四种网络/寿命模式及两个构造重入场景。root 固定 725 文件副本 Linux ReleaseSafe 2×：纯目标 6/6 步骤、6/6，TLS native owner 5/5、4/4，HTTPS 17/17；旧 Profile owner 5/5、8/8，Profile/CookieStore/Session/remote 各 15/15，页面纯 13/13、76/82 通过/6 平台跳过。Windows 纯与 Unsupported 入口 10/10 步骤、89/94 通过/5 跳过。
- 实际验证将默认代理拒绝与默认直连坏证书拒绝分开，覆盖错证书/host、服务提前停止、扩展未握手零请求、首请求 Secure/HttpOnly Cookie、跨端口 Cookie 与独立 localStorage、跨 Profile 信任隔离、停泊/重挂/进程恢复/Stop 和最终引用归零。运行环境为 WebKitGTK 2.52.6/libsoup 3.4.4/GIO GnuTLS，最低 2.40 仅 API/源码兼容核验；测试所需 TLS 依赖通过显式私有 namespace overlay 提供，不改系统或 SDK。CI 接入 TLS owner 与 HTTPS 1×/2×，配置解析通过后仍不代表远端执行。内存/动态/文件资源的 HTTPS 运输继续，Linux `local_site` 仍为 false。见[Profile 合同](webview-profile.md)。

### T02.1 原生组合取消与解绑

- Windows 在通知前撤销旧组合、未配对 surrogate 和 reconversion offer，通知后核验窗口/HWND、客户端代数与新组合，再决定是否调用 IMM；IMM 返回后不写回旧状态。END 沿用相同本地撤销顺序，取消失败也不恢复已撤销状态。回调启动的新组合、绑定或关闭不被旧操作覆盖，活跃且未取消的 IME 仍保留 Tab/导航键优先权。
- Core 仅在解绑的原生取消作用域内把旧客户端撤销通知转为 `text_preedit_revoked`；Context 清 composing 后在 `on_input` 前消费，由旧 `TextClient.unbound` 负责唯一 Document 的组合清理。普通显式取消与 legacy 无客户端编辑器仍走普通输入，新绑定也不被旧作用域吞掉。没有通过忽略 Busy/StaleTextClient 掩盖错误，未增加查询 API、轮询或隐藏延续任务。
- 已分别复现成功解绑后的本地组合残留、END 回调创建的新状态被尾部覆盖，以及仅修原生层后向正在交接的编辑器重复发送业务取消所致 Busy。正式回归覆盖失败/重绑/直接原生关闭/失焦，以及真实 Document/Adapter 取消、解绑、窗口关闭三组；虚拟组合撤销而正文和 undo 不变，生命周期通知不能进入业务输入。原 Diff 扩展解绑链保留键盘/undo/资源断言后转绿；历史两次偶发 Tab 记录仍未自然复现，不将这次修复视为其已确认根因。
- 9 文件冻结并完成平台层及 Core/UI 只读 review。作者 Debug 核心和新目标为 11/11 步骤、98/98，ReleaseSafe 六目标为 31/31、98/98；新原生目标共十四组检查，原扩展 Diff 链 15/15。root 固定 733 文件组合副本 Windows ReleaseSafe（GPU/UIA/WebView）八个原生目标 54/54：包含新取消、文档编辑器/Diff、补全详情、生命周期/Stop/cleanup及真实 WebView。1000 个绘制窗口后 records=0、slots=1，GDI 12→12、USER 6→6；15 个 WebView App/99 次待关闭后 COM=0。CI 已接新目标并解析，远端未执行；这些消息级检查不代替真实语言引擎、TSF 或视觉验收。见[文本上下文](text-input.md)。
- 同一 733 文件固定副本的完整 test/check：Windows ReleaseSafe（GPU/UIA/WebView）319/319 步骤、897/904 通过/7 平台跳过；Linux ReleaseSafe 2×连同相关原生目标为 185/185、801/802 通过/1 平台跳过。Linux 实际编辑器、Diff、补全详情、GTK surrounding、四个顺序 App 与 Stop 资源检查通过；整合后的 fmt 检查也通过。新高斯模块与后续文件 consumer 提取不在这个冻结副本中，另行验收。

### P01/B05 独立文件 consumer 与运输验证

- 将既有 Linux pollable/socket 文件流机械提取为可选 `ziggurat_file_stream`。同一进程共用一份 native implementation，保留 32 个物理文件、每 consumer 八个 reservation 和 16KiB chunk；没有第二份 App/View/HTTP 状态、隐藏 worker 或整文件复制。旧 WebView 公开结构、错误和 Windows 原生路径保持兼容，原 C 入口通过薄头和 admit 的兼容 wrapper 保留。
- Candidate 在本地准备失败或 abort 时保留原 source/pump；consumer 已不可撤销接受后才 admit，随后取消仍履行已接受责任。HEAD 零 pread，Control 不持物理槽；source/pump/实际 stream 的最后引用才归还容量。多个 consumer 和逻辑 Budget 关闭不能突破进程上限，迟到引用不访问 Zig owner。独立只读 review 确认 C 实现除 include、入口改名及兼容 wrapper 外逐字等价，未发现确认缺陷。
- 九个作者文件冻结，Debug/ReleaseSafe console 各 12/12 步骤、5/5 测试。root 固定 737 文件副本独立 Linux ReleaseSafe：console/页面纯 23/23 步骤、81/87 通过/6 平台跳过，普通页面、动态文件、PageSession 和 remote 的 2× 原生目标各 15/15，最终资源为零；Windows 纯 10/10、89/94 通过/5 平台跳过。全部九个源哈希复核一致，fmt 通过。独立 wrapper 已接默认 test/check，公开运行检查继续沿用可选 WebKit CI。
- 同一 737 文件副本 Windows ReleaseSafe 的旧 WebView、完整私有文件、PageSession 与 remote 四个真实 Runtime 目标为 28/28 步骤：十五个 App、九十九次 pending close 后 COM=0；文件 source/control/budget、停泊/挂载会话的资源/计时器/Stop 及最后回调均归零。Linux 提取没有引入 Windows GIO native 对象。
- 隔离的 TLS-only 运输原型在宿主显式服务器/worker 下，迁移前 strict-C O0/O2 各八组、迁移后独立 consumer O2 八组实际通过。真实网络 oracle 覆盖完整 8MiB+37 字节、HEAD、取消、断开、缩短、EIO、已接受但未启动 pump、错证书；一次最多一个待发送 chunk 和一个 read，系统流/消息/服务器最终引用匹配。该原型不等于公开 Endpoint、能力认证或页面资源路由完成，Linux `local_site` 继续为 false。
- 额外 raw backend 检查暴露已拒绝 STARTED 后迟到 COMMITTED 被误报策略失败；同环境迁移前文件实现同样失败，且该序列不读文件。第一失败源/可执行文件/日志和原实现对照均保留，作为独立导航生命周期问题继续修复，不由已通过的文件流矩阵宣称覆盖。见[文件流合同](file-stream.md)。

### G01.8 显式合成快照高斯准备首片

- 可选 `ziggurat_gaussian` 只依赖绘制资源与标准库。Processor 显式分配一个物理 Work，worker 仅卷积固定像素和预分配空间，owner 清理临时存储后再发布独立 Prepared；没有隐式线程、计时器、GPU 读回或 paint 工作面。旧结果、候选、scratch、固定元数据与源的完整 mip retention 同时进入预算，仍有 Work/结果时拒绝关闭。
- 真实透明 Snapshot 先完成重叠子树、group/mask，再按透明外延滤波；父 clip 和整体 opacity 在结果回放时应用。半径 `ceil(3*sigma*scale)`、最大 128 px，输出保留负 placement。零 sigma 返回原 identity/Lease/levels，仅持自身 source pin，不增加像素、上传或图片驻留。
- 纯测试 Windows/Linux ReleaseSafe 各 10/10，使用独立直接二维卷积 oracle、实际 worker、全部分配失败、取消、旧代数和最终 free 重入。root 固定 740 文件副本 Linux ReleaseSafe 2×完整 test/check 与高斯、旧 offscreen/layers/images 原生回归为 183/183 步骤、812/813 通过/1 平台跳过；Windows 相同五个绘制目标为 35/35。GDI/hardware/WARP/Cairo 三 DPI 的高斯量化及回放最大差为一字节，最终 group 像素 alpha=255 单独核验；零 sigma 上传/驻留/创建次数保持不变。
- App 关闭前窗口/records/Stop 归零，GPU refs 归零，Linux native 为零。Windows 保持已初始化 App 的 GDI 10→10；App 释放后进程计数为 4，独立无高斯的顺序 App 对照也保留同一计数，未宣称进程 GDI 为零。CI 已加入两平台显式原生目标，远端未运行。自动 live blur scope、GPU 两遍滤波、backdrop 与自动失效继续实施，父项未完成。见[高斯准备合同](gaussian.md)。
- 相同 740 文件固定副本的 Windows ReleaseSafe（GPU/UIA/WebView）完整 test/check 为 325/325 步骤、908/915 通过/7 平台跳过。它覆盖该副本的整合状态；后续光标、HTTP 元数据提取、导航与文本捕获修复分别冻结和验证。

### V06 可选 C 归档与间接头缓存

- 可选 native 程序使用独立静态库成员，只有实际引用其导出符号才参与最终链接；共享接口仍由普通 C object 提供。源码分离与实际可执行文件是否包含字节码分别验证，不由 dead-code 假设代替二进制证据。
- object 和 archive 均保持独立 C 构建根，以覆盖 Zig 0.15.2 对 imported module 间接头的缓存边界。Windows/Linux 的正式回归各在同一个缓存下将间接头常量从 17 改成 29，两种产物分别实际执行并得到新值；保留四份构建日志，不靠删除缓存通过。已有 CI 清单调用扩展后的同一脚本，配置解析通过，远端未执行。可选功能的准备时间、默认执行成本和驱动内部存储仍按 V02/V06 分别测量，归档不代表零构建成本。

### T02/T04 显式光标样式与缓存发布

- 可选 `ziggurat_caret` 提供有工作额度的字素 cell 索引。两个编辑器适配器显式准备同一 Layout 的完整 advance cells，支持 bar/block/underline 和失焦轮廓；bidi、软换行、空行与 EOF 保留原生几何。默认 bar 不建索引或额外 cell 数组，样式不改变 shaping、原生 TextClient 或辅助技术插入位置。block 在正文前、underline/轮廓在正文后绘制，IME/非空选区采用明确回退。
- 正式重入回归确认旧 ShapedEditor 在退休几何的 allocator 回调修改正文后，可能将旧 Layout 标记为当前版本。现以 buffer/display revision、selection、affinity 核验候选，先无回调交换拥有权、再释放旧资源，最后复核；返回 `LayoutRequired` 后仍保留快照真实 stamp，业务编辑不重放。发布前 Prepared pins 的再次核验属于防御收紧，夹具不授权 Surface 跨事务借用。
- 七个文件冻结。作者 Windows Debug/ReleaseSafe 各 33/33 步骤、Linux Debug 2×/ReleaseSafe 1×各 29/29，均 25/25 纯测试及新旧编辑器原生通过。root 固定 744 文件组合副本 Windows ReleaseSafe 纯检查 26/26、115/120 通过/5 平台跳过，原生编辑器、代码/Diff、IME 及四类 WebView Runtime 目标 74/74；Linux ReleaseSafe 2×为 62/62、106/112 通过/6 平台跳过。覆盖三 DPI、90° 仿射和双分数 clip、全部候选 OOM、复用、undo 及关闭，最终资源归零。CI 已加入新目标并解析，远端未运行。版本化行背景、成熟输入控件及文本构造捕获另行验收，父项继续实施。见[光标合同](editor-carets.md)。

### P01/B05 共享 HTTP 响应格式

- 将方法、头部许可与响应校验、OwnedResponse 及原测试机械提取到纯 `ziggurat_http_response`；WebView 的十二个公开名字保留同类型别名，Limits、请求 Book 和文件 consumer 不变。root 独立逐段比对原始内容，只有模块边界与一条类型身份测试变化。HeaderGrant 继续只校验观察到的头，不承担凭据注入。
- 两个文件冻结。root Windows ReleaseSafe 纯元数据 3/3；固定 744 文件组合副本的两平台页面、文件与原生整合结果见上节。Linux 独立 file wrapper 与动态文件回归通过，实际 HTTPS 页面目标 17/17；Windows 真实文件响应与 Runtime 回归通过。新 HTTPS Endpoint 继续单独实现认证、网络接受/取消及 App Stop，不借用 WebView 的请求 ID、五簿或 Producer ACK。

### P01 已撤销导航的原生终态

- Linux STARTED 已拒绝或 stop 后，SDK 仍可发送排队的 COMMITTED。仅对同一 loading generation/serial 的已撤销且仍受信加载保留固定 tombstone，忽略其 DOM/来源发布，等待真实 FINISHED；未拥有或未受信 COMMITTED 仍拒绝。终态先清旧标记再调用完成，完成回调可显式接受下一次导航，关闭/进程失败不等待引擎收尾。固定 native 元数据增加 24 B，没有历史表、分配、轮询或额外 timer。
- 每次加载保存首个实际 load failure；全局 nativeFailure 仍更新为最近诊断。无 load-failed 的取消完成状态为 0，不继承上一条 JS 错误。两次故障的首错误/最近错误差异用明确注入验证，真实已拒绝或 stop 的 STARTED→COMMITTED→FINISHED 则由 SDK 事件验证，两者分别记录。
- 三个文件冻结。root 独立固定 737 文件副本 Linux ReleaseSafe 2×：严格 C backend 全场景通过，公开 navigation、dynamic file、PageSession、remote 各 15/15 步骤，HTTPS 17/17；完整 test/check 连同基础生命周期为 211/211、882/889 通过/7 平台跳过。完成重入/关闭、上一真实 JS 错误、动态源与资源归零均通过。744 文件组合副本后续原生检查仍通过。本片修复导航终态，不开放 Linux local_site 或凭据注入，P01 继续实施。见[页面策略](pages.md)。

### G01.5 显式 host stroke 与 SVG non-scaling-stroke

- `Stroke.space` 区分局部与变换后描边，中心线先映射到 host、按 host 单位生成描边，再以独立输出映射回放。SVG 根变换、嵌套 viewport/use、clip/mask 与 paint server 分别沿各自空间处理，原几何 bounds 不被描边外扩替代。CSS 保留 vector-effect 非继承默认及显式 inherit/reset/cascade；不同 tspan 的独立 vector-effect 尚不支持时明确失败。
- 独立 review 复现两处错误并补回归：小缩放下 dash/trim 曲线的 host 切分精度不足，以及 caller allocator 重入修改借用的输出矩阵导致两次准备使用不同值。前者统一 host 误差约束，后者在首次分配前按值捕获。192 个默认路径场景的新旧像素、采样与全部统计一致，未执行性能计时，不由等价结果推断速度。
- 14 文件冻结。最终 Windows ReleaseSafe 为 23/23 步骤、vector 38 + SVG 131 = 169/169 纯测试；真实 GDI/hardware/WARP 的 SVG 与文字目标全部通过，覆盖双合成、三 DPI、root shear、NSS 两映射、设备恢复、13 个文字映射 oracle、候选 OOM 与最终引用零。此前 Linux Debug/ReleaseSafe 的 169/169 与 Cairo 原生检查通过；其中旧日志在磁盘清理时丢失，最终 Windows 日志已另存缓存目录外。混合文字样式、textPath、patterns/markers/filters 与更广 SVG 继续，G01.5 未完成，见[SVG 合同](svg.md)。

### T02/T04 同一正文的版本化行背景

- DocumentEditor 的 `LineBackground.paragraph` 是 committed UTF-8 正文的真实 LF 段落起点，使用唯一 Document 的行索引核验；严格有序、无重复、有界复制。`setLineBackgrounds` 以 expected text version 事务发布，分配器重入改变正文时返回明确过期结果。选择变化保留背景，正文修改/undo 使旧背景失效，IME 虚拟组合期间抑制。
- 准备只遍历可见投影，与折叠、换行及原生 text height 使用同一 RunIterator；不把投影 gap/min-height 涂成正文背景。已有/候选定义和几何进入同一预算，paint 不分配或整形；背景、选区、正文按明确顺序回放，不创建第二份正文、选区或 undo。
- 四个文件冻结并完成只读 review。作者 Windows/Linux Debug/ReleaseSafe 四配置均为 26/26 步骤、21/21 纯与新旧编辑器、caret、Diff 原生通过；root 另一次固定组合检查返回 exit 0，包含生命周期、IME 与 Diff UIA。旧缓存日志丢失，该 root 运行不补造步骤总数；已救援源并核对原 SHA256。CI 已接目标，后续 producer/hook 核心 API 迁移须再次整合验证。历史偶发 Tab 问题仍未确定根因，见[行背景合同](editor-line-backgrounds.md)。

### T01 文本构造的拥有型输入捕获

- Layout 在派生 UTF-16、长度与原生布局前先拥有 UTF-8；family/locale 在首次 allocator 回调前有界捕获。后续统计、解码和 native 参数只读取同一捕获值，捕获期间的源寿命仍由调用者保证，不能靠重复读取推断外部可变存储是否安全。
- 三个文件与保留 SHA256 一致；root ReleaseSafe 的输入捕获、旧布局和 shaped editor 检查为 18/18 步骤，包含 11 个隔离子进程和分配失败回归。该轮日志在缓存清理时丢失，未将此窄验记作最终整图通过。CI 加入 `smoke-text-layout-capture`，见[文本布局](text-layout.md)。

### P01/B01.3 Linux exact-origin 凭据与 HTTPS 页面组合

- 创建期冻结最多八个精确 HTTPS origin 与各自 32-byte Bearer，独立于普通请求和 IPC 许可。只有非空配置准备可清零 wire 存储；每跳移除原 Authorization、执行原 method/origin/header 门禁，再为精确目标添加 Bearer，并计入 64 项/16KiB 头预算。禁止与观察型 Authorization HeaderGrant 混配，空配置沿原路径。协议版本拒绝旧扩展，secret/序列化 backing 在实际最后原生引用时清零，迟到 C 回调不访问 Zig/App。
- 17 文件首片冻结并完成独立 review。真实 TLS 五文档/48 请求验证首请求、子资源、同源与跨源跳转、重载、恢复、无配置和另一 Profile；后者不继承 secret。此前 ReleaseSafe 全模式 1×/2×通过；最后一轮全模式 Debug 失败后日志被清理，其根因及完整 Debug 矩阵仍未确认，不能用后续较窄通过代替。
- 独立公开 Endpoint 拥有自己的身份、认证、Offer/Ticket 和取消，不依赖 WebView 请求簿。构造失败及最后 owner free 前清零 Bearer，比较 scratch 同样清零；回归先以 `CredentialStillPresent` 失败，再在 Debug/ReleaseSafe 通过。正式 `test-https-resources-native` 独立物理状态，Debug/ReleaseSafe 各 9/9 步骤；C ASan/UBSan 的 16 个故障场景通过。旧日志已丢失，测试和清零回归已接正式目标及 CI。
- 公开 Endpoint→WebKit 实际组合的最终 ReleaseSafe 2×为 20/20 步骤；root 独立 Debug 1×复验同为 20/20。五模式覆盖内存、worker Ticket、524325-byte 私有文件、权威 HEAD 长度与零 body、独立取消、Stop 在 worker 唤醒前 seal、post Closed 保留调用者责任及缺失 Bearer 零 offer；所有 HTTP/file/Profile/View 最后引用归零。目录准备在 App 前，退出 drain 后由显式 worker 仅清理本次确切目录，构造/attach 失败也完成回收。最终源清单及这两轮完整日志保存在缓存外。
- 组合目标 `smoke-https-pages` 已接可选 Linux WebKit/HTTPS CI；远端未运行。TLS 依赖只恢复约 308KB 的最小私有包，没有系统安装或放宽生产 TLS。Windows B01.3 发送前 callback 覆盖与真实重定向 oracle 正在实施；Linux `local_site` 仍为 false，完整页面工具和其他平台继续。见[请求凭据](request-credentials.md)与[HTTPS 资源](https-resources.md)。

### T02/T04 实际输入来源与编辑前输入门

- Core 正文事件改为显式 `TextInput{text,producer}`，producer 描述实际 Win32 character、IMM result、GTK commit/keyval 或 application 交付路径，不推断物理键盘或可信输入。唯一 DocumentEditor 在 key/text/preedit/native change 默认动作前提供同步 pass/consume；回调已编辑、交接绑定、关闭或改变准备状态时消费旧输入。生命周期撤销不进入业务 hook，默认 null 不复制正文或增加每事件分配。
- 原生 change 明确返回 applied/rejected/superseded，仅 applied 确认原请求。hook 自己的编辑与原请求责任分离，后续呈现失败保留业务提交并报告 layout 状态，不重放输入。所有 prepare 入口共享 Busy 边界；callback pins、token、窗口许可、文档与视图 stamp 在 foreign 回调后复核，observer 后不再读取可能关闭的适配器。
- 28 文件首片冻结，完成 root 与独立绘制任务的源 review。作者 Windows Debug 核心 99/99、新原生目标 8/8 步骤及 20 场景通过；root 固定组合源 Windows ReleaseSafe（GPU/UIA/WebView）完整 test/check 为 352/352 步骤、942/950 通过/8 平台跳过。它不包含后续 tspan 或 Windows 凭据增量。
- root 独立 Linux ReleaseSafe 1×与 Debug 2×各 43/43 步骤，覆盖新输入门、行背景、文本捕获、旧文档/代码/Diff 编辑器、Stop 与四个顺序 App，最后资源归零；28 源清单复核一致。CI 已加入新目标并解析，远端未运行。系统 IME 显式禁用、真实语言引擎、TSF、完整快捷键 scope 与更高层已消费输入仍是独立子项。见[编辑前输入门](editor-pre-input.md)。

### B01.3 Windows 请求凭据与逐跳 Runtime 验收

- Windows 沿用相同的独立 exact-origin Bearer 合同，在每次发送回调先移除已观察 Authorization、执行原来源/方法/其余头门禁，再装饰精确目标并计入最终预算。空配置保留原行为；原生 C State 在最后引用时清零独立 UTF-16 凭据，迟到回收不访问 Zig/App。能力位只在真实 Runtime 验收后打开。
- 11 文件冻结，完成 root 与独立编辑器任务的源码审阅。作者 Debug/ReleaseSafe 各 20/20 步骤、90/95 测试通过/5 平台跳过，四 Runtime 模式均通过。root 在唯一固定源副本独立 ReleaseSafe 复验同为 20/20、90/95，并完成相同四模式：主场景五个文档、68 次 wire 对照 73 次 callback、五条消息及一次进程恢复；GET/HEAD、同源/跨源往返、JS 同名头、重载/恢复、清空与另一 Profile 均有固定计数。peer 无模块 Bearer，禁止来源零 HTTP。
- 关闭 ready 与错证书均为零 HTTP，禁止重定向仅发送原来源一次。测试在 App 结束后由显式 worker 等待自己持有的浏览器句柄，最终 probe/COM/Window 归零；测试专用证书例外只进入隔离 adapter，不进入生产对象。作者旧 WebView/remote/authorization 回归通过。可选 Windows CI 已接全链和 JSON 留存并解析，远端未运行。框架不宣称控制 SDK/OS 在该发送回调后添加的自身认证；B01/P01 其余页面工具与 TLS 错误上报问题继续实施。

### G01.5 同字体 tspan 的独立实色填充

- 首片保持单一 shaping chunk、字体、方向与 anchor，仅将明确源区间的 solid/none/currentColor 和 fill-opacity 分配到原 provider cluster。整段只 shape 一次，保留 glyph paint order；颜色边界切开不可分 cluster 或混合 bidi parity 时明确拒绝。公共描边、paint-order、完整 glyph-cell 边界、clip/mask/opacity 及 non-scaling-stroke 仍作用于整段，不按颜色重复描边。
- cache 区分几何与绘色：同一分区换色复用已有 Path，分区改变先准备候选再交接；所有同时存活路径、cell、分区和临时数据计入现有有界预算。默认单色路径不强制请求 mapping。准备后原生回放不 shape、不分配颜色数组。
- 13 文件基线完成独立源 review，Linux Debug/ReleaseSafe 纯测试各 142/142，两优化模式、两缩放的隐藏原生检查各 11/11。固定副本 Windows ReleaseSafe 的整合为 77/77 步骤、180/180 纯测试，实际 GDI/hardware/WARP 三 DPI、完整 OOM、重入和资源回收通过；填充分区有四个接受场景（两个 RTL）及一个明确 cluster 拒绝。平台 shaping 的接受数不同，测试保留各自正例和拒绝条件。
- 同一固定组合源另通过 Linux ReleaseSafe（WebView/HTTPS resources）完整 test/check：231/231 步骤、937/946 通过、9 平台跳过，后验 52 个输入/填充/凭据源 hash 一致。这不替代真实语言引擎、HTTPS 错误重复测试或视觉验收。与 dx/dy/rotate、spacing textLength 的组合继续按独立切片验证，混合字体、textPath 及其他 SVG 缺项仍在实施。

### G01.5 实色分区与单 chunk 字符定位组合

- 在上述基线后，独立 14 文件切片把已有 dx/dy/rotate 与实色分区组合。私有 Positioned 产品只在完整 source/cluster/坐标验证后交付已定位 Mapping 和精确 cell 四角；颜色分区接管它，不再重复排序、定位或把旋转四角提前缩成 AABB。重用、重新分区、公共描边和外层 objectBoundingBox 继续使用同一几何。
- Linux Debug/ReleaseSafe 各 145/145 纯测试，两优化模式、两缩放原生各 11/11；root 固定副本 Windows ReleaseSafe 为 15/15 步骤、145/145，实际六个填充接受场景（三 RTL、两定位）、一个 cluster 拒绝及十三个映射接受场景。GDI/hardware/WARP、两合成模式、三 DPI、原 Layout 对照、分配失败和资源回收通过，14 源 hash 后验不变。
- 后续 spacing textLength 与无 dx/dy/rotate 的单 chunk spacingAndGlyphs 已在同一私有 Horizontal 几何中组合：路径与精确 glyph cell 共用一次 advance/stretch/offset，颜色重分区和缓存复用不再二次变换。多字体、多 chunk、非恒等缩放 arc outline 等未支持输入明确拒绝；零宽、零自然 advance、端点、溢出与原描边用户单位分别验证。
- 最终 14 文件组合在 Linux Debug/ReleaseSafe 各 153/153 纯测试、两缩放原生各 11/11；root 独立 ReleaseSafe 2×复验通过。固定副本 Windows ReleaseSafe 连同核心/模式/生命周期为 45/45 步骤、256/256，其中 SVG 153/153；实测六个必接受间距场景和六个伸缩场景（各三 RTL），原填充/定位、GDI/hardware/WARP、两合成模式、三 DPI、完整 OOM/重入与资源归零均通过。八个默认场景的像素、完整分配/释放字节序列、峰值、工作量和命令 fingerprint 与基线一致；没有据此声明时间性能。textPath、多字体及其他 SVG 缺项继续实施。

### T02 显式窗口文本输入模式

- `WindowOptions.text_input_mode` 和 setter 显式选择 system 或 keyboard_compose。默认只保留一份系统上下文；GTK 每次真实切换准备一个新 context，先发布身份/epoch，再断开退休信号并撤离旧对象。Windows 仅调整当前 HWND 的 IMM 关联，恢复默认 context；普通字符、键盘布局和本地 compose 不被丢弃。getter 报告已选择策略，不能当成用户 IME open 状态。
- 切换的 native cancellation、重入、关闭和新输入都有独立 authority。Windows 已真实复现并修正回调禁用后保留旧 surrogate，以及嵌套字符被外层旧消息覆盖；原消息续写核对局部 producer 代数，取消 END 仅清理。同一正常 result/new-preedit 消息不因文档 revision 改变而误拒绝。没有新增 worker、轮询或普通输入分配。
- 最终 15 文件冻结并完成交叉源 review。Windows Debug/ReleaseSafe 各 21/21 步骤、103/103 核心测试，模式、原预输入门和旧 IMM 取消原生检查均资源归零。Linux Debug 1×/2×核心 101/101，模式和预输入原生各 15/15；root 独立 ReleaseSafe 2×为 46/46，涵盖旧编辑器、Diff、Stop 与顺序 App。后续生产修复仅涉及 Windows，GTK 生产未漂移。最终组合源完整 test/check 与后端整合继续验证。
- 不承诺任意宿主自定义 HIMC 的恢复、完整 TSF store、所有真实语言引擎、子 WebView 或进程级语言策略；CI 已加入新隐藏窗口目标并解析，远端未运行。T02 父项继续实施。见[窗口输入模式](text-input-mode.md)。
- root 最终固定组合源的 Linux ReleaseSafe 2×完整 test/check 与相关原生为 265/265 步骤、944/953 通过/9 平台跳过，后验输入模式与凭据清单一致；随后 Windows ReleaseSafe 模式、预输入、旧 IMM、核心与 1000 次绘制窗口销毁随 SVG 整合全部通过，GDI/USER 数量不变。这一组合不包含之后的区间标记和页面初始化器增量；新的整图验收单独记录。

### T02/T04 同一 Prepared 的有界区间标记

- DocumentEditor 以 committed UTF-8 非空区间准备背景和下划线，复用同一投影、折叠、换行、bidi character cells 与 Prepared；不重新 shape 或在 draw 分配。标记拥有独立版本，正文变化后明确 stale，selection 不使其失效；composition 期间按合同拒绝或抑制，失败候选不发布。
- 最终四文件在 Linux 独立 ReleaseSafe 2×为14/14步骤、22/22纯与真实原生通过。其后固定809源的 Windows ReleaseSafe 完整 test/check 及相关原生418/418步骤、1010/1017通过/7平台跳过，Linux ReleaseSafe 2×274/274步骤、987/1001通过/14平台跳过；两者区间标记、旧文本/文档/代码/Diff客户端、输入门、模式及最后资源均通过。所有809个hash在两进程退出后复核一致。
- 该整合包含既有SVG stretch、输入模式和最终Windows初始化器，不包含之后的textPath、TextBinding、HTTPS Site、SVG image或Unicode Word增量。完整编辑器与T02/T04父项继续，见[区间标记](editor-range-markers.md)。

### B02.2 Windows 拥有型文档初始化器首片

- 创建配置与替换在首次调用者分配前捕获有界描述符，再独立拥有正文、来源及UTF-16 batch。默认空表无初始化器存储或原生ID；非空采用显式总字节与物理在途预算，有序prepare/accept/activate/retire事务。逻辑取消不提前释放物理责任，关闭先撤Zig入口，迟到C回调独立释放。
- 只接受可信、语法有效的ordinary function body、精确HTTPS来源、document-start/top-frame/page-world；它不是不可信代码sandbox。实际编译器输出通过14项VM语义断言及无效body逃出包装的负例。导航在初次安装或替换未完成时关闭门禁，Remove重入取消的真实red已修复，保留旧脚本且不重复通知。
- 最终16文件源经独立review并纳入上述809源整合。root真实Runtime的exercise、close_pending、stop_pending、wrong_certificate四模式全通过：六epoch/九message、两次install/一次cancel/一次recover/一次native gate denial；业务wire计数严格为8/1/1/0，wrong-certificate保持真实拒绝。全部物理引用和预算归零，确认浏览器退出后才清理本次确切测试目录。
- Linux非空入口保持UnsupportedCapability，默认空配置的链接回归已修复并独立通过Debug13/13步骤、92/105通过/13平台跳过。其他时机/frame/world和Linux实现继续，B02父项未完成。见[初始化器合同](document-initializers.md)。

### P01 显式 HTTPS Site 与借用响应

- 可选Linux HTTPS模块新增Site：拥有静态路由和Endpoint，路径、MIME、body、mount先捕获/拥有后验证，最多128路由并二分查找；总预算包含表、Site、Endpoint及borrowed/queued候选。静态GET/HEAD/404带固定响应策略；动态/文件fallback由宿主显式提供，policy headers仍由handler负责应用，没有目录查找或自动文件回退。
- respondBorrowed在原Endpoint验证/预约/复制/接管事务中避免临时Owned body，输入Response不被消费；Ticket仍只在成功接管时消费。构造先pin宿主server，并在安装handler前后复核唯一TLS listener和raw paths；两处真实重入red修复后，失败构造不发布、不通知on_closed。最后临时server-unpin后的App复核经源码review，未声称单独触发了那个确切回调点。
- 最终13源hash一致，root ReleaseSafe服务端13/13步骤；实际WebKit九模式在Debug1×、最终ReleaseSafe2×各20/20步骤，覆盖静态路由、完整私有文件/HEAD、取消/Stop/post Closed、回调关闭与最终free重入关闭/quit，最后HTTP/file/Profile/View引用归零。独立review通过。此处是宿主明确管理的TLS服务路由，不开放Options.local或Linux local_site；独立严格TLS错误分类偶发问题仍未解决。见[Site](https-site.md)。

### T06 显式完整文档 Unicode Word 单位

- Windows文档辅助桥的word_units默认关闭；启用时只在同一immutable native Text候选尾部追加至多scalar_count个u32边界，所有正文、选区、undo和原生生命周期仍只有原所有者。ICU lexical分段把尾部标点/空白归前词，leading-only run单独成单位；不拆scalar或grapheme。查询只二分已拥有表，不分配、shape或回调Zig；本层新增投影验证为线性cursor，系统词典内部成本另列。
- Word与Format升级到真实word表；未实现的Line继续升级Paragraph，Page继续Document。terminal空paragraph特例仅限实际Paragraph路径，不能让Word误退为空末行。默认Text/State复用既有padding，没有新增word数组或Word API查询；opt-in追加字节、old/candidate并存及保留MTA引用都进入原native ledger。
- 保留真实旧getter对照red：相同新store/probe下Word Expand期望[2,9]却返回Paragraph[0,18]，不称作完整旧源码回归。最终14源经root review并归档；作者Windows Debug/ReleaseSafe各store2/2、provider5/5，以及六相关原生目标37/37步骤、6/6纯，通过真实Bridge的Word内容、反向移动、EOF、关闭Range、native词表与预算。Linux两配置的显式ICU/模块目标各13/13步骤、6/6纯和8组golden通过；其结果不代表Linux辅助后端运行。最终共享整图验收另行进行，完整T06与其他语言单位继续。见[文档辅助功能](document-accessibility.md)。
- 同轮原Diff Tab oracle以完全相同源码/二进制跑六种selector各20次，共120/120通过，原断言、trace和最后资源检查保留；没有Diff/Core生产修补。此前丢失的两个失败日志没有重建，历史原因仍未确认，不能以重复通过声称根因已经修复。

### R06/B01 无页面的 Windows 引擎发现

- 新独立可选ziggurat_webview_runtime只执行显式worker的loader版本查询，返回拥有型固定Result，区分加载、导出入口、SDK查询和返回值合同失败；只有SDK精确not-found HRESULT表示未发现引擎。主线程/不支持平台先拒绝，不读取路径；两条绝对路径在首次原生调用前捕获，最后字符串与loader引用释放后再复核取消。没有App、Profile、Environment、隐藏worker或默认应用动态加载。
- 最终三源逐hash由两位独立reviewer核对，root Windows Debug/ReleaseSafe各6/6步骤、4/4纯与真实SDK九次探针全部通过；观察引擎156.0.4314.23，缺DLL/缺导出入口分别报告，预热后进程handle稳定，最后无存活子进程。它不是全程进程创建监视，也不证明页面可初始化。Linux Debug/ReleaseSafe各4/4纯只验证冷Unsupported等合同；Linux/macOS实际引擎发现继续。CI已接独立目标并本地解析，未运行远端CI，R06/B01父项未完成。见[引擎发现](webview-runtime.md)。

### G01.5 有界 user-space SVG pattern 首片

- 显式 `patternUnits=userSpaceOnUse`、基本实色内容与局部仿射，由 prepare 预检可见候选 tile，再编译已有拥有型矢量几何；目标描边、non-scaling-stroke、外部 clip/mask 与整次 paint opacity 沿用原合同。定义样式来自真实祖先，零尺寸不绘制，objectBoundingBox、模板、viewBox 与嵌套 paint server 等未实现输入明确拒绝。
- tile 与目标几何在共同16-lane域完成一次 paint，保留半像素接缝反例，避免两个A8=128边缘 source-over 后只得192。pixel 只在 pattern 路径创建借用 Sheet/refs 的私有场景，实时计入父 live/peak，成功及失败均只合并一次累计工作；原生 draw 仍只回放图片，不展开图案。
- 普通八场景的完整像素、分配、峰值、工作量与命令指纹保持一致；既有条件资源 owner 从72增至80字节，pixel pattern 首用另有96字节累计 ledger。pixel 的 color/scene/sort 统计仅覆盖新增共用 lane 过程，不能当作普通 pixel 全部颜色工作的计量或耗时改善。
- 作者 Debug/ReleaseSafe 纯测试各179/179，Linux 两优化×1x/2x 原生各9/9，另图片回归12/12；root 对累计30源做独立 review 与 ReleaseSafe2x 检查，25/25步骤、179/179纯及图案/文字/图片真实回放通过，运行后全部哈希一致。Windows 此片仍待验证，完整 G01.5 未完成，见[图案合同](svg-patterns.md)。

### B03/P01 显式授权的完整 Cookie 枚举

- Linux `CookieStore.listAll` 返回独立拥有的有界 Batch，要求默认关闭的 `allow_read_all`；write/clear 授权互不隐含。review 发现早期候选缺少全量读取门后补齐正式拒绝用例，默认/write-only/clear-only 均不调用 Completion、不分配、不占逻辑或物理槽，也不改变 requested-byte/peak 计数。
- 原生异步/finish 两个入口都是可空 ELF 弱引用，完整 pair 可用才接受；保留既有2.40强链接边界，不另开 loader 或增加 Store/Op 字段。旧 CookieManager 声明与真实缺任一符号的三个加载探针通过，但没有实跑2.40 Runtime。SDK先生成的完整 GList及其释放成本不受项目结果额度约束；适配层超限完整失败，不截断或冒充分页。
- 十源冻结，作者 Debug/ReleaseSafe 各真实15/15步骤、C owner7/7且1/1、结果/token纯5/5通过；root 独立 ReleaseSafe 原生15/15，C owner7/7且1/1，以及两优化各3/3且5/5，通过真实跨域/path/Secure/HttpOnly/expiry、Profile seal、取消/Stop/重入/物理Full及Batch跨App，最终适配层引用归零，全部源哈希一致。Options在已验64位Linux仍56字节，不据此声称耗时改善。
- root 随后在固定827文件副本执行新增 Windows 不可读Store地址/永不可调用Completion的冷拒绝断言，ReleaseSafe `test-webview` 为7/7步骤、111通过/5平台跳过，全部源哈希一致。它只证明Unsupported合同，不代表Windows冷Store已实现；全量替换和无值身份删除继续，完整B03未完成，见[CookieStore合同](cookie-store.md)。

### G01.5 开放折线 textPath 与拥有型嵌入图片

- textPath 子集复用单次完整 Layout 的 glyph/cluster 顺序，将轮廓与精确 cell 共同映射到原始开放折线路径；glyph 两端的 chord、端点切向延伸及超出有限路线的拒绝分别验证。仅目标自身 transform 参与路线定义，外层映射随后应用；曲线、多 chunk、逐字符定位等未支持组合明确拒绝，见[SVG文字](svg-text.md)。
- 图片由宿主在 prepare 前显式解码，provider 只查找已准备的不可变 ImageView；SVG验证有界 data-image key、固定全部借用资源并拥有紧密预乘像素副本。none/九种对齐 meet/slice、shear、clip/mask 与定位矩形bbox分别验证，不在解析或draw中执行I/O/解码；外部URI、SVG递归图片及overflow扩展保持拒绝，见[SVG图片](svg-images.md)。
- 累计26源完成作者与root review。root固定825组合源的Windows ReleaseSafe（GPU/UIA/WebView）完整test/check及相关原生目标417/417步骤、1053通过/7平台跳过；Linux ReleaseSafe2x275/275、1025通过/14平台跳过，运行后825哈希全部一致。实际文字12组折线路径oracle和图片两模式×四fit场景×三prepare DPI、源关闭回放、GDI/hardware/WARP/Cairo及最后引用归零均通过。图片条件资源成本及sample_color固定Builder增长已记录，不作性能改善声明。

### T02/G02 保留式 TextBinding 的同一成功坐标

- 显式 `setCommittedSpace/clearCommittedSpace` 与本地 caret，沿原 Context workspace/window/region 的稳定绑定获取每次成功front；曾启用后撤销、换workspace或Context重绑必须重新授权。read/change/caret/install在foreign调用前后复核，原buffer/有向UTF16选区仍是唯一模型，mapped caret继续交给原生文本服务。
- 真正的旧unbound尾回调可覆盖新绑定问题已由稳定owner与transaction busy边界修复；关闭中的异步unbound仍保留Context寿命，不能以isClosed提前释放。四源冻结并经独立review，作者Windows相关矩阵及root825两平台完整组合通过，包含真实WindowsIMM映射caret和GTK文本上下文、成功/失败front、撤销重建与资源归零。仿射Diff是后续独立子片，不能由此推定已完成，见[文本输入](text-input.md)。

### G01.5 SVG 双端 user-space marker 首片

- line/polyline/单开放M/L路径从原始命令取得首尾顶点与方向；局部marker-start/end、固定角/auto/auto-start-reverse、viewBox/ref/viewport clip与真实定义继承进入既有markers绘制槽。目标fill/stroke opacity不降低标记，整体clip/mask/opacity只在完整元素外作用一次。默认strokeWidth units、mid/曲线/多subpath等其余范围继续。
- 十四源冻结，累计34源由root独立review及ReleaseSafe2x25/25步骤、193/193纯与SVG/textPath/image原生回归通过，全部posthash一致；作者两优化×1x/2x原生各9/9。八组默认像素、分配次数与工作量保持，已有span_style场景峰值每份增加32字节，Style/Frame各增32、固定CSS winner scratch增80字节均明确记录。Windows此片仍待验，完整G01.5未完成，见[双端标记](svg-markers.md)。

### T04/G02 可编辑 Diff 的共享仿射授权首片

- 显式坐标 binding 使用唯一成功 Space 与两条固定 POD 候选记录，UIA 几何和原生输入复用原 Document/Adapter/Prepared；完整 stamp 在 native 发布前匹配，失败帧保旧、缺失/覆盖的成功候选撤权，不在 draw 提交文本或分配。首次 opt-in 后退役 binding 继续拒绝输入，不能恢复 DIP fallback；controls/auxiliary 在该模式明确不支持。
- 输入权限贯穿指针映射、原生 read/change/caret、最终 Document guard 和四种成对布局分支。真实 Ctrl+Enter allocator 撤权及提交后 observer 撤权先失败再通过；代数耗尽永久拒绝新权限，但 publisher/坐标/native 资源仍可退役。已提交 TextClient change 的展示失败通过诊断报告，权限丢失返回 superseded，其它情况 applied；旧 observer 回归新增一次诊断、一次 revision 与单次 undo/redo 验证。
- Windows 实际 UIA/MTA 首验通过，换回旧 close 源的受控检查明确返回 ClosingCoordinateLost，退出后恢复原 hash，未对悬挂指针重试。最终 Debug 集成为38/38步骤、84通过/1平台跳过；Linux Debug纯16/16、84通过/1跳过，Debug与ReleaseSafe 2×仿射原生各10/10，资源为零。新组合 ReleaseSafe 完整检查继续，不据此宣称 T04/G02/T06 父项完成。见[Diff 可访问性](document-diff-accessibility.md)。

### G01.5 普通目标的 strokeWidth marker

- 默认/显式 strokeWidth 按目标 computed stroke-width（含 viewport 归一对角百分比）缩放 marker 坐标，保留 userSpace 算式及目标整体 effects。stroke none 仍可画 marker，普通宽度零不展开；真实引用的 strokeWidth 与 NSS 组合明确拒绝。
- 累计34文件、单生产文件增量通过交叉源码审阅，Linux Debug/ReleaseSafe纯各201/201，两优化两缩放原生各9/9；root独立ReleaseSafe纯201/201、2×原生9/9。原四个userSpace场景和八个默认场景的像素、完整分配trace及工作量均一致，无新增持久字段/分配层；Windows 新片继续整合验证，不宣称全量SVG完成。见[marker合同](svg-markers.md)。

### B03/P01 显式授权的非空完整 Cookie 替换

- 独立默认关闭的 replaceAll 授权；先做 descriptor-only 累计32KiB预检，再验证、复制输入并一次调用可选 native async/finish pair。空输入明确拒绝，调用者可另用显式 clear；不通过隐藏读取、clear/set序列模拟替换。
- 原生受理前的验证/预算/分配失败保留旧数据；受理后的失败、取消、Stop 没有事务回滚或持久化保证。请求完整输入与嵌入 GList 节点由单个有界 block 拥有到 GTask 最后释放，Store/Op保持160/96字节，Options保持56字节；引擎内部成本另列。
- 累计12源完成交叉审阅与hash复核。作者Debug/ReleaseSafe真实私有Profile各15/15、C owner各7/7及1/1、纯各3/3及6/6；实际缺失replace async、finish或两者的ELF均明确拒绝。root独立整合及Windows新增不可读descriptor冷拒绝断言继续，Windows不因此获得无页面CookieStore。无值身份删除仍单独实施。见[CookieStore合同](cookie-store.md)。

### G01.5 开放原始顶点的 marker-mid 与闭合标记

- 开放 M/L 的 mid 使用原始内部顶点及不按线长加权的方向半角；单一 M/L/Z 与 polygon 另走完整闭合验证，start/end 共用首点 seam 方向，mid 包含最后列出的顶点。固定方向可接受非零折返，需要 auto 的180度折返及显式零长 closing edge 明确拒绝。曲线、多 subpath 与 NSS/strokeWidth 组合仍另行实施。
- 开放 mid 首片的累计34源经独立 review，Linux ReleaseSafe2x 的 SVG/text/image 联合回归25/25步骤、208/208纯测试，全部后验hash一致。Style/Frame各增16字节，固定CSS winner scratch由1360增至1400；默认像素、次数和工作量保持，span_style峰值增加16字节及相应trace变化单独记录，不宣称时间性能。
- 闭合标记累计34源冻结并独立审阅，作者 Debug/ReleaseSafe 纯测试各218/218，两个优化与两个缩放的原生矩阵各9/9。默认8、双端4、开放mid2共14场景在两个优化中的完整像素/分配/工作量指纹逐字段一致，闭合片没有新增布局字段。负角像素 oracle 的中间失败保留：CSS负角先取模与 signed auto 半角的三角函数相差2 ULP，最终用独立已知 signed rotation matrix 验证，未放宽逐字节断言。root独立闭合/Windows新mid验证继续，不由作者检查推定父项完成。

### B03/P01 无预期值的 Cookie 身份删除

- deleteKey只捕获name/domain/path，独立allow_write先于输入访问；通过单次native异步写入过期tombstone提交，不隐藏读取当前value或整批替换。domain大小写及前导点沿实际Soup身份规则验证；name/path精确，已变value和空value都能按身份删除，缺失项为无操作。完成只表示SDK完成，不是后续可见性、事务回滚或持久化屏障。
- 累计13源经独立审阅与root ReleaseSafe2x真实Cookie15/15、C owner7/7及1/1检查，31次身份操作和原有全量读/替换/HTTP/关闭回归均通过，13源后验一致。真实ABI受控失败在首个身份删除返回InvalidCookie，修正保留字段的默认值后相同断言通过；Store/Op/Row维持160/96/80字节，无新增拥有字段。Windows新增不可读key的冷拒绝断言继续，不给Windows增加无页面Store能力。

### 837 组合验证与 Diff 测试隔离

- 固定837源在Linux ReleaseSafe2x完整test/check及相关原生检查284/284步骤、1062通过/14平台跳过，后验837源一致。Windows ReleaseSafe GPU/UIA/WebView 为425/427步骤、1091通过/7平台跳过，实际新仿射UIA、SVG marker/strokeWidth和WebView检查通过，但旧Diff集成在unified之前出现TestUnexpectedResult，整组不记为通过，原因仍未确认。
- 保存的原失败二进制单次重跑通过，随后固定20次诊断中19次通过，另一次在context方向键断言得到117行与2行差异。受控Ctrl线程状态已独立复现后者；测试的plain-key helper现明确save/clear/restore本线程键盘表，保留原期望和全部256字节恢复断言。修正后固定50次projection、50次observer、20次完整链及单次受控context均通过，未将这一测试缺口倒推成原始unified之前失败的根因，也没有修改生产输入或放宽断言。继续保存阶段诊断和失败证据。

### G01.5 闭合标记复验与单段曲线端点

- root 在绑定 live 源目录的独立 local cache 完成闭合片 ReleaseSafe2x 联合复验：25/25步骤、218/218纯测试，SVG/text/image实际原生检查通过，34源后验一致。此前复用另一源码目录的 local cache 时误运行旧201测试二进制，已保留该轮记录并明确不计为218测试验收；不同绝对源码目录分别持有local cache，global cache仍可共享。
- 单段M+Q/C的start/end使用原控制多边形的第一个非零端点切向量，接受非恒定同端点loop及解析器正规化后的相对/S/T命令。constant曲线、更多段或闭合曲线在本片明确拒绝，不以flatten顶点代替原始顶点。没有增加持久字段、第二份Path或默认路径分配。
- 累计34源完成独立review并冻结。作者Debug/ReleaseSafe各225/225、两优化两缩放原生各9/9，默认14场景完整指纹一致；root独立ReleaseSafe纯225/225，34源后验一致。曲线片的root原生/Windows组合继续，混合L/Q/C作为后续独立切片推进，父项仍在实施。

### B03/P01 Linux显式有界PNG截图

- 独立capture_preview能力只开放capturePreview，默认关闭不创建budget/Op/PNG buffer；不连带开放Find、Cookie或PDF工具。每个实际GTask持有自己的Op，finish取得拥有型Cairo surface，同步主线程编码到预留有界buffer，销毁surface后才借出PNG；取消/关闭的迟到finish只回收C资源，不调用已撤离Zig对象。
- View在recover中复用同一budget，物理槽直到GTask finalizer才归还；每budget最多8请求、进程同时最多8请求，关闭或新attach不绕过。默认每请求4MiB、最高16MiB，分别最多预留32/128MiB PNG buffer；SDK surface、编码临时内存和UI编码耗时另计，没有隐藏worker或UI等待。默认固定记录各增一个nullable指针，Linux x86_64 View/C State从5016/2464到5024/2472字节；启用budget64字节、每Op56字节。
- 14源冻结并完成交叉review，作者Debug/ReleaseSafe两缩放实际PNG检查各13/13，C owner各5/5。root独立ReleaseSafe2x实际PNG13/13、C owner5/5、test-webview92通过/13平台跳过，14源后验一致。完整像素和尺寸oracle覆盖取消、deadline、导航/reload/recover、close/Stop、回调释放owner及最终物理资源归零，未打开图片或浏览器，不建立视觉质量结论。
- build/check和可选Linux CI已接入capture-zig/capture-owner及2x检查，CI配置已解析，远端未运行。Windows冷拒绝回归和新组合整体验证继续；Linux Find/PDF仍按各自未满足的原生合同保留明确UnsupportedCapability。见[页面策略](pages.md)。

### G01.5 开放混合曲线的原始顶点标记

- 单一开放M/L/Q/C路径现可混合端点与mid标记，方向来自相邻原始段的端点切向及不按长度加权的半角；控制点和flatten顶点不产生额外实例。首次遇到曲线才进入混合扫描，已验证的直线前缀不重扫、不重复计费；全部原始段验证后才展开引用。constant曲线、零长直线、多M、arc和闭合混合曲线仍明确拒绝。
- 累计34源冻结并完成root独立源码review。作者Debug/ReleaseSafe各231/231、两优化两缩放原生各9/9，14个旧场景的28条完整像素/分配/工作量指纹逐字段一致；无新增持久字段、顶点数组或拥有分配。root另以ReleaseSafe2x完成SVG/text/image联合25/25步骤、231/231纯测试，34源后验一致。Windows组合和闭合曲线后续切片继续，不宣称整个SVG完成。

### G02/T06 同帧语义局部矩形批量查询

- Frame.semanticLocalBounds一次批量读取当前pending Snapshot实际记录的语义描述符，完整Tree与frame/source/candidate/space/clip权限只验证一轮；不从裁剪后的窗口AABB反推局部几何。最多128项、固定2KiB候选栈存储、整批原子输出，不分配或追加任何表。相同Ref可按当前offset精确重基，原点和右/下边缘都必须准确恢复，否则明确InvalidGeometry。
- 四文件切片已冻结并完成root源码审阅。Linux Debug/ReleaseSafe各128/128纯测试，原有仿射UI原生分别在Debug1x与ReleaseSafe2x各9/9通过、资源归零；Frame/Context/Semantic记录大小未变。Linux公共入口仍在权限校验后明确SemanticGeometryRequired，数值oracle使用私有测试入口，不由此宣称Linux原生语义或AT-SPI完成。Windows公共正例、typed辅助控件桥接和完整组合验证继续，见[仿射坐标](affine.md)。

### 838文件 Windows 组合复验

- 同一固定838文件源码在 Windows ReleaseSafe、GPU/UIA/WebView配置下完成完整test/check及相关隐藏窗口检查：427/427步骤、1108通过/7平台跳过，全部838后验哈希一致。覆盖闭合M/L标记、Cookie身份删除的Windows冷拒绝、旧Diff输入和原生生命周期；不把这一结果推广到随后新增的曲线或Linux工具。
- 保留早期837组合的unified之前失败记录及未确认的原始根因。线程键盘modifier隔离缺口已有独立受控复现及修复，后续组合通过本身不能证明它解释了所有较早失败。

### G01.5 闭合混合曲线及共享arc精度

- 单一M/L/Q/C/Z路径的标记使用原始段和真实closing edge：首尾共享seam方向，最后列出顶点的mid由该段incoming和closing方向组合。不以flatten点增加实例；零长closing edge、constant曲线、多subpath等未支持输入继续明确拒绝，既有全直线路径的扫描和算式保持。
- 累计34源冻结，经独立review和root Linux ReleaseSafe2x SVG/text/image联合检查，25/25步骤、238/238纯测试及实际隐藏回放通过，后验哈希一致。作者两优化两缩放原生各9/9，默认及旧闭合场景完整像素/分配/工作量指纹保持。Windows新组合继续验证。
- 另以正式RED复现极小但非零arc弦产生非有限中心、且bounds/A8/compiled消费结果不一致的问题。共享solver新增有限性检查，三种实际消费均明确返回UnsupportedArcPrecision；没有改写可表示输入的求解算式或Result/Ellipse布局。作者两优化各vector41和SVG238共279/279、32条旧完整指纹保持。三个冻结源已加入下一份组合快照；新增九项标量检查有实际成本，不据此声称零开销或耗时改善。见[向量](vector.md)和[标记](svg-markers.md)。

### T04/G02/T06 仿射typed Diff控件桥接

- 显式typed toolbar/hunk/fold控件从同一Frame真实语义描述符取得局部矩形，并与正文共享同一成功Space、完整publication和裁剪链；自定义auxiliary计划仍明确不支持。native一次发布正文和辅助几何，MTA动作只读取独立原生快照。焦点按已接受key查原Frame ID，准备失败的新bank不能替换旧front。
- 每个排队辅助动作捕获publication serial；即使Diff epoch相同，新Space也会撤销旧动作。setContextPresented在进入时固定完整坐标代数，贯穿候选分配/释放与四种成对文档发布的最后守卫。没有新增正文、选区或undo模型。
- Windows Debug真实split/unified检查通过，包含公共semanticLocalBounds、toolbar命中/焦点、失败front、旧队列撤销、context重入和单次undo，最终native资源归零。初版隐藏fixture缺少线程焦点前置条件已补齐，生产FocusDenied策略未改。root逐一撤除serial、context代数和已接受bank焦点三项保护，分别在精确版本、StalePresentation和ControlUnavailable断言捕获预期失败；每轮均恢复并复核十五份候选源。
- 在已测64位Windows，native固定State2912字节、可选AuxMapping2400字节；split/unified测试所计字节峰值分别129267/118659，范围与既有预算及不计项见[Diff语义合同](document-diff-accessibility.md)。没有把布局大小或本轮检查当成性能改善。随后同一844文件组合的Windows ReleaseSafe真实split/unified及两平台整图检查均通过，父T04/G02/T06仍继续实施。

### G01.5 共享arc端点方向与单段标记

- Arc.endpointDirections返回纯值的局部前向outgoing/incoming向量，沿Path相同输入校验和同一椭圆求解器；相同端点省略返回null，零半径/不同端点返回直线方向。编译期geometry/directions投影不让已有bounds/A8/compiled几何路径计算新方向；Result/Ellipse/Arc/Path布局保持，Directions payload为32B，nullable/error返回包装另计。
- 单开放M+A的首尾marker使用该解析切向，不从弦或flatten点推断；相对命令、旋转、半径纠正/负半径、四flag及整体effects分别检查。无实际mid不查其引用，混合/多arc/闭合及省略arc的更广marker拓扑仍按明确边界拒绝。
- 九源变更、累计38源已冻结并独立源码review。作者两优化各286/286、两优化两缩放原生各9/9，32条旧SVG完整指纹保持；root另以ReleaseSafe2x执行vector/SVG/text/image联合28/28步骤、286/286，真实回放及38源后验一致。Windows新API/arc marker组合待下一份固定快照验证，未据此推定整个SVG或性能改善。

### B02.2/P01 Linux可信文档初始化器

- Linux复用现有拥有型可信函数体编译器和事务簿，在主线程有界转换实际UTF-16 batch，完整准备后才同步修改未来文档的精确SDK注册对象。private/public bootstrap和用户batch各有独立引用，外部撤权回调后重新核代数并取当前batch，按private→public→用户batch排序。导航各入口有明确注册门，不以JS求值、隐藏页面或等待ACK替代原生注册。
- installed只表示本地manager已提交未来文档注册，不保证WebProcess ACK、语法有效、执行成功或当前文档回滚。真实替换通常在公开方法返回前同步完成，提交点后的cancel返回false；source与物理槽先退休再交completion，completion可同栈替换/关闭/Stop。
- 十六源冻结并经分开审阅生产及最终fixture/docs。作者Debug/ReleaseSafe两缩放真实TLS均15/15、C owner七组、纯18/18及WebView97通过/8既有跳过。root独立ReleaseSafe2x复验同一16源：C owner3/3、TLS15/15、单元13/13步骤且97/105、纯5/5且18/18，后验全符。独立双服务严格核10文档/10消息/5安装及8/1请求，覆盖旧文档不变、origin/top/opaque、输入拥有、OOM、同栈重入、recover/旧PageId和close/Stop。
- 已测Linux x86_64 View仍5024B，CState2472→2496B；默认不建initializer owner/预算，已有bootstrap boxed引用持有期变化与SDK内部成本另计。选配预算/owner/op为32/32/56B，首次失败可留下空选配记录至关闭。GObject弱通知和归零计数只证明被追踪适配层责任及预算退休，不能由额外raw SDK引用推定C owner仍活或引擎内存已消失。错误测试假设及其失败原字节已保留。见[初始化器](document-initializers.md)；新的Windows及完整组合继续，B02父项仍部分完成。

### 第七份固定源码整图复验

- 同一844文件快照Windows ReleaseSafe开启GPU/UIA/WebView，test/check与相关原生目标431/431步骤、1138/1145测试通过、7项明确平台跳过。typed Diff控件、公共局部语义查询、正文MTA快照、成对折叠/上下文、闭合L/Q/C marker、文字和嵌入图片实际检查通过；1000窗口后records0/slots1，GDI12→12、USER6→6；15个App和99次pending关闭后COM0。
- 相同快照Linux ReleaseSafe2x为289/289步骤、1109/1123测试通过、14项平台跳过，覆盖test/check、Core停止、实际SVG/文字/图片、仿射编辑器、Diff、TextBinding、输入门、范围标记、Unicode单位和PNG物理所有者。两平台退出后的844文件哈希均完全一致；check只编译的目标没有算作原生运行。
- 本份包含闭合混合L/Q/C与共享arc精度、同帧语义批量查询及typed Diff控件；单段/混合arc marker和Linux初始化器分别已有独立验收，将进入下一份整合。快捷键作用域、无页面Linux版本发现及闭合arc后续继续，完整路线图保持实施中。

### R06/B01 Linux 显式 DSO 引擎版本发现

- 显式调用者 worker 载入绝对 POSIX UTF-8 DSO 路径，先解析全部三个版本入口，再查询版本并尝试一次关闭；不创建 App、GTK、Profile、页面或隐藏线程。符号属于该 handle 的解析范围（可含依赖），不据此认证目标文件身份，也不把版本可查询当成页面可初始化。
- 结果保留 loader 的有界原始诊断及阶段；任意载入失败不猜作 Runtime 缺失。主错误和关闭错误分别保留，关闭失败不重试、不宣称引用归零。取消发生在已载入库之后仍履行清理责任。显式空路径、不可读预取消地址、缺任一入口、缺依赖及关闭失败有独立检查。
- 八源冻结清单 674E6B95E7E4C4DBDA5C2DB777A73E8D240ED599865761C7EB170AD6B9C2A994。root Linux ReleaseSafe 独立检查22/22步骤、10/10纯测试，真实库九次查询与独立C worker均得到2.52.6；依赖故障库无RPATH/绝对NEEDED，未安装其唯一依赖。Windows ReleaseSafe回归6/6步骤、4/4纯测试，真实loader九次查询156.0.4314.23，预热后句柄稳定、loader释放且检查时无存活子进程；两平台所有八源后验哈希一致。
- Linux Result为288字节（旧272），Windows Result/Failure/Options布局保持；SDK构造器可以分配或注册进程状态，不宣称零SDK堆或dlclose卸载。CI接入独立目标并完成本地配置解析，远端未运行。macOS实际发现与完整R06/B01继续，见[引擎发现](webview-runtime.md)。

### G01.5 开放混合圆弧与闭合圆弧标记

- 开放单子路径支持原始 L/Q/C/A 顶点，闭合子路径支持非零 Z：共享接缝使用真实关闭边与首段 outgoing 的角平分，最后 mid 使用末段 incoming 与关闭边；首尾重合的两个实例按源顺序独立绘制。解析与 mid 两遍各自前向处理，每遍每个 A 至多一次端点方向查询，不把控制点或展开顶点作为 marker。
- 最终闭合七源0616BD34226BAB5D6AF702BE0A797A764CC3C25A86AEE9334FF730D72A45742E，累计38源55447EEEA22AB11DAFBB58F5977B774D4327B95E5962555DEF013BC1FE7B3ADE。作者Debug/ReleaseSafe各254/254纯测试，Linux两优化×1x/2x原生各9/9；36条完整旧指纹逐字段保持。root独立只读review无确认问题，ReleaseSafe2x为28/28步骤、vector44+SVG254共298/298，SVG/文字/图片原生回归与全部38源及U02.2 v4依赖八源后验哈希通过。
- 原始MidCursor仍32字节，闭合mid路径声明该局部cursor并执行分派，包含无A的闭合曲线；没有新增拥有分配或Path/Style/Frame/Plan持久字段，不据此宣称零CPU/栈成本。内部零段、零关闭边与省略A仍明确拒绝；开放纯M/L零L拓扑正在下一子片实施。Windows闭合圆弧整合与完整G01.5继续，见[标记合同](svg-markers.md)。

### U02.2 有界快捷键scope与显式Escape续交

- 可选workspace共享两份scope bank与现有128条命中记录，32 scopes/16层；复用既有控件focus及真实TextClientToken，无第二focus或文档。原flat路径保留，overlay顺序/barrier只作用于注册快捷键。成功renderer front、安装代数、routing、焦点/文本/IME身份共同限定权限；失败候选、重建、clear/reprepare及focus ABA均撤销旧请求。
- bare非repeat Escape可显式等待一个新front，cleanup后只提交一次App.post；Full/Closed不转移失败任务所有权、不重试或隐式fallback，accepted任务允许Context在on_closed立即释放。动作和fallback只在事件/任务阶段执行。
- v4八源清单D15841F24288A590477F669E565BAE57038D6A7530D85D239264126DF92E2648；Windows root ReleaseSafe22/22步骤、152/152纯及GDI/hardware/WARP各7个实际场景通过，Linux root27/27、145/145及scopes/widgets/affine/composition原生通过，全部后验哈希一致。此前Windows9项纯测试误用fake HWND进入真实UIA，最小修正仅为测试显式关闭semantics；真实native夹具保持UIA开启，生产Context实现未变，失败日志保留。
- x86_64 Linux默认Input/Context各增加16字节，scope workspace2344、替换峰值4688字节，无默认scope分配；声明的stack prologue局部成本与不计项见合同，不称总栈峰值或零开销。其他未消费键通用续交和原生多击继续，完整U02未完成。

### T06 Linux通用原生子节点宿主

- 构造期显式children宿主已实现，默认plain DrawingArea与输入/IM路径保留；prepare/mount/withdraw单binding，provisional先登记，退休先撤入口再断stock parent关系。核心不导入Document/UI，Linux文档Bridge仍Unsupported，AtkText/AT-SPI另行实施。
- 作者8源84359D23A44CBAB69A340BE1E147F8C366C5C62E927103331BCED81DC9CCB218；真实旧constructor compiled RED及两优化×1x/2x原生各8组/18child精确finalize通过。root独立Linux45/45步骤、246/246纯与相同8组/公开构造/窗口复用/App停机/输入合成回归通过，12源及UI8源posthash一致；Windows公开children入口提前Unsupported、不读不可读title，scope整组22/22、152/152通过。
- Root测量两平台Options/Record固定各+8字节，App/Window大小不变；选配token72、area/host各新增40字节，NativeWindow416不变。真实SDK全局class、raw window提前hide信号、未注入实际构造失败及其他未验边界见[宿主合同](accessibility-host.md)。

### G01.5 开放纯M/L零段原始顶点

- 支持leading/trailing/internal/all-zero L，原始每个mid和起终实例按源序独立绘制。零段start/end方向分别借前后非零段，单零R→D两mid为0/90度，双零才额外出现45度；不会删除重合顶点。单调双anchor cursor为O(n+v)/O(1)，额外分类扫描只进入含零L且实际解析mid的分支，所有计费/取消使用原parent预算。
- 最终七源9DA3CAE1EF83FFD2BFB7787346771DF6C91D8AC8B119415DF50BAA9C444721B1、累计38源F3E6346E8440C58D931CE75A1900EB048231725605BF63271695824F6EE118BA。作者两优化纯各263/263、36旧完整指纹一致，原生两优化×1x/2x各9/9、36 fixture-mode×3DPI；root独立源码review无确认问题，ReleaseSafe2x28/28步骤、307/307纯，SVG/text/image实际回放及38源、UI8和额外依赖11源posthash通过。
- 私有OpenTopology payload56字节、cold cursor80字节，持久记录和拥有分配不增；payload不冒充optional/error返回ABI或实际栈峰值。sample_color四次alpha128最终一次round为239、pixel逐层round为240均由独立合成oracle验证；原content-before-width0门禁保留。混合零L+曲线、constant Q/C、零Z及省略A继续明确拒绝，Windows整合与完整G01.5继续。

### 第八份组合验收

- 固定848源，清单E5A283B566729BF009488DF407ECF51193CF9C16CC31A8C2C677DBF5594C3CD5。Windows ReleaseSafe440/440步骤、1150/1157通过/7平台跳过；Linux289/289、1126/1135通过/9平台跳过及十个真实WebKit探针全部通过，两平台源后验一致。该副本包含开放混合A与Linux初始化器，不含后来scope/runtime/closed/zero/GTKhost子片。
- Windows额外HTTPS页面29/29步骤、130/135通过/5跳过，初始化器与凭据各四种真实wire模式通过，wrong-certificate无后续请求；848源后验一致。日志与receipt均保留缓存外。下一份组合继续合入上述已独立验证的新子片，完整路线图仍实施中。

### T06/P02 原始 GTK area 的显式位置快照

通用可访问宿主新增私有 token-scoped 32字节位置 POD，既有 token72及NativeWindow416不变；不新增窗口记录、任务或默认绘制工作。原始area allocation与真实parent GdkWindow决定GTK逻辑原点，flags区分extent/window/screen可用性；未映射及未验证的Wayland原点不伪造。root独立Debug/ReleaseSafe×1x/2x各19/19步骤、精确九源前后哈希通过，含真实SDK坐标、负奇数物理像素HiDPI回归、mount同步信号BUSY、错误线程/输出保持、原始area/live window关闭及旧token跨App。最初直接取area Gdk原点的问题由独立review指出并以真实X11 RED确认，修复后保留该回归。文档AtkText/外部AT-SPI仍在独立实施；该坐标首片不代表完整T06/P02或Wayland验收。

### G01.5 单个零长终端 Z 的标记拓扑

非零L/Q/C/A原段后可保留单个零长Z，闭合首尾共用last-incoming/first-outgoing接缝，Z前最后列点仍是独立mid、使用last-incoming两侧极限；同点角色不合并。完整预检、自动180门禁、Plan内容/尺寸/NSS及原有work/预算/取消保持；内部零段继续明确不支持。仅marker.zig一处生产文件变化，Middle32/MidCursor32及两后端API不变，末A的incoming从同次共享查询捕获，无第三次求解/前缀回扫。作者D/RS各272/272、旧36及新增zero-open四条完整指纹一致，四组D/RS×1x/2x原生各9/9，38个fixture-mode分别覆盖三个准备DPI；root独立ReleaseSafe2x为28/28、316/316，含单独SVG文字/图片，38源+UI8+当前Core等13依赖前后哈希通过。精确38源小归档保留；Windows和后续固定整图另行验收，不能由本片声称完整SVG。

### 第九固定快照的 Linux 整合验收

862份固定源码在Linux ReleaseSafe、GTK2x下完成311/311步骤，1165/1174项测试通过、9项明确跳过；另完成初始化器owner/Zig、PNG owner/Zig、基础/动态资源/远程导航/导航/区域/离窗Session共十条真实WebKit原生探针，全部结束后862份源码哈希仍匹配。该快照整合嵌套输入scope/显式Escape、通用GTK可访问宿主、LinuxRuntime查询、闭合Arc及开放zeroL；不包含之后实施的zeroZ、位置POD、LinuxAtkText或词查询。

同一固定快照的Windows ReleaseSafe完成454/454步骤、1183/1190测试通过及7项跳过；额外运行时发现/卸载与GDI、hardware、WARP三种快捷键scope均实际通过。独立HTTPS检查为29/29步骤、130/135测试通过及5项跳过，初始化器和凭据各四种wire模式通过；主检查和wire结束后862份源码均匹配固定清单30787F09BA15D3C760BF11D0EE091A7B4963E9BBE79F36C56134ABC04BA2C912。两份Windows日志分别为A442C94AE29A940B614FF95AC925033626388ED11EA0BEA5237AAD421B0518DD和8FA46D2F8875A7F7A44B36524C04A5FEE5C0810D428CF7CD4307052F2E73058F；不将这些结果推广至快照外的后续子片。

### G01.5 闭合纯线段的内部零长 L

单个终端Z的纯M/L路径可包含内部零L；真实Z参与线性后续方向查找，首尾独立角色共用闭合接缝，全零序列显式使用正X。统一滚动cursor单调分类，保留普通非零路径的公式和计费；两绘制后端共用预检及拓扑。新增私有返回payload从32增至40字节，冷cursor80字节不进入普通分支的持久状态，没有新增拥有分配；未测栈峰值或CPU性能。混合零段/曲线及更广退化段继续实施。

精确38源小归档E7EDE7D0798035E6A984176D70F00D3B18EC22C6FCFA858456CF591B60B93FA6：作者Debug/ReleaseSafe各281/281、44条完整旧指纹相同，Linux两优化×1x/2x原生各9/9。root独立ReleaseSafe2x完成28/28步骤、vector44+SVG281共325/325，含20个SVG fixture×两模式×三个准备DPI、独立文字/图片原生回归及38源、scope8、当期依赖24的前后哈希。root日志B37C60816933ACAFDC5175BCF14642AD391C89A837ABA7A5EF9D5ECD4AFD8088；该Linux验收不代替Windows整合或完整SVG支持。

### T01/U02.3 显式准备的词范围查询

TextLayout 新增构造期开关 Options.word_ranges 与 Layout.wordRangeAt(Caret)，在不可变 UTF-8 快照中返回逻辑半开范围。只接受真实字素端点，边界 affinity 选择逻辑前后，0/EOF 钳制首尾单位，空文本返回空范围。保留系统 lexical interval，连续非词间隙合并；ICU 与 Pango 的中日韩、标点等结果可不同，不引入 ASCII 覆盖规则。查询为二分，无 SDK 调用或分配；构造时使用唯一已有原生 Layout 和捕获输入，有界索引单次分配8+4G，全部峰值预算和关闭/lease/失败回滚仍有效。

精确十一源 v2 清单 FE1CFE422A97D406244B7C58D18B2683D6662D732A5321E2E2B7CC2873345EE7。Linux作者两优化的SDK oracle、helper、纯测试、fault、旧Layout/capture及v2强化分配尝试计数已实际通过。root独立Windows Debug/ReleaseSafe每轮34/34步骤、2/2纯测试，含15种语言/locale的bulk/reference、8192G/65536B、错误位置/线程/限额、逐项OOM、输入捕获/lease、精确及差1峰值；独立ICU版本72.1.0.4，enabled-empty缺导出也明确失败，普通构造不要求该新增导出。22项实际源码/依赖前后哈希匹配，root验收记录8CEAAE801C5288D7460175AAE8961686254F54AE897C6CE0350C0C5D10D10DC0。

两平台两优化的四组默认分配请求/次数/owned/peak/模块调用trace与各自旧基线逐字一致；Options56、LayoutState672、Engine352，空文本不开索引分配。该证据不覆盖SDK内部存储、词典成本、CPU、总体RSS或二进制大小。原生多击、编辑器词/行选择及完整U02.3继续实施；整图test/check和相关隐藏原生回归在下一份固定快照继续验收。


### Linux 文档只读与完整 Prepared 命中窄片验收

候选14文件 C61679A44C8124F5B1F5077FFAAE78AEB385EE9DAC3F186700F1FB0CB492DE7B 已通过作者两优化×1×/2×矩阵。Root 独立 ReleaseSafe 2×为31/31步骤、39/39单测、8组C owner、216+476个真实点比较；正式脚本外部AT-SPI另21/21并验证独立进程发现、Unicode/CHAR、point、替换与defunct。两次各141依赖前后匹配，原scroll1失败输入保持原布局/裁剪转绿，最后账本归零。Root回执 E8E29303AC1B87EE2665259169B8F1E6A650DE28FFF7CE32FA6D12598BC47649。

输入与只读快照共用无SDK纯命中内核，完整候选不随可见几何裁剪，过滤资格另走本次实际可见line域；没有完整packet时不可退回近似可见caret。两遍预检保持全部caller buffers事务，快照不借Adapter/Document/Engine；结构遍历单调，完整成本另含每stop既有Document索引查询，工作计数不代表CPU期限。C只拥有同一Geometry内的packet和数组，关闭后不回访Zig。

本片限Linux单源只读Text/Component，不含选择/修改/focus动作、多源、affine provider或完整语言单位；Windows原生point尚未迁移。共享Editor改动的Windows回归与全图test/check另行整合，未以旧UIA检查代替新point修复。

### G01.5 开放零长多项式路径的整合验收

单个开放子路径的 L/Q/C 可包含零 L 或恒定 Q/C；非恒定同端点曲线仍保留两端真实方向。零段按原始线性序列分别借前 incoming 与后 outgoing，所有原角色按源顺序独立绘制。共享预检和单调 cursor 为 O(n+v)、常数额外状态，沿用父准备账本；未新增方向数组、拥有分配或持久绘制字段。私有成功返回 payload 从48增至56字节的成本已明确保留，不据此推定实际栈峰值或CPU成本。

精确38源清单29042D74ABDE3C399A345040B24BD193D60AE7EE1672FC05141EB908A67CA02C：作者 Debug/ReleaseSafe 各290/290、48条完整旧指纹一致，并完成 Linux 两优化×1x/2x 原生。Root 独立 Linux ReleaseSafe2x 为28/28步骤、vector44+SVG290共334/334，含SVG、文字与图片原生目标；Windows 两优化各33/33步骤、334/334测试，SVG在GDI、hardware、WARP实际回放并通过独立文字/图片回归。Windows每轮242份实际输入前后匹配，Linux亦核完整依赖；合并回执76EDB22AC741D003BB08A0EF50A3867169CBF1BD0D6FBC26FFB574DD15E6FC74。

验收限本片开放 L/Q/C 的退化组合。闭合退化组合、退化 Arc、多子路径和更广SVG能力继续分项；隐藏原生像素检查不代表视觉质量、CPU吞吐或全路线图完成。

### P01/B05 Linux custom 读取与有界请求头策略

既有 LocalSite.methods、request_headers 与注册 request_origins 现由 Linux custom 后端完整捕获并校验：默认 GET/HEAD 不分配策略区，显式策略沿用同一资源与 deferral owner。头名称/值/总量、独立 Origin、静态读取与动态回调均有独立门；策略最多32KiB，不给旧 HTML/资源配置新增统一1MiB上限。每次请求不读取 body，也不补造发起来源。

实际 WebKitGTK2.52.6 的同源 fetch/XHR 写请求已进入 scheme callback，但没有可见 Origin，故在业务前拒绝；注册 secure/CORS 不保证这个头存在。本片只验收 GET/HEAD、显式头授权与安全拒绝，不能标完整 Linux 写方法、跨来源 CORS 或 request body 已完成。首正向写实验失败及原日志保留，未为了通过检查放宽门禁。

作者最终 Debug/ReleaseSafe 的动态、普通和导航六个独立进程均15/15，逐轮455个实际源码/SDK/工具依赖前后匹配。Root独立无observer ReleaseSafe亦15/15，实际授权非X头、any/精确空值、6个头负例和5个缺Origin写请求，以及Full、导航/reload/进程恢复/raw close、旧ID迟到响应仍由调用者拥有、worker私有文件/HEAD零读取/取消/关闭全部通过，最终资源归零。Root日志56A06320679B66A4025BBC5D57A1FEC5C8FDF000F7DCF4A9A1FABD58AE02EA79；11源小归档7C877876FA67B7E32F23031A1518616C0F8AA46328758FA4B0C39862326816AA，回执3DDC882389D58D7E523700A868EA6289C824232711BBEECEEA294092505022E5。

源审查与原生观察分开记录；早期诊断observer复用名单导致首fetch/XHR的依赖名单被后一次覆盖，现存三日志和无observer独立名单，不将其算默认成本证据。共享Zig dispatcher的Windows回归在后续固定窗口继续，完整HTTPS local_site和更广工具仍待实现。

### 第十批固定快照的两平台整合

固定881源清单C07F3A442F5228EFC85639746C116A0ED940651F251CF1004288AF2898F2F541整合开放零长多项式SVG、词查询v2、Linux只读Prepared命中及位置/宿主/输入scope。Linux ReleaseSafe2x完成351/351步骤、1199/1208测试通过和9项明确跳过；Windows ReleaseSafe完成457/457步骤、1217/1224测试通过和7项明确跳过，另完成真实Runtime查询及GDI/hardware/WARP的scope检查。两平台全部881份源码前后匹配；日志分别为BA507E717D561DAD65E580C153437AEF244CE282EEBBC277C91EB6E11028C2A6和4CA6A0E84418242C430A550D2319DABA2C46A5FFE15C6888F88D4AE53C699413。

首次880源检查点漏拷已验收的tests/text_word_costs.zig，导致check单目标编译失败，另触发原3GiB恢复缓存后置限额；失败清单/日志保留。补齐唯一已验测试输入并独立记录4GiB后续限额后重跑成功，固定16GiB缓存盘没有扩容或清理。此快照不含之后的闭合退化多项式、custom请求头或Windows完整point候选；这些继续按独立源片验收，完整路线图仍实施中。


2026-10-18 闭合多项式 marker 窄片段验收：单一 M(L/Q/C)+Z 子路径的零长度 L、常量 Q/C 与有向闭合接缝现复用单调 PolynomialCursor；真实闭合边和同端点曲线保留其切向语义。最终38文件 A0CAE1AF1461C410E8A1CBF449E1FCAC053110ABDBFAB8620E6C16E73D2327C4；独立 Linux 28/28步骤、343/343测试，Windows Debug/ReleaseSafe 各18/18步骤、343/343测试，并实际验证 GDI、硬件与WARP 的22 fixture/native replay、两种采样及三个准备DPI，leases归零。52项旧完整指纹精确一致；普通/open cursor布局保持，closed private payload增加8字节且显式计费。不将该片段写成全部 SVG、视觉质量或性能路线图完成。证据 .validation/drawing/marker-closed-polynomial-root-acceptance.json。

2026-10-18 T06 Windows 完整 Prepared 命中窄片验收：source18 F5A0A1FB192DFBFA5A10798F6BE1BC6652D01E262D007C4BED9872DD9B8F2236。原始39831D诊断同一输入由Adapter0/UIA1变为0/0；Debug/ReleaseSafe GDI、硬件、WARP各2073组owner/MTA点对照，双源和split/unified实际原生对照通过；7项provider与真实最后COMfree时正文/辅助/无命中×关闭6组合均通过。仅移除最终gate的受控版本6组合均编译后真实失败，已恢复。Linux common24/24步骤、39/39测试不退化。Geometry固定头104→112B、额外OwnedHit144B及完整数组、迟到Text引用显式计费；无性能/视觉泛化。T06与编辑器词/行多击等父项继续。证据 .validation/linux-document-accessibility/windows-point-root-acceptance.json。

### 第十一批固定快照的两平台整合

- 同一 891 文件快照完成 Windows ReleaseSafe 474/474 步骤、1233/1243 通过/10 平台跳过，以及 Linux ReleaseSafe 2x 353/353 步骤、1211/1220 通过/9 平台跳过；两端运行后源码哈希全部一致。
- 本批纳入闭合零长多项式 SVG、custom 读取/请求头策略与 Windows 完整 Prepared point。Windows 实际运行 provider、六条最终释放撤销、生命周期、编辑器、WebView、文件、远程与会话检查，并复验三种 renderer 的快捷键 scope；SVG 原生矩阵复用已验收且产品输入逐项相同的 Debug/ReleaseSafe GDI/hardware/WARP 记录。Linux 实际运行 Cairo、文本/图片及对应原生检查。
- 新一轮公开点击事件与 Core/Windows/GTK 接入、UI 消费迁移及 Linux Find 仍在独立实现与验证，不包含在本批已验收范围。私有未接线的纯状态或 C helper 测试不代表这些公开能力完成。完整路线图保持实施中。

### B03 Linux 原生 Find 与真实 native callback 边界

- `FindState.matches/active_index` 改成显式 optional；null 表示未知，-1 仍表示已知无活动项。Windows 原生 known 值保留，Linux 初次 search 提供已知总数、step 不伪造全页计数或索引；whole_word 和关闭高亮在读取 query/分配/修改旧场次前明确拒绝。
- 单 controller 的物理命令在逻辑取消、timeout 或同 WebView 导航后保留占用到真实终态/最后旧 controller 释放；无终态持续 Full，不用隐藏重建、轮询、timer 或第二队列放行。View 预算跨真正 reload/recover 保留，原生 qdata/信号/Command 独立拥有，最后 foreign free 返回才归还额度。
- 最终15源完成独立只读 review，无剩余确认P1/P2。作者 Debug/ReleaseSafe 各完成13/13构建与十个独立真实 Runtime 模式，覆盖顺序/大小写/UTF-8、step unknown、取消/timeout 后物理Full、refresh/reload/recover、普通/raw close/Stop及最后native/Find/observer引用零。恢复实际观察到旧SDK先返回零再发process_failed，不把零结果当恢复成功；故障先到的严格分支未在该Runtime矩阵观察。
- 两优化窄纯检查各16/16步骤、103通过/8明确跳过，C owner十一组归零。旧capture owner五组、capture14/14、普通WebView15/15和navigation15/15两优化均通过；最后一组补验使用27,100源/tool/header/DSO预哈希并审真实Zig h元数据，包含inactive Windows与_test输入。初次漏列测试C输入导致的闭包失败保留，未改产品或放宽断言求绿。
- C→Zig入口使用独立App native scope遮蔽被暂停的原始输入receipt，普通Region/Session转发保持原权限。独立同步C ABI空初始化器完成的旧RED与Windows/Linux D/RS normal/close GREEN均保留，既有initializer close/Stop和cookie-store回归通过；此oracle不冒称SDK异步Add或scope.end内最后free实证。
- 同字节旧891/新源D/RS成本对照：View5024→5032、native State2496→2504、FindState8→16，Options/Book/Slot不变；普通配置和capture-only的caller分配/主要init frame不变，Find首命令前无新增domain/command。query专用noinline own frame为Debug11800/ReleaseSafe5032字节；预算不包含Command保留的完整旧State/config/SDK内存。完整路线图、P01和B03保持实施中，详见[页面合同](pages.md)。

### G01.8 完整子树的live高斯scope

- `Frame.gaussianScope`只记录一次正文，使用显式准备的核和有界透明工作面；GDI/Cairo及可选D3D11程序共享Q24整数两遍滤波。父视觉clip/mask/opacity在滤波后应用，子树内部裁剪先合成；命中、焦点、caret和Space使用原几何。原有f64快照Processor保留独立数值合同。
- 两平台Debug/ReleaseSafe相关纯测试与真实原生回放均通过，包含三个DPI、反射、透明halo、body失败、旧候选预算、分配及原生plane/program失败、最后Snapshot/Texture引用、设备丢失与显式重新准备。Windows hardware/WARP另实际验证180×72物理尺寸、1.5倍缩放的隐藏Context绘制、正文一次和整buffer软件后备；最终资源归零。普通与显式高斯Surface的独立可执行文件检查确认可选shader字节只进入显式路径。
- 纳入同一985文件整合检查点：Windows ReleaseSafe完整构建467/467步骤、1520通过/12平台跳过，三个隐藏原生检查通过；原脚本随后因过低缓存预算失败并保留，修正同一缓存预算后的test/check为455/455且退出0。Linux ReleaseSafe为315/315、1509通过/11跳过，真实GTK/WebView及中性HTTPS ABI对应原生检查均通过。普通paint无滤波工作面分配；这些结果不代表吞吐量、视觉质量或其它驱动验收。见[高斯scope合同](gaussian-scopes.md)。

### V05.1 声明式视图无窗口驱动

- `view.Harness` 复用 Host 的构建、排列与单事件遍，不创建窗口也不分配；按种类、文本、名称和键查询节点，按查询或坐标激活控件并对滑块应用 `ValueChange`，每次成功事件后重新渲染。禁用、被裁剪遮住、种类不符和事件未被消费分别返回明确错误，不静默成功。
- `write` 输出取整边界的树大纲，供测试做文本比较。Host 与 Harness 共用同一 `Build` 绑定，Host 行为不变。
- 范围只限声明式视图：不经过 `ui.Context`，不覆盖原生命中、焦点、键盘、可访问性和测试时钟；V05 其余部分（统一测试时钟、原生输入注入、inspector）继续待实现。见[声明式视图](view.md)。

### V05.2 无窗口键盘回放

- `Harness.attachInput` 把每次渲染记录进测试持有、未连接窗口的 `ui.Context`，`key` 按 `Context` 处理控件按键的同一顺序调用输入状态的快捷键、Tab、范围键、分组导航、空间导航、Home/End 与激活，把结果作为动作或数值事件交给构建，再重新渲染；`focused` 返回焦点节点。
- 无窗口测试覆盖 Tab/Shift+Tab 顺序、单选组作为单一停靠点、方向键选择、Space 激活与重复键忽略、End、滑块方向键，以及列表框方向键选中后滚入视野。不经过原生事件、文本输入焦点接收者和可访问性；统一测试时钟、原生输入注入与 inspector 继续待实现。

### U06.1 标签页、工具栏与比例分栏

- 新增语义角色 `tab_list`、`tab`、`toolbar`、`splitter`，追加在既有编号之后。Frame 提供 `tabList`/`tab`/`toolbar`/`splitter`：标签复用单选分组的命中、Tab 停靠点和方向键选择；分隔条复用范围控件的捕获拖动与键盘步进，上下分栏向下增大，拖动轨道只覆盖上下限之间，指针始终对着分隔条中心。
- Windows UIA 映射为 Tab/Selection、TabItem/SelectionItem、ToolBar 与 Thumb/RangeValue，选择与 Radio 共用同一套单选规则。Linux 没有普通控件的 AT-SPI 层，本片不声明 Linux 可访问性。
- `ziggurat_view` 提供 `tabs`/`tab`、`toolbar`（叶子控件以工具栏为可访问父节点）和 `split(axis, &fraction, limits, style)`（恰好两个子节点，比例在 0..1 的上下限内）。Harness 可以点击标签、调整分栏并读取分隔条矩形。
- 单元测试覆盖分组、重复选择、语义父子与范围、纵向分隔条的指针和方向键；Linux 隐藏窗口 smoke 在 1x/2x 下实测标签点击与分隔条捕获拖动。Windows smoke 另用真实 MTA UIAutomationClient 检查控件类型、工具栏父节点、标签选择与分隔条 RangeValue 读写。DIP 偏好、窗口不足时的显式约束、RTL、折叠、sidebar、tooltip 和 toast 继续待实现，见[声明式视图](view.md)。

### U08.1 链接、徽标、分段控件与折叠区

- 新增语义角色 `link` 与 `disclosure`，追加在既有编号之后。Frame 提供 `link`、`segment` 与 `disclosure`：分段复用单选分组，链接与折叠区复用按钮激活；三者都参与 Tab 焦点。Windows UIA 映射为 Hyperlink/Invoke、RadioButton/SelectionItem 与 Button/ExpandCollapse，ExpandCollapse 在状态已符合时不产生动作。Linux 不声明 AT-SPI。
- `ziggurat_view` 提供 `link`、`badge`、`segmented`/`segment` 与 `disclosure`。徽标只是带背景的静态文字，不计为控件，也不产生语义节点；单个 `disclosure` 不等于多段 accordion。
- 单元测试覆盖分组、方向键选择、激活和语义；Linux 隐藏窗口 smoke 在 1x/2x 下实测分段、链接和折叠区的原生点击。Windows smoke 用真实 UIAutomationClient 检查分段选择、链接 Invoke 与折叠区 ExpandCollapse。见[声明式视图](view.md)。

### U04.2 声明式视图列表框

- 新增语义角色 `list_box` 与 `list_item`，追加在既有编号之后，与虚拟集合使用的 `list` 分开。Frame 提供 `listBox` 与 `listItem`，选项复用单选分组：一个 Tab 停靠点，方向键与 Home/End 移动并选中。Windows UIA 映射为 List / Selection（单选）与 ListItem / SelectionItem。Linux 不声明 AT-SPI。
- `ziggurat_view` 提供 `listBox`/`listItem`。输入选中的选项在下一次排列时被外层滚动容器以最小位移滚入视野；选项全部参与构建，不做虚拟化。
- 单元测试覆盖分组、方向键导航与语义；无窗口测试覆盖选中、半遮挡选项的滚入与重复选择不滚动。Windows smoke 用真实 UIAutomationClient 检查 List 的单选 Selection 与 ListItem Select。

### U10.1 表单字段与字段集

- 语义节点新增 `description`、`invalid` 与 `required`。说明与名称、值一起复制进固定文本存储，导出子树时一并复制。Windows UIA 映射为 HelpText、IsDataValidForForm 与 IsRequiredForForm。`widgets.Options` 带同名字段，只进入语义，不参与绘制。
- `ziggurat_view` 提供 `field` 与 `fieldset`。字段按标签、内容、帮助或错误的顺序排列；字段内的控件取得说明与验证状态，没有名称时以标签为名。`Embed.annotate` 把同样的信息交给嵌入叶子，`ziggurat_view_text` 的文本框据此调用 `Field.drawDescribed`。任何容器的 `enabled = false` 都会传给全部后代。
- 单元测试覆盖语义文本导出与容量、无窗口的字段排列、错误清除与禁用继承。Windows smoke 用真实 UIAutomationClient 检查标签名称、HelpText、表单有效性和必填状态，以及字段集分组。

### U08.2 度量条、评分、面包屑与手风琴

- 新增语义角色 `meter` 与 `navigation`，追加在既有编号之后。Frame 提供 `meter`、`rating`、`navigation` 与 `group`。度量条只读，报告实际值与上下限，值在首选区间外时用主题新增的 `caution` 色。评分是步长为 1 的范围控件，轨道从第一个标记前半格开始，按到哪个标记就取哪个分数。Windows UIA 映射为 ProgressBar（LocalizedControlType 为 "meter"）、Slider，以及带导航地标的 Group。Linux 不声明 AT-SPI。
- `ziggurat_view` 提供 `breadcrumbs`、`meter`、`rating`、`accordion`/`section`。面包屑在间隙中画分隔符；手风琴最多打开一节，再次激活已打开的节会关闭它。面包屑和手风琴里的控件以容器为可访问父节点。
- 单元测试覆盖区间与参数校验、评分标记命中、语义角色与父节点，以及无窗口的分节切换和评分调整；Linux 隐藏窗口 smoke 在 1x/2x 下实测评分的原生点击。Windows smoke 用真实 UIAutomationClient 检查导航地标、度量条只读 RangeValue、评分 SetValue 与分节 ExpandCollapse。

### U04.3/U04.4/U05.2 声明式视图的树、表格、可编辑组合框与标记输入框

- 新增语义角色 `tree`、`tree_item`、`table`、`table_header`、`column_header`、`table_row`、`token_field`、`token`，追加在既有编号之后；语义节点新增 `multiple` 与 `expanded`。Frame 提供 `treeView`、`treeItem`、`dataTable`、`tableHeader`、`columnHeader`、`tableRow`、`tokenField`、`tokenItem`、`comboField` 与 `comboToggle`。Windows UIA 映射为 Tree、TreeItem / SelectionItem / ExpandCollapse、DataGrid、Header、HeaderItem / Invoke（ItemStatus 为排序方向）、DataItem、List / ListItem（标记）；多选集合报告 CanSelectMultiple，AddToSelection/RemoveFromSelection 经数值请求只改动该项。Linux 不声明 AT-SPI。
- `ziggurat_view` 提供应用持有的 `Selection`（按稳定项 ID，容量由调用者给出）、`tree`/`treeItem`、`table`/`tableRow`（`Column`、`Sort`）、`editableComboBox` 与 `tokenField`/`token`；`Embed.status` 报告输入法组合与空输入。行共享一个 Tab 停靠点，键盘与指针支持单选、Ctrl 切换、Shift 范围、Ctrl+Shift 追加范围、Ctrl+A、PageUp/PageDown 与树的 Left/Right 层级导航；表头与各行按全部单元格的内容统一求列宽。可编辑组合框在组合期间隐藏建议并把按键留给输入法。标记输入框按宽度换行，排列宽度变化时再测量一次。
- 无窗口测试（含 `-fllvm`）覆盖树的展开、三角按下、键盘层级导航、按 ID 保持选择，表格的排序、列对齐、多选修饰键、Ctrl+A、翻页与滚入，可编辑组合框的打开/关闭/按钮/组合期间隐藏与选中后焦点，标记输入框的换行、移除与焦点移动，以及选择容量。Linux 隐藏窗口 smoke 在 1x/2x 下实测树的三角与行按下、列头排序、行选择、列对齐与标记移除。Windows smoke 用真实 UIAutomationClient 检查树 ExpandCollapse/LeafNode/选择、DataGrid 多选、列头 Invoke 与 ItemStatus、标记的控件类型。行不做虚拟化；列宽拖动、冻结、重排、读屏实际播报与视觉质量未验收。见[声明式视图](view.md)。

### U05.1/U06.2/U08.3 组合框、建议列表、提示、通知、导航按钮与头像

- 新增语义角色 `combo_box`、`tooltip`、`status`、`search`、`image`，追加在既有编号之后。Frame 提供 `comboBox`、`popupList`、`navButton`、`avatar`、`tooltip`、`status` 与 `search`。Windows UIA 映射为 ComboBox / ExpandCollapse / 只读 Value、ToolTip、Polite 实时区域的 Group（出现时引发 LiveRegionChanged）、带搜索地标的 Group 与 Image；Value 只在文本框上可写。Linux 不声明 AT-SPI。
- `ziggurat_view` 的 View 持有唯一一个打开的列表：组合框由激活或方向键打开，建议列表跟随锚点焦点；高亮是虚拟的，焦点留在锚点上，选中或 Escape 后焦点回到锚点。建议列表在选中或 Escape 后保持关闭，直到标签变化。列表外的按下关闭列表，组合框列表还会吞掉这次按下。列表、通知与提示在主树之后按顺序绘制并优先命中，不受祖先裁剪。
- 每一遍带有时间，构建通过 `wakeAt` 请求下一遍。Host 只在 paint 之后投递任务，把最早期限交给调度器；`ziggurat_view_timer` 用 `ziggurat_wake.OneShot` 实现调度，期限变化时取消旧装定，没有期限时不装定，不引入持续重绘计时器。
- 无窗口测试覆盖提示的延迟、按下/Escape/离开隐藏与焦点触发，通知的到期、动作、关闭与满队列淘汰，组合框的打开、方向键、Enter/Escape/Tab/外部按下、选项点击、靠近底边时向上翻转与列表内滚动，建议列表的焦点打开、高亮、选中后关闭与重新打开，导航按钮、头像与搜索区域，以及浮层绘制顺序和 Frame 语义角色。Linux 隐藏窗口 smoke 在 1x/2x 下实测组合框列表的原生点击选择、导航按钮点击，以及通知经真实一次性计时器到期后窗口回到无期限的空闲状态。Windows smoke 用真实 UIAutomationClient 检查组合框 Value/ExpandCollapse、搜索地标、导航按钮 Invoke、Image、提示作为 HelpText 与通知的 LiveSetting。实时区域事件只在有客户端监听时引发，读屏实际播报、视觉质量与动画未验收。见[声明式视图](view.md)。

### S06.1 上下文菜单、异步消息框与菜单快捷键

- `system.menus` 统一校验菜单栏、上下文菜单和托盘菜单：ID、父项顺序、标签、禁用祖先及快捷键（command 项、不重复、普通键须带 Control/Alt/Super）。`&` 助记符在 GTK 上转为 `_`。
- `Owner.popupMenu(request, items, anchor)` 调用即返回，每个被接受的请求只以 `Action.popup` 完成一次，取消为 null，detach/关闭不回调，只报告启用且祖先启用的命令。Windows 把请求投递到私有隐藏窗口，在主循环分发时才进入 `TrackPopupMenuEx` 的系统菜单循环（与原生移动/缩放相同），已有菜单或移动循环时直接以 null 完成；detach 先切断隐藏窗口的回指，迟到返回的循环只释放自己的菜单。Linux 用 `gtk_menu_popup_at_rect`，在一次性 idle 中报告。
- `Owner.showMessage(request, options)` 1–3 个按钮，结果为按钮 ID、dismissed 或 failed。Windows 用 `MessageDialog` 异步接口，与文件选择器相同只触发独立事件并由 App 单次原生等待在主线程读取；Linux 用 `response` 信号的模态 `GtkMessageDialog`，不调用 `gtk_dialog_run`。
- Windows 菜单栏快捷键在 Content `key_input` 未消费的键上分发 `Action.menu`，忽略自动重复与 AltGr。Linux 没有菜单栏，快捷键只显示在上下文菜单中。
- 纯单元测试覆盖结构/快捷键/助记符/消息参数校验；Linux 隐藏窗口 smoke 在 Xvfb 1x/2x 下实测 GTK 菜单根项/嵌套项/禁用祖先/取消/detach 与消息框按钮/关闭/取消/窗口销毁，原生链接计数归零。Windows smoke 覆盖真实系统菜单循环内的键盘选择、取消、detach、菜单栏快捷键规则与 MessageDialog 异步取消。选择由原生激活接口或消息注入完成，不代表物理输入、人工点击或视觉质量已验收。见[系统工具](system.md)。

### S08.1 独立托盘与锚定菜单

- `system.Tray` 属于 App：每项有自己的隐藏顶层窗口、复制图标和 App 停止登记，可同时存在多个；重新 show 使用新原生 ID，旧回调不会命中。可选 GUID 让系统记住用户摆放位置。
- `Tray.popupMenu(request, items, .icon)` 用系统报告的图标矩形锚定并避开遮挡，取不到时用指针；打开前取得前台以便外部点击关闭。任务栏重建时重新添加图标。
- Windows smoke 实际向 Shell 添加两项，验证事件、旧 ID 隔离、原地更新、锚定菜单选择、任务栏重建、显式移除与 App 停止回收。标题与 popover 亮态没有 Windows 对应，macOS 托盘继续待实现。见[系统工具](system.md)。

### P02 Linux 系统设施（部分）

- 菜单栏：`GtkMenuBar` 放在平台层按需插入的纵向盒中，清除/detach 时内容回到窗口原位；快捷键只在焦点控件未消费后匹配，命令与快捷键在 idle 中报告，勾选状态由应用掌握。
- 托盘：窗口 Owner 与独立 `Tray` 都导出 status notifier item，watcher 出现（含面板重启）时登记；无 dbusmenu，菜单由应用弹出，独立托盘在 X11 上用 1×1 锚点窗口打开。
- 选择器：`GtkFileChooserNative`（门户或 GTK 对话框），异步 response，只接受本地 UTF-8 路径。
- 通知：`org.freedesktop.Notifications`，默认动作激活，替换/清除撤回已显示项。
- 全局快捷键：X11 `XGrabKey`，锁定键组合、冲突错误陷阱、松开前不重复；Wayland 明确返回 `UnsupportedCapability`。
- 剪贴板与拖放由独立工作项实施。`smoke-system-menus` 与 `smoke-system-desktop` 覆盖上述路径，后者用私有会话总线上的替身服务。

### R01.1/R02.1 单文件安装程序、启动器、卸载与 deb

- `ziggurat-setup` 存根按自身内容充当安装程序、启动器或卸载器；`ziggurat package setup` 把更新包和安装配置追加为单文件安装程序，Windows 签名后的证书表在读取时跳过。安装复用更新发布事务（stage 校验、原子 marker、保留归档），写入启动器、卸载器和 `install.json`，支持 `--silent`、用户/机器范围与 `--dir`。同版本即修复，旧版本拒绝，首次安装失败删除已写内容，升级失败回滚到原版本。
- Windows：开始菜单快捷方式（IShellLinkW）与 HKCU/HKLM 卸载项（显示名、版本、发布者、位置、图标、静默卸载命令、大小）；卸载器从临时副本完成删除。Linux：desktop 条目（Exec 引号与字符串转义）、可选 hicolor 图标、`bin` 链接。卸载保留用户数据，`--purge` 删除。`ziggurat package deb` 写出确定性的 deb（未压缩 tar 成员、md5sums、相对 `/usr/bin` 链接、依赖默认 GTK/Pango，`--webview` 加入 WebKitGTK/libsoup，菜单/图标缓存刷新）。
- 单元测试覆盖载荷定位（含构造的 PE 证书表）、desktop 转义与拒绝、deb 确定性和路径/控制字段注入拒绝。本地 Linux 用真实安装程序在私有 HOME 完成安装、经链接启动并检查参数、升级、拒绝降级、卸载保留数据与 purge；deb 经 dpkg-deb 检查后实际 `dpkg -i`、运行、`dpkg -r`。Windows 交叉编译通过；`tests/setup_smoke.ps1` 已接入 CI，Windows 运行结果以 CI 为准，本地未运行。未实现：图形向导、关闭运行中的应用、文件关联注册（等待系统集成工作提供注册函数）、真实证书签名后的安装程序验证、macOS app/DMG/公证。见[打包](packaging.md)。

### R03.1/R04.1/R05.1 更新检查、下载、增量与发布目录

- `feed.check` 读取逐条签名的发布索引，选出本 identity/target 最新完整版本和匹配已安装归档的增量；本 target 条目验签失败使整个检查失败。`download.fetch` 续传到调用者文件，取消保留前缀，完整但摘要错误时截断；`http.Source` 基于调用者的 `std.http.Client` 用 Range 续传。`launch.spawnDetached` 在 `App.run` 返回后启动新版本，退出仍经 `requestQuit` 的否决。
- 增量补丁为复制/插入指令流，签名清单绑定来源版本与归档摘要、补丁和结果摘要；应用时校验补丁字节、复制边界和结果摘要，失败由调用者回退完整归档。`publishZip` 可保留归档，`retention` 提供列表、逐文件校验后的回滚与保留当前及更新版本的清理。`Manifest.endorsement` 让旧密钥背书新密钥，`additional_public_keys` 支持过渡期；背书不链式、不支持吊销。
- `ziggurat-update` 新增 `pack`（任意平台的确定性包）、`endorse`、`release`（完整归档、增量、清单与 feed.json；重跑不变，冲突资产返回 `AssetConflict`）、`check`/`fetch`（优先增量、失败回退）、`rollback`、`prune`。
- 测试覆盖补丁重建与畸形拒绝、增量/背书绑定与伪造、索引选择与篡改和全部分配失败、取消/短响应续传与无 Range 重来、回环 HTTP 的 206/200，以及安装→增量升级（损坏补丁回退）→完整升级→回滚（篡改阻止）→清理的完整流程；工具在本地完成 keygen/pack/release 两次幂等与冲突拒绝、check 选中增量。未实现：更新提示界面组件、GitHub/S3 上传（需发布者凭据，工具只生成静态目录）、密钥吊销、真实服务器与旧客户端跨版本演练。见[更新](updates.md)。

### R06.1 init/dev/build/package/doctor

- `ziggurat init` 生成依赖本框架检出的 native（声明式视图）、web（WebView 页面）和 hybrid（原生视图窗口与页面窗口共享状态）项目；框架 `build.zig` 新增公开的 `addApplicationResources` 供应用嵌入 Windows 资源。`dev` 构建后以子进程运行应用，轮询源码变化后重建重启，可带前端监视命令；`build` 默认 ReleaseSafe，`--package` 生成确定性的更新包；`doctor` 报告 Zig 版本、Linux pkg-config 依赖与显示、Windows WebView2 SDK/Runtime 版本和项目文件。
- 单元测试覆盖模板渲染、名称/identity 清理、非空目录与缺失框架。本地 Linux 三种模板均对本仓库实际构建并在 Xvfb 中运行 8 秒无错误（未做页面内容或视觉检查），`dev` 修改后重建且只保留一个应用进程，`build --package` 两次摘要一致。Windows 只完成交叉编译。未实现：模板外的前端工程脚手架、类型化 IPC 模板、远程依赖引用。见[ziggurat 命令](cli.md)。

### E02.1 Fetch 与 WebSocket 客户端

- 新增纯 Zig `ziggurat_net`，不导入核心、不创建线程。`fetch`/`stream`/`fetchJson` 在宿主 worker 上执行 HTTP(S) 请求：任意方法与 body、逐跳重定向（credentials 跨 origin 丢弃）、gzip/deflate 解码、解码后 body/头部/重定向/URL 上限，`stream` 以调用者 Writer 施加 TCP 背压。`Cancel` 绑定已建立连接的 socket，取消时 shutdown，被取消的传输不报告成功；连接与 TLS 握手期间的取消在其返回后生效。
- `WebSocket` 由单一 worker 独占连接两个方向（同一 TLS 会话不并发读写），任意线程 `send`/`ping`/`close`/`cancel`/`resumeReading`；预分配发送队列满返回 `Full`，handler 返回 `pause` 停止读 socket。分片重组、UTF-8、掩码/保留位/控制帧/关闭码校验与 1002/1007/1009 关闭、自动 pong、关闭握手、子协议协商。HTTPS/WSS 复用调用者 `std.http.Client` 的 TLS、系统 CA 与代理。
- 单元测试用回环服务覆盖以上路径，Linux ReleaseSafe/Debug 各连续运行 1000/300 次（含 CPU 压力）无失败；`scripts/net-tls-probe.sh` 用临时 localhost 证书实测 HTTPS、100 KB WSS 回显和不受信证书拒绝。Windows 单元测试交叉编译通过，运行结果以 CI 为准。未实现：压缩扩展、非 CONNECT HTTP 代理上的 WebSocket、内置超时与自动重连、连接/握手阶段的即时取消、公网与代理环境验证。见[Fetch 与 WebSocket](net.md)。

### W03.3 Windows 系统框架材质

- `Window.setBackdrop(.system/.none/.mica/.acrylic/.mica_alt)` 经 DWM system backdrop 属性在主线程同步提交；`backdrop_material` 只在 `.system` 装饰且系统版本不低于 Windows 11 build 22621 时为 true，版本由 RtlGetVersion 每进程读取一次。不支持时在原生调用前返回 `UnsupportedCapability`，原生拒绝为 `WindowUpdateFailed` 并保留 HRESULT 诊断；选择不由框架保存。
- 材质只覆盖系统标题栏/边框；客户区仍不透明，`transparent` 保持 false，W03.2 需渲染器预乘 alpha 输出后另行实现。Linux/Wayland 报告不支持。
- 测试后端单测覆盖能力门禁、Busy、失败不改状态与关闭后 `Closed`；`smoke-window-chrome` 在 Windows 比对独立读取的版本与能力，支持时提交五种材质并在 DWM 允许时读回原值。本地已通过 Linux 原生检查与 Windows 交叉编译；Windows 运行结果以 CI 为准，不建立视觉效果结论。

### B02/B03 Linux DevTools 与整体数据清理

- Linux 接受 `devtools_enabled` 与 `setDevToolsEnabled/devToolsEnabled/openDevTools`，映射 WebKit developer extras；inspector 是引擎拥有的独立顶层窗口，拒绝停靠进 Content host。禁用、detach、reload/recover 替换与关闭同步关闭已显示 inspector，`devToolsResourceCount()` 回到 0；网页上下文菜单仍被拒绝。
- Linux `clearBrowsingData(.entire_profile)` 对 View 自己的数据管理器清除全部类型与时间范围，持久 Profile 下影响共用者。它复用截图的显式 budget、每 View 与进程物理上限及 GTask 结果寿命，不要求当前文档、不预留 PNG 容量；新增独立 `clear_browsing_data` 能力位，`browser_tools` 仍为 false。
- 本地 Linux（Xvfb、WebKitGTK 4.1）Debug 通过 `smoke-webview-linux`、`P01_PROBE=backend`、`smoke-webview-cookies-linux`、`smoke-webview-capture-linux`、`test-webkit-capture` 与 `test-webview`：DevTools 默认关闭/禁用拒绝/显示/重复/禁用关闭/recover 保留/reload 清除，清理后 Store 查询为空、新文档无旧 Cookie 与 localStorage，取消恰好一次，原生计数归零。Linux PDF、无页面 Windows CookieStore 与 Linux View Cookie 工具保持原状态。

### S05.1 多格式剪贴板 Board 与放置目标

- `clipboard.Board` 每个 App 一个原生连接：Windows 用私有 message-only HWND 作为 owner、更新监听、延迟渲染与重试 timer；GTK 用 CLIPBOARD selection。写入先校验全部条目并在打开剪贴板前构造原生块，失败不留部分内容；lazy offer 的 released 恰好一次。读取经调用者 Request 槽异步交付，取消/停机后无回调；GTK 同 selection 的同步应答改由 idle 交付，保持“启动调用内不回调”。
- `drop.Target` 为窗口注册原生放置目标：Windows `IDropTarget`（嵌套 OleInitialize、subclass 在 WM_DESTROY 撤销），GTK 扩展 GtkWindow 既有 root-window target 列表并在 detach 还原。悬停 leave 总先于 drop；payload 复制到调用者 buffer，超出报告所需字节。拖动源因两平台都需要模态拖动循环而不提供。
- Linux Xvfb 1x/2x 下 `smoke-clipboard`、`smoke-drop` 通过；Windows 路径只交叉编译。未自动验证：真实跨进程拖放、另一进程占用剪贴板时的重试、`WM_RENDERALLFORMATS` 退出渲染。见[系统工具](system.md)。

### S03.1 桌面环境快照、订阅与粗模式文件监视

- `system.desktop` 提供显示器、偏好、电源、网络快照和每 Watch 独立原生订阅，突发合并、stop/停机撤销后无回调；Windows 用不显示的顶层窗口接收广播，网络变化回调只 PostMessage；Linux 用 GDK/GtkSettings/GIO 信号。Linux 配色/高对比度来自主题名启发式，不读取 portal，accent 为 null。见[桌面环境](desktop-environment.md)。
- `system.watch.Watcher` 在宿主 worker 上运行，预算在 init 分配，`changed`/`overflow`/`root_removed` 合并交付且容量不足时顺延；详细模式未实现。见[文件监视](file-watch.md)。
- Linux 下 `smoke-desktop`（1x/2x，真实 GtkSettings 突发合并）与 `smoke-file-watch` 通过；inotify 溢出、Windows 零字节完成和真实系统主题/电源/网络变化未自动触发。

### S02.2–S02.3 打开 URL/路径、定位与回收站

- `shell.Worker` 新增 `openUrl`（默认只允许 https/http/mailto，`file:` 永远拒绝）、`openPath`、`reveal`（Windows SHOpenFolderAndSelectItems，Linux FileManager1.ShowItems 有界超时）与 `trash`（Windows SHFileOperationW 仅本地固定盘，Linux g_file_trash）。均在宿主 worker 阻塞执行，校验在交给处理程序之前完成。
- `smoke-shell` 在私有 XDG 目录真实 trash 12 个 Unicode 文件，并在私有会话总线上用假 FileManager1 验证 ShowItems 与超时；不打开浏览器或用户文件。真实关联程序、资源管理器显示与回收站策略边界未自动验证。

### W04.2 显示器变化后的重新放置

- `window_placement.displacement(window, &topology)` 对照宿主刚刷新的快照分类当前原生 frame：`contained`、`partial`（单个 workarea 两个方向至少重叠 48 原生单位）、`offscreen`，特殊状态为 `special`，快照过期返回 `DisplayChanged`。只查询，不分配、不注册回调；模块仍只依赖核心。
- 宿主用 `system.desktop.Watch` 订阅 monitors 变化，在回调里 `refresh` 与 `displacement`，`offscreen` 时以 Tracker 快照建立新的 `Restorer`。`partial` 是否收回由宿主决定，Openbox 会把越界窗口夹到可见边缘而得到这个结果。
- 单测覆盖跨两个 workarea 的包含、部分可见、阈值边界、仅落在 workarea 外条带、小 frame 与无效矩形。`smoke-window-placement` 增加越界移动后恢复与最大化期间 `special`；新增 Linux `smoke-window-placement-displays` 用 RandR 实际缩小 Xvfb 输出，monitors 回调推进到 `offscreen` 并恢复到新 workarea，1x 与 `GDK_SCALE=2` 本地通过，结束时恢复原模式。Windows 只交叉编译，没有在真实系统上改变显示器配置。见[窗口恢复](window-placement.md)。
### W05.1、S04.1、S07.1 单实例与系统集成

- `system.identity` 定义贯穿锁、desktop ID、AppUserModelID 和处理程序的应用 ID 规则，在 App.init 前设置进程身份，并把 Windows Known Folder 与 Linux XDG/user-dirs 目录写入调用者缓冲；未配置的 Linux 用户目录明确返回 `DirectoryUnavailable`。
- `system.instance` 以 Linux 运行目录 flock + Unix socket、Windows 每用户每会话 named pipe（仅当前用户 DACL、首实例标志、双向 SID 核对）实现单实例。接收在宿主创建的 worker 上阻塞，可跨线程停止；消息完整校验后才确认，帧上限 128 参数/单项 16 KiB/合计 64 KiB，畸形、超长、停滞与外来用户对端被拒而 listener 继续服务。primary 退出时旧 secondary 得到 `PrimaryUnavailable`，`claimOrForward` 有界重试。激活由宿主复制消息后经 `App.post` 决定。
- `system.integration` 按用户写入/卸载登录项、URL scheme 与文件关联，供安装程序调用：Windows 为 HKCU Run/Classes 与带所有者标记的 ProgID，不绕过受保护的用户选择；Linux 为 autostart、desktop entry、MIME package 与只改本 ID 条目的 mimeapps.list，原子写入并可刷新缓存。`localPath` 解码转发的 file URL。
- `system.power.Assertion` 为每个 owner 持有独立 Windows 电源请求或 logind inhibitor 描述符，release 幂等；`system.taskbar` 提供 Windows ITaskbarList3 进度/叠加图标与 Linux launcher entry 进度/计数/提醒，capability 如实报告 Windows 无非打包数字 badge。
- Linux Debug 与 ReleaseSafe 在私有 session bus（兼作 system bus）与 Xvfb 下实际运行 `smoke-os-integration`：8 个并发与最大长度参数的真实子进程转发、三类恶意对端、旧 primary 停止、被杀 primary 回收、12 轮资源持平与开放运行目录拒绝；隔离 XDG 根中由 GIO 独立解析并真正启动注册的 scheme 与文件类型，参数经单实例送达，卸载后无关 mimeapps 行保留；logind 替身核对 12 轮 Inhibit 参数与描述符关闭，独立订阅者核对 launcher 信号。`test-system-integration` 10/10。Windows 目标 Debug/ReleaseSafe 交叉编译通过，同一 smoke 已加入 Windows CI，原生运行结果尚未记录，故 Windows 不标完成。
- 密钥存储、任务栏/Dock 菜单（D03）和 macOS 不在本片；dock 实际显示、真实 logind 策略与 Windows 设置中的默认应用对话框未经人工验证。见[单实例与系统集成](os-integration.md)。

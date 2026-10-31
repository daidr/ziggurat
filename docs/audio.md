# 音频

`ziggurat_audio` 是可选模块，播放三类声音：解码进内存、经常重叠播放的音效，边播边解码的音乐等长音频，以及应用自己生成的声音。所有播放器在 Zig 里混音（48 kHz 立体声 `f32`），再交给系统音频输出。模块只依赖核心的 `App.post`，不依赖 UI 或 WebView。

```zig
const audio = @import("ziggurat_audio");

const engine = try audio.Engine.init(allocator, .{ .app = app });
defer engine.deinit(); // 有 App 时在主线程调用

const click = try engine.decodeSound(@embedFile("click.wav")); // 只解码一次
defer click.release();
_ = try engine.play(click); // 每次播放互相叠加，播完自行释放

const music = try engine.openStreamFile(try std.fs.cwd().openFile("theme.flac", .{}));
music.setLoopRange(intro_ns, 0); // 前奏只播一次，之后无缝循环
music.setVolume(0.6);
music.play();
```

## 线程与所有权

- `Engine` 拥有两个显式线程：输出线程混音并写入设备，解码线程为流提前约一秒解码。两者随 `init` 启动、`deinit` 停止并 join，无事可做时阻塞等待，不轮询。混音路径不分配、不释放内存，也不做文件 I/O。
- 所有方法都可以从任意线程调用；引擎的 allocator 也必须线程安全，因为关闭的流在解码线程上释放。
- `Decoder` 的 `read`/`setPosition`/`deinit` 在解码线程上运行，这就是应用生成声音的回调线程。`EndedCallback`（播放器播到结尾）和 `OutputCallback`（`outputError` 变化）经 `App.post` 在主线程运行；没有 App 时 `onEnded` 返回 `error.NoApp`。投递遇到 `Full` 时下一个混音周期重试，遇到 `Closed` 时丢弃等待中的通知，不再投递。引擎销毁时若仍有通知排队，该任务执行时发现引擎已不在，只释放自己。
- `Player` 是值句柄（引擎、槽位、代数）。`close` 立即结束并释放；`release` 让它播到结尾或淡出后自行释放，暂停中的立即释放；`engine.play(sound)` 返回的播放器播完自行释放。释放后句柄失效，所有方法静默无效，槽位以新代数复用。
- `Sound` 引用计数：播放器持有它播放的声音，创建者 `release` 一次即可。`openStreamFile` 成功后流拥有文件并在关闭时关闭它；`openStreamBytes` 借用的字节必须活过引擎；`newPlayer` 成功后流拥有解码器。

## 播放器

`play`、`pause`（淡出，无爆音）、`stop`（暂停并回到开头）、`seek`、`position`、`duration`（未知长度为 null），`setVolume`（增益，变化在 5 ms 内渐变）、`setPan`（单声道等功率，立体声把一侧并入另一侧）、`setSpeed`（同时改变音高，最大 16 倍）、`setLoop` 与 `setLoopRange`（区间外的部分只播一次，`setLoop(false)` 后越过区间结尾一直播到末尾）。不同采样率的源用 Catmull-Rom 插值重采样到输出频率。`Engine.setVolume` 是总音量，混音结果截断到 [-1, 1]。

`position` 是正在被听到的位置，不是混音到的位置：输出总要提前混音一段（见下面的延迟），所以播放时它比已混音的位置晚这一段；暂停后它继续走到输出把已缓冲的部分放完再停；`seek` 与 `stop` 之后立刻就是新位置，在输出放完 seek 之前混好的部分之前停在那里；变速时按每段实际的速度换算；循环时回到循环起点。

## 格式

- WAV：8/16/24/32 位整数 PCM、32/64 位浮点，含 `WAVE_FORMAT_EXTENSIBLE`；数据块长度为 0 或全 1 时按流式写入、长度未知处理。
- FLAC：纯 Zig 解码，支持 constant/verbatim/fixed/LPC 子帧、三种立体声去相关、wasted bits、4–32 位，校验帧头 CRC-8 与帧 CRC-16；seek 用帧头二分定位，不依赖 seek table。
- MP3：由 minimp3（CC0）解码 MPEG-1/2/2.5 Layer III，跳过 ID3v2 标签，按 Xing/Info 帧去掉编码器延迟与尾部填充；seek 精确到样本。输入可以是内存或文件，按需读取。
- Ogg Vorbis：由 stb_vorbis（MIT 或 Unlicense，二选一）解码，seek 精确到样本。它只能从内存解码，所以文件流也会先整体读入内存，上限 512 MiB。
- 两个 C 解码器用 C 运行时分配自己的状态，不经 `Engine` 的分配器；它们只在解码线程或 `decodeSound` 的调用方线程上运行，混音线程照旧不分配。源码按固定提交放在 `src/audio/third_party/`，版本、哈希与许可证见那里的 README，测试会核对哈希。
- `Options.formats` 是按顺序匹配文件开头的格式列表（`?` 匹配任意字节），默认 `default_formats` 为 WAV、FLAC、Ogg Vorbis 与 MP3；应用可以追加自己的 `Format`。

## 输出与失败路径

- Windows：WASAPI 共享模式、事件驱动、默认输出设备，由 WASAPI 转换到设备格式；每 500 ms 检查默认设备是否变化，变化或设备丢失时重新打开。输出线程在 COM 多线程套间中运行。
- Linux：运行时加载 `libpulse-simple.so.0`（PulseAudio，PipeWire 也提供），失败则加载 `libasound.so.2` 的 ALSA `default` 设备；两者都未安装时程序照常运行。
- 输出在第一次播放时打开，所有播放器停止 5 秒后关闭。打不开时用空设备按真实时间“播放”，播放器照常走时、按时结束，`outputError` 给出 `NoDevice`/`BackendUnavailable`/`DeviceFailed`/`Unsupported`，`outputErrorDetail` 给出系统原文；除 `Unsupported` 外每 2 秒重试一次真实设备。
- 延迟：`Options.latency` 或 `Engine.setLatency` 设定输出提前混音多少，对应 Web Audio 的 `latencyHint`。

  | 延迟 | 提前 | 适用 |
  |---|---|---|
  | `.interactive`（默认） | 约 40 ms | 游戏与界面：声音的开始、停止和变化立刻听到 |
  | `.playback` | 约 250 ms | 音乐播放器：系统让应用等待片刻（如 macOS 切换外观时最长约 0.2 s）也不断音，而 40 ms 会放空、听得出停顿 |

  用 `.playback` 时，播放、暂停、seek 和音量变化都会晚这么久才听到。最好在播放前设定：已打开的输出会重新打开，丢掉已缓冲的部分。WASAPI 的缓冲时长、PulseAudio 的 `tlength` 和 ALSA 的 latency 都按它设定；`Output.custom` 的 `Opener.open` 收到这个时长，播放器位置按设备确实缓冲这么多来推算。
- `Output.silent` 始终使用空设备；`Output.manual` 不启动线程，由调用者用 `render` 混音、用 `decode` 推进流，用于测试和离线渲染；`Output.custom` 接入应用自己的设备或测试后端。

## 验证

`zig build test-audio` 已接默认 test/check：WAV 各编码与截断、FLAC 用独立编码器生成的立体声 16 位与单声道 24 位文件逐样本比对与前后 seek、MP3 与 Ogg Vorbis 的 440 Hz 测试音（长度、过零次数、峰值）及 seek 结果与顺序解码一致、损坏与截断数据、分配失败无泄漏；混音逐样本行为（结尾静音、叠加与截断、循环与区间循环、暂停淡出与恢复淡入、音量渐变、声像、变速、重采样、seek/stop）；流的无缝循环、区间循环、seek、空循环停止、释放后播完关闭解码器；句柄失效与槽位复用；经测试后端 App 的结束通知、App 停止后的丢弃与引擎先销毁时的排队任务；测试后端设备丢失后重开；无设备时按时播放并报告原因；空设备的时钟、追赶与重试；输出提前混音时播放器的位置（缓冲、seek、暂停后放完、变速、循环）与改变延迟后按新时长重开输出。`zig build smoke-audio` 在真实系统输出上播放 200 ms 并打开一个 WAV 流，有设备走真实后端，无设备走失败路径，两种情况都要求按时结束。CI 主机没有声卡，真实设备上的出声只由本地运行确认。

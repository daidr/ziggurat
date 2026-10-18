# 多窗口设备域测量

`benchmark-gpu-domain` 比较一个显式共享设备域与每窗口独立设备域。它使用真实隐藏窗口、相同大小的原生绘制目标和相同命令，不改变默认 Context 的设备策略。

```powershell
zig build benchmark-gpu-domain -Dgpu=true -Doptimize=ReleaseFast -- --driver hardware --repetitions 3 --output hardware.json
zig build benchmark-gpu-domain -Dgpu=true -Doptimize=ReleaseFast -- --driver warp --repetitions 3 --output warp.json
```

每次运行对1、4、8个窗口分别采集共享和独立配置；偶数 trial 先共享，奇数 trial 先独立，保留执行顺序。每个窗口使用320×180物理像素目标、scale=1，一个背景 fill 与16次同一纹理绘制。源是256×256预乘BGRA，显式上传；共享配置只上传一次，独立配置各上传一次。普通回放不读回像素，也不重新上传。

`setup_ns` 从设备域创建开始，到每个窗口完成第一次 begin/replay/end 返回为止；包含窗口、renderer、纹理上传和命令记录，排除 App、源像素及命令存储分配。全部 trial 在一个进程运行，后续会受系统/驱动缓存影响，不能称为独立进程冷启动比较。

预热8轮后记录64轮。一轮顺序提交所有窗口，`round_p50_ns` 和 `round_p95_ns` 是整轮 CPU 墙钟耗时，窗口数不同则工作量不同。提交包含成功、busy 或 occluded Present；JSON 分别保留实际次数。没有 fence、显示等待、同步读回或事件循环，数字不表示 GPU 完成、显示帧率或输入延迟，也不用于评价视觉质量。

工具在测量之外校验：预热后的显式 Zig 分配尝试、renderer device/target 创建与域 bitmap 创建都不增加，设备域没有丢失；每轮计数覆盖全部提交。所有窗口、renderer、Texture 和 Domain 释放后，adapter references 与核心窗口记录归零。原生库与驱动内部的分配没有被 Zig allocator 计数器覆盖。

内存分别保存准备前、预热后和清理后的整个进程 working set/private bytes。清理后样本仍包含 App、源像素、工具和系统/驱动缓存；不强制工作集修剪，不把未回落的 RSS 等同泄漏。Domain 的 logical pixel bytes 与 reservation 单列，不是实际显存用量。

一个纹理的逻辑 payload 为262144字节。4个或8个窗口共享时仍是一个域、一次上传和一个 bitmap；各窗口独立时分别为4或8份。该成本关系由实际计数验证，提交时间是否更短需要在目标设备、负载和驱动上测量。当前不根据共享资源的数量推定性能优势，也不新增全局自动缓存。

原始样本：[hardware](benchmarks/2026-10-17-gpu-domain-hardware.json)、[WARP](benchmarks/2026-10-17-gpu-domain-warp.json)。[源码与环境清单](benchmarks/2026-10-17-gpu-domain-manifest.json)记录相应源码、可执行文件和报告哈希、工具链、优化模式和枚举到的显卡；默认 D3D11 adapter 未通过枚举列表反推。样本使用仿射回放加入之前的一致源码，后续 renderer 变化后应重新采集。最终36个样本采集前已结束整图验证，三个实施任务短暂停止构建与测试；其他系统和无关后台负载未受控制。

以下为三个 trial 的中位数。setup 单位毫秒，round p50 单位微秒；后者仍是所有窗口一轮提交的 CPU 时间。完整 p95、每次 trial、Present 与内存计数保留在原始报告中。

| driver | 窗口 | 共享 setup | 独立 setup | 共享 round p50 | 独立 round p50 |
| --- | ---: | ---: | ---: | ---: | ---: |
| hardware | 1 | 129.980 | 118.278 | 159.7 | 159.5 |
| hardware | 4 | 147.506 | 229.613 | 649.1 | 383.2 |
| hardware | 8 | 172.563 | 412.475 | 1605.2 | 819.6 |
| WARP | 1 | 15.914 | 13.694 | 63.7 | 63.8 |
| WARP | 4 | 26.771 | 48.985 | 228.0 | 227.6 |
| WARP | 8 | 48.329 | 95.627 | 464.1 | 570.6 |

本机 hardware 的共享配置在4/8窗口下 setup 较低、提交 p50 较高；WARP 的不同窗口数也没有一致的提交收益。样本支持显式共享的副本/创建成本关系，尚不足以解释驱动调度差异或据此改为默认共享和自动缓存策略。

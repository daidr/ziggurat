# 快照差异计算

`ziggurat_document_diff` 是仅依赖 Document 的可选纯 Zig 模块。`compare(allocator, reader_a, reader_b, options)` 同步计算两份不可变 Reader 的行差异，成功返回拥有型 `Result`。它不创建线程、修改文档、释放 Reader 或访问原生布局；宿主在自己的 worker 执行，并通过 `App.post` 交付结果。

```zig
var result = try diff.compare(worker_allocator, reader_a, reader_b, .{});
defer result.deinit();
for (result.hunks) |hunk| {
    // 把 a 的 hunk.a.bytes 替换为 b 的 hunk.b.bytes。
    // 两侧 .lines 都是零基、右端不含的行区间。
}
```

每条记录包含自己的 LF；CRLF、缺失末尾换行、空白和 Unicode 字节均按原文比较。空文档有零条差异记录，末尾 LF 不生成额外空记录。Hunk 的字节区间包含换行，因此按顺序替换可完整重建目标，不需要猜测换行形式。行内变化、词匹配和可见并排/统一视图仍由后续切片实施。

索引通过 Reader.cursor 顺序访问持久树叶，不复制全文。行哈希只用于快速排除，命中后仍逐字节确认，不把哈希碰撞当成相同内容。先确认共同前后文，再对中段使用最远前沿和三角形追踪表，在成功时保证最少的整行插入/删除次数。这样重复行中的局部替换不漂移到共同尾部；其余相同成本的重复行有确定的选择顺序，不承诺语法或缩进启发式的展示位置。

`Result` 只拥有 Hunk 元数据，不借用输入文本或 Snapshot。两份 Reader 释放后，元数据仍可用于展示。源字节仍须由宿主从对应快照读取；结果本身不是拥有型补丁。`a/b` 记录捕获的完整 revision、committed text version 和字节长度。不同 Document 可以具有相同版本号，宿主必须保留请求与 Document 身份的对应关系，交付时同时检查身份、代数与版本，不能仅凭相等版本号接受任意文档的结果。Reader、Snapshot、取消标志和 allocator 必须覆盖各自使用期；worker 分配的结果在 owner 释放时要求 allocator 支持该线程交接。

Result不可按值复制拥有责任。使用`take()`显式搬运，成功后旧值的`isOwned()`为false、deinit幂等；再次take返回ResultMoved。零Hunk的合法结果同样保留该状态，不能靠空slice判断是否已搬运。deinit在调用外部分配器前撤销拥有状态，分配器重入不会重复释放。

默认 `Limits`：每侧最多131072条真实记录，插入加删除距离最多512，全部同时存活的堆分配最多16MiB，工作单位最多64Mi。硬上限分别为1048576、8192、1GiB；超限返回 `LineLimitExceeded`、`DistanceLimitExceeded`、`CapacityExceeded` 或 `WorkLimitExceeded`，不返回不完整结果。底层分配失败保留 `OutOfMemory`。算法不是对任意差异大小的无限计算；宿主可明确扩大预算、分段或提示用户。

内存额度包括两侧索引、前沿、三角追踪、回溯编辑和最终 Hunk 的重叠存活；不包含已有 Document/Snapshot、allocator 元数据或固定栈空间。`Stats.peak_bytes` 是这些分配的实际请求峰值。搜索前沿为 O(D)，追踪存储为 O(D²)，索引为 O(N+M)。追踪按预算距离与裁去共同前后文后的中段长度的较小值预留，实际访问统计单独记录。

工作单位涵盖索引哈希字节、候选相等检查、确认字节、前沿初始化/步进、追踪写入、回溯和 Hunk 构造。Reader 树访问另有固定树高界。`hash_bytes`、`compared_bytes`、`frontier_steps`、`trace_cells` 与总 `work` 分别记录；这些不是 CPU 纳秒。每个叶块或前沿步骤检查显式 `Cancellation`，取消不取得 Reader 的释放责任。任何失败都清理候选分配，输入和选择保持原状。

`zig build test-document-diff` 验证空输入、换行形式、Unicode、跨不同叶布局、强制哈希碰撞、全部分配失败、精确预算边界、析构重入及 worker 读取期间 owner 编辑。961组短二元行序列与512组固定种子的随机 Unicode/CRLF/NUL/末尾换行输入使用独立动态规划 oracle 校验最短距离，并逐个用 Hunk 重建完整目标。该计算模型不等于完整 Diff 控件或交互验收。

`zig build benchmark-document-diff -Doptimize=ReleaseSafe` 测量10000/100000条16-byte记录，分别比较相同内容与中间一行变更；每种重复7次，输出比较调用的中位数/最大样本、请求分配峰值和工作计数。Document构造、Snapshot获取与Result释放不在比较计时内。工具不创建UI循环，不代表键入到显示延迟或V02正式基线。

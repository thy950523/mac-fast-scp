# FastSCP 实时进度 — 设计文档

> 日期:2026-08-07
> 范围:在已上线的 FastSCP(2026-08-06 设计 + receive 功能)上,**为发送和接收两条传输路径加上实时进度显示**:
> 1. 发送-弹窗路径:在已打开的「传送到服务器」弹窗里展示「总进度」;
> 2. 发送-一键快发路径:在屏幕右上角浮出轻量进度窗,实时跟踪,完成后自动关闭;
> 3. 接收路径:在「从服务器接收」弹窗里展示与发送一致的「总进度」(接收无无头入口,故无悬浮窗)。

## 目标与非目标

### 目标
- 发送 / 接收共享同一套进度计算逻辑,口径与视觉一致。
- 「总进度」按 **字节比**(`completedBytes / totalBytes`)计算,而非文件数。
- 两个弹窗内显示:总进度条 + 已传/总量·速率 + 剩余 ETA + 第 X/N 个文件 + 当前文件名;提供「取消传输」。
- 发送一键快发改用右上角自定义悬浮窗(不是系统通知),完成后自动关闭。
- 单个 `scp -r` 进程内支持多文件 / 递归目录的字节级累计。
- 解析失败/缺字段/网络波动导致 pct 回退等异常情况下,总进度保证**单调非减、卡在 [0,100],正常结束时一定到 100%**。
- 接收侧通过一次远端 SSH 探测拿到总大小;探测失败时有两级降级,不阻断传输。

### 非目标(YAGNI,本期不做)
- 不做并发传输队列(`SSHExecutor` 单进程,本设计保持单实例悬浮窗)。
- 不做断点续传,不改用 `rsync`。
- 不做悬浮窗的「取消传输」按钮(弹窗里有,悬浮窗是 fire-and-forget)。
- 不在 Finder Sync 扩展里加进度显示。
- 不做「无头快速接收」(所有接收入口都开接收面板)。

## 技术选型与关键决定

| 决策点 | 选择 | 理由 |
|---|---|---|
| 「总进度」口径 | 已传字节 / 总字节 | 用户明确要求按 size;scp 原生只给单文件 %,需预扫 + 累加 |
| 发送总大小来源 | `FileManager` 本地递归 | 主 App 未沙盒,可直接读选中项 |
| 接收总大小来源 | 传输前一次远端 SSH 探测 | 源在远端,本地扫不到;`find -printf` 给逐文件大小 |
| 接收探测降级 | Tier1 GNU find → Tier2 `find -type f` + `du -sk` → Tier3 不确定 | 兼容 BSD/macOS 远端;主目标是 Linux,但不阻断非 Linux |
| 字节速率来源 | 解析 scp stderr 行 `NNN(\.\d+)?(K\|M\|G)B/s` | scp 原生吐速率,不需采样估算 |
| 文件切换检测 | 解析出的文件名变化 | scp 每行文件名在 `%` 前 |
| 方向抽象 | `TransferDirection { .send, .receive }` | 发送/接收共用 tracker / aggregator / 视图,只在文案与数据源分叉 |
| 悬浮窗实现 | 自定义 `NSPanel` + SwiftUI | 系统 `UNUserNotificationCenter` 无法实时刷新进度条;仅发送快发用 |
| 进度状态机 | `FastSCPCore/TransferAggregator`(纯 struct) | 核心累加逻辑零 UI 依赖、可单测 |
| 远端探测解析 | `FastSCPCore/RemoteSizeProbe`(纯函数) | 解析 `find -printf` / `du` 输出,可单测 |
| 完成通知 | 弹窗/悬浮窗自带成功态;**移除**发送快发的系统通知 | 不重复打扰;接收弹窗成功后自动关窗 |

## 进度模型与计算

### 模型

```swift
public enum TransferPhase: Equatable, Sendable {
    case preparing    // 发送:本地统计 / 接收:远端探测
    case sending      // scp 正在跑(发送与接收共用此阶段名)
    case done
    case failed(String)
}

public enum TransferDirection: String, Sendable { case send, receive }

/// 进度字节信息的可信程度,驱动 UI 显示哪些字段。
public enum SizeKnowledge: Sendable {
    case full        // 有总字节 + 每文件大小 → 字节级平滑进度,显示「已传 X / Y」
    case totalsOnly  // 只有总字节 + 文件数(无每文件大小)→ 按文件计数比例推进
    case unknown     // 什么都没有 → 不确定进度条 + 当前文件名
}

public struct TransferProgress: Equatable, Sendable {
    public let phase: TransferPhase
    public let direction: TransferDirection
    public let totalBytes: Int64
    public let completedBytes: Int64
    public let totalFiles: Int
    public let currentFileIndex: Int          // 1-based;0 表示未知
    public let currentFileName: String?
    public let rateBytesPerSec: Int64?
    public let etaSeconds: Int?
    public let sizeKnowledge: SizeKnowledge
    public var percent: Double                // completedBytes/totalBytes,钳到 [0,1]
}
```

### 解析增强(`SCPProgressParser`)

在原百分比解析基础上,同一行再提取:

```
\r<filename><spaces>NN% <size> <rate> <eta>
```

- `rate` 正则:`\b(\d+(?:\.\d+)?)(K|M|G)?B/s\b` → bytes/s。
- `fileName`:`%` 前的非空白前缀。
- 解析失败字段填 `nil`,不抛错;聚合器据此走降级分支。

### 聚合器(`TransferAggregator`,纯 struct,可测)

```swift
public struct TransferAggregator {
    public init(direction: TransferDirection,
                totalBytes: Int64,
                totalFiles: Int,
                fileSizeLookup: [String: Int64] = [:],
                sizeKnowledge: SizeKnowledge = .full)
    public mutating func startSending()
    public mutating func ingest(_ event: ParsedProgress)
    public mutating func complete()         // scp 正常退出 → 钳 100%
    public mutating func fail(_ message: String)
    public var progress: TransferProgress
}
```

**`.full` 模式(发送,以及接收 Tier1):**
- 文件切换时把上一文件的完整大小计入 `completedBytes`。
- 当前文件贡献 `max(pct seen) × currentFileSize`(pct 回退时不变,保证单调)。
- ETA = 剩余字节 / 平滑速率。

**`.totalsOnly` 模式(接收 Tier2,无每文件大小):**
- 进度按**文件计数比例**:`completedFiles + clamp(pct, 0, 1)` 除以 `totalFiles`,再映射到字节(`completedBytes = totalBytes × ratio`)。
- 单文件内随 scp pct 平滑推进(隐含各文件大小相近),不做精确字节累加。
- `complete()` 仍钳到 `totalBytes`。

**`.unknown` 模式(接收 Tier3):**
- `percent` 不发布;UI 显示不确定进度条 + 当前文件名 + 速率。
- `complete()` 切 `.done`。

**`complete()`:** `completedBytes = totalBytes`,phase = `.done`(退出钳位,保证 100%)。

**`fail(_:)`:** phase = `.failed(message)`,不修正字节。

## 本地扫描与远端探测

两种「prepare 数据源」产出同一结构 `PreparedTransfer { totalBytes, totalFiles, lookup, sizeKnowledge }`,供 `TransferTracker` 构造聚合器。

### 发送:本地扫描(`LocalScanner`)

后台 `Task` 用 `FileManager.default.enumerator` 递归:
- 跳过符号链接指向的内容;目录不计文件大小。
- 累加 `totalBytes`,计数 `totalFiles`,建 `fileSizeLookup[basename] = size`。
- 结果 `.full`。

### 接收:远端探测(`RemoteSizeProbe` + `SSHExecutor.probeRemoteSizes`)

对每个选中的远端路径 `<remotePath>/<name>` 执行:

**Tier 1 — `find -printf`(GNU find,Linux):**
```
find <p1> <p2> ... -type f -printf '%s %f\n'
```
- 每行 `字节数 文件名`;行数 = 文件数;累加字节 = 总字节;逐行填 lookup。
- 退出码 0 且输出可解析 → `.full`。

**Tier 2 — 退化(BSD/macOS 远端或 Tier1 失败):**
```
find <p1> <p2> ... -type f          # 行数 = 文件数
du -sk <p1> <p2> ...                # 末行 total = KB(BSD/GNU 都有 -k)
```
- 取文件数 + 总 KB(×1024 转字节);无逐文件大小 → `.totalsOnly`。
- 任一命令失败 → Tier 3。

**Tier 3 — 完全失败:**
- 返回 `(totalBytes: 0, totalFiles: 0, lookup: [:], sizeKnowledge: .unknown)`,不阻断后续 scp。

> 路径引用:通过 `Process` argv 直接传(非 shell),无需引号转义;`find` 接受多路径参数。`du -sk` 多路径在 GNU 与 BSD 上都在末行给 `total`。

## 弹窗进度 UI(发送 + 接收共用)

`TransferStatusView` 接收 `(tracker, direction, alias, path, onCancel)`,文案与图标随方向:

- 发送:`↗ 正在传输到 alias:path`
- 接收:`↙ 正在接收自 alias:path`

```
┌─ 传送到服务器 ──────────────────┐
│                                │
│         ↗                       │
│   正在传输到 server1:/var/www    │
│                                │
│   ▓▓▓▓▓▓▓▓░░░░░░░░  62%        │
│   74.5MB / 120MB · 12.3MB/s     │
│   剩余约 4 秒                    │
│                                │
│   第 3 / 7 个文件                │
│   logs/app.log                  │
│                                │
│           [ 取消传输 ]           │
└────────────────────────────────┘
```

要点:
- `.full`:`ProgressView(value: percent)` + 「已传/总量 · 速率」+ ETA + 第 X/N + 文件名。
- `.totalsOnly`:进度条 + 百分比 + 速率 + ETA + 第 X/N + 文件名;**隐藏「已传 X / Y MB」**(字节是按比例映射的,不是真实已传),只在完成态显示总量。
- `.unknown`:`ProgressView()`(不确定)+ 当前文件名 + 速率;不显示百分比与字节。
- 「取消传输」调 `SSHExecutor.shared.cancel()` → scp 被终止 → catch 走失败态,不关窗。
- 成功:发送/接收均记对应最近目标(`RecentStore.shared()` / `.sharedReceive()`)→ 关窗;失败:视图内显示错误 + 「关闭」。

## 悬浮进度窗(仅发送一键快发)

替换 `AppDelegate.runQuick` 现有的「无界面 + 结束系统通知」。接收没有无头入口,不用此窗。

**窗体:**
- `NSPanel`,`level = .floating`,`becomesKeyOnlyIfNeeded = true`,`hidesOnDeactivate = false`。
- 主屏右上角(16pt 边距),宽 ≈ 320pt,`.ultraThinMaterial` + 投影。

**内容随阶段切换:**

传输中:`↗ 正在传输 alias:path` + 进度条 + 已传/总量·速率 + 第 X/N·文件名。
成功(~1.2s 后淡出自动关闭):`✓ 已发送到 alias:path`。
失败(停留至用户关闭):`⚠ 传输失败` + 友好错误 + 「关闭」。

**生命周期:** show() 出现;订阅 tracker,`.done` → 1.2s 后淡出;`.failed` 停留;单实例。**移除** `Notifier.send`。

## 接线与文件结构

### 新增/修改文件

| 文件 | 变更 |
|---|---|
| `Sources/FastSCPCore/SCPProgressParser.swift` | 增强:返回 `(percent, fileName, rate)` |
| `Sources/FastSCPCore/ByteFormat.swift`(新) | 字节/速率人类可读格式化 |
| `Sources/FastSCPCore/TransferProgress.swift`(新) | 模型 + `TransferAggregator`(支持三档 sizeKnowledge) |
| `Sources/FastSCPCore/RemoteSizeProbe.swift`(新) | 纯解析:`find -printf` / `find -type f` / `du -sk` |
| `Sources/FastSCP/TransferTracker.swift`(新) | `@MainActor ObservableObject`:方向 + prepare 数据源 + 发布进度 |
| `Sources/FastSCP/TransferStatusView.swift`(新) | 弹窗传输态 SwiftUI 视图(方向化) |
| `Sources/FastSCP/QuickTransferHUDController.swift`(新) | 右上角 `NSPanel`(仅发送) |
| `Sources/FastSCP/SSHExecutor.swift` | 新增 `probeRemoteSizes(remotePath:names:)` |
| `Sources/FastSCP/DestinationPanel.swift` | `performTransfer` 改用 tracker;传输态切 `TransferStatusView`;加取消 |
| `Sources/FastSCP/ReceivePanel.swift` | `performPull` 改用 tracker(方向 .receive);传输态切 `TransferStatusView`;加取消 |
| `Sources/FastSCP/AppDelegate.swift` | `runQuick` 改用 tracker + HUD;移除系统通知 |

### `DestinationViewModel.performTransfer`

```swift
let tracker = TransferTracker(direction: .send, selections: selections, prepare: .localScan)
self.tracker = tracker
await tracker.prepare()
tracker.start()
do {
    try await SSHExecutor.shared.transfer(alias:path:sources:) { p in
        Task { @MainActor in tracker.ingest(p) }
    }
    tracker.complete()
    RecentStore.shared().record(...)
    onClose?()
} catch { tracker.fail(SSHErrorMapper.friendlyMessage(for: error)) }
```

### `ReceiveViewModel.performPull`

```swift
let tracker = TransferTracker(
    direction: .receive,
    remotePath: currentPath, names: names, alias: selectedAlias,
    prepare: .remoteProbe
)
self.tracker = tracker
await tracker.prepare()
tracker.start()
do {
    try await SSHExecutor.shared.pull(alias:remotePath:names:localDest:) { p in
        Task { @MainActor in tracker.ingest(p) }
    }
    tracker.complete()
    RecentStore.sharedReceive().record(...)
    onClose?()
} catch { tracker.fail(...) }
```

## 测试策略(`FastSCPCoreTests`,TDD)

- `SCPProgressParserTests`:`fileName` / `rate` 提取(常规 / 缺速率 / 只有百分比);保留旧用例。
- `ByteFormatTests`:size / rate 格式化、边界(0、负数、GB)。
- `TransferAggregatorTests`:单/多文件字节累加;`.totalsOnly` 按文件计数比例;`.unknown` 不发布 percent;pct 回退取最大值;`complete()` 钳 100%;`fail()` 不改字节;ETA。
- `RemoteSizeProbeTests`(新):
  - `find -printf` 样例 → totalBytes / totalFiles / lookup 正确。
  - `find -type f` 行数 → totalFiles。
  - `du -sk` 单/多路径 total 行 → KB 正确。
  - 空输出 / 乱码 → 优雅降级(.totalsOnly / .unknown)。

GUI:手动验证(真机右键 + 真实 SSH 服务器)。

## 边界与已知限制

- **并发传输**:不支持;悬浮窗单实例。
- **发送巨大目录预扫**:后台 `Task`,不卡主线程;`preparing` 阶段短暂 0%。
- **接收探测开销**:一次额外 SSH 往返;目录巨大时 `find -printf` 可能慢,在 `.preparing` 状态显示「正在统计远端文件…」。
- **接收 Tier2 精度**:按文件计数比例,大小悬殊时进度条会跳跃;到达 100% 靠 `complete()` 钳位兜底。
- **不可读文件 / 权限**:探测或传输报错走 `.failed`,显示友好信息。
- **符号链接**:发送只算链接本身;接收遵循 scp 默认行为。
- **空选区/空选择**:进度直接 `.done`,不报错。
- **scp 退出非 0 但中途显示过进度**:`.fail()` 不改字节,UI 显示错误,不显示虚假 100%。

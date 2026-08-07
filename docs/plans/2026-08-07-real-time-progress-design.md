# FastSCP 实时进度 — 设计文档

> 日期:2026-08-07
> 范围:在已上线的 FastSCP(2026-08-06 设计)上,**为两种发送路径加上实时进度显示**:
> 1. 弹窗路径:在已打开的选择目标弹窗里展示「总进度」;
> 2. 一键快发路径:在屏幕右上角浮出轻量进度窗,实时跟踪,完成后自动关闭。

## 目标与非目标

### 目标
- 两种发送路径共享同一套进度计算逻辑,口径一致。
- 「总进度」按 **字节比**(`completedBytes / totalBytes`)计算,而非文件数。
- 弹窗内显示:总进度条 + 已传/总量·速率 + 剩余 ETA + 第 X/N 个文件 + 当前文件名;提供「取消传输」。
- 一键快发改为右上角自定义悬浮窗(不是系统通知),完成后自动关闭。
- 单个 `scp -r` 进程内支持多文件传输的字节级累计。
- 解析失败/缺字段/网络波动导致 pct 回退等异常情况下,总进度保证**单调非减、卡在 [0,100],正常结束时一定到 100%**。

### 非目标(YAGNI,本期不做)
- 不做并发传输队列(`SSHExecutor` 单进程,本设计保持单实例悬浮窗)。
- 不做断点续传,不改用 `rsync`。
- 不做悬浮窗的「取消传输」按钮(弹窗里有,悬浮窗是 fire-and-forget)。
- 不在 Finder Sync 扩展里加进度显示。

## 技术选型与关键决定

| 决策点 | 选择 | 理由 |
|---|---|---|
| 「总进度」口径 | 已传字节 / 总字节 | 用户明确要求按 size;scp 原生只给单文件 %,需本地预扫 + 累加 |
| 总大小来源 | `FileManager` 本地递归 | 主 App 未沙盒,可直接读选中项;不需 SSH 往返 |
| 字节速率来源 | 解析 scp stderr 行 `NNN(\.\d+)?(K\|M\|G)B/s` | scp 原生吐速率,不需采样估算 |
| 文件切换检测 | 解析出的文件名变化 | scp 每行文件名在 `%` 前;同一文件多行同名,换文件即换名 |
| 悬浮窗实现 | 自定义 `NSPanel` + SwiftUI | 系统 `UNUserNotificationCenter` 无法实时刷新进度条 |
| 悬浮窗焦点策略 | `becomesKeyOnlyIfNeeded` + `hidesOnDeactivate=false`,`level=.floating` | 不抢焦点,不打断用户 |
| 悬浮窗外观 | 圆角 + `.ultraThinMaterial` + 投影,宽 ≈ 320pt | 与 macOS 原生气泡风格一致 |
| 进度状态机位置 | `FastSCPCore/TransferProgress.swift`(纯 struct) | 核心累加逻辑零 UI 依赖、可单测 |
| 进度驱动层 | `FastSCP/TransferTracker.swift`(`@MainActor ObservableObject`) | 负责本地扫描 + 喂数据 + 发布 SwiftUI |
| 传输完成通知 | 悬浮窗/弹窗自带成功态;**移除**原有一键快发的系统通知 | 不重复打扰 |
| 并发模型 | 不变,单 `scp` 进程;悬浮窗单实例 | 不引入新复杂度 |

## 进度模型与计算

### 模型

```swift
public enum TransferPhase {
    case preparing    // 本地统计总大小
    case sending      // scp 正在跑
    case done         // 成功
    case failed(String) // 失败(带友好消息)
}

public struct TransferProgress: Equatable, Sendable {
    public let phase: TransferPhase
    public let totalBytes: Int64
    public let completedBytes: Int64
    public let totalFiles: Int
    public let currentFileIndex: Int          // 1-based;0 表示未知
    public let currentFileName: String?
    public let rateBytesPerSec: Int64?        // scp 原生速率
    public let etaSeconds: Int?               // 剩余字节 / 平滑速率
    public var percent: Double                // completedBytes/totalBytes,钳到 [0,1]
}
```

### 解析增强(`SCPProgressParser`)

在原百分比解析基础上,同一行再提取:

```
\r<filename><spaces>NN% <size> <rate> <eta>
```

- `rate` 正则:`\b(\d+(?:\.\d+)?)(K|M|G)?B/s\b` → 换算为 bytes/s。
- `fileName`:`%` 前的非空白前缀(`trimmingCharacters(.whitespacesAndNewlines)`)。
- 解析失败字段填 `nil`,不抛错;聚合器据此走降级分支。

### 聚合器(`TransferAggregator`,纯 struct,可测)

```swift
public struct TransferAggregator {
    public init(totalBytes: Int64, totalFiles: Int)
    public mutating func ingest(_ event: ParsedProgress)
    public mutating func complete()         // scp 正常退出 → 钳 100%
    public mutating func fail(_ message: String)
    public var progress: TransferProgress
}
```

**状态字段(私有):** `totalBytes`、`totalFiles`、`completedBytes`、`currentFileName`(上一次)、`currentFileSize`(当前文件的本地大小,从预扫拿)、`currentFileBytesSeen`(当前文件已传,取 pct 最大值,保证单调)、`currentFileIndex`、`rateBytesPerSec`、`fileSizeLookup: [String: Int64]`。

**`ingest` 逻辑:**
1. 解析得到 `(name?, pct, rate?)`。
2. 若 `name != currentFileName`(文件切换):
   - 把**上一文件**的 `currentFileSize`(若查表得到)累加进 `completedBytes`。
   - `currentFileIndex += 1`;`currentFileName = name`;从 `fileSizeLookup[name]` 取 `currentFileSize`;`currentFileBytesSeen = 0`。
3. `currentFileBytesSeen = max(currentFileBytesSeen, pct/100 × currentFileSize)`(pct 回退时不变,保证单调)。
4. `completedBytes` 反映到 `progress`:`completedBytes + currentFileBytesSeen`。
5. `rateBytesPerSec = rate`;ETA = `(totalBytes − 实际完成) / rate`(rate 缺失则 `nil`)。

**`complete()`:** `completedBytes = totalBytes`,phase = `.done`(退出钳位,保证 100%)。

**`fail(_:)`:** phase = `.failed(message)`,不修正字节。

**单文件特例:** `totalFiles == 1` 时,`ingest` 直接把整文件大小视为 `currentFileSize`,逻辑同上,只是文件切换永不发生。

### 本地预扫(`TransferTracker.prepare`)

在 `FastSCP/TransferTracker.swift`,后台 `Task`:
- `FileManager.default.enumerator(at: ...)` 递归遍历每个 `selections`。
- 跳过符号链接指向的内容(`URL.resourceValues(forKeys: [.isSymbolicLinkKey])`),大小记链接本身。
- 累加 `totalBytes`,计数 `totalFiles`。
- 顺手建 `fileSizeLookup`(路径 → 字节),用于聚合器精确匹配。
- 期间 `phase = .preparing`;完成切 `.sending`。

## 弹窗进度 UI(选择目标路径)

`DestinationViewModel.performTransfer` 进入传输态后,主内容区(服务器下拉 / 路径 / 列表)整体替换为「传输状态视图」:

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
- `ProgressView(value: tracker.progress.percent)` + `monospacedDigit()` 百分比文本。
- 三行信息绑定 tracker 的 `currentFileIndex/totalFiles`、`currentFileName`(`lineLimit(1)` + `.truncation(.middle)`)、`etaSeconds`。
- 「取消传输」按钮调 `SSHExecutor.shared.cancel()`(已存在,此前未使用)→ scp 进程被终止 → catch 走失败态,不关窗,显示「已取消」。
- 成功:维持现状(记最近目标 → 关窗);失败:视图内显示错误 + 「重试 / 关闭」。

## 悬浮进度窗(快速传输)

替换 `AppDelegate.runQuick` 中现有的「无界面 + 结束系统通知」流程。

**窗体:**
- `NSPanel`,`styleMask: [.titled, .fullSizeContentView]`(隐藏标题栏)/ 或 `.borderless`,`level = .floating`。
- `becomesKeyOnlyIfNeeded = true`,`hidesOnDeactivate = false`(显示但不抢焦点)。
- 位置钉在主屏右上角(留 16pt 边距),从 `NSScreen.main?.visibleFrame` 计算。
- 内容宽 ≈ 320pt,高度自适应;`.ultraThinMaterial` 背景 + 投影。

**内容随阶段切换:**

传输中:
```
┌────────────────────────────┐
│ ↗  正在传输 server1:/var/www │
│ ▓▓▓▓▓▓▓░░░░░░░░░  62%       │
│ 74.5MB / 120MB · 12.3MB/s  │
│ 第 3 / 7 个 · logs/app.log  │
└────────────────────────────┘
```

成功(~1.2s 后淡出自动关闭):
```
┌────────────────────────────┐
│ ✓  已发送到 server1:/var/www  │
└────────────────────────────┘
```

失败(停留,直到用户关闭):
```
┌────────────────────────────┐
│ ⚠  传输失败                  │
│ <友好错误信息,≤ 3 行>        │
│                     [ 关闭 ] │
└────────────────────────────┘
```

**生命周期:**
- `QuickTransferHUDController.show(tracker:)` → 创建 `NSPanel` + 放右上角 → `makeKeyAndOrderFront`(不激活 App)。
- 订阅 `tracker.$progress`,阶段切 `.done` 启动 ~1.2s 计时器 → fade out → `orderOut(nil)` 并释放。
- 阶段切 `.failed` → 不自动关闭,等用户点「关闭」。
- 单实例:同一时刻只有一个 `HUD` 活跃;第二次快速触发复用并重置同一 tracker(并发传输本就不支持)。

**不再发系统通知:** 成功/失败均由悬浮窗承担;从 `runQuick` 移除 `Notifier.send` 调用。

## 接线与文件结构

### 新增/修改文件

| 文件 | 变更 |
|---|---|
| `Sources/FastSCPCore/SCPProgressParser.swift` | 增强:同时返回 `(percent, fileName, rate)` |
| `Sources/FastSCPCore/TransferProgress.swift`(新) | `TransferProgress` / `TransferPhase` / `ParsedProgress` / `TransferAggregator` / `ByteFormat` |
| `Sources/FastSCP/TransferTracker.swift`(新) | `@MainActor ObservableObject`:本地扫描 + `TransferAggregator` + `@Published progress` |
| `Sources/FastSCP/TransferStatusView.swift`(新) | 弹窗传输态 SwiftUI 视图 |
| `Sources/FastSCP/QuickTransferHUDController.swift`(新) | 右上角 `NSPanel` + SwiftUI 内容 + 生命周期 |
| `Sources/FastSCP/DestinationPanel.swift` | `DestinationViewModel.performTransfer` 改用 `TransferTracker`;传输态切到 `TransferStatusView`;加「取消传输」 |
| `Sources/FastSCP/AppDelegate.swift` | `runQuick` 改用 `TransferTracker` + `QuickTransferHUDController`;移除 `Notifier.send` |

### `performTransfer` 改动要点

```swift
func performTransfer(alias: String, path: String) async {
    let tracker = TransferTracker(selections: selections)
    self.tracker = tracker                       // 视图绑定
    await tracker.prepare()                      // 后台统计
    do {
        try await SSHExecutor.shared.transfer(
            alias: alias, path: path, sources: selections,
            progress: { tracker.ingest($0) }
        )
        await tracker.complete()
        RecentStore.shared().record(...)
        onClose?()
    } catch {
        let friendly = SSHErrorMapper.friendlyMessage(for: error)
        await tracker.fail(friendly)
        // 不关窗,视图展示错误
    }
}
```

### `runQuick` 改动要点

```swift
private func runQuick(_ req: URLCoordinator.QuickRequest) {
    Task { @MainActor in
        let tracker = TransferTracker(selections: req.selections)
        let hud = QuickTransferHUDController(tracker: tracker, alias: req.alias, path: req.remotePath)
        hud.show()
        await tracker.prepare()
        do {
            try await SSHExecutor.shared.transfer(
                alias: req.alias, path: req.remotePath, sources: req.selections,
                progress: { tracker.ingest($0) }
            )
            await tracker.complete()
            RecentStore.shared().record(...)
            // HUD 自动在 ~1.2s 后关闭
        } catch {
            let friendly = SSHErrorMapper.friendlyMessage(for: error)
            await tracker.fail(friendly)
            // HUD 停留,等待用户关闭
        }
    }
}
```

## 测试策略(`FastSCPCoreTests`,TDD)

- `SCPProgressParserTests`:新增 `fileName` / `rate` 提取用例(常规 / 长名截断 / 缺速率);保留旧百分比用例。
- `TransferAggregatorTests`(新):纯状态机覆盖
  - 单文件 0→100%,`percent` 单调到 1.0。
  - 多文件:文件名切换时字节正确累加;`currentFileIndex` 正确递增。
  - pct 回退(`60% → 45% → 70%`)时 `completedBytes` 不下降。
  - 速率/文件名缺失:不崩,字段为 `nil`,`percent` 仍正确。
  - `complete()` 后 `percent == 1.0`,即使中间解析有缺口。
  - `fail("x")` 后 `phase == .failed("x")`,字节不被修正。
  - `percent` 永远钳在 [0,1]。
- `ByteFormatTests`(新):`12345678` → `"11.8MB"`、`1234` → `"1.2KB"`;速率同理;零/负数保护。

GUI(`TransferStatusView`、`QuickTransferHUDController`):手动 + 截图验证。

## 边界与已知限制

- **并发传输**:不支持;悬浮窗单实例,第二次快速触发复用同一 tracker。
- **巨大目录预扫**:后台 `Task` 执行,不卡主线程;`progress` 在 `preparing` 阶段可能短暂停留在 0%。
- **不可读文件**:本地扫描时大小计 0,文件计数 +1(不报错)。
- **符号链接**:只算链接本身,不跟随目标。
- **空选区**:`totalBytes == 0` → 跳过扫描直接进 `.done`(兼容理论极端情况)。
- **`scp` 退出非 0 但中途已显示过 100%**:`fail()` 不改字节,phase 切 failed,UI 显示错误;不显示虚假 100%。
- **`~/.ssh/config` 解析、Finder Sync、URL scheme**:本期完全不动。
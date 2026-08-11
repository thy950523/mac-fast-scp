# FastSCP 后续开发 Roadmap

一份活的事项清单，记录已识别但尚未动工的改进。条目按提出顺序排列，**不代表优先级**。
每条真正开工时，按 `docs/superpowers/specs/` + `docs/superpowers/plans/` 的惯例另出设计与实现计划。

---

## 1. 传输列表优化（发送与接收界面）

**现状**
传输进行中只显示「第 N / M 个文件」+ 当前正在传的文件名（`TransferStatusView`），
看不到整批文件各自的进度与状态。

**目标**
在当前文件指示下方再加一个**整批文件列表**，逐项显示状态（排队中 / 传输中 / 已完成 / 失败）。
发送与接收两个界面都要有。

**涉及**
- 视图：`Sources/FastSCP/TransferStatusView.swift`（面板内）、`Sources/FastSCP/QuickTransferHUDController.swift`（右上角 HUD）——两者共用同一套传输视图。
- 模型：`Sources/FastSCP/TransferTracker.swift` 与 `Sources/FastSCPCore/TransferProgress.swift` 的 `TransferAggregator` 目前只追踪「聚合字节数 + 当前文件」，需要升级为「文件列表 + 每项状态」。
- 数据源已就绪：scp 多文件传输时每个文件会输出独立进度条与 100% 收尾行（见 `docs/superpowers/specs/2026-08-10-scp-progress-and-extension-dedup-design.md` 实验 F），`SCPProgressParser` 已能解析出 `fileName`。

---

## 2. 弹窗消息展示更新

**现状**
弹窗字体偏小，且没有收缩（折叠）功能，需要更新。

**待澄清（开工前确认）**
「弹窗」具体指哪个？候选：
- 右上角传输浮窗 `Sources/FastSCP/QuickTransferHUDController.swift`（最贴合「弹窗」）；
- 覆盖确认弹窗 `Sources/FastSCP/OverwritePanel.swift`（标题「覆盖确认」，正文 13pt、列表高度固定不可折叠，符合「字小 + 不能收缩」）；
- 面板内的 `TransferStatusView` / `TransferPhaseView`。

系统通知（`Notifier`）的字体不在我们控制范围内。需先确认范围再动。

**涉及（视范围）**
- `Sources/FastSCP/QuickTransferHUDController.swift`
- `Sources/FastSCP/OverwritePanel.swift`
- `Sources/FastSCP/TransferStatusView.swift`

---

## 3. 重复文件勾选框 UI 优化

**现状**
重复文件确认时，勾选框颜色与背景重叠、看不清；勾选框与文件项的 UI 需要重新设计。

**技术定位**
目前唯一的「逐文件勾选」UI 是**发送方向**的覆盖确认弹窗 `Sources/FastSCP/OverwritePanel.swift`
（`OverwriteView` 用 `checkmark.square.fill` / `square` + `.foregroundStyle(.tint)`，
在 `List` 行里选中态背景也是 tint，二者容易糊在一起）。

⚠️ **接收方向目前没有任何重复文件确认**——scp 直接覆盖本地同名文件，不弹窗。

**待澄清（开工前确认）**
你说的「重复接收」是指：
- (a) 修这个**发送**覆盖弹窗的勾选对比度（把「传输」说成了「接收」）？还是
- (b) 想给**接收**也加一个重复文件确认流程（属于新功能，目前没有）？

两者范围差别很大。

**涉及**
- `Sources/FastSCP/OverwritePanel.swift`（至少 (a) 必改）
- 若 (b)：还需在 `Sources/FastSCP/ReceivePanel.swift` 的 `performPull` 前置一个本地碰撞检测 + 确认弹窗，并决定覆盖 / 跳过 / 重命名策略。

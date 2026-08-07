# FastSCP 接收功能设计文档

> 日期: 2026-08-06
> 目标: 在已有「发送」基础上，新增「从服务器接收(拉取)」功能，与发送交互对称、最大化复用现有基础设施。
> 前置结论: 发送已原生支持整个文件夹(见 §一)，本次**不改动发送链路**。

## 一、发送验证结论(本次实测)

实测 `scp -r` 与现有代码链路，确认：

- 选中文件夹发送 → 多层嵌套递归落地，**文件夹名保留**。
- 多选混合(文件 + 文件夹) → 各自落进目标目录，互不干扰。
- 链路 `FinderSync.selectedItemURLs()`(不过滤类型) → `SSHExecutor.transfer`(用 `-r`) → 已存在远端目录，全程无需改动。

scp 行为细节（关键）：

| 目标目录状态 | 行为 |
|---|---|
| **已存在**（FastSCP 的情况——你总是在面板里浏览到一个已存在的远端目录） | 发送文件夹 `foo` 到 `server:/var/www/` → 落地 `/var/www/foo/`，**名字保留** ✅ |
| 不存在 | 内容直接铺进目标，**名字丢失** |

FastSCP 始终是前者，符合用户直觉。**结论：发送文件夹本就工作正常，本次不改。**

## 二、目标与非目标（接收）

### 目标
- 从 Finder 右键或菜单栏发起「接收」，选择「哪台机器 + 接收哪些文件/目录」，确认后直接落到当前目录。
- 与发送对称：右键提供「本地侧」（当前目录 = 目标），面板负责「远端侧」（选源）。
- 复用：`~/.ssh/config` 解析、远端目录浏览器、`SSHExecutor`、进度解析、通知。

### 非目标（YAGNI）
- **不做**「最近来源 / 最近接收方」列表或子菜单（明确要求）。每次都是「点接收 → 选 → 确认」。
- **不做**零弹窗快路径（接收每次必须选源，无法像发送那样直达）。
- **不做**同步 / 监听 / 定时拉取（那是另一个产品）。
- **不做**断点续传（v1 用 `scp -r`）。

## 三、入口与 Finder 右键共存

单个 `FastSCP ▸` 父菜单，内部分两段，按上下文自适应：

```
右键
└── FastSCP ▸
    ├── ── 发送 ──            (选中 ≥1 项时可用)
    │     发送到 server1:/var/www      (一键, 零弹窗)
    │     最近目标 ▸
    │     手动选择…
    └── ── 接收 ──            (有「当前目录」即一直可用)
          从服务器接收…               (单入口, 无子菜单)
```

上下文规则：
- **发送**段：仅当 `selectedItemURLs()` 非空时可用（源 = 选中项）。
- **接收**段：始终可用。「当前目录」= 右键窗口所在目录（容器右键），或选中项的父目录（项右键）。

菜单栏：现有「传送到服务器…」下方加「从服务器接收…」，图标 `tray.and.arrow.down`（发送为 `...up`）。

## 四、接收流程

1. 入口（Finder 右键 / 菜单栏）→ 通过 URL scheme 唤起主 App，携带「当前目录」（菜单栏发起时无此参数）。
2. 主 App 弹出唯一接收面板。
3. 用户：选机器 → 浏览/键入远端路径 → 多选要接收的文件/文件夹 → 点「接收 N 项」。
4. 后台 `scp -r` 拉取到目标目录 → 面板底部原地变进度条 → 完成出系统通知。

## 五、接收面板（唯一弹窗）

```
┌─ 从服务器接收 ────────────────┐
│ 从哪台 [server1       ▾]       │  ① 机器下拉(默认上次那台)
│ 路径   [/var/log/       ] ↵   │   键入/回车跳转
│ ┌──────────────────────────┐ │
│ │ ☐ 📁 nginx        双击进入 │ │  ② 多选远端文件+目录
│ │ ☑ 📁 app                    │ │   文件夹: 双击进入; 勾选=拉取
│ │ ☑ 📄 access.log             │ │   文件: 勾选=拉取
│ │ ☑ 📄 error.log              │ │
│ └──────────────────────────┘ │
│  → 接收到 ~/work (当前目录)    │  目标目录(只读展示;菜单栏发起可「改…」)
│ [    接收 3 项 ← server1     ] │  确认 → 进度 → 通知
└──────────────────────────────┘
```

与发送面板的关系：复用「服务器下拉 + 路径输入 + 远端目录列表」骨架；差异在列表从「仅目录 / 单击导航」改为「文件 + 目录 / 多选」。建议抽出一个**共享的远端浏览器子视图**，发送 / 接收各自套选择语义。

目标目录：
- **Finder 右键发起** → 当前目录，面板只读展示，不可改。
- **菜单栏发起** → 默认 `~/Downloads`，给「改…」按钮（NSOpenPanel 选目录）。

轻量默认（非列表）：面板打开默认选上次用过的机器、停在上次浏览路径，仅为省去重新定位；**不构成任何「最近来源」UI**。

## 六、技术设计

### URL scheme 扩展
- `fastscp://receive?dest=<本地目录>` — Finder 右键发起，dest = 当前目录绝对路径；菜单栏发起，dest = `~/Downloads`。
- `URLCoordinator` 新增 `receiveRequest`（含 `destURL: URL`），`handle(_:)` 增加 `case "receive"`。

### 远端目录列表（选择模式）
- 现状：`SSHExecutor.listDirectory` 返回 `ls -ap` 结果并 `filter(\.isDirectory)`。
- 新增：`listEntries(alias:path:)`（或加参数）返回文件 + 目录，不过滤。`RemoteEntry.isDirectory` 已有，UI 据此区分图标与可进入性。
- 双击目录 → 进入；勾选 → 纳入待接收集合。

### 拉取执行
`SSHExecutor` 新增：
```swift
func pull(alias: String, remotePath: String, names: [String],
          localDest: URL, progress: @Sendable @escaping (SCPProgress?) -> Void) async throws
```
构造 `scp -r <alias>:<remotePath>/<name> ... <localDest>/`（每个选中项拼成完整远端操作数，目录/文件统一走 `-r`）。进度解析复用 `SCPProgressParser`。

### 目标目录解析（Finder 右键）
- 通过 `FIMenuKind` 区分容器右键 / 项右键。
- 容器右键 → 当前窗口目录（实现时确认取值方式：跟踪 `beginObservingDirectory` 或 `selectedItemURLs` 父级）。
- 项右键 → 选中项 `.deletingLastPathComponent()`。
- ⚠️ **待实现确认**：Finder Sync 取「当前窗口目录」的精确 API；这是「接收到当前目录」的关键依赖，实现时先验证。

### 面板与状态
- 新增 `ReceiveViewModel` / `ReceiveView` / `ReceivePanelController`（镜像发送三件套）。
- `AppDelegate.react()` 增加：有 `receiveRequest` → 创建并展示接收面板。
- `StatusItemController` 增加「从服务器接收…」菜单项。

### 记忆策略
- 接收**不新增**任何 recent 列表。
- 「默认机器/路径」只读取现有 `RecentStore`（发送侧）的 `first?.alias` 作为下拉默认值，**不写、不存**接收历史。

## 七、命令与落地行为

- 拉取：`scp -r server1:/var/log/app server1:/var/log/access.log ~/work/`
- 目标本地目录始终已存在（当前目录 / `~/Downloads`）→ 每个远端源名字保留，落进目标目录。
- 远端 `~` 由 scp 在远端展开，`alias:~/path/x` 可用。

## 八、错误处理（与发送一致）

- 认证失败 / 主机不可达 / 远端读权限不足 → stderr 经 `SSHErrorMapper` 友好化，面板内联展示。
- 本地目标不可写 → 提示并保留面板（不关闭）。
- 传输中取消 → kill `Process`（复用 `SSHExecutor.cancel()`）。

## 九、改动清单

| 文件 | 改动 |
|---|---|
| `FinderSync.swift` | 新增「从服务器接收…」项；按 menuKind 分段与门控；携带当前目录 |
| `URLCoordinator.swift` | `receiveRequest` + `case "receive"` |
| `SSHExecutor.swift` | `pull(...)` + `listEntries(...)`（含文件） |
| `DestinationPanel.swift`（或新文件） | `ReceiveViewModel/View/Controller` + 共享远端浏览器子视图 |
| `StatusItemController.swift` | 「从服务器接收…」菜单项 |
| `AppDelegate.swift` | `react()` 处理 receiveRequest |

## 十、测试策略

- 单测：拉取参数构造逻辑（给定 alias/path/names → 正确 argv）；`listEntries` 不过滤文件。
- 手测：真机右键 + 真实 SSH 服务器，验证接收到当前目录、文件夹/文件混合、名字保留。

## 十一、已知限制

- 接收无零弹窗快路径（每次须选源）。
- Finder Sync 取「当前目录」API 待实现时验证（见 §六）。
- 同名文件覆盖：scp 直接覆盖本地同名，v1 不做冲突确认（与 cp/scp 一致），后续可加。

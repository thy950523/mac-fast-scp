# 设计：SCP 实时进度回归 + 扩展重复注册根治

日期：2026-08-10

## 背景

两个独立问题，共用一次改动窗口：

1. **扩展重复**：每次重新构建后，「设置 > 登录项与扩展 > 扩展」出现多行同名 FastSCP。
2. **进度不实时**：当前工作区有一批未提交改动，把传输后端从 scp 换成了 rsync，动机是「scp 拿不到实时进度」。该前提经实验证伪，决定全部 revert，回到 scp。

## 调研结论

### scp 进度输出行为（实验实测）

用 `pty.fork()` + 逐次 `read()` 打时间戳的探针，在本地 macOS sshd（OpenSSH 10.2p1 / macOS 26.5.2）和真实远端 Linux（Ubuntu 5.15）两处验证：

| 实验 | 方案 | 读到字节 | 进度质量 |
|------|------|---------|---------|
| A | `scp`（默认 SFTP）+ PTY | 2722 | ❌ 字节数卡死 3%，显示 `- stalled -`，末尾跳 100% |
| B | `scp -O` + PTY | 2882 | ✅ 每秒真实递增 |
| C | `scp -O`，纯管道 stdout | **0** | ❌ 完全无输出 |
| D | `scp -O -v`，纯管道 | 6630 | ❌ 仅握手日志，传输 34s 内零进度 |
| E | `script -q /dev/null scp -O`，纯管道 | 2806 | ✅ 每秒实时（0.13s/1.14s/2.14s…） |
| F | 同 E，多文件递归目录 | 2410 | ✅ 每文件独立进度条 + 100% 收尾行 |
| G | 同 E，真实远端 Linux | 2806 | ✅ 与本地一致 |

三条结论：

1. **「直接读 scp 的 stdout」不可行**（实验 C）。scp 对 stdout 做 `isatty()`，非 TTY 时进度条一个字节都不输出。`-v` 也不含进度（实验 D）。必须有伪终端。
2. **`script(1)` 包装就够了**（实验 E），不需要手写 `forkpty` + termios。仓库 commit `ef36217` 的注释称「script 会块缓冲导致卡在 0%」，该诊断错误。
3. **`-O` 是关键**。`SCPCommandBuilder.swift` 现有注释称「macOS scp 静默忽略 -O」，在 OpenSSH 10.2p1 上不成立；`-O` 正常工作并强制 legacy SCP 协议。不加 `-O` 走 SFTP，字节计数器本身不动（实验 A 复现了「卡住」现象）——这才是进度条卡死的真因，与 `script` 无关。

### 工程细节（实测）

- **stdin**：保持打开的 `Pipe` 认证正常；用 `/dev/null` 会导致认证提前中止（对应 commit `b497171`）。
- **取消**：`script` 把 scp 放进独立进程组；SIGTERM 打给 `script` 后，scp 因 PTY 主端关闭收到 SIGHUP 退出。压测 6/6 无孤儿进程。
- **多文件**：递归传输时每个文件输出独立进度条与 100% 收尾行，可由现有 `TransferAggregator` 聚合。

### 扩展重复的根因

设置面板的扩展列表**按 App 分组，分组数据来自 LaunchServices**。现场：

- PluginKit 只有 **1** 条记录 → 不是 PluginKit 的问题。
- LaunchServices 记着 **4** 个 `FastSCP.app` 路径，每个占一行：
  - `/Applications/FastSCP.app`（install.sh 的目标）
  - `~/Applications/FastSCP.app`（历史手工副本，二进制不同且更新，是当前唯一注册 appex 的）
  - `…/DerivedData/FastSCP-duquaqrhbrjdzqcunpcofpsyfzxa/Build/Products/Debug/FastSCP.app`
  - `…/DerivedData/FastSCP-new/Build/Products/Debug/FastSCP.app`

两个 DerivedData 路径的 `.app` **仍在磁盘上**。`install.sh` 只删自己的临时构建目录（`$TMPDIR/fastscp-install-build`），管不到 `execute.sh` 第 3 步产生的 Debug 构建。

因此现有 `pruneStaleLaunchServicesEntries()` 治标不治本：`lsregister -u` 注销后，磁盘上的 `.app` 会被重新索引加回来。**必须先断源头（删磁盘副本），再清记录。**

## 决策

| 议题 | 决定 |
|------|------|
| 构建方式 | 只用 `scripts/install.sh`，装到 `/Applications` |
| rsync 相关未提交改动 | 全部删除，回到纯 SCP |
| 进度精度 | 整体百分比 + 速度 + 当前文件名 |
| `~/Applications/FastSCP.app` | 删除，统一以 `/Applications` 为准 |
| DerivedData 产物清理时机 | `install.sh` 里自动清 |

## 设计

### 第一部分：实时进度改回 SCP

**执行链路**

```
Process(/usr/bin/script -q /dev/null /usr/bin/scp -O -r <args>)
  ├─ stdout+stderr → 同一个 Pipe（进度在 stdout，错误在 stderr，合并便于出错回显）
  ├─ stdin        → Pipe 并保持打开（不可用 /dev/null，否则 ssh 认证提前中止）
  └─ 增量读取 → LineScanner 按 \r/\n 切行 → SCPProgressParser.parse
```

**改动**

- `SCPCommandBuilder`：`pullArgs` 加 `-O`；修正「macOS 忽略 -O」的错误注释。
- `SSHExecutor`：删除 `forkpty` / termios / winsize / setsockopt / 手工 `waitpid` 一整套（约 100 行 C 互操作），改用标准 `Process` + `Pipe`；`transfer` 与 `pull` 均经 `script` 包装并带 `-O`。
- 取消：`proc.terminate()`，保留现有 250ms 后 SIGKILL 兜底。

**保留不动**：`SCPProgressParser`、`TransferAggregator`、`RemoteSizeProbe`、`TransferTracker` 全部复用，已能产出「整体百分比 + 速度 + 当前文件名」。`SCPProgressParser` 中剥离 `^D\x08\x08` 的逻辑对应 `script` 的输出特征，继续需要。

**revert 范围**：7 个改动文件 `git checkout` 回 `cb0f5d4`，删除 `RsyncCommandBuilder.swift`、`RsyncProgressParser.swift`。revert 会一并恢复被顺手删掉的内容——`waitForExit` 注释、`removeRemoteEntries` 的 `rm -rf` 安全说明、`SharedPaths` 的沙盒容器路径映射。最后一项需留意：未提交版本把扩展与 App 的共享目录改成同一个 `~/Library/Application Support/FastSCP`，revert 会改回容器路径映射。

### 第二部分：扩展重复注册

**① `install.sh` 增加「消除竞争副本」步骤**（重签名之后、注册之前）

逐项先注销 LS 记录再删目录：

- 扫描 DerivedData 下所有 `FastSCP.app`（含 `FastSCP-new`、`FastSCP-*` 各变体），`lsregister -u` 后 `rm -rf` 该 `.app`
- 删除 `~/Applications/FastSCP.app`
- 现有 `pluginkit -r` 循环改为对所有路径注销，然后只 `-a` 注册 `/Applications` 那一份

删除范围严格限定为以 `FastSCP.app` 结尾、且位于 DerivedData 或 `~/Applications` 之下的路径。

**② `execute.sh` 不再污染共享 DerivedData**

第 3 步 Debug 构建加 `-derivedDataPath "$TMPDIR/fastscp-debug-build"`，结束即删。

**③ `ExtensionChecker.pruneStaleLaunchServicesEntries()` 保留作兜底**

代码逻辑不变（revert 后即原样），App 启动时后台跑，处理脚本未覆盖的意外路径。

**为什么删除逻辑放脚本而非 App**：App 在用户会话里 `rm -rf` 其它目录风险收益不划算；构建脚本是这些产物的创造者，由它清理更合适。

## 验证

**进度**：`execute.sh` 构建安装后，向 `tencent` 传几十 MB 文件，确认进度条平滑递增而非 0→100 跳变；中途取消，确认无残留进程。

**扩展**：跑一次 `install.sh`，确认 `lsregister -dump` 只剩 `/Applications/FastSCP.app` 一条、`pluginkit` 只有一条指向它的记录，设置面板只有一行；再跑一次 `execute.sh`，确认无新增记录。

## 已知影响

清理会注销并删除 `~/Applications/FastSCP.app`，它当前是唯一注册 appex 的副本。清理后扩展重新指向 `/Applications` 那份，可能需要在设置里重新勾选一次扩展开关，Finder 菜单才会恢复。

## 实现记录

实现于 2026-08-10，按 `docs/superpowers/plans/2026-08-10-scp-progress-and-extension-dedup.md` 执行，分支 `fix/scp-progress-extension-dedup`。

**已完成**

- 未提交的 rsync 改动全部 revert，两个 rsync 源文件已删除。删除后需要 `xcodegen generate`
  重新生成 `.xcodeproj`（它被 git 忽略但仍列着已删文件，否则构建失败）。
- `SCPCommandBuilder` 加 `-O`，修正了「macOS scp 忽略 -O」的错误注释。
- `SSHExecutor` 改用 `script -q /dev/null` + 标准 `Process`，删除 forkpty/termios/
  TCP_NODELAY/轮询读线程一整套 C 互操作（-134/+70 行）；取消改为 `proc.terminate()`
  + 250ms SIGKILL 兜底。
- `install.sh` 新增「消除竞争副本」步骤；`execute.sh` 的 Debug 构建改用临时 derivedDataPath。

**验收结果**

进度（Task 4，人工验证）：发送与接收进度条均平滑推进，本次改动的核心目标达成。

扩展去重（Task 6，人工验证）：LaunchServices 与 PluginKit 各只剩一条指向 `/Applications`
的记录，`~/Applications` 旧副本与 DerivedData 构建产物均已清除，设置面板确认只有一行。

**实现中修正的三处计划缺陷**

1. `[ -d "$path" ] || return` 在 `set -e` 下会传播退出码 1 并中止 `install.sh` ——
   且恰好在本次改动造成的稳态（副本已清干净）下触发。改为 `return 0`。
2. `pluginkit -mAvvv` 是错的。按 man page，`-A` 只返回**每个版本最后注册的那个实例**，
   而本项目的情况正是同版本 4 份副本。实测 `-mAvvv` 列出 482 条 `Path`，`-mADvvv`
   列出 494 条（多出 12 条被隐藏的重复实例）。核对处用 `-A` 会只显示一行、
   谎报「已只剩一条」。两处均改为 `-mADvvv`。
3. 末尾的 `grep` 无匹配时在 `pipefail` 下返回 1，作为脚本最后一条命令会让安装成功的
   `install.sh` 报失败。加 `|| true`。

另外给删除闸门补了第三道 `..` 路径穿越拒绝：原先两道闸门是纯字面匹配，而 `case` 的 `*`
会匹配 `/`，所以 `$HOME/Applications/../../VICTIM/FastSCP.app` 能同时骗过两道。当前没有
调用点能传入 `..`，但这个函数会对用户 home 目录跑 `rm -rf`，注释又声称「一眼看出它删不到
别处」——补上闸门让这句话成立。

以及一处 Task 6 验收时发现的脚本缺陷：两个脚本都在 `rm -rf` 临时构建目录后**紧接着**
打印 LaunchServices 核对，正好落在 LS 的收敛窗口内，每次都显示 2-3 行、看着像失败
（实测目录已从磁盘删除，约 20 秒后 LS 自行收敛回一条）。改为删除前先主动
`lsregister -u`，不等系统淘汰。

## 遗留问题（不属于本次计划范围）

Task 4 人工验收时发现三个传输相关缺陷，**均非本次改动引入**，已另行安排修复：

- **快捷发送 HUD 没有取消按钮** —— `QuickTransferHUDController` 的 `.sending` 分支从未
  绘制取消按钮，功能从未实现过。
- **接收取消后 UI 卡在「接收中」** —— 表象，根因见下。
- **`SSHExecutor` 单例并发冲突（根因）** —— 它是 `static let shared`，只有一个
  `runningProcess` 字段，但传输可以并发。`debug.log` 实证：

      11:06:09 [ssh] scp args=... epub      <- 传输 A 开始
      11:06:20 [ssh] scp args=... psd       <- 传输 B 开始，A 仍在跑
      11:06:24 [ssh] cancel() process=true  <- 杀掉的是 B
      11:06:55 [ssh] OK                     <- A 照常完成

  后启动的传输覆盖了先前的进程引用，先启动的那个从此无法取消（日志中多次出现
  `cancel() called process=false`），且 `cancelled` 标志会被后续传输重置。

修复方向（已与使用者确认）：改为每个传输持有独立句柄，取消只作用于自己那个；HUD 加取消按钮。

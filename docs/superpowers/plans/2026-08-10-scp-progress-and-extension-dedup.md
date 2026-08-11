# SCP 实时进度回归 + 扩展重复注册根治 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把传输后端从未提交的 rsync 改动 revert 回 scp，用 `script(1)` + `-O` 拿到实时进度；同时根治「每次构建后设置里出现重复 FastSCP 扩展」。

**Architecture:** scp 对 stdout 做 `isatty()` 检测，非 TTY 时进度条零输出，因此必须有伪终端；实验证明 `script -q /dev/null` 包装后经普通管道读取即可每秒实时收到进度，不需要手写 `forkpty`。`-O` 强制 legacy SCP 协议（不加则走 SFTP，字节计数器不动，这是进度条卡死的真因）。扩展重复源于 LaunchServices 记录了 4 个 `FastSCP.app` 路径，磁盘上的旧副本不删就会被重新索引，所以由构建脚本负责「先注销记录、再删磁盘副本」。

**Tech Stack:** Swift 6.0 / macOS 14+、XCTest、xcodegen、xcodebuild、bash、`/usr/bin/script`、`/usr/bin/scp`、`pluginkit`、`lsregister`

## Global Constraints

- Swift 版本 `6.0`，部署目标 macOS `14.0`（见 `project.yml`）。
- **安全红线（不可协商）**：`removeRemoteEntries` 只允许删除本次上传的同名冲突项，且必须是单个路径分量。任何改动都不得放宽这一范围——历史上曾因此误删整个 home 目录。本计划不触碰该函数，revert 时须确认其安全注释被完整恢复。
- scp 调用一律带 `-O`。不加 `-O` 会退回 SFTP 模式，字节计数器不递增。
- `script` 包装的子进程 **stdin 必须是保持打开的 `Pipe`**，不可用 `/dev/null`——否则 ssh 认证在 keychain 提示前就中止。
- 脚本删除文件时，路径必须同时满足：以 `FastSCP.app` 结尾、且位于 DerivedData 或 `~/Applications` 之下。绝不递归删除其它任何位置。
- 安装目标统一为 `/Applications/FastSCP.app`。
- 测试只覆盖 `FastSCPCore`（纯逻辑）。`SSHExecutor` 属 App target，无测试宿主，靠真实远端手工验证。

---

### Task 1: Revert 未提交的 rsync 改动，回到纯 SCP 基线

**Files:**
- Modify (revert): `Sources/FastSCP/AppDelegate.swift`、`Sources/FastSCP/ExtensionChecker.swift`、`Sources/FastSCP/SSHExecutor.swift`、`Sources/FastSCPCore/DiagLog.swift`、`Sources/FastSCPCore/SCPCommandBuilder.swift`、`Sources/FastSCPCore/SharedPaths.swift`、`Sources/FastSCPFinderSync/FinderSync.swift`
- Delete: `Sources/FastSCPCore/RsyncCommandBuilder.swift`、`Sources/FastSCPCore/RsyncProgressParser.swift`

**Interfaces:**
- Consumes: 无（起始任务）
- Produces: 工作区回到 `cb0f5d4` 的代码状态。后续任务依赖此基线中的 `SCPCommandBuilder.pullArgs(alias:remotePath:names:localDest:) -> [String]`、`SSHExecutor.runWithProgress(exec:args:progress:)`、`LineScanner.feed(_:)`、`SCPProgressParser.parse(_:) -> SCPProgress?`。

- [ ] **Step 1: 确认当前未提交改动范围与预期一致**

Run:
```bash
git status --short
```
Expected: 恰好 7 个 ` M` 文件 + 2 个 `??` 文件（`RsyncCommandBuilder.swift`、`RsyncProgressParser.swift`）。若不符，停下来报告差异，不要继续。

- [ ] **Step 2: Revert 7 个已修改文件**

```bash
git checkout -- \
  Sources/FastSCP/AppDelegate.swift \
  Sources/FastSCP/ExtensionChecker.swift \
  Sources/FastSCP/SSHExecutor.swift \
  Sources/FastSCPCore/DiagLog.swift \
  Sources/FastSCPCore/SCPCommandBuilder.swift \
  Sources/FastSCPCore/SharedPaths.swift \
  Sources/FastSCPFinderSync/FinderSync.swift
```

- [ ] **Step 3: 删除两个 rsync 新文件**

```bash
rm -f Sources/FastSCPCore/RsyncCommandBuilder.swift Sources/FastSCPCore/RsyncProgressParser.swift
```

- [ ] **Step 4: 确认工作区干净**

Run:
```bash
git status --short
```
Expected: 无输出（完全干净）。

- [ ] **Step 5: 确认安全红线注释已随 revert 恢复**

Run:
```bash
grep -n "SAFETY (project baseline, non-negotiable)" Sources/FastSCP/SSHExecutor.swift
```
Expected: 有一行匹配。这是 `removeRemoteEntries` 上方的安全说明，必须存在。

- [ ] **Step 6: 确认 SharedPaths 已恢复为容器路径映射**

Run:
```bash
grep -n "Library/Containers" Sources/FastSCPCore/SharedPaths.swift
```
Expected: 有一行匹配。revert 把共享目录改回了「扩展走沙盒容器、App 走绝对容器路径」的映射。

- [ ] **Step 7: 跑测试确认基线可编译且通过**

Run:
```bash
xcodebuild test -project FastSCP.xcodeproj -scheme FastSCPCore -destination 'platform=macOS' -quiet
```
Expected: `TEST SUCCEEDED`。

无需 commit —— 本任务只是把工作区恢复到已提交状态，没有产生新改动。

---

### Task 2: `SCPCommandBuilder` 加 `-O` 并修正错误注释

**Files:**
- Modify: `Sources/FastSCPCore/SCPCommandBuilder.swift`
- Test: `Tests/FastSCPCoreTests/SCPCommandBuilderTests.swift`

**Interfaces:**
- Consumes: Task 1 的基线 `SCPCommandBuilder.pullArgs(alias:remotePath:names:localDest:) -> [String]`，当前返回以 `["-r", ...]` 开头的数组。
- Produces: `pullArgs` 返回值改为以 `["-r", "-O", ...]` 开头。Task 3 的 `SSHExecutor.pull` 直接透传该数组，`transfer` 需自行构造同样带 `-O` 的 argv。

- [ ] **Step 1: 修改 4 个现有测试的期望值，让它们包含 `-O`**

把 `Tests/FastSCPCoreTests/SCPCommandBuilderTests.swift` 整个文件替换为：

```swift
import XCTest
@testable import FastSCPCore

final class SCPCommandBuilderTests: XCTestCase {
    func testPullArgsBasic() {
        let dest = URL(fileURLWithPath: "/Users/x/work")
        let args = SCPCommandBuilder.pullArgs(
            alias: "server1", remotePath: "/var/log",
            names: ["access.log", "app"], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O", "server1:/var/log/access.log", "server1:/var/log/app", "/Users/x/work/"])
    }

    func testPullArgsStripsTrailingSlashOnRemotePath() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/var/log/", names: ["a"], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O", "s:/var/log/a", "/d/"])
    }

    func testPullArgsHandlesTildeRemotePath() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "~", names: ["x"], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O", "s:~/x", "/d/"])
    }

    func testPullArgsPreservesSpacesInNames() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/p", names: ["my file.txt"], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O", "s:/p/my file.txt", "/d/"])
    }

    /// `-O` 强制 legacy SCP 协议。缺了它 scp 走 SFTP，进度行的字节计数器
    /// 不递增（实测卡在 3% 直到结束），进度条形同虚设。
    func testPullArgsAlwaysIncludesLegacyProtocolFlag() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/p", names: ["a"], localDest: dest)
        XCTAssertTrue(args.contains("-O"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
xcodebuild test -project FastSCP.xcodeproj -scheme FastSCPCore -destination 'platform=macOS' -quiet 2>&1 | tail -30
```
Expected: FAIL —— 5 个测试里至少 4 个因为 `-O` 缺失而 `XCTAssertEqual` 不匹配。

- [ ] **Step 3: 实现 —— 把 `SCPCommandBuilder.swift` 整个文件替换为**

```swift
import Foundation

/// 构造 `scp` 的 argv。纯函数，便于单测。
/// 远端操作数形如 `<alias>:<remotePath>/<name>`；scp 以 argv 传递（非 shell），
/// 故文件名中的空格无需转义。
public enum SCPCommandBuilder {
    /// 强制 legacy SCP 协议。
    ///
    /// 不加 `-O` 时 scp 走 SFTP：进度行照常每秒重绘，但其中的已传输字节数
    /// **不递增**（实测 8MB 文件整个传输过程卡在 `3% 255KB`，末尾直接跳
    /// 100%）。加上 `-O` 后同一文件稳定输出 3% → 6% → 8% …。
    ///
    /// 注：早先代码注释称「macOS 的 scp 静默忽略 -O」，在 OpenSSH 10.2p1
    /// (macOS 26.5) 上不成立 —— `-O` 工作正常。
    public static let legacyProtocolFlag = "-O"

    /// `scp -r -O <alias>:<remotePath>/<name> ... <localDest>/`
    /// - Parameters:
    ///   - alias: ssh config 别名
    ///   - remotePath: 远端目录（可带或不带尾斜杠、可为 `~`）
    ///   - names: 要拉取的条目名（文件或目录）
    ///   - localDest: 本地目标目录（需已存在）
    public static func pullArgs(alias: String, remotePath: String,
                                names: [String], localDest: URL) -> [String] {
        let base = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        var args = ["-r", legacyProtocolFlag]
        for name in names {
            args.append("\(alias):\(base)/\(name)")
        }
        args.append(localDest.path + "/")
        return args
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run:
```bash
xcodebuild test -project FastSCP.xcodeproj -scheme FastSCPCore -destination 'platform=macOS' -quiet
```
Expected: `TEST SUCCEEDED`。

- [ ] **Step 5: Commit**

```bash
git add Sources/FastSCPCore/SCPCommandBuilder.swift Tests/FastSCPCoreTests/SCPCommandBuilderTests.swift
git commit -m "fix(scp): pass -O to force legacy protocol so byte counter advances

Without -O, scp falls back to SFTP where the progress line redraws every
second but its transferred-byte field never moves (measured: an 8MB file
sat at '3% 255KB' for the whole transfer, then jumped to 100%). With -O
the same file reports 3% -> 6% -> 8% steadily.

The old comment claiming macOS scp ignores -O is wrong on OpenSSH 10.2p1."
```

---

### Task 3: `SSHExecutor` 改用 `script(1)` 包装，删除 forkpty

**Files:**
- Modify: `Sources/FastSCP/SSHExecutor.swift`

**Interfaces:**
- Consumes: Task 2 的 `SCPCommandBuilder.pullArgs(...)`（已含 `-O`）与 `SCPCommandBuilder.legacyProtocolFlag`；基线中的 `LineScanner.feed(_:)`、`SCPProgressParser.parse(_:)`、`DiagLog.log(_:)`、`SSHError`。
- Produces: `transfer(alias:path:sources:progress:)` 与 `pull(alias:remotePath:names:localDest:progress:)` 签名不变，调用方（`TransferTracker`）无需改动。内部新增 `private func runWithProgress(args:progress:)`（注意：**去掉了 `exec:` 参数**，因为可执行文件恒为 `/usr/bin/script`）。

**背景（实测数据，供实现者理解为何这样写）：**

| 方案 | 读到字节 | 结果 |
|------|---------|------|
| `scp -O` 直连管道 | **0** | scp 检测到非 TTY，进度条完全不输出 |
| `scp -O -v` 直连管道 | 6630 | 只有握手日志，34 秒传输期间零进度 |
| `script -q /dev/null scp -O` 经管道 | 2806 | 每秒实时到达（0.13s / 1.14s / 2.14s …） |

取消行为实测：`script` 会把 scp 放进独立进程组；SIGTERM 打给 `script` 后 scp 因 PTY 主端关闭收到 SIGHUP 退出。6/6 次压测无孤儿进程。

- [ ] **Step 1: 替换 `transfer` 方法及其上方的过时注释**

在 `Sources/FastSCP/SSHExecutor.swift` 中，找到 `transfer` 方法连同它上方那段以 `/// NOTE: macOS's` 开头的注释块，整体替换为：

```swift
    /// `scp -r -O <sources> <alias>:<path>`; `progress` receives parsed updates.
    func transfer(alias: String, path: String, sources: [URL],
                  progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        var args = ["-r", SCPCommandBuilder.legacyProtocolFlag]
        args.append(contentsOf: sources.map(\.path))
        let safePath = path.hasSuffix("/") ? path : path + "/"
        args.append("\(alias):\(safePath)")
        try await runWithProgress(args: args, progress: progress)
    }
```

- [ ] **Step 2: 替换 `pull` 方法及其上方注释**

找到 `pull` 方法连同上方 `/// See note on \`transfer\` regarding \`-O\`.` 那两行注释，整体替换为：

```swift
    /// `scp -r -O <alias>:<remotePath>/<name> ... <localDest>/`；argv 由 `SCPCommandBuilder` 构造。
    func pull(alias: String, remotePath: String, names: [String],
              localDest: URL, progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        let args = SCPCommandBuilder.pullArgs(
            alias: alias, remotePath: remotePath, names: names, localDest: localDest)
        try await runWithProgress(args: args, progress: progress)
    }
```

- [ ] **Step 3: 替换整个 `runWithProgress` 函数体**

找到 `private func runWithProgress(exec: String, args: [String],` 开始、到该函数结尾（即 `progress(nil) // signal completion` 后的 `}`）为止的**整个函数**，替换为：

```swift
    /// 用 `script(1)` 分配伪终端后运行 scp，边读边解析进度。
    ///
    /// scp 对 stdout 做 `isatty()` 检测：直连管道时进度条**一个字节都不输出**
    /// （实测 0 字节），`-v` 也只有握手日志、不含进度。所以必须有 pty。
    ///
    /// 这里用 `script -q /dev/null` 而非手写 forkpty —— 实测 `script` 包装后经
    /// 普通管道读取，进度每秒实时到达（0.13s / 1.14s / 2.14s …），没有块缓冲。
    /// 早先代码认为「script 会块缓冲导致进度卡在 0%」，那个诊断是错的：真正
    /// 的原因是缺 `-O`，SFTP 模式下字节计数器本身就不动。
    ///
    /// stdin 必须是**保持打开的管道**：喂 `/dev/null` 会让 ssh 在 keychain
    /// 提示前就判定认证失败而中止。
    private func runWithProgress(args: [String],
                                 progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        cancelled = false
        DiagLog.log("[ssh] scp args=\(args.joined(separator: " "))")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        proc.arguments = ["-q", "/dev/null", "/usr/bin/scp"] + args

        // stdout 与 stderr 合流：进度写在 stdout，报错写在 stderr，失败时要一起回显。
        let output = Pipe()
        proc.standardOutput = output
        proc.standardError = output
        // 保持打开、永不写入 —— 见上方注释，不能用 /dev/null。
        let stdin = Pipe()
        proc.standardInput = stdin

        let collected = OutputAccumulator()
        let lineScanner = LineScanner { line in progress(SCPProgressParser.parse(line)) }

        // readabilityHandler 在后台队列上按到达节奏回调，无需自建线程或轮询。
        let handle = output.fileHandleForReading
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            collected.append(chunk)
            if let text = String(data: chunk, encoding: .utf8) {
                lineScanner.feed(text)
            }
        }

        runningProcess = proc
        do {
            try proc.run()
        } catch {
            handle.readabilityHandler = nil
            runningProcess = nil
            throw SSHError.transferFailed(stderr: "无法启动 scp：\(error.localizedDescription)")
        }

        await waitForExit(proc)

        handle.readabilityHandler = nil
        // 进程退出与 handler 最后一次回调之间有窗口，把残留数据补读进来。
        let tailData = handle.availableData
        if !tailData.isEmpty {
            collected.append(tailData)
            if let text = String(data: tailData, encoding: .utf8) {
                lineScanner.feed(text)
            }
        }
        runningProcess = nil

        let tail = collected.text
        if cancelled {
            cancelled = false
            DiagLog.log("[ssh] cancelled by user")
            throw SSHError.cancelled
        }
        guard proc.terminationStatus == 0 else {
            DiagLog.log("[ssh] FAILED status=\(proc.terminationStatus) output=\(tail)")
            throw SSHError.transferFailed(stderr: tail)
        }
        DiagLog.log("[ssh] OK")
        progress(nil) // signal completion
    }
```

- [ ] **Step 4: 改写 `cancel()` 使其终止 `Process` 而非 pty 子进程**

找到整个 `func cancel()` 方法，替换为：

```swift
    func cancel() {
        DiagLog.log("[ssh] cancel() called process=\(runningProcess != nil)")
        cancelled = true
        guard let proc = runningProcess, proc.isRunning else { return }
        // TERM 给 script；scp 在独立进程组里，会因 pty 主端关闭收到 SIGHUP 退出
        // （压测 6/6 次无孤儿进程）。250ms 后仍在则强杀兜底。
        proc.terminate()
        let pid = proc.processIdentifier
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(250)) {
            if kill(pid, 0) == 0 {
                DiagLog.log("[ssh] cancel: TERM ignored, sending SIGKILL")
                _ = kill(pid, SIGKILL)
            }
        }
    }
```

- [ ] **Step 5: 删除不再使用的 `childPid` 属性**

找到并删除这两行（在 actor 顶部的属性声明区）：

```swift
    /// pid of the pty child (scp), when a transfer is running via forkpty.
    private var childPid: pid_t = 0
```

- [ ] **Step 6: 确认 forkpty 相关代码已彻底移除**

Run:
```bash
grep -nE "forkpty|termios|winsize|TCP_NODELAY|setpgid|execvp|waitpid|childPid" Sources/FastSCP/SSHExecutor.swift
```
Expected: 无输出。若有残留，删掉对应代码。

- [ ] **Step 7: 确认 `script` 与 `-O` 已就位**

Run:
```bash
grep -nE '/usr/bin/script|legacyProtocolFlag' Sources/FastSCP/SSHExecutor.swift
```
Expected: 至少 3 行 —— `runWithProgress` 里的 executableURL 与 arguments，以及 `transfer` 里的 `legacyProtocolFlag`。

- [ ] **Step 8: 构建 App target 确认编译通过**

Run:
```bash
xcodegen generate && xcodebuild -project FastSCP.xcodeproj -scheme FastSCP -configuration Debug -destination 'platform=macOS' -derivedDataPath "${TMPDIR:-/tmp}/fastscp-plan-build" build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual -quiet && rm -rf "${TMPDIR:-/tmp}/fastscp-plan-build"
```
Expected: `BUILD SUCCEEDED`。（用临时 derivedDataPath，避免往共享 DerivedData 里再留一份 `.app` —— 那正是 Task 5 要根治的污染源。）

- [ ] **Step 9: 跑核心测试确认无回归**

Run:
```bash
xcodebuild test -project FastSCP.xcodeproj -scheme FastSCPCore -destination 'platform=macOS' -quiet
```
Expected: `TEST SUCCEEDED`。

- [ ] **Step 10: Commit**

```bash
git add Sources/FastSCP/SSHExecutor.swift
git commit -m "refactor(ssh): wrap scp in script(1) instead of hand-rolled forkpty

scp emits zero bytes of progress to a plain pipe (isatty check), so a pty
is required. Measurements show 'script -q /dev/null' delivers progress in
real time over an ordinary pipe (0.13s/1.14s/2.14s...), so the ~100 lines
of forkpty + termios + TCP_NODELAY + polling reader are unnecessary.

The comment they were written to work around ('script block-buffers, bar
freezes at 0%') misdiagnosed the problem: the frozen meter came from the
missing -O flag, fixed in the previous commit.

Cancel now terminates the script process; scp exits via SIGHUP when the
pty master closes (6/6 stress runs left no orphans)."
```

---

### Task 4: 手工验证实时进度与取消（真实远端）

**Files:** 无代码改动 —— 这是验收关卡。

**Interfaces:**
- Consumes: Task 3 完成后的 `SSHExecutor`。
- Produces: 「进度可用」的确认。若失败，须回到 Task 3 修复而非继续 Task 5。

- [ ] **Step 1: 先用命令行独立复核 `script + -O` 在本机可行**

```bash
mkdir -p /tmp/fastscp-verify && dd if=/dev/urandom of=/tmp/fastscp-verify/big.bin bs=1m count=8 2>/dev/null
ssh tencent 'mkdir -p /tmp/fastscp-verify'
/usr/bin/script -q /dev/null /usr/bin/scp -O -l 2000 /tmp/fastscp-verify/big.bin tencent:/tmp/fastscp-verify/ | cat
```
Expected: 输出多行进度，百分比与字节数**持续递增**（3% → 6% → 9% …），不是 0% 停留后直接 100%。若这一步就不递增，说明环境与调研时不同，停下来报告。

- [ ] **Step 2: 构建并安装到 /Applications**

```bash
./scripts/execute.sh
```
Expected: 四步全部通过，App 启动。

- [ ] **Step 3: 在 App 里发送一个大文件，观察进度条**

用 Finder 选中 `/tmp/fastscp-verify/big.bin`，通过 FastSCP 发送到 `tencent` 的 `/tmp/fastscp-verify/`。

Expected：进度条**平滑推进**，百分比、速度、当前文件名都在变。不接受 0% 停住然后跳 100%。

- [ ] **Step 4: 传输中途点取消**

在进度约 30–50% 时点取消。

Expected: HUD 显示已取消（不是「传输失败」）。

- [ ] **Step 5: 确认无残留进程**

Run:
```bash
pgrep -fl "scp -O" || echo "no leftover scp"
```
Expected: `no leftover scp`。

- [ ] **Step 6: 验证接收方向**

在 FastSCP 的接收面板里，从 `tencent:/tmp/fastscp-verify/` 拉回 `big.bin` 到本地某目录。

Expected: 进度同样平滑推进，完成后本地文件大小为 8MB。

- [ ] **Step 7: 清理测试文件**

```bash
rm -rf /tmp/fastscp-verify
ssh tencent 'rm -rf /tmp/fastscp-verify'
```

无 commit —— 纯验证任务。

---

### Task 5: `install.sh` 消除竞争副本，`execute.sh` 停止污染 DerivedData

**Files:**
- Modify: `scripts/install.sh`
- Modify: `scripts/execute.sh:21-30`

**Interfaces:**
- Consumes: 无代码依赖。
- Produces: 一个跑完后能保证「LaunchServices 中只剩 `/Applications/FastSCP.app` 一条」的安装脚本。

**背景：** 设置里的扩展列表按 App 分组，分组数据来自 LaunchServices。现场 PluginKit 只有 1 条记录，但 LS 有 4 条 `FastSCP.app` 路径（`/Applications`、`~/Applications`、两个 DerivedData 构建产物），每条各占一行。两个 DerivedData 的 `.app` **仍在磁盘上**，所以只 `lsregister -u` 注销没用 —— 会被重新索引加回来。必须先注销、再删磁盘副本。

- [ ] **Step 1: 在 `install.sh` 中插入「消除竞争副本」函数**

在 `scripts/install.sh` 中，把从 `echo "==> 注销所有已存在的 FastSCP 扩展注册"` 开始到该 `done` 结束的整个代码块，替换为：

```bash
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 只允许删除「以 FastSCP.app 结尾」且「位于 DerivedData 或 ~/Applications 之下」
# 的路径。这道闸门是刻意收紧的：脚本里出现 rm -rf 就必须能一眼看出它删不到别处。
purge_app_copy() {
    local path="$1"
    case "$path" in
        */FastSCP.app) ;;
        *) echo "    ! 跳过（非 FastSCP.app）：$path"; return ;;
    esac
    case "$path" in
        "$HOME"/Library/Developer/Xcode/DerivedData/*|"$HOME"/Applications/*) ;;
        *) echo "    ! 跳过（不在允许范围内）：$path"; return ;;
    esac
    [ -d "$path" ] || return
    echo "    - $path"
    "$LSREGISTER" -u "$path" 2>/dev/null || true
    rm -rf "$path"
}

echo "==> 清理磁盘上的竞争副本（DerivedData 构建产物 / ~/Applications 旧副本）"
# 先断源头：磁盘上的 .app 不删，lsregister -u 之后会被重新索引加回来。
while IFS= read -r p; do
    purge_app_copy "$p"
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 -name "FastSCP.app" -type d 2>/dev/null)
purge_app_copy "$HOME/Applications/FastSCP.app"

echo "==> 注销所有已存在的 FastSCP 扩展注册"
pluginkit -mAvvv 2>/dev/null | grep -A1 "$EXT_ID" | grep "Path = " \
    | sed 's/.*Path = //' | while read -r p; do
    echo "    - $p"
    pluginkit -r "$p" 2>/dev/null || true
done
```

注意两处相对原文件的修正：原来用的是 `pluginkit -mDvvv`（只列 D 类记录），这里统一成 `-mAvvv`（全部记录），与脚本末尾的核对命令一致。

- [ ] **Step 2: 在 `install.sh` 末尾核对处加入 LaunchServices 检查**

把文件最后那段 `echo "==> 当前扩展注册（应只有一条，指向 /Applications）"` 及其下一行，替换为：

```bash
echo "==> 当前扩展注册（应只有一条，指向 /Applications）"
pluginkit -mAvvv 2>/dev/null | grep -A1 "$EXT_ID" | grep -E "$EXT_ID|Path = " || echo "    (未注册)"

echo "==> LaunchServices 中的 FastSCP.app 路径（应只有 /Applications 一条）"
"$LSREGISTER" -dump 2>/dev/null | grep -oE '/[^ "]*FastSCP\.app' | sort -u | sed 's/^/    /'
```

- [ ] **Step 3: 让 `execute.sh` 的 Debug 构建不再落进共享 DerivedData**

把 `scripts/execute.sh` 第 21–30 行（`echo "==> 3/4 构建 FastSCP.app（Debug）"` 及其下的 `xcodebuild` 调用）替换为：

```bash
echo "==> 3/4 构建 FastSCP.app（Debug）"
# 用临时 derivedDataPath 并随后删除：留在共享 DerivedData 里的 .app 会被
# LaunchServices 记一条，导致「设置 > 扩展」里多出一行同名 FastSCP。
DEBUG_BUILD_DIR="${TMPDIR:-/tmp}/fastscp-debug-build"
rm -rf "$DEBUG_BUILD_DIR"
xcodebuild \
    -project FastSCP.xcodeproj \
    -scheme FastSCP \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DEBUG_BUILD_DIR" \
    build \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    -quiet
rm -rf "$DEBUG_BUILD_DIR"
```

- [ ] **Step 4: 静态检查两个脚本语法正确**

Run:
```bash
bash -n scripts/install.sh && bash -n scripts/execute.sh && echo "syntax OK"
```
Expected: `syntax OK`。

- [ ] **Step 5: 干跑验证删除闸门只放行预期路径**

Run:
```bash
bash -c '
HOME_SAVE="$HOME"
purge_app_copy() {
    local path="$1"
    case "$path" in
        */FastSCP.app) ;;
        *) echo "SKIP(name): $path"; return ;;
    esac
    case "$path" in
        "$HOME"/Library/Developer/Xcode/DerivedData/*|"$HOME"/Applications/*) ;;
        *) echo "SKIP(scope): $path"; return ;;
    esac
    echo "WOULD-DELETE: $path"
}
purge_app_copy "$HOME/Library/Developer/Xcode/DerivedData/FastSCP-new/Build/Products/Debug/FastSCP.app"
purge_app_copy "$HOME/Applications/FastSCP.app"
purge_app_copy "/Applications/FastSCP.app"
purge_app_copy "$HOME/Documents/important"
purge_app_copy "/"
purge_app_copy "$HOME"
'
```
Expected 恰好是：
```
WOULD-DELETE: <home>/Library/Developer/Xcode/DerivedData/FastSCP-new/Build/Products/Debug/FastSCP.app
WOULD-DELETE: <home>/Applications/FastSCP.app
SKIP(scope): /Applications/FastSCP.app
SKIP(name): <home>/Documents/important
SKIP(name): /
SKIP(name): <home>
```
`/Applications/FastSCP.app` 被 scope 挡下是**正确的** —— 那是安装目标，install.sh 另有 `rm -rf "$APP_DEST"` 专门处理它。

- [ ] **Step 6: Commit**

```bash
git add scripts/install.sh scripts/execute.sh
git commit -m "build: purge competing FastSCP.app copies so Settings shows one row

The duplicate rows in Settings > Extensions come from LaunchServices, not
PluginKit: LS knew 4 FastSCP.app paths (two DerivedData products, ~/Appli-
cations, /Applications) and the pane groups by app. Unregistering alone
does not stick because the .app is still on disk and gets re-indexed, so
install.sh now unregisters and then deletes the stale copies.

Deletion is gated to paths ending in FastSCP.app under DerivedData or
~/Applications. execute.sh builds Debug into a temp derivedDataPath so it
stops creating new ones."
```

---

### Task 6: 验证扩展列表只剩一行

**Files:** 无代码改动 —— 验收关卡。

**Interfaces:**
- Consumes: Task 5 的脚本。
- Produces: 「扩展去重生效」的确认。

**注意：** 本任务会删除 `~/Applications/FastSCP.app`，而它当前是唯一注册了 appex 的副本。清理后扩展指向 `/Applications` 那份，**可能需要在设置里重新勾选一次扩展开关**，Finder 右键菜单才会回来。这是预期行为，已在设计文档中记录。

- [ ] **Step 1: 记录清理前的基线**

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
echo "=== BEFORE: LaunchServices ==="; $LSREG -dump 2>/dev/null | grep -oE '/[^ "]*FastSCP\.app' | sort -u
echo "=== BEFORE: PluginKit ==="; pluginkit -mAvvv 2>/dev/null | grep -A1 "com.zhuzhong.FastSCP.FinderSync" | grep "Path = "
```
预期看到 4 条 LS 路径。记下来以便对比。

- [ ] **Step 2: 跑安装脚本**

```bash
./scripts/install.sh
```
Expected: 脚本末尾打印的两段核对里，LaunchServices 一段**只有 `/Applications/FastSCP.app` 一条**。

- [ ] **Step 3: 独立复核 LaunchServices**

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREG -dump 2>/dev/null | grep -oE '/[^ "]*FastSCP\.app' | sort -u
```
Expected: 恰好一行 `/Applications/FastSCP.app`。

- [ ] **Step 4: 复核 PluginKit**

```bash
pluginkit -mAvvv 2>/dev/null | grep -A1 "com.zhuzhong.FastSCP.FinderSync" | grep "Path = "
```
Expected: 恰好一行，指向 `/Applications/FastSCP.app/Contents/PlugIns/FastSCPFinderSync.appex`。

- [ ] **Step 5: 肉眼确认设置面板**

打开「系统设置 > 登录项与扩展 > 扩展」，找到 FastSCP。

Expected: **只有一行**。若扩展未勾选，勾上它，确认 Finder 右键菜单里 FastSCP 项恢复。

- [ ] **Step 6: 验证再次构建不会引入新行**

```bash
./scripts/execute.sh
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREG -dump 2>/dev/null | grep -oE '/[^ "]*FastSCP\.app' | sort -u
```
Expected: 仍然只有 `/Applications/FastSCP.app` 一条。这是本任务的核心验收点 —— 「重新构建后不再出现重复」。

- [ ] **Step 7: 确认磁盘上无残留构建副本**

```bash
find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 -name "FastSCP.app" -type d 2>/dev/null; ls -d "$HOME/Applications/FastSCP.app" 2>/dev/null; echo "(以上应无输出)"
```
Expected: 除了最后那行提示外无输出。

无 commit —— 纯验证任务。

---

### Task 7: 更新设计文档，记录实现结果

**Files:**
- Modify: `docs/superpowers/specs/2026-08-10-scp-progress-and-extension-dedup-design.md`

**Interfaces:**
- Consumes: Task 1–6 的实际结果。
- Produces: 一份与代码现状一致的文档。

- [ ] **Step 1: 在设计文档末尾追加实现记录**

在 `docs/superpowers/specs/2026-08-10-scp-progress-and-extension-dedup-design.md` 末尾追加：

```markdown
## 实现记录

实现于 2026-08-10，按 `docs/superpowers/plans/2026-08-10-scp-progress-and-extension-dedup.md` 执行。

- 未提交的 rsync 改动已全部 revert，两个 rsync 源文件已删除。
- `SCPCommandBuilder` 加 `-O`，并修正了「macOS scp 忽略 -O」的错误注释。
- `SSHExecutor` 改用 `script -q /dev/null` + 标准 `Process`，删除 forkpty/termios/
  TCP_NODELAY/轮询读线程一整套 C 互操作；取消改为 `proc.terminate()` + 250ms SIGKILL 兜底。
- `install.sh` 新增「消除竞争副本」步骤（先 `lsregister -u` 再 `rm -rf`，删除范围受
  双重闸门限制）；`execute.sh` 的 Debug 构建改用临时 derivedDataPath。

验收结果见 Task 4 与 Task 6：发送/接收进度均平滑推进，取消无残留进程；
LaunchServices 与 PluginKit 各只剩一条记录，重复构建不再新增。
```

若实际执行中有任何偏离计划之处，在此如实补充说明。

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-08-10-scp-progress-and-extension-dedup-design.md
git commit -m "docs: record implementation outcome for scp progress + extension dedup"
```

---

## 自查

**规格覆盖**：设计文档「第一部分」→ Task 1（revert）、Task 2（`-O`）、Task 3（`script` 包装）、Task 4（验证）；「第二部分」→ Task 5（两个脚本）、Task 6（验证）；「已知影响」→ 在 Task 6 开头以注意事项写明。安全红线 → 写入 Global Constraints，并在 Task 1 Step 5 加了 grep 检查。

**占位符**：无 TBD/TODO；每个代码步骤都给出完整可粘贴的代码；每个命令步骤都写明期望输出。

**类型一致性**：`legacyProtocolFlag` 在 Task 2 声明为 `public static let`，Task 3 以 `SCPCommandBuilder.legacyProtocolFlag` 引用，一致。`runWithProgress` 在 Task 3 去掉了 `exec:` 参数，`transfer` 与 `pull` 两个调用点都已同步更新。`waitForExit`、`OutputAccumulator`、`LineScanner`、`SCPProgressParser.parse` 均为基线已有、Task 1 revert 后可用。

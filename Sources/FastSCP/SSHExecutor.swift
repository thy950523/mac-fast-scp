import Foundation
import FastSCPCore

enum SSHError: LocalizedError {
    case listingFailed(alias: String, stderr: String)
    case transferFailed(stderr: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .listingFailed(alias, stderr):
            return "无法列出 \(alias) 的目录\n\(stderr)"
        case let .transferFailed(stderr):
            return "传输失败:\n\(stderr)"
        case .cancelled:
            return "已取消"
        }
    }
}

/// Runs system `ssh`/`scp` via `Process`. The alias is passed directly so
/// `~/.ssh/config` supplies host/user/port/identity/ProxyJump unchanged.
actor SSHExecutor {
    static let shared = SSHExecutor()
    private var runningProcess: Process?
    private var cancelled = false

    /// `ssh <alias> ls -ap <path>` → directory entries (filtered to dirs).
    func listDirectory(alias: String, path: String) async throws -> [RemoteEntry] {
        let result = try await run(exec: "/usr/bin/ssh", args: [alias, "ls", "-ap", path])
        return LsParser.parse(result.stdout).filter(\.isDirectory)
    }

    /// `ssh <alias> ls -apt <path>` → entries (files + directories, unfiltered),
    /// sorted by modification time, newest first (`-t`).
    /// 接收面板用它多选要拉取的源条目。
    func listEntries(alias: String, path: String) async throws -> [RemoteEntry] {
        let result = try await run(exec: "/usr/bin/ssh", args: [alias, "ls", "-apt", path])
        return LsParser.parse(result.stdout)
    }

    /// `scp -r -O <sources> <alias>:<path>`; `progress` receives parsed updates.
    func transfer(alias: String, path: String, sources: [URL],
                  progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        var args = ["-r", SCPCommandBuilder.legacyProtocolFlag]
        args.append(contentsOf: sources.map(\.path))
        let safePath = path.hasSuffix("/") ? path : path + "/"
        args.append("\(alias):\(safePath)")
        try await runWithProgress(args: args, progress: progress)
    }

    /// `scp -r -O <alias>:<remotePath>/<name> ... <localDest>/`；argv 由 `SCPCommandBuilder` 构造。
    func pull(alias: String, remotePath: String, names: [String],
              localDest: URL, progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        let args = SCPCommandBuilder.pullArgs(
            alias: alias, remotePath: remotePath, names: names, localDest: localDest)
        try await runWithProgress(args: args, progress: progress)
    }

    /// Remove existing entries (`rm -rf`) at `<alias>:<path>/<name>` so a send
    /// can overwrite them — scp itself can't open a read-only remote file for
    /// writing. Returns `(success, message)`; `message` carries stderr on failure.
    ///
    /// SAFETY (project baseline, non-negotiable): this may delete ONLY an exact
    /// same-name collision of the current upload, at the destination. The guards
    /// below enforce that scope so a malformed name or a quoting regression can
    /// never broaden the deletion (a past bug deleted an entire home directory).
    func removeRemoteEntries(alias: String, path: String, names: [String]) async -> (success: Bool, message: String) {
        let base = (path.hasSuffix("/") ? String(path.dropLast()) : path).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, base != "/" else {
            return (false, "目标路径无效（\(path)），已拒绝删除。")
        }
        // A deletable name must be a single path component — no `/`, not `.`/`..`.
        let safe = names.filter { RemoteShell.isSafeBasename($0) }
        guard !safe.isEmpty else {
            return (false, "没有可安全删除的同名文件。")
        }
        var quoted: [String] = []
        for name in safe {
            let q = RemoteShell.quote("\(base)/\(name)")
            // Defense-in-depth: a correct quote always embeds the name. If a
            // future regression ever produced an empty/degenerate token, abort
            // rather than risk a bare or over-broad `rm -rf`.
            guard q.contains(name) else {
                DiagLog.log("[ssh] removeRemote ABORTED: quoted path did not embed name name=\(name) q=\(q)")
                return (false, "内部错误：路径转义异常，已中止删除。")
            }
            quoted.append(q)
        }
        var args = [alias, "rm", "-rf"]
        args.append(contentsOf: quoted)
        DiagLog.log("[ssh] removeRemote alias=\(alias) base=\(base) names=\(safe)")
        do {
            let r = try await run(exec: "/usr/bin/ssh", args: args)
            if !r.stderr.isEmpty { DiagLog.log("[ssh] removeRemote stderr=\(r.stderr)") }
            return (true, r.stderr)
        } catch {
            let msg: String
            if case let SSHError.listingFailed(_, stderr) = error { msg = stderr } else { msg = String(describing: error) }
            DiagLog.log("[ssh] removeRemote FAILED \(msg)")
            return (false, msg)
        }
    }

    /// Determine remote total size with a two-tier fallback:
    /// 1. `find ... -printf '%s %f\n'` (GNU find) → per-file sizes (`.full`)
    /// 2. `find ... -type f` (count) + `du -sk` (total) → `.totalsOnly`
    /// 3. neither works → `.unknown` (transfer still runs, progress is indeterminate)
    func probeRemoteSizes(alias: String, remotePath: String, names: [String]) async -> PreparedTransfer {
        let base = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        let paths = names.map { RemoteShell.quote("\(base)/\($0)") }
        if let full = await probeTier1(alias: alias, paths: paths) { return full }
        if let totals = await probeTier2(alias: alias, paths: paths) { return totals }
        return PreparedTransfer(totalBytes: 0, totalFiles: 0, sizeKnowledge: .unknown)
    }

    private func probeTier1(alias: String, paths: [String]) async -> PreparedTransfer? {
        var args = [alias, "find"]
        args.append(contentsOf: paths)
        args.append(contentsOf: ["-type", "f", "-printf", "'%s %f\\n'"])
        do {
            let r = try await run(exec: "/usr/bin/ssh", args: args)
            guard let s = RemoteSizeProbe.parseFindPrintf(r.stdout) else { return nil }
            return PreparedTransfer(totalBytes: s.totalBytes, totalFiles: s.totalFiles,
                                    sizeKnowledge: .full)
        } catch {
            return nil
        }
    }

    private func probeTier2(alias: String, paths: [String]) async -> PreparedTransfer? {
        do {
            var cArgs = [alias, "find"]
            cArgs.append(contentsOf: paths)
            cArgs.append(contentsOf: ["-type", "f"])
            let count = RemoteSizeProbe.parseFindFileCount(
                try await run(exec: "/usr/bin/ssh", args: cArgs).stdout)
            guard count > 0 else { return nil }

            var dArgs = [alias, "du", "-sk"]
            dArgs.append(contentsOf: paths)
            let duOut = try await run(exec: "/usr/bin/ssh", args: dArgs).stdout
            guard let kb = RemoteSizeProbe.parseDuTotalKB(duOut) else { return nil }
            return PreparedTransfer(totalBytes: kb * 1024, totalFiles: count,
                                    sizeKnowledge: .totalsOnly)
        } catch {
            return nil
        }
    }

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

    // MARK: - internals

    /// Wait for `proc` to exit WITHOUT blocking the actor. `Process.waitUntilExit()`
    /// is a synchronous, thread-blocking call; invoking it from an actor method
    /// would monopolize the actor's executor, so a queued `cancel()` could not
    /// run until the process exited on its own — the cancel button looked dead.
    /// `terminationHandler` fires on a background queue and resumes here, leaving
    /// the actor suspended (free to service `cancel()` mid-transfer).
    private func waitForExit(_ proc: Process) async {
        await withCheckedContinuation { continuation in
            proc.terminationHandler = { _ in continuation.resume() }
        }
    }

    private struct ExecResult { let stdout: String; let stderr: String }

    private func run(exec: String, args: [String]) async throws -> ExecResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        runningProcess = proc
        try proc.run()
        await waitForExit(proc)
        runningProcess = nil
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw SSHError.listingFailed(alias: args.first ?? "", stderr: stderr)
        }
        return ExecResult(stdout: String(data: outData, encoding: .utf8) ?? "", stderr: stderr)
    }

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
        //
        // 但 `readabilityHandler = nil` 并不会同步取消已派发的 block，所以退出后的
        // 收尾 drain 可能与某次 handler 回调并发。两边都要 read(2) 同一个 fd：若不
        // 串行化，后到的块可能先被 append，错误信息会乱序、进度行会解析出重复值。
        // 因此把「读 + 累加 + 喂给 LineScanner」整体放到一个串行队列上 —— 读也必须
        // 在队列内，只锁住 append/feed 挡不住两个 read(2) 本身抢跑。
        // 这也顺带保证 LineScanner.feed 永不并发（它在回调期间会放锁）。
        let ioQueue = DispatchQueue(label: "com.zhuzhong.FastSCP.scp-io")
        let handle = output.fileHandleForReading
        handle.readabilityHandler = { fh in
            ioQueue.sync {
                let chunk = fh.availableData
                guard !chunk.isEmpty else { return }
                collected.append(chunk)
                if let text = String(data: chunk, encoding: .utf8) {
                    lineScanner.feed(text)
                }
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

        // 清除 handler 与收尾 drain 都在 ioQueue 上，与 handler 回调互斥排队。
        // （在此之前派发的 block 仍可能排在这次 sync 后面才跑，但那时 fd 已到
        // EOF，读到空 Data 后直接 return，不会再改动 collected。）
        ioQueue.sync {
            handle.readabilityHandler = nil
            // 进程退出与 handler 最后一次回调之间有窗口，把残留数据补读进来。
            // script 是写端唯一持有者（Process 启动后已关掉父进程这一份），进程既已
            // 退出，EOF 必定到达，所以这里读到底比单次 availableData 更完整 ——
            // availableData 只保证一次 read(2)，缓冲里剩下的可能读不干净。
            let tailData = handle.readDataToEndOfFile()
            if !tailData.isEmpty {
                collected.append(tailData)
                if let text = String(data: tailData, encoding: .utf8) {
                    lineScanner.feed(text)
                }
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
        // 注意：nil 不是完成信号。上面的 LineScanner 回调对每一条解析不出进度的行
        // 都会传 nil（传输途中很常见，失败与取消路径同样会传），而调用方
        // TransferTracker.ingest 一律 `guard let ... else { return }` 丢弃 nil。
        // 这一次调用因此是无害的收尾，别当成「只发一次的结束事件」来依赖。
        progress(nil)
    }
}

/// Thread-safe accumulator of the raw output captured from a child process.
private final class OutputAccumulator: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?
            // `script` may emit a leading EOT (0x04) + backspaces artifact.
            .trimmingCharacters(in: CharacterSet.controlCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Splits an incoming byte stream into lines on `\n` or `\r`, emitting each
/// complete line to the callback. Thread-safe.
final class LineScanner: @unchecked Sendable {
    private let callback: @Sendable (String) -> Void
    private var buffer = ""
    private let lock = NSLock()

    init(callback: @Sendable @escaping (String) -> Void) {
        self.callback = callback
    }

    func feed(_ text: String) {
        lock.lock()
        buffer.append(text)
        while let r = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) {
            let line = String(buffer[buffer.startIndex..<r.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            if !line.isEmpty {
                lock.unlock()
                callback(line)
                lock.lock()
            }
        }
        lock.unlock()
    }
}

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
    /// pid of the pty child (scp), when a transfer is running via forkpty.
    private var childPid: pid_t = 0
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

    /// `scp -r <sources> <alias>:<path>`; `progress` receives parsed updates.
/// NOTE: macOS's `/usr/bin/scp` silently ignores the `-O` (legacy protocol)
/// flag — its usage output lists `[-346ABCOpqRrsTv]` but on this build O is
/// not recognized, so we fall back to the default SFTP mode, which emits only
/// 2 progress lines per file (start + end). There is no portable way to get
/// per-block progress from the macOS scp client.
    func transfer(alias: String, path: String, sources: [URL],
                  progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        var args = ["-r"]
        args.append(contentsOf: sources.map(\.path))
        let safePath = path.hasSuffix("/") ? path : path + "/"
        args.append("\(alias):\(safePath)")
        try await runWithProgress(exec: "/usr/bin/scp", args: args, progress: progress)
    }

    /// `scp -r <alias>:<remotePath>/<name> ... <localDest>/`；argv 由 `SCPCommandBuilder` 构造。
    /// See note on `transfer` regarding `-O`.
    func pull(alias: String, remotePath: String, names: [String],
              localDest: URL, progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        let args = SCPCommandBuilder.pullArgs(
            alias: alias, remotePath: remotePath, names: names, localDest: localDest)
        try await runWithProgress(exec: "/usr/bin/scp", args: args, progress: progress)
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
        DiagLog.log("[ssh] cancel() called process=\(runningProcess != nil) childPid=\(childPid)")
        cancelled = true
        if childPid > 0 {
            let pid = childPid
            childPid = 0
            // Send TERM first (clean remote teardown); if the child is still alive
            // 250ms later, force-kill it so the pty closes and the reader resumes.
            _ = kill(pid, SIGTERM)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(250)) {
                if kill(pid, 0) == 0 {
                    DiagLog.log("[ssh] cancel: TERM ignored, sending SIGKILL")
                    _ = kill(pid, SIGKILL)
                }
            }
        }
        runningProcess?.terminate()
        runningProcess = nil
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

    private func runWithProgress(exec: String, args: [String],
                                 progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        cancelled = false
        DiagLog.log("[ssh] exec=\(exec) args=\(args.joined(separator: " "))")

        // scp (OpenSSH ≥9, SFTP mode) emits its progress meter only to a TTY.
        // We previously wrapped scp in `script -q /dev/null`, but `script`
        // block-buffers its stdout when it's a pipe, so progress arrived in
        // multi-second bursts and the bar looked frozen at 0%. Instead we
        // allocate a pty directly with forkpty and exec scp as the session
        // leader: scp sees a controlling terminal (progress flows), and we read
        // the pty master ourselves, so progress bytes arrive in real time. The
        // open master also keeps ssh's stdin from EOF-ing, so it waits for the
        // keychain/agent prompt instead of aborting auth.
        let argv = [exec] + args
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)

        var masterFd: Int32 = -1
        // Configure a proper PTY so scp believes it has a real interactive terminal
        // and emits per-block progress. Two critical settings:
        //   1. ICANON must be OFF: canonical mode buffers input AND output until \n.
        //      scp progress lines end with \r, not \n — with ICANON on, all 162
        //      bytes get held in the kernel PTY buffer until scp exits, then one
        //      read() returns everything at once. We get 2 lines, not per-block.
        //   2. VMIN=1, VTIME=0: read() returns as soon as ≥1 byte is available,
        //      so each progress line arrives in its own read() call.
        //   3. TCP_NODELAY on the underlying socket: prevents Nagle-coalescing
        //      of the small progress writes scp makes between SFTP ACKs.
        var winsize = winsize()
        winsize.ws_row = 24; winsize.ws_col = 200
        var tios = termios()
        // Control: 115200 baud, 8N1, local
        tios.c_cflag = tcflag_t(B115200 | CS8 | CLOCAL | CREAD | HUPCL)
        // Input: non-canonical, no signal chars, VMIN=1 VTIME=0
        tios.c_iflag = tcflag_t(IGNPAR | ICRNL | IXON | IXOFF)
        tios.c_lflag = tcflag_t(0)  // NO ICANON — raw mode for streaming output
        tios.c_oflag = tcflag_t(OPOST | ONLCR)  // map \n→\r\n on output
        tios.c_cc.16 = 1   // VMIN
        tios.c_cc.17 = 0   // VTIME
        var tiosPtr = UnsafeMutablePointer<termios>.allocate(capacity: 1)
        tiosPtr.initialize(to: tios)
        defer { tiosPtr.deinitialize(count: 1); tiosPtr.deallocate() }
        errno = 0
        let pid = forkpty(&masterFd, nil, tiosPtr, &winsize)
        if pid < 0 {
            cArgs.forEach { if let p = $0 { free(p) } }
            throw SSHError.transferFailed(stderr: "无法分配伪终端（forkpty 失败）。")
        }
        // Disable Nagle on the PTY master socket so progress writes are not
        // coalesced between SFTP ACK round-trips.
        var one = Int32(1)
        _ = setsockopt(masterFd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        if pid == 0 {
            // ── child: become scp (only async-signal-safe calls until exec) ──
            _ = close(masterFd)          // child uses the pty slave (0/1/2), not the master
            // Set child as leader of its own process group so scp's
            // getpgrp() == tcgetpgrp() check passes (foreground terminal).
            _ = setpgid(0, 0)
            _ = execvp(exec, &cArgs)
            _exit(127)                   // only reached if exec fails
        }
        // ── parent ──
        // Also setpgid in the parent to avoid race condition where the child
        // execs before we set it here.
        _ = setpgid(pid, pid)
        cArgs.forEach { if let p = $0 { free(p) } }

        let collected = OutputAccumulator()
        let lineScanner = LineScanner { line in progress(SCPProgressParser.parse(line)) }
        childPid = pid
        let master = masterFd   // capture as let for the reader thread

        // Make the PTY master non-blocking: read() returns immediately with EAGAIN
        // if no data is buffered, rather than blocking until 8 KB are accumulated.
        var flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let status: Int32 = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            // Reader thread: non-blocking read() polls for available bytes. With a
            // blocking read, we'd wait for 8 KB or EOF. With O_NONBLOCK + short sleep,
            // we get each progress write as soon as it arrives (typically 40-80 bytes
            // per SFTP ACK round-trip), giving the UI live updates without spinning.
            let reader = Thread {
                var readCalls = 0, totalBytes = 0, feedCalls = 0
                while true {
                    var buf = [UInt8](repeating: 0, count: 4096)
                    let n = read(master, &buf, buf.count)
                    if n > 0 {
                        readCalls += 1; totalBytes += n
                        let chunk = Data(bytes: buf, count: n)
                        collected.append(chunk)
                        if let text = String(data: chunk, encoding: .utf8) {
                            lineScanner.feed(text); feedCalls += 1
                        }
                    } else if n < 0 && errno == EAGAIN {
                        // Nothing buffered right now: sleep briefly so we don't
                        // spin at 100% CPU, then check again. 50 ms feels live.
                        usleep(50_000)
                    } else {
                        // n == 0: EOF (scp closed its write side) or real error.
                        break
                    }
                }
                DiagLog.log("[ssh] pty-summary reads=\(readCalls) bytes=\(totalBytes) feedCalls=\(feedCalls)")
                var st: Int32 = 0; _ = waitpid(pid, &st, 0); _ = close(master)
                cont.resume(returning: st)
            }
            reader.threadPriority = 0.5
            reader.start()
        }

        childPid = 0
        let tail = collected.text
        if cancelled {
            cancelled = false
            DiagLog.log("[ssh] cancelled by user")
            throw SSHError.cancelled
        }
        // wait(2) status layout (BSD): low 7 bits 0 ⇒ normal exit; exit code
        // is bits 8-15. A non-zero signal (cancel) makes this false, but we've
        // already thrown .cancelled above in that case.
        let cleanExit = (status >= 0) && ((status & 0x7f) == 0) && (((status >> 8) & 0xff) == 0)
        if !cleanExit {
            DiagLog.log("[ssh] FAILED status=\(status) output=\(tail)")
            throw SSHError.transferFailed(stderr: tail)
        }
        DiagLog.log("[ssh] OK")
        progress(nil) // signal completion
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

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

    /// `ssh <alias> ls -ap <path>` → entries (files + directories, unfiltered).
    /// 接收面板用它多选要拉取的源条目。
    func listEntries(alias: String, path: String) async throws -> [RemoteEntry] {
        let result = try await run(exec: "/usr/bin/ssh", args: [alias, "ls", "-ap", path])
        return LsParser.parse(result.stdout)
    }

    /// `scp -r <sources> <alias>:<path>`; `progress` receives parsed updates.
    func transfer(alias: String, path: String, sources: [URL],
                  progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        var args = ["-r"]
        args.append(contentsOf: sources.map(\.path))
        let safePath = path.hasSuffix("/") ? path : path + "/"
        args.append("\(alias):\(safePath)")
        try await runWithProgress(exec: "/usr/bin/scp", args: args, progress: progress)
    }

    /// `scp -r <alias>:<remotePath>/<name> ... <localDest>/`；argv 由 `SCPCommandBuilder` 构造。
    func pull(alias: String, remotePath: String, names: [String],
              localDest: URL, progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        let args = SCPCommandBuilder.pullArgs(
            alias: alias, remotePath: remotePath, names: names, localDest: localDest)
        try await runWithProgress(exec: "/usr/bin/scp", args: args, progress: progress)
    }

    /// Determine remote total size with a two-tier fallback:
    /// 1. `find ... -printf '%s %f\n'` (GNU find) → per-file sizes (`.full`)
    /// 2. `find ... -type f` (count) + `du -sk` (total) → `.totalsOnly`
    /// 3. neither works → `.unknown` (transfer still runs, progress is indeterminate)
    func probeRemoteSizes(alias: String, remotePath: String, names: [String]) async -> PreparedTransfer {
        let base = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        let paths = names.map { "'\(base)/\($0)'" }
        if let full = await probeTier1(alias: alias, paths: paths) { return full }
        if let totals = await probeTier2(alias: alias, paths: paths) { return totals }
        return PreparedTransfer(totalBytes: 0, totalFiles: 0, lookup: [:], sizeKnowledge: .unknown)
    }

    private func probeTier1(alias: String, paths: [String]) async -> PreparedTransfer? {
        var args = [alias, "find"]
        args.append(contentsOf: paths)
        args.append(contentsOf: ["-type", "f", "-printf", "'%s %f\\n'"])
        do {
            let r = try await run(exec: "/usr/bin/ssh", args: args)
            guard let s = RemoteSizeProbe.parseFindPrintf(r.stdout) else { return nil }
            return PreparedTransfer(totalBytes: s.totalBytes, totalFiles: s.totalFiles,
                                    lookup: s.lookup, sizeKnowledge: .full)
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
                                    lookup: [:], sizeKnowledge: .totalsOnly)
        } catch {
            return nil
        }
    }

    func cancel() {
        cancelled = true
        runningProcess?.terminate()
        runningProcess = nil
    }

    // MARK: - internals

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
        proc.waitUntilExit()
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
        NSLog("FastSCP[ssh] exec=%@ args=%@", exec, args.joined(separator: " "))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        // Drain stdout so scp never blocks on a full pipe.
        out.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        let lineScanner = LineScanner { line in
            progress(SCPProgressParser.parse(line))
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            lineScanner.feed(text)
        }

        runningProcess = proc
        try proc.run()
        proc.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        runningProcess = nil

        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if cancelled {
            cancelled = false
            throw SSHError.cancelled
        }
        if proc.terminationStatus != 0 {
            throw SSHError.transferFailed(stderr: stderr)
        }
        progress(nil) // signal completion
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

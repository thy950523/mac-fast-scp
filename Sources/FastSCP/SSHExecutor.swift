import Foundation
import FastSCPCore

enum SSHError: LocalizedError {
    case listingFailed(alias: String, stderr: String)
    case transferFailed(stderr: String)

    var errorDescription: String? {
        switch self {
        case let .listingFailed(alias, stderr):
            return "无法列出 \(alias) 的目录\n\(stderr)"
        case let .transferFailed(stderr):
            return "传输失败:\n\(stderr)"
        }
    }
}

/// Runs system `ssh`/`scp` via `Process`. The alias is passed directly so
/// `~/.ssh/config` supplies host/user/port/identity/ProxyJump unchanged.
actor SSHExecutor {
    static let shared = SSHExecutor()
    private var runningProcess: Process?

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

    func cancel() {
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

import Foundation
import Combine
import FastSCPCore

@MainActor
final class TransferTracker: ObservableObject {
    @Published private(set) var progress: TransferProgress
    let direction: TransferDirection

    private let selections: [URL]
    private let remote: (alias: String, path: String, names: [String])?
    private var aggregator: TransferAggregator
    private var prepared = false
    /// Last shown percent we logged, to sample ingest diagnostics.
    private var lastLoggedPct = -2

    /// Send initializer: total size comes from a local scan.
    init(sendSelections selections: [URL]) {
        self.direction = .send
        self.selections = selections
        self.remote = nil
        self.aggregator = TransferAggregator(direction: .send, totalBytes: 0, totalFiles: 0)
        self.progress = aggregator.progress
    }

    /// Receive initializer: total size comes from a remote probe.
    init(receiveAlias alias: String, remotePath: String, names: [String]) {
        self.direction = .receive
        self.selections = []
        self.remote = (alias, remotePath, names)
        self.aggregator = TransferAggregator(direction: .receive, totalBytes: 0, totalFiles: 0)
        self.progress = aggregator.progress
    }

    /// Compute total size (local scan for send, remote probe for receive).
    /// Safe to call multiple times (no-op after the first).
    func prepare() async {
        guard !prepared else { return }
        prepared = true

        let prep: PreparedTransfer
        switch direction {
        case .send:
            let sels = selections
            DiagLog.log("[tracker] prepare send sources=\(sels.map(\.path))")
            let scanned = await Task.detached(priority: .userInitiated) { () -> (PreparedTransfer, [String]) in
                // One-shot readability probe for diagnostics only (never blocks).
                // If these are non-empty, the app can't read its own sources — a
                // macOS TCC situation we want to see in the log.
                let unreadable = sels.filter { !LocalScanner.isReadable($0) }.map(\.path)
                return (LocalScanner.scan(urls: sels), unreadable)
            }.value
            prep = scanned.0
            DiagLog.log("[tracker] prepare send result bytes=\(prep.totalBytes) files=\(prep.totalFiles) knowledge=\(prep.sizeKnowledge) unreadable=\(scanned.1)")
        case .receive:
            guard let r = remote else {
                prep = PreparedTransfer(totalBytes: 0, totalFiles: 0, sizeKnowledge: .unknown)
                break
            }
            prep = await SSHExecutor.shared.probeRemoteSizes(
                alias: r.alias, remotePath: r.path, names: r.names)
        }
        aggregator = TransferAggregator(direction: direction,
                                        totalBytes: prep.totalBytes,
                                        totalFiles: prep.totalFiles,
                                        sizeKnowledge: prep.sizeKnowledge)
        progress = aggregator.progress
    }

    func start() {
        aggregator.startSending()
        progress = aggregator.progress
    }

    /// Feed a parsed scp progress event (from the SSHExecutor callback).
    /// nil means "this output line carried no progress" — common mid-transfer,
    /// and also passed on the failure/cancel paths. It is NOT an end-of-stream
    /// or completion marker; success/failure is driven by the caller via
    /// `complete()` / `fail()`.
    func ingest(_ event: SCPProgress?) {
        guard let p = event else { return }
        aggregator.ingest(ParsedProgress(percent: Double(p.percent) / 100.0,
                                         transferredBytes: p.fileTransferredBytes,
                                         fileName: p.fileName,
                                         rateBytesPerSec: p.rateBytesPerSec))
        progress = aggregator.progress
        // Sample by whole-percent change so a transfer logs a handful of lines,
        // not hundreds. Localizes whether progress events reach the tracker and
        // what percent they compute to.
        let shown = Int(progress.percent * 100)
        if shown != lastLoggedPct {
            lastLoggedPct = shown
            DiagLog.log("[tracker] ingest scp=\(p.percent)% xfbytes=\(p.fileTransferredBytes.map(String.init) ?? "nil") name=\(p.fileName ?? "nil") -> completed=\(progress.completedBytes)/\(progress.totalBytes) shown=\(shown)%")
        }
    }

    func complete() {
        aggregator.complete()
        progress = aggregator.progress
    }

    func fail(_ message: String) {
        aggregator.fail(message)
        progress = aggregator.progress
    }
}

/// Recursively measures local files for a send.
private enum LocalScanner {
    static func scan(urls: [URL]) -> PreparedTransfer {
        var total: Int64 = 0
        var count = 0
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey,
                                      .isSymbolicLinkKey, .fileSizeKey]
        for root in urls {
            // `FileManager.enumerator(at:)` yields nothing for a FILE url (it
            // only enumerates directory contents), so measure files directly.
            if !root.hasDirectoryPath {
                if let size = fileSize(root) {
                    total += size
                    count += 1
                }
                continue
            }
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles]) {
                for case let url as URL in e {
                    let rv = try? url.resourceValues(forKeys: Set(keys))
                    if rv?.isSymbolicLink == true || rv?.isDirectory == true { continue }
                    total += Int64(rv?.fileSize ?? 0)
                    count += 1
                }
            }
        }
        return PreparedTransfer(totalBytes: total, totalFiles: count, sizeKnowledge: .full)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let rv = try? url.resourceValues(forKeys: keys),
              rv.isRegularFile == true else { return nil }
        return Int64(rv.fileSize ?? 0)
    }

    /// True if the URL can actually be read right now (open+read for files,
    /// list for directories). POSIX `access()` can report OK while macOS TCC
    /// still blocks the real read, so this performs a real probe. Diagnostics
    /// only — it never blocks or waits for a permission dialog.
    static func isReadable(_ url: URL) -> Bool {
        let path = url.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        let peek = try? handle.read(upToCount: 1)
        try? handle.close()
        return peek != nil
    }
}

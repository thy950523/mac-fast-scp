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
            prep = await Task.detached(priority: .userInitiated) {
                LocalScanner.scan(urls: sels)
            }.value
        case .receive:
            guard let r = remote else {
                prep = PreparedTransfer(totalBytes: 0, totalFiles: 0, lookup: [:], sizeKnowledge: .unknown)
                break
            }
            prep = await SSHExecutor.shared.probeRemoteSizes(
                alias: r.alias, remotePath: r.path, names: r.names)
        }
        aggregator = TransferAggregator(direction: direction,
                                        totalBytes: prep.totalBytes,
                                        totalFiles: prep.totalFiles,
                                        fileSizeLookup: prep.lookup,
                                        sizeKnowledge: prep.sizeKnowledge)
        progress = aggregator.progress
    }

    func start() {
        aggregator.startSending()
        progress = aggregator.progress
    }

    /// Feed a parsed scp progress event (from the SSHExecutor callback).
    /// A nil event is the end-of-stream marker; definitive success/failure is
    /// driven by the caller via `complete()` / `fail()`.
    func ingest(_ event: SCPProgress?) {
        guard let p = event else { return }
        aggregator.ingest(ParsedProgress(percent: Double(p.percent) / 100.0,
                                         fileName: p.fileName,
                                         rateBytesPerSec: p.rateBytesPerSec))
        progress = aggregator.progress
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
        var lookup: [String: Int64] = [:]
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey,
                                      .isSymbolicLinkKey, .fileSizeKey]
        for root in urls {
            let rootURL = root.hasDirectoryPath ? root : root.deletingLastPathComponent()
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles]) {
                for case let url as URL in e {
                    let rv = try? url.resourceValues(forKeys: Set(keys))
                    if rv?.isSymbolicLink == true || rv?.isDirectory == true { continue }
                    let size = Int64(rv?.fileSize ?? 0)
                    total += size
                    count += 1
                    // Key by basename and by path relative to the selection root;
                    // scp prints the relative path for files inside a recursive
                    // directory, and just the basename for top-level files.
                    lookup[url.lastPathComponent] = size
                    if let rel = relativePath(url, from: rootURL) {
                        lookup[rel] = size
                    }
                }
            }
        }
        return PreparedTransfer(totalBytes: total, totalFiles: count,
                                lookup: lookup, sizeKnowledge: .full)
    }

    private static func relativePath(_ url: URL, from root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        var rel = String(filePath.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? nil : rel
    }
}

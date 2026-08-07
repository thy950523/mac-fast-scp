import Foundation

/// Output of a successful remote size probe.
public struct RemoteSize: Equatable, Sendable {
    public var totalBytes: Int64
    public var totalFiles: Int
    public var lookup: [String: Int64]
    public init(totalBytes: Int64, totalFiles: Int, lookup: [String: Int64]) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.lookup = lookup
    }
}

public enum RemoteSizeProbe {
    /// Parses `find ... -type f -printf '%s %f\n'` output.
    /// Each line: "<size> <basename>". Returns nil if no valid line.
    public static func parseFindPrintf(_ output: String) -> RemoteSize? {
        var total: Int64 = 0
        var count = 0
        var lookup: [String: Int64] = [:]
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let size = Int64(parts[0]) else { continue }
            let name = String(parts[1])
            total += size
            count += 1
            lookup[name] = size
        }
        guard count > 0 else { return nil }
        return RemoteSize(totalBytes: total, totalFiles: count, lookup: lookup)
    }

    /// Counts non-empty lines from `find ... -type f`.
    public static func parseFindFileCount(_ output: String) -> Int {
        output.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// Parses `du -sk` total in KB. For multiple paths, takes the last numeric
    /// line (the "total" summary both GNU `-c` and BSD print).
    public static func parseDuTotalKB(_ output: String) -> Int64? {
        var last: Int64?
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let first = line.split(separator: "\t").first
                ?? line.split(separator: " ").first
            if let s = first, let kb = Int64(s) { last = kb }
        }
        return last
    }
}

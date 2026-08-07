import Foundation

/// Output of a successful remote size probe.
public struct RemoteSize: Equatable, Sendable {
    public var totalBytes: Int64
    public var totalFiles: Int
    public init(totalBytes: Int64, totalFiles: Int) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
    }
}

public enum RemoteSizeProbe {
    /// Parses `find ... -type f -printf '%s %f\n'` output for total bytes and
    /// file count. Each line: "<size> <basename>". Returns nil if no valid line.
    public static func parseFindPrintf(_ output: String) -> RemoteSize? {
        var total: Int64 = 0
        var count = 0
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let size = Int64(parts[0]) else { continue }
            total += size
            count += 1
        }
        guard count > 0 else { return nil }
        return RemoteSize(totalBytes: total, totalFiles: count)
    }

    /// Counts non-empty lines from `find ... -type f`.
    public static func parseFindFileCount(_ output: String) -> Int {
        output.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// Sums the KB columns of `du -sk` output. Called without `-c`, so both
    /// GNU and BSD `du` print one line per selected path (no total line);
    /// summing them yields the correct grand total on both platforms.
    public static func parseDuTotalKB(_ output: String) -> Int64? {
        var sum: Int64 = 0
        var found = false
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let first = line.split(separator: "\t").first
                ?? line.split(separator: " ").first
            if let s = first, let kb = Int64(s) { sum += kb; found = true }
        }
        return found ? sum : nil
    }
}

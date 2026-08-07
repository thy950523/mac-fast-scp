import Foundation

public struct SCPProgress: Equatable, Sendable {
    public let percent: Int
    public let fileName: String?
    /// Bytes transferred for the file currently in flight (from the size field
    /// of scp's progress line), not the total.
    public let fileTransferredBytes: Int64?
    public let rateBytesPerSec: Int64?
    public let detail: String

    public init(percent: Int, fileName: String?, fileTransferredBytes: Int64?,
                rateBytesPerSec: Int64?, detail: String) {
        self.percent = percent
        self.fileName = fileName
        self.fileTransferredBytes = fileTransferredBytes
        self.rateBytesPerSec = rateBytesPerSec
        self.detail = detail
    }
}

public enum SCPProgressParser {
    /// Best-effort parse of an OpenSSH `scp` progress line:
    /// "\r<name><spaces>NNN% <transferred> <rate> <eta>".
    /// Returns nil if the line carries no percent at all.
    public static func parse(_ line: String) -> SCPProgress? {
        // Strip a leading CR and any control chars (e.g. the EOT/backspace
        // artifact that `script` emits before the first progress line).
        let stripped = line
            .drop(while: { $0 == "\r" || $0.isNewline })
            .trimmingPrefix { $0.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) } }
        let s = String(stripped)
        guard let r = s.range(of: #"\b\d{1,3}%"#, options: .regularExpression) else {
            return nil
        }
        let numberText = String(s[r].dropLast())
        guard let pct = Int(numberText), (0...100).contains(pct) else { return nil }

        let fileName = String(s[..<r.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = String(s[r.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SCPProgress(
            percent: pct,
            fileName: fileName.isEmpty ? nil : fileName,
            fileTransferredBytes: parseTransferredBytes(from: detail),
            rateBytesPerSec: parseRate(from: detail),
            detail: detail
        )
    }

    /// The first whitespace-delimited token after the percent is the current
    /// file's transferred size (`450MB`, `12KB`, `0`).
    static func parseTransferredBytes(from detail: String) -> Int64? {
        guard let first = detail.split(separator: " ").first else { return nil }
        return ByteFormat.parseSize(String(first))
    }

    /// Parse "12.3MB/s", "456KB/s", "1.2GB/s" into bytes/second. Returns nil if absent.
    static func parseRate(from detail: String) -> Int64? {
        guard let r = detail.range(of: #"(\d+(?:\.\d+)?)\s*(K|M|G)?B/s"#, options: .regularExpression)
        else { return nil }
        let token = detail[r]
        var chars: [Character] = []
        var unit: Character = "B"
        for c in token {
            if c.isNumber || c == "." {
                chars.append(c)
            } else if c == "K" || c == "M" || c == "G" {
                unit = c
                break
            } else if !chars.isEmpty {
                break
            }
        }
        guard let n = Double(String(chars)), n >= 0 else { return nil }
        let mult: Double
        switch unit {
        case "K": mult = 1024
        case "M": mult = 1024 * 1024
        case "G": mult = 1024 * 1024 * 1024
        default:  mult = 1
        }
        return Int64(n * mult)
    }
}

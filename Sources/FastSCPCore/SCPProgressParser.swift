import Foundation

public struct SCPProgress: Equatable, Sendable {
    public let percent: Int
    public let detail: String
    public init(percent: Int, detail: String) {
        self.percent = percent
        self.detail = detail
    }
}

public enum SCPProgressParser {
    /// Best-effort parse of an OpenSSH `scp` stderr progress line:
    /// "<name><spaces>NNN%<size> <rate> <eta>".
    public static func parse(_ line: String) -> SCPProgress? {
        guard let range = line.range(of: #"\b\d{1,3}%"#, options: .regularExpression) else { return nil }
        let numberText = String(line[range].dropLast())  // strip trailing '%'
        guard let pct = Int(numberText), (0...100).contains(pct) else { return nil }
        let detail = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return SCPProgress(percent: pct, detail: detail)
    }
}

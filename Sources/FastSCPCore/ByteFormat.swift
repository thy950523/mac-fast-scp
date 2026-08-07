import Foundation

public enum ByteFormat {
    public static func size(_ bytes: Int64) -> String {
        let b = max(bytes, 0)
        if b < 1024 { return "\(b) B" }
        let kb = Double(b) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    public static func rate(_ bytesPerSec: Int64) -> String {
        size(bytesPerSec) + "/s"
    }

    /// Parse an scp size token such as `450MB`, `12KB`, `1.2GB`, or a plain
    /// byte count. Returns nil for non-numeric input. Units are powers of 1024.
    public static func parseSize(_ token: String) -> Int64? {
        let t = token.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // Scan the leading numeric portion (digits + optional dot).
        var num = ""
        var unit = ""
        for c in t {
            if c.isNumber || c == "." {
                num.append(c)
            } else {
                unit.append(c)
            }
        }
        guard let n = Double(num) else { return nil }
        let mult: Double
        switch unit.uppercased() {
        case "K", "KB": mult = 1024
        case "M", "MB": mult = 1024 * 1024
        case "G", "GB": mult = 1024 * 1024 * 1024
        case "T", "TB": mult = 1024.0 * 1024 * 1024 * 1024
        case "", "B":  mult = 1
        default:       return nil
        }
        return Int64(n * mult)
    }
}

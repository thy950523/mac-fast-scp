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
}

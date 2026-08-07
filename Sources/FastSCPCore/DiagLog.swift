import Foundation

/// Minimal file-based diagnostic logger. Writes to the shared app-group
/// container so the sandboxed Finder extension and the unsandboxed app can both
/// be traced reliably (the unified log drops/defers these NSLog messages).
/// Temporary instrumentation — remove once receive bugs are resolved.
public enum DiagLog {
    private static let lock = NSLock()

    private static var url: URL {
        SharedPaths.sharedDir.appendingPathComponent("debug.log")
    }

    public static func log(_ message: String) {
        let line = "\(Date().ISO8601Format()) \(message)\n"
        lock.lock(); defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        let u = url
        try? FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: u.path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: u)
        }
    }
}

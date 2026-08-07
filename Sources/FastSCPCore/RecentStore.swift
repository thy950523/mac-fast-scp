import Foundation

/// Reads/writes recent destinations from a single JSON file whose location
/// resolves to the same on-disk path whether the caller is the sandboxed
/// extension (home-relative) or the unsandboxed app (absolute container path).
public final class RecentStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Resolve the store path for the current process context via `SharedPaths`.
    public static var defaultURL: URL { SharedPaths.recentURL }

    /// 发送方向（本地 → 远端）的最近服务器。
    public static func shared() -> RecentStore {
        RecentStore(fileURL: SharedPaths.recentURL)
    }

    /// 接收方向（远端 → 本地）的最近服务器，与发送完全独立。
    public static func sharedReceive() -> RecentStore {
        RecentStore(fileURL: SharedPaths.recentReceiveURL)
    }

    public func load() -> [RecentDestination] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoded = (try? JSONDecoder().decode([RecentDestination].self, from: data)) ?? []
        return RecentDestinations.normalize(decoded)
    }

    public func save(_ destinations: [RecentDestination]) {
        lock.lock(); defer { lock.unlock() }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(destinations) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func record(_ entry: RecentDestination) {
        let updated = RecentDestinations.add(load(), entry)
        save(updated)
    }
}

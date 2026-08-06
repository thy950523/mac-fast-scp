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

    public static func shared() -> RecentStore {
        RecentStore(fileURL: defaultURL)
    }

    public func load() -> [RecentDestination] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([RecentDestination].self, from: data)) ?? []
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

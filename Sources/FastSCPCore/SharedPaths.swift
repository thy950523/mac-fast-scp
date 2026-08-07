import Foundation

/// Resolves a directory that both the sandboxed Finder extension and the
/// unsandboxed app can reach as the same on-disk path.
///
/// - Extension (sandboxed) sees: `~/Library/Application Support/FastSCP/`
///   which maps to `<ext-container>/Data/Library/Application Support/FastSCP/`.
/// - App (unsandboxed) reaches the same files via the absolute container path.
public enum SharedPaths {
    public static var sharedDir: URL {
        let isExtension = Bundle.main.bundleIdentifier == FastSCPConfig.extensionBundleID
        if isExtension {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return appSupport.appendingPathComponent("FastSCP", isDirectory: true)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent(
                "Library/Containers/\(FastSCPConfig.extensionBundleID)/Data/Library/Application Support/FastSCP",
                isDirectory: true
            )
        }
    }

    /// 发送（本地 → 远端）的最近服务器。
    public static var recentURL: URL { sharedDir.appendingPathComponent("recent.json") }
    /// 接收（远端 → 本地）的最近服务器，与发送独立统计。
    public static var recentReceiveURL: URL { sharedDir.appendingPathComponent("recent-receive.json") }
    public static func batchURL(token: String) -> URL { sharedDir.appendingPathComponent("batch-\(token).txt") }
}

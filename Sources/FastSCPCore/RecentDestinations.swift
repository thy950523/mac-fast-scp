import Foundation

/// 「最近」列表按服务器（alias）去重：每台服务器只保留最近一次使用的路径，
/// 最多保留 `FastSCPConfig.maxRecentDestinations` 台，最近使用的排在最前。
public enum RecentDestinations {
    public static func add(_ existing: [RecentDestination], _ entry: RecentDestination) -> [RecentDestination] {
        var filtered = existing.filter { $0.alias != entry.alias }
        filtered.insert(entry, at: 0)
        return Array(filtered.prefix(FastSCPConfig.maxRecentDestinations))
    }

    /// 读取磁盘数据时统一规范化：按时间倒序、按 alias 去重、截断到上限。
    /// 这样即使旧文件里存着乱序/超量/同机多路径的数据，展示顺序也一定正确。
    public static func normalize(_ list: [RecentDestination]) -> [RecentDestination] {
        var seen = Set<String>()
        var out: [RecentDestination] = []
        for item in list.sorted(by: { $0.timestamp > $1.timestamp }) {
            guard !seen.contains(item.alias) else { continue }
            seen.insert(item.alias)
            out.append(item)
            if out.count == FastSCPConfig.maxRecentDestinations { break }
        }
        return out
    }
}

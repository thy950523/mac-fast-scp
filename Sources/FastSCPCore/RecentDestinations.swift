import Foundation

public enum RecentDestinations {
    public static func add(_ existing: [RecentDestination], _ entry: RecentDestination) -> [RecentDestination] {
        var filtered = existing.filter { $0.id != entry.id }
        filtered.insert(entry, at: 0)
        return Array(filtered.prefix(FastSCPConfig.maxRecentDestinations))
    }
}

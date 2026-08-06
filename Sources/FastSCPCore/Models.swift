import Foundation

public struct SSHHost: Equatable, Identifiable, Sendable {
    public let id: String
    public let alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?

    public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil) {
        self.id = alias
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
    }
}

public struct RemoteEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isDirectory: Bool
    public init(name: String, isDirectory: Bool) {
        self.id = name
        self.name = name
        self.isDirectory = isDirectory
    }
}

public struct RecentDestination: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(alias)|\(remotePath)" }
    public let alias: String
    public let remotePath: String
    public let timestamp: Date
    public init(alias: String, remotePath: String, timestamp: Date) {
        self.alias = alias
        self.remotePath = remotePath
        self.timestamp = timestamp
    }
}

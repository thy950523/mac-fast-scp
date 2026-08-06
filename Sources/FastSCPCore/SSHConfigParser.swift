import Foundation

public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var current: SSHHost?
        let lines = text.components(separatedBy: .newlines)

        func flush() {
            if let host = current { hosts.append(host) }
            current = nil
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard let key = parts.first?.lowercased() else { continue }
            let values = Array(parts.dropFirst())

            if key == "host" {
                flush()
                let aliases = values
                let hasWildcard = aliases.contains { $0.contains("*") || $0.contains("?") }
                if hasWildcard || aliases.isEmpty { continue }
                current = SSHHost(alias: aliases[0])
            } else if var host = current, let value = values.first {
                switch key {
                case "hostname": host.hostName = value
                case "user": host.user = value
                case "port": host.port = Int(value)
                default: break
                }
                current = host
            }
        }
        flush()
        return hosts
    }
}

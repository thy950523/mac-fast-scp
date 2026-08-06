import Foundation

public enum LsParser {
    public static func parse(_ output: String) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        for raw in output.components(separatedBy: .newlines) {
            var name = raw
            guard !name.isEmpty else { continue }
            let isDir = name.hasSuffix("/")
            if isDir { name.removeLast() }
            if name == "." || name == ".." { continue }
            entries.append(RemoteEntry(name: name, isDirectory: isDir))
        }
        return entries
    }
}

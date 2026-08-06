import Foundation
import FastSCPCore

/// Reads the selection-batch file written by the Finder Sync extension.
enum SelectionStore {
    static func read(token: String) -> [URL] {
        let url = SharedPaths.batchURL(token: token)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        try? FileManager.default.removeItem(at: url)
        return text.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }
}

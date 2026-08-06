import AppKit
import Foundation
import FastSCPCore

enum ExtensionStatus {
    case loaded
    case notLoaded
    case unknown

    var isEnabled: Bool {
        if case .loaded = self { return true }
        return false
    }
}

enum ExtensionChecker {
    /// Uses `pluginkit` to check whether the Finder Sync extension is loaded.
    /// A `+` prefix in the matching line means Finder has loaded it.
    static func check() -> ExtensionStatus {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        proc.arguments = ["-m", "-v"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return .unknown
        }
        // Read BEFORE waitUntilExit to avoid pipe-buffer deadlock
        // (pluginkit -v output is large enough to fill the pipe).
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let output = String(data: outData, encoding: .utf8) ?? ""
        for line in output.components(separatedBy: .newlines) {
            if line.contains(FastSCPConfig.extensionBundleID) {
                return line.hasPrefix("+") ? .loaded : .notLoaded
            }
        }
        return .notLoaded
    }

    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Extensions",
        ]
        for s in urls {
            if let url = URL(string: s),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference") {
            NSWorkspace.shared.open(url)
        }
    }
}

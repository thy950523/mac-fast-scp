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
    /// Uses `pluginkit` to check whether *our own* Finder Sync extension is loaded.
    ///
    /// Matching on bundle ID alone is not enough: development builds leave stale
    /// registrations for the same bundle ID at other paths (DerivedData, /tmp,
    /// an older /Applications copy). Those extra entries show up as duplicate
    /// rows in System Settings > Extensions, and a `-` on any of them used to
    /// make us report "未启用" even when the installed copy was fine. So we ask
    /// pluginkit for full records and only trust the one whose path lives inside
    /// *this* app bundle.
    static func check() -> ExtensionStatus {
        guard let records = pluginkitRecords() else { return .unknown }
        let ourAppPath = Bundle.main.bundlePath
        for record in records where record.bundleID == FastSCPConfig.extensionBundleID {
            if record.path.hasPrefix(ourAppPath + "/") {
                return record.enabled ? .loaded : .notLoaded
            }
        }
        // Either nothing registered, or only stale copies at other paths — the
        // extension inside the app the user is actually running is not active.
        return .notLoaded
    }

    /// Stale registrations of our extension at paths outside this app bundle.
    /// These are the duplicate rows in System Settings > Extensions.
    static func staleRegistrationPaths() -> [String] {
        guard let records = pluginkitRecords() else { return [] }
        let ourAppPath = Bundle.main.bundlePath
        return records
            .filter { $0.bundleID == FastSCPConfig.extensionBundleID }
            .map(\.path)
            .filter { !$0.hasPrefix(ourAppPath + "/") }
    }

    /// Ask pluginkit to forget stale registrations so System Settings shows a
    /// single row. Returns the paths it attempted to remove.
    @discardableResult
    static func pruneStaleRegistrations() -> [String] {
        let stale = staleRegistrationPaths()
        for path in stale {
            run("/usr/bin/pluginkit", ["-r", path])
            DiagLog.log("[app] pruned stale extension registration: \(path)")
        }
        let lsStale = pruneStaleLaunchServicesEntries()
        return stale + lsStale
    }

    /// PluginKit 不是重复行的唯一来源。
    ///
    /// 「设置 > 登录项与扩展 > 扩展」按 **App** 分组，分组信息来自
    /// LaunchServices；而 LaunchServices 会记住每一个它见过的 FastSCP.app 路径
    /// （旧的构建产物目录、被删掉的副本……），即使那些目录早就不存在了，
    /// 仍会各占一行。所以必须把 LS 里指向别处的 FastSCP.app 也注销掉。
    @discardableResult
    static func pruneStaleLaunchServicesEntries() -> [String] {
        let ourAppPath = Bundle.main.bundlePath
        let stale = launchServicesAppPaths().filter { $0 != ourAppPath }
        for path in stale {
            run(lsregisterPath, ["-u", path])
            DiagLog.log("[app] pruned stale LaunchServices entry: \(path)")
        }
        if !stale.isEmpty {
            // 重新登记本体，确保清理过程没有连带影响到我们自己。
            run(lsregisterPath, ["-f", ourAppPath])
        }
        return stale
    }

    private static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// 从 `lsregister -dump` 中抽出所有 `…/FastSCP.app` 路径（不含内嵌 appex）。
    private static func launchServicesAppPaths() -> [String] {
        guard let dump = capture(lsregisterPath, ["-dump"]) else { return [] }
        let appName = (Bundle.main.bundlePath as NSString).lastPathComponent  // "FastSCP.app"
        var found = Set<String>()
        for line in dump.components(separatedBy: .newlines) {
            guard line.contains(appName) else { continue }
            // dump 行形如 `path:  /Applications/FastSCP.app` 等多种格式，
            // 这里扫描出以 / 开头、以 appName 结尾的绝对路径片段。
            for token in line.components(separatedBy: .whitespaces) {
                let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"(),"))
                guard t.hasPrefix("/"), t.hasSuffix("/" + appName) || t.hasSuffix(appName),
                      !t.contains(".appex") else { continue }
                // 只取 .app 结尾的那一段，忽略 bundle 内部的更深路径。
                if t.hasSuffix(appName) { found.insert(t) }
            }
        }
        return Array(found)
    }

    // MARK: - process helpers

    private static func run(_ tool: String, _ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func capture(_ tool: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        // Read BEFORE waitUntilExit — these dumps are far larger than the pipe buffer.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - pluginkit parsing

    private struct Record {
        let bundleID: String
        let path: String
        let enabled: Bool
    }

    /// Parse `pluginkit -mAvvv` output. Records look like:
    ///
    ///     +    com.zhuzhong.FastSCP.FinderSync(0.1.0)
    ///              Path = /Applications/FastSCP.app/Contents/PlugIns/...appex
    ///
    /// A leading `+` means enabled, `-` means explicitly disabled.
    private static func pluginkitRecords() -> [Record]? {
        guard let output = capture("/usr/bin/pluginkit", ["-mAvvv"]) else { return nil }

        var records: [Record] = []
        var pendingID: String?
        var pendingEnabled = false
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "Path = ") {
                if let id = pendingID {
                    records.append(Record(bundleID: id,
                                          path: String(trimmed[range.upperBound...]),
                                          enabled: pendingEnabled))
                    pendingID = nil
                }
                continue
            }
            // Header line: optional +/- flag, then `bundle.id(version)`.
            var head = trimmed
            var enabled = true
            if head.hasPrefix("+") {
                head.removeFirst()
            } else if head.hasPrefix("-") {
                enabled = false
                head.removeFirst()
            }
            head = head.trimmingCharacters(in: .whitespaces)
            guard let paren = head.firstIndex(of: "(") else { continue }
            pendingID = String(head[head.startIndex..<paren])
            pendingEnabled = enabled
        }
        return records
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

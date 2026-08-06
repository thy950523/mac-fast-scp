# FastSCP Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
>
> **Commit policy:** This plan shows commit steps as prescribed by TDD workflow. Per this repo's global rule, **do NOT actually run `git commit` unless the user explicitly asks.** Surface each checkpoint and let the user say "commit" (or batch at the end).

**Goal:** A macOS tool that adds a Finder right-click menu to SCP selected files/folders to an SSH server destination, with one-click "send to last target" and a small destination-picker panel.

**Architecture:** Two-process macOS app. `FastSCPFinderSync` (sandboxed Finder Sync extension) provides the Finder right-click menu, captures selected paths, and hands them to `FastSCP` (unsandboxed agent app, `LSUIElement`, no Dock icon) via a custom `fastscp://` URL scheme. The agent app owns all UI and shells out to system `ssh`/`scp` (inheriting `~/.ssh/config` 1:1). Pure logic (config parsing, list parsing, progress parsing, recent-destination logic) lives in a `FastSCPCore` framework shared by both processes and fully unit-tested.

**Tech Stack:** Swift 6, SwiftUI, AppKit (NSPanel), Finder Sync (`FIFinderSync`), xcodegen (project generation), XCTest.

**Bundle IDs / constants:**
- App: `com.zhuzhong.FastSCP`
- Extension: `com.zhuzhong.FastSCP.FinderSync`
- Framework: `com.zhuzhong.FastSCP.Core`
- App Group: `group.com.zhuzhong.FastSCP`
- URL scheme: `fastscp`
- Deployment target: macOS 14.0

---

## Task 0: Project scaffold (xcodegen)

**Files:**
- Create: `project.yml`
- Create: `Sources/FastSCP/Info.plist`, `Sources/FastSCP/FastSCP.entitlements`
- Create: `Sources/FastSCPFinderSync/Info.plist`, `Sources/FastSCPFinderSync/FastSCPFinderSync.entitlements`
- Create: `Sources/FastSCPCore/.gitkeep`, `Sources/FastSCP/.gitkeep`, `Sources/FastSCPFinderSync/.gitkeep`, `Tests/FastSCPCoreTests/.gitkeep`
- Create: `.gitignore`

**Step 1: Write `project.yml`**

```yaml
name: FastSCP
options:
  bundleIdPrefix: com.zhuzhong
  deploymentTarget:
    macOS: "14.0"
  groupSortPosition: top
targets:
  FastSCPCore:
    type: framework
    platform: macOS
    sources:
      - path: Sources/FastSCPCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.zhuzhong.FastSCP.Core
        ENABLE_TESTABILITY: YES
        SWIFT_VERSION: "6.0"
  FastSCP:
    type: application
    platform: macOS
    sources:
      - path: Sources/FastSCP
    dependencies:
      - target: FastSCPCore
        embed: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.zhuzhong.FastSCP
        CODE_SIGN_ENTITLEMENTS: Sources/FastSCP/FastSCP.entitlements
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: YES
        SWIFT_VERSION: "6.0"
    info:
      path: Sources/FastSCP/Info.plist
      properties:
        CFBundleDisplayName: FastSCP
        CFBundleShortVersionString: "0.1.0"
        LSUIElement: true
        LSMinimumSystemVersion: "14.0"
        CFBundleURLTypes:
          - CFBundleURLName: com.zhuzhong.FastSCP
            CFBundleURLSchemes: [fastscp]
        NSHumanReadableCopyright: ""
  FastSCPFinderSync:
    type: app-extension
    platform: macOS
    sources:
      - path: Sources/FastSCPFinderSync
    dependencies:
      - target: FastSCPCore
        embed: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.zhuzhong.FastSCP.FinderSync
        CODE_SIGN_ENTITLEMENTS: Sources/FastSCPFinderSync/FastSCPFinderSync.entitlements
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: YES
        SWIFT_VERSION: "6.0"
    info:
      path: Sources/FastSCPFinderSync/Info.plist
      properties:
        CFBundleDisplayName: FastSCP Finder Extension
        NSExtension:
          NSExtensionPointIdentifier: com.apple.FinderSync
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).FinderSync
  FastSCPCoreTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests/FastSCPCoreTests
    dependencies:
      - target: FastSCPCore
```

**Step 2: Write entitlements**

`Sources/FastSCP/FastSCP.entitlements` — main app is **unsandboxed** (sandbox forbids spawning `ssh`/`scp`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.zhuzhong.FastSCP</string>
    </array>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

`Sources/FastSCPFinderSync/FastSCPFinderSync.entitlements` — extension is sandboxed (mandatory) with the shared app group:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.zhuzhong.FastSCP</string>
    </array>
</dict>
</plist>
```

**Step 3: Write `.gitignore`**
```
build/
DerivedData/
*.xcodeproj/
.fastscp/
```
(Keep `.xcodeproj/` ignored — it's regenerated from `project.yml` via xcodegen. The source of truth is `project.yml` + `Sources/`.)

**Step 4: Add minimal placeholders so targets compile**

`Sources/FastSCPCore/Placeholder.swift`:
```swift
public enum FastSCPCorePlaceholder {}
```

`Sources/FastSCP/Main.swift` (placeholder; replaced in Task 8):
```swift
import SwiftUI

@main
struct FastSCPApp {
    static func main() {
        print("FastSCP placeholder")
    }
}
```

`Sources/FastSCPFinderSync/FinderSync.swift` (placeholder; replaced in Task 10):
```swift
import Cocoa
import FinderSync

class FinderSync: NSObject, FIFinderSync {
    override init() {
        super.init()
    }
}
```

**Step 5: Generate project and build**

Run:
```bash
xcodegen generate
xcodebuild -project FastSCP.xcodeproj -scheme FastSCP -configuration Debug build 2>&1 | tail -30
xcodebuild -project FastSCP.xcodeproj -scheme FastSCPFinderSync -configuration Debug build 2>&1 | tail -30
```
Expected: both build with `BUILD SUCCEEDED`.

> **Local-signing note:** App Groups may need a real provisioning profile on some machines. If `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil` at runtime, fall back to writing recent data into the extension's container dir from the unsandboxed app (see Task 6 fallback). The plan uses App Group as primary.

**Step 6: Checkpoint** — surface to user for commit.

---

## Task 1: Shared constants & models

**Files:**
- Create: `Sources/FastSCPCore/Constants.swift`
- Create: `Sources/FastSCPCore/Models.swift`

**Step 1: Write `Constants.swift`**
```swift
import Foundation

public enum FastSCPConfig {
    public static let urlScheme = "fastscp"
    public static let appGroupID = "group.com.zhuzhong.FastSCP"
    public static let maxRecentDestinations = 5
    public static let recentDefaultsKey = "recentDestinations"
}
```

**Step 2: Write `Models.swift`**
```swift
import Foundation

public struct SSHHost: Equatable, Identifiable, Sendable {
    public let id: String       // alias (first Host token)
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

public struct RemoteEntry: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public init(name: String, isDirectory: Bool) {
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
```

**Step 3: Build** — `xcodebuild ... -scheme FastSCPCore build`. Expected: SUCCEEDED.

**Step 4: Checkpoint.**

---

## Task 2: SSH config parser (TDD)

**Files:**
- Create: `Tests/FastSCPCoreTests/SSHConfigParserTests.swift`
- Create: `Sources/FastSCPCore/SSHConfigParser.swift`

**Step 1: Write failing tests**
```swift
import XCTest
@testable import FastSCPCore

final class SSHConfigParserTests: XCTestCase {
    func testParsesSingleHostWithFields() {
        let text = """
        Host server1
            HostName 10.0.0.5
            User ubuntu
            Port 2222
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts, [
            SSHHost(alias: "server1", hostName: "10.0.0.5", user: "ubuntu", port: 2222)
        ])
    }

    func testSkipsWildcardHosts() {
        let text = """
        Host *.example.com
            User deploy
        Host server2
            HostName s2.example.com
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts.map(\.alias), ["server2"])
    }

    func testMultipleAliasesUsesFirstAndSkipsIfAnyWildcard() {
        let text = """
        Host alpha bravo
            HostName a.b
        Host charlie *.x
            HostName c.x
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts.map(\.alias), ["alpha"])
    }

    func testIgnoresEmptyAndComments() {
        let text = """
        # a comment
        Host gamma
            # inline
            HostName g.b

        Host delta
            HostName d.b
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts.map(\.alias), ["gamma", "delta"])
    }

    func testIsCaseInsensitiveForKeys() {
        let text = """
        Host zeta
            hostname z.b
            USER root
            PORT 22
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts, [
            SSHHost(alias: "zeta", hostName: "z.b", user: "root", port: 22)
        ])
    }
}
```

**Step 2: Run, verify FAIL** — `xcodebuild ... -scheme FastSCPCore test`. Expected: fails (no `SSHConfigParser`).

**Step 3: Implement `SSHConfigParser.swift`**
```swift
import Foundation

public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var current: SSHHost? = nil
        let lines = text.components(separatedBy: .newlines)

        func flush() {
            if let h = current { hosts.append(h) }
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
```

**Step 4: Run, verify PASS.**

**Step 5: Checkpoint.**

---

## Task 3: `ls -ap` directory-listing parser (TDD)

**Files:**
- Create: `Tests/FastSCPCoreTests/LsParserTests.swift`
- Create: `Sources/FastSCPCore/LsParser.swift`

**Step 1: Failing tests**
```swift
import XCTest
@testable import FastSCPCore

final class LsParserTests: XCTestCase {
    func testParsesDirectoriesAndFiles() {
        let out = """
        ./
        ../
        html/
        logs/
        README.txt
        .hidden/
        """
        let entries = LsParser.parse(out)
        XCTAssertEqual(entries, [
            RemoteEntry(name: "html", isDirectory: true),
            RemoteEntry(name: "logs", isDirectory: true),
            RemoteEntry(name: "README.txt", isDirectory: false),
            RemoteEntry(name: ".hidden", isDirectory: true),
        ])
    }

    func testSkipsSelfAndParent() {
        XCTAssertEqual(LsParser.parse("./\n../\n"), [])
    }

    func testEmpty() {
        XCTAssertEqual(LsParser.parse(""), [])
    }
}
```

**Step 2: Run, verify FAIL.**

**Step 3: Implement `LsParser.swift`**
```swift
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
```

**Step 4: Run, verify PASS.**

**Step 5: Checkpoint.**

---

## Task 4: scp progress parser (TDD)

**Files:**
- Create: `Tests/FastSCPCoreTests/SCPProgressParserTests.swift`
- Create: `Sources/FastSCPCore/SCPProgressParser.swift`

**Step 1: Failing tests**
```swift
import XCTest
@testable import FastSCPCore

final class SCPProgressParserTests: XCTestCase {
    func testParsesPercentLine() {
        let line = "\rREADME.md                                    100%   12KB 123.4KB/s   0:00:00"
        let p = SCPProgressParser.parse(line)
        XCTAssertEqual(p?.percent, 100)
        XCTAssertNotNil(p?.detail)
    }

    func testParsesMidProgress() {
        let line = "\rbig.bin                                      45%  450MB  10.0MB/s   0:00:05"
        XCTAssertEqual(SCPProgressParser.parse(line)?.percent, 45)
    }

    func testIgnoresLinesWithoutPercent() {
        XCTAssertNil(SCPProgressParser.parse("some random stderr noise"))
        XCTAssertNil(SCPProgressParser.parse(""))
    }
}
```

**Step 2: Run, verify FAIL.**

**Step 3: Implement `SCPProgressParser.swift`**
```swift
import Foundation

public struct SCPProgress: Equatable, Sendable {
    public let percent: Int
    public let detail: String
    public init(percent: Int, detail: String) {
        self.percent = percent
        self.detail = detail
    }
}

public enum SCPProgressParser {
    // OpenSSH scp stderr: "<name><spaces>NNN%<detail>"
    private static let regex = try! NSRegularExpression(pattern: #"(?:^|\r)\s*\d+%|(\d{1,3})%"#)

    public static func parse(_ line: String) -> SCPProgress? {
        guard let r = line.range(of: #"\b(\d{1,3})%"#, options: .regularExpression) else { return nil }
        let numberString = String(line[r]).dropLast() // strip '%'
        guard let pct = Int(numberString), (0...100).contains(pct) else { return nil }
        // detail = trimmed remainder after the percent token
        let detail = String(line[r.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SCPProgress(percent: pct, detail: detail)
    }
}
```
(Note: a single-line best-effort parser. Streaming per-byte progress on a single large file isn't guaranteed by `scp` when stderr isn't a TTY; the UI also shows file-count progress + raw log as fallback. `rsync --info=progress2` is a documented future upgrade.)

**Step 4: Run, verify PASS.**

**Step 5: Checkpoint.**

---

## Task 5: Recent destinations logic (TDD)

**Files:**
- Create: `Tests/FastSCPCoreTests/RecentDestinationsTests.swift`
- Create: `Sources/FastSCPCore/RecentDestinations.swift`

**Step 1: Failing tests** — pure logic against `[RecentDestination]`, inject fixed `Date` values.
```swift
import XCTest
@testable import FastSCPCore

final class RecentDestinationsTests: XCTestCase {
    private func d(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: "\(s)T00:00:00Z")!
    }

    func testAddNew() {
        let result = RecentDestinations.add([], .init(alias: "s1", remotePath: "/a", timestamp: d("2026-08-06")))
        XCTAssertEqual(result.count, 1)
    }

    func testDedupUpdatesTimestampAndMovesFirst() {
        let old = RecentDestination(alias: "s1", remotePath: "/a", timestamp: d("2026-08-01"))
        let r = RecentDestinations.add([old], .init(alias: "s1", remotePath: "/a", timestamp: d("2026-08-06")))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].timestamp, d("2026-08-06"))
    }

    func testCapAtMax() {
        var list: [RecentDestination] = []
        for i in 0..<7 {
            list = RecentDestinations.add(list, .init(alias: "s\(i)", remotePath: "/p", timestamp: d("2026-08-0\(i+1)")))
        }
        XCTAssertEqual(list.count, FastSCPConfig.maxRecentDestinations)
        // newest first
        XCTAssertEqual(list.first?.alias, "s6")
    }
}
```

**Step 2: Run, verify FAIL.**

**Step 3: Implement `RecentDestinations.swift`**
```swift
import Foundation

public enum RecentDestinations {
    public static func add(_ existing: [RecentDestination], _ entry: RecentDestination) -> [RecentDestination] {
        var filtered = existing.filter { $0.id != entry.id }
        filtered.insert(entry, at: 0)
        return Array(filtered.prefix(FastSCPConfig.maxRecentDestinations))
    }
}
```

**Step 4: Run, verify PASS.**

**Step 5: Checkpoint.**

---

## Task 6: Persistence (recent destinations store) + extension-readable storage

**Files:**
- Create: `Sources/FastSCPCore/RecentStore.swift`

**Step 1: Implement a store backed by the App Group container JSON file**
```swift
import Foundation

public final class RecentStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.zhuzhong.FastSCP.recentstore")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func shared() -> RecentStore {
        if let group = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: FastSCPConfig.appGroupID) {
            return RecentStore(fileURL: group.appendingPathComponent("recent.json"))
        }
        // Fallback for local dev when app group container isn't provisioned:
        // ~/Library/Application Support/FastSCP/recent.json
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FastSCP", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RecentStore(fileURL: dir.appendingPathComponent("recent.json"))
    }

    public func load() -> [RecentDestination] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            return (try? JSONDecoder().decode([RecentDestination].self, from: data)) ?? []
        }
    }

    public func save(_ destinations: [RecentDestination]) {
        queue.sync {
            let data = try? JSONEncoder().encode(destinations)
            try? data?.write(to: fileURL, options: .atomic)
        }
    }

    public func record(_ entry: RecentDestination) {
        let updated = RecentDestinations.add(load(), entry)
        save(updated)
    }
}
```

**Fallback path note:** If the App Group container is unavailable (local signing), the store writes to `~/Library/Application Support/FastSCP/recent.json`. The **unsandboxed app** can read/write this freely. The **sandboxed extension** cannot read that fallback path — in that case the extension must read from the App Group container only (primary path). If the App Group works for both targets, this is consistent. Verify at runtime on this machine during Task 11.

**Step 2: Build** (`-scheme FastSCPCore`). Expected: SUCCEEDED.

**Step 3: Checkpoint.**

---

## Task 7: SSH executor (Process wrappers)

**Files:**
- Create: `Sources/FastSCP/SSHExecutor.swift`  (app target, unsandboxed)

> Not unit-tested (real Process + network). Built against a protocol so UI could be swapped; verified manually in Task 11. This file lives in the **app** target (needs `Process`, unavailable under sandbox).

**Step 1: Implement**
```swift
import Foundation
import FastSCPCore

enum SSHError: LocalizedError {
    case listingFailed(alias: String, path: String, stderr: String)
    case transferFailed(stderr: String)
    var errorDescription: String? {
        switch self {
        case let .listingFailed(alias, path, stderr): return "无法列出 \(alias):\(path)\n\(stderr)"
        case let .transferFailed(stderr): return "传输失败:\n\(stderr)"
        }
    }
}

actor SSHExecutor {
    static let shared = SSHExecutor()
    private var runningProcess: Process?

    /// `ssh <alias> 'ls -ap <path>'`
    func listDirectory(alias: String, path: String) async throws -> [RemoteEntry] {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let output = try await run(["-p", alias, "ls", "-ap", "\(escapedPath)"], useSSH: true)
        return LsParser.parse(output).filter { $0.isDirectory }
    }

    /// `scp -r <sources> <alias>:<path>`
    func transfer(alias: String, path: String, sources: [URL],
                  progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        var args = ["-r"]
        args.append(contentsOf: sources.map { $0.path })
        let safePath = path.hasSuffix("/") ? path : path + "/"
        args.append("\(alias):\(safePath)")
        try await runWithProgress(args, useSSH: false, progress: progress)
    }

    func cancel() {
        runningProcess?.terminate()
    }

    // MARK: - internals

    private func run(_ sshArgs: [String], useSSH: Bool) async throws -> String {
        let proc = Process()
        let binary = useSSH ? "/usr/bin/ssh" : "/usr/bin/scp"
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = sshArgs
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        runningProcess = proc
        try proc.run()
        proc.waitUntilExit()
        runningProcess = nil
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        if proc.terminationStatus != 0 {
            let errMsg = String(data: errData, encoding: .utf8) ?? ""
            if useSSH {
                throw SSHError.listingFailed(alias: sshArgs[safe: 1] ?? "", path: "", stderr: errMsg)
            } else {
                throw SSHError.transferFailed(stderr: errMsg)
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func runWithProgress(_ args: [String], useSSH: Bool,
                                 progress: @Sendable @escaping (SCPProgress?) -> Void) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: useSSH ? "/usr/bin/ssh" : "/usr/bin/scp")
        proc.arguments = args
        let err = Pipe()
        proc.standardOutput = FileHandle() // discard
        proc.standardError = err
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                progress(SCPProgressParser.parse(line))
            }
        }
        runningProcess = proc
        try proc.run()
        proc.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        runningProcess = nil
        if proc.terminationStatus != 0 {
            // drain
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            throw SSHError.transferFailed(stderr: String(data: errData, encoding: .utf8) ?? "")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

**Step 2: Build** (`-scheme FastSCP`). Expected: SUCCEEDED.

**Step 3: Checkpoint.**

---

## Task 8: Main app — URL handoff + lifecycle

**Files:**
- Modify: `Sources/FastSCP/Main.swift` (replace placeholder)
- Create: `Sources/FastSCP/URLCoordinator.swift`
- Create: `Sources/FastSCP/SelectionStore.swift`

**Step 1: `SelectionStore.swift`** — reads the temp file written by the extension (App Group container).
```swift
import Foundation
import FastSCPCore

enum SelectionStore {
    /// Extension writes selected paths (one per line) to this shared file.
    static func batchURL(for token: String) -> URL {
        if let group = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: FastSCPConfig.appGroupID) {
            return group.appendingPathComponent("batch-\(token).txt")
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("fastscp-batch-\(token).txt")
    }

    static func readSelections(token: String) -> [URL] {
        let url = batchURL(for: token)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        try? FileManager.default.removeItem(at: url)
        return text.split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }
}
```

**Step 2: `URLCoordinator.swift`** — parses `fastscp://...` and drives the flow.
```swift
import Foundation
import SwiftUI
import FastSCPCore

@MainActor
final class URLCoordinator: ObservableObject {
    @Published var panelState: PanelState = .idle
    @Published var quickTransfer: QuickTransfer?

    enum PanelState: Equatable {
        case idle
        case choosing(selections: [URL])
    }

    struct QuickTransfer: Equatable {
        let selections: [URL]
        let alias: String
        let remotePath: String
    }

    func handle(_ url: URL) {
        guard url.scheme == FastSCPConfig.urlScheme else { return }
        let action = url.host ?? ""
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let token = comps?.queryItems?.first(where: { $0.name == "list" })?.value ?? ""

        switch action {
        case "choose":
            panelState = .choosing(selections: SelectionStore.readSelections(token: token))
        case "quick":
            let alias = comps?.queryItems?.first(where: { $0.name == "alias" })?.value ?? ""
            let path = comps?.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
            quickTransfer = QuickTransfer(
                selections: SelectionStore.readSelections(token: token),
                alias: alias,
                remotePath: path
            )
        default:
            break
        }
    }
}
```

**Step 3: Replace `Main.swift` with the SwiftUI app** (`@main` via NSApplicationDelegate bridging for `onOpenURL`).
```swift
import SwiftUI
import FastSCPCore

@main
struct FastSCPApp: App {
    @StateObject private var coordinator = URLCoordinator()

    var body: some Scene {
        MenuBarExtra {} // hidden; agent app has no UI scene unless a panel is shown
        .commandsRemoved()

        // Panels driven by coordinator
        Settings {
            EmptyView()
        }
    }
}
```
> Note: `onOpenURL` is best wired via `NSAppleEventManager` in an `NSApplicationDelegate` (NSApplicationDelegateAdaptor) because the app is `LSUIElement` and may be relaunched by the extension repeatedly. Task 9 (UI) wires `NSApplicationDelegateAdaptor` + `.onOpenURL` to `coordinator.handle`. A placeholder `@main` is sufficient to build now.

**Step 4: Build.** Expected: SUCCEEDED (may emit warnings; fix as needed).

**Step 5: Checkpoint.**

---

## Task 9: Destination picker panel (SwiftUI + NSPanel)

**Files:**
- Create: `Sources/FastSCP/DestinationPanel.swift`
- Create: `Sources/FastSCP/AppDelegate.swift`
- Modify: `Sources/FastSCP/Main.swift` (wire delegate + panels)
- Modify: `Sources/FastSCP/URLCoordinator.swift` (trigger panels)

This is the core UI. Build it, then verify visually in Task 11.

**Step 1: `AppDelegate.swift`** — receives Apple Events (URL scheme) for an agent app.
```swift
import AppKit
import SwiftUI
import FastSCPCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let coordinator = URLCoordinator()
    private var panel: DestinationPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Handle the case where launched via URL: the event may already be queued.
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { coordinator.handle(url) }
        presentIfNeeded()
    }

    func handleAppleEvent(_ event: NSAppleEventDescriptor) {
        guard let urlStr = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlStr) else { return }
        coordinator.handle(url)
        presentIfNeeded()
    }

    private func presentIfNeeded() {
        switch coordinator.panelState {
        case .choosing:
            if panel == nil { panel = DestinationPanelController(coordinator: coordinator) }
            panel?.show()
        case .idle:
            break
        }
    }
}
```

**Step 2: `DestinationPanel.swift`** — a small borderless `NSPanel` (≈360×440) hosting SwiftUI.
```swift
import AppKit
import SwiftUI
import FastSCPCore

final class DestinationPanelController {
    private let panel: NSPanel
    private let vm: DestinationViewModel

    init(coordinator: URLCoordinator) {
        case let .choosing(selections) = coordinator.panelState
        vm = DestinationViewModel(selections: selections)
        let host = NSHostingController(rootView: DestinationView(viewModel: vm) {
            coordinator.panelState = .idle
        })
        panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        panel.title = "选择目标"
        panel.setContentSize(NSSize(width: 360, height: 440))
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        vm.onSend = { [weak panel] alias, path in
            Task { @MainActor in
                await self.vm.performTransfer(alias: alias, path: path)
                RecentStore.shared().record(.init(alias: alias, remotePath: path, timestamp: Date()))
                panel?.close()
            }
        }
        Task { await vm.loadHosts() }
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class DestinationViewModel: ObservableObject {
    @Published var hosts: [SSHHost] = []
    @Published var selectedAlias: String = ""
    @Published var currentPath: String = "~"
    @Published var entries: [RemoteEntry] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var progressText: String?
    let selections: [URL]
    var onSend: ((String, String) -> Void)?

    init(selections: [URL]) { self.selections = selections }

    func loadHosts() async {
        let configText = (try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8)) ?? ""
        let parsed = SSHConfigParser.parse(configText)
        hosts = parsed
        selectedAlias = RecentStore.shared().load().first?.alias ?? parsed.first?.alias ?? ""
        await refresh()
    }

    func refresh() async {
        guard !selectedAlias.isEmpty else { return }
        loading = true; errorMessage = nil
        do {
            entries = try await SSHExecutor.shared.listDirectory(alias: selectedAlias, path: currentPath)
        } catch {
            errorMessage = error.localizedDescription
            entries = []
        }
        loading = false
    }

    func enter(_ entry: RemoteEntry) {
        currentPath = (currentPath as NSString).appendingPathComponent(entry.name)
        Task { await refresh() }
    }

    func goUp() {
        let s = currentPath as NSString
        if s.deletingLastPathComponent != currentPath {
            currentPath = s.deletingLastPathComponent
            Task { await refresh() }
        }
    }

    func commitPath() { Task { await refresh() } }

    func send() {
        guard !selectedAlias.isEmpty else { return }
        onSend?(selectedAlias, currentPath)
    }

    func performTransfer(alias: String, path: String) async {
        progressText = "传输中…"
        defer { progressText = nil }
        do {
            try await SSHExecutor.shared.transfer(alias: alias, path: path, sources: selections) { [weak self] p in
                Task { @MainActor in
                    self?.progressText = p.map { "\($0.percent)% \($0.detail)" } ?? "传输中…"
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DestinationView: View {
    @ObservedObject var viewModel: DestinationViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("服务器").frame(width: 50, alignment: .leading)
                Picker("", selection: $viewModel.selectedAlias) {
                    ForEach(viewModel.hosts) { Text($0.alias).tag($0.alias) }
                }
                .labelsHidden()
                .onChange(of: viewModel.selectedAlias) { _, _ in viewModel.commitPath() }
            }
            HStack {
                Text("路径").frame(width: 50, alignment: .leading)
                TextField("/path", text: $viewModel.currentPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.commitPath() }
            }
            Divider()
            if viewModel.loading {
                ProgressView().controlSize(.small).padding(.vertical, 20)
            } else {
                List(viewModel.entries) { entry in
                    Button(action: { viewModel.enter(entry) }) {
                        Label(entry.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let err = viewModel.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Spacer(minLength: 0)
            HStack {
                Button("返回上层") { viewModel.goUp() }
                Spacer()
                Button("取消", role: .cancel) { onClose() }
                Button("发送 \(viewModel.selections.count) 项 → \(viewModel.selectedAlias):\(viewModel.currentPath)") {
                    viewModel.send()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedAlias.isEmpty || viewModel.progressText != nil)
            }
            if let p = viewModel.progressText {
                Text(p).font(.caption)
            }
        }
        .padding(12)
    }
}
```

**Step 3: Update `Main.swift`** to use the delegate.
```swift
import SwiftUI

@main
struct FastSCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
```

**Step 4: Wire Apple Event for URL scheme** — add in `AppDelegate.applicationDidFinishLaunching`:
```swift
NSAppleEventManager.shared().setEventHandler(
    appDelegate-like self, // self is the AppDelegate
    andSelector: #selector(handleURLEvent(_:replyEvent:)),
    forEventClass: kInternetEventClass, andEventID: kAEGetURL)
```
Add method:
```swift
@objc func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
    handleAppleEvent(event)
}
```
(Concrete wiring finalized during Task 11 build; the exact selector target is `self`.)

**Step 5: Build.** Expected: SUCCEEDED. Visual verification deferred to Task 11.

**Step 6: Checkpoint.**

---

## Task 10: Finder Sync extension — menu + capture + handoff

**Files:**
- Modify: `Sources/FastSCPFinderSync/FinderSync.swift` (replace placeholder)

**Step 1: Implement**
```swift
import Cocoa
import FinderSync
import FastSCPCore

class FinderSync: NSObject, FIFinderSync {
    override init() {
        super.init()
        // Observe the whole filesystem so the menu appears everywhere.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "FastSCP")
        let recents = RecentStore.shared().load()

        if let last = recents.first {
            let item = NSMenuItem(title: "发送到 \(last.alias):\(last.remotePath)",
                                  action: #selector(quickSend(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = last
            menu.addItem(item)
        }
        if recents.count > 1 {
            let submenu = NSMenu(title: "最近目标")
            for r in recents.dropFirst() {
                let item = NSMenuItem(title: "\(r.alias):\(r.remotePath)",
                                      action: #selector(quickSend(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = r
                submenu.addItem(item)
            }
            let parent = NSMenuItem(title: "最近目标", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        let choose = NSMenuItem(title: "选择目标…", action: #selector(chooseDestination(_:)), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)
        return menu
    }

    @objc func quickSend(_ sender: NSMenuItem) {
        guard let dest = sender.representedObject as? RecentDestination else { return }
        guard let token = writeSelectionBatch() else { return }
        openURL(action: "quick", token: token,
                extra: ["alias": dest.alias, "path": dest.remotePath])
    }

    @objc func chooseDestination(_ sender: NSMenuItem) {
        guard let token = writeSelectionBatch() else { return }
        openURL(action: "choose", token: token, extra: [:])
    }

    private func writeSelectionBatch() -> String? {
        let urls = FIFinderSyncController.default().selectedItemURLs()
        guard !urls.isEmpty else { return nil }
        let token = UUID().uuidString
        let fileURL = SelectionStore.batchURL(for: token)
        let text = urls.map(\.path).joined(separator: "\n")
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        return token
    }

    private func openURL(action: String, token: String, extra: [String: String]) {
        var comps = URLComponents()
        comps.scheme = FastSCPConfig.urlScheme
        comps.host = action
        var items = [URLQueryItem(name: "list", value: token)]
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }
}
```

> `SelectionStore.batchURL(for:)` is in `FastSCPCore` — move it (or duplicate the one-liner) so the extension can call it. If it's app-target-only, add a small `Sources/FastSCPCore/BatchPaths.swift` instead and have both call it. **Adjustment during implementation:** relocate the `batchURL` logic into `FastSCPCore` so both targets share it.

**Step 2: Move `batchURL` into `FastSCPCore/BatchPaths.swift`**, update `SelectionStore` to delegate to it.

**Step 3: Build extension** (`-scheme FastSCPFinderSync`). Expected: SUCCEEDED.

**Step 4: Checkpoint.**

---

## Task 11: Integration build, install, and manual end-to-end test

**Step 1: Regenerate + clean build all targets**
```bash
xcodegen generate
xcodebuild -project FastSCP.xcodeproj -scheme FastSCP -configuration Debug build
xcodebuild -project FastSCP.xcodeproj -scheme FastSCPFinderSync -configuration Debug build
xcodebuild -project FastSCP.xcodeproj -scheme FastSCPCore test
```
Expected: builds succeed; all unit tests pass.

**Step 2: Run the app once** so macOS registers the URL scheme + Finder extension:
```bash
open "$(xcodebuild -project FastSCP.xcodeproj -scheme FastSCP -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}' | head -1)/FastSCP.app"
```
Then System Settings → Extensions → Finder Extensions → enable **FastSCP Finder Extension**.

**Step 3: Manual test matrix**
- Right-click a file in Finder → "FastSCP ▸ 选择目标…" → panel appears (small, near center) → server dropdown lists `~/.ssh/config` hosts → double-click folders navigates → path field typed + Enter navigates → "发送 N 项 → alias:/path" → file arrives on server → success.
- Right-click again → "发送到 alias:/path" (one-click) appears → click → transfer runs (no panel) → notification.
- "最近目标" submenu lists prior targets.
- Error case: pick a server with a bad path / no write permission → error message shown inline.

**Step 4: App Group verification** — confirm `containerURL(forSecurityApplicationGroupIdentifier:)` is non-nil for both targets (add a temporary `print` / check `~/Library/Group Containers/group.com.zhuzhong.FastSCP/recent.json` is created). If nil, switch to the documented fallback (extension reads from its own container; app writes recent there).

**Step 5: Checkpoint — surface full status to user for review/commit.**

---

## Out of scope / future
- `rsync --info=progress2` for streaming progress + resume.
- Per-source-folder destination memory.
- `SSH_ASKPASS` GUI passphrase prompt for keys not in ssh-agent.
- Notarization / App Store distribution (requires sandbox-compatible approach — different architecture).
- Drag-and-drop onto a menu bar icon.

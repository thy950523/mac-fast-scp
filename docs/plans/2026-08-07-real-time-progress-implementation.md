# FastSCP 实时进度 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add real-time transfer progress to both send and receive paths — byte-based total progress in the two popup panels, and an auto-closing top-right HUD for quick-send — computed by a shared direction-aware progress engine.

**Architecture:** A pure state machine `TransferAggregator` (in `FastSCPCore`) consumes parsed scp progress lines and maintains monotonic total progress in three knowledge modes: `.full` (per-file sizes from local scan or remote `find -printf`), `.totalsOnly` (file-count ratio from `find` + `du`), and `.unknown` (indeterminate). `RemoteSizeProbe` parses remote command output. A `@MainActor` `TransferTracker` wraps the aggregator with a direction + prepare data source and publishes to SwiftUI. Both popups share `TransferStatusView`; quick-send gets `QuickTransferHUDController`.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSPanel`), `FileManager.enumerator`, `Process` (existing `SSHExecutor`), xcodegen, XCTest.

**Design doc:** `docs/plans/2026-08-07-real-time-progress-design.md`

---

## Conventions

- Core tests: `xcodebuild test -project FastSCP.xcodeproj -scheme FastSCPCore -destination 'platform=macOS' -only-testing:FastSCPCoreTests/<Suite>/<test>`
- App build: `xcodebuild -project FastSCP.xcodeproj -scheme FastSCP -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`
- If `FastSCP.xcodeproj` is missing, run `xcodegen generate` first.
- TDD per task: red → fail → minimal impl → pass → commit.

---

## Phase 1 — Parser, formatting, probe (pure, in `FastSCPCore`)

### Task 1: Augment `SCPProgressParser` to extract filename + rate

**Files:** Modify `Sources/FastSCPCore/SCPProgressParser.swift`; Test `Tests/FastSCPCoreTests/SCPProgressParserTests.swift`

**Step 1: Add failing tests** (append to the test class)

```swift
func testParsesFileName() {
    let line = "\rlogs/app.log                                62%   74MB 12.3MB/s   0:00:04"
    XCTAssertEqual(SCPProgressParser.parse(line)?.fileName, "logs/app.log")
}

func testParsesRateKB() {
    let p = SCPProgressParser.parse("\rREADME.md  100%   12KB 123.4KB/s   0:00:00")
    XCTAssertNotNil(p?.rateBytesPerSec)
    XCTAssertGreaterThan(p!.rateBytesPerSec!, 0)
}

func testParsesRateMB() {
    let p = SCPProgressParser.parse("\rbig.bin  45%  450MB  10.0MB/s   0:00:05")
    XCTAssertGreaterThan(p!.rateBytesPerSec!, 1_000_000)
}

func testPercentOnlyLineHasNilNameAndRate() {
    let p = SCPProgressParser.parse("42%")
    XCTAssertNotNil(p); XCTAssertEqual(p?.percent, 42)
    XCTAssertNil(p?.fileName); XCTAssertNil(p?.rateBytesPerSec)
}
```

`testIgnoresLinesWithoutPercent` (no percent → nil) must keep passing.

**Step 2:** Run the suite, confirm new tests FAIL (members not defined).

**Step 3: Replace `SCPProgressParser.swift`:**

```swift
import Foundation

public struct SCPProgress: Equatable, Sendable {
    public let percent: Int
    public let fileName: String?
    public let rateBytesPerSec: Int64?
    public let detail: String
    public init(percent: Int, fileName: String?, rateBytesPerSec: Int64?, detail: String) {
        self.percent = percent; self.fileName = fileName
        self.rateBytesPerSec = rateBytesPerSec; self.detail = detail
    }
}

public enum SCPProgressParser {
    /// Parses "\r<name><spaces>NNN%<size> <rate> <eta>". Returns nil if no percent.
    public static func parse(_ line: String) -> SCPProgress? {
        let stripped = line.hasPrefix("\r") ? String(line.dropFirst()) : line
        guard let r = stripped.range(of: #"\b\d{1,3}%"#, options: .regularExpression) else { return nil }
        let pctText = String(stripped[r].dropLast())
        guard let pct = Int(pctText), (0...100).contains(pct) else { return nil }
        let fileName = String(stripped[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = String(stripped[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return SCPProgress(percent: pct,
                           fileName: fileName.isEmpty ? nil : fileName,
                           rateBytesPerSec: parseRate(from: detail),
                           detail: detail)
    }

    static func parseRate(from detail: String) -> Int64? {
        guard let r = detail.range(of: #"(\d+(?:\.\d+)?)\s*(K|M|G)?B/s"#, options: .regularExpression)
        else { return nil }
        let token = detail[r]
        var chars: [Character] = []
        var unit: Character = "B"
        for c in token {
            if c.isNumber || c == "." { chars.append(c) }
            else if c == "K" || c == "M" || c == "G" { unit = c; break }
            else if !chars.isEmpty { break }
        }
        guard let n = Double(String(chars)), n >= 0 else { return nil }
        let mult: Double
        switch unit {
        case "K": mult = 1024
        case "M": mult = 1024*1024
        case "G": mult = 1024*1024*1024
        default:  mult = 1
        }
        return Int64(n * mult)
    }
}
```

**Step 4:** Run tests → PASS. **Step 5:** Commit `feat(core): extract fileName + rate from scp progress lines`.

---

### Task 2: `ByteFormat`

**Files:** Create `Sources/FastSCPCore/ByteFormat.swift`; Test `Tests/FastSCPCoreTests/ByteFormatTests.swift`

**Step 1: Test**

```swift
import XCTest
@testable import FastSCPCore
final class ByteFormatTests: XCTestCase {
    func testSize() {
        XCTAssertEqual(ByteFormat.size(0), "0 B")
        XCTAssertEqual(ByteFormat.size(512), "512 B")
        XCTAssertEqual(ByteFormat.size(1024), "1.0 KB")
        XCTAssertEqual(ByteFormat.size(10*1024*1024), "10.0 MB")
        XCTAssertEqual(ByteFormat.size(Int64(1024)*1024*1024), "1.00 GB")
    }
    func testRate() {
        XCTAssertEqual(ByteFormat.rate(12_000_000), "11.4 MB/s")
    }
    func testNegativeSafe() {
        XCTAssertEqual(ByteFormat.size(-5), "0 B")
        XCTAssertEqual(ByteFormat.rate(-1), "0 B/s")
    }
}
```

**Step 2:** Run → FAIL. **Step 3: Implement**

```swift
import Foundation
public enum ByteFormat {
    public static func size(_ bytes: Int64) -> String {
        let b = max(bytes, 0)
        if b < 1024 { return "\(b) B" }
        let kb = Double(b)/1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb/1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb/1024)
    }
    public static func rate(_ bps: Int64) -> String { size(bps) + "/s" }
}
```

**Step 4:** PASS. **Step 5:** Commit `feat(core): add ByteFormat helpers`.

---

### Task 3: `RemoteSizeProbe` — parse remote size commands

**Files:** Create `Sources/FastSCPCore/RemoteSizeProbe.swift`; Test `Tests/FastSCPCoreTests/RemoteSizeProbeTests.swift`

**Step 1: Test**

```swift
import XCTest
@testable import FastSCPCore

final class RemoteSizeProbeTests: XCTestCase {
    func testParseFindPrintf() {
        let out = "12345 readme.md\n67890 logs/app.log\n"
        let r = RemoteSizeProbe.parseFindPrintf(out)
        XCTAssertEqual(r?.totalBytes, 80235)
        XCTAssertEqual(r?.totalFiles, 2)
        XCTAssertEqual(r?.lookup["readme.md"], 12345)
        XCTAssertEqual(r?.lookup["logs/app.log"], 67890)
    }

    func testParseFindPrintfEmpty() {
        XCTAssertNil(RemoteSizeProbe.parseFindPrintf(""))
        XCTAssertNil(RemoteSizeProbe.parseFindPrintf("garbage line\n"))
    }

    func testParseFindFileCount() {
        let out = "/var/www/a\n/var/www/b\n/var/www/c\n"
        XCTAssertEqual(RemoteSizeProbe.parseFindFileCount(out), 3)
    }

    func testParseDuTotalSingle() {
        // GNU du -sk: "12345\tpath"
        XCTAssertEqual(RemoteSizeProbe.parseDuTotalKB("12345\t/var/www"), 12345)
    }

    func testParseDuTotalMultiPathBSD() {
        // BSD du -sk with multiple args ends with a "total" line.
        let out = "100\t/a\n200\t/b\n300\ttotal\n"
        XCTAssertEqual(RemoteSizeProbe.parseDuTotalKB(out), 300)
    }

    func testParseDuTotalGNU() {
        // GNU du -sc ends with a "total" line too.
        let out = "100\t/a\n200\t/b\n300\ttotal\n"
        XCTAssertEqual(RemoteSizeProbe.parseDuTotalKB(out), 300)
    }
}
```

**Step 2:** Run → FAIL. **Step 3: Implement**

```swift
import Foundation

/// Output of a successful remote size probe.
public struct RemoteSize: Equatable, Sendable {
    public var totalBytes: Int64
    public var totalFiles: Int
    public var lookup: [String: Int64]
    public init(totalBytes: Int64, totalFiles: Int, lookup: [String: Int64]) {
        self.totalBytes = totalBytes; self.totalFiles = totalFiles; self.lookup = lookup
    }
}

public enum RemoteSizeProbe {
    /// Parses `find ... -type f -printf '%s %f\n'` output.
    /// Each line: "<size> <basename>". Returns nil if no valid line.
    public static func parseFindPrintf(_ output: String) -> RemoteSize? {
        var total: Int64 = 0
        var count = 0
        var lookup: [String: Int64] = [:]
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let size = Int64(parts[0]) else { continue }
            let name = String(parts[1])
            total += size
            count += 1
            lookup[name] = size
        }
        guard count > 0 else { return nil }
        return RemoteSize(totalBytes: total, totalFiles: count, lookup: lookup)
    }

    /// Counts non-empty lines from `find ... -type f`.
    public static func parseFindFileCount(_ output: String) -> Int {
        output.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// Parses `du -sk` total in KB. For multiple paths, takes the last numeric
    /// line (the "total" summary both GNU `-c` and BSD print).
    public static func parseDuTotalKB(_ output: String) -> Int64? {
        var last: Int64?
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let first = line.split(separator: "\t").first ?? line.split(separator: " ").first
            if let s = first, let kb = Int64(s) { last = kb }
        }
        return last
    }
}
```

**Step 4:** PASS. **Step 5:** Commit `feat(core): add RemoteSizeProbe parsers (find -printf, find, du)`.

---

## Phase 2 — TransferAggregator (pure state machine)

### Task 4: Model + aggregator skeleton + `.full` behavior

**Files:** Create `Sources/FastSCPCore/TransferProgress.swift`; Test `Tests/FastSCPCoreTests/TransferAggregatorTests.swift`

**Step 1: Test**

```swift
import XCTest
@testable import FastSCPCore
final class TransferAggregatorTests: XCTestCase {
    func testInitialPreparingAndZero() {
        let a = TransferAggregator(direction: .send, totalBytes: 1000, totalFiles: 1)
        XCTAssertEqual(a.progress.percent, 0)
        if case .preparing = a.progress.phase {} else { XCTFail("expected preparing") }
    }

    func testSingleFileFull() {
        var a = TransferAggregator(direction: .send, totalBytes: 1000, totalFiles: 1)
        a.startSending()
        a.ingest(.init(percent: 0.3, fileName: "a.bin", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.completedBytes, 300)
        a.ingest(.init(percent: 0.7, fileName: "a.bin", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.completedBytes, 700)
        a.complete()
        XCTAssertEqual(a.progress.percent, 1.0)
        if case .done = a.progress.phase {} else { XCTFail() }
    }

    func testMultiFileFull() {
        let lookup = ["a.bin": 600, "b.bin": 400]
        var a = TransferAggregator(direction: .send, totalBytes: 1000, totalFiles: 2,
                                   fileSizeLookup: lookup, sizeKnowledge: .full)
        a.startSending()
        a.ingest(.init(percent: 1.0, fileName: "a.bin", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.currentFileIndex, 1)
        a.ingest(.init(percent: 0.5, fileName: "b.bin", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.currentFileIndex, 2)
        XCTAssertEqual(a.progress.completedBytes, 800)
        a.complete()
        XCTAssertEqual(a.progress.percent, 1.0)
    }

    func testPctRegressionKeepsMax() {
        var a = TransferAggregator(direction: .send, totalBytes: 1000, totalFiles: 1)
        a.startSending()
        a.ingest(.init(percent: 0.6, fileName: "x", rateBytesPerSec: nil))
        let before = a.progress.completedBytes
        a.ingest(.init(percent: 0.45, fileName: "x", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.completedBytes, before)
    }

    func testEtaFromRate() {
        var a = TransferAggregator(direction: .send, totalBytes: 1000, totalFiles: 1)
        a.startSending()
        a.ingest(.init(percent: 0, fileName: "a", rateBytesPerSec: 100))
        XCTAssertEqual(a.progress.etaSeconds, 10)
    }

    func testFailKeepsBytesSetsPhase() {
        var a = TransferAggregator(direction: .send, totalBytes: 1000, totalFiles: 1)
        a.startSending()
        a.ingest(.init(percent: 0.5, fileName: "a", rateBytesPerSec: nil))
        let before = a.progress.completedBytes
        a.fail("kaboom")
        XCTAssertEqual(a.progress.completedBytes, before)
        if case .failed(let m) = a.progress.phase { XCTAssertEqual(m, "kaboom") } else { XCTFail() }
    }
}
```

**Step 2:** Run → FAIL. **Step 3: Implement** (`TransferProgress.swift`)

```swift
import Foundation

public enum TransferPhase: Equatable, Sendable {
    case preparing, sending, done, failed(String)
}
public enum TransferDirection: String, Sendable { case send, receive }
public enum SizeKnowledge: Sendable { case full, totalsOnly, unknown }

public struct TransferProgress: Equatable, Sendable {
    public let phase: TransferPhase
    public let direction: TransferDirection
    public let totalBytes: Int64
    public let completedBytes: Int64
    public let totalFiles: Int
    public let currentFileIndex: Int
    public let currentFileName: String?
    public let rateBytesPerSec: Int64?
    public let etaSeconds: Int?
    public let sizeKnowledge: SizeKnowledge

    public var percent: Double {
        guard totalBytes > 0 else { return phase == .done ? 1 : 0 }
        return min(max(Double(completedBytes)/Double(totalBytes), 0), 1)
    }
}

public struct ParsedProgress: Equatable, Sendable {
    public let percent: Double
    public let fileName: String?
    public let rateBytesPerSec: Int64?
    public init(percent: Double, fileName: String?, rateBytesPerSec: Int64?) {
        self.percent = percent; self.fileName = fileName; self.rateBytesPerSec = rateBytesPerSec
    }
}

public struct TransferAggregator {
    public let direction: TransferDirection
    public let totalBytes: Int64
    public let totalFiles: Int
    public let sizeKnowledge: SizeKnowledge

    private var fileSizeLookup: [String: Int64]
    private var completedBytes: Int64 = 0
    private var completedFiles: Int = 0
    private var currentFileName: String?
    private var currentFileIndex: Int = 0
    private var currentFileSize: Int64 = 0
    private var currentFileBytesSeen: Int64 = 0
    private var currentFileMaxPct: Double = 0
    private var phase: TransferPhase = .preparing
    private var rateBytesPerSec: Int64?
    private var etaSeconds: Int?

    public init(direction: TransferDirection, totalBytes: Int64, totalFiles: Int,
                fileSizeLookup: [String: Int64] = [:], sizeKnowledge: SizeKnowledge = .full) {
        self.direction = direction; self.totalBytes = totalBytes
        self.totalFiles = totalFiles; self.fileSizeLookup = fileSizeLookup
        self.sizeKnowledge = sizeKnowledge
    }

    public var progress: TransferProgress {
        let done = min(completedBytes + currentFileBytesSeen, max(totalBytes, 0))
        return TransferProgress(phase: phase, direction: direction, totalBytes: totalBytes,
            completedBytes: done, totalFiles: totalFiles, currentFileIndex: currentFileIndex,
            currentFileName: currentFileName, rateBytesPerSec: rateBytesPerSec,
            etaSeconds: etaSeconds, sizeKnowledge: sizeKnowledge)
    }

    public mutating func startSending() {
        if case .preparing = phase { phase = .sending }
    }

    public mutating func ingest(_ event: ParsedProgress) {
        if case .preparing = phase { phase = .sending }
        let pct = min(max(event.percent, 0), 1)

        if let name = event.fileName, name != currentFileName {
            // close out the PREVIOUS file — but only if there was one
            // (the first file transition has nothing to credit yet).
            if currentFileName != nil {
                switch sizeKnowledge {
                case .full:
                    completedBytes += currentFileSize
                case .totalsOnly:
                    completedFiles += 1
                    if totalFiles > 0 {
                        completedBytes = totalBytes * Int64(completedFiles) / Int64(totalFiles)
                    }
                case .unknown:
                    break
                }
            }
            currentFileIndex = min(currentFileIndex + 1, max(totalFiles, 1))
            currentFileName = name
            currentFileSize = fileSizeLookup[name] ?? 0
            currentFileBytesSeen = 0
            currentFileMaxPct = 0
        } else if currentFileName == nil, let name = event.fileName {
            currentFileName = name
            currentFileSize = fileSizeLookup[name] ?? 0
            currentFileIndex = min(currentFileIndex + 1, max(totalFiles, 1))
        }

        switch sizeKnowledge {
        case .full:
            if pct >= currentFileMaxPct {
                currentFileMaxPct = pct
                currentFileBytesSeen = Int64(Double(currentFileSize) * pct)
            }
        case .totalsOnly:
            if pct >= currentFileMaxPct { currentFileMaxPct = pct }
            let doneFiles = completedFiles
            let ratio = totalFiles > 0
                ? Double(doneFiles) / Double(totalFiles)
                    + pct / Double(totalFiles)
                : 0
            currentFileBytesSeen = Int64(Double(totalBytes) * min(max(ratio, 0), 1))
                - completedBytes
        case .unknown:
            currentFileBytesSeen = 0
        }

        rateBytesPerSec = event.rateBytesPerSec
        if let r = event.rateBytesPerSec, r > 0, totalBytes > 0 {
            let remaining = max(totalBytes - (completedBytes + currentFileBytesSeen), 0)
            etaSeconds = Int(remaining / r)
        }
    }

    public mutating func complete() {
        completedBytes = totalBytes
        currentFileBytesSeen = 0
        phase = .done
    }
    public mutating func fail(_ message: String) { phase = .failed(message) }
}
```

**Step 4:** PASS. **Step 5:** Commit `feat(core): TransferProgress model + TransferAggregator (.full)`.

---

### Task 5: `.totalsOnly` and `.unknown` behavior

**Files:** Modify `Tests/FastSCPCoreTests/TransferAggregatorTests.swift`

**Step 1: Add tests**

```swift
    func testTotalsOnlyAdvancesByFileRatio() {
        var a = TransferAggregator(direction: .receive, totalBytes: 1000, totalFiles: 2,
                                   sizeKnowledge: .totalsOnly)
        a.startSending()
        a.ingest(.init(percent: 1.0, fileName: "a", rateBytesPerSec: nil))
        // first file done → 50%
        XCTAssertEqual(a.progress.completedBytes, 500)
        a.ingest(.init(percent: 0.5, fileName: "b", rateBytesPerSec: nil))
        // second file halfway → 75%
        XCTAssertEqual(a.progress.completedBytes, 750)
        a.complete()
        XCTAssertEqual(a.progress.percent, 1.0)
    }

    func testUnknownShowsNoBytes() {
        var a = TransferAggregator(direction: .receive, totalBytes: 0, totalFiles: 0,
                                   sizeKnowledge: .unknown)
        a.startSending()
        a.ingest(.init(percent: 0.5, fileName: "remote.bin", rateBytesPerSec: 1000))
        XCTAssertEqual(a.progress.completedBytes, 0)
        XCTAssertEqual(a.progress.percent, 0)
        XCTAssertEqual(a.progress.currentFileName, "remote.bin")
        a.complete()
        XCTAssertEqual(a.progress.percent, 1.0)
    }
```

**Step 2:** Run → both should already PASS with the Task 4 implementation (verify; adjust `ingest` if `totalsOnly` math is off — expected: after file switch `completedFiles=1`, ratio base = `1/2 + 0 = 0.5` → completedBytes=500; then b at 0.5 → `0.5 + 0.25 = 0.75` → 750).

**Step 3:** PASS. **Step 4:** Commit `test(core): cover totalsOnly/unknown aggregator modes`.

---

## Phase 3 — SSH probe + TransferTracker

### Task 6: `SSHExecutor.probeRemoteSizes`

**Files:** Modify `Sources/FastSCP/SSHExecutor.swift`

**Step 1: Add `PreparedTransfer` to core**

Append to `Sources/FastSCPCore/TransferProgress.swift`:

```swift
public struct PreparedTransfer: Equatable, Sendable {
    public let totalBytes: Int64
    public let totalFiles: Int
    public let lookup: [String: Int64]
    public let sizeKnowledge: SizeKnowledge
    public init(totalBytes: Int64, totalFiles: Int, lookup: [String: Int64], sizeKnowledge: SizeKnowledge) {
        self.totalBytes = totalBytes; self.totalFiles = totalFiles
        self.lookup = lookup; self.sizeKnowledge = sizeKnowledge
    }
}
```

**Step 2: Add the probe methods to `SSHExecutor`**

In `Sources/FastSCP/SSHExecutor.swift`, add this import if not present (`FastSCPCore` is already imported), then add the methods after `pull(...)`. The argv shape is `ssh <alias> find <paths> ...`:

```swift
    /// Determine remote total size with a two-tier fallback:
    /// 1. `find ... -printf '%s %f\n'` (GNU find) → per-file sizes (.full)
    /// 2. `find ... -type f` (count) + `du -sk` (total) → .totalsOnly
    /// 3. neither → .unknown
    func probeRemoteSizes(alias: String, remotePath: String, names: [String]) async -> PreparedTransfer {
        let base = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        let paths = names.map { "\(base)/\($0)" }
        if let full = await probeTier1(alias: alias, paths: paths) { return full }
        if let totals = await probeTier2(alias: alias, paths: paths) { return totals }
        return PreparedTransfer(totalBytes: 0, totalFiles: 0, lookup: [:], sizeKnowledge: .unknown)
    }

    private func probeTier1(alias: String, paths: [String]) async -> PreparedTransfer? {
        var args = [alias, "find"]
        args.append(contentsOf: paths)
        args.append(contentsOf: ["-type", "f", "-printf", "%s %f\\n"])
        do {
            let r = try await run(exec: "/usr/bin/ssh", args: args)
            guard let s = RemoteSizeProbe.parseFindPrintf(r.stdout) else { return nil }
            return PreparedTransfer(totalBytes: s.totalBytes, totalFiles: s.totalFiles,
                                    lookup: s.lookup, sizeKnowledge: .full)
        } catch { return nil }
    }

    private func probeTier2(alias: String, paths: [String]) async -> PreparedTransfer? {
        do {
            var cArgs = [alias, "find"]; cArgs.append(contentsOf: paths); cArgs.append(contentsOf: ["-type", "f"])
            let count = RemoteSizeProbe.parseFindFileCount(
                try await run(exec: "/usr/bin/ssh", args: cArgs).stdout)
            guard count > 0 else { return nil }

            var dArgs = [alias, "du", "-sk"]; dArgs.append(contentsOf: paths)
            let duOut = try await run(exec: "/usr/bin/ssh", args: dArgs).stdout
            guard let kb = RemoteSizeProbe.parseDuTotalKB(duOut) else { return nil }
            return PreparedTransfer(totalBytes: kb * 1024, totalFiles: count,
                                    lookup: [:], sizeKnowledge: .totalsOnly)
        } catch { return nil }
    }
```

**Step 3:** Build → SUCCEED. **Step 4:** Commit `feat: remote size probe with find/du two-tier fallback`.

---

### Task 7: `TransferTracker`

**Files:** Create `Sources/FastSCP/TransferTracker.swift`

**Step 1: Implement**

```swift
import Foundation
import Combine
import FastSCPCore

@MainActor
final class TransferTracker: ObservableObject {
    @Published private(set) var progress: TransferProgress
    let direction: TransferDirection

    private let selections: [URL]
    private let remote: (alias: String, path: String, names: [String])?
    private var aggregator: TransferAggregator
    private var prepared = false

    /// Send initializer: local scan.
    init(sendSelections selections: [URL]) {
        self.direction = .send
        self.selections = selections
        self.remote = nil
        self.aggregator = TransferAggregator(direction: .send, totalBytes: 0, totalFiles: 0)
        self.progress = aggregator.progress
    }

    /// Receive initializer: remote probe.
    init(receiveAlias alias: String, remotePath: String, names: [String]) {
        self.direction = .receive
        self.selections = []
        self.remote = (alias, remotePath, names)
        self.aggregator = TransferAggregator(direction: .receive, totalBytes: 0, totalFiles: 0)
        self.progress = aggregator.progress
    }

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        let prep: PreparedTransfer
        switch direction {
        case .send:
            prep = await Task.detached(priority: .userInitiated) {
                LocalScanner.scan(urls: self.selections)
            }.value
        case .receive:
            guard let r = remote else {
                prep = PreparedTransfer(totalBytes: 0, totalFiles: 0, lookup: [:], sizeKnowledge: .unknown)
                break
            }
            prep = await SSHExecutor.shared.probeRemoteSizes(alias: r.alias, remotePath: r.path, names: r.names)
        }
        aggregator = TransferAggregator(direction: direction,
                                        totalBytes: prep.totalBytes,
                                        totalFiles: prep.totalFiles,
                                        fileSizeLookup: prep.lookup,
                                        sizeKnowledge: prep.sizeKnowledge)
        progress = aggregator.progress
    }

    func start() { aggregator.startSending(); progress = aggregator.progress }

    func ingest(_ event: SCPProgress?) {
        guard let p = event else { return }
        aggregator.ingest(ParsedProgress(percent: Double(p.percent)/100.0,
                                         fileName: p.fileName,
                                         rateBytesPerSec: p.rateBytesPerSec))
        progress = aggregator.progress
    }

    func complete() { aggregator.complete(); progress = aggregator.progress }
    func fail(_ m: String) { aggregator.fail(m); progress = aggregator.progress }
}

private enum LocalScanner {
    static func scan(urls: [URL]) -> PreparedTransfer {
        var total: Int64 = 0; var count = 0; var lookup: [String: Int64] = [:]
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        for root in urls {
            count += 1
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                for case let url as URL in e {
                    let rv = try? url.resourceValues(forKeys: Set(keys))
                    if rv?.isSymbolicLink == true || rv?.isDirectory == true { continue }
                    let size = Int64(rv?.fileSize ?? 0)
                    total += size
                    lookup[url.lastPathComponent] = size
                }
            }
        }
        return PreparedTransfer(totalBytes: total, totalFiles: count, lookup: lookup, sizeKnowledge: .full)
    }
}
```

**Step 2:** Build → SUCCEED. **Step 3:** Commit `feat(app): TransferTracker with local scan / remote probe`.

---

## Phase 4 — Shared progress view + panel wiring

### Task 8: `TransferStatusView`

**Files:** Create `Sources/FastSCP/TransferStatusView.swift`

**Step 1: Implement**

```swift
import SwiftUI
import FastSCPCore

struct TransferStatusView: View {
    @ObservedObject var tracker: TransferTracker
    let alias: String
    let path: String
    var onCancel: () -> Void

    private var p: TransferProgress { tracker.progress }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: p.direction == .send ? "arrow.up.circle" : "arrow.down.circle")
                .font(.system(size: 36)).foregroundStyle(.tint)
            Text(headline).font(.system(size: 13)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            if p.sizeKnowledge == .unknown {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: p.percent).progressViewStyle(.linear)
            }

            HStack { Text(percentText).monospacedDigit(); Spacer() }.font(.caption)

            HStack(spacing: 8) {
                Text(sizeAndRateText).monospacedDigit()
                Spacer()
                if let eta = etaText { Text(eta).monospacedDigit() }
            }
            .font(.caption2).foregroundStyle(.secondary)

            Divider()
            HStack {
                if p.totalFiles > 0 {
                    Text("第 \(max(p.currentFileIndex,1)) / \(p.totalFiles) 个文件")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(p.currentFileName ?? "—").font(.system(size: 12)).lineLimit(1)
                .truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button("取消传输", role: .cancel) { onCancel() }.buttonStyle(.bordered)
        }
        .padding(14)
    }

    private var headline: String {
        p.direction == .send
            ? "正在传输到 \(alias):\(path)"
            : "正在接收自 \(alias):\(path)"
    }
    private var percentText: String { "\(Int(p.percent * 100))%" }
    private var sizeAndRateText: String {
        let rate = p.rateBytesPerSec.map { ByteFormat.rate($0) } ?? "—"
        switch p.sizeKnowledge {
        case .full:
            return "\(ByteFormat.size(p.completedBytes)) / \(ByteFormat.size(p.totalBytes)) · \(rate)"
        case .totalsOnly, .unknown:
            return rate
        }
    }
    private var etaText: String? {
        guard let s = p.etaSeconds, s > 0 else { return nil }
        if s >= 3600 { return "剩余 > 1 小时" }
        let m = s/60, r = s%60
        return m > 0 ? "剩余 \(m) 分 \(r) 秒" : "剩余 \(r) 秒"
    }
}
```

**Step 2:** Build → SUCCEED. **Step 3:** Commit `feat(app): shared direction-aware TransferStatusView`.

---

### Task 9: Wire `DestinationPanel` (send)

**Files:** Modify `Sources/FastSCP/DestinationPanel.swift`

**Step 1:** Add `@Published var tracker: TransferTracker?` to `DestinationViewModel`. Delete `@Published var progressText: String?` and all its uses.

Replace `performTransfer` with:

```swift
    func performTransfer(alias: String, path: String) async {
        let t = TransferTracker(sendSelections: selections)
        self.tracker = t
        await t.prepare(); t.start()
        do {
            try await SSHExecutor.shared.transfer(alias: alias, path: path, sources: selections) { p in
                Task { @MainActor in t.ingest(p) }
            }
            t.complete()
            RecentStore.shared().record(.init(alias: alias, remotePath: path, timestamp: Date()))
            Notifier.send(title: "FastSCP", body: "已发送 \(selections.count) 项到 \(alias):\(path)")
            onClose?()
        } catch {
            t.fail(SSHErrorMapper.friendlyMessage(for: error))
        }
    }
    func cancelTransfer() { SSHExecutor.shared.cancel() }
```

**Step 2:** In `DestinationView.body`, replace the `if let p = viewModel.progressText { ... }` block with:

```swift
                if let t = viewModel.tracker {
                    switch t.progress.phase {
                    case .sending, .preparing:
                        TransferStatusView(tracker: t, alias: viewModel.selectedAlias,
                                           path: viewModel.currentPath,
                                           onCancel: { viewModel.cancelTransfer() })
                    case .failed(let msg):
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("传输失败").font(.headline)
                            Text(msg).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                            Button("关闭", role: .cancel) { onClose() }
                        }.padding(.top, 8)
                    case .done:
                        EmptyView()
                    }
                }
```

In `footer`, remove `|| viewModel.progressText != nil` from the `.disabled(...)`.

**Step 3:** Build → SUCCEED. **Step 4:** Commit `feat(app): send panel uses TransferTracker + cancel`.

---

### Task 10: Wire `ReceivePanel` (receive)

**Files:** Modify `Sources/FastSCP/ReceivePanel.swift`

**Step 1:** Add `@Published var tracker: TransferTracker?` to `ReceiveViewModel`. Delete `progressText` and its uses.

Replace `performPull` with:

```swift
    func performPull() async {
        let names = entries.filter { selectedNames.contains($0.name) }.map(\.name)
        let t = TransferTracker(receiveAlias: selectedAlias, remotePath: currentPath, names: names)
        self.tracker = t
        await t.prepare(); t.start()
        do {
            try await SSHExecutor.shared.pull(alias: selectedAlias, remotePath: currentPath,
                                              names: names, localDest: destURL) { p in
                Task { @MainActor in t.ingest(p) }
            }
            t.complete()
            RecentStore.sharedReceive().record(
                .init(alias: selectedAlias, remotePath: currentPath, timestamp: Date()))
            Notifier.send(title: "FastSCP", body: "已接收 \(names.count) 项到 \(destURL.path)")
            onClose?()
        } catch {
            t.fail(SSHErrorMapper.friendlyMessage(for: error))
        }
    }
    func cancelTransfer() { SSHExecutor.shared.cancel() }
```

**Step 2:** In `ReceiveView.body`, replace the `if let p = viewModel.progressText { ... }` block with the same transfer/failed switch as Task 9 (using `TransferStatusView` with `tracker`, `alias: viewModel.selectedAlias`, `path: viewModel.currentPath`, `onCancel: { viewModel.cancelTransfer() }`). Remove `|| viewModel.progressText != nil` from footer `.disabled`.

**Step 3:** Build → SUCCEED. **Step 4:** Commit `feat(app): receive panel uses TransferTracker + cancel`.

---

## Phase 5 — Quick-send HUD

### Task 11: `QuickTransferHUDController`

**Files:** Create `Sources/FastSCP/QuickTransferHUDController.swift`

**Step 1: Implement**

```swift
import AppKit
import SwiftUI
import FastSCPCore

@MainActor
final class QuickTransferHUDController {
    private var window: NSPanel?
    private let tracker: TransferTracker
    private let alias: String
    private let path: String

    init(tracker: TransferTracker, alias: String, path: String) {
        self.tracker = tracker; self.alias = alias; self.path = path
    }

    func show() {
        let host = NSHostingController(rootView: HUDView(tracker: tracker, alias: alias, path: path) { [weak self] in
            self?.dismiss()
        })
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.borderless]
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setContentSize(NSSize(width: 320, height: 120))
        if let screen = NSScreen.main {
            let v = screen.visibleFrame, s = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: v.maxX - s.width - 16, y: v.maxY - s.height - 16))
        }
        self.window = panel
        panel.orderFrontRegardless()
        observe()
    }

    private func observe() {
        Task { @MainActor [weak self] in
            while let self, self.window != nil {
                switch self.tracker.progress.phase {
                case .done:
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    self.fadeOut()
                    return
                case .failed:
                    return   // stay until user closes
                default:
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    private func fadeOut() {
        guard let panel = window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in self?.dismiss() }
    }

    func dismiss() {
        window?.orderOut(nil); window = nil
    }
}

private struct HUDView: View {
    @ObservedObject var tracker: TransferTracker
    let alias: String
    let path: String
    var onClose: () -> Void
    private var p: TransferProgress { tracker.progress }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch p.phase {
            case .preparing:
                row(icon: "arrow.up.circle", title: "准备中 \(alias):\(path)")
                ProgressView().progressViewStyle(.linear)
                Text("正在统计文件…").font(.caption2).foregroundStyle(.secondary)
            case .sending:
                row(icon: "arrow.up.circle", title: "正在传输 \(alias):\(path)",
                    trailing: "\(Int(p.percent*100))%")
                if p.sizeKnowledge == .unknown {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: p.percent).progressViewStyle(.linear)
                }
                HStack(spacing: 6) {
                    Text(p.sizeKnowledge == .full
                         ? "\(ByteFormat.size(p.completedBytes)) / \(ByteFormat.size(p.totalBytes))"
                         : "传输中").font(.caption2).monospacedDigit()
                    if let r = p.rateBytesPerSec { Text("· \(ByteFormat.rate(r))").font(.caption2).monospacedDigit() }
                    Spacer()
                }
                if p.totalFiles > 0 {
                    Text("第 \(max(p.currentFileIndex,1)) / \(p.totalFiles) 个 · \(p.currentFileName ?? "")")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            case .done:
                row(icon: "checkmark.circle.fill", color: .green, title: "已发送到 \(alias):\(path)")
            case .failed(let msg):
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("传输失败").font(.system(size: 12, weight: .semibold)); Spacer()
                }
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                HStack { Spacer(); Button("关闭") { onClose() }.controlSize(.small) }
            }
        }
        .padding(12).frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.black.opacity(0.1), lineWidth: 0.5))
    }

    private func row(icon: String, color: Color = .accentColor, title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let t = trailing { Text(t).font(.caption).monospacedDigit() }
        }
    }
}
```

**Step 2:** Build → SUCCEED. **Step 3:** Commit `feat(app): top-right floating HUD for quick-send progress`.

---

### Task 12: Wire `AppDelegate.runQuick` to the HUD

**Files:** Modify `Sources/FastSCP/AppDelegate.swift`

**Step 1:** Replace `runQuick` with:

```swift
    private func runQuick(_ req: URLCoordinator.QuickRequest) {
        Task { @MainActor in
            let tracker = TransferTracker(sendSelections: req.selections)
            let hud = QuickTransferHUDController(tracker: tracker, alias: req.alias, path: req.remotePath)
            hud.show()
            await tracker.prepare(); tracker.start()
            do {
                try await SSHExecutor.shared.transfer(
                    alias: req.alias, path: req.remotePath, sources: req.selections
                ) { p in Task { @MainActor in tracker.ingest(p) } }
                tracker.complete()
                RecentStore.shared().record(.init(alias: req.alias, remotePath: req.remotePath, timestamp: Date()))
            } catch {
                tracker.fail(SSHErrorMapper.friendlyMessage(for: error))
            }
        }
    }
```

(The HUD auto-closes on success; on failure it stays. Removed both `Notifier.send` calls.)

**Step 2:** Build → SUCCEED. **Step 3:** Commit `feat(app): quick-send uses TransferTracker + HUD, drops notification`.

---

## Phase 6 — Verify

### Task 13: Full test suite + build + manual

**Step 1:** `xcodebuild test -project FastSCP.xcodeproj -scheme FastSCPCore -destination 'platform=macOS'` → ALL PASS.

**Step 2:** `xcodebuild -project FastSCP.xcodeproj -scheme FastSCP -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual` → SUCCEED.

**Step 3:** `./scripts/execute.sh` to install to /Applications, then manual matrix:
- Send single/multi file via popup → byte-based bar, cancel, error.
- Quick-send single/multi → HUD top-right, auto-close, error stays.
- Receive single/multi from a Linux server → `.full` byte-based bar.
- Receive from a non-GNU host (or simulated) → `.totalsOnly` / `.unknown` graceful.
- Existing: recent lists (send & receive), menus, About, no duplicate extension registrations.

**Step 4:** Commit any cleanup `chore: post-progress cleanup` (or skip if clean).

---

## Out of scope

- Concurrent transfers / queue; multi-HUD.
- HUD cancel button; headless receive.
- Finder Sync extension changes.
- `rsync` / resume.

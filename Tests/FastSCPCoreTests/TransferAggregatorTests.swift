import XCTest
@testable import FastSCPCore

final class TransferAggregatorTests: XCTestCase {
    func testInitialPreparingAndZero() {
        let a = TransferAggregator(direction: .send, totalBytes: 1000, totalFiles: 1)
        XCTAssertEqual(a.progress.percent, 0)
        if case .preparing = a.progress.phase {} else { XCTFail("expected preparing") }
    }

    // MARK: - Real byte accumulation (both directions)

    func testSingleFileAccumulatesTransferredBytes() {
        var a = TransferAggregator(direction: .send, totalBytes: 10_000_000, totalFiles: 1)
        a.startSending()
        a.ingest(.init(percent: 0.3, transferredBytes: 3_000_000,
                       fileName: "a.bin", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.completedBytes, 3_000_000)
        a.ingest(.init(percent: 0.7, transferredBytes: 7_000_000,
                       fileName: "a.bin", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.completedBytes, 7_000_000)
        a.complete()
        XCTAssertEqual(a.progress.completedBytes, 10_000_000)
        XCTAssertEqual(a.progress.percent, 1.0)
    }

    func testMultiFileCreditsPreviousFileThenAddsCurrent() {
        // a.bin = 6,000,000; b.bin = 4,000,000; total = 10,000,000.
        var a = TransferAggregator(direction: .receive, totalBytes: 10_000_000, totalFiles: 2)
        a.startSending()
        a.ingest(.init(percent: 1.0, transferredBytes: 6_000_000,
                       fileName: "a.bin", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.currentFileIndex, 1)
        // Switching to b credits a.bin's last observed bytes.
        a.ingest(.init(percent: 0.5, transferredBytes: 2_000_000,
                       fileName: "b.bin", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.currentFileIndex, 2)
        XCTAssertEqual(a.progress.completedBytes, 8_000_000) // 6M + 2M
        a.ingest(.init(percent: 1.0, transferredBytes: 4_000_000,
                       fileName: "b.bin", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.completedBytes, 10_000_000)
        a.complete()
        XCTAssertEqual(a.progress.percent, 1.0)
    }

    func testTransferredBytesNeverRegress() {
        var a = TransferAggregator(direction: .send, totalBytes: 10_000_000, totalFiles: 1)
        a.startSending()
        a.ingest(.init(percent: 0.6, transferredBytes: 6_000_000,
                       fileName: "x", rateBytesPerSec: nil))
        let before = a.progress.completedBytes
        // A later event reporting fewer bytes (jitter/unit rounding) is ignored.
        a.ingest(.init(percent: 0.45, transferredBytes: 4_500_000,
                       fileName: "x", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.completedBytes, before)
    }

    func testMissingTransferredBytesDoesNotCrash() {
        // If scp's size token is unparseable on some line, we keep the last
        // known value rather than resetting to zero.
        var a = TransferAggregator(direction: .send, totalBytes: 10_000_000, totalFiles: 1)
        a.startSending()
        a.ingest(.init(percent: 0.3, transferredBytes: 3_000_000,
                       fileName: "x", rateBytesPerSec: nil))
        a.ingest(.init(percent: 0.4, transferredBytes: nil,
                       fileName: "x", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.completedBytes, 3_000_000)
    }

    func testReceiveTotalsOnlyIsByteBased() {
        // Tier2: we know total bytes (du) and file count, but not per-file
        // sizes. Real transferred bytes from scp still drive the bar.
        var a = TransferAggregator(direction: .receive, totalBytes: 10_000_000,
                                   totalFiles: 2, sizeKnowledge: .totalsOnly)
        a.startSending()
        a.ingest(.init(percent: 1.0, transferredBytes: 6_000_000,
                       fileName: "a", rateBytesPerSec: nil))
        a.ingest(.init(percent: 0.5, transferredBytes: 2_000_000,
                       fileName: "b", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.completedBytes, 8_000_000)
        XCTAssertEqual(a.progress.percent, 0.8)
        a.complete()
        XCTAssertEqual(a.progress.percent, 1.0)
    }

    func testUnknownShowsIndeterminateButStillCountsFiles() {
        var a = TransferAggregator(direction: .receive, totalBytes: 0, totalFiles: 0,
                                   sizeKnowledge: .unknown)
        a.startSending()
        a.ingest(.init(percent: 0.5, transferredBytes: 500,
                       fileName: "remote.bin", rateBytesPerSec: 1000))
        XCTAssertEqual(a.progress.currentFileName, "remote.bin")
        XCTAssertEqual(a.progress.percent, 0) // no total → indeterminate
        a.complete()
        XCTAssertEqual(a.progress.percent, 1.0)
    }

    func testEtaFromRate() {
        var a = TransferAggregator(direction: .send, totalBytes: 1_000_000, totalFiles: 1)
        a.startSending()
        a.ingest(.init(percent: 0, transferredBytes: 0, fileName: "a", rateBytesPerSec: 100_000))
        // After 0 bytes at 100KB/s → 10s remaining.
        XCTAssertEqual(a.progress.etaSeconds, 10)
    }

    func testFailKeepsBytesSetsPhase() {
        var a = TransferAggregator(direction: .send, totalBytes: 10_000_000, totalFiles: 1)
        a.startSending()
        a.ingest(.init(percent: 0.5, transferredBytes: 5_000_000,
                       fileName: "a", rateBytesPerSec: nil))
        let before = a.progress.completedBytes
        a.fail("kaboom")
        XCTAssertEqual(a.progress.completedBytes, before)
        if case .failed(let m) = a.progress.phase { XCTAssertEqual(m, "kaboom") } else { XCTFail() }
    }
}

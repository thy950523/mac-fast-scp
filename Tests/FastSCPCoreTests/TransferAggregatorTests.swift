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
        let lookup: [String: Int64] = ["a.bin": 600, "b.bin": 400]
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

    func testTotalsOnlyAdvancesByFileRatio() {
        var a = TransferAggregator(direction: .receive, totalBytes: 1000, totalFiles: 2,
                                   sizeKnowledge: .totalsOnly)
        a.startSending()
        a.ingest(.init(percent: 1.0, fileName: "a", rateBytesPerSec: nil))
        XCTAssertEqual(a.progress.completedBytes, 500)
        a.ingest(.init(percent: 0.5, fileName: "b", rateBytesPerSec: nil))
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
}

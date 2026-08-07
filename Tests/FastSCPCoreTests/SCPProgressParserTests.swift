import XCTest
@testable import FastSCPCore

final class SCPProgressParserTests: XCTestCase {
    func testParsesCompletePercentLine() {
        let line = "\rREADME.md                                    100%   12KB 123.4KB/s   0:00:00"
        let p = SCPProgressParser.parse(line)
        XCTAssertEqual(p?.percent, 100)
        XCTAssertFalse(p?.detail.isEmpty ?? true)
    }

    func testParsesMidProgress() {
        let line = "\rbig.bin                                      45%  450MB  10.0MB/s   0:00:05"
        XCTAssertEqual(SCPProgressParser.parse(line)?.percent, 45)
    }

    func testIgnoresLinesWithoutPercent() {
        XCTAssertNil(SCPProgressParser.parse("some random stderr noise"))
        XCTAssertNil(SCPProgressParser.parse(""))
    }

    func testRejectsPercentOver100() {
        XCTAssertNil(SCPProgressParser.parse("foo 150% bad"))
    }

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

    func testParsesTransferredBytes() {
        // The token after percent is the current file's transferred bytes.
        let p = SCPProgressParser.parse("\rbig.bin  45%  450MB  10.0MB/s   0:00:05")
        XCTAssertEqual(p?.fileTransferredBytes, 450 * 1024 * 1024)
    }

    func testParsesTransferredBytesAtZero() {
        let p = SCPProgressParser.parse("\rf  0%  0  0.0KB/s --:-- ETA")
        XCTAssertEqual(p?.fileTransferredBytes, 0)
    }

    func testParsesTransferredBytesKilo() {
        let p = SCPProgressParser.parse("\rf  100%  4883KB  630.0MB/s 00:00")
        XCTAssertEqual(p?.fileTransferredBytes, 4883 * 1024)
    }

    func testPercentOnlyLineHasNilNameAndRate() {
        let p = SCPProgressParser.parse("42%")
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.percent, 42)
        XCTAssertNil(p?.fileName)
        XCTAssertNil(p?.rateBytesPerSec)
    }

    func testStripsScriptEOTPrefix() {
        // `script -q` emits EOT (0x04) + two backspaces before the first line.
        let line = "\u{04}\u{08}\u{08}\rREADME.md  100%  12KB 123.4KB/s 0:00"
        let p = SCPProgressParser.parse(line)
        XCTAssertEqual(p?.percent, 100)
        XCTAssertEqual(p?.fileName, "README.md")
    }
}

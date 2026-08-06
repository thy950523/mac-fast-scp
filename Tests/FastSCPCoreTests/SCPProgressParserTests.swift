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
}

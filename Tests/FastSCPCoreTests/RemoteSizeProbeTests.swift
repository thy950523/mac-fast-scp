import XCTest
@testable import FastSCPCore

final class RemoteSizeProbeTests: XCTestCase {
    func testParseFindPrintf() {
        // `find -printf '%s %f\n'` → %f is basename (directories stripped).
        let out = "12345 readme.md\n67890 app.log\n"
        let r = RemoteSizeProbe.parseFindPrintf(out)
        XCTAssertEqual(r?.totalBytes, 80235)
        XCTAssertEqual(r?.totalFiles, 2)
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
        XCTAssertEqual(RemoteSizeProbe.parseDuTotalKB("12345\t/var/www"), 12345)
    }

    func testParseDuTotalSumsMultiplePaths() {
        // Called without -c: one line per path on both GNU and BSD du.
        let out = "100\t/a\n200\t/b\n"
        XCTAssertEqual(RemoteSizeProbe.parseDuTotalKB(out), 300)
    }

    func testParseDuTotalIgnoresNonNumeric() {
        XCTAssertEqual(RemoteSizeProbe.parseDuTotalKB("100\t/a\ndu: cannot read '/b'\n"), 100)
    }
}

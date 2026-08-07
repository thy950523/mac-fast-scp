import XCTest
@testable import FastSCPCore

final class ByteFormatTests: XCTestCase {
    func testSize() {
        XCTAssertEqual(ByteFormat.size(0), "0 B")
        XCTAssertEqual(ByteFormat.size(512), "512 B")
        XCTAssertEqual(ByteFormat.size(1024), "1.0 KB")
        XCTAssertEqual(ByteFormat.size(10 * 1024 * 1024), "10.0 MB")
        XCTAssertEqual(ByteFormat.size(Int64(1024) * 1024 * 1024), "1.00 GB")
    }

    func testRate() {
        XCTAssertEqual(ByteFormat.rate(12_000_000), "11.4 MB/s")
    }

    func testNegativeSafe() {
        XCTAssertEqual(ByteFormat.size(-5), "0 B")
        XCTAssertEqual(ByteFormat.rate(-1), "0 B/s")
    }

    func testParseSizeTokens() {
        XCTAssertEqual(ByteFormat.parseSize("0"), 0)
        XCTAssertEqual(ByteFormat.parseSize("512"), 512)
        XCTAssertEqual(ByteFormat.parseSize("12KB"), 12 * 1024)
        XCTAssertEqual(ByteFormat.parseSize("1.5MB"), Int64(1.5 * 1024 * 1024))
        XCTAssertEqual(ByteFormat.parseSize("2GB"), 2 * 1024 * 1024 * 1024)
        XCTAssertNil(ByteFormat.parseSize(""))
        XCTAssertNil(ByteFormat.parseSize("n/a"))
    }
}

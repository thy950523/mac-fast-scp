import XCTest
@testable import FastSCPCore

final class RecentDestinationsTests: XCTestCase {
    private func d(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: "\(iso)T00:00:00Z")!
    }

    func testAddNew() {
        let result = RecentDestinations.add([], .init(alias: "s1", remotePath: "/a", timestamp: d("2026-08-06")))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].alias, "s1")
    }

    func testDedupUpdatesTimestampAndMovesFirst() {
        let old = RecentDestination(alias: "s1", remotePath: "/a", timestamp: d("2026-08-01"))
        let r = RecentDestinations.add([old], .init(alias: "s1", remotePath: "/a", timestamp: d("2026-08-06")))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].timestamp, d("2026-08-06"))
    }

    func testSameAliasDifferentPathKeepsOneEntry() {
        let old = RecentDestination(alias: "s1", remotePath: "/a", timestamp: d("2026-08-01"))
        let r = RecentDestinations.add([old], .init(alias: "s1", remotePath: "/b", timestamp: d("2026-08-06")))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].remotePath, "/b")
    }

    func testNewEntryGoesFirst() {
        let existing = [RecentDestination(alias: "s1", remotePath: "/a", timestamp: d("2026-08-01"))]
        let r = RecentDestinations.add(existing, .init(alias: "s2", remotePath: "/b", timestamp: d("2026-08-06")))
        XCTAssertEqual(r.map(\.alias), ["s2", "s1"])
    }

    func testCapAtMax() {
        var list: [RecentDestination] = []
        for i in 0..<7 {
            list = RecentDestinations.add(list, .init(alias: "s\(i)", remotePath: "/p", timestamp: d("2026-08-0\(i + 1)")))
        }
        XCTAssertEqual(list.count, FastSCPConfig.maxRecentDestinations)
        XCTAssertEqual(list.first?.alias, "s6")
    }

    func testMaxIsThree() {
        XCTAssertEqual(FastSCPConfig.maxRecentDestinations, 3)
    }

    func testNormalizeSortsByTimestampDedupesAndTruncates() {
        let raw = [
            RecentDestination(alias: "s1", remotePath: "/old", timestamp: d("2026-08-01")),
            RecentDestination(alias: "s2", remotePath: "/b", timestamp: d("2026-08-05")),
            RecentDestination(alias: "s1", remotePath: "/new", timestamp: d("2026-08-06")),
            RecentDestination(alias: "s3", remotePath: "/c", timestamp: d("2026-08-04")),
            RecentDestination(alias: "s4", remotePath: "/d", timestamp: d("2026-08-03")),
        ]
        let r = RecentDestinations.normalize(raw)
        XCTAssertEqual(r.map(\.alias), ["s1", "s2", "s3"])
        XCTAssertEqual(r[0].remotePath, "/new")
    }
}

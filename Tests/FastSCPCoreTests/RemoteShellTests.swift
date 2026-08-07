import XCTest
@testable import FastSCPCore

/// Pins the exact output of `RemoteShell.quote` and the basename guard. The
/// quoting is safety-critical for remote `rm`: a regression that produced an
/// empty/degenerate token once expanded `rm -rf` to the entire home directory.
final class RemoteShellTests: XCTestCase {

    // MARK: quote

    func testQuoteTildeAlone() {
        XCTAssertEqual(RemoteShell.quote("~"), "$HOME")
    }

    func testQuoteTildeSlashSingleSegment() {
        XCTAssertEqual(RemoteShell.quote("~/x"), "$HOME'/x'")
    }

    func testQuoteTildeSlashNested() {
        XCTAssertEqual(RemoteShell.quote("~/a/b/c"), "$HOME'/a/b/c'")
    }

    func testQuoteAbsolute() {
        XCTAssertEqual(RemoteShell.quote("/abs/path"), "'/abs/path'")
    }

    func testQuoteParensInName() {
        XCTAssertEqual(RemoteShell.quote("~/fonts(1)(1).zip"), "$HOME'/fonts(1)(1).zip'")
    }

    func testQuoteSpacesInName() {
        XCTAssertEqual(RemoteShell.quote("~/name with space.txt"), "$HOME'/name with space.txt'")
    }

    func testQuoteNeverReturnsEmptyForNonEmptyInput() {
        // The exact failure mode that caused the home-dir wipe was an empty body.
        ["~/alpha.txt", "~", "/x", "~/a b/c"].forEach {
            XCTAssertFalse(RemoteShell.quote($0).isEmpty, "quote(\($0)) was empty")
        }
    }

    func testQuoteAlwaysEmbedsTheBasenameForCollisions() {
        // removeRemoteEntries relies on the quoted path still containing the name.
        for name in ["alpha.txt", "fonts(1)(1).zip", "name with space.txt"] {
            let q = RemoteShell.quote("~/fastscp-verify/\(name)")
            XCTAssertTrue(q.contains(name), "quote did not embed name \(name): \(q)")
        }
    }

    // MARK: isSafeBasename

    func testSafeBasenameAcceptsPlainNames() {
        XCTAssertTrue(RemoteShell.isSafeBasename("alpha.txt"))
        XCTAssertTrue(RemoteShell.isSafeBasename("fonts(1)(1).zip"))
        XCTAssertTrue(RemoteShell.isSafeBasename("name with space.txt"))
    }

    func testSafeBasenameRejectsTraversalAndEmpty() {
        XCTAssertFalse(RemoteShell.isSafeBasename(""), "empty rejected")
        XCTAssertFalse(RemoteShell.isSafeBasename("."), ". rejected")
        XCTAssertFalse(RemoteShell.isSafeBasename(".."), ".. rejected")
        XCTAssertFalse(RemoteShell.isSafeBasename("a/b"), "slash rejected")
        XCTAssertFalse(RemoteShell.isSafeBasename("../etc"), "traversal rejected")
        XCTAssertFalse(RemoteShell.isSafeBasename("/etc/passwd"), "absolute rejected")
        XCTAssertFalse(RemoteShell.isSafeBasename("   "), "whitespace-only rejected")
    }
}

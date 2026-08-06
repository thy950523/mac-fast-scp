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
        XCTAssertEqual(LsParser.parse(out), [
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

    func testBlankLinesIgnored() {
        XCTAssertEqual(LsParser.parse("\n\nfile.txt\n\n"), [
            RemoteEntry(name: "file.txt", isDirectory: false),
        ])
    }
}

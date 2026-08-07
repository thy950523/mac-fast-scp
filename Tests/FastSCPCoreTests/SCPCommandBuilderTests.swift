import XCTest
@testable import FastSCPCore

final class SCPCommandBuilderTests: XCTestCase {
    func testPullArgsBasic() {
        let dest = URL(fileURLWithPath: "/Users/x/work")
        let args = SCPCommandBuilder.pullArgs(
            alias: "server1", remotePath: "/var/log",
            names: ["access.log", "app"], localDest: dest)
        XCTAssertEqual(args, ["-r", "server1:/var/log/access.log", "server1:/var/log/app", "/Users/x/work/"])
    }

    func testPullArgsStripsTrailingSlashOnRemotePath() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/var/log/", names: ["a"], localDest: dest)
        XCTAssertEqual(args, ["-r", "s:/var/log/a", "/d/"])
    }

    func testPullArgsHandlesTildeRemotePath() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "~", names: ["x"], localDest: dest)
        XCTAssertEqual(args, ["-r", "s:~/x", "/d/"])
    }

    func testPullArgsPreservesSpacesInNames() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/p", names: ["my file.txt"], localDest: dest)
        XCTAssertEqual(args, ["-r", "s:/p/my file.txt", "/d/"])
    }
}

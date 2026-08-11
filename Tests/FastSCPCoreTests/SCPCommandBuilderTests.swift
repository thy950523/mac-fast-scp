import XCTest
@testable import FastSCPCore

final class SCPCommandBuilderTests: XCTestCase {
    func testPullArgsBasic() {
        let dest = URL(fileURLWithPath: "/Users/x/work")
        let args = SCPCommandBuilder.pullArgs(
            alias: "server1", remotePath: "/var/log",
            names: ["access.log", "app"], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O", "server1:/var/log/access.log", "server1:/var/log/app", "/Users/x/work/"])
    }

    func testPullArgsStripsTrailingSlashOnRemotePath() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/var/log/", names: ["a"], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O", "s:/var/log/a", "/d/"])
    }

    func testPullArgsHandlesTildeRemotePath() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "~", names: ["x"], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O", "s:~/x", "/d/"])
    }

    func testPullArgsPreservesSpacesInNames() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/p", names: ["my file.txt"], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O", "s:/p/my file.txt", "/d/"])
    }

    /// `-O` 强制 legacy SCP 协议。缺了它 scp 走 SFTP，进度行的字节计数器
    /// 不递增（实测卡在 3% 直到结束），进度条形同虚设。
    func testPullArgsAlwaysIncludesLegacyProtocolFlag() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/p", names: ["a"], localDest: dest)
        XCTAssertTrue(args.contains("-O"))
    }
}

import XCTest
@testable import FastSCPCore

final class SCPCommandBuilderTests: XCTestCase {

    // MARK: - pullArgs (receive: scp remote→local)

    func testPullArgsBasic() {
        let dest = URL(fileURLWithPath: "/Users/x/work")
        let args = SCPCommandBuilder.pullArgs(
            alias: "server1", remotePath: "/var/log",
            names: ["access.log", "app"], localDest: dest)
        // 远端路径经 RemoteShell.quote 单引号包裹，过远端 shell 时不被元字符破坏。
        XCTAssertEqual(args, ["-r", "-O",
            "server1:'/var/log/access.log'", "server1:'/var/log/app'", "/Users/x/work/"])
    }

    func testPullArgsStripsTrailingSlashOnRemotePath() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/var/log/", names: ["a"], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O", "s:'/var/log/a'", "/d/"])
    }

    func testPullArgsHandlesTildeRemotePath() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "~", names: ["x"], localDest: dest)
        // `~` 必须转成 `$HOME` 留在引号外，否则单引号会让远端 shell 把它当字面量。
        XCTAssertEqual(args, ["-r", "-O", "s:$HOME'/x'", "/d/"])
    }

    func testPullArgsQuotesSpacesInNames() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/p", names: ["my file.txt"], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O", "s:'/p/my file.txt'", "/d/"])
    }

    /// Regression（实测 2026-08-11 的接收秒败）：远端文件名里的 ASCII 括号让
    /// legacy scp 在远端 bash 上 `syntax error near unexpected token '('`，
    /// 进程立刻退出 → 既无实时进度，取消也只剩 `process=false`。pullArgs 必须
    /// 把远端路径整体转义。
    func testPullArgsQuotesParensInName() {
        let dest = URL(fileURLWithPath: "/d")
        let name = "像高手一样 ( etc.) (z-library.sk, 1lib.sk).epub"
        let args = SCPCommandBuilder.pullArgs(
            alias: "agent", remotePath: "~/xferdir", names: [name], localDest: dest)
        XCTAssertEqual(args, ["-r", "-O",
            "agent:$HOME'/xferdir/像高手一样 ( etc.) (z-library.sk, 1lib.sk).epub'", "/d/"])
    }

    /// 转义后，文件名仍须原样嵌在引号串里——removeRemoteEntries 依赖这点，
    /// scp 远端 `scp -f` 也只认原始文件名。
    func testPullArgsStillEmbedsNameAfterQuoting() {
        let dest = URL(fileURLWithPath: "/d")
        for name in ["alpha.txt", "fonts(1)(1).zip", "name with space.txt"] {
            let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "~/d", names: [name], localDest: dest)
            XCTAssertTrue(args.contains { $0.contains(name) }, "pullArgs did not embed name \(name): \(args)")
        }
    }

    /// `-O` 强制 legacy SCP 协议。缺了它 scp 走 SFTP，进度行的字节计数器
    /// 不递增（实测卡在 3% 直到结束），进度条形同虚设。
    func testPullArgsAlwaysIncludesLegacyProtocolFlag() {
        let dest = URL(fileURLWithPath: "/d")
        let args = SCPCommandBuilder.pullArgs(alias: "s", remotePath: "/p", names: ["a"], localDest: dest)
        XCTAssertTrue(args.contains("-O"))
    }

    // MARK: - sendArgs (send: scp local→remote)

    func testSendArgsBasic() {
        let src = URL(fileURLWithPath: "/Users/x/a.txt")
        let args = SCPCommandBuilder.sendArgs(alias: "server1", remotePath: "/var/log", sources: [src])
        XCTAssertEqual(args, ["-r", "-O", "/Users/x/a.txt", "server1:'/var/log/'"])
    }

    func testSendArgsNormalizesMissingTrailingSlash() {
        let src = URL(fileURLWithPath: "/a.txt")
        let args = SCPCommandBuilder.sendArgs(alias: "s", remotePath: "/var/log", sources: [src])
        // 尾斜杠让 scp 把文件「放进」该目录，而非当成新文件名；规范化发生在转义之前。
        XCTAssertEqual(args, ["-r", "-O", "/a.txt", "s:'/var/log/'"])
    }

    func testSendArgsKeepsExistingTrailingSlash() {
        let src = URL(fileURLWithPath: "/a.txt")
        let args = SCPCommandBuilder.sendArgs(alias: "s", remotePath: "/var/log/", sources: [src])
        XCTAssertEqual(args, ["-r", "-O", "/a.txt", "s:'/var/log/'"])
    }

    func testSendArgsTildeRemotePath() {
        let src = URL(fileURLWithPath: "/a.txt")
        let args = SCPCommandBuilder.sendArgs(alias: "s", remotePath: "~/xferdir", sources: [src])
        XCTAssertEqual(args, ["-r", "-O", "/a.txt", "s:$HOME'/xferdir/'"])
    }

    /// 发送方向同样的潜在缺陷：远端目标目录带空格/括号时也必须转义。
    func testSendArgsQuotesSpacesAndParensInRemotePath() {
        let src = URL(fileURLWithPath: "/a.txt")
        let args = SCPCommandBuilder.sendArgs(alias: "s", remotePath: "~/my (1) dir", sources: [src])
        XCTAssertEqual(args, ["-r", "-O", "/a.txt", "s:$HOME'/my (1) dir/'"])
    }
}

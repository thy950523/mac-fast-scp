import XCTest
@testable import FastSCPCore

final class SSHConfigParserTests: XCTestCase {
    func testParsesSingleHostWithFields() {
        let text = """
        Host server1
            HostName 10.0.0.5
            User ubuntu
            Port 2222
        """
        XCTAssertEqual(SSHConfigParser.parse(text), [
            SSHHost(alias: "server1", hostName: "10.0.0.5", user: "ubuntu", port: 2222)
        ])
    }

    func testSkipsWildcardHosts() {
        let text = """
        Host *.example.com
            User deploy
        Host server2
            HostName s2.example.com
        """
        XCTAssertEqual(SSHConfigParser.parse(text).map(\.alias), ["server2"])
    }

    func testSkipsHostIfAnyAliasIsWildcard() {
        let text = """
        Host charlie *.x
            HostName c.x
        Host delta
            HostName d.b
        """
        XCTAssertEqual(SSHConfigParser.parse(text).map(\.alias), ["delta"])
    }

    func testIgnoresEmptyAndComments() {
        let text = """
        # a comment

        Host gamma
            # inline comment
            HostName g.b

        Host delta
            HostName d.b
        """
        XCTAssertEqual(SSHConfigParser.parse(text).map(\.alias), ["gamma", "delta"])
    }

    func testIsCaseInsensitiveForKeys() {
        let text = """
        Host zeta
            hostname z.b
            USER root
            PORT 22
        """
        XCTAssertEqual(SSHConfigParser.parse(text), [
            SSHHost(alias: "zeta", hostName: "z.b", user: "root", port: 22)
        ])
    }

    func testEmptyInput() {
        XCTAssertTrue(SSHConfigParser.parse("").isEmpty)
    }
}

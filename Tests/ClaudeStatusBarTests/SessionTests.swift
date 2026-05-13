import XCTest
@testable import ClaudeStatusBar

final class SessionTests: XCTestCase {

    func testDecodesBusySession() throws {
        let json = #"""
        {"pid":64199,"sessionId":"0b5263d6-45a9-451b-8455-36fa61b2eb5d","cwd":"/Users/me/proj","startedAt":1778661605178,"procStart":"Wed May 13 08:40:04 2026","version":"2.1.140","peerProtocol":1,"kind":"interactive","entrypoint":"cli","status":"busy","updatedAt":1778669494835}
        """#.data(using: .utf8)!

        let s = try JSONDecoder().decode(Session.self, from: json)

        XCTAssertEqual(s.pid, 64199)
        XCTAssertEqual(s.sessionId, "0b5263d6-45a9-451b-8455-36fa61b2eb5d")
        XCTAssertEqual(s.cwd, "/Users/me/proj")
        XCTAssertEqual(s.status, .busy)
        XCTAssertEqual(s.version, "2.1.140")
        XCTAssertEqual(s.kind, "interactive")
        XCTAssertEqual(s.entrypoint, "cli")
        XCTAssertNil(s.waitingFor)
        XCTAssertEqual(s.startedAt.timeIntervalSince1970, 1778661605.178, accuracy: 0.001)
        XCTAssertEqual(s.updatedAt.timeIntervalSince1970, 1778669494.835, accuracy: 0.001)
    }

    func testDecodesWaitingSessionWithReason() throws {
        let json = #"""
        {"pid":66857,"sessionId":"668cc4a8","cwd":"/x","startedAt":1,"version":"2.1.140","kind":"interactive","entrypoint":"cli","status":"waiting","updatedAt":2,"waitingFor":"dialog open"}
        """#.data(using: .utf8)!

        let s = try JSONDecoder().decode(Session.self, from: json)

        XCTAssertEqual(s.status, .waiting)
        XCTAssertEqual(s.waitingFor, "dialog open")
    }

    func testDecodesIdleSession() throws {
        let json = #"""
        {"pid":1,"sessionId":"a","cwd":"/","startedAt":0,"version":"2","kind":"interactive","entrypoint":"cli","status":"idle","updatedAt":0}
        """#.data(using: .utf8)!

        let s = try JSONDecoder().decode(Session.self, from: json)
        XCTAssertEqual(s.status, .idle)
    }

    func testIgnoresUnknownStatusGracefully() {
        let json = #"""
        {"pid":1,"sessionId":"a","cwd":"/","startedAt":0,"version":"2","kind":"interactive","entrypoint":"cli","status":"flux-capacitor","updatedAt":0}
        """#.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(Session.self, from: json))
    }

    func testIdentifiableUsesPid() throws {
        let json = #"""
        {"pid":42,"sessionId":"a","cwd":"/","startedAt":0,"version":"2","kind":"interactive","entrypoint":"cli","status":"idle","updatedAt":0}
        """#.data(using: .utf8)!

        let s = try JSONDecoder().decode(Session.self, from: json)
        XCTAssertEqual(s.id, 42)
    }
}

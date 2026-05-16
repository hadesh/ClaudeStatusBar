import XCTest
import AppKit
@testable import ClaudeStatusBar

final class SessionRowViewTests: XCTestCase {

    /// Session 是 Decodable-only,memberwise init 不公开。测试用 JSON 路径构造,
    /// 跟 SessionTests 一致。
    private func makeSession(pid: Int = 1234, status: SessionStatus = .busy) -> Session {
        let json = """
        {"pid":\(pid),"sessionId":"sid-\(pid)","cwd":"/tmp/proj","startedAt":1,"version":"2","kind":"interactive","entrypoint":"cli","status":"\(status.rawValue)","updatedAt":2}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    func testIdleSessionDoesNotCreateTerminateButton() {
        let s = makeSession(status: .idle)
        let view = SessionRowView(
            session: s,
            secondary: nil,
            onTerminate: { _ in },
            onClick: {}
        )
        XCTAssertNil(view.terminateButton)
    }

    func testBusySessionCreatesHiddenTerminateButton() {
        let s = makeSession(status: .busy)
        let view = SessionRowView(
            session: s,
            secondary: "▸ Bash",
            onTerminate: { _ in },
            onClick: {}
        )
        XCTAssertNotNil(view.terminateButton)
        XCTAssertTrue(view.terminateButton!.isHidden,
                      "初始未 hover,按钮必须 isHidden")
    }

    func testWaitingSessionCreatesTerminateButton() {
        let s = makeSession(status: .waiting)
        let view = SessionRowView(
            session: s,
            secondary: "⏳ permission",
            onTerminate: { _ in },
            onClick: {}
        )
        XCTAssertNotNil(view.terminateButton)
    }
}

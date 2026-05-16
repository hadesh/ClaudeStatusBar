import XCTest
@testable import ClaudeStatusBar

final class PermissionPromptSessionExitDetectorTests: XCTestCase {

    private func session(pid: Int, sessionId: String, status: SessionStatus) -> Session {
        let json = """
        {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"/x","startedAt":0,"version":"v","kind":"interactive","entrypoint":"cli","status":"\(status.rawValue)","updatedAt":0}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    func testFirstCallSilentlyAbsorbsBaseline() {
        var detector = PermissionPromptSessionExitDetector()
        let exited = detector.detect(in: [
            session(pid: 1, sessionId: "s-1", status: .waiting),
            session(pid: 2, sessionId: "s-2", status: .busy),
        ])
        XCTAssertEqual(exited, Set<String>(), "首帧吸收基线,避免启动时把已经离开 waiting 的会话误报")
    }

    func testRepeatedSameSetReturnsEmpty() {
        var detector = PermissionPromptSessionExitDetector()
        let s = [session(pid: 1, sessionId: "s-1", status: .waiting)]
        _ = detector.detect(in: s)
        XCTAssertEqual(detector.detect(in: s), Set<String>())
        XCTAssertEqual(detector.detect(in: s), Set<String>())
    }

    func testWaitingThenIdleReturnsExitedSessionId() {
        var detector = PermissionPromptSessionExitDetector()
        _ = detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .waiting)])
        let exited = detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .idle)])
        XCTAssertEqual(exited, ["s-1"])
    }

    func testWaitingThenBusyReturnsExitedSessionId() {
        var detector = PermissionPromptSessionExitDetector()
        _ = detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .waiting)])
        let exited = detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .busy)])
        XCTAssertEqual(exited, ["s-1"])
    }

    func testSessionDisappearedAlsoCountsAsExited() {
        var detector = PermissionPromptSessionExitDetector()
        _ = detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .waiting)])
        let exited = detector.detect(in: [])
        XCTAssertEqual(exited, ["s-1"], "CLI 进程退出 → session 消失,也应让浮窗关闭")
    }

    func testReentryDoesNotReExit() {
        var detector = PermissionPromptSessionExitDetector()
        _ = detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .waiting)])
        XCTAssertEqual(detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .idle)]), ["s-1"])
        // 再进入 waiting 不算 exit;再次离开 waiting 才算
        XCTAssertEqual(detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .waiting)]), Set<String>())
        XCTAssertEqual(detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .idle)]), ["s-1"])
    }

    func testBusyToIdleIgnored() {
        var detector = PermissionPromptSessionExitDetector()
        _ = detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .busy)])
        let exited = detector.detect(in: [session(pid: 1, sessionId: "s-1", status: .idle)])
        XCTAssertEqual(exited, Set<String>(), "未进入过 waiting,任何状态变化都不算离开")
    }

    func testMultipleExitsInOneFrame() {
        var detector = PermissionPromptSessionExitDetector()
        _ = detector.detect(in: [
            session(pid: 1, sessionId: "s-1", status: .waiting),
            session(pid: 2, sessionId: "s-2", status: .waiting),
            session(pid: 3, sessionId: "s-3", status: .waiting),
        ])
        let exited = detector.detect(in: [
            session(pid: 1, sessionId: "s-1", status: .idle),
            session(pid: 2, sessionId: "s-2", status: .busy),
            session(pid: 3, sessionId: "s-3", status: .waiting),
        ])
        XCTAssertEqual(exited, ["s-1", "s-2"])
    }
}

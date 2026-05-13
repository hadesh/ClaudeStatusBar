import XCTest
@testable import ClaudeStatusBar

final class WaitingTransitionDetectorTests: XCTestCase {

    private func session(pid: Int, status: SessionStatus, waitingFor: String? = nil) -> Session {
        let waitingField = waitingFor.map { ",\"waitingFor\":\"\($0)\"" } ?? ""
        let json = """
        {"pid":\(pid),"sessionId":"s\(pid)","cwd":"/x","startedAt":0,"version":"v","kind":"interactive","entrypoint":"cli","status":"\(status.rawValue)","updatedAt":0\(waitingField)}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    func testFirstCallReturnsAllCurrentlyWaiting() {
        var detector = WaitingTransitionDetector()
        let newly = detector.detect(in: [
            session(pid: 1, status: .busy),
            session(pid: 2, status: .waiting, waitingFor: "perm")
        ])
        XCTAssertEqual(newly.map(\.pid), [2])
    }

    func testRepeatedCallWithSameSetReturnsEmpty() {
        var detector = WaitingTransitionDetector()
        let s = [session(pid: 2, status: .waiting)]
        _ = detector.detect(in: s)
        XCTAssertTrue(detector.detect(in: s).isEmpty)
    }

    func testWaitingThenIdleThenWaitingNotifiesTwice() {
        var detector = WaitingTransitionDetector()
        let waiting = [session(pid: 2, status: .waiting)]
        let idle = [session(pid: 2, status: .idle)]

        XCTAssertEqual(detector.detect(in: waiting).map(\.pid), [2])
        XCTAssertTrue(detector.detect(in: idle).isEmpty)
        XCTAssertEqual(detector.detect(in: waiting).map(\.pid), [2])
    }

    func testNewSessionEnteringWaitingNotifies() {
        var detector = WaitingTransitionDetector()
        _ = detector.detect(in: [session(pid: 1, status: .busy)])

        let newly = detector.detect(in: [
            session(pid: 1, status: .busy),
            session(pid: 2, status: .waiting)
        ])
        XCTAssertEqual(newly.map(\.pid), [2])
    }

    func testSessionDisappearingDoesNotTriggerOnReappearance() {
        var detector = WaitingTransitionDetector()
        _ = detector.detect(in: [session(pid: 2, status: .waiting)])
        _ = detector.detect(in: [])
        // 重新出现且仍为 waiting → 视为新的 waiting,应通知
        let newly = detector.detect(in: [session(pid: 2, status: .waiting)])
        XCTAssertEqual(newly.map(\.pid), [2])
    }

    func testBusyToWaitingNotifies() {
        var detector = WaitingTransitionDetector()
        _ = detector.detect(in: [session(pid: 1, status: .busy)])
        let newly = detector.detect(in: [session(pid: 1, status: .waiting)])
        XCTAssertEqual(newly.map(\.pid), [1])
    }
}

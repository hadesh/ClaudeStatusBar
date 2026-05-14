import XCTest
@testable import ClaudeStatusBar

final class TaskCompletionDetectorTests: XCTestCase {

    private func session(pid: Int, status: SessionStatus) -> Session {
        let json = """
        {"pid":\(pid),"sessionId":"s\(pid)","cwd":"/x","startedAt":0,"version":"v","kind":"interactive","entrypoint":"cli","status":"\(status.rawValue)","updatedAt":0}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    func testFirstCallSilentlyAbsorbsBaseline() {
        var detector = TaskCompletionDetector()
        let newly = detector.detect(in: [
            session(pid: 1, status: .busy),
            session(pid: 2, status: .idle),
        ])
        XCTAssertEqual(newly.map(\.pid), [])
    }

    func testBusyToIdleNotifies() {
        var detector = TaskCompletionDetector()
        _ = detector.detect(in: [session(pid: 1, status: .busy)])
        let newly = detector.detect(in: [session(pid: 1, status: .idle)])
        XCTAssertEqual(newly.map(\.pid), [1])
    }

    func testStillBusyDoesNotNotify() {
        var detector = TaskCompletionDetector()
        _ = detector.detect(in: [session(pid: 1, status: .busy)])
        XCTAssertTrue(detector.detect(in: [session(pid: 1, status: .busy)]).isEmpty)
    }

    func testIdleToIdleDoesNotNotify() {
        var detector = TaskCompletionDetector()
        _ = detector.detect(in: [session(pid: 1, status: .idle)])
        XCTAssertTrue(detector.detect(in: [session(pid: 1, status: .idle)]).isEmpty)
    }

    func testBusyToWaitingDoesNotNotify() {
        // Permission requests transition busy → waiting; that's panel territory,
        // never a completion notification.
        var detector = TaskCompletionDetector()
        _ = detector.detect(in: [session(pid: 1, status: .busy)])
        XCTAssertTrue(detector.detect(in: [session(pid: 1, status: .waiting)]).isEmpty)
    }

    func testWaitingToIdleDoesNotNotify() {
        // The session was waiting (not busy) — the user already addressed it,
        // no completion fanfare needed.
        var detector = TaskCompletionDetector()
        _ = detector.detect(in: [session(pid: 1, status: .waiting)])
        XCTAssertTrue(detector.detect(in: [session(pid: 1, status: .idle)]).isEmpty)
    }

    func testBusyToGoneDoesNotNotify() {
        // CLI exited — that's not a completion in the user-visible sense.
        var detector = TaskCompletionDetector()
        _ = detector.detect(in: [session(pid: 1, status: .busy)])
        XCTAssertTrue(detector.detect(in: []).isEmpty)
    }

    func testReentryAfterIdleNotifiesOnSecondCompletion() {
        var detector = TaskCompletionDetector()
        _ = detector.detect(in: [session(pid: 1, status: .busy)])
        XCTAssertEqual(detector.detect(in: [session(pid: 1, status: .idle)]).map(\.pid), [1])
        // Now busy again, then idle again — should fire again.
        _ = detector.detect(in: [session(pid: 1, status: .busy)])
        XCTAssertEqual(detector.detect(in: [session(pid: 1, status: .idle)]).map(\.pid), [1])
    }

    func testMultipleSessionsCompleteIndependently() {
        var detector = TaskCompletionDetector()
        _ = detector.detect(in: [
            session(pid: 1, status: .busy),
            session(pid: 2, status: .busy),
        ])
        let newly = detector.detect(in: [
            session(pid: 1, status: .idle),
            session(pid: 2, status: .busy),
        ])
        XCTAssertEqual(newly.map(\.pid), [1])
    }
}

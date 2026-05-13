import XCTest
@testable import ClaudeStatusBar

final class WaitingReminderTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000_000)
    private let cfg = WaitingReminderTracker.Config(initialDelay: 30, interval: 30, maxReminders: 3)

    private func makeSession(pid: Int, status: String = "waiting") -> Session {
        let json = #"""
        {"pid":\#(pid),"sessionId":"s\#(pid)","cwd":"/x","startedAt":0,"version":"v","kind":"interactive","entrypoint":"cli","status":"\#(status)","updatedAt":0}
        """#.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    func testFirstSightingDoesNotReturnReminder() {
        var tracker = WaitingReminderTracker(config: cfg)
        let s = makeSession(pid: 1)
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0).map(\.pid), [])
    }
}

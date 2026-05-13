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

    func testReminderFiresAfterInitialDelay() {
        var tracker = WaitingReminderTracker(config: cfg)
        let s = makeSession(pid: 1)
        _ = tracker.tick(sessions: [s], now: t0)
        XCTAssertEqual(
            tracker.tick(sessions: [s], now: t0.addingTimeInterval(29)).map(\.pid),
            [],
            "1 s short of delay → no reminder"
        )
        XCTAssertEqual(
            tracker.tick(sessions: [s], now: t0.addingTimeInterval(30)).map(\.pid),
            [1],
            "exactly at delay → reminder"
        )
    }

    func testFiresRepeatedlyUpToMax() {
        var tracker = WaitingReminderTracker(config: cfg)
        let s = makeSession(pid: 1)
        _ = tracker.tick(sessions: [s], now: t0)
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(30)).map(\.pid), [1], "1st")
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(60)).map(\.pid), [1], "2nd")
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(90)).map(\.pid), [1], "3rd")
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(120)).map(\.pid), [], "stop after max")
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(1000)).map(\.pid), [], "still stopped")
    }

    func testRespectsIntervalBetweenReminders() {
        var tracker = WaitingReminderTracker(config: cfg)
        let s = makeSession(pid: 1)
        _ = tracker.tick(sessions: [s], now: t0)
        _ = tracker.tick(sessions: [s], now: t0.addingTimeInterval(30))   // 1st reminder
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(45)).map(\.pid), [], "too early")
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(60)).map(\.pid), [1], "interval reached")
    }
}

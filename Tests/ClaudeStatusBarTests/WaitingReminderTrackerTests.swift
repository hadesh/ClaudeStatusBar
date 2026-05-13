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

    func testStateClearsWhenSessionLeavesWaiting() {
        var tracker = WaitingReminderTracker(config: cfg)
        let waiting = makeSession(pid: 1)
        let busy = makeSession(pid: 1, status: "busy")
        _ = tracker.tick(sessions: [waiting], now: t0)
        _ = tracker.tick(sessions: [busy], now: t0.addingTimeInterval(60))
        // Re-enter waiting at t=120 → must be a fresh "first sighting".
        XCTAssertEqual(
            tracker.tick(sessions: [waiting], now: t0.addingTimeInterval(120)).map(\.pid),
            [],
            "re-entry is fresh"
        )
        XCTAssertEqual(
            tracker.tick(sessions: [waiting], now: t0.addingTimeInterval(150)).map(\.pid),
            [1],
            "fires after delay"
        )
    }

    func testIgnoresNonWaitingSessions() {
        var tracker = WaitingReminderTracker(config: cfg)
        let busy = makeSession(pid: 1, status: "busy")
        let idle = makeSession(pid: 2, status: "idle")
        XCTAssertEqual(tracker.tick(sessions: [busy, idle], now: t0).map(\.pid), [])
        XCTAssertEqual(tracker.tick(sessions: [busy, idle], now: t0.addingTimeInterval(1000)).map(\.pid), [])
    }

    func testHandlesMultipleSessionsIndependently() {
        var tracker = WaitingReminderTracker(config: cfg)
        let s1 = makeSession(pid: 1)
        let s2 = makeSession(pid: 2)
        _ = tracker.tick(sessions: [s1], now: t0)                         // s1 first seen at t=0
        _ = tracker.tick(sessions: [s1, s2], now: t0.addingTimeInterval(15))  // s2 first seen at t=15
        XCTAssertEqual(
            tracker.tick(sessions: [s1, s2], now: t0.addingTimeInterval(30)).map(\.pid),
            [1],
            "only s1 due"
        )
        XCTAssertEqual(
            tracker.tick(sessions: [s1, s2], now: t0.addingTimeInterval(45)).map(\.pid),
            [2],
            "now s2 due"
        )
    }
}

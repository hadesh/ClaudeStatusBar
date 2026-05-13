import XCTest
@testable import ClaudeStatusBar

final class UsageTrackerFallbackTests: XCTestCase {

    private let cacheWithOnlyOldDate = #"""
    {
      "version": 3,
      "lastComputedDate": "2026-05-12",
      "dailyActivity": [
        {"date": "2026-05-10", "messageCount": 1, "sessionCount": 1, "toolCallCount": 0},
        {"date": "2026-05-12", "messageCount": 1407, "sessionCount": 10, "toolCallCount": 678}
      ],
      "dailyModelTokens": [
        {"date": "2026-05-12", "tokensByModel": {"opus": 510831}}
      ],
      "modelUsage": {"opus": {"costUSD": 0}}
    }
    """#.data(using: .utf8)!

    func testFallsBackToMostRecentWhenTodayMissing() throws {
        let usage = try UsageTracker.parse(cacheWithOnlyOldDate, date: "2026-05-13")
        XCTAssertEqual(usage.date, "2026-05-12")
        XCTAssertEqual(usage.sessionCount, 10)
        XCTAssertEqual(usage.messageCount, 1407)
        XCTAssertEqual(usage.totalTokens, 510831)
    }

    func testUsesExactDateWhenAvailable() throws {
        let usage = try UsageTracker.parse(cacheWithOnlyOldDate, date: "2026-05-12")
        XCTAssertEqual(usage.date, "2026-05-12")
        XCTAssertEqual(usage.messageCount, 1407)
    }

    func testEmptyCacheReturnsZerosWithRequestedDate() throws {
        let empty = #"{"dailyActivity":[],"dailyModelTokens":[],"modelUsage":{}}"#.data(using: .utf8)!
        let usage = try UsageTracker.parse(empty, date: "2026-05-13")
        XCTAssertEqual(usage.date, "2026-05-13")
        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertEqual(usage.sessionCount, 0)
    }
}

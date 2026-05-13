import XCTest
@testable import ClaudeStatusBar

final class UsageTrackerTests: XCTestCase {

    private let sample = #"""
    {
      "version": 3,
      "lastComputedDate": "2026-05-12",
      "dailyActivity": [
        {"date": "2026-05-11", "messageCount": 5, "sessionCount": 1, "toolCallCount": 2},
        {"date": "2026-05-12", "messageCount": 1407, "sessionCount": 10, "toolCallCount": 678}
      ],
      "dailyModelTokens": [
        {"date": "2026-05-12", "tokensByModel": {"opus": 510831, "qwen": 2833000}}
      ],
      "modelUsage": {
        "opus": {"inputTokens": 100, "outputTokens": 200, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "costUSD": 1.5},
        "qwen": {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "costUSD": 0}
      }
    }
    """#.data(using: .utf8)!

    func testParsesDailyUsageForGivenDate() throws {
        let usage = try UsageTracker.parse(sample, date: "2026-05-12")
        XCTAssertEqual(usage.date, "2026-05-12")
        XCTAssertEqual(usage.sessionCount, 10)
        XCTAssertEqual(usage.messageCount, 1407)
        XCTAssertEqual(usage.toolCallCount, 678)
        XCTAssertEqual(usage.tokensByModel["opus"], 510831)
        XCTAssertEqual(usage.tokensByModel["qwen"], 2833000)
        XCTAssertEqual(usage.totalTokens, 510831 + 2833000)
    }

func testTotalCostSumsAllModels() throws {
        let usage = try UsageTracker.parse(sample, date: "2026-05-12")
        XCTAssertEqual(usage.totalCostUSD, 1.5, accuracy: 0.0001)
    }

    func testThrowsOnInvalidJson() {
        let bad = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try UsageTracker.parse(bad, date: "2026-05-12"))
    }
}

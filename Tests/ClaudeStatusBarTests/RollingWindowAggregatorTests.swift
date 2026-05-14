import XCTest
@testable import ClaudeStatusBar

final class RollingWindowAggregatorTests: XCTestCase {
    private var tempDir: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)  // arbitrary fixed clock

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rolling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeJsonl(_ lines: [String], at relPath: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func assistant(at offsetMinutes: Double, model: String = "claude-opus-4-7", input: Int, output: Int) -> String {
        let ts = Self.formatter.string(from: now.addingTimeInterval(offsetMinutes * 60))
        return #"""
        {"type":"assistant","timestamp":"\#(ts)","message":{"model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}
        """#
    }

    func testNoActivityReturnsNil() {
        XCTAssertNil(RollingWindowAggregator.currentWindow(now: now, projectsRoot: tempDir))
    }

    func testReturnsWindowForRecentActivity() throws {
        try writeJsonl([
            assistant(at: -30, input: 100, output: 200),  // 30 min ago
            assistant(at: -10, input: 50, output: 75),    // 10 min ago
        ], at: "p/s.jsonl")

        let win = try XCTUnwrap(RollingWindowAggregator.currentWindow(now: now, projectsRoot: tempDir))
        XCTAssertEqual(win.inputTokens, 150)
        XCTAssertEqual(win.outputTokens, 275)
        XCTAssertEqual(win.totalTokens, 425)
        XCTAssertEqual(win.startedAt.timeIntervalSince1970, now.addingTimeInterval(-30 * 60).timeIntervalSince1970, accuracy: 1)
        // resetsAt = block start + 5h
        XCTAssertEqual(
            win.resetsAt.timeIntervalSince1970,
            now.addingTimeInterval(-30 * 60 + 5 * 3600).timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testIgnoresActivityOlderThan5Hours() throws {
        try writeJsonl([
            assistant(at: -301, input: 1000, output: 1000),  // 5h 1m ago — outside window
            assistant(at: -10, input: 50, output: 75),       // inside window
        ], at: "p/s.jsonl")

        let win = try XCTUnwrap(RollingWindowAggregator.currentWindow(now: now, projectsRoot: tempDir))
        XCTAssertEqual(win.inputTokens, 50)
        XCTAssertEqual(win.outputTokens, 75)
    }

    func testReturnsNilWhenAllActivityIsOlderThan5Hours() throws {
        try writeJsonl([
            assistant(at: -400, input: 1000, output: 1000),
            assistant(at: -350, input: 1000, output: 1000),
        ], at: "p/s.jsonl")

        XCTAssertNil(RollingWindowAggregator.currentWindow(now: now, projectsRoot: tempDir))
    }

    func testBlockStartIsEarliestEntryInWindow() throws {
        try writeJsonl([
            assistant(at: -120, input: 1, output: 1),  // 2h ago
            assistant(at: -60, input: 1, output: 1),
            assistant(at: -1, input: 1, output: 1),
        ], at: "p/s.jsonl")

        let win = try XCTUnwrap(RollingWindowAggregator.currentWindow(now: now, projectsRoot: tempDir))
        XCTAssertEqual(
            win.startedAt.timeIntervalSince1970,
            now.addingTimeInterval(-120 * 60).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(win.inputTokens, 3)
        XCTAssertEqual(win.outputTokens, 3)
    }

    func testIgnoresNonAssistantEntries() throws {
        let userTs = Self.formatter.string(from: now.addingTimeInterval(-5 * 60))
        try writeJsonl([
            #"{"type":"user","timestamp":"\#(userTs)","message":{"role":"user"}}"#,
            assistant(at: -5, input: 10, output: 20),
        ], at: "p/s.jsonl")

        let win = try XCTUnwrap(RollingWindowAggregator.currentWindow(now: now, projectsRoot: tempDir))
        XCTAssertEqual(win.inputTokens, 10)
        XCTAssertEqual(win.outputTokens, 20)
    }

    func testAggregatesAcrossFiles() throws {
        try writeJsonl([
            assistant(at: -60, input: 100, output: 0),
        ], at: "p1/a.jsonl")
        try writeJsonl([
            assistant(at: -30, input: 0, output: 200),
        ], at: "p2/b.jsonl")

        let win = try XCTUnwrap(RollingWindowAggregator.currentWindow(now: now, projectsRoot: tempDir))
        XCTAssertEqual(win.inputTokens, 100)
        XCTAssertEqual(win.outputTokens, 200)
    }

    func testSkipsMalformedLines() throws {
        try writeJsonl([
            "not json",
            assistant(at: -10, input: 5, output: 5),
            "{\"type\":\"assistant\"}",  // missing timestamp/usage
        ], at: "p/s.jsonl")

        let win = try XCTUnwrap(RollingWindowAggregator.currentWindow(now: now, projectsRoot: tempDir))
        XCTAssertEqual(win.totalTokens, 10)
    }

    func testRemainingClampsAtZero() {
        let win = RollingWindow(
            startedAt: now.addingTimeInterval(-6 * 3600),
            resetsAt: now.addingTimeInterval(-3600),
            inputTokens: 0, outputTokens: 0
        )
        XCTAssertEqual(win.remaining(now: now), 0)
    }
}

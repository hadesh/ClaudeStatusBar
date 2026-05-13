import XCTest
@testable import ClaudeStatusBar

final class LiveUsageAggregatorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-agg-\(UUID().uuidString)", isDirectory: true)
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

    private func assistant(model: String, input: Int, output: Int) -> String {
        #"""
        {"type":"assistant","message":{"model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """#
    }

    func testEmptyRootReturnsEmpty() {
        let result = LiveUsageAggregator.aggregate(from: tempDir)
        XCTAssertTrue(result.isEmpty)
    }

    func testNonExistentRootReturnsEmpty() {
        let bogus = tempDir.appendingPathComponent("nope")
        XCTAssertTrue(LiveUsageAggregator.aggregate(from: bogus).isEmpty)
    }

    func testAggregatesSingleSession() throws {
        try writeJsonl([
            assistant(model: "claude-opus-4-7", input: 100, output: 200),
            assistant(model: "claude-opus-4-7", input: 50, output: 75),
        ], at: "proj-a/sess1.jsonl")
        let result = LiveUsageAggregator.aggregate(from: tempDir)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].model, "claude-opus-4-7")
        XCTAssertEqual(result[0].inputTokens, 150)
        XCTAssertEqual(result[0].outputTokens, 275)
    }

    func testSumsAcrossMultipleProjectsAndSessions() throws {
        try writeJsonl([
            assistant(model: "opus", input: 100, output: 200),
        ], at: "proj-a/sess1.jsonl")
        try writeJsonl([
            assistant(model: "opus", input: 50, output: 75),
        ], at: "proj-b/sess2.jsonl")
        try writeJsonl([
            assistant(model: "qwen", input: 1000, output: 0),
        ], at: "proj-b/sess3.jsonl")
        let result = LiveUsageAggregator.aggregate(from: tempDir)
        XCTAssertEqual(result.count, 2)
        let opus = result.first { $0.model == "opus" }
        XCTAssertEqual(opus?.inputTokens, 150)
        XCTAssertEqual(opus?.outputTokens, 275)
        let qwen = result.first { $0.model == "qwen" }
        XCTAssertEqual(qwen?.inputTokens, 1000)
    }

    func testSortedByCombinedDescending() throws {
        try writeJsonl([
            assistant(model: "small", input: 10, output: 10),
            assistant(model: "medium", input: 100, output: 100),
            assistant(model: "large", input: 1000, output: 1000),
        ], at: "p/s.jsonl")
        let result = LiveUsageAggregator.aggregate(from: tempDir)
        XCTAssertEqual(result.map(\.model), ["large", "medium", "small"])
    }

    func testIgnoresNonAssistantEntries() throws {
        try writeJsonl([
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            assistant(model: "opus", input: 10, output: 20),
            #"{"type":"system","message":{}}"#,
        ], at: "p/s.jsonl")
        let result = LiveUsageAggregator.aggregate(from: tempDir)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].inputTokens, 10)
    }

    func testFiltersSyntheticAndZeroTotals() throws {
        try writeJsonl([
            assistant(model: "<synthetic>", input: 0, output: 0),
            assistant(model: "real", input: 5, output: 5),
        ], at: "p/s.jsonl")
        let result = LiveUsageAggregator.aggregate(from: tempDir)
        XCTAssertEqual(result.map(\.model), ["real"])
    }

    func testSkipsMalformedLinesAndFiles() throws {
        try writeJsonl([
            "not json",
            assistant(model: "opus", input: 10, output: 20),
            "also broken",
        ], at: "p/s.jsonl")
        let result = LiveUsageAggregator.aggregate(from: tempDir)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].inputTokens, 10)
    }
}

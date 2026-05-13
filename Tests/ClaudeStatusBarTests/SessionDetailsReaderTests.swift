import XCTest
@testable import ClaudeStatusBar

final class SessionDetailsReaderTests: XCTestCase {

    // MARK: - encodeProjectPath

    func testEncodesSlashesToHyphens() {
        XCTAssertEqual(
            SessionDetailsReader.encodeProjectPath("/Users/me/proj"),
            "-Users-me-proj"
        )
    }

    func testEncodesUnderscoresAndDots() {
        XCTAssertEqual(
            SessionDetailsReader.encodeProjectPath("/Users/me/Desktop/amap/amap_c3_ad_spec"),
            "-Users-me-Desktop-amap-amap-c3-ad-spec"
        )
        XCTAssertEqual(
            SessionDetailsReader.encodeProjectPath("/Users/me/.claude"),
            "-Users-me--claude"
        )
    }

    // MARK: - parseLastAssistantUsage

    private let assistantLine = #"""
    {"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":6,"cache_creation_input_tokens":0,"cache_read_input_tokens":181125,"output_tokens":3281}}}
    """#

    func testParsesLatestAssistantUsage() {
        let data = assistantLine.data(using: .utf8)!
        let d = SessionDetailsReader.parseLastAssistantUsage(data)
        XCTAssertEqual(d?.model, "claude-opus-4-7")
        XCTAssertEqual(d?.inputTokens, 6)
        XCTAssertEqual(d?.cacheReadTokens, 181125)
        XCTAssertEqual(d?.outputTokens, 3281)
        XCTAssertEqual(d?.contextTokens, 6 + 0 + 181125)
    }

    func testIgnoresUserLinesAndPicksLastAssistant() {
        let mixed = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"model":"old-model","usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5}}}
        {"type":"user","message":{"role":"user","content":"again"}}
        \(assistantLine)
        """.data(using: .utf8)!
        let d = SessionDetailsReader.parseLastAssistantUsage(mixed)
        XCTAssertEqual(d?.model, "claude-opus-4-7")
        XCTAssertEqual(d?.cacheReadTokens, 181125)
    }

    func testReturnsNilWhenNoAssistantMessages() {
        let onlyUsers = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"user","message":{"role":"user","content":"again"}}
        """.data(using: .utf8)!
        XCTAssertNil(SessionDetailsReader.parseLastAssistantUsage(onlyUsers))
    }

    func testSkipsMalformedLines() {
        let withGarbage = """
        not a json line
        {"type":"user"}
        \(assistantLine)
        another bad line
        """.data(using: .utf8)!
        let d = SessionDetailsReader.parseLastAssistantUsage(withGarbage)
        XCTAssertEqual(d?.model, "claude-opus-4-7")
    }

    // MARK: - context window per model

    func testOpus4HasOneMillionContext() {
        XCTAssertEqual(SessionDetails.contextWindow(forModel: "claude-opus-4-7"), 1_000_000)
        XCTAssertEqual(SessionDetails.contextWindow(forModel: "claude-opus-4-1"), 1_000_000)
    }

    func testSonnet4HasOneMillionContext() {
        XCTAssertEqual(SessionDetails.contextWindow(forModel: "claude-sonnet-4-6"), 1_000_000)
    }

    func testHaiku4HasTwoHundredKContext() {
        XCTAssertEqual(SessionDetails.contextWindow(forModel: "claude-haiku-4-5"), 200_000)
    }

    func testClaude3xHasTwoHundredKContext() {
        XCTAssertEqual(SessionDetails.contextWindow(forModel: "claude-3-5-sonnet"), 200_000)
        XCTAssertEqual(SessionDetails.contextWindow(forModel: "claude-3-opus"), 200_000)
    }

    func testUsageRatioWithRealNumbers() {
        let d = SessionDetails(
            model: "claude-opus-4-7", inputTokens: 100,
            outputTokens: 0, cacheReadTokens: 99_900, cacheCreationTokens: 0
        )
        XCTAssertEqual(d.contextTokens, 100_000)
        XCTAssertEqual(d.contextWindow, 1_000_000)
        XCTAssertEqual(d.usageRatio, 0.1, accuracy: 0.0001)
    }

    func testUsageRatioReflectsActualOverflow() {
        // 不再 cap 到 1.0 — 真超出窗口要诚实地显示,提示表不准。
        let d = SessionDetails(
            model: "claude-3-opus", inputTokens: 0,
            outputTokens: 0, cacheReadTokens: 250_000, cacheCreationTokens: 0
        )
        XCTAssertEqual(d.contextWindow, 200_000)
        XCTAssertGreaterThan(d.usageRatio, 1.0)
    }

    // MARK: - file system read

    func testReadReturnsNilWhenFileMissing() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonexistent-\(UUID())")
        let d = SessionDetailsReader.read(
            cwd: "/no/such/path",
            sessionId: "no-session",
            projectsRoot: tmp
        )
        XCTAssertNil(d)
    }

    func testReadFromFlatFileLayout() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sd-test-\(UUID().uuidString)")
        let projectDir = tmp.appendingPathComponent("-x")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try assistantLine.write(
            to: projectDir.appendingPathComponent("sess.jsonl"),
            atomically: true, encoding: .utf8
        )
        let d = SessionDetailsReader.read(cwd: "/x", sessionId: "sess", projectsRoot: tmp)
        XCTAssertEqual(d?.model, "claude-opus-4-7")
    }
}

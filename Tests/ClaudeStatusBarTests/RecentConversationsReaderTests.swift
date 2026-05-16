import XCTest
@testable import ClaudeStatusBar

final class RecentConversationsReaderTests: XCTestCase {

    // MARK: - parseFirstPrompt (pure)

    func testParseFirstPromptEmptyData() {
        XCTAssertNil(RecentConversationsReader.parseFirstPrompt(Data()))
    }

    func testParseFirstPromptSingleUserStringEntry() {
        let data = #"""
        {"type":"user","message":{"role":"user","content":"hello world"}}
        """#.data(using: .utf8)!
        XCTAssertEqual(
            RecentConversationsReader.parseFirstPrompt(data),
            "hello world"
        )
    }

    func testParseFirstPromptSkipsSystemAndFindsUser() {
        // 第一行是 system / hook 注入, 第二行才是真 user prompt.
        let data = #"""
        {"type":"system","content":"injected"}
        {"type":"user","message":{"role":"user","content":"actual prompt"}}
        """#.data(using: .utf8)!
        XCTAssertEqual(
            RecentConversationsReader.parseFirstPrompt(data),
            "actual prompt"
        )
    }

    func testParseFirstPromptSkipsToolResultContentArray() {
        // user message 的 content 是 array(tool_result 形态), 跳过, 继续找下一条.
        let data = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"out"}]}}
        {"type":"user","message":{"role":"user","content":"real first prompt"}}
        """#.data(using: .utf8)!
        XCTAssertEqual(
            RecentConversationsReader.parseFirstPrompt(data),
            "real first prompt"
        )
    }

    func testParseFirstPromptSkipsCorruptLines() {
        let data = #"""
        not json at all
        {"malformed":
        {"type":"user","message":{"role":"user","content":"survived"}}
        """#.data(using: .utf8)!
        XCTAssertEqual(
            RecentConversationsReader.parseFirstPrompt(data),
            "survived"
        )
    }

    func testParseFirstPromptTruncatedAt80Chars() {
        let long = String(repeating: "a", count: 100)
        let data = #"""
        {"type":"user","message":{"role":"user","content":"\#(long)"}}
        """#.data(using: .utf8)!
        let result = RecentConversationsReader.parseFirstPrompt(data)
        XCTAssertEqual(result?.count, 81)  // 80 + "…"
        XCTAssertTrue(result?.hasSuffix("…") ?? false)
    }

    func testParseFirstPromptReturnsNilWhenNoUserStringPrompt() {
        let data = #"""
        {"type":"system","content":"x"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"y"}]}}
        """#.data(using: .utf8)!
        XCTAssertNil(RecentConversationsReader.parseFirstPrompt(data))
    }
}

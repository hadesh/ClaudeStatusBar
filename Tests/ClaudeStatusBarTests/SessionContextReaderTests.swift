import XCTest
@testable import ClaudeStatusBar

final class SessionContextReaderTests: XCTestCase {

    func testEmptyDataReturnsNilFields() {
        let ctx = SessionContextReader.parse(Data())
        XCTAssertNil(ctx.recentPrompt)
        XCTAssertNil(ctx.lastTool)
    }

    func testStringUserMessageAsPrompt() {
        let lines = """
        {"type":"user","message":{"role":"user","content":"please refactor foo.swift"}}
        """.data(using: .utf8)!
        let ctx = SessionContextReader.parse(lines)
        XCTAssertEqual(ctx.recentPrompt, "please refactor foo.swift")
        XCTAssertNil(ctx.lastTool)
    }

    func testToolResultUserMessageIgnored() {
        // 当 user message 的 content 是 array(tool_result 形态),不应被当作 prompt。
        let lines = """
        {"type":"user","message":{"role":"user","content":"original prompt"}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"abc","content":"output"}]}}
        """.data(using: .utf8)!
        let ctx = SessionContextReader.parse(lines)
        XCTAssertEqual(ctx.recentPrompt, "original prompt")
    }

    func testLastToolUseExtraction() {
        let lines = """
        {"type":"user","message":{"role":"user","content":"go"}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
        """.data(using: .utf8)!
        let ctx = SessionContextReader.parse(lines)
        XCTAssertEqual(ctx.lastTool, "Bash: npm test")
    }

    func testToolUseEditExtractsBasename() {
        let lines = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/me/proj/foo.swift","old_string":"a","new_string":"b"}}]}}
        """#.data(using: .utf8)!
        let ctx = SessionContextReader.parse(lines)
        XCTAssertEqual(ctx.lastTool, "Edit: foo.swift")
    }

    func testToolUseUnknownToolJustName() {
        let lines = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://example.com"}}]}}
        """#.data(using: .utf8)!
        let ctx = SessionContextReader.parse(lines)
        XCTAssertEqual(ctx.lastTool, "WebFetch")
    }

    func testPromptTruncatedAt50Chars() {
        let long = String(repeating: "a", count: 80)
        let lines = """
        {"type":"user","message":{"role":"user","content":"\(long)"}}
        """.data(using: .utf8)!
        let ctx = SessionContextReader.parse(lines)
        XCTAssertEqual(ctx.recentPrompt?.count, 51)  // 50 + ellipsis "…"
        XCTAssertTrue(ctx.recentPrompt?.hasSuffix("…") ?? false)
    }

    func testBashCommandTruncatedAt60Chars() {
        let cmd = String(repeating: "x", count: 80)
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"\#(cmd)"}}]}}"#
        let ctx = SessionContextReader.parse(line.data(using: .utf8)!)
        // 'Bash: ' (6) + truncated body (60) + '…' = 67
        XCTAssertEqual(ctx.lastTool?.count, 67)
        XCTAssertTrue(ctx.lastTool?.hasSuffix("…") ?? false)
    }

    func testReadFromFlatLayoutFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scr-test-\(UUID().uuidString)")
        let projectDir = tmp.appendingPathComponent("-x")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let body = #"""
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b/c.txt"}}]}}
        """#
        try body.write(
            to: projectDir.appendingPathComponent("sess.jsonl"),
            atomically: true, encoding: .utf8
        )
        let ctx = SessionContextReader.read(cwd: "/x", sessionId: "sess", projectsRoot: tmp)
        XCTAssertEqual(ctx?.recentPrompt, "hi")
        XCTAssertEqual(ctx?.lastTool, "Read: c.txt")
    }
}

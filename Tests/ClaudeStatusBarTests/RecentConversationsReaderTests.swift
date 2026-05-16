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

    // MARK: - read (filesystem)

    func testReadReturnsEmptyForMissingDirectory() {
        let tmp = makeTempProjectsRoot()
        defer { cleanup(tmp) }
        let result = RecentConversationsReader.read(
            cwd: "/some/cwd", excluding: nil, projectsRoot: tmp
        )
        XCTAssertEqual(result, [])
    }

    func testReadFlatLayoutSingleFile() throws {
        let tmp = makeTempProjectsRoot()
        defer { cleanup(tmp) }
        let projectDir = tmp.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath("/proj")
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try writeFlatJsonl(in: projectDir, sessionId: "abc-123", firstPrompt: "the prompt")

        let result = RecentConversationsReader.read(
            cwd: "/proj", excluding: nil, projectsRoot: tmp
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sessionId, "abc-123")
        XCTAssertEqual(result[0].firstPrompt, "the prompt")
        XCTAssertEqual(result[0].jsonlURL, projectDir.appendingPathComponent("abc-123.jsonl"))
    }

    func testReadSortsByMtimeDescending() throws {
        let tmp = makeTempProjectsRoot()
        defer { cleanup(tmp) }
        let projectDir = tmp.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath("/proj")
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // 创建 3 个文件, mtime 依次为 -3h / -1h / -2h
        try writeFlatJsonl(in: projectDir, sessionId: "old",   firstPrompt: "old",  mtime: Date(timeIntervalSinceNow: -10800))
        try writeFlatJsonl(in: projectDir, sessionId: "newest", firstPrompt: "new", mtime: Date(timeIntervalSinceNow: -3600))
        try writeFlatJsonl(in: projectDir, sessionId: "mid",   firstPrompt: "mid",  mtime: Date(timeIntervalSinceNow: -7200))

        let result = RecentConversationsReader.read(
            cwd: "/proj", excluding: nil, projectsRoot: tmp
        )
        XCTAssertEqual(result.map { $0.sessionId }, ["newest", "mid", "old"])
    }

    func testReadRespectsLimitParameter() throws {
        let tmp = makeTempProjectsRoot()
        defer { cleanup(tmp) }
        let projectDir = tmp.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath("/proj")
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        for i in 0..<7 {
            try writeFlatJsonl(
                in: projectDir,
                sessionId: "s\(i)",
                firstPrompt: "p\(i)",
                mtime: Date(timeIntervalSinceNow: TimeInterval(-i * 60))
            )
        }
        let result = RecentConversationsReader.read(
            cwd: "/proj", excluding: nil, limit: 3, projectsRoot: tmp
        )
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map { $0.sessionId }, ["s0", "s1", "s2"])
    }

    func testReadExcludesGivenSessionIdFlat() throws {
        let tmp = makeTempProjectsRoot()
        defer { cleanup(tmp) }
        let projectDir = tmp.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath("/proj")
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try writeFlatJsonl(in: projectDir, sessionId: "keep", firstPrompt: "keep me", mtime: Date(timeIntervalSinceNow: -60))
        try writeFlatJsonl(in: projectDir, sessionId: "skip", firstPrompt: "skip me", mtime: Date(timeIntervalSinceNow: -30))

        let result = RecentConversationsReader.read(
            cwd: "/proj", excluding: "skip", projectsRoot: tmp
        )
        XCTAssertEqual(result.map { $0.sessionId }, ["keep"])
    }

    func testReadSubdirectoryLayoutSessionIdFromParent() throws {
        let tmp = makeTempProjectsRoot()
        defer { cleanup(tmp) }
        let projectDir = tmp.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath("/proj")
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try writeSubdirJsonl(in: projectDir, sessionId: "sub-1", filename: "log.jsonl", firstPrompt: "from subdir")

        let result = RecentConversationsReader.read(
            cwd: "/proj", excluding: nil, projectsRoot: tmp
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sessionId, "sub-1")
        XCTAssertEqual(result[0].firstPrompt, "from subdir")
    }

    func testReadExcludesGivenSessionIdSubdir() throws {
        let tmp = makeTempProjectsRoot()
        defer { cleanup(tmp) }
        let projectDir = tmp.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath("/proj")
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try writeSubdirJsonl(in: projectDir, sessionId: "keep", filename: "a.jsonl", firstPrompt: "keep")
        try writeSubdirJsonl(in: projectDir, sessionId: "skip", filename: "b.jsonl", firstPrompt: "skip")

        let result = RecentConversationsReader.read(
            cwd: "/proj", excluding: "skip", projectsRoot: tmp
        )
        XCTAssertEqual(result.map { $0.sessionId }, ["keep"])
    }

    // MARK: - test fixtures

    private func makeTempProjectsRoot() -> URL {
        let dir = NSTemporaryDirectory() + "rcr-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        // C realpath resolves /var -> /private/var so URLs match FileManager.contentsOfDirectory output
        guard let rp = realpath(dir, nil) else { return URL(fileURLWithPath: dir, isDirectory: true) }
        defer { free(rp) }
        return URL(fileURLWithPath: String(cString: rp), isDirectory: true)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 写一个子目录布局的 jsonl: <projectDir>/<sessionId>/<filename>
    private func writeSubdirJsonl(
        in projectDir: URL,
        sessionId: String,
        filename: String,
        firstPrompt: String,
        mtime: Date? = nil
    ) throws {
        let dir = projectDir.appendingPathComponent(sessionId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        let line = #"{"type":"user","message":{"role":"user","content":"\#(firstPrompt)"}}"#
        try line.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime],
                ofItemAtPath: url.path
            )
        }
    }

    /// 写一个扁平布局的 jsonl: <projectDir>/<sessionId>.jsonl
    private func writeFlatJsonl(
        in projectDir: URL,
        sessionId: String,
        firstPrompt: String,
        mtime: Date? = nil
    ) throws {
        let url = projectDir.appendingPathComponent("\(sessionId).jsonl")
        let line = #"{"type":"user","message":{"role":"user","content":"\#(firstPrompt)"}}"#
        try line.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime],
                ofItemAtPath: url.path
            )
        }
    }
}

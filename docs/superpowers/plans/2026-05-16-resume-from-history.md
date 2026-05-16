# Fresh session 恢复上次会话子菜单 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** fresh session(`SessionContextStore` 拿不到 recentPrompt)行下挂一个「恢复上次会话 ▸」子菜单,列出同 cwd 下最近 5 个历史会话,点击复制 `claude --resume <sessionId>` 到剪贴板。

**Architecture:** 新增纯静态 `RecentConversationsReader`(对仗 `SessionContextReader`/`SessionDetailsReader`,只 import Foundation)+ 数据模型 `RecentConversation`。`AppDelegate.rebuildMenu` 在 session 循环里判断 fresh,二选一挂 resume 子菜单或现有 detail 行。

**Tech Stack:** Swift + AppKit,SwiftPM,XCTest。复用 `SessionDetailsReader.encodeProjectPath` / `defaultProjectsRoot` 和 `WaitingNotifier.notify(title:body:userInfo:)`。

**Spec:** `docs/superpowers/specs/2026-05-16-resume-from-history-design.md`

---

## 文件清单

| 类型 | 路径 | 责任 |
|------|------|------|
| 新增 | `Sources/ClaudeStatusBar/Models/RecentConversation.swift` | 不可变数据模型,Foundation only |
| 新增 | `Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift` | 纯静态 enum,parse + file IO |
| 改 | `Sources/ClaudeStatusBar/AppDelegate.swift` | 新增 `relativeFormatter`、`makeRecentResumeItem(for:)`、`@objc copyResumeCommand(_:)`;`rebuildMenu` 加 fresh 二选一分支 |
| 新增 | `Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift` | 纯函数 + 文件 IO 全部场景 |

---

## Task 1: 添加 RecentConversation 模型

**Files:**
- Create: `Sources/ClaudeStatusBar/Models/RecentConversation.swift`

数据载体,不需要测试。Foundation only,符合 `Models/` 约束。

- [ ] **Step 1: 创建 model 文件**

```swift
import Foundation

public struct RecentConversation: Equatable {
    public let sessionId: String
    public let firstPrompt: String  // 已截断
    public let modifiedAt: Date     // jsonl 文件 mtime
    public let jsonlURL: URL

    public init(
        sessionId: String,
        firstPrompt: String,
        modifiedAt: Date,
        jsonlURL: URL
    ) {
        self.sessionId = sessionId
        self.firstPrompt = firstPrompt
        self.modifiedAt = modifiedAt
        self.jsonlURL = jsonlURL
    }
}
```

- [ ] **Step 2: 编译通过**

Run: `swift build`
Expected: 0 errors

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStatusBar/Models/RecentConversation.swift
git commit -m "$(cat <<'EOF'
feat(menu): RecentConversation 模型

历史 jsonl 元信息载体: sessionId + 首句 prompt + 文件 mtime + URL.
后续 RecentConversationsReader 返回值用.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: parseFirstPrompt 纯函数 + 单元测试

**Files:**
- Create: `Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift`
- Create: `Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift`

Reader 的纯解析层,跟 `SessionContextReader.parse` 同构 但**正向**扫描。一次性写完所有 parse 场景的测试,然后实现到全绿。

- [ ] **Step 1: 写 Reader 骨架(只占位,parse 还没实现)**

```swift
// Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift
import Foundation

/// 同 cwd 下的历史会话摘要 reader. 用于 fresh session 行的「恢复上次会话」子菜单.
///
/// 对仗 SessionContextReader: 后者反向扫拿"最新" prompt + lastTool 给运行中的会话用,
/// 本 reader 顺序扫拿"最早" prompt 给一个 fresh session 看历史. 两个方向反过来不能复用.
public enum RecentConversationsReader {

    public static let maxFileBytes: Int = 100 * 1024 * 1024
    public static let defaultLimit: Int = 5
    public static let promptMaxChars: Int = 80

    /// 顺序扫描 JSONL, 返回第一条 type=user, content 为非空 string 的消息内容.
    /// 截断到 promptMaxChars + "…".  array(tool_result)形态的 user 消息跳过, 损坏 JSON 行跳过.
    public static func parseFirstPrompt(_ data: Data) -> String? {
        return nil  // 下一步实现
    }
}
```

- [ ] **Step 2: 写全部 parseFirstPrompt 单元测试**

```swift
// Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift
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
```

- [ ] **Step 3: 跑测试,确认 7 个 parse 测试都失败**

Run: `swift test --filter ClaudeStatusBarTests.RecentConversationsReaderTests`
Expected: 7 个 testParseFirstPrompt* 全部 FAIL(占位实现一直返回 nil,只有 testParseFirstPromptEmptyData 和 testParseFirstPromptReturnsNilWhenNoUserStringPrompt 会偶然 PASS)

- [ ] **Step 4: 实现 parseFirstPrompt**

把 Reader 文件改成:

```swift
import Foundation

/// 同 cwd 下的历史会话摘要 reader. 用于 fresh session 行的「恢复上次会话」子菜单.
///
/// 对仗 SessionContextReader: 后者反向扫拿"最新" prompt + lastTool 给运行中的会话用,
/// 本 reader 顺序扫拿"最早" prompt 给一个 fresh session 看历史. 两个方向反过来不能复用.
public enum RecentConversationsReader {

    public static let maxFileBytes: Int = 100 * 1024 * 1024
    public static let defaultLimit: Int = 5
    public static let promptMaxChars: Int = 80

    /// 顺序扫描 JSONL, 返回第一条 type=user, content 为非空 string 的消息内容.
    /// 截断到 promptMaxChars + "…".  array(tool_result)形态的 user 消息跳过, 损坏 JSON 行跳过.
    public static func parseFirstPrompt(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(UserEntry.self, from: lineData),
                  entry.type == "user",
                  case .string(let s) = entry.message?.content ?? .array,
                  !s.isEmpty
            else { continue }
            return truncate(s, max: promptMaxChars)
        }
        return nil
    }

    // MARK: - Private helpers

    private static func truncate(_ s: String, max: Int) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }

    // MARK: - JSON shapes

    private struct UserEntry: Decodable {
        let type: String?
        let message: UserMessage?
    }
    private struct UserMessage: Decodable {
        let content: ContentValue?
    }
    /// user 消息的 content 可能是 string 或 array (tool_result 形态).
    /// 我们只关心 string; array 整体当作"无效 prompt", 继续扫下一条.
    private enum ContentValue: Decodable {
        case string(String)
        case array
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            self = .array
        }
    }
}
```

- [ ] **Step 5: 跑测试,确认 7 个 parse 测试全部 PASS**

Run: `swift test --filter ClaudeStatusBarTests.RecentConversationsReaderTests`
Expected: 7 PASS, 0 FAIL

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift
git commit -m "$(cat <<'EOF'
feat(menu): RecentConversationsReader 解析首句 prompt

顺序扫 jsonl 找第一条 user-string content. 跟 SessionContextReader 反扫"最新" 形成
互补 —— fresh session 看的是"会话开头". 跳过 system/assistant/tool_result/损坏行.
80 字符截断.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Reader.read — 扁平布局 + mtime 排序 + limit

**Files:**
- Modify: `Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift`
- Modify: `Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift`

加 `read(cwd:excluding:limit:projectsRoot:)`,只支持扁平 `<projectDir>/<sessionId>.jsonl` 布局,不处理子目录(下一个 task 加)。先把核心数据流(列文件 → 排 mtime → 取 limit → parse → 返回)跑通。

- [ ] **Step 1: 在测试文件里加 fixture helper 和 4 个新测试**

在 `RecentConversationsReaderTests.swift` 末尾追加:

```swift
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

    // MARK: - test fixtures

    private func makeTempProjectsRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rcr-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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
```

- [ ] **Step 2: 跑测试,确认 4 个新测试 FAIL(read 还没实现)**

Run: `swift test --filter ClaudeStatusBarTests.RecentConversationsReaderTests`
Expected: 7 parse PASS,4 read FAIL("RecentConversationsReader has no member 'read'" 编译错误,所以是编译失败,表现为整个 suite 不能跑)

- [ ] **Step 3: 实现 read 的扁平布局版本**

在 `RecentConversationsReader` 里追加(放在 `parseFirstPrompt` 后面):

```swift
    /// 读 cwd 对应 projects 目录下的历史会话, 按 mtime 倒序返回前 limit 个有效项.
    /// 扁平布局: `<projectDir>/<sessionId>.jsonl`.  子目录布局在后续 commit 加.
    public static func read(
        cwd: String,
        excluding sessionId: String?,
        limit: Int = defaultLimit,
        projectsRoot: URL = SessionDetailsReader.defaultProjectsRoot
    ) -> [RecentConversation] {
        let projectDir = projectsRoot.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath(cwd)
        )
        let candidates = collectCandidates(in: projectDir, excluding: sessionId)
        let sorted = candidates.sorted { $0.modifiedAt > $1.modifiedAt }
        var result: [RecentConversation] = []
        for c in sorted {
            if result.count >= limit { break }
            guard let prompt = parseFile(at: c.url) else { continue }
            result.append(RecentConversation(
                sessionId: c.sessionId,
                firstPrompt: prompt,
                modifiedAt: c.modifiedAt,
                jsonlURL: c.url
            ))
        }
        return result
    }

    // MARK: - private file walking

    private struct Candidate {
        let url: URL
        let sessionId: String
        let modifiedAt: Date
    }

    private static func collectCandidates(in projectDir: URL, excluding: String?) -> [Candidate] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return [] }

        var result: [Candidate] = []
        for entry in entries {
            // 子目录布局在下一个 commit 加, 这里只处理扁平 *.jsonl
            guard entry.pathExtension == "jsonl" else { continue }
            let stem = entry.deletingPathExtension().lastPathComponent
            if let excluding, stem == excluding { continue }
            guard let mt = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            else { continue }
            result.append(Candidate(url: entry, sessionId: stem, modifiedAt: mt))
        }
        return result
    }

    private static func parseFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseFirstPrompt(data)
    }
```

- [ ] **Step 4: 跑全部 reader 测试**

Run: `swift test --filter ClaudeStatusBarTests.RecentConversationsReaderTests`
Expected: 11 PASS, 0 FAIL

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift
git commit -m "$(cat <<'EOF'
feat(menu): RecentConversationsReader.read 扁平布局

按 cwd 编码定位 projects 目录,扁平 *.jsonl 候选,按 mtime 倒序取前 limit 个.
子目录布局 + size 阈值 + 整文件无 prompt 兜底在后续 commits.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Reader.read — 子目录布局 + 双重 exclude

**Files:**
- Modify: `Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift`
- Modify: `Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift`

兼容 `<projectDir>/<sessionId>/<anything>.jsonl` 布局(`SessionDetailsReader.locateJsonl` 里能看到这个格式)。同时实现两种布局下的 `excluding` 跳过。

- [ ] **Step 1: 加 fixture helper(子目录写法)和 3 个测试**

在 `RecentConversationsReaderTests` 测试方法区追加:

```swift
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
```

在测试文件的 fixture 区(`makeTempProjectsRoot` 附近)加:

```swift
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
```

- [ ] **Step 2: 跑测试,确认新测试中 subdir 相关 2 个 FAIL**

Run: `swift test --filter ClaudeStatusBarTests.RecentConversationsReaderTests`
Expected: 11 既有 + `testReadExcludesGivenSessionIdFlat` PASS;`testReadSubdirectoryLayoutSessionIdFromParent` 和 `testReadExcludesGivenSessionIdSubdir` FAIL(子目录还没实现)。

(`testReadExcludesGivenSessionIdFlat` 之所以应该 PASS,是因为上一个 task 实现 collectCandidates 时已经写了 `if let excluding, stem == excluding { continue }`。)

- [ ] **Step 3: 在 collectCandidates 里加子目录处理**

替换 `collectCandidates` 整个方法为:

```swift
    private static func collectCandidates(in projectDir: URL, excluding: String?) -> [Candidate] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return [] }

        var result: [Candidate] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if let c = candidateFromSubdirectory(entry, excluding: excluding) {
                    result.append(c)
                }
            } else if entry.pathExtension == "jsonl" {
                let stem = entry.deletingPathExtension().lastPathComponent
                if let excluding, stem == excluding { continue }
                guard let mt = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                else { continue }
                result.append(Candidate(url: entry, sessionId: stem, modifiedAt: mt))
            }
        }
        return result
    }

    /// 子目录布局: dir 名即 sessionId, 取里面 mtime 最新的一个 *.jsonl 当代表.
    private static func candidateFromSubdirectory(_ dir: URL, excluding: String?) -> Candidate? {
        let dirName = dir.lastPathComponent
        if let excluding, dirName == excluding { return nil }
        guard let inner = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        var best: (URL, Date)?
        for f in inner where f.pathExtension == "jsonl" {
            guard let mt = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            else { continue }
            if best == nil || mt > best!.1 { best = (f, mt) }
        }
        guard let (url, mt) = best else { return nil }
        return Candidate(url: url, sessionId: dirName, modifiedAt: mt)
    }
```

- [ ] **Step 4: 跑测试,确认全部 PASS**

Run: `swift test --filter ClaudeStatusBarTests.RecentConversationsReaderTests`
Expected: 14 PASS, 0 FAIL

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift
git commit -m "$(cat <<'EOF'
feat(menu): RecentConversationsReader 子目录布局 + exclude

兼容 <projectDir>/<sessionId>/<anything>.jsonl 布局(取目录内 mtime 最新一个 jsonl
当候选, sessionId 即目录名). 两种布局下都跳过 excluding 参数指定的 sessionId.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Reader.read — 大小阈值 + 无 prompt 跳过

**Files:**
- Modify: `Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift`
- Modify: `Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift`

两个边界:
- 超过 100MB 的 jsonl 跳过 — 不是为正确性(读完 100MB 找不到 user-string 也会被 skip),是为**性能**:菜单 willOpen 时同步扫,不能因为有个奇大 jsonl 卡住。
- 整个文件没有 user-string prompt 的也跳过 — Task 3 的 `parseFile → parseFirstPrompt → nil → continue` 路径其实已经覆盖了,这个测试是**回归覆盖**,锁住行为。

注意:本 task 加的两个测试在没有 size guard 的情况下仍会 PASS(只是 size 测试会慢几秒因为读 100MB)。**这是预期**,不要因为"已经绿就不写 impl"——size guard 必须加,因为菜单在 main queue 上扫盘,卡几秒就是用户体验事故。

- [ ] **Step 1: 加 2 个新测试**

在测试方法区追加:

```swift
    func testReadSkipsFilesOverSizeLimit() throws {
        let tmp = makeTempProjectsRoot()
        defer { cleanup(tmp) }
        let projectDir = tmp.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath("/proj")
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // 一个超大稀疏文件
        let bigURL = projectDir.appendingPathComponent("big.jsonl")
        FileManager.default.createFile(atPath: bigURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: bigURL)
        try fh.truncate(atOffset: UInt64(RecentConversationsReader.maxFileBytes + 1))
        try fh.close()
        // 一个正常的小文件, 应当被保留
        try writeFlatJsonl(in: projectDir, sessionId: "small", firstPrompt: "ok")

        let result = RecentConversationsReader.read(
            cwd: "/proj", excluding: nil, projectsRoot: tmp
        )
        XCTAssertEqual(result.map { $0.sessionId }, ["small"])
    }

    func testReadSkipsCandidatesWithNoUserStringPrompt() throws {
        let tmp = makeTempProjectsRoot()
        defer { cleanup(tmp) }
        let projectDir = tmp.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath("/proj")
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // 这个 jsonl 整个没有 user-string content, 应整体跳过
        let emptyPromptURL = projectDir.appendingPathComponent("ghost.jsonl")
        let body = #"""
        {"type":"system","content":"x"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
        """#
        try body.write(to: emptyPromptURL, atomically: true, encoding: .utf8)
        // 正常文件
        try writeFlatJsonl(in: projectDir, sessionId: "real", firstPrompt: "real prompt")

        let result = RecentConversationsReader.read(
            cwd: "/proj", excluding: nil, projectsRoot: tmp
        )
        XCTAssertEqual(result.map { $0.sessionId }, ["real"])
    }
```

- [ ] **Step 2: 跑测试,观察行为**

Run: `swift test --filter ClaudeStatusBarTests.RecentConversationsReaderTests`
Expected: 16 PASS(包括两个新加的)。`testReadSkipsFilesOverSizeLimit` 应当 PASS 但**明显慢**(读 100MB sparse 文件几秒级)。这就是为什么需要 size guard — 不是为了让测试通过,是为了让菜单不卡。

- [ ] **Step 3: 在 parseFile 加 size guard(性能修复)**

替换 `parseFile(at:)`:

```swift
    private static func parseFile(at url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size <= maxFileBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseFirstPrompt(data)
    }
```

- [ ] **Step 4: 重跑测试,确认仍 PASS 且 size 测试明显变快**

Run: `swift test --filter ClaudeStatusBarTests.RecentConversationsReaderTests`
Expected: 16 PASS, 0 FAIL。`testReadSkipsFilesOverSizeLimit` 现在是毫秒级。

- [ ] **Step 5: 跑整个 test suite,确认没 regress 别的测试**

Run: `swift test`
Expected: 全部 PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift
git commit -m "$(cat <<'EOF'
feat(menu): RecentConversationsReader 大小阈值 + 空文件跳过覆盖

>100MB jsonl 直接跳过(性能, 不读 Data); 整文件没 user-string prompt 的候选行为
本来就被跳过, 加测试锁回归. size guard 在 Data(contentsOf:) 之前.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: AppDelegate — copyResumeCommand 复制命令

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

加 `@objc copyResumeCommand(_:)` 私有方法,从 `NSMenuItem.representedObject` 拿 sessionId,写剪贴板,弹反馈通知。本 task 暂时不挂菜单(Task 8 接通),但方法本身要能编译通过。

- [ ] **Step 1: 在 AppDelegate.swift 末尾(`activateTerminal` 方法之后,`handleNotificationClick` 之前)插入新方法**

定位:在 `func activateTerminal(sessionId:cwd:)` 方法的右大括号 `}` 后,`private func handleNotificationClick` 之前。

插入:

```swift
    /// 「恢复上次会话」子菜单的 action 入口.
    /// representedObject 是历史 sessionId, 拼成 `claude --resume <id>` 写剪贴板.
    /// 反馈走 WaitingNotifier.notify(title:body:) 通用通道, 不过 settings 网关
    /// (用户主动操作的反馈, 不是被动打扰).
    @objc private func copyResumeCommand(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        let cmd = "claude --resume \(sid)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        notifier.notify(title: "已复制 resume 命令", body: cmd)
    }
```

- [ ] **Step 2: 编译通过**

Run: `swift build`
Expected: 0 errors

- [ ] **Step 3: 跑全套测试确认没影响**

Run: `swift test`
Expected: 全部 PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(menu): AppDelegate copyResumeCommand action

把 NSMenuItem.representedObject 里的 sessionId 拼成 `claude --resume <id>` 写剪贴板,
弹通用通知反馈. Task 8 接通菜单后才会被触发.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: AppDelegate — makeRecentResumeItem 子菜单装配

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

加 `relativeFormatter` 属性 + `formatRelative(_:)` 辅助方法 + `makeRecentResumeItem(for:)` 私有方法。本 task 同样不接到 rebuildMenu(下一个 task 接),但要能编译。

- [ ] **Step 1: 加 `relativeFormatter` 私有属性**

定位:AppDelegate class 里既有的私有属性区(在 `private var cancellables = Set<AnyCancellable>()` 之后,`private lazy var settingsWindowController` 之前)。

插入:

```swift
    /// 子菜单条目的相对时间格式器: "5 分钟前" / "2 小时前" / "昨天" / "3 天前" 等.
    /// rebuildMenu 每次都会调用 makeRecentResumeItem, 复用同一个 formatter 避免反复创建.
    private lazy var relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()
```

- [ ] **Step 2: 加 `makeRecentResumeItem(for:)` 和 `formatRelative(_:)` 私有方法**

定位:`makeSessionDetailItem(_:)` 方法结尾的右大括号 `}` 之后,`revealSession(forPid:)` 之前。

插入:

```swift
    /// fresh session(SessionContextStore 拿不到 recentPrompt)行下方的「恢复上次会话 ▸」
    /// 子菜单. 同 cwd 下没有可恢复的历史时返回 nil(不挂任何条目, 视觉上跟没这个功能一样).
    private func makeRecentResumeItem(for s: Session) -> NSMenuItem? {
        let recents = RecentConversationsReader.read(
            cwd: s.cwd, excluding: s.sessionId
        )
        guard !recents.isEmpty else { return nil }

        let parent = NSMenuItem(title: "恢复上次会话", action: nil, keyEquivalent: "")
        parent.indentationLevel = 1
        let submenu = NSMenu()
        for r in recents {
            let title = "\(r.firstPrompt)  ·  \(formatRelative(r.modifiedAt))"
            let it = NSMenuItem(
                title: title,
                action: #selector(copyResumeCommand(_:)),
                keyEquivalent: ""
            )
            it.target = self
            it.toolTip = "claude --resume \(r.sessionId)"
            it.representedObject = r.sessionId
            submenu.addItem(it)
        }
        parent.submenu = submenu
        return parent
    }

    private func formatRelative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
```

- [ ] **Step 3: 编译通过**

Run: `swift build`
Expected: 0 errors

- [ ] **Step 4: 跑全套测试**

Run: `swift test`
Expected: 全部 PASS(本 task 没改测试)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(menu): AppDelegate makeRecentResumeItem 子菜单装配

读 RecentConversationsReader → 装 NSMenuItem(title="恢复上次会话") + submenu,
每条 representedObject 是 sessionId, action 指 copyResumeCommand.
relativeFormatter (zh_CN, .short) 渲染 mtime 为相对时间. 还没接到 rebuildMenu.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: rebuildMenu 接通 fresh 二选一分支

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

把 `rebuildMenu` 里 session 循环的 detail 行装配改成「detail vs resume 子菜单」二选一。判定依据 `contextStore.contextByPid[s.pid]?.recentPrompt == nil`(`nil` 整体 = 还没扫过,也算 fresh)。

- [ ] **Step 1: 改 rebuildMenu 的 session 循环**

定位:`AppDelegate.swift:256-263`(行号近似,实际找下面这段):

```swift
        } else {
            for s in sessions.sorted(by: { $0.pid < $1.pid }) {
                menu.addItem(makeSessionItem(s))
                if let detail = makeSessionDetailItem(s) {
                    menu.addItem(detail)
                }
            }
        }
```

替换为:

```swift
        } else {
            for s in sessions.sorted(by: { $0.pid < $1.pid }) {
                menu.addItem(makeSessionItem(s))
                // fresh session(还没产生 user prompt)挂「恢复上次会话」子菜单;
                // 否则挂模型/上下文 detail 行. 两条路径互斥.
                if contextStore.contextByPid[s.pid]?.recentPrompt == nil {
                    if let resume = makeRecentResumeItem(for: s) {
                        menu.addItem(resume)
                    }
                } else if let detail = makeSessionDetailItem(s) {
                    menu.addItem(detail)
                }
            }
        }
```

- [ ] **Step 2: 编译 + 全测试通过**

Run: `swift build && swift test`
Expected: build 无 error,全部 test PASS

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(menu): rebuildMenu fresh 行下挂 resume 子菜单

session 循环里 detail 行 vs resume 子菜单二选一: contextStore 拿不到 recentPrompt
(nil 整体不存在 也含还没扫过)就当 fresh 挂 resume 子菜单, 否则挂 detail.
SessionContextStore 异步首次扫描期间可能短暂多挂几百 ms, 下次 rebuild 自愈.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: 手动验证

**Files:** 不改代码

**目的:** 跑起来真实场景验证 fresh 触发、子菜单装配、剪贴板写入、相对时间显示、二选一切换、子目录布局兼容。`AppDelegate` 没单测覆盖,这步是端到端验收。

- [ ] **Step 1: 启动 app**

Run: `swift run`
预期:状态栏出现🐙图标,无崩溃。

- [ ] **Step 2: 基线检查 — 已有 session 应当走 detail 行,不显示 resume 子菜单**

操作:在另一个终端起 `claude` 并发一句"hi"。等 30s 让 SessionContextStore 扫到。
预期:菜单里这个 session 行下方显示 detail 行(`<model> · X% (...tokens)`),**没有**「恢复上次会话 ▸」子菜单。

- [ ] **Step 3: 触发 fresh 场景**

操作:打开一个新终端,在已经有过 claude 历史(同 cwd 下 `~/.claude/projects/` 里有别的 jsonl)的目录里跑 `claude`,**不发 prompt**。

预期:菜单里新出现的这个 session 行下方,看到「恢复上次会话 ▸」(缩进 1 级),hover 后显示子菜单,每条形如:
- `重构 SessionRowView 高亮逻辑...  ·  3 分钟前`
- `widget hover 子菜单  ·  2 小时前`
- ...(最多 5 条)

- [ ] **Step 4: 验证子菜单条目点击**

操作:点击其中一条。

预期:
- 主菜单关闭
- 系统通知弹"已复制 resume 命令"标题、`claude --resume <长 id>` 内容
- 剪贴板里的内容是 `claude --resume <id>`(去任意终端 ⌘V 验证)
- toolTip(hover 不点)显示完整 `claude --resume <id>`

- [ ] **Step 5: 验证 fresh → 有 prompt 后切换**

操作:在那个 fresh terminal 里发一句"test"。等 30s。

预期:菜单 fresh 行下方的「恢复上次会话 ▸」消失,改为显示 detail 行(模型 + 上下文 %)。子菜单不再出现。

- [ ] **Step 6: 验证 cwd 没历史时不挂**

操作:`cd /tmp/never-claude-here-$(uuidgen)` 然后跑 `claude`,不发 prompt。

预期:菜单里这个 session 行下方什么都没有(既不是 detail,也不是 resume 子菜单)。

- [ ] **Step 7: 验证子目录布局**

定位:本机 `~/.claude/projects/<encoded-cwd>/` 下若已有子目录形式的会话(`<sessionId>/<file>.jsonl`),Step 3 的子菜单里应该能看到对应条目。否则手动造一个:

```bash
SOMECWD=~/.claude/projects/-tmp-fixture-test
mkdir -p "$SOMECWD/fake-uuid-aaaa"
echo '{"type":"user","message":{"role":"user","content":"subdir layout test"}}' > "$SOMECWD/fake-uuid-aaaa/log.jsonl"
cd /tmp/fixture/test  # cwd 编码后要等于 -tmp-fixture-test, 确认下
claude
```

预期:子菜单里看到"subdir layout test · 刚刚",sessionId 是 `fake-uuid-aaaa`,点击复制的命令是 `claude --resume fake-uuid-aaaa`。

- [ ] **Step 8: 验证不影响既有功能**

快速 smoke:
- 偏好设置打开正常 (`⌘,`)
- 通知开关 toggle 不出错
- 状态栏图标点击 / Ctrl+Shift+C 切换菜单都还正常
- session 行 hover 显终止按钮 / 点击跳终端都还正常

预期:全部正常。如果 Step 8 任一项 break 了,回滚 Task 8 那个 commit,排查二选一分支引入的副作用。

- [ ] **Step 9: 收尾**

确认所有 commit 都 clean(`git status` 干净)。如果手动验证发现问题,fix 再补 commit,不要 amend 之前的 commit。

---

## 验收

完成本 plan 后:
- 7 个新 commit(Task 1-8 各一个,Task 9 不出 commit)
- `RecentConversationsReader` 16 个测试全 PASS
- `swift test` 全套通过
- 手动验证 9 个步骤全部观察到预期行为
- spec 里"非目标"列表的事项确实都没做(没新终端、没自动注入、没跨 cwd、没改 SessionRowView)

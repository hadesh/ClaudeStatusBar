# 信息密度提效实施计划 (v0.7.0 候选)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 spec `2026-05-15-info-density-design.md` 落地三块改进 —— 状态栏图标右上角红圈数字角标、菜单条目两行 attributedTitle 增加 prompt/工具/waitingFor、AskUserQuestion 触发时弹浮窗替代当前的系统通知 banner。

**Architecture:** 复用现有 `PermissionPromptStore`(包括 AskUserQuestion 在内的 incoming/resolved Combine 流)、`UsageTracker` 的 30s 定时风格、`OctopusIcon` 的 NSImage 渲染管线。新增 4 个文件:`SessionContextReader`、`SessionContextStore`、`AskUserQuestionPanel`、`AskUserQuestionPanelManager`。Wire 协议、helper 二进制、`PermissionPromptListener` 不动。

**Tech Stack:** Swift 5.9+、AppKit、Combine、Foundation;XCTest;SwiftPM (无 Xcode 项目)。

---

## 文件结构与责任

| 文件 | 操作 | 责任 |
|---|---|---|
| `Sources/ClaudeStatusBar/UI/OctopusIcon.swift` | 修改 | `image(...)` 增加 `badgeCount: Int` 参数,`>0` 时叠红圈+数字 |
| `Sources/ClaudeStatusBar/UI/StatusIcon.swift` | 修改 | `image(...)` 增加 `badgeCount` 参数透传;`badgeCount > 0` 强制 `isTemplate=false` |
| `Sources/ClaudeStatusBar/Services/SessionContextReader.swift` | **新建** | 纯静态;反扫 jsonl 取 `(recentPrompt, lastTool)` |
| `Sources/ClaudeStatusBar/Services/SessionContextStore.swift` | **新建** | `@Published [Int32: SessionContext]`;自持 30s timer |
| `Sources/ClaudeStatusBar/UI/AskUserQuestionPanel.swift` | **新建** | NSPanel,展示 questions/options,「跳回终端答」按钮 + ✕,内含 input 解析 |
| `Sources/ClaudeStatusBar/Services/AskUserQuestionPanelManager.swift` | **新建** | 订阅 store.incoming/resolved,过滤 `toolName == "AskUserQuestion"` |
| `Sources/ClaudeStatusBar/AppDelegate.swift` | 修改 | 注入新 store/manager;`refreshIcon` 计算 attentionCount;`makeSessionItem` 改 attributedTitle;**删除** `routeAskUserQuestionToTerminal` 与对应 incoming filter sink |
| `Tests/ClaudeStatusBarTests/SessionContextReaderTests.swift` | **新建** | 解析逻辑测试 |
| `Tests/ClaudeStatusBarTests/AskUserQuestionPanelTests.swift` | **新建** | input 解析 + Outcome 闭包行为 |
| `Tests/ClaudeStatusBarTests/AskUserQuestionPanelManagerTests.swift` | **新建** | incoming/resolved/abandon 路径 |
| `Tests/ClaudeStatusBarTests/OctopusIconTests.swift` | 修改 | 加 badgeCount 用例 |
| `Tests/ClaudeStatusBarTests/StatusIconTests.swift` | 修改 | 加 badgeCount 用例 |

---

## Task 1: OctopusIcon 增加 badgeCount 参数

**Files:**
- Modify: `Sources/ClaudeStatusBar/UI/OctopusIcon.swift`
- Modify: `Tests/ClaudeStatusBarTests/OctopusIconTests.swift`

- [ ] **Step 1: 写失败测试**

追加到 `Tests/ClaudeStatusBarTests/OctopusIconTests.swift` 的 class 末尾(注意 `}` 之前):

```swift
    func testBadgeCountZeroProducesSameImageAsNoBadge() {
        // badgeCount=0 (默认) 应该等价于不带角标,像素相同。
        let withoutArg = OctopusIcon.image(color: .red, isTemplate: false)
        let withZero = OctopusIcon.image(color: .red, isTemplate: false, badgeCount: 0)
        XCTAssertEqual(withoutArg.tiffRepresentation, withZero.tiffRepresentation)
    }

    func testBadgeCountAddsRedPixelsTopRight() {
        let plain = OctopusIcon.image(color: .black, size: NSSize(width: 32, height: 32), isTemplate: false, badgeCount: 0)
        let badged = OctopusIcon.image(color: .black, size: NSSize(width: 32, height: 32), isTemplate: false, badgeCount: 3)
        guard
            let plainRep = plain.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
            let badgedRep = badged.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        else { return XCTFail("bitmap rep") }

        // 角标在右上角四分之一区域。
        var plainRedish = 0, badgedRedish = 0
        let xRange = (plainRep.pixelsWide / 2)..<plainRep.pixelsWide
        let yRange = 0..<(plainRep.pixelsHigh / 2)  // bitmap 坐标系 y=0 在顶部
        for x in xRange {
            for y in yRange {
                if let c = plainRep.colorAt(x: x, y: y),
                   c.redComponent > 0.7, c.greenComponent < 0.3 { plainRedish += 1 }
                if let c = badgedRep.colorAt(x: x, y: y),
                   c.redComponent > 0.7, c.greenComponent < 0.3 { badgedRedish += 1 }
            }
        }
        XCTAssertEqual(plainRedish, 0, "plain icon should have no red badge pixels")
        XCTAssertGreaterThan(badgedRedish, 5, "badged icon should have visible red badge pixels")
    }

    func testBadgeCountClampsAtNinePlus() {
        // 渲染不应崩溃;具体字符样式不强制,只验证渲染完成。
        let img = OctopusIcon.image(color: .black, size: NSSize(width: 32, height: 32), isTemplate: false, badgeCount: 42)
        XCTAssertEqual(img.size, NSSize(width: 32, height: 32))
    }
```

- [ ] **Step 2: 跑测试看失败**

```bash
swift test --filter ClaudeStatusBarTests.OctopusIconTests
```

预期: 编译失败 ("Extra argument 'badgeCount' in call" / "Cannot find 'badgeCount'")

- [ ] **Step 3: 实现**

替换 `Sources/ClaudeStatusBar/UI/OctopusIcon.swift` 中的 `image(...)` 函数(把 `public static func image(...) -> NSImage { ... }` 整段换成下面):

```swift
    public static func image(
        color: NSColor,
        size: NSSize = NSSize(width: 18, height: 18),
        isTemplate: Bool,
        badgeCount: Int = 0
    ) -> NSImage {
        let cols = grid[0].count
        let rows = grid.count
        let cellW = size.width / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)

        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }

        let ctx = NSGraphicsContext.current
        ctx?.shouldAntialias = false
        ctx?.imageInterpolation = .none

        color.setFill()
        for (r, row) in grid.enumerated() {
            for (c, cell) in row.enumerated() where cell == 1 {
                let x = CGFloat(c) * cellW
                let y = size.height - CGFloat(r + 1) * cellH
                NSRect(x: x, y: y, width: cellW, height: cellH).fill()
            }
        }

        if badgeCount > 0 {
            drawBadge(count: badgeCount, in: size)
        }

        img.isTemplate = isTemplate
        return img
    }

    /// 在 NSImage 当前 lockFocus 上下文里画角标。圆心定在右上角往内 ~3px。
    /// 数字 ≥10 显示 "9+"。badge 半径按 size 缩放保证 18x18 / 32x32 都看得清。
    private static func drawBadge(count: Int, in size: NSSize) {
        let radius = max(size.width * 0.22, 5)
        let diameter = radius * 2
        let cx = size.width - radius
        let cy = size.height - radius
        let rect = NSRect(x: cx - radius, y: cy - radius, width: diameter, height: diameter)

        let ctx = NSGraphicsContext.current
        ctx?.shouldAntialias = true

        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let label = count >= 10 ? "9+" : "\(count)"
        let fontSize = radius * 1.1
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let attr = NSAttributedString(string: label, attributes: attrs)
        let textSize = attr.size()
        let textOrigin = NSPoint(
            x: cx - textSize.width / 2,
            y: cy - textSize.height / 2
        )
        attr.draw(at: textOrigin)

        ctx?.shouldAntialias = false
    }
```

- [ ] **Step 4: 跑测试看通过**

```bash
swift test --filter ClaudeStatusBarTests.OctopusIconTests
```

预期: 全部通过(包括既有 3 个旧用例 + 新增 3 个)。

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/UI/OctopusIcon.swift Tests/ClaudeStatusBarTests/OctopusIconTests.swift
git commit -m "feat(icon): OctopusIcon 支持右上角红圈数字角标"
```

---

## Task 2: StatusIcon 透传 badgeCount + isTemplate 规则

**Files:**
- Modify: `Sources/ClaudeStatusBar/UI/StatusIcon.swift`
- Modify: `Tests/ClaudeStatusBarTests/StatusIconTests.swift`

- [ ] **Step 1: 写失败测试**

追加到 `Tests/ClaudeStatusBarTests/StatusIconTests.swift` 的 class 末尾:

```swift
    func testIdleWithBadgeIsNotTemplate() {
        // badgeCount > 0 时不能用模板模式 —— 红圈会被 AppKit 强制变灰。
        XCTAssertFalse(StatusIcon.image(for: .idle, badgeCount: 1).isTemplate)
    }

    func testIdleZeroBadgeStillTemplate() {
        XCTAssertTrue(StatusIcon.image(for: .idle, badgeCount: 0).isTemplate)
    }

    func testWorkingBadgePropagatesToOctopus() {
        // 不直接断言像素;只验证 badgeCount > 0 + 任意状态下结果非 nil 且尺寸正确。
        let img = StatusIcon.image(for: .working, badgeCount: 2)
        XCTAssertEqual(img.size.width, 18)
        XCTAssertFalse(img.isTemplate)
    }
```

- [ ] **Step 2: 跑测试看失败**

```bash
swift test --filter ClaudeStatusBarTests.StatusIconTests
```

预期: 编译失败("Extra argument 'badgeCount' in call")

- [ ] **Step 3: 实现**

替换 `Sources/ClaudeStatusBar/UI/StatusIcon.swift` 整个文件:

```swift
import AppKit

public enum StatusIcon {
    public static func image(
        for status: AggregateStatus,
        working: NSColor = SettingsStore.defaultWorkingColor,
        attention: NSColor = SettingsStore.defaultAttentionColor,
        badgeCount: Int = 0
    ) -> NSImage {
        // badgeCount > 0 → 角标存在,必须非模板,否则红圈被 AppKit 反相成灰色。
        let templateAllowed = badgeCount == 0
        switch status {
        case .none, .idle:
            return OctopusIcon.image(
                color: .black, isTemplate: templateAllowed, badgeCount: badgeCount
            )
        case .working:
            return OctopusIcon.image(color: working, isTemplate: false, badgeCount: badgeCount)
        case .needsAttention:
            return OctopusIcon.image(color: attention, isTemplate: false, badgeCount: badgeCount)
        }
    }
}
```

- [ ] **Step 4: 跑测试看通过**

```bash
swift test --filter ClaudeStatusBarTests.StatusIconTests
```

预期: 全部通过(5 旧 + 3 新)。

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/UI/StatusIcon.swift Tests/ClaudeStatusBarTests/StatusIconTests.swift
git commit -m "feat(icon): StatusIcon 透传 badgeCount,角标存在时强制非模板"
```

---

## Task 3: AppDelegate 计算 attentionCount

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

- [ ] **Step 1: 改 `refreshIcon` 使用 attentionCount**

定位到 `private func refreshIcon()`(约 184 行),整段替换为:

```swift
    private func refreshIcon() {
        statusItem?.button?.image = StatusIcon.image(
            for: store.aggregateStatus,
            working: settings.workingColor,
            attention: settings.attentionColor,
            badgeCount: attentionCount()
        )
    }

    /// 「需要你」事件的 sessionId 集合并 —— waiting 状态的会话和 permission 浮窗
    /// 经常对应同一个 session,简单加法会双计。permission entry 上的 sessionId
    /// 理论可空但实际 CLI 总是带,本期不做空补偿(少计 1 比双计明显)。
    private func attentionCount() -> Int {
        let waitingIds = Set(
            store.sessions.filter { $0.status == .waiting }.map { $0.sessionId }
        )
        return waitingIds.union(permissionStore.pendingSessionIds()).count
    }
```

- [ ] **Step 2: 加 permissionStore 信号到现有 sink**

定位到 `applicationDidFinishLaunching` 里 `permissionStore.incoming` 的 sink(约 73-80 行,后面紧跟 `.store(in: &cancellables)`)。在那段 sink **之后**、`store.$sessions` sink **之前**插入新 sink,触发 incoming/resolved 时刷一下 icon:

```swift
        // 浮窗状态变化(新请求 / 用户答复 / 终端 race) 都影响 attentionCount,
        // 跟着刷新一下图标角标。
        Publishers.Merge(
            permissionStore.incoming.map { _ in () },
            permissionStore.resolved.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refreshIcon() }
        .store(in: &cancellables)
```

- [ ] **Step 3: 编译**

```bash
swift build
```

预期: 编译通过,无 warning。如果报错检查 `Publishers.Merge` 是否需要 `import Combine`(文件顶部已有,应该没问题)。

- [ ] **Step 4: 启动手测**

```bash
swift run
```

手动验证:
1. 无会话时图标无角标
2. 跑 `claude` 让它进 waiting 状态(例如让它请求工具权限) → 图标出现红圈数字 1
3. 在浮窗答复 / 终端答复 → 角标消失

如果手测失败,回到 Step 2 检查 sink 是否被加进 cancellables。

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "feat(icon): 状态栏图标显示「需要你」事件计数角标"
```

---

## Task 4: SessionContextReader 静态读取器

**Files:**
- Create: `Sources/ClaudeStatusBar/Services/SessionContextReader.swift`
- Create: `Tests/ClaudeStatusBarTests/SessionContextReaderTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `Tests/ClaudeStatusBarTests/SessionContextReaderTests.swift`:

```swift
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
```

- [ ] **Step 2: 跑测试看失败**

```bash
swift test --filter ClaudeStatusBarTests.SessionContextReaderTests
```

预期: 编译失败("Cannot find 'SessionContextReader' in scope")

- [ ] **Step 3: 实现 reader**

新建 `Sources/ClaudeStatusBar/Services/SessionContextReader.swift`:

```swift
import Foundation

public struct SessionContext: Equatable {
    public let recentPrompt: String?
    public let lastTool: String?
    public init(recentPrompt: String?, lastTool: String?) {
        self.recentPrompt = recentPrompt
        self.lastTool = lastTool
    }
}

/// 反扫 jsonl 拿「最近 user prompt + 最后一次 tool_use」。SessionDetailsReader
/// 的兄弟工具,但目标字段不同 —— SessionDetailsReader 取 model + token usage。
/// 同样保持纯静态:测试构造内存数据 / 临时目录 fixture 直接调静态方法。
public enum SessionContextReader {

    /// jsonl 文件大小超过此阈值时跳过(避免阻塞 30s 定时器)。
    public static let maxFileBytes: Int = 100 * 1024 * 1024

    public static func read(
        cwd: String,
        sessionId: String,
        projectsRoot: URL = SessionDetailsReader.defaultProjectsRoot
    ) -> SessionContext? {
        guard let url = locateJsonl(cwd: cwd, sessionId: sessionId, projectsRoot: projectsRoot)
        else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size <= maxFileBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// 纯函数版:从 JSONL 字节流反向扫描。先反扫拿 lastTool,继续反扫拿 recentPrompt
    /// (跳过 tool_result 形态的 user 消息)。
    public static func parse(_ data: Data) -> SessionContext {
        guard let text = String(data: data, encoding: .utf8) else {
            return SessionContext(recentPrompt: nil, lastTool: nil)
        }
        let decoder = JSONDecoder()

        var recentPrompt: String?
        var lastTool: String?

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let lineData = String(line).data(using: .utf8) else { continue }
            // user message: 最近一条 string-content
            if recentPrompt == nil,
               let entry = try? decoder.decode(UserEntry.self, from: lineData),
               entry.type == "user",
               case .string(let s) = entry.message?.content ?? .array([]),
               !s.isEmpty
            {
                recentPrompt = truncate(s, max: 50)
                if lastTool != nil { break }
                continue
            }
            // assistant tool_use: 最近一条
            if lastTool == nil,
               let entry = try? decoder.decode(AssistantEntry.self, from: lineData),
               entry.type == "assistant",
               let block = entry.message?.content?.first(where: { $0.type == "tool_use" })
            {
                lastTool = formatTool(name: block.name ?? "?", input: block.input)
                if recentPrompt != nil { break }
            }
        }
        return SessionContext(recentPrompt: recentPrompt, lastTool: lastTool)
    }

    // MARK: - Private

    private static func locateJsonl(cwd: String, sessionId: String, projectsRoot: URL) -> URL? {
        let projectDir = projectsRoot.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath(cwd)
        )
        let direct = projectDir.appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let subdir = projectDir.appendingPathComponent(sessionId)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: subdir, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.first { $0.pathExtension == "jsonl" }
    }

    private static func truncate(_ s: String, max: Int) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }

    private static func formatTool(name: String, input: [String: AnyCodable]?) -> String {
        switch name {
        case "Bash":
            if let cmd = input?["command"]?.stringValue {
                return "Bash: " + truncate(cmd, max: 60)
            }
            return name
        case "Edit", "Write", "NotebookEdit", "Read":
            if let path = input?["file_path"]?.stringValue {
                return "\(name): \((path as NSString).lastPathComponent)"
            }
            return name
        default:
            return name
        }
    }

    // MARK: - JSON 结构

    private struct UserEntry: Decodable {
        let type: String?
        let message: UserMessage?
    }
    private struct UserMessage: Decodable {
        let content: ContentValue?
    }
    /// user message 的 content 可能是 string 或 array(tool_result 形态)。
    /// 我们只关心 string;array 整体丢弃。
    private enum ContentValue: Decodable {
        case string(String)
        case array([AnyCodable])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let a = try? c.decode([AnyCodable].self) { self = .array(a); return }
            self = .array([])
        }
    }

    private struct AssistantEntry: Decodable {
        let type: String?
        let message: AssistantMessage?
    }
    private struct AssistantMessage: Decodable {
        let content: [AssistantBlock]?
    }
    private struct AssistantBlock: Decodable {
        let type: String?
        let name: String?
        let input: [String: AnyCodable]?
    }

    /// 轻量 JSONValue:够拿 string,其他类型保留以便 decode 不失败。
    public struct AnyCodable: Decodable {
        public let stringValue: String?
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { stringValue = nil; return }
            if let s = try? c.decode(String.self) { stringValue = s; return }
            // 数字/布尔/对象/数组都不是我们要的字符串字段,忽略。
            stringValue = nil
        }
    }
}
```

- [ ] **Step 4: 跑测试看通过**

```bash
swift test --filter ClaudeStatusBarTests.SessionContextReaderTests
```

预期: 9 个用例全部通过。

如果 `testToolResultUserMessageIgnored` 失败,看一下 ContentValue 的 init —— 关键是 user message 的 content 当解析成 array 时,要走 `.array` case,被外层的 `case .string(let s)` 模式匹配跳过。

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/SessionContextReader.swift Tests/ClaudeStatusBarTests/SessionContextReaderTests.swift
git commit -m "feat(menu): 新增 SessionContextReader 反扫 jsonl 取最近 prompt + 工具"
```

---

## Task 5: SessionContextStore (30s timer)

**Files:**
- Create: `Sources/ClaudeStatusBar/Services/SessionContextStore.swift`

- [ ] **Step 1: 实现 store**

新建 `Sources/ClaudeStatusBar/Services/SessionContextStore.swift`:

```swift
import Foundation
import Combine

/// 维护每条 session 的「最近 prompt + 最后 tool」缓存。30s timer 全量刷一次,
/// 主动调 `refresh(for:)` 可以单条触发(用于 SessionStore.sessions 增减)。
/// 对外暴露 `@Published contextByPid`,AppDelegate 在重建菜单时直接读。
public final class SessionContextStore: ObservableObject {
    @Published public private(set) var contextByPid: [Int: SessionContext] = [:]

    private let interval: TimeInterval
    private let projectsRoot: URL
    private let workQueue = DispatchQueue(label: "ClaudeStatusBar.SessionContextStore", qos: .utility)
    private let publishQueue: DispatchQueue
    private var timer: DispatchSourceTimer?

    /// 当前已知 sessions —— AppDelegate 把 SessionStore.$sessions 通过 sink 喂进来。
    /// 用 NSLock 保护因为 timer 在 workQueue 上读、AppDelegate 在 main 上写。
    private let lock = NSLock()
    private var snapshot: [Session] = []

    public init(
        interval: TimeInterval = 30.0,
        projectsRoot: URL = SessionDetailsReader.defaultProjectsRoot,
        publishQueue: DispatchQueue = .main
    ) {
        self.interval = interval
        self.projectsRoot = projectsRoot
        self.publishQueue = publishQueue
    }

    deinit { stop() }

    public func start() {
        refreshAll()
        let t = DispatchSource.makeTimerSource(queue: workQueue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.refreshAll() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// AppDelegate 在 SessionStore.$sessions sink 里调,告诉 store 当前活跃 session
    /// 列表。新增 pid 立刻扫一次,删除 pid 立刻清缓存。
    public func updateSessions(_ sessions: [Session]) {
        lock.lock()
        let oldPids = Set(snapshot.map { $0.pid })
        let newPids = Set(sessions.map { $0.pid })
        snapshot = sessions
        lock.unlock()

        let added = newPids.subtracting(oldPids)
        let removed = oldPids.subtracting(newPids)

        if !removed.isEmpty {
            let publishQueue = self.publishQueue
            publishQueue.async { [weak self] in
                guard let self else { return }
                var dict = self.contextByPid
                for pid in removed { dict.removeValue(forKey: pid) }
                self.contextByPid = dict
            }
        }
        if !added.isEmpty {
            let toScan = sessions.filter { added.contains($0.pid) }
            workQueue.async { [weak self] in self?.scanAndPublish(toScan) }
        }
    }

    // MARK: - Private

    private func refreshAll() {
        lock.lock()
        let sessions = snapshot
        lock.unlock()
        scanAndPublish(sessions)
    }

    private func scanAndPublish(_ sessions: [Session]) {
        let projectsRoot = self.projectsRoot
        var partial: [Int: SessionContext] = [:]
        for s in sessions {
            if let ctx = SessionContextReader.read(
                cwd: s.cwd, sessionId: s.sessionId, projectsRoot: projectsRoot
            ) {
                partial[s.pid] = ctx
            }
        }
        publishQueue.async { [weak self] in
            guard let self else { return }
            // 增量合并;本次扫描没拿到的 pid 保留旧值(可能 jsonl 正在写入)。
            var merged = self.contextByPid
            for (k, v) in partial { merged[k] = v }
            self.contextByPid = merged
        }
    }
}
```

- [ ] **Step 2: 编译**

```bash
swift build
```

预期: 通过。如果 `Session` 找不到 —— 它是 `public struct`,`@testable` 不需要;直接 import 就行,因为目标内部相互可见。

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/SessionContextStore.swift
git commit -m "feat(menu): 新增 SessionContextStore 缓存每条 session 的上下文"
```

> 注:本 task 不写单测 —— store 主要是定时器调度 + dict 合并,逻辑薄;验证放到 Task 6 的手测里(菜单展开后看到副行)。

---

## Task 6: AppDelegate 接入 SessionContextStore + 菜单条目改 attributedTitle

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

- [ ] **Step 1: 注入 store**

在 AppDelegate 的属性区(约 12 行,跟 `usageTracker` 一起),加:

```swift
    private let contextStore = SessionContextStore()
```

- [ ] **Step 2: 启动 + 订阅 sessions**

在 `applicationDidFinishLaunching` 里 `usageTracker.start()` 之后(约 122 行)加一行:

```swift
        contextStore.start()
```

并在 `store.$sessions` 的 sink 闭包内(约 84 行,`sessions` 参数已经是新值)首行加:

```swift
                self.contextStore.updateSessions(sessions)
```

定位锚点是这个 sink:

```swift
        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                // 这里加新行 ↓
                self.contextStore.updateSessions(sessions)
                let transitioned = self.detector.detect(in: sessions)
                ...
```

- [ ] **Step 3: applicationWillTerminate 加 stop**

```swift
    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        usageTracker.stop()
        contextStore.stop()  // 新增
        permissionListener.stop()
        ...
```

- [ ] **Step 4: 改 makeSessionItem 用 attributedTitle**

定位 `private func makeSessionItem(_ s: Session) -> NSMenuItem`(约 321 行),整段替换为:

```swift
    private func makeSessionItem(_ s: Session) -> NSMenuItem {
        let badge: String
        switch s.status {
        case .idle: badge = "○"
        case .busy: badge = "●"
        case .waiting: badge = "⚠"
        }
        let name = (s.cwd as NSString).lastPathComponent
        let mainTitle = "\(badge) \(name) · pid \(s.pid)"
        let secondary = secondaryLine(for: s)

        let attr = NSMutableAttributedString(
            string: mainTitle,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if let secondary {
            attr.append(NSAttributedString(string: "\n"))
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            attr.append(NSAttributedString(
                string: secondary,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: para,
                ]
            ))
        }

        let item = NSMenuItem(title: "", action: #selector(revealSession(_:)), keyEquivalent: "")
        item.attributedTitle = attr
        item.target = self
        item.representedObject = s
        item.toolTip = "\(s.cwd)\n按住 Option 点击在 Finder 中打开"
        return item
    }

    /// 副行内容,按 status 切换:
    /// - waiting: ⏳ {waitingFor},fallback 到 prompt
    /// - working: ▸ {tool} 优先,fallback 到 prompt
    /// - idle/busy 非工具调用: » {recentPrompt}
    /// 全空时返回 nil(主行单独显示)。
    private func secondaryLine(for s: Session) -> String? {
        let ctx = contextStore.contextByPid[s.pid]
        switch s.status {
        case .waiting:
            if let w = s.waitingFor, !w.isEmpty { return "⏳ \(w)" }
            if let p = ctx?.recentPrompt { return "⏳ \(p)" }
            return nil
        case .busy:
            if let t = ctx?.lastTool { return "▸ \(t)" }
            if let p = ctx?.recentPrompt { return "» \(p)" }
            return nil
        case .idle:
            if let p = ctx?.recentPrompt { return "» \(p)" }
            return nil
        }
    }
```

- [ ] **Step 5: 编译**

```bash
swift build
```

预期: 通过。

- [ ] **Step 6: 跑现有全部测试**

```bash
swift test
```

预期: 全部通过。本 task 不引入新测试 —— attributedTitle 渲染依赖 AppKit,UI 层手测。

- [ ] **Step 7: 启动手测**

```bash
swift run
```

手动验证:
1. 跑一会 claude,菜单展开看每条 session 多一行灰色小字
2. session waiting 时副行是 `⏳ Bash: ...`(读 waitingFor)
3. 让 session 跑工具,副行变 `▸ Bash: npm test` 或类似
4. session idle 一段时间,副行是 `» 之前的 prompt`
5. 字段完全空时(刚启动还没 jsonl)菜单条目仍显示主行,无副行报错

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "feat(menu): 会话条目副行展示 prompt / 工具 / waitingFor"
```

---

## Task 7: AskUserQuestion input 解析 (放在 panel 文件内)

**Files:**
- Create: `Sources/ClaudeStatusBar/UI/AskUserQuestionPanel.swift`(本 task 仅放 model 部分,UI 在 Task 8 补)
- Create: `Tests/ClaudeStatusBarTests/AskUserQuestionPanelTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `Tests/ClaudeStatusBarTests/AskUserQuestionPanelTests.swift`:

```swift
import XCTest
@testable import ClaudeStatusBar

final class AskUserQuestionInputTests: XCTestCase {

    func testParsesValidInput() {
        let req = PermissionPromptRequest(
            id: "1",
            toolName: "AskUserQuestion",
            input: [
                "questions": .array([
                    .object([
                        "question": .string("Pick one"),
                        "options": .array([
                            .object([
                                "value": .string("a"),
                                "label": .string("Option A"),
                                "description": .string("First"),
                            ]),
                            .object([
                                "value": .string("b"),
                                "label": .string("Option B"),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )
        let parsed = AskUserQuestionInput.parse(req)
        XCTAssertEqual(parsed?.questions.count, 1)
        XCTAssertEqual(parsed?.questions[0].question, "Pick one")
        XCTAssertEqual(parsed?.questions[0].options.count, 2)
        XCTAssertEqual(parsed?.questions[0].options[0].label, "Option A")
        XCTAssertEqual(parsed?.questions[0].options[0].description, "First")
        XCTAssertEqual(parsed?.questions[0].options[1].label, "Option B")
        XCTAssertNil(parsed?.questions[0].options[1].description)
    }

    func testEmptyInputReturnsNil() {
        let req = PermissionPromptRequest(id: "1", toolName: "AskUserQuestion", input: [:])
        XCTAssertNil(AskUserQuestionInput.parse(req))
    }

    func testMalformedQuestionsReturnsNil() {
        let req = PermissionPromptRequest(
            id: "1",
            toolName: "AskUserQuestion",
            input: ["questions": .string("not an array")]
        )
        XCTAssertNil(AskUserQuestionInput.parse(req))
    }

    func testQuestionMissingOptionsStillReturnsQuestion() {
        // 缺 options 字段 → options 空数组,但 question 文案仍可展示。
        let req = PermissionPromptRequest(
            id: "1",
            toolName: "AskUserQuestion",
            input: [
                "questions": .array([
                    .object(["question": .string("orphan question")]),
                ]),
            ]
        )
        let parsed = AskUserQuestionInput.parse(req)
        XCTAssertEqual(parsed?.questions[0].question, "orphan question")
        XCTAssertEqual(parsed?.questions[0].options.count, 0)
    }
}
```

- [ ] **Step 2: 跑测试看失败**

```bash
swift test --filter ClaudeStatusBarTests.AskUserQuestionInputTests
```

预期: 编译失败("Cannot find 'AskUserQuestionInput'")

- [ ] **Step 3: 实现 input 解析(Panel 文件骨架,UI 留空)**

新建 `Sources/ClaudeStatusBar/UI/AskUserQuestionPanel.swift`:

```swift
import Cocoa

/// 解析 AskUserQuestion 工具的 input 字段。结构是
/// `{questions: [{question: string, options: [{value, label, description?}]}]}`,
/// schema 漂移时返回 nil 让上层降级到「仅显示 toolName + 跳回终端」。
struct AskUserQuestionInput {
    struct Option {
        let value: String?
        let label: String
        let description: String?
    }
    struct Question {
        let question: String
        let options: [Option]
    }
    let questions: [Question]

    static func parse(_ request: PermissionPromptRequest) -> AskUserQuestionInput? {
        guard case .array(let qs)? = request.input["questions"], !qs.isEmpty else {
            return nil
        }
        let questions: [Question] = qs.compactMap { qVal in
            guard case .object(let q) = qVal,
                  case .string(let text)? = q["question"]
            else { return nil }
            let opts: [Option]
            if case .array(let optArr)? = q["options"] {
                opts = optArr.compactMap { oVal in
                    guard case .object(let o) = oVal,
                          case .string(let label)? = o["label"]
                    else { return nil }
                    let value: String? = {
                        if case .string(let v)? = o["value"] { return v }
                        return nil
                    }()
                    let desc: String? = {
                        if case .string(let d)? = o["description"] { return d }
                        return nil
                    }()
                    return Option(value: value, label: label, description: desc)
                }
            } else {
                opts = []
            }
            return Question(question: text, options: opts)
        }
        return questions.isEmpty ? nil : AskUserQuestionInput(questions: questions)
    }
}

// UI 部分在 Task 8 补。
```

- [ ] **Step 4: 跑测试看通过**

```bash
swift test --filter ClaudeStatusBarTests.AskUserQuestionInputTests
```

预期: 4 个用例通过。

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/UI/AskUserQuestionPanel.swift Tests/ClaudeStatusBarTests/AskUserQuestionPanelTests.swift
git commit -m "feat(askq): AskUserQuestion input 解析"
```

---

## Task 8: AskUserQuestionPanel UI

**Files:**
- Modify: `Sources/ClaudeStatusBar/UI/AskUserQuestionPanel.swift`

- [ ] **Step 1: 在文件末尾追加 Panel 类**

在 Task 7 创建的文件 `Sources/ClaudeStatusBar/UI/AskUserQuestionPanel.swift` 末尾追加(`// UI 部分在 Task 8 补。` 那行之前删掉,然后追加):

```swift
/// 浮窗形态:展示 AskUserQuestion 的完整问题文案 + 所有选项。本期不代答,
/// 仅给一个「跳回终端答」按钮 + ✕。✕ 等同 abandon(让 hook helper 退出 0,
/// CLI 端终端 prompt 接管 race)。
final class AskUserQuestionPanel: NSPanel, NSWindowDelegate {
    enum Outcome {
        case goToTerminal
        case abandon
    }
    typealias Response = (Outcome) -> Void

    static let panelWidth: CGFloat = 460
    static let bodyMaxHeight: CGFloat = 320

    let promptId: String
    let request: PermissionPromptRequest
    private let onResponse: Response

    init(request: PermissionPromptRequest, onResponse: @escaping Response) {
        self.promptId = request.id
        self.request = request
        self.onResponse = onResponse

        let frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240)
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Claude Code 需要你回答"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        delegate = self
        for kind: NSWindow.ButtonType in [.miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        let body = makeContent()
        contentView = body
        body.layoutSubtreeIfNeeded()
        let fitting = body.fittingSize
        if fitting.height > 0 {
            setContentSize(NSSize(width: Self.panelWidth, height: fitting.height))
        }
    }

    override var canBecomeKey: Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onResponse(.abandon)
        return false
    }

    @objc private func goToTerminal() { onResponse(.goToTerminal) }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let header = makeHeaderRow()
        let body = makeBodyContainer()
        let buttonRow = makeButtonRow()

        let column = NSStackView(views: [header, body, buttonRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
        for view in [header, body, buttonRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 16),
                view.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -16),
            ])
        }
        return column
    }

    private func makeHeaderRow() -> NSView {
        let session = PermissionPromptPreview.sessionName(for: request) ?? ""
        let label = NSTextField(labelWithString: session.isEmpty ? "AskUserQuestion" : "AskUserQuestion · \(session)")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    private func makeBodyContainer() -> NSView {
        let parsed = AskUserQuestionInput.parse(request)
        let attr = NSMutableAttributedString()

        if let parsed {
            for (qIdx, q) in parsed.questions.enumerated() {
                if qIdx > 0 { attr.append(NSAttributedString(string: "\n\n")) }
                attr.append(NSAttributedString(
                    string: "❓ \(q.question)\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: NSColor.labelColor,
                    ]
                ))
                for (oIdx, opt) in q.options.enumerated() {
                    let circled = circledNumber(oIdx + 1)
                    attr.append(NSAttributedString(
                        string: "  \(circled) \(opt.label)\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                            .foregroundColor: NSColor.labelColor,
                        ]
                    ))
                    if let d = opt.description, !d.isEmpty {
                        attr.append(NSAttributedString(
                            string: "      \(d)\n",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ]
                        ))
                    }
                }
            }
        } else {
            attr.append(NSAttributedString(
                string: "(无法解析问题内容,请直接回到终端答复)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            ))
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.textStorage?.setAttributedString(attr)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.lineFragmentPadding = 0
        }
        scroll.documentView = textView

        // 简化:不预测高度,固定 maxHeight,内容超出靠滚动条。
        scroll.heightAnchor.constraint(lessThanOrEqualToConstant: Self.bodyMaxHeight).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        return scroll
    }

    private func makeButtonRow() -> NSView {
        let button = NSButton(title: "跳回终端答", target: self, action: #selector(goToTerminal))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [spacer, button])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func circledNumber(_ n: Int) -> String {
        switch n {
        case 1: return "①"
        case 2: return "②"
        case 3: return "③"
        case 4: return "④"
        case 5: return "⑤"
        case 6: return "⑥"
        case 7: return "⑦"
        case 8: return "⑧"
        case 9: return "⑨"
        default: return "(\(n))"
        }
    }
}
```

- [ ] **Step 2: 编译**

```bash
swift build
```

预期: 通过。如果报「Use of undeclared type 'PermissionPromptPreview'」检查目标共享 —— `PermissionPromptPreview.swift` 在 `Models/` 下,目标内全可见。

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStatusBar/UI/AskUserQuestionPanel.swift
git commit -m "feat(askq): AskUserQuestionPanel 浮窗 UI"
```

---

## Task 9: AskUserQuestionPanelManager

**Files:**
- Create: `Sources/ClaudeStatusBar/Services/AskUserQuestionPanelManager.swift`
- Create: `Tests/ClaudeStatusBarTests/AskUserQuestionPanelManagerTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `Tests/ClaudeStatusBarTests/AskUserQuestionPanelManagerTests.swift`:

```swift
import XCTest
import Combine
@testable import ClaudeStatusBar

final class AskUserQuestionPanelManagerTests: XCTestCase {

    func testIncomingNonAskUserQuestionIgnored() {
        let store = PermissionPromptStore()
        let manager = AskUserQuestionPanelManager(store: store, navigator: NoopNavigator())
        store.add(
            PermissionPromptRequest(id: "1", toolName: "Bash", input: [:]),
            reply: { _ in }
        )
        XCTAssertEqual(manager.entryCountForTesting, 0)
    }

    func testIncomingAskUserQuestionPresentsPanel() {
        let store = PermissionPromptStore()
        let manager = AskUserQuestionPanelManager(store: store, navigator: NoopNavigator())
        store.add(
            PermissionPromptRequest(id: "1", toolName: "AskUserQuestion", input: [:]),
            reply: { _ in }
        )
        XCTAssertEqual(manager.entryCountForTesting, 1)
    }

    func testResolvedDismissesPanel() {
        let store = PermissionPromptStore()
        let manager = AskUserQuestionPanelManager(store: store, navigator: NoopNavigator())
        store.add(
            PermissionPromptRequest(id: "x", toolName: "AskUserQuestion", input: [:]),
            reply: { _ in }
        )
        XCTAssertEqual(manager.entryCountForTesting, 1)
        store.abandon(id: "x")
        XCTAssertEqual(manager.entryCountForTesting, 0)
    }

    func testGoToTerminalAbandonsAndNavigates() {
        let store = PermissionPromptStore()
        let nav = RecordingNavigator()
        let manager = AskUserQuestionPanelManager(store: store, navigator: nav)
        var captured: PermissionPromptDecision??
        store.add(
            PermissionPromptRequest(
                id: "y", toolName: "AskUserQuestion",
                input: [:], cwd: "/proj", sessionId: "s"
            ),
            reply: { captured = $0 }
        )
        manager.handleResponseForTesting(id: "y", outcome: .goToTerminal)
        XCTAssertEqual(captured, .some(nil))  // abandon 传 nil
        XCTAssertEqual(nav.lastCwd, "/proj")
    }
}

private final class NoopNavigator: TerminalActivating {
    func activate(forSessionId sessionId: String?, cwd: String?) {}
}

private final class RecordingNavigator: TerminalActivating {
    var lastCwd: String?
    func activate(forSessionId sessionId: String?, cwd: String?) {
        lastCwd = cwd
    }
}
```

- [ ] **Step 2: 跑测试看失败**

```bash
swift test --filter ClaudeStatusBarTests.AskUserQuestionPanelManagerTests
```

预期: 编译失败("Cannot find 'AskUserQuestionPanelManager'", "Cannot find 'TerminalActivating'")

- [ ] **Step 3: 实现 manager**

新建 `Sources/ClaudeStatusBar/Services/AskUserQuestionPanelManager.swift`:

```swift
import Cocoa
import Combine

/// 终端激活的注入点 —— 真实实现走 TerminalNavigator + NSRunningApplication;
/// 测试用 mock。manager 不直接依赖 NSApp / 跨进程逻辑,方便单测。
protocol TerminalActivating {
    func activate(forSessionId sessionId: String?, cwd: String?)
}

/// 订阅 PermissionPromptStore.incoming/resolved,过滤 toolName==AskUserQuestion
/// 并管理对应浮窗。与 PermissionPromptPanelManager 平行存在,各管各的窗位:
/// AskUserQuestion 浮窗固定右上,**不参与**权限浮窗的纵向堆叠队列。
final class AskUserQuestionPanelManager {
    private let store: PermissionPromptStore
    private let navigator: TerminalActivating
    private var entries: [(id: String, panel: AskUserQuestionPanel)] = []
    private var cancellables = Set<AnyCancellable>()

    private let edgeInset: CGFloat = 20
    private let stackGap: CGFloat = 12

    init(store: PermissionPromptStore, navigator: TerminalActivating) {
        self.store = store
        self.navigator = navigator
        store.incoming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] req in self?.present(req) }
            .store(in: &cancellables)
        store.resolved
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.dismiss(id: id) }
            .store(in: &cancellables)
    }

    // MARK: - Test Hooks

    var entryCountForTesting: Int { entries.count }
    func handleResponseForTesting(id: String, outcome: AskUserQuestionPanel.Outcome) {
        handleResponse(id: id, outcome: outcome)
    }

    // MARK: - Private

    private func present(_ request: PermissionPromptRequest) {
        guard request.toolName == "AskUserQuestion" else { return }
        guard !entries.contains(where: { $0.id == request.id }) else { return }
        let panel = AskUserQuestionPanel(request: request) { [weak self] outcome in
            self?.handleResponse(id: request.id, outcome: outcome)
        }
        entries.append((request.id, panel))
        layout()
        panel.orderFrontRegardless()
    }

    private func dismiss(id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let panel = entries.remove(at: idx).panel
        panel.orderOut(nil)
        panel.close()
        layout()
    }

    private func handleResponse(id: String, outcome: AskUserQuestionPanel.Outcome) {
        switch outcome {
        case .goToTerminal:
            let req = entries.first(where: { $0.id == id })?.panel.request
            navigator.activate(forSessionId: req?.sessionId, cwd: req?.cwd)
            store.abandon(id: id)
        case .abandon:
            store.abandon(id: id)
        }
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.maxX - AskUserQuestionPanel.panelWidth - edgeInset
        // 起点比 PermissionPromptPanelManager 低 80px,避免和权限浮窗叠死。
        var y = frame.maxY - edgeInset - 80
        for (_, panel) in entries {
            y -= panel.frame.height
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            y -= stackGap
        }
    }
}
```

- [ ] **Step 4: 跑测试看通过**

```bash
swift test --filter ClaudeStatusBarTests.AskUserQuestionPanelManagerTests
```

预期: 4 个用例通过。

> 注:在测试环境(headless)里 NSPanel 可能不渲染,但 `entries.append` 不依赖渲染 —— 数组操作就够测;`testResolvedDismissesPanel` 验证 sink 路径连通。如果 manager 测试因 AppKit `screen.visibleFrame` 在 CI 报 nil,把 `layout()` 中加 guard 即可(已经是 guard `let screen` 保护)。

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/AskUserQuestionPanelManager.swift Tests/ClaudeStatusBarTests/AskUserQuestionPanelManagerTests.swift
git commit -m "feat(askq): AskUserQuestionPanelManager 接管浮窗生命周期"
```

---

## Task 10: AppDelegate 替换 routeAskUserQuestionToTerminal

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

- [ ] **Step 1: 加 askPanels 持有 + Adapter**

在 AppDelegate 属性区(约 18 行,跟 `permissionPanels` 旁边)加:

```swift
    private lazy var askUserQuestionPanels = AskUserQuestionPanelManager(
        store: permissionStore,
        navigator: AppDelegateTerminalActivator(delegate: self)
    )
```

在文件末尾(class `AppDelegate` 大括号之后,**文件级**)加:

```swift
/// 把 AppDelegate 已经在用的「pid → NSRunningApplication / cwd → Finder」
/// 路径暴露成 TerminalActivating。manager 不直接持 NSApp,方便单测。
private final class AppDelegateTerminalActivator: TerminalActivating {
    weak var delegate: AppDelegate?
    init(delegate: AppDelegate) { self.delegate = delegate }
    func activate(forSessionId sessionId: String?, cwd: String?) {
        delegate?.activateTerminal(sessionId: sessionId, cwd: cwd)
    }
}
```

并在 `AppDelegate` 类内部加:

```swift
    /// AskUserQuestion 浮窗「跳回终端」按钮触发。复用现有
    /// findOwningApp / openCwdInFinder 路径。sessionId → pid 反查走
    /// SessionStore 现有数据。
    func activateTerminal(sessionId: String?, cwd: String?) {
        if let sid = sessionId,
           let pid = store.sessions.first(where: { $0.sessionId == sid })?.pid,
           let app = findOwningApp(of: pid)
        {
            app.activate(options: [.activateAllWindows])
            return
        }
        if let cwd { openCwdInFinder(cwd) }
        else { NSSound.beep() }
    }
```

- [ ] **Step 2: 在 applicationDidFinishLaunching 触发 manager**

定位 `_ = permissionPanels`(约 62 行),在它之后加:

```swift
        _ = askUserQuestionPanels  // 触发 lazy 实例化,把 sink 接上
```

- [ ] **Step 3: 删掉旧的 incoming filter sink**

删除 `applicationDidFinishLaunching` 中以下整段(约 70-80 行):

```swift
        // AskUserQuestion 不弹浮窗 —— 它是结构化的多选题,只能在终端答。
        // 这里发一条系统通知提醒用户,然后立刻 abandon 让 hook exit,CLI 端
        // 终端 prompt 接管。PanelManager 那边已经 toolName-skip 这种请求。
        permissionStore.incoming
            .receive(on: DispatchQueue.main)
            .filter { PermissionPromptPanelManager.toolsRoutedAwayFromPanel.contains($0.toolName) }
            .sink { [weak self] req in
                guard let self else { return }
                self.routeAskUserQuestionToTerminal(req)
            }
            .store(in: &cancellables)
```

- [ ] **Step 4: 删掉 routeAskUserQuestionToTerminal 私有方法**

删除 `private func routeAskUserQuestionToTerminal(_ req: PermissionPromptRequest)` 整个方法(约 386-403 行,含上面 docstring 注释)。

- [ ] **Step 5: 编译**

```bash
swift build
```

预期: 通过,无 warning。如果报「'routeAskUserQuestionToTerminal' is unused」之类的 dead-code warning,意味着 Step 3-4 没删干净。

- [ ] **Step 6: 跑全部测试**

```bash
swift test
```

预期: 全部通过(包括前面 task 加的 + 现有 PermissionPromptPanelManager 测试)。`PermissionPromptPanelManager` 那个 `toolsRoutedAwayFromPanel` 静态集合**保留不动** —— 它仍然在过滤 `present(_:)` 时跳过 AskUserQuestion,只是不再有 AppDelegate 那层 filter sink 兜底了(新 manager 替代)。

- [ ] **Step 7: 启动手测**

```bash
swift run
```

让 claude 触发一次 AskUserQuestion(随便让模型说「我需要你选一下 A 或 B」之类),验证:
1. 浮窗在右上角弹出,显示完整问题文案 + 所有选项 + description
2. 角标(Task 3)显示 +1
3. 点「跳回终端答」 → 终端窗口被 activate,浮窗消失
4. 直接在终端答 → 浮窗自动消失(走 socket EOF → store.resolveDeny → resolved)
5. 浮窗 ✕ → 浮窗消失,**终端 select prompt 仍然在等用户答**(没变 deny)

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "feat(askq): AskUserQuestion 改用浮窗,替换原系统通知 banner"
```

---

## Task 11: 端到端验证 + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: 跑完整测试套件**

```bash
swift test
```

预期: 全部通过。如果有失败 task,回到对应 task fix。

- [ ] **Step 2: 全量手测清单**

```bash
swift run
```

按以下清单逐项验证:

| 场景 | 预期 |
|---|---|
| 无会话 | 图标无角标,模板模式跟系统主题反相 |
| 1 个 working session | 图标橙色,无角标 |
| 1 个 waiting session | 图标黄色,角标 `1` |
| 2 个 waiting + 1 个权限浮窗(同一会话) | 角标 `2` 或 `3` 取决于会话 sessionId 是否重合;手验证语义合理 |
| 展开菜单 working session | 副行 `▸ <tool>: <key>` |
| 展开菜单 waiting session | 副行 `⏳ <waitingFor 或 prompt>` |
| 展开菜单 idle session | 副行 `» <prompt>`,如果 jsonl 还没扫到则无副行(不报错) |
| 触发 PermissionRequest(Bash) | 现有浮窗弹出(三按钮),不变 |
| 触发 AskUserQuestion | 新浮窗弹出,显示 `❓ 问题 / ① 选项 / 描述`,只有「跳回终端答」按钮 |
| AskUserQuestion 浮窗点跳转 | 终端 activate,浮窗消失 |
| AskUserQuestion 浮窗 ✕ | 浮窗消失,终端 select prompt 仍在等用户(关键!不能变 deny) |
| AskUserQuestion 终端先答 | 浮窗自动消失(socket EOF 路径) |

- [ ] **Step 3: 更新 CHANGELOG**

把以下内容加到 `CHANGELOG.md` 顶部(在 `## 0.6.2 — 2026-05-15` 之前):

```markdown
## 0.7.0 — 2026-05-15

信息密度提升的三件套。

### 新增

- **状态栏图标角标**:右上角红圈数字,表示「需要你」类事件总数 —— waiting 会话 + 待处理权限/AskUserQuestion 浮窗。计数按 sessionId 取并集,避免同一会话被 waiting 状态和浮窗双计。`>=10` 显示 `9+`。`badgeCount > 0` 时图标强制非模板,保证红色不被 AppKit 反相成灰。
- **菜单条目副行**:每条 session 在主行下增加灰色小字第二行,按状态切换:waiting → `⏳ <waitingFor 或最近 prompt>`;working → `▸ <toolName>: <key>`(Bash 截 60 字、Edit/Write/Read/NotebookEdit 取 file_path basename);idle → `» <最近 prompt 截 50 字>`。数据反扫 `~/.claude/projects/.../*.jsonl`,30s 全量刷新 + sessions 增减时增量扫(新 `SessionContextReader` + `SessionContextStore`)。
- **AskUserQuestion 改弹浮窗**:原本一闪即逝的「Claude Code 需要你回答」系统通知,改成跟权限浮窗同风格的右上角浮窗,展示完整问题文案 + 全部选项 label/description + 终端按键序号 ① ② ③。本期不代答(CLI 协议不支持外部代答),只提供「跳回终端答」按钮 + ✕。✕ 维持 abandon 语义,不会把 AskUserQuestion 转成 deny。

### Wire 协议

- 不变。`PermissionPromptStore` 现在被两个 manager 共用(`PermissionPromptPanelManager` 处理常规权限,`AskUserQuestionPanelManager` 处理 AskUserQuestion),hook helper 二进制不需要重发。
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: 0.7.0 信息密度提效 changelog"
```

- [ ] **Step 5: 打包验证(可选)**

```bash
./scripts/package.sh
open dist/ClaudeStatusBar.app
```

打包模式下系统通知走 UN(不再降级为 osascript),手测验证打包后的 app 行为与 swift run 一致。

---

## 自查记录

下表是 spec → plan 的覆盖检查:

| spec 章节 | 覆盖 task |
|---|---|
| 1. 状态栏图标角标 视觉 | Task 1, 2 |
| 1. 状态栏图标角标 数据(集合并) | Task 3 |
| 1. 状态栏图标角标 刷新触发 | Task 3(Combine.Merge sink) |
| 1. 状态栏图标角标 模板兼容 | Task 2(`badgeCount > 0` → `isTemplate=false`) |
| 2. 菜单条目 视觉/状态副行 | Task 6 |
| 2. 菜单条目 关键参数提取 | Task 4(formatTool) |
| 2. 菜单条目 数据来源 | Task 4 |
| 2. 菜单条目 刷新策略 | Task 5(30s timer + 增量) |
| 2. 菜单条目 渲染 | Task 6(attributedTitle) |
| 3. AskUserQuestion 复用 vs 新建 | Task 7-9(新建,独立) |
| 3. AskUserQuestion Manager/Store | Task 9, 10 |
| 3. AskUserQuestion routeAskUserQuestionToTerminal 删除 | Task 10 |
| 3. AskUserQuestion 浮窗内容/序号映射 | Task 8 |
| 3. AskUserQuestion 关闭信号(✕/跳转/EOF) | Task 8(✕)、Task 10(跳转)、Task 9(resolved sink 接 EOF 路径) |
| 3. AskUserQuestion Input 解析 | Task 7 |
| 3. AskUserQuestion 全局热键不注册 | Task 9(代码上没注册) |
| 3. AskUserQuestion 多窗堆叠简化方案 | Task 9(layout 起点偏移 80px) |
| 风险与降级 | Task 4(maxFileBytes 100MB)、Task 8(parse 失败降级)、Task 1(`>=10 → 9+`) |
| 测试策略 | Task 1, 2, 4, 7, 9 各自有测试 |

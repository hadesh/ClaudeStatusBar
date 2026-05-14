# Jump to Terminal & 5-Hour Rolling Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two features for ClaudeStatusBar v0.3.0:
1. Click a session → jump to its controlling terminal app (option-click keeps the existing "open cwd in Finder" behavior).
2. Show the current 5-hour rolling usage window (tokens + reset countdown) in the menu.

**Architecture:**
- **Phase 2A.** Walk the session pid's parent chain (via `ps -o ppid=,ucomm=`) until we hit the first registered GUI app, judged by `NSRunningApplication(processIdentifier:)` returning non-nil. Works for any macOS terminal/IDE with an integrated terminal (iTerm2, Terminal, Warp, Tabby, Hyper, Kitty, Ghostty, WezTerm, Alacritty, VS Code, Cursor, Zed, …) — no hardcoded list. The walk is pure logic with two injectable closures (`processInfo`, `isGuiApp`) and is fully unit-tested. Production wiring lives in AppDelegate: the resolved pid feeds back into `NSRunningApplication(processIdentifier:)?.activate(...)`. AppDelegate's existing `openCwd(_:)` becomes the option-click fallback. If no GUI ancestor is found (cron jobs, `nohup`, etc.), beep + `osascript display notification` ("找不到对应终端 — 按住 Option 点击可在 Finder 中打开 cwd").
- **Phase 2B.** New pure aggregator walks `~/.claude/projects/**/*.jsonl` like `LiveUsageAggregator` but parses the top-level ISO 8601 `timestamp` string (with fractional seconds) and keeps only assistant entries within the last 5 hours. Returns a `RollingWindow` (block start = earliest message in the past 5 h, reset = block start + 5 h, totals summed in the block). `UsageTracker` publishes it alongside `lifetimeByModel`. AppDelegate renders a "本 5 小时" section above the lifetime block.

**Tech Stack:** Swift 5.9, AppKit, Foundation, Combine, XCTest, `Foundation.Process` (for `ps`), `NSRunningApplication`, `ISO8601DateFormatter`.

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `Sources/ClaudeStatusBar/Services/ProcessTree.swift` | new | Thin `Foundation.Process` wrapper around `ps -o ppid=,ucomm= -p <pid>`; returns `(parent: Int, name: String)?`. Untested (system call); kept tiny so the testable pieces don't depend on it. |
| `Sources/ClaudeStatusBar/Services/TerminalNavigator.swift` | new | Pure `findGuiAncestor(startingFrom:processInfo:isGuiApp:) -> Int?` — walks parent chain returning the first pid where `isGuiApp` is true, bounded at 32 hops. Foundation-only. |
| `Sources/ClaudeStatusBar/Models/RollingWindow.swift` | new | `RollingWindow` struct (startedAt, resetsAt, inputTokens, outputTokens). |
| `Sources/ClaudeStatusBar/Services/RollingWindowAggregator.swift` | new | Pure `currentWindow(now:projectsRoot:)`. Owns its own JSONL decoders; no shared state with `LiveUsageAggregator` (the file walk is cheap enough to do twice). |
| `Sources/ClaudeStatusBar/Services/UsageTracker.swift` | modify | Add `@Published currentWindow: RollingWindow?` published alongside `lifetimeByModel`. |
| `Sources/ClaudeStatusBar/AppDelegate.swift` | modify | (a) Replace `openCwd` action on session menu items with new `revealSession(_:)` + tooltip update; (b) render a "本 5 小时" section in `rebuildMenu`. |
| `Tests/ClaudeStatusBarTests/TerminalNavigatorTests.swift` | new | Unit tests for `findGuiAncestor` with injected `processInfo` / `isGuiApp` closures. |
| `Tests/ClaudeStatusBarTests/RollingWindowAggregatorTests.swift` | new | Unit tests for the aggregator. |
| `scripts/package.sh` | modify | Bump default version 0.2.0 → 0.3.0. |

The two phases are orthogonal — neither feature touches the other's files. They share only the AppDelegate (different inserts) and the version bump.

---

# Phase 2A — Jump to Terminal

## Task 1: ProcessTree wrapper

**Files:**
- Create: `Sources/ClaudeStatusBar/Services/ProcessTree.swift`

- [ ] **Step 1: Create the wrapper**

Write `Sources/ClaudeStatusBar/Services/ProcessTree.swift`:

```swift
import Foundation

/// Reads a process's parent pid and short executable name via `/bin/ps`. Untested wrapper —
/// used only as the production `processInfo` source for `TerminalNavigator`. The pure logic
/// that consumes it is tested separately with an injectable closure.
public enum ProcessTree {
    public static func info(pid: Int) -> (parent: Int, name: String)? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-o", "ppid=,ucomm=", "-p", String(pid)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // Format: "  1234 zsh"  — leading spaces, ppid, single space, ucomm.
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let parent = Int(parts[0]) else { return nil }
        return (parent: parent, name: String(parts[1]).trimmingCharacters(in: .whitespaces))
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
swift build
```

Expected: clean.

- [ ] **Step 3: Manual sanity check (no commit yet)**

Add a temporary main.swift line or just run a one-off Swift snippet to confirm it returns a sensible value for the current process. Easiest: in your shell, pick a known pid (e.g. your terminal's pid) and run the equivalent `ps -o ppid=,ucomm= -p <pid>` to verify the parsing format. If `ucomm` differs from what's expected (e.g. has trailing whitespace or a different separator on this macOS version), adjust the parser **before** committing — the rest of the plan depends on this returning `(parent, name)` cleanly.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/ProcessTree.swift
git commit -m "feat(navigator): add ProcessTree wrapper around ps"
```

---

## Task 2: findGuiAncestor pure logic with tests

**Files:**
- Create: `Sources/ClaudeStatusBar/Services/TerminalNavigator.swift`
- Create: `Tests/ClaudeStatusBarTests/TerminalNavigatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeStatusBarTests/TerminalNavigatorTests.swift`:

```swift
import XCTest
@testable import ClaudeStatusBar

final class TerminalNavigatorTests: XCTestCase {
    private let neverGui: TerminalNavigator.IsGuiAppFn = { _ in false }
    private let alwaysGui: TerminalNavigator.IsGuiAppFn = { _ in true }

    func testReturnsFirstGuiAncestor() {
        let processInfo: TerminalNavigator.ProcessInfoFn = { pid in
            switch pid {
            case 100: return (parent: 50, name: "claude")
            case 50:  return (parent: 30, name: "zsh")
            case 30:  return (parent: 10, name: "tmux")
            case 10:  return (parent: 1, name: "iTerm2")
            default:  return nil
            }
        }
        // Only pid 10 is a GUI app; everything else (claude, zsh, tmux) is not.
        let isGuiApp: TerminalNavigator.IsGuiAppFn = { $0 == 10 }
        XCTAssertEqual(
            TerminalNavigator.findGuiAncestor(startingFrom: 100, processInfo: processInfo, isGuiApp: isGuiApp),
            10
        )
    }

    func testReturnsStartingPidWhenItselfIsAGuiApp() {
        let processInfo: TerminalNavigator.ProcessInfoFn = { _ in (parent: 1, name: "x") }
        XCTAssertEqual(
            TerminalNavigator.findGuiAncestor(startingFrom: 999, processInfo: processInfo, isGuiApp: alwaysGui),
            999
        )
    }

    func testReturnsNilWhenNoGuiInChain() {
        let processInfo: TerminalNavigator.ProcessInfoFn = { pid in
            switch pid {
            case 100: return (parent: 50, name: "zsh")
            case 50:  return (parent: 1, name: "launchd")
            default:  return nil
            }
        }
        XCTAssertNil(
            TerminalNavigator.findGuiAncestor(startingFrom: 100, processInfo: processInfo, isGuiApp: neverGui)
        )
    }

    func testReturnsNilOnMissingProcess() {
        let processInfo: TerminalNavigator.ProcessInfoFn = { _ in nil }
        XCTAssertNil(
            TerminalNavigator.findGuiAncestor(startingFrom: 100, processInfo: processInfo, isGuiApp: alwaysGui)
        )
    }

    func testBoundsHopCountAt32() {
        var calls = 0
        let processInfo: TerminalNavigator.ProcessInfoFn = { pid in
            calls += 1
            return (parent: pid + 1, name: "zsh")  // chain never bottoms out
        }
        XCTAssertNil(
            TerminalNavigator.findGuiAncestor(startingFrom: 1000, processInfo: processInfo, isGuiApp: neverGui)
        )
        XCTAssertEqual(calls, 32, "should stop after 32 hops to avoid runaway loops")
    }
}
```

- [ ] **Step 2: Run, confirm compile failure**

```bash
swift test --filter ClaudeStatusBarTests.TerminalNavigatorTests
```

Expected: FAIL — "Cannot find 'TerminalNavigator' in scope".

- [ ] **Step 3: Implement the navigator**

Create `Sources/ClaudeStatusBar/Services/TerminalNavigator.swift`:

```swift
import Foundation

public enum TerminalNavigator {
    public typealias ProcessInfoFn = (Int) -> (parent: Int, name: String)?
    public typealias IsGuiAppFn = (Int) -> Bool

    /// Walks the parent process chain and returns the first pid where `isGuiApp` returns true.
    /// "GUI app" means a LaunchServices-registered .app (i.e. `NSRunningApplication(processIdentifier:)`
    /// returns a non-nil instance). The starting pid itself is checked first.
    /// Bounded at 32 hops so a corrupt parent map can never spin forever.
    public static func findGuiAncestor(
        startingFrom pid: Int,
        processInfo: ProcessInfoFn,
        isGuiApp: IsGuiAppFn
    ) -> Int? {
        var current = pid
        for _ in 0..<32 {
            guard current > 1 else { return nil }
            if isGuiApp(current) { return current }
            guard let info = processInfo(current) else { return nil }
            current = info.parent
        }
        return nil
    }
}
```

The `name` field of `processInfo`'s return value is unused by the algorithm — we keep it in the tuple to match `ProcessTree.info(pid:)`'s signature so the production wiring stays a one-liner. (`name` is also handy for ad-hoc debug logging if needed later.)

- [ ] **Step 4: Run tests, confirm pass**

```bash
swift test --filter ClaudeStatusBarTests.TerminalNavigatorTests
```

Expected: 5 tests pass. Full suite: 67 + 5 = **72 tests** pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/TerminalNavigator.swift Tests/ClaudeStatusBarTests/TerminalNavigatorTests.swift
git commit -m "feat(navigator): walk parent chain to find owning GUI app"
```

---

## Task 3: AppDelegate revealSession handler with option-click fallback

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

This task does three things in one commit because they're inseparable: (a) change the menu item's action selector, (b) add the new handler with option-click branching, (c) update the tooltip.

- [ ] **Step 1: Read the current AppDelegate**

Open `Sources/ClaudeStatusBar/AppDelegate.swift` and locate:
- `makeSessionItem(_:)` — currently builds the per-session menu item with `action: #selector(openCwd(_:))` and `representedObject = s.cwd` and tooltip `s.cwd`.
- `openCwd(_:)` — currently the only action handler reading `representedObject as? String`.

- [ ] **Step 2: Update `makeSessionItem` to pass the whole Session and the new selector**

In `makeSessionItem`, change:

```swift
        let item = NSMenuItem(title: title, action: #selector(openCwd(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s.cwd
        item.toolTip = s.cwd
```

to:

```swift
        let item = NSMenuItem(title: title, action: #selector(revealSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s
        item.toolTip = "\(s.cwd)\n按住 Option 点击在 Finder 中打开"
```

- [ ] **Step 3: Replace `openCwd(_:)` with `revealSession(_:)` plus the helpers**

Replace the existing method (the one that currently reads `representedObject as? String` and calls `NSWorkspace.shared.open`):

```swift
    @objc private func openCwd(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
```

with:

```swift
    @objc private func revealSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        if optionHeld {
            openCwdInFinder(session.cwd)
            return
        }
        guard let app = findOwningApp(of: session.pid) else {
            notifyTerminalNotFound()
            return
        }
        app.activate(options: [.activateAllWindows])
    }

    private func findOwningApp(of sessionPid: Int) -> NSRunningApplication? {
        let resolved = TerminalNavigator.findGuiAncestor(
            startingFrom: sessionPid,
            processInfo: ProcessTree.info(pid:),
            isGuiApp: { NSRunningApplication(processIdentifier: pid_t($0)) != nil }
        )
        return resolved.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
    }

    private func openCwdInFinder(_ cwd: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    private func notifyTerminalNotFound() {
        NSSound.beep()
        showSystemNotification(
            title: "找不到对应终端",
            body: "按住 Option 点击可在 Finder 中打开 cwd"
        )
    }

    private func showSystemNotification(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
```

Notes:
- The double `NSRunningApplication(processIdentifier:)` call inside `findOwningApp` (once via the closure, once for the return value) is intentional and trivial — both calls just hit a LaunchServices cache. Keeps the pure algorithm Foundation-only.
- We use `osascript display notification` for the failure popup (not `UNUserNotificationCenter`) because (a) it works in both `swift run` and the packaged app, (b) it doesn't require auth, and (c) duplicating the bundle-id branch from `WaitingNotifier` for one-off failure popups isn't worth it. Existing `WaitingNotifier` is unchanged.
- There's no separate "app not installed" branch: if `NSRunningApplication(processIdentifier:)` says yes, it's running, so it's installed. The `notifyTerminalNotFound` path covers both "no GUI ancestor" (cron / nohup / `launchd` start) and any pathological lookup race.

- [ ] **Step 4: Build & run tests**

```bash
swift build
swift test
```

Expected: green, **72 tests** pass.

- [ ] **Step 5: Smoke test the .app**

```bash
./scripts/package.sh
# Quit any running ClaudeStatusBar instance (menu → Quit) before launching the new build.
open dist/ClaudeStatusBar.app
sleep 3
pgrep -f "dist/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBar"
# Manually click a session in the menu and verify:
#   - plain click activates the GUI app that owns the shell (any terminal / IDE works)
#   - option-click opens cwd in Finder
#   - if the session was started outside any GUI app (cron / nohup / etc.): beep + notification
# Then kill the smoke instance:
PID=$(pgrep -f "dist/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBar" | head -1)
kill "$PID"
```

If you can't currently exercise all three branches manually, at minimum confirm the app launches without crashing.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "feat(navigator): click session activates owning GUI app; option-click opens Finder"
```

---

# Phase 2B — 5-Hour Rolling Usage Window

## Task 4: RollingWindow model

**Files:**
- Create: `Sources/ClaudeStatusBar/Models/RollingWindow.swift`

- [ ] **Step 1: Create the model**

Write `Sources/ClaudeStatusBar/Models/RollingWindow.swift`:

```swift
import Foundation

public struct RollingWindow: Equatable {
    public let startedAt: Date
    public let resetsAt: Date
    public let inputTokens: Int
    public let outputTokens: Int

    public init(startedAt: Date, resetsAt: Date, inputTokens: Int, outputTokens: Int) {
        self.startedAt = startedAt
        self.resetsAt = resetsAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public var totalTokens: Int { inputTokens + outputTokens }

    public func remaining(now: Date) -> TimeInterval {
        max(0, resetsAt.timeIntervalSince(now))
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
swift build
```

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStatusBar/Models/RollingWindow.swift
git commit -m "feat(window): add RollingWindow model"
```

---

## Task 5: RollingWindowAggregator pure function with tests

**Files:**
- Create: `Sources/ClaudeStatusBar/Services/RollingWindowAggregator.swift`
- Create: `Tests/ClaudeStatusBarTests/RollingWindowAggregatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeStatusBarTests/RollingWindowAggregatorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run, confirm compile failure**

```bash
swift test --filter ClaudeStatusBarTests.RollingWindowAggregatorTests
```

Expected: FAIL — "Cannot find 'RollingWindowAggregator' in scope".

- [ ] **Step 3: Implement the aggregator**

Create `Sources/ClaudeStatusBar/Services/RollingWindowAggregator.swift`:

```swift
import Foundation

public enum RollingWindowAggregator {
    public static let windowDuration: TimeInterval = 5 * 60 * 60

    public static let defaultProjectsRoot: URL = LiveUsageAggregator.defaultProjectsRoot

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Returns the current 5-hour rolling window or nil if no assistant activity has happened
    /// in the last 5 hours. The block's `startedAt` is the earliest assistant message inside
    /// the window; `resetsAt` is `startedAt + 5h`.
    public static func currentWindow(
        now: Date = Date(),
        projectsRoot: URL = defaultProjectsRoot
    ) -> RollingWindow? {
        let cutoff = now.addingTimeInterval(-windowDuration)
        let entries = collectEntries(since: cutoff, projectsRoot: projectsRoot)
        guard !entries.isEmpty else { return nil }
        let blockStart = entries.map(\.timestamp).min() ?? cutoff
        let inputTokens = entries.reduce(0) { $0 + $1.inputTokens }
        let outputTokens = entries.reduce(0) { $0 + $1.outputTokens }
        return RollingWindow(
            startedAt: blockStart,
            resetsAt: blockStart.addingTimeInterval(windowDuration),
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    private struct Entry {
        let timestamp: Date
        let inputTokens: Int
        let outputTokens: Int
    }

    private static func collectEntries(since cutoff: Date, projectsRoot: URL) -> [Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var entries: [Entry] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            collect(file: url, cutoff: cutoff, into: &entries)
        }
        return entries
    }

    private static func collect(file url: URL, cutoff: Date, into entries: inout [Entry]) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let raw = try? decoder.decode(JSONLEntry.self, from: lineData),
                  raw.type == "assistant",
                  let tsStr = raw.timestamp,
                  let ts = isoFormatter.date(from: tsStr),
                  ts >= cutoff,
                  let usage = raw.message?.usage else { continue }
            entries.append(Entry(
                timestamp: ts,
                inputTokens: usage.input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0
            ))
        }
    }

    private struct JSONLEntry: Decodable {
        let type: String?
        let timestamp: String?
        let message: JSONLMessage?
    }
    private struct JSONLMessage: Decodable {
        let usage: JSONLUsage?
    }
    private struct JSONLUsage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
    }
}
```

- [ ] **Step 4: Run all aggregator tests, confirm pass**

```bash
swift test --filter ClaudeStatusBarTests.RollingWindowAggregatorTests
```

Expected: 9 tests pass.

- [ ] **Step 5: Run full suite to confirm no regression**

```bash
swift test
```

Expected: 72 + 9 = **81 tests** pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/RollingWindowAggregator.swift Tests/ClaudeStatusBarTests/RollingWindowAggregatorTests.swift
git commit -m "feat(window): add RollingWindowAggregator pure function"
```

---

## Task 6: Publish currentWindow through UsageTracker

**Files:**
- Modify: `Sources/ClaudeStatusBar/Services/UsageTracker.swift`

- [ ] **Step 1: Add the published property and update `refresh`**

In `Sources/ClaudeStatusBar/Services/UsageTracker.swift`, locate:

```swift
    @Published public private(set) var lifetimeByModel: [ModelLifetimeUsage] = []
```

Add directly below it:

```swift
    @Published public private(set) var currentWindow: RollingWindow? = nil
```

Then locate the body of `refresh()`:

```swift
    public func refresh() {
        let projectsRoot = self.projectsRoot
        let publishQueue = self.publishQueue
        workQueue.async { [weak self] in
            let result = LiveUsageAggregator.aggregate(from: projectsRoot)
            publishQueue.async { [weak self] in
                self?.lifetimeByModel = result
            }
        }
    }
```

Replace it with:

```swift
    public func refresh() {
        let projectsRoot = self.projectsRoot
        let publishQueue = self.publishQueue
        workQueue.async { [weak self] in
            let lifetime = LiveUsageAggregator.aggregate(from: projectsRoot)
            let window = RollingWindowAggregator.currentWindow(now: Date(), projectsRoot: projectsRoot)
            publishQueue.async { [weak self] in
                self?.lifetimeByModel = lifetime
                self?.currentWindow = window
            }
        }
    }
```

- [ ] **Step 2: Build & run tests**

```bash
swift build
swift test
```

Expected: 81 tests pass. UsageTracker has no unit tests of its own (it's a thin timer wrapper), so no test changes needed.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/UsageTracker.swift
git commit -m "feat(window): publish currentWindow alongside lifetime totals"
```

---

## Task 7: Render "本 5 小时" section in the menu

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

- [ ] **Step 1: Update the Combine sink to receive `currentWindow`**

Locate in `applicationDidFinishLaunching`:

```swift
        Publishers.CombineLatest(store.$sessions, usageTracker.$lifetimeByModel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions, lifetime in
                guard let self else { return }
                self.refreshIcon()
                self.rebuildMenu(with: sessions, lifetime: lifetime)
            }
            .store(in: &cancellables)
```

Replace with:

```swift
        Publishers.CombineLatest3(store.$sessions, usageTracker.$lifetimeByModel, usageTracker.$currentWindow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions, lifetime, window in
                guard let self else { return }
                self.refreshIcon()
                self.rebuildMenu(with: sessions, lifetime: lifetime, window: window)
            }
            .store(in: &cancellables)
```

- [ ] **Step 2: Update `rebuildMenu` signature and add the new section**

Locate the function signature `private func rebuildMenu(with sessions: [Session], lifetime: [ModelLifetimeUsage])`. Change it to:

```swift
    private func rebuildMenu(with sessions: [Session], lifetime: [ModelLifetimeUsage], window: RollingWindow?) {
```

Find the line where the lifetime block starts being appended (the existing `appendLifetimeItems(to: menu, lifetime: lifetime)` call). Insert directly above it:

```swift
        appendCurrentWindowItems(to: menu, window: window)
        menu.addItem(.separator())
```

So the menu order becomes: header → sessions → separator → **本 5 小时 section + separator** → lifetime section → separator → 开机自启 → separator → Quit.

- [ ] **Step 3: Add the helper method**

After the existing `appendLifetimeItems(to:lifetime:)` method, add:

```swift
    private func appendCurrentWindowItems(to menu: NSMenu, window: RollingWindow?) {
        let header = NSMenuItem(title: "本 5 小时", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        guard let window else {
            let empty = NSMenuItem(title: "  (无活动)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let usage = NSMenuItem(
            title: "用量 \(formatTokens(window.totalTokens))  In \(formatTokens(window.inputTokens)) · Out \(formatTokens(window.outputTokens))",
            action: nil, keyEquivalent: ""
        )
        usage.isEnabled = false
        usage.indentationLevel = 1
        menu.addItem(usage)

        let remaining = window.remaining(now: Date())
        let reset = NSMenuItem(
            title: "重置 \(formatRemaining(remaining)) 后",
            action: nil, keyEquivalent: ""
        )
        reset.isEnabled = false
        reset.indentationLevel = 1
        menu.addItem(reset)
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
```

- [ ] **Step 4: Build & run tests**

```bash
swift build
swift test
```

Expected: 81 tests pass.

- [ ] **Step 5: Smoke test**

```bash
./scripts/package.sh
# Quit any running instance.
open dist/ClaudeStatusBar.app
sleep 3
PID=$(pgrep -f "dist/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBar" | head -1)
[ -n "$PID" ] && echo "Launched OK: $PID" || echo "FAIL"
# Manually open the menu and verify the "本 5 小时" section appears with usage and reset countdown.
kill "$PID"
```

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "feat(window): render 本 5 小时 section in status menu"
```

---

# Final

## Task 8: Bump version & repackage

**Files:**
- Modify: `scripts/package.sh`

- [ ] **Step 1: Bump default version**

In `scripts/package.sh`, change:

```bash
VERSION="${VERSION:-0.2.0}"
```

to:

```bash
VERSION="${VERSION:-0.3.0}"
```

- [ ] **Step 2: Repackage and verify**

```bash
./scripts/package.sh
ls dist/
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/ClaudeStatusBar.app/Contents/Info.plist
```

Expected: `dist/ClaudeStatusBar-0.3.0.zip` exists; Info.plist version is `0.3.0`.

- [ ] **Step 3: Commit**

```bash
git add scripts/package.sh
git commit -m "chore: bump version to 0.3.0"
```

---

## Out of scope

This plan deliberately does NOT include:

- **Tab-level targeting inside iTerm2 / Terminal.app.** v1 brings the resolved app to the foreground via `NSRunningApplication.activate(options:)` only — no window/tab targeting. If real users find "activate app only" insufficient, the natural extension is a `bundleId → SpecialHandler` registry that gets consulted before the default activate path: iTerm2 / Terminal.app handlers can use AppleScript + tty matching to focus the exact tab; everything else falls through to the default. The current architecture supports this without rework.
- **Per-model breakdown of the 5h window.** The menu shows aggregate input/output tokens only. If you want per-model split (like the lifetime section), that's a separate display task.
- **Plan-tier-aware progress bar.** Per the design call, we only show absolute usage — no "% of Pro/Max limit". A future plan can add a "settings" submenu for plan tier if requested.
- **Refactor of `WaitingNotifier` / new `SystemNotifier`.** AppDelegate's `showSystemNotification` helper is intentionally inline + osascript-only to avoid touching the existing notifier in this round. If we end up with more failure-popup sites, extract then.
- **Encapsulating AppDelegate's reminder timer (Phase 1 reviewer's note).** AppDelegate is now ~200 lines; still readable. Extract when it crosses ~300 or when a third "settings"-like feature lands.

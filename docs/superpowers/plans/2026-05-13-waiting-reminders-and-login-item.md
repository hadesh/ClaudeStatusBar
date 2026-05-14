# Waiting Reminders & Launch at Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add (a) repeated reminders when a Claude Code session stays in `waiting`, and (b) a "Launch at Login" toggle in the menu.

**Architecture:**
- Pure value-type `WaitingReminderTracker` that, given the current sessions plus `now`, emits the sessions that should fire a reminder right now. Driven by a 5 s timer in `AppDelegate`. The first transition into `waiting` is still owned by the existing `WaitingTransitionDetector`, so the two are orthogonal — the tracker only handles repeats.
- Thin wrapper `LoginItemController` over `SMAppService.mainApp` (macOS 13+, no helper bundle). The menu shows the toggle only when the app is launched from a real bundle (i.e. not `swift run`).

**Tech Stack:** Swift 5.9, AppKit, Combine, `ServiceManagement.SMAppService`, XCTest.

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `Sources/ClaudeStatusBar/Services/WaitingReminderTracker.swift` | new | Stateful per-pid scheduler that decides when to re-fire a "still waiting" notification. |
| `Sources/ClaudeStatusBar/Services/LoginItemController.swift` | new | Thin SMAppService wrapper: read enabled status, register/unregister. |
| `Sources/ClaudeStatusBar/Services/WaitingNotifier.swift` | modify | Make notification identifier unique per call so reminders don't collapse. |
| `Sources/ClaudeStatusBar/AppDelegate.swift` | modify | Wire reminder timer; add Launch-at-Login menu item. |
| `Tests/ClaudeStatusBarTests/WaitingReminderTrackerTests.swift` | new | Unit tests for the tracker. |
| `scripts/package.sh` | modify | Bump default version to 0.2.0. |

The tracker is fully testable as a pure value type with an injected `now`. The login wrapper is intentionally thin and not unit-tested — its behavior is determined by the OS and is verified manually.

---

## Task 1: Scaffold WaitingReminderTracker (first sighting yields no reminder)

**Files:**
- Create: `Sources/ClaudeStatusBar/Services/WaitingReminderTracker.swift`
- Create: `Tests/ClaudeStatusBarTests/WaitingReminderTrackerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeStatusBarTests/WaitingReminderTrackerTests.swift`:

```swift
import XCTest
@testable import ClaudeStatusBar

final class WaitingReminderTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000_000)
    private let cfg = WaitingReminderTracker.Config(initialDelay: 30, interval: 30, maxReminders: 3)

    private func makeSession(pid: Int, status: String = "waiting") -> Session {
        let json = #"""
        {"pid":\#(pid),"sessionId":"s\#(pid)","cwd":"/x","startedAt":0,"version":"v","kind":"interactive","entrypoint":"cli","status":"\#(status)","updatedAt":0}
        """#.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    func testFirstSightingDoesNotReturnReminder() {
        var tracker = WaitingReminderTracker(config: cfg)
        let s = makeSession(pid: 1)
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0).map(\.pid), [])
    }
}
```

- [ ] **Step 2: Run the test, confirm it fails to compile**

```bash
swift test --filter ClaudeStatusBarTests.WaitingReminderTrackerTests
```

Expected: FAIL with "cannot find 'WaitingReminderTracker' in scope".

- [ ] **Step 3: Create the minimal tracker**

Create `Sources/ClaudeStatusBar/Services/WaitingReminderTracker.swift`:

```swift
import Foundation

public struct WaitingReminderTracker {
    public struct Config: Equatable {
        public let initialDelay: TimeInterval
        public let interval: TimeInterval
        public let maxReminders: Int
        public init(initialDelay: TimeInterval, interval: TimeInterval, maxReminders: Int) {
            self.initialDelay = initialDelay
            self.interval = interval
            self.maxReminders = maxReminders
        }
        public static let `default` = Config(initialDelay: 30, interval: 30, maxReminders: 3)
    }

    private let config: Config
    private var state: [Int: PerPid] = [:]

    private struct PerPid {
        let firstSeenAt: Date
        var lastNotifiedAt: Date?
        var remindersFired: Int
    }

    public init(config: Config = .default) {
        self.config = config
    }

    public mutating func tick(sessions: [Session], now: Date) -> [Session] {
        let waitingPids = Set(sessions.filter { $0.status == .waiting }.map(\.pid))
        state = state.filter { waitingPids.contains($0.key) }
        for s in sessions where s.status == .waiting && state[s.pid] == nil {
            state[s.pid] = PerPid(firstSeenAt: now, lastNotifiedAt: nil, remindersFired: 0)
        }
        return []
    }
}
```

- [ ] **Step 4: Run the test, confirm it passes**

```bash
swift test --filter ClaudeStatusBarTests.WaitingReminderTrackerTests
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/WaitingReminderTracker.swift Tests/ClaudeStatusBarTests/WaitingReminderTrackerTests.swift
git commit -m "feat(reminders): scaffold WaitingReminderTracker"
```

---

## Task 2: Reminder fires after initialDelay

**Files:**
- Modify: `Sources/ClaudeStatusBar/Services/WaitingReminderTracker.swift`
- Modify: `Tests/ClaudeStatusBarTests/WaitingReminderTrackerTests.swift`

- [ ] **Step 1: Add the failing test**

Append inside `WaitingReminderTrackerTests`:

```swift
    func testReminderFiresAfterInitialDelay() {
        var tracker = WaitingReminderTracker(config: cfg)
        let s = makeSession(pid: 1)
        _ = tracker.tick(sessions: [s], now: t0)
        XCTAssertEqual(
            tracker.tick(sessions: [s], now: t0.addingTimeInterval(29)).map(\.pid),
            [],
            "1 s short of delay → no reminder"
        )
        XCTAssertEqual(
            tracker.tick(sessions: [s], now: t0.addingTimeInterval(30)).map(\.pid),
            [1],
            "exactly at delay → reminder"
        )
    }
```

- [ ] **Step 2: Run and confirm it fails**

```bash
swift test --filter ClaudeStatusBarTests.WaitingReminderTrackerTests/testReminderFiresAfterInitialDelay
```

Expected: FAIL — second assertion got `[]`.

- [ ] **Step 3: Replace the body of `tick` with the full scheduler**

In `Sources/ClaudeStatusBar/Services/WaitingReminderTracker.swift`, replace the entire `tick` method with:

```swift
    public mutating func tick(sessions: [Session], now: Date) -> [Session] {
        let waitingPids = Set(sessions.filter { $0.status == .waiting }.map(\.pid))
        state = state.filter { waitingPids.contains($0.key) }
        var out: [Session] = []
        for s in sessions where s.status == .waiting {
            guard var perPid = state[s.pid] else {
                state[s.pid] = PerPid(firstSeenAt: now, lastNotifiedAt: nil, remindersFired: 0)
                continue
            }
            guard perPid.remindersFired < config.maxReminders else { continue }
            let waited = now.timeIntervalSince(perPid.firstSeenAt)
            guard waited >= config.initialDelay else { continue }
            let lastFired = perPid.lastNotifiedAt ?? .distantPast
            guard now.timeIntervalSince(lastFired) >= config.interval else { continue }
            perPid.remindersFired += 1
            perPid.lastNotifiedAt = now
            state[s.pid] = perPid
            out.append(s)
        }
        return out
    }
```

- [ ] **Step 4: Run all tracker tests, confirm pass**

```bash
swift test --filter ClaudeStatusBarTests.WaitingReminderTrackerTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/WaitingReminderTracker.swift Tests/ClaudeStatusBarTests/WaitingReminderTrackerTests.swift
git commit -m "feat(reminders): fire reminder after initialDelay"
```

---

## Task 3: Repeat up to maxReminders, respect interval

**Files:**
- Modify: `Tests/ClaudeStatusBarTests/WaitingReminderTrackerTests.swift`

- [ ] **Step 1: Add tests covering repeat & interval**

Append inside `WaitingReminderTrackerTests`:

```swift
    func testFiresRepeatedlyUpToMax() {
        var tracker = WaitingReminderTracker(config: cfg)
        let s = makeSession(pid: 1)
        _ = tracker.tick(sessions: [s], now: t0)
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(30)).map(\.pid), [1], "1st")
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(60)).map(\.pid), [1], "2nd")
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(90)).map(\.pid), [1], "3rd")
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(120)).map(\.pid), [], "stop after max")
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(1000)).map(\.pid), [], "still stopped")
    }

    func testRespectsIntervalBetweenReminders() {
        var tracker = WaitingReminderTracker(config: cfg)
        let s = makeSession(pid: 1)
        _ = tracker.tick(sessions: [s], now: t0)
        _ = tracker.tick(sessions: [s], now: t0.addingTimeInterval(30))   // 1st reminder
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(45)).map(\.pid), [], "too early")
        XCTAssertEqual(tracker.tick(sessions: [s], now: t0.addingTimeInterval(60)).map(\.pid), [1], "interval reached")
    }
```

- [ ] **Step 2: Run, confirm pass (the implementation from Task 2 already covers these)**

```bash
swift test --filter ClaudeStatusBarTests.WaitingReminderTrackerTests
```

Expected: 4 tests pass. If any fail, revisit Task 2's `tick` body before continuing.

- [ ] **Step 3: Commit**

```bash
git add Tests/ClaudeStatusBarTests/WaitingReminderTrackerTests.swift
git commit -m "test(reminders): cover repeat & interval behavior"
```

---

## Task 4: State clears when waiting ends; multi-session independence

**Files:**
- Modify: `Tests/ClaudeStatusBarTests/WaitingReminderTrackerTests.swift`

- [ ] **Step 1: Add the remaining tests**

Append inside `WaitingReminderTrackerTests`:

```swift
    func testStateClearsWhenSessionLeavesWaiting() {
        var tracker = WaitingReminderTracker(config: cfg)
        let waiting = makeSession(pid: 1)
        let busy = makeSession(pid: 1, status: "busy")
        _ = tracker.tick(sessions: [waiting], now: t0)
        _ = tracker.tick(sessions: [busy], now: t0.addingTimeInterval(60))
        // Re-enter waiting at t=120 → must be a fresh "first sighting".
        XCTAssertEqual(
            tracker.tick(sessions: [waiting], now: t0.addingTimeInterval(120)).map(\.pid),
            [],
            "re-entry is fresh"
        )
        XCTAssertEqual(
            tracker.tick(sessions: [waiting], now: t0.addingTimeInterval(150)).map(\.pid),
            [1],
            "fires after delay"
        )
    }

    func testIgnoresNonWaitingSessions() {
        var tracker = WaitingReminderTracker(config: cfg)
        let busy = makeSession(pid: 1, status: "busy")
        let idle = makeSession(pid: 2, status: "idle")
        XCTAssertEqual(tracker.tick(sessions: [busy, idle], now: t0).map(\.pid), [])
        XCTAssertEqual(tracker.tick(sessions: [busy, idle], now: t0.addingTimeInterval(1000)).map(\.pid), [])
    }

    func testHandlesMultipleSessionsIndependently() {
        var tracker = WaitingReminderTracker(config: cfg)
        let s1 = makeSession(pid: 1)
        let s2 = makeSession(pid: 2)
        _ = tracker.tick(sessions: [s1], now: t0)                         // s1 first seen at t=0
        _ = tracker.tick(sessions: [s1, s2], now: t0.addingTimeInterval(15))  // s2 first seen at t=15
        XCTAssertEqual(
            tracker.tick(sessions: [s1, s2], now: t0.addingTimeInterval(30)).map(\.pid),
            [1],
            "only s1 due"
        )
        XCTAssertEqual(
            tracker.tick(sessions: [s1, s2], now: t0.addingTimeInterval(45)).map(\.pid),
            [2],
            "now s2 due"
        )
    }
```

- [ ] **Step 2: Run, confirm pass**

```bash
swift test --filter ClaudeStatusBarTests.WaitingReminderTrackerTests
```

Expected: 7 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/ClaudeStatusBarTests/WaitingReminderTrackerTests.swift
git commit -m "test(reminders): cover state clearing & multi-session"
```

---

## Task 5: Make WaitingNotifier identifier unique per call

The current identifier is `claude-waiting-{pid}-{updatedAt}`. If the CLI hasn't rewritten `~/.claude/sessions/{pid}.json` between reminder ticks, `updatedAt` is unchanged and macOS will collapse subsequent reminders into the original notification (silent). Use a monotonic millisecond timestamp instead.

**Files:**
- Modify: `Sources/ClaudeStatusBar/Services/WaitingNotifier.swift`

- [ ] **Step 1: Replace the identifier line**

In `Sources/ClaudeStatusBar/Services/WaitingNotifier.swift`, replace:

```swift
            let req = UNNotificationRequest(
                identifier: "claude-waiting-\(session.pid)-\(Int(session.updatedAt.timeIntervalSince1970))",
                content: content, trigger: nil
            )
```

with:

```swift
            let req = UNNotificationRequest(
                identifier: "claude-waiting-\(session.pid)-\(Int(Date().timeIntervalSince1970 * 1000))",
                content: content, trigger: nil
            )
```

- [ ] **Step 2: Run all tests, confirm green**

```bash
swift test
```

Expected: all suites pass; this change has no test coverage on its own.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/WaitingNotifier.swift
git commit -m "fix(notifier): unique identifier per call so reminders don't collapse"
```

---

## Task 6: Wire reminder timer into AppDelegate

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

- [ ] **Step 1: Add tracker & timer properties**

In `Sources/ClaudeStatusBar/AppDelegate.swift`, immediately after the line:

```swift
    private var detector = WaitingTransitionDetector()
```

insert:

```swift
    private var reminderTracker = WaitingReminderTracker()
    private var reminderTimer: DispatchSourceTimer?
```

- [ ] **Step 2: Start the timer in `applicationDidFinishLaunching`**

At the end of `applicationDidFinishLaunching`, after `usageTracker.start()`, append:

```swift
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 5.0, repeating: 5.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for s in self.reminderTracker.tick(sessions: self.store.sessions, now: Date()) {
                self.notifier.notify(session: s)
            }
        }
        t.resume()
        reminderTimer = t
```

- [ ] **Step 3: Cancel the timer in `applicationWillTerminate`**

In `applicationWillTerminate`, after `usageTracker.stop()`, append:

```swift
        reminderTimer?.cancel()
        reminderTimer = nil
```

- [ ] **Step 4: Build & run tests**

```bash
swift build
swift test
```

Expected: build succeeds; all tests green.

- [ ] **Step 5: Smoke test the .app**

```bash
./scripts/package.sh
# Quit any existing ClaudeStatusBar instance via its menu first.
open dist/ClaudeStatusBar.app
```

Manual check: with no `waiting` sessions, no notifications fire for at least a minute. Quit the app afterwards.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "feat(reminders): tick WaitingReminderTracker every 5s in AppDelegate"
```

---

## Task 7: LoginItemController — minimal SMAppService wrapper

**Files:**
- Create: `Sources/ClaudeStatusBar/Services/LoginItemController.swift`

- [ ] **Step 1: Create the wrapper**

Create `Sources/ClaudeStatusBar/Services/LoginItemController.swift`:

```swift
import Foundation
import ServiceManagement

public final class LoginItemController {
    /// SMAppService.mainApp only works inside a code-signed bundle. `swift run`
    /// starts without a bundle identifier, so we hide the menu item there.
    public static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
swift build
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/LoginItemController.swift
git commit -m "feat(login): add LoginItemController wrapping SMAppService.mainApp"
```

---

## Task 8: Add "开机自启" menu item

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

- [ ] **Step 1: Add controller property**

Below the `reminderTimer` property added in Task 6, add:

```swift
    private let loginItem = LoginItemController()
```

- [ ] **Step 2: Insert the menu item between lifetime block and Quit separator**

In `rebuildMenu`, locate the sequence:

```swift
        appendLifetimeItems(to: menu, lifetime: lifetime)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
```

and insert the Login-Item block between `appendLifetimeItems(...)` and the `.separator()` call:

```swift
        appendLifetimeItems(to: menu, lifetime: lifetime)
        if LoginItemController.isAvailable {
            let item = NSMenuItem(
                title: "开机自启",
                action: #selector(toggleLoginItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = loginItem.isEnabled ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
```

- [ ] **Step 3: Add the toggle handler**

After the existing `openCwd(_:)` method (it ends right before the closing `}` of `AppDelegate`), add:

```swift
    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            try loginItem.setEnabled(!loginItem.isEnabled)
        } catch {
            NSLog("Toggle login item failed: \(error)")
        }
        rebuildMenu(with: store.sessions, lifetime: usageTracker.lifetimeByModel)
    }
```

- [ ] **Step 4: Build & run all tests**

```bash
swift build
swift test
```

Expected: green.

- [ ] **Step 5: Smoke test**

```bash
./scripts/package.sh
# Quit any existing ClaudeStatusBar via its menu first.
open dist/ClaudeStatusBar.app
```

Manual checks:
1. Menu shows "开机自启", unchecked.
2. Click it → System Settings → General → Login Items lists `ClaudeStatusBar`. Re-open the menu — checkmark should be on.
3. Click again → unregisters; checkmark off.

If `register()` triggers a one-time "Background Items Added" prompt and the click feels ignored, that's expected on first run. The next click reflects current state.

Quit the app after testing.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "feat(login): add Launch at Login toggle to status menu"
```

---

## Task 9: Bump version to 0.2.0 and repackage

**Files:**
- Modify: `scripts/package.sh`

- [ ] **Step 1: Bump default version**

In `scripts/package.sh`, change:

```bash
VERSION="${VERSION:-0.1.0}"
```

to:

```bash
VERSION="${VERSION:-0.2.0}"
```

- [ ] **Step 2: Repackage and verify**

```bash
./scripts/package.sh
ls dist/
```

Expected: `dist/ClaudeStatusBar-0.2.0.zip` exists; `dist/ClaudeStatusBar.app/Contents/Info.plist` shows `CFBundleShortVersionString = 0.2.0`:

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/ClaudeStatusBar.app/Contents/Info.plist
```

- [ ] **Step 3: Commit**

```bash
git add scripts/package.sh
git commit -m "chore: bump version to 0.2.0"
```

---

## Out of scope (separate plans)

This plan deliberately does NOT cover the remaining roadmap features. Each deserves its own plan because the design space is meaningfully larger:

- **Feature #1: 点会话 → 跳回对应终端窗口/Tab.** Requires per-terminal-app handlers (iTerm2 / Terminal.app via AppleScript first; Ghostty / WezTerm / Alacritty as best-effort), process-tree walking from session pid to controlling terminal, and a fallback to today's "open cwd in Finder" behavior. Will be drafted as `docs/superpowers/plans/<date>-jump-to-terminal.md` after this plan lands.
- **Feature #2: 5 h 用量窗口进度.** Requires a model→price table, a rolling-window aggregator over `~/.claude/projects/**/*.jsonl` with timestamps, plan-tier configuration, and new menu rendering. Will be drafted as `docs/superpowers/plans/<date>-five-hour-window.md` afterwards.

Splitting them keeps each plan independently shippable and lets us incorporate any learnings from this phase before committing the design for the next.

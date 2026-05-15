# Session 行 Hover 终止按钮 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 状态栏菜单 session 行 hover 时右侧显示圆形 stop 按钮,单击向 pid 发 SIGINT(等同 Ctrl+C),中断当前 turn 但保留会话。仅 busy/waiting 显示按钮,无二次确认,点完立即关菜单。

**Architecture:** 新增静态 `ProcessTerminator`(参照 `ProcessLiveness` 形状)封装 `kill(pid, SIGINT)` 并支持注入便于单测;新增自定义 `SessionRowView`(`NSView` 子类)替换 `AppDelegate.makeSessionItem` 里现有 `attributedTitle` 路径,自己负责主行/副行渲染、hover 跟踪、高亮态背景、终止按钮显隐。AppDelegate 提供 `revealSession(forPid:)` 闭包供 view 回调,Option-click 跳 Finder 的语义保持不变。

**Tech Stack:** Swift 5.9, AppKit (Cocoa), Foundation, Darwin (`kill(2)`, `SIGINT`), XCTest, SF Symbols (`stop.circle.fill`).

参考 spec: `docs/superpowers/specs/2026-05-15-session-terminate-button-design.md`。

---

## File Structure

| 文件 | 状态 | 职责 |
|------|------|------|
| `Sources/ClaudeStatusBar/Services/ProcessTerminator.swift` | new | `sendInterrupt(pid:) -> Bool`,封装 `kill(pid, SIGINT)`,`killFn` 可注入 |
| `Sources/ClaudeStatusBar/UI/SessionRowView.swift` | new | 单个 session 主行的自定义 NSView:文字渲染 + hover 跟踪 + 高亮态绘制 + 终止按钮 |
| `Sources/ClaudeStatusBar/AppDelegate.swift` | modify | `makeSessionItem` 改用 `SessionRowView`;新增 `revealSession(forPid:)` 入口;删旧的 `@objc revealSession(_:)` |
| `Tests/ClaudeStatusBarTests/ProcessTerminatorTests.swift` | new | 3 个测试:成功调用、非正 pid 拒绝、kill 失败返回 false |
| `Tests/ClaudeStatusBarTests/SessionRowViewTests.swift` | new | 4 个测试:idle 不建按钮、busy 建按钮初始隐藏、hover 显隐、点击回调 |

---

## Task 1: ProcessTerminator + tests

**Files:**
- Create: `Sources/ClaudeStatusBar/Services/ProcessTerminator.swift`
- Create: `Tests/ClaudeStatusBarTests/ProcessTerminatorTests.swift`

- [ ] **Step 1: 写第一个失败测试**

创建 `Tests/ClaudeStatusBarTests/ProcessTerminatorTests.swift`:

```swift
import XCTest
import Darwin
@testable import ClaudeStatusBar

final class ProcessTerminatorTests: XCTestCase {

    override func tearDown() {
        // 任何测试改了 killFn 都恢复回真实 BSD kill,避免相互污染。
        ProcessTerminator.killFn = { Darwin.kill($0, $1) }
        super.tearDown()
    }

    func testSendInterruptCallsKillWithSIGINT() {
        var captured: (pid_t, Int32)?
        ProcessTerminator.killFn = { pid, sig in
            captured = (pid, sig)
            return 0
        }

        XCTAssertTrue(ProcessTerminator.sendInterrupt(pid: 4242))
        XCTAssertEqual(captured?.0, 4242)
        XCTAssertEqual(captured?.1, SIGINT)
    }
}
```

- [ ] **Step 2: 运行测试,确认编译失败**

```bash
swift test --filter ClaudeStatusBarTests.ProcessTerminatorTests
```

预期:编译失败,`ProcessTerminator` 未定义。

- [ ] **Step 3: 写最小实现让测试通过**

创建 `Sources/ClaudeStatusBar/Services/ProcessTerminator.swift`:

```swift
import Darwin
import Foundation

/// 给指定 pid 发 SIGINT,语义等同终端按 Ctrl+C —— 中断当前正在跑的 turn,
/// 不结束 CLI 进程、会话保留。`killFn` 是注入点,默认走 BSD `kill(2)`,
/// 测试时可替换。形状参考 `ProcessLiveness`。
public enum ProcessTerminator {
    public typealias KillFunction = (pid_t, Int32) -> Int32

    public static var killFn: KillFunction = { Darwin.kill($0, $1) }

    /// pid <= 0 直接拒(防 0/-1 这种"全进程组"式的危险目标)。
    /// 返回 false 表示 kill 调用失败(进程已退、权限不足等),
    /// 调用方一般无需关心 —— SessionWatcher 下次扫描会清掉死会话。
    @discardableResult
    public static func sendInterrupt(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return killFn(pid_t(pid), SIGINT) == 0
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --filter ClaudeStatusBarTests.ProcessTerminatorTests
```

预期:1 个测试通过。

- [ ] **Step 5: 加非正 pid 测试**

在 `ProcessTerminatorTests.swift` 的类里追加:

```swift
    func testSendInterruptRejectsNonPositivePid() {
        var called = false
        ProcessTerminator.killFn = { _, _ in
            called = true
            return 0
        }

        XCTAssertFalse(ProcessTerminator.sendInterrupt(pid: 0))
        XCTAssertFalse(ProcessTerminator.sendInterrupt(pid: -1))
        XCTAssertFalse(called, "非正 pid 时不该调用 kill")
    }
```

- [ ] **Step 6: 跑测试确认通过**

```bash
swift test --filter ClaudeStatusBarTests.ProcessTerminatorTests
```

预期:2 个测试通过。`guard pid > 0` 已经覆盖。

- [ ] **Step 7: 加 kill 失败测试**

追加:

```swift
    func testSendInterruptReturnsFalseOnKillFailure() {
        ProcessTerminator.killFn = { _, _ in -1 }
        XCTAssertFalse(ProcessTerminator.sendInterrupt(pid: 1234))
    }
```

- [ ] **Step 8: 跑测试确认通过**

```bash
swift test --filter ClaudeStatusBarTests.ProcessTerminatorTests
```

预期:3 个测试通过。

- [ ] **Step 9: 完整测试套跑一遍确认没回归**

```bash
swift test
```

预期:全绿。

- [ ] **Step 10: Commit**

```bash
git add Sources/ClaudeStatusBar/Services/ProcessTerminator.swift \
        Tests/ClaudeStatusBarTests/ProcessTerminatorTests.swift
git commit -m "$(cat <<'EOF'
feat(services): ProcessTerminator 封装 kill(pid, SIGINT)

形状照抄 ProcessLiveness:纯静态、Darwin-only、killFn 可注入便于单测。
拒非正 pid,kill 失败返回 false。下一步给状态栏 hover 终止按钮调用。
EOF
)"
```

---

## Task 2: SessionRowView 骨架(idle 不建按钮)

**Files:**
- Create: `Sources/ClaudeStatusBar/UI/SessionRowView.swift`
- Create: `Tests/ClaudeStatusBarTests/SessionRowViewTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Tests/ClaudeStatusBarTests/SessionRowViewTests.swift`:

```swift
import XCTest
import AppKit
@testable import ClaudeStatusBar

final class SessionRowViewTests: XCTestCase {

    /// Session 是 Decodable-only,memberwise init 不公开。测试用 JSON 路径构造,
    /// 跟 SessionTests 一致。
    private func makeSession(pid: Int = 1234, status: SessionStatus = .busy) -> Session {
        let json = #"""
        {"pid":\#(pid),"sessionId":"sid-\#(pid)","cwd":"/tmp/proj","startedAt":1,"version":"2","kind":"interactive","entrypoint":"cli","status":"\#(status.rawValue)","updatedAt":2}
        """#.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    func testIdleSessionDoesNotCreateTerminateButton() {
        let s = makeSession(status: .idle)
        let view = SessionRowView(
            session: s,
            secondary: nil,
            onTerminate: { _ in },
            onClick: {}
        )
        XCTAssertNil(view.terminateButton)
    }
}
```

- [ ] **Step 2: 运行测试,确认编译失败**

```bash
swift test --filter ClaudeStatusBarTests.SessionRowViewTests
```

预期:编译失败,`SessionRowView` 未定义。

- [ ] **Step 3: 写最小实现**

创建 `Sources/ClaudeStatusBar/UI/SessionRowView.swift`:

```swift
import Cocoa

/// 状态栏菜单里单个 session 主行的自定义 view。每次 `rebuildMenu` 都会
/// 新构造一批,旧的随 NSMenu 释放 —— 不在 view 里维护跨 menu 的状态。
///
/// hover 行为:鼠标 enter → 终止按钮 isHidden = false;exit → 隐藏。
/// 跟 `enclosingMenuItem.isHighlighted` 解耦,因为键盘上下选时高亮跟着移
/// 但鼠标其实在别处,这种情况按钮不该出现。
///
/// 高亮态背景由本 view 自己画 —— `NSMenuItem.view` 不会自动跟随选中色。
final class SessionRowView: NSView {

    private let session: Session
    private let secondary: String?
    private let onTerminate: (Int) -> Void
    private let onClick: () -> Void

    /// 仅当 session.status ∈ {busy, waiting} 时才创建。idle 时为 nil。
    /// internal 可见性,测试通过 @testable import 直接读。
    private(set) var terminateButton: NSButton?

    private var mainLabel: NSTextField!
    private var secondaryLabel: NSTextField?

    init(
        session: Session,
        secondary: String?,
        onTerminate: @escaping (Int) -> Void,
        onClick: @escaping () -> Void
    ) {
        self.session = session
        self.secondary = secondary
        self.onTerminate = onTerminate
        self.onClick = onClick

        let height: CGFloat = secondary != nil ? 38 : 24
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: height))
        autoresizingMask = [.width]

        buildSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func buildSubviews() {
        let badge: String
        switch session.status {
        case .idle: badge = "○"
        case .busy: badge = "●"
        case .waiting: badge = "⚠"
        }
        let name = (session.cwd as NSString).lastPathComponent
        let mainText = "\(badge) \(name) · pid \(session.pid)"

        mainLabel = makeLabel(font: NSFont.menuFont(ofSize: 0))
        mainLabel.stringValue = mainText
        addSubview(mainLabel)

        if let s = secondary {
            let lbl = makeLabel(font: NSFont.systemFont(ofSize: 11))
            lbl.stringValue = s
            lbl.textColor = .secondaryLabelColor
            lbl.lineBreakMode = .byTruncatingTail
            secondaryLabel = lbl
            addSubview(lbl)
        }

        // idle 不需要终止按钮 —— Ctrl+C 在 readline 等输入时是清空 prompt,
        // 那是惊讶行为。busy/waiting 才挂按钮。
        if session.status != .idle {
            terminateButton = makeTerminateButton()
            addSubview(terminateButton!)
        }
    }

    private func makeLabel(font: NSFont) -> NSTextField {
        let lbl = NSTextField()
        lbl.font = font
        lbl.isEditable = false
        lbl.isSelectable = false
        lbl.isBordered = false
        lbl.drawsBackground = false
        lbl.backgroundColor = .clear
        lbl.textColor = .labelColor
        return lbl
    }

    private func makeTerminateButton() -> NSButton {
        let btn = NSButton()
        btn.bezelStyle = .shadowlessSquare
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyUpOrDown
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        btn.image = NSImage(
            systemSymbolName: "stop.circle.fill",
            accessibilityDescription: "中断当前任务"
        )?.withSymbolConfiguration(cfg)
        btn.contentTintColor = .secondaryLabelColor
        btn.toolTip = "中断当前任务(SIGINT)"
        btn.target = self
        btn.action = #selector(terminateClicked)
        btn.isHidden = true
        return btn
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let buttonSize: CGFloat = 18
        let buttonRightInset: CGFloat = 12
        let mainLeftInset: CGFloat = 14   // 跟 NSMenuItem 默认左缩进对齐
        let mainRightInset: CGFloat = buttonSize + buttonRightInset + 4

        if let _ = secondaryLabel {
            mainLabel.frame = NSRect(x: mainLeftInset, y: h - 20,
                                     width: w - mainLeftInset - mainRightInset, height: 16)
            secondaryLabel!.frame = NSRect(x: mainLeftInset, y: 4,
                                           width: w - mainLeftInset - 14, height: 14)
        } else {
            mainLabel.frame = NSRect(x: mainLeftInset, y: 4,
                                     width: w - mainLeftInset - mainRightInset, height: 16)
        }

        if let btn = terminateButton {
            let y = (h - buttonSize) / 2
            btn.frame = NSRect(x: w - buttonSize - buttonRightInset, y: y,
                               width: buttonSize, height: buttonSize)
        }
    }

    @objc private func terminateClicked() {
        onTerminate(session.pid)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --filter ClaudeStatusBarTests.SessionRowViewTests
```

预期:1 个测试通过。

- [ ] **Step 5: 加 busy 建按钮初始隐藏测试**

在 `SessionRowViewTests.swift` 类里追加:

```swift
    func testBusySessionCreatesHiddenTerminateButton() {
        let s = makeSession(status: .busy)
        let view = SessionRowView(
            session: s,
            secondary: "▸ Bash",
            onTerminate: { _ in },
            onClick: {}
        )
        XCTAssertNotNil(view.terminateButton)
        XCTAssertTrue(view.terminateButton!.isHidden,
                      "初始未 hover,按钮必须 isHidden")
    }

    func testWaitingSessionCreatesTerminateButton() {
        let s = makeSession(status: .waiting)
        let view = SessionRowView(
            session: s,
            secondary: "⏳ permission",
            onTerminate: { _ in },
            onClick: {}
        )
        XCTAssertNotNil(view.terminateButton)
    }
```

- [ ] **Step 6: 跑测试确认通过**

```bash
swift test --filter ClaudeStatusBarTests.SessionRowViewTests
```

预期:3 个测试通过。idle 分支已经在 buildSubviews 里跳过了按钮创建,这两个新 case 直接落到 else 分支。

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeStatusBar/UI/SessionRowView.swift \
        Tests/ClaudeStatusBarTests/SessionRowViewTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): SessionRowView 骨架,idle 不建终止按钮

自定义 NSView 替代 attributedTitle 路径,主行/副行/终止按钮在 layout()
里手动 frame 排布。idle 直接不创建按钮,busy/waiting 创建但 isHidden,
等下个 commit 加 hover 跟踪后再显隐。
EOF
)"
```

---

## Task 3: SessionRowView hover 显隐 + 主行点击 + 高亮态绘制

**Files:**
- Modify: `Sources/ClaudeStatusBar/UI/SessionRowView.swift`
- Modify: `Tests/ClaudeStatusBarTests/SessionRowViewTests.swift`

- [ ] **Step 1: 写 hover 测试**

在 `SessionRowViewTests.swift` 类里追加:

```swift
    func testHoverShowsAndHidesTerminateButton() {
        let s = makeSession(status: .busy)
        let view = SessionRowView(
            session: s,
            secondary: nil,
            onTerminate: { _ in },
            onClick: {}
        )
        XCTAssertTrue(view.terminateButton!.isHidden, "初始隐藏")

        view.handleHoverChanged(isHovering: true)
        XCTAssertFalse(view.terminateButton!.isHidden, "hover 进入后显示")

        view.handleHoverChanged(isHovering: false)
        XCTAssertTrue(view.terminateButton!.isHidden, "hover 离开后再隐藏")
    }
```

- [ ] **Step 2: 跑测试确认编译失败**

```bash
swift test --filter ClaudeStatusBarTests.SessionRowViewTests
```

预期:编译失败,`handleHoverChanged` 未定义。

- [ ] **Step 3: 加 hover 跟踪与高亮态绘制实现**

修改 `Sources/ClaudeStatusBar/UI/SessionRowView.swift`,在类内部追加:

```swift
    // MARK: - hover 跟踪

    /// 抽出来给单测调用 —— 真 NSEvent 构造比较繁琐,而 NSResponder 的
    /// mouseEntered/mouseExited 本身就只是把事件转给这里。
    func handleHoverChanged(isHovering: Bool) {
        terminateButton?.isHidden = !isHovering
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        handleHoverChanged(isHovering: true)
    }

    override func mouseExited(with event: NSEvent) {
        handleHoverChanged(isHovering: false)
    }

    // MARK: - 主行点击

    /// NSMenu tracking 模式下 NSMenuItem.view 不会自动触发 NSMenuItem.action,
    /// 必须自己处理 mouseUp。按钮区域内的点击让 NSButton 自己消化。
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let btn = terminateButton, !btn.isHidden, btn.frame.contains(p) {
            return
        }
        onClick()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    // MARK: - 高亮态背景

    override func draw(_ dirtyRect: NSRect) {
        if enclosingMenuItem?.isHighlighted == true {
            NSColor.selectedMenuItemColor.setFill()
            bounds.fill()
            mainLabel.textColor = .selectedMenuItemTextColor
            secondaryLabel?.textColor = .selectedMenuItemTextColor
        } else {
            mainLabel.textColor = .labelColor
            secondaryLabel?.textColor = .secondaryLabelColor
        }
        super.draw(dirtyRect)
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --filter ClaudeStatusBarTests.SessionRowViewTests
```

预期:4 个测试全部通过。

- [ ] **Step 5: 加终止按钮回调测试**

追加:

```swift
    func testTerminateClickInvokesCallbackWithPid() {
        var receivedPid: Int?
        let s = makeSession(pid: 9001, status: .waiting)
        let view = SessionRowView(
            session: s,
            secondary: nil,
            onTerminate: { receivedPid = $0 },
            onClick: {}
        )
        view.terminateButton!.performClick(nil)
        XCTAssertEqual(receivedPid, 9001)
    }
```

- [ ] **Step 6: 跑测试确认通过**

```bash
swift test --filter ClaudeStatusBarTests.SessionRowViewTests
```

预期:5 个测试通过。`terminateButton.performClick(nil)` 触发 target/action,即 `terminateClicked()` → `onTerminate(session.pid)`。

- [ ] **Step 7: 完整测试套跑一遍**

```bash
swift test
```

预期:全绿,无回归。

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeStatusBar/UI/SessionRowView.swift \
        Tests/ClaudeStatusBarTests/SessionRowViewTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): SessionRowView hover 显隐按钮、点击回调、高亮态背景

- NSTrackingArea inVisibleRect + activeAlways
- mouseUp 手动判定按钮区域,菜单 tracking 模式下让按钮自己消化点击
- 自绘 selectedMenuItemColor + selectedMenuItemTextColor 反色
EOF
)"
```

---

## Task 4: AppDelegate 集成

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppDelegate.swift`

- [ ] **Step 1: 改 makeSessionItem 用新 view**

打开 `Sources/ClaudeStatusBar/AppDelegate.swift`,定位 `makeSessionItem(_:)`(约 353-391 行),整段替换为:

```swift
    private func makeSessionItem(_ s: Session) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = s
        item.toolTip = "\(s.cwd)\n按住 Option 点击在 Finder 中打开"

        let view = SessionRowView(
            session: s,
            secondary: secondaryLine(for: s),
            onTerminate: { [weak self] pid in
                ProcessTerminator.sendInterrupt(pid: pid)
                self?.statusItem?.menu?.cancelTracking()
            },
            onClick: { [weak self] in
                self?.revealSession(forPid: s.pid)
            }
        )
        item.view = view
        return item
    }
```

- [ ] **Step 2: 加新 revealSession(forPid:) 入口**

在 `AppDelegate` 类内部找到旧的 `@objc private func revealSession(_ sender: NSMenuItem)`(约 427-439 行),整段替换为:

```swift
    /// SessionRowView 主行点击入口。沿用旧 revealSession 的全部语义:
    /// Option 检测仍走 NSApp.currentEvent,与 sender 类型无关。
    private func revealSession(forPid pid: Int) {
        guard let session = store.sessions.first(where: { $0.pid == pid }) else { return }
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
```

注意:旧版的 `@objc` 标记和 `_ sender: NSMenuItem` 参数都删掉 —— 现在已经没有 `NSMenuItem.action = #selector(revealSession(_:))` 用法,这个入口只从闭包调用。

- [ ] **Step 3: 编译**

```bash
swift build
```

预期:编译通过。

如果报 `representedObject` 没人读了的 warning,可以保留(下面 manual verify 提到 toolTip 也用)。

- [ ] **Step 4: 跑全部测试**

```bash
swift test
```

预期:全绿。AppDelegate 没有现成的 unit test,这一改动靠手动验收。

- [ ] **Step 5: 手动验收 #1 — 启动 app**

```bash
swift run
```

让 app 跑起来。打开一个 iTerm/Terminal/VSCode 终端,在某目录跑 `claude`,等它出现在状态栏菜单里。

- [ ] **Step 6: 手动验收 #2 — idle 不出按钮**

会话刚启动还没下任何 prompt 时是 idle。点状态栏图标,鼠标悬到该 session 行上 —— 右侧**不**应该出现停止按钮。

- [ ] **Step 7: 手动验收 #3 — busy/waiting 出按钮**

在 claude 里发一个能跑几秒的 prompt(比如 "列出当前目录内容并描述")。会话状态翻 busy。再次打开菜单,hover 那一行 —— 右侧出现实心圆停止按钮(`stop.circle.fill`)。鼠标移开,按钮消失。

- [ ] **Step 8: 手动验收 #4 — 点击中断**

再次 hover busy 行,点击停止按钮:
- 状态栏菜单立刻关闭(`cancelTracking`)
- 几秒内 claude 那边 task 被打断(类似你按 Ctrl+C 看到的样子)
- 会话**没有**退出 —— prompt 提示符还在,可以继续聊
- 状态栏菜单图标在几秒后跟随 SessionStore 刷新,该会话翻回 idle

- [ ] **Step 9: 手动验收 #5 — 主行点击仍跳终端**

随便选一个 idle / busy 行,**非按钮区域**单击 —— 切到对应终端窗口(原 `revealSession` 行为)。

- [ ] **Step 10: 手动验收 #6 — Option-click 仍跳 Finder**

按住 Option,主行点击 —— Finder 打开 cwd(原 Option-click 行为)。

- [ ] **Step 11: 手动验收 #7 — 键盘选中不触发 hover**

打开菜单,用键盘上下方向键移动选中 busy 行 —— 即使行被高亮(蓝色背景),按钮**也不**出现。鼠标 hover 才出。

如果上述 7 项都过,继续下一步。任何一项不过,停下排错(常见问题:NSButton 在 menu tracking 下点击不响应 → 检查 bezelStyle / isBordered;高亮态文字看不清 → 检查 draw() 的 textColor 切换)。

- [ ] **Step 12: Commit**

```bash
git add Sources/ClaudeStatusBar/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(menu): session 行接入 SessionRowView,hover 出停止按钮

- makeSessionItem 改走 NSMenuItem.view = SessionRowView
- 终止闭包:ProcessTerminator.sendInterrupt + 立即 cancelTracking
- revealSession 收口为 forPid: 入口,主行点击和闭包共用
- 删除旧 @objc revealSession(_ sender:),已无引用
EOF
)"
```

---

## Task 5: 收尾 — 完整跑一遍 + push

- [ ] **Step 1: 全量构建测试**

```bash
swift build && swift test
```

预期:build 通过,所有测试绿。

- [ ] **Step 2: 看下最终 diff**

```bash
git log --oneline -5
git diff --stat HEAD~4..HEAD
```

预期:看到 4 个 feat commit + spec commit,改动局限在:
- 新增 1 个 service 文件 + 1 个 view 文件
- 新增 2 个测试文件
- AppDelegate 修改 ~30 行(makeSessionItem 重写 + revealSession 入口换形)

- [ ] **Step 3: 不要 push,等用户确认**

完成。把最近 commit 列出来给用户,等用户决定是否 push / 是否要更新 changelog。

---

## 不做的事(YAGNI)

- **SIGINT → SIGTERM 升级**:不加超时升级逻辑,信任 CLI。
- **二次确认对话框**:与 Ctrl+C 同重,会话不丢。
- **idle 状态显灰按钮**:压根不创建,见 spec 决策。
- **`SessionRowView` 的 Auto Layout**:用手动 frame + autoresizingMask = .width,够用且不引入 layout 触发时机问题。
- **修改 `makeSessionDetailItem`**(模型+上下文%那行):不动。
- **CHANGELOG / CLAUDE.md**:本期无新架构约定,不更新。如果用户想发版再单独提。

## 失败排查 cheat sheet

| 症状 | 可能原因 | 排查 |
|------|----------|------|
| 编译报 `'kill'` 二义 | `Darwin.kill` vs `Foundation.kill` | 在 `ProcessTerminator` 文件顶部 `import Darwin`,实现里写全 `Darwin.kill($0, $1)` |
| 按钮在 menu tracking 下点不到 | `bezelStyle` 太花 / `isBordered` 没关 | 切到 `.shadowlessSquare`,继续 `isBordered = false`;实在不行就在 `mouseUp` 里手动判定按钮 frame 内点击,不依赖 NSButton 自己派发 |
| 高亮态文字看不见 | `draw()` 没切 textColor | 确认 selected 分支里 `mainLabel.textColor = .selectedMenuItemTextColor` |
| hover 按钮不出来 | `updateTrackingAreas` 没调用 | view 加到 NSMenuItem.view 后,window 出现时 AppKit 会调一次。可以临时加 print 验证;实在不行在 `viewDidMoveToWindow` 里手动 `updateTrackingAreas()` |
| idle 翻 busy 后菜单还显示按钮但不响应 | menu 是 cached 的 view | rebuildMenu 每次新建 view,正常应该不会撞到。如果撞到说明 menu 不是每次重建 — 看 `Publishers.CombineLatest3` sink 是不是少触发 |

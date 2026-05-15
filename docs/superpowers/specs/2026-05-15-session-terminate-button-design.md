# 状态栏菜单 · session 行 hover 终止按钮

## 背景与目标

当前状态栏菜单里每个 Claude Code 会话渲染为两个 `NSMenuItem`：

- 主行：`badge + 目录名 + pid`，配 secondary line（waiting / tool / prompt 摘要），点击跳到对应终端
- 副行：`模型 · 上下文百分比`，纯展示

用户想在主行上加一个 **hover 时才出现的圆形终止按钮**，单击即向该会话发 `SIGINT`，等同于在终端里按 Ctrl+C —— 中断当前正在跑的 turn，**不结束整个 CLI 进程，会话继续保留**。

适用范围:

- 仅 `busy` / `waiting` 状态显示按钮(idle 时按钮根本不创建)
- 不弹二次确认,点了立即发信号
- 发信号后立刻关闭状态栏菜单(`cancelTracking()`),用户不必呆等 `busy → idle` 的状态切换

## 非目标

- 不做 SIGINT → SIGTERM 的超时升级。Claude CLI 接住 SIGINT 后的行为我们信任,失败也是 CLI 的事。
- 不做"终止整个 CLI 进程"开关。本期就一种语义。
- 不动 secondary line / 副行渲染逻辑,只改主行的容器形态。
- 不动 `revealSession`(单击主行跳终端、Option+单击跳 Finder)的语义。

## 架构改动

### 文件清单

| 类型 | 路径 | 用途 |
|------|------|------|
| 新增 | `Sources/ClaudeStatusBar/Services/ProcessTerminator.swift` | 静态封装 `kill(pid, SIGINT)`,`killFn` 可注入便于单测 |
| 新增 | `Sources/ClaudeStatusBar/UI/SessionRowView.swift` | 自定义 `NSView`,承担主行渲染 + hover 按钮 + 高亮态绘制 |
| 改 | `Sources/ClaudeStatusBar/AppDelegate.swift` | `makeSessionItem` 改为 `NSMenuItem.view = SessionRowView`;新增 `revealSession(forPid:)` 入口供 view 回调 |
| 新增 | `Tests/ClaudeStatusBarTests/ProcessTerminatorTests.swift` | 验证注入的 `KillFunction` 收到正确 pid 与 `SIGINT` |
| 新增 | `Tests/ClaudeStatusBarTests/SessionRowViewTests.swift` | 验证 idle 不创建按钮、busy hover 显隐、点击触发回调 |

### 数据流

```
Session(state, pid)
  │
  ▼
AppDelegate.makeSessionItem
  │  builds:
  │    secondary = secondaryLine(for: s)        // 既有逻辑
  │    onTerminate = { pid in
  │       ProcessTerminator.sendInterrupt(pid: pid)
  │       statusItem?.menu?.cancelTracking()
  │    }
  │    onClick = { revealSession(forPid: s.pid) }
  ▼
NSMenuItem(view: SessionRowView)
  │
  ▼ user hover
SessionRowView.mouseEntered → terminateButton.isHidden = false
  │
  ▼ user click
SessionRowView → onTerminate(pid) → kill(pid, SIGINT) → menu cancelTracking
                                          │
                                          ▼ ~1s 后
                            CLI 把 status 写回 idle
                                          │
                                          ▼
                            SessionWatcher → SessionStore → menu 重建
```

## 组件设计

### `ProcessTerminator`

参照 `Services/ProcessLiveness.swift` 的形状(纯静态、只 import Darwin、`KillFunction` 可替换便于测)。

```swift
import Darwin
import Foundation

public enum ProcessTerminator {
    public typealias KillFunction = (pid_t, Int32) -> Int32

    /// 默认走 BSD `kill(2)`。测试可替换。
    public static var killFn: KillFunction = { Darwin.kill($0, $1) }

    /// 给 pid 发 SIGINT(等同 Ctrl+C)。pid <= 0 直接拒;
    /// 返回 false 表示 kill 调用失败(进程已退、权限不足等),
    /// 调用方一般无需关心 —— SessionWatcher 下次扫描会清掉死会话。
    @discardableResult
    public static func sendInterrupt(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return killFn(pid_t(pid), SIGINT) == 0
    }
}
```

### `SessionRowView`

**定位**: 一个 `NSView` 子类,作为单个 `NSMenuItem.view` 使用。view 实例与 `Session` 是一对一的快照关系 —— 每次 `rebuildMenu` 都会新构造一批 view,旧的随 menu 一起被释放,**不在 view 内部维护任何长期状态**(hover 状态除外,它的生命周期就只在本次 menu tracking 内)。

**构造器**:

```swift
init(
    session: Session,                         // pid / status / cwd / 用于显示
    secondary: String?,                       // AppDelegate 已经算好的副行
    onTerminate: @escaping (Int) -> Void,     // 发信号 + 关菜单的副作用
    onClick: @escaping () -> Void             // 主行点击 → revealSession
)
```

**子视图**:

- `mainLabel` — `NSTextField`(non-editable, bezel-less, drawsBackground=false),内容就是现有 `mainTitle = "{badge} {name} · pid {pid}"`,字体 `NSFont.menuFont(ofSize: 0)`
- `secondaryLabel` — 同款 NSTextField,内容是 `secondary`,字体 11pt,`secondaryLabelColor`,`lineBreakMode = .byTruncatingTail`。`secondary == nil` 时不创建
- `terminateButton` — `NSButton`,`bezelStyle = .accessoryBarAction` 或 `.shadowlessSquare` borderless,`image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "中断当前任务")`,`imageScaling = .scaleProportionallyUpOrDown`,尺寸 14x14,`isHidden = true` 初始,`target/action` 调内部 `@objc terminateClicked`。**仅当 `session.status == .busy || .waiting` 时才创建** —— idle 时该字段为 `nil`,hover 也不会显现。

**布局**:

view 高度跟随当前菜单字体动态算(参照现有两行 attributedString 的高度,实测约 32pt;实现里用 fittingSize 或固定值都可,先用 32pt + secondary 时 36pt,后续若发现挤压再调)。

```
┌─────────────────────────────────────────────────────┐
│ {badge} {name} · pid {pid}                  [stop]  │   ← terminateButton 右对齐
│ {secondary}                                         │
└─────────────────────────────────────────────────────┘
```

按钮约束: 右边缘距 view 右侧 8pt,垂直居中于 mainLabel 行。

**高亮态**:

`NSMenuItem.view` 不会自动跟随高亮绘制选中色。重写 `draw(_:)`:

```swift
override func draw(_ dirtyRect: NSRect) {
    if enclosingMenuItem?.isHighlighted == true {
        NSColor.selectedMenuItemColor.setFill()
        bounds.fill()
        // 高亮态文字反色
        mainLabel.textColor = .selectedMenuItemTextColor
        secondaryLabel?.textColor = .selectedMenuItemTextColor
    } else {
        mainLabel.textColor = .labelColor
        secondaryLabel?.textColor = .secondaryLabelColor
    }
    super.draw(dirtyRect)
}
```

**hover 跟踪**:

```swift
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
    terminateButton?.isHidden = false
}
override func mouseExited(with event: NSEvent) {
    terminateButton?.isHidden = true
}
```

> **关键点**: hover 行为通过 `NSTrackingArea` 实现,而不是绑定 `isHighlighted`。两者解耦的原因 —— 用户用键盘上下选时 highlighted 会跟着变,但鼠标实际在别处,这种情况按钮不该出现。

**点击主行**(非按钮):

```swift
override func mouseUp(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if let btn = terminateButton, btn.frame.contains(p) {
        return  // 让按钮自己处理
    }
    onClick()
    enclosingMenuItem?.menu?.cancelTracking()
}
```

> NSMenu tracking 模式下 `NSMenuItem.view` 的命中测试需要自己处理,默认不会触发 `NSMenuItem.action`。

**点击按钮**:

```swift
@objc private func terminateClicked() {
    onTerminate(session.pid)
    // onTerminate 内部已经会 cancelTracking,这里不重复
}
```

### `AppDelegate.makeSessionItem` 改写

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

/// 拆出来的入口,沿用既有 revealSession 的全部语义(Option-click 跳 Finder
/// 也是查 NSApp.currentEvent 的 modifierFlags,与 sender 类型无关)。
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

`@objc revealSession(_:)`(老的 NSMenuItem action 形式)继续保留,以防菜单里其它地方还用到;实际上目前只有主行用到,可以删 —— 留 `revealSession(forPid:)` 一个入口。

`makeSessionDetailItem`(模型 + 上下文百分比那行)**完全不动**。

## 测试计划

### `ProcessTerminatorTests`

```swift
func testSendInterruptCallsKillWithSIGINT() {
    var captured: (pid_t, Int32)?
    let original = ProcessTerminator.killFn
    ProcessTerminator.killFn = { pid, sig in captured = (pid, sig); return 0 }
    defer { ProcessTerminator.killFn = original }

    XCTAssertTrue(ProcessTerminator.sendInterrupt(pid: 4242))
    XCTAssertEqual(captured?.0, 4242)
    XCTAssertEqual(captured?.1, SIGINT)
}

func testSendInterruptRejectsNonPositivePid() {
    var called = false
    let original = ProcessTerminator.killFn
    ProcessTerminator.killFn = { _, _ in called = true; return 0 }
    defer { ProcessTerminator.killFn = original }

    XCTAssertFalse(ProcessTerminator.sendInterrupt(pid: 0))
    XCTAssertFalse(ProcessTerminator.sendInterrupt(pid: -1))
    XCTAssertFalse(called)
}

func testSendInterruptReturnsFalseOnKillFailure() {
    let original = ProcessTerminator.killFn
    ProcessTerminator.killFn = { _, _ in -1 }
    defer { ProcessTerminator.killFn = original }

    XCTAssertFalse(ProcessTerminator.sendInterrupt(pid: 1234))
}
```

### `SessionRowViewTests`

```swift
func testIdleSessionDoesNotCreateTerminateButton() {
    let s = makeSession(status: .idle)
    let view = SessionRowView(session: s, secondary: nil, onTerminate: { _ in }, onClick: {})
    XCTAssertNil(view.terminateButtonForTesting)
}

func testBusySessionCreatesHiddenTerminateButton() {
    let s = makeSession(status: .busy)
    let view = SessionRowView(session: s, secondary: "▸ Bash", onTerminate: { _ in }, onClick: {})
    XCTAssertNotNil(view.terminateButtonForTesting)
    XCTAssertTrue(view.terminateButtonForTesting!.isHidden)
}

func testMouseEnteredRevealsButton() {
    let s = makeSession(status: .busy)
    let view = SessionRowView(session: s, secondary: nil, onTerminate: { _ in }, onClick: {})
    view.mouseEnteredForTesting()
    XCTAssertFalse(view.terminateButtonForTesting!.isHidden)
    view.mouseExitedForTesting()
    XCTAssertTrue(view.terminateButtonForTesting!.isHidden)
}

func testTerminateClickInvokesCallbackWithPid() {
    var receivedPid: Int?
    let s = makeSession(pid: 9001, status: .waiting)
    let view = SessionRowView(
        session: s, secondary: nil,
        onTerminate: { receivedPid = $0 }, onClick: {}
    )
    view.simulateTerminateClickForTesting()
    XCTAssertEqual(receivedPid, 9001)
}
```

> view 暴露几个 `*ForTesting` 入口,只在 test target 调用;不污染对外 API。或者把这些 internal 化让 `@testable import` 直接拿。

### 不测的部分

- **真发 SIGINT**: 不在单测里 fork 真进程发信号(慢、flaky、跨平台风险)。`ProcessTerminatorTests` 只验证调用契约。
- **NSMenu 集成**: NSMenuItem.view 在 menu tracking 期间的 hit testing 行为是 AppKit 黑盒,不写自动化测试 —— 手动验收(见下)。

### 手动验收

`swift run` 启动后:

1. 没有 busy/waiting 会话时,菜单里 idle 行 hover **不**出现按钮 ✅
2. 启动一个长 Bash 任务让会话进入 busy,hover 该行右侧出现实心圆停止按钮 ✅
3. 单击按钮:菜单立即关闭,几秒内 Claude CLI 那边确认 task 被中断,会话状态翻回 idle ✅
4. busy 行非按钮区域单击:跳转到对应终端窗口(原行为不变)✅
5. busy 行 Option+单击非按钮区域:跳 Finder(原行为不变)✅
6. 键盘上下选中 busy 行,按钮**不**自动出现(只跟鼠标 hover)✅

## 风险与决策

- **NSMenuItem.view 的 hit testing**: AppKit 在 menu tracking 模式下,`NSMenuItem.view` 内的 `NSButton` 默认会响应点击。如果实测发现按钮点不到,fallback 是在 `mouseUp` 里手动判定按钮区域(代码里已经写了)。
- **secondary line 数据来源**: 现 `secondaryLine(for:)` 依赖 `contextStore.contextByPid`。把它留在 AppDelegate 里、把字符串结果传进 view —— 避免 view 反向依赖 `SessionContextStore`,view 保持纯粹。
- **idle 时 hover 不出按钮 vs 出但灰着**: 选了"不出"。理由:idle 时按钮无意义,出现反而造成"为什么按了没反应"的困惑;且 SIGINT 在 idle 状态(CLI 在 readline 等输入)的实际效果是把当前 prompt 清空,这是"惊讶行为"。
- **不加二次确认**: 与 Ctrl+C 同重,会话不丢,误点成本低。
- **关菜单时机**: 在 `onTerminate` 闭包里关。不在 view 内部关,避免 view 知道太多。

## 完成定义(DoD)

- `swift build` 通过
- `swift test` 全绿(含 2 个新测试 suite)
- 手动验收 6 项全过
- CLAUDE.md 不需要更新(这次改动没引入新的架构约定 —— SessionRowView 是 UI/ 子目录里很自然的一员,ProcessTerminator 完全照 ProcessLiveness 的模板)

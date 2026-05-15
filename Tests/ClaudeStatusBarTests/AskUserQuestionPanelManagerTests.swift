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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.entryCountForTesting, 0)
    }

    func testIncomingAskUserQuestionPresentsPanel() {
        let store = PermissionPromptStore()
        let manager = AskUserQuestionPanelManager(store: store, navigator: NoopNavigator())
        store.add(
            PermissionPromptRequest(id: "1", toolName: "AskUserQuestion", input: [:]),
            reply: { _ in }
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.entryCountForTesting, 1)
    }

    func testResolvedDismissesPanel() {
        let store = PermissionPromptStore()
        let manager = AskUserQuestionPanelManager(store: store, navigator: NoopNavigator())
        store.add(
            PermissionPromptRequest(id: "x", toolName: "AskUserQuestion", input: [:]),
            reply: { _ in }
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.entryCountForTesting, 1)
        store.abandon(id: "x")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
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

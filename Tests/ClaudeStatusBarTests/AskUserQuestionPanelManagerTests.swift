import XCTest
import Combine
@testable import ClaudeStatusBar

final class AskUserQuestionPanelManagerTests: XCTestCase {

    private func makeManager(
        store: PermissionPromptStore,
        navigator: TerminalActivating = NoopNavigator()
    ) -> AskUserQuestionPanelManager {
        AskUserQuestionPanelManager(
            store: store,
            stack: FloatingPanelStack(),
            navigator: navigator
        )
    }

    func testIncomingPermissionKindIgnored() {
        // 即使 toolName 是 "AskUserQuestion",只要 kind 是 .permission(理论上
        // helper 端 D2 已经把 PermissionRequest+AskUserQuestion 短路掉,这里是
        // 双保险防御)。
        let store = PermissionPromptStore()
        let manager = makeManager(store: store)
        store.add(
            PermissionPromptRequest(
                id: "1", toolName: "AskUserQuestion", input: [:],
                kind: .permission
            ),
            reply: { _ in }
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.entryCountForTesting, 0)
    }

    func testIncomingAskUserQuestionPresentsPanel() {
        let store = PermissionPromptStore()
        let manager = makeManager(store: store)
        store.add(
            PermissionPromptRequest(
                id: "1", toolName: "AskUserQuestion", input: [:],
                kind: .askUserQuestion
            ),
            reply: { _ in }
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(manager.entryCountForTesting, 1)
    }

    func testResolvedDismissesPanel() {
        let store = PermissionPromptStore()
        let manager = makeManager(store: store)
        store.add(
            PermissionPromptRequest(
                id: "x", toolName: "AskUserQuestion", input: [:],
                kind: .askUserQuestion
            ),
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
        let manager = makeManager(store: store, navigator: nav)
        var captured: PermissionPromptDecision??
        store.add(
            PermissionPromptRequest(
                id: "y", toolName: "AskUserQuestion",
                input: [:], cwd: "/proj", sessionId: "s",
                kind: .askUserQuestion
            ),
            reply: { captured = $0 }
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        manager.handleResponseForTesting(id: "y", outcome: .goToTerminal)
        XCTAssertEqual(captured, .some(nil))  // abandon 传 nil
        XCTAssertEqual(nav.lastCwd, "/proj")
    }

    func testSubmitOutcomeResolvesWithAnswers() throws {
        let store = PermissionPromptStore()
        let manager = makeManager(store: store)
        var capturedDecision: PermissionPromptDecision?
        var replyCount = 0
        let questionsValue: JSONValue = .array([
            .object([
                "question": .string("颜色?"),
                "multiSelect": .bool(false),
                "options": .array([
                    .object(["label": .string("红")]),
                    .object(["label": .string("蓝")]),
                ]),
            ])
        ])
        store.add(
            PermissionPromptRequest(
                id: "z", toolName: "AskUserQuestion",
                input: ["questions": questionsValue],
                kind: .askUserQuestion
            ),
            reply: { decision in
                capturedDecision = decision
                replyCount += 1
            }
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        manager.handleResponseForTesting(id: "z", outcome: .submit(answers: ["颜色?": "红"]))

        XCTAssertEqual(replyCount, 1)
        let decision = try XCTUnwrap(capturedDecision)
        XCTAssertEqual(decision.behavior, .allow)
        let updated = try XCTUnwrap(decision.updatedInput)
        XCTAssertEqual(updated["questions"], questionsValue,
                       "原始 questions 必须原样回传(AskUserQuestionOutput schema)")
        XCTAssertEqual(updated["answers"], .object(["颜色?": .string("红")]))
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

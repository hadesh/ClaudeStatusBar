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

    func testParsesHeaderAndMultiSelect() {
        let req = PermissionPromptRequest(
            id: "1", toolName: "AskUserQuestion",
            input: [
                "questions": .array([
                    .object([
                        "question": .string("Pick"),
                        "header": .string("Lib"),
                        "multiSelect": .bool(true),
                        "options": .array([
                            .object(["label": .string("A")]),
                            .object(["label": .string("B")]),
                        ]),
                    ])
                ])
            ]
        )
        let parsed = AskUserQuestionInput.parse(req)
        XCTAssertEqual(parsed?.questions[0].header, "Lib")
        XCTAssertEqual(parsed?.questions[0].multiSelect, true)
    }
}

/// Panel 提交路径行为测试 — 涉及 AppKit NSPanel,但不需要 NSApp.run 启动。
final class AskUserQuestionPanelSubmitTests: XCTestCase {

    private func singleSelectRequest() -> PermissionPromptRequest {
        PermissionPromptRequest(
            id: "id", toolName: "AskUserQuestion",
            input: [
                "questions": .array([
                    .object([
                        "question": .string("颜色?"),
                        "multiSelect": .bool(false),
                        "options": .array([
                            .object(["label": .string("红")]),
                            .object(["label": .string("蓝")]),
                        ]),
                    ])
                ])
            ],
            kind: .askUserQuestion
        )
    }

    private func multiSelectRequest() -> PermissionPromptRequest {
        PermissionPromptRequest(
            id: "id", toolName: "AskUserQuestion",
            input: [
                "questions": .array([
                    .object([
                        "question": .string("Tags?"),
                        "multiSelect": .bool(true),
                        "options": .array([
                            .object(["label": .string("A")]),
                            .object(["label": .string("B")]),
                            .object(["label": .string("C")]),
                        ]),
                    ])
                ])
            ],
            kind: .askUserQuestion
        )
    }

    func testSingleSelectSubmitsLabel() {
        var captured: AskUserQuestionPanel.Outcome?
        let panel = AskUserQuestionPanel(request: singleSelectRequest()) { captured = $0 }
        XCTAssertFalse(panel.isSubmitEnabledForTesting, "未选时提交应禁用")
        panel.selectOptionForTesting(questionIndex: 0, label: "红")
        XCTAssertTrue(panel.isSubmitEnabledForTesting)
        panel.clickSubmitForTesting()
        guard case .submit(let answers) = captured else {
            return XCTFail("expected .submit, got \(String(describing: captured))")
        }
        XCTAssertEqual(answers["颜色?"], "红")
    }

    func testMultiSelectJoinsLabelsWithCommaSpace() {
        // Schema: multi-select 答案是 ", " 串联(changelog 第 243 行 fix)
        var captured: AskUserQuestionPanel.Outcome?
        let panel = AskUserQuestionPanel(request: multiSelectRequest()) { captured = $0 }
        panel.selectOptionForTesting(questionIndex: 0, label: "A")
        panel.selectOptionForTesting(questionIndex: 0, label: "C")
        panel.clickSubmitForTesting()
        guard case .submit(let answers) = captured else {
            return XCTFail("expected .submit")
        }
        XCTAssertEqual(answers["Tags?"], "A, C")
    }

    func testOtherFieldFreeTextSubmits() {
        var captured: AskUserQuestionPanel.Outcome?
        let panel = AskUserQuestionPanel(request: singleSelectRequest()) { captured = $0 }
        panel.selectOptionForTesting(questionIndex: 0, label: "__OTHER__")
        panel.setOtherTextForTesting(questionIndex: 0, text: "黄色")
        XCTAssertTrue(panel.isSubmitEnabledForTesting)
        panel.clickSubmitForTesting()
        guard case .submit(let answers) = captured else {
            return XCTFail("expected .submit")
        }
        XCTAssertEqual(answers["颜色?"], "黄色")
    }

    func testOtherSelectedButEmptyDisablesSubmit() {
        let panel = AskUserQuestionPanel(request: singleSelectRequest()) { _ in }
        panel.selectOptionForTesting(questionIndex: 0, label: "__OTHER__")
        // 没填文本
        XCTAssertFalse(panel.isSubmitEnabledForTesting,
                       "Other 选中但 text 空时不应允许提交")
    }

    func testWindowCloseAbandons() {
        // ✕ 仍是 abandon 语义不变,跳回终端的逃生口。
        var captured: AskUserQuestionPanel.Outcome?
        let panel = AskUserQuestionPanel(request: singleSelectRequest()) { captured = $0 }
        _ = panel.windowShouldClose(panel)
        XCTAssertEqual(captured, .abandon)
    }
}

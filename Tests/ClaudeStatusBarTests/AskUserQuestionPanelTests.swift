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

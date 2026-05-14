import XCTest
@testable import ClaudeStatusBar

final class PermissionPromptPreviewTests: XCTestCase {

    func testCompactSummaryShowsToolNameAndCommand() {
        let r = PermissionPromptRequest(
            id: "x", toolName: "Bash",
            input: ["command": .string("rm -rf foo")]
        )
        XCTAssertEqual(PermissionPromptPreview.compactSummary(for: r), "Bash: rm -rf foo")
    }

    func testCompactSummaryShowsFilePathForEdit() {
        let r = PermissionPromptRequest(
            id: "x", toolName: "Edit",
            input: ["file_path": .string("/tmp/x.txt")]
        )
        XCTAssertEqual(PermissionPromptPreview.compactSummary(for: r), "Edit: /tmp/x.txt")
    }

    func testCompactSummaryShowsUrlForWebFetch() {
        let r = PermissionPromptRequest(
            id: "x", toolName: "WebFetch",
            input: ["url": .string("https://example.com")]
        )
        XCTAssertEqual(
            PermissionPromptPreview.compactSummary(for: r),
            "WebFetch: https://example.com"
        )
    }

    func testCompactSummaryTrimsLong() {
        let long = String(repeating: "a", count: 200)
        let r = PermissionPromptRequest(
            id: "x", toolName: "Bash",
            input: ["command": .string(long)]
        )
        let body = PermissionPromptPreview.compactSummary(for: r)
        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertLessThan(body.count, 100)
    }

    func testCompactSummaryFallsBackToToolNameWhenNoKnownField() {
        let r = PermissionPromptRequest(
            id: "x", toolName: "CustomTool", input: [:]
        )
        XCTAssertEqual(PermissionPromptPreview.compactSummary(for: r), "CustomTool")
    }

    func testCompactSummaryIgnoresNonStringFields() {
        let r = PermissionPromptRequest(
            id: "x", toolName: "Bash",
            input: ["command": .number(42)]
        )
        XCTAssertEqual(PermissionPromptPreview.compactSummary(for: r), "Bash")
    }

    func testBodyPreviewFullCommand() {
        // bodyPreview uses the larger 200-char default, used by the panel UI
        // for a multi-line label rather than a single banner row.
        let r = PermissionPromptRequest(
            id: "x", toolName: "Bash",
            input: ["command": .string("git log --oneline --decorate -n 5")]
        )
        XCTAssertEqual(
            PermissionPromptPreview.bodyPreview(for: r),
            "git log --oneline --decorate -n 5"
        )
    }

    func testBodyPreviewEmptyForUnknownInput() {
        let r = PermissionPromptRequest(id: "x", toolName: "X", input: [:])
        XCTAssertEqual(PermissionPromptPreview.bodyPreview(for: r), "")
    }

    func testSessionNameUsesCwdBasename() {
        let r = PermissionPromptRequest(
            id: "x", toolName: "Bash", input: [:],
            cwd: "/Users/me/Code/my-project", sessionId: "abc-123-def"
        )
        XCTAssertEqual(PermissionPromptPreview.sessionName(for: r), "my-project")
    }

    func testSessionNameFallsBackToShortSessionId() {
        let r = PermissionPromptRequest(
            id: "x", toolName: "Bash", input: [:],
            cwd: nil, sessionId: "abcdefgh1234"
        )
        XCTAssertEqual(PermissionPromptPreview.sessionName(for: r), "session abcdefgh")
    }

    func testSessionNameNilWhenBothMissing() {
        let r = PermissionPromptRequest(id: "x", toolName: "Bash", input: [:])
        XCTAssertNil(PermissionPromptPreview.sessionName(for: r))
    }
}

import XCTest
import Cocoa
@testable import ClaudeStatusBar

/// Sanity tests for `PermissionPromptPanel` — primarily a regression net
/// for AppKit invariants enforced at runtime (e.g. mutually-exclusive
/// collection-behavior flags) that the type system cannot catch.
final class PermissionPromptPanelTests: XCTestCase {

    func testInitDoesNotThrow() {
        let request = PermissionPromptRequest(
            id: "test-id", toolName: "Bash",
            input: ["command": .string("echo hi")]
        )
        let panel = PermissionPromptPanel(request: request) { _ in }
        XCTAssertEqual(panel.promptId, "test-id")
        XCTAssertNotNil(panel.contentView)
    }

    func testInitWithEmptyInputUsesToolNameOnly() {
        let request = PermissionPromptRequest(id: "x", toolName: "Custom", input: [:])
        let panel = PermissionPromptPanel(request: request) { _ in }
        XCTAssertEqual(panel.promptId, "x")
    }

    func testPanelIsVisibleSizeAfterInit() {
        // Regression: with `contentRect` height=1 and no explicit setContentSize
        // the panel renders as a sub-pixel sliver and looks invisible to the user.
        let request = PermissionPromptRequest(
            id: "x", toolName: "Bash",
            input: ["command": .string("ls -la")]
        )
        let panel = PermissionPromptPanel(request: request) { _ in }
        XCTAssertGreaterThan(panel.frame.height, 60, "panel must have visible height")
        XCTAssertGreaterThan(panel.frame.width, 200, "panel must have visible width")
    }

    func testPanelCanBecomeKeyForButtonClicks() {
        // Regression: setting `becomesKeyOnlyIfNeeded = true` on a
        // .nonactivatingPanel suppresses key-window status on mouse-down, which
        // makes button clicks silently no-op.
        let request = PermissionPromptRequest(id: "x", toolName: "Bash", input: [:])
        let panel = PermissionPromptPanel(request: request) { _ in }
        XCTAssertTrue(panel.canBecomeKey, "panel must be able to become key")
        XCTAssertFalse(
            panel.becomesKeyOnlyIfNeeded,
            "becomesKeyOnlyIfNeeded=true breaks button clicks on a nonactivating panel"
        )
    }

    func testCloseButtonIsVisible() {
        let request = PermissionPromptRequest(id: "x", toolName: "Bash", input: [:])
        let panel = PermissionPromptPanel(request: request) { _ in }
        let close = panel.standardWindowButton(.closeButton)
        XCTAssertNotNil(close, "panel must have a close button")
        XCTAssertFalse(close?.isHidden ?? true, "close button must be visible")
    }

    func testWindowShouldCloseFiresDeny() {
        let request = PermissionPromptRequest(id: "x", toolName: "Bash", input: [:])
        var captured: PermissionPromptDecision.Behavior?
        let panel = PermissionPromptPanel(request: request) { captured = $0 }
        let allowed = panel.windowShouldClose(panel)
        XCTAssertFalse(allowed, "panel must defer the actual close to the manager")
        XCTAssertEqual(captured, .deny)
    }

    func testCollectionBehaviorFlagsAreCompatible() {
        // .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive;
        // setting both makes AppKit throw at runtime.
        let request = PermissionPromptRequest(id: "x", toolName: "X", input: [:])
        let panel = PermissionPromptPanel(request: request) { _ in }
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.collectionBehavior.contains(.moveToActiveSpace))
    }
}

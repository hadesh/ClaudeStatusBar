import XCTest
import AppKit
@testable import ClaudeStatusBar

/// Animator 在没有 NSStatusBarButton 的测试环境下也要能跑 ——
/// `button` 为 weak,传 nil 时应安全跳过 redraw,只验证 timer 行为。
final class StatusIconAnimatorTests: XCTestCase {

    func testNonWorkingDoesNotStartTimer() {
        let a = StatusIconAnimator(button: nil)
        a.update(
            status: .idle,
            workingColor: .orange,
            attentionColor: .yellow,
            badgeCount: 0
        )
        XCTAssertFalse(timerIsRunning(a))
    }

    func testWorkingStartsTimer() {
        let a = StatusIconAnimator(button: nil)
        a.update(
            status: .working,
            workingColor: .orange,
            attentionColor: .yellow,
            badgeCount: 0
        )
        XCTAssertTrue(timerIsRunning(a))
    }

    func testTransitionFromWorkingStopsTimer() {
        let a = StatusIconAnimator(button: nil)
        a.update(status: .working, workingColor: .orange, attentionColor: .yellow, badgeCount: 0)
        XCTAssertTrue(timerIsRunning(a))
        a.update(status: .idle, workingColor: .orange, attentionColor: .yellow, badgeCount: 0)
        XCTAssertFalse(timerIsRunning(a))
    }

    func testStopHaltsTimer() {
        let a = StatusIconAnimator(button: nil)
        a.update(status: .working, workingColor: .orange, attentionColor: .yellow, badgeCount: 0)
        a.stop()
        XCTAssertFalse(timerIsRunning(a))
    }

    /// Reflection helper:Animator 把 timer 设为 private,测试只关心是否存在。
    private func timerIsRunning(_ a: StatusIconAnimator) -> Bool {
        let mirror = Mirror(reflecting: a)
        for child in mirror.children where child.label == "timer" {
            return (child.value as? DispatchSourceTimer) != nil
        }
        return false
    }
}

import XCTest
import AppKit
@testable import ClaudeStatusBar

final class StatusIconTests: XCTestCase {

    func testNoneIsTemplateImage() {
        // 模板图允许 AppKit 跟随系统主题反相(浅色栏深 icon / 深色栏浅 icon)。
        XCTAssertTrue(StatusIcon.image(for: .none).isTemplate)
    }

    func testIdleIsTemplateImage() {
        XCTAssertTrue(StatusIcon.image(for: .idle).isTemplate)
    }

    func testWorkingIsNotTemplate() {
        // 活动状态用品牌橙色,不能被系统反相。
        XCTAssertFalse(StatusIcon.image(for: .working).isTemplate)
    }

    func testNeedsAttentionIsNotTemplate() {
        XCTAssertFalse(StatusIcon.image(for: .needsAttention).isTemplate)
    }

    func testImageRendersAtDefaultSize() {
        let img = StatusIcon.image(for: .working)
        XCTAssertEqual(img.size.width, 18)
        XCTAssertEqual(img.size.height, 18)
    }
}

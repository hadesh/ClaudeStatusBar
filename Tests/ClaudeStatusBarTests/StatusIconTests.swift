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

    func testIdleWithBadgeIsNotTemplate() {
        // badgeCount > 0 时不能用模板模式 —— 红圈会被 AppKit 强制变灰。
        XCTAssertFalse(StatusIcon.image(for: .idle, badgeCount: 1).isTemplate)
    }

    func testIdleZeroBadgeStillTemplate() {
        XCTAssertTrue(StatusIcon.image(for: .idle, badgeCount: 0).isTemplate)
    }

    func testWorkingBadgePropagatesToOctopus() {
        // 不直接断言像素;只验证 badgeCount > 0 + 任意状态下结果非 nil 且尺寸正确。
        let img = StatusIcon.image(for: .working, badgeCount: 2)
        XCTAssertEqual(img.size.width, 18)
        XCTAssertFalse(img.isTemplate)
    }

    func testWorkingFrameIndexProducesDistinctImage() {
        // working 态用 frameIndex 切帧,两帧像素必须不同 —— 否则 animator 切了也看不见。
        let f0 = StatusIcon.image(for: .working, frameIndex: 0)
        let f1 = StatusIcon.image(for: .working, frameIndex: 1)
        XCTAssertNotEqual(f0.tiffRepresentation, f1.tiffRepresentation)
    }
}

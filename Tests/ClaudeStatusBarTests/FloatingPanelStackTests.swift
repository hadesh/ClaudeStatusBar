import XCTest
import AppKit
@testable import ClaudeStatusBar

/// FloatingPanelStack 只管几何排版,不持有 panel 内容。测试用 dummy NSPanel
/// 构造各种宽高的占位 panel,断言注册/注销之后的 frame.origin。
///
/// 必须有 NSScreen.main —— XCTest 跑 macOS 测试时主屏总是存在,放心读
/// `visibleFrame`。
final class FloatingPanelStackTests: XCTestCase {

    private func makePanel(width: CGFloat, height: CGFloat) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        return panel
    }

    private func screenVisibleFrame() throws -> NSRect {
        guard let screen = NSScreen.main else {
            throw XCTSkip("NSScreen.main is nil — likely headless CI without a screen")
        }
        return screen.visibleFrame
    }

    // MARK: - 单 panel

    func testSinglePanelPlacedAtTopRight() throws {
        let visible = try screenVisibleFrame()
        let stack = FloatingPanelStack(edgeInset: 20, stackGap: 12)
        let panel = makePanel(width: 420, height: 200)
        stack.register(panel, owner: "test")

        let origin = panel.frame.origin
        XCTAssertEqual(origin.x, visible.maxX - 420 - 20, accuracy: 0.5, "右边对齐 visibleFrame.maxX - inset")
        XCTAssertEqual(origin.y, visible.maxY - 20 - 200, accuracy: 0.5, "顶部留 inset 后 panel 顶部对齐,origin.y 是底边")
    }

    // MARK: - 两个 panel 垂直堆叠

    func testTwoPanelsStackedVertically() throws {
        _ = try screenVisibleFrame()
        let stack = FloatingPanelStack(edgeInset: 20, stackGap: 12)
        let p1 = makePanel(width: 420, height: 200)
        let p2 = makePanel(width: 460, height: 250)
        stack.register(p1, owner: "p1")
        stack.register(p2, owner: "p2")

        // 第二个 panel 顶部 = 第一个 panel 底部 - gap;origin.y = 顶部 - 自身高度
        let p1Origin = p1.frame.origin
        let p2Origin = p2.frame.origin
        XCTAssertEqual(p2Origin.y, p1Origin.y - 12 - 250, accuracy: 0.5,
                       "第二个 panel 紧接第一个 panel 下方,中间留 stackGap")
    }

    // MARK: - 不同 width 各自右对齐

    func testDifferentWidthsAlignedToRight() throws {
        let visible = try screenVisibleFrame()
        let stack = FloatingPanelStack(edgeInset: 20, stackGap: 12)
        let narrow = makePanel(width: 420, height: 100)
        let wide = makePanel(width: 460, height: 100)
        stack.register(narrow, owner: "narrow")
        stack.register(wide, owner: "wide")

        // 右边 = visibleFrame.maxX - inset 都一致
        let narrowRight = narrow.frame.origin.x + narrow.frame.width
        let wideRight = wide.frame.origin.x + wide.frame.width
        XCTAssertEqual(narrowRight, visible.maxX - 20, accuracy: 0.5)
        XCTAssertEqual(wideRight, visible.maxX - 20, accuracy: 0.5)
        XCTAssertEqual(narrowRight, wideRight, accuracy: 0.5, "宽度不同的 panel 仍右对齐")
    }

    // MARK: - unregister 后剩下的重排到顶

    func testUnregisterRelaysOutRemainingToTop() throws {
        let visible = try screenVisibleFrame()
        let stack = FloatingPanelStack(edgeInset: 20, stackGap: 12)
        let p1 = makePanel(width: 420, height: 200)
        let p2 = makePanel(width: 420, height: 200)
        stack.register(p1, owner: "p1")
        stack.register(p2, owner: "p2")
        stack.unregister(p1)

        // 现在只剩 p2,它的 origin.y 应该跟单 panel 时一致
        XCTAssertEqual(p2.frame.origin.y, visible.maxY - 20 - 200, accuracy: 0.5,
                       "unregister 第一个后,第二个应重排到顶")
    }

    // MARK: - 重复注册不入栈两次

    func testDuplicateRegisterIsIdempotent() throws {
        _ = try screenVisibleFrame()
        let stack = FloatingPanelStack(edgeInset: 20, stackGap: 12)
        let p = makePanel(width: 420, height: 200)
        stack.register(p, owner: "once")
        stack.register(p, owner: "twice")
        XCTAssertEqual(stack.entryCountForTesting, 1, "同一 panel 不应重复入栈")
    }

    // MARK: - 注册顺序 = 显示顺序

    func testRegistrationOrderDeterminesStackOrder() throws {
        _ = try screenVisibleFrame()
        let stack = FloatingPanelStack(edgeInset: 20, stackGap: 12)
        let first = makePanel(width: 420, height: 100)
        let middle = makePanel(width: 420, height: 100)
        let last = makePanel(width: 420, height: 100)
        stack.register(first, owner: "1")
        stack.register(middle, owner: "2")
        stack.register(last, owner: "3")

        // origin.y 越小越靠下 —— 注册顺序 first/middle/last 对应 y 递减
        XCTAssertGreaterThan(first.frame.origin.y, middle.frame.origin.y)
        XCTAssertGreaterThan(middle.frame.origin.y, last.frame.origin.y)
    }
}

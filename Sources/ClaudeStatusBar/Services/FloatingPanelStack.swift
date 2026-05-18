import Cocoa

/// 多个独立的浮窗 manager(`PermissionPromptPanelManager` /
/// `AskUserQuestionPanelManager` / 未来可能再加的)共享同一条「右上向下」的
/// 浮窗队列。manager 在 panel 出现/消失时调 `register` / `unregister`,stack
/// 自己挑 y 起点 + 累加。每次 register/unregister 自动 `relayout()`。
///
/// 不变量:
/// - 注册顺序就是显示顺序,新出现的 panel 永远拼在最下面。
/// - `relayout()` 是幂等的,manager 在 panel 高度变化时可以多次调用。
/// - panel 的 width 各自决定;stack 只对齐 x 右边到 `visibleFrame.maxX - edgeInset`,
///   左边随宽度浮动。permission 浮窗(420)和 askq 浮窗(460)宽度不同,统一栈让
///   它们各自保留宽度但右边对齐成一列。
///
/// 为什么不让 stack 直接 own 浮窗:浮窗的内容、Outcome 类型、abandon 语义都跟
/// 各自的 manager 强绑定 —— 如果把 panel 生命周期搬出去,manager 就得通过 ID
/// 回查 panel,反而把 stack 变成另一个隐式注册中心。当前形态下 stack 只管几何,
/// manager 只管语义,两者解耦。
final class FloatingPanelStack {
    private struct Entry {
        let panel: NSPanel
        let owner: String   // debug 标签:"permission:<id>" / "askq:<id>"
    }

    /// 屏幕边缘到首个 panel 顶部的距离 + 末个 panel 底部到屏幕边缘的距离。
    private let edgeInset: CGFloat
    /// 相邻 panel 之间的间距。
    private let stackGap: CGFloat
    private var entries: [Entry] = []

    init(edgeInset: CGFloat = 20, stackGap: CGFloat = 12) {
        self.edgeInset = edgeInset
        self.stackGap = stackGap
    }

    func register(_ panel: NSPanel, owner: String) {
        // 防御:同一个 panel 重复注册时不重复入栈,只重排。
        guard !entries.contains(where: { $0.panel === panel }) else {
            relayout(); return
        }
        entries.append(Entry(panel: panel, owner: owner))
        relayout()
    }

    func unregister(_ panel: NSPanel) {
        entries.removeAll { $0.panel === panel }
        relayout()
    }

    /// 重算所有 panel 的位置。manager 在 panel 高度变化时(比如内容自适应导致
    /// fittingSize 增长)可以再调一次。
    func relayout() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var y = visible.maxY - edgeInset
        for e in entries {
            let panelFrame = e.panel.frame
            let x = visible.maxX - panelFrame.width - edgeInset
            y -= panelFrame.height
            e.panel.setFrameOrigin(NSPoint(x: x, y: y))
            y -= stackGap
        }
    }

    /// 测试钩子。
    var entryCountForTesting: Int { entries.count }
}

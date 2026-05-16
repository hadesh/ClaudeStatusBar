import Cocoa

/// 状态栏菜单里单个 session 主行的自定义 view。每次 `rebuildMenu` 都会
/// 新构造一批,旧的随 NSMenu 释放 —— 不在 view 里维护跨 menu 的状态。
///
/// **高亮信号双轨触发**:
/// 1. NSMenuDelegate.menu(_:willHighlight:) ── 键盘 ↑↓ 选中
/// 2. NSTrackingArea + mouseEntered/Exited ── 鼠标 hover
/// 经验上 view-based NSMenuItem 在不同 macOS 版本里只有其中一条路径稳定
/// 触发,两条都接成 setHighlighted(_:) 才能保证有反应。
///
/// 高亮可视化用 `wantsLayer + layer.backgroundColor`,不走 draw()。layer
/// 修改是同步可见的,不依赖 redraw 时机,也不会被 NSTextField subview 遮挡。
final class SessionRowView: NSView {

    private let session: Session
    private let secondary: String?
    private let onTerminate: (Int) -> Void
    private let onClick: () -> Void

    /// 仅当 session.status ∈ {busy, waiting} 时才创建。idle 时为 nil。
    /// internal 可见性,测试通过 @testable import 直接读。
    private(set) var terminateButton: NSButton?

    private var mainLabel: NSTextField!
    private var secondaryLabel: NSTextField?

    /// 当前是否处于「菜单选中态」。由 AppDelegate 通过 setHighlighted(_:) 推过来。
    private var isHighlightedByMenu: Bool = false

    init(
        session: Session,
        secondary: String?,
        onTerminate: @escaping (Int) -> Void,
        onClick: @escaping () -> Void
    ) {
        self.session = session
        self.secondary = secondary
        self.onTerminate = onTerminate
        self.onClick = onClick

        let height: CGFloat = secondary != nil ? 38 : 24
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: height))
        autoresizingMask = [.width]
        wantsLayer = true

        buildSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func buildSubviews() {
        let badge: String
        switch session.status {
        case .idle: badge = "○"
        case .busy: badge = "●"
        case .waiting: badge = "⚠"
        }
        let name = (session.cwd as NSString).lastPathComponent
        let mainText = "\(badge) \(name) · pid \(session.pid)"

        mainLabel = makeLabel(font: NSFont.menuFont(ofSize: 0))
        mainLabel.stringValue = mainText
        addSubview(mainLabel)

        if let s = secondary {
            let lbl = makeLabel(font: NSFont.systemFont(ofSize: 11))
            lbl.stringValue = s
            lbl.textColor = .secondaryLabelColor
            lbl.lineBreakMode = .byTruncatingTail
            secondaryLabel = lbl
            addSubview(lbl)
        }

        // idle 不需要终止按钮 —— Ctrl+C 在 readline 等输入时是清空 prompt,
        // 那是惊讶行为。busy/waiting 才挂按钮。
        if session.status != .idle {
            terminateButton = makeTerminateButton()
            addSubview(terminateButton!)
        }
    }

    private func makeLabel(font: NSFont) -> NSTextField {
        let lbl = NSTextField()
        lbl.font = font
        lbl.isEditable = false
        lbl.isSelectable = false
        lbl.isBordered = false
        lbl.drawsBackground = false
        lbl.backgroundColor = .clear
        lbl.textColor = .labelColor
        return lbl
    }

    private func makeTerminateButton() -> NSButton {
        let btn = NSButton()
        btn.bezelStyle = .shadowlessSquare
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyUpOrDown
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        btn.image = NSImage(
            systemSymbolName: "stop.circle.fill",
            accessibilityDescription: "中断当前任务"
        )?.withSymbolConfiguration(cfg)
        btn.contentTintColor = .secondaryLabelColor
        btn.toolTip = "中断当前任务(SIGINT)"
        btn.target = self
        btn.action = #selector(terminateClicked)
        btn.isHidden = true
        return btn
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let buttonSize: CGFloat = 18
        let buttonRightInset: CGFloat = 12
        let mainLeftInset: CGFloat = 14   // 跟 NSMenuItem 默认左缩进对齐
        let mainRightInset: CGFloat = buttonSize + buttonRightInset + 4

        if let _ = secondaryLabel {
            mainLabel.frame = NSRect(x: mainLeftInset, y: h - 20,
                                     width: w - mainLeftInset - mainRightInset, height: 16)
            secondaryLabel!.frame = NSRect(x: mainLeftInset, y: 4,
                                           width: w - mainLeftInset - 14, height: 14)
        } else {
            mainLabel.frame = NSRect(x: mainLeftInset, y: 4,
                                     width: w - mainLeftInset - mainRightInset, height: 16)
        }

        if let btn = terminateButton {
            let y = (h - buttonSize) / 2
            btn.frame = NSRect(x: w - buttonSize - buttonRightInset, y: y,
                               width: buttonSize, height: buttonSize)
        }
    }

    /// `@objc` 是为了 NSButton.target/action 派发;internal 可见性是为了让单测
    /// 直接调用 —— XCTest 环境下 NSButton.performClick / sendAction 都不可靠
    /// (无 NSApp event loop / 按钮不在 window 里),走 target/action 的真实链路
    /// 是这一个方法。
    @objc func terminateClicked() {
        onTerminate(session.pid)
    }

    // MARK: - 高亮态(menu delegate + tracking area 双轨触发)

    /// 双轨入口:AppDelegate.menu(_:willHighlight:) 和本 view 的 mouseEntered/
    /// Exited 都会调过来。第二次同值调用提前 return。
    func setHighlighted(_ on: Bool) {
        guard isHighlightedByMenu != on else { return }
        isHighlightedByMenu = on
        layer?.backgroundColor = on
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
        mainLabel.textColor = on ? .selectedMenuItemTextColor : .labelColor
        secondaryLabel?.textColor = on
            ? .selectedMenuItemTextColor
            : .secondaryLabelColor
        terminateButton?.isHidden = !on
    }

    // MARK: - 鼠标 hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 菜单弹出时 view 才被加到 NSCarbonMenuWindow,trackingArea 必须在这
        // 之后重新装一次,首次 updateTrackingAreas 在 view 还没有 window 时
        // 调用过一次但没意义。
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        setHighlighted(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    // MARK: - 主行点击

    /// NSMenu tracking 模式下 NSMenuItem.view 不会自动触发 NSMenuItem.action,
    /// 必须自己处理 mouseUp。按钮区域内的点击让 NSButton 自己消化。
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let btn = terminateButton, !btn.isHidden, btn.frame.contains(p) {
            return
        }
        onClick()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

import Cocoa

/// 状态栏菜单里单个 session 主行的自定义 view。每次 `rebuildMenu` 都会
/// 新构造一批,旧的随 NSMenu 释放 —— 不在 view 里维护跨 menu 的状态。
///
/// hover 行为:鼠标 enter → 终止按钮 isHidden = false;exit → 隐藏。
/// 跟 `enclosingMenuItem.isHighlighted` 解耦,因为键盘上下选时高亮跟着移
/// 但鼠标其实在别处,这种情况按钮不该出现。
///
/// 高亮态背景由本 view 自己画 —— `NSMenuItem.view` 不会自动跟随选中色。
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

    // MARK: - hover 跟踪

    /// 抽出来给单测调用 —— 真 NSEvent 构造比较繁琐,而 NSResponder 的
    /// mouseEntered/mouseExited 本身就只是把事件转给这里。
    func handleHoverChanged(isHovering: Bool) {
        terminateButton?.isHidden = !isHovering
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        handleHoverChanged(isHovering: true)
    }

    override func mouseExited(with event: NSEvent) {
        handleHoverChanged(isHovering: false)
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

    // MARK: - 高亮态背景

    override func draw(_ dirtyRect: NSRect) {
        if enclosingMenuItem?.isHighlighted == true {
            NSColor.selectedMenuItemColor.setFill()
            bounds.fill()
            mainLabel.textColor = .selectedMenuItemTextColor
            secondaryLabel?.textColor = .selectedMenuItemTextColor
        } else {
            mainLabel.textColor = .labelColor
            secondaryLabel?.textColor = .secondaryLabelColor
        }
        super.draw(dirtyRect)
    }
}

import AppKit

public final class SettingsWindowController: NSWindowController {
    private enum Tab: Int, CaseIterable {
        case general
        case appearance
        case about

        var label: String {
            switch self {
            case .general: return "通用"
            case .appearance: return "外观"
            case .about: return "关于"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .about: return "info.circle"
            }
        }
    }

    private let settings: SettingsStore
    private let loginItem: LoginItemController
    private lazy var generalVC = GeneralSettingsViewController(settings: settings, loginItem: loginItem)
    private lazy var appearanceVC = AppearanceSettingsViewController(settings: settings)
    private lazy var aboutVC = AboutSettingsViewController()

    private let tabBar = NSStackView()
    private let contentContainer = NSView()
    private var tabButtons: [Tab: NSButton] = [:]
    private var currentTab: Tab = .general

    public init(settings: SettingsStore, loginItem: LoginItemController = LoginItemController()) {
        self.settings = settings
        self.loginItem = loginItem
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClaudeStatusBar"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = makeRoot()
        select(.general)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
    }

    private func makeRoot() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        tabBar.orientation = .horizontal
        tabBar.alignment = .centerY
        tabBar.distribution = .fillEqually
        tabBar.spacing = 8
        tabBar.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        for tab in Tab.allCases {
            let button = makeTabButton(for: tab)
            tabBar.addArrangedSubview(button)
            tabButtons[tab] = button
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(tabBar)
        root.addSubview(separator)
        root.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            separator.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func makeTabButton(for tab: Tab) -> NSButton {
        let button = NSButton()
        button.title = tab.label
        button.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.label)
        button.imagePosition = .imageAbove
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .smallSquare
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 11)
        button.target = self
        button.action = #selector(tabClicked(_:))
        button.tag = tab.rawValue
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 56).isActive = true
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        return button
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let tab = Tab(rawValue: sender.tag) else { return }
        select(tab)
    }

    private func select(_ tab: Tab) {
        currentTab = tab
        for (t, button) in tabButtons {
            let active = (t == tab)
            button.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
            button.attributedTitle = NSAttributedString(
                string: t.label,
                attributes: [
                    .foregroundColor: active ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 11, weight: active ? .semibold : .regular),
                ]
            )
        }
        installContent(for: tab)
    }

    private func installContent(for tab: Tab) {
        let vc: NSViewController
        switch tab {
        case .general: vc = generalVC
        case .appearance: vc = appearanceVC
        case .about: vc = aboutVC
        }
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let body = vc.view
        body.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            body.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        resizeWindow(forContent: vc.preferredContentSize)
    }

    private func resizeWindow(forContent size: NSSize) {
        guard let window else { return }
        let tabBarHeight: CGFloat = 80  // tab buttons + insets + separator
        let target = NSSize(
            width: max(460, size.width),
            height: tabBarHeight + (size.height > 0 ? size.height : 240)
        )
        var frame = window.frame
        let contentRect = window.contentRect(forFrameRect: frame)
        let dx = target.width - contentRect.width
        let dy = target.height - contentRect.height
        frame.origin.y -= dy
        frame.size.width += dx
        frame.size.height += dy
        window.setFrame(frame, display: true, animate: false)
    }
}

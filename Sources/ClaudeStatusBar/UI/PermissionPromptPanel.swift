import Cocoa

/// Floating non-activating panel showing one pending permission request with
/// `允许 / 一直允许 / 拒绝` buttons. Single click on any button fires the
/// supplied response closure. Esc maps to deny, Return to allow, Tab cycles
/// across all three buttons. The window's close button (✕) maps to `abandon`,
/// not deny — the user's intent is "I'll answer in the terminal", so we let
/// the helper exit silently and let the CLI's terminal prompt take over.
final class PermissionPromptPanel: NSPanel, NSWindowDelegate {
    /// Panel-internal signal. Distinct from `PermissionPromptDecision.Behavior`
    /// (which is the app→helper wire type) so `abandon` doesn't leak into
    /// JSON encoders that have no business serializing it.
    enum Outcome {
        case allow
        case allowAlways
        case deny
        /// User dismissed the panel without making a decision (e.g. ✕).
        case abandon
    }
    typealias Response = (Outcome) -> Void

    static let panelWidth: CGFloat = 420
    static let bodyMaxHeight: CGFloat = 160
    static let bodyMinHeight: CGFloat = 44

    let promptId: String
    private let onResponse: Response
    private weak var allowButton: NSButton?

    init(request: PermissionPromptRequest, onResponse: @escaping Response) {
        self.promptId = request.id
        self.onResponse = onResponse

        let frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200)
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Claude Code 授权请求"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        delegate = self
        for kind: NSWindow.ButtonType in [.miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        let body = makeContent(for: request)
        contentView = body
        body.layoutSubtreeIfNeeded()
        let fitting = body.fittingSize
        if fitting.height > 0 {
            setContentSize(NSSize(width: Self.panelWidth, height: fitting.height))
        }
        // Default focus on Allow so a quick Return resolves; Tab cycles to Deny.
        if let allowButton {
            initialFirstResponder = allowButton
        }
    }

    // Window-close (✕) means "I'll go answer in the terminal" — abandon, don't
    // deny. The store's reply receives nil; the listener closes the helper
    // socket without writing; the helper exits silently; the CLI's terminal
    // prompt wins the race. Manager still receives the resolved signal and
    // closes this panel through the normal dismiss path.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onResponse(.abandon)
        return false  // manager calls panel.close() after store.resolved fires
    }

    /// Make sure the panel becomes key on mouse-down so button clicks fire on
    /// the first click, matching the behaviour the user expects from a dialog.
    override var canBecomeKey: Bool { true }

    @objc private func allow() { onResponse(.allow) }
    @objc private func deny() { onResponse(.deny) }
    @objc private func allowAlways() { onResponse(.allowAlways) }

    // MARK: - Layout

    private func makeContent(for request: PermissionPromptRequest) -> NSView {
        let header = makeHeaderRow(for: request)
        let bodyContainer = makeBodyContainer(for: request)
        let buttonRow = makeButtonRow()

        let column = NSStackView(views: [header, bodyContainer, buttonRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)

        // The header / body / button row each need to span the full column
        // width — leading-only alignment would shrink them to intrinsic width.
        for view in [header, bodyContainer, buttonRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 16),
                view.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -16),
            ])
        }
        return column
    }

    private func makeHeaderRow(for request: PermissionPromptRequest) -> NSView {
        let tool = NSTextField(labelWithString: request.toolName)
        tool.font = .systemFont(ofSize: 14, weight: .semibold)
        tool.textColor = .labelColor

        let session = PermissionPromptPreview.sessionName(for: request) ?? ""
        let sessionLabel = NSTextField(labelWithString: session.isEmpty ? "" : "· \(session)")
        sessionLabel.font = .systemFont(ofSize: 12, weight: .regular)
        sessionLabel.textColor = .secondaryLabelColor
        sessionLabel.lineBreakMode = .byTruncatingMiddle
        sessionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [tool, sessionLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        row.distribution = .fill
        return row
    }

    private func makeBodyContainer(for request: PermissionPromptRequest) -> NSView {
        let bodyText = PermissionPromptPreview.bodyPreview(for: request, maxLength: 4096)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.string = bodyText.isEmpty ? "(无额外参数)" : bodyText
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = bodyText.isEmpty ? .tertiaryLabelColor : .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.lineFragmentPadding = 0
        }
        scroll.documentView = textView

        // Pre-measure the rendered height so we can shrink the panel for short
        // inputs and cap it for long ones. NSScrollView with a max constraint
        // alone doesn't shrink; we set the actual height on the constraint.
        let availableWidth = Self.panelWidth - 2 * 16 - 12 - 6 * 2  // insets + scrollbar + textContainerInset
        let needed = Self.measureTextHeight(
            text: textView.string,
            font: textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
            width: availableWidth
        )
        let target = min(max(needed + 12, Self.bodyMinHeight), Self.bodyMaxHeight)
        let heightConstraint = scroll.heightAnchor.constraint(equalToConstant: target)
        heightConstraint.priority = .required
        heightConstraint.isActive = true
        return scroll
    }

    private func makeButtonRow() -> NSView {
        let denyButton = NSButton(title: "拒绝", target: self, action: #selector(deny))
        denyButton.bezelStyle = .rounded
        denyButton.keyEquivalent = "\u{1B}"  // Esc — mirrors KeyboardShortcutCatalog.panelCancel

        let allowAlwaysButton = NSButton(title: "一直允许", target: self, action: #selector(allowAlways))
        allowAlwaysButton.bezelStyle = .rounded
        // 不设 keyEquivalent:回车留给「允许」(单次),Tab 才能走到这里。

        let allowButton = NSButton(title: "允许", target: self, action: #selector(allow))
        allowButton.bezelStyle = .rounded
        allowButton.keyEquivalent = "\r"  // Return — mirrors KeyboardShortcutCatalog.panelConfirm; gets default-button blue highlight
        self.allowButton = allowButton

        // Tab cycle: deny → allowAlways → allow → deny. AppKit walks nextKeyView on Tab.
        denyButton.nextKeyView = allowAlwaysButton
        allowAlwaysButton.nextKeyView = allowButton
        allowButton.nextKeyView = denyButton

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [spacer, denyButton, allowAlwaysButton, allowButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fill
        return row
    }

    // MARK: - Helpers

    /// Measures the rendered height of `text` at the given width, using the
    /// same options NSTextView uses internally so the cap is accurate.
    private static func measureTextHeight(text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard width > 0, !text.isEmpty else {
            return font.ascender - font.descender + font.leading
        }
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let bounds = attr.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.height)
    }
}

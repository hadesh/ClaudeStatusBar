import Cocoa

/// 解析 AskUserQuestion 工具的 input 字段。结构是
/// `{questions: [{question: string, options: [{value, label, description?}]}]}`,
/// schema 漂移时返回 nil 让上层降级到「仅显示 toolName + 跳回终端」。
struct AskUserQuestionInput {
    struct Option {
        let value: String?
        let label: String
        let description: String?
    }
    struct Question {
        let question: String
        let options: [Option]
    }
    let questions: [Question]

    static func parse(_ request: PermissionPromptRequest) -> AskUserQuestionInput? {
        guard case .array(let qs)? = request.input["questions"], !qs.isEmpty else {
            return nil
        }
        let questions: [Question] = qs.compactMap { qVal in
            guard case .object(let q) = qVal,
                  case .string(let text)? = q["question"]
            else { return nil }
            let opts: [Option]
            if case .array(let optArr)? = q["options"] {
                opts = optArr.compactMap { oVal in
                    guard case .object(let o) = oVal,
                          case .string(let label)? = o["label"]
                    else { return nil }
                    let value: String? = {
                        if case .string(let v)? = o["value"] { return v }
                        return nil
                    }()
                    let desc: String? = {
                        if case .string(let d)? = o["description"] { return d }
                        return nil
                    }()
                    return Option(value: value, label: label, description: desc)
                }
            } else {
                opts = []
            }
            return Question(question: text, options: opts)
        }
        return questions.isEmpty ? nil : AskUserQuestionInput(questions: questions)
    }
}

/// 浮窗形态:展示 AskUserQuestion 的完整问题文案 + 所有选项。本期不代答,
/// 仅给一个「跳回终端答」按钮 + ✕。✕ 等同 abandon(让 hook helper 退出 0,
/// CLI 端终端 prompt 接管 race)。
final class AskUserQuestionPanel: NSPanel, NSWindowDelegate {
    enum Outcome {
        case goToTerminal
        case abandon
    }
    typealias Response = (Outcome) -> Void

    static let panelWidth: CGFloat = 460
    static let bodyMaxHeight: CGFloat = 320

    let promptId: String
    let request: PermissionPromptRequest
    private let onResponse: Response

    init(request: PermissionPromptRequest, onResponse: @escaping Response) {
        self.promptId = request.id
        self.request = request
        self.onResponse = onResponse

        let frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240)
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Claude Code 需要你回答"
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
        let body = makeContent()
        contentView = body
        body.layoutSubtreeIfNeeded()
        let fitting = body.fittingSize
        if fitting.height > 0 {
            setContentSize(NSSize(width: Self.panelWidth, height: fitting.height))
        }
    }

    override var canBecomeKey: Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onResponse(.abandon)
        return false
    }

    @objc private func goToTerminal() { onResponse(.goToTerminal) }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let header = makeHeaderRow()
        let body = makeBodyContainer()
        let buttonRow = makeButtonRow()

        let column = NSStackView(views: [header, body, buttonRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
        for view in [header, body, buttonRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 16),
                view.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -16),
            ])
        }
        return column
    }

    private func makeHeaderRow() -> NSView {
        let session = PermissionPromptPreview.sessionName(for: request) ?? ""
        let label = NSTextField(labelWithString: session.isEmpty ? "AskUserQuestion" : "AskUserQuestion · \(session)")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    private func makeBodyContainer() -> NSView {
        let parsed = AskUserQuestionInput.parse(request)
        let attr = NSMutableAttributedString()

        if let parsed {
            for (qIdx, q) in parsed.questions.enumerated() {
                if qIdx > 0 { attr.append(NSAttributedString(string: "\n\n")) }
                attr.append(NSAttributedString(
                    string: "❓ \(q.question)\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: NSColor.labelColor,
                    ]
                ))
                for (oIdx, opt) in q.options.enumerated() {
                    let circled = circledNumber(oIdx + 1)
                    attr.append(NSAttributedString(
                        string: "  \(circled) \(opt.label)\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                            .foregroundColor: NSColor.labelColor,
                        ]
                    ))
                    if let d = opt.description, !d.isEmpty {
                        attr.append(NSAttributedString(
                            string: "      \(d)\n",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ]
                        ))
                    }
                }
            }
        } else {
            attr.append(NSAttributedString(
                string: "(无法解析问题内容,请直接回到终端答复)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            ))
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.textStorage?.setAttributedString(attr)
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

        // 简化:不预测高度,固定 maxHeight,内容超出靠滚动条。
        scroll.heightAnchor.constraint(lessThanOrEqualToConstant: Self.bodyMaxHeight).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        return scroll
    }

    private func makeButtonRow() -> NSView {
        let button = NSButton(title: "跳回终端答", target: self, action: #selector(goToTerminal))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [spacer, button])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func circledNumber(_ n: Int) -> String {
        switch n {
        case 1: return "①"
        case 2: return "②"
        case 3: return "③"
        case 4: return "④"
        case 5: return "⑤"
        case 6: return "⑥"
        case 7: return "⑦"
        case 8: return "⑧"
        case 9: return "⑨"
        default: return "(\(n))"
        }
    }
}

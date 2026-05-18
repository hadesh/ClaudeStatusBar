import Cocoa

/// 解析 AskUserQuestion 工具的 input 字段。结构是
/// `{questions: [{question, header, multiSelect, options: [{label, description?}]}]}`,
/// schema 漂移时返回 nil 让上层降级到「仅显示 toolName + 跳回终端」。
struct AskUserQuestionInput {
    struct Option {
        let label: String
        let description: String?
    }
    struct Question {
        let question: String
        let header: String?
        let multiSelect: Bool
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
            let header: String? = {
                if case .string(let h)? = q["header"] { return h }
                return nil
            }()
            let multiSelect: Bool = {
                if case .bool(let b)? = q["multiSelect"] { return b }
                return false
            }()
            let opts: [Option]
            if case .array(let optArr)? = q["options"] {
                opts = optArr.compactMap { oVal in
                    guard case .object(let o) = oVal,
                          case .string(let label)? = o["label"]
                    else { return nil }
                    let desc: String? = {
                        if case .string(let d)? = o["description"] { return d }
                        return nil
                    }()
                    return Option(label: label, description: desc)
                }
            } else {
                opts = []
            }
            return Question(
                question: text, header: header,
                multiSelect: multiSelect, options: opts
            )
        }
        return questions.isEmpty ? nil : AskUserQuestionInput(questions: questions)
    }
}

/// 浮窗形态:
///   - 单选问题 → radio 按钮组 + 「Other:」radio + 文本框
///   - 多选问题 → checkbox 组 + 「Other:」checkbox + 文本框
///   - 提交 → `.submit(answers:)`,answers key=question 文本,value=选中 label(多选 ", " 串)
///   - 跳回终端 / ✕ → `.goToTerminal` / `.abandon`(让 helper EOF 退出 0,CLI 终端 prompt 接管)
final class AskUserQuestionPanel: NSPanel, NSWindowDelegate {
    enum Outcome: Equatable {
        case submit(answers: [String: String])
        case goToTerminal
        case abandon
    }
    typealias Response = (Outcome) -> Void

    static let panelWidth: CGFloat = 460
    static let bodyMaxHeight: CGFloat = 360

    let promptId: String
    let request: PermissionPromptRequest
    private let onResponse: Response

    /// 每个 question 的所有控件 + 取答案的 closure。本面板生命周期内不会重排。
    private var questionRows: [QuestionRow] = []
    private var submitButton: NSButton!

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
        updateSubmitEnabled()
    }

    override var canBecomeKey: Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onResponse(.abandon)
        return false
    }

    @objc private func goToTerminal() { onResponse(.goToTerminal) }

    @objc private func submit() {
        var answers: [String: String] = [:]
        for row in questionRows {
            guard let answer = row.collectAnswer() else { return }  // 防御:校验失败不该走到这
            answers[row.question.question] = answer
        }
        onResponse(.submit(answers: answers))
    }

    @objc fileprivate func selectionChanged() { updateSubmitEnabled() }

    private func updateSubmitEnabled() {
        submitButton?.isEnabled = questionRows.allSatisfy { $0.isAnswered }
    }

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
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        guard let parsed else {
            let fallback = NSTextField(labelWithString: "(无法解析问题内容,请直接回到终端答复)")
            fallback.textColor = .tertiaryLabelColor
            fallback.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(fallback)
            return wrapInScroll(stack)
        }

        for q in parsed.questions {
            let row = QuestionRow(
                question: q,
                width: Self.panelWidth - 32 - 8,  // 减边距 + scroll 内边距
                onChange: #selector(selectionChanged),
                target: self
            )
            questionRows.append(row)
            stack.addArrangedSubview(row.view)
        }
        return wrapInScroll(stack)
    }

    private func wrapInScroll(_ content: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = false

        let docView = NSView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: docView.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -8),
            content.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -8),
        ])
        scroll.documentView = docView

        scroll.heightAnchor.constraint(lessThanOrEqualToConstant: Self.bodyMaxHeight).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        return scroll
    }

    private func makeButtonRow() -> NSView {
        let goTerminal = NSButton(title: "跳回终端答", target: self, action: #selector(goToTerminal))
        goTerminal.bezelStyle = .rounded

        let submit = NSButton(title: "提交", target: self, action: #selector(submit))
        submit.bezelStyle = .rounded
        submit.keyEquivalent = "\r"
        self.submitButton = submit

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [goTerminal, spacer, submit])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: - Test Hooks

    func selectOptionForTesting(questionIndex: Int, label: String) {
        questionRows[questionIndex].selectForTesting(label: label)
        updateSubmitEnabled()
    }

    func setOtherTextForTesting(questionIndex: Int, text: String) {
        questionRows[questionIndex].setOtherText(text)
        updateSubmitEnabled()
    }

    var isSubmitEnabledForTesting: Bool { submitButton?.isEnabled ?? false }

    func clickSubmitForTesting() { submit() }
}

/// 单个 question 在 panel 里的状态机:管理 N 个 option button + 1 行 Other(button + text field)。
/// 单选用 NSButton(.radio) 同 superview 自动互斥;多选用 .switch / checkbox。
private final class QuestionRow {
    let question: AskUserQuestionInput.Question
    let view: NSView
    private var optionButtons: [NSButton] = []
    private var otherButton: NSButton!
    private var otherField: NSTextField!

    init(
        question: AskUserQuestionInput.Question,
        width: CGFloat,
        onChange: Selector,
        target: AnyObject
    ) {
        self.question = question

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        if let header = question.header, !header.isEmpty {
            let chip = NSTextField(labelWithString: header)
            chip.font = .systemFont(ofSize: 10, weight: .medium)
            chip.textColor = .secondaryLabelColor
            stack.addArrangedSubview(chip)
        }

        let prompt = NSTextField(labelWithString: question.question)
        prompt.font = .systemFont(ofSize: 13, weight: .medium)
        prompt.textColor = .labelColor
        prompt.lineBreakMode = .byWordWrapping
        prompt.maximumNumberOfLines = 0
        prompt.preferredMaxLayoutWidth = width
        stack.addArrangedSubview(prompt)

        for opt in question.options {
            let button = QuestionRow.makeOptionButton(
                title: opt.label, multiSelect: question.multiSelect,
                target: target, action: onChange
            )
            stack.addArrangedSubview(button)
            optionButtons.append(button)

            if let desc = opt.description, !desc.isEmpty {
                let descLabel = NSTextField(labelWithString: desc)
                descLabel.font = .systemFont(ofSize: 11)
                descLabel.textColor = .secondaryLabelColor
                descLabel.lineBreakMode = .byWordWrapping
                descLabel.maximumNumberOfLines = 0
                descLabel.preferredMaxLayoutWidth = width - 24
                let indent = NSStackView(views: [descLabel])
                indent.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
                stack.addArrangedSubview(indent)
            }
        }

        let otherRow = NSStackView()
        otherRow.orientation = .horizontal
        otherRow.spacing = 6
        otherRow.alignment = .firstBaseline
        let otherBtn = QuestionRow.makeOptionButton(
            title: "Other:", multiSelect: question.multiSelect,
            target: target, action: onChange
        )
        let field = NSTextField()
        field.placeholderString = "自定义回答"
        field.isEnabled = false
        field.target = target
        field.action = onChange
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        otherRow.addArrangedSubview(otherBtn)
        otherRow.addArrangedSubview(field)
        stack.addArrangedSubview(otherRow)
        self.otherButton = otherBtn
        self.otherField = field

        view = stack
    }

    private static func makeOptionButton(
        title: String, multiSelect: Bool,
        target: AnyObject, action: Selector
    ) -> NSButton {
        let button: NSButton
        if multiSelect {
            button = NSButton(checkboxWithTitle: title, target: target, action: action)
        } else {
            button = NSButton(radioButtonWithTitle: title, target: target, action: action)
        }
        return button
    }

    /// 是否已经给出可用答案。空多选允许;单选必须选一项;Other 选中但 text 空算未答。
    var isAnswered: Bool {
        if otherButton.state == .on, otherField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if question.multiSelect {
            // multi-select 全空也允许提交(d.ts 规定 multiSelect 答案可空)
            otherField.isEnabled = (otherButton.state == .on)
            return true
        }
        // single: 必须选了某个 option 或选了 Other 且 text 非空
        let hasOption = optionButtons.contains { $0.state == .on }
        let hasOther = otherButton.state == .on && !otherField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        otherField.isEnabled = (otherButton.state == .on)
        return hasOption || hasOther
    }

    func collectAnswer() -> String? {
        var labels: [String] = []
        for (i, btn) in optionButtons.enumerated() where btn.state == .on {
            labels.append(question.options[i].label)
        }
        if otherButton.state == .on {
            let text = otherField.stringValue.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { labels.append(text) }
        }
        if !question.multiSelect {
            // 单选:理论上 labels 至多 1;若用户用键盘多选了 radio + Other 也只取第一个
            return labels.first
        }
        return labels.joined(separator: ", ")
    }

    // MARK: - Test Hooks

    func selectForTesting(label: String) {
        if label == "__OTHER__" {
            otherButton.state = .on
            return
        }
        for (i, opt) in question.options.enumerated() where opt.label == label {
            if question.multiSelect {
                optionButtons[i].state = .on
            } else {
                for b in optionButtons { b.state = .off }
                optionButtons[i].state = .on
            }
        }
    }

    func setOtherText(_ text: String) {
        otherField.stringValue = text
        otherField.isEnabled = (otherButton.state == .on)
    }
}

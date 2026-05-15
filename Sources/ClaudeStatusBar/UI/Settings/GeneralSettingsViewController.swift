import AppKit
import Combine

public final class GeneralSettingsViewController: NSViewController {
    private let settings: SettingsStore
    private let loginItem: LoginItemController
    private var cancellables = Set<AnyCancellable>()

    private let loginItemCheckbox = NSButton(checkboxWithTitle: "开机自启", target: nil, action: nil)
    private let notificationsCheckbox = NSButton(checkboxWithTitle: "启用等待通知", target: nil, action: nil)
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let showCurrentWindowCheckbox = NSButton(checkboxWithTitle: "显示「本 5 小时」用量", target: nil, action: nil)
    private let showLifetimeCheckbox = NSButton(checkboxWithTitle: "显示「总用量(按模型)」", target: nil, action: nil)

    private let hookJSONTextView = NSTextView()
    private let hookJSONScrollView = NSScrollView()
    private let hookApplyButton = NSButton(title: "应用", target: nil, action: nil)
    private let hookResetButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let hookStatusLabel = NSTextField(labelWithString: "")

    private struct IntervalChoice {
        let title: String
        let seconds: TimeInterval?
    }
    private let choices: [IntervalChoice] = [
        .init(title: "30 秒",   seconds: 30),
        .init(title: "1 分钟",  seconds: 60),
        .init(title: "2 分钟",  seconds: 120),
        .init(title: "5 分钟",  seconds: 300),
        .init(title: "不提醒",  seconds: nil),
    ]

    public init(settings: SettingsStore, loginItem: LoginItemController) {
        self.settings = settings
        self.loginItem = loginItem
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        loginItemCheckbox.target = self
        loginItemCheckbox.action = #selector(toggleLoginItem(_:))
        if !LoginItemController.isAvailable {
            loginItemCheckbox.isEnabled = false
            loginItemCheckbox.toolTip = "需要将 ClaudeStatusBar 打包成 .app 后才可用"
        }

        notificationsCheckbox.target = self
        notificationsCheckbox.action = #selector(toggleNotifications(_:))

        for c in choices {
            intervalPopup.addItem(withTitle: c.title)
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged(_:))

        let intervalRow = NSStackView(views: [
            NSTextField(labelWithString: "提醒间隔:"),
            intervalPopup,
        ])
        intervalRow.orientation = .horizontal
        intervalRow.spacing = 8

        stack.addArrangedSubview(loginItemCheckbox)
        stack.addArrangedSubview(notificationsCheckbox)
        stack.addArrangedSubview(intervalRow)

        // ── 菜单显示区段 ─────────────────────────────────────────
        let menuSeparator = NSBox()
        menuSeparator.boxType = .separator
        menuSeparator.translatesAutoresizingMaskIntoConstraints = false
        menuSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(menuSeparator)

        let menuHeader = NSTextField(labelWithString: "菜单显示")
        menuHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(menuHeader)

        showCurrentWindowCheckbox.target = self
        showCurrentWindowCheckbox.action = #selector(toggleShowCurrentWindow(_:))
        showLifetimeCheckbox.target = self
        showLifetimeCheckbox.action = #selector(toggleShowLifetime(_:))
        stack.addArrangedSubview(showCurrentWindowCheckbox)
        stack.addArrangedSubview(showLifetimeCheckbox)

        // ── Hook 配置区段 ─────────────────────────────────────────
        let hookSeparator = NSBox()
        hookSeparator.boxType = .separator
        hookSeparator.translatesAutoresizingMaskIntoConstraints = false
        hookSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(hookSeparator)

        let hookHeader = NSTextField(labelWithString: "PermissionRequest Hook")
        hookHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(hookHeader)

        let hookSubtitle = NSTextField(labelWithString: "把 ClaudeStatusBarHook 注册到 ~/.claude/settings.json,用 GUI 替代手动编辑。")
        hookSubtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hookSubtitle.textColor = .secondaryLabelColor
        hookSubtitle.lineBreakMode = .byWordWrapping
        hookSubtitle.maximumNumberOfLines = 0
        hookSubtitle.preferredMaxLayoutWidth = 380
        stack.addArrangedSubview(hookSubtitle)

        let jsonLabel = NSTextField(labelWithString: "Hook JSON:")
        stack.addArrangedSubview(jsonLabel)

        configureHookJSONEditor()
        stack.addArrangedSubview(hookJSONScrollView)
        // 高度 200pt(够展示完整 default JSON),内部滚动;不做交互式 resize。
        hookJSONScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hookJSONScrollView.widthAnchor.constraint(equalToConstant: 440),
            hookJSONScrollView.heightAnchor.constraint(equalToConstant: 200),
        ])

        hookApplyButton.target = self
        hookApplyButton.action = #selector(applyHookConfig(_:))
        hookApplyButton.bezelStyle = .rounded
        hookApplyButton.keyEquivalent = "\r"
        hookResetButton.target = self
        hookResetButton.action = #selector(resetHookConfig(_:))
        hookResetButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [hookResetButton, hookApplyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        stack.addArrangedSubview(buttonRow)

        hookStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hookStatusLabel.textColor = .secondaryLabelColor
        hookStatusLabel.lineBreakMode = .byWordWrapping
        hookStatusLabel.maximumNumberOfLines = 0
        hookStatusLabel.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(hookStatusLabel)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        preferredContentSize = NSSize(width: 510, height: 580)

        sync()
        observe()
        loadHookConfig()
    }

    private func observe() {
        settings.$notificationsEnabled
            .sink { [weak self] enabled in
                self?.notificationsCheckbox.state = enabled ? .on : .off
                self?.intervalPopup.isEnabled = enabled
            }
            .store(in: &cancellables)
        settings.$reminderInterval
            .sink { [weak self] interval in self?.applyInterval(interval) }
            .store(in: &cancellables)
    }

    private func sync() {
        loginItemCheckbox.state = (LoginItemController.isAvailable && loginItem.isEnabled) ? .on : .off
        notificationsCheckbox.state = settings.notificationsEnabled ? .on : .off
        intervalPopup.isEnabled = settings.notificationsEnabled
        applyInterval(settings.reminderInterval)
        showCurrentWindowCheckbox.state = settings.showCurrentWindow ? .on : .off
        showLifetimeCheckbox.state = settings.showLifetimeUsage ? .on : .off
    }

    private func applyInterval(_ interval: TimeInterval?) {
        let idx = choices.firstIndex(where: { $0.seconds == interval })
            ?? choices.firstIndex(where: { $0.seconds == nil }) ?? 0
        intervalPopup.selectItem(at: idx)
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        do {
            try loginItem.setEnabled(sender.state == .on)
        } catch {
            NSLog("Toggle login item failed: \(error)")
            sender.state = loginItem.isEnabled ? .on : .off
        }
    }

    @objc private func toggleNotifications(_ sender: NSButton) {
        settings.notificationsEnabled = sender.state == .on
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard choices.indices.contains(idx) else { return }
        settings.reminderInterval = choices[idx].seconds
    }

    @objc private func toggleShowCurrentWindow(_ sender: NSButton) {
        settings.showCurrentWindow = sender.state == .on
    }

    @objc private func toggleShowLifetime(_ sender: NSButton) {
        settings.showLifetimeUsage = sender.state == .on
    }

    // MARK: - Hook 配置

    private func configureHookJSONEditor() {
        // NSScrollView + NSTextView 的标准多行编辑器组合。
        hookJSONScrollView.hasVerticalScroller = true
        hookJSONScrollView.hasHorizontalScroller = false
        hookJSONScrollView.borderType = .lineBorder
        hookJSONScrollView.autohidesScrollers = false

        hookJSONTextView.isEditable = true
        hookJSONTextView.isSelectable = true
        hookJSONTextView.isRichText = false
        hookJSONTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hookJSONTextView.textContainerInset = NSSize(width: 6, height: 6)
        hookJSONTextView.allowsUndo = true
        hookJSONTextView.isAutomaticQuoteSubstitutionEnabled = false
        hookJSONTextView.isAutomaticDashSubstitutionEnabled = false
        hookJSONTextView.isAutomaticTextReplacementEnabled = false
        hookJSONTextView.isAutomaticSpellingCorrectionEnabled = false
        hookJSONTextView.isVerticallyResizable = true
        hookJSONTextView.isHorizontallyResizable = false
        hookJSONTextView.autoresizingMask = [.width]
        hookJSONTextView.minSize = NSSize(width: 0, height: 0)
        hookJSONTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        hookJSONTextView.textContainer?.widthTracksTextView = true
        hookJSONScrollView.documentView = hookJSONTextView
    }

    /// 打开设置面板时读一次 settings.json,把现有安装填进 UI;没安装就显示
    /// app 内置默认值。读失败(JSON 损坏)在状态 label 显示错误,字段填默认。
    private func loadHookConfig() {
        let installed: HookInstaller.Configuration?
        do {
            installed = try HookInstaller.currentInstallation()
        } catch {
            populateEditor(with: .default)
            setStatus("无法解析 ~/.claude/settings.json:\(error.localizedDescription)", kind: .error)
            return
        }
        if let installed {
            populateEditor(with: installed)
            setStatus("已安装", kind: .success)
        } else {
            populateEditor(with: .default)
            setStatus("未安装。点「应用」即注册到 ~/.claude/settings.json。", kind: .info)
        }
    }

    private func populateEditor(with config: HookInstaller.Configuration) {
        hookJSONTextView.string = config.prettyJSON()
    }

    @objc private func applyHookConfig(_ sender: NSButton) {
        let raw = hookJSONTextView.string
        let config: HookInstaller.Configuration
        do {
            config = try HookInstaller.Configuration.parse(jsonString: raw)
        } catch let HookInstaller.InstallError.parseFailed(msg) {
            setStatus("JSON 解析失败:\(msg)", kind: .error); return
        } catch let HookInstaller.InstallError.unexpectedSchema(msg) {
            setStatus("结构不对:\(msg)", kind: .error); return
        } catch {
            setStatus("解析失败:\(error.localizedDescription)", kind: .error); return
        }
        do {
            try HookInstaller.install(config)
            setStatus("已应用到 ~/.claude/settings.json(原始已备份为 settings.json.bak)", kind: .success)
        } catch {
            setStatus("写入失败:\(error.localizedDescription)", kind: .error)
        }
    }

    @objc private func resetHookConfig(_ sender: NSButton) {
        // 仅恢复 UI 字段为内置默认。**不**直接写 settings.json — 用户还要再点
        // 「应用」才落地,符合"无意点击不破坏文件"原则。
        populateEditor(with: .default)
        setStatus("已恢复默认。点「应用」写入。", kind: .info)
    }

    private enum StatusKind { case info, success, error }
    private func setStatus(_ text: String, kind: StatusKind) {
        hookStatusLabel.stringValue = text
        switch kind {
        case .info: hookStatusLabel.textColor = .secondaryLabelColor
        case .success: hookStatusLabel.textColor = .systemGreen
        case .error: hookStatusLabel.textColor = .systemRed
        }
    }
}

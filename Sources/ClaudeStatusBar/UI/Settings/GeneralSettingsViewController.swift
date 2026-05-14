import AppKit
import Combine

public final class GeneralSettingsViewController: NSViewController {
    private let settings: SettingsStore
    private let loginItem: LoginItemController
    private var cancellables = Set<AnyCancellable>()

    private let loginItemCheckbox = NSButton(checkboxWithTitle: "开机自启", target: nil, action: nil)
    private let notificationsCheckbox = NSButton(checkboxWithTitle: "启用等待通知", target: nil, action: nil)
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)

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

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        preferredContentSize = NSSize(width: 380, height: 180)

        sync()
        observe()
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
}

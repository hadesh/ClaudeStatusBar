import Cocoa
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let store = SessionStore()
    private let usageTracker = UsageTracker()
    private lazy var watcher = SessionWatcher(store: store)
    private let notifier = WaitingNotifier()
    private var detector = WaitingTransitionDetector()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                for s in self.detector.detect(in: sessions) {
                    self.notifier.notify(session: s)
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(store.$sessions, usageTracker.$usage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions, usage in
                guard let self else { return }
                self.refreshIcon()
                self.rebuildMenu(with: sessions, usage: usage)
            }
            .store(in: &cancellables)

        watcher.start()
        usageTracker.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        usageTracker.stop()
    }

    private func refreshIcon() {
        statusItem?.button?.image = StatusIcon.image(for: store.aggregateStatus)
    }

    private func rebuildMenu(with sessions: [Session], usage: DailyUsage) {
        let menu = NSMenu()

        let header = NSMenuItem(
            title: "Claude Code · \(sessions.count) 个会话",
            action: nil, keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if sessions.isEmpty {
            let empty = NSMenuItem(title: "(暂无会话)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for s in sessions.sorted(by: { $0.pid < $1.pid }) {
                menu.addItem(makeSessionItem(s))
                if let detail = makeSessionDetailItem(s) {
                    menu.addItem(detail)
                }
            }
        }

        menu.addItem(.separator())
        appendUsageItems(to: menu, usage: usage)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem?.menu = menu
    }

    private func appendUsageItems(to menu: NSMenu, usage: DailyUsage) {
        let today = UsageTracker.todayString()
        let label = usage.date == today ? "今日" : "最近 (\(usage.date))"
        let title = "\(label) · \(usage.messageCount) 消息 · \(formatTokens(usage.totalTokens)) tokens"
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if usage.totalCostUSD > 0 {
            let cost = NSMenuItem(
                title: String(format: "  累计费用 $%.2f", usage.totalCostUSD),
                action: nil, keyEquivalent: ""
            )
            cost.isEnabled = false
            menu.addItem(cost)
        }

        for (model, tokens) in usage.tokensByModel.sorted(by: { $0.value > $1.value }) {
            let item = NSMenuItem(
                title: "  \(model): \(formatTokens(tokens))",
                action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func makeSessionItem(_ s: Session) -> NSMenuItem {
        let badge: String
        switch s.status {
        case .idle: badge = "◌"
        case .busy: badge = "●"
        case .waiting: badge = "⚠"
        }
        let name = (s.cwd as NSString).lastPathComponent
        let suffix = s.status == .waiting ? " — \(s.waitingFor ?? "")" : ""
        let title = "\(badge) \(name) · pid \(s.pid)\(suffix)"

        let item = NSMenuItem(title: title, action: #selector(openCwd(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s.cwd
        item.toolTip = s.cwd
        return item
    }

    private func makeSessionDetailItem(_ s: Session) -> NSMenuItem? {
        guard let d = SessionDetailsReader.read(cwd: s.cwd, sessionId: s.sessionId) else {
            return nil
        }
        let pct = Int((d.usageRatio * 100).rounded())
        let title = "\(d.model) · \(pct)% (\(formatTokens(d.contextTokens))/\(formatTokens(d.contextWindow)))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        return item
    }

    @objc private func openCwd(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

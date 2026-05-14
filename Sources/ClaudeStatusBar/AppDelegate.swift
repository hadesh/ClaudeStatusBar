import Cocoa
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let store = SessionStore()
    private let usageTracker = UsageTracker()
    private lazy var watcher = SessionWatcher(store: store)
    private let notifier = WaitingNotifier()
    private var detector = WaitingTransitionDetector()
    private var reminderTracker = WaitingReminderTracker()
    private var reminderTimer: DispatchSourceTimer?
    private let loginItem = LoginItemController()
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

        Publishers.CombineLatest3(store.$sessions, usageTracker.$lifetimeByModel, usageTracker.$currentWindow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions, lifetime, window in
                guard let self else { return }
                self.refreshIcon()
                self.rebuildMenu(with: sessions, lifetime: lifetime, window: window)
            }
            .store(in: &cancellables)

        watcher.start()
        usageTracker.start()

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 5.0, repeating: 5.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for s in self.reminderTracker.tick(sessions: self.store.sessions, now: Date()) {
                self.notifier.notify(session: s)
            }
        }
        t.resume()
        reminderTimer = t
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        usageTracker.stop()
        reminderTimer?.cancel()
        reminderTimer = nil
    }

    private func refreshIcon() {
        statusItem?.button?.image = StatusIcon.image(for: store.aggregateStatus)
    }

    private func rebuildMenu(with sessions: [Session], lifetime: [ModelLifetimeUsage], window: RollingWindow?) {
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
        appendCurrentWindowItems(to: menu, window: window)
        menu.addItem(.separator())
        appendLifetimeItems(to: menu, lifetime: lifetime)
        if LoginItemController.isAvailable {
            let item = NSMenuItem(
                title: "开机自启",
                action: #selector(toggleLoginItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = loginItem.isEnabled ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem?.menu = menu
    }

    private func appendLifetimeItems(to menu: NSMenu, lifetime: [ModelLifetimeUsage]) {
        let header = NSMenuItem(title: "总用量 (按模型)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let totalCombined = lifetime.reduce(0) { $0 + $1.combined }
        guard totalCombined > 0 else {
            let empty = NSMenuItem(title: "  (无数据)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for u in lifetime {
            let pct = Double(u.combined) / Double(totalCombined) * 100
            let pctStr = String(format: "%.1f%%", pct)
            let title = "\(u.model)  \(pctStr)  In \(formatTokens(u.inputTokens)) · Out \(formatTokens(u.outputTokens))"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            menu.addItem(item)
        }

        let totalCost = lifetime.reduce(0.0) { $0 + $1.costUSD }
        if totalCost > 0 {
            let cost = NSMenuItem(
                title: String(format: "累计费用 $%.2f", totalCost),
                action: nil, keyEquivalent: ""
            )
            cost.isEnabled = false
            cost.indentationLevel = 1
            menu.addItem(cost)
        }
    }

    private func appendCurrentWindowItems(to menu: NSMenu, window: RollingWindow?) {
        let header = NSMenuItem(title: "本 5 小时", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        guard let window else {
            let empty = NSMenuItem(title: "  (无活动)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let usage = NSMenuItem(
            title: "用量 \(formatTokens(window.totalTokens))  In \(formatTokens(window.inputTokens)) · Out \(formatTokens(window.outputTokens))",
            action: nil, keyEquivalent: ""
        )
        usage.isEnabled = false
        usage.indentationLevel = 1
        menu.addItem(usage)

        let remaining = window.remaining(now: Date())
        let reset = NSMenuItem(
            title: "重置 \(formatRemaining(remaining)) 后",
            action: nil, keyEquivalent: ""
        )
        reset.isEnabled = false
        reset.indentationLevel = 1
        menu.addItem(reset)
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func makeSessionItem(_ s: Session) -> NSMenuItem {
        let badge: String
        switch s.status {
        case .idle: badge = "○"
        case .busy: badge = "●"
        case .waiting: badge = "⚠"
        }
        let name = (s.cwd as NSString).lastPathComponent
        let suffix = s.status == .waiting ? " — \(s.waitingFor ?? "")" : ""
        let title = "\(badge) \(name) · pid \(s.pid)\(suffix)"

        let item = NSMenuItem(title: title, action: #selector(revealSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s
        item.toolTip = "\(s.cwd)\n按住 Option 点击在 Finder 中打开"
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

    @objc private func revealSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        if optionHeld {
            openCwdInFinder(session.cwd)
            return
        }
        guard let app = findOwningApp(of: session.pid) else {
            notifyTerminalNotFound()
            return
        }
        app.activate(options: [.activateAllWindows])
    }

    private func findOwningApp(of sessionPid: Int) -> NSRunningApplication? {
        let resolved = TerminalNavigator.findGuiAncestor(
            startingFrom: sessionPid,
            processInfo: ProcessTree.info(pid:),
            isGuiApp: { NSRunningApplication(processIdentifier: pid_t($0)) != nil }
        )
        return resolved.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
    }

    private func openCwdInFinder(_ cwd: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    private func notifyTerminalNotFound() {
        NSSound.beep()
        showSystemNotification(
            title: "找不到对应终端",
            body: "按住 Option 点击可在 Finder 中打开 cwd"
        )
    }

    private func showSystemNotification(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            try loginItem.setEnabled(!loginItem.isEnabled)
        } catch {
            NSLog("Toggle login item failed: \(error)")
        }
        rebuildMenu(with: store.sessions, lifetime: usageTracker.lifetimeByModel, window: usageTracker.currentWindow)
    }
}

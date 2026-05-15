import Cocoa
import Combine
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    /// Ctrl+Shift+C toggle 状态栏菜单。一直注册,跟 PermissionPromptPanelManager
    /// 的 Y/N(只在浮窗可见时注册)用同 modifier 不同字母,无冲突。
    private var toggleMenuHotkey: GlobalHotkey?
    /// 通过 NSMenuDelegate 维护;`performClick` 后系统弹菜单 → menuWillOpen 翻 true。
    private var menuIsShowing = false
    private let store = SessionStore()
    private let usageTracker = UsageTracker()
    private lazy var watcher = SessionWatcher(store: store)
    private let notifier = WaitingNotifier()
    private let dispatcher = NotificationDispatcher()
    private let permissionStore = PermissionPromptStore()
    private lazy var permissionPanels = PermissionPromptPanelManager(store: permissionStore)
    private lazy var permissionListener = PermissionPromptListener(
        store: permissionStore,
        socketPath: AppDelegate.permissionSocketPath()
    )
    private var detector = WaitingTransitionDetector()
    private var completionDetector = TaskCompletionDetector()
    private let settings: SettingsStore
    private let loginItem = LoginItemController()
    private var reminderTracker: WaitingReminderTracker
    private var reminderTimer: DispatchSourceTimer?
    private var lastReminderInterval: TimeInterval?
    private var cancellables = Set<AnyCancellable>()
    private lazy var settingsWindowController = SettingsWindowController(
        settings: settings, loginItem: loginItem
    )

    override init() {
        let s = SettingsStore()
        self.settings = s
        self.reminderTracker = Self.makeReminderTracker(interval: s.reminderInterval)
        self.lastReminderInterval = s.reminderInterval
        super.init()
    }

    private static func makeReminderTracker(interval: TimeInterval?) -> WaitingReminderTracker {
        guard let interval else {
            return WaitingReminderTracker(config: .init(initialDelay: 30, interval: 30, maxReminders: 0))
        }
        return WaitingReminderTracker(
            config: .init(initialDelay: interval, interval: interval, maxReminders: 3)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        dispatcher.onWaitingClick = { [weak self] pid, cwd in
            self?.handleNotificationClick(pid: pid, cwd: cwd)
        }
        dispatcher.install()

        // Touch panelManager so its store subscriptions are wired before the
        // listener starts accepting requests.
        _ = permissionPanels

        do {
            try permissionListener.start()
        } catch {
            NSLog("PermissionPromptListener failed to start: \(error)")
        }

        // AskUserQuestion 不弹浮窗 —— 它是结构化的多选题,只能在终端答。
        // 这里发一条系统通知提醒用户,然后立刻 abandon 让 hook exit,CLI 端
        // 终端 prompt 接管。PanelManager 那边已经 toolName-skip 这种请求。
        permissionStore.incoming
            .receive(on: DispatchQueue.main)
            .filter { PermissionPromptPanelManager.toolsRoutedAwayFromPanel.contains($0.toolName) }
            .sink { [weak self] req in
                guard let self else { return }
                self.routeAskUserQuestionToTerminal(req)
            }
            .store(in: &cancellables)

        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                let transitioned = self.detector.detect(in: sessions)
                let completed = self.completionDetector.detect(in: sessions)
                guard self.settings.notificationsEnabled else { return }
                // 浮窗已经在该会话上承担了"等待响应"的告知,系统通知就别再叠一层。
                let withPanel = self.permissionStore.pendingSessionIds()
                for s in transitioned where !withPanel.contains(s.sessionId) {
                    self.notifier.notify(session: s)
                }
                for s in completed { self.notifier.notifyCompletion(session: s) }
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // 颜色变化:刷新菜单栏图标。
                self.refreshIcon()
                // 间隔变化:重建 reminder tracker(状态清零是预期行为)。
                if self.settings.reminderInterval != self.lastReminderInterval {
                    self.reminderTracker = Self.makeReminderTracker(interval: self.settings.reminderInterval)
                    self.lastReminderInterval = self.settings.reminderInterval
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
            let due = self.reminderTracker.tick(sessions: self.store.sessions, now: Date())
            guard self.settings.notificationsEnabled else { return }
            let withPanel = self.permissionStore.pendingSessionIds()
            for s in due where !withPanel.contains(s.sessionId) {
                self.notifier.notify(session: s)
            }
        }
        t.resume()
        reminderTimer = t

        toggleMenuHotkey = GlobalHotkey(
            keyCode: kVK_ANSI_C,
            modifiers: controlKey | shiftKey
        ) { [weak self] in
            self?.toggleStatusMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        usageTracker.stop()
        permissionListener.stop()
        reminderTimer?.cancel()
        reminderTimer = nil
    }

    /// `~/Library/Application Support/ClaudeStatusBar/prompt.sock`. Created at
    /// 0700 on first call. Helper subprocesses dial this path.
    static func permissionSocketPath() -> String {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ClaudeStatusBar", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(
            at: supportDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return supportDir.appendingPathComponent("prompt.sock").path
    }

    /// Ctrl+Shift+C 触发。第一次按弹菜单(performClick 等同鼠标点🐙图标),
    /// 第二次按关菜单(cancelTracking 是 NSMenu 程序化关闭 API)。menuIsShowing
    /// 由 NSMenuDelegate 维护,所以两次按下之间用户用鼠标关掉菜单也不会卡住。
    private func toggleStatusMenu() {
        if menuIsShowing {
            statusItem?.menu?.cancelTracking()
        } else {
            statusItem?.button?.performClick(nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsShowing = true }
    func menuDidClose(_ menu: NSMenu) { menuIsShowing = false }

    private func refreshIcon() {
        statusItem?.button?.image = StatusIcon.image(
            for: store.aggregateStatus,
            working: settings.workingColor,
            attention: settings.attentionColor
        )
    }

    private func rebuildMenu(with sessions: [Session], lifetime: [ModelLifetimeUsage], window: RollingWindow?) {
        let menu = NSMenu()
        // 每次重建都要重新挂 delegate ── menuIsShowing 状态机依赖它。
        menu.delegate = self

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
        menu.addItem(.separator())
        let prefsItem = NSMenuItem(
            title: "偏好设置...",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem?.menu = menu
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        settingsWindowController.showWindow(sender)
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
        notifier.notify(
            title: "找不到对应终端",
            body: "按住 Option 点击可在 Finder 中打开 cwd"
        )
    }

    /// AskUserQuestion 路由:发系统通知 + 立刻 abandon。abandon 让 listener 关
    /// 掉 helper 的 socket fd,helper 读到 EOF exit(0) 不写 stdout,CLI 那边
    /// race 走终端 prompt(askUserQuestion 的多选题就在终端弹出来等用户答)。
    private func routeAskUserQuestionToTerminal(_ req: PermissionPromptRequest) {
        let project = req.cwd.map { ($0 as NSString).lastPathComponent } ?? "(unknown)"
        // pid 通过 sessionId 反查;反查不到时 click 路径会 fall back 到 cwd。
        let pid = store.sessions.first(where: { $0.sessionId == req.sessionId })?.pid ?? 0
        var userInfo: [String: Any] = ["pid": pid]
        if let cwd = req.cwd { userInfo["cwd"] = cwd }
        if settings.notificationsEnabled {
            notifier.notify(
                title: "Claude Code 需要你回答",
                body: "\(project) · 请回到终端选择",
                userInfo: userInfo
            )
        }
        permissionStore.abandon(id: req.id)
    }

    private func handleNotificationClick(pid: Int, cwd: String?) {
        if let app = findOwningApp(of: pid) {
            app.activate(options: [.activateAllWindows])
            return
        }
        if let cwd {
            openCwdInFinder(cwd)
        } else {
            NSSound.beep()
        }
    }
}

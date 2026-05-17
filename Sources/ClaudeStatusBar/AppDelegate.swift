import Cocoa
import Combine
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var iconAnimator: StatusIconAnimator?
    /// Ctrl+Shift+C toggle 状态栏菜单。一直注册,跟 PermissionPromptPanelManager
    /// 的 Y/N(只在浮窗可见时注册)用同 modifier 不同字母,无冲突。
    private var toggleMenuHotkey: GlobalHotkey?
    /// 通过 NSMenuDelegate 维护;`performClick` 后系统弹菜单 → menuWillOpen 翻 true。
    private var menuIsShowing = false
    private let store = SessionStore()
    private let usageTracker = UsageTracker()
    private let contextStore = SessionContextStore()
    private lazy var watcher = SessionWatcher(store: store)
    private let notifier = WaitingNotifier()
    private let dispatcher = NotificationDispatcher()
    private let permissionStore = PermissionPromptStore()
    private lazy var permissionPanels = PermissionPromptPanelManager(store: permissionStore)
    private lazy var askUserQuestionPanels = AskUserQuestionPanelManager(
        store: permissionStore,
        navigator: AppDelegateTerminalActivator(delegate: self)
    )
    private lazy var permissionListener = PermissionPromptListener(
        store: permissionStore,
        socketPath: AppDelegate.permissionSocketPath()
    )
    private var detector = WaitingTransitionDetector()
    private var completionDetector = TaskCompletionDetector()
    /// Bridge for "用户在终端答完 prompt → 关掉所有该 sessionId 的浮窗"。
    /// hook helper 永远收不到 race-loser 信号(CLI 不杀它,stdin 已关),所以
    /// 用 session.status 离开 waiting 当替代触发。
    private var sessionExitDetector = PermissionPromptSessionExitDetector()
    private let settings: SettingsStore
    private let loginItem = LoginItemController()
    private var reminderTracker: WaitingReminderTracker
    private var reminderTimer: DispatchSourceTimer?
    private var lastReminderInterval: TimeInterval?
    private var cancellables = Set<AnyCancellable>()
    /// 子菜单条目的相对时间格式器: "5 分钟前" / "2 小时前" / "昨天" / "3 天前" 等.
    /// rebuildMenu 每次都会调用 makeRecentResumeItem, 复用同一个 formatter 避免反复创建.
    private lazy var relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()
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
        iconAnimator = StatusIconAnimator(button: statusItem?.button)

        dispatcher.onWaitingClick = { [weak self] pid, cwd in
            self?.handleNotificationClick(pid: pid, cwd: cwd)
        }
        dispatcher.install()

        // Touch panelManager so its store subscriptions are wired before the
        // listener starts accepting requests.
        _ = permissionPanels
        _ = askUserQuestionPanels  // 触发 lazy 实例化,把 sink 接上

        do {
            try permissionListener.start()
        } catch {
            NSLog("PermissionPromptListener failed to start: \(error)")
        }

        // 浮窗状态变化(新请求 / 用户答复 / 终端 race) 都影响 attentionCount,
        // 跟着刷新一下图标角标。
        Publishers.Merge(
            permissionStore.incoming.map { _ in () },
            permissionStore.resolved.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refreshIcon() }
        .store(in: &cancellables)

        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                self.contextStore.updateSessions(sessions)
                let transitioned = self.detector.detect(in: sessions)
                let completed = self.completionDetector.detect(in: sessions)
                // sessionId 离开 waiting → 关掉对应浮窗。先于 notification 处理,
                // 这样 abandonAll 触发的 resolved 能在同一 runloop 把面板移除。
                for sid in self.sessionExitDetector.detect(in: sessions) {
                    self.permissionStore.abandonAll(sessionId: sid)
                }
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
                // 显示开关变化时菜单结构会变,主动重建一次(若数据未变,
                // CombineLatest3 sink 不会重新触发)。
                self.rebuildMenu(
                    with: self.store.sessions,
                    lifetime: self.usageTracker.lifetimeByModel,
                    window: self.usageTracker.currentWindow
                )
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
        contextStore.start()

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
        contextStore.stop()
        permissionListener.stop()
        reminderTimer?.cancel()
        reminderTimer = nil
        iconAnimator?.stop()
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

    /// 唯一可靠的「哪一项被选中」信号 —— 鼠标 hover 与键盘 ↑↓ 都会触发。
    /// SessionRowView 的 NSTrackingArea 在菜单 tracking 模式下不被派发,
    /// 所以靠这条 delegate 回调推送高亮态。
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            guard let row = menuItem.view as? SessionRowView else { continue }
            row.setHighlighted(menuItem === item)
        }
    }

    private func refreshIcon() {
        iconAnimator?.update(
            status: store.aggregateStatus,
            workingColor: settings.workingColor,
            attentionColor: settings.attentionColor,
            badgeCount: attentionCount()
        )
    }

    /// 「需要你」事件的 sessionId 集合并 —— waiting 状态的会话和 permission 浮窗
    /// 经常对应同一个 session,简单加法会双计。permission entry 上的 sessionId
    /// 理论可空但实际 CLI 总是带,本期不做空补偿(少计 1 比双计明显)。
    private func attentionCount() -> Int {
        let waitingIds = Set(
            store.sessions.filter { $0.status == .waiting }.map { $0.sessionId }
        )
        return waitingIds.union(permissionStore.pendingSessionIds()).count
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
                // fresh session(还没产生 user prompt)挂「恢复上次会话」子菜单;
                // 否则挂模型/上下文 detail 行. 两条路径互斥.
                if contextStore.contextByPid[s.pid]?.recentPrompt == nil {
                    if let resume = makeRecentResumeItem(for: s) {
                        menu.addItem(resume)
                    }
                } else if let detail = makeSessionDetailItem(s) {
                    menu.addItem(detail)
                }
            }
        }

        menu.addItem(.separator())
        if settings.showCurrentWindow {
            appendCurrentWindowItems(to: menu, window: window)
            menu.addItem(.separator())
        }
        if settings.showLifetimeUsage {
            appendLifetimeItems(to: menu, lifetime: lifetime)
            menu.addItem(.separator())
        }
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
        let item = NSMenuItem()
        item.toolTip = "\(s.cwd)\n按住 Option 点击在 Finder 中打开"

        let view = SessionRowView(
            session: s,
            secondary: secondaryLine(for: s),
            onTerminate: { [weak self] pid in
                ProcessTerminator.sendInterrupt(pid: pid)
                self?.statusItem?.menu?.cancelTracking()
            },
            onClick: { [weak self] in
                self?.revealSession(forPid: s.pid)
            }
        )
        item.view = view
        return item
    }

    /// 副行内容,按 status 切换:
    /// - waiting: ⏳ {waitingFor},fallback 到 prompt
    /// - working: ▸ {tool} 优先,fallback 到 prompt
    /// - idle/busy 非工具调用: » {recentPrompt}
    /// 全空时返回 nil(主行单独显示)。
    private func secondaryLine(for s: Session) -> String? {
        let ctx = contextStore.contextByPid[s.pid]
        switch s.status {
        case .waiting:
            if let w = s.waitingFor, !w.isEmpty { return "⏳ \(w)" }
            if let p = ctx?.recentPrompt { return "⏳ \(p)" }
            return nil
        case .busy:
            if let t = ctx?.lastTool { return "▸ \(t)" }
            if let p = ctx?.recentPrompt { return "» \(p)" }
            return nil
        case .idle:
            if let p = ctx?.recentPrompt { return "» \(p)" }
            return nil
        }
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

    /// fresh session(SessionContextStore 拿不到 recentPrompt)行下方的「恢复上次会话 ▸」
    /// 子菜单. 同 cwd 下没有可恢复的历史时返回 nil(不挂任何条目, 视觉上跟没这个功能一样).
    private func makeRecentResumeItem(for s: Session) -> NSMenuItem? {
        let recents = RecentConversationsReader.read(
            cwd: s.cwd, excluding: s.sessionId
        )
        guard !recents.isEmpty else { return nil }

        let parent = NSMenuItem(title: "恢复上次会话", action: nil, keyEquivalent: "")
        parent.indentationLevel = 1
        let submenu = NSMenu()
        for r in recents {
            let title = "\(r.firstPrompt)  ·  \(formatRelative(r.modifiedAt))"
            let it = NSMenuItem(
                title: title,
                action: #selector(copyResumeCommand(_:)),
                keyEquivalent: ""
            )
            it.target = self
            it.toolTip = "claude --resume \(r.sessionId)"
            it.representedObject = r.sessionId
            submenu.addItem(it)
        }
        parent.submenu = submenu
        return parent
    }

    private func formatRelative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// SessionRowView 主行点击入口。沿用旧 revealSession 的全部语义:
    /// Option 检测仍走 NSApp.currentEvent,与 sender 类型无关。
    private func revealSession(forPid pid: Int) {
        guard let session = store.sessions.first(where: { $0.pid == pid }) else { return }
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

    /// AskUserQuestion 浮窗「跳回终端」按钮触发。复用现有
    /// findOwningApp / openCwdInFinder 路径。sessionId → pid 反查走
    /// SessionStore 现有数据。
    func activateTerminal(sessionId: String?, cwd: String?) {
        if let sid = sessionId,
           let pid = store.sessions.first(where: { $0.sessionId == sid })?.pid,
           let app = findOwningApp(of: pid)
        {
            app.activate(options: [.activateAllWindows])
            return
        }
        if let cwd { openCwdInFinder(cwd) }
        else { NSSound.beep() }
    }

    /// 「恢复上次会话」子菜单的 action 入口.
    /// representedObject 是历史 sessionId, 拼成 `claude --resume <id>` 写剪贴板.
    /// 反馈走 WaitingNotifier.notify(title:body:) 通用通道, 不过 settings 网关
    /// (用户主动操作的反馈, 不是被动打扰).
    @objc private func copyResumeCommand(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        let cmd = "claude --resume \(sid)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        notifier.notify(title: "已复制 resume 命令", body: cmd)
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

/// 把 AppDelegate 已经在用的「pid → NSRunningApplication / cwd → Finder」
/// 路径暴露成 TerminalActivating。manager 不直接持 NSApp,方便单测。
private final class AppDelegateTerminalActivator: TerminalActivating {
    weak var delegate: AppDelegate?
    init(delegate: AppDelegate) { self.delegate = delegate }
    func activate(forSessionId sessionId: String?, cwd: String?) {
        delegate?.activateTerminal(sessionId: sessionId, cwd: cwd)
    }
}

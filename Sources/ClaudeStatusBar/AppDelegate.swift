import Cocoa
import Combine

/// 整个 app 的 wiring 层。它本身不写业务逻辑 —— 只负责:
///   1. 把 store / tracker / detector / panel manager 实例化出来并接到一起
///   2. 装 4 条 Combine 订阅,把数据/事件流串成现状架构图描述的拓扑
///   3. 起 5s reminder timer
///   4. 持有两个 NSMenuItem.action 必须的 @objc selector(openSettings /
///      copyResumeCommand) —— NSMenuItem 不接 closure-action,必须 NSObject。
///
/// 业务行为分散在:
/// - `MenuController` + `MenuBuilder` —— 状态栏图标 / 菜单 / 热键
/// - `NotificationOrchestrator` —— detector + reminder + 通知派发
/// - `TerminalActivator` —— sessionId/pid → 终端 app / Finder
/// - `PermissionPromptStore` 系列 —— 权限浮窗 / hook helper
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - 长生命周期组件(供其他子系统读)

    private let store = SessionStore()
    private let usageTracker = UsageTracker()
    private let contextStore = SessionContextStore()
    private let detailsStore = SessionDetailsStore()
    private lazy var watcher = SessionWatcher(store: store)

    private let notifier = WaitingNotifier()
    private let dispatcher = NotificationDispatcher()
    private let permissionStore = PermissionPromptStore()

    private let settings: SettingsStore
    private let loginItem = LoginItemController()

    // MARK: - 协调层(本次拆分新增)

    private lazy var terminalActivator = TerminalActivator(
        store: store, notifier: notifier
    )
    private lazy var orchestrator = NotificationOrchestrator(
        notifier: notifier,
        permissionGate: permissionStore,
        isNotificationsEnabled: { [unowned self] in self.settings.notificationsEnabled },
        reminderInterval: settings.reminderInterval
    )
    private lazy var menuController = MenuController(
        store: store,
        permissionStore: permissionStore,
        usageTracker: usageTracker,
        contextStore: contextStore,
        detailsStore: detailsStore,
        settings: settings,
        terminalActivator: terminalActivator,
        menuTarget: self,
        openSettingsSelector: #selector(openSettings(_:)),
        copyResumeSelector: #selector(copyResumeCommand(_:))
    )

    // MARK: - 浮窗管理 / 权限 socket listener

    /// 两类浮窗共享同一条「右上向下」的垂直队列。FloatingPanelStack 只管几何
    /// 排版,内容/语义由各自的 manager 持有。
    private let panelStack = FloatingPanelStack()
    private lazy var permissionPanels = PermissionPromptPanelManager(
        store: permissionStore, stack: panelStack
    )
    private lazy var askUserQuestionPanels = AskUserQuestionPanelManager(
        store: permissionStore, stack: panelStack, navigator: terminalActivator
    )
    private lazy var permissionListener = PermissionPromptListener(
        store: permissionStore,
        socketPath: AppDelegate.permissionSocketPath()
    )

    // MARK: - 设置窗口

    private lazy var settingsWindowController = SettingsWindowController(
        settings: settings, loginItem: loginItem
    )

    // MARK: - Timer / 订阅状态

    private var reminderTimer: DispatchSourceTimer?
    private var lastReminderInterval: TimeInterval?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    override init() {
        let s = SettingsStore()
        self.settings = s
        self.lastReminderInterval = s.reminderInterval
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        dispatcher.onWaitingClick = { [weak self] pid, cwd in
            self?.terminalActivator.handleNotificationClick(pid: pid, cwd: cwd)
        }
        dispatcher.install()

        // Touch panel managers so their store subscriptions are wired before the
        // listener starts accepting requests.
        _ = permissionPanels
        _ = askUserQuestionPanels

        do {
            try permissionListener.start()
        } catch {
            NSLog("PermissionPromptListener failed to start: \(error)")
        }

        menuController.start()

        wireSubscriptions()

        watcher.start()
        usageTracker.start()
        contextStore.start()
        detailsStore.start()

        startReminderTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        usageTracker.stop()
        contextStore.stop()
        detailsStore.stop()
        permissionListener.stop()
        reminderTimer?.cancel()
        reminderTimer = nil
        menuController.stop()
    }

    // MARK: - Combine 订阅(5 条)

    private func wireSubscriptions() {
        // 1) 浮窗集合变化 → 刷新角标(不重建菜单,只动图标)。
        Publishers.Merge(
            permissionStore.incoming.map { _ in () },
            permissionStore.resolved.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.menuController.refreshIcon() }
        .store(in: &cancellables)

        // 2) sessions 变化 → 喂给 contextStore / detailsStore 增量扫描 + Orchestrator 跑 detector + 派发通知。
        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                self.contextStore.updateSessions(sessions)
                self.detailsStore.updateSessions(sessions)
                self.orchestrator.sessionsDidChange(sessions)
            }
            .store(in: &cancellables)

        // 3) settings 变化 → 颜色/显示开关都让 menuController 整刷一次;reminder
        //    间隔变化时显式重建 tracker(状态清零是预期行为)。
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.menuController.refresh()
                if self.settings.reminderInterval != self.lastReminderInterval {
                    self.orchestrator.rebuildReminderTracker(interval: self.settings.reminderInterval)
                    self.lastReminderInterval = self.settings.reminderInterval
                }
            }
            .store(in: &cancellables)

        // 4) 数据快照变化 → 重建菜单。CombineLatest3 等三条流首次都有值后才发,避
        //    免启动期闪烁。
        Publishers.CombineLatest3(
            store.$sessions,
            usageTracker.$lifetimeByModel,
            usageTracker.$currentWindow
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in self?.menuController.refresh() }
        .store(in: &cancellables)

        // 5) detailsByPid 变化 → 单独触发刷新。CombineLatest 装到一起会让 detailsByPid
        //    在没首次值时把整条流卡住,简单起见独立 sink;refresh() 内部读最新快照。
        detailsStore.$detailsByPid
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.menuController.refresh() }
            .store(in: &cancellables)
    }

    private func startReminderTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 5.0, repeating: 5.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.orchestrator.tickReminder(now: Date(), sessions: self.store.sessions)
        }
        t.resume()
        reminderTimer = t
    }

    // MARK: - NSMenuItem 必须的 @objc 入口

    @objc private func openSettings(_ sender: NSMenuItem) {
        settingsWindowController.showWindow(sender)
    }

    /// 「恢复上次会话」子菜单的 action 入口。representedObject 是历史 sessionId,
    /// 拼成 `claude --resume <id>` 写剪贴板。反馈走 WaitingNotifier 通用通道,
    /// 不过 settings 网关(用户主动操作的反馈,不是被动打扰)。
    @objc private func copyResumeCommand(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        let cmd = "claude --resume \(sid)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        notifier.notify(title: "已复制 resume 命令", body: cmd)
    }

    // MARK: - 杂项

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
}

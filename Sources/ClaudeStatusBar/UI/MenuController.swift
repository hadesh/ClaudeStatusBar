import Cocoa

/// 状态栏 status item 的 owner —— 装图标、装菜单、调度刷新。AppDelegate 把
/// 全部 store/tracker 引用注入进来,自己只负责把数据快照交给 MenuBuilder
/// 构造一份新的 NSMenu。
///
/// 之所以是 NSObject:
/// - `NSMenuDelegate` 协议要求 NSObject(menuWillOpen / menuDidClose /
///   willHighlight 三件套来自 AppKit Carbon 时代的 ObjC 协议)。
/// - 这些 delegate 回调维持 `menuIsShowing` 状态机,Ctrl+Shift+C toggle 热键
///   依赖它判断当前是 perform-click 弹菜单还是 cancelTracking 关菜单。
///
/// 跟 MenuBuilder 的关系:本类不构 menu —— `refresh()` 把数据快照打包成
/// `MenuBuilder.Snapshot` 交给 builder,得到新 NSMenu 后整体替换
/// `statusItem.menu`。MenuBuilder 是无状态纯静态;MenuController 持有所有跨刷
/// 新需要保留的可变状态(statusItem、iconAnimator、热键、menuIsShowing)。
public final class MenuController: NSObject, NSMenuDelegate {

    private let store: SessionStore
    private let permissionStore: PermissionPromptStore
    private let usageTracker: UsageTracker
    private let contextStore: SessionContextStore
    private let detailsStore: SessionDetailsStore
    private let settings: SettingsStore
    private let terminalActivator: TerminalActivator

    private weak var menuTarget: AnyObject?
    private let openSettingsSelector: Selector
    private let copyResumeSelector: Selector

    private var statusItem: NSStatusItem?
    private var iconAnimator: StatusIconAnimator?

    /// Ctrl+Shift+C toggle 状态栏菜单。一直注册,跟 PermissionPromptPanelManager
    /// 的 Y/N(只在浮窗可见时注册)用同 modifier 不同字母,无冲突。
    private var toggleMenuHotkey: GlobalHotkey?

    /// 通过 NSMenuDelegate 维护;`performClick` 后系统弹菜单 → menuWillOpen 翻 true。
    private var menuIsShowing = false

    /// 子菜单条目的相对时间格式器。每次 build 复用同一个 formatter,避免反复创建。
    private lazy var relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    /// `menuTarget` weak 持有 —— 实际是 AppDelegate,它生命周期跟 NSApp 同寿,
    /// 不会先于 MenuController 释放。weak 只是为了不参与引用计数把链路弄复杂。
    public init(
        store: SessionStore,
        permissionStore: PermissionPromptStore,
        usageTracker: UsageTracker,
        contextStore: SessionContextStore,
        detailsStore: SessionDetailsStore,
        settings: SettingsStore,
        terminalActivator: TerminalActivator,
        menuTarget: AnyObject,
        openSettingsSelector: Selector,
        copyResumeSelector: Selector
    ) {
        self.store = store
        self.permissionStore = permissionStore
        self.usageTracker = usageTracker
        self.contextStore = contextStore
        self.detailsStore = detailsStore
        self.settings = settings
        self.terminalActivator = terminalActivator
        self.menuTarget = menuTarget
        self.openSettingsSelector = openSettingsSelector
        self.copyResumeSelector = copyResumeSelector
        super.init()
    }

    // MARK: - 生命周期

    /// 装状态栏图标 + 注册 toggle 热键 + 第一次刷新菜单。AppDelegate 在
    /// `applicationDidFinishLaunching` 完成所有 store/tracker 启动后调用一次。
    public func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        iconAnimator = StatusIconAnimator(button: item.button)

        let combo = KeyboardShortcutCatalog.toggleMenu.combo
        toggleMenuHotkey = GlobalHotkey(
            keyCode: combo.carbonKeyCode,
            modifiers: combo.carbonModifiers
        ) { [weak self] in
            self?.toggleStatusMenu()
        }

        refresh()
    }

    public func stop() {
        iconAnimator?.stop()
        toggleMenuHotkey = nil
    }

    // MARK: - 刷新入口

    /// 重建菜单并刷新图标。store/usageTracker/contextStore 的 @Published 任意一条
    /// 触发都该走这里 —— 数据耦合度高,分别刷会产生短暂不一致(图标在新会话进
    /// waiting,但菜单还显示空)。
    public func refresh() {
        refreshIcon()
        let snapshot = MenuBuilder.Snapshot(
            sessions: store.sessions,
            lifetime: usageTracker.lifetimeByModel,
            window: usageTracker.currentWindow,
            contextByPid: contextStore.contextByPid,
            detailsByPid: detailsStore.detailsByPid,
            now: Date()
        )
        let menu = MenuBuilder.build(
            snapshot: snapshot,
            actions: makeActions(),
            settings: settings,
            relativeFormatter: relativeFormatter,
            menuDelegate: self
        )
        statusItem?.menu = menu
    }

    /// 仅刷图标 —— 给「权限浮窗集合变化、颜色变化」用。这两类事件不影响菜单
    /// 内容,跑一次完整 refresh() 是浪费。
    public func refreshIcon() {
        iconAnimator?.update(
            status: store.aggregateStatus,
            workingColor: settings.workingColor,
            attentionColor: settings.attentionColor,
            badgeCount: attentionCount()
        )
    }

    // MARK: - NSMenuDelegate

    public func menuWillOpen(_ menu: NSMenu) { menuIsShowing = true }
    public func menuDidClose(_ menu: NSMenu) { menuIsShowing = false }

    /// 唯一可靠的「哪一项被选中」信号 —— 鼠标 hover 与键盘 ↑↓ 都会触发。
    /// SessionRowView 的 NSTrackingArea 在菜单 tracking 模式下不被派发,
    /// 所以靠这条 delegate 回调推送高亮态。
    public func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            guard let row = menuItem.view as? SessionRowView else { continue }
            row.setHighlighted(menuItem === item)
        }
    }

    // MARK: - Private

    /// 「需要你」事件的 sessionId 集合并 —— waiting 状态的会话和 permission 浮窗
    /// 经常对应同一个 session,简单加法会双计。permission entry 上的 sessionId
    /// 理论可空但实际 CLI 总是带,本期不做空补偿(少计 1 比双计明显)。
    private func attentionCount() -> Int {
        let waitingIds = Set(
            store.sessions.filter { $0.status == .waiting }.map { $0.sessionId }
        )
        return waitingIds.union(permissionStore.pendingSessionIds()).count
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

    /// 每次 refresh() 都新建一份 actions —— closure capture 的 [weak self]
    /// 不会变,但语义上「这一份 actions 是这次菜单实例的回调」,生命周期跟
    /// 菜单同步反而清楚。每次构造极便宜。
    private func makeActions() -> MenuBuilder.Actions {
        MenuBuilder.Actions(
            onSessionTerminate: { [weak self] pid in
                ProcessTerminator.sendInterrupt(pid: pid)
                self?.statusItem?.menu?.cancelTracking()
            },
            onSessionClick: { [weak self] pid in
                self?.terminalActivator.revealSession(forPid: pid)
            },
            menuTarget: menuTarget,
            openSettingsSelector: openSettingsSelector,
            copyResumeSelector: copyResumeSelector
        )
    }
}

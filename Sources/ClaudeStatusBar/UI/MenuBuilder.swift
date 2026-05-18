import Cocoa

/// 把状态栏下拉菜单的整段构造逻辑收成纯静态函数。MenuController 每次刷新都
/// 喂一份 Snapshot 进来,得到一个全新的 NSMenu。
///
/// 「纯静态」是这一组类的共同约定(参见 `LiveUsageAggregator`、
/// `SessionDetailsReader` 等):构造器不持有状态、不订阅任何东西,因此可以在
/// 单测里直接断言 `menu.items.count` / 标题 / submenu 结构,不需要起 AppKit
/// runloop 也不需要起整个 AppDelegate。
///
/// 调用方约定:
/// - `actions.onSessionTerminate` / `onSessionClick` 由 MenuController 提供,
///   闭包内部负责真正的副作用(发 SIGINT、激活终端、关菜单等)。MenuBuilder
///   只把 pid 透传出去。
/// - `actions.menuTarget` / `openSettingsSelector` / `copyResumeSelector` 用于
///   `NSMenuItem.target/action` 派发 —— 这两个 item 的 action 必须走 NSObject
///   target/selector 模式(NSMenuItem 不支持 closure-action),所以必须由调用方
///   提供一个 NSObject(实际上是 AppDelegate)。target 是 weak 持有,菜单生命
///   周期短(每次 rebuild 都是新菜单),不存在循环引用。
public enum MenuBuilder {

    /// 构建菜单所需的全部数据切片。一份不可变快照 —— 调用方在主线程聚合好后
    /// 整体传进来。
    ///
    /// 注意:`contextByPid` / `detailsByPid` 都是缓存读出来的字典,MenuBuilder
    /// **不**会在构造期间触发任何 jsonl I/O,菜单重建路径完全不会卡主线程。
    /// 缓存由 `SessionContextStore` / `SessionDetailsStore` 在后台 30s 刷。
    public struct Snapshot {
        public let sessions: [Session]
        public let lifetime: [ModelLifetimeUsage]
        public let window: RollingWindow?
        public let contextByPid: [Int: SessionContext]
        public let detailsByPid: [Int: SessionDetails]
        public let now: Date

        public init(
            sessions: [Session],
            lifetime: [ModelLifetimeUsage],
            window: RollingWindow?,
            contextByPid: [Int: SessionContext],
            detailsByPid: [Int: SessionDetails],
            now: Date
        ) {
            self.sessions = sessions
            self.lifetime = lifetime
            self.window = window
            self.contextByPid = contextByPid
            self.detailsByPid = detailsByPid
            self.now = now
        }
    }

    /// 菜单上各种交互的注入点。closure 形态的回调走「数据出去」语义,selector
    /// 形态的回调走「NSMenuItem.action 派发」语义,二者并存是因为 NSMenuItem
    /// 不直接支持 closure。
    public struct Actions {
        public let onSessionTerminate: (Int) -> Void
        public let onSessionClick: (Int) -> Void
        public weak var menuTarget: AnyObject?
        public let openSettingsSelector: Selector
        public let copyResumeSelector: Selector

        public init(
            onSessionTerminate: @escaping (Int) -> Void,
            onSessionClick: @escaping (Int) -> Void,
            menuTarget: AnyObject?,
            openSettingsSelector: Selector,
            copyResumeSelector: Selector
        ) {
            self.onSessionTerminate = onSessionTerminate
            self.onSessionClick = onSessionClick
            self.menuTarget = menuTarget
            self.openSettingsSelector = openSettingsSelector
            self.copyResumeSelector = copyResumeSelector
        }
    }

    /// 构造菜单的入口。调用方每次想刷新都重新调一次 —— NSMenu 不可变形,只能
    /// 整体替换。`menuDelegate` 必须是同一个实例(MenuController),否则
    /// menuWillOpen / willHighlight 这些 delegate 状态机会断裂。
    public static func build(
        snapshot: Snapshot,
        actions: Actions,
        settings: SettingsStore,
        relativeFormatter: RelativeDateTimeFormatter,
        menuDelegate: NSMenuDelegate
    ) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = menuDelegate

        let header = NSMenuItem(
            title: "Claude Code · \(snapshot.sessions.count) 个会话",
            action: nil, keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if snapshot.sessions.isEmpty {
            let empty = NSMenuItem(title: "(暂无会话)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for s in snapshot.sessions.sorted(by: { $0.pid < $1.pid }) {
                menu.addItem(makeSessionItem(s, contextByPid: snapshot.contextByPid, actions: actions))
                // fresh session(还没产生 user prompt)挂「恢复上次会话」子菜单;
                // 否则挂模型/上下文 detail 行。两条路径互斥 —— 历史会话已经存在
                // 时不该再提示「恢复」,反过来 fresh session 没有 detail 可显示。
                if snapshot.contextByPid[s.pid]?.recentPrompt == nil {
                    if let resume = makeRecentResumeItem(
                        for: s,
                        actions: actions,
                        relativeFormatter: relativeFormatter,
                        now: snapshot.now
                    ) {
                        menu.addItem(resume)
                    }
                } else if let detail = makeSessionDetailItem(s, details: snapshot.detailsByPid[s.pid]) {
                    menu.addItem(detail)
                }
            }
        }

        menu.addItem(.separator())
        if settings.showCurrentWindow {
            appendCurrentWindowItems(to: menu, window: snapshot.window, now: snapshot.now)
            menu.addItem(.separator())
        }
        if settings.showLifetimeUsage {
            appendLifetimeItems(to: menu, lifetime: snapshot.lifetime)
            menu.addItem(.separator())
        }

        let prefsItem = NSMenuItem(
            title: "偏好设置...",
            action: actions.openSettingsSelector,
            keyEquivalent: ","
        )
        prefsItem.target = actions.menuTarget
        menu.addItem(prefsItem)
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    // MARK: - Session row 主行

    private static func makeSessionItem(
        _ s: Session,
        contextByPid: [Int: SessionContext],
        actions: Actions
    ) -> NSMenuItem {
        let item = NSMenuItem()
        item.toolTip = "\(s.cwd)\n按住 Option 点击在 Finder 中打开"

        let view = SessionRowView(
            session: s,
            secondary: secondaryLine(for: s, context: contextByPid[s.pid]),
            onTerminate: actions.onSessionTerminate,
            onClick: { actions.onSessionClick(s.pid) }
        )
        item.view = view
        return item
    }

    /// 副行内容,按 status 切换:
    /// - waiting: ⏳ {waitingFor},fallback 到 prompt
    /// - busy:    ▸ {tool} 优先,fallback 到 prompt
    /// - idle:    » {recentPrompt}
    /// 全空时返回 nil(SessionRowView 会按单行布局渲染)。
    private static func secondaryLine(for s: Session, context: SessionContext?) -> String? {
        switch s.status {
        case .waiting:
            if let w = s.waitingFor, !w.isEmpty { return "⏳ \(w)" }
            if let p = context?.recentPrompt { return "⏳ \(p)" }
            return nil
        case .busy:
            if let t = context?.lastTool { return "▸ \(t)" }
            if let p = context?.recentPrompt { return "» \(p)" }
            return nil
        case .idle:
            if let p = context?.recentPrompt { return "» \(p)" }
            return nil
        }
    }

    // MARK: - Session detail / 恢复子菜单(主行下面那条)

    /// 渲染单条 session 的「<model> · <pct>% (used/window)」detail 行。`details`
    /// 来自 `SessionDetailsStore.detailsByPid` —— `nil` 时直接不挂这条(跟改造前
    /// 调用 reader 拿到 nil 的语义一致),菜单不显示残缺信息。
    private static func makeSessionDetailItem(_ s: Session, details: SessionDetails?) -> NSMenuItem? {
        guard let d = details else { return nil }
        let pct = Int((d.usageRatio * 100).rounded())
        let title = "\(d.model) · \(pct)% (\(formatTokens(d.contextTokens))/\(formatTokens(d.contextWindow)))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        return item
    }

    /// fresh session(SessionContextStore 拿不到 recentPrompt)行下方的「恢复上次会话 ▸」
    /// 子菜单。同 cwd 下没有可恢复的历史时返回 nil(不挂任何条目,视觉上跟没这个功能一样)。
    /// 子菜单的每个 item action 走 selector,拼好的 `claude --resume <id>` 由
    /// menuTarget 实现的 copyResumeSelector 写剪贴板。
    private static func makeRecentResumeItem(
        for s: Session,
        actions: Actions,
        relativeFormatter: RelativeDateTimeFormatter,
        now: Date
    ) -> NSMenuItem? {
        let recents = RecentConversationsReader.read(
            cwd: s.cwd, excluding: s.sessionId
        )
        guard !recents.isEmpty else { return nil }

        let parent = NSMenuItem(title: "恢复上次会话", action: nil, keyEquivalent: "")
        parent.indentationLevel = 1
        let submenu = NSMenu()
        for r in recents {
            let title = "\(r.firstPrompt)  ·  \(formatRelative(r.modifiedAt, formatter: relativeFormatter, now: now))"
            let it = NSMenuItem(
                title: title,
                action: actions.copyResumeSelector,
                keyEquivalent: ""
            )
            it.target = actions.menuTarget
            it.toolTip = "claude --resume \(r.sessionId)"
            it.representedObject = r.sessionId
            submenu.addItem(it)
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - 累计用量

    private static func appendLifetimeItems(to menu: NSMenu, lifetime: [ModelLifetimeUsage]) {
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

    // MARK: - 5 小时窗口

    private static func appendCurrentWindowItems(to menu: NSMenu, window: RollingWindow?, now: Date) {
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

        let remaining = window.remaining(now: now)
        let reset = NSMenuItem(
            title: "重置 \(formatRemaining(remaining)) 后",
            action: nil, keyEquivalent: ""
        )
        reset.isEnabled = false
        reset.indentationLevel = 1
        menu.addItem(reset)
    }

    // MARK: - 文本格式化

    private static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private static func formatRelative(
        _ date: Date,
        formatter: RelativeDateTimeFormatter,
        now: Date
    ) -> String {
        formatter.localizedString(for: date, relativeTo: now)
    }
}

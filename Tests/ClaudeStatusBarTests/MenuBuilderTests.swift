import XCTest
import AppKit
@testable import ClaudeStatusBar

/// MenuBuilder 是纯静态构造器,fixture 准备成本低 —— 给一份 Snapshot + Actions
/// 就能断言完整的 NSMenu 结构。
///
/// 测试 cwd 一律指向 `/tmp/menu-builder-test-fixture-…` 这种不存在的路径,确
/// 保 SessionDetailsReader / RecentConversationsReader 都 fallback 到 nil,
/// 菜单结构不会被本机 ~/.claude/projects/ 里的真实数据污染。
final class MenuBuilderTests: XCTestCase {

    // MARK: - 基础 fixture

    private let cwd = "/tmp/menu-builder-test-fixture-does-not-exist"

    private func makeSession(pid: Int, status: SessionStatus, sessionId: String = "sid") -> Session {
        let json = #"""
        {"pid":\#(pid),"sessionId":"\#(sessionId)","cwd":"\#(cwd)","startedAt":0,"version":"2","kind":"interactive","entrypoint":"cli","status":"\#(status.rawValue)","updatedAt":0}
        """#.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    private func emptySnapshot(sessions: [Session] = []) -> MenuBuilder.Snapshot {
        MenuBuilder.Snapshot(
            sessions: sessions,
            lifetime: [],
            window: nil,
            contextByPid: [:],
            detailsByPid: [:],
            now: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeActions(target: AnyObject) -> MenuBuilder.Actions {
        MenuBuilder.Actions(
            onSessionTerminate: { _ in },
            onSessionClick: { _ in },
            menuTarget: target,
            openSettingsSelector: NSSelectorFromString("openSettingsTest:"),
            copyResumeSelector: NSSelectorFromString("copyResumeTest:")
        )
    }

    private func defaultSettings() -> SettingsStore {
        // 用一个 in-memory UserDefaults 隔离,避免 settings 在测试机上被持久化。
        let suite = UserDefaults(suiteName: "MenuBuilderTests-\(UUID().uuidString)")!
        return SettingsStore(defaults: suite)
    }

    private func formatter() -> RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }

    private final class StubMenuTarget: NSObject {}
    private final class StubMenuDelegate: NSObject, NSMenuDelegate {}

    // MARK: - 空菜单(无 session)

    func testHeaderShowsSessionCountForEmpty() {
        let menu = MenuBuilder.build(
            snapshot: emptySnapshot(),
            actions: makeActions(target: StubMenuTarget()),
            settings: defaultSettings(),
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )

        XCTAssertEqual(menu.items[0].title, "Claude Code · 0 个会话")
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "(暂无会话)")
    }

    func testEmptyMenuTrailingItemsArePrefsAndQuit() {
        let menu = MenuBuilder.build(
            snapshot: emptySnapshot(),
            actions: makeActions(target: StubMenuTarget()),
            settings: defaultSettings(),
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )

        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("偏好设置..."))
        XCTAssertTrue(titles.contains("Quit"))
        // Quit 始终在最后一行
        XCTAssertEqual(menu.items.last?.title, "Quit")
    }

    // MARK: - sessions 行

    func testHeaderShowsSessionCountForMultiple() {
        let snap = MenuBuilder.Snapshot(
            sessions: [
                makeSession(pid: 1, status: .idle),
                makeSession(pid: 2, status: .busy)
            ],
            lifetime: [], window: nil, contextByPid: [:], detailsByPid: [:], now: Date()
        )
        let menu = MenuBuilder.build(
            snapshot: snap,
            actions: makeActions(target: StubMenuTarget()),
            settings: defaultSettings(),
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )
        XCTAssertEqual(menu.items[0].title, "Claude Code · 2 个会话")
    }

    func testSessionRowViewAttachedAsView() {
        let snap = MenuBuilder.Snapshot(
            sessions: [makeSession(pid: 42, status: .busy)],
            lifetime: [], window: nil, contextByPid: [:], detailsByPid: [:], now: Date()
        )
        let menu = MenuBuilder.build(
            snapshot: snap,
            actions: makeActions(target: StubMenuTarget()),
            settings: defaultSettings(),
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )

        // header / separator / sessionRow ...
        let row = menu.items[2]
        XCTAssertNotNil(row.view as? SessionRowView, "session 主行必须是 SessionRowView")
    }

    func testSessionsSortedByPid() {
        let snap = MenuBuilder.Snapshot(
            sessions: [
                makeSession(pid: 999, status: .idle),
                makeSession(pid: 100, status: .idle),
                makeSession(pid: 500, status: .idle)
            ],
            lifetime: [], window: nil, contextByPid: [:], detailsByPid: [:], now: Date()
        )
        let menu = MenuBuilder.build(
            snapshot: snap,
            actions: makeActions(target: StubMenuTarget()),
            settings: defaultSettings(),
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )

        let rowViews = menu.items.compactMap { $0.view as? SessionRowView }
        XCTAssertEqual(rowViews.count, 3)
        // 通过 mainLabel 文本反推 pid 顺序 — SessionRowView 主标题包含 "pid <n>"
        // 这里间接验证排序;换言之 100 应该出现在 500 之前。
        let labels = rowViews.compactMap { $0.subviews.compactMap({ $0 as? NSTextField }).first?.stringValue }
        XCTAssertTrue(labels[0].contains("pid 100"))
        XCTAssertTrue(labels[1].contains("pid 500"))
        XCTAssertTrue(labels[2].contains("pid 999"))
    }

    // MARK: - detail 行(从 detailsByPid 缓存读)

    func testSessionDetailItemRenderedFromCache() {
        let s = makeSession(pid: 7, status: .idle)
        let details = SessionDetails(
            model: "claude-opus-4-7",
            inputTokens: 100, outputTokens: 50,
            cacheReadTokens: 99_900, cacheCreationTokens: 0
        )
        let snap = MenuBuilder.Snapshot(
            sessions: [s],
            lifetime: [], window: nil,
            // recentPrompt 非空 → 走 detail 分支(否则会改走 resume submenu)
            contextByPid: [s.pid: SessionContext(recentPrompt: "hello", lastTool: nil)],
            detailsByPid: [s.pid: details],
            now: Date()
        )
        let menu = MenuBuilder.build(
            snapshot: snap,
            actions: makeActions(target: StubMenuTarget()),
            settings: defaultSettings(),
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )
        // contextTokens = 100 + 99_900 + 0 = 100_000;window = 1_000_000(opus-4 系)
        // 10% (100.0k/1.0M)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(
            titles.contains { $0 == "claude-opus-4-7 · 10% (100.0k/1.0M)" },
            "应渲染为 <model> · <pct>% (used/window),实际 titles: \(titles)"
        )
    }

    func testSessionDetailItemSkippedWhenCacheMissing() {
        // detailsByPid 拿不到该 pid → 不挂 detail 行,但 sessionRow 仍存在。
        let s = makeSession(pid: 13, status: .idle)
        let snap = MenuBuilder.Snapshot(
            sessions: [s],
            lifetime: [], window: nil,
            contextByPid: [s.pid: SessionContext(recentPrompt: "x", lastTool: nil)],
            detailsByPid: [:],
            now: Date()
        )
        let menu = MenuBuilder.build(
            snapshot: snap,
            actions: makeActions(target: StubMenuTarget()),
            settings: defaultSettings(),
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )
        let titles = menu.items.map(\.title)
        XCTAssertFalse(
            titles.contains { $0.contains("·") && $0.contains("%") },
            "缓存缺失时菜单不应显示残缺的 detail 行"
        )
    }

    // MARK: - 偏好设置 / Quit selectors

    func testPrefsItemUsesInjectedSelectorAndTarget() {
        let target = StubMenuTarget()
        let actions = makeActions(target: target)
        let menu = MenuBuilder.build(
            snapshot: emptySnapshot(),
            actions: actions,
            settings: defaultSettings(),
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )

        let prefs = menu.items.first { $0.title == "偏好设置..." }
        XCTAssertNotNil(prefs)
        XCTAssertEqual(prefs?.action, actions.openSettingsSelector)
        XCTAssertTrue(prefs?.target as? StubMenuTarget === target)
        XCTAssertEqual(prefs?.keyEquivalent, ",")
    }

    func testQuitItemUsesAppTerminate() {
        let menu = MenuBuilder.build(
            snapshot: emptySnapshot(),
            actions: makeActions(target: StubMenuTarget()),
            settings: defaultSettings(),
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )

        let quit = menu.items.last
        XCTAssertEqual(quit?.title, "Quit")
        XCTAssertEqual(quit?.action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(quit?.keyEquivalent, "q")
    }

    // MARK: - 5 小时窗口

    func testCurrentWindowEmpty() {
        var settings = defaultSettings()
        settings.showCurrentWindow = true
        let menu = MenuBuilder.build(
            snapshot: emptySnapshot(),
            actions: makeActions(target: StubMenuTarget()),
            settings: settings,
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )
        XCTAssertTrue(menu.items.contains { $0.title == "本 5 小时" })
        XCTAssertTrue(menu.items.contains { $0.title == "  (无活动)" })
    }

    func testCurrentWindowHidesWhenSettingOff() {
        let settings = defaultSettings()
        settings.showCurrentWindow = false
        let menu = MenuBuilder.build(
            snapshot: emptySnapshot(),
            actions: makeActions(target: StubMenuTarget()),
            settings: settings,
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )
        XCTAssertFalse(menu.items.contains { $0.title == "本 5 小时" })
    }

    func testCurrentWindowFormatting() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = RollingWindow(
            startedAt: now,
            resetsAt: now.addingTimeInterval(3600 * 2 + 60 * 30),
            inputTokens: 1500,
            outputTokens: 2500
        )
        let snap = MenuBuilder.Snapshot(
            sessions: [], lifetime: [], window: window, contextByPid: [:], detailsByPid: [:], now: now
        )
        let settings = defaultSettings()
        settings.showCurrentWindow = true
        let menu = MenuBuilder.build(
            snapshot: snap,
            actions: makeActions(target: StubMenuTarget()),
            settings: settings,
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )

        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains { $0.contains("用量 4.0k") }, "总 token 应显示 4.0k")
        XCTAssertTrue(titles.contains { $0.contains("In 1.5k") })
        XCTAssertTrue(titles.contains { $0.contains("Out 2.5k") })
        XCTAssertTrue(titles.contains { $0.contains("重置 2h 30m 后") })
    }

    // MARK: - 累计用量

    func testLifetimeShowsWhenEnabledAndHasData() {
        let lifetime = [
            ModelLifetimeUsage(model: "claude-opus-4", inputTokens: 1000, outputTokens: 500, costUSD: 1.23),
            ModelLifetimeUsage(model: "claude-sonnet-4", inputTokens: 200, outputTokens: 100, costUSD: 0.10),
        ]
        let snap = MenuBuilder.Snapshot(
            sessions: [], lifetime: lifetime, window: nil, contextByPid: [:], detailsByPid: [:], now: Date()
        )
        let settings = defaultSettings()
        settings.showLifetimeUsage = true
        let menu = MenuBuilder.build(
            snapshot: snap,
            actions: makeActions(target: StubMenuTarget()),
            settings: settings,
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )

        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("总用量 (按模型)"))
        XCTAssertTrue(titles.contains { $0.hasPrefix("claude-opus-4") })
        XCTAssertTrue(titles.contains { $0.hasPrefix("claude-sonnet-4") })
        XCTAssertTrue(titles.contains { $0.contains("累计费用 $1.33") })
    }

    func testLifetimeEmptyShowsNoData() {
        let settings = defaultSettings()
        settings.showLifetimeUsage = true
        let menu = MenuBuilder.build(
            snapshot: emptySnapshot(),
            actions: makeActions(target: StubMenuTarget()),
            settings: settings,
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )
        XCTAssertTrue(menu.items.contains { $0.title == "  (无数据)" })
    }

    func testLifetimeHidesWhenSettingOff() {
        let lifetime = [
            ModelLifetimeUsage(model: "x", inputTokens: 1, outputTokens: 1, costUSD: 0)
        ]
        let snap = MenuBuilder.Snapshot(
            sessions: [], lifetime: lifetime, window: nil, contextByPid: [:], detailsByPid: [:], now: Date()
        )
        let settings = defaultSettings()
        settings.showLifetimeUsage = false
        let menu = MenuBuilder.build(
            snapshot: snap,
            actions: makeActions(target: StubMenuTarget()),
            settings: settings,
            relativeFormatter: formatter(),
            menuDelegate: StubMenuDelegate()
        )
        XCTAssertFalse(menu.items.contains { $0.title == "总用量 (按模型)" })
    }

    // MARK: - delegate 注入

    func testMenuDelegateIsAssigned() {
        let delegate = StubMenuDelegate()
        let menu = MenuBuilder.build(
            snapshot: emptySnapshot(),
            actions: makeActions(target: StubMenuTarget()),
            settings: defaultSettings(),
            relativeFormatter: formatter(),
            menuDelegate: delegate
        )
        XCTAssertTrue(menu.delegate === delegate)
    }
}

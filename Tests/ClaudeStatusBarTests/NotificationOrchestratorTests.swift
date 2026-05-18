import XCTest
@testable import ClaudeStatusBar

/// 校验 NotificationOrchestrator 的核心不变量(详见类顶部注释):
/// 1. detector 调用顺序 + abandonAll 在 transition 通知前
/// 2. transition / reminder 通知按 pendingSessionIds 抑制;completion 不抑制
/// 3. settings 关闭时 detector 仍 tick(再开启不会重发首帧)
/// 4. reminderTracker 的节奏与重建语义
final class NotificationOrchestratorTests: XCTestCase {

    // MARK: - Stubs

    private final class StubNotifier: WaitingNotifying {
        var notified: [Session] = []
        var completed: [Session] = []
        func notify(session: Session) { notified.append(session) }
        func notifyCompletion(session: Session) { completed.append(session) }
    }

    private final class StubGate: PermissionPromptGating {
        var pending: Set<String> = []
        var abandoned: [String] = []
        func pendingSessionIds() -> Set<String> { pending }
        func abandonAll(sessionId: String) {
            abandoned.append(sessionId)
            pending.remove(sessionId)
        }
    }

    // MARK: - fixture

    private func session(
        pid: Int,
        sessionId: String,
        status: SessionStatus
    ) -> Session {
        let json = #"""
        {"pid":\#(pid),"sessionId":"\#(sessionId)","cwd":"/x","startedAt":0,"version":"2","kind":"interactive","entrypoint":"cli","status":"\#(status.rawValue)","updatedAt":0}
        """#.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    private func makeOrchestrator(
        notifier: StubNotifier = StubNotifier(),
        gate: StubGate = StubGate(),
        notificationsEnabled: Bool = true,
        reminderInterval: TimeInterval? = nil
    ) -> (NotificationOrchestrator, StubNotifier, StubGate) {
        let enabled = NotificationsFlag(value: notificationsEnabled)
        let orch = NotificationOrchestrator(
            notifier: notifier,
            permissionGate: gate,
            isNotificationsEnabled: { enabled.value },
            reminderInterval: reminderInterval
        )
        return (orch, notifier, gate)
    }

    private final class NotificationsFlag {
        var value: Bool
        init(value: Bool) { self.value = value }
    }

    // MARK: - 不变量 1: 第一帧 baseline 不发通知

    func testFirstFrameAbsorbsBaseline() {
        let (orch, notifier, _) = makeOrchestrator()
        orch.sessionsDidChange([
            session(pid: 1, sessionId: "a", status: .waiting),
            session(pid: 2, sessionId: "b", status: .idle)
        ])
        XCTAssertEqual(notifier.notified, [])
        XCTAssertEqual(notifier.completed, [])
    }

    // MARK: - 不变量 2a: busy → waiting transition 发通知

    func testBusyToWaitingNotifies() {
        let (orch, notifier, _) = makeOrchestrator()
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .busy)])
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .waiting)])
        XCTAssertEqual(notifier.notified.map(\.sessionId), ["a"])
    }

    // MARK: - 不变量 2b: busy → idle completion 发通知

    func testBusyToIdleNotifiesCompletion() {
        let (orch, notifier, _) = makeOrchestrator()
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .busy)])
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .idle)])
        XCTAssertEqual(notifier.completed.map(\.sessionId), ["a"])
        XCTAssertEqual(notifier.notified, [])
    }

    // MARK: - 不变量 3a: pendingSessionIds 抑制 transition 通知

    func testWaitingTransitionSuppressedWhenPanelOwnsSession() {
        let (orch, notifier, gate) = makeOrchestrator()
        gate.pending = ["a"]  // 浮窗在弹
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .busy)])
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .waiting)])
        XCTAssertEqual(notifier.notified, [], "panel 在弹时不该发横幅")
    }

    // MARK: - 不变量 3b: completion 通知不被抑制

    func testCompletionNotSuppressedByPanelGate() {
        let (orch, notifier, gate) = makeOrchestrator()
        gate.pending = ["a"]
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .busy)])
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .idle)])
        XCTAssertEqual(notifier.completed.map(\.sessionId), ["a"])
    }

    // MARK: - 不变量 4: waiting → idle 触发 abandonAll

    func testLeavingWaitingTriggersAbandonAll() {
        let (orch, _, gate) = makeOrchestrator()
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .waiting)])
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .idle)])
        XCTAssertEqual(gate.abandoned, ["a"])
    }

    func testStillWaitingDoesNotAbandon() {
        let (orch, _, gate) = makeOrchestrator()
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .waiting)])
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .waiting)])
        XCTAssertEqual(gate.abandoned, [])
    }

    // MARK: - 不变量 5: notificationsEnabled = false 时 detector 仍 tick

    func testNotificationsDisabledStillAdvancesDetectorState() {
        let notifier = StubNotifier()
        let gate = StubGate()
        let flag = NotificationsFlag(value: false)
        let orch = NotificationOrchestrator(
            notifier: notifier,
            permissionGate: gate,
            isNotificationsEnabled: { flag.value },
            reminderInterval: nil
        )

        // 关掉通知,跑两帧建立 baseline + 触发一次 transition。
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .busy)])
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .waiting)])
        XCTAssertEqual(notifier.notified, [], "关掉通知期间不该发")

        // 现在再打开通知。如果 detector 没在关闭期间 tick,这里第一帧会被
        // 当 baseline,把 waiting 漏报。期望:detector 已经记得 a 在 waiting,
        // 所以不会再触发新的 transition。
        flag.value = true
        orch.sessionsDidChange([session(pid: 1, sessionId: "a", status: .waiting)])
        XCTAssertEqual(notifier.notified, [], "重开后不该重报已经在 waiting 的 session")
    }

    // MARK: - reminder 节奏

    func testReminderRespectsInitialDelay() {
        let (orch, notifier, _) = makeOrchestrator(reminderInterval: 30)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = session(pid: 1, sessionId: "a", status: .waiting)
        orch.tickReminder(now: now, sessions: [s])  // baseline
        orch.tickReminder(now: now.addingTimeInterval(15), sessions: [s])
        XCTAssertEqual(notifier.notified, [], "未到 initialDelay 不应发")

        orch.tickReminder(now: now.addingTimeInterval(31), sessions: [s])
        XCTAssertEqual(notifier.notified.map(\.sessionId), ["a"])
    }

    func testReminderHonorsMaxReminders() {
        let (orch, notifier, _) = makeOrchestrator(reminderInterval: 30)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = session(pid: 1, sessionId: "a", status: .waiting)
        orch.tickReminder(now: now, sessions: [s])  // baseline
        // 跨足够长时间多次 tick,每次都过 interval。
        for i in 1...10 {
            orch.tickReminder(now: now.addingTimeInterval(30 * Double(i) + 1), sessions: [s])
        }
        // makeReminderTracker 在 reminderInterval != nil 时把 maxReminders 设为 3。
        XCTAssertEqual(notifier.notified.count, 3, "最多 3 次提醒")
    }

    func testReminderNilIntervalNeverFires() {
        let (orch, notifier, _) = makeOrchestrator(reminderInterval: nil)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = session(pid: 1, sessionId: "a", status: .waiting)
        orch.tickReminder(now: now, sessions: [s])
        for i in 1...20 {
            orch.tickReminder(now: now.addingTimeInterval(60 * Double(i)), sessions: [s])
        }
        XCTAssertEqual(notifier.notified, [], "interval nil → maxReminders=0,永远不发")
    }

    func testReminderRebuildClearsPerPidState() {
        let (orch, notifier, _) = makeOrchestrator(reminderInterval: 30)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = session(pid: 1, sessionId: "a", status: .waiting)
        orch.tickReminder(now: now, sessions: [s])  // baseline
        orch.tickReminder(now: now.addingTimeInterval(31), sessions: [s])
        XCTAssertEqual(notifier.notified.count, 1)

        // 重建之后 firstSeenAt 应该被重置 —— 立刻再过 31s 应该再触发一次。
        orch.rebuildReminderTracker(interval: 30)
        orch.tickReminder(now: now.addingTimeInterval(40), sessions: [s])  // 新 baseline
        orch.tickReminder(now: now.addingTimeInterval(40 + 31), sessions: [s])
        XCTAssertEqual(notifier.notified.count, 2, "重建后又能再发一次")
    }

    func testReminderSuppressedByPanelGate() {
        let (orch, notifier, gate) = makeOrchestrator(reminderInterval: 30)
        gate.pending = ["a"]
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = session(pid: 1, sessionId: "a", status: .waiting)
        orch.tickReminder(now: now, sessions: [s])  // baseline
        orch.tickReminder(now: now.addingTimeInterval(31), sessions: [s])
        XCTAssertEqual(notifier.notified, [], "浮窗在弹时 reminder 也该被抑制")
    }
}

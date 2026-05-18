import Foundation

/// 把 4 个 detector + reminderTracker + 通知派发决策聚合到一起的协调器。
/// 拆出来之前这段逻辑直接住在 AppDelegate 的 sink 闭包里 —— 跨多个 mutating
/// struct 的调用顺序、抑制规则和 settings gate 全杂在一起,既难读也难测。
///
/// 关键不变量(改动这块时都要确认它们仍然成立):
///
/// 1. **detector 调用顺序**:`waitingTransition.detect` → `completion.detect`
///    → `sessionExit.detect`。前两者是「新事件抽取」,sessionExit 触发
///    `permissionGate.abandonAll(sessionId:)` 把对应浮窗关掉 —— 这一步要在
///    transition 通知派发之前完成,这样下一帧 `pendingSessionIds()` 看到的
///    是 abandon 后的真实状态。
///
/// 2. **抑制规则**:transition / reminder 通知都过 `pendingSessionIds()` 过滤
///    (浮窗已经在该会话上承担了"等待响应"的告知,横幅会双计);completion
///    通知**不**过滤(busy → idle 不是权限态)。
///
/// 3. **`isNotificationsEnabled` 只 gate 派发,不 gate 状态推进**:即使用户关
///    掉了通知,detector 和 reminderTracker 也照常 tick —— 否则状态机断裂,
///    再开启时第一帧会被当成 baseline 把已有 waiting 的会话误吞。
///
/// 4. **reminder tracker 的重建会清状态**:`rebuildReminderTracker` 故意丢弃
///    in-flight 的 per-pid 计时(用户改了间隔,旧的计时按新间隔重新跑符合
///    直觉)。
public final class NotificationOrchestrator {

    private var waitingTransition = WaitingTransitionDetector()
    private var completion = TaskCompletionDetector()
    private var sessionExit = PermissionPromptSessionExitDetector()
    private var reminderTracker: WaitingReminderTracker

    private let notifier: WaitingNotifying
    private let permissionGate: PermissionPromptGating
    private let isNotificationsEnabled: () -> Bool

    public init(
        notifier: WaitingNotifying,
        permissionGate: PermissionPromptGating,
        isNotificationsEnabled: @escaping () -> Bool,
        reminderInterval: TimeInterval?
    ) {
        self.notifier = notifier
        self.permissionGate = permissionGate
        self.isNotificationsEnabled = isNotificationsEnabled
        self.reminderTracker = Self.makeReminderTracker(interval: reminderInterval)
    }

    // MARK: - 对外入口

    /// SessionStore.$sessions 每次推送都调一次。detector 三件套连续跑、
    /// abandonAll、派发横幅 —— 顺序见类顶部不变量 1。
    public func sessionsDidChange(_ sessions: [Session]) {
        let transitioned = waitingTransition.detect(in: sessions)
        let completed = completion.detect(in: sessions)

        // sessionId 离开 waiting → 关掉对应浮窗。先于 notify 处理,这样
        // abandonAll 触发的 resolved 信号能在同一 runloop 把面板移除。
        for sid in sessionExit.detect(in: sessions) {
            permissionGate.abandonAll(sessionId: sid)
        }

        guard isNotificationsEnabled() else { return }

        // 浮窗已经在该会话上承担了"等待响应"的告知,系统通知就别再叠一层。
        let withPanel = permissionGate.pendingSessionIds()
        for s in transitioned where !withPanel.contains(s.sessionId) {
            notifier.notify(session: s)
        }
        for s in completed {
            notifier.notifyCompletion(session: s)
        }
    }

    /// 5s reminder timer 的回调入口。reminderTracker.tick 先跑(更新状态机),
    /// 然后才 gate —— 关掉通知再开启不会重复发首帧。
    public func tickReminder(now: Date, sessions: [Session]) {
        let due = reminderTracker.tick(sessions: sessions, now: now)
        guard isNotificationsEnabled() else { return }
        let withPanel = permissionGate.pendingSessionIds()
        for s in due where !withPanel.contains(s.sessionId) {
            notifier.notify(session: s)
        }
    }

    /// SettingsStore.reminderInterval 变化时调一次。in-flight 的 per-pid
    /// 计时被清空 —— 这是预期行为(见类顶部不变量 4)。
    public func rebuildReminderTracker(interval: TimeInterval?) {
        reminderTracker = Self.makeReminderTracker(interval: interval)
    }

    // MARK: - Private

    /// `nil` 间隔 → maxReminders=0,reminderTracker.tick 永远返回空。其他配置
    /// 数字跟设置 UI 里默认 30s / 1min / 5min 这些选项一致。把 interval 同时
    /// 用作 initialDelay 是个产品决定 —— 等同长时间 = 一倍间隔后第一次提醒。
    private static func makeReminderTracker(interval: TimeInterval?) -> WaitingReminderTracker {
        guard let interval else {
            return WaitingReminderTracker(
                config: .init(initialDelay: 30, interval: 30, maxReminders: 0)
            )
        }
        return WaitingReminderTracker(
            config: .init(initialDelay: interval, interval: interval, maxReminders: 3)
        )
    }
}

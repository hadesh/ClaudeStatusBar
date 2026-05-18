import Foundation
import UserNotifications

/// `NotificationOrchestrator` 看到的最小通知派发接口。把 `WaitingNotifier` 抽成
/// protocol 后,Orchestrator 的单测可以注入一个内存 stub,不必真的调
/// `UNUserNotificationCenter` 或起 osascript 子进程。
public protocol WaitingNotifying: AnyObject {
    func notify(session: Session)
    func notifyCompletion(session: Session)
}

/// Posts the "session entered waiting" banner. Stateless aside from a feature
/// flag. The `UNUserNotificationCenter` delegate seat is owned by
/// `NotificationDispatcher`; click routing to the terminal lives there.
public final class WaitingNotifier: WaitingNotifying {
    private let useUN: Bool

    public init() {
        // UNUserNotificationCenter 仅在有 bundle identifier(打包成 .app)时可用。
        useUN = Bundle.main.bundleIdentifier != nil
    }

    /// Banner posted when a CLI session enters `waiting` for a non-permission
    /// reason (the permission case is owned by the panel). Used by
    /// `WaitingTransitionDetector` and `WaitingReminderTracker`.
    public func notify(session: Session) {
        let project = (session.cwd as NSString).lastPathComponent
        let reason = session.waitingFor ?? "需要确认"
        notify(
            title: "Claude Code 等待响应",
            body: "\(project) · \(reason)",
            userInfo: ["pid": session.pid, "cwd": session.cwd]
        )
    }

    /// Banner posted when a CLI session transitions `busy → idle` —
    /// "Claude Code finished its turn". Click routes back to the terminal via
    /// `NotificationDispatcher.onWaitingClick` (same userInfo shape).
    public func notifyCompletion(session: Session) {
        let project = (session.cwd as NSString).lastPathComponent
        let body = project.isEmpty ? "(unknown project)" : project
        notify(
            title: "Claude Code 任务完成",
            body: body,
            userInfo: ["pid": session.pid, "cwd": session.cwd]
        )
    }

    public func notify(title: String, body: String, userInfo: [String: Any] = [:]) {
        if useUN {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = userInfo
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content, trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        } else {
            presentViaOsascript(title: title, body: body)
        }
    }

    private func presentViaOsascript(title: String, body: String) {
        let escapedTitle = escapeForAppleScript(title)
        let escapedBody = escapeForAppleScript(body)
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

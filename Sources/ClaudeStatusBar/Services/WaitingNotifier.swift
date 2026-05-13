import Foundation
import UserNotifications

public final class WaitingNotifier {
    private let useUN: Bool

    public init() {
        // UNUserNotificationCenter 仅在有 bundle identifier(打包成 .app)时可用。
        useUN = Bundle.main.bundleIdentifier != nil
        if useUN {
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            ) { _, _ in }
        }
    }

    public func notify(session: Session) {
        let project = (session.cwd as NSString).lastPathComponent
        let title = "Claude Code 等待响应"
        let reason = session.waitingFor ?? "需要确认"
        let body = "\(project) · \(reason)"

        if useUN {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "claude-waiting-\(session.pid)-\(Int(Date().timeIntervalSince1970 * 1000))",
                content: content, trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        } else {
            presentViaOsascript(title: title, body: body)
        }
    }

    private func presentViaOsascript(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}

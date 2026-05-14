import Foundation
import UserNotifications

public final class WaitingNotifier: NSObject, UNUserNotificationCenterDelegate {
    public typealias ClickHandler = (_ pid: Int, _ cwd: String?) -> Void

    private let useUN: Bool
    private var clickHandler: ClickHandler?

    public override init() {
        // UNUserNotificationCenter 仅在有 bundle identifier(打包成 .app)时可用。
        useUN = Bundle.main.bundleIdentifier != nil
        super.init()
        if useUN {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// 用户点击通知时回调。AppDelegate 在 didFinishLaunching 里挂 hook,
    /// 把点击路由到激活终端 / 打开 cwd 的逻辑。osascript 兜底路径无法回调。
    public func setClickHandler(_ handler: @escaping ClickHandler) {
        clickHandler = handler
    }

    public func notify(session: Session) {
        let project = (session.cwd as NSString).lastPathComponent
        let reason = session.waitingFor ?? "需要确认"
        notify(
            title: "Claude Code 等待响应",
            body: "\(project) · \(reason)",
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

    /// 状态栏 app 在用户点开菜单时会被视为前台,默认行为会吞掉横幅;返回
    /// `[.banner, .sound]` 强制弹出。
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let pid = info["pid"] as? Int {
            let cwd = info["cwd"] as? String
            DispatchQueue.main.async { [weak self] in
                self?.clickHandler?(pid, cwd)
            }
        }
        completionHandler()
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

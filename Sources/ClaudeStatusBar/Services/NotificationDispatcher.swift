import Foundation
import UserNotifications

/// Single owner of the `UNUserNotificationCenter` delegate seat. Routes
/// `didReceive` callbacks for the waiting-banner notifications back to a
/// click handler. Permission prompts go through `PermissionPromptPanel`
/// (a non-UN floating panel) and don't touch this dispatcher.
public final class NotificationDispatcher: NSObject, UNUserNotificationCenterDelegate {
    public typealias WaitingClick = (_ pid: Int, _ cwd: String?) -> Void

    public var onWaitingClick: WaitingClick?

    public func install() {
        // UNUserNotificationCenter.current() crashes without a bundle id
        // (i.e. when launched via `swift run` rather than as a .app). Waiting
        // banners degrade to the osascript fallback in that mode; permission
        // prompts go through the panel which doesn't depend on UN.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 状态栏 app 打开菜单时会被视为前台,默认行为会吞掉横幅;强制弹出。
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
                self?.onWaitingClick?(pid, cwd)
            }
        }
        completionHandler()
    }
}

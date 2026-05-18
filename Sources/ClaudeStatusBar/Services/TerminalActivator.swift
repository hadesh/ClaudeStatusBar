import Cocoa

/// 「把焦点切到对应的终端 App / 用 Finder 打开 cwd」 这一组动作的统一入口。
/// 调用方:
///   - SessionRowView 主行点击 → revealSession(forPid:)
///   - 通知横幅点击 → handleNotificationClick(pid:cwd:)
///   - AskUserQuestion 浮窗「跳回终端答」按钮 → activate(forSessionId:cwd:)
///   - 找不到对应终端 / cwd 都没有时 → 调 notifier.notify(...) 弹个提示
///
/// 内部走 TerminalNavigator.findGuiAncestor 沿父进程链找到第一个
/// LaunchServices 可识别的 GUI app(iTerm2、Terminal.app、VS Code 等);找不到
/// 时退化到 Finder 打开 cwd;再不行就发个「找不到对应终端」通知。
///
/// 必须在主线程被调用 —— `revealSession` 读 NSApp.currentEvent 检测 Option
/// modifier,跨线程访问 currentEvent 是 UB。AskUserQuestion 路径不依赖
/// modifier,但同样走主线程,因为最终都要 NSWorkspace / NSRunningApplication。
public protocol TerminalActivating: AnyObject {
    func activate(forSessionId sessionId: String?, cwd: String?)
}

public final class TerminalActivator: TerminalActivating {
    private let store: SessionStore
    private let notifier: WaitingNotifier

    public init(store: SessionStore, notifier: WaitingNotifier) {
        self.store = store
        self.notifier = notifier
    }

    /// SessionRowView 主行点击入口。按住 Option 时改走 Finder 打开 cwd —— 用户偶尔
    /// 想要的是文件夹而不是终端。Option 检测必须在主线程读 NSApp.currentEvent。
    public func revealSession(forPid pid: Int) {
        guard let session = store.sessions.first(where: { $0.pid == pid }) else { return }
        let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        if optionHeld {
            openCwdInFinder(session.cwd)
            return
        }
        guard let app = findOwningApp(of: session.pid) else {
            notifyTerminalNotFound()
            return
        }
        app.activate(options: [.activateAllWindows])
    }

    /// 通知横幅点击入口。userInfo 里只有 pid + cwd,没有 sessionId,所以走 pid
    /// 路径。找不到 GUI 祖先时退到 Finder 而不是发"找不到终端"——通知点击是用户
    /// 主动发起的,要尽量给个反馈,而 revealSession 那里 Option 才进 Finder,无法
    /// 回退,所以保留两个不同的 fallback 策略。
    public func handleNotificationClick(pid: Int, cwd: String?) {
        if let app = findOwningApp(of: pid) {
            app.activate(options: [.activateAllWindows])
            return
        }
        if let cwd {
            openCwdInFinder(cwd)
        } else {
            NSSound.beep()
        }
    }

    /// AskUserQuestion 浮窗「跳回终端答」按钮触发。优先 sessionId → pid 反查,
    /// 反查不到时退到 cwd 打开 Finder。
    public func activate(forSessionId sessionId: String?, cwd: String?) {
        if let sid = sessionId,
           let pid = store.sessions.first(where: { $0.sessionId == sid })?.pid,
           let app = findOwningApp(of: pid)
        {
            app.activate(options: [.activateAllWindows])
            return
        }
        if let cwd {
            openCwdInFinder(cwd)
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Private

    private func findOwningApp(of sessionPid: Int) -> NSRunningApplication? {
        let resolved = TerminalNavigator.findGuiAncestor(
            startingFrom: sessionPid,
            processInfo: ProcessTree.info(pid:),
            isGuiApp: { NSRunningApplication(processIdentifier: pid_t($0)) != nil }
        )
        return resolved.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
    }

    private func openCwdInFinder(_ cwd: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    private func notifyTerminalNotFound() {
        NSSound.beep()
        notifier.notify(
            title: "找不到对应终端",
            body: "按住 Option 点击可在 Finder 中打开 cwd"
        )
    }
}

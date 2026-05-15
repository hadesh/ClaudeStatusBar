import Foundation
import Combine

/// Holds in-flight permission prompts. Each entry carries a reply closure that
/// resolves the originating socket connection. Auto-denies after `timeout`.
///
/// `nil` passed to `Reply` means "abandon" — the listener should close the fd
/// without writing any response, so the helper exits without writing stdout
/// and the CLI's terminal prompt wins the race. Used when the user dismisses
/// the panel via ✕ (intent: "let me answer in the terminal").
public final class PermissionPromptStore {
    public typealias Reply = (PermissionPromptDecision?) -> Void
    /// (interval, work) -> cancel. Lets tests inject deterministic timing.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    private struct Pending {
        let request: PermissionPromptRequest
        let reply: Reply
        let cancelTimeout: () -> Void
    }

    public let incoming = PassthroughSubject<PermissionPromptRequest, Never>()

    /// Fires whenever an entry leaves the pending set — explicit resolve, allow/deny
    /// shorthand, or auto-deny on timeout. Lets the panel UI dismiss stale windows
    /// when the request was resolved by something other than the panel itself.
    public let resolved = PassthroughSubject<String, Never>()

    private let timeout: TimeInterval
    private let scheduler: Scheduler
    private let lock = NSLock()
    private var entries: [String: Pending] = [:]

    public init(
        timeout: TimeInterval = 300,
        scheduler: @escaping Scheduler = PermissionPromptStore.defaultScheduler
    ) {
        self.timeout = timeout
        self.scheduler = scheduler
    }

    public var pendingIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.keys).sorted()
    }

    /// CLI sessionIds for every in-flight prompt. Used by `AppDelegate` to
    /// suppress the system "等待响应" notification while the panel is owning
    /// that session — otherwise the user gets both a banner and the panel for
    /// the same event.
    public func pendingSessionIds() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.values.compactMap { $0.request.sessionId })
    }

    public func add(_ request: PermissionPromptRequest, reply: @escaping Reply) {
        let cancel = scheduler(timeout) { [weak self] in
            self?.fireTimeout(id: request.id)
        }
        lock.lock()
        entries[request.id] = Pending(request: request, reply: reply, cancelTimeout: cancel)
        lock.unlock()
        incoming.send(request)
    }

    public func resolve(id: String, decision: PermissionPromptDecision) {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return }
        entry.cancelTimeout()
        entry.reply(decision)
        resolved.send(id)
    }

    /// Convenience: allow with the original input echoed back as `updatedInput`.
    public func resolveAllow(id: String) {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return }
        entry.cancelTimeout()
        entry.reply(.allow(id: id, input: entry.request.input))
        resolved.send(id)
    }

    /// Convenience: allow + tell the helper to add a session-scoped permission
    /// rule for this exact tool/input. The helper rewrites this into a
    /// `decision: {behavior: "allow", updatedPermissions: [...]}` envelope.
    public func resolveAllowAlways(id: String) {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return }
        entry.cancelTimeout()
        entry.reply(.allowAlways(id: id, input: entry.request.input))
        resolved.send(id)
    }

    public func resolveDeny(id: String, message: String) {
        resolve(id: id, decision: .deny(id: id, message: message))
    }

    /// 用户点 ✕ 关掉浮窗,意图是"我去终端答"。我们不替用户做 deny,而是让
    /// helper 端读到 EOF 自己 exit(0) 不写 stdout,CLI 看到 hook 没输出就让
    /// 终端 prompt 完整接管 race。entry 离开后 `resolved` 信号照常 fire,
    /// 所以 manager 能跟 allow/deny 同样的路径关掉面板。
    public func abandon(id: String) {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return }
        entry.cancelTimeout()
        entry.reply(nil)
        resolved.send(id)
    }

    private func fireTimeout(id: String) {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return }
        let minutes = Int(timeout / 60)
        let message = minutes > 0
            ? "user did not respond within \(minutes) minutes"
            : "user did not respond within \(Int(timeout)) seconds"
        entry.reply(.deny(id: id, message: message))
        resolved.send(id)
    }

    public static let defaultScheduler: Scheduler = { interval, work in
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now() + interval)
        t.setEventHandler(handler: work)
        t.resume()
        return { t.cancel() }
    }
}

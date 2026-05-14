import Foundation

/// Edge detector for "task complete" notifications. Returns sessions that
/// transitioned `busy → idle` between consecutive `detect(in:)` calls. The
/// first call silently absorbs the baseline so app start doesn't fire spurious
/// notifications for sessions that were already idle.
///
/// `busy → waiting` is **not** a completion (CLI is asking the user) — that
/// path is handled by the in-app permission panel, not a system notification.
public struct TaskCompletionDetector {
    private var lastBusyPids: Set<Int>?

    public init() {}

    public mutating func detect(in sessions: [Session]) -> [Session] {
        let nowBusy = Set(sessions.filter { $0.status == .busy }.map(\.pid))
        defer { lastBusyPids = nowBusy }
        guard let last = lastBusyPids else { return [] }
        // Sessions that were busy and are now idle. Sessions that disappeared
        // (CLI exit) are intentionally excluded — exiting isn't a completion.
        return sessions.filter { $0.status == .idle && last.contains($0.pid) }
    }
}

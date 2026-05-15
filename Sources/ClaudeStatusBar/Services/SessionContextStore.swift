import Foundation
import Combine

/// 维护每条 session 的「最近 prompt + 最后 tool」缓存。30s timer 全量刷一次,
/// 主动调 `refresh(for:)` 可以单条触发(用于 SessionStore.sessions 增减)。
/// 对外暴露 `@Published contextByPid`,AppDelegate 在重建菜单时直接读。
public final class SessionContextStore: ObservableObject {
    @Published public private(set) var contextByPid: [Int: SessionContext] = [:]

    private let interval: TimeInterval
    private let projectsRoot: URL
    private let workQueue = DispatchQueue(label: "ClaudeStatusBar.SessionContextStore", qos: .utility)
    private let publishQueue: DispatchQueue
    private var timer: DispatchSourceTimer?

    /// 当前已知 sessions —— AppDelegate 把 SessionStore.$sessions 通过 sink 喂进来。
    /// 用 NSLock 保护因为 timer 在 workQueue 上读、AppDelegate 在 main 上写。
    private let lock = NSLock()
    private var snapshot: [Session] = []

    public init(
        interval: TimeInterval = 30.0,
        projectsRoot: URL = SessionDetailsReader.defaultProjectsRoot,
        publishQueue: DispatchQueue = .main
    ) {
        self.interval = interval
        self.projectsRoot = projectsRoot
        self.publishQueue = publishQueue
    }

    deinit { stop() }

    public func start() {
        refreshAll()
        let t = DispatchSource.makeTimerSource(queue: workQueue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.refreshAll() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// AppDelegate 在 SessionStore.$sessions sink 里调,告诉 store 当前活跃 session
    /// 列表。新增 pid 立刻扫一次,删除 pid 立刻清缓存。
    public func updateSessions(_ sessions: [Session]) {
        lock.lock()
        let oldPids = Set(snapshot.map { $0.pid })
        let newPids = Set(sessions.map { $0.pid })
        snapshot = sessions
        lock.unlock()

        let added = newPids.subtracting(oldPids)
        let removed = oldPids.subtracting(newPids)

        if !removed.isEmpty {
            let publishQueue = self.publishQueue
            publishQueue.async { [weak self] in
                guard let self else { return }
                var dict = self.contextByPid
                for pid in removed { dict.removeValue(forKey: pid) }
                self.contextByPid = dict
            }
        }
        if !added.isEmpty {
            let toScan = sessions.filter { added.contains($0.pid) }
            workQueue.async { [weak self] in self?.scanAndPublish(toScan) }
        }
    }

    // MARK: - Private

    private func refreshAll() {
        lock.lock()
        let sessions = snapshot
        lock.unlock()
        scanAndPublish(sessions)
    }

    private func scanAndPublish(_ sessions: [Session]) {
        let projectsRoot = self.projectsRoot
        var partial: [Int: SessionContext] = [:]
        for s in sessions {
            if let ctx = SessionContextReader.read(
                cwd: s.cwd, sessionId: s.sessionId, projectsRoot: projectsRoot
            ) {
                partial[s.pid] = ctx
            }
        }
        publishQueue.async { [weak self] in
            guard let self else { return }
            // 增量合并;本次扫描没拿到的 pid 保留旧值(可能 jsonl 正在写入)。
            var merged = self.contextByPid
            for (k, v) in partial { merged[k] = v }
            self.contextByPid = merged
        }
    }
}

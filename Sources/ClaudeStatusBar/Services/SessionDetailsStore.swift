import Foundation
import Combine

/// `SessionDetails` 的缓存层。形态跟 `SessionContextStore` 完全平行 ——
/// 那个 store 缓存「最近 user prompt + 最后 tool_use」,本 store 缓存「最近
/// 一条 assistant 消息的 model + token usage」。
///
/// 为什么需要缓存:`MenuBuilder` 在主线程构造菜单,如果直接调
/// `SessionDetailsReader.read(...)` 会 reverse-scan jsonl —— 单条 jsonl 累积
/// 到几十 MB 时菜单弹出会有肉眼可感的卡顿。改成读 `detailsByPid` 后,菜单
/// 重建是 O(N) 字典查询,jsonl I/O 在后台 30s timer 上异步跑。
///
/// 30s 间隔的取舍:Claude Code CLI 把 assistant 消息追加到 jsonl 是 append-
/// only,但单条消息的 usage 字段在 stream 完成后才完整 —— 间隔太短容易读
/// 到部分写入。30s 跟 `SessionContextStore` / `UsageTracker` 对齐。
///
/// 并发模型:`updateSessions` 由 AppDelegate 在主线程推入(`SessionStore.$sessions`
/// sink),`refreshAll` 在 workQueue 周期触发。`snapshot` 用 NSLock 保护
/// 跨线程读写;`detailsByPid` 的写入永远走 publishQueue(默认 main),
/// 让 `@Published` 的订阅者拿到一致快照。
public final class SessionDetailsStore: ObservableObject {
    @Published public private(set) var detailsByPid: [Int: SessionDetails] = [:]

    private let interval: TimeInterval
    private let projectsRoot: URL
    private let workQueue = DispatchQueue(label: "ClaudeStatusBar.SessionDetailsStore", qos: .utility)
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
    /// 列表。新增 pid 立刻扫一次(不等下一轮 timer),删除 pid 立刻清缓存。
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
                var dict = self.detailsByPid
                for pid in removed { dict.removeValue(forKey: pid) }
                self.detailsByPid = dict
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
        var partial: [Int: SessionDetails] = [:]
        for s in sessions {
            if let d = SessionDetailsReader.read(
                cwd: s.cwd, sessionId: s.sessionId, projectsRoot: projectsRoot
            ) {
                partial[s.pid] = d
            }
        }
        publishQueue.async { [weak self] in
            guard let self else { return }
            // 增量合并;本次扫描没拿到的 pid 保留旧值(可能 jsonl 正在写入)。
            var merged = self.detailsByPid
            for (k, v) in partial { merged[k] = v }
            self.detailsByPid = merged
        }
    }
}

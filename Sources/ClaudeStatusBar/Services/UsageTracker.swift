import Foundation
import CoreServices

public final class UsageTracker {
    public static let defaultURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/stats-cache.json")
    }()

    private let url: URL
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?

    @Published public private(set) var usage: DailyUsage = .empty

    public init(url: URL = UsageTracker.defaultURL, queue: DispatchQueue = .main) {
        self.url = url
        self.queue = queue
    }

    deinit { stop() }

    public func start() {
        refresh()
        // 监听父目录(stats-cache.json 所在目录),只过滤目标文件事件
        let parent = url.deletingLastPathComponent()
        let pathsToWatch = [parent.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let tracker = Unmanaged<UsageTracker>.fromOpaque(info).takeUnretainedValue()
            tracker.refresh()
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    public func refresh() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let parsed = try? Self.parse(data, date: Self.todayString()) else { return }
        DispatchQueue.main.async { [weak self] in self?.usage = parsed }
    }

    /// 纯函数:解析 stats-cache.json 内容,聚合指定日期的数据。
    /// 若 `date` 在缓存中缺失,回落到 dailyActivity 中最近的一天(stats-cache.json
    /// 是惰性计算,可能滞后到昨天)。
    public static func parse(_ data: Data, date: String) throws -> DailyUsage {
        let raw = try JSONDecoder().decode(StatsCache.self, from: data)
        let totalCost = raw.modelUsage.values.reduce(0.0) { $0 + $1.costUSD }

        let hasRequested = raw.dailyActivity.contains(where: { $0.date == date })
            || raw.dailyModelTokens.contains(where: { $0.date == date })
        let resolvedDate: String
        if hasRequested {
            resolvedDate = date
        } else {
            let candidates = (raw.dailyActivity.map(\.date) + raw.dailyModelTokens.map(\.date))
            resolvedDate = candidates.sorted(by: >).first ?? date
        }

        let activity = raw.dailyActivity.first(where: { $0.date == resolvedDate })
        let tokens = raw.dailyModelTokens.first(where: { $0.date == resolvedDate })?
            .tokensByModel ?? [:]
        return DailyUsage(
            date: resolvedDate,
            sessionCount: activity?.sessionCount ?? 0,
            messageCount: activity?.messageCount ?? 0,
            toolCallCount: activity?.toolCallCount ?? 0,
            tokensByModel: tokens,
            totalCostUSD: totalCost
        )
    }

    public static func todayString(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    // MARK: - JSON

    private struct StatsCache: Decodable {
        let dailyActivity: [Activity]
        let dailyModelTokens: [ModelTokens]
        let modelUsage: [String: ModelUsage]
    }
    private struct Activity: Decodable {
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }
    private struct ModelTokens: Decodable {
        let date: String
        let tokensByModel: [String: Int]
    }
    private struct ModelUsage: Decodable {
        let costUSD: Double
    }
}

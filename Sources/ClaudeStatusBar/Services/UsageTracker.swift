import Foundation

public final class UsageTracker {
    private let projectsRoot: URL
    private let interval: TimeInterval
    private let publishQueue: DispatchQueue
    private let workQueue = DispatchQueue(label: "ClaudeStatusBar.UsageTracker", qos: .utility)
    private var timer: DispatchSourceTimer?

    @Published public private(set) var lifetimeByModel: [ModelLifetimeUsage] = []
    @Published public private(set) var currentWindow: RollingWindow? = nil

    public init(
        projectsRoot: URL = LiveUsageAggregator.defaultProjectsRoot,
        interval: TimeInterval = 30.0,
        publishQueue: DispatchQueue = .main
    ) {
        self.projectsRoot = projectsRoot
        self.interval = interval
        self.publishQueue = publishQueue
    }

    deinit { stop() }

    public func start() {
        refresh()
        let t = DispatchSource.makeTimerSource(queue: workQueue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func refresh() {
        let projectsRoot = self.projectsRoot
        let publishQueue = self.publishQueue
        workQueue.async { [weak self] in
            let lifetime = LiveUsageAggregator.aggregate(from: projectsRoot)
            let window = RollingWindowAggregator.currentWindow(now: Date(), projectsRoot: projectsRoot)
            publishQueue.async { [weak self] in
                self?.lifetimeByModel = lifetime
                self?.currentWindow = window
            }
        }
    }
}

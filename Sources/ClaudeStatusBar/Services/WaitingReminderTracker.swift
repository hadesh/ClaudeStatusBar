import Foundation

public struct WaitingReminderTracker {
    public struct Config: Equatable {
        public let initialDelay: TimeInterval
        public let interval: TimeInterval
        public let maxReminders: Int
        public init(initialDelay: TimeInterval, interval: TimeInterval, maxReminders: Int) {
            self.initialDelay = initialDelay
            self.interval = interval
            self.maxReminders = maxReminders
        }
        public static let `default` = Config(initialDelay: 30, interval: 30, maxReminders: 3)
    }

    private let config: Config
    private var state: [Int: PerPid] = [:]

    private struct PerPid {
        let firstSeenAt: Date
        var lastNotifiedAt: Date?
        var remindersFired: Int
    }

    public init(config: Config = .default) {
        self.config = config
    }

    public mutating func tick(sessions: [Session], now: Date) -> [Session] {
        let waitingPids = Set(sessions.filter { $0.status == .waiting }.map(\.pid))
        state = state.filter { waitingPids.contains($0.key) }
        for s in sessions where s.status == .waiting && state[s.pid] == nil {
            state[s.pid] = PerPid(firstSeenAt: now, lastNotifiedAt: nil, remindersFired: 0)
        }
        return []
    }
}

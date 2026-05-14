import Foundation

public struct RollingWindow: Equatable {
    public let startedAt: Date
    public let resetsAt: Date
    public let inputTokens: Int
    public let outputTokens: Int

    public init(startedAt: Date, resetsAt: Date, inputTokens: Int, outputTokens: Int) {
        self.startedAt = startedAt
        self.resetsAt = resetsAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public var totalTokens: Int { inputTokens + outputTokens }

    public func remaining(now: Date) -> TimeInterval {
        max(0, resetsAt.timeIntervalSince(now))
    }
}

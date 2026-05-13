import Foundation

public struct DailyUsage: Equatable {
    public let date: String
    public let sessionCount: Int
    public let messageCount: Int
    public let toolCallCount: Int
    public let tokensByModel: [String: Int]
    public let totalCostUSD: Double

    public var totalTokens: Int { tokensByModel.values.reduce(0, +) }

    public static let empty = DailyUsage(
        date: "", sessionCount: 0, messageCount: 0, toolCallCount: 0,
        tokensByModel: [:], totalCostUSD: 0
    )
}

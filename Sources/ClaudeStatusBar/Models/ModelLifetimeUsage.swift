import Foundation

public struct ModelLifetimeUsage: Equatable {
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double

    public init(model: String, inputTokens: Int, outputTokens: Int, costUSD: Double) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }

    /// 用于 share% 计算与排序的合成值。
    public var combined: Int { inputTokens + outputTokens }
}

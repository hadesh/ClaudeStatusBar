import Foundation

public struct SessionDetails: Equatable {
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int

    public init(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    /// 当前对话占据的上下文 token 数(本轮请求的所有输入 = 历史 + 系统消息)。
    public var contextTokens: Int {
        inputTokens + cacheReadTokens + cacheCreationTokens
    }

    public var contextWindow: Int {
        Self.contextWindow(forModel: model)
    }

    /// 不做 cap — 真超过 1.0 就让它超出,提示模型→窗口表需要更新。
    public var usageRatio: Double {
        guard contextWindow > 0 else { return 0 }
        return Double(contextTokens) / Double(contextWindow)
    }

    /// 模型名 → 上下文窗口大小。表过时就在这里改。
    public static func contextWindow(forModel model: String) -> Int {
        let m = model.lowercased()
        if m.contains("opus-4") || m.contains("sonnet-4") { return 1_000_000 }
        if m.contains("haiku-4") { return 200_000 }
        // Claude 3.x、claude-2 系列都是 200K
        return 200_000
    }
}

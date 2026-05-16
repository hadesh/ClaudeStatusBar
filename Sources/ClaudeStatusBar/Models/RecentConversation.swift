import Foundation

public struct RecentConversation: Equatable {
    public let sessionId: String
    public let firstPrompt: String  // 已截断
    public let modifiedAt: Date     // jsonl 文件 mtime
    public let jsonlURL: URL

    public init(
        sessionId: String,
        firstPrompt: String,
        modifiedAt: Date,
        jsonlURL: URL
    ) {
        self.sessionId = sessionId
        self.firstPrompt = firstPrompt
        self.modifiedAt = modifiedAt
        self.jsonlURL = jsonlURL
    }
}

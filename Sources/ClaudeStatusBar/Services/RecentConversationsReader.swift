import Foundation

/// 同 cwd 下的历史会话摘要 reader. 用于 fresh session 行的「恢复上次会话」子菜单.
///
/// 对仗 SessionContextReader: 后者反向扫拿"最新" prompt + lastTool 给运行中的会话用,
/// 本 reader 顺序扫拿"最早" prompt 给一个 fresh session 看历史. 两个方向反过来不能复用.
public enum RecentConversationsReader {

    public static let maxFileBytes: Int = 100 * 1024 * 1024
    public static let defaultLimit: Int = 5
    public static let promptMaxChars: Int = 80

    /// 顺序扫描 JSONL, 返回第一条 type=user, content 为非空 string 的消息内容.
    /// 截断到 promptMaxChars + "…".  array(tool_result)形态的 user 消息跳过, 损坏 JSON 行跳过.
    public static func parseFirstPrompt(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(UserEntry.self, from: lineData),
                  entry.type == "user",
                  case .string(let s) = entry.message?.content ?? .array,
                  !s.isEmpty
            else { continue }
            return truncate(s, max: promptMaxChars)
        }
        return nil
    }

    // MARK: - Private helpers

    private static func truncate(_ s: String, max: Int) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }

    // MARK: - JSON shapes

    private struct UserEntry: Decodable {
        let type: String?
        let message: UserMessage?
    }
    private struct UserMessage: Decodable {
        let content: ContentValue?
    }
    /// user 消息的 content 可能是 string 或 array (tool_result 形态).
    /// 我们只关心 string; array 整体当作"无效 prompt", 继续扫下一条.
    private enum ContentValue: Decodable {
        case string(String)
        case array
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            self = .array
        }
    }
}

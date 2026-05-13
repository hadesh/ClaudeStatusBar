import Foundation

public enum SessionDetailsReader {
    public static let defaultProjectsRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }()

    /// 把 cwd 编码成 ~/.claude/projects/ 下的子目录名。
    /// 规则:所有非字母数字字符替换为 `-`(包含 /、_、. 等)。
    public static func encodeProjectPath(_ cwd: String) -> String {
        cwd.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "-"
        }.joined()
    }

    /// 读取指定会话最近一次的 assistant 消息,提取 model + usage。
    public static func read(
        cwd: String,
        sessionId: String,
        projectsRoot: URL = defaultProjectsRoot
    ) -> SessionDetails? {
        guard let url = locateJsonl(
            cwd: cwd, sessionId: sessionId, projectsRoot: projectsRoot
        ) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseLastAssistantUsage(data)
    }

    /// 纯函数:从 JSONL 字节流反向扫描,返回第一条带 usage 的 assistant 消息。
    public static func parseLastAssistantUsage(_ data: Data) -> SessionDetails? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(JSONLEntry.self, from: lineData),
                  entry.type == "assistant",
                  let msg = entry.message,
                  let usage = msg.usage
            else { continue }
            return SessionDetails(
                model: msg.model ?? "(未知)",
                inputTokens: usage.input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0,
                cacheReadTokens: usage.cache_read_input_tokens ?? 0,
                cacheCreationTokens: usage.cache_creation_input_tokens ?? 0
            )
        }
        return nil
    }

    private static func locateJsonl(
        cwd: String, sessionId: String, projectsRoot: URL
    ) -> URL? {
        let projectDir = projectsRoot.appendingPathComponent(encodeProjectPath(cwd))
        let direct = projectDir.appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // 兼容子目录布局:{projectDir}/{sessionId}/*.jsonl
        let subdir = projectDir.appendingPathComponent(sessionId)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: subdir, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.first { $0.pathExtension == "jsonl" }
    }

    private struct JSONLEntry: Decodable {
        let type: String?
        let message: JSONLMessage?
    }
    private struct JSONLMessage: Decodable {
        let model: String?
        let usage: JSONLUsage?
    }
    private struct JSONLUsage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
    }
}

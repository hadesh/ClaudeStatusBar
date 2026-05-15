import Foundation

public struct SessionContext: Equatable {
    public let recentPrompt: String?
    public let lastTool: String?
    public init(recentPrompt: String?, lastTool: String?) {
        self.recentPrompt = recentPrompt
        self.lastTool = lastTool
    }
}

/// 反扫 jsonl 拿「最近 user prompt + 最后一次 tool_use」。SessionDetailsReader
/// 的兄弟工具,但目标字段不同 —— SessionDetailsReader 取 model + token usage。
/// 同样保持纯静态:测试构造内存数据 / 临时目录 fixture 直接调静态方法。
public enum SessionContextReader {

    /// jsonl 文件大小超过此阈值时跳过(避免阻塞 30s 定时器)。
    public static let maxFileBytes: Int = 100 * 1024 * 1024

    public static func read(
        cwd: String,
        sessionId: String,
        projectsRoot: URL = SessionDetailsReader.defaultProjectsRoot
    ) -> SessionContext? {
        guard let url = locateJsonl(cwd: cwd, sessionId: sessionId, projectsRoot: projectsRoot)
        else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size <= maxFileBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// 纯函数版:从 JSONL 字节流反向扫描。先反扫拿 lastTool,继续反扫拿 recentPrompt
    /// (跳过 tool_result 形态的 user 消息)。
    public static func parse(_ data: Data) -> SessionContext {
        guard let text = String(data: data, encoding: .utf8) else {
            return SessionContext(recentPrompt: nil, lastTool: nil)
        }
        let decoder = JSONDecoder()

        var recentPrompt: String?
        var lastTool: String?

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let lineData = String(line).data(using: .utf8) else { continue }
            // user message: 最近一条 string-content
            if recentPrompt == nil,
               let entry = try? decoder.decode(UserEntry.self, from: lineData),
               entry.type == "user",
               case .string(let s) = entry.message?.content ?? .array([]),
               !s.isEmpty
            {
                recentPrompt = truncate(s, max: 50)
                if lastTool != nil { break }
                continue
            }
            // assistant tool_use: 最近一条
            if lastTool == nil,
               let entry = try? decoder.decode(AssistantEntry.self, from: lineData),
               entry.type == "assistant",
               let block = entry.message?.content?.first(where: { $0.type == "tool_use" })
            {
                lastTool = formatTool(name: block.name ?? "?", input: block.input)
                if recentPrompt != nil { break }
            }
        }
        return SessionContext(recentPrompt: recentPrompt, lastTool: lastTool)
    }

    // MARK: - Private

    private static func locateJsonl(cwd: String, sessionId: String, projectsRoot: URL) -> URL? {
        let projectDir = projectsRoot.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath(cwd)
        )
        let direct = projectDir.appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let subdir = projectDir.appendingPathComponent(sessionId)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: subdir, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.first { $0.pathExtension == "jsonl" }
    }

    private static func truncate(_ s: String, max: Int) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }

    private static func formatTool(name: String, input: [String: AnyCodable]?) -> String {
        switch name {
        case "Bash":
            if let cmd = input?["command"]?.stringValue {
                return "Bash: " + truncate(cmd, max: 60)
            }
            return name
        case "Edit", "Write", "NotebookEdit", "Read":
            if let path = input?["file_path"]?.stringValue {
                return "\(name): \((path as NSString).lastPathComponent)"
            }
            return name
        default:
            return name
        }
    }

    // MARK: - JSON 结构

    private struct UserEntry: Decodable {
        let type: String?
        let message: UserMessage?
    }
    private struct UserMessage: Decodable {
        let content: ContentValue?
    }
    /// user message 的 content 可能是 string 或 array(tool_result 形态)。
    /// 我们只关心 string;array 整体丢弃。
    private enum ContentValue: Decodable {
        case string(String)
        case array([AnyCodable])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let a = try? c.decode([AnyCodable].self) { self = .array(a); return }
            self = .array([])
        }
    }

    private struct AssistantEntry: Decodable {
        let type: String?
        let message: AssistantMessage?
    }
    private struct AssistantMessage: Decodable {
        let content: [AssistantBlock]?
    }
    private struct AssistantBlock: Decodable {
        let type: String?
        let name: String?
        let input: [String: AnyCodable]?
    }

    /// 轻量 JSONValue:够拿 string,其他类型保留以便 decode 不失败。
    public struct AnyCodable: Decodable {
        public let stringValue: String?
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { stringValue = nil; return }
            if let s = try? c.decode(String.self) { stringValue = s; return }
            // 数字/布尔/对象/数组都不是我们要的字符串字段,忽略。
            stringValue = nil
        }
    }
}

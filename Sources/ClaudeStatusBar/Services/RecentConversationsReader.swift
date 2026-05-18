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
    /// 截断到 promptMaxChars + "…".  跳过:array(tool_result)形态的 user 消息,
    /// 损坏 JSON 行, CLI 注入的伪 user 消息(`!` 命令副作用 / slash command / stdout 等).
    public static func parseFirstPrompt(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(UserEntry.self, from: lineData),
                  entry.type == "user",
                  case .string(let s) = entry.message?.content ?? .array,
                  !s.isEmpty,
                  !looksLikeCliInjection(s)
            else { continue }
            return truncate(s, max: promptMaxChars)
        }
        return nil
    }

    /// 读 cwd 对应 projects 目录下的历史会话, 按 mtime 倒序返回前 limit 个有效项.
    /// 扁平布局: `<projectDir>/<sessionId>.jsonl`;
    /// 子目录布局: `<projectDir>/<sessionId>/<anything>.jsonl`(取 mtime 最新的一个).
    public static func read(
        cwd: String,
        excluding sessionId: String?,
        limit: Int = defaultLimit,
        projectsRoot: URL = SessionDetailsReader.defaultProjectsRoot
    ) -> [RecentConversation] {
        let projectDir = projectsRoot.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath(cwd)
        )
        let candidates = collectCandidates(in: projectDir, excluding: sessionId)
        let sorted = candidates.sorted { $0.modifiedAt > $1.modifiedAt }
        var result: [RecentConversation] = []
        for c in sorted {
            if result.count >= limit { break }
            guard let prompt = parseFile(at: c.url) else { continue }
            result.append(RecentConversation(
                sessionId: c.sessionId,
                firstPrompt: prompt,
                modifiedAt: c.modifiedAt,
                jsonlURL: c.url
            ))
        }
        return result
    }

    // MARK: - private file walking

    private struct Candidate {
        let url: URL
        let sessionId: String
        let modifiedAt: Date
    }

    private static func collectCandidates(in projectDir: URL, excluding: String?) -> [Candidate] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return [] }

        var result: [Candidate] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if let c = candidateFromSubdirectory(entry, excluding: excluding) {
                    result.append(c)
                }
            } else if entry.pathExtension == "jsonl" {
                let stem = entry.deletingPathExtension().lastPathComponent
                if let excluding, stem == excluding { continue }
                guard let mt = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                else { continue }
                result.append(Candidate(url: entry, sessionId: stem, modifiedAt: mt))
            }
        }
        return result
    }

    /// 子目录布局: dir 名即 sessionId, 取里面 mtime 最新的一个 *.jsonl 当代表.
    private static func candidateFromSubdirectory(_ dir: URL, excluding: String?) -> Candidate? {
        let dirName = dir.lastPathComponent
        if let excluding, dirName == excluding { return nil }
        guard let inner = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        var best: (URL, Date)?
        for f in inner where f.pathExtension == "jsonl" {
            guard let mt = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            else { continue }
            if best == nil || mt > best!.1 { best = (f, mt) }
        }
        guard let (url, mt) = best else { return nil }
        return Candidate(url: url, sessionId: dirName, modifiedAt: mt)
    }

    private static func parseFile(at url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size <= maxFileBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseFirstPrompt(data)
    }

    // MARK: - Private helpers

    private static func truncate(_ s: String, max: Int) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }

    /// CLI 把 `!` 命令副作用、slash command、命令 stdout 都以 type=user 注入 jsonl,
    /// 用一组已知尖括号标签包裹. 这些不是用户主动发起的对话, 在子菜单里展示是杂讯.
    /// 用户实际打字的 prompt 不会以这些前缀开头.
    private static func looksLikeCliInjection(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "<local-command-",   // local-command-caveat / local-command-stdout / local-command-stderr
            "<command-name>",    // slash command 调用
            "<command-message>",
            "<command-args>",
            "<system-reminder>",
            "<bash-input>",
            "<bash-stdout>",
            "<bash-stderr>",
        ]
        return prefixes.contains(where: { trimmed.hasPrefix($0) })
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

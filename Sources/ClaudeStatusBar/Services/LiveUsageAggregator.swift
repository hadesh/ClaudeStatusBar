import Foundation

/// 从 ~/.claude/projects/**/*.jsonl 实时聚合每个模型的累计 token 用量。
/// 用来弥补 ~/.claude/stats-cache.json 的滞后(`lastComputedDate` 可能是昨天)。
public enum LiveUsageAggregator {
    public static let defaultProjectsRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }()

    public static func aggregate(from projectsRoot: URL = defaultProjectsRoot) -> [ModelLifetimeUsage] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var totals: [String: (inTok: Int, outTok: Int)] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            accumulate(file: url, into: &totals)
        }

        return totals
            .filter { !$0.key.hasPrefix("<") && ($0.value.inTok + $0.value.outTok) > 0 }
            .map { (model, t) in
                ModelLifetimeUsage(
                    model: model, inputTokens: t.inTok, outputTokens: t.outTok, costUSD: 0
                )
            }
            .sorted { $0.combined > $1.combined }
    }

    private static func accumulate(
        file url: URL, into totals: inout [String: (inTok: Int, outTok: Int)]
    ) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(JSONLEntry.self, from: lineData),
                  entry.type == "assistant",
                  let model = entry.message?.model,
                  let usage = entry.message?.usage else { continue }
            let cur = totals[model, default: (0, 0)]
            totals[model] = (
                cur.inTok + (usage.input_tokens ?? 0),
                cur.outTok + (usage.output_tokens ?? 0)
            )
        }
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
    }
}

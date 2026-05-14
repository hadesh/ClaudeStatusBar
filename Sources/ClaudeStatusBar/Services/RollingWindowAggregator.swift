import Foundation

public enum RollingWindowAggregator {
    public static let windowDuration: TimeInterval = 5 * 60 * 60

    public static let defaultProjectsRoot: URL = LiveUsageAggregator.defaultProjectsRoot

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Returns the current 5-hour rolling window or nil if no assistant activity has happened
    /// in the last 5 hours. The block's `startedAt` is the earliest assistant message inside
    /// the window; `resetsAt` is `startedAt + 5h`.
    public static func currentWindow(
        now: Date = Date(),
        projectsRoot: URL = defaultProjectsRoot
    ) -> RollingWindow? {
        let cutoff = now.addingTimeInterval(-windowDuration)
        let entries = collectEntries(since: cutoff, projectsRoot: projectsRoot)
        guard !entries.isEmpty else { return nil }
        let blockStart = entries.map(\.timestamp).min() ?? cutoff
        let inputTokens = entries.reduce(0) { $0 + $1.inputTokens }
        let outputTokens = entries.reduce(0) { $0 + $1.outputTokens }
        return RollingWindow(
            startedAt: blockStart,
            resetsAt: blockStart.addingTimeInterval(windowDuration),
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    private struct Entry {
        let timestamp: Date
        let inputTokens: Int
        let outputTokens: Int
    }

    private static func collectEntries(since cutoff: Date, projectsRoot: URL) -> [Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var entries: [Entry] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            collect(file: url, cutoff: cutoff, into: &entries)
        }
        return entries
    }

    private static func collect(file url: URL, cutoff: Date, into entries: inout [Entry]) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let raw = try? decoder.decode(JSONLEntry.self, from: lineData),
                  raw.type == "assistant",
                  let tsStr = raw.timestamp,
                  let ts = isoFormatter.date(from: tsStr),
                  ts >= cutoff,
                  let usage = raw.message?.usage else { continue }
            entries.append(Entry(
                timestamp: ts,
                inputTokens: usage.input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0
            ))
        }
    }

    private struct JSONLEntry: Decodable {
        let type: String?
        let timestamp: String?
        let message: JSONLMessage?
    }
    private struct JSONLMessage: Decodable {
        let usage: JSONLUsage?
    }
    private struct JSONLUsage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
    }
}

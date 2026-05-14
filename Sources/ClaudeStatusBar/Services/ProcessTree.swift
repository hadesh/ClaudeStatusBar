import Foundation

/// Reads a process's parent pid and short executable name via `/bin/ps`. Untested wrapper —
/// used only as the production `processInfo` source for `TerminalNavigator`. The pure logic
/// that consumes it is tested separately with an injectable closure.
public enum ProcessTree {
    public static func info(pid: Int) -> (parent: Int, name: String)? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-o", "ppid=,ucomm=", "-p", String(pid)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // Format: "  1234 zsh"  — leading spaces, ppid, single space, ucomm.
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let parent = Int(parts[0]) else { return nil }
        return (parent: parent, name: String(parts[1]).trimmingCharacters(in: .whitespaces))
    }
}

import Foundation

/// Pure transformation: PermissionRequest hook stdin payload → stdout payload.
/// Returning `nil` means "write nothing" — Claude Code will fall back to the
/// terminal prompt (the hook racing against the UI prompt: first response wins).
public enum HookProcessor {
    public typealias SocketCall = (_ requestLine: Data) -> Data?

    public static func process(input: Data, socketCall: SocketCall) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: input),
              let payload = parsed as? [String: Any],
              let toolName = payload["tool_name"] as? String
        else { return nil }

        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let sessionId = payload["session_id"] as? String
        let cwd = payload["cwd"] as? String

        let id = UUID().uuidString
        var socketRequest: [String: Any] = [
            "id": id,
            "toolName": toolName,
            "input": toolInput,
        ]
        if let sid = sessionId, !sid.isEmpty {
            socketRequest["sessionId"] = sid
        }
        if let cwd, !cwd.isEmpty {
            socketRequest["cwd"] = cwd
        }

        guard let requestLine = try? JSONSerialization.data(withJSONObject: socketRequest),
              let responseLine = socketCall(requestLine),
              let respObj = try? JSONSerialization.jsonObject(with: responseLine),
              var response = respObj as? [String: Any]
        else { return nil }

        response.removeValue(forKey: "id")
        let raw = response["behavior"] as? String ?? ""
        let allowOnce = raw == "allow"
        let allowAlways = raw == "allow_always"
        let isAllow = allowOnce || allowAlways

        var decision: [String: Any] = ["behavior": isAllow ? "allow" : "deny"]
        if isAllow {
            if let updated = response["updatedInput"] as? [String: Any] {
                decision["updatedInput"] = updated
            }
            if allowAlways {
                decision["updatedPermissions"] = sessionAllowRule(
                    toolName: toolName, toolInput: toolInput
                )
            }
        } else {
            decision["message"] = (response["message"] as? String) ?? "Denied via status bar"
        }

        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: output)
    }

    /// Builds a session-scoped `updatedPermissions` payload that allow-lists
    /// the current tool invocation for the rest of this CLI session. For Bash
    /// we pin to the exact command string (Claude Code's matcher takes the
    /// command as ruleContent). For other tools we omit ruleContent — meaning
    /// "any input for this tool, just for this session" — because each tool
    /// has its own ruleContent grammar and we don't want to silently mis-match.
    private static func sessionAllowRule(toolName: String, toolInput: [String: Any]) -> [[String: Any]] {
        var rule: [String: Any] = ["toolName": toolName]
        if toolName == "Bash", let command = toolInput["command"] as? String, !command.isEmpty {
            rule["ruleContent"] = command
        }
        return [[
            "type": "addRules",
            "behavior": "allow",
            "destination": "session",
            "rules": [rule],
        ]]
    }
}

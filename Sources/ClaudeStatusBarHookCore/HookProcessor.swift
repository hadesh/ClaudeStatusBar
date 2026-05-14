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
        let behavior = (response["behavior"] as? String) == "allow" ? "allow" : "deny"

        var decision: [String: Any] = ["behavior": behavior]
        if behavior == "allow" {
            if let updated = response["updatedInput"] as? [String: Any] {
                decision["updatedInput"] = updated
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
}

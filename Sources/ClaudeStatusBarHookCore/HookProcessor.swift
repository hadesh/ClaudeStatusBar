import Foundation

/// Pure transformation: hook stdin payload → stdout payload.
/// 按 `hook_event_name` 分流到两条路径:
///   1. `PermissionRequest`(默认 / 兼容旧版)— 现有的「按工具问用户允许/拒绝」走这里。
///      **特殊**: tool_name == AskUserQuestion 时直接 allow,不发 socket;CLI 的
///      AskUserQuestion 应答路径走 PreToolUse,这里再弹浮窗会重复问且没语义。
///   2. `PreToolUse`(matcher: AskUserQuestion)— 在浮窗里收答案,通过 `updatedInput`
///      把 `{questions, answers, annotations?}` 直接塞回 CLI(Claude Code 2.1.85+
///      的 short-circuit 路径,见 ~/.claude/cache/changelog.md:1212)。
///
/// Returning `nil` 表示"不写 stdout" — Claude Code 会 fallback 到终端 prompt。
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
        // 缺省视为 PermissionRequest — 老版本 Claude Code 的 hook payload 里
        // 没有 hook_event_name 字段,我们靠它分流前必须保留旧行为。
        let eventName = (payload["hook_event_name"] as? String) ?? "PermissionRequest"

        switch eventName {
        case "PreToolUse":
            // matcher 在 settings.json 写死 AskUserQuestion;但 helper 仍做防御。
            guard toolName == "AskUserQuestion" else { return nil }
            return processAskUserQuestion(
                toolInput: toolInput, sessionId: sessionId, cwd: cwd,
                socketCall: socketCall
            )
        case "PermissionRequest":
            // **完全不响应** AskUserQuestion 的 PermissionRequest:
            //   - 不发 socket(避免和 PreToolUse 路径重复弹浮窗)
            //   - 也**不写 "allow" envelope** — 那会让 CLI 跳过 AskUserQuestion
            //     的终端 select,导致 PreToolUse abandon(浮窗"跳回终端答")
            //     之后,用户回到终端却看不到 select,模型只收到空答复。
            // return nil 让 CLI 把 PermissionRequest 当作"hook 没决定",走默认
            // 流程:AskUserQuestion 是 built-in 工具,默认 allow → 工具执行 →
            // 终端 select 出来。
            if toolName == "AskUserQuestion" {
                return nil
            }
            return processPermissionRequest(
                toolName: toolName, toolInput: toolInput,
                sessionId: sessionId, cwd: cwd, socketCall: socketCall
            )
        default:
            return nil
        }
    }

    // MARK: - PermissionRequest 路径

    private static func processPermissionRequest(
        toolName: String, toolInput: [String: Any],
        sessionId: String?, cwd: String?, socketCall: SocketCall
    ) -> Data? {
        let id = UUID().uuidString
        var socketRequest: [String: Any] = [
            "id": id,
            "kind": "permission",
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

    // MARK: - PreToolUse / AskUserQuestion 路径

    private static func processAskUserQuestion(
        toolInput: [String: Any],
        sessionId: String?, cwd: String?, socketCall: SocketCall
    ) -> Data? {
        let id = UUID().uuidString
        var socketRequest: [String: Any] = [
            "id": id,
            "kind": "askUserQuestion",
            "toolName": "AskUserQuestion",
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
        // 用户没在浮窗里答(abandon / deny / 超时) — 让 CLI 终端 select 接管。
        let behavior = response["behavior"] as? String ?? ""
        guard behavior == "allow",
              let updated = response["updatedInput"] as? [String: Any]
        else { return nil }

        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "Answered via status bar",
                "updatedInput": updated,
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

import XCTest
@testable import ClaudeStatusBarHookCore

final class HookProcessorTests: XCTestCase {

    private static let validInput = Data(#"""
    {"session_id":"abc-123","tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"/tmp"}
    """#.utf8)

    func testForwardsToolNameInputCwdSessionIdOverSocket() throws {
        var capturedRequest: Data?
        let output = HookProcessor.process(input: Self.validInput) { req in
            capturedRequest = req
            return Data(#"{"id":"x","behavior":"allow","updatedInput":{"command":"ls -la"}}"#.utf8)
        }
        XCTAssertNotNil(output)

        let socketReq = try XCTUnwrap(
            JSONSerialization.jsonObject(with: capturedRequest!) as? [String: Any]
        )
        XCTAssertEqual(socketReq["toolName"] as? String, "Bash")
        XCTAssertEqual(socketReq["sessionId"] as? String, "abc-123")
        XCTAssertEqual(socketReq["cwd"] as? String, "/tmp")
        XCTAssertNotNil(socketReq["id"])
        XCTAssertNil(socketReq["toolUseId"], "toolUseId is leftover from MCP path; should not be forwarded")
        let input = try XCTUnwrap(socketReq["input"] as? [String: Any])
        XCTAssertEqual(input["command"] as? String, "ls -la")
    }

    func testOmitsCwdAndSessionIdWhenAbsent() throws {
        let stdin = Data(#"{"tool_name":"Read","tool_input":{}}"#.utf8)
        var captured: Data?
        _ = HookProcessor.process(input: stdin) { req in
            captured = req
            return Data(#"{"behavior":"allow"}"#.utf8)
        }
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captured!) as? [String: Any]
        )
        XCTAssertNil(parsed["cwd"])
        XCTAssertNil(parsed["sessionId"])
    }

    func testAllowEnvelopeShape() throws {
        let output = HookProcessor.process(input: Self.validInput) { _ in
            Data(#"{"id":"x","behavior":"allow","updatedInput":{"command":"ls -la"}}"#.utf8)
        }
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output!) as? [String: Any]
        )
        let hso = try XCTUnwrap(parsed["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hso["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(hso["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let updated = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["command"] as? String, "ls -la")
    }

    func testDenyEnvelopeIncludesMessage() throws {
        let output = HookProcessor.process(input: Self.validInput) { _ in
            Data(#"{"id":"x","behavior":"deny","message":"User denied via status bar"}"#.utf8)
        }
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output!) as? [String: Any]
        )
        let decision = try XCTUnwrap(
            (parsed["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "User denied via status bar")
        XCTAssertNil(decision["updatedInput"])
    }

    func testInternalIdIsStrippedFromOutput() throws {
        let output = HookProcessor.process(input: Self.validInput) { _ in
            Data(#"{"id":"internal-uuid","behavior":"allow"}"#.utf8)
        }
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output!) as? [String: Any]
        )
        let decision = try XCTUnwrap(
            (parsed["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        XCTAssertNil(decision["id"])
    }

    func testMalformedInputReturnsNil() {
        let output = HookProcessor.process(input: Data("not json".utf8)) { _ in
            XCTFail("socket should not be called for malformed input"); return nil
        }
        XCTAssertNil(output)
    }

    func testInputMissingToolNameReturnsNil() {
        let output = HookProcessor.process(input: Data(#"{"session_id":"x"}"#.utf8)) { _ in
            XCTFail("socket should not be called when tool_name is absent"); return nil
        }
        XCTAssertNil(output)
    }

    func testAppNotRunningReturnsNil() {
        // socketCall returning nil simulates the app being down. Returning nil
        // from the processor means the hook writes nothing, letting Claude's
        // terminal prompt win the race.
        let output = HookProcessor.process(input: Self.validInput) { _ in nil }
        XCTAssertNil(output)
    }

    func testUnknownBehaviorDefaultsToDeny() throws {
        let output = HookProcessor.process(input: Self.validInput) { _ in
            Data(#"{"behavior":"???"}"#.utf8)
        }
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output!) as? [String: Any]
        )
        let decision = try XCTUnwrap(
            (parsed["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        XCTAssertEqual(decision["behavior"] as? String, "deny")
    }

    func testAllowAlwaysFlattensToAllowPlusSessionRuleForBash() throws {
        let output = HookProcessor.process(input: Self.validInput) { _ in
            Data(#"{"id":"x","behavior":"allow_always","updatedInput":{"command":"ls -la"}}"#.utf8)
        }
        let decision = try XCTUnwrap(
            (try XCTUnwrap(
                JSONSerialization.jsonObject(with: output!) as? [String: Any]
            )["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        // CLI sees plain "allow" — the "always" intent rides in updatedPermissions.
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNil(decision["message"])
        let updates = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(updates.count, 1)
        let entry = updates[0]
        XCTAssertEqual(entry["type"] as? String, "addRules")
        XCTAssertEqual(entry["behavior"] as? String, "allow")
        XCTAssertEqual(entry["destination"] as? String, "session")
        let rules = try XCTUnwrap(entry["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["toolName"] as? String, "Bash")
        XCTAssertEqual(rules[0]["ruleContent"] as? String, "ls -la",
                       "Bash should pin to the exact command for 'always allow'")
    }

    func testAllowAlwaysOmitsRuleContentForNonBashTools() throws {
        let stdin = Data(#"{"tool_name":"Read","tool_input":{"file_path":"/tmp/foo"}}"#.utf8)
        let output = HookProcessor.process(input: stdin) { _ in
            Data(#"{"behavior":"allow_always"}"#.utf8)
        }
        let decision = try XCTUnwrap(
            (try XCTUnwrap(
                JSONSerialization.jsonObject(with: output!) as? [String: Any]
            )["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let rules = try XCTUnwrap(
            ((decision["updatedPermissions"] as? [[String: Any]])?.first)?["rules"] as? [[String: Any]]
        )
        XCTAssertEqual(rules[0]["toolName"] as? String, "Read")
        XCTAssertNil(rules[0]["ruleContent"],
                     "non-Bash tools have per-tool ruleContent grammars; we don't guess")
    }

    func testPlainAllowDoesNotEmitUpdatedPermissions() throws {
        let output = HookProcessor.process(input: Self.validInput) { _ in
            Data(#"{"behavior":"allow"}"#.utf8)
        }
        let decision = try XCTUnwrap(
            (try XCTUnwrap(
                JSONSerialization.jsonObject(with: output!) as? [String: Any]
            )["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        XCTAssertNil(decision["updatedPermissions"])
    }

    // MARK: - PreToolUse / AskUserQuestion 分流

    func testPreToolUseAskUserQuestionEmitsAnswerEnvelope() throws {
        let stdin = Data(#"""
        {"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"颜色?","options":[{"label":"红"},{"label":"蓝"}]}]},"session_id":"s","cwd":"/p"}
        """#.utf8)
        var capturedRequest: Data?
        let output = HookProcessor.process(input: stdin) { req in
            capturedRequest = req
            return Data(#"""
            {"id":"x","behavior":"allow","updatedInput":{"questions":[{"question":"颜色?","options":[{"label":"红"},{"label":"蓝"}]}],"answers":{"颜色?":"红"}}}
            """#.utf8)
        }

        // socket payload 标记 kind=askUserQuestion 让 listener 路由到正确 manager。
        let socketReq = try XCTUnwrap(
            JSONSerialization.jsonObject(with: capturedRequest!) as? [String: Any]
        )
        XCTAssertEqual(socketReq["kind"] as? String, "askUserQuestion")
        XCTAssertEqual(socketReq["toolName"] as? String, "AskUserQuestion")

        // stdout envelope 走 PreToolUse short-circuit schema(changelog 1212)。
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output!) as? [String: Any]
        )
        let hso = try XCTUnwrap(parsed["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hso["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hso["permissionDecision"] as? String, "allow")
        XCTAssertNotNil(hso["permissionDecisionReason"])
        let updated = try XCTUnwrap(hso["updatedInput"] as? [String: Any])
        let answers = try XCTUnwrap(updated["answers"] as? [String: Any])
        XCTAssertEqual(answers["颜色?"] as? String, "红")
        XCTAssertNotNil(updated["questions"], "原 questions 必须原样回传")
    }

    func testPreToolUseAskUserQuestionAbandonReturnsNil() {
        // 用户在浮窗里点 ✕ → store 回 nil → listener 关 fd → helper 这边
        // socketCall 也返回 nil(EOF),processor 应吐 nil 让终端 select 接管。
        let stdin = Data(#"""
        {"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}
        """#.utf8)
        let output = HookProcessor.process(input: stdin) { _ in nil }
        XCTAssertNil(output)
    }

    func testPreToolUseAskUserQuestionDenyReturnsNil() {
        // 防御:即使 socket 异常返回 deny,也别拼一个 PreToolUse deny envelope
        // 出去——直接 nil 走终端兜底更安全。
        let stdin = Data(#"""
        {"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}
        """#.utf8)
        let output = HookProcessor.process(input: stdin) { _ in
            Data(#"{"behavior":"deny","message":"bad"}"#.utf8)
        }
        XCTAssertNil(output)
    }

    func testPreToolUseNonAskUserQuestionReturnsNil() {
        // PreToolUse hook 在 settings.json 里 matcher 写死 AskUserQuestion;
        // 万一别的工具触发了(用户配错 matcher),helper 应 fallback,不发 socket。
        let stdin = Data(#"""
        {"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}
        """#.utf8)
        let output = HookProcessor.process(input: stdin) { _ in
            XCTFail("socket should not be called for non-AskUserQuestion in PreToolUse")
            return nil
        }
        XCTAssertNil(output)
    }

    func testPermissionRequestAskUserQuestionReturnsNilSoCLIFallsBackToTerminal() {
        // D2:PermissionRequest+AskUserQuestion 完全不响应。
        // 关键:**不能输出 "allow" envelope** —— 那会让 CLI 跳过 AskUserQuestion
        // 的终端 select,使「跳回终端答」逃生口失效(用户在浮窗 abandon 后,
        // 终端不出 select,模型收到空答复)。return nil 让 CLI 走默认 flow
        // (AskUserQuestion 是 built-in 工具默认 allow → 工具执行 → 终端 select)。
        let stdin = Data(#"""
        {"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}
        """#.utf8)
        let output = HookProcessor.process(input: stdin) { _ in
            XCTFail("socket should not be called for AskUserQuestion via PermissionRequest")
            return nil
        }
        XCTAssertNil(output, "AskUserQuestion via PermissionRequest must return nil, not allow envelope")
    }

    func testUnknownHookEventReturnsNil() {
        let stdin = Data(#"""
        {"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{}}
        """#.utf8)
        let output = HookProcessor.process(input: stdin) { _ in nil }
        XCTAssertNil(output)
    }

    func testPermissionRequestWithoutEventNameStillWorks() {
        // 旧版 Claude Code(2.1.85 之前)的 PermissionRequest hook 不写
        // hook_event_name,缺省解释为 PermissionRequest 才能保持向后兼容。
        // 这条用例覆盖 Self.validInput 不含 hook_event_name 字段的现状。
        let output = HookProcessor.process(input: Self.validInput) { _ in
            Data(#"{"behavior":"allow"}"#.utf8)
        }
        XCTAssertNotNil(output)
    }
}

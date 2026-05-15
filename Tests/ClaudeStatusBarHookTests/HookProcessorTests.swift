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
}

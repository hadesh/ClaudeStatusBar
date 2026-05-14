import XCTest
@testable import ClaudeStatusBar

final class PermissionPromptTests: XCTestCase {

    func testRequestRoundTrip() throws {
        let raw = #"{"id":"abc","toolName":"Bash","input":{"command":"rm -rf foo","timeout":3000},"cwd":"/tmp/p","sessionId":"sess-01"}"#
        let req = try JSONDecoder().decode(PermissionPromptRequest.self, from: Data(raw.utf8))
        XCTAssertEqual(req.id, "abc")
        XCTAssertEqual(req.toolName, "Bash")
        XCTAssertEqual(req.cwd, "/tmp/p")
        XCTAssertEqual(req.sessionId, "sess-01")
        XCTAssertEqual(req.input["command"], .string("rm -rf foo"))
        XCTAssertEqual(req.input["timeout"], .number(3000))

        let encoded = try JSONEncoder().encode(req)
        let again = try JSONDecoder().decode(PermissionPromptRequest.self, from: encoded)
        XCTAssertEqual(again, req)
    }

    func testRequestOptionalFieldsCanBeNil() throws {
        let raw = #"{"id":"x","toolName":"Read","input":{}}"#
        let req = try JSONDecoder().decode(PermissionPromptRequest.self, from: Data(raw.utf8))
        XCTAssertNil(req.cwd)
        XCTAssertNil(req.sessionId)
    }

    func testAllowDecisionEncodesUpdatedInput() throws {
        let d = PermissionPromptDecision.allow(id: "x", input: ["command": .string("ls")])
        let data = try JSONEncoder().encode(d)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["behavior"] as? String, "allow")
        XCTAssertEqual((obj["updatedInput"] as? [String: Any])?["command"] as? String, "ls")
        XCTAssertNil(obj["message"])
    }

    func testDenyDecisionEncodesMessage() throws {
        let d = PermissionPromptDecision.deny(id: "x", message: "no thanks")
        let data = try JSONEncoder().encode(d)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["behavior"] as? String, "deny")
        XCTAssertEqual(obj["message"] as? String, "no thanks")
        XCTAssertNil(obj["updatedInput"])
    }

    func testJSONValueSupportsNestedShapes() throws {
        let raw = #"{"a":[1,2,3],"b":{"nested":true},"c":null,"d":"s"}"#
        let v = try JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8))
        XCTAssertEqual(v["a"], .array([.number(1), .number(2), .number(3)]))
        XCTAssertEqual(v["b"], .object(["nested": .bool(true)]))
        XCTAssertEqual(v["c"], .null)
        XCTAssertEqual(v["d"], .string("s"))
    }
}

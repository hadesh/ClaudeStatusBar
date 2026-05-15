import Foundation

public enum JSONValue: Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// Helper → app: a single permission request awaiting user decision.
public struct PermissionPromptRequest: Codable, Equatable {
    public let id: String
    public let toolName: String
    public let input: [String: JSONValue]
    /// Working directory of the originating CLI session, used to derive a
    /// human-friendly session name for the panel.
    public let cwd: String?
    /// Stable Claude Code session UUID. Surfaced as a short suffix on the
    /// panel so concurrent sessions for the same project can be told apart.
    public let sessionId: String?

    public init(
        id: String,
        toolName: String,
        input: [String: JSONValue],
        cwd: String? = nil,
        sessionId: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.input = input
        self.cwd = cwd
        self.sessionId = sessionId
    }
}

/// App → helper: the user's decision (or auto-deny on timeout).
public struct PermissionPromptDecision: Codable, Equatable {
    public enum Behavior: String, Codable {
        case allow
        case deny
        /// 允许并要求 helper 在输出里附带一条 session-scoped 的 addRules,本次会话内
        /// 后续相同调用直接放行。最终 CLI 看到的 `decision.behavior` 仍是 "allow"。
        case allowAlways = "allow_always"
    }
    public let id: String
    public let behavior: Behavior
    public let updatedInput: [String: JSONValue]?
    public let message: String?

    public init(id: String, behavior: Behavior, updatedInput: [String: JSONValue]? = nil, message: String? = nil) {
        self.id = id
        self.behavior = behavior
        self.updatedInput = updatedInput
        self.message = message
    }

    public static func allow(id: String, input: [String: JSONValue]) -> Self {
        .init(id: id, behavior: .allow, updatedInput: input, message: nil)
    }

    public static func allowAlways(id: String, input: [String: JSONValue]) -> Self {
        .init(id: id, behavior: .allowAlways, updatedInput: input, message: nil)
    }

    public static func deny(id: String, message: String) -> Self {
        .init(id: id, behavior: .deny, updatedInput: nil, message: message)
    }
}

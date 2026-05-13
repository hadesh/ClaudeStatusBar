import Foundation

public enum SessionStatus: String, Codable {
    case idle
    case busy
    case waiting
}

public struct Session: Codable, Identifiable, Equatable {
    public let pid: Int
    public let sessionId: String
    public let cwd: String
    public let version: String
    public let kind: String
    public let entrypoint: String
    public let startedAt: Date
    public var updatedAt: Date
    public var status: SessionStatus
    public var waitingFor: String?

    public var id: Int { pid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int.self, forKey: .pid)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try c.decode(String.self, forKey: .cwd)
        version = try c.decode(String.self, forKey: .version)
        kind = try c.decode(String.self, forKey: .kind)
        entrypoint = try c.decode(String.self, forKey: .entrypoint)
        status = try c.decode(SessionStatus.self, forKey: .status)
        waitingFor = try c.decodeIfPresent(String.self, forKey: .waitingFor)
        startedAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .startedAt) / 1000)
        updatedAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .updatedAt) / 1000)
    }

    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, version, kind, entrypoint
        case startedAt, updatedAt, status, waitingFor
    }
}

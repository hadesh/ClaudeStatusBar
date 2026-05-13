import Foundation
import Combine

public enum AggregateStatus: Equatable {
    case none
    case idle
    case working
    case needsAttention
}

public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [Session] = []

    public init() {}

    public var aggregateStatus: AggregateStatus {
        if sessions.isEmpty { return .none }
        if sessions.contains(where: { $0.status == .waiting }) { return .needsAttention }
        if sessions.contains(where: { $0.status == .busy }) { return .working }
        return .idle
    }

    public func upsert(_ session: Session) {
        if let i = sessions.firstIndex(where: { $0.pid == session.pid }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
    }

    public func remove(pid: Int) {
        sessions.removeAll { $0.pid == pid }
    }

    public func replaceAll(with newSessions: [Session]) {
        sessions = newSessions
    }
}

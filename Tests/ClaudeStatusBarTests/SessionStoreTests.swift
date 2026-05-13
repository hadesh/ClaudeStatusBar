import XCTest
@testable import ClaudeStatusBar

final class SessionStoreTests: XCTestCase {

    private func makeSession(pid: Int, status: SessionStatus, cwd: String = "/x") -> Session {
        let json = """
        {"pid":\(pid),"sessionId":"s\(pid)","cwd":"\(cwd)","startedAt":0,"version":"v","kind":"interactive","entrypoint":"cli","status":"\(status.rawValue)","updatedAt":0}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    func testEmptyStoreAggregateIsNone() {
        let store = SessionStore()
        XCTAssertEqual(store.aggregateStatus, .none)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testAllIdleAggregateIsIdle() {
        let store = SessionStore()
        store.upsert(makeSession(pid: 1, status: .idle))
        store.upsert(makeSession(pid: 2, status: .idle))
        XCTAssertEqual(store.aggregateStatus, .idle)
    }

    func testAnyBusyAggregateIsWorking() {
        let store = SessionStore()
        store.upsert(makeSession(pid: 1, status: .idle))
        store.upsert(makeSession(pid: 2, status: .busy))
        XCTAssertEqual(store.aggregateStatus, .working)
    }

    func testWaitingTrumpsBusy() {
        let store = SessionStore()
        store.upsert(makeSession(pid: 1, status: .busy))
        store.upsert(makeSession(pid: 2, status: .waiting))
        XCTAssertEqual(store.aggregateStatus, .needsAttention)
    }

    func testUpsertReplacesByPid() {
        let store = SessionStore()
        store.upsert(makeSession(pid: 1, status: .idle))
        store.upsert(makeSession(pid: 1, status: .busy))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].status, .busy)
    }

    func testRemoveByPid() {
        let store = SessionStore()
        store.upsert(makeSession(pid: 1, status: .busy))
        store.upsert(makeSession(pid: 2, status: .idle))
        store.remove(pid: 1)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].pid, 2)
    }

    func testReplaceAllSetsExactSet() {
        let store = SessionStore()
        store.upsert(makeSession(pid: 1, status: .busy))
        store.upsert(makeSession(pid: 2, status: .idle))
        store.replaceAll(with: [makeSession(pid: 3, status: .waiting)])
        XCTAssertEqual(store.sessions.map(\.pid), [3])
        XCTAssertEqual(store.aggregateStatus, .needsAttention)
    }
}

import XCTest
import Combine
@testable import ClaudeStatusBar

final class PermissionPromptStoreTests: XCTestCase {

    private func makeRequest(id: String) -> PermissionPromptRequest {
        PermissionPromptRequest(id: id, toolName: "Bash", input: ["command": .string("ls")])
    }

    private func noopScheduler(_ a: TimeInterval, _ b: @escaping () -> Void) -> () -> Void {
        return {}
    }

    func testAddPublishesRequest() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var seen: [PermissionPromptRequest] = []
        let sub = store.incoming.sink { seen.append($0) }
        defer { sub.cancel() }
        store.add(makeRequest(id: "a")) { _ in }
        XCTAssertEqual(seen.map(\.id), ["a"])
    }

    func testResolveFiresReplyHandlerExactlyOnce() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var calls: [PermissionPromptDecision] = []
        store.add(makeRequest(id: "a")) { calls.append($0) }
        store.resolve(id: "a", decision: .allow(id: "a", input: [:]))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].behavior, .allow)
    }

    func testResolveRemovesFromPending() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        store.add(makeRequest(id: "a")) { _ in }
        XCTAssertEqual(store.pendingIds, ["a"])
        store.resolve(id: "a", decision: .allow(id: "a", input: [:]))
        XCTAssertEqual(store.pendingIds, [])
    }

    func testDoubleResolveIsNoOp() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var calls = 0
        store.add(makeRequest(id: "a")) { _ in calls += 1 }
        store.resolve(id: "a", decision: .allow(id: "a", input: [:]))
        store.resolve(id: "a", decision: .deny(id: "a", message: "x"))
        XCTAssertEqual(calls, 1)
    }

    func testResolveUnknownIdIsNoOp() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        store.resolve(id: "ghost", decision: .deny(id: "ghost", message: "x"))
        XCTAssertEqual(store.pendingIds, [])
    }

    func testTimeoutAutoDenies() {
        var fire: (() -> Void)?
        let scheduler: PermissionPromptStore.Scheduler = { _, work in
            fire = work
            return {}
        }
        let store = PermissionPromptStore(timeout: 300, scheduler: scheduler)
        var captured: PermissionPromptDecision?
        store.add(makeRequest(id: "a")) { captured = $0 }
        XCTAssertNotNil(fire, "scheduler should be invoked on add")
        fire!()
        XCTAssertEqual(captured?.behavior, .deny)
        XCTAssertNotNil(captured?.message)
        XCTAssertTrue(captured!.message!.contains("5"))
        XCTAssertEqual(store.pendingIds, [])
    }

    func testResolveCancelsTimeout() {
        var cancelCalled = false
        let scheduler: PermissionPromptStore.Scheduler = { _, _ in
            return { cancelCalled = true }
        }
        let store = PermissionPromptStore(timeout: 60, scheduler: scheduler)
        store.add(makeRequest(id: "a")) { _ in }
        store.resolve(id: "a", decision: .allow(id: "a", input: [:]))
        XCTAssertTrue(cancelCalled)
    }

    func testTimeoutDoesNotFireAfterResolve() {
        var fire: (() -> Void)?
        let scheduler: PermissionPromptStore.Scheduler = { _, work in
            fire = work
            return {}
        }
        let store = PermissionPromptStore(timeout: 60, scheduler: scheduler)
        var calls: [PermissionPromptDecision] = []
        store.add(makeRequest(id: "a")) { calls.append($0) }
        store.resolve(id: "a", decision: .allow(id: "a", input: [:]))
        fire!()
        XCTAssertEqual(calls.count, 1, "timer firing after resolve should be a no-op")
    }

    func testResolveAllowEchoesOriginalInput() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var captured: PermissionPromptDecision?
        let req = PermissionPromptRequest(
            id: "a", toolName: "Bash",
            input: ["command": .string("ls -la")]
        )
        store.add(req) { captured = $0 }
        store.resolveAllow(id: "a")
        XCTAssertEqual(captured?.behavior, .allow)
        XCTAssertEqual(captured?.updatedInput?["command"], .string("ls -la"))
    }

    func testResolveDenyShorthand() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var captured: PermissionPromptDecision?
        store.add(makeRequest(id: "a")) { captured = $0 }
        store.resolveDeny(id: "a", message: "nope")
        XCTAssertEqual(captured?.behavior, .deny)
        XCTAssertEqual(captured?.message, "nope")
    }

    func testResolvedSignalFiresOnExplicitResolve() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var seen: [String] = []
        let sub = store.resolved.sink { seen.append($0) }
        defer { sub.cancel() }
        store.add(makeRequest(id: "a")) { _ in }
        store.resolve(id: "a", decision: .deny(id: "a", message: "x"))
        XCTAssertEqual(seen, ["a"])
    }

    func testResolvedSignalFiresOnAllowAndDenyShorthands() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var seen: [String] = []
        let sub = store.resolved.sink { seen.append($0) }
        defer { sub.cancel() }
        store.add(makeRequest(id: "a")) { _ in }
        store.add(makeRequest(id: "b")) { _ in }
        store.resolveAllow(id: "a")
        store.resolveDeny(id: "b", message: "no")
        XCTAssertEqual(seen, ["a", "b"])
    }

    func testResolvedSignalFiresOnTimeout() {
        var fire: (() -> Void)?
        let scheduler: PermissionPromptStore.Scheduler = { _, work in
            fire = work; return {}
        }
        let store = PermissionPromptStore(timeout: 60, scheduler: scheduler)
        var seen: [String] = []
        let sub = store.resolved.sink { seen.append($0) }
        defer { sub.cancel() }
        store.add(makeRequest(id: "a")) { _ in }
        fire!()
        XCTAssertEqual(seen, ["a"])
    }

    func testResolvedSignalDoesNotFireOnUnknownId() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var seen: [String] = []
        let sub = store.resolved.sink { seen.append($0) }
        defer { sub.cancel() }
        store.resolveDeny(id: "ghost", message: "x")
        XCTAssertEqual(seen, [])
    }

    func testResolveAllowAlwaysEchoesInputAndUsesAllowAlwaysBehavior() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var captured: PermissionPromptDecision?
        let req = PermissionPromptRequest(
            id: "a", toolName: "Bash",
            input: ["command": .string("ls -la")]
        )
        store.add(req) { captured = $0 }
        store.resolveAllowAlways(id: "a")
        XCTAssertEqual(captured?.behavior, .allowAlways)
        XCTAssertEqual(captured?.updatedInput?["command"], .string("ls -la"))
        XCTAssertEqual(store.pendingIds, [])
    }

    func testResolveAllowAlwaysFiresResolvedSignal() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var seen: [String] = []
        let sub = store.resolved.sink { seen.append($0) }
        defer { sub.cancel() }
        store.add(makeRequest(id: "a")) { _ in }
        store.resolveAllowAlways(id: "a")
        XCTAssertEqual(seen, ["a"])
    }

    func testPendingSessionIdsTracksLiveRequests() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        let r1 = PermissionPromptRequest(id: "a", toolName: "Bash", input: [:], cwd: nil, sessionId: "sess-1")
        let r2 = PermissionPromptRequest(id: "b", toolName: "Bash", input: [:], cwd: nil, sessionId: "sess-2")
        let r3 = PermissionPromptRequest(id: "c", toolName: "Bash", input: [:], cwd: nil, sessionId: nil)
        store.add(r1) { _ in }
        store.add(r2) { _ in }
        store.add(r3) { _ in }
        XCTAssertEqual(store.pendingSessionIds(), ["sess-1", "sess-2"])
        store.resolveAllow(id: "a")
        XCTAssertEqual(store.pendingSessionIds(), ["sess-2"])
        store.resolveDeny(id: "b", message: "no")
        XCTAssertEqual(store.pendingSessionIds(), [])
    }

    func testConcurrentAddsKeepIndependentState() {
        let store = PermissionPromptStore(timeout: 1000, scheduler: noopScheduler)
        var seenA: PermissionPromptDecision?
        var seenB: PermissionPromptDecision?
        store.add(makeRequest(id: "a")) { seenA = $0 }
        store.add(makeRequest(id: "b")) { seenB = $0 }
        store.resolve(id: "b", decision: .deny(id: "b", message: "no"))
        XCTAssertNil(seenA)
        XCTAssertEqual(seenB?.behavior, .deny)
        XCTAssertEqual(store.pendingIds, ["a"])
    }
}

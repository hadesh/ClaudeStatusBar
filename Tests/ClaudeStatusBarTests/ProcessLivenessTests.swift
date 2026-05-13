import XCTest
@testable import ClaudeStatusBar

final class ProcessLivenessTests: XCTestCase {

    func testCurrentProcessIsAlive() {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(ProcessLiveness.isAlive(pid: pid))
    }

    func testInitProcessIsAlive() {
        XCTAssertTrue(ProcessLiveness.isAlive(pid: 1))
    }

    func testImpossiblePidIsDead() {
        // 99999999 是一个理论上的极大 PID,正常系统不会使用
        XCTAssertFalse(ProcessLiveness.isAlive(pid: 99_999_999))
    }
}

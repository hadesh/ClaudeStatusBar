import XCTest
import Darwin
@testable import ClaudeStatusBar

final class ProcessTerminatorTests: XCTestCase {

    override func tearDown() {
        // 任何测试改了 killFn 都恢复回真实 BSD kill,避免相互污染。
        ProcessTerminator.killFn = { Darwin.kill($0, $1) }
        super.tearDown()
    }

    func testSendInterruptCallsKillWithSIGINT() {
        var captured: (pid_t, Int32)?
        ProcessTerminator.killFn = { pid, sig in
            captured = (pid, sig)
            return 0
        }

        XCTAssertTrue(ProcessTerminator.sendInterrupt(pid: 4242))
        XCTAssertEqual(captured?.0, 4242)
        XCTAssertEqual(captured?.1, SIGINT)
    }

    func testSendInterruptRejectsNonPositivePid() {
        var called = false
        ProcessTerminator.killFn = { _, _ in
            called = true
            return 0
        }

        XCTAssertFalse(ProcessTerminator.sendInterrupt(pid: 0))
        XCTAssertFalse(ProcessTerminator.sendInterrupt(pid: -1))
        XCTAssertFalse(called, "非正 pid 时不该调用 kill")
    }

    func testSendInterruptReturnsFalseOnKillFailure() {
        ProcessTerminator.killFn = { _, _ in -1 }
        XCTAssertFalse(ProcessTerminator.sendInterrupt(pid: 1234))
    }
}

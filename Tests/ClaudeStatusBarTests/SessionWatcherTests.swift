import XCTest
@testable import ClaudeStatusBar

final class SessionWatcherTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-watcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeSession(pid: Int, status: String, into dir: URL) throws {
        let json = """
        {"pid":\(pid),"sessionId":"s\(pid)","cwd":"/tmp","startedAt":0,"version":"v","kind":"interactive","entrypoint":"cli","status":"\(status)","updatedAt":0}
        """
        try json.write(to: dir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
    }

    func testEmptyDirectoryYieldsNoSessions() {
        let result = SessionWatcher.readSessions(from: tempDir)
        XCTAssertEqual(result.count, 0)
    }

    func testNonExistentDirectoryYieldsEmpty() {
        let bogus = tempDir.appendingPathComponent("does-not-exist")
        let result = SessionWatcher.readSessions(from: bogus)
        XCTAssertEqual(result.count, 0)
    }

    func testAliveProcessIncluded() throws {
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        try writeSession(pid: livePid, status: "busy", into: tempDir)
        let result = SessionWatcher.readSessions(from: tempDir)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].pid, livePid)
        XCTAssertEqual(result[0].status, .busy)
    }

    func testDeadProcessFilteredOut() throws {
        try writeSession(pid: 99_999_999, status: "idle", into: tempDir)
        let result = SessionWatcher.readSessions(from: tempDir)
        XCTAssertTrue(result.isEmpty)
    }

    func testCorruptFileSkipped() throws {
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        try writeSession(pid: livePid, status: "idle", into: tempDir)
        try "not json".write(
            to: tempDir.appendingPathComponent("garbage.json"),
            atomically: true, encoding: .utf8
        )
        let result = SessionWatcher.readSessions(from: tempDir)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].pid, livePid)
    }

    func testNonJsonFilesIgnored() throws {
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        try writeSession(pid: livePid, status: "idle", into: tempDir)
        try "irrelevant".write(
            to: tempDir.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )
        let result = SessionWatcher.readSessions(from: tempDir)
        XCTAssertEqual(result.count, 1)
    }
}

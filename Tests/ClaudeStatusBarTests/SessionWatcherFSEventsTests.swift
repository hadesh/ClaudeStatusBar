import XCTest
import Combine
@testable import ClaudeStatusBar

final class SessionWatcherFSEventsTests: XCTestCase {

    private var tempDir: URL!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watcher-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeSession(pid: Int, status: String) throws {
        let json = """
        {"pid":\(pid),"sessionId":"s\(pid)","cwd":"/tmp","startedAt":0,"version":"v","kind":"interactive","entrypoint":"cli","status":"\(status)","updatedAt":0}
        """
        try json.write(
            to: tempDir.appendingPathComponent("\(pid).json"),
            atomically: true, encoding: .utf8
        )
    }

    func testFileCreationTriggersStoreUpdate() throws {
        let store = SessionStore()
        let watcher = SessionWatcher(directory: tempDir, store: store)
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)

        let exp = expectation(description: "session appears in store")
        store.$sessions
            .dropFirst() // 跳过初始 [] 值
            .sink { sessions in
                if sessions.contains(where: { $0.pid == livePid }) {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        watcher.start()
        defer { watcher.stop() }

        // 给 FSEvents 注册一点时间再写文件
        Thread.sleep(forTimeInterval: 0.2)
        try writeSession(pid: livePid, status: "busy")

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].status, .busy)
    }

    func testFileDeletionTriggersStoreUpdate() throws {
        let store = SessionStore()
        let watcher = SessionWatcher(directory: tempDir, store: store)
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        try writeSession(pid: livePid, status: "idle")

        let appeared = expectation(description: "session appears")
        let removed = expectation(description: "session removed")
        store.$sessions
            .dropFirst()
            .sink { sessions in
                if sessions.contains(where: { $0.pid == livePid }) {
                    appeared.fulfill()
                } else if sessions.isEmpty {
                    removed.fulfill()
                }
            }
            .store(in: &cancellables)

        watcher.start()
        defer { watcher.stop() }

        wait(for: [appeared], timeout: 2.0)
        try FileManager.default.removeItem(
            at: tempDir.appendingPathComponent("\(livePid).json")
        )
        wait(for: [removed], timeout: 1.0)
    }
}

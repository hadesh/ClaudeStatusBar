import XCTest
@testable import ClaudeStatusBar

/// SessionDetailsStore 跟 SessionContextStore 是同构的缓存层。这一组测试
/// 主要校验它特有的行为:增量扫新增 pid、清除删除 pid、增量合并(缺失 pid
/// 不写入 nil)。底层 SessionDetailsReader.read 的解析正确性由
/// SessionDetailsReaderTests 已经覆盖,不在本文件重测。
final class SessionDetailsStoreTests: XCTestCase {

    /// 一条最小可解析的 assistant 行 —— model 字段可替换以制造区分。
    private func assistantLine(model: String, output: Int = 100) -> String {
        #"""
        {"type":"assistant","message":{"model":"\#(model)","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\#(output)}}}
        """#
    }

    private func session(pid: Int, sessionId: String, cwd: String) -> Session {
        let json = #"""
        {"pid":\#(pid),"sessionId":"\#(sessionId)","cwd":"\#(cwd)","startedAt":0,"version":"2","kind":"interactive","entrypoint":"cli","status":"idle","updatedAt":0}
        """#.data(using: .utf8)!
        return try! JSONDecoder().decode(Session.self, from: json)
    }

    /// 在 tmp 下铺一份 `<projectsRoot>/<encoded-cwd>/<sessionId>.jsonl`,放进 1 行 assistant。
    /// 返回 projectsRoot URL 给 store 的 init 用。fixture 用法贴合 SessionDetailsReader。
    private func makeFixture(
        cwd: String, sessionId: String, model: String
    ) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sds-test-\(UUID().uuidString)")
        let projectDir = tmp.appendingPathComponent(SessionDetailsReader.encodeProjectPath(cwd))
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try assistantLine(model: model).write(
            to: projectDir.appendingPathComponent("\(sessionId).jsonl"),
            atomically: true, encoding: .utf8
        )
        return tmp
    }

    /// 让 store 内部 workQueue → publishQueue.main 的异步链跑完。store 默认
    /// publishQueue=.main,所以 main runloop 轮询一段时间足够。
    private func drainAsync(maxSeconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: maxSeconds))
    }

    // MARK: - updateSessions: 新增 pid 立刻扫

    func testAddingNewSessionScansImmediately() throws {
        let cwd = "/proj-a"
        let projectsRoot = try makeFixture(cwd: cwd, sessionId: "s1", model: "claude-opus-4-7")
        defer { try? FileManager.default.removeItem(at: projectsRoot) }

        let store = SessionDetailsStore(interval: 999, projectsRoot: projectsRoot)
        // 故意不 start(),避免周期 timer 干扰 —— 我们专测 updateSessions 的增量扫。
        store.updateSessions([session(pid: 42, sessionId: "s1", cwd: cwd)])
        drainAsync()

        XCTAssertEqual(store.detailsByPid[42]?.model, "claude-opus-4-7")
    }

    // MARK: - updateSessions: 删除 pid 立刻清缓存

    func testRemovingSessionClearsCache() throws {
        let cwd = "/proj-b"
        let projectsRoot = try makeFixture(cwd: cwd, sessionId: "s2", model: "claude-haiku-4-5")
        defer { try? FileManager.default.removeItem(at: projectsRoot) }

        let store = SessionDetailsStore(interval: 999, projectsRoot: projectsRoot)
        store.updateSessions([session(pid: 99, sessionId: "s2", cwd: cwd)])
        drainAsync()
        XCTAssertNotNil(store.detailsByPid[99], "前置:扫描应该填上 pid 99")

        store.updateSessions([])  // session 退出
        drainAsync()
        XCTAssertNil(store.detailsByPid[99], "session 消失后缓存项必须清掉")
    }

    // MARK: - 增量合并:扫不到的 pid 保留旧值

    func testMergeKeepsOldValueWhenScanFails() throws {
        // 先用一份带 jsonl 的 cwd 让 pid 7 落上 model A。
        let cwd = "/proj-c"
        let projectsRoot = try makeFixture(cwd: cwd, sessionId: "s3", model: "claude-opus-4-7")
        defer { try? FileManager.default.removeItem(at: projectsRoot) }

        let store = SessionDetailsStore(interval: 999, projectsRoot: projectsRoot)
        let sess = session(pid: 7, sessionId: "s3", cwd: cwd)
        store.updateSessions([sess])
        drainAsync()
        XCTAssertEqual(store.detailsByPid[7]?.model, "claude-opus-4-7")

        // 把 jsonl 删掉模拟 "正在写入 / 损坏" 情况。手动触发 refresh —— Store
        // 没暴露这个 API,只能通过 updateSessions 同样的 sessions 让它再扫一次。
        // 这个 case 走的是 added 路径(pid 集合相同 → added 集合空,不会重扫)。
        // 改用:补一个 pid,让 added 触发,但 7 不在 added 集合里,旧值保留。
        try FileManager.default.removeItem(at: projectsRoot.appendingPathComponent(
            SessionDetailsReader.encodeProjectPath(cwd)
        ))
        let other = session(pid: 8, sessionId: "s4", cwd: "/proj-other")
        store.updateSessions([sess, other])
        drainAsync()
        XCTAssertEqual(
            store.detailsByPid[7]?.model, "claude-opus-4-7",
            "未在 added 集合中的 pid 旧值必须保留"
        )
    }

    // MARK: - timer 触发的全量刷

    func testTimerRefreshFillsCache() throws {
        let cwd = "/proj-d"
        let projectsRoot = try makeFixture(cwd: cwd, sessionId: "s5", model: "claude-sonnet-4-6")
        defer { try? FileManager.default.removeItem(at: projectsRoot) }

        // 极短 interval 让 timer 几乎立即触发。
        let store = SessionDetailsStore(interval: 0.05, projectsRoot: projectsRoot)
        store.updateSessions([session(pid: 1, sessionId: "s5", cwd: cwd)])
        store.start()
        defer { store.stop() }
        drainAsync(maxSeconds: 0.3)

        XCTAssertEqual(store.detailsByPid[1]?.model, "claude-sonnet-4-6")
    }

    // MARK: - 多 session 都扫到

    func testMultipleSessionsAllScanned() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sds-multi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default
        let cwds = ["/p1", "/p2", "/p3"]
        for (i, cwd) in cwds.enumerated() {
            let dir = tmp.appendingPathComponent(SessionDetailsReader.encodeProjectPath(cwd))
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try assistantLine(model: "model-\(i)").write(
                to: dir.appendingPathComponent("ses\(i).jsonl"),
                atomically: true, encoding: .utf8
            )
        }
        let store = SessionDetailsStore(interval: 999, projectsRoot: tmp)
        store.updateSessions([
            session(pid: 10, sessionId: "ses0", cwd: "/p1"),
            session(pid: 20, sessionId: "ses1", cwd: "/p2"),
            session(pid: 30, sessionId: "ses2", cwd: "/p3")
        ])
        drainAsync()

        XCTAssertEqual(store.detailsByPid[10]?.model, "model-0")
        XCTAssertEqual(store.detailsByPid[20]?.model, "model-1")
        XCTAssertEqual(store.detailsByPid[30]?.model, "model-2")
    }
}

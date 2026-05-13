import Foundation
import CoreServices

public final class SessionWatcher {
    public static let defaultDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/sessions", isDirectory: true)
    }()

    private let directory: URL
    private let store: SessionStore
    private let safetyInterval: TimeInterval
    private let queue: DispatchQueue

    private var stream: FSEventStreamRef?
    private var safetyTimer: DispatchSourceTimer?

    public init(
        directory: URL = SessionWatcher.defaultDirectory,
        store: SessionStore,
        safetyInterval: TimeInterval = 30.0,
        queue: DispatchQueue = .main
    ) {
        self.directory = directory
        self.store = store
        self.safetyInterval = safetyInterval
        self.queue = queue
    }

    deinit { stop() }

    public func start() {
        ensureDirectoryExists()
        scanOnce()
        startFSEvents()
        startSafetyTimer()
    }

    public func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        safetyTimer?.cancel()
        safetyTimer = nil
    }

    public func scanOnce() {
        let sessions = Self.readSessions(from: directory)
        let store = self.store
        DispatchQueue.main.async {
            store.replaceAll(with: sessions)
        }
    }

    /// 纯函数:读取目录下所有 *.json,解码并过滤掉死进程。
    public static func readSessions(from directory: URL) -> [Session] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        return entries.compactMap { url -> Session? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            // 文件正在被写入时可能读到不完整 JSON,失败即跳过(下次事件会再触发)。
            guard let session = try? decoder.decode(Session.self, from: data) else { return nil }
            guard ProcessLiveness.isAlive(pid: session.pid) else { return nil }
            return session
        }
    }

    // MARK: - Private

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private func startFSEvents() {
        let pathsToWatch = [directory.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SessionWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scanOnce()
        }
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // 100ms 合并延迟
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func startSafetyTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + safetyInterval, repeating: safetyInterval)
        t.setEventHandler { [weak self] in self?.scanOnce() }
        t.resume()
        safetyTimer = t
    }
}

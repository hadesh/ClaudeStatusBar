import Foundation
import Darwin

/// Listens on a Unix domain socket. Each connection delivers exactly one
/// newline-terminated `PermissionPromptRequest` JSON, and is held open until
/// the matching `PermissionPromptDecision` comes back from `store`.
public final class PermissionPromptListener {
    public enum ListenerError: Error {
        case socketCreationFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pathTooLong
    }

    private let store: PermissionPromptStore
    private let socketPath: String
    private let acceptQueue = DispatchQueue(label: "PermissionPromptListener.accept")
    private let workQueue = DispatchQueue(label: "PermissionPromptListener.work", attributes: .concurrent)
    private var serverFd: Int32 = -1
    private var stopped = false

    public init(store: PermissionPromptStore, socketPath: String) {
        self.store = store
        self.socketPath = socketPath
    }

    public func start() throws {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.socketCreationFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count + 1 <= capacity else {
            close(fd); throw ListenerError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { buf in
                for i in 0..<capacity { buf[i] = 0 }
                for (i, b) in pathBytes.enumerated() { buf[i] = b }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                bind(fd, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno; close(fd); throw ListenerError.bindFailed(e)
        }
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            let e = errno; close(fd); throw ListenerError.listenFailed(e)
        }

        serverFd = fd
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        stopped = true
        let fd = serverFd
        serverFd = -1
        if fd >= 0 { close(fd) }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while !stopped {
            let client = accept(serverFd, nil, nil)
            if client < 0 {
                if stopped { return }
                continue
            }
            // Without SO_NOSIGPIPE, writing to a socket whose peer has gone
            // away (helper killed by CLI when terminal won) raises SIGPIPE
            // and tears down the whole app. We always check write's return
            // value, so suppress the signal and let EPIPE surface as an error.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            workQueue.async { [weak self] in
                self?.handle(clientFd: client)
            }
        }
    }

    private func handle(clientFd: Int32) {
        defer { close(clientFd) }
        guard let bytes = readLineBytes(fd: clientFd),
              let request = try? JSONDecoder().decode(PermissionPromptRequest.self, from: bytes)
        else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var captured: PermissionPromptDecision?
        store.add(request) { decision in
            captured = decision
            semaphore.signal()
        }

        // Watch for the helper going away. When the CLI's terminal prompt wins
        // the race, it kills the hook subprocess; the kernel then closes our
        // end of the socket and `read` returns 0. Resolve as deny so the
        // panel dismisses (via store.resolved) and our semaphore unblocks.
        // Resolving a request that the panel has already settled is a no-op
        // thanks to the store's lock.
        let watcher = DispatchSource.makeReadSource(fileDescriptor: clientFd, queue: workQueue)
        let store = self.store
        let requestId = request.id
        watcher.setEventHandler {
            var byte: UInt8 = 0
            let n = read(clientFd, &byte, 1)
            if n <= 0 {
                store.resolveDeny(id: requestId, message: "Settled by terminal prompt")
            }
            // Any spurious data from the helper (shouldn't happen) is dropped.
        }
        watcher.resume()
        defer { watcher.cancel() }

        semaphore.wait()

        guard let decision = captured,
              var data = try? JSONEncoder().encode(decision) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var sent = 0
            let total = raw.count
            let base = raw.baseAddress!
            while sent < total {
                let n = write(clientFd, base.advanced(by: sent), total - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private func readLineBytes(fd: Int32) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return out.isEmpty ? nil : out }
            for i in 0..<Int(n) {
                if buf[i] == 0x0A { return out }
                out.append(buf[i])
            }
        }
    }
}

import XCTest
import Darwin
@testable import ClaudeStatusBarHookCore

final class SocketClientTests: XCTestCase {

    func testRoundTrip() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sc-\(UUID().uuidString.prefix(8)).sock")
        let server = try LineServer(path: path)
        defer { server.stop() }

        var receivedRequest: Data?
        server.handler = { request in
            receivedRequest = request
            return Data(#"{"behavior":"allow","updatedInput":{}}"#.utf8)
        }

        let response = SocketClient.requestResponse(
            socketPath: path,
            requestLine: Data(#"{"id":"x","toolName":"Bash"}"#.utf8)
        )
        XCTAssertEqual(receivedRequest, Data(#"{"id":"x","toolName":"Bash"}"#.utf8))
        let resp = try XCTUnwrap(response)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: resp) as? [String: Any])
        XCTAssertEqual(obj["behavior"] as? String, "allow")
    }

    func testNonexistentSocketReturnsNil() {
        let response = SocketClient.requestResponse(
            socketPath: "/tmp/definitely-not-a-real-socket-\(UUID().uuidString).sock",
            requestLine: Data("{}".utf8)
        )
        XCTAssertNil(response)
    }
}

/// Minimal newline-framed Unix server for SocketClient interop tests.
private final class LineServer {
    var handler: ((Data) -> Data)?
    private let path: String
    private var serverFd: Int32 = -1
    private var stopped = false

    init(path: String) throws {
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "LineServer", code: 1) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count + 1 <= cap else {
            Darwin.close(fd); throw NSError(domain: "LineServer", code: 2)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tp in
            tp.withMemoryRebound(to: UInt8.self, capacity: cap) { buf in
                for i in 0..<cap { buf[i] = 0 }
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
        }
        let rc = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                bind(fd, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(fd); throw NSError(domain: "LineServer", code: 3)
        }
        guard listen(fd, 4) == 0 else {
            Darwin.close(fd); throw NSError(domain: "LineServer", code: 4)
        }
        serverFd = fd

        DispatchQueue.global().async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        stopped = true
        let fd = serverFd
        serverFd = -1
        if fd >= 0 { Darwin.close(fd) }
        unlink(path)
    }

    private func acceptLoop() {
        while !stopped {
            let client = accept(serverFd, nil, nil)
            if client < 0 { return }
            DispatchQueue.global().async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        defer { Darwin.close(client) }
        var input = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        readLoop: while true {
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(client, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            for i in 0..<Int(n) {
                if buf[i] == 0x0A { break readLoop }
                input.append(buf[i])
            }
        }
        guard let h = handler else { return }
        var reply = h(input)
        reply.append(0x0A)
        reply.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

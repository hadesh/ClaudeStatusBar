import XCTest
import Combine
import Darwin
@testable import ClaudeStatusBar

final class PermissionPromptListenerTests: XCTestCase {

    private func tempSocketPath() -> String {
        // sockaddr_un.sun_path on Darwin is 104 bytes; keep paths short.
        let dir = NSTemporaryDirectory()
        let name = "ppl-\(UUID().uuidString.prefix(8)).sock"
        return (dir as NSString).appendingPathComponent(name)
    }

    func testRoundTripOneRequest() throws {
        let path = tempSocketPath()
        let store = PermissionPromptStore(timeout: 1000, scheduler: { _, _ in {} })
        let listener = PermissionPromptListener(store: store, socketPath: path)
        try listener.start()
        defer { listener.stop() }

        let received = expectation(description: "store received request")
        var incoming: PermissionPromptRequest?
        let sub = store.incoming.sink { req in incoming = req; received.fulfill() }
        defer { sub.cancel() }

        let client = try TestUnixClient(path: path)
        let request = PermissionPromptRequest(
            id: "x1", toolName: "Bash",
            input: ["command": .string("ls")]
        )
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try client.writeAll(payload)

        wait(for: [received], timeout: 2.0)
        XCTAssertEqual(incoming?.id, "x1")
        XCTAssertEqual(incoming?.toolName, "Bash")

        let decision = PermissionPromptDecision.allow(
            id: "x1", input: ["command": .string("ls")]
        )
        store.resolve(id: "x1", decision: decision)

        let response = try XCTUnwrap(client.readLine(timeout: 2.0))
        let decoded = try JSONDecoder().decode(PermissionPromptDecision.self, from: response)
        XCTAssertEqual(decoded.behavior, .allow)
        XCTAssertEqual(decoded.id, "x1")
        client.close()
    }

    func testTwoConcurrentClientsKeepRepliesPaired() throws {
        let path = tempSocketPath()
        let store = PermissionPromptStore(timeout: 1000, scheduler: { _, _ in {} })
        let listener = PermissionPromptListener(store: store, socketPath: path)
        try listener.start()
        defer { listener.stop() }

        let bothReceived = expectation(description: "both received")
        bothReceived.expectedFulfillmentCount = 2
        let sub = store.incoming.sink { _ in bothReceived.fulfill() }
        defer { sub.cancel() }

        let clientA = try TestUnixClient(path: path)
        let clientB = try TestUnixClient(path: path)
        let reqA = PermissionPromptRequest(id: "A", toolName: "Bash", input: [:])
        let reqB = PermissionPromptRequest(id: "B", toolName: "Edit", input: [:])
        try clientA.writeAll(JSONEncoder().encode(reqA) + Data([0x0A]))
        try clientB.writeAll(JSONEncoder().encode(reqB) + Data([0x0A]))

        wait(for: [bothReceived], timeout: 2.0)

        // Resolve B first; A should still be pending and only the B client gets a reply.
        store.resolve(id: "B", decision: .deny(id: "B", message: "no B"))
        let respB = try XCTUnwrap(clientB.readLine(timeout: 2.0))
        let decB = try JSONDecoder().decode(PermissionPromptDecision.self, from: respB)
        XCTAssertEqual(decB.id, "B")
        XCTAssertEqual(decB.behavior, .deny)

        store.resolve(id: "A", decision: .allow(id: "A", input: [:]))
        let respA = try XCTUnwrap(clientA.readLine(timeout: 2.0))
        let decA = try JSONDecoder().decode(PermissionPromptDecision.self, from: respA)
        XCTAssertEqual(decA.id, "A")
        XCTAssertEqual(decA.behavior, .allow)

        clientA.close(); clientB.close()
    }

    func testMalformedJsonDropsConnection() throws {
        let path = tempSocketPath()
        let store = PermissionPromptStore(timeout: 1000, scheduler: { _, _ in {} })
        let listener = PermissionPromptListener(store: store, socketPath: path)
        try listener.start()
        defer { listener.stop() }

        let sub = store.incoming.sink { _ in
            XCTFail("malformed input should not reach store")
        }
        defer { sub.cancel() }

        let client = try TestUnixClient(path: path)
        try client.writeAll(Data("not json\n".utf8))
        // The server closes; readLine returns nil within timeout.
        let line = client.readLine(timeout: 1.0)
        XCTAssertNil(line)
        client.close()
    }
}

/// BSD-socket Unix client for tests. Writes/reads on a single fd.
private final class TestUnixClient {
    private let fd: Int32

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "TestUnixClient", code: 1)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count + 1 <= cap else {
            Darwin.close(fd)
            throw NSError(domain: "TestUnixClient", code: 2)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tp in
            tp.withMemoryRebound(to: UInt8.self, capacity: cap) { buf in
                for i in 0..<cap { buf[i] = 0 }
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
        }
        let rc = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                connect(fd, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw NSError(domain: "TestUnixClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "connect: \(e)"])
        }
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 {
                    throw NSError(domain: "TestUnixClient", code: 4)
                }
                sent += n
            }
        }
    }

    func readLine(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32((deadline.timeIntervalSinceNow * 1000).rounded()))
            let p = poll(&pfd, 1, remaining)
            if p <= 0 { return out.isEmpty ? nil : out }
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return out.isEmpty ? nil : out }
            for i in 0..<Int(n) {
                if buf[i] == 0x0A { return out }
                out.append(buf[i])
            }
        }
        return out.isEmpty ? nil : out
    }

    func close() {
        Darwin.close(fd)
    }
}

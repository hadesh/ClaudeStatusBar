import Foundation
import Darwin

/// One-shot Unix-domain-socket client. Connects, writes one newline-terminated
/// request, reads one newline-terminated response, closes. Used by the helper
/// to talk to the status-bar app per `tools/call`.
public enum SocketClient {
    public static func requestResponse(socketPath: String, requestLine: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count + 1 <= cap else { return nil }
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
        guard rc == 0 else { return nil }

        var payload = requestLine
        payload.append(0x0A)
        let writeOK = payload.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        guard writeOK else { return nil }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
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

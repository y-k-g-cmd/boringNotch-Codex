import Foundation
import Darwin

/// Real socket reader regression: a >64 MiB snapshot followed by another update
/// must remain on the same initialized connection. No real user data is used.
@main struct CodexFrameChecks {
    static func main() throws {
        precondition(CodexIPCTransport.supportsStreamVersion(11))
        precondition(CodexIPCTransport.supportsStreamVersion(13))
        precondition(!CodexIPCTransport.supportsStreamVersion(12))
        precondition(!CodexIPCTransport.supportsStreamVersion(14))
        precondition(!CodexIPCTransport.supportsFrameLength(0))
        precondition(CodexIPCTransport.supportsFrameLength(64 * 1024 * 1024 + 1))
        precondition(CodexIPCTransport.supportsFrameLength(256 * 1024 * 1024))
        precondition(!CodexIPCTransport.supportsFrameLength(256 * 1024 * 1024 + 1))
        let home = URL(fileURLWithPath: "/private/tmp/nf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("ipc"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let metadataFD = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(metadataFD) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(home.appendingPathComponent("ipc/ipc.sock").path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { dst in path.withUnsafeBytes { dst.copyBytes(from: $0) } }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(metadataFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        precondition(bound == 0, "isolated socket metadata must be created")
        var pair: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let client = pair[0], server = pair[1]
        defer { Darwin.close(client) }
        let received = DispatchSemaphore(value: 0), serverDone = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { Darwin.close(server); serverDone.signal() }
            var noSignal: Int32 = 1
            setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            func send(_ value: [String: Any]) {
                let data = try! JSONSerialization.data(withJSONObject: value)
                var size = UInt32(data.count).littleEndian
                var packet = withUnsafeBytes(of: &size) { Data($0) }; packet.append(data)
                packet.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let count = Darwin.write(server, raw.baseAddress!.advanced(by: offset), min(65536, raw.count - offset))
                        precondition(count > 0, "reader must not disconnect on supported large frame")
                        offset += count
                    }
                }
            }
            send(["type": "response", "method": "initialize", "result": ["clientId": "frame-test"]])
            send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "owner", "params": ["conversationId": "test", "change": ["type": "snapshot", "revision": 1, "conversationState": ["title": "Synthetic large frame", "diagnosticPadding": String(repeating: "x", count: 64 * 1024 * 1024 + 1024), "threadRuntimeStatus": ["type": "idle"]]]]])
            send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 13, "sourceClientId": "owner", "params": ["conversationId": "test", "change": ["type": "patches", "baseRevision": 1, "revision": 2, "patches": [["op": "replace", "path": ["title"], "value": "Version 13 follow-up"]], "acceptedTextChanges": []]]])
            _ = finish.wait(timeout: .now() + 20)
        }
        let transport = CodexIPCTransport(home: home, socketConnector: { Darwin.dup(client) }) { event in
            switch event {
            case .session(let session, let baseline):
                if !baseline { precondition(session.title == "Version 13 follow-up") }; received.signal()
            case .connection(false, _): preconditionFailure("supported large frame must not disconnect")
            default: break
            }
        }
        transport.start()
        precondition(received.wait(timeout: .now() + 30) == .success, ">64 MiB frame must be delivered")
        precondition(received.wait(timeout: .now() + 10) == .success, "same connection must deliver subsequent frame")
        transport.stop(); finish.signal()
        precondition(serverDone.wait(timeout: .now() + 3) == .success)
        print("PASS: zero/oversize rejected; 256 MiB boundary accepted; actual >64 MiB snapshot plus follow-up delivered without reconnect")
    }
}

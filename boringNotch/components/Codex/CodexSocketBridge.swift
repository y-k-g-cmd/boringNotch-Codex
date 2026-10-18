import Foundation
import Darwin

/// The existing XPC helper opens only ~/.codex/ipc/ipc.sock. All protocol handling
/// remains in the app. Called only after the user grants the Codex directory.
final class CodexSocketBridge {
    func connect() throws -> Int32 {
        let connection = NSXPCConnection(serviceName: "\(Bundle.main.bundleIdentifier ?? "io.github.y-k-g-cmd.boringnotchcodex").BoringNotchXPCHelper")
        connection.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        var result: Int32 = -1
        var failure: Int32 = ECONNREFUSED
        var transportError: Error?
        guard let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler({ transportError = $0 }) as? BoringNotchXPCHelperProtocol else {
            throw POSIXError(.ECONNREFUSED)
        }
        proxy.openCodexStatusSocket { handle, code in
            failure = code
            if let handle { result = Darwin.dup(handle.fileDescriptor) }
        }
        if let transportError { throw transportError }
        guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .ECONNREFUSED) }
        return result
    }
}

import Foundation
import Darwin

/// No caller-supplied executable, arguments, path, or RPC method. The official
/// CLI owns authentication. Only numeric quota windows cross the XPC boundary.
extension BoringNotchXPCHelper {
    @objc func readCodexUsage(with reply: @escaping (Data?, String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do { reply(try CodexUsageReader.read(), nil) }
            catch { reply(nil, "用量读取失败，请确认 Codex 已登录后重试") }
        }
    }
}

enum CodexUsageReader {
    enum Failure: Error { case unavailable, timeout, invalid }
    static func read() throws -> Data {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw Failure.unavailable }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // Bound cleanup to the child we spawned; never terminate the desktop.
            let until = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "boringnotch-usage", "version": "1.0"]]])
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var pending = Data(), requested = false
        var bytes = [UInt8](repeating: 0, count: 16384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 250)
            if ready < 0 { if errno == EINTR { continue }; throw Failure.invalid }
            if ready == 0 { continue }
            let count = Darwin.read(fd.fd, &bytes, bytes.count)
            guard count > 0 else { throw Failure.invalid }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count < 2 * 1024 * 1024 else { throw Failure.invalid }
            while let end = pending.firstIndex(of: 10) {
                let line = Data(pending[..<end]); pending.removeSubrange(...end)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                if message["id"] as? Int == 1 && !requested {
                    guard message["error"] == nil else { throw Failure.invalid }
                    requested = true
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if message["id"] as? Int == 2 {
                    guard message["error"] == nil, let result = message["result"] as? [String: Any] else { throw Failure.invalid }
                    return try sanitize(result)
                }
            }
        }
        throw Failure.timeout
    }

    static func sanitize(_ result: [String: Any]) throws -> Data {
        let byID = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        guard let limits = byID?["codex"] ?? result["rateLimits"] as? [String: Any] else { throw Failure.invalid }
        var windows: [[String: Any]] = []
        for key in ["primary", "secondary"] {
            guard let value = limits[key] as? [String: Any],
                  let used = value["usedPercent"] as? Double, used.isFinite,
                  let minutes = value["windowDurationMins"] as? Double, minutes.isFinite, minutes > 0 else { continue }
            var window: [String: Any] = ["usedPercent": max(0, min(100, used)), "minutes": minutes]
            if let reset = value["resetsAt"] as? Double, reset.isFinite { window["resetsAt"] = reset }
            windows.append(window)
        }
        guard !windows.isEmpty else { throw Failure.unavailable }
        return try JSONSerialization.data(withJSONObject: ["windows": windows])
    }
}

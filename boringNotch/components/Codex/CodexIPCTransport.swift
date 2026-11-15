import Foundation
import Darwin

/// Adapter for the installed Codex Desktop IPC protocol (verified stream versions 11 and 13).
/// This is a private desktop interface, separate from the public app-server protocol.
/// Replies are targeted to the live owner and validated against its exact pending request.
final class CodexIPCTransport: @unchecked Sendable {
    enum Event {
        case connection(Bool, String)
        case session(CodexSession, baseline: Bool)
        case removed(String)
        case retryPaused
        case actionResult(UUID, Bool, String)
    }
    private let deliver: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "boringnotch.codex.ipc", qos: .utility)
    private var clientID = ""
    private var followed: Set<String> = []
    private var states: [String: (revision: Int, owner: String, value: [String: Any])] = [:]
    private let stopLock = NSLock()
    private var stopped = false
    private var outgoing: [CodexRequestAction] = []
    private var pendingActions: [String: (action: CodexRequestAction, deadline: TimeInterval)] = [:]
    private var isStopped: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopped }
    private let retryTimeout: TimeInterval
    // Same framing limit as the installed desktop reader (256 MiB).
    static let maximumFrameBytes = 256 * 1024 * 1024
    static func supportsFrameLength(_ length: Int) -> Bool {
        length > 0 && length <= maximumFrameBytes
    }
    // Version 13 retains snapshot/revision/patches and the same request methods.
    // acceptedTextChanges is transcript-renderer metadata, not a state patch.
    static func supportsStreamVersion(_ version: Int) -> Bool { [11, 13].contains(version) }
    private var initializedAt: TimeInterval?
    private var attemptDeadline = TimeInterval.infinity
    private let home: URL
    private let socketConnector: (() throws -> Int32)?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
         socketConnector: (() throws -> Int32)? = nil,
         retryTimeout: TimeInterval = 300,
         deliver: @escaping @Sendable (Event) -> Void) {
        self.home = home
        self.socketConnector = socketConnector
        self.retryTimeout = retryTimeout
        self.deliver = deliver
    }

    func start() { queue.async { self.run() } }

    func stop() { stopLock.lock(); stopped = true; stopLock.unlock() }

    func submit(_ action: CodexRequestAction) {
        stopLock.lock(); defer { stopLock.unlock() }
        guard !stopped else { return }
        outgoing.append(action)
    }

    private func flushActions(fd: Int32) throws {
        stopLock.lock(); let actions = outgoing; outgoing.removeAll(); stopLock.unlock()
        for action in actions {
            do {
                guard let current = states[action.sessionID], current.owner == action.ownerClientID,
                      !clientID.isEmpty, !action.ownerClientID.isEmpty,
                      let live = CodexSession.parse(current.value, threadID: action.threadID, hostID: action.hostID, ownerClientID: current.owner)
                        .requests.first(where: { $0.id == action.request.id }), live == action.request else { throw CodexPendingRequest.Invalid.stale }
                let response = try live.response(action.reply)
                var params = response.payload
                params["conversationId"] = action.threadID
                let id = action.token.uuidString
                var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
                    "version": (response.method == "thread-follower-start-turn" ? 2 : 1) + (action.hostID == "local" ? 0 : 1), "method": response.method, "params": params,
                    "targetClientId": action.ownerClientID, "timeoutMs": 10000]
                if action.hostID != "local" { message["hostId"] = action.hostID }
                try send(message, fd: fd)
                pendingActions[id] = (action, ProcessInfo.processInfo.systemUptime + 12)
            } catch {
                deliver(.actionResult(action.token, false, "请求已变化或无法提交，请检查后重试，或在 Codex 中处理"))
            }
        }
        for (id, pending) in pendingActions where pending.deadline <= ProcessInfo.processInfo.systemUptime {
            pendingActions.removeValue(forKey: id)
            deliver(.actionResult(pending.action.token, false, "未收到 Codex 确认，请检查任务状态；不会自动重复提交"))
        }
    }

    private func run() {
        var window = CodexReconnectWindow(now: ProcessInfo.processInfo.systemUptime, timeout: retryTimeout)
        while !isStopped {
            guard window.canAttempt(at: ProcessInfo.processInfo.systemUptime) else {
                deliver(.retryPaused)
                return
            }
            initializedAt = nil
            attemptDeadline = ProcessInfo.processInfo.systemUptime + window.remaining(at: ProcessInfo.processInfo.systemUptime)
            do { try connectAndRead() }
            catch {
                guard !isStopped else { return }
                let label = (error as? Failure)?.label ?? "Codex 连接失败：\((error as NSError).localizedDescription)"
                deliver(.connection(false, label))
            }
            guard !isStopped else { return }
            // A handshake followed immediately by a bad frame is not a stable
            // connection: it must not renew the five-minute retry budget forever.
            if let initializedAt {
                let now = ProcessInfo.processInfo.systemUptime
                window.disconnectedAfterSuccess(at: now, connectedFor: now - initializedAt)
            }
            Thread.sleep(forTimeInterval: min(3, window.remaining(at: ProcessInfo.processInfo.systemUptime)))
        }
    }

    private func connectAndRead() throws {
        defer {
            stopLock.lock(); let unsent = outgoing; outgoing.removeAll(); stopLock.unlock()
            let unresolved = pendingActions.values.map(\.action) + unsent
            pendingActions.removeAll()
            for action in unresolved {
                deliver(.actionResult(action.token, false, "连接已中断，请确认 Codex 中的请求状态后重试"))
            }
        }
        let path = home.appendingPathComponent("ipc/ipc.sock").path
        var statInfo = stat()
        guard lstat(path, &statInfo) == 0 else { throw Failure.system("目录访问", errno) }
        guard statInfo.st_uid == getuid(), (statInfo.st_mode & S_IFMT) == S_IFSOCK else { throw Failure.unavailable }
        let fd = try socketConnector?() ?? socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        if socketConnector == nil {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.system("连接", errno) }
        }
        clientID = ""
        followed.removeAll()
        states.removeAll()
        try send(["type": "request", "requestId": UUID().uuidString, "sourceClientId": "",
                  "version": 0, "method": "initialize", "params": ["clientType": "boringnotch"]], fd: fd)
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var lastIndexScan = Date.distantPast
        let connectedAt = Date()
        while !isStopped {
            if !clientID.isEmpty { try flushActions(fd: fd) }
            if clientID.isEmpty && ProcessInfo.processInfo.systemUptime >= attemptDeadline { throw Failure.disconnected }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 1000)
            if ready < 0 { if errno == EINTR { continue }; throw Failure.disconnected }
            if ready > 0 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { throw Failure.disconnected }
                pending.append(contentsOf: buffer.prefix(count))
                while pending.count >= 4 {
                    let length = pending.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                    guard Self.supportsFrameLength(length) else { throw Failure.invalidFrame(length) }
                    guard pending.count >= length + 4 else { break }
                    let frame = Data(pending.dropFirst(4).prefix(length))
                    pending.removeFirst(4 + length)
                    guard let message = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { throw Failure.invalidPayload }
                    try handle(message, fd: fd)
                }
            }
            if clientID.isEmpty {
                if Date().timeIntervalSince(connectedAt) > 5 { throw Failure.disconnected }
            } else if Date().timeIntervalSince(lastIndexScan) > 15 {
                for id in recentThreadIDs() { try follow(id, host: "local", fd: fd) }
                lastIndexScan = Date()
            }
        }
    }

    private func handle(_ message: [String: Any], fd: Int32) throws {
        let type = message["type"] as? String
        if type == "response", let id = message["requestId"] as? String,
           let pending = pendingActions.removeValue(forKey: id) {
            let success = message["resultType"] as? String == "success"
                && message["handledByClientId"] as? String == pending.action.ownerClientID
            let detail = message["error"] as? String ?? "响应来源已变化，请重新连接"
            deliver(.actionResult(pending.action.token, success, success ? "已提交，等待 Codex 更新" : "Codex 拒绝：\(detail.prefix(250))"))
            return
        }
        if type == "client-discovery-request", let id = message["requestId"] {
            try send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]], fd: fd)
            return
        }
        let method = message["method"] as? String
        if type == "response", method == "initialize",
           let result = message["result"] as? [String: Any], let id = result["clientId"] as? String {
            clientID = id
            initializedAt = ProcessInfo.processInfo.systemUptime
            deliver(.connection(true, "已连接 Codex"))
            return
        }
        guard type == "broadcast", !clientID.isEmpty,
              let params = message["params"] as? [String: Any] else { return }
        if let targets = message["targetClientIds"] as? [String], !targets.contains(clientID) { return }
        guard let thread = params["conversationId"] as? String else { return }
        let host = params["hostId"] as? String ?? "local"
        let key = host + ":" + thread
        if method == "thread-stream-following-changed" {
            // Discover live threads announced by existing desktop clients.
            if params["following"] as? Bool == true { try follow(thread, host: host, fd: fd) }
        } else if method == "thread-archived" {
            states.removeValue(forKey: key)
            deliver(.removed(key))
        } else if method == "thread-stream-state-changed" {
            guard let version = message["version"] as? Int, Self.supportsStreamVersion(version) else {
                deliver(.connection(false, "Codex 状态协议已变化，请更新接入适配")); return
            }
            guard let change = params["change"] as? [String: Any], let revision = change["revision"] as? Int else { return }
            let owner = message["sourceClientId"] as? String ?? ""
            let baseline = states[key] == nil
            if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
                states[key] = (revision, owner, state)
            } else if change["type"] as? String == "patches", let previous = states[key],
                      previous.owner == owner, previous.revision == change["baseRevision"] as? Int,
                      let patches = change["patches"] as? [[String: Any]],
                      let state = try? CodexStatePatch.apply(patches, to: previous.value) as? [String: Any] {
                states[key] = (revision, owner, state)
            } else {
                // Ask the owner for a fresh snapshot rather than guessing through missing patches.
                states.removeValue(forKey: key)
                followed.remove(key)
                try announce(thread, host: host, following: false, fd: fd)
                try follow(thread, host: host, fd: fd)
                return
            }
            if let state = states[key]?.value {
                deliver(.session(CodexSession.parse(state, threadID: thread, hostID: host, ownerClientID: owner), baseline: baseline))
            }
        }
    }

    private func follow(_ thread: String, host: String, fd: Int32) throws {
        guard UUID(uuidString: thread) != nil else { return }
        guard followed.insert(host + ":" + thread).inserted else { return }
        try announce(thread, host: host, following: true, fd: fd)
    }

    private func announce(_ thread: String, host: String, following: Bool, fd: Int32) throws {
        try send(["type": "broadcast", "sourceClientId": clientID, "method": "thread-stream-following-changed",
                  "version": 1, "params": ["conversationId": thread, "hostId": host, "following": following]], fd: fd)
    }

    private func recentThreadIDs() -> [String] {
        // Metadata only; never open auth.json, sqlite databases, or conversation rollouts.
        let path = home.appendingPathComponent("session_index.jsonl")
        guard let file = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return [] }
        try? file.seek(toOffset: size > 262144 ? size - 262144 : 0)
        guard let data = try? file.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        var seen: Set<String> = []
        return text.split(separator: "\n").reversed().compactMap { line -> String? in
            guard let data = line.data(using: .utf8), let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = entry["id"] as? String, seen.insert(id).inserted else { return nil }
            return id
        }.prefix(32).map { $0 }
    }

    private func send(_ message: [String: Any], fd: Int32) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(data.count).littleEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(data)
        try packet.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure.disconnected }
                offset += written
            }
        }
    }

    private enum Failure: Error {
        case unavailable, disconnected, invalidPayload
        case invalidFrame(Int)
        case system(String, Int32)

        var label: String {
            switch self {
            case .system(let operation, let code):
                return "Codex \(operation)失败（\(code)），正在重试"
            case .invalidFrame(let length): return "Codex 状态消息长度异常（\(length) 字节），正在重试"
            case .invalidPayload: return "Codex 状态数据无效，正在重试"
            default: return "Codex 未连接，正在重试"
            }
        }
    }
}

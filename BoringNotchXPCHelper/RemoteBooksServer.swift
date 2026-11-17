import Foundation
import Network
import Security
import AppKit
import ApplicationServices

/// One in-memory pairing session owned by the host app's XPC connection.
/// All protocol state is confined to queue. The only remote action is Books left/right.
final class RemoteBooksServer {
    private let queue = DispatchQueue(label: "boringNotch.books-remote")
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var watchdog: DispatchSourceTimer?
    private var lease = Date.distantPast
    private var token = "", pin = "", phase = "stopped", message = ""
    private var hosts = Set<String>()
    private var addresses: [String] = []
    private var failures: [Date] = []
    private var cache: [String: (String, Int, Data)] = [:]
    private var order: [String] = []
    private var busy = false
    private var generation = UUID()
    private let html: Data
    private let turn: (String, @escaping (Bool, String) -> Void) -> Void

    init(html: Data? = nil, turn: ((String, @escaping (Bool, String) -> Void) -> Void)? = nil) {
        self.html = html ?? Bundle.main.url(forResource: "BooksRemote", withExtension: "html")
            .flatMap { try? Data(contentsOf: $0) } ?? Data()
        self.turn = turn ?? Self.turnBooks
    }

    func control(_ action: String, reply: @escaping (Data) -> Void) {
        queue.async {
            switch action {
            case "start": if self.listener == nil { self.start() }; self.lease = Date().addingTimeInterval(12)
            case "renew": self.lease = Date().addingTimeInterval(12)
            case "stop": self.stopNow()
            case "status": break
            default: reply(self.json(["state": "error", "message": "未知操作"])); return
            }
            reply(self.json(["state": self.phase, "message": self.message,
                             "addresses": self.addresses, "pin": self.pin, "token": self.token]))
        }
    }
    func stop() { queue.async { self.stopNow() } }

    private func start() {
        stopNow()
        guard !html.isEmpty else { phase = "error"; message = "手机页面资源缺失"; return }
        guard let secret = Self.random(32), let code = Self.random(8) else {
            phase = "error"; message = "无法生成配对凭证"; return
        }
        token = secret.map { String(format: "%02x", $0) }.joined()
        pin = code.map { String(Int($0) % 10) }.joined()
        let ips = Self.localAddresses()
        guard !ips.isEmpty else { stopNow(); phase = "error"; message = "没有可用的局域网 IPv4，请连接 Wi-Fi 后重试"; return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: .any)
            let service = try NWListener(using: parameters)
            listener = service; phase = "starting"
            let session = generation
            service.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == session else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port?.rawValue else { return }
                    self.addresses = ips.map { "http://\($0):\(port)" }
                    self.hosts = Set((ips + ["127.0.0.1", "localhost"]).map { "\($0):\(port)" })
                    self.phase = "ready"
                case .failed:
                    self.stopNow(); self.phase = "error"; self.message = "无法启动局域网服务，请检查本地网络权限"
                default: break
                }
            }
            service.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            service.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if Date() > self.lease { self.stopNow() }
            }
            watchdog = timer; timer.resume()
        } catch { stopNow(); phase = "error"; message = "无法启动局域网服务" }
    }
    private func stopNow() {
        generation = UUID(); listener?.cancel(); listener = nil
        watchdog?.cancel(); watchdog = nil
        clients.values.forEach { $0.cancel() }; clients.removeAll()
        token = ""; pin = ""; addresses = []; hosts = []; failures = []
        cache = [:]; order = []; busy = false; phase = "stopped"; message = ""
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 32, case let .hostPort(host, _) = connection.endpoint,
              Self.isLocalIPv4(String(describing: host)) else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection
        connection.start(queue: queue)
        // Bound incomplete / idle requests and avoid retaining an unbounded socket set.
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish(id) }
        receive(id, accumulated: Data())
    }
    private func finish(_ id: UUID) { clients.removeValue(forKey: id)?.cancel() }
    private func receive(_ id: UUID, accumulated: Data) {
        guard let connection = clients[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self, self.clients[id] != nil else { return }
            var buffer = accumulated; if let data { buffer.append(data) }
            guard buffer.count <= 9216 else { self.respond(id, 400, self.json(["error": "请求过大"])); return }
            if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard boundary.lowerBound <= 8192,
                      let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else {
                    self.respond(id, 400, self.json(["error": "请求无效"])); return
                }
                let lines = header.components(separatedBy: "\r\n")
                let request = (lines.first ?? "").split(separator: " ").map(String.init)
                guard request.count == 3, request[2] == "HTTP/1.1" else { self.respond(id, 400, self.json(["error": "请求无效"])); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { self.respond(id, 400, self.json(["error": "请求头无效"])); return }
                    let key = line[..<colon].lowercased()
                    guard headers[key] == nil else { self.respond(id, 400, self.json(["error": "重复请求头"])); return }
                    headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil else { self.respond(id, 400, self.json(["error": "不支持分块请求"])); return }
                let length = Int(headers["content-length"] ?? "0") ?? -1
                guard (0...1024).contains(length), request[0] != "POST" || length > 0 else { self.respond(id, 400, self.json(["error": "请求长度无效"])); return }
                let body = Data(buffer[boundary.upperBound...])
                if body.count < length && !done && error == nil { self.receive(id, accumulated: buffer); return }
                guard body.count == length else { self.respond(id, 400, self.json(["error": "请求体无效"])); return }
                self.route(id, method: request[0], path: request[1], headers: headers, body: body)
            } else if done || error != nil { self.finish(id) }
            else { self.receive(id, accumulated: buffer) }
        }
    }
    private func route(_ id: UUID, method: String, path: String, headers: [String: String], body: Data) {
        func fail(_ code: Int, _ text: String) { respond(id, code, json(["error": text])) }
        guard let host = headers["host"], hosts.contains(host) else { fail(403, "来源地址不允许"); return }
        if method == "GET" && path == "/" { respond(id, 200, html, type: "text/html; charset=utf-8"); return }
        var object: [String: Any] = [:]
        if method == "POST" {
            guard headers["origin"] == "http://" + host else { fail(403, "请求来源不允许"); return }
            guard headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { fail(415, "需要 JSON 请求"); return }
            guard let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { fail(400, "JSON 无效"); return }
            object = parsed
        }
        if method == "POST" && path == "/pair" {
            failures.removeAll { Date().timeIntervalSince($0) > 60 }
            guard failures.count < 10 else { fail(429, "尝试过多，请一分钟后重试"); return }
            guard let value = object["pin"] as? String, Self.equal(value, pin) else { failures.append(Date()); fail(401, "配对码错误"); return }
            respond(id, 200, json(["token": token])); return
        }
        guard Self.equal(headers["authorization"] ?? "", "Bearer " + token), !token.isEmpty else { fail(401, "请重新配对"); return }
        if method == "GET" && path == "/health" { respond(id, 200, json(["ok": true])); return }
        guard method == "POST" && path == "/turn" else { fail(404, "没有此操作"); return }
        guard let direction = object["direction"] as? String, ["prev", "next"].contains(direction),
              let requestID = object["id"] as? String, (1...80).contains(requestID.count) else { fail(400, "翻页参数无效"); return }
        if let prior = cache[requestID] {
            guard prior.0 == direction else { fail(409, "请求编号已被使用"); return }
            respond(id, prior.1, prior.2); return
        }
        guard !busy else { fail(409, "上一条翻页仍在处理"); return }
        busy = true
        let session = generation
        turn(direction) { [weak self] ok, message in
            guard let self else { return }
            self.queue.async {
                guard self.generation == session else { return }
                self.busy = false
                let code = ok ? 200 : 503
                let data = self.json(ok ? ["ok": true, "message": message] : ["error": message])
                self.cache[requestID] = (direction, code, data); self.order.append(requestID)
                if self.order.count > 256 { self.cache.removeValue(forKey: self.order.removeFirst()) }
                self.respond(id, code, data)
            }
        }
    }
    private func respond(_ id: UUID, _ code: Int, _ body: Data, type: String = "application/json; charset=utf-8") {
        guard let connection = clients[id] else { return }
        let head = "HTTP/1.1 \(code) Response\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n"
        var output = Data(head.utf8); output.append(body)
        connection.send(content: output, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
    }
    private func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8) }
    private static func equal(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func random(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        return SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess ? bytes : nil
    }
    static func isLocalIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
    static func localAddresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }
        defer { freeifaddrs(pointer) }
        var current = pointer, result = Set<String>()
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (item.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if isLocalIPv4(ip) && !ip.hasPrefix("127.") { result.insert(ip) }
        }
        return result.sorted()
    }
    // XPC services may receive no WindowServer session dictionary. Unknown is not
    // evidence of a locked desktop; the Books foreground check below still applies.
    static func desktopIsKnownUnavailable(_ session: [String: Any]?) -> Bool {
        session?[kCGSessionOnConsoleKey as String] as? Bool == false ||
        session?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    static func isBooksApplication(_ identifier: String?) -> Bool {
        identifier == "com.apple.iBooksX" || identifier == "com.apple.iBooks"
    }

    private static func turnBooks(_ direction: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard AXIsProcessTrusted() else { completion(false, "请在 Mac 的 boringNotch 设置中授权辅助功能"); return }
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            guard !desktopIsKnownUnavailable(session) else {
                completion(false, "请解锁 Mac 并保持桌面唤醒"); return
            }
            guard let app = NSWorkspace.shared.runningApplications.first(where: { isBooksApplication($0.bundleIdentifier) }) else {
                completion(false, "请先在 Mac 图书中打开 EPUB 正文"); return
            }
            app.activate()
            let deadline = Date().addingTimeInterval(2)
            while !app.isActive && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            guard app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                completion(false, "无法切换到图书，请在 Mac 上打开阅读窗口"); return
            }
            let key: CGKeyCode = direction == "next" ? 124 : 123
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
                completion(false, "无法创建翻页按键"); return
            }
            // Target only Books, even if focus changes between checking and posting.
            down.flags = []; up.flags = []
            down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
            completion(true, "已发送翻页按键")
        }
    }
}

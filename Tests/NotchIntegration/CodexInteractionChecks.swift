import Foundation
import Darwin

final class InteractionEvents: @unchecked Sendable {
    let snapshot = DispatchSemaphore(value: 0)
    let response = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: [(Bool, String)] = []
    func receive(_ event: CodexIPCTransport.Event) {
        switch event {
        case .session: snapshot.signal()
        case .actionResult(_, let success, let message):
            lock.lock(); stored.append((success, message)); lock.unlock(); response.signal()
        default: break
        }
    }
    var results: [Bool] { lock.lock(); defer { lock.unlock() }; return stored.map(\.0) }
}

@main struct CodexInteractionChecks {
    static func packet(_ object: [String: Any], _ fd: Int32) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        var size = UInt32(data.count).littleEndian
        var bytes = withUnsafeBytes(of: &size) { Data($0) }; bytes.append(data)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                precondition(count > 0); offset += count
            }
        }
    }
    static func read(_ fd: Int32) -> [String: Any] {
        func bytes(_ count: Int) -> Data {
            var result = Data(); var buffer = [UInt8](repeating: 0, count: count)
            while result.count < count {
                let n = Darwin.read(fd, &buffer, count - result.count)
                precondition(n > 0, "mock IPC read timed out")
                result.append(contentsOf: buffer.prefix(n))
            }
            return result
        }
        let size = bytes(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        return try! JSONSerialization.jsonObject(with: bytes(size)) as! [String: Any]
    }
    static func main() throws {
        let questionMessage: [String: Any] = ["type": "agentMessage", "id": "call-real-shape", "text": "请选择一个选项", "questions": [["title": "请选择一个选项", "options": ["A", "B", "C", "D"]]]]
        var questionTurn: [String: Any] = ["turnId": "async-turn", "status": "completed", "turnStartedAtMs": 1, "items": [questionMessage]]
        func asyncState(_ turn: [String: Any]) -> [String: Any] {
            ["turnHistory": ["history": ["entitiesByKey": ["turn:async-turn": turn]]], "threadRuntimeStatus": ["type": "idle"], "cwd": "/tmp/test"]
        }
        let questionSession = CodexSession.parse(asyncState(questionTurn), threadID: "test", hostID: "local")
        precondition(questionSession.activity == .needsInput && questionSession.requests.count == 1, "completed async question must still need an answer")
        let asyncRequest = questionSession.requests[0]
        precondition(asyncRequest.questions[0].options.map(\.label) == ["A", "B", "C", "D"])
        let asyncID = asyncRequest.questions[0].id
        precondition(asyncID == "[\"request_user_input_async\",\"call-real-shape\",0]")
        let asyncResponse = try asyncRequest.response(.answers([asyncID: ["A"]]))
        precondition(asyncResponse.method == "thread-follower-start-turn")
        let turnStart = asyncResponse.payload["turnStart"] as! [String: Any]
        let request = turnStart["request"] as! [String: Any]
        precondition(request["threadId"] as? String == "test", "turn request must target the same conversation")
        let text = (request["input"] as! [[String: Any]])[0]["text"] as! String
        precondition(text.contains("<send_user_message_question_reply>") && text.contains("\"answer\":\"A\""))
        var answeredTurn = questionTurn
        answeredTurn["items"] = [questionMessage, ["type": "userMessage", "content": [["type": "text", "text": text]]]]
        precondition(CodexSession.parse(asyncState(answeredTurn), threadID: "test", hostID: "local").requests.isEmpty, "answered async questions disappear")
        questionTurn["status"] = "inProgress"
        let active = CodexSession.parse(asyncState(questionTurn), threadID: "test", hostID: "local")
        let activeResponse = try active.requests[0].response(.answers([asyncID: ["B"]]))
        precondition(activeResponse.method == "thread-follower-steer-turn")
        let plain: [String: Any] = ["turns": [["turnId": "plain", "status": "completed", "items": [["type": "agentMessage", "text": "请选择 A 或 B"]]]]]
        precondition(CodexSession.parse(plain, threadID: "test", hostID: "local").requests.isEmpty, "ordinary prose cannot manufacture a request")
        let regions = [CGRect(x: 20, y: 40, width: 580, height: 84), CGRect(x: 20, y: 18, width: 580, height: 22)]
        precondition(!PageSwipeRouting.switchesPage(at: CGPoint(x: 200, y: 80), excludingTaskRegions: true, taskRegions: regions), "cards browse tasks")
        precondition(!PageSwipeRouting.switchesPage(at: CGPoint(x: 200, y: 25), excludingTaskRegions: true, taskRegions: regions), "task bar also browses tasks")
        precondition(PageSwipeRouting.switchesPage(at: CGPoint(x: 200, y: 145), excludingTaskRegions: true, taskRegions: regions), "connection toolbar switches pages")
        precondition(PageSwipeRouting.switchesPage(at: CGPoint(x: 200, y: 175), excludingTaskRegions: true, taskRegions: regions), "navigation switches pages")
        precondition(PageSwipeRouting.switchesPage(at: CGPoint(x: 200, y: 80), excludingTaskRegions: false, taskRegions: regions), "page mode switches everywhere")
        precondition(PageSwipeRouting.switchesPage(at: CGPoint(x: 200, y: 80), excludingTaskRegions: true, taskRegions: []), "request panel has no task browsing region")
        precondition(CodexReminderTiming.completionDuration(6) == 6)
        precondition(CodexReminderTiming.completionDuration(25) == 25)
        precondition(CodexReminderTiming.completionDuration(0) == 1)
        precondition(CodexReminderTiming.completionDuration(200) == 60)
        precondition(CodexReminderTiming.completionDuration(.nan) == 6)
        var swipe = PageSwipeAccumulator()
        precondition(swipe.update(dx: -20, dy: 1) == nil)
        precondition(swipe.update(dx: -25, dy: 1) == 1)
        precondition(swipe.update(dx: -100, dy: 0) == nil, "one page per gesture")
        swipe.reset(); precondition(swipe.update(dx: 45, dy: 0) == -1)
        swipe.reset(); precondition(swipe.update(dx: 2, dy: 20) == nil)
        precondition(swipe.update(dx: 100, dy: 1) == nil, "vertical axis stays locked")
        swipe.reset(); precondition(swipe.update(dx: 20, dy: 20) == nil && !swipe.claimed)

        let command: [String: Any] = ["id": 21, "method": "item/commandExecution/requestApproval", "params": ["threadId": "test", "turnId": "t", "command": "echo test", "availableDecisions": ["accept", "decline"]]]
        let input: [String: Any] = ["id": "q", "method": "item/tool/requestUserInput", "params": ["threadId": "test", "questions": [["id": "choice", "question": "Choose", "options": [["label": "One", "description": "First"]]]]]]
        let permission: [String: Any] = ["id": "p", "method": "item/permissions/requestApproval", "params": ["threadId": "test", "permissions": ["file_system": ["read": ["/tmp/example"]]]]]
        let file: [String: Any] = ["id": "f", "method": "item/fileChange/requestApproval", "params": ["threadId": "test", "reason": "test change"]]
        let rawRequests = [command, input, permission, file]
        let requests = rawRequests.map { CodexPendingRequest($0)! }
        var wireAsyncTurn = questionTurn
        wireAsyncTurn["status"] = "completed"
        precondition(CodexPendingRequest(["id": true, "method": "unknown"]) == nil)
        precondition(requests[1].questions.first?.options.first?.label == "One")
        precondition((try? requests[1].response(.answers([:]))) == nil, "all questions required")
        precondition((try? requests[0].response(.decision("acceptForSession"))) == nil, "no persistent approval")
        let allowed = try requests[2].response(.permissions(true)).payload["response"] as! [String: Any]
        precondition(allowed["scope"] as? String == "turn")
        let denied = try requests[2].response(.permissions(false)).payload["response"] as! [String: Any]
        precondition((denied["permissions"] as! [String: Any]).isEmpty)

        // Only inspect the real socket's ownership. All wire traffic goes to an isolated
        // socketpair supplied by the same connector seam used by the production XPC helper.
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("ipc/ipc.sock").path) else {
            print("PASS: request and swipe checks; SKIP socketpair worker (no Codex socket metadata)")
            return
        }
        var pair: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let clientFD = pair[0], serverFD = pair[1]
        defer { Darwin.close(clientFD) }
        let events = InteractionEvents()
        let finished = DispatchSemaphore(value: 0)
        let closeServer = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let fd = serverFD
            defer { Darwin.close(fd); finished.signal() }
            var timeout = timeval(tv_sec: 8, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = read(fd)
            packet(["type": "response", "method": "initialize", "result": ["clientId": "test-client"]], fd)
            func snapshot(_ requests: [[String: Any]], revision: Int) {
                packet(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "owner",
                    "params": ["conversationId": "test", "hostId": "local", "change": ["type": "snapshot", "revision": revision,
                    "conversationState": ["title": "Mock", "cwd": "/tmp/test", "requests": requests, "turns": revision == 1 ? [wireAsyncTurn] : [], "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnApproval"]]]]]], fd)
            }
            snapshot(rawRequests, revision: 1)
            var received = 0
            while received < 5 {
                let message = read(fd)
                guard message["type"] as? String == "request" else { continue }
                precondition(message["targetClientId"] as? String == "owner" && message["version"] as? Int == (received == 4 ? 2 : 1))
                let params = message["params"] as! [String: Any]
                precondition(params["conversationId"] as? String == "test")
                switch received {
                case 0: precondition(params["requestId"] as? Int == 21 && params["decision"] as? String == "accept")
                case 1:
                    let response = params["response"] as! [String: Any]
                    let answers = response["answers"] as! [String: [String: [String]]]
                    precondition(answers["choice"]?["answers"] == ["One"])
                case 2:
                    let response = params["response"] as! [String: Any]
                    precondition(response["scope"] as? String == "turn")
                case 3: precondition(params["decision"] as? String == "decline")
                default:
                    precondition(message["method"] as? String == "thread-follower-start-turn")
                    let start = params["turnStart"] as! [String: Any]
                    let request = start["request"] as! [String: Any]
                    precondition((request["input"] as! [[String: Any]])[0]["text"] as? String == text)
                }
                packet(["type": "response", "requestId": message["requestId"]!, "resultType": "success", "handledByClientId": "owner"], fd)
                received += 1
            }
            var changed = command
            changed["params"] = ["threadId": "test", "command": "different command"]
            snapshot([changed], revision: 2)
            _ = closeServer.wait(timeout: .now() + 8)
        }
        let worker = CodexIPCTransport(home: home, socketConnector: { Darwin.dup(clientFD) }, deliver: { events.receive($0) })
        worker.start(); defer { worker.stop(); closeServer.signal() }
        precondition(events.snapshot.wait(timeout: .now() + 4) == .success)
        let replies: [CodexReply] = [.decision("accept"), .answers(["choice": ["One"]]), .permissions(true), .decision("decline"), .answers([asyncID: ["A"]])]
        let wireRequests = requests + [asyncRequest]
        for i in 0..<5 {
            worker.submit(CodexRequestAction(token: UUID(), sessionID: "local:test", threadID: "test", hostID: "local", ownerClientID: "owner", request: wireRequests[i], reply: replies[i]))
            precondition(events.response.wait(timeout: .now() + 4) == .success)
        }
        precondition(events.snapshot.wait(timeout: .now() + 4) == .success)
        worker.submit(CodexRequestAction(token: UUID(), sessionID: "local:test", threadID: "test", hostID: "local", ownerClientID: "owner", request: requests[0], reply: .decision("accept")))
        precondition(events.response.wait(timeout: .now() + 4) == .success)
        precondition(events.results == [true, true, true, true, true, false], "changed payload cannot be approved")
        worker.submit(CodexRequestAction(token: UUID(), sessionID: "local:test", threadID: "test", hostID: "local", ownerClientID: "wrong-owner", request: requests[0], reply: .decision("accept")))
        precondition(events.response.wait(timeout: .now() + 4) == .success && events.results.last == false, "ownership change cannot route a reply elsewhere")
        worker.stop(); closeServer.signal()
        precondition(finished.wait(timeout: .now() + 4) == .success)
        print("PASS: async question lifecycle, swipe locking, 5 framed IPC replies, and stale-request rejection")
    }
}

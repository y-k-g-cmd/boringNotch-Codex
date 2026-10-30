import Foundation
import CoreFoundation

enum CodexActivity: String, Equatable {
    case running, needsApproval, needsInput, completed, failed, interrupted, idle, unknown
    var needsAttention: Bool { self == .needsApproval || self == .needsInput }
    var label: String {
        switch self {
        case .running: return "执行中"
        case .needsApproval: return "等待审批"
        case .needsInput: return "需要你的回答"
        case .completed: return "已完成"
        case .failed: return "执行失败"
        case .interrupted: return "已中断"
        case .idle: return "空闲"
        case .unknown: return "状态不可用"
        }
    }
}

struct CodexSession: Identifiable, Equatable {
    var id: String { hostID + ":" + threadID }
    let threadID: String
    let hostID: String
    var title: String
    var activity: CodexActivity
    var turnID: String?
    var summary: String
    var updatedAt: Date
    var ownerClientID = ""
    var requests: [CodexPendingRequest] = []
    var isSubagent = false

    /// Match desktop lineage metadata, never a display title or an ordinary fork.
    static func isSubagentState(_ state: [String: Any]) -> Bool {
        if let parent = state["parentThreadId"] as? String,
           !parent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let source = state["source"] as? [String: Any],
           let child = source["subAgent"], !(child is NSNull) { return true }
        if let source = state["source"] as? String {
            return ["subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther"].contains(source)
        }
        return false
    }

    static func parse(_ state: [String: Any], threadID: String, hostID: String, ownerClientID: String = "") -> CodexSession {
        var turns = state["turns"] as? [[String: Any]] ?? []
        let lastLegacyTurn = turns.last
        if let wrapper = state["turnHistory"] as? [String: Any],
           let history = wrapper["history"] as? [String: Any],
           let entities = history["entitiesByKey"] as? [String: [String: Any]] {
            turns += entities.values.filter { $0["turnId"] is String && $0["status"] is String }
        }
        let turn = turns.contains { $0["turnStartedAtMs"] != nil }
            ? turns.max { ($0["turnStartedAtMs"] as? Double ?? 0) < ($1["turnStartedAtMs"] as? Double ?? 0) }
            : lastLegacyTurn
        let runtime = state["threadRuntimeStatus"] as? [String: Any] ?? [:]
        let flags = runtime["activeFlags"] as? [String] ?? []
        let turnStatus = turn?["status"] as? String
        var activity: CodexActivity
        if flags.contains("waitingOnApproval") { activity = .needsApproval }
        else if flags.contains("waitingOnUserInput") { activity = .needsInput }
        else if runtime["type"] as? String == "active" || turnStatus == "inProgress" { activity = .running }
        else if turnStatus == "completed" { activity = .completed }
        else if turnStatus == "failed" { activity = .failed }
        else if turnStatus == "interrupted" { activity = .interrupted }
        else if runtime["type"] as? String == "idle" { activity = .idle }
        else { activity = .unknown }
        let items = turn?["items"] as? [[String: Any]] ?? []
        let messages = items.filter { $0["type"] as? String == "agentMessage" }
        let asyncRequests = CodexPendingRequest.asyncQuestions(in: turn, allTurns: turns, threadID: threadID, cwd: state["cwd"] as? String ?? "")
        if !asyncRequests.isEmpty && activity != .needsApproval { activity = .needsInput }
        var summary = messages.last?["text"] as? String ?? ""
        if activity.needsAttention {
            let requests = state["requests"] as? [[String: Any]] ?? []
            let params = requests.last?["params"] as? [String: Any] ?? [:]
            let questions = params["questions"] as? [[String: Any]] ?? []
            let pendingItem = items.last { $0["completed"] as? Bool == false }
            summary = params["reason"] as? String
                ?? questions.first?["question"] as? String
                ?? pendingItem?["reason"] as? String
                ?? (activity == .needsApproval ? "有操作需要你在 Codex 中审批" : "Codex 正在等待你的回答")
            if let question = asyncRequests.first?.questions.first { summary = question.title }
        }
        var session = CodexSession(threadID: threadID, hostID: hostID,
                            title: state["title"] as? String ?? state["fallbackSearchTitle"] as? String ?? "Codex 会话",
                            activity: activity, turnID: turn?["turnId"] as? String,
                            summary: String(summary.prefix(500)),
                            updatedAt: Date(timeIntervalSince1970: state["updatedAt"] as? Double ?? 0))
        session.isSubagent = isSubagentState(state)
        session.ownerClientID = ownerClientID
        session.requests = (state["requests"] as? [[String: Any]] ?? []).compactMap(CodexPendingRequest.init)
            .filter { request in
                let params = request.parameters
                return (params["threadId"] as? String).map { $0 == threadID } ?? true
            }
            .map { request in
                var request = request
                if request.method == "item/fileChange/requestApproval",
                   let itemID = request.parameters["itemId"] as? String,
                   let item = items.first(where: { $0["id"] as? String == itemID }),
                   let data = try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys]) {
                    request.context = String(data: data, encoding: .utf8) ?? ""
                }
                return request
            }
        session.requests += asyncRequests
        return session
    }
}

/// Deduplicates by turn and waiting episode. Baseline snapshots never announce old completions.
struct CodexReminderPolicy {
    private var previous: [String: CodexSession] = [:]
    private var completed: Set<String> = []

    mutating func observe(_ session: CodexSession, baseline: Bool = false) -> Bool {
        let old = previous.updateValue(session, forKey: session.id)
        guard !session.isSubagent else { return false }
        if session.activity.needsAttention {
            return old?.activity != session.activity || old?.turnID != session.turnID || old?.requests != session.requests
        }
        guard !baseline, let old, session.activity == .completed,
              let turnID = session.turnID,
              old.activity == .running || old.activity.needsAttention else { return false }
        let key = session.id + ":" + turnID
        return completed.insert(key).inserted
    }
}

/// Immer uses array paths (not RFC6901 strings). Reject bad revisions/paths atomically.
enum CodexStatePatch {
    enum Failure: Error { case invalidPath, unsupportedOperation }

    static func apply(_ patches: [[String: Any]], to state: Any) throws -> Any {
        var value = state
        for patch in patches {
            guard let op = patch["op"] as? String, let path = patch["path"] as? [Any] else { throw Failure.invalidPath }
            value = try edit(value, path: ArraySlice(path), operation: op, replacement: patch["value"])
        }
        return value
    }

    private static func edit(_ value: Any, path: ArraySlice<Any>, operation: String, replacement: Any?) throws -> Any {
        guard let head = path.first else {
            guard operation == "replace" || operation == "add", let replacement else { throw Failure.unsupportedOperation }
            return replacement
        }
        let rest = path.dropFirst()
        if var object = value as? [String: Any], let key = head as? String {
            if rest.isEmpty {
                switch operation {
                case "remove": guard object.removeValue(forKey: key) != nil else { throw Failure.invalidPath }
                case "replace": guard object[key] != nil, let replacement else { throw Failure.invalidPath }; object[key] = replacement
                case "add": guard let replacement else { throw Failure.invalidPath }; object[key] = replacement
                default: throw Failure.unsupportedOperation
                }
            } else {
                guard let child = object[key] else { throw Failure.invalidPath }
                object[key] = try edit(child, path: rest, operation: operation, replacement: replacement)
            }
            return object
        }
        if var array = value as? [Any], let index = head as? Int, index >= 0 {
            if rest.isEmpty {
                switch operation {
                case "add": guard index <= array.count, let replacement else { throw Failure.invalidPath }; array.insert(replacement, at: index)
                case "replace": guard index < array.count, let replacement else { throw Failure.invalidPath }; array[index] = replacement
                case "remove": guard index < array.count else { throw Failure.invalidPath }; array.remove(at: index)
                default: throw Failure.unsupportedOperation
                }
            } else {
                guard index < array.count else { throw Failure.invalidPath }
                array[index] = try edit(array[index], path: rest, operation: operation, replacement: replacement)
            }
            return array
        }
        throw Failure.invalidPath
    }
}

struct CodexQuestion: Identifiable, Equatable {
    struct Option: Equatable { let label: String; let description: String }
    let id: String
    let title: String
    let options: [Option]
    let isSecret: Bool
}

enum CodexReply: Equatable {
    case decision(String)
    case answers([String: [String]])
    case permissions(Bool)
}

/// Immutable request identity AND payload. A click is valid only for this exact request.
struct CodexPendingRequest: Identifiable, Equatable {
    static let asyncMethod = "codex/asyncQuestion"
    var context = ""
    let rawData: Data
    let idData: Data
    let method: String
    var id: String { method + ":" + idData.base64EncodedString() }
    var raw: [String: Any] { (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any] ?? [:] }
    var parameters: [String: Any] { raw["params"] as? [String: Any] ?? [:] }
    var title: String {
        switch method {
        case "item/commandExecution/requestApproval": return "命令执行审批"
        case "item/fileChange/requestApproval": return "文件修改审批"
        case "item/permissions/requestApproval": return "权限请求"
        case "item/tool/requestUserInput", Self.asyncMethod: return "需要你的回答"
        default: return "需要在 Codex 中处理"
        }
    }
    var questions: [CodexQuestion] {
        (parameters["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let id = q["id"] as? String, let title = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> CodexQuestion.Option? in
                guard let label = o["label"] as? String else { return nil }
                return .init(label: label, description: o["description"] as? String ?? "")
            }
            return CodexQuestion(id: id, title: title, options: options, isSecret: q["isSecret"] as? Bool ?? false)
        }
    }
    var details: String {
        if method == Self.asyncMethod { return "" }
        var lines: [String] = []
        for key in ["reason", "message", "command", "cwd", "grantRoot"] {
            if let value = parameters[key] as? String, !value.isEmpty { lines.append("\(key): \(value)") }
        }
        for key in ["changes", "permissions", "networkApprovalContext"] {
            if let value = parameters[key], !(value is NSNull),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
               let text = String(data: data, encoding: .utf8) { lines.append("\(key):\n\(text)") }
        }
        if !context.isEmpty { lines.append(context) }
        return lines.joined(separator: "\n")
    }
    var supportsReply: Bool {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval": return true
        case "item/permissions/requestApproval": return parameters["permissions"] is [String: Any]
        case "item/tool/requestUserInput", Self.asyncMethod: return !questions.isEmpty
        default: return false
        }
    }
    init?(_ raw: [String: Any]) {
        guard let method = raw["method"] as? String, let requestID = raw["id"],
              requestID is String || (requestID is NSNumber && CFGetTypeID(requestID as CFTypeRef) != CFBooleanGetTypeID()),
              let idData = try? JSONSerialization.data(withJSONObject: requestID, options: [.fragmentsAllowed, .sortedKeys]),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return nil }
        self.method = method; self.idData = idData; self.rawData = data
    }
    enum Invalid: Error { case unsupported, stale, incomplete }
    func response(_ reply: CodexReply) throws -> (method: String, payload: [String: Any]) {
        let requestID = try JSONSerialization.jsonObject(with: idData, options: .fragmentsAllowed)
        var payload: [String: Any] = ["requestId": requestID]
        switch (method, reply) {
        case ("item/commandExecution/requestApproval", .decision(let decision)),
             ("item/fileChange/requestApproval", .decision(let decision)):
            guard ["accept", "decline"].contains(decision) else { throw Invalid.unsupported }
            if let available = parameters["availableDecisions"] as? [Any], !available.contains(where: { $0 as? String == decision }) {
                throw Invalid.unsupported
            }
            payload["decision"] = decision
            return (method.contains("commandExecution") ? "thread-follower-command-approval-decision" : "thread-follower-file-approval-decision", payload)
        case ("item/tool/requestUserInput", .answers(let answers)), (Self.asyncMethod, .answers(let answers)):
            guard !questions.isEmpty, Set(answers.keys) == Set(questions.map(\.id)),
                  questions.allSatisfy({ q in answers[q.id]?.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true }) else { throw Invalid.incomplete }
            if method == Self.asyncMethod {
                let values = questions.map { ["questionItemId": $0.id, "question": $0.title, "answer": answers[$0.id]!.joined(separator: "\n")] }
                let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
                let prompt = "<send_user_message_question_reply>\n" + String(decoding: data, as: UTF8.self) + "\n</send_user_message_question_reply>"
                let input: [[String: Any]] = [["type": "text", "text": prompt, "text_elements": []]]
                let context: [String: Any] = ["inheritThreadSettings": true]
                if parameters["active"] as? Bool == true {
                    return ("thread-follower-steer-turn", ["input": input,
                        "restoreMessage": ["cwd": parameters["cwd"] as? String ?? "", "context": ["prompt": prompt, "turnTrigger": "send_user_message_async_question"]]])
                }
                return ("thread-follower-start-turn", ["turnStart": ["request": ["threadId": parameters["threadId"] as? String ?? "", "input": input, "turnTrigger": "send_user_message_async_question"], "context": context]])
            }
            payload["response"] = ["answers": answers.mapValues { ["answers": $0] }]
            return ("thread-follower-submit-user-input", payload)
        case ("item/permissions/requestApproval", .permissions(let allow)):
            guard let permissions = parameters["permissions"] as? [String: Any] else { throw Invalid.unsupported }
            payload["response"] = ["permissions": allow ? permissions : [:], "scope": "turn"]
            return ("thread-follower-permissions-request-approval-response", payload)
        default: throw Invalid.unsupported
        }
    }

    /// Desktop async questions are structured agent-message data, outside server requests.
    /// Only the latest turn is actionable; accepted XML replies consume the exact question IDs.
    static func asyncQuestions(in turn: [String: Any]?, allTurns: [[String: Any]], threadID: String, cwd: String) -> [Self] {
        guard let turn, let turnID = turn["turnId"] as? String,
              ["completed", "inProgress"].contains(turn["status"] as? String ?? "") else { return [] }
        var answered: Set<String> = []
        for turn in allTurns {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                let kind = item["type"] as? String
                guard kind == "userMessage" || (kind == "steeringUserMessage" && item["status"] as? String == "accepted") else { continue }
                let content = (item["content"] ?? item["input"]) as? [[String: Any]] ?? []
                for entry in content {
                    guard let text = entry["text"] as? String else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let open = "<send_user_message_question_reply>", close = "</send_user_message_question_reply>"
                    guard trimmed.hasPrefix(open), trimmed.hasSuffix(close),
                          let data = String(trimmed.dropFirst(open.count).dropLast(close.count)).data(using: .utf8),
                          let value = try? JSONSerialization.jsonObject(with: data) else { continue }
                    let replies = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
                    for reply in replies { if let id = reply["questionItemId"] as? String { answered.insert(id) } }
                }
            }
        }
        return (turn["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard item["type"] as? String == "agentMessage", let itemID = item["id"] as? String,
                  let values = item["questions"] as? [[String: Any]], !values.isEmpty else { return nil }
            let questions: [[String: Any]] = values.enumerated().compactMap { index, value in
                guard let title = value["title"] as? String else { return nil }
                let idData = try! JSONSerialization.data(withJSONObject: ["request_user_input_async", itemID, index], options: [.withoutEscapingSlashes])
                let id = String(decoding: idData, as: UTF8.self)
                guard !answered.contains(id) else { return nil }
                let options = (value["options"] as? [String] ?? []).map { ["label": $0, "description": ""] }
                return ["id": id, "question": title, "options": options]
            }
            guard !questions.isEmpty else { return nil }
            return Self(["id": "async:\(turnID):\(itemID)", "method": asyncMethod,
                "params": ["threadId": threadID, "turnId": turnID, "itemId": itemID, "questions": questions, "cwd": cwd, "active": turn["status"] as? String == "inProgress"]])
        }
    }
}

struct CodexRequestAction: Equatable {
    let token: UUID
    let sessionID: String
    let threadID: String
    let hostID: String
    let ownerClientID: String
    let request: CodexPendingRequest
    let reply: CodexReply
}

/// Default page selection when opening; explicit task reminders override this.
enum NotchDefaultContent: Equatable {
    case media, codex, fallback
    static func choose(isPlaying: Bool, hasCodex: Bool) -> Self {
        if isPlaying { return .media }
        if hasCodex { return .codex }
        return .fallback
    }
}

/// Only these values can affect the notch shell. Streaming text stays in the page.
struct CodexNotchState: Equatable {
    var retryPaused = false
    var connected = false
    var hasRelevantTasks = false
    var hasRunning = false
    var attentionCount = 0
    var reminderSequence = 0

    func enteredRetryPause(from previous: Self) -> Bool {
        retryPaused && !previous.retryPaused
    }

    init() {}
    init(sessions: [CodexSession], connected: Bool, unread: Set<String>, reminderSequence: Int, retryPaused: Bool = false) {
        let sessions = sessions.filter { !$0.isSubagent }
        self.retryPaused = retryPaused
        self.connected = connected
        self.hasRunning = !retryPaused && sessions.contains { $0.activity == .running }
        self.attentionCount = retryPaused ? 0 : sessions.filter { $0.activity.needsAttention }.count
        self.hasRelevantTasks = !retryPaused && sessions.contains { $0.activity == .running || $0.activity.needsAttention || unread.contains($0.id) }
        self.reminderSequence = reminderSequence
    }
}

struct CodexCompletionHighlight: Equatable {
    let id: UUID
    let expiresAt: Date
}

struct CodexCompletionFocus: Equatable {
    let id: UUID
    let sessionID: String
}

/// Monotonic failed-connection window. A working connection does not expire.
struct CodexReconnectWindow {
    let timeout: TimeInterval
    private(set) var failedSince: TimeInterval
    init(now: TimeInterval, timeout: TimeInterval = 300) {
        self.failedSince = now
        self.timeout = max(0, timeout)
    }
    func remaining(at now: TimeInterval) -> TimeInterval { max(0, timeout - (now - failedSince)) }
    func canAttempt(at now: TimeInterval) -> Bool { remaining(at: now) > 0 }
    static let stableConnectionDuration: TimeInterval = 15
    mutating func disconnectedAfterSuccess(at now: TimeInterval, connectedFor duration: TimeInterval) {
        guard duration.isFinite, duration >= Self.stableConnectionDuration else { return }
        failedSince = now
    }
}


enum CodexReminderTiming {
    static func completionDuration(_ stored: Double) -> Double {
        stored.isFinite ? min(60, max(1, stored)) : 6
    }
}

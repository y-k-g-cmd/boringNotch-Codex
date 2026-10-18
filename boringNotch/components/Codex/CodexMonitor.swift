import AppKit
import Combine
import SwiftUI

@MainActor
final class CodexMonitor: ObservableObject {
    struct Submission: Equatable {
        let action: CodexRequestAction
        var busy: Bool
        var message: String
    }
    static let shared = CodexMonitor()
    @Published private(set) var retryPaused = false
    @Published private(set) var completionHighlights: [String: CodexCompletionHighlight] = [:]
    @Published private(set) var completionFocus: CodexCompletionFocus?
    @Published private(set) var submissions: [String: Submission] = [:]
    private var pendingCompletionIDs: Set<String> = []
    @Published private(set) var notchState = CodexNotchState()
    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var connected = false
    @Published private(set) var connectionLabel = "等待连接 Codex"
    @Published private(set) var reminderSequence = 0
    @Published private(set) var unread: Set<String> = []
    @AppStorage("codexNotchReminders") var remindersEnabled = true
    var completionReminderSeconds: Double {
        let stored = UserDefaults.standard.object(forKey: "codexCompletionReminderDuration") as? Double ?? 6
        return CodexReminderTiming.completionDuration(stored)
    }
    private var policy = CodexReminderPolicy()
    private var transport: CodexIPCTransport?
    private var pendingReminder: Task<Void, Never>?

    var hasUnreadCompleted: Bool { sessions.contains { $0.activity == .completed && unread.contains($0.id) } }
    var attentionCount: Int { sessions.filter { $0.activity.needsAttention }.count }
    var hasRelevantTasks: Bool {
        !retryPaused && sessions.contains { $0.activity == .running || $0.activity.needsAttention || unread.contains($0.id) }
    }
    var hasBadge: Bool { attentionCount > 0 || !unread.isEmpty }
    var reminderNeedsAttention: Bool { sessions.contains { $0.activity.needsAttention } }

    init() {}

    private var scopedHome: URL?
    private var generation = UUID()

    func start() {
        guard transport == nil, !retryPaused else { return }
        var home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        if let bookmark = UserDefaults.standard.data(forKey: "codexMonitorDirectory") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                scopedHome = url
                home = url
                if stale, let refreshed = try? url.bookmarkData(options: .withSecurityScope) {
                    UserDefaults.standard.set(refreshed, forKey: "codexMonitorDirectory")
                }
            }
        }
        connect(home: home)
    }

    func reconnect() {
        guard let home = scopedHome else { chooseDirectory(); return }
        transport?.stop()
        retryPaused = false
        connect(home: home)
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 数据目录"
        panel.message = "选择 .codex 文件夹，以读取本机会话状态；只有你点击提交或允许／拒绝时才发送对应请求的回答。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        panel.begin { [weak self] response in
            guard response == .OK, let home = panel.url, let self else { return }
            let accessing = home.startAccessingSecurityScopedResource()
            guard let bookmark = try? home.bookmarkData(options: .withSecurityScope) else {
                if accessing { home.stopAccessingSecurityScopedResource() }
                self.connectionLabel = "无法保存目录访问权限，请重新选择"
                return
            }
            self.transport?.stop()
            self.scopedHome?.stopAccessingSecurityScopedResource()
            self.scopedHome = accessing ? home : nil
            UserDefaults.standard.set(bookmark, forKey: "codexMonitorDirectory")
            self.sessions.removeAll()
            self.unread.removeAll()
            self.pendingCompletionIDs.removeAll()
            self.completionHighlights.removeAll()
            self.completionFocus = nil
            self.policy = CodexReminderPolicy()
            self.connect(home: home)
        }
    }

    private func connect(home: URL) {
        defer { publishNotchState() }
        generation = UUID()
        let generation = generation
        connected = false
        retryPaused = false
        connectionLabel = "正在连接 Codex…"
        submissions.removeAll()
        // A folder grant is required before using the existing unsandboxed helper.
        let bridge = CodexSocketBridge()
        let connector: (() throws -> Int32)? = scopedHome == nil ? nil : { try bridge.connect() }
        let transport = CodexIPCTransport(home: home, socketConnector: connector) { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.receive(event)
            }
        }
        self.transport = transport
        transport.start()
    }

    func receive(_ event: CodexIPCTransport.Event) {
        defer { publishNotchState() }
        switch event {
        case .actionResult(let token, let success, let message):
            guard let key = submissions.first(where: { $0.value.action.token == token })?.key else { return }
            submissions[key]?.busy = success
            submissions[key]?.message = message
        case .retryPaused:
            connected = false
            retryPaused = true
            connectionLabel = "5 分钟内未连上，已暂停；请手动连接"
            transport?.stop()
            pendingReminder?.cancel()
            pendingCompletionIDs.removeAll()
            completionHighlights.removeAll()
        case .connection(let connected, let label):
            self.connected = connected
            connectionLabel = label
        case .removed(let key):
            submissions.removeValue(forKey: key)
            sessions.removeAll { $0.id == key }
            unread.remove(key)
            pendingCompletionIDs.remove(key)
            completionHighlights.removeValue(forKey: key)
        case .session(let session, let baseline):
            if let submission = submissions[session.id],
               session.ownerClientID != submission.action.ownerClientID || !session.requests.contains(submission.action.request) {
                submissions.removeValue(forKey: session.id)
            }
            guard sessions.first(where: { $0.id == session.id }) != session else { return }
            if session.activity != .completed {
                pendingCompletionIDs.remove(session.id)
                completionHighlights.removeValue(forKey: session.id)
            }
            let notify = policy.observe(session, baseline: baseline)
            var next = sessions.filter { $0.id != session.id }
            next.append(session)
            next.sort {
                if $0.activity.needsAttention != $1.activity.needsAttention { return $0.activity.needsAttention }
                return $0.updatedAt > $1.updatedAt
            }
            sessions = next
            if !session.activity.needsAttention && session.activity != .completed { unread.remove(session.id) }
            guard notify else { return }
            unread.insert(session.id)
            // Coalesce bursts, retaining every unread card.
            guard remindersEnabled else { return }
            if session.activity == .completed { pendingCompletionIDs.insert(session.id) }
            pendingReminder?.cancel()
            pendingReminder = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.connected, self.hasBadge, self.remindersEnabled else { return }
                self.reminderSequence += 1
                self.publishNotchState()
            }
        }
    }

    /// Called when the notch actually presents a reminder, after any drag/share delay.
    func beginReminderPresentation() {
        let eligible = sessions.filter {
            pendingCompletionIDs.contains($0.id) && $0.activity == .completed && unread.contains($0.id)
        }
        pendingCompletionIDs.removeAll()
        completionFocus = nil
        guard remindersEnabled, let first = eligible.first else { return }
        let token = UUID()
        var next = completionHighlights.filter { $0.value.expiresAt > Date() }
        for session in eligible {
            next[session.id] = CodexCompletionHighlight(id: token, expiresAt: Date().addingTimeInterval(3))
        }
        completionHighlights = next
        completionFocus = CodexCompletionFocus(id: token, sessionID: first.id)
    }

    func open(_ session: CodexSession) {
        defer { publishNotchState() }
        // Opening a card navigates only; replies require their own explicit button.
        guard let url = URL(string: "codex://threads/\(session.threadID)") else { return }
        if NSWorkspace.shared.open(url) {
            unread.remove(session.id)
            pendingCompletionIDs.remove(session.id)
            completionHighlights.removeValue(forKey: session.id)
        }
    }

    func submit(_ reply: CodexReply, request: CodexPendingRequest, session: CodexSession) {
        guard connected, let transport, submissions[session.id]?.busy != true,
              let live = sessions.first(where: { $0.id == session.id }),
              live.ownerClientID == session.ownerClientID, !live.ownerClientID.isEmpty,
              live.requests.contains(request), (try? request.response(reply)) != nil else { return }
        let action = CodexRequestAction(token: UUID(), sessionID: live.id, threadID: live.threadID,
            hostID: live.hostID, ownerClientID: live.ownerClientID, request: request, reply: reply)
        submissions[live.id] = Submission(action: action, busy: true, message: "正在提交…")
        transport.submit(action)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.submissions[live.id]?.action.token == action.token,
                  self.submissions[live.id]?.busy == true else { return }
            self.submissions[live.id]?.busy = false
            self.submissions[live.id]?.message = "Codex 尚未更新请求，请打开原任务确认；不会自动重复提交"
        }
    }

    private func publishNotchState() {
        let next = CodexNotchState(sessions: sessions, connected: connected, unread: unread, reminderSequence: reminderSequence, retryPaused: retryPaused)
        if notchState != next { notchState = next }
    }

    func markCompletedRead() {
        defer { publishNotchState() }
        let pending = Set(sessions.filter { $0.activity.needsAttention }.map(\.id))
        unread.formIntersection(pending)
        pendingCompletionIDs.formIntersection(pending)
        completionHighlights = completionHighlights.filter { pending.contains($0.key) }
    }
}
